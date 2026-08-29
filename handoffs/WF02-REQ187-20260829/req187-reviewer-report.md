# REQ-187 — REVIEWER report (Step 2d)

**Verdict: PASS**

## Idiomatic vs. crutch

`dispatch_timer_arrival/3` and `dispatch_timer_fired/4` in
`lib/letflow/engine/transition.ex` are structurally identical to the
already-reviewed `:SUB_PROCESS` pair (`dispatch_sub_process_entry/4` /
`dispatch_sub_process_completion/4`) and to `dispatch_task_completion/4`:
arrival leaves the token in place and emits a `pending_event()`; fired
reuses the shared `advance_off_completed_node/4` helper, the same one
`:HUMAN_TASK` completion and `:SUB_PROCESS` completion already share. No
new dispatch mechanism was invented — the fourth `pending_event()` variant
and fourth `transition_event()` variant both follow the tagged-tuple
convention the module already documents as open-ended (moduledoc:
"Deliberately not a closed enumeration beyond these four"). This is the
right level of abstraction for the requirement — a `gen_statem` was never
in scope for this pure kernel module, and none was introduced.

`prepare_timer_arms/4` mirrors `prepare_sub_process_children/5`'s own
`Enum.filter(&match?(...))` precedent exactly. `build_timer_arms_multi/4`
reuses `Scheduler.create/2`'s documented `Multi`-accepting branch rather
than hand-rolling a second timer-insert path. No crutch found.

## Supervision

No new process, no `spawn`, no change to `Letflow.InstanceSupervisor` or
any supervision tree in this diff. `advance_after_timer_fired/3` runs as
ordinary sequential/`Multi` code inside `Scheduler.do_fire/2`'s already-open
transaction (nested as a Postgres `SAVEPOINT`, not a new process). Per-instance
process isolation is unaffected.

## Purity gate (independently re-verified, not trusted from SECURITY-REVIEWER)

Ran the moduledoc's own grep against `instance_state.ex`, `token.ex`,
`transition.ex`:

```
grep -n "Repo\.\|Logger\.\|DateTime\.\|System\.os_time\|System\.system_time\|HTTPoison\|Req\.\|File\.\|:rand\.\|:crypto\." lib/letflow/engine/instance_state.ex lib/letflow/engine/token.ex lib/letflow/engine/transition.ex
```

All 4 matches are inside `transition.ex`'s own moduledoc prose (lines
33–35, 49) describing the grep itself — zero matches in executable code.
`dispatch_timer_arrival/3` reads only its own `token`/`node.id` arguments;
`dispatch_timer_fired/4` reads only `definition_snapshot.edges`. Confirmed
clean.

## Scope creep

`git diff --stat main...HEAD` touches exactly 6 `lib/` files plus the
design doc, all named in the design doc's §11 file list: `transition.ex`,
`graph.ex`, `engine.ex`, `task_activation.ex`, `scheduler.ex`,
`reconstruction.ex`. No route, controller, migration, or `web/` file. No
change to `lib/letflow/dlq.ex`. No change to REQ-056's SERVICE_TASK
HTTP-abort deferral (confirmed by grep — `cancel_instance/3`'s moduledoc
still names that half as deferred, untouched). No REQ-188
recurrence/escalation-timer machinery added — `timer_type: "deadline"` is
the only value used, `"escalation"`/`"scheduled_transition"` are untouched.
`prepare_timer_arms/4`'s multi-timer guard (`{:error,
{:multiple_timers_in_one_hop_chain_not_supported, node_ids}}`) is scoped
exactly to REQ-187's own acceptance criteria — it does not attempt to
widen `Scheduler.create/2`'s API (correctly left for a future requirement
per the design doc's own framing of that as out of scope).

## Design-doc open questions (§13), reviewed

1. **Calendar-approximation duration semantics** — acceptable. Fixed-length
   (365d/30d/7d/86400s/3600s/60s/1s) is a reasonable default for a
   workflow deadline timer, blast radius is contained to one function's
   internals, `@spec` is unaffected either way. No objection.
2. **`timer_type: "deadline"`** — acceptable. Elimination-based reasoning
   (the other three values read as reserved for REQ-188's own
   escalation/recurrence work) is sound and does not collide with anything
   on record. If a later requirement needs a different literal, only one
   call site changes.
3. **`:scheduler_timer` step-name collision (OQ-3)** — resolved correctly,
   and resolved *better* than the two options the design doc itself
   offered ("confirm it can't happen" vs. "widen `Scheduler.create/2`'s
   API"). ELIXIR-DEV added a third option: a defensive, typed
   `{:error, {:multiple_timers_in_one_hop_chain_not_supported, node_ids}}`
   guard in `prepare_timer_arms/4`, which turns what would otherwise be a
   raw `Ecto.Multi` `RuntimeError` (a real reachable scenario — two
   parallel branches both landing on distinct `:TIMER` nodes in the same
   hop-chain, since `:PARALLEL_GATEWAY` splits are real, shipped
   behavior) into a total, never-raising failure. This is exactly the
   codebase's own "never raise" totality discipline applied correctly, and
   it does not silently assume single-timer-per-hop-chain is impossible —
   it fails loudly and typed instead. Good catch, no rework needed.
4. **`reconcile_projection/5` has no timer-cancellation call** — the
   design doc's own structural argument holds: `dispatch_end/3`'s
   completion rule requires zero live tokens, and a `:TIMER`-parked token
   is never removed by an ordinary hop, so an instance cannot reach
   `:completed` via `complete_task/3` while a sibling `:TIMER` token is
   still live. Correctly left as a documented scope boundary, not
   silently papered over.
5. **`:TIMER` out-degree unenforced** — matches CHK-12's own documented
   scope (duration only, not out-degree) and existing precedent for other
   node types with no dedicated out-degree check. Not a regression, not
   scope creep to add one here uninvited.

## Decision-record consistency

No conflict with any `docs/migration/decisions/` record. REQ-185/186's
scheduler architecture (`Letflow.Scheduler`, `Letflow.Scheduler.Timer`,
`Multi`-based `create/2`) is reused unchanged, not re-decided —
`advance_after_timer_fired/3` calls into it as a plain function, no new
framework/library choice introduced.

## Design-vs-implementation fidelity

Checked line-by-line against `lib/letflow/design/req187-timer-engine-wiring.md`:
- `prepare_timer_arms/4` and `build_timer_arms_multi/4` (engine.ex) match
  §3.1/§3.2 exactly, including the identity `id_map` trick in the
  `complete_task`/`advance_after_timer_fired` call sites, which is safe
  because `do_reconcile_token_records/4`'s own
  `{:new_token_during_resume_not_supported, _}` guard runs *before* the
  timer-arm `Multi.merge` step in both `build_complete_task_tail_multi/6`
  and `persist_timer_fired_advance/6` — by the time the timer-arm step
  runs, every surviving token's `token_id` is already confirmed to be a
  real, persisted `TokenRecord` id (`to_pure_token/1`'s own
  `token_id: to_string(record.id)` invariant), so `token_id -> token_id`
  is a correct identity map, not a shortcut that happens to work by luck.
- `finalize_instance_projection/5`'s call site is unmoved, arity widened
  from 2 to 5 exactly as specified, reusing `attrs.completed_at`. Verified
  by reading the diff context, not by trusting the design doc's claim.
- `run_cancel_instance/5`'s `:timer_cancellations` step sits between
  `:open_tasks` and `:instance_projection`, matching §6.1's load-bearing
  lock-ordering requirement.
- `Scheduler.do_fire/2`'s new `with` clause and `attempt_fire/2`'s new
  `{:error, {:instance_not_active, _status}} -> :already_final` clause
  match §7.1/§7.2 exactly, in the right order relative to the existing
  catch-all.
- `Reconstruction`'s new `"TIMER_FIRED"` clause matches §9 — position-match
  by `node_id` (not marker-based), no variable merge.

No divergence found between the design doc and the shipped code.

## Mechanical test-file updates (transition_test.exs, task_activation_test.exs, scheduler_test.exs, scheduler/poller_test.exs)

All four are genuine, non-weakening mechanical consequences:
- `transition_test.exs`: the old 3-way catch-all test (`SERVICE_TASK`,
  `TIMER`, bogus atom) is narrowed to 2 (`TIMER` removed, since it now has
  real dispatch), and a new, more thorough `:TIMER entry/fired` describe
  block is *added* — net increase in coverage for this file, not a
  removal. `cancel_pending_timers/2` test replaced with `/5` doc-content
  test; the moduledoc itself explains real `update_all` coverage now lives
  in `engine_test.exs`'s DB-level tests instead of this pure/async file —
  confirmed `engine_test.exs` passes (42/42) and its scope does include
  `create/2`/`complete_task/3` Multi behavior.
- `scheduler_test.exs` / `scheduler/poller_test.exs`: the shared fixture
  graph's middle node changed from `HUMAN_TASK` to `TIMER` — a required
  change, not a weakening, since REQ-187 makes `fire_timer/2` re-enter the
  engine and this file's own tests are specifically about firing
  mechanics; a `HUMAN_TASK` fixture can no longer be fired through by this
  module at all. `HUMAN_TASK` dispatch itself keeps its own coverage
  elsewhere (`task_activation_test.exs`, `sub_process_test.exs`,
  `transition_test.exs`'s human-task describe blocks), untouched by this
  diff. `token_id: live_token_id!/2` additions are necessitated by
  `advance_after_timer_fired/3`'s direct token-id match (§8.2) — without
  it every previously-passing "timer fires successfully" test would now
  fail with `{:unknown_token_id, ...}`, which is exactly the failure mode
  I'd expect if this update were skipped, confirming it's load-bearing
  rather than decorative.

## Verification performed

- `mix compile --warnings-as-errors` — clean.
- `grep` purity check — zero real matches (only moduledoc prose).
- `mix test test/letflow/engine/transition_test.exs test/letflow/engine/task_activation_test.exs test/letflow/engine/reconstruction_test.exs` — 59 passed.
- `mix test test/letflow/scheduler_test.exs test/letflow/scheduler/poller_test.exs` — 18 passed.
- `mix test test/letflow/engine_test.exs` — 42 passed.
- `git diff --stat main...HEAD` — scope confirmed limited to the 6 named files.

## Conclusion

PASS. No rework required. Forwarding to TEST-DESIGNER (Step 3) for
mutation-driven coverage per the original acceptance criteria.
