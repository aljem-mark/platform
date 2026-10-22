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
# the live override supplies -- recreating `account` under min would break token
# verification for every session.
#
# ROLLBACK: the stack-level rollback documented in scripts/apply-mail.sh
# (pre-build baseline + `git checkout "$ANCHOR" -- dev/docker-compose.yaml` +
# recreate under the live layering). Nothing new to invent here.
# ---------------------------------------------------------------------------
set -euo pipefail

SECRETS=/etc/wedidwork/secrets.env
DEV=/home/rhinax/projects/we-did-work/dev

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

# --- 3. merged-config pre-checks on the service about to be recreated. Compose
#        merges `environment` key-by-key even in list form, so the base MAIL_URL
#        survives the override's `- SERVER_SECRET`; a FUTURE override edit adding
#        a conflicting MAIL_URL would silently undo that, so assert the merge.
MERGED="$(docker compose -f docker-compose.yaml -f docker-compose.override.yaml config)" \
  || fail "'docker compose config' failed -- cannot verify the merged account environment."

account_key() {
  printf '%s\n' "$MERGED" | awk -v key="$1" '
    /^services:[[:space:]]*$/ { in_svc = 1; next }
    in_svc && /^[^[:space:]]/ { in_svc = 0 }
    in_svc && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { cur = substr($1, 1, length($1) - 1) }
    in_svc && cur == "account" && index($0, " " key ":") {
      v = $0
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "", v)
      gsub(/"/, "", v)
      print v
      exit
    }'
}

MAIL_URL="$(account_key MAIL_URL || true)"
if [ -z "$MAIL_URL" ]; then
  fail "merged config has an EMPTY account MAIL_URL -- email would stay off. Check docker-compose.yaml (base) and dev/docker-compose.override.yaml for a conflicting MAIL_URL= entry."
fi

# --- 4. ...and the live signing secret must survive the merge, or the recreate
#        breaks token verification for every service.
SHARED="$(account_key SERVER_SECRET || true)"
if [ -z "$SHARED" ]; then
  fail "merged config has an EMPTY account SERVER_SECRET -- recreating account now would break token verification for every session."
fi
unset SHARED

echo "Pre-checks OK: mail running with a credential; merged account MAIL_URL=$MAIL_URL; SERVER_SECRET present."
echo "Enabling transactional email -- recreating account + workspace_cockroach (signups will now require email confirmation)."

docker compose -f docker-compose.yaml -f docker-compose.override.yaml \
  up -d --no-deps --force-recreate account workspace_cockroach

docker compose -f docker-compose.yaml -f docker-compose.override.yaml ps account workspace_cockroach
