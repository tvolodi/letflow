defmodule Letflow.Plugs.ApiPipeline do
  @moduledoc """
  Single shared middleware chain for all tenant-scoped sub-routers. Mounted by
  `Letflow.Router` via `forward "/api/v1", to: Letflow.Plugs.ApiPipeline`; the
  `/api/v1` prefix is stripped before this module is called.

  All middleware that must NOT run on `GET /health` lives here and here only —
  sub-routers declare no plug chains.

  PROVENANCE (historical, not current decision authority):
  `&Letflow.Api.Context.assign_trace_id/1` (REQ-072) is mounted immediately
  after `Plug.Parsers`, before `Letflow.Plugs.AuthPipeline` — so every
  request, including one that fails authentication, gets a trace id. This is
  `trace.zig`'s port; it no longer needs its own deferred-plug row below.

  ## Admission control (REQ-216/REQ-217, ISS-0431/GH#835)

  `Letflow.Plugs.Admission` is mounted TWICE: once with `pool: :global` as the
  very FIRST plug in this chain (before `Plug.Parsers`, so a request rejected
  for lack of capacity costs no body-parsing work), and once with
  `pool: :tenant` immediately after `Letflow.Plugs.AuthPipeline` and before
  `Letflow.Plugs.TenantStatus` (tenant identity is not resolved until
  `AuthPipeline` completes). See `Letflow.Plugs.Admission`'s own moduledoc for
  the full rationale, including the disclosed limitation that `AuthPipeline`'s
  own DB work is covered only by the global gate.

  **REQ-217 rework (design doc §10.1):** `:release_global_admission` is
  mounted between `AuthPipeline` and the `pool: :tenant` mount. It releases
  the GLOBAL gate's already-held ref immediately after `AuthPipeline`
  completes, so the tenant gate's own subsequent
  `try_acquire({:tenant, schema})` call — which, per `Letflow.Admission`'s
  composing rule, ALSO consumes a global unit — is the only global unit this
  request holds from that point forward, not a second one stacked on top of
  an already-held first (the original REQ-217 wiring's double-global-
  consumption defect, fixed here). This deliberately means admission at the
  global gate is a re-checked, not reserved, precondition for admission at
  the tenant gate: a request admitted at the global gate can still receive
  `{:error, :capacity}` at the tenant gate. This is intentional (see the
  design doc §10.3) and must not be "fixed" by re-introducing overlap
  between the two gates' held refs. See
  `Letflow.Plugs.Admission.release_global_ref/1` for the mechanics.

  `use Plug.ErrorHandler` + `handle_errors/2` below is Mechanism B of
  `Letflow.Plugs.Admission`'s raise-safety net — pure cleanup plumbing (drains
  and releases whatever admission refs this process accumulated before a raise
  that occurred in a plug running before `:dispatch`), never a response
  helper. It introduces no new response body/status/contract: `handle_errors/2`
  returns the conn unchanged and `Plug.ErrorHandler`'s own generated `call/2`
  unconditionally re-raises afterward, so Bandit's existing crash-response
  path runs exactly as it does today.

  ## Deferred plugs (not yet declared — added by owning stage)

  PROVENANCE (historical, not current decision authority):
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
  use Plug.ErrorHandler

  # REQ-217 -- global admission gate, first plug in the chain (before
  # Plug.Parsers). See Letflow.Plugs.Admission's moduledoc.
  plug(Letflow.Plugs.Admission, pool: :global)

  # 2 MB cap — large enough for any single-workflow payload while
  # preventing unbounded reads from a single request. This root
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

  # REQ-217 rework (design doc §10.1) -- releases the global gate's
  # already-held ref immediately after AuthPipeline completes, BEFORE the
  # tenant gate's own try_acquire({:tenant, schema}) call runs, so that call
  # (which also consumes a global unit, per Letflow.Admission's composing
  # rule) is the only global unit this request holds from here on, not a
  # second one stacked on an already-held first. See
  # Letflow.Plugs.Admission.release_global_ref/1's own doc.
  plug(:release_global_admission)

  # REQ-217 -- per-tenant admission gate, after AuthPipeline (tenant identity
  # now resolved) and before TenantStatus. See Letflow.Plugs.Admission's
  # moduledoc.
  plug(Letflow.Plugs.Admission, pool: :tenant)

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

  # REQ-217 rework (design doc §10.1) -- same "Plug.Router's plug DSL only
  # accepts a local 2-arity function atom, never a remote function capture"
  # constraint as :assign_trace_id above. Delegates straight to
  # Letflow.Plugs.Admission.release_global_ref/1, ignoring opts.
  defp release_global_admission(conn, _opts), do: Letflow.Plugs.Admission.release_global_ref(conn)

  # REQ-217 Mechanism B (see Letflow.Plugs.Admission's moduledoc "Ref storage
  # and release" section) -- covers a raise inside a plug running BEFORE
  # :dispatch (AuthPipeline, TenantStatus, or Letflow.Plugs.Admission's own
  # believed-unreachable branches), where conn.assigns carries neither
  # admission-ref assign. Process-dictionary state survives that raise
  # regardless of which conn binding is in scope at crash time.
  #
  # Pure cleanup plumbing: returns conn unchanged, introduces no new response
  # body/status. Plug.ErrorHandler's own generated call/2 unconditionally
  # re-raises after this returns, so Bandit's existing crash-response path is
  # unaffected.
  @impl Plug.ErrorHandler
  def handle_errors(conn, %{kind: _kind, reason: _reason, stack: _stack}) do
    Letflow.Plugs.Admission.release_pending_refs()
    conn
  end
end
