// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Per-package test harness; intentionally a near-duplicate of the
// equivalents in weather_core, weather_http_kit, and weather_otel so
// each package's tests stand on their own and can be lifted directly
// into a reader's project. See DESIGN.md § "Testing strategy" at the
// repository root for the rationale.

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
/// drive `collect()` explicitly via [TestHarness.collectMetrics]. See
/// weather_http_kit's harness for the longer comment on why this
/// shape exists.
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
    serviceName: 'cache_service_test',
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
