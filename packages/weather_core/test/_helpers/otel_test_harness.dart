// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Test harness for weather_core. Tests bring up a real OpenTelemetry SDK
// pointed at an in-memory span exporter (and an on-demand metric reader)
// so spans and metrics can be inspected after the system under test runs.
// We do not mock the SDK itself; per DESIGN.md we test against the real
// OTel implementation pointed at a test exporter.
//
// Tests only — never imported from production code.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

class InMemorySpanExporter implements SpanExporter {
  final List<Span> _spans = <Span>[];
  bool _isShutdown = false;

  List<Span> get spans => List<Span>.unmodifiable(_spans);
  List<String> get spanNames => _spans.map((s) => s.name).toList();
  void clear() => _spans.clear();

  Span? findSpanByName(String name) {
    for (var i = _spans.length - 1; i >= 0; i--) {
      if (_spans[i].name == name) return _spans[i];
    }
    return null;
  }

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

class InMemoryMetricExporter implements MetricExporter {
  final List<Metric> _metrics = <Metric>[];
  bool _isShutdown = false;

  List<Metric> get metrics => List<Metric>.unmodifiable(_metrics);
  void clear() => _metrics.clear();

  Metric? findMetricByName(String name) {
    for (var i = _metrics.length - 1; i >= 0; i--) {
      if (_metrics[i].name == name) return _metrics[i];
    }
    return null;
  }

  @override
  Future<bool> export(MetricData data) async {
    if (_isShutdown) return false;
    _metrics.addAll(data.metrics);
    return true;
  }

  @override
  Future<bool> forceFlush() async => !_isShutdown;

  @override
  Future<bool> shutdown() async {
    _isShutdown = true;
    return true;
  }
}

/// On-demand metric reader for tests — never fires on a timer; tests
/// drive `collect()` explicitly via [TestHarness.collectMetrics].
class OnDemandMetricReader extends MetricReader {
  OnDemandMetricReader(this.exporter);

  final MetricExporter exporter;
  bool _isShutdown = false;

  @override
  Future<MetricData> collect() async {
    final mp = meterProvider;
    if (mp == null || _isShutdown) {
      return MetricData.empty();
    }
    final metrics = await mp.collectAllMetrics();
    return MetricData(resource: mp.resource, metrics: metrics);
  }

  @override
  Future<bool> forceFlush() async {
    if (_isShutdown) return false;
    final data = await collect();
    if (data.metrics.isNotEmpty) {
      await exporter.export(data);
    }
    return await exporter.forceFlush();
  }

  @override
  Future<bool> shutdown() async {
    if (_isShutdown) return true;
    _isShutdown = true;
    return await exporter.shutdown();
  }
}

class TestHarness {
  TestHarness({
    required this.spans,
    required this.metrics,
    required this.metricReader,
  });

  final InMemorySpanExporter spans;
  final InMemoryMetricExporter metrics;
  final MetricReader metricReader;

  Future<void> collectMetrics() async {
    final data = await metricReader.collect();
    await metrics.export(data);
  }

  void clear() {
    spans.clear();
    metrics.clear();
  }
}

TestHarness? _shared;
Future<TestHarness> maybeInitializeOtelForTest() async {
  if (_shared != null) return _shared!;
  final spanExporter = InMemorySpanExporter();
  final metricExporter = InMemoryMetricExporter();
  final reader = OnDemandMetricReader(metricExporter);
  await OTel.initialize(
    serviceName: 'weather_core_test',
    serviceVersion: '0.0.0-test',
    spanProcessor: SimpleSpanProcessor(spanExporter),
    metricReader: reader,
    detectPlatformResources: false,
  );
  return _shared = TestHarness(
    spans: spanExporter,
    metrics: metricExporter,
    metricReader: reader,
  );
}
