// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:weather_core/weather_core.dart';

/// Hand-rolled fake with call counters. The counters are what let
/// cache_service tests assert "a cached lookup did NOT call upstream"
/// without dragging in a mocking framework.
class FakeWeatherProvider implements WeatherProvider {
  GeocodeResult Function(String query, int maxResults)? geocodeImpl;
  WeatherForecast Function(City city, int forecastDays)? forecastImpl;

  Object? geocodeError;
  Object? forecastError;

  int geocodeCallCount = 0;
  int forecastCallCount = 0;

  @override
  String get name => 'fake';

  @override
  Future<GeocodeResult> geocode(String query, {int maxResults = 5}) async {
    geocodeCallCount++;
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
    forecastCallCount++;
    if (forecastError != null) throw forecastError!;
    final fn = forecastImpl;
    if (fn == null) {
      throw StateError('forecastImpl not set on FakeWeatherProvider');
    }
    return fn(city, forecastDays);
  }
}
