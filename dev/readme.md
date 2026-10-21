# Docker Compose dev image

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