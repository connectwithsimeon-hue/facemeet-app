import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';

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
  final _titleCtrl = TextEditingController();
  final _topicCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  String _visibility = 'link_only';
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _topicCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _titleCtrl.text.trim();
    final topic = _topicCtrl.text.trim();
    if (title.length < 3 || topic.length < 3) {
      _showSnack('Add a title and topic to continue.');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final liveTopic = await SupabaseService.instance
          .createLiveTopicFromConnection(
            cohostUserId: widget.cohostUserId,
            title: title,
            topic: topic,
            description: _descriptionCtrl.text.trim().isEmpty
                ? null
                : _descriptionCtrl.text.trim(),
            visibility: _visibility,
          );
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

  String _friendlyError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('not_enough_sparks')) {
      return 'You need 1 Spark to start a Live Topic.';
    }
    if (message.contains('connection_required')) {
      return 'Live Topics can start from an unlocked connection.';
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
        mediaQuery.viewPadding.bottom + mediaQuery.viewInsets.bottom + 32;

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
            _Field(
              controller: _titleCtrl,
              label: 'Title',
              hint: 'What is this Live Topic called?',
            ),
            const SizedBox(height: 14),
            _Field(
              controller: _topicCtrl,
              label: 'Topic',
              hint: 'What will you talk about?',
            ),
            const SizedBox(height: 14),
            _Field(
              controller: _descriptionCtrl,
              label: 'Description',
              hint: 'Optional context for viewers',
              maxLines: 4,
            ),
            const SizedBox(height: 18),
            Text(
              'Visibility',
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _VisibilityChip(
                  label: 'Link-only',
                  value: 'link_only',
                  selected: _visibility == 'link_only',
                  onSelected: () => setState(() => _visibility = 'link_only'),
                ),
                _VisibilityChip(
                  label: 'Public',
                  value: 'public',
                  selected: _visibility == 'public',
                  onSelected: () => setState(() => _visibility = 'public'),
                ),
                _VisibilityChip(
                  label: 'Invite-only',
                  value: 'invite_only',
                  selected: _visibility == 'invite_only',
                  onSelected: () => setState(() => _visibility = 'invite_only'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.surfaceGlass,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderGlass),
              ),
              child: Row(
                children: [
                  const Icon(Icons.bolt_rounded, color: AppTheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Costs 1 Spark. Opens a 15-minute Live Topic room.',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _isSubmitting ? null : _create,
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
              label: Text(_isSubmitting ? 'Creating...' : 'Invite Co-host'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
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
          ],
        ),
      ),
    );
  }
}

class LiveTopicDetailScreen extends StatefulWidget {
  final Map<String, dynamic>? initialLiveTopic;
  final String? slug;

  const LiveTopicDetailScreen({super.key, this.initialLiveTopic, this.slug});

  @override
  State<LiveTopicDetailScreen> createState() => _LiveTopicDetailScreenState();
}

class _LiveTopicDetailScreenState extends State<LiveTopicDetailScreen> {
  Map<String, dynamic>? _liveTopic;
  List<Map<String, dynamic>> _joinRequests = const [];
  Timer? _timer;
  bool _isBusy = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _liveTopic = widget.initialLiveTopic;
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      Map<String, dynamic>? topic = _liveTopic;
      if (topic == null && widget.slug != null) {
        topic = await SupabaseService.instance.getLiveTopicBySlug(widget.slug!);
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
        }
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  bool get _isHostOrCohost {
    final uid = SupabaseService.instance.currentUserId;
    return uid != null &&
        (_liveTopic?['creator_user_id'] == uid ||
            _liveTopic?['cohost_user_id'] == uid);
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

  Future<void> _runAction(
    Future<Map<String, dynamic>> Function() action,
  ) async {
    setState(() => _isBusy = true);
    try {
      final updated = await action();
      if (mounted) {
        setState(() => _liveTopic = updated);
        await _load();
      }
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _share() async {
    final title = _liveTopic?['title']?.toString() ?? 'this Live Topic';
    final isLive = _liveTopic?['status'] == 'live';
    final copy = isLive
        ? "I'm live on FaceMeet discussing $title.\nWatch, ask a question, or request to join:\n$_shareUrl"
        : "I'm starting a FaceMeet Live Topic about $title.\nJoin when we go live:\n$_shareUrl";
    await Share.share(copy, subject: 'FaceMeet Live Topic');
  }

  Future<void> _requestToJoin() async {
    final id = _liveTopic?['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() => _isBusy = true);
    try {
      await SupabaseService.instance.requestToJoinLiveTopic(liveTopicId: id);
      _showSnack('Request sent.');
    } catch (error) {
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
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
      _showSnack(error.toString().replaceFirst('Exception: ', ''));
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
                  _InfoCard(
                    title: topic['title']?.toString() ?? 'Live Topic',
                    body: topic['topic']?.toString() ?? '',
                    description: topic['description']?.toString(),
                    status: topic['status']?.toString() ?? 'pending',
                  ),
                  const SizedBox(height: 14),
                  _ShareCard(url: _shareUrl, onShare: _share),
                  const SizedBox(height: 18),
                  if (_isCohostInvite) _buildInviteActions(),
                  if (_isHostOrCohost) _buildHostActions(topic),
                  if (!_isHostOrCohost && topic['status'] == 'live')
                    _ActionButton(
                      label: 'Request to Join',
                      icon: Icons.record_voice_over_rounded,
                      onPressed: _isBusy ? null : _requestToJoin,
                    ),
                  if (_isHostOrCohost && _joinRequests.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _JoinRequestList(
                      requests: _joinRequests,
                      onApprove: (id) => _decideRequest(id, true),
                      onReject: (id) => _decideRequest(id, false),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Leave Room'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                    ),
                  ),
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
          label: 'Accept Co-host Invite',
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
            onPressed: _isBusy
                ? null
                : () => _runAction(
                    () => SupabaseService.instance.startLiveTopic(id),
                  ),
          ),
        if (status == 'live') ...[
          _ActionButton(
            label: 'Extend 15 min for 1 Spark',
            icon: Icons.bolt_rounded,
            onPressed: _isBusy
                ? null
                : () => _runAction(
                    () => SupabaseService.instance.extendLiveTopic(id),
                  ),
          ),
          const SizedBox(height: 10),
          _SecondaryActionButton(
            label: 'End Room',
            icon: Icons.stop_circle_outlined,
            onPressed: _isBusy
                ? null
                : () => _runAction(
                    () => SupabaseService.instance.endLiveTopic(id),
                  ),
          ),
        ],
        if (status == 'pending_cohost_acceptance')
          Text(
            'Waiting for your co-host to accept.',
            style: GoogleFonts.dmSans(color: AppTheme.textMuted),
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
            'Create a focused conversation with $cohostName.',
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Live Topics are 15-minute link-shareable conversations between connected people. Your co-host must accept before it can go live.',
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

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;

  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: GoogleFonts.dmSans(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: GoogleFonts.dmSans(color: AppTheme.textSecondary),
        hintStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
        filled: true,
        fillColor: AppTheme.surfaceGlass,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppTheme.borderGlass),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
        ),
      ),
    );
  }
}

class _VisibilityChip extends StatelessWidget {
  final String label;
  final String value;
  final bool selected;
  final VoidCallback onSelected;

  const _VisibilityChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onSelected(),
      backgroundColor: AppTheme.surfaceGlass,
      selectedColor: AppTheme.primary,
      labelStyle: GoogleFonts.dmSans(
        color: selected ? Colors.white : AppTheme.textSecondary,
        fontWeight: FontWeight.w700,
      ),
      side: const BorderSide(color: AppTheme.borderGlass),
    );
  }
}

class _LiveRoomCard extends StatelessWidget {
  final Map<String, dynamic> topic;
  final String timerText;

  const _LiveRoomCard({required this.topic, required this.timerText});

  @override
  Widget build(BuildContext context) {
    final isLive = topic['status'] == 'live';
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
            'Live Topic Room',
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isLive ? 'Time remaining $timerText' : 'Video stage coming next',
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

class _InfoCard extends StatelessWidget {
  final String title;
  final String body;
  final String? description;
  final String status;

  const _InfoCard({
    required this.title,
    required this.body,
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
          _StatusPill(status: status),
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
