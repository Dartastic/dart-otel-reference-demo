// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

void main() {
  group('City.fromOpenMeteoJson', () {
    final validJson = <String, dynamic>{
      'id': 2972315,
      'name': 'Toulouse',
      'latitude': 43.60426,
      'longitude': 1.44367,
      'country': 'France',
      'country_code': 'FR',
      'admin1': 'Occitanie',
      'timezone': 'Europe/Paris',
      'population': 433055,
      'elevation': 146.0,
    };

    test('parses a full Open-Meteo geocoding response', () {
      final city = City.fromOpenMeteoJson(validJson);
      expect(city.id, 2972315);
      expect(city.name, 'Toulouse');
      expect(city.latitude, closeTo(43.60426, 1e-6));
      expect(city.longitude, closeTo(1.44367, 1e-6));
      expect(city.country, 'France');
      expect(city.countryCode, 'FR');
      expect(city.admin1, 'Occitanie');
      expect(city.timezone, 'Europe/Paris');
      expect(city.population, 433055);
      expect(city.elevationMeters, 146.0);
    });

    test('handles missing optional fields', () {
      final minimal = Map<String, dynamic>.from(validJson)
        ..remove('admin1')
        ..remove('timezone')
        ..remove('population')
        ..remove('elevation');
      final city = City.fromOpenMeteoJson(minimal);
      expect(city.admin1, isNull);
      expect(city.timezone, isNull);
      expect(city.population, isNull);
      expect(city.elevationMeters, isNull);
    });

    test('coerces integer latitude/longitude to double', () {
      final integerCoords = Map<String, dynamic>.from(validJson)
        ..['latitude'] = 43
        ..['longitude'] = 1;
      final city = City.fromOpenMeteoJson(integerCoords);
      expect(city.latitude, 43.0);
      expect(city.longitude, 1.0);
    });

    test('throws FormatException on missing id', () {
      final bad = Map<String, dynamic>.from(validJson)..remove('id');
      expect(() => City.fromOpenMeteoJson(bad), throwsFormatException);
    });

    test('throws FormatException on non-numeric latitude', () {
      final bad = Map<String, dynamic>.from(validJson)
        ..['latitude'] = '43.60426';
      expect(() => City.fromOpenMeteoJson(bad), throwsFormatException);
    });

    test('throws FormatException on empty name', () {
      final bad = Map<String, dynamic>.from(validJson)..['name'] = '';
      expect(() => City.fromOpenMeteoJson(bad), throwsFormatException);
    });
  });

  group('City equality', () {
    final a = const City(
      id: 1,
      name: 'A',
      latitude: 1,
      longitude: 2,
      country: 'France',
      countryCode: 'FR',
    );
    final b = const City(
      id: 1,
      name: 'A',
      latitude: 1,
      longitude: 2,
      country: 'France',
      countryCode: 'FR',
    );
    final c = const City(
      id: 2,
      name: 'A',
      latitude: 1,
      longitude: 2,
      country: 'France',
      countryCode: 'FR',
    );

    test('structural equality', () {
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('different id => unequal', () {
      expect(a, isNot(equals(c)));
    });
  });

  group('GeocodeResult', () {
    final toulouse = const City(
      id: 1,
      name: 'Toulouse',
      latitude: 43.6,
      longitude: 1.44,
      country: 'France',
      countryCode: 'FR',
    );
    final paris = const City(
      id: 2,
      name: 'Paris',
      latitude: 48.85,
      longitude: 2.35,
      country: 'France',
      countryCode: 'FR',
    );

    test('isEmpty / isNotEmpty / isAmbiguous', () {
      const empty = GeocodeResult(query: 'q', matches: []);
      expect(empty.isEmpty, true);
      expect(empty.isNotEmpty, false);
      expect(empty.isAmbiguous, false);

      final single = GeocodeResult(query: 'q', matches: [toulouse]);
      expect(single.isEmpty, false);
      expect(single.isAmbiguous, false);

      final multi = GeocodeResult(query: 'q', matches: [toulouse, paris]);
      expect(multi.isAmbiguous, true);
    });

    test('best returns first match when present', () {
      final result = GeocodeResult(query: 'q', matches: [toulouse, paris]);
      expect(result.best, toulouse);
    });

    test('best throws StateError on empty result', () {
      const empty = GeocodeResult(query: 'q', matches: []);
      expect(() => empty.best, throwsStateError);
    });
  });
}
