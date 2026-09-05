# Stage 3 — Instance engine

Status: in progress -- every Stage 3 requirement through REQ-062 has
shipped (REQ-060 merged 2026-08-19), as has the later-added REQ-109
(variable_schemas storage and per-key output-variable validation,
closing ISS-0063 / GH#212, WF02-REQ109-20260819); one later-added S3
requirement is still open: REQ-110. Depends on: S2 (all of
REQ-022..REQ-042 `done`).
Requirements: REQ-044 `done` (Pure transition kernel core types and
dispatch skeleton); REQ-049 `done` (Variable scoping and merge, EE-09);
REQ-050 `done` (Exclusive gateway evaluation and condition expressions,
EE-05); REQ-043 `done` (Instance engine schema: instance_projections
ALTER, tokens, tasks); REQ-045 `done` (Instance start and engine
execution shell, EE-01); REQ-051 `done` (Parallel gateway split and
join, EE-06/EE-07 -- status already `done` in `docs/requirements.yaml`
per REQ-051's own DOC-UPDATER entry, but this header's pending list had
not been updated to reflect that; fixed here alongside REQ-045, same
gap-fix shape REQ-045's own DOC-UPDATER already applied to REQ-043
above); REQ-047 `done` (Task activation persistence, EE-03 -- tasks-row
insert, instance_projections update and event append committed in one
transaction via Letflow.Engine.TaskActivation; same header-sync gap-fix
shape applied by this requirement's own DOC-UPDATER); REQ-046 `done`
(Retirement of lib/letflow/process_instance.ex and its supervision tree
-- process_instance.ex and transition_event.ex deleted,
instance_supervisor.ex retained with start_instance/1 removed, reserved
for REQ-056/057; router.ex's dead pilot-slice routes removed as a
mid-flight gap fix); REQ-048 `done` (Task completion, EE-04 --
Letflow.Engine.complete_task/3 merges output variables, evaluates
outgoing edges, activates the next node(s) and flips the task to
COMPLETED with a TASK_COMPLETED event append, all in one Ecto.Multi;
same header-sync gap-fix shape applied by this requirement's own
DOC-UPDATER); REQ-058 `done` (Lua script execution audit
persistence path, LUA-07 minimal path -- Letflow.Engine.LuaScriptAudit,
schema-per-tenant migration, injected-executor test-double pattern,
missing/nil/empty-prefix fail-closed added during an INV-1 rework
cycle; the real Lua execution runtime remains S5 scope); REQ-052 `done`
(Instance cancellation, EE-08 -- Letflow.Engine.cancel_instance/3 sets
every open task to CANCELLED, appends one INSTANCE_CANCELLED event, and
sets instance status to CANCELLED in one transaction; supersedes and
deletes lib/letflow/parallel_approval.ex and
lib/letflow/approval_supervisor.ex, superseded by REQ-051's
PARALLEL_GATEWAY split/join; same header-sync gap-fix shape applied by
this requirement's own DOC-UPDATER); REQ-061 `done` (Execution error
handling, EE-10 -- Letflow.Engine.set_instance_error/2 and
Letflow.Engine.ExecutionError.append_multi/3, the single shared sink
every engine-internal failure funnels into; REQ-050's gateway-no-match
path fixed to route into it during a rework iteration, REQ-049's own
pre-existing gap filed separately as docs/issues/ISS-0063.yaml
(renumbered from ISS-0061 during Step Final's rebase; main
independently gained an unrelated ISS-0061 via a concurrent branch),
out of scope per REVIEWER sign-off; same header-sync gap-fix shape
applied by this requirement's own DOC-UPDATER); REQ-053 `done` (State
reconstruction by event replay, EE-11 --
Letflow.Engine.Reconstruction.reconstruct_instance/2, replays an
instance's full event log across events and events_archive through the
existing pure kernel to reconstruct state independent of the
projection, with opt-in write-back under SELECT ... FOR UPDATE NOWAIT
and a three-way instance-not-found/lock-contention/replay-failed error
taxonomy; same header-sync gap-fix shape applied by this requirement's
own DOC-UPDATER); REQ-057 `done` (Plugin handler interface and
registry contract, EXT-03 -- Letflow.Engine.PluginInterface behaviour +
Letflow.Engine.PluginRegistry GenServer/ETS registry; a crash/exit in a
handler is treated as an ERROR outcome routed through REQ-061's
set_instance_error/2, closing that requirement's own AC8 obligation
deferred forward at the time; wires REQ-031's plugin_lookup_fun and
REQ-049's variable merge; registry contract only, WASM plugin host is
S5 scope; same header-sync gap-fix shape applied by this requirement's
own DOC-UPDATER); REQ-056 `done` (Service task configuration, retry
classification and dispatch contract, EXT-01 --
Letflow.Engine.ServiceTask, pure config-parsing,
failure-classification, backoff and retry-decision functions with the
HTTP transport and service_catalog left injectable per this stage's
own scope boundary; an exhausted-retry outcome routes into REQ-061's
set_instance_error/2, closing REQ-061's own deferred AC8 obligation;
same header-sync gap-fix shape applied by this requirement's own
DOC-UPDATER); REQ-055 `done` (Concurrent instance isolation
guarantees, EE-12 -- a moduledoc-only lock-inventory section added to
lib/letflow/engine.ex plus three new concurrency tests in
test/letflow/engine_concurrency_test.exs verifying 100-concurrent-
instance completion, same-instance conflict resolution, and post-
concurrency reconstruction match; REQ-045's row-based state resolution
made AC5's process-kill scenario N/A; same header-sync gap-fix shape
applied by this requirement's own DOC-UPDATER); REQ-054 `done`
(Periodic instance state snapshots, ISS-601 --
Letflow.Engine.SnapshotWriter with a schema-per-tenant
instance_state_snapshots migration, extending REQ-053's reconstruct
path to replay from the latest snapshot forward instead of from
sequence 1 when one exists; a rework cycle wired the writer's four
call sites into lib/letflow/engine.ex after REVIEWER's first pass
caught them as dead code; same header-sync gap-fix shape applied by
this requirement's own DOC-UPDATER); REQ-059 `done` (Dependency pin
resolution, recording and inheritance, PIN-01..04 --
Letflow.Engine.PinResolver, resolving every versioned reference before
the instance row is written, recording the pin set in INSTANCE_STARTED's
payload with no side table, PinMissing with no fallback, and
inherited-wins pin inheritance for REQ-062 sub-process children; carries
forward R-Co's own PIN-01 AC1/AC2 and PIN-03 AC3 scope gap
(service_catalog/PLC-01, ISS-0672/GH-306, already noted above under
"Scope boundaries with S4 and S5") and reserves PIN_RETRY_EXHAUSTED as a
named, not-yet-emitted hook for PIN-03 AC4's exhausted-retry-budget DLQ
routing rather than a partial implementation; same header-sync gap-fix
shape applied by this requirement's own DOC-UPDATER); REQ-060 `done`
(Explicit instance pin rebind, PIN-05 -- Letflow.Engine.PinRebind, the
sole write path to a running instance's effective pin set after
INSTANCE_STARTED, requiring a mandatory reason, validating every ref
against REQ-059's merge_effective_pins with all-or-nothing application
on an UnknownPinRef, rejecting COMPLETED/CANCELLED/ERROR instances as
InstanceNotRebindable, appending one INSTANCE_PINS_REBOUND event per
CHANGED entry, and surfacing lock contention as a distinct
ConcurrentModification error via the same SELECT FOR UPDATE NOWAIT
convention REQ-053 established; same header-sync gap-fix shape applied
by this requirement's own DOC-UPDATER); REQ-062 `done` (Sub-process
invocation runtime half, SPC-01 -- child instance creation via
createWithParentInheritance, parent-token waiting_child_instance_id
wait/clear (R-Co GH #428 field-dropping regression test included),
input filtering and output-merge per interface, all four SPC-01 failure
modes routed through REQ-061's set_instance_error/2 rather than a local
ERROR transition, closing REQ-061's own AC8 obligation deferred forward
at build time; Step 2a hit max_rework (3/3) and was escalated PARTIAL,
recovered via a design-amendment pass (Multi-key/idempotency-key shape
addenda, lib/letflow/design/req062-sub-process-runtime.md §10-12)
rather than a blind fourth retry; composed against REQ-059's own
PinResolver integration during the merge of feature/WF02-REQ062-20260819
into main, since both requirements independently touched
lib/letflow/engine.ex/lib/letflow/engine/reconstruction.ex; same
header-sync gap-fix shape applied by this requirement's own
DOC-UPDATER); REQ-109 `done` (variable_schemas storage and per-key
output-variable validation at the merge call site, closing ISS-0063 /
GH#212 -- ports R-Co migrations/012_event_retention.sql:32's
variable_schemas table as a tenant-scoped migration plus
Letflow.Engine.VariableSchema (Ecto schema, the single per-definition
SELECT, and the pure validations builder), and replaces the hardcoded
`nil` variable_validations argument at
Letflow.Engine.merge_output_variables/7's VariableMerge.merge/3 call
with a real map, making REQ-061's `{:rejected, ...}` ->
ExecutionError.append_multi/3 branch reachable through
complete_task/3 for the first time; validation goes through REQ-024's
pure JsonSchema.validate/2 delegate with no new mix.exs dependency, and
the registration/INSERT path is deferred to REQ-078/REQ-082; closes
ISS-0063 / GH#212 and ISS-0075 / GH#296; same header-sync gap-fix shape
applied by this requirement's own DOC-UPDATER);
REQ-110 `pending`. Every Stage 3 requirement listed above through
REQ-062 is `done` in `docs/requirements.yaml`, as is the later-added
REQ-109; REQ-110 was added to this stage afterwards and is still open.

## Scope

PROVENANCE (historical, not current decision authority):
Port `src/engine/` (11 files: `instance.zig` 5550 lines,
`transition.zig` 3323, `reconstruction.zig` 1646, `pin_resolver.zig`
967, `service_task.zig` 420, `pin_rebind.zig` 388,
`snapshot_writer.zig` 348, `plugin_registry.zig` 232,
`lua_script_audit.zig` 201, `plugin_interface.zig` 79,
`transition_source_embed.zig` 24).

PROVENANCE (historical, not current decision authority):
The 20 requirements above decompose this along R-Co's own EE-01..EE-12
behavioural seams rather than one-requirement-per-file — `instance.zig`
and `transition.zig` each span many EE-\* requirements and cannot be a
single agent turn each. `src/design/engine.md`'s `## Section EE-NN`
headings map 1:1 onto those ids (EE-01 Start Instance L18, EE-02 Pure
Transition Function L442, EE-03 Task Activation L1086, EE-04 Complete
Task L1632, EE-05 Exclusive Gateway L2238, EE-06 Parallel Split L2638,
EE-07 Parallel Join L2898, EE-08 Cancellation L3299, EE-09 Variable
Scoping L3957, EE-10 Execution Error Handling L4571, EE-11 State
Reconstruction L5237, EE-12 Concurrent Instance Safety L5771), and the
non-EE engine files carry their own R-Co requirement ids: ISS-601
(`snapshot_writer.zig`, REQ-054), EXT-01 (`service_task.zig`, REQ-056),
EXT-03 (`plugin_interface.zig` + `plugin_registry.zig`, REQ-057),
LUA-07's minimal audit path (`lua_script_audit.zig`, REQ-058),
PIN-01..04 (`pin_resolver.zig`, REQ-059), PIN-05 (`pin_rebind.zig`,
REQ-060).

Two requirements do not map to a single R-Co engine file. REQ-061
(EE-10 execution error handling) was split out of REQ-052 on sizing
review — EE-08 and EE-10 together span 1,324 lines of `engine.md`
against REQ-044's 644-line baseline, and they differ in kind:
cancellation is caller-initiated and terminal, while error handling is
engine-internal and halts non-terminally at ERROR pending an S6
dead-letter action. REQ-051 (EE-06 + EE-07) was reviewed for the same
concern and deliberately left intact at 661 lines, because split and
join share the Token/JoinCounter model and EE-07's
cancelled-branch-exclusion rule cannot be stated without the split half
present.

PROVENANCE (historical, not current decision authority):
**SPC-01's runtime half is in scope here (REQ-062).** Shipped REQ-032
ported only SPC-02's definition-time half and states in both its
description and its acceptance criteria that SPC-01 "belongs to S3
(`src/engine/` port)", naming `src/engine/instance.zig` as the
integration point — so this is in scope by REQ-032's own terms rather
than an addition to the stage. It covers sub-process child instance
creation (`createWithParentInheritance`, internal-only), the
parent-token wait (`waiting_child_instance_id`), interface-filtered
input/output propagation, and the four SPC-01 failure modes. Two other
requirements in this batch presuppose it: REQ-044 ports
`Token.waiting_child_instance_id`, and REQ-059 AC6 requires child-instance
pin inheritance — neither has a child-creation path to hang off
without REQ-062.

PROVENANCE (historical, not current decision authority):
**`transition_source_embed.zig` is deliberately not ported and has no
requirement.** Its own header states it exists solely because Zig's
`@embedFile` cannot escape a module root, so
`tests/differential/differential_test.zig` needs a one-line shim
colocated beside `transition.zig` to read its raw source bytes at
compile time. Elixir has no equivalent constraint, so an Elixir port
would be a file with no purpose. Recorded here explicitly rather than
silently dropped from the 11-file count.

PROVENANCE (historical, not current decision authority):
Two dependencies this stage's engine writes into come from directories
outside `src/engine/` and are only partially in scope: `tasks`/`tokens`
tables (R-Co `migrations/005_instances.sql`) are created by REQ-043
because the engine cannot activate or complete a task without them, but
`src/tasks/store.zig`'s standalone task query/list surface (1202 lines)
is not ported here.

## Scope boundaries with S4 and S5

- **HTTP routes and controllers belong to S4** (api-surface). Every
  requirement above builds context-module functions returning tagged
  tuples; the status-code mapping (`POST /instances`,
  `POST /tasks/:id/complete`, `POST /instances/:id/cancel`,
  `POST /instances/:id/rebind-pins`, `GET /instances/{id}/pins`,
  `POST /instances/:id/reconstruct`) is S4's. This is the same boundary
  REQ-036 and REQ-042 already set in S2.
- **The Lua and WASM execution runtimes belong to S5**
  (scripting-and-plugins), which needs its own build-vs-bind decision
  record first. What stays in S3 is the engine-side *plugin registry
  contract* (REQ-057) and the *lua audit persistence path* (REQ-058) —
  both ported against injected executor/handler interfaces, the same
  injectable-lookup pattern REQ-031 used for its own missing
  `ServiceCatalog`/`PluginRegistry` dependencies. Neither requirement
  may add a Lua/WASM dependency to `mix.exs`.
- Also out of scope, with named hooks left in the affected
  requirements rather than partial implementations: SCH-03 timer
  cancellation and OBS-05's dead-letter queue (`src/scheduler/`,
  `src/dlq/` — S6), the real outbound HTTP transport for SERVICE_TASK
  dispatch (REQ-056 leaves it injectable), and the `service_catalog` /
  PLC-01 module catalog that PIN-01's AC1/AC2 and PIN-03's AC3 need —
  R-Co itself holds PIN-01/PIN-03 at TESTED rather than RELEASED over
  exactly that gap (its ISS-0672/GH-306), and REQ-059 carries the same
  scoping forward explicitly.

This stage generalizes Letflow's existing early pattern —
`Letflow.ProcessInstance` (`lib/letflow/process_instance.ex`),
`Letflow.ParallelApproval` (`lib/letflow/parallel_approval.ex`), and
`Letflow.InstanceSupervisor` (`lib/letflow/instance_supervisor.ex`) — into a
real, definition-driven engine, rather than starting from scratch.
Read those three modules first.

Two early findings (full write-ups retired, see
`docs/status/requirement_status.yaml` for the removal record) are
direct input to how this generalization should work:

- **Idiomatic OTP, confirmed:** `ParallelApproval` held dual-approval
  progress as genuine `:gen_statem` data (mutated via ordinary map
  updates) and dispatched on real function-clause/guard matching,
  introducing no extra top-level state atoms or hidden `case data.mode
  do` dispatch to fake what `:gen_statem` already provides. Supervision
  isolation was preserved via a second, deliberately separate
  `DynamicSupervisor` rather than a shared/singleton process. Hold the
  generalized engine to the same bar: real per-state callbacks, real
  supervised isolation, not a `GenServer` simulating a state machine by
  hand.
- **Process-per-instance's actual value, and its limits:** for a
  low-complexity two-approver feature, process-per-instance was
  operationally heavier than a plain Postgres row needed to be — real,
  correctly-supervised OTP, but buying a narrower guarantee ("the id
  stays reachable") than it sounds, for real supervision-code cost. Its
  case gets stronger specifically where this stage's actual scope
  lives: service task dispatch, plugin registries, and anything with
  expensive-to-reconstruct in-memory state, timers, backpressure, or an
  OS-level resource with no natural row representation. Don't assume
  process-per-instance is automatically the right call for every piece
  of engine state — check which side of that line it falls on.

**Where these two findings land in the expanded requirements.** Both
are cited by name inside the requirements they bind, so no requirement
silently overrides either:

- REQ-045 carries the stage's single largest design question — whether
  a running instance is a supervised `:gen_statem` or a plain
  transactional context module — as an explicit OPEN QUESTION for
  CODE-DESIGNER, following REQ-039/REQ-040's precedent. It notes that
  the answer may legitimately differ per subsystem: EE-01's own start
  path is close to the row side (every write is already transactional,
  and REQ-053's reconstruction makes state cheaply rebuildable), while
  REQ-056's service task dispatch and REQ-057's plugin registry are
  the cases the second finding names as strongest for a process.
- REQ-052, REQ-054 and REQ-057 each carry the same question scoped to
  their own state (cancellation of a live process, the snapshot-cadence
  counter, the registry's storage mechanism). REQ-052 and REQ-057
  additionally inherit REQ-040's crash-safety note: `try/after` does
  not cover a process exit.

PROVENANCE (historical, not current decision authority):
**Gateway condition evaluation is not an open question** (REQ-050).
R-Co has a real, working implementation to port:
`src/engine/transition.zig`'s `evaluateGatewayCondition()` (~L1118)
translates the CEL syntax stored in definition graphs into R-Co's
`src/expr/` module, then parses and evaluates there, returning false on
any translation/parse/evaluation error — which is exactly EE-05 AC4's
treat-errors-as-false rule. The "`vendor/cel/cel.zig` is a stub"
wording that appears in `src/design/definition.md` and in `engine.md`'s
own EE-05 section is stale as a description of *runtime* evaluation
(retired by R-Co commit `480b7dc5`, which wired `src/expr` into
`transition.zig`); `vendor/cel/cel.zig` is in any case a real
13,877-byte subset evaluator, not a stub. REQ-029 quoted that wording
correctly for its own definition-time syntax-check scope. REQ-050
records the distinction so it is not propagated a third time.
- REQ-046 and REQ-055 hold the first finding's bar concretely — real
  supervised isolation via a `DynamicSupervisor` (the deliberate
  `ApprovalSupervisor`-vs-`InstanceSupervisor` separation is the
  precedent), never a singleton process funnelling every instance's
  work, and never a `GenServer` hand-simulating a state machine.

**Generalization of the early modules.** REQ-045 supersedes
`lib/letflow/process_instance.ex` (its hardcoded four-atom state graph
becomes REQ-027 definition data, snapshotted per instance by REQ-033)
and generalizes `lib/letflow/instance_supervisor.ex`; REQ-046 executes
that retirement/rewiring as its own reviewable unit. REQ-052 (with
REQ-051) supersedes `lib/letflow/parallel_approval.ex` — its
two-approver machine is the hand-written special case of what
PARALLEL_GATEWAY split/join now expresses as definition data.

## Decisions

No dedicated decision file expected unless this stage surfaces a
genuinely new choice beyond what S0/S2 already settled. Two
candidates are flagged inside the requirements as open questions that
may escalate to a `decisions/000x-*.md` record if CODE-DESIGNER's
resolution introduces a new dependency or a platform-wide rule
(matching the precedent REQ-024's JSON Schema library choice set):

- The plugin-registry storage mechanism (REQ-057) and the
  process-vs-row resolution for the engine itself (REQ-045).
- Snapshot storage/cadence for `instance_state_snapshots` (REQ-054),
  which is a distinct table from REQ-027/REQ-033's
  `instance_definition_snapshots` — periodic execution state vs. the
  immutable PD-08 definition graph.

All S3 tables (REQ-043's `instance_projections` ALTER, `tasks`,
`tokens`; REQ-054's `instance_state_snapshots`; REQ-058's
`lua_script_execution_audit`) follow
`docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B via
REQ-022's schema-per-tenant `:prefix` mechanism. None is classified
GLOBAL, so none needs REQ-041's GLOBAL-exception flagging.

## REVIEWER sign-off

(Not yet populated — S3 is in progress. The stale "this stage hasn't
started" wording this section carried until 2026-08-20 was left over from
before S3 began and was corrected by REQ-109's DOC-UPDATER pass; it did
not mean no reviews had happened. Every S3 requirement merged so far
passed REVIEWER as a per-requirement WF-02 Step 2d gate, recorded in that
requirement's own handoff under `handoffs/WF02-REQ0NN-*/`, and two such
sign-offs are already cited inline in the requirement list above (REQ-061's
ISS-0063 out-of-scope ruling, line 51; REQ-054's dead-call-site rework,
line 89). The consolidated per-requirement sign-off section here is
populated at the S3 stage gate (WF-04), not incrementally per requirement
— same convention as `stage-2-event-store-definitions.md` states for S2 and
`stage-1-identity.md`'s populated section followed for S1.)
