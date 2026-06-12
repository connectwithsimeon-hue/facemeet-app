import 'package:flutter/material.dart';
import '../../../theme/app_theme.dart';

class OnboardingStepIndicatorWidget extends StatelessWidget {
  final int currentStep;
  final int totalSteps;

  const OnboardingStepIndicatorWidget({
    super.key,
    required this.currentStep,
    required this.totalSteps,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(totalSteps, (i) {
        final isCompleted = i < currentStep;
        final isActive = i == currentStep;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: isCompleted
                    ? AppTheme.sparkGreen
                    : isActive
                    ? AppTheme.primary
                    : AppTheme.surfaceGlass,
              ),
            ),
          ),
        );
      }),
    );
  }
}
