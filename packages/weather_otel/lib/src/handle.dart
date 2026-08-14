// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:otel_logging/otel_logging.dart';
import 'package:shelf/shelf.dart' show Handler;

import 'admin_handler.dart';

/// Lifecycle handle for an initialized OpenTelemetry SDK.
///
/// Returned by `initializeOtel`. Owns the shutdown path and the
/// (optional) demo admin endpoint.
class WeatherOtelHandle {
  WeatherOtelHandle._({
    required this.serviceName,
    required this.serviceVersion,
    required this.serviceInstanceId,
    required this.demoModeEnabled,
    required Logger logger,
  }) : _logger = logger;

  /// The service name registered with the SDK.
  final String serviceName;

  /// The service version registered with the SDK.
  final String serviceVersion;

  /// A unique id generated for this process. Reported as
  /// `service.instance.id` on every emitted resource.
  final String serviceInstanceId;

  /// Whether `WEATHER_DEMO_MODE=true` was set when the bootstrap ran.
  /// When false, [demoAdminPipeline] returns null and no admin endpoint
  /// is exposed.
  final bool demoModeEnabled;

  final Logger _logger;
  Future<void>? _shutdownFuture;
  Future<void> Function()? _onBeforeShutdown;
  StreamSubscription<ProcessSignal>? _sigtermSub;
  StreamSubscription<ProcessSignal>? _sigintSub;

  @internal
  static WeatherOtelHandle internalCreate({
    required String serviceName,
    required String serviceVersion,
    required String serviceInstanceId,
    required bool demoModeEnabled,
    required Logger logger,
  }) => WeatherOtelHandle._(
    serviceName: serviceName,
    serviceVersion: serviceVersion,
    serviceInstanceId: serviceInstanceId,
    demoModeEnabled: demoModeEnabled,
    logger: logger,
  );

  /// Forces every span processor (and meter / log processor) to flush
  /// buffered data to its exporter. Returns when the flush completes
  /// or fails.
  ///
  /// Useful in throughput demos and immediately before exit; production
  /// paths should rely on the batch processors' own scheduling.
  Future<void> forceFlush() async {
    try {
      await OTel.tracerProvider().forceFlush();
      await OTel.meterProvider().forceFlush();
      await OTel.loggerProvider().forceFlush();
    } on Object catch (e, st) {
      _logger.warning('forceFlush failed', e, st);
      rethrow;
    }
  }

  /// Flushes pending telemetry and shuts down the SDK. Idempotent — the
  /// first call runs the work; concurrent or later calls await the same
  /// in-flight completion rather than returning early or re-running.
  Future<void> shutdown() => _shutdownFuture ??= _doShutdown();

  Future<void> _doShutdown() async {
    _logger.info('Shutting down OpenTelemetry SDK for $serviceName');

    await _sigtermSub?.cancel();
    await _sigintSub?.cancel();
    _sigtermSub = null;
    _sigintSub = null;

    // Let the app drain first (e.g. close HTTP servers so in-flight
    // request spans end) before anything is flushed.
    final beforeShutdown = _onBeforeShutdown;
    if (beforeShutdown != null) {
      try {
        await beforeShutdown();
      } on Object catch (e, st) {
        _logger.warning('onBeforeShutdown hook failed', e, st);
      }
    }

    // Uninstall the package:logging → OTel bridge BEFORE shutting the
    // SDK down, so records emitted during/after shutdown (including
    // our own messages below) never hit a dead logs pipeline.
    await PackageLoggingBridge.uninstall();

    try {
      await OTel.shutdown();
    } on Object catch (e, st) {
      _logger.warning('OTel.shutdown failed', e, st);
    }
    _logger.info('OpenTelemetry SDK shutdown complete');
  }

  /// Installs SIGTERM and SIGINT handlers that run [shutdown] and then
  /// terminate the process with `exit(0)`. Idempotent.
  ///
  /// Cloud Run and Cloud Functions Gen 2 both deliver SIGTERM ~10s
  /// before forcibly killing the container — that window is enough for
  /// `BatchSpanProcessor` to flush.
  ///
  /// Call this once near process startup, after `initializeOtel`. Skip
  /// it in tests; let the test runner own process lifetime.
  void attachToProcessLifecycle({Future<void> Function()? onBeforeShutdown}) {
    _onBeforeShutdown = onBeforeShutdown;
    _sigtermSub ??= ProcessSignal.sigterm.watch().listen(_onSignal);
    _sigintSub ??= ProcessSignal.sigint.watch().listen(_onSignal);
  }

  Future<void> _onSignal(ProcessSignal signal) async {
    _logger.info('Received ${signal.toString()}, shutting down OpenTelemetry');
    await shutdown();
    // exit(0) so the process terminates cleanly even if other code in
    // the isolate is still running. Ignore _shutdownStarted — once a
    // signal has been observed, we always want to exit.
    exit(0);
  }

  /// Returns the shelf handler for the demo's admin endpoint, or null
  /// when `WEATHER_DEMO_MODE` was not `true` at bootstrap time.
  ///
  /// When non-null, the returned handler responds to:
  ///   * `GET  /health`  — readiness probe, always 200.
  ///   * `POST /flush`    — runs [forceFlush] and returns 200, or 500 on
  ///                        flush failure with a brief diagnostic body.
  ///
  /// Mount this on a private port (e.g., `127.0.0.1:8081`) — never on
  /// the public service port — so the flush endpoint can never be
  /// reached from outside the host.
  Handler? demoAdminPipeline() => demoModeEnabled
      ? buildDemoAdminHandler(forceFlush: forceFlush, logger: _logger)
      : null;
}
