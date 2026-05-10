# Dart OTel Demo

A reference implementation of well-instrumented Dart server applications and
CLIs using the [Dartastic OpenTelemetry SDK][sdk]. Built as the working example
for an upcoming `blog.dart.dev` post on observability for Dart and Flutter.

**Status.** The local stack is shipped and runnable today —
`tool/stack.sh up` brings up two services + Grafana LGTM + bundled
dashboards in one command. The
[Cloud Run path](./deploy/cloudrun/README.md) and
[Cloud Functions Gen 2 path](./deploy/functions/README.md) both
ship deploy scripts for `weather-api` and `cache-service` with
production-grade IAM-locked service-to-service auth, and recommend
Google Cloud Operations (Cloud Trace + Cloud Logging + Cloud
Monitoring) as the telemetry backend. Architectural intent and
per-area shipping status are in [DESIGN.md](./DESIGN.md).

## What this demonstrates
![weather-trace.png](weather-trace.png)
- Distributed tracing across a CLI client, two Dart HTTP services, and an
  external API — one trace ID flowing through every hop, four levels deep.
- The standard OTel HTTP server semantic conventions: a
  `http.server.request.duration` histogram with bounded labels, plus
  full HTTP semconv attributes on every server span.
- Production-grade OTel patterns: `BatchSpanProcessor` everywhere,
  `SIGTERM`-driven graceful shutdown, route-template span names for
  bounded cardinality, propagated W3C Trace Context and Baggage,
  parent-based sampling.
- A `weather_client` SDK that implements `WeatherProvider` over HTTP —
  the same package is consumed by both `weather_api` (calling
  `cache_service`) and `weather_cli` (calling `weather_api`),
  demonstrating the symmetry between the demo's services and a
  caller-side library.
- A swarm runner (`load/run_swarm.sh`) that spawns N parallel CLI
  invocations and force-flushes the SDK before exit, plus a bundled
  Grafana dashboard whose latency heatmap shows the bimodal pattern
  (cache hits vs Open-Meteo round trips) that pops out at any
  meaningful traffic volume.
- A testing strategy that uses the **real** OTel SDK against an
  in-memory exporter — no mocking the SDK. See
  [DESIGN.md § Testing strategy](./DESIGN.md#testing-strategy).

## Quick start

```sh
# Bring up weather_api + cache_service + Grafana LGTM in one command:
tool/stack.sh up

# In another shell, drive a request through the stack:
curl -s 'http://localhost:8080/weather/Toulouse?days=3' | jq .

# Or generate enough volume to make the dashboards interesting:
load/run_swarm.sh --total 500 --parallel 25

# Open Grafana → Dashboards → Dart OTel Demo → Service Overview.
# The latency heatmap shows the bimodal cache pattern after a swarm.
open http://localhost:3000          # admin / admin
```

Full walkthrough — what's running, what to look for in the trace tree,
how to drive it from the CLI, how to tear it down — in
[deploy/local/README.md](./deploy/local/README.md).

## Local development workflow

```sh
# Run the same checks CI runs (pub get, analyze, format, test):
tool/build.sh

# Same plus AOT-compile every services/<name>/bin/server.dart:
tool/build.sh --release

# Run a service locally in the foreground.
# With one service available, no argument needed:
tool/run.sh

# With multiple services, pick one:
tool/run.sh weather_api
tool/run.sh --list

# Generate a unified LCOV coverage report at coverage/lcov.info:
tool/coverage.sh

# Or with an HTML report at coverage/html/ (requires lcov's `genhtml`):
tool/coverage.sh --html
```

`tool/run.sh` forwards the standard `OTEL_*` environment variables and
each service's own config (`PORT`, `ADMIN_PORT`, `OTEL_DEMO_MODE`) from
the calling shell — see each service's README for the accepted set.
For the canonical local-stack invocation:

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
tool/run.sh weather_api
```

## Quick links

- [DESIGN.md](./DESIGN.md) — architectural decisions and rationale
- [Dartastic OpenTelemetry SDK][sdk]
- [Flutterrific OpenTelemetry][flutter] — the Flutter-side companion
- [Open-Meteo](https://open-meteo.com) — upstream weather API (free, no key)

## License

Apache-2.0. See [LICENSE](./LICENSE).

[sdk]: https://github.com/MindfulSoftwareLLC/dartastic_opentelemetry
[flutter]: https://github.com/MindfulSoftwareLLC/flutterrific_opentelemetry
