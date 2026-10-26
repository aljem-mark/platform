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
# COMPLETENESS IS ENUMERATED, NOT INFERRED FROM WARNINGS: every ${REF} in either
# compose file is required -- including `${VAR:-default}` refs, which Compose never
# warns about and which would otherwise silently render `http://huly.local:<port>`
# in production. A ref that cannot be sourced, or whose value is still a local-dev
# host, aborts the run and names itself.
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


REF_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-[^}]*)?\}")


def template_regex(template):
    """Turn a compose value template into a regex with one group per ${REF}.

    A container only holds the RENDERED value, e.g. `TRANSACTOR_URL=${A};${B}` ends
    up as `ws://internal;wss://public`. Copying that whole string into A is what
    produced the doubled TRANSACTOR_URL. Each ref therefore matches only its own
    segment (no `;`, the list separator), and the whole value must match the
    template exactly, so a value that is already doubled is rejected, not copied.
    """
    parts, pos, seen = ["^"], 0, set()
    for m in REF_RE.finditer(template):
        parts.append(re.escape(template[pos:m.start()]))
        ref = m.group(1)
        if ref in seen:
            parts.append("(?P=%s)" % ref)
        else:
            parts.append("(?P<%s>[^;]*?)" % ref)
            seen.add(ref)
        pos = m.end()
    parts.append(re.escape(template[pos:]) + "$")
    return re.compile("".join(parts))


def refs_and_mapping():
    """Union of ${REF} names from both compose files, each with candidate (service, var, template)."""
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
            if line.lstrip().startswith("#"):
                continue
            kv = re.match(r"^\s*-?\s*([A-Za-z_][A-Za-z0-9_]*)=(.*?)\s*(?:\s#.*)?$", line)
            var, template = (kv.group(1), kv.group(2).strip("\"'")) if kv else (None, None)
            for ref in REF_RE.findall(line):
                refs.add(ref)
                cand = (service, var, template)
                buckets = mapping.setdefault(ref, [])
                if cand not in buckets:
                    buckets.append(cand)
    return refs, mapping


def extract_ref(ref, live_value, template):
    """The part of a rendered container value that belongs to `ref`, or None."""
    if live_value is None or template is None:
        return None
    m = template_regex(template).match(live_value)
    if not m:
        return None
    got = m.group(ref)
    return got or None


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


def sourced_env(path):
    r = sh(["bash", "-c", 'set -a; . "$1" >/dev/null 2>&1; set +a; env', "_", path])
    pairs = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            pairs[k] = v
    return pairs, bool(r.stderr.strip())


def source_problems(values, path):
    """(mismatched keys, had shell errors) when the file is sourced the way every
    wrapper sources it. An unquoted `|` or `?` silently loses the assignment and
    executes fragments, so this is checked, not assumed."""
    got, erred = sourced_env(path)
    return [k for k in sorted(values) if got.get(k) != values[k]], erred


def unset_refs(values):
    """Render the merged config with `values` in the environment; return refs that warn as unset."""
    env = dict(os.environ)
    env.update(values)
    r = sh(COMPOSE + ["config", "--format", "json"], cwd=dev, env=env)
    if r.returncode != 0:
        print("docker compose config failed:", (r.stderr or "").strip()[:400], file=sys.stderr)
        sys.exit(3)
    names = set(re.findall(r'The "([A-Za-z_][A-Za-z0-9_]*)" variable is not set', r.stderr))
    return {n for n in names if n not in OPTIONAL_REFS}, r.stdout


refs, mapping = refs_and_mapping()
if not refs:
    print("no interpolation references found in the compose files -- refusing to guess.", file=sys.stderr)
    sys.exit(4)

def live_account_secret():
    for service, var, template in mapping.get("HULY_SHARED_SECRET", []):
        if service == "account":
            return extract_ref("HULY_SHARED_SECRET", read_var(service, var), template)
    return None


# Refs whose canonical value in this stack is deliberately BLANK: integrations
# with no service deployed (the prod generator empties exactly these) and the
# analytics keys. They must not be required, or a correct stack aborts.
OPTIONAL_REFS = {
    "GMAIL_PUBLIC_URL",
    "CALENDAR_PUBLIC_URL",
    "TELEGRAM_PUBLIC_URL",
    "GITHUB_PUBLIC_URL",
    "PAYMENT_PUBLIC_URL",
    "POSTHOG_API_KEY",
    "POSTHOG_HOST",
}


def tainted(values):
    """Refs whose resolved value still carries the compose local-dev default host.

    Compose never warns for `${VAR:-default}` refs, so 'no warnings' is NOT a
    completeness proof: those refs silently render `http://huly.local:<port>`,
    which is a browser-breaking value in production. They are treated as REQUIRED
    and their rendered value must not be a local-dev host.
    """
    # Only BROWSER-FACING values must never be a local-dev host. The internal hops
    # (ACCOUNT_INTERNAL_URL, STREAM_DATALAKE_URL) legitimately use huly.local on this
    # box: the compose pins `extra_hosts: huly.local:host-gateway` for them, and the
    # live stack runs that way today.
    return [
        r
        for r in sorted(refs)
        if r.endswith("_PUBLIC_URL") and values.get(r) and "huly.local" in values[r]
    ]


def unresolved(values):
    return [r for r in sorted(refs) if r not in OPTIONAL_REFS and not values.get(r)]


def malformed(values):
    """URL refs that hold more than one URL.

    Each *_URL ref is ONE address; the compose joins them with `;` itself
    (TRANSACTOR_URL=${TRANSACTOR_INTERNAL_URL};${TRANSACTOR_PUBLIC_URL}). A `;` inside
    the ref doubles the list, and the account service then reads the third segment
    as the transactor REGION, finds no transactor, and fails workspace selection
    with a 500.
    """
    return [k for k in sorted(values) if k.endswith("_URL") and ";" in (values.get(k) or "")]


current = existing_values()
if current:
    warned, merged = unset_refs(current)
    bad, erred = source_problems(current, secrets_path)
    if (
        not warned
        and merged.strip()
        and not unresolved(current)
        and not tainted(current)
        and not malformed(current)
        and not bad
        and not erred
    ):
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

dropped = malformed(current)
if dropped:
    print(
        "existing secrets.env holds a multi-URL value for: " + ", ".join(dropped)
        + " -- re-deriving it from the live containers.",
        file=sys.stderr,
    )
values = {k: v for k, v in current.items() if v and k not in dropped}
missing = []
for ref in sorted(refs):
    if values.get(ref):
        continue
    got = None
    for service, var, template in mapping.get(ref, []):
        # The signing secret comes from account ONLY: other containers may still
        # run with a divergent value, and copying one of those would rotate it.
        if ref == "HULY_SHARED_SECRET" and service != "account":
            continue
        got = extract_ref(ref, read_var(service, var), template)
        if got and not malformed({ref: got}):
            break
        got = None
    if got:
        values[ref] = got
    elif ref not in OPTIONAL_REFS:
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

local_dev = tainted(values)
if missing or local_dev:
    if missing:
        print("could not source values for: " + ", ".join(missing), file=sys.stderr)
    if local_dev:
        print(
            "these refs would render the compose local-dev default (huly.local) instead of a real value: "
            + ", ".join(local_dev),
            file=sys.stderr,
        )
        print(
            "set them from your public domain (see the PUBLIC_URLS table in scripts/generate-prod-config.sh) "
            "and re-run; nothing has been written.",
            file=sys.stderr,
        )
    print("no file written; nothing was changed.", file=sys.stderr)
    sys.exit(6)

def shell_quote(value):
    """Single-quote so the file stays shell-sourceable: these values legitimately
    carry `|`, `?`, `&`, `=` and spaces (STORAGE_CONFIG/QUEUE_CONFIG/URLs), which
    an unquoted assignment would make the shell try to execute."""
    return "'" + str(value).replace("'", "'\\''") + "'"


with open(candidate, "w", encoding="utf-8") as fh:
    for k in sorted(values):
        fh.write("%s=%s\n" % (k, shell_quote(values[k])))
os.chmod(candidate, 0o600)

bad, erred = source_problems(values, candidate)
if bad or erred:
    if bad:
        print("these keys do not survive shell sourcing of the written file: " + ", ".join(bad), file=sys.stderr)
    if erred:
        print("the written file produced shell errors when sourced -- values are not safely quoted", file=sys.stderr)
    print("no file written; nothing was changed.", file=sys.stderr)
    sys.exit(9)

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
