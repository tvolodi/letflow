defmodule Letflow.Routers.AdminServices do
  @moduledoc """
  Admin service-catalog sub-router (REQ-192, design
  `lib/letflow/design/req192-service-catalog-routes.md`). Mounted at
  `/admin/services` by `Letflow.Plugs.ApiPipeline`, so the full paths under
  `/api/v1` are `GET /api/v1/admin/services`, `POST /api/v1/admin/services`,
  `PATCH /api/v1/admin/services/:service_id`, and
  `DELETE /api/v1/admin/services/:service_id` — matching
  `web/src/api/services.ts`'s `servicesApi.listAll`/`register`/
  `updateScope`/`delete` calls exactly. Route/controller layer only, atop
  REQ-191's already-shipped `Letflow.ServiceCatalog` context module — no
  change to that module, `Letflow.ServiceCatalog.Entry`, or the
  `service_catalog` migration.

  ## Contract source

  See `Letflow.Routers.Services`'s moduledoc §0 — the same statement applies
  verbatim to this router's four routes.

  ## Two routers, one per mount prefix

  See `Letflow.Routers.Services`'s moduledoc — this router is deliberately
  separate from it (not a single router mounted at two prefixes), matching
  `test/letflow/api/authorization_enforcement_test.exs`'s strict
  one-router-to-one-mount-prefix `@mount_prefix` mechanism.

  ## Authorization (REQ-069, REQ-131)

  `GET /` is declared with the already-shipped `:AdminServicesRead` policy
  key; `POST /`, `PATCH /:service_id`, `DELETE /:service_id` are each
  declared with the already-shipped `:AdminServicesManage` policy key.
  `Letflow.Api.Authorization.endpoint_policy_key/2` already maps
  `GET "/admin/services"` to `:AdminServicesRead` and any `POST`/`PATCH`/
  `DELETE` on a path starting with `"/admin/services"` to
  `:AdminServicesManage`; `required_permission/1` already maps both keys to
  `:UsersGroupsRolesManage`, held only by `:PLATFORM_ADMIN` (that role's own
  `role_allows?/2` catch-all clause) — no other role holds it, so a caller
  with only `:ServicesRead` (or any non-`PLATFORM_ADMIN` role) gets `403`
  before any handler below runs. No new `endpoint_policy_key`/
  `required_permission` clause, no new permission atom —
  `lib/letflow/api/authorization.ex` is not modified by this requirement.

  `required_permission/1`'s own comment above this clause
  (`# platform-admin enforced in handler, per Zig's comment`) is stale — no
  handler-level `PLATFORM_ADMIN`-only check exists anywhere in this router;
  the `:UsersGroupsRolesManage` permission mapping alone is what restricts
  these two policy keys to `PLATFORM_ADMIN`. This router does not add a
  second, handler-side gate (unnecessary, and out of this requirement's
  scope) — flagged for REVIEWER to decide whether the comment itself should
  be corrected in a future, `authorization.ex`-scoped requirement (design
  §3).

  ## `GET /` — no backing "list all" function (design §5, layering exception
  ## FLAGGED FOR REVIEWER SIGN-OFF, not pre-approved)

  `Letflow.ServiceCatalog` exposes no tenant-independent "list every row"
  function, and adding one is out of this requirement's scope. This
  handler therefore queries `Letflow.ServiceCatalog.Entry` **directly** via
  `Letflow.Repo`/`Ecto.Query`, bypassing the context module — a genuine
  first-of-its-kind exception to this codebase's router -> context-module
  layering discipline (every other router, including
  `Letflow.Routers.Audit` and `Letflow.Routers.Metrics`, delegates to a
  context-module function). This is deliberate, not an oversight: reuses
  `Letflow.ServiceCatalog.list_for_tenant/2`'s exact keyset shape
  (`order_by: [desc: created_at, desc: service_id]`, `limit(page_size + 1)`,
  drop-the-extra-row split) with **no** `where` clause, under its own cursor
  prefix `"SCA:"` (distinct from `ServiceCatalog`'s own `"SC:"`, so a cursor
  minted by one endpoint is rejected — `{:error, :wrong_endpoint}` — if
  replayed against the other, per `Letflow.Api.Pagination`'s INV-9
  cross-endpoint isolation).

  **REVIEWER must independently evaluate and sign off on this exception at
  Step 2d — it is not to be treated as routine or pre-approved by analogy to
  anything already in the codebase.** Also named as a related finding for
  REVIEWER: this duplicates `list_for_tenant/2`'s keyset-pagination shape at
  the router layer; a future, `service_catalog.ex`-scoped requirement should
  consider hoisting a shared, tenant-agnostic list-all function into the
  context module and retiring this duplication (design §5, OQ-1). Neither
  point is resolved here — both are named, not silently accepted as
  permanent.

  ## `auth_method` -> `:required_auth` translation (design §6)

  `RegisterServiceBody`'s own field is named `auth_method`, while
  `ServiceRecord`'s corresponding output field (and `Entry`'s column, and
  `register_attrs()`'s key) is `required_auth` — this asymmetry already
  exists in the frozen `web/src/api/services.ts` wire contract; this
  router's job is exactly to bridge it, the same way every other POST
  handler in this codebase translates a JSON body into a context module's
  expected attrs map. `max_retries` (in `RegisterServiceBody`) has no
  `register_attrs()` key and is dropped, never passed through (design §8
  finding 1).

  ## 409 problem-details bodies (REQ-066, design §11)

  Two new `Letflow.Api.Error` constructors,
  `service_referenced_by_active_definitions/1` (delete-blocked) and
  `service_scope_narrowing_conflict/1` (narrow-blocked), modeled on the
  existing `Error.promotion_conflict/2`'s real RFC 9457 extensions-map
  shape. A duplicate `service_id` on register maps to plain
  `Response.conflict/2` instead (no structured extension needed — there is
  nothing to list beyond the one conflicting id already named in the
  request body).

  ## Cross-tenant-404 (design §10)

  None of the four routes here is tenant-filtered — every row is visible
  regardless of the caller's own tenant, by design (that is exactly what
  distinguishes this admin surface from `Letflow.Routers.Services`). A 404
  on `PATCH`/`DELETE` here means only "no such `service_id` exists at all",
  never a disguised cross-tenant-ownership check — REQ-072's
  cross-tenant-non-disclosure rule applies to the non-admin list endpoint
  instead (`Letflow.Routers.Services`), which is the only place a
  tenant-visibility distinction exists in this route set.
  """

  use Letflow.Api.AuthorizedRouter

  import Ecto.Query

  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Repo
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry

  # Distinct from ServiceCatalog's own "SC:" -- Pagination.decode_cursor/3's
  # whole point is cross-endpoint cursor isolation (INV-9), so a cursor
  # minted by GET /services must be rejected if replayed against
  # GET /admin/services and vice versa (design §5).
  @list_cursor_prefix "SCA:"

  authz_get "/", :AdminServicesRead do
    handle_list(conn)
  end

  authz_post "/", :AdminServicesManage do
    handle_register(conn)
  end

  authz_patch "/:service_id", :AdminServicesManage do
    handle_update_scope(conn, conn.params["service_id"])
  end

  authz_delete "/:service_id", :AdminServicesManage do
    handle_delete(conn, conn.params["service_id"])
  end

  match _ do
    Response.not_found(conn)
  end

  # ── GET /admin/services (design §5) ───────────────────────────────────────
  #
  # Deliberate, flagged layering exception -- see moduledoc. Queries
  # Letflow.ServiceCatalog.Entry directly, with no `where` clause restricting
  # scope or owner, so every row is visible regardless of tenant.

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      params = %{
        cursor: non_empty(Map.get(query, "cursor")),
        page_size: page_size
      }

      params
      |> list_all()
      |> handle_list_result(conn)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  @spec list_all(%{cursor: String.t() | nil, page_size: pos_integer()}) ::
          {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp list_all(params) do
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        Entry
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([e], desc: e.created_at, desc: e.service_id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query)
      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {created_at_us, service_id}) do
    ts = DateTime.from_unix!(created_at_us, :microsecond)
    from(e in query, where: {e.created_at, e.service_id} < {^ts, ^service_id})
  end

  @spec decode_list_cursor(String.t() | nil) ::
          {:ok, {non_neg_integer(), String.t()} | nil}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @list_cursor_prefix, byte_size(@list_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  defp decode_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [ts_str, service_id] = String.split(rest, ":", parts: 2)
    {String.to_integer(ts_str), service_id}
  end

  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor(%Entry{service_id: service_id, created_at: created_at}) do
    created_at_us = DateTime.to_unix(created_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(created_at_us, service_id)
    |> Pagination.encode_cursor()
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

  # ── POST /admin/services (design §6) ──────────────────────────────────────

  defp handle_register(conn) do
    with {:ok, body} <- object_body(conn) do
      attrs =
        %{}
        |> maybe_put(body, "service_id", :service_id)
        |> maybe_put(body, "endpoint_url", :endpoint_url)
        |> maybe_put(body, "scope", :scope)
        |> maybe_put(body, "owner_tenant_id", :owner_tenant_id)
        |> maybe_put(body, "auth_method", :required_auth)
        |> maybe_put(body, "timeout_ms", :timeout_ms)
        |> maybe_put(body, "request_schema", :request_schema)
        |> maybe_put(body, "response_schema", :response_schema)

      case ServiceCatalog.register(attrs) do
        {:ok, entry} ->
          Response.created(conn, service_record_json(entry))

        {:error, :tenant_not_found} ->
          Response.unprocessable(conn, "owner_tenant_id does not name an existing tenant")

        {:error, :duplicate_service_id} ->
          Response.conflict(conn, "service_id already registered")

        {:error, %Ecto.Changeset{}} ->
          Response.unprocessable(conn, "validation failed")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  # ── PATCH /admin/services/:service_id (design §9) ─────────────────────────

  defp handle_update_scope(conn, service_id) do
    with {:ok, body} <- object_body(conn) do
      attrs =
        %{}
        |> maybe_put(body, "scope", :scope)
        |> maybe_put(body, "owner_tenant_id", :owner_tenant_id)

      case ServiceCatalog.update_scope(service_id, attrs) do
        {:ok, entry} ->
          Response.ok(conn, service_record_json(entry))

        {:error, :not_found} ->
          Response.not_found(conn)

        {:error, {:referenced_by_active_definitions, conflicts}} ->
          Response.send_problem(conn, Error.service_scope_narrowing_conflict(conflicts))

        {:error, %Ecto.Changeset{}} ->
          Response.unprocessable(conn, "validation failed")
      end
    else
      {:error, :malformed_json} ->
        Response.bad_request(conn, "request body must be a JSON object")
    end
  end

  # ── DELETE /admin/services/:service_id (design §12) ───────────────────────

  defp handle_delete(conn, service_id) do
    case ServiceCatalog.delete(service_id) do
      :ok ->
        Response.no_content(conn)

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, {:referenced_by_active_definitions, definition_ids}} ->
        Response.send_problem(
          conn,
          Error.service_referenced_by_active_definitions(definition_ids)
        )
    end
  end

  # ── Request-body helpers ───────────────────────────────────────────────────

  defp object_body(conn) do
    case conn.body_params do
      %{"_json" => _non_object} -> {:error, :malformed_json}
      body when is_map(body) -> {:ok, body}
      _other -> {:error, :malformed_json}
    end
  end

  defp maybe_put(attrs, body, body_key, attrs_key) do
    case Map.fetch(body, body_key) do
      {:ok, value} -> Map.put(attrs, attrs_key, value)
      :error -> attrs
    end
  end

  # ── Query-param parsing helpers ───────────────────────────────────────────

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Response allowlist (INV-2, design §7/§8) ──────────────────────────────
  #
  # Duplicated from Letflow.Routers.Services rather than shared -- matching
  # this codebase's one-router-per-mount-prefix precedent of each router
  # owning its own private response-allowlist function (dlq.ex/webhooks.ex),
  # not introducing a cross-router dependency the design does not call for.

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
