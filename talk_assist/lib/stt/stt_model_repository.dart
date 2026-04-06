//Handles local storage for the small Whisper model files
//First creates directories, checks if files exist and are large enough,
//Then downloads missing files from the internet

import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stt_config.dart';

class SttModelRepository {
    //get/create the base app document directory of models
    Future<Directory> getBaseModelDirectory() async {
        final appDir = await getApplicationDocumentsDirectory();
        final dir = Directory('${appDir.path}/${SttConfig.modelDirName}');
        if (!await dir.exists()) {
        await dir.create(recursive: true);
        }
        return dir;
    }

    //Get/create the specific subdirectory for the Whisper tiny
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

    //Quick check for encoder/decoder/tokens file
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

    //Return the expected full paths for encoder/decoder/tokens
    //so other code can feed them straight into the native recognizer.
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

        if (encoderExists) {
        encoderSize = await encoderFile.length();
        }
        if (decoderExists) {
        decoderSize = await decoderFile.length();
        }

        return 'encoderExists=$encoderExists, decoderExists=$decoderExists, tokensExists=$tokensExists, encoderSize=$encoderSize, decoderSize=$decoderSize';
    }

    //Save the path for SharedPreferences 
    Future<void> saveModelDirectoryPath(String path) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(SttConfig.prefsModelDirKey, path);
        await prefs.setBool(SttConfig.prefsModelReadyKey, true);
    }

    //Return the previously saved model directory if it still exists
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

    //Ensure that the model files exist locally,downlaod if missing
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

        // clear any saved state 
        await clearSavedModelState();

        try {
            if (!await encoderFile.exists()) {
            print('STT download: downloading encoder...');
            await _downloadFile(SttConfig.encoderUrl, encoderFile);
            }

            if (!await decoderFile.exists()) {
            print('STT download: downloading decoder...');
            await _downloadFile(SttConfig.decoderUrl, decoderFile);
            }

            if (!await tokensFile.exists()) {
            print('STT download: downloading tokens...');
            await _downloadFile(SttConfig.tokensUrl, tokensFile);
            }

            final nowReady = await isModelReady();
            if (!nowReady) {
            throw Exception('STT model files downloaded, but validation still failed');
            }

            await saveModelDirectoryPath(targetDir.path);
            print('STT download: model ready at ${targetDir.path}');
        } catch (e) {
            // if a file was created but is empty, remove it so next attempt is clean
            if (await encoderFile.exists() && await encoderFile.length() == 0) {
            await encoderFile.delete();
            }
            if (await decoderFile.exists() && await decoderFile.length() == 0) {
            await decoderFile.delete();
            }
            if (await tokensFile.exists() && await tokensFile.length() == 0) {
            await tokensFile.delete();
            }
            rethrow;
        }
    }

    Future<void> clearSavedModelState() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(SttConfig.prefsModelDirKey);
        await prefs.remove(SttConfig.prefsModelReadyKey);
    }

    //Download helper with a timeout and basic error checks.
    Future<void> _downloadFile(String url, File outputFile) async {
        print('STT download: sending GET request for $url');

        final response = await http.get(Uri.parse(url)).timeout(
            const Duration(minutes: 3),
            onTimeout: () => throw Exception('STT file download timed out: $url'),
        );

        print('STT download: response status = ${response.statusCode}');
        if (response.statusCode != 200) {
            throw Exception('Failed to download STT file: ${response.statusCode} $url');
        }

        print('STT download: received ${response.bodyBytes.length} bytes');
        await outputFile.writeAsBytes(response.bodyBytes, flush: true);
        print('STT download: saved ${outputFile.path}');
    }

}