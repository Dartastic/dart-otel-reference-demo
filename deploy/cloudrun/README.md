# Cloud Run deployment

The same `weather_api` and `cache_service` binaries that run in the
[local stack](../local/) deploy unchanged to [Google Cloud Run][run].
Same Dockerfiles, same env-var-driven OTel configuration, same
trace tree, same metric semconv. The runtime is selected by the
deployment environment, not by the code.

> **Status.** Deploy scripts for `weather-api` and `cache-service`
> ship today. Both services are `--allow-unauthenticated` for now
> so you can drive a request from your laptop and see the trace
> tree end-to-end. The remaining work — service-to-service
> authentication that lets `cache-service` reject anything that
> isn't `weather-api` — is described under
> [Service-to-service authentication](#service-to-service-authentication-pending)
> and is the next change to land.
>
> Telemetry on the Cloud Run path uses
> [Google Cloud Operations](#option-a--google-cloud-operations-recommended)
> (Cloud Trace + Cloud Logging + Cloud Monitoring). Grafana LGTM is
> a local-stack convenience — running it on Cloud Run hits Cloud
> Run's one-port-per-service constraint and isn't worth the moving
> parts when GCP's native observability stack handles OTLP natively.

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
same env vars the local stack uses. Cloud Run is a managed runtime
on a managed cloud, and the natural answer is the cloud's own
observability stack rather than running a self-hosted
Tempo/Mimir/Loki on top of it.

### Option A — Google Cloud Operations (recommended)

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

After a `curl` against the public weather-api URL, the trace tree
shows up in
[Cloud Trace's explorer][trace-explorer] keyed off
`service.name=weather-api`. Click any span to see the full
hierarchy and any logs Cloud Logging captured during the same trace.

### Option B — Dartastic Cloud

Coming online; the endpoint and tenant configuration will be
documented here once the public Cloud is live. Same OTLP shape as
above (gRPC), with API-key auth via
`OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer ...` set as a
`--set-secrets` reference into Secret Manager so the key never
lands in source.

### Option C — Any other OTLP-compatible backend

Honeycomb, your own self-hosted OTel Collector, or anything else
that speaks OTLP works the same way:

```sh
export OTEL_EXPORTER_OTLP_ENDPOINT="https://api.your-backend.example"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"
```

API keys belong in Secret Manager and reach the container via
`--set-secrets`, not the env YAML files. (The deploy scripts don't
include this wiring by default — add it to your
`deploy-*-service.sh` if you go this route.)

> **Why not Grafana LGTM on Cloud Run?** It's the local stack's
> backend, and it would be nice to keep one observability surface.
> But Cloud Run exposes exactly one external port per service while
> LGTM wants three (3000 for Grafana UI, 4317 for OTLP gRPC, 4318
> for OTLP HTTP). The viable resolutions all involve a sidecar
> reverse proxy or splitting LGTM across multiple services with a
> shared backing store, and at that point you're better off using
> Cloud Operations natively. Run LGTM via `tool/stack.sh up` for
> dev and demos; let GCP's stack handle production.

## Service-to-service authentication (pending)

The current scripts deploy both `weather-api` and `cache-service`
with `--allow-unauthenticated` so the demo works end-to-end with a
single `curl`. That is **not the production-correct pattern**: in a
real deployment, only `weather-api` should be public, and
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
intentionally small but it crosses the package boundary; the
follow-up commit lands it.

Once that ships, `deploy-cache-service.sh` swaps
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
[trace-explorer]: https://console.cloud.google.com/traces/list
