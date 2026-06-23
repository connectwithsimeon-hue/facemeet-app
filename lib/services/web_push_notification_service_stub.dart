import 'package:flutter/material.dart';

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

  Future<void> maybeShowEnablePrompt(BuildContext? context) async {}

  Future<void> openNotificationSettings(BuildContext context) async {}

  Future<String> notificationStatusLabel() async => 'Enable Notifications';

  Future<WebPushSetupResult> currentSetupState() async {
    return const WebPushSetupResult(
      success: false,
      status: 'Notifications unavailable',
      message: 'Web push is only available in the web app.',
    );
  }

  Future<WebPushSetupResult> enableNotifications() async {
    return const WebPushSetupResult(
      success: false,
      status: 'Notifications unavailable',
      message: 'Web push is only available in the web app.',
    );
  }

  Future<WebPushSetupResult> refreshExistingSubscription() async {
    return const WebPushSetupResult(
      success: false,
      status: 'Notifications unavailable',
      message: 'Web push is only available in the web app.',
    );
  }

  Future<WebPushSetupResult> sendTestNotification() async {
    return const WebPushSetupResult(
      success: false,
      status: 'Notifications unavailable',
      message: 'Web push is only available in the web app.',
    );
  }

  Future<bool> sendWebPushNotification({
    required String userId,
    required String type,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    debugPrint('WEB PUSH DISABLED: send_web_push skipped type=$type');
    return false;
  }
}
