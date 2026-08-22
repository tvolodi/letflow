defmodule Letflow.Tasks do
  @moduledoc """
  Context module for the task read-query surface (REQ-083) — backs the three
  `Letflow.Routers.Tasks` routes (`GET /tasks`, `GET /tasks/inbox`,
  `GET /tasks/:id`). Plain Ecto context module, no process, no `gen_statem` —
  a pure read/query surface over the already-shipped `tasks` table
  (`Letflow.Engine.Task`, REQ-043/047). See
  `lib/letflow/design/req083-task-routes-read.md` for the full design this
  module implements.

  ## `src/tasks/store.zig` boundary — ported vs. not ported (AC6)

  R-Co's task query/filter/list logic lives in `src/tasks/store.zig` (1,202
  lines), outside `src/api/`. This module ports only the query operations the
  three read-path route handlers (`handleList`/`handleGetById`/`handleInbox`)
  actually invoke — every other `store.zig` operation is a deliberate
  non-port, enumerated below so the boundary is explicit rather than
  approximate.

  **Ported by this module:**

  | R-Co function | This module's equivalent | Notes |
  |---|---|---|
  | `TaskStore.getById` (L239-283) | `get_task/2` | Adds the `instance_projections` join for `correlation_key`, matching R-Co's own `LEFT JOIN` |
  | `TaskStore.listCursor` (L579-737) | `list_tasks/2` | Cursor prefix `"T:"`, keyset `(inserted_at, id)` — same shape as R-Co; **extended** beyond R-Co's own shipped SQL to add ROLE-held-task scoping (see `resolve_principal_scope/2`'s own doc — R-Co's `listCursor` has no `ROLE` arm at all, only `USER`/`GROUP`; this requirement's own text and acceptance criteria require all three) |
  | `taskStatusToString`/`parseTaskStatus` (L1150-1163, L1143-1149) | `Letflow.Engine.Task`'s existing `Ecto.Enum` cast/dump (already shipped, REQ-043) | No new function needed — `Ecto.Enum` already does this |
  | `parseUuid`/`uuidToHex` | `Ecto.UUID.cast/1` / Ecto's native string-form UUIDs | No raw 16-byte UUID type in ordinary use elsewhere in this codebase |

  **Not ported by this module** (every other `pub fn`/error set in
  `store.zig`):

  | R-Co function/type | Why not ported here |
  |---|---|
  | `TaskStore.list` (L443-577, offset-based) | Superseded entirely by `listCursor` — never called by any of the three read handlers |
  | `TaskStore.createInTx` (L161-237) | Task-activation write path — already covered by REQ-047's `Letflow.Engine.TaskActivation.append_multi/6`, a different module entirely |
  | `TaskStore.completeInTx` (L304-379), `cancelInTx` (L381-441) | EE-04 task-completion write path — REQ-085's scope, not read |
  | `TaskStore.claimTask` (L761-849), `assign` (L851-908), `reassign`/`reassignInTx` (L910-1002) | Task claim/assign/reassign write path — REQ-085's scope |
  | `TaskError`'s `AlreadyTerminated`, `ClaimError`, `AssignError` variants | All write-path error shapes — this module's own error surface only needs the read-path subset (not-found, invalid-input, cursor errors) |
  | `insertTaskWaitDescriptorInTx` (L1025-1141) | SCH-03 timer-wait bookkeeping — S6 scope, not invoked by any read handler |

  ## Error handling — matches this project's established residual-risk precedent

  Every function below returns `{:ok, _} | {:error, atom}` for its *expected*
  failure modes (invalid UUID, not found, malformed cursor). A genuine
  DB/connection-level failure is not caught and converted anywhere in this
  module — it propagates as a raised exception, matching `Letflow.Identity`'s
  own established precedent for simple reads rather than inventing a new
  blanket-rescue policy here.

  ## Tenant scoping (INV-1)

  Every function below takes `opts :: [prefix: String.t()]`. This module
  never itself decides tenant scope or authorization — `prefix` is supplied
  by the caller (the router, via `Letflow.Api.Context.scoped_repo_opts/1`),
  exactly like every other REQ-072+ context module in this codebase.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Engine.Task
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.GroupMember
  alias Letflow.Identity.RoleRegistry
  alias Letflow.Repo

  @typedoc "Threaded into every `Repo` call below — `:prefix` derived by the caller from `Letflow.Api.Context.scoped_repo_opts/1`, never from request data."
  @type opts :: [prefix: String.t()]

  @type task_status :: :pending | :completed | :cancelled

  @type principal_scope :: %{
          user_id: String.t(),
          group_ids: [Ecto.UUID.t()],
          role_names: [String.t()]
        }

  @type assignee_scope ::
          :unfiltered
          | {:explicit_user, user_id :: String.t()}
          | {:principal, principal_scope()}

  @type list_tasks_params :: %{
          optional(:status) => task_status() | nil,
          optional(:instance_id) => Ecto.UUID.t() | nil,
          assignee_scope: assignee_scope(),
          cursor: String.t() | nil,
          page_size: pos_integer()
        }

  @list_cursor_prefix "T:"

  @doc """
  Cursor-paginated task listing — backs `GET /tasks` and (via a
  caller-supplied `assignee_scope`) `GET /tasks/inbox`. One function backs
  both endpoints, matching R-Co's own `handleInbox` (which itself builds a
  `ListTasksParams` and calls `handleList`) — this function has no notion of
  "which endpoint called me"; the caller (the router) decides `assignee_scope`
  before calling.

  `assignee_scope`:

    * `:unfiltered` — no assignee filter at all (every task in the tenant's
      schema, subject only to `status`/`instance_id`).
    * `{:explicit_user, user_id}` — `assignee_type == "USER" and assignee_ref
      == user_id` — a caller-supplied `?assignee_id=` filter.
    * `{:principal, principal_scope}` — a task assigned directly to
      `principal_scope.user_id`, OR to a group in `principal_scope.group_ids`,
      OR to a role in `principal_scope.role_names`. Built via
      `resolve_principal_scope/2`.

  Sorted by `inserted_at` descending, then `id` descending (R-Co's own
  `ORDER BY created_at DESC, id DESC`), cursor-paginated via
  `Letflow.Api.Pagination` with prefix `"T:"`.

  Always returns `{:error, :invalid_cursor}` for a malformed/wrong-endpoint
  cursor (collapsing `Letflow.Api.Pagination.decode_cursor/4`'s
  `:invalid_base64`/`:invalid_cursor` atoms into one, matching R-Co's own
  single `INVALID_CURSOR`/422 branch for those cases) and
  `{:error, :expired}` for one past its freshness window.
  """
  @spec list_tasks(list_tasks_params(), opts()) ::
          {:ok, %{items: [Task.t()], next_cursor: String.t() | nil}}
          | {:error, :invalid_cursor | :wrong_endpoint | :expired}
  def list_tasks(params, opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    page_size = Map.fetch!(params, :page_size)

    with {:ok, cursor_seek} <- decode_list_cursor(Map.get(params, :cursor)) do
      query =
        Task
        |> filter_by_status(Map.get(params, :status))
        |> filter_by_instance_id(Map.get(params, :instance_id))
        |> filter_by_assignee_scope(Map.get(params, :assignee_scope, :unfiltered))
        |> filter_by_list_cursor(cursor_seek)
        |> order_by([t], desc: t.inserted_at, desc: t.id)
        |> limit(^(page_size + 1))

      rows = Repo.all(query, prefix: prefix)
      {page, next_cursor} = split_list_page(rows, page_size)

      {:ok, %{items: page, next_cursor: next_cursor}}
    end
  end

  @doc """
  Fetches a single task by id, joined to `instance_projections` for
  `correlation_key` (a plain `left_join`, matching R-Co's own `LEFT JOIN`).

  `Ecto.UUID.cast/1` is checked first — an invalid UUID never reaches the DB
  (`{:error, :invalid_id}`, no round-trip). A cross-tenant `id` and a
  genuinely nonexistent `id` resolve through this same single code path to
  `{:error, :not_found}` — no branch exists that could tell them apart
  (INV-5/AC3), the identical structural mechanism REQ-072's own AC4
  demonstration established.

  This function does not itself decide tenant scope or authorization —
  `prefix` is supplied by the caller.
  """
  @spec get_task(id :: String.t(), opts()) ::
          {:ok, {Task.t(), correlation_key :: String.t() | nil}}
          | {:error, :not_found | :invalid_id}
  def get_task(id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :invalid_id}

      {:ok, id} ->
        query =
          from(t in Task,
            left_join: ip in InstanceProjection,
            on: ip.instance_id == t.instance_id,
            where: t.id == ^id,
            select: {t, ip.correlation_key}
          )

        case Repo.one(query, prefix: prefix) do
          nil -> {:error, :not_found}
          {task, correlation_key} -> {:ok, {task, correlation_key}}
        end
    end
  end

  @doc """
  Resolves the group ids and role names a user holds — the requirement's own
  explicit instruction ("resolve group and role membership through
  `Letflow.Identity` rather than reimplementing the resolution"), and the one
  place this module's read path goes beyond what R-Co's own shipped
  `listCursor` SQL actually does: **R-Co's `include_group_membership_for_user`
  branch covers `USER`/`GROUP` only — there is no `ROLE` arm anywhere in
  R-Co's shipped `listCursor`.** REQ-083's own requirement text names all
  three ("assigned directly to X, ... to a group X belongs to, and ... to a
  role X holds") and tests all three explicitly — this module implements the
  requirement's text, not R-Co's incomplete implementation of it.

  Group ids: a direct read of the `group_members` table
  (`Letflow.Identity.GroupMember`, REQ-074's schema), inverted from
  `Letflow.Identity.list_group_members/3`'s own `group_id`-keyed direction —
  a read of an `Identity`-owned table, not a reimplementation of
  `Letflow.Identity`'s own membership-management logic (writes to this table
  remain exclusively `Letflow.Identity.add_group_member/3`/
  `remove_group_member/3`'s).

  Role names: derived, not stored directly — a user "holds" a role iff the
  role's bound group (`Letflow.Identity.RoleRegistry.list_roles/0`, already
  shipped, REQ-020) is one of the group ids resolved above. No new role
  table, no per-user role column anywhere in this schema.

  No caching, no memoization — both queries run fresh on every call,
  consistent with this project's existing per-request-fresh-query precedent
  elsewhere in S4 (REQ-072's `scoped_repo_opts/1`, REQ-074's group-membership
  joins).
  """
  @spec resolve_principal_scope(user_id :: String.t(), opts()) :: principal_scope()
  def resolve_principal_scope(user_id, opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    group_ids =
      Repo.all(
        from(m in GroupMember, where: m.user_id == ^user_id, select: m.group_id),
        prefix: prefix
      )

    role_names =
      RoleRegistry.list_roles()
      |> Enum.filter(&(&1.group_id in group_ids))
      |> Enum.map(& &1.name)

    %{user_id: user_id, group_ids: group_ids, role_names: role_names}
  end

  # ── list_tasks/2 private helpers ────────────────────────────────────────

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: from(t in query, where: t.status == ^status)

  defp filter_by_instance_id(query, nil), do: query

  defp filter_by_instance_id(query, instance_id) do
    from(t in query, where: t.instance_id == ^instance_id)
  end

  defp filter_by_assignee_scope(query, :unfiltered), do: query

  defp filter_by_assignee_scope(query, {:explicit_user, user_id}) do
    from(t in query, where: t.assignee_type == "USER" and t.assignee_ref == ^user_id)
  end

  defp filter_by_assignee_scope(
         query,
         {:principal,
          %{
            user_id: user_id,
            group_ids: group_ids,
            role_names: role_names
          }}
       ) do
    from(t in query,
      where:
        (t.assignee_type == "USER" and t.assignee_ref == ^user_id) or
          (t.assignee_type == "GROUP" and t.assignee_ref in ^group_ids) or
          (t.assignee_type == "ROLE" and t.assignee_ref in ^role_names)
    )
  end

  defp filter_by_list_cursor(query, nil), do: query

  defp filter_by_list_cursor(query, {inserted_at_us, id}) do
    ts = DateTime.from_unix!(inserted_at_us, :microsecond)
    from(t in query, where: {t.inserted_at, t.id} < {^ts, ^id})
  end

  # Decodes the raw encoded cursor string into a `{inserted_at_us, id}` seek
  # tuple, or passes `nil` through unchanged. Collapses
  # Pagination.decode_cursor/4's :invalid_base64/:invalid_cursor into one
  # atom, matching R-Co's own single INVALID_CURSOR branch for both.
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
    [ts_str, id_str] = String.split(rest, ":", parts: 2)
    {String.to_integer(ts_str), id_str}
  end

  defp split_list_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_next_cursor(List.last(page))}
  end

  defp split_list_page(rows, _page_size), do: {rows, nil}

  defp build_list_next_cursor(%Task{id: id, inserted_at: inserted_at}) do
    inserted_at_us = DateTime.to_unix(inserted_at, :microsecond)

    @list_cursor_prefix
    |> Pagination.build_raw_cursor(inserted_at_us, id)
    |> Pagination.encode_cursor()
  end
end
