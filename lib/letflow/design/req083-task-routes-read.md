# REQ-083 — Task routes 1/2, read path (`Letflow.Tasks`, `Letflow.Routers.Tasks`)

PROVENANCE (historical, not current decision authority):
**Requirement:** REQ-083 (`docs/requirements.yaml`, stage S4; full `description` and all
7 `acceptance_criteria` read directly from that entry, per `core-directives.md`'s "Load
Scoped Context, Not Whole Files" — `awk '/^  - id: REQ-083$/,/^  - id: REQ-084$/'
docs/requirements.yaml`).
**Run:** `WF02-REQ083-20260822`, WF-02 Step 1.
**Owner (implementer):** `ELIXIR-DEV`.
**Ports:** `src/api/routes/tasks.zig`'s `handleList` (L89), `handleGetById` (L290),
`handleInbox` (L960) — the read third of a 7-handler, 1,085-line file split with REQ-085
(write path: `handleComplete`, `handleAssign`/`handleReassign`, `handleClaim`). Plus only
the `src/tasks/store.zig` (1,202 lines) query/filter operations these three handlers
actually invoke — see §1 for the full ported/not-ported enumeration this requirement's
own acceptance criterion demands.
**No implementation code below** — signatures, `@spec`-style types, and field/shape
tables only, matching every prior S4 design doc's convention (`req072`, `req067`,
`req066`, `req074`).

**Rework note (rework_count 1, `WF02-REQ083-20260822`, 2026-08-22).**
SECURITY-REVIEWER's Step 2c gate FAILed this design's original §3.4 on INV-1: it had
`resolve_principal_scope/2` resolve ROLE-held tasks via `Letflow.Identity.RoleRegistry.
list_roles/0`, which queries `TenantRole` with no `:prefix` — a real tenant-isolation gap
once the legacy `public.tenant_role` table is dropped per Decision 0006. §3.4 point 2 now
specifies a direct, explicitly `:prefix`-scoped `Ecto.Query` against
`Letflow.Identity.TenantRole` instead, staying inside this run's `owned_modules`
(`lib/letflow/tasks.ex`) with no change to `Letflow.Identity`/`RoleRegistry`. See §3.4,
§6, and INV-TR83-5 for the full revision; §0 lists the security finding read for this
rework.

---

## 0. Sources read for this design

- This run's Step 00 handoff (`handoffs/WF02-REQ083-20260822/step-00-git-setup.json`) —
  `context.requirement_text` (the description above).
- `docs/requirements.yaml` REQ-083's own entry (scoped `awk` read, not the whole file) —
  all 7 `acceptance_criteria`, quoted verbatim in §9 below.
- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's procedure.
- `docs/guides/backend_developer_guide.md` — §3 conventions (naming, error-tuple shape,
  parameterized SQL, migrations), §5 multi-tenancy (schema-per-tenant, Decision 0006 D2).
- `docs/migration/stage-4-api-surface.md` — S4 scope, REQ-072/066/067/069/070/071's
  REVIEWER sign-off history (the established `with_authorized_scope`-shaped pattern §5.2
  below reuses).
- `docs/anti-patterns.md` — general.
- `lib/letflow/design/req072-tenant-request-context.md` (full) — `Letflow.Api.Context.
  scoped_repo_opts/1`'s exact contract (this design's tenant-scoping mechanism, §4).
- `lib/letflow/design/api-pagination.md` (REQ-067, full) — `Letflow.Api.Pagination`'s
  exact function set this design composes (§5).
- `lib/letflow/design/req047-task-activation-persistence.md` (full) — the already-shipped
  `tasks` table's write path (REQ-047/EE-03), `assignee_type`/`assignee_ref`'s exact
  semantics (copied verbatim from `node.attributes` at activation time, zero validation),
  and REQ-047's own OQ-1 (no closed-set/default for `assignee_type`) — load-bearing for
  §3.3 below.
- `lib/letflow/design/req066-api-error-response.md` (full) — `Letflow.Api.Error`/
  `Letflow.Api.Response`'s exact function set (§6).
- `lib/letflow/design/req069-authorization.md` (full) — `Letflow.Api.Authorization`'s
  `TasksList`/`TasksGetById` → `:TasksRead` mapping and `TaskRowScope` shape, already
  shipped (§4.2).
- `lib/letflow/api/authorization.ex`, `lib/letflow/api/context.ex` (read directly, not
  paraphrased from the design docs alone) — confirmed `evaluate_access/2`'s exact
  `AllowWithRowFilter` branch (`endpoint == :TasksList and is_task_worker_only?(ctx.roles)`
  → `{:own_user_and_groups, ctx.user_id}`) and `scoped_repo_opts/1`'s exact return shape.
- `lib/letflow/routers/identity.ex` (full) — the established `with_authorized_scope/4`
  private-helper pattern (REQ-073/074) this design's own router-level helper mirrors, and
  the hand-built-response-map discipline (`user_map/1`/`group_map/1`) this design's
  `task_list_item_map/1`/`task_detail_map/1` follow (§6).
- `lib/letflow/routers/tasks.ex` (current stub, full — 12 lines).
- `lib/letflow/engine/task.ex` (full) — the already-shipped `Letflow.Engine.Task` schema
  this design reads from (§2) but does not itself modify.
- `priv/repo/migrations/20260818110003_create_tasks.exs` and
  `.../20260820000006_drop_tenant_id_tasks.exs` (full) — confirmed the live `tasks` table
  shape: no `tenant_id` column (Decision 0006 D2, already dropped), `idx_task_instance`/
  `idx_task_token` only — **no index supports a `created_at`/`status`/`assignee_*`-driven
  query**, R-Co's own `idx_task_pending`/`idx_task_status` were explicitly not ported by
  REQ-043 "belongs with S4's tasks routes" — flagged as OQ-5 below.
- `lib/letflow/identity.ex`, `lib/letflow/identity/group_member.ex` (full) — confirmed
  `Letflow.Identity` has **no** "list a user's own group memberships" function (every
  existing group-member query is group-id-keyed, e.g. `list_group_members/3`) — load-
  bearing for §3.4's design (a direct `Ecto.Query` against `Letflow.Identity.GroupMember`,
  not a new `Letflow.Identity` function, since `Letflow.Identity`/its submodules are
  explicitly **not** an owned module of this run per the Step 00 handoff).
- `lib/letflow/design/req020-role-registry.md` (full) — `Letflow.Identity.TenantRole`'s
  exact shape (`%{name:, group_id:}` — a role *name* maps to exactly one *group*), the
  schema §3.4 reads directly (rather than through `RoleRegistry.list_roles/0`, per the
  rework note in §3.4 point 2) to resolve "roles a user holds" without any new schema or
  any new `Letflow.Identity` function.
- `handoffs/WF02-REQ083-20260822/step-02c-security-reviewer.json` (SECURITY-REVIEWER's
  Step 2c FAIL, INV-1) and `lib/letflow/identity/role_registry.ex` (re-read for this
  rework) — confirmed `RoleRegistry.list_roles/0` (lines 38-40) has no `:prefix` option
  and no per-request `search_path` mechanism exists in production code; this rework
  replaces this design's original call to it with a direct `:prefix`-scoped query
  against `Letflow.Identity.TenantRole` (§3.4 point 2).
- `lib/letflow/engine/instance_projection.ex` — confirmed `correlation_key` (`:string`,
  nullable) exists on `instance_projections`, the join `get_task/2`'s detail response
  needs to match R-Co's `serializeTaskDetail` shape (§6.2).
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\api\routes\tasks.zig` (the three handler bodies in
  full: L89-290 `handleList`, L290-322 `handleGetById`, L960-981 `handleInbox`, plus
  `errorResult`/`serializeTaskDetail`) and
  `C:\Users\tvolo\dev\ai-dala\R-Co\src\tasks\store.zig` (full file — every `pub fn`
  enumerated in §1; `Task`/`TaskError`/`ListCursorParams` struct definitions; `getById`
  L239-283; `listCursor` L579-737, including its `include_group_membership_for_user`
  SQL-fragment comment block, ISS-0619/ISS-0647/GH-652).

---

PROVENANCE (historical, not current decision authority):
## 1. `src/tasks/store.zig` boundary — ported vs. not ported (AC6, moduledoc-mandatory)

**Ported by this requirement** (both **read-only** query operations `handleList`/
`handleGetById`/`handleInbox` actually invoke):

| R-Co function | Letflow equivalent | Notes |
|---|---|---|
| `TaskStore.getById` (L239-283) | `Letflow.Tasks.get_task/2` (§3.2) | Adds the `instance_projections` join for `correlation_key`, matching R-Co's own `LEFT JOIN` |
| `TaskStore.listCursor` (L579-737) | `Letflow.Tasks.list_tasks/2` (§3.1) | Cursor prefix `"T:"`, keyset `(created_at, id)` — same shape; **extended** beyond R-Co's own shipped SQL to add ROLE-held-task scoping, see §3.4's explicit flag |
| `taskStatusToString`/`parseTaskStatus` (L1150-1163, L1143-1149) | `Letflow.Engine.Task`'s existing `Ecto.Enum` cast/dump (already shipped, REQ-043) — no new function | R-Co's manual string↔enum port has no Elixir equivalent to write; `Ecto.Enum` already does this |
| `parseUuid`/`uuidToHex` (L1173+, and the route file's own `uuidToHex`) | `Ecto.UUID.cast/1` / Ecto's native string-form UUIDs | Elixir has no raw 16-byte UUID type in ordinary use elsewhere in this codebase (matching `req020`'s own precedent for the identical translation) |

PROVENANCE (historical, not current decision authority):
**Not ported by this requirement** (every other `pub fn`/error set in `store.zig`,
enumerated so the boundary is explicit rather than approximate, per AC6):

| R-Co function/type | Why not ported here |
|---|---|
| `TaskStore.list` (L443-577, offset-based) | Superseded entirely by `listCursor` — `handleList`/`handleInbox` never call it; same "cursor supersedes offset" precedent as `req073`'s `list_users/2` replacing R-Co's offset pagination |
| `TaskStore.createInTx` (L161-237) | Task-activation write path — already covered by REQ-047's `Letflow.Engine.TaskActivation.append_multi/6`, a different module entirely, not this requirement's concern |
| `TaskStore.completeInTx` (L304-379), `cancelInTx` (L381-441) | EE-04 task-completion write path — REQ-085's scope, not read |
| `TaskStore.claimTask` (L761-849), `assign` (L851-908), `reassign`/`reassignInTx` (L910-1002) | Task claim/assign/reassign write path (ISS-102, API-04) — REQ-085's scope |
| `TaskError`'s `AlreadyTerminated` variant, `ClaimError`, `AssignError` (full sets, L79-118) | All write-path error shapes (claim/assign/complete conflicts) — this requirement's own error surface (§3) only needs the read-path subset: not-found, pool-exhausted-equivalent (an unhandled DB error, per this project's established residual-risk precedent, §3.5), invalid-input |
| `insertTaskWaitDescriptorInTx` (L1025-1141) | SCH-03 timer-wait bookkeeping — S6 scope (`req047`'s own named, unimplemented `cancel_pending_timers/2` hook), not invoked by any of the three read handlers |

**This table's content is required, verbatim in substance, in `Letflow.Tasks`'s
`@moduledoc`** — AC6's own wording ("states which ... operations were ported and which
were not, rather than describing the boundary approximately") is checked by
CODE-DESIGN-VALIDATOR/REVIEWER against the actual moduledoc text, not against this design
doc alone.

---

## 2. What already exists, untouched by this design

`Letflow.Engine.Task` (`lib/letflow/engine/task.ex`, REQ-043/047, shipped) — schema only,
already has every field this requirement's read path needs: `id`, `instance_id`,
`token_id`, `node_id`, `node_name`, `status` (`Ecto.Enum`, `:pending|:completed|:cancelled`
↔ `"PENDING"|"COMPLETED"|"CANCELLED"`), `assignee_type`/`assignee_ref` (both plain
`:string`, nullable, unvalidated per REQ-047 §4.3), `form_schema` (`:map`),
`output_variables`, `completed_by`, `completed_at`, `cancelled_at`, `inserted_at`/
`updated_at`. **This design adds no field, no migration, no changeset to this module** —
`insert_changeset/2`/`complete_changeset/2` are REQ-047/085's, unchanged.

**Two fields R-Co's `Task` struct carries that Letflow's schema does not, flagged rather
than silently worked around (OQ-1, OQ-2):**

- **`claimed_by`** — R-Co's task-claim mechanism (ISS-102, `TaskStore.claimTask`) writes
  this column; Letflow has never built a `claimed_by` column (confirmed: `grep -rn
  "claimed_by" lib/ priv/` has zero hits outside this design doc). `handleGetById`'s
  response (`serializeTaskDetail`) includes it. **This design's `get_task/2` response
  omits `claimed_by` entirely** rather than hardcoding a permanent `null` — the column
  doesn't exist, and REQ-085 (the write-path requirement that will actually build
  claim/assign) is the correct owner of deciding its final shape. Flagged as OQ-1 for
  REVIEWER/REQ-085's own CODE-DESIGNER, not silently invented here.
- **`correlation_key`** — R-Co's `getById` joins `instance_projections` for this field;
  Letflow's `instance_projections` table has it (confirmed, §0). **This design's
  `get_task/2` DOES join and include it** (§3.2, §6.2) — no gap here, listed alongside
  `claimed_by` only to make clear the two "extra" R-Co response fields were each
  individually checked, not both assumed absent by pattern-matching on "R-Co has a field
  Letflow's schema doesn't."

`Letflow.Api.Context.scoped_repo_opts/1`, `Letflow.Api.Pagination.*`,
`Letflow.Api.Authorization.*`, `Letflow.Api.Response.*`/`Letflow.Api.Error.*` — all
shipped (REQ-072/067/069/066), all read-only dependencies of this design, none modified.

---

## 3. `Letflow.Tasks` — new context module

**New file:** `lib/letflow/tasks.ex` → `Letflow.Tasks`. Plain Ecto context module (no
process, no `gen_statem` — this is a pure read/query surface, matching
`backend_developer_guide.md` §3.2's "no real state machine here" branch), following the
same top-level-context-module shape as `Letflow.Identity`/`Letflow.Definitions`.

### 3.1 `list_tasks/2` — backs `handleList` and (via a caller-supplied scope) `handleInbox`

```
@type task_status :: :pending | :completed | :cancelled

@type assignee_scope ::
        :unfiltered
        | {:explicit_user, user_id :: String.t()}
        | {:principal, principal_scope()}

@type principal_scope :: %{
        user_id: String.t(),
        group_ids: [Ecto.UUID.t()],
        role_names: [String.t()]
      }

@type list_tasks_params :: %{
        optional(:status) => task_status(),
        optional(:instance_id) => Ecto.UUID.t(),
        assignee_scope: assignee_scope(),
        cursor: String.t() | nil,
        page_size: pos_integer()
      }

@spec list_tasks(list_tasks_params(), opts :: [prefix: String.t()]) ::
        {:ok, %{items: [Letflow.Engine.Task.t()], next_cursor: String.t() | nil}}
        | {:error, :invalid_cursor | :wrong_endpoint | :expired}
```

**One function backs both `GET /tasks` and `GET /tasks/inbox`, matching R-Co's own shape**
(`handleInbox` literally builds a `ListTasksParams` and calls `handleList` with it, §0) —
the router (§5) is what decides each endpoint's `assignee_scope` value before calling
this function; `list_tasks/2` itself has no notion of "which endpoint called me."

**Query shape (plain `Ecto.Query`, no raw SQL — INV-7):**

1. Base query: `from(t in Letflow.Engine.Task)`.
2. `status` present → `where: t.status == ^status`.
3. `instance_id` present → `where: t.instance_id == ^instance_id`.
4. `assignee_scope`:
   - `:unfiltered` → no additional `where` clause (every task in the tenant's schema,
     subject only to `status`/`instance_id` above) — the `:all`-scope case (operator/
     admin browsing `GET /tasks` with no `assignee_id` filter, or any non-task-worker role
     calling `GET /tasks/inbox`, §3.4/§5.3).
   - `{:explicit_user, user_id}` → `where: t.assignee_type == "USER" and t.assignee_ref ==
     ^user_id` — the caller-supplied `?assignee_id=` filter on plain `GET /tasks` for a
     caller with `:all` scope (an operator explicitly asking "show me X's tasks";
     R-Co's own `ListTasksParams.assignee_id` with `assignee_type_user_only: true` when a
     row filter isn't otherwise forced, confirmed at `listCursor` L662-668).
   - `{:principal, %{user_id:, group_ids:, role_names:}}` → `where: (t.assignee_type ==
     "USER" and t.assignee_ref == ^user_id) or (t.assignee_type == "GROUP" and t.assignee_ref
     in ^group_ids) or (t.assignee_type == "ROLE" and t.assignee_ref in ^role_names)` — the
     `AllowWithRowFilter` case (task-worker-only caller) **and** `GET /tasks/inbox` for
     that same caller class (§3.4/§5.3). `group_ids`/`role_names` are plain string lists
     built by the router (§5) via `resolve_principal_scope/2` (§3.4) — this function never
     itself calls `Letflow.Identity`.
PROVENANCE (historical, not current decision authority):
5. Cursor: if `params.cursor` is non-`nil`, decode it first (`Letflow.Api.Pagination.
   decode_cursor(cursor, "T:", 2)`, §5's own pre-step per REQ-067 §0.1's "parse/validate
   at the route-handler/call-site layer" convention — `list_tasks/2` receives an
   **already-decoded** `%Cursor{}`'s `inner` value split into `(created_at_us, id)` by the
   caller, not the raw encoded string — see §5.1 for exactly where this split happens).
   Concretely: `list_tasks_params.cursor` in the `@type` above is the **raw encoded
   string** as received from the query param, and `list_tasks/2` itself performs the
   `decode_cursor/4` call and the `(created_at, id)` extraction internally (kept inside
   this function, not the router) — this is the one departure from "router does all
   parsing" stated explicitly: the `(created_at, id)` seek predicate is a Task-specific,
   Ecto-composed `where` clause this module alone knows how to build (`where: {t.
   inserted_at, t.id} < {^decoded_ts, ^decoded_id}`, keyset-paginated as `pagination.zig`'s
   own `(created_at, id) < (...)` comparison ports directly, §0), so decode-then-build-
   where-clause stays one atomic step inside this module rather than split across two.
   `decode_cursor/4`'s own error tuples (`{:error, :invalid_base64}` etc., REQ-067 §5) are
   **not** independently re-exposed by this function's `@spec` — collapsed to the three
   listed above per REQ-067's own atom set, with `:invalid_base64`/`:invalid_cursor` both
   surfacing as `{:error, :invalid_cursor}` here (a route-facing simplification the router
   maps to one 422, matching R-Co's own `errorResult(..., 422, "INVALID_CURSOR", ...)`
   branch for every `decodeCursor` failure kind except `Expired`, which gets its own 410 —
   see §5's error-to-status table).
6. `order_by: [desc: t.inserted_at, desc: t.id]`, `limit: ^(page_size + 1)` (fetch one
   extra row to detect `has_next`, exactly `listCursor`'s own `page_size + 1` convention,
   §0).
7. `Repo.all(query, prefix: prefix)`.
8. `has_next = length(rows) > page_size`; `page = if has_next, do:
   Enum.take(rows, page_size), else: rows`.
9. `next_cursor` — if `has_next`, build via `Pagination.build_raw_cursor("T:",
   last_row.inserted_at_us, last_row.id) |> Pagination.encode_cursor()`
   (`inserted_at_us` = the row's `inserted_at` converted to integer microseconds since
   epoch, the Elixir equivalent of R-Co's `EXTRACT(EPOCH ...) * 1000000` cast, §0);
   `nil` otherwise.
10. Returns `{:ok, %{items: page, next_cursor: next_cursor}}`.

**Sort key note (AC1's "cursor-paginated ... across at least two pages").** `inserted_at`
(mapped from `t.created_at` in R-Co's own `ORDER BY created_at DESC, id DESC`) is the sort
key — `Letflow.Engine.Task`'s `timestamps/1` macro already provides `inserted_at` with
microsecond precision (`:utc_datetime_usec`, req043 §4), matching R-Co's own
microsecond-precision `created_at`. No new column needed.

### 3.2 `get_task/2` — backs `handleGetById`

```
@spec get_task(id :: String.t(), opts :: [prefix: String.t()]) ::
        {:ok, {Letflow.Engine.Task.t(), correlation_key :: String.t() | nil}}
        | {:error, :not_found | :invalid_id}
```

- `Ecto.UUID.cast(id)` first — `:error` → `{:error, :invalid_id}` (no DB round-trip,
  matching this project's now-established "validate UUID shape before any query touches
  it" convention, `req020` §4.2's identical reasoning applied here).
- `{:ok, id}` → a single query joining `Letflow.Engine.Task` to `Letflow.Engine.
  InstanceProjection` on `instance_id`, `select: {t, ip.correlation_key}` (a plain `left_join`
  since a task's parent instance is expected to exist by FK, §0's confirmed `on_delete:
  :restrict`, but `left_join` is used anyway to match R-Co's own `LEFT JOIN` exactly and
  avoid an unnecessary `inner_join`-vs-`left_join` divergence with no behavioral upside).
- No row → `{:error, :not_found}`. Row found → `{:ok, {task, correlation_key}}`.
- **This function does not itself decide tenant scope or authorization** — `prefix` is
  supplied by the caller (the router, via `Context.scoped_repo_opts/1`, §4) exactly the
  way REQ-072's own INV-5 test design (§4 of that design doc) demonstrates: a cross-tenant
  `id` and a truly-nonexistent `id` both resolve to `{:error, :not_found}` through this
  **same** code path, with no branch that could distinguish them (AC3).

### 3.3 `assignee_type`/`assignee_ref` — read as-is, zero interpretation (AC2's premise)

**This design adds no validation, no closed-set check, no default for either column when
reading.** REQ-047 §4.3 (already shipped) established that `assignee_type` is
unvalidated free text at write time (`node.attributes["assignee_type"]`, no default when
absent) and `assignee_ref` is copied verbatim from `node.attributes["role"]`. This
requirement's scoping logic (§3.1 point 4, §3.4) matches on the **literal string values**
`"USER"`/`"GROUP"`/`"ROLE"` — the same three values REQ-047's `Task` struct doc comment
and REQ-083's own requirement text both name — with no other value producing a match in
any `assignee_scope` branch (a row with `assignee_type == "SUPERVISOR"`, or `nil`, simply
never matches the `{:principal, _}` scope's three `or` clauses and is correctly excluded
from a task-worker's/inbox's results, matching AC2's "no task assigned only to a
different user Y" framing generalized to any non-matching assignee).

### 3.4 `resolve_principal_scope/2` — group/role membership, through `Letflow.Identity`, not reimplemented

```
@spec resolve_principal_scope(user_id :: String.t(), opts :: [prefix: String.t()]) ::
        principal_scope()
```

PROVENANCE (historical, not current decision authority):
**This is the requirement's own explicit instruction — "resolve group and role
membership through Letflow.Identity rather than reimplementing the resolution" — and it
is also the one place this design's read path goes beyond what R-Co's own shipped
`listCursor` SQL actually does (flagged prominently, not silently, per §0's own reading
of `store.zig`'s SQL comment block: R-Co's `include_group_membership_for_user` branch
covers `USER`/`GROUP` only — there is no `ROLE` arm anywhere in R-Co's shipped
`listCursor`. REQ-083's own requirement text names all three (`"assigned directly to X,
... to a group X belongs to, and ... to a role X holds"`) and AC2 tests all three
explicitly — this design implements the requirement's text, not R-Co's incomplete
implementation of it, and this divergence must be stated in `Letflow.Tasks`'s moduledoc,
not left for a reader to discover by diffing against R-Co.**

**`Letflow.Identity`/its submodules are a read-only dependency of this run (Step 00
handoff's `owned_modules` explicitly excludes them) — no new function is added to
`Letflow.Identity` or `Letflow.Identity.RoleRegistry`.** Group and role resolution is
built from two direct, `:prefix`-scoped reads against `Identity`-owned schemas —
composed here rather than reimplemented, and (per the rework note in point 2 below) never
routed through an `Identity`-owned function whose own query is not itself tenant-scoped:

1. **Group ids the user belongs to** — a plain `Ecto.Query` against
   `Letflow.Identity.GroupMember` (the existing schema, §0): `from(m in
   Letflow.Identity.GroupMember, where: m.user_id == ^user_id, select: m.group_id) |>
   Repo.all(prefix: prefix)`. This reuses the exact same schema/join shape
   `Letflow.Identity.list_group_members/3` already establishes (§0), inverted (by
   `user_id` instead of `group_id`) — not a new query *pattern*, just the missing
   direction of the existing one. **This is a direct read of an `Identity`-owned table,
   not a reimplementation of `Letflow.Identity`'s own membership-management logic**
   (`add_group_member/3`/`remove_group_member/3` still own all writes to this table; this
   function only ever reads).
2. **Role names the user holds** — derived, not stored directly: a user "holds" a role
   iff the role's bound group (`Letflow.Identity.TenantRole`, the schema `RoleRegistry`
   itself is built on, §0 — each row is `%{name:, group_id:}`) is one of the group ids
   from step 1. **REWORK (rework_count 1, run `WF02-REQ083-20260822`): this design no
   longer calls `Letflow.Identity.RoleRegistry.list_roles/0` for this step.**
   SECURITY-REVIEWER's Step 2c gate (`handoffs/WF02-REQ083-20260822/step-02c-security-reviewer.json`,
   INV-1 FAIL) found that `RoleRegistry.list_roles/0`
   (`lib/letflow/identity/role_registry.ex:38-40`) issues `Repo.all(from(t in TenantRole,
   ...))` with **no `:prefix` option** and no per-request `search_path` mechanism exists
   anywhere in production code — `tenant_role` is a per-tenant-schema table since
   migration `20260819000002_create_tenant_role_tenant_scoped.exs` (Decision 0006), and
   this design's original call to `list_roles/0` would have been the first production
   caller to reach that gap from a live tenant-scoped API surface (either an unhandled
   `undefined_table` crash post-drop of the legacy `public.tenant_role`, or an unscoped
   cross-tenant read pre-drop — both INV-1 violations). This design now specifies a
   **direct, explicitly `:prefix`-scoped query against `Letflow.Identity.TenantRole`**
   instead, composed here exactly the way step 1's `GroupMember` query already is —
   mirroring, not inventing, the codebase's established `Repo.all(query, prefix: prefix)`
   convention (confirmed at e.g. `lib/letflow/identity.ex:247,412,500` and this same
   design's own §3.1 point 7/§3.2): `from(t in Letflow.Identity.TenantRole, where:
   t.group_id in ^group_ids_from_step_1, select: %{name: t.name, group_id: t.group_id})
   |> Repo.all(prefix: prefix)`, mapped to `role.name`. The `prefix` here is the **same**
   `prefix` value already threaded into this function's own `opts` (§4's `[prefix:
   String.t()]` — sourced, transitively, from `Context.scoped_repo_opts/1`'s tenant-schema
   name, never a path/query/header value), so this query is scoped to the calling
   tenant's own schema by construction, identically to `GroupMember`'s own read in
   step 1 and to `list_tasks/2`/`get_task/2`'s own `Repo.all/Repo.one` calls (§3.1 point
   7, §3.2). **This is still a read of an `Identity`-owned table, not a reimplementation
   of `Letflow.Identity.RoleRegistry`'s own role-assignment *write* logic**
   (`upsert_role/2` still owns every write to `tenant_role`; this function only ever
   reads, exactly as originally specified for `GroupMember`) — only the *read mechanism*
   changed, from an unscoped call through `RoleRegistry.list_roles/0` to a directly
   `:prefix`-scoped `Ecto.Query` against the same underlying schema module
   (`Letflow.Identity.TenantRole`), which `Letflow.Identity.RoleRegistry` already depends
   on and re-exports no encapsulation over (it is a plain, public, `use Ecto.Schema`
   struct with ordinary fields, §0 — reading it directly does not reach into
   `RoleRegistry`'s private implementation). **`Letflow.Identity`/its submodules remain a
   read-only dependency of this run** (Step 00's `owned_modules` boundary, unchanged) —
   this fix stays inside `lib/letflow/tasks.ex`, this run's own owned module, and adds no
   function to `Letflow.Identity.RoleRegistry` or `Letflow.Identity` (the alternative
   SECURITY-REVIEWER flagged — a prefix-accepting variant of `list_roles/0` added to
   `RoleRegistry` itself — was considered and rejected here as the higher-friction option
   that crosses this run's `owned_modules` boundary for no benefit the direct-query
   approach doesn't already provide; SECURITY-REVIEWER's own finding named the direct
   query as the lower-friction, in-scope fix).
3. Returns `%{user_id: user_id, group_ids: group_ids, role_names: role_names}`.

**No caching, no memoization across requests.** Both queries run fresh on every call —
flagged as OQ-3 (a performance question, not a correctness one; REQ-083's acceptance
criteria have no latency requirement, and this project's established precedent elsewhere
in S4 — REQ-072's `scoped_repo_opts/1`, REQ-074's group-membership joins — is likewise
"query fresh per request, no caching," so this is consistent, not a new pattern).

### 3.5 Error handling — matches this project's established residual-risk precedent

Every function above returns `{:ok, _} | {:error, atom}` for its *expected* failure
modes (invalid UUID, not found, malformed cursor). **A genuine DB/connection-level
failure (pool exhaustion, connection drop) is not caught and converted anywhere in this
module** — it propagates as a raised exception, matching `Letflow.Identity`'s own
established precedent for simple reads (`req019` §5.1's OQ-4, `req020` §2's identical
note) rather than inventing a new blanket-rescue policy here. R-Co's `PoolExhausted`
(→ 503) has no direct Elixir equivalent in this design; a connection-level failure here
surfaces as an unhandled crash of the single request-handling process, consistent with
this codebase's process-per-request fault model (matching REQ-071's REVIEWER-endorsed
fail-closed reasoning for `TenantStatus`, §0 of `stage-4-api-surface.md`).

---

## 4. Tenant scoping (INV-1, AC4)

**Identical mechanism to every other REQ-073+ route — no new mechanism invented here.**
Every one of the three handlers resolves `Letflow.Api.Context.scoped_repo_opts/1` first
(§0); its `[prefix: schema_name]` result is threaded into every `Letflow.Tasks` call
(`opts` parameter, §3). `scoped_repo_opts/1`'s own structural guarantee (REQ-072 §3.1,
already REVIEWER-confirmed) — its **only** input is `conn.assigns[:auth_context][
:tenant_id]`, never a path/query/header value — is what makes AC4 ("tenant A caller
returns no tenant B task ... identically-named nodes") true by construction: two tenants'
`tasks` tables live in physically separate Postgres schemas, so `Repo.all(query, prefix:
schema_a)` cannot select a row that only exists under `prefix: schema_b`, regardless of
`node_id`/`node_name` collisions between the two.

`{:error, :missing_auth_context | :invalid_tenant_id}` from `scoped_repo_opts/1` is
handled by the router exactly as `Letflow.Routers.Identity`'s existing
`with_authorized_scope/4` already does (§5.2) — `Response.internal_error/1`, no unscoped
query ever attempted (OQ-2 of REQ-072, still open there, resolved *for this router*
by copying the existing precedent rather than deciding a new policy).

---

## 5. `Letflow.Routers.Tasks` — the three routes

**File:** `lib/letflow/routers/tasks.ex` (replaces the current 12-line stub). Mounted at
`/tasks` by `Letflow.Plugs.ApiPipeline` (unchanged mount point, per the existing stub's
own moduledoc).

```
GET /tasks        -> Letflow.Tasks.list_tasks/2               (:TasksList policy key)
GET /tasks/inbox  -> Letflow.Tasks.list_tasks/2 (forced scope) (:TasksList policy key)
GET /tasks/:id    -> Letflow.Tasks.get_task/2                  (:TasksGetById policy key)
```

PROVENANCE (historical, not current decision authority):
**Route-match ordering — `/tasks/inbox` before `/tasks/:id` (a real, checkable
requirement, not a stylistic note):** `Plug.Router`'s `get "/tasks/:id"` would otherwise
also match the literal path segment `"inbox"` as `id = "inbox"`, which would then fail
`Ecto.UUID.cast/1` (§3.2) and misreport as `{:error, :invalid_id}` → 422, instead of
serving the inbox. This design specifies `get "/tasks/inbox"` declared textually **before**
`get "/tasks/:id"` in the router module body, matching R-Co's own `main.zig` dispatch
order (`seg4 == "inbox"` checked before the bare-`:id` branch, §0) and `Plug.Router`'s
documented first-match-wins semantics.

### 5.1 `with_authorized_scope/4` — reused, not reinvented

This design specifies the **same private helper shape** `Letflow.Routers.Identity` already
established (§0, reproduced here for this module rather than shared/extracted — no new
cross-router abstraction is introduced, matching this codebase's existing precedent of
each sub-router carrying its own copy rather than a premature shared behaviour):

```
defp with_authorized_scope(conn, method, path_template, fun)
```

1. `Context.scoped_repo_opts(conn)` — `{:error, _}` → `Response.internal_error(conn)`
   (§4). `{:ok, prefix: _}` → continue.
2. Build `%Authorization.AccessContext{user_id: conn.assigns.auth_context.user_id, roles:
   Authorization.roles_from_strings(conn.assigns.auth_context.roles)}`.
3. `Authorization.evaluate_access(ctx, Authorization.endpoint_policy_key(method,
   path_template))`. `endpoint_policy_key/2` already maps `("GET", "/tasks")` →
   `:TasksList` and `("GET", "/tasks/:id")` → `:TasksGetById` (both shipped, §0) — **no
   change to `Letflow.Api.Authorization` by this requirement.** `/tasks/inbox` is not a
   path `endpoint_policy_key/2` recognizes today; §5.3 covers this explicitly.
4. `decision.kind == :Deny403` → `Response.forbidden(conn, "insufficient permissions")`
   (AC7 — a caller without `TasksRead`, i.e. no role granting `:TasksRead` per
   `Authorization.role_allows?/2`'s existing matrix, gets exactly this on all three
   routes, since all three resolve to `:TasksList`/`:TasksGetById` → `required_permission`
   → `:TasksRead`, §0).
5. Otherwise → `fun.(conn, opts, decision)` (one parameter more than `Identity`'s own
   helper — `decision` is threaded through here because `GET /tasks` and `GET
   /tasks/inbox` both need `decision.task_scope` to build their `assignee_scope`, §5.3;
   `Identity`'s routes never needed this, hence the shape difference is deliberate, not
   an inconsistency to "fix" back to parity).

### 5.2 `handle_list/3` (`GET /tasks`)

PROVENANCE (historical, not current decision authority):
1. Parse query params: `status` (via a small `parse_status_param/1` this router or
   `Letflow.Tasks` defines — `nil` → `{:ok, nil}`; `"PENDING"|"COMPLETED"|"CANCELLED"` →
   `{:ok, :pending|:completed|:cancelled}`; anything else → `{:error, :invalid_status}` →
   `Response.bad_request(conn, "status must be one of PENDING, COMPLETED, CANCELLED")`),
   `instance_id` (via `Ecto.UUID.cast/1`; malformed → `Response.bad_request/2` — this
   design deliberately does **not** silently drop a malformed `instance_id` the way
   R-Co's own `main.zig` does (`catch null`, §0) — matching this project's now-established
   "reject, don't silently default, on malformed caller input" convention already applied
   to `page_size` (REQ-067 §0.1) and `group_id` (`req020` §4.2)), `assignee_id` (raw
   string, no format check — R-Co's own `assignee_id` filter is an opaque string
   comparison, never itself UUID-validated, §0), `cursor` (raw string, passed through),
   `page_size` (via `Pagination.parse_page_size_param/1` then `validate_page_size/1`,
   REQ-067 §0.1's exact composition).
2. Any parse/validation failure short-circuits to the matching `Response.bad_request/2`
   call (400, matching REQ-067 §0.2's project-wide 400 convention for page_size, extended
   here to `status`/`instance_id` for consistency — none of these three is R-Co's own
   422, a deliberate, stated divergence for the same reasoning REQ-067 §0.2 already gives:
   this codebase's REQ-066-established `bad_request/1` is the generic "malformed
   caller-supplied input" status, and R-Co's per-field 422 choices were themselves
   inconsistent across handlers, §0).
3. Build `assignee_scope`:
   - `decision.task_scope == {:own_user_and_groups, user_id}` (i.e., `AllowWithRowFilter`,
     a task-worker-only caller) → **always** `{:principal, Tasks.resolve_principal_scope(
     user_id, opts)}`, regardless of any `assignee_id` query param the caller supplied —
     matching `evaluate_access/2`'s own INV-2 guarantee (§0 of `req069`) that a
     task-worker's row scope can never be widened by a request-supplied filter.
   - `decision.task_scope == :all` and `assignee_id` param present → `{:explicit_user,
     assignee_id}`.
   - `decision.task_scope == :all` and no `assignee_id` param → `:unfiltered`.
4. `Tasks.list_tasks(%{status: ..., instance_id: ..., assignee_scope: ..., cursor: ...,
   page_size: ...}, opts)`.
5. `{:ok, %{items:, next_cursor:}}` → `Response.ok(conn, %{items: Enum.map(items,
   &task_list_item_map/1), next_cursor: next_cursor, count: length(items)})` — matching
   `Pagination.Page`'s own `{items, next_cursor, count}` envelope shape (REQ-067 §2.2),
   built by hand here rather than via `Pagination.page_response/2` since this design's
   items are already an ordinary list, not requiring that helper's generic wrapping (either
   is acceptable; flagged as a non-load-bearing style choice, OQ-4).
6. `{:error, :invalid_cursor}` → `Response.unprocessable(conn, "cursor is not valid for
   this endpoint")` (422, matching R-Co's own `INVALID_CURSOR`/422 for every
   `decodeCursor` failure kind it collapses that atom from, §3.1 point 5).
   `{:error, :wrong_endpoint}` → same 422 (same R-Co status; a `"T:"`-prefix mismatch is
   still "not valid for this endpoint"). `{:error, :expired}` →
   `Response.send_problem(conn, %Error{status: 410, ...})` — **410, not one of
   `Letflow.Api.Error`'s ten already-shipped generic constructors** (none of which covers
   410 today, §0 of `req066`) — this design specifies a new, minimal, locally-built
   `Error.t()` literal for this one case (`type: "...cursor-expired", title: "Cursor
   Expired", status: 410, detail: "cursor has expired; please restart pagination"`,
   `trace_id` populated the same way `send_problem/2` already does, REQ-066 §2.2) rather
   than adding a permanent new public constructor to `Letflow.Api.Error` for a single call
   site — flagged as OQ-6 for REVIEWER: promote to a real `Error.cursor_expired/0`
   constructor if a second call site needs it later (e.g. REQ-080's instance-list
   pagination), not invented as shared infrastructure by this one requirement alone.

### 5.3 `handle_inbox/3` (`GET /tasks/inbox`)

**`endpoint_policy_key/2` has no `("GET", "/tasks/inbox")` clause today (§0) — this
design specifies adding exactly one new clause, `def endpoint_policy_key("GET",
"/tasks/inbox"), do: :TasksList`, to the already-shipped `Letflow.Api.Authorization`
module.** This is the one place this design touches a module outside its own
`owned_modules` list — justified because R-Co's own `handleInbox` delegates its entire
authorization decision to the identical `:TasksList` policy key (`evaluateAccess(...,
.TasksList)`, §0 — `handleInbox` builds `ListTasksParams` and calls `handleList`, which is
where the *only* `evaluateAccess` call for this whole flow happens), so this is a direct,
narrow, single-clause port of an already-decided R-Co mapping, not a new authorization
policy invented by this requirement. Flagged for REVIEWER/SECURITY-REVIEWER to confirm
this one-clause addition to `Letflow.Api.Authorization` is in scope for a "read path"
requirement (it is additive-only, changes no existing clause's behavior, and has no
test-breaking surface — every existing `endpoint_policy_key/2` call site is
pattern-matched by exact string, so adding one new clause cannot alter any existing
route's resolution).

PROVENANCE (historical, not current decision authority):
1. Parse `status`/`instance_id` — **not accepted** by `GET /tasks/inbox` (R-Co's own
   `handleInbox` signature takes only `cursor`/`page_size`, §0) — any `status=`/
   `instance_id=` query param present is silently ignored (not an error; matching R-Co's
   own behavior of simply not reading those params for this endpoint at all, since
   `main.zig`'s inbox branch never populates them, §0). `assignee_id` is likewise not
   accepted (R-Co's `handleInbox` never reads it either). `cursor`/`page_size` parsed
   identically to §5.2 points 1-2.
2. Build `assignee_scope`:
   - `Authorization.is_task_worker_only?(ctx.roles)` (the same predicate
     `evaluate_access/2` itself uses internally, §0 — called here directly by the router,
     not duplicated logic, since it's already a public function) → `{:principal,
     Tasks.resolve_principal_scope(user_id, opts)}` — **this is the concrete design
     element for AC2's four assertions** (direct/group/role inclusion, different-user
     exclusion).
   - Otherwise (any role other than task-worker-only — operator, designer, admin) →
     `:unfiltered` — **matches R-Co's own `handleInbox` behavior exactly**: `actor.
     is_operator_or_above` (R-Co) maps to "not task-worker-only" here, and R-Co's own
     inbox for such a caller sets `effective_assignee_id = null`, i.e. every task in the
     tenant, not merely "assigned to me." This is R-Co's real, considered behavior (an
     operator's "inbox" is deliberately the whole queue), not a bug this design is
     porting by accident — stated explicitly in the moduledoc per this project's "state a
     divergence-from-naive-expectation explicitly" convention, since REQ-083's own
     "per-principal" framing could otherwise be misread as applying uniformly to every
     role.
3. `Tasks.list_tasks(%{assignee_scope: ..., cursor: ..., page_size: ...}, opts)` (no
   `status`/`instance_id` key at all — `Letflow.Tasks.list_tasks/2`'s `@type` marks both
   `optional`, §3.1, so omitting them is a normal call, not a special case).
4. Response/error handling identical to §5.2 points 5-6.

### 5.4 `handle_get_by_id/3` (`GET /tasks/:id`)

1. `Tasks.get_task(id, opts)`.
2. `{:ok, {task, correlation_key}}` → `Response.ok(conn, task_detail_map(task,
   correlation_key))`.
3. `{:error, :not_found}` → `Response.not_found(conn)` — **the same call every other
   cross-tenant/true-not-found path in this codebase makes** (REQ-072 §4.3's own AC4
   demonstration; `get_task/2`'s single code path, §3.2, is what makes AC3 true here by
   the identical structural argument REQ-072 already established, restated for this
   specific caller rather than re-derived).
4. `{:error, :invalid_id}` → `Response.bad_request(conn, "task_id is not a valid UUID")`
   — **400, not R-Co's own 422** (`handleGetById`'s `INVALID_TASK_ID`/422, §0) — same
   stated divergence rationale as §5.2 point 2 (this codebase's established
   malformed-input convention).

### 5.5 Response allowlists (INV-2, AC5)

Hand-built maps, never a `Jason.Encoder`/struct-wholesale encoding — matching
`Letflow.Routers.Identity`'s `user_map/1`/`group_map/1` discipline exactly (§0):

```
@spec task_list_item_map(Letflow.Engine.Task.t()) :: map()
```
Exactly nine keys: `id`, `instance_id`, `node_id`, `node_name`, `status` (the `Ecto.Enum`
dump string, e.g. `"PENDING"`), `assignee_type`, `assignee_ref`, `created_at` (ISO 8601,
via `DateTime.to_iso8601/1` on the schema's own `inserted_at` — a genuine, stated
improvement over R-Co's raw epoch-microsecond integer, matching REQ-066 §0.1's precedent
of stating a Jason-driven correctness/format improvement explicitly rather than silently
diverging), `token_id`. **`form_schema`, `output_variables`, `completed_by`,
`completed_at`, `cancelled_at`, `inserted_at`/`updated_at` (the raw schema fields) are
never included** — this is the concrete AC5 element: a test asserting `Map.keys(map) ==
["assignee_ref", "assignee_type", "created_at", "id", "instance_id", "node_id",
"node_name", "status", "token_id"]` (sorted, or however TEST-DESIGNER orders the
assertion) demonstrates the full key set, not merely "contains no forbidden key."

```
@spec task_detail_map(Letflow.Engine.Task.t(), correlation_key :: String.t() | nil) :: map()
```
The same nine keys as `task_list_item_map/1`, **plus** `correlation_key` and `updated_at`
(ISO 8601) — ten keys total. **No `claimed_by`** (§2's OQ-1). **No `form_schema`/
`output_variables`/`completed_by`/`completed_at`/`cancelled_at`** — flagged as OQ-7: R-Co's
own `serializeTaskDetail` includes `form_schema` (§0) but not `output_variables`/
`completed_by`/`completed_at`/`cancelled_at` (those are write-path/EE-04-completion
fields with no R-Co read-path precedent in this handler); this design **excludes**
`form_schema` too, since no acceptance criterion here names it and REQ-047 §4.4 already
flagged `form_schema` as unpopulated (`nil` today, always) — including a field that is
currently always `nil` for every row in this codebase would be a response contract this
design cannot yet demonstrate is correct. REVIEWER should confirm whether to add it back
once REQ-047's own OQ-3 (form_schema's source) resolves, rather than this design guessing
now.

---

## 6. Cross-module dependencies

| Module | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Task` (REQ-043, shipped, unmodified) | `Letflow.Tasks` → that | Schema reads only |
| `Letflow.Engine.InstanceProjection` (shipped, unmodified) | `Letflow.Tasks` → that | `correlation_key` join, `get_task/2` only |
| `Letflow.Identity.GroupMember` (REQ-074, shipped, unmodified) | `Letflow.Tasks` → that | Direct `:prefix`-scoped read query, `resolve_principal_scope/2` only (§3.4) |
| `Letflow.Identity.TenantRole` (REQ-020, shipped, unmodified) | `Letflow.Tasks` → that | Direct `:prefix`-scoped read query, `resolve_principal_scope/2` only (§3.4) — **rework (rework_count 1): no longer via `Letflow.Identity.RoleRegistry.list_roles/0`, which lacks `:prefix` scoping (SECURITY-REVIEWER Step 2c INV-1 FAIL); this design now reads the `TenantRole` schema directly with the caller's `prefix`, same mechanism as the `GroupMember` row above** |
| `Letflow.Api.Context.scoped_repo_opts/1` (REQ-072, shipped, unmodified) | `Letflow.Routers.Tasks` → that | Every handler's first call (§4) |
| `Letflow.Api.Pagination.*` (REQ-067, shipped, unmodified) | `Letflow.Tasks`/`Letflow.Routers.Tasks` → that | Cursor decode/encode, page-size parse/validate |
| `Letflow.Api.Authorization.*` (REQ-069, shipped) | `Letflow.Routers.Tasks` → that | **One new clause added** (`endpoint_policy_key("GET", "/tasks/inbox")`, §5.3) — the only non-`Letflow.Tasks`/non-router file this design touches |
| `Letflow.Api.Response`/`Letflow.Api.Error` (REQ-066, shipped, unmodified) | `Letflow.Routers.Tasks` → that | Every response/error path (§5) |

---

## 7. DB objects touched

**None.** No migration. `tasks`, `instance_projections`, `group_members`, `tenant_role`
all already exist with every column this design reads. See OQ-5 for the one flagged,
not-mandated performance question (supporting indexes).

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-TR83-1 | Tenant scope for all three handlers comes exclusively from `Context.scoped_repo_opts/1`'s `[prefix: _]`, never a path/query/header value | §4 |
| INV-TR83-2 | `AllowWithRowFilter`'s task-worker row scope can never be widened by a caller-supplied `assignee_id`/`instance_id`/`status` param | §5.2 point 3, §5.3 point 2 |
| INV-TR83-3 | Cross-tenant and never-existed `get_task/2` lookups are the same code path, same `{:error, :not_found}`, same `Response.not_found/1` call | §3.2, §5.4 |
| INV-TR83-4 | Every serialized response is a hand-built allowlist map; no `Jason.Encoder` derive, no struct-wholesale encoding | §5.5 |
| INV-TR83-5 | `resolve_principal_scope/2` performs only reads against `Identity`-owned schemas — zero writes, zero reimplementation of `Letflow.Identity`'s own membership-management logic — and both of its two queries (`GroupMember`, `TenantRole`) are themselves explicitly `:prefix`-scoped to the caller's tenant, not routed through any unscoped `Letflow.Identity` function | §3.4 |
| INV-TR83-6 | All three routes require `:TasksRead` (via `evaluate_access/2`'s existing `:TasksList`/`:TasksGetById` → `required_permission` chain, unchanged); `Deny403` → 403 on every one | §5.1 |

---

## 9. Acceptance-criteria traceability

PROVENANCE (historical, not current decision authority):
| REQ-083 acceptance criterion (verbatim) | Concrete design element |
|---|---|
| "each of the three handlers has an end-to-end test through the real router asserting status and response shape, with list and inbox cursor-paginated via REQ-067 across at least two pages" | §5.2-§5.4 (all three routes wired through the real `Letflow.Routers.Tasks`); §3.1 points 5-9 (cursor mechanism reused from REQ-067 verbatim) — TEST-DESIGNER's job to write the ≥2-page test, this design's job is that the mechanism supports it (no dup/gap, same guarantee REQ-067 §10 already establishes) |
| "the inbox for user X returns tasks assigned directly to X, tasks assigned to a group X belongs to, and tasks assigned to a role X holds, and returns no task assigned only to a different user Y in the same tenant -- four assertions in explicit tests" | §3.1 point 4 (`{:principal, _}` scope's three `or` clauses), §3.4 (group/role resolution mechanism), §5.3 point 2 (inbox forces this scope for task-worker-only callers) |
| "a task id belonging to another tenant returns the same response as a nonexistent id, demonstrated by a test (INV-5)" | §3.2 (single code path), §5.4 point 3 (`Response.not_found/1`, no detail param — REQ-066 INV-5 mechanism reused) |
| "listing tasks as a tenant A caller returns no tenant B task when both tenants have tasks on identically-named nodes, demonstrated by a test seeding both (INV-1)" | §4 (schema-per-tenant scoping, `scoped_repo_opts/1`'s structural guarantee) |
| "the serialised task response contains an explicit field allowlist and does not encode the Ecto struct wholesale, demonstrated by a test asserting the full key set (INV-2)" | §5.5 (`task_list_item_map/1`/`task_detail_map/1`, exact key enumeration) |
| "the moduledoc states which src/tasks/store.zig query operations were ported and which were not, rather than describing the boundary approximately" | §1 (full ported/not-ported table, required verbatim in substance in `Letflow.Tasks`'s moduledoc) |
| "a caller without TasksRead receives 403 on all three endpoints" | §5.1 point 4 (shared `with_authorized_scope/4` helper, all three routes) |
| "No implementation code (.ex/.exs bodies) — signatures and type shapes only" | Every code block above is a `@spec`, a type, a field table, or an algorithm-shape description — no `def ... do ... end` with real logic |

---

## 10. Open questions — explicitly listed, not silently resolved

- **OQ-1 (MAJOR, cross-requirement).** `claimed_by` has no Letflow schema column;
  `get_task/2`'s response omits it entirely rather than inventing one. REQ-085's own
  CODE-DESIGNER should confirm this is the right deferral (add the column/field when
  claim/assign actually lands) rather than this requirement guessing the eventual shape.
- **OQ-2 (MINOR).** `correlation_key` — confirmed present and included; listed only to
  show it was checked, not a real open question.
- **OQ-3 (MINOR, performance).** `resolve_principal_scope/2` runs two fresh queries per
  `GET /tasks/inbox`/task-worker `GET /tasks` call, no caching. Consistent with this
  project's existing per-request-fresh-query precedent elsewhere in S4; flagged only in
  case REVIEWER wants a different policy stated explicitly.
- **OQ-4 (MINOR, style).** Hand-built `%{items:, next_cursor:, count:}` response map vs.
  `Letflow.Api.Pagination.page_response/2`. Either produces the same JSON shape; left to
  ELIXIR-DEV.
- **OQ-5 (MINOR, performance).** No new index on `tasks` for `(status)`,
  `(assignee_type, assignee_ref)`, or `(inserted_at, id)` (the keyset-pagination sort key)
  — R-Co's own `idx_task_pending`/`idx_task_status` were explicitly deferred to "S4's
  tasks routes" by REQ-043's own migration header (§0). This requirement's acceptance
  criteria have no performance requirement, so this design does not mandate adding one —
  flagged for REVIEWER to decide whether ELIXIR-DEV should add a supporting migration
  (`create index(:tasks, [:inserted_at, :id])` at minimum, for keyset-pagination
  correctness-at-scale rather than result correctness, which does not depend on an index)
  as part of this requirement or defer it further.
- **OQ-6 (MINOR).** A locally-built 410 `Error.t()` literal for cursor expiry (§5.2 point
  6) instead of a new `Letflow.Api.Error.cursor_expired/0` public constructor. Flagged for
  promotion to a shared constructor once a second call site exists (e.g. REQ-080).
- **OQ-7 (MINOR).** `task_detail_map/2` excludes `form_schema` (always `nil` today per
  REQ-047 §4.4's own OQ-3) despite R-Co's `serializeTaskDetail` including it. Flagged for
  REVIEWER; add back once REQ-047's OQ-3 (form_schema's source) resolves.
- **OQ-8 (MINOR, scope note).** §5.3 adds one clause to `Letflow.Api.Authorization`
  (outside this design's nominal `owned_modules`, §0) — justified as a narrow, additive,
  R-Co-precedented single-clause port. Flagged explicitly per this project's "don't
  silently touch a file outside scope" discipline, rather than silently including the
  diff with no note.
