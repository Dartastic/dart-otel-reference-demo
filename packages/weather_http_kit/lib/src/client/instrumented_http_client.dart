// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

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
  static final Logger _log = Logger('weather_http_kit.http');

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
    OTelAPI.textMapPropagator.inject(injectionContext, request.headers, setter);

    // Activate the span for the duration of the inner send. We use
    // `injectionContext.run` rather than `tracer.withSpanAsync` so we own
    // the exception path: `withSpanAsync` auto-records every escaping
    // exception, which would double-record alongside the explicit
    // `recordException` below.
    try {
      return await injectionContext.run(() async {
        try {
          final response = await _inner.send(request);
          _log.info(
            '${request.method} ${request.url} → ${response.statusCode}',
          );
          span.addAttributes(
            OTel.attributesOf<Http>({
              .httpResponseStatusCode: response.statusCode,
              if (response.contentLength != null)
                .httpResponseBodySize: response.contentLength!,
            }),
          );
          // Client spans: >= 400 is Error (the server returned an error to
          // this caller); below that stays Unset.
          if (response.statusCode >= 400) {
            span
              ..setStatus(.Error)
              ..addAttributes(
                OTel.attributesFromSemanticMap({
                  ErrorAttributes.errorType: '${response.statusCode}',
                }),
              );
          }
          return response;
        } catch (e, st) {
          span
            ..recordException(e, stackTrace: st)
            ..setStatus(.Error, e.toString())
            ..addAttributes(
              OTel.attributesFromSemanticMap({
                ErrorAttributes.errorType: e.runtimeType.toString(),
              }),
            );
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
  return OTel.attributesFromSemanticMap({
    ...<Http, Object>{
      .httpRequestMethod: request.method,
      if (request.contentLength != null)
        .httpRequestBodySize: request.contentLength!,
    },
    Url.urlFull: url.toString(),
    Server.serverAddress: url.host,
    if (url.hasPort) Server.serverPort: url.port,
  });
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
