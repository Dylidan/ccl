import "dart:convert";
import "dart:io";

import "package:flutter/foundation.dart";
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:talk_assist/llm/model_config.dart";

// Callback for download progress updates.
typedef ModelDownloadProgress =
    void Function({required int receivedBytes, required int totalBytes});

// Metadata for a downloaded GGUF model file.
class ModelRecord {
  const ModelRecord({
    required this.path,
    required this.sourceUrl,
    required this.downloadedAtEpochMs,
  });

  // Absolute path to the .gguf file on disk.
  final String path;

  // Where this file was downloaded from, if known.
  final String? sourceUrl;

  // When the file was saved (epoch milliseconds).
  final int downloadedAtEpochMs;
}

/// Manages the Qwen3.5-0.8B GGUF model file lifecycle for [LlamadartLlmService].
/// Checks [SharedPreferences] for a previously-configured path,
/// discovers .gguf files in the models directory, or downloads from
/// HuggingFace. Validates GGUF headers before accepting files.
class ModelRepository {
  static const String _modelPathKey = "llm.model.path";
  static const String _modelSourceUrlKey = "llm.model.source_url";
  static const String _downloadedAtKey = "llm.model.downloaded_at";

  /// Reads the persisted model path from [SharedPreferences] and verifies
  /// the file still exists on disk.
  Future<ModelRecord?> getConfiguredModel() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_modelPathKey);
    if (path == null || path.isEmpty) {
      return null;
    }

    final file = File(path);
    if (!await file.exists()) {
      return null;
    }

    return ModelRecord(
      path: path,
      sourceUrl: prefs.getString(_modelSourceUrlKey),
      downloadedAtEpochMs:
          prefs.getInt(_downloadedAtKey) ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  // Cascading strategy to obtain a valid model file.
  // 1. Returns already-configured model if still valid.
  // 2. Discovers any .gguf file in the models directory.
  // 3. Downloads from HuggingFace if nothing found locally.
  Future<ModelRecord?> ensureModelAvailable({
    ModelDownloadProgress? onProgress,
  }) async {
    final configured = await getConfiguredModel();
    if (configured != null && await _isValidModelFile(File(configured.path))) {
      if (kDebugMode) {
        final filename = configured.path.split("/").last;
        debugPrint("Model cache hit: $filename");
      }
      return configured;
    }

    final discovered = await _discoverLocalModel();
    if (discovered != null) {
      await _persist(
        path: discovered.path,
        sourceUrl: discovered.sourceUrl,
        downloadedAtEpochMs: discovered.downloadedAtEpochMs,
      );
      if (kDebugMode) {
        final filename = discovered.path.split("/").last;
        debugPrint("Model discovered locally: $filename");
      }
      return discovered;
    }

    final downloadUri = await resolveDownloadUri();
    if (kDebugMode) {
      debugPrint("Model download started (url=$downloadUri).");
    }
    return _downloadModel(downloadUri, onProgress: onProgress);
  }

  /// Determines where to download the model from.
  /// Queries the official HuggingFace API for GGUF files, falling back to a hardcoded URL if the API fails.
  Future<Uri> resolveDownloadUri() async {
    final officialUri = await _resolveOfficialGgufUri();
    if (officialUri != null) {
      return officialUri;
    }
    return Uri.parse(ModelConfig.fallbackGgufUrl);
  }

  Future<void> clearConfiguredModel() async {
    final model = await getConfiguredModel();
    if (model != null) {
      final file = File(model.path);
      if (await file.exists()) {
        await file.delete();
      }
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_modelPathKey);
    await prefs.remove(_modelSourceUrlKey);
    await prefs.remove(_downloadedAtKey);
  }

  Future<ModelRecord?> _discoverLocalModel() async {
    final modelDir = await _modelDirectory();
    if (!await modelDir.exists()) {
      return null;
    }

    final files = <File>[];
    await for (final entry in modelDir.list(followLinks: false)) {
      if (entry is! File) {
        continue;
      }
      if (!entry.path.toLowerCase().endsWith(
        ".${ModelConfig.modelExtension}",
      )) {
        continue;
      }
      files.add(entry);
    }

    if (files.isEmpty) {
      return null;
    }

    files.sort((a, b) => b.path.compareTo(a.path));

    for (final file in files) {
      if (!await _isValidModelFile(file)) {
        continue;
      }
      return ModelRecord(
        path: file.path,
        sourceUrl: null,
        downloadedAtEpochMs: (await file.lastModified()).millisecondsSinceEpoch,
      );
    }

    return null;
  }

  Future<Uri?> _resolveOfficialGgufUri() async {
    final client = HttpClient();
    try {
      final apiUri = Uri.parse(ModelConfig.officialModelApiUrl);
      final request = await client.getUrl(apiUri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }

      final body = await utf8.decoder.bind(response).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final siblings = decoded["siblings"];
      if (siblings is! List) {
        return null;
      }

      final ggufFiles = <String>[];
      for (final sibling in siblings) {
        if (sibling is! Map) {
          continue;
        }
        final siblingMap = Map<String, dynamic>.from(sibling);
        final fileName = siblingMap["rfilename"]?.toString();
        if (fileName == null || fileName.isEmpty) {
          continue;
        }
        if (fileName.toLowerCase().endsWith(".${ModelConfig.modelExtension}")) {
          ggufFiles.add(fileName);
        }
      }

      if (ggufFiles.isEmpty) {
        return null;
      }

      ggufFiles.sort((a, b) {
        final aPreferred = a.toLowerCase().contains(
          ModelConfig.preferredQuantizationHint,
        );
        final bPreferred = b.toLowerCase().contains(
          ModelConfig.preferredQuantizationHint,
        );
        if (aPreferred == bPreferred) {
          return a.compareTo(b);
        }
        return aPreferred ? -1 : 1;
      });

      final selectedFile = ggufFiles.first;
      return _buildResolveUri(
        repoId: ModelConfig.officialRepoId,
        fileName: selectedFile,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Uri _buildResolveUri({required String repoId, required String fileName}) {
    final encodedRepo = repoId.split("/").map(Uri.encodeComponent).join("/");
    final encodedFile = fileName.split("/").map(Uri.encodeComponent).join("/");
    return Uri.parse(
      "https://huggingface.co/$encodedRepo/resolve/main/$encodedFile",
    );
  }

  Future<ModelRecord> _downloadModel(
    Uri downloadUri, {
    ModelDownloadProgress? onProgress,
  }) async {
    final destination = await _destinationModelFile();
    final partialFile = File("${destination.path}.part");
    final client = HttpClient();
    IOSink? sink;

    try {
      if (await partialFile.exists()) {
        await partialFile.delete();
      }

      final request = await client.getUrl(downloadUri);
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          "Model download failed with HTTP ${response.statusCode}.",
          uri: downloadUri,
        );
      }

      sink = partialFile.openWrite();
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
      sink = null;

      if (await destination.exists()) {
        await destination.delete();
      }
      await partialFile.rename(destination.path);

      await _validateGgufFile(destination);

      final record = ModelRecord(
        path: destination.path,
        sourceUrl: downloadUri.toString(),
        downloadedAtEpochMs: DateTime.now().millisecondsSinceEpoch,
      );

      await _persist(
        path: record.path,
        sourceUrl: record.sourceUrl,
        downloadedAtEpochMs: record.downloadedAtEpochMs,
      );

      return record;
    } catch (_) {
      if (sink != null) {
        await sink.close();
      }
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _persist({
    required String path,
    required String? sourceUrl,
    required int downloadedAtEpochMs,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modelPathKey, path);
    await prefs.setInt(_downloadedAtKey, downloadedAtEpochMs);
    if (sourceUrl == null || sourceUrl.isEmpty) {
      await prefs.remove(_modelSourceUrlKey);
    } else {
      await prefs.setString(_modelSourceUrlKey, sourceUrl);
    }
  }

  Future<File> _destinationModelFile() async {
    final directory = await _modelDirectory();
    await directory.create(recursive: true);
    return File("${directory.path}/${ModelConfig.preferredModelFileName}");
  }

  Future<Directory> _modelDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory("${appDir.path}/${ModelConfig.modelDirectoryName}");
  }

  Future<bool> _isValidModelFile(File file) async {
    try {
      await _validateGgufFile(file);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Validates that a file looks like a valid GGUF model.
  /// Checks minimum 64MB size and "GGUF" magic header bytes.
  Future<void> _validateGgufFile(File file) async {
    final sizeBytes = await file.length();
    if (sizeBytes < ModelConfig.minimumModelSizeBytes) {
      throw FormatException(
        "Invalid GGUF file: expected at least ${ModelConfig.minimumModelSizeBytes} bytes.",
      );
    }

    final raf = await file.open();
    try {
      final header = await raf.read(4);
      if (header.length < 4) {
        throw const FormatException("Invalid GGUF file: header is too short.");
      }
      final magic = String.fromCharCodes(header);
      if (magic != "GGUF") {
        throw const FormatException("Invalid GGUF file header.");
      }
    } finally {
      await raf.close();
    }
  }
}
