#!/usr/bin/env bash
#
# deploy/cloudrun/deploy-weather-api.sh
#
# Builds the weather_api container image with Cloud Build, pushes
# it to Artifact Registry, and deploys it to Cloud Run with the
# cache-service URL injected as WEATHER_UPSTREAM_URL.
#
# Run from the repository root:
#
#   bash deploy/cloudrun/deploy-weather-api.sh
#
# Reads PROJECT, REGION, ARTIFACT_REPO, WEATHER_API_SERVICE,
# CACHE_SERVICE_SERVICE, OTEL_EXPORTER_OTLP_* from
# `deploy/cloudrun/config.sh` or your shell environment.
#
# This script must run AFTER deploy-cache-service.sh — it queries
# Cloud Run for cache-service's URL and fails if cache-service
# isn't already deployed.
#
# What the script does:
#   1. Looks up cache-service's URL via `gcloud run services
#      describe`. Cache-service must be in the same region.
#   2. Submits a Cloud Build using services/weather_api/Dockerfile.
#   3. Deploys to Cloud Run, injecting WEATHER_UPSTREAM_URL into
#      the env so weather-api's outbound HTTP client points at
#      cache-service.
#   4. Currently --allow-unauthenticated. Phase 2 of the deployment
#      lifts this and locks down weather-api to only accept traffic
#      from your IAP / API Gateway / etc.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [ -f deploy/cloudrun/config.sh ]; then
  # shellcheck source=/dev/null
  source deploy/cloudrun/config.sh
fi

: "${PROJECT:?Set PROJECT in deploy/cloudrun/config.sh or your shell}"
: "${REGION:?Set REGION in deploy/cloudrun/config.sh or your shell}"
: "${ARTIFACT_REPO:?Set ARTIFACT_REPO}"
: "${WEATHER_API_SERVICE:?Set WEATHER_API_SERVICE}"
: "${CACHE_SERVICE_SERVICE:?Set CACHE_SERVICE_SERVICE}"

echo "==> Looking up cache-service URL"
CACHE_URL="$(gcloud run services describe "$CACHE_SERVICE_SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(status.url)' 2>/dev/null || true)"

if [ -z "$CACHE_URL" ]; then
  echo "error: cache-service is not deployed in $REGION." >&2
  echo "       Run deploy-cache-service.sh first." >&2
  exit 1
fi
echo "    WEATHER_UPSTREAM_URL=$CACHE_URL"

if git -C "$ROOT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  if ! git -C "$ROOT_DIR" diff --quiet HEAD; then
    TAG="${TAG}-dirty"
  fi
else
  TAG="dev"
fi

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/weather-api:${TAG}"

echo "==> Building weather_api image"
echo "    Image:        $IMAGE"
gcloud builds submit \
  --project="$PROJECT" \
  --region="$REGION" \
  --tag="$IMAGE" \
  --config=- <<EOF >/dev/null
steps:
  - name: gcr.io/cloud-builders/docker
    args:
      - build
      - -f
      - services/weather_api/Dockerfile
      - -t
      - $IMAGE
      - .
images:
  - $IMAGE
EOF

DYNAMIC_ENV=("WEATHER_UPSTREAM_URL=${CACHE_URL}")
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}")
fi
if [ -n "${OTEL_EXPORTER_OTLP_PROTOCOL:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_EXPORTER_OTLP_PROTOCOL}")
fi
if [ -n "${OTEL_EXPORTER_OTLP_INSECURE:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_INSECURE=${OTEL_EXPORTER_OTLP_INSECURE}")
fi

echo "==> Deploying weather_api to Cloud Run"
gcloud run deploy "$WEATHER_API_SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --image="$IMAGE" \
  --env-vars-file=deploy/cloudrun/env/weather-api.env.yaml \
  --update-env-vars="$(IFS=,; echo "${DYNAMIC_ENV[*]}")" \
  --allow-unauthenticated \
  --port=8080 \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=0 \
  --max-instances=10 \
  --quiet >/dev/null

URL="$(gcloud run services describe "$WEATHER_API_SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(status.url)')"

echo
echo "==> weather-api deployed: $URL"
echo
echo "Try it:"
echo "    curl -s '${URL}/weather/Boston?days=3' | jq ."
