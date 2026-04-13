// This service wraps recording and offline transcription using Sherpa ONNX.
// First check mic permission, make sure model files exist (download if needed),
// then record WAV to a temp file, then pass the WAV to sherpa to get a transcription string.

import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'stt_service.dart';
import 'stt_model_repository.dart';
import 'dart:typed_data';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

class SherpaSttService implements SttService {
  final AudioRecorder _recorder = AudioRecorder();
  final SttModelRepository _modelRepository = SttModelRepository();
  String? _modelDirPath;
  String? _currentPath;
  bool _initialized = false;

  // FIX (Bug 2): store the in-flight init future so that concurrent callers
  // (e.g. background init from initState + user tapping the mic) all await
  // the same work instead of racing to download model files simultaneously.
  Future<void>? _initFuture;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    // FIX (Bug 2): coalesce concurrent calls onto one future.
    return _initFuture ??= _initInternal().whenComplete(() {
      _initFuture = null;
    });
  }

  Future<void> _initInternal() async {
    // Check mic permission and ensure model exists (downloading if needed).
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied');
    }
    await _modelRepository.ensureModelAvailable();

    final modelDir = await _modelRepository.getWhisperTinyEnDirectory();
    _modelDirPath = modelDir.path;

    final ready = await _modelRepository.isModelReady();
    print('STT model ready: $ready');
    final summary = await _modelRepository.getModelStatusSummary();
    print('STT model status: $summary');

    _initialized = true;
  }

  @override
  Future<void> startRecording() async {
    if (!_initialized) {
      await initialize();
    }

    if (await _recorder.isRecording()) return;

    // Create a temp WAV file name in the system temp dir.
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/stt_${DateTime.now().millisecondsSinceEpoch}.wav';

    _currentPath = path;

    // Start recording WAV at 16kHz mono.
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: path,
    );
  }

  @override
  Future<String?> stopRecordingAndTranscribe() async {
    if (!await _recorder.isRecording()) return null;

    // Stop and get the path.
    final path = await _recorder.stop();
    final finalPath = path ?? _currentPath;
    _currentPath = null;

    if (finalPath == null) return null;

    final file = File(finalPath);
    if (!await file.exists()) return null;

    // Hand the WAV file to sherpa_onnx and normalise empty results.
    final text = await _transcribeFile(finalPath);
    return text?.trim().isEmpty == true ? null : text?.trim();
  }

  // Actual transcription using sherpa_onnx.
  Future<String?> _transcribeFile(String wavPath) async {
    if (_modelDirPath == null) {
      throw Exception('STT model directory is not initialized');
    }

    // Get the file paths the model repo provides.
    final expected = await _modelRepository.getExpectedFilePaths();
    final encoder = expected['encoder']!;
    final decoder = expected['decoder']!;
    final tokens = expected['tokens']!;

    print('STT transcribe: wavPath=$wavPath');
    print('STT transcribe: encoder=$encoder');
    print('STT transcribe: decoder=$decoder');
    print('STT transcribe: tokens=$tokens');

    // Read wave then samples + sampleRate.
    final waveData = await sherpa_onnx.readWave(wavPath);
    final samples = waveData.samples;
    final sampleRate = waveData.sampleRate;

    print(
      'STT transcribe: samples=${samples.length}, sampleRate=$sampleRate',
    );

    // Simple config for the offline recognizer.
    final config = sherpa_onnx.OfflineRecognizerConfig(
      model: sherpa_onnx.OfflineModelConfig(
        whisper: sherpa_onnx.OfflineWhisperModelConfig(
          encoder: encoder,
          decoder: decoder,
          language: 'en',
          task: 'transcribe',
        ),
        tokens: tokens,
        debug: true,
        numThreads: 2,
      ),
    );

    final recognizer = sherpa_onnx.OfflineRecognizer(config);
    final stream = recognizer.createStream();

    // Push waveform samples into the recognizer,
    // then decode and grab the text result.
    stream.acceptWaveform(
      samples: Float32List.fromList(samples),
      sampleRate: sampleRate,
    );

    recognizer.decode(stream);

    final result = recognizer.getResult(stream);
    final text = result.text.trim();

    // Free native resources.
    stream.free();
    recognizer.free();

    print('STT transcribe result: $text');

    return text.isEmpty ? null : text;
  }

  @override
  Future<void> cancel() async {
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    _currentPath = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
  }
}
