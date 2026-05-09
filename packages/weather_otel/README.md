# weather_otel

Application-side OpenTelemetry bootstrap for the Dart OTel demo. Every
service binary and the CLI consume this package to initialize the SDK
with the same production-grade defaults and graceful-shutdown wiring.

## What `initializeOtel` does

```dart
final otel = await initializeOtel(
  serviceName: 'weather-api',
  serviceVersion: '1.0.0',
);

// At process exit:
await otel.shutdown();
```

This single call:

- Generates a unique `service.instance.id` for the process. Backends use
  it to distinguish replicas in a horizontally-scaled deployment.
- Wraps the chosen exporter in a `BatchSpanProcessor` with the OTel-spec
  defaults (5s schedule, 2048 queue, 512 batch). Production paths
  always use batch. `SimpleSpanProcessor` only ever appears in tests.
- Defaults the sampler to `ParentBasedSampler(TraceIdRatioSampler(1.0))`
  — the OTel-spec default for traces. Override with the `samplingRatio`
  parameter to sample a percentage of root spans.
- Resolves OTLP endpoint, protocol, headers, and resource attributes
  from the standard `OTEL_*` environment variables. No custom env vars
  are introduced — vendor backends switch by configuration alone.
- Returns a `WeatherOtelHandle` whose `shutdown()` flushes pending
  spans and tears down the SDK in the right order.

## Graceful shutdown

```dart
final otel = await initializeOtel(...);
otel.attachToProcessLifecycle();  // installs SIGTERM + SIGINT handlers

// At this point, a SIGTERM from Cloud Run or `docker stop` triggers
// `otel.shutdown()` followed by `exit(0)`. The handler runs once;
// repeated signals are ignored to avoid racing concurrent shutdown.
```

Cloud Run sends SIGTERM ~10 seconds before SIGKILL. Cloud Functions
Gen 2 has the same window. The handler registers a flush call inside
that window so spans for in-flight requests reach the backend before
the container dies.

## Demo admin endpoint (sidecar only)

When `OTEL_DEMO_MODE=true` is set in the environment, `demoAdminPipeline`
returns a shelf handler that exposes `POST /flush` and
`GET /healthz`. Mount it on a **separate port** (e.g., `8081`) — never
on the public-facing service — so the flush endpoint can never be
reached from outside the host.

```dart
final adminHandler = otel.demoAdminPipeline();
if (adminHandler != null) {
  await io.serve(adminHandler, '127.0.0.1', 8081);
}
```

When `OTEL_DEMO_MODE` is unset (or not `true`), `demoAdminPipeline`
returns `null` — the admin port is never opened in production
binaries. See `DESIGN.md` § "Demo affordances" at the repository root.

## Library, not framework

`weather_otel` does not own application startup or the request
pipeline. It owns only the SDK lifecycle. Services compose it with
`weather_http_kit`, their own routers, and their own port-binding
code. See the services under `services/` for the canonical wiring.
