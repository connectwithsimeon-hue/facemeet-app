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
    .wrap.fill video { object-fit: cover; }
    .badge { position: absolute; left: 14px; top: 14px; padding: 8px 11px; border-radius: 999px; background: rgba(0,0,0,.58); color: white; font: 800 12px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; border: 1px solid rgba(255,255,255,.14); }
    .badge::before { content: ''; display: inline-block; width: 8px; height: 8px; margin-right: 7px; border-radius: 99px; background: #ef4d3f; }
    .controls { position: absolute; right: 12px; top: 12px; display: flex; gap: 8px; }
    .control { min-width: 42px; height: 42px; padding: 0 13px; border-radius: 999px; border: 1px solid rgba(255,255,255,.16); background: rgba(0,0,0,.66); color: white; font: 900 12px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; cursor: pointer; }
    .resume { position: absolute; right: 14px; bottom: 14px; width: 44px; height: 44px; border-radius: 999px; border: 1px solid rgba(255,255,255,.16); background: rgba(0,0,0,.62); color: white; font: 800 18px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; cursor: pointer; }
    .hint { position: absolute; left: 14px; right: 14px; bottom: 68px; padding: 10px 12px; border-radius: 16px; background: rgba(0,0,0,.58); color: white; font: 600 13px -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; text-align: center; pointer-events: none; }
    .hidden { display: none; }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.20/dist/hls.min.js"></script>
</head>
<body>
  <div id="wrap" class="wrap">
    <video id="video" playsinline webkit-playsinline autoplay></video>
    <div class="badge">Live</div>
    <div class="controls">
      <button id="fit" class="control" aria-label="Toggle fill mode">Fill</button>
      <button id="expand" class="control" aria-label="Expand live playback">⛶</button>
    </div>
    <button id="resume" class="resume" aria-label="Resume live playback">▶</button>
    <div id="hint" class="hint">Tap the video if live playback does not start automatically.</div>
  </div>
  <script>
    (function () {
      const src = $hlsUrl;
      const wrap = document.getElementById('wrap');
      const video = document.getElementById('video');
      const hint = document.getElementById('hint');
      const resume = document.getElementById('resume');
      const fit = document.getElementById('fit');
      const expand = document.getElementById('expand');
      let wakeLock = null;
      let hls = null;
      let retryTimer = null;
      let retryCount = 0;
      const maxRetries = 24;
      const retryDelayMs = 3000;
      async function requestWakeLock() {
        try {
          if ('wakeLock' in navigator && !wakeLock) {
            wakeLock = await navigator.wakeLock.request('screen');
            wakeLock.addEventListener('release', function () { wakeLock = null; });
          }
        } catch (_) {}
      }
      function setWarmingHint() {
        hint.classList.remove('hidden');
        hint.textContent = 'Connecting live playback... the stream is warming up.';
      }
      function playLive() {
        requestWakeLock();
        video.play().catch(function () {});
      }
      function clearRetry() {
        if (retryTimer) {
          clearTimeout(retryTimer);
          retryTimer = null;
        }
      }
      function destroyHls() {
        if (hls) {
          try { hls.destroy(); } catch (_) {}
          hls = null;
        }
      }
      function scheduleRetry() {
        clearRetry();
        if (retryCount >= maxRetries) {
          showError();
          return;
        }
        retryCount += 1;
        setWarmingHint();
        retryTimer = setTimeout(start, retryDelayMs);
      }
      function showError() {
        hint.classList.remove('hidden');
        hint.textContent = 'Live playback is not available yet. Please try again shortly.';
      }
      function hideHintLater() { setTimeout(function () { hint.classList.add('hidden'); }, 5000); }
      video.addEventListener('playing', hideHintLater);
      video.addEventListener('error', scheduleRetry);
      video.addEventListener('click', playLive);
      resume.addEventListener('click', playLive);
      fit.addEventListener('click', function () {
        wrap.classList.toggle('fill');
        fit.textContent = wrap.classList.contains('fill') ? 'Fit' : 'Fill';
        playLive();
      });
      expand.addEventListener('click', function () {
        playLive();
        if (document.fullscreenElement) {
          document.exitFullscreen().catch(function () {});
          return;
        }
        wrap.requestFullscreen?.().catch(function () {});
      });
      document.addEventListener('visibilitychange', function () {
        if (!document.hidden) playLive();
      });
      if (!src) { showError(); return; }
      function start() {
        clearRetry();
        destroyHls();
        setWarmingHint();
        video.removeAttribute('src');
        video.load();
        if (video.canPlayType('application/vnd.apple.mpegurl')) {
          video.src = src;
          playLive();
          return;
        }
        if (window.Hls && window.Hls.isSupported()) {
          hls = new window.Hls({ lowLatencyMode: true, liveDurationInfinity: true });
          hls.on(window.Hls.Events.ERROR, function (_, data) {
            if (data && data.fatal) scheduleRetry();
          });
          hls.loadSource(src);
          hls.attachMedia(video);
          hls.on(window.Hls.Events.MANIFEST_PARSED, function () {
            retryCount = 0;
            playLive();
          });
          return;
        }
        showError();
      }
      start();
    })();
  </script>
</body>
</html>""";
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = (media.size.width * 1.08).clamp(
      420.0,
      (media.size.height * 0.68).clamp(420.0, 620.0),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: height,
        color: Colors.black,
        child: HtmlElementView(viewType: _viewType),
      ),
    );
  }
}
