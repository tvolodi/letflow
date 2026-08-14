# Stage 3 — Instance engine

Status: not started. Depends on: S2. Requirements: none expanded yet.

## Scope

Port `src/engine/` (11 files: `instance.zig`, `transition.zig`,
`snapshot_writer.zig`, `reconstruction.zig`, `service_task.zig`,
`plugin_interface.zig`, `plugin_registry.zig`, `pin_resolver.zig`,
`pin_rebind.zig`, `lua_script_audit.zig`,
`transition_source_embed.zig`).

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

## Decisions

No dedicated decision file expected unless this stage surfaces a
genuinely new choice beyond what S0/S2 already settled (e.g. snapshot
storage format, plugin-registry extensibility mechanism).

## REVIEWER sign-off

(None yet — this stage hasn't started.)
