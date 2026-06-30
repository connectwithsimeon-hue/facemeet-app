import 'dart:convert';
import 'dart:html' as html;
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
  late html.IFrameElement _iframe;

  @override
  void initState() {
    super.initState();
    _viewType =
        'facemeet-live-topic-hls-${DateTime.now().microsecondsSinceEpoch}';
    _iframe = html.IFrameElement()
      ..allow = 'autoplay; fullscreen; picture-in-picture'
      ..allowFullscreen = true
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000000'
      ..style.display = 'block';
    _loadPlayer();
    ui.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId) => _iframe,
    );
  }

  @override
  void didUpdateWidget(covariant LiveTopicHlsPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hlsUrl != widget.hlsUrl) _loadPlayer();
  }

  void _loadPlayer() {
    _iframe.srcdoc = _htmlFor(widget.hlsUrl);
  }

  String _htmlFor(String rawUrl) {
    final hlsUrl = jsonEncode(rawUrl.trim());
    return """<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <style>
    html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
    .wrap { position: relative; width: 100%; height: 100%; background: #000; }
    video { width: 100%; height: 100%; object-fit: contain; background: #000; }
    .hint { position: absolute; left: 14px; right: 14px; bottom: 14px; padding: 10px 12px; border-radius: 16px; background: rgba(0,0,0,.58); color: white; font: 600 13px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; text-align: center; pointer-events: none; }
    .hidden { display: none; }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.20/dist/hls.min.js"></script>
</head>
<body>
  <div class="wrap">
    <video id="video" controls playsinline webkit-playsinline autoplay></video>
    <div id="hint" class="hint">Tap play if the live stream does not start automatically.</div>
  </div>
  <script>
    (function () {
      const src = $hlsUrl;
      const video = document.getElementById('video');
      const hint = document.getElementById('hint');
      function showError() { hint.textContent = 'Live playback is not available yet. Please try again shortly.'; }
      function hideHintLater() { setTimeout(function () { hint.classList.add('hidden'); }, 5000); }
      video.addEventListener('playing', hideHintLater);
      video.addEventListener('error', showError);
      if (!src) { showError(); return; }
      if (video.canPlayType('application/vnd.apple.mpegurl')) {
        video.src = src;
        video.play().catch(function () {});
        return;
      }
      if (window.Hls && window.Hls.isSupported()) {
        const hls = new window.Hls({ lowLatencyMode: true, liveDurationInfinity: true });
        hls.on(window.Hls.Events.ERROR, function (_, data) {
          if (data && data.fatal) showError();
        });
        hls.loadSource(src);
        hls.attachMedia(video);
        hls.on(window.Hls.Events.MANIFEST_PARSED, function () {
          video.play().catch(function () {});
        });
        return;
      }
      showError();
    })();
  </script>
</body>
</html>""";
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
