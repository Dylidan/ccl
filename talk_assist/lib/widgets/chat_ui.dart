import "dart:ui";

import "package:flutter/material.dart";
import "package:talk_assist/chat/chat_view_models.dart";

import "animated_gradient_background.dart";
import "message_bubble.dart";
import "send_button.dart";

class ChatUI extends StatelessWidget {
  const ChatUI({
    super.key,
    required this.title,
    required this.messages,
    required this.conversations,
    required this.textController,
    required this.scrollController,
    required this.onSend,
    required this.onNewConversation,
    required this.onSelectConversation,
    required this.onMicTap,
    required this.isListening,
    required this.isTranscribing,
    required this.llmStatus,
  });

  final String title;
  final List<ChatMessageView> messages;
  final List<ConversationTabView> conversations;
  final TextEditingController textController;
  final ScrollController scrollController;
  final VoidCallback onSend;
  final VoidCallback onNewConversation;
  final ValueChanged<String> onSelectConversation;
  final VoidCallback onMicTap;
  final bool isListening;
  final bool isTranscribing;
  final LlmStatusView llmStatus;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showSidePanel = constraints.maxWidth >= 920;
        final conversationPanel = _ConversationPanel(
          conversations: conversations,
          onNewConversation: onNewConversation,
          onSelectConversation: onSelectConversation,
        );

        return Scaffold(
          extendBodyBehindAppBar: true,
          backgroundColor: Colors.transparent,
          drawer: showSidePanel
              ? null
              : Drawer(
                  backgroundColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  child: conversationPanel,
                ),
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: ClipRRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: AppBar(
                  elevation: 0,
                  backgroundColor: Colors.white.withOpacity(0.08),
                  leading: showSidePanel
                      ? null
                      : Builder(
                          builder: (context) {
                            return IconButton(
                              icon: const Icon(Icons.menu_rounded),
                              onPressed: () => Scaffold.of(context).openDrawer(),
                            );
                          },
                        ),
                  title: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                      color: Colors.white,
                    ),
                  ),
                  centerTitle: false,
                  actions: [
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: _LlmStatusIndicator(status: llmStatus),
                    ),
                  ],
                ),
              ),
            ),
          ),
          body: Stack(
            children: [
              const AnimatedGradientBackground(),
              SafeArea(
                child: Row(
                  children: [
                    if (showSidePanel)
                      SizedBox(width: 300, child: conversationPanel),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                return MessageBubble(message: messages[index]);
                              },
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(22),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.10),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.12),
                                    ),
                                    borderRadius: BorderRadius.circular(22),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: textController,
                                          textInputAction: TextInputAction.send,
                                          onSubmitted: (_) => onSend(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                          ),
                                          decoration: InputDecoration(
                                            hintText:
                                                "Message or /reminder Task | 2026-03-15 18:30",
                                            hintStyle: TextStyle(
                                              color: Colors.white.withOpacity(0.55),
                                            ),
                                            border: InputBorder.none,
                                            isDense: true,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 6,
                                                ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      IconButton(
                                        onPressed: isTranscribing ? null : onMicTap,
                                        icon: isTranscribing
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              )
                                            : Icon(
                                                isListening
                                                    ? Icons.stop_circle
                                                    : Icons.mic,
                                              ),
                                      ),
                                      SendButton(
                                        onPressed: onSend,
                                        enabled:
                                            textController.text.trim().isNotEmpty,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ConversationPanel extends StatelessWidget {
  const _ConversationPanel({
    required this.conversations,
    required this.onNewConversation,
    required this.onSelectConversation,
  });

  final List<ConversationTabView> conversations;
  final VoidCallback onNewConversation;
  final ValueChanged<String> onSelectConversation;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.14),
            border: Border(
              right: BorderSide(color: Colors.white.withOpacity(0.08)),
            ),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(0.05),
                Colors.black.withOpacity(0.10),
              ],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      onNewConversation();
                      if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) {
                        Navigator.of(context).pop();
                      }
                    },
                    icon: const Icon(Icons.add_comment_outlined),
                    label: const Text("New Chat"),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    "Conversations",
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.75),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: conversations.isEmpty
                        ? Center(
                            child: Text(
                              "No saved chats yet.",
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: conversations.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final conversation = conversations[index];
                              return _ConversationTile(
                                conversation: conversation,
                                onTap: () {
                                  onSelectConversation(conversation.id);
                                  if (Scaffold.maybeOf(context)?.isDrawerOpen ?? false) {
                                    Navigator.of(context).pop();
                                  }
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
  });

  final ConversationTabView conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isActive = conversation.isActive;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: isActive
                ? Colors.white.withOpacity(0.10)
                : Colors.white.withOpacity(0.03),
            border: Border.all(
              color: isActive
                  ? Colors.white.withOpacity(0.14)
                  : Colors.white.withOpacity(0.06),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  conversation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  conversation.preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.68),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LlmStatusIndicator extends StatelessWidget {
  const _LlmStatusIndicator({required this.status});

  final LlmStatusView status;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: status.dotColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: status.dotColor.withOpacity(0.6),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          status.label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.75),
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}