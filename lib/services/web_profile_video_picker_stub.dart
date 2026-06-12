import 'package:image_picker/image_picker.dart';

class WebProfileVideoPick {
  final List<int> bytes;
  final String fileName;
  final String mimeType;
  final List<List<int>> moderationFrames;

  const WebProfileVideoPick({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.moderationFrames,
  });
}

Future<WebProfileVideoPick?> pickWebProfileVideoForModeration() async {
  final pickedVideo = await ImagePicker().pickVideo(
    source: ImageSource.gallery,
    maxDuration: const Duration(seconds: 20),
  );
  if (pickedVideo == null) return null;
  final bytes = await pickedVideo.readAsBytes();
  return WebProfileVideoPick(
    bytes: bytes,
    fileName: pickedVideo.name,
    mimeType: 'video/mp4',
    moderationFrames: const [],
  );
}
