// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

import 'weather_code.dart';

/// Current weather observation at a specific location and time.
@immutable
class CurrentWeather {
  const CurrentWeather({
    required this.observedAt,
    required this.temperatureCelsius,
    required this.apparentTemperatureCelsius,
    required this.relativeHumidityPercent,
    required this.windSpeedKmh,
    required this.windDirectionDegrees,
    required this.precipitationMm,
    required this.weatherCode,
    required this.isDay,
  });

  /// Construct from the `current` block of an Open-Meteo forecast response.
  ///
  /// Throws [FormatException] on contract violations.
  factory CurrentWeather.fromOpenMeteoJson(Map<String, dynamic> json) {
    final time = json['time'];
    final temperature = json['temperature_2m'];
    final apparent = json['apparent_temperature'];
    final humidity = json['relative_humidity_2m'];
    final wind = json['wind_speed_10m'];
    final windDir = json['wind_direction_10m'];
    final precipitation = json['precipitation'];
    final code = json['weather_code'];
    final isDay = json['is_day'];

    if (time is! String) {
      throw const FormatException('Missing "time" in current weather');
    }
    if (temperature is! num) {
      throw const FormatException('Missing or non-numeric "temperature_2m"');
    }
    if (code is! int) {
      throw const FormatException('Missing or non-integer "weather_code"');
    }

    return CurrentWeather(
      observedAt: DateTime.parse(time),
      temperatureCelsius: temperature.toDouble(),
      apparentTemperatureCelsius: apparent is num
          ? apparent.toDouble()
          : temperature.toDouble(),
      relativeHumidityPercent: humidity is num ? humidity.toDouble() : 0,
      windSpeedKmh: wind is num ? wind.toDouble() : 0,
      windDirectionDegrees: windDir is num ? windDir.toDouble() : 0,
      precipitationMm: precipitation is num ? precipitation.toDouble() : 0,
      weatherCode: WeatherCode.fromCode(code),
      isDay: switch (isDay) {
        final int v => v == 1,
        final bool v => v,
        _ => true,
      },
    );
  }

  /// Time of the observation in UTC unless the request specified a timezone.
  final DateTime observedAt;

  final double temperatureCelsius;
  final double apparentTemperatureCelsius;
  final double relativeHumidityPercent;
  final double windSpeedKmh;
  final double windDirectionDegrees;
  final double precipitationMm;
  final WeatherCode weatherCode;
  final bool isDay;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CurrentWeather &&
          runtimeType == other.runtimeType &&
          observedAt == other.observedAt &&
          temperatureCelsius == other.temperatureCelsius &&
          apparentTemperatureCelsius == other.apparentTemperatureCelsius &&
          relativeHumidityPercent == other.relativeHumidityPercent &&
          windSpeedKmh == other.windSpeedKmh &&
          windDirectionDegrees == other.windDirectionDegrees &&
          precipitationMm == other.precipitationMm &&
          weatherCode == other.weatherCode &&
          isDay == other.isDay;

  @override
  int get hashCode => Object.hash(
    observedAt,
    temperatureCelsius,
    apparentTemperatureCelsius,
    relativeHumidityPercent,
    windSpeedKmh,
    windDirectionDegrees,
    precipitationMm,
    weatherCode,
    isDay,
  );

  @override
  String toString() =>
      'CurrentWeather($temperatureCelsius°C, ${weatherCode.description}, '
      '${isDay ? "day" : "night"} @ $observedAt)';

  /// Round-trip JSON serializer for service-to-service traffic. See [City]
  /// for the convention. [WeatherCode] is encoded as its underlying
  /// integer code; [observedAt] is encoded as ISO 8601.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'observedAt': observedAt.toIso8601String(),
    'temperatureCelsius': temperatureCelsius,
    'apparentTemperatureCelsius': apparentTemperatureCelsius,
    'relativeHumidityPercent': relativeHumidityPercent,
    'windSpeedKmh': windSpeedKmh,
    'windDirectionDegrees': windDirectionDegrees,
    'precipitationMm': precipitationMm,
    'weatherCode': weatherCode.code,
    'isDay': isDay,
  };

  /// Inverse of [toJson]. Throws [FormatException] on bad input.
  factory CurrentWeather.fromJson(Map<String, dynamic> json) {
    final observedAt = json['observedAt'];
    final code = json['weatherCode'];
    final isDay = json['isDay'];
    if (observedAt is! String) {
      throw const FormatException(
        'Missing or non-string "observedAt" in current weather JSON',
      );
    }
    if (code is! int) {
      throw const FormatException(
        'Missing or non-integer "weatherCode" in current weather JSON',
      );
    }
    if (isDay is! bool) {
      throw const FormatException(
        'Missing or non-boolean "isDay" in current weather JSON',
      );
    }
    return CurrentWeather(
      observedAt: DateTime.parse(observedAt),
      temperatureCelsius: _requireDouble(json, 'temperatureCelsius'),
      apparentTemperatureCelsius: _requireDouble(
        json,
        'apparentTemperatureCelsius',
      ),
      relativeHumidityPercent: _requireDouble(json, 'relativeHumidityPercent'),
      windSpeedKmh: _requireDouble(json, 'windSpeedKmh'),
      windDirectionDegrees: _requireDouble(json, 'windDirectionDegrees'),
      precipitationMm: _requireDouble(json, 'precipitationMm'),
      weatherCode: WeatherCode.fromCode(code),
      isDay: isDay,
    );
  }
}

double _requireDouble(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) {
    throw FormatException(
      'Missing or non-numeric "$key" in current weather JSON',
    );
  }
  return value.toDouble();
}
