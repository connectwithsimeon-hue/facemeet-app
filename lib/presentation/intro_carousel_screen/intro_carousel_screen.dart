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
      fullScreenAsset: 'assets/images/professional_connections.png',
      imageLabel:
          'FaceMeet Professional Connections onboarding slide with a video-first introduction scene',
    ),
    _SlideData(
      fullScreenAsset: 'assets/images/friendship.png',
      imageLabel:
          'FaceMeet Friendship onboarding slide with multiple smiling video-first introductions',
    ),
    _SlideData(
      fullScreenAsset: 'assets/images/social_connections.png',
      imageLabel:
          'FaceMeet Social Connections onboarding slide with a video-first conversation scene',
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
            child: Opacity(
              opacity: _slides[_currentPage].isPoster ? 0 : 1,
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
            child: Opacity(
              opacity: _slides[_currentPage].isPoster ? 0 : 1,
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
  final String? fullScreenAsset;
  final String imageLabel;

  const _SlideData({required this.fullScreenAsset, required this.imageLabel});

  bool get isPoster => fullScreenAsset?.isNotEmpty == true;
}

// ─── Single slide page ────────────────────────────────────────────────────────

class _SlidePage extends StatelessWidget {
  final _SlideData slide;

  const _SlidePage({super.key, required this.slide});

  static const _navyBg = Color(0xFF0D0D1A);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _navyBg,
      child: Image.asset(
        slide.fullScreenAsset!,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        width: double.infinity,
        height: double.infinity,
        semanticLabel: slide.imageLabel,
      ),
    );
  }
}
