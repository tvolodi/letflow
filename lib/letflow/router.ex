defmodule Letflow.Router do
  @moduledoc """
  Top-level Plug router. Executes docs/migration/decisions/0001-web-framework.md
  addendum (2026-08-20) — Plug/Bandit stands.

  ## Route table

  | Method | Path                | Handler                            | Auth      | DB        |
  |--------|---------------------|------------------------------------|-----------|-----------|
  | GET    | /health             | inline 200 `{"status":"ok"}`       | none      | none      |
  | GET    | /api/tenant-config  | `Letflow.Routers.TenantConfig`     | **none**  | global `tenants` |
  | GET    | /api/mobile/tenant-config | `Letflow.Routers.MobileTenantConfig` | **none** | global `tenants` |
  | GET    | /metrics            | `Letflow.Routers.MetricsExposition`| **none**  | none (ETS only)  |
  | *      | /api/v1/…           | `Letflow.Plugs.ApiPipeline`        | delegated | delegated |
  | *      | _                   | `Letflow.Api.Response.not_found/1` | none      | none      |

  `GET /health` is handled before the `/api/v1` forward so it never enters the
  tenant-scoped middleware pipeline. Contract preserved exactly for
  `deploy/redeploy-test.sh`'s post-deploy health check.

  PROVENANCE (historical, not current decision authority):
  `GET /api/tenant-config` (REQ-078) is forwarded here, **not** from
  `Letflow.Plugs.ApiPipeline`, for the same class of reason: it is R-Co's
  explicitly public login-bootstrap endpoint (`tenant_config.zig:3`), and
  `Letflow.Plugs.AuthPipeline` has no public-path bypass, so behind the
  pipeline it would be unreachable by the only caller that needs it — the
  login page, which has no token yet. Declared before the `/api/v1` forward,
  exactly as `GET /health` is. See `Letflow.Routers.TenantConfig`'s moduledoc
  for the never-error rule and the disclosure boundary.

  `Letflow.Api.Context.assign_trace_id/1` is deliberately **not** mounted on
  this router, so `/api/tenant-config` sets no `x-trace-id` response header
  (harmless — it emits no problem document, ever). Mounting it here would
  change `GET /health`'s response headers, which the health-check contract
  above pins.

  `Letflow.Plugs.Cors` (REQ-118) **is** mounted on this router, ahead of
  `plug(:match)`/`plug(:dispatch)`, so it runs for every route below —
  `/health`, `/api/tenant-config`, and (falling through the forward) every
  `/api/v1/*` route — with one plug. It has to cover `/api/tenant-config`
  too: that's the SPA's login-bootstrap call, cross-origin from a built SPA
  just like `/api/v1/*`, and it has no token yet to authenticate with, so it
  can't go through `Letflow.Plugs.ApiPipeline` either. Mounting CORS here
  does not change `GET /health`'s pinned status/JSON-body contract — it only
  adds response headers, which `test/letflow/router_test.exs` does not
  assert on for that route. See `lib/letflow/design/req118-cors.md` for the
  full design (allowed-origin config, credentials decision, preflight
  handling).

  PROVENANCE (historical, not current decision authority):
  Readiness endpoint (R-Co routes/health.zig handleReady, backed by
  src/api/health/readiness.zig + subsystems.zig) is deliberately not ported — it
  requires S6 observability subsystem probes that do not yet exist. Only the liveness
  endpoint (GET /health) is preserved here.

  `GET /metrics` (REQ-194) is the real Prometheus metrics subsystem superseding
  REQ-078's retired `Letflow.Routers.Metrics` placeholder — see
  `Letflow.Routers.MetricsExposition`'s moduledoc for the full auth/scope/format
  decision (global, unauthenticated, Prometheus exposition text) and the
  tenant-safety invariant that makes an unauthenticated, global scope safe. Declared
  before the `/api/v1` forward for the same reason `/api/tenant-config` is: there is
  no tenant context to resolve and no session to check.

  `Letflow.Plugs.HttpMetrics` (REQ-194) is mounted here, ahead of `plug(:match)`, so
  it observes every route this router serves except `GET /metrics` itself (excluded
  to avoid a self-observation feedback loop in the metrics it is producing). It
  never changes response status/body/headers — only records
  `letflow_http_requests_total`/`letflow_http_errors_total` via a
  `register_before_send/2` callback.

  ## Deferred routes (not yet mounted — added by owning stage)

  PROVENANCE (historical, not current decision authority):
  | Letflow module (pending)            | R-Co source               | Owning stage                          |
  |-------------------------------------|---------------------------|---------------------------------------|
  | `Letflow.Routers.Dlq`               | `dlq.zig`                 | S6 (dead-letter queue subsystem)      |
  | `Letflow.Routers.Services`          | `services.zig`            | S6 (service catalog)                  |
  | `Letflow.Routers.PlatformMigrations`| `platform_migrations.zig` | S6 (platform migration runner)        |
  | `Letflow.Routers.Webhooks`          | `webhooks.zig`            | S6 (webhook dispatch subsystem)       |
  | `Letflow.Routers.SimulationTest`    | `simulation_test.zig`     | S7 (simulation harness)               |
  | `Letflow.Routers.ProcessModules`    | `process_modules.zig`     | S5 (process-module packaging)         |
  | `Letflow.Routers.Entities`          | `entities.zig`            | S5/S6 (entity/data-model subsystem)   |
  | `Letflow.Routers.EntityQuery`       | `entity_query.zig`        | S5/S6 (same, plus query compiler)     |
  | `Letflow.Routers.AgentRequests`     | `agent_task_specs.zig`    | post-S6 (runtime-agent subsystem)     |
  | `Letflow.Routers.AgentResponses`    | `agent_sandboxes.zig`     | post-S6 (runtime-agent subsystem)     |
  | `Letflow.Routers.AgentEvents`       | `agent_artifacts.zig`     | post-S6 (runtime-agent subsystem)     |
  """

  use Plug.Router

  plug(Letflow.Plugs.Cors)
  plug(Letflow.Plugs.HttpMetrics)
  plug(:match)
  plug(:dispatch)

  # No auth, no DB — liveness signal for deploy/redeploy-test.sh.
  get "/health" do
    Letflow.Api.Response.send_json(conn, 200, %{status: "ok"})
  end

  # Public by design (REQ-078) -- declared BEFORE the /api/v1 forward so it
  # never enters Letflow.Plugs.AuthPipeline, which has no bypass.
  forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)

  # Public by design (REQ-124) -- mobile bootstrap, same reasoning as
  # /api/tenant-config above: the mobile app has no token yet when it calls
  # this. Declared immediately after /api/tenant-config and still BEFORE the
  # /api/v1 forward so it never enters Letflow.Plugs.AuthPipeline. See
  # Letflow.Routers.MobileTenantConfig's moduledoc.
  forward("/api/mobile/tenant-config", to: Letflow.Routers.MobileTenantConfig)

  # Public and global by design (REQ-194) -- declared BEFORE the /api/v1 forward so
  # it never enters Letflow.Plugs.AuthPipeline, same reasoning as the two routes
  # above. See Letflow.Routers.MetricsExposition's moduledoc for the full auth/scope
  # reasoning and the tenant-safety invariant this relies on.
  forward("/metrics", to: Letflow.Routers.MetricsExposition)

  forward("/api/v1", to: Letflow.Plugs.ApiPipeline)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
