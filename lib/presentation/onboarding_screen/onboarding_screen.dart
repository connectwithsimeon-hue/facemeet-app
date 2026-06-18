import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../routes/app_routes.dart';
import '../../theme/app_theme.dart';
import '../../services/install_gate_service.dart';
import '../../services/supabase_service.dart';
import '../../services/referral_service.dart';
import './widgets/onboarding_step1_widget.dart';
import './widgets/onboarding_step2_widget.dart';
import './widgets/onboarding_step3_widget.dart';
import './widgets/onboarding_step4_widget.dart';
import './widgets/onboarding_step_indicator_widget.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  int _currentStep = 0;
  bool _isSaving = false;

  // TODO: Replace with Supabase user profile state management
  // Step 1 data
  String _firstName = '';
  int _age = 24;
  String _gender = '';
  String _interestedIn = '';

  // Step 2 data
  final List<String> _selectedInterests = [];

  // Step 3 data
  String _city = '';
  String _stateRegion = '';
  String _country = 'US';
  String _countryCode = 'US';
  String? _regionId;
  String? _cityPlaceId;
  String? _areaPlaceId;
  String? _canonicalPlaceId;
  String _locationDisplayName = '';
  double? _latitude;
  double? _longitude;
  String _metroArea = '';
  String _locationSource = 'picker';
  bool _locationPermissionGranted = false;

  // Step 4 data
  String? _profileVideoUrl;

  late AnimationController _slideController;
  late Animation<Offset> _slideAnim;
  late Animation<double> _fadeAnim;

  String _normalizeGender(String value) {
    switch (value.trim().toLowerCase()) {
      case 'man':
        return 'man';
      case 'woman':
        return 'woman';
      case 'non-binary':
      case 'non_binary':
        return 'non_binary';
      case 'other':
        return 'other';
      default:
        return value;
    }
  }

  String _normalizeInterestedIn(String value) {
    switch (value.trim().toLowerCase()) {
      case 'men':
        return 'men';
      case 'women':
        return 'women';
      case 'everyone':
        return 'everyone';
      default:
        return value;
    }
  }

  @override
  void initState() {
    super.initState();
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = Tween<Offset>(begin: const Offset(0.06, 0), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic),
        );
    _fadeAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _slideController,
        curve: const Interval(0, 0.6, curve: Curves.easeOut),
      ),
    );
    _slideController.forward();
  }

  @override
  void dispose() {
    _slideController.dispose();
    super.dispose();
  }

  void _nextStep() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    bool saved = false;

    try {
      switch (_currentStep) {
        case 0:
          final normalizedGender = _normalizeGender(_gender);
          final normalizedInterestedIn = _normalizeInterestedIn(_interestedIn);
          await SupabaseService.instance.saveOnboardingStep({
            'first_name': _firstName,
            'age': _age,
            'gender': normalizedGender,
            'interested_in': normalizedInterestedIn,
          });
          assert(() {
            debugPrint(
              '[Onboarding] Step 1 saved — first_name: $_firstName, age: $_age, gender: $normalizedGender, interested_in: $normalizedInterestedIn',
            );
            return true;
          }());
          saved = true;
          break;

        case 1:
          await SupabaseService.instance.saveOnboardingStep({
            'interests': _selectedInterests,
          });
          assert(() {
            debugPrint(
              '[Onboarding] Step 2 saved — interests: $_selectedInterests',
            );
            return true;
          }());
          saved = true;
          break;

        case 2:
          final locationData = <String, dynamic>{
            'city': _city.trim(),
            'state_region': _stateRegion.trim(),
            'country': _country.trim().isNotEmpty ? _country.trim() : 'US',
            'country_code': _countryCode.trim().isNotEmpty
                ? _countryCode.trim().toUpperCase()
                : null,
            'region_id': _regionId,
            'city_place_id': _cityPlaceId,
            'area_place_id': _areaPlaceId,
            'canonical_place_id': _canonicalPlaceId,
            'location_display_name': _locationDisplayName.trim().isNotEmpty
                ? _locationDisplayName.trim()
                : null,
            'metro_area': _metroArea.trim().isNotEmpty
                ? _metroArea.trim()
                : null,
            'location_source': _locationSource,
            'location_permission_granted': _locationPermissionGranted,
            'location_updated_at': DateTime.now().toIso8601String(),
          };

          if (_locationPermissionGranted &&
              _latitude != null &&
              _longitude != null) {
            locationData['latitude'] = _latitude;
            locationData['longitude'] = _longitude;
          }

          await SupabaseService.instance.saveOnboardingStep(locationData);
          assert(() {
            debugPrint(
              '[Onboarding] Step 3 saved — city: $_city, state_region: $_stateRegion, country: $_country, metro_area: $_metroArea, location_source: $_locationSource, canonical_place_selected=${_canonicalPlaceId != null}, location_permission_granted: $_locationPermissionGranted',
            );
            return true;
          }());
          saved = true;
          break;

        case 3:
          await SupabaseService.instance.saveOnboardingStep({
            'profile_video_url': _profileVideoUrl,
            'verification_status': 'pending',
          }, markComplete: true);
          assert(() {
            debugPrint(
              '[Onboarding] Step 4 saved — profile_video_url: $_profileVideoUrl, verification_status: pending, onboarding_complete: true',
            );
            return true;
          }());
          saved = true;
          break;
      }
    } catch (e) {
      debugPrint('[Onboarding] Save failed on step ${_currentStep + 1}: $e');
      if (mounted) {
        final errorMsg = e.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: const Color(0xFFFF4458),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    }

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (!saved) return;

    if (_currentStep < 3) {
      setState(() => _currentStep++);
      _slideController.reset();
      _slideController.forward();
    } else {
      _completeOnboarding();
    }
  }

  void _prevStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
      _slideController.reset();
      _slideController.forward();
    }
  }

  void _completeOnboarding() async {
    // Apply any pending referral code stored from deep link
    try {
      final prefs = await SharedPreferences.getInstance();
      var pendingCode = prefs.getString('pending_referral_code');
      debugPrint(
        'REFERRAL: pending code found yes/no=${pendingCode != null && pendingCode.isNotEmpty}',
      );
      if ((pendingCode == null || pendingCode.isEmpty) && kIsWeb) {
        final recoveredCode =
            (await InstallGateService.instance.getPendingReferralCode()).trim();
        if (recoveredCode.isNotEmpty) {
          await prefs.setString('pending_referral_code', recoveredCode);
          pendingCode = recoveredCode;
          debugPrint('REFERRAL: recovered pending code from web storage yes');
        }
      }
      if (pendingCode != null && pendingCode.isNotEmpty) {
        debugPrint('REFERRAL: apply called yes');
        final applied = await ReferralService.instance.applyReferralOnJoin(
          pendingCode,
        );
        if (applied) {
          await prefs.remove('pending_referral_code');
          debugPrint('REFERRAL: Applied pending referral code yes');
        } else {
          debugPrint('REFERRAL: Pending referral kept for retry');
        }
      } else {
        debugPrint('REFERRAL: apply called no');
      }
    } catch (e) {
      debugPrint(
        'REFERRAL: Error applying referral on onboarding complete: $e',
      );
    }

    // Ensure referral code is generated for the new user
    try {
      await ReferralService.instance.getOrCreateReferralCode();
    } catch (e) {
      debugPrint('REFERRAL: Error generating referral code: $e');
    }

    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(
      context,
      AppRoutes.routeAfterAuth(onboardingComplete: true),
      (route) => false,
    );
  }

  bool _canProceed() {
    switch (_currentStep) {
      case 0:
        return _firstName.isNotEmpty &&
            _gender.isNotEmpty &&
            _interestedIn.isNotEmpty &&
            _age >= 18;
      case 1:
        return _selectedInterests.length >= 3;
      case 2:
        return _city.trim().isNotEmpty &&
            _stateRegion.trim().isNotEmpty &&
            _country.trim().isNotEmpty &&
            _canonicalPlaceId != null;
      case 3:
        return _profileVideoUrl != null;
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTablet = size.width >= 600;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Stack(
        children: [
          // Background gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x22FF4458), Color(0xFF0D0D0F)],
                stops: [0.0, 0.4],
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isTablet ? 560 : double.infinity,
                ),
                child: Column(
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                      child: Row(
                        children: [
                          if (_currentStep > 0)
                            GestureDetector(
                              onTap: _prevStep,
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: AppTheme.surfaceGlass,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: AppTheme.borderGlass,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.arrow_back_ios_rounded,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            )
                          else
                            const SizedBox(width: 40),
                          const Spacer(),
                          Text(
                            'Step ${_currentStep + 1} of 4',
                            style: GoogleFonts.dmSans(
                              fontSize: 13,
                              color: AppTheme.textMuted,
                            ),
                          ),
                          const Spacer(),
                          const SizedBox(width: 40),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Step indicator
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: OnboardingStepIndicatorWidget(
                        currentStep: _currentStep,
                        totalSteps: 4,
                      ),
                    ),
                    const SizedBox(height: 28),
                    // Step content
                    Expanded(
                      child: FadeTransition(
                        opacity: _fadeAnim,
                        child: SlideTransition(
                          position: _slideAnim,
                          child: _buildCurrentStep(),
                        ),
                      ),
                    ),
                    // CTA button
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                      child: _buildCTAButton(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentStep() {
    switch (_currentStep) {
      case 0:
        return OnboardingStep1Widget(
          firstName: _firstName,
          age: _age,
          gender: _gender,
          interestedIn: _interestedIn,
          onFirstNameChanged: (v) => setState(() => _firstName = v),
          onAgeChanged: (v) => setState(() => _age = v),
          onGenderChanged: (v) => setState(() => _gender = v),
          onInterestedInChanged: (v) => setState(() => _interestedIn = v),
        );
      case 1:
        return OnboardingStep2Widget(
          selectedInterests: _selectedInterests,
          onInterestsChanged: (interests) => setState(() {
            _selectedInterests.clear();
            _selectedInterests.addAll(interests);
          }),
        );
      case 2:
        return OnboardingStep3Widget(
          city: _city,
          stateRegion: _stateRegion,
          country: _country,
          countryCode: _countryCode,
          regionId: _regionId,
          cityPlaceId: _cityPlaceId,
          areaPlaceId: _areaPlaceId,
          canonicalPlaceId: _canonicalPlaceId,
          locationDisplayName: _locationDisplayName,
          metroArea: _metroArea,
          latitude: _latitude,
          longitude: _longitude,
          locationSource: _locationSource,
          locationPermissionGranted: _locationPermissionGranted,
          onLocationChanged: (location) => setState(() {
            _city = location.city;
            _stateRegion = location.stateRegion;
            _country = location.country;
            _countryCode = location.countryCode;
            _regionId = location.regionId;
            _cityPlaceId = location.cityPlaceId;
            _areaPlaceId = location.areaPlaceId;
            _canonicalPlaceId = location.canonicalPlaceId;
            _locationDisplayName = location.locationDisplayName;
            _metroArea = location.metroArea ?? '';
            _latitude = location.latitude;
            _longitude = location.longitude;
            _locationSource = location.locationSource;
            _locationPermissionGranted = location.locationPermissionGranted;
          }),
        );
      case 3:
        return OnboardingStep4Widget(
          videoUrl: _profileVideoUrl,
          onVideoRecorded: (url) => setState(() => _profileVideoUrl = url),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildCTAButton() {
    final labels = [
      'Continue',
      'Continue',
      'Continue',
      'Finish & Start Sparking',
    ];

    final canProceed = _canProceed();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: canProceed && !_isSaving
            ? () {
                debugPrint('ONBOARDING CTA: step $_currentStep tapped');
                _nextStep();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 52,
          decoration: BoxDecoration(
            gradient: canProceed
                ? const LinearGradient(
                    colors: [Color(0xFFFF4458), Color(0xFFFF6B7A)],
                  )
                : null,
            color: canProceed ? null : const Color(0x33FFFFFF),
            borderRadius: BorderRadius.circular(16),
            boxShadow: canProceed
                ? [
                    BoxShadow(
                      color: AppTheme.primary.withAlpha(77),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Center(
            child: _isSaving
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.5,
                    ),
                  )
                : Text(
                    labels[_currentStep],
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: canProceed ? Colors.white : AppTheme.textMuted,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
