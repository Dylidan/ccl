import "dart:convert";
import "dart:io";

import "package:path_provider/path_provider.dart";
import "package:talk_assist/message.dart";

/// Reads and writes all conversations to disk as JSON.
/// Stores data in `history.json` in the app documents directory.
/// All operations are resilient to missing or corrupt files.
class HistoryStore {
  static const String _fileName = "history.json";

  /// Loads persisted conversations from disk.
  /// Supports both the current archive shape and the older single-history list.
  Future<ConversationArchive> loadArchive() async {
    final file = await _historyFile();
    if (!await file.exists()) {
      return const ConversationArchive(conversations: <ConversationThread>[]);
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const ConversationArchive(conversations: <ConversationThread>[]);
    }

    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return _archiveFromMap(decoded);
    }
    if (decoded is Map) {
      return _archiveFromMap(Map<String, dynamic>.from(decoded));
    }
    if (decoded is List) {
      final legacyConversation = _legacyConversationFromList(decoded);
      return ConversationArchive(
        conversations: legacyConversation == null
            ? const <ConversationThread>[]
            : <ConversationThread>[legacyConversation],
        activeConversationId: legacyConversation?.id,
      );
    }

    return const ConversationArchive(conversations: <ConversationThread>[]);
  }

  /// Serializes all conversations to JSON and writes to disk.
  /// Uses flush=true for durability. Creates parent directories if needed.
  Future<void> saveArchive(ConversationArchive archive) async {
    final file = await _historyFile();
    await file.parent.create(recursive: true);
    final payload = jsonEncode(archive.toJson());
    await file.writeAsString(payload, flush: true);
  }

  Future<void> clear() async {
    final file = await _historyFile();
    if (await file.exists()) {
      await file.delete();
    }
  }

  ConversationArchive _archiveFromMap(Map<String, dynamic> json) {
    final decodedConversations = json["conversations"];
    final conversations = <ConversationThread>[];
    if (decodedConversations is List) {
      for (final item in decodedConversations) {
        if (item is! Map) {
          continue;
        }
        try {
          conversations.add(
            ConversationThread.fromJson(Map<String, dynamic>.from(item)),
          );
        } catch (_) {
          continue;
        }
      }
    }

    final activeConversationId = json["activeConversationId"]?.toString();
    return ConversationArchive(
      conversations: conversations,
      activeConversationId: activeConversationId,
    );
  }

  ConversationThread? _legacyConversationFromList(List<dynamic> decoded) {
    final messages = <ChatMessage>[];
    for (final entry in decoded) {
      if (entry is! Map) {
        continue;
      }
      try {
        messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(entry)));
      } catch (_) {
        continue;
      }
    }

    if (messages.isEmpty) {
      return null;
    }

    final createdAt = messages.first.timestamp;
    final updatedAt = messages.last.timestamp;
    final firstUserText = messages
        .where((message) => message.role == MsgRole.user)
        .map((message) => message.text.trim())
        .firstWhere((text) => text.isNotEmpty, orElse: () => "New chat");

    return ConversationThread(
      id: "conv_${createdAt.microsecondsSinceEpoch}",
      title: firstUserText.length <= 36
          ? firstUserText
          : "${firstUserText.substring(0, 36).trimRight()}...",
      createdAt: createdAt,
      updatedAt: updatedAt,
      messages: messages,
    );
  }

  Future<File> _historyFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File("${appDir.path}/$_fileName");
  }
}
