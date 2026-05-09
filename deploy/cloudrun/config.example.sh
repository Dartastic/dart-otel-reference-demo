# deploy/cloudrun/config.example.sh
#
# Reader configuration for the Cloud Run deploy scripts.
#
# Copy this file to `config.sh` (which is gitignored) and edit the
# values below for your GCP project. The deploy scripts source
# `config.sh` if it exists; otherwise they fall back to environment
# variables. You can also set the same variables in your shell and
# skip the file entirely.
#
#   cp deploy/cloudrun/config.example.sh deploy/cloudrun/config.sh
#   $EDITOR deploy/cloudrun/config.sh
#
# All values in this file are non-secret — they go in plain shell.
# Service account keys and any other secrets belong in Secret Manager,
# referenced from the env YAML files via `--set-secrets`.

# Your Google Cloud project ID. Find it with `gcloud projects list`.
export PROJECT="${PROJECT:-your-gcp-project-id}"

# Region for Cloud Run, Artifact Registry, and Cloud Build. Pick one
# close to your users; latency matters more than the slight pricing
# differences between regions. The demo uses one region for everything
# so traffic between services stays in-region (free egress).
#   us-central1, us-east1, us-west1, europe-west1, asia-northeast1, …
export REGION="${REGION:-us-central1}"

# Artifact Registry repository name for the built service images.
# Created by deploy-bootstrap.sh on first run. Repository names are
# lowercase letters, digits, and hyphens.
export ARTIFACT_REPO="${ARTIFACT_REPO:-dart-otel-demo}"

# Cloud Run service names. Hyphens, not underscores — Cloud Run
# rejects underscores. Override if you want to deploy multiple
# environments side by side (e.g. weather-api-staging).
export WEATHER_API_SERVICE="${WEATHER_API_SERVICE:-weather-api}"
export CACHE_SERVICE_SERVICE="${CACHE_SERVICE_SERVICE:-cache-service}"

# OTLP endpoint your services should export to. Three reasonable
# choices:
#
#   1. Google Cloud Operations (Cloud Trace + Cloud Logging + Cloud
#      Monitoring) — production-correct on GCP. Endpoint is
#      `https://telemetry.googleapis.com:443`. Requires the Telemetry
#      API enabled and `roles/telemetry.tracesWriter` on each
#      service's runtime service account. Spans and metrics land in
#      Cloud Trace / Cloud Monitoring; logs land in Cloud Logging
#      via the same telemetry endpoint.
#
#   2. Grafana LGTM running on Cloud Run — same observability surface
#      as the local stack. Requires deploying the lgtm container
#      separately. Pending — see the Phase 2 section in the
#      deploy/cloudrun/README.md.
#
#   3. Any external OTLP-compatible backend (Honeycomb, Datadog,
#      Dartastic, your own collector) — set the endpoint and add
#      `OTEL_EXPORTER_OTLP_HEADERS=Authorization=...` to the env
#      YAML for auth.
#
# Phase 1 leaves this empty so the SDK falls back to its default
# (`http://localhost:4318` — which exports nowhere on Cloud Run, no
# error). Set it before deploy if you want telemetry from the start.
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
