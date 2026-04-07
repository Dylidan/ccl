import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:talk_assist/llm/llm_service.dart';
import 'package:talk_assist/llm/model_config.dart';
import 'package:talk_assist/message.dart';

/// Online LLM service that streams responses from OpenRouter.ai.
///
/// Used when an internet connection is available.
/// the [LlmOrchestrator] will catch [LlmUnavailableException] and route
/// to the local on-device model or safe-mode instead.
///
///To Run: create a .env file in project root with "OPENROUTER_KEY=yourkey"
/// and "SERPER_KEY=yourkey" then
///   flutter run
///
/// As of now I have my API key in the .env file, not sure if that is good
/// practice or not, previously was defining at runtime with:
///   flutter run --dart-define=OPENROUTER_KEY=your_api_key
class OpenRouterLlmService implements LlmService {
  OpenRouterLlmService({
    String? apiKey,
    http.Client? httpClient,
  })  : _apiKey = apiKey ?? dotenv.env['OPENROUTER_KEY'] ?? '',
        _client = httpClient ?? http.Client();

  static const String _endpoint =
      'https://openrouter.ai/api/v1/chat/completions';

  // Change this to load the model of your choice
  // 'openrouter/auto' lets OpenRouter pick the best free model automatically.
  // I tried using a couple including meta-llama/llama-3.1-8b-instruct:free
  // but they seem to fail occasionally so I'm going to leave it as auto
  // models are constantly being removed from the free tier
  static const String _model = 'openrouter/auto';

  static const Duration _requestTimeout = Duration(seconds: 30);

  final String _apiKey;
  final http.Client _client;
  bool _initialized = false;

  @override
  Future<void> init() async {
    _initialized = true;
  }

  @override
  Future<bool> isReady() async {
    return _initialized && _apiKey.isNotEmpty;
  }

  /// Sends the full conversation history to OpenRouter and returns the reply.
  ///
  /// Throws [LlmUnavailableException] on network errors, bad status codes,
  /// missing API key, or empty responses — so the orchestrator can fall back.
  @override
  Future<String> generateReply({
    required String userInput,
    required List<ChatMessage> history,
  }) async {
    if (_apiKey.isEmpty) {
      throw const LlmUnavailableException(
        'OpenRouter API key not set. '
        'Run with --dart-define=OPENROUTER_KEY=your_key',
      );
    }

    final messages = _buildMessages(history: history, userInput: userInput);

    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse(_endpoint),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': _model,
              'messages': messages,
              'max_tokens': ModelConfig.openRouterMaxTokens,
              'temperature': ModelConfig.openRouterTemperature,
            }),
          )
          .timeout(_requestTimeout);
    } catch (e) {
      throw LlmUnavailableException('OpenRouter request failed: $e');
    }

    if (response.statusCode != 200) {
      if (kDebugMode) {
        debugPrint(
          'OpenRouter error ${response.statusCode}: ${response.body}',
        );
      }
      throw LlmUnavailableException(
        'OpenRouter returned HTTP ${response.statusCode}.',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw const LlmUnavailableException('OpenRouter returned no choices.');
    }

    final reply =
        (choices[0] as Map<String, dynamic>)['message']?['content']?.toString().trim() ?? '';

    if (reply.isEmpty) {
      throw const LlmUnavailableException('OpenRouter returned empty content.');
    }

    if (kDebugMode) {
      debugPrint(
        'OpenRouter reply received (chars=${reply.length}, model=$_model).',
      );
    }

    return reply;
  }

  /// Formats history into the OpenAI-compatible message format.
  ///
  /// Strips safe-mode assistant messages so the online model never
  /// sees those canned fallback responses in its context.
  List<Map<String, String>> _buildMessages({
    required List<ChatMessage> history,
    required String userInput,
  }) {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': ModelConfig.systemPrompt},
    ];

    // Include conversation history, excluding safe-mode replies
    for (final msg in history) {
      if (msg.role == MsgRole.assistant &&
          msg.assistantOrigin == AssistantOrigin.safeMode) {
        continue;
      }
      messages.add({
        'role': msg.role == MsgRole.user ? 'user' : 'assistant',
        'content': msg.text,
      });
    }

    // Avoid duplicating the current user input if it's already the last message
    final normalized = userInput.trim();
    if (normalized.isNotEmpty) {
      final alreadyPresent = messages.isNotEmpty &&
          messages.last['role'] == 'user' &&
          messages.last['content'] == normalized;
      if (!alreadyPresent) {
        messages.add({'role': 'user', 'content': normalized});
      }
    }

    return messages;
  }

  @override
  Future<void> dispose() async {
    _client.close();
    _initialized = false;
  }
}
