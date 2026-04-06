import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:talk_assist/llm/llamadart_llm_service.dart';
import 'package:talk_assist/llm/llm_service.dart';
import 'package:talk_assist/llm/model_repository.dart';
import 'package:talk_assist/llm/open_router_llm_service.dart';
import 'package:talk_assist/llm/safe_mode_llm_service.dart';
import 'package:talk_assist/message.dart';

/// Result from [LlmOrchestrator.replyForUserInput].
///
/// Pairs the reply text with its origin so the UI can distinguish
/// between online (OpenRouter), local (llamadart), and safe-mode fallback replies.
class LlmOrchestratorReply {
  const LlmOrchestratorReply({required this.text, required this.origin});

  /// The generated reply text.
  final String text;

  /// Which service produced this reply.
  final AssistantOrigin origin;
}

/// Routes user messages to the best available LLM backend.
///
/// Priority order:
///   1. **OpenRouter** (online) — used whenever an internet connection is detected.
///   2. **LlamadartLlmService** (on-device) — used when offline and the local
///      Qwen3.5 model has been downloaded and initialised.
///   3. **SafeModeLlmService** (fallback) — used when neither of the above
///      can respond (e.g. first boot before the model is ready, no internet).
///
/// The local model download runs as a background task regardless of whether
/// OpenRouter is currently serving requests, so it is ready when the user
/// goes offline.
class LlmOrchestrator {
  factory LlmOrchestrator({
    ModelRepository? modelRepository,
    LlmService? onlineLlmService,
    LlmService? localLlmService,
    LlmService? safeModeLlmService,
    Connectivity? connectivity,
    Future<List<ConnectivityResult>> Function()? connectivityCheck,
  }) {
    final repository = modelRepository ?? ModelRepository();
    final resolvedConnectivity = connectivity ?? Connectivity();
    return LlmOrchestrator._(
      modelRepository: repository,
      onlineLlmService: onlineLlmService ?? OpenRouterLlmService(),
      localLlmService:
          localLlmService ?? LlamadartLlmService(modelRepository: repository),
      safeModeLlmService: safeModeLlmService ?? SafeModeLlmService(),
      connectivityCheck:
          connectivityCheck ?? resolvedConnectivity.checkConnectivity,
    );
  }

  LlmOrchestrator._({
    required ModelRepository modelRepository,
    required LlmService onlineLlmService,
    required LlmService localLlmService,
    required LlmService safeModeLlmService,
    required Future<List<ConnectivityResult>> Function() connectivityCheck,
  }) : _modelRepository = modelRepository,
       _onlineLlm = onlineLlmService,
       _localLlm = localLlmService,
       _safeModeLlm = safeModeLlmService,
       _connectivityCheck = connectivityCheck;

  final ModelRepository _modelRepository;
  final LlmService _onlineLlm;
  final LlmService _localLlm;
  final LlmService _safeModeLlm;
  final Future<List<ConnectivityResult>> Function() _connectivityCheck;

  Future<void>? _startFuture;
  Future<bool>? _prepareFuture;
  bool _started = false;
  bool _isLocalReady = false;
  bool _disposed = false;

  List<ChatMessage> _latestHistory = <ChatMessage>[];

  /// Idempotent startup.
  ///
  /// Initialises safe-mode and the online service immediately, then kicks
  /// off the local model download/init in the background so it is ready
  /// when the user goes offline.
  Future<void> start() {
    if (_disposed || _started) return Future<void>.value();

    final existing = _startFuture;
    if (existing != null) return existing;

    final future = _startInternal();
    _startFuture = future;
    return future.whenComplete(() {
      if (identical(_startFuture, future)) _startFuture = null;
    });
  }

  Future<void> _startInternal() async {
    await _safeModeLlm.init();
    await _onlineLlm.init();
    await _cleanupLegacyQueueFile();
    // Kick off local model preparation in the background.
    unawaited(_prepareLocalModel(triggerSource: 'startup'));
    _started = true;
  }

  void setHistorySnapshot(List<ChatMessage> history) {
    _latestHistory = List<ChatMessage>.from(history);
  }

  /// Main entry point for getting a reply to user input.
  ///
  /// Routing logic:
  ///   - Online  → try OpenRouter first.
  ///   - OpenRouter fails or offline → try local llamadart model.
  ///   - Local model not ready → safe-mode fallback.
  Future<LlmOrchestratorReply> replyForUserInput({
    required String userInput,
    required List<ChatMessage> history,
  }) async {
    await start();

    final normalized = userInput.trim();
    if (normalized.isEmpty) {
      final safeReply = await _safeModeLlm.generateReply(
        userInput: normalized,
        history: history,
      );
      return LlmOrchestratorReply(
        text: safeReply,
        origin: AssistantOrigin.safeMode,
      );
    }

    setHistorySnapshot(history);

    final requestStartedAt = DateTime.now();
    if (kDebugMode) {
      debugPrint('LLM request started (inputChars=${normalized.length}).');
    }

    try {
      // ── 1. Try online (OpenRouter) ─────────────────────────────────────────
      final isOnline = await _hasLikelyInternetConnection();
      if (isOnline) {
        try {
          final onlineReply = await _onlineLlm.generateReply(
            userInput: normalized,
            history: _historyForLlm(_latestHistory),
          );
          _latestHistory = <ChatMessage>[
            ..._latestHistory,
            ChatMessage(
              role: MsgRole.assistant,
              text: onlineReply,
              timestamp: DateTime.now(),
              assistantOrigin: AssistantOrigin.localLlm,
            ),
          ];
          if (kDebugMode) debugPrint('OpenRouter reply succeeded.');
          return LlmOrchestratorReply(
            text: onlineReply,
            origin: AssistantOrigin.localLlm,
          );
        } catch (e) {
          if (kDebugMode) {
            debugPrint('OpenRouter failed, falling back to local model: $e');
          }
        }
      }

      // ── 2. Try local (llamadart / Qwen3.5) ────────────────────────────────
      final localReady = await _prepareLocalModel(triggerSource: 'send');
      if (localReady) {
        try {
          final localReply = await _localLlm.generateReply(
            userInput: normalized,
            history: _historyForLlm(_latestHistory),
          );
          _latestHistory = <ChatMessage>[
            ..._latestHistory,
            ChatMessage(
              role: MsgRole.assistant,
              text: localReply,
              timestamp: DateTime.now(),
              assistantOrigin: AssistantOrigin.localLlm,
            ),
          ];
          return LlmOrchestratorReply(
            text: localReply,
            origin: AssistantOrigin.localLlm,
          );
        } catch (e) {
          if (kDebugMode) debugPrint('Local LLM generation failed: $e');
          await _refreshLocalReadyFromService();
        }
      }

      // ── 3. Safe-mode fallback ──────────────────────────────────────────────
      final safeReply = await _safeModeLlm.generateReply(
        userInput: normalized,
        history: history,
      );
      return LlmOrchestratorReply(
        text: safeReply,
        origin: AssistantOrigin.safeMode,
      );
    } finally {
      if (kDebugMode) {
        final elapsedMs = DateTime.now()
            .difference(requestStartedAt)
            .inMilliseconds;
        debugPrint('LLM request finished (elapsedMs=$elapsedMs).');
      }
    }
  }

  // ── Local model preparation ────────────────────────────────────────────────

  Future<bool> _prepareLocalModel({required String triggerSource}) {
    if (_disposed) return Future<bool>.value(false);
    if (_isLocalReady) return Future<bool>.value(true);

    final existing = _prepareFuture;
    if (existing != null) return existing;

    final future = _prepareLocalModelInternal(triggerSource: triggerSource);
    _prepareFuture = future;
    return future.whenComplete(() {
      if (identical(_prepareFuture, future)) _prepareFuture = null;
    });
  }

  Future<bool> _prepareLocalModelInternal({
    required String triggerSource,
  }) async {
    final hasInternet = await _hasLikelyInternetConnection();
    if (!hasInternet) return false;

    try {
      final downloadStartedAt = DateTime.now();
      var lastLoggedBucket = 0;
      var didLogCompletion = false;
      final model = await _modelRepository.ensureModelAvailable(
        onProgress: ({required int receivedBytes, required int totalBytes}) {
          if (!kDebugMode || totalBytes <= 0) return;

          final percent = (receivedBytes * 100 ~/ totalBytes).clamp(0, 100);
          final bucket = (percent ~/ 10) * 10;
          final shouldLogBucket = bucket >= 10 && bucket > lastLoggedBucket;

          if (shouldLogBucket) {
            lastLoggedBucket = bucket;
            final receivedMB = (receivedBytes / 1024 / 1024).toStringAsFixed(1);
            final totalMB = (totalBytes / 1024 / 1024).toStringAsFixed(1);
            final elapsed = DateTime.now().difference(downloadStartedAt);
            final elapsedStr =
                '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
            debugPrint(
              'Model download: $bucket% ($receivedMB / $totalMB MB) [elapsed: $elapsedStr]',
            );
          }

          if (percent >= 100 && !didLogCompletion) {
            didLogCompletion = true;
            final total = DateTime.now().difference(downloadStartedAt);
            debugPrint(
              'Model download complete in ${total.inMinutes}m ${total.inSeconds % 60}s',
            );
          }
        },
      );
      if (model == null) return false;

      await _localLlm.init();
      _isLocalReady = true;
      if (kDebugMode) {
        debugPrint('Local Qwen3.5 ready (trigger=$triggerSource).');
      }
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Local model setup failed: $e');
      _isLocalReady = false;
      return false;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Strips safe-mode assistant messages before sending history to any LLM.
  List<ChatMessage> _historyForLlm(List<ChatMessage> history) {
    return history
        .where(
          (m) =>
              m.role != MsgRole.assistant ||
              m.assistantOrigin != AssistantOrigin.safeMode,
        )
        .toList(growable: false);
  }

  Future<bool> _hasLikelyInternetConnection() async {
    try {
      final results = await _connectivityCheck();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      return true;
    }
  }

  Future<void> _refreshLocalReadyFromService() async {
    try {
      _isLocalReady = await _localLlm.isReady();
    } catch (_) {
      _isLocalReady = false;
    }
  }

  Future<void> _cleanupLegacyQueueFile() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final legacyFile = File('${appDir.path}/pending_queue.json');
      if (await legacyFile.exists()) await legacyFile.delete();
    } catch (_) {
      // Non-critical cleanup.
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _started = false;
    await _onlineLlm.dispose();
    await _localLlm.dispose();
    await _safeModeLlm.dispose();
  }
}
