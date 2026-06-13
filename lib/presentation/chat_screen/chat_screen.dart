import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import './widgets/chat_inbox_widget.dart';
import './widgets/chat_thread_widget.dart';

class ChatScreen extends StatefulWidget {
  final String? initialMatchId;
  final Map<String, dynamic>? initialOtherUser;

  const ChatScreen({super.key, this.initialMatchId, this.initialOtherUser});

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  Map<String, dynamic>? _activeConversation;
  bool get _isThreadOpen => _activeConversation != null;

  List<Map<String, dynamic>> _conversationMaps = [];
  bool _isLoading = true;

  RealtimeChannel? _matchesChannel;

  @override
  void initState() {
    super.initState();
    _loadConversations();
    _subscribeToMatchChanges();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Handle navigation arguments — open a specific conversation if provided
    // First check constructor params (when embedded in shell)
    final matchId = widget.initialMatchId;
    final otherUser = widget.initialOtherUser;
    if (matchId != null && matchId.isNotEmpty && _activeConversation == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openConversationById(matchId, otherUser);
      });
      return;
    }
    // Fallback: check route arguments (legacy direct navigation)
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic> && args.containsKey('matchId')) {
      final routeMatchId = args['matchId'] as String?;
      final routeOtherUser = args['otherUser'] as Map<String, dynamic>?;
      if (routeMatchId != null &&
          routeMatchId.isNotEmpty &&
          _activeConversation == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _openConversationById(routeMatchId, routeOtherUser);
        });
      }
    }
  }

  @override
  void dispose() {
    _matchesChannel?.unsubscribe();
    super.dispose();
  }

  void _subscribeToMatchChanges() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;
    _matchesChannel = SupabaseService.instance.client
        .channel('chat_screen_matches:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'matches',
          callback: (_) => _loadConversations(),
        )
        .subscribe();
  }

  Future<void> _loadConversations() async {
    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final matches = await SupabaseService.instance.getChatUnlockedMatches();
      final conversations = <Map<String, dynamic>>[];

      for (final match in matches) {
        final otherId = match['user_1_id'] == uid
            ? match['user_2_id'] as String
            : match['user_1_id'] as String;
        final profile = await SupabaseService.instance.getUserProfile(otherId);
        if (profile == null) continue;

        // Fetch last message
        String lastMessage = 'Chat is unlocked — say hello!';
        String lastMessageTime = '';
        int unreadCount = 0;
        try {
          final msgs = await SupabaseService.instance.client
              .from('messages')
              .select('content, created_at, sender_id, is_read')
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
          // Count unread messages from other user
          final unread = await SupabaseService.instance.client
              .from('messages')
              .select('id')
              .eq('match_id', match['id'] as String)
              .eq('sender_id', otherId)
              .eq('is_read', false);
          unreadCount = (unread as List).length;
        } catch (_) {}

        conversations.add({
          'id': match['id'],
          'matchId': match['id'],
          'user': {
            'id': otherId,
            'name': profile['first_name'] ?? 'Someone',
            'age': profile['age'] ?? 0,
            'city': profile['city'] ?? '',
            'imageUrl': profile['profile_video_url'],
            'thumbnailUrl': profile['thumbnail_url'],
            'semanticLabel':
                'Profile photo of ${profile['first_name'] ?? 'your match'}',
            'isOnline': false,
          },
          'lastMessage': lastMessage,
          'lastMessageTime': lastMessageTime,
          'unreadCount': unreadCount,
          'sessionDate': '',
        });
      }

      if (mounted) {
        setState(() {
          _conversationMaps = conversations;
          _isLoading = false;
        });

        // Re-open active conversation if it was set via args
        if (_activeConversation != null) {
          final matchId = _activeConversation!['matchId'] as String?;
          if (matchId != null) {
            final updated = conversations
                .where((c) => c['matchId'] == matchId)
                .firstOrNull;
            if (updated != null && mounted) {
              setState(() => _activeConversation = updated);
            }
          }
        }

        // If a notification opened the screen before conversations loaded,
        // open that conversation now that data is available.
        if (_pendingOpenMatchId != null) {
          final pending = _pendingOpenMatchId!;
          _pendingOpenMatchId = null;
          final found = conversations
              .where((c) => c['matchId'] == pending)
              .firstOrNull;
          if (found != null) {
            setState(() => _activeConversation = found);
          } else {
            _fetchAndOpenConversation(pending);
          }
        }
      }
    } catch (e) {
      debugPrint('CHAT SCREEN: error loading conversations — $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _openConversationById(String matchId, Map<String, dynamic>? otherUser) {
    // Try to find in loaded conversations first
    final existing = _conversationMaps
        .where((c) => c['matchId'] == matchId)
        .firstOrNull;
    if (existing != null) {
      setState(() => _activeConversation = existing);
      return;
    }
    // Build a minimal conversation map from the passed otherUser
    if (otherUser != null) {
      setState(() {
        _activeConversation = {
          'id': matchId,
          'matchId': matchId,
          'user': {
            'id': otherUser['id'] ?? '',
            'name': otherUser['first_name'] ?? 'Someone',
            'age': otherUser['age'] ?? 0,
            'city': otherUser['city'] ?? '',
            'imageUrl': otherUser['profile_video_url'],
            'thumbnailUrl': otherUser['thumbnail_url'],
            'semanticLabel':
                'Profile photo of ${otherUser['first_name'] ?? 'your match'}',
            'isOnline': false,
          },
          'lastMessage': '',
          'lastMessageTime': '',
          'unreadCount': 0,
          'sessionDate': '',
        };
      });
      return;
    }
    // Conversations not yet loaded and no otherUser provided — wait for load
    // then retry. This handles the case where the screen is opened from a
    // notification before _loadConversations() has completed.
    if (_isLoading) {
      _pendingOpenMatchId = matchId;
    } else {
      // Conversations finished loading but match not found — fetch profile and open
      _fetchAndOpenConversation(matchId);
    }
  }

  // Stores a matchId to open once conversations finish loading
  String? _pendingOpenMatchId;

  /// Fetch the other user's profile from Supabase and open the conversation.
  Future<void> _fetchAndOpenConversation(String matchId) async {
    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid == null) return;
      // Look up the match to find the other user's ID
      final match = await SupabaseService.instance.client
          .from('matches')
          .select('user_1_id, user_2_id')
          .eq('id', matchId)
          .maybeSingle();
      if (match == null) return;
      final otherId = match['user_1_id'] == uid
          ? match['user_2_id'] as String
          : match['user_1_id'] as String;
      final profile = await SupabaseService.instance.getUserProfile(otherId);
      if (!SupabaseService.instance.isUserFacingProfileAvailable(profile)) {
        return;
      }
      if (!mounted) return;
      setState(() {
        _activeConversation = {
          'id': matchId,
          'matchId': matchId,
          'user': {
            'id': otherId,
            'name': profile?['first_name'] ?? 'Someone',
            'age': profile?['age'] ?? 0,
            'city': profile?['city'] ?? '',
            'imageUrl': profile?['profile_video_url'],
            'thumbnailUrl': profile?['thumbnail_url'],
            'semanticLabel':
                'Profile photo of ${profile?['first_name'] ?? 'your match'}',
            'isOnline': false,
          },
          'lastMessage': '',
          'lastMessageTime': '',
          'unreadCount': 0,
          'sessionDate': '',
        };
      });
    } catch (e) {
      debugPrint('CHAT SCREEN: error fetching conversation for $matchId — $e');
    }
  }

  void _openConversation(Map<String, dynamic> conversation) {
    setState(() => _activeConversation = conversation);
  }

  void _closeConversation() {
    setState(() => _activeConversation = null);
    _loadConversations(); // Refresh to update unread counts
  }

  void _handleConversationBlocked() {
    final blockedMatchId = _activeConversation?['matchId'] as String?;
    setState(() {
      _activeConversation = null;
      if (blockedMatchId != null) {
        _conversationMaps.removeWhere((c) => c['matchId'] == blockedMatchId);
      }
    });
    _loadConversations();
  }

  /// Public method so MainShellScreen can open a specific conversation
  void openConversation(String matchId, Map<String, dynamic>? otherUser) {
    _openConversationById(matchId, otherUser);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width >= 600;

    return PopScope(
      canPop: true,
      onPopInvoked: (didPop) {
        if (!didPop && _isThreadOpen) {
          _closeConversation();
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.backgroundDark,
        resizeToAvoidBottomInset: true,
        body: isTablet ? _buildTabletLayout() : _buildPhoneLayout(),
      ),
    );
  }

  Widget _buildPhoneLayout() {
    if (_isThreadOpen && _activeConversation != null) {
      return ChatThreadWidget(
        conversation: _activeConversation!,
        onBack: _closeConversation,
        onConversationBlocked: _handleConversationBlocked,
      );
    }
    if (_isLoading) {
      return Column(
        children: [
          _buildTopBar(),
          const Expanded(
            child: Center(
              child: CircularProgressIndicator(color: Color(0xFFFF4458)),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _buildTopBar(),
        Expanded(
          child: ChatInboxWidget(
            conversations: _conversationMaps,
            onConversationTap: _openConversation,
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return ClipRect(
      child: Container(
        color: const Color(0xCC0D0D0F),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(
              children: [
                Text(
                  'Chats',
                  style: GoogleFonts.dmSans(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabletLayout() {
    return Row(
      children: [
        SizedBox(
          width: 320,
          child: _isLoading
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFFFF4458)),
                )
              : ChatInboxWidget(
                  conversations: _conversationMaps,
                  onConversationTap: _openConversation,
                  selectedId: _activeConversation?['id'],
                ),
        ),
        const VerticalDivider(width: 1, color: AppTheme.borderGlass),
        Expanded(
          child: _activeConversation != null
              ? ChatThreadWidget(
                  conversation: _activeConversation!,
                  onBack: null,
                  onConversationBlocked: _handleConversationBlocked,
                )
              : _buildEmptyChatState(),
        ),
      ],
    );
  }

  Widget _buildEmptyChatState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.chat_bubble_outline_rounded,
            color: AppTheme.textMuted,
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            'Select a conversation',
            style: GoogleFonts.dmSans(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
