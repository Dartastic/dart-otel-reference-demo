#!/usr/bin/env bash
#
# tool/run.sh
#
# Runs one of the demo's service binaries locally for development.
# Auto-discovers everything under services/<name>/bin/server.dart so
# new services need no script changes.
#
# Run from anywhere — the script chdir's to the repository root.
#
# Usage:
#   tool/run.sh                 # runs the only service if there is one,
#                                 otherwise lists choices and exits.
#   tool/run.sh <service>       # runs services/<service>/bin/server.dart
#   tool/run.sh --list          # lists discovered services and exits
#
# Environment passthrough:
#   PORT, ADMIN_PORT, OTEL_DEMO_MODE, OTEL_*  — forwarded to the service
#                                                exactly as set in the
#                                                calling shell. See each
#                                                service's README for
#                                                accepted variables.
#
# To run the demo with telemetry going somewhere visible, the usual
# pattern is:
#
#   OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
#   OTEL_EXPORTER_OTLP_PROTOCOL=grpc \
#   tool/run.sh weather_api
#
# This script does not start collectors, dashboards, or sibling
# services — it runs ONE binary in the foreground. For the full local
# stack (collector + dashboards + every service), use deploy/local/
# (TBD as of this writing) or invoke this script multiple times in
# separate shells with different PORT values.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v dart >/dev/null 2>&1; then
  echo "error: 'dart' is not on PATH. Install the Dart SDK and retry." >&2
  exit 1
fi

# Discover available service binaries.
mapfile -t ENTRIES < <(
  find "$ROOT_DIR/services" -maxdepth 3 -type f -name 'server.dart' 2>/dev/null \
    | sort
)

declare -a NAMES=()
declare -A ENTRY_FOR=()
for entry in "${ENTRIES[@]}"; do
  svc_dir="$(dirname "$(dirname "$entry")")"
  name="$(basename "$svc_dir")"
  NAMES+=("$name")
  ENTRY_FOR["$name"]="$entry"
done

list_services() {
  if [ "${#NAMES[@]}" -eq 0 ]; then
    echo "(no services with bin/server.dart found under services/)"
    return
  fi
  echo "Available services:"
  for n in "${NAMES[@]}"; do
    echo "  $n  ($(realpath --relative-to="$ROOT_DIR" "${ENTRY_FOR[$n]}"))"
  done
}

case "${1:-}" in
  --list|-l)
    list_services
    exit 0
    ;;
  -h|--help)
    sed -n '3,38p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  '')
    if [ "${#NAMES[@]}" -eq 1 ]; then
      target="${NAMES[0]}"
    else
      list_services
      echo
      echo "error: more than one service available — pick one explicitly:" >&2
      echo "       tool/run.sh <service>" >&2
      exit 2
    fi
    ;;
  *)
    target="$1"
    if [ -z "${ENTRY_FOR[$target]+x}" ]; then
      echo "error: no service named '$target'" >&2
      list_services
      exit 2
    fi
    ;;
esac

entry="${ENTRY_FOR[$target]}"
echo "==> dart pub get (workspace)"
dart pub get >/dev/null

echo "==> dart run $entry"
echo "    (PORT=${PORT:-8080}${ADMIN_PORT:+ ADMIN_PORT=$ADMIN_PORT}${OTEL_DEMO_MODE:+ OTEL_DEMO_MODE=$OTEL_DEMO_MODE})"
echo "    Ctrl-C to stop"
echo

# exec replaces this shell with the dart process so SIGINT and SIGTERM
# go straight to the Dart binary — that's what triggers the
# weather_otel signal handler that flushes spans before exit.
exec dart run "$entry"
