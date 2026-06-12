import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/status_badge_widget.dart';
import '../../../widgets/user_safety_actions.dart';
import '../../../services/external_return_repair_service.dart';
import '../../../services/presence_service.dart';
import '../../../services/video_repair_service.dart';

class DiscoveryCardWidget extends StatefulWidget {
  final String userId;
  final String name;
  final int age;
  final String city;
  final String bio;
  final List<String> interests;
  final String videoUrl;
  final bool isVerified;
  final bool isOnline;
  final String? lastSeenAt;
  final String? videoPrompt;
  final VoidCallback onSpark;
  final VoidCallback onSkip;
  final VoidCallback? onReported;
  final VoidCallback? onBlocked;

  const DiscoveryCardWidget({
    super.key,
    required this.userId,
    required this.name,
    required this.age,
    required this.city,
    required this.bio,
    required this.interests,
    required this.videoUrl,
    required this.isVerified,
    required this.isOnline,
    this.lastSeenAt,
    this.videoPrompt,
    required this.onSpark,
    required this.onSkip,
    this.onReported,
    this.onBlocked,
  });

  @override
  State<DiscoveryCardWidget> createState() => _DiscoveryCardWidgetState();
}

class _DiscoveryCardWidgetState extends State<DiscoveryCardWidget>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;
  late AnimationController _snapController;
  late Animation<Offset> _snapAnim;

  VideoPlayerController? _videoController;
  bool _videoInitialized = false;
  bool _videoError = false;
  bool _isMuted = true;
  int _videoInitGeneration = 0;
  int _videoRetryCount = 0;
  StreamSubscription<void>? _externalReturnRepairSubscription;
  StreamSubscription<VideoRepairEvent>? _videoRepairSubscription;
  static const int _maxVideoRetries = 2;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _snapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _snapAnim = Tween<Offset>(begin: Offset.zero, end: Offset.zero).animate(
      CurvedAnimation(parent: _snapController, curve: Curves.easeOutCubic),
    );
    _externalReturnRepairSubscription = ExternalReturnRepairService.events
        .listen((_) {
          debugPrint(
            'DISCOVERY VIDEO: external return repair event user=$_videoLogId',
          );
          _recoverVideoAfterResume();
        });
    _videoRepairSubscription = VideoRepairService.events.listen((event) {
      debugPrint(
        'DISCOVERY VIDEO: repair received user=$_videoLogId source=${event.source}',
      );
      _recoverVideoAfterResume();
    });
    _initVideo();
  }

  String get _videoLogId =>
      widget.userId.isNotEmpty ? widget.userId : 'unknown';

  Future<void> _initVideo({String reason = 'initial'}) async {
    final videoUrl = widget.videoUrl.trim();
    final generation = ++_videoInitGeneration;

    if (mounted) {
      setState(() {
        _videoInitialized = false;
        _videoError = false;
      });
    }

    if (videoUrl.isEmpty) {
      debugPrint(
        'DISCOVERY VIDEO: init failed user=$_videoLogId reason=missing_url trigger=$reason',
      );
      if (mounted && generation == _videoInitGeneration) {
        setState(() => _videoError = true);
      }
      return;
    }

    debugPrint(
      'DISCOVERY VIDEO: init started user=$_videoLogId trigger=$reason retry=$_videoRetryCount url_present=true',
    );

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
      _videoController = controller;
      await controller.initialize();
      if (!mounted || generation != _videoInitGeneration) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.setVolume(0.0);
      await controller.play();
      debugPrint(
        'DISCOVERY VIDEO: init success user=$_videoLogId duration=${controller.value.duration.inMilliseconds}ms size=${controller.value.size.width.toStringAsFixed(0)}x${controller.value.size.height.toStringAsFixed(0)}',
      );
      debugPrint(
        'DISCOVERY VIDEO: play started user=$_videoLogId is_playing=${controller.value.isPlaying}',
      );
      if (mounted && generation == _videoInitGeneration) {
        setState(() {
          _videoInitialized = true;
          _videoError = false;
          _isMuted = true;
        });
      }
    } catch (e) {
      debugPrint(
        'DISCOVERY VIDEO: init failed user=$_videoLogId trigger=$reason error=$e',
      );
      if (generation == _videoInitGeneration) {
        await _disposeVideoController();
        _retryOrShowVideoFallback('init_failed');
      }
    }
  }

  Future<void> _disposeVideoController() async {
    final controller = _videoController;
    _videoController = null;
    if (controller != null) {
      await controller.dispose();
    }
  }

  void _retryOrShowVideoFallback(String reason) {
    if (!mounted) return;
    if (_videoRetryCount < _maxVideoRetries) {
      _videoRetryCount += 1;
      debugPrint(
        'DISCOVERY VIDEO: retry scheduled user=$_videoLogId reason=$reason attempt=$_videoRetryCount',
      );
      Future.delayed(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        _initVideo(reason: 'retry_$reason');
      });
      return;
    }

    setState(() {
      _videoInitialized = false;
      _videoError = true;
    });
  }

  Future<void> _resetVideoForCurrentProfile(String reason) async {
    debugPrint(
      'DISCOVERY VIDEO: profile changed, resetting video user=$_videoLogId trigger=$reason',
    );
    _videoInitGeneration += 1;
    _videoRetryCount = 0;
    if (mounted) {
      setState(() {
        _videoInitialized = false;
        _videoError = false;
        _isMuted = true;
      });
    }
    await _disposeVideoController();
    if (mounted) {
      await _initVideo(reason: reason);
    }
  }

  Future<void> _recoverVideoAfterResume() async {
    debugPrint('DISCOVERY VIDEO: app resumed user=$_videoLogId');
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted || widget.videoUrl.trim().isEmpty) return;

    final controller = _videoController;
    final value = controller?.value;
    final hasInvalidVideo =
        controller == null ||
        value == null ||
        value.hasError ||
        !value.isInitialized ||
        value.size.width <= 0 ||
        value.size.height <= 0;

    if (hasInvalidVideo) {
      debugPrint(
        'DISCOVERY VIDEO: controller recreated user=$_videoLogId reason=invalid_after_resume',
      );
      debugPrint('DISCOVERY VIDEO: controller recreated yes');
      await _resetVideoForCurrentProfile('resume_recreate_invalid');
      return;
    }

    try {
      await controller.setVolume(_isMuted ? 0.0 : 1.0);
      await controller.play();
      debugPrint(
        'DISCOVERY VIDEO: resume replay attempted user=$_videoLogId is_playing=${controller.value.isPlaying}',
      );

      if (!controller.value.isPlaying) {
        debugPrint(
          'DISCOVERY VIDEO: controller recreated user=$_videoLogId reason=not_playing_after_resume',
        );
        debugPrint('DISCOVERY VIDEO: controller recreated yes');
        await _resetVideoForCurrentProfile('resume_recreate_not_playing');
      } else {
        debugPrint('DISCOVERY VIDEO: controller recreated no');
      }
    } catch (e) {
      debugPrint('DISCOVERY VIDEO: play failed user=$_videoLogId error=$e');
      debugPrint(
        'DISCOVERY VIDEO: controller recreated user=$_videoLogId reason=play_failed_after_resume',
      );
      debugPrint('DISCOVERY VIDEO: controller recreated yes');
      await _resetVideoForCurrentProfile('resume_recreate_play_failed');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _recoverVideoAfterResume();
    }
  }

  @override
  void didUpdateWidget(covariant DiscoveryCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.videoUrl != widget.videoUrl) {
      _resetVideoForCurrentProfile('did_update_widget');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _externalReturnRepairSubscription?.cancel();
    _videoRepairSubscription?.cancel();
    _snapController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails d) {
    setState(() => _isDragging = true);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() => _dragOffset += d.delta);
  }

  void _onPanEnd(DragEndDetails d) {
    setState(() => _isDragging = false);
    const threshold = 80.0;
    if (_dragOffset.dx > threshold) {
      debugPrint(
        'DISCOVERY_SWIPE: Right swipe triggered — calling onSpark (dx=${_dragOffset.dx.toStringAsFixed(1)})',
      );
      widget.onSpark();
      setState(() => _dragOffset = Offset.zero);
    } else if (_dragOffset.dx < -threshold) {
      debugPrint(
        'DISCOVERY_SWIPE: Left swipe triggered — calling onSkip (dx=${_dragOffset.dx.toStringAsFixed(1)})',
      );
      widget.onSkip();
      setState(() => _dragOffset = Offset.zero);
    } else {
      _snapAnim = Tween<Offset>(begin: _dragOffset, end: Offset.zero).animate(
        CurvedAnimation(parent: _snapController, curve: Curves.easeOutCubic),
      );
      _snapController.reset();
      _snapController.forward().then((_) {
        setState(() => _dragOffset = Offset.zero);
      });
    }
  }

  void _toggleMute() {
    final newMuted = !_isMuted;
    setState(() => _isMuted = newMuted);
    final volume = newMuted ? 0.0 : 1.0;
    _videoController?.setVolume(volume);
    debugPrint('MUTE_TOGGLE: volume set to $volume (isMuted=$newMuted)');
  }

  void resetMute() {
    if (!mounted) return;
    setState(() => _isMuted = true);
    _videoController?.setVolume(0.0);
    debugPrint('MUTE_RESET: volume reset to 0 on card change');
  }

  Future<void> _reportUser() async {
    final submitted = await showReportUserSheet(
      context,
      reportedUserId: widget.userId,
      reportedUserName: widget.name,
      source: 'profile',
    );
    if (submitted) widget.onReported?.call();
  }

  Future<void> _blockUser() async {
    final blocked = await showBlockUserDialog(
      context,
      blockedUserId: widget.userId,
      blockedUserName: widget.name,
      source: 'profile',
    );
    if (blocked) widget.onBlocked?.call();
  }

  double get _sparkOpacity => (_dragOffset.dx / 120).clamp(0.0, 1.0);
  double get _skipOpacity => (-_dragOffset.dx / 120).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: AnimatedBuilder(
        animation: _snapController,
        builder: (context, child) {
          final currentOffset = _isDragging ? _dragOffset : _snapAnim.value;
          return Transform.translate(
            offset: currentOffset,
            child: Transform.rotate(
              angle: currentOffset.dx * 0.0008,
              child: child,
            ),
          );
        },
        child: Stack(
          children: [
            // Main card
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Video background or placeholder
                  _buildVideoBackground(),
                  // Gradient overlay
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Color(0x80000000),
                          Color(0xCC000000),
                        ],
                        stops: [0.0, 0.4, 0.7, 1.0],
                      ),
                    ),
                  ),
                  // Spark indicator
                  Positioned(
                    top: 40,
                    left: 24,
                    child: AnimatedOpacity(
                      opacity: _sparkOpacity,
                      duration: Duration.zero,
                      child: _SwipeLabel(
                        label: 'SPARK',
                        color: AppTheme.sparkGreen,
                        icon: Icons.bolt_rounded,
                      ),
                    ),
                  ),
                  // Skip indicator
                  Positioned(
                    top: 40,
                    right: 24,
                    child: AnimatedOpacity(
                      opacity: _skipOpacity,
                      duration: Duration.zero,
                      child: _SwipeLabel(
                        label: 'SKIP',
                        color: Colors.white54,
                        icon: Icons.close_rounded,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 16,
                    left: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CardSafetyButton(
                          icon: Icons.flag_outlined,
                          label: 'Report User',
                          onTap: _reportUser,
                        ),
                        const SizedBox(height: 8),
                        _CardSafetyButton(
                          icon: Icons.block_rounded,
                          label: 'Block User',
                          destructive: true,
                          onTap: _blockUser,
                        ),
                      ],
                    ),
                  ),
                  // Mute toggle button — top right corner
                  Positioned(
                    top: 16,
                    right: 16,
                    child: GestureDetector(
                      onTap: _toggleMute,
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: const Color(0x80000000),
                        child: Icon(
                          _isMuted ? Icons.volume_off : Icons.volume_up,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                  // Profile info at bottom
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(24),
                      ),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 0, sigmaY: 0),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 128),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Video prompt line (shown only if non-null/non-empty)
                              if (widget.videoPrompt != null &&
                                  widget.videoPrompt!.trim().isNotEmpty) ...[
                                Row(
                                  children: [
                                    Text(
                                      'Q:',
                                      style: GoogleFonts.outfit(
                                        fontSize: 11,
                                        color: const Color(0xFFE8503A),
                                        fontWeight: FontWeight.w700,
                                        fontStyle: FontStyle.italic,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        widget.videoPrompt!.length > 40
                                            ? '${widget.videoPrompt!.substring(0, 40)}...'
                                            : widget.videoPrompt!,
                                        style: GoogleFonts.outfit(
                                          fontSize: 11,
                                          color: Colors.white.withAlpha(153),
                                          fontStyle: FontStyle.italic,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                        maxLines: 1,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                              ],
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    '${widget.name}, ${widget.age}',
                                    style: GoogleFonts.dmSans(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (widget.isVerified) _VerifiedShieldBadge(),
                                  if (widget.isOnline) ...[
                                    const SizedBox(width: 6),
                                    StatusBadgeWidget(
                                      type: BadgeType.online,
                                      compact: true,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.location_on_rounded,
                                    color: AppTheme.textSecondary,
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    widget.city,
                                    style: GoogleFonts.dmSans(
                                      fontSize: 13,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                                  if (widget.isOnline) ...[
                                    const SizedBox(width: 8),
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: const BoxDecoration(
                                        color: Color(0xFF4CAF50),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'Online now',
                                      style: GoogleFonts.outfit(
                                        fontSize: 11,
                                        color: const Color(0xFF4CAF50),
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ] else ...[
                                    const SizedBox(width: 8),
                                    Text(
                                      PresenceService.formatLastSeen(
                                        widget.lastSeenAt,
                                      ),
                                      style: GoogleFonts.outfit(
                                        fontSize: 11,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 10),
                              Text(
                                widget.bio,
                                style: GoogleFonts.dmSans(
                                  fontSize: 14,
                                  color: AppTheme.textSecondary,
                                  height: 1.4,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: widget.interests
                                    .take(4)
                                    .map((tag) => _InterestChip(tag: tag))
                                    .toList(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Action buttons
            Positioned(
              bottom: 56,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _ActionButton(
                    icon: Icons.close_rounded,
                    color: const Color(0xB3FFFFFF),
                    backgroundColor: const Color(0x26FFFFFF),
                    borderColor: const Color(0x33FFFFFF),
                    size: 56,
                    onTap: widget.onSkip,
                  ),
                  const SizedBox(width: 20),
                  _ActionButton(
                    icon: Icons.bolt_rounded,
                    color: Colors.white,
                    backgroundColor: AppTheme.primary,
                    borderColor: Colors.transparent,
                    size: 72,
                    onTap: () {
                      debugPrint(
                        'DISCOVERY_SPARK_BUTTON: Spark button tapped — calling onSpark',
                      );
                      widget.onSpark();
                    },
                    hasGlow: true,
                  ),
                  const SizedBox(width: 20),
                  _ActionButton(
                    icon: Icons.info_outline_rounded,
                    color: const Color(0xB3FFFFFF),
                    backgroundColor: const Color(0x26FFFFFF),
                    borderColor: const Color(0x33FFFFFF),
                    size: 56,
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: Colors.transparent,
                        isScrollControlled: true,
                        builder: (_) => _AboutMeSheet(
                          userId: widget.userId,
                          name: widget.name,
                          age: widget.age,
                          bio: widget.bio,
                          interests: widget.interests,
                          onReported: widget.onReported,
                          onBlocked: widget.onBlocked,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoBackground() {
    // Show dark placeholder if no video URL or error
    if (_videoError || widget.videoUrl.isEmpty) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF0D0D0F)],
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.videocam_off_rounded,
                  color: Color(0xFFE8503A),
                  size: 32,
                ),
                const SizedBox(height: 10),
                Text(
                  widget.videoUrl.isEmpty
                      ? 'Profile video unavailable'
                      : 'Video is taking longer than expected',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.dmSans(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                if (widget.videoUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      _videoRetryCount = 0;
                      _resetVideoForCurrentProfile('manual_retry');
                    },
                    child: Text(
                      'Tap to retry',
                      style: GoogleFonts.dmSans(
                        color: const Color(0xFFE8503A),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // Show loading skeleton while video initializes
    if (!_videoInitialized) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A1A2E), Color(0xFF0D0D0F)],
          ),
        ),
        child: const Center(
          child: CircularProgressIndicator(
            color: AppTheme.primary,
            strokeWidth: 2,
          ),
        ),
      );
    }

    // Video is ready — fill card as background
    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _videoController!.value.size.width,
          height: _videoController!.value.size.height,
          child: VideoPlayer(_videoController!),
        ),
      ),
    );
  }
}

/// Coral checkmark shield badge for verified users — tapping shows a tooltip
class _VerifiedShieldBadge extends StatefulWidget {
  const _VerifiedShieldBadge();

  @override
  State<_VerifiedShieldBadge> createState() => _VerifiedShieldBadgeState();
}

class _VerifiedShieldBadgeState extends State<_VerifiedShieldBadge> {
  OverlayEntry? _tooltipEntry;

  void _showTooltip(BuildContext context) {
    _removeTooltip();
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final offset = renderBox.localToGlobal(Offset.zero);

    _tooltipEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: offset.dx - 60,
        top: offset.dy - 40,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A2E),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFFE8503A).withAlpha(100),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(100),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'Verified real person',
              style: GoogleFonts.dmSans(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_tooltipEntry!);
    Future.delayed(const Duration(seconds: 2), _removeTooltip);
  }

  void _removeTooltip() {
    _tooltipEntry?.remove();
    _tooltipEntry = null;
  }

  @override
  void dispose() {
    _removeTooltip();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showTooltip(context),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: const Color(0xFFE8503A).withAlpha(26),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          Icons.verified_rounded,
          color: Color(0xFFE8503A),
          size: 16,
        ),
      ),
    );
  }
}

class _SwipeLabel extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _SwipeLabel({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: color.withAlpha(51),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.dmSans(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _InterestChip extends StatelessWidget {
  final String tag;
  const _InterestChip({required this.tag});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0x26FFFFFF),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x33FFFFFF), width: 1),
          ),
          child: Text(
            tag,
            style: GoogleFonts.dmSans(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final Color backgroundColor;
  final Color borderColor;
  final double size;
  final VoidCallback onTap;
  final bool hasGlow;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.backgroundColor,
    required this.borderColor,
    required this.size,
    required this.onTap,
    this.hasGlow = false,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.90,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Ensure minimum 48x48 tap target even if visual size is smaller
    final tapSize = widget.size < 48.0 ? 48.0 : widget.size;
    return SizedBox(
      width: tapSize,
      height: tapSize,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(tapSize / 2),
          onTap: () {
            _ctrl.forward().then((_) => _ctrl.reverse());
            widget.onTap();
          },
          child: ScaleTransition(
            scale: _scale,
            child: Center(
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: widget.backgroundColor,
                  borderRadius: BorderRadius.circular(widget.size / 2),
                  border: Border.all(color: widget.borderColor, width: 1.5),
                  boxShadow: widget.hasGlow
                      ? [
                          BoxShadow(
                            color: AppTheme.primary.withAlpha(115),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ]
                      : null,
                ),
                child: Icon(
                  widget.icon,
                  color: widget.color,
                  size: widget.size * 0.42,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CardSafetyButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _CardSafetyButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppTheme.error : Colors.white;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: destructive ? const Color(0x99FF4458) : Colors.white38,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: GoogleFonts.dmSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── About Me Bottom Sheet ────────────────────────────────────────────────────

class _AboutMeSheet extends StatelessWidget {
  final String userId;
  final String name;
  final int age;
  final String bio;
  final List<String> interests;
  final VoidCallback? onReported;
  final VoidCallback? onBlocked;

  const _AboutMeSheet({
    required this.userId,
    required this.name,
    required this.age,
    required this.bio,
    required this.interests,
    this.onReported,
    this.onBlocked,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3A3E),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Name + age
          Text(
            '$name, $age',
            style: GoogleFonts.outfit(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          // About Me label
          Text(
            'About Me',
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          // Bio text
          Text(
            bio.isNotEmpty ? bio : 'No bio yet.',
            style: GoogleFonts.dmSans(
              fontSize: 15,
              color: const Color(0xFFCCCCCC),
              height: 1.55,
            ),
          ),
          if (interests.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Interests',
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.primary,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: interests
                  .map(
                    (interest) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0x1AE8503A),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0x33E8503A),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        interest,
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 20),
          UserSafetyActionButtons(
            reportedUserId: userId,
            reportedUserName: name,
            source: 'profile',
            onReported: onReported,
            onBlocked: () {
              Navigator.pop(context);
              onBlocked?.call();
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
