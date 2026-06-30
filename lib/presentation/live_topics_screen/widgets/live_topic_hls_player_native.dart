import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../theme/app_theme.dart';

class LiveTopicHlsPlayer extends StatefulWidget {
  final String hlsUrl;

  const LiveTopicHlsPlayer({super.key, required this.hlsUrl});

  @override
  State<LiveTopicHlsPlayer> createState() => _LiveTopicHlsPlayerState();
}

class _LiveTopicHlsPlayerState extends State<LiveTopicHlsPlayer>
    with WidgetsBindingObserver {
  static const int _maxWarmupAttempts = 24;
  static const Duration _warmupRetryDelay = Duration(seconds: 3);

  VideoPlayerController? _controller;
  Timer? _retryTimer;
  bool _isInitializing = true;
  bool _isWaitingForStream = false;
  String? _error;
  int _warmupAttempt = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setWakeLock(true);
    _init();
  }

  @override
  void didUpdateWidget(covariant LiveTopicHlsPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hlsUrl != widget.hlsUrl) {
      _resetPlaybackState();
      _setWakeLock(true);
      _init();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setWakeLock(true);
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        controller.play();
      } else if (_error == null) {
        _scheduleWarmupRetry(immediate: true);
      }
    }
  }

  Future<void> _init() async {
    _retryTimer?.cancel();
    final previousController = _controller;
    _controller = null;
    await previousController?.dispose();
    if (!mounted) return;
    setState(() {
      _isInitializing = true;
      _isWaitingForStream = _warmupAttempt > 0;
      _error = null;
    });

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.hlsUrl),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setVolume(1);
      await controller.play();
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _isWaitingForStream = false;
        _error = null;
        _warmupAttempt = 0;
      });
    } catch (error) {
      debugPrint('LIVE TOPIC HLS: playback init failed — $error');
      await _controller?.dispose();
      _controller = null;
      if (!mounted) return;
      _warmupAttempt += 1;
      if (_warmupAttempt < _maxWarmupAttempts) {
        setState(() {
          _isInitializing = false;
          _isWaitingForStream = true;
          _error = null;
        });
        _scheduleWarmupRetry();
        return;
      }
      setState(() {
        _isInitializing = false;
        _isWaitingForStream = false;
        _error = 'Live playback is not available on this device yet.';
      });
    }
  }

  void _scheduleWarmupRetry({bool immediate = false}) {
    _retryTimer?.cancel();
    if (!mounted || _warmupAttempt >= _maxWarmupAttempts) return;
    _retryTimer = Timer(immediate ? Duration.zero : _warmupRetryDelay, () {
      if (mounted) _init();
    });
  }

  void _resetPlaybackState() {
    _retryTimer?.cancel();
    _controller?.dispose();
    _controller = null;
    _warmupAttempt = 0;
    _isInitializing = true;
    _isWaitingForStream = false;
    _error = null;
  }

  Future<void> _setWakeLock(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (error) {
      debugPrint('LIVE TOPIC HLS: wake lock update skipped — $error');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _setWakeLock(false);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_isInitializing) {
      return _LiveTopicHlsPlaceholder(
        icon: Icons.play_circle_rounded,
        title: _isWaitingForStream
            ? 'Connecting live playback...'
            : 'Loading live playback...',
        body: _isWaitingForStream
            ? 'The live stream is warming up. This usually takes a few seconds.'
            : 'Preparing the live conversation stream.',
        showSpinner: true,
      );
    }

    if (_isWaitingForStream) {
      return const _LiveTopicHlsPlaceholder(
        icon: Icons.sensors_rounded,
        title: 'Connecting live playback...',
        body:
            'The live stream is warming up. This usually takes a few seconds.',
        showSpinner: true,
      );
    }

    if (_error != null ||
        controller == null ||
        !controller.value.isInitialized) {
      return _LiveTopicHlsPlaceholder(
        icon: Icons.live_tv_rounded,
        title: 'Playback unavailable',
        body: _error ?? 'Live playback is not available on this device yet.',
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Container(
        height: 360,
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final videoSize = controller.value.size;
                final videoWidth = videoSize.width == 0
                    ? constraints.maxWidth
                    : videoSize.width;
                final videoHeight = videoSize.height == 0
                    ? constraints.maxHeight
                    : videoSize.height;
                return FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: videoWidth,
                    height: videoHeight,
                    child: VideoPlayer(controller),
                  ),
                );
              },
            ),
            Positioned(
              left: 16,
              top: 16,
              child: SafeArea(
                bottom: false,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(154),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withAlpha(36)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, color: AppTheme.primary, size: 8),
                      SizedBox(width: 8),
                      Text(
                        'Live',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withAlpha(154),
                    foregroundColor: Colors.white,
                  ),
                  tooltip: 'Resume live',
                  onPressed: () => controller.play(),
                  icon: const Icon(Icons.sensors_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveTopicHlsPlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final bool showSpinner;

  const _LiveTopicHlsPlaceholder({
    required this.icon,
    required this.title,
    required this.body,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: AppTheme.backgroundVariant,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.primary, size: 30),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withAlpha(184), height: 1.35),
          ),
          if (showSpinner) ...[
            const SizedBox(height: 16),
            const CircularProgressIndicator(color: AppTheme.primary),
          ],
        ],
      ),
    );
  }
}
