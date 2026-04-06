import 'package:flutter/material.dart';
import 'package:talk_assist/chat/chat_view_models.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessageView message;
  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final align = isUser ? Alignment.centerRight : Alignment.centerLeft;

    final bubbleGradient = isUser
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF5B8CFF).withOpacity(0.95),
              const Color(0xFF7A5CFF).withOpacity(0.95),
            ],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.14),
              Colors.white.withOpacity(0.08),
            ],
          );

    final textColor = isUser ? Colors.white : Colors.white.withOpacity(0.92);

    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          gradient: bubbleGradient,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isUser ? 18 : 6),
            bottomRight: Radius.circular(isUser ? 6 : 18),
          ),
          border: isUser ? null : Border.all(color: Colors.white.withOpacity(0.10)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.20),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Text(
            message.text,
            style: TextStyle(color: textColor, fontSize: 16, height: 1.25),
          ),
        ),
      ),
    );
  }
}