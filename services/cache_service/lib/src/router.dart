// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:weather_core/weather_core.dart';
import 'package:weather_http_kit/weather_http_kit.dart';

import 'cache.dart';
import 'error_mapping.dart';

final _log = Logger('cache_service.router');

/// Default TTL for forecast cache entries. Open-Meteo updates its
/// forecast model on a multi-minute cadence; 5 minutes is a reasonable
/// trade-off between freshness and call reduction for a demo.
const Duration defaultForecastTtl = Duration(minutes: 5);

/// Default TTL for geocode cache entries. Geocoding results rarely
/// change — a city's lat/lon is stable. A long TTL keeps the cache
/// hit rate high.
const Duration defaultGeocodeTtl = Duration(hours: 24);

/// Maximum forecast horizon supported by the upstream provider. The
/// cache_service rejects values outside this range BEFORE looking up
/// or calling upstream, matching the validation `weather_api` performs
/// on inbound requests.
const int minForecastDays = 1;
const int maxForecastDays = 16;

/// Cache key for forecast lookups. Records give us free structural
/// equality and hashCode for use as Map keys.
typedef ForecastKey = ({int cityId, int forecastDays});

/// Cache key for geocode lookups: lowercased query plus the result limit.
typedef GeocodeKey = ({String query, int maxResults});

/// Builds the public HTTP pipeline for `cache_service`.
Handler buildCacheServicePipeline({
  required WeatherProvider upstream,
  TtlCache<ForecastKey, WeatherForecast>? forecastCache,
  TtlCache<GeocodeKey, GeocodeResult>? geocodeCache,
}) {
  final fc =
      forecastCache ??
      TtlCache<ForecastKey, WeatherForecast>(ttl: defaultForecastTtl);
  final gc =
      geocodeCache ??
      TtlCache<GeocodeKey, GeocodeResult>(ttl: defaultGeocodeTtl);
  final router = _buildRouter(
    upstream: upstream,
    forecastCache: fc,
    geocodeCache: gc,
  );
  return const Pipeline()
      .addMiddleware(
        otelMiddleware(
          tracerName: 'cache_service',
          routeResolver: _routeTemplateFor,
        ),
      )
      .addHandler(router.call);
}

Router _buildRouter({
  required WeatherProvider upstream,
  required TtlCache<ForecastKey, WeatherForecast> forecastCache,
  required TtlCache<GeocodeKey, GeocodeResult> geocodeCache,
}) {
  final router = Router();

  router.get('/healthz', (Request _) => Response.ok('ok\n'));

  router.get('/v1/geocode', (Request request) async {
    final query = request.url.queryParameters['q']?.trim() ?? '';
    if (query.isEmpty) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': '"q" must not be empty',
      });
    }
    final limit =
        _parsePositiveInt(
          request.url.queryParameters['limit'],
          defaultValue: 5,
          maxValue: 50,
        ) ??
        -1;
    if (limit < 1) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': '"limit" must be a positive integer up to 50',
      });
    }

    final key = (query: query.toLowerCase(), maxResults: limit);
    final lookup = geocodeCache.get(key);
    _annotateActiveSpan(
      namespace: 'geocode',
      outcome: lookup.outcome,
      cacheSize: geocodeCache.size,
    );

    GeocodeResult result;
    if (lookup.value != null) {
      result = lookup.value!;
    } else {
      try {
        result = await upstream.geocode(query, maxResults: limit);
      } on WeatherProviderException catch (e, st) {
        return _errorResponse(e, st);
      }
      geocodeCache.put(key, result);
    }

    return _jsonResponse(200, <String, Object>{
      'query': query,
      'matches': result.matches.map((c) => c.toJson()).toList(growable: false),
    });
  });

  router.post('/v1/forecast', (Request request) async {
    final Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(await request.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return _jsonResponse(400, <String, Object>{
          'error': 'invalid_request',
          'message': 'request body must be a JSON object',
        });
      }
      body = decoded;
    } on FormatException catch (e) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': 'request body is not valid JSON: ${e.message}',
      });
    }

    final cityRaw = body['city'];
    final daysRaw = body['forecastDays'];
    if (cityRaw is! Map<String, dynamic>) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': 'request body must contain a "city" object',
      });
    }
    if (daysRaw is! int ||
        daysRaw < minForecastDays ||
        daysRaw > maxForecastDays) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message':
            '"forecastDays" must be an integer in '
            '$minForecastDays..$maxForecastDays',
      });
    }

    final City city;
    try {
      city = City.fromJson(cityRaw);
    } on FormatException catch (e) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': 'malformed "city" object: ${e.message}',
      });
    }

    final key = (cityId: city.id, forecastDays: daysRaw);
    final lookup = forecastCache.get(key);
    _annotateActiveSpan(
      namespace: 'forecast',
      outcome: lookup.outcome,
      cacheSize: forecastCache.size,
    );

    WeatherForecast forecast;
    if (lookup.value != null) {
      forecast = lookup.value!;
    } else {
      try {
        forecast = await upstream.getForecast(
          city: city,
          forecastDays: daysRaw,
        );
      } on WeatherProviderException catch (e, st) {
        return _errorResponse(e, st);
      }
      forecastCache.put(key, forecast);
    }

    return _jsonResponse(200, forecast.toJson());
  });

  return router;
}

/// Returns the route template for [request] so otelMiddleware uses it
/// as the server-span name. Bounded cardinality (3 templates total).
String? _routeTemplateFor(Request request) {
  final segments = request.url.pathSegments;
  if (segments.length == 1 && segments[0] == 'healthz') return '/healthz';
  if (segments.length == 2 && segments[0] == 'v1') {
    if (segments[1] == 'geocode') return '/v1/geocode';
    if (segments[1] == 'forecast') return '/v1/forecast';
  }
  return null;
}

/// Adds cache-attribution attributes to the active server span. Called
/// from inside each route handler — at this point otelMiddleware has
/// the server span active, and `Context.current.span` is that span.
///
/// Attribute names are local to this service for now. If a similar
/// pattern shows up in cache_service-like services elsewhere, lift
/// these into a shared semantic-conventions enum (the same way
/// WeatherSemantics in weather_core lifted business-level enums).
void _annotateActiveSpan({
  required String namespace,
  required CacheOutcome outcome,
  required int cacheSize,
}) {
  final span = Context.current.span;
  if (span == null) return;
  span.addAttributes(
    OTel.attributesFromMap(<String, Object>{
      'weather.cache.namespace': namespace,
      'weather.cache.outcome': outcome.name,
      'weather.cache.size': cacheSize,
    }),
  );
  span.addEventNow('cache.${outcome.name}');
}

Response _errorResponse(WeatherProviderException e, StackTrace st) {
  final status = httpStatusForProviderError(e.kind);
  if (status >= 500) {
    _log.warning('Upstream error: ${e.kind}', e, st);
  } else {
    _log.info('Caller-attributable upstream error: ${e.kind}');
  }
  return _jsonResponse(status, <String, Object?>{
    'error': e.kind.name,
    'message': e.message,
    'provider': e.providerName,
  });
}

Response _jsonResponse(int status, Map<String, Object?> body) {
  return Response(
    status,
    body: jsonEncode(body),
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

int? _parsePositiveInt(
  String? raw, {
  required int defaultValue,
  required int maxValue,
}) {
  if (raw == null) return defaultValue;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed < 1 || parsed > maxValue) return null;
  return parsed;
}
