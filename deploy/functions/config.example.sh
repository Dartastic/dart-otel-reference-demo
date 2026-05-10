# deploy/functions/config.example.sh
#
# Reader configuration for the Cloud Functions Gen 2 deploy scripts.
#
# Copy this file to `config.sh` (which is gitignored) and edit the
# values for your GCP project, or set the same variables in your
# shell. Same shape as deploy/cloudrun/config.sh — a project that
# already has a Cloud Run config.sh can copy that file over.
#
#   cp deploy/functions/config.example.sh deploy/functions/config.sh
#   $EDITOR deploy/functions/config.sh

# Your Google Cloud project ID.
export PROJECT="${PROJECT:-your-gcp-project-id}"

# Region for Cloud Functions, Artifact Registry, and Cloud Build.
# Functions Gen 2 supports the same regions as Cloud Run.
export REGION="${REGION:-us-central1}"

# Artifact Registry repository for the function images. Reusing the
# same repo as the Cloud Run path is fine — Functions Gen 2 stores
# its built images in Artifact Registry too.
export ARTIFACT_REPO="${ARTIFACT_REPO:-dart-otel-demo}"

# Function names. Hyphens, not underscores. Override to deploy
# multiple environments side by side.
export WEATHER_API_FUNCTION="${WEATHER_API_FUNCTION:-weather-api-fn}"
export CACHE_SERVICE_FUNCTION="${CACHE_SERVICE_FUNCTION:-cache-service-fn}"

# OTLP endpoint. Same shape as the Cloud Run path; see the
# walkthrough in deploy/functions/README.md and
# deploy/cloudrun/README.md § Telemetry destination for the three
# options. Cloud Operations is the recommended default on Cloud
# Functions Gen 2.
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-grpc}"
