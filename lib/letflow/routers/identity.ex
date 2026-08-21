defmodule Letflow.Routers.Identity do
  @moduledoc """
  Identity user-CRUD sub-router (REQ-073), mounted at `/identity` by
  `Letflow.Plugs.ApiPipeline` (so full paths under `/api/v1` are
  `/api/v1/identity/users`, `/api/v1/identity/users/:id`,
  `/api/v1/identity/users/:id/status`). Ports
  `src/api/routes/identity.zig`'s `handleCreateUser`, `handleListUsers`,
  `handleGetUser`, `handlePatchUser`, `handleUpdateUserStatus`. See
  `lib/letflow/design/req073-identity-user-routes.md` for the full design.

  Every route below is deliberately thin — scoped-prefix resolution,
  authorization, request validation, and a response-shape allowlist, with all
  actual persistence delegated to `Letflow.Identity`:

  * POST   /users              -> Identity.create_user/2
  * GET    /users              -> Identity.list_users/2
  * GET    /users/:id          -> Identity.get_user/2
  * PATCH  /users/:id          -> Identity.get_user/2, then Identity.update_user_profile/3
  * POST   /users/:id/status   -> Identity.get_user/2, then Identity.update_user_status/3

  ## Ordering guarantee (AC4)

  Every handler resolves `Letflow.Api.Context.scoped_repo_opts/1` first, then
  calls `Letflow.Api.Authorization.evaluate_access/2` against `:UsersManage`
  — **before any `Repo` call of any kind**, including the get/patch/
  status-update handlers' own pre-fetch reads. A `Deny403` decision returns
  immediately; no read or write happens on that path.

  ## Response allowlist (AC5, INV-2)

  `user_map/1` is a hand-built map with exactly the eight keys named in its
  own @doc — never a `Jason.Encoder` derivation over `%Letflow.Identity.User{}`
  — so `password_hash`, `external_id`, and `external_realm` can never leak
  through this module regardless of what the schema later grows.
  """

  use Plug.Router

  alias Letflow.Api.Authorization
  alias Letflow.Api.Context
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Identity

  @users_cursor_prefix "U:"

  plug(:match)
  plug(:dispatch)

  post "/users" do
    with_authorized_scope(conn, "POST", "/users", fn conn, opts ->
      handle_create(conn, opts)
    end)
  end

  get "/users" do
    with_authorized_scope(conn, "GET", "/users", fn conn, opts ->
      handle_list(conn, opts)
    end)
  end

  get "/users/:id" do
    with_authorized_scope(conn, "GET", "/users/:id", fn conn, opts ->
      handle_get(conn, conn.params["id"], opts)
    end)
  end

  patch "/users/:id" do
    with_authorized_scope(conn, "PATCH", "/users/:id", fn conn, opts ->
      handle_patch(conn, conn.params["id"], opts)
    end)
  end

  post "/users/:id/status" do
    with_authorized_scope(conn, "POST", "/users/:id/status", fn conn, opts ->
      handle_status_update(conn, conn.params["id"], opts)
    end)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── Shared step-1/step-2 preamble (design §1) ───────────────────────────
  #
  # Step 1 -- scoped prefix. Step 2 -- authorization. No Repo call of any
  # kind happens before both steps have run and step 2 has returned :Allow.
  # `method`/`path_template` are literal string constants at every call
  # site above, never derived from conn.request_path, so a handler's own
  # policy key can never accidentally vary with the literal path matched.
  defp with_authorized_scope(conn, method, path_template, fun) do
    case Context.scoped_repo_opts(conn) do
      {:error, _missing_auth_context_or_invalid_tenant_id} ->
        Response.internal_error(conn)

      {:ok, prefix: _schema} = ok ->
        ctx = %Authorization.AccessContext{
          user_id: conn.assigns.auth_context.user_id,
          roles: Authorization.roles_from_strings(conn.assigns.auth_context.roles)
        }

        decision =
          Authorization.evaluate_access(
            ctx,
            Authorization.endpoint_policy_key(method, path_template)
          )

        case decision.kind do
          :Deny403 ->
            Response.forbidden(conn, "insufficient permissions")

          _allow_or_allow_with_row_filter ->
            {:ok, opts} = ok
            fun.(conn, opts)
        end
    end
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
