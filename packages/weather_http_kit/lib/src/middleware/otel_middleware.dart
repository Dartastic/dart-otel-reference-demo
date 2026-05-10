// Licensed under the Apache License, Version 2.0.
// Copyright 2026, Mindful Software LLC.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart'
    show TextMapGetter;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

/// Optional callback that lets the application provide a more specific
/// span name than the default. Receives the inbound [Request] and should
/// return either the span name (e.g. `'GET /weather/:city'`) or null
/// to fall back to the default (`'<METHOD>'` or `'<METHOD> <route>'`).
typedef ServerSpanNamer = String? Function(Request request);

/// Optional callback that lets the application advertise a low-cardinality
/// route template for [HttpResource.httpRoute] (e.g. `'/weather/:city'`
/// rather than `'/weather/Toulouse'`). High-cardinality URLs as
/// `http.route` will explode metric series.
typedef RouteResolver = String? Function(Request request);

/// Builds shelf middleware that creates a `SpanKind.server` span around
/// every request, extracts W3C trace context and baggage from inbound
/// headers, and sets HTTP semantic-convention attributes.
///
/// Usage:
///
/// ```dart
/// final pipeline = const Pipeline()
///     .addMiddleware(otelMiddleware())
///     .addHandler(router.call);
/// ```
///
/// The application is responsible for initializing the OpenTelemetry SDK
/// before any request reaches this middleware (see the `weather_otel`
/// bootstrap helper).
Middleware otelMiddleware({
  String tracerName = 'weather_http_kit',
  ServerSpanNamer? spanNamer,
  RouteResolver? routeResolver,
}) {
  final log = Logger('weather_http_kit.otelMiddleware');

  return (Handler innerHandler) {
    // Set up the duration histogram once per pipeline construction —
    // not per request. The OTel SDK is expected to be initialized
    // before the middleware is wrapped (server bootstrap calls
    // `initializeOtel` first). The metric name and unit follow the
    // OTel HTTP semantic conventions for `http.server.request.duration`;
    // when exported via OTLP and translated to Prometheus the name
    // becomes `http_server_request_duration_seconds` (plus `_bucket`,
    // `_count`, `_sum` for the histogram series).
    final meter = OTel.meter(tracerName);
    final durationHistogram = meter.createHistogram<double>(
      name: 'http.server.request.duration',
      unit: 's',
      description:
          'Duration of HTTP server requests in seconds (per OTel HTTP '
          'semantic conventions). Labels are deliberately low-cardinality '
          'so the series count stays bounded: only http.request.method, '
          'http.route, http.response.status_code, and url.scheme.',
    );
    // Saturation proxy alongside the RED-style duration histogram.
    // Per OTel HTTP semconv `http.server.active_requests` is an
    // UpDownCounter incremented when a request starts and
    // decremented when it ends. We deliberately exclude
    // `http.response.status_code` from the label set (the request
    // is in flight so there isn't one yet) — same shape as the
    // duration histogram minus that one label, ensuring cardinality
    // stays bounded. The instrument's running value is "how many
    // requests are this service handling RIGHT NOW" — a clean
    // saturation panel on the dashboard.
    final activeRequests = meter.createUpDownCounter<int>(
      name: 'http.server.active_requests',
      unit: '{request}',
      description:
          'Number of HTTP server requests currently in flight, per OTel '
          'HTTP semantic conventions. Labels: http.request.method, '
          'http.route, url.scheme — same low-cardinality bounded set '
          'as http.server.request.duration minus http.response.status_code '
          '(no status code yet — the request is in flight).',
    );

    return (Request request) async {
      final tracer = OTel.tracerProvider().getTracer(tracerName);

      // ── 1. Extract trace context and baggage from inbound headers.
      // The SDK's W3CTraceContextPropagator and W3CBaggagePropagator
      // don't expose const constructors — instances are stateless and
      // cheap to construct, but cannot be stored as `static const`.
      //
      // Order matters: baggage first, then trace context. In
      // dartastic_opentelemetry 1.1.0-beta the W3CBaggagePropagator's
      // extract returns a fresh empty Context when the inbound request
      // has no `baggage` header (instead of the input context unchanged),
      // which would clobber any spanContext we extracted before it. The
      // trace context propagator, by contrast, preserves the input
      // context when traceparent is missing, so running it second is
      // safe under either inbound combination.
      final getter = _RequestHeaderGetter(request.headers);
      var inboundContext = W3CBaggagePropagator().extract(
        OTel.context(),
        request.headers,
        getter,
      );
      inboundContext = W3CTraceContextPropagator().extract(
        inboundContext,
        request.headers,
        getter,
      );

      // ── 2. Build attributes and start the server span. The SDK uses
      //     `context:` for parent-span lineage AND for the trace ID, so
      //     this links the new span to the upstream caller's trace.
      final route = routeResolver?.call(request);
      final method = request.method;
      final spanName =
          spanNamer?.call(request) ??
          (route != null ? '$method $route' : method);

      final span = tracer.startSpan(
        spanName,
        kind: SpanKind.server,
        context: inboundContext,
        attributes: _serverRequestAttributes(request, route: route),
      );

      // Stopwatch starts AFTER context extraction and span construction
      // so we measure the handler's wall-clock cost, not the
      // middleware's own overhead. Monotonic clock — safe across NTP
      // adjustments.
      final stopwatch = Stopwatch()..start();
      // Status code captured during response handling so the metric
      // can be tagged with it. Stays null if the handler throws before
      // setting a status; the metric record at the bottom of `finally`
      // treats null as 500 (uncaught exception → server error, which
      // is what most HTTP frameworks would surface).
      int? observedStatusCode;

      // Increment the in-flight gauge before the handler runs and
      // decrement in `finally` so even handlers that throw decrement
      // back to zero. Built once per request to share between the
      // inc/dec calls so they always carry the same attribute set —
      // a mismatch here would leak series and prevent the gauge from
      // ever returning to its baseline.
      final activeAttrs = _activeRequestAttributes(request, route: route);
      activeRequests.add(1, activeAttrs);

      // ── 3. Run the handler in a zone whose Context is
      //     `inboundContext.withSpan(span)`. Two reasons we don't use
      //     `tracer.withSpanAsync` here:
      //       1. `withSpanAsync` activates `Context.current.withSpan(span)`,
      //          which would discard the inbound baggage we just extracted
      //          (Context.current at this point is empty).
      //       2. `withSpanAsync` auto-records every escaping exception and
      //          sets status Error. That conflicts with our handling of
      //          HijackException (control flow, not an error) and would
      //          double-record for genuine errors that we want to log
      //          and annotate ourselves.
      try {
        return await inboundContext.withSpan(span).run(() async {
          try {
            final response = await innerHandler(request);
            observedStatusCode = response.statusCode;
            span
              ..addAttributes(
                OTel.attributesFromMap(<String, Object>{
                  HttpResource.responseStatusCode.key: response.statusCode,
                }),
              )
              ..setStatus(_statusForCode(response.statusCode));
            return response;
          } on HijackException {
            // Handler took over the underlying socket; we can't observe
            // the response. Treat this as a successful exit.
            span.setStatus(SpanStatusCode.Ok);
            rethrow;
          } catch (e, st) {
            log.warning('Handler threw an exception', e, st);
            span
              ..recordException(e, stackTrace: st)
              ..setStatus(SpanStatusCode.Error, e.toString());
            rethrow;
          }
        });
      } finally {
        stopwatch.stop();
        span.end();
        // Decrement the in-flight gauge with the SAME attribute set
        // we used on the increment. The gauge tracks "right now,
        // how many?" — any mismatched attributes would leave a
        // permanent +1 on a series that no decrement ever reaches.
        activeRequests.add(-1, activeAttrs);
        // Record the duration metric LAST so even handlers that throw
        // contribute to the latency distribution and error-rate
        // dashboards. Attribute set is the low-cardinality subset —
        // see `_metricAttributes`.
        durationHistogram.record(
          stopwatch.elapsedMicroseconds / 1000000.0,
          _metricAttributes(
            request,
            route: route,
            statusCode: observedStatusCode ?? 500,
          ),
        );
      }
    };
  };
}

/// Builds the attribute set for an inbound HTTP request following the
/// OpenTelemetry HTTP semantic conventions.
///
/// Notes on attribute choice:
///   * `url.path` carries the request path (low-cardinality bucketing
///     comes from `http.route`).
///   * `url.query` is included when present so it is visible on traces;
///     it is NOT used as a metric attribute.
///   * `client.address` uses shelf's connection info if available;
///     otherwise omitted.
Attributes _serverRequestAttributes(Request request, {String? route}) {
  final url = request.requestedUri;
  final attrs = <String, Object>{
    HttpResource.requestMethod.key: request.method,
    UrlResource.urlPath.key: url.path,
    UrlResource.urlScheme.key: url.scheme,
    ServerResource.serverAddress.key: url.host,
  };
  if (url.hasPort) {
    attrs[ServerResource.serverPort.key] = url.port;
  }
  if (url.hasQuery && url.query.isNotEmpty) {
    attrs[UrlResource.urlQuery.key] = url.query;
  }
  if (route != null && route.isNotEmpty) {
    attrs[HttpResource.httpRoute.key] = route;
  }
  final userAgent = request.headers['user-agent'];
  if (userAgent != null && userAgent.isNotEmpty) {
    attrs['user_agent.original'] = userAgent;
  }
  // Shelf does not expose peer address directly; the application can add
  // a small middleware to inject it from `request.context['shelf.io.connection_info']`
  // when running on dart:io. We leave that out here to keep the middleware
  // free of platform-specific code.
  return OTel.attributesFromMap(attrs);
}

/// Builds the LOW-cardinality attribute set used as labels on the
/// `http.server.request.duration` histogram. Distinct from the span
/// attributes (which can be high-cardinality — they're per-request) —
/// metric labels become Prometheus series, so each unique combination
/// is a permanent commitment to storage and query cost.
///
/// Included:
///   * `http.request.method` — bounded set (GET, POST, PUT, …)
///   * `http.route` — the route TEMPLATE supplied by the application,
///     never the concrete path (`'/weather/:city'`, not
///     `'/weather/Toulouse'`). When the route resolver returns null —
///     for unmatched paths or routes the application chose not to
///     advertise — we fall back to the literal string `'unknown'`
///     rather than dropping the dimension entirely; missing labels in
///     Prometheus break aggregation queries.
///   * `http.response.status_code` — bounded set (handful of 2xx,
///     4xx, 5xx that any given service actually emits).
///   * `url.scheme` — http or https; effectively a constant per
///     deployment.
///
/// Deliberately excluded from metrics (they would explode cardinality):
///   * `url.path` — high-cardinality, and the route template carries
///     the equivalent low-cardinality bucketing already.
///   * `url.query`, `user_agent.original`, `client.address` — all
///     unbounded.
///   * `server.address`, `server.port` — usually constant per
///     deployment but redundant with the per-target `service.name`
///     resource attribute the SDK already carries.
Attributes _metricAttributes(
  Request request, {
  required String? route,
  required int statusCode,
}) {
  return OTel.attributesFromMap(<String, Object>{
    HttpResource.requestMethod.key: request.method,
    HttpResource.httpRoute.key: route ?? 'unknown',
    HttpResource.responseStatusCode.key: statusCode,
    UrlResource.urlScheme.key: request.requestedUri.scheme,
  });
}

/// Bounded label set for the in-flight gauge. Same shape as
/// [_metricAttributes] without `http.response.status_code` — the
/// request is in flight, no status code yet. Per OTel HTTP semconv
/// for `http.server.active_requests`.
Attributes _activeRequestAttributes(Request request, {required String? route}) {
  return OTel.attributesFromMap(<String, Object>{
    HttpResource.requestMethod.key: request.method,
    HttpResource.httpRoute.key: route ?? 'unknown',
    UrlResource.urlScheme.key: request.requestedUri.scheme,
  });
}

/// Maps an HTTP status code to a `SpanStatusCode` per the OTel HTTP
/// semantic conventions: 4xx is Unset (callers' bad requests are not
/// the server's fault), 5xx is Error, otherwise Ok.
SpanStatusCode _statusForCode(int statusCode) {
  if (statusCode >= 500) return SpanStatusCode.Error;
  return SpanStatusCode.Ok;
}

/// Adapter that lets [W3CTraceContextPropagator] read from a
/// case-insensitive HTTP header map.
class _RequestHeaderGetter implements TextMapGetter<String> {
  _RequestHeaderGetter(this._headers);

  final Map<String, String> _headers;

  @override
  String? get(String key) {
    // Shelf header maps are case-insensitive but we query by both the
    // canonical lowercase key (W3C uses lowercase header names) and the
    // raw key for safety.
    return _headers[key] ?? _headers[key.toLowerCase()];
  }

  @override
  Iterable<String> keys() => _headers.keys;
}
