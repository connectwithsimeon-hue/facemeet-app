import 'dart:async';

import 'package:flutter/foundation.dart';

class VideoRepairEvent {
  final String source;
  final DateTime createdAt;

  VideoRepairEvent(this.source) : createdAt = DateTime.now();
}

class VideoRepairService {
  static final StreamController<VideoRepairEvent> _controller =
      StreamController<VideoRepairEvent>.broadcast();

  static Stream<VideoRepairEvent> get events => _controller.stream;

  static void trigger(String source) {
    debugPrint('VIDEO REPAIR: trigger source=$source');
    _controller.add(VideoRepairEvent(source));
  }
}
