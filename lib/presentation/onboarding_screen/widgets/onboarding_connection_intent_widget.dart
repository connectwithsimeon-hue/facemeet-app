import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

class OnboardingConnectionIntentWidget extends StatelessWidget {
  final String selectedIntent;
  final ValueChanged<String> onIntentChanged;

  const OnboardingConnectionIntentWidget({
    super.key,
    required this.selectedIntent,
    required this.onIntentChanged,
  });

  static const List<_ConnectionIntentOption> _options = [
    _ConnectionIntentOption(
      value: 'dating',
      label: 'Dating',
      description: 'Meet people with romantic chemistry.',
      icon: Icons.favorite_rounded,
    ),
    _ConnectionIntentOption(
      value: 'friendship',
      label: 'Friendship',
      description: 'Build real friendships with people nearby.',
      icon: Icons.groups_rounded,
    ),
    _ConnectionIntentOption(
      value: 'professional',
      label: 'Professional Connections',
      description: 'Connect with ambitious people and collaborators.',
      icon: Icons.work_rounded,
    ),
    _ConnectionIntentOption(
      value: 'events',
      label: 'Events',
      description: 'Discover curated FaceMeet experiences.',
      icon: Icons.event_available_rounded,
    ),
    _ConnectionIntentOption(
      value: 'open_to_all',
      label: 'Open to All',
      description: 'Stay open to every kind of meaningful connection.',
      icon: Icons.auto_awesome_rounded,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final normalized = SupabaseService.normalizeConnectionIntent(
      selectedIntent,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What are you here for?',
            style: GoogleFonts.dmSans(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Choose the connection you want FaceMeet to prioritize first.',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          ..._options.map((option) {
            final isSelected = normalized == option.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _IntentOptionCard(
                option: option,
                isSelected: isSelected,
                onTap: () => onIntentChanged(option.value),
              ),
            );
          }),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _IntentOptionCard extends StatelessWidget {
  final _ConnectionIntentOption option;
  final bool isSelected;
  final VoidCallback onTap;

  const _IntentOptionCard({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0x33E8503A)
                  : AppTheme.surfaceGlass,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isSelected ? AppTheme.primary : AppTheme.borderGlass,
                width: isSelected ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFE8503A)
                        : const Color(0x22FFFFFF),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(option.icon, color: Colors.white, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: GoogleFonts.dmSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        option.description,
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: isSelected ? AppTheme.primary : AppTheme.textMuted,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionIntentOption {
  final String value;
  final String label;
  final String description;
  final IconData icon;

  const _ConnectionIntentOption({
    required this.value,
    required this.label,
    required this.description,
    required this.icon,
  });
}
