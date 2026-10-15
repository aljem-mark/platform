#!/usr/bin/env bash
#
# generate-prod-config.sh — create a filled dev/.env for this deployment,
# from the committed template dev/.env.example.
#
# Usage (from the repo root):
#   bash scripts/generate-prod-config.sh
#   bash scripts/generate-prod-config.sh --domain wedid.work
#   bash scripts/generate-prod-config.sh --rotate-secret   # new HULY_SHARED_SECRET
#   bash scripts/generate-prod-config.sh --dry-run         # list placeholders only
#
# What it does:
#   * copies dev/.env.example -> dev/.env (gitignored; an existing file is backed
#     up to dev/.env.bak first)
#   * substitutes REPLACE_ME_DOMAIN with your domain
#   * sets HULY_SHARED_SECRET (openssl rand -hex 32) — it REUSES the value already
#     present in dev/.env unless --rotate-secret is passed, so a redeploy does not
#     log every user out and does not invalidate existing API tokens
#   * prompts (hidden input) for PLUNK_SMTP_PASSWORD — the ONE value it must NEVER
#     generate: only the mail provider's own secret key works
#   * refuses to finish if any REPLACE_ME_* placeholder is left
#
# Notes:
#   * Every input is collected and validated BEFORE anything is written, and the
#     new file is moved into place atomically — a failed run never leaves a
#     half-written dev/.env behind.
#   * Compose loads dev/.env automatically when it runs from dev/ — that is what
#     `rush docker:up:min` does. NEVER commit dev/.env: it holds real secrets.
#   * This is the single deployment mechanism. The per-service
#     dev/docker-compose.prod-template.yaml + docker-compose.override.yaml flow is
#     retired (kept for reference only, not used by this script).
#   * The DB / MinIO / storage values in the template are LOCAL defaults. Replace
#     them with your real credentials before a production deploy (warned below).
#   * Deliverability prerequisite: the sending domain must be verified with the
#     mail provider AND carry SPF + DKIM (ideally DMARC) DNS records.
#   * Changing HULY_SHARED_SECRET invalidates existing sessions and API tokens.
#     Users re-login once; recreate API tokens afterwards.

set -euo pipefail

TEMPLATE="dev/.env.example"
OUTPUT="dev/.env"
TMP="${OUTPUT}.tmp"
DOMAIN=""
DRY_RUN=false
ROTATE_SECRET=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --rotate-secret) ROTATE_SECRET=true; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
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
  echo
  echo "Note: REPLACE_ME_PLUNK_SMTP_PASSWORD is prompted for (never generated) — it"
  echo "      must be the mail provider's own secret. REPLACE_ME_HULY_SHARED_SECRET is"
  echo "      generated once and afterwards preserved (see --rotate-secret); the"
  echo "      REPLACE_ME_DOMAIN occurrences take the --domain value."
  exit 0
fi

# ── collect and validate every input BEFORE writing anything ────────────────

if [[ -z "$DOMAIN" ]]; then
  read -r -p "Enter your public domain (e.g. wedid.work): " DOMAIN
fi
if [[ -z "$DOMAIN" ]]; then
  echo "Error: a domain is required." >&2
  exit 1
fi

# Shared secret: reuse the one already deployed so redeploys stay stable.
EXISTING_SECRET=""
if [[ -f "$OUTPUT" ]]; then
  EXISTING_SECRET="$(grep -E '^HULY_SHARED_SECRET=' "$OUTPUT" | head -1 | cut -d= -f2- || true)"
fi
if [[ "$ROTATE_SECRET" == true || -z "$EXISTING_SECRET" || "$EXISTING_SECRET" == REPLACE_ME_* ]]; then
  SHARED_SECRET="$(openssl rand -hex 32)"
  SHARED_SECRET_NOTE="newly generated"
else
  SHARED_SECRET="$EXISTING_SECRET"
  SHARED_SECRET_NOTE="reusing the existing value (--rotate-secret to change it)"
fi

# The mail (pod-mail) SMTP password: user-supplied, NEVER generated. Only the
# value issued by the mail provider works (Plunk secret key, `sk_…`). Prompt
# hidden; PLUNK_SMTP_PASSWORD allows a non-interactive run.
SMTP_PASSWORD_VALUE="${PLUNK_SMTP_PASSWORD:-}"
if [[ -z "$SMTP_PASSWORD_VALUE" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "Enter the SMTP password (mail provider secret, Plunk 'sk_…'): " SMTP_PASSWORD_VALUE || true
    echo
  else
    echo "Error: no interactive terminal for the SMTP password prompt." >&2
    echo "       Re-run from a terminal, or set PLUNK_SMTP_PASSWORD in the environment." >&2
    exit 1
  fi
fi
if [[ -z "$SMTP_PASSWORD_VALUE" ]]; then
  echo "Error: the SMTP password is required (mail provider secret, Plunk 'sk_…')." >&2
  echo "       It cannot be generated — copy it from the provider dashboard." >&2
  exit 1
fi
if ! grep -q 'REPLACE_ME_PLUNK_SMTP_PASSWORD' "$TEMPLATE"; then
  echo "Error: REPLACE_ME_PLUNK_SMTP_PASSWORD is missing from the template (drift)." >&2
  exit 1
fi

# ── write atomically: build the file next to the target, then move it in ────

if [[ -f "$OUTPUT" ]]; then
  cp "$OUTPUT" "${OUTPUT}.bak"
  echo "Existing $OUTPUT backed up to ${OUTPUT}.bak"
fi

echo "Generating $OUTPUT from $TEMPLATE ..."
rm -f "$TMP"
cp "$TEMPLATE" "$TMP"
sed_inplace "s|REPLACE_ME_DOMAIN|${DOMAIN}|g" "$TMP"
sed_inplace "s|REPLACE_ME_HULY_SHARED_SECRET|${SHARED_SECRET}|g" "$TMP"
echo "  HULY_SHARED_SECRET: ${SHARED_SECRET_NOTE}"
# Escape sed replacement metacharacters so a secret containing & | \ survives intact.
ESCAPED_SMTP_PASSWORD="$(printf '%s' "$SMTP_PASSWORD_VALUE" | sed -e 's/[\\&|]/\\&/g')"
sed_inplace "s|REPLACE_ME_PLUNK_SMTP_PASSWORD|${ESCAPED_SMTP_PASSWORD}|g" "$TMP"
unset SHARED_SECRET EXISTING_SECRET SMTP_PASSWORD_VALUE ESCAPED_SMTP_PASSWORD

# Fail if anything was missed (template drift / typo) — the previous dev/.env,
# if any, is left untouched.
LEFTOVER="$(grep -oE 'REPLACE_ME_[A-Z_]+' "$TMP" | sort -u || true)"
if [[ -n "$LEFTOVER" ]]; then
  rm -f "$TMP"
  echo "Error: unfilled placeholders remain (template drift):" >&2
  echo "$LEFTOVER" >&2
  exit 1
fi

chmod 600 "$TMP" 2>/dev/null || true
mv -f "$TMP" "$OUTPUT"

# It holds real secrets: make sure git really ignores it.
if git rev-parse --git-dir >/dev/null 2>&1 && ! git check-ignore -q "$OUTPUT"; then
  echo "WARNING: $OUTPUT is NOT gitignored — do not commit it." >&2
fi

echo "Done: $OUTPUT written (gitignored)."
echo
echo "Next steps:"
echo "  1. Review $OUTPUT. The DB / MinIO / storage values are LOCAL defaults — for a"
echo "     production deploy set your real DB_CR_URL / DB_URL_PG / MONGO_URL /"
echo "     STORAGE_CONFIG / BACKUP_STORAGE_CONFIG / PLATFORM_ADMIN_EMAILS."
echo "  2. Build the images. 'rush docker:min' does NOT build pod-mail and the compose"
echo "     has no 'build:' key, so build the mail image explicitly too:"
echo "       rush docker:build --to @hcengineering/pod-mail     # -> hardcoreeng/mail:<git-rev>"
echo "  3. Start the stack (compose loads dev/.env automatically when run from dev/):"
echo "       rush docker:up:min"
echo "     ...or directly:"
echo "       cd dev && docker compose -f docker-compose.yaml -f docker-compose.min.yaml up -d --force-recreate"
echo "  4. Verify:"
echo "       curl -s https://${DOMAIN}/config.json | tr ',' '\\n' | grep huly.local   # -> empty on a server"
echo "       docker compose -f docker-compose.yaml -f docker-compose.min.yaml logs mail   # real send must not 401/535"
echo
echo "NOTE: the sending domain must be verified with the mail provider and carry"
echo "      SPF + DKIM (ideally DMARC), or mail is rejected/spammed."
echo "NOTE: changing HULY_SHARED_SECRET invalidates existing sessions and API tokens."
echo "      Users re-login once; recreate API tokens afterwards."
