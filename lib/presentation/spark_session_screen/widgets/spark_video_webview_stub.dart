import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';

/// Web implementation for Daily Spark Sessions using a tokenized DailyIframe
/// join flow inside an isolated iframe document.
class SparkVideoWebView extends StatefulWidget {
  final String roomUrl;
  final String meetingToken;
  final VoidCallback onConnected;
  final VoidCallback? onRemoteParticipantJoined;
  final VoidCallback? onEndRequested;
  final void Function(String error)? onError;
  final bool showFaceMeetTimer;
  final String timerText;
  final bool timerIsUrgent;

  const SparkVideoWebView({
    super.key,
    required this.roomUrl,
    required this.meetingToken,
    required this.onConnected,
    this.onRemoteParticipantJoined,
    this.onEndRequested,
    this.onError,
    this.showFaceMeetTimer = false,
    this.timerText = '03:00',
    this.timerIsUrgent = false,
  });

  @override
  State<SparkVideoWebView> createState() => SparkVideoWebViewState();
}

class SparkVideoWebViewState extends State<SparkVideoWebView> {
  late final String _viewType;
  late html.IFrameElement _iframe;
  late html.DivElement _host;
  StreamSubscription<html.Event>? _loadSub;
  StreamSubscription<html.MessageEvent>? _messageSub;
  bool _connected = false;
  bool _participantSeen = false;
  bool _endRequested = false;

  @override
  void initState() {
    super.initState();
    _viewType =
        'facemeet-daily-iframe-${DateTime.now().microsecondsSinceEpoch}';
    debugPrint(
      'SPARK SESSION: web Daily join started — room URL present=${widget.roomUrl.isNotEmpty}, token present=${widget.meetingToken.isNotEmpty}',
    );
    _registerDailyIframe();
    _listenForDailyMessages();
  }

  String _wrapperUrl() => 'spark_daily_join.html?v=20260612';

  void _postStartPayload() {
    _postToDailyFrame({
      'source': 'facemeet-parent',
      'type': 'start',
      'roomUrl': widget.roomUrl,
      'meetingToken': widget.meetingToken,
    });
  }

  void _postUiStatePayload() {
    _postToDailyFrame({
      'source': 'facemeet-parent',
      'type': 'ui-state',
      'showFaceMeetTimer': widget.showFaceMeetTimer,
      'timerText': widget.timerText,
      'timerIsUrgent': widget.timerIsUrgent,
    });
  }

  void _registerDailyIframe() {
    _host = html.DivElement()
      ..style.position = 'relative'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000'
      ..style.overflow = 'hidden';

    _iframe = html.IFrameElement()
      ..src = _wrapperUrl()
      ..allow =
          'camera; microphone; fullscreen; display-capture; autoplay; clipboard-write'
      ..allowFullscreen = true
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000'
      ..style.display = 'block';

    _loadSub = _iframe.onLoad.listen((_) {
      debugPrint(
        'DAILY WEB: secure iframe document loaded — waiting for Daily join events',
      );
      _postStartPayload();
      _postUiStatePayload();
      Timer(const Duration(milliseconds: 250), _postStartPayload);
      Timer(const Duration(milliseconds: 250), _postUiStatePayload);
      Timer(const Duration(seconds: 1), _postStartPayload);
      Timer(const Duration(seconds: 1), _postUiStatePayload);
    });

    ui.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      _host.children
        ..clear()
        ..add(_iframe);
      return _host;
    });
  }

  void _listenForDailyMessages() {
    _messageSub = html.window.onMessage.listen((event) {
      var payload = event.data;
      if (payload == null) return;

      if (payload is String) {
        try {
          payload = jsonDecode(payload);
        } catch (_) {
          final normalized = payload.toLowerCase();
          if (normalized.contains('joined')) _markConnected();
          if (normalized.contains('participant')) _markParticipantSeen();
          if (normalized.contains('left') || normalized.contains('leave')) {
            _requestFaceMeetEnd('Daily iframe leave message');
          }
          return;
        }
      }

      if (payload is! Map) return;
      if (payload['source'] != 'facemeet-daily') return;

      final type = (payload['type'] as String? ?? '').toLowerCase();
      if (type == 'joined') {
        debugPrint('SPARK SESSION: web Daily join success');
        _markConnected();
      } else if (type == 'participant-joined' ||
          type == 'remote-participant-joined') {
        debugPrint('SPARK SESSION: web Daily remote participant detected');
        _markParticipantSeen();
      } else if (type == 'left') {
        debugPrint('DAILY WEB END: Daily left event received');
        _requestFaceMeetEnd('Daily iframe leave message');
      } else if (type == 'remote-participant-left') {
        debugPrint('SPARK SESSION: web Daily remote participant left');
      } else if (type == 'error') {
        final message = (payload['message'] as String? ?? 'Daily join failed')
            .trim();
        debugPrint('SPARK SESSION: web Daily error — $message');
        widget.onError?.call(message);
      } else if (type == 'wrapper-ready') {
        _postStartPayload();
        _postUiStatePayload();
      } else if (type == 'end-requested') {
        debugPrint('DAILY WEB END: wrapper requested FaceMeet end flow');
        widget.onEndRequested?.call();
      }
    });
  }

  void _markConnected() {
    if (_connected) return;
    _connected = true;
    widget.onConnected();
  }

  void _markParticipantSeen() {
    if (_participantSeen) return;
    _participantSeen = true;
    widget.onRemoteParticipantJoined?.call();
  }

  Future<void> retryJoin() async {
    debugPrint('SPARK SESSION: web Daily join retry started');
    _connected = false;
    _participantSeen = false;
    _endRequested = false;
    _iframe.style.display = 'block';
    _postToDailyFrame({'source': 'facemeet-parent', 'type': 'leave'});
    _iframe.src = '${_wrapperUrl()}&retry=${DateTime.now().millisecondsSinceEpoch}';
  }

  void _postToDailyFrame(Map<String, dynamic> payload) {
    try {
      _iframe.contentWindow?.postMessage(jsonEncode(payload), '*');
    } catch (_) {}
  }

  Future<void> leaveCall() async {
    try {
      debugPrint('DAILY WEB END: Daily leave requested');
      _postToDailyFrame({'source': 'facemeet-parent', 'type': 'leave'});
      _iframe.style.display = 'none';
      _iframe.src = 'about:blank';
    } catch (e) {
      debugPrint('SPARK SESSION: web Daily leave failed — $e');
    }
  }

  @override
  void didUpdateWidget(covariant SparkVideoWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomUrl != widget.roomUrl ||
        oldWidget.meetingToken != widget.meetingToken) {
      _postStartPayload();
    }
    if (oldWidget.showFaceMeetTimer != widget.showFaceMeetTimer ||
        oldWidget.timerText != widget.timerText ||
        oldWidget.timerIsUrgent != widget.timerIsUrgent) {
      _postUiStatePayload();
    }
  }

  void _requestFaceMeetEnd(String source) {
    if (_endRequested) {
      debugPrint(
        'SPARK SESSION: duplicate web Daily end ignored — source=$source',
      );
      return;
    }
    _endRequested = true;
    debugPrint('DAILY WEB END: Flutter end flow started — source=$source');
    leaveCall();
    widget.onEndRequested?.call();
  }

  @override
  void dispose() {
    _loadSub?.cancel();
    _messageSub?.cancel();
    leaveCall();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.roomUrl.isEmpty || widget.meetingToken.isEmpty) {
      widget.onError?.call('Secure Spark Session access is missing.');
      return const ColoredBox(color: Colors.black);
    }

    return HtmlElementView(viewType: _viewType);
  }
}
