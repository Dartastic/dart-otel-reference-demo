# Error handling in the demo — implementation brief

> **Status: waiting on release.** Implements against
> `dartastic_opentelemetry_api` ≥ 1.0.0-rc.2 (the release carrying
> `OTelAPI.setErrorHandler`, api#94) and the SDK release that adds the
> `OTel.setErrorHandler` facade (SDK #232). Do not implement before those
> ship; the snippets below will not compile against 1.0.0-rc.1.

## What the library now provides

OpenTelemetry's [error-handling principles] say the API must never throw
into application code when misused — invalid input degrades safely and is
*reported*. The Dart OTel packages route every such report through one
global, per-isolate handler:

- `OTelAPI.setErrorHandler((error, stackTrace) { ... })` — API package.
- `OTel.setErrorHandler(...)` — SDK facade, **same handler slot** (the SDK
  delegates to the API; setting either sets both, last write wins).
- Default: reports are logged via `OTelLog.error`. Installing a handler
  **replaces** the logging — log inside your handler if you want both.
- `Context.runIsolate` re-installs the parent's handler in child isolates
  (handlers are copied; capture a `SendPort` to aggregate reports in the
  parent — see `doc/isolates.md` in the API package).
- A handler that throws propagates deliberately — the spec's strict mode.

**Not this handler's job:** exceptions thrown by *demo code* inside
`withSpan` blocks. Those always rethrow; how they are recorded on spans is
governed by the SDK's `SpanExceptionOptions` (recordException /
setStatusOnException / PII sanitizer). The two hooks are complementary:
`SpanExceptionOptions` = your app's errors onto spans;
`setErrorHandler` = the library's own error reports.

## What the demo should demonstrate

1. **Telemetry health as telemetry** (weather-api and cache-service):
   install a handler at startup that counts reports on a
   `otel.errors.reported` counter and logs at warn — showing the
   log-AND-count pattern and that a handler replaces default logging:

   ```dart
   final otelErrors = meter.createCounter<int>(name: 'otel.errors.reported');
   OTel.setErrorHandler((error, stackTrace) {
     otelErrors.add(1);
     OTelLog.error('OTel internal: $error');
   });
   ```

2. **Strict mode in development** (weather-api): behind an env flag
   (`DEMO_OTEL_STRICT=true`), install the crash-fast handler so misuse
   surfaces immediately in local dev:

   ```dart
   OTel.setErrorHandler((e, st) =>
       Error.throwWithStackTrace(e, st ?? StackTrace.current));
   ```

3. **Trigger one report on purpose** (demo affordance, like the existing
   test-traces button): an endpoint or button that feeds the API an
   invalid input the spec says must not throw (e.g. an empty attribute
   key) and shows the report arriving in the handler — proving nothing
   crashed and nothing was silently swallowed.

4. **Isolate propagation** (Flutter client or a CLI load tool, optional):
   run a traced computation via `Context.current.runIsolate` and show the
   handler behaving identically in the child; if aggregating, use the
   SendPort pattern from the API's `doc/isolates.md`.

5. **Contrast with `SpanExceptionOptions`** (weather-api): keep one
   deliberately-failing route (the demo already throws on unknown cities)
   and document in its comments that this exception reaches the span via
   `SpanExceptionOptions`, *not* the error handler.

## Wiring points

- `services/weather_api/bin/` (or its bootstrap): handler install right
  after `OTel.initialize`, before serving.
- `services/cache_service`: same pattern, counter-only handler.
- `apps/` Flutter client: install in `main()` before `runApp`; remember
  each isolate needs its own install unless spawned via `runIsolate`.
- Dashboard: add the `otel.errors.reported` counter to the Grafana health
  row so a nonzero value is visible at a glance.

[error-handling principles]: https://opentelemetry.io/docs/specs/otel/error-handling/
