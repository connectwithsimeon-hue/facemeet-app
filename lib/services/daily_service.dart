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

  factory DailyAccessResult.fromMap(Map<String, dynamic> data) {
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
      throw Exception('spark session unavailable');
    }

    final roomExpiresAt = DateTime.tryParse(roomExpiresAtRaw);
    final tokenExpiresAt = DateTime.tryParse(tokenExpiresAtRaw);
    if (roomExpiresAt == null || tokenExpiresAt == null) {
      throw Exception('spark session unavailable');
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
      if (data is Map && data['error'] != null) {
        throw Exception(data['error'].toString());
      }
      if (data is! Map) {
        throw Exception('spark session unavailable');
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
        'spark_diag_session_id_short': AndroidDiagnosticsService.shortId(
          parsed.sessionId,
        ),
        'spark_diag_session_key_short': AndroidDiagnosticsService.shortId(
          parsed.sessionKey,
        ),
        'spark_diag_daily_access_success': 'yes',
        'spark_diag_daily_access_error_safe': 'none',
      });
      debugPrint(
        'SPARK DAILY ACCESS: access granted for matchId=${parsed.matchId}, sessionId=${parsed.sessionId}, token_present=${parsed.meetingToken.isNotEmpty}',
      );
      return parsed;
    } catch (e) {
      final message = _safeErrorMessage(e);
      await AndroidDiagnosticsService.instance.setValues({
        'daily_access_succeeded': 'no',
        'meeting_token_received': 'no',
        'spark_diag_daily_access_success': 'no',
        'spark_diag_daily_access_error_safe': message,
      });
      debugPrint('SPARK DAILY ACCESS: request failed — $message');
      throw Exception(message);
    }
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

  /// Whether we're on a platform that supports the Daily Flutter SDK
  static bool get supportsNativeCall => !kIsWeb;
}
