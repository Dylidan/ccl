import "dart:io";

import "package:archive/archive_io.dart";
import "package:flutter/foundation.dart";
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:talk_assist/tts/tts_config.dart";

// Callback for download progress updates.
typedef TtsModelDownloadProgress =
    void Function({required int receivedBytes, required int totalBytes});

// Metadata for a downloaded Piper TTS model.
class TtsModelRecord {
  const TtsModelRecord({
    required this.modelPath,
    required this.tokensPath,
    required this.espeakDataDir,
    required this.sourceUrl,
    required this.downloadedAtEpochMs,
  });

  // Absolute path to the .onnx model file.
  final String modelPath;

  // Absolute path to the tokens.txt file.
  final String tokensPath;

  // Absolute path to the espeak-ng-data directory.
  final String espeakDataDir;

  // Where this model was downloaded from, if known.
  final String? sourceUrl;

  // When the model was saved (epoch milliseconds).
  final int downloadedAtEpochMs;
}

/// Manages the Piper TTS voice model file lifecycle.
/// Checks [SharedPreferences] for a previously-configured path,
/// discovers model files in the TTS models directory, or downloads from
/// sherpa-onnx releases.
class TtsModelRepository {
  static const String _modelPathKey = "tts.model.onnx_path";
  static const String _tokensPathKey = "tts.model.tokens_path";
  static const String _espeakDirKey = "tts.model.espeak_dir";
  static const String _modelSourceUrlKey = "tts.model.source_url";
  static const String _downloadedAtKey = "tts.model.downloaded_at";

  /// Reads the persisted model paths from [SharedPreferences] and verifies
  /// the files still exist on disk.
  Future<TtsModelRecord?> getConfiguredModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelPath = prefs.getString(_modelPathKey);
    final tokensPath = prefs.getString(_tokensPathKey);
    final espeakDir = prefs.getString(_espeakDirKey);

    if (modelPath == null ||
        modelPath.isEmpty ||
        tokensPath == null ||
        tokensPath.isEmpty ||
        espeakDir == null ||
        espeakDir.isEmpty) {
      return null;
    }

    final modelFile = File(modelPath);
    final tokensFile = File(tokensPath);
    final espeakDirFile = Directory(espeakDir);

    if (!await modelFile.exists() ||
        !await tokensFile.exists() ||
        !await espeakDirFile.exists()) {
      return null;
    }

    return TtsModelRecord(
      modelPath: modelPath,
      tokensPath: tokensPath,
      espeakDataDir: espeakDir,
      sourceUrl: prefs.getString(_modelSourceUrlKey),
      downloadedAtEpochMs:
          prefs.getInt(_downloadedAtKey) ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  // Cascading strategy to obtain a valid model.
  // 1. Returns already-configured model if still valid.
  // 2. Discovers any model files in the TTS models directory.
  // 3. Downloads from sherpa-onnx releases if nothing found locally.
  Future<TtsModelRecord?> ensureModelAvailable({
    TtsModelDownloadProgress? onProgress,
  }) async {
    if (kDebugMode) {
      debugPrint("TTS MODEL: Checking for voice model...");
    }

    final configured = await getConfiguredModel();
    if (configured != null && await _isValidModel(configured)) {
      if (kDebugMode) {
        final filename = configured.modelPath.split("/").last;
        debugPrint("TTS MODEL: Cache hit - $filename");
      }
      return configured;
    }

    if (kDebugMode) {
      debugPrint("TTS MODEL: No cached model found, checking local files...");
    }

    final discovered = await _discoverLocalModel();
    if (discovered != null) {
      await _persist(
        modelPath: discovered.modelPath,
        tokensPath: discovered.tokensPath,
        espeakDataDir: discovered.espeakDataDir,
        sourceUrl: discovered.sourceUrl,
        downloadedAtEpochMs: discovered.downloadedAtEpochMs,
      );
      if (kDebugMode) {
        final filename = discovered.modelPath.split("/").last;
        debugPrint("TTS MODEL: Discovered locally - $filename");
      }
      return discovered;
    }

    final downloadUri = Uri.parse(TtsConfig.modelDownloadUrl);
    if (kDebugMode) {
      debugPrint("TTS MODEL: Downloading voice model from:");
      debugPrint("  $downloadUri");
      debugPrint("TTS MODEL: This may take a minute (~61MB)...");
    }

    // Wrap the progress callback to add logging
    TtsModelDownloadProgress? wrappedProgress;
    if (onProgress != null || kDebugMode) {
      final downloadStartedAt = DateTime.now();
      var lastLoggedBucket = 0;
      var didLogCompletion = false;
      wrappedProgress = ({required int receivedBytes, required int totalBytes}) {
        onProgress?.call(receivedBytes: receivedBytes, totalBytes: totalBytes);

        if (!kDebugMode || totalBytes <= 0) {
          return;
        }

        final percent = (receivedBytes * 100 ~/ totalBytes).clamp(0, 100);
        final bucket = (percent ~/ 10) * 10;
        final shouldLogBucket = bucket >= 10 && bucket > lastLoggedBucket;

        if (shouldLogBucket) {
          lastLoggedBucket = bucket;
          final receivedMB = (receivedBytes / 1024 / 1024).toStringAsFixed(1);
          final totalMB = (totalBytes / 1024 / 1024).toStringAsFixed(1);
          final elapsed = DateTime.now().difference(downloadStartedAt);
          final elapsedStr = "${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s";
          debugPrint(
            "TTS MODEL: Download progress $bucket% ($receivedMB MB / $totalMB MB) [elapsed: $elapsedStr]",
          );
        }

        if (percent >= 100 && !didLogCompletion) {
          didLogCompletion = true;
          final total = DateTime.now().difference(downloadStartedAt);
          debugPrint(
            "TTS MODEL: Download complete in ${total.inMinutes}m ${total.inSeconds % 60}s",
          );
        }
      };
    }

    return _downloadModel(downloadUri, onProgress: wrappedProgress);
  }

  Future<void> clearConfiguredModel() async {
    final model = await getConfiguredModel();
    if (model != null) {
      final dir = Directory(model.modelPath).parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_modelPathKey);
    await prefs.remove(_tokensPathKey);
    await prefs.remove(_espeakDirKey);
    await prefs.remove(_modelSourceUrlKey);
    await prefs.remove(_downloadedAtKey);
  }

  Future<TtsModelRecord?> _discoverLocalModel() async {
    final modelDir = await _modelDirectory();
    if (!await modelDir.exists()) {
      return null;
    }

    final voiceDir = Directory("${modelDir.path}/${TtsConfig.voiceModelName}");
    if (!await voiceDir.exists()) {
      return null;
    }

    final modelFile = File("${voiceDir.path}/${TtsConfig.onnxModelFileName}");
    final tokensFile = File("${voiceDir.path}/${TtsConfig.tokensFileName}");
    final espeakDir = Directory(
      "${voiceDir.path}/${TtsConfig.espeakDataDirName}",
    );

    if (!await modelFile.exists() ||
        !await tokensFile.exists() ||
        !await espeakDir.exists()) {
      return null;
    }

    return TtsModelRecord(
      modelPath: modelFile.path,
      tokensPath: tokensFile.path,
      espeakDataDir: espeakDir.path,
      sourceUrl: null,
      downloadedAtEpochMs:
          (await voiceDir.stat()).modified.millisecondsSinceEpoch,
    );
  }

  Future<TtsModelRecord> _downloadModel(
    Uri downloadUri, {
    TtsModelDownloadProgress? onProgress,
  }) async {
    final modelDir = await _modelDirectory();
    final archiveFile = File("${modelDir.path}/voice.tar.bz2");
    final extractDir = Directory(
      "${modelDir.path}/${TtsConfig.voiceModelName}",
    );

    final client = HttpClient();
    final downloadStartTime = DateTime.now();

    try {
      // Ensure the model directory exists before writing the archive.
      await modelDir.create(recursive: true);

      // Download the archive.
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }

      final request = await client.getUrl(downloadUri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          "TTS model download failed with HTTP ${response.statusCode}.",
          uri: downloadUri,
        );
      }

      final sink = archiveFile.openWrite();
      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : -1;
      var receivedBytes = 0;
      onProgress?.call(receivedBytes: 0, totalBytes: totalBytes);

      await for (final chunk in response) {
        sink.add(chunk);
        receivedBytes += chunk.length;
        onProgress?.call(receivedBytes: receivedBytes, totalBytes: totalBytes);
      }

      await sink.flush();
      await sink.close();

      // Extract the archive.
      if (kDebugMode) {
        debugPrint("TTS MODEL: Extracting archive...");
      }

      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      await extractDir.create(recursive: true);

      await _extractTarBz2(archiveFile, extractDir);

      if (kDebugMode) {
        debugPrint("TTS MODEL: Extraction complete");
      }

      // Find the extracted files.
      final modelFile = File(
        "${extractDir.path}/${TtsConfig.onnxModelFileName}",
      );
      final tokensFile = File("${extractDir.path}/${TtsConfig.tokensFileName}");
      final espeakDir = Directory(
        "${extractDir.path}/${TtsConfig.espeakDataDirName}",
      );

      if (!await modelFile.exists() ||
          !await tokensFile.exists() ||
          !await espeakDir.exists()) {
        throw const FormatException(
          "TTS model archive missing required files.",
        );
      }

      // Validate the model size.
      await _validateModelSize(modelFile, tokensFile, espeakDir);

      // Cleanup archive.
      await archiveFile.delete();

      if (kDebugMode) {
        final elapsedSec = DateTime.now()
            .difference(downloadStartTime)
            .inSeconds;
        debugPrint("TTS MODEL: Download complete (elapsedSec=$elapsedSec)");
      }

      final record = TtsModelRecord(
        modelPath: modelFile.path,
        tokensPath: tokensFile.path,
        espeakDataDir: espeakDir.path,
        sourceUrl: downloadUri.toString(),
        downloadedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      await _persist(
        modelPath: record.modelPath,
        tokensPath: record.tokensPath,
        espeakDataDir: record.espeakDataDir,
        sourceUrl: record.sourceUrl,
        downloadedAtEpochMs: record.downloadedAtEpochMs,
      );

      return record;
    } catch (e) {
      if (kDebugMode) {
        debugPrint("TTS MODEL: Download failed - $e");
      }
      // Cleanup on failure.
      if (await archiveFile.exists()) {
        await archiveFile.delete();
      }
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _extractTarBz2(File archive, Directory destination) async {
    // Read the bz2 compressed archive.
    final bz2Bytes = await archive.readAsBytes();
    final tarBytes = BZip2Decoder().decodeBytes(bz2Bytes);

    // Decode the tar archive.
    final archiveObj = TarDecoder().decodeBytes(tarBytes);

    // Extract all files from the archive.
    for (final file in archiveObj.files) {
      if (!file.isFile) continue;

      // Get the relative path within the archive (skip the top-level directory).
      String relativePath = file.name;
      final pathParts = relativePath.split('/');
      if (pathParts.length > 1) {
        // Remove the top-level directory (e.g., "vits-piper-en_US-amy-low/")
        relativePath = pathParts.sublist(1).join('/');
      }

      final filePath = "${destination.path}/$relativePath";
      final outputFile = File(filePath);

      // Ensure parent directory exists.
      await outputFile.parent.create(recursive: true);

      // Write the file.
      await outputFile.writeAsBytes(file.content as List<int>);
    }

    if (kDebugMode) {
      debugPrint("TTS MODEL: Extracted ${archiveObj.files.length} files");
    }
  }

  Future<void> _persist({
    required String modelPath,
    required String tokensPath,
    required String espeakDataDir,
    required String? sourceUrl,
    required int downloadedAtEpochMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelPathKey, modelPath);
    await prefs.setString(_tokensPathKey, tokensPath);
    await prefs.setString(_espeakDirKey, espeakDataDir);
    await prefs.setInt(_downloadedAtKey, downloadedAtEpochMs);
    if (sourceUrl == null || sourceUrl.isEmpty) {
      await prefs.remove(_modelSourceUrlKey);
    } else {
      await prefs.setString(_modelSourceUrlKey, sourceUrl);
    }
  }

  Future<Directory> _modelDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory("${appDir.path}/${TtsConfig.ttsModelDirectoryName}");
  }

  Future<bool> _isValidModel(TtsModelRecord record) async {
    try {
      await _validateModelSize(
        File(record.modelPath),
        File(record.tokensPath),
        Directory(record.espeakDataDir),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _validateModelSize(
    File modelFile,
    File tokensFile,
    Directory espeakDir,
  ) async {
    var totalSize = 0;
    totalSize += await modelFile.length();
    totalSize += await tokensFile.length();

    await for (final entry in espeakDir.list(recursive: true)) {
      if (entry is File) {
        totalSize += await entry.length();
      }
    }

    if (totalSize < TtsConfig.minimumModelSizeBytes) {
      throw FormatException(
        "Invalid TTS model: expected at least ${TtsConfig.minimumModelSizeBytes} bytes, got $totalSize.",
      );
    }
  }
}
