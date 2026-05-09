// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';

// SDK re-exports MOST of the API surface (Tracer, Span, Context,
// Attributes, semantic enums) via a `show` clause. The
// instrument-interface types `APICounter` and `APIHistogram` are NOT
// in that show clause — `meter.createCounter`/`createHistogram`
// return them as their statically-typed return value, so we import
// them from the API package directly to name them in field
// declarations and getters.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    show APICounter, APIHistogram;
import 'package:logging/logging.dart';

import '../instrumentation/weather_semantics.dart';
import '../models/weather_forecast.dart';
import '../providers/weather_provider.dart';
import '../providers/weather_provider_exception.dart';

/// Top-level orchestration for weather lookups.
///
/// Composes the two operations a `WeatherProvider` exposes (geocoding and
/// forecast retrieval) into the use cases the application needs. Emits a
/// service-layer span wrapping each request and aggregate metrics that
/// support the standard RED panels (Rate, Errors, Duration).
///
/// Caching is **not** the responsibility of this class. In the demo the
/// cache is a separate service; in single-process deployments the cache
/// can be layered around an instance via the decorator pattern.
class WeatherService {
  WeatherService({required WeatherProvider provider})
    : _provider = provider,
      _instruments = _Instruments.instance;

  final WeatherProvider _provider;
  final _Instruments _instruments;

  static final Logger _log = Logger('weather_core.WeatherService');

  /// Resolves [cityName] and returns a forecast.
  ///
  /// Throws `WeatherProviderException`:
  /// - kind `notFound` if no city matches `cityName`
  /// - any other kind on upstream failure
  Future<WeatherForecast> getForecast({
    required String cityName,
    required int forecastDays,
  }) async {
    final stopwatch = Stopwatch()..start();
    final tracer = OTel.tracer();

    final span = tracer.startSpan(
      'WeatherService.getForecast',
      attributes: OTel.attributesFromMap(<String, Object>{
        WeatherSemantics.operation.key: 'getForecast',
        // Free-text query is high-cardinality — span-only.
        WeatherSemantics.geocodeQuery.key: cityName,
        WeatherSemantics.forecastDays.key: forecastDays,
      }),
    );

    var outcome = 'success';
    String? errorKind;
    String? countryCode;

    try {
      return await tracer.withSpanAsync(span, () async {
        final geocoded = await _provider.geocode(cityName);
        if (geocoded.isEmpty) {
          span.addEvent(
            OTel.spanEventNow(
              'geocode.no_matches',
              OTel.attributesFromMap(<String, Object>{
                WeatherSemantics.geocodeQuery.key: cityName,
              }),
            ),
          );
          throw WeatherProviderException(
            kind: WeatherProviderErrorKind.notFound,
            providerName: _provider.name,
            message: 'No city matched query "$cityName"',
          );
        }

        if (geocoded.isAmbiguous) {
          span.addEvent(
            OTel.spanEventNow(
              'geocode.ambiguous',
              OTel.attributesFromMap(<String, Object>{
                WeatherSemantics.geocodeMatchCount.key: geocoded.matches.length,
              }),
            ),
          );
          _log.fine(
            'Ambiguous geocode for "$cityName" '
            '(${geocoded.matches.length} matches); using first',
          );
        }

        final best = geocoded.best;
        countryCode = best.countryCode;

        // Country code is bounded (~250 values) — safe on metrics. City id
        // and city name are high-cardinality and remain span-only.
        span.addAttributes(
          OTel.attributesFromMap(<String, Object>{
            WeatherSemantics.cityId.key: best.id,
            WeatherSemantics.cityName.key: best.name,
            WeatherSemantics.cityCountryCode.key: best.countryCode,
          }),
        );

        final forecast = await _provider.getForecast(
          city: best,
          forecastDays: forecastDays,
        );

        span.setStatus(SpanStatusCode.Ok);
        return forecast;
      });
    } on WeatherProviderException catch (e, st) {
      outcome = 'error';
      errorKind = e.kind.name;
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(SpanStatusCode.Error, e.message);
      rethrow;
    } catch (e, st) {
      outcome = 'error';
      errorKind = WeatherProviderErrorKind.unknown.name;
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(SpanStatusCode.Error, e.toString());
      rethrow;
    } finally {
      stopwatch.stop();
      span.end();

      // Aggregate metrics for RED panels. Attribute set is bounded:
      //   provider:    {open-meteo, ...}                   ~5 values
      //   operation:   {getForecast, getCurrentWeather}     2 values
      //   outcome:     {success, error}                     2 values
      //   error.kind:  WeatherProviderErrorKind             7 values
      //   country:     ISO 3166-1 alpha-2 or 'unknown'    ~250 values
      // Upper bound on series count: ~35,000 — safe under all backend
      // caps (Cloud Monitoring's per-metric 200k, Prometheus practical).
      // See DESIGN.md "Cardinality discipline."
      final metricAttributes = OTel.attributesFromMap(<String, Object>{
        WeatherSemantics.provider.key: _provider.name,
        WeatherSemantics.operation.key: 'getForecast',
        WeatherSemantics.outcome.key: outcome,
        WeatherSemantics.errorKind.key: ?errorKind,
        WeatherSemantics.cityCountryCode.key: countryCode ?? 'unknown',
      });
      _instruments.requests.add(1, metricAttributes);
      _instruments.duration.record(
        stopwatch.elapsedMilliseconds,
        metricAttributes,
      );
    }
  }
}

/// Lazily initialized singleton holding the service's metric instruments.
///
/// Instruments are held at module scope rather than constructed per service
/// instance because `Meter.createCounter` / `createHistogram` are not free —
/// the SDK enforces uniqueness by name and aggregates values across all
/// references with the same name. The OTel API guidelines call for caching
/// instruments by name, which this pattern provides without forcing every
/// caller to thread a Meter through.
class _Instruments {
  _Instruments._();

  static final _Instruments instance = _Instruments._build();

  factory _Instruments._build() {
    final meter = OTel.meter('weather_core');
    return _Instruments._()
      .._requests = meter.createCounter<int>(
        name: 'weather.requests',
        unit: '1',
        description:
            'Count of weather service operations by provider, '
            'operation, outcome, error kind, and country.',
      )
      .._duration = meter.createHistogram<int>(
        name: 'weather.request.duration',
        unit: 'ms',
        description: 'Wall-clock duration of weather service operations.',
        boundaries: const [
          5,
          10,
          25,
          50,
          100,
          250,
          500,
          1000,
          2500,
          5000,
          10000,
        ],
      );
  }

  late final APICounter<int> _requests;
  late final APIHistogram<int> _duration;

  APICounter<int> get requests => _requests;
  APIHistogram<int> get duration => _duration;
}
