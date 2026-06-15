import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'android_diagnostics_service.dart';
import 'supabase_service.dart';
import '../routes/app_routes.dart';
import '../main.dart' show mainShellKey;

/// Global navigator key — injected from main.dart before use.
GlobalKey<NavigatorState>? pushNotificationNavigatorKey;

class PushNotificationService {
  static final PushNotificationService _instance =
      PushNotificationService._internal();
  factory PushNotificationService() => _instance;
  PushNotificationService._internal();

  /// Static debug log list — every print statement also appends here.
  static final List<String> debugLogs = [];

  static void _log(String message) {
    print(message);
    debugLogs.add('[${DateTime.now().toIso8601String()}] $message');
    // Keep bridge in sync so the debug screen can read logs
  }

  // Access FirebaseMessaging.instance lazily via a getter so it is never
  // evaluated at field-initialisation time (before Firebase.initializeApp()).
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  // Stores the latest FCM token so the auth state listener can use it
  String? _currentToken;

  // Local notifications (Android/iOS only — not web)
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'facemeet_notifications',
    'FaceMeet Notifications',
    importance: Importance.max,
  );

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Step 1 — Request permission and register FCM token.
  Future<void> initialise() async {
    _log(
      'PUSH DEBUG: PushNotificationService.initialise() called — platform=${defaultTargetPlatform.name}, kIsWeb=$kIsWeb',
    );

    // Initialise local notifications plugin (non-web only) — do this first,
    // before the permission delay, so foreground messages work immediately.
    if (!kIsWeb) {
      await _initLocalNotifications();
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // Delay permission request so the auth screen is fully visible.
      // 3 seconds is enough for the UI to settle after cold start.
      Future.delayed(const Duration(seconds: 3), () async {
        await _requestPermissionAndRegisterToken();
      });
    } else {
      // Android / web — request immediately, no dialog timing constraint.
      await _requestPermissionAndRegisterToken();
    }
  }

  /// Requests notification permission, retrieves the FCM token, and saves it.
  Future<void> _requestPermissionAndRegisterToken() async {
    _log(
      'PUSH DEBUG: _requestPermissionAndRegisterToken() START — platform=${defaultTargetPlatform.name}, kIsWeb=$kIsWeb',
    );
    try {
      // Request notification permission (shows system dialog on iOS).
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      await AndroidDiagnosticsService.instance.setValue(
        'fcm_permission_status',
        settings.authorizationStatus.name,
      );
      _log(
        'PUSH DEBUG: requestPermission() completed — authorizationStatus=${settings.authorizationStatus}',
      );

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        await _requestAndroidRuntimeNotificationPermission();
      }

      // On iOS, log the APNs token for diagnostics (existence only, not value).
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          final apnsToken = await _messaging.getAPNSToken();
          final apnsExists = apnsToken != null;
          _log('PUSH DEBUG: APNs token exists: $apnsExists');
          if (!apnsExists) {
            _log(
              'PUSH DEBUG: APNs token is null — device may not be registered with APNs yet. '
              'Check: Push Notifications capability in Apple Developer portal, '
              'APNs Auth Key in Firebase Console, bundle ID match.',
            );
          }
        } catch (e, st) {
          _log('PUSH DEBUG: getAPNSToken() threw error = $e\n$st');
        }
      }

      // Get and store current FCM token.
      _log('PUSH DEBUG: calling getToken()...');
      final token = await _messaging.getToken();
      final fcmExists = token != null;
      await AndroidDiagnosticsService.instance.setValue(
        'fcm_token_generated',
        fcmExists ? 'yes' : 'no',
      );
      _log(
        'PUSH DEBUG: FCM token exists: $fcmExists${fcmExists ? ", length: ${token.length}" : ""}',
      );
      if (!fcmExists) {
        _log('PUSH DEBUG: FCM TOKEN IS NULL — cannot register device');
        return;
      }
      _currentToken = token;

      // Save token immediately — covers session restore (user already signed in
      // when initialise() is called) and normal sign-in flows.
      final userId = Supabase.instance.client.auth.currentUser?.id;
      _log(
        'PUSH DEBUG: User ID exists at registration time: ${userId != null}',
      );
      await saveTokenToSupabase(token);

      // Listen for auth state changes — save token when user signs in or updates.
      Supabase.instance.client.auth.onAuthStateChange.listen((data) {
        if ((data.event == AuthChangeEvent.signedIn ||
                data.event == AuthChangeEvent.userUpdated) &&
            _currentToken != null) {
          _log(
            'PUSH DEBUG: Auth event ${data.event} — re-saving token for user ${data.session?.user.id.substring(0, 8)}...',
          );
          saveTokenToSupabase(_currentToken!);
        }
      });

      // Listen for token refresh.
      _messaging.onTokenRefresh.listen((newToken) async {
        _log('PUSH DEBUG: FCM token refreshed — saving new token');
        _currentToken = newToken;
        await saveTokenToSupabase(newToken);
      });

      _log(
        'PUSH DEBUG: _requestPermissionAndRegisterToken() COMPLETE — token registered successfully',
      );
    } catch (e, st) {
      _log(
        'PUSH DEBUG: _requestPermissionAndRegisterToken() CAUGHT ERROR = $e\n$st',
      );
    }
  }

  /// Step 2 — Upsert FCM token into Supabase device_tokens table.
  Future<void> saveTokenToSupabase(String token) async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final userExists = userId != null;
      _log(
        'PUSH DEBUG: saveTokenToSupabase — Current user ID exists: $userExists',
      );
      if (!userExists) {
        _log('PUSH DEBUG: userId is null — skipping upsert');
        return;
      }

      final platform = kIsWeb
          ? 'web'
          : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');

      _log(
        'PUSH DEBUG: Upserting token — userId exists: true, platform: $platform, token length: ${token.length}',
      );
      await AndroidDiagnosticsService.instance.setValues({
        'device_tokens_upsert_attempted': 'yes',
        'latest_device_token_platform': platform,
      });

      await Supabase.instance.client.from('device_tokens').upsert({
        'user_id': userId,
        'fcm_token': token,
        'platform': platform,
        'updated_at': DateTime.now().toIso8601String(),
        'last_seen_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,fcm_token');

      _log('PUSH DEBUG: Token save to Supabase: SUCCESS');
      debugPrint('PUSH: FCM token saved for user $userId on $platform');
      await AndroidDiagnosticsService.instance.verifyDeviceTokenReadback(
        fcmToken: token,
      );
    } catch (e) {
      debugPrint('PUSH: Failed to save FCM token — $e');
      await AndroidDiagnosticsService.instance.setValues({
        'device_tokens_upsert_attempted': 'yes',
        'fcm_token_saved_in_supabase': 'error',
      });
      _log('PUSH DEBUG: Token save to Supabase: FAILED — error: $e');
    }
  }

  /// Step 3 — Show local notification for foreground messages.
  void handleForegroundMessages() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('PUSH: Foreground message received — ${message.messageId}');
      _log('PUSH: Foreground message received — ${message.messageId}');
      AndroidDiagnosticsService.instance.recordPushPayload(
        source: 'last_foreground_message_payload',
        data: message.data,
      );
      if (message.data['type'] == 'spark_session' ||
          message.data['type'] == 'new_match' ||
          message.data['type'] == 'new_spark') {
        AndroidDiagnosticsService.instance.recordPushPayload(
          source: 'last_spark_notification_payload',
          data: message.data,
        );
      }
      AndroidDiagnosticsService.instance.setValue(
        'last_fcm_message_received',
        'foreground:${message.data['type'] ?? 'unknown'}',
      );

      if (kIsWeb) return; // Web handles notifications natively via browser

      final notification = message.notification;
      final notificationTitle =
          notification?.title ?? _fallbackNotificationTitle(message.data);
      final notificationBody =
          notification?.body ?? _fallbackNotificationBody(message.data);
      if (notificationTitle.trim().isEmpty && notificationBody.trim().isEmpty) {
        return;
      }

      _localNotifications.show(
        (message.messageId ?? jsonEncode(message.data)).hashCode,
        notificationTitle,
        notificationBody,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            importance: Importance.max,
            priority: Priority.high,
            channelShowBadge: true,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: jsonEncode(message.data),
      );
      AndroidDiagnosticsService.instance.setValue(
        'last_local_notification_shown',
        'foreground:${message.data['type'] ?? 'unknown'}',
      );
    });
  }

  /// Step 4 — Handle notification taps (terminated + background states).
  Future<void> handleNotificationTaps() async {
    // App opened from terminated state
    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      await AndroidDiagnosticsService.instance.recordPushPayload(
        source: 'last_initial_message_payload',
        data: initialMessage.data,
      );
      await AndroidDiagnosticsService.instance.setValue(
        'last_fcm_message_received',
        'initial:${initialMessage.data['type'] ?? 'unknown'}',
      );
      _routeFromMessage(initialMessage);
    }

    // App opened from background state
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      AndroidDiagnosticsService.instance.recordPushPayload(
        source: 'last_opened_app_payload',
        data: message.data,
      );
      AndroidDiagnosticsService.instance.setValue(
        'last_fcm_message_received',
        'opened:${message.data['type'] ?? 'unknown'}',
      );
      _routeFromMessage(message);
    });
  }

  // ─── Private helpers ───────────────────────────────────────────────────────

  Future<void> _initLocalNotifications() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        _log(
          'SPARK SESSION: notification tapped — payload exists=${payload != null && payload.isNotEmpty}',
        );
        if (payload == null || payload.isEmpty) return;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is Map<String, dynamic>) {
            AndroidDiagnosticsService.instance.recordPushPayload(
              source: 'last_notification_tap_payload',
              data: decoded,
            );
            unawaited(_routeFromData(decoded));
          }
        } catch (e) {
          _log('PUSH: local notification payload decode failed — $e');
        }
      },
    );

    // Create the Android notification channel
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_channel);
  }

  String _fallbackNotificationTitle(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    switch (type) {
      case 'spark_session':
        return 'Your Spark Session is ready';
      case 'new_spark':
        return 'Someone sparked you';
      case 'new_match':
        return 'It’s a match';
      case 'chat_unlocked':
        return 'Chat unlocked';
      case 'new_message':
        return 'New message';
      default:
        return 'FaceMeet';
    }
  }

  String _fallbackNotificationBody(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    switch (type) {
      case 'spark_session':
        return 'Tap to join your 3-minute video date.';
      case 'new_spark':
        return 'Open FaceMeet to respond.';
      case 'new_match':
        return 'Open FaceMeet to start your Spark Session.';
      case 'chat_unlocked':
        return 'You both felt the spark. Say hello.';
      case 'new_message':
        return 'Open FaceMeet to reply.';
      default:
        return '';
    }
  }

  Future<void> _requestAndroidRuntimeNotificationPermission() async {
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      await AndroidDiagnosticsService.instance.setValues({
        'android_permission_api_available': 'no',
        'android_permission_request_attempted': 'no',
      });
      _log('PUSH DEBUG: Android notification permission plugin unavailable');
      return;
    }

    try {
      final enabledBefore = await androidPlugin.areNotificationsEnabled();
      await AndroidDiagnosticsService.instance.setValues({
        'android_permission_api_available': 'yes',
        'android_notifications_enabled_before': enabledBefore,
        'android_permission_request_attempted': 'yes',
      });
      _log(
        'PUSH DEBUG: Android notifications enabled before prompt: $enabledBefore',
      );
      final granted = await androidPlugin.requestNotificationsPermission();
      await AndroidDiagnosticsService.instance.setValue(
        'android_permission_request_result',
        granted,
      );
      _log(
        'PUSH DEBUG: Android runtime notification permission granted: $granted',
      );
      final enabledAfter = await androidPlugin.areNotificationsEnabled();
      await AndroidDiagnosticsService.instance.setValue(
        'android_notifications_enabled_after',
        enabledAfter,
      );
      _log(
        'PUSH DEBUG: Android notifications enabled after prompt: $enabledAfter',
      );
    } catch (e) {
      await AndroidDiagnosticsService.instance.setValues({
        'android_permission_request_result': 'error',
        'android_notifications_enabled_after': 'unknown',
      });
      _log('PUSH DEBUG: Android notification permission request failed — $e');
    }
  }

  void _routeFromMessage(RemoteMessage message) {
    _log(
      'SPARK SESSION: notification tapped — fcm messageId=${message.messageId}',
    );
    AndroidDiagnosticsService.instance.recordPushPayload(
      source: 'last_notification_tap_payload',
      data: message.data,
    );
    unawaited(_routeFromData(message.data));
  }

  Future<void> _routeFromData(Map<String, dynamic> data) async {
    final type = data['type'] as String?;
    final navigator = pushNotificationNavigatorKey?.currentState;

    if (navigator == null) return;

    switch (type) {
      case 'new_match':
        final matchId = data['match_id'] as String?;
        _log(
          'SPARK SESSION: mutual match notification received — matchId=$matchId',
        );
        if (matchId != null && matchId.isNotEmpty) {
          await _openCanonicalSparkSessionFromNotification(
            navigator: navigator,
            matchId: matchId,
            source: 'notification_new_match',
          );
        } else {
          _log(
            'SPARK SESSION: route target after notification tap — sparksScreen fallback',
          );
          navigator.pushNamedAndRemoveUntil(
            AppRoutes.sparksScreen,
            (route) => false,
          );
        }
        break;
      case 'new_spark':
        final matchId = data['match_id'] as String?;
        if (matchId != null && matchId.isNotEmpty) {
          await _openCanonicalSparkSessionFromNotification(
            navigator: navigator,
            matchId: matchId,
            source: 'notification_new_spark',
          );
        } else {
          _log(
            'SPARK SESSION: route target after notification tap — discoveryFeedScreen',
          );
          // Navigate to discovery feed — do not reveal who sparked them
          navigator.pushNamedAndRemoveUntil(
            AppRoutes.discoveryFeedScreen,
            (route) => false,
          );
        }
        break;
      case 'new_message':
        final matchId = data['match_id'] as String?;
        if (matchId != null && matchId.isNotEmpty) {
          // If the shell is already mounted, use openChat() to avoid
          // pushing a new MainShellScreen (which causes a blank screen).
          final shell = mainShellKey.currentState;
          if (shell != null) {
            shell.openChat(matchId, null);
          } else {
            // Shell not yet mounted — navigate via route (cold start)
            navigator.pushNamedAndRemoveUntil(
              AppRoutes.chatScreen,
              (route) => false,
              arguments: {'matchId': matchId},
            );
          }
        }
        break;
      case 'spark_session':
        final matchId = data['match_id'] as String?;
        final shell = mainShellKey.currentState;
        if (matchId != null && matchId.isNotEmpty) {
          _log(
            'SPARK SESSION: invite notification received — matchId=$matchId',
          );
          await _openCanonicalSparkSessionFromNotification(
            navigator: navigator,
            matchId: matchId,
            source: 'notification_spark_session',
            replaceStackWhenShellMissing: shell == null,
          );
        } else {
          // No matchId — fall back to Sessions tab refresh
          if (shell != null) {
            shell.refreshSparks();
          } else {
            navigator.pushNamedAndRemoveUntil(
              AppRoutes.sparksScreen,
              (route) => false,
            );
          }
        }
        break;
      default:
        debugPrint('PUSH: Unknown notification type — $type');
        _log('PUSH: Unknown notification type — $type');
    }
  }

  Future<void> _openCanonicalSparkSessionFromNotification({
    required NavigatorState navigator,
    required String matchId,
    required String source,
    bool replaceStackWhenShellMissing = false,
  }) async {
    await AndroidDiagnosticsService.instance.setValue(
      'entry_point_before_navigation',
      source,
    );
    final result = await SupabaseService.instance
        .startOrJoinCanonicalSparkSession(matchId: matchId, source: source);
    await AndroidDiagnosticsService.instance.setValues({
      'canonical_resolver_source': source,
      'canonical_resolver_result': result.canEnter ? 'joinable' : 'rejected',
      'canonical_resolver_reject_reason': result.canEnter
          ? 'none'
          : result.reason,
      'session_key_used_for_navigation': AndroidDiagnosticsService.shortId(
        result.sessionKey,
      ),
    });

    if (!result.canEnter) {
      await AndroidDiagnosticsService.instance.setValues({
        'suppressed_session_popup_reason': result.reason,
        'last_session_status': 'unknown',
        'last_session_ended_at': 'unknown',
        'last_session_chat_unlocked': 'unknown',
        'last_session_feedback_complete': 'unknown',
      });
      _log(
        'SPARK SESSION: notification tap suppressed — reason=${result.reason}',
      );
      return;
    }

    final arguments = {
      'matchId': result.matchId,
      'sessionId': result.sessionId,
      'sessionKey': result.sessionKey,
    };
    if (replaceStackWhenShellMissing) {
      _log(
        'SPARK SESSION: route target after notification tap — canonical sparkSessionScreen cold start',
      );
      navigator.pushNamedAndRemoveUntil(
        AppRoutes.sparkSessionScreen,
        (route) => false,
        arguments: arguments,
      );
      return;
    }

    _log(
      'SPARK SESSION: route target after notification tap — canonical sparkSessionScreen',
    );
    navigator.pushNamed(AppRoutes.sparkSessionScreen, arguments: arguments);
  }
}
