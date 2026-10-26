#!/usr/bin/env bash
#
# deploy.sh — bring the Huly stack up locally or on the server, with the checks
# that keep workspaces working (one shared token secret, single transactor URL,
# no huly.local on the server) run BEFORE anything is recreated, and a health
# check AFTER.
#
# Usage (from anywhere; paths are resolved from this script's location):
#   sudo bash scripts/deploy.sh                     # server/prod (default) from /etc/wedidwork/secrets.env
#   bash scripts/deploy.sh --local                  # local stack from dev/.env
#
# Options:
#   --local                deploy the local stack instead of the server (default: server/prod)
#   --server | --prod      explicit server/prod (same as the default)
#   --min                  use the minimal stack (adds docker-compose.min.yaml)
#   --pull                 git pull --ff-only first (as the repo owner, not root)
#   --rebuild-secrets      server: run build-secrets-env.sh before deploying
#   --fix-override         replace literal token secrets in docker-compose.override.yaml
#                          with ${HULY_SHARED_SECRET} (a backup is written first)
#   --rotate-secret        DELIBERATELY change HULY_SHARED_SECRET (logs everyone out,
#                          voids API tokens). Without it a changed secret aborts.
#   --check                only run the health check on the running stack
#   --dry-run              run the pre-checks and print the compose command; change nothing
#   --wait <seconds>       how long to watch containers after the recreate (default 45)
#   -h | --help            show this help
#
# What it never does: print a secret value, put a secret in a command line, or
# build images (build them first with `rush docker:build`).
#
# Server notes:
#   * Run it with sudo: /etc/wedidwork is root-only, and without the secrets the
#     recreate would start services with empty DB / storage / signing config.
#   * Layering is docker-compose.yaml + docker-compose.override.yaml (what the live
#     stack runs). --min adds docker-compose.min.yaml for a minimal stack.
#   * Email: a full recreate also wires account + workspace to the mail relay
#     (MAIL_URL is in the base compose), so signups require email confirmation.
#     It warns when PLUNK_SMTP_PASSWORD is empty.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV="$REPO/dev"
SERVER_SECRETS=/etc/wedidwork/secrets.env
LOCAL_ENV="$DEV/.env"

MODE=server
MIN=false
PULL=false
REBUILD_SECRETS=false
FIX_OVERRIDE=false
ROTATE=false
CHECK_ONLY=false
DRY_RUN=false
WAIT=45

SECRET_KEYS='SECRET|SERVER_SECRET|STREAM_SERVER_SECRET|HULY_TOKEN_SECRET'
# Integrations with no service in this stack are deliberately blank.
OPTIONAL_REFS=" GMAIL_PUBLIC_URL CALENDAR_PUBLIC_URL TELEGRAM_PUBLIC_URL GITHUB_PUBLIC_URL PAYMENT_PUBLIC_URL POSTHOG_API_KEY POSTHOG_HOST PLUNK_SMTP_PASSWORD "

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
fail() { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }
step() { echo; echo "==> $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE=local; shift ;;
    --server|--prod) MODE=server; shift ;;
    --min) MIN=true; shift ;;
    --pull) PULL=true; shift ;;
    --rebuild-secrets) REBUILD_SECRETS=true; shift ;;
    --fix-override) FIX_OVERRIDE=true; shift ;;
    --rotate-secret) ROTATE=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --wait) WAIT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ "$WAIT" =~ ^[0-9]+$ ]] || fail "--wait needs a number of seconds."
if [[ "$MODE" == local && "$REBUILD_SECRETS" == true ]]; then
  fail "--rebuild-secrets is server-only (it builds $SERVER_SECRETS)."
fi
command -v docker >/dev/null 2>&1 || fail "docker is required."
docker compose version >/dev/null 2>&1 || fail "docker compose v2 is required."

sha8() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-8; else shasum -a 256 | cut -c1-8; fi
}

# ── compose file set ────────────────────────────────────────────────────────
FILE_NAMES=(docker-compose.yaml)
[[ -f "$DEV/docker-compose.override.yaml" ]] && FILE_NAMES+=(docker-compose.override.yaml)
[[ "$MIN" == true ]] && FILE_NAMES+=(docker-compose.min.yaml)
COMPOSE_FILES=()
for f in "${FILE_NAMES[@]}"; do COMPOSE_FILES+=(-f "$f"); done
compose() { (cd "$DEV" && docker compose "${COMPOSE_FILES[@]}" "$@"); }

# ── load the environment (secrets stay in this process, never echoed) ───────
load_env() {
  local file="$1"
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

read_secret_from_file() {
  grep -E '^HULY_SHARED_SECRET=' "$1" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'" || true
}

running_account_secret() {
  local cid
  cid="$(compose ps -q account 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || return 0
  docker exec "$cid" printenv SERVER_SECRET 2>/dev/null || true
}

# ── health check (also used by --check) ─────────────────────────────────────
health_check() {
  local expected_fp="$1" ids problems=0
  ids="$(compose ps -q -a 2>/dev/null)"
  [[ -n "$ids" ]] || { warn "no containers found for this stack."; return 1; }

  step "Containers"
  local id name status restarts
  for id in $ids; do
    name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
    status="$(docker inspect -f '{{.State.Status}}' "$id")"
    restarts="$(docker inspect -f '{{.RestartCount}}' "$id")"
    printf '  %-30s %-10s restarts=%s\n' "$name" "$status" "$restarts"
    if [[ "$status" != running || "$restarts" != 0 ]]; then
      problems=$((problems + 1))
      echo "    last log lines:"
      docker logs --tail 8 "$id" 2>&1 | sed 's/^/      /'
    fi
  done

  step "Token secrets (fingerprint only)"
  local fps="" line key val fp
  for id in $ids; do
    name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
    while IFS= read -r line; do
      key="${line%%=*}"; val="${line#*=}"
      fp="$(printf '%s' "$val" | sha8)"
      printf '  %-30s %-22s %s\n' "$name" "$key" "$fp"
      fps="$fps $fp"
    done < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" | grep -E "^($SECRET_KEYS)=" || true)
  done
  local distinct
  distinct="$(printf '%s\n' $fps | sort -u | grep -c . || true)"
  if [[ "$distinct" -gt 1 ]]; then
    warn "containers use $distinct different token secrets -- workspaces will fail (500/401)."
    problems=$((problems + 1))
  elif [[ -n "$expected_fp" && -n "$fps" && "$(printf '%s\n' $fps | sort -u)" != "$expected_fp" ]]; then
    warn "containers share one secret, but it is not the one in the env file -- recreate the stack."
    problems=$((problems + 1))
  else
    echo "  OK: one shared secret"
  fi

  step "Transactor URLs"
  local bad=0 url
  for id in $ids; do
    url="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" | grep -E '^TRANSACTOR_URL=' | cut -d= -f2- || true)"
    [[ -n "$url" ]] || continue
    if [[ "$(printf '%s' "$url" | tr -cd ';' | wc -c | tr -d ' ')" != 1 ]]; then
      name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
      warn "$name TRANSACTOR_URL is not 'internal;public': $url"
      bad=1
    fi
  done
  if [[ "$bad" == 0 ]]; then echo "  OK: every TRANSACTOR_URL is internal;public"; else problems=$((problems + 1)); fi

  echo
  if [[ "$problems" -eq 0 ]]; then
    echo "Health check passed."
  else
    echo "Health check found $problems problem(s) -- see above."
    return 1
  fi
}

# ── pre-checks ──────────────────────────────────────────────────────────────
check_compose_secrets() {
  # Every token secret in the compose files must be ${HULY_SHARED_SECRET}.
  local f bad=""
  for f in docker-compose.yaml docker-compose.override.yaml; do
    [[ -f "$DEV/$f" ]] || continue
    while IFS= read -r line; do
      bad="$bad"$'\n'"  $f:${line%%:*}"
    done < <(grep -nE "^[[:space:]]*-?[[:space:]]*($SECRET_KEYS)[=:]" "$DEV/$f" \
               | grep -v '^[0-9]*:[[:space:]]*#' \
               | grep -vF '${HULY_SHARED_SECRET}' || true)
  done
  if [[ -n "$bad" ]]; then
    if [[ "$FIX_OVERRIDE" == true && "$DRY_RUN" == false ]]; then
      local ov="$DEV/docker-compose.override.yaml"
      cp -p "$ov" "$ov.pre-deploy.$(date +%Y%m%d%H%M%S)"
      sed -E -i.sedtmp \
        -e "s/^([[:space:]]*-[[:space:]]*($SECRET_KEYS))=.*/\1=\${HULY_SHARED_SECRET}/" \
        -e "s/^([[:space:]]*($SECRET_KEYS)):.*/\1: \${HULY_SHARED_SECRET}/" "$ov"
      rm -f "$ov.sedtmp"
      echo "  fixed literal token secrets in docker-compose.override.yaml (backup written next to it)"
      FIX_OVERRIDE=false
      check_compose_secrets
      return
    fi
    fail "token secrets that are not \${HULY_SHARED_SECRET} (line numbers only):$bad
       Every service must use the one shared secret. Re-run with --fix-override, or fix them by hand."
  fi
  echo "  OK: every token secret in the compose files is \${HULY_SHARED_SECRET}"
}

check_server_values() {
  # Every ${REF} used by the active compose lines must be set, single-URL, and
  # never a local-dev host.
  local refs r val unset_refs="" multi="" localdev=""
  refs="$(cd "$DEV" && grep -hv '^[[:space:]]*#' "${FILE_NAMES[@]}" \
            | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\${//' | sort -u)"
  for r in $refs; do
    val="${!r:-}"
    if [[ -z "$val" ]]; then
      case "$OPTIONAL_REFS" in *" $r "*) ;; *) unset_refs="$unset_refs $r" ;; esac
      continue
    fi
    [[ "$r" == *_URL && "$val" == *";"* ]] && multi="$multi $r"
    [[ "$val" == *huly.local* ]] && localdev="$localdev $r"
  done
  [[ -z "$unset_refs" ]] || fail "not set in $SERVER_SECRETS:$unset_refs (try --rebuild-secrets)."
  [[ -z "$multi" ]] || fail "these must hold ONE url, not a ';' list:$multi (the compose joins them itself)."
  [[ -z "$localdev" ]] || fail "these point at huly.local, which only exists locally:$localdev
       Use your domain for *_PUBLIC_URL and service names for internal ones (e.g. http://account:3000)."
  echo "  OK: all compose values set, single-URL, no huly.local"

  if [[ -z "${PLUNK_SMTP_PASSWORD:-}" ]]; then
    warn "PLUNK_SMTP_PASSWORD is empty: mail is wired in, so new signups need email confirmation but no mail will be sent."
  fi
}

check_nginx() {
  command -v nginx >/dev/null 2>&1 || { warn "nginx not found -- skipping proxy route check."; return 0; }
  local conf key path missing=""
  conf="$(nginx -T 2>/dev/null || true)"
  [[ -n "$conf" ]] || { warn "could not read the nginx config -- skipping proxy route check."; return 0; }
  for key in TRANSACTOR_PUBLIC_URL ACCOUNT_PUBLIC_URL COLLABORATOR_PUBLIC_URL DATALAKE_PUBLIC_URL; do
    [[ -n "${!key:-}" ]] || continue
    path="$(printf '%s' "${!key}" | sed -E 's#^[a-z]+://[^/]+##; s#/+$##')"
    [[ -n "$path" ]] || continue
    printf '%s' "$conf" | grep -qE "location[[:space:]]+(=[[:space:]]*)?${path}([/[:space:]{]|$)" \
      || missing="$missing $path($key)"
  done
  if [[ -n "$missing" ]]; then
    warn "nginx has no location for:$missing -- the browser cannot reach these, so workspaces may not load."
  else
    echo "  OK: nginx routes exist for the browser-facing paths"
  fi
}

check_rotation() {
  # The env secret must equal what account runs now, unless --rotate-secret.
  local env_secret="$1" live
  [[ "$env_secret" =~ ^[0-9a-f]{64}$ ]] || fail "HULY_SHARED_SECRET is missing or not 64 hex characters."
  live="$(running_account_secret)"
  if [[ -z "$live" ]]; then
    echo "  account is not running -- no rotation check needed"
  elif [[ "$live" == "$env_secret" ]]; then
    echo "  OK: HULY_SHARED_SECRET matches the running account"
  elif [[ "$ROTATE" == true ]]; then
    warn "HULY_SHARED_SECRET differs from the running account -- rotating as requested (everyone must log in again)."
  else
    fail "HULY_SHARED_SECRET differs from the running account. Deploying would log everyone out and void API tokens.
       Restore the old value, or re-run with --rotate-secret if this is deliberate."
  fi
  unset live
}

rotate_server_secret() {
  [[ "$DRY_RUN" == true ]] && { echo "  (dry run) would write a new HULY_SHARED_SECRET to $SERVER_SECRETS"; return; }
  command -v openssl >/dev/null 2>&1 || fail "openssl is required to generate a secret."
  cp -p "$SERVER_SECRETS" "$SERVER_SECRETS.bak.$(date +%Y%m%d%H%M%S)"
  local tmp
  tmp="$(mktemp "$SERVER_SECRETS.XXXXXX")"
  chmod 600 "$tmp"
  NEW_SECRET="$(openssl rand -hex 32)" awk '
    BEGIN { done = 0 }
    /^HULY_SHARED_SECRET=/ { print "HULY_SHARED_SECRET=\047" ENVIRON["NEW_SECRET"] "\047"; done = 1; next }
    { print }
    END { if (!done) print "HULY_SHARED_SECRET=\047" ENVIRON["NEW_SECRET"] "\047" }
  ' "$SERVER_SECRETS" > "$tmp"
  mv "$tmp" "$SERVER_SECRETS"
  echo "  wrote a new HULY_SHARED_SECRET (previous file backed up next to it)"
}

# ── 0. pull ─────────────────────────────────────────────────────────────────
if [[ "$PULL" == true && "$CHECK_ONLY" == false ]]; then
  step "Pulling the latest code"
  owner="${SUDO_USER:-$(id -un)}"
  if [[ "$(id -u)" == 0 && "$owner" != root ]]; then
    sudo -u "$owner" git -C "$REPO" pull --ff-only
  else
    git -C "$REPO" pull --ff-only
  fi
fi

# ── 1. environment ──────────────────────────────────────────────────────────
step "Environment: $MODE"
if [[ "$MODE" == server ]]; then
  [[ "$(id -u)" == 0 ]] || fail "run with sudo: $SERVER_SECRETS is readable by root only."
  if [[ "$REBUILD_SECRETS" == true && "$CHECK_ONLY" == false ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      echo "  (dry run) would run scripts/build-secrets-env.sh"
    else
      bash "$REPO/scripts/build-secrets-env.sh"
    fi
  fi
  [[ -f "$SERVER_SECRETS" ]] || fail "$SERVER_SECRETS not found (try --rebuild-secrets)."
  if [[ "$ROTATE" == true && "$CHECK_ONLY" == false ]]; then
    rotate_server_secret
  fi
  load_env "$SERVER_SECRETS"
else
  if [[ ! -f "$LOCAL_ENV" || "$ROTATE" == true ]] && [[ "$CHECK_ONLY" == false ]]; then
    if [[ ! -f "$LOCAL_ENV" && -f "$LOCAL_ENV.bak" && "$ROTATE" == false ]] \
       && [[ "$(read_secret_from_file "$LOCAL_ENV.bak")" =~ ^[0-9a-f]{64}$ ]]; then
      echo "  dev/.env is missing; restoring dev/.env.bak so the local secret is kept"
      [[ "$DRY_RUN" == true ]] || cp -p "$LOCAL_ENV.bak" "$LOCAL_ENV"
    fi
    GEN_ARGS=(--local)
    [[ "$ROTATE" == true ]] && GEN_ARGS+=(--rotate-secret)
    if [[ "$DRY_RUN" == true ]]; then
      echo "  (dry run) would run: scripts/generate-prod-config.sh ${GEN_ARGS[*]}"
    else
      bash "$REPO/scripts/generate-prod-config.sh" "${GEN_ARGS[@]}" </dev/null
    fi
  fi
  ENV_SRC="$LOCAL_ENV"
  # A dry run or --check restores nothing, so read the file it would restore from.
  if [[ ! -f "$ENV_SRC" && -f "$LOCAL_ENV.bak" ]] && [[ "$DRY_RUN" == true || "$CHECK_ONLY" == true ]]; then
    ENV_SRC="$LOCAL_ENV.bak"
  fi
  [[ -f "$ENV_SRC" ]] || fail "dev/.env not found."
  load_env "$ENV_SRC"
fi
EXPECTED_FP=""
[[ -n "${HULY_SHARED_SECRET:-}" ]] && EXPECTED_FP="$(printf '%s' "$HULY_SHARED_SECRET" | sha8)"

if [[ "$CHECK_ONLY" == true ]]; then
  health_check "$EXPECTED_FP"
  exit $?
fi

# ── 2. pre-checks (nothing has been recreated yet) ──────────────────────────
step "Pre-checks"
check_compose_secrets
if [[ "$MODE" == server ]]; then
  check_server_values
  check_nginx
fi
check_rotation "${HULY_SHARED_SECRET:-}"

# ── 3. recreate ─────────────────────────────────────────────────────────────
step "Recreating the stack"
echo "  cd dev && docker compose ${COMPOSE_FILES[*]} up -d --force-recreate"
if [[ "$DRY_RUN" == true ]]; then
  echo
  echo "Dry run: pre-checks passed, nothing was changed."
  exit 0
fi
compose up -d --force-recreate

# ── 4. watch, then health check ─────────────────────────────────────────────
if [[ "$WAIT" -gt 0 ]]; then
  step "Waiting ${WAIT}s for services to settle"
  sleep "$WAIT"
fi
health_check "$EXPECTED_FP"
