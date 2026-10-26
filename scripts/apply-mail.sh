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
# *_URL values for the other services. (Token secrets are no longer in the
# override: every service reads ${HULY_SHARED_SECRET} from the base compose.)
#
# `--no-deps` plus naming the service means no neighbour container is created,
# started or recreated. A full-stack `up --force-recreate` under this layering
# also (re)creates mail with PLUNK_SMTP_PASSWORD, so this script is only needed
# to apply a new mail credential without touching the rest of the stack.
#
# PRE-BUILD BASELINE and ROLLBACK ANCHOR -- capture this BEFORE building
# anything; it is the state the stack-level rollback below restores. Run as
# `rhinax` from the repo; it writes only to /tmp.
#
#   cd ~/projects/we-did-work
#   if [ -s /tmp/wedidwork.rollback-anchor ]; then          # reuse the plan's anchor
#     ANCHOR=$(cat /tmp/wedidwork.rollback-anchor)
#   else                                                    # else pin the current revision
#     ANCHOR=$(git rev-parse HEAD)
#     printf '%s\n' "$ANCHOR" > /tmp/wedidwork.rollback-anchor
#   fi
#   echo "anchor=$ANCHOR $(git log --oneline -1 "$ANCHOR")"
#   git rev-parse HEAD                    # revision currently deployed
#   sha256sum dev/docker-compose.yaml > /tmp/wedidwork.compose.sha256
#   docker compose -f docker-compose.yaml -f docker-compose.override.yaml ps > /tmp/wedidwork.pre-build.ps
#   docker ps -a --format '{{.Names}} {{.CreatedAt}} {{.Image}}' > /tmp/wedidwork.pre-build.containers
#   docker images --digests | grep -E 'hardcoreeng/(mail|account|workspace)' > /tmp/wedidwork.pre-build.images
#
# ANCHOR SEMANTICS: the saved anchor (9e84ae3f7, "Merge PR #12", 2026-10-15
# 12:42) is the revision immediately BEFORE bc5c78e5a (2026-10-15 13:23) added
# the `mail:` service and MAIL_URL -- reverting dev/docker-compose.yaml to it
# means "email off, signups auto-confirm". The anchor is a REPO revision and the
# live stack can be older still (dev-account-1 was created 2026-10-06 with
# MAIL_URL empty), which is why the runtime snapshots above are captured too.
# /tmp is volatile: if the anchor file is gone after a reboot the fallback pins
# the current HEAD, and the snapshots should be retaken before any change.
# ---------------------------------------------------------------------------
# STACK-LEVEL ROLLBACK -- pairs with the baseline above. This is the
# compose/stack rollback; the mail-image rollback is the separate block below.
#
#   WARNING: the anchor predates the shared-secret fix (8c16e287a). Its
#   dev/docker-compose.yaml still has `SECRET=secret` on datalake, collaborator,
#   media, export, etc., which splits token verification from account and brings
#   back the workspace 500. After reverting, set every SECRET= /
#   STREAM_SERVER_SECRET= line back to ${HULY_SHARED_SECRET} before any recreate
#   of those services -- or revert only the mail/MAIL_URL lines instead.
#
#   a) compose-only revert, as rhinax:
#        cd ~/projects/we-did-work
#        git checkout "$ANCHOR" -- dev/docker-compose.yaml
#        git diff --stat "$ANCHOR" -- dev/docker-compose.yaml
#      (full tree revert is `git checkout "$ANCHOR"`. The untracked
#       dev/docker-compose.override.yaml is NOT covered by git -- never
#       regenerate, move or delete it as part of a rollback.)
#   b) recreate ONLY the affected services, as ROOT, under the LIVE layering:
#        sudo -s
#        cd /home/rhinax/projects/we-did-work/dev
#        set -a; . /etc/wedidwork/secrets.env; set +a
#        docker compose -f docker-compose.yaml -f docker-compose.override.yaml up -d --no-deps --force-recreate account workspace_cockroach
#        docker compose -f docker-compose.yaml -f docker-compose.override.yaml ps
#        exit
#   c) verify, and know how to get back:
#        cd ~/projects/we-did-work
#        git diff --quiet "$ANCHOR" -- dev/docker-compose.yaml && echo "compose == anchor"
#        git checkout HEAD -- dev/docker-compose.yaml      # undo the revert
#        sha256sum -c /tmp/wedidwork.compose.sha256        # passes only while the
#                                    # compose still equals the captured baseline
#
# TWO HAZARDS FIXED HERE -- do not "simplify" these back:
#   1. LAYERING. The recreate uses `-f docker-compose.yaml -f
#      docker-compose.override.yaml`, matching what is actually live. The
#      pre-Plunk plan recreated these services under
#      `-f docker-compose.min.yaml`, which drops the override and every value it
#      supplies. (The override used to hold per-service SERVER_SECRET values; those
#      are gone -- the base compose gives every service ${HULY_SHARED_SECRET} -- but
#      a mixed layering still recreates services with config their neighbours do
#      not share.) The min layering is only correct for a stack started on min.
#   2. SECRET SOURCING. The same plan ran `set -a; . /etc/wedidwork/secrets.env`
#      as `rhinax`, where /etc/wedidwork is 750 root:root: the source silently
#      no-ops, leaving DB_CR_URL / QUEUE_CONFIG / STORAGE_CONFIG /
#      HULY_SHARED_SECRET unset and the recreated services broken. Source it as
#      root (as above) or through the root-owned wrapper -- never as rhinax.
#
# Keep the live SERVER_SECRET value unchanged through any rollback: it is the
# signing secret, and rotating it logs every user out (see the secret notes in
# scripts/generate-prod-config.sh).
# ---------------------------------------------------------------------------
# Rollback — this deploy is ADDITIVE, not a replace: `mail` never had an image
# or a container on this box, so nothing is overwritten.
#   * Before the first run of this script (runbook step 7): nothing to undo.
#     Everything up to here builds one image and appends one secret line; no
#     running container is touched until this script executes.
#   * After a run:      docker rm -f dev-mail-1
#     returns prod to its pre-change state ("no mail service"). This script uses
#     --no-deps and recreates ONLY mail, so the running min stack is untouched.
#   * Secret:           remove the single appended line from
#     /etc/wedidwork/secrets.env (grep -v '^PLUNK_SMTP_PASSWORD=' ... > tmp &&
#     mv), as root. It is additive — nothing else in that file was modified.
#   * Repo side:        git checkout 7a205607c      # previous prod revision
#   * Pre-flight:       the `docker compose ... config | grep ...` merge check in
#     docs/api/README.md section 6 step 2 belongs to FULL-STACK deploys only.
#     The mail-only path sources the existing override untouched; it is not needed.
#   * Known gap:        dev/docker-compose.yaml declares `image: hardcoreeng/mail`
#     with no tag, so compose resolves :latest and the NEXT recreate has no pinned
#     image to fall back to. Tracked as (B) ledger item #4 — not this incident.
# ---------------------------------------------------------------------------


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
