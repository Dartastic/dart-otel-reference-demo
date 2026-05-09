// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:weather_core/weather_core.dart';

/// Hand-rolled fake — same shape as the FakeWeatherProvider in
/// weather_core's tests. Reproduced here rather than imported from
/// weather_core's test/ directory because Dart packages do not share
/// test-only source.
class FakeWeatherProvider implements WeatherProvider {
  GeocodeResult Function(String query, int maxResults)? geocodeImpl;
  WeatherForecast Function(City city, int forecastDays)? forecastImpl;

  Object? geocodeError;
  Object? forecastError;

  @override
  String get name => 'fake';

  @override
  Future<GeocodeResult> geocode(String query, {int maxResults = 5}) async {
    if (geocodeError != null) throw geocodeError!;
    final fn = geocodeImpl;
    if (fn == null) {
      throw StateError('geocodeImpl not set on FakeWeatherProvider');
    }
    return fn(query, maxResults);
  }

  @override
  Future<WeatherForecast> getForecast({
    required City city,
    required int forecastDays,
  }) async {
    if (forecastError != null) throw forecastError!;
    final fn = forecastImpl;
    if (fn == null) {
      throw StateError('forecastImpl not set on FakeWeatherProvider');
    }
    return fn(city, forecastDays);
  }
}
