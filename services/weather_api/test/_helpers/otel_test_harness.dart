// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

class InMemorySpanExporter implements SpanExporter {
  final List<Span> _spans = <Span>[];
  bool _isShutdown = false;

  List<Span> get spans => List<Span>.unmodifiable(_spans);
  void clear() => _spans.clear();

  Span? findSpanByName(String name) {
    for (var i = _spans.length - 1; i >= 0; i--) {
      if (_spans[i].name == name) return _spans[i];
    }
    return null;
  }

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

InMemorySpanExporter? _sharedExporter;
Future<InMemorySpanExporter> maybeInitializeOtelForTest() async {
  if (_sharedExporter != null) return _sharedExporter!;
  final exporter = InMemorySpanExporter();
  await OTel.initialize(
    endpoint: 'http://localhost:4317',
    serviceName: 'weather_api_test',
    serviceVersion: '0.0.0-test',
    spanProcessor: SimpleSpanProcessor(exporter),
    // The shelf middleware now emits a duration histogram. With
    // enableMetrics: true (the default) the SDK would auto-create
    // an OTLP exporter pointing at `endpoint`, which doesn't exist
    // in tests — and would log noisy export-failed warnings every
    // export interval. Disable here; the weather_http_kit package's
    // own tests verify the metric is emitted correctly.
    enableMetrics: false,
    detectPlatformResources: false,
  );
  return _sharedExporter = exporter;
}
