// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:weather_core/weather_core.dart';
import 'package:weather_http_kit/weather_http_kit.dart';

import 'error_mapping.dart';

final _log = Logger('weather_api.router');

/// Default forecast horizon when the caller omits the `days` query parameter.
const int defaultForecastDays = 3;

/// Lower and upper bounds enforced on the `days` query parameter. Open-Meteo's
/// forecast endpoint accepts 1..16; we clamp at the API boundary so the
/// upstream provider never sees a value it would reject anyway.
const int minForecastDays = 1;
const int maxForecastDays = 16;

/// Builds the public HTTP pipeline for `weather_api`.
///
/// The pipeline is:
///   1. `_corsMiddleware` — permissive CORS so browser-hosted clients
///      (the Flutter web demo at `apps/weather_flutter`) can call the
///      API. Allows `traceparent`, `tracestate`, and `baggage` headers
///      so W3C trace context propagates across origins.
///   2. `otelMiddleware` — server span per request, W3C trace context and
///      baggage extraction, HTTP semconv attributes.
///   3. The router below — `GET /weather/<city>`, the v1 wire-format
///      pass-throughs (`GET /v1/geocode`, `POST /v1/forecast` — see
///      packages/weather_client/README.md), and `GET /health`.
///
/// The OTel middleware is the outermost layer of the instrumented
/// stack so server spans cover even 4xx/5xx responses produced by the
/// router itself (e.g., a 404 from an unmatched path is still an
/// observable event). CORS sits outside the OTel middleware so
/// preflight `OPTIONS` requests don't pollute the trace tree with a
/// span per request — a deliberate choice; browsers send a preflight
/// per cross-origin request and treating each as an independent
/// observable event would inflate metrics and trace volume without
/// adding signal.
Handler buildWeatherApiPipeline({required WeatherService service}) {
  final router = _buildRouter(service, service.provider);
  return const Pipeline()
      .addMiddleware(_corsMiddleware())
      .addMiddleware(
        otelMiddleware(
          tracerName: 'weather_api',
          // Span name uses the route template, not the concrete path. The
          // server span ends up named "GET /weather/:city" rather than
          // "GET /weather/Boston" — bounded cardinality, useful in
          // dashboards.
          routeResolver: _routeTemplateFor,
        ),
      )
      .addHandler(router.call);
}

/// Permissive CORS so browsers can call the API in the demo. The demo
/// is reference code, not a hardened deployment — production code
/// should set `access-control-allow-origin` to a specific origin and
/// audit the allowed headers. The allow-headers list is large enough
/// to cover trace-context propagation (`traceparent`, `tracestate`,
/// `baggage`) and the `content-type` headers `package:http` and
/// browser fetch send by default.
Middleware _corsMiddleware() {
  const headers = <String, String>{
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers':
        'Content-Type, Authorization, traceparent, tracestate, baggage',
    'access-control-max-age': '86400',
  };
  return (Handler inner) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: headers);
      }
      final response = await inner(request);
      return response.change(
        headers: <String, String>{...response.headers, ...headers},
      );
    };
  };
}

Router _buildRouter(WeatherService service, WeatherProvider upstream) {
  final router = Router();

  router.get('/health', (Request _) {
    return Response.ok('ok\n');
  });

  // v1 wire-format pass-throughs. weather_cli talks the v1 contract
  // (packages/weather_client/README.md) to THIS service so its trace
  // tree spans three hops: cli → weather_api → cache_service. No
  // caching here — cache_service owns the cache; these routes exist to
  // put weather_api's server + client spans on the path.
  router.get('/v1/geocode', (Request request) async {
    final query = request.url.queryParameters['q']?.trim() ?? '';
    if (query.isEmpty) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': '"q" must not be empty',
      });
    }
    final limitRaw = request.url.queryParameters['limit'];
    final limit = limitRaw == null ? 5 : int.tryParse(limitRaw);
    if (limit == null || limit < 1 || limit > 50) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': '"limit" must be a positive integer up to 50',
      });
    }

    try {
      final result = await upstream.geocode(query, maxResults: limit);
      return _jsonResponse(200, <String, Object>{
        'query': query,
        'matches': result.matches
            .map((c) => c.toJson())
            .toList(growable: false),
      });
    } on WeatherProviderException catch (e, st) {
      return _providerErrorResponse(e, st, operation: 'geocode');
    }
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

    try {
      final forecast = await upstream.getForecast(
        city: city,
        forecastDays: daysRaw,
      );
      return _jsonResponse(200, forecast.toJson());
    } on WeatherProviderException catch (e, st) {
      return _providerErrorResponse(e, st, operation: 'forecast');
    }
  });

  router.get('/weather/<city>', (Request request, String city) async {
    final daysRaw = request.url.queryParameters['days'];
    final daysParsed = daysRaw == null
        ? defaultForecastDays
        : int.tryParse(daysRaw);
    if (daysParsed == null ||
        daysParsed < minForecastDays ||
        daysParsed > maxForecastDays) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message':
            '"days" must be an integer in $minForecastDays..$maxForecastDays',
        'received': ?daysRaw,
      });
    }

    if (city.isEmpty) {
      return _jsonResponse(400, <String, Object>{
        'error': 'invalid_request',
        'message': 'city must not be empty',
      });
    }

    try {
      final forecast = await service.getForecast(
        cityName: city,
        forecastDays: daysParsed,
      );
      return _jsonResponse(200, forecast.toJson());
    } on WeatherProviderException catch (e, st) {
      final status = httpStatusForProviderError(e.kind);
      // 4xx errors are caller-attributable (they asked for a bad city, an
      // out-of-range value, etc.) and don't deserve a warning. 5xx errors
      // are upstream failures that operators should see.
      if (status >= 500) {
        _log.warning(
          'Provider error for city="$city" days=$daysParsed: ${e.kind}',
          e,
          st,
        );
      } else {
        _log.info(
          'Caller-attributable error for city="$city" days=$daysParsed: ${e.kind}',
        );
      }
      return _jsonResponse(status, <String, Object?>{
        'error': e.kind.name,
        'message': e.message,
        'provider': e.providerName,
      });
    } on Object catch (e, st) {
      // Anything we don't recognise is a 500 — and worth investigating.
      _log.severe('Unhandled exception in /weather handler', e, st);
      return _jsonResponse(500, <String, Object>{
        'error': 'internal_error',
        'message': 'an unexpected error occurred',
      });
    }
  });

  return router;
}

/// Returns the route template for [request] for use as `http.route` on the
/// server span. Returns null when the path doesn't match any known route —
/// otelMiddleware then falls back to using just the HTTP method as the
/// span name.
String? _routeTemplateFor(Request request) {
  final segments = request.url.pathSegments;
  if (segments.length == 1 && segments[0] == 'health') return '/health';
  if (segments.length == 2 && segments[0] == 'weather') return '/weather/:city';
  if (segments.length == 2 && segments[0] == 'v1') {
    if (segments[1] == 'geocode') return '/v1/geocode';
    if (segments[1] == 'forecast') return '/v1/forecast';
  }
  return null;
}

/// Maps a [WeatherProviderException] from a v1 pass-through to the same
/// wire shape `/weather/<city>` uses. 4xx = caller-attributable; 5xx =
/// upstream failures operators should see.
Response _providerErrorResponse(
  WeatherProviderException e,
  StackTrace st, {
  required String operation,
}) {
  final status = httpStatusForProviderError(e.kind);
  if (status >= 500) {
    _log.warning('Provider error in v1/$operation: ${e.kind}', e, st);
  } else {
    _log.info('Caller-attributable error in v1/$operation: ${e.kind}');
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
