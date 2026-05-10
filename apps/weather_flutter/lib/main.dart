// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Simplest Flutter web/wasm client for the demo's v1 weather API.
//
// What this demonstrates:
//   * The Dartastic OpenTelemetry SDK runs in a browser (dart2js
//     and dart2wasm). 1.1.0-beta.2 is the first SDK release where
//     this is supported.
//   * The same `InstrumentedHttpClient` used server-side runs
//     unchanged in the browser — propagating W3C trace context and
//     baggage on every outbound request.
//   * Trace context flows from the user's tap all the way through
//     weather_api → cache_service → Open-Meteo. The full trace tree
//     appears in the backend with the Flutter span as the root.
//
// What this is NOT:
//   * A full Flutter integration with the OTel SDK. That's
//     [Flutterrific OpenTelemetry][flutterrific] — automatic
//     navigator-observer spans, route-template extraction, error-
//     boundary widgets, frame-timing metrics. Those land in the
//     `flutterrific_opentelemetry_pro` package as part of
//     Dartastic.io Pro. This demo uses the SDK directly so the
//     reader can see exactly which line does what.
//
// [flutterrific]: https://github.com/MindfulSoftwareLLC/flutterrific_opentelemetry

import 'dart:convert';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:weather_core/weather_core.dart';
import 'package:weather_http_kit/weather_http_kit.dart';

const String _serviceName = 'weather-flutter';
const String _serviceVersion = '0.1.0';

// The weather_api endpoint. When running locally with
// `tool/stack.sh up`, weather_api listens on :8080 and exposes
// `GET /weather/<city>?days=N`.
const String _defaultApiBaseUrl = 'http://localhost:8080';

// OTLP HTTP endpoint. Browsers can't speak gRPC, so we use
// HTTP/protobuf. The local Grafana LGTM stack accepts OTLP HTTP on
// :4318. To send to Cloud Operations, Honeycomb, Dartastic Cloud, or
// any other OTLP-HTTP backend, change this URL — no other code
// change.
const String _defaultOtlpEndpoint = 'http://localhost:4318';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Browsers can't speak OTLP gRPC, so the exporter must use OTLP/HTTP.
  // The SDK reads `OTEL_EXPORTER_OTLP_PROTOCOL` from the env when set;
  // browsers have no env at runtime, so the SDK falls back to its
  // default (http/protobuf) — which is exactly what we want. The
  // default endpoint is also http://localhost:4318, matching Grafana
  // LGTM's OTLP HTTP port. We pass it explicitly so the demo's reader
  // sees the URL without having to know the default.
  await OTel.initialize(
    serviceName: _serviceName,
    serviceVersion: _serviceVersion,
    endpoint: _defaultOtlpEndpoint,
    secure: false,
  );

  runApp(const WeatherDemoApp());
}

class WeatherDemoApp extends StatelessWidget {
  const WeatherDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dart OTel Demo — Flutter client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const WeatherHomePage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class WeatherHomePage extends StatefulWidget {
  const WeatherHomePage({super.key});

  @override
  State<WeatherHomePage> createState() => _WeatherHomePageState();
}

class _WeatherHomePageState extends State<WeatherHomePage> {
  final _cityController = TextEditingController(text: 'Toulouse');
  late final http.Client _httpClient;
  late final Tracer _tracer;

  WeatherForecast? _forecast;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();

    // InstrumentedHttpClient adds a SpanKind.client span per
    // outbound HTTP request and injects W3C trace context + baggage
    // into the headers — that's what stitches the Flutter app's
    // trace tree to the weather_api server span.
    _httpClient = InstrumentedHttpClient(
      inner: http.Client(),
      tracerName: 'weather_flutter.http',
    );

    _tracer = OTel.tracerProvider().getTracer('weather_flutter');
  }

  Future<void> _fetchWeather() async {
    final city = _cityController.text.trim();
    if (city.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    // Wrap the user-initiated action in a span. This becomes the
    // root of the trace tree; weather_api's server span attaches as
    // a child, then cache_service's, then the open-meteo client
    // span. One trace_id, four levels deep, originating in the
    // user's tap.
    final span = _tracer.startSpan(
      'fetchWeather',
      kind: SpanKind.internal,
      attributes: OTel.attributesFromMap(<String, Object>{
        'app.action': 'fetch_weather',
        'app.input.city': city,
      }),
    );

    try {
      // `withSpan(span).run` activates the span on the current
      // Context for the duration of the async call. The
      // InstrumentedHttpClient's outbound request reads
      // `Context.current` and uses it as the parent — that's the
      // mechanic that links the trace tree across the HTTP boundary.
      final forecast = await Context.current
          .withSpan(span)
          .run(() => _getForecast(city: city, forecastDays: 3));
      span.setStatus(.Ok);
      if (!mounted) return;
      setState(() {
        _forecast = forecast;
        _loading = false;
      });
    } catch (e, st) {
      span
        ..recordException(e, stackTrace: st)
        ..setStatus(.Error, e.toString());
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
      span.end();
    }
  }

  /// Hits the demo's public `GET /weather/<city>?days=N` endpoint and
  /// decodes the response into a [WeatherForecast]. Kept inline rather
  /// than calling `WeatherClient` because the public weather_api
  /// endpoint is the user-facing route — what curl, the Flutter
  /// client, and any other consumer of the demo's public API uses.
  Future<WeatherForecast> _getForecast({
    required String city,
    required int forecastDays,
  }) async {
    final uri = Uri.parse(
      '$_defaultApiBaseUrl/weather/${Uri.encodeComponent(city)}'
      '?days=$forecastDays',
    );
    final response = await _httpClient.get(uri);
    if (response.statusCode != 200) {
      throw HttpException(
        'weather_api returned ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return WeatherForecast.fromJson(decoded);
  }

  @override
  void dispose() {
    _cityController.dispose();
    _httpClient.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dart OTel Demo — Flutter client')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _cityController,
                  decoration: const InputDecoration(
                    labelText: 'City',
                    hintText: 'e.g. Toulouse, Paris, Tokyo',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _fetchWeather(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loading ? null : _fetchWeather,
                  child: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Get weather'),
                ),
                const SizedBox(height: 24),
                if (_error != null) _ErrorCard(message: _error!),
                if (_forecast != null) _ForecastCard(forecast: _forecast!),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.forecast});

  final WeatherForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = forecast.current;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${forecast.city.name}, ${forecast.city.country}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${current.temperatureCelsius.toStringAsFixed(1)}°C',
                  style: theme.textTheme.displaySmall,
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    current.weatherCode.name,
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Text('Forecast', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            ...forecast.daily.map(
              (day) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        '${day.date.month}/${day.date.day}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        day.weatherCode.name,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${day.temperatureMinCelsius.toStringAsFixed(0)}'
                      '–'
                      '${day.temperatureMaxCelsius.toStringAsFixed(0)}°C',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}

/// Minimal exception type for non-2xx responses. Plain `Exception` is
/// fine for a demo; production code would map to a typed error.
class HttpException implements Exception {
  HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
