import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:video_player/video_player.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

class MatchCelebrationWidget extends StatefulWidget {
  final String matchedName;
  final String matchedUserId;
  final VoidCallback onDismiss;
  final VoidCallback onStartSession;
  final VoidCallback onScheduleLater;

  const MatchCelebrationWidget({
    super.key,
    required this.matchedName,
    required this.matchedUserId,
    required this.onDismiss,
    required this.onStartSession,
    required this.onScheduleLater,
  });

  @override
  State<MatchCelebrationWidget> createState() => _MatchCelebrationWidgetState();
}

class _MatchCelebrationWidgetState extends State<MatchCelebrationWidget>
    with TickerProviderStateMixin {
  late AnimationController _entranceCtrl;
  late AnimationController _confettiCtrl;
  late Animation<double> _scaleAnim;
  late Animation<double> _fadeAnim;
  late List<_ConfettiParticle> _particles;

  String _myVideoUrl = '';
  String _myName = '';
  String _theirVideoUrl = '';
  String _theirName = '';
  bool _profilesLoaded = false;

  @override
  void initState() {
    super.initState();
    _particles = List.generate(60, (i) => _ConfettiParticle(math.Random()));
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _confettiCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _scaleAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutBack),
    );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0, 0.5, curve: Curves.easeOut),
      ),
    );
    _entranceCtrl.forward();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    final myId = SupabaseService.instance.currentUserId;
    final theirId = widget.matchedUserId;

    final results = await Future.wait([
      myId != null
          ? SupabaseService.instance.getUserProfile(myId)
          : Future.value(null),
      SupabaseService.instance.getUserProfile(theirId),
    ]);

    if (mounted) {
      setState(() {
        final myProfile = results[0];
        final theirProfile = results[1];
        _myVideoUrl = myProfile?['profile_video_url'] ?? '';
        _myName = myProfile?['first_name'] ?? 'You';
        _theirVideoUrl = theirProfile?['profile_video_url'] ?? '';
        _theirName = theirProfile?['first_name'] ?? widget.matchedName;
        _profilesLoaded = true;
      });
    }
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _confettiCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: Container(
        color: Colors.black.withAlpha(224),
        child: Stack(
          children: [
            // Confetti
            AnimatedBuilder(
              animation: _confettiCtrl,
              builder: (_, __) => CustomPaint(
                painter: _ConfettiPainter(
                  particles: _particles,
                  progress: _confettiCtrl.value,
                ),
                size: Size.infinite,
              ),
            ),
            // Content
            SafeArea(
              child: ScaleTransition(
                scale: _scaleAnim,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Spark icon
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFF4458), Color(0xFFFF8A65)],
                            ),
                            borderRadius: BorderRadius.circular(36),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.primary.withAlpha(128),
                                blurRadius: 28,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.bolt_rounded,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'It\'s a Spark! ✦',
                          style: GoogleFonts.dmSans(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'You and $_theirName both sparked each other',
                          style: GoogleFonts.dmSans(
                            fontSize: 15,
                            color: AppTheme.textSecondary,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                        // Avatars
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _profilesLoaded
                                ? _VideoAvatar(
                                    videoUrl: _myVideoUrl,
                                    label: _myName,
                                    fallbackInitial: _myName.isNotEmpty
                                        ? _myName[0].toUpperCase()
                                        : 'Y',
                                  )
                                : _LoadingAvatar(label: 'You'),
                            Container(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0x33FF4458),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(
                                Icons.bolt_rounded,
                                color: AppTheme.primary,
                                size: 24,
                              ),
                            ),
                            _profilesLoaded
                                ? _VideoAvatar(
                                    videoUrl: _theirVideoUrl,
                                    label: _theirName,
                                    fallbackInitial: _theirName.isNotEmpty
                                        ? _theirName[0].toUpperCase()
                                        : '?',
                                  )
                                : _LoadingAvatar(label: widget.matchedName),
                          ],
                        ),
                        const SizedBox(height: 40),
                        // Start session CTA
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: GestureDetector(
                            onTap: widget.onStartSession,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFFFF4458),
                                    Color(0xFFFF6B7A),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(18),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppTheme.primary.withAlpha(102),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.videocam_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Start 3-minute intro now',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 16,
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
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: GestureDetector(
                            onTap: widget.onScheduleLater,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.12),
                                ),
                              ),
                              child: Center(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.schedule_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Schedule for later',
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
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: widget.onDismiss,
                          child: Text(
                            'Keep discovering',
                            style: GoogleFonts.dmSans(
                              fontSize: 14,
                              color: AppTheme.textSecondary,
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
      ),
    );
  }
}

/// Circular video thumbnail that loops muted. Falls back to dark circle with initial.
class _VideoAvatar extends StatefulWidget {
  final String videoUrl;
  final String label;
  final String fallbackInitial;

  const _VideoAvatar({
    required this.videoUrl,
    required this.label,
    required this.fallbackInitial,
  });

  @override
  State<_VideoAvatar> createState() => _VideoAvatarState();
}

class _VideoAvatarState extends State<_VideoAvatar> {
  VideoPlayerController? _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (widget.videoUrl.isNotEmpty) {
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
      await ctrl.initialize();
      ctrl.setLooping(true);
      ctrl.setVolume(0);
      ctrl.play();
      if (mounted) {
        setState(() {
          _ctrl = ctrl;
          _ready = true;
        });
      } else {
        ctrl.dispose();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(44),
            border: Border.all(color: AppTheme.primary, width: 2.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(42),
            child: _ready && _ctrl != null
                ? FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: _ctrl!.value.size.width,
                      height: _ctrl!.value.size.height,
                      child: VideoPlayer(_ctrl!),
                    ),
                  )
                : Container(
                    color: const Color(0xFF1A1A1E),
                    child: Center(
                      child: Text(
                        widget.fallbackInitial,
                        style: GoogleFonts.dmSans(
                          fontSize: 32,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          widget.label,
          style: GoogleFonts.dmSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _LoadingAvatar extends StatelessWidget {
  final String label;
  const _LoadingAvatar({required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 88,
          height: 88,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1E),
            borderRadius: BorderRadius.circular(44),
            border: Border.all(color: AppTheme.primary, width: 2.5),
          ),
          child: const Center(
            child: CircularProgressIndicator(
              color: AppTheme.primary,
              strokeWidth: 2,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _ConfettiParticle {
  late double x;
  late double y;
  late double size;
  late double speed;
  late Color color;
  late double angle;

  _ConfettiParticle(math.Random rng) {
    x = rng.nextDouble();
    y = rng.nextDouble();
    size = rng.nextDouble() * 8 + 4;
    speed = rng.nextDouble() * 0.15 + 0.05;
    angle = rng.nextDouble() * math.pi * 2;
    final colors = [
      AppTheme.primary,
      AppTheme.sparkGreen,
      Colors.amber,
      Colors.white,
      const Color(0xFFFF8A65),
    ];
    color = colors[rng.nextInt(colors.length)];
  }
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiParticle> particles;
  final double progress;

  _ConfettiPainter({required this.particles, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final y = (p.y + p.speed * progress * 5) % 1.0;
      final x = p.x + math.sin(progress * math.pi * 2 + p.angle) * 0.02;
      final paint = Paint()
        ..color = p.color.withAlpha(204)
        ..style = PaintingStyle.fill;
      canvas.save();
      canvas.translate(x * size.width, y * size.height);
      canvas.rotate(progress * math.pi * 4 + p.angle);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: p.size,
          height: p.size * 0.6,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.progress != progress;
}
