#!/usr/bin/env python3
"""smtp-auth-check.py — verify a mail relay credential AND endpoint directly.

WHY: the pod-mail service returns HTTP 200 even when the SMTP send fails
(`handleSendMail` catches the error, logs it, then `res.send()`), so a `/send` probe's
status code proves nothing. This script speaks to the relay itself and reports the SMTP
verdict: 235 = accepted, 535 = rejected. Use it as the deploy pre-flight so a wrong
endpoint or key is caught before the stack is brought up.

The relay endpoint (host/port/TLS) must come from the PROVIDER DASHBOARD, not from docs:
for Plunk that is `next-smtp.useplunk.com`, 2465 (implicit TLS) or 2587 (STARTTLS). The
legacy `smtp.useplunk.com:465` still answers the greeting and AUTH LOGIN but returns 535
for current project keys.

Usage:
    scripts/smtp-auth-check.py                        # key + host/port from the mail container
    scripts/smtp-auth-check.py --prompt               # type/paste a candidate key (hidden, no shell history)
    pbpaste | scripts/smtp-auth-check.py --stdin      # candidate key from the clipboard
    SMTP_KEY=sk_... scripts/smtp-auth-check.py        # candidate from the environment (visible in ps/history)

Endpoint / key overrides:
    scripts/smtp-auth-check.py --host next-smtp.useplunk.com --port 2465 --prompt
    scripts/smtp-auth-check.py --port 2587 --tls starttls
    scripts/smtp-auth-check.py --container my-mail-container
    (env equivalents: SMTP_HOST, SMTP_PORT, SMTP_TLS, SMTP_USER, SMTP_KEY, MAIL_CONTAINER)

--tls: implicit | starttls | none. Default: implicit for 465/2465, starttls for 587/2587,
none otherwise.

Exit code: 0 = AUTH OK, 1 = AUTH REJECTED, 2 = could not run the check.
The key is only ever sent to the relay — it is never printed.
"""
import argparse
import base64
import getpass
import os
import re
import socket
import ssl
import subprocess
import sys

DEFAULT_HOST = 'next-smtp.useplunk.com'
DEFAULT_PORT = 2465
DEFAULT_USER = 'plunk'
DEFAULT_CONTAINER = 'dev-mail-1'


def container_env(container: str) -> dict:
    try:
        out = subprocess.run(
            ['docker', 'inspect', container, '--format', '{{range .Config.Env}}{{println .}}{{end}}'],
            capture_output=True, text=True).stdout
    except FileNotFoundError:
        return {}
    env = {}
    for line in out.splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            env[k] = v
    return env


def read_reply(sock) -> str:
    data = b''
    while not re.search(rb'(?m)^\d{3}[ -]', data):
        chunk = sock.recv(1024)
        if not chunk:
            break
        data += chunk
    lines = data.decode(errors='replace').strip().splitlines()
    return lines[-1] if lines else ''


def pick_tls(port, override):
    if override:
        return override.lower()
    if port in (465, 2465):
        return 'implicit'
    if port in (587, 2587):
        return 'starttls'
    return 'none'


def main() -> int:
    ap = argparse.ArgumentParser(description='Verify a mail relay credential/endpoint (235 = OK, 535 = rejected).')
    ap.add_argument('--host', help=f'relay host (default: container, else {DEFAULT_HOST})')
    ap.add_argument('--port', type=int, help=f'relay port (default: container, else {DEFAULT_PORT})')
    ap.add_argument('--tls', choices=['implicit', 'starttls', 'none'], help='TLS mode (default: inferred from the port)')
    ap.add_argument('--user', help=f'SMTP username (default: {DEFAULT_USER})')
    ap.add_argument('--container', help=f'mail container to read key/host from (default: {DEFAULT_CONTAINER})')
    ap.add_argument('--prompt', action='store_true', help='read the key from a hidden prompt')
    ap.add_argument('--stdin', action='store_true', help='read the key from stdin (e.g. pbpaste | ...)')
    args = ap.parse_args()

    container = args.container or os.environ.get('MAIL_CONTAINER') or DEFAULT_CONTAINER
    cenv = container_env(container)
    host = args.host or os.environ.get('SMTP_HOST') or cenv.get('SMTP_HOST') or DEFAULT_HOST
    port = args.port or (int(os.environ['SMTP_PORT']) if os.environ.get('SMTP_PORT') else None) \
        or int(cenv.get('SMTP_PORT', DEFAULT_PORT))
    user = args.user or os.environ.get('SMTP_USER') or cenv.get('SMTP_USERNAME') or DEFAULT_USER
    mode = pick_tls(port, args.tls)

    if args.prompt:
        key, origin = getpass.getpass('SMTP secret (input hidden): ').strip(), 'typed'
    elif args.stdin:
        key, origin = sys.stdin.readline().strip(), 'stdin/clipboard'
    elif os.environ.get('SMTP_KEY'):
        key, origin = os.environ['SMTP_KEY'].strip(), '$SMTP_KEY'
    else:
        key, origin = cenv.get('SMTP_PASSWORD', ''), f'container {container}'
    if not key:
        print('No key: use --prompt, --stdin, SMTP_KEY=..., or start the mail container.', file=sys.stderr)
        return 2

    print(f'relay {host}:{port} (tls={mode}) as "{user}" with a {len(key)}-char key (source: {origin})')
    verdict = ''
    try:
        with socket.create_connection((host, port), timeout=25) as sock:
            sock.settimeout(25)
            if mode == 'implicit':
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
            print('  greeting :', read_reply(sock))
            sock.sendall(b'EHLO verify.local\r\n')
            print('  ehlo     :', read_reply(sock))
            if mode == 'starttls':
                sock.sendall(b'STARTTLS\r\n')
                print('  starttls :', read_reply(sock))
                sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
                sock.sendall(b'EHLO verify.local\r\n')
                print('  ehlo(tls):', read_reply(sock))
            sock.sendall(b'AUTH LOGIN\r\n')
            print('  auth     :', read_reply(sock))
            sock.sendall(base64.b64encode(user.encode()) + b'\r\n')
            print('  username :', read_reply(sock))
            sock.sendall(base64.b64encode(key.encode()) + b'\r\n')
            verdict = read_reply(sock)
            print('  password :', verdict)
            try:
                sock.sendall(b'QUIT\r\n')
                read_reply(sock)
            except Exception:  # noqa: BLE001
                pass
    except Exception as exc:  # noqa: BLE001
        print(f'  connection failed: {type(exc).__name__}: {exc}')
        return 2
    ok = verdict.startswith('235')
    print('  RESULT   :', 'AUTH OK — this credential works on this endpoint' if ok
          else 'AUTH REJECTED — 535: wrong credential for this user/endpoint (or the relay moved)')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
