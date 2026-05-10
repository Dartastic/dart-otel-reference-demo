// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.
//
// weather_api server entry point.
//
// Composes weather_otel (SDK bootstrap + lifecycle), weather_http_kit
// (instrumented HTTP client), and weather_core (WeatherService +
// OpenMeteoProvider) into a deployable HTTP service.
//
// Configuration via environment:
//
//   PORT                  — public service port (default 8080)
//   ADMIN_PORT            — admin port (default 8081), only bound when
//                           OTEL_DEMO_MODE=true
//   ADMIN_HOST            — interface to bind the admin port to
//                           (default 127.0.0.1). Override to 0.0.0.0
//                           when running inside a container so Docker
//                           port mapping can reach the port.
//   OTEL_DEMO_MODE        — when 'true', enables the demo admin endpoint
//   WEATHER_UPSTREAM_URL  — base URL of the v1 upstream service, default
//                           http://localhost:8090 (cache_service's
//                           default). The upstream MUST speak the
//                           contract documented in
//                           packages/weather_client/README.md.
//   OTEL_*                — standard OTel env vars (endpoint, protocol,
//                           headers, sampler args). See weather_otel README.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:weather_api/weather_api.dart';
import 'package:weather_client/weather_client.dart';
import 'package:weather_core/weather_core.dart';
import 'package:weather_http_kit/weather_http_kit.dart';
import 'package:weather_otel/weather_otel.dart';

const String _serviceName = 'weather-api';
const String _serviceVersion = '0.1.0';
const String _defaultUpstreamUrl = 'http://localhost:8090';

Future<void> main(List<String> _) async {
  _configureLogging();
  final log = Logger('weather_api.main');

  final otel = await initializeOtel(
    serviceName: _serviceName,
    serviceVersion: _serviceVersion,
  );
  otel.attachToProcessLifecycle();

  // Outbound HTTP client. Wrapping the standard client in
  // InstrumentedHttpClient adds a `SpanKind.client` span per outbound
  // request and injects W3C trace context + baggage into the headers
  // — that is what stitches weather_api's server span to
  // cache_service's server span as a parent-child link in the trace.
  final outboundClient = InstrumentedHttpClient(
    inner: http.Client(),
    tracerName: 'weather_api.http',
  );

  // Upstream is cache_service (or anything else that speaks the v1
  // wire-format contract documented in
  // packages/weather_client/README.md). WeatherClient implements
  // WeatherProvider, so it slots into WeatherService unchanged.
  final upstreamUrl = Uri.parse(
    Platform.environment['WEATHER_UPSTREAM_URL'] ?? _defaultUpstreamUrl,
  );
  log.info('upstream weather provider: $upstreamUrl');
  // tokenProvider attaches a Cloud Run service-account ID token to
  // every outbound request when running on Cloud Run (`K_SERVICE`
  // env var present); a no-op otherwise. Required when cache-service
  // is deployed `--no-allow-unauthenticated` — the standard
  // production posture for an internal-only service. Locally, the
  // demo's docker-compose stack doesn't set K_SERVICE, so this
  // resolves to `null` and no Authorization header is attached.
  final provider = WeatherClient(
    baseUrl: upstreamUrl,
    client: outboundClient,
    providerName: 'cache-service',
    tokenProvider: cloudRunIdTokenProvider(audience: upstreamUrl),
  );
  final service = WeatherService(provider: provider);

  final pipeline = buildWeatherApiPipeline(service: service);

  final port = _envInt('PORT', 8080);
  final publicServer = await shelf_io.serve(pipeline, '0.0.0.0', port);
  publicServer.autoCompress = true;
  log.info(
    'weather_api listening on http://${publicServer.address.host}:${publicServer.port}',
  );

  // Demo admin server. Only binds when OTEL_DEMO_MODE=true; production
  // deployments leave the port closed.
  HttpServer? adminServer;
  final adminHandler = otel.demoAdminPipeline();
  if (adminHandler != null) {
    final adminPort = _envInt('ADMIN_PORT', 8081);
    final adminHost = Platform.environment['ADMIN_HOST'] ?? '127.0.0.1';
    adminServer = await shelf_io.serve(adminHandler, adminHost, adminPort);
    log.info(
      'weather_api admin endpoint listening on '
      'http://${adminServer.address.host}:${adminServer.port} '
      '(OTEL_DEMO_MODE=true)',
    );
  }

  // Block forever. SIGTERM / SIGINT handling is owned by
  // WeatherOtelHandle.attachToProcessLifecycle, which flushes spans
  // before exit.
  await _blockForever();

  // Unreachable in practice — the signal handler exits the process —
  // but kept so static analysis sees the close calls.
  await publicServer.close();
  await adminServer?.close();
  outboundClient.close();
}

void _configureLogging() {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String();
    final tag = '[${record.level.name}] ${record.loggerName}';
    stdout.writeln('$time $tag: ${record.message}');
    if (record.error != null) {
      stdout.writeln('  error: ${record.error}');
    }
    if (record.stackTrace != null) {
      stdout.writeln('  stack:\n${record.stackTrace}');
    }
  });
}

int _envInt(String key, int defaultValue) {
  final raw = Platform.environment[key];
  if (raw == null) return defaultValue;
  return int.tryParse(raw) ?? defaultValue;
}

Future<void> _blockForever() {
  final completer = Completer<void>();
  // Never completed — the SIGTERM handler installed by
  // attachToProcessLifecycle will exit the process.
  return completer.future;
}
