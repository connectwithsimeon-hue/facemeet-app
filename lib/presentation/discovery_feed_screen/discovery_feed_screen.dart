import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../providers/subscription_provider.dart';
import '../../routes/app_routes.dart';
import '../../services/android_diagnostics_service.dart';
import '../../services/supabase_service.dart';
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
  bool _hasUpcomingEvents = false;
  String _selectedIntentFilter = 'all';
  String _viewerConnectionIntent = SupabaseService.defaultConnectionIntent;

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
      final currentProfile = await SupabaseService.instance
          .getCurrentUserProfile();
      final viewerIntent = SupabaseService.normalizeConnectionIntent(
        currentProfile?['connection_intent'] as String?,
      );
      final nextSelectedFilter =
          _isFilterAllowedForViewer(_selectedIntentFilter, viewerIntent)
          ? _selectedIntentFilter
          : 'all';
      final results = await Future.wait([
        SupabaseService.instance.getDiscoveryFeed(
          connectionIntentFilter: _effectiveIntentFilterForViewer(
            nextSelectedFilter,
            viewerIntent,
          ),
        ),
        SupabaseService.instance.getMyAccessibleEvents(),
      ]);
      final profiles = List<Map<String, dynamic>>.from(results[0] as List);
      final events = List<Map<String, dynamic>>.from(results[1] as List);
      if (mounted) {
        setState(() {
          _profiles = profiles;
          _hasUpcomingEvents = events.isNotEmpty;
          _viewerConnectionIntent = viewerIntent;
          _selectedIntentFilter = nextSelectedFilter;
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
    final senderUserId = SupabaseService.instance.currentUserId;
    String? senderThumbnailUrl;
    try {
      final senderProfile = await SupabaseService.instance
          .getCurrentUserProfile();
      senderThumbnailUrl =
          (senderProfile?['thumbnail_url'] as String?)?.trim().isNotEmpty ==
              true
          ? senderProfile!['thumbnail_url'] as String
          : null;
    } catch (e) {
      debugPrint('PUSH NOTIFICATION: sender thumbnail lookup skipped — $e');
    }
    final notificationData = {
      ...data,
      'type': type,
      if (senderUserId != null) 'sender_user_id': senderUserId,
      if (senderThumbnailUrl != null)
        'sender_thumbnail_url': senderThumbnailUrl,
      if (senderThumbnailUrl != null) 'image': senderThumbnailUrl,
    };
    try {
      final response = await SupabaseService.instance.client.functions.invoke(
        'send_push_notification',
        body: {
          'user_id': userId,
          'target_user_id': userId,
          if (senderUserId != null) 'sender_user_id': senderUserId,
          'type': type,
          'title': title,
          'body': body,
          'data': notificationData,
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
      final targetUserShort = responseData is Map
          ? (responseData['target_user_short']?.toString() ??
                AndroidDiagnosticsService.shortId(userId))
          : AndroidDiagnosticsService.shortId(userId);
      final senderUserShort = responseData is Map
          ? (responseData['sender_user_short']?.toString() ??
                AndroidDiagnosticsService.shortId(senderUserId))
          : AndroidDiagnosticsService.shortId(senderUserId);
      final targetEqualsSender = responseData is Map
          ? responseData['target_equals_sender'] == true
          : false;
      final selfSuppressed = responseData is Map
          ? responseData['self_notification_suppressed'] == true
          : false;
      final targetNativeTokenCount = responseData is Map
          ? ((responseData['target_native_token_count'] as num?)?.toInt() ??
                nativeTokenRows)
          : nativeTokenRows;
      final targetWebSubscriptionCount = responseData is Map
          ? ((responseData['target_web_subscription_count'] as num?)?.toInt() ??
                webSent)
          : webSent;
      final webPushAttempted = responseData is Map
          ? responseData['web_push_attempted'] == true
          : false;
      final webPushSuccessCount = responseData is Map
          ? ((responseData['web_push_success_count'] as num?)?.toInt() ??
                webSent)
          : webSent;
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
        'push_target_user_short': targetUserShort,
        'push_sender_user_short': senderUserShort,
        'push_target_equals_sender': targetEqualsSender ? 'yes' : 'no',
        'push_self_notification_suppressed': selfSuppressed ? 'yes' : 'no',
        'push_target_native_token_count': targetNativeTokenCount,
        'push_target_web_subscription_count': targetWebSubscriptionCount,
        'web_push_attempted': webPushAttempted ? 'yes' : 'no',
        'web_push_success_count': webPushSuccessCount,
      });
    } catch (e) {
      await AndroidDiagnosticsService.instance.setValue(
        'last_push_invoke_result',
        'type=$type, error',
      );
      debugPrint('PUSH NOTIFICATION: failed to send type=$type — $e');
    }
    return nativePushSent;
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
    final sparkType = await _resolveSparkTypeForViewer();
    if (sparkType == null) {
      debugPrint('DISCOVERY_SPARK: spark type selection cancelled');
      return;
    }
    debugPrint(
      'DISCOVERY_SPARK: from_user_id=$currentUid, to_user_id=$uid, action_type=spark, spark_type=$sparkType',
    );
    debugPrint('SPARK SESSION: user sparked — toUserId=$uid');

    // Step 1 — Insert interaction row and verify success
    Map<String, dynamic>? insertedRow;
    try {
      insertedRow = await SupabaseService.instance.saveInteraction(
        toUserId: uid,
        actionType: 'spark',
        sparkType: sparkType,
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

    // Step 1b — Send spark notification to the sparked user.
    // Professional Connection Sparks intentionally reveal the sender profile;
    // Dating/Friendship Sparks keep the private mystery flow.
    debugPrint('SPARK PUSH: spark created');
    debugPrint(
      'SPARK PUSH: recipient user id present yes/no=${uid.isNotEmpty}',
    );
    final isProfessionalSpark = sparkType == 'professional';
    final professionalSenderName = isProfessionalSpark
        ? await _currentUserFirstName()
        : null;
    unawaited(
      _sendPushNotification(
        userId: uid,
        type: 'new_spark',
        title: isProfessionalSpark
            ? 'Professional Connection Spark'
            : 'Someone Sparked you ⚡',
        body: isProfessionalSpark
            ? '${professionalSenderName ?? 'Someone'} wants to connect professionally.'
            : 'Open FaceMeet to see who felt a spark.',
        data: {
          'type': 'new_spark',
          'url': isProfessionalSpark && currentUid != null
              ? '/?push_type=new_spark&spark_type=professional&sender_user_id=$currentUid'
              : '/',
          'spark_type': sparkType,
          if (isProfessionalSpark && currentUid != null)
            'professional_spark_sender_id': currentUid,
        },
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

              debugPrint(
                'MUTUAL SPARK PUSH: self-notification skipped for initiating user',
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

  Future<String?> _currentUserFirstName() async {
    try {
      final profile = await SupabaseService.instance.getCurrentUserProfile();
      final firstName = profile?['first_name']?.toString().trim();
      return firstName == null || firstName.isEmpty ? null : firstName;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveSparkTypeForViewer() async {
    final viewerIntent = SupabaseService.normalizeConnectionIntent(
      _viewerConnectionIntent,
    );
    if (viewerIntent != 'open_to_all') {
      return SupabaseService.sparkTypeForConnectionIntent(viewerIntent);
    }
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SparkTypeSelectorSheet(),
    );
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

  void _changeIntentFilter(String value) {
    if (_selectedIntentFilter == value) return;
    if (!_isFilterAllowedForViewer(value, _viewerConnectionIntent)) return;
    setState(() {
      _selectedIntentFilter = value;
      _currentCardIndex = 0;
    });
    _cardController.reset();
    _loadProfiles();
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
        _buildIntentFilterRow(),
        const SizedBox(height: 12),
        if (_hasUpcomingEvents) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _buildEventsPromoCard(),
          ),
          const SizedBox(height: 12),
        ],
        // Card stack
        Expanded(child: Center(child: _buildCardArea(size, isTablet))),
        SizedBox(height: isTablet ? 16 : 90),
      ],
    );
  }

  Widget _buildEventsPromoCard() {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, AppRoutes.eventsScreen),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppTheme.surfaceGlass,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.borderGlass),
        ),
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0x22E8503A),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.event_available_rounded,
                color: AppTheme.primary,
                size: 21,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Upcoming FaceMeet Events',
                    style: GoogleFonts.dmSans(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Request access to curated FaceMeet social events.',
                    style: GoogleFonts.dmSans(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'View Events',
              style: GoogleFonts.dmSans(
                color: AppTheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
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
              connectionIntent:
                  profile['connection_intent'] as String? ??
                  SupabaseService.defaultConnectionIntent,
              onSpark: _handleSpark,
              onSkip: _handleSkip,
              onBlocked: () => _removeBlockedProfile(profileId),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIntentFilterRow() {
    final filters = _availableIntentFiltersForViewer(_viewerConnectionIntent);

    if (filters.length <= 1) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 38,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final filter = filters[index];
          return _IntentFilterChip(
            label: filter.label,
            isSelected: _selectedIntentFilter == filter.value,
            onTap: () => _changeIntentFilter(filter.value),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: filters.length,
      ),
    );
  }

  List<_IntentFilterOption> _availableIntentFiltersForViewer(
    String? viewerIntent,
  ) {
    final normalized = SupabaseService.normalizeConnectionIntent(viewerIntent);
    const allFilters = [
      _IntentFilterOption(value: 'all', label: 'All'),
      _IntentFilterOption(value: 'dating', label: 'Dating'),
      _IntentFilterOption(value: 'friendship', label: 'Friendship'),
      _IntentFilterOption(
        value: 'professional',
        label: 'Professional Connections',
      ),
    ];

    if (normalized == 'open_to_all') return allFilters;

    return allFilters
        .where((filter) {
          return filter.value == 'all' || filter.value == normalized;
        })
        .toList(growable: false);
  }

  bool _isFilterAllowedForViewer(String filter, String? viewerIntent) {
    return _availableIntentFiltersForViewer(
      viewerIntent,
    ).any((option) => option.value == filter);
  }

  String _effectiveIntentFilterForViewer(
    String selectedFilter,
    String? viewerIntent,
  ) {
    final normalized = SupabaseService.normalizeConnectionIntent(viewerIntent);
    if (selectedFilter != 'all') return selectedFilter;
    return normalized == 'open_to_all' ? 'all' : normalized;
  }
}

class _SparkTypeSelectorSheet extends StatelessWidget {
  const _SparkTypeSelectorSheet();

  static const _options = [
    _SparkTypeOption(value: 'dating', label: 'Dating Spark'),
    _SparkTypeOption(value: 'friendship', label: 'Friendship Spark'),
    _SparkTypeOption(
      value: 'professional',
      label: 'Professional Connection Spark',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(14),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        decoration: BoxDecoration(
          color: const Color(0xFF17171F),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: AppTheme.borderGlass),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 30,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What kind of Spark?',
              style: GoogleFonts.dmSans(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Choose the connection context for this Spark.',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            ..._options.map((option) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.of(context).pop(option.value),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceGlass,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.borderGlass),
                    ),
                    child: Text(
                      option.label,
                      style: GoogleFonts.dmSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _SparkTypeOption {
  final String value;
  final String label;

  const _SparkTypeOption({required this.value, required this.label});
}

class _IntentFilterOption {
  final String value;
  final String label;

  const _IntentFilterOption({required this.value, required this.label});
}

class _IntentFilterChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _IntentFilterChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary : AppTheme.surfaceGlass,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.borderGlass,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: isSelected ? Colors.white : AppTheme.textSecondary,
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
