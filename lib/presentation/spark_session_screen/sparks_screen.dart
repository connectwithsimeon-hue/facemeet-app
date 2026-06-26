import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import '../../main.dart' show mainShellKey;
import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/profile_avatar.dart';
import 'widgets/spark_schedule_sheet.dart';

class SparksScreen extends StatefulWidget {
  final VoidCallback? onNavigateToDiscover;

  const SparksScreen({super.key, this.onNavigateToDiscover});

  @override
  State<SparksScreen> createState() => SparksScreenState();
}

class SparksScreenState extends State<SparksScreen>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  List<Map<String, dynamic>> _pendingMatches = [];
  List<Map<String, dynamic>> _scheduledIntros = [];
  List<Map<String, dynamic>> _chatUnlockedMatches = [];

  RealtimeChannel? _matchesChannel;
  RealtimeChannel? _schedulesChannel;
  RealtimeChannel? _presenceChannel;
  // Map of userId -> {is_online, last_seen_at}
  final Map<String, Map<String, dynamic>> _presenceMap = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialLoad();
  }

  /// Perform an immediate one-time fetch, then attach the realtime listener.
  /// If the first fetch returns empty (Supabase connection may still be
  /// initialising on a cold start), retry once after 2 seconds.
  Future<void> _initialLoad() async {
    await _loadMatches();

    // Retry once if both lists are still empty (cold-start race condition)
    if (_pendingMatches.isEmpty &&
        _scheduledIntros.isEmpty &&
        _chatUnlockedMatches.isEmpty) {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) await _loadMatches();
    }

    // Attach realtime listener only after the initial fetch is done
    if (mounted) {
      _subscribeToMatchChanges();
      _subscribeToScheduleChanges();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _matchesChannel?.unsubscribe();
    _schedulesChannel?.unsubscribe();
    _presenceChannel?.unsubscribe();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Refresh when app comes back to foreground (e.g. opened from notification)
    if (state == AppLifecycleState.resumed && mounted) {
      _loadMatches();
    }
  }

  /// Public method so MainShellScreen can trigger a refresh externally
  /// (e.g. when a spark_session notification is tapped).
  void refresh() {
    if (mounted) _loadMatches();
  }

  /// Subscribe to any match changes so the Ready to Spark section stays live
  void _subscribeToMatchChanges() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    _matchesChannel = SupabaseService.instance.client
        .channel('sparks_screen_matches:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'matches',
          callback: (_) => _loadMatches(),
        )
        .subscribe();
  }

  void _subscribeToScheduleChanges() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    _schedulesChannel = SupabaseService.instance.client
        .channel('spark_session_schedules:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'spark_session_schedules',
          callback: (_) => _loadMatches(),
        )
        .subscribe();
  }

  Future<void> _loadMatches() async {
    setState(() => _isLoading = true);
    try {
      final pending = await SupabaseService.instance.getPendingMatches();
      final chatUnlocked = await SupabaseService.instance
          .getChatUnlockedMatches();
      final schedules = await SupabaseService.instance
          .getMyScheduledSparkSessions();

      // Enrich each match with the other user's profile
      final uid = SupabaseService.instance.currentUserId;

      // Bug 1 fix: filter out any chat_unlocked matches from pending list
      // (safety net in case status update was delayed or partially applied)
      final filteredPending = pending
          .where((m) => m['status'] != 'chat_unlocked')
          .toList();

      final enrichedSchedules = await _enrichSchedules(schedules, uid);
      final scheduledMatchIds = enrichedSchedules
          .map((schedule) => schedule['match_id'] as String?)
          .whereType<String>()
          .toSet();
      final enrichedPending = await _enrichMatches(
        filteredPending
            .where(
              (match) => !scheduledMatchIds.contains(match['id'] as String?),
            )
            .toList(),
        uid,
      );
      final enrichedChat = await _enrichMatches(chatUnlocked, uid);

      if (mounted) {
        setState(() {
          _pendingMatches = enrichedPending;
          _scheduledIntros = enrichedSchedules;
          _chatUnlockedMatches = enrichedChat;
          _isLoading = false;
        });
        // Subscribe to presence for all matched users
        _subscribeToPresence();
      }
    } catch (e) {
      debugPrint('SPARKS SCREEN LOAD ERROR: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _enrichMatches(
    List<Map<String, dynamic>> matches,
    String? uid,
  ) async {
    final enriched = <Map<String, dynamic>>[];
    for (final match in matches) {
      final otherId = match['user_1_id'] == uid
          ? match['user_2_id'] as String
          : match['user_1_id'] as String;
      final profile = await SupabaseService.instance.getUserProfile(otherId);

      // Fetch last message for chat_unlocked matches
      String lastMessage = 'Chat is unlocked — say hello!';
      String lastMessageTime = '';
      if (match['status'] == 'chat_unlocked') {
        try {
          final msgs = await SupabaseService.instance.client
              .from('messages')
              .select('content, created_at')
              .eq('match_id', match['id'] as String)
              .order('created_at', ascending: false)
              .limit(1);
          if ((msgs as List).isNotEmpty) {
            lastMessage = msgs[0]['content'] as String? ?? lastMessage;
            final createdAt = DateTime.tryParse(
              msgs[0]['created_at'] as String? ?? '',
            );
            if (createdAt != null) {
              final diff = DateTime.now().difference(createdAt);
              if (diff.inMinutes < 60) {
                lastMessageTime = '${diff.inMinutes}m ago';
              } else if (diff.inHours < 24) {
                lastMessageTime = '${diff.inHours}h ago';
              } else {
                lastMessageTime = '${diff.inDays}d ago';
              }
            }
          }
        } catch (_) {}
      }

      enriched.add({
        ...match,
        'other_user': profile ?? {},
        'last_message': lastMessage,
        'last_message_time': lastMessageTime,
      });
    }
    return enriched;
  }

  Future<List<Map<String, dynamic>>> _enrichSchedules(
    List<Map<String, dynamic>> schedules,
    String? uid,
  ) async {
    final enriched = <Map<String, dynamic>>[];
    for (final schedule in schedules) {
      final proposerId = schedule['proposer_user_id'] as String?;
      final recipientId = schedule['recipient_user_id'] as String?;
      final otherId = proposerId == uid ? recipientId : proposerId;
      final matchId = schedule['match_id'] as String?;
      if (otherId == null || matchId == null) continue;
      final blocked = await SupabaseService.instance.hasBlockBetween(otherId);
      if (blocked) continue;
      final profile = await SupabaseService.instance.getUserProfile(otherId);
      if (!SupabaseService.instance.isUserFacingProfileAvailable(profile)) {
        continue;
      }
      final match = await SupabaseService.instance.getMatch(matchId);
      if (match == null) continue;
      final matchStatus = match['status']?.toString().trim().toLowerCase();
      if (matchStatus == 'chat_unlocked' || matchStatus == 'session_ended') {
        continue;
      }
      enriched.add({...schedule, 'other_user': profile ?? {}, 'match': match});
    }
    return enriched;
  }

  void _startSparkSession(Map<String, dynamic> match) {
    final matchId = match['id'] as String;
    final uid = SupabaseService.instance.currentUserId;
    final otherId = match['user_1_id'] == uid
        ? match['user_2_id'] as String
        : match['user_1_id'] as String;

    debugPrint('SPARK SESSION: join tapped from Sessions — matchId=$matchId');
    Navigator.pushNamed(
      context,
      AppRoutes.sparkSessionScreen,
      arguments: {'matchId': matchId, 'matchedUserId': otherId},
    );
  }

  void _startScheduledSparkSession(Map<String, dynamic> schedule) {
    final match = schedule['match'] as Map<String, dynamic>? ?? {};
    final other = schedule['other_user'] as Map<String, dynamic>? ?? {};
    final matchId =
        (schedule['match_id'] as String?) ?? (match['id'] as String?);
    final otherId = other['id'] as String? ?? '';
    if (matchId == null || matchId.isEmpty || otherId.isEmpty) return;

    debugPrint(
      'SPARK SESSION: join tapped from scheduled intro — matchId=$matchId',
    );
    Navigator.pushNamed(
      context,
      AppRoutes.sparkSessionScreen,
      arguments: {'matchId': matchId, 'matchedUserId': otherId},
    );
  }

  /// Subscribe to realtime presence updates for all matched users
  void _subscribeToPresence() {
    _presenceChannel?.unsubscribe();
    final uid = SupabaseService.instance.currentUserId;

    // Collect all matched user IDs
    final matchedIds = <String>{};
    for (final m in [
      ..._pendingMatches,
      ..._scheduledIntros,
      ..._chatUnlockedMatches,
    ]) {
      final other = m['other_user'] as Map<String, dynamic>? ?? {};
      final otherId = other['id'] as String? ?? '';
      if (otherId.isNotEmpty && otherId != uid) {
        matchedIds.add(otherId);
        // Seed presence map from loaded profile data
        _presenceMap[otherId] = {
          'is_online': other['is_online'] as bool? ?? false,
          'last_seen_at': other['last_seen_at'] as String?,
        };
      }
    }

    if (matchedIds.isEmpty) return;

    // Subscribe to users table changes for matched user IDs
    _presenceChannel = SupabaseService.instance.client
        .channel('sparks_presence_${uid ?? 'anon'}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          callback: (payload) {
            final record = payload.newRecord;
            final recordId = record['id'] as String?;
            if (recordId != null && matchedIds.contains(recordId)) {
              if (mounted) {
                setState(() {
                  _presenceMap[recordId] = {
                    'is_online': record['is_online'] as bool? ?? false,
                    'last_seen_at': record['last_seen_at'] as String?,
                  };
                });
              }
            }
          },
        )
        .subscribe();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        // SparksScreen is a tab inside MainShellScreen — do not pop the shell
        return false;
      },
      child: Scaffold(
        backgroundColor: AppTheme.backgroundDark,
        extendBody: true,
        appBar: PreferredSize(
          preferredSize: Size.zero,
          child: AppBar(
            leading: const SizedBox.shrink(),
            automaticallyImplyLeading: false,
            leadingWidth: 0,
            toolbarHeight: 0,
            elevation: 0,
            backgroundColor: Colors.transparent,
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.5, -0.5),
              radius: 1.0,
              colors: [Color(0x1AFF4458), Color(0xFF0D0D0F)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: Text(
                    'Sparks',
                    style: GoogleFonts.dmSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: _isLoading
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFFFF4458),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _loadMatches,
                          color: const Color(0xFFFF4458),
                          backgroundColor: const Color(0xFF1A1A2E),
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                            children: [
                              if (_scheduledIntros.isNotEmpty) ...[
                                _SectionHeader(
                                  title: 'Scheduled Intros',
                                  subtitle:
                                      '${_scheduledIntros.length} intro${_scheduledIntros.length > 1 ? 's' : ''} planned',
                                ),
                                const SizedBox(height: 12),
                                ..._scheduledIntros.map((schedule) {
                                  final other =
                                      schedule['other_user']
                                          as Map<String, dynamic>? ??
                                      {};
                                  final otherId = other['id'] as String? ?? '';
                                  final presence = _presenceMap[otherId];
                                  final isOnline =
                                      presence?['is_online'] as bool? ??
                                      (other['is_online'] as bool? ?? false);
                                  return _ScheduledIntroCard(
                                    schedule: schedule,
                                    isOnline: isOnline,
                                    onRefresh: _loadMatches,
                                    onStartSession: () =>
                                        _startScheduledSparkSession(schedule),
                                  );
                                }),
                                const SizedBox(height: 24),
                              ],
                              // ── Ready to Spark section ──
                              if (_pendingMatches.isNotEmpty) ...[
                                _SectionHeader(
                                  title: 'Ready to Spark',
                                  subtitle:
                                      '${_pendingMatches.length} mutual match${_pendingMatches.length > 1 ? 'es' : ''} waiting',
                                ),
                                const SizedBox(height: 12),
                                ..._pendingMatches.map((match) {
                                  final other =
                                      match['other_user']
                                          as Map<String, dynamic>? ??
                                      {};
                                  final otherId = other['id'] as String? ?? '';
                                  final presence = _presenceMap[otherId];
                                  final isOnline =
                                      presence?['is_online'] as bool? ??
                                      (other['is_online'] as bool? ?? false);
                                  return _PendingMatchCard(
                                    match: match,
                                    isOnline: isOnline,
                                    onStartSession: () =>
                                        _startSparkSession(match),
                                    onScheduleSession: () async {
                                      final scheduled =
                                          await showSparkScheduleSheet(
                                            context,
                                            matchId: match['id'] as String,
                                            recipientUserId: otherId,
                                            recipientName:
                                                other['first_name']
                                                    as String? ??
                                                'your match',
                                          );
                                      if (scheduled) _loadMatches();
                                    },
                                  );
                                }),
                                const SizedBox(height: 24),
                              ],
                              // ── Chat Unlocked section ──
                              if (_chatUnlockedMatches.isNotEmpty) ...[
                                _SectionHeader(
                                  title: 'Messages',
                                  subtitle:
                                      '${_chatUnlockedMatches.length} chat${_chatUnlockedMatches.length > 1 ? 's' : ''} unlocked',
                                ),
                                const SizedBox(height: 12),
                                ..._chatUnlockedMatches.map((match) {
                                  final other =
                                      match['other_user']
                                          as Map<String, dynamic>? ??
                                      {};
                                  final otherId = other['id'] as String? ?? '';
                                  final presence = _presenceMap[otherId];
                                  final isOnline =
                                      presence?['is_online'] as bool? ??
                                      (other['is_online'] as bool? ?? false);
                                  return _ChatUnlockedMatchCard(
                                    match: match,
                                    isOnline: isOnline,
                                  );
                                }),
                              ],
                              // ── Empty state ──
                              if (_pendingMatches.isEmpty &&
                                  _scheduledIntros.isEmpty &&
                                  _chatUnlockedMatches.isEmpty)
                                _EmptyState(
                                  onStartDiscovering:
                                      widget.onNavigateToDiscover,
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: GoogleFonts.dmSans(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            Text(
              subtitle,
              style: GoogleFonts.dmSans(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PendingMatchCard extends StatefulWidget {
  final Map<String, dynamic> match;
  final VoidCallback onStartSession;
  final VoidCallback onScheduleSession;
  final bool isOnline;

  const _PendingMatchCard({
    required this.match,
    required this.onStartSession,
    required this.onScheduleSession,
    this.isOnline = false,
  });

  @override
  State<_PendingMatchCard> createState() => _PendingMatchCardState();
}

class _PendingMatchCardState extends State<_PendingMatchCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  late Animation<double> _borderOpacity;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _borderOpacity = Tween<double>(
      begin: 0.25,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final other = widget.match['other_user'] as Map<String, dynamic>? ?? {};
    final name = other['first_name'] as String? ?? 'Someone';
    final age = other['age'] as int? ?? 0;
    final city = other['city'] as String? ?? '';
    final thumbnailUrl = other['thumbnail_url'] as String?;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AnimatedBuilder(
        animation: _borderOpacity,
        builder: (_, child) => ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Color.fromRGBO(255, 68, 88, _borderOpacity.value),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Color.fromRGBO(
                      255,
                      68,
                      88,
                      _borderOpacity.value * 0.25,
                    ),
                    blurRadius: 16,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // Profile thumbnail avatar
                    Stack(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: const Color(0xFFFF4458),
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: ProfileAvatar(
                              thumbnailUrl: thumbnailUrl,
                              firstName: name,
                              radius: 36,
                            ),
                          ),
                        ),
                        if (widget.isOnline)
                          Positioned(
                            right: 2,
                            bottom: 2,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFF0D0D0F),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    // Info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            age > 0 ? '$name, $age' : name,
                            style: GoogleFonts.dmSans(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (city.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Icon(
                                  Icons.location_on_rounded,
                                  color: AppTheme.textMuted,
                                  size: 12,
                                ),
                                const SizedBox(width: 3),
                                Expanded(
                                  child: Text(
                                    city,
                                    style: GoogleFonts.dmSans(
                                      fontSize: 12,
                                      color: AppTheme.textMuted,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(
                                Icons.bolt_rounded,
                                color: Color(0xFFFF4458),
                                size: 13,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'Mutual Spark!',
                                style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFFFF4458),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Start now or schedule for later',
                            style: GoogleFonts.dmSans(
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                              color: const Color(0xFFFF4458),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      children: [
                        GestureDetector(
                          onTap: widget.onStartSession,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFFF4458), Color(0xFFFF6B7A)],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFFF4458).withAlpha(77),
                                  blurRadius: 12,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Text(
                              'Start now',
                              style: GoogleFonts.dmSans(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.3,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: widget.onScheduleSession,
                          child: Text(
                            'Schedule',
                            style: GoogleFonts.dmSans(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
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
    );
  }
}

class _ScheduledIntroCard extends StatelessWidget {
  final Map<String, dynamic> schedule;
  final VoidCallback onStartSession;
  final VoidCallback onRefresh;
  final bool isOnline;

  const _ScheduledIntroCard({
    required this.schedule,
    required this.onStartSession,
    required this.onRefresh,
    this.isOnline = false,
  });

  @override
  Widget build(BuildContext context) {
    final other = schedule['other_user'] as Map<String, dynamic>? ?? {};
    final name = other['first_name'] as String? ?? 'Someone';
    final age = other['age'] as int? ?? 0;
    final city = other['city'] as String? ?? '';
    final thumbnailUrl = other['thumbnail_url'] as String?;
    final status = schedule['status'] as String? ?? 'proposed';
    final match = schedule['match'] as Map<String, dynamic>? ?? {};
    final matchStatus = match['status']?.toString().trim().toLowerCase() ?? '';
    final sparkType = SupabaseService.sparkTypeLabel(
      schedule['spark_type'] as String?,
    );
    final currentUserId = SupabaseService.instance.currentUserId;
    final proposerId = schedule['proposer_user_id'] as String?;
    final recipientId = schedule['recipient_user_id'] as String?;
    final isRecipient = recipientId == currentUserId;
    final proposedTimes = _proposedTimes(schedule);
    final acceptedTime = _acceptedTime(schedule);
    final canJoin = acceptedTime != null && _canJoin(acceptedTime);
    final isCompleted =
        status == 'completed' ||
        matchStatus == 'chat_unlocked' ||
        matchStatus == 'session_ended' ||
        schedule['completed_at'] != null;
    final primaryTime =
        acceptedTime ?? (proposedTimes.isNotEmpty ? proposedTimes.first : null);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0x1AFFFFFF),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0x333AD29F), width: 1.5),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Stack(
                        children: [
                          ProfileAvatar(
                            thumbnailUrl: thumbnailUrl,
                            firstName: name,
                            radius: 32,
                            borderColor: AppTheme.sparkGreen,
                          ),
                          if (isOnline)
                            Positioned(
                              right: 2,
                              bottom: 2,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF4CAF50),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: const Color(0xFF0D0D0F),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              age > 0 ? '$name, $age' : name,
                              style: GoogleFonts.dmSans(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (city.isNotEmpty)
                              Text(
                                city,
                                style: GoogleFonts.dmSans(
                                  color: AppTheme.textMuted,
                                  fontSize: 12,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      _StatusPill(status: status),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Icon(
                        Icons.bolt_rounded,
                        color: AppTheme.primary,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          sparkType,
                          style: GoogleFonts.dmSans(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    acceptedTime != null
                        ? 'Scheduled for ${formatSparkScheduleTime(acceptedTime)}'
                        : primaryTime != null
                        ? 'Proposed: ${formatSparkScheduleTime(primaryTime)}'
                        : 'Time not selected yet',
                    style: GoogleFonts.dmSans(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (status != 'accepted' && proposedTimes.length > 1) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${proposedTimes.length} suggested times available',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (isCompleted) ...[
                    Text(
                      'This intro is complete. Your Messages section is ready when chat unlocks.',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.textMuted,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ] else if (status == 'accepted') ...[
                    _ActionButton(
                      label: canJoin
                          ? 'Join 3-minute intro'
                          : 'Join opens near scheduled time',
                      filled: canJoin,
                      onTap: canJoin ? onStartSession : null,
                    ),
                  ] else if (isRecipient && proposedTimes.isNotEmpty) ...[
                    _ActionButton(
                      label: 'Accept time',
                      filled: true,
                      onTap: () async {
                        await SupabaseService.instance
                            .acceptSparkSessionSchedule(
                              scheduleId: schedule['id'] as String,
                              notifyUserId: proposerId ?? '',
                              acceptedTime: proposedTimes.first,
                            );
                        onRefresh();
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label: 'Suggest another',
                            onTap: () async {
                              final changed = await showSparkScheduleSheet(
                                context,
                                matchId: schedule['match_id'] as String,
                                recipientUserId: proposerId ?? '',
                                recipientName: name,
                                schedule: schedule,
                              );
                              if (changed) onRefresh();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionButton(
                            label: 'Start now',
                            onTap: onStartSession,
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            label: 'Start now',
                            filled: true,
                            onTap: onStartSession,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionButton(
                            label: 'Cancel',
                            onTap: () async {
                              await SupabaseService.instance
                                  .cancelSparkSessionSchedule(
                                    scheduleId: schedule['id'] as String,
                                  );
                              onRefresh();
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static List<DateTime> _proposedTimes(Map<String, dynamic> schedule) {
    final raw = schedule['proposed_times'];
    if (raw is! List) return [];
    return raw
        .map((value) => DateTime.tryParse(value.toString())?.toLocal())
        .whereType<DateTime>()
        .toList()
      ..sort();
  }

  static DateTime? _acceptedTime(Map<String, dynamic> schedule) {
    final raw = schedule['accepted_time']?.toString();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  static bool _canJoin(DateTime acceptedTime) {
    final now = DateTime.now();
    return now.isAfter(acceptedTime.subtract(const Duration(minutes: 15))) &&
        now.isBefore(acceptedTime.add(const Duration(minutes: 45)));
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      'accepted' => 'Accepted',
      'countered' => 'New times',
      _ => 'Proposed',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.sparkGreen.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.dmSans(
          color: AppTheme.sparkGreen,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool filled;

  const _ActionButton({required this.label, this.onTap, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: filled
                ? AppTheme.primary
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(12),
            border: filled
                ? null
                : Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatUnlockedMatchCard extends StatelessWidget {
  final Map<String, dynamic> match;
  final bool isOnline;

  const _ChatUnlockedMatchCard({required this.match, this.isOnline = false});

  @override
  Widget build(BuildContext context) {
    final other = match['other_user'] as Map<String, dynamic>? ?? {};
    final name = other['first_name'] as String? ?? 'Someone';
    final age = other['age'] as int? ?? 0;
    final thumbnailUrl = other['thumbnail_url'] as String?;
    final matchId = match['id'] as String? ?? '';
    final lastMessage =
        match['last_message'] as String? ?? 'Chat is unlocked — say hello!';
    final lastMessageTime = match['last_message_time'] as String? ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () {
          mainShellKey.currentState?.openChat(matchId, other);
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x14FFFFFF),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x1AFFFFFF), width: 1),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Stack(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppTheme.sparkGreen.withAlpha(120),
                              width: 1.5,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: ProfileAvatar(
                              thumbnailUrl: thumbnailUrl,
                              firstName: name,
                              radius: 28,
                            ),
                          ),
                        ),
                        if (isOnline)
                          Positioned(
                            right: 1,
                            bottom: 1,
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4CAF50),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFF0D0D0F),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            age > 0 ? '$name, $age' : name,
                            style: GoogleFonts.dmSans(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            lastMessage,
                            style: GoogleFonts.dmSans(
                              fontSize: 12,
                              color: AppTheme.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (lastMessageTime.isNotEmpty)
                          Text(
                            lastMessageTime,
                            style: GoogleFonts.dmSans(
                              fontSize: 11,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        const SizedBox(height: 4),
                        const Icon(
                          Icons.chevron_right_rounded,
                          color: AppTheme.textMuted,
                          size: 18,
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
    );
  }
}

class _VideoThumbnail extends StatefulWidget {
  final String videoUrl;

  const _VideoThumbnail({required this.videoUrl});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  VideoPlayerController? _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await ctrl.initialize();
      if (mounted) {
        ctrl.setLooping(true);
        ctrl.setVolume(0);
        ctrl.play();
        setState(() {
          _controller = ctrl;
          _initialized = true;
        });
      } else {
        ctrl.dispose();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_initialized && _controller != null) {
      return AspectRatio(
        aspectRatio: _controller!.value.aspectRatio,
        child: VideoPlayer(_controller!),
      );
    }
    return Container(color: const Color(0xFF1A1A2E));
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback? onStartDiscovering;

  const _EmptyState({this.onStartDiscovering});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(
        child: Column(
          children: [
            const Icon(
              Icons.bolt_outlined,
              color: AppTheme.textMuted,
              size: 64,
            ),
            const SizedBox(height: 16),
            Text(
              'No Sparks yet',
              style: GoogleFonts.dmSans(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start swiping to find your Spark',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AppTheme.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: onStartDiscovering,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF4458), Color(0xFFFF6B7A)],
                  ),
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFF4458).withAlpha(77),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Text(
                  'Start Discovering',
                  style: GoogleFonts.dmSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
