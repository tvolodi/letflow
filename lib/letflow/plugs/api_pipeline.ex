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

  ## Mount changes made by REQ-078

    * **`/solution-packs` added** — `Letflow.Routers.SolutionPacks`, a new
      sub-router. R-Co's `{tenant_id}` path segment is deliberately **not**
      carried (INV-1); see that module's moduledoc.
    * **`/validation` removed**, and `Letflow.Routers.Validation` deleted with
      it. R-Co has **no `/validation` URL prefix anywhere** — the endpoint is
      `POST /api/v1/definitions/:id/validate`, which now lives on
      `Letflow.Routers.Definitions`. The stub was an artefact of REQ-070
      grouping by Zig *filename* rather than by URL, and `forward/2` is
      prefix-exclusive so it could never have carried the real path.
    * **`/tenant-config` removed** — `Letflow.Routers.TenantConfig` is now
      forwarded from `Letflow.Router` at `/api/tenant-config`, **outside this
      pipeline**, because it is a public login-bootstrap endpoint and
      `Letflow.Plugs.AuthPipeline` has no bypass: behind auth it is
      unreachable by the only caller that needs it. The module file did not
      move; only its mount did. See its moduledoc.
  """

  use Plug.Router

  # 2 MB cap — matches R-Co's `max_body_size` default; large enough for any
  # single-workflow payload while preventing unbounded reads. This root
  # `length:` is the shared floor forwarded to every parser in the list
  # below UNLESS a parser overrides it via its own `{parser, opts}` tuple
  # (`Plug.Parsers.init/1`: `Keyword.merge(root_opts, opts)`, per-parser
  # `opts` winning) — so the `:json` branch keeps this 2 MB ceiling
  # unchanged.
  #
  # REQ-212 added `:multipart` so `POST /instances/:id/attachments` can
  # accept a file upload — deliberately NOT via a route-scoped second
  # Plug.Parsers plug (Letflow.Api.AuthorizedRouter's plug chain is fixed to
  # match/Authorize/dispatch for every router using it; changing that would
  # affect every other router) and deliberately NOT by raising the shared
  # root `length:` itself (every other sub-router mounted below would
  # silently start accepting a much larger body of ANY content type, a
  # DoS-surface change no other route asked for). Instead `:multipart` gets
  # its own per-parser `length:` override, `26_214_400` (25 MiB) — MUST stay
  # numerically identical to `Letflow.Repository.Attachments.@max_upload_bytes`
  # (lib/letflow/repository/attachments.ex), REQ-211's own upload-size
  # ceiling and the authoritative check (this Plug.Parsers value is a
  # stronger, earlier DoS defense — rejecting an oversized multipart body
  # before it is fully buffered — not a replacement for that check). Both
  # numbers must change together; flagged for REVIEWER (design
  # lib/letflow/design/req212-instance-attachments-routes.md §2.1/§7).
  plug(Plug.Parsers,
    parsers: [:json, {:multipart, length: 26_214_400}],
    json_decoder: Jason,
    length: 2_097_152
  )

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
  forward("/promotions", to: Letflow.Routers.Promotions)
  forward("/onboarding", to: Letflow.Routers.Onboarding)
  forward("/solution-packs", to: Letflow.Routers.SolutionPacks)
  forward("/audit", to: Letflow.Routers.Audit)
  forward("/dlq", to: Letflow.Routers.Dlq)
  forward("/webhooks", to: Letflow.Routers.Webhooks)
  forward("/services", to: Letflow.Routers.Services)
  forward("/admin/services", to: Letflow.Routers.AdminServices)

  match _ do
    Letflow.Api.Response.not_found(conn)
  end

  # `Plug.Router`'s `plug` DSL (via `Plug.Builder`) only accepts an atom
  # naming a local 2-arity function, or a module — not a remote function
  # capture — so this thin 2-arity wrapper is the mount point; the real
  # implementation stays in `Letflow.Api.Context`, per REQ-072's design.
  defp assign_trace_id(conn, _opts), do: Letflow.Api.Context.assign_trace_id(conn)
end
