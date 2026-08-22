defmodule Letflow.Plugs.ApiPipeline do
  @moduledoc """
  Single shared middleware chain for all tenant-scoped sub-routers. Mounted by
  `Letflow.Router` via `forward "/api/v1", to: Letflow.Plugs.ApiPipeline`; the
  `/api/v1` prefix is stripped before this module is called.

  All middleware that must NOT run on `GET /health` lives here and here only —
  sub-routers declare no plug chains.

  `&Letflow.Api.Context.assign_trace_id/1` (REQ-072) is mounted first —
  immediately after `Plug.Parsers`, before `Letflow.Plugs.AuthPipeline` — so
  every request, including one that fails authentication, gets a trace id.
  This is `trace.zig`'s port; it no longer needs its own deferred-plug row
  below.

  ## Deferred plugs (not yet declared — added by owning stage)

  | Deferred plug                    | R-Co source              | Owning stage                              |
  |----------------------------------|--------------------------|-------------------------------------------|
  | `Letflow.Plugs.ContentType`      | `content_type.zig`       | S4 (no owning REQ assigned yet)           |
  | `Letflow.Plugs.Validate`         | `validate.zig`           | S4 (REQ-068 shape already ported)         |
  | `Letflow.Plugs.RateLimit`        | `rate_limit.zig`         | S4 (to port)                              |
  | `Letflow.Plugs.QuotaEnforcement` | `quota_enforcement.zig`  | S4 (to port)                              |
  | `Letflow.Plugs.OutboxCap`        | `outbox_cap.zig`         | S6 (outbox subsystem)                     |
  | `Letflow.Plugs.AgentAuth`        | `agent_auth.zig`         | post-S6 (runtime-agent subsystem)         |
  """

  use Plug.Router

  # 2 MB cap — matches R-Co's `max_body_size` default; large enough for any
  # single-workflow payload while preventing unbounded reads.
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, length: 2_097_152)
  plug(:assign_trace_id)
  plug(Letflow.Plugs.AuthPipeline)
  plug(Letflow.Plugs.TenantStatus)
  plug(:match)
  plug(:dispatch)

  forward("/identity", to: Letflow.Routers.Identity)
  forward("/tenants", to: Letflow.Routers.Tenants)
  forward("/instances", to: Letflow.Routers.Instances)
  forward("/definitions", to: Letflow.Routers.Definitions)
  forward("/tasks", to: Letflow.Routers.Tasks)
  forward("/promotion", to: Letflow.Routers.Promotion)
  forward("/onboarding", to: Letflow.Routers.Onboarding)
  forward("/audit", to: Letflow.Routers.Audit)
  forward("/tenant-config", to: Letflow.Routers.TenantConfig)
  forward("/validation", to: Letflow.Routers.Validation)
  forward("/metrics", to: Letflow.Routers.Metrics)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end

  # `Plug.Router`'s `plug` DSL (via `Plug.Builder`) only accepts an atom
  # naming a local 2-arity function, or a module — not a remote function
  # capture — so this thin 2-arity wrapper is the mount point; the real
  # implementation stays in `Letflow.Api.Context`, per REQ-072's design.
  defp assign_trace_id(conn, _opts), do: Letflow.Api.Context.assign_trace_id(conn)
end
