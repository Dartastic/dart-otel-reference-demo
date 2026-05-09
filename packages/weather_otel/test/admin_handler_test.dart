// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// The admin handler is built from a `forceFlush` callback rather than
// the SDK directly, so these tests need no OpenTelemetry initialization.

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
// We import the internal admin handler builder directly. It is not part
// of weather_otel's public surface (the public surface is
// WeatherOtelHandle.demoAdminPipeline), but testing it in isolation
// keeps these tests free of an OTel.initialize call.
import 'package:weather_otel/src/admin_handler.dart';

void main() {
  final log = Logger('admin_handler_test');

  Request _req(String method, String path) {
    return Request(method, Uri.parse('http://admin$path'));
  }

  group('buildDemoAdminHandler', () {
    test('GET /healthz returns 200 with body "ok"', () async {
      final handler = buildDemoAdminHandler(
        forceFlush: () async {},
        logger: log,
      );
      final response = await handler(_req('GET', '/healthz'));
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'ok\n');
    });

    test('POST /flush invokes forceFlush and returns 200', () async {
      var calls = 0;
      final handler = buildDemoAdminHandler(
        forceFlush: () async {
          calls++;
        },
        logger: log,
      );
      final response = await handler(_req('POST', '/flush'));
      expect(calls, 1);
      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'flushed\n');
    });

    test('POST /flush returns 500 when forceFlush throws', () async {
      final handler = buildDemoAdminHandler(
        forceFlush: () async => throw StateError('exporter unreachable'),
        logger: log,
      );
      final response = await handler(_req('POST', '/flush'));
      expect(response.statusCode, 500);
      expect(await response.readAsString(), contains('forceFlush failed'));
    });

    test('GET /flush returns 405 with Allow: POST', () async {
      final handler = buildDemoAdminHandler(
        forceFlush: () async {},
        logger: log,
      );
      final response = await handler(_req('GET', '/flush'));
      expect(response.statusCode, 405);
      expect(response.headers['allow'], 'POST');
    });

    test('POST /healthz returns 405 with Allow: GET', () async {
      final handler = buildDemoAdminHandler(
        forceFlush: () async {},
        logger: log,
      );
      final response = await handler(_req('POST', '/healthz'));
      expect(response.statusCode, 405);
      expect(response.headers['allow'], 'GET');
    });

    test('unknown path returns 404', () async {
      final handler = buildDemoAdminHandler(
        forceFlush: () async {},
        logger: log,
      );
      final response = await handler(_req('GET', '/anything-else'));
      expect(response.statusCode, 404);
    });
  });
}
