// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

// Mirrors weather_core's harness so each package's tests stand on their
// own and can be lifted directly into a reader's project. See DESIGN.md
// § "Testing strategy" at the repository root for the rationale.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';

class InMemorySpanExporter implements SpanExporter {
  final List<Span> _spans = <Span>[];
  bool _isShutdown = false;

  List<Span> get spans => List<Span>.unmodifiable(_spans);
  List<String> get spanNames => _spans.map((s) => s.name).toList();
  void clear() => _spans.clear();

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
