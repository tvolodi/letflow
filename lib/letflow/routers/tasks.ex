defmodule Letflow.Routers.Tasks do
  @moduledoc """
  Task read+write sub-router, mounted at `/tasks` by
  `Letflow.Plugs.ApiPipeline`. REQ-083 built the read path (`handleList`
  L89, `handleGetById` L290, `handleInbox` L960 of `src/api/routes/tasks.zig`,
  `lib/letflow/design/req083-task-routes-read.md`). REQ-085 adds the write
  path (`handleComplete` L341, `handleClaim` L551, `handleAssign` L628,
  `handleReassign` L736 — same source file — `lib/letflow/design/req085-task-routes-write.md`).

  * GET  /tasks             -> `Letflow.Tasks.list_tasks/2` (`:TasksList` policy key)
  * GET  /tasks/inbox       -> `Letflow.Tasks.list_tasks/2`, forced per-principal scope (`:TasksList` policy key)
  * GET  /tasks/:id         -> `Letflow.Tasks.get_task/2` (`:TasksGetById` policy key)
  * POST /tasks/:id/complete -> `Letflow.Engine.complete_task/3` (`:TasksComplete` policy key) — the ONLY call this router makes to drive completion; zero `Repo.` calls anywhere in this module (INV-TW85-2). Completion is an engine transition (output variables merge, token advances) — a handler that flipped the `tasks` row to `COMPLETED` directly would leave the owning instance permanently stalled.
  * POST /tasks/:id/claim   -> `Letflow.Tasks.claim_task/3` (`:TasksComplete` policy key, REQ-085 design §2 — not `:TasksAssign`, since claiming your own inbox item is a completion-track action, not an assignment one)
  * POST /tasks/:id/assign  -> `Letflow.Tasks.assign_task/4` (`:TasksAssign` policy key)
  * POST /tasks/:id/reassign -> `Letflow.Tasks.reassign_task/4` (`:TasksAssign` policy key — `required_permission/1` maps both `:TasksAssign`/`:TasksReassign` endpoint keys to the same `:TasksAssign` permission)

  Every route is deliberately thin — scoped-prefix resolution, authorization,
  request validation, and a response-shape allowlist, with all persistence
  delegated to `Letflow.Tasks`/`Letflow.Engine`. All unmatched requests
  return the RFC 9457 404 problem document.

  ## Authorization (REQ-131)

  Every route below is declared via `authz_get`/`authz_post`
  (`Letflow.Api.AuthorizedRouter`) with its own policy key —
  `Letflow.Plugs.Authorize` evaluates it before this module's handler ever
  runs. The route-local `with_authorized_scope/4` copy that used to live
  here (the same established pattern `Letflow.Routers.Identity` and
  `Letflow.Routers.Tenants` also used to have) is deleted, not adapted, per
  REQ-130's design §2.4.

  ## Concurrency (`claim`/`assign`/`reassign`, AC4)

  `Letflow.Tasks.claim_task/3`/`assign_task/4`/`reassign_task/4` each acquire
  `SELECT ... FOR UPDATE` on the single `tasks` row via `Letflow.Tasks`'s own
  private `fetch_and_lock_task/3`, inside one `Ecto.Multi` per call — the
  same row-lock-then-check-in-Elixir idiom `Letflow.Engine.complete_task/3`
  already established. This router adds no second locking/concurrency
  scheme of its own; it only calls those functions and maps their results.

  ## Route-match ordering — `/inbox` before `/:id`

  `Plug.Router`'s `get "/:id"` would otherwise also match the literal path
  segment `"inbox"` as `id = "inbox"`, which would then fail
  `Ecto.UUID.cast/1` and misreport as `{:error, :invalid_id}` (400) instead of
  serving the inbox. `get "/inbox"` is declared textually **before**
  `get "/:id"` below, so `Plug.Router`'s documented first-match-wins
  semantics resolve the literal path before the parameterized one gets a
  chance to swallow it (`main.zig`'s dispatch order does the same for the
  same reason).

  ## `endpoint_policy_key/2` — one new clause on `Letflow.Api.Authorization` (OQ-8)

  `Letflow.Api.Authorization.endpoint_policy_key/2` had no `("GET",
  "/tasks/inbox")` clause before this requirement — one was added, mapping to
  the same `:TasksList` policy key `GET /tasks` already uses, since inbox
  listing is only a forced-scope variant of the same list operation and has
  no reason to be gated by a different permission (the historical
  `handleInbox` delegates to `handleList` the same way, with the *only*
  `evaluateAccess` call for that whole flow happening inside it —
  `tasks.zig` L960-982). Additive-only,
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
  merely "assigned to me." This is deliberate, not a bug: an operator sits
  above individual assignment, so an operator's "inbox" is the whole queue,
  not a per-principal filter that would hide work from the people
  responsible for the tenant's whole task backlog.

  ## Response allowlists (INV-2, AC5)

  `task_list_item_map/2` (11 keys) / `task_detail_map/3` (13 keys, adds
  `correlation_key`/`updated_at`) are hand-built maps, never a
  `Jason.Encoder`/struct-wholesale encoding — matching
  `Letflow.Routers.Identity`'s `user_map/1` discipline exactly. `claimed_by`
  is omitted entirely (no Letflow schema column exists yet — REQ-085's own
  concern). `form_schema`/`output_variables`/`completed_by`/`completed_at`/
  `cancelled_at` are also excluded — none is named by any REQ-083 acceptance
  criterion, and `form_schema` is unpopulated (always `nil`) in this codebase
  today (REQ-047 §4.4's own open question) — a distinct concern from
  `form_id`/`form_version` below (identity/version, not rendering payload).

  `form_id`/`form_version` (REQ-126, `lib/letflow/design/req126-form-version-pinning.md`)
  are the two new keys as of this requirement — `form_id` is the task's own
  `node_id`, `form_version` is the pinned `instance_definition_snapshots.definition_ver`
  `Letflow.Tasks.get_task/2`/`list_tasks/2`/`get_form_version/2` now surface.
  See `Letflow.Tasks`'s own moduledoc ("Form version pinning") for why this
  is a new read rather than a new instance of `Letflow.Engine.PinResolver`'s
  machinery.
  """

  use Letflow.Api.AuthorizedRouter

  alias Letflow.Api.Authorization
  alias Letflow.Api.Error
  alias Letflow.Api.Pagination
  alias Letflow.Api.Response
  alias Letflow.Api.Validation
  alias Letflow.Api.Validation.FieldConstraint
  alias Letflow.Engine
  alias Letflow.Tasks

  authz_get "/inbox", :TasksList do
    handle_inbox(conn, conn.assigns.scoped_opts, conn.assigns.access_decision)
  end

  authz_get "/", :TasksList do
    handle_list(conn, conn.assigns.scoped_opts, conn.assigns.access_decision)
  end

  authz_get "/:id", :TasksGetById do
    handle_get_by_id(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/complete", :TasksComplete do
    handle_complete(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/claim", :TasksComplete do
    handle_claim(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/assign", :TasksAssign do
    handle_assign(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  authz_post "/:id/reassign", :TasksReassign do
    handle_reassign(conn, conn.params["id"], conn.assigns.scoped_opts)
  end

  match _ do
    Response.not_found(conn)
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
  # silently ignored for this endpoint -- inbox's assignee scope is always
  # forced (per-principal or unfiltered, see INV-2 above), so a
  # caller-supplied filter on these fields would have no effect regardless
  # (main.zig's inbox branch never populates them either, for the same
  # reason).
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
      "items" =>
        Enum.map(items, fn {task, form_version} -> task_list_item_map(task, form_version) end),
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
    Response.send_problem(conn, Error.cursor_expired())
  end

  # ── GET /tasks/:id (design §5.4) ────────────────────────────────────────

  defp handle_get_by_id(conn, id, opts) do
    case Tasks.get_task(id, opts) do
      {:ok, {task, correlation_key, form_version}} ->
        Response.ok(conn, task_detail_map(task, correlation_key, form_version))

      {:error, :not_found} ->
        Response.not_found(conn)

      {:error, :invalid_id} ->
        Response.bad_request(conn, "task_id is not a valid UUID")
    end
  end

  # ── POST /tasks/:id/complete (REQ-085 design §5.2) ──────────────────────
  #
  # INV-TW85-2: this handler performs ZERO Repo. calls and ZERO
  # Task.complete_changeset/2 calls -- completion is driven entirely by
  # Letflow.Engine.complete_task/3 (REQ-048), the engine entry point. A
  # handler that flipped the tasks row to COMPLETED directly, without going
  # through that function, would leave the owning instance permanently
  # stalled (output variables never merged, token never advanced) -- the
  # single most damaging way to get this route wrong. Do not add a Repo call
  # here under any circumstance.
  defp handle_complete(conn, id, opts) do
    output_variables = conn.body_params
    actor_id = conn.assigns.auth_context.user_id
    idempotency_key = Ecto.UUID.generate()

    attrs = %{
      output_variables: output_variables,
      actor_id: actor_id,
      idempotency_key: idempotency_key
    }

    id
    |> Engine.complete_task(attrs, opts)
    |> handle_complete_result(conn)
  end

  defp handle_complete_result({:ok, result}, conn) do
    Response.ok(conn, complete_result_map(result))
  end

  defp handle_complete_result({:error, :invalid_task_id}, conn) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  defp handle_complete_result({:error, :invalid_output_variables}, conn) do
    Response.unprocessable(conn, "output_variables must be a JSON object")
  end

  defp handle_complete_result({:error, :task_not_found}, conn) do
    Response.not_found(conn)
  end

  defp handle_complete_result({:error, {:task_not_pending, _status}}, conn) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_complete_result({:error, %Ecto.Changeset{}}, conn) do
    Response.unprocessable(conn, "validation failed")
  end

  # Catch-all: every other complete_error() member (:invalid_schema_name,
  # :instance_not_found, {:instance_not_active, _}, :snapshot_not_found,
  # {:graph_structure_invalid, _}, {:missing_token_record, _},
  # {:transition_failed, _}, {:new_token_during_resume_not_supported, _},
  # {:task_activation_failed, _}, {:event_append_failed, _},
  # :missing_actor_id, :missing_idempotency_key,
  # {:instance_execution_error, _, _}, {:error, term()}) -- either
  # structurally unreachable given this handler's own router-derived inputs,
  # or a genuine data-integrity/downstream failure this caller cannot fix by
  # retrying (design §5.5.1). complete_task/3's own catch-all already
  # guarantees it never raises, so this is a typed-tuple match, not a bare
  # pattern that can raise (INV-8).
  defp handle_complete_result({:error, _reason}, conn) do
    Response.internal_error(conn)
  end

  # ── POST /tasks/:id/claim (REQ-085 design §5.3) ─────────────────────────

  defp handle_claim(conn, id, opts) do
    attrs = %{actor_id: conn.assigns.auth_context.user_id}

    id
    |> Tasks.claim_task(attrs, opts)
    |> handle_claim_result(conn, opts)
  end

  defp handle_claim_result({:ok, task}, conn, opts) do
    Response.ok(conn, task_detail_map(task, nil, Tasks.get_form_version(task.instance_id, opts)))
  end

  defp handle_claim_result({:error, :invalid_task_id}, conn, _opts) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  defp handle_claim_result({:error, :task_not_found}, conn, _opts) do
    Response.not_found(conn)
  end

  defp handle_claim_result({:error, {:task_not_pending, _status}}, conn, _opts) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_claim_result({:error, :assigned_to_other_user}, conn, _opts) do
    Response.conflict(conn, "task is assigned to a different user")
  end

  defp handle_claim_result({:error, :assignee_group_not_member}, conn, _opts) do
    Response.conflict(conn, "caller is not a member of the assigned group")
  end

  defp handle_claim_result({:error, :assignee_role_not_held}, conn, _opts) do
    Response.conflict(conn, "caller does not hold the assigned role")
  end

  defp handle_claim_result({:error, :not_claimable}, conn, _opts) do
    Response.conflict(conn, "task cannot be claimed")
  end

  defp handle_claim_result({:error, _reason}, conn, _opts) do
    Response.internal_error(conn)
  end

  # ── POST /tasks/:id/assign, POST /tasks/:id/reassign (REQ-085 design §5.4) ─

  @user_id_schema [
    %FieldConstraint{name: "user_id", required: true, type: :string, reject_empty_string: true}
  ]

  defp handle_assign(conn, id, opts) do
    case Validation.validate(@user_id_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"user_id" => user_id}} ->
        id
        |> Tasks.assign_task(%{user_id: user_id}, opts)
        |> handle_assign_result(conn, opts)
    end
  end

  defp handle_reassign(conn, id, opts) do
    case Validation.validate(@user_id_schema, conn.body_params) do
      {:errors, field_errors} ->
        Response.send_problem(conn, Validation.problem(field_errors))

      {:ok, %{"user_id" => user_id}} ->
        id
        |> Tasks.reassign_task(%{user_id: user_id}, opts)
        |> handle_reassign_result(conn, opts)
    end
  end

  defp handle_assign_result({:ok, task}, conn, opts) do
    Response.ok(conn, task_detail_map(task, nil, Tasks.get_form_version(task.instance_id, opts)))
  end

  defp handle_assign_result({:error, :invalid_task_id}, conn, _opts) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  # Belt-and-suspenders -- Validation.validate/2 above is expected to
  # already have rejected a missing/empty user_id before assign_task/4 is
  # ever reached.
  defp handle_assign_result({:error, :missing_user_id}, conn, _opts) do
    Response.unprocessable(conn, "user_id is required")
  end

  defp handle_assign_result({:error, :task_not_found}, conn, _opts) do
    Response.not_found(conn)
  end

  defp handle_assign_result({:error, {:task_not_pending, _status}}, conn, _opts) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_assign_result({:error, :already_assigned}, conn, _opts) do
    Response.conflict(conn, "task is already assigned")
  end

  defp handle_assign_result({:error, _reason}, conn, _opts) do
    Response.internal_error(conn)
  end

  defp handle_reassign_result({:ok, task}, conn, opts) do
    Response.ok(conn, task_detail_map(task, nil, Tasks.get_form_version(task.instance_id, opts)))
  end

  defp handle_reassign_result({:error, :invalid_task_id}, conn, _opts) do
    Response.bad_request(conn, "task_id is not a valid UUID")
  end

  defp handle_reassign_result({:error, :missing_user_id}, conn, _opts) do
    Response.unprocessable(conn, "user_id is required")
  end

  defp handle_reassign_result({:error, :task_not_found}, conn, _opts) do
    Response.not_found(conn)
  end

  defp handle_reassign_result({:error, {:task_not_pending, _status}}, conn, _opts) do
    Response.conflict(conn, "task is not pending")
  end

  defp handle_reassign_result({:error, :not_currently_assigned}, conn, _opts) do
    Response.conflict(conn, "task is not currently assigned")
  end

  defp handle_reassign_result({:error, _reason}, conn, _opts) do
    Response.internal_error(conn)
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
  # Nine base keys, hand-built -- never a Jason.Encoder derivation over
  # %Letflow.Engine.Task{} -- plus form_id/form_version (REQ-126), eleven
  # keys total. output_variables/completed_by/completed_at/cancelled_at/
  # inserted_at/updated_at are deliberately excluded (see moduledoc, design
  # §5.5); tasks.form_schema (the unrelated, still-unpopulated rendering
  # payload) is also excluded -- see moduledoc.
  #
  # form_id is task.node_id itself (no join needed -- REQ-126 design §4.3);
  # form_version is threaded in by the caller, sourced from the
  # instance_definition_snapshots left_join Letflow.Tasks.get_task/2 /
  # list_tasks/2 / get_form_version/2 already performed.
  @spec task_list_item_map(Letflow.Engine.Task.t(), form_version :: String.t() | nil) :: map()
  defp task_list_item_map(%Letflow.Engine.Task{} = task, form_version) do
    %{
      "id" => task.id,
      "instance_id" => task.instance_id,
      "node_id" => task.node_id,
      "node_name" => task.node_name,
      "status" => task_status_string(task.status),
      "assignee_type" => task.assignee_type,
      "assignee_ref" => task.assignee_ref,
      "created_at" => DateTime.to_iso8601(task.inserted_at),
      "token_id" => task.token_id,
      "form_id" => task.node_id,
      "form_version" => form_version
    }
  end

  @doc false
  # Same eleven keys as task_list_item_map/2, plus correlation_key and
  # updated_at -- thirteen keys total. No claimed_by (no Letflow schema
  # column exists yet; see moduledoc).
  @spec task_detail_map(
          Letflow.Engine.Task.t(),
          correlation_key :: String.t() | nil,
          form_version :: String.t() | nil
        ) :: map()
  defp task_detail_map(%Letflow.Engine.Task{} = task, correlation_key, form_version) do
    task
    |> task_list_item_map(form_version)
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

  @doc false
  # Six keys, mirroring Letflow.Engine.complete_result()'s own six fields
  # exactly (design §5.6) -- an allowlist restatement of an already-plain
  # map, not a struct-to-map reduction (complete_result() involves no
  # %Task{} struct at all on this path). instance_status uses the same
  # Atom.to_string/1 |> String.upcase/1 convention task_status_string/1
  # already establishes, producing "ACTIVE"/"COMPLETED".
  @spec complete_result_map(Letflow.Engine.complete_result()) :: map()
  defp complete_result_map(%{
         task_id: task_id,
         instance_id: instance_id,
         instance_status: instance_status,
         current_nodes: current_nodes,
         variables: variables,
         completed_at: completed_at
       }) do
    %{
      "task_id" => task_id,
      "instance_id" => instance_id,
      "instance_status" => instance_status |> Atom.to_string() |> String.upcase(),
      "current_nodes" => current_nodes,
      "variables" => variables,
      "completed_at" => DateTime.to_iso8601(completed_at)
    }
  end
end
