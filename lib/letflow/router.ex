defmodule Letflow.Router do
  @moduledoc """
  Top-level Plug router. Executes docs/migration/decisions/0001-web-framework.md
  addendum (2026-08-20) — Plug/Bandit stands.

  ## Route table

  | Method | Path        | Handler                            | Auth      | DB        |
  |--------|-------------|------------------------------------|-----------|-----------|
  | GET    | /health     | inline 200 `{"status":"ok"}`       | none      | none      |
  | *      | /api/v1/… | `Letflow.Plugs.ApiPipeline`        | delegated | delegated |
  | *      | _           | `Letflow.Api.Response.not_found/1` | none      | none      |

  `GET /health` is handled before the `/api/v1` forward so it never enters the
  tenant-scoped middleware pipeline. Contract preserved exactly for
  `deploy/redeploy-test.sh`'s post-deploy health check.

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

  forward("/api/v1", to: Letflow.Plugs.ApiPipeline)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end
end
