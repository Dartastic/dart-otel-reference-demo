// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Bridge from `package:logging` records into the OTel logs SDK.
//
// The Dartastic SDK (1.1.0-beta) ships a `DartLogBridge` for
// `dart:developer.log` and a `logPrint: true` flag on
// `OTel.initialize` for `print()`. There is no built-in equivalent
// for `package:logging` — which is what every Dart server library and
// every Flutter app uses for its own logs.
//
// Without this bridge, log records emitted via `Logger('foo').info(…)`
// reach stdout (or whatever the application's `Logger.root.onRecord`
// listener writes them to) but DO NOT flow over OTLP. In Tempo's UI
// the trace→logs button reads "No log volumes available" because Loki
// never sees a log record correlated to the trace.
//
// The right long-term home for this is the SDK, behind a one-flag
// `OTel.initialize(bridgePackageLogging: true)` and an env-var
// equivalent. Tracking issue:
// https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry/issues/32
// When that ships, this file goes away — `weather_otel` will set
// the flag and stop owning the level mapping.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart' as dart_logging;

/// Subscribes to `Logger.root.onRecord` and emits each record through
/// the OTel logs SDK.
///
/// Returns the `StreamSubscription` so callers can cancel during
/// shutdown. The bootstrap doesn't bother — the subscription's
/// lifetime is the process lifetime.
///
/// Trace context correlation is automatic: `OTelLogger.emit` reads
/// `Context.current` for the active span, so any record emitted from
/// inside a span (handler code, business logic) lands in Loki with
/// the trace_id and span_id of that span attached.
///
/// Each `package:logging` `Logger` becomes its own OTel
/// instrumentation scope by name (`Logger('weather_api.router')` →
/// scope `weather_api.router`), so backends that group by scope can
/// see which logger emitted what without parsing the message.
///
/// The application's own `Logger.root.onRecord` listeners (typically
/// the one that pretty-prints to stdout) keep firing — this bridge is
/// additive, not a replacement. That matters on Cloud Run and Cloud
/// Functions where the platform also collects stdout.
void bridgePackageLoggingToOtel() {
  dart_logging.Logger.root.onRecord.listen((record) {
    final scope = record.loggerName.isNotEmpty ? record.loggerName : 'app';
    final logger = OTel.logger(scope);
    final severity = _severityFor(record.level);

    final attrMap = <String, Object>{};
    if (record.error != null) {
      attrMap['exception.type'] = record.error.runtimeType.toString();
      attrMap['exception.message'] = record.error.toString();
    }
    if (record.stackTrace != null) {
      attrMap['exception.stacktrace'] = record.stackTrace.toString();
    }

    logger.emit(
      timeStamp: record.time,
      severityNumber: severity,
      severityText: record.level.name,
      body: record.message,
      attributes: attrMap.isEmpty ? null : OTel.attributesFromMap(attrMap),
    );
  });
}

/// Maps `package:logging`'s `Level` values to OpenTelemetry severities.
///
/// The boundary chosen at each step matches the SDK's own
/// `DartLogBridge._levelToSeverity` so the two bridges stay
/// behaviorally consistent: a record at level 800 (INFO) lands at
/// `Severity.INFO` whether it came from `dart:developer.log(level:
/// 800)` or `Logger('x').info('…')`.
Severity _severityFor(dart_logging.Level level) {
  final v = level.value;
  if (v < 300) return Severity.TRACE;
  if (v < 500) return Severity.TRACE2;
  if (v < 700) return Severity.DEBUG;
  if (v < 800) return Severity.DEBUG2;
  if (v < 900) return Severity.INFO;
  if (v < 1000) return Severity.WARN;
  if (v < 1200) return Severity.ERROR;
  return Severity.FATAL;
}
