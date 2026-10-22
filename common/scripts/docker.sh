#!/bin/bash
# Supports minified mode for resource-constrained dev machines:
#   rush docker --minified   or   rush docker:min
#
# The build is dispatched through the repo's own Rush bootstrap
# (common/scripts/install-run-rush.js), which installs and runs the exact
# @microsoft/rush version pinned in rush.json. Never call a bare `rush` from
# this script: on hosts where PATH resolves `rush` to GNU rush (Ubuntu's
# "Restricted User Shell", apt package `rush`), the bare call is rejected with
# "You are not permitted to execute this command" -- or silently runs the
# wrong tool. The bootstrap needs no global install and no PATH ordering.
set -e

# Resolve the repo root from this script's location so the bootstrap is found
# regardless of the current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUSH_BOOTSTRAP="$REPO_ROOT/common/scripts/install-run-rush.js"

MINIFIED=false
for arg in "$@"; do
  if [ "$arg" = "--minified" ]; then
    MINIFIED=true
    break
  fi
done

cd "$REPO_ROOT"

if [ "$MINIFIED" = true ]; then
  echo "Building minified docker images (excluding optional services)..."
  node "$RUSH_BOOTSTRAP" docker:build -p 20 \
    --to @hcengineering/pod-server \
    --to @hcengineering/pod-front \
    --to @hcengineering/prod \
    --to @hcengineering/pod-account \
    --to @hcengineering/pod-workspace \
    --to @hcengineering/pod-collaborator \
    --to @hcengineering/tool \
    --to @hcengineering/pod-analytics-collector \
    --to @hcengineering/rekoni-service \
    --to @hcengineering/pod-datalake \
    --to @hcengineering/pod-export \
    --to @hcengineering/pod-media \
    --to @hcengineering/pod-external
else
  node "$RUSH_BOOTSTRAP" docker:build -p 20 \
    --to @hcengineering/pod-server \
    --to @hcengineering/pod-front \
    --to @hcengineering/prod \
    --to @hcengineering/pod-account \
    --to @hcengineering/pod-workspace \
    --to @hcengineering/pod-collaborator \
    --to @hcengineering/tool \
    --to @hcengineering/pod-print \
    --to @hcengineering/pod-sign \
    --to @hcengineering/pod-analytics-collector \
    --to @hcengineering/rekoni-service \
    --to @hcengineering/pod-ai-bot \
    --to @hcengineering/import-tool \
    --to @hcengineering/pod-stats \
    --to @hcengineering/pod-fulltext \
    --to @hcengineering/pod-love \
    --to @hcengineering/pod-mail \
    --to @hcengineering/pod-datalake \
    --to @hcengineering/pod-mail-worker \
    --to @hcengineering/pod-export \
    --to @hcengineering/pod-media \
    --to @hcengineering/pod-preview \
    --to @hcengineering/pod-link-preview \
    --to @hcengineering/pod-external \
    --to @hcengineering/pod-backup \
    --to @hcengineering/backup-api-pod \
    --to @hcengineering/pod-billing \
    --to @hcengineering/pod-process \
    --to @hcengineering/pod-rating \
    --to @hcengineering/pod-payment \
    --to @hcengineering/pod-worker \
    --to @hcengineering/pod-events-processor
fi
