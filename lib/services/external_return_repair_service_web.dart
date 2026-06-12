// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

class ExternalReturnRepairService {
  static final StreamController<void> _controller =
      StreamController<void>.broadcast();

  static bool _listening = false;

  static Stream<void> get events {
    _ensureListening();
    return _controller.stream;
  }

  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    html.window.addEventListener('facemeet:external-return-repair', (_) {
      _controller.add(null);
    });
  }
}
