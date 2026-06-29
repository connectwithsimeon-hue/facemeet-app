import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../routes/app_routes.dart';
import '../../services/daily_service.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import '../../services/daily_call_web.dart'
    if (dart.library.io) '../../services/daily_call_io.dart';

class CreateLiveTopicScreen extends StatefulWidget {
  final String cohostUserId;
  final String cohostName;

  const CreateLiveTopicScreen({
    super.key,
    required this.cohostUserId,
    required this.cohostName,
  });

  @override
  State<CreateLiveTopicScreen> createState() => _CreateLiveTopicScreenState();
}

class _CreateLiveTopicScreenState extends State<CreateLiveTopicScreen> {
  static const String _visibility = 'link_only';

  List<Map<String, dynamic>> _curatedTopics = const [];
  Map<String, dynamic>? _selectedTopic;
  bool _isLoadingTopics = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _loadCuratedTopics();
  }

  Future<void> _loadCuratedTopics() async {
    try {
      final topics = await SupabaseService.instance
          .listActiveCuratedLiveTopics();
      if (!mounted) return;
      setState(() {
        _curatedTopics = topics;
        _selectedTopic = topics.isEmpty ? null : topics.first;
        _isLoadingTopics = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _isLoadingTopics = false);
        _showSnack(error.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _create() async {
    final selectedTopicId = _selectedTopic?['id']?.toString();
    if (selectedTopicId == null || selectedTopicId.isEmpty) {
      _showSnack('Choose a curated topic to continue.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final liveTopic = await SupabaseService.instance
          .createLiveTopicFromCuratedTopic(
            cohostUserId: widget.cohostUserId,
            curatedTopicId: selectedTopicId,
            visibility: _visibility,
          );
      unawaited(_sendCohostInvitePush(liveTopic));
      if (!mounted) return;
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.liveTopicDetailScreen,
        arguments: {'liveTopic': liveTopic},
      );
    } catch (error) {
      _showSnack(_friendlyError(error));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _sendCohostInvitePush(Map<String, dynamic> liveTopic) async {
    try {
      final creatorProfile = await SupabaseService.instance
          .getCurrentUserProfile();
      final creatorName =
          creatorProfile?['first_name']?.toString().trim().isNotEmpty == true
          ? creatorProfile!['first_name'].toString().trim()
          : 'Someone';
      final title = liveTopic['title']?.toString().trim();
      final slug = liveTopic['public_slug']?.toString().trim();
      final id = liveTopic['id']?.toString().trim();
      await SupabaseService.instance.sendPushNotification(
        userId: widget.cohostUserId,
        type: 'live_topic_invite',
        title: '$creatorName invited you to co-host a Live Topic',
        body: title != null && title.isNotEmpty
            ? '"$title"'
            : 'Tap to accept or decline.',
        data: {
          if (id != null && id.isNotEmpty) 'live_topic_id': id,
          if (slug != null && slug.isNotEmpty) 'live_topic_slug': slug,
          if (title != null && title.isNotEmpty) 'topic_title': title,
          if (SupabaseService.instance.currentUserId != null)
            'creator_user_id': SupabaseService.instance.currentUserId,
          'cohost_user_id': widget.cohostUserId,
          if (slug != null && slug.isNotEmpty)
            'url':
                'https://app.facemeet.app/?push_type=live_topic_invite&live_topic_slug=$slug',
        },
      );
    } catch (error) {
      debugPrint('LIVE TOPIC PUSH: invite send skipped — $error');
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('not_enough_sparks')) {
      return 'You need 1 Spark to start a Live Topic.';
    }
    if (message.contains('connection_required')) {
      return 'Live Topics can start from an unlocked connection.';
    }
    if (message.contains('curated_topic_not_available')) {
      return 'That curated topic is no longer available. Choose another one.';
    }
    return message;
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.primary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomPadding =
        mediaQuery.viewPadding.bottom + mediaQuery.viewInsets.bottom + 132;
    final canCreate =
        !_isSubmitting && !_isLoadingTopics && _selectedTopic != null;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Start Live Topic',
          style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(20, 20, 20, bottomPadding),
          children: [
            _IntroCard(cohostName: widget.cohostName),
            const SizedBox(height: 20),
            Text(
              'Trending Today',
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 12),
            if (_isLoadingTopics)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: CircularProgressIndicator(color: AppTheme.primary),
                ),
              )
            else if (_curatedTopics.isEmpty)
              const _NoCuratedTopicsCard()
            else
              for (final topic in _curatedTopics) ...[
                _CuratedTopicCard(
                  topic: topic,
                  selected: _selectedTopic?['id'] == topic['id'],
                  onSelected: () => setState(() => _selectedTopic = topic),
                ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 18),
            if (_selectedTopic != null)
              _SelectedTopicSummary(
                topic: _selectedTopic!,
                cohostName: widget.cohostName,
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          decoration: BoxDecoration(
            color: AppTheme.backgroundDark.withAlpha(242),
            border: const Border(top: BorderSide(color: AppTheme.borderGlass)),
          ),
          child: ElevatedButton.icon(
            onPressed: canCreate ? _create : null,
            icon: _isSubmitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.group_add_rounded),
            label: Text(
              _isSubmitting
                  ? 'Creating...'
                  : _selectedTopic == null
                  ? 'Select a topic'
                  : 'Invite Co-host',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: AppTheme.surfaceGlass,
              disabledForegroundColor: AppTheme.textMuted,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              textStyle: GoogleFonts.dmSans(
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LiveTopicDetailScreen extends StatefulWidget {
  final Map<String, dynamic>? initialLiveTopic;
  final String? slug;
  final String? liveTopicId;

  const LiveTopicDetailScreen({
    super.key,
    this.initialLiveTopic,
    this.slug,
    this.liveTopicId,
  });

  @override
  State<LiveTopicDetailScreen> createState() => _LiveTopicDetailScreenState();
}

class _LiveTopicDetailScreenState extends State<LiveTopicDetailScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _liveTopic;
  List<Map<String, dynamic>> _joinRequests = const [];
  Timer? _timer;
  Timer? _statusRefreshTimer;
  final GlobalKey<DailyCallViewState> _dailyCallKey =
      GlobalKey<DailyCallViewState>();
  bool _isBusy = false;
  bool _isLoading = true;
  bool _isLoadingDailyAccess = false;
  String? _dailyRoomUrl;
  String? _dailyMeetingToken;
  String? _dailyAccessError;
  bool _isAutoEnding = false;
  bool _wakeLockEnabled = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isLoadingAudienceAccess = false;
  bool _isStartingHls = false;
  Map<String, dynamic>? _audienceAccess;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _liveTopic = widget.initialLiveTopic;
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_maybeAutoEndExpiredRoom());
    });
    _statusRefreshTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final status = _liveTopic?['status']?.toString();
      if (_shouldRefreshStatus(status)) {
        unawaited(_load(silent: true));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _statusRefreshTimer?.cancel();
    unawaited(_setLiveTopicWakeLock(false));
    unawaited(_leaveDailyCall());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_load(silent: true));
    }
  }

  bool _shouldRefreshStatus(String? status) {
    return status == 'pending_cohost_acceptance' ||
        status == 'ready' ||
        status == 'live';
  }

  Future<void> _load({bool silent = false}) async {
    try {
      Map<String, dynamic>? topic = _liveTopic;
      final slug = widget.slug?.trim().isNotEmpty == true
          ? widget.slug!.trim()
          : _liveTopic?['public_slug']?.toString().trim();
      if (slug != null && slug.isNotEmpty) {
        topic = await SupabaseService.instance.getLiveTopicBySlug(slug);
      } else {
        final liveTopicId = widget.liveTopicId?.trim();
        if (liveTopicId != null && liveTopicId.isNotEmpty) {
          topic = await SupabaseService.instance.getLiveTopicById(liveTopicId);
        }
      }
      if (topic != null) {
        final requests = await SupabaseService.instance
            .listLiveTopicJoinRequests(topic['id']?.toString() ?? '');
        if (mounted) {
          setState(() {
            _liveTopic = topic;
            _joinRequests = requests;
            _isLoading = false;
          });
          await _syncDailyForTopic(topic);
        }
      } else if (mounted) {
        if (!silent) setState(() => _isLoading = false);
      }
    } catch (error) {
      debugPrint('LIVE TOPIC: status refresh failed — $error');
      if (mounted && !silent) setState(() => _isLoading = false);
    }
  }

  bool get _isHostOrCohost {
    final uid = SupabaseService.instance.currentUserId;
    return uid != null &&
        (_liveTopic?['creator_user_id'] == uid ||
            _liveTopic?['cohost_user_id'] == uid);
  }

  bool get _canUseDailyStage {
    if (_isHostOrCohost) return true;
    final stageStatus =
        _liveTopic?['viewer_stage_status']?.toString() ??
        _audienceAccess?['viewer_stage_status']?.toString();
    return stageStatus == 'joined';
  }

  bool get _isApprovedUnpaidSpeaker {
    if (_isHostOrCohost) return false;
    final requestStatus = _liveTopic?['viewer_request_status']?.toString();
    final stageStatus = _liveTopic?['viewer_stage_status']?.toString();
    return requestStatus == 'approved' && stageStatus != 'joined';
  }

  bool get _hasPendingStageRequest {
    return _liveTopic?['viewer_request_status']?.toString() == 'pending';
  }

  bool get _isCohostInvite {
    final uid = SupabaseService.instance.currentUserId;
    return uid != null &&
        _liveTopic?['cohost_user_id'] == uid &&
        _liveTopic?['status'] == 'pending_cohost_acceptance';
  }

  String get _shareUrl =>
      'https://facemeet.app/live/${_liveTopic?['public_slug'] ?? ''}';

  String get _timeRemaining {
    final endsAt = DateTime.tryParse(_liveTopic?['ends_at']?.toString() ?? '');
    if (endsAt == null) return '15:00';
    final remaining = endsAt.difference(DateTime.now());
    if (remaining.isNegative) return '00:00';
    final minutes = remaining.inMinutes
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final seconds = remaining.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _maybeAutoEndExpiredRoom() async {
    if (_isAutoEnding || _isBusy) return;
    final topic = _liveTopic;
    final status = topic?['status']?.toString();
    if (topic == null || status != 'live') return;

    final endsAt = DateTime.tryParse(topic['ends_at']?.toString() ?? '');
    if (endsAt == null || DateTime.now().isBefore(endsAt)) return;

    if (!_isHostOrCohost) {
      await _load(silent: true);
      return;
    }

    final id = topic['id']?.toString();
    if (id == null || id.isEmpty) return;
    _isAutoEnding = true;
    await _endRoom(id, autoEnded: true);
  }

  Future<void> _runAction(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    setState(() => _isBusy = true);
    try {
      final updated = await action();
      if (mounted) {
        setState(() => _liveTopic = updated);
        await _load(silent: true);
      }
    } catch (error) {
      debugPrint('LIVE TOPIC: action failed — $error');
      await _load(silent: true);
      _showSnack(_friendlyLiveTopicError(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _startRoom(String liveTopicId) async {
    setState(() => _isBusy = true);
    try {
      final updated = await SupabaseService.instance.startLiveTopic(
        liveTopicId,
      );
      if (!mounted) return;
      setState(() => _liveTopic = updated);
      await _load(silent: true);
      await _startHlsPlayback(force: true);
    } catch (error) {
      debugPrint('LIVE TOPIC: start failed — $error');
      await _load(silent: true);
      _showSnack(_friendlyLiveTopicError(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _endRoom(String liveTopicId, {bool autoEnded = false}) async {
    setState(() => _isBusy = true);
    try {
      await _stopHlsPlayback();
      final updated = await SupabaseService.instance.endLiveTopic(liveTopicId);
      await _leaveDailyCall();
      if (mounted) {
        setState(() => _liveTopic = updated);
        await _load(silent: true);
        _showSnack('This Live Topic has ended.');
      }
    } catch (error) {
      debugPrint('LIVE TOPIC: end failed — $error');
      await _load(silent: true);
      if (_isAlreadyClosedError(error)) {
        await _leaveDailyCall();
        _showSnack('This Live Topic has already ended.');
      } else {
        _showSnack(_friendlyLiveTopicError(error));
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
      if (!autoEnded) _isAutoEnding = false;
    }
  }

  Future<void> _syncDailyForTopic(Map<String, dynamic> topic) async {
    final status = topic['status']?.toString();
    if (status == 'ended' || status == 'cancelled' || status == 'declined') {
      await _leaveDailyCall();
      if (mounted) {
        setState(() {
          _dailyRoomUrl = null;
          _dailyMeetingToken = null;
          _dailyAccessError = null;
          _isLoadingDailyAccess = false;
        });
      }
      return;
    }

    if (status == 'live' && !_isHostOrCohost) {
      await _loadAudienceAccess(pay: false, silent: true);
    }

    if (kIsWeb || !_canUseDailyStage || status != 'live') {
      await _setLiveTopicWakeLock(false);
      return;
    }

    await _setLiveTopicWakeLock(true);

    if ((_dailyRoomUrl?.isNotEmpty ?? false) &&
        (_dailyMeetingToken?.isNotEmpty ?? false)) {
      return;
    }

    await _loadDailyAccess();
  }

  Future<void> _loadDailyAccess({bool force = false}) async {
    final id = _liveTopic?['id']?.toString();
    if (id == null || id.isEmpty || kIsWeb || !_canUseDailyStage) return;
    if (_isLoadingDailyAccess) return;
    if (!force &&
        (_dailyRoomUrl?.isNotEmpty ?? false) &&
        (_dailyMeetingToken?.isNotEmpty ?? false)) {
      return;
    }

    setState(() {
      _isLoadingDailyAccess = true;
      _dailyAccessError = null;
      if (force) {
        _dailyRoomUrl = null;
        _dailyMeetingToken = null;
      }
    });

    try {
      final access = await DailyService.instance.getLiveTopicDailyAccess(
        liveTopicId: id,
      );
      if (!mounted) return;
      setState(() {
        _dailyRoomUrl = access.roomUrl;
        _dailyMeetingToken = access.meetingToken;
        _dailyAccessError = null;
        _isLoadingDailyAccess = false;
      });
      if (_isHostOrCohost) {
        unawaited(_startHlsPlayback(force: true));
      }
    } catch (error) {
      debugPrint('LIVE TOPIC DAILY: access failed — $error');
      if (!mounted) return;
      setState(() {
        _dailyAccessError = _friendlyDailyAccessError(error);
        _isLoadingDailyAccess = false;
      });
    }
  }

  Future<void> _startHlsPlayback({bool force = false}) async {
    final topic = _liveTopic;
    final id = topic?['id']?.toString() ?? '';
    final status = topic?['status']?.toString();
    final hlsStatus = topic?['hls_status']?.toString();
    if (id.isEmpty ||
        !_isHostOrCohost ||
        status != 'live' ||
        _isStartingHls ||
        hlsStatus == 'live' ||
        (hlsStatus == 'pending' && !force)) {
      return;
    }

    _isStartingHls = true;
    try {
      final result = await DailyService.instance.controlLiveTopicHls(
        liveTopicId: id,
        action: 'start',
      );
      if (!mounted) return;
      setState(() {
        _liveTopic = {
          ...?_liveTopic,
          'hls_status': result.hlsStatus,
          'hls_playback_url': result.hlsPlaybackUrl,
        };
      });
      await _load(silent: true);
      if (!result.playbackUrlAvailable) {
        _showSnack('Live playback is starting...');
      }
    } catch (error) {
      debugPrint('LIVE TOPIC HLS: start failed safely — $error');
      if (mounted) _showSnack('Live playback could not start yet.');
    } finally {
      _isStartingHls = false;
    }
  }

  Future<void> _stopHlsPlayback() async {
    final topic = _liveTopic;
    final id = topic?['id']?.toString() ?? '';
    final status = topic?['status']?.toString();
    final hlsStatus = topic?['hls_status']?.toString();
    if (id.isEmpty ||
        !_isHostOrCohost ||
        status != 'live' ||
        (hlsStatus != 'live' &&
            hlsStatus != 'pending' &&
            hlsStatus != 'failed')) {
      return;
    }

    try {
      final result = await DailyService.instance.controlLiveTopicHls(
        liveTopicId: id,
        action: 'stop',
      );
      if (!mounted) return;
      setState(() {
        _liveTopic = {
          ...?_liveTopic,
          'hls_status': result.hlsStatus,
          'hls_playback_url': result.hlsPlaybackUrl,
        };
      });
    } catch (error) {
      debugPrint('LIVE TOPIC HLS: stop failed safely — $error');
    }
  }

  Future<Map<String, String>?> _refreshDailyAccess() async {
    await _loadDailyAccess(force: true);
    final roomUrl = _dailyRoomUrl?.trim() ?? '';
    final meetingToken = _dailyMeetingToken?.trim() ?? '';
    if (roomUrl.isEmpty || meetingToken.isEmpty) return null;
    return {'roomUrl': roomUrl, 'meetingToken': meetingToken};
  }

  Future<void> _leaveDailyCall() async {
    try {
      await _dailyCallKey.currentState?.leave();
    } catch (error) {
      debugPrint('LIVE TOPIC DAILY: leave failed safely — $error');
    }
    await _setLiveTopicWakeLock(false);
  }

  Future<void> _setLiveTopicWakeLock(bool enabled) async {
    if (_wakeLockEnabled == enabled) return;
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
      _wakeLockEnabled = enabled;
    } catch (error) {
      debugPrint('LIVE TOPIC DAILY: wake lock update skipped — $error');
    }
  }

  Future<void> _toggleLiveTopicMute() async {
    final nextMuted = !_isMuted;
    try {
      final dailyState = _dailyCallKey.currentState;
      if (dailyState == null) throw StateError('Daily call is not ready');
      await dailyState.setMuted(nextMuted);
      if (mounted) setState(() => _isMuted = nextMuted);
    } catch (error) {
      debugPrint('LIVE TOPIC DAILY: mute toggle failed — $error');
      _showSnack('Could not update microphone. Please try again.');
    }
  }

  Future<void> _toggleLiveTopicCamera() async {
    final nextCameraOff = !_isCameraOff;
    try {
      final dailyState = _dailyCallKey.currentState;
      if (dailyState == null) throw StateError('Daily call is not ready');
      await dailyState.setCameraOff(nextCameraOff);
      if (mounted) setState(() => _isCameraOff = nextCameraOff);
    } catch (error) {
      debugPrint('LIVE TOPIC DAILY: camera toggle failed — $error');
      _showSnack('Could not update camera. Please try again.');
    }
  }

  Future<void> _handleDailyCallEnded() async {
    await _setLiveTopicWakeLock(false);
    await _load(silent: true);
  }

  Future<void> _leaveRoom() async {
    final topic = _liveTopic;
    final id = topic?['id']?.toString() ?? '';
    final status = topic?['status']?.toString();
    final uid = SupabaseService.instance.currentUserId;
    final isCreator = uid != null && topic?['creator_user_id'] == uid;
    final shouldEndForEveryone =
        id.isNotEmpty &&
        _isHostOrCohost &&
        (status == 'live' ||
            status == 'ready' ||
            (status == 'pending_cohost_acceptance' && isCreator));

    if (shouldEndForEveryone) {
      await _endRoom(id);
      return;
    }

    await _leaveDailyCall();
    if (mounted) Navigator.pop(context);
  }

  String _friendlyDailyAccessError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('host or co-host')) {
      return 'You can only join this video stage after host approval.';
    }
    if (text.contains('not started')) {
      return 'This Live Topic has not started yet.';
    }
    if (text.contains('ended')) {
      return 'This Live Topic has ended.';
    }
    if (text.contains('no longer available')) {
      return 'This video room is no longer available. Please refresh or start a new Live Topic.';
    }
    return 'Could not connect to the Live Topic video. Please try again.';
  }

  bool _isAlreadyClosedError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('topic_not_open') ||
        text.contains('already_ended') ||
        text.contains('cancelled') ||
        text.contains('declined');
  }

  String _friendlyLiveTopicError(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('topic_not_open')) {
      return 'This Live Topic is no longer open.';
    }
    if (text.contains('stage_full') || text.contains('max_speakers_reached')) {
      return 'This stage is full.';
    }
    if (text.contains('stage_request_not_approved')) {
      return 'The host needs to approve your stage request first.';
    }
    if (text.contains('topic_ended')) {
      return 'This Live Topic has ended.';
    }
    if (text.contains('not_host_or_cohost')) {
      return 'Only a host or co-host can do that.';
    }
    if (text.contains('host_insufficient_sparks')) {
      return 'Your co-host needs 1 Spark to extend this Live Topic.';
    }
    if (text.contains('cohost_insufficient_sparks')) {
      return 'Your co-host needs 1 Spark to extend this Live Topic.';
    }
    if (text.contains('extension_requires_both_sparks')) {
      return 'Both hosts need 1 Spark to extend this Live Topic.';
    }
    if (text.contains('insufficient_sparks') ||
        text.contains('not_enough_sparks')) {
      if (text.contains('cohost')) {
        return 'You need 1 Spark to accept this co-host invite.';
      }
      return 'You need 1 Spark to extend this Live Topic.';
    }
    if (text.contains('cohost_not_accepted')) {
      return 'Your co-host must accept before the room can start.';
    }
    if (text.contains('topic_not_ready')) {
      return 'This Live Topic is not ready yet.';
    }
    if (text.contains('already_ended')) {
      return 'This Live Topic has already ended.';
    }
    return 'Something went wrong. Please refresh and try again.';
  }

  Future<void> _share() async {
    final title = _liveTopic?['title']?.toString() ?? 'this Live Topic';
    final shareHook = _liveTopic?['curated_share_hook']?.toString().trim();
    final status = _liveTopic?['status']?.toString();
    final copy = switch (status) {
      'live' =>
        'I\'m live on FaceMeet talking about: $title\n\n'
            'Join the conversation here:\n$_shareUrl\n\n'
            'FaceMeet is a video-first way to meet people through Sparks and Live Topics.',
      'ended' || 'expired' || 'cancelled' =>
        'This FaceMeet Live Topic has ended, but you can still discover more conversations here:\n$_shareUrl',
      _ =>
        shareHook != null && shareHook.isNotEmpty
            ? '$shareHook\n\nFollow or join when it starts:\n$_shareUrl'
            : 'I\'m starting a FaceMeet Live Topic: $title\n\n'
                  'Follow or join when it starts:\n$_shareUrl',
    };
    await Share.share(copy, subject: 'FaceMeet Live Topic');
  }

  Future<void> _requestToJoin() async {
    final id = _liveTopic?['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() => _isBusy = true);
    try {
      final message = await _askJoinStageMessage();
      if (!mounted) return;
      await SupabaseService.instance.requestToJoinLiveTopic(
        liveTopicId: id,
        message: message,
      );
      _showSnack('Request sent.');
      await _load(silent: true);
    } catch (error) {
      debugPrint('LIVE TOPIC: request to join failed — $error');
      _showSnack(_friendlyLiveTopicError(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<String?> _askJoinStageMessage() async {
    final controller = TextEditingController();
    final result = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset + 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Request to Join Stage',
                  style: GoogleFonts.dmSans(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Share what you want to add to the conversation. This request is free.',
                  style: GoogleFonts.dmSans(
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  maxLines: 3,
                  maxLength: 180,
                  style: GoogleFonts.dmSans(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Optional message',
                    hintStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
                    filled: true,
                    fillColor: AppTheme.surfaceGlass,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: AppTheme.borderGlass),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: AppTheme.borderGlass),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: AppTheme.primary),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _ActionButton(
                  label: 'Send Request',
                  icon: Icons.record_voice_over_rounded,
                  onPressed: () {
                    Navigator.pop(context, controller.text.trim());
                  },
                ),
                const SizedBox(height: 8),
                _SecondaryActionButton(
                  label: 'Cancel',
                  icon: Icons.close_rounded,
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();
    return result;
  }

  Future<void> _loadAudienceAccess({
    required bool pay,
    bool silent = false,
  }) async {
    final id = _liveTopic?['id']?.toString();
    if (id == null || id.isEmpty || _isHostOrCohost) return;
    if (!silent && mounted) setState(() => _isLoadingAudienceAccess = true);
    try {
      final access = await SupabaseService.instance.joinLiveTopicAudience(
        liveTopicId: id,
        pay: pay,
      );
      if (!mounted) return;
      setState(() {
        _audienceAccess = access;
        _isLoadingAudienceAccess = false;
      });
      if (pay && access['access_granted'] == true) {
        _showSnack('You can now watch this Live Topic.');
      }
    } catch (error) {
      debugPrint('LIVE TOPIC: audience access failed — $error');
      if (!mounted) return;
      setState(() => _isLoadingAudienceAccess = false);
      _showSnack(_friendlyLiveTopicError(error));
    }
  }

  Future<void> _joinStage() async {
    final id = _liveTopic?['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() => _isBusy = true);
    try {
      await SupabaseService.instance.joinLiveTopicStage(liveTopicId: id);
      if (mounted) {
        setState(() {
          _audienceAccess = {
            ...?_audienceAccess,
            'viewer_stage_status': 'joined',
          };
        });
      }
      _showSnack('Stage unlocked. Connecting video...');
      await _load(silent: true);
      await _loadDailyAccess(force: true);
    } catch (error) {
      debugPrint('LIVE TOPIC: join stage failed — $error');
      _showSnack(_friendlyLiveTopicError(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _decideRequest(String requestId, bool approve) async {
    setState(() => _isBusy = true);
    try {
      await SupabaseService.instance.decideLiveTopicJoinRequest(
        requestId: requestId,
        approve: approve,
      );
      await _load();
    } catch (error) {
      debugPrint('LIVE TOPIC: join request decision failed — $error');
      _showSnack(_friendlyLiveTopicError(error));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.primary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topic = _liveTopic;
    final status = topic?['status']?.toString() ?? '';
    final isEnded =
        status == 'ended' || status == 'cancelled' || status == 'declined';
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Live Topic',
          style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.primary),
              )
            : topic == null
            ? _EmptyTopicState(onBack: () => Navigator.pop(context))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _LiveRoomCard(topic: topic, timerText: _timeRemaining),
                  const SizedBox(height: 18),
                  if (status == 'live') ...[
                    if (_canUseDailyStage)
                      _LiveTopicVideoStage(
                        isHostOrCohost: _isHostOrCohost,
                        isWeb: kIsWeb,
                        isLoading: _isLoadingDailyAccess,
                        error: _dailyAccessError,
                        roomUrl: _dailyRoomUrl,
                        meetingToken: _dailyMeetingToken,
                        dailyCallKey: _dailyCallKey,
                        onRetry: () => _loadDailyAccess(force: true),
                        onEnded: () => unawaited(_handleDailyCallEnded()),
                        onRefreshDailyAccess: _refreshDailyAccess,
                        isMuted: _isMuted,
                        isCameraOff: _isCameraOff,
                        onToggleMute: _toggleLiveTopicMute,
                        onToggleCamera: _toggleLiveTopicCamera,
                        onLeave: _leaveRoom,
                      )
                    else
                      _LiveTopicAudienceCard(
                        topic: topic,
                        audienceAccess: _audienceAccess,
                        isLoading: _isLoadingAudienceAccess,
                        onPayToWatch: _isBusy
                            ? null
                            : () => _loadAudienceAccess(pay: true),
                      ),
                    const SizedBox(height: 18),
                  ],
                  _InfoCard(
                    title: topic['title']?.toString() ?? 'Live Topic',
                    body:
                        topic['curated_prompt']?.toString() ??
                        topic['description']?.toString() ??
                        topic['topic']?.toString() ??
                        '',
                    category:
                        topic['curated_category']?.toString() ??
                        topic['topic']?.toString(),
                    description: topic['description']?.toString(),
                    status: topic['status']?.toString() ?? 'pending',
                  ),
                  const SizedBox(height: 14),
                  if (isEnded) ...[
                    _EndedTopicCard(
                      title: topic['title']?.toString() ?? 'this Live Topic',
                      onBack: () => Navigator.pop(context),
                    ),
                    const SizedBox(height: 18),
                  ] else ...[
                    _ShareCard(url: _shareUrl, onShare: _share),
                    const SizedBox(height: 18),
                  ],
                  if (!isEnded && _isCohostInvite) ...[
                    _CohostInviteNoticeCard(
                      creatorName:
                          (topic['host_profile'] is Map
                                  ? topic['host_profile']['first_name']
                                  : null)
                              ?.toString() ??
                          'Your connection',
                      title: topic['title']?.toString() ?? 'this Live Topic',
                    ),
                    const SizedBox(height: 14),
                  ] else if (!isEnded &&
                      topic['status'] == 'pending_cohost_acceptance') ...[
                    _WaitingForCohostCard(
                      cohostName:
                          (topic['cohost_profile'] is Map
                                  ? topic['cohost_profile']['first_name']
                                  : null)
                              ?.toString() ??
                          'Your co-host',
                      title: topic['title']?.toString() ?? 'this Live Topic',
                      onRefresh: _isBusy ? null : () => _load(silent: false),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (!isEnded && _isCohostInvite) _buildInviteActions(),
                  if (!isEnded && _isHostOrCohost) _buildHostActions(topic),
                  if (!isEnded &&
                      !_isHostOrCohost &&
                      topic['status'] == 'live') ...[
                    if (_isApprovedUnpaidSpeaker)
                      _ActionButton(
                        label: 'Join Stage for 1 Spark',
                        icon: Icons.video_call_rounded,
                        onPressed: _isBusy ? null : _joinStage,
                      )
                    else if (_hasPendingStageRequest)
                      const _VideoPlaceholderCard(
                        icon: Icons.hourglass_top_rounded,
                        title: 'Request sent',
                        body:
                            'The host or co-host can approve your request to join the stage.',
                      )
                    else
                      _ActionButton(
                        label: 'Request to Join Stage',
                        icon: Icons.record_voice_over_rounded,
                        onPressed: _isBusy ? null : _requestToJoin,
                      ),
                  ],
                  if (!isEnded &&
                      _isHostOrCohost &&
                      _joinRequests.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _JoinRequestList(
                      requests: _joinRequests,
                      onApprove: (id) => _decideRequest(id, true),
                      onReject: (id) => _decideRequest(id, false),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _leaveRoom,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Leave Room'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                    ),
                  ),
                  if (!isEnded)
                    TextButton.icon(
                      onPressed: () => _showSnack('Report flow coming next.'),
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Report Live Topic'),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.textMuted,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildInviteActions() {
    final id = _liveTopic?['id']?.toString() ?? '';
    return Column(
      children: [
        _ActionButton(
          label: 'Accept as co-host for 1 Spark',
          icon: Icons.check_circle_rounded,
          onPressed: _isBusy
              ? null
              : () => _runAction(
                  () => SupabaseService.instance.respondLiveTopicCohostInvite(
                    liveTopicId: id,
                    accept: true,
                  ),
                ),
        ),
        const SizedBox(height: 10),
        _SecondaryActionButton(
          label: 'Decline',
          icon: Icons.cancel_outlined,
          onPressed: _isBusy
              ? null
              : () => _runAction(
                  () => SupabaseService.instance.respondLiveTopicCohostInvite(
                    liveTopicId: id,
                    accept: false,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildHostActions(Map<String, dynamic> topic) {
    final id = topic['id']?.toString() ?? '';
    final status = topic['status']?.toString() ?? '';
    return Column(
      children: [
        if (status == 'ready')
          _ActionButton(
            label: 'Start 15-minute Room',
            icon: Icons.play_arrow_rounded,
            onPressed: _isBusy ? null : () => _startRoom(id),
          ),
        if (status == 'live') ...[
          _ActionButton(
            label: 'Extend 15 min - 1 Spark each',
            icon: Icons.bolt_rounded,
            onPressed: _isBusy
                ? null
                : () => _runAction(
                    () => SupabaseService.instance.extendLiveTopic(
                      id,
                      extensionKey:
                          '${DateTime.now().microsecondsSinceEpoch}-$id',
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          _SecondaryActionButton(
            label: 'End Room',
            icon: Icons.stop_circle_outlined,
            onPressed: _isBusy ? null : () => _endRoom(id),
          ),
        ],
        if (status == 'pending_cohost_acceptance')
          _SecondaryActionButton(
            label: 'Refresh status',
            icon: Icons.refresh_rounded,
            onPressed: _isBusy ? null : () => _load(silent: false),
          ),
      ],
    );
  }
}

class _IntroCard extends StatelessWidget {
  final String cohostName;

  const _IntroCard({required this.cohostName});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.forum_rounded, color: AppTheme.primary, size: 30),
          const SizedBox(height: 12),
          Text(
            'Choose a curated topic to discuss with $cohostName.',
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Live Topics are 15-minute link-shareable conversations between connected people. Choose a FaceMeet topic, invite your co-host, then go live after they accept.',
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _CuratedTopicCard extends StatelessWidget {
  final Map<String, dynamic> topic;
  final bool selected;
  final VoidCallback onSelected;

  const _CuratedTopicCard({
    required this.topic,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final category = topic['category']?.toString() ?? 'Live Topic';
    final title = topic['title']?.toString() ?? '';
    final prompt = topic['prompt']?.toString() ?? '';
    final featured = topic['featured'] == true;
    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(22),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.16)
              : AppTheme.surfaceGlass,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.borderGlass,
            width: selected ? 1.4 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppTheme.primary.withValues(alpha: 0.16),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _MiniPill(label: category, icon: Icons.auto_awesome_rounded),
                if (featured)
                  const _MiniPill(
                    label: 'Featured',
                    icon: Icons.local_fire_department_rounded,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
                height: 1.12,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              prompt,
              style: GoogleFonts.dmSans(
                color: AppTheme.textSecondary,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? AppTheme.primary : AppTheme.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  selected ? 'Selected topic' : 'Start with this topic',
                  style: GoogleFonts.dmSans(
                    color: selected ? AppTheme.primary : AppTheme.textSecondary,
                    fontWeight: FontWeight.w800,
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

class _SelectedTopicSummary extends StatelessWidget {
  final Map<String, dynamic> topic;
  final String cohostName;

  const _SelectedTopicSummary({required this.topic, required this.cohostName});

  @override
  Widget build(BuildContext context) {
    final title = topic['title']?.toString() ?? 'Selected topic';
    final prompt = topic['prompt']?.toString() ?? '';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Selected Topic',
            style: GoogleFonts.dmSans(
              color: AppTheme.primary,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (prompt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              prompt,
              style: GoogleFonts.dmSans(
                color: AppTheme.textSecondary,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 14),
          _SummaryLine(
            icon: Icons.person_rounded,
            label: 'Co-host: $cohostName',
          ),
          const SizedBox(height: 8),
          const _SummaryLine(icon: Icons.bolt_rounded, label: 'Costs 1 Spark'),
          const SizedBox(height: 8),
          const _SummaryLine(
            icon: Icons.timer_rounded,
            label: 'Opens a 15-minute Live Topic room',
          ),
          const SizedBox(height: 8),
          const _SummaryLine(
            icon: Icons.link_rounded,
            label: 'Visibility: Link-only',
          ),
        ],
      ),
    );
  }
}

class _NoCuratedTopicsCard extends StatelessWidget {
  const _NoCuratedTopicsCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        children: [
          const Icon(Icons.forum_outlined, color: AppTheme.textMuted, size: 36),
          const SizedBox(height: 12),
          Text(
            'No Live Topics available right now.',
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Check back later for new curated topics.',
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SummaryLine({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.primary, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String label;
  final IconData icon;

  const _MiniPill({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.primary, size: 14),
          const SizedBox(width: 5),
          Text(
            label,
            style: GoogleFonts.dmSans(
              color: AppTheme.primary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveRoomCard extends StatelessWidget {
  final Map<String, dynamic> topic;
  final String timerText;

  const _LiveRoomCard({required this.topic, required this.timerText});

  @override
  Widget build(BuildContext context) {
    final status = topic['status']?.toString() ?? '';
    final isLive = status == 'live';
    final isPending = status == 'pending_cohost_acceptance';
    final isReady = status == 'ready';
    final isEnded =
        status == 'ended' || status == 'cancelled' || status == 'declined';
    final title = isPending
        ? 'Waiting for Co-host'
        : isReady
        ? 'Ready to Start'
        : isEnded
        ? 'Live Topic Ended'
        : 'Live Topic Room';
    final subtitle = isLive
        ? 'Time remaining $timerText'
        : isReady
        ? 'Start when you and your co-host are ready.'
        : isPending
        ? 'Your co-host needs to accept before the room opens.'
        : isEnded
        ? 'This conversation has ended.'
        : 'Video stage coming next';
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2A1115), Color(0xFF111113)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        children: [
          Icon(
            isLive ? Icons.live_tv_rounded : Icons.video_camera_front_rounded,
            color: AppTheme.primary,
            size: 44,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndedTopicCard extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _EndedTopicCard({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.check_circle_outline_rounded,
                  color: AppTheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'This Live Topic has ended.',
                      style: GoogleFonts.dmSans(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '"$title" is no longer active. You can return to chat whenever you are ready.',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SecondaryActionButton(
            label: 'Return to Chat',
            icon: Icons.arrow_back_rounded,
            onPressed: onBack,
          ),
        ],
      ),
    );
  }
}

class _CohostInviteNoticeCard extends StatelessWidget {
  final String creatorName;
  final String title;

  const _CohostInviteNoticeCard({
    required this.creatorName,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.32)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.group_add_rounded, color: AppTheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Live Topic Invite',
                  style: GoogleFonts.dmSans(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '$creatorName invited you to co-host "$title". Accept for 1 Spark when you are ready to help open the room.',
                  style: GoogleFonts.dmSans(
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WaitingForCohostCard extends StatelessWidget {
  final String cohostName;
  final String title;
  final VoidCallback? onRefresh;

  const _WaitingForCohostCard({
    required this.cohostName,
    required this.title,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.hourglass_top_rounded, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Waiting for $cohostName',
                      style: GoogleFonts.dmSans(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'The room for "$title" will be ready after your co-host accepts. No timer starts yet.',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.textSecondary,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _SecondaryActionButton(
            label: 'Refresh status',
            icon: Icons.refresh_rounded,
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _LiveTopicVideoStage extends StatelessWidget {
  final bool isHostOrCohost;
  final bool isWeb;
  final bool isLoading;
  final String? error;
  final String? roomUrl;
  final String? meetingToken;
  final GlobalKey<DailyCallViewState> dailyCallKey;
  final VoidCallback onRetry;
  final VoidCallback onEnded;
  final Future<Map<String, String>?> Function() onRefreshDailyAccess;
  final bool isMuted;
  final bool isCameraOff;
  final Future<void> Function() onToggleMute;
  final Future<void> Function() onToggleCamera;
  final Future<void> Function() onLeave;

  const _LiveTopicVideoStage({
    required this.isHostOrCohost,
    required this.isWeb,
    required this.isLoading,
    required this.error,
    required this.roomUrl,
    required this.meetingToken,
    required this.dailyCallKey,
    required this.onRetry,
    required this.onEnded,
    required this.onRefreshDailyAccess,
    required this.isMuted,
    required this.isCameraOff,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onLeave,
  });

  @override
  Widget build(BuildContext context) {
    if (!isHostOrCohost) {
      return const _VideoPlaceholderCard(
        icon: Icons.visibility_rounded,
        title: 'This Live Topic is live',
        body:
            'Viewer mode is coming next. Hosts and co-hosts are on video now.',
      );
    }

    if (isWeb) {
      return const _VideoPlaceholderCard(
        icon: Icons.desktop_windows_rounded,
        title: 'Live Topic video is ready on mobile',
        body:
            'Host and co-host video is available in the iOS and Android app. PWA video support is coming next.',
      );
    }

    if (isLoading) {
      return const _VideoPlaceholderCard(
        icon: Icons.videocam_rounded,
        title: 'Connecting video...',
        body: 'Preparing your secure Live Topic room.',
        showSpinner: true,
      );
    }

    if (error != null && error!.trim().isNotEmpty) {
      return _VideoPlaceholderCard(
        icon: Icons.error_outline_rounded,
        title: 'Could not connect',
        body: error!,
        actionLabel: 'Try again',
        onAction: onRetry,
      );
    }

    final safeRoomUrl = roomUrl?.trim() ?? '';
    final safeMeetingToken = meetingToken?.trim() ?? '';
    if (safeRoomUrl.isEmpty || safeMeetingToken.isEmpty) {
      return _VideoPlaceholderCard(
        icon: Icons.videocam_off_rounded,
        title: 'Video room not ready',
        body: 'Refresh to prepare your secure Live Topic video room.',
        actionLabel: 'Refresh',
        onAction: onRetry,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 430,
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: AppTheme.borderGlass),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DailyCallView(
              key: dailyCallKey,
              roomUrl: safeRoomUrl,
              meetingToken: safeMeetingToken,
              onCallEnded: onEnded,
              onCallError: (_) {},
              onRefreshDailyAccess: onRefreshDailyAccess,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x99000000),
                    Colors.transparent,
                    Colors.transparent,
                    Color(0xCC000000),
                  ],
                  stops: [0, 0.2, 0.62, 1],
                ),
              ),
            ),
            Positioned(
              left: 18,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(138),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Colors.white.withAlpha(31)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppTheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Live Topic',
                      style: GoogleFonts.dmSans(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 18,
              child: SafeArea(
                top: false,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _LiveTopicCallControlButton(
                      icon: isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                      label: isMuted ? 'Unmute' : 'Mute',
                      active: isMuted,
                      onTap: onToggleMute,
                    ),
                    _LiveTopicCallControlButton(
                      icon: Icons.call_end_rounded,
                      label: 'Leave',
                      destructive: true,
                      emphasized: true,
                      onTap: onLeave,
                    ),
                    _LiveTopicCallControlButton(
                      icon: isCameraOff
                          ? Icons.videocam_off_rounded
                          : Icons.videocam_rounded,
                      label: isCameraOff ? 'Camera On' : 'Camera Off',
                      active: isCameraOff,
                      onTap: onToggleCamera,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveTopicCallControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Future<void> Function() onTap;
  final bool active;
  final bool destructive;
  final bool emphasized;

  const _LiveTopicCallControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.destructive = false,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final background = destructive
        ? AppTheme.error
        : active
        ? AppTheme.primary
        : Colors.black.withAlpha(166);
    final size = emphasized ? 62.0 : 54.0;

    return InkWell(
      onTap: () => unawaited(onTap()),
      borderRadius: BorderRadius.circular(999),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: background,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withAlpha(35)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(77),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: emphasized ? 30 : 25),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveTopicAudienceCard extends StatelessWidget {
  final Map<String, dynamic> topic;
  final Map<String, dynamic>? audienceAccess;
  final bool isLoading;
  final VoidCallback? onPayToWatch;

  const _LiveTopicAudienceCard({
    required this.topic,
    required this.audienceAccess,
    required this.isLoading,
    required this.onPayToWatch,
  });

  @override
  Widget build(BuildContext context) {
    final status = topic['status']?.toString() ?? '';
    final hlsUrl =
        audienceAccess?['hls_playback_url']?.toString().trim().isNotEmpty ==
            true
        ? audienceAccess!['hls_playback_url'].toString().trim()
        : topic['hls_playback_url']?.toString().trim() ?? '';
    final hlsStatus =
        audienceAccess?['hls_status']?.toString() ??
        topic['hls_status']?.toString() ??
        'not_started';
    final hlsLastErrorCode =
        audienceAccess?['hls_last_error_code']?.toString().trim() ??
        topic['hls_last_error_code']?.toString().trim() ??
        '';
    final hlsStartWasRequested = {
      'hls_start_received',
      'hls_start_validated',
      'daily_start_in_progress',
      'daily_start_response_received',
    }.contains(hlsLastErrorCode);
    final accessGranted =
        audienceAccess?['access_granted'] == true ||
        topic['viewer_access_type']?.toString().isNotEmpty == true;
    final requiresPayment = audienceAccess?['requires_payment'] == true;
    final freeSeats =
        ((audienceAccess?['free_seats_remaining'] as num?)?.toInt() ??
                (topic['free_seats_remaining'] as num?)?.toInt() ??
                0)
            .clamp(0, 20);

    if (status != 'live') {
      return const _VideoPlaceholderCard(
        icon: Icons.schedule_rounded,
        title: 'Starting soon',
        body: 'This Live Topic will open when the hosts start the room.',
      );
    }

    if (isLoading) {
      return const _VideoPlaceholderCard(
        icon: Icons.visibility_rounded,
        title: 'Preparing access...',
        body: 'Checking your Live Topic watch access.',
        showSpinner: true,
      );
    }

    if (requiresPayment && !accessGranted) {
      return _VideoPlaceholderCard(
        icon: Icons.bolt_rounded,
        title: 'This Live Topic is popular',
        body: 'The free viewer seats are full. Watch/listen for 1 Spark.',
        actionLabel: 'Watch for 1 Spark',
        onAction: onPayToWatch,
      );
    }

    if (!accessGranted) {
      return _VideoPlaceholderCard(
        icon: Icons.visibility_rounded,
        title: freeSeats > 0 ? 'Free viewer seats available' : 'Watch gate',
        body: freeSeats > 0
            ? '$freeSeats free viewer seats remain. Open this Live Topic to claim one.'
            : 'Watch/listen access will be available after the gate opens.',
      );
    }

    if (hlsUrl.isNotEmpty && hlsStatus == 'live') {
      return _HlsPlaybackCard(hlsUrl: hlsUrl);
    }

    if (hlsStatus == 'pending' && hlsStartWasRequested) {
      return const _VideoPlaceholderCard(
        icon: Icons.podcasts_rounded,
        title: 'Live playback is being prepared',
        body:
            'The host and co-host are live. Watch/listen playback will appear here when HLS is available.',
      );
    }

    if (hlsStatus == 'failed') {
      return const _VideoPlaceholderCard(
        icon: Icons.podcasts_rounded,
        title: 'Live playback is not available yet',
        body:
            'The room is live, but watch/listen playback could not start. Please check back shortly.',
      );
    }

    return const _VideoPlaceholderCard(
      icon: Icons.podcasts_rounded,
      title: 'Live playback has not started yet',
      body:
          'The host and co-host are live. Watch/listen playback will appear here after the host starts streaming.',
    );
  }
}

class _HlsPlaybackCard extends StatefulWidget {
  final String hlsUrl;

  const _HlsPlaybackCard({required this.hlsUrl});

  @override
  State<_HlsPlaybackCard> createState() => _HlsPlaybackCardState();
}

class _HlsPlaybackCardState extends State<_HlsPlaybackCard> {
  VideoPlayerController? _controller;
  bool _isInitializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant _HlsPlaybackCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hlsUrl != widget.hlsUrl) {
      _controller?.dispose();
      _controller = null;
      _isInitializing = true;
      _error = null;
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.hlsUrl),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setVolume(1);
      if (!mounted) return;
      setState(() => _isInitializing = false);
    } catch (error) {
      debugPrint('LIVE TOPIC HLS: playback init failed — $error');
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _error = 'Live playback is not available on this device yet.';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_isInitializing) {
      return const _VideoPlaceholderCard(
        icon: Icons.play_circle_rounded,
        title: 'Loading live playback...',
        body: 'Preparing the live conversation stream.',
        showSpinner: true,
      );
    }

    if (_error != null ||
        controller == null ||
        !controller.value.isInitialized) {
      return _VideoPlaceholderCard(
        icon: Icons.live_tv_rounded,
        title: 'Playback unavailable',
        body: _error ?? 'Live playback is not available on this device yet.',
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 360,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio == 0
                    ? 16 / 9
                    : controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: _ActionButton(
                  label: controller.value.isPlaying ? 'Pause' : 'Play Live',
                  icon: controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: () async {
                    if (controller.value.isPlaying) {
                      await controller.pause();
                    } else {
                      await controller.play();
                    }
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoPlaceholderCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool showSpinner;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _VideoPlaceholderCard({
    required this.icon,
    required this.title,
    required this.body,
    this.showSpinner = false,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        children: [
          if (showSpinner)
            const SizedBox(
              width: 34,
              height: 34,
              child: CircularProgressIndicator(color: AppTheme.primary),
            )
          else
            Icon(icon, color: AppTheme.primary, size: 38),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              height: 1.35,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 14),
            _SecondaryActionButton(
              label: actionLabel!,
              icon: Icons.refresh_rounded,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final String body;
  final String? category;
  final String? description;
  final String status;

  const _InfoCard({
    required this.title,
    required this.body,
    required this.category,
    required this.description,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _StatusPill(status: status),
              if (category != null && category!.trim().isNotEmpty)
                _MiniPill(
                  label: category!.trim(),
                  icon: Icons.auto_awesome_rounded,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              fontSize: 16,
            ),
          ),
          if (description != null && description!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              description!,
              style: GoogleFonts.dmSans(
                color: AppTheme.textMuted,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final label = status
        .replaceAll('_', ' ')
        .split(' ')
        .map(
          (word) => word.isEmpty
              ? word
              : '${word[0].toUpperCase()}${word.substring(1)}',
        )
        .join(' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: GoogleFonts.dmSans(
          color: AppTheme.primary,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _ShareCard extends StatelessWidget {
  final String url;
  final VoidCallback onShare;

  const _ShareCard({required this.url, required this.onShare});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Share link',
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.dmSans(color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          _ActionButton(
            label: 'Share this room',
            icon: Icons.ios_share_rounded,
            onPressed: onShare,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: GoogleFonts.dmSans(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _SecondaryActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _SecondaryActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.textSecondary,
        minimumSize: const Size.fromHeight(50),
        side: const BorderSide(color: AppTheme.borderGlass),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: GoogleFonts.dmSans(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class _JoinRequestList extends StatelessWidget {
  final List<Map<String, dynamic>> requests;
  final void Function(String requestId) onApprove;
  final void Function(String requestId) onReject;

  const _JoinRequestList({
    required this.requests,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Join requests',
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 10),
          for (final request in requests)
            if (request['status'] == 'pending')
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Someone requested to join',
                        style: GoogleFonts.dmSans(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => onReject(request['id'].toString()),
                      icon: const Icon(Icons.close_rounded),
                      color: AppTheme.textMuted,
                    ),
                    IconButton(
                      onPressed: () => onApprove(request['id'].toString()),
                      icon: const Icon(Icons.check_rounded),
                      color: AppTheme.sparkGreen,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _EmptyTopicState extends StatelessWidget {
  final VoidCallback onBack;

  const _EmptyTopicState({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.forum_outlined,
              color: AppTheme.textMuted,
              size: 52,
            ),
            const SizedBox(height: 14),
            Text(
              'Live Topic not found',
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 20,
              ),
            ),
            const SizedBox(height: 12),
            _SecondaryActionButton(
              label: 'Back',
              icon: Icons.arrow_back_rounded,
              onPressed: onBack,
            ),
          ],
        ),
      ),
    );
  }
}
