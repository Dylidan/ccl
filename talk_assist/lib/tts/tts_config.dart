/// Central configuration for the Piper TTS voice model.
/// All tunable parameters live here so changes are isolated to one file.
/// This is the single source of truth for voice identity, model URLs, and synthesis settings.
class TtsConfig {
  const TtsConfig._();

  // Human-readable voice name for UI display.
  static const String voiceDisplayName = "Amy";

  // Piper voice model identity.
  static const String voiceModelName = "en_US-amy-low";
  static const String voiceLocale = "en_US";

  // Model download URL from sherpa-onnx releases.
  // Format: https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-{modelName}.tar.bz2
  static const String modelDownloadUrl =
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-amy-low.tar.bz2";

  // File names after extraction.
  static const String onnxModelFileName = "en_US-amy-low.onnx";
  static const String tokensFileName = "tokens.txt";
  static const String espeakDataDirName = "espeak-ng-data";

  // Directory names.
  static const String ttsModelDirectoryName = "tts_models";

  // Minimum expected total size for the extracted model (~61MB).
  static const int minimumModelSizeBytes = 61 * 1024 * 1024;

  // Estimated time to show in UI for first-time model download.
  static const Duration firstSetupEstimate = Duration(minutes: 1);

  /// TTS synthesis settings.
  /// Number of CPU threads for synthesis.
  static const int synthesisThreads = 2;

  // Speech speed multiplier (1.0 = normal, 0.5 = half speed, 2.0 = double speed).
  static const double speechSpeed = 1.0;

  // Speaker ID (0 for single-speaker models).
  static const int speakerId = 0;

  // Provider configuration.
  static const String onnxProvider = "cpu";
  static const bool debugMode = false;

  // Max sentences per generation call.
  static const int maxNumSentences = 1;
}
