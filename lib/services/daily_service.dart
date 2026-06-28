import 'package:flutter/foundation.dart';

import 'android_diagnostics_service.dart';
import 'supabase_service.dart';

class DailyAccessResult {
  final String matchId;
  final String sessionId;
  final String sessionKey;
  final String roomUrl;
  final String meetingToken;
  final DateTime roomExpiresAt;
  final DateTime tokenExpiresAt;
  final int maxParticipants;

  const DailyAccessResult({
    required this.matchId,
    required this.sessionId,
    required this.sessionKey,
    required this.roomUrl,
    required this.meetingToken,
    required this.roomExpiresAt,
    required this.tokenExpiresAt,
    required this.maxParticipants,
  });

  factory DailyAccessResult.fromMap(
    Map<String, dynamic> data, {
    int? httpStatus,
  }) {
    final matchId = (data['match_id'] as String? ?? '').trim();
    final sessionId = (data['session_id'] as String? ?? '').trim();
    final sessionKey = (data['session_key'] as String? ?? '').trim();
    final roomUrl = (data['room_url'] as String? ?? '').trim();
    final meetingToken = (data['meeting_token'] as String? ?? '').trim();
    final roomExpiresAtRaw = (data['room_expires_at'] as String? ?? '').trim();
    final tokenExpiresAtRaw = (data['token_expires_at'] as String? ?? '')
        .trim();
    final maxParticipants = (data['max_participants'] as num?)?.toInt() ?? 0;

    if (matchId.isEmpty ||
        sessionId.isEmpty ||
        sessionKey.isEmpty ||
        roomUrl.isEmpty ||
        meetingToken.isEmpty ||
        roomExpiresAtRaw.isEmpty ||
        tokenExpiresAtRaw.isEmpty ||
        maxParticipants <= 0) {
      throw DailyAccessException(
        message: 'spark session unavailable',
        code: 'malformed_daily_access_response',
        httpStatus: httpStatus,
      );
    }

    final roomExpiresAt = DateTime.tryParse(roomExpiresAtRaw);
    final tokenExpiresAt = DateTime.tryParse(tokenExpiresAtRaw);
    if (roomExpiresAt == null || tokenExpiresAt == null) {
      throw DailyAccessException(
        message: 'spark session unavailable',
        code: 'malformed_daily_access_response',
        httpStatus: httpStatus,
      );
    }

    return DailyAccessResult(
      matchId: matchId,
      sessionId: sessionId,
      sessionKey: sessionKey,
      roomUrl: roomUrl,
      meetingToken: meetingToken,
      roomExpiresAt: roomExpiresAt,
      tokenExpiresAt: tokenExpiresAt,
      maxParticipants: maxParticipants,
    );
  }
}

class LiveTopicDailyAccessResult {
  final String liveTopicId;
  final String roomUrl;
  final String meetingToken;
  final DateTime roomExpiresAt;
  final DateTime tokenExpiresAt;
  final int maxParticipants;

  const LiveTopicDailyAccessResult({
    required this.liveTopicId,
    required this.roomUrl,
    required this.meetingToken,
    required this.roomExpiresAt,
    required this.tokenExpiresAt,
    required this.maxParticipants,
  });

  factory LiveTopicDailyAccessResult.fromMap(Map<String, dynamic> data) {
    final liveTopicId = (data['live_topic_id'] as String? ?? '').trim();
    final roomUrl = (data['room_url'] as String? ?? '').trim();
    final meetingToken = (data['meeting_token'] as String? ?? '').trim();
    final roomExpiresAtRaw = (data['room_expires_at'] as String? ?? '').trim();
    final tokenExpiresAtRaw = (data['token_expires_at'] as String? ?? '')
        .trim();
    final maxParticipants = (data['max_participants'] as num?)?.toInt() ?? 0;

    if (liveTopicId.isEmpty ||
        roomUrl.isEmpty ||
        meetingToken.isEmpty ||
        roomExpiresAtRaw.isEmpty ||
        tokenExpiresAtRaw.isEmpty ||
        maxParticipants <= 0) {
      throw DailyAccessException(
        message: 'Live Topic video is unavailable',
        code: 'malformed_live_topic_daily_access_response',
      );
    }

    final roomExpiresAt = DateTime.tryParse(roomExpiresAtRaw);
    final tokenExpiresAt = DateTime.tryParse(tokenExpiresAtRaw);
    if (roomExpiresAt == null || tokenExpiresAt == null) {
      throw DailyAccessException(
        message: 'Live Topic video is unavailable',
        code: 'malformed_live_topic_daily_access_response',
      );
    }

    return LiveTopicDailyAccessResult(
      liveTopicId: liveTopicId,
      roomUrl: roomUrl,
      meetingToken: meetingToken,
      roomExpiresAt: roomExpiresAt,
      tokenExpiresAt: tokenExpiresAt,
      maxParticipants: maxParticipants,
    );
  }
}

class DailyService {
  static DailyService? _instance;
  static DailyService get instance => _instance ??= DailyService._();
  DailyService._();

  Future<DailyAccessResult> getSparkSessionDailyAccess({
    required String matchId,
    String? sessionKey,
  }) async {
    final safeMatchId = matchId.trim();
    if (safeMatchId.isEmpty) {
      throw Exception('invalid match');
    }

    final body = <String, dynamic>{'match_id': safeMatchId};
    final safeSessionKey = sessionKey?.trim();
    if (safeSessionKey != null && safeSessionKey.isNotEmpty) {
      body['session_key'] = safeSessionKey;
    }
    await AndroidDiagnosticsService.instance.setValues({
      'current_spark_match_id': AndroidDiagnosticsService.shortId(safeMatchId),
      'client_session_key': AndroidDiagnosticsService.shortId(safeSessionKey),
      'spark_diag_match_id_short': AndroidDiagnosticsService.shortId(
        safeMatchId,
      ),
      'spark_diag_session_key_short': AndroidDiagnosticsService.shortId(
        safeSessionKey,
      ),
      'spark_diag_daily_access_attempted': 'yes',
      'spark_diag_daily_access_success': 'pending',
      'spark_diag_daily_access_error_safe': 'none',
      'spark_diag_daily_access_error_code': 'none',
      'spark_diag_daily_access_http_status': 'pending',
      'spark_diag_daily_room_available_yes_no': 'unknown',
      'spark_diag_daily_token_received_yes_no': 'unknown',
      'spark_diag_retry_available_yes_no': 'unknown',
    });

    try {
      debugPrint(
        'SPARK DAILY ACCESS: invoking spark_session_get_daily_access for matchId=$safeMatchId',
      );
      final response = await SupabaseService.instance.client.functions.invoke(
        'spark_session_get_daily_access',
        body: body,
      );

      final data = response.data;
      await AndroidDiagnosticsService.instance.setValue(
        'spark_diag_daily_access_http_status',
        'unknown',
      );
      if (data is Map && data['error'] != null) {
        throw DailyAccessException(
          message: data['error'].toString(),
          code: data['error_code']?.toString() ?? 'daily_access_failed',
        );
      }
      if (data is! Map) {
        throw DailyAccessException(
          message: 'spark session unavailable',
          code: 'malformed_daily_access_response',
        );
      }

      final parsed = DailyAccessResult.fromMap(Map<String, dynamic>.from(data));
      await AndroidDiagnosticsService.instance.setValues({
        'daily_access_succeeded': 'yes',
        'canonical_session_key': AndroidDiagnosticsService.shortId(
          parsed.sessionKey,
        ),
        'daily_room_host_path': AndroidDiagnosticsService.roomHostPath(
          parsed.roomUrl,
        ),
        'meeting_token_received': parsed.meetingToken.isNotEmpty ? 'yes' : 'no',
        'spark_diag_daily_room_available_yes_no': parsed.roomUrl.isNotEmpty
            ? 'yes'
            : 'no',
        'spark_diag_daily_token_received_yes_no': parsed.meetingToken.isNotEmpty
            ? 'yes'
            : 'no',
        'spark_diag_daily_access_http_status': 'unknown',
        'spark_diag_session_id_short': AndroidDiagnosticsService.shortId(
          parsed.sessionId,
        ),
        'spark_diag_session_key_short': AndroidDiagnosticsService.shortId(
          parsed.sessionKey,
        ),
        'spark_diag_daily_access_success': 'yes',
        'spark_diag_daily_access_error_safe': 'none',
        'spark_diag_daily_access_error_code': 'none',
        'spark_diag_retry_available_yes_no': 'no',
        'spark_diag_lock_used': data['lock_used'] == true ? 'yes' : 'no',
        'spark_diag_duplicate_session_guard':
            (data['duplicate_guard_count'] ?? '0').toString(),
      });
      debugPrint(
        'SPARK DAILY ACCESS: access granted for matchId=${parsed.matchId}, sessionId=${parsed.sessionId}, token_present=${parsed.meetingToken.isNotEmpty}',
      );
      return parsed;
    } catch (e) {
      final code = e is DailyAccessException ? e.code : _safeErrorCode(e);
      final message = _safeErrorMessage(e);
      await AndroidDiagnosticsService.instance.setValues({
        'daily_access_succeeded': 'no',
        'meeting_token_received': 'no',
        'spark_diag_daily_access_success': 'no',
        'spark_diag_daily_access_error_safe': message,
        'spark_diag_daily_access_error_code': code,
        'spark_diag_daily_access_http_status': e is DailyAccessException
            ? (e.httpStatus?.toString() ?? 'unknown')
            : 'unknown',
        'spark_diag_daily_room_available_yes_no': 'unknown',
        'spark_diag_daily_token_received_yes_no': 'no',
        'spark_diag_retry_available_yes_no': _isTransientErrorCode(code)
            ? 'yes'
            : 'no',
      });
      debugPrint('SPARK DAILY ACCESS: request failed — $message');
      throw Exception(message);
    }
  }

  Future<LiveTopicDailyAccessResult> getLiveTopicDailyAccess({
    required String liveTopicId,
  }) async {
    final safeLiveTopicId = liveTopicId.trim();
    if (safeLiveTopicId.isEmpty) {
      throw Exception('invalid live topic');
    }

    try {
      debugPrint(
        'LIVE TOPIC DAILY ACCESS: invoking live_topic_get_daily_access for liveTopicId=$safeLiveTopicId',
      );
      final response = await SupabaseService.instance.client.functions.invoke(
        'live_topic_get_daily_access',
        body: {'live_topic_id': safeLiveTopicId},
      );

      final data = response.data;
      if (data is Map && data['error'] != null) {
        throw DailyAccessException(
          message: data['error'].toString(),
          code: data['error_code']?.toString() ?? 'daily_access_failed',
        );
      }
      if (data is! Map) {
        throw DailyAccessException(
          message: 'Live Topic video is unavailable',
          code: 'malformed_live_topic_daily_access_response',
        );
      }

      final parsed = LiveTopicDailyAccessResult.fromMap(
        Map<String, dynamic>.from(data),
      );
      debugPrint(
        'LIVE TOPIC DAILY ACCESS: access granted for liveTopicId=${parsed.liveTopicId}, token_present=${parsed.meetingToken.isNotEmpty}',
      );
      return parsed;
    } catch (error) {
      final message = _safeLiveTopicErrorMessage(error);
      debugPrint('LIVE TOPIC DAILY ACCESS: request failed — $message');
      throw Exception(message);
    }
  }

  bool _isTransientErrorCode(String code) {
    return const {
      'daily_access_failed',
      'daily_token_create_failed',
      'daily_room_missing',
      'daily_room_create_failed',
      'daily_room_reuse_failed',
      'claim_rpc_failed',
      'daily_service_unavailable',
      'malformed_daily_access_response',
    }.contains(code);
  }

  String _safeErrorCode(Object error) {
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    const knownCodes = [
      'daily_access_failed',
      'daily_token_create_failed',
      'daily_room_missing',
      'daily_room_create_failed',
      'daily_room_reuse_failed',
      'claim_rpc_failed',
      'daily_service_unavailable',
      'malformed_daily_access_response',
      'spark_session_unavailable',
    ];
    for (final code in knownCodes) {
      if (raw.contains(code)) return code;
    }
    return 'daily_access_failed';
  }

  String _safeErrorMessage(Object error) {
    final raw = error.toString().replaceFirst('Exception: ', '').trim();

    if (raw.contains('authentication required')) {
      return 'authentication required';
    }
    if (raw.contains('invalid match')) return 'invalid match';
    if (raw.contains('match not found')) return 'match not found';
    if (raw.contains('not authorized for this spark session')) {
      return 'not authorized for this spark session';
    }
    if (raw.contains('spark session expired')) return 'spark session expired';
    if (raw.contains('spark session unavailable')) {
      return 'spark session unavailable';
    }
    return 'Daily video service is temporarily unavailable. Please try again later.';
  }

  String _safeLiveTopicErrorMessage(Object error) {
    final raw = error.toString().replaceFirst('Exception: ', '').trim();
    if (raw.contains('authentication required')) {
      return 'authentication required';
    }
    if (raw.contains('host or co-host') ||
        raw.contains('daily_access_denied')) {
      return 'You can only join this Live Topic as a host or co-host.';
    }
    if (raw.contains('not started') || raw.contains('room_not_live')) {
      return 'This Live Topic has not started yet.';
    }
    if (raw.contains('ended') || raw.contains('room_ended')) {
      return 'This Live Topic has ended.';
    }
    if (raw.contains('no longer available') ||
        raw.contains('NoLongerAvailable')) {
      return 'This video room is no longer available. Please refresh or start a new Live Topic.';
    }
    return 'Could not connect to the Live Topic video. Please try again.';
  }

  /// Whether we're on a platform that supports the Daily Flutter SDK
  static bool get supportsNativeCall => !kIsWeb;
}

class DailyAccessException implements Exception {
  final String message;
  final String code;
  final int? httpStatus;

  const DailyAccessException({
    required this.message,
    required this.code,
    this.httpStatus,
  });

  @override
  String toString() => message;
}
