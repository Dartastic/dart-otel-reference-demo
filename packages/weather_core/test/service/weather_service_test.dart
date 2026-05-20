// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:test/test.dart';
import 'package:weather_core/weather_core.dart';

import '../_helpers/otel_test_harness.dart';

/// Hand-rolled fake — using a dedicated class instead of a mocking library
/// keeps the test self-contained and obvious to read on the blog.
class FakeWeatherProvider implements WeatherProvider {
  GeocodeResult Function(String query, int maxResults)? geocodeImpl;
  WeatherForecast Function(City city, int forecastDays)? forecastImpl;

  Object? geocodeError;
  Object? forecastError;

  @override
  String get name => 'fake';

  @override
  Future<GeocodeResult> geocode(String query, {int maxResults = 5}) async {
    if (geocodeError != null) throw geocodeError!;
    final fn = geocodeImpl;
    if (fn == null) {
      throw StateError('geocodeImpl not set on FakeWeatherProvider');
    }
    return fn(query, maxResults);
  }

  @override
  Future<WeatherForecast> getForecast({
    required City city,
    required int forecastDays,
  }) async {
    if (forecastError != null) throw forecastError!;
    final fn = forecastImpl;
    if (fn == null) {
      throw StateError('forecastImpl not set on FakeWeatherProvider');
    }
    return fn(city, forecastDays);
  }
}

void main() {
  late TestHarness harness;
  late InMemorySpanExporter spans;
  late FakeWeatherProvider provider;
  late WeatherService service;

  setUpAll(() async {
    harness = await maybeInitializeOtelForTest();
    spans = harness.spans;
  });

  setUp(() {
    harness.clear();
    provider = FakeWeatherProvider();
    service = WeatherService(provider: provider);
  });

  const boston = City(
    id: 1,
    name: 'Boston',
    latitude: 43.6,
    longitude: 1.44,
    country: 'France',
    countryCode: 'FR',
  );
  const paris = City(
    id: 2,
    name: 'Paris',
    latitude: 48.85,
    longitude: 2.35,
    country: 'France',
    countryCode: 'FR',
  );

  WeatherForecast _forecastFor(City city, int days) {
    return WeatherForecast(
      city: city,
      current: CurrentWeather(
        observedAt: DateTime.utc(2026, 5, 9, 12),
        temperatureCelsius: 18.0,
        apparentTemperatureCelsius: 17.0,
        relativeHumidityPercent: 60,
        windSpeedKmh: 10.0,
        windDirectionDegrees: 270,
        precipitationMm: 0.0,
        weatherCode: WeatherCode.partlyCloudy,
        isDay: true,
      ),
      daily: List<DailyForecast>.generate(
        days,
        (i) => DailyForecast(
          date: DateTime.utc(2026, 5, 9 + i),
          weatherCode: WeatherCode.partlyCloudy,
          temperatureMinCelsius: 10.0,
          temperatureMaxCelsius: 20.0,
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
  }

  group('WeatherService.getForecast', () {
    test('returns the forecast on the happy path', () async {
      provider.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [boston]);
      provider.forecastImpl = _forecastFor;

      final forecast = await service.getForecast(
        cityName: 'Boston',
        forecastDays: 3,
      );

      expect(forecast.city, boston);
      expect(forecast.daily, hasLength(3));

      final span = spans.findSpanByName('WeatherService.getForecast');
      expect(span, isNotNull);
      expect(span!.status, SpanStatusCode.Ok);
    });

    test(
      'emits geocode.no_matches event and throws notFound when empty',
      () async {
        provider.geocodeImpl = (q, _) =>
            GeocodeResult(query: q, matches: const []);

        await expectLater(
          service.getForecast(cityName: 'Atlantis', forecastDays: 3),
          throwsA(
            isA<WeatherProviderException>().having(
              (e) => e.kind,
              'kind',
              WeatherProviderErrorKind.notFound,
            ),
          ),
        );

        final span = spans.findSpanByName('WeatherService.getForecast');
        expect(span, isNotNull);
        expect(
          span!.spanEvents?.any((e) => e.name == 'geocode.no_matches'),
          true,
        );
        expect(span.status, SpanStatusCode.Error);
      },
    );

    test('on ambiguous geocode, emits event and uses first match', () async {
      provider.geocodeImpl = (q, _) =>
          GeocodeResult(query: q, matches: const [boston, paris]);
      provider.forecastImpl = _forecastFor;

      final forecast = await service.getForecast(
        cityName: 'Toul',
        forecastDays: 1,
      );

      expect(forecast.city, boston);
      final span = spans.findSpanByName('WeatherService.getForecast');
      expect(span, isNotNull);
      expect(span!.spanEvents?.any((e) => e.name == 'geocode.ambiguous'), true);
    });

    test('records exception and rethrows on provider error', () async {
      provider.geocodeError = const WeatherProviderException(
        kind: WeatherProviderErrorKind.upstream,
        providerName: 'fake',
        message: 'upstream is down',
      );

      await expectLater(
        service.getForecast(cityName: 'X', forecastDays: 1),
        throwsA(
          isA<WeatherProviderException>().having(
            (e) => e.kind,
            'kind',
            WeatherProviderErrorKind.upstream,
          ),
        ),
      );

      final span = spans.findSpanByName('WeatherService.getForecast');
      expect(span, isNotNull);
      expect(span!.status, SpanStatusCode.Error);
      // The exception is recorded as an `exception` event per OTel spec.
      expect(span.spanEvents?.any((e) => e.name == 'exception'), true);
    });
  });
}
