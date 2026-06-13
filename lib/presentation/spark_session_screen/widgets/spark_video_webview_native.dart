import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Native WebView fallback for Daily Spark Sessions using a tokenized
/// DailyIframe join flow inside injected HTML.
class SparkVideoWebView extends StatefulWidget {
  final String roomUrl;
  final String meetingToken;
  final VoidCallback onConnected;
  final VoidCallback? onRemoteParticipantJoined;
  final VoidCallback? onEndRequested;
  final void Function(bool muted)? onMuteChanged;
  final void Function(bool cameraOff)? onCameraChanged;
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
    this.onMuteChanged,
    this.onCameraChanged,
    this.onError,
    this.showFaceMeetTimer = false,
    this.timerText = '03:00',
    this.timerIsUrgent = false,
  });

  @override
  State<SparkVideoWebView> createState() => SparkVideoWebViewState();
}

class SparkVideoWebViewState extends State<SparkVideoWebView> {
  late final WebViewController _controller;
  bool _connected = false;
  bool _participantSeen = false;
  Timer? _connectionTimer;

  @override
  void initState() {
    super.initState();
    debugPrint(
      'SPARK WEBVIEW: initializing secure WebView — room URL present=${widget.roomUrl.isNotEmpty}, token present=${widget.meetingToken.isNotEmpty}',
    );
    _initWebView();
  }

  String _buildSecureDailyHtml() {
    final roomUrl = jsonEncode(widget.roomUrl);
    final meetingToken = jsonEncode(widget.meetingToken);

    return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0" />
    <style>
      html, body, #frame-host {
        margin: 0;
        padding: 0;
        width: 100%;
        height: 100%;
        background: #000;
        overflow: hidden;
      }
    </style>
    <script src="https://unpkg.com/@daily-co/daily-js"></script>
  </head>
  <body>
    <div id="frame-host"></div>
    <script>
      (function () {
        const roomUrl = $roomUrl;
        const meetingToken = $meetingToken;
        let callFrame = null;

        function send(type, extra) {
          const payload = Object.assign({ type }, extra || {});
          if (window.FaceMeetDailyBridge) {
            FaceMeetDailyBridge.postMessage(JSON.stringify(payload));
          }
        }

        async function leaveCurrentFrame() {
          if (!callFrame) return;
          try {
            await callFrame.leave();
          } catch (_) {}
          try {
            callFrame.destroy();
          } catch (_) {}
          callFrame = null;
        }

        async function startJoin() {
          try {
            const host = document.getElementById('frame-host');
            host.innerHTML = '';
            callFrame = window.DailyIframe.createFrame(host, {
              showLeaveButton: false,
              iframeStyle: {
                width: '100%',
                height: '100%',
                border: '0',
                backgroundColor: '#000000',
              },
            });

            callFrame.on('joined-meeting', function () { send('joined'); });
            callFrame.on('participant-joined', function () { send('participant-joined'); });
            callFrame.on('left-meeting', function () { send('left'); });
            callFrame.on('error', function (event) {
              const message =
                (event && (event.errorMsg || event.error || event.message)) ||
                'Daily join failed';
              send('error', { message: String(message) });
            });

            if (typeof callFrame.preAuth === 'function') {
              try {
                await callFrame.preAuth({ url: roomUrl, token: meetingToken });
              } catch (_) {}
            }

            await callFrame.join({ url: roomUrl, token: meetingToken });
          } catch (error) {
            const message =
              (error && error.message) ? error.message : String(error || 'Daily join failed');
            send('error', { message });
          }
        }

        startJoin();
      })();
    </script>
  </body>
</html>
''';
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FaceMeetDailyBridge',
        onMessageReceived: (message) {
          try {
            final payload = jsonDecode(message.message) as Map<String, dynamic>;
            final type = (payload['type'] as String? ?? '').toLowerCase();
            if (type == 'joined') {
              if (!_connected) {
                _connected = true;
                widget.onConnected();
              }
            } else if (type == 'participant-joined') {
              if (!_participantSeen) {
                _participantSeen = true;
                widget.onRemoteParticipantJoined?.call();
              }
            } else if (type == 'left') {
              widget.onEndRequested?.call();
            } else if (type == 'error') {
              widget.onError?.call(
                (payload['message'] as String? ?? 'Daily join failed').trim(),
              );
            }
          } catch (e) {
            debugPrint('SPARK WEBVIEW: bridge payload parse failed — $e');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            debugPrint('SPARK WEBVIEW: secure page started loading');
          },
          onPageFinished: (url) {
            debugPrint('SPARK WEBVIEW: secure page finished loading');
          },
          onWebResourceError: (error) {
            debugPrint(
              'SPARK WEBVIEW: web resource error — ${error.description}',
            );
            if (!_connected) {
              widget.onError?.call(
                'Video room failed to load: ${error.description}',
              );
            }
          },
        ),
      )
      ..loadHtmlString(_buildSecureDailyHtml());

    _controller.setBackgroundColor(Colors.black);

    _connectionTimer = Timer(const Duration(seconds: 15), () {
      if (!_connected && mounted) {
        debugPrint('SPARK WEBVIEW: connection timeout — assuming connected');
        _connected = true;
        widget.onConnected();
      }
    });
  }

  Future<void> retryJoin() async {
    debugPrint('SPARK WEBVIEW: retryJoin requested');
    _connected = false;
    _participantSeen = false;
    _connectionTimer?.cancel();
    await leaveCall();
    _initWebView();
  }

  Future<void> leaveCall() async {
    try {
      await _controller.runJavaScript('''
        (function() {
          try {
            var streams = document.querySelectorAll('video, audio');
            streams.forEach(function(el) {
              if (el.srcObject) {
                el.srcObject.getTracks().forEach(function(track) { track.stop(); });
                el.srcObject = null;
              }
            });
          } catch (_) {}
        })();
      ''');
    } catch (e) {
      debugPrint(
        'SPARK WEBVIEW: leaveCall JS injection failed (non-critical) — $e',
      );
    }
  }

  void sendToggleMuteCommand() {}

  void sendToggleCameraCommand() {}

  void sendEndCallCommand() {
    widget.onEndRequested?.call();
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    leaveCall().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
