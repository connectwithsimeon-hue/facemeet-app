import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/external_return_repair_service.dart';
import '../../services/android_diagnostics_service.dart';
import '../../services/supabase_service.dart';
import '../../services/realtime_notification_service.dart';
import '../../services/video_repair_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_navigation.dart';
import '../../widgets/in_app_notification_overlay.dart';
import '../../routes/app_routes.dart';
import '../chat_screen/chat_screen.dart';
import '../discovery_feed_screen/discovery_feed_screen.dart';
import '../events_screen/events_screen.dart';
import '../profile_screen/profile_screen.dart';
import '../spark_session_screen/sparks_screen.dart';

class MainShellScreen extends StatefulWidget {
  final int initialIndex;
  final String? chatMatchId;
  final Map<String, dynamic>? chatOtherUser;

  const MainShellScreen({
    super.key,
    this.initialIndex = discoverTabIndex,
    this.chatMatchId,
    this.chatOtherUser,
  });

  @override
  State<MainShellScreen> createState() => MainShellScreenState();
}

class MainShellScreenState extends State<MainShellScreen> {
  late int _currentIndex;

  final GlobalKey<ChatScreenState> _chatKey = GlobalKey<ChatScreenState>();
  final GlobalKey<SparksScreenState> _sparksKey =
      GlobalKey<SparksScreenState>();

  late final List<Widget> _tabs = [
    const DiscoveryFeedScreen(),
    SparksScreen(
      key: _sparksKey,
      onNavigateToDiscover: () => _onTap(discoverTabIndex),
    ),
    const EventsScreen(),
    ChatScreen(
      key: _chatKey,
      initialMatchId: widget.chatMatchId,
      initialOtherUser: widget.chatOtherUser,
    ),
    const ProfileScreen(),
  ];

  // Realtime subscription for new mutual matches (legacy — kept for reconnect watcher)
  RealtimeChannel? _matchesChannel;
  // Realtime subscription for pending match count badge
  RealtimeChannel? _pendingMatchesChannel;

  // Auto-reconnect timer
  Timer? _reconnectTimer;
  bool _matchesChannelActive = false;

  // Pending matches badge count (Sessions tab)
  int _pendingMatchCount = 0;

  // Chat tab unread message badge count
  int _chatUnreadCount = 0;

  // Overlay entry for full-screen match modal
  OverlayEntry? _matchOverlayEntry;

  // Notification stream subscription
  StreamSubscription<NotificationEvent>? _notifSubscription;
  StreamSubscription<void>? _externalReturnRepairSubscription;

  // Active banner overlay entries (stack so multiple can queue)
  final List<OverlayEntry> _bannerEntries = [];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _subscribeToNewMatches();
    _loadPendingMatchCount();
    _subscribeToPendingMatchCount();
    _startReconnectWatcher();
    _initNotificationService();
    _loadChatUnreadCount();
    _externalReturnRepairSubscription = ExternalReturnRepairService.events
        .listen((_) {
          debugPrint('MAIN SHELL: external return repair received');
          Future.delayed(const Duration(milliseconds: 120), () {
            if (!mounted) return;
            debugPrint('MAIN SHELL: layout repair setState');
            setState(() {});
            Future.delayed(const Duration(milliseconds: 80), () {
              if (!mounted) return;
              debugPrint('MAIN SHELL: video repair triggered');
              _triggerVideoRepair('external-return-repair');
            });
          });
        });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerVideoRepair('main-shell-visible');
    });
    Future.delayed(const Duration(milliseconds: 450), () {
      _triggerVideoRepair('main-shell-init-delay');
    });
  }

  void _triggerVideoRepair(String source) {
    if (!mounted) return;
    if (_currentIndex == discoverTabIndex || _currentIndex == profileTabIndex) {
      VideoRepairService.trigger(source);
    }
  }

  // ── Notification service ────────────────────────────────────────────────────
  void _initNotificationService() {
    RealtimeNotificationService.instance.initialize();
    _notifSubscription = RealtimeNotificationService.instance.notificationStream
        .listen(_handleNotificationEvent);
  }

  void _handleNotificationEvent(NotificationEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case NotificationEventType.sparkReceived:
        _showSparkBanner(event.data);
        break;
      case NotificationEventType.mutualMatch:
        // The existing _subscribeToNewMatches already shows the modal.
        // The notification service fires a second event for the OTHER user
        // (the one who didn't trigger the match insert).
        // We guard against double-showing by checking if overlay is already up.
        if (_matchOverlayEntry == null) {
          _showMatchModal(
            matchId: event.data['matchId'] as String,
            matchedUserId: event.data['matchedUserId'] as String,
            name: event.data['name'] as String,
            city: event.data['city'] as String? ?? '',
            thumbnailUrl: event.data['thumbnailUrl'] as String?,
          );
          setState(() => _pendingMatchCount++);
        }
        break;
      case NotificationEventType.newMessage:
        // Only show banner + badge when not already on Chat tab
        if (_currentIndex != chatsTabIndex) {
          setState(() => _chatUnreadCount++);
          _showMessageBanner(event.data);
        }
        break;
    }
  }

  // ── Spark banner ────────────────────────────────────────────────────────────
  void _showSparkBanner(Map<String, dynamic> data) {
    final name = data['name'] as String? ?? 'Someone';
    final thumbnailUrl = data['thumbnailUrl'] as String?;
    _showBanner(
      title: '⚡ New Spark!',
      message: '$name sparked you — check them out!',
      thumbnailUrl: thumbnailUrl,
      icon: Icons.bolt_rounded,
      accentColor: const Color(0xFFFFB800),
      onTap: () => _onTap(discoverTabIndex), // Navigate to Discover tab
    );
  }

  // ── Message banner ──────────────────────────────────────────────────────────
  void _showMessageBanner(Map<String, dynamic> data) {
    final name = data['name'] as String? ?? 'Someone';
    final content = data['content'] as String? ?? '';
    final thumbnailUrl = data['thumbnailUrl'] as String?;
    final preview = content.length > 60
        ? '${content.substring(0, 60)}…'
        : content;
    _showBanner(
      title: name,
      message: preview.isNotEmpty ? preview : 'Sent you a message',
      thumbnailUrl: thumbnailUrl,
      icon: Icons.chat_bubble_rounded,
      accentColor: const Color(0xFF4CAF50),
      onTap: () => _onTap(chatsTabIndex), // Navigate to Chat tab
    );
  }

  // ── Generic banner helper ───────────────────────────────────────────────────
  void _showBanner({
    required String title,
    required String message,
    String? thumbnailUrl,
    required IconData icon,
    required Color accentColor,
    VoidCallback? onTap,
  }) {
    final overlay = Navigator.of(context, rootNavigator: true).overlay;
    if (overlay == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => InAppBannerNotification(
        title: title,
        message: message,
        thumbnailUrl: thumbnailUrl,
        icon: icon,
        accentColor: accentColor,
        onTap: onTap,
        onDismiss: () {
          entry.remove();
          _bannerEntries.remove(entry);
        },
      ),
    );

    _bannerEntries.add(entry);
    overlay.insert(entry);
  }

  // ── Chat unread count ───────────────────────────────────────────────────────
  Future<void> _loadChatUnreadCount() async {
    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid == null) return;
      final unread = await SupabaseService.instance.client
          .from('messages')
          .select('id')
          .neq('sender_id', uid)
          .eq('is_read', false);
      if (mounted) {
        setState(() => _chatUnreadCount = (unread as List).length);
      }
    } catch (_) {}
  }

  // ── Fix 3: Auto-reconnect every 30s if subscription is not active ──
  void _startReconnectWatcher() {
    _reconnectTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_matchesChannelActive) {
        debugPrint(
          '[Matches Realtime] Subscription inactive — reconnecting...',
        );
        _matchesChannel?.unsubscribe();
        _matchesChannel = null;
        _subscribeToNewMatches();
      } else {
        debugPrint('[Matches Realtime] Subscription active ✓');
      }
    });
  }

  /// Initial load of pending match count
  Future<void> _loadPendingMatchCount() async {
    try {
      final matches = await SupabaseService.instance.getPendingMatches();
      if (mounted) {
        setState(() => _pendingMatchCount = matches.length);
      }
    } catch (_) {}
  }

  /// Subscribe to matches table changes to keep badge count up to date
  void _subscribeToPendingMatchCount() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    _pendingMatchesChannel = SupabaseService.instance.client
        .channel('pending_matches_badge:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'matches',
          callback: (_) async {
            try {
              final matches = await SupabaseService.instance
                  .getPendingMatches();
              if (mounted) {
                setState(() => _pendingMatchCount = matches.length);
              }
            } catch (_) {}
          },
        )
        .subscribe();
  }

  void _subscribeToNewMatches() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    _matchesChannelActive = false;
    debugPrint('[Matches Realtime] Subscribing for user $uid...');

    _matchesChannel = SupabaseService.instance.client
        .channel('new_matches_modal:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'matches',
          callback: (payload) async {
            final record = payload.newRecord;
            // Only handle matched_pending_session rows involving current user
            if ((record['user_1_id'] == uid || record['user_2_id'] == uid) &&
                record['status'] == 'matched_pending_session') {
              debugPrint(
                '[Matches Realtime] New match detected: ${record['id']}',
              );
              final otherId = record['user_1_id'] == uid
                  ? record['user_2_id'] as String
                  : record['user_1_id'] as String;

              try {
                final profile = await SupabaseService.instance.getUserProfile(
                  otherId,
                );
                final matchId = record['id'] as String? ?? '';
                final name = profile?['first_name'] as String? ?? 'Someone';
                final city = profile?['city'] as String? ?? '';
                final thumbnailUrl = profile?['thumbnail_url'] as String?;

                if (mounted) {
                  _showMatchModal(
                    matchId: matchId,
                    matchedUserId: otherId,
                    name: name,
                    city: city,
                    thumbnailUrl: thumbnailUrl,
                  );
                  // Bump badge count immediately
                  setState(() => _pendingMatchCount++);
                }
              } catch (e) {
                debugPrint('[Matches Realtime] Error fetching profile: $e');
              }
            }
          },
        )
        .subscribe((status, [error]) {
          debugPrint('[Matches Realtime] Status: $status, error: $error');
          _matchesChannelActive = status == RealtimeSubscribeStatus.subscribed;
        });
  }

  // ── Full-screen modal overlay via root navigator OverlayEntry ──
  void _showMatchModal({
    required String matchId,
    required String matchedUserId,
    required String name,
    required String city,
    required String? thumbnailUrl,
  }) {
    // Remove any existing overlay first
    _removeMatchOverlay();
    debugPrint(
      'SPARK SESSION: join prompt shown on receiver — matchId=$matchId',
    );

    _matchOverlayEntry = OverlayEntry(
      builder: (ctx) => _SparkMatchModal(
        matchId: matchId,
        matchedUserId: matchedUserId,
        name: name,
        city: city,
        thumbnailUrl: thumbnailUrl,
        onJoinNow: () {
          debugPrint(
            'SPARK SESSION: join tapped from Mutual Spark prompt — matchId=$matchId',
          );
          _removeMatchOverlay();
          unawaited(
            _openCanonicalSparkSession(
              matchId: matchId,
              matchedUserId: matchedUserId,
              source: 'main_shell_mutual_match_popup',
            ),
          );
        },
        onJoinLater: () {
          _removeMatchOverlay();
        },
      ),
    );

    // Insert into the root overlay so it appears above everything
    final overlay = Navigator.of(context, rootNavigator: true).overlay;
    overlay?.insert(_matchOverlayEntry!);
  }

  Future<void> _openCanonicalSparkSession({
    required String matchId,
    required String matchedUserId,
    required String source,
  }) async {
    await AndroidDiagnosticsService.instance.setValue(
      'entry_point_before_navigation',
      source,
    );
    final result = await SupabaseService.instance
        .startOrJoinCanonicalSparkSession(matchId: matchId, source: source);
    await AndroidDiagnosticsService.instance.setValues({
      'canonical_resolver_source': source,
      'canonical_resolver_result': result.canEnter ? 'joinable' : 'rejected',
      'canonical_resolver_reject_reason': result.canEnter
          ? 'none'
          : result.reason,
      'session_key_used_for_navigation': AndroidDiagnosticsService.shortId(
        result.sessionKey,
      ),
    });
    if (!mounted) return;
    if (!result.canEnter) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not start Spark Session: ${result.reason}'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    Navigator.pushNamed(
      context,
      AppRoutes.sparkSessionScreen,
      arguments: {
        'matchId': result.matchId,
        'matchedUserId': matchedUserId,
        'sessionId': result.sessionId,
        'sessionKey': result.sessionKey,
      },
    );
  }

  void _removeMatchOverlay() {
    _matchOverlayEntry?.remove();
    _matchOverlayEntry = null;
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _matchesChannel?.unsubscribe();
    _pendingMatchesChannel?.unsubscribe();
    _notifSubscription?.cancel();
    _externalReturnRepairSubscription?.cancel();
    RealtimeNotificationService.instance.dispose();
    _removeMatchOverlay();
    for (final entry in _bannerEntries) {
      try {
        entry.remove();
      } catch (_) {}
    }
    _bannerEntries.clear();
    super.dispose();
  }

  void _onTap(int index) {
    if (index == _currentIndex) {
      if (index == discoverTabIndex || index == profileTabIndex) {
        _triggerVideoRepair('selected-tab-retap-$index');
      }
      return;
    }
    // Clear badge when user navigates to Sparks tab
    if (index == sparksTabIndex) {
      setState(() => _pendingMatchCount = 0);
      Future.delayed(const Duration(milliseconds: 500), _loadPendingMatchCount);
    }
    // Clear chat badge when user navigates to Chat tab
    if (index == chatsTabIndex) {
      setState(() => _chatUnreadCount = 0);
    }
    setState(() => _currentIndex = index);
    if (index == discoverTabIndex || index == profileTabIndex) {
      Future.delayed(const Duration(milliseconds: 260), () {
        _triggerVideoRepair('tab-switch-$index');
      });
    }
  }

  void navigateToTab(int index) {
    setState(() => _currentIndex = index);
    if (index == discoverTabIndex || index == profileTabIndex) {
      Future.delayed(const Duration(milliseconds: 260), () {
        _triggerVideoRepair('navigate-to-tab-$index');
      });
    }
  }

  void switchToTab(int index) {
    setState(() => _currentIndex = index);
    if (index == discoverTabIndex || index == profileTabIndex) {
      Future.delayed(const Duration(milliseconds: 260), () {
        _triggerVideoRepair('switch-to-tab-$index');
      });
    }
  }

  /// Navigates to the Sessions tab (index 1) and triggers an immediate refresh
  /// so a waiting spark session appears without manual pull-to-refresh.
  void refreshSparks() {
    setState(() {
      _pendingMatchCount = 0;
      _currentIndex = sparksTabIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sparksKey.currentState?.refresh();
      Future.delayed(const Duration(milliseconds: 500), _loadPendingMatchCount);
    });
  }

  /// Opens the Chat tab and navigates directly to the conversation for [matchId].
  void openChat(String matchId, Map<String, dynamic>? otherUser) {
    // Switch to chat tab first
    if (_currentIndex != chatsTabIndex) {
      setState(() {
        _chatUnreadCount = 0;
        _currentIndex = chatsTabIndex;
      });
    }
    // Then open the conversation after the tab is visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _chatKey.currentState?.openConversation(matchId, otherUser);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width >= 600;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return WillPopScope(
      onWillPop: () async {
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0x33FFFFFF), width: 1),
            ),
            title: const Text(
              'Exit app?',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'Are you sure you want to exit FaceMeet?',
              style: TextStyle(color: Color(0xFF8A8A9A)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text(
                  'Stay',
                  style: TextStyle(color: Color(0xFFFF4458)),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text(
                  'Exit',
                  style: TextStyle(color: Color(0xFF8A8A9A)),
                ),
              ),
            ],
          ),
        );
        if (shouldExit == true) {
          SystemNavigator.pop();
        }
        return false;
      },
      child: SafeArea(
        bottom: false,
        child: Scaffold(
          backgroundColor: AppTheme.backgroundDark,
          extendBody: true,
          body: isTablet
              ? Row(
                  children: [
                    AppNavigationRail(
                      currentIndex: _currentIndex,
                      onTap: _onTap,
                    ),
                    const VerticalDivider(
                      width: 1,
                      color: AppTheme.borderGlass,
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: _currentIndex,
                        children: _tabs,
                      ),
                    ),
                  ],
                )
              : Stack(
                  children: [
                    IndexedStack(index: _currentIndex, children: _tabs),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: bottomPadding),
                        child: AppNavigation(
                          currentIndex: _currentIndex,
                          onTap: _onTap,
                          sessionsBadge: _pendingMatchCount,
                          chatBadge: _chatUnreadCount,
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ── Full-screen frosted glass modal overlay ──
class _SparkMatchModal extends StatefulWidget {
  final String matchId;
  final String matchedUserId;
  final String name;
  final String city;
  final String? thumbnailUrl;
  final VoidCallback onJoinNow;
  final VoidCallback onJoinLater;

  const _SparkMatchModal({
    required this.matchId,
    required this.matchedUserId,
    required this.name,
    required this.city,
    required this.thumbnailUrl,
    required this.onJoinNow,
    required this.onJoinLater,
  });

  @override
  State<_SparkMatchModal> createState() => _SparkMatchModalState();
}

class _SparkMatchModalState extends State<_SparkMatchModal>
    with TickerProviderStateMixin {
  late AnimationController _fadeCtrl;
  late AnimationController _pulseCtrl;
  late Animation<double> _fadeAnim;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _pulseAnim = Tween<double>(
      begin: 0.7,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: double.infinity,
          height: double.infinity,
          color: const Color(0xCC000000),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xE61A1A2E),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: const Color(0x66FF4458),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFFF4458).withAlpha(50),
                          blurRadius: 40,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'FaceMeet',
                            style: GoogleFonts.dmSans(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: const Color(0x99FFFFFF),
                              letterSpacing: 1.5,
                            ),
                          ),
                          const SizedBox(height: 20),
                          AnimatedBuilder(
                            animation: _pulseAnim,
                            builder: (_, __) => Transform.scale(
                              scale: _pulseAnim.value,
                              child: Container(
                                width: 72,
                                height: 72,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0x33FF4458),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFFFF4458).withAlpha(
                                        (80 * _pulseAnim.value).toInt(),
                                      ),
                                      blurRadius: 24,
                                      spreadRadius: 4,
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.bolt_rounded,
                                  color: Color(0xFFFF4458),
                                  size: 40,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFFFF4458),
                                width: 2.5,
                              ),
                            ),
                            child: ClipOval(
                              child:
                                  widget.thumbnailUrl != null &&
                                      widget.thumbnailUrl!.isNotEmpty
                                  ? Image.network(
                                      widget.thumbnailUrl!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) =>
                                          _InitialAvatar(name: widget.name),
                                    )
                                  : _InitialAvatar(name: widget.name),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            widget.name,
                            style: GoogleFonts.dmSans(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          if (widget.city.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.location_on_rounded,
                                  color: Color(0xFF8A8A9A),
                                  size: 13,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  widget.city,
                                  style: GoogleFonts.dmSans(
                                    fontSize: 13,
                                    color: const Color(0xFF8A8A9A),
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 16),
                          Text(
                            'You have a mutual Spark with ${widget.name} — they are waiting for you right now.',
                            style: GoogleFonts.dmSans(
                              fontSize: 15,
                              color: Colors.white,
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 28),
                          SizedBox(
                            width: double.infinity,
                            child: GestureDetector(
                              onTap: widget.onJoinNow,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFFFF4458),
                                      Color(0xFFFF6B7A),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFFFF4458,
                                      ).withAlpha(100),
                                      blurRadius: 20,
                                      offset: const Offset(0, 6),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  'Join Spark Session now',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          GestureDetector(
                            onTap: widget.onJoinLater,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                'Join later',
                                style: GoogleFonts.dmSans(
                                  fontSize: 14,
                                  color: const Color(0xFF8A8A9A),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
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

class _InitialAvatar extends StatelessWidget {
  final String name;
  const _InitialAvatar({required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFF4458),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: GoogleFonts.dmSans(
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
