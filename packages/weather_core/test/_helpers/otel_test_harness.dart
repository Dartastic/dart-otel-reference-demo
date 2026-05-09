// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Test harness for weather_core. Tests bring up a real OpenTelemetry SDK
// with an in-memory span exporter so spans can be inspected after the
// system under test runs. We do not mock the SDK itself; per DESIGN.md we
// test against the real OTel implementation pointed at a test exporter.
//
// Tests only — never imported from production code.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// In-memory `SpanExporter` that captures every exported span for later
/// inspection in tests. Modeled after the SDK's own `InMemorySpanExporter`
/// (in `dartastic_opentelemetry/test/testing_utils/`). Reproduced here as a
/// standalone helper because that one is not part of the published API.
class InMemorySpanExporter implements SpanExporter {
  final List<Span> _spans = <Span>[];
  bool _isShutdown = false;

  /// All spans captured since the last `clear()`.
  List<Span> get spans => List<Span>.unmodifiable(_spans);

  /// All captured span names, in export order.
  List<String> get spanNames => _spans.map((s) => s.name).toList();

  /// Discard the captured spans. Call this in `setUp` to isolate tests.
  void clear() => _spans.clear();

  /// Return the most recent span with [name], or null if none.
  Span? findSpanByName(String name) {
    for (var i = _spans.length - 1; i >= 0; i--) {
      if (_spans[i].name == name) return _spans[i];
    }
    return null;
  }

  /// Return all spans with [name], in export order.
  List<Span> findSpansByName(String name) =>
      _spans.where((s) => s.name == name).toList(growable: false);

  @override
  Future<void> export(List<Span> spans) async {
    if (_isShutdown) {
      throw StateError('InMemorySpanExporter is shutdown');
    }
    _spans.addAll(spans);
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    _isShutdown = true;
  }
}

/// Initializes the OpenTelemetry SDK for a test suite.
///
/// Returns the [InMemorySpanExporter] so tests can inspect captured spans.
/// Use `SimpleSpanProcessor` (synchronous export per span) so spans are
/// available immediately after the system under test returns — no need to
/// await a flush. This is the one place `SimpleSpanProcessor` is acceptable;
/// see DESIGN.md "Non-goals." Production paths use `BatchSpanProcessor`.
///
/// `OTel.initialize()` may only be called once per process. Tests that
/// share a process must share this initialization — call it from a single
/// `setUpAll` in a top-level test runner, or use [maybeInitializeOtel] to
/// make it idempotent.
Future<InMemorySpanExporter> initializeOtelForTest({
  String serviceName = 'weather_core_test',
  String serviceVersion = '0.0.0-test',
}) async {
  final exporter = InMemorySpanExporter();
  await OTel.initialize(
    endpoint: 'http://localhost:4317',
    serviceName: serviceName,
    serviceVersion: serviceVersion,
    spanProcessor: SimpleSpanProcessor(exporter),
    detectPlatformResources: false,
  );
  return exporter;
}

/// Idempotent variant — initializes only if no SDK has been registered yet.
/// Useful when several test files share a process.
InMemorySpanExporter? _sharedExporter;
Future<InMemorySpanExporter> maybeInitializeOtelForTest() async {
  return _sharedExporter ??= await initializeOtelForTest();
}
