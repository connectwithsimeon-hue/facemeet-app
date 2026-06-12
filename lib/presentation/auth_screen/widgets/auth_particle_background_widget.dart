import 'dart:math' as math;
import 'package:flutter/material.dart';

class AuthParticleBackgroundWidget extends StatefulWidget {
  const AuthParticleBackgroundWidget({super.key});

  @override
  State<AuthParticleBackgroundWidget> createState() =>
      _AuthParticleBackgroundWidgetState();
}

class _AuthParticleBackgroundWidgetState
    extends State<AuthParticleBackgroundWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_Particle> _particles;
  final math.Random _random = math.Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _particles = List.generate(40, (i) => _Particle(_random));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return CustomPaint(
          painter: _ParticlePainter(
            particles: _particles,
            progress: _controller.value,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _Particle {
  late double x;
  late double y;
  late double size;
  late double speed;
  late double opacity;
  late double drift;

  _Particle(math.Random rng) {
    x = rng.nextDouble();
    y = rng.nextDouble();
    size = rng.nextDouble() * 3 + 1;
    speed = rng.nextDouble() * 0.03 + 0.01;
    opacity = rng.nextDouble() * 0.4 + 0.1;
    drift = (rng.nextDouble() - 0.5) * 0.01;
  }
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double progress;

  _ParticlePainter({required this.particles, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final x = ((p.x + p.drift * progress * 20) % 1.0) * size.width;
      final y = (1.0 - ((p.y + p.speed * progress * 10) % 1.0)) * size.height;

      final paint = Paint()
        ..color = const Color(0xFFFF4458).withOpacity(p.opacity)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(Offset(x, y), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => old.progress != progress;
}
