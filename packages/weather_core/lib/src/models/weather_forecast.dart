// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

import 'city.dart';
import 'current_weather.dart';
import 'daily_forecast.dart';
import 'weather_code.dart';

/// A weather forecast for a single [City] containing the current observation
/// and a series of [DailyForecast]s.
///
/// This is the top-level domain object returned by the service layer.
@immutable
class WeatherForecast {
  const WeatherForecast({
    required this.city,
    required this.current,
    required this.daily,
    required this.fetchedAt,
  });

  /// Construct from an Open-Meteo forecast response.
  ///
  /// Open-Meteo returns daily values as parallel arrays (a column-oriented
  /// layout): `time[]`, `weather_code[]`, `temperature_2m_min[]`, etc. We
  /// transpose them into a list of [DailyForecast] row objects, which is
  /// the natural shape for application code.
  factory WeatherForecast.fromOpenMeteoJson({
    required City city,
    required Map<String, dynamic> json,
    required DateTime fetchedAt,
  }) {
    final currentJson = json['current'];
    if (currentJson is! Map<String, dynamic>) {
      throw const FormatException('Missing "current" block in forecast');
    }
    final dailyJson = json['daily'];
    if (dailyJson is! Map<String, dynamic>) {
      throw const FormatException('Missing "daily" block in forecast');
    }

    final daily = _parseDaily(dailyJson);

    return WeatherForecast(
      city: city,
      current: CurrentWeather.fromOpenMeteoJson(currentJson),
      daily: List<DailyForecast>.unmodifiable(daily),
      fetchedAt: fetchedAt,
    );
  }

  /// Resolved location.
  final City city;

  /// Conditions at observation time.
  final CurrentWeather current;

  /// Daily forecast series. Length is determined by the request's
  /// `forecast_days` parameter (1–16 for Open-Meteo).
  final List<DailyForecast> daily;

  /// Wall-clock time at which this forecast was retrieved. Not the upstream's
  /// generation time — caller-side, used for cache freshness decisions.
  final DateTime fetchedAt;

  /// Length of the daily forecast series. Used as a low-cardinality bucketed
  /// metric attribute (the request's `forecast_days` parameter) — direct value
  /// is fine since it ranges only 1–16.
  int get forecastHorizonDays => daily.length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WeatherForecast &&
          runtimeType == other.runtimeType &&
          city == other.city &&
          current == other.current &&
          _listEquals(daily, other.daily) &&
          fetchedAt == other.fetchedAt;

  @override
  int get hashCode =>
      Object.hash(city, current, Object.hashAll(daily), fetchedAt);

  @override
  String toString() =>
      'WeatherForecast(${city.name}, $forecastHorizonDays days, '
      'fetched ${fetchedAt.toIso8601String()})';

  /// Round-trip JSON serializer for service-to-service traffic. Recursively
  /// serializes the embedded [City], [CurrentWeather], and [DailyForecast]
  /// instances. This is the wire format `services/weather_api` returns to
  /// callers and `services/cache_service` exchanges with `weather_api`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'city': city.toJson(),
    'current': current.toJson(),
    'daily': daily.map((d) => d.toJson()).toList(growable: false),
    'fetchedAt': fetchedAt.toIso8601String(),
  };

  /// Inverse of [toJson]. Throws [FormatException] on bad input.
  factory WeatherForecast.fromJson(Map<String, dynamic> json) {
    final city = json['city'];
    final current = json['current'];
    final daily = json['daily'];
    final fetchedAt = json['fetchedAt'];
    if (city is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or non-object "city" in forecast JSON',
      );
    }
    if (current is! Map<String, dynamic>) {
      throw const FormatException(
        'Missing or non-object "current" in forecast JSON',
      );
    }
    if (daily is! List) {
      throw const FormatException(
        'Missing or non-array "daily" in forecast JSON',
      );
    }
    if (fetchedAt is! String) {
      throw const FormatException(
        'Missing or non-string "fetchedAt" in forecast JSON',
      );
    }
    return WeatherForecast(
      city: City.fromJson(city),
      current: CurrentWeather.fromJson(current),
      daily: daily
          .map((e) => DailyForecast.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
      fetchedAt: DateTime.parse(fetchedAt),
    );
  }
}

List<DailyForecast> _parseDaily(Map<String, dynamic> daily) {
  final time = _requireList<String>(daily, 'time');
  final weatherCode = _requireList<num>(daily, 'weather_code');
  final tempMin = _requireList<num>(daily, 'temperature_2m_min');
  final tempMax = _requireList<num>(daily, 'temperature_2m_max');
  final precipSum = _requireList<num>(daily, 'precipitation_sum');
  final precipProb = _optionalList<num>(daily, 'precipitation_probability_max');
  final windMax = _requireList<num>(daily, 'wind_speed_10m_max');
  final uvMax = _optionalList<num>(daily, 'uv_index_max');
  final sunrise = _requireList<String>(daily, 'sunrise');
  final sunset = _requireList<String>(daily, 'sunset');

  final length = time.length;
  if (weatherCode.length != length ||
      tempMin.length != length ||
      tempMax.length != length ||
      precipSum.length != length ||
      windMax.length != length ||
      sunrise.length != length ||
      sunset.length != length) {
    throw const FormatException(
      'Daily forecast arrays have inconsistent lengths',
    );
  }

  return List<DailyForecast>.generate(length, (i) {
    return DailyForecast(
      date: DateTime.parse(time[i]),
      weatherCode: WeatherCode.fromCode(weatherCode[i].toInt()),
      temperatureMinCelsius: tempMin[i].toDouble(),
      temperatureMaxCelsius: tempMax[i].toDouble(),
      precipitationSumMm: precipSum[i].toDouble(),
      precipitationProbabilityMaxPercent: (i < (precipProb?.length ?? 0))
          ? precipProb![i].toDouble()
          : 0,
      windSpeedMaxKmh: windMax[i].toDouble(),
      uvIndexMax: (i < (uvMax?.length ?? 0)) ? uvMax![i].toDouble() : 0,
      sunrise: DateTime.parse(sunrise[i]),
      sunset: DateTime.parse(sunset[i]),
    );
  });
}

List<T> _requireList<T>(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! List) {
    throw FormatException('Missing or non-list "$key" in daily block');
  }
  return value.cast<T>();
}

List<T>? _optionalList<T>(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! List) return null;
  return value.cast<T>();
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
