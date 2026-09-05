defmodule Letflow.Routers.Identity do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Identity user-CRUD sub-router (REQ-073), extended by REQ-074 with
  group-management and group-membership routes, mounted at `/identity` by
  `Letflow.Plugs.ApiPipeline` (so full paths under `/api/v1` are
  `/api/v1/identity/users`, `/api/v1/identity/groups`, etc). Ports
  `src/api/routes/identity.zig`'s `handleCreateUser`, `handleListUsers`,
  `handleGetUser`, `handlePatchUser`, `handleUpdateUserStatus` (REQ-073), and
  `handleCreateGroup`, `handleAddGroupMember`, `handleListGroups`,
  `handleDeleteGroup`, `handleListGroupMembersArray`/`handleListGroupMembers`,
  `handleRemoveGroupMember` (REQ-074). See
  `lib/letflow/design/req073-identity-user-routes.md` and
  `lib/letflow/design/req074-identity-group-routes.md` for the full designs.

  Every route below is deliberately thin — scoped-prefix resolution,
  authorization, request validation, and a response-shape allowlist, with all
  actual persistence delegated to `Letflow.Identity`:

  * POST   /users                        -> Identity.create_user/2
  * GET    /users                        -> Identity.list_users/2
  * GET    /users/:id                    -> Identity.get_user/2
  * PATCH  /users/:id                    -> Identity.get_user/2, then Identity.update_user_profile/3
  * POST   /users/:id/status             -> Identity.get_user/2, then Identity.update_user_status/3
  * POST   /groups                       -> Identity.create_group/2
  * GET    /groups                       -> Identity.list_groups/1
  * DELETE /groups/:id                   -> Identity.delete_group/2
  * POST   /groups/:id/members           -> Identity.add_group_member/3
  * GET    /groups/:id/members           -> Identity.list_group_members/3 (cursor-paginated — see "Group member listing" below)
  * DELETE /groups/:id/members/:user_id  -> Identity.remove_group_member/3
  * POST   /tokens                       -> Identity.create_token/3 (REQ-076)
  * GET    /tokens                       -> Identity.list_tokens/2 (REQ-076)
  * DELETE /tokens/:id                   -> Identity.revoke_token/2 (REQ-076)
  * GET    /roles                        -> Letflow.Identity.RoleRegistry.list_roles/0 (REQ-076)
  * POST   /roles                        -> Letflow.Identity.RoleRegistry.upsert_role/2 (REQ-076)

  ## API tokens (REQ-076, INV-4)

  `POST /tokens` is the **only** handler in this module that ever puts a token
  plaintext into a response body (`token_created_map/2`) — never re-derivable
  from a persisted row, since the row never holds the plaintext at all
  (`Letflow.Identity.ApiToken`'s own moduledoc). `GET /tokens` and `DELETE
  /tokens/:id` both respond with `token_map/1`, which structurally excludes
  `token_hash` and has no parameter through which a plaintext could ever reach
  it. See `lib/letflow/design/req076-identity-tokens-roles-onboarding.md` §6
  for the full design.

  ## Role registry constraint (REQ-076 AC6)

  PROVENANCE (historical, not current decision authority):
  `POST /roles`'s `name` field accepts any role name, not restricted to a
  closed enum (R-Co's `src/identity/role_registry.zig` validates only the
  same format constraint, never enum membership, confirmed by direct
  read). `Letflow.Identity.RoleRegistry.upsert_role/2` (REQ-020,
  unchanged by this requirement) already enforces exactly a **format**
  constraint (non-empty, ≤128 Unicode codepoints, no ASCII control
  characters), never enum membership, and this route adds no stricter
  check on top of it. `POST /roles` returns **200**, not 201 — an upsert,
  not strictly a create, so the response code reflects that update
  semantic rather than resource-creation semantics (design doc §10 OQ-5 —
  deliberate, not a status-code bug).

  ## Group member listing: one served endpoint, not two (REQ-074 AC6)

  PROVENANCE (historical, not current decision authority):
  R-Co defines two member-listing handlers: `handleListGroupMembersArray`
  (bare JSON array, fixed `page_size: 200`, no cursor — the one actually
  wired to `GET /groups/:id/members` at `main.zig:1393`) and
  `handleListGroupMembers` (cursor-paginated, `identity.zig:526` —
  `grep -n "handleListGroupMembers(" src/main.zig` has **zero** route-table
  hits; it is exercised only by `identity.zig`'s own unit tests, never
  reachable through any HTTP route R-Co actually serves). This module ports
  **one** endpoint, `GET /groups/:id/members`, using the cursor-paginated
  *mechanism* R-Co built but never routed — not the served bare-array
  shape — because REQ-074's own AC4 requires cursor pagination across at
  least two pages, which the served array shape cannot satisfy. Same
  divergence shape REQ-073 already made for `list_users/2` replacing R-Co's
  offset pagination.

  PROVENANCE (historical, not current decision authority):
  This port also does **not** carry forward `handleListGroupMembers`'s
  R-Co-only `PLATFORM_ADMIN`-exclusive gate (`identity.zig:533`) — this
  route is gated by the same shared `:GroupsManage` policy as every other
  group route, not a handler-local role literal. Flagged as OQ-3 for
  REVIEWER: this is a real behavioral narrowing versus that unrouted-but-real
  stricter gate, not an accidental relaxation.

  ## Group member removal: single-member, not R-Co's live bulk-remove-all (REQ-074 AC6)

  PROVENANCE (historical, not current decision authority):
  `handleRemoveGroupMember` (single `(group_id, user_id)` removal,
  `identity.zig:551`) is also unrouted in R-Co's route table —
  `grep -n "handleRemoveGroupMember" src/main.zig` has zero hits. What
  R-Co's route table actually serves at its bodyless `DELETE
  /groups/:id/members` is an **inline bulk remove-all-members** operation
  (`main.zig:1400-1430`): list up to 200 members, then call
  `removeGroupMember` once per member, silently swallowing (`catch {}`) any
  per-member error — a materially different, higher-blast-radius operation
  from single-member removal.

  This module ports `handleRemoveGroupMember`'s single-member semantics at
  `DELETE /groups/:id/members/:user_id` instead — a route R-Co's route
  table never actually binds to that handler, but whose path shape is implied by
  the handler's own `(group_id, user_id)` signature and is the only
  sensible single-member REST verb; no acceptance criterion here names bulk
  removal. Flagged as **OQ-1** for REVIEWER: whether single-member removal
  is the right port target given R-Co's live route does something else
  entirely, or whether the bulk-remove-all behavior should also be ported
  (additionally, at the bodyless path) — not resolved here.

  ## Ordering guarantee (AC4/design §3)

  As of REQ-131, this is enforced by `Letflow.Plugs.Authorize`
  (`use Letflow.Api.AuthorizedRouter`), not by a route-local helper: every
  route resolves `Letflow.Api.Context.scoped_repo_opts/1` first, then calls
  `Letflow.Api.Authorization.evaluate_access/2` against the route's own
  declared policy key (`:UsersManage` for `/users*`, `:GroupsManage` for
  `/groups*`) — **before any `Repo` call of any kind**, including every
  pre-fetch read. A `Deny403` decision returns immediately; no read or write
  happens on that path, and no handler in this module runs.

  ## Response allowlist (AC5, INV-2)

  `user_map/1` is a hand-built map with exactly the eight keys named in its
  own @doc — never a `Jason.Encoder` derivation over `%Letflow.Identity.User{}`
  — so `password_hash`, `external_id`, and `external_realm` can never leak
  through this module regardless of what the schema later grows. `group_map/1`
  (REQ-074) is the same hand-built-map discipline for `%Letflow.Identity.Group{}`.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Identity
  alias Letflow.Identity.RoleRegistry

  @users_cursor_prefix "U:"

  authz_post "/users", :UsersManage do
    handle_create(conn, conn.assigns.scoped_opts)
  end

  authz_get "/users", :UsersManage do
    handle_list(conn, conn.assigns.scoped_opts)
  end

  authz_get "/users/:id", :UsersManage do
    handle_get(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_patch "/users/:id", :UsersManage do
    handle_patch(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/users/:id/status", :UsersManage do
    handle_status_update(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/groups", :GroupsManage do
    handle_create_group(conn, conn.assigns.scoped_opts)
  end

  authz_get "/groups", :GroupsManage do
    handle_list_groups(conn, conn.assigns.scoped_opts)
  end

  authz_delete "/groups/:id", :GroupsManage do
    handle_delete_group(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/groups/:id/members", :GroupsManage do
    handle_add_member(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_get "/groups/:id/members", :GroupsManage do
    handle_list_group_members(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_delete "/groups/:id/members/:user_id", :GroupsManage do
    handle_remove_member(
      conn,
      conn.params["id"],
      conn.params["user_id"],
      conn.assigns.scoped_opts
    )
  end

  authz_post "/tokens", :TokensManage do
    handle_create_token(conn, conn.assigns.scoped_opts)
  end

  authz_get "/tokens", :TokensManage do
    handle_list_tokens(conn, conn.assigns.scoped_opts)
  end

  authz_delete "/tokens/:id", :TokensManage do
    handle_revoke_token(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_get "/roles", :RolesManage do
    handle_list_roles(conn)
  end

  authz_post "/roles", :RolesManage do
    handle_upsert_role(conn)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── POST /users (design §2.1) ───────────────────────────────────────────

  @create_schema [
    %FieldConstraint{
      name: "username",
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
      name: "email",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "status",
      required: false,
      type: :string,
      allowed_values: ["active", "inactive"]
    }
  ]

  defp handle_create(conn, opts) do
    case Validation.validate(@create_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        case Identity.create_user(attrs, opts) do
          {:ok, user} -> Response.created(conn, user_map(user))
          {:error, :duplicate_username} -> Response.conflict(conn, "username already exists")
          {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
        end
    end
  end

  # ── GET /users (design §2.2) ────────────────────────────────────────────

  defp handle_list(conn, opts) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, status} <- parse_status_param(Map.get(query, "status")),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, cursor} <- parse_cursor_param(Map.get(query, "cursor")) do
      search = non_empty(Map.get(query, "search"))

      {:ok, %{users: users, next_cursor: next_cursor}} =
        Identity.list_users(
          %{search: search, status: status, cursor: cursor, page_size: page_size},
          opts
        )

      page = Pagination.page_response(Enum.map(users, &user_map/1), next_cursor)
      Response.ok(conn, page)
    else
      {:error, :status_invalid} ->
        Response.unprocessable(conn, "status_invalid")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")
    end
  end

  defp parse_status_param(nil), do: {:ok, nil}
  defp parse_status_param("active"), do: {:ok, :active}
  defp parse_status_param("inactive"), do: {:ok, :inactive}
  defp parse_status_param(_other), do: {:error, :status_invalid}

  defp parse_cursor_param(nil), do: {:ok, nil}

  defp parse_cursor_param(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @users_cursor_prefix, byte_size(@users_cursor_prefix)) do
      {:ok, %Pagination.Cursor{} = cursor} ->
        {:ok, cursor}

      {:error, _invalid_base64_or_wrong_endpoint_or_expired_or_invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── GET /users/:id (design §2.3) ────────────────────────────────────────

  defp handle_get(conn, id, opts) do
    case Identity.get_user(id, opts) do
      {:ok, user} -> Response.ok(conn, user_map(user))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── PATCH /users/:id (design §2.4) ──────────────────────────────────────

  @patch_schema [
    %FieldConstraint{
      name: "display_name",
      required: false,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "email",
      required: false,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "status",
      required: false,
      type: :string,
      allowed_values: ["active", "inactive"]
    }
  ]

  defp handle_patch(conn, id, opts) do
    case Identity.get_user(id, opts) do
      {:error, :not_found} ->
        Response.not_found(conn)

      {:ok, _existing} ->
        case Validation.validate(@patch_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, attrs} ->
            case Identity.update_user_profile(id, attrs, opts) do
              {:ok, user} -> Response.ok(conn, user_map(user))
              {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
              {:error, :not_found} -> Response.not_found(conn)
            end
        end
    end
  end

  # ── POST /users/:id/status (design §2.5) ────────────────────────────────

  @status_schema [
    %FieldConstraint{
      name: "status",
      required: true,
      type: :string,
      allowed_values: ["active", "inactive"]
    }
  ]

  defp handle_status_update(conn, id, opts) do
    case Identity.get_user(id, opts) do
      {:error, :not_found} ->
        Response.not_found(conn)

      {:ok, _existing} ->
        case Validation.validate(@status_schema, conn.body_params) do
          {:errors, field_errors} ->
            Response.send_problem(conn, Validation.problem(field_errors))

          {:ok, %{"status" => status_string}} ->
            status = String.to_existing_atom(status_string)

            case Identity.update_user_status(id, status, opts) do
              {:ok, user} -> Response.ok(conn, user_map(user))
              {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
              {:error, :not_found} -> Response.not_found(conn)
            end
        end
    end
  end

  # ── POST /groups (design §3.1) ──────────────────────────────────────────

  @create_group_schema [
    %FieldConstraint{
      name: "name",
      required: true,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "display_name",
      required: false,
      type: :string,
      reject_empty_string: true,
      min_length: 1,
      max_length: 255
    },
    %FieldConstraint{
      name: "description",
      required: false,
      type: :string,
      max_length: 1000
    }
  ]

  defp handle_create_group(conn, opts) do
    case Validation.validate(@create_group_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        case Identity.create_group(attrs, opts) do
          {:ok, group} -> Response.created(conn, group_map(group))
          {:error, :duplicate_group_name} -> Response.conflict(conn, "group name already exists")
          {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
        end
    end
  end

  # ── GET /groups (design §3.3) ───────────────────────────────────────────

  defp handle_list_groups(conn, opts) do
    {:ok, %{groups: groups, total: total}} = Identity.list_groups(opts)

    Response.ok(conn, %{"items" => Enum.map(groups, &group_map/1), "total" => total})
  end

  # ── DELETE /groups/:id (design §3.4) ────────────────────────────────────

  defp handle_delete_group(conn, id, opts) do
    case Identity.delete_group(id, opts) do
      :ok -> Response.no_content(conn)
      {:error, :not_found_or_has_members} -> Response.not_found(conn)
    end
  end

  # ── POST /groups/:id/members (design §3.2) ──────────────────────────────
  #
  # OQ-2 (ELIXIR-DEV's call, design flagged this explicitly): R-Co's dual
  # "user_id"/"user_ids"[0] fallback is preserved verbatim, since no
  # acceptance criterion calls for simplifying it and no existing Letflow
  # caller depends on the array shape either way -- preserving costs
  # nothing and stays closer to the source.

  @add_member_schema [
    %FieldConstraint{name: "user_id", required: false, type: :string},
    %FieldConstraint{name: "user_ids", required: false, type: :array}
  ]

  defp handle_add_member(conn, group_id, opts) do
    case Validation.validate(@add_member_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, attrs} ->
        case resolve_member_user_id(attrs) do
          {:error, :user_id_required} ->
            Response.unprocessable(conn, "user_id_required")

          {:error, :user_id_invalid} ->
            Response.unprocessable(conn, "user_id_invalid")

          {:ok, user_id} ->
            case Identity.add_group_member(group_id, user_id, opts) do
              {:ok, %{member: _member, created: created?}} ->
                status = if created?, do: 201, else: 200
                Response.send_json(conn, status, member_result_map(group_id, user_id, created?))

              {:error, :group_not_found} ->
                Response.not_found(conn)

              {:error, :user_not_found} ->
                Response.not_found(conn)
            end
        end
    end
  end

  defp resolve_member_user_id(%{"user_id" => user_id}) when is_binary(user_id) do
    {:ok, user_id}
  end

  defp resolve_member_user_id(%{"user_ids" => [first | _rest]}) when is_binary(first) do
    {:ok, first}
  end

  defp resolve_member_user_id(%{"user_ids" => list}) when is_list(list) do
    {:error, :user_id_invalid}
  end

  defp resolve_member_user_id(_attrs), do: {:error, :user_id_required}

  # ── GET /groups/:id/members (design §3.5) ───────────────────────────────

  @group_members_cursor_prefix "G:"

  defp handle_list_group_members(conn, group_id, opts) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size),
         {:ok, cursor} <- parse_group_members_cursor_param(Map.get(query, "cursor")) do
      case Identity.list_group_members(group_id, %{cursor: cursor, page_size: page_size}, opts) do
        {:ok, %{members: users, next_cursor: next_cursor}} ->
          page = Pagination.page_response(Enum.map(users, &user_map/1), next_cursor)
          Response.ok(conn, page)

        {:error, :group_not_found} ->
          Response.not_found(conn)
      end
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")

      {:error, :invalid_cursor} ->
        Response.bad_request(conn, "invalid cursor")
    end
  end

  defp parse_group_members_cursor_param(nil), do: {:ok, nil}

  defp parse_group_members_cursor_param(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @group_members_cursor_prefix,
           byte_size(@group_members_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} ->
        {:ok, cursor}

      {:error, _invalid_base64_or_wrong_endpoint_or_expired_or_invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  # ── DELETE /groups/:id/members/:user_id (design §3.6) ───────────────────

  defp handle_remove_member(conn, group_id, user_id, opts) do
    case Identity.remove_group_member(group_id, user_id, opts) do
      :ok -> Response.no_content(conn)
      {:error, :group_not_found} -> Response.not_found(conn)
    end
  end

  # ── POST /tokens (design §6.1, AC1/AC2/AC3, INV-4) ──────────────────────

  @create_token_schema [
    %FieldConstraint{name: "user_id", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "roles", required: true, type: :array},
    %FieldConstraint{name: "expires_at", required: false, type: :string}
  ]

  defp handle_create_token(conn, opts) do
    case Validation.validate(@create_token_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"user_id" => user_id, "roles" => roles} = attrs} ->
        case parse_expires_at(Map.get(attrs, "expires_at")) do
          {:error, :expires_at_invalid} ->
            Response.unprocessable(conn, "expires_at_invalid")

          {:ok, parsed_expires_at} ->
            case Identity.create_token(
                   user_id,
                   %{roles: roles, expires_at: parsed_expires_at},
                   opts
                 ) do
              {:ok, %{token: token, plaintext: plaintext}} ->
                Response.created(conn, token_created_map(token, plaintext))

              {:error, :user_not_found} ->
                Response.not_found(conn)

              {:error, :invalid_role_set} ->
                Response.unprocessable(conn, "roles_invalid")

              {:error, :expires_at_in_past} ->
                Response.unprocessable(conn, "expires_at_in_past")

              {:error, %Ecto.Changeset{}} ->
                Response.unprocessable(conn, "validation failed")
            end
        end
    end
  end

  defp parse_expires_at(nil), do: {:ok, nil}

  defp parse_expires_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :expires_at_invalid}
    end
  end

  # ── GET /tokens (design §6.1, AC1/AC2) ───────────────────────────────────

  defp handle_list_tokens(conn, opts) do
    {:ok, tokens} = Identity.list_tokens(opts)

    Response.ok(conn, %{"items" => Enum.map(tokens, &token_map/1)})
  end

  # ── DELETE /tokens/:id (design §6.1, AC4) ────────────────────────────────

  defp handle_revoke_token(conn, id, opts) do
    case Identity.revoke_token(id, opts) do
      {:ok, token} -> Response.ok(conn, token_map(token))
      {:error, :not_found} -> Response.not_found(conn)
    end
  end

  # ── GET /roles (design §6.1, AC6) ────────────────────────────────────────

  defp handle_list_roles(conn) do
    roles = RoleRegistry.list_roles()

    Response.ok(conn, %{"items" => Enum.map(roles, &role_map/1)})
  end

  # ── POST /roles (design §6.1, AC6) ───────────────────────────────────────

  @upsert_role_schema [
    %FieldConstraint{name: "name", required: true, type: :string, reject_empty_string: true},
    %FieldConstraint{name: "group_id", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_upsert_role(conn) do
    case Validation.validate(@upsert_role_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"name" => name, "group_id" => group_id}} ->
        case RoleRegistry.upsert_role(name, group_id) do
          {:ok, role} -> Response.ok(conn, role_map(role))
          {:error, :invalid_role_name} -> Response.unprocessable(conn, "invalid_role_name")
          {:error, :invalid_group_id} -> Response.unprocessable(conn, "invalid_group_id")
          {:error, :group_not_found} -> Response.not_found(conn)
          {:error, %Ecto.Changeset{}} -> Response.unprocessable(conn, "validation failed")
        end
    end
  end

  # ── Response allowlist (design §3, AC5, INV-2) ──────────────────────────

  @doc false
  # Exactly 8 keys, hand-built -- never a Jason.Encoder derivation over the
  # full %User{} struct. `password_hash`, `external_id`, `external_realm` are
  # deliberately excluded (INV-2; see moduledoc/design §3).
  @spec user_map(Letflow.Identity.User.t()) :: map()
  defp user_map(%Letflow.Identity.User{} = user) do
    %{
      "id" => user.id,
      "username" => user.username,
      "display_name" => user.display_name,
      "email" => user.email,
      "status" => Atom.to_string(user.status),
      "auth_source" => Atom.to_string(user.auth_source),
      "inserted_at" => iso8601(user.inserted_at),
      "updated_at" => iso8601(user.updated_at)
    }
  end

  @doc false
  # Hand-built map, never a Jason.Encoder derivation over %Group{} (design §9,
  # INV-2-equivalent even though INV-2 isn't formally named for this
  # requirement). Nothing on %Group{} needs excluding today, but the
  # allowlist discipline is applied anyway, matching user_map/1's own
  # convention.
  @spec group_map(Letflow.Identity.Group.t()) :: map()
  defp group_map(%Letflow.Identity.Group{} = group) do
    %{
      "id" => group.id,
      "name" => group.name,
      "display_name" => group.display_name,
      "description" => group.description,
      "created_at" => iso8601(group.inserted_at)
    }
  end

  # The ONLY function in this codebase that ever puts a token plaintext into a
  # response body (design §6.2, AC1, INV-4). Called exactly once, from
  # handle_create_token/2's success branch, on the freshly-returned
  # {token, plaintext} pair -- never re-derivable from a persisted row (the
  # row never holds the plaintext, Letflow.Identity.ApiToken's own moduledoc).
  @spec token_created_map(Letflow.Identity.ApiToken.t(), String.t()) :: map()
  defp token_created_map(%Letflow.Identity.ApiToken{} = token, plaintext) do
    %{
      "id" => token.id,
      "token" => plaintext,
      "name" => token.name,
      "user_id" => token.user_id,
      "roles" => token.roles,
      "expires_at" => iso8601_or_nil(token.expires_at),
      "created_at" => iso8601(token.inserted_at)
    }
  end

  # Metadata only -- used by GET /tokens and DELETE /tokens/:id. Structurally
  # excludes token_hash and has no parameter through which a plaintext could
  # ever reach it (design §6.2, AC1/AC2, INV-4).
  @spec token_map(Letflow.Identity.ApiToken.t()) :: map()
  defp token_map(%Letflow.Identity.ApiToken{} = token) do
    %{
      "id" => token.id,
      "name" => token.name,
      "user_id" => token.user_id,
      "roles" => token.roles,
      "status" => token_status(token),
      "created_at" => iso8601(token.inserted_at),
      "expires_at" => iso8601_or_nil(token.expires_at),
      "revoked_at" => iso8601_or_nil(token.revoked_at),
      "last_used_at" => iso8601_or_nil(token.last_used_at)
    }
  end

  defp token_status(%Letflow.Identity.ApiToken{revoked_at: revoked_at})
       when not is_nil(revoked_at),
       do: "revoked"

  defp token_status(%Letflow.Identity.ApiToken{expires_at: expires_at})
       when not is_nil(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: "active", else: "expired"
  end

  defp token_status(%Letflow.Identity.ApiToken{}), do: "active"

  @spec role_map(Letflow.Identity.TenantRole.t()) :: map()
  defp role_map(%Letflow.Identity.TenantRole{} = role) do
    %{
      "id" => role.id,
      "name" => role.name,
      "group_id" => role.group_id,
      "created_at" => iso8601(role.inserted_at)
    }
  end

  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # PROVENANCE (historical, not current decision authority):
  # Design §9's ad hoc add-member response shape (`group_id`/`user_id`/
  # `created`, coinciding with `serializeGroupMemberResult`,
  # identity.zig:1017-1023 -- not group_map/1 or user_map/1). OQ-9
  # (ELIXIR-DEV's call): "added_at" is omitted -- no
  # acceptance criterion depends on its presence, and adding it would need
  # threading the just-inserted/just-fetched GroupMember's own inserted_at
  # through for no named requirement.
  @spec member_result_map(String.t(), String.t(), boolean()) :: map()
  defp member_result_map(group_id, user_id, created?) do
    %{"group_id" => group_id, "user_id" => user_id, "created" => created?}
  end

  # OQ-2: no other REQ-073-adjacent response builder was found to check
  # against (see handoff) -- ISO 8601 via DateTime.to_iso8601/1, matching
  # the convention `lib/letflow/definitions/export_import.ex` and
  # `lib/letflow/engine/execution_error.ex` already use for a timestamp in a
  # JSON response body. `users.inserted_at`/`updated_at` are `NaiveDateTime`
  # (Ecto's `timestamps()` default) and are treated as UTC, matching every
  # other naive-datetime-as-UTC assumption already made in this codebase.
  defp iso8601(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
