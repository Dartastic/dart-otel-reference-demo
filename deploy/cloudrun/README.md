# Cloud Run deployment

The same `weather_api` and `cache_service` binaries that run in the
[local stack](../local/) deploy unchanged to [Google Cloud Run][run].
Same Dockerfiles, same env-var-driven OTel configuration, same
trace tree, same metric semconv. The runtime is selected by the
deployment environment, not by the code.

> **Status: Phase 1.** This phase ships the deploy scripts for
> `weather-api` and `cache-service`. Both services are
> `--allow-unauthenticated` for now so you can drive a request from
> your laptop and see the trace tree end-to-end. Phases 2 and 3 add
> service-to-service authentication and an OTLP-LGTM-on-Cloud-Run
> backend; both are flagged inline below.

## Prerequisites

You'll need:

- A Google Cloud project with **billing enabled**. Cloud Run, Cloud
  Build, and Artifact Registry all need billing on; the deploy
  fails with a clear error otherwise. The demo's runtime cost at
  zero traffic is dominated by Artifact Registry storage (~$0.10
  per GB-month for image storage; the two service images are tiny).
- The [`gcloud` CLI][gcloud-install] installed and authenticated:
  ```sh
  gcloud auth login                  # browser SSO
  gcloud auth application-default login
  gcloud config set project YOUR_PROJECT_ID
  ```
- Docker is **not** required locally — the build runs in Cloud
  Build, not on your machine.

## Configure once

```sh
cp deploy/cloudrun/config.example.sh deploy/cloudrun/config.sh
$EDITOR deploy/cloudrun/config.sh    # set PROJECT, REGION, OTLP endpoint
```

`config.sh` is gitignored — your project ID never reaches the repo.
Every script under `deploy/cloudrun/` sources `config.sh` if it
exists; you can also set the same variables in your shell and skip
the file entirely.

## Deploy

```sh
# First time on a fresh project — enables APIs + creates the
# Artifact Registry repository:
bash deploy/cloudrun/deploy-bootstrap.sh

# Order matters — weather-api needs cache-service's URL:
bash deploy/cloudrun/deploy-cache-service.sh
bash deploy/cloudrun/deploy-weather-api.sh

# Or all three in one go:
bash deploy/cloudrun/deploy-all.sh
```

Each deploy script tags the image with the short git SHA so each
revision in Cloud Run is traceable to a commit. Dirty trees get a
`-dirty` suffix.

After `deploy-weather-api.sh` finishes, it prints the public URL.
Drive a request:

```sh
curl -s 'https://weather-api-XXX.a.run.app/weather/Toulouse?days=3' | jq .
```

The same trace tree the local stack produces — `weather-api` →
`cache-service` → `open-meteo` — lands in whatever OTLP backend
you configured.

## Cloud Run resource attributes

The Dartastic SDK's `detectPlatformResources: true` (the default)
auto-detects most of the cloud and service identity attributes that
SREs expect on every span and metric. On Cloud Run you get the
following without any explicit configuration:

| Attribute              | Source                               |
| ---------------------- | ------------------------------------ |
| `service.name`         | argument to `OTel.initialize`        |
| `service.version`      | argument to `OTel.initialize`        |
| `service.instance.id`  | per-process UUID set by `weather_otel` bootstrap |
| `cloud.provider`       | `gcp`                                |
| `cloud.platform`       | `gcp_cloud_run`                      |
| `cloud.region`         | `K_REVISION` metadata (Cloud Run-injected) |
| `cloud.account.id`     | project number (from metadata server) |
| `process.runtime.*`    | `dart`, version                      |
| `host.*`               | container hostname, arch             |

We set `deployment.environment=cloudrun` explicitly via
`OTEL_RESOURCE_ATTRIBUTES` in
[`env/weather-api.env.yaml`](env/weather-api.env.yaml) and
[`env/cache-service.env.yaml`](env/cache-service.env.yaml) — that's
the one attribute the SDK doesn't know on its own (the same binary
could be deployed to dev / staging / prod and you want to slice
metrics by which one).

## Telemetry destination

The deploy scripts honor `OTEL_EXPORTER_OTLP_ENDPOINT` and
`OTEL_EXPORTER_OTLP_PROTOCOL` from your `config.sh` — exactly the
same env vars the local stack uses. Three reasonable choices on GCP:

### Option A — Google Cloud Operations (production-correct)

Cloud Trace, Cloud Monitoring, and Cloud Logging all accept OTLP
directly. Spans land in Cloud Trace, metrics in Cloud Monitoring,
logs in Cloud Logging — and the trace ↔ log correlation works out
of the box because the platform recognises OTLP `trace_id` /
`span_id`.

```sh
# In deploy/cloudrun/config.sh:
export OTEL_EXPORTER_OTLP_ENDPOINT="https://telemetry.googleapis.com:443"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
```

The runtime service account each Cloud Run service uses needs
`roles/telemetry.tracesWriter`,
`roles/telemetry.metricsWriter`, and
`roles/telemetry.logsWriter`. The deploy scripts don't grant these
automatically — production projects usually have a custom service
account per service, and we don't want to assume what yours is.
Granting the default Compute Engine service account works for a
quick demo:

```sh
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for role in roles/telemetry.tracesWriter \
            roles/telemetry.metricsWriter \
            roles/telemetry.logsWriter; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" \
    --role="$role" \
    --quiet
done
```

This is the recommended option for any deployment that's not
explicitly using Grafana for the demo's visualization.

### Option B — Grafana LGTM on Cloud Run (Phase 3 — pending design review)

Goal: keep the same Tempo / Mimir / Loki / Grafana surface as the
local stack so the dashboards we ship under
[`dashboards/grafana/`](../../dashboards/grafana/) work without
changes. Realistic on Cloud Run with one wrinkle: Cloud Run exposes
exactly **one external port per service**, while LGTM wants three
(3000 for Grafana UI, 4317 for OTLP gRPC, 4318 for OTLP HTTP).

Resolutions in rough cost order:

1. Single Cloud Run service exposing 4318 (OTLP HTTP) — telemetry
   ingress works; Grafana access requires a sidecar reverse proxy
   or a separately-deployed `grafana-only` service.
2. Two Cloud Run services (one for OTLP, one for Grafana) backed by
   a shared Cloud SQL / GCS-stored Tempo backend — proper, more
   moving parts.
3. Skip LGTM-on-Cloud-Run; recommend Option A (Cloud Operations) for
   anything past the local demo.

Phase 3 will pick one and ship the deploy script. For now, point at
Option A.

### Option C — External backend (Honeycomb, Dartastic, your own collector)

```sh
export OTEL_EXPORTER_OTLP_ENDPOINT="https://api.honeycomb.io"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
```

Add API keys via `--set-secrets` from Secret Manager — never bake
them into the env YAML files.

## Phase 2 — service-to-service authentication (pending)

Phase 1 leaves both `weather-api` and `cache-service` accessible to
the public Internet so the demo works end-to-end with a single
`curl`. That is **not the production-correct pattern**: in a real
deployment, only `weather-api` should be public, and
`cache-service` should accept requests only from `weather-api`.

The standard Cloud Run pattern is:

1. Deploy `cache-service` with `--no-allow-unauthenticated`.
2. Grant `weather-api`'s runtime service account the
   `roles/run.invoker` role on `cache-service`.
3. From `weather-api`, fetch a service-account ID token from the
   GCE metadata server (audience = `cache-service`'s URL) and
   include it as `Authorization: Bearer <token>` on every outbound
   request to `cache-service`.

The third step needs a small extension to `weather_client` —
specifically a `tokenProvider:` callback the client calls before
each request. The callback is a no-op locally and a
metadata-server-token fetch on Cloud Run. The library change is
intentionally small but it crosses the package boundary, so we're
checkpointing it for review before landing.

Once Phase 2 ships, `deploy-cache-service.sh` swaps
`--allow-unauthenticated` for the IAM-locked path and the deploy
becomes production-correct.

## Costs and quotas

At zero traffic, both services scale to zero and you pay nothing
for compute. Storage costs (Artifact Registry) for two ~10 MB
images are below the free tier. Cloud Build's free tier covers
~120 minutes per day at the time of writing — plenty for hand
deploys.

For sustained load, Cloud Run bills per request and per
container-second. The demo's defaults (`--cpu=1 --memory=512Mi`)
are conservative for the workloads we ship; tune up if your traffic
shape demands.

## Tear down

```sh
gcloud run services delete weather-api  --region=$REGION --quiet
gcloud run services delete cache-service --region=$REGION --quiet
gcloud artifacts repositories delete $ARTIFACT_REPO \
  --location=$REGION --quiet
```

Disabling APIs is optional — they're free at zero traffic.

[run]: https://cloud.google.com/run
[gcloud-install]: https://cloud.google.com/sdk/docs/install
