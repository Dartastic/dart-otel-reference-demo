# weather_http_kit

Shelf middleware and an instrumented `http.Client` wrapper that carry
OpenTelemetry trace context and baggage across HTTP boundaries. Used by
every Dart service and CLI in the demo.

## What's in here

- **`OtelMiddleware`** — shelf middleware that:
  - Extracts W3C trace context (`traceparent`, `tracestate`) and baggage
    from inbound request headers
  - Creates a `SpanKind.server` span as a child of the extracted context
  - Sets HTTP semantic-convention attributes on the span (`http.request.method`,
    `url.path`, `url.scheme`, `server.address`, `client.address`,
    `user_agent.original`)
  - Sets `http.response.status_code` on completion
  - Records exceptions and sets span status on errors

- **`InstrumentedHttpClient`** — wraps any `http.Client` (production
  `IOClient`, test `MockClient`, etc.) and:
  - Creates a `SpanKind.client` span for each outbound request
  - Injects W3C trace context and baggage into the request headers
  - Sets HTTP client semantic attributes (`http.request.method`, `url.full`,
    `server.address`, `http.response.status_code`)
  - Records exceptions and sets span status on errors

## Library code, no init

This package uses the Dartastic OpenTelemetry SDK directly but does not
call `OTel.initialize()` — consumers must initialize the SDK at app
startup before constructing the middleware or wrapping a client. See
the `weather_otel` bootstrap helper.

## Testing

Tests bring up a real OpenTelemetry SDK pointed at an in-memory span
exporter to verify the spans, attributes, and propagation headers
that the middleware and client actually emit. We do not mock the SDK.
See `DESIGN.md` § "Testing strategy" at the repository root.
