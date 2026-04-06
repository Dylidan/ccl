abstract class SttService {
  Future<void> initialize();
  Future<void> startRecording();
  Future<String?> stopRecordingAndTranscribe();
  Future<void> cancel();
  Future<void> dispose();
}