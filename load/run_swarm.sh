#!/usr/bin/env bash
#
# load/run_swarm.sh
#
# Drives N parallel `weather_cli` invocations against a running
# weather_api, then forces a span flush so the result lands in the
# backend immediately. Exists for two reasons:
#
#   1. Generates enough trace volume to make the BatchSpanProcessor
#      actually batch — single curls hide the batching behavior
#      because the export cadence is faster than the request rate.
#   2. Gives the dashboards something to chart: RED metrics, latency
#      histograms, cache hit ratio over time, status-code mix.
#
# Each invocation produces an independent trace (its own root span,
# its own trace_id), so this is N independent traces, not one big
# trace. That's what real load looks like.
#
# Run from anywhere — the script chdir's to the repository root.
#
# Usage:
#   load/run_swarm.sh [options]
#
# Options:
#   --total N       Total invocations to perform.        Default: 100
#   --parallel P    Maximum concurrent workers.          Default: 10
#   --days D        Forecast horizon per invocation.     Default: 3
#   --upstream URL  weather_api base URL.                Default: $WEATHER_API_URL
#                                                                 or http://localhost:8080
#   --otlp-endpoint URL
#                   OTLP endpoint for the SWARM ITSELF — the spans
#                   the CLI invocations produce.          Default: http://localhost:4317
#   --no-flush      Skip the post-run flush step.        Default: flush both
#                                                                 admin endpoints
#   --bin PATH      Use this binary instead of `dart run`.
#                   If `tool/build.sh --release` has been run, this
#                   defaults to build/weather_cli/weather (much
#                   faster — no JIT warmup per invocation).
#
# Cities rotate through a fixed list of varied geographies — picked
# so cache hit ratio is interesting (some hits, some misses) and
# Open-Meteo's geocoder doesn't trivially short-circuit them all.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ── Defaults ──
TOTAL=100
PARALLEL=10
DAYS=3
UPSTREAM="${WEATHER_API_URL:-http://localhost:8080}"
OTLP_ENDPOINT="http://localhost:4317"
DO_FLUSH=1
BIN=""

# ── Cities — varied enough to hit different geocoder branches and
# generate a mix of cache hits and misses. The list intentionally
# repeats some entries so cache-hit dynamics show up after the first
# pass through the list.
CITIES=(
  "Toulouse"
  "Paris"
  "Tokyo"
  "London"
  "New York"
  "Sydney"
  "Mumbai"
  "São Paulo"
  "Toulouse"
  "Tokyo"
  "Cape Town"
  "Reykjavik"
)

# ── Arg parsing ──
while [ "$#" -gt 0 ]; do
  case "$1" in
    --total)         TOTAL="$2";          shift 2 ;;
    --parallel)      PARALLEL="$2";       shift 2 ;;
    --days)          DAYS="$2";           shift 2 ;;
    --upstream)      UPSTREAM="$2";       shift 2 ;;
    --otlp-endpoint) OTLP_ENDPOINT="$2";  shift 2 ;;
    --no-flush)      DO_FLUSH=0;          shift ;;
    --bin)           BIN="$2";            shift 2 ;;
    -h|--help)       sed -n '3,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

# ── Pick a runner: AOT exe if available, else `dart run`. ──
if [ -z "$BIN" ]; then
  if [ -x "$ROOT_DIR/build/weather_cli/weather" ]; then
    BIN="$ROOT_DIR/build/weather_cli/weather"
  fi
fi

if [ -n "$BIN" ]; then
  RUNNER=("$BIN")
else
  if ! command -v dart >/dev/null 2>&1; then
    echo "error: 'dart' is not on PATH and no AOT binary exists at" >&2
    echo "       build/weather_cli/weather. Run 'tool/build.sh --release'" >&2
    echo "       to compile it, or install the Dart SDK." >&2
    exit 1
  fi
  RUNNER=(dart run "$ROOT_DIR/apps/weather_cli/bin/weather.dart")
fi

# ── Dependency checks ──
if ! command -v xargs >/dev/null 2>&1; then
  echo "error: 'xargs' is required but not on PATH." >&2
  exit 1
fi

# ── Sanity-check the upstream is responsive before spawning a swarm. ──
if command -v curl >/dev/null 2>&1; then
  if ! curl -fsS --max-time 3 "${UPSTREAM%/}/healthz" >/dev/null 2>&1; then
    echo "error: upstream $UPSTREAM is not responding to /healthz." >&2
    echo "       Start the stack with 'tool/stack.sh up' or set --upstream." >&2
    exit 1
  fi
fi

cat <<EOF
==> Swarming weather_cli
    runner:        ${RUNNER[*]}
    upstream:      $UPSTREAM
    otlp endpoint: $OTLP_ENDPOINT
    total:         $TOTAL
    parallel:      $PARALLEL
    days/forecast: $DAYS
    cities:        ${#CITIES[@]} unique (rotated)
EOF

RESULTS_FILE="$(mktemp -t swarm-results.XXXXXX)"
trap 'rm -f "$RESULTS_FILE"' EXIT

# Worker function. Exported so xargs subshells can call it. Each
# worker runs ONE invocation and writes one line to stdout: 'ok' or
# 'fail'. We aggregate from those at the end.
#
# Word-splitting on $SWARM_RUNNER is intentional: bash exports
# strings, not arrays, so the runner ('dart run path/to/file.dart'
# or '/path/to/exe') is split into its argv on the worker side.
# This handles the common cases correctly. For paths containing
# spaces, set --bin to a path without spaces.
swarm_worker() {
  local city="$1"
  # shellcheck disable=SC2086 # word-splitting on SWARM_RUNNER is intentional
  if $SWARM_RUNNER \
      --quiet \
      --json \
      --upstream "$SWARM_UPSTREAM" \
      --days "$SWARM_DAYS" \
      "$city" >/dev/null 2>&1; then
    echo "ok"
  else
    echo "fail"
  fi
}
export -f swarm_worker

# Pass invocation context into the worker subshell environment.
export SWARM_RUNNER="${RUNNER[*]}"
export SWARM_UPSTREAM="$UPSTREAM"
export SWARM_DAYS="$DAYS"
export OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_ENDPOINT"
export OTEL_EXPORTER_OTLP_PROTOCOL="grpc"

# ── Run the swarm. ──
START_NS=$(date +%s%N 2>/dev/null || date +%s)

# Generate one city per invocation by rotating through the city list.
{
  for ((i = 0; i < TOTAL; i++)); do
    echo "${CITIES[i % ${#CITIES[@]}]}"
  done
} | xargs -P "$PARALLEL" -I {} bash -c 'swarm_worker "$@"' _ {} > "$RESULTS_FILE"

END_NS=$(date +%s%N 2>/dev/null || date +%s)

# ── Aggregate. ──
OK_COUNT=$(grep -c '^ok$' "$RESULTS_FILE" || true)
FAIL_COUNT=$(grep -c '^fail$' "$RESULTS_FILE" || true)
TOTAL_COUNT=$((OK_COUNT + FAIL_COUNT))

# Duration in seconds. The %N branch (nanoseconds) is GNU date; macOS
# date doesn't support it and we fall back to second resolution.
if [ "${#START_NS}" -gt 13 ]; then
  DURATION_MS=$(( (END_NS - START_NS) / 1000000 ))
  DURATION_S=$(awk "BEGIN { printf \"%.2f\", $DURATION_MS / 1000 }")
else
  DURATION_S=$((END_NS - START_NS))
fi

if [ "$DURATION_S" = "0" ] || [ "$DURATION_S" = "0.00" ]; then
  RPS="(infinite — too fast to measure)"
else
  RPS=$(awk "BEGIN { printf \"%.1f\", $TOTAL_COUNT / $DURATION_S }")
fi

cat <<EOF

==> Swarm complete
    completed:  $TOTAL_COUNT  (${OK_COUNT} ok, ${FAIL_COUNT} failed)
    duration:   ${DURATION_S}s
    throughput: ${RPS} req/s
EOF

# ── Force-flush the services so spans land in the backend right now,
# instead of waiting for the BatchSpanProcessor's natural cadence. ──
if [ "$DO_FLUSH" -eq 1 ]; then
  if ! command -v curl >/dev/null 2>&1; then
    echo "    (curl not on PATH — skipping post-run flush)"
  else
    echo
    echo "==> Forcing flush on admin endpoints"
    for endpoint in \
        "http://localhost:8081/flush" \
        "http://localhost:8091/flush"; do
      if curl -fsS --max-time 5 -X POST "$endpoint" >/dev/null 2>&1; then
        echo "    flushed: $endpoint"
      else
        echo "    flush failed: $endpoint (admin port may not be exposed)"
      fi
    done
  fi
fi

# Exit non-zero if anything failed — useful in CI as a smoke test.
[ "$FAIL_COUNT" -eq 0 ]
