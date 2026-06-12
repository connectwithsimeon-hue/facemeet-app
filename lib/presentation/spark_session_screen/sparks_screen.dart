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
  List<Map<String, dynamic>> _chatUnlockedMatches = [];

  RealtimeChannel? _matchesChannel;
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
    if (_pendingMatches.isEmpty && _chatUnlockedMatches.isEmpty) {
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) await _loadMatches();
    }

    // Attach realtime listener only after the initial fetch is done
    if (mounted) _subscribeToMatchChanges();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _matchesChannel?.unsubscribe();
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

  Future<void> _loadMatches() async {
    setState(() => _isLoading = true);
    try {
      final pending = await SupabaseService.instance.getPendingMatches();
      final chatUnlocked = await SupabaseService.instance
          .getChatUnlockedMatches();

      // Enrich each match with the other user's profile
      final uid = SupabaseService.instance.currentUserId;

      // Bug 1 fix: filter out any chat_unlocked matches from pending list
      // (safety net in case status update was delayed or partially applied)
      final filteredPending = pending
          .where((m) => m['status'] != 'chat_unlocked')
          .toList();

      final enrichedPending = await _enrichMatches(filteredPending, uid);
      final enrichedChat = await _enrichMatches(chatUnlocked, uid);

      if (mounted) {
        setState(() {
          _pendingMatches = enrichedPending;
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

  /// Subscribe to realtime presence updates for all matched users
  void _subscribeToPresence() {
    _presenceChannel?.unsubscribe();
    final uid = SupabaseService.instance.currentUserId;

    // Collect all matched user IDs
    final matchedIds = <String>{};
    for (final m in [..._pendingMatches, ..._chatUnlockedMatches]) {
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
  final bool isOnline;

  const _PendingMatchCard({
    required this.match,
    required this.onStartSession,
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
                          // "Waiting for you" label
                          GestureDetector(
                            onTap: widget.onStartSession,
                            child: Text(
                              'Waiting for you — tap to join',
                              style: GoogleFonts.dmSans(
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                color: const Color(0xFFFF4458),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Start button
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
                          'Start Spark\nSession',
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

class _ChatUnlockedMatchCard extends StatelessWidget {
  final Map<String, dynamic> match;
  final bool isOnline;

  const _ChatUnlockedMatchCard({required this.match, this.isOnline = false});

  @override
  Widget build(BuildContext context) {
    final other = match['other_user'] as Map<String, dynamic>? ?? {};
    final name = other['first_name'] as String? ?? 'Someone';
    final age = other['age'] as int? ?? 0;
    final city = other['city'] as String? ?? '';
    final thumbnailUrl = other['thumbnail_url'] as String?;
    final matchId = match['id'] as String? ?? '';
    final otherId = other['id'] as String? ?? '';
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
