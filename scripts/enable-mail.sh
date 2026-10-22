#!/bin/bash
# enable-mail.sh -- turn transactional email ON by recreating exactly
# `account` + `workspace_cockroach` so they pick up MAIL_URL=http://mail:8097
# from the base compose, under the same layering the live stack already runs.
#
# WHAT IT CHANGES IN PROD: `forceConfirmation` flips ON -- signups move from
# auto-confirm to email-confirmation. That is a PRODUCT decision, not a build
# step. Run it only after the mail image is built and the relay is up with a
# credential (scripts/apply-mail.sh).
#
# WHY a wrapper: /etc/wedidwork is 750 root:root, so `rhinax` cannot read the
# secrets file -- a plain `set -a; . /etc/wedidwork/secrets.env` silently no-ops
# and the recreate would leave DB_CR_URL / QUEUE_CONFIG / STORAGE_CONFIG /
# HULY_SHARED_SECRET unset. This runs under sudo and fails loudly rather than
# applying a half-configured stack.
#
# PRE-CHECKS ARE FAIL-CLOSED: the merged environment for EVERY service being
# recreated is parsed from `docker compose config --format json` with a real JSON
# parser. A missing python3, or a Compose too old for --format json, aborts the
# run -- it can never degrade into "guard passes because parsing failed".
#
# DEPLOYED FORM (root-owned copy -- the repo working tree is rhinax-writable and
# must NEVER be a sudoers target):
#   sudo install -o root -g root -m 755 scripts/enable-mail.sh /usr/local/sbin/wedidwork-enable-mail
#   printf '%s\n' 'rhinax ALL=(root) NOPASSWD: /usr/local/sbin/wedidwork-enable-mail' \
#     | sudo tee /etc/sudoers.d/wedidwork-enable-mail >/dev/null
#   sudo chmod 440 /etc/sudoers.d/wedidwork-enable-mail
#   sudo visudo -cf /etc/sudoers.d/wedidwork-enable-mail
# Re-run the `install` line after any `git pull` that changes this file.
#
# COMPOSE LAYERING: pinned to what the live stack actually runs
# (docker-compose.yaml + docker-compose.override.yaml). Do NOT switch this to
# docker-compose.min.yaml: that drops the override, and with it the SERVER_SECRET
# the live override supplies -- recreating these services under min would break
# token verification for every session.
#
# ROLLBACK: the stack-level rollback documented in scripts/apply-mail.sh
# (pre-build baseline + `git checkout "$ANCHOR" -- dev/docker-compose.yaml` +
# recreate under the live layering). Nothing new to invent here.
# ---------------------------------------------------------------------------
set -euo pipefail

SECRETS=/etc/wedidwork/secrets.env
DEV=/home/rhinax/projects/we-did-work/dev

# The full recreate set -- both are token-verifying services wired to MAIL_URL in
# the base compose, so both are guarded below. Single source of truth: the loop
# and the `up` line cannot drift apart. Word splitting here is intentional.
RECREATE="account workspace_cockroach"

fail() { echo "FATAL: $*" >&2; exit 1; }

if [ ! -r "$SECRETS" ]; then
  fail "$SECRETS is not readable -- refusing to enable mail (the secrets would silently no-op and leave the recreated services unconfigured)."
fi

cd "$DEV" 2>/dev/null || fail "$DEV not found."
for f in docker-compose.yaml docker-compose.override.yaml; do
  if [ ! -f "$DEV/$f" ]; then
    fail "$DEV/$f is missing -- refusing to enable mail."
  fi
done

set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a

# --- 1. the relay must be UP: never flip signups to email-confirmation with no relay
RUNNING="$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml ps --status running --services)" \
  || fail "could not query the running services."
printf '%s\n' "$RUNNING" | grep -qx 'mail' \
  || fail "the 'mail' container is not running -- build and start it first (scripts/apply-mail.sh)."

# --- 2. ...and it must actually hold a credential: a running relay with an empty
#        SMTP password fails every send silently.
docker compose -f docker-compose.yaml -f docker-compose.override.yaml exec -T mail sh -c 'test -n "$SMTP_PASSWORD"' \
  || fail "the 'mail' container has an empty SMTP_PASSWORD -- apply the credential first (scripts/apply-mail.sh)."

# --- 3. merged-config pre-checks, parsed as JSON, for EVERY service about to be
#        recreated. Compose merges `environment` key-by-key (list form included),
#        so the base MAIL_URL survives the override's `- SERVER_SECRET`; a FUTURE
#        override edit -- the override is rhinax-writable -- adding a conflicting
#        MAIL_URL would silently undo that, so assert the merge per service.
#        An empty SERVER_SECRET slipping through would recreate a token-verifying
#        service with no signing secret and kill every session, so this guard must
#        never false-negative: hence a structured parse, not YAML pattern matching.
#        The non-empty value is then compared with what the RUNNING container
#        actually holds: SERVER_SECRET interpolates ${HULY_SHARED_SECRET} from
#        /etc/wedidwork/secrets.env, so an edit or a
#        `generate-prod-config.sh --rotate-secret` would otherwise be applied to
#        these two services while the other token services keep the old value.
#        A rotation aborts the run -- "never rotate it" is an enforced invariant,
#        not a note. Neither value is ever echoed.
command -v python3 >/dev/null 2>&1 \
  || fail "python3 is required for the merged-config guard -- refusing to run without it."

MERGED_JSON="$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml config --format json)" \
  || fail "'docker compose config --format json' failed -- cannot verify the merged environment (Compose v2.20+ required)."

svc_env() {
  printf '%s' "$MERGED_JSON" | python3 -c '
import json, sys
svc, key = sys.argv[1], sys.argv[2]
doc = json.load(sys.stdin)
svc_def = (doc.get("services") or {}).get(svc) or {}
env = svc_def.get("environment") or {}
if isinstance(env, list):                      # list form: "KEY=value" entries
    env = dict(item.split("=", 1) for item in env if "=" in item)
val = env.get(key, "")
sys.stdout.write("" if val is None else str(val))
' "$1" "$2"
}

SUMMARY=""
for svc in $RECREATE; do
  # the service must be live: the rotation guard below needs a value to compare against
  printf '%s\n' "$RUNNING" | grep -qx "$svc" \
    || fail "$svc is not running -- refusing to recreate it (there would be no live signing secret to compare against)."

  url="$(svc_env "$svc" MAIL_URL)"
  if [ -z "$url" ]; then
    fail "merged config has an EMPTY $svc MAIL_URL -- email would stay off. Check docker-compose.yaml (base) and dev/docker-compose.override.yaml for a conflicting MAIL_URL= entry."
  fi

  new_secret="$(svc_env "$svc" SERVER_SECRET)"
  if [ -z "$new_secret" ]; then
    fail "merged config has an EMPTY $svc SERVER_SECRET -- recreating $svc now would break token verification for every session."
  fi

  # NEVER ROTATE the signing secret: compare the value the recreate WOULD apply
  # against the one the running container actually holds. Both stay in shell
  # variables and are never echoed.
  live_secret="$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml exec -T "$svc" printenv SERVER_SECRET)" \
    || fail "could not read the running $svc SERVER_SECRET -- refusing to recreate without the rotation check."
  if [ "$new_secret" != "$live_secret" ]; then
    fail "$svc: the merged SERVER_SECRET differs from the running one -- recreating now would rotate the signing secret and log every user out. Fix the value in /etc/wedidwork/secrets.env first (never rotate it)."
  fi
  unset new_secret live_secret

  SUMMARY="$SUMMARY $svc(MAIL_URL=$url, SERVER_SECRET: unchanged)"
done

# --- 4. WHOLE-UNION completeness. The per-service guards above cover only the two
#        keys that decide token validity and mail wiring; an incomplete secrets file
#        would still recreate these services with empty DB / storage / queue config.
#        Every ${...} interpolation in the live layering must resolve -- and Compose
#        warns on stderr for each unset one, so "no warnings" against the MERGED
#        render is the proof, not a hand-maintained key list.
set +e
WARN_OUT="$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml config --format json 2>&1 >/dev/null)"
CFG_RC=$?
set -e
if [ "$CFG_RC" != "0" ]; then
  fail "'docker compose config' failed -- cannot verify that every interpolation resolves."
fi
UNRESOLVED="$(printf '%s\n' "$WARN_OUT" \
  | grep -oE 'The "[A-Za-z_][A-Za-z0-9_]*" variable is not set' \
  | sed -e 's/^The "//' -e 's/" variable is not set$//' | sort -u || true)"
if [ -n "$UNRESOLVED" ]; then
  fail "secrets file is incomplete -- the live layering still has unset interpolations: $(printf '%s' "$UNRESOLVED" | tr '\n' ' '). Recreating $RECREATE now would leave empty DB/storage/queue config. Run scripts/build-secrets-env.sh as root first."
fi

echo "Pre-checks OK: mail running with a credential;$SUMMARY"
echo "Enabling transactional email -- recreating $RECREATE (signups will now require email confirmation)."

docker compose -f docker-compose.yaml -f docker-compose.override.yaml \
  up -d --no-deps --force-recreate $RECREATE

docker compose -f docker-compose.yaml -f docker-compose.override.yaml ps $RECREATE
