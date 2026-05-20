// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:weather_cli/weather_cli.dart';
import 'package:weather_core/weather_core.dart';

void main() {
  // Two-day forecast for Boston on 9–10 May 2026. Pinned values so
  // text-format assertions are deterministic.
  const boston = City(
    id: 4930956,
    name: 'Boston',
    latitude: 42.35843,
    longitude: -71.05977,
    country: 'United States',
    countryCode: 'US',
  );

  final current = CurrentWeather(
    observedAt: DateTime.utc(2026, 5, 9, 12),
    temperatureCelsius: 18.5,
    apparentTemperatureCelsius: 17.2,
    relativeHumidityPercent: 62,
    windSpeedKmh: 12.0,
    windDirectionDegrees: 270,
    precipitationMm: 0.0,
    weatherCode: WeatherCode.partlyCloudy,
    isDay: true,
  );

  final daily = <DailyForecast>[
    DailyForecast(
      date: DateTime.utc(2026, 5, 9),
      weatherCode: WeatherCode.partlyCloudy,
      temperatureMinCelsius: 10.5,
      temperatureMaxCelsius: 20.0,
      precipitationSumMm: 0,
      precipitationProbabilityMaxPercent: 10,
      windSpeedMaxKmh: 15,
      uvIndexMax: 6,
      sunrise: DateTime.utc(2026, 5, 9, 6, 30),
      sunset: DateTime.utc(2026, 5, 9, 21),
    ),
    DailyForecast(
      date: DateTime.utc(2026, 5, 10),
      weatherCode: WeatherCode.rainHeavy,
      temperatureMinCelsius: 11.0,
      temperatureMaxCelsius: 22.0,
      precipitationSumMm: 4.2,
      precipitationProbabilityMaxPercent: 70,
      windSpeedMaxKmh: 25,
      uvIndexMax: 4,
      sunrise: DateTime.utc(2026, 5, 10, 6, 29),
      sunset: DateTime.utc(2026, 5, 10, 21, 1),
    ),
  ];

  final forecast = WeatherForecast(
    city: boston,
    current: current,
    daily: daily,
    fetchedAt: DateTime.utc(2026, 5, 9, 12),
  );

  group('renderText', () {
    test('starts with the city, country, and decimal coordinates', () {
      final lines = renderText(forecast).split('\n');
      expect(lines.first, 'Boston, United States (42.36°N, 71.06°W)');
    });

    test('renders southern / western coordinates with the right cardinals', () {
      const sydney = City(
        id: 1,
        name: 'Sydney',
        latitude: -33.87,
        longitude: 151.21,
        country: 'Australia',
        countryCode: 'AU',
      );
      const losAngeles = City(
        id: 2,
        name: 'Los Angeles',
        latitude: 34.05,
        longitude: -118.24,
        country: 'United States',
        countryCode: 'US',
      );
      String firstLine(City c) => renderText(
        WeatherForecast(
          city: c,
          current: current,
          daily: const <DailyForecast>[],
          fetchedAt: DateTime.utc(2026, 5, 9, 12),
        ),
      ).split('\n').first;
      // Magnitude is shown without a sign, with the cardinal as the
      // suffix — no double-negatives even for negative coordinates.
      expect(firstLine(sydney), contains('33.87°S'));
      expect(firstLine(sydney), contains('151.21°E'));
      expect(firstLine(losAngeles), contains('34.05°N'));
      expect(firstLine(losAngeles), contains('118.24°W'));
    });

    test('current line includes temperature, feels-like, condition, wind', () {
      final text = renderText(forecast);
      expect(text, contains('18.5°C'));
      expect(text, contains('feels like 17.2°C'));
      expect(text, contains('wind 12 km/h'));
    });

    test('one daily line per forecast day', () {
      // Daily lines start with two spaces and a weekday abbreviation —
      // count them rather than splitting on substrings to avoid false
      // positives on dates that appear in other lines.
      final text = renderText(forecast);
      final dailyLines = text
          .split('\n')
          .where(
            (line) =>
                RegExp(r'^  (Mon|Tue|Wed|Thu|Fri|Sat|Sun) ').hasMatch(line),
          )
          .toList();
      expect(dailyLines, hasLength(2));
    });

    test(
      'daily line includes range, weather word, precip pct, precip mm, uv',
      () {
        final text = renderText(forecast);
        // The May 10 row in our fixture: 11.0–22.0°C, rain heavy,
        // 70% / 4.2 mm, uv 4.0.
        final mayTen = text
            .split('\n')
            .firstWhere((l) => l.contains('Sun May 10'));
        expect(mayTen, contains('11.0–22.0°C'));
        expect(mayTen.toLowerCase(), contains('rain'));
        expect(mayTen, contains('70%'));
        expect(mayTen, contains('4.2 mm'));
        expect(mayTen, contains('uv 4.0'));
      },
    );

    test('footer carries the fetch timestamp', () {
      final text = renderText(forecast);
      expect(text, contains('Fetched 2026-05-09T12:00:00.000Z'));
    });
  });

  group('renderJson', () {
    test('round-trips through the v1 wire format', () {
      final encoded = renderJson(forecast);
      final decoded = WeatherForecast.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded, forecast);
    });

    test('is pretty-printed with two-space indentation', () {
      final encoded = renderJson(forecast);
      // First nested key sits two spaces in.
      expect(encoded, contains('\n  "city":'));
    });
  });
}
