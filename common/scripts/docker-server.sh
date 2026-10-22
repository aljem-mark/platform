# Dispatched through the repo's own Rush bootstrap (same reason as docker.sh):
# a bare `rush` is rejected on hosts where PATH resolves it to GNU rush (Ubuntu's
# "Restricted User Shell", apt package `rush`). $0 is used rather than
# BASH_SOURCE because this file has no shebang and may be executed by sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)" || exit 1
RUSH_BOOTSTRAP="$REPO_ROOT/common/scripts/install-run-rush.js"
if [ ! -f "$RUSH_BOOTSTRAP" ]; then
  echo "FATAL: $RUSH_BOOTSTRAP not found." >&2
  exit 1
fi
cd "$REPO_ROOT" || exit 1

node "$RUSH_BOOTSTRAP" docker:build -p 20 \
--to @hcengineering/pod-server \
--to @hcengineering/tool || true
