import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import '../../../theme/app_theme.dart';
import '../../../services/android_diagnostics_service.dart';
import '../../../services/metro_location_service.dart';

class OnboardingLocationData {
  final String city;
  final String stateRegion;
  final String country;
  final String? metroArea;
  final double? latitude;
  final double? longitude;
  final String locationSource;
  final bool locationPermissionGranted;

  const OnboardingLocationData({
    required this.city,
    required this.stateRegion,
    required this.country,
    required this.metroArea,
    required this.latitude,
    required this.longitude,
    required this.locationSource,
    required this.locationPermissionGranted,
  });
}

class OnboardingStep3Widget extends StatefulWidget {
  final String city;
  final String stateRegion;
  final String country;
  final String metroArea;
  final double? latitude;
  final double? longitude;
  final String locationSource;
  final bool locationPermissionGranted;
  final ValueChanged<OnboardingLocationData> onLocationChanged;

  const OnboardingStep3Widget({
    super.key,
    required this.city,
    required this.stateRegion,
    required this.country,
    required this.metroArea,
    required this.latitude,
    required this.longitude,
    required this.locationSource,
    required this.locationPermissionGranted,
    required this.onLocationChanged,
  });

  @override
  State<OnboardingStep3Widget> createState() => _OnboardingStep3WidgetState();
}

class _OnboardingStep3WidgetState extends State<OnboardingStep3Widget> {
  static const _noMetroValue = '__no_metro__';
  static const _manualMetroValue = '__manual_metro__';

  late final TextEditingController _cityController;
  late final TextEditingController _stateController;
  late final TextEditingController _countryController;
  late final TextEditingController _metroController;

  bool _isLocating = false;
  bool _locationDenied = false;
  bool _locationDetected = false;
  bool _manualMetro = false;
  String? _selectedMetro;
  double? _latitude;
  double? _longitude;
  String _locationSource = 'manual';
  bool _locationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _cityController = TextEditingController(text: widget.city);
    _stateController = TextEditingController(text: widget.stateRegion);
    _countryController = TextEditingController(
      text: widget.country.isNotEmpty ? widget.country : 'US',
    );
    _metroController = TextEditingController(text: widget.metroArea);
    _latitude = widget.latitude;
    _longitude = widget.longitude;
    _locationSource = widget.locationSource;
    _locationPermissionGranted = widget.locationPermissionGranted;

    if (widget.metroArea.isNotEmpty &&
        MetroLocationService.metroNames.contains(widget.metroArea)) {
      _selectedMetro = widget.metroArea;
    } else if (widget.metroArea.isNotEmpty) {
      _selectedMetro = _manualMetroValue;
      _manualMetro = true;
    }
  }

  @override
  void dispose() {
    _cityController.dispose();
    _stateController.dispose();
    _countryController.dispose();
    _metroController.dispose();
    super.dispose();
  }

  void _emitLocation({String source = 'manual', bool? permissionGranted}) {
    _locationSource = source;
    _locationPermissionGranted =
        permissionGranted ?? _locationPermissionGranted;
    widget.onLocationChanged(
      OnboardingLocationData(
        city: _cityController.text.trim(),
        stateRegion: _stateController.text.trim(),
        country: _countryController.text.trim().isNotEmpty
            ? _countryController.text.trim()
            : 'US',
        metroArea: _metroController.text.trim().isNotEmpty
            ? _metroController.text.trim()
            : null,
        latitude: _locationPermissionGranted ? _latitude : null,
        longitude: _locationPermissionGranted ? _longitude : null,
        locationSource: _locationSource,
        locationPermissionGranted: _locationPermissionGranted,
      ),
    );
  }

  Future<void> _requestLocation() async {
    setState(() {
      _isLocating = true;
      _locationDenied = false;
      _locationDetected = false;
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      await AndroidDiagnosticsService.instance.setValue(
        'location_permission_status',
        serviceEnabled ? 'service_enabled' : 'service_disabled',
      );
      if (!serviceEnabled) {
        _handleDenied();
        return;
      }

      var permission = await Geolocator.checkPermission();
      await AndroidDiagnosticsService.instance.setValue(
        'location_permission_status',
        permission.name,
      );
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        await AndroidDiagnosticsService.instance.setValue(
          'location_permission_request_result',
          permission.name,
        );
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        await AndroidDiagnosticsService.instance.setValue(
          'location_updated_yes_no',
          'no',
        );
        _handleDenied();
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );

      final metro = MetroLocationService.findMetroArea(
        position.latitude,
        position.longitude,
      );

      if (!mounted) return;
      setState(() {
        _isLocating = false;
        _locationDetected = true;
        _latitude = position.latitude;
        _longitude = position.longitude;
        _locationSource = 'detected';
        _locationPermissionGranted = true;

        if (metro != null) {
          _cityController.text = metro.name;
          _stateController.text = metro.stateRegion;
          _countryController.text = metro.country;
          _metroController.text = metro.name;
          _selectedMetro = metro.name;
          _manualMetro = false;
        }
      });

      _emitLocation(source: 'detected', permissionGranted: true);
      await AndroidDiagnosticsService.instance.setValues({
        'location_permission_status': permission.name,
        'location_updated_yes_no': 'yes',
      });
    } catch (e) {
      await AndroidDiagnosticsService.instance.setValue(
        'location_updated_yes_no',
        'no',
      );
      _handleDenied();
    }
  }

  void _handleDenied() {
    if (!mounted) return;
    setState(() {
      _locationDenied = true;
      _isLocating = false;
      _locationSource = 'manual';
      _locationPermissionGranted = false;
      _latitude = null;
      _longitude = null;
    });
    _emitLocation(source: 'manual', permissionGranted: false);
  }

  void _handleMetroChanged(String? value) {
    setState(() {
      _selectedMetro = value == _noMetroValue ? null : value;
      _manualMetro = value == _manualMetroValue;
      if (value == null || value == _noMetroValue) {
        _metroController.clear();
      } else if (value != _manualMetroValue) {
        _metroController.text = value;
      } else {
        _metroController.clear();
      }
    });
    _emitLocation();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Where are you based?',
            style: GoogleFonts.dmSans(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tell us where you are so we can show people near you first.',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'FaceMeet is open for profile uploads everywhere.',
            style: GoogleFonts.dmSans(
              fontSize: 13,
              color: AppTheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 28),

          GestureDetector(
            onTap: _isLocating ? null : _requestLocation,
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0x33FF4458), Color(0x1AFF4458)],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x66FF4458), width: 1),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isLocating)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: AppTheme.primary,
                        strokeWidth: 2,
                      ),
                    )
                  else
                    const Icon(
                      Icons.my_location_rounded,
                      color: AppTheme.primary,
                      size: 22,
                    ),
                  const SizedBox(width: 10),
                  Text(
                    _isLocating
                        ? 'Detecting your location...'
                        : 'Use My Location',
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          if (_locationDenied) ...[
            _InfoBanner(
              icon: Icons.info_outline_rounded,
              color: const Color(0xFFF59E0B),
              text:
                  'No problem. Enter your city manually and you can continue.',
            ),
            const SizedBox(height: 16),
          ],

          if (_locationDetected) ...[
            _InfoBanner(
              icon: Icons.check_circle_rounded,
              color: const Color(0xFF22C55E),
              text: _metroController.text.trim().isNotEmpty
                  ? 'Location detected. You can edit it below.'
                  : 'Location detected. Add your city so nearby people can find you.',
            ),
            const SizedBox(height: 16),
          ],

          _LocationTextField(
            controller: _cityController,
            label: 'City',
            hint: 'Dallas, Chicago, London...',
            textInputAction: TextInputAction.next,
            onChanged: (_) => _emitLocation(),
          ),
          const SizedBox(height: 14),
          _LocationTextField(
            controller: _stateController,
            label: 'State / Region',
            hint: 'Texas, Illinois, Greater London...',
            textInputAction: TextInputAction.next,
            onChanged: (_) => _emitLocation(),
          ),
          const SizedBox(height: 14),
          _LocationTextField(
            controller: _countryController,
            label: 'Country',
            hint: 'US',
            textInputAction: TextInputAction.next,
            onChanged: (_) => _emitLocation(),
          ),
          const SizedBox(height: 14),

          _MetroDropdown(
            selectedMetro: _selectedMetro,
            onChanged: _handleMetroChanged,
          ),
          if (_manualMetro) ...[
            const SizedBox(height: 12),
            _LocationTextField(
              controller: _metroController,
              label: 'Metro Area',
              hint: 'Optional, if different from your city',
              textInputAction: TextInputAction.done,
              onChanged: (_) => _emitLocation(),
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Your exact location is only saved when you choose Use My Location.',
            style: GoogleFonts.dmSans(
              fontSize: 12,
              color: AppTheme.textMuted,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _InfoBanner({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withAlpha(26),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(51), width: 1),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.dmSans(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputAction textInputAction;
  final ValueChanged<String> onChanged;

  const _LocationTextField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.textInputAction,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: textInputAction,
              style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: GoogleFonts.dmSans(color: AppTheme.textHint),
                filled: true,
                fillColor: AppTheme.surfaceGlass,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: AppTheme.borderGlass),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: AppTheme.primary),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MetroDropdown extends StatelessWidget {
  final String? selectedMetro;
  final ValueChanged<String?> onChanged;

  const _MetroDropdown({required this.selectedMetro, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final items = <DropdownMenuItem<String?>>[
      DropdownMenuItem<String?>(
        value: _OnboardingStep3WidgetState._noMetroValue,
        child: Text(
          'No metro / not sure',
          style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
        ),
      ),
      ...MetroLocationService.metroNames.map((metro) {
        return DropdownMenuItem<String?>(value: metro, child: Text(metro));
      }),
      DropdownMenuItem<String?>(
        value: _OnboardingStep3WidgetState._manualMetroValue,
        child: Text(
          'My city is not listed',
          style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
        ),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Metro Area (optional)',
          style: GoogleFonts.dmSans(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppTheme.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceGlass,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderGlass, width: 1),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: selectedMetro,
                  hint: Text(
                    'Choose a metro or enter your own',
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      color: AppTheme.textHint,
                    ),
                  ),
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1A1A1F),
                  icon: const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: AppTheme.textMuted,
                  ),
                  style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
                  items: items,
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
