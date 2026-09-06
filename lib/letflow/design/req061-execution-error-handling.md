PROVENANCE (historical, not current decision authority):
# Design: REQ-061 — Execution error handling (`instance.zig` `setInstanceError`, EE-10)

**Requirement:** REQ-061 (this run's handoff `context.requirement_text.REQ-061`, stage S3)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ061-20260819`, WF-02 Step 1
**This document produces:** `Letflow.Engine.ExecutionError.append_multi/3` (the shared,
Multi-composable sink every engine-internal failure funnels into) and
`Letflow.Engine.set_instance_error/2` (its standalone entry point), the `EXECUTION_ERROR`
event payload shape, the exact rewiring of REQ-049's schema-violation-on-merge case and
REQ-050's no-matching-gateway-edge case inside `complete_task/3`'s own `Ecto.Multi`, the
concurrency/eligibility protocol (AC5), DB columns touched (none new), the moduledoc content
this run's text requires (OBS-05 hook, ERROR-is-not-terminal), invariants, cross-module
dependencies, every acceptance criterion mapped to a concrete design element, and — as
explicitly instructed — the AC4 "at least three of five" tension, stated rather than
silently resolved. No implementation code — signatures/shapes only, matching
`req045`/`req048`/`req052`'s own convention.

---

## 0. Sources read for this design

- This run's handoff — `context.requirement_text.REQ-061` (full description, including the
  IMPORTANT TENSION paragraph) and `task.acceptance_criteria`, per `core-directives.md`'s
  "Load Scoped Context, Not Whole Files."
- `docs/agents/instructions/core-directives.md` (full).
- `docs/guides/backend_developer_guide.md` (full) — §3.5 error shapes, §3.6 SQL-locking,
  §3.7 migrations, §4 self-review checklist.
- `docs/migration/stage-3-instance-engine.md` (full) — the EE-01..EE-12 breakdown; the
  explicit note that REQ-061 "was split out of REQ-052 on sizing review... cancellation is
  caller-initiated and terminal, while error handling is engine-internal and halts
  non-terminally at ERROR pending an S6 dead-letter action"; the SCOPE BOUNDARY naming
  OBS-05's dead-letter queue as S6, out of scope here with a named hook required instead of a
  partial implementation.
- `lib/letflow/design/req052-instance-cancellation.md` (full) — the sibling terminal-transition
  design this doc's `Ecto.Multi`/lock-ordering/event-before-projection-write discipline
  mirrors (§7 there); its §6 already establishes `InstanceProjection.terminal?/1` returning
  `false` for `:error` and its own OQ-5 already flags that `cancel_instance/3` treats an
  `:error`-status instance as cancellable, deliberately not revisited by this design (§11
  OQ-5 there is the exact seam this design's own moduledoc content must not contradict).
- Shipped code, read directly (not paraphrased):
  - `lib/letflow/engine.ex` (full, 1619 lines, current `main`) — `create/2`,
    `complete_task/3` (§729–1300) and `cancel_instance/3` (§1302–1619) in full. In
    particular:
    - `merge_output_variables/2` (line 1043) — REQ-049's current call site. Today it wraps
      `VariableMerge.merge/3`'s `{:rejected, unchanged_variables, events}` outcome as
      `{:error, {:unexpected_variable_rejection, events}}`, returned from a bare
      `Multi.run(:merge, ...)` step. **Confirmed: this aborts the whole `Ecto.Multi` —
      nothing is persisted, `instance_projections.status` stays `:active`, no `ERROR` state
      and no `EXECUTION_ERROR` event exist anywhere today.** This is the "ad-hoc error
      write" (in fact, not even a write) this requirement must rewire.
    - `dispatch_task_completion_hop_chain/2` (line 1056) — REQ-050's current call site.
      Today it wraps `Transition.transition/3`'s `{:error, {:no_matching_edge, node_id,
      evaluated_conditions}}` (raised via `dispatch_task_completion/4` /
      `dispatch_exclusive_gateway/4` in `transition.ex`, confirmed by direct read, §0 below)
      as `{:error, {:transition_failed, reason}}`, again from a bare `Multi.run(:transition,
      ...)` step. **Confirmed: same outcome — the whole Multi aborts, nothing persists.**
    - `fetch_and_lock_instance_projection/3` (line 915) — already rejects a non-`:active`
      instance (including `:error`) with `{:error, {:instance_not_active, status}}`, and
      `complete_error()`'s own union (line 751) **already includes**
      `{:error, {:instance_not_active, status :: :completed | :cancelled | :error}}`.
      **This means AC3 ("an instance in ERROR rejects task completion with a distinct
      conflict error and remains in ERROR afterwards") is already satisfied by shipped
      REQ-048 code, with no change needed** — confirmed precisely in §6 below rather than
      asserted from memory, since this is the one AC this design does *not* need to build
      new logic for.
    - `build_task_activation_and_reconciliation_multi/3` (line 1087) and
      `interpret_complete_result/1` (line 1274, 1298) — the exact `Multi.merge/2` and
      result-unwrapping shape this design's own §5 mirrors for its own branching.
  - `lib/letflow/engine/variable_merge.ex` (full, 195 lines) — `merge/3`'s
    `{:rejected, current_variables, [{:execution_error, key, rejected_value,
    :variable_schema_rejected, failures}]}` return shape (line 160-164). **This module's own
    moduledoc already names REQ-061 by id** ("Dependency ordering: this module does not
    depend on REQ-061" / "A rejected batch is signalled purely through `merge/3`'s own
    return value... which the caller... inspects and acts on, including invoking whichever
    REQ-061 function eventually performs the actual ERROR transition") — confirming this
    design's own read of the intended seam, not inventing it. `current_variables` is
    returned **unchanged** on rejection (§9 below relies on this directly for the
    variable-snapshot value).
  - `lib/letflow/engine/transition.ex` (full, 900+ lines skimmed at the relevant sections) —
    `transition_error()`'s `{:no_matching_edge, node_id :: String.t(), evaluated_conditions
    :: [evaluated_condition()]}` member (line 140), `dispatch_exclusive_gateway/4` (line
    424) and `dispatch_task_completion/4` (line 362) both returning it. Confirmed `Transition`
    is pure (no `Repo`, per its own moduledoc's grep-checkable claim, reused unmodified by
    this design — §4 below, this design calls no `Transition` function itself).
  - `lib/letflow/event_store/instance_projection.ex` (full, 180 lines) — `status` `Ecto.Enum`
    already carries `:error`; `terminal?/1` (line 178) **already** returns `false` for
    `:error` — the exact "ERROR is not terminal" contract this run's own text asks the
    moduledoc to restate, already codified, not something this design invents.
    `error_detail` (`:map`, line 117) is an **already-existing, currently-unused** column —
    no migration needed for this design's own status/detail write (§8 below).
    `update_changeset/2`'s cast list (line 156-164) already includes `:status` and
    `:error_detail`, reused unchanged.
  - `lib/letflow/event_store.ex` (full, 1149 lines) — `append/2`'s idempotency-key handling
    (global-uniqueness `unique_constraint`/`conflict_target: :idempotency_key`, confirmed by
    direct read of `fetch_idempotency_key/1` and the idempotency insert step, lines 108-460),
    which is why §9 below can safely reuse the *original* triggering call's
    `actor_id`/`idempotency_key` for the `EXECUTION_ERROR` event — exactly one of
    `TASK_COMPLETED`/`EXECUTION_ERROR` is ever appended per `complete_task/3` call (the two
    branches are mutually exclusive within one Multi, §5), so no idempotency-key collision is
    possible between them. `active_instance_guard/3` (line 357) confirmed as the same shared
    predicate `req052`'s design already traced — reused unmodified, not touched by this
    design.
  - `lib/letflow/engine/task_activation.ex` (full moduledoc + `append_multi_from_existing_records/6`
    signature) — the established **"zero `Repo` calls of its own, every write happens inside
    the caller's already-open `Ecto.Multi`" composable-helper pattern** (its own moduledoc,
    "Zero `Repo` calls of its own (INV-EE47-7)") this design's own
    `ExecutionError.append_multi/3` copies directly, so this design introduces no new
    architectural shape to the codebase.
- `docs/anti-patterns.md` (current entries) — no entry bears directly on this module's own
  logic.

PROVENANCE (historical, not current decision authority):
**Access gap — resolved (GH#328, ISS-0100):** `R-Co/src/engine/instance.zig` is reachable in
this environment; the earlier "unreachable" framing below (and OQ-1, §12) no longer holds and
is kept only as a record of what this design was built without at the time. Read directly:
`setInstanceError()` (L3078–3182, signature `pub fn setInstanceError(self: *InstanceStore,
allocator: std.mem.Allocator, args: SetInstanceErrorArgs) SetInstanceErrorError!void`) and
`SetInstanceErrorArgs` (L289–306: `instance_id`, `error_type: ErrorType`, `affected_node:
?[]const u8`, `affected_field: ?[]const u8`, `reason: []const u8`, `variable_state: []const
u8`, `evaluated_conditions: ?[]const EvaluatedCondition`, `actor_id: []const u8`). This
design's own shape (§2 `error_args()`) matches it field-for-field: `affected_node`/
`affected_field` collapse into this design's `affected()` tagged union, `variable_state` maps
to `variables`, `reason`/`actor_id` map 1:1.

What "the error-code table" actually is at ~L4060–4071 (inside `buildExecutionErrorPayload/3`,
not a separate table): a `switch` over R-Co's own closed `ErrorType` enum (L244–273, 10
variants — `NO_MATCHING_EDGE`, `SCHEMA_VIOLATION`, `SERVICE_TASK_FAILURE`,
`TRANSFORM_EVALUATION_ERROR`, `TRANSFORM_RESULT_NON_OBJECT`, `PIN_MISSING`,
`SUB_PROCESS_MISSING_REQUIRED_INPUT`, `SUB_PROCESS_INPUT_SCHEMA_VIOLATION`,
`SUB_PROCESS_MISSING_REQUIRED_OUTPUT`, `SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION`) that stringifies
each variant to its JSON `error_type` value. This corrects §2's own characterization below —
see the note there.

---

## 1. Module/file layout

**One new file:** `lib/letflow/engine/execution_error.ex` (`Letflow.Engine.ExecutionError`) —
the composable core, matching the codebase's own convention of one `lib/letflow/engine/*.ex`
module per EE-* concern that has real logic of its own (`variable_merge.ex`, `transition.ex`,
`task_activation.ex`), rather than adding more private functions to the already-1619-line
`lib/letflow/engine.ex`.

**One new public function on the existing `Letflow.Engine` module:** `set_instance_error/2` —
the standalone entry point, alongside `create/2`, `complete_task/3`, `cancel_instance/3`,
matching that module's own "one context-module function per EE-* public operation" shape
(`req052` §1).

**`lib/letflow/engine.ex` is edited, not replaced:** `merge_output_variables/2` (line 1043)
and `dispatch_task_completion_hop_chain/2` (line 1056) are changed to never return
`{:error, _}` themselves (§5 below) — they route the EE-10 case into
`ExecutionError.append_multi/3` instead of aborting the transaction. **No new migration** —
every column this design writes (`instance_projections.status`, `.error_detail`) already
exists (§8).

---

## 2. `Letflow.Engine.ExecutionError` — types

```
@type error_type ::
        :variable_schema_rejected
      | :no_matching_gateway_edge
      | :service_task_retries_exhausted
      | :plugin_error_outcome
      | :subprocess_interface_violation
      | atom()
```

A closed-looking but explicitly **open** union (the trailing `atom()` is deliberate, not a
typo). **Correction (GH#328, ISS-0100, resolves OQ-1):** R-Co's own error-code table
(~L4060–4071, read directly — see §0) is *not* a mapping — it is a hardcoded `switch` over a
*closed* 10-variant `ErrorType` enum (L244–273). This design's open union is therefore a
deliberate departure from R-Co's shape, not a port of it: R-Co has no extensibility point here
at all, while this design adds one via the trailing `atom()` specifically because REQ-062's
own error shapes were still unresolved when this was written (OQ-2). The five named atoms map
1:1 onto this run's own five calling paths (REQ-049, REQ-050, REQ-056, REQ-057, REQ-062), and
those five are a *coarser* grouping than R-Co's 10 `ErrorType` variants by design — e.g. this
design's single `:variable_schema_rejected` corresponds to R-Co's `SCHEMA_VIOLATION`, and this
design's `:subprocess_interface_violation` corresponds to four separate R-Co variants
(`SUB_PROCESS_MISSING_REQUIRED_INPUT`, `SUB_PROCESS_INPUT_SCHEMA_VIOLATION`,
`SUB_PROCESS_MISSING_REQUIRED_OUTPUT`, `SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION`) — confirming
OQ-2's own premise that R-Co treats these as four distinct causes, not one. REQ-062's four
SPC-01 sub-process interface-violation sub-cases are not four separate atoms here — they are
expected to share `:subprocess_interface_violation` and distinguish themselves via
`error_args.details` (below), left to REQ-062's own CODE-DESIGNER to shape precisely (§12
OQ-2, now with R-Co's exact four variant names above to work from).

```
@type affected ::
        {:node, node_id :: String.t()}
      | {:field, field :: String.t()}
```

AC1's "affected node or field" as a two-member tagged union rather than one bag-of-optional-keys
map — every caller must say which kind of thing failed. REQ-049 (a variable key) uses
`{:field, key}`; REQ-050 (a gateway node) uses `{:node, node_id}`.

```
@type error_args :: %{
        required(:instance_id)      => Ecto.UUID.t(),
        required(:error_type)       => error_type(),
        required(:affected)         => affected(),
        required(:reason)           => String.t(),
        required(:variables)        => map(),
        optional(:details)          => map(),
        required(:actor_id)         => Ecto.UUID.t() | nil,
        required(:idempotency_key)  => String.t()
      }
```

- `reason` — the human-readable string AC1 requires (e.g. `"variable 'approved_amount'
  failed schema validation"`, `"no outgoing edge matched conditions and no default edge
  configured for gateway node <id>"`). Built by the caller, not by `ExecutionError` itself —
  this module renders no strings of its own, it only persists what it is handed (matches
  `EventStore.append/2`'s own "caller builds the payload" convention).
- `variables` — the instance variable-map snapshot **as it stood at the moment of the
  error**, AC1/AC5's load-bearing field. §9 states precisely which value each of REQ-049's
  and REQ-050's own call sites supplies here, since the two are not the same instant (§9's
  own asymmetry note).
- `details` — optional caller-specific diagnostic payload (REQ-049: `%{rejected_value:,
  failures:}`; REQ-050: `%{evaluated_conditions:}`) — extra context beyond AC1's four
  mandatory fields, embedded in the event payload (§9) but not separately validated by this
  module.
- `actor_id`/`idempotency_key` — **required, not defaulted by this module.** For REQ-049/050
  (§5), the caller supplies the original triggering call's own `actor_id`/`idempotency_key`
  (already available, already validated by that caller's own pre-transaction phase). For a
  genuinely actor-less future caller (REQ-056's background retry-exhaustion, no human in the
  loop) this module does **not** invent a system-actor convention — that is this run's own
  named OPEN QUESTION (§12 OQ-3), left for REQ-056's own CODE-DESIGNER, since inventing one
  here would silently pre-empt a decision this requirement's own text does not ask this
  design to make.

```
@type eligibility_error :: {:error, {:instance_not_found}}
                          | {:error, {:instance_already_error, error_detail :: map()}}
                          | {:error, {:instance_terminal, status :: :completed | :cancelled}}
```

---

## 3. `Letflow.Engine.ExecutionError.append_multi/3` — the shared composable sink

```
@spec append_multi(
        Ecto.Multi.t(),
        error_args :: error_args(),
        opts :: [prefix: String.t(), locked_projection: InstanceProjection.t() | nil]
      ) :: Ecto.Multi.t()
```

**This is "the single, shared path every engine-internal failure funnels into"** (this run's
own text) — the one place the `status: :error` write, the `EXECUTION_ERROR` event, and the
eligibility check are implemented. Every caller (existing or future) reaches persisted `ERROR`
state only through this function. Matches `TaskActivation.append_multi_from_existing_records/6`'s
own established shape exactly: **zero `Repo` calls of its own** — every step appended runs
inside the *caller's* already-open `Ecto.Multi`/transaction (`task_activation.ex`'s own
INV-EE47-7, copied here as this design's INV-EE61-7, §11).

`opts[:locked_projection]`: when the caller already holds a `SELECT ... FOR UPDATE` lock on
this instance's `instance_projections` row within the *same* transaction (REQ-049/050's own
call sites, §5 — `complete_task/3`'s own M2 already locked it), pass the already-fetched
struct here to avoid a second, redundant (though harmless — Postgres permits a transaction
to re-acquire its own row lock without blocking) `SELECT FOR UPDATE`. When absent (`nil`,
the default — every standalone caller via `set_instance_error/2`, §4), `append_multi/3`
performs its own lock+fetch as its first appended step.

### Steps appended (in order), as a table — matching `req052` §7's own presentation

| Step key | What it does | Reads from |
|---|---|---|
| `:execution_error_projection_lock` (only appended when `opts[:locked_projection]` is `nil`) | Row-lock + fetch `instance_projections` by `error_args.instance_id` (`lock: "FOR UPDATE"`); `nil` row → `{:error, {:instance_not_found}}` | — |
| `:execution_error_eligibility` | Pure check against the locked/passed-in projection: `status == :completed` or `:cancelled` → `{:error, {:instance_terminal, status}}`; `status == :error` (already halted by a prior EE-10) → `{:error, {:instance_already_error, projection.error_detail}}` (AC5's own conflict shape); `status == :active` → proceed | `:execution_error_projection_lock`, or `opts[:locked_projection]` directly |
| `:execution_error_event` | `EventStore.append/2` — one `EXECUTION_ERROR` event (§9), built from `error_args` | `error_args`, `opts[:prefix]` |
| `:execution_error_projection_update` | `InstanceProjection.update_changeset/2` (already shipped, reused unchanged) with `%{status: :error, error_detail: <compact detail map, §8>}` — `last_event_seq` intentionally omitted, same "`append/2`'s own M step already advanced it, `Repo.update/2` only writes changed fields" reasoning `complete_task/3`'s/`cancel_instance/3`'s own reconciliation steps already establish (§0) | `:execution_error_projection_lock`/`opts[:locked_projection]` |

**Ordering rationale, mirroring `req052` §7's own EE-12 reasoning exactly:**
`:execution_error_event` runs **before** `:execution_error_projection_update`, for the
identical reason `req052`'s own M6-before-M7 ordering exists: `EventStore.append/2`'s own
`active_instance_guard/3` reads `instance_projections.status` inside the same transaction —
if the projection write ran first (setting `status: :error`), the guard would read the
instance as already-terminated-equivalent... **except `:error` is not one of the statuses
`active_instance_guard/3` rejects** (only `:completed`/`:cancelled` per
`InstanceProjection.terminal?/1`, confirmed §0) — so this ordering is not strictly
load-bearing the way it is for `cancel_instance/3`'s `CANCELLED` write, but is kept identical
regardless, both for consistency with the established pattern and because a *future* change
to what `active_instance_guard/3` rejects should not silently break this call site by
depending on today's specific behavior.

### The eligibility check *is* AC5's mechanism

Two concurrent operations both triggering EE-10 on one instance: both attempt
`:execution_error_projection_lock` (or arrive already holding the lock via
`opts[:locked_projection]`, in which case whichever caller's *own outer* transaction commits
first is the effective winner — see §5's own race note for the REQ-049/050 case specifically).
Whichever acquires the row lock first proceeds through `:execution_error_event` and
`:execution_error_projection_update` and commits, setting `status: :error`. The second,
now unblocked, re-reads the row under its own fresh lock and sees `status == :error` —
`:execution_error_eligibility` returns `{:error, {:instance_already_error, error_detail}}`,
a genuine, distinct conflict, and writes nothing. This is the same FIFO-row-lock-queueing
mechanism `req052` §7.1 traces in detail for its own cancel-vs-complete race; not re-derived
here, only pointed at.

---

## 4. `Letflow.Engine.set_instance_error/2` — the standalone public entry point

```
@type standalone_error_attrs :: %{
        required(:instance_id)     => Ecto.UUID.t(),
        required(:error_type)      => ExecutionError.error_type(),
        required(:affected)        => ExecutionError.affected(),
        required(:reason)          => String.t(),
        required(:variables)       => map(),
        optional(:details)         => map(),
        required(:actor_id)        => Ecto.UUID.t() | nil,
        required(:idempotency_key) => String.t()
      }

@type set_error_opts :: [prefix: String.t()]

@type set_error_result :: %{
        instance_id: Ecto.UUID.t(),
        status: :error,
        error_type: ExecutionError.error_type(),
        error_detail: map()
      }

@type set_error_error ::
        {:error, :invalid_instance_id}
      | {:error, :invalid_schema_name}
      | {:error, :missing_actor_id_or_idempotency_key}
      | {:error, :instance_not_found}
      | {:error, {:instance_terminal, status :: :completed | :cancelled}}
      | {:error, {:instance_already_error, error_detail :: map()}}
      | {:error, {:event_append_failed, term()}}
      | {:error, Ecto.Changeset.t()}
      | {:error, term()}

@spec set_instance_error(
        attrs :: standalone_error_attrs(),
        opts :: set_error_opts()
      ) :: {:ok, set_error_result()} | set_error_error()
```

Signature shape mirrors `create/2`'s own `(attrs, opts)` form (no separate positional id
argument, since `instance_id` is one of several required fields on `attrs` here, not the
sole identifying argument the way `task_id`/`instance_id` are for `complete_task/3`/
`cancel_instance/3`). Implementation: the same pre-transaction/no-I/O-on-failure discipline
every other public function in this module already follows (`cast_instance_id/1` reused
unchanged from `cancel_instance/3`, §0; a defensive check that `actor_id` is present *or*
explicitly `nil` — `nil` is a legal value here unlike `cancel_instance/3`'s own
`missing_actor_id` rejection, since REQ-061's own future actor-less callers, §12 OQ-3, may
need to pass `nil` — but `idempotency_key` is still required, non-nilable, matching every
other event-appending call in this module), then:

```
Multi.new()
|> ExecutionError.append_multi(error_args, prefix: prefix)
|> Repo.transaction()
|> <same {:ok, %{...}} | {:error, failed_step, reason, _changes} unwrapping shape
   every other public function in this module already uses>
```

This is the entry point future REQ-056 (exhausted service-task retries — plausibly triggered
from outside any other function's own open transaction, e.g. a scheduled retry-check) and
REQ-057/REQ-062 (whichever of their own call sites is *not* already inside another function's
Multi) are expected to call. Where a future caller *is* already inside its own Multi (e.g. a
hypothetical future in-Multi SPC-01 violation check inside REQ-062's own sub-process creation
path, symmetric to REQ-049/050's own shape here), it calls `ExecutionError.append_multi/3`
directly instead, exactly as §5 below does — `set_instance_error/2` is not the only legal way
to reach this sink, `ExecutionError.append_multi/3` is the actual shared core; `
set_instance_error/2` is one (the standalone) caller of it, on equal footing with
`complete_task/3`'s own two in-Multi call sites.

---

## 5. Rewiring `complete_task/3` — REQ-049 and REQ-050's call sites

**The core problem this section solves:** `merge_output_variables/2` and
`dispatch_task_completion_hop_chain/2` are both currently plain `Multi.run/3` steps that
return `{:error, _}` on the EE-10 case — and an `Ecto.Multi.run/3` step returning `{:error,
_}` unconditionally aborts and rolls back the **entire** transaction (Ecto's own documented
behavior). To persist `ERROR` state atomically, the failure must instead be routed to a
**different, still-committing** tail of the same Multi — never surfaced to `Ecto.Multi` itself
as a step failure. This is the same shape `complete_task/3` already uses for its normal path
(`Multi.merge/2` building the tail dynamically from `changes`, `build_task_activation_and_
reconciliation_multi/3`, §0) — this design extends that same mechanism to branch two ways
instead of building one fixed tail.

### 5.1 `merge_output_variables/2` — always `{:ok, tagged}`, never `{:error, _}`

Return-shape change (signature, not body):

```
@type merge_outcome ::
        {:merged, %{new_variables: map(), merge_events: [VariableMerge.merge_event()]}}
      | {:execution_error, ExecutionError.error_args()}

@spec merge_outcome_for(current_variables :: map(), output_variables :: map()) ::
        {:ok, merge_outcome()}
```

On `VariableMerge.merge/3`'s `{:rejected, current_variables, [{:execution_error, key,
rejected_value, :variable_schema_rejected, failures}]}` (§0's confirmed return shape), this
function builds:

```
error_args = %{
  instance_id: <from the M2-locked InstanceProjection.instance_id>,
  error_type: :variable_schema_rejected,
  affected: {:field, key},
  reason: "variable '#{key}' failed schema validation" <> <failures summary>,
  variables: current_variables,          # unchanged, per merge/3's own contract — §9
  details: %{rejected_value: rejected_value, failures: failures},
  actor_id: <the complete_task/3 caller's own actor_id, threaded through>,
  idempotency_key: <the complete_task/3 caller's own idempotency_key, threaded through>
}
```

and returns `{:ok, {:execution_error, error_args}}` — never `{:error, _}` — so the
`Multi.run/3` step it lives inside never aborts the transaction.

### 5.2 `dispatch_task_completion_hop_chain/2` — same treatment, plus a pass-through

```
@type transition_outcome ::
        {:advanced, InstanceState.t()}
      | {:execution_error, ExecutionError.error_args()}

@spec transition_outcome_for(
        %{graph: Graph.t(), seed_instance_state: InstanceState.t(), own_token_id: String.t()},
        merge_outcome()
      ) :: {:ok, transition_outcome()}
```

If the upstream `merge_outcome` is already `{:execution_error, _}` (REQ-049 already fired),
this function is a pass-through — it does **not** call `Transition.transition/3` at all
(there is nothing coherent to transition on top of a rejected merge), and re-returns the same
`{:ok, {:execution_error, error_args}}` unchanged. Otherwise it runs `Transition.transition/3`
exactly as today; on `{:ok, new_instance_state, _pending_events}` it returns `{:ok,
{:advanced, new_instance_state}}`; on `{:error, {:no_matching_edge, node_id,
evaluated_conditions}}` it builds:

```
error_args = %{
  instance_id: <same>,
  error_type: :no_matching_gateway_edge,
  affected: {:node, node_id},
  reason: "no outgoing edge matched conditions and no default edge configured for gateway node '#{node_id}'",
  variables: <state_with_merged_variables.variables — the post-merge value, §9's asymmetry note>,
  details: %{evaluated_conditions: evaluated_conditions},
  actor_id: <threaded through>,
  idempotency_key: <threaded through>
}
```

and returns `{:ok, {:execution_error, error_args}}`. Any *other* `Transition.transition/3`
error (`transition_error()` has other members — hop-limit, unimplemented node type, etc.,
§0) is **not** rewired by this requirement — it is explicitly out of this run's own five
named calling paths, and continues to abort the transaction via `{:error, {:transition_failed,
reason}}` exactly as today (§12 OQ-4 flags this precisely: this design touches only the one
`transition_error()` member — `{:no_matching_edge, ...}` — this run's own text names for
REQ-050; the others are left as pre-existing, unrewired ad-hoc aborts, not silently assumed
covered).

### 5.3 The `Multi.merge/2` branch point

Replaces `build_task_activation_and_reconciliation_multi/3`'s current unconditional call
(§0, line 881) with a function that inspects `changes.transition_outcome` first:

- **`{:execution_error, error_args}`** → returns `Multi.new() |> ExecutionError.append_multi(
  error_args, prefix: prefix, locked_projection: changes.instance_projection) |> Multi.run(
  :complete_task_outcome, fn _repo, _changes -> {:ok, {:execution_error, error_args}} end)`.
  `changes.instance_projection` is M2's own already-locked struct (§0) — reused directly, no
  second lock. **None** of the normal-path steps run: no task activation, no token
  reconciliation, no `complete_task_row/5`, no `TASK_COMPLETED` event, no
  `reconcile_projection/5` call. The task stays `:pending`; only the instance flips to
  `:error`.
- **`{:advanced, final_instance_state}`** → returns exactly today's existing tail
  (`build_task_activation_and_reconciliation_multi`'s own body, `complete_task_row/5`,
  `append_task_completed_event/5`, `reconcile_projection/5`), plus one appended
  `Multi.run(:complete_task_outcome, fn _repo, _changes -> {:ok, :completed} end)` marker
  step, so `interpret_complete_result/1` (§5.4) can tell the two committed paths apart
  without re-deriving it from which optional keys are present in the final `changes` map.

### 5.4 `interpret_complete_result/1` — the new clause

The Multi as a whole still resolves as `{:ok, %{...}}` from `Ecto.Multi`'s own perspective in
**both** branches (it commits either way — that is the entire point: `ERROR` state must
durably persist, not roll back). `interpret_complete_result/1` gains a new leading clause
that pattern-matches `changes.complete_task_outcome`:

```
{:ok, %{complete_task_outcome: {:execution_error, error_args}}}
  -> {:error, {:instance_execution_error, error_args.error_type, error_args.affected}}

{:ok, %{complete_task_outcome: :completed, task: ..., transition: ..., task_complete: ...}}
  -> <today's existing success clause, unchanged>
```

**`complete_error()`'s own type union (line 744-762) gains one new member:**

```
| {:error, {:instance_execution_error, error_type :: Letflow.Engine.ExecutionError.error_type(),
            affected :: Letflow.Engine.ExecutionError.affected()}}
```

This is the one public-signature change this design makes to an already-shipped function —
flagged explicitly as a signature change ELIXIR-DEV must apply, per the backend guide's own
self-review checklist item "If any function signature changed: every call site still
compiles." No known call site outside `engine.ex` itself pattern-matches exhaustively on
`complete_error()`'s members today (confirmed: `complete_task/3` has no caller yet — S4's
route layer is not built, per `stage-3-instance-engine.md`'s own scope boundary) — so this
addition is additive/safe.

### 5.5 The race between two `complete_task/3` calls on the same instance (AC5, restated for this specific call site)

If two concurrent `complete_task/3` calls target *different* tasks of the *same* instance and
both independently hit an EE-10 case (e.g. two tasks completing near-simultaneously, one
hitting REQ-049's rejection and the other REQ-050's no-match), both already hold **their own**
task-row lock (M1, on different `tasks` rows) but race on the **same** `instance_projections`
row lock (M2, acquired early in each call, before either reaches its own merge/transition
step) — so the race is already resolved by M2's own lock ordering, before `ExecutionError.
append_multi/3` is ever reached: whichever call's M2 acquires the lock first proceeds through
its own merge/transition/error-branch and commits `status: :error` first; the second call's M2
is blocked until the first commits, then (once unblocked) re-reads `instance_projections` and
sees `status == :active` still (M2's own `fetch_and_lock_instance_projection/3` only accepts
`:active`, §0) — **wait, this needs to be traced precisely, not glossed:** M2 runs *before*
the merge/transition steps that discover the EE-10 case, so the *second* call's M2 will in
fact still see `:active` (the first call hasn't committed `:error` yet if M2 races ahead of
the first call's own merge/transition/error-append sequence) **unless** the first call has
already fully committed by the time the second's M2 acquires the lock — in which case the
second's M2 itself rejects with `{:error, {:instance_not_active, :error}}` (already-existing
REQ-048 behavior, §0), a **different** conflict shape than
`{:instance_already_error, _}` but equally a genuine, distinct rejection. Either way — caught
at M2 as `{:instance_not_active, :error}`, or caught later at `:execution_error_eligibility`
as `{:instance_already_error, _}` if somehow both got past M2 (not possible under
`FOR UPDATE` semantics, since M2 itself serializes on the same row — this second case is
therefore unreachable for *this specific* two-`complete_task/3` race, stated so it is not
left ambiguous) — **exactly one of the two calls ever commits an `EXECUTION_ERROR`/`ERROR`
transition, the other is rejected**, satisfying AC5 for this call site. TEST-DESIGNER's
concrete scenario: two tasks on one instance, one crafted to hit REQ-049's rejection and the
other REQ-050's no-match, run truly concurrently (not sequentially, per AC5's own wording),
asserting the disjunction "exactly one call returns `{:error, {:instance_execution_error,
...}}` and the other returns `{:error, {:instance_not_active, :error}}`."

---

## 6. Task completion against an `ERROR` instance (AC3) — already satisfied, no new logic

**Confirmed by direct read (§0), not asserted:** `fetch_and_lock_instance_projection/3`
(`complete_task/3`'s own M2, line 915-925) already has:

```elixir
%InstanceProjection{status: :active} = projection -> {:ok, projection}
%InstanceProjection{status: status} -> {:error, {:instance_not_active, status}}
```

and `complete_error()`'s union (line 751, §0) **already** names
`{:error, {:instance_not_active, status :: :completed | :cancelled | :error}}` as a legal
return value — `:error` was already part of that union before this requirement, evidently
anticipating REQ-061 landing later (the type was written broader than REQ-048's own shipped
behavior needed at the time). **This design adds nothing here.** AC3's "distinct conflict
error" is `{:error, {:instance_not_active, :error}}` — distinct from
`{:instance_not_active, :completed}` and `{:instance_not_active, :cancelled}` by its own third
element, satisfying AC3's own "distinct" wording without a new atom. "Remains in ERROR
afterwards" holds trivially: the rejected call performs zero writes (M2 fails before any
`Multi.run` step past it executes).

This is stated as its own section, not folded into §5, specifically so
CODE-DESIGN-VALIDATOR/REVIEWER can verify AC3 is met **without** searching for new code that
does not exist for this AC — the concrete design element is "the already-shipped M2 check,
confirmed to already include `:error` in its rejection clause," not a new function.

---

## 7. Cancellation of an `ERROR` instance — not this requirement's concern, cross-referenced only

`cancel_instance/3` (REQ-052, shipped) already treats an `:error`-status instance as
cancellable (its own `InstanceProjection.terminal?/1` reuse, §0) — `req052`'s own OQ-5
explicitly flagged this reading for "REQ-061's own CODE-DESIGNER to confirm it does not
conflict with whatever REQ-061 itself decides about operator-driven recovery from `ERROR`."
**Confirmed here: no conflict.** This design does not touch `cancel_instance/3`, does not
change `terminal?/1`, and does not introduce any new "is `ERROR` cancellable" rule — an
operator/caller discarding an `ERROR`-halted instance via `cancel_instance/3` remains exactly
as `req052` already built it, independent of this requirement's own scope (S6's OBS-05
dead-letter API, §10 below, is the *other*, not-yet-built operator path — retry, as opposed
to `cancel_instance/3`'s discard).

---

## 8. DB tables/columns touched — no schema change (reuses REQ-023/043 exactly)

| Table | Columns this design reads | Columns this design writes | Migration/schema (unchanged) |
|---|---|---|---|
| `instance_projections` | Full row (locked `FOR UPDATE`, or reused from caller's own lock) | `status` (→ `:error`), `error_detail` (→ compact detail map, below) | `…110001_alter_instance_projections_add_engine_columns.exs` (REQ-043), `instance_projection.ex` |
| `events` | — | One `EXECUTION_ERROR` row via `EventStore.append/2` (§9), unchanged mechanism | REQ-025 (unchanged) |

**No migration file is added by this requirement.** `instance_projections.error_detail`
(`:map`, jsonb) already exists and has been unused by every shipped requirement until now
(§0, confirmed by direct read of `instance_projection.ex`).

**`error_detail`'s shape (this design's own choice, not fixed by any prior requirement):**

```
%{
  "error_type"  => <error_type() as a string, e.g. "variable_schema_rejected">,
  "affected"    => <affected() encoded, e.g. %{"kind" => "field", "key" => "approved_amount"}
                    or %{"kind" => "node", "node_id" => "gw-1"}>,
  "reason"      => <the human-readable string>,
  "occurred_at" => <ISO-8601 timestamp>
}
```

Deliberately **excludes** the variable-map snapshot — that lives in the `EXECUTION_ERROR`
event's own payload (§9), the durable, append-only audit record AC1/AC5 actually require.
`error_detail` is a *current-state summary* column (mirroring `completed_at`/`cancelled_at`'s
own role: "what does the projection itself need to answer 'why is this instance stuck'
without a join to `events`"), not a duplicate of the event payload — flagged as this design's
own choice, not silently assumed, at §12 OQ-5, since a future S4
`GET /instances/:id` route may want the fuller detail and could reasonably want it inlined
here instead of requiring a separate events-read; this design opts for the smaller column and
leaves that call to S4.

---

## 9. `EXECUTION_ERROR` event append (REQ-025) — the AC1 payload

Built by `ExecutionError.append_multi/3`'s own `:execution_error_event` step (§3), from
`error_args` (assembled by whichever caller built it — REQ-049/050's own `error_args`
construction, §5.1/§5.2, or a future caller's own):

```
payload = Jason.encode!(%{
  error_type: to_string(error_args.error_type),
  affected: <encode affected() the same way §8's error_detail does>,
  reason: error_args.reason,
  variables: error_args.variables,
  details: Map.get(error_args, :details, %{})
})

event_attrs = %{
  instance_id: error_args.instance_id,
  event_type: "EXECUTION_ERROR",
  payload: payload,
  actor_id: error_args.actor_id,
  idempotency_key: error_args.idempotency_key
}
```

**All four AC1-mandated fields are present in one event payload, read back verbatim:**
`error_type` (error type), `affected` (affected node or field), `reason` (human-readable
reason), `variables` (the instance variable-map snapshot) — this is the concrete, single
design element AC1 maps to.

**The variable-snapshot asymmetry, stated explicitly rather than left implicit (§5's own
forward reference):** REQ-049's own `error_args.variables` is `current_variables`
**unchanged/pre-merge** (`VariableMerge.merge/3`'s own contract: nothing is merged on
rejection, §0) — an accurate "instance variable state at the time of the error" reading,
since the merge itself is what failed. REQ-050's own `error_args.variables` is
`state_with_merged_variables.variables`, i.e. **post-merge** — because by the time
`Transition.transition/3` runs, `VariableMerge.merge/3` already succeeded (this hop only
fails later, at gateway-edge evaluation); the merge's result is real, coherent instance state
at that instant, even though (because the overall Multi takes the error branch) it is never
independently persisted to `instance_projections.variables` on its own. This is intentional,
not an inconsistency to fix: each snapshot reflects the actual last-computed variable state
immediately preceding the specific step that failed, which is what "at the time of the error"
means precisely for each call site. Flagged at §12 OQ-6 for REVIEWER to confirm this reading
is the intended one (vs., e.g., REQ-050's snapshot instead using the pre-merge value for
symmetry with REQ-049 — this design rejects that alternative because it would describe a
variable state the instance was never actually in at the moment the gateway dispatch ran).

**`"EXECUTION_ERROR"` must already be a registered `event_type_registry` row for the tenant,
or this step (and therefore the whole call) fails with `{:error, :unknown_event_type}`** — the
same pre-existing, already-flagged gap `req045`'s OQ-3a, `req048`'s OQ-6, and `req052`'s
OQ-6 all document for `"INSTANCE_STARTED"`/`"TASK_COMPLETED"`/`"INSTANCE_CANCELLED"` (§0);
this design inherits it rather than re-discovering it, and does not attempt to seed the
registry (out of scope, same as every prior S3 design).

---

## 10. SCOPE BOUNDARY — OBS-05 dead-letter queue, and ERROR-is-not-terminal (required moduledoc content)

Both `Letflow.Engine.ExecutionError`'s own moduledoc and `Letflow.Engine.set_instance_error/2`'s
`@doc` must state, verbatim in substance (this run's own text: "That operator retry/discard
path is R-Co's OBS-05 dead-letter API (`src/dlq/`, S6 operational-cross-cutting plus S4's
route layer) — explicitly out of this stage's scope. Leave a named hook and state the
boundary; do NOT build a partial DLQ" and "State that distinction explicitly in the
moduledoc — reading ERROR as terminal is the easy mistake"):

> An instance that reaches `ERROR` via this module stays in `ERROR` until an **operator**
> action moves it out — retry (re-attempt the failed step) or discard (abandon the instance).
> That operator action is R-Co's OBS-05 dead-letter API (`src/dlq/`, S6
> operational-cross-cutting, plus S4's own route layer to expose it over HTTP) — **neither
> exists in Letflow yet, and this module builds no partial version of either.** No
> retry-queue table, no discard endpoint, no background sweep of `ERROR`-status instances is
> introduced here. The one hook this module leaves for that future work:
> `instance_projections.status == :error` plus its `error_detail` column (§8) *is* the durable
> record OBS-05's future dead-letter listing/read path will query — no additional table is
> needed for S6 to find every `ERROR`-halted instance once it exists.
>
> **`ERROR` is explicitly NOT terminal, unlike `CANCELLED` and `COMPLETED`.**
> `InstanceProjection.terminal?/1` (already shipped, REQ-023/043) already encodes this —
> `true` only for `:completed`/`:cancelled`, `false` for both `:active` and `:error` — so
> `EventStore.append/2`'s own active-instance guard does **not** reject a further append
> attempt against an `ERROR` instance purely because of its status (a *specific* append,
> like `complete_task/3`'s own M2, may still reject it for its own, distinct reason — AC3, §6
> above — but that is that call's own business rule, not the event store's terminal-state
> guard). REQ-060's pin rebind treats `ERROR` as non-rebindable and REQ-052's cancellation
> treats `CANCELLED`/`COMPLETED` as already-finished; neither of those readings makes `ERROR`
> itself a terminal status in the event-store's own sense — an operator action (once S6
> lands) can still move an instance out of `ERROR`, which is precisely why `ERROR` is a
> fourth, distinct value in REQ-023's status enum rather than folded into `CANCELLED`.

---

## 11. Invariants

| id | Invariant | Enforced where |
|---|---|---|
| INV-EE61-1 | `ExecutionError.append_multi/3` never mutates `instance_projections`/`events` outside the caller's own single `Ecto.Multi`/`Repo.transaction/1` — both commit or roll back together with every other step of that same transaction | §3 |
| INV-EE61-2 | An instance already `:completed`/`:cancelled` and one already `:error` return two distinct, separately pattern-matchable conflict shapes (`{:instance_terminal, status}` vs. `{:instance_already_error, error_detail}`) when a second EE-10 trigger targets it | §3 (`:execution_error_eligibility`) |
| INV-EE61-3 | Exactly one `EXECUTION_ERROR` event is appended per successful `ExecutionError.append_multi/3`-driven commit | §3, §9 |
| INV-EE61-4 | The `EXECUTION_ERROR` event payload always carries all four of `error_type`, `affected`, `reason`, `variables` — no caller may omit one (all four are `required()` keys on `error_args()`) | §2, §9 |
| INV-EE61-5 | `status` flips to `:error` and the `EXECUTION_ERROR` append commit together — forcing the append to fail (e.g. `:unknown_event_type`, §9) rolls back the whole enclosing transaction, leaving `instance_projections.status` unchanged | §3 (event step before projection-update step, same transaction) |
| INV-EE61-6 | An instance in `:error` rejects `complete_task/3` with `{:error, {:instance_not_active, :error}}` and remains `:error` afterwards — zero writes on that rejected call | §6 (already-shipped REQ-048 behavior, confirmed not re-derived) |
| INV-EE61-7 | `Letflow.Engine.ExecutionError` performs zero `Repo` calls of its own — every write happens inside the caller's already-open `Ecto.Multi` | §3, matching `TaskActivation`'s own INV-EE47-7 |
| INV-EE61-8 | `ERROR` is never treated as terminal by `InstanceProjection.terminal?/1` or `EventStore.append/2`'s own active-instance guard — only `set_instance_error`'s own eligibility check (§3) and `complete_task/3`'s own M2 (§6) reject further activity against an `:error` instance, each for its own distinct reason | §10 |
| INV-EE61-9 | No `tenant_id` column or derivation is added to either table this design touches (Decision 0006 D2) | §8 |
| INV-EE61-10 | This module performs zero HTTP status-code mapping (S4 boundary, matching every other S3 context-module function) | §4, §10 |

---

## 12. Open questions — explicitly listed, not silently resolved

PROVENANCE (historical, not current decision authority):
**OQ-1 — RESOLVED (GH#328, ISS-0100, 2026-08-20).** R-Co's own `setInstanceError()`
(L3078–3182), `SetInstanceErrorArgs` (L289–306), and error-code switch (~L4060–4071 inside
`buildExecutionErrorPayload/3`) were read directly against `R-Co/src/engine/instance.zig`.
Verdict: this design's shape matches field-for-field (§0) and no correction to this design's
own behavior was needed — the one inaccuracy found was this design's *description* of R-Co
(§2's "mirrors R-Co's own error-code table being a mapping, not a hardcoded case statement" —
backwards; R-Co's table *is* a hardcoded `switch`), now corrected in §2 and §0. No further
action for REVIEWER on this item.

**OQ-2 (MAJOR).** REQ-062's "four SPC-01 sub-process interface violations" are modeled here as
sharing one `:subprocess_interface_violation` `error_type()` atom, distinguished only via
`error_args.details`, rather than four separate atoms. This design does not know REQ-062's
own four violation shapes (REQ-062 is `pending`, unimplemented) well enough to name them
individually. Flagged for REQ-062's own CODE-DESIGNER to either confirm this shared-atom
reading or split it into four atoms when that requirement is designed — this design commits
only to `error_type()`'s union being open (the trailing `atom()`, §2), not to REQ-062's exact
future value(s).

**OQ-3 (MAJOR).** `error_args.actor_id`/`.idempotency_key` for a genuinely actor-less future
caller (REQ-056's background service-task retry-exhaustion check, most plausibly triggered by
a scheduled process with no human actor in the loop) has no resolved convention here — no
"system actor" sentinel UUID, no deterministic idempotency-key derivation scheme is defined
by this design. `set_instance_error/2`'s own signature (§4) accepts `actor_id: nil` as
structurally legal (unlike `cancel_instance/3`'s `missing_actor_id` rejection) specifically to
leave room for this, but does not itself decide what a `nil`-actor `EXECUTION_ERROR` event
should look like beyond "actor_id: nil is passed through to `EventStore.append/2` unchanged."
Flagged for REQ-056's own CODE-DESIGNER (and REQ-057/062's, whichever of them turns out to be
actor-less) to resolve when built — do not silently invent a sentinel value here.

**OQ-4 (MINOR).** `Transition.transition/3`'s other `transition_error()` members (hop-limit
exceeded, unimplemented node type, `:missing_token_record`, etc.) are **not** rewired into
`set_instance_error` by this design — only `{:no_matching_edge, ...}` (REQ-050's own named
case) is. Flagged for REVIEWER to confirm this narrow scoping (matching this run's own text,
which names REQ-050's case specifically) is correct, versus a broader reading where *every*
`Transition` failure should route through EE-10. This design deliberately takes the narrow
reading — the requirement text names five *specific* calling paths, not "every possible
engine failure," and a hop-limit-exceeded or unimplemented-node-type failure is arguably a
programming/definition-authoring bug rather than a runtime data condition an operator can
meaningfully retry/discard via OBS-05 — and this narrow reading is now confirmed against
R-Co's literal error-code table (OQ-1, resolved above): R-Co's own closed `ErrorType` enum
(L244–273) has no hop-limit-exceeded or unimplemented-node-type variant either — only
`NO_MATCHING_EDGE` from `Transition`'s failure space is wired into `setInstanceError()` on
R-Co's own side, matching this design's scoping exactly.

**OQ-5 (MINOR).** `error_detail`'s shape (§8) deliberately excludes the variable-map snapshot,
keeping it in the `EXECUTION_ERROR` event payload only. Flagged for REVIEWER/S4's own future
CODE-DESIGNER to confirm this split (small summary column + full detail in the append-only
event log) is preferred over inlining the full snapshot into `error_detail` too, which would
let a future `GET /instances/:id` route answer "why is this stuck" without a second query
against `events` at the cost of duplicating a potentially large blob.

**OQ-6 (MINOR).** §9's variable-snapshot asymmetry (REQ-049 uses the pre-merge value,
REQ-050 uses the post-merge value) is this design's own reasoned choice, not verified against
R-Co's literal source. Flagged for REVIEWER to confirm this reading is the intended one.

**OQ-7 (MINOR, inherited).** `"EXECUTION_ERROR"` must be a registered `event_type_registry`
row per tenant for §9's append to succeed — the same pre-existing gap `req045`/`req048`/
`req052` already document for their own event types. This design does not attempt to seed the
registry.

---

## 13. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.VariableMerge` (req049, shipped) | This code → that | `merge/3`'s existing `{:rejected, ...}` return shape consumed unchanged (§5.1) — `VariableMerge` itself is not modified |
| `Letflow.Engine.Transition` (req044/050/051, shipped) | This code → that | `transition/3`'s existing `{:error, {:no_matching_edge, ...}}` member consumed unchanged (§5.2) — `Transition` itself is not modified, remains pure |
| `Letflow.EventStore.InstanceProjection` (req023/043, shipped) | This code → that | `terminal?/1` (referenced, not called directly by this design — §10), `update_changeset/2` (§3, reused unchanged) |
| `Letflow.EventStore` (req025, shipped) | This code → that | `append/2` for `EXECUTION_ERROR` (§9) — the concrete mechanism through which `active_instance_guard/3` is exercised for this event type, same pattern `req052`'s own text asked verified for `INSTANCE_CANCELLED` |
| `Letflow.TenantProvisioning` (req022, shipped) | This code → that | `tenant_id_for_schema_name/1`, pre-transaction, `set_instance_error/2`'s own pre-transaction phase (§4) |
| `Letflow.Engine.TaskActivation` (req047, shipped) | Pattern precedent only, not called | `append_multi_from_existing_records/6`'s own "zero Repo calls, composable into caller's Multi" shape is copied by `ExecutionError.append_multi/3` (§3), not invoked by it |
| `Letflow.Engine.complete_task/3` (req048, shipped, **edited by this requirement**) | This requirement edits | §5: `merge_output_variables/2` and `dispatch_task_completion_hop_chain/2` change return shape; `build_task_activation_and_reconciliation_multi/3`'s call site becomes a two-way branch; `interpret_complete_result/1` gains a new clause; `complete_error()` gains one new union member |
| `Letflow.Engine.cancel_instance/3` (req052, shipped) | **Not edited** by this requirement | §7 — confirms no conflict with `req052`'s own OQ-5, cross-referenced only |
| REQ-056 (exhausted service-task retries, not yet built) | Future caller | Expected to call `Letflow.Engine.set_instance_error/2` (standalone) or `ExecutionError.append_multi/3` (in-Multi), per whichever shape its own call site turns out to need (§4) |
| REQ-057 (plugin ERROR outcome, not yet built) | Future caller | Same as REQ-056 |
| REQ-062 (SPC-01 sub-process interface violations, not yet built) | Future caller | Same as REQ-056; §12 OQ-2 on its own `error_type()` granularity |
| S6 (OBS-05 dead-letter API, not yet built) | Future, named hook only | §10 — not called by this design; the hook is `instance_projections.status == :error` + `.error_detail`, already durable by construction |
| S4 (`GET /instances/{id}`, `POST /instances/:id/rebind-pins`, etc., not yet built) | S4 → this module's own reads | Status-code mapping and any dead-letter HTTP surface, entirely out of scope here |

---

## 14. Acceptance-criteria traceability

| This run's acceptance criterion | Concrete design element |
|---|---|
| "an EXECUTION_ERROR event carries error type, affected node or field, a human-readable reason, and the instance variable map as it stood at the moment of the error -- all four verified by reading the event payload back" | §9 (payload shape, all four fields), §2 (`error_args()`'s `required()` keys enforce every caller supplies all four) |
| "the status flip to ERROR and the EXECUTION_ERROR append commit together: forcing the append to fail leaves the instance status unchanged, verified by reading both back" | §3 (`:execution_error_event` before `:execution_error_projection_update`, same `Ecto.Multi`), INV-EE61-1/5 |
| "an instance in ERROR rejects task completion with a distinct conflict error and remains in ERROR afterwards" | §6 (already-shipped REQ-048 M2 check, `{:error, {:instance_not_active, :error}}`, confirmed not re-derived) |
| "at least three of the five calling paths ... are demonstrated routing into this one function ... confirmed by inspection and by test" | §15 below — the AC4 TENSION, addressed explicitly, not silently resolved |
| "two concurrent operations that both trigger EE-10 on the same instance result in exactly one committed EXECUTION_ERROR and one rejection, run concurrently rather than sequentially" | §3 (`:execution_error_eligibility`'s row-lock-queueing mechanism, general case) + §5.5 (the specific REQ-049/050-in-`complete_task/3` race, traced precisely) |
| "the moduledoc names OBS-05's dead-letter retry/discard path (S6/S4) as the out-of-scope operator action, confirms no partial DLQ was built, and states that ERROR is non-terminal in a way CANCELLED and COMPLETED are not" | §10 (required verbatim-in-substance moduledoc content) |

---

## 15. THE AC4 TENSION — addressed explicitly, per this run's own instruction not to silently resolve it

**This run's own text, quoted in full:** *"AC4 asks for 'at least three of the five calling
paths' (REQ-049, REQ-050, REQ-056, REQ-057, REQ-062) to be demonstrated routing into
set_instance_error, but only REQ-049 and REQ-050 are shipped today — REQ-056/057/062 are
still pending requirements with no code yet. Your design must state explicitly how this AC
can be satisfied now (e.g. wiring the two existing callers, REQ-049 and REQ-050, into the
shared sink, with the remaining three left as named future call sites) rather than silently
assuming three exist."*

**Verified independently, not taken on the requirement text's word alone:** `docs/migration/
stage-3-instance-engine.md`'s own status line (§0, read in full) confirms REQ-056, REQ-057,
and REQ-062 are all listed under "REQ-053, REQ-054, REQ-055, REQ-056, REQ-057, REQ-059,
REQ-060, REQ-061, REQ-062 ... `pending`" — no shipped code exists for any of the three.
REQ-049 (variable scoping/merge, EE-09) and REQ-050 (exclusive gateway, EE-05) are both listed
`done`. This design's own §0/§5/§6 traced their exact current (pre-this-requirement) call
sites directly in shipped `lib/letflow/engine.ex`, confirming both exist and, before this
requirement, wrote **no** ERROR state at all (they simply abort the transaction and return an
ad-hoc error tuple to the caller). **The premise in the requirement text is confirmed
accurate: two of five calling paths exist in shipped code today, not three.**

**This design's own resolution — an INTERIM reading of AC4, not this requirement's to decide
unilaterally:**

1. **What this design actually builds and can be demonstrated by test today:** both of the
   two currently-existing callers (REQ-049 and REQ-050, §5) are rewired to route through
   `Letflow.Engine.ExecutionError.append_multi/3` — the one shared sink — rather than each
   writing (or, as today, *not* writing) its own ad-hoc error handling. **This is "2 of 2
   currently-shippable callers wired," not "at least 3 of 5,"** stated as exactly what it is.
2. **The remaining three (REQ-056, REQ-057, REQ-062) are named, not silently dropped:** §4
   and §13 above name all three explicitly as expected future callers of either
   `set_instance_error/2` or `ExecutionError.append_multi/3` directly, and §12's OQ-2/OQ-3
   name the specific open decisions their own future CODE-DESIGNER runs will need to resolve
   (REQ-062's error-type granularity, REQ-056/057's actor-less-caller convention). Nothing
   about this design's own shape blocks any of the three from wiring in later — the shared
   sink's own public contract (`error_args()`, §2; `append_multi/3`'s composable shape, §3)
   is deliberately generic enough that a future caller supplying its own `error_type`/
   `affected`/`reason`/`variables` needs no change to this module itself.
3. **What this design does NOT do:** it does not fabricate a third call site, does not stub
   REQ-056/057/062's own logic early to "get to three," and does not weaken AC4's own wording
   to quietly mean "two." Test-count-wise, this run's own TEST-DESIGNER (Step 3) can write and
   pass concrete tests demonstrating **2 of the 5 named paths** routing into the shared sink
   today (REQ-049's rejection case, REQ-050's no-match case) — genuinely fewer than AC4's own
   literal "at least three."

**Flagged explicitly for REVIEWER (Step 2d) and, if REVIEWER defers it, for ORCH/RELEASE-
VALIDATOR to decide, not resolved unilaterally by this design:** whether "2 of 2
currently-shippable callers, with the remaining 3 named as future call sites and their own
open questions recorded" is an acceptable interim satisfaction of AC4 for *this* run, with
AC4's own "at least three" language re-verified once REQ-056/057/062 each land (at which point
a trivial, mechanical re-check — do at least 3 of the 5 named `error_type()` values appear in
shipped call sites — would settle it definitively), **or** whether AC4 as literally worded
blocks this requirement from being marked `done` until a third caller actually exists (which
would mean REQ-061 cannot complete WF-02 until at least one of REQ-056/057/062 also ships,
a sequencing this design does not believe REQ-061's own text intends, since REQ-061 is
explicitly the *shared sink* infrastructure requirement other requirements build their own
call sites against, not the other way around — but this design does not get to decide that
sequencing question for the pipeline). **This is not silently resolved either way** — it is
this design's own explicit recommendation (option 1: accept 2-of-2-today plus 3 named futures
as satisfying AC4's intent) offered for REVIEWER's actual sign-off, not assumed on this
design's own authority.
