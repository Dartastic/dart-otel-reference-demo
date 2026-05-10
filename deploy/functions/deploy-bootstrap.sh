#!/usr/bin/env bash
#
# deploy/functions/deploy-bootstrap.sh
#
# One-time setup for a fresh Google Cloud project: enables the APIs
# Cloud Functions Gen 2 needs and creates the Artifact Registry
# repository the deploy scripts push images to.
#
# Functions Gen 2 is built on Cloud Run + Cloud Build + Eventarc,
# so this is a superset of the Cloud Run bootstrap. Re-running it
# on a project that already has the Cloud Run path enabled is
# safe — only the eventarc API and any unrelated Functions API
# are net-new.
#
#   bash deploy/functions/deploy-bootstrap.sh
#
# Reads PROJECT, REGION, ARTIFACT_REPO from
# `deploy/functions/config.sh` or your shell environment.

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

echo "==> Setting active project to $PROJECT"
gcloud config set project "$PROJECT" >/dev/null

echo "==> Enabling required APIs (this may take a minute on first run)"
# - cloudfunctions.googleapis.com  Functions Gen 2 control plane
# - run.googleapis.com             Cloud Run (Functions Gen 2 runs on it)
# - cloudbuild.googleapis.com      Cloud Build (image builds in deploy scripts)
# - artifactregistry...            Artifact Registry (image storage)
# - eventarc.googleapis.com        Eventarc (Functions Gen 2 dependency,
#                                  even for HTTP triggers)
# - iam.googleapis.com             service accounts (inter-service auth)
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  eventarc.googleapis.com \
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
echo "      bash deploy/functions/deploy-cache-service.sh"
echo "      bash deploy/functions/deploy-weather-api.sh"
