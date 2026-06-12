import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../widgets/custom_image_widget.dart';

/// Non-blocking frosted glass banner that slides down from the top
/// when a new mutual match is created. Stays for 6 seconds or until tapped/dismissed.
class MutualMatchBannerWidget extends StatefulWidget {
  final String matchId;
  final String matchedUserId;
  final String matchedName;
  final String? matchedVideoUrl;
  final VoidCallback onDismiss;
  final VoidCallback onStartSession;

  const MutualMatchBannerWidget({
    super.key,
    required this.matchId,
    required this.matchedUserId,
    required this.matchedName,
    this.matchedVideoUrl,
    required this.onDismiss,
    required this.onStartSession,
  });

  @override
  State<MutualMatchBannerWidget> createState() =>
      _MutualMatchBannerWidgetState();
}

class _MutualMatchBannerWidgetState extends State<MutualMatchBannerWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<Offset> _slideAnim;
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));

    _slideCtrl.forward();

    // Auto-dismiss after 6 seconds
    _autoDismissTimer = Timer(const Duration(seconds: 6), _dismiss);
  }

  void _dismiss() {
    if (!mounted) return;
    _slideCtrl.reverse().then((_) {
      if (mounted) widget.onDismiss();
    });
  }

  void _handleTap() {
    _autoDismissTimer?.cancel();
    _slideCtrl.reverse().then((_) {
      if (mounted) widget.onStartSession();
    });
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: _slideAnim,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xCC1A1A2E),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: const Color(0x66FF4458),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF4458).withAlpha(40),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        // Video thumbnail
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFFF4458),
                              width: 2,
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child:
                                widget.matchedVideoUrl != null &&
                                    widget.matchedVideoUrl!.isNotEmpty
                                ? CustomImageWidget(
                                    imageUrl: widget.matchedVideoUrl!,
                                    semanticLabel:
                                        'Profile photo of ${widget.matchedName}',
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    color: const Color(0xFF1A1A2E),
                                    child: Center(
                                      child: Text(
                                        widget.matchedName.isNotEmpty
                                            ? widget.matchedName[0]
                                                  .toUpperCase()
                                            : '?',
                                        style: GoogleFonts.dmSans(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Text
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.bolt_rounded,
                                    color: Color(0xFFFF4458),
                                    size: 14,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Mutual Spark!',
                                    style: GoogleFonts.dmSans(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: const Color(0xFFFF4458),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'You have a mutual Spark with ${widget.matchedName}. Ready for a 3-minute Spark Session.',
                                style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  color: Colors.white,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Start button
                        GestureDetector(
                          onTap: _handleTap,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFFF4458), Color(0xFFFF6B7A)],
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              'Start\nSpark',
                              style: GoogleFonts.dmSans(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.2,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Dismiss button
                        GestureDetector(
                          onTap: _dismiss,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: const Color(0x1AFFFFFF),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                              size: 16,
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
        ),
      ),
    );
  }
}
