#!/usr/bin/env bash
#
# deploy/cloudrun/deploy-bootstrap.sh
#
# One-time setup for a fresh Google Cloud project: enables the APIs
# the demo needs and creates the Artifact Registry repository the
# build/deploy scripts push images to.
#
# Idempotent — re-running it on a project that's already set up is
# a no-op (Google's API enablement and `--quiet` create-if-missing
# semantics handle this).
#
#   bash deploy/cloudrun/deploy-bootstrap.sh
#
# Reads PROJECT, REGION, ARTIFACT_REPO from
# `deploy/cloudrun/config.sh` or your shell environment.

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

echo "==> Setting active project to $PROJECT"
gcloud config set project "$PROJECT" >/dev/null

echo "==> Enabling required APIs (this may take a minute on first run)"
# - run.googleapis.com         Cloud Run (services)
# - cloudbuild.googleapis.com  Cloud Build (image builds in deploy scripts)
# - artifactregistry...        Artifact Registry (image storage)
# - iam.googleapis.com         service accounts (Phase 2 inter-service auth)
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  --quiet

echo "==> Ensuring Artifact Registry repository '$ARTIFACT_REPO' exists in $REGION"
if ! gcloud artifacts repositories describe "$ARTIFACT_REPO" \
       --location="$REGION" --project="$PROJECT" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$ARTIFACT_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="Container images for the Dart OTel reference demo" \
    --project="$PROJECT" \
    --quiet
else
  echo "    (already exists — skipping)"
fi

echo
echo "==> Bootstrap complete."
echo "    Next:"
echo "      bash deploy/cloudrun/deploy-cache-service.sh"
echo "      bash deploy/cloudrun/deploy-weather-api.sh"
