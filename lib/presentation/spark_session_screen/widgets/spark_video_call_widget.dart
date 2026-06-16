import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/supabase_service.dart';
import '../../../services/android_diagnostics_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/user_safety_actions.dart';
import './spark_video_webview_stub.dart'
    if (dart.library.io) './spark_video_webview_native.dart';

// Conditional import: daily_flutter only on native
import '../../../services/daily_call_web.dart'
    if (dart.library.io) '../../../services/daily_call_io.dart';

// WebView — only on non-web platforms (conditional import for web safety)

enum _LiveSafetyAction { report, block, endAndReport, endAndBlock }

class SparkVideoCallWidget extends StatefulWidget {
  final String roomUrl;
  final String meetingToken;
  final Map<String, dynamic> otherUser;
  final VoidCallback onCallEnded;
  final String? matchId;
  final String? sessionId;
  final String? sessionKey;
  // Bug 5: callback to trigger spark refund when Daily.co error occurs
  final VoidCallback? onCallErrorRefund;

  const SparkVideoCallWidget({
    super.key,
    required this.roomUrl,
    required this.meetingToken,
    required this.otherUser,
    required this.onCallEnded,
    this.matchId,
    this.sessionId,
    this.sessionKey,
    this.onCallErrorRefund,
  });

  @override
  State<SparkVideoCallWidget> createState() => _SparkVideoCallWidgetState();
}

class _SparkVideoCallWidgetState extends State<SparkVideoCallWidget>
    with SingleTickerProviderStateMixin {
  static const int _sessionDurationSeconds = 180; // 3 minutes
  static const int _minimumStaySeconds = 10; // Fix 4: minimum stay

  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _showControls = true;

  // Call state tracking
  bool _callConnecting = true;
  bool _callActive = false;
  bool _callEnded = false;

  // Fix 1: callFullyConnected — only true when joined AND remote participant present
  bool _callFullyConnected = false;
  bool _callStateJoined = false;
  bool _remoteParticipantPresent = false;

  // Fix 3: error overlay — shown as overlay on top of video, never close the call
  bool _showErrorOverlay = false;
  String _overlayError = '';

  // Fix 4: track call screen start time for minimum stay
  DateTime? _callScreenStartTime;

  // Bug 4: GlobalKey to access WebView state for explicit leave on timer expiry
  final GlobalKey<SparkVideoWebViewState> _webViewKey =
      GlobalKey<SparkVideoWebViewState>();

  // Bug 2 fix: GlobalKey to access DailyCallView state for explicit native leave()
  final GlobalKey<DailyCallViewState> _nativeCallKey =
      GlobalKey<DailyCallViewState>();

  // Countdown timer — starts only after Daily reports joined-meeting
  int _secondsRemaining = 180;
  Timer? _countdownTimer;

  late AnimationController _timerPulseCtrl;
  late Animation<double> _timerPulse;

  bool _callFailed = false;
  String _callError = '';

  // ── Realtime session-ended listener ──
  RealtimeChannel? _sessionChannel;
  String? _resolvedSessionId;

  @override
  void initState() {
    super.initState();
    // Fix 4: record when the call screen opened
    _callScreenStartTime = DateTime.now();
    debugPrint(
      'SPARK VIDEO CALL: initState — room URL present=${widget.roomUrl.isNotEmpty}, token_present=${widget.meetingToken.isNotEmpty}, matchId=${widget.matchId}, platform=${kIsWeb ? "web" : "native"}, screenStartTime=$_callScreenStartTime',
    );

    _timerPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _timerPulse = Tween<double>(begin: 1.0, end: 1.06).animate(
      CurvedAnimation(parent: _timerPulseCtrl, curve: Curves.easeInOut),
    );

    // Resolve session ID and attach realtime listener
    _resolveSessionAndListen();

    if (widget.roomUrl.isEmpty || widget.meetingToken.isEmpty) {
      debugPrint(
        'SPARK VIDEO CALL: ERROR — secure Daily access is incomplete, cannot connect',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _callConnecting = false;
            // Fix 3: show as overlay error, not a full-screen replacement
            _showErrorOverlay = true;
            _overlayError =
                'Secure Spark Session access is missing. Please try again.';
          });
        }
      });
      return;
    }

    if (kIsWeb) {
      debugPrint(
        'SPARK SESSION: web Daily join started — room URL present=${widget.roomUrl.isNotEmpty}, token present=${widget.meetingToken.isNotEmpty}',
      );
    } else {
      debugPrint(
        'SPARK SESSION: Daily room join started — native DailyCallView will manage connection',
      );
    }
  }

  /// Resolve the spark_session ID for this match, then attach the realtime listener.
  Future<void> _resolveSessionAndListen() async {
    final matchId = widget.matchId;
    if (matchId == null || matchId.isEmpty) return;

    try {
      // If sessionId was passed directly, use it; otherwise look it up by matchId
      String? sessionId = widget.sessionId;
      if (sessionId == null || sessionId.isEmpty) {
        Map<String, dynamic>? row;
        if (widget.sessionKey != null && widget.sessionKey!.isNotEmpty) {
          row = await SupabaseService.instance.client
              .from('spark_sessions')
              .select('id')
              .eq('match_id', matchId)
              .eq('session_key', widget.sessionKey!)
              .limit(1)
              .maybeSingle();
        } else {
          final rows = await SupabaseService.instance.client
              .from('spark_sessions')
              .select('id')
              .eq('match_id', matchId)
              .order('created_at', ascending: false)
              .limit(1);
          row = (rows as List).isNotEmpty
              ? Map<String, dynamic>.from(rows.first)
              : null;
        }
        sessionId = row?['id'] as String?;
      }

      if (sessionId == null) {
        debugPrint(
          'SPARK VIDEO CALL: could not resolve session ID for matchId=$matchId — will retry in 2s',
        );
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        final rows = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('id')
            .eq('match_id', matchId)
            .order('created_at', ascending: false)
            .limit(1);
        final row = (rows as List).isNotEmpty
            ? Map<String, dynamic>.from(rows.first)
            : null;
        sessionId = row?['id'] as String?;
      }

      if (sessionId == null) {
        debugPrint(
          'SPARK VIDEO CALL: session ID still null after retry — skipping realtime listener',
        );
        return;
      }

      _resolvedSessionId = sessionId;
      debugPrint(
        'SPARK VIDEO CALL: attaching realtime listener on session id=$sessionId',
      );
      _attachSessionListener(sessionId);
    } catch (e) {
      debugPrint('SPARK VIDEO CALL: error resolving session ID — $e');
    }
  }

  /// Subscribe to the spark_sessions row. When status = 'ended' fires, close for this user too.
  void _attachSessionListener(String sessionId) {
    _sessionChannel?.unsubscribe();
    _sessionChannel = SupabaseService.instance.client
        .channel('spark_session_$sessionId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'spark_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: sessionId,
          ),
          callback: (payload) {
            final newRow = payload.newRecord;
            final status = newRow['status'] as String?;
            debugPrint(
              'SPARK VIDEO CALL: realtime update received — status=$status',
            );
            if (status == 'ended' && !_callEnded) {
              debugPrint(
                'SPARK VIDEO CALL: session ended remotely — closing screen',
              );
              _handleRemoteEnd();
            }
          },
        )
        .subscribe();
  }

  /// Called when the other user ends the session (realtime event).
  void _handleRemoteEnd() {
    if (_callEnded) return;
    _callEnded = true;
    _countdownTimer?.cancel();
    _timerPulseCtrl.stop();
    // Bug 2/4: Fully leave the Daily.co call so audio is terminated, then navigate
    _leaveCallSilently().then((_) {
      if (mounted) {
        widget.onCallEnded();
      }
    });
  }

  /// Silently leave the Daily.co call — terminates audio/video for this user.
  /// Called on timer expiry, remote end, and manual end to ensure audio stops.
  Future<void> _leaveCallSilently() async {
    try {
      if (kIsWeb) {
        // Bug 2/4: On web, use GlobalKey to call leaveCall() on the WebView
        // which injects JS to stop all media tracks. Await it so audio stops
        // before we navigate away.
        final state = _webViewKey.currentState;
        if (state != null) {
          await state.leaveCall();
        }
        debugPrint(
          'SPARK VIDEO CALL: _leaveCallSilently — called WebView leaveCall() for web',
        );
      } else {
        // Bug 2 fix: On native, call leave() explicitly via GlobalKey BEFORE
        // navigating. This terminates audio/video immediately instead of waiting
        // for dispose() which only runs after the widget is removed from the tree.
        final nativeState = _nativeCallKey.currentState;
        if (nativeState != null) {
          debugPrint(
            'SPARK VIDEO CALL: _leaveCallSilently — calling native DailyCallView.leave() via GlobalKey',
          );
          await nativeState.leave();
          debugPrint(
            'SPARK VIDEO CALL: _leaveCallSilently — native leave() completed, audio/video terminated',
          );
        } else {
          debugPrint(
            'SPARK VIDEO CALL: _leaveCallSilently — native key state is null (already disposed?)',
          );
        }
      }
    } catch (e) {
      debugPrint(
        'SPARK VIDEO CALL: _leaveCallSilently error (non-critical) — $e',
      );
    }
  }

  /// Called when the Daily.co call successfully connects
  void _onCallConnected() {
    if (_callActive) return; // already connected
    debugPrint('SPARK SESSION: join room success — starting timer');
    if (mounted) {
      setState(() {
        _callConnecting = false;
        _callActive = true;
        _callFailed = false;
      });
      startCountdown();
    }
  }

  /// Called when the Daily.co call fails to connect
  void _onCallError(String error) {
    debugPrint('SPARK SESSION: join room failure — $error');
    if (mounted && !_callActive) {
      setState(() {
        _callConnecting = false;
        _callFailed = true;
        _callError = error.replaceFirst('Exception: ', '');
      });
    }
  }

  // Fix 1: Called when Daily.co fires CallStateUpdated with state=joined
  void _onCallStateJoined() {
    if (_callStateJoined) return;
    _callStateJoined = true;
    debugPrint(
      'SPARK SESSION: Daily room join success — callStateJoined=true, remoteParticipantPresent=$_remoteParticipantPresent',
    );
    if (mounted) {
      setState(() {
        _callConnecting = false;
        _callActive = true;
      });
      if (!kIsWeb) {
        startCountdown();
      }
    }
    _checkAndMarkFullyConnected();
  }

  // Fix 1: Called when a remote participant joins the call
  void _onRemoteParticipantJoined() {
    if (_remoteParticipantPresent) return;
    _remoteParticipantPresent = true;
    debugPrint(
      'SPARK VIDEO CALL: remote participant joined — remoteParticipantPresent=true, callStateJoined=$_callStateJoined',
    );
    _checkAndMarkFullyConnected();
  }

  // Fix 1: Only mark callFullyConnected=true when BOTH conditions are met
  void _checkAndMarkFullyConnected() {
    if (_callFullyConnected) return;
    if (_callStateJoined && _remoteParticipantPresent) {
      _callFullyConnected = true;
      debugPrint(
        'SPARK VIDEO CALL: callFullyConnected=true — both call joined AND remote participant present.',
      );
      if (mounted) {
        setState(() {});
      }
      AndroidDiagnosticsService.instance.setValues({
        'waiting_overlay_active': 'no',
        'waiting_overlay_reason': 'remote participant detected',
      });
    } else {
      debugPrint(
        'SPARK VIDEO CALL: _checkAndMarkFullyConnected — not yet fully connected. callStateJoined=$_callStateJoined, remoteParticipantPresent=$_remoteParticipantPresent',
      );
      AndroidDiagnosticsService.instance.setValues({
        'waiting_overlay_active': _callStateJoined ? 'yes' : 'no',
        'waiting_overlay_reason': _callStateJoined
            ? 'native Daily joined; waiting for remote participant'
            : 'waiting for native Daily joined state',
      });
    }
  }

  // Fix 3: Called when Daily.co fires any error — show as overlay on top of video, never close the call
  void _onDailyError(String error) {
    final cleanError = error.replaceFirst('Exception: ', '');
    debugPrint(
      'SPARK SESSION: Daily room join failure/error — "$cleanError". Showing as overlay (NOT closing call).',
    );
    // Bug 5: If the call was fully connected (sparks were deducted), trigger refund
    if (_callFullyConnected) {
      debugPrint(
        'SPARK VIDEO CALL: call was fully connected when error occurred — triggering spark refund',
      );
      widget.onCallErrorRefund?.call();
    }
    if (mounted) {
      setState(() {
        _callConnecting = false;
        // Fix 3: show error as overlay, do NOT set _callFailed
        _showErrorOverlay = true;
        _overlayError = cleanError;
      });
    }
  }

  // Dismiss the error overlay (user tapped X or it auto-dismisses)
  void _dismissErrorOverlay() {
    if (mounted) {
      setState(() {
        _showErrorOverlay = false;
        _overlayError = '';
      });
    }
  }

  Future<void> _retryConnection() async {
    debugPrint(
      'SPARK VIDEO CALL: retrying connection — room URL present=${widget.roomUrl.isNotEmpty}',
    );
    if (!mounted) return;
    setState(() {
      _callConnecting = true;
      _showErrorOverlay = false;
      _overlayError = '';
      _callActive = false;
      _callStateJoined = false;
      _remoteParticipantPresent = false;
      _callFullyConnected = false;
    });
    _countdownTimer?.cancel();

    if (kIsWeb) {
      _webViewKey.currentState?.retryJoin();
    } else {
      await _nativeCallKey.currentState?.retryJoin();
    }
  }

  /// Starts the 3-minute countdown timer. Called only after Daily joined-meeting.
  void startCountdown() {
    if (_countdownTimer != null) return;
    _secondsRemaining = 180;
    debugPrint(
      'SPARK VIDEO CALL: TIMER STARTED — secondsRemaining=$_secondsRemaining',
    );
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _secondsRemaining--;
        debugPrint(
          'SPARK VIDEO CALL: timer tick — secondsRemaining=$_secondsRemaining',
        );
        if (_secondsRemaining <= 30 && !_timerPulseCtrl.isAnimating) {
          _timerPulseCtrl.repeat(reverse: true);
        }
      });
      if (_secondsRemaining <= 0) {
        timer.cancel();
        debugPrint(
          'SPARK VIDEO CALL: TIMER REACHED ZERO — callFullyConnected=$_callFullyConnected',
        );
        _onTimerExpired();
      }
    });
  }

  // Fix 2: Called when timer reaches zero — only navigate if callFullyConnected
  void _onTimerExpired() {
    if (!_callFullyConnected) {
      debugPrint(
        'SPARK VIDEO CALL: timer fired but callFullyConnected=false — NOT navigating to decision screen. Showing error overlay instead.',
      );
      if (mounted) {
        setState(() {
          _showErrorOverlay = true;
          _overlayError =
              'Could not connect to video call. The other person may not have joined.';
        });
      }
      return;
    }
    debugPrint(
      'SPARK VIDEO CALL: timer expired and callFullyConnected=true — proceeding to end call',
    );
    _endCall();
  }

  /// Mark the session as ended in Supabase so the other participant's listener fires.
  Future<void> _markSessionEndedInSupabase() async {
    final sessionId = _resolvedSessionId;
    if (sessionId == null) {
      // Try to resolve via matchId as fallback
      final matchId = widget.matchId;
      if (matchId == null || matchId.isEmpty) return;
      try {
        Map<String, dynamic>? row;
        if (widget.sessionKey != null && widget.sessionKey!.isNotEmpty) {
          row = await SupabaseService.instance.client
              .from('spark_sessions')
              .select('id')
              .eq('match_id', matchId)
              .eq('session_key', widget.sessionKey!)
              .limit(1)
              .maybeSingle();
        } else {
          final rows = await SupabaseService.instance.client
              .from('spark_sessions')
              .select('id')
              .eq('match_id', matchId)
              .order('created_at', ascending: false)
              .limit(1);
          row = (rows as List).isNotEmpty
              ? Map<String, dynamic>.from(rows.first)
              : null;
        }
        final id = row?['id'] as String?;
        if (id == null) return;
        await _writeEndedRecord(id);
      } catch (e) {
        debugPrint(
          'SPARK VIDEO CALL: error marking session ended (fallback) — $e',
        );
      }
      return;
    }
    await _writeEndedRecord(sessionId);
  }

  Future<void> _writeEndedRecord(String sessionId) async {
    final currentUserId = SupabaseService.instance.currentUserId;
    try {
      await SupabaseService.instance.client
          .from('spark_sessions')
          .update({
            'status': 'ended',
            'ended_by': currentUserId,
            'ended_at': DateTime.now().toIso8601String(),
          })
          .eq('id', sessionId);
      final matchId = widget.matchId?.trim();
      final sessionKey = widget.sessionKey?.trim();
      if (matchId != null &&
          matchId.isNotEmpty &&
          sessionKey != null &&
          sessionKey.isNotEmpty) {
        await SupabaseService.instance.client
            .from('matches')
            .update({'current_session_key': null})
            .eq('id', matchId)
            .eq('current_session_key', sessionKey);
      }
      debugPrint(
        'SPARK VIDEO CALL: session $sessionId marked as ended by $currentUserId',
      );
    } catch (e) {
      debugPrint('SPARK VIDEO CALL: error writing ended record — $e');
    }
  }

  Future<void> _endCall({bool enforceMinimumStay = true}) async {
    if (_callEnded) return;

    // Fix 4: enforce minimum stay duration
    if (enforceMinimumStay && _callScreenStartTime != null) {
      final elapsed = DateTime.now()
          .difference(_callScreenStartTime!)
          .inSeconds;
      if (elapsed < _minimumStaySeconds) {
        final remaining = _minimumStaySeconds - elapsed;
        debugPrint(
          'SPARK VIDEO CALL: minimum stay not reached — elapsed=${elapsed}s, waiting ${remaining}s more before navigating',
        );
        await Future.delayed(Duration(seconds: remaining));
        if (!mounted) return;
      }
    }

    _callEnded = true;
    debugPrint(
      'SPARK VIDEO CALL: ending call — navigating to decision screen. callFullyConnected=$_callFullyConnected',
    );
    _countdownTimer?.cancel();
    _timerPulseCtrl.stop();

    // Bug 2/4: Await the leave call BEFORE navigating so audio fully stops
    await _leaveCallSilently();

    // Mark session as ended in Supabase so the other participant's listener fires
    await _markSessionEndedInSupabase();

    if (mounted) {
      if (kIsWeb) {
        debugPrint('DAILY WEB END: post-session navigation started');
      }
      debugPrint('SPARK VIDEO CALL: showing decision screen now');
      widget.onCallEnded();
    }
  }

  Future<void> _toggleMute() async {
    final nextMuted = !_isMuted;
    try {
      final nativeState = _nativeCallKey.currentState;
      if (nativeState == null) {
        throw StateError('Native Daily call is not ready');
      }
      await nativeState.setMuted(nextMuted);
      if (!mounted) return;
      setState(() => _isMuted = nextMuted);
    } catch (e) {
      debugPrint('SPARK VIDEO CALL: native mute toggle failed — $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not update microphone. Please try again.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _toggleCamera() async {
    final nextCameraOff = !_isCameraOff;
    try {
      final nativeState = _nativeCallKey.currentState;
      if (nativeState == null) {
        throw StateError('Native Daily call is not ready');
      }
      await nativeState.setCameraOff(nextCameraOff);
      if (!mounted) return;
      setState(() => _isCameraOff = nextCameraOff);
    } catch (e) {
      debugPrint('SPARK VIDEO CALL: native camera toggle failed — $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not update camera. Please try again.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  void _onWebMuteChanged(bool muted) {
    if (!mounted || _isMuted == muted) return;
    setState(() => _isMuted = muted);
  }

  void _onWebCameraChanged(bool cameraOff) {
    if (!mounted || _isCameraOff == cameraOff) return;
    setState(() => _isCameraOff = cameraOff);
  }

  void _sendWebToggleMute() {
    setState(() => _isMuted = !_isMuted);
    _webViewKey.currentState?.sendToggleMuteCommand();
  }

  void _sendWebToggleCamera() {
    setState(() => _isCameraOff = !_isCameraOff);
    _webViewKey.currentState?.sendToggleCameraCommand();
  }

  void _sendWebEndCall() {
    _webViewKey.currentState?.sendEndCallCommand();
  }

  String? get _reportedUserId {
    final rawId = widget.otherUser['id']?.toString().trim();
    if (rawId == null || rawId.isEmpty) return null;
    return rawId;
  }

  String get _reportedUserName {
    final name = widget.otherUser['name']?.toString().trim();
    if (name == null || name.isEmpty) return 'your match';
    return name;
  }

  String? get _sparkSessionReportContext {
    final parts = <String>[];
    final matchId = widget.matchId?.trim();
    final sessionKey = widget.sessionKey?.trim();
    if (matchId != null && matchId.isNotEmpty) {
      parts.add('match_id: $matchId');
    }
    if (sessionKey != null && sessionKey.isNotEmpty) {
      parts.add('session_key: $sessionKey');
    }
    if (parts.isEmpty) return null;
    return 'Spark Session context\n${parts.join('\n')}';
  }

  Future<void> _reportLiveSessionUser({required bool endAfter}) async {
    final reportedUserId = _reportedUserId;
    if (reportedUserId == null) {
      _showSafetyUnavailableMessage();
      return;
    }

    final submitted = await showReportUserSheet(
      context,
      reportedUserId: reportedUserId,
      reportedUserName: _reportedUserName,
      source: 'spark_session',
      matchId: widget.matchId,
      contextNote: _sparkSessionReportContext,
    );
    if (!submitted || !mounted) return;

    if (endAfter) {
      await _endCall(enforceMinimumStay: false);
    }
  }

  Future<void> _blockLiveSessionUser({required bool endAfter}) async {
    final blockedUserId = _reportedUserId;
    if (blockedUserId == null) {
      _showSafetyUnavailableMessage();
      return;
    }

    final blocked = await showBlockUserDialog(
      context,
      blockedUserId: blockedUserId,
      blockedUserName: _reportedUserName,
      source: 'spark_session',
      matchId: widget.matchId,
    );
    if (!blocked || !mounted) return;

    if (endAfter || _callActive || _callFullyConnected) {
      await _endCall(enforceMinimumStay: false);
    }
  }

  void _showSafetyUnavailableMessage() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Safety action is unavailable for this session.',
          style: GoogleFonts.dmSans(),
        ),
        backgroundColor: AppTheme.error,
      ),
    );
  }

  String get _timerDisplay {
    final m = _secondsRemaining ~/ 60;
    final s = _secondsRemaining % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Color get _timerColor {
    if (_secondsRemaining <= 30) return AppTheme.error;
    if (_secondsRemaining <= 60) return AppTheme.warning;
    return AppTheme.sparkGreen;
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _timerPulseCtrl.dispose();
    // Bug 4: If the user closes the app mid-session, mark the session as ended
    // and leave the call so audio is fully terminated
    if (!_callEnded) {
      _callEnded = true;
      _markSessionEndedInSupabase();
      _leaveCallSilently();
    }
    _sessionChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Fix 3: Never replace the call screen with an error — always render video layer
    // Error is shown as an overlay on top of the video
    final content = Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video layer — always present so DailyCallView starts connecting immediately
          if (kIsWeb)
            SparkVideoWebView(
              // Bug 4: Use GlobalKey so we can call leaveCall() explicitly on timer expiry
              key: _webViewKey,
              roomUrl: widget.roomUrl,
              meetingToken: widget.meetingToken,
              // Fix 1: onConnected maps to _onCallStateJoined (not _onCallConnected)
              onConnected: _onCallStateJoined,
              onRemoteParticipantJoined: _onRemoteParticipantJoined,
              onEndRequested: () => _endCall(enforceMinimumStay: false),
              onMuteChanged: _onWebMuteChanged,
              onCameraChanged: _onWebCameraChanged,
              // Fix 3: errors shown as overlay, not closing the call
              onError: _onDailyError,
              showFaceMeetTimer: _callFullyConnected,
              timerText: _timerDisplay,
              timerIsUrgent: _secondsRemaining <= 60,
            )
          else
            DailyCallView(
              // Bug 2 fix: Use GlobalKey so we can call leave() explicitly before navigation
              key: _nativeCallKey,
              roomUrl: widget.roomUrl,
              meetingToken: widget.meetingToken,
              onCallEnded: _endCall,
              // Fix 1: onCallConnected maps to _onCallStateJoined
              onCallConnected: _onCallStateJoined,
              // Fix 3: errors shown as overlay
              onCallError: _onDailyError,
              // Hide waiting overlay when remote participant joins
              onRemoteParticipantJoined: _onRemoteParticipantJoined,
            ),
          // Connecting overlay — shown until call state is joined
          if (!kIsWeb && _callConnecting) _buildConnectingOverlay(),
          // Waiting for remote participant overlay
          if (!kIsWeb &&
              !_callConnecting &&
              _callActive &&
              !_callFullyConnected)
            _buildWaitingForParticipantOverlay(),
          // Dark gradient overlay (only when call is fully connected)
          if (!kIsWeb && _callFullyConnected)
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xCC000000),
                    Colors.transparent,
                    Colors.transparent,
                    Color(0xCC000000),
                  ],
                  stops: [0.0, 0.2, 0.7, 1.0],
                ),
              ),
            ),
          // Top bar with timer (only when call is fully connected)
          if (!kIsWeb && _callFullyConnected)
            SafeArea(
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Row(
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.otherUser['name'] as String? ?? 'Your Match',
                            style: GoogleFonts.dmSans(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          if ((widget.otherUser['city'] as String? ?? '')
                              .isNotEmpty)
                            Text(
                              widget.otherUser['city'] as String,
                              style: GoogleFonts.dmSans(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                        ],
                      ),
                      const Spacer(),
                      // Countdown timer pill — only shown after call fully connects
                      ScaleTransition(
                        scale: _timerPulse,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: _timerColor.withAlpha(51),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: _timerColor.withAlpha(128),
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.timer_rounded,
                                    color: _timerColor,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _timerDisplay,
                                    style: GoogleFonts.dmSans(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: _timerColor,
                                      fontFeatures: [
                                        const FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Bottom controls (shown when call is active — joined or fully connected)
          if (!kIsWeb && (_callActive || _callFullyConnected))
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _ControlButton(
                          icon: _isMuted
                              ? Icons.mic_off_rounded
                              : Icons.mic_rounded,
                          label: _isMuted ? 'Unmute' : 'Mute',
                          onTap: _toggleMute,
                          isActive: _isMuted,
                        ),
                        _ControlButton(
                          icon: Icons.call_end_rounded,
                          label: 'End',
                          onTap: _endCall,
                          isDestructive: true,
                          size: 64,
                        ),
                        _ControlButton(
                          icon: _isCameraOff
                              ? Icons.videocam_off_rounded
                              : Icons.videocam_rounded,
                          label: _isCameraOff ? 'Camera On' : 'Camera Off',
                          onTap: _toggleCamera,
                          isActive: _isCameraOff,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (kIsWeb) _buildWebOverlayControls(),
          _buildLiveSafetyMenu(),
          // Fix 3: Error overlay — shown on top of video, user must explicitly dismiss or tap End Call
          if (_showErrorOverlay) _buildErrorOverlay(),
        ],
      ),
    );

    if (kIsWeb) {
      return content;
    }

    return GestureDetector(
      onTap: () => setState(() => _showControls = !_showControls),
      child: content,
    );
  }

  Widget _buildLiveSafetyMenu() {
    return Positioned(
      top: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 12, 16, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: PopupMenuButton<_LiveSafetyAction>(
                tooltip: 'Safety',
                color: const Color(0xFF1A1A1E),
                elevation: 12,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(color: Colors.white.withAlpha(24)),
                ),
                offset: const Offset(0, 48),
                onSelected: (action) {
                  switch (action) {
                    case _LiveSafetyAction.report:
                      _reportLiveSessionUser(endAfter: false);
                      break;
                    case _LiveSafetyAction.block:
                      _blockLiveSessionUser(endAfter: true);
                      break;
                    case _LiveSafetyAction.endAndReport:
                      _reportLiveSessionUser(endAfter: true);
                      break;
                    case _LiveSafetyAction.endAndBlock:
                      _blockLiveSessionUser(endAfter: true);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  _safetyMenuItem(
                    value: _LiveSafetyAction.report,
                    icon: Icons.flag_outlined,
                    label: 'Report User',
                  ),
                  _safetyMenuItem(
                    value: _LiveSafetyAction.block,
                    icon: Icons.block_rounded,
                    label: 'Block User',
                    destructive: true,
                  ),
                  const PopupMenuDivider(height: 8),
                  _safetyMenuItem(
                    value: _LiveSafetyAction.endAndReport,
                    icon: Icons.report_gmailerrorred_rounded,
                    label: 'End and Report',
                    destructive: true,
                  ),
                  _safetyMenuItem(
                    value: _LiveSafetyAction.endAndBlock,
                    icon: Icons.phone_disabled_rounded,
                    label: 'End and Block',
                    destructive: true,
                  ),
                ],
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(86),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withAlpha(46),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.shield_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuEntry<_LiveSafetyAction> _safetyMenuItem({
    required _LiveSafetyAction value,
    required IconData icon,
    required String label,
    bool destructive = false,
  }) {
    final color = destructive ? AppTheme.error : Colors.white;
    return PopupMenuItem<_LiveSafetyAction>(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: color, size: 19),
          const SizedBox(width: 10),
          Text(
            label,
            style: GoogleFonts.dmSans(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectingOverlay() {
    return Container(
      color: Colors.black87,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: Color(0xFFFF4458),
              strokeWidth: 3,
            ),
            const SizedBox(height: 24),
            Text(
              'Connecting video',
              style: GoogleFonts.dmSans(
                fontSize: 16,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Setting up your Spark Session',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebOverlayControls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ControlButton(
                icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: _isMuted ? 'Unmute' : 'Mute',
                onTap: _sendWebToggleMute,
                isActive: _isMuted,
              ),
              _ControlButton(
                icon: Icons.call_end_rounded,
                label: 'End',
                onTap: _sendWebEndCall,
                isDestructive: true,
                size: 64,
              ),
              _ControlButton(
                icon: _isCameraOff
                    ? Icons.videocam_off_rounded
                    : Icons.videocam_rounded,
                label: _isCameraOff ? 'Camera On' : 'Camera Off',
                onTap: _sendWebToggleCamera,
                isActive: _isCameraOff,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Shown after local user joins but before remote participant arrives
  Widget _buildWaitingForParticipantOverlay() {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(
              color: Color(0xFFFF4458),
              strokeWidth: 3,
            ),
            const SizedBox(height: 24),
            Text(
              'Waiting for your match',
              style: GoogleFonts.dmSans(
                fontSize: 16,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The timer will start when they join',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Fix 3: Error shown as overlay on top of video — not a full-screen replacement
  Widget _buildErrorOverlay() {
    return Container(
      color: Colors.black54,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0x1AFFFFFF),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.error.withAlpha(80),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Dismiss button (top right)
                      Align(
                        alignment: Alignment.topRight,
                        child: GestureDetector(
                          onTap: _dismissErrorOverlay,
                          child: const Icon(
                            Icons.close_rounded,
                            color: Colors.white54,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: AppTheme.error.withAlpha(30),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.videocam_off_rounded,
                          color: AppTheme.error,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Could not connect to video call',
                        style: GoogleFonts.dmSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _overlayError.isNotEmpty
                            ? _overlayError
                            : 'An unexpected error occurred.',
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: _dismissErrorOverlay,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white12,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: Colors.white24,
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  'Dismiss',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white70,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GestureDetector(
                              onTap: _retryConnection,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFFF4458),
                                      Color(0xFFFF6B7A),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  'Retry',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isActive;
  final bool isDestructive;
  final double size;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isActive = false,
    this.isDestructive = false,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDestructive ? AppTheme.error : AppTheme.surfaceGlass;
    final iconColor = isDestructive
        ? Colors.white
        : isActive
        ? AppTheme.primary
        : Colors.white;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(size / 2),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: bg,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isDestructive
                        ? AppTheme.error.withAlpha(180)
                        : AppTheme.borderGlassActive,
                    width: 1.5,
                  ),
                ),
                child: Icon(icon, color: iconColor, size: size * 0.42),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: GoogleFonts.dmSans(
              fontSize: 11,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
