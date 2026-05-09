#!/usr/bin/env bash
#
# tool/stack.sh
#
# Thin convenience wrapper around `docker compose` for the local
# stack at deploy/local/docker-compose.yml. Exists so you don't have
# to remember the path or `cd` to it.
#
# Run from anywhere — the script chdir's to the repository root.
#
# Usage:
#   tool/stack.sh <docker-compose-subcommand> [args]
#   tool/stack.sh up                    # bring up the stack (rebuilds images)
#   tool/stack.sh up -d                 # detached
#   tool/stack.sh down                  # stop containers; keep data volume
#   tool/stack.sh down -v               # also wipe accumulated traces
#   tool/stack.sh ps                    # running container status
#   tool/stack.sh logs                  # tail logs from all services
#   tool/stack.sh logs weather-api      # tail one service
#   tool/stack.sh restart cache-service # restart one service
#
# Any subcommand and flag accepted by `docker compose` is passed
# through unchanged — this script does not own the surface, it just
# locates the compose file.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: 'docker' is not on PATH. Install Docker and retry." >&2
  exit 1
fi

# `docker compose` (v2 plugin) is required. The legacy `docker-compose`
# binary is not supported here — version skew between the two has
# burned enough demo audiences that we just refuse to run on it.
if ! docker compose version >/dev/null 2>&1; then
  echo "error: 'docker compose' (v2 plugin) is required." >&2
  echo "       The legacy 'docker-compose' binary is not supported." >&2
  exit 1
fi

COMPOSE_FILE="$ROOT_DIR/deploy/local/docker-compose.yml"
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "error: compose file not found at $COMPOSE_FILE" >&2
  exit 1
fi

# Default to a useful command if nothing was passed.
if [ "$#" -eq 0 ]; then
  cat <<EOF
tool/stack.sh: thin wrapper around \`docker compose -f deploy/local/docker-compose.yml\`

Usage:
  tool/stack.sh up [-d]                  bring up the stack
  tool/stack.sh down [-v]                stop containers (and optionally wipe data)
  tool/stack.sh ps                       container status
  tool/stack.sh logs [<service>]         tail logs
  tool/stack.sh restart <service>        restart one service

See deploy/local/README.md for the full walkthrough.
EOF
  exit 0
fi

# Default `up` to also rebuild local images so source changes are
# picked up. This matches developer expectations more often than
# the bare-`up` behaviour of using cached images.
if [ "$1" = "up" ]; then
  shift
  exec docker compose -f "$COMPOSE_FILE" up --build "$@"
fi

exec docker compose -f "$COMPOSE_FILE" "$@"
