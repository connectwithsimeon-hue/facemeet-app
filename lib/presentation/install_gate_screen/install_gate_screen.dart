import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../routes/app_routes.dart';
import '../../services/install_gate_service.dart';
import '../../theme/app_theme.dart';

class InstallGateScreen extends StatefulWidget {
  const InstallGateScreen({super.key});

  @override
  State<InstallGateScreen> createState() => _InstallGateScreenState();
}

class _InstallGateScreenState extends State<InstallGateScreen> {
  InstallGateContext? _context;
  bool _loading = true;
  bool _installing = false;
  final List<Timer> _contextRefreshTimers = [];

  @override
  void initState() {
    super.initState();
    _loadContext();
    _scheduleInstallContextRefreshes();
  }

  @override
  void dispose() {
    for (final timer in _contextRefreshTimers) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _loadContext() async {
    final contextData = await InstallGateService.instance.currentContext();
    if (!mounted) return;

    if (!contextData.shouldShowInstallGate) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.authScreen,
        (route) => false,
      );
      return;
    }

    setState(() {
      _context = contextData;
      _loading = false;
    });
  }

  void _scheduleInstallContextRefreshes() {
    for (final delay in const [
      Duration(milliseconds: 300),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ]) {
      _contextRefreshTimers.add(
        Timer(delay, () {
          if (!mounted) return;
          final current = _context;
          if (current != null && current.canPromptInstall) return;
          _loadContext();
        }),
      );
    }
  }

  Future<void> _handleInstall() async {
    if (_installing) return;
    setState(() => _installing = true);
    final result = await InstallGateService.instance.promptInstall();
    if (!mounted) return;
    setState(() => _installing = false);

    if (result.outcome == 'accepted' || result.outcome == 'prompted') {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Install prompt not available yet. Tap the install icon in the address bar, or tap the three dots and choose Install app.',
          style: GoogleFonts.dmSans(),
        ),
        backgroundColor: AppTheme.backgroundVariant,
      ),
    );
  }

  Future<void> _continueInBrowser() async {
    await InstallGateService.instance.allowContinueInBrowserForSession();
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.authScreen,
      (route) => false,
    );
  }

  Widget _buildIosInstructions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _instructionLine('1. Open FaceMeet in Safari'),
        _instructionLine('2. Tap the Share button'),
        _instructionLine('3. Tap Add to Home Screen'),
        _instructionLine('4. Tap Add'),
        _instructionLine('5. Open FaceMeet from your Home Screen'),
      ],
    );
  }

  Widget _buildAndroidInstructions(bool canPromptInstall) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          canPromptInstall
              ? 'Tap Install to add FaceMeet to your phone. Then open FaceMeet from your app screen.'
              : 'Tap the install icon in the address bar, or tap the three dots and choose Install app or Add to Home Screen.',
          style: GoogleFonts.dmSans(
            fontSize: 15,
            height: 1.5,
            color: AppTheme.textSecondary,
          ),
        ),
        if (canPromptInstall) ...[
          const SizedBox(height: 18),
          ElevatedButton(
            onPressed: _installing ? null : _handleInstall,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(54),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              elevation: 0,
            ),
            child: _installing
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
                        'Opening install prompt...',
                        style: GoogleFonts.dmSans(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                : Text(
                    'Install FaceMeet',
                    style: GoogleFonts.dmSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _instructionLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: GoogleFonts.dmSans(
          fontSize: 15,
          height: 1.5,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final installContext = _context;

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
                constraints: const BoxConstraints(maxWidth: 520),
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
                  child: _loading || installContext == null
                      ? const Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.primary,
                          ),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withAlpha(28),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Icon(
                                Icons.install_mobile_rounded,
                                color: AppTheme.primary,
                                size: 34,
                              ),
                            ),
                            const SizedBox(height: 22),
                            Text(
                              'Install FaceMeet',
                              style: GoogleFonts.dmSans(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.textPrimary,
                                height: 1.05,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'FaceMeet works best as an app so you don’t miss Sparks, Spark Sessions, chats, or messages.',
                              style: GoogleFonts.dmSans(
                                fontSize: 16,
                                color: AppTheme.textSecondary,
                                height: 1.5,
                              ),
                            ),
                            if (installContext
                                .pendingReferralCode
                                .isNotEmpty) ...[
                              const SizedBox(height: 18),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: AppTheme.primary.withAlpha(18),
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: AppTheme.primary.withAlpha(64),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'After installing, open FaceMeet from your Home Screen. Your invite code is saved.',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 14,
                                        height: 1.5,
                                        color: AppTheme.textPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Invite code: ${installContext.pendingReferralCode}',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 14,
                                        height: 1.4,
                                        color: AppTheme.primary,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (installContext.isIos) ...[
                                      const SizedBox(height: 8),
                                      Text(
                                        'If you are asked later, enter this code after signup.',
                                        style: GoogleFonts.dmSans(
                                          fontSize: 13,
                                          height: 1.45,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 24),
                            if (installContext.isIos) _buildIosInstructions(),
                            if (installContext.isAndroid)
                              _buildAndroidInstructions(
                                installContext.canPromptInstall,
                              ),
                            if (!installContext.isIos &&
                                !installContext.isAndroid)
                              Text(
                                'Install FaceMeet from your browser menu, then open it from your Home Screen or app launcher.',
                                style: GoogleFonts.dmSans(
                                  fontSize: 15,
                                  height: 1.5,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            const SizedBox(height: 20),
                            Center(
                              child: TextButton(
                                onPressed: _continueInBrowser,
                                child: Text(
                                  'Having trouble? Continue in browser',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ),
                            ),
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
}
