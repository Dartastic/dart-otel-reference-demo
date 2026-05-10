// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';

import 'package:cache_service/cache_service.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

import '_helpers/fake_weather_provider.dart';
import '_helpers/otel_test_harness.dart';

void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;
  late FakeWeatherProvider upstream;
  late TtlCache<ForecastKey, WeatherForecast> forecastCache;
  late TtlCache<GeocodeKey, GeocodeResult> geocodeCache;
  late Handler handler;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest();
    spans = harness.spans;
  });

  setUp(() {
    harness.clear();
    upstream = FakeWeatherProvider();
    forecastCache = TtlCache<ForecastKey, WeatherForecast>(
      ttl: const Duration(minutes: 5),
    );
    geocodeCache = TtlCache<GeocodeKey, GeocodeResult>(
      ttl: const Duration(hours: 24),
    );
    handler = buildCacheServicePipeline(
      upstream: upstream,
      forecastCache: forecastCache,
      geocodeCache: geocodeCache,
    );
  });

  // ---------- Test fixtures ----------

  const toulouse = City(
    id: 2972315,
    name: 'Toulouse',
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
      Request('GET', Uri.parse('http://cache-service$path'));

  Request post(String path, Object body) => Request(
    'POST',
    Uri.parse('http://cache-service$path'),
    body: body is String ? body : jsonEncode(body),
    headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );

  // ---------- Healthz ----------

  group('GET /healthz', () {
    test('returns 200 with body "ok"', () async {
      final response = await handler(get('/healthz'));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'ok\n');
    });
  });

  // ---------- Geocode ----------

  group('GET /v1/geocode', () {
    test('200 with matches on a fresh key (cache miss)', () async {
      upstream.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [toulouse]);

      final response = await handler(get('/v1/geocode?q=Toulouse'));

      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['query'], 'Toulouse');
      expect((body['matches'] as List), hasLength(1));
      expect(upstream.geocodeCallCount, 1);
    });

    test(
      'caches by lowercased query — second call does not hit upstream',
      () async {
        upstream.geocodeImpl = (q, _) =>
            GeocodeResult(query: q, matches: const [toulouse]);

        await handler(get('/v1/geocode?q=Toulouse'));
        await handler(get('/v1/geocode?q=toulouse')); // different case
        await handler(get('/v1/geocode?q=TOULOUSE')); // different case

        // All three resolve to the same cache key ('toulouse', 5).
        expect(upstream.geocodeCallCount, 1);
      },
    );

    test('annotates the server span with cache outcome', () async {
      upstream.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [toulouse]);

      // First call: miss.
      await handler(get('/v1/geocode?q=Toulouse'));
      var span = spans.findSpanByName('GET /v1/geocode')!;
      expect(span.attributes.getString('weather.cache.outcome'), 'miss');
      expect(span.attributes.getString('weather.cache.namespace'), 'geocode');
      expect(span.spanEvents?.any((e) => e.name == 'cache.miss'), true);

      spans.clear();

      // Second call to the same key: hit.
      await handler(get('/v1/geocode?q=Toulouse'));
      span = spans.findSpanByName('GET /v1/geocode')!;
      expect(span.attributes.getString('weather.cache.outcome'), 'hit');
      expect(span.spanEvents?.any((e) => e.name == 'cache.hit'), true);
    });

    test('400 on empty q', () async {
      final response = await handler(get('/v1/geocode?q='));
      expect(response.statusCode, 400);
      expect(upstream.geocodeCallCount, 0);
    });

    test('400 on invalid limit', () async {
      final response = await handler(get('/v1/geocode?q=x&limit=999'));
      expect(response.statusCode, 400);
      expect(upstream.geocodeCallCount, 0);
    });

    test('upstream error maps to the right HTTP status', () async {
      upstream.geocodeError = const WeatherProviderException(
        kind: WeatherProviderErrorKind.upstream,
        providerName: 'open-meteo',
        message: 'upstream returned 500',
      );

      final response = await handler(get('/v1/geocode?q=Toulouse'));
      expect(response.statusCode, 502);
    });
  });

  // ---------- Forecast ----------

  group('POST /v1/forecast', () {
    Object _validBody({int days = 3}) => <String, dynamic>{
      'city': toulouse.toJson(),
      'forecastDays': days,
    };

    test('200 with the forecast on a cache miss', () async {
      upstream.forecastImpl = forecastFor;

      final response = await handler(post('/v1/forecast', _validBody(days: 2)));

      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      // Sanity-check the structure — round-trip behaviour itself is
      // covered by weather_core's tests.
      expect(body['city'], isA<Map<String, dynamic>>());
      expect((body['daily'] as List), hasLength(2));
      expect(upstream.forecastCallCount, 1);
    });

    test(
      'caches by (cityId, days) — repeat call does not hit upstream',
      () async {
        upstream.forecastImpl = forecastFor;

        await handler(post('/v1/forecast', _validBody(days: 3)));
        await handler(post('/v1/forecast', _validBody(days: 3)));
        await handler(post('/v1/forecast', _validBody(days: 3)));

        expect(upstream.forecastCallCount, 1);
      },
    );

    test(
      'different days for the same city is a separate cache entry',
      () async {
        upstream.forecastImpl = forecastFor;

        await handler(post('/v1/forecast', _validBody(days: 3)));
        await handler(post('/v1/forecast', _validBody(days: 5)));
        await handler(post('/v1/forecast', _validBody(days: 3))); // hit

        expect(upstream.forecastCallCount, 2);
      },
    );

    test('annotates the server span with cache outcome', () async {
      upstream.forecastImpl = forecastFor;

      await handler(post('/v1/forecast', _validBody()));
      var span = spans.findSpanByName('POST /v1/forecast')!;
      expect(span.attributes.getString('weather.cache.outcome'), 'miss');

      spans.clear();
      await handler(post('/v1/forecast', _validBody()));
      span = spans.findSpanByName('POST /v1/forecast')!;
      expect(span.attributes.getString('weather.cache.outcome'), 'hit');
    });

    test('400 on non-JSON body', () async {
      final response = await handler(post('/v1/forecast', 'not json'));
      expect(response.statusCode, 400);
      expect(upstream.forecastCallCount, 0);
    });

    test('400 on missing forecastDays', () async {
      final response = await handler(
        post('/v1/forecast', <String, dynamic>{'city': toulouse.toJson()}),
      );
      expect(response.statusCode, 400);
    });

    test('400 on out-of-range forecastDays', () async {
      final response = await handler(
        post('/v1/forecast', _validBody(days: 100)),
      );
      expect(response.statusCode, 400);
    });

    test('400 on malformed city object', () async {
      final response = await handler(
        post('/v1/forecast', <String, dynamic>{
          'city': <String, dynamic>{'id': 'not-an-int'},
          'forecastDays': 3,
        }),
      );
      expect(response.statusCode, 400);
    });

    test('rateLimit upstream maps to 429 — the most common deployment '
        'failure mode worth catching specifically', () async {
      upstream.forecastError = const WeatherProviderException(
        kind: WeatherProviderErrorKind.rateLimit,
        providerName: 'open-meteo',
        message: 'rate limited',
      );

      final response = await handler(post('/v1/forecast', _validBody()));
      expect(response.statusCode, 429);
    });
  });

  group('weather.cache.lookups counter', () {
    // Pins the cardinality and the per-outcome attribution that
    // makes hit-ratio queries safe across both backends. If a
    // future change introduces a high-cardinality attribute on
    // this metric (a request id, a city name, anything unbounded),
    // this test fails — that's the cardinality guardrail
    // promoted from a span attribute to a proper metric.
    // The counter is process-cumulative; previous tests in this
    // file have already incremented it. We snapshot before/after
    // and assert on the delta — that's both more honest about how
    // OTel cumulative counters work and robust to test ordering.
    int countOf(String namespace, String outcome) {
      final metric = harness.metrics.findMetricByName('weather.cache.lookups');
      if (metric == null) return 0;
      for (final p in metric.points) {
        if (p.attributes.getString('weather.cache.namespace') == namespace &&
            p.attributes.getString('weather.cache.outcome') == outcome) {
          return (p.value as num).toInt();
        }
      }
      return 0;
    }

    test('increments on hit and miss with bounded label set', () async {
      upstream.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [toulouse]);

      // Snapshot the cumulative running total first.
      await harness.collectMetrics();
      final missBefore = countOf('geocode', 'miss');
      final hitBefore = countOf('geocode', 'hit');
      harness.metrics.clear();

      // Two distinct keys produce two misses, then a repeat of the
      // first key is a hit.
      await handler(get('/v1/geocode?q=Toulouse'));
      await handler(get('/v1/geocode?q=Berlin'));
      await handler(get('/v1/geocode?q=Toulouse'));

      await harness.collectMetrics();
      expect(countOf('geocode', 'miss') - missBefore, 2);
      expect(countOf('geocode', 'hit') - hitBefore, 1);

      // Cardinality guardrail — every emitted point on this metric
      // carries exactly the bounded label set, never more. If a
      // future change starts attaching the city name or a request
      // id, this fails — the metric's series count would explode
      // and dashboards would break.
      const allowedKeys = <String>{
        'weather.cache.namespace',
        'weather.cache.outcome',
      };
      final metric = harness.metrics.findMetricByName('weather.cache.lookups')!;
      for (final point in metric.points) {
        expect(
          point.attributes.toMap().keys.toSet(),
          equals(allowedKeys),
          reason:
              'cache.lookups carries unexpected attribute keys — '
              'cardinality guardrail. Found: '
              '${point.attributes.toMap().keys.toList()}',
        );
      }
    });
  });
}
