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
      'last_push_recipient_id',
      'last_push_token_rows_found',
      'last_push_android_token_rows_found',
      'last_push_native_sent',
      'last_push_web_sent',
      'last_push_edge_reason',
      'android_push_target_token_count',
      'fcm_send_attempted',
      'fcm_success_count',
      'fcm_failure_reason_safe',
      'last_fcm_message_received',
      'last_local_notification_shown',
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
      'daily_participant_total_count',
      'daily_remote_participant_ids',
      'remote_participant_count_immediate',
      'remote_participant_count_delayed',
      'waiting_overlay_active',
      'waiting_overlay_reason',
      'last_daily_participant_event',
      'suppressed_session_popup_reason',
      'last_session_status',
      'last_session_ended_at',
      'last_session_chat_unlocked',
      'last_session_feedback_complete',
      ...sparkRoomEntryDiagnosticKeys,
      'diagnostics_updated_at',
    ];

    return orderedKeys
        .map((key) => '$key: ${merged[key] ?? 'unknown'}')
        .toList();
  }

  static const List<String> sparkRoomEntryDiagnosticKeys = [
    'spark_diag_app_version_build',
    'spark_diag_platform',
    'spark_diag_diagnostics_build',
    'spark_diag_current_user_short',
    'spark_diag_match_id_short',
    'spark_diag_session_id_short',
    'spark_diag_session_key_short',
    'spark_diag_user_slot',
    'spark_diag_daily_access_attempted',
    'spark_diag_daily_access_success',
    'spark_diag_daily_access_error_safe',
    'spark_diag_daily_access_error_code',
    'spark_diag_daily_room_available_yes_no',
    'spark_diag_daily_token_received_yes_no',
    'spark_diag_daily_access_http_status',
    'spark_diag_ready_skipped_reason',
    'spark_diag_retry_available_yes_no',
    'spark_diag_ready_update_attempted',
    'spark_diag_ready_update_success',
    'spark_diag_ready_update_error_safe',
    'spark_diag_ready_readback_user_1',
    'spark_diag_ready_readback_user_2',
    'spark_diag_ready_poll_tick_count',
    'spark_diag_ready_poll_latest_user_1',
    'spark_diag_ready_poll_latest_user_2',
    'spark_diag_ready_poll_latest_status',
    'spark_diag_launch_call_called',
    'spark_diag_room_join_mode',
    'spark_diag_native_daily_join_attempted',
    'spark_diag_native_daily_join_success',
    'spark_diag_native_daily_join_error_safe',
    'spark_diag_web_daily_join_attempted',
    'spark_diag_web_daily_join_success',
    'spark_diag_web_daily_join_error_safe',
    'spark_diag_remote_participant_count',
    'spark_diag_remote_participant_ever_seen',
    'spark_diag_feedback_allowed',
    'spark_diag_end_reason',
    'spark_diag_duplicate_session_guard',
    'spark_diag_lock_used',
    'spark_diag_waiting_reason',
    'spark_diag_repeat_invite_created',
    'spark_diag_repeat_invite_target_user_short',
    'spark_diag_repeat_popup_seen',
    'spark_diag_repeat_popup_suppressed_reason',
    'spark_diag_repeat_popup_source',
    'spark_diag_repeat_popup_match_id_short',
    'spark_diag_repeat_popup_session_key_short',
  ];

  Future<List<String>> buildSparkRoomEntryLines() async {
    await load();
    final packageInfo = await PackageInfo.fromPlatform();
    final platform = kIsWeb
        ? 'Web'
        : defaultTargetPlatform == TargetPlatform.android
        ? 'Android'
        : defaultTargetPlatform.name;
    final merged = <String, String>{
      ..._state,
      'spark_diag_app_version_build':
          '${packageInfo.version}+${packageInfo.buildNumber}',
      'spark_diag_platform': platform,
      'spark_diag_diagnostics_build': 'yes',
    };
    return sparkRoomEntryDiagnosticKeys
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

  static String safeError(Object error) => _safeError(error);

  static String _androidOsVersion() {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return 'not android';
    }
    return 'unavailable in Flutter layer';
  }
}
