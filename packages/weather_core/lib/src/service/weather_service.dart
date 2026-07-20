// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';

// The SDK barrel re-exports the full API surface — semantic enums,
// Context, Attributes, Span, Tracer, and the instrument-interface
// types (APICounter, APIHistogram) — so one import covers everything.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
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

  /// The provider this service composes. Exposed so callers wiring a
  /// pipeline (e.g. `buildWeatherApiPipeline`) don't have to be handed
  /// the same provider twice.
  WeatherProvider get provider => _provider;

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
    final tracer = OTel.tracerProvider().getTracer('weather_core');

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

        return forecast;
      });
    } on WeatherProviderException catch (e) {
      // withSpanAsync already recorded the exception and set the span
      // status; here we only annotate the failure metrics.
      outcome = 'error';
      errorKind = e.kind.name;
      rethrow;
    } catch (e) {
      // Span exception handling is owned by withSpanAsync.
      outcome = 'error';
      errorKind = WeatherProviderErrorKind.unknown.name;
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
        stopwatch.elapsedMicroseconds / Duration.microsecondsPerSecond,
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
      .._duration = meter.createHistogram<double>(
        name: 'weather.request.duration',
        unit: 's',
        description:
            'Wall-clock duration of weather service operations, in '
            'seconds (semconv prefers seconds for new duration instruments).',
        boundaries: const [
          0.005,
          0.01,
          0.025,
          0.05,
          0.1,
          0.25,
          0.5,
          1,
          2.5,
          5,
          10,
        ],
      );
  }

  late final APICounter<int> _requests;
  late final APIHistogram<double> _duration;

  APICounter<int> get requests => _requests;
  APIHistogram<double> get duration => _duration;
}
