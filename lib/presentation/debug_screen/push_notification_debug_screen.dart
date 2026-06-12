import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/push_notification_service.dart';

/// Temporary in-app debug screen for diagnosing iOS push notification issues.
/// Access via the debug button on the profile screen or by navigating directly.
/// Remove this screen once push notifications are confirmed working.
class PushNotificationDebugScreen extends StatefulWidget {
  const PushNotificationDebugScreen({super.key});

  @override
  State<PushNotificationDebugScreen> createState() =>
      _PushNotificationDebugScreenState();
}

class _PushNotificationDebugScreenState
    extends State<PushNotificationDebugScreen> {
  bool _loading = false;

  // Diagnostic results
  String _permissionStatus = 'Not checked';
  bool? _apnsTokenExists;
  bool? _fcmTokenExists;
  int? _fcmTokenLength;
  bool? _userIdExists;
  String? _userId;
  bool? _tokenSavedToSupabase;
  String? _supabaseError;
  String? _platform;
  List<String> _logs = [];

  // Native method channel for iOS APNs/Firebase Installations reset
  static const MethodChannel _iosChannel = MethodChannel(
    'com.ononobi.facemeet/push',
  );

  @override
  void initState() {
    super.initState();
    // Import existing logs from PushNotificationService
    _importExistingLogs();
    // Run diagnostics automatically on open
    WidgetsBinding.instance.addPostFrameCallback((_) => _runDiagnostics());
  }

  void _importExistingLogs() {
    try {
      final existing = PushNotificationService.debugLogs;
      if (existing.isNotEmpty) {
        _logs = List.from(existing);
      }
    } catch (_) {}
  }

  void _addLog(String message) {
    final entry = '[${DateTime.now().toIso8601String()}] $message';
    debugPrint('[PUSH_DEBUG_SCREEN] $message');
    setState(() {
      _logs.add(entry);
    });
  }

  /// Full iOS debug reset:
  /// 1. Delete old Supabase token for this user
  /// 2. Delete Firebase FCM token
  /// 3. Delete Firebase Installation ID via native channel
  /// 4. Wait for APNs re-registration
  /// 5. Get new FCM token
  /// 6. Save to Supabase
  Future<void> _retryApnsRegistration() async {
    setState(() {
      _loading = true;
      _logs.clear();
    });
    _addLog('=== iOS Full Reset & Re-Registration START ===');

    try {
      // ── Step 1: Delete old Supabase token ──────────────────────────────
      _addLog('Step 1: Deleting old Supabase device_tokens for this user...');
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        try {
          await Supabase.instance.client
              .from('device_tokens')
              .delete()
              .eq('user_id', userId)
              .eq('platform', 'ios');
          _addLog('Step 1: Old iOS Supabase tokens deleted');
        } catch (e) {
          _addLog('Step 1: Supabase delete error (non-fatal): $e');
        }
      } else {
        _addLog('Step 1: No user logged in — skipping Supabase token delete');
      }

      // ── Step 2: Delete Firebase FCM token ──────────────────────────────
      _addLog('Step 2: Deleting Firebase FCM token...');
      try {
        await FirebaseMessaging.instance.deleteToken();
        _addLog('Step 2: Firebase FCM token deleted');
      } catch (e) {
        _addLog('Step 2: FCM token delete error (non-fatal): $e');
      }

      // ── Step 3: Delete Firebase Installation ID via native channel ──────
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        _addLog(
          'Step 3: Deleting Firebase Installation ID via native channel...',
        );
        try {
          await _iosChannel.invokeMethod('deleteFirebaseInstallation');
          _addLog('Step 3: Firebase Installation ID deleted');
        } catch (e) {
          _addLog('Step 3: Firebase Installation delete error (non-fatal): $e');
        }

        // ── Step 4: Re-register for APNs via native channel ────────────────
        _addLog('Step 4: Calling native registerForRemoteNotifications...');
        try {
          await _iosChannel.invokeMethod('registerForRemoteNotifications');
          _addLog('Step 4: Native APNs registration triggered');
        } catch (e) {
          _addLog('Step 4: Native APNs registration error (non-fatal): $e');
        }

        // Wait for APNs token to be issued
        _addLog('Step 4: Waiting 3s for APNs token...');
        await Future.delayed(const Duration(seconds: 3));

        // ── Step 5: Get APNs token ──────────────────────────────────────────
        _addLog('Step 5: Fetching APNs token...');
        try {
          final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
          _apnsTokenExists = apnsToken != null;
          _addLog('Step 5: APNs token exists: $_apnsTokenExists');
          if (_apnsTokenExists == true) {
            // Log only fingerprint (first 8 + last 4 chars) for security
            final t = apnsToken!;
            final fingerprint = t.length > 12
                ? '${t.substring(0, 8)}...${t.substring(t.length - 4)}'
                : '(short token)';
            _addLog('Step 5: APNs token fingerprint: $fingerprint');
          }
        } catch (e) {
          _addLog('Step 5: APNs token fetch error: $e');
        }
      } else {
        _addLog('Step 3-5: Android — skipping iOS-specific APNs steps');
      }

      // ── Step 6: Get new FCM token ───────────────────────────────────────
      _addLog('Step 6: Fetching new FCM token...');
      await Future.delayed(const Duration(seconds: 1));
      final fcmToken = await FirebaseMessaging.instance.getToken();
      _fcmTokenExists = fcmToken != null;
      _fcmTokenLength = fcmToken?.length;
      _addLog('Step 6: FCM token exists: $_fcmTokenExists');

      if (fcmToken != null) {
        // Log only fingerprint
        final fingerprint = fcmToken.length > 12
            ? '${fcmToken.substring(0, 8)}...${fcmToken.substring(fcmToken.length - 4)}'
            : '(short token)';
        _addLog('Step 6: FCM token fingerprint: $fingerprint');

        // ── Step 7: Save to Supabase ──────────────────────────────────────
        _addLog('Step 7: Saving new FCM token to Supabase...');
        if (userId != null) {
          await _saveTokenToSupabase(fcmToken);
        } else {
          _addLog('Step 7: No user logged in — skipping Supabase save');
        }
      } else {
        _addLog('Step 6: FCM token is NULL — registration failed');
        _addLog(
          'Check: APNs Auth Key in Firebase Console → Project Settings → Cloud Messaging → iOS app\n'
          'Key must belong to Apple Team 9777KXMY5P',
        );
      }
    } catch (e, st) {
      _addLog('Reset error: $e\n$st');
    }

    _addLog('=== iOS Full Reset & Re-Registration COMPLETE ===');
    setState(() => _loading = false);
    // Run full diagnostics to refresh all status rows.
    await _runDiagnostics();
  }

  Future<void> _runDiagnostics() async {
    setState(() {
      _loading = true;
      _logs.clear();
    });

    _addLog('=== iOS Push Notification Diagnostics START ===');
    _addLog('Platform: ${defaultTargetPlatform.name}, kIsWeb: $kIsWeb');

    // ── 1. Platform ────────────────────────────────────────────────────────
    _platform = kIsWeb
        ? 'web'
        : (defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android');
    _addLog('Detected platform: $_platform');

    // ── 2. Current user ────────────────────────────────────────────────────
    final user = Supabase.instance.client.auth.currentUser;
    _userIdExists = user != null;
    _userId = user?.id;
    _addLog('Current user ID exists: $_userIdExists');
    if (_userIdExists == true) {
      _addLog('User ID (first 8 chars): ${_userId!.substring(0, 8)}...');
    }

    if (kIsWeb) {
      _addLog('Web platform — FCM/APNs not applicable on web.');
      setState(() => _loading = false);
      return;
    }

    // ── 3. Notification permission ─────────────────────────────────────────
    try {
      final settings = await FirebaseMessaging.instance
          .getNotificationSettings();
      _permissionStatus = settings.authorizationStatus.name;
      _addLog('Notification permission status: $_permissionStatus');
    } catch (e) {
      _permissionStatus = 'Error: $e';
      _addLog('ERROR getting permission status: $e');
    }

    // ── 4. APNs token (iOS only) ───────────────────────────────────────────
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        _addLog('Requesting APNs token...');
        final apnsToken = await FirebaseMessaging.instance.getAPNSToken();
        _apnsTokenExists = apnsToken != null;
        _addLog('APNs token exists: $_apnsTokenExists');
        if (_apnsTokenExists == true) {
          _addLog('APNs token length: ${apnsToken!.length}');
        } else {
          _addLog(
            'APNs token is NULL — this means either:\n'
            '  a) Push Notifications capability not enabled in Apple Developer portal\n'
            '  b) APNs Auth Key not uploaded in Firebase Console\n'
            '  c) Bundle ID mismatch between app and Firebase project\n'
            '  d) Running on Simulator (APNs not supported)',
          );
        }
      } catch (e) {
        _apnsTokenExists = false;
        _addLog('ERROR getting APNs token: $e');
      }
    } else {
      _addLog('Android — APNs token not applicable');
      _apnsTokenExists = null;
    }

    // ── 5. FCM token ───────────────────────────────────────────────────────
    try {
      _addLog('Requesting FCM token...');
      final fcmToken = await FirebaseMessaging.instance.getToken();
      _fcmTokenExists = fcmToken != null;
      _fcmTokenLength = fcmToken?.length;
      _addLog('FCM token exists: $_fcmTokenExists');
      if (_fcmTokenExists == true) {
        _addLog('FCM token length: $_fcmTokenLength');

        // ── 6. Save token to Supabase ──────────────────────────────────────
        if (_userIdExists == true) {
          _addLog('Attempting to save FCM token to Supabase device_tokens...');
          await _saveTokenToSupabase(fcmToken!);
        } else {
          _addLog('Skipping Supabase save — no logged-in user.');
          _tokenSavedToSupabase = false;
        }
      } else {
        _addLog(
          'FCM token is NULL — this means either:\n'
          '  a) APNs token was null (FCM requires APNs on iOS)\n'
          '  b) Firebase project not configured for this bundle ID\n'
          '  c) GoogleService-Info.plist missing or wrong bundle ID',
        );
        _tokenSavedToSupabase = false;
      }
    } catch (e) {
      _fcmTokenExists = false;
      _addLog('ERROR getting FCM token: $e');
      _tokenSavedToSupabase = false;
    }

    _addLog('=== Diagnostics COMPLETE ===');
    setState(() => _loading = false);
  }

  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) {
        _addLog('Supabase save skipped — userId is null');
        _tokenSavedToSupabase = false;
        return;
      }

      await Supabase.instance.client.from('device_tokens').upsert({
        'user_id': userId,
        'fcm_token': token,
        'platform': _platform,
        'updated_at': DateTime.now().toIso8601String(),
        'last_seen_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,fcm_token');

      _tokenSavedToSupabase = true;
      _supabaseError = null;
      _addLog('Supabase device_tokens upsert: SUCCESS');
      _addLog('Token saved under user_id: ${userId.substring(0, 8)}...');
    } catch (e) {
      _tokenSavedToSupabase = false;
      _supabaseError = e.toString();
      _addLog('Supabase device_tokens upsert: FAILED');
      _addLog('Supabase error: $e');
    }
  }

  Widget _buildStatusRow(String label, bool? value, {String? detail}) {
    final color = value == null
        ? Colors.grey
        : (value ? Colors.green : Colors.red);
    final icon = value == null
        ? Icons.help_outline
        : (value ? Icons.check_circle : Icons.cancel);
    final text = value == null ? 'N/A' : (value ? 'YES' : 'NO');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
                if (detail != null)
                  Text(
                    detail,
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withAlpha(51),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withAlpha(128)),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        title: const Text(
          'Push Notification Debug',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _runDiagnostics,
            tooltip: 'Re-run diagnostics',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFFE8503A),
                    ),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Running diagnostics...',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Status Summary Card ──────────────────────────────────
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF252540),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Diagnostic Summary',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Platform: ${_platform ?? "detecting..."}',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 12,
                          ),
                        ),
                        const Divider(color: Colors.white12, height: 20),
                        _buildStatusRow(
                          'Notification Permission',
                          _permissionStatus == 'authorized'
                              ? true
                              : (_permissionStatus == 'Not checked'
                                    ? null
                                    : false),
                          detail: _permissionStatus,
                        ),
                        if (defaultTargetPlatform == TargetPlatform.iOS)
                          _buildStatusRow(
                            'APNs Token Exists',
                            _apnsTokenExists,
                            detail: _apnsTokenExists == false
                                ? 'Required for iOS FCM'
                                : null,
                          ),
                        _buildStatusRow(
                          'FCM Token Exists',
                          _fcmTokenExists,
                          detail: _fcmTokenExists == true
                              ? 'Length: $_fcmTokenLength chars'
                              : null,
                        ),
                        _buildStatusRow(
                          'Current User ID Exists',
                          _userIdExists,
                          detail: _userIdExists == true && _userId != null
                              ? 'ID: ${_userId!.substring(0, 8)}...'
                              : null,
                        ),
                        _buildStatusRow(
                          'Token Saved to Supabase',
                          _tokenSavedToSupabase,
                          detail: _supabaseError != null
                              ? 'Error: ${_supabaseError!.length > 60 ? "${_supabaseError!.substring(0, 60)}..." : _supabaseError}'
                              : null,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // ── Diagnosis ────────────────────────────────────────────
                  if (!_loading) _buildDiagnosis(),

                  const SizedBox(height: 16),

                  // ── Full iOS Reset Button ────────────────────────────────
                  if (!_loading && defaultTargetPlatform == TargetPlatform.iOS)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _retryApnsRegistration,
                        icon: const Icon(Icons.restart_alt, size: 18),
                        label: const Text('Full iOS Reset & Re-Register APNs'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE8503A),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),

                  if (!_loading && defaultTargetPlatform == TargetPlatform.iOS)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Deletes old Supabase token, Firebase FCM token, and Firebase Installation ID, then re-registers APNs and saves a fresh token.',
                        style: TextStyle(color: Colors.grey[500], fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                    ),

                  const SizedBox(height: 16),

                  // ── Log Output ───────────────────────────────────────────
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0D0D1A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Debug Logs',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._logs.map(
                          (log) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              log,
                              style: TextStyle(
                                color:
                                    log.contains('ERROR') ||
                                        log.contains('FAILED') ||
                                        log.contains('NULL')
                                    ? Colors.red[300]
                                    : log.contains('SUCCESS') ||
                                          log.contains('exists: true') ||
                                          log.contains('YES')
                                    ? Colors.green[300]
                                    : Colors.grey[400],
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ),
                        if (_logs.isEmpty)
                          const Text(
                            'No logs yet. Tap refresh to run diagnostics.',
                            style: TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }

  Widget _buildDiagnosis() {
    String diagnosis = '';
    Color diagColor = Colors.orange;

    if (_permissionStatus != 'authorized' &&
        _permissionStatus != 'Not checked') {
      diagnosis =
          '⚠️ FAILING STEP: Notification permission is "$_permissionStatus".\n\n'
          'Fix: Go to iPhone Settings → FaceMeet → Notifications → Allow Notifications.';
      diagColor = Colors.red;
    } else if (defaultTargetPlatform == TargetPlatform.iOS &&
        _apnsTokenExists == false) {
      diagnosis =
          '⚠️ FAILING STEP: APNs token is NULL.\n\n'
          'This is the root cause. Without an APNs token, Firebase cannot generate an FCM token.\n\n'
          'Likely causes:\n'
          '1. APNs Auth Key (.p8) not uploaded in Firebase Console → Project Settings → Cloud Messaging → iOS app\n'
          '2. Key must belong to Apple Team 9777KXMY5P\n'
          '3. Push Notifications capability not enabled in Apple Developer portal for bundle ID com.ononobi.facemeet\n'
          '4. Running on Simulator (APNs only works on real devices)\n'
          '5. Provisioning profile does not include push notification entitlement';
      diagColor = Colors.red;
    } else if (_fcmTokenExists == false) {
      diagnosis =
          '⚠️ FAILING STEP: FCM token is NULL.\n\n'
          'APNs token was obtained but Firebase could not generate an FCM token.\n\n'
          'Likely causes:\n'
          '1. GoogleService-Info.plist bundle ID does not match com.ononobi.facemeet\n'
          '2. Firebase project Cloud Messaging not properly configured\n'
          '3. APNs Auth Key in Firebase Console does not match Team ID 9777KXMY5P\n'
          '4. Network connectivity issue during token fetch\n\n'
          'Use "Full iOS Reset & Re-Register APNs" button to force a fresh token.';
      diagColor = Colors.red;
    } else if (_userIdExists == false) {
      diagnosis =
          '⚠️ FAILING STEP: No logged-in user.\n\n'
          'FCM token was obtained but cannot be saved to Supabase because no user is signed in.\n\n'
          'Fix: Log in first, then re-run diagnostics.';
      diagColor = Colors.orange;
    } else if (_tokenSavedToSupabase == false && _supabaseError != null) {
      diagnosis =
          '⚠️ FAILING STEP: Supabase token save failed.\n\n'
          'FCM token was obtained but could not be saved to device_tokens table.\n\n'
          'Error: $_supabaseError\n\n'
          'Likely causes:\n'
          '1. Missing unique index on (user_id, fcm_token) — fixed by migration 20260504173400\n'
          '2. RLS policy blocking insert — policy "users_manage_own_device_tokens" must allow authenticated users\n'
          '3. platform column CHECK constraint — only "ios" and "android" are allowed (not "web")';
      diagColor = Colors.red;
    } else if (_tokenSavedToSupabase == true && _fcmTokenExists == true) {
      diagnosis =
          '✅ All steps PASSED.\n\n'
          'APNs token: obtained\n'
          'FCM token: obtained\n'
          'Token saved to Supabase: success\n\n'
          'If notifications still do not arrive, the issue is on the SENDER side:\n'
          '1. Check that the notification sender (Edge Function or backend) is reading the FCM token from device_tokens for this user\n'
          '2. Verify the notification payload includes "notification" object (not just "data") for iOS\n'
          '3. Verify APNs Auth Key in Firebase Console is for Team ID 9777KXMY5P and Key ID matches\n'
          '4. BadEnvironmentKeyInToken = APNs key/environment mismatch in Firebase Console';
      diagColor = Colors.green;
    } else {
      diagnosis = 'Run diagnostics to see results.';
      diagColor = Colors.grey;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: diagColor.withAlpha(26),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: diagColor.withAlpha(102)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Diagnosis',
            style: TextStyle(
              color: diagColor,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            diagnosis,
            style: TextStyle(color: diagColor.withAlpha(230), fontSize: 13),
          ),
        ],
      ),
    );
  }
}
