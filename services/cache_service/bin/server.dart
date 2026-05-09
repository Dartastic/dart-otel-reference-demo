// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.
//
// cache_service server entry point.
//
// Composes weather_otel (SDK bootstrap + lifecycle), weather_http_kit
// (instrumented HTTP client), weather_core (OpenMeteoProvider as the
// upstream), and the v1 router with TTL caches into a deployable HTTP
// service.
//
// Configuration via environment:
//
//   PORT             — public service port (default 8090)
//   ADMIN_PORT       — admin port (default 8091), only bound when
//                      OTEL_DEMO_MODE=true
//   ADMIN_HOST       — interface to bind the admin port to (default
//                      127.0.0.1). Override to 0.0.0.0 when running
//                      inside a container so Docker port mapping can
//                      reach the port.
//   OTEL_DEMO_MODE   — when 'true', enables the demo admin endpoint
//   FORECAST_TTL_SECONDS — forecast cache TTL in seconds (default 300)
//   GEOCODE_TTL_SECONDS  — geocode cache TTL in seconds (default 86400)
//   OTEL_*           — standard OTel env vars. See weather_otel README.

import 'dart:async';
import 'dart:io';

import 'package:cache_service/cache_service.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:weather_core/weather_core.dart';
import 'package:weather_http_kit/weather_http_kit.dart';
import 'package:weather_otel/weather_otel.dart';

const String _serviceName = 'cache-service';
const String _serviceVersion = '0.1.0';

Future<void> main(List<String> _) async {
  _configureLogging();
  final log = Logger('cache_service.main');

  final otel = await initializeOtel(
    serviceName: _serviceName,
    serviceVersion: _serviceVersion,
  );
  otel.attachToProcessLifecycle();

  final outboundClient = InstrumentedHttpClient(
    inner: http.Client(),
    tracerName: 'cache_service.http',
  );
  final upstream = OpenMeteoProvider(client: outboundClient);

  final forecastTtl = Duration(
    seconds: _envInt('FORECAST_TTL_SECONDS', defaultForecastTtl.inSeconds),
  );
  final geocodeTtl = Duration(
    seconds: _envInt('GEOCODE_TTL_SECONDS', defaultGeocodeTtl.inSeconds),
  );
  log.info(
    'cache TTLs: forecast=${forecastTtl.inSeconds}s geocode=${geocodeTtl.inSeconds}s',
  );

  final pipeline = buildCacheServicePipeline(
    upstream: upstream,
    forecastCache: TtlCache<ForecastKey, WeatherForecast>(ttl: forecastTtl),
    geocodeCache: TtlCache<GeocodeKey, GeocodeResult>(ttl: geocodeTtl),
  );

  final port = _envInt('PORT', 8090);
  final publicServer = await shelf_io.serve(pipeline, '0.0.0.0', port);
  publicServer.autoCompress = true;
  log.info(
    'cache_service listening on http://${publicServer.address.host}:${publicServer.port}',
  );

  HttpServer? adminServer;
  final adminHandler = otel.demoAdminPipeline();
  if (adminHandler != null) {
    final adminPort = _envInt('ADMIN_PORT', 8091);
    final adminHost = Platform.environment['ADMIN_HOST'] ?? '127.0.0.1';
    adminServer = await shelf_io.serve(adminHandler, adminHost, adminPort);
    log.info(
      'cache_service admin endpoint listening on '
      'http://${adminServer.address.host}:${adminServer.port} '
      '(OTEL_DEMO_MODE=true)',
    );
  }

  await _blockForever();

  // Unreachable — the signal handler exits the process — but kept
  // visible so static analysis sees the close calls.
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
    if (record.error != null) stdout.writeln('  error: ${record.error}');
    if (record.stackTrace != null)
      stdout.writeln('  stack:\n${record.stackTrace}');
  });
}

int _envInt(String key, int defaultValue) {
  final raw = Platform.environment[key];
  if (raw == null) return defaultValue;
  return int.tryParse(raw) ?? defaultValue;
}

Future<void> _blockForever() => Completer<void>().future;
