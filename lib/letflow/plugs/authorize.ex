defmodule Letflow.Plugs.Authorize do
  @moduledoc """
  Mandatory authorization plug (REQ-131), built exactly to REQ-130's design
  (`lib/letflow/design/req130-authorization-generalization.md` §2.3).
  Supersedes every router-local `with_authorized_scope/4`/`with_authorization/4`
  copy that existed before this requirement (`identity.ex`, `audit.ex`,
  `definitions.ex`, `instances.ex`, `onboarding.ex`, `tenants.ex`, `tasks.ex`)
  — all deleted, not adapted, by this same requirement.

  Mounted automatically by every sub-router under `lib/letflow/routers/`
  that does `use Letflow.Api.AuthorizedRouter` (which `plug`s this module
  between `:match` and `:dispatch`) — never wired by hand at a route, and
  never opt-in per route. A route declared with `Letflow.Api.AuthorizedRouter`'s
  `authz_get/3`/`authz_post/3`/`authz_patch/3`/`authz_delete/3` macros gets
  its own literal policy key enforced; a route declared with the plain
  `Plug.Router` `get`/`post`/`patch`/`delete` macros (or the router's own
  catch-all `match _`) still passes through this plug — since it is
  unconditionally in the pipeline — and is evaluated as `:Unknown`, i.e.
  fail-closed-EXCEPT-`PLATFORM_ADMIN` (see below). There is no route shape
  that reaches a handler without going through this plug.

  ## Ordering (design §2.3)

  Runs strictly after `Letflow.Plugs.AuthPipeline` (so
  `conn.assigns.auth_context` — `user_id`, `tenant_id`, `roles` — is already
  populated) and performs the tenant-scope resolution
  (`Letflow.Api.Context.scoped_repo_opts/1`) itself, before evaluating
  authorization — matching every incumbent per-router preamble's own
  ordering (scope resolved first, permission checked second, matching
  `identity.ex`'s/`tasks.ex`'s former `with_authorized_scope/4`). A
  scope-resolution failure (`{:error, :missing_auth_context |
  :invalid_tenant_id}`) is an immediate `500`
  (`Letflow.Api.Response.internal_error/1`), sent and the conn halted,
  before `Letflow.Api.Authorization.evaluate_access/2` is ever called.

  ## Policy key resolution — literal, never request-derived (design §2.1, §2.3)

  `Letflow.Api.AuthorizedRouter`'s route macros attach the route's policy
  key as `conn.private[:policy_key]` via `Plug.Router`'s own `:private`
  route-match option — resolved by the compiled `:match` plug at
  route-match time from a **compile-time literal atom** baked into the
  route declaration, never derived from `conn.request_path`,
  `conn.path_info`, or any other request-observed value. This preserves
  REQ-130's design §2.1 safety property (the same one every incumbent
  per-call-site helper already honoured) while moving *where* the literal
  lives (declared once at the route) and *who* enforces it runs
  (unconditionally, for every route under a router using
  `Letflow.Api.AuthorizedRouter`).

  A route matched with no `:policy_key` private key present — i.e. a route
  declared with the plain `get`/`post`/`patch`/`delete` macros instead of
  `authz_*`, or the router's own `match _` catch-all — is treated as
  `endpoint == :Unknown`, `Letflow.Api.Authorization.evaluate_access/2`'s
  own ported catch-all branch: **fail-closed-EXCEPT-`PLATFORM_ADMIN`**, not
  wide open. This is what makes the mechanism unconditional rather than
  opt-in: even a route a future author forgets to run through `authz_*` is
  never silently reachable by every caller — at worst it is silently
  reachable by `PLATFORM_ADMIN` only, which is the same fixed constraint
  `Letflow.Api.Authorization`'s own `:Unknown` branch already imposes and
  that this plug is built around, not permitted to "fix" (see that
  module's moduledoc and REQ-130's design §3).

  ## What reaches the handler on `:Allow`/`:AllowWithRowFilter` (design §6)

    * `conn.assigns[:scoped_opts]` — the `[prefix: schema]` keyword list
      every handler passes to its own `Repo`/context-module calls. Replaces
      the `opts` argument every incumbent `with_authorized_scope/4`-wrapped
      handler used to receive as a function argument.
    * `conn.assigns[:access_decision]` — the **full** `%AccessDecision{}`
      struct, never collapsed to a bare boolean or to its `:kind` alone —
      so a handler that needs `decision.task_scope` (today, only
      `Letflow.Routers.Tasks`'s `GET /tasks`/`GET /tasks/inbox`, the only
      policy key that can ever produce `:AllowWithRowFilter`) can read it.
      A handler with no row-scoped concept of its resource ignores this key
      entirely, exactly like every already-wired router except `tasks.ex`
      already does.

  On `:Deny403`, this plug itself sends `403` via
  `Letflow.Api.Response.forbidden/2` (RFC 9457 problem document via
  `Letflow.Api.Response`/`Letflow.Api.Error`, `Content-Type:
  application/problem+json`, per REQ-066's contract) and halts the conn —
  no handler runs, no `Repo` call of any kind has happened by this point.
  """

  @behaviour Plug

  import Plug.Conn

  alias Letflow.Api.Authorization
  alias Letflow.Api.Context
  alias Letflow.Api.Response

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Context.scoped_repo_opts(conn) do
      {:error, _missing_auth_context_or_invalid_tenant_id} ->
        conn |> Response.internal_error() |> halt()

      {:ok, prefix: _schema} = ok ->
        ctx = %Authorization.AccessContext{
          user_id: conn.assigns.auth_context.user_id,
          roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)
        }

        # No :policy_key private key present (plain get/post/patch/delete, or
        # a router's own `match _` catch-all) -> :Unknown, evaluate_access/2's
        # own fail-closed-EXCEPT-PLATFORM_ADMIN branch. Never widened.
        policy_key = Map.get(conn.private, :policy_key, :Unknown)
        decision = Authorization.evaluate_access(ctx, policy_key)

        case decision.kind do
          :Deny403 ->
            conn |> Response.forbidden("insufficient permissions") |> halt()

          _allow_or_allow_with_row_filter ->
            {:ok, opts} = ok

            conn
            |> assign(:scoped_opts, opts)
            |> assign(:access_decision, decision)
        end
    end
  end
end
