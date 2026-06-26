import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../routes/app_routes.dart';
import '../../services/android_diagnostics_service.dart';
import '../../theme/app_theme.dart';
import '../../services/supabase_service.dart';
import '../../services/web_push_notification_service.dart';
import '../../widgets/user_safety_actions.dart';
import './widgets/spark_decision_widget.dart';
import './widgets/spark_video_call_widget.dart';
import './widgets/spark_waiting_room_widget.dart';

enum SparkSessionPhase { permissionCheck, waiting, inCall, decision, outcome }

class SparkSessionScreen extends StatefulWidget {
  const SparkSessionScreen({super.key});

  @override
  State<SparkSessionScreen> createState() => _SparkSessionScreenState();
}

class _SparkSessionScreenState extends State<SparkSessionScreen> {
  SparkSessionPhase _phase = SparkSessionPhase.permissionCheck;
  bool _mutualSpark = false;
  bool _waitingForOtherDecision = false;

  // Room access payload populated after secure Daily access is fetched
  String? _dailyRoomUrl;
  String? _dailyMeetingToken;
  String? _sparkSessionId;

  // Match ID from route arguments
  String? _matchId;
  String? _matchedUserId;

  // Session key from the waiting room — used for precise spark deduction
  String? _sessionKey;

  // Real matched user profile loaded from Supabase
  Map<String, dynamic>? _otherUserProfile;
  bool _loadingProfile = true;

  // Permission state
  bool _permissionDenied = false;
  Timer? _decisionStatusTimer;
  bool _chatNavigationStarted = false;
  bool _remoteParticipantEverSeen = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic>) {
      _matchId = args['matchId'] as String?;
      _matchedUserId = args['matchedUserId'] as String?;
    }
    if (_loadingProfile) {
      _checkFeatureGatingThenLoad();
    }
  }

  /// Check spark balance before allowing session entry.
  /// Simple rule: if spark_balance > 0, allow. No tier gating.
  Future<void> _checkFeatureGatingThenLoad() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) {
      _loadOtherUserProfile();
      return;
    }

    try {
      final data = await SupabaseService.instance.client
          .from('users')
          .select('spark_balance')
          .eq('id', uid)
          .maybeSingle();

      if (data == null) {
        _loadOtherUserProfile();
        return;
      }

      final sparkBalance = (data['spark_balance'] as num?)?.toInt() ?? 0;
      debugPrint('SPARK GATE: uid=$uid, spark_balance=$sparkBalance');

      if (sparkBalance <= 0) {
        // Check if the OTHER user is the initiator and has sparks
        // (so the non-initiating user can still join)
        String? otherUserId = _matchedUserId;
        if ((otherUserId == null || otherUserId.isEmpty) &&
            _matchId != null &&
            _matchId!.isNotEmpty) {
          try {
            final match = await SupabaseService.instance.client
                .from('matches')
                .select('user_1_id, user_2_id')
                .eq('id', _matchId!)
                .maybeSingle();
            if (match != null) {
              otherUserId = match['user_1_id'] == uid
                  ? match['user_2_id'] as String?
                  : match['user_1_id'] as String?;
            }
          } catch (_) {}
        }

        // Check if there's an active session for this match (meaning other user already started)
        bool otherUserStarted = false;
        if (_matchId != null && _matchId!.isNotEmpty) {
          try {
            final tenMinutesAgo = DateTime.now()
                .subtract(const Duration(minutes: 10))
                .toIso8601String();
            final activeSession = await SupabaseService.instance.client
                .from('spark_sessions')
                .select('id, initiated_by')
                .eq('match_id', _matchId!)
                .not('status', 'eq', 'ended')
                .isFilter('ended_at', null)
                .gte('created_at', tenMinutesAgo)
                .limit(1)
                .maybeSingle();
            if (activeSession != null) {
              final initiatedBy = activeSession['initiated_by'] as String?;
              // If the other user initiated, this user can join without sparks
              otherUserStarted = initiatedBy != null && initiatedBy != uid;
              debugPrint(
                'SPARK GATE: active session found, initiated_by=$initiatedBy, otherUserStarted=$otherUserStarted',
              );
            }
          } catch (_) {}
        }

        if (!otherUserStarted) {
          debugPrint(
            'SPARK GATE: spark_balance=$sparkBalance and no active session — blocking',
          );
          if (mounted) {
            setState(() => _loadingProfile = false);
            _showLimitBottomSheet('free');
          }
          return;
        }
        debugPrint(
          'SPARK GATE: spark_balance=$sparkBalance but other user started session — allowing join',
        );
      }
    } catch (e) {
      debugPrint('SPARK GATE: Error checking feature gate: $e');
    }

    _loadOtherUserProfile();
  }

  void _showLimitBottomSheet(String tier) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isDismissible: false,
      builder: (ctx) => _SparkLimitBottomSheet(
        tier: tier,
        onBuyMoreSparks: () {
          Navigator.pop(ctx);
          Navigator.pushNamed(
            context,
            AppRoutes.pricingScreen,
            arguments: {'scrollToBundles': true},
          );
        },
        onUpgradeToSparkPlus: () {
          Navigator.pop(ctx);
          Navigator.pushNamed(context, AppRoutes.pricingScreen);
        },
        onUpgradeToGold: () {
          Navigator.pop(ctx);
          Navigator.pushNamed(context, AppRoutes.pricingScreen);
        },
        onBack: () {
          Navigator.pop(ctx);
          Navigator.pop(context);
        },
      ),
    );
  }

  Future<void> _loadOtherUserProfile() async {
    if (_matchedUserId == null || _matchedUserId!.isEmpty) {
      if (_matchId != null && _matchId!.isNotEmpty) {
        try {
          final match = await SupabaseService.instance.client
              .from('matches')
              .select('user_1_id, user_2_id')
              .eq('id', _matchId!)
              .maybeSingle();
          if (match != null) {
            final currentUid = SupabaseService.instance.currentUserId;
            _matchedUserId = match['user_1_id'] == currentUid
                ? match['user_2_id'] as String?
                : match['user_1_id'] as String?;
          }
        } catch (_) {}
      }
    }

    if (_matchedUserId != null && _matchedUserId!.isNotEmpty) {
      try {
        final profile = await SupabaseService.instance.getUserProfile(
          _matchedUserId!,
        );
        if (mounted) {
          setState(() {
            _otherUserProfile =
                SupabaseService.instance.isUserFacingProfileAvailable(profile)
                ? profile
                : null;
            _loadingProfile = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loadingProfile = false);
      }
    } else {
      if (mounted) setState(() => _loadingProfile = false);
    }

    if (mounted) {
      _requestPermissionsAndProceed();
    }
  }

  /// Request camera and microphone permissions before entering the waiting room.
  Future<void> _requestPermissionsAndProceed() async {
    if (kIsWeb) {
      debugPrint(
        'SPARK SESSION: web platform — skipping native permission request',
      );
      if (mounted) setState(() => _phase = SparkSessionPhase.waiting);
      return;
    }

    debugPrint('SPARK SESSION: requesting camera and microphone permissions');
    final cameraStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();

    debugPrint(
      'SPARK SESSION: camera=${cameraStatus.name}, microphone=${micStatus.name}',
    );

    if (!mounted) return;

    if (cameraStatus.isGranted && micStatus.isGranted) {
      debugPrint(
        'SPARK SESSION: camera and microphone permissions granted — entering waiting room',
      );
      setState(() {
        _permissionDenied = false;
        _phase = SparkSessionPhase.waiting;
      });
    } else {
      debugPrint(
        'SPARK SESSION: permission denied — camera=${cameraStatus.name}, mic=${micStatus.name}',
      );
      setState(() => _permissionDenied = true);

      // Show a dialog explaining why the permissions are needed
      if (mounted) {
        final isPermanent =
            cameraStatus.isPermanentlyDenied || micStatus.isPermanentlyDenied;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1F),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                const Icon(
                  Icons.videocam_rounded,
                  color: Color(0xFFFF4458),
                  size: 24,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Camera & Microphone Needed',
                    style: GoogleFonts.dmSans(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            content: Text(
              isPermanent
                  ? 'FaceMeet needs camera and microphone access to run a Spark Session. '
                        'You\'ve previously denied these permissions — please enable them in '
                        'Settings → FaceMeet → Privacy to continue.'
                  : 'FaceMeet needs access to your camera and microphone so you can see '
                        'and hear your match during a Spark Session. Without these permissions '
                        'the video call cannot start.',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: const Color(0xFF9E9EA8),
                height: 1.5,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(
                  'Not Now',
                  style: GoogleFonts.dmSans(
                    color: const Color(0xFF9E9EA8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  if (isPermanent) {
                    await openAppSettings();
                  } else {
                    await _requestPermissionsAndProceed();
                  }
                },
                child: Text(
                  isPermanent ? 'Open Settings' : 'Try Again',
                  style: GoogleFonts.dmSans(
                    color: const Color(0xFFFF4458),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }
  }

  void _onOtherUserJoined({
    String? roomUrl,
    String? sessionKey,
    String? sessionId,
    String? meetingToken,
  }) {
    setState(() {
      if (roomUrl != null) _dailyRoomUrl = roomUrl;
      if (sessionKey != null) _sessionKey = sessionKey;
      if (sessionId != null) _sparkSessionId = sessionId;
      if (meetingToken != null) _dailyMeetingToken = meetingToken;
      _remoteParticipantEverSeen = false;
      _phase = SparkSessionPhase.inCall;
    });
    // Keep screen awake for the duration of the video call
    if (!kIsWeb) {
      WakelockPlus.enable();
    }
  }

  void _onCallEnded() {
    // Release wakelock when call ends
    if (!kIsWeb) {
      WakelockPlus.disable();
    }
    _checkStatusAndProceed();
  }

  void _onRemoteParticipantEverSeen() {
    if (_remoteParticipantEverSeen) return;
    _remoteParticipantEverSeen = true;
    AndroidDiagnosticsService.instance.setValues({
      'spark_diag_remote_participant_ever_seen': 'yes',
      'spark_diag_feedback_allowed': 'yes',
    });
  }

  /// After a call ends, check if this match is already chat_unlocked.
  /// If so, skip the rating/decision screen and go directly to chat.
  /// Only show the decision screen for first-time sessions.
  Future<void> _checkStatusAndProceed() async {
    final matchId = _matchId;
    if (!_remoteParticipantEverSeen) {
      await AndroidDiagnosticsService.instance.setValues({
        'spark_diag_remote_participant_ever_seen': 'no',
        'spark_diag_feedback_allowed': 'no',
        'spark_diag_end_reason': 'ended before remote participant joined',
      });
      debugPrint(
        'SPARK SESSION: call ended before remote participant joined — skipping feedback',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'The other person did not join yet. You can try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: const Color(0xFF1A1A1F),
          ),
        );
        Navigator.pop(context);
      }
      return;
    }

    await AndroidDiagnosticsService.instance.setValues({
      'spark_diag_feedback_allowed': 'yes',
      'spark_diag_end_reason': 'remote participant joined',
    });

    if (matchId != null && matchId.isNotEmpty) {
      try {
        final match = await SupabaseService.instance.client
            .from('matches')
            .select('status')
            .eq('id', matchId)
            .maybeSingle();
        final status = match?['status'] as String? ?? '';
        if (status == 'chat_unlocked') {
          // Bug 5 fix: subsequent session — skip rating, go straight to chat
          debugPrint(
            'SPARK SESSION: match already chat_unlocked — skipping decision screen, going to chat',
          );
          _incrementSparksUsed();
          if (mounted) {
            Navigator.pushNamed(
              context,
              AppRoutes.chatScreen,
              arguments: {'matchId': matchId, 'otherUser': _otherUserProfile},
            );
          }
          return;
        }
      } catch (e) {
        debugPrint('SPARK SESSION: could not check match status — $e');
      }
    }
    // First-time session or status check failed — show decision/rating screen
    debugPrint('SPARK SESSION: first spark date ended — matchId=$matchId');
    debugPrint('SPARK SESSION: how-did-it-feel screen shown');
    _incrementSparksUsed();
    setState(() => _phase = SparkSessionPhase.decision);
  }

  /// Deduct 1 spark from spark_balance after a completed session.
  /// IMPORTANT: Only deducts from the session INITIATOR, not the joiner.
  /// All tiers use spark_balance as the single source of truth.
  Future<void> _incrementSparksUsed() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) {
      debugPrint('SPARK DEDUCT: uid is null — skipping deduction');
      return;
    }

    debugPrint(
      'SPARK DEDUCT: _incrementSparksUsed called — uid=$uid, matchId=$_matchId, sessionKey=$_sessionKey',
    );

    // Only deduct if both users actually joined
    if (_matchId != null && _matchId!.isNotEmpty) {
      try {
        // Use session_key for precise row lookup — prevents picking up wrong session
        List<dynamic> sessions;
        if (_sessionKey != null && _sessionKey!.isNotEmpty) {
          sessions = await SupabaseService.instance.client
              .from('spark_sessions')
              .select(
                'id, initiated_by, user_1_ready, user_2_ready, status, created_at',
              )
              .eq('match_id', _matchId!)
              .eq('session_key', _sessionKey!)
              .limit(1);
        } else {
          sessions = await SupabaseService.instance.client
              .from('spark_sessions')
              .select(
                'id, initiated_by, user_1_ready, user_2_ready, status, created_at',
              )
              .eq('match_id', _matchId!)
              .order('created_at', ascending: false)
              .limit(1);
        }

        debugPrint(
          'SPARK DEDUCT: session query returned ${sessions.length} row(s) for matchId=$_matchId, sessionKey=$_sessionKey',
        );

        final sessionRow = sessions.isNotEmpty ? sessions.first : null;

        if (sessionRow == null) {
          debugPrint(
            'SPARK DEDUCT: no session row found for matchId=$_matchId — skipping deduction',
          );
          return;
        }

        debugPrint(
          'SPARK DEDUCT: session row — id=${sessionRow['id']}, status=${sessionRow['status']}, '
          'initiated_by=${sessionRow['initiated_by']}, '
          'user_1_ready=${sessionRow['user_1_ready']}, user_2_ready=${sessionRow['user_2_ready']}',
        );

        // Check if both users were ready (both joined)
        final u1Ready = sessionRow['user_1_ready'] == true;
        final u2Ready = sessionRow['user_2_ready'] == true;
        if (!u1Ready || !u2Ready) {
          debugPrint(
            'SPARK DEDUCT: session did not have both users joined (u1=$u1Ready, u2=$u2Ready) — skipping deduction',
          );
          return;
        }

        // Determine initiator: prefer initiated_by from session row,
        // fall back to user_1_id from the matches table (NOT spark_sessions — that column doesn't exist there)
        String? initiatedBy = sessionRow['initiated_by'] as String?;
        if (initiatedBy == null || initiatedBy.isEmpty) {
          debugPrint(
            'SPARK DEDUCT: initiated_by not set in session row — falling back to matches.user_1_id',
          );
          try {
            final matchRow = await SupabaseService.instance.client
                .from('matches')
                .select('user_1_id')
                .eq('id', _matchId!)
                .maybeSingle();
            initiatedBy = matchRow?['user_1_id'] as String?;
            debugPrint(
              'SPARK DEDUCT: fallback initiatedBy from matches.user_1_id=$initiatedBy',
            );
          } catch (e) {
            debugPrint(
              'SPARK DEDUCT: could not read matches.user_1_id for fallback — $e',
            );
          }
        }

        if (initiatedBy != null &&
            initiatedBy.isNotEmpty &&
            initiatedBy != uid) {
          debugPrint(
            'SPARK DEDUCT: current user ($uid) is NOT the initiator ($initiatedBy) — skipping deduction',
          );
          return;
        }

        if (initiatedBy == null || initiatedBy.isEmpty) {
          debugPrint(
            'SPARK DEDUCT: could not determine initiator — skipping deduction to avoid double-charge',
          );
          return;
        }

        debugPrint(
          'SPARK DEDUCT: ✅ current user ($uid) IS the initiator — proceeding with deduction',
        );
      } catch (e) {
        debugPrint(
          'SPARK DEDUCT: could not check session state — $e — skipping deduction to avoid double-charge',
        );
        return;
      }
    }

    try {
      final data = await SupabaseService.instance.client
          .from('users')
          .select('subscription_tier, spark_balance')
          .eq('id', uid)
          .maybeSingle();

      if (data == null) {
        debugPrint('SPARK DEDUCT: user data is null for uid=$uid — skipping');
        return;
      }

      final tier = data['subscription_tier'] as String? ?? 'free';
      final currentBalance = (data['spark_balance'] as num?)?.toInt() ?? 0;

      debugPrint(
        'SPARK DEDUCT: uid=$uid, tier=$tier, spark_balance=$currentBalance',
      );

      if (currentBalance <= 0) {
        debugPrint(
          'SPARK DEDUCT: spark_balance is already 0 for uid=$uid — nothing to deduct',
        );
        return;
      }

      // Always deduct 1 from spark_balance regardless of tier
      final newBalance = currentBalance - 1;
      await SupabaseService.instance.client
          .from('users')
          .update({'spark_balance': newBalance})
          .eq('id', uid);

      debugPrint(
        'SPARK DEDUCT: ✅ decremented spark_balance from $currentBalance to $newBalance for uid=$uid (tier=$tier)',
      );

      // CRITICAL FIX: Clear current_session_key after successful session completion
      // so the next session starts completely fresh with no stale key.
      if (_matchId != null && _matchId!.isNotEmpty) {
        try {
          await SupabaseService.instance.client
              .from('matches')
              .update({'current_session_key': null})
              .eq('id', _matchId!);
          debugPrint(
            'SPARK DEDUCT: cleared current_session_key for matchId=$_matchId',
          );
        } catch (e) {
          debugPrint('SPARK DEDUCT: could not clear session key — $e');
        }
      }
    } catch (e) {
      debugPrint('SPARK DEDUCT: Error decrementing spark_balance: $e');
    }
  }

  /// Refund a spark to the initiator — called when Daily.co error occurs.
  /// Only refunds if the current user is the initiator and a deduction was made.
  Future<void> _refundSparkIfInitiator() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    if (_matchId == null || _matchId!.isEmpty) return;

    try {
      final sessionRow = await SupabaseService.instance.client
          .from('spark_sessions')
          .select(
            'initiated_by, user_1_id, user_2_id, user_1_ready, user_2_ready',
          )
          .eq('match_id', _matchId!)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      // Only refund if both users had joined (meaning a deduction occurred)
      final u1Ready = sessionRow?['user_1_ready'] == true;
      final u2Ready = sessionRow?['user_2_ready'] == true;
      if (!u1Ready || !u2Ready) {
        debugPrint(
          'SPARK REFUND: both users did not join — no deduction to refund',
        );
        return;
      }

      String? initiatedBy = sessionRow?['initiated_by'] as String?;
      if (initiatedBy == null || initiatedBy.isEmpty) {
        initiatedBy = sessionRow?['user_1_id'] as String?;
      }

      if (initiatedBy != uid) {
        debugPrint(
          'SPARK REFUND: current user is not initiator — no refund needed',
        );
        return;
      }

      final userData = await SupabaseService.instance.client
          .from('users')
          .select('spark_balance')
          .eq('id', uid)
          .maybeSingle();

      if (userData == null) return;

      final balance = (userData['spark_balance'] as num?)?.toInt() ?? 0;
      // Refund 1 spark to balance
      await SupabaseService.instance.client
          .from('users')
          .update({'spark_balance': balance + 1})
          .eq('id', uid);
      debugPrint(
        'SPARK REFUND: ✅ refunded 1 spark to uid=$uid (balance: $balance → ${balance + 1})',
      );
    } catch (e) {
      debugPrint('SPARK REFUND: error during refund — $e');
    }
  }

  Future<void> _onDecisionMade(bool didSpark) async {
    debugPrint(
      'SPARK SESSION: post-session decision submitted — spark=$didSpark',
    );
    final matchId = _matchId;
    final currentUserId = SupabaseService.instance.currentUserId;

    if (matchId != null && currentUserId != null) {
      try {
        // Determine which user slot we are (user_1 or user_2)
        final match = await SupabaseService.instance.client
            .from('matches')
            .select('user_1_id, user_2_id, status')
            .eq('id', matchId)
            .maybeSingle();

        if (match != null) {
          final isUser1 = match['user_1_id'] == currentUserId;
          final wasChatUnlocked = match['status'] == 'chat_unlocked';
          final decisionField = isUser1 ? 'decision_user_1' : 'decision_user_2';
          final decision = didSpark ? 'spark' : 'skip';

          Map<String, dynamic>? session;
          if (_sessionKey != null && _sessionKey!.isNotEmpty) {
            session = await SupabaseService.instance.client
                .from('spark_sessions')
                .select('id, decision_user_1, decision_user_2')
                .eq('match_id', matchId)
                .eq('session_key', _sessionKey!)
                .limit(1)
                .maybeSingle();
          } else {
            final sessions = await SupabaseService.instance.client
                .from('spark_sessions')
                .select('id, decision_user_1, decision_user_2')
                .eq('match_id', matchId)
                .order('created_at', ascending: false)
                .limit(1);
            session = (sessions as List).isNotEmpty
                ? Map<String, dynamic>.from(sessions.first)
                : null;
          }

          if (session != null) {
            final sessionId = session['id'] as String?;
            if (sessionId == null || sessionId.isEmpty) return;

            await SupabaseService.instance.client
                .from('spark_sessions')
                .update({decisionField: decision})
                .eq('id', sessionId);
            debugPrint(
              'SPARK SESSION: decision saved — sessionId=$sessionId field=$decisionField decision=$decision',
            );

            final updatedSession = await SupabaseService.instance.client
                .from('spark_sessions')
                .select('decision_user_1, decision_user_2')
                .eq('id', sessionId)
                .single();

            final d1 = updatedSession['decision_user_1'];
            final d2 = updatedSession['decision_user_2'];
            if (d1 != null && d2 != null) {
              final mutual = d1 == 'spark' && d2 == 'spark';
              final outcome = mutual ? 'mutual_spark' : 'no_spark';
              final matchStatus = mutual ? 'chat_unlocked' : 'session_ended';

              // Update spark_session outcome
              await SupabaseService.instance.client
                  .from('spark_sessions')
                  .update({
                    'outcome': outcome,
                    'status': 'ended',
                    'ended_at': DateTime.now().toIso8601String(),
                  })
                  .eq('id', sessionId);

              // Update match status
              await SupabaseService.instance.client
                  .from('matches')
                  .update({'status': matchStatus, 'current_session_key': null})
                  .eq('id', matchId);

              await SupabaseService.instance
                  .completeSparkSessionScheduleForMatch(matchId);

              // If mutual spark, navigate directly to chat thread
              if (mutual && mounted) {
                debugPrint(
                  'SPARK SESSION: mutual Spark confirmed — sessionId=$sessionId matchId=$matchId',
                );
                if (!wasChatUnlocked) {
                  await _sendChatUnlockedPush(matchId, match);
                }
                _navigateToChatAfterUnlock(matchId);
                return;
              }
            } else if (didSpark) {
              debugPrint(
                'SPARK SESSION: waiting for other decision — sessionId=$sessionId matchId=$matchId',
              );
            }
          }
        }
      } catch (_) {}
    }

    setState(() {
      _mutualSpark = didSpark;
      _waitingForOtherDecision = didSpark;
      _phase = SparkSessionPhase.outcome;
    });
    if (didSpark) {
      _startDecisionStatusWatcher();
    }
    // Ensure wakelock is released after decision
    if (!kIsWeb) {
      WakelockPlus.disable();
    }
  }

  void _startDecisionStatusWatcher() {
    final matchId = _matchId;
    if (matchId == null || matchId.isEmpty || _decisionStatusTimer != null) {
      return;
    }
    debugPrint('SPARK SESSION: watching match status after decision');
    _decisionStatusTimer = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      try {
        final match = await SupabaseService.instance.client
            .from('matches')
            .select('status')
            .eq('id', matchId)
            .maybeSingle();
        final status = match?['status'] as String? ?? '';
        if (status == 'chat_unlocked') {
          timer.cancel();
          _decisionStatusTimer = null;
          _navigateToChatAfterUnlock(matchId);
        } else if (status == 'session_ended') {
          timer.cancel();
          _decisionStatusTimer = null;
        }
      } catch (e) {
        debugPrint('SPARK SESSION: decision status watch error — $e');
      }
    });
  }

  void _navigateToChatAfterUnlock(String matchId) {
    if (_chatNavigationStarted || !mounted) return;
    _chatNavigationStarted = true;
    _decisionStatusTimer?.cancel();
    _decisionStatusTimer = null;
    debugPrint('SPARK SESSION: chat unlocked — matchId=$matchId');
    debugPrint(
      'SPARK SESSION: mutual Spark — navigating directly to chat thread for matchId=$matchId',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Chat unlocked. Say hello!',
          style: GoogleFonts.dmSans(color: Colors.white),
        ),
        backgroundColor: AppTheme.sparkGreen,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.chatScreen,
      (route) => false,
      arguments: {'matchId': matchId, 'otherUser': _otherUserProfile},
    );
  }

  Future<void> _sendChatUnlockedPush(
    String matchId,
    Map<String, dynamic> match,
  ) async {
    try {
      final userAId = match['user_1_id'] as String?;
      final userBId = match['user_2_id'] as String?;
      debugPrint('CHAT UNLOCK PUSH: chat unlocked');
      debugPrint(
        'CHAT UNLOCK PUSH: user A present yes/no=${userAId?.isNotEmpty == true}',
      );
      debugPrint(
        'CHAT UNLOCK PUSH: user B present yes/no=${userBId?.isNotEmpty == true}',
      );

      final userAName = await _firstNameForUser(userAId);
      final userBName = await _firstNameForUser(userBId);
      debugPrint(
        'CHAT UNLOCK PUSH: user A display name present yes/no=${userAName != null}',
      );
      debugPrint(
        'CHAT UNLOCK PUSH: user B display name present yes/no=${userBName != null}',
      );

      if (userAId != null && userAId.isNotEmpty) {
        final sentToA = await WebPushNotificationService.instance
            .sendWebPushNotification(
              userId: userAId,
              type: 'chat_unlocked',
              title: 'Chat unlocked 💬',
              body: _chatUnlockedBody(userBName),
              data: {'match_id': matchId, 'type': 'chat_unlocked'},
            );
        debugPrint('CHAT UNLOCK PUSH: send to user A success/failure=$sentToA');
      }

      if (userBId != null && userBId.isNotEmpty) {
        final sentToB = await WebPushNotificationService.instance
            .sendWebPushNotification(
              userId: userBId,
              type: 'chat_unlocked',
              title: 'Chat unlocked 💬',
              body: _chatUnlockedBody(userAName),
              data: {'match_id': matchId, 'type': 'chat_unlocked'},
            );
        debugPrint('CHAT UNLOCK PUSH: send to user B success/failure=$sentToB');
      }
    } catch (e) {
      debugPrint('CHAT UNLOCK PUSH: success/failure=false — $e');
    }
  }

  Future<String?> _firstNameForUser(String? userId) async {
    if (userId == null || userId.isEmpty) return null;
    try {
      final profile = await SupabaseService.instance.getUserProfile(userId);
      final firstName = profile?['first_name']?.toString().trim();
      if (firstName == null || firstName.isEmpty) return null;
      return firstName;
    } catch (e) {
      debugPrint('CHAT UNLOCK PUSH: display name lookup failed — $e');
      return null;
    }
  }

  String _chatUnlockedBody(String? otherName) {
    if (otherName == null || otherName.isEmpty) {
      return 'You both felt the spark. Say hello.';
    }
    return 'You both felt the spark. Say hello to $otherName.';
  }

  Map<String, dynamic> get _safeOtherUser {
    final p = _otherUserProfile;
    if (p == null) {
      return {
        'id': _matchedUserId,
        'name': 'Your Match',
        'age': 0,
        'city': '',
        'imageUrl': null,
        'thumbnailUrl': null,
        'semanticLabel': 'Profile photo',
      };
    }
    return {
      'id': _matchedUserId ?? p['id'],
      'name': p['first_name'] ?? 'Your Match',
      'age': p['age'] ?? 0,
      'city': p['city'] ?? '',
      'imageUrl':
          p['thumbnail_url'] ??
          p['profile_image_url'] ??
          p['avatar_url'] ??
          p['profile_photo_url'] ??
          p['profile_video_thumbnail_url'] ??
          p['profile_video_url'],
      'thumbnailUrl': p['thumbnail_url'],
      'semanticLabel': 'Profile photo of ${p['first_name'] ?? 'your match'}',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: _loadingProfile
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF4458)),
            )
          : _buildPhaseContent(),
    );
  }

  Widget _buildPhaseContent() {
    switch (_phase) {
      case SparkSessionPhase.permissionCheck:
        return _permissionDenied
            ? _buildPermissionDeniedScreen()
            : const Center(
                child: CircularProgressIndicator(color: Color(0xFFFF4458)),
              );
      case SparkSessionPhase.waiting:
        return SparkWaitingRoomWidget(
          otherUser: _safeOtherUser,
          matchId: _matchId,
          onOtherUserJoined:
              ({
                String? roomUrl,
                String? sessionKey,
                String? sessionId,
                String? meetingToken,
              }) => _onOtherUserJoined(
                roomUrl: roomUrl,
                sessionKey: sessionKey,
                sessionId: sessionId,
                meetingToken: meetingToken,
              ),
        );
      case SparkSessionPhase.inCall:
        return SparkVideoCallWidget(
          roomUrl: _dailyRoomUrl ?? '',
          meetingToken: _dailyMeetingToken ?? '',
          otherUser: _safeOtherUser,
          matchId: _matchId,
          sessionId: _sparkSessionId,
          sessionKey: _sessionKey,
          onCallEnded: _onCallEnded,
          onRemoteParticipantEverSeen: _onRemoteParticipantEverSeen,
          // Bug 5: refund spark if Daily.co error occurs after sparks were deducted
          onCallErrorRefund: _refundSparkIfInitiator,
        );
      case SparkSessionPhase.decision:
        return SparkDecisionWidget(
          otherUser: _safeOtherUser,
          onDecision: _onDecisionMade,
        );
      case SparkSessionPhase.outcome:
        return _SparkOutcomeWidget(
          mutualSpark: _mutualSpark,
          waitingForOtherDecision: _waitingForOtherDecision,
          otherUser: _safeOtherUser,
          matchId: _matchId,
          sessionKey: _sessionKey,
          onGoToChat: () => Navigator.pushNamed(
            context,
            AppRoutes.chatScreen,
            arguments: {'matchId': _matchId, 'otherUser': _otherUserProfile},
          ),
          onDiscover: () => Navigator.pushNamedAndRemoveUntil(
            context,
            AppRoutes.discoveryFeedScreen,
            (r) => false,
          ),
        );
    }
  }

  Widget _buildPermissionDeniedScreen() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x22FF4458), Color(0xFF0D0D0F)],
          stops: [0.0, 0.5],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withAlpha(30),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.videocam_off_rounded,
                  color: AppTheme.primary,
                  size: 40,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Camera & Microphone Required',
                style: GoogleFonts.dmSans(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'FaceMeet needs access to your camera and microphone to start a Spark Session.',
                style: GoogleFonts.dmSans(
                  fontSize: 15,
                  color: AppTheme.textSecondary,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              GestureDetector(
                onTap: _requestPermissionsAndProceed,
                child: Container(
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF4458), Color(0xFFE8503A)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Text(
                      'Grant Access',
                      style: GoogleFonts.dmSans(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Go back',
                  style: GoogleFonts.dmSans(
                    fontSize: 14,
                    color: AppTheme.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    // Always release wakelock when screen is disposed
    if (!kIsWeb) {
      WakelockPlus.disable();
    }
    _decisionStatusTimer?.cancel();
    super.dispose();
  }
}

// ── Spark Limit Bottom Sheet ──────────────────────────────────────────────────

class _SparkLimitBottomSheet extends StatelessWidget {
  final String tier;
  final VoidCallback onBuyMoreSparks;
  final VoidCallback onUpgradeToSparkPlus;
  final VoidCallback onUpgradeToGold;
  final VoidCallback onBack;

  const _SparkLimitBottomSheet({
    required this.tier,
    required this.onBuyMoreSparks,
    required this.onUpgradeToSparkPlus,
    required this.onUpgradeToGold,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final isFree = tier == 'free';
    final isSparkPlus = tier == 'spark_plus';

    final String subtitle;
    if (isFree) {
      subtitle =
          'You\'ve used all 3 free Sparks for this week. Buy a bundle or go monthly to keep sparking!';
    } else if (isSparkPlus) {
      subtitle =
          'You\'ve used all 3 Sparks for today. Your daily allowance resets at midnight, or buy more now!';
    } else {
      // Gold
      subtitle =
          'You\'ve used all 10 Sparks for today. Your daily allowance resets at midnight, or buy more now!';
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFF3A3A3E),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          // Icon
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
          // Title — always the friendly message
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
            subtitle,
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),

          // ── PRIMARY: Buy more Sparks (coral, full width) ──
          GestureDetector(
            onTap: onBuyMoreSparks,
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

          // ── SECONDARY: Upgrade button (outlined, smaller) ──
          if (isSparkPlus) ...[
            // Spark+ user → Upgrade to Gold
            GestureDetector(
              onTap: onUpgradeToGold,
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFF6B6B6B),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Upgrade to Gold',
                        style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFAAAAAA),
                        ),
                      ),
                      Text(
                        'Unlock 10 Sparks per day with Gold at \$29.99/mo',
                        style: GoogleFonts.dmSans(
                          fontSize: 11,
                          color: const Color(0xFF777777),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ] else if (isFree) ...[
            // Free user → Upgrade to Spark+
            GestureDetector(
              onTap: onUpgradeToSparkPlus,
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Upgrade to Spark+',
                        style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFFF4458).withAlpha(200),
                        ),
                      ),
                      Text(
                        'Get 3 Sparks every day with Spark+ at \$14.99/mo',
                        style: GoogleFonts.dmSans(
                          fontSize: 11,
                          color: const Color(0xFFFF4458).withAlpha(140),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),

          // ── TERTIARY: Wait until tomorrow/Monday (plain text link) ──
          GestureDetector(
            onTap: onBack,
            child: Text(
              isSparkPlus || (!isFree)
                  ? 'Your limit resets at midnight'
                  : 'Your limit resets on Monday',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: const Color(0xFF666666),
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Spark Outcome Widget ──────────────────────────────────────────────────────

class _SparkOutcomeWidget extends StatelessWidget {
  final bool mutualSpark;
  final bool waitingForOtherDecision;
  final Map<String, dynamic> otherUser;
  final String? matchId;
  final String? sessionKey;
  final VoidCallback onGoToChat;
  final VoidCallback onDiscover;

  const _SparkOutcomeWidget({
    required this.mutualSpark,
    required this.waitingForOtherDecision,
    required this.otherUser,
    this.matchId,
    this.sessionKey,
    required this.onGoToChat,
    required this.onDiscover,
  });

  @override
  Widget build(BuildContext context) {
    final name = otherUser['name'] as String? ?? 'Your Match';
    final otherUserId = otherUser['id']?.toString().trim();
    final safetyContext = _sparkSessionReportContext;
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.2,
          colors: mutualSpark
              ? [const Color(0x2200C853), const Color(0xFF0D0D0F)]
              : [const Color(0x22FF4458), const Color(0xFF0D0D0F)],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                waitingForOtherDecision
                    ? Icons.hourglass_top_rounded
                    : mutualSpark
                    ? Icons.favorite_rounded
                    : Icons.sentiment_neutral_rounded,
                color: waitingForOtherDecision
                    ? AppTheme.primary
                    : mutualSpark
                    ? AppTheme.sparkGreen
                    : AppTheme.textMuted,
                size: 72,
              ),
              const SizedBox(height: 24),
              Text(
                waitingForOtherDecision
                    ? 'Waiting for their response...'
                    : mutualSpark
                    ? 'It\'s a Spark! ⚡'
                    : 'No Spark This Time',
                style: GoogleFonts.dmSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                waitingForOtherDecision
                    ? 'You chose Spark. We’ll open chat as soon as they choose Spark too.'
                    : mutualSpark
                    ? 'You and $name both sparked each other! Chat is now unlocked.'
                    : 'Better luck next time. Keep discovering!',
                style: GoogleFonts.dmSans(
                  fontSize: 16,
                  color: AppTheme.textSecondary,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              if (mutualSpark && !waitingForOtherDecision)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: () {
                      debugPrint('SPARK SESSION: Go to Chat tapped');
                      onGoToChat();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.sparkGreen,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      'Go to Chat',
                      style: GoogleFonts.dmSans(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              if (!waitingForOtherDecision)
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    onPressed: () {
                      debugPrint('SPARK SESSION: Keep Discovering tapped');
                      onDiscover();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0x33FFFFFF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: Text(
                      'Keep Discovering',
                      style: GoogleFonts.dmSans(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              if (!waitingForOtherDecision &&
                  otherUserId != null &&
                  otherUserId.isNotEmpty) ...[
                const SizedBox(height: 18),
                UserSafetyActionButtons(
                  reportedUserId: otherUserId,
                  reportedUserName: name,
                  source: 'spark_session',
                  matchId: matchId,
                  contextNote: safetyContext,
                  direction: Axis.horizontal,
                  onBlocked: onDiscover,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String? get _sparkSessionReportContext {
    final parts = <String>[];
    final cleanMatchId = matchId?.trim();
    final cleanSessionKey = sessionKey?.trim();
    if (cleanMatchId != null && cleanMatchId.isNotEmpty) {
      parts.add('match_id: $cleanMatchId');
    }
    if (cleanSessionKey != null && cleanSessionKey.isNotEmpty) {
      parts.add('session_key: $cleanSessionKey');
    }
    if (parts.isEmpty) return null;
    return 'Spark Session context\n${parts.join('\n')}';
  }
}
