// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart';

import 'handle.dart';
import 'package_logging_bridge.dart';

/// Default sampling ratio applied to root spans when no `samplingRatio`
/// is provided and `OTEL_TRACES_SAMPLER_ARG` is not set in the
/// environment. Sample everything by default — easy to lower for
/// production via configuration.
const double defaultSamplingRatio = 1.0;

/// Initializes the OpenTelemetry SDK for an application binary.
///
/// Returns a [WeatherOtelHandle] that owns the lifecycle. The caller is
/// expected to either call [WeatherOtelHandle.attachToProcessLifecycle]
/// (recommended for long-running services) or to invoke
/// [WeatherOtelHandle.shutdown] explicitly before exit.
///
/// The bootstrap is opinionated about a handful of choices the demo's
/// architecture document calls "production-grade defaults":
///
///   * Span processor — `BatchSpanProcessor`. The demo never uses
///     `SimpleSpanProcessor` outside of tests; it spends synchronization
///     time on every span end where a batch processor amortizes it. To
///     override (e.g., from tests), pass `spanProcessor:` explicitly.
///   * Sampler — `ParentBasedSampler(TraceIdRatioSampler(samplingRatio))`.
///     The OpenTelemetry-spec default is `parentbased_always_on`, but
///     ratio-based root sampling is what production deployments tune.
///     Pass `samplingRatio: 1.0` (the default) to sample everything.
///   * Service identity — `service.name` and `service.version` from the
///     parameters; `service.instance.id` generated as a UUID v4 from
///     `Random.secure()`. Backends use the instance id to distinguish
///     replicas in a horizontally-scaled deployment.
///   * `package:logging` bridge — every record emitted via
///     `Logger('foo').info(…)` is forwarded through the OTel logs SDK
///     so entries flow over OTLP with the active span's trace_id /
///     span_id attached. The application's own `Logger.root.onRecord`
///     listener (typically the one printing to stdout) keeps firing.
///     Pass `bridgePackageLogging: false` to opt out. Convenience
///     belongs in the SDK; tracking issue:
///     https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/32
///   * `BaggageSpanProcessor` — every entry in `Context.current.baggage`
///     is copied onto each starting span as a string attribute. This
///     is what makes low-cardinality baggage entries (like a
///     `cli.run_id` set once at the CLI's entry point) searchable on
///     every span across the trace tree without manual enrichment.
///     Pass `attachBaggageToSpans: false` to opt out — primarily
///     useful in tests that want to assert raw span attributes
///     without baggage interference.
///
/// Endpoint, protocol, headers, and additional resource attributes
/// resolve from the standard `OTEL_*` environment variables — no custom
/// env vars are introduced. Switch backends (stdout, Grafana LGTM,
/// Cloud Operations, Dartastic Cloud) via `OTEL_EXPORTER_OTLP_ENDPOINT`
/// and `OTEL_EXPORTER_OTLP_PROTOCOL` alone.
///
/// Demo affordance: when the environment has `OTEL_DEMO_MODE=true`, the
/// returned handle's `demoAdminPipeline()` returns a shelf handler that
/// exposes `POST /flush` and `GET /healthz`. Mount it on a private
/// admin port; never on the public-facing service port. When the env is
/// unset, `demoAdminPipeline()` returns null and the admin endpoint is
/// never built.
Future<WeatherOtelHandle> initializeOtel({
  required String serviceName,
  required String serviceVersion,
  String? serviceNamespace,
  Map<String, Object>? extraResourceAttributes,
  double? samplingRatio,
  SpanProcessor? spanProcessor,
  Sampler? sampler,
  bool bridgePackageLogging = true,
  bool attachBaggageToSpans = true,
  Map<String, String> environment = const <String, String>{},
}) async {
  final logger = Logger('weather_otel.bootstrap');

  // Read configuration from the supplied environment map first, then
  // fall back to the real process environment. The map argument exists
  // for tests that want to drive `OTEL_DEMO_MODE` and the sampler arg
  // without touching the real environment.
  String? envLookup(String key) =>
      environment[key] ?? Platform.environment[key];

  final demoModeEnabled =
      (envLookup('OTEL_DEMO_MODE')?.toLowerCase() ?? '') == 'true';

  // Resolve the sampling ratio. Explicit arg > env > default.
  final resolvedSamplingRatio =
      samplingRatio ??
      _parseDouble(envLookup('OTEL_TRACES_SAMPLER_ARG')) ??
      defaultSamplingRatio;

  if (resolvedSamplingRatio < 0.0 || resolvedSamplingRatio > 1.0) {
    throw ArgumentError.value(
      resolvedSamplingRatio,
      'samplingRatio',
      'must be between 0.0 and 1.0 inclusive',
    );
  }

  // Generate the per-process instance id. Using Random.secure() so we
  // do not have to add a uuid dependency for what is fundamentally a
  // 16-byte random identifier.
  final instanceId = _generateUuidV4();

  // Build resource attributes. We DO NOT use ServiceResource.serviceName
  // / serviceVersion enum keys here because OTel.initialize already
  // applies those from the explicit serviceName / serviceVersion
  // parameters. Adding them to resourceAttributes would conflict.
  final resourceAttrs = <String, Object>{
    'service.instance.id': instanceId,
    if (serviceNamespace != null) 'service.namespace': serviceNamespace,
    ...?extraResourceAttributes,
  };

  // Effective sampler. Caller's > built-from-ratio.
  final effectiveSampler =
      sampler ?? ParentBasedSampler(TraceIdRatioSampler(resolvedSamplingRatio));

  await OTel.initialize(
    serviceName: serviceName,
    serviceVersion: serviceVersion,
    resourceAttributes: resourceAttrs.isEmpty
        ? null
        : OTel.attributesFromMap(resourceAttrs),
    spanProcessor: spanProcessor,
    sampler: effectiveSampler,
  );

  // Register a BaggageSpanProcessor in addition to whatever the SDK
  // wired up via spanProcessor: above (default is BatchSpanProcessor
  // around the OTLP exporter). The BaggageSpanProcessor only runs in
  // onStart — it copies every entry in Context.current.baggage onto
  // the starting span as a string attribute. That makes low-
  // cardinality baggage entries (e.g. cli.run_id, cli.session_id,
  // request_id, tenant) searchable on every span across the trace
  // tree without per-span manual enrichment in handler code.
  // Cardinality discipline is the caller's responsibility — only put
  // bounded values into baggage. See DESIGN.md § Cardinality
  // discipline.
  if (attachBaggageToSpans) {
    OTel.tracerProvider().addSpanProcessor(const BaggageSpanProcessor());
  }

  // Bridge `package:logging` records into the OTel logs SDK so log
  // entries land in the configured backend (Loki, Cloud Logging,
  // Dartastic Cloud, etc.) with the active span's trace_id/span_id
  // attached. The application's own `Logger.root.onRecord` listeners
  // (typically the one printing to stdout) keep firing — this is
  // additive. See package_logging_bridge.dart for the SDK-issue
  // tracking move of this convenience into the SDK itself.
  if (bridgePackageLogging) {
    bridgePackageLoggingToOtel();
  }

  logger.info(
    'OpenTelemetry initialized: service=$serviceName v$serviceVersion '
    'instance=$instanceId samplingRatio=$resolvedSamplingRatio '
    '${demoModeEnabled ? "(demo mode)" : ""}',
  );

  return WeatherOtelHandle.internalCreate(
    serviceName: serviceName,
    serviceVersion: serviceVersion,
    serviceInstanceId: instanceId,
    demoModeEnabled: demoModeEnabled,
    logger: logger,
  );
}

double? _parseDouble(String? raw) {
  if (raw == null) return null;
  return double.tryParse(raw.trim());
}

/// Generates a RFC 4122 v4 UUID using `Random.secure()`.
///
/// Hand-rolled to avoid pulling a `uuid` dependency for a single
/// allocation per process. Output format:
/// `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx` where `y` is one of
/// `8, 9, a, b`.
String _generateUuidV4() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  // Set version (4) and variant (10xx) bits per RFC 4122.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final s = bytes.map(hex).join();
  return '${s.substring(0, 8)}-'
      '${s.substring(8, 12)}-'
      '${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-'
      '${s.substring(20, 32)}';
}
