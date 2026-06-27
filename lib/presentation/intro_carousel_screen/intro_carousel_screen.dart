import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: const Color(0xFFFFF4ED),
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: _navyBg,
        body: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: _slides.length,
              onPageChanged: (i) => setState(() => _currentPage = i),
              itemBuilder: (context, index) {
                return GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _handlePwaTap('slide tap', _next),
                  child: _SlidePage(slide: _slides[index]),
                );
              },
            ),

            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                minimum: const EdgeInsets.only(top: 12, right: 18),
                child: _IntroTextButton(
                  label: 'Skip',
                  onPressed: () => _handlePwaTap('skip tap', _finish),
                ),
              ),
            ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: _IntroBottomControls(
                  currentPage: _currentPage,
                  pageCount: _slides.length,
                  buttonLabel: isLast ? 'Get Started' : 'Next',
                  onPressed: () => _handlePwaTap('next tap', _next),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebIntro(BuildContext context) {
    final isLast = _currentPage == _slides.length - 1;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: const Color(0xFFFFF4ED),
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: _navyBg,
        body: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _handlePwaTap('web slide tap', () {
                if (isLast) {
                  _finish();
                } else {
                  setState(() => _currentPage += 1);
                }
              }),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: _SlidePage(
                  key: ValueKey<int>(_currentPage),
                  slide: _slides[_currentPage],
                ),
              ),
            ),

            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                minimum: const EdgeInsets.only(top: 12, right: 18),
                child: _IntroTextButton(
                  label: 'Skip',
                  onPressed: () => _handlePwaTap('web skip', _finish),
                ),
              ),
            ),

            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: _IntroBottomControls(
                  currentPage: _currentPage,
                  pageCount: _slides.length,
                  buttonLabel: isLast ? 'Get Started' : 'Next',
                  onPressed: () => _handlePwaTap('web next', () {
                    if (isLast) {
                      _finish();
                    } else {
                      setState(() => _currentPage += 1);
                    }
                  }),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IntroTextButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _IntroTextButton({required this.label, required this.onPressed});

  static const _darkText = Color(0xFF181823);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(230),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.black.withAlpha(18)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(22),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Text(
            label,
            style: GoogleFonts.dmSans(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: _darkText,
            ),
          ),
        ),
      ),
    );
  }
}

class _IntroBottomControls extends StatelessWidget {
  final int currentPage;
  final int pageCount;
  final String buttonLabel;
  final VoidCallback onPressed;

  const _IntroBottomControls({
    required this.currentPage,
    required this.pageCount,
    required this.buttonLabel,
    required this.onPressed,
  });

  static const _coral = Color(0xFFE8503A);
  static const _darkText = Color(0xFF181823);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withAlpha(220),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.black.withAlpha(15)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(18),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(pageCount, (i) {
              final isActive = i == currentPage;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: isActive ? 24 : 8,
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: isActive ? _coral : _darkText.withAlpha(64),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 14),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(999),
            child: Ink(
              height: 58,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFE8503A), Color(0xFFFF6542)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: _coral.withAlpha(92),
                    blurRadius: 22,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  buttonLabel,
                  style: GoogleFonts.dmSans(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
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
