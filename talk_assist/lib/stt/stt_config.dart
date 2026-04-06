class SttConfig {
  const SttConfig._();

  static const String modelFamily = 'whisper_tiny_en';
  static const String modelDirName = 'stt_models';
  static const String modelSubDirName = 'whisper_tiny_en';

  static const String encoderFileName = 'tiny.en-encoder.int8.onnx';
  static const String decoderFileName = 'tiny.en-decoder.int8.onnx';
  static const String tokensFileName = 'tiny.en-tokens.txt';

  static const String prefsModelDirKey = 'stt_model_dir';
  static const String prefsModelReadyKey = 'stt_model_ready';

  static const int minimumEncoderSizeBytes = 1024 * 1024;
  static const int minimumDecoderSizeBytes = 100 * 1024;

  static const String encoderUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/resolve/main/tiny.en-encoder.int8.onnx';
  static const String decoderUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/resolve/main/tiny.en-decoder.int8.onnx';
  static const String tokensUrl =
      'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/resolve/main/tiny.en-tokens.txt';
}