import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class ProfileStatsWidget extends StatelessWidget {
  final int sparkCount;
  final int sessionCount;
  final int matchCount;

  const ProfileStatsWidget({
    super.key,
    required this.sparkCount,
    required this.sessionCount,
    required this.matchCount,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderGlass, width: 1),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(
            children: [
              Expanded(
                child: _StatItem(
                  value: '$sparkCount',
                  label: 'Sparks Sent',
                  icon: Icons.bolt_rounded,
                  color: AppTheme.primary,
                ),
              ),
              Container(width: 1, height: 40, color: AppTheme.borderGlass),
              Expanded(
                child: _StatItem(
                  value: '$sessionCount',
                  label: 'Sessions',
                  icon: Icons.videocam_rounded,
                  color: const Color(0xFF9B8FFF),
                ),
              ),
              Container(width: 1, height: 40, color: AppTheme.borderGlass),
              Expanded(
                child: _StatItem(
                  value: '$matchCount',
                  label: 'Matches',
                  icon: Icons.favorite_rounded,
                  color: AppTheme.sparkGreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color color;

  const _StatItem({
    required this.value,
    required this.label,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 6),
        Text(
          value,
          style: GoogleFonts.dmSans(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            fontFeatures: [const FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 11,
            color: AppTheme.textMuted,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
