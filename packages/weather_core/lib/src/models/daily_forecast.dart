// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

import 'weather_code.dart';

/// Aggregated weather for a single day.
@immutable
class DailyForecast {
  const DailyForecast({
    required this.date,
    required this.weatherCode,
    required this.temperatureMinCelsius,
    required this.temperatureMaxCelsius,
    required this.precipitationSumMm,
    required this.precipitationProbabilityMaxPercent,
    required this.windSpeedMaxKmh,
    required this.uvIndexMax,
    required this.sunrise,
    required this.sunset,
  });

  /// Calendar date in the forecast's timezone.
  final DateTime date;

  final WeatherCode weatherCode;
  final double temperatureMinCelsius;
  final double temperatureMaxCelsius;
  final double precipitationSumMm;
  final double precipitationProbabilityMaxPercent;
  final double windSpeedMaxKmh;
  final double uvIndexMax;
  final DateTime sunrise;
  final DateTime sunset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DailyForecast &&
          runtimeType == other.runtimeType &&
          date == other.date &&
          weatherCode == other.weatherCode &&
          temperatureMinCelsius == other.temperatureMinCelsius &&
          temperatureMaxCelsius == other.temperatureMaxCelsius &&
          precipitationSumMm == other.precipitationSumMm &&
          precipitationProbabilityMaxPercent ==
              other.precipitationProbabilityMaxPercent &&
          windSpeedMaxKmh == other.windSpeedMaxKmh &&
          uvIndexMax == other.uvIndexMax &&
          sunrise == other.sunrise &&
          sunset == other.sunset;

  @override
  int get hashCode => Object.hash(
    date,
    weatherCode,
    temperatureMinCelsius,
    temperatureMaxCelsius,
    precipitationSumMm,
    precipitationProbabilityMaxPercent,
    windSpeedMaxKmh,
    uvIndexMax,
    sunrise,
    sunset,
  );

  @override
  String toString() =>
      'DailyForecast(${date.toIso8601String().substring(0, 10)}, '
      '${temperatureMinCelsius.toStringAsFixed(1)}-'
      '${temperatureMaxCelsius.toStringAsFixed(1)}°C, '
      '${weatherCode.description})';

  /// Round-trip JSON serializer for service-to-service traffic. See [City]
  /// for the convention. Dates use ISO 8601; [WeatherCode] is encoded as
  /// its underlying integer code.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'date': date.toIso8601String(),
    'weatherCode': weatherCode.code,
    'temperatureMinCelsius': temperatureMinCelsius,
    'temperatureMaxCelsius': temperatureMaxCelsius,
    'precipitationSumMm': precipitationSumMm,
    'precipitationProbabilityMaxPercent': precipitationProbabilityMaxPercent,
    'windSpeedMaxKmh': windSpeedMaxKmh,
    'uvIndexMax': uvIndexMax,
    'sunrise': sunrise.toIso8601String(),
    'sunset': sunset.toIso8601String(),
  };

  /// Inverse of [toJson]. Throws [FormatException] on bad input.
  factory DailyForecast.fromJson(Map<String, dynamic> json) {
    final date = json['date'];
    final code = json['weatherCode'];
    final sunrise = json['sunrise'];
    final sunset = json['sunset'];
    if (date is! String) {
      throw const FormatException(
        'Missing or non-string "date" in daily forecast JSON',
      );
    }
    if (code is! int) {
      throw const FormatException(
        'Missing or non-integer "weatherCode" in daily forecast JSON',
      );
    }
    if (sunrise is! String) {
      throw const FormatException(
        'Missing or non-string "sunrise" in daily forecast JSON',
      );
    }
    if (sunset is! String) {
      throw const FormatException(
        'Missing or non-string "sunset" in daily forecast JSON',
      );
    }
    return DailyForecast(
      date: DateTime.parse(date),
      weatherCode: WeatherCode.fromCode(code),
      temperatureMinCelsius: _requireDoubleD(json, 'temperatureMinCelsius'),
      temperatureMaxCelsius: _requireDoubleD(json, 'temperatureMaxCelsius'),
      precipitationSumMm: _requireDoubleD(json, 'precipitationSumMm'),
      precipitationProbabilityMaxPercent: _requireDoubleD(
        json,
        'precipitationProbabilityMaxPercent',
      ),
      windSpeedMaxKmh: _requireDoubleD(json, 'windSpeedMaxKmh'),
      uvIndexMax: _requireDoubleD(json, 'uvIndexMax'),
      sunrise: DateTime.parse(sunrise),
      sunset: DateTime.parse(sunset),
    );
  }
}

double _requireDoubleD(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException(
      'Missing or non-numeric "$key" in daily forecast JSON',
    );
  }
  return value.toDouble();
}
