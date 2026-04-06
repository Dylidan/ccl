class ChatMessageView {
  const ChatMessageView({
    required this.id,
    required this.text,
    required this.isUser,
  });

  final String id;
  final String text;
  final bool isUser;
}

class ConversationTabView {
  const ConversationTabView({
    required this.id,
    required this.title,
    required this.preview,
    required this.isActive,
  });

  final String id;
  final String title;
  final String preview;
  final bool isActive;
}
