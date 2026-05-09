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
///   1. `otelMiddleware` — server span per request, W3C trace context and
///      baggage extraction, HTTP semconv attributes.
///   2. The router below — `GET /weather/<city>` and `GET /healthz`.
///
/// The OTel middleware is the outermost layer so server spans cover even
/// 4xx/5xx responses produced by the router itself (e.g., a 404 from an
/// unmatched path is still an observable event).
Handler buildWeatherApiPipeline({required WeatherService service}) {
  final router = _buildRouter(service);
  return const Pipeline()
      .addMiddleware(
        otelMiddleware(
          tracerName: 'weather_api',
          // Span name uses the route template, not the concrete path. The
          // server span ends up named "GET /weather/:city" rather than
          // "GET /weather/Toulouse" — bounded cardinality, useful in
          // dashboards.
          routeResolver: _routeTemplateFor,
        ),
      )
      .addHandler(router.call);
}

Router _buildRouter(WeatherService service) {
  final router = Router();

  router.get('/healthz', (Request _) {
    return Response.ok('ok\n');
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
        if (daysRaw != null) 'received': daysRaw,
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
  if (segments.length == 1 && segments[0] == 'healthz') return '/healthz';
  if (segments.length == 2 && segments[0] == 'weather') return '/weather/:city';
  return null;
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
