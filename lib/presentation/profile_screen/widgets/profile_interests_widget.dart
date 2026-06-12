import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class ProfileInterestsWidget extends StatelessWidget {
  final List<String> interests;
  final bool isEditing;
  final ValueChanged<List<String>> onChanged;

  const ProfileInterestsWidget({
    super.key,
    required this.interests,
    required this.isEditing,
    required this.onChanged,
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

  void _showEditSheet(BuildContext context) {
    final selected = List<String>.from(interests);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.7,
            decoration: const BoxDecoration(
              color: Color(0xF0141416),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Row(
                    children: [
                      Text(
                        'Edit Interests',
                        style: GoogleFonts.dmSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          onChanged(selected);
                          Navigator.pop(ctx);
                        },
                        child: Text(
                          'Done',
                          style: GoogleFonts.dmSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                    child: Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: _allInterests.map((interest) {
                        final isSel = selected.contains(interest);
                        return GestureDetector(
                          onTap: () {
                            setSheetState(() {
                              if (isSel) {
                                selected.remove(interest);
                              } else {
                                selected.add(interest);
                              }
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? const Color(0x33FF4458)
                                  : AppTheme.surfaceGlass,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: isSel
                                    ? AppTheme.primary
                                    : AppTheme.borderGlass,
                                width: isSel ? 1.5 : 1,
                              ),
                            ),
                            child: Text(
                              interest,
                              style: GoogleFonts.dmSans(
                                fontSize: 13,
                                fontWeight: isSel
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: isSel
                                    ? AppTheme.primary
                                    : AppTheme.textSecondary,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: interests.map((tag) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0x1AFF4458),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0x33FF4458), width: 1),
              ),
              child: Text(
                tag,
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.primary,
                ),
              ),
            );
          }).toList(),
        ),
        if (isEditing) ...[
          const SizedBox(height: 14),
          GestureDetector(
            onTap: () => _showEditSheet(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: AppTheme.surfaceGlass,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppTheme.borderGlassActive, width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.edit_rounded,
                    color: AppTheme.textMuted,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Edit interests',
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
