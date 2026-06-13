import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/content_filter_service.dart';
import '../services/supabase_service.dart';
import '../theme/app_theme.dart';

const List<String> kReportReasons = [
  'Harassment or abuse',
  'Fake profile / catfish',
  'Sexual content / nudity',
  'Minor safety concern',
  'Scam or spam',
  'Other',
];

class UserSafetyActionButtons extends StatelessWidget {
  final String reportedUserId;
  final String reportedUserName;
  final String source;
  final String? matchId;
  final String? contextNote;
  final VoidCallback? onReported;
  final VoidCallback? onBlocked;
  final Axis direction;

  const UserSafetyActionButtons({
    super.key,
    required this.reportedUserId,
    required this.reportedUserName,
    required this.source,
    this.matchId,
    this.contextNote,
    this.onReported,
    this.onBlocked,
    this.direction = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context) {
    final buttons = [
      _SafetyButton(
        icon: Icons.flag_outlined,
        label: 'Report User',
        onTap: () async {
          final submitted = await showReportUserSheet(
            context,
            reportedUserId: reportedUserId,
            reportedUserName: reportedUserName,
            source: source,
            matchId: matchId,
            contextNote: contextNote,
          );
          if (submitted) onReported?.call();
        },
      ),
      _SafetyButton(
        icon: Icons.block_rounded,
        label: 'Block User',
        destructive: true,
        onTap: () async {
          final blocked = await showBlockUserDialog(
            context,
            blockedUserId: reportedUserId,
            blockedUserName: reportedUserName,
            source: source,
            matchId: matchId,
          );
          if (blocked) onBlocked?.call();
        },
      ),
    ];

    if (direction == Axis.vertical) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [buttons[0], const SizedBox(height: 8), buttons[1]],
      );
    }

    return Row(
      children: [
        Expanded(child: buttons[0]),
        const SizedBox(width: 10),
        Expanded(child: buttons[1]),
      ],
    );
  }
}

Future<bool> showReportUserSheet(
  BuildContext context, {
  required String reportedUserId,
  required String reportedUserName,
  required String source,
  String? matchId,
  String? contextNote,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ReportUserSheet(
      reportedUserId: reportedUserId,
      reportedUserName: reportedUserName,
      source: source,
      matchId: matchId,
      contextNote: contextNote,
    ),
  );
  return result == true;
}

Future<bool> showBlockUserDialog(
  BuildContext context, {
  required String blockedUserId,
  required String blockedUserName,
  required String source,
  String? matchId,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Text(
        'Block User',
        style: GoogleFonts.dmSans(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
      content: Text(
        'Block $blockedUserName? They will no longer appear in your feed, and chat will be unavailable.',
        style: GoogleFonts.dmSans(color: AppTheme.textSecondary, height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(
            'Cancel',
            style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            'Block User',
            style: GoogleFonts.dmSans(
              color: AppTheme.error,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return false;

  try {
    await SupabaseService.instance.blockUser(
      blockedUserId: blockedUserId,
      source: source,
      matchId: matchId,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'User blocked. They will no longer appear in your feed.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.sparkGreen,
          duration: const Duration(seconds: 3),
        ),
      );
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not block user. Please try again.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    }
    return false;
  }
}

class _ReportUserSheet extends StatefulWidget {
  final String reportedUserId;
  final String reportedUserName;
  final String source;
  final String? matchId;
  final String? contextNote;

  const _ReportUserSheet({
    required this.reportedUserId,
    required this.reportedUserName,
    required this.source,
    this.matchId,
    this.contextNote,
  });

  @override
  State<_ReportUserSheet> createState() => _ReportUserSheetState();
}

class _ReportUserSheetState extends State<_ReportUserSheet> {
  final TextEditingController _detailsCtrl = TextEditingController();
  String _reason = kReportReasons.first;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    try {
      await SupabaseService.instance.submitUserReport(
        reportedUserId: widget.reportedUserId,
        reason: _reason,
        details: _combinedDetails,
        source: widget.source,
        matchId: widget.matchId,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Report submitted. FaceMeet will review it within 24 hours.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.sparkGreen,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not submit report. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  String? get _combinedDetails {
    final contextNote = widget.contextNote?.trim();
    final userDetails = _detailsCtrl.text.trim();
    if ((contextNote == null || contextNote.isEmpty) && userDetails.isEmpty) {
      return null;
    }
    if (contextNote == null || contextNote.isEmpty) return userDetails;
    if (userDetails.isEmpty) return contextNote;
    return '$contextNote\n\nUser details:\n$userDetails';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3E),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Report User',
                style: GoogleFonts.dmSans(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tell us why ${widget.reportedUserName} should be reviewed. Reports are sent to FaceMeet moderation.',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 16),
              ...kReportReasons.map((reason) {
                final isSelected = _reason == reason;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _reason = reason),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Icon(
                          isSelected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: isSelected
                              ? AppTheme.primary
                              : AppTheme.textMuted,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            reason,
                            style: GoogleFonts.dmSans(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 8),
              TextField(
                controller: _detailsCtrl,
                maxLines: 3,
                maxLength: 300,
                style: GoogleFonts.dmSans(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  labelText: 'Details (optional)',
                  helperText: ContentFilterService.violationMessage,
                  helperMaxLines: 2,
                  helperStyle: GoogleFonts.dmSans(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                  labelStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
                  filled: true,
                  fillColor: AppTheme.surfaceGlass,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.borderGlass),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.borderGlass),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.primary),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _isSubmitting ? null : _submit,
                  icon: _isSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.flag_outlined, size: 18),
                  label: Text(
                    _isSubmitting ? 'Submitting…' : 'Submit Report',
                    style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SafetyButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _SafetyButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppTheme.error : AppTheme.textSecondary;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16, color: color),
      label: Text(
        label,
        style: GoogleFonts.dmSans(
          color: color,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: destructive ? const Color(0x66FF4458) : AppTheme.borderGlass,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
