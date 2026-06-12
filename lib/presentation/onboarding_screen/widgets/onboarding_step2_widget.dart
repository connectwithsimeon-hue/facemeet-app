import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class OnboardingStep2Widget extends StatelessWidget {
  final List<String> selectedInterests;
  final ValueChanged<List<String>> onInterestsChanged;

  const OnboardingStep2Widget({
    super.key,
    required this.selectedInterests,
    required this.onInterestsChanged,
  });

  static const _allInterests = [
    'Hiking 🥾',
    'Coffee ☕',
    'Travel ✈️',
    'Music 🎵',
    'Cooking 🍳',
    'Photography 📸',
    'Yoga 🧘',
    'Gaming 🎮',
    'Reading 📚',
    'Fitness 💪',
    'Art 🎨',
    'Movies 🎬',
    'Dancing 💃',
    'Wine 🍷',
    'Surfing 🏄',
    'Foodie 🍜',
    'Dogs 🐕',
    'Cats 🐈',
    'Tech 💻',
    'Fashion 👗',
    'Meditation 🧠',
    'Running 🏃',
    'Climbing 🧗',
    'Jazz 🎷',
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What are you into?',
            style: GoogleFonts.dmSans(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          RichText(
            text: TextSpan(
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AppTheme.textSecondary,
              ),
              children: [
                const TextSpan(text: 'Pick at least '),
                TextSpan(
                  text: '3 interests',
                  style: GoogleFonts.dmSans(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextSpan(
                  text:
                      ' that spark your curiosity — ${selectedInterests.length} selected',
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _allInterests.map((interest) {
              final isSelected = selectedInterests.contains(interest);
              return GestureDetector(
                onTap: () {
                  final updated = List<String>.from(selectedInterests);
                  if (isSelected) {
                    updated.remove(interest);
                  } else {
                    updated.add(interest);
                  }
                  onInterestsChanged(updated);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0x33FF4458)
                        : AppTheme.surfaceGlass,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.primary
                          : AppTheme.borderGlass,
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    interest,
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: isSelected
                          ? AppTheme.primary
                          : AppTheme.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
