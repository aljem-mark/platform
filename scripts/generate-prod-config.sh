#!/usr/bin/env bash
#
# generate-prod-config.sh — create a filled dev/.env for this deployment,
# from the committed template dev/.env.example.
#
# Usage (from the repo root):
#   bash scripts/generate-prod-config.sh                     # public deployment (prompts for domain)
#   bash scripts/generate-prod-config.sh --domain wedid.work
#   bash scripts/generate-prod-config.sh --local             # local stack: huly.local, public URLs left empty
#   bash scripts/generate-prod-config.sh --rotate-secret     # new HULY_SHARED_SECRET
#   bash scripts/generate-prod-config.sh --dry-run           # list placeholders only
#
# What it does:
#   * copies dev/.env.example -> dev/.env (gitignored; an existing file is backed
#     up to dev/.env.bak first)
#   * substitutes REPLACE_ME_DOMAIN with your domain and fills the browser-facing
#     *_PUBLIC_URL keys from it; with --local it writes the huly.local values instead
#     and leaves those keys EMPTY (the compose then falls back to its own
#     http://huly.local:<port> defaults)
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
#   * SERVER: the secrets belong in a root-only file OUTSIDE the repo, e.g.
#     /etc/wedidwork/secrets.env (chmod 600), injected with systemd
#     EnvironmentFile= or `set -a; . /etc/wedidwork/secrets.env; set +a` before
#     `up` — the shell environment wins over dev/.env (keys documented in
#     dev/secrets.env.example). Generate dev/.env for LOCAL use, or for the
#     server's non-secret values only.
#   * HULY_SHARED_SECRET must stay STABLE across redeploys (it signs tokens for
#     seven services); this script reuses an existing value unless --rotate-secret.
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
LOCAL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --local) LOCAL=true; shift ;;
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
  echo "      must be the mail provider's own secret, and may be left EMPTY when you"
  echo "      do not need outbound mail. REPLACE_ME_HULY_SHARED_SECRET is generated"
  echo "      once and afterwards preserved (see --rotate-secret); the"
  echo "      REPLACE_ME_DOMAIN occurrences take the --domain value."
  exit 0
fi

# ── collect and validate every input BEFORE writing anything ────────────────

if [[ "$LOCAL" == true ]]; then
  DOMAIN="huly.local"            # not a public deployment: only used for the summary below
elif [[ -z "$DOMAIN" ]]; then
  read -r -p "Enter your public domain (e.g. wedid.work): " DOMAIN
fi
if [[ -z "$DOMAIN" ]]; then
  echo "Error: a domain is required (or pass --local for a local stack)." >&2
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

# The mail (pod-mail) SMTP password: user-supplied and NEVER generated. Only the
# value issued by the mail provider works (Plunk secret key, `sk_…`). It is needed
# only when you actually want outbound mail, so it may be left empty; the prompt is
# skipped entirely for a non-interactive run.
SMTP_PASSWORD_VALUE="${PLUNK_SMTP_PASSWORD:-}"
if [[ -z "$SMTP_PASSWORD_VALUE" && -t 0 ]]; then
  read -r -s -p "SMTP password for the mail relay (Plunk 'sk_…', Enter to skip): " SMTP_PASSWORD_VALUE || true
  echo
fi
if [[ -z "$SMTP_PASSWORD_VALUE" ]]; then
  echo "  PLUNK_SMTP_PASSWORD: not set — outbound mail stays disabled until you set it"
  echo "  (server: /etc/wedidwork/secrets.env; locally: PLUNK_SMTP_PASSWORD=… )."
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
if [[ "$LOCAL" == true ]]; then
  # Local stack: the *_PUBLIC_URL keys stay EMPTY so the compose's
  # http://huly.local:<port> defaults apply (see the front service).
  sed_inplace "s|^HULY_DOMAIN=.*|HULY_DOMAIN=huly.local|" "$TMP"
  sed_inplace "s|^HULY_PUBLIC_URL=.*|HULY_PUBLIC_URL=http://huly.local:8087|" "$TMP"
  sed_inplace "s|^TRANSACTOR_PUBLIC_URL=.*|TRANSACTOR_PUBLIC_URL=ws://huly.local:3332|" "$TMP"
  # Keep the disabled-integration keys on their local endpoints so local features work.
  for kv in GMAIL_PUBLIC_URL=http://huly.local:8093 CALENDAR_PUBLIC_URL=http://huly.local:8095 \
            TELEGRAM_PUBLIC_URL=http://huly.local:8086 GITHUB_PUBLIC_URL=http://huly.local:3500 \
            PAYMENT_PUBLIC_URL=http://huly.local:3040; do
    sed_inplace "s|^${kv%%=*}=.*|${kv}|" "$TMP"
  done
  echo "  public URLs: LOCAL (empty *_PUBLIC_URL -> compose falls back to huly.local)"
else
  # Deployment: fill every browser-facing URL from the domain. These are exactly the
  # values the front service publishes in /config.json. An empty scheme means "blank it"
  # (the integration is disabled client-side) — that only works because the compose uses
  # the `${VAR-default}` form for those keys.
  while IFS='|' read -r key scheme path; do
    [[ -z "$key" ]] && continue
    if [[ -z "$scheme" ]]; then
      sed_inplace "s|^${key}=.*|${key}=|" "$TMP"
    else
      sed_inplace "s|^${key}=.*|${key}=${scheme}://${DOMAIN}${path}|" "$TMP"
    fi
  done <<'PUBLIC_URLS'
ACCOUNT_PUBLIC_URL|https|/_accounts
COLLABORATOR_PUBLIC_URL|wss|/collaborator
FILES_PUBLIC_URL|https|/files/:workspace/:blobId/:filename
DATALAKE_PUBLIC_URL|https|/datalake
HULYLAKE_PUBLIC_URL|https|/hulylake
PULSE_PUBLIC_URL|wss|/pulse/ws
STATS_PUBLIC_URL|https|/stats
REKONI_PUBLIC_URL|https|/rekoni
PREVIEW_PUBLIC_URL|https|/preview
LINK_PREVIEW_PUBLIC_URL|https|/link-preview
PRINT_PUBLIC_URL|https|/print
SIGN_PUBLIC_URL|https|/sign
BACKUP_PUBLIC_URL|https|/backup/api/backup
EXPORT_PUBLIC_URL|https|/export
BRANDING_PUBLIC_URL|https|/branding.json
STREAM_PUBLIC_URL|https|/stream/recording
GMAIL_PUBLIC_URL||
CALENDAR_PUBLIC_URL||
TELEGRAM_PUBLIC_URL||
GITHUB_PUBLIC_URL||
PAYMENT_PUBLIC_URL||
PUBLIC_URLS
  echo "  public URLs: https://${DOMAIN}/… (browser-facing, from *_PUBLIC_URL)"
  # Blanking the calendar/telegram URLs also disables those client features.
  sed_inplace "s|^FRONT_DISABLED_FEATURES=.*|FRONT_DISABLED_FEATURES=auto-translate,mailboxes,calendar,telegram|" "$TMP"
fi
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
echo "     ON A SERVER, do not keep secrets in this file: put HULY_SHARED_SECRET,"
echo "     PLUNK_SMTP_PASSWORD and the DB credentials in a root-only file OUTSIDE the"
echo "     repo (keys: dev/secrets.env.example) and inject it before 'up':"
echo "       set -a; . /etc/wedidwork/secrets.env; set +a"
echo "     (the shell environment wins over dev/.env, so nothing sensitive needs to"
echo "      exist repo-side)."
echo "  2. Build the images. 'rush docker:min' does NOT build pod-mail and the compose"
echo "     has no 'build:' key, so build the mail image explicitly too:"
echo "       rush docker:build --to @hcengineering/pod-mail     # -> hardcoreeng/mail:<git-rev>"
echo "  3. Start the stack (compose loads dev/.env automatically when run from dev/):"
echo "       rush docker:up:min"
echo "     ...or directly:"
echo "       cd dev && docker compose -f docker-compose.yaml -f docker-compose.min.yaml up -d --force-recreate"
echo "  4. Verify:"
if [[ "$LOCAL" == true ]]; then
  echo "       open http://huly.local:8087 — the app must load with no ERR_NAME_NOT_RESOLVED"
else
  echo "       curl -s https://${DOMAIN}/config.json | tr ',' '\\n' | grep huly.local   # -> empty"
fi
echo "       docker compose -f docker-compose.yaml -f docker-compose.min.yaml logs mail   # real send must not 401/535"
echo
echo "NOTE: the sending domain must be verified with the mail provider and carry"
echo "      SPF + DKIM (ideally DMARC), or mail is rejected/spammed."
echo "NOTE: changing HULY_SHARED_SECRET invalidates existing sessions and API tokens."
echo "      Users re-login once; recreate API tokens afterwards."
