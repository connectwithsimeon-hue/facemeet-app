import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';

class OnboardingStep1Widget extends StatelessWidget {
  final String firstName;
  final int age;
  final String gender;
  final String interestedIn;
  final ValueChanged<String> onFirstNameChanged;
  final ValueChanged<int> onAgeChanged;
  final ValueChanged<String> onGenderChanged;
  final ValueChanged<String> onInterestedInChanged;

  const OnboardingStep1Widget({
    super.key,
    required this.firstName,
    required this.age,
    required this.gender,
    required this.interestedIn,
    required this.onFirstNameChanged,
    required this.onAgeChanged,
    required this.onGenderChanged,
    required this.onInterestedInChanged,
  });

  static const _genders = ['man', 'woman', 'non_binary', 'other'];
  static const _interestedOptions = ['men', 'women', 'everyone'];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tell us about yourself',
            style: GoogleFonts.dmSans(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Your profile is how others will see you on FaceMeet',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 32),
          _glassLabel('First name'),
          const SizedBox(height: 8),
          _GlassTextField(
            initialValue: firstName,
            hint: 'What do people call you?',
            onChanged: onFirstNameChanged,
            keyboardType: TextInputType.name,
          ),
          const SizedBox(height: 20),
          _glassLabel('Age'),
          const SizedBox(height: 8),
          _AgeSelector(age: age, onChanged: onAgeChanged),
          const SizedBox(height: 20),
          _glassLabel('I am a'),
          const SizedBox(height: 10),
          _OptionChipRow(
            options: _genders,
            selected: gender,
            onSelected: onGenderChanged,
          ),
          const SizedBox(height: 20),
          _glassLabel('Interested in'),
          const SizedBox(height: 10),
          _OptionChipRow(
            options: _interestedOptions,
            selected: interestedIn,
            onSelected: onInterestedInChanged,
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _glassLabel(String text) {
    return Text(
      text,
      style: GoogleFonts.dmSans(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppTheme.textMuted,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _GlassTextField extends StatelessWidget {
  final String initialValue;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType keyboardType;

  const _GlassTextField({
    required this.initialValue,
    required this.hint,
    required this.onChanged,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: TextFormField(
          initialValue: initialValue,
          keyboardType: keyboardType,
          onChanged: onChanged,
          style: GoogleFonts.dmSans(color: Colors.white, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: AppTheme.surfaceGlass,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                color: AppTheme.borderGlass,
                width: 1,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                color: AppTheme.borderGlass,
                width: 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
            ),
            hintStyle: GoogleFonts.dmSans(
              fontSize: 15,
              color: AppTheme.textHint,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 16,
            ),
          ),
        ),
      ),
    );
  }
}

class _AgeSelector extends StatelessWidget {
  final int age;
  final ValueChanged<int> onChanged;

  const _AgeSelector({required this.age, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.borderGlass, width: 1),
          ),
          child: Row(
            children: [
              const SizedBox(width: 20),
              Expanded(
                child: Text(
                  '$age years old',
                  style: GoogleFonts.dmSans(color: Colors.white, fontSize: 15),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.remove_rounded,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                onPressed: age > 18 ? () => onChanged(age - 1) : null,
              ),
              Container(width: 1, height: 20, color: AppTheme.borderGlass),
              IconButton(
                icon: const Icon(
                  Icons.add_rounded,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                onPressed: age < 99 ? () => onChanged(age + 1) : null,
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionChipRow extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;

  const _OptionChipRow({
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  String _labelForOption(String value) {
    switch (value) {
      case 'man':
        return 'Man';
      case 'woman':
        return 'Woman';
      case 'non_binary':
        return 'Non-binary';
      case 'other':
        return 'Other';
      case 'men':
        return 'Men';
      case 'women':
        return 'Women';
      case 'everyone':
        return 'Everyone';
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: options.map((opt) {
        final isSelected = selected == opt;
        return GestureDetector(
          onTap: () => onSelected(opt),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0x33FF4458)
                  : AppTheme.surfaceGlass,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isSelected ? AppTheme.primary : AppTheme.borderGlass,
                width: isSelected ? 1.5 : 1,
              ),
            ),
            child: Text(
              _labelForOption(opt),
              style: GoogleFonts.dmSans(
                fontSize: 14,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? AppTheme.primary : AppTheme.textSecondary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
