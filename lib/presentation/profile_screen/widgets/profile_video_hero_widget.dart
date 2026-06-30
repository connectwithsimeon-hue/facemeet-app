import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/status_badge_widget.dart';
import '../../../services/external_return_repair_service.dart';
import '../../../services/supabase_service.dart';
import '../../../services/video_repair_service.dart';
import '../../../routes/app_routes.dart';
import '../profile_video_record_screen.dart';

class ProfileVideoHeroWidget extends StatefulWidget {
  final String videoUrl;
  final String name;
  final int age;
  final String city;
  final bool isVerified;
  final VoidCallback? onVideoUpdated;
  final VoidCallback? onSettingsTap;

  const ProfileVideoHeroWidget({
    super.key,
    required this.videoUrl,
    required this.name,
    required this.age,
    required this.city,
    required this.isVerified,
    this.onVideoUpdated,
    this.onSettingsTap,
  });

  @override
  State<ProfileVideoHeroWidget> createState() => _ProfileVideoHeroWidgetState();
}

class _ProfileVideoHeroWidgetState extends State<ProfileVideoHeroWidget>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _videoReady = false;
  final bool _isUploading = false;
  bool _isMuted = true;
  StreamSubscription<void>? _externalReturnRepairSubscription;
  StreamSubscription<VideoRepairEvent>? _videoRepairSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _externalReturnRepairSubscription = ExternalReturnRepairService.events
        .listen((_) {
          debugPrint('PROFILE VIDEO: external return repair event');
          _recoverVideoAfterExternalReturn();
        });
    _videoRepairSubscription = VideoRepairService.events.listen((event) {
      debugPrint('PROFILE VIDEO: repair received source=${event.source}');
      _recoverVideoAfterExternalReturn();
    });
    if (widget.videoUrl.isNotEmpty) {
      _initVideo(widget.videoUrl);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint('PROFILE VIDEO: lifecycle resumed');
      _recoverVideoAfterExternalReturn();
    }
  }

  @override
  void didUpdateWidget(ProfileVideoHeroWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl && widget.videoUrl.isNotEmpty) {
      _controller?.dispose();
      _videoReady = false;
      _initVideo(widget.videoUrl);
    }
  }

  Future<void> _initVideo(String url) async {
    try {
      await _controller?.dispose();
      _controller = null;
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(url));
      await ctrl.initialize();
      ctrl.setLooping(true);
      ctrl.setVolume(_isMuted ? 0 : 1);
      ctrl.play();
      if (mounted) {
        setState(() {
          _controller = ctrl;
          _videoReady = true;
        });
      } else {
        ctrl.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _videoReady = false);
    }
  }

  Future<void> _recoverVideoAfterExternalReturn() async {
    await Future.delayed(const Duration(milliseconds: 320));
    if (!mounted || widget.videoUrl.trim().isEmpty) return;

    final controller = _controller;
    final value = controller?.value;
    final hasInvalidVideo =
        controller == null ||
        value == null ||
        value.hasError ||
        !value.isInitialized ||
        value.size.width <= 0 ||
        value.size.height <= 0;

    if (hasInvalidVideo) {
      debugPrint('PROFILE VIDEO: controller recreated after external return');
      debugPrint('PROFILE VIDEO: controller recreated yes');
      if (mounted) setState(() => _videoReady = false);
      await controller?.dispose();
      _controller = null;
      await _initVideo(widget.videoUrl);
      return;
    }

    try {
      await controller.setVolume(_isMuted ? 0 : 1);
      await controller.play();
      debugPrint(
        'PROFILE VIDEO: external return replay attempted is_playing=${controller.value.isPlaying}',
      );
      if (!controller.value.isPlaying) {
        debugPrint(
          'PROFILE VIDEO: controller recreated after external return not_playing',
        );
        debugPrint('PROFILE VIDEO: controller recreated yes');
        if (mounted) setState(() => _videoReady = false);
        await controller.dispose();
        _controller = null;
        await _initVideo(widget.videoUrl);
      } else {
        debugPrint('PROFILE VIDEO: controller recreated no');
      }
    } catch (e) {
      debugPrint('PROFILE VIDEO: external return replay failed — $e');
      debugPrint('PROFILE VIDEO: controller recreated yes');
      if (mounted) setState(() => _videoReady = false);
      await _controller?.dispose();
      _controller = null;
      await _initVideo(widget.videoUrl);
    }
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
      _controller?.setVolume(_isMuted ? 0 : 1);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _externalReturnRepairSubscription?.cancel();
    _videoRepairSubscription?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  // ── Upload limit check ──────────────────────────────────────────────────

  Future<bool> _canUpload() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return false;
    final profile = await SupabaseService.instance.getUserProfile(uid);
    final tier = profile?['subscription_tier'] as String? ?? 'free';
    final count = (profile?['video_upload_count'] as num?)?.toInt() ?? 0;

    if (tier == 'free' && count >= 3) {
      if (mounted) _showUpgradeLimitSheet();
      return false;
    }
    return true;
  }

  // ── Bottom sheets ────────────────────────────────────────────────────────

  void _showEditOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditOptionsSheet(
        onReRecord: () {
          Navigator.pop(context);
          _handleReRecord();
        },
      ),
    );
  }

  void _showUpgradeLimitSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _UpgradeLimitSheet(
        onUpgrade: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, AppRoutes.pricingScreen);
        },
      ),
    );
  }

  // ── Re-record flow ───────────────────────────────────────────────────────

  Future<void> _handleReRecord() async {
    final allowed = await _canUpload();
    if (!allowed) return;

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProfileVideoRecordScreen(
          onVideoUploaded: (String newUrl) {
            // Immediately refresh the video player with the new URL
            if (mounted) {
              _controller?.dispose();
              _controller = null;
              setState(() => _videoReady = false);
              _initVideo(newUrl);
            }
            // Also trigger full profile refresh on the parent screen
            widget.onVideoUpdated?.call();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final heroHeight = size.height * 0.52;

    return SizedBox(
      height: heroHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video fills entire hero container
          if (_videoReady && _controller != null)
            FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.size.width,
                height: _controller!.value.size.height,
                child: VideoPlayer(_controller!),
              ),
            )
          else
            Container(
              color: const Color(0xFF1A1A1E),
              child: widget.videoUrl.isEmpty
                  ? Center(
                      child: Text(
                        widget.name.isNotEmpty
                            ? widget.name[0].toUpperCase()
                            : '?',
                        style: GoogleFonts.dmSans(
                          fontSize: 64,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    )
                  : const Center(
                      child: CircularProgressIndicator(
                        color: AppTheme.primary,
                        strokeWidth: 2,
                      ),
                    ),
            ),

          // Dark gradient overlay — transparent at top, black 70% at bottom 40%
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            height: heroHeight * 0.4,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0xB3000000)],
                ),
              ),
            ),
          ),

          // Top bar — "My Profile" title (top left) and settings icon (top right)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'My Profile',
                      style: GoogleFonts.dmSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    GestureDetector(
                      onTap: widget.onSettingsTap,
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
                              Icons.settings_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Edit video button — clear profile video edit action.
          Positioned(
            bottom: heroHeight * 0.4 + 12,
            right: 16,
            child: GestureDetector(
              onTap: _showEditOptions,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(110),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0x66E8503A),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.edit_rounded,
                          color: Color(0xFFE8503A),
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Edit Video',
                          style: GoogleFonts.dmSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Mute/Unmute button — frosted glass, bottom-left of video (above info)
          if (_videoReady)
            Positioned(
              bottom: heroHeight * 0.4 + 12,
              left: 16,
              child: GestureDetector(
                onTap: _toggleMute,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withAlpha(100),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withAlpha(60),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isMuted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isMuted ? 'Unmute' : 'Mute',
                            style: GoogleFonts.dmSans(
                              fontSize: 12,
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
            ),

          // Bottom info — name, age, city overlaid directly on video
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
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
                    if (widget.isVerified)
                      StatusBadgeWidget(
                        type: BadgeType.verified,
                        compact: true,
                      ),
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
                  ],
                ),
              ],
            ),
          ),

          // Upload overlay
          if (_isUploading)
            Positioned.fill(
              child: Container(
                color: Colors.black.withAlpha(204),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/images/App_Logo_Icon-1776473863446.png',
                          width: 60,
                          height: 60,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 24),
                      const SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          color: Color(0xFFE8503A),
                          strokeWidth: 3,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Uploading your profile video...',
                        style: GoogleFonts.outfit(
                          fontSize: 16,
                          color: const Color(0xFFF5F0E8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This may take a moment. Do not close the app.',
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Edit Options Bottom Sheet ────────────────────────────────────────────────

class _EditOptionsSheet extends StatelessWidget {
  final VoidCallback onReRecord;

  const _EditOptionsSheet({required this.onReRecord});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(60),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Update Profile Video',
            style: GoogleFonts.dmSans(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          // Re-record option only
          _SheetOption(
            icon: Icons.videocam_rounded,
            label: 'Re-record video',
            onTap: onReRecord,
          ),
          const SizedBox(height: 16),
          // Cancel
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withAlpha(30), width: 1),
              ),
              child: Center(
                child: Text(
                  'Cancel',
                  style: GoogleFonts.dmSans(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SheetOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withAlpha(25), width: 1),
        ),
        child: Row(
          children: [
            const SizedBox(width: 20),
            Icon(icon, color: const Color(0xFFE8503A), size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Upgrade Limit Bottom Sheet ───────────────────────────────────────────────

class _UpgradeLimitSheet extends StatelessWidget {
  final VoidCallback onUpgrade;

  const _UpgradeLimitSheet({required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(60),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: const Color(0x33E8503A),
              borderRadius: BorderRadius.circular(30),
            ),
            child: const Icon(
              Icons.videocam_off_rounded,
              color: Color(0xFFE8503A),
              size: 28,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Free Re-uploads Used',
            style: GoogleFonts.dmSans(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'You\'ve used all 3 free profile video re-uploads. Upgrade to Spark+ for unlimited re-uploads.',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: onUpgrade,
            child: Container(
              width: double.infinity,
              height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFE8503A), Color(0xFFD43F27)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.workspace_premium_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Subscribe to Spark+',
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Text(
              'Maybe later',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AppTheme.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
