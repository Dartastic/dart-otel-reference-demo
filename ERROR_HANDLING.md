# Error handling: not yet in the demo

What the demo implements (the handler installed before initialize,
telemetry that reports instead of throwing, and how the app's own
errors reach spans) is in the README's
[Telemetry never throws](README.md#telemetry-never-throws). These are
the parts of the OpenTelemetry error-handling contract it doesn't show
yet.

1. **Strict mode in development** (weather-api). Behind an env flag,
   install a handler that rethrows, so misuse surfaces at once in local
   development:

   ```dart
   OTelAPI.setErrorHandler((e, st) =>
       Error.throwWithStackTrace(e, st ?? StackTrace.current));
   ```

2. **Trigger one report on purpose**, a demo affordance like the
   test-traces button: an endpoint or button that feeds the API an input
   the spec says must not throw (an empty attribute key, say) and shows
   the report arriving in the handler, proving nothing crashed and
   nothing was silently swallowed.

3. **Isolate propagation** (the Flutter client or the CLI). Run a traced
   computation with `Context.current.runIsolate` and show the handler
   behaving the same in the child isolate. To aggregate reports in the
   parent, send them over a `SendPort`, as the API package's
   `doc/isolates.md` describes.

A counter of reports would show telemetry health as telemetry, but the
OpenTelemetry semantic conventions have no metric for it yet, so the
demo doesn't invent one.
