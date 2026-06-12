import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum BadgeType { verified, spark, online, pending, matched, chatUnlocked }

class StatusBadgeWidget extends StatelessWidget {
  final BadgeType type;
  final String? customLabel;
  final bool compact;

  const StatusBadgeWidget({
    super.key,
    required this.type,
    this.customLabel,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final config = _getConfig();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: config.bgColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: config.borderColor, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(config.icon, size: compact ? 10 : 12, color: config.iconColor),
          const SizedBox(width: 4),
          Text(
            customLabel ?? config.label,
            style: GoogleFonts.dmSans(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w600,
              color: config.textColor,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }

  _BadgeConfig _getConfig() {
    switch (type) {
      case BadgeType.verified:
        return _BadgeConfig(
          icon: Icons.verified_rounded,
          label: 'Verified',
          bgColor: const Color(0x334CAF82),
          borderColor: const Color(0x664CAF82),
          iconColor: const Color(0xFF4CAF82),
          textColor: const Color(0xFF4CAF82),
        );
      case BadgeType.spark:
        return _BadgeConfig(
          icon: Icons.bolt_rounded,
          label: 'Sparked',
          bgColor: const Color(0x33FF4458),
          borderColor: const Color(0x66FF4458),
          iconColor: const Color(0xFFFF4458),
          textColor: const Color(0xFFFF4458),
        );
      case BadgeType.online:
        return _BadgeConfig(
          icon: Icons.circle,
          label: 'Online',
          bgColor: const Color(0x334CAF82),
          borderColor: const Color(0x664CAF82),
          iconColor: const Color(0xFF4CAF82),
          textColor: const Color(0xFF4CAF82),
        );
      case BadgeType.pending:
        return _BadgeConfig(
          icon: Icons.hourglass_empty_rounded,
          label: 'Pending',
          bgColor: const Color(0x33F59E0B),
          borderColor: const Color(0x66F59E0B),
          iconColor: const Color(0xFFF59E0B),
          textColor: const Color(0xFFF59E0B),
        );
      case BadgeType.matched:
        return _BadgeConfig(
          icon: Icons.favorite_rounded,
          label: 'Matched',
          bgColor: const Color(0x33FF4458),
          borderColor: const Color(0x66FF4458),
          iconColor: const Color(0xFFFF4458),
          textColor: const Color(0xFFFF4458),
        );
      case BadgeType.chatUnlocked:
        return _BadgeConfig(
          icon: Icons.lock_open_rounded,
          label: 'Chat Unlocked',
          bgColor: const Color(0x334CAF82),
          borderColor: const Color(0x664CAF82),
          iconColor: const Color(0xFF4CAF82),
          textColor: const Color(0xFF4CAF82),
        );
    }
  }
}

class _BadgeConfig {
  final IconData icon;
  final String label;
  final Color bgColor;
  final Color borderColor;
  final Color iconColor;
  final Color textColor;

  _BadgeConfig({
    required this.icon,
    required this.label,
    required this.bgColor,
    required this.borderColor,
    required this.iconColor,
    required this.textColor,
  });
}
