defmodule Letflow.Routers.Tasks do
  @moduledoc """
  Task read-path sub-router (REQ-083), mounted at `/tasks` by
  `Letflow.Plugs.ApiPipeline`. Ports `src/api/routes/tasks.zig`'s
  `handleList` (L89), `handleGetById` (L290), `handleInbox` (L960). See
  `lib/letflow/design/req083-task-routes-read.md` for the full design.

  * GET /tasks        -> `Letflow.Tasks.list_tasks/2` (`:TasksList` policy key)
  * GET /tasks/inbox  -> `Letflow.Tasks.list_tasks/2`, forced per-principal scope (`:TasksList` policy key)
  * GET /tasks/:id    -> `Letflow.Tasks.get_task/2` (`:TasksGetById` policy key)

  Every route is deliberately thin — scoped-prefix resolution, authorization,
  request validation, and a response-shape allowlist, with all persistence
  delegated to `Letflow.Tasks`. All unmatched requests return the RFC 9457
  404 problem document.

  ## Route-match ordering — `/inbox` before `/:id`

  `Plug.Router`'s `get "/:id"` would otherwise also match the literal path
  segment `"inbox"` as `id = "inbox"`, which would then fail
  `Ecto.UUID.cast/1` and misreport as `{:error, :invalid_id}` (400) instead of
  serving the inbox. `get "/inbox"` is declared textually **before**
  `get "/:id"` below, matching R-Co's own `main.zig` dispatch order and
  `Plug.Router`'s documented first-match-wins semantics.

  ## `endpoint_policy_key/2` — one new clause on `Letflow.Api.Authorization` (OQ-8)

  `Letflow.Api.Authorization.endpoint_policy_key/2` had no `("GET",
  "/tasks/inbox")` clause before this requirement — one was added, mapping to
  the same `:TasksList` policy key `GET /tasks` already uses. This is a
  direct, narrow port of R-Co's own delegation: `handleInbox` builds a
  `ListTasksParams` and calls `handleList`, which is where the *only*
  `evaluateAccess` call for this whole flow happens (`tasks.zig` L960-982) —
  `handleInbox` performs no authorization call of its own. Additive-only,
  changes no existing clause's behavior (every existing `endpoint_policy_key/2`
  call site is pattern-matched by exact string).

  ## Inbox scoping — per-principal, not merely per-tenant

  For a task-worker-only caller (`Authorization.is_task_worker_only?/1`),
  both `GET /tasks` (via `evaluate_access/2`'s own `AllowWithRowFilter`
  decision) and `GET /tasks/inbox` force `assignee_scope` to
  `{:principal, Letflow.Tasks.resolve_principal_scope(user_id, opts)}` —
  never a caller-supplied filter (INV-2: a task-worker's row scope can never
  be widened by a request-supplied `assignee_id`/`status`/`instance_id`
  param). For any other caller (operator, designer, admin), `GET
  /tasks/inbox` returns `:unfiltered` — **every** task in the tenant, not
  merely "assigned to me." This matches R-Co's own `handleInbox` behavior
  exactly (`actor.is_operator_or_above` sets `effective_assignee_id = null`)
  — a deliberate, real R-Co behavior being ported, not a bug: an
  operator's "inbox" is the whole queue.

  ## Response allowlists (INV-2, AC5)

  `task_list_item_map/1` (9 keys) / `task_detail_map/2` (10 keys, adds
  `correlation_key`/`updated_at`) are hand-built maps, never a
  `Jason.Encoder`/struct-wholesale encoding — matching
  `Letflow.Routers.Identity`'s `user_map/1` discipline exactly. `claimed_by`
  is omitted entirely (no Letflow schema column exists yet — REQ-085's own
  concern). `form_schema`/`output_variables`/`completed_by`/`completed_at`/
  `cancelled_at` are also excluded — none is named by any REQ-083 acceptance
  criterion, and `form_schema` is unpopulated (always `nil`) in this codebase
  today (REQ-047 §4.4's own open question).
  """

  use Plug.Router

  alias Letflow.Api.Authorization
  alias Letflow.Api.Context
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Tasks

  plug(:match)
  plug(:dispatch)

  @problems_base Application.compile_env(
                   :letflow,
                   :problems_base_uri,
                   "https://bpm.example.com/problems/"
                 )

  get "/inbox" do
    with_authorized_scope(conn, "GET", "/tasks/inbox", fn conn, opts, decision ->
      handle_inbox(conn, opts, decision)
    end)
  end

  get "/" do
    with_authorized_scope(conn, "GET", "/tasks", fn conn, opts, decision ->
      handle_list(conn, opts, decision)
    end)
  end

  get "/:id" do
    with_authorized_scope(conn, "GET", "/tasks/:id", fn conn, opts, _decision ->
      handle_get_by_id(conn, conn.params["id"], opts)
    end)
  end

  match _ do
    Response.not_found(conn)
  end

  # ── Shared step-1/step-2 preamble (design §5.1) ─────────────────────────
  #
  # Step 1 -- scoped prefix. Step 2 -- authorization. No Repo call of any
  # kind happens before both steps have run and step 2 has returned :Allow
  # or :AllowWithRowFilter. `method`/`path_template` are literal string
  # constants at every call site above, never derived from conn.request_path,
  # matching Letflow.Api.Authorization's own already-shipped endpoint_policy_key/2
  # clauses for these three routes (full-path literals, "/tasks"-prefixed,
  # not this sub-router's own forward-relative match patterns).
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
            fun.(conn, opts, decision)
        end
    end
  end

  # ── GET /tasks (design §5.2) ────────────────────────────────────────────

  defp handle_list(conn, opts, decision) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, status} <- parse_status_param(Map.get(query, "status")),
         {:ok, instance_id} <- parse_instance_id_param(Map.get(query, "instance_id")),
         {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      assignee_id = non_empty(Map.get(query, "assignee_id"))
      assignee_scope = build_list_assignee_scope(decision, assignee_id, opts)

      Tasks.list_tasks(
        %{
          status: status,
          instance_id: instance_id,
          assignee_scope: assignee_scope,
          cursor: Map.get(query, "cursor"),
          page_size: page_size
        },
        opts
      )
      |> handle_list_result(conn)
    else
      {:error, :invalid_status} ->
        Response.bad_request(conn, "status must be one of PENDING, COMPLETED, CANCELLED")

      {:error, :invalid_instance_id} ->
        Response.bad_request(conn, "instance_id is not a valid UUID")

      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # A task-worker-only caller's scope is always forced to their own
  # principal scope, regardless of any assignee_id the caller supplied
  # (INV-2 -- AllowWithRowFilter's row scope can never be widened by a
  # request-supplied filter).
  defp build_list_assignee_scope(
         %Authorization.AccessDecision{task_scope: {:own_user_and_groups, user_id}},
         _assignee_id,
         opts
       ) do
    {:principal, Tasks.resolve_principal_scope(user_id, opts)}
  end

  defp build_list_assignee_scope(%Authorization.AccessDecision{task_scope: :all}, nil, _opts) do
    :unfiltered
  end

  defp build_list_assignee_scope(
         %Authorization.AccessDecision{task_scope: :all},
         assignee_id,
         _opts
       ) do
    {:explicit_user, assignee_id}
  end

  # ── GET /tasks/inbox (design §5.3) ──────────────────────────────────────

  defp handle_inbox(conn, opts, _decision) do
    conn = fetch_query_params(conn)
    query = conn.query_params

    with {:ok, raw_page_size} <- Pagination.parse_page_size_param(Map.get(query, "page_size")),
         {:ok, page_size} <- Pagination.validate_page_size(raw_page_size) do
      user_id = conn.assigns.auth_context.user_id
      assignee_scope = build_inbox_assignee_scope(conn, user_id, opts)

      Tasks.list_tasks(
        %{assignee_scope: assignee_scope, cursor: Map.get(query, "cursor"), page_size: page_size},
        opts
      )
      |> handle_list_result(conn)
    else
      {:error, :invalid_page_size} ->
        Response.bad_request(conn, "invalid page_size")

      {:error, :page_size_too_large} ->
        Response.bad_request(conn, "page_size out of range")
    end
  end

  # `status`/`instance_id`/`assignee_id` query params, if present, are
  # silently ignored for this endpoint -- R-Co's own handleInbox never reads
  # them either (main.zig's inbox branch never populates them).
  defp build_inbox_assignee_scope(conn, user_id, opts) do
    roles = Authorization.roles_from_strings(conn.assigns.auth_context.roles)

    if Authorization.is_task_worker_only?(roles) do
      {:principal, Tasks.resolve_principal_scope(user_id, opts)}
    else
      :unfiltered
    end
  end

  # ── Shared list/inbox result handling (design §5.2 points 5-6) ─────────

  defp handle_list_result({:ok, %{items: items, next_cursor: next_cursor}}, conn) do
    Response.ok(conn, %{
      "items" => Enum.map(items, &task_list_item_map/1),
      "next_cursor" => next_cursor,
      "count" => length(items)
    })
  end

  defp handle_list_result({:error, :invalid_cursor}, conn) do
    Response.unprocessable(conn, "cursor is not valid for this endpoint")
  end

  defp handle_list_result({:error, :wrong_endpoint}, conn) do
    Response.unprocessable(conn, "cursor is not valid for this endpoint")
  end

  defp handle_list_result({:error, :expired}, conn) do
    Response.send_problem(conn, cursor_expired_error())
  end

  # OQ-6: a locally-built 410 Error.t() literal for this one call site,
  # rather than a new Letflow.Api.Error.cursor_expired/0 public constructor
  # (none of Letflow.Api.Error's existing constructors cover 410 today).
  # Promote to a shared constructor if a second call site needs one later.
  defp cursor_expired_error do
    %Error{
      type: @problems_base <> "cursor-expired",
      title: "Cursor Expired",
      status: 410,
      detail: "cursor has expired; please restart pagination"
    }
  end

  # ── GET /tasks/:id (design §5.4) ────────────────────────────────────────

  defp handle_get_by_id(conn, id, opts) do
    case Tasks.get_task(id, opts) do
      {:ok, {task, correlation_key}} ->
        Response.ok(conn, task_detail_map(task, correlation_key))

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :invalid_id} ->
        Response.bad_request(conn, "task_id is not a valid UUID")
    end
  end

  # ── Query-param parsing helpers ─────────────────────────────────────────

  defp parse_status_param(nil), do: {:ok, nil}
  defp parse_status_param("PENDING"), do: {:ok, :pending}
  defp parse_status_param("COMPLETED"), do: {:ok, :completed}
  defp parse_status_param("CANCELLED"), do: {:ok, :cancelled}
  defp parse_status_param(_other), do: {:error, :invalid_status}

  defp parse_instance_id_param(nil), do: {:ok, nil}

  defp parse_instance_id_param(raw) when is_binary(raw) do
    case Ecto.UUID.cast(raw) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_instance_id}
    end
  end

  defp non_empty(nil), do: nil
  defp non_empty(""), do: nil
  defp non_empty(value) when is_binary(value), do: value

  # ── Response allowlists (design §5.5, INV-2, AC5) ───────────────────────

  @doc false
  # Exactly nine keys, hand-built -- never a Jason.Encoder derivation over
  # %Letflow.Engine.Task{}. form_schema/output_variables/completed_by/
  # completed_at/cancelled_at/inserted_at/updated_at are deliberately
  # excluded (see moduledoc, design §5.5).
  @spec task_list_item_map(Letflow.Engine.Task.t()) :: map()
  defp task_list_item_map(%Letflow.Engine.Task{} = task) do
    %{
      "id" => task.id,
      "instance_id" => task.instance_id,
      "node_id" => task.node_id,
      "node_name" => task.node_name,
      "status" => task_status_string(task.status),
      "assignee_type" => task.assignee_type,
      "assignee_ref" => task.assignee_ref,
      "created_at" => DateTime.to_iso8601(task.inserted_at),
      "token_id" => task.token_id
    }
  end

  @doc false
  # Same nine keys as task_list_item_map/1, plus correlation_key and
  # updated_at -- ten keys total. No claimed_by (no Letflow schema column
  # exists yet; see moduledoc).
  @spec task_detail_map(Letflow.Engine.Task.t(), String.t() | nil) :: map()
  defp task_detail_map(%Letflow.Engine.Task{} = task, correlation_key) do
    task
    |> task_list_item_map()
    |> Map.put("correlation_key", correlation_key)
    |> Map.put("updated_at", DateTime.to_iso8601(task.updated_at))
  end

  # task.status is loaded as one of :pending/:completed/:cancelled; the
  # schema's own Ecto.Enum mapping dumps each to its uppercase DB string
  # ("PENDING"/"COMPLETED"/"CANCELLED", see Letflow.Engine.Task's moduledoc
  # INV-EE43-4) -- Atom.to_string/1 |> String.upcase/1 reproduces exactly
  # that mapping without re-deriving it via a second lookup table.
  defp task_status_string(status) when is_atom(status) do
    status |> Atom.to_string() |> String.upcase()
  end
end
