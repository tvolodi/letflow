defmodule Letflow.Routers.Tenants do
  @moduledoc """
  Tenant-administration sub-router (REQ-075), mounted at `/tenants` directly
  by `Letflow.Plugs.ApiPipeline` (so full paths under `/api/v1` are
  `/api/v1/tenants`, `/api/v1/tenants/:slug`, etc). **Not** nested under
  `Letflow.Routers.Identity`'s own `/identity` mount — R-Co's own route
  table treats `tenants` as a top-level resource
  (`resource == "tenants"`, `src/main.zig:1489`), a sibling of
  `users`/`groups`/`identity`, not nested under it, and semantically these
  six handlers operate on the platform's tenant registry, categorically
  different from `Letflow.Routers.Identity`'s per-tenant user/group
  management. Ports `src/api/routes/identity.zig`'s `handleCreateTenant`,
  `handleListTenants`, `handleGetTenant`, `handlePatchTenant`,
  `handleDeactivateTenant`, `handleReactivateTenant`. See
  `lib/letflow/design/req075-tenant-administration-routes.md` for the full
  design.

  | Handler     | Method/path                          | Domain fn(s) called                                                                                    | Auth            | Response                    |
  |-------------|---------------------------------------|---------------------------------------------------------------------------------------------------------|-----------------|-----------------------------|
  | create      | `POST /tenants`                       | `Identity.create_tenant/1` -> `TenantProvisioning.provision_tenant_schema/1` -> `TenantProvisioning.replay_migrations/2` | `:TenantsManage` | 201, `tenant_map/1`         |
  | list        | `GET /tenants`                        | `Identity.list_tenants/1`                                                                                | `:TenantsManage` | 200, paginated `tenant_map`  |
  | get         | `GET /tenants/:slug`                  | `Identity.get_tenant_by_slug/1`                                                                          | `:TenantsManage` | 200, `tenant_map/1`         |
  | patch       | `PATCH /tenants/:slug`                | `Identity.get_tenant_by_slug/1` then `Identity.patch_tenant/2`                                           | `:TenantsManage` | 200, `tenant_map/1`         |
  | deactivate  | `POST /tenants/:slug/deactivate`      | `Identity.deactivate_tenant/1`                                                                           | `:TenantsManage` | 200, `tenant_map/1`         |
  | reactivate  | `POST /tenants/:slug/reactivate`      | `Identity.reactivate_tenant/1`                                                                           | `:TenantsManage` | 200, `tenant_map/1`         |

  ## THIS IS THE HIGHEST-RISK ROUTE GROUP IN S4 (AC6)

  These six handlers operate on the global `tenants` table, entirely
  outside REQ-072's per-tenant `:prefix`-scoping mechanism — there is no
  tenant context to scope by, because these handlers decide which tenants
  exist. PLATFORM_ADMIN (via `Authorization.evaluate_access/2`'s
  `:TenantsManage` permission) is the ONLY protection against cross-tenant
  enumeration/reads/writes here. This makes this route group higher-risk
  than every other S4 route: a gating bug elsewhere in S4 leaks at most one
  tenant's own data to that tenant's own misbehaving caller; a gating bug
  here leaks or corrupts every tenant on the platform, because there is no
  second isolation layer (no `:prefix`, no row-level tenant filter) standing
  behind the role check if it fails.

  ## Own-tenant rule (AC3) — no carve-out, ported as-is

  R-Co's `getTenantAdmin`/`patchTenant`/every other handler in this group
  requires `actor.role == PLATFORM_ADMIN` unconditionally, with no
  exception for a caller whose own home tenant happens to be the target —
  reading or patching your own tenant's record through these routes
  requires PLATFORM_ADMIN exactly like reading or patching any other
  tenant's record. This is ported as-is: there is no "manage your own
  tenant" carve-out in this implementation either.

  ## Relationship to REQ-076 (AC7)

  `POST /tenants` (this requirement) and REQ-076's onboarding endpoint are
  two HTTP entry points into the same underlying provisioning primitives
  (`Letflow.TenantProvisioning.provision_tenant_schema/1` +
  `Letflow.TenantProvisioning.replay_migrations/2`) — not two divergent
  tenant-creation code paths. This one is the PLATFORM_ADMIN-driven
  direct-creation path; REQ-076's is the self-service signup path. Both
  must call the same `Letflow.TenantProvisioning` functions; neither
  reimplements schema creation or migration replay itself.

  ## Deactivation-status statement (AC5)

  A tenant with `status: :inactive` rejects a subsequent authenticated
  request from that tenant's own (non-PLATFORM_ADMIN) caller with `403
  tenant_inactive`, checked in `Letflow.Plugs.TenantStatus` before the
  request reaches any sub-router — for every HTTP method, not only writes,
  matching R-Co's own `enforceTenantActiveForOperation`/`isTenantInactive`
  behavior (checked at `src/identity/service.zig:133-151` and
  `src/api/middleware/auth.zig:1663-1674`). PLATFORM_ADMIN callers are
  exempt from this check, also matching R-Co (`service.zig:138`,
  `auth.zig:1663`).

  ## Ordering guarantee (design §6.1)

  Every handler calls `Letflow.Api.Authorization.evaluate_access/2` against
  the endpoint's `:TenantsManage` policy key **before any `Repo` call of any
  kind** — there is no "Step 1 — scoped prefix" here at all (unlike
  `Letflow.Routers.Identity`), because there is no tenant to `:prefix`-scope
  by. A `Deny403` decision returns immediately; no read or write happens on
  that path.

  ## Response allowlist (design §8)

  `tenant_map/1` is a hand-built map with exactly the six keys named in its
  own @doc — never a `Jason.Encoder` derivation over `%Letflow.Identity.Tenant{}`.
  `idp_realm_id` is deliberately excluded (design's own OQ-6, ELIXIR-DEV's
  call, confirmed here: no confirmed precedent from R-Co's `serializeTenant`
  was available to check against, so the allowlist-not-denylist default
  wins — add it explicitly later if a requirement needs it).

  ## Judgment calls confirmed here (design §9)

  * **OQ-2** — re-deactivating an already-`:inactive` tenant (or
    reactivating an already-`:active` one) is a no-op success, not an
    `:invalid_transition` error — confirmed; see
    `Letflow.Identity.deactivate_tenant/1`'s @doc.
  * **OQ-3** — `POST .../deactivate` and `.../reactivate` take no request
    body; `conn.body_params` is ignored on both.
  * **OQ-5** — no compensating rollback if `TenantProvisioning.provision_tenant_schema/1`
    or `TenantProvisioning.replay_migrations/2` fails after the tenant row is
    already committed. Left open per the design's own instruction; a
    caller sees a `500` in that case (`Response.internal_error/1`) and a
    `tenants` row with no matching schema — an operationally recoverable
    partial state, not silently retried or rolled back here.
    Followed up as ISS-0230/GH#468, resolved by scoping the recovery path into
    `REQ-076` (tenant onboarding) rather than building it here. The rollback
    stays absent deliberately — adding one makes the state *worse*, since
    deleting the `tenants` row after `provision_tenant_schema/1` already
    succeeded orphans a real Postgres schema. "Operationally recoverable" is
    now a measured claim rather than an assumption: re-invoking both
    primitives with the same `tenant_id` converges the state, and
    `tenant_schemas.migrations_applied_at IS NULL` identifies affected
    tenants. See `Letflow.TenantProvisioning`'s moduledoc section "No
    reconciliation path for a half-provisioned tenant" for the full
    procedure and the obligation REQ-076 inherits.
  """

  use Plug.Router

  alias Letflow.Api.Authorization
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning

  @tenants_cursor_prefix "T:"

  plug(:match)
  plug(:dispatch)

  post "/" do
    with_authorization(conn, "POST", "/tenants", fn conn ->
      handle_create(conn)
    end)
  end

  get "/" do
    with_authorization(conn, "GET", "/tenants", fn conn ->
      handle_list(conn)
    end)
  end

  get "/:slug" do
    with_authorization(conn, "GET", "/tenants/:slug", fn conn ->
      handle_get(conn, conn.params["slug"])
    end)
  end

  patch "/:slug" do
    with_authorization(conn, "PATCH", "/tenants/:slug", fn conn ->
      handle_patch(conn, conn.params["slug"])
    end)
  end

  post "/:slug/deactivate" do
    with_authorization(conn, "POST", "/tenants/:slug/deactivate", fn conn ->
      handle_deactivate(conn, conn.params["slug"])
    end)
  end

  post "/:slug/reactivate" do
    with_authorization(conn, "POST", "/tenants/:slug/reactivate", fn conn ->
      handle_reactivate(conn, conn.params["slug"])
    end)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── Shared authorization preamble (design §6.1) ─────────────────────────
  #
  # No "Step 1 -- scoped prefix" here (unlike Letflow.Routers.Identity) --
  # that is the load-bearing structural difference this whole router exists
  # to get right. No Repo call of any kind happens before this returns
  # :Allow/:AllowWithRowFilter.
  defp with_authorization(conn, method, path_template, fun) do
    ctx = %Authorization.AccessContext{
      user_id: conn.assigns.auth_context.user_id,
      roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)
    }

    decision =
      Authorization.evaluate_access(ctx, Authorization.endpoint_policy_key(method, path_template))

    case decision.kind do
      :Deny403 -> Response.forbidden(conn, "insufficient permissions")
      _allow_or_allow_with_row_filter -> fun.(conn)
    end
  end

  # ── POST /tenants (design §7.1, AC4, AC7) ───────────────────────────────

  @create_schema [
    %FieldConstraint{
      name: "slug",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "display_name",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "idp_realm_id",
      required: false,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    }
  ]

  defp handle_create(conn) do
    case Validation.validate(@create_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        case Identity.create_tenant(attrs) do
          {:ok, tenant} -> provision_and_respond(conn, tenant)
          {:error, :duplicate_slug} -> Response.conflict(conn, "slug already exists")
          {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
        end
    end
  end

  # OQ-5: no compensating rollback of the just-created tenant row on a
  # provisioning/replay failure -- see moduledoc. Do NOT "fix" this by adding a
  # delete here: it orphans a real Postgres schema (ISS-0230/GH#468). The
  # recovery path is REQ-076's, not this function's.
  defp provision_and_respond(conn, tenant) do
    with {:ok, _registration} <- TenantProvisioning.provision_tenant_schema(tenant.id),
         {:ok, _applied_versions} <- TenantProvisioning.replay_migrations(tenant.id) do
      Response.created(conn, tenant_map(tenant))
    else
      _provisioning_or_replay_error -> Response.internal_error(conn)
    end
  end

  # ── GET /tenants (design §6.2, AC1) ─────────────────────────────────────

  defp handle_list(conn) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, cursor} <- parse_cursor_param(Map.get(query, "cursor")) do
      search = non_empty(Map.get(query, "search"))

      {:ok, %{tenants: tenants, next_cursor: next_cursor}} =
        Identity.list_tenants(%{search: search, cursor: cursor, page_size: page_size})

      page = Pagination.page_response(Enum.map(tenants, &tenant_map/1), next_cursor)
      Response.ok(conn, page)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")
    end
  end

  defp parse_cursor_param(nil), do: {:ok, nil}

  defp parse_cursor_param(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @tenants_cursor_prefix, byte_size(@tenants_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} ->
        {:ok, cursor}

      {:error, _invalid_base64_or_wrong_endpoint_or_expired_or_invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── GET /tenants/:slug (design §6.3) ─────────────────────────────────────

  defp handle_get(conn, slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:ok, tenant} -> Response.ok(conn, tenant_map(tenant))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── PATCH /tenants/:slug (design §6.4) ──────────────────────────────────

  @patch_schema [
    %FieldConstraint{
      name: "display_name",
      required: false,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    }
  ]

  defp handle_patch(conn, slug) do
    case Identity.get_tenant_by_slug(slug) do
      {:error, :not_found} ->
        Response.not_found(conn)

      {:ok, _existing} ->
        case Validation.validate(@patch_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, attrs} ->
            case Identity.patch_tenant(slug, attrs) do
              {:ok, tenant} -> Response.ok(conn, tenant_map(tenant))
              {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
              {:error, :not_found} -> Response.not_found(conn)
            end
        end
    end
  end

  # ── POST /tenants/:slug/deactivate and /reactivate (design §6.5) ───────
  #
  # OQ-3: bodyless -- conn.body_params ignored on both.

  defp handle_deactivate(conn, slug) do
    case Identity.deactivate_tenant(slug) do
      {:ok, tenant} -> Response.ok(conn, tenant_map(tenant))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  defp handle_reactivate(conn, slug) do
    case Identity.reactivate_tenant(slug) do
      {:ok, tenant} -> Response.ok(conn, tenant_map(tenant))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── Response allowlist (design §8) ──────────────────────────────────────

  @doc false
  # Exactly 6 keys, hand-built -- never a Jason.Encoder derivation over the
  # full %Tenant{} struct. `idp_realm_id` is deliberately excluded (OQ-6,
  # see moduledoc).
  @spec tenant_map(Tenant.t()) :: map()
  defp tenant_map(%Tenant{} = tenant) do
    %{
      "id" => tenant.id,
      "slug" => tenant.slug,
      "display_name" => tenant.display_name,
      "status" => Atom.to_string(tenant.status),
      "inserted_at" => iso8601(tenant.inserted_at),
      "updated_at" => iso8601(tenant.updated_at)
    }
  end

  # Matches Letflow.Routers.Identity's own user_map/1 convention exactly
  # (ISO 8601 via DateTime.to_iso8601/1 over the NaiveDateTime-as-UTC
  # assumption already established elsewhere in this codebase).
  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
