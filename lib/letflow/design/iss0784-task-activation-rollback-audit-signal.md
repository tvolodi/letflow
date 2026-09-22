# Design: operator-facing signal on task-activation rollback (ISS-0784)

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Issue:** `docs/issues/ISS-0784.yaml` (queue task 783, GH-1731, stage S9).
**Related:** REQ-273 (`lib/letflow/design/req273-form-schema-activation.md` §7 OQ-2),
REQ-385 (`lib/letflow/design/req385-task-form-version-mismatch-fallback.md` §6 OQ-1).

## 1. Problem, restated precisely

`Letflow.Engine.TaskActivation.resolve_form_schema/1` rejects a malformed
`form_schema` node attribute via `Letflow.Definitions.JsonSchemaShape.check/1`. The
rejection propagates as `{:error, {:invalid_form_schema, node_id, reason}}` out of
`insert_attrs/4`, then `insert_newly_pending/6`, then out of the enclosing
`Multi.run(:task_records, ...)` (or `Multi.run({:task_records, instance_id[, disambiguator]}, ...)`
for `append_multi_from_existing_records/7`). `Ecto.Multi`'s own contract means this
aborts and rolls back **the entire enclosing transaction** — correct per INV-8 (a
malformed `form_schema` must never reach a committed `tasks` row), but today nothing
records that this was attempted and rejected. The task simply never activates; an
operator sees a stalled instance with no visible cause beyond application logs.

This design adds exactly one thing: an independent, best-effort `Letflow.Audit` entry
recording the rejected attempt, written **after** the enclosing transaction has already
rolled back — never inside it (§3 explains why that's the only correct order). No new
UI or frontend change is in scope for this MINOR issue; §8 states plainly what an
operator can and cannot do with the existing `AuditLogPage.tsx` today, rather than
claiming a filter that does not exist.

## 2. Where the rejection is reachable from (four call sites, all already located)

`resolve_form_schema/1`'s failure can only reach a caller through
`TaskActivation.append_multi/6` or `TaskActivation.append_multi_from_existing_records/7`.
Every other caller of these two functions (`Letflow.Engine.SubProcess.append_start_multi/7`,
`build_completion_write_steps/12`) merges its own `Multi` into one of the four outer
Multis below rather than opening a separate transaction, so the rejection always
surfaces at exactly one of these four existing "unwrap the `Ecto.Multi` error envelope"
points in `lib/letflow/engine.ex`:

| # | Site | Function | `instance_id` in scope as | `actor_id` in scope as | `prefix` in scope as |
|---|---|---|---|---|---|
| 1 | `create/2`'s Multi | `interpret_create_result/6` (~line 1725, catch-all clause) | `instance_id` (existing 2nd arg) | `attrs[:actor_id]` — not currently threaded into this clause; add as an argument (§4.1) | `prefix` — not currently threaded into this clause; add as an argument |
| 2 | `complete_task/3`'s Multi | `interpret_complete_result/1` (~line 4062, catch-all clause) | `changes.task.instance_id` (the `:task` Multi step, fetched first, is always present in `changes_so_far` by the time a later `:task_records`-keyed step can fail) | `actor_id` from `run_complete_task/6`'s own closure — not currently threaded into this clause; widen its arity (§4.1) | `prefix` from the same closure; widen arity |
| 3 | timer-fired advance (`advance_after_timer_fired/3`'s internals, ~line 2465-2468) | inline `case repo.transaction(multi) do {:error, _, reason, _} -> {:error, reason} end` | `timer.instance_id` (already in scope) | `Letflow.EventStore.platform_actor_id()` — same value this same function body already passes at line 2457 for `append_sub_process_children_creation_multi/5` | `prefix` (already in scope) |
| 4 | service-task-outcome advance (`advance_after_service_task_outcome/4`'s internals, ~line 2816-2819) | inline `case repo.transaction(multi) do {:error, _, reason, _} -> {:error, reason} end` | `dispatch.instance_id` (already in scope) | `Letflow.EventStore.platform_actor_id()` — same value this same function body already passes at line 2805 | `prefix` (already in scope) |

Sites 3 and 4 already establish the "system-driven cascade uses
`EventStore.platform_actor_id()` as its actor" precedent in the immediately
surrounding code — this design reuses it rather than inventing a second convention for
"who is the actor of a rejection nobody asked for directly."

## 3. Transactional placement — must NOT be inside the rolled-back Multi

**The audit write cannot be a step inside the same `Ecto.Multi` that just failed.**
`Ecto.Multi`/`Repo.transaction/1` is all-or-nothing: if any step returns `{:error, _}`,
every step already applied in that same transaction — including an audit-entry insert
that itself reported success — is rolled back along with it. Adding
`Audit.append_multi(multi, :rejection_audit, attrs, prefix)` *before* the failing
`:task_records` step would never survive to be readable (Postgres never commits it);
adding it *after* is unreachable, because `Multi.run/3`'s reduce-while semantics never
run a later step once an earlier one has already failed. Either placement defeats the
entire point of this issue — there would still be no readable trace of the rejection.

The only placement that can ever produce a row a `SELECT` can see is a **second,
independent write, in its own transaction, issued by the caller after
`Repo.transaction(multi)` has already returned `{:error, _failed_step, reason, _changes}`**
— i.e. after Postgres has already released the failed transaction's locks and rolled
back every row the failing attempt would have written. This is the same shape
`Letflow.Audit`'s own moduledoc already documents as one of its two supported call
shapes ("directly inside a caller's own `Repo.transaction/1` anonymous function"), just
invoked from the *failure* branch of an unwrap point instead of the success branch.

Concretely, at each of the four sites in §2, the existing
`{:error, _failed_step, reason, _changes} -> {:error, reason}` clause is extended to,
before returning: pattern-match `reason` for `{:invalid_form_schema, node_id, detail}`;
if it matches, call the new helper below (own `Repo.transaction/1`, run and awaited
synchronously, its result inspected — not fire-and-forget) and then return the
**original** `{:error, reason}` regardless of whether the audit write itself succeeded
(§5). If `reason` does not match, behavior is byte-identical to today.

## 4. New function surfaces (signatures and type shapes only)

### 4.1 `Letflow.Engine` — private helper, one call site reused four times

```
@spec record_task_activation_rejection_audit(
        instance_id :: Ecto.UUID.t(),
        node_id :: String.t(),
        reason :: {:not_well_formed, path :: [String.t()]} | :too_deep,
        actor_id :: Ecto.UUID.t() | nil,
        prefix :: String.t()
      ) :: :ok
```

- `reason` is exactly `resolve_form_schema/1`'s own `{:error, _}` payload type, minus
  the outer `:error` tag — i.e. `{:not_well_formed, path :: [String.t()]} | :too_deep`,
  the literal union `Letflow.Definitions.JsonSchemaShape.check/1`'s own `@spec` names
  (that module defines no standalone named type for it — this design does not invent
  one just to shorten this signature). This function does not invent a new error
  taxonomy; it re-shapes the existing one into a JSON-safe map (below) for the audit
  row's `after_state`.
- `actor_id` is `nil` for the two system-driven cascade sites (§2 rows 3/4, an atom-typed
  actor per `EventStore.platform_actor_id()` — resolve whichever of `nil`/an atom/a
  fixed platform UUID that function actually returns; this design does not re-decide
  that, it reuses the value verbatim the same way lines 2457/2805 already do) and the
  requesting user's `actor_id` for the two user-driven sites (§2 rows 1/2).
- Return type is unconditionally `:ok` — this function is best-effort and never
  propagates a failure to its caller (§5); there is nothing for a caller to branch on.
- **Existing signature changes required to reach this helper** (both catch-all
  clauses currently discard the context this helper needs):
  - `interpret_create_result/6`'s catch-all clause (currently
    `({:error, _failed_step, reason, _changes}, _instance_id, _definition, _status, _current_node_ids, _initial_variables)`)
    must stop discarding `instance_id`/`_changes` is fine to keep discarding, but the
    caller (`persist/8`) must additionally pass `attrs[:actor_id]` and `prefix` through
    to `interpret_create_result/6` — widen its arity from 6 to 8
    (`..., actor_id, prefix`), or thread them via a small map, CODE-DESIGNER leaves the
    exact mechanical shape to ELIXIR-DEV since both are equivalent and neither
    contradicts any existing invariant.
  - `interpret_complete_result/1`'s catch-all clause must widen to
    `interpret_complete_result(result, actor_id, prefix)` (arity 1 → 3) and, in the
    catch-all clause specifically, read `instance_id` out of `_changes.task.instance_id`
    (the `:task` step's own already-fetched `Letflow.Engine.Task.t()`) — every other
    `interpret_complete_result/1` clause ignores `actor_id`/`prefix`, so this is an
    additive, non-breaking widen for those clauses (they simply gain two unused
    parameters), not a rewrite of their own bodies.
  - Sites 3/4 (§2) need no signature change — the inline `case` already closes over
    every value the helper needs.

### 4.2 JSON-safe encoding of `reason` for `after_state`

```
@spec encode_form_schema_rejection_reason(
        {:not_well_formed, path :: [String.t()]} | :too_deep
      ) :: map()
```

Maps the two known shapes exactly:
- `{:not_well_formed, path}` → `%{"code" => "not_well_formed", "path" => path}`
  (`path` is already `[String.t()]` — JSON-encodable as-is, no further conversion).
- `:too_deep` → `%{"code" => "too_deep", "path" => nil}`.

A third, unmatched shape is *not* silently swallowed into a generic fallback: this
function's `@spec` is closed over `JsonSchemaShape.check_error/0`'s own two-member
union, so an exhaustive `case` here is exactly as tight as `resolve_form_schema/1`'s own
`@spec` already is — if `JsonSchemaShape.check/1`'s error union ever grows a third
member, this function fails to compile until updated, which is the intended signal
(§8 OQ-2 names this explicitly rather than leaving it implicit).

## 5. The audit entry itself

`record_task_activation_rejection_audit/5` (§4.1) builds and passes exactly this
`Letflow.Audit.entry_attrs()` map to `Letflow.Audit.insert_entry/3`:

| Field | Value |
|---|---|
| `actor_id` | per §4.1 (the real requesting actor, or the platform actor for a system-driven cascade) |
| `action` | the literal string `"task_activation.rejected"` — new action name, following the existing `<resource>.<verb>` convention (`"task.create"`, `"instance.create"`) |
| `resource_type` | the literal string `"instance"` — deliberately the *instance*, not a synthetic `"task_activation_attempt"` type, because no `tasks` row was ever created to be a `resource_id`, and an operator's actual question ("why did my instance never get this task") is instance-scoped. This entry is then interleaved with that instance's other audit history (`"instance.create"`, etc.) whenever an operator narrows `AuditLogPage` to `resourceType = "instance"` and scans for it (§8 — `AuditLogPage.tsx` has no `resource_id` filter today, so this is scanning within a narrowed window, not filtering by id). |
| `resource_id` | `instance_id` |
| `before_state` | `nil` — there is no prior state; nothing changed |
| `after_state` | `%{"node_id" => node_id, "reason" => encode_form_schema_rejection_reason(reason)}` (§4.2) — deliberately named `after_state` (not a new field) to reuse `Letflow.Audit`'s existing schema and hash-chain computation unmodified; its semantic meaning here is "the state of the rejected attempt," not "the resulting row state," which is a deliberate, narrow repurposing worth flagging to CODE-DESIGN-VALIDATOR/REVIEWER rather than silently overloading (§8 OQ-1) |
| `trace_id` | `nil` — no precedent in this codebase threads a trace id through this call path either (matches `record_task_create_audit/3`'s own `trace_id: nil`) |

Call shape: `Letflow.Repo.transaction(fn -> Letflow.Audit.insert_entry(Letflow.Repo, attrs, prefix) end)` —
its own independent transaction, run and awaited synchronously in the same process,
never backgrounded (per `core-directives.md`'s "No Background Wait For A Cross-Turn
Notification" — not directly applicable to a subagent here, but the same "run
synchronously, inspect the real result" discipline applies to this helper).

## 6. Failure semantics of the audit write itself (INV-8)

The audit write is **best-effort**: if `Audit.insert_entry/3` itself returns
`{:error, _}` (e.g. a `chain_hash` race, though `fetch_chain_tail/2` + insert inside one
transaction already serializes against concurrent writers the same way every other
`insert_entry/3` caller relies on), `record_task_activation_rejection_audit/5` logs the
failure with `Logger.warning/1` — this codebase's own established convention for
exactly this "best-effort, log and swallow" shape, per `snapshot_instance/4`
(lib/letflow/engine.ex ~line 1465-1478, the `{:error, reason} -> Logger.warning(...)`
clause) — and returns `:ok` regardless. It must never raise, and must never turn the
original `{:invalid_form_schema, node_id, reason}` rollback into a *different* error
returned to `create/2`'s/`complete_task/3`'s own caller — the exact same "best-effort,
log and swallow, never let a side-channel failure change the primary call's own
success/failure verdict" discipline `snapshot_instance/4` already establishes for
`SnapshotWriter` failures (that helper is called from `maybe_snapshot_after_create/4`,
~line 1449-1459, which supplies the `{:ok, _}`/fallthrough dispatch around it — the log
call itself lives one level down, in `snapshot_instance/4`). This is a direct precedent
reuse, not a new pattern, and not a gap in this codebase's logging conventions.

This satisfies INV-8: the audit write touches tenant-controlled data (`node_id`,
`reason`) and external I/O (a second DB round-trip) from a path already reached by
tenant input, so it must use a typed result and must not let a realistic failure (e.g.
transient connection loss right after the main rollback) crash the calling process or
mask the caller's real, already-determined error.

## 7. Tenant-data path / SECURITY-REVIEWER — explicit conclusion

**Yes, SECURITY-REVIEWER sign-off is required**, under two invariants from
`docs/agents/instructions/security-invariants.md`:

- **INV-6 ("New data-access paths prove their scoping")** applies directly: this
  introduces four new call sites that write to `audit_entries`, a tenant-scoped table.
  INV-6's own text is unconditional ("Every new API route ... or a new migration
  introducing a business table" — a new write call site reaching an existing
  tenant-scoped table is the same class of thing) and its "how to verify" requires an
  explicit SECURITY-REVIEWER statement of which invariants apply and how each is
  satisfied — reusing an already-compliant primitive (`Audit.insert_entry/3`) does not
  exempt a new caller from demonstrating it invoked that primitive correctly.
- **INV-1 (tenant data isolation)** applies and is satisfied by construction, but must
  still be *demonstrated*, per INV-1's own "how to verify" clause (c): confirm the
  `prefix` this new code passes to `Audit.insert_entry/3` is the same already-resolved
  tenant prefix already in scope at each of the four call sites (§2's table) — never a
  caller-supplied or re-derived value — exactly the provenance discipline INV-1(c)
  requires for any `tenant_id`/`prefix`-bearing write. Since all four sites source
  `prefix` from a value already flowing through the existing (already-reviewed)
  transaction rather than a newly introduced argument, this should be a short
  confirmation, not a new design question — but it is SECURITY-REVIEWER's confirmation
  to make, not this design doc's to assert on its own authority.
- INV-2/INV-3/INV-5/INV-9 do not apply (no new API response shape, no untrusted runtime,
  no lookup-by-id endpoint, no outbound URL). INV-4/INV-7 do not apply (no secret
  material, no raw SQL).

ELIXIR-DEV's handoff for the implementation of this design must route through
SECURITY-REVIEWER before REVIEWER, per the standard WF-02 gate ordering — this is not a
new exception to that ordering, just a confirmation that this change is in-scope for it
(the issue's own `suggested_fix` already flagged this as a question; this section
answers it).

## 8. Operator consumption — existing UI, honest gap named, no frontend scope added

**Verified directly (not assumed):** `web/src/api/audit.ts`'s `AuditLogFilters`
interface (lines 4-11) is `actor?`, `resource_type?`, `from?`, `to?`, `cursor?`,
`page_size?` — there is no `resource_id` field at the type layer, and consequently
`auditApi.list/1` never sends a `resource_id` query param either.
`web/src/pages/admin/AuditLogPage.tsx`'s filter state (lines 49-65) and its rendered
filter inputs (lines 91-140) mirror that exactly: `actor`, `resourceType`, `from`, `to`,
`pageSize` — no `resourceId` state, no input for it. **An earlier draft of this section
claimed `resource_id` filtering already exists in this UI; that was false, caught by
CODE-DESIGN-VALIDATOR reading these two files directly, and is corrected here.**

Adding that filter (both the `AuditLogFilters` field/query-param plumbing and a new
`AuditLogPage.tsx` input) is real, non-trivial frontend scope — a type change, an API
client change, a new controlled input, and its own test coverage — disproportionate to
this issue's MINOR severity and to what its `suggested_fix` actually asks for (a
recorded signal, not a new filter UI). This design explicitly declares that frontend
change **out of scope** for ISS-0784.

**The real, honest consumption path today**: an operator investigating a stalled
instance already knows its `instance_id` (it's the thing they're stalled on) but cannot
filter by it. What they *can* do with the existing page is filter by
`resourceType = "instance"` (a plain free-text `<input>`, confirmed by reading the
page's own filter-state wiring — not a `<select>` bound to a hardcoded option list) and
`from`/`to` to narrow the time window, then visually scan the resulting list's Resource
column for the `instance_id` they already have, and its Action column for
`"task_activation.rejected"`. This is materially better than before this design (there
was previously no row to find at all — application logs only) but it is scanning, not
filtering-by-id — that gap is real and is not fixed by this issue.

Named rather than silently left: without `resource_id` or `action` filters,
`AuditLogPage.tsx` cannot isolate either "this instance's history" or "all rejected
task-activation attempts across the tenant" without a full visual scan of whatever
`from`/`to`/`resourceType` window the operator narrows to. This is a pre-existing
frontend gap (not introduced by this design) and is out of scope for this MINOR issue's
sizing; flagged here rather than silently worked around, per `core-directives.md`'s "No
Issue Left Local-Only" — if ELIXIR-DEV/REVIEWER judge it worth a follow-up, it should be
filed as its own issue (adding `resource_id` and/or `action` to `AuditLogFilters` and
`AuditLogPage.tsx`), not folded into this one's implementation.

## 9. Invariants this design must hold (for TEST-DESIGNER)

- **INV-ISS0784-1**: A `{:invalid_form_schema, node_id, reason}` rollback at any of the
  four call sites (§2) always produces exactly one `audit_entries` row with
  `action = "task_activation.rejected"`, `resource_type = "instance"`,
  `resource_id = <that instance's id>`, readable via `Letflow.Audit.list_entries/1`
  after the main transaction has rolled back.
- **INV-ISS0784-2**: The rolled-back `tasks`/other rows never reappear — the audit
  write is provably independent of the failed Multi (i.e. rolling back the main
  transaction must not also remove the audit row; the audit row's own transaction must
  commit even though the main one aborted).
- **INV-ISS0784-3**: The original `{:error, {:invalid_form_schema, node_id, reason}}`
  (or the wider `create_error()`/`complete_error()` shape it flows into) returned to
  `create/2`'s/`complete_task/3`'s own caller is byte-identical to today's, whether or
  not the audit write itself succeeds — the audit side-channel is provably observable
  only in `audit_entries`, never in the primary call's return value.
- **INV-ISS0784-4**: A simulated `Audit.insert_entry/3` failure at the rejection-audit
  call site does not raise, does not change the primary call's return value (reuses
  INV-ISS0784-3's own assertion), and is observable only via whatever this codebase's
  test harness already uses to assert a `Logger` call was made (match existing
  `ExUnit.CaptureLog` precedent elsewhere in this test suite if one exists, rather than
  inventing a new logging-assertion idiom for this one test).

## 10. Open questions

- **OQ-1**: Repurposing `after_state` (schema-named "resulting state after the
  mutation") to instead mean "the state of a rejected attempt that never mutated
  anything" is a deliberate but narrow overload of `Letflow.Audit.Entry`'s existing
  field semantics. An alternative is a new, explicitly-named field
  (`rejected_attempt_state` or similar) added to `audit_entries` via migration — CODE-
  DESIGNER did not pursue this because it would widen scope well past this issue's
  MINOR/single-turn sizing (a new column touches `Letflow.Audit.Entry`'s changeset,
  its canonical-hash field list in `Letflow.Audit`'s moduledoc, `verify_chain/2`, and
  every existing caller's `entry_attrs()` map) — flagged for REVIEWER to confirm the
  smaller `after_state`-reuse choice is acceptable rather than silently deciding it is.
- **OQ-2**: `encode_form_schema_rejection_reason/1` (§4.2) is closed over
  `JsonSchemaShape.check/1`'s current two-member error union by design, so it breaks
  compilation if that union grows. Confirm with REVIEWER that "fails to compile on an
  unhandled new reason shape" is the preferred failure mode here versus a permissive
  fallback clause (e.g. `_other -> %{"code" => "unknown", "path" => nil}`) that would
  compile silently but risk masking a genuinely new rejection reason from ever reaching
  the audit trail with useful detail.
- **OQ-3 (inherited, not reopened)**: Neither `append_multi/6` nor
  `append_multi_from_existing_records/7` currently thread an `actor_id` of their own
  (`do_insert/3`'s own `record_task_create_audit/3` already documents `actor_id: nil`
  as deliberate, per REQ-195 OQ-1, since "No actor context reaches this function
  today"). This design does not change that — the `actor_id` used for the *rejection*
  audit entry (§2/§4.1) comes from each of the four call sites' own already-available
  actor context (the `create/2`/`complete_task/3` request's `attrs[:actor_id]`, or
  `EventStore.platform_actor_id()` for the two system-driven cascades), never from
  `TaskActivation` itself, so `TaskActivation`'s own "no actor context reaches this
  function" invariant is untouched by this design.
