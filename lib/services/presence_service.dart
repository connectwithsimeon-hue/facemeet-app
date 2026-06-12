import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import './supabase_service.dart';

/// Manages real-time online presence for the current user.
/// Uses both DB updates (is_online, last_seen_at) and a Supabase Realtime
/// presence channel so status updates even if the app crashes.
class PresenceService {
  static PresenceService? _instance;
  static PresenceService get instance => _instance ??= PresenceService._();
  PresenceService._();

  RealtimeChannel? _presenceChannel;
  Timer? _heartbeatTimer;

  SupabaseClient get _client => SupabaseService.instance.client;
  String? get _uid => SupabaseService.instance.currentUserId;

  // ── Go online ──────────────────────────────────────────────────────────────

  Future<void> setOnline() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _client
          .from('users')
          .update({
            'is_online': true,
            'last_seen_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', uid);
      debugPrint('PRESENCE: set online for $uid');
    } catch (e) {
      debugPrint('PRESENCE: setOnline error — $e');
    }
    _startPresenceChannel(uid);
    _startHeartbeat();
  }

  // ── Go offline ─────────────────────────────────────────────────────────────

  Future<void> setOffline() async {
    final uid = _uid;
    _stopHeartbeat();
    _stopPresenceChannel();
    if (uid == null) return;
    try {
      await _client
          .from('users')
          .update({
            'is_online': false,
            'last_seen_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', uid);
      debugPrint('PRESENCE: set offline for $uid');
    } catch (e) {
      debugPrint('PRESENCE: setOffline error — $e');
    }
  }

  // ── Heartbeat: update last_seen_at every 60s while online ─────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      final uid = _uid;
      if (uid == null) return;
      try {
        await _client
            .from('users')
            .update({'last_seen_at': DateTime.now().toUtc().toIso8601String()})
            .eq('id', uid);
      } catch (_) {}
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ── Realtime presence channel ──────────────────────────────────────────────

  void _startPresenceChannel(String uid) {
    _stopPresenceChannel();
    _presenceChannel = _client
        .channel('presence_$uid')
        .onPresenceSync((_) {})
        .subscribe((status, [_]) async {
          if (status == RealtimeSubscribeStatus.subscribed) {
            await _presenceChannel?.track({
              'user_id': uid,
              'online_at': DateTime.now().toIso8601String(),
            });
          }
        });
  }

  void _stopPresenceChannel() {
    _presenceChannel?.unsubscribe();
    _presenceChannel = null;
  }

  // ── Subscribe to another user's online status ──────────────────────────────

  /// Returns a stream of [Map] with keys: is_online (bool), last_seen_at (String?)
  RealtimeChannel subscribeToUserPresence({
    required String userId,
    required void Function(bool isOnline, String? lastSeenAt) onUpdate,
  }) {
    final channel = _client
        .channel('user_presence_watch_$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'users',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: userId,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            final isOnline = newRecord['is_online'] as bool? ?? false;
            final lastSeenAt = newRecord['last_seen_at'] as String?;
            onUpdate(isOnline, lastSeenAt);
          },
        )
        .subscribe();
    return channel;
  }

  // ── Format last_seen_at for display ───────────────────────────────────────

  static String formatLastSeen(String? lastSeenAt) {
    if (lastSeenAt == null) return 'Last seen recently';
    final dt = DateTime.tryParse(lastSeenAt);
    if (dt == null) return 'Last seen recently';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inMinutes < 5) return 'Last seen recently';
    if (diff.inMinutes < 60) return 'Last seen today';
    if (diff.inHours < 24) return 'Last seen today';
    if (diff.inDays == 1) return 'Last seen yesterday';
    return 'Last seen ${diff.inDays} days ago';
  }

  void dispose() {
    _stopHeartbeat();
    _stopPresenceChannel();
  }
}
