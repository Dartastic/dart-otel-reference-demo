// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:meta/meta.dart';

/// Categories of provider failure. Each kind is a stable, low-cardinality
/// value suitable for use as a metric attribute — callers can safely emit
/// `weather.error.kind` on a counter or histogram.
enum WeatherProviderErrorKind {
  /// Transport-layer failure: connection refused, DNS, TLS, timeout.
  network,

  /// Upstream returned a 5xx or otherwise indicated server-side failure.
  upstream,

  /// Upstream returned a 4xx other than 404 — usually a malformed request.
  badRequest,

  /// Upstream responded successfully but the lookup returned no match
  /// (e.g. an unknown city name).
  notFound,

  /// Upstream rate-limited us — 429 or equivalent.
  rateLimit,

  /// Upstream returned a 200 with a payload we could not parse — this is
  /// usually an upstream contract change.
  parse,

  /// Anything else.
  unknown,
}

/// An error from a `WeatherProvider`. Includes the originating cause and
/// stack trace where available so they can be attached to spans via
/// `span.recordException`.
@immutable
class WeatherProviderException implements Exception {
  const WeatherProviderException({
    required this.kind,
    required this.message,
    this.providerName,
    this.statusCode,
    this.cause,
    this.causeStackTrace,
  });

  /// Bounded category — safe as a metric label.
  final WeatherProviderErrorKind kind;

  /// Human-readable message. May contain query-specific or upstream-specific
  /// detail; do **not** put on metrics.
  final String message;

  /// The provider that raised the error, e.g. `"open-meteo"`. Bounded —
  /// safe as a metric label.
  final String? providerName;

  /// HTTP status code if the failure came from a response.
  final int? statusCode;

  /// Underlying exception if any, preserved so it can be recorded on the span.
  final Object? cause;
  final StackTrace? causeStackTrace;

  @override
  String toString() {
    final parts = <String>[
      'WeatherProviderException(${kind.name}',
      if (providerName != null) 'provider=$providerName',
      if (statusCode != null) 'status=$statusCode',
      'message=$message',
    ];
    final result = StringBuffer(parts.join(', '));
    result.write(')');
    if (cause != null) {
      result
        ..write('\n  caused by: ')
        ..write(cause);
    }
    return result.toString();
  }
}
