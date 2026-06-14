import 'dart:async';

import 'package:daily_flutter/daily_flutter.dart';
import 'package:flutter/material.dart';

import 'android_diagnostics_service.dart';

// Native (iOS/Android) implementation using daily_flutter SDK
// This file is imported on non-web platforms via conditional import

/// Native Daily video call widget using daily_flutter SDK
class DailyCallView extends StatefulWidget {
  final String roomUrl;
  final String meetingToken;
  final VoidCallback onCallEnded;
  final VoidCallback? onCallConnected;
  final void Function(String error)? onCallError;
  final VoidCallback? onRemoteParticipantJoined;

  const DailyCallView({
    super.key,
    required this.roomUrl,
    required this.meetingToken,
    required this.onCallEnded,
    this.onCallConnected,
    this.onCallError,
    this.onRemoteParticipantJoined,
  });

  @override
  State<DailyCallView> createState() => DailyCallViewState();
}

// Bug 2 fix: State class is public so SparkVideoCallWidget can call leave() via GlobalKey
class DailyCallViewState extends State<DailyCallView> {
  CallClient? _client;
  bool _loading = true;
  bool _connected = false;
  String? _error;
  int _joinAttempt = 0;
  static const int _maxJoinAttempts = 3;

  /// Bug 2 fix: Explicit leave() method that can be called BEFORE the widget
  /// is disposed. This ensures audio/video is fully terminated when the timer
  /// expires, rather than waiting for dispose() to be called after navigation.
  Future<void> leave() async {
    try {
      debugPrint(
        'DAILY CALL VIEW: leave() called explicitly — calling _client?.leave()',
      );
      await _client?.leave();
      debugPrint('DAILY CALL VIEW: leave() completed — audio/video terminated');
    } catch (e) {
      debugPrint('DAILY CALL VIEW: leave() error (non-critical) — $e');
    }
  }

  Future<void> setMuted(bool muted) async {
    final client = _client;
    if (client == null) {
      throw StateError('Daily call is not ready');
    }

    await client.updateInputs(
      inputs: InputSettingsUpdate.set(
        microphone: MicrophoneInputSettingsUpdate.set(
          isEnabled: BoolUpdate.set(!muted),
        ),
      ),
    );
    debugPrint(
      'DAILY CALL VIEW: native microphone ${muted ? "muted" : "unmuted"}',
    );
  }

  Future<void> setCameraOff(bool cameraOff) async {
    final client = _client;
    if (client == null) {
      throw StateError('Daily call is not ready');
    }

    await client.updateInputs(
      inputs: InputSettingsUpdate.set(
        camera: CameraInputSettingsUpdate.set(
          isEnabled: BoolUpdate.set(!cameraOff),
        ),
      ),
    );
    debugPrint(
      'DAILY CALL VIEW: native camera ${cameraOff ? "disabled" : "enabled"}',
    );
  }

  Future<void> retryJoin() async {
    debugPrint('SPARK SESSION: Daily join retry started — manual retry');
    try {
      await _client?.leave();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loading = true;
      _connected = false;
      _error = null;
    });
    _client = null;
    _joinAttempt = 0;
    await _initCall();
  }

  @override
  void initState() {
    super.initState();
    debugPrint(
      'DAILY CALL VIEW: initState — roomUrl=${widget.roomUrl}, token_present=${widget.meetingToken.isNotEmpty}',
    );
    _initCall();
  }

  Future<void> _initCall() async {
    _joinAttempt++;
    debugPrint(
      'SPARK SESSION: Daily join attempt started — attempt=$_joinAttempt/$_maxJoinAttempts',
    );
    debugPrint('DAILY CALL VIEW: creating CallClient');
    try {
      // Step 1: Create CallClient
      _client = await CallClient.create();
      debugPrint('DAILY CALL VIEW: CallClient created successfully');

      // Step 2: Explicitly enable camera and microphone BEFORE joining
      await _client!.updateInputs(
        inputs: const InputSettingsUpdate.set(
          camera: CameraInputSettingsUpdate.set(
            isEnabled: BoolUpdate.set(true),
          ),
          microphone: MicrophoneInputSettingsUpdate.set(
            isEnabled: BoolUpdate.set(true),
          ),
        ),
      );
      debugPrint(
        'DAILY CALL VIEW: camera=enabled, microphone=enabled via updateInputs',
      );

      // Step 3: Subscribe to events before joining
      _client!.events.listen((event) {
        if (!mounted) return;
        _handleEvent(event);
      });

      // Step 4: Join with clientSettings also enforcing camera+mic enabled
      debugPrint(
        'DAILY CALL VIEW: calling join() with secure token — url=${widget.roomUrl}, token_present=${widget.meetingToken.isNotEmpty}',
      );
      await _client!
          .join(
            url: Uri.parse(widget.roomUrl),
            clientSettings: const ClientSettingsUpdate.set(
              inputs: InputSettingsUpdate.set(
                camera: CameraInputSettingsUpdate.set(
                  isEnabled: BoolUpdate.set(true),
                ),
                microphone: MicrophoneInputSettingsUpdate.set(
                  isEnabled: BoolUpdate.set(true),
                ),
              ),
            ),
            token: widget.meetingToken,
          )
          .timeout(const Duration(seconds: 20));
      debugPrint('DAILY CALL VIEW: join() called — waiting for joined state');
    } catch (e) {
      debugPrint('DAILY CALL VIEW: ERROR during initCall — $e');
      final isTimeout =
          e is TimeoutException ||
          e.toString().toLowerCase().contains('timeoutexception') ||
          e.toString().toLowerCase().contains('timeout');
      if (isTimeout) {
        debugPrint(
          'SPARK SESSION: Daily join timeout — attempt=$_joinAttempt/$_maxJoinAttempts',
        );
      }

      if (isTimeout && _joinAttempt < _maxJoinAttempts && mounted) {
        debugPrint(
          'SPARK SESSION: Daily join retry started — nextAttempt=${_joinAttempt + 1}',
        );
        try {
          await _client?.leave();
        } catch (_) {}
        _client = null;
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          await _initCall();
        }
        return;
      }

      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
        debugPrint('SPARK SESSION: Daily join final failure — $e');
        AndroidDiagnosticsService.instance.setValue(
          'native_daily_join_success',
          'no',
        );
        widget.onCallError?.call(e.toString());
      }
    }
  }

  void _handleEvent(Event event) {
    if (event is CallStateUpdatedEvent) {
      final stateData = event.stateData;
      String stateName = 'unknown';
      bool isJoined = false;
      bool isLeft = false;

      stateData.map(
        initialized: (_) => stateName = 'initialized',
        joining: (_) => stateName = 'joining',
        joined: (_) {
          stateName = 'joined';
          isJoined = true;
        },
        leaving: (_) => stateName = 'leaving',
        left: (_) {
          stateName = 'left';
          isLeft = true;
        },
      );

      debugPrint('DAILY CALL VIEW: onCallStateUpdated — state=$stateName');

      if (isJoined && !_connected) {
        _connected = true;
        AndroidDiagnosticsService.instance.setValue(
          'native_daily_join_success',
          'yes',
        );
        debugPrint('SPARK SESSION: Daily join success');
        debugPrint(
          'DAILY CALL VIEW: call state=joined — local video track should be active',
        );
        // Re-assert microphone enabled immediately after joining (setLocalAudio equivalent)
        _client
            ?.updateInputs(
              inputs: const InputSettingsUpdate.set(
                camera: CameraInputSettingsUpdate.set(
                  isEnabled: BoolUpdate.set(true),
                ),
                microphone: MicrophoneInputSettingsUpdate.set(
                  isEnabled: BoolUpdate.set(true),
                ),
              ),
            )
            .then((_) {
              debugPrint(
                'DAILY CALL VIEW: post-join updateInputs — microphone re-enabled (setLocalAudio equivalent)',
              );
            })
            .catchError((e) {
              debugPrint('DAILY CALL VIEW: post-join updateInputs error — $e');
            });
        if (mounted) setState(() => _loading = false);
        widget.onCallConnected?.call();
        _notifyRemoteParticipantIfPresent('joined-state');
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 750), () {
            _notifyRemoteParticipantIfPresent('joined-state-delayed');
          }),
        );
      } else if (isLeft) {
        debugPrint('DAILY CALL VIEW: call left — triggering onCallEnded');
        widget.onCallEnded();
      }
    }

    if (event is ParticipantJoinedEvent) {
      final p = event.participant;
      debugPrint(
        'DAILY CALL VIEW: participant joined — id=${p.id}, isLocal=${p.info.isLocal}',
      );
      if (!p.info.isLocal) {
        AndroidDiagnosticsService.instance.setValue(
          'last_daily_participant_event',
          'participant-joined',
        );
        debugPrint(
          'DAILY CALL VIEW: REMOTE participant joined — firing onRemoteParticipantJoined callback',
        );
        widget.onRemoteParticipantJoined?.call();
      }
      if (mounted) setState(() {});
    }

    if (event is ParticipantUpdatedEvent) {
      final p = event.participant;
      if (!p.info.isLocal) {
        final hasVideo = p.media?.camera.track != null;
        AndroidDiagnosticsService.instance.setValue(
          'last_daily_participant_event',
          'participant-updated',
        );
        debugPrint(
          'DAILY CALL VIEW: remote participant updated — id=${p.id}, hasVideoTrack=$hasVideo',
        );
        _notifyRemoteParticipantIfPresent('participant-updated');
      }
      if (mounted) setState(() {});
    }

    if (event is ParticipantLeftEvent) {
      debugPrint('DAILY CALL VIEW: remote participant left');
      if (mounted) setState(() {});
    }
  }

  void _notifyRemoteParticipantIfPresent(String source) {
    final client = _client;
    if (client == null) return;

    final remoteCount = client.participants.all.values
        .where((participant) => !participant.info.isLocal)
        .length;

    debugPrint(
      'DAILY CALL VIEW: remote participant check ($source) — remoteCount=$remoteCount',
    );
    final key = source.contains('delayed')
        ? 'remote_participant_count_delayed'
        : 'remote_participant_count_immediate';
    AndroidDiagnosticsService.instance.setValue(key, remoteCount);

    if (remoteCount > 0) {
      widget.onRemoteParticipantJoined?.call();
    }
  }

  @override
  void dispose() {
    debugPrint('DAILY CALL VIEW: dispose — leaving call');
    _client?.leave().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(
                color: Color(0xFFFF4458),
                strokeWidth: 3,
              ),
              SizedBox(height: 20),
              Text(
                'Connecting video...',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not connect: $_error',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_client == null) return const SizedBox.shrink();

    return _DailyVideoLayout(client: _client!);
  }
}

class _DailyVideoLayout extends StatefulWidget {
  final CallClient client;
  const _DailyVideoLayout({required this.client});

  @override
  State<_DailyVideoLayout> createState() => _DailyVideoLayoutState();
}

class _DailyVideoLayoutState extends State<_DailyVideoLayout> {
  final VideoViewController _remoteController = VideoViewController();
  final VideoViewController _localController = VideoViewController();

  @override
  void initState() {
    super.initState();
    _updateTracks();
    widget.client.events.listen((event) {
      if (!mounted) return;
      if (event is ParticipantJoinedEvent ||
          event is ParticipantUpdatedEvent ||
          event is ParticipantLeftEvent) {
        _updateTracks();
      }
    });
  }

  Future<void> _updateTracks() async {
    final participants = widget.client.participants.all;
    final remoteList = participants.values
        .where((p) => !p.info.isLocal)
        .toList();
    final localList = participants.values.where((p) => p.info.isLocal).toList();

    if (remoteList.isNotEmpty) {
      final track = remoteList.first.media?.camera.track;
      await _remoteController.setTrack(track);
      debugPrint(
        'DAILY CALL VIEW: remote video track set — track=${track != null ? "present" : "null"}',
      );
    }

    if (localList.isNotEmpty) {
      final localTrack = localList.first.media?.camera.track;
      await _localController.setTrack(localTrack);
      debugPrint(
        'DAILY CALL VIEW: local video track set — track=${localTrack != null ? "present" : "null"}',
      );
    }

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _remoteController.dispose();
    _localController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final participants = widget.client.participants.all;
    final remoteList = participants.values
        .where((p) => !p.info.isLocal)
        .toList();
    final localList = participants.values.where((p) => p.info.isLocal).toList();

    final hasRemote =
        remoteList.isNotEmpty && remoteList.first.media?.camera.track != null;
    final hasLocal = localList.isNotEmpty;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Remote participant — full screen background
        if (hasRemote)
          SizedBox.expand(
            child: VideoView(
              controller: _remoteController,
              fit: VideoViewFit.cover,
            ),
          )
        else
          Container(
            color: const Color(0xFF0D0D0F),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Color(0xFFFF4458),
                    strokeWidth: 2,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Waiting for other person...',
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        // Local PiP — top right corner, 120x160, rounded corners 12
        if (hasLocal)
          Positioned(
            top: 100,
            right: 16,
            width: 120,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox.expand(
                child: VideoView(
                  controller: _localController,
                  fit: VideoViewFit.cover,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// No-op stubs — DailyCallView manages its own lifecycle
Future<void> initDailyCall(String roomUrl) async {}
Future<void> leaveDailyCall() async {}
Future<void> setDailyMuted(bool muted) async {}
Future<void> setDailyCameraOff(bool off) async {}
