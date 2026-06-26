import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/user_safety_actions.dart';

class ProfessionalSparkRevealScreen extends StatefulWidget {
  final String? senderUserId;

  const ProfessionalSparkRevealScreen({super.key, required this.senderUserId});

  @override
  State<ProfessionalSparkRevealScreen> createState() =>
      _ProfessionalSparkRevealScreenState();
}

class _ProfessionalSparkRevealScreenState
    extends State<ProfessionalSparkRevealScreen> {
  bool _isLoading = true;
  bool _isSparkingBack = false;
  String? _error;
  Map<String, dynamic>? _profile;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final senderUserId = widget.senderUserId?.trim();
    if (senderUserId == null || senderUserId.isEmpty) {
      setState(() {
        _isLoading = false;
        _error = 'This professional Spark could not be opened.';
      });
      return;
    }

    try {
      final blocked = await SupabaseService.instance.hasBlockBetween(
        senderUserId,
      );
      final profile = blocked
          ? null
          : await SupabaseService.instance.getUserProfile(senderUserId);

      if (!mounted) return;
      if (blocked ||
          !SupabaseService.instance.isUserFacingProfileAvailable(profile)) {
        setState(() {
          _isLoading = false;
          _error = 'This profile is no longer available.';
        });
        return;
      }

      setState(() {
        _profile = profile;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load this profile. Please try again.';
      });
    }
  }

  Future<void> _sparkBack() async {
    final senderUserId = widget.senderUserId?.trim();
    final currentUserId = SupabaseService.instance.currentUserId;
    if (_isSparkingBack ||
        senderUserId == null ||
        senderUserId.isEmpty ||
        currentUserId == null) {
      return;
    }

    setState(() => _isSparkingBack = true);
    try {
      var matchRow = await SupabaseService.instance.getExistingMatch(
        user1Id: currentUserId,
        user2Id: senderUserId,
      );

      if (matchRow == null) {
        try {
          await SupabaseService.instance.saveInteraction(
            toUserId: senderUserId,
            actionType: 'spark',
            sparkType: 'professional',
          );
        } catch (e) {
          final message = e.toString().toLowerCase();
          if (!message.contains('duplicate') &&
              !message.contains('unique') &&
              !message.contains('already')) {
            rethrow;
          }
        }

        final isMutual = await SupabaseService.instance.checkMutualSpark(
          senderUserId,
        );
        if (isMutual) {
          matchRow = await SupabaseService.instance.getExistingMatch(
            user1Id: currentUserId,
            user2Id: senderUserId,
          );
          matchRow ??= await SupabaseService.instance.createMatch(
            user1Id: currentUserId,
            user2Id: senderUserId,
          );
        }
      }

      if (!mounted) return;
      final matchId = matchRow?['id'] as String?;
      final status = matchRow?['status'] as String? ?? '';
      if (matchId != null && matchId.isNotEmpty && status != 'chat_unlocked') {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.sparkSessionScreen,
          (route) => false,
          arguments: {'matchId': matchId, 'matchedUserId': senderUserId},
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Professional Spark sent.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.sparkGreen,
        ),
      );
      Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.discoveryFeedScreen,
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isSparkingBack = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not Spark back. Please try again.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  void _goToDiscover() {
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.discoveryFeedScreen,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final firstName = profile?['first_name'] as String? ?? 'Someone';
    final age = (profile?['age'] as num?)?.toInt();
    final city =
        (profile?['location_display_name'] as String?)?.trim().isNotEmpty ==
            true
        ? profile!['location_display_name'] as String
        : (profile?['city'] as String?) ?? '';
    final thumbnailUrl = profile?['thumbnail_url'] as String?;
    final bio = profile?['bio'] as String? ?? '';
    final connectionIntent = SupabaseService.connectionIntentCardLabel(
      profile?['connection_intent'] as String?,
    );
    final interests =
        (profile?['interests'] as List?)
            ?.map((item) => item.toString())
            .where((item) => item.trim().isNotEmpty)
            .toList() ??
        <String>[];

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: SafeArea(
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.primary),
              )
            : _error != null
            ? _ErrorState(message: _error!, onClose: _goToDiscover)
            : SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        onPressed: _goToDiscover,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1E),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(
                          color: const Color(0x33E8503A),
                          width: 1,
                        ),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0x1AE8503A),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              'Professional Connection Spark',
                              style: GoogleFonts.dmSans(
                                color: AppTheme.primary,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 22),
                          ProfileAvatar(
                            thumbnailUrl: thumbnailUrl,
                            firstName: firstName,
                            radius: 58,
                            borderColor: AppTheme.primary,
                          ),
                          const SizedBox(height: 18),
                          Text(
                            age == null ? firstName : '$firstName, $age',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.outfit(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 28,
                            ),
                          ),
                          if (city.trim().isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              city,
                              textAlign: TextAlign.center,
                              style: GoogleFonts.dmSans(
                                color: AppTheme.textSecondary,
                                fontSize: 14,
                              ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          _IntentChip(label: connectionIntent),
                          const SizedBox(height: 22),
                          Text(
                            bio.trim().isEmpty
                                ? '$firstName sent you a professional Spark. Review their profile and Spark back if you want to connect.'
                                : bio,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.dmSans(
                              color: const Color(0xFFD8D8DC),
                              fontSize: 15,
                              height: 1.55,
                            ),
                          ),
                          if (interests.isNotEmpty) ...[
                            const SizedBox(height: 22),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: interests.take(8).map((interest) {
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.10,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    interest,
                                    style: GoogleFonts.dmSans(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    ElevatedButton(
                      onPressed: _isSparkingBack ? null : _sparkBack,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFF4B2A25),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: _isSparkingBack
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(
                              'Spark Back',
                              style: GoogleFonts.dmSans(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: _isSparkingBack ? null : _goToDiscover,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0x33FFFFFF)),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: Text(
                        'Not Interested',
                        style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 18),
                    UserSafetyActionButtons(
                      reportedUserId: widget.senderUserId!,
                      reportedUserName: firstName,
                      source: 'professional_spark',
                      direction: Axis.vertical,
                      onBlocked: _goToDiscover,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _IntentChip extends StatelessWidget {
  final String label;

  const _IntentChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x1A3AD29F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x333AD29F)),
      ),
      child: Text(
        label,
        style: GoogleFonts.dmSans(
          color: AppTheme.sparkGreen,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onClose;

  const _ErrorState({required this.message, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.work_outline_rounded,
              color: AppTheme.primary,
              size: 42,
            ),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontSize: 16,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: onClose,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
              child: Text(
                'Back to Discover',
                style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
