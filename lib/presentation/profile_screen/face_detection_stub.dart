/// Stub implementation for web platform — face detection not supported on web.
/// Always returns true so the upload proceeds without blocking.
Future<bool> detectFaceInVideoFile(String filePath) async {
  return true;
}
