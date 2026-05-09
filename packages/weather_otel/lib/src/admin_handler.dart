// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

/// Builds the shelf handler exposed by `WeatherOtelHandle.demoAdminPipeline`
/// when `OTEL_DEMO_MODE=true`.
///
/// Routes:
///   * `GET  /healthz`  — always 200 for liveness / readiness probes.
///   * `POST /flush`    — calls [forceFlush] and returns 200 on success,
///                        500 with a short diagnostic body on failure.
///   * Anything else    — 404.
///
/// Methods other than `GET` on `/healthz` and `POST` on `/flush` return
/// 405 with an `Allow` header. The handler does NOT use the OpenTelemetry
/// shelf middleware — admin requests should not appear in the trace tree
/// they are flushing.
Handler buildDemoAdminHandler({
  required Future<void> Function() forceFlush,
  required Logger logger,
}) {
  return (Request request) async {
    final path = request.url.path;
    final method = request.method;

    if (path == 'healthz') {
      if (method != 'GET') {
        return Response(
          405,
          headers: <String, String>{'allow': 'GET'},
          body: 'Method Not Allowed',
        );
      }
      return Response.ok('ok\n');
    }

    if (path == 'flush') {
      if (method != 'POST') {
        return Response(
          405,
          headers: <String, String>{'allow': 'POST'},
          body: 'Method Not Allowed',
        );
      }
      try {
        await forceFlush();
        return Response.ok('flushed\n');
      } on Object catch (e, st) {
        logger.warning('admin /flush failed', e, st);
        return Response.internalServerError(body: 'forceFlush failed: $e\n');
      }
    }

    return Response.notFound('Not Found');
  };
}
