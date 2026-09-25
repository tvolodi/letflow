defmodule Letflow.Routers.TenantModules do
  @moduledoc """
  REQ-403 — the HTTP half of `docs/migration/decisions/0039-platform-module-solution-layering.md`
  D5's install path. See
  `lib/letflow/design/req403-module-install-route.md` §2 for the full
  design (a CODE-DESIGN-VALIDATOR-approved design), not a fresh design of
  its own.

  Mounted at `/tenant/modules` by `Letflow.Plugs.ApiPipeline` (full path
  `/api/v1/tenant/modules`), the same forwarding shape as the existing
  `forward("/tenant/settings", to: Letflow.Routers.TenantSettings)` line.

  One route: `POST /` (full path `POST /api/v1/tenant/modules`), gated by
  `:ModulesManage` (`PLATFORM_ADMIN`-only, per REQ-401/D5).

  Deliberately mounted at `/tenant/modules`, NOT under `/api/v1/modules/`
  (REQ-404's future per-module mount) — so this route can never collide
  with a future module whose catalog id happens to be `install`.

  Delegates to `Letflow.Modules.Installs.install/3`. The `prefix` argument
  comes **only** from `conn.assigns.scoped_opts` (set by
  `Letflow.Plugs.Authorize`, itself derived server-side from
  `conn.assigns.auth_context.tenant_id` via
  `Letflow.Api.Context.scoped_repo_opts/1`) — never from the request body,
  path, or query string (INV-1). Any `tenant_id`/`tenant`/`prefix` key
  present in the JSON body is read by nothing in this router and has no
  effect.

  `actor_id` passed to `install/3` is `conn.assigns.auth_context.user_id`
  (the authenticated caller — same source `Letflow.Routers.TenantSettings`
  and `Letflow.Routers.Me` use for identity, never a body field).
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Response
  alias Letflow.Modules.Installs
  alias Letflow.Modules.TenantModule

  authz_post "/", :ModulesManage do
    handle_install(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST /tenant/modules (design §2.3/§2.4) ─────────────────────────────

  @spec handle_install(Plug.Conn.t()) :: Plug.Conn.t()
  defp handle_install(%Plug.Conn{body_params: %{"module_id" => module_id}} = conn)
       when is_binary(module_id) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)
    actor_id = conn.assigns.auth_context.user_id

    case Installs.install(module_id, actor_id, prefix: prefix) do
      {:ok, tenant_module} ->
        Response.created(conn, install_response_map(tenant_module))

      {:error, :unknown_module} ->
        Response.not_found(conn)

      {:error, :already_installed} ->
        Response.conflict(conn, "module already installed")

      {:error, {:dependency_not_installed, dep_id}} ->
        Response.unprocessable(conn, "missing dependency: #{dep_id}")

      {:error, {:pack_install_failed, _reason}} ->
        Response.unprocessable(conn, "module installation failed")

      {:error, {:on_install_failed, _reason}} ->
        Response.unprocessable(conn, "module installation failed")

      {:error, %Ecto.Changeset{} = changeset} ->
        Response.unprocessable(conn, changeset_error_message(changeset))
    end
  end

  defp handle_install(conn) do
    Response.unprocessable(conn, "request body must include a string \"module_id\"")
  end

  @spec install_response_map(TenantModule.t()) :: map()
  defp install_response_map(%TenantModule{} = tenant_module) do
    %{
      "module_id" => tenant_module.module_id,
      "version" => tenant_module.version,
      "installed_at" => DateTime.to_iso8601(tenant_module.installed_at)
    }
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {_field, messages} -> messages end)
    |> case do
      [] -> "validation failed"
      messages -> Enum.join(messages, "; ")
    end
  end
end
