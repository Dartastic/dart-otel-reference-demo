#!/usr/bin/env bash
#
# deploy/functions/deploy-weather-api.sh
#
# Deploys weather_api as a Cloud Functions Gen 2 HTTP function.
# Looks up cache-service-fn's URL via gcloud and injects it as
# WEATHER_UPSTREAM_URL — same wire-up as the cloudrun path, just
# with `gcloud functions describe` instead of
# `gcloud run services describe`.
#
# Run AFTER deploy-cache-service.sh:
#
#   bash deploy/functions/deploy-weather-api.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [ -f deploy/functions/config.sh ]; then
  # shellcheck source=/dev/null
  source deploy/functions/config.sh
fi

: "${PROJECT:?Set PROJECT in deploy/functions/config.sh or your shell}"
: "${REGION:?Set REGION in deploy/functions/config.sh or your shell}"
: "${ARTIFACT_REPO:?Set ARTIFACT_REPO}"
: "${WEATHER_API_FUNCTION:?Set WEATHER_API_FUNCTION}"
: "${CACHE_SERVICE_FUNCTION:?Set CACHE_SERVICE_FUNCTION}"

echo "==> Looking up $CACHE_SERVICE_FUNCTION URL"
CACHE_URL="$(gcloud functions describe "$CACHE_SERVICE_FUNCTION" \
  --gen2 \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(serviceConfig.uri)' 2>/dev/null || true)"

if [ -z "$CACHE_URL" ]; then
  echo "error: $CACHE_SERVICE_FUNCTION is not deployed in $REGION." >&2
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

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/weather-api-fn:${TAG}"

echo "==> Building weather_api image for Functions Gen 2"
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

echo "==> Deploying weather_api as a Functions Gen 2 HTTP function"
gcloud functions deploy "$WEATHER_API_FUNCTION" \
  --gen2 \
  --project="$PROJECT" \
  --region="$REGION" \
  --runtime=custom \
  --source=. \
  --dockerfile=services/weather_api/Dockerfile \
  --trigger-http \
  --allow-unauthenticated \
  --env-vars-file=deploy/functions/env/weather-api.env.yaml \
  --update-env-vars="$(IFS=,; echo "${DYNAMIC_ENV[*]}")" \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --quiet >/dev/null

URL="$(gcloud functions describe "$WEATHER_API_FUNCTION" \
  --gen2 \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(serviceConfig.uri)')"

echo
echo "==> $WEATHER_API_FUNCTION deployed: $URL"
echo
echo "Try it:"
echo "    curl -s '${URL}/weather/Boston?days=3' | jq ."
