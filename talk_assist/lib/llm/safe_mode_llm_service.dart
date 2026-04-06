import "package:talk_assist/llm/llm_service.dart";
import "package:talk_assist/llm/model_config.dart";
import "package:talk_assist/message.dart";

/// Fallback LLM service that returns canned responses.
/// Used when the on-device Qwen3.5 model is not ready yet (still
/// downloading or initializing). Never touches native code or network.
class SafeModeLlmService implements LlmService {
  bool _initialized = false;

  @override
  Future<void> init() async {
    _initialized = true;
  }

  @override
  Future<bool> isReady() async => _initialized;

  /// Returns a canned status message for empty input, or echoes back the user's
  /// words with a "still setting up" note for non-empty input.
  @override
  Future<String> generateReply({
    required String userInput,
    required List<ChatMessage> history,
  }) async {
    if (!_initialized) {
      await init();
    }

    final normalized = userInput.trim();
    if (normalized.isEmpty) {
      return ModelConfig.safeModeStatusMessage;
    }

    return "I heard: \"$normalized\". ${ModelConfig.safeModeStatusMessage} "
        "I saved your request and I will answer it as soon as setup is finished.";
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
  }
}
