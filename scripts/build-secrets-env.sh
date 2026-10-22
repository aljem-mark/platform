#!/bin/bash
# build-secrets-env.sh -- build the COMPLETE /etc/wedidwork/secrets.env from the
# values the live containers are actually running with.
#
# WHY: the live stack was brought up with root's shell environment; no file on the
# box holds those values in reproducible form. `enable-mail.sh` recreates
# `account`/`workspace_cockroach` under the live layering, and Compose interpolates
# their config from the environment -- so an incomplete secrets file recreates them
# with empty DB/storage/queue config and an empty signing secret. This builds that
# file from the source of truth: the running containers themselves.
#
# KEY NAMES ARE THE INTERPOLATION NAMES, NOT THE CONTAINER ENV NAMES:
# `docker-compose.yaml` has `- DB_URL=${DB_CR_URL}`, so the file must define
# DB_CR_URL even though the container ends up holding DB_URL.
#
# NEVER ROTATES THE SIGNING SECRET: HULY_SHARED_SECRET is copied verbatim from
# dev-account-1's SERVER_SECRET (the 64-char value -- NOT rating_cockroach's
# divergent short one, which needs its own reconcile). If the existing file holds a
# different value the run aborts rather than rotating it.
#
# SAFETY: values already present in the existing file win (nothing is clobbered);
# the candidate is validated by rendering the merged config and refusing to proceed
# while ANY interpolation still warns as unset; the existing file is backed up
# before it is replaced, and an already-complete file is left untouched.
# No value is ever printed, logged, placed in argv or passed through sudo args.
#
# DEPLOYED FORM (root-owned copy -- the repo working tree is rhinax-writable and
# must NEVER be a sudoers target):
#   sudo install -o root -g root -m 755 scripts/build-secrets-env.sh /usr/local/sbin/wedidwork-build-secrets
#   printf '%s\n' 'rhinax ALL=(root) NOPASSWD: /usr/local/sbin/wedidwork-build-secrets' \
#     | sudo tee /etc/sudoers.d/wedidwork-build-secrets >/dev/null
#   sudo chmod 440 /etc/sudoers.d/wedidwork-build-secrets
#   sudo visudo -cf /etc/sudoers.d/wedidwork-build-secrets
# Re-run the `install` line after any `git pull` that changes this file.
#
# ORDER: run this BEFORE enable-mail.sh, and never between an `up` and its verify.
set -euo pipefail

SECRETS=/etc/wedidwork/secrets.env
DEV=/home/rhinax/projects/we-did-work/dev

fail() { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || fail "must run as root -- install as /usr/local/sbin/wedidwork-build-secrets and run that."
[ -d /etc/wedidwork ] || fail "/etc/wedidwork does not exist -- create it root-owned, mode 750, first."
cd "$DEV" 2>/dev/null || fail "$DEV not found."
for f in docker-compose.yaml docker-compose.override.yaml; do
  [ -f "$DEV/$f" ] || fail "$DEV/$f is missing."
done
command -v python3 >/dev/null 2>&1 || fail "python3 is required."
command -v docker >/dev/null 2>&1 || fail "docker is required."

TMP="$(mktemp /etc/wedidwork/.secrets.candidate.XXXXXX)" || fail "cannot create a candidate file in /etc/wedidwork."
chmod 600 "$TMP"
trap 'rm -f "$TMP"' EXIT

set +e
python3 - "$TMP" "$DEV" "$SECRETS" <<'PY'
import json, os, re, subprocess, sys

candidate, dev, secrets_path = sys.argv[1], sys.argv[2], sys.argv[3]
COMPOSE = ["docker", "compose", "-f", "docker-compose.yaml", "-f", "docker-compose.override.yaml"]


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def refs_and_mapping():
    """Union of ${REF} names from both compose files, each with candidate (service, var)."""
    refs, mapping = set(), {}
    for name in ("docker-compose.yaml", "docker-compose.override.yaml"):
        path = os.path.join(dev, name)
        if not os.path.exists(path):
            continue
        service = None
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
            if m:
                service = m.group(1)
                continue
            for ref in re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", line):
                refs.add(ref)
                var = re.search(
                    r"(?:-\s*)?([A-Za-z_][A-Za-z0-9_]*)=(?:\"|')?[^\"']*?\$\{" + re.escape(ref), line
                )
                cand = (service, var.group(1) if var else None)
                buckets = mapping.setdefault(ref, [])
                if cand not in buckets:
                    buckets.append(cand)
    return refs, mapping


def container_id(service):
    if not service:
        return None
    r = sh(["docker", "ps", "-q", "--filter", "label=com.docker.compose.service=" + service])
    ids = [x for x in r.stdout.split() if x]
    return ids[0] if ids else None


def read_var(service, var):
    cid = container_id(service)
    if not cid or not var:
        return None
    r = sh(["docker", "exec", cid, "printenv", var])
    if r.returncode != 0:
        return None
    value = r.stdout.rstrip("\n")
    return value or None


def existing_values():
    out = {}
    if not os.path.exists(secrets_path):
        return out
    with open(secrets_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def unset_refs(values):
    """Render the merged config with `values` in the environment; return refs that warn as unset."""
    env = dict(os.environ)
    env.update(values)
    r = sh(COMPOSE + ["config", "--format", "json"], cwd=dev, env=env)
    if r.returncode != 0:
        print("docker compose config failed:", (r.stderr or "").strip()[:400], file=sys.stderr)
        sys.exit(3)
    names = set(re.findall(r'The "([A-Za-z_][A-Za-z0-9_]*)" variable is not set', r.stderr))
    return names, r.stdout


refs, mapping = refs_and_mapping()
if not refs:
    print("no interpolation references found in the compose files -- refusing to guess.", file=sys.stderr)
    sys.exit(4)

def live_account_secret():
    for service, var in mapping.get("HULY_SHARED_SECRET", []):
        if service == "account":
            return read_var(service, var)
    return None


current = existing_values()
if current:
    warned, merged = unset_refs(current)
    if not warned and merged.strip():
        held = current.get("HULY_SHARED_SECRET")
        live_now = live_account_secret()
        if live_now and held and held != live_now:
            print(
                "secrets.env resolves everything but its HULY_SHARED_SECRET differs from the live account value "
                "-- refusing to touch it (never rotate). Reconcile deliberately before recreating anything.",
                file=sys.stderr,
            )
            sys.exit(5)
        print("secrets.env already resolves every interpolation (%d refs) -- no change made." % len(refs))
        sys.exit(10)

values = {k: v for k, v in current.items() if v}
missing = []
for ref in sorted(refs):
    if values.get(ref):
        continue
    got = None
    for service, var in mapping.get(ref, []):
        got = read_var(service, var)
        if got:
            break
    if got:
        values[ref] = got
    else:
        missing.append(ref)

live = live_account_secret()
if live:
    held = values.get("HULY_SHARED_SECRET")
    if held and held != live:
        print(
            "HULY_SHARED_SECRET in secrets.env differs from the live account value -- refusing (never rotate).",
            file=sys.stderr,
        )
        sys.exit(5)
    values["HULY_SHARED_SECRET"] = live

if missing:
    print("could not source values for: " + ", ".join(missing), file=sys.stderr)
    print("no file written; nothing was changed.", file=sys.stderr)
    sys.exit(6)

with open(candidate, "w", encoding="utf-8") as fh:
    for k in sorted(values):
        fh.write("%s=%s\n" % (k, values[k]))
os.chmod(candidate, 0o600)

warned, merged = unset_refs(values)
if warned:
    print("still unresolved after derivation: " + ", ".join(sorted(warned)), file=sys.stderr)
    print("no file written; nothing was changed.", file=sys.stderr)
    sys.exit(7)
if not merged.strip():
    print("merged config rendered empty -- refusing.", file=sys.stderr)
    sys.exit(8)

print("candidate resolves all %d interpolation refs from the live containers." % len(refs))
PY
rc=$?
set -e

case "$rc" in
  0)  : ;;
  10) echo "No change made."; exit 0 ;;
  *)  fail "derivation or validation failed (exit $rc) -- $SECRETS left untouched." ;;
esac

if [ -f "$SECRETS" ]; then
  BACKUP="$SECRETS.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$SECRETS" "$BACKUP"
  chmod 600 "$BACKUP"
  echo "backed up the previous file to $(basename "$BACKUP")"
fi

install -o root -g root -m 600 "$TMP" "$SECRETS"
echo "wrote $SECRETS (root:root, mode 600)."
echo "next: install and run the apply/enable wrappers; do not run an 'up' between this and enable-mail.sh."
