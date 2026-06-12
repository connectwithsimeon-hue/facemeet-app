import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import '../auth_screen/widgets/auth_particle_background_widget.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key});

  @override
  State<EmailVerificationScreen> createState() =>
      _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen>
    with SingleTickerProviderStateMixin {
  bool _isResending = false;
  bool _isChecking = false;
  String? _email;
  String? _passwordForVerificationSignIn;
  late AnimationController _iconController;
  late Animation<double> _iconScale;
  StreamSubscription<AuthState>? _authSubscription;

  @override
  void initState() {
    super.initState();
    // currentUser may be null when email confirmation is required (no session yet)
    _email = SupabaseService.instance.currentUser?.email;
    _iconController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _iconScale = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.easeOutBack),
    );
    _iconController.forward();

    // Check immediately in case the user was already verified (e.g. opened via deep link)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkIfAlreadyVerified();
    });

    // Listen for auth state changes (user verifies email in another tab/app or via deep link)
    _authSubscription = SupabaseService.instance.authStateChanges.listen((
      event,
    ) {
      if (!mounted) return;
      if (event.event == AuthChangeEvent.userUpdated ||
          event.event == AuthChangeEvent.signedIn) {
        final user = event.session?.user;
        if (user != null && user.emailConfirmedAt != null) {
          _navigateAfterVerification();
        }
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pick up the email passed as a route argument (set during sign-up navigation)
    final arg = ModalRoute.of(context)?.settings.arguments;
    if (arg is String && arg.isNotEmpty) {
      _email = arg;
    } else if (arg is Map<String, dynamic>) {
      final email = arg['email'] as String?;
      final password = arg['password'] as String?;
      if (email != null && email.isNotEmpty) {
        _email = email;
      }
      if (password != null && password.isNotEmpty) {
        _passwordForVerificationSignIn = password;
      }
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _iconController.dispose();
    super.dispose();
  }

  /// Check if the user is already verified when the screen first loads.
  /// This handles the case where the app was opened via the deep link and
  /// the session was already set before this screen was pushed.
  Future<void> _checkIfAlreadyVerified() async {
    debugPrint('EMAIL VERIFY: verification check started — automatic=true');
    try {
      final user = await _refreshAndRefetchUser();
      final confirmed = user?.emailConfirmedAt != null;
      debugPrint('EMAIL VERIFY: email confirmed $confirmed');
      if (confirmed && mounted) {
        debugPrint('EMAIL VERIFY: verification success — automatic=true');
        await _navigateAfterVerification();
      }
    } catch (e) {
      debugPrint(
        'EMAIL VERIFY: verification failed — automatic=true, error=$e',
      );
      // Non-critical — user can tap "I've verified" manually
    }
  }

  Future<void> _navigateAfterVerification() async {
    if (!mounted) return;
    final isComplete = await SupabaseService.instance.isOnboardingComplete();
    final route = AppRoutes.routeAfterAuth(onboardingComplete: isComplete);
    debugPrint('EMAIL VERIFY: navigation after verification — route=$route');
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, route, (route) => false);
  }

  Future<void> _checkVerification() async {
    setState(() => _isChecking = true);
    debugPrint('EMAIL VERIFY: verification check started — manual=true');
    try {
      User? user = await _refreshAndRefetchUser();
      var confirmed = user?.emailConfirmedAt != null;

      if (!confirmed) {
        user = await _signInAfterCrossDeviceVerification();
        confirmed = user?.emailConfirmedAt != null;
      }

      debugPrint('EMAIL VERIFY: email confirmed $confirmed');

      if (confirmed) {
        debugPrint('EMAIL VERIFY: verification success — manual=true');
        await _navigateAfterVerification();
      } else if (SupabaseService.instance.currentUser == null &&
          (_passwordForVerificationSignIn == null ||
              _passwordForVerificationSignIn!.isEmpty)) {
        debugPrint(
          'EMAIL VERIFY: verification failed — user signed out, prompting login',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Your email is verified. Please sign in to continue.',
                style: GoogleFonts.dmSans(),
              ),
              backgroundColor: AppTheme.sparkGreen,
            ),
          );
          Navigator.pushNamedAndRemoveUntil(
            context,
            AppRoutes.authScreen,
            (route) => false,
          );
        }
      } else {
        debugPrint('EMAIL VERIFY: verification failed — manual=true');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Email not verified yet. Please check your inbox.',
                style: GoogleFonts.dmSans(),
              ),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('EMAIL VERIFY: verification failed — manual=true, error=$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not check verification status. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
    if (mounted) setState(() => _isChecking = false);
  }

  Future<User?> _refreshAndRefetchUser() async {
    User? user;
    try {
      final response = await SupabaseService.instance.client.auth
          .refreshSession();
      debugPrint('EMAIL VERIFY: session refreshed — success=true');
      user = response.user ?? SupabaseService.instance.currentUser;
    } catch (e) {
      debugPrint('EMAIL VERIFY: session refreshed — success=false, error=$e');
    }

    try {
      final userResponse = await SupabaseService.instance.client.auth.getUser();
      user = userResponse.user;
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — success=true, hasUser=${user != null}',
      );
    } catch (e) {
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — success=false, error=$e',
      );
    }

    return user;
  }

  Future<User?> _signInAfterCrossDeviceVerification() async {
    final email = _email;
    final password = _passwordForVerificationSignIn;
    if (email == null ||
        email.isEmpty ||
        password == null ||
        password.isEmpty) {
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — sign-in fallback skipped, missing in-memory credentials',
      );
      return SupabaseService.instance.currentUser;
    }

    try {
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — trying sign-in fallback after cross-device verification',
      );
      final response = await SupabaseService.instance.client.auth
          .signInWithPassword(email: email, password: password);
      final user = response.user ?? SupabaseService.instance.currentUser;
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — sign-in fallback success=${user != null}',
      );
      return user;
    } on AuthException catch (e) {
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — sign-in fallback auth error=${e.message}',
      );
      return SupabaseService.instance.currentUser;
    } catch (e) {
      debugPrint(
        'EMAIL VERIFY: user reloaded/refetched — sign-in fallback error=$e',
      );
      return SupabaseService.instance.currentUser;
    }
  }

  Future<void> _resendVerification() async {
    // Use the email from route arguments or from the current user
    final email = _email ?? SupabaseService.instance.currentUser?.email;
    if (email == null || email.isEmpty) return;
    setState(() => _isResending = true);
    try {
      await SupabaseService.instance.client.auth.resend(
        type: OtpType.signup,
        email: email,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Verification email resent to $email',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.sparkGreen,
          ),
        );
      }
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message, style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to resend email. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
    if (mounted) setState(() => _isResending = false);
  }

  Future<void> _signOut() async {
    await SupabaseService.instance.signOut();
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(
        context,
        AppRoutes.authScreen,
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width >= 600;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          const AuthParticleBackgroundWidget(),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isTablet ? 480 : double.infinity,
                ),
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 60),
                        // Animated email icon
                        ScaleTransition(
                          scale: _iconScale,
                          child: Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [Color(0xFFE8503A), Color(0xFFD43F27)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primary.withAlpha(89),
                                  blurRadius: 28,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.mark_email_unread_outlined,
                              color: Colors.white,
                              size: 48,
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Text(
                          'Check your email',
                          style: GoogleFonts.dmSans(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                            letterSpacing: -0.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'We sent a verification link to',
                          style: GoogleFonts.dmSans(
                            fontSize: 15,
                            color: AppTheme.textMuted,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _email ?? '',
                          style: GoogleFonts.dmSans(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                          ),
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Click the link in the email to verify your account before continuing.',
                          style: GoogleFonts.dmSans(
                            fontSize: 14,
                            color: AppTheme.textMuted,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 36),
                        // I've verified button
                        _ActionButton(
                          label: "I've verified my email",
                          isLoading: _isChecking,
                          isPrimary: true,
                          onTap: _checkVerification,
                        ),
                        const SizedBox(height: 14),
                        // Resend button
                        _ActionButton(
                          label: 'Resend verification email',
                          isLoading: _isResending,
                          isPrimary: false,
                          onTap: _resendVerification,
                        ),
                        const SizedBox(height: 28),
                        GestureDetector(
                          onTap: _signOut,
                          child: Text(
                            'Use a different account',
                            style: GoogleFonts.dmSans(
                              fontSize: 13,
                              color: AppTheme.textMuted,
                              decoration: TextDecoration.underline,
                              decorationColor: AppTheme.textMuted,
                            ),
                          ),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final bool isLoading;
  final bool isPrimary;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.isLoading,
    required this.isPrimary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isLoading ? null : onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              gradient: isPrimary
                  ? const LinearGradient(
                      colors: [Color(0xFFE8503A), Color(0xFFD43F27)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    )
                  : null,
              color: isPrimary ? null : AppTheme.surfaceGlass,
              borderRadius: BorderRadius.circular(16),
              border: isPrimary
                  ? null
                  : Border.all(color: AppTheme.borderGlass, width: 1),
              boxShadow: isPrimary
                  ? [
                      BoxShadow(
                        color: AppTheme.primary.withAlpha(89),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ]
                  : null,
            ),
            child: Center(
              child: isLoading
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isPrimary ? Colors.white : AppTheme.primary,
                        ),
                      ),
                    )
                  : Text(
                      label,
                      style: GoogleFonts.dmSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isPrimary ? Colors.white : AppTheme.textPrimary,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
