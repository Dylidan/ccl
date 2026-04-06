import "dart:async";

import "package:flutter/material.dart";
import "package:talk_assist/chat/chat_controller.dart";
import "package:talk_assist/chat/chat_view_models.dart";
import 'package:talk_assist/stt/sherpa_stt_service.dart';
import "widgets/chat_ui.dart";

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessageView> _messages = <ChatMessageView>[];
  final List<ConversationTabView> _conversations = <ConversationTabView>[];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  late final ChatController _chatController;
  bool _isListening = false;
  bool _isTranscribing = false;
  late final SherpaSttService _sttService;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));

    _chatController = ChatController();
    _chatController.addListener(_onChatControllerChanged);
    unawaited(_chatController.initialize());
    _sttService = SherpaSttService();
    _sttService.initialize();
  }

  void _onChatControllerChanged() {
    if (!mounted) {
      return;
    }

    setState(() {
      _messages
        ..clear()
        ..addAll(
          _chatController.messages.map(
            (message) => ChatMessageView(
              id: message.id,
              text: message.text,
              isUser: message.isUser,
            ),
          ),
        );
      _conversations
        ..clear()
        ..addAll(
          _chatController.conversations.map(
            (conversation) => ConversationTabView(
              id: conversation.id,
              title: conversation.title,
              preview: conversation.preview,
              isActive: conversation.isActive,
            ),
          ),
        );
    });

    _scrollToBottom();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      return;
    }

    _controller.clear();
    await _chatController.sendUserMessage(text);
    _scrollToBottom();
  }

  Future<void> _createConversation() async {
    _controller.clear();
    await _chatController.createConversation();
    _scrollToBottom();
  }

  Future<void> _selectConversation(String conversationId) async {
    await _chatController.selectConversation(conversationId);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  //Mic logic, if listening stop recird 
  //if not start recording and transcribe when done
  Future<void> _toggleMic() async {
    if (_isTranscribing) return;

    if (!_isListening) {
      try {
        await _chatController.stopSpeaking();

        await _sttService.startRecording();

        if (!mounted) return;
        setState(() {
          _isListening = true;
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Record failed: $e')),
        );
      }
      return;
    }

    try {
      setState(() {
        _isListening = false;
        _isTranscribing = true;
      });

      final text = await _sttService.stopRecordingAndTranscribe();

      if (!mounted) return;

      if (text != null && text.isNotEmpty) {
        _controller.text = text;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No speech detected')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Speech recognition failed: $e')),
      );
    } finally {
      if (!mounted) return;
      setState(() {
        _isTranscribing = false;
      });
    }
  }

  @override
  void dispose() {
    _chatController.removeListener(_onChatControllerChanged);
    _chatController.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _sttService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChatUI(
      title: "TalkAssist 2.0",
      messages: _messages,
      conversations: _conversations,
      textController: _controller,
      scrollController: _scrollController,
      onSend: _sendMessage,
      onNewConversation: _createConversation,
      onSelectConversation: _selectConversation,
      onMicTap: _toggleMic,
      isListening: _isListening,
      isTranscribing: _isTranscribing,
    );
  }
}
