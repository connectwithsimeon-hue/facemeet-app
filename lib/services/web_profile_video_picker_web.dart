import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'web_profile_video_picker_stub.dart';

const double _maxProfileVideoSeconds = 20.5;

Future<WebProfileVideoPick?> pickWebProfileVideoForModeration() async {
  debugPrint('WEB VIDEO: capture started');

  final input = html.FileUploadInputElement()..accept = 'video/*';
  input.setAttribute('capture', 'user');
  input.style.display = 'none';
  html.document.body?.append(input);

  final completer = Completer<html.File?>();
  input.onChange.first.then((_) {
    completer.complete(
      input.files?.isNotEmpty == true ? input.files!.first : null,
    );
  });
  input.click();

  try {
    final file = await completer.future;
    if (file == null) {
      debugPrint('WEB VIDEO: capture cancelled or no file returned');
      return null;
    }

    debugPrint('WEB VIDEO: file received');
    debugPrint(
      'WEB VIDEO: file name=${file.name} type=${file.type} size=${file.size}',
    );

    if (file.size <= 0) {
      throw Exception('Recorded video is empty. Please record again.');
    }

    debugPrint('WEB VIDEO: reading bytes started');
    final bytes = await _readFileBytes(file);
    debugPrint('WEB VIDEO: reading bytes completed length=${bytes.length}');
    if (bytes.isEmpty) {
      throw Exception('Recorded video is empty. Please record again.');
    }

    debugPrint('WEB VIDEO: frame sampling started');
    final frameBytes = await _sampleFrames(file);
    debugPrint('WEB VIDEO: frame sampling count=${frameBytes.length}');

    return WebProfileVideoPick(
      bytes: bytes,
      fileName: _safeFileName(file),
      mimeType: file.type,
      moderationFrames: frameBytes,
    );
  } finally {
    input.remove();
  }
}

Future<Uint8List> _readFileBytes(html.File file) async {
  final bytes = await _readFileBytesAsArrayBuffer(file);
  if (bytes.isNotEmpty) return bytes;

  debugPrint('WEB VIDEO: arrayBuffer read empty; trying data URL fallback');
  return _readFileBytesAsDataUrl(file);
}

Future<Uint8List> _readFileBytesAsArrayBuffer(html.File file) async {
  final reader = html.FileReader();
  final completer = Completer<Uint8List>();

  reader.onLoadEnd.first.then((_) {
    final result = reader.result;
    if (result is ByteBuffer) {
      completer.complete(Uint8List.view(result));
    } else if (result is Uint8List) {
      completer.complete(result);
    } else if (result is List<int>) {
      completer.complete(Uint8List.fromList(result));
    } else {
      debugPrint(
        'WEB VIDEO: unsupported FileReader result type=${result.runtimeType}',
      );
      completer.complete(Uint8List(0));
    }
  });
  reader.onError.first.then((_) {
    completer.completeError(Exception('Could not read recorded video.'));
  });
  reader.readAsArrayBuffer(file);
  return completer.future;
}

Future<Uint8List> _readFileBytesAsDataUrl(html.File file) async {
  final reader = html.FileReader();
  final completer = Completer<Uint8List>();

  reader.onLoadEnd.first.then((_) {
    final result = reader.result;
    if (result is String && result.contains(',')) {
      try {
        completer.complete(
          Uint8List.fromList(base64Decode(result.split(',').last)),
        );
      } catch (_) {
        completer.complete(Uint8List(0));
      }
    } else {
      completer.complete(Uint8List(0));
    }
  });
  reader.onError.first.then((_) {
    completer.completeError(Exception('Could not read recorded video.'));
  });
  reader.readAsDataUrl(file);
  return completer.future;
}

class _VideoMetadata {
  final html.VideoElement video;
  final String objectUrl;
  final double durationSeconds;

  const _VideoMetadata({
    required this.video,
    required this.objectUrl,
    required this.durationSeconds,
  });
}

Future<_VideoMetadata> _loadVideoMetadata(html.File file) async {
  final objectUrl = html.Url.createObjectUrl(file);
  final video = html.VideoElement()
    ..src = objectUrl
    ..muted = true
    ..preload = 'metadata'
    ..style.display = 'none';
  html.document.body?.append(video);

  await video.onLoadedMetadata.first.timeout(
    const Duration(seconds: 10),
    onTimeout: () =>
        throw Exception('We could not read this video. Please record again.'),
  );

  final duration = video.duration.isFinite ? video.duration.toDouble() : 0.0;
  debugPrint('WEB VIDEO: duration detected ${duration.toStringAsFixed(2)}s');

  return _VideoMetadata(
    video: video,
    objectUrl: objectUrl,
    durationSeconds: duration,
  );
}

Future<List<Uint8List>> _sampleFrames(html.File file) async {
  final metadata = await _loadVideoMetadata(file);
  final video = metadata.video;
  try {
    final duration = metadata.durationSeconds;
    if (duration <= 0) {
      throw Exception('We could not read this video. Please record again.');
    }
    if (duration > _maxProfileVideoSeconds) {
      debugPrint('WEB VIDEO: rejected too long seconds=$duration');
      throw Exception(
        'This video is too long. Please record a video under 20 seconds.',
      );
    }
    debugPrint('WEB VIDEO: duration accepted seconds=$duration');

    final times = <double>[
      0.5,
      if (duration > 4) duration * 0.45,
      if (duration > 8) duration * 0.8,
    ];

    final frames = <Uint8List>[];
    for (final time in times.take(3)) {
      final frame = await _captureFrame(video, time.clamp(0.1, duration));
      if (frame.isNotEmpty) frames.add(frame);
    }
    return frames;
  } finally {
    video.remove();
    html.Url.revokeObjectUrl(metadata.objectUrl);
  }
}

Future<Uint8List> _captureFrame(html.VideoElement video, num seconds) async {
  video.currentTime = seconds.toDouble();
  await video.onSeeked.first.timeout(
    const Duration(seconds: 8),
    onTimeout: () =>
        throw Exception('We could not read this video. Please record again.'),
  );

  final width = video.videoWidth > 0 ? video.videoWidth : 640;
  final height = video.videoHeight > 0 ? video.videoHeight : 960;
  final canvas = html.CanvasElement(width: width, height: height);
  final context = canvas.context2D;
  context.drawImageScaled(video, 0, 0, width, height);
  final dataUrl = canvas.toDataUrl('image/jpeg', 0.82);
  final base64Data = dataUrl.split(',').last;
  return Uint8List.fromList(base64Decode(base64Data));
}

String _safeFileName(html.File file) {
  final name = file.name.trim();
  if (name.isNotEmpty && name.contains('.')) return name;

  final mime = file.type.toLowerCase();
  final extension = mime.contains('quicktime')
      ? 'mov'
      : mime.contains('webm')
      ? 'webm'
      : mime.contains('x-m4v')
      ? 'm4v'
      : 'mp4';
  return 'profile-video.$extension';
}
