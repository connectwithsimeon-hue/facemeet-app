import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../theme/app_theme.dart';

class LiveTopicHlsPlayer extends StatefulWidget {
  final String hlsUrl;

  const LiveTopicHlsPlayer({super.key, required this.hlsUrl});

  @override
  State<LiveTopicHlsPlayer> createState() => _LiveTopicHlsPlayerState();
}

class _LiveTopicHlsPlayerState extends State<LiveTopicHlsPlayer> {
  VideoPlayerController? _controller;
  bool _isInitializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didUpdateWidget(covariant LiveTopicHlsPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hlsUrl != widget.hlsUrl) {
      _controller?.dispose();
      _controller = null;
      _isInitializing = true;
      _error = null;
      _init();
    }
  }

  Future<void> _init() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.hlsUrl),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setVolume(1);
      if (!mounted) return;
      setState(() => _isInitializing = false);
    } catch (error) {
      debugPrint('LIVE TOPIC HLS: playback init failed — $error');
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _error = 'Live playback is not available on this device yet.';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_isInitializing) {
      return const _LiveTopicHlsPlaceholder(
        icon: Icons.play_circle_rounded,
        title: 'Loading live playback...',
        body: 'Preparing the live conversation stream.',
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
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio == 0
                    ? 16 / 9
                    : controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: _LiveTopicHlsActionButton(
                  label: controller.value.isPlaying ? 'Pause' : 'Play Live',
                  icon: controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onPressed: () async {
                    if (controller.value.isPlaying) {
                      await controller.pause();
                    } else {
                      await controller.play();
                    }
                    if (mounted) setState(() {});
                  },
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

class _LiveTopicHlsActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const _LiveTopicHlsActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    );
  }
}
