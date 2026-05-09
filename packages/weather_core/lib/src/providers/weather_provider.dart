// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import '../models/city.dart';
import '../models/geocode_result.dart';
import '../models/weather_forecast.dart';
import 'weather_provider_exception.dart';

/// Abstraction over a weather data source.
///
/// Concrete implementations call out to upstream APIs (e.g. Open-Meteo).
/// Implementations are expected to:
///
/// 1. Emit a span around each operation using `OTel.tracer()`.
/// 2. Set semantic-convention attributes on the span (`http.request.method`,
///    `server.address`, `http.response.status_code`) and provider-specific
///    attributes (`weather.provider`, `weather.operation`).
/// 3. Record exceptions via `span.recordException(...)` and set the span
///    status to `error` on failure.
/// 4. Translate upstream failures to [WeatherProviderException] with an
///    appropriate [WeatherProviderErrorKind]. Callers must not need to know
///    the upstream's error model.
///
/// Implementations are **not** responsible for retries, caching, or fallback
/// — those concerns belong higher in the stack. A provider call is a single
/// upstream request and either succeeds or throws.
abstract interface class WeatherProvider {
  /// A short, stable identifier for the provider — e.g. `"open-meteo"`.
  /// Used as a low-cardinality metric attribute; bounded enum-equivalent.
  String get name;

  /// Resolves a free-text city query to zero or more matching [City]s.
  ///
  /// [maxResults] caps the number of matches returned. Implementations
  /// SHOULD honor the cap upstream where the API supports it.
  ///
  /// Throws [WeatherProviderException] on any failure (network, parse,
  /// upstream error). Returns a [GeocodeResult] with `isEmpty == true`
  /// when the upstream succeeds but reports no matches — that case is
  /// not exceptional.
  Future<GeocodeResult> geocode(String query, {int maxResults = 5});

  /// Retrieves a forecast for [city] covering [forecastDays] days.
  ///
  /// [forecastDays] is bounded by the upstream — Open-Meteo allows 1 to 16.
  /// Implementations MUST validate the bound and raise
  /// [WeatherProviderException] with [WeatherProviderErrorKind.badRequest]
  /// for out-of-range values rather than passing them to the upstream.
  ///
  /// Throws [WeatherProviderException] on any failure.
  Future<WeatherForecast> getForecast({
    required City city,
    required int forecastDays,
  });
}
