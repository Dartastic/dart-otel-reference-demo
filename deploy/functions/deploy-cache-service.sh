#!/usr/bin/env bash
#
# deploy/functions/deploy-cache-service.sh
#
# Deploys cache_service as a Cloud Functions Gen 2 HTTP function.
#
# Cloud Functions Gen 2 runs on Cloud Run under the hood, so the
# image we deploy is built from the same services/cache_service/
# Dockerfile the Cloud Run path uses. The differences are:
#
#   1. The deploy command is `gcloud functions deploy --gen2`
#      instead of `gcloud run deploy`. The Functions API exposes a
#      slightly different surface for trigger configuration,
#      retry policy, and event filters that the demo doesn't use
#      but real production functions often do.
#   2. The function name appears in `faas.name` in OTel resource
#      attributes; we set it explicitly in the env YAML so the
#      same binary running on Cloud Run vs Functions can be
#      separated in dashboards.
#   3. IAM is the same (Cloud Run-style: roles/run.invoker on the
#      function for the caller's runtime SA). Functions Gen 2
#      also accepts roles/cloudfunctions.invoker, which maps to
#      the same underlying permission.
#
# Service-to-service auth: the function deploys
# `--no-allow-unauthenticated`. weather-api's runtime SA gets
# roles/run.invoker on this function so it can call through.
#
#   bash deploy/functions/deploy-cache-service.sh

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
: "${CACHE_SERVICE_FUNCTION:?Set CACHE_SERVICE_FUNCTION}"

if git -C "$ROOT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  if ! git -C "$ROOT_DIR" diff --quiet HEAD; then
    TAG="${TAG}-dirty"
  fi
else
  TAG="dev"
fi

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/cache-service-fn:${TAG}"

echo "==> Building cache_service image for Functions Gen 2"
echo "    Image:        $IMAGE"
echo "    Function:     $CACHE_SERVICE_FUNCTION"
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
      - services/cache_service/Dockerfile
      - -t
      - $IMAGE
      - .
images:
  - $IMAGE
EOF

DYNAMIC_ENV=()
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}")
fi
if [ -n "${OTEL_EXPORTER_OTLP_PROTOCOL:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_EXPORTER_OTLP_PROTOCOL}")
fi
if [ -n "${OTEL_EXPORTER_OTLP_INSECURE:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_INSECURE=${OTEL_EXPORTER_OTLP_INSECURE}")
fi

echo "==> Deploying cache_service as a Functions Gen 2 HTTP function"
# `--no-allow-unauthenticated` and `--gen2` are the load-bearing
# flags here. `--source` accepts a build-context directory; we use
# the repo root so the workspace's pubspec.yaml resolves member
# packages exactly the way `docker build` does in the cloudrun
# scripts. The Dockerfile path is relative to that source.
gcloud functions deploy "$CACHE_SERVICE_FUNCTION" \
  --gen2 \
  --project="$PROJECT" \
  --region="$REGION" \
  --runtime=custom \
  --source=. \
  --dockerfile=services/cache_service/Dockerfile \
  --trigger-http \
  --no-allow-unauthenticated \
  --env-vars-file=deploy/functions/env/cache-service.env.yaml \
  ${DYNAMIC_ENV[@]:+--update-env-vars="$(IFS=,; echo "${DYNAMIC_ENV[*]}")"} \
  --memory=512Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=10 \
  --quiet >/dev/null

URL="$(gcloud functions describe "$CACHE_SERVICE_FUNCTION" \
  --gen2 \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(serviceConfig.uri)')"

# Bind run.invoker for weather-api's runtime SA. Same mechanic as
# the cloudrun path: Functions Gen 2 IS Cloud Run, so the IAM
# binding uses the run.services API. Default Compute Engine SA
# unless WEATHER_API_RUNTIME_SA is overridden.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" \
  --format='value(projectNumber)')"
WEATHER_API_RUNTIME_SA="${WEATHER_API_RUNTIME_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

echo "==> Binding run.invoker for $WEATHER_API_RUNTIME_SA"
gcloud run services add-iam-policy-binding "$CACHE_SERVICE_FUNCTION" \
  --project="$PROJECT" \
  --region="$REGION" \
  --member="serviceAccount:${WEATHER_API_RUNTIME_SA}" \
  --role=roles/run.invoker \
  --quiet >/dev/null

echo
echo "==> $CACHE_SERVICE_FUNCTION deployed: $URL"
echo "    Locked down with --no-allow-unauthenticated."
echo "    Pass the URL as WEATHER_UPSTREAM_URL to deploy-weather-api.sh,"
echo "    or set it in deploy/functions/config.sh for re-runs."
