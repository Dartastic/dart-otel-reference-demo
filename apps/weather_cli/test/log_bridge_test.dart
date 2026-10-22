// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// These tests are about capturing print, so they print.
// ignore_for_file: avoid_print

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart' as logging;
import 'package:test/test.dart';
import 'package:weather_cli/weather_cli.dart';

/// Records what reaches the logs pipeline. With [printOnEmit] set it also
/// prints while handling a record, the way a noisy exporter might: the
/// no-loop rule must keep that line from becoming another record.
class _RecordingProcessor extends LogRecordProcessor {
  final List<ReadWriteLogRecord> records = [];
  bool printOnEmit = false;

  @override
  Future<void> onEmit(ReadWriteLogRecord logRecord, Context? context) async {
    records.add(logRecord);
    if (printOnEmit) print('processor saw: ${logRecord.body}');
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

void main() {
  final processor = _RecordingProcessor();
  final console = <String>[];

  /// Runs [body] the way bin/weather.dart does, inside captureConsole,
  /// with the real console swapped for [console].
  Future<void> run(FutureOr<void> Function() body) => runZoned(
    () => captureConsole(() async => body()),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => console.add(line),
    ),
  );

  setUpAll(() async {
    await OTel.initialize(
      serviceName: 'log-bridge-test',
      logRecordProcessor: processor,
      enableMetrics: false,
      detectPlatformResources: false,
    );
    installLogBridgeByHand();
  });

  tearDownAll(() async {
    await uninstallLogBridgeByHand();
    await OTel.shutdown();
  });

  setUp(() {
    processor.records.clear();
    processor.printOnEmit = false;
    console.clear();
  });

  test('a package:logging record becomes an OTel log record', () async {
    await run(() {
      logging.Logger(
        'weather_cli.test',
      ).warning('upstream slow', StateError('timeout'), StackTrace.current);
    });
    await Future<void>.delayed(Duration.zero);
    expect(processor.records, hasLength(1));
    final record = processor.records.single;
    expect(record.body, 'upstream slow');
    expect(record.severityNumber, Severity.WARN);
    final attributes = record.attributes!.toMap();
    expect(
      attributes[ExceptionAttributes.exceptionType.key]?.value,
      'StateError',
    );
    expect(
      attributes.containsKey(ExceptionAttributes.exceptionStacktrace.key),
      isTrue,
    );
  });

  test('print reaches the console and becomes an INFO record', () async {
    await run(() => print('hello'));
    expect(console, ['hello']);
    expect(processor.records.map((r) => r.body), ['hello']);
    expect(processor.records.single.severityNumber, Severity.INFO);
  });

  test('a print while emitting is not captured again: no loop', () async {
    processor.printOnEmit = true;
    await run(() => print('once'));
    expect(processor.records.map((r) => r.body), ['once']);
    expect(console, ['once', 'processor saw: once']);
  });

  test('the SDK diagnostics go to stderr, never to print', () {
    expect(OTelLog.logFunction, isNot(same(print)));
  });
}
