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
      headline1: '',
      headline1Coral: 'Professional Connections',
      headline2: '',
      subtitle:
          'Meet founders, creators, and professionals through real video-first introductions.',
      imageLabel:
          'FaceMeet Professional Connections onboarding slide with a video-first introduction scene',
      overlayWidget: _PosterCropOverlay(
        imageAsset: 'assets/images/professional_connections.png',
        imageLabel: 'Professional video-first introduction scene',
      ),
    ),
    _SlideData(
      headline1: '',
      headline1Coral: 'Friendship',
      headline2: '',
      subtitle:
          'Find people you genuinely click with through short video-first introductions.',
      imageLabel:
          'FaceMeet Friendship onboarding slide with multiple smiling video-first introductions',
      overlayWidget: _PosterCropOverlay(
        imageAsset: 'assets/images/friendship.png',
        imageLabel: 'Friendship video-first introduction scene',
      ),
    ),
    _SlideData(
      headline1: '',
      headline1Coral: 'Social Connections',
      headline2: '',
      subtitle:
          'Meet real people through short video-first conversations built around shared intent.',
      imageLabel:
          'FaceMeet Social Connections onboarding slide with a video-first conversation scene',
      overlayWidget: _PosterCropOverlay(
        imageAsset: 'assets/images/social_connections.png',
        imageLabel: 'Video-first social connection conversation scene',
      ),
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
  final String imageLabel;
  final Widget overlayWidget;

  const _SlideData({
    required this.headline1,
    required this.headline1Coral,
    required this.headline2,
    required this.subtitle,
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

class _PosterCropOverlay extends StatelessWidget {
  final String imageAsset;
  final String imageLabel;

  const _PosterCropOverlay({
    required this.imageAsset,
    required this.imageLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withAlpha(31), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFE8503A).withAlpha(56),
            blurRadius: 40,
            spreadRadius: 5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Image.asset(
          imageAsset,
          fit: BoxFit.cover,
          alignment: Alignment.bottomCenter,
          semanticLabel: imageLabel,
          errorBuilder: (_, __, ___) => Container(
            color: const Color(0xFF1A1A2E),
            child: const Icon(Icons.videocam, color: Colors.white24, size: 60),
          ),
        ),
      ),
    );
  }
}
