# DESIGN

This document captures the architectural decisions for the demo: what we are
building, why, and the explicit non-goals. **Read this before the code.**

The audience is broad — Dart and Flutter developers learning OpenTelemetry,
observability practitioners new to Dart, GCP architects evaluating Dart on the
server, and reviewers from the GDE and Cloud Trace communities. Anything in
this repository that would mislead a reader who copies the code into their
own production system is a defect.

## North Star

**Production-correctness first.** Every architectural choice is made for the
production case. Demo-only affordances live in clearly labeled sidecar
components and never appear in the production hot path. We do not optimize
for "this looks cool in a five-minute demo" at the cost of "this teaches ten
thousand developers a bad habit."

This document and every line of code in this repository is written with that
invariant in mind.

## System

```
                ┌──────────────────────────────────────┐
                │  external — open-meteo.com           │
                └──────────────▲───────────────────────┘
                               │ http (W3C trace context)
                ┌──────────────┴───────────────────────┐
                │  cache_service                       │
                │  in-memory cache; on miss, fetches   │
                │  upstream and writes back            │
                └──────────────▲───────────────────────┘
                               │ http (W3C + baggage)
                ┌──────────────┴───────────────────────┐
                │  weather_api                         │
                │  public front door: validation,      │
                │  request shaping, response format    │
                └──────────────▲───────────────────────┘
                               │ http (W3C + baggage)
                ┌──────────────┴───────────────────────┐
                │  weather_cli   (instances 1..N,      │
                │                 swarmable)           │
                └──────────────────────────────────────┘
```

A single trace identifier flows from the CLI through both internal services
and into the external Open-Meteo call. Baggage entries (`cli.run_id`,
`cli.session_id`, `request_id`, `tenant`) flow with it and become searchable
attributes on every span via the `BaggageSpanProcessor`.

## Implementation status

The rest of this document is the architectural intent. Some of it
shipped as written; some shipped slightly differently; some is
still ahead. This section is the honest mapping. Skim it before
treating any later claim as a description of the current code.

### Shipped

- **Trace tree end-to-end.** `weather_cli → weather_api →
  cache_service → open-meteo`. Single trace_id, four levels deep.
  Provider-level spans (`open-meteo geocode`) nest as parents of
  transport-level client spans (`GET`) so each hop carries both
  business semantics and HTTP semantics.
- **W3C Trace Context propagation** on every HTTP boundary, inbound
  and outbound. Implemented once in `weather_http_kit` and reused.
- **W3C Baggage propagation** on every boundary too — `baggage`
  header extracted to `Context.current` so handler code can read it
  via `Baggage.fromContext(Context.current)`.
- **`BatchSpanProcessor` everywhere in production paths.**
  `SimpleSpanProcessor` only in tests. The bootstrap reads SDK
  defaults; explicit overrides are an `OTEL_*` env-var concern.
- **`ParentBasedSampler(TraceIdRatioSampler(...))`** wired in the
  bootstrap. 100% sampling default for the demo, env-overridable.
- **SIGTERM / SIGINT graceful shutdown.**
  `weather_otel.attachToProcessLifecycle()` installs handlers that
  forceFlush and shutdown the SDK before exit. Documented for the
  Cloud Run 10-second grace window.
- **`http.server.request.duration` histogram** emitted by the shelf
  middleware with a deliberately low-cardinality label set
  (method, route TEMPLATE, status_code, scheme), pinned by a test
  that catches accidental high-cardinality additions.
- **Cache attribution on spans.** `cache_service` annotates the
  active server span with `weather.cache.namespace`,
  `weather.cache.outcome` (hit / miss / expired), and
  `weather.cache.size`, plus a `cache.{outcome}` event.
- **Error categorization across HTTP boundaries.**
  `WeatherProviderException` ↔ HTTP status mapping is symmetric
  between weather_api (`httpStatusForProviderError`) and
  weather_client (`_exceptionForStatus`); errors round-trip cleanly
  through any number of hops.
- **`recordException` + `setStatus(Error)`** on every caught
  exception in instrumented code. ~13 sites across the codebase.
- **Local stack** (`deploy/local/`): `docker compose` brings up
  `weather_api` + `cache_service` + Grafana LGTM + bundled
  dashboards in one command. Single-binary stack with auto-loaded
  dashboards under "Dart OTel Demo" in Grafana.
- **Swarm script** (`load/run_swarm.sh`): N parallel CLI
  invocations, post-run flush via the demo admin endpoints
  (`POST /flush` on loopback-bound 8081 / 8091, only when
  `OTEL_DEMO_MODE=true`).
- **OTel logs SDK integration via a `package:logging` bridge.**
  `weather_otel`'s bootstrap forwards every `package:logging`
  record through the OTel logs SDK so entries flow over OTLP
  with the active span's trace_id and span_id attached, while
  the application's own stdout listener keeps printing locally
  (additive, not a replacement). Each `Logger` becomes its own
  OTel instrumentation scope by name. The demo ships its own
  ~40-line bridge in `package_logging_bridge.dart` — readable,
  enough for the demo. A production-grade `package:logging`
  bridge ships in `dartastic_opentelemetry_logging` as part of
  Dartastic.io Pro, alongside other higher-quality telemetry
  packages — drop it in instead when production polish matters.
- **In-flight requests gauge** (`http.server.active_requests`) in
  `weather_http_kit`'s shelf middleware. UpDownCounter
  incremented on request start, decremented on request end (in
  `finally`, so handlers that throw still decrement). Same
  bounded label set as the duration histogram minus
  `http.response.status_code` (the request is in flight, no
  status yet) — `http.request.method`, `http.route`,
  `url.scheme` only. Pinned by a cardinality test plus a
  return-to-baseline test that catches inc/dec attribute
  mismatches before they leak series in production.
- **Upstream dependency-health + cost counter**
  (`weather.upstream.requests`) on `OpenMeteoProvider`. One
  counter answers two questions: dependency health (success /
  total over a rolling window, sliced by `error.kind`) and
  upstream-call cost (count × per-call price). Attributes:
  `weather.provider`, `weather.operation`, `weather.outcome`,
  `weather.error.kind` (only when outcome=error). ~80 series
  upper bound. Cardinality is pinned by a test that fails the
  moment a high-cardinality attribute (city name, query string,
  request id) is added.
- **Cache hit/miss/expired counter** in `cache_service`.
  `weather.cache.lookups` is a counter incremented per cache
  lookup, attributed by `weather.cache.namespace` (forecast |
  geocode) and `weather.cache.outcome` (hit | miss | expired).
  Cardinality is bounded forever — eight series at most. Promoted
  from a span attribute (which is per-trace and only useful for
  individual debugging) to a proper metric so backends can chart
  hit ratio over time and alert on miss-rate spikes. The
  cardinality discipline is pinned by a test in
  `services/cache_service/test/handler_test.dart` —
  introducing a high-cardinality attribute on this metric (a
  query string, a request id) makes the test fail.
- **`BaggageSpanProcessor` wired by default in
  `weather_otel`'s bootstrap.** Every entry in
  `Context.current.baggage` is copied onto each starting span as
  a string attribute. Combined with the W3C Baggage propagator
  (which carries baggage entries as a `baggage` header on every
  outbound HTTP request), a baggage entry set once at the CLI's
  entry point appears as a span attribute on every span across
  the trace tree — `weather-cli`, `weather-api`,
  `cache-service`, and the open-meteo client spans nested under
  cache-service. Searchable in any backend without per-handler
  enrichment.
- **Concrete baggage entries** emitted by `weather_cli`:
  `cli.run_id` (UUID v4 per process invocation; finds all spans
  for one CLI run with one search) and `cli.session_id` (read
  from the `CLI_SESSION_ID` env var; the swarm script sets one
  session id for an entire batch so every CLI in one swarm
  shares it). Both are bounded-cardinality identifiers — safe
  for the BaggageSpanProcessor to copy onto every span.
- **Cloud Run deployment** (`deploy/cloudrun/`).
  `weather-api` and `cache-service` deploy via the bundled
  `gcloud-deploy-*.sh` scripts. Production-grade auth:
  `cache-service` is `--no-allow-unauthenticated`; weather-api's
  outbound HTTP path attaches a Cloud Run ID token from the GCE
  metadata server (no-op locally, active on Cloud Run) on every
  call. Telemetry destination is OTLP-to-Cloud-Operations by
  default — Cloud Trace / Cloud Logging / Cloud Monitoring all
  accept OTLP natively.
- **Cloud Functions Gen 2 deployment** (`deploy/functions/`).
  Mirror layout to `deploy/cloudrun/`. Same Dockerfiles, same
  `WeatherClient.tokenProvider` wiring (Functions Gen 2 IS Cloud
  Run under the hood — `K_SERVICE` is set, the metadata server is
  reachable, SIGTERM is delivered the same way), with overrides in
  the env YAML for `cloud.platform=gcp_cloud_functions` and
  `faas.name` so dashboards can split Functions out from Cloud
  Run.
- **`faas.coldstart` and `faas.execution` per-invocation
  attributes** on every server span emitted by `weather_http_kit`'s
  `otelMiddleware`. `faas.coldstart` is a boolean — `true` on the
  first request a process handles, `false` thereafter — set via a
  process-global latch that flips on first observation.
  `faas.execution` is read from the `Function-Execution-Id`
  inbound header (Cloud Functions Gen 2 sets this on every
  invocation) and forwarded as-is so trace data correlates with
  the platform's own logs and metrics. Both are span attributes
  only, never metric labels (the execution id is high-cardinality
  by design).
- **`faas.coldstart.duration` histogram** alongside the
  `http.server.request.duration` histogram, recorded once per
  process — on the first request the instance handles. Same
  low-cardinality label set as the duration histogram (method,
  route, status_code, scheme) so dashboards can graph cold-start
  cost distribution side-by-side with the general-purpose latency
  distribution without folding `faas.coldstart` in as a label
  (which would double the duration histogram's series count for
  warm-path values that are always `false`).
- **Testing pattern** with `InMemorySpanExporter` and now
  `MemoryMetricReader` in `weather_http_kit`. Every package has a
  ~50-line harness designed to be lifted into a reader's project
  unchanged.
- **Backend selection by env var, no code change.** The
  Dartastic SDK reads the standard `OTEL_TRACES_EXPORTER`
  (`otlp` | `console` | `none`) and `OTEL_EXPORTER_OTLP_ENDPOINT`
  variables on its own — the bootstrap doesn't add any custom
  switching. Five concrete backends documented today: Grafana
  LGTM (local stack), `console` / stdout (debugging and CI),
  Google Cloud Operations (Cloud Run target — Cloud Trace +
  Cloud Logging + Cloud Monitoring), Dartastic Cloud (when
  online), and any other OTLP-compatible backend (Honeycomb, a
  self-hosted collector, …). The env-var matrix is in the README
  under "Selecting a telemetry backend"; the Cloud Run walk-
  through is in `deploy/cloudrun/README.md`.

### Shipped differently than originally designed

- **No separate `apps/otel_flush_cli`.** The flush mechanism is the
  admin endpoint plus a curl from the swarm script (or any client).
  A separate CLI binary would have been one more thing to install
  and document; curl is everywhere.
- **`weather_client` SDK package** wasn't in the original design —
  it emerged when `weather_api` needed to call `cache_service` over
  HTTP via the same `WeatherProvider` interface. It's now used by
  both `weather_api → cache_service` and `weather_cli → weather_api`,
  which is a better story than was originally planned.
- **Cardinality discipline** is enforced by the metric attribute
  helper and a pinned test, not by type signatures (the design
  overstated this). The test catches accidental additions; type
  signatures would have required a more invasive API and aren't
  warranted at this scale.

### Not yet shipped

The original "Not yet shipped" list is empty as of this writing.
The remaining work to publish the blog post is content (the post
itself, screenshots, the trace-walkthrough narrative) rather than
instrumentation gaps — every demonstrated pattern in the design
ships in code today.
## Deployment matrix

The same Dart code ships to three runtimes. The runtime is selected by a
Dockerfile or a Functions entry shim. The telemetry destination is selected
entirely by `OTEL_*` environment variables — there is **no code change
between backends.**

| Runtime                         | weather_api | cache_service | Notes                              |
|---------------------------------|-------------|---------------|------------------------------------|
| Local Docker Compose            | container   | container     | Bundled with Grafana LGTM stack    |
| Google Cloud Run                | service     | service       | Service-to-service via internal URL|
| Dart Cloud Functions (Gen 2)    | function    | function      | Function-to-function via HTTPS     |

Telemetry backends:

| Backend                        | When                                              | Endpoint                              |
|--------------------------------|---------------------------------------------------|---------------------------------------|
| stdout (`ConsoleExporter`)     | local dev, debugging, CI                          | n/a                                   |
| Grafana LGTM (local container) | offline demo, full pillar coverage                | `localhost:4318`                      |
| Google Cloud Operations        | production GCP — Cloud Trace + Cloud Logging      | `telemetry.googleapis.com`            |

## Package layout

Every package depends on the Dartastic OpenTelemetry **SDK**
(`dartastic_opentelemetry`). Library packages do not call `OTel.initialize()` —
that is exclusively an application-layer concern and lives in the service or
app entrypoint.

```
packages/
  weather_core         domain models, business logic, instrumented; no init
  weather_http_kit     shelf middleware + instrumented http.Client; no init
  weather_client       Dart HTTP client SDK for the v1 API; no init
  weather_otel         app-side bootstrap (init, SIGTERM wiring, gated admin endpoint)
services/
  weather_api          public front door
  cache_service        cache + upstream fetcher
apps/
  weather_cli          instrumented caller, swarmable
load/
  run_swarm.sh         spawns N CLI instances for throughput demos
dashboards/
  grafana/             pre-built Grafana dashboard JSON, auto-loaded into the local stack
deploy/
  local/               docker-compose for app + Grafana LGTM
  cloudrun/            Cloud Run deploy scripts + env YAML; IAM-locked cache-service
  functions/           Cloud Functions Gen 2 deploy scripts + env YAML; same shape as cloudrun
```

The original design also called for a separate `apps/otel_flush_cli`
binary; the flush mechanism shipped instead as an admin endpoint
plus `curl` from the swarm script. See "Implementation status"
above.

## OpenTelemetry patterns

**Trace context propagation.** W3C Trace Context (`traceparent`, `tracestate`)
on every HTTP boundary, inbound and outbound. Implemented once in
`weather_http_kit` middleware and the instrumented HTTP client; reused by
every service and the CLI.

**Baggage.** W3C Baggage propagation alongside trace context. The bootstrap
registers a `BaggageSpanProcessor` so baggage entries become span attributes
automatically — searchable in any backend without manual enrichment. Demo
entries: `cli.run_id`, `cli.session_id`, `request_id`, `tenant`.

**Sampling.** Default is `ParentBasedSampler(TraceIdRatioSampler(arg))` so
upstream sampling decisions are honored. The demo ships at 100% sampling
(`OTEL_TRACES_SAMPLER_ARG=1.0`); production guidance for tuning is in the
README.

**Span processor.** `BatchSpanProcessor` everywhere. Production-grade
defaults: `scheduleDelay: 1s`, `maxQueueSize: 2048`, `maxExportBatchSize: 512`.
The same configuration applies in serverless: Functions Gen 2 sits on
Cloud Run and receives `SIGTERM` ~10 seconds before instance shutdown,
which is more than enough for a tuned batch processor to drain.

**Shutdown.** `ProcessSignal.sigterm.watch()` is registered at app boot and
calls `OTel.shutdown()`, which force-flushes processors and closes exporters.
There is no flush code anywhere in the request hot path. The only spans that
can be lost are from `SIGKILL` — and you cannot trace your way out of a hard
crash regardless of language or telemetry stack.

**Resource attributes.** Full semantic-convention coverage per deployment
target: `service.*`, `deployment.environment`, `cloud.provider`,
`cloud.platform`, `cloud.region`, `faas.*` for Functions (`faas.name`,
`faas.version`, `faas.instance`, `faas.coldstart`), `host.*` for local,
`container.*` where applicable. Resource detection is automatic with
manual overrides via env.

**Cardinality discipline.** High-cardinality attributes (city name,
query parameters, error messages, full URLs) belong on **spans**, where
storage cost is bounded by the trace itself. Low-cardinality attributes
(`country`, `http.route`, `http.method`, `http.status_code`, cache result
class) belong on **metrics**, where every unique combination becomes a
separate time series. We never put raw user IDs, request IDs, or city
names on metrics. This rule is enforced by the type signatures of helper
functions in `weather_http_kit`.

**Logs.** `package:logging` integrated with the OTel logs SDK. Log records
carry the active trace ID and span ID for one-click correlation. Log
volume is itself a metric.

**Errors.** Every caught exception in instrumented code calls
`span.recordException(e, stackTrace: s)` and `span.setStatus(SpanStatusCode.error, ...)`.
The recorded `exception.stacktrace` attribute is what the trace
backend (Tempo, Cloud Trace) renders for the on-call to debug from.

**Golden signals + extras.** Standard RED (Rate, Errors, Duration) plus
saturation proxies (in-flight requests), dependency health (Open-Meteo
success rate), cache effectiveness (hit / miss / stale ratios), cold-start
histograms (Functions only), and cost-relevant metrics (upstream API call
counter — people pay per call).

## Demo affordances (sidecar only)

These are demo-time conveniences. They never run in a production deployment.

- **Admin `POST /flush` endpoint** on a loopback-bound port (8081 for
  weather_api, 8091 for cache_service), exposed by
  `weather_otel.demoAdminPipeline()` only when `OTEL_DEMO_MODE=true`.
  The bootstrap helper short-circuits when the flag is unset —
  production binaries do not exercise the code path. Driven by `curl`
  from the swarm script, or directly by the user.
- **`load/run_swarm.sh`** spawns N CLI instances in parallel for
  throughput demonstrations and POSTs to both flush endpoints at the
  end of every batch so traces land in the backend immediately.
- Pre-built Grafana dashboard JSON in `dashboards/grafana/`,
  auto-loaded into the local stack's Grafana container.

## Testing strategy

Tests in this repository do not mock the OpenTelemetry SDK. Instead they
bring up the **real** SDK pointed at an **in-memory span exporter** that
captures every emitted span for inspection. This is a deliberate teaching
choice and one of the patterns we most want readers to copy.

### Why not mock OpenTelemetry

Mocking instrumentation gives false confidence. A test that asserts
`mockTracer.startSpan(...)` was called proves only that the *test code* was
written to call it — it tells you nothing about whether the resulting span
has the right name, the right kind, the right attributes, the right status,
the right parent, or the right baggage. Worse, the mock has to be kept in
sync with the SDK's evolving API surface, and any divergence makes the
tests pass while production breaks.

Pointing the real SDK at an in-memory exporter inverts the cost:
- The SDK's behavior is exercised end-to-end. If it changes meaningfully,
  tests notice.
- Assertions are about the **observable telemetry** — the spans, their
  attributes, the events on them, the resulting status. That is what a
  real backend will see, and what an SRE will debug from.
- The in-memory exporter is ~50 lines of code. Reproduced verbatim in
  every demo test directory; reusable in any reader's project.

### The pattern

```dart
// test/_helpers/otel_test_harness.dart
class InMemorySpanExporter implements SpanExporter {
  final List<Span> _spans = <Span>[];
  List<Span> get spans => List.unmodifiable(_spans);
  void clear() => _spans.clear();
  Span? findSpanByName(String name) { /* … */ }

  @override
  Future<void> export(List<Span> spans) async => _spans.addAll(spans);
  @override Future<void> forceFlush() async {}
  @override Future<void> shutdown() async {}
}

Future<InMemorySpanExporter> initializeOtelForTest() async {
  final exporter = InMemorySpanExporter();
  await OTel.initialize(
    serviceName: 'test',
    serviceVersion: '0.0.0-test',
    spanProcessor: SimpleSpanProcessor(exporter),
  );
  return exporter;
}
```

A test then does:

```dart
late InMemorySpanExporter spans;
setUpAll(() async => spans = await maybeInitializeOtelForTest());
setUp(() => spans.clear());

test('records the right span on geocode', () async {
  await provider.geocode('Toulouse');
  final span = spans.findSpanByName('open-meteo geocode');
  expect(span, isNotNull);
  expect(span!.kind, SpanKind.client);
});
```

`SimpleSpanProcessor` in tests is the **only** place this codebase uses it
— production paths use `BatchSpanProcessor` exclusively. Tests need
synchronous export-per-span so spans are available immediately after the
system under test returns; production prioritizes throughput over latency.

### Fakes, not mocking frameworks

Where the tests need test doubles for non-OTel collaborators (the
`WeatherProvider` in `WeatherService` tests, the `http.Client` in provider
tests), we hand-roll small `FakeXxx` classes or use the http package's
built-in `MockClient`. We do not pull in `mockito`, `mocktail`, or other
mocking frameworks. The reason is the same as above: the demo is a
teaching artifact, and a hand-written 30-line fake is more readable for a
blog audience than four lines of `when(...).thenReturn(...)` magic. Real
projects can choose differently.

### Coverage

`tool/coverage.sh` at the repository root runs the test suite for every
package in the workspace, formats the result as a unified LCOV report at
`coverage/lcov.info`, and (with `--html`) renders an HTML report at
`coverage/html/`. CI integration is straightforward.

## Non-goals

We deliberately do **not** do the following, anywhere in this repository:

- **No `SimpleSpanProcessor`.** It is acceptable to discuss it for teaching;
  it never appears in a runnable code path here.
- **No per-request flush.** The `SIGTERM` handler is the production answer.
- **No mocking of OTel in tests.** Tests use a real SDK pointed at a test
  exporter or the global console exporter.
- **No demo-only conveniences in production code paths.** Every demo
  affordance lives in its own sidecar.

## Open questions for review

These are the areas where we explicitly want a Cloud Trace expert,
observability GDE, or Dart server practitioner to weigh in:

1. **Sampling.** Is `ParentBasedSampler(TraceIdRatioSampler)` the right
   default for the demo, or should we ship an error-prioritizing or
   tail-based sampler as the recommended pattern?
2. **Batch tuning.** Are our `BatchSpanProcessor` defaults appropriate for
   Cloud Run / Functions Gen 2 instance lifetimes and traffic patterns?
3. **Cloud Trace OTLP.** Confirm exact endpoint, auth flow, and any
   GCP-specific resource attributes that improve the Cloud Trace experience.
4. **Cardinality.** Are our metric attribute choices safe under Cloud
   Monitoring's per-metric series cap, especially for
   `cache_result × http.route × http.status_code`?
5. **Cost optimization.** Recommended exporter compression and protocol
   choices for high-volume Dart workloads on GCP.
6. **Trace AI MCP.** How should we structure spans, attributes, and events
   to maximize the new Trace AI MCP's analysis quality?
7. **Functions specifics.** Whether `SIGTERM` is reliably delivered in
   `firebase_functions_dart`, and whether the lazy-init pattern interacts
   well with concurrent first-request bursts.

This document will be revised as review feedback arrives. Significant
revisions will be summarized in a "Revisions" section appended below.
