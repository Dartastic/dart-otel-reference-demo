#!/usr/bin/env bash
#
# deploy/cloudrun/deploy-cache-service.sh
#
# Builds the cache_service container image with Cloud Build, pushes
# it to Artifact Registry, and deploys it to Cloud Run.
#
# Run from the repository root:
#
#   bash deploy/cloudrun/deploy-cache-service.sh
#
# Reads PROJECT, REGION, ARTIFACT_REPO, CACHE_SERVICE_SERVICE,
# OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_EXPORTER_OTLP_PROTOCOL from
# `deploy/cloudrun/config.sh` (copy `config.example.sh`) or your
# shell environment.
#
# What the script does:
#   1. Submits a Cloud Build using services/cache_service/Dockerfile
#      and the repository root as the build context (because the
#      Dart workspace's pubspec.yaml at the root resolves all member
#      packages — same constraint as docker-compose).
#   2. Tags the resulting image with the short git SHA so revisions
#      are reproducible. Falls back to `dev` if not in a git repo.
#   3. Deploys to Cloud Run with `--no-allow-unauthenticated`. Only
#      callers that present a valid service-account ID token with
#      the cache-service URL as the audience are accepted. The
#      script grants `roles/run.invoker` to weather-api's runtime
#      service account so weather-api can call cache-service via
#      the WeatherClient.tokenProvider path
#      (cloudRunIdTokenProvider in weather_otel).
#   4. Prints the resulting service URL — weather-api needs it as
#      WEATHER_UPSTREAM_URL and as the audience claim on the
#      ID tokens it mints.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Source per-reader config if present, otherwise rely on the shell
# environment carrying the same variables. Fail loudly when
# anything required is missing — better than deploying to the wrong
# project by accident.
if [ -f deploy/cloudrun/config.sh ]; then
  # shellcheck source=/dev/null
  source deploy/cloudrun/config.sh
fi

: "${PROJECT:?Set PROJECT in deploy/cloudrun/config.sh or your shell}"
: "${REGION:?Set REGION in deploy/cloudrun/config.sh or your shell}"
: "${ARTIFACT_REPO:?Set ARTIFACT_REPO}"
: "${CACHE_SERVICE_SERVICE:?Set CACHE_SERVICE_SERVICE}"

# Resolve image tag from git so each deploy is traceable to a commit.
if git -C "$ROOT_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  # Mark dirty trees so a deploy from uncommitted code is obvious in
  # the console. Won't break the deploy.
  if ! git -C "$ROOT_DIR" diff --quiet HEAD; then
    TAG="${TAG}-dirty"
  fi
else
  TAG="dev"
fi

IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/${ARTIFACT_REPO}/cache-service:${TAG}"

echo "==> Building cache_service image"
echo "    Image:        $IMAGE"
echo "    Project:      $PROJECT"
echo "    Region:       $REGION"
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

# Build the env-vars set passed to gcloud run deploy. Static values
# come from the YAML file; dynamic values (OTLP endpoint and
# protocol) are layered on top so we don't write project-specific
# values to a file that's checked into git.
DYNAMIC_ENV=()
if [ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_ENDPOINT=${OTEL_EXPORTER_OTLP_ENDPOINT}")
fi
if [ -n "${OTEL_EXPORTER_OTLP_PROTOCOL:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_PROTOCOL=${OTEL_EXPORTER_OTLP_PROTOCOL}")
fi
# Cloud Run + grpc OTLP needs OTEL_EXPORTER_OTLP_INSECURE=true if
# you're not terminating TLS in front of the collector — same as
# the local compose stack. Leaving this off when the endpoint is
# `telemetry.googleapis.com` (which terminates TLS) is correct.
if [ -n "${OTEL_EXPORTER_OTLP_INSECURE:-}" ]; then
  DYNAMIC_ENV+=("OTEL_EXPORTER_OTLP_INSECURE=${OTEL_EXPORTER_OTLP_INSECURE}")
fi

echo "==> Deploying cache_service to Cloud Run"
gcloud run deploy "$CACHE_SERVICE_SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --image="$IMAGE" \
  --env-vars-file=deploy/cloudrun/env/cache-service.env.yaml \
  ${DYNAMIC_ENV[@]:+--update-env-vars="$(IFS=,; echo "${DYNAMIC_ENV[*]}")"} \
  --no-allow-unauthenticated \
  --port=8090 \
  --cpu=1 \
  --memory=512Mi \
  --min-instances=0 \
  --max-instances=10 \
  --quiet >/dev/null

URL="$(gcloud run services describe "$CACHE_SERVICE_SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(status.url)')"

# Bind the run.invoker role for weather-api's runtime service
# account on this Cloud Run service. Default Compute Engine SA is
# what Cloud Run uses unless --service-account was passed at deploy
# time; teams with a custom per-service SA should set
# WEATHER_API_RUNTIME_SA in config.sh.
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT" \
  --format='value(projectNumber)')"
WEATHER_API_RUNTIME_SA="${WEATHER_API_RUNTIME_SA:-${PROJECT_NUMBER}-compute@developer.gserviceaccount.com}"

echo "==> Binding run.invoker on cache-service for $WEATHER_API_RUNTIME_SA"
gcloud run services add-iam-policy-binding "$CACHE_SERVICE_SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --member="serviceAccount:${WEATHER_API_RUNTIME_SA}" \
  --role=roles/run.invoker \
  --quiet >/dev/null

echo
echo "==> cache-service deployed: $URL"
echo "    Locked down with --no-allow-unauthenticated."
echo "    weather-api's runtime SA has run.invoker on this service."
echo "    Pass the URL as WEATHER_UPSTREAM_URL to deploy-weather-api.sh,"
echo "    or set it in deploy/cloudrun/config.sh for re-runs."
