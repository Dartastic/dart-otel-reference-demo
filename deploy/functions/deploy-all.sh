#!/usr/bin/env bash
#
# deploy/functions/deploy-all.sh
#
# Bootstrap, then deploy cache-service and weather-api as Cloud
# Functions Gen 2. Order matters — weather-api needs cache-service's
# URL.
#
#   bash deploy/functions/deploy-all.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

bash deploy/functions/deploy-bootstrap.sh
bash deploy/functions/deploy-cache-service.sh
bash deploy/functions/deploy-weather-api.sh
