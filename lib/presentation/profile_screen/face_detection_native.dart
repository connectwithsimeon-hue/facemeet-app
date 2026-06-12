import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:video_thumbnail_plus/video_thumbnail_plus.dart';

/// Native implementation: samples 3 frames from the video and checks for faces.
/// Returns true if at least one face is detected in any sampled frame.
Future<bool> detectFaceInVideoFile(String filePath) async {
  if (kIsWeb) return true;

  final faceDetector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: false,
      enableLandmarks: false,
      enableContours: false,
      enableTracking: false,
      minFaceSize: 0.1,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  bool faceFound = false;

  try {
    // Sample 3 frames: at 500ms, 2000ms, 4000ms
    final samplePositions = [500, 2000, 4000];

    for (final positionMs in samplePositions) {
      try {
        final thumbnailBytes = await VideoThumbnailPlus.thumbnailData(
          video: filePath,
          imageFormat: ImageFormat.JPEG,
          timeMs: positionMs,
          quality: 75,
        );

        if (thumbnailBytes == null) continue;

        // Write bytes to a temp file for InputImage
        final tempDir = Directory.systemTemp;
        final tempFile = File(
          '${tempDir.path}/face_check_${positionMs}_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await tempFile.writeAsBytes(thumbnailBytes);

        final inputImage = InputImage.fromFile(tempFile);
        final faces = await faceDetector.processImage(inputImage);

        // Clean up temp file
        try {
          await tempFile.delete();
        } catch (_) {}

        if (faces.isNotEmpty) {
          faceFound = true;
          debugPrint(
            'FACE DETECTION: found ${faces.length} face(s) at ${positionMs}ms',
          );
          break;
        } else {
          debugPrint('FACE DETECTION: no face at ${positionMs}ms');
        }
      } catch (e) {
        debugPrint(
          'FACE DETECTION: error sampling frame at ${positionMs}ms: $e',
        );
      }
    }
  } finally {
    await faceDetector.close();
  }

  return faceFound;
}
