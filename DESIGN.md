# DESIGN

This document captures the architectural decisions for the demo: what we are
building, why, and the explicit non-goals. **Read this for the reasoning;
read [README.md](./README.md) for the practical documentation of what's
shipped.**

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

## Implementation status

The demo is **shipped end-to-end** as of this writing. Every pattern,
package, dashboard, and deployment target listed in
[README.md § What's shipped](./README.md#whats-shipped) is in code today
and exercised by tests. There is no "not yet shipped" backlog blocking
the launch — remaining work is content (the blog post itself,
screenshots, the trace-walkthrough narrative) rather than instrumentation
gaps.

### Shipped differently than originally designed

Three places where what shipped differs from the original design intent:

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

## Cardinality discipline — the load-bearing decision

The single decision that affects more code than any other in this
repository is the placement rule for attributes: **high-cardinality
attributes go on spans; low-cardinality attributes go on metrics.**

The reasoning:

- A span is a per-trace artifact. Storage cost grows with trace
  volume regardless of attribute cardinality; a city name on a span
  attribute costs no more than a status code does.
- A metric label, by contrast, becomes a separate time series for
  every unique combination of label values. A `city` label on a
  request-rate counter detonates the series count: 50,000 cities ×
  10 routes × 5 status codes = 2.5M series. That's storage cost,
  query cost, and a Prometheus alerting backend that times out on
  every dashboard refresh.

Every metric in the demo ships with a guardrail test that fails the
moment a high-cardinality attribute leaks in. The pattern: build the
metric's attribute set in a single helper, assert in tests that the
attribute keys are exactly the allowed set. Five metrics, five
guardrail tests. The discipline is enforced mechanically, not
trusted to reviewers.

## Mocking the OTel SDK is a defect

Tests in this repository do not mock the OpenTelemetry SDK. They
point the real SDK at an in-memory exporter and assert on the
exported telemetry. The reasoning is in [README.md § Testing strategy](./README.md#testing-strategy).

Why this is a design decision and not a tooling decision: a mocked
SDK invites readers to write tests that pass when production breaks.
A reader who copies this repo's pattern into their own project
inherits a test suite that exercises real SDK behavior; a reader who
copies a mocked-SDK pattern inherits a test suite that lies.
Anything in this repo that taught readers to mock OTel would be a
defect.

## Demo affordances are sidecars

The flush endpoint, the swarm script, and the bundled Grafana
dashboards are demo affordances — they never run in a production
deployment. The architectural commitment: they are sidecars,
gated behind `OTEL_DEMO_MODE=true`, and the bootstrap helper that
exposes them short-circuits when the flag is unset. Production
binaries do not exercise the code paths.

This is the reason the README frames demo affordances as a separate
section rather than mixed in with the production patterns: a reader
copying instrumentation patterns should know which lines they're
expected to take and which lines are demo-only.

## Non-goals

We deliberately do **not** do the following, anywhere in this repository:

- **No `SimpleSpanProcessor`.** It is acceptable to discuss it for
  teaching; it never appears in a runnable production code path here.
  Tests are the only exception.
- **No per-request flush.** The `SIGTERM` handler is the production
  answer. A `forceFlush` in a request hot path is an instrumentation
  smell.
- **No mocking of OTel in tests.** Tests use a real SDK pointed at a
  test exporter or the global console exporter.
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
