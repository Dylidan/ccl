import "dart:convert";

/// Identifies the author of a chat message.
enum MsgRole { user, assistant }

/// Tracks which service produced an assistant reply.
/// Used to filter safe-mode echoes out of LLM context windows.
enum AssistantOrigin { localLlm, safeMode, queuedReplay, deviceAction }

/// A single message in the conversation.
///
/// Immutable value object with role, text, timestamp, and optional origin.
/// Serializable to/from JSON for disk persistence.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    required this.timestamp,
    this.assistantOrigin,
  });

  final MsgRole role;
  final String text;
  final DateTime timestamp;

  /// Which service produced this assistant reply, if known.
  final AssistantOrigin? assistantOrigin;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "role": role.name,
      "text": text,
      "timestamp": timestamp.toIso8601String(),
      if (assistantOrigin != null) "assistantOrigin": assistantOrigin!.name,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: _parseRole(json["role"]?.toString()),
      text: json["text"]?.toString() ?? "",
      timestamp:
          DateTime.tryParse(json["timestamp"]?.toString() ?? "") ??
          DateTime.now(),
      assistantOrigin: _parseAssistantOrigin(
        json["assistantOrigin"]?.toString(),
      ),
    );
  }

  @override
  String toString() {
    return "[${timestamp.toIso8601String()}] ${role.name}: $text";
  }
}

/// A single persisted conversation thread.
class ConversationThread {
  ConversationThread({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    List<ChatMessage>? messages,
  }) : messages = messages ?? <ChatMessage>[];

  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<ChatMessage> messages;

  bool get hasMessages => messages.isNotEmpty;

  String get preview {
    if (messages.isEmpty) {
      return "Empty conversation";
    }
    return messages.last.text.trim();
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "id": id,
      "title": title,
      "createdAt": createdAt.toIso8601String(),
      "updatedAt": updatedAt.toIso8601String(),
      "messages": messages
          .map((message) => message.toJson())
          .toList(growable: false),
    };
  }

  factory ConversationThread.fromJson(Map<String, dynamic> json) {
    final decodedMessages = json["messages"];
    final messages = <ChatMessage>[];
    if (decodedMessages is List) {
      for (final item in decodedMessages) {
        if (item is! Map) {
          continue;
        }
        try {
          messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(item)));
        } catch (_) {
          continue;
        }
      }
    }

    final createdAt =
        DateTime.tryParse(json["createdAt"]?.toString() ?? "") ??
        (messages.isNotEmpty ? messages.first.timestamp : DateTime.now());
    final updatedAt =
        DateTime.tryParse(json["updatedAt"]?.toString() ?? "") ??
        (messages.isNotEmpty ? messages.last.timestamp : createdAt);

    return ConversationThread(
      id: json["id"]?.toString() ?? _conversationIdFrom(createdAt),
      title: _normalizedConversationTitle(
        raw: json["title"]?.toString(),
        messages: messages,
      ),
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
    );
  }
}

/// Serializable bundle of all saved conversations and the selected one.
class ConversationArchive {
  const ConversationArchive({
    required this.conversations,
    this.activeConversationId,
  });

  final List<ConversationThread> conversations;
  final String? activeConversationId;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "activeConversationId": activeConversationId,
      "conversations": conversations
          .map((conversation) => conversation.toJson())
          .toList(growable: false),
    };
  }
}

/// Global in-memory conversation store.
///
/// Owns all conversations, the currently active conversation, and filtered
/// snapshots for building LLM prompts.
class Message {
  static final Message instance = Message._internal();

  Message._internal();

  /// The most recent user input for the active conversation.
  String latestUserInput = "";

  final List<ConversationThread> _conversations = <ConversationThread>[];
  String? _activeConversationId;

  List<ConversationThread> conversationsSnapshot() {
    return _conversations
        .map(
          (conversation) => ConversationThread(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messages: List<ChatMessage>.from(conversation.messages),
          ),
        )
        .toList(growable: false);
  }

  String get activeConversationId {
    return _ensureConversationAvailable().id;
  }

  ConversationThread get activeConversation => _ensureConversationAvailable();

  void replaceConversations(
    List<ConversationThread> conversations, {
    String? activeConversationId,
  }) {
    _conversations
      ..clear()
      ..addAll(
        conversations.map(
          (conversation) => ConversationThread(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            messages: List<ChatMessage>.from(conversation.messages),
          ),
        ),
      );

    if (_conversations.isEmpty) {
      _activeConversationId = null;
      createConversation();
      return;
    }

    final requestedId = activeConversationId;
    final hasRequestedId = requestedId != null &&
        _conversations.any((conversation) => conversation.id == requestedId);
    _activeConversationId = hasRequestedId ? requestedId : _conversations.first.id;
    _syncLatestUserInput();
  }

  String createConversation({String title = "New chat"}) {
    final now = DateTime.now();
    final conversation = ConversationThread(
      id: _conversationIdFrom(now),
      title: title,
      createdAt: now,
      updatedAt: now,
    );
    _conversations.insert(0, conversation);
    _activeConversationId = conversation.id;
    latestUserInput = "";
    return conversation.id;
  }

  bool setActiveConversation(String id) {
    final conversation = _conversationById(id);
    if (conversation == null) {
      return false;
    }
    _activeConversationId = conversation.id;
    _syncLatestUserInput();
    return true;
  }

  void addUserMessage(String text, {String? conversationId}) {
    final conversation = _conversationForMutation(conversationId);
    final now = DateTime.now();
    final hadUserMessages = conversation.messages.any(
      (message) => message.role == MsgRole.user,
    );

    conversation.messages.add(
      ChatMessage(role: MsgRole.user, text: text, timestamp: now),
    );
    conversation.updatedAt = now;

    if (!hadUserMessages && _isDefaultConversationTitle(conversation.title)) {
      conversation.title = _titleFromUserText(text);
    }

    _moveConversationToFront(conversation.id);
    if (conversation.id == _activeConversationId) {
      latestUserInput = text;
    }
  }

  void addAssistMsg(
    String text, {
    AssistantOrigin origin = AssistantOrigin.localLlm,
    String? conversationId,
  }) {
    final conversation = _conversationForMutation(conversationId);
    final now = DateTime.now();
    conversation.messages.add(
      ChatMessage(
        role: MsgRole.assistant,
        text: text,
        timestamp: now,
        assistantOrigin: origin,
      ),
    );
    conversation.updatedAt = now;
    _moveConversationToFront(conversation.id);
    if (conversation.id == _activeConversationId) {
      _syncLatestUserInput();
    }
  }

  ConversationArchive archiveSnapshot() {
    return ConversationArchive(
      conversations: conversationsSnapshot(),
      activeConversationId: _activeConversationId,
    );
  }

  String exportHistoryJson() {
    return jsonEncode(archiveSnapshot().toJson());
  }

  List<ChatMessage> historySnapshot({String? conversationId}) {
    final conversation = _conversationForRead(conversationId);
    return List<ChatMessage>.from(conversation.messages);
  }

  /// Returns active or selected history with safe-mode assistant messages stripped out.
  List<ChatMessage> historyForLlm({
    bool includeSafeModeAssistant = false,
    String? conversationId,
  }) {
    return historySnapshot(conversationId: conversationId)
        .where((message) {
          if (message.role != MsgRole.assistant) {
            return true;
          }
          if (includeSafeModeAssistant) {
            return true;
          }
          if (message.assistantOrigin == AssistantOrigin.safeMode) {
            return false;
          }

          final normalized = message.text.trimLeft().toLowerCase();
          return !normalized.startsWith("safe mode");
        })
        .map(
          (message) => ChatMessage(
            role: message.role,
            text: message.text,
            timestamp: message.timestamp,
            assistantOrigin: message.assistantOrigin,
          ),
        )
        .toList(growable: false);
  }

  ConversationThread _ensureConversationAvailable() {
    if (_conversations.isEmpty) {
      createConversation();
    }
    return _conversationForRead(null);
  }

  ConversationThread _conversationForRead(String? conversationId) {
    final resolvedId = conversationId ?? _activeConversationId;
    final conversation = resolvedId == null ? null : _conversationById(resolvedId);
    if (conversation != null) {
      return conversation;
    }
    return _conversations.first;
  }

  ConversationThread _conversationForMutation(String? conversationId) {
    if (_conversations.isEmpty) {
      createConversation();
    }
    return _conversationForRead(conversationId);
  }

  ConversationThread? _conversationById(String id) {
    for (final conversation in _conversations) {
      if (conversation.id == id) {
        return conversation;
      }
    }
    return null;
  }

  void _moveConversationToFront(String id) {
    final index = _conversations.indexWhere((conversation) => conversation.id == id);
    if (index <= 0) {
      return;
    }
    final conversation = _conversations.removeAt(index);
    _conversations.insert(0, conversation);
  }

  void _syncLatestUserInput() {
    latestUserInput = "";
    final conversation = _conversationForRead(null);
    for (var index = conversation.messages.length - 1; index >= 0; index -= 1) {
      final item = conversation.messages[index];
      if (item.role == MsgRole.user) {
        latestUserInput = item.text;
        break;
      }
    }
  }
}

MsgRole _parseRole(String? raw) {
  for (final value in MsgRole.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return MsgRole.user;
}

AssistantOrigin? _parseAssistantOrigin(String? raw) {
  if (raw == null || raw.isEmpty) {
    return null;
  }
  for (final value in AssistantOrigin.values) {
    if (value.name == raw) {
      return value;
    }
  }
  return null;
}

String _conversationIdFrom(DateTime time) {
  return "conv_${time.microsecondsSinceEpoch}";
}

String _titleFromUserText(String text) {
  final normalized = text.trim().replaceAll(RegExp(r"\s+"), " ");
  if (normalized.isEmpty) {
    return "New chat";
  }
  if (normalized.length <= 36) {
    return normalized;
  }
  return "${normalized.substring(0, 36).trimRight()}...";
}

bool _isDefaultConversationTitle(String title) {
  return title.trim().isEmpty || title.trim().toLowerCase() == "new chat";
}

String _normalizedConversationTitle({
  required String? raw,
  required List<ChatMessage> messages,
}) {
  final trimmed = raw?.trim() ?? "";
  if (trimmed.isNotEmpty) {
    return trimmed;
  }

  for (final message in messages) {
    if (message.role == MsgRole.user && message.text.trim().isNotEmpty) {
      return _titleFromUserText(message.text);
    }
  }
  return "New chat";
}
