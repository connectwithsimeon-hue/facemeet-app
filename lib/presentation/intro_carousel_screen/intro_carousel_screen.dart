import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../routes/app_routes.dart';

const String _kIntroSeenKey = 'intro_carousel_seen';

class IntroCarouselScreen extends StatefulWidget {
  const IntroCarouselScreen({super.key});

  @override
  State<IntroCarouselScreen> createState() => _IntroCarouselScreenState();
}

class _IntroCarouselScreenState extends State<IntroCarouselScreen> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _tapGuardActive = false;

  static const _coral = Color(0xFFE8503A);
  static const _navyBg = Color(0xFF0D0D1A);

  final List<_SlideData> _slides = const [
    _SlideData(
      headline1: 'Meet ',
      headline1Coral: 'Real People,',
      headline2: 'Not Photos',
      subtitle:
          'Every match starts with a live\nvideo date — no hiding behind filters.',
      imageUrl:
          'https://images.pexels.com/photos/4226140/pexels-photo-4226140.jpeg?auto=compress&cs=tinysrgb&w=800',
      imageLabel: 'Woman smiling on a video call with a man in a warm-lit room',
      overlayWidget: _Slide1Overlay(),
    ),
    _SlideData(
      headline1: '100%\n',
      headline1Coral: 'Catfish-Free',
      headline2: '',
      subtitle:
          'You see them live before you ever swipe.\nWhat you see is what you get.',
      imageUrl:
          'https://images.pexels.com/photos/4226140/pexels-photo-4226140.jpeg?auto=compress&cs=tinysrgb&w=800',
      imageLabel:
          'Woman smiling on a video call showing verified live badge overlay',
      overlayWidget: _Slide2Overlay(),
    ),
    _SlideData(
      headline1Coral: '3 Minutes to\n',
      headline1: '',
      headline2: 'Feel the Chemistry',
      subtitle:
          'Quick video sparks mean\nno wasted time — you\'ll know instantly.',
      imageUrl:
          'https://images.pexels.com/photos/3807571/pexels-photo-3807571.jpeg?auto=compress&cs=tinysrgb&w=800',
      imageLabel:
          'Black woman smiling on a live video call with a timer showing 3 minutes',
      overlayWidget: _Slide3Overlay(),
    ),
    _SlideData(
      headline1: 'Ready to Meet\n',
      headline1Coral: 'Your Match?',
      headline2: '',
      subtitle: 'Join thousands already\nsparking real connections.',
      imageUrl: '',
      imageLabel: '',
      overlayWidget: _Slide4Overlay(),
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    debugPrint('INTRO CAROUSEL: Skip/Get Started tapped — finishing intro');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kIntroSeenKey, true);
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppRoutes.authScreen, (route) => false);
  }

  void _next() {
    debugPrint(
      'INTRO CAROUSEL: Next tapped — currentPage=$_currentPage, lastPage=${_slides.length - 1}',
    );
    if (_currentPage < _slides.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finish();
    }
  }

  void _handlePwaTap(String label, VoidCallback action) {
    if (_tapGuardActive) {
      debugPrint('INTRO CAROUSEL: duplicate tap ignored — $label');
      return;
    }
    _tapGuardActive = true;
    debugPrint('INTRO CAROUSEL: pointer/tap received — $label');
    action();
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      _tapGuardActive = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return _buildWebIntro(context);
    }

    final isLast = _currentPage == _slides.length - 1;

    return Scaffold(
      backgroundColor: _navyBg,
      body: Stack(
        children: [
          // Page view
          PageView.builder(
            controller: _pageController,
            itemCount: _slides.length,
            onPageChanged: (i) => setState(() => _currentPage = i),
            itemBuilder: (context, index) {
              return _SlidePage(slide: _slides[index]);
            },
          ),

          // Skip button top-right
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 20,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerUp: (_) => _handlePwaTap('skip pointer', () {
                _finish();
              }),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _handlePwaTap('skip tap', () {
                    _finish();
                  }),
                  borderRadius: BorderRadius.circular(999),
                  child: Ink(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(31),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withAlpha(51),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'Skip',
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withAlpha(217),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Bottom controls: dots + button
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 32,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Dot indicators
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_slides.length, (i) {
                    final isActive = i == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: isActive ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: isActive ? _coral : Colors.white.withAlpha(77),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 24),

                // Next / Get Started button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerUp: (_) => _handlePwaTap('next pointer', _next),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _handlePwaTap('next tap', _next),
                        borderRadius: BorderRadius.circular(32),
                        child: Ink(
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFE8503A), Color(0xFFD43B25)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(32),
                            boxShadow: [
                              BoxShadow(
                                color: _coral.withAlpha(115),
                                blurRadius: 20,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Text(
                              isLast ? 'Get Started' : 'Next',
                              style: GoogleFonts.dmSans(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebIntro(BuildContext context) {
    final isLast = _currentPage == _slides.length - 1;

    return Scaffold(
      backgroundColor: _navyBg,
      body: Stack(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: _SlidePage(
              key: ValueKey<int>(_currentPage),
              slide: _slides[_currentPage],
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 20,
            child: _WebIntroButton(
              label: 'Skip',
              onPressed: () => _handlePwaTap('web skip', () {
                _finish();
              }),
              compact: true,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: MediaQuery.of(context).padding.bottom + 32,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_slides.length, (i) {
                    final isActive = i == _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: isActive ? 20 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        color: isActive ? _coral : Colors.white.withAlpha(77),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _WebIntroButton(
                    label: isLast ? 'Get Started' : 'Next',
                    onPressed: () => _handlePwaTap('web next', () {
                      if (isLast) {
                        _finish();
                      } else {
                        setState(() => _currentPage += 1);
                      }
                    }),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WebIntroButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool compact;

  const _WebIntroButton({
    required this.label,
    required this.onPressed,
    this.compact = false,
  });

  static const _coral = Color(0xFFE8503A);

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: (_) => onPressed(),
      child: Semantics(
        button: true,
        label: label,
        child: Container(
          height: compact ? null : 56,
          width: compact ? null : double.infinity,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 18 : 20,
            vertical: compact ? 12 : 0,
          ),
          decoration: BoxDecoration(
            gradient: compact
                ? null
                : const LinearGradient(
                    colors: [Color(0xFFE8503A), Color(0xFFD43B25)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
            color: compact ? Colors.white.withAlpha(31) : null,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: compact ? Colors.white.withAlpha(51) : _coral,
              width: 1,
            ),
            boxShadow: compact
                ? null
                : [
                    BoxShadow(
                      color: _coral.withAlpha(115),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.dmSans(
              fontSize: compact ? 14 : 17,
              fontWeight: compact ? FontWeight.w500 : FontWeight.w700,
              color: Colors.white,
              letterSpacing: compact ? 0 : 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Slide data model ────────────────────────────────────────────────────────

class _SlideData {
  final String headline1;
  final String headline1Coral;
  final String headline2;
  final String subtitle;
  final String imageUrl;
  final String imageLabel;
  final Widget overlayWidget;

  const _SlideData({
    required this.headline1,
    required this.headline1Coral,
    required this.headline2,
    required this.subtitle,
    required this.imageUrl,
    required this.imageLabel,
    required this.overlayWidget,
  });
}

// ─── Single slide page ────────────────────────────────────────────────────────

class _SlidePage extends StatelessWidget {
  final _SlideData slide;

  const _SlidePage({super.key, required this.slide});

  static const _coral = Color(0xFFE8503A);
  static const _navyBg = Color(0xFF0D0D1A);

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.0, 0.3),
          radius: 1.2,
          colors: [Color(0xFF2A1018), _navyBg],
        ),
      ),
      child: Column(
        children: [
          SizedBox(height: topPad + 60),

          // FaceMeet logo row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/facemeet_splash_logo-1778015584859.png',
                width: 36,
                height: 36,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _coral,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.favorite,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: 'Face',
                      style: GoogleFonts.dmSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    TextSpan(
                      text: 'Meet',
                      style: GoogleFonts.dmSans(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: _coral,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Headline
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: _HeadlineText(slide: slide),
          ),

          const SizedBox(height: 12),

          // Subtitle
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              slide.subtitle,
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                fontSize: 15,
                color: Colors.white.withAlpha(166),
                height: 1.55,
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Image / illustration area
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: slide.overlayWidget,
            ),
          ),

          // Space for bottom controls (dots + button)
          const SizedBox(height: 130),
        ],
      ),
    );
  }
}

class _HeadlineText extends StatelessWidget {
  final _SlideData slide;

  const _HeadlineText({required this.slide});

  static const _coral = Color(0xFFE8503A);

  @override
  Widget build(BuildContext context) {
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        children: [
          if (slide.headline1Coral.isNotEmpty && slide.headline1.isEmpty) ...[
            TextSpan(
              text: slide.headline1Coral,
              style: GoogleFonts.dmSans(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: _coral,
                height: 1.15,
              ),
            ),
            TextSpan(
              text: slide.headline2,
              style: GoogleFonts.dmSans(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
              ),
            ),
          ] else ...[
            TextSpan(
              text: slide.headline1,
              style: GoogleFonts.dmSans(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                height: 1.15,
              ),
            ),
            TextSpan(
              text: slide.headline1Coral,
              style: GoogleFonts.dmSans(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: _coral,
                height: 1.15,
              ),
            ),
            if (slide.headline2.isNotEmpty)
              TextSpan(
                text: '\n${slide.headline2}',
                style: GoogleFonts.dmSans(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  height: 1.15,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// ─── Slide overlays ───────────────────────────────────────────────────────────

/// Slide 1 — video call mockup with timer badge
class _Slide1Overlay extends StatelessWidget {
  const _Slide1Overlay();

  @override
  Widget build(BuildContext context) {
    return _VideoCallMockup(
      imageUrl: '',
      imageAsset: 'assets/images/slide1_image-1778035225680.png',
      imageLabel: 'Woman smiling on a video call with a man in a warm-lit room',
      badgeWidget: const SizedBox.shrink(),
      bottomWidget: const SizedBox.shrink(),
    );
  }
}

/// Slide 2 — video call mockup with verified live badge
class _Slide2Overlay extends StatelessWidget {
  const _Slide2Overlay();

  @override
  Widget build(BuildContext context) {
    return _VideoCallMockup(
      imageUrl: '',
      imageAsset: 'assets/images/slide2_image-1778035226223.png',
      imageLabel:
          'Woman smiling on a video call showing verified live badge overlay',
      badgeWidget: const SizedBox.shrink(),
      bottomWidget: _VerifiedLiveBadge(),
    );
  }
}

/// Slide 3 — video call mockup with 3-min timer ring
class _Slide3Overlay extends StatelessWidget {
  const _Slide3Overlay();

  @override
  Widget build(BuildContext context) {
    return _VideoCallMockup(
      imageUrl: '',
      imageAsset: 'assets/images/slide3_image-1778035226227.png',
      imageLabel:
          'Black woman smiling on a live video call with a timer showing 3 minutes',
      badgeWidget: _LiveBadge(),
      bottomWidget: _TimerRingWidget(),
    );
  }
}

/// Slide 4 — centered logo + CTA (no image)
class _Slide4Overlay extends StatelessWidget {
  const _Slide4Overlay();

  static const _coral = Color(0xFFE8503A);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // App icon with glow
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              boxShadow: [
                BoxShadow(
                  color: _coral.withAlpha(128),
                  blurRadius: 60,
                  spreadRadius: 10,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(36),
              child: Image.asset(
                'assets/images/facemeet_splash_logo-1778015584859.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  decoration: BoxDecoration(
                    gradient: const RadialGradient(
                      colors: [Color(0xFF3A1010), Color(0xFF1A0808)],
                    ),
                    borderRadius: BorderRadius.circular(36),
                    border: Border.all(color: _coral.withAlpha(102), width: 2),
                  ),
                  child: const Icon(Icons.favorite, color: _coral, size: 80),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Floating hearts decoration
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _FloatingHeart(size: 28, opacity: 0.25, offset: -30),
              const SizedBox(width: 80),
              _FloatingHeart(size: 40, opacity: 0.2, offset: 0),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Reusable video call mockup container ─────────────────────────────────────

class _VideoCallMockup extends StatelessWidget {
  final String imageUrl;
  final String? imageAsset;
  final String imageLabel;
  final Widget badgeWidget;
  final Widget bottomWidget;

  const _VideoCallMockup({
    required this.imageUrl,
    this.imageAsset,
    required this.imageLabel,
    required this.badgeWidget,
    required this.bottomWidget,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withAlpha(31), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFE8503A).withAlpha(64),
            blurRadius: 40,
            spreadRadius: 5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Main video feed image
            imageAsset != null && imageAsset!.isNotEmpty
                ? Image.asset(
                    imageAsset!,
                    fit: BoxFit.cover,
                    semanticLabel: imageLabel,
                    errorBuilder: (_, __, ___) => Container(
                      color: const Color(0xFF1A1A2E),
                      child: const Icon(
                        Icons.videocam,
                        color: Colors.white24,
                        size: 60,
                      ),
                    ),
                  )
                : Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    semanticLabel: imageLabel,
                    errorBuilder: (_, __, ___) => Container(
                      color: const Color(0xFF1A1A2E),
                      child: const Icon(
                        Icons.videocam,
                        color: Colors.white24,
                        size: 60,
                      ),
                    ),
                  ),

            // Warm gradient overlay at bottom
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 200,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withAlpha(179)],
                  ),
                ),
              ),
            ),

            // Top-left badge (timer or LIVE)
            Positioned(top: 14, left: 14, child: badgeWidget),

            // Bottom widget (controls or badge)
            Positioned(bottom: 0, left: 0, right: 0, child: bottomWidget),
          ],
        ),
      ),
    );
  }
}

// ─── Small UI components ──────────────────────────────────────────────────────

class _TimerBadge extends StatelessWidget {
  final String label;

  const _TimerBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFFE8503A),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.dmSans(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFFE8503A),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            'LIVE',
            style: GoogleFonts.dmSans(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _CallControls extends StatelessWidget {
  const _CallControls();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ControlButton(icon: Icons.mic, isMain: false),
          const SizedBox(width: 20),
          _ControlButton(icon: Icons.call_end, isMain: true),
          const SizedBox(width: 20),
          _ControlButton(icon: Icons.videocam, isMain: false),
        ],
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final bool isMain;

  const _ControlButton({required this.icon, required this.isMain});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: isMain ? 56 : 48,
      height: isMain ? 56 : 48,
      decoration: BoxDecoration(
        color: isMain ? const Color(0xFFE8503A) : Colors.black.withAlpha(140),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: isMain ? 26 : 22),
    );
  }
}

class _VerifiedLiveBadge extends StatelessWidget {
  const _VerifiedLiveBadge();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, right: 16),
      child: Align(
        alignment: Alignment.bottomRight,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Coral checkmark badge
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFE8503A),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8503A).withAlpha(128),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.check_rounded,
                color: Colors.white,
                size: 30,
              ),
            ),
            const SizedBox(height: 8),
            // Verified Live label
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(179),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Verified Live',
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    'Real. Live. Verified.',
                    style: GoogleFonts.dmSans(
                      fontSize: 11,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimerRingWidget extends StatelessWidget {
  const _TimerRingWidget();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black.withAlpha(191),
            border: Border.all(color: const Color(0xFFE8503A), width: 3),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE8503A).withAlpha(128),
                blurRadius: 20,
                spreadRadius: 3,
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '03:00',
                style: GoogleFonts.dmSans(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFFE8503A),
                ),
              ),
              Text(
                'min left',
                style: GoogleFonts.dmSans(fontSize: 11, color: Colors.white60),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FloatingHeart extends StatelessWidget {
  final double size;
  final double opacity;
  final double offset;

  const _FloatingHeart({
    required this.size,
    required this.opacity,
    required this.offset,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(offset, 0),
      child: Icon(
        Icons.favorite,
        color: const Color(0xFFE8503A).withOpacity(opacity),
        size: size,
      ),
    );
  }
}
