class LocationCountry {
  final String code;
  final String name;

  const LocationCountry({required this.code, required this.name});

  factory LocationCountry.fromMap(Map<String, dynamic> map) {
    return LocationCountry(
      code: map['code']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
    );
  }
}

class LocationRegion {
  final String id;
  final String countryCode;
  final String? regionCode;
  final String name;

  const LocationRegion({
    required this.id,
    required this.countryCode,
    required this.regionCode,
    required this.name,
  });

  factory LocationRegion.fromMap(Map<String, dynamic> map) {
    return LocationRegion(
      id: map['id']?.toString() ?? '',
      countryCode: map['country_code']?.toString() ?? '',
      regionCode: map['region_code']?.toString(),
      name: map['name']?.toString() ?? '',
    );
  }
}

class LocationPlace {
  final String id;
  final String? parentPlaceId;
  final String? parentPlaceName;
  final String countryCode;
  final String countryName;
  final String? regionId;
  final String? regionCode;
  final String? regionName;
  final String placeName;
  final String placeType;
  final String displayName;
  final double? latitude;
  final double? longitude;

  const LocationPlace({
    required this.id,
    required this.parentPlaceId,
    required this.parentPlaceName,
    required this.countryCode,
    required this.countryName,
    required this.regionId,
    required this.regionCode,
    required this.regionName,
    required this.placeName,
    required this.placeType,
    required this.displayName,
    required this.latitude,
    required this.longitude,
  });

  bool get isArea =>
      placeType == 'local_area' ||
      placeType == 'area' ||
      placeType == 'neighborhood' ||
      placeType == 'district';

  String get cityName =>
      isArea && parentPlaceName != null ? parentPlaceName! : placeName;

  String? get areaName => isArea ? placeName : null;

  factory LocationPlace.fromMap(Map<String, dynamic> map) {
    double? parseDouble(dynamic value) {
      if (value is num) return value.toDouble();
      return double.tryParse(value?.toString() ?? '');
    }

    return LocationPlace(
      id: map['place_id']?.toString() ?? map['id']?.toString() ?? '',
      parentPlaceId: map['parent_place_id']?.toString(),
      parentPlaceName: map['parent_place_name']?.toString(),
      countryCode: map['country_code']?.toString() ?? '',
      countryName: map['country_name']?.toString() ?? '',
      regionId: map['region_id']?.toString(),
      regionCode: map['region_code']?.toString(),
      regionName: map['region_name']?.toString(),
      placeName: map['place_name']?.toString() ?? map['name']?.toString() ?? '',
      placeType: map['place_type']?.toString() ?? 'city',
      displayName: map['display_name']?.toString() ?? '',
      latitude: parseDouble(map['latitude']),
      longitude: parseDouble(map['longitude']),
    );
  }
}
