import 'package:flutter/material.dart';

// Web stub — daily_flutter is not supported on web
// This file is imported on web via conditional import

/// Stub class for web platform — daily_flutter not available on web
/// On web, SparkVideoCallWidget uses WebView directly instead.
class DailyCallView extends StatefulWidget {
  final String roomUrl;
  final String meetingToken;
  final VoidCallback onCallEnded;
  final VoidCallback? onCallConnected;
  final void Function(String error)? onCallError;
  final VoidCallback? onRemoteParticipantJoined;
  final Future<Map<String, String>?> Function()? onRefreshDailyAccess;

  const DailyCallView({
    super.key,
    required this.roomUrl,
    required this.meetingToken,
    required this.onCallEnded,
    this.onCallConnected,
    this.onCallError,
    this.onRemoteParticipantJoined,
    this.onRefreshDailyAccess,
  });

  @override
  State<DailyCallView> createState() => DailyCallViewState();
}

// Bug 2 fix: Public state class stub for web — matches the public class name in daily_call_io.dart
// so GlobalKey<DailyCallViewState> compiles on both platforms.
class DailyCallViewState extends State<DailyCallView> {
  /// No-op on web — audio/video is handled by WebView
  Future<void> leave() async {}

  Future<void> setMuted(bool muted) async {}

  Future<void> setCameraOff(bool cameraOff) async {}

  Future<void> retryJoin() async {}

  @override
  Widget build(BuildContext context) {
    // On web, SparkVideoCallWidget handles the WebView directly
    return const SizedBox.shrink();
  }
}

/// Stub — no-op on web
Future<void> initDailyCall(String roomUrl) async {}
Future<void> leaveDailyCall() async {}
Future<void> setDailyMuted(bool muted) async {}
Future<void> setDailyCameraOff(bool off) async {}
