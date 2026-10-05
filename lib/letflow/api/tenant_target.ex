defmodule Letflow.Api.TenantTarget do
  @moduledoc """
  Proves that a tenant identifier a handler received from the REQUEST (path,
  query or body) is the caller's own tenant, or that the caller holds platform
  scope (ISS-0993 design section 8). Pure: no DB, no `Repo`.

  Called by the tenant-naming handlers (`Letflow.Routers.Tenants`,
  `Letflow.Routers.Promotions`) before any lookup of the named tenant.

  Rules, in order:

    1. The caller's recomputed `platform_scope?`
       (`Letflow.PlatformTenant.scope_facts_for/1`; the stored flag is never
       read, a missing `auth_context` or missing keys are fail-closed and never
       raise) -> `:ok`.
    2. `target` is a canonical-UUID string equal, case-insensitively, to the
       caller's `tenant_id` (read with `Map.get/3`, never by dot access) -> `:ok`.
    3. Anything else (`nil`, another tenant's UUID, a malformed id, a slug)
       -> `{:error, :not_found}`.

  The helper never builds a response. A handler maps `{:error, :not_found}` to
  `Letflow.Api.Response.not_found/1`, the SAME zero-detail 404 every existing
  not-found uses, so the bytes equal those of a nonexistent tenant (INV-5). The
  call must happen BEFORE any lookup of the target, so the denied path costs no
  DB round trip and shows no timing difference from a nonexistent id.
  """

  alias Letflow.PlatformTenant

  @spec authorize_target_tenant(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, :not_found}
  def authorize_target_tenant(%Plug.Conn{assigns: assigns}, target) do
    auth_context = Map.get(assigns, :auth_context)

    cond do
      PlatformTenant.scope_facts_for(auth_context).platform_scope? -> :ok
      own_tenant?(auth_context, target) -> :ok
      true -> {:error, :not_found}
    end
  end

  def authorize_target_tenant(_other, _target), do: {:error, :not_found}

  defp own_tenant?(auth_context, target) when is_map(auth_context) and is_binary(target) do
    case Map.get(auth_context, :tenant_id) do
      own when is_binary(own) ->
        PlatformTenant.uuid?(target) and String.downcase(target) == String.downcase(own)

      _other ->
        false
    end
  end

  defp own_tenant?(_auth_context, _target), do: false
end
