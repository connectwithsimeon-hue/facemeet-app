import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../main.dart' show mainShellKey, SplashScreen;
import '../presentation/auth_screen/auth_screen.dart';
import '../presentation/auth_screen/email_verification_screen.dart';
import '../presentation/install_gate_screen/install_gate_screen.dart';
import '../presentation/main_shell_screen/main_shell_screen.dart';
import '../presentation/notification_onboarding_screen/notification_onboarding_screen.dart';
import '../presentation/onboarding_screen/onboarding_screen.dart';
import '../presentation/spark_session_screen/spark_session_screen.dart';
import '../presentation/pricing_screen/pricing_screen.dart';
import '../presentation/profile_screen/profile_video_record_screen.dart';
import '../presentation/debug_screen/push_notification_debug_screen.dart';
import '../presentation/events_screen/events_screen.dart';
import '../presentation/intro_carousel_screen/intro_carousel_screen.dart';
import '../presentation/professional_spark_reveal_screen/professional_spark_reveal_screen.dart';
import '../widgets/app_navigation.dart';

class AppRoutes {
  static const String initial = '/';
  static const String splashScreen = '/splash';
  static const String introCarousel = '/intro-carousel';
  static const String authScreen = '/auth-screen';
  static const String installGateScreen = '/install-gate-screen';
  static const String onboardingScreen = '/onboarding-screen';
  static const String notificationOnboardingScreen =
      '/notification-onboarding-screen';
  static const String discoveryFeedScreen = '/discovery-feed-screen';
  static const String sparksScreen = '/sparks-screen';
  static const String sparkSessionScreen = '/spark-session-screen';
  static const String chatScreen = '/chat-screen';
  static const String chatThreadScreen = '/chat-thread-screen';
  static const String profileScreen = '/profile-screen';
  static const String pricingScreen = '/pricing-screen';
  static const String eventsScreen = '/events-screen';
  static const String professionalSparkRevealScreen =
      '/professional-spark-reveal-screen';
  static const String profileVideoRecord = '/profile-video-record';
  static const String emailVerificationScreen = '/email-verification-screen';
  static const String pushNotificationDebug = '/push-notification-debug';

  static Map<String, WidgetBuilder> routes = {
    initial: (context) => const SplashScreen(),
    splashScreen: (context) => const SplashScreen(),
    introCarousel: (context) => const IntroCarouselScreen(),
    installGateScreen: (context) => const InstallGateScreen(),
    authScreen: (context) => const AuthScreen(),
    emailVerificationScreen: (context) => const EmailVerificationScreen(),
    onboardingScreen: (context) => const OnboardingScreen(),
    notificationOnboardingScreen: (context) =>
        const NotificationOnboardingScreen(),
    discoveryFeedScreen: (context) =>
        MainShellScreen(key: mainShellKey, initialIndex: discoverTabIndex),
    sparksScreen: (context) =>
        MainShellScreen(key: mainShellKey, initialIndex: sparksTabIndex),
    sparkSessionScreen: (context) => const SparkSessionScreen(),
    chatScreen: (context) {
      final args = ModalRoute.of(context)?.settings.arguments;
      String? matchId;
      Map<String, dynamic>? otherUser;
      if (args is Map<String, dynamic>) {
        matchId = args['matchId'] as String?;
        otherUser = args['otherUser'] as Map<String, dynamic>?;
      }
      return MainShellScreen(
        key: mainShellKey,
        initialIndex: chatsTabIndex,
        chatMatchId: matchId,
        chatOtherUser: otherUser,
      );
    },
    profileScreen: (context) =>
        MainShellScreen(key: mainShellKey, initialIndex: profileTabIndex),
    pricingScreen: (context) => const PricingScreen(),
    eventsScreen: (context) => const EventsScreen(),
    professionalSparkRevealScreen: (context) {
      final args = ModalRoute.of(context)?.settings.arguments;
      String? senderUserId;
      if (args is Map<String, dynamic>) {
        senderUserId = args['senderUserId'] as String?;
      }
      return ProfessionalSparkRevealScreen(senderUserId: senderUserId);
    },
    profileVideoRecord: (context) => const ProfileVideoRecordScreen(),
    pushNotificationDebug: (context) => const PushNotificationDebugScreen(),
  };

  static String routeAfterAuth({required bool onboardingComplete}) {
    if (!onboardingComplete) return onboardingScreen;
    return kIsWeb ? notificationOnboardingScreen : discoveryFeedScreen;
  }
}
