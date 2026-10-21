#!/bin/bash
# apply-mail.sh -- recreate ONLY the mail relay container, with its credential
# injected from the root-only server secrets file.
#
# WHY a wrapper: /etc/wedidwork is 750 root:root, so `rhinax` cannot read the
# secrets file -- a plain `set -a; . /etc/wedidwork/secrets.env` silently no-ops
# and mail would come up with an empty SMTP password. This script therefore runs
# under sudo, and fails loudly rather than applying a half-configured container.
#
# DEPLOYED FORM (root-owned copy -- the repo working tree is rhinax-writable and
# must NEVER be a sudoers target):
#   sudo install -o root -g root -m 755 scripts/apply-mail.sh /usr/local/sbin/wedidwork-apply-mail
#   printf '%s\n' 'rhinax ALL=(root) NOPASSWD: /usr/local/sbin/wedidwork-apply-mail' \
#     | sudo tee /etc/sudoers.d/wedidwork-apply-mail >/dev/null
#   sudo chmod 440 /etc/sudoers.d/wedidwork-apply-mail
#   sudo visudo -cf /etc/sudoers.d/wedidwork-apply-mail
# Re-run the `install` line after any `git pull` that changes this file.
#
# COMPOSE LAYERING: pin to what the live prod stack actually runs
# (docker-compose.yaml + docker-compose.override.yaml). Do NOT switch this to
# docker-compose.min.yaml: mail itself is defined in the base file only, but a
# later stack-wide `up` under a different file set would drop the override's
# hardcoded SERVER_SECRET / *_URL values for the other services.
#
# `--no-deps` plus naming the service means no neighbour container is created,
# started or recreated, so the override's secrets are never re-applied.
set -euo pipefail

SECRETS=/etc/wedidwork/secrets.env
DEV=/home/rhinax/projects/we-did-work/dev

if [ ! -r "$SECRETS" ]; then
  echo "FATAL: $SECRETS is not readable -- refusing to apply (mail would come up with an empty SMTP password)." >&2
  exit 1
fi

cd "$DEV" 2>/dev/null || { echo "FATAL: $DEV not found." >&2; exit 1; }
for f in docker-compose.yaml docker-compose.override.yaml; do
  if [ ! -f "$DEV/$f" ]; then
    echo "FATAL: $DEV/$f is missing -- refusing to apply." >&2
    exit 1
  fi
done

set -a
# shellcheck disable=SC1090
. "$SECRETS"
set +a

if [ -z "${PLUNK_SMTP_PASSWORD:-}" ]; then
  echo "FATAL: PLUNK_SMTP_PASSWORD is not set in $SECRETS." >&2
  exit 1
fi

exec docker compose \
  -f docker-compose.yaml \
  -f docker-compose.override.yaml \
  up -d --no-deps --force-recreate mail
