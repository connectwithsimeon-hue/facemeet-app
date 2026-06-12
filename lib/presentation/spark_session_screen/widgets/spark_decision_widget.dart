import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/custom_image_widget.dart';

class SparkDecisionWidget extends StatefulWidget {
  final Map<String, dynamic> otherUser;
  final ValueChanged<bool> onDecision;

  const SparkDecisionWidget({
    super.key,
    required this.otherUser,
    required this.onDecision,
  });

  @override
  State<SparkDecisionWidget> createState() => _SparkDecisionWidgetState();
}

class _SparkDecisionWidgetState extends State<SparkDecisionWidget>
    with SingleTickerProviderStateMixin {
  bool? _selected;
  late AnimationController _entranceCtrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _entranceCtrl,
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      ),
    );
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutCubic),
        );
    _entranceCtrl.forward();
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  void _makeDecision(bool spark) {
    debugPrint(
      'SPARK SESSION: post-session ${spark ? 'Spark' : 'Skip'} tapped',
    );
    setState(() => _selected = spark);
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) widget.onDecision(spark);
    });
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl =
        widget.otherUser['thumbnailUrl'] ?? widget.otherUser['imageUrl'];
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x22FF4458), Color(0xFF0D0D0F)],
          stops: [0.0, 0.5],
        ),
      ),
      child: SafeArea(
        child: FadeTransition(
          opacity: _fade,
          child: SlideTransition(
            position: _slide,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Avatar
                  Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(55),
                      border: Border.all(color: AppTheme.primary, width: 2.5),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primary.withAlpha(64),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(53),
                      child: CustomImageWidget(
                        imageUrl: imageUrl,
                        semanticLabel: widget.otherUser['semanticLabel'],
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'How did it feel?',
                    style: GoogleFonts.dmSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your choice is private until both of you decide',
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      color: AppTheme.textSecondary,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),
                  // Decision cards
                  Row(
                    children: [
                      Expanded(
                        child: _DecisionCard(
                          icon: Icons.close_rounded,
                          label: 'Skip',
                          sublabel: 'Not this time',
                          color: const Color(0xB3FFFFFF),
                          bgColor: AppTheme.surfaceGlass,
                          borderColor: AppTheme.borderGlassActive,
                          isSelected: _selected == false,
                          isDisabled: _selected != null,
                          onTap: () => _makeDecision(false),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _DecisionCard(
                          icon: Icons.bolt_rounded,
                          label: 'Spark',
                          sublabel: 'I felt it!',
                          color: Colors.white,
                          bgColor: const Color(0x33FF4458),
                          borderColor: AppTheme.primary,
                          isSelected: _selected == true,
                          isDisabled: _selected != null,
                          onTap: () => _makeDecision(true),
                          hasGlow: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceGlass,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AppTheme.borderGlass,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.lock_outline_rounded,
                              color: AppTheme.textMuted,
                              size: 16,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Both choices stay private. Chat only unlocks if you both choose Spark.',
                                style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  color: AppTheme.textSecondary,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DecisionCard extends StatefulWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final Color color;
  final Color bgColor;
  final Color borderColor;
  final bool isSelected;
  final bool isDisabled;
  final VoidCallback onTap;
  final bool hasGlow;

  const _DecisionCard({
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.color,
    required this.bgColor,
    required this.borderColor,
    required this.isSelected,
    required this.isDisabled,
    required this.onTap,
    this.hasGlow = false,
  });

  @override
  State<_DecisionCard> createState() => _DecisionCardState();
}

class _DecisionCardState extends State<_DecisionCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.94,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.isDisabled
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          if (!widget.isDisabled) _ctrl.forward();
        },
        onTapUp: (_) {
          _ctrl.reverse();
          if (!widget.isDisabled) widget.onTap();
        },
        onTapCancel: () => _ctrl.reverse(),
        child: ScaleTransition(
          scale: _scale,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: widget.isDisabled && !widget.isSelected ? 0.4 : 1.0,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(
                    vertical: 28,
                    horizontal: 16,
                  ),
                  decoration: BoxDecoration(
                    color: widget.isSelected
                        ? widget.bgColor
                        : AppTheme.surfaceGlass,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.isSelected
                          ? widget.borderColor
                          : AppTheme.borderGlass,
                      width: widget.isSelected ? 1.5 : 1,
                    ),
                    boxShadow: widget.isSelected && widget.hasGlow
                        ? [
                            BoxShadow(
                              color: AppTheme.primary.withAlpha(77),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
                  ),
                  child: Column(
                    children: [
                      Icon(
                        widget.icon,
                        color: widget.isSelected
                            ? widget.color
                            : AppTheme.textMuted,
                        size: 40,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        widget.label,
                        style: GoogleFonts.dmSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: widget.isSelected
                              ? widget.color
                              : AppTheme.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.sublabel,
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.textMuted,
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
}
