// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

void main() {
  group('WeatherCode.fromCode', () {
    test('resolves known codes to the right enum value', () {
      expect(WeatherCode.fromCode(0), WeatherCode.clearSky);
      expect(WeatherCode.fromCode(2), WeatherCode.partlyCloudy);
      expect(WeatherCode.fromCode(45), WeatherCode.fog);
      expect(WeatherCode.fromCode(63), WeatherCode.rainModerate);
      expect(WeatherCode.fromCode(95), WeatherCode.thunderstorm);
      expect(WeatherCode.fromCode(99), WeatherCode.thunderstormHeavyHail);
    });

    test('returns unknown for codes the API may add later', () {
      expect(WeatherCode.fromCode(7), WeatherCode.unknown);
      expect(WeatherCode.fromCode(100), WeatherCode.unknown);
      expect(WeatherCode.fromCode(-5), WeatherCode.unknown);
    });

    test('every value has a non-empty description', () {
      for (final code in WeatherCode.values) {
        expect(
          code.description,
          isNotEmpty,
          reason: '$code missing description',
        );
      }
    });
  });

  group('WeatherCode.severity', () {
    test('clear/cloudy codes are calm', () {
      expect(WeatherCode.clearSky.severity, WeatherSeverity.calm);
      expect(WeatherCode.mainlyClear.severity, WeatherSeverity.calm);
      expect(WeatherCode.partlyCloudy.severity, WeatherSeverity.calm);
      expect(WeatherCode.overcast.severity, WeatherSeverity.calm);
    });

    test('thunderstorm and heavy precipitation are severe', () {
      expect(WeatherCode.thunderstorm.severity, WeatherSeverity.severe);
      expect(
        WeatherCode.thunderstormHeavyHail.severity,
        WeatherSeverity.severe,
      );
      expect(WeatherCode.rainHeavy.severity, WeatherSeverity.severe);
      expect(WeatherCode.snowHeavy.severity, WeatherSeverity.severe);
    });

    test('moderate conditions are notable', () {
      expect(WeatherCode.fog.severity, WeatherSeverity.notable);
      expect(WeatherCode.rainModerate.severity, WeatherSeverity.notable);
      expect(WeatherCode.snowModerate.severity, WeatherSeverity.notable);
    });

    test('unknown bucketed as notable so dashboards still see it', () {
      expect(WeatherCode.unknown.severity, WeatherSeverity.notable);
    });
  });
}
