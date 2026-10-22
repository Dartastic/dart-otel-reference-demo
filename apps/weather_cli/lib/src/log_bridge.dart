// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.
//
// Logging into the OpenTelemetry Logs signal, wired by hand.
//
// Every other app in this repo uses the published bridge, otel_logging's
// `PackageLoggingBridge.install()`, which is what you should use too. The
// CLI does the same job in plain code, so you can see what the bridge
// does and why each step is there:
//
//   * a `package:logging` listener turns each record into an OTel log
//     record: severity mapped from the level, the error as `exception.*`
//     attributes, and the caller's zone re-entered so the record carries
//     the active span's trace and span ids;
//   * `print` is captured with a Zone override: each line still reaches
//     the console, and also becomes an OTel log record at INFO.
//
// Capturing console output means OTel could end up logging about
// itself, and looping. Three rules stop that:
//
//   1. The OpenTelemetry error handler and the SDK's own diagnostics
//      (`OTelLog.logFunction`) write to stderr, which is never captured:
//      a report that telemetry is failing can't travel over it.
//   2. While a record is being emitted, anything printed in that same
//      call is written to the console but not captured again (a zone
//      flag marks the emit).
//   3. The SDK's own diagnostics are never bridged: rule 1 sends them to
//      stderr instead of `print`, the SDK's default.

import 'dart:async';
import 'dart:io';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart' as logging;

/// The zone key that marks code running inside an emit (rule 2).
final Object _emittingKey = Object();

/// The `package:logging` subscription, while the bridge is installed.
StreamSubscription<logging.LogRecord>? _subscription;

/// Bridges `package:logging` records to the OTel Logs signal, by hand.
/// Call after OTel is initialized; [uninstallLogBridgeByHand] before it
/// shuts down.
void installLogBridgeByHand() {
  // Rules 1 and 3: the SDK's diagnostics go to stderr, never to the
  // captured `print` and so never back into OTel. (weather_otel's
  // bootstrap already installed the error handler, also on stderr.)
  OTelLog.logFunction = stderr.writeln;
  _subscription ??= logging.Logger.root.onRecord.listen(_bridgeRecord);
}

/// Stops bridging. Records logged after this reach only the console.
Future<void> uninstallLogBridgeByHand() async {
  await _subscription?.cancel();
  _subscription = null;
}

/// Runs [body] with `print` captured: each line is written to the
/// console as usual and, while the bridge is installed, also emitted as
/// an OTel log record at INFO.
R captureConsole<R>(R Function() body) => runZoned(
  body,
  zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      // The console always gets the line.
      parent.print(zone, line);
      // Rule 2: a line printed while emitting is not captured again.
      if (_subscription == null || zone[_emittingKey] == true) return;
      _emit(
        loggerName: 'console',
        severity: Severity.INFO,
        body: line,
        zone: zone,
      );
    },
  ),
);

void _bridgeRecord(logging.LogRecord record) {
  final attributes = <String, Object>{
    if (record.error != null) ...{
      ExceptionAttributes.exceptionType.key: '${record.error.runtimeType}',
      ExceptionAttributes.exceptionMessage.key: '${record.error}',
    },
    if (record.stackTrace != null)
      ExceptionAttributes.exceptionStacktrace.key: '${record.stackTrace}',
  };
  _emit(
    loggerName: record.loggerName,
    severity: _severityOf(record.level),
    body: record.message,
    attributes: attributes,
    timeStamp: record.time,
    // package:logging captures the zone the caller logged from. The
    // listener runs in the zone that subscribed, so re-enter the
    // caller's: that is where Context.current holds the active span.
    zone: record.zone,
  );
}

void _emit({
  required String loggerName,
  required Severity severity,
  required String body,
  Map<String, Object> attributes = const {},
  DateTime? timeStamp,
  Zone? zone,
}) {
  // Rule 2: everything this emit does runs with the flag set, so a print
  // anywhere below it is not captured again.
  (zone ?? Zone.current).fork(zoneValues: {_emittingKey: true}).run(() {
    // Telemetry never throws: a failure here is reported to the
    // OpenTelemetry error handler, never thrown into the app.
    try {
      OTel.loggerProvider()
          .getLogger(loggerName.isEmpty ? 'weather_cli' : loggerName)
          .emit(
            timeStamp: timeStamp,
            severityNumber: severity,
            severityText: severity.name,
            body: body,
            attributes: attributes.isEmpty
                ? null
                : OTel.attributesFromMap(attributes),
          );
    } on Object catch (e, st) {
      OTelErrorHandling.report(e, st);
    }
  });
}

/// `package:logging` levels to OTel severities, by the levels' values.
Severity _severityOf(logging.Level level) => switch (level.value) {
  < 500 => Severity.TRACE,
  < 800 => Severity.DEBUG,
  < 900 => Severity.INFO,
  < 1000 => Severity.WARN,
  < 1200 => Severity.ERROR,
  _ => Severity.FATAL,
};
