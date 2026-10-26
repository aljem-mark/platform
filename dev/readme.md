# Docker Compose dev image

## Deploying (`scripts/deploy.sh`)

One script for both environments. It checks the config before recreating anything
(one shared token secret, single-URL values, no `huly.local` on the server, secret not
changed by accident), recreates the stack, then runs a health check (restarts, shared
secret, transactor URLs, and mail: `MAIL_URL`, mail password, SMTP login). It never prints
secrets and does not build images (run `rush docker:build` first).

```bash
sudo bash scripts/deploy.sh                 # server/prod (default): /etc/wedidwork/secrets.env
bash scripts/deploy.sh --local              # local: dev/.env (created with --local if missing)
```

| Flag | What it does |
| --- | --- |
| `--local` | Deploy the local stack instead of the server |
| `--min` | Minimal stack (adds `docker-compose.min.yaml`) |
| `--pull` | `git pull --ff-only` first (as the repo owner, not root) |
| `--rebuild-secrets` | Server: run `build-secrets-env.sh` first |
| `--fix-override` | Replace literal token secrets in `docker-compose.override.yaml` with `${HULY_SHARED_SECRET}` (backup first) |
| `--rotate-secret` | Deliberately change `HULY_SHARED_SECRET` (logs everyone out, voids API tokens) |
| `--check` | Only run the health check on the running stack |
| `--dry-run` | Run the pre-checks and show the compose command; change nothing |
| `--skip-smtp` | Skip the SMTP login test (the health check otherwise runs `smtp-auth-check.py` for you) |
| `--wait <s>` | Seconds to wait before the health check (default 45) |

## Configuration (`dev/.env`)

`dev/docker-compose.yaml` reads its deployment values (`DB_CR_URL`, `QUEUE_CONFIG`,
`STORAGE_CONFIG`, `HULY_SHARED_SECRET`, the internal service URLs, ...) from
**`dev/.env`**, which Compose loads automatically when it runs from this directory.

Create it once before the first `up`:

```bash
cp dev/.env.example dev/.env      # local defaults + REPLACE_ME_* to fill in
```

or generate it with the domain + secrets already substituted (prompts for the mail
provider key):

```bash
bash scripts/generate-prod-config.sh --domain <your-domain>
```

`dev/.env` is **gitignored and must never be committed** — it holds real secrets
(shared token-signing key, DB credentials, mail provider key). The committed template
is `dev/.env.example`; keep it in sync when you add a variable. `--help` on the script
shows the other options (`--dry-run`, `--rotate-secret`).

## Running platform inside docker compose

```bash
rush build
rush bundle
rush docker:build
docker compose up -d --force-recreate
```

The minified stack (`rush docker:up:min`) is the documented resource-constrained path.
Note that `rush docker:min` does **not** build every pod that the min compose starts
(e.g. `@hcengineering/pod-mail` is only in the full `rush docker:build` list), so build
such images explicitly with `rush docker:build --to <package>` when you need them.

## Running ElasticVUE to check elastic intance

```bash
docker run -p 8082:8080 -d cars10/elasticvue
```

## Running Local NPM registry with Docker

```bash
docker run -it --rm --name verdaccio -p 4873:4873 verdaccio/verdaccio
```

```bash
npm set registry http://localhost:4873
npm adduser
npm login
```

Verdaccio will be available via HTTP http://localhost:4873