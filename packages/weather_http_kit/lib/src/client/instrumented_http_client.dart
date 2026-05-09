// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    show TextMapSetter;
import 'package:http/http.dart' as http;

/// An [http.Client] decorator that emits a `SpanKind.client` span for every
/// outbound request, injects W3C trace context and baggage into the
/// request headers, and sets HTTP client semantic-convention attributes.
///
/// The decorated [inner] client may be any [http.Client] — production
/// `IOClient`, a test `MockClient`, or another decorator. The decorated
/// client owns the underlying socket; this wrapper only forwards.
///
/// Usage:
///
/// ```dart
/// final client = InstrumentedHttpClient(inner: http.Client());
/// final response = await client.get(Uri.parse('https://example.com/'));
/// ```
///
/// The application is responsible for initializing the OpenTelemetry SDK
/// before any request is sent through this client.
class InstrumentedHttpClient extends http.BaseClient {
  /// Creates a new instrumented client wrapping [inner].
  ///
  /// [tracerName] is the instrumentation library name reported on emitted
  /// spans. The default is appropriate for general application code.
  InstrumentedHttpClient({
    required http.Client inner,
    String tracerName = 'weather_http_kit',
  }) : _inner = inner,
       _tracerName = tracerName;

  final http.Client _inner;
  final String _tracerName;

  // Singletons — the propagators are stateless and cheap to construct,
  // but caching is the OTel convention and avoids per-request allocations.
  // `static final` rather than `static const` because the SDK's
  // W3CTraceContextPropagator and W3CBaggagePropagator classes don't
  // expose const constructors.
  static final _traceContextPropagator = W3CTraceContextPropagator();
  static final _baggagePropagator = W3CBaggagePropagator();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final tracer = OTel.tracerProvider().getTracer(_tracerName);

    // Span name per OTel HTTP semconv for client spans: the request method
    // alone. The URL goes into attributes — keeping it out of the name
    // means span-name cardinality is bounded by the small set of HTTP
    // methods, which is what every backend wants.
    final span = tracer.startSpan(
      request.method,
      kind: SpanKind.client,
      attributes: _clientRequestAttributes(request),
    );

    // Inject trace context and baggage with the new span active. We start
    // from `Context.current` (which already carries any baggage set by the
    // calling code) and overlay the new span — that way both the parent
    // chain and the calling baggage flow downstream.
    final injectionContext = Context.current.withSpan(span);
    final setter = _RequestHeaderSetter(request);
    _traceContextPropagator.inject(injectionContext, request.headers, setter);
    _baggagePropagator.inject(injectionContext, request.headers, setter);

    // Activate the span for the duration of the inner send. We use
    // `injectionContext.run` rather than `tracer.withSpanAsync` so we own
    // the exception path: `withSpanAsync` auto-records every escaping
    // exception, which would double-record alongside the explicit
    // `recordException` below.
    try {
      return await injectionContext.run(() async {
        try {
          final response = await _inner.send(request);
          span
            ..addAttributes(
              OTel.attributesFromMap(<String, Object>{
                HttpResource.responseStatusCode.key: response.statusCode,
                if (response.contentLength != null)
                  HttpResource.responseBodySize.key: response.contentLength!,
              }),
            )
            ..setStatus(_statusForCode(response.statusCode));
          return response;
        } catch (e, st) {
          span
            ..recordException(e, stackTrace: st)
            ..setStatus(SpanStatusCode.Error, e.toString());
          rethrow;
        }
      });
    } finally {
      span.end();
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

Attributes _clientRequestAttributes(http.BaseRequest request) {
  final url = request.url;
  final attrs = <String, Object>{
    HttpResource.requestMethod.key: request.method,
    UrlResource.urlFull.key: url.toString(),
    ServerResource.serverAddress.key: url.host,
  };
  if (url.hasPort) {
    attrs[ServerResource.serverPort.key] = url.port;
  }
  if (request.contentLength != null) {
    attrs[HttpResource.requestBodySize.key] = request.contentLength!;
  }
  return OTel.attributesFromMap(attrs);
}

/// Maps HTTP client response status to a span status. For client spans the
/// OTel HTTP semconv treats 4xx-and-up as errors (the server returned an
/// error to *this* caller, regardless of whose fault it is).
SpanStatusCode _statusForCode(int statusCode) {
  if (statusCode >= 400) return SpanStatusCode.Error;
  return SpanStatusCode.Ok;
}

/// Adapter that lets a propagator write into a [http.BaseRequest]'s
/// header map. [http.BaseRequest.headers] is a mutable map, so the setter
/// just writes to it directly.
class _RequestHeaderSetter implements TextMapSetter<String> {
  _RequestHeaderSetter(this._request);

  final http.BaseRequest _request;

  @override
  void set(String key, String value) {
    _request.headers[key] = value;
  }
}
