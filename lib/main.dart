import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import './presentation/main_shell_screen/main_shell_screen.dart';
import './providers/subscription_provider.dart';
import './services/presence_service.dart';
import './services/android_diagnostics_service.dart';
import './services/push_notification_service.dart';
import './services/revenuecat_service.dart';
import './services/supabase_service.dart';
import './services/install_gate_service.dart';
import './services/web_push_notification_service.dart';
import './widgets/custom_error_widget.dart';
import 'core/app_export.dart';

// FaceMeet v1.0

// Global flag — set to true ONLY when the user taps the Log Out button.
// The auth state listener checks this before navigating to the auth screen.
bool manualLogout = false;

// Bug 2: Global flag — set to true during payment flow to prevent
// spurious signedOut events from navigating to auth screen.
bool paymentInProgress = false;

/// Top-level background message handler — must be a top-level function.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Ensure Flutter bindings are available in the background isolate.
  WidgetsFlutterBinding.ensureInitialized();

  // CRITICAL: Firebase must be initialized in the background isolate before
  // any Firebase API (including FirebaseMessaging) is accessed.
  // Without this, iOS throws "Firebase has not been correctly initialized".
  try {
    await Firebase.initializeApp();
  } catch (e) {
    // Already initialized — safe to ignore.
    debugPrint('FIREBASE BG: initializeApp skipped (already initialized): $e');
  }

  await AndroidDiagnosticsService.instance.recordBackgroundMessage(
    Map<String, dynamic>.from(message.data),
  );

  final notification = message.notification;
  final title =
      notification?.title ?? message.data['title'] as String? ?? 'FaceMeet';
  final body = notification?.body ?? message.data['body'] as String? ?? '';

  // Show a local notification banner so the user sees it even when the app is closed.
  const channel = AndroidNotificationChannel(
    'facemeet_notifications',
    'FaceMeet Notifications',
    importance: Importance.max,
  );

  final plugin = FlutterLocalNotificationsPlugin();
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings();
  await plugin.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
  );

  final androidPlugin = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await androidPlugin?.createNotificationChannel(channel);

  await plugin.show(
    message.messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.name,
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: const DarwinNotificationDetails(),
    ),
  );
}

/// GlobalKey for MainShellScreen — reliable in both debug and release builds.
final GlobalKey<MainShellScreenState> mainShellKey =
    GlobalKey<MainShellScreenState>();

// Tracks whether background services have been initialized.
bool _servicesInitialized = false;

// Completer that resolves once Supabase (and Firebase) are ready.
// Auth listener and session check happen as soon as this completes.
final Completer<void> _servicesReady = Completer<void>();

// Completer that resolves once ALL services (including RevenueCat) are ready.
// PushNotificationService waits on this.
final Completer<void> _allServicesReady = Completer<void>();

// Tracks whether Firebase initialized successfully.
// PushNotificationService must NOT be created if this is false.
bool _firebaseInitialized = false;

// Navigator key exposed so SplashScreen can navigate after session check.
final GlobalKey<NavigatorState> _appNavigatorKey = GlobalKey<NavigatorState>();

/// SplashScreen — shown on launch while services initialize.
/// Navigates to home or auth based on currentSession after Supabase is ready.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _dotController;

  @override
  void initState() {
    super.initState();
    _dotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    _waitAndRoute();
  }

  @override
  void dispose() {
    _dotController.dispose();
    super.dispose();
  }

  Future<void> _waitAndRoute() async {
    // Wait for Supabase (and Firebase) to be ready.
    await _servicesReady.future;

    if (!mounted) return;

    // Immediately check currentSession — do NOT wait for RevenueCat.
    final session = Supabase.instance.client.auth.currentSession;
    final hasSession = session != null;
    debugPrint('SPLASH: Existing session found: $hasSession');

    if (hasSession) {
      debugPrint('SPLASH: Routing to home');
      try {
        final isComplete = await SupabaseService.instance
            .isOnboardingComplete();
        final professionalSparkSenderId = _professionalSparkSenderFromUrl(
          Uri.base,
        );
        final route = AppRoutes.routeAfterAuth(onboardingComplete: isComplete);
        if (mounted) {
          if (isComplete && professionalSparkSenderId != null) {
            Navigator.of(context).pushNamedAndRemoveUntil(
              AppRoutes.professionalSparkRevealScreen,
              (r) => false,
              arguments: {'senderUserId': professionalSparkSenderId},
            );
          } else {
            Navigator.of(context).pushNamedAndRemoveUntil(route, (r) => false);
          }
        }
      } catch (e) {
        debugPrint('SPLASH: Onboarding check failed, routing to home: $e');
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil(
            kIsWeb
                ? AppRoutes.notificationOnboardingScreen
                : AppRoutes.discoveryFeedScreen,
            (r) => false,
          );
        }
      }
    } else {
      if (kIsWeb) {
        debugPrint('SPLASH: Web/PWA detected — bypassing intro carousel');
        final shouldGateInstall = await InstallGateService.instance
            .shouldGateInstallFirst();
        if (mounted) {
          Navigator.of(context).pushNamedAndRemoveUntil(
            shouldGateInstall
                ? AppRoutes.installGateScreen
                : AppRoutes.authScreen,
            (r) => false,
          );
        }
        return;
      }

      // Check if the intro carousel has been seen before
      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool('intro_carousel_seen') ?? false;
      debugPrint('SPLASH: Intro carousel seen: $introSeen');
      if (mounted) {
        if (introSeen) {
          debugPrint('SPLASH: Routing to auth (intro already seen)');
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil(AppRoutes.authScreen, (r) => false);
        } else {
          debugPrint('SPLASH: Routing to intro carousel');
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil(AppRoutes.introCarousel, (r) => false);
        }
      }
    }
  }

  String? _professionalSparkSenderFromUrl(Uri uri) {
    final pushType = uri.queryParameters['push_type'];
    final sparkType = uri.queryParameters['spark_type'];
    final senderUserId = uri.queryParameters['sender_user_id']?.trim();
    if (pushType == 'new_spark' &&
        sparkType == 'professional' &&
        senderUserId != null &&
        senderUserId.isNotEmpty) {
      return senderUserId;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/images/facemeet_splash_logo-1778015584859.png',
              width: 240,
              height: 240,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.favorite,
                color: Color(0xFFE8503A),
                size: 120,
              ),
            ),
            const SizedBox(height: 24),
            _AnimatedLoadingText(controller: _dotController),
          ],
        ),
      ),
    );
  }
}

/// Animated "LOADING . . . ." text widget in FaceMeet brand colours.
/// The dots fade in one by one using the provided [AnimationController].
class _AnimatedLoadingText extends StatelessWidget {
  final AnimationController controller;

  const _AnimatedLoadingText({required this.controller});

  @override
  Widget build(BuildContext context) {
    // Each dot fades in at a staggered interval within the 0–1 animation cycle.
    final dot1 = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.0, 0.5, curve: Curves.easeIn),
    );
    final dot2 = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.2, 0.7, curve: Curves.easeIn),
    );
    final dot3 = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.4, 0.9, curve: Curves.easeIn),
    );
    final dot4 = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.6, 1.0, curve: Curves.easeIn),
    );

    const textStyle = TextStyle(
      fontFamily: 'Inter',
      fontSize: 16,
      fontWeight: FontWeight.w700,
      letterSpacing: 4.0,
      color: Color(0xFFE8503A),
    );

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('LOADING', style: textStyle),
            const SizedBox(width: 6),
            _buildDot(dot1.value, textStyle),
            _buildDot(dot2.value, textStyle),
            _buildDot(dot3.value, textStyle),
            _buildDot(dot4.value, textStyle),
          ],
        );
      },
    );
  }

  Widget _buildDot(double opacity, TextStyle style) {
    return Opacity(
      opacity: opacity.clamp(0.15, 1.0),
      child: Text(' .', style: style),
    );
  }
}

void main() {
  // Ensure bindings are ready — synchronous, no await needed.
  WidgetsFlutterBinding.ensureInitialized();

  // 🚨 CRITICAL: Custom error handling - DO NOT REMOVE
  bool hasShownError = false;
  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (!hasShownError) {
      hasShownError = true;
      Future.delayed(Duration(seconds: 5), () {
        hasShownError = false;
      });
      return CustomErrorWidget(errorDetails: details);
    }
    return SizedBox.shrink();
  };

  // runApp() is called immediately — no awaits before this line.
  // The auth screen renders on the first frame while services init in background.
  runApp(
    ChangeNotifierProvider(
      create: (_) => SubscriptionProvider(),
      child: MyApp(),
    ),
  );

  // All service initialization runs AFTER the first frame is painted.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _initializeServicesInBackground();
  });
}

/// Initialize all services in the background after the first frame renders.
/// This ensures the splash screen is visible immediately on launch.
Future<void> _initializeServicesInBackground() async {
  if (_servicesInitialized) return;
  _servicesInitialized = true;

  // 1. Orientation lock (non-critical, fire-and-forget on failure)
  if (!kIsWeb) {
    try {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
    } catch (e) {
      debugPrint(
        'ORIENTATION: setPreferredOrientations failed (non-critical): $e',
      );
    }
  }

  // 2. Firebase (native only)
  if (!kIsWeb) {
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      _firebaseInitialized = true;
      debugPrint('FIREBASE: initializeApp() succeeded.');
    } catch (e, st) {
      debugPrint('FIREBASE: initializeApp() FAILED with error: $e');
      debugPrint('FIREBASE: initializeApp() stack trace: $st');
      debugPrint(
        'FIREBASE: Push notifications will be disabled for this session.',
      );
    }
  }

  // 3. Supabase — CRITICAL: signal _servicesReady immediately after this
  // so the splash screen can check currentSession without waiting for RevenueCat.
  try {
    await SupabaseService.initialize();
    await SupabaseService.instance.testSupabaseConnection();
    debugPrint('SUPABASE: Initialized');
  } catch (e) {
    debugPrint('SUPABASE: Failed to initialize: $e');
  }

  // Signal that Supabase is ready — splash screen and auth listener can proceed NOW.
  debugPrint('BACKGROUND INIT: Supabase ready — signaling _servicesReady.');
  if (!_servicesReady.isCompleted) {
    _servicesReady.complete();
  }

  // 4. RevenueCat (native only) — runs AFTER session check is unblocked.
  // RevenueCat slowness or failure must NOT block auth/session restoration.
  if (!kIsWeb) {
    try {
      await RevenueCatService.initialize();
    } catch (e) {
      debugPrint('REVENUECAT: initialize failed (non-critical): $e');
    }
  }

  debugPrint('BACKGROUND INIT: All services initialized.');

  if (!_allServicesReady.isCompleted) {
    _allServicesReady.complete();
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final AppLinks _appLinks;

  // Tracks whether PushNotificationService has been started this session.
  // Prevents double-initialization if signedIn fires after startup already started it.
  bool _pushNotificationStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _captureReferralFromLaunchUrl();
    unawaited(_recoverPendingReferralCodeFromWebStorage());
    _setupDeepLinkHandler();

    // Set up auth listener as soon as Supabase is ready — do NOT wait for RevenueCat.
    _servicesReady.future.then((_) {
      if (!mounted) return;
      _setupAuthListener();

      // Start PushNotificationService as soon as Firebase + Supabase are ready
      // AND a valid user session exists. RevenueCat must NOT block this.
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        debugPrint(
          'PUSH: Session exists at startup — starting PushNotificationService (not waiting for RevenueCat).',
        );
        _startPushNotificationsIfNeeded();
      } else {
        debugPrint(
          'PUSH: No session at startup — PushNotificationService deferred until sign-in.',
        );
      }
    });

    // RevenueCat completion: only refresh subscription. Push notifications
    // are no longer gated on this completer.
    _allServicesReady.future.then((_) {
      if (!mounted) return;
      _refreshSubscription();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Step 7 — Foreground lifecycle: silently refresh session when app resumes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _silentlyRefreshSession();
      _refreshSubscription();
      // Presence: mark online only after services (Supabase) are fully ready
      if (_servicesReady.isCompleted) {
        PresenceService.instance.setOnline();
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // Presence: mark offline only after services (Supabase) are fully ready
      if (_servicesReady.isCompleted) {
        PresenceService.instance.setOffline();
      }
    }
  }

  Future<void> _refreshSubscription() async {
    try {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        await Provider.of<SubscriptionProvider>(
          ctx,
          listen: false,
        ).refreshSubscription();
      }
    } catch (e) {
      debugPrint('SUBSCRIPTION: refresh from main error — $e');
    }
  }

  Future<void> _silentlyRefreshSession() async {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        await Supabase.instance.client.auth.refreshSession();
        debugPrint(
          'SESSION LIFECYCLE — silently refreshed on foreground resume',
        );
      }
    } catch (e) {
      debugPrint(
        'SESSION LIFECYCLE — silent refresh failed (non-critical): $e',
      );
    }
  }

  /// Initialize app_links and listen for incoming deep links
  void _setupDeepLinkHandler() {
    _appLinks = AppLinks();

    // Handle deep links received while app is already running
    _appLinks.uriLinkStream.listen(
      (Uri uri) {
        debugPrint('DEEP LINK: Received URI: $uri');
        _handleDeepLink(uri);
      },
      onError: (err) {
        debugPrint('DEEP LINK: Stream error: $err');
      },
    );

    // Handle the initial deep link that launched the app
    _appLinks
        .getInitialLink()
        .then((Uri? uri) {
          if (uri != null) {
            debugPrint('DEEP LINK: Initial URI: $uri');
            _handleDeepLink(uri);
          }
        })
        .catchError((err) {
          debugPrint('DEEP LINK: Error getting initial link: $err');
        });
  }

  /// Route incoming deep links to the appropriate handler
  void _handleDeepLink(Uri uri) {
    debugPrint('DEEP LINK: scheme=${uri.scheme}, host=${uri.host}');
    if (uri.scheme == 'facemeet') {
      if (uri.host == 'payment-success') {
        _handlePaymentSuccess();
      } else if (uri.host == 'payment-cancelled') {
        _handlePaymentCancelled();
      } else if (uri.host == 'login-callback') {
        _handleAuthCallback(uri);
      }
    }
    // Handle https://facemeet.app/join/[code] referral links
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        _isFaceMeetReferralHost(uri.host)) {
      final referralCode = _extractReferralCode(uri);
      if (referralCode != null && referralCode.isNotEmpty) {
        _storeReferralCode(referralCode);
      }
    }
  }

  bool _isFaceMeetReferralHost(String host) {
    return host == 'app.facemeet.app' ||
        host == 'facemeet.app' ||
        host == 'www.facemeet.app';
  }

  String? _extractReferralCode(Uri uri) {
    final queryRef = uri.queryParameters['ref']?.trim();
    if (queryRef != null && queryRef.isNotEmpty) return queryRef;
    if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'join') {
      return uri.pathSegments[1].trim();
    }
    if (uri.pathSegments.length >= 2 && uri.pathSegments[0] == 'r') {
      return uri.pathSegments[1].trim();
    }
    return null;
  }

  void _captureReferralFromLaunchUrl() {
    try {
      final referralCode = _extractReferralCode(Uri.base);
      if (referralCode != null && referralCode.isNotEmpty) {
        _storeReferralCode(referralCode);
      }
    } catch (e) {
      debugPrint('REFERRAL: launch URL capture failed: $e');
    }
  }

  Future<void> _recoverPendingReferralCodeFromWebStorage() async {
    if (!kIsWeb) return;
    try {
      final code = (await InstallGateService.instance.getPendingReferralCode())
          .trim();
      if (code.isEmpty) {
        debugPrint('REFERRAL: recovered web pending code no');
        return;
      }
      await _storeReferralCode(code);
      debugPrint('REFERRAL: recovered web pending code yes');
    } catch (e) {
      debugPrint('REFERRAL: web pending code recovery failed: $e');
    }
  }

  /// Store referral code in SharedPreferences for use after signup
  Future<void> _storeReferralCode(String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cleaned = code.trim();
      if (cleaned.isEmpty) return;
      await prefs.setString('pending_referral_code', cleaned);
      debugPrint('REFERRAL: Stored pending referral code yes');
    } catch (e) {
      debugPrint('REFERRAL: Failed to store referral code: $e');
    }
  }

  /// Handle successful payment: refresh subscription data and navigate to home
  Future<void> _handlePaymentSuccess() async {
    debugPrint('DEEP LINK: Handling payment-success');

    // Bug 2: Set flag to prevent auth listener from treating the post-Stripe
    // signedOut event as a real logout and navigating to the auth screen.
    paymentInProgress = true;

    // Step 1: Silently refresh the Supabase session first to prevent
    // the auth listener from firing a spurious signedOut event.
    try {
      await Supabase.instance.client.auth.refreshSession();
      debugPrint(
        'DEEP LINK: Session refreshed before payment-success handling',
      );
    } catch (e) {
      debugPrint('DEEP LINK: Session refresh failed (non-critical): $e');
    }

    // Step 2: Verify we still have a valid session before navigating.
    // If session is null after refresh, attempt restore before proceeding.
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      debugPrint(
        'DEEP LINK: No session after refresh — attempting restore before navigation',
      );
      await _silentlyRefreshSession();
      await Future.delayed(const Duration(milliseconds: 1200));
    }

    // Step 3: Refresh subscription data in place before navigating.
    await _refreshSubscription();

    // Step 4: Navigate to discovery feed (shell) — only if we have a session.
    final currentSession = Supabase.instance.client.auth.currentSession;
    if (currentSession != null) {
      // Bug 2: Use pushNamed instead of pushNamedAndRemoveUntil to avoid
      // clearing the stack which can cause a blank screen if auth fires.
      // Pop back to the existing shell if already there, otherwise push.
      final navigator = _navigatorKey.currentState;
      if (navigator != null) {
        navigator.pushNamedAndRemoveUntil(
          AppRoutes.discoveryFeedScreen,
          (route) => false,
        );
      }
    } else {
      // Still no session — navigate to pricing screen so user stays in app
      debugPrint(
        'DEEP LINK: Session still null after restore — navigating to pricing screen',
      );
      _navigatorKey.currentState?.pushNamed(AppRoutes.pricingScreen);
    }

    // Step 5: Poll for subscription update — Stripe webhooks can take 5-30s.
    // Retry up to 8 times with increasing delays (total ~35 seconds).
    await Future.delayed(const Duration(milliseconds: 800));

    String tier = 'free';
    const maxRetries = 8;
    final retryDelays = [1, 2, 3, 4, 5, 5, 5, 5]; // seconds between retries

    for (int i = 0; i < maxRetries; i++) {
      await _refreshSubscription();
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        final sub = Provider.of<SubscriptionProvider>(ctx, listen: false);
        tier = sub.subscriptionTier;
      }
      debugPrint('DEEP LINK: Payment success poll #${i + 1} — tier=$tier');
      if (tier != 'free') break;
      if (i < maxRetries - 1) {
        await Future.delayed(Duration(seconds: retryDelays[i]));
      }
    }

    // Bug 2: Clear payment flag after polling completes
    paymentInProgress = false;
    debugPrint(
      'DEEP LINK: Payment success — final tier=$tier, paymentInProgress cleared',
    );

    // Step 6: Show SnackBar after navigation settles
    await Future.delayed(const Duration(milliseconds: 300));
    final ctx2 = _navigatorKey.currentContext;
    if (ctx2 != null && ctx2.mounted) {
      String message;
      if (tier == 'gold') {
        message = 'Welcome to Gold! 🏆 10 Sparks added to your balance!';
      } else if (tier == 'spark_plus') {
        message = 'Welcome to Spark+! ⚡ 3 Sparks added to your balance!';
      } else {
        // Webhook may still be processing — show generic success and let
        // the user know sparks will appear shortly.
        message = 'Payment successful! ✨ Your Sparks will appear shortly.';
      }
      ScaffoldMessenger.of(ctx2).showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
          backgroundColor: const Color(0xFFE8503A),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  /// Handle cancelled payment: navigate to pricing screen and show SnackBar
  void _handlePaymentCancelled() {
    debugPrint('DEEP LINK: Handling payment-cancelled');

    _navigatorKey.currentState?.pushNamed(AppRoutes.pricingScreen);

    Future.delayed(const Duration(milliseconds: 500), () {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text(
              'Payment cancelled — no charge was made.',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            backgroundColor: Color(0xFF555555),
            duration: Duration(seconds: 4),
          ),
        );
      }
    });
  }

  // Step 4 — Auth state listener with manualLogout guard
  void _setupAuthListener() {
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final event = data.event;
      debugPrint('AUTH STATE CHANGE — event: $event');

      if (event == AuthChangeEvent.tokenRefreshed) {
        debugPrint('AUTH STATE CHANGE — token refreshed successfully');
      } else if (event == AuthChangeEvent.signedIn ||
          event == AuthChangeEvent.userUpdated) {
        // Presence: mark online on sign in
        PresenceService.instance.setOnline();
        // Start push notifications on sign-in if not already started.
        // This covers the case where there was no session at startup.
        _startPushNotificationsIfNeeded();
        // If email just got verified (e.g. user tapped link while app was open),
        // navigate away from the verification screen.
        final user = data.session?.user;
        if (user != null && user.emailConfirmedAt != null) {
          final ctx = _navigatorKey.currentContext;
          if (ctx != null) {
            final currentRoute = ModalRoute.of(ctx)?.settings.name;
            if (currentRoute == AppRoutes.emailVerificationScreen) {
              _navigateAfterAuthCallback();
            }
          }
        }
      } else if (event == AuthChangeEvent.signedOut) {
        // Presence: mark offline on sign out
        PresenceService.instance.setOffline();
        if (manualLogout) {
          debugPrint('AUTH STATE CHANGE — manual logout, navigating to auth');
          manualLogout = false;
          _navigatorKey.currentState?.pushNamedAndRemoveUntil(
            AppRoutes.authScreen,
            (route) => false,
          );
        } else if (paymentInProgress) {
          // Bug 2: Ignore signedOut events during payment flow — Stripe redirect
          // can trigger a spurious signedOut that must not navigate to auth screen.
          debugPrint(
            'AUTH STATE CHANGE — signedOut during payment flow (paymentInProgress=true) — ignoring',
          );
        } else {
          // Unexpected signedOut (e.g. token expiry during Stripe redirect).
          // Never navigate to auth — attempt a silent session restore instead.
          // Bug 4 fix: wait longer before attempting restore to allow Supabase
          // to auto-restore from stored refresh token after Stripe redirect.
          debugPrint(
            'AUTH STATE CHANGE — unexpected signedOut, attempting silent restore',
          );
          Future.delayed(const Duration(milliseconds: 1500), () async {
            await _silentlyRefreshSession();
            // After restore attempt, check if we have a valid session.
            // If we do, stay on current screen. If not, do nothing — don't
            // navigate to auth screen on unexpected signedOut.
            final restored = Supabase.instance.client.auth.currentSession;
            debugPrint(
              'AUTH STATE CHANGE — restore attempt complete, session=${restored != null ? "valid" : "null"}',
            );
          });
        }
      }
    });
  }

  // Step 3 — Determine initial route: always splash; splash navigates based on session
  String _resolveInitialRoute() {
    return AppRoutes.splashScreen;
  }

  /// Handle Supabase email verification callback (facemeet://login-callback)
  Future<void> _handleAuthCallback(Uri uri) async {
    debugPrint('AUTH CALLBACK: Handling login-callback URI: $uri');
    try {
      // ── 1. PKCE flow: Supabase sends ?code=XXXX in the query string ──────────
      final code = uri.queryParameters['code'];
      if (code != null && code.isNotEmpty) {
        debugPrint('AUTH CALLBACK: Exchanging PKCE code for session');
        final response = await Supabase.instance.client.auth
            .exchangeCodeForSession(code);
        final user =
            response.session.user ?? Supabase.instance.client.auth.currentUser;
        debugPrint(
          'AUTH CALLBACK: User after exchangeCodeForSession: ${user?.email}, confirmed: ${user?.emailConfirmedAt}',
        );
        if (user != null) {
          await _navigateAfterAuthCallback();
        }
        return;
      }

      // ── 2. OTP / magic-link flow: token_hash + type in query params ──────────
      final tokenHash = uri.queryParameters['token_hash'];
      final type = uri.queryParameters['type'];
      if (tokenHash != null && tokenHash.isNotEmpty && type != null) {
        debugPrint('AUTH CALLBACK: Verifying OTP token_hash (type=$type)');
        final otpType = type == 'signup'
            ? OtpType.signup
            : type == 'email'
            ? OtpType.email
            : OtpType.signup;
        final response = await Supabase.instance.client.auth.verifyOTP(
          tokenHash: tokenHash,
          type: otpType,
        );
        final user = response.user ?? Supabase.instance.client.auth.currentUser;
        debugPrint(
          'AUTH CALLBACK: User after verifyOTP: ${user?.email}, confirmed: ${user?.emailConfirmedAt}',
        );
        if (user != null) {
          await _navigateAfterAuthCallback();
        }
        return;
      }

      // ── 3. Legacy implicit flow: access_token + refresh_token in fragment ────
      final fragment = uri.fragment;
      final query = uri.query;
      final rawParams = fragment.isNotEmpty ? fragment : query;

      if (rawParams.isNotEmpty) {
        final params = Uri.splitQueryString(rawParams);
        final accessToken = params['access_token'];
        final refreshToken = params['refresh_token'];

        if (accessToken != null && refreshToken != null) {
          debugPrint('AUTH CALLBACK: Setting session from tokens');
          await Supabase.instance.client.auth.setSession(refreshToken);
          final user = Supabase.instance.client.auth.currentUser;
          debugPrint(
            'AUTH CALLBACK: User after setSession: ${user?.email}, confirmed: ${user?.emailConfirmedAt}',
          );
          if (user != null) {
            await _navigateAfterAuthCallback();
          }
          return;
        }
      }

      // ── 4. Fallback: refresh session and check current user ──────────────────
      debugPrint('AUTH CALLBACK: No tokens in URI, refreshing session');
      await Supabase.instance.client.auth.refreshSession();
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null && user.emailConfirmedAt != null) {
        await _navigateAfterAuthCallback();
      }
    } catch (e) {
      debugPrint('AUTH CALLBACK: Error handling callback: $e');
      // Even on error, try to check current session state
      try {
        await Supabase.instance.client.auth.refreshSession();
        final user = Supabase.instance.client.auth.currentUser;
        if (user != null && user.emailConfirmedAt != null) {
          await _navigateAfterAuthCallback();
        }
      } catch (_) {}
    }
  }

  /// Navigate to onboarding or discovery feed after successful auth callback
  Future<void> _navigateAfterAuthCallback() async {
    debugPrint('AUTH CALLBACK: Navigating after successful verification');
    try {
      final isComplete = await SupabaseService.instance.isOnboardingComplete();
      final route = AppRoutes.routeAfterAuth(onboardingComplete: isComplete);
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(route, (r) => false);
    } catch (e) {
      debugPrint('AUTH CALLBACK: Navigation error: $e');
      _navigatorKey.currentState?.pushNamedAndRemoveUntil(
        AppRoutes.onboardingScreen,
        (r) => false,
      );
    }
  }

  /// Start PushNotificationService if Firebase is ready and it hasn't been started yet.
  void _startPushNotificationsIfNeeded() {
    if (_pushNotificationStarted) return;
    if (kIsWeb) {
      _pushNotificationStarted = true;
      debugPrint('WEB PUSH: refreshing current PWA subscription at startup');
      unawaited(
        WebPushNotificationService.instance.refreshExistingSubscription(),
      );
      return;
    }
    if (!_firebaseInitialized) {
      debugPrint(
        'PUSH: Firebase NOT initialized — PushNotificationService skipped.',
      );
      return;
    }
    _pushNotificationStarted = true;
    debugPrint('PUSH: Starting PushNotificationService.');
    pushNotificationNavigatorKey = _navigatorKey;
    PushNotificationService().initialise();
    PushNotificationService().handleForegroundMessages();
    PushNotificationService().handleNotificationTaps();
  }

  @override
  Widget build(BuildContext context) {
    try {
      return Sizer(
        builder: (context, orientation, screenType) {
          return MaterialApp(
            title: 'facemeet',
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: ThemeMode.light,
            navigatorKey: _navigatorKey,
            // 🚨 CRITICAL: NEVER REMOVE OR MODIFY
            builder: (context, child) {
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(1.0)),
                child: child!,
              );
            },
            // 🚨 END CRITICAL SECTION
            debugShowCheckedModeBanner: false,
            routes: AppRoutes.routes,
            initialRoute: AppRoutes.splashScreen,
          );
        },
      );
    } catch (e) {
      debugPrint('ROOT WIDGET BUILD ERROR: $e');
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          color: Colors.red,
          alignment: Alignment.center,
          child: const Text(
            'FaceMeet Loading',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    }
  }
}
