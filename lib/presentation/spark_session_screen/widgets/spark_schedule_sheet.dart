import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

Future<bool> showSparkScheduleSheet(
  BuildContext context, {
  required String matchId,
  required String recipientUserId,
  required String recipientName,
  Map<String, dynamic>? schedule,
}) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SparkScheduleSheet(
      matchId: matchId,
      recipientUserId: recipientUserId,
      recipientName: recipientName,
      schedule: schedule,
    ),
  );
  return result == true;
}

class _SparkScheduleSheet extends StatefulWidget {
  final String matchId;
  final String recipientUserId;
  final String recipientName;
  final Map<String, dynamic>? schedule;

  const _SparkScheduleSheet({
    required this.matchId,
    required this.recipientUserId,
    required this.recipientName,
    this.schedule,
  });

  @override
  State<_SparkScheduleSheet> createState() => _SparkScheduleSheetState();
}

class _SparkScheduleSheetState extends State<_SparkScheduleSheet> {
  final List<DateTime> _slots = [];
  bool _isSaving = false;

  bool get _isCounter => widget.schedule != null;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _slots.addAll([
      now.add(const Duration(hours: 2)),
      DateTime(now.year, now.month, now.day + 1, 19),
      _nextWeekendEvening(now),
    ]);
  }

  static DateTime _nextWeekendEvening(DateTime now) {
    final daysUntilSaturday = (DateTime.saturday - now.weekday) % 7;
    final offset = daysUntilSaturday == 0 ? 7 : daysUntilSaturday;
    final date = now.add(Duration(days: offset));
    return DateTime(date.year, date.month, date.day, 19);
  }

  Future<void> _pickCustomTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppTheme.primary,
            surface: Color(0xFF1A1A1E),
          ),
        ),
        child: child!,
      ),
    );
    if (date == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 19, minute: 0),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(
            primary: AppTheme.primary,
            surface: Color(0xFF1A1A1E),
          ),
        ),
        child: child!,
      ),
    );
    if (time == null) return;

    final selected = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (selected.isBefore(now.add(const Duration(minutes: 10)))) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Choose a time at least 10 minutes from now.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _slots.insert(0, selected);
      _dedupeAndLimitSlots();
    });
  }

  void _removeSlot(DateTime slot) {
    setState(() => _slots.remove(slot));
  }

  void _dedupeAndLimitSlots() {
    final unique = _slots.map((slot) => slot.toUtc()).toSet().toList()..sort();
    _slots
      ..clear()
      ..addAll(unique.take(3).map((slot) => slot.toLocal()));
  }

  Future<void> _submit() async {
    if (_isSaving) return;
    _dedupeAndLimitSlots();
    if (_slots.isEmpty) return;

    setState(() => _isSaving = true);
    try {
      if (_isCounter) {
        await SupabaseService.instance.counterSparkSessionSchedule(
          scheduleId: widget.schedule!['id'] as String,
          notifyUserId: widget.recipientUserId,
          proposedTimes: _slots,
        );
      } else {
        await SupabaseService.instance.createSparkSessionSchedule(
          matchId: widget.matchId,
          recipientUserId: widget.recipientUserId,
          proposedTimes: _slots,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isCounter
                ? 'New intro times suggested.'
                : 'Intro times sent to ${widget.recipientName}.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.sparkGreen,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not schedule this intro. Please try again.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.fromLTRB(
        22,
        18,
        22,
        MediaQuery.of(context).viewInsets.bottom + 28,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFF3A3A3E),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              _isCounter ? 'Suggest another time' : 'Schedule 3-minute intro',
              style: GoogleFonts.outfit(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose up to 3 times. Times are shown in your local timezone.',
              style: GoogleFonts.dmSans(
                color: AppTheme.textSecondary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _PresetChip(
                  label: 'Later today',
                  onTap: () => setState(() {
                    _slots.insert(
                      0,
                      DateTime.now().add(const Duration(hours: 2)),
                    );
                    _dedupeAndLimitSlots();
                  }),
                ),
                _PresetChip(
                  label: 'Tomorrow',
                  onTap: () => setState(() {
                    final now = DateTime.now();
                    _slots.insert(
                      0,
                      DateTime(now.year, now.month, now.day + 1, 19),
                    );
                    _dedupeAndLimitSlots();
                  }),
                ),
                _PresetChip(
                  label: 'This weekend',
                  onTap: () => setState(() {
                    _slots.insert(0, _nextWeekendEvening(DateTime.now()));
                    _dedupeAndLimitSlots();
                  }),
                ),
                _PresetChip(label: 'Pick a time', onTap: _pickCustomTime),
              ],
            ),
            const SizedBox(height: 18),
            ..._slots.take(3).map((slot) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.schedule_rounded,
                      color: AppTheme.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        formatSparkScheduleTime(slot),
                        style: GoogleFonts.dmSans(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => _removeSlot(slot),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: AppTheme.textMuted,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 14),
            ElevatedButton(
              onPressed: _isSaving || _slots.isEmpty ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF4A2B2A),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      _isCounter ? 'Send new times' : 'Send schedule options',
                      style: GoogleFonts.dmSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PresetChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0x1AE8503A),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: const Color(0x33E8503A)),
        ),
        child: Text(
          label,
          style: GoogleFonts.dmSans(
            color: AppTheme.primary,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

String formatSparkScheduleTime(DateTime time) {
  final local = time.toLocal();
  final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final suffix = local.hour >= 12 ? 'PM' : 'AM';
  final month = _monthName(local.month);
  return '$month ${local.day}, $hour12:$minute $suffix';
}

String _monthName(int month) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return months[(month - 1).clamp(0, 11)];
}
