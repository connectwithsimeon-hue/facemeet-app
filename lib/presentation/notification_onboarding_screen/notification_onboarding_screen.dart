import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/web_push_notification_service.dart';
import '../../theme/app_theme.dart';

class NotificationOnboardingScreen extends StatefulWidget {
  const NotificationOnboardingScreen({super.key});

  @override
  State<NotificationOnboardingScreen> createState() =>
      _NotificationOnboardingScreenState();
}

class _NotificationOnboardingScreenState
    extends State<NotificationOnboardingScreen> {
  bool _checking = true;
  bool _enabling = false;
  String? _statusTitle;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _checkNotificationState();
  }

  Future<void> _checkNotificationState() async {
    final state = await WebPushNotificationService.instance.currentSetupState();
    if (!mounted) return;
    if (state.success && state.status == 'Notifications enabled') {
      _goToApp();
      return;
    }
    setState(() {
      _checking = false;
      _statusTitle = state.status;
      _statusMessage = _gateMessageForState(state);
    });
  }

  Future<void> _enableNotifications() async {
    if (_enabling) return;
    setState(() {
      _enabling = true;
      _statusTitle = 'Enabling notifications...';
      _statusMessage = null;
    });

    final result = await WebPushNotificationService.instance
        .enableNotifications();
    if (!mounted) return;

    if (result.success && result.status == 'Notifications enabled') {
      setState(() {
        _enabling = false;
        _statusTitle = 'Notifications enabled';
        _statusMessage =
            'You will now get alerts for Sparks, sessions, chats, and messages.';
      });
      await Future.delayed(const Duration(milliseconds: 850));
      if (mounted) _goToApp();
      return;
    }

    setState(() {
      _enabling = false;
      _statusTitle = result.status;
      _statusMessage = _gateMessageForState(result);
    });
  }

  String _gateMessageForState(WebPushSetupResult state) {
    switch (state.status) {
      case 'Notifications blocked':
        return 'Notifications are blocked. Please enable them in your browser settings.';
      case 'Notifications are not supported':
        return 'Notifications are not supported on this browser.';
      case 'Could not finish enabling notifications':
        return 'Could not finish enabling notifications. Please try again.';
      default:
        return state.message;
    }
  }

  void _goToApp() {
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.discoveryFeedScreen,
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF24100D), Color(0xFF0D0D0F)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundVariant.withAlpha(242),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppTheme.borderGlass),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withAlpha(90),
                        blurRadius: 28,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withAlpha(28),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Icon(
                          Icons.notifications_active_rounded,
                          color: AppTheme.primary,
                          size: 34,
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Turn on notifications',
                        style: GoogleFonts.dmSans(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textPrimary,
                          height: 1.05,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'FaceMeet needs notifications so you don’t miss Sparks, Spark Sessions, chats, or messages.',
                        style: GoogleFonts.dmSans(
                          fontSize: 16,
                          color: AppTheme.textSecondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Turn on notifications to continue.',
                        style: GoogleFonts.dmSans(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      _buildIPhoneHelper(),
                      const SizedBox(height: 22),
                      if (_checking)
                        const Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.primary,
                          ),
                        )
                      else
                        ElevatedButton(
                          onPressed: _enabling ? null : _enableNotifications,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primary,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: AppTheme.primary.withAlpha(
                              120,
                            ),
                            minimumSize: const Size.fromHeight(54),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(18),
                            ),
                            elevation: 0,
                          ),
                          child: _enabling
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      'Enabling notifications...',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                )
                              : Text(
                                  'Enable Notifications',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                        ),
                      if (_statusTitle != null || _statusMessage != null) ...[
                        const SizedBox(height: 18),
                        _buildStatusCard(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIPhoneHelper() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.phone_iphone_rounded,
            color: AppTheme.textMuted,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'On iPhone, notifications work after FaceMeet is added to your Home Screen and opened from the app icon.',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.textMuted,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final isGood = _statusTitle == 'Notifications enabled';
    final isBlocked =
        _statusTitle == 'Notifications blocked' ||
        _statusTitle == 'Notifications are not supported';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isGood
            ? AppTheme.sparkGreen.withAlpha(22)
            : isBlocked
            ? AppTheme.error.withAlpha(22)
            : AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isGood
              ? AppTheme.sparkGreen.withAlpha(90)
              : isBlocked
              ? AppTheme.error.withAlpha(90)
              : AppTheme.borderGlass,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_statusTitle != null)
            Text(
              _statusTitle!,
              style: GoogleFonts.dmSans(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: isGood
                    ? AppTheme.sparkGreen
                    : isBlocked
                    ? AppTheme.error
                    : AppTheme.textPrimary,
              ),
            ),
          if (_statusMessage != null && _statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _statusMessage!,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
