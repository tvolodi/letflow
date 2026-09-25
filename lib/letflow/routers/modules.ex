defmodule Letflow.Routers.Modules do
  @moduledoc """
  REQ-404 — the D4/D5 module-router dispatch mount. See
  `lib/letflow/design/req404-module-router-mount.md` for the full design (a
  CODE-DESIGN-VALIDATOR-approved design), not a fresh design of its own.

  Mounted at `/modules` by `Letflow.Plugs.ApiPipeline` (full path
  `/api/v1/modules/<module_id>/<rest...>`).

  ## A plain `Plug`, not `Letflow.Api.AuthorizedRouter` (design §1.1)

  `AuthorizedRouter`'s `plug(:match) -> plug(Letflow.Plugs.Authorize) ->
  plug(:dispatch)` chain runs a permission check on EVERY request before any
  handler code runs. D5 requires the OPPOSITE order here: "is this module
  installed for this tenant" must be answered, and can return 404, BEFORE
  any permission evaluation, for every role including `PLATFORM_ADMIN`. So
  this dispatcher does no authorization evaluation of its own — it forwards
  to the module's own `router/0` (an `AuthorizedRouter`-based router, per
  the module contract's `router/0` callback), which performs the REAL
  permission check.

  ## D5's ordering invariant, restated precisely for this dispatcher

  No branch in `call/2` below ever calls
  `Letflow.Api.Authorization.evaluate_access/2` or any function that does.
  The only downstream code that evaluates a permission is the
  forwarded-to module's own `Letflow.Plugs.Authorize`, reached only after
  every 404 branch below has already been cleared.

  ## Response-body minimality / no information leak (D5)

  Every 404 branch below calls the exact same zero-argument
  `Letflow.Api.Response.not_found/1` — the response cannot distinguish
  "module doesn't exist" from "module exists but isn't installed for you"
  from "module exists, installed, but has no `router/0`."

  ## INV-1 (tenant scoping is server-derived only)

  `scoped_opts` here is derived exclusively from
  `conn.assigns.auth_context.tenant_id` via
  `Letflow.Api.Context.scoped_repo_opts/1` — the identical function and
  identical source `Letflow.Plugs.Authorize` itself uses. No path segment,
  query parameter, or header is read for tenant identification.

  ## D3 (module boundary)

  This file never names a concrete module. Every module reference here is
  one of `Letflow.Modules.Catalog`, `Letflow.Modules.Installs`, or a
  runtime value (`entry_module`) obtained from `Catalog.fetch/1` — never a
  literal `Letflow.Modules.<id>` name.
  """

  @behaviour Plug

  alias Letflow.Api.Context
  alias Letflow.Api.Response
  alias Letflow.Modules.Catalog
  alias Letflow.Modules.Installs

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(_opts), do: []

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case conn.path_info do
      [] ->
        Response.not_found(conn)

      [module_id | rest] ->
        gate(conn, module_id, rest)
    end
  end

  # Folds design §1.3 steps 2-6 into one with-chain.
  defp gate(conn, module_id, rest) do
    with {:ok, scoped_opts} <- Context.scoped_repo_opts(conn),
         conn <- Plug.Conn.assign(conn, :scoped_opts, scoped_opts),
         {:ok, entry_module} <- fetch_module(module_id),
         {:ok, router} <- fetch_router(entry_module),
         true <- Installs.installed?(module_id, scoped_opts) do
      Plug.forward(conn, rest, router, router.init([]))
    else
      {:error, :missing_auth_context} -> Response.internal_error(conn)
      {:error, :invalid_tenant_id} -> Response.internal_error(conn)
      {:error, :not_found} -> Response.not_found(conn)
      :no_router -> Response.not_found(conn)
      false -> Response.not_found(conn)
    end
  end

  defp fetch_module(module_id), do: Catalog.fetch(module_id)

  defp fetch_router(entry_module) do
    if function_exported?(entry_module, :router, 0) do
      {:ok, entry_module.router()}
    else
      :no_router
    end
  end
end
