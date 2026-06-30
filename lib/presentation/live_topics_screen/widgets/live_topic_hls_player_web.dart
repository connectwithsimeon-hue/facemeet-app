import 'dart:async';
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';

class LiveTopicHlsPlayer extends StatefulWidget {
  final String hlsUrl;

  const LiveTopicHlsPlayer({super.key, required this.hlsUrl});

  @override
  State<LiveTopicHlsPlayer> createState() => _LiveTopicHlsPlayerState();
}

class _LiveTopicHlsPlayerState extends State<LiveTopicHlsPlayer> {
  late final String _viewType;
  late final html.DivElement _root;
  late final html.VideoElement _video;
  late final html.DivElement _hint;
  Object? _hls;
  static Future<void>? _hlsScriptFuture;

  @override
  void initState() {
    super.initState();
    _viewType =
        'facemeet-live-topic-hls-${DateTime.now().microsecondsSinceEpoch}';
    _video = html.VideoElement()
      ..controls = true
      ..autoplay = true
      ..muted = false
      ..setAttribute('playsinline', 'true')
      ..setAttribute('webkit-playsinline', 'true')
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = 'contain'
      ..style.backgroundColor = '#000000';
    _hint = html.DivElement()
      ..text = 'Tap play if the live stream does not start automatically.'
      ..style.position = 'absolute'
      ..style.left = '14px'
      ..style.right = '14px'
      ..style.bottom = '14px'
      ..style.padding = '10px 12px'
      ..style.borderRadius = '16px'
      ..style.backgroundColor = 'rgba(0,0,0,.58)'
      ..style.color = 'white'
      ..style.font =
          "600 13px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
      ..style.textAlign = 'center'
      ..style.pointerEvents = 'none';
    _root = html.DivElement()
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000000'
      ..children.addAll([_video, _hint]);
    ui.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _root,
    );
    _loadPlayer();
  }

  @override
  void didUpdateWidget(covariant LiveTopicHlsPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hlsUrl != widget.hlsUrl) _loadPlayer();
  }

  void _loadPlayer() {
    final src = widget.hlsUrl.trim();
    _destroyHls();
    _video
      ..pause()
      ..removeAttribute('src')
      ..load();
    _hint
      ..text = 'Tap play if the live stream does not start automatically.'
      ..style.display = 'block';

    if (src.isEmpty) {
      _showError();
      return;
    }

    if (_video.canPlayType('application/vnd.apple.mpegurl').isNotEmpty) {
      _video.src = src;
      _video.play().catchError((_) {});
      return;
    }

    _attachHlsJs(src);
  }

  Future<void> _attachHlsJs(String src) async {
    try {
      await _ensureHlsScript();
      if (!mounted) return;
      final hlsCtor = js_util.getProperty<Object?>(html.window, 'Hls');
      if (hlsCtor == null) {
        _showError();
        return;
      }
      final supported = js_util.callMethod<bool>(hlsCtor, 'isSupported', []);
      if (!supported) {
        _showError();
        return;
      }
      final hls = js_util.callConstructor<Object>(hlsCtor, [
        js_util.jsify({
          'lowLatencyMode': true,
          'liveDurationInfinity': true,
          'maxLiveSyncPlaybackRate': 1.5,
        }),
      ]);
      _hls = hls;
      final events = js_util.getProperty<Object>(hlsCtor, 'Events');
      final manifestParsed = js_util.getProperty<String>(
        events,
        'MANIFEST_PARSED',
      );
      final hlsError = js_util.getProperty<String>(events, 'ERROR');
      js_util.callMethod(hls, 'on', [
        manifestParsed,
        js_util.allowInterop((dynamic _, dynamic __) {
          _video.play().catchError((_) {});
        }),
      ]);
      js_util.callMethod(hls, 'on', [
        hlsError,
        js_util.allowInterop((dynamic _, dynamic data) {
          final fatal = js_util.getProperty<bool?>(data, 'fatal') ?? false;
          if (fatal) _showError();
        }),
      ]);
      js_util.callMethod(hls, 'loadSource', [src]);
      js_util.callMethod(hls, 'attachMedia', [_video]);
    } catch (_) {
      if (mounted) _showError();
    }
  }

  static Future<void> _ensureHlsScript() {
    final existing = js_util.getProperty<Object?>(html.window, 'Hls');
    if (existing != null) return Future.value();
    return _hlsScriptFuture ??= () {
      final completer = Completer<void>();
      final script = html.ScriptElement()
        ..src = 'https://cdn.jsdelivr.net/npm/hls.js@1.5.20/dist/hls.min.js'
        ..async = true;
      script.onLoad.first.then((_) => completer.complete());
      script.onError.first.then((_) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('hls.js failed to load'));
        }
      });
      html.document.head?.append(script);
      return completer.future;
    }();
  }

  void _showError() {
    _hint
      ..text = 'Live playback is not available yet. Please try again shortly.'
      ..style.display = 'block';
  }

  void _destroyHls() {
    final hls = _hls;
    if (hls != null) {
      try {
        js_util.callMethod(hls, 'destroy', []);
      } catch (_) {}
    }
    _hls = null;
  }

  @override
  void dispose() {
    _destroyHls();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 360,
        color: Colors.black,
        child: HtmlElementView(viewType: _viewType),
      ),
    );
  }
}
