import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/profile_avatar.dart';
import '../../../widgets/user_safety_actions.dart';
import '../../../services/android_diagnostics_service.dart';
import '../../../services/content_filter_service.dart';
import '../../../services/supabase_service.dart';
import '../../../services/web_push_notification_service.dart';
import '../../../services/presence_service.dart';
import '../../../routes/app_routes.dart';
import '../../../providers/subscription_provider.dart';

class ChatThreadWidget extends StatefulWidget {
  final Map<String, dynamic> conversation;
  final VoidCallback? onBack;
  final VoidCallback? onConversationBlocked;

  const ChatThreadWidget({
    super.key,
    required this.conversation,
    this.onBack,
    this.onConversationBlocked,
  });

  @override
  State<ChatThreadWidget> createState() => _ChatThreadWidgetState();
}

class _ChatThreadWidgetState extends State<ChatThreadWidget> {
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  List<Map<String, dynamic>> _messages = [];
  bool _isTyping = false;
  bool _isLoadingMessages = true;
  bool _isSending = false;

  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _sparkRequestChannel;
  RealtimeChannel? _presenceWatchChannel;

  // Live presence state for the other user
  bool _isOtherUserOnline = false;
  String? _otherUserLastSeenAt;

  // Incoming spark request state
  bool _showSparkRequestModal = false;
  String? _incomingSessionId;
  String? _incomingRoomUrl;
  bool _isStartingSession = false;
  String? _lastIncomingSparkSessionId;

  // Pending curated Live Topic invite/waiting state for this connection.
  Map<String, dynamic>? _pendingLiveTopic;
  Timer? _liveTopicInviteTimer;
  bool _isLoadingLiveTopicInvite = false;
  bool _isLiveTopicActionBusy = false;

  String get _matchId =>
      widget.conversation['matchId'] as String? ??
      widget.conversation['id'] as String? ??
      '';
  Map<String, dynamic> get _user =>
      widget.conversation['user'] as Map<String, dynamic>? ?? {};
  String get _otherUserId => _user['id'] as String? ?? '';
  String get _otherName => _user['name'] as String? ?? 'Your Match';

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _subscribeToMessages();
    _subscribeToSparkRequests();
    _checkForActiveSparkRequest();
    _initPresence();
    _loadPendingLiveTopic();
    _liveTopicInviteTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_loadPendingLiveTopic(silent: true));
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _messagesChannel?.unsubscribe();
    _sparkRequestChannel?.unsubscribe();
    _presenceWatchChannel?.unsubscribe();
    _liveTopicInviteTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    if (_matchId.isEmpty) {
      if (mounted) setState(() => _isLoadingMessages = false);
      return;
    }
    try {
      final msgs = await SupabaseService.instance.getMessages(_matchId);
      if (mounted) {
        setState(() {
          _messages = msgs;
          _isLoadingMessages = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
        // Mark messages as read
        await SupabaseService.instance.markMessagesRead(_matchId);
      }
    } catch (e) {
      debugPrint('CHAT THREAD: error loading messages — $e');
      if (mounted) setState(() => _isLoadingMessages = false);
    }
  }

  void _subscribeToMessages() {
    if (_matchId.isEmpty) return;
    _messagesChannel = SupabaseService.instance.subscribeToMessages(
      matchId: _matchId,
      onNewMessage: (message) {
        if (mounted) {
          setState(() => _messages.add(message));
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
          // Mark as read if from other user
          if (message['sender_id'] != SupabaseService.instance.currentUserId) {
            SupabaseService.instance.markMessagesRead(_matchId);
          }
        }
      },
    );
  }

  /// Subscribe to new spark_sessions for this match (incoming spark requests)
  void _subscribeToSparkRequests() {
    if (_matchId.isEmpty) return;
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    _sparkRequestChannel = SupabaseService.instance.subscribeToNewSparkSessions(
      matchId: _matchId,
      onNewSession: (record) {
        unawaited(_handleIncomingSparkSessionRecord(record));
      },
    );
  }

  Future<void> _checkForActiveSparkRequest() async {
    if (_matchId.isEmpty) return;
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    try {
      final record = await SupabaseService.instance.client
          .from('spark_sessions')
          .select(
            'id, initiated_by, status, ended_at, created_at, user_1_ready, user_2_ready, session_key, decision_user_1, decision_user_2, outcome',
          )
          .eq('match_id', _matchId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (record != null) {
        await _handleIncomingSparkSessionRecord(record);
      }
    } catch (e) {
      debugPrint('CHAT THREAD: active spark-session check failed — $e');
    }
  }

  Future<void> _handleIncomingSparkSessionRecord(
    Map<String, dynamic> record,
  ) async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null || !mounted) return;

    final initiatorId = record['initiated_by'] as String?;
    final sessionId = record['id'] as String?;
    final status = (record['status'] as String? ?? '').toLowerCase();
    final endedAt = record['ended_at'] as String?;

    if (initiatorId == null || initiatorId == uid) {
      return;
    }
    if (sessionId == null || sessionId.isEmpty) {
      return;
    }
    if (await _isChatUnlockedMatch()) {
      if (mounted && _showSparkRequestModal) {
        setState(() {
          _showSparkRequestModal = false;
          _incomingSessionId = null;
          _incomingRoomUrl = null;
        });
      }
      await _recordSuppressedSparkPopup(
        reason: 'handled_by_global_repeat_popup',
        status: status,
        endedAtExists: false,
        chatUnlocked: true,
        feedbackComplete: false,
      );
      return;
    }
    if (status == 'ended' || (endedAt != null && endedAt.isNotEmpty)) {
      await _recordSuppressedSparkPopup(
        reason: 'session_ended',
        status: status,
        endedAtExists: endedAt != null && endedAt.isNotEmpty,
        chatUnlocked: false,
        feedbackComplete: false,
      );
      return;
    }

    final outcome = record['outcome'];
    final feedbackComplete =
        record['decision_user_1'] != null && record['decision_user_2'] != null;
    if (outcome != null || feedbackComplete) {
      await _recordSuppressedSparkPopup(
        reason: 'feedback_complete',
        status: status,
        endedAtExists: false,
        chatUnlocked: false,
        feedbackComplete: true,
      );
      return;
    }

    if (record['user_1_ready'] == true && record['user_2_ready'] == true) {
      await _recordSuppressedSparkPopup(
        reason: 'both_users_already_joined',
        status: status,
        endedAtExists: false,
        chatUnlocked: false,
        feedbackComplete: false,
      );
      return;
    }

    final currentUserAlreadyJoined = await _currentUserAlreadyJoinedSession(
      record,
    );
    if (currentUserAlreadyJoined) {
      await _recordSuppressedSparkPopup(
        reason: 'current_user_already_joined',
        status: status,
        endedAtExists: false,
        chatUnlocked: false,
        feedbackComplete: false,
      );
      return;
    }

    final eligibility = await SupabaseService.instance
        .checkSparkSessionEntryEligibility(
          matchId: _matchId,
          sessionId: sessionId,
        );
    if (!eligibility.canEnter) {
      await _recordSuppressedSparkPopup(
        reason: eligibility.reason,
        status: eligibility.sessionStatus ?? status,
        endedAtExists: eligibility.endedAtExists,
        chatUnlocked: eligibility.chatUnlocked,
        feedbackComplete: eligibility.feedbackComplete,
      );
      debugPrint(
        'CHAT THREAD: suppressed Spark Session popup — reason=${eligibility.reason}',
      );
      return;
    }

    if (!mounted) return;
    if (_lastIncomingSparkSessionId == sessionId && _showSparkRequestModal) {
      return;
    }

    final sessionKey = record['session_key'] as String?;
    await AndroidDiagnosticsService.instance.setValues({
      'spark_diag_repeat_popup_seen': 'yes',
      'spark_diag_repeat_popup_source': 'chat_thread_realtime',
      'spark_diag_repeat_popup_match_id_short':
          AndroidDiagnosticsService.shortId(_matchId),
      'spark_diag_repeat_popup_session_key_short':
          AndroidDiagnosticsService.shortId(sessionKey),
      'spark_diag_repeat_popup_suppressed_reason': 'shown',
    });

    debugPrint(
      'CHAT THREAD: incoming Spark Session detected — sessionId=$sessionId initiatedBy=$initiatorId status=$status',
    );
    setState(() {
      _showSparkRequestModal = true;
      _incomingSessionId = sessionId;
      _lastIncomingSparkSessionId = sessionId;
    });
  }

  Future<bool> _currentUserAlreadyJoinedSession(
    Map<String, dynamic> record,
  ) async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null || _matchId.isEmpty) return false;

    try {
      final match = await SupabaseService.instance.client
          .from('matches')
          .select('user_1_id, user_2_id, status')
          .eq('id', _matchId)
          .maybeSingle();
      if (match == null) return false;

      final matchStatus = (match['status'] as String? ?? '').toLowerCase();
      if (matchStatus == 'session_ended') {
        return true;
      }

      if (match['user_1_id'] == uid) {
        return record['user_1_ready'] == true;
      }
      if (match['user_2_id'] == uid) {
        return record['user_2_ready'] == true;
      }
    } catch (e) {
      debugPrint(
        'CHAT THREAD: current-user session readiness check failed — $e',
      );
    }
    return false;
  }

  Future<void> _recordSuppressedSparkPopup({
    required String reason,
    required String status,
    required bool endedAtExists,
    required bool chatUnlocked,
    required bool feedbackComplete,
  }) async {
    await AndroidDiagnosticsService.instance.setValues({
      'suppressed_session_popup_reason': reason,
      'spark_diag_repeat_popup_suppressed_reason': reason,
      'spark_diag_repeat_popup_source': 'chat_thread_realtime',
      'spark_diag_repeat_popup_match_id_short':
          AndroidDiagnosticsService.shortId(_matchId),
      'last_session_status': status.isEmpty ? 'unknown' : status,
      'last_session_ended_at': endedAtExists ? 'yes' : 'no',
      'last_session_chat_unlocked': chatUnlocked ? 'yes' : 'no',
      'last_session_feedback_complete': feedbackComplete ? 'yes' : 'no',
    });
  }

  Future<bool> _isChatUnlockedMatch() async {
    if (_matchId.isEmpty) return false;
    try {
      final match = await SupabaseService.instance.client
          .from('matches')
          .select('status')
          .eq('id', _matchId)
          .maybeSingle();
      return (match?['status'] as String? ?? '').toLowerCase() ==
          'chat_unlocked';
    } catch (e) {
      debugPrint('CHAT THREAD: match status check failed — $e');
      return false;
    }
  }

  void _scrollToBottom() {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _sendMessage() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _isSending || _matchId.isEmpty) return;

    setState(() => _isSending = true);
    _inputCtrl.clear();
    setState(() => _isTyping = false);

    try {
      final sentMessage = await SupabaseService.instance.sendMessage(
        matchId: _matchId,
        content: text,
      );
      // Message will appear via realtime subscription

      // Trigger 2 — notify the recipient about the new message
      try {
        await _sendNewMessagePush(sentMessage);
      } catch (e) {
        debugPrint('MESSAGE PUSH: success/failure=false — $e');
      }
    } catch (e) {
      debugPrint('CHAT THREAD: error sending message — $e');
      if (mounted) {
        final errorText = e.toString().replaceFirst('Exception: ', '');
        final message = errorText == ContentFilterService.violationMessage
            ? ContentFilterService.violationMessage
            : 'Failed to send: $errorText';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: AppTheme.error),
        );
        // Restore text on failure
        _inputCtrl.text = text;
        setState(() => _isTyping = true);
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Start a new Spark Session from chat
  Future<void> _startNewSparkSession() async {
    if (_matchId.isEmpty) return;
    setState(() => _isStartingSession = true);

    try {
      debugPrint('SPARK SESSION: join tapped from chat — matchId=$_matchId');
      await AndroidDiagnosticsService.instance.setValues({
        'spark_diag_repeat_invite_created': 'chat_start_navigate',
        'spark_diag_repeat_invite_target_user_short':
            AndroidDiagnosticsService.shortId(_otherUserId),
        'spark_diag_repeat_popup_match_id_short':
            AndroidDiagnosticsService.shortId(_matchId),
      });
      if (mounted) {
        Navigator.pushNamed(
          context,
          AppRoutes.sparkSessionScreen,
          arguments: {'matchId': _matchId, 'matchedUserId': _otherUserId},
        );
      }
    } catch (e) {
      debugPrint('CHAT THREAD: error starting new Spark Session — $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not start Spark Session: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isStartingSession = false);
    }
  }

  Future<void> _acceptSparkRequest() async {
    setState(() => _showSparkRequestModal = false);
    final eligibility = await SupabaseService.instance
        .checkSparkSessionEntryEligibility(matchId: _matchId);
    if (!eligibility.canEnter) {
      await _recordSuppressedSparkPopup(
        reason: eligibility.reason,
        status: eligibility.sessionStatus ?? 'unknown',
        endedAtExists: eligibility.endedAtExists,
        chatUnlocked: eligibility.chatUnlocked,
        feedbackComplete: eligibility.feedbackComplete,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('That Spark Session is no longer available.'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }
    if (mounted) {
      Navigator.pushNamed(
        context,
        AppRoutes.sparkSessionScreen,
        arguments: {'matchId': _matchId, 'matchedUserId': _otherUserId},
      );
    }
  }

  void _declineSparkRequest() {
    setState(() {
      _showSparkRequestModal = false;
      _incomingSessionId = null;
      _incomingRoomUrl = null;
    });
    // Cancel the session row if possible
    if (_incomingSessionId != null) {
      SupabaseService.instance.client
          .from('spark_sessions')
          .delete()
          .eq('id', _incomingSessionId!)
          .catchError((_) {});
    }
  }

  /// Load initial presence state and subscribe to live updates
  Future<void> _initPresence() async {
    if (_otherUserId.isEmpty) return;
    // Load initial state from DB
    try {
      final profile = await SupabaseService.instance.getUserProfile(
        _otherUserId,
      );
      if (profile != null && mounted) {
        setState(() {
          _isOtherUserOnline = profile['is_online'] as bool? ?? false;
          _otherUserLastSeenAt = profile['last_seen_at'] as String?;
        });
      }
    } catch (_) {}

    // Subscribe to live updates
    _presenceWatchChannel = PresenceService.instance.subscribeToUserPresence(
      userId: _otherUserId,
      onUpdate: (isOnline, lastSeenAt) {
        if (mounted) {
          setState(() {
            _isOtherUserOnline = isOnline;
            _otherUserLastSeenAt = lastSeenAt;
          });
        }
      },
    );
  }

  Future<void> _sendNewMessagePush(Map<String, dynamic>? sentMessage) async {
    try {
      final senderId = SupabaseService.instance.currentUserId;
      final recipientId = _otherUserId;
      debugPrint('MESSAGE PUSH: message sent');
      debugPrint(
        'MESSAGE PUSH: sender present yes/no=${senderId?.isNotEmpty == true}',
      );
      debugPrint(
        'MESSAGE PUSH: recipient present yes/no=${recipientId.isNotEmpty}',
      );

      if (senderId == null ||
          senderId.isEmpty ||
          recipientId.isEmpty ||
          recipientId == senderId) {
        debugPrint('MESSAGE PUSH: send success/failure=false');
        return;
      }

      final currentProfile = await SupabaseService.instance
          .getCurrentUserProfile();
      final senderFirstName = currentProfile?['first_name']?.toString().trim();
      debugPrint(
        'MESSAGE PUSH: sender display name present yes/no=${senderFirstName?.isNotEmpty == true}',
      );

      final title = senderFirstName != null && senderFirstName.isNotEmpty
          ? 'New message from $senderFirstName'
          : 'New message on FaceMeet';
      final sent = await WebPushNotificationService.instance
          .sendWebPushNotification(
            userId: recipientId,
            type: 'new_message',
            title: title,
            body: 'Open FaceMeet to reply.',
            data: {
              'match_id': _matchId,
              'message_id': sentMessage?['id'],
              'type': 'new_message',
            },
          );
      debugPrint('MESSAGE PUSH: send success/failure=$sent');
    } catch (e) {
      debugPrint('MESSAGE PUSH: success/failure=false — $e');
    }
  }

  void _startLiveTopic() {
    if (_otherUserId.isEmpty) return;
    Navigator.pushNamed(
      context,
      AppRoutes.createLiveTopicScreen,
      arguments: {
        'cohostUserId': _otherUserId,
        'cohostName': _otherName,
        'matchId': _matchId,
      },
    );
  }

  Future<void> _loadPendingLiveTopic({bool silent = false}) async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null || _otherUserId.isEmpty) return;
    if (_isLoadingLiveTopicInvite) return;

    if (mounted && !silent) {
      setState(() => _isLoadingLiveTopicInvite = true);
    } else {
      _isLoadingLiveTopicInvite = true;
    }

    try {
      final topics = await SupabaseService.instance.listMyLiveTopics();
      Map<String, dynamic>? pending;
      for (final topic in topics) {
        final status = topic['status']?.toString();
        if (status != 'pending_cohost_acceptance') continue;

        final creatorId = topic['creator_user_id']?.toString();
        final cohostId = topic['cohost_user_id']?.toString();
        final belongsToThisConversation =
            (creatorId == uid && cohostId == _otherUserId) ||
            (creatorId == _otherUserId && cohostId == uid);
        if (belongsToThisConversation) {
          pending = topic;
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        _pendingLiveTopic = pending;
        _isLoadingLiveTopicInvite = false;
      });
    } catch (error) {
      debugPrint('LIVE TOPIC CHAT: pending invite load failed — $error');
      if (mounted) {
        setState(() => _isLoadingLiveTopicInvite = false);
      } else {
        _isLoadingLiveTopicInvite = false;
      }
    }
  }

  bool get _isPendingLiveTopicInvite {
    final uid = SupabaseService.instance.currentUserId;
    final topic = _pendingLiveTopic;
    return uid != null &&
        topic != null &&
        topic['cohost_user_id']?.toString() == uid &&
        topic['creator_user_id']?.toString() == _otherUserId;
  }

  Future<void> _respondToLiveTopicInvite(bool accept) async {
    final id = _pendingLiveTopic?['id']?.toString();
    if (id == null || id.isEmpty) return;

    setState(() => _isLiveTopicActionBusy = true);
    try {
      final updated = await SupabaseService.instance
          .respondLiveTopicCohostInvite(liveTopicId: id, accept: accept);
      if (!mounted) return;
      if (accept) {
        setState(() {
          _pendingLiveTopic = updated['status'] == 'pending_cohost_acceptance'
              ? updated
              : null;
        });
        Navigator.pushNamed(
          context,
          AppRoutes.liveTopicDetailScreen,
          arguments: {'liveTopic': updated},
        );
      } else {
        setState(() => _pendingLiveTopic = null);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Live Topic invite declined.'),
            backgroundColor: AppTheme.primary,
          ),
        );
      }
    } catch (error) {
      debugPrint('LIVE TOPIC CHAT: invite response failed — $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_friendlyLiveTopicInviteError(error)),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLiveTopicActionBusy = false);
    }
  }

  String _friendlyLiveTopicInviteError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('not_enough_sparks') ||
        text.contains('insufficient_sparks')) {
      return 'You need 1 Spark to accept this co-host invite.';
    }
    if (text.contains('invite_not_available')) {
      return 'This Live Topic invite is no longer available.';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  void _viewPendingLiveTopic() {
    final topic = _pendingLiveTopic;
    if (topic == null) return;
    Navigator.pushNamed(
      context,
      AppRoutes.liveTopicDetailScreen,
      arguments: {'liveTopic': topic},
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = _isOtherUserOnline;
    final lastSeenAt = _otherUserLastSeenAt;
    final sparkBalance = context.watch<SubscriptionProvider>().sparkBalance;

    return Stack(
      children: [
        Column(
          children: [
            // AppBar
            ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  color: const Color(0xCC0D0D0F),
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildHeaderIdentityRow(isOnline, lastSeenAt),
                          const SizedBox(height: 10),
                          _buildHeaderActionRow(sparkBalance),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_otherUserId.isNotEmpty) _buildSafetyBar(),
            if (_pendingLiveTopic != null)
              _LiveTopicInviteCard(
                topic: _pendingLiveTopic!,
                otherName: _otherName,
                isInviteForMe: _isPendingLiveTopicInvite,
                isBusy: _isLiveTopicActionBusy,
                onAccept: () => _respondToLiveTopicInvite(true),
                onDecline: () => _respondToLiveTopicInvite(false),
                onView: _viewPendingLiveTopic,
                onRefresh: () => _loadPendingLiveTopic(silent: false),
              ),
            // Messages
            Expanded(
              child: _isLoadingMessages
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFFFF4458),
                      ),
                    )
                  : _messages.isEmpty
                  ? _buildEmptyMessages()
                  : ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      itemCount: _messages.length,
                      itemBuilder: (context, i) {
                        final msg = _messages[i];
                        final isMe =
                            msg['sender_id'] ==
                            SupabaseService.instance.currentUserId;
                        final createdAt = DateTime.tryParse(
                          msg['created_at'] as String? ?? '',
                        );
                        String timeStr = '';
                        if (createdAt != null) {
                          final diff = DateTime.now().difference(createdAt);
                          if (diff.inMinutes < 1) {
                            timeStr = 'now';
                          } else if (diff.inMinutes < 60) {
                            timeStr = '${diff.inMinutes}m ago';
                          } else {
                            timeStr =
                                '${createdAt.hour.toString().padLeft(2, '0')}:${createdAt.minute.toString().padLeft(2, '0')}';
                          }
                        }
                        return _MessageBubble(
                          content: msg['content'] as String? ?? '',
                          time: timeStr,
                          isMe: isMe,
                          isRead: msg['is_read'] as bool? ?? false,
                        );
                      },
                    ),
            ),
            // Input bar
            ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  color: const Color(0xCC0D0D0F),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      10,
                      16,
                      MediaQuery.of(context).padding.bottom + 96,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: TextField(
                                controller: _inputCtrl,
                                style: GoogleFonts.dmSans(
                                  color: Colors.white,
                                  fontSize: 15,
                                ),
                                onChanged: (v) =>
                                    setState(() => _isTyping = v.isNotEmpty),
                                decoration: InputDecoration(
                                  hintText: 'Say something...',
                                  hintStyle: GoogleFonts.dmSans(
                                    color: AppTheme.textHint,
                                    fontSize: 15,
                                  ),
                                  filled: true,
                                  fillColor: AppTheme.surfaceGlass,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: const BorderSide(
                                      color: AppTheme.borderGlass,
                                      width: 1,
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: const BorderSide(
                                      color: AppTheme.borderGlass,
                                      width: 1,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(24),
                                    borderSide: const BorderSide(
                                      color: AppTheme.primary,
                                      width: 1.5,
                                    ),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 12,
                                  ),
                                ),
                                onSubmitted: (_) => _sendMessage(),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _sendMessage,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              gradient: _isTyping
                                  ? const LinearGradient(
                                      colors: [
                                        Color(0xFFFF4458),
                                        Color(0xFFFF6B7A),
                                      ],
                                    )
                                  : null,
                              color: _isTyping ? null : AppTheme.surfaceGlass,
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: _isTyping
                                  ? [
                                      BoxShadow(
                                        color: AppTheme.primary.withAlpha(102),
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Icon(
                              Icons.send_rounded,
                              color: _isTyping
                                  ? Colors.white
                                  : AppTheme.textMuted,
                              size: 20,
                            ),
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
        // Incoming Spark Request Modal
        if (_showSparkRequestModal)
          _SparkRequestModal(
            otherName: _otherName,
            onAccept: _acceptSparkRequest,
            onDecline: _declineSparkRequest,
          ),
      ],
    );
  }

  Widget _buildHeaderIdentityRow(bool isOnline, String? lastSeenAt) {
    return Row(
      children: [
        const SizedBox(width: 8),
        Stack(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.primary, width: 1.5),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(19),
                child: ProfileAvatar(
                  thumbnailUrl: _user['thumbnailUrl'] as String?,
                  firstName: _otherName,
                  radius: 19,
                ),
              ),
            ),
            if (isOnline)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: AppTheme.sparkGreen,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppTheme.backgroundDark,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _otherName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: GoogleFonts.dmSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              Text(
                isOnline
                    ? 'Online now'
                    : PresenceService.formatLastSeen(lastSeenAt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  color: isOnline
                      ? const Color(0xFF4CAF50)
                      : AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeaderActionRow(int sparkBalance) {
    if (_isStartingSession) {
      return const Padding(
        padding: EdgeInsets.only(left: 8),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                color: AppTheme.primary,
                strokeWidth: 2,
              ),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: Row(
          children: [
            _buildSparkBalancePill(sparkBalance),
            const SizedBox(width: 8),
            _buildHeaderPillButton(
              label: 'Live',
              icon: Icons.forum_rounded,
              onTap: _startLiveTopic,
              isPrimary: false,
            ),
            const SizedBox(width: 8),
            _buildHeaderPillButton(
              label: 'Spark',
              icon: Icons.videocam_rounded,
              onTap: _startNewSparkSession,
              isPrimary: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSparkBalancePill(int sparkBalance) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderGlass),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Available',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: 5),
              const Icon(Icons.bolt_rounded, color: AppTheme.primary, size: 14),
              const SizedBox(width: 4),
              Text(
                '$sparkBalance',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeaderPillButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    required bool isPrimary,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isPrimary ? AppTheme.primary : AppTheme.surfaceGlass,
          borderRadius: BorderRadius.circular(20),
          border: isPrimary ? null : Border.all(color: AppTheme.borderGlass),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isPrimary ? Colors.white : AppTheme.primary,
              size: 17,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMessages() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primary.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chat_bubble_rounded,
                color: AppTheme.primary,
                size: 36,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'You have a Spark with $_otherName',
              style: GoogleFonts.dmSans(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Say hi and plan your next Spark Session',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AppTheme.textSecondary,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSafetyBar() {
    return Container(
      color: const Color(0xCC0D0D0F),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: UserSafetyActionButtons(
        reportedUserId: _otherUserId,
        reportedUserName: _otherName,
        source: 'chat',
        matchId: _matchId.isEmpty ? null : _matchId,
        onBlocked: () {
          if (widget.onConversationBlocked != null) {
            widget.onConversationBlocked!.call();
          } else {
            widget.onBack?.call();
          }
        },
      ),
    );
  }
}

class _LiveTopicInviteCard extends StatelessWidget {
  final Map<String, dynamic> topic;
  final String otherName;
  final bool isInviteForMe;
  final bool isBusy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onView;
  final VoidCallback onRefresh;

  const _LiveTopicInviteCard({
    required this.topic,
    required this.otherName,
    required this.isInviteForMe,
    required this.isBusy,
    required this.onAccept,
    required this.onDecline,
    required this.onView,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final title = topic['title']?.toString().trim();
    final topicTitle = title == null || title.isEmpty
        ? 'this Live Topic'
        : title;
    final headline = isInviteForMe
        ? 'Live Topic Invite'
        : 'Waiting for $otherName';
    final body = isInviteForMe
        ? '$otherName invited you to co-host "$topicTitle". Accept for 1 Spark when you are ready to help open the room.'
        : '$otherName needs to accept "$topicTitle" before the Live Topic room is ready.';

    return Container(
      color: const Color(0xCC0D0D0F),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surfaceGlass,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.34)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.primary.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.forum_rounded,
                    color: AppTheme.primary,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.dmSans(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        body,
                        style: GoogleFonts.dmSans(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isInviteForMe)
              Row(
                children: [
                  Expanded(
                    child: _LiveTopicCardButton(
                      label: 'Decline',
                      icon: Icons.close_rounded,
                      onTap: isBusy ? null : onDecline,
                      isPrimary: false,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _LiveTopicCardButton(
                      label: 'Accept for 1 Spark',
                      icon: Icons.check_rounded,
                      onTap: isBusy ? null : onAccept,
                      isPrimary: true,
                    ),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: _LiveTopicCardButton(
                      label: 'Refresh',
                      icon: Icons.refresh_rounded,
                      onTap: isBusy ? null : onRefresh,
                      isPrimary: false,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _LiveTopicCardButton(
                      label: 'View',
                      icon: Icons.open_in_new_rounded,
                      onTap: isBusy ? null : onView,
                      isPrimary: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _LiveTopicCardButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool isPrimary;

  const _LiveTopicCardButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.isPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            color: isPrimary ? AppTheme.primary : AppTheme.surfaceGlassVariant,
            borderRadius: BorderRadius.circular(14),
            border: isPrimary ? null : Border.all(color: AppTheme.borderGlass),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isPrimary ? Colors.white : AppTheme.textSecondary,
                size: 17,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.dmSans(
                  color: isPrimary ? Colors.white : AppTheme.textSecondary,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SparkRequestModal extends StatelessWidget {
  final String otherName;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _SparkRequestModal({
    required this.otherName,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black54,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: const Color(0xE60D0D0F),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: AppTheme.primary.withAlpha(80),
                    width: 1,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withAlpha(30),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.videocam_rounded,
                        color: AppTheme.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '$otherName wants to start another Spark Session',
                      style: GoogleFonts.dmSans(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.3,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'You\'ll enter the waiting room and connect when both of you are ready.',
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
                            onTap: onDecline,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                color: AppTheme.surfaceGlass,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: AppTheme.borderGlass,
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                'Decline',
                                style: GoogleFonts.dmSans(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textSecondary,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: onAccept,
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFFF4458),
                                    Color(0xFFFF6B7A),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.primary.withAlpha(77),
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Text(
                                'Accept',
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
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final String time;
  final bool isMe;
  final bool isRead;

  const _MessageBubble({
    required this.content,
    required this.time,
    required this.isMe,
    required this.isRead,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.65,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: isMe
                        ? const LinearGradient(
                            colors: [Color(0xFFFF4458), Color(0xFFFF6B7A)],
                          )
                        : null,
                    color: isMe ? null : AppTheme.surfaceGlassVariant,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isMe ? 18 : 4),
                      bottomRight: Radius.circular(isMe ? 4 : 18),
                    ),
                    border: isMe
                        ? null
                        : Border.all(color: AppTheme.borderGlass, width: 1),
                  ),
                  child: Text(
                    content,
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      time,
                      style: GoogleFonts.dmSans(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 4),
                      Icon(
                        isRead ? Icons.done_all_rounded : Icons.done_rounded,
                        size: 12,
                        color: isRead ? AppTheme.primary : AppTheme.textMuted,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (isMe) const SizedBox(width: 8),
        ],
      ),
    );
  }
}
