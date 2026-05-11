// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'dart:async';

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:logging/logging.dart';

/// Runs [body] inside a zone whose uncaught-async-error handler
/// records the exception on the active OpenTelemetry span (if any)
/// and logs it through `package:logging` — which the bridged OTel
/// logs pipeline picks up automatically.
///
/// This is the outermost wrapper every Dart entry point should use.
/// Synchronous `try/catch` doesn't see errors that escape an `await`
/// chain or a callback registered with a third-party library; a
/// zone's `onError` handler does, and it's the last opportunity to
/// attach diagnostic context before the error becomes invisible.
///
/// ```dart
/// void main(List<String> args) {
///   runWithOtelErrorHandlers(() async {
///     // ... initializeOtel, start the server / drive the CLI ...
///   });
/// }
/// ```
///
/// The handler is best-effort and never rethrows. After the
/// observability work runs, control returns to the zone — Dart's
/// default behaviour for a `runZonedGuarded` handler that doesn't
/// throw is to absorb the error.
void runWithOtelErrorHandlers(
  FutureOr<void> Function() body, {
  String loggerName = 'weather_otel.uncaught',
}) {
  final log = Logger(loggerName);
  runZonedGuarded(
    () async {
      await body();
    },
    (error, stack) {
      log.severe('uncaught error escaped to zone handler', error, stack);
      final span = Context.current.span;
      if (span != null) {
        span
          ..recordException(error, stackTrace: stack)
          ..setStatus(.Error, error.toString());
      }
    },
  );
}
