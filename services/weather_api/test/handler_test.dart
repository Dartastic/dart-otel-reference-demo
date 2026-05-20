// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Integration tests for the HTTP pipeline. Each test builds the same
// pipeline the production binary builds (otelMiddleware + router), but
// against a hand-rolled FakeWeatherProvider — no network, no upstream.
//
// We stand up a real OpenTelemetry SDK pointed at an in-memory exporter
// so we can also assert on emitted spans where it matters.

import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:weather_api/weather_api.dart';
import 'package:weather_core/weather_core.dart';

import '_helpers/fake_weather_provider.dart';
import '_helpers/otel_test_harness.dart';

void main() {
  late InMemorySpanExporter spans;
  late FakeWeatherProvider provider;
  late Handler handler;

  setUpAll(() async {
    spans = await maybeInitializeOtelForTest();
  });

  setUp(() {
    spans.clear();
    provider = FakeWeatherProvider();
    handler = buildWeatherApiPipeline(
      service: WeatherService(provider: provider),
    );
  });

  // ---------- Test fixtures ----------

  const boston = City(
    id: 1,
    name: 'Boston',
    latitude: 43.6,
    longitude: 1.44,
    country: 'France',
    countryCode: 'FR',
  );

  WeatherForecast forecastFor(City city, int days) => WeatherForecast(
    city: city,
    current: CurrentWeather(
      observedAt: DateTime.utc(2026, 5, 9, 12),
      temperatureCelsius: 18,
      apparentTemperatureCelsius: 17,
      relativeHumidityPercent: 60,
      windSpeedKmh: 10,
      windDirectionDegrees: 270,
      precipitationMm: 0,
      weatherCode: WeatherCode.partlyCloudy,
      isDay: true,
    ),
    daily: List<DailyForecast>.generate(
      days,
      (i) => DailyForecast(
        date: DateTime.utc(2026, 5, 9 + i),
        weatherCode: WeatherCode.partlyCloudy,
        temperatureMinCelsius: 10,
        temperatureMaxCelsius: 20,
        precipitationSumMm: 0,
        precipitationProbabilityMaxPercent: 10,
        windSpeedMaxKmh: 12,
        uvIndexMax: 5,
        sunrise: DateTime.utc(2026, 5, 9 + i, 6, 30),
        sunset: DateTime.utc(2026, 5, 9 + i, 21),
      ),
    ),
    fetchedAt: DateTime.utc(2026, 5, 9, 12),
  );

  Request get(String path) =>
      Request('GET', Uri.parse('http://weather-api$path'));

  // ---------- Tests ----------

  group('GET /healthz', () {
    test('returns 200 with body "ok"', () async {
      final response = await handler(get('/healthz'));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'ok\n');
    });

    test('emits a server span named with the route template', () async {
      await handler(get('/healthz'));
      // Span name uses the route template ('/healthz') prefixed with the
      // method ('GET'). This is the otelMiddleware route-resolver
      // contract: low-cardinality span names are essential for dashboards.
      final span = spans.findSpanByName('GET /healthz');
      expect(span, isNotNull);
      expect(span!.kind, SpanKind.server);
    });
  });

  group('GET /weather/<city>', () {
    test('returns 200 with the forecast JSON on the happy path', () async {
      provider.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [boston]);
      provider.forecastImpl = forecastFor;

      final response = await handler(get('/weather/Boston?days=2'));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      // Sanity-check the structure — the round-trip behavior of the
      // serializers themselves is exercised in weather_core's tests.
      expect(body['city'], isA<Map<String, dynamic>>());
      expect((body['city'] as Map<String, dynamic>)['name'], 'Boston');
      expect((body['daily'] as List), hasLength(2));
    });

    test('uses defaultForecastDays when days is omitted', () async {
      provider.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [boston]);
      provider.forecastImpl = forecastFor;

      final response = await handler(get('/weather/Boston'));

      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect((body['daily'] as List), hasLength(defaultForecastDays));
    });

    test('returns 400 with diagnostic body for non-integer days', () async {
      final response = await handler(get('/weather/Boston?days=abc'));
      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'invalid_request');
      expect(body['received'], 'abc');
    });

    test('returns 400 for days out of the supported range', () async {
      final response = await handler(get('/weather/Boston?days=100'));
      expect(response.statusCode, 400);
    });

    test('returns 404 when the geocoder finds no matches', () async {
      provider.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const []);

      final response = await handler(get('/weather/Atlantis'));
      expect(response.statusCode, 404);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'notFound');
    });

    test('returns 502 on upstream provider errors', () async {
      provider.geocodeError = const WeatherProviderException(
        kind: WeatherProviderErrorKind.upstream,
        providerName: 'fake',
        message: 'upstream returned 500',
      );

      final response = await handler(get('/weather/Boston'));
      expect(response.statusCode, 502);
    });

    test('returns 503 on network errors', () async {
      provider.geocodeError = const WeatherProviderException(
        kind: WeatherProviderErrorKind.network,
        providerName: 'fake',
        message: 'connection refused',
      );

      final response = await handler(get('/weather/Boston'));
      expect(response.statusCode, 503);
    });

    test('returns 429 on upstream rate limit', () async {
      provider.geocodeError = const WeatherProviderException(
        kind: WeatherProviderErrorKind.rateLimit,
        providerName: 'fake',
        message: 'rate limited',
      );

      final response = await handler(get('/weather/Boston'));
      expect(response.statusCode, 429);
    });

    test('emits a server span with the route template name', () async {
      provider.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [boston]);
      provider.forecastImpl = forecastFor;

      await handler(get('/weather/Boston?days=1'));

      final span = spans.findSpanByName('GET /weather/:city');
      expect(span, isNotNull);
      expect(span!.kind, SpanKind.server);
    });
  });
}
