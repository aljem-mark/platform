# we-did-work Backend REST API

This document is the companion guide to [`openapi.yaml`](./openapi.yaml). It
explains how to authenticate, how the model-driven workspace API works, and how
to perform common operations end to end.

> **Interactive viewer:** the OpenAPI spec is also served through a Swagger UI
> page. See [Serving the spec](#serving-the-spec) below.

---

## 1. Authentication

The API is authenticated with a **Bearer token** minted inside the application.

### Creating an API token

1. Open the app and go to **Settings → API Tokens**.
2. Click **Create token** (or the equivalent add action).
3. Give it a name, choose the **workspace** it is bound to, and pick an expiry
   (7 / 30 / 90 / 180 / 365 days).
4. Copy the returned token. It is shown only once.

### Using the token

Send it in the `Authorization` header on every request:

```
Authorization: Bearer <token>
```

The token encodes a **workspace**. Every workspace-data endpoint takes a
`:workspaceId` path parameter, and the request is rejected with **403** if it
does not match the token's bound workspace.

### Revocation

Tokens are revocable from the same **Settings → API Tokens** screen. A revoked
or expired token is rejected with **401** (`Invalid or revoked token`).

### Rate limiting

Workspace-data endpoints are rate limited. On a 429 response, the server returns
`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`, and
`Retry-After` headers. Back off until `Retry-After` elapses before retrying.

---

## 2. The model-driven workspace API

The workspace API is **model-driven**. Documents are addressed by **class**
(`Ref<Class<Doc>>`), and every class lives in a **domain** in the workspace's
hierarchy. To query or write data you must know the valid class references.

### Load the model first

```
GET /api/v1/load-model/{workspaceId}
```

Returns the model txes that define the hierarchy (classes, attributes, mixins,
types, statuses, permissions, spaces). Use this to discover the class refs you
need (e.g. `tracker:class:Issue`, `contact:class:Person`).

### Querying documents

```
GET /api/v1/find-all/{workspaceId}?class=tracker:class:Issue&query={...}&options={...}&limit=50
```

or, with a JSON body:

```
POST /api/v1/find-all/{workspaceId}
Content-Type: application/json

{ "_class": "tracker:class:Issue", "query": { "space": "tracker:space:DefaultProject" }, "options": { "limit": 50 } }
```

- `_class` must resolve in the hierarchy, otherwise the server returns **404**
  (`Invalid class name is passed. Failed to findAll.`).
- `query` is a `DocumentQuery` (field filters, `$in`, `$nin`, etc.).
- `options` is a `FindOptions` (`limit`, `sort`, `projection`, ...).

### Writing documents

Writes are expressed as internal **Tx** objects and applied through a single
endpoint:

```
POST /api/v1/tx/{workspaceId}
Content-Type: application/json

{ ...tx... }
```

The `Tx` format is the platform's internal transaction format. The common
shapes are:

- **Create** (`TxCreateDoc`): `_class`, `objectClass`, `objectId`, `objectSpace`,
  `attributes`, `modifiedBy`, `modifiedOn`.
- **Update** (`TxUpdateDoc`): `_class`, `objectId`, `objectClass`, `operations`,
  `modifiedBy`, `modifiedOn`.
- **Remove** (`TxRemoveDoc`): `_class`, `objectId`, `objectClass`, `modifiedBy`,
  `modifiedOn`.
- **Collection** (`TxCollectionCUD`): wraps a create/update/remove on an
  attached collection (e.g. adding a member to a space).

> The exact field names follow `@hcengineering/core`'s `Tx` types. When in
> doubt, capture a real write from the app (or the `load-model` output) and
> mirror its shape.

### Other workspace endpoints

- `GET /api/v1/ping/{workspaceId}` — session liveness.
- `GET /api/v1/account/{workspaceId}` — current account for the session.
- `GET /api/v1/search-fulltext/{workspaceId}?query=...` — full-text search.
- `GET|POST /api/v1/request/{domain}/...` — domain RPC.
- `POST /api/v1/ensure-person/{workspaceId}` — ensure a person + social identity.
- `GET /api/v1/generate-id/{workspaceId}` — generate a fresh document id.

---

## 3. End-to-end example: list issues for a workspace

This example uses `curl`. Replace `{token}`, `{workspaceId}`, and the host as
needed.

```bash
HOST=https://huly.local:8087
TOKEN=<your-api-token>
WS=<your-workspace-id>

# 1. Confirm the session is alive
curl -s -H "Authorization: Bearer $TOKEN" \
  "$HOST/api/v1/ping/$WS"

# 2. Load the model to find the Issue class ref (grep for tracker:class:Issue)
curl -s -H "Authorization: Bearer $TOKEN" \
  "$HOST/api/v1/load-model/$WS" | grep -o 'tracker:class:Issue' | head -1

# 3. List issues in a project
curl -s -H "Authorization: Bearer $TOKEN" \
  "$HOST/api/v1/find-all/$WS?class=tracker:class:Issue&query=%7B%22space%22%3A%22tracker:space:DefaultProject%22%7D&limit=50"
```

---

## 4. Server ops and account endpoints

- `GET /api/v1/version` — server model version (unauthenticated).
- `GET /api/v1/health` — server health (unauthenticated).
- `GET /api/v1/statistics`, `GET /api/v1/profiling`, `PUT /api/v1/manage`,
  `PUT /api/v1/broadcast` — admin/ops (Bearer).
- `PUT /cookie`, `DELETE /cookie`, `POST /` — account service (cookie / account
  RPC).
- `GET|POST /files`, `GET|POST|DELETE /files/*` — blob/file storage.

---

## 5. Serving the spec

The OpenAPI spec is served through a static **Swagger UI** page so consumers
can browse and try the endpoints interactively.

- Spec file: `docs/api/openapi.yaml`
- Swagger UI route: `/api/docs` (served statically by the front server)

> **Security note:** the spec is a **static reference** — it contains no live
> tokens, workspace ids, or runtime secrets. The routes are **disabled by
> default** (`DOC_MODE` unset) and return 404, so the API surface stays
> invisible on public domains.

### Modes (`DOC_MODE` env var on the front service)

| Mode | Served spec | Use |
|---|---|---|
| `off` (unset/anything else) | nothing — both routes 404 | production / public domains (default) |
| `safe` | `openapi-safe.yaml` — consumer endpoints only; admin/infra paths (manage, broadcast, profiling, statistics, cookie/session, account RPC, deprecated event) excluded | staging / internal deployments |
| `all` | `openapi.yaml` — full internal spec incl. admin/ops endpoints | internal/ops only |

Any value other than exactly `safe` or `all` (including `true`, `1`, `on`)
behaves as `off` — fail-closed.

### Enabling the docs viewer

Set `DOC_MODE` in the front service's environment:

- Docker: add `DOC_MODE=safe` (or `all`) to the front service's
  `environment:` block in `dev/docker-compose.yaml` (or your deployment's
  compose file), then restart the stack.
- Local dev without Docker (`rushx run-local` in `pods/front`): export
  `DOC_MODE` before starting.

Keep `off` on public/production domains unless you deliberately want the API
surface visible; when enabled the routes are still unauthenticated.

> **Rebuild note:** `rush docker:min`'s incremental build does not track the
> esbuild bundle, so edits to `server/front` routes or the spec may be silently
> skipped. Use `rush docker:rebuild` when front-route or spec changes are
> involved.

---

## 6. References

- `pods/server/src/rpc.ts` — workspace-data REST endpoints (Express).
- `pods/server/src/server_http.ts` — server ops endpoints.
- `server/account-service/src/index.ts` — account service (Koa).
- `server/front/src/index.ts` — front server (SPA + files + static).
- `ARCHITECTURE_OVERVIEW.md` — service/port table.
