# REQ-188 design review findings (Step 1b, iteration 1) — FAIL

Reviewed: `lib/letflow/design/req188-recurring-timers-and-retention.md` against
`docs/requirements.yaml`'s REQ-188 entry, `handoffs/WF02-REQ188-20260829/step-01-code-designer.json`,
and the real source (`lib/letflow/scheduler.ex`, `lib/letflow/scheduler/poller.ex`,
`lib/letflow/scheduler/timer.ex`, `priv/repo/migrations/20260829020001_create_timers.exs`,
`docs/issues/ISS-0014.yaml`, `docs/migration/decisions/0003-ecto-schema-strategy.md`,
`lib/letflow/definitions/graph.ex`, `lib/letflow/event_store.ex`).

## Verdict: FAIL — one defect, mechanical and dispositive

## What checks out (verified independently against real code/docs, not the design's narrative)

1. **Re-arm insertion point.** `do_fire/2`'s real `with` chain (`lib/letflow/scheduler.ex`
   L219-243) ends with `Engine.advance_after_timer_fired/3` then returns `{:ok, :fired}`.
   The design's claimed insertion point for `maybe_rearm_timer/3` — one more `with` step
   after that call, still before the `{:ok, :fired}` return, still inside `fire_timer/2`'s
   single `Repo.transaction/1` — genuinely fits the real function's structure.
2. **`fire_at` anchor.** Anchoring the new row's `fire_at` to the fired timer's own
   `fire_at` + interval (not to `now`/`fired_at`) is the correct drift-avoidance choice and
   matches AC 1's literal wording ("fire_at equal to the fired timer's fire_at plus one
   hour").
3. **"At most once per poll cycle" — structural claim holds.** Verified against the real
   `poll_and_fire/1` (L149-170): `claim_due_timer_ids/2` is called exactly ONCE per
   invocation, up front, producing a fixed `timer_ids` list that `Enum.reduce/3` then
   iterates. `Letflow.Scheduler.Poller.handle_info(:tick, state)` (poller.ex L51-58) calls
   `poll_and_fire/1` once per tenant schema per tick — not per-timer. A newly re-armed row
   is inserted inside the transaction firing the *previous* occurrence, strictly after the
   list was already materialized, so it cannot appear in the same cycle's claim query. The
   design's reasoning is sound and matches the real execution order.
4. **`repeat_total`/`fired_count` termination logic.** REQ-186's real CHECK constraint
   (`priv/repo/migrations/20260829020001_create_timers.exs` L111-118) is exactly
   `fired_count IS NOT NULL AND fired_count >= 0 AND (repeat_total IS NULL OR (repeat_total
   >= 1 AND fired_count <= repeat_total))`. The design's §1.2 case-2 comparison
   (`new_fired_count >= repeat_total` → series complete) matches this bound exactly, and the
   worked "R3/PT1H" trace (fires at fired_count 0→1→2, stops before a 4th row at
   new_fired_count=3) is arithmetically correct.
5. **Poller state widening.** `%{} → %{last_retention_run_at: DateTime.t() | nil}` is a real,
   compatible change. Grepped `test/letflow/scheduler/poller_test.exs` and
   `test/letflow/scheduler_test.exs`: no test pattern-matches or asserts on the Poller's
   state shape directly (`init(%{})`/`handle_info(:tick, %{})` literals do not appear), so
   REQ-186/187's existing tests make no assumption this change breaks.
   `retention_enabled?()` genuinely defaults to `false` by the same
   `scheduler_config()[:key] || @default` pattern the four existing accessors already use —
   this is a real default, not just an assertion.
6. **ISS-0014 citation.** Read `docs/issues/ISS-0014.yaml` directly. Its resolution
   (resolved 2026-08-17) says verbatim: "Adopted option (a) ... port archive/1 as a
   row-level move ... Rejected (b) ... Rejected (c) (port PAR-03's whole-partition retention
   now) because it would force partitioning early, contradicting 0003 Decision C's
   deliberate deferral, and would need REVIEWER sign-off / a new decision record." The
   design's §0 point 1 quotes this accurately — not strengthened or paraphrased into
   something the record doesn't say.
7. **`archive/1` zero-callers claim.** Grepped `lib/` for `EventStore.archive(` and `def
   archive`: the only hits are the definition itself (`event_store.ex:989`), an unrelated
   `Letflow.Definitions.archive/2` (different schema), and moduledoc/comment references in
   `reconstruction.ex` and `retention_policy.ex`. Zero real call sites today — claim
   verified.
8. **`escalation_timer_duration` absence.** Read `lib/letflow/definitions/graph.ex`
   directly: CHK-12 (`check_timer_duration/1`, L738) filters only `:TIMER` nodes; no
   reference to `escalation_timer_duration` exists anywhere in the file, and `:HUMAN_TASK`'s
   own checks (L684, L1123) validate other attributes only. The design's claim is accurate.

## The defect: fenced code blocks reproduce real implementation, not just signatures

Task acceptance criterion 8 / core design rule (repeated verbatim in this design's own §1's
framing and hit twice already on this pipeline for a different requirement, per
`docs/anti-patterns.md`'s recurring "no literal Elixir implementation code in design docs"
finding — see this same repo's commits `3680243` and `290c6b2` reworking a different design
for exactly this): design artefacts may show `@spec`s, type shapes, and bare function heads,
but must not reproduce real function BODIES.

Two fenced blocks in this design cross that line:

**§2.3, lines 230-236** — this is a complete, runnable implementation of
`retention_due?/1`, not a signature:

```
def retention_due?(nil), do: true
def retention_due?(%DateTime{} = last_run_at) do
  DateTime.diff(DateTime.utc_now(), last_run_at, :millisecond) >= retention_interval_ms()
end
```

This is exactly the code ELIXIR-DEV would write verbatim into `scheduler.ex` — a full
pattern-matched two-clause function with a real body, not a description of behavior.

**§2.4, lines 256-264** — this reproduces the actual body of the new step being added to
`Poller.handle_info(:tick, state)`, including the real `if/do/else` control flow, the real
`Enum.each(schemas, &Scheduler.run_retention_sweep/1)` call, and the real state-update
expression:

```
new_state =
  if Scheduler.retention_enabled?() and Scheduler.retention_due?(state.last_retention_run_at) do
    Enum.each(schemas, &Scheduler.run_retention_sweep/1)
    %{state | last_retention_run_at: DateTime.utc_now()}
  else
    state
  end
```

This is not a type shape or a table — it is the literal algorithm, syntactically
indistinguishable from what would land in `poller.ex`.

By contrast, §2.2's `run_retention_sweep/1` block (lines 212-216) is fine — it shows only
the `@spec` plus a bare function head with a guard, no `do...end` body — that is the
acceptable "signature only" form the rest of the design mostly follows (§1.2's
`maybe_rearm_timer/3` spec, §2.1's three accessor specs).

## Required rework

Replace both offending blocks with prose + a bare signature, mirroring how §1.2 already
describes `maybe_rearm_timer/3`'s behavior in prose (numbered cases) while keeping only the
`@spec` in a fenced block. Concretely:
- §2.3: keep `@spec retention_due?(last_run_at :: DateTime.t() | nil) :: boolean()`; describe
  the two cases in prose ("nil means never run, due immediately... a non-nil last_run_at is
  due once `retention_interval_ms()` has elapsed since it").
- §2.4: keep the prose already surrounding the block (which is good) but delete the fenced
  code entirely; describe the added step's four properties in prose instead (guarded by both
  `retention_enabled?()` and `retention_due?/1`; iterates the same `schemas` list already
  computed for the timer-poll loop; calls `run_retention_sweep/1` once per schema; updates
  `last_retention_run_at` to `DateTime.utc_now()` only when the sweep ran, otherwise leaves
  state untouched).

No other defect found. Everything else in scope for this validation pass — the re-arm
mechanism, the "once per cycle" structural claim, the CHECK-constraint alignment, the
Poller state widening's compatibility, the ISS-0014/CHK-12 citations, and the
zero-callers claim — is accurate and verified against real code.
