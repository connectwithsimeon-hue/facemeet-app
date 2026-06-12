import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shows a top banner notification that auto-dismisses after [duration].
class InAppBannerNotification extends StatefulWidget {
  final String title;
  final String message;
  final String? thumbnailUrl;
  final IconData icon;
  final Color accentColor;
  final VoidCallback? onTap;
  final VoidCallback onDismiss;
  final Duration duration;

  const InAppBannerNotification({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    required this.accentColor,
    required this.onDismiss,
    this.thumbnailUrl,
    this.onTap,
    this.duration = const Duration(seconds: 4),
  });

  @override
  State<InAppBannerNotification> createState() =>
      _InAppBannerNotificationState();
}

class _InAppBannerNotificationState extends State<InAppBannerNotification>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

    _ctrl.forward();

    _timer = Timer(widget.duration, _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _ctrl.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    return Positioned(
      top: topPadding + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: GestureDetector(
            onTap: () {
              _timer?.cancel();
              _ctrl.reverse().then((_) {
                if (mounted) {
                  widget.onDismiss();
                  widget.onTap?.call();
                }
              });
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xE61A1A2E),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: widget.accentColor.withAlpha(80),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: widget.accentColor.withAlpha(40),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Avatar or icon
                      _buildAvatar(),
                      const SizedBox(width: 12),
                      // Text
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.title,
                              style: GoogleFonts.dmSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.message,
                              style: GoogleFonts.dmSans(
                                fontSize: 12,
                                color: const Color(0xCCFFFFFF),
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Dismiss
                      GestureDetector(
                        onTap: _dismiss,
                        child: const Icon(
                          Icons.close_rounded,
                          color: Color(0x66FFFFFF),
                          size: 18,
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
    );
  }

  Widget _buildAvatar() {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.accentColor.withAlpha(40),
        border: Border.all(
          color: widget.accentColor.withAlpha(120),
          width: 1.5,
        ),
      ),
      child: widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty
          ? ClipOval(
              child: Image.network(
                widget.thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(widget.icon, color: widget.accentColor, size: 20),
              ),
            )
          : Icon(widget.icon, color: widget.accentColor, size: 20),
    );
  }
}
