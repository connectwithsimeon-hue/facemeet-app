import 'dart:async';
import 'dart:js_util' as js_util;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'supabase_service.dart';

class WebPushSetupResult {
  final bool success;
  final String status;
  final String message;

  const WebPushSetupResult({
    required this.success,
    required this.status,
    required this.message,
  });
}

class WebPushNotificationService {
  static final WebPushNotificationService instance =
      WebPushNotificationService._();
  WebPushNotificationService._();

  static const String _vapidPublicKey = String.fromEnvironment(
    'VAPID_PUBLIC_KEY',
    defaultValue: '',
  );

  Future<void> maybeShowEnablePrompt(BuildContext? context) async {
    debugPrint('WEB PUSH: automatic startup prompt disabled');
  }

  Future<void> openNotificationSettings(BuildContext context) async {
    debugPrint('WEB PUSH: settings opened');
  }

  Future<String> notificationStatusLabel() async {
    final state = await currentSetupState();
    return state.status;
  }

  Future<WebPushSetupResult> currentSetupState() async {
    try {
      final supported = _callJsBool('facemeetIsWebPushSupported');
      if (!supported) {
        return const WebPushSetupResult(
          success: false,
          status: 'Notifications are not supported',
          message: 'Notifications are not supported on this browser.',
        );
      }

      final permission = _callJsString('facemeetGetNotificationPermission');
      if (permission == 'denied') {
        return const WebPushSetupResult(
          success: false,
          status: 'Notifications blocked',
          message:
              'Notifications are blocked. Enable them in your browser settings.',
        );
      }

      if (permission == 'granted') {
        final refreshed = await refreshExistingSubscription();
        if (refreshed.success) {
          return const WebPushSetupResult(
            success: true,
            status: 'Notifications enabled',
            message: 'Notifications enabled.',
          );
        }
        return const WebPushSetupResult(
          success: false,
          status: 'Finish enabling notifications',
          message:
              'Permission is allowed, but FaceMeet needs to finish saving this device.',
        );
      }

      return const WebPushSetupResult(
        success: false,
        status: 'Enable Notifications',
        message:
            'Get notified when someone Sparks you, when a Spark Session is ready, and when chat unlocks.',
      );
    } catch (e) {
      debugPrint('WEB PUSH: current state failed — $e');
      return const WebPushSetupResult(
        success: false,
        status: 'Could not check notifications',
        message: 'We could not check notification status. Please try again.',
      );
    }
  }

  Future<WebPushSetupResult> refreshExistingSubscription() async {
    try {
      final supported = _callJsBool('facemeetIsWebPushSupported');
      if (!supported) {
        return const WebPushSetupResult(
          success: false,
          status: 'Notifications are not supported',
          message: 'Notifications are not supported on this browser.',
        );
      }

      final permission = _callJsString('facemeetGetNotificationPermission');
      if (permission != 'granted') {
        return WebPushSetupResult(
          success: false,
          status: permission == 'denied'
              ? 'Notifications blocked'
              : 'Enable Notifications',
          message: permission == 'denied'
              ? 'Notifications are blocked. Enable them in your browser settings.'
              : 'Notifications are not enabled on this device.',
        );
      }

      if (_vapidPublicKey.isEmpty) {
        debugPrint('WEB PUSH: refresh skipped; missing VAPID public key');
        return const WebPushSetupResult(
          success: false,
          status: 'Could not finish enabling notifications',
          message:
              'Notifications are not configured yet. Please try again after the next update.',
        );
      }

      final raw = await _callJsPromise('facemeetRefreshWebPushSubscription', [
        _vapidPublicKey,
      ]);
      final result = _jsObjectToMap(raw);
      final serviceWorkerReady = result['serviceWorkerReady'] == true;
      final isFaceMeetWorker = result['isFaceMeetWorker'] == true;
      final endpoint = result['endpoint']?.toString() ?? '';
      final p256dh = result['p256dh']?.toString() ?? '';
      final auth = result['auth']?.toString() ?? '';
      final userAgent = result['userAgent']?.toString() ?? '';
      final platform = result['platform']?.toString() ?? 'web';
      final hasSubscription =
          endpoint.isNotEmpty && p256dh.isNotEmpty && auth.isNotEmpty;

      if (!serviceWorkerReady || !isFaceMeetWorker || !hasSubscription) {
        debugPrint(
          'WEB PUSH: refresh incomplete worker=$isFaceMeetWorker subscription=$hasSubscription',
        );
        return WebPushSetupResult(
          success: false,
          status: 'Finish enabling notifications',
          message: _diagnosticMessage(
            permissionGranted: true,
            serviceWorkerReady: serviceWorkerReady,
            isFaceMeetWorker: isFaceMeetWorker,
            subscriptionCreated: hasSubscription,
            subscriptionSaved: false,
            subscriptionVerified: false,
            fallback:
                'Permission is allowed, but FaceMeet needs to finish saving this device.',
          ),
        );
      }

      final saved = await _saveSubscription(
        endpoint: endpoint,
        p256dh: p256dh,
        auth: auth,
        userAgent: userAgent,
        platform: platform,
      );
      if (!saved) {
        return const WebPushSetupResult(
          success: false,
          status: 'Could not finish enabling notifications',
          message: 'We could not save this device. Please try again.',
        );
      }

      final verified = await _verifySavedSubscription(endpoint: endpoint);
      return WebPushSetupResult(
        success: verified,
        status: verified
            ? 'Notifications enabled'
            : 'Could not finish enabling notifications',
        message: verified
            ? 'Notifications enabled.'
            : 'We could not verify this device. Please try again.',
      );
    } catch (e) {
      debugPrint('WEB PUSH: refresh failed — $e');
      return const WebPushSetupResult(
        success: false,
        status: 'Could not finish enabling notifications',
        message:
            'We could not finish enabling notifications. Please try again.',
      );
    }
  }

  Future<WebPushSetupResult> enableNotifications() async {
    debugPrint('WEB PUSH: enable tapped');
    try {
      final supported = _callJsBool('facemeetIsWebPushSupported');
      debugPrint('WEB PUSH: browser support yes/no=$supported');
      if (!supported) {
        return const WebPushSetupResult(
          success: false,
          status: 'Notifications are not supported',
          message: 'Notifications are not supported on this browser.',
        );
      }

      if (_vapidPublicKey.isEmpty) {
        debugPrint('WEB PUSH: missing VAPID public key');
        return const WebPushSetupResult(
          success: false,
          status: 'Could not finish enabling notifications',
          message:
              'Notifications are not configured yet. Please try again after the next update.',
        );
      }

      final beforePermission = _callJsString(
        'facemeetGetNotificationPermission',
      );
      debugPrint('WEB PUSH: permission before request=$beforePermission');

      final raw = await _callJsPromise('facemeetRequestWebPushSubscription', [
        _vapidPublicKey,
      ]);
      final result = _jsObjectToMap(raw);
      final permission = result['permission']?.toString() ?? 'unknown';
      debugPrint('WEB PUSH: permission after request=$permission');
      final permissionGranted = permission == 'granted';
      final serviceWorkerReady = result['serviceWorkerReady'] == true;
      final isFaceMeetWorker = result['isFaceMeetWorker'] == true;
      final jsSubscriptionCreated = result['subscriptionCreated'] == true;

      if (permission == 'denied') {
        return const WebPushSetupResult(
          success: false,
          status: 'Notifications blocked',
          message:
              'Notifications are blocked. Enable them in your browser settings.',
        );
      }
      if (permission != 'granted') {
        return WebPushSetupResult(
          success: false,
          status: 'Enable Notifications',
          message: _diagnosticMessage(
            permissionGranted: permissionGranted,
            serviceWorkerReady: serviceWorkerReady,
            isFaceMeetWorker: isFaceMeetWorker,
            subscriptionCreated: jsSubscriptionCreated,
            subscriptionSaved: false,
            subscriptionVerified: false,
            fallback: 'Notifications were not enabled.',
          ),
        );
      }

      final endpoint = result['endpoint']?.toString() ?? '';
      final p256dh = result['p256dh']?.toString() ?? '';
      final auth = result['auth']?.toString() ?? '';
      final userAgent = result['userAgent']?.toString() ?? '';
      final platform = result['platform']?.toString() ?? 'web';
      final hasSubscription =
          endpoint.isNotEmpty && p256dh.isNotEmpty && auth.isNotEmpty;
      debugPrint('WEB PUSH: service worker registered/ready');
      debugPrint(
        'WEB PUSH: service worker is FaceMeet push worker yes/no=$isFaceMeetWorker',
      );
      debugPrint('WEB PUSH: subscription created yes/no=$hasSubscription');
      if (!serviceWorkerReady || !isFaceMeetWorker || !hasSubscription) {
        return WebPushSetupResult(
          success: false,
          status: 'Could not finish enabling notifications',
          message: _diagnosticMessage(
            permissionGranted: permissionGranted,
            serviceWorkerReady: serviceWorkerReady,
            isFaceMeetWorker: isFaceMeetWorker,
            subscriptionCreated: hasSubscription,
            subscriptionSaved: false,
            subscriptionVerified: false,
            fallback:
                'We could not finish enabling notifications. Please try again.',
          ),
        );
      }

      final saved = await _saveSubscription(
        endpoint: endpoint,
        p256dh: p256dh,
        auth: auth,
        userAgent: userAgent,
        platform: platform,
      );
      debugPrint('WEB PUSH: subscription saved yes/no=$saved');
      if (!saved) {
        return WebPushSetupResult(
          success: false,
          status: 'Could not finish enabling notifications',
          message: _diagnosticMessage(
            permissionGranted: permissionGranted,
            serviceWorkerReady: serviceWorkerReady,
            isFaceMeetWorker: isFaceMeetWorker,
            subscriptionCreated: hasSubscription,
            subscriptionSaved: saved,
            subscriptionVerified: false,
            fallback: 'We could not save this device. Please try again.',
          ),
        );
      }

      final verified = await _verifySavedSubscription(endpoint: endpoint);
      debugPrint('WEB PUSH: subscription verified yes/no=$verified');
      if (!verified) {
        return WebPushSetupResult(
          success: false,
          status: 'Could not finish enabling notifications',
          message: _diagnosticMessage(
            permissionGranted: permissionGranted,
            serviceWorkerReady: serviceWorkerReady,
            isFaceMeetWorker: isFaceMeetWorker,
            subscriptionCreated: hasSubscription,
            subscriptionSaved: saved,
            subscriptionVerified: verified,
            fallback: 'We could not verify this device. Please try again.',
          ),
        );
      }

      return WebPushSetupResult(
        success: true,
        status: 'Notifications enabled',
        message: _diagnosticMessage(
          permissionGranted: permissionGranted,
          serviceWorkerReady: serviceWorkerReady,
          isFaceMeetWorker: isFaceMeetWorker,
          subscriptionCreated: hasSubscription,
          subscriptionSaved: saved,
          subscriptionVerified: verified,
          fallback: 'Notifications enabled.',
        ),
      );
    } catch (e) {
      debugPrint('WEB PUSH: enable failed — $e');
      return const WebPushSetupResult(
        success: false,
        status: 'Could not finish enabling notifications',
        message:
            'We could not finish enabling notifications. Please try again.',
      );
    }
  }

  Future<WebPushSetupResult> sendTestNotification() async {
    debugPrint('WEB PUSH TEST: started');
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) {
      return const WebPushSetupResult(
        success: false,
        status: 'Test notification failed',
        message: 'Please sign in before sending a test notification.',
      );
    }

    try {
      final response = await SupabaseService.instance.client.functions.invoke(
        'send_web_push',
        body: {
          'user_id': uid,
          'type': 'test_notification',
          'title': 'FaceMeet notifications are working',
          'body': 'You’ll get alerts for Sparks, sessions, and messages.',
          'data': {'type': 'test_notification', 'url': '/'},
        },
      );

      final data = response.data;
      final successCount = data is Map
          ? (data['success_count'] as int? ?? 0)
          : 0;
      final ok = successCount > 0;
      debugPrint('WEB PUSH TEST: success/failure=$ok');
      return WebPushSetupResult(
        success: ok,
        status: ok ? 'Test notification sent' : 'Test notification failed',
        message: ok
            ? 'Test notification sent.'
            : 'No active notification subscription received the test.',
      );
    } catch (e) {
      debugPrint('WEB PUSH TEST: failure — $e');
      return const WebPushSetupResult(
        success: false,
        status: 'Test notification failed',
        message: 'Test notification failed. Please try again.',
      );
    }
  }

  Future<bool> sendWebPushNotification({
    required String userId,
    required String type,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    if (type != 'new_spark' &&
        type != 'new_match' &&
        type != 'spark_session' &&
        type != 'spark_schedule_proposed' &&
        type != 'spark_schedule_accepted' &&
        type != 'spark_schedule_reminder' &&
        type != 'spark_schedule_ready' &&
        type != 'chat_unlocked' &&
        type != 'new_message' &&
        type != 'live_topic_invite') {
      debugPrint('WEB PUSH: event wiring disabled in Phase 2E type=$type');
      return false;
    }

    debugPrint('SPARK PUSH: send_web_push called');
    try {
      final response = await SupabaseService.instance.client.functions.invoke(
        'send_web_push',
        body: {
          'user_id': userId,
          'type': type,
          'title': title,
          'body': body,
          'data': {...data, 'type': type},
        },
      );
      final responseData = response.data;
      final successCount = responseData is Map
          ? (responseData['success_count'] as int? ?? 0)
          : 0;
      final failureCount = responseData is Map
          ? (responseData['failure_count'] as int? ?? 0)
          : 0;
      debugPrint(
        'SPARK PUSH: success/failure=${successCount > 0}/$failureCount',
      );
      return successCount > 0;
    } catch (e) {
      debugPrint('SPARK PUSH: success/failure=false — $e');
      return false;
    }
  }

  bool _callJsBool(String functionName) {
    final fn = js_util.getProperty(js_util.globalThis, functionName);
    if (fn == null) return false;
    return js_util.callMethod(js_util.globalThis, functionName, []) == true;
  }

  String _callJsString(String functionName) {
    final fn = js_util.getProperty(js_util.globalThis, functionName);
    if (fn == null) return 'unsupported';
    return js_util
            .callMethod(js_util.globalThis, functionName, [])
            ?.toString() ??
        'unsupported';
  }

  Future<dynamic> _callJsPromise(
    String functionName,
    List<dynamic> args,
  ) async {
    final promise = js_util.callMethod(js_util.globalThis, functionName, args);
    return await js_util.promiseToFuture<dynamic>(promise);
  }

  Map<String, dynamic> _jsObjectToMap(dynamic value) {
    final keys = js_util.objectKeys(value).cast<String>();
    return {
      for (final key in keys) key: js_util.getProperty<dynamic>(value, key),
    };
  }

  Future<bool> _saveSubscription({
    required String endpoint,
    required String p256dh,
    required String auth,
    required String userAgent,
    required String platform,
  }) async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return false;

    try {
      final response = await SupabaseService.instance.client.functions.invoke(
        'register_web_push_subscription',
        body: {
          'endpoint': endpoint,
          'p256dh': p256dh,
          'auth': auth,
          'user_agent': userAgent,
          'platform': platform,
        },
      );
      final data = response.data;
      final success = data is Map && data['success'] == true;
      debugPrint(
        'WEB PUSH: subscription registration function success=$success',
      );
      return success;
    } catch (e) {
      debugPrint('WEB PUSH: saving subscription failed — $e');
      return false;
    }
  }

  Future<bool> _verifySavedSubscription({String? endpoint}) async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return false;

    try {
      var query = SupabaseService.instance.client
          .from('web_push_subscriptions')
          .select('endpoint, p256dh, auth, is_active')
          .eq('user_id', uid)
          .eq('is_active', true);
      if (endpoint != null && endpoint.isNotEmpty) {
        query = query.eq('endpoint', endpoint);
      }
      final rows = await query.limit(1);
      if (rows is! List || rows.isEmpty) return false;
      final row = Map<String, dynamic>.from(rows.first as Map);
      return (row['endpoint'] as String? ?? '').isNotEmpty &&
          (row['p256dh'] as String? ?? '').isNotEmpty &&
          (row['auth'] as String? ?? '').isNotEmpty &&
          row['is_active'] == true;
    } catch (e) {
      debugPrint('WEB PUSH: subscription verification failed — $e');
      return false;
    }
  }

  String _diagnosticMessage({
    required bool permissionGranted,
    required bool serviceWorkerReady,
    required bool isFaceMeetWorker,
    required bool subscriptionCreated,
    required bool subscriptionSaved,
    required bool subscriptionVerified,
    required String fallback,
  }) {
    return '$fallback\n'
        'Permission granted: ${permissionGranted ? 'yes' : 'no'}\n'
        'FaceMeet push worker: ${serviceWorkerReady && isFaceMeetWorker ? 'yes' : 'no'}\n'
        'Subscription created: ${subscriptionCreated ? 'yes' : 'no'}\n'
        'Subscription saved: ${subscriptionSaved ? 'yes' : 'no'}\n'
        'Subscription verified: ${subscriptionVerified ? 'yes' : 'no'}';
  }
}
