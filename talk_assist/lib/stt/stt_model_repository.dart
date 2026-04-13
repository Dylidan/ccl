// Handles local storage for the small Whisper model files.
// First creates directories, checks if files exist and are large enough,
// then downloads missing files from the internet using a streaming download
// so large files (encoder ~40MB, decoder ~170MB) don't time out.

import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stt_config.dart';

class SttModelRepository {
  // Get/create the base app document directory for models.
  Future<Directory> getBaseModelDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/${SttConfig.modelDirName}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  // Get/create the specific subdirectory for Whisper tiny.en.
  Future<Directory> getWhisperTinyEnDirectory() async {
    final baseDir = await getBaseModelDirectory();
    final dir = Directory('${baseDir.path}/${SttConfig.modelSubDirName}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> getEncoderFile() async {
    final dir = await getWhisperTinyEnDirectory();
    return File('${dir.path}/${SttConfig.encoderFileName}');
  }

  Future<File> getDecoderFile() async {
    final dir = await getWhisperTinyEnDirectory();
    return File('${dir.path}/${SttConfig.decoderFileName}');
  }

  Future<File> getTokensFile() async {
    final dir = await getWhisperTinyEnDirectory();
    return File('${dir.path}/${SttConfig.tokensFileName}');
  }

  // Quick check: do all three model files exist and meet minimum size?
  Future<bool> isModelReady() async {
    final encoderFile = await getEncoderFile();
    final decoderFile = await getDecoderFile();
    final tokensFile = await getTokensFile();

    final encoderExists = await encoderFile.exists();
    final decoderExists = await decoderFile.exists();
    final tokensExists = await tokensFile.exists();

    if (!encoderExists || !decoderExists || !tokensExists) {
      return false;
    }

    final encoderSize = await encoderFile.length();
    final decoderSize = await decoderFile.length();

    return encoderSize >= SttConfig.minimumEncoderSizeBytes &&
        decoderSize >= SttConfig.minimumDecoderSizeBytes;
  }

  // Return the expected full paths so callers can feed them to the recognizer.
  Future<Map<String, String>> getExpectedFilePaths() async {
    final dir = await getWhisperTinyEnDirectory();
    return {
      'encoder': '${dir.path}/${SttConfig.encoderFileName}',
      'decoder': '${dir.path}/${SttConfig.decoderFileName}',
      'tokens': '${dir.path}/${SttConfig.tokensFileName}',
    };
  }

  Future<String> getModelStatusSummary() async {
    final encoderFile = await getEncoderFile();
    final decoderFile = await getDecoderFile();
    final tokensFile = await getTokensFile();

    final encoderExists = await encoderFile.exists();
    final decoderExists = await decoderFile.exists();
    final tokensExists = await tokensFile.exists();

    int encoderSize = 0;
    int decoderSize = 0;

    if (encoderExists) encoderSize = await encoderFile.length();
    if (decoderExists) decoderSize = await decoderFile.length();

    return 'encoderExists=$encoderExists, decoderExists=$decoderExists, '
        'tokensExists=$tokensExists, encoderSize=$encoderSize, decoderSize=$decoderSize';
  }

  Future<void> saveModelDirectoryPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(SttConfig.prefsModelDirKey, path);
    await prefs.setBool(SttConfig.prefsModelReadyKey, true);
  }

  Future<String?> getSavedModelDirectoryPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(SttConfig.prefsModelDirKey);
    if (path == null || path.isEmpty) return null;
    final dir = Directory(path);
    if (!await dir.exists()) return null;
    return path;
  }

  Future<bool> needsDownload() async {
    return !(await isModelReady());
  }

  // Ensure model files exist locally, downloading any that are missing.
  Future<void> ensureModelAvailable() async {
    final ready = await isModelReady();
    if (ready) {
      final dir = await getWhisperTinyEnDirectory();
      await saveModelDirectoryPath(dir.path);
      return;
    }

    print('STT download: model not ready, starting download...');

    final targetDir = await getWhisperTinyEnDirectory();
    final encoderFile = await getEncoderFile();
    final decoderFile = await getDecoderFile();
    final tokensFile = await getTokensFile();

    await clearSavedModelState();

    try {
      if (!await encoderFile.exists()) {
        print('STT download: downloading encoder...');
        await _downloadFileStreaming(SttConfig.encoderUrl, encoderFile);
      }

      if (!await decoderFile.exists()) {
        print('STT download: downloading decoder...');
        await _downloadFileStreaming(SttConfig.decoderUrl, decoderFile);
      }

      if (!await tokensFile.exists()) {
        print('STT download: downloading tokens...');
        await _downloadFileStreaming(SttConfig.tokensUrl, tokensFile);
      }

      final nowReady = await isModelReady();
      if (!nowReady) {
        throw Exception(
            'STT model files downloaded, but validation still failed');
      }

      await saveModelDirectoryPath(targetDir.path);
      print('STT download: model ready at ${targetDir.path}');
    } catch (e) {
      // Remove any zero-byte partial files so the next attempt starts clean.
      // Non-empty partial files are left in place so they aren't re-downloaded
      // if the app was killed mid-download — isModelReady() uses size checks.
      for (final f in [encoderFile, decoderFile, tokensFile]) {
        if (await f.exists() && await f.length() == 0) {
          await f.delete();
        }
      }
      rethrow;
    }
  }

  Future<void> clearSavedModelState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(SttConfig.prefsModelDirKey);
    await prefs.remove(SttConfig.prefsModelReadyKey);
  }

  // Streaming download helper.
  //
  // WHY: http.get() buffers the entire response body in RAM before returning.
  // The decoder file is ~170 MB, so with a 3-minute wall-clock timeout the
  // download timed out before the buffer finished filling — even on a fast
  // connection — because no bytes were written to disk until http.get()
  // resolved.
  //
  // This implementation uses http.Client.send() with a streamed request so
  // bytes are piped to disk as they arrive. The stall timeout (default 60 s)
  // fires only if *no new bytes* are received for that duration, which is the
  // correct signal for a genuinely broken connection.
  Future<void> _downloadFileStreaming(
      String url,
      File outputFile, {
        Duration stallTimeout = const Duration(seconds: 60),
      }) async {
    print('STT download: streaming GET $url');

    final client = http.Client();
    // Write to a temp file alongside the target so a failed download never
    // leaves a partial file at the expected path (which would fool isModelReady).
    final tmpFile = File('${outputFile.path}.tmp');

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      print('STT download: response status = ${response.statusCode}');
      if (response.statusCode != 200) {
        throw Exception(
            'Failed to download STT file: ${response.statusCode} $url');
      }

      final totalBytes = response.contentLength ?? -1;
      int receivedBytes = 0;

      final sink = tmpFile.openWrite();

      // stallTimer fires if no bytes arrive for stallTimeout.
      // It is reset on every chunk.
      Timer? stallTimer;
      Object? stallError;

      void resetStall() {
        stallTimer?.cancel();
        stallTimer = Timer(stallTimeout, () {
          stallError = Exception(
              'STT download stalled (no data for ${stallTimeout.inSeconds}s): $url');
          sink.close();
        });
      }

      resetStall();

      try {
        await for (final chunk in response.stream) {
          if (stallError != null) break;
          sink.add(chunk);
          receivedBytes += chunk.length;
          resetStall();

          if (totalBytes > 0) {
            final pct = (receivedBytes * 100 ~/ totalBytes).clamp(0, 100);
            final mb = (receivedBytes / 1024 / 1024).toStringAsFixed(1);
            final totalMb = (totalBytes / 1024 / 1024).toStringAsFixed(1);
            print('STT download: $pct% ($mb / $totalMb MB)');
          }
        }
      } finally {
        stallTimer?.cancel();
        await sink.flush();
        await sink.close();
      }

      if (stallError != null) throw stallError!;

      print('STT download: received $receivedBytes bytes, moving to ${outputFile.path}');
      await tmpFile.rename(outputFile.path);
      print('STT download: saved ${outputFile.path}');
    } catch (e) {
      // Clean up the temp file on any error.
      if (await tmpFile.exists()) await tmpFile.delete();
      rethrow;
    } finally {
      client.close();
    }
  }
}
