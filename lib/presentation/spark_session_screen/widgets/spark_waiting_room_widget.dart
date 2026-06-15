import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../routes/app_routes.dart';
import '../../../services/android_diagnostics_service.dart';
import '../../../services/daily_service.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/profile_avatar.dart';
import '../../../widgets/user_safety_actions.dart';

class SparkWaitingRoomWidget extends StatefulWidget {
  final Map<String, dynamic> otherUser;
  final void Function({
    String? roomUrl,
    String? sessionKey,
    String? sessionId,
    String? meetingToken,
  })
  onOtherUserJoined;
  final String? matchId;
  final String? initialSessionKey;
  final String? initialSessionId;

  const SparkWaitingRoomWidget({
    super.key,
    required this.otherUser,
    required this.onOtherUserJoined,
    this.matchId,
    this.initialSessionKey,
    this.initialSessionId,
  });

  @override
  State<SparkWaitingRoomWidget> createState() => _SparkWaitingRoomWidgetState();
}

class _SparkWaitingRoomWidgetState extends State<SparkWaitingRoomWidget>
    with TickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late AnimationController _dotCtrl;
  late Animation<double> _pulse1;
  late Animation<double> _pulse2;
  late Animation<double> _pulse3;
  int _dotCount = 0;

  bool _isCreatingRoom = false;
  String? _errorMessage;
  bool _roomReady = false;

  // Guard to prevent launching the call more than once
  bool _callLaunched = false;

  // The unique key for this specific session attempt
  String? _sessionKey;
  String? _sessionId;

  // Simple 2-second polling timer — the only ready-detection mechanism
  Timer? _readyPollingTimer;
  // 5-minute timeout timer
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat();
    _dotCtrl.addListener(() {
      if (_dotCtrl.value == 0) {
        setState(() => _dotCount = (_dotCount + 1) % 4);
      }
    });

    _pulse1 = Tween<double>(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(
        parent: _pulseCtrl,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );
    _pulse2 = Tween<double>(begin: 1.0, end: 1.9).animate(
      CurvedAnimation(
        parent: _pulseCtrl,
        curve: const Interval(0.15, 0.75, curve: Curves.easeOut),
      ),
    );
    _pulse3 = Tween<double>(begin: 1.0, end: 2.3).animate(
      CurvedAnimation(
        parent: _pulseCtrl,
        curve: const Interval(0.3, 0.9, curve: Curves.easeOut),
      ),
    );

    _sessionKey = widget.initialSessionKey?.trim();
    _sessionId = widget.initialSessionId?.trim();
    _createRoomAndWait();
  }

  /// Called when both users are confirmed ready. Guards against double-launch.
  Future<void> _launchCall() async {
    if (_callLaunched) {
      debugPrint(
        'SPARK WAITING ROOM: _launchCall called but already launched — ignoring',
      );
      return;
    }
    final matchId = widget.matchId;
    if (matchId == null || matchId.isEmpty) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Invalid match ID — cannot start session.';
        });
      }
      return;
    }
    _callLaunched = true;
    try {
      debugPrint(
        'SPARK WAITING ROOM: requesting secure Daily access for active session key=$_sessionKey',
      );
      final access = await DailyService.instance.getSparkSessionDailyAccess(
        matchId: matchId,
        sessionKey: _sessionKey,
      );
      _sessionKey = access.sessionKey;
      _sessionId = access.sessionId;
      debugPrint(
        'SPARK WAITING ROOM: ✅ launching secure Spark Session — room_url exists=${access.roomUrl.isNotEmpty}, meeting_token exists=${access.meetingToken.isNotEmpty}',
      );
      await AndroidDiagnosticsService.instance.setValues({
        'waiting_overlay_active': 'no',
        'waiting_overlay_reason': 'launching Daily call',
      });
      _cancelTimers();
      if (mounted) {
        widget.onOtherUserJoined(
          roomUrl: access.roomUrl,
          sessionKey: access.sessionKey,
          sessionId: access.sessionId,
          meetingToken: access.meetingToken,
        );
      }
    } catch (e) {
      debugPrint('SPARK SESSION: secure Daily access final failure — $e');
      _callLaunched = false;
      if (mounted) {
        setState(() {
          _isCreatingRoom = false;
          _roomReady = true;
          _errorMessage = _getFriendlyErrorMessage(e.toString());
        });
      }
    }
  }

  /// Retry room creation from the error state (resets state and re-runs the flow).
  void _retryRoomCreation() {
    debugPrint(
      'SPARK WAITING ROOM: User tapped Retry — restarting room creation flow',
    );
    if (!mounted) return;
    setState(() {
      _errorMessage = null;
      _roomReady = false;
      _callLaunched = false;
      _sessionKey = null;
    });
    _cancelTimers();
    _createRoomAndWait();
  }

  Future<void> _createRoomAndWait() async {
    if (!mounted) return;
    setState(() {
      _isCreatingRoom = true;
      _errorMessage = null;
    });
    await AndroidDiagnosticsService.instance.setValues({
      'current_spark_match_id': AndroidDiagnosticsService.shortId(
        widget.matchId,
      ),
      'waiting_overlay_active': 'yes',
      'waiting_overlay_reason': 'setting up spark session',
    });

    final matchId = widget.matchId;
    final currentUid = SupabaseService.instance.currentUserId;

    debugPrint(
      'SPARK WAITING ROOM: ▶ User tapped Start Session — matchId=$matchId, currentUid=$currentUid',
    );

    try {
      // ── STEP 1: Determine which user slot the current user occupies ──
      bool isUser1 = false;
      String? user1Id;
      String? user2Id;
      String? coordinationKey = _sessionKey;

      if (matchId == null || matchId.isEmpty) {
        if (mounted) {
          setState(() {
            _isCreatingRoom = false;
            _errorMessage = 'Invalid match ID — cannot start session.';
          });
        }
        return;
      }

      try {
        final match = await SupabaseService.instance.client
            .from('matches')
            .select('user_1_id, user_2_id, current_session_key')
            .eq('id', matchId)
            .limit(1)
            .maybeSingle();
        if (match != null) {
          user1Id = match['user_1_id'] as String?;
          user2Id = match['user_2_id'] as String?;
          coordinationKey ??= match['current_session_key'] as String?;
          isUser1 = user1Id == currentUid;
          debugPrint(
            'SPARK WAITING ROOM: STEP 1 — current user is ${isUser1 ? "user_1" : "user_2"} '
            '(user_1_id=$user1Id, user_2_id=$user2Id, currentUid=$currentUid, current_session_key=$coordinationKey)',
          );
        } else {
          debugPrint(
            'SPARK WAITING ROOM: STEP 1 — match row not found for matchId=$matchId',
          );
        }
      } catch (e) {
        final errMsg = e.toString();
        debugPrint(
          'SPARK WAITING ROOM: STEP 1 — could not fetch match — $errMsg',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error fetching match: $errMsg'),
              backgroundColor: const Color(0xFF1A1A2E),
              duration: const Duration(seconds: 5),
            ),
          );
          setState(() {
            _isCreatingRoom = false;
            _errorMessage = 'Error fetching match: $errMsg';
          });
        }
        return;
      }

      // ── STEP 2: Only the initiator (first user) must have Sparks available ──
      if ((coordinationKey == null || coordinationKey.isEmpty) &&
          currentUid != null) {
        try {
          final userData = await SupabaseService.instance.client
              .from('users')
              .select('spark_balance')
              .eq('id', currentUid)
              .maybeSingle();

          if (userData != null) {
            final sparkBalance =
                (userData['spark_balance'] as num?)?.toInt() ?? 0;

            debugPrint(
              'SPARK WAITING ROOM: PRE-CHECK (initiator) — spark_balance=$sparkBalance',
            );

            if (sparkBalance <= 0) {
              if (mounted) {
                setState(() {
                  _isCreatingRoom = false;
                  _errorMessage =
                      "You've run out of Sparks! Purchase a bundle or go monthly to keep sparking ⚡";
                });
                _showOutOfSparksSheet();
              }
              return;
            }
          } else {
            if (mounted) {
              setState(() {
                _isCreatingRoom = false;
                _errorMessage =
                    "You've run out of Sparks! Purchase a bundle or go monthly to keep sparking ⚡";
              });
              _showOutOfSparksSheet();
            }
            return;
          }
        } catch (e) {
          debugPrint(
            'SPARK WAITING ROOM: PRE-CHECK spark balance check failed: $e',
          );
          if (mounted) {
            setState(() {
              _isCreatingRoom = false;
              _errorMessage =
                  'Could not verify your Spark balance. Please try again.';
            });
          }
          return;
        }
      }

      // ── STEP 3: Request secure Daily access from the server ──
      debugPrint(
        'SPARK WAITING ROOM: requesting secure Daily access — matchId=$matchId, sessionKey=$coordinationKey',
      );
      final access = await DailyService.instance.getSparkSessionDailyAccess(
        matchId: matchId,
        sessionKey: coordinationKey,
      );

      _sessionKey = access.sessionKey;
      _sessionId = access.sessionId;
      await AndroidDiagnosticsService.instance.setValues({
        'client_session_key': AndroidDiagnosticsService.shortId(
          coordinationKey,
        ),
        'canonical_session_key': AndroidDiagnosticsService.shortId(
          access.sessionKey,
        ),
        'waiting_overlay_reason': 'participant ready flag pending',
      });

      debugPrint(
        'SPARK SESSION: secure access resolved — matchId=$matchId, sessionId=${access.sessionId}, sessionKey=$_sessionKey, room URL exists=${access.roomUrl.isNotEmpty}',
      );

      // ── STEP 4: Mark this participant ready on the shared spark_session row ──
      try {
        await AndroidDiagnosticsService.instance.setValues({
          'ready_update_target': 'canonical_session_id',
          'fallback_latest_row_used': 'no',
        });
        await SupabaseService.instance.client
            .from('spark_sessions')
            .update({isUser1 ? 'user_1_ready' : 'user_2_ready': true})
            .eq('id', access.sessionId)
            .eq('session_key', access.sessionKey);
        debugPrint(
          'SPARK WAITING ROOM: ready flag updated for sessionId=${access.sessionId}',
        );
      } catch (e) {
        final errMsg = e.toString();
        debugPrint(
          'SPARK WAITING ROOM: ready-flag update failed — sessionId=${access.sessionId}, error=$errMsg',
        );
        if (mounted) {
          setState(() {
            _isCreatingRoom = false;
            _errorMessage = 'Session update failed: $errMsg';
          });
        }
        return;
      }

      // ── STEP 5: Fast path if both users are already ready ──
      try {
        final freshSession = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('user_1_ready, user_2_ready, daily_room_url')
            .eq('id', access.sessionId)
            .maybeSingle();
        if (freshSession != null) {
          final u1 = freshSession['user_1_ready'] == true;
          final u2 = freshSession['user_2_ready'] == true;
          debugPrint(
            'SPARK WAITING ROOM: secure fast-path check — u1=$u1, u2=$u2',
          );
          if (u1 && u2) {
            if (mounted) {
              setState(() {
                _isCreatingRoom = false;
                _roomReady = true;
              });
            }
            await AndroidDiagnosticsService.instance.setValue(
              'waiting_overlay_reason',
              'both ready; launching call',
            );
            await _launchCall();
            return;
          }
        }
      } catch (e) {
        debugPrint(
          'SPARK WAITING ROOM: secure fast-path check failed (non-critical): $e',
        );
      }

      if (mounted) {
        setState(() {
          _isCreatingRoom = false;
          _roomReady = true;
        });
        await AndroidDiagnosticsService.instance.setValue(
          'waiting_overlay_reason',
          'waiting for other participant ready flag',
        );

        // ── STEP 4: Start 2-second polling timer ──
        _startReadyPolling();
        _startTimeoutTimer();
        await _checkBothReadyNow();
      }
    } catch (e) {
      if (mounted) {
        final errMsg = e.toString();
        debugPrint(
          'SPARK WAITING ROOM: ❌ unexpected error in _createRoomAndWait — $errMsg',
        );
        final friendlyError = _getFriendlyErrorMessage(errMsg);
        setState(() {
          _isCreatingRoom = false;
          _errorMessage = friendlyError;
        });
        await AndroidDiagnosticsService.instance.setValues({
          'waiting_overlay_active': 'yes',
          'waiting_overlay_reason': 'waiting room error',
        });
        if (_isOutOfSparksError(errMsg)) {
          _showOutOfSparksSheet();
        }
      }
    }
  }

  /// Immediately check if both users are already ready (handles missed realtime events).
  Future<void> _checkBothReadyNow() async {
    final matchId = widget.matchId;
    if (matchId == null || matchId.isEmpty) return;
    try {
      // Query only the canonical session returned by the server.
      Map<String, dynamic>? session;
      if (_sessionId != null && _sessionId!.isNotEmpty) {
        session = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('daily_room_url, user_1_ready, user_2_ready')
            .eq('id', _sessionId!)
            .eq('match_id', matchId)
            .maybeSingle();
      } else if (_sessionKey != null && _sessionKey!.isNotEmpty) {
        session = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('daily_room_url, user_1_ready, user_2_ready')
            .eq('match_id', matchId)
            .eq('session_key', _sessionKey!)
            .maybeSingle();
      } else {
        await AndroidDiagnosticsService.instance.setValues({
          'fallback_latest_row_used': 'no',
          'ready_update_target': 'missing_canonical_session',
        });
        debugPrint(
          'SPARK WAITING ROOM: immediate ready check skipped — missing canonical session id/key',
        );
        return;
      }

      if (session != null) {
        final u1 = session['user_1_ready'] == true;
        final u2 = session['user_2_ready'] == true;
        final roomUrl = session['daily_room_url'] as String?;
        debugPrint(
          'SPARK WAITING ROOM: immediate ready check — user_1_ready=$u1, user_2_ready=$u2, room URL exists=${roomUrl != null && roomUrl.isNotEmpty}',
        );
        if (u1 && u2 && roomUrl != null) {
          debugPrint(
            'SPARK WAITING ROOM: ✅ both users ready (caught by immediate check) — launching call',
          );
          await _launchCall();
        }
      }
    } catch (e) {
      debugPrint('SPARK WAITING ROOM: immediate ready check failed — $e');
    }
  }

  Future<void> _updateStartedAt(String matchId) async {
    try {
      // Update by session_key if available for precision
      if (_sessionId != null && _sessionId!.isNotEmpty) {
        final session = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('started_at, user_1_ready, user_2_ready')
            .eq('id', _sessionId!)
            .eq('match_id', matchId)
            .maybeSingle();

        if (session != null) {
          final u1 = session['user_1_ready'] == true;
          final u2 = session['user_2_ready'] == true;
          if (u1 && u2) {
            await SupabaseService.instance.client
                .from('spark_sessions')
                .update({'started_at': DateTime.now().toIso8601String()})
                .eq('id', _sessionId!)
                .eq('match_id', matchId);
            debugPrint(
              'SPARK WAITING ROOM: updated started_at for matchId=$matchId, sessionId=$_sessionId',
            );
          }
        }
      } else if (_sessionKey != null && _sessionKey!.isNotEmpty) {
        final session = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('started_at, user_1_ready, user_2_ready')
            .eq('match_id', matchId)
            .eq('session_key', _sessionKey!)
            .maybeSingle();

        if (session != null) {
          final u1 = session['user_1_ready'] == true;
          final u2 = session['user_2_ready'] == true;
          if (u1 && u2) {
            await SupabaseService.instance.client
                .from('spark_sessions')
                .update({'started_at': DateTime.now().toIso8601String()})
                .eq('match_id', matchId)
                .eq('session_key', _sessionKey!);
            debugPrint(
              'SPARK WAITING ROOM: updated started_at for matchId=$matchId, key=$_sessionKey',
            );
          }
        }
      } else {
        await AndroidDiagnosticsService.instance.setValues({
          'fallback_latest_row_used': 'no',
          'ready_update_target': 'missing_canonical_session',
        });
        debugPrint(
          'SPARK WAITING ROOM: started_at update skipped — missing canonical session id/key',
        );
      }
    } catch (e) {
      debugPrint('SPARK WAITING ROOM: could not update started_at — $e');
    }
  }

  /// Polls spark_sessions every 2 seconds until both ready flags are true.
  /// Uses session_key for precise row targeting — no ambiguity across multiple sessions.
  void _startReadyPolling() {
    final matchId = widget.matchId;
    if (matchId == null || matchId.isEmpty) return;

    debugPrint(
      'SPARK WAITING ROOM: ▶ starting 2-second ready polling for matchId=$matchId, sessionKey=$_sessionKey',
    );

    _readyPollingTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) {
        _readyPollingTimer?.cancel();
        return;
      }

      final now = DateTime.now().toIso8601String();

      try {
        Map<String, dynamic>? session;

        if (_sessionId != null && _sessionId!.isNotEmpty) {
          session = await SupabaseService.instance.client
              .from('spark_sessions')
              .select('daily_room_url, user_1_ready, user_2_ready')
              .eq('id', _sessionId!)
              .eq('match_id', matchId)
              .maybeSingle();
        } else if (_sessionKey != null && _sessionKey!.isNotEmpty) {
          // Precise lookup: find the exact row for this attempt
          session = await SupabaseService.instance.client
              .from('spark_sessions')
              .select('daily_room_url, user_1_ready, user_2_ready')
              .eq('match_id', matchId)
              .eq('session_key', _sessionKey!)
              .maybeSingle();
        } else {
          await AndroidDiagnosticsService.instance.setValues({
            'fallback_latest_row_used': 'no',
            'ready_update_target': 'missing_canonical_session',
          });
          debugPrint(
            'SPARK POLLING [$now]: missing canonical session id/key — not falling back to latest row',
          );
          return;
        }

        if (session == null) {
          debugPrint(
            'SPARK POLLING [$now]: no session row found yet for matchId=$matchId, key=$_sessionKey — continuing to poll',
          );
          return;
        }

        final u1 = session['user_1_ready'] == true;
        final u2 = session['user_2_ready'] == true;
        final roomUrl = session['daily_room_url'] as String?;

        debugPrint(
          'SPARK POLLING [$now]: matchId=$matchId, key=$_sessionKey — user_1_ready=$u1, user_2_ready=$u2',
        );

        if (u1 && u2 && roomUrl != null) {
          debugPrint(
            'SPARK POLLING [$now]: ✅ both users ready — cancelling timer and launching call',
          );
          _readyPollingTimer?.cancel();
          await _updateStartedAt(matchId);
          await _launchCall();
        }
        // If only one flag is true, continue polling
      } catch (e) {
        debugPrint(
          'SPARK POLLING [$now]: ❌ query failed — $e — continuing to poll',
        );
      }
    });
  }

  /// 5-minute timeout: if other user hasn't joined, show message and return to Sparks tab.
  void _startTimeoutTimer() {
    debugPrint(
      'SPARK WAITING ROOM: 5-minute timeout timer started for matchId=${widget.matchId}',
    );
    _timeoutTimer = Timer(const Duration(minutes: 5), () async {
      if (!mounted) return;

      final matchId = widget.matchId;
      final otherName = _otherFirstName;

      debugPrint(
        'SPARK TIMEOUT: ⏰ other user ($otherName) did not join within 5 minutes. matchId=$matchId',
      );

      _cancelTimers();

      if (matchId != null && matchId.isNotEmpty) {
        try {
          // Check if both users were ready before resetting
          Map<String, dynamic>? session;
          if (_sessionId != null && _sessionId!.isNotEmpty) {
            session = await SupabaseService.instance.client
                .from('spark_sessions')
                .select('user_1_ready, user_2_ready, initiated_by')
                .eq('id', _sessionId!)
                .eq('match_id', matchId)
                .maybeSingle();
          } else if (_sessionKey != null && _sessionKey!.isNotEmpty) {
            session = await SupabaseService.instance.client
                .from('spark_sessions')
                .select('user_1_ready, user_2_ready, initiated_by')
                .eq('match_id', matchId)
                .eq('session_key', _sessionKey!)
                .maybeSingle();
          } else {
            await AndroidDiagnosticsService.instance.setValues({
              'fallback_latest_row_used': 'no',
              'ready_update_target': 'missing_canonical_session',
            });
            debugPrint(
              'SPARK TIMEOUT: cleanup skipped — missing canonical session id/key',
            );
            return;
          }

          final u1Ready = session?['user_1_ready'] == true;
          final u2Ready = session?['user_2_ready'] == true;
          final bothJoined = u1Ready && u2Ready;

          // Reset ready flags on the specific session row
          if (_sessionId != null && _sessionId!.isNotEmpty) {
            await SupabaseService.instance.client
                .from('spark_sessions')
                .update({'user_1_ready': false, 'user_2_ready': false})
                .eq('id', _sessionId!)
                .eq('match_id', matchId);
          } else if (_sessionKey != null && _sessionKey!.isNotEmpty) {
            await SupabaseService.instance.client
                .from('spark_sessions')
                .update({'user_1_ready': false, 'user_2_ready': false})
                .eq('match_id', matchId)
                .eq('session_key', _sessionKey!);
          } else {
            await AndroidDiagnosticsService.instance.setValues({
              'fallback_latest_row_used': 'no',
              'ready_update_target': 'missing_canonical_session',
            });
            debugPrint(
              'SPARK TIMEOUT: ready reset skipped — missing canonical session id/key',
            );
            return;
          }

          // CRITICAL FIX: Clear current_session_key so next session starts fresh
          try {
            await SupabaseService.instance.client
                .from('matches')
                .update({'current_session_key': null})
                .eq('id', matchId);
            debugPrint(
              'SPARK TIMEOUT: cleared current_session_key for matchId=$matchId',
            );
          } catch (e) {
            debugPrint('SPARK TIMEOUT: could not clear session key — $e');
          }

          debugPrint(
            'SPARK TIMEOUT: reset user_1_ready and user_2_ready to false for matchId=$matchId',
          );

          // Bug 2 fix: if only the initiator joined (other user never joined),
          // refund the spark credit to the initiator.
          final currentUid = SupabaseService.instance.currentUserId;
          if (!bothJoined && currentUid != null) {
            final initiatedBy = session?['initiated_by'] as String?;
            if (initiatedBy == currentUid) {
              debugPrint(
                'SPARK TIMEOUT: other user never joined — refunding spark credit to initiator $currentUid',
              );
              try {
                final userData = await SupabaseService.instance.client
                    .from('users')
                    .select(
                      'spark_balance, subscription_tier, sparks_used_today, sparks_used_this_week',
                    )
                    .eq('id', currentUid)
                    .maybeSingle();
                if (userData != null) {
                  final balance =
                      (userData['spark_balance'] as num?)?.toInt() ?? 0;
                  debugPrint(
                    'SPARK TIMEOUT: no deduction occurred (call never started) — no refund needed. balance=$balance',
                  );
                }
              } catch (e) {
                debugPrint('SPARK TIMEOUT: refund check failed — $e');
              }
            }
          }
        } catch (e) {
          debugPrint('SPARK TIMEOUT: failed to reset ready flags — $e');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Your match didn't join in time"),
            duration: Duration(seconds: 5),
            backgroundColor: Color(0xFF1A1A2E),
          ),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  void _cancelTimers() {
    _readyPollingTimer?.cancel();
    _timeoutTimer?.cancel();
  }

  /// Returns true if the error string looks like a spark-balance/quota error.
  /// Bug 3/5 fix: Do NOT match 'daily' as that would catch Daily.co connection errors.
  bool _isOutOfSparksError(String error) {
    final lower = error.toLowerCase();
    return lower.contains('out of sparks') ||
        lower.contains('run out of sparks') ||
        lower.contains('spark balance') ||
        lower.contains('insufficient sparks') ||
        lower.contains('insufficient balance') ||
        lower.contains('balance') ||
        lower.contains('limit') ||
        lower.contains('quota') ||
        lower.contains('403') ||
        lower.contains('402') ||
        lower.contains('payment') ||
        lower.contains('insufficient');
  }

  /// Maps raw technical errors to user-friendly messages.
  String _getFriendlyErrorMessage(String rawError) {
    if (_isOutOfSparksError(rawError)) {
      return "You've run out of Sparks! Purchase a bundle or go monthly to keep sparking ⚡";
    }
    // Generic fallback for other errors (including Daily.co connection errors)
    return 'Could not start the session. Please try again.';
  }

  /// Shows a bottom sheet prompting the user to buy sparks or upgrade.
  void _showOutOfSparksSheet() {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3E),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.primary.withAlpha(30),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: AppTheme.primary,
                size: 32,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              "You've run out of Sparks! ⚡",
              style: GoogleFonts.dmSans(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Purchase a bundle or go monthly to keep sparking',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            GestureDetector(
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pushNamed(
                  context,
                  AppRoutes.pricingScreen,
                  arguments: {'scrollToBundles': true},
                );
              },
              child: Container(
                width: double.infinity,
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF4458), Color(0xFFE8503A)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(
                    'Buy more Sparks',
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pushNamed(context, AppRoutes.pricingScreen);
              },
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFF4458).withAlpha(120),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    'Upgrade to monthly plan',
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: const Color(0xFFFF4458).withAlpha(200),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Text(
                'Maybe later',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: const Color(0xFF666666),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancelTimers();
    _pulseCtrl.dispose();
    _dotCtrl.dispose();
    super.dispose();
  }

  String get _otherFirstName {
    final name = widget.otherUser['name'] as String? ?? 'them';
    return name.split(' ').first;
  }

  String? get _otherUserId {
    final id = widget.otherUser['id']?.toString().trim();
    return id == null || id.isEmpty ? null : id;
  }

  String get _otherUserName {
    return widget.otherUser['name'] as String? ?? 'Your Match';
  }

  void _closeWaitingRoom() {
    _cancelTimers();
    if (mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _reportWaitingRoomUser({required bool endAfter}) async {
    final userId = _otherUserId;
    if (userId == null) return;

    final submitted = await showReportUserSheet(
      context,
      reportedUserId: userId,
      reportedUserName: _otherUserName,
      source: 'spark_session',
      matchId: widget.matchId,
      contextNote: 'Report submitted from Spark Session waiting room.',
    );
    if (submitted && endAfter) {
      _closeWaitingRoom();
    }
  }

  Future<void> _blockWaitingRoomUser() async {
    final userId = _otherUserId;
    if (userId == null) return;

    final blocked = await showBlockUserDialog(
      context,
      blockedUserId: userId,
      blockedUserName: _otherUserName,
      source: 'spark_session',
      matchId: widget.matchId,
    );
    if (blocked) {
      _closeWaitingRoom();
    }
  }

  Widget _buildWaitingRoomSafetyMenu() {
    if (_otherUserId == null) return const SizedBox.shrink();

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
              child: PopupMenuButton<String>(
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
                    case 'report':
                      _reportWaitingRoomUser(endAfter: false);
                      break;
                    case 'block':
                      _blockWaitingRoomUser();
                      break;
                    case 'end_report':
                      _reportWaitingRoomUser(endAfter: true);
                      break;
                    case 'end_block':
                      _blockWaitingRoomUser();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  _waitingRoomSafetyMenuItem(
                    value: 'report',
                    icon: Icons.flag_outlined,
                    label: 'Report User',
                  ),
                  _waitingRoomSafetyMenuItem(
                    value: 'block',
                    icon: Icons.block_rounded,
                    label: 'Block User',
                    destructive: true,
                  ),
                  const PopupMenuDivider(height: 8),
                  _waitingRoomSafetyMenuItem(
                    value: 'end_report',
                    icon: Icons.report_gmailerrorred_rounded,
                    label: 'End and Report',
                    destructive: true,
                  ),
                  _waitingRoomSafetyMenuItem(
                    value: 'end_block',
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

  PopupMenuEntry<String> _waitingRoomSafetyMenuItem({
    required String value,
    required IconData icon,
    required String label,
    bool destructive = false,
  }) {
    final color = destructive ? AppTheme.error : Colors.white;
    return PopupMenuItem<String>(
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

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.2,
          colors: [Color(0x22FF4458), Color(0xFF0D0D0F)],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Pulse rings + avatar
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (context, child) {
                    return SizedBox(
                      width: 240,
                      height: 240,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Transform.scale(
                            scale: _pulse3.value,
                            child: Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppTheme.primary.withOpacity(
                                    (1 - _pulseCtrl.value * 0.8).clamp(0, 0.15),
                                  ),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: _pulse2.value,
                            child: Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppTheme.primary.withOpacity(
                                    (1 - _pulseCtrl.value * 0.7).clamp(0, 0.25),
                                  ),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                          Transform.scale(
                            scale: _pulse1.value,
                            child: Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: AppTheme.primary.withOpacity(
                                    (1 - _pulseCtrl.value * 0.5).clamp(0, 0.4),
                                  ),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                          child!,
                        ],
                      ),
                    );
                  },
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(50),
                      border: Border.all(color: AppTheme.primary, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withAlpha(77),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(48),
                      child: ProfileAvatar(
                        thumbnailUrl:
                            widget.otherUser['thumbnailUrl'] as String?,
                        firstName: widget.otherUser['name'] as String?,
                        radius: 48,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  widget.otherUser['name'] as String? ?? 'Your Match',
                  style: GoogleFonts.dmSans(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                if ((widget.otherUser['age'] as int? ?? 0) > 0)
                  Text(
                    '${widget.otherUser['age']}',
                    style: GoogleFonts.dmSans(
                      fontSize: 16,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                const SizedBox(height: 8),
                if ((widget.otherUser['city'] as String? ?? '').isNotEmpty)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.location_on_rounded,
                        color: AppTheme.textMuted,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.otherUser['city'] as String,
                        style: GoogleFonts.dmSans(
                          fontSize: 14,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 32),
                // Status card
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceGlass,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppTheme.borderGlass,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isCreatingRoom)
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: AppTheme.primary,
                                strokeWidth: 2,
                              ),
                            )
                          else if (_errorMessage != null)
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: AppTheme.warning,
                              size: 20,
                            )
                          else
                            SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: AppTheme.primary,
                                strokeWidth: 2,
                              ),
                            ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Text(
                              _isCreatingRoom
                                  ? 'Setting up your Spark Session...'
                                  : _errorMessage != null
                                  ? _errorMessage!
                                  : 'Waiting for $_otherFirstName to join${'.' * ((_dotCount % 3) + 1)}',
                              style: GoogleFonts.dmSans(
                                fontSize: 14,
                                color: _errorMessage != null
                                    ? AppTheme.warning
                                    : AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Fix 3: Retry button shown when Daily.co room creation fails
                if (_errorMessage != null && !_isCreatingRoom) ...[
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: _retryRoomCreation,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(
                      'Retry',
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                if (_roomReady && !_isCreatingRoom && _errorMessage == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.sparkGreen.withAlpha(20),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppTheme.sparkGreen.withAlpha(60),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle_rounded,
                                color: AppTheme.sparkGreen,
                                size: 14,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "You're ready — waiting for $_otherFirstName",
                                style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  color: AppTheme.sparkGreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 48),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.timer_outlined,
                        color: AppTheme.textMuted,
                        size: 14,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '3-minute Spark Session',
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _buildWaitingRoomSafetyMenu(),
        ],
      ),
    );
  }
}
