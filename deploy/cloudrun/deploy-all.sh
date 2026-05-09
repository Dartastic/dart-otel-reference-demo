#!/usr/bin/env bash
#
# deploy/cloudrun/deploy-all.sh
#
# Convenience wrapper: bootstrap the project (idempotent), then
# deploy cache-service, then weather-api. Handy for first-time setup
# and for re-deploying both services from a clean checkout.
#
#   bash deploy/cloudrun/deploy-all.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

bash deploy/cloudrun/deploy-bootstrap.sh
bash deploy/cloudrun/deploy-cache-service.sh
bash deploy/cloudrun/deploy-weather-api.sh
