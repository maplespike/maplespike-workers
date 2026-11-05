# maplespike-workers

Cloudflare Workers edge stub for Maplespike Quill’s SaaS API (`quill-api`).

This repo holds the Hono Worker under `api/`: an optional SaaS edge twin of the self-hosted Quill API. It is **not** on `quill.maplespike.ca` or `mcp.maplespike.ca` today; both hostnames are served by the self-hosted k3s stack through the Cloudflare tunnel, and attaching the Worker to any hostname would be a separate, future decision. Today it is a **stub** (health, modules list placeholder, OpenAPI stub) with no D1/KV/R2 bindings active.

## Layout

- `api/` — Worker package (`wrangler.toml`, `src/index.ts`, TypeScript)
- `api/wrangler.toml` — Worker name `quill-api`, `nodejs_compat`, compatibility date

## Deploy

From `api/`:

```bash
npm ci
npm run deploy   # wrangler deploy
```

Local:

```bash
npm run dev      # wrangler dev
```

Custom domains noted in `wrangler.toml` are placeholders only and are not attached; `quill.maplespike.ca` and `mcp.maplespike.ca` stay on the self-hosted k3s stack via the tunnel. Attaching any domain would need Cloudflare zone permissions and an explicit decision first.

## Secrets and bindings (paths only)

- **Not in git.** `.env` is gitignored. Do not commit tokens or connection strings.
- **Cloudflare Workers secrets** (dashboard or `wrangler secret put …`) hold runtime credentials once Phase 2 bindings land.
- **Planned bindings** (commented in `api/src/index.ts` / `wrangler.toml`): D1, KV, R2 — configured in the Cloudflare account for this Worker, not as files in this repo.
- Zone/API tokens used to attach custom domains live in the operator’s Cloudflare account / secret store, never under this tree.

## Status

Stub phase. `GET /`, `/v1/health`, `/v1/modules`, `/v1/openapi.json` respond; database-backed routes wait on bindings.
