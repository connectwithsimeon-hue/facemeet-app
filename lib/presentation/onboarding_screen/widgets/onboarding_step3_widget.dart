import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/location_models.dart';
import '../../../services/android_diagnostics_service.dart';
import '../../../services/metro_location_service.dart';
import '../../../services/supabase_service.dart';
import '../../../theme/app_theme.dart';

class OnboardingLocationData {
  final String city;
  final String stateRegion;
  final String country;
  final String countryCode;
  final String? regionId;
  final String? cityPlaceId;
  final String? areaPlaceId;
  final String? canonicalPlaceId;
  final String locationDisplayName;
  final String? metroArea;
  final double? latitude;
  final double? longitude;
  final String locationSource;
  final bool locationPermissionGranted;

  const OnboardingLocationData({
    required this.city,
    required this.stateRegion,
    required this.country,
    required this.countryCode,
    required this.regionId,
    required this.cityPlaceId,
    required this.areaPlaceId,
    required this.canonicalPlaceId,
    required this.locationDisplayName,
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
  final String countryCode;
  final String? regionId;
  final String? cityPlaceId;
  final String? areaPlaceId;
  final String? canonicalPlaceId;
  final String locationDisplayName;
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
    required this.countryCode,
    required this.regionId,
    required this.cityPlaceId,
    required this.areaPlaceId,
    required this.canonicalPlaceId,
    required this.locationDisplayName,
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
  final TextEditingController _searchController = TextEditingController();

  List<LocationCountry> _countries = const [];
  List<LocationRegion> _regions = const [];
  List<LocationPlace> _places = const [];
  LocationCountry? _selectedCountry;
  LocationRegion? _selectedRegion;
  LocationPlace? _selectedPlace;

  bool _loadingCountries = true;
  bool _loadingRegions = false;
  bool _searchingPlaces = false;
  bool _isLocating = false;
  bool _locationDenied = false;
  bool _locationDetected = false;
  String? _loadError;
  int _searchGeneration = 0;

  double? _latitude;
  double? _longitude;
  String _locationSource = 'picker';
  bool _locationPermissionGranted = false;

  @override
  void initState() {
    super.initState();
    _latitude = widget.latitude;
    _longitude = widget.longitude;
    _locationSource = widget.locationSource == 'manual'
        ? 'picker'
        : widget.locationSource;
    _locationPermissionGranted = widget.locationPermissionGranted;
    _loadCountries();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadCountries() async {
    setState(() {
      _loadingCountries = true;
      _loadError = null;
    });

    try {
      final countries = await SupabaseService.instance.getLocationCountries();
      if (!mounted) return;
      final initialCountryCode = widget.countryCode.isNotEmpty
          ? widget.countryCode
          : widget.country;
      final selected = countries.where((country) {
        return country.code.toUpperCase() == initialCountryCode.toUpperCase();
      }).firstOrNull;

      setState(() {
        _countries = countries;
        _selectedCountry =
            selected ??
            countries.where((country) => country.code == 'US').firstOrNull ??
            countries.firstOrNull;
        _loadingCountries = false;
      });

      if (_selectedCountry != null) {
        await _loadRegions(
          _selectedCountry!.code,
          initialRegionId: widget.regionId,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingCountries = false;
        _loadError = 'Could not load locations. Please try again.';
      });
    }
  }

  Future<void> _loadRegions(
    String countryCode, {
    String? initialRegionId,
  }) async {
    setState(() {
      _loadingRegions = true;
      _regions = const [];
      _selectedRegion = null;
      _places = const [];
      _selectedPlace = null;
    });

    try {
      final regions = await SupabaseService.instance.getLocationRegions(
        countryCode,
      );
      if (!mounted) return;
      final selected = regions.where((region) {
        return region.id == initialRegionId ||
            region.name.toLowerCase() == widget.stateRegion.toLowerCase();
      }).firstOrNull;

      setState(() {
        _regions = regions;
        _selectedRegion = selected;
        _loadingRegions = false;
      });

      if (widget.canonicalPlaceId != null && widget.city.isNotEmpty) {
        _searchController.text = widget.city;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingRegions = false;
        _loadError = 'Could not load regions. Please try again.';
      });
    }
  }

  Future<void> _searchPlaces(String query) async {
    final country = _selectedCountry;
    final generation = ++_searchGeneration;
    if (country == null) return;

    setState(() {
      _searchingPlaces = true;
      _places = const [];
      _loadError = null;
    });

    try {
      final places = await SupabaseService.instance.searchLocations(
        query: query.trim(),
        countryCode: country.code,
        regionId: _selectedRegion?.id,
        limit: 20,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _places = places;
        _searchingPlaces = false;
      });
    } catch (e) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _searchingPlaces = false;
        _loadError = 'Location search failed. Try another city or area.';
      });
    }
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
        _locationSource = 'gps';
        _locationPermissionGranted = true;
      });

      if (metro != null) {
        await _selectDetectedMetro(metro);
      }

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

  Future<void> _selectDetectedMetro(MetroArea metro) async {
    final country = _countries.where((item) {
      return item.code.toUpperCase() == metro.country.toUpperCase() ||
          item.name.toLowerCase() == metro.country.toLowerCase();
    }).firstOrNull;
    if (country == null) return;

    setState(() => _selectedCountry = country);
    await _loadRegions(country.code);
    final region = _regions.where((item) {
      return item.name.toLowerCase() == metro.stateRegion.toLowerCase() ||
          (item.regionCode ?? '').toLowerCase() ==
              metro.stateRegion.toLowerCase();
    }).firstOrNull;
    if (region != null) {
      setState(() => _selectedRegion = region);
    }

    final matches = await SupabaseService.instance.searchLocations(
      query: metro.name,
      countryCode: country.code,
      regionId: region?.id,
      limit: 5,
    );
    if (!mounted || matches.isEmpty) return;
    _selectPlace(matches.first, source: 'gps');
  }

  void _handleDenied() {
    if (!mounted) return;
    setState(() {
      _locationDenied = true;
      _isLocating = false;
      _locationSource = 'picker';
      _locationPermissionGranted = false;
      _latitude = null;
      _longitude = null;
    });
    _emitLocation();
  }

  void _selectPlace(LocationPlace place, {String source = 'picker'}) {
    setState(() {
      _selectedPlace = place;
      _searchController.text = place.displayName;
      _places = const [];
      _locationSource = source;
      if (!_locationPermissionGranted ||
          _latitude == null ||
          _longitude == null) {
        _latitude = place.latitude;
        _longitude = place.longitude;
      }
    });
    _emitLocation();
  }

  void _emitLocation() {
    final country = _selectedCountry;
    final region = _selectedRegion;
    final place = _selectedPlace;
    widget.onLocationChanged(
      OnboardingLocationData(
        city: place?.cityName ?? '',
        stateRegion: region?.name ?? place?.regionName ?? '',
        country: country?.code ?? place?.countryCode ?? 'US',
        countryCode: country?.code ?? place?.countryCode ?? 'US',
        regionId: region?.id ?? place?.regionId,
        cityPlaceId: place == null
            ? null
            : place.isArea
            ? place.parentPlaceId
            : place.id,
        areaPlaceId: place?.isArea == true ? place?.id : null,
        canonicalPlaceId: place?.id,
        locationDisplayName: place?.displayName ?? '',
        metroArea: place?.areaName ?? place?.cityName,
        latitude: _latitude,
        longitude: _longitude,
        locationSource: _locationSource,
        locationPermissionGranted: _locationPermissionGranted,
      ),
    );
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
            'Choose a real location so FaceMeet can show nearby people first.',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'GPS is optional. Your saved location comes from the picker.',
            style: GoogleFonts.dmSans(
              fontSize: 13,
              color: AppTheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 28),
          _LocationActionButton(
            isLoading: _isLocating,
            onTap: _isLocating ? null : _requestLocation,
          ),
          const SizedBox(height: 16),
          if (_locationDenied) ...[
            _InfoBanner(
              icon: Icons.info_outline_rounded,
              color: const Color(0xFFF59E0B),
              text:
                  'No problem. Pick your country, region, and city below to continue.',
            ),
            const SizedBox(height: 16),
          ],
          if (_locationDetected) ...[
            _InfoBanner(
              icon: Icons.check_circle_rounded,
              color: const Color(0xFF22C55E),
              text:
                  'Location permission is on. Confirm your city or area below.',
            ),
            const SizedBox(height: 16),
          ],
          if (_loadError != null) ...[
            _InfoBanner(
              icon: Icons.error_outline_rounded,
              color: const Color(0xFFF59E0B),
              text: _loadError!,
            ),
            const SizedBox(height: 16),
          ],
          _CountryDropdown(
            countries: _countries,
            selectedCountry: _selectedCountry,
            isLoading: _loadingCountries,
            onChanged: (country) async {
              if (country == null) return;
              setState(() {
                _selectedCountry = country;
                _selectedRegion = null;
                _selectedPlace = null;
                _searchController.clear();
                _locationSource = 'picker';
                _locationPermissionGranted = false;
              });
              _emitLocation();
              await _loadRegions(country.code);
            },
          ),
          const SizedBox(height: 14),
          _RegionDropdown(
            regions: _regions,
            selectedRegion: _selectedRegion,
            isLoading: _loadingRegions,
            onChanged: (region) {
              setState(() {
                _selectedRegion = region;
                _selectedPlace = null;
                _searchController.clear();
                _places = const [];
                _locationSource = 'picker';
                _locationPermissionGranted = false;
              });
              _emitLocation();
            },
          ),
          const SizedBox(height: 14),
          _PlaceSearchField(
            controller: _searchController,
            enabled: _selectedCountry != null,
            isSearching: _searchingPlaces,
            onChanged: _searchPlaces,
          ),
          const SizedBox(height: 10),
          if (_places.isNotEmpty)
            _PlaceResultsList(places: _places, onSelected: _selectPlace)
          else if (_selectedPlace != null)
            _SelectedPlaceCard(place: _selectedPlace!),
          const SizedBox(height: 14),
          Text(
            'Typing is only used to search. FaceMeet saves the selected location record.',
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

class _LocationActionButton extends StatelessWidget {
  final bool isLoading;
  final VoidCallback? onTap;

  const _LocationActionButton({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
            if (isLoading)
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
              isLoading ? 'Detecting your location...' : 'Use My Location',
              style: GoogleFonts.dmSans(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppTheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountryDropdown extends StatelessWidget {
  final List<LocationCountry> countries;
  final LocationCountry? selectedCountry;
  final bool isLoading;
  final ValueChanged<LocationCountry?> onChanged;

  const _CountryDropdown({
    required this.countries,
    required this.selectedCountry,
    required this.isLoading,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _PickerShell(
      label: 'Country',
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LocationCountry>(
          value: countries.contains(selectedCountry) ? selectedCountry : null,
          isExpanded: true,
          dropdownColor: AppTheme.backgroundDark,
          hint: Text(
            isLoading ? 'Loading countries...' : 'Choose country',
            style: GoogleFonts.dmSans(color: AppTheme.textHint),
          ),
          items: countries.map((country) {
            return DropdownMenuItem<LocationCountry>(
              value: country,
              child: Text(
                country.name,
                style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
              ),
            );
          }).toList(),
          onChanged: isLoading ? null : onChanged,
        ),
      ),
    );
  }
}

class _RegionDropdown extends StatelessWidget {
  final List<LocationRegion> regions;
  final LocationRegion? selectedRegion;
  final bool isLoading;
  final ValueChanged<LocationRegion?> onChanged;

  const _RegionDropdown({
    required this.regions,
    required this.selectedRegion,
    required this.isLoading,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _PickerShell(
      label: 'State / Region',
      child: DropdownButtonHideUnderline(
        child: DropdownButton<LocationRegion>(
          value: regions.contains(selectedRegion) ? selectedRegion : null,
          isExpanded: true,
          dropdownColor: AppTheme.backgroundDark,
          hint: Text(
            isLoading ? 'Loading regions...' : 'Choose state or region',
            style: GoogleFonts.dmSans(color: AppTheme.textHint),
          ),
          items: regions.map((region) {
            return DropdownMenuItem<LocationRegion>(
              value: region,
              child: Text(
                region.name,
                style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
              ),
            );
          }).toList(),
          onChanged: isLoading ? null : onChanged,
        ),
      ),
    );
  }
}

class _PlaceSearchField extends StatelessWidget {
  final TextEditingController controller;
  final bool enabled;
  final bool isSearching;
  final ValueChanged<String> onChanged;

  const _PlaceSearchField({
    required this.controller,
    required this.enabled,
    required this.isSearching,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _PickerShell(
      label: 'City or Area',
      child: TextField(
        controller: controller,
        enabled: enabled,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: GoogleFonts.dmSans(fontSize: 15, color: Colors.white),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: enabled
              ? 'Search Lagos, VI, Phoenix...'
              : 'Choose country first',
          hintStyle: GoogleFonts.dmSans(color: AppTheme.textHint),
          suffixIcon: isSearching
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : const Icon(Icons.search_rounded, color: AppTheme.textMuted),
        ),
      ),
    );
  }
}

class _PickerShell extends StatelessWidget {
  final String label;
  final Widget child;

  const _PickerShell({required this.label, required this.child});

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
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceGlass,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderGlass, width: 1),
              ),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

class _PlaceResultsList extends StatelessWidget {
  final List<LocationPlace> places;
  final ValueChanged<LocationPlace> onSelected;

  const _PlaceResultsList({required this.places, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      child: Column(
        children: places.take(8).map((place) {
          return ListTile(
            dense: true,
            leading: Icon(
              place.isArea
                  ? Icons.location_city_rounded
                  : Icons.location_on_rounded,
              color: AppTheme.primary,
              size: 20,
            ),
            title: Text(
              place.displayName,
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              place.isArea ? 'Area / neighborhood' : 'City',
              style: GoogleFonts.dmSans(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
            onTap: () => onSelected(place),
          );
        }).toList(),
      ),
    );
  }
}

class _SelectedPlaceCard extends StatelessWidget {
  final LocationPlace place;

  const _SelectedPlaceCard({required this.place});

  @override
  Widget build(BuildContext context) {
    return _InfoBanner(
      icon: Icons.check_circle_rounded,
      color: const Color(0xFF22C55E),
      text: 'Selected: ${place.displayName}',
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
