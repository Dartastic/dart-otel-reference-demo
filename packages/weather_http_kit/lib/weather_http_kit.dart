// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

/// HTTP instrumentation kit for the Dart OTel demo.
///
/// Provides:
/// - [otelMiddleware] — shelf middleware that emits a server span per
///   request and extracts W3C trace context and baggage from inbound
///   headers.
/// - [InstrumentedHttpClient] — `http.Client` decorator that emits a
///   client span per request and injects W3C trace context and baggage
///   into outbound headers.
///
/// The application is responsible for initializing the OpenTelemetry SDK
/// (`OTel.initialize(...)`) before using either.
library;

export 'src/client/instrumented_http_client.dart' show InstrumentedHttpClient;
export 'src/middleware/otel_middleware.dart'
    show RouteResolver, ServerSpanNamer, otelMiddleware;
