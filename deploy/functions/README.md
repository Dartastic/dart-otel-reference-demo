# Cloud Functions Gen 2 deployment

The same `weather_api` and `cache_service` binaries that run in
the [local stack](../local/) and on [Cloud Run](../cloudrun/)
deploy unchanged as Cloud Functions Gen 2 HTTP functions. Same
Dockerfiles, same `WeatherClient.tokenProvider` wiring, same
trace tree. The runtime is selected by the deployment surface,
not by the code.

> **Why this exists when Cloud Run is already there.** Cloud
> Functions Gen 2 IS Cloud Run with a different control plane:
> the `gcloud functions deploy --gen2` API exposes function-shaped
> trigger configuration (HTTP, Pub/Sub, Eventarc) and per-function
> retry policies that aren't directly on `gcloud run deploy`. For
> a service-shaped workload like this demo's, the deployments are
> functionally equivalent — but a real codebase often has both
> (services for stable HTTP frontends, functions for event handlers
> behind Pub/Sub or storage triggers), and showing both deployment
> surfaces against the same binary is part of the
> "production-correctness first" framing.

## Status

Deploy scripts ship for `weather-api-fn` and `cache-service-fn`.
Production-grade auth: cache-service-fn deploys
`--no-allow-unauthenticated`; weather-api-fn fetches a Cloud Run
ID token from the metadata server and attaches it on every
outbound call (same `cloudRunIdTokenProvider` in `weather_otel`
that the Cloud Run path uses — Functions Gen 2 sets `K_SERVICE`
the same way Cloud Run does, so no code change is needed). For
visualization, point the OTLP endpoint at Google Cloud Operations
— same recommendation as the Cloud Run path.

## Prerequisites

Same shape as Cloud Run:

- Google Cloud project with billing enabled
- `gcloud` CLI authenticated (`gcloud auth login` +
  `gcloud auth application-default login`)
- A region with Cloud Functions Gen 2 availability — most regions
  Cloud Run supports also support Functions Gen 2

The `deploy-bootstrap.sh` script enables the extra APIs Functions
Gen 2 needs on top of Cloud Run (`cloudfunctions.googleapis.com`,
`eventarc.googleapis.com` — the latter is a hard dependency even
for HTTP-triggered functions).

## Configure once

```sh
cp deploy/functions/config.example.sh deploy/functions/config.sh
$EDITOR deploy/functions/config.sh    # PROJECT, REGION, OTLP endpoint
```

`config.sh` is gitignored — same gitignore rule as
`deploy/cloudrun/config.sh`.

## Deploy

```sh
bash deploy/functions/deploy-bootstrap.sh
bash deploy/functions/deploy-cache-service.sh
bash deploy/functions/deploy-weather-api.sh

# Or all three in one go:
bash deploy/functions/deploy-all.sh
```

`deploy-cache-service.sh` deploys `cache-service-fn` with
`--no-allow-unauthenticated` and binds `roles/run.invoker` for
weather-api-fn's runtime SA. `deploy-weather-api.sh` reads
`cache-service-fn`'s URL via `gcloud functions describe` and
injects it as `WEATHER_UPSTREAM_URL`.

After `deploy-weather-api.sh` finishes:

```sh
curl -s 'https://weather-api-fn-XXX.a.run.app/weather/Boston?days=3' | jq .
```

The trace tree fans out the same as the Cloud Run path —
`weather-api-fn` → `cache-service-fn` → `open-meteo` — and lands in
whatever OTLP backend you configured.

## What's different from Cloud Run

Most of the deployment surface is the same; the differences worth
calling out:

| Concern                   | Cloud Run                          | Cloud Functions Gen 2                              |
| ------------------------- | ---------------------------------- | -------------------------------------------------- |
| Deploy command            | `gcloud run deploy`                | `gcloud functions deploy --gen2`                   |
| Source / image            | `--image=…` (Artifact Registry)    | `--source=. --dockerfile=…` (built per-deploy)     |
| Resulting service         | Cloud Run service                  | Cloud Run service with Functions metadata          |
| `cloud.platform`          | `gcp_cloud_run` (auto-detected)    | `gcp_cloud_functions` (we override via env)        |
| `faas.name` / `faas.version` | not set                         | set explicitly in env YAML                         |
| Inter-service auth        | `roles/run.invoker`                | `roles/run.invoker` (same; Gen 2 IS Cloud Run)     |
| SIGTERM / shutdown        | 10s grace, SDK flushes via handler | identical (Gen 2 inherits Cloud Run's lifecycle)   |
| Cold-start time           | comparable to Cloud Run            | comparable to Cloud Run                            |
| `K_SERVICE` env           | set                                | set                                                |
| Metadata server           | available                          | available                                          |

Because Gen 2 inherits Cloud Run's container lifecycle exactly,
the bootstrap in `weather_otel` doesn't need any "is this
Functions?" branch — `attachToProcessLifecycle()` registers the
same SIGTERM handler, the BatchSpanProcessor flushes inside the
10s grace window, and the metadata-server token fetch in
`cloudRunIdTokenProvider` works without modification.

## Resource attributes — what to override

Cloud Functions Gen 2 wants two things in `OTEL_RESOURCE_ATTRIBUTES`
that the SDK's auto-detection doesn't get right out of the box on
Functions:

```
OTEL_RESOURCE_ATTRIBUTES=cloud.platform=gcp_cloud_functions,faas.name=weather-api-fn,deployment.environment=cloudfunctions
```

The env YAML files in `deploy/functions/env/` set these. The
SDK's other auto-detection still applies — `cloud.region`,
`service.instance.id`, `process.runtime.*`, `host.*` — so Function
spans look right in any backend that groups by resource attribute.

`faas.coldstart` (per-invocation, set on the first request a
fresh instance handles) and `faas.execution` (per-invocation
correlation id) are the two attributes the SDK and bootstrap
don't currently emit. Both are out-of-scope for Phase 1; track in
DESIGN.md when you take this further.

## Telemetry destination

Same three options the Cloud Run path documents:

- **Google Cloud Operations** (recommended) — endpoint is
  `https://telemetry.googleapis.com:443`, gRPC, requires
  `roles/telemetry.{traces,metrics,logs}Writer` on the runtime
  service account. See
  [`deploy/cloudrun/README.md` § Option A](../cloudrun/README.md#option-a--google-cloud-operations-recommended)
  for the IAM one-liner; it applies to Functions runtime SAs the
  same way.
- **Dartastic Cloud** — endpoint published once the public Cloud
  is online.
- **External OTLP backend** — Honeycomb, your own collector.
  API keys via Secret Manager + `--set-secrets`.

## Costs and quotas

Cloud Functions Gen 2 bills the same as Cloud Run (per-request
+ per-container-second). Free tier is the same. The deploy is
slower than Cloud Run because Functions builds the image as part
of the deploy step rather than accepting a pre-built `--image=`;
budget ~2 minutes for the first deploy of each function and ~1
minute for redeploys.

## Tear down

```sh
gcloud functions delete weather-api-fn --gen2 --region=$REGION --quiet
gcloud functions delete cache-service-fn --gen2 --region=$REGION --quiet
```

The Artifact Registry images stick around — clean up via the
Cloud Run path's tear-down (or leave them; they're cheap).
