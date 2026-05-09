// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

import '../_helpers/otel_test_harness.dart';

/// Builds a Map shaped like Open-Meteo's `/v1/search` response for one match.
Map<String, dynamic> _geocodeResponse(String name) => <String, dynamic>{
  'results': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 1,
      'name': name,
      'latitude': 43.6,
      'longitude': 1.44,
      'country': 'France',
      'country_code': 'FR',
      'timezone': 'Europe/Paris',
    },
  ],
};

Map<String, dynamic> _forecastResponse() => <String, dynamic>{
  'current': <String, dynamic>{
    'time': '2026-05-09T12:00',
    'temperature_2m': 18.5,
    'apparent_temperature': 17.2,
    'relative_humidity_2m': 62,
    'wind_speed_10m': 12.0,
    'wind_direction_10m': 270,
    'precipitation': 0.0,
    'weather_code': 2,
    'is_day': 1,
  },
  'daily': <String, dynamic>{
    'time': <String>['2026-05-09'],
    'weather_code': <int>[2],
    'temperature_2m_min': <double>[10.5],
    'temperature_2m_max': <double>[20.0],
    'precipitation_sum': <double>[0.0],
    'precipitation_probability_max': <int>[10],
    'wind_speed_10m_max': <double>[15.0],
    'uv_index_max': <double>[6.0],
    'sunrise': <String>['2026-05-09T06:30'],
    'sunset': <String>['2026-05-09T21:00'],
  },
};

void main() {
  late InMemorySpanExporter spans;

  setUpAll(() async {
    spans = await maybeInitializeOtelForTest();
  });

  setUp(() {
    spans.clear();
  });

  group('OpenMeteoProvider.geocode', () {
    test('returns matching cities on a 2xx with results', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'geocoding-api.open-meteo.com');
        expect(req.url.queryParameters['name'], 'Toulouse');
        return http.Response(jsonEncode(_geocodeResponse('Toulouse')), 200);
      });
      final provider = OpenMeteoProvider(client: client);

      final result = await provider.geocode('Toulouse');

      expect(result.isNotEmpty, true);
      expect(result.best.name, 'Toulouse');
      expect(result.best.countryCode, 'FR');

      final span = spans.findSpanByName('open-meteo geocode');
      expect(span, isNotNull);
      expect(span!.kind, SpanKind.client);
    });

    test('returns empty result when 2xx body has no results key', () async {
      final client = MockClient((_) async {
        return http.Response(jsonEncode(<String, dynamic>{}), 200);
      });
      final provider = OpenMeteoProvider(client: client);

      final result = await provider.geocode('Atlantis');

      expect(result.isEmpty, true);
      expect(result.matches, isEmpty);
    });

    test('throws badRequest on empty query without making a request', () async {
      var called = false;
      final client = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      final provider = OpenMeteoProvider(client: client);

      expect(
        () => provider.geocode('   '),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.badRequest,
          ),
        ),
      );
      expect(called, false);
    });

    test('classifies a 5xx as upstream', () async {
      final client = MockClient((_) async {
        return http.Response('boom', 503);
      });
      final provider = OpenMeteoProvider(client: client);

      await expectLater(
        provider.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.upstream,
          ),
        ),
      );
    });

    test('classifies a 429 as rateLimit', () async {
      final client = MockClient((_) async {
        return http.Response('slow down', 429);
      });
      final provider = OpenMeteoProvider(client: client);

      await expectLater(
        provider.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.rateLimit,
          ),
        ),
      );
    });

    test('classifies SocketException as network', () async {
      final client = MockClient((_) async {
        throw const SocketException('connection refused');
      });
      final provider = OpenMeteoProvider(client: client);

      await expectLater(
        provider.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.network,
          ),
        ),
      );
    });

    test('classifies malformed JSON as parse', () async {
      final client = MockClient((_) async {
        return http.Response('not json at all', 200);
      });
      final provider = OpenMeteoProvider(client: client);

      await expectLater(
        provider.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.parse,
          ),
        ),
      );
    });
  });

  group('OpenMeteoProvider.getForecast', () {
    const toulouse = City(
      id: 1,
      name: 'Toulouse',
      latitude: 43.6,
      longitude: 1.44,
      country: 'France',
      countryCode: 'FR',
    );

    test('returns a forecast on a 2xx', () async {
      final client = MockClient((req) async {
        expect(req.url.host, 'api.open-meteo.com');
        expect(req.url.queryParameters['forecast_days'], '3');
        return http.Response(jsonEncode(_forecastResponse()), 200);
      });
      final provider = OpenMeteoProvider(client: client);

      final forecast = await provider.getForecast(
        city: toulouse,
        forecastDays: 3,
      );

      expect(forecast.city, toulouse);
      expect(forecast.daily, hasLength(1));
      expect(forecast.current.weatherCode, WeatherCode.partlyCloudy);

      final span = spans.findSpanByName('open-meteo forecast');
      expect(span, isNotNull);
      expect(span!.kind, SpanKind.client);
    });

    test(
      'rejects out-of-range forecastDays without making a request',
      () async {
        var called = false;
        final client = MockClient((_) async {
          called = true;
          return http.Response('', 200);
        });
        final provider = OpenMeteoProvider(client: client);

        expect(
          () => provider.getForecast(city: toulouse, forecastDays: 100),
          throwsA(
            isA<WeatherProviderException>().having(
              (e) => e.kind,
              'kind',
              WeatherProviderErrorKind.badRequest,
            ),
          ),
        );
        expect(called, false);
      },
    );

    test('classifies 404 as notFound', () async {
      final client = MockClient((_) async {
        return http.Response('not found', 404);
      });
      final provider = OpenMeteoProvider(client: client);

      await expectLater(
        provider.getForecast(city: toulouse, forecastDays: 3),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.notFound,
          ),
        ),
      );
    });
  });
}
