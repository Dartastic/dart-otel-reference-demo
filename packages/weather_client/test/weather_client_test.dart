// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:weather_client/weather_client.dart';
import 'package:weather_core/weather_core.dart';

void main() {
  Uri baseUrl = Uri.parse('http://cache-service:8090');

  // ---------- Test fixtures ----------

  const toulouse = City(
    id: 2972315,
    name: 'Toulouse',
    latitude: 43.604,
    longitude: 1.444,
    country: 'France',
    countryCode: 'FR',
  );

  WeatherForecast _sampleForecast(City city, int days) => WeatherForecast(
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

  group('WeatherClient.geocode', () {
    test('GET /v1/geocode and parses the matches list', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/v1/geocode');
        expect(request.url.queryParameters['q'], 'Toulouse');
        expect(request.url.queryParameters['limit'], '5');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'query': 'Toulouse',
            'matches': <Map<String, dynamic>>[toulouse.toJson()],
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);

      final result = await client.geocode('Toulouse');

      expect(result.matches, hasLength(1));
      expect(result.matches.first, toulouse);
      expect(result.query, 'Toulouse');
    });

    test('passes through maxResults as the limit query parameter', () async {
      final mock = MockClient((request) async {
        expect(request.url.queryParameters['limit'], '12');
        return http.Response(
          jsonEncode(<String, dynamic>{'query': 'q', 'matches': <dynamic>[]}),
          200,
        );
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await client.geocode('q', maxResults: 12);
    });

    test('rejects an empty query without making a request', () async {
      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('', 200);
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      expect(
        () => client.geocode('   '),
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

    test('throws parse on missing matches array', () async {
      final mock = MockClient((_) async {
        return http.Response(jsonEncode(<String, dynamic>{'query': 'x'}), 200);
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.geocode('x'),
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

  group('WeatherClient.getForecast', () {
    test('POSTs JSON body and parses the WeatherForecast response', () async {
      final expected = _sampleForecast(toulouse, 2);
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/forecast');
        expect(request.headers['content-type'], contains('application/json'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['forecastDays'], 2);
        expect(body['city'], toulouse.toJson());
        return http.Response(
          jsonEncode(expected.toJson()),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);

      final actual = await client.getForecast(city: toulouse, forecastDays: 2);

      expect(actual, expected);
    });

    test('throws parse on missing required field in response body', () async {
      final mock = MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'city': toulouse.toJson(),
            // 'current' missing
            'daily': <dynamic>[],
            'fetchedAt': '2026-05-09T12:00:00Z',
          }),
          200,
        );
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.getForecast(city: toulouse, forecastDays: 1),
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

  group('HTTP status mapping', () {
    Future<void> _assertStatusMapsToKind(
      int statusCode,
      WeatherProviderErrorKind kind,
    ) async {
      final mock = MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{'message': 'upstream said no'}),
          statusCode,
        );
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.geocode('x'),
        throwsA(
          isA<WeatherProviderException>()
              .having((e) => e.kind, 'kind ($statusCode)', kind)
              .having(
                (e) => e.message,
                'message',
                contains('upstream said no'),
              ),
        ),
      );
    }

    test(
      '400 -> badRequest',
      () => _assertStatusMapsToKind(400, WeatherProviderErrorKind.badRequest),
    );
    test(
      '404 -> notFound',
      () => _assertStatusMapsToKind(404, WeatherProviderErrorKind.notFound),
    );
    test(
      '429 -> rateLimit',
      () => _assertStatusMapsToKind(429, WeatherProviderErrorKind.rateLimit),
    );
    test(
      '500 -> upstream',
      () => _assertStatusMapsToKind(500, WeatherProviderErrorKind.upstream),
    );
    test(
      '502 -> upstream',
      () => _assertStatusMapsToKind(502, WeatherProviderErrorKind.upstream),
    );
    test(
      '503 -> network',
      () => _assertStatusMapsToKind(503, WeatherProviderErrorKind.network),
    );
    test(
      '418 -> unknown',
      () => _assertStatusMapsToKind(418, WeatherProviderErrorKind.unknown),
    );
  });

  group('Network errors', () {
    test('SocketException -> network', () async {
      final mock = MockClient((_) async {
        throw const SocketException('connection refused');
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.network,
          ),
        ),
      );
    });

    test('http.ClientException -> network', () async {
      final mock = MockClient((_) async {
        throw http.ClientException('peer reset');
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.network,
          ),
        ),
      );
    });
  });

  group('Body parsing', () {
    test('non-JSON body -> parse', () async {
      final mock = MockClient((_) async {
        return http.Response('not json', 200);
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.geocode('x'),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.parse,
          ),
        ),
      );
    });

    test('JSON body that is not an object -> parse', () async {
      final mock = MockClient((_) async {
        return http.Response('[1,2,3]', 200);
      });
      final client = WeatherClient(baseUrl: baseUrl, client: mock);
      await expectLater(
        client.geocode('x'),
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
}
