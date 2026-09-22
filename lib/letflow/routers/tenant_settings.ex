defmodule Letflow.Routers.TenantSettings do
  @moduledoc """
  REQ-382 — the first HTTP-reachable write path onto `tenants.settings`.
  Mounted at `/tenant/settings` by `Letflow.Plugs.ApiPipeline` (full path
  `PATCH /api/v1/tenant/settings`). See
  `lib/letflow/design/req382-tenant-branding-write-path.md` for the full
  design.

  One route: `PATCH /` (full path `/tenant/settings`), gated by the existing
  `:TenantsManage` permission (`PLATFORM_ADMIN`-only — see design §1 for why
  this reuses that permission rather than minting a new one). Unlike
  `Letflow.Routers.Tenants`, there is **no target-tenant path parameter** —
  the tenant patched is always the caller's own, from
  `conn.assigns.auth_context.tenant_id` (design §1's "difference from
  `Tenants`" note).

  Delegates to `Letflow.Identity.update_tenant_settings/2` exactly as it
  exists today (its own casting discipline, `Tenant.settings_changeset/2`'s
  cast list, and `Letflow.Identity.TenantSettings`'s closed key vocabulary
  are all unchanged by this router). This router's own job is: (1) resolve
  the caller's tenant, (2) shallow-merge the request's recognized top-level
  keys onto the tenant's current settings so a partial PATCH does not erase
  previously-set keys it did not mention (design §3 step 5), (3) record a
  rejected out-of-scope key (or `brand_colors` sub-key) as one
  `Letflow.Audit` entry without failing the rest of the request (design §4).
  """

  use Letflow.Api.AuthorizedRouter

  require Logger

  alias Letflow.Api.Response
  alias Letflow.Audit
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantSettings

  authz_patch "/", :TenantsManage do
    handle_patch(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── PATCH /tenant/settings (design §3) ──────────────────────────────────

  defp handle_patch(%Plug.Conn{body_params: raw} = conn) when is_map(raw) do
    tenant_id = conn.assigns.auth_context.tenant_id

    case Identity.get_tenant(tenant_id) do
      {:ok, tenant} -> patch_tenant_settings(conn, tenant, raw)
      # Structurally not realistically reachable for a token that already
      # passed AuthPipeline/Authorize (design §3 step 2 — same defensive
      # shape as Letflow.Routers.Tenants.handle_promote/3), still handled.
      {:error, :not_found} -> Response.internal_error(conn)
    end
  end

  defp handle_patch(conn) do
    Response.unprocessable(conn, "request body must be a JSON object")
  end

  defp patch_tenant_settings(conn, %Tenant{} = tenant, raw) do
    {recognized_top, rejected_top_keys} = partition_top_level(raw)
    {recognized_top, rejected_brand_colors_keys} = partition_brand_colors(recognized_top)

    merged_settings = Map.merge(tenant.settings || %{}, recognized_top)

    case Identity.update_tenant_settings(tenant.slug, %{"settings" => merged_settings}) do
      {:ok, updated_tenant} ->
        maybe_record_rejected_keys(
          conn,
          tenant,
          raw,
          rejected_top_keys,
          rejected_brand_colors_keys
        )

        Response.ok(conn, settings_response_map(tenant, updated_tenant))

      {:error, :not_found} ->
        Response.internal_error(conn)

      {:error, %Ecto.Changeset{} = changeset} ->
        # AC2's "plain-language message the caller can surface verbatim" — no
        # audit write on this path: a value-validation failure (e.g. a
        # WCAG-failing color) is a full-request rejection, not the
        # out-of-scope-*key* rejection AC4's audit obligation is scoped to
        # (design §3 step 7).
        Response.unprocessable(conn, changeset_error_message(changeset))
    end
  end

  @spec partition_top_level(map()) :: {map(), [String.t()]}
  defp partition_top_level(raw) do
    allowed_keys = TenantSettings.allowed_keys()
    recognized_top = Map.take(raw, allowed_keys)
    rejected_top_keys = Map.keys(raw) -- allowed_keys
    {recognized_top, rejected_top_keys}
  end

  @spec partition_brand_colors(map()) :: {map(), [String.t()]}
  defp partition_brand_colors(%{"brand_colors" => brand_colors} = recognized_top)
       when is_map(brand_colors) do
    allowed_keys = Tenant.brand_colors_allowed_keys()
    recognized_brand_colors = Map.take(brand_colors, allowed_keys)
    rejected_brand_colors_keys = Map.keys(brand_colors) -- allowed_keys

    {Map.put(recognized_top, "brand_colors", recognized_brand_colors), rejected_brand_colors_keys}
  end

  # `brand_colors` absent, or present-but-not-a-map (left untouched — the
  # existing "brand_colors must be a map" changeset error fires downstream
  # unchanged; this is not a key-rejection case, design §3 step 4).
  defp partition_brand_colors(recognized_top), do: {recognized_top, []}

  defp maybe_record_rejected_keys(_conn, _tenant, _raw, [], []), do: :ok

  defp maybe_record_rejected_keys(
         conn,
         %Tenant{} = tenant,
         raw,
         rejected_top_keys,
         rejected_brand_colors_keys
       ) do
    prefix = Keyword.fetch!(conn.assigns.scoped_opts, :prefix)

    attrs = %{
      actor_id: conn.assigns.auth_context.user_id,
      action: "tenant_settings.reject_unrecognized_keys",
      resource_type: "tenant_settings",
      resource_id: tenant.id,
      before_state: nil,
      after_state: %{
        "rejected_top_level_keys" => Map.take(raw, rejected_top_keys),
        "rejected_brand_colors_keys" =>
          Map.take(raw["brand_colors"] || %{}, rejected_brand_colors_keys)
      },
      trace_id: conn.assigns[:trace_id]
    }

    case Audit.insert_entry(Letflow.Repo, attrs, prefix) do
      {:ok, _entry} ->
        :ok

      {:error, reason} ->
        # INV-4: never the raw exception/reason term if it could carry
        # connection/query text -- name only the tenant id and a bounded
        # description. Does NOT fail the HTTP response (design §3 step 9a) --
        # the settings mutation the caller asked for already committed and
        # must not appear to have failed because of an unrelated audit-write
        # hiccup.
        Logger.error(
          "tenant_settings.reject_unrecognized_keys audit write failed " <>
            "(tenant_id=#{tenant.id}): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.get(:settings, ["validation failed"])
    |> Enum.join("; ")
  end

  @spec settings_response_map(Tenant.t(), Tenant.t()) :: map()
  defp settings_response_map(%Tenant{} = tenant, %Tenant{} = updated_tenant) do
    %{"tenant_id" => tenant.id, "settings" => updated_tenant.settings || %{}}
  end
end
