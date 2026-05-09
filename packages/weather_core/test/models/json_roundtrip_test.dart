// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

void main() {
  const toulouse = City(
    id: 2972315,
    name: 'Toulouse',
    latitude: 43.60426,
    longitude: 1.44367,
    country: 'France',
    countryCode: 'FR',
    admin1: 'Occitanie',
    timezone: 'Europe/Paris',
    population: 433055,
    elevationMeters: 146.0,
  );

  final current = CurrentWeather(
    observedAt: DateTime.utc(2026, 5, 9, 12),
    temperatureCelsius: 18.5,
    apparentTemperatureCelsius: 17.2,
    relativeHumidityPercent: 62,
    windSpeedKmh: 12.3,
    windDirectionDegrees: 270,
    precipitationMm: 0.0,
    weatherCode: WeatherCode.partlyCloudy,
    isDay: true,
  );

  final dailyDay = DailyForecast(
    date: DateTime.utc(2026, 5, 9),
    weatherCode: WeatherCode.rainHeavy,
    temperatureMinCelsius: 10.5,
    temperatureMaxCelsius: 20.0,
    precipitationSumMm: 4.2,
    precipitationProbabilityMaxPercent: 70.0,
    windSpeedMaxKmh: 25.0,
    uvIndexMax: 4.0,
    sunrise: DateTime.utc(2026, 5, 9, 6, 30),
    sunset: DateTime.utc(2026, 5, 9, 21),
  );

  final forecast = WeatherForecast(
    city: toulouse,
    current: current,
    daily: <DailyForecast>[dailyDay],
    fetchedAt: DateTime.utc(2026, 5, 9, 12),
  );

  group('City.toJson / fromJson', () {
    test('round-trips a fully-populated city', () {
      final json = jsonEncode(toulouse);
      final decoded = City.fromJson(jsonDecode(json) as Map<String, dynamic>);
      expect(decoded, toulouse);
    });

    test('round-trips a city with all optional fields absent', () {
      const minimal = City(
        id: 1,
        name: 'A',
        latitude: 1,
        longitude: 2,
        country: 'France',
        countryCode: 'FR',
      );
      final encoded = jsonEncode(minimal);
      // Optional null fields should not appear in output.
      expect(jsonDecode(encoded), isNot(contains('admin1')));
      expect(jsonDecode(encoded), isNot(contains('timezone')));
      final decoded = City.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded, minimal);
    });

    test('throws FormatException on missing required fields', () {
      expect(
        () => City.fromJson(<String, dynamic>{'id': 1}),
        throwsFormatException,
      );
    });
  });

  group('CurrentWeather.toJson / fromJson', () {
    test('round-trips', () {
      final json = jsonEncode(current);
      final decoded = CurrentWeather.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(decoded, current);
    });

    test('encodes WeatherCode as its integer code', () {
      final encoded = jsonDecode(jsonEncode(current)) as Map<String, dynamic>;
      expect(encoded['weatherCode'], WeatherCode.partlyCloudy.code);
    });

    test('throws FormatException on a non-string observedAt', () {
      expect(
        () => CurrentWeather.fromJson(<String, dynamic>{
          'observedAt': 1234567890,
          'weatherCode': 0,
          'isDay': true,
        }),
        throwsFormatException,
      );
    });
  });

  group('DailyForecast.toJson / fromJson', () {
    test('round-trips', () {
      final json = jsonEncode(dailyDay);
      final decoded = DailyForecast.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(decoded, dailyDay);
    });
  });

  group('WeatherForecast.toJson / fromJson', () {
    test('round-trips a complete forecast', () {
      final json = jsonEncode(forecast);
      final decoded = WeatherForecast.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(decoded, forecast);
    });

    test('preserves the daily series order across the round-trip', () {
      final multiDay = WeatherForecast(
        city: toulouse,
        current: current,
        daily: <DailyForecast>[
          dailyDay,
          DailyForecast(
            date: DateTime.utc(2026, 5, 10),
            weatherCode: WeatherCode.clearSky,
            temperatureMinCelsius: 11,
            temperatureMaxCelsius: 22,
            precipitationSumMm: 0,
            precipitationProbabilityMaxPercent: 5,
            windSpeedMaxKmh: 8,
            uvIndexMax: 7,
            sunrise: DateTime.utc(2026, 5, 10, 6, 29),
            sunset: DateTime.utc(2026, 5, 10, 21, 1),
          ),
        ],
        fetchedAt: DateTime.utc(2026, 5, 9, 12),
      );
      final json = jsonEncode(multiDay);
      final decoded = WeatherForecast.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(decoded.daily, multiDay.daily);
      expect(decoded.daily[0].date, DateTime.utc(2026, 5, 9));
      expect(decoded.daily[1].date, DateTime.utc(2026, 5, 10));
    });

    test('throws FormatException on missing nested object', () {
      expect(
        () => WeatherForecast.fromJson(<String, dynamic>{
          'city': toulouse.toJson(),
          'current': current.toJson(),
          // missing 'daily' and 'fetchedAt'
        }),
        throwsFormatException,
      );
    });
  });
}
