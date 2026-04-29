# Railway Deployment Guide

> **Audience:** Internal Eco team
> **File:** `docs/deployment/RAILWAY.md`
> **Last Updated:** 2026-04-29

This guide walks you through standing up a Railway project that runs the code-ingest stack: Qdrant, a cron-scheduled ingestion service, and the MCP query server. All three services live in a single Railway project and talk over Railway's private network. None of them is exposed to the public internet.

## 1. Prerequisites

- A Railway account with access to the Eco team workspace.
- A new (empty) Railway project — create one in the dashboard.
- Railway **Pro plan** is recommended. Hobby plan caps volume sizes lower than what the full Eco repo set needs (see "Volumes" below).
- Required secrets ready:
  - `DEEPINFRA_API_KEY` — from https://deepinfra.com/dash/api_keys
  - `GITHUB_TOKEN` — a Personal Access Token with `repo` scope to clone private Eco repos.

## 2. Project-level shared variables

Set these on the Railway project (so they're inherited by services that need them):

| Variable | Value |
|---|---|
| `DEEPINFRA_API_KEY` | your key |
| `GITHUB_TOKEN` | your PAT |
| `QDRANT_URL` | `http://qdrant-code-ingest.railway.internal:6333` |

`QDRANT_URL` points at the Qdrant service over Railway's private network — see service naming below. Do not set `QDRANT_API_KEY`; the bundled Qdrant has no auth.

## 3. Enable private networking

In the project's **Settings → Networking**, ensure **Private Networking** is enabled. All three services will use private DNS (`*.railway.internal`) to reach each other; no service should expose a public domain.

## 4. Create the three services

Create each service in the project. **Service names matter** — the Qdrant DNS hostname is derived from its service name.

### 4a. `qdrant-code-ingest`

- **Name:** `qdrant-code-ingest` (exactly — used in `QDRANT_URL`).
- **Source:** Docker Image. Image: `qdrant/qdrant:latest`.
- **Config-as-code Path:** `railway/qdrant.toml`.
- **Volume:** mount at `/qdrant/storage`, **50 GB**.
- **Networking:** internal port 6333. **No public domain.**
- **Environment variables:** none required. Optional: `QDRANT__SERVICE__GRPC_PORT=6334`.

### 4b. `code-ingest-ingest`

- **Name:** `code-ingest-ingest`.
- **Source:** This GitHub repo. Branch: `main`.
- **Config-as-code Path:** `railway/ingest.toml`.
- **Volume:** mount at `/app/repos`, **20 GB**. (Without this, every cron run re-clones every repo from scratch.)
- **Networking:** no exposed ports.
- **Environment variables:** inherits `DEEPINFRA_API_KEY`, `GITHUB_TOKEN`, `QDRANT_URL` from the project. Optional overrides:
  - `PRIORITY` (default `low`) — `low` ingests medium+high priority repos and unprioritized repos. `medium`, `high`, or `ALL` change the filter. See `config/repositories.yaml`.
  - `EMBEDDING_MODEL` (default `Qwen/Qwen3-Embedding-8B`).
  - `BATCH_SIZE` (default `15`).
  - `EMBEDDING_TIMEOUT` (default `120`).
  - `LOG_LEVEL` (default `INFO`).

### 4c. `code-ingest-mcp`

- **Name:** `code-ingest-mcp`.
- **Source:** This GitHub repo. Branch: `main`.
- **Config-as-code Path:** `railway/mcp.toml`.
- **Volume:** none.
- **Networking:** internal port 8001. **No public domain.**
- **Environment variables:** inherits `DEEPINFRA_API_KEY`, `QDRANT_URL` from the project. Add the following service-scoped variables:
  - `MCP_HTTP_TRANSPORT=true`
  - `ENABLE_HEALTH_ENDPOINT=true`
  - `HEALTH_PORT=8001`
  - `DOCKER_ENV=true`
  - Optional: `EMBEDDING_MODEL` (must match `code-ingest-ingest`), `LOG_LEVEL`.

## 5. First ingestion run

The default cron schedule is `0 4 * * *` (04:00 UTC nightly). To populate Qdrant before the next scheduled tick:

1. In the Railway dashboard, open `code-ingest-ingest` and click **Deploy** (or run **Redeploy**). Railway runs the entrypoint once.
2. Watch logs (**Deployments → latest → Logs**). Expected sequence:
   - "⏳ Waiting for Qdrant..." → "✅ Qdrant is ready"
   - "📥 Cloning repositories..." (first run; subsequent runs say "🔄 Refreshing existing repositories")
   - "🔍 Running repository discovery..."
   - "🚀 Starting ingestion pipeline..."
   - per-repo / per-batch progress
   - "✅ Ingestion complete!" with `Total chunks` and `Repositories` counts.
3. Once the run finishes (exit 0), `code-ingest-mcp` should report ready. From inside the Railway project (e.g. via `railway shell` on any service), or from a developer machine using `railway connect`, hit:
   ```
   curl http://code-ingest-mcp.railway.internal:8001/health
   ```
   Expected:
   ```json
   {
     "status": "ready",
     "qdrant": "ok",
     "backend_type": "qdrant",
     "ingestion": "complete"
   }
   ```

## 6. Changing the cron schedule

Edit `railway/ingest.toml` and update `cronSchedule`. Standard 5-field cron syntax (minute hour dom month dow). Examples:
- `0 4 * * *` — nightly at 04:00 UTC (default)
- `0 */6 * * *` — every 6 hours
- `0 4 * * 1` — Mondays at 04:00 UTC

Commit the change and redeploy. The new schedule takes effect on the next deploy.

## 7. Connecting an IDE to the MCP server

Because MCP has no public domain, your IDE (Cursor, Claude Code, etc.) can't reach it directly. Use Railway's developer tunneling:

```bash
railway login
railway link            # pick the project + the code-ingest-mcp service
railway connect         # opens a local tunnel to the service's internal port
```

`railway connect` exposes the MCP server on a localhost port; point your IDE's MCP config at `http://localhost:<port>/mcp`.

This is per-developer and short-lived — for an always-on integration we'd need either a public domain + bearer auth (deferred, see spec) or a proxy/gateway service. Out of scope for v1.

## 8. Operations

**Logs.** Each service has its own log stream in the Railway dashboard. The cron service's logs are organized per-run (one "deployment" per cron firing).

**Resizing volumes.** Railway → service → Settings → Volume → resize. Volumes can be grown without data loss up to the plan's per-volume cap (250 GB on Pro).

**Rotating secrets.** Update the variable on the project, then redeploy each affected service so it picks up the new value.

**Cost watch.** The cron service only consumes compute during its run window — long-running cost is dominated by the Qdrant service and its volume.

## 9. Troubleshooting

**Symptom:** Ingest container exits with `❌ Missing required environment variable(s): ...`.
**Fix:** Set `DEEPINFRA_API_KEY` and `GITHUB_TOKEN` on the project (or service) and redeploy.

**Symptom:** Ingest container says `❌ Qdrant did not become healthy in time`.
**Fix:** Check `QDRANT_URL` is `http://qdrant-code-ingest.railway.internal:6333` (match the Qdrant service name exactly). Confirm private networking is enabled and the Qdrant service is running.

**Symptom:** MCP `/health` returns `{"status": "waiting_for_ingestion", "ingestion": "pending"}` long after deploy.
**Fix:** Check that `code-ingest-ingest` has run successfully (Deployments tab). Trigger a manual deploy if the cron hasn't fired yet.

**Symptom:** MCP `/health` returns `{"ingestion": "unknown"}`.
**Fix:** MCP can't probe Qdrant — check `QDRANT_URL` on the MCP service and that Qdrant is healthy.

**Symptom:** Volume hits ~80% full.
**Fix:** Resize via the Railway dashboard. For `qdrant-code-ingest` storage, also confirm collection points growth is expected — large unexplained growth may indicate a duplicate-ingestion issue.

## 10. Optional: save as a private template

Once the project is up and validated, use Railway dashboard → **Save as Template** → keep it **private** to the Eco workspace. The team can then deploy new instances with one click. This step is manual — it doesn't live in this repo.

## Related documentation

- [Spec](../superpowers/specs/2026-04-29-railway-template-design.md)
- [Docker Compose local setup](../../docker/README.md)
- [Architecture overview](../architecture/OVERVIEW.md)
