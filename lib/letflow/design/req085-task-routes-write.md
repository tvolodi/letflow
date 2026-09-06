# REQ-085 — Task routes 2/2, write path (`Letflow.Tasks`, `Letflow.Engine`, `Letflow.Routers.Tasks`)

PROVENANCE (historical, not current decision authority):
**Requirement:** REQ-085 (`docs/requirements.yaml`, stage S4; full `description` and all 7
`acceptance_criteria` read directly from that entry —
`grep -n "id: REQ-085" -A 45 docs/requirements.yaml`).
**Run:** `WF02-REQ085-20260822`, WF-02 Step 1.
**Owner (implementer):** `ELIXIR-DEV`.
**Ports:** `src/api/routes/tasks.zig`'s `handleComplete` (L341, EE-04), `handleClaim`
(L551), `handleAssign` (L628), `handleReassign` (L736) — the write half of the 7-handler
file REQ-083 already split (read third: `handleList`/`handleGetById`/`handleInbox`). Plus
only the `src/tasks/store.zig` write operations these four handlers actually invoke
(`claimTask` L761-849, `assign` L851-908, `reassign`/`reassignInTx` L910-1002) —
`completeInTx`/`cancelInTx` are **not** ported by this requirement; `handleComplete`
routes to REQ-048's already-shipped `Letflow.Engine.complete_task/3` instead (see §0's
requirement text quote and §3.1).
**No implementation code below** — signatures, `@spec`-style types, and field/shape
tables only, matching REQ-083's design doc's own convention and rigor.

---

## 0. Sources read for this design

- This run's Step 00 handoff context (`context.requirement_text`, `task.
  acceptance_criteria`) and `docs/requirements.yaml` REQ-085's own entry (scoped `grep`,
  not the whole file) — all 7 acceptance criteria, quoted verbatim in §9.
- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's procedure.
- `docs/guides/backend_developer_guide.md`, `docs/anti-patterns.md`.
- `lib/letflow/design/req083-task-routes-read.md` (full) — this design's own structural
  template, and the load-bearing prior decision it makes explicit as **OQ-1**: `claimed_by`
  has no Letflow schema column, and REQ-085's own CODE-DESIGNER (this document) is the
  correct owner of deciding claim's final shape rather than REQ-083 guessing it. §3.3
  below is that decision.
- `lib/letflow/routers/tasks.ex` (REQ-083, full, as shipped) — the `with_authorized_scope/4`
  preamble shape (steps: scoped prefix, then `Authorization.evaluate_access/2`, `Deny403`
  → `Response.forbidden/2`, else `fun.(conn, opts, decision)`), the response-map-allowlist
  discipline (`task_list_item_map/1`/`task_detail_map/2`, hand-built maps, exact key
  enumeration, never `Jason.Encoder`/struct-wholesale), and the query-param-parsing
  convention (reject malformed input with 400, never silently default) — all reused
  verbatim in shape by this design, not reinvented.
- `lib/letflow/tasks.ex` (full, as shipped) — `resolve_principal_scope/2`'s exact
  signature and implementation (`group_ids` via a direct `:prefix`-scoped query against
  `Letflow.Identity.GroupMember`, `role_names` via a direct `:prefix`-scoped query against
  `Letflow.Identity.TenantRole`) — this is the **only** group/role resolution path this
  design's `claim_task/3` uses; no second resolution path is introduced (§3.3).
- `lib/letflow/engine.ex` — full moduledoc (all sections, including "EE-12 (REQ-055) —
  lock inventory and cross-instance isolation" and its "Lock ordering" paragraph) plus
  `complete_task/3`'s full implementation: `@type complete_attrs`/`complete_opts`/
  `complete_error`/`complete_result`, `complete_task/3` itself (lines ~1319-1343),
  `run_complete_task/6` (~1375-1434), `fetch_and_lock_task/3` (~1485-1495),
  `fetch_and_lock_instance_projection/3` (~1500-1510), and `interpret_complete_result/1`'s
  full tail (both success clauses and the catch-all `{:error, _failed_step, reason,
  _changes} -> {:error, reason}` clause, ~2324-2355). Confirmed: `complete_task/3` is the
  **only** function this design's `handleComplete` may call for the completion
  transition; its row-locking already produces `{:error, {:task_not_pending, :completed |
  :cancelled}}` for a double-transition attempt — §3.1/§5.5 map that (and only that
  mechanism) to the 409 problem document. No second existence-check-then-transition
  pattern is introduced.
- `lib/letflow/engine/task.ex` (full, as shipped) — confirmed `insert_changeset/2` and
  `complete_changeset/2` are the only two changesets today; neither casts `assignee_type`/
  `assignee_ref`. §3.4 below specifies one new changeset function on this existing schema
  module (no migration) for claim/assign/reassign's writes.
- `lib/letflow/api/authorization.ex` (full, as shipped) — confirmed `endpoint_policy_key/2`
  already has clauses for `("POST", "/tasks/:id/complete") -> :TasksComplete`,
  `("POST", "/tasks/:id/assign") -> :TasksAssign`, `("POST", "/tasks/:id/reassign") ->
  :TasksReassign`, and `required_permission/1` maps both `:TasksAssign` and
  `:TasksReassign` to the `:TasksAssign` permission. **No existing clause for `("POST",
  "/tasks/:id/claim")`** — §3.2 resolves this. Also confirmed the exact five-role
  permission matrix (`role_allows?/2`): `TASK_WORKER` holds `:TasksComplete` but **not**
  `:TasksAssign`; `PROCESS_OPERATOR` and `PLATFORM_ADMIN` hold both. This is load-bearing
  for §3.2's claim-permission decision.
- `lib/letflow/api/response.ex`, `lib/letflow/api/error.ex` (full, as shipped) —
  `Response.conflict/2` → `Error.conflict/1` (409, arbitrary `detail`) is the existing 409
  helper reused for every `{:task_not_pending, _}`/assignment-conflict mapping below; no
  new problem-document shape is invented.
- `lib/letflow/api/validation.ex` (full, as shipped) — `Validation.validate/2` +
  `Validation.problem/1` (422, `Error.unprocessable/1` with a populated `errors` list) is
  the existing request-body-field-constraint mechanism, reused for `assign`/`reassign`'s
  `user_id` body field, matching `Letflow.Routers.Identity`'s own `handle_create/2`
  precedent (`@create_schema` + `Validation.validate/2` call) exactly.
- `lib/letflow/routers/identity.ex` (full, as shipped) — confirmed the established
  "direct `Authorization.evaluate_access/2` call from inside a route module, not a plug"
  pattern this design's own `with_authorized_scope/4` mirrors (REQ-131, the mandatory-auth-
  plug requirement, is still `status: pending` — `grep -n "id: REQ-131" -A 6
  docs/requirements.yaml` confirmed). `Letflow.Routers.Tenants` uses the identical
  pattern for its own write routes (`post "/"`, `patch "/:slug"`, `post "/:slug/
  deactivate"`, `post "/:slug/reactivate"`) — two independent existing write-path
  sub-routers, not one, both calling `evaluate_access/2` directly and documenting it as
  temporary pending REQ-131.
- `docs/agents/instructions/security-invariants.md` — INV-1, INV-5, INV-7, INV-8 read in
  full (each section, plus "How to verify" and the "Applicability note").
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\api\routes\tasks.zig` — `handleComplete` (L341-
  ~470, including the ISS-0619 GROUP/ROLE-pool ownership-check block this design does
  **not** port, see §3.1's scope note), `handleClaim` (L551-608), `handleAssign` (L628-
  713), `handleReassign` (L716-820), `extractUserIdFromBody` (L823-841).
PROVENANCE (historical, not current decision authority):
- `C:\Users\tvolo\dev\ai-dala\R-Co\src\tasks\store.zig` — `claimTask` (L761-829,
  including its atomic conditional-`UPDATE`-then-diagnostic-`SELECT` shape and its
  `claimed_by`-column-only `WHERE` clause, which never inspects `assignee_type`/
  `assignee_ref`), `assign` (L851-908, its `WHERE ... assignee_ref IS NULL` precondition),
  `reassign`/`reassignInTx` (L910-1002, its `WHERE ... assignee_ref IS NOT NULL`
  precondition) — full text of all three read for the exact preconditions §3.4-§3.6 below
  translate (with one deliberate, stated divergence for `claim_task/3` alone, see §3.4).

---

## 1. Genuine schema/semantics gap — resolved here (claimed_by vs. assignee_type/assignee_ref)

**R-Co's `claimTask` and Letflow's required claim semantics are two different things,
not one function with a missing column.** R-Co's `store.claimTask` operates on a
separate `claimed_by` column (`WHERE id = $1 AND claimed_by IS NULL AND status =
'PENDING'`) that **never inspects `assignee_type`/`assignee_ref` at all** — in R-Co, any
authenticated caller with `TasksComplete` can claim any unclaimed `PENDING` task
regardless of who/what it is assigned to; `assignee_type`/`assignee_ref` and
`claimed_by` are two independent, simultaneously-populatable dimensions on the same row.

**REQ-085's own requirement text and AC5 describe a different mechanism**: "claiming a
task assigned to a different user, or to a group the caller does not belong to, must
fail." This is **not** describable in terms of a `claimed_by IS NULL` check at all — it
is a group/role-membership-aware check against `assignee_type`/`assignee_ref`, the same
two columns REQ-047 already populates at task-activation time and REQ-083's read path
already scopes by. **Decision (resolves REQ-083's own OQ-1): no migration, no new
`claimed_by` column.** `claim_task/3` (§3.4) is specified as **atomic conditional
self-assignment**: allowed when the task is currently unassigned, or assigned to a
group/role the caller belongs to; rejected when assigned to a specific different user or
a group/role the caller does not belong to. A successful claim writes `assignee_type:
"USER", assignee_ref: <caller's user_id>` — the same two columns `assign_task/4`/
`reassign_task/4` write, via the same new changeset (§3.4).

**Why this is sufficient, not a compromise:** every REQ-085 acceptance criterion
claim/assign/reassign name (AC4's "exactly one winner" under concurrent claims, AC5's
group/role rejection) is achievable with `assignee_type`/`assignee_ref` alone plus
row-locking (§4), matching `complete_task/3`'s own already-established row-lock
discipline. A `claimed_by` column would add a **third** state dimension with no
acceptance criterion asking for it, and would leave REQ-083's already-shipped response
maps (which correctly omit `claimed_by` today) needing a follow-up change this
requirement has no reason to force. Not ported: R-Co's `ClaimError.AlreadyClaimed`
variant has no Letflow equivalent — a task already `assignee_type: "USER"` for a
*different* user maps to this design's own `:assigned_to_other_user` (§3.4), a
semantically equivalent but not identically-named outcome, since Letflow's claim has no
separate "claimed" boolean to be independently true.

---

## 2. Claim's permission gate — resolved here (`:TasksComplete`, not `:TasksAssign`)

**Decision: `POST /tasks/:id/claim` maps to the same `:TasksComplete` policy key
`POST /tasks/:id/complete` already uses — not a new `:TasksClaim` key, and not
`:TasksAssign`.** Two independent lines of evidence, both read in full at §0:

PROVENANCE (historical, not current decision authority):
1. **R-Co itself.** `handleClaim` (`tasks.zig` L568-572) calls `evaluateAccess(...,
   .TasksComplete)` — not `.TasksAssign`. R-Co treats claiming as "any caller who can
   complete tasks may claim one," an operator-adjacent action available to ordinary task
   workers, not an operator-only administrative action.
2. **Letflow's own permission matrix would make claim unusable by its primary caller
   otherwise.** `role_allows?/2` (`lib/letflow/api/authorization.ex`, confirmed at §0)
   grants `TASK_WORKER` the `:TasksComplete` permission but **not** `:TasksAssign`. A
   `TASK_WORKER`-only caller is exactly who needs to claim a group/role-assigned task
   before completing it (the whole point of AC5's group/role-membership check — a task
   worker claiming a task assigned to their own group). Mapping claim to `:TasksAssign`
   would make claiming impossible for the one role class REQ-085's own text is written
   around, and would silently invert R-Co's considered behavior in the process.

**This resolves AC7's own wording precisely** ("a caller without `TasksComplete` cannot
complete and a caller without `TasksAssign` cannot assign or reassign" — conspicuously
silent on claim's own gate, per the task brief's own observation): claim is gated by
`:TasksComplete`, the same permission AC7 already names for `handleComplete`, so AC7's
test coverage for "a caller without `TasksComplete` cannot complete" doubles, by the same
mechanism, as "a caller without `TasksComplete` cannot claim" — TEST-DESIGNER should add
one explicit assertion for claim's own 403 case rather than assuming AC7's literal text
already covers it (it names `complete` only), but the underlying gate is the same one.

**Mechanism:** `lib/letflow/api/authorization.ex` gets exactly one new, additive
`endpoint_policy_key/2` clause: `def endpoint_policy_key("POST", "/tasks/:id/claim"), do:
:TasksComplete` — placed immediately after the existing `("POST", "/tasks/:id/complete")`
clause. No new `endpoint_policy_key()` type member, no new `permission()` type member, no
`required_permission/1` change (the existing `key in [:TasksComplete]` — actually a bare
`def required_permission(:TasksComplete), do: :TasksComplete`, confirmed at §0 — clause
already covers it once `endpoint_policy_key/2` maps claim's path to that atom). This is
the same class of change REQ-083 already made for `/tasks/inbox` → `:TasksList` (one
additive clause, no existing clause's behavior altered, every call site matched by exact
string) — flagged prominently per this project's "state a file touched outside nominal
scope explicitly" convention, not silently included.

---

## 3. `Letflow.Tasks` — new write functions (extends REQ-083's context module)

### 3.0 Which module owns claim/assign/reassign — `Letflow.Tasks`, not `Letflow.Engine`

**Decision: `claim_task/3`, `assign_task/4`, `reassign_task/4` are new functions on
`Letflow.Tasks` (`lib/letflow/tasks.ex`), not on `Letflow.Engine`.** `handleComplete`
alone routes to `Letflow.Engine.complete_task/3` (§5.5) — that one is non-negotiable per
REQ-085's own text ("COMPLETION IS THE ENGINE ENTRY POINT... routes to the engine's
completion function"), because completion drives a real transition: output variables
merge into instance variables, the token advances. **Claim/assign/reassign do neither.**
None of the three touches `instance_projections` or `tokens` at all — they mutate
exactly one `tasks` row's `assignee_type`/`assignee_ref` columns and nothing else, with
no token movement, no instance-variable merge, no `TASK_COMPLETED`-class event to
append. Putting them in `Letflow.Engine` would misstate what that module's job is (EE-12's
own moduledoc, §0, scopes its lock inventory explicitly to `create/2`, `complete_task/3`,
`cancel_instance/3` — three functions that all drive instance/token state; claim/assign/
reassign would be four lock entries added to a table whose entire premise is
"instance-scoped engine transitions," for locks that never touch an instance-scoped row
beyond the task's own FK). `Letflow.Tasks` already owns "the `tasks`-table surface that
is not a full engine transition" (REQ-083's read path) and already owns
`resolve_principal_scope/2`, which `claim_task/3` needs directly (§3.4) — extending it
for these three writes keeps one module owning that boundary, symmetric with `Letflow.
Engine` owning "task completion is an engine transition."

**This module's own lock-inventory statement (mirroring EE-12's style, required in the
moduledoc per REQ-085's own "route through it rather than adding a second locking
scheme" instruction):** every `lock("FOR UPDATE")` acquired by `claim_task/3`/
`assign_task/4`/`reassign_task/4` is `fetch_and_lock_task/3` (§3.4, a **new, private**
function in this module — not `Letflow.Engine`'s own private function of the same name,
which is unreachable outside `engine.ex`), filtered `where t.id == ^task_id`.
**Single-row**, scoped to exactly the one `tasks` row the path parameter names, which
FK-scopes to exactly one `instance_id` — the identical single-row shape `Letflow.Engine`'s
own `fetch_and_lock_task/3` already uses for `complete_task/3` (§0), duplicated
deliberately (three-line query, not worth a cross-module extraction for one duplicate —
matching REQ-083's own stated reasoning for why `with_authorized_scope/4` is duplicated
per-router rather than shared, §0). No lock in this module ever touches
`instance_projections` or `tokens`. **No global or table-level lock** — same structural
guarantee EE-12 states for `Letflow.Engine`, restated here since it is a distinct module.

### 3.1 Locking shape — `Ecto.Multi` + `SELECT ... FOR UPDATE`, not a bare conditional `UPDATE`

PROVENANCE (historical, not current decision authority):
**Decision: every one of the three new functions uses the same `Ecto.Multi` +
row-lock-then-check-in-Elixir shape `complete_task/3` already established — not R-Co's
own bare `UPDATE ... WHERE ... RETURNING` atomicity-without-an-app-level-lock idiom.**
R-Co's `store.zig` relies on Postgres's own single-statement atomicity (the `UPDATE`'s
`WHERE` clause is itself the concurrency check; 0 rows updated means "lost the race,"
resolved by a follow-up diagnostic `SELECT`). This design deliberately does not port
that idiom, for a reason stated directly by REQ-085's own requirement text: "read
REQ-047/048's row-locking approach and route through it rather than adding a second
locking scheme in the route layer" — and, by extension, in this module's own write path.
This codebase's one existing precedent for "two concurrent writers, exactly one winner"
(`complete_task/3`, EE-12) already committed to `SELECT ... FOR UPDATE` + an explicit
post-lock check inside `Ecto.Multi.run/3`, not a bare conditional `UPDATE`. Introducing a
second concurrency idiom in the same table (`tasks`) that some callers reach via
row-locking and others reach via a racing bare `UPDATE...WHERE` would itself be "a second
locking scheme" in the sense REQ-085's text warns against, even though neither idiom is
wrong in isolation — consistency with the one already-reviewed idiom is the deciding
factor, not a claim that R-Co's approach is unsafe.

**Concrete shape, all three functions:**
```
Ecto.Multi.new()
|> Multi.run(:task, fn repo, _changes -> fetch_and_lock_task(repo, task_id, prefix) end)
|> Multi.run(:scope, fn _repo, _changes -> ... end)   # claim_task/3 only, see §3.4
|> Multi.run(:apply, fn repo, changes -> decide_and_apply(repo, changes, ...) end)
|> Repo.transaction()
```
`fetch_and_lock_task/3` (private, this module): identical shape to `Letflow.Engine`'s own
(§0) — `Task |> where([t], t.id == ^task_id) |> lock("FOR UPDATE") |> repo.one(prefix:
prefix)`, `nil -> {:error, :task_not_found}`, `%Task{status: :pending} = task -> {:ok,
task}`, `%Task{status: status} -> {:error, {:task_not_pending, status}}`. This single
helper is shared by all three functions' first `Multi.run` step (one private function,
three callers, inside this one module — not duplicated three times).

**Why this produces "exactly one winner" (AC4).** Two concurrent `claim_task/3` calls on
the same `task_id`: transaction A's `SELECT ... FOR UPDATE` locks the row; transaction
B's identical query **blocks** at the database level until A commits or rolls back. Once
A commits (having written `assignee_type: "USER", assignee_ref: A's user_id`), B's lock
acquires and B's `repo.one/2` call returns the **post-A-commit** row — B's own
`:apply` step then evaluates `assignee_type == "USER" and assignee_ref != B's user_id`
and returns `{:error, :assigned_to_other_user}` deterministically, not a raised
exception, not a 500. Exactly one of the two transactions ever calls `repo.update/2`, the
other only ever reads.

### 3.2 New schema changeset — `Letflow.Engine.Task.assignment_changeset/2` (no migration)

**One new function on the existing `lib/letflow/engine/task.ex` schema module** (not a
new file, not a migration): `assignment_changeset/2`, `cast(attrs, [:assignee_type,
:assignee_ref])`, `validate_required([:assignee_type, :assignee_ref])`. `@spec
assignment_changeset(t(), attrs :: %{assignee_type: String.t(), assignee_ref: String.t()})
:: Ecto.Changeset.t()`. Both fields are always written together (never one without the
other) by every one of claim/assign/reassign's successful-write branches (§3.4-§3.6) —
the same "paired write" discipline REQ-047 §4.3 already established at task-activation
time, restated here for the claim/assign/reassign write path. `insert_changeset/2`/
`complete_changeset/2` are unchanged; this is a third, additive changeset function.

### 3.3 `resolve_principal_scope/2` — reused unchanged, claim's only group/role source

`claim_task/3` (§3.4) calls the **existing** `Letflow.Tasks.resolve_principal_scope/2`
(§0) with the *claiming* caller's `user_id` — the identical function REQ-083's inbox/
task-worker-list scoping already uses, per REQ-085's own explicit instruction ("Resolve
group and role membership through Letflow.Identity ... the same resolution REQ-083's
inbox uses -- one resolution path, not two that can disagree"). **No new function is
added to `Letflow.Identity` or any of its submodules; no second query pattern is
introduced.** `assign_task/4`/`reassign_task/4` never call this function — see §3.5's own
note on why the operator-driven assign/reassign path has no group/role check at all
(matching R-Co exactly: `store.assign`/`store.reassign` never validate the target
`user_id` against any membership table).

### 3.4 `claim_task/3`

```
@type claim_attrs :: %{required(:actor_id) => Ecto.UUID.t()}
@type claim_opts :: [prefix: String.t()]

@type claim_error ::
        {:error, :invalid_task_id}
        | {:error, :task_not_found}
        | {:error, {:task_not_pending, status :: :completed | :cancelled}}
        | {:error, :assigned_to_other_user}
        | {:error, :assignee_group_not_member}
        | {:error, :assignee_role_not_held}
        | {:error, :not_claimable}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}

@spec claim_task(
        task_id :: String.t(),
        attrs :: claim_attrs(),
        opts :: claim_opts()
      ) :: {:ok, Letflow.Engine.Task.t()} | claim_error()
```

**Pre-transaction (design mirrors `complete_task/3`'s own pre-transaction phase, §0):**
`Ecto.UUID.cast(task_id)` — `:error` → `{:error, :invalid_task_id}` before any I/O.

**Atomic phase** (one `Ecto.Multi`, per §3.1):
1. `:task` step — `fetch_and_lock_task/3` (§3.1/§3.0).
2. `:scope` step — `{:ok, Letflow.Tasks.resolve_principal_scope(attrs.actor_id, prefix:
   prefix)}` (never fails; §3.3's function has no error return).
3. `:apply` step — given the locked `task` and the resolved `principal_scope`, decide
   claimability and, if claimable, write the update:

   | `task.assignee_type` | `task.assignee_ref` condition | Outcome |
   |---|---|---|
   | `nil` | (unassigned) | **Claimable** — write `assignee_type: "USER", assignee_ref: actor_id` via `assignment_changeset/2`, `repo.update(prefix: prefix)` |
   | `"USER"` | `== actor_id` | **No-op success** — already claimed by this same caller; return the task unchanged, no write attempted (idempotent re-claim, not an error) |
   | `"USER"` | `!= actor_id` | `{:error, :assigned_to_other_user}` |
   | `"GROUP"` | `in principal_scope.group_ids` | **Claimable** — same write as the unassigned case |
   | `"GROUP"` | not in `principal_scope.group_ids` | `{:error, :assignee_group_not_member}` |
   | `"ROLE"` | `in principal_scope.role_names` | **Claimable** — same write |
   | `"ROLE"` | not in `principal_scope.role_names` | `{:error, :assignee_role_not_held}` |
   | any other string, or a value not matching REQ-047's own three literal values | — | `{:error, :not_claimable}` — mirrors REQ-083 §3.3's own "no other value produces a match" treatment of unrecognized `assignee_type` values, applied here to the write side |

4. Result assembly: `{:ok, %{apply: task}}` → `{:ok, task}`. `{:error, _step, reason,
   _changes}` → `{:error, reason}` (the identical catch-all unwrap `interpret_
   complete_result/1`'s own tail already establishes, §0 — restated here since this is a
   different function/module, not a shared helper).

**This table is the concrete design element for AC5's two explicit tests** (different-
user rejection, different-group rejection) **and AC4's concurrent-claim test** (§3.1's
locking argument: the loser's `:apply` step always lands in the `"USER"`/`!= actor_id`
row of this table once the winner's write is visible, never a 500).

### 3.5 `assign_task/4`

```
@type assign_attrs :: %{required(:user_id) => String.t()}
@type assign_opts :: [prefix: String.t()]

@type assign_error ::
        {:error, :invalid_task_id}
        | {:error, :missing_user_id}
        | {:error, :task_not_found}
        | {:error, {:task_not_pending, status :: :completed | :cancelled}}
        | {:error, :already_assigned}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}

@spec assign_task(
        task_id :: String.t(),
        attrs :: assign_attrs(),
        opts :: assign_opts()
      ) :: {:ok, Letflow.Engine.Task.t()} | assign_error()
```

Pre-transaction: `Ecto.UUID.cast(task_id)` (`:invalid_task_id`); `attrs.user_id` presence/
non-empty-string check (`:missing_user_id`) — **this function's own defensive guard**;
the router's own `Validation.validate/2` call (§5.4) is expected to already have rejected
a missing/empty `user_id` before this function is ever reached, so this guard is
belt-and-suspenders (INV-8), not the primary enforcement point, matching `complete_task/3`'s
own `fetch_output_variables/1` precedent of validating its own attrs defensively even
though the router validates first.

Atomic phase: `:task` step (`fetch_and_lock_task/3`, §3.1); `:apply` step — `task.
assignee_ref == nil` → **assignable**, write `assignee_type: "USER", assignee_ref:
attrs.user_id` (`assignment_changeset/2`); `task.assignee_ref != nil` (already `"USER"`/
`"GROUP"`/`"ROLE"`-assigned) → `{:error, :already_assigned}`. This is R-Co's own
precondition (`assign`'s `WHERE ... assignee_ref IS NULL`, §0) ported exactly — **no
group/role-membership check on the target `user_id`, matching R-Co exactly**: an
operator may assign a `PENDING` task to any `user_id` string, validated for presence
only, never checked against `Letflow.Identity` for existence or group membership (the
same "assignee_ref is unvalidated free text" treatment REQ-083 §3.3 already established
for the *read* side, applied here to the *write* side — stated explicitly so a reader
doesn't wonder why `assign_task/4` never calls `resolve_principal_scope/2`).

### 3.6 `reassign_task/4`

```
@type reassign_attrs :: %{required(:user_id) => String.t()}
@type reassign_opts :: [prefix: String.t()]

@type reassign_error ::
        {:error, :invalid_task_id}
        | {:error, :missing_user_id}
        | {:error, :task_not_found}
        | {:error, {:task_not_pending, status :: :completed | :cancelled}}
        | {:error, :not_currently_assigned}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}

@spec reassign_task(
        task_id :: String.t(),
        attrs :: reassign_attrs(),
        opts :: reassign_opts()
      ) :: {:ok, Letflow.Engine.Task.t()} | reassign_error()
```

Identical shape to `assign_task/4` (§3.5) with the precondition inverted, matching
R-Co's own `reassign` (`WHERE ... assignee_ref IS NOT NULL`, §0): `:apply` step —
`task.assignee_ref != nil` → **reassignable**, write `assignee_type: "USER",
assignee_ref: attrs.user_id` (unconditionally overwrites whatever was there —
`"USER"`/`"GROUP"`/`"ROLE"`, matching R-Co's own unconditional overwrite); `task.
assignee_ref == nil` → `{:error, :not_currently_assigned}`. Same "no group/role check on
target `user_id`" note as §3.5 applies here too.

---

## 4. Tenant scoping (INV-1)

**Identical mechanism to every other REQ-072+ route, restated for the write path — no
new mechanism.** Every one of the four handlers resolves `Letflow.Api.Context.
scoped_repo_opts/1` first (§5.2); its `[prefix: schema_name]` is threaded into every
`Letflow.Tasks`/`Letflow.Engine` call. `claim_task/3`/`assign_task/4`/`reassign_task/4`'s
`repo.one`/`repo.update` calls (§3) all pass `prefix: prefix` — two tenants' `tasks`
tables live in physically separate Postgres schemas, so a `task_id` from tenant B can
never be locked or written by a `prefix: schema_a` call, regardless of UUID collision
(there is none, since `task_id` is a real UUID primary key, but the argument is
structural, not probabilistic). `complete_task/3` already establishes this same
guarantee for its own call (`TenantProvisioning.tenant_id_for_schema_name/1` validates
`prefix` before any write, §0).

**AC6 (cross-tenant id == nonexistent id, same response, on all four verbs, no state
change)** is satisfied structurally: every one of the four functions' `fetch_and_lock_task`
equivalent resolves a cross-tenant `task_id` to `nil` (since the row simply isn't visible
under that `prefix`) → `{:error, :task_not_found}`, the **same** code path and the
**same** error atom a truly nonexistent `task_id` produces. §5.5's response mapping sends
`Response.not_found/1` for this atom on all four routes with no varying detail (INV-5's
existing `not_found/1` no-argument mechanism, reused unchanged) — no branch anywhere
distinguishes "exists in another tenant's schema" from "never existed."

---

## 5. `Letflow.Routers.Tasks` — four new routes (same module REQ-083 already shipped)

**File:** `lib/letflow/routers/tasks.ex` — extends the existing REQ-083 module, not a new
router file (confirms the task brief's own instruction: this is the same file REQ-083's
read routes already live in and are mounted from).

```
POST /tasks/:id/complete   -> Letflow.Engine.complete_task/3   (:TasksComplete)
POST /tasks/:id/claim      -> Letflow.Tasks.claim_task/3        (:TasksComplete, §2)
POST /tasks/:id/assign     -> Letflow.Tasks.assign_task/4       (:TasksAssign)
POST /tasks/:id/reassign   -> Letflow.Tasks.reassign_task/4     (:TasksAssign, required_permission/1 maps both TasksAssign/TasksReassign endpoint keys to the same :TasksAssign permission, §0)
```

No route-ordering hazard analogous to REQ-083's `/inbox`-before-`/:id` concern — all four
new routes are `POST /tasks/:id/<verb>`, a distinct, non-overlapping literal suffix
segment each; `Plug.Router`'s first-match-wins semantics need no special ordering here.

### 5.1 `with_authorized_scope/4` — the exact same private helper, unchanged

**This design adds zero new authorization mechanism.** REQ-083's own `with_authorized_
scope/4` (§0, quoted in full there) already threads `decision` through to the handler
function — required for `GET /tasks`'s row-filter scope, unused by any of REQ-083's own
three handlers otherwise. This design's four new routes reuse that identical function,
unmodified: `with_authorized_scope(conn, "POST", "/tasks/:id/complete", fn conn, opts,
_decision -> handle_complete(conn, conn.params["id"], opts) end)`, and identically for
`/claim`, `/assign`, `/reassign` (each ignoring the unused `decision` argument the same
way `handle_get_by_id/3` already does, §0). `Deny403` → `Response.forbidden(conn,
"insufficient permissions")` (AC7) — the same call, same message, same helper as every
other route in this module and in `Letflow.Routers.Identity`/`Letflow.Routers.Tenants`
(§0's confirmed precedent for calling `Authorization.evaluate_access/2` directly from a
route module rather than a plug, pending REQ-131).

### 5.2 `handle_complete/3` (`POST /tasks/:id/complete`)

1. Parse request body: `output_variables` — `conn.body_params` is expected to already be
   a decoded JSON object (`Letflow.Plugs.SafeJsonParser`, REQ-068's existing pipeline
   stage, §0 of REQ-083's own design references this same plug); pass `conn.body_params`
   through to `complete_task/3`'s own `attrs.output_variables` **as-is**, with no
   router-level re-validation beyond what `complete_task/3` already performs
   (`fetch_output_variables/1`'s own `is_map/1` + `not is_struct/1` guard, §0) — this
   router deliberately does **not** duplicate that check (a second, possibly-divergent
   validation of the same field is exactly the "no second locking/validation scheme"
   discipline this design applies uniformly, not only to locking).
2. `actor_id: conn.assigns.auth_context.user_id`, `idempotency_key: <a fresh UUID this
   handler generates via `Ecto.UUID.generate/0` per request>` — matching `create/2`'s own
   established idempotency-key-sourcing convention for a caller that supplies none in the
   body (no acceptance criterion here asks for caller-supplied idempotency; a per-request
   generated key is the simplest correct choice, flagged as **OQ-1** below only because a
   future requirement may want a caller-supplied `Idempotency-Key` header instead, not
   because this design is uncertain about the value for *this* requirement's own tests).
3. `Letflow.Engine.complete_task(conn.params["id"], %{output_variables: ..., actor_id:
   ..., idempotency_key: ...}, opts)` — **the only call this handler makes to drive
   completion**; zero `Repo.` calls in this router module (grep-confirmable, per AC2).
4. Map the result per the table in §5.5.1 below.

**AC1's "completing a task advances the owning instance" and AC2's "no direct write to
the tasks table; routes to REQ-048's engine completion function" are satisfied
structurally by step 3 alone** — this handler contains no `Task.complete_changeset/2`
call, no `Repo.update` call, nothing but the one delegating call.

### 5.3 `handle_claim/3` (`POST /tasks/:id/claim`)

1. No request body is read (claim takes no body parameter — matching R-Co's own
   `handleClaim` signature, §0, which has no `body: []const u8` parameter at all, unlike
   `handleAssign`/`handleReassign`).
2. `Letflow.Tasks.claim_task(conn.params["id"], %{actor_id: conn.assigns.auth_context.
   user_id}, opts)`.
3. Map the result per §5.5.2.

### 5.4 `handle_assign/3` (`POST /tasks/:id/assign`) and `handle_reassign/3` (`POST /tasks/:id/reassign`)

Both handlers share the identical body-validation shape (matching `Letflow.Routers.
Identity`'s `@create_schema`/`Validation.validate/2` precedent, §0):

```
@user_id_schema [
  %FieldConstraint{name: "user_id", required: true, type: :string, reject_empty_string: true}
]
```

1. `Validation.validate(@user_id_schema, conn.body_params)` — `{:errors, field_errors}` →
   `Response.send_problem(conn, Validation.problem(field_errors))` (422, matching R-Co's
   own `INVALID_INPUT`/422 for a missing/empty `user_id`, §0 — no divergence here, unlike
   the 400-vs-422 divergence REQ-083 §5.2 point 2 made for malformed query params; this
   is a request-*body* field going through this codebase's own established `Validation`
   pipeline, which already resolves to 422 by construction).
2. `{:ok, %{"user_id" => user_id}}` → `Letflow.Tasks.assign_task(conn.params["id"], %{
   user_id: user_id}, opts)` (or `reassign_task/4` for the reassign route).
3. Map the result per §5.5.3/§5.5.4.

### 5.5 Result-to-HTTP mapping tables

**5.5.1 — `handle_complete/3`, from `Letflow.Engine.complete_error()`'s full union (§0):**

| `complete_task/3` result | HTTP | Mechanism |
|---|---|---|
| `{:ok, complete_result()}` | 200 | `Response.ok(conn, complete_result_map(result))`, §5.6 |
| `{:error, :invalid_task_id}` | 400 | `Response.bad_request(conn, "task_id is not a valid UUID")` — matches REQ-083 §5.4's own 400-not-422 convention for a malformed path-parameter UUID |
| `{:error, :invalid_output_variables}` | 422 | `Response.unprocessable(conn, "output_variables must be a JSON object")` |
| `{:error, :task_not_found}` | 404 | `Response.not_found(conn)` — INV-5, §4 |
| `{:error, {:task_not_pending, _status}}` | 409 | `Response.conflict(conn, "task is not pending")` — **AC3's own required mapping**; the task-status column value (`:completed`/`:cancelled`) is never echoed into the `detail` string, since no acceptance criterion asks for it and a constant detail is simpler to test |
| `{:error, %Ecto.Changeset{}}` | 422 | `Response.unprocessable(conn, "validation failed")` |
| every other member of `complete_error()` (`:invalid_schema_name`, `:instance_not_found`, `{:instance_not_active, _}`, `:snapshot_not_found`, `{:graph_structure_invalid, _}`, `{:missing_token_record, _}`, `{:transition_failed, _}`, `{:new_token_during_resume_not_supported, _}`, `{:task_activation_failed, _}`, `{:event_append_failed, _}`, `:missing_actor_id`, `:missing_idempotency_key`, `{:instance_execution_error, _, _}`, `{:error, term()}`) | 500 | `Response.internal_error(conn)` — a single catch-all clause, **not** seventeen individually-matched clauses. Every member in this row is either structurally unreachable given this handler's own inputs (`:invalid_schema_name`/`:missing_actor_id`/`:missing_idempotency_key` — `prefix`/`actor_id`/`idempotency_key` are router-derived, never caller-supplied, §5.2 point 2), or represents a genuine data-integrity/downstream failure this caller cannot fix by retrying with different input (`:instance_not_found`, `{:graph_structure_invalid, _}`, `{:transition_failed, _}`, `{:instance_execution_error, _, _}`, etc.) — matching REQ-083 §3.5's own "residual-risk, not individually enumerated" precedent, applied here to a typed-error catch-all rather than an unhandled-exception one |

**INV-8 note on the catch-all clause:** this is a `case`/`with`-exhaustive typed-tuple
match, not a bare pattern that can raise — `interpret_complete_result/1`'s own catch-all
(§0) already guarantees `complete_task/3` never raises for any of these paths; this
router's own catch-all only decides the HTTP status for outcomes it cannot usefully
subdivide further.

**5.5.2 — `handle_claim/3`, from §3.4's `claim_error()`:**

| `claim_task/3` result | HTTP |
|---|---|
| `{:ok, task}` | 200, `Response.ok(conn, task_detail_map(task, nil))` — §5.6 |
| `{:error, :invalid_task_id}` | 400 |
| `{:error, :task_not_found}` | 404 |
| `{:error, {:task_not_pending, _}}` | 409 |
| `{:error, :assigned_to_other_user}` | 409, `Response.conflict(conn, "task is assigned to a different user")` |
| `{:error, :assignee_group_not_member}` | 409, `Response.conflict(conn, "caller is not a member of the assigned group")` |
| `{:error, :assignee_role_not_held}` | 409, `Response.conflict(conn, "caller does not hold the assigned role")` |
| `{:error, :not_claimable}` | 409, `Response.conflict(conn, "task cannot be claimed")` |
| `{:error, %Ecto.Changeset{}}` or `{:error, term()}` | 500 |

**5.5.3 — `handle_assign/3`, from §3.5's `assign_error()`:**

| `assign_task/4` result | HTTP |
|---|---|
| `{:ok, task}` | 200, `Response.ok(conn, task_detail_map(task, nil))` |
| `{:error, :invalid_task_id}` | 400 |
| `{:error, :missing_user_id}` | 422 (belt-and-suspenders — §3.5's own note; `Validation.validate/2` at §5.4 point 1 is expected to already have caught this) |
| `{:error, :task_not_found}` | 404 |
| `{:error, {:task_not_pending, _}}` | 409 |
| `{:error, :already_assigned}` | 409, `Response.conflict(conn, "task is already assigned")` |
| `{:error, %Ecto.Changeset{}}` or `{:error, term()}` | 500 |

**5.5.4 — `handle_reassign/3`, from §3.6's `reassign_error()`:**

Identical to §5.5.3, with `{:error, :not_currently_assigned}` → 409,
`Response.conflict(conn, "task is not currently assigned")`, in place of
`:already_assigned`.

**No 403 row appears in any of the four tables above** — `Deny403` is resolved entirely
by `with_authorized_scope/4` (§5.1) before any of these four handler functions is ever
called; none of them independently checks a permission.

### 5.6 Response bodies (INV-2)

**Claim/assign/reassign success — reuses REQ-083's `task_detail_map/2` unchanged**
(§0: ten keys — the nine `task_list_item_map/1` keys plus `correlation_key`/`updated_at`).
This design calls it with `correlation_key: nil` for all three (none of claim/assign/
reassign has the `instance_projections` join `get_task/2` performs — the caller already
has the task's `instance_id` if it needs the correlation key, via a follow-up `GET
/tasks/:id`; no acceptance criterion here requires it inline, and adding a second query
per write call for a field no test asserts on is unjustified). `task_detail_map/2` still
correctly omits `claimed_by` (§1's decision confirms REQ-083's own omission was right,
not merely deferred) and `form_schema`/`output_variables`/`completed_by`/`completed_at`/
`cancelled_at` (unchanged from REQ-083 §5.5's own reasoning).

**Complete success — a new, dedicated allowlist map, `complete_result_map/1`:**
```
@spec complete_result_map(Letflow.Engine.complete_result()) :: map()
```
Six keys, mirroring `complete_result()`'s own six fields exactly (no `Ecto.Task` struct
involved at all on this path — `complete_result()` is already a plain map, so this is an
allowlist restatement, not a struct-to-map reduction): `"task_id"`, `"instance_id"`,
`"instance_status"` (the `:active`/`:completed` atom, stringified via the same
`Atom.to_string/1 |> String.upcase/1` convention `task_status_string/1` already
establishes, §0, producing `"ACTIVE"`/`"COMPLETED"` — consistent with `instance_
projections.status`'s own `Ecto.Enum` uppercase-string dump, confirmed at §0), `"current_
nodes"` (the list of `node_id` strings, passed through unchanged — already a plain list
of strings, no further mapping needed), `"variables"` (the merged instance-variables map,
passed through unchanged — REQ-085 has no acceptance criterion asking for a narrower
allowlist over instance variable *contents*, only that they be observable, per AC1), `
"completed_at"` (ISO 8601 via `DateTime.to_iso8601/1`, matching REQ-083's own `created_at`/
`updated_at` convention).

**This is the concrete design element AC1 needs**: a test asserting the response body's
`"variables"` key contains the merged output, and/or a follow-up `GET /tasks/:instance_id
.../...` or instance read confirming token movement, demonstrates AC1's "not only the
200" requirement — this design's job is that the response shape carries enough
information for that test to exist (`instance_status`/`current_nodes`/`variables` all
present), which it does.

---

## 6. Cross-module dependencies

| Module | Direction | Nature |
|---|---|---|
| `Letflow.Engine.complete_task/3` (REQ-048, shipped, unmodified) | `Letflow.Routers.Tasks` → that | `handle_complete/3`'s only call for the completion transition (§5.2) |
| `Letflow.Engine.Task` (REQ-043, shipped) | `Letflow.Tasks` → that | **One new changeset function added** (`assignment_changeset/2`, §3.2) — the only file outside `Letflow.Tasks`/`Letflow.Routers.Tasks` this design's write functions themselves touch |
| `Letflow.Tasks.resolve_principal_scope/2` (REQ-083, shipped, unmodified) | `claim_task/3` → that | Claim's only group/role source (§3.3) — `assign_task/4`/`reassign_task/4` never call it |
| `Letflow.Identity.GroupMember`/`Letflow.Identity.TenantRole` (shipped, unmodified) | transitively, via `resolve_principal_scope/2` | No new/changed dependency — reused exactly as REQ-083 already established |
| `Letflow.Api.Authorization` (REQ-069, shipped) | `Letflow.Routers.Tasks` → that | **One new clause added** (`endpoint_policy_key("POST", "/tasks/:id/claim") -> :TasksComplete`, §2) — the only non-`Letflow.Tasks`/non-`Letflow.Engine.Task`/non-router file this design touches |
| `Letflow.Api.Validation`/`Letflow.Api.Validation.FieldConstraint` (REQ-068, shipped, unmodified) | `Letflow.Routers.Tasks` → that | `assign`/`reassign`'s `user_id` body-field check (§5.4) |
| `Letflow.Api.Context.scoped_repo_opts/1` (REQ-072, shipped, unmodified) | `Letflow.Routers.Tasks` → that | Every handler's first call (§4, §5.1) |
| `Letflow.Api.Response`/`Letflow.Api.Error` (REQ-066, shipped, unmodified) | `Letflow.Routers.Tasks` → that | Every response/error path (§5.5) |

---

## 7. DB objects touched

**None.** No migration. `tasks` already has every column this design writes
(`assignee_type`, `assignee_ref` — both already exist, REQ-043). No new column
(`claimed_by` explicitly rejected, §1), no new index (claim/assign/reassign all operate
by primary key `id`, already indexed via the table's own primary-key constraint; no new
query pattern this design introduces needs a supporting index the way REQ-083's own
OQ-5 flagged for keyset pagination).

---

## 8. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-TW85-1 | Tenant scope for all four handlers comes exclusively from `Context.scoped_repo_opts/1`'s `[prefix: _]`, never a path/query/header value | §4 |
| INV-TW85-2 | `handle_complete/3` performs zero `Repo.` calls and zero `Task.complete_changeset/2` calls — completion is driven entirely by `Letflow.Engine.complete_task/3` | §5.2 |
| INV-TW85-3 | `claim_task/3`/`assign_task/4`/`reassign_task/4` acquire `SELECT ... FOR UPDATE` on exactly the one `tasks` row named by `task_id`, inside one `Ecto.Multi` per call, with the winning/losing outcome decided after the lock is held — never a bare `UPDATE ... WHERE` racing without an application-level lock | §3.0, §3.1 |
| INV-TW85-4 | Cross-tenant and never-existed `task_id` lookups are the same code path, same `{:error, :task_not_found}`/`Response.not_found/1` call, on all four routes | §4 |
| INV-TW85-5 | Every serialized response (complete's `complete_result_map/1`, claim/assign/reassign's reused `task_detail_map/2`) is a hand-built allowlist map — no `Jason.Encoder` derive, no struct-wholesale encoding | §5.6 |
| INV-TW85-6 | `claim_task/3`'s group/role membership check routes exclusively through the existing `Letflow.Tasks.resolve_principal_scope/2` — no second resolution path against `Letflow.Identity`-owned schemas | §3.3 |
| INV-TW85-7 | `complete`/`claim` require `:TasksComplete`; `assign`/`reassign` require `:TasksAssign`; `Deny403` on any of the four returns the same 403 body via the same `with_authorized_scope/4` helper, before any handler function runs | §2, §5.1 |
| INV-TW85-8 | No implementation code (`.ex`/`.exs` bodies) anywhere in this document — signatures, `@spec`s, and algorithm-shape tables only | Whole document |

---

## 9. Acceptance-criteria traceability

| REQ-085 acceptance criterion (verbatim) | Concrete design element |
|---|---|
| "completing a task advances the owning instance -- the output variables appear in the instance's variables and the token has moved -- demonstrated end-to-end through the real router by asserting instance state, not only the 200" | §5.2 (delegates entirely to `complete_task/3`, which already drives the transition, REQ-048), §5.6 (`complete_result_map/1` surfaces `variables`/`current_nodes`/`instance_status` so a test can assert on them beyond the status code) |
| "handleComplete contains no direct write to the tasks table; it routes to REQ-048's engine completion function, confirmed by grep for Repo. in the module returning no hit and stated in the moduledoc" | §5.2 point 3 (the one delegating call), INV-TW85-2 |
| "completing an already-completed task and completing an already-cancelled task each return a 409-class problem document and produce no second transition, verified by asserting the instance state is unchanged -- two explicit tests" | §5.5.1's `{:error, {:task_not_pending, _}} -> 409` row, backed by `complete_task/3`'s own row-lock guarantee (§0) that a non-`:pending` task never re-enters the transition path |
| "two concurrent claims of the same task produce exactly one success and one deterministic non-500 rejection, demonstrated by a test running both concurrently" | §3.1 (locking mechanism + the concurrency argument), §3.4's decision table (the loser always lands on a named `claim_error()` member, never `{:error, term()}`), §5.5.2 (every named member maps to a 4xx, only the true catch-all maps to 500) |
| "claiming a task assigned to a different user in the same tenant, and claiming one assigned to a group the caller does not belong to, are both rejected with no state change -- two explicit tests" | §3.4's decision table (`:assigned_to_other_user`, `:assignee_group_not_member` rows) — both reject *before* any `repo.update/2` call, so no write is even attempted |
| "a task id belonging to another tenant returns the same response as a nonexistent id on all four verbs, with no state change in any case -- verified by reading the target row (INV-1, INV-5)" | §4 (single code path per function, structural argument), INV-TW85-4 |
| "a caller without TasksComplete cannot complete and a caller without TasksAssign cannot assign or reassign, with the absence of state change verified in each case" | §5.1 (shared `with_authorized_scope/4`, `Deny403` before any handler runs — no row is ever locked, let alone written, on a 403 path), §2 (claim's own `:TasksComplete` gate, additionally covering "a caller without TasksComplete cannot claim" even though AC7's own text names complete only) |

---

## 10. Open questions — explicitly listed, not silently resolved

- **OQ-1 (MINOR).** `handle_complete/3` generates a fresh `idempotency_key` per request
  via `Ecto.UUID.generate/0` (§5.2 point 2) rather than accepting a caller-supplied
  `Idempotency-Key` header. No acceptance criterion here asks for caller-controlled
  idempotency, so this is not a gap against REQ-085's own scope — flagged only in case a
  later requirement (a webhook-retry or offline-client scenario) wants header-sourced
  idempotency added to this same call site.
- **OQ-2 (MINOR).** Claim's no-op "already claimed by the same caller" branch (§3.4's
  second table row) returns success with no write, rather than an error. No acceptance
  criterion tests this specific case either way; flagged for REVIEWER to confirm this is
  the intended UX (a double-click on "claim" by the same user succeeding silently) rather
  than a 409 — either is defensible, this design picked the one matching ordinary
  idempotent-PUT-style expectations.
- **OQ-3 (MINOR).** `assign_task/4`/`reassign_task/4` perform no existence check on the
  target `user_id` against `Letflow.Identity` (§3.5's own note) — matches R-Co exactly,
  not a gap, but flagged since a future requirement might reasonably want to reject
  assignment to a nonexistent user id.
