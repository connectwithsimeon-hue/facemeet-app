import 'dart:math';

/// Approved metro areas for FaceMeet launch.
/// Each metro has a center coordinate and a radius in miles.
class MetroArea {
  final String name;
  final String stateRegion;
  final String country;
  final double lat;
  final double lng;
  final double radiusMiles;

  const MetroArea({
    required this.name,
    required this.stateRegion,
    this.country = 'US',
    required this.lat,
    required this.lng,
    required this.radiusMiles,
  });
}

class MetroLocationService {
  static const List<MetroArea> approvedMetros = [
    MetroArea(
      name: 'Dallas-Fort Worth',
      stateRegion: 'Texas',
      lat: 32.7767,
      lng: -96.7970,
      radiusMiles: 60,
    ),
    MetroArea(
      name: 'Houston',
      stateRegion: 'Texas',
      lat: 29.7604,
      lng: -95.3698,
      radiusMiles: 50,
    ),
    MetroArea(
      name: 'Austin',
      stateRegion: 'Texas',
      lat: 30.2672,
      lng: -97.7431,
      radiusMiles: 40,
    ),
    MetroArea(
      name: 'Atlanta',
      stateRegion: 'Georgia',
      lat: 33.7490,
      lng: -84.3880,
      radiusMiles: 40,
    ),
    MetroArea(
      name: 'New York',
      stateRegion: 'New York',
      lat: 40.7128,
      lng: -74.0060,
      radiusMiles: 50,
    ),
  ];

  static const List<String> metroNames = [
    'Dallas-Fort Worth',
    'Houston',
    'Austin',
    'Atlanta',
    'New York',
  ];

  /// Returns the metro name if the coordinates fall within an approved metro,
  /// or null if outside all metros.
  static String? findMetro(double lat, double lng) {
    return findMetroArea(lat, lng)?.name;
  }

  /// Returns the closest known metro if the coordinates fall within its radius.
  /// Unknown metros are allowed elsewhere in onboarding; this only enriches data.
  static MetroArea? findMetroArea(double lat, double lng) {
    // Find the closest metro that is within its radius
    MetroArea? closest;
    double closestDist = double.infinity;

    for (final metro in approvedMetros) {
      final dist = _distanceMiles(lat, lng, metro.lat, metro.lng);
      if (dist <= metro.radiusMiles && dist < closestDist) {
        closestDist = dist;
        closest = metro;
      }
    }

    return closest;
  }

  /// Haversine distance in miles between two lat/lng points.
  static double _distanceMiles(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    const earthRadiusMiles = 3958.8;
    final dLat = _toRad(lat2 - lat1);
    final dLng = _toRad(lng2 - lng1);
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRad(lat1)) * cos(_toRad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusMiles * c;
  }

  static double _toRad(double deg) => deg * pi / 180;
}
