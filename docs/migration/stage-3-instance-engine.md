# Stage 3 — Instance engine

Status: in progress. Depends on: S2 (all of REQ-022..REQ-042 `done`).
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
mid-flight gap fix); REQ-048, REQ-052, REQ-053, REQ-054, REQ-055,
REQ-056, REQ-057, REQ-058, REQ-059, REQ-060, REQ-061, REQ-062
(`docs/requirements.yaml`, 13 total) `pending`.

## Scope

Port `src/engine/` (11 files: `instance.zig` 5550 lines,
`transition.zig` 3323, `reconstruction.zig` 1646, `pin_resolver.zig`
967, `service_task.zig` 420, `pin_rebind.zig` 388,
`snapshot_writer.zig` 348, `plugin_registry.zig` 232,
`lua_script_audit.zig` 201, `plugin_interface.zig` 79,
`transition_source_embed.zig` 24).

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

**`transition_source_embed.zig` is deliberately not ported and has no
requirement.** Its own header states it exists solely because Zig's
`@embedFile` cannot escape a module root, so
`tests/differential/differential_test.zig` needs a one-line shim
colocated beside `transition.zig` to read its raw source bytes at
compile time. Elixir has no equivalent constraint, so an Elixir port
would be a file with no purpose. Recorded here explicitly rather than
silently dropped from the 11-file count.

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

(None yet — this stage hasn't started.)
