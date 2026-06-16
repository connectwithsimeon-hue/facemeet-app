import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../providers/subscription_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/android_diagnostics_service.dart';
import '../../services/supabase_service.dart';
import '../../services/web_push_notification_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_navigation.dart';
import '../../widgets/loading_skeleton_widget.dart';
import './widgets/discovery_card_widget.dart';
import './widgets/match_celebration_widget.dart';
import '../main_shell_screen/main_shell_screen.dart';

class DiscoveryFeedScreen extends StatefulWidget {
  const DiscoveryFeedScreen({super.key});

  @override
  State<DiscoveryFeedScreen> createState() => _DiscoveryFeedScreenState();
}

class _DiscoveryFeedScreenState extends State<DiscoveryFeedScreen>
    with TickerProviderStateMixin {
  int _currentCardIndex = 0;

  bool _isLoading = true;
  List<Map<String, dynamic>> _profiles = [];

  late AnimationController _cardController;
  late Animation<Offset> _cardSlide;
  late Animation<double> _cardFade;

  @override
  void initState() {
    super.initState();
    _cardController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _cardSlide = Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _cardController, curve: Curves.easeOutCubic),
        );
    _cardFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _cardController,
        curve: const Interval(0, 0.5, curve: Curves.easeOut),
      ),
    );
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    setState(() => _isLoading = true);
    try {
      final profiles = await SupabaseService.instance.getDiscoveryFeed();
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _currentCardIndex = 0;
          _isLoading = false;
        });
        if (_profiles.isNotEmpty) {
          _cardController.forward();
        }
      }
    } catch (e) {
      debugPrint('DISCOVERY FEED LOAD ERROR: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _cardController.dispose();
    super.dispose();
  }

  /// Send a push notification via the Supabase Edge Function.
  /// Wrapped in try/catch so a failure never crashes the app.
  Future<bool> _sendPushNotification({
    required String userId,
    required String type,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    var nativePushSent = false;
    try {
      final response = await SupabaseService.instance.client.functions.invoke(
        'send_push_notification',
        body: {
          'user_id': userId,
          'type': type,
          'title': title,
          'body': body,
          'data': {...data, 'type': type},
        },
      );
      final responseData = response.data;
      nativePushSent = responseData is Map
          ? ((responseData['sent'] as num?)?.toInt() ?? 0) > 0
          : false;
      final nativeTokenRows = responseData is Map
          ? ((responseData['native_tokens_found'] as num?)?.toInt() ?? 0)
          : 0;
      final androidTokenRows = responseData is Map
          ? ((responseData['android_tokens_found'] as num?)?.toInt() ?? 0)
          : 0;
      final nativeSent = responseData is Map
          ? ((responseData['native_sent'] as num?)?.toInt() ?? 0)
          : 0;
      final webSent = responseData is Map
          ? ((responseData['web_sent'] as num?)?.toInt() ?? 0)
          : 0;
      final edgeReason = responseData is Map
          ? (responseData['reason']?.toString() ?? 'unknown')
          : 'unknown';
      final androidTargetTokenCount = responseData is Map
          ? ((responseData['android_push_target_token_count'] as num?)
                    ?.toInt() ??
                androidTokenRows)
          : 0;
      final fcmAttempted = responseData is Map
          ? responseData['fcm_send_attempted'] == true
          : false;
      final fcmSuccessCount = responseData is Map
          ? ((responseData['fcm_success_count'] as num?)?.toInt() ?? nativeSent)
          : 0;
      final fcmFailureReason = responseData is Map
          ? (responseData['fcm_failure_reason_safe']?.toString() ?? 'unknown')
          : 'unknown';
      debugPrint(
        'PUSH NOTIFICATION: sent type=$type to userId=$userId, nativeSent=$nativePushSent',
      );
      await AndroidDiagnosticsService.instance.setValues({
        'last_push_invoke_result':
            'type=$type, sent=${nativePushSent ? 'yes' : 'no'}',
        'last_push_recipient_id': AndroidDiagnosticsService.shortId(userId),
        'last_push_token_rows_found': nativeTokenRows,
        'last_push_android_token_rows_found': androidTokenRows,
        'last_push_native_sent': nativeSent,
        'last_push_web_sent': webSent,
        'last_push_edge_reason': edgeReason,
        'android_push_target_token_count': androidTargetTokenCount,
        'fcm_send_attempted': fcmAttempted ? 'yes' : 'no',
        'fcm_success_count': fcmSuccessCount,
        'fcm_failure_reason_safe': fcmFailureReason,
      });
    } catch (e) {
      await AndroidDiagnosticsService.instance.setValue(
        'last_push_invoke_result',
        'type=$type, error',
      );
      debugPrint('PUSH NOTIFICATION: failed to send type=$type — $e');
    }
    if (!kIsWeb) return nativePushSent;
    return await WebPushNotificationService.instance.sendWebPushNotification(
      userId: userId,
      type: type,
      title: title,
      body: body,
      data: data,
    );
  }

  /// Spark action: insert interaction, verify, check reciprocal, then advance.
  Future<void> _handleSpark() async {
    debugPrint('DISCOVERY_SPARK: tapped on card index $_currentCardIndex');
    final profile = _profiles[_currentCardIndex];
    final uid = profile['id'] as String?;
    if (uid == null) {
      debugPrint('DISCOVERY_SPARK: profile id is null — skipping');
      _advanceCard();
      return;
    }

    final currentUid = SupabaseService.instance.currentUserId;
    debugPrint(
      'DISCOVERY_SPARK: from_user_id=$currentUid, to_user_id=$uid, action_type=spark',
    );
    debugPrint('SPARK SESSION: user sparked — toUserId=$uid');

    // Step 1 — Insert interaction row and verify success
    Map<String, dynamic>? insertedRow;
    try {
      insertedRow = await SupabaseService.instance.saveInteraction(
        toUserId: uid,
        actionType: 'spark',
      );
      if (insertedRow == null) {
        debugPrint(
          'DISCOVERY_SPARK: target user missing or stale — skipping card',
        );
        _advanceCard();
        return;
      }
      debugPrint('DISCOVERY_SPARK: insert succeeded — row: $insertedRow');
    } catch (e) {
      debugPrint('DISCOVERY_SPARK: insert FAILED — error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Spark failed: $e',
              style: GoogleFonts.dmSans(fontSize: 13),
            ),
            backgroundColor: const Color(0xFFE8503A),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      // Do NOT advance — let user retry
      return;
    }

    // Step 1b — Send mystery spark notification to the sparked user
    debugPrint('SPARK PUSH: spark created');
    debugPrint(
      'SPARK PUSH: recipient user id present yes/no=${uid.isNotEmpty}',
    );
    unawaited(
      _sendPushNotification(
        userId: uid,
        type: 'new_spark',
        title: 'Someone Sparked you ⚡',
        body: 'Open FaceMeet to see who felt a spark.',
        data: {'type': 'new_spark', 'url': '/'},
      ),
    );

    // Log current interaction count for this user
    try {
      final count = await SupabaseService.instance.getInteractionCount();
      debugPrint(
        'DISCOVERY_SPARK: current interaction count for $currentUid = $count',
      );
    } catch (e) {
      debugPrint('DISCOVERY_SPARK: could not fetch interaction count — $e');
    }

    // Step 2 — Check for reciprocal spark
    debugPrint(
      'DISCOVERY_SPARK: checking reciprocal spark — from_user_id=$uid, to_user_id=$currentUid',
    );
    try {
      final isMutual = await SupabaseService.instance.checkMutualSpark(uid);
      debugPrint('DISCOVERY_SPARK: reciprocal check result = $isMutual');
      if (isMutual && currentUid != null) {
        Map<String, dynamic>? matchRow;
        final existing = await SupabaseService.instance.getExistingMatch(
          user1Id: currentUid,
          user2Id: uid,
        );
        if (existing == null) {
          matchRow = await SupabaseService.instance.createMatch(
            user1Id: currentUid,
            user2Id: uid,
          );
          debugPrint(
            'DISCOVERY_SPARK: mutual spark — match created between $currentUid and $uid',
          );
          debugPrint(
            'SPARK SESSION: mutual spark created — matchId=${matchRow?['id']}',
          );

          // Phase 2B — notify both users about the mutual match.
          try {
            final matchId = matchRow?['id'] as String?;
            if (matchId != null) {
              debugPrint('MUTUAL SPARK PUSH: mutual spark created');
              debugPrint(
                'MUTUAL SPARK PUSH: user A present yes/no=${currentUid.isNotEmpty}',
              );
              debugPrint(
                'MUTUAL SPARK PUSH: user B present yes/no=${uid.isNotEmpty}',
              );
              final sentToMatched = await _sendPushNotification(
                userId: uid,
                type: 'new_match',
                title: "It's a Mutual Spark ⚡",
                body:
                    'You both Sparked. Open FaceMeet to start your 3-minute Spark Session.',
                data: {'match_id': matchId, 'type': 'new_match'},
              );
              debugPrint(
                'MUTUAL SPARK PUSH: send to user B success/failure=$sentToMatched',
              );

              final sentToCurrent = await WebPushNotificationService.instance
                  .sendWebPushNotification(
                    userId: currentUid,
                    type: 'new_match',
                    title: "It's a Mutual Spark ⚡",
                    body:
                        'You both Sparked. Open FaceMeet to start your 3-minute Spark Session.',
                    data: {'match_id': matchId, 'type': 'new_match'},
                  );
              debugPrint(
                'MUTUAL SPARK PUSH: send to user A success/failure=$sentToCurrent',
              );
            }
          } catch (e) {
            debugPrint('MUTUAL SPARK PUSH: success/failure=false — $e');
          }

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  "It's a mutual Spark! 🔥",
                  style: GoogleFonts.dmSans(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                backgroundColor: const Color(0xFFE8503A),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        } else {
          matchRow = existing;
          debugPrint(
            'DISCOVERY_SPARK: mutual spark detected but match already exists — skipping duplicate',
          );
        }
        final matchId = matchRow?['id'] as String?;
        final status = matchRow?['status'] as String? ?? '';
        if (matchId != null &&
            matchId.isNotEmpty &&
            status != 'chat_unlocked' &&
            mounted) {
          _showMutualSparkPrompt(
            matchId: matchId,
            matchedUserId: uid,
            matchedName: profile['first_name'] as String? ?? 'Your Match',
          );
          return;
        }
      }
    } catch (e) {
      debugPrint('DISCOVERY_SPARK: reciprocal check error — $e');
    }

    // Step 3 — Advance only after insert + reciprocal check completed
    _advanceCard();
  }

  void _showMutualSparkPrompt({
    required String matchId,
    required String matchedUserId,
    required String matchedName,
  }) {
    debugPrint(
      'SPARK SESSION: join prompt shown on initiator — matchId=$matchId',
    );
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black87,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (dialogContext, _, __) {
        return MatchCelebrationWidget(
          matchedName: matchedName,
          matchedUserId: matchedUserId,
          onDismiss: () {
            Navigator.of(dialogContext).pop();
            _advanceCard();
          },
          onStartSession: () {
            debugPrint(
              'SPARK SESSION: join tapped from discovery mutual prompt — matchId=$matchId',
            );
            Navigator.of(dialogContext).pop();
            Navigator.pushNamed(
              context,
              AppRoutes.sparkSessionScreen,
              arguments: {'matchId': matchId, 'matchedUserId': matchedUserId},
            );
          },
        );
      },
    );
  }

  void _handleSkip() {
    debugPrint('DISCOVERY_SWIPE: skip on card index $_currentCardIndex');
    final profile = _profiles[_currentCardIndex];
    final uid = profile['id'] as String?;
    if (uid != null) {
      SupabaseService.instance
          .saveInteraction(toUserId: uid, actionType: 'skip')
          .catchError((_) => null);
    }
    _advanceCard();
  }

  void _advanceCard() {
    if (_currentCardIndex < _profiles.length - 1) {
      _cardController.reset();
      setState(() => _currentCardIndex++);
      _cardController.forward();
    } else {
      setState(() => _currentCardIndex = _profiles.length);
    }
  }

  void _removeBlockedProfile(String userId) {
    final index = _profiles.indexWhere((profile) => profile['id'] == userId);
    if (index == -1) return;

    setState(() {
      _profiles.removeAt(index);
      if (_currentCardIndex >= _profiles.length) {
        _currentCardIndex = _profiles.length;
      }
    });

    if (_currentCardIndex < _profiles.length) {
      _cardController.reset();
      _cardController.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width >= 600;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      extendBody: true,
      body: Stack(
        children: [
          // Background gradient
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.5, -0.5),
                radius: 1.0,
                colors: [Color(0x1AE8503A), Color(0xFF0D0D0F)],
              ),
            ),
          ),
          _buildFeedContent(size, isTablet),
        ],
      ),
    );
  }

  Widget _buildFeedContent(Size size, bool isTablet) {
    final sparkBalance = context.watch<SubscriptionProvider>().sparkBalance;

    return Column(
      children: [
        // AppBar area
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Image.asset(
                          'assets/images/ChatGPT_Image_Apr_17__2026__08_07_43_PM-1776474490115.png',
                          width: 40,
                          height: 40,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: 'Face',
                            style: GoogleFonts.dmSans(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFFF5ECD7),
                            ),
                          ),
                          TextSpan(
                            text: 'Meet',
                            style: GoogleFonts.dmSans(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFFE8503A),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                // Spark balance pill
                GestureDetector(
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.pricingScreen),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceGlass,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: AppTheme.borderGlass),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Available ',
                              style: GoogleFonts.dmSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textMuted,
                              ),
                            ),
                            const Icon(
                              Icons.bolt_rounded,
                              color: AppTheme.primary,
                              size: 14,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$sparkBalance',
                              style: GoogleFonts.dmSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _FilterButton(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Card stack
        Expanded(child: Center(child: _buildCardArea(size, isTablet))),
        SizedBox(height: isTablet ? 16 : 90),
      ],
    );
  }

  Widget _buildCardArea(Size size, bool isTablet) {
    if (_isLoading) {
      return LoadingSkeletonWidget(
        width: isTablet ? 480.0 : size.width,
        height: size.height * 0.65,
      );
    }

    if (_profiles.isEmpty || _currentCardIndex >= _profiles.length) {
      return SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.explore_off_rounded,
                color: AppTheme.textMuted,
                size: 72,
              ),
              const SizedBox(height: 20),
              Text(
                'No profiles yet — check back soon',
                style: GoogleFonts.dmSans(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'New Sparks are added every day',
                style: GoogleFonts.dmSans(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: _loadProfiles,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE8503A), Color(0xFFD43F27)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Text(
                    'Refresh',
                    style: GoogleFonts.dmSans(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final profile = _profiles[_currentCardIndex];
    final profileId = profile['id'] as String? ?? '';
    final cardWidth = isTablet ? 480.0 : size.width;

    return SizedBox(
      width: cardWidth,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isTablet ? 0 : 16),
        child: FadeTransition(
          opacity: _cardFade,
          child: SlideTransition(
            position: _cardSlide,
            child: DiscoveryCardWidget(
              key: ValueKey(_currentCardIndex),
              userId: profileId,
              name: profile['first_name'] ?? 'Unknown',
              age: profile['age'] ?? 0,
              city: profile['city'] ?? '',
              bio: profile['bio'] ?? '',
              interests: profile['interests'] != null
                  ? List<String>.from(profile['interests'])
                  : [],
              videoUrl: profile['profile_video_url'] as String? ?? '',
              isVerified:
                  profile['verification_status'] == 'verified' ||
                  profile['is_verified'] == true,
              isOnline: profile['is_online'] as bool? ?? false,
              lastSeenAt: profile['last_seen_at'] as String?,
              videoPrompt: profile['video_prompt'] as String?,
              onSpark: _handleSpark,
              onSkip: _handleSkip,
              onBlocked: () => _removeBlockedProfile(profileId),
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final shell = context.findAncestorStateOfType<MainShellScreenState>();
        if (shell != null) {
          shell.switchToTab(profileTabIndex);
        }
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.surfaceGlass,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderGlass),
            ),
            child: const Icon(
              Icons.tune_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}
