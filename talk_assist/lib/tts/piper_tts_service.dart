import "dart:async";
import "dart:io";
import "dart:isolate";

import "package:audioplayers/audioplayers.dart";
import "package:flutter/foundation.dart";
import "package:path_provider/path_provider.dart";
import "package:sherpa_onnx/sherpa_onnx.dart" as sherpa_onnx;
import "package:talk_assist/tts/tts_config.dart";
import "package:talk_assist/tts/tts_model_repository.dart";
import "package:talk_assist/tts/tts_service.dart";

// Isolate message for speech generation.
class _SpeechGenerationRequest {
  const _SpeechGenerationRequest({
    required this.text,
    required this.modelPath,
    required this.tokensPath,
    required this.espeakDataDir,
    required this.outputPath,
    required this.speed,
    required this.speakerId,
    required this.numThreads,
  });

  final String text;
  final String modelPath;
  final String tokensPath;
  final String espeakDataDir;
  final String outputPath;
  final double speed;
  final int speakerId;
  final int numThreads;
}

// Isolate response for speech generation.
class _SpeechGenerationResponse {
  const _SpeechGenerationResponse({
    this.success = false,
    this.error,
    this.sampleRate,
  });

  final bool success;
  final String? error;
  final int? sampleRate;
}

/// Piper TTS implementation using sherpa_onnx.
/// Downloads the voice model on first use and caches it locally.
/// Generates speech on an Isolate to avoid blocking the UI thread.
class PiperTtsService implements TtsService {
  PiperTtsService({
    TtsModelRepository? modelRepository,
    AudioPlayer? audioPlayer,
  }) : _modelRepository = modelRepository ?? TtsModelRepository(),
       _audioPlayer = audioPlayer ?? AudioPlayer();

  final TtsModelRepository _modelRepository;
  final AudioPlayer _audioPlayer;

  TtsModelRecord? _modelRecord;
  bool _initialized = false;
  bool _disposed = false;
  bool _isSpeaking = false;

  // FIX (Bug 1): replaced _initCompleter with an in-progress flag + nullable
  // future so that a failed init can be retried, and concurrent callers all
  // await the same in-flight future instead of spawning duplicate work.
  bool _initInProgress = false;
  Future<void>? _initFuture;

  @override
  bool get isReady => _initialized && _modelRecord != null;

  @override
  Future<bool> checkReady() async {
    if (_disposed) return false;
    if (_initialized) return true;

    // If init is in flight, wait for it (with a timeout).
    final inFlight = _initFuture;
    if (inFlight != null) {
      try {
        await inFlight.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw TimeoutException("TTS init check timeout"),
        );
        return _initialized;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  @override
  Future<void> init() async {
    if (_disposed) {
      throw StateError("PiperTtsService has been disposed");
    }

    if (_initialized) {
      if (kDebugMode) debugPrint("TTS: Already initialized, skipping");
      return;
    }

    // FIX (Bug 1): if a prior attempt is in flight, return that same future
    // so callers coalesce instead of racing.
    if (_initInProgress) {
      if (kDebugMode) debugPrint("TTS: Initialization already in progress");
      return _initFuture!;
    }

    // FIX (Bug 1): store the future and set the in-progress flag so that:
    //   - concurrent callers await the same work
    //   - a failed attempt clears _initInProgress so the next call can retry
    _initInProgress = true;
    _initFuture = _initInternal();

    try {
      await _initFuture!;
    } finally {
      _initInProgress = false;
      _initFuture = null;
    }
  }

  Future<void> _initInternal() async {
    if (kDebugMode) debugPrint("TTS: Starting initialization...");

    try {
      if (kDebugMode) debugPrint("TTS: Checking/downloading voice model...");

      final record = await _modelRepository.ensureModelAvailable();

      if (record == null) {
        if (kDebugMode) debugPrint("TTS ERROR: Failed to obtain TTS voice model");
        throw TtsException("Failed to obtain TTS voice model");
      }

      _modelRecord = record;
      _initialized = true;

      if (kDebugMode) {
        debugPrint("TTS: Voice model ready");
        debugPrint("TTS:   Model path: ${record.modelPath}");
        debugPrint("TTS:   Tokens path: ${record.tokensPath}");
        debugPrint("TTS:   Espeak dir: ${record.espeakDataDir}");
        debugPrint("TTS: Initialization complete - READY TO SPEAK");
      }
    } catch (e) {
      if (kDebugMode) debugPrint("TTS ERROR: Initialization failed - $e");
      // FIX (Bug 1): just rethrow — _initInProgress is cleared in the
      // finally block of init(), allowing the next call to retry.
      rethrow;
    }
  }

  @override
  Future<void> speak(String text) async {
    if (_disposed) {
      if (kDebugMode) debugPrint("TTS SPEAK: Skipped - service disposed");
      return;
    }

    if (text.trim().isEmpty) {
      if (kDebugMode) debugPrint("TTS SPEAK: Skipped - empty text");
      return;
    }

    if (kDebugMode) {
      debugPrint(
        "TTS SPEAK: Requested to speak: \"${text.substring(0, text.length > 50 ? 50 : text.length)}...\"",
      );
      debugPrint("TTS SPEAK: Current ready state: $_initialized");
    }

    // Trigger or wait for init if not yet ready.
    if (!_initialized) {
      if (kDebugMode) debugPrint("TTS SPEAK: Not ready yet, waiting for initialization...");
      try {
        await init().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw TtsException("TTS initialization timed out");
          },
        );
        if (kDebugMode) debugPrint("TTS SPEAK: Initialization completed while waiting");
      } catch (e) {
        if (kDebugMode) debugPrint("TTS SPEAK: SKIPPED - TTS not ready: $e");
        return;
      }
    }

    if (_modelRecord == null) {
      if (kDebugMode) debugPrint("TTS SPEAK: SKIPPED - no model record available");
      return;
    }

    if (_isSpeaking) {
      if (kDebugMode) debugPrint("TTS SPEAK: Stopping current speech");
      await stop();
    }

    _isSpeaking = true;
    if (kDebugMode) debugPrint("TTS SPEAK: Starting speech generation...");

    try {
      final tempDir = await getTemporaryDirectory();
      final outputPath =
          "${tempDir.path}/tts_output_${DateTime.now().millisecondsSinceEpoch}.wav";

      if (kDebugMode) debugPrint("TTS SPEAK: Output path: $outputPath");

      final request = _SpeechGenerationRequest(
        text: text,
        modelPath: _modelRecord!.modelPath,
        tokensPath: _modelRecord!.tokensPath,
        espeakDataDir: _modelRecord!.espeakDataDir,
        outputPath: outputPath,
        speed: TtsConfig.speechSpeed,
        speakerId: TtsConfig.speakerId,
        numThreads: TtsConfig.synthesisThreads,
      );

      if (kDebugMode) debugPrint("TTS SPEAK: Running generation on isolate...");

      final response = await Isolate.run(() => _generateSpeech(request));

      if (!response.success) {
        if (kDebugMode) debugPrint("TTS SPEAK: FAILED - ${response.error}");
        throw TtsException(response.error ?? "Speech generation failed");
      }

      if (kDebugMode) {
        debugPrint(
          "TTS SPEAK: Audio generated successfully (sampleRate: ${response.sampleRate})",
        );
        debugPrint("TTS SPEAK: Playing audio...");
      }

      await _audioPlayer.play(DeviceFileSource(outputPath));

      if (kDebugMode) debugPrint("TTS SPEAK: Audio playback started");

      // FIX (Bug 5): delete the temp file only after playback completes,
      // not on a fixed 5-second timer that can fire mid-playback.
      unawaited(
        _audioPlayer.onPlayerComplete.first.then((_) => _cleanupTempFile(outputPath)),
      );
    } catch (e) {
      if (kDebugMode) debugPrint("TTS SPEAK: ERROR - $e");
      // Silently ignore — text is still shown in the UI.
    } finally {
      _isSpeaking = false;
      if (kDebugMode) debugPrint("TTS SPEAK: Done");
    }
  }

  @override
  Future<void> stop() async {
    if (_isSpeaking) {
      await _audioPlayer.stop();
      _isSpeaking = false;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
    await _audioPlayer.dispose();
  }

  Future<void> _cleanupTempFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Ignore cleanup errors.
    }
  }

  // Static method to run on isolate.
  static _SpeechGenerationResponse _generateSpeech(
    _SpeechGenerationRequest request,
  ) {
    try {
      sherpa_onnx.initBindings();

      final vits = sherpa_onnx.OfflineTtsVitsModelConfig(
        model: request.modelPath,
        tokens: request.tokensPath,
        dataDir: request.espeakDataDir,
      );

      final modelConfig = sherpa_onnx.OfflineTtsModelConfig(
        vits: vits,
        numThreads: request.numThreads,
        debug: TtsConfig.debugMode,
        provider: TtsConfig.onnxProvider,
      );

      final config = sherpa_onnx.OfflineTtsConfig(
        model: modelConfig,
        maxNumSenetences: TtsConfig.maxNumSentences,
      );

      final tts = sherpa_onnx.OfflineTts(config);

      final audio = tts.generate(
        text: request.text,
        sid: request.speakerId,
        speed: request.speed,
      );

      final success = sherpa_onnx.writeWave(
        filename: request.outputPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );

      tts.free();

      if (!success) {
        return const _SpeechGenerationResponse(
          success: false,
          error: "Failed to write WAV file",
        );
      }

      return _SpeechGenerationResponse(
        success: true,
        sampleRate: audio.sampleRate,
      );
    } catch (e) {
      return _SpeechGenerationResponse(success: false, error: e.toString());
    }
  }
}
