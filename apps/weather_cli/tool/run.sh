#!/usr/bin/env bash
#
# apps/weather_cli/tool/run.sh
#
# Run ONLY weather_cli, with its telemetry pointed at a remote OTLP ingest
# endpoint (default: the rice-19 box). The endpoint is selected purely through
# the STANDARD OpenTelemetry exporter env vars — nothing Dartastic-specific,
# no code changes. weather_otel's bootstrap resolves the exporter from these.
#
# Usage:
#   DARTASTIC_KEY=<otel-ingest key> tool/run.sh <city> [extra weather_cli args…]
#
# Knobs (all standard OTel, or the slug shortcut):
#   OTEL_SLUG                      box slug → otlp.<slug>.dartastic.io
#                                  (default dartastic-io-rice-19)
#   OTEL_EXPORTER_OTLP_ENDPOINT    full endpoint; wins over OTEL_SLUG
#   OTEL_EXPORTER_OTLP_PROTOCOL    grpc | http/protobuf   (default grpc)
#   OTEL_SERVICE_NAME             default weather-cli
#   OTEL_RESOURCE_ATTRIBUTES      default deployment.environment=demo
#   WEATHER_API_URL              the upstream the CLI calls (unrelated to OTLP)
set -euo pipefail

CLI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$CLI_DIR/../.." && pwd)"

command -v dart >/dev/null 2>&1 || { echo "error: dart not on PATH" >&2; exit 1; }
: "${DARTASTIC_KEY:?set DARTASTIC_KEY to your otel-ingest Bearer token}"
: "${OTEL_SLUG:=dartastic-io-rice-19}"

# ── The only thing pointing the CLI at rice-19: standard OTel env vars ──
# NOTE: the :443 is REQUIRED. Per the OTel spec an OTLP/gRPC endpoint with no
# explicit port defaults to 4317 — which on the box is loopback-only. The public
# endpoint (gRPC and HTTP) is nginx on :443, which TLS-terminates and grpc_pass /
# proxy_pass to the local collector. Without :443 the SDK dials 4317 and times out.
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-https://otlp.${OTEL_SLUG}.dartastic.io:443}"
export OTEL_EXPORTER_OTLP_PROTOCOL="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/protobuf}"
export OTEL_EXPORTER_OTLP_HEADERS="authorization=Bearer ${DARTASTIC_KEY}"
export OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-weather-cli}"
export OTEL_RESOURCE_ATTRIBUTES="${OTEL_RESOURCE_ATTRIBUTES:-deployment.environment=demo}"

echo "==> OTLP  → $OTEL_EXPORTER_OTLP_ENDPOINT  (protocol=$OTEL_EXPORTER_OTLP_PROTOCOL)"
echo "==> service=$OTEL_SERVICE_NAME   (auth header set from DARTASTIC_KEY)"
echo "==> dart run bin/weather.dart $*"
echo

# Resolve the workspace once (quiet, non-fatal), then run the CLI in the
# foreground so SIGINT reaches the Dart process → spans flush before exit.
( cd "$ROOT_DIR" && dart pub get >/dev/null 2>&1 ) || true
cd "$CLI_DIR"
exec dart run bin/weather.dart "$@"
