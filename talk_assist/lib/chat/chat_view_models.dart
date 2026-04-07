import 'package:flutter/material.dart';

class ChatMessageView {
  const ChatMessageView({
    required this.id,
    required this.text,
    required this.isUser,
    this.origin,
  });

  final String id;
  final String text;
  final bool isUser;
  final String? origin;
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

class LlmStatusView {
  const LlmStatusView({required this.label});

  final String label;

  Color get dotColor {
    switch (label) {
      case 'online':    return const Color(0xFF34D399); // teal
      case 'on-device': return const Color(0xFF4ADE80); // green
      case 'safe mode': return const Color(0xFFFBBF24); // amber
      case 'device':    return const Color(0xFF60A5FA); // blue
      case 'queued':    return const Color(0xFFA78BFA); // purple
      default:          return const Color(0xFF6B7280); // grey
    }
  }
}