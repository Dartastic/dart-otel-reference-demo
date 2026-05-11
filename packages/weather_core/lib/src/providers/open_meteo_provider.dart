// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// The SDK re-exports MOST of the API surface (Tracer, Span, Context,
// Attributes, semantic enums) — but NOT the abstract instrument
// interfaces (APICounter, APIHistogram), which is why we depend on
// the API package directly to name them. Same constraint
// `weather_service.dart` and `cache_service`'s router work around.
import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    show APICounter;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../instrumentation/weather_semantics.dart';
import '../models/city.dart';
import '../models/geocode_result.dart';
import '../models/weather_forecast.dart';
import 'weather_provider.dart';
import 'weather_provider_exception.dart';

/// Open-Meteo implementation of `WeatherProvider`.
///
/// Open-Meteo (<https://open-meteo.com>) is a free, no-API-key weather
/// service appropriate for public demos. It provides separate endpoints
/// for geocoding and forecast retrieval.
///
/// The constructor accepts an [http.Client] so consumers can inject the
/// instrumented client from `weather_http_kit` (which adds W3C trace
/// context propagation on outbound calls). Tests can inject a fake.
///
/// This class produces client spans for every upstream call and translates
/// upstream errors into `WeatherProviderException` with appropriate
/// `WeatherProviderErrorKind`s.
class OpenMeteoProvider implements WeatherProvider {
  /// Creates a provider that talks to Open-Meteo over [client].
  ///
  /// [timeout] is applied per upstream request. Defaults to 10 seconds, in
  /// line with the OTel spec's recommended HTTP exporter timeout.
  OpenMeteoProvider({
    required http.Client client,
    Duration timeout = const Duration(seconds: 10),
    Uri? geocodingBaseUri,
    Uri? forecastBaseUri,
  }) : _client = client,
       _timeout = timeout,
       _geocodingBaseUri = geocodingBaseUri ?? _defaultGeocodingUri,
       _forecastBaseUri = forecastBaseUri ?? _defaultForecastUri;

  static final Uri _defaultGeocodingUri = Uri.parse(
    'https://geocoding-api.open-meteo.com/v1/search',
  );
  static final Uri _defaultForecastUri = Uri.parse(
    'https://api.open-meteo.com/v1/forecast',
  );

  static const _currentVariables =
      'temperature_2m,apparent_temperature,relative_humidity_2m,'
      'wind_speed_10m,wind_direction_10m,precipitation,weather_code,is_day';

  static const _dailyVariables =
      'weather_code,temperature_2m_min,temperature_2m_max,'
      'precipitation_sum,precipitation_probability_max,'
      'wind_speed_10m_max,uv_index_max,sunrise,sunset';

  static const _maxForecastDays = 16;
  static const _minForecastDays = 1;

  final http.Client _client;
  final Duration _timeout;
  final Uri _geocodingBaseUri;
  final Uri _forecastBaseUri;

  static final Logger _log = Logger('weather_core.OpenMeteoProvider');

  @override
  String get name => 'open-meteo';

  /// Per-call counter for upstream requests to Open-Meteo.
  ///
  /// Two questions a real ops team always wants this metric to
  /// answer:
  ///
  ///   1. **Dependency health.** What fraction of our calls to
  ///      Open-Meteo succeed right now? `success / (success +
  ///      error)` over a rolling window is the headline number;
  ///      slicing by `error.kind` shows whether failures are
  ///      network, rate-limit, parse, or upstream-5xx so the
  ///      page goes to the right team.
  ///   2. **Cost.** Open-Meteo is free at the demo's volume but
  ///      every paid upstream API charges per call. Multiplying
  ///      `sum(rate(weather_upstream_requests_total))` by the
  ///      contract's per-call price is the cleanest "what is this
  ///      dependency costing us" panel — no per-request log
  ///      parsing required.
  ///
  /// Cardinality bounded:
  ///   provider:    {open-meteo, ...}                ~5 values
  ///   operation:   {geocode, getForecast}            2 values
  ///   outcome:     {success, error}                  2 values
  ///   error.kind:  WeatherProviderErrorKind          7 values
  ///                  (only present when outcome=error)
  /// Upper bound: ~80 series — safe under any backend's per-metric
  /// series cap.
  static late final APICounter<int> _upstreamRequests =
      OTel.meter('weather_core').createCounter<int>(
        name: 'weather.upstream.requests',
        unit: '1',
        description:
            'Count of upstream weather-provider calls by provider, '
            'operation, outcome, and error.kind. Use for dependency-'
            'health panels (success rate by provider × operation) and '
            'upstream-call cost panels (count × per-call price).',
      );

  /// Increments `_upstreamRequests`. Called from the `finally` block
  /// of every operation so success and error paths share one
  /// recording site — keeps the counter's contract obvious and
  /// removes duplicate increment risk if the success path ever
  /// grows another return statement.
  void _recordUpstream({
    required String operation,
    required String outcome,
    String? errorKind,
  }) {
    final attrs = <String, Object>{
      WeatherSemantics.provider.key: name,
      WeatherSemantics.operation.key: operation,
      WeatherSemantics.outcome.key: outcome,
      WeatherSemantics.errorKind.key: ?errorKind,
    };
    _upstreamRequests.add(1, OTel.attributesFromMap(attrs));
  }

  @override
  Future<GeocodeResult> geocode(String query, {int maxResults = 5}) async {
    if (query.trim().isEmpty) {
      throw const WeatherProviderException(
        kind: WeatherProviderErrorKind.badRequest,
        message: 'geocode query must not be empty',
        providerName: 'open-meteo',
      );
    }
    if (maxResults < 1 || maxResults > 100) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.badRequest,
        message: 'maxResults must be between 1 and 100, got $maxResults',
        providerName: name,
      );
    }

    final uri = _geocodingBaseUri.replace(
      queryParameters: <String, String>{
        'name': query,
        'count': maxResults.toString(),
        'language': 'en',
        'format': 'json',
      },
    );

    final span = OTel.tracer().startSpan(
      'open-meteo geocode',
      kind: SpanKind.client,
      attributes: OTel.attributesFromSemanticMap({
        ...<Http, Object>{.requestMethod: 'GET'},
        Url.urlFull: uri.toString(),
        ServerResource.serverAddress: uri.host,
        ...<WeatherSemantics, Object>{
          .provider: name,
          .operation: 'geocode',
          // Free-text query is high-cardinality — span-only.
          .geocodeQuery: query,
          .geocodeMaxResults: maxResults,
        },
      }),
    );

    var outcome = 'success';
    String? errorKind;
    try {
      return await OTel.tracer().withSpanAsync(span, () async {
        final body = await _get(uri, span: span, operation: 'geocode');
        final decoded = _decodeJson(body);

        final rawResults = decoded['results'];
        if (rawResults is! List) {
          // Open-Meteo represents "no matches" as a 200 with no `results`
          // key. This is not an exceptional condition.
          span
            ..addEvent(
              OTel.spanEventNow(
                'geocode.no_matches',
                OTel.attributesFromMap(<String, Object>{
                  WeatherSemantics.geocodeMatchCount.key: 0,
                }),
              ),
            )
            ..setStatus(.Ok);
          return GeocodeResult(query: query, matches: const []);
        }

        final cities = <City>[];
        for (final entry in rawResults) {
          if (entry is Map<String, dynamic>) {
            try {
              cities.add(City.fromOpenMeteoJson(entry));
            } on FormatException catch (e) {
              // Skip malformed entries rather than failing the whole
              // request; record an event so the issue is observable.
              span.addEvent(
                OTel.spanEventNow(
                  'geocode.entry_skipped',
                  OTel.attributesFromMap(<String, Object>{
                    ExceptionResource.exceptionMessage.key: e.message,
                  }),
                ),
              );
            }
          }
        }

        span
          ..addAttributes(
            OTel.attributesFromMap(<String, Object>{
              WeatherSemantics.geocodeMatchCount.key: cities.length,
              WeatherSemantics.geocodeAmbiguous.key: cities.length > 1,
            }),
          )
          ..setStatus(.Ok);

        return GeocodeResult(
          query: query,
          matches: List<City>.unmodifiable(cities),
        );
      });
    } on WeatherProviderException catch (e, st) {
      outcome = 'error';
      errorKind = e.kind.name;
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(.Error, e.message);
      rethrow;
    } catch (e, st) {
      outcome = 'error';
      errorKind = WeatherProviderErrorKind.unknown.name;
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(.Error, e.toString());
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.unknown,
        providerName: name,
        message: 'Unexpected error during geocode: $e',
        cause: e,
        causeStackTrace: st,
      );
    } finally {
      span.end();
      _recordUpstream(
        operation: 'geocode',
        outcome: outcome,
        errorKind: errorKind,
      );
    }
  }

  @override
  Future<WeatherForecast> getForecast({
    required City city,
    required int forecastDays,
  }) async {
    if (forecastDays < _minForecastDays || forecastDays > _maxForecastDays) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.badRequest,
        message:
            'forecastDays must be between $_minForecastDays and '
            '$_maxForecastDays, got $forecastDays',
        providerName: name,
      );
    }

    final uri = _forecastBaseUri.replace(
      queryParameters: <String, String>{
        'latitude': city.latitude.toString(),
        'longitude': city.longitude.toString(),
        'current': _currentVariables,
        'daily': _dailyVariables,
        'forecast_days': forecastDays.toString(),
        'timezone': 'auto',
      },
    );

    final span = OTel.tracer().startSpan(
      'open-meteo forecast',
      kind: SpanKind.client,
      attributes: OTel.attributesFromSemanticMap({
        ...<Http, Object>{.requestMethod: 'GET'},
        Url.urlFull: uri.toString(),
        ServerResource.serverAddress: uri.host,
        ...<WeatherSemantics, Object>{
          .provider: name,
          .operation: 'forecast',
          .cityId: city.id,
          // City name is high-cardinality. Span attribute only.
          .cityName: city.name,
          // Country code is bounded (~250 values) — both span and metric safe.
          .cityCountryCode: city.countryCode,
          .forecastDays: forecastDays,
        },
      }),
    );

    var outcome = 'success';
    String? errorKind;
    try {
      return await OTel.tracer().withSpanAsync(span, () async {
        final body = await _get(uri, span: span, operation: 'forecast');
        final decoded = _decodeJson(body);
        final fetchedAt = DateTime.now().toUtc();

        try {
          final forecast = WeatherForecast.fromOpenMeteoJson(
            city: city,
            json: decoded,
            fetchedAt: fetchedAt,
          );
          span
            ..addAttributes(
              OTel.attributesFromMap(<String, Object>{
                WeatherSemantics.currentWeatherCode.key:
                    forecast.current.weatherCode.code,
                WeatherSemantics.currentSeverity.key:
                    forecast.current.weatherCode.severity.name,
                WeatherSemantics.currentIsDay.key: forecast.current.isDay,
              }),
            )
            ..setStatus(.Ok);
          return forecast;
        } on FormatException catch (e, st) {
          throw WeatherProviderException(
            kind: WeatherProviderErrorKind.parse,
            providerName: name,
            message:
                'Forecast response did not match expected schema: ${e.message}',
            cause: e,
            causeStackTrace: st,
          );
        }
      });
    } on WeatherProviderException catch (e, st) {
      outcome = 'error';
      errorKind = e.kind.name;
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(.Error, e.message);
      rethrow;
    } catch (e, st) {
      outcome = 'error';
      errorKind = WeatherProviderErrorKind.unknown.name;
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(.Error, e.toString());
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.unknown,
        providerName: name,
        message: 'Unexpected error during forecast: $e',
        cause: e,
        causeStackTrace: st,
      );
    } finally {
      span.end();
      _recordUpstream(
        operation: 'forecast',
        outcome: outcome,
        errorKind: errorKind,
      );
    }
  }

  /// Performs the HTTP GET, applies the timeout, classifies failures.
  Future<String> _get(
    Uri uri, {
    required Span span,
    required String operation,
  }) async {
    http.Response response;
    try {
      response = await _client.get(uri).timeout(_timeout);
    } on TimeoutException catch (e, st) {
      _log.warning('Open-Meteo $operation timed out after $_timeout', e, st);
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: name,
        message: 'Request to $uri timed out after $_timeout',
        cause: e,
        causeStackTrace: st,
      );
    } on SocketException catch (e, st) {
      _log.warning('Open-Meteo $operation socket error', e, st);
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: name,
        message: 'Network error reaching ${uri.host}: ${e.message}',
        cause: e,
        causeStackTrace: st,
      );
    } on http.ClientException catch (e, st) {
      _log.warning('Open-Meteo $operation HTTP client error', e, st);
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: name,
        message: 'HTTP client error reaching ${uri.host}: ${e.message}',
        cause: e,
        causeStackTrace: st,
      );
    }

    span.addAttributes(
      OTel.attributesOf<Http>({
        .responseStatusCode: response.statusCode,
        .responseBodySize: response.bodyBytes.length,
      }),
    );

    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      return response.body;
    }
    if (status == 429) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.rateLimit,
        providerName: name,
        statusCode: status,
        message: 'Rate-limited by ${uri.host}',
      );
    }
    if (status >= 500) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.upstream,
        providerName: name,
        statusCode: status,
        message: '${uri.host} returned $status: ${_truncate(response.body)}',
      );
    }
    if (status == 404) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.notFound,
        providerName: name,
        statusCode: status,
        message: 'Resource not found at $uri',
      );
    }
    throw WeatherProviderException(
      kind: WeatherProviderErrorKind.badRequest,
      providerName: name,
      statusCode: status,
      message:
          '${uri.host} rejected request ($status): '
          '${_truncate(response.body)}',
    );
  }

  Map<String, dynamic> _decodeJson(String body) {
    final Object? decoded;
    try {
      decoded = json.decode(body);
    } on FormatException catch (e, st) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.parse,
        providerName: name,
        message: 'Could not parse response body as JSON: ${e.message}',
        cause: e,
        causeStackTrace: st,
      );
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw WeatherProviderException(
      kind: WeatherProviderErrorKind.parse,
      providerName: name,
      message: 'Expected JSON object at top level, got ${decoded.runtimeType}',
    );
  }

  static String _truncate(String s, {int max = 200}) =>
      s.length <= max ? s : '${s.substring(0, max)}...';
}
