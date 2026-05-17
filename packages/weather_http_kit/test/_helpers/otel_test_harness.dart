// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Test harness for weather_http_kit. Mirrors weather_core's harness —
// reproduced here rather than shared so each package's tests stand on
// their own and can be lifted directly into a reader's project.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

/// Captures every exported `Span` for inspection in tests.
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

/// In-memory metric exporter — same pattern as the span exporter
/// above. Tests pull metrics by calling [OtelTestHarness.collectMetrics]
/// which triggers the reader's collect cycle.
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

/// On-demand metric reader for tests. Unlike
/// [PeriodicExportingMetricReader] it never fires on a timer — tests
/// drive `collect()` explicitly. Pairing it with [InMemoryMetricExporter]
/// keeps tests synchronous and stops the SDK from auto-creating an
/// OTLP exporter pointing at an endpoint that doesn't exist.
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

/// Bundle returned from [maybeInitializeOtelForTest] so tests can
/// reach both spans and metrics through one handle.
class OtelTestHarness {
  OtelTestHarness({
    required this.spans,
    required this.metrics,
    required this.metricReader,
  });

  final InMemorySpanExporter spans;
  final InMemoryMetricExporter metrics;
  final MetricReader metricReader;

  /// Forces one collect cycle on the metric reader, then exports the
  /// result into [metrics]. Tests call this AFTER exercising the code
  /// path under test — the reader's auto-export cadence is too slow
  /// to rely on in a unit test.
  Future<void> collectMetrics() async {
    final data = await metricReader.collect();
    await metrics.export(data);
  }

  /// Convenience for the common per-test reset.
  void clear() {
    spans.clear();
    metrics.clear();
  }
}

OtelTestHarness? _shared;

/// Idempotent — initializes only on the first call. Safe to call from
/// every test file's `setUpAll`.
Future<OtelTestHarness> maybeInitializeOtelForTest() async {
  if (_shared != null) return _shared!;
  final spanExporter = InMemorySpanExporter();
  final metricExporter = InMemoryMetricExporter();
  // On-demand reader — see [OnDemandMetricReader]. Wiring it explicitly
  // via `metricReader:` stops the SDK from auto-creating an OTLP metric
  // exporter pointing at `endpoint` (which in tests doesn't exist),
  // which would otherwise log noisy export-failed warnings every
  // export interval.
  final reader = OnDemandMetricReader(metricExporter);
  await OTel.initialize(
    serviceName: 'weather_http_kit_test',
    serviceVersion: '0.0.0-test',
    spanProcessor: SimpleSpanProcessor(spanExporter),
    metricReader: reader,
    detectPlatformResources: false,
  );
  _shared = OtelTestHarness(
    spans: spanExporter,
    metrics: metricExporter,
    metricReader: reader,
  );
  return _shared!;
}
