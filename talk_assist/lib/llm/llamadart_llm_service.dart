import "dart:async";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:llamadart/llamadart.dart";
import "package:talk_assist/llm/llm_service.dart";
import "package:talk_assist/llm/model_config.dart";
import "package:talk_assist/llm/model_repository.dart";
import "package:talk_assist/message.dart";

/// On-device LLM service using the llamadart plugin (llama.cpp).
/// Wraps local Qwen3.5 inference with initialization guards,
/// completion serialization, timeout handling, and context-window checks.
class LlamadartLlmService implements LlmService {
  LlamadartLlmService({
    required ModelRepository modelRepository,
    LlamaEngine? engine,
  }) : _modelRepository = modelRepository,
       _engine = engine ?? LlamaEngine(LlamaBackend());

  final ModelRepository _modelRepository;
  final LlamaEngine _engine;

  Future<void>? _initFuture;
  Future<void> _completionLane = Future<void>.value();

  bool _hasSuccessfulGeneration = false;
  int? _activeContextWindowTokens;

  /// Lazy, idempotent initialization.
  /// Tries configured init candidates until one succeeds.
  @override
  Future<void> init() {
    if (_engine.isReady) {
      return Future<void>.value();
    }
    return _initFuture ??= _initInternal();
  }

  Future<void> _initInternal() async {
    try {
      final model = await _modelRepository.getConfiguredModel();
      if (model == null) {
        throw const LlmUnavailableException(
          "No local Qwen3.5 model is configured.",
        );
      }

      final file = File(model.path);
      if (!await file.exists()) {
        throw LlmUnavailableException(
          "Configured model file does not exist: ${model.path}",
        );
      }

      if (kDebugMode) {
        final fileSize = await file.length();
        final fileSizeMB = (fileSize / 1024 / 1024).toStringAsFixed(1);
        final filename = model.path.split(Platform.pathSeparator).last;
        debugPrint(
          "Qwen3.5 model file (name=$filename, sizeMB=$fileSizeMB, source=${model.sourceUrl ?? 'unknown'}).",
        );
      }

      final initCandidates = _initCandidates();
      Object? lastError;

      for (final candidate in initCandidates) {
        try {
          await _engine.loadModel(
            model.path,
            modelParams: ModelParams(
              contextSize: candidate.nCtx,
              batchSize: candidate.nBatch,
              microBatchSize: candidate.nBatch,
              numberOfThreads: ModelConfig.inferenceThreads,
              numberOfThreadsBatch: ModelConfig.inferenceThreads,
              preferredBackend: GpuBackend.cpu,
              gpuLayers: 0,
            ),
          );

          final actualContext = await _engine.getContextSize();
          _activeContextWindowTokens = actualContext > 0
              ? actualContext
              : candidate.nCtx;

          if (kDebugMode) {
            debugPrint(
              "Qwen3.5 context ready (nCtx=${_activeContextWindowTokens ?? candidate.nCtx}, nBatch=${candidate.nBatch}).",
            );
          }
          return;
        } catch (error) {
          lastError = error;
          _activeContextWindowTokens = null;

          if (_engine.isReady) {
            try {
              await _engine.unloadModel();
            } catch (_) {
              // Best-effort reset before trying the next candidate.
            }
          }
        }
      }

      throw LlmUnavailableException("Qwen3.5 init failed: $lastError");
    } catch (_) {
      _initFuture = null;
      rethrow;
    }
  }

  @override
  Future<bool> isReady() async {
    if (_engine.isReady) {
      return true;
    }

    final model = await _modelRepository.getConfiguredModel();
    if (model == null) {
      return false;
    }

    return File(model.path).existsSync();
  }

  /// Public entry point for generating a reply.
  /// Only one completion runs at a time.
  @override
  Future<String> generateReply({
    required String userInput,
    required List<ChatMessage> history,
  }) {
    return _enqueueCompletion(
      label: "generateReply",
      operation: () =>
          _generateReplyInternal(userInput: userInput, history: history),
    );
  }

  Future<String> _generateReplyInternal({
    required String userInput,
    required List<ChatMessage> history,
  }) async {
    await _requireInitialized();

    final startedAt = DateTime.now();
    String outcome = "unknown";
    int? tokensPredicted;
    int? tokensEvaluated;

    if (kDebugMode) {
      debugPrint(
        "Qwen3.5 generation started (history=${history.length}, inputChars=${userInput.length}).",
      );
    }

    final messages = _buildMessages(
      history: history,
      userInput: userInput,
      historyLimit: ModelConfig.maxHistoryMessages,
      systemPrompt: ModelConfig.systemPrompt,
    );

    final contextUsage = await _contextWindowUsage(messages: messages);
    if (contextUsage != null) {
      tokensEvaluated = contextUsage.promptTokens;
      if (kDebugMode) {
        debugPrint(
          "Qwen3.5 context window available (nCtx=${contextUsage.contextWindow}, promptTokens=${contextUsage.promptTokens}, available=${contextUsage.remainingTokens}).",
        );
      }
      if (contextUsage.isNearFull && kDebugMode) {
        debugPrint(
          "Qwen3.5 context window almost full (available=${contextUsage.remainingTokens}).",
        );
      }
      if (contextUsage.isFull) {
        if (kDebugMode) {
          debugPrint(
            "Qwen3.5 context window full (available=${contextUsage.remainingTokens}).",
          );
        }
        outcome = "context_limit";
        _logInteractionMetrics(
          outcome: outcome,
          totalElapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
          tokensEvaluated: tokensEvaluated,
        );
        return ModelConfig.contextWindowLimitReachedMessage;
      }
    }

    if (kDebugMode) {
      final initCandidates = _initCandidates();
      final primaryNCtx = initCandidates.isNotEmpty
          ? initCandidates.first.nCtx
          : -1;
      final primaryNBatch = initCandidates.isNotEmpty
          ? initCandidates.first.nBatch
          : -1;
      final userPreview = userInput.trim();
      final preview = userPreview.length > 120
          ? "${userPreview.substring(0, 120)}..."
          : userPreview;
      debugPrint(
        "Qwen3.5 prompt prepared (messages=${messages.length}, nCtx=$primaryNCtx, nBatch=$primaryNBatch, nPredict=${ModelConfig.maxPredictTokens}, latestUser=\"$preview\").",
      );
    }

    try {
      final rawReply = await _runCompletion(
        messages: messages,
        timeout: _activeInferenceTimeout(),
        nPredict: ModelConfig.maxPredictTokens,
        temperature: ModelConfig.temperature,
        topK: ModelConfig.topK,
        topP: ModelConfig.topP,
        attempt: "primary",
      );

      final text = rawReply.trim();
      if (text.isNotEmpty) {
        outcome = "success";
        _hasSuccessfulGeneration = true;
        tokensPredicted = await _safeTokenCount(text);
        final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
        if (kDebugMode) {
          debugPrint(
            "Qwen3.5 generation succeeded (attempt=primary, elapsedMs=$elapsedMs).",
          );
        }
        return text;
      }

      outcome = "empty";
      throw const LlmUnavailableException(
        "Qwen3.5 returned an empty completion.",
      );
    } on TimeoutException {
      outcome = "timeout";
      _interruptCompletion(attempt: "primary");
      // Give native side time to finish in-flight decode before next attempt.
      await Future<void>.delayed(const Duration(seconds: 2));

      throw const LlmUnavailableException(
        "Qwen3.5 response timed out on this device.",
      );
    } on LlmUnavailableException {
      rethrow;
    } catch (error) {
      outcome = "error";
      throw LlmUnavailableException("Qwen3.5 generation failed: $error");
    } finally {
      _logInteractionMetrics(
        outcome: outcome,
        totalElapsedMs: DateTime.now().difference(startedAt).inMilliseconds,
        tokensPredicted: tokensPredicted,
        tokensEvaluated: tokensEvaluated,
      );
    }
  }

  Future<void> _requireInitialized() async {
    if (_engine.isReady) {
      return;
    }
    await init();
    if (!_engine.isReady) {
      throw const LlmUnavailableException("Local model context is not ready.");
    }
  }

  Future<String> _runCompletion({
    required List<LlamaChatMessage> messages,
    required Duration timeout,
    required int nPredict,
    required double temperature,
    required int topK,
    required double topP,
    required String attempt,
  }) async {
    final startedAt = DateTime.now();
    if (kDebugMode) {
      debugPrint(
        "Qwen3.5 completion start (attempt=$attempt, messages=${messages.length}, nPredict=$nPredict, timeoutMs=${timeout.inMilliseconds}).",
      );
    }

    final responseBuffer = StringBuffer();

    await (() async {
      await for (final chunk in _engine.create(
        messages,
        params: GenerationParams(
          maxTokens: nPredict,
          temp: temperature,
          topK: topK,
          topP: topP,
        ),
        enableThinking: false,
      )) {
        if (chunk.choices.isEmpty) {
          continue;
        }

        final deltaText = chunk.choices.first.delta.content;
        if (deltaText != null && deltaText.isNotEmpty) {
          responseBuffer.write(deltaText);
        }
      }
    })().timeout(timeout);

    if (kDebugMode) {
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      debugPrint(
        "Qwen3.5 completion end (attempt=$attempt, elapsedMs=$elapsed).",
      );
    }

    return responseBuffer.toString();
  }

  void _interruptCompletion({required String attempt}) {
    try {
      _engine.cancelGeneration();
      if (kDebugMode) {
        debugPrint("Qwen3.5 completion interrupted (attempt=$attempt).");
      }
    } catch (_) {
      // Ignore cancellation errors.
    }
  }

  /// Only one completion runs at a time.
  /// Each new operation waits for the previous to complete (or fail).
  Future<T> _enqueueCompletion<T>({
    required String label,
    required Future<T> Function() operation,
  }) {
    final completer = Completer<T>();
    final queuedAt = DateTime.now();
    final previous = _completionLane;

    _completionLane = previous
        .catchError((_) {
          // Keep the lane alive after previous failures.
        })
        .then((_) async {
          final waitedMs = DateTime.now().difference(queuedAt).inMilliseconds;
          if (kDebugMode && waitedMs > 0) {
            debugPrint(
              "Qwen3.5 completion lane acquired (label=$label, waitMs=$waitedMs).",
            );
          }

          try {
            completer.complete(await operation());
          } catch (error, stackTrace) {
            completer.completeError(error, stackTrace);
          }
        });

    return completer.future;
  }

  Duration _activeInferenceTimeout() {
    if (_hasSuccessfulGeneration) {
      return ModelConfig.steadyStateInferenceTimeout;
    }
    return ModelConfig.coldStartInferenceTimeout;
  }

  List<_InitCandidate> _initCandidates() {
    return const <_InitCandidate>[
      _InitCandidate(
        nCtx: ModelConfig.contextWindowTokens,
        nBatch: ModelConfig.batchSizeTokens,
      ),
    ];
  }

  /// Builds stateless OpenAI-style chat messages for engine.create().
  /// Filters safe-mode assistant replies and deduplicates trailing user input.
  List<LlamaChatMessage> _buildMessages({
    required List<ChatMessage> history,
    required String userInput,
    required int historyLimit,
    required String systemPrompt,
  }) {
    final filteredHistory = history
        .where((message) {
          if (message.role != MsgRole.assistant) {
            return true;
          }
          return message.assistantOrigin != AssistantOrigin.safeMode;
        })
        .toList(growable: false);

    final trimmedHistory = filteredHistory.length > historyLimit
        ? filteredHistory.sublist(filteredHistory.length - historyLimit)
        : filteredHistory;

    final messages = <LlamaChatMessage>[
      LlamaChatMessage.fromText(role: LlamaChatRole.system, text: systemPrompt),
    ];

    for (final message in trimmedHistory) {
      final text = message.text.trim();
      if (text.isEmpty) {
        continue;
      }

      messages.add(
        LlamaChatMessage.fromText(
          role: message.role == MsgRole.user
              ? LlamaChatRole.user
              : LlamaChatRole.assistant,
          text: text,
        ),
      );
    }

    final normalizedInput = userInput.trim();
    if (normalizedInput.isNotEmpty) {
      final isDuplicateLastUser =
          messages.isNotEmpty &&
          messages.last.role == LlamaChatRole.user &&
          messages.last.content == normalizedInput;
      if (!isDuplicateLastUser) {
        messages.add(
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: normalizedInput,
          ),
        );
      }
    }

    return messages;
  }

  /// Checks how much of the context window the current prompt consumes.
  Future<_ContextWindowUsage?> _contextWindowUsage({
    required List<LlamaChatMessage> messages,
  }) async {
    final contextWindow = await _resolveContextWindowTokens();
    if (contextWindow <= 0) {
      return null;
    }

    try {
      final template = await _engine.chatTemplate(
        messages,
        includeTokenCount: false,
      );
      final promptTokens = await _engine.getTokenCount(template.prompt);
      if (promptTokens <= 0) {
        return null;
      }

      final remaining = contextWindow - promptTokens;
      return _ContextWindowUsage(
        contextWindow: contextWindow,
        promptTokens: promptTokens,
        remainingTokens: remaining,
        isNearFull:
            remaining <= ModelConfig.contextWindowNearFullThresholdTokens,
        isFull: remaining <= ModelConfig.contextWindowFullThresholdTokens,
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint("Qwen3.5 token count unavailable: $error");
      }
      return null;
    }
  }

  Future<int> _resolveContextWindowTokens() async {
    final knownContext = _activeContextWindowTokens;
    if (knownContext != null && knownContext > 0) {
      return knownContext;
    }

    try {
      final runtimeContext = await _engine.getContextSize();
      if (runtimeContext > 0) {
        _activeContextWindowTokens = runtimeContext;
        return runtimeContext;
      }
    } catch (_) {
      // Fallback to configured context below.
    }

    _activeContextWindowTokens = ModelConfig.contextWindowTokens;
    return ModelConfig.contextWindowTokens;
  }

  Future<int?> _safeTokenCount(String text) async {
    if (text.isEmpty) {
      return 0;
    }
    try {
      return await _engine.getTokenCount(text);
    } catch (_) {
      return null;
    }
  }

  void _logInteractionMetrics({
    required String outcome,
    required int totalElapsedMs,
    int? tokensPredicted,
    int? tokensEvaluated,
  }) {
    if (!kDebugMode) {
      return;
    }

    final tokensPerSecond = _tokensPerSecond(
      tokensPredicted: tokensPredicted,
      elapsedMs: totalElapsedMs,
    );
    final predictedLabel = tokensPredicted?.toString() ?? "n/a";
    final evaluatedLabel = tokensEvaluated?.toString() ?? "n/a";
    final tpsLabel = tokensPerSecond?.toStringAsFixed(2) ?? "n/a";
    final msPerToken = (tokensPredicted != null && tokensPredicted > 0)
        ? totalElapsedMs ~/ tokensPredicted
        : null;
    final msPerTokenLabel = msPerToken?.toString() ?? "n/a";

    debugPrint(
      "Qwen3.5 interaction metrics (outcome=$outcome, totalMs=$totalElapsedMs, tokensPredicted=$predictedLabel, tokensEvaluated=$evaluatedLabel, tokensPerSecond=$tpsLabel, msPerToken=$msPerTokenLabel).",
    );
  }

  double? _tokensPerSecond({
    required int? tokensPredicted,
    required int elapsedMs,
  }) {
    if (tokensPredicted == null || tokensPredicted <= 0 || elapsedMs <= 0) {
      return null;
    }
    return tokensPredicted / (elapsedMs / 1000.0);
  }

  /// Releases native resources and resets service state.
  /// Safe to call multiple times.
  @override
  Future<void> dispose() async {
    _initFuture = null;
    _completionLane = Future<void>.value();
    _hasSuccessfulGeneration = false;
    _activeContextWindowTokens = null;

    try {
      await _engine.dispose();
    } catch (_) {
      // Ignore teardown errors.
    }
  }
}

class _InitCandidate {
  const _InitCandidate({required this.nCtx, required this.nBatch});

  final int nCtx;
  final int nBatch;
}

class _ContextWindowUsage {
  const _ContextWindowUsage({
    required this.contextWindow,
    required this.promptTokens,
    required this.remainingTokens,
    required this.isNearFull,
    required this.isFull,
  });

  final int contextWindow;
  final int promptTokens;
  final int remainingTokens;
  final bool isNearFull;
  final bool isFull;
}
