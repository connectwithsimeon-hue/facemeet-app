import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import './supabase_service.dart';

/// Notification event types
enum NotificationEventType { sparkReceived, mutualMatch, newMessage }

/// Notification event payload
class NotificationEvent {
  final NotificationEventType type;
  final Map<String, dynamic> data;

  const NotificationEvent({required this.type, required this.data});
}

/// Centralized Supabase Realtime notification service.
/// Subscribe to [notificationStream] to receive events.
class RealtimeNotificationService {
  static RealtimeNotificationService? _instance;
  static RealtimeNotificationService get instance =>
      _instance ??= RealtimeNotificationService._();

  RealtimeNotificationService._();

  final _controller = StreamController<NotificationEvent>.broadcast();
  Stream<NotificationEvent> get notificationStream => _controller.stream;

  RealtimeChannel? _interactionsChannel;
  RealtimeChannel? _matchesChannel;
  RealtimeChannel? _messagesChannel;

  bool _isInitialized = false;

  /// Start all realtime subscriptions for the current user.
  void initialize() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null || _isInitialized) return;
    _isInitialized = true;

    _subscribeToSparks(uid);
    _subscribeToMatches(uid);
    _subscribeToMessages(uid);

    debugPrint('[RealtimeNotificationService] Initialized for user $uid');
  }

  /// Stop all subscriptions and close the stream.
  void dispose() {
    _interactionsChannel?.unsubscribe();
    _matchesChannel?.unsubscribe();
    _messagesChannel?.unsubscribe();
    _interactionsChannel = null;
    _matchesChannel = null;
    _messagesChannel = null;
    _isInitialized = false;
    debugPrint('[RealtimeNotificationService] Disposed');
  }

  // ── Spark received ──────────────────────────────────────────────────────────
  void _subscribeToSparks(String uid) {
    _interactionsChannel = SupabaseService.instance.client
        .channel('notif_sparks:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'interactions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'to_user_id',
            value: uid,
          ),
          callback: (payload) async {
            final record = payload.newRecord;
            final actionType = record['action_type'] as String?;
            // Only fire for spark actions (not pass/skip)
            if (actionType != 'spark') return;

            final fromUserId = record['from_user_id'] as String?;
            if (fromUserId == null) return;
            final sparkType = SupabaseService.normalizeSparkType(
              record['spark_type'] as String?,
            );

            try {
              if (sparkType != 'professional') {
                _controller.add(
                  NotificationEvent(
                    type: NotificationEventType.sparkReceived,
                    data: {'fromUserId': fromUserId, 'sparkType': sparkType},
                  ),
                );
                debugPrint(
                  '[RealtimeNotificationService] Private spark received',
                );
                return;
              }

              final profile = await SupabaseService.instance.getUserProfile(
                fromUserId,
              );
              final name = profile?['first_name'] as String? ?? 'Someone';
              final thumbnailUrl = profile?['thumbnail_url'] as String?;

              _controller.add(
                NotificationEvent(
                  type: NotificationEventType.sparkReceived,
                  data: {
                    'fromUserId': fromUserId,
                    'sparkType': sparkType,
                    'name': name,
                    'thumbnailUrl': thumbnailUrl,
                  },
                ),
              );
              debugPrint(
                '[RealtimeNotificationService] Spark received from $name',
              );
            } catch (e) {
              debugPrint(
                '[RealtimeNotificationService] Error fetching spark sender: $e',
              );
            }
          },
        )
        .subscribe();
  }

  // ── Mutual match ────────────────────────────────────────────────────────────
  void _subscribeToMatches(String uid) {
    _matchesChannel = SupabaseService.instance.client
        .channel('notif_matches:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'matches',
          callback: (payload) async {
            final record = payload.newRecord;
            final user1 = record['user_1_id'] as String?;
            final user2 = record['user_2_id'] as String?;
            final status = record['status'] as String?;

            // Only fire for mutual matches involving current user
            if ((user1 != uid && user2 != uid)) return;
            if (status != 'matched_pending_session') return;

            final otherId = user1 == uid ? user2 : user1;
            if (otherId == null) return;

            try {
              final profile = await SupabaseService.instance.getUserProfile(
                otherId,
              );
              final name = profile?['first_name'] as String? ?? 'Someone';
              final city = profile?['city'] as String? ?? '';
              final thumbnailUrl = profile?['thumbnail_url'] as String?;
              final matchId = record['id'] as String? ?? '';

              _controller.add(
                NotificationEvent(
                  type: NotificationEventType.mutualMatch,
                  data: {
                    'matchId': matchId,
                    'matchedUserId': otherId,
                    'name': name,
                    'city': city,
                    'thumbnailUrl': thumbnailUrl,
                  },
                ),
              );
              debugPrint(
                '[RealtimeNotificationService] Mutual match with $name',
              );
            } catch (e) {
              debugPrint(
                '[RealtimeNotificationService] Error fetching match profile: $e',
              );
            }
          },
        )
        .subscribe();
  }

  // ── New message ─────────────────────────────────────────────────────────────
  void _subscribeToMessages(String uid) {
    _messagesChannel = SupabaseService.instance.client
        .channel('notif_messages:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          callback: (payload) async {
            final record = payload.newRecord;
            final senderId = record['sender_id'] as String?;

            // Don't notify for own messages
            if (senderId == uid || senderId == null) return;

            final matchId = record['match_id'] as String?;
            final content = record['content'] as String? ?? '';

            try {
              final profile = await SupabaseService.instance.getUserProfile(
                senderId,
              );
              final name = profile?['first_name'] as String? ?? 'Someone';
              final thumbnailUrl = profile?['thumbnail_url'] as String?;

              _controller.add(
                NotificationEvent(
                  type: NotificationEventType.newMessage,
                  data: {
                    'senderId': senderId,
                    'matchId': matchId,
                    'name': name,
                    'thumbnailUrl': thumbnailUrl,
                    'content': content,
                  },
                ),
              );
              debugPrint(
                '[RealtimeNotificationService] New message from $name',
              );
            } catch (e) {
              debugPrint(
                '[RealtimeNotificationService] Error fetching message sender: $e',
              );
            }
          },
        )
        .subscribe();
  }
}
