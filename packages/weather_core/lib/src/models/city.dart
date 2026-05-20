// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

/// A geographic location resolved from a city name lookup.
///
/// Returned by a geocoding provider as part of a `GeocodeResult`. Used as the
/// input to forecast retrieval — providers operate on coordinates, not names,
/// so geocoding is the unavoidable first hop of any user-initiated weather
/// request.
@immutable
class City {
  const City({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.country,
    required this.countryCode,
    this.admin1,
    this.timezone,
    this.population,
    this.elevationMeters,
  });

  /// Construct a [City] from an Open-Meteo geocoding API response object.
  ///
  /// Throws [FormatException] if required fields are missing or have the
  /// wrong type — this indicates an upstream contract change and should
  /// be surfaced rather than silently coerced.
  factory City.fromOpenMeteoJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final country = json['country'];
    final countryCode = json['country_code'];

    if (id is! int) {
      throw const FormatException(
        'Missing or non-integer "id" in geocoding response',
      );
    }
    if (name is! String || name.isEmpty) {
      throw const FormatException(
        'Missing or empty "name" in geocoding response',
      );
    }
    if (latitude is! num) {
      throw const FormatException(
        'Missing or non-numeric "latitude" in geocoding response',
      );
    }
    if (longitude is! num) {
      throw const FormatException(
        'Missing or non-numeric "longitude" in geocoding response',
      );
    }
    if (country is! String) {
      throw const FormatException('Missing "country" in geocoding response');
    }
    if (countryCode is! String) {
      throw const FormatException(
        'Missing "country_code" in geocoding response',
      );
    }

    return City(
      id: id,
      name: name,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      country: country,
      countryCode: countryCode,
      admin1: json['admin1'] is String ? json['admin1'] as String : null,
      timezone: json['timezone'] is String ? json['timezone'] as String : null,
      population: json['population'] is int ? json['population'] as int : null,
      elevationMeters: json['elevation'] is num
          ? (json['elevation'] as num).toDouble()
          : null,
    );
  }

  /// Stable identifier from the geocoding provider.
  final int id;

  /// Display name (e.g. "Boston").
  final String name;

  final double latitude;
  final double longitude;

  /// Full country name (e.g. "France").
  final String country;

  /// ISO 3166-1 alpha-2 country code (e.g. "FR"). Bounded enum (~250 values),
  /// safe to use as a low-cardinality metric attribute.
  final String countryCode;

  /// First-level administrative division — state, region, prefecture
  /// (e.g. "Occitanie"). May be null for small countries.
  final String? admin1;

  /// IANA timezone (e.g. "Europe/Paris").
  final String? timezone;

  /// Population estimate at the time of the geocoding lookup. Used as a
  /// coarse signal for cardinality bucketing in metrics (small/medium/large
  /// city); the raw population number is too high-cardinality to be a metric
  /// attribute.
  final int? population;

  /// Elevation in meters above mean sea level.
  final double? elevationMeters;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is City &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          latitude == other.latitude &&
          longitude == other.longitude &&
          country == other.country &&
          countryCode == other.countryCode &&
          admin1 == other.admin1 &&
          timezone == other.timezone &&
          population == other.population &&
          elevationMeters == other.elevationMeters;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    latitude,
    longitude,
    country,
    countryCode,
    admin1,
    timezone,
    population,
    elevationMeters,
  );

  @override
  String toString() => 'City($name, $countryCode @ $latitude,$longitude)';

  /// Round-trip JSON serializer for service-to-service traffic.
  ///
  /// Distinct from [fromOpenMeteoJson] — that adapter handles Open-Meteo's
  /// snake_case schema with its specific quirks (e.g., `country_code`,
  /// `elevation`). [toJson] / [fromJson] use this package's canonical
  /// camelCase keys so downstream Dart services can deserialize without
  /// knowing anything about the upstream provider's contract.
  ///
  /// Optional fields are omitted from the output when null. [fromJson]
  /// accepts both presence and absence and applies the same type-strict
  /// validation as [fromOpenMeteoJson].
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'latitude': latitude,
    'longitude': longitude,
    'country': country,
    'countryCode': countryCode,
    if (admin1 != null) 'admin1': admin1,
    if (timezone != null) 'timezone': timezone,
    if (population != null) 'population': population,
    if (elevationMeters != null) 'elevationMeters': elevationMeters,
  };

  /// Inverse of [toJson]. Throws [FormatException] on bad input.
  factory City.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final country = json['country'];
    final countryCode = json['countryCode'];

    if (id is! int) {
      throw const FormatException('Missing or non-integer "id" in city JSON');
    }
    if (name is! String || name.isEmpty) {
      throw const FormatException('Missing or empty "name" in city JSON');
    }
    if (latitude is! num) {
      throw const FormatException(
        'Missing or non-numeric "latitude" in city JSON',
      );
    }
    if (longitude is! num) {
      throw const FormatException(
        'Missing or non-numeric "longitude" in city JSON',
      );
    }
    if (country is! String) {
      throw const FormatException('Missing "country" in city JSON');
    }
    if (countryCode is! String) {
      throw const FormatException('Missing "countryCode" in city JSON');
    }

    return City(
      id: id,
      name: name,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      country: country,
      countryCode: countryCode,
      admin1: json['admin1'] is String ? json['admin1'] as String : null,
      timezone: json['timezone'] is String ? json['timezone'] as String : null,
      population: json['population'] is int ? json['population'] as int : null,
      elevationMeters: json['elevationMeters'] is num
          ? (json['elevationMeters'] as num).toDouble()
          : null,
    );
  }
}
