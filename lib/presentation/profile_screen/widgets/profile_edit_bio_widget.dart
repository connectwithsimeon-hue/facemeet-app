import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class ProfileEditBioWidget extends StatefulWidget {
  final String bio;
  final bool isEditing;
  final ValueChanged<String> onChanged;
  final FocusNode? focusNode;

  const ProfileEditBioWidget({
    super.key,
    required this.bio,
    required this.isEditing,
    required this.onChanged,
    this.focusNode,
  });

  @override
  State<ProfileEditBioWidget> createState() => _ProfileEditBioWidgetState();
}

class _ProfileEditBioWidgetState extends State<ProfileEditBioWidget> {
  late TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.bio);
  }

  @override
  void didUpdateWidget(ProfileEditBioWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isEditing && oldWidget.isEditing) {
      _ctrl.text = widget.bio;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isEditing) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: TextField(
            controller: _ctrl,
            focusNode: widget.focusNode,
            maxLines: 4,
            maxLength: 200,
            onChanged: widget.onChanged,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 14,
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'Tell people who you are...',
              hintStyle: GoogleFonts.dmSans(
                color: AppTheme.textHint,
                fontSize: 14,
              ),
              filled: true,
              fillColor: AppTheme.surfaceGlass,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: AppTheme.borderGlass,
                  width: 1,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: AppTheme.borderGlass,
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: AppTheme.primary,
                  width: 1.5,
                ),
              ),
              counterStyle: GoogleFonts.dmSans(
                fontSize: 11,
                color: AppTheme.textMuted,
              ),
              contentPadding: const EdgeInsets.all(14),
            ),
          ),
        ),
      );
    }

    return Text(
      widget.bio.isEmpty
          ? 'Add a bio to tell people about yourself...'
          : widget.bio,
      style: GoogleFonts.dmSans(
        fontSize: 14,
        color: widget.bio.isEmpty ? AppTheme.textMuted : AppTheme.textSecondary,
        height: 1.6,
      ),
    );
  }
}
