// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:weather_core/weather_core.dart';

/// HTTP client for the demo's v1 weather API.
///
/// Implements [WeatherProvider] against any service that speaks the
/// v1 API contract:
///
/// ```
///   GET  <baseUrl>/v1/geocode?q=<query>&limit=<int>
///        → 200 { "query": "...", "matches": [ <City>, ... ] }
///   POST <baseUrl>/v1/forecast
///        body: { "city": <City>, "forecastDays": N }
///        → 200 <WeatherForecast>
///   GET  <baseUrl>/healthz
///        → 200 "ok\n"
/// ```
///
/// HTTP status codes returned by the upstream are mapped back to
/// [WeatherProviderException] kinds — symmetric with the mapping
/// `services/weather_api` uses to translate the same exceptions to
/// HTTP. So a 404 from cache_service surfaces as
/// [WeatherProviderErrorKind.notFound] in the caller; if the caller is
/// itself an HTTP service, the mapping reverses cleanly back to 404.
///
/// **Library, not bootstrap.** Consumers pass an [http.Client] (almost
/// always `InstrumentedHttpClient` from `weather_http_kit`) and own
/// the OpenTelemetry SDK lifecycle. This package does not call
/// `OTel.initialize` and does not create any spans of its own — the
/// outbound spans come from the supplied client.
class WeatherClient implements WeatherProvider {
  /// Creates a client that talks to the v1 API rooted at [baseUrl].
  ///
  /// [baseUrl] should NOT include a trailing slash; both
  /// `http://cache-service:8090` and `http://cache-service:8090/v1`
  /// are accepted, though the latter is non-canonical and produces an
  /// extra `/v1` segment on every request.
  WeatherClient({
    required Uri baseUrl,
    required http.Client client,
    String providerName = 'weather-v1',
    Duration timeout = const Duration(seconds: 10),
  }) : _baseUrl = baseUrl,
       _client = client,
       _name = providerName,
       _timeout = timeout;

  final Uri _baseUrl;
  final http.Client _client;
  final String _name;
  final Duration _timeout;

  static final Logger _log = Logger('weather_client');

  @override
  String get name => _name;

  @override
  Future<GeocodeResult> geocode(String query, {int maxResults = 5}) async {
    if (query.trim().isEmpty) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.badRequest,
        providerName: _name,
        message: 'query must not be empty',
      );
    }
    final uri = _baseUrl.replace(
      pathSegments: <String>[..._baseUrl.pathSegments, 'v1', 'geocode'],
      queryParameters: <String, String>{
        'q': query,
        'limit': maxResults.toString(),
      },
    );
    final body = await _send(method: 'GET', uri: uri, operation: 'geocode');
    return _parseGeocodeBody(query, body);
  }

  @override
  Future<WeatherForecast> getForecast({
    required City city,
    required int forecastDays,
  }) async {
    final uri = _baseUrl.replace(
      pathSegments: <String>[..._baseUrl.pathSegments, 'v1', 'forecast'],
    );
    final requestBody = <String, dynamic>{
      'city': city.toJson(),
      'forecastDays': forecastDays,
    };
    final body = await _send(
      method: 'POST',
      uri: uri,
      operation: 'getForecast',
      body: jsonEncode(requestBody),
    );
    return _parseForecastBody(body);
  }

  /// Sends an HTTP request and returns the response body as a string.
  /// All upstream errors are translated to [WeatherProviderException]
  /// before being thrown — callers don't need to know they're talking
  /// to anything over the wire.
  Future<String> _send({
    required String method,
    required Uri uri,
    required String operation,
    String? body,
  }) async {
    try {
      final request = http.Request(method, uri);
      request.headers['accept'] = 'application/json';
      if (body != null) {
        request.headers['content-type'] = 'application/json; charset=utf-8';
        request.body = body;
      }
      final streamed = await _client.send(request).timeout(_timeout);
      final response = await http.Response.fromStream(streamed);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body;
      }
      throw _exceptionForStatus(
        operation: operation,
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    } on TimeoutException catch (e) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: _name,
        message: 'request timed out after ${_timeout.inSeconds}s: $e',
      );
    } on SocketException catch (e) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: _name,
        message: 'socket error: ${e.message}',
      );
    } on http.ClientException catch (e) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: _name,
        message: 'http client error: ${e.message}',
      );
    } on WeatherProviderException {
      // Already classified — propagate without rewrapping.
      rethrow;
    } on Object catch (e, st) {
      _log.warning('Unexpected error during $operation', e, st);
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.unknown,
        providerName: _name,
        message: 'unexpected error: $e',
      );
    }
  }

  /// Inverse of `services/weather_api`'s `httpStatusForProviderError`.
  /// Keep these two in sync — divergence breaks caller-attributable
  /// vs. server-attributable error reporting across the chain.
  WeatherProviderException _exceptionForStatus({
    required String operation,
    required int statusCode,
    required String responseBody,
  }) {
    final kind = switch (statusCode) {
      400 => WeatherProviderErrorKind.badRequest,
      404 => WeatherProviderErrorKind.notFound,
      429 => WeatherProviderErrorKind.rateLimit,
      503 => WeatherProviderErrorKind.network,
      >= 500 => WeatherProviderErrorKind.upstream,
      _ => WeatherProviderErrorKind.unknown,
    };
    // Try to extract the upstream's error message from a JSON body so
    // it's visible in the caller's logs / span events.
    String message = 'HTTP $statusCode from $operation';
    try {
      final decoded = jsonDecode(responseBody);
      if (decoded is Map<String, dynamic>) {
        final upstreamMessage = decoded['message'];
        if (upstreamMessage is String && upstreamMessage.isNotEmpty) {
          message = '$message: $upstreamMessage';
        }
      }
    } on Object catch (_) {
      // Body wasn't JSON or didn't have a message field — fall through
      // with the generic message.
    }
    return WeatherProviderException(
      kind: kind,
      providerName: _name,
      message: message,
    );
  }

  GeocodeResult _parseGeocodeBody(String query, String body) {
    final decoded = _decodeJson(body, operation: 'geocode');
    final matchesRaw = decoded['matches'];
    if (matchesRaw is! List) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.parse,
        providerName: _name,
        message: 'geocode response missing "matches" array',
      );
    }
    try {
      final matches = matchesRaw
          .map((e) => City.fromJson(e as Map<String, dynamic>))
          .toList(growable: false);
      // The server echoes the query but trust the caller's input over
      // a possibly normalized response field.
      return GeocodeResult(query: query, matches: matches);
    } on FormatException catch (e) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.parse,
        providerName: _name,
        message: 'malformed City in geocode response: ${e.message}',
      );
    }
  }

  WeatherForecast _parseForecastBody(String body) {
    final decoded = _decodeJson(body, operation: 'getForecast');
    try {
      return WeatherForecast.fromJson(decoded);
    } on FormatException catch (e) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.parse,
        providerName: _name,
        message: 'malformed WeatherForecast in response: ${e.message}',
      );
    }
  }

  Map<String, dynamic> _decodeJson(String body, {required String operation}) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw WeatherProviderException(
          kind: WeatherProviderErrorKind.parse,
          providerName: _name,
          message: '$operation response was not a JSON object',
        );
      }
      return decoded;
    } on FormatException catch (e) {
      throw WeatherProviderException(
        kind: WeatherProviderErrorKind.parse,
        providerName: _name,
        message: '$operation response was not valid JSON: ${e.message}',
      );
    }
  }

  /// Releases the underlying HTTP client. Call once when the
  /// application is done with this client. Idempotent.
  void close() {
    _client.close();
  }
}

/// Internal-only constant set of accepted HTTP status codes for the
/// status-mapping switch above. Exposed so tests can iterate it.
@visibleForTesting
const Set<int> mappedStatusCodes = <int>{400, 404, 429, 500, 502, 503};
