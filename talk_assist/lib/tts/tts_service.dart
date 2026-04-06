/// Abstract interface for text-to-speech services.
/// Implementations handle model initialization, speech synthesis, and playback.
abstract class TtsService {
  /// Returns true if the TTS service is ready to synthesize speech.
  /// This includes having the voice model downloaded and loaded into memory.
  bool get isReady;

  /// Checks whether the TTS service is ready to synthesize speech.
  /// Returns true if the voice model is available and loaded.
  Future<bool> checkReady();

  /// Initializes the TTS service.
  /// Downloads the voice model if needed and loads it into memory.
  /// Can be called multiple times; subsequent calls are no-ops.
  Future<void> init();

  /// Synthesizes and speaks the given [text].
  /// Stops any current speech before starting the new one.
  /// If the service is not ready, the speech request is silently ignored.
  Future<void> speak(String text);

  // Stops any currently playing speech.
  Future<void> stop();

  /// Releases resources and cleans up.
  /// After disposal, the service cannot be used again.
  Future<void> dispose();
}

/// Exception thrown when TTS synthesis or playback fails.
class TtsException implements Exception {
  const TtsException(this.message);

  final String message;

  @override
  String toString() => "TtsException: $message";
}
