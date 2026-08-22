defmodule Letflow.Router do
  @moduledoc """
  Top-level Plug router. Executes docs/migration/decisions/0001-web-framework.md
  addendum (2026-08-20) — Plug/Bandit stands.

  ## Route table

  | Method | Path                | Handler                            | Auth      | DB        |
  |--------|---------------------|------------------------------------|-----------|-----------|
  | GET    | /health             | inline 200 `{"status":"ok"}`       | none      | none      |
  | GET    | /api/tenant-config  | `Letflow.Routers.TenantConfig`     | **none**  | global `tenants` |
  | *      | /api/v1/…           | `Letflow.Plugs.ApiPipeline`        | delegated | delegated |
  | *      | _                   | `Letflow.Api.Response.not_found/1` | none      | none      |

  `GET /health` is handled before the `/api/v1` forward so it never enters the
  tenant-scoped middleware pipeline. Contract preserved exactly for
  `deploy/redeploy-test.sh`'s post-deploy health check.

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

  Readiness endpoint (R-Co routes/health.zig handleReady, backed by
  src/api/health/readiness.zig + subsystems.zig) is deliberately not ported — it
  requires S6 observability subsystem probes that do not yet exist. Only the liveness
  endpoint (GET /health) is preserved here.

  ## Deferred routes (not yet mounted — added by owning stage)

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

  plug(:match)
  plug(:dispatch)

  # No auth, no DB — liveness signal for deploy/redeploy-test.sh.
  get "/health" do
    Letflow.Api.Response.send_json(conn, 200, %{status: "ok"})
  end

  # Public by design (REQ-078) -- declared BEFORE the /api/v1 forward so it
  # never enters Letflow.Plugs.AuthPipeline, which has no bypass.
  forward("/api/tenant-config", to: Letflow.Routers.TenantConfig)

  forward("/api/v1", to: Letflow.Plugs.ApiPipeline)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
