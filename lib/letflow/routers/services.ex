defmodule Letflow.Routers.Services do
  @moduledoc """
  Non-admin service-catalog sub-router (REQ-192, design
  `lib/letflow/design/req192-service-catalog-routes.md`). Mounted at
  `/services` by `Letflow.Plugs.ApiPipeline`, so the one full path under
  `/api/v1` is `GET /api/v1/services` — matching
  `web/src/api/services.ts`'s `servicesApi.listForTenant` call exactly.
  Route/controller layer only, atop REQ-191's already-shipped
  `Letflow.ServiceCatalog` context module — no change to that module,
  `Letflow.ServiceCatalog.Entry`, or the `service_catalog` migration.

  ## Contract source (design §0)

  PROVENANCE (historical, not current decision authority):
  R-Co's `src/api/routes/services.zig` (417 lines) has five handlers —
  `handleListServices` (L27), `handleAdminListServices` (L62),
  `handleAdminRegisterService` (L93), `handleAdminUpdateService` (L175),
  `handleAdminDeleteService` (L233) — matching the five routes across this
  router and `Letflow.Routers.AdminServices` one-for-one. The binding
  contract actually consulted while drafting this route layer is the
  already-shipped SPA consumer, `web/src/api/services.ts`'s `servicesApi`
  object and `web/src/types/api.ts`'s `ServiceRecord`/`RegisterServiceBody`/
  `UpdateServiceScopeBody` types, and the two agree — R-Co's route shape is
  corroborating evidence, not itself re-verified line by line against a live
  R-Co checkout.

  ## Two routers, one per mount prefix (design §1)

  `GET /services` and `Letflow.Routers.AdminServices`'s four
  `/admin/services...` routes need two different full external paths to
  match `Letflow.Api.Authorization.endpoint_policy_key/2`'s already-shipped
  clauses, and `test/letflow/api/authorization_enforcement_test.exs`'s
  `@mount_prefix` mechanism is strictly one-router-to-one-mount-prefix — so
  this is a separate router module from `Letflow.Routers.AdminServices`,
  not a single router mounted twice, matching `Letflow.Routers.Dlq`/
  `Letflow.Routers.Webhooks`'s own one-router-per-mount-prefix precedent.

  ## Authorization (REQ-069, REQ-131)

  The one route below is declared via `authz_get`
  (`Letflow.Api.AuthorizedRouter`) with the already-shipped `:ServicesRead`
  policy key. `Letflow.Api.Authorization.endpoint_policy_key/2` already maps
  `GET "/services"` to it, and `required_permission(:ServicesRead)` already
  maps to `:DefinitionsRead` — held by every role except `:AGENT_RUNNER`
  (design §3), so any authenticated non-agent caller may list. No new
  `endpoint_policy_key`/`required_permission` clause, no new permission
  atom — `lib/letflow/api/authorization.ex` is not modified by this
  requirement.

  ## Tenant scoping (design §4)

  Tenant id comes from `conn.assigns.auth_context.tenant_id` (REQ-072,
  already populated by `Letflow.Plugs.AuthPipeline` before this router
  runs) — **not** `conn.assigns.scoped_opts`, since `service_catalog` is a
  global table with no `[prefix: schema]` concept
  (`Letflow.ServiceCatalog`'s own moduledoc, "No `opts[:prefix]` on any
  function" section).

  `Letflow.ServiceCatalog.list_for_tenant/2`'s own visibility rule (every
  `scope: :global` row plus this tenant's own `scope: :tenant` rows) is
  exactly this route's cross-tenant-non-disclosure requirement (AC1/AC7,
  REQ-072) — a tenant-scoped entry owned by a different tenant is simply
  absent from the page; there is no single-item `GET /services/:service_id`
  route in this requirement to build a 404-vs-403 branch for (design §10).

  ## Response allowlist (INV-2)

  `service_record_json/1` is a hand-built allowlist over
  `Letflow.ServiceCatalog.Entry` fields — never a raw `Jason.Encoder`
  derivation over the Ecto struct, matching `Letflow.Routers.Dlq.dlq_entry_json/1`'s
  own precedent. Two real `ServiceRecord`/`Entry` contract gaps (design §8,
  carried forward from the design's own findings, not silently resolved
  here):

    * `max_retries` has no backing `Entry` column and no `register_attrs()`
      key — omitted from the output entirely, following
      `Letflow.Routers.Dlq`'s own already-reviewer-accepted precedent for
      exactly this situation.
    * `request_schema`/`response_schema` are non-nullable in the TS type but
      nullable on `Entry` — the router serializes the true column value,
      `null` included, rather than inventing a fallback (e.g. `""`) that
      would misrepresent "no schema was supplied".

  The list body is an exactly-two-key map, `%{"items" => ..., "next_cursor"
  => ...}`, matching `Letflow.Routers.Dlq`'s own documented divergence from
  the full `CursorPage<T>` shape.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry

  authz_get "/", :ServicesRead do
    handle_list(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /services (design §4) ─────────────────────────────────────────────

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        cursor: non_empty(Map.get(query, "cursor")),
        page_size: page_size
      }

      tenant_id = conn.assigns.auth_context.tenant_id

      params
      |> ServiceCatalog.list_for_tenant(tenant_id)
      |> handle_list_result(conn)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  defp handle_list_result({:ok, %{items: items, next_cursor: next_cursor}}, conn) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &service_record_json/1),
      "next_cursor" => next_cursor
    })
  end

  defp handle_list_result({:error, reason}, conn)
       when reason in [:invalid_cursor, :wrong_endpoint, :expired] do
    Response.bad_request(conn, "invalid cursor")
  end

  # ── Query-param parsing helpers ───────────────────────────────────────────

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Response allowlist (INV-2, design §7/§8) ──────────────────────────────

  @spec service_record_json(Entry.t()) :: map()
  defp service_record_json(%Entry{} = entry) do
    %{
      "service_id" => entry.service_id,
      "endpoint_url" => entry.endpoint_url,
      "request_schema" => entry.request_schema,
      "response_schema" => entry.response_schema,
      "required_auth" => Atom.to_string(entry.required_auth),
      "timeout_ms" => entry.timeout_ms,
      "scope" => Atom.to_string(entry.scope),
      "owner_tenant_id" => entry.owner_tenant_id,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "updated_at" => DateTime.to_iso8601(entry.updated_at)
    }
  end
end
