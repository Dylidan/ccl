import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter/widgets.dart";
import "package:talk_assist/llm/history_store.dart";
import "package:talk_assist/llm/llm_orchestrator.dart";
import "package:talk_assist/message.dart";
import "package:talk_assist/reminders/reminder_command.dart";
import "package:talk_assist/reminders/reminder_service.dart";
import "package:talk_assist/tts/piper_tts_service.dart";
import "package:talk_assist/tts/tts_service.dart";

/// Lightweight message object for the chat UI layer.
class ChatUiMessage {
  const ChatUiMessage({
    required this.id,
    required this.text,
    required this.isUser,
  });

  final String id;
  final String text;
  final bool isUser;
}

/// Lightweight conversation object for the conversation list UI.
class ChatConversationSummary {
  const ChatConversationSummary({
    required this.id,
    required this.title,
    required this.preview,
    required this.updatedAt,
    required this.isActive,
  });

  final String id;
  final String title;
  final String preview;
  final DateTime updatedAt;
  final bool isActive;
}

class _PendingUiMessage {
  const _PendingUiMessage({
    required this.conversationId,
    required this.message,
  });

  final String conversationId;
  final ChatUiMessage message;
}

/// Bridges the chat UI to the LLM backend.
/// Manages the active conversation, the conversation list, persistence,
/// reminders, and TTS.
class ChatController extends ChangeNotifier with WidgetsBindingObserver {
  ChatController({
    HistoryStore? historyStore,
    LlmOrchestrator? orchestrator,
    ReminderService? reminderService,
    TtsService? ttsService,
    Duration? historyFlushInterval,
  }) : _historyStore = historyStore ?? HistoryStore(),
       _orchestrator = orchestrator ?? LlmOrchestrator(),
       _reminderService = reminderService ?? ReminderService(),
       _ttsService = ttsService ?? PiperTtsService(),
       _historyFlushInterval =
           historyFlushInterval ?? const Duration(seconds: 30);

  final HistoryStore _historyStore;
  final LlmOrchestrator _orchestrator;
  final ReminderService _reminderService;
  final TtsService _ttsService;
  final Message _messageStore = Message.instance;
  final Duration _historyFlushInterval;
  final List<_PendingUiMessage> _pendingMessages = <_PendingUiMessage>[];

  Future<void>? _initializeFuture;
  Future<void>? _historyFlushFuture;
  Timer? _historyFlushTimer;
  bool _historyDirty = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _isObserverRegistered = false;

  String get activeConversationId => _messageStore.activeConversationId;

  List<ChatConversationSummary> get conversations {
    final activeId = activeConversationId;
    return _messageStore
        .conversationsSnapshot()
        .map(
          (conversation) => ChatConversationSummary(
            id: conversation.id,
            title: conversation.title,
            preview: conversation.preview,
            updatedAt: conversation.updatedAt,
            isActive: conversation.id == activeId,
          ),
        )
        .toList(growable: false);
  }

  List<ChatUiMessage> get messages {
    final activeId = activeConversationId;
    final history = _messageStore.historySnapshot(conversationId: activeId);
    final pendingForActive = _pendingMessages
        .where((item) => item.conversationId == activeId)
        .map((item) => item.message);

    return List<ChatUiMessage>.unmodifiable(
      <ChatUiMessage>[
        ..._mapHistoryToUiMessages(history),
        ...pendingForActive,
      ],
    );
  }

  Future<void> initialize() async {
    if (_initialized || _disposed) {
      return;
    }

    final existing = _initializeFuture;
    if (existing != null) {
      return existing;
    }

    final future = _initializeInternal();
    _initializeFuture = future;
    return future.whenComplete(() {
      if (identical(_initializeFuture, future)) {
        _initializeFuture = null;
      }
    });
  }

  Future<void> _initializeInternal() async {
    final archive = await _historyStore.loadArchive();
    _messageStore.replaceConversations(
      archive.conversations,
      activeConversationId: archive.activeConversationId,
    );
    _pendingMessages.clear();

    _orchestrator.setHistorySnapshot(_messageStore.historyForLlm());

    await _orchestrator.start();
    unawaited(_ttsService.init());

    _initialized = true;
    _historyDirty = false;
    _registerLifecycleObserver();
    _startHistoryFlushTimer();
    _notifyIfAlive();
  }

  Future<void> createConversation() async {
    if (!_initialized) {
      await initialize();
    }

    _messageStore.createConversation();
    _orchestrator.setHistorySnapshot(_messageStore.historyForLlm());
    _markHistoryDirty();
    _notifyIfAlive();
    unawaited(_flushHistoryIfDirty(reason: "new-conversation"));
  }

  Future<void> selectConversation(String conversationId) async {
    if (!_initialized) {
      await initialize();
    }

    if (!_messageStore.setActiveConversation(conversationId)) {
      return;
    }

    _orchestrator.setHistorySnapshot(_messageStore.historyForLlm());
    _markHistoryDirty();
    _notifyIfAlive();
    unawaited(_flushHistoryIfDirty(reason: "select-conversation"));
  }

  Future<void> sendUserMessage(String rawInput) async {
    final text = rawInput.trim();
    if (text.isEmpty || _disposed) {
      return;
    }

    if (!_initialized) {
      await initialize();
    }

    final conversationId = activeConversationId;
    final assistantId = "a_${DateTime.now().microsecondsSinceEpoch}";

    _messageStore.addUserMessage(text, conversationId: conversationId);
    _pendingMessages.add(
      _PendingUiMessage(
        conversationId: conversationId,
        message: ChatUiMessage(id: assistantId, text: "...", isUser: false),
      ),
    );
    _orchestrator.setHistorySnapshot(_messageStore.historyForLlm());
    _markHistoryDirty();
    _notifyIfAlive();
    unawaited(_flushHistoryIfDirty(reason: "user-message"));

    final reminderParse = ReminderRequest.parse(text);
    if (reminderParse.isReminderCommand) {
      final reminderReply = await _handleReminderCommand(
        assistantId: assistantId,
        parseResult: reminderParse,
      );
      _messageStore.addAssistMsg(
        reminderReply,
        origin: AssistantOrigin.deviceAction,
        conversationId: conversationId,
      );
      _orchestrator.setHistorySnapshot(_messageStore.historyForLlm());
      _markHistoryDirty();
      _notifyIfAlive();
      unawaited(_flushHistoryIfDirty(reason: "reminder-reply"));
      return;
    }

    LlmOrchestratorReply reply;
    try {
      reply = await _orchestrator.replyForUserInput(
        userInput: text,
        history: _messageStore.historySnapshot(conversationId: conversationId),
      );
    } catch (_) {
      reply = const LlmOrchestratorReply(
        text:
            "I heard you. I am still preparing the local assistant and will answer as soon as it is ready.",
        origin: AssistantOrigin.safeMode,
      );
    }

    _removePendingMessage(assistantId);
    _messageStore.addAssistMsg(
      reply.text,
      origin: reply.origin,
      conversationId: conversationId,
    );
    _orchestrator.setHistorySnapshot(_messageStore.historyForLlm());
    _markHistoryDirty();
    _notifyIfAlive();
    unawaited(_flushHistoryIfDirty(reason: "assistant-reply"));

    if (kDebugMode) {
      debugPrint("CHAT: Triggering TTS for reply");
    }
    unawaited(_ttsService.speak(reply.text));
  }

  Future<String> _handleReminderCommand({
    required String assistantId,
    required ReminderCommandParseResult parseResult,
  }) async {
    final errorMessage = parseResult.errorMessage;
    if (errorMessage != null) {
      _removePendingMessage(assistantId);
      return errorMessage;
    }

    final request = parseResult.request!;
    final launchResult = await _reminderService.createReminder(request);
    _removePendingMessage(assistantId);
    return launchResult.opened
        ? launchResult.message
        : "Reminder could not be opened: ${launchResult.message}";
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_initialized || _disposed) {
      return;
    }

    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        unawaited(_flushHistoryIfDirty(reason: "lifecycle:${state.name}"));
        break;
      case AppLifecycleState.resumed:
        break;
    }
  }

  Future<void> _flushHistoryIfDirty({required String reason}) {
    if (_disposed || !_initialized || !_historyDirty) {
      return Future<void>.value();
    }

    final existing = _historyFlushFuture;
    if (existing != null) {
      return existing;
    }

    final future = _flushHistoryInternal(reason: reason);
    _historyFlushFuture = future;
    return future.whenComplete(() {
      if (identical(_historyFlushFuture, future)) {
        _historyFlushFuture = null;
      }
      if (_historyDirty && !_disposed) {
        unawaited(_flushHistoryIfDirty(reason: "coalesced"));
      }
    });
  }

  Future<void> _flushHistoryInternal({required String reason}) async {
    final archive = _messageStore.archiveSnapshot();
    _historyDirty = false;
    try {
      await _historyStore.saveArchive(archive);
      if (kDebugMode) {
        debugPrint(
          "History flushed (reason=$reason, conversations=${archive.conversations.length}).",
        );
      }
    } catch (_) {
      _historyDirty = true;
    }
  }

  void _startHistoryFlushTimer() {
    _historyFlushTimer?.cancel();
    _historyFlushTimer = Timer.periodic(_historyFlushInterval, (_) {
      unawaited(_flushHistoryIfDirty(reason: "timer"));
    });
  }

  void _markHistoryDirty() {
    _historyDirty = true;
  }

  void _registerLifecycleObserver() {
    if (_isObserverRegistered) {
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _isObserverRegistered = true;
  }

  void _unregisterLifecycleObserver() {
    if (!_isObserverRegistered) {
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    _isObserverRegistered = false;
  }

  List<ChatUiMessage> _mapHistoryToUiMessages(List<ChatMessage> history) {
    return List<ChatUiMessage>.generate(history.length, (index) {
      final message = history[index];
      final prefix = message.role == MsgRole.user ? "u" : "a";
      return ChatUiMessage(
        id: "${prefix}_${message.timestamp.microsecondsSinceEpoch}_$index",
        text: message.text,
        isUser: message.role == MsgRole.user,
      );
    });
  }

  void _removePendingMessage(String id) {
    _pendingMessages.removeWhere((entry) => entry.message.id == id);
  }

  Future<void> stopSpeaking() async {
    await _ttsService.stop();
  }

  void _notifyIfAlive() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _historyFlushTimer?.cancel();
    _unregisterLifecycleObserver();
    unawaited(_flushHistoryIfDirty(reason: "dispose"));

    _disposed = true;
    unawaited(_orchestrator.dispose());
    unawaited(_ttsService.dispose());
    super.dispose();
  }
}
