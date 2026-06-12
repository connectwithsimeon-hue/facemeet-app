import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';

/// A reusable circular avatar widget that displays a user's thumbnail image.
/// Falls back to a coral CircleAvatar with the user's first initial if no
/// thumbnail is available or if the image fails to load.
class ProfileAvatar extends StatelessWidget {
  final String? thumbnailUrl;
  final String? firstName;
  final double radius;
  final Color? borderColor;

  const ProfileAvatar({
    super.key,
    this.thumbnailUrl,
    this.firstName,
    this.radius = 24,
    this.borderColor,
  });

  bool get _hasThumbnail =>
      thumbnailUrl != null && thumbnailUrl!.trim().isNotEmpty;

  String get _initial {
    final name = firstName ?? '';
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Widget _buildFallback() {
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFFFF4458),
      child: Text(
        _initial,
        style: GoogleFonts.dmSans(
          fontSize: (radius * 0.7).clamp(10, 28),
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final diameter = radius * 2;

    Widget avatar;

    if (_hasThumbnail) {
      avatar = CachedNetworkImage(
        imageUrl: thumbnailUrl!,
        imageBuilder: (context, imageProvider) => Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            image: DecorationImage(image: imageProvider, fit: BoxFit.cover),
          ),
        ),
        placeholder: (context, url) => Container(
          width: diameter,
          height: diameter,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFF1A1A2E),
          ),
          child: const _ShimmerCircle(),
        ),
        errorWidget: (context, url, error) => _buildFallback(),
        width: diameter,
        height: diameter,
        fit: BoxFit.cover,
      );
    } else {
      avatar = _buildFallback();
    }

    if (borderColor != null) {
      return Container(
        width: diameter + 4,
        height: diameter + 4,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor!, width: 2),
        ),
        child: ClipOval(child: avatar),
      );
    }

    return ClipOval(child: avatar);
  }
}

class _ShimmerCircle extends StatefulWidget {
  const _ShimmerCircle();

  @override
  State<_ShimmerCircle> createState() => _ShimmerCircleState();
}

class _ShimmerCircleState extends State<_ShimmerCircle>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.3,
      end: 0.7,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Color.fromRGBO(255, 255, 255, _anim.value * 0.1),
        ),
      ),
    );
  }
}
