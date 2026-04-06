import "package:talk_assist/message.dart";

/// Abstract interface for any LLM backend.
/// Decouples the orchestrator from the specific inference engine.
/// Both [LlamadartLlmService] (on-device) and [SafeModeLlmService] (fallback)
/// implement this contract.
abstract class LlmService {
  // Prepare the service for use. May be a no-op for stateless implementations.
  Future<void> init();

  // Whether the service is ready to accept generation requests.
  Future<bool> isReady();

  // Generate a reply for the given user input and conversation history.
  // Throws [LlmUnavailableException] if the LLM cannot produce a reply.
  Future<String> generateReply({
    required String userInput,
    required List<ChatMessage> history,
  });

  // Release any native resources or background tasks.
  Future<void> dispose();
}

/// Exception thrown when the LLM cannot produce a reply.
/// Signals the [LlmOrchestrator] to fall back to safe-mode.
class LlmUnavailableException implements Exception {
  const LlmUnavailableException(this.message);

  final String message;

  @override
  String toString() => "LlmUnavailableException: $message";
}
