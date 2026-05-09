// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

void main() {
  const toulouse = City(
    id: 1,
    name: 'Toulouse',
    latitude: 43.6,
    longitude: 1.44,
    country: 'France',
    countryCode: 'FR',
  );

  Map<String, dynamic> validForecastJson() => <String, dynamic>{
    'current': <String, dynamic>{
      'time': '2026-05-09T12:00',
      'temperature_2m': 18.5,
      'apparent_temperature': 17.2,
      'relative_humidity_2m': 62,
      'wind_speed_10m': 12.3,
      'wind_direction_10m': 270,
      'precipitation': 0.0,
      'weather_code': 2,
      'is_day': 1,
    },
    'daily': <String, dynamic>{
      'time': <String>['2026-05-09', '2026-05-10', '2026-05-11'],
      'weather_code': <int>[2, 3, 61],
      'temperature_2m_min': <double>[10.5, 11.0, 12.5],
      'temperature_2m_max': <double>[20.0, 22.0, 18.5],
      'precipitation_sum': <double>[0.0, 0.5, 4.2],
      'precipitation_probability_max': <int>[10, 30, 70],
      'wind_speed_10m_max': <double>[15.0, 18.0, 25.0],
      'uv_index_max': <double>[6.0, 7.0, 4.0],
      'sunrise': <String>[
        '2026-05-09T06:30',
        '2026-05-10T06:29',
        '2026-05-11T06:27',
      ],
      'sunset': <String>[
        '2026-05-09T21:00',
        '2026-05-10T21:01',
        '2026-05-11T21:02',
      ],
    },
  };

  group('WeatherForecast.fromOpenMeteoJson', () {
    test('transposes daily column arrays into row objects', () {
      final fetchedAt = DateTime.utc(2026, 5, 9, 12);
      final forecast = WeatherForecast.fromOpenMeteoJson(
        city: toulouse,
        json: validForecastJson(),
        fetchedAt: fetchedAt,
      );

      expect(forecast.daily, hasLength(3));
      expect(forecast.forecastHorizonDays, 3);
      expect(forecast.fetchedAt, fetchedAt);

      final today = forecast.daily[0];
      expect(today.weatherCode, WeatherCode.partlyCloudy);
      expect(today.temperatureMinCelsius, 10.5);
      expect(today.temperatureMaxCelsius, 20.0);

      final dayThree = forecast.daily[2];
      expect(dayThree.weatherCode, WeatherCode.rainSlight);
      expect(dayThree.precipitationSumMm, 4.2);
      expect(dayThree.precipitationProbabilityMaxPercent, 70.0);
    });

    test('parses current observation', () {
      final forecast = WeatherForecast.fromOpenMeteoJson(
        city: toulouse,
        json: validForecastJson(),
        fetchedAt: DateTime.utc(2026, 5, 9, 12),
      );
      expect(forecast.current.temperatureCelsius, 18.5);
      expect(forecast.current.weatherCode, WeatherCode.partlyCloudy);
      expect(forecast.current.isDay, true);
    });

    test(
      'throws FormatException when daily arrays have inconsistent lengths',
      () {
        final json = validForecastJson();
        (json['daily']
            as Map<String, dynamic>)['temperature_2m_min'] = <double>[
          10.5,
          11.0,
          // missing third entry
        ];
        expect(
          () => WeatherForecast.fromOpenMeteoJson(
            city: toulouse,
            json: json,
            fetchedAt: DateTime.utc(2026, 5, 9, 12),
          ),
          throwsFormatException,
        );
      },
    );

    test('throws FormatException when "current" block is missing', () {
      final json = validForecastJson()..remove('current');
      expect(
        () => WeatherForecast.fromOpenMeteoJson(
          city: toulouse,
          json: json,
          fetchedAt: DateTime.utc(2026, 5, 9, 12),
        ),
        throwsFormatException,
      );
    });

    test('tolerates missing optional precipitation_probability_max', () {
      final json = validForecastJson();
      (json['daily'] as Map<String, dynamic>).remove(
        'precipitation_probability_max',
      );
      final forecast = WeatherForecast.fromOpenMeteoJson(
        city: toulouse,
        json: json,
        fetchedAt: DateTime.utc(2026, 5, 9, 12),
      );
      expect(forecast.daily.first.precipitationProbabilityMaxPercent, 0.0);
    });
  });

  group('CurrentWeather.fromOpenMeteoJson', () {
    test('handles is_day as int (1 / 0)', () {
      final dayJson = <String, dynamic>{
        'time': '2026-05-09T12:00',
        'temperature_2m': 18.5,
        'weather_code': 0,
        'is_day': 1,
      };
      expect(CurrentWeather.fromOpenMeteoJson(dayJson).isDay, true);

      final nightJson = Map<String, dynamic>.from(dayJson)..['is_day'] = 0;
      expect(CurrentWeather.fromOpenMeteoJson(nightJson).isDay, false);
    });

    test('handles is_day as bool', () {
      final json = <String, dynamic>{
        'time': '2026-05-09T12:00',
        'temperature_2m': 18.5,
        'weather_code': 0,
        'is_day': true,
      };
      expect(CurrentWeather.fromOpenMeteoJson(json).isDay, true);
    });

    test('throws FormatException on missing temperature_2m', () {
      final bad = <String, dynamic>{
        'time': '2026-05-09T12:00',
        'weather_code': 0,
      };
      expect(
        () => CurrentWeather.fromOpenMeteoJson(bad),
        throwsFormatException,
      );
    });
  });
}
