import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../routes/app_routes.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';
import './widgets/auth_form_widget.dart';
import './widgets/auth_particle_background_widget.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  bool _isLogin = true;
  bool _isLoading = false;
  bool _acceptedTerms = false;
  bool _showPasswordResetConfirmation = false;
  String? _passwordResetEmail;
  late AnimationController _logoController;
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;

  // TODO: Replace with Supabase auth client for production
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  // Google Sign-In setup per Section 11.5.3
  static const String _webClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: _webClientId,
    serverClientId: _webClientId,
    scopes: ['email', 'profile'],
  );

  @override
  void initState() {
    super.initState();
    _logoController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _logoController, curve: Curves.easeOutBack),
    );
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _logoController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );
    _logoController.forward();
  }

  @override
  void dispose() {
    _logoController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleEmailAuth() async {
    if (!_ensureTermsAccepted()) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      if (_isLogin) {
        final response = await SupabaseService.instance.signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (response.user != null && mounted) {
          // Check if email is verified
          final user = response.user!;
          if (user.emailConfirmedAt == null) {
            // Email not verified — sign out and show message with resend option
            await SupabaseService.instance.signOut();
            if (mounted) {
              _showUnverifiedEmailDialog(_emailController.text.trim());
            }
          } else {
            final isComplete = await SupabaseService.instance
                .isOnboardingComplete();
            Navigator.pushNamedAndRemoveUntil(
              context,
              AppRoutes.routeAfterAuth(onboardingComplete: isComplete),
              (route) => false,
            );
          }
        }
      } else {
        final response = await SupabaseService.instance.signUp(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
        if (response.user != null && mounted) {
          // Navigate to email verification screen
          Navigator.pushNamedAndRemoveUntil(
            context,
            AppRoutes.emailVerificationScreen,
            (route) => false,
            arguments: {
              'email': _emailController.text.trim(),
              'password': _passwordController.text,
            },
          );
        }
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
              'Something went wrong. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _showUnverifiedEmailDialog(String email) {
    bool isResending = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.backgroundVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: AppTheme.borderGlass, width: 1),
          ),
          title: Row(
            children: [
              const Icon(
                Icons.mark_email_unread_outlined,
                color: AppTheme.primary,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Email not verified',
                  style: GoogleFonts.dmSans(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          content: Text(
            'Please verify your email first. Check your inbox for the verification link we sent to $email.',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textMuted,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'OK',
                style: GoogleFonts.dmSans(
                  color: AppTheme.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            TextButton(
              onPressed: isResending
                  ? null
                  : () async {
                      setDialogState(() => isResending = true);
                      try {
                        await SupabaseService.instance.client.auth.resend(
                          type: OtpType.signup,
                          email: email,
                        );
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
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
                      } catch (_) {
                        setDialogState(() => isResending = false);
                      }
                    },
              child: isResending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppTheme.primary,
                        ),
                      ),
                    )
                  : Text(
                      'Resend link',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleGoogleSignIn() async {
    if (!_ensureTermsAccepted()) return;
    setState(() => _isLoading = true);
    try {
      final success = await SupabaseService.instance.signInWithGoogle();
      if (success && mounted) {
        final isComplete = await SupabaseService.instance
            .isOnboardingComplete();
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.routeAfterAuth(onboardingComplete: isComplete),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sign-in failed. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _handleAppleSignIn() async {
    if (kIsWeb) return;
    if (!_ensureTermsAccepted()) return;
    setState(() => _isLoading = true);
    try {
      await SupabaseService.instance.client.auth.signInWithOAuth(
        OAuthProvider.apple,
      );
      if (mounted) {
        final isComplete = await SupabaseService.instance
            .isOnboardingComplete();
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppRoutes.routeAfterAuth(onboardingComplete: isComplete),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Apple Sign-In failed. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  void _handleForgotPassword() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ForgotPasswordSheet(
        onSend: (email) async {
          try {
            await SupabaseService.instance.resetPassword(email);
            if (mounted) {
              Navigator.pop(context);
              setState(() {
                _isLogin = true;
                _showPasswordResetConfirmation = true;
                _passwordResetEmail = email;
              });
            }
          } catch (_) {}
          if (mounted && !_showPasswordResetConfirmation) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'We could not send the reset email. Please try again.',
                  style: GoogleFonts.dmSans(),
                ),
                backgroundColor: AppTheme.error,
              ),
            );
          }
        },
      ),
    );
  }

  bool _ensureTermsAccepted() {
    if (_acceptedTerms) return true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Please agree to the Terms of Use and Community Guidelines.',
          style: GoogleFonts.dmSans(),
        ),
        backgroundColor: AppTheme.error,
      ),
    );
    return false;
  }

  Future<void> _openLegalUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('LEGAL LINK: failed to open $url — $e');
    }
  }

  void _returnToSignInFromPasswordReset() {
    setState(() {
      _isLogin = true;
      _showPasswordResetConfirmation = false;
      _passwordResetEmail = null;
      _passwordController.clear();
    });
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
          // Particle background
          const AuthParticleBackgroundWidget(),
          // Gradient overlay removed — solid dark background preserved
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
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(height: 12),
                        // Logo
                        FadeTransition(
                          opacity: _logoFade,
                          child: ScaleTransition(
                            scale: _logoScale,
                            child: _buildLogo(),
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Glass card — BackdropFilter removed (causes blank screen on iOS release builds)
                        // Using solid dark container instead
                        ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xE6141416),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: AppTheme.borderGlass,
                                width: 1,
                              ),
                            ),
                            padding: const EdgeInsets.all(28),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_showPasswordResetConfirmation)
                                  _buildPasswordResetConfirmation()
                                else ...[
                                  // Toggle
                                  _buildToggle(),
                                  const SizedBox(height: 28),
                                  // Form
                                  AuthFormWidget(
                                    formKey: _formKey,
                                    emailController: _emailController,
                                    passwordController: _passwordController,
                                    isLogin: _isLogin,
                                    isLoading: _isLoading,
                                    acceptedTerms: _acceptedTerms,
                                    onAcceptedTermsChanged: (value) =>
                                        setState(() => _acceptedTerms = value),
                                    onTermsTap: () => _openLegalUrl(
                                      'https://facemeet.app/terms',
                                    ),
                                    onPrivacyTap: () => _openLegalUrl(
                                      'https://facemeet.app/privacy',
                                    ),
                                    onSubmit: _handleEmailAuth,
                                    onForgotPassword: _handleForgotPassword,
                                  ),
                                ],
                                const SizedBox(height: 24),
                                // Divider — commented out until social sign-in is re-enabled
                                // Row(
                                //   children: [
                                //     Expanded(
                                //       child: Divider(
                                //         color: AppTheme.borderGlass,
                                //       ),
                                //     ),
                                //     Padding(
                                //       padding: const EdgeInsets.symmetric(
                                //         horizontal: 12,
                                //       ),
                                //       child: Text(
                                //         'or',
                                //         style: GoogleFonts.dmSans(
                                //           fontSize: 13,
                                //           color: AppTheme.textMuted,
                                //         ),
                                //       ),
                                //     ),
                                //     Expanded(
                                //       child: Divider(
                                //         color: AppTheme.borderGlass,
                                //       ),
                                //     ),
                                //   ],
                                // ),
                                // const SizedBox(height: 20),
                                // Social buttons — commented out until re-enabled
                                // AuthSocialButtonsWidget(
                                //   onGoogleTap: _handleGoogleSignIn,
                                //   onAppleTap: kIsWeb
                                //       ? null
                                //       : _handleAppleSignIn,
                                //   isLoading: _isLoading,
                                // ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Legal
                        _buildLegalText(),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Removed blocking overlay — _isLoading is handled inline by buttons/form
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(102),
                blurRadius: 30,
                spreadRadius: 0,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(32),
            child: Image.asset(
              'assets/images/ChatGPT_Image_Apr_17__2026__08_07_43_PM-1776474490115.png',
              fit: BoxFit.fill,
            ),
          ),
        ),
        const SizedBox(height: 8),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'Face',
                style: GoogleFonts.dmSans(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFFF5ECD7),
                  letterSpacing: -0.5,
                ),
              ),
              TextSpan(
                text: 'Meet',
                style: GoogleFonts.dmSans(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFFE8503A),
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'See them before you swipe',
          style: GoogleFonts.dmSans(
            fontSize: 15,
            fontWeight: FontWeight.w400,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordResetConfirmation() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: AppTheme.primary.withAlpha(24),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.primary.withAlpha(90)),
          ),
          child: const Icon(
            Icons.mark_email_read_outlined,
            color: AppTheme.primary,
            size: 30,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          'Check your email',
          style: GoogleFonts.dmSans(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: AppTheme.textPrimary,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'We sent you a password reset link. Open the email and follow the instructions to reset your password.',
          style: GoogleFonts.dmSans(
            fontSize: 15,
            color: AppTheme.textSecondary,
            height: 1.55,
          ),
        ),
        if (_passwordResetEmail != null && _passwordResetEmail!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _passwordResetEmail!,
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          'After resetting your password, open the FaceMeet app from your Home Screen and sign in with your new password.',
          style: GoogleFonts.dmSans(
            fontSize: 13,
            color: AppTheme.textMuted,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            onPressed: _returnToSignInFromPasswordReset,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              elevation: 0,
            ),
            child: Text(
              'Back to Sign In',
              style: GoogleFonts.dmSans(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToggle() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _ToggleTab(
            label: 'Sign In',
            isActive: _isLogin,
            onTap: () => setState(() => _isLogin = true),
          ),
          _ToggleTab(
            label: 'Sign Up',
            isActive: !_isLogin,
            onTap: () => setState(() => _isLogin = false),
          ),
        ],
      ),
    );
  }

  Widget _buildLegalText() {
    return Text(
      'Safety reports are reviewed by FaceMeet moderation within 24 hours.',
      style: GoogleFonts.dmSans(
        fontSize: 12,
        color: AppTheme.textMuted,
        height: 1.5,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _ToggleTab extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ToggleTab({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isActive ? AppTheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 14,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive ? Colors.white : AppTheme.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForgotPasswordSheet extends StatefulWidget {
  final Function(String email) onSend;
  const _ForgotPasswordSheet({required this.onSend});

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  final _emailCtrl = TextEditingController();
  final _key = GlobalKey<FormState>();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: Container(
          color: const Color(0xE6141416),
          padding: const EdgeInsets.all(28),
          child: Form(
            key: _key,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Reset Password',
                  style: GoogleFonts.dmSans(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter your email and we\'ll send a reset link',
                  style: GoogleFonts.dmSans(
                    fontSize: 14,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: GoogleFonts.dmSans(color: Colors.white, fontSize: 15),
                  decoration: InputDecoration(
                    labelText: 'Email address',
                    prefixIcon: const Icon(
                      Icons.email_outlined,
                      color: AppTheme.textMuted,
                      size: 20,
                    ),
                  ),
                  validator: (v) => (v == null || !v.contains('@'))
                      ? 'Enter a valid email'
                      : null,
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    if (_key.currentState!.validate()) {
                      widget.onSend(_emailCtrl.text.trim());
                    }
                  },
                  child: const Text('Send Reset Link'),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
