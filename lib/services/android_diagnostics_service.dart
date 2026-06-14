import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'supabase_service.dart';

class AndroidDiagnosticsService extends ChangeNotifier {
  static final AndroidDiagnosticsService instance =
      AndroidDiagnosticsService._();
  AndroidDiagnosticsService._();

  static const String _prefsKey = 'facemeet_android_diagnostics';

  final Map<String, String> _state = <String, String>{};
  bool _loaded = false;

  Map<String, String> get snapshot => Map.unmodifiable(_state);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          _state
            ..clear()
            ..addAll(
              decoded.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              ),
            );
        }
      }
    } catch (e) {
      debugPrint('ANDROID DIAGNOSTICS: load failed — $e');
    }
    _ensureBaseFields();
    notifyListeners();
  }

  Future<void> setValue(String key, Object? value) async {
    _state[key] = _safeValue(value);
    _state['diagnostics_updated_at'] = DateTime.now().toIso8601String();
    notifyListeners();
    await _persist();
  }

  Future<void> setValues(Map<String, Object?> values) async {
    values.forEach((key, value) {
      _state[key] = _safeValue(value);
    });
    _state['diagnostics_updated_at'] = DateTime.now().toIso8601String();
    notifyListeners();
    await _persist();
  }

  Future<void> recordPushPayload({
    required String source,
    required Map<String, dynamic> data,
  }) async {
    await setValues({
      source: _safePayloadSummary(data),
      'last_push_event_source': source,
    });
  }

  Future<void> recordBackgroundMessage(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      final current = raw == null || raw.isEmpty
          ? <String, String>{}
          : (jsonDecode(raw) as Map).map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            );
      current['last_background_message_payload'] = _safePayloadSummary(data);
      current['last_push_event_source'] = 'background_message';
      current['diagnostics_updated_at'] = DateTime.now().toIso8601String();
      await prefs.setString(_prefsKey, jsonEncode(current));
    } catch (e) {
      debugPrint('ANDROID DIAGNOSTICS: background record failed — $e');
    }
  }

  Future<void> verifyDeviceTokenReadback({String? fcmToken}) async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null || uid.isEmpty) {
      await setValues({
        'device_tokens_readback_found': 'no',
        'device_tokens_readback_note': 'no current user',
      });
      return;
    }

    try {
      final baseQuery = SupabaseService.instance.client
          .from('device_tokens')
          .select('platform, updated_at')
          .eq('user_id', uid)
          .eq('platform', 'android');
      final rows =
          await (fcmToken != null && fcmToken.isNotEmpty
                  ? baseQuery.eq('fcm_token', fcmToken)
                  : baseQuery)
              .order('updated_at', ascending: false)
              .limit(1);
      final found = rows.isNotEmpty;
      final row = found ? Map<String, dynamic>.from(rows.first as Map) : null;
      await setValues({
        'fcm_token_saved_in_supabase': found ? 'yes' : 'no',
        'device_tokens_readback_found': found ? 'yes' : 'no',
        'latest_device_token_platform': row?['platform'] ?? 'not found',
        'latest_device_token_updated_at': row?['updated_at'] ?? 'not found',
      });
    } catch (e) {
      await setValues({
        'device_tokens_readback_found': 'error',
        'device_tokens_readback_note': _safeError(e),
      });
    }
  }

  Future<List<String>> buildProfileLines() async {
    await load();
    final packageInfo = await PackageInfo.fromPlatform();
    final uid = SupabaseService.instance.currentUserId;
    final platform = kIsWeb
        ? 'Web'
        : defaultTargetPlatform == TargetPlatform.android
        ? 'Android'
        : defaultTargetPlatform.name;

    final merged = <String, String>{
      ..._state,
      'app_version_build': '${packageInfo.version}+${packageInfo.buildNumber}',
      'platform': platform,
      'current_user_id': shortId(uid),
      'android_os_version': _androidOsVersion(),
    };

    const orderedKeys = [
      'app_version_build',
      'platform',
      'android_os_version',
      'current_user_id',
      'fcm_permission_status',
      'android_notifications_enabled_before',
      'android_permission_api_available',
      'android_permission_request_attempted',
      'android_permission_request_result',
      'android_notifications_enabled_after',
      'fcm_token_generated',
      'device_tokens_upsert_attempted',
      'fcm_token_saved_in_supabase',
      'device_tokens_readback_found',
      'latest_device_token_platform',
      'latest_device_token_updated_at',
      'last_push_invoke_result',
      'last_spark_notification_payload',
      'last_notification_tap_payload',
      'last_foreground_message_payload',
      'last_opened_app_payload',
      'last_initial_message_payload',
      'last_background_message_payload',
      'current_spark_match_id',
      'client_session_key',
      'canonical_session_key',
      'daily_access_succeeded',
      'daily_room_host_path',
      'meeting_token_received',
      'native_daily_join_success',
      'remote_participant_count_immediate',
      'remote_participant_count_delayed',
      'waiting_overlay_active',
      'waiting_overlay_reason',
      'last_daily_participant_event',
      'diagnostics_updated_at',
    ];

    return orderedKeys
        .map((key) => '$key: ${merged[key] ?? 'unknown'}')
        .toList();
  }

  static String shortId(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return 'none';
    if (text.length <= 12) return text;
    return '${text.substring(0, 6)}...${text.substring(text.length - 4)}';
  }

  static String roomHostPath(String? roomUrl) {
    final raw = roomUrl?.trim() ?? '';
    if (raw.isEmpty) return 'none';
    try {
      final uri = Uri.parse(raw);
      final path = uri.path.isEmpty ? '/' : uri.path;
      return '${uri.host}$path';
    } catch (_) {
      return 'unavailable';
    }
  }

  static String _safePayloadSummary(Map<String, dynamic> data) {
    final type = data['type']?.toString().trim();
    final matchId = data['match_id']?.toString().trim();
    final sessionKey = data['session_key']?.toString().trim();
    return [
      'type=${type == null || type.isEmpty ? 'none' : type}',
      'match_id=${shortId(matchId)}',
      if (sessionKey != null && sessionKey.isNotEmpty)
        'session_key=${shortId(sessionKey)}',
    ].join(', ');
  }

  void _ensureBaseFields() {
    _state.putIfAbsent('diagnostics_updated_at', () => 'not yet updated');
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_state));
    } catch (e) {
      debugPrint('ANDROID DIAGNOSTICS: persist failed — $e');
    }
  }

  static String _safeValue(Object? value) {
    final text = value?.toString().trim() ?? 'unknown';
    if (text.isEmpty) return 'unknown';
    if (text.length > 160) return '${text.substring(0, 157)}...';
    return text;
  }

  static String _safeError(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '').trim();
    if (text.isEmpty) return 'unknown error';
    if (text.length > 80) return '${text.substring(0, 77)}...';
    return text;
  }

  static String _androidOsVersion() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return 'not android';
    }
    return 'unavailable in Flutter layer';
  }
}
