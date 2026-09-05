# Design: REQ-052 — Instance cancellation (`instance.zig` `cancelInstance`, EE-08)

**Requirement:** REQ-052 (this run's handoff `context.requirement_text.REQ-052`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ052-20260819`, WF-02 Step 1
**This document produces:** `Letflow.Engine.cancel_instance/3`'s public signature, its
`Ecto.Multi` shape, the row-locking protocol (and why its lock order must match
`complete_task/3`'s), the SUPERSESSION disposition of `lib/letflow/parallel_approval.ex` and
`Letflow.ApprovalSupervisor`, the SCOPE BOUNDARY hooks (SCH-03, REQ-056), the OPEN QUESTION
about process termination (why its premise does not hold for this requirement's own scope,
citing REQ-045's actual resolution and REQ-040's precedent), invariants, DB tables/columns
touched, cross-module dependencies, and every acceptance criterion mapped to a concrete
design element. No implementation code — signatures/shapes only, matching
`req045`/`req048`/`req051`'s own convention.

---

## 0. Sources read for this design

- This run's handoff — `context.requirement_text.REQ-052` (full description) and
  `task.acceptance_criteria`, per `core-directives.md`'s "Load Scoped Context, Not Whole
  Files."
- `docs/agents/instructions/core-directives.md` (full).
- `docs/guides/backend_developer_guide.md` (full) — §3.2 gen_statem-vs-plain-Ecto
  discipline, §3.3 one-supervised-process-per-instance (load-bearing for §2 below), §3.5
  error shapes, §3.6 SQL-locking-via-`Ecto.Query.lock/2`, §3.7 migrations.
- `docs/migration/stage-3-instance-engine.md` (full) — the EE-01..EE-12 breakdown, the
  "Two early findings" (idiomatic-OTP-confirmed / process-per-instance's-actual-value)
  and "Where these two findings land" sections naming REQ-052 explicitly, and the
  "Generalization of the early modules" paragraph stating REQ-052 (with REQ-051)
  supersedes `lib/letflow/parallel_approval.ex`.
- `docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` — D2: no
  `tenant_id` column/derivation on any of `tasks`, `tokens`, `instance_projections`,
  `events` (this design adds no new column to any of the four).
- `lib/letflow/design/req045-instance-start-engine-shell.md` (full) — **the process-vs-row
  decision this requirement's own OPEN QUESTION depends on** (§1: "plain transactional
  context module, no process… `create/2` is a plain function"), and its AC5/AC6 moduledoc
  content this design's own §2 mirrors for `cancel_instance/3`.
- `lib/letflow/design/req048-task-completion.md` (full) — the row-locking discipline
  (`tasks` before `instance_projections`, "never the reverse, across every call site, to
  avoid a lock-ordering deadlock", §8), the already-shipped `fetch_and_lock_instance_
  projection/3` defensive `:instance_not_active` check (§8.1/M2), and the scoped-
  reconstruction pattern this design deliberately does **not** need (§6 below explains
  why).
- `lib/letflow/design/req051-parallel-gateway-split-join.md` (full) — `JoinCounter`,
  `join_outcome/1`'s `:wait`/`:fire`/`:cancel_join` decision, `{:cancel_branch,
  branch_id}`'s existing pure handling (§3.4), and §8's explicit statement that REQ-052 is
  its "forward dependent" — read in full because §4 below must state precisely whether
  this design wires that forward dependency or not, and why.
- `lib/letflow/design/req040-promotion-assertion-rerun.md` §2 (full) — the crash-safety
  investigation/decision this requirement's own OPEN QUESTION is instructed to cite: the
  `try/rescue`-not-a-new-process decision, and the explicit statement that a hard
  `Process.exit(pid, :kill)`/node crash is the one exit class Elixir's `try` cannot cover
  (mirrored, not re-derived, in §5.4 below).
- `docs/anti-patterns.md` (current entries) — no entry bears directly on this module's own
  logic; the git-rebase/module-naming entries are process notes for ELIXIR-DEV, not design
  content.
- Shipped code, read directly (not paraphrased):
  - `lib/letflow/engine.ex` (full, 1268 lines, current `main`) — `create/2`, `complete_task/3`
    and every private helper both call, in particular `fetch_and_lock_task/3`,
    `fetch_and_lock_instance_projection/3` (§8.1's already-shipped `:instance_not_active`
    check — load-bearing for §7 below: **no change to `complete_task/3` is needed by this
    requirement**, that check already rejects a `:cancelled` instance's tasks), and
    `reconcile_projection/5`'s `InstanceProjection.update_changeset/2` call shape.
  - `lib/letflow/event_store.ex` (full, 1149 lines) — `append/2`'s pre-transaction `with`
    chain, `active_instance_guard/3` (lines 357-369, **a plain, unlocked read** — its own
    comment names this explicitly as design doc OQ-6, not a locked read), and
    `assign_sequence/3`'s separate `instance_sequences`-row locking (confirms
    `active_instance_guard/3` alone is not this codebase's serialization mechanism for
    concurrent writers — §5.2 below is where real serialization for this requirement
    actually happens).
  - `lib/letflow/event_store/instance_projection.ex` (full) — `status` `Ecto.Enum`
    (`:active`/`:completed`/`:cancelled`/`:error`), `terminal?/1` (`true` only for
    `:completed`/`:cancelled` — **`:error` is not terminal**, load-bearing for §3 below),
    `update_changeset/2`'s exact cast list (`:status`, `:last_event_seq`, `:current_nodes`,
    `:variables`, `:error_detail`, `:completed_at`, `:cancelled_at`) and its
    `validate_required([:status, :last_event_seq])` (confirmed, per `complete_task/3`'s own
    `reconcile_projection/5` precedent, that omitting `:last_event_seq` from `attrs` is safe
    — `validate_required` reads the changeset's current field value, which the locked struct
    already carries non-`nil`, and `Repo.update/2` only writes columns present in
    `changeset.changes`).
  - `lib/letflow/engine/task.ex` (full) — `status :: :pending | :completed | :cancelled`
    (`:cancelled` **already a valid value**, no schema change needed), `cancelled_at` field
    (already present), `complete_changeset/2`'s cast list already includes `:status` and
    `:cancelled_at` — **reused unchanged**, no new Task changeset function.
  - `lib/letflow/engine/token_record.ex` (full) — `status :: :active | :waiting | :completed
    | :cancelled` (`:cancelled` already valid), `cancelled_at` field already present,
    `advance_changeset/2`'s cast list already includes `:status` and `:cancelled_at` —
    reused unchanged.
  - `lib/letflow/engine/transition.ex`, `instance_state.ex`, `token.ex`, `join_counter.ex`
    (full) — confirmed `Transition`'s purity contract (`grep`-checkable, no `Repo`/`Logger`/
    clock/`:rand`/`:crypto`) and that `join_counters` is not persisted anywhere (§4 traces
    this precisely).
  - `lib/letflow/parallel_approval.ex`, `lib/letflow/approval_supervisor.ex` (both full,
    96 and 26 lines) — read to determine the SUPERSESSION disposition (§2).
  - `lib/letflow/instance_supervisor.ex` (full) — confirms it is **already** the
    `DynamicSupervisor` reserved for REQ-056/REQ-057's future supervised process, per its
    own moduledoc quoting `Letflow.Engine`'s REQ-045 AC5 moduledoc — load-bearing for §2's
    disposition of `Letflow.ApprovalSupervisor` (a second, now-redundant `DynamicSupervisor`
    with no distinct future consumer of its own).
  - `lib/letflow/application.ex` — confirmed both `Letflow.InstanceSupervisor` and
    `Letflow.ApprovalSupervisor` are children of the top-level supervision tree (lines
    24-25) — §2's DELETE decision requires ELIXIR-DEV to remove `Letflow.ApprovalSupervisor`
    from this list.
  - `lib/letflow/sandbox_pool.ex` moduledoc (grep only) — mentions `Letflow.ApprovalSupervisor`
    by name in a comparison sentence; flagged in §2 as a stale cross-reference for
    ELIXIR-DEV to update, not a functional dependency.
  - `test/letflow/parallel_approval_test.exs` (existence confirmed via `grep -rl`, not read
    in full — its removal is ELIXIR-DEV's job alongside the module's own deletion, per §2).

**Access gap — RESOLVED 2026-08-22, GH#326 (WF03-ISS0278-20260822).** At design time this
environment had no `R-Co/src/engine/instance.zig` reachable, so OQ-1 and OQ-2 below were
left as this design's own unverified resolutions. `R-Co/src/engine/instance.zig` is
reachable now (`c:\Users\tvolo\dev\ai-dala\R-Co`), and both questions are settled by its
`cancelInstance` (EE-08, line 2513 on):

- **OQ-1 (reason/note field): CONFIRMED, no field expected.** The real signature is
  `pub fn cancelInstance(self: *InstanceStore, allocator: std.mem.Allocator, task_store: *const task_mod.TaskStore, instance_id: Uuid, actor_id: []const u8) CancelInstanceError!void` —
  no `reason`/`note` parameter of any kind. `cancel_attrs()`'s omission (§3) matches R-Co
  exactly.
- **OQ-2 (per-branch teardown mechanism): CONFIRMED, direct UPDATE, not per-branch
  transition events.** R-Co's own doc-comment states the 8-step algorithm explicitly (steps
  d/e): `UPDATE tasks SET status='CANCELLED' ... WHERE instance_id=$1 AND status='PENDING'`
  and `UPDATE timers SET status='cancelled' ... WHERE instance_id=$1 AND status='pending'`,
  both plain SQL UPDATEs issued directly inside the single `cancelInstance` transaction —
  there is no per-branch event driven through R-Co's own transition/graph machinery
  anywhere in this path. §4's reasoning below (not driving `{:cancel_branch, branch_id}`
  through `Transition`) is the same shape R-Co itself uses, not merely a plausible
  independent choice.

This design is otherwise unchanged — §4's own machinery (Ecto transactional multi vs. R-Co's
SQL transaction) was already reasoned independently and remains a legitimate implementation
choice; only the *mechanism* question (direct update vs. per-event) was open, and it is now
confirmed to match.

---

## 1. Module/file layout

**No new file.** `cancel_instance/3` and its private helpers are added to the already-shipped
`lib/letflow/engine.ex` (`Letflow.Engine`), alongside `create/2` and `complete_task/3` —
matching that module's own established "one context module, one function per EE-*
public operation" shape. No new migration, no new table, no new column (§8 confirms every
column this design writes already exists).

---

## 2. SUPERSESSION — `lib/letflow/parallel_approval.ex` and `Letflow.ApprovalSupervisor`

**Decision: both `lib/letflow/parallel_approval.ex` (`Letflow.ParallelApproval`) and
`lib/letflow/approval_supervisor.ex` (`Letflow.ApprovalSupervisor`) are DELETED by this
requirement, together with `test/letflow/parallel_approval_test.exs` and their two
`children` entries in `lib/letflow/application.ex` (lines 24-25 currently list both
`Letflow.InstanceSupervisor` and `Letflow.ApprovalSupervisor` — only the former stays).**

**Reasoning, stated explicitly since this diverges from a literal "identical to how REQ-046
handled `ProcessInstance`/`InstanceSupervisor`" reading (REQ-046 deleted the gen_statem but
*retained* its supervisor) — flagged for REVIEWER to confirm, not silently assumed correct:**

1. **The gen_statem half — `Letflow.ParallelApproval` — is deleted, same as
   `ProcessInstance`.** Its hardcoded two-approver `:pending`/`:approved` state graph is now
   exactly what REQ-051's `PARALLEL_GATEWAY` split/join expresses as generic definition data
   (a 2-edge split into two `HUMAN_TASK` "approve" nodes feeding one join), with this
   requirement (`cancel_instance/3`) as the piece that lets a caller abandon such an instance
   before both approvals land. No functional capability of `ParallelApproval` becomes
   unreachable once REQ-051 and this requirement both ship. This half of the disposition is
   not in question.
2. **The supervisor half — `Letflow.ApprovalSupervisor` — is deleted, *not* retained, and
   this is the actual divergence from REQ-046's precedent.** REQ-046 retained
   `Letflow.InstanceSupervisor` because a *distinct, already-named* future consumer existed
   for it: REQ-056 (service task dispatch) and REQ-057 (plugin registry), the two
   subsystems `stage-3-instance-engine.md`'s own Early finding names as the strong case for
   a supervised process. `Letflow.InstanceSupervisor`'s own moduledoc (read directly, §0)
   states this in its own words: "reserved for per-process-instance processes… retained
   rather than deleted… for whichever later S3 requirement (REQ-056/REQ-057) does need a
   supervised process." **`Letflow.ApprovalSupervisor` has no equivalent distinct future
   consumer** — REQ-045 already resolved the *general* "is a running instance a supervised
   process?" question for this whole stage (§1 of that design: "no process, plain
   transactional context module"), and the *one* `DynamicSupervisor` this stage keeps in
   reserve for whichever later requirement does need process-per-unit supervision is
   already `Letflow.InstanceSupervisor` — not a second, approval-specific one. Keeping both
   `InstanceSupervisor` and `ApprovalSupervisor` idle in the supervision tree for the same
   "maybe REQ-056/057 needs a DynamicSupervisor" reason would be exactly the "hidden
   ambiguity/redundant surface" `core-directives.md`'s Unblock-Everything/anti-scope-creep
   boundary and this codebase's own "one process per instance, not two competing
   supervisors for the same class of thing" convention both warn against — REQ-051 §0
   itself already frames `ApprovalSupervisor` as "the hand-written special case of what
   PARALLEL_GATEWAY split/join now expresses as definition data," which reads naturally as
   "the special case's dedicated infrastructure goes away with it," not "keep a second idle
   supervisor around indefinitely."
3. **Cross-references to update, named for ELIXIR-DEV rather than left for it to discover:**
   `lib/letflow/sandbox_pool.ex`'s moduledoc mentions `Letflow.ApprovalSupervisor` by name in
   a comparison sentence ("`Letflow.InstanceSupervisor`/`Letflow.ApprovalSupervisor` use one
   process *per*…") — this sentence needs editing (not merely deleting the file) so it does
   not reference a module that no longer exists. `lib/letflow/row_approval.ex`'s moduledoc
   also mentions `Letflow.ParallelApproval` by name, but purely as a historical/comparison
   reference for its own "same semantics, no process" design choice — this reference may
   stay verbatim (it describes what `row_approval.ex` deliberately chose *not* to do,
   which remains true and informative even after `ParallelApproval` itself is deleted), not
   flagged for mandatory editing, only noted here so ELIXIR-DEV does not delete
   `row_approval.ex` believing it depends on the deleted module (it does not — `grep`
   confirms no call into `ParallelApproval`/`ApprovalSupervisor` from `row_approval.ex`,
   only prose).

**Required moduledoc content (this design's own equivalent of REQ-045 AC5/`req045`'s §2
point 1) — `cancel_instance/3`'s moduledoc section must state, verbatim in substance:**

> `lib/letflow/parallel_approval.ex` (`Letflow.ParallelApproval`) and
> `lib/letflow/approval_supervisor.ex` (`Letflow.ApprovalSupervisor`) are **deleted** by this
> requirement, together with REQ-051's `PARALLEL_GATEWAY` split/join — the hand-written
> two-approver `:gen_statem` and its dedicated `DynamicSupervisor` are both fully
> superseded, with no retained/generalized half (unlike `Letflow.ProcessInstance`'s own
> retirement, REQ-046, which kept `Letflow.InstanceSupervisor` for a distinct, still-open
> future need — REQ-052 introduces no new process and therefore has no equivalent
> supervisor to keep).

---

## 3. `Letflow.Engine.cancel_instance/3` — public signature

```elixir
@type cancel_attrs :: %{
        required(:actor_id)        => Ecto.UUID.t(),
        required(:idempotency_key) => String.t()
      }

@type cancel_opts :: [prefix: String.t()]

@type cancel_error ::
        {:error, :invalid_instance_id}
      | {:error, :invalid_schema_name}
      | {:error, :missing_actor_id}
      | {:error, :missing_idempotency_key}
      | {:error, :instance_not_found}
      | {:error, {:instance_already_terminal, status :: :completed | :cancelled}}
      | {:error, {:event_append_failed, term()}}
      | {:error, Ecto.Changeset.t()}
      | {:error, term()}

@type cancel_result :: %{
        instance_id: Ecto.UUID.t(),
        status: :cancelled,
        cancelled_task_ids: [Ecto.UUID.t()],
        cancelled_at: DateTime.t()
      }

@spec cancel_instance(
        instance_id :: Ecto.UUID.t(),
        attrs :: cancel_attrs(),
        opts :: cancel_opts()
      ) :: {:ok, cancel_result()} | cancel_error()
```

`instance_id` is a separate positional argument, exactly mirroring `complete_task/3`'s own
`task_id` positioning (§0) — this requirement's own text names the function
`cancel_instance/N`, and `N` = 3 to match `create/2`/`complete_task/3`'s established
`(subject_id?, attrs, opts)`/`(attrs, opts)` shape for this module. `attrs` carries only
`actor_id`/`idempotency_key`, plumbed straight through to `EventStore.append/2`'s own
identical requirement (§0's "plumb straight through, let `append/2` return its own typed
errors" pattern, already established by `create/2`/`complete_task/3`) — **no
`:cancellation_reason`/`:note` field is added by this design.** No acceptance criterion or
requirement-text bullet names one, and R-Co's own literal signature is unreachable in this
environment (§0's access gap) — flagged as OQ-1 (§11), not silently decided either way.

**`output_variables`-equivalent validation is absent by design, stated explicitly rather
than silently omitted:** unlike `complete_task/3` (which validates a caller-supplied
`output_variables` map), `cancel_instance/3` accepts no free-form caller payload at all —
there is nothing analogous to validate before the transactional phase beyond the two
`Ecto.UUID`-shaped identifiers `EventStore.append/2` already requires.

---

## 4. Why this design does NOT drive `{:cancel_branch, branch_id}` through `Transition` —
stated explicitly, not silently decided

REQ-051's own design doc (§8, §0) names `cancel_instance/N` as its "forward dependent…
expected to eventually emit `{:cancel_branch, branch_id}` events (one per still-open branch
of an instance being cancelled) into this same `transition/3` entry point." This design
does **not** wire that dependency, for a concrete, traced reason rather than an oversight:

`Transition`'s `{:cancel_branch, branch_id}` dispatch (`req051` §3.4) needs a correctly
populated `InstanceState.join_counters` map to decide `:wait`/`:fire`/`:cancel_join` for any
branch that belongs to an outstanding split. **No table persists `JoinCounter` state across
calls today** — `req048`'s own design doc already discloses this precisely (its MAJOR OQ-3:
"`join_counters: %{}` always… no table persists join-counter state today… flagged for
REVIEWER/ORCH to confirm this is an acceptable known gap"), and nothing has closed that gap
since (REQ-054's `instance_state_snapshots` — the table that would carry it — is still
`pending`). A `cancel_instance/3` call that reconstructed `InstanceState` the same
`tasks`/`tokens`/`instance_projections`-only way `complete_task/3`'s §6 does (`req048`) would
therefore *always* pass an empty `join_counters` map to `Transition.transition/3`, and every
`{:cancel_branch, branch_id}` call would silently take `req051` §3.4 step 3's own "no cohort
currently tracks this branch" branch — a **total, defensive no-op that merely removes the
token**, never reaching `join_outcome/1`'s real `:fire`/`:cancel_join` computation. Driving
`{:cancel_branch, _}` here today would therefore add real complexity (a second scoped-
reconstruction, identical in shape to `req048` §6) for **zero** behavioral benefit — it would
never actually exercise `req051`'s join-aware cancellation logic, only its always-taken
degenerate branch, which is exactly the same outcome as not calling it at all.

**What this design does instead:** `cancel_instance/3` is a direct, coarser-grained
persistence-layer operation — it does not go through `Transition`/`dispatch_node`/`Token`
at all. It marks every currently-open `tasks` row and every currently-live `tokens` row
CANCELLED directly (§7), sets `instance_projections.status = :cancelled` directly (§7), and
appends exactly one `INSTANCE_CANCELLED` event — the literal EE-08 text ("Sets all open
tasks to CANCELLED, appends an INSTANCE_CANCELLED event, and sets the instance status to
CANCELLED"), with no intermediate pure-transition step.

**How this design still satisfies this run's own AC — "an instance CANCELLED by the
all-branches-cancelled path and one CANCELLED by a direct caller request must reach the
same persisted state… compared explicitly":** stated precisely, not asserted loosely.
`Transition`'s own `:cancel_join` outcome (`req051` §3.4/§4.1) is a **pure, in-memory-only**
computation — `Transition` touches no `Repo` anywhere (§0's purity re-confirmation) — and
**no caller in this codebase persists its result today**; `req051`'s own design (§8) named
`cancel_instance/N` as the only intended future caller, and this section is this design's
own reasoned decision not to wire it (for the concrete reason above). Consequently, as of
this requirement's own shipped state, `cancel_instance/3` is the **only reachable code path
in this codebase that ever transitions a persisted instance to `:cancelled`** — there is no
second, independently-implemented "all-branches-cancelled" persistence path it could
diverge from. The AC's "agreement" is therefore satisfied by construction along two
concrete, checkable seams, both stated so TEST-DESIGNER can verify them directly without a
second orchestration path needing to exist:

1. **Same terminal status value.** `req051` §3.4's `:cancel_join` branch sets
   `instance_state.status = :cancelled` (the bare atom `:cancelled` on the pure
   `InstanceState.t()` struct); `cancel_instance/3`'s own §7 M4 sets
   `instance_projections.status = :cancelled` (the identical atom, cast through the same
   `Ecto.Enum` REQ-043 already defines). A unit test can call
   `Transition.transition(graph, state_with_one_outstanding_branch, {:cancel_branch,
   last_branch_id})` directly (pure, no DB) and assert its returned `InstanceState.status ==
   :cancelled`, then separately call `cancel_instance/3` against a real instance and assert
   `instance_projections.status == :cancelled` was persisted — both assertions target the
   identical atom, not two different spellings of "cancelled."
2. **Same event/task disposition.** `req051` §5.3's `{:parallel_join_cancelled, ...}`
   pending event and this design's own persisted `INSTANCE_CANCELLED` event both represent
   "this instance's execution is over, triggered by cancellation, not completion" — the
   former is `Transition`'s own internal signal (never itself an `events` row, per `req051`
   §8's own scope note that persisting it is "REQ-047's future orchestration job" — a job no
   shipped requirement has taken on), the latter is the one and only durable record this
   design ever produces for a caller-initiated cancel. No requirement anywhere persists
   `PARALLEL_JOIN_CANCELLED` as its own distinct `events` row today, so there is no risk of
   the two paths producing two *different* event types for the same underlying "instance
   cancelled" fact.

**Flagged explicitly for REVIEWER/RELEASE-VALIDATOR (§11 OQ-2), not silently settled:**
whether this "agreement by construction, not by a second exercised code path" reading of
the AC is the intended one, or whether a future requirement should instead build the
scoped-`join_counters` reconstruction needed to let `cancel_instance/3` genuinely drive
`{:cancel_branch, _}` per branch (closing `req051`'s named forward dependency literally,
not only in spirit) — this design does not build that reconstruction now, since REQ-052's
own acceptance criteria do not name it and `req048`'s own OQ-3 already deferred the
underlying gap to REQ-053/054.

---

## 5. Pre-transaction phase (no I/O attempted on failure)

Algorithm shape (matching `create/2`/`complete_task/3`'s own pre-transaction `with` chain,
§0), not literal code — `cancel_instance/3` first runs three checks in a fixed order,
short-circuiting on the first failure, **before** any `Ecto.Multi`/`Repo.transaction/1`
opens:

1. `cast_instance_id/1` — `Ecto.UUID.cast(instance_id)`, `:error` ->
   `{:error, :invalid_instance_id}`. Same defensive INV-8 guard `complete_task/3`'s own
   `cast_task_id/1` already establishes (§0) — `instance_id` flows into a `where i.instance_id
   == ^instance_id` query (§7 M2) and a malformed value must not raise
   `Ecto.Query.CastError`.
2. `fetch_actor_and_idempotency_key/1` — `Map.get(attrs, :actor_id)` ->
   `{:error, :missing_actor_id}` if absent/`nil`; `Map.get(attrs, :idempotency_key)` ->
   `{:error, :missing_idempotency_key}` if absent/`nil`. Unlike `complete_task/3`, which
   leaves `actor_id`/`idempotency_key` entirely to `EventStore.append/2`'s own validation
   (no pre-check), this design pre-checks both here — stated as a deliberate, disclosed
   divergence (§11 OQ-3): since `cancel_instance/3` has **no other** payload to validate
   (§3), skipping this check would mean the *only* two caller-supplied values ever reach
   `EventStore.append/2` unchecked, deferring 100% of this call's input validation to a
   dependency several Multi steps deep — this design chooses to fail fast instead, matching
   `create/2`'s own "every I/O-free check runs before the transaction opens" discipline
   applied to the one input surface this function actually has.
3. `TenantProvisioning.tenant_id_for_schema_name/1` against `opts[:prefix]` — the same
   schema-name-shape validation `create/2`/`complete_task/3`/`EventStore.append/2` all
   already perform at this same point in their own call sequence.

Only once all three succeed does the function proceed to open the `Ecto.Multi` (§7).

---

## 6. Instance-status eligibility — reusing `InstanceProjection.terminal?/1`, not a new
predicate

**No new "is this instance cancellable" function is written.** `InstanceProjection.terminal?/1`
(already shipped, REQ-023/043, §0) is the single existing source of truth for "does this
status forbid further mutation" — the exact predicate `EventStore.append/2`'s own
`active_instance_guard/3` (§0) already calls. §7 M3 below calls this same function, reused
unchanged, rather than writing a second, independently-maintained `:active`/`:cancelled`/
`:completed`/`:error` case split that could silently drift from the event-store's own
definition of "terminal." This is this design's concrete answer to the requirement text's
own instruction — *"REQ-025's append/1 already enforces exactly this at the event-store
layer via its active-instance guard on instance_projections.status, so verify that guard
now actually fires for engine-driven appends rather than duplicating the check"* — read as:
share the one predicate function both call sites already agree on, don't invent a second
one (§11 OQ-4 states precisely what "duplicating the check" was read to mean here, since
`cancel_instance/3` still needs *some* local check to produce AC2's own conflict error
before mutating any row — the instruction is read as "reuse the shared predicate," not
"perform no check of your own at all," since AC2 is this requirement's own, not
`append/2`'s).

**Concrete consequence, stated so it is not silently assumed:** `terminal?/1` returns
`false` for `:error`, not only for `:active`. An instance halted at `:error`
(REQ-061/EE-10's own future non-terminal halt, per this run's own SPLIT NOTE) is therefore
**not** rejected by this check — `cancel_instance/3` treats an `:error`-status instance the
same as an `:active` one: cancellable. No acceptance criterion of this run names the
`:error` case explicitly; this is this design's own reading of `terminal?/1`'s existing,
already-shipped contract (an ERROR-halted instance awaiting an operator's retry/discard per
REQ-061's own future scope is a reasonable candidate for "discard via cancel," not a case
this design invents new behavior for) — flagged as OQ-5 (§11) for REVIEWER to confirm this
reading, not silently assumed correct.

---

## 7. The `Ecto.Multi` — one transaction (EE-08 AC3)

All of the following run inside **one** `Ecto.Multi`/`Repo.transaction/1` call, matching
`create/2`'s and `complete_task/3`'s own established shape (§0):

| Step key | What it does | Reads from |
|---|---|---|
| `:open_tasks` (M1) | Row-lock + fetch every `tasks` row for this instance with `status == :pending`, **ordered deterministically** (`order_by: [asc: :id]`), `lock: "FOR UPDATE"` | — |
| `:instance_projection` (M2) | Row-lock + fetch the `instance_projections` row by `instance_id` (`lock: "FOR UPDATE"`); `nil` -> `:instance_not_found` | — |
| `:eligibility` (M3) | Pure check: `InstanceProjection.terminal?(projection.status)` (§6, reused unchanged) — `true` -> `{:error, {:instance_already_terminal, projection.status}}`, short-circuiting the whole transaction (nothing has been written yet — M1/M2 only locked/read) | M2 |
| `:task_cancellations` (M4) | For each `M1` row, `Task.complete_changeset/2` (already shipped, §0 — reused unchanged) with `%{status: :cancelled, cancelled_at: cancelled_at}` | M1 |
| `:token_cancellations` (M5) | Row-lock + fetch every `tokens` row for this instance with `status in [:active, :waiting]` (`lock: "FOR UPDATE"`, deterministic `order_by: [asc: :id]`), then `TokenRecord.advance_changeset/2` (already shipped, §0 — reused unchanged) with `%{status: :cancelled, cancelled_at: cancelled_at}` on each | — |
| `:event` (M6) | `EventStore.append/2` — `INSTANCE_CANCELLED` (§9); called while `instance_projections.status` is still whatever M2 read (`:active`/`:error`, never yet written by this Multi) — see §9's ordering note | M2 (`instance_id`), `attrs` (`actor_id`/`idempotency_key`) |
| `:projection` (M7) | `InstanceProjection.update_changeset/2` (already shipped, §0 — reused unchanged) with `%{status: :cancelled, cancelled_at: cancelled_at}` — `last_event_seq` intentionally omitted from `attrs`, same "`append/2`'s own M6 already advanced it, `Repo.update/2` only writes changed fields" reasoning `complete_task/3`'s own `reconcile_projection/5` already establishes (§0) | M2 |

**Ordering rationale (EE-12, the concurrency AC):**

- **M1 before M2 — `tasks` locked before `instance_projections`, matching `complete_task/3`'s
  own stated global rule verbatim ("always tasks before instance_projections, never the
  reverse, across every call site, to avoid a lock-ordering deadlock between two…calls").**
  `cancel_instance/3` is a second call site touching both tables under lock; using the
  opposite order from `complete_task/3` would create exactly the AB-BA deadlock shape that
  rule exists to prevent. §7.1 below traces the concrete race this ordering resolves.
- M3 (pure, no I/O) runs immediately after M2, before any write — so a terminal instance's
  cancel attempt writes **nothing** (AC2's "changes nothing"), even though M1 already
  acquired (harmless, released-on-rollback) locks on the open task rows.
- M4/M5 have no ordering dependency on each other (`tasks` and `tokens` are disjoint tables,
  each already individually locked by M1/M5's own `FOR UPDATE` read) — placed in this order
  purely to mirror M1's own table-first convention, not because either requires the other's
  output.
- M6 (event) **before** M7 (projection status write) — mirrors `complete_task/3`'s own
  `:event` (M9) before `:projection` (M10) ordering (§0) and is load-bearing here for a
  reason `complete_task/3` did not have to consider: `EventStore.append/2`'s own
  `active_instance_guard/3` (§0) reads `instance_projections.status` itself, inside the same
  outer transaction. If M7 ran first (setting `status: :cancelled`), M6's own guard would
  read that just-written `:cancelled` status and reject its own call with
  `{:error, {:instance_terminated, :cancelled}}` — `cancel_instance/3` would then be unable
  to ever append its own `INSTANCE_CANCELLED` event. Running M6 first, while
  `instance_projections.status` still reads as whatever M2 observed (`:active`/`:error`,
  never yet mutated by this Multi), is what makes the append succeed.
- M6's `EventStore.append/2` call is a genuine, unmodified call into REQ-025's shipped
  function (not a duplicate/simplified reimplementation) — this is the concrete mechanism
  by which "REQ-025's append/1 already enforces exactly this…guard now actually fires for
  engine-driven appends" (this run's own text) is exercised on every successful
  `cancel_instance/3` call, not merely asserted true.

### 7.1 The concurrent race — cancellation vs. task completion (AC4)

Traced precisely, not merely asserted, since this run's own AC requires "exactly one winner
and a distinct conflict error for the loser, run concurrently rather than sequentially":

Two transactions, `T_cancel` (`cancel_instance/3`) and `T_complete` (`complete_task/3`),
racing on the same instance, where `T_complete` targets a task that happens to be the
instance's **only** remaining open task (the scenario that makes the race's outcome
deterministic and independently checkable — see the note at the end of this section for the
general, more-than-one-open-task case):

- **`T_complete` acquires the task row's lock first.** `T_complete`'s own M1
  (`fetch_and_lock_task/3`, §0) locks and reads the row as `:pending`, proceeds through its
  own hop-chain, and (this being the instance's last open task) its own M10
  (`reconcile_projection/5`) sets `instance_projections.status = :completed`, then commits.
  `T_cancel`'s own M1 (`:open_tasks`, this design's) is blocked on that same row until
  `T_complete` commits; once released, `T_cancel`'s `WHERE status == :pending` predicate no
  longer matches that row (it is now `:completed`) — the row is silently excluded from
  `T_cancel`'s locked set, matching ordinary Postgres `SELECT … FOR UPDATE` re-evaluation
  semantics under READ COMMITTED. `T_cancel` proceeds to its own M2, locks
  `instance_projections`, and reads `status == :completed` — M3's `terminal?/1` check (§6)
  now returns `true`, so `T_cancel` returns `{:error, {:instance_already_terminal,
  :completed}}` (a genuine, distinct conflict error) and writes nothing. **`T_complete` is
  the winner, `T_cancel` is the loser with a distinct, typed conflict.**
- **`T_cancel` acquires the task row's lock first.** `T_cancel`'s own M1 locks the row
  (matched by `status == :pending`), and — being the instance's only open task — proceeds
  through M2-M7, setting that task to `:cancelled` and the instance to `:cancelled`, then
  commits. `T_complete`'s own M1 (`fetch_and_lock_task/3`) is blocked on the same row until
  `T_cancel` commits; once released, it re-reads the row under its own fresh lock and sees
  `status == :cancelled` — the already-shipped `fetch_and_lock_task/3` clause (§0) returns
  `{:error, {:task_not_pending, :cancelled}}` unchanged — **no `complete_task/3` code change
  is needed for this direction of the race; its existing error shape already covers it.**
  **`T_cancel` is the winner, `T_complete` is the loser with a distinct, typed conflict.**

**Whichever transaction acquires the contested task row's lock first is deterministically the
winner** — Postgres's own row-lock queueing (FIFO per row, no starvation for two competing
transactions) makes this outcome reproducible under an actual concurrent test (two processes
issuing their calls at the same time, one intentionally delayed by a millisecond via a test
hook, or simply run truly concurrently and asserting the disjunction "exactly one of the two
results is `{:ok, _}` and the other is one of the two named conflict tuples above" — this
design leaves the exact test mechanics to TEST-DESIGNER, per `complete_task/3`'s own design
doc precedent of citing the code path rather than prescribing the test).

**General, more-than-one-open-task case, stated so it is not silently glossed over:** if the
instance has *other* open tasks beyond the one `T_complete` targets, `T_complete` winning the
race does **not** terminate the instance (it stays `:active`) — `T_cancel`'s own M3 check
would then see `:active`, not a terminal status, and **both** operations succeed (the
targeted task completes, and the instance — along with its remaining open tasks — is
separately, successfully cancelled by `T_cancel`). This is not a violation of AC4: AC4
describes "a cancellation racing a task completion" produces "exactly one winner and a
distinct conflict error for the loser" at the level of **that specific task's own row lock**
(§7.1's own two bullets each end in exactly one winner/one distinct-error-loser for the
task's own fate), not at the level of "the whole instance's cancellability" in every possible
open-task-count scenario — a `T_complete` that is not the last task never conflicts with
`T_cancel` at the instance-status level, only a `T_complete` that would terminate the
instance does. TEST-DESIGNER's concrete scenario should therefore construct a single-open-
task instance, matching this section's own worked case, to get an unambiguous, deterministic
winner/loser pair.

---

## 8. DB tables/columns touched (no schema change — reuses REQ-043/023 exactly)

| Table | Columns this design reads | Columns this design writes | Migration/schema (unchanged) |
|---|---|---|---|
| `tasks` | `id`, `instance_id`, `status` (locked `FOR UPDATE`, filtered to `:pending`) | `status`, `cancelled_at`, via `Task.complete_changeset/2` (already shipped, reused) | `…110003_create_tasks.exs`, `task.ex` |
| `tokens` | `id`, `instance_id`, `status` (locked `FOR UPDATE`, filtered to `:active`/`:waiting`) | `status`, `cancelled_at`, via `TokenRecord.advance_changeset/2` (already shipped, reused) | `…110002_create_tokens.exs`, `token_record.ex` |
| `instance_projections` | Full row (locked `FOR UPDATE`) | `status`, `cancelled_at`, via `InstanceProjection.update_changeset/2` (already shipped, reused); `last_event_seq` via `EventStore.append/2`'s own existing M2 (§0) | `…110001_alter_instance_projections_add_engine_columns.exs`, `instance_projection.ex` |
| `events` | — | One `INSTANCE_CANCELLED` row via `EventStore.append/2` (§9), unchanged | REQ-025 (unchanged) |

**No migration file is added by this requirement.** Every table and column this design writes
to already exists — `tasks.cancelled_at`/`status: :cancelled`,
`tokens.cancelled_at`/`status: :cancelled`, and `instance_projections.cancelled_at`/
`status: :cancelled` were all already present in REQ-023/043's own shipped schemas (§0),
unused by any requirement until now.

---

## 9. `INSTANCE_CANCELLED` event append (REQ-025)

The payload (`Jason.encode!/1`) carries two keys: `cancelled_task_ids`
(`Enum.map(open_tasks, & &1.id)`, the `M1`-locked set, before any status mutation) and
`cancelled_token_ids` (`Enum.map(open_tokens, & &1.id)`, the `M5`-locked set) — both recorded
for audit/traceability, mirroring `complete_task/3`'s own `TASK_COMPLETED` payload's
`activated_nodes` field (§0's "record what this call actually touched" convention).
`event_attrs` built from this payload plus `instance_id` (from M2's locked projection),
`event_type: "INSTANCE_CANCELLED"`, and `actor_id`/`idempotency_key` read straight from
`attrs` (§3), passed to `EventStore.append/2` with `prefix: prefix`.

**`"INSTANCE_CANCELLED"` must already be a registered `event_type_registry` row for the
tenant, or this step (and therefore the whole call) fails with
`{:error, :unknown_event_type}`** — the same pre-existing, already-flagged gap `req045`'s own
OQ-3a documents for `"INSTANCE_STARTED"` and `req048`'s own OQ-6 documents for
`"TASK_COMPLETED"` (§0); this design inherits it rather than re-discovering it, and does not
attempt to seed the registry (out of scope, same as `req045`/`req048`).

---

## 10. SCOPE BOUNDARY — SCH-03 timer cancellation and REQ-056 SERVICE_TASK abandonment
(required moduledoc content)

`Letflow.Engine.cancel_instance/3`'s own moduledoc section must state, verbatim in
substance (this run's own text: "leave named, documented hooks for both, identifying S6 and
REQ-056 respectively — do not silently omit them from the moduledoc as if EE-08 were fully
covered"):

> R-Co's own EE-08 additionally (a) cancels pending timers atomically via SCH-03
> (`src/scheduler/`, S6 — not yet built in Letflow) and (b) abandons any in-flight
> `SERVICE_TASK` HTTP call best-effort (REQ-056's own future transport, out of S3 scope).
> **Neither exists in Letflow yet, and `cancel_instance/3` performs neither.** This function
> cancels what already exists today — `tasks`, `tokens`, and `instance_projections` rows,
> plus the one `INSTANCE_CANCELLED` event — and leaves both as named, documented gaps: a
> future S6 timer-scheduling requirement is expected to add its own timer-cancellation call
> alongside this function's own transaction (or a follow-up hook this function exposes for
> it to call), and REQ-056 is expected to add its own best-effort HTTP-abort call the same
> way. Neither is a silent omission — `cancel_instance/3` does not claim to fully implement
> EE-08's R-Co scope, only its S3-buildable subset.

Also states, per §2's own required content: the `Letflow.ParallelApproval`/
`Letflow.ApprovalSupervisor` deletion (§2's own verbatim block) and, per §1 of `req045`
(mirrored here rather than restated at length): "`POST /api/v1/instances/:id/cancel` is S4
(api-surface) scope — this function returns tagged tuples only, matching the boundary
`req045`/`req048` already established for `create/2`/`complete_task/3`."

---

## 11. Open questions — explicitly listed, not silently resolved

**OQ-1 (MINOR) — RESOLVED 2026-08-22, GH#326.** `cancel_attrs()` (§3) carries no
cancellation-reason/note field. R-Co's own literal `cancelInstance` signature
(`R-Co/src/engine/instance.zig:2513`) confirms this: its parameter list is
`(self, allocator, task_store, instance_id, actor_id)` — no `reason`/`note` field at all.
No S4 follow-up needed on this point.

**OQ-2 (MAJOR) — RESOLVED 2026-08-22, GH#326.** §4's decision **not** to drive `{:cancel_branch, branch_id}` through
`Transition` for `cancel_instance/3`'s own whole-instance cancellation, and the
"agreement by construction" argument offered in its place, is this design's own resolution
of a genuinely ambiguous AC ("an instance CANCELLED by the all-branches-cancelled path and
one CANCELLED by a direct caller request must reach the same persisted state… compared
explicitly"). Flagged for REVIEWER/RELEASE-VALIDATOR to confirm this reading — verifying
that "the same status atom, and no second exercised persistence path exists to diverge from
it" satisfies the AC — is the intended one, versus requiring `cancel_instance/3` to
literally call `Transition.transition(graph, state, {:cancel_branch, branch_id})` per branch.
At design time this would have always hit the "no cohort tracked" no-op given the
join-counters persistence gap `req048`'s own OQ-3 disclosed; ISS-0397 (2026-09-03) has
since closed that persistence gap, but §0's Access-gap finding (R-Co's own `cancelInstance`
never drives per-branch transition events either) is an independent, still-standing reason
this design's whole-instance-only approach is correct, not merely a stopgap — see ISS-0402
(resolved 2026-09-05), which investigated exactly this question after ISS-0397 landed and
found no current caller, UAT scenario, or scheduled requirement needs branch-level
cancellation.

**OQ-3 (MINOR).** §5 step 2 pre-validates `actor_id`/`idempotency_key` before the
transaction opens, diverging from `complete_task/3`'s own "no pre-check, let `append/2`
validate" convention (§0). Flagged for REVIEWER to confirm this divergence (motivated by
`cancel_instance/3` having no other payload to validate, §5) is acceptable, or whether
consistency with `complete_task/3`'s convention should be preferred instead (removing this
design's own pre-check and letting `EventStore.append/2`'s own
`:missing_actor_id`/`:missing_idempotency_key` errors surface from inside M6 instead).

**OQ-4 (MINOR).** §6's reading of "verify that guard now actually fires for engine-driven
appends rather than duplicating the check" as "reuse `InstanceProjection.terminal?/1`,
don't invent a second predicate" (rather than "perform no local eligibility check at all
and rely solely on `EventStore.append/2`'s own guard") is this design's own interpretation.
The alternative reading — relying purely on M6's own `EventStore.append/2` call to produce
AC2's conflict, with no separate M3 check — was considered and rejected because it would
leave M1/M4/M5 (task/token cancellation) running and potentially partially visible before
the conflict is ever discovered, and because it would not, on its own, prevent a second
concurrent `cancel_instance/3` call from doing the same redundant work before either
commits (§7's M2 row-lock is what actually serializes two concurrent `cancel_instance/3`
calls on the same instance — a scenario this run's own AC4 does not name explicitly, but
which M2's lock incidentally also protects against). Flagged for REVIEWER to confirm.

**OQ-5 (MINOR).** §6's reading of `InstanceProjection.terminal?/1`'s existing `:error ->
false` behavior as "an `:error`-status instance is cancellable, same as `:active`" is this
design's own extension of an already-shipped predicate to a case (REQ-061/EE-10's own future
non-terminal `ERROR` halt) that does not fully exist yet in this codebase (REQ-061 is
`pending`). Flagged for REVIEWER to confirm this reading, and for REQ-061's own
CODE-DESIGNER to confirm it does not conflict with whatever REQ-061 itself decides about
operator-driven recovery from `ERROR`.

**OQ-6 (MINOR, inherited not new).** `"INSTANCE_CANCELLED"` must be a registered
`event_type_registry` row per tenant for M6 (§9) to succeed — the same pre-existing,
already-flagged gap `req045`'s OQ-3a and `req048`'s OQ-6 document for
`"INSTANCE_STARTED"`/`"TASK_COMPLETED"`. This design does not attempt to seed the registry;
whoever resolves `req045`'s OQ-3a resolves this one identically.

---

## 12. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-EE52-1 | `cancel_instance/3` never mutates `tasks`/`tokens`/`instance_projections`/`events` rows outside one `Ecto.Multi`/`Repo.transaction/1` — all four commit or roll back together | §7 |
| INV-EE52-2 | An instance with no matching `instance_projections` row and one whose status is already `:completed`/`:cancelled` return two distinct, separately pattern-matchable errors (`{:error, :instance_not_found}` vs. `{:error, {:instance_already_terminal, status}}`) | §7, M2/M3 |
| INV-EE52-3 | Cancelling an already-terminal instance writes nothing — verified by re-reading `tasks`/`instance_projections`/`events` after a rejected call | §7 (M3 short-circuits before M4/M5/M6/M7) |
| INV-EE52-4 | Cancelling an instance with zero open tasks/tokens still appends exactly one `INSTANCE_CANCELLED` event and still sets `instance_projections.status = :cancelled` | §7 (M1/M5 may both be `[]`; M6/M7 are unconditional) |
| INV-EE52-5 | Exactly one `INSTANCE_CANCELLED` event is appended per successful call | §7 M6, §9 |
| INV-EE52-6 | `tasks` are always locked before `instance_projections`, matching `complete_task/3`'s own global lock-ordering rule, on every call site | §7 (M1 before M2), §7.1 |
| INV-EE52-7 | No `tenant_id` column or derivation is added to any of the four tables this design touches (Decision 0006 D2) | §0 |
| INV-EE52-8 | This module performs zero HTTP status-code mapping (§10's S4 boundary restatement) | §10 |
| INV-EE52-9 | `Letflow.ParallelApproval`/`Letflow.ApprovalSupervisor` no longer exist once this requirement ships — no code path in this codebase can start a new instance of either | §2 |

---

## 13. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Task` (req043, shipped) | This code → that | `complete_changeset/2`, reused unchanged (§7 M4) |
| `Letflow.Engine.TokenRecord` (req043, shipped) | This code → that | `advance_changeset/2`, reused unchanged (§7 M5) |
| `Letflow.EventStore.InstanceProjection` (req023/043, shipped) | This code → that | `terminal?/1` (§6), `update_changeset/2` (§7 M7), both reused unchanged |
| `Letflow.EventStore` (req025, shipped) | This code → that | `append/2` for `INSTANCE_CANCELLED` (§9) — the concrete mechanism this run's own text asks to be "verified… rather than duplicated" |
| `Letflow.TenantProvisioning` (req022, shipped) | This code → that | `tenant_id_for_schema_name/1`, pre-transaction (§5) |
| `Letflow.Engine.Transition`, `InstanceState`, `Token`, `JoinCounter` (req044/050/051, shipped) | **Not called** by this design | §4/§0's Access-gap finding explains why: R-Co's own `cancelInstance` (EE-08) never drives per-branch events through transition/graph machinery either — plain unconditional SQL UPDATEs — so this is architectural parity, not a stopgap for a missing table. ISS-0397 (2026-09-03) later closed the join_counters persistence gap this cell used to cite as the blocker; that fix does not change this conclusion (see ISS-0402, resolved 2026-09-05). `req051`'s own `:cancel_join` pure logic remains untested by any real caller until a future requirement adds branch-level cancellation as a deliberate product decision |
| `lib/letflow/parallel_approval.ex`, `lib/letflow/approval_supervisor.ex` (pre-existing) | This requirement deletes both | §2 |
| `lib/letflow/application.ex` | This requirement edits | Removes `Letflow.ApprovalSupervisor`'s child-spec entry (§0, §2) |
| `lib/letflow/sandbox_pool.ex` | This requirement edits (moduledoc text only) | Removes the stale `Letflow.ApprovalSupervisor` cross-reference (§2 point 3) |
| S4 (`POST /api/v1/instances/:id/cancel`, not yet built) | S4 → `Letflow.Engine.cancel_instance/3` | Status-code mapping, entirely out of scope here (§10) |
| S6 (SCH-03 timer cancellation, not yet built) | Future, named hook only | §10 — not called by this design |
| REQ-056 (SERVICE_TASK HTTP abandonment, not yet built) | Future, named hook only | §10 — not called by this design |
| REQ-053/054 (state reconstruction / snapshot persistence, not yet built) | Future, unrelated to this call path | This design's §7 needs no scoped `InstanceState` reconstruction at all (unlike `complete_task/3`'s own §6) — it operates directly on `tasks`/`tokens`/`instance_projections` rows, so it does not block on either |

---

## 14. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| "cancelling an ACTIVE instance sets every open task to CANCELLED, appends exactly one INSTANCE_CANCELLED event, and sets the instance status to CANCELLED -- all committed together, verified by reading tasks, instance_projections and events back" | §7 (one `Ecto.Multi`), M4 (tasks), M6 (event), M7 (status), INV-EE52-1/5 |
| "cancelling an already-CANCELLED or already-COMPLETED instance returns a distinct conflict error and changes nothing; cancelling an ACTIVE instance with zero open tasks still appends INSTANCE_CANCELLED" | §7 M3 (`{:error, {:instance_already_terminal, status}}`, INV-EE52-2/3) + INV-EE52-4 (zero-open-tasks edge case, M1 may be `[]`, M6/M7 unconditional) |
| "after cancellation, a further append via REQ-025's append/1 is rejected by its existing active-instance guard -- demonstrated against the real event store rather than asserted from the code" | §7 M7 (persists `status: :cancelled`) + §6/§9 (the exact, unmodified `EventStore.append/2`/`active_instance_guard/3` this leaves in place to reject it) — TEST-DESIGNER's job to demonstrate against the real store, per this design's cited code path |
| "a cancellation racing a task completion on the same instance resolves with exactly one winner and a distinct conflict error for the loser, run concurrently rather than sequentially" | §7.1 (both race directions traced precisely, citing the exact lock-order mechanism and the exact resulting error tuple for each) |
| "an instance cancelled via REQ-051's all-branches-cancelled join path and one cancelled by a direct cancel_instance call reach the same persisted state (status, task statuses, appended event), compared explicitly" | §4 (full reasoning: why `{:cancel_branch, _}` is not wired, and the two concrete "agreement by construction" seams — same status atom, no second exercised persistence path) |
| "the moduledoc names the SCH-03 timer-cancellation hook (S6) and the in-flight SERVICE_TASK abandonment hook (REQ-056) as explicitly out of scope, rather than implying EE-08 is fully covered" | §10 (required verbatim-in-substance moduledoc content) |
| "the moduledoc states concretely whether lib/letflow/parallel_approval.ex and Letflow.ApprovalSupervisor are deleted or retained-with-a-stated-reason, and mix test passes with the actual output quoted after the change" | §2 (DELETE, both, with reasoning) — `mix test` execution/quoting is ELIXIR-DEV's/TEST-RUNNER's job, not this design's |
| OPEN QUESTION — process termination, flagged not silently resolved | §15 below |

---

## 15. OPEN QUESTION (as instructed by this run's own text) — process termination

**This run's own text:** *"if REQ-045's process-vs-row resolution chose supervised
processes, cancellation must terminate a live process, and killing a process is exactly the
exit path that Elixir's try/after does not cover — the same crash-safety question REQ-040
flagged for sandbox teardown. Leave the concrete mechanism to CODE-DESIGNER, citing
REQ-040's precedent."*

**Stated precisely, not silently resolved either way:** the premise's antecedent is false
for this requirement's own actual scope. `req045` §1 (§0 above, read in full) resolved the
stage's process-vs-row question as: *"`create/2` is a plain function on a new context
module… No `:gen_statem`, no `DynamicSupervisor`, no per-instance process is introduced."*
`complete_task/3` (`req048`) extends that same resolution without revisiting it. **There is
therefore no live process representing a running instance today, and `cancel_instance/3`
(§7) terminates none** — it is, like `create/2`/`complete_task/3`, a bounded sequence of
`Ecto.Multi` steps that either all commit or all roll back; a crash mid-call is covered by
ordinary Postgres transaction atomicity (an uncommitted transaction simply never commits —
no external, non-transactional resource is claimed anywhere in §7, unlike `req040`'s
`SandboxPool.claim/2`, so no `try/rescue`-style best-effort-cleanup wrapper is needed here at
all — flagged explicitly as the reason this design, unlike `req040`'s, needs no such
wrapper).

**Not fully moot, stated so it is not dropped rather than merely deferred:** `stage-3-
instance-engine.md`'s own Early finding (§0) names REQ-056 (service task dispatch) and
REQ-057 (plugin registry) as the strong future case for a supervised process, and this run's
own SCOPE BOUNDARY (§10) already names REQ-056's in-flight `SERVICE_TASK` HTTP-call
abandonment as an explicit, undone hook. **If and when REQ-056 introduces a supervised
process for an in-flight service-task dispatch, a future requirement extending
`cancel_instance` (or REQ-056 itself) to abort that process will face exactly the class of
problem this run's text names** — a hard `Process.exit(pid, :kill)`/node crash is not
covered by `try/after` (or `try/rescue`, which also does not run on a hard kill — `req040`
§2.3's own explicit statement, re-confirmed here rather than re-derived). This design leaves
that mechanism entirely to whichever future requirement introduces the process in the first
place (REQ-056/057's own CODE-DESIGNER, citing this section and `req040` §2.3 as precedent)
— it is not resolved, deferred, or silently assumed away here, because no process exists
yet for **this** requirement's own scope to terminate.
