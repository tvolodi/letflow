# REQ-185 TEST-DESIGNER verification note

Design-only requirement — no ExUnit tests written (there is no implementation
yet; REQ-186/187/188 build the actual code). Per Step 3's handoff, this note
independently re-derives/re-checks the design artefact's own empirical claims
rather than trusting its citations of itself.

## 1. §6 qps arithmetic (500 tenants / 5s tick)

Design text (§6): "500 queries every 5 seconds = **100 queries/second**" and
"1000 tenants ⇒ ~200 qps."

- Arithmetic: 500 / 5 = 100. **Correct.** 1000 / 5 = 200. **Correct**, and
  consistent with the claimed linear scaling (queries-per-tick scales 1:1
  with tenant count at a fixed poll interval, so qps = tenant_count / interval_s).
- Underlying assumption re-checked against the poller description itself
  (§6, first paragraph): "the poller iterates tenant schemas per tick ...
  running its `FOR UPDATE SKIP LOCKED`-guarded claim query **once per tenant
  schema per tick**." That is exactly "one query per tenant per tick" — the
  assumption the 500/5=100 arithmetic depends on. No hidden per-timer query,
  no N+1 inside a tenant's schema (the claim query is a single `SELECT ...
  LIMIT max_timers_per_cycle`, not one query per due row). The arithmetic and
  its underlying assumption both hold.

**Verdict: CONFIRMED.**

## 2. §8 `dlq_entries.entry_type` unconstrained-string claim

Read directly (not taken on the design doc's word):

- `priv/repo/migrations/20260829000001_create_dlq_entries.exs`: column is
  declared `add :entry_type, :string, null: false` — no `Ecto.Enum`, no CHECK
  constraint anywhere in the `change/0` function. The migration's own header
  comment states this is deliberate: "`entry_type` is plain `:string`, NOT
  `Ecto.Enum` -- design doc section 1: the requirement text states this is
  extensible." Only an index exists on `entry_type` (`idx_dlq_entries_entry_type`),
  no value restriction.
- `lib/letflow/dlq/entry.ex`: schema declares `field(:entry_type, :string)`
  (plain string type), contrasted explicitly in the moduledoc with `status`,
  which *is* a closed `Ecto.Enum` over `[:pending, :retrying, :resolved,
  :discarded]`. `insert_changeset/2` casts `:entry_type` via `cast/3` with no
  `validate_inclusion/3` or any allow-list validation anywhere in the file.
- `lib/letflow/dlq.ex`: `enqueue/2`'s attrs spec (line 55) types `entry_type`
  as a bare `String.t()`, and grepping the whole file for `entry_type` shows
  no allow-list/inclusion check — it is only used for casting (via the
  changeset) and as an equality filter in `filter_by_entry_type/2` (line
  347-348) for `list/2`'s query. No gate rejects an arbitrary string.

**Verdict: CONFIRMED.** `entry_type` is genuinely a bare, unconstrained
`:string` column; `"timer"` requires no schema change.

## 3. §1 `lib/letflow/application.ex` supervision-tree claim

Read the full file (127 lines). The `children` list is: `Letflow.Repo`,
`Ecto.Migrator`, `Oidcc.ProviderConfiguration.Worker`, a `Registry`,
`Letflow.InstanceSupervisor`, `Task.Supervisor` for `SandboxPool` +
`Letflow.SandboxPool`, then five more `Task.Supervisor`s (Engine plugin, Lua
wall-clock kill, Wasm module registry, Wasm capability gate, Wasm module
version registry) plus `Letflow.Engine.Wasm.ModuleVersionRegistry`, plus
`http_child/0`'s conditional `Bandit` listener. No `Process.send_after`,
no `:timer.send_interval`, no `GenServer` performing periodic ticks anywhere
in the file (confirmed by reading top to bottom; the only timing-adjacent
concept is the Lua wall-clock *kill* mechanism, which is a one-shot
per-execution guard, not a recurring ticker).

**Verdict: CONFIRMED.** No periodic/ticking process exists in the
supervision tree today.

## 4. `mix.exs` no-Oban/Quantum claim

`grep -n "oban\|quantum" -i mix.exs` → **zero matches**. `deps/0` (lines
32-43) lists exactly: `ecto_sql`, `postgrex`, `plug`, `bandit`, `jason`,
`stream_data` (test-only), `ueberauth_oidcc`, `lua`, `wasmex`. No job-queue
or scheduling library of any kind.

**Verdict: CONFIRMED.**

## 5. §3 REVIEWER sign-off presence

§3 of the design artefact contains a fully written, non-placeholder
sign-off block: "**REVIEWER sign-off:** ✅ **RECORDED, 2026-08-29,
WF02-REQ185-20260829 Step 2d.**" followed by a multi-paragraph reasoned
sign-off (agreement with grounds 1/3/4, a caveat on ground 2, a
supervision-idiom check, and a decision-record-consistency confirmation) —
not a "PENDING" placeholder. The §9 summary table's row 2 reads "REVIEWER
sign-off **RECORDED** (2026-08-29, agree)", consistent with §3.

**Verdict: CONFIRMED** — genuine sign-off present and correctly reflected in
the summary table.

## Overall result

All 5 claims independently verified and CONFIRMED. No discrepancy found.
Routing to RELEASE-VALIDATOR (Step 5) per the Step 3 handoff's acceptance
criteria.
