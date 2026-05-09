// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
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

  /// Whether `OTEL_DEMO_MODE=true` was set when the bootstrap ran.
  /// When false, [demoAdminPipeline] returns null and no admin endpoint
  /// is exposed.
  final bool demoModeEnabled;

  final Logger _logger;
  bool _shutdownStarted = false;
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

  /// Forces the configured span processor(s) to flush any buffered spans
  /// to their exporter. Returns when the flush completes or fails.
  ///
  /// Useful in throughput demos and immediately before exit; production
  /// paths should rely on the `BatchSpanProcessor`'s own scheduling.
  Future<void> forceFlush() async {
    final provider = OTel.tracerProvider();
    try {
      await provider.forceFlush();
    } on Object catch (e, st) {
      _logger.warning('forceFlush failed', e, st);
      rethrow;
    }
  }

  /// Flushes pending spans and shuts down the SDK. Idempotent — repeated
  /// calls return immediately without reattempting the work.
  ///
  /// After shutdown, no further spans can be emitted. Wire this to your
  /// process exit hook, or call [attachToProcessLifecycle] to install
  /// the standard SIGTERM / SIGINT handlers.
  Future<void> shutdown() async {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    _logger.info('Shutting down OpenTelemetry SDK for $serviceName');

    await _sigtermSub?.cancel();
    await _sigintSub?.cancel();
    _sigtermSub = null;
    _sigintSub = null;

    final provider = OTel.tracerProvider();
    try {
      await provider.forceFlush();
    } on Object catch (e, st) {
      // Log and continue — we still want to release exporter resources
      // even if the final flush failed.
      _logger.warning('forceFlush during shutdown failed', e, st);
    }
    try {
      await provider.shutdown();
    } on Object catch (e, st) {
      _logger.warning('TracerProvider shutdown failed', e, st);
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
  void attachToProcessLifecycle() {
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
  /// when `OTEL_DEMO_MODE` was not `true` at bootstrap time.
  ///
  /// When non-null, the returned handler responds to:
  ///   * `GET  /healthz`  — readiness probe, always 200.
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
