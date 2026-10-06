#!/usr/bin/env bash
#
# generate-prod-config.sh — create a filled dev/docker-compose.override.yaml
# from the committed template, for a public-domain deployment.
#
# Usage (from the repo root):
#   bash scripts/generate-prod-config.sh
#   bash scripts/generate-prod-config.sh --domain wedid.work
#   bash scripts/generate-prod-config.sh --dry-run        # list placeholders only
#
# What it does:
#   * copies dev/docker-compose.prod-template.yaml -> dev/docker-compose.override.yaml
#   * substitutes REPLACE_ME_DOMAIN with your domain
#   * generates ONE shared SERVER_SECRET (used on all 7 token-verifying
#     services) and unique random values for each service-local secret
#   * refuses to finish if any REPLACE_ME_* placeholder is left
#   * keeps the output file out of git (adds it to .git/info/exclude)
#
# Notes:
#   * MinIO (AWS_*) credentials are NOT part of the template: they must match
#     the MinIO container's own credentials. Omitted => inherited as-is.
#   * Changing SERVER_SECRET invalidates existing sessions and API tokens.
#     Users re-login once; recreate API tokens (Settings -> API Tokens).

set -euo pipefail

TEMPLATE="dev/docker-compose.prod-template.yaml"
OUTPUT="dev/docker-compose.override.yaml"
DOMAIN=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Locate repo root (script lives in scripts/).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: template not found at $TEMPLATE (run from the repo root)." >&2
  exit 1
fi

# Cross-platform in-place sed (GNU sed on Linux, BSD sed on macOS).
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"          # GNU
  else
    sed -i '' "$@"       # BSD/macOS
  fi
}

if [[ "$DRY_RUN" == true ]]; then
  echo "Placeholders in $TEMPLATE:"
  grep -oE 'REPLACE_ME_[A-Z_]+' "$TEMPLATE" | sort | uniq -c
  exit 0
fi

if [[ -z "$DOMAIN" ]]; then
  read -r -p "Enter your public domain (e.g. wedid.work): " DOMAIN
fi
if [[ -z "$DOMAIN" ]]; then
  echo "Error: a domain is required." >&2
  exit 1
fi

echo "Generating $OUTPUT from $TEMPLATE ..."
cp "$TEMPLATE" "$OUTPUT"

# One shared token-signing secret across all 7 token-verifying services.
SHARED_SECRET="$(openssl rand -hex 32)"
sed_inplace "s|REPLACE_ME_DOMAIN|${DOMAIN}|g" "$OUTPUT"
sed_inplace "s|REPLACE_ME_SERVER_SECRET|${SHARED_SECRET}|g" "$OUTPUT"

# Unique per-service secrets.
for key in COLLABORATOR STREAM_SERVER MEDIA ANALYTICS EXPORT DATALAKE HULY_TOKEN EVENTS_PROCESSOR; do
  value="$(openssl rand -hex 32)"
  sed_inplace "s|REPLACE_ME_${key}_SECRET|${value}|g" "$OUTPUT"
done

# Fail if anything was missed (template drift / typo).
LEFTOVER="$(grep -oE 'REPLACE_ME_[A-Z_]+' "$OUTPUT" | sort -u || true)"
if [[ -n "$LEFTOVER" ]]; then
  echo "Error: unfilled placeholders remain in $OUTPUT:" >&2
  echo "$LEFTOVER" >&2
  exit 1
fi

# Keep real secrets out of git.
EXCLUDE_FILE=".git/info/exclude"
if [[ -d .git ]] && ! grep -qxF "$OUTPUT" "$EXCLUDE_FILE" 2>/dev/null; then
  echo "$OUTPUT" >> "$EXCLUDE_FILE"
fi

echo "Done: $OUTPUT written (untracked)."
echo
echo "Next steps:"
echo "  1. Review $OUTPUT."
echo "  2. Pre-flight merge check:"
echo "       docker compose -f docker-compose.yaml -f docker-compose.min.yaml config \\"
echo "         | grep -E 'ACCOUNTS_URL|BRANDING_URL|STORAGE_CONFIG'"
echo "  3. Deploy:"
echo "       docker compose -f docker-compose.yaml -f docker-compose.min.yaml up -d --force-recreate"
echo "  4. Verify:"
echo "       curl -s https://${DOMAIN}/config.json | grep -c huly.local   # -> 0"
echo
echo "NOTE: changing SERVER_SECRET invalidates existing sessions and API tokens."
echo "      Users re-login once; recreate API tokens afterwards."