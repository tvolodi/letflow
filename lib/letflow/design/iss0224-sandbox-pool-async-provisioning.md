# Design: ISS-0224 — `Letflow.SandboxPool` provisioning must not block the pool's mailbox

**Run:** `WF03-ISS0224-20260822` (GH#457, queue task 224) · **Author:** CODE-DESIGNER ·
**Status:** proposed — **REWORK ROUND 2** applied 2026-08-22, awaiting CODE-DESIGN-VALIDATOR

> **ISS-0227 (2026-08-22):** §5's `provision_op()` no longer carries `owner_pid` and its
> `in_flight()` record no longer carries `schema_name` — both were write-only. **§17 is
> authoritative for those two fields;** §5 and §7 step 2 are marked in place and otherwise left
> as the historical record. Nothing else in this document is affected.

> ## REWORK NOTICE — round 1 (2026-08-22)
>
> CODE-DESIGN-VALIDATOR returned FAIL with six findings. F1 and F2 were required to be
> settled by measurement, not re-wording. Both were reproduced first-hand before anything
> was changed, and both **refuted a load-bearing claim of round 0**. The design changed in
> substance as a result — this is not a wording pass.
>
> | # | Finding | Round-0 claim | Round-1 outcome |
> |---|---|---|---|
> | **F1** | The pool process is a *third* concurrent DB actor | "peak demand 2, exactly today's" | **REFUTED.** Real peak was **3**; round 0 regressed at `pool_size == 2`. **Fixed by design change**, not by disclosure: all `Repo` work now runs in one serialized worker (§4). Peak is back to 2, **verified 4/4 at `pool_size = 2`** (§3.7) |
> | **F2** | RT-2(c) does not fail pre-fix | "(c) ✗ FAILS, immune to timing noise" | **REFUTED.** (c) held 3/20 in my run, 5/20 in the validator's — a biased coin flip. **(c) is deleted**; (d) is the load-bearing fail-first (0/20 pre-fix, 20/20 post-fix); **new RT-7 added** as a second, far-stronger fail-first (§10.3) |
> | **F3** | Supervisor child ordering | "immediately **after** `PluginTaskSupervisor`" | **CORRECTED** — must be **before** `{Letflow.SandboxPool, []}` (§6.6) |
> | **F4** | Two `handle_info` clauses cannot be distinguished by pattern match | steps 2 and 4 written separately | **CORRECTED** — one clause, body-level branch (§7 step 3) |
> | **F5** | Cited provisioning minimum wrong | "446 ms, 2.2×" | **CORRECTED** — 411 ms, **2.06×** (§10.4) |
> | **F6** | Decision 0009 never named | cited only as "V11" | **CORRECTED** and, better, **the floor of 2 is now shown adequate** (§3.7, §14 OQ-6) |
>
> Also applied: §7 step 5's "every event that calls it frees exactly one slot" wording fix.
> Nothing the validator cleared was re-litigated; §16 lists what was left untouched.

> ## REWORK NOTICE — round 2 (2026-08-22)
>
> CODE-DESIGN-VALIDATOR returned FAIL with three findings. It **confirmed all three of round 1's
> headline claims by independent measurement** — peak DB demand 2 at `pool_size=2` (5/5 pass
> serialized vs 3/3 fail with round 0's shape), RT-2's surviving magnitude assertion and RT-7
> both 0/20 and 15/15-impossible pre-fix and 20/20 post-fix with waiter overshoot 1–3 ms, and
> decision 0009's floor of 2 adequate for the pool. **The F1 fix itself is therefore correct and
> was not redesigned.** What round 2 fixes is a hazard that fix *created*, plus two
> documentation-integrity defects.
>
> | # | Finding | Round-1 state | Round-2 outcome |
> |---|---|---|---|
> | **R2-F1** (MAJOR) | Fixing F1 created an unhandled death-path interleaving, and made INV-SP-A3 false | §7 step 2 copies `owner_ref` into the `{:drop, purpose: :release}` op **and** retains the `active` entry, so for 441–625 ms one ref is in both. An owner dying in that window missed clause B cases 1–4 and fell through to case 5, which deleted `active`, freed the slot and enqueued a **second** drop — contradicting §2.2/INV-SP-5, §7's `:release_failed` branch and §5's `db_queue` bound | **FIXED IN THE DESIGN, not disclosed.** New clause B **case 4b**, ordered before case 5 (§7 step 3): demonitor, delete the `active` entry in that same callback, and **rewrite the already-scheduled op in place** to `purpose: :release_orphaned` (`from: nil`, `owner_ref: nil`) — no second drop, no reply to a dead caller. INV-SP-A3 **restated** as ordered classification with the one enumerated overlap; the proof went from four points to five. INV-SP-5 restated with its live-owner precondition and **reconciled** with INV-SP-DOWN-3 (§8.2 — they are two halves of one rule, selected by whether the owner is alive; they never both apply). INV-SP-A4 gains fifth death path **(e)**. §5's bound corrected to an in-contract `2 × max_concurrent`. §4.4 **(I)** records the demonitor-at-enqueue alternative as **REJECTED** with its reason (permanent slot leak on the failed-DROP path — `sandbox_pool.ex:253-254`). New regression case **RT-8** |
> | **R2-F2** (MODERATE) | RT-2's assertions were silently re-lettered and the document contradicted itself | Round 1 deleted (c) and promoted (d) into the (c) slot without re-lettering the summaries; §10.3's table had no row (d), while `:16` said "(c) is deleted" and `:1180` told TEST-DESIGNER to implement "RT-2(c)". The load-bearing row also mistyped its own reason as `2·t_w1 < t_w1` | **FIXED.** The survivor is **(d)** everywhere; (c) is kept as an explicit struck-through **deleted** row in the table so the audit trail lives in the table, not only in prose; the typo now reads `2·t_w2 < t_w1`. Every reference updated in one pass (§10.3, §10.4, §15, §16, this notice) |
> | **R2-F3** (MINOR) | RT-7 was a mandatory fail-first with no vacuity guard while its sibling RT-2 had one | RT-7's ratio `4·t_probe < t_b` goes green pre-fix on any host provisioning under 80 ms, silently | **FIXED.** RT-7 gains premise **(a)** `t_b >= 200` else `flunk/1`, the same shape and the **same** 200 ms floor as RT-2(a) — **no new constant**; the count in §10.4 is still zero. RT-7's rows were re-lettered (a→b, b→**c**) and the re-lettering is stated in the block itself and applied everywhere, per R2-F2's lesson. §10.4 now names **both** guards |
>
> Also applied: the validator's round-2 150-sample window (min 423 ms) added to §10.4's table
> (six windows now); §11 gains items 16–18 fencing the case-4b decision. §16's round-2 section
> lists what the validator cleared and this round therefore did not touch.

**Verdict up front (unchanged in round 2):** the fix is **NOT BLOCKED**, and after F1's correction it no longer
regresses at `TEST_MIN_POOL_SIZE = 2` — the configuration whose reachability was used to
reject the alternative in round 0. Peak DB-connection demand is **2, the same as today**,
and that is measured (§3.7), not asserted. No new constant is introduced anywhere,
including in the regression-test contract.

---

## 0. Sources, and which factual premises this design verified first-hand

### 0.1 Read in full

| Source | Why |
|---|---|
| `lib/letflow/sandbox_pool.ex` (421 lines) | the module under change; every line number cited was re-read at `HEAD` of `fix/WF03-ISS0224-20260822` |
| `test/letflow/sandbox_pool_test.exs` (476 lines) | the coverage this design must not weaken |
| `test/letflow/sandbox_pool_call_timeout_test.exs` (163 lines) | ISS-0220's regression contract; the fail-first conventions §10 follows |
| `test/support/data_case.ex` (24 lines) | `{:shared, self()}` for non-async cases |
| `test/test_helper.exs` | V6 — it does **not** set `:manual` |
| `lib/letflow/application.ex` | F3; child ordering is load-bearing |
| `scratch/iss0224_validator_probe_release_during_provision.exs` | the validator's F1 probe, read in full before re-running it |
| `scratch/iss0224_validator_probe_rt2_ordering.exs` | the validator's F2 probe, read in full before re-running it |
| `docs/agents/instructions/core-directives.md` | mandatory |
| `docs/anti-patterns.md` (index + the three entries relied on) | mandatory |

### 0.2 Read in the named scope

- `req039-…md` §4.2, §4.3, §4.4, §4.5, §4.7 (INV-SP-1..7), §11 (OQ-2, OQ-3, OQ-4).
- `iss-0048-…md` §3, §5.1–§5.5, §6 (INV-SP-DOWN-1..5), §8, §13.
- `iss0220-…md` §3.2, §9 (INV-SP-T1..T5), §12, §16.
- `promotion_assertion_rerun_test.exs` moduledoc in full + every `:sys.get_state/1` site.
- `lib/letflow/definitions.ex` `:1466-1500`, `:1591`, `:1633`, `:1818-1826`.
- **`docs/migration/decisions/0009-test-parallel-pool-sizing.md`** (F6) — `:38`, `:59-90`.
- `config/test.exs`; `scripts/test_parallel.sh` `:105-145`; `mix.exs` `:60-70`.
- `deps/db_connection/.../ownership.ex` `:55-90`, `.../ownership/manager.ex` `:205-240`, `:400-430`.
- `deps/ecto_sql/lib/ecto/adapters/postgres.ex` `:306-345`.

### 0.3 The eleven hazards this design was dispatched to settle

| # | Hazard | Settled in |
|---|---|---|
| 1 | slot bookkeeping across an asynchronous completion | §5, §6.1, INV-SP-A1 |
| 2 | owner dies **during** provisioning, before `owner_ref` exists today | §7 step 3 case 2, §7 step 2, INV-SP-A4 |
| 3 | three classes of monitor ref at `handle_info({:DOWN, …})` | §7 step 3, INV-SP-A3 |
| 4 | `from` held across callbacks | §6.4, INV-SP-A2 |
| 5 | monitor the caller, never the worker, for ownership | §6.5, INV-SP-A4 |
| 6 | INV-SP-1 preserved or weakened? | §8.1 — **preserved as written** |
| 7 | INV-SP-T4; `release_call_timeout/0`; ISS-0220 §16 OQ-3 | §8.3 |
| 8 | DB-connection hazard **(both halves — the Tasks *and* the pool process, F1)** | §3 |
| 9 | `promotion_assertion_rerun_test`'s `:sys.get_state/1` technique | §9 |
| 10 | `drop_schema/1` in or out of scope | §2.3 — **IN**, reversed in round 1, forced by F1 |
| 11 | no new constant unless derived and window-stable | §10.4 — **zero** |

### 0.4 Premises verified first-hand (V-numbers referenced throughout)

Required by `core-directives.md` §"Instruction Precedence" ("this chain governs what you are
told to DO, not what you are told IS TRUE") and `docs/anti-patterns.md`'s "Inheriting a claim
from a record instead of re-deriving it from the source". **This applies to the validator's
findings exactly as it applied to the handoff's diagnosis:** F1 and F2 were reproduced here
before being acted on.

| V | Premise | Status |
|---|---|---|
| V1 | Exactly two synchronous provisioning sites: `handle_provision_now/2` (`:297-313`) and `service_next_waiter/1` (`:332-359`) | VERIFIED (read) |
| V2 | While one runs, the pool processes no messages, including `{:claim_timeout, _}` (`:260`) | VERIFIED (read + measured) |
| V3 | The overshoot equals one provisioning | VERIFIED (measured, §1.2) |
| V4 | `max_wait_ms` is documented as bounding queue parking only | VERIFIED (read) — `:184`, `:53-55`, `req039-…md` §4.4 step 3 |
| V5 | Provisioning works **only** under Sandbox `:auto`; it already fails under `{:shared, _}` and `:manual` | VERIFIED (measured, §3.2) |
| V6 | `test_helper.exs` does not set `:manual`; mode reverts to `:manual` when a shared owner exits (`manager.ex:402-404`) | VERIFIED (read) |
| V7 | Every test that claims a sandbox switches to `:auto` first | VERIFIED (read) |
| V8 | The migration lock is `:table_lock` on `"<prefix>"."schema_migrations"` — per-sandbox, no cross-sandbox coupling | VERIFIED (read + grep of `config/`) |
| V9 | `Definitions` has no `Task.async`/`spawn` around any claim/release pair; `:1495` matches exactly `[:sandbox_unavailable, :provision_failed]` | VERIFIED (read, re-derived this run) |
| V10 | `application.ex` already supervises a named `Task.Supervisor` (`:26`) | VERIFIED (read) |
| V11 | `config/test.exs` pins the singleton to `max_concurrent_sandboxes: 1`; `scripts/test_parallel.sh` clamps to `TEST_MIN_POOL_SIZE` = 2, per **decision 0009** | VERIFIED (read) |
| **V12** | **F1: the pool process running `drop_schema/1` while a provisioning Task is in flight is a third concurrent checkout. Round 0's design fails at `pool_size = 2`** | **VERIFIED (measured, §3.6)** — re-ran the validator's probe: `pool_size=2` → provisioning `DBConnection.ConnectionError`; `pool_size=3` → both succeed |
| **V13** | **F2: RT-2(c) ("first reporter is `:w2`") does NOT fail pre-fix** | **VERIFIED (measured, §10.3)** — 3/20 in my run against the shipped pool; 5/20 in the validator's. Also confirms `t_w2 == t_w1` exactly in 20/20 |
| **V14** | **F3: `{Letflow.SandboxPool, []}` is at `application.ex:25`, `PluginTaskSupervisor` at `:26` — so "after" would start the supervisor after its dependant** | **VERIFIED (read)** |
| **V15** | **F4: `mix letflow.check` runs `compile --warnings-as-errors` (`mix.exs:67`)**, so an unreachable clause is a red build, not a warning | **VERIFIED (read)** |
| **V16** | **F1's fix works: with all `Repo` work serialized in one worker, a release arriving during a provisioning succeeds at `pool_size = 2`** | **VERIFIED (measured, 4/4, §3.7)** |
| **V17** | Today's shipped code **already** fails at `pool_size = 2` when the calling process holds an `:auto` checkout (`probe3 sync 1` → `ConnectionError`) — a pre-existing marginality of `sandbox_pool_test.exs`, not introduced here | **VERIFIED (measured, §3.8)** |

**Premise NOT verified, and named:** ISS-0220's 15 373 ms loaded-host provisioning
(`iss0220-…md` §4.1 sample A, itself flagged in that document's §16 OQ-1). Cited only as an
upper witness; nothing here is sized from it. **Also not re-derived by me:** ISSUE-FIXER's
411 ms project-wide minimum provisioning (§10.4) — attributed, with my own independent
figures alongside it.

---

## 1. The defect, re-derived from source and re-measured

### 1.1 The mechanism

`handle_call({:claim, max_wait_ms}, from, state)` (`:232`) dispatches to
`handle_provision_now/2` (`:297`), which calls `provision_sandbox/0` (`:383`) — a
`CREATE SCHEMA` plus a replay of 31 migrations — **inside the pool's own callback**.
`service_next_waiter/1` (`:338`) does the same. A GenServer executing a callback processes
no other message, so for the whole duration of a provisioning the pool's mailbox is frozen,
including a parked waiter's own `Process.send_after`-scheduled `{:claim_timeout, _}` (`:323`).

`claim/2`'s `@doc` (`:184`), the moduledoc's "Two budgets" section (`:53-55`) and
`req039-…md` §4.4 step 3 all say `max_wait_ms` bounds queue parking. None says "plus one
provisioning". **This is a documented-contract violation** (V4), at any magnitude.

### 1.2 Re-measured, in this worktree, on a quiet host

`MIX_ENV=test mix run scratch/iss0224_repro.exs 200 100` — a **second independent sample
window** from the handoff's (different day, and the sibling `test_parallel.sh` run that had
been holding 88 of this Postgres instance's 100 connections had drained; checked via
`pg_stat_activity` first).

| `max_wait_ms` | CONTROL overshoot | DEFECT overshoot | W1 provisioning |
|---|---|---|---|
| 200 | +7, +14, +12 ms | **+262, +259, +254, +279, +246 ms** | 446–479 ms |
| 100 | +16, +11, +8 ms | **+347, +413, +369, +527, +528 ms** | 447–628 ms |

V13's 20-run probe independently confirms the mechanism at its sharpest: **`t_w2 == t_w1`
to the millisecond in 20/20 runs** (495/495, 480/480, 543/543, …). W2's reply is gated on
W1's provisioning, not on W2's own timer.

### 1.3 The honest magnitude statement

**The overshoot is bounded by exactly one provisioning, and one provisioning is host- and
load-dependent.** Measured here: 416–1015 ms across ~155 first-hand samples (§10.4);
735–1460 ms on this host under a concurrent 4-partition suite; 15 373 ms reported under
ISS-0220's observed contention (not re-verified, §0.4).

**The handoff's 1000 ms row is a real negative result and is restated as such:** at
`max_wait_ms: 1000` on a quiet host there is no violation, because one provisioning fits
inside the window. This design does **not** claim the defect is always large. It claims the
overshoot is **unbounded by anything the contract names** — not `max_wait_ms`, not
`provision_timeout_ms/0` (a caller-side allowance that aborts nothing, `iss0220-…md` §5.3),
not anything else in the module. That is what makes it a contract violation regardless of
magnitude.

---

## 2. Scope boundary

### 2.1 In scope

- Moving **all** `Repo` work — provisioning **and** `drop_schema/1` — out of the pool's
  callbacks into a single serialized worker Task. (`drop_schema/1` was out of scope in
  round 0; F1 forced the reversal — §2.3.)
- The slot-reservation bookkeeping an asynchronous completion requires.
- Establishing the owner monitor **before** provisioning starts.
- The multi-way `:DOWN` dispatch (six live cases plus a no-op — §7 step 3 clause B).
- One new child in `lib/letflow/application.ex`, ordered **before** the pool (F3).

### 2.2 Explicitly NOT in scope

- `provision_timeout_ms/0`'s value (44 000 ms), `claim_call_timeout/1`,
  `release_call_timeout/0` — untouched (§8.3 argues the last at length).
- `max_wait_ms`'s meaning — unchanged; INV-SP-T5 holds verbatim.
- `claim/2`'s and `release/2`'s public `@spec`s, arities and error taxonomy — unchanged
  (§6.1, V9).
- **`release/2`'s return contract** — unchanged: it still replies only once the DROP has
  resolved, still reports `:ok` vs `{:error, :release_failed}`, and still retains the `active`
  entry on failure **while the owner is alive**. Only *where the DROP executes* changes (§2.3).

  *The "while the owner is alive" qualifier was added in round 2 (F1). It is not a change to
  the contract — `sandbox_pool.ex:248` vs `:253-254` already behaves exactly this way, and a
  dead owner has no contract left to observe. Round 1 stated the retention unconditionally,
  which was simply inaccurate for the dead-owner path. Full reconciliation with
  INV-SP-DOWN-3 in §8.2's INV-SP-5 entry.*
- `FixtureLoader`, `Letflow.Definitions`, any migration, any config file, any HTTP route.

### 2.3 `drop_schema/1` — **IN** scope (round 1 reversal, forced by F1)

**Round 0 put it out of scope. That was wrong, and F1 is why.**

Round 0 reasoned that `drop_schema/1` is two orders of magnitude cheaper than a provisioning
and that moving it would change `release/2`'s contract. The first half is true and
irrelevant; the second half confused two different things. What F1 exposed is a **connection**
problem, not a latency problem:

With provisioning in a Task and `drop_schema/1` still in a pool callback, three DB actors can
be live at once — the worker Task (1 checkout), `Ecto.Migrator`'s inner `Task.async` (1), and
the pool process running `Repo.query!` (1). **Peak 3, where today's fully-synchronous pool
peaks at 2** (V12, measured). Round 0's own §3.4 rejected the concurrent-provisioning
alternative *because its failure was reachable at decision 0009's `TEST_MIN_POOL_SIZE` floor
of 2* — and then shipped a design that fails at exactly that floor. The validator's fourth
consequence is correct and is the sharpest point in the review.

**The contract objection does not apply to the fix.** Moving the DROP into the serialized
worker does **not** make `release/2` fire-and-forget. The caller still blocks in
`GenServer.call/3`; the reply is issued via `GenServer.reply/2` once the DROP's real outcome
is known; `:ok` vs `{:error, :release_failed}` is unchanged; INV-SP-5's retain-on-failure is
unchanged. Only the *latency* moves, and §4.2 shows it does not even move much.

**Decision: all pool-side `Repo` calls move into the worker.** Peak demand returns to 2 —
**measured 4/4 at `pool_size = 2`** (V16, §3.7). This is the decision F1 asked for, taken
rather than deferred, and it is not a BLOCKED outcome.

**A bonus this buys, not a side effect to gloss over:** with no `Repo` call left in any pool
callback, INV-SP-T4a becomes a clean guarantee instead of the hedged one round 0 wrote, and
F1's 5576 ms residual disappears entirely. Post-fix waiter overshoot is measured at **1–3 ms**
(§10.3), against 20–687 ms if the DROP had stayed in the callback.

---

## 3. Hazard 8 — the DB-connection question, measured first-hand

### 3.1 What the source says

`ownership/manager.ex:215-238`: `:auto` gives each process its own proxy;
`{:shared, owner}` redirects every other process to the owner's single proxy; `:manual`
searches `$callers` and otherwise refuses. `Task.async/1` and
`Task.Supervisor.async_nolink/3` both propagate `$callers`.

### 3.2 Mode compatibility (unchanged from round 0; validator confirmed)

`scratch/iss0224_dbconn_probe.exs`, `pool_size = 32`:

| mode | `sync` (today) | `task` | `tasksup` |
|---|---|---|---|
| `:auto` | **OK** (1460 ms) | **OK** (949 ms) | **OK** (1051 ms) |
| `{:shared, owner}` | FAIL `ConnectionError` | FAIL, *same* | FAIL, *same* |
| `:manual` | FAIL `OwnershipError` | FAIL, *same* | FAIL, *same* |

`probe2` adds `:manual` with the pool explicitly `allow`-ed: `sync` and `task` both fail
identically. **`:auto` is the only mode provisioning works in at all, before or after** (V5,
V7) — which is why every test that claims a sandbox switches to it.

### 3.3 One provisioning costs 2 checkouts, in either shape

Round 0's first probe reported a spurious `sync` OK / `task` FAIL at `pool_size = 2`; that
was an ordering artefact (the script process held a checkout by then) — the class
`docs/anti-patterns.md`'s "Re-deriving the count while inheriting the unit being counted"
describes. `scratch/iss0224_dbconn_probe3.exs` isolates it, one shape per OS process:

| `pool_size` | holders | `sync` | `task` |
|---|---|---|---|
| 2 | 0 | **OK** (735 ms) | **OK** (958 ms) |
| 2 | 1 | FAIL | FAIL, *same* |

Symmetric. One provisioning = 2 checkouts (its own + `Ecto.Migrator`'s inner `Task.async`),
in either shape. Validator confirmed.

### 3.4 Concurrent provisioning deadlocks — the rule that rejects unbounded concurrency

`probe3 many<N>`, `:auto`, no holders:

| N | `pool_size` | result |
|---|---|---|
| 3 | 3 | **0/3 — `ConnectionError` after 5 879 ms** |
| 3 | 4 | 3/3 OK, 1 345 ms |
| 5 | 5 | **0/5 — `ConnectionError` after 5 804 ms** |
| 5 | 6 | 5/5 OK, 2 463 ms |

*P* concurrent provisionings need `pool_size ≥ P + 1`; at exactly *P* it **deadlocks** (all
*P* outer Tasks hold all *P* connections; no inner `Task.async` can ever check one out).
Verified at two independent values of N, and independently reproduced by the validator.

### 3.5 F1 — the third actor round 0 missed

Round 0 applied §3.4's rule to the Tasks and forgot the pool process. With `drop_schema/1`
still in `handle_call({:release, …})` (`:246`) and in the `:DOWN` reclaim branch (`:283`),
the pool issues its own `Repo.query!` **while the worker holds its two checkouts**.

Re-ran the validator's probe (`scratch/iss0224_validator_probe_release_during_provision.exs`),
read in full first:

```
RESULT pool_size=2
  release-during-provisioning : {:ok, 3}  (wall 3 ms)
  provisioning                : {:error, {:provision, DBConnection.ConnectionError, ...}}

RESULT pool_size=3
  release-during-provisioning : {:ok, 4}
  provisioning                : {:ok, "sandbox_141c3c70..."}
```

**V12 confirmed.** Round 0's peak was **3**, not 2, and it fails at `pool_size = 2`. The
validator also observed the mirror-image race — a single `drop_schema/1` taking **5576 ms**
while it waited for a connection — which refutes round 0's INV-SP-T4a residual wording
("one `drop_schema/1`, 20–498 ms typical, 687 ms worst") a second, independent way.

Round 0's §3.5 ("holds connection demand at exactly today's two") and §4.1's table row
("**2, exactly today's**") are **withdrawn**.

### 3.6 The corrected design's demand — measured, not asserted

With every `Repo` call serialized in one worker, at most one DB operation is ever in flight:
a provisioning (2 checkouts) or a DROP (1). Peak = **2**, exactly today's.

`scratch/iss0224_serializer_prototype.exs f1` runs F1's exact scenario against a prototype of
the corrected design — A holds a claim, B's provisioning is in flight, A releases mid-flight:

| run | `pool_size` | A's release | B's provisioning |
|---|---|---|---|
| 1 | 2 | **`:ok`** (563 ms) | **`{:ok, …}`** (549 ms) |
| 2 | 2 | **`:ok`** (528 ms) | **`{:ok, …}`** (514 ms) |
| 3 | 2 | **`:ok`** (601 ms) | **`{:ok, …}`** (587 ms) |
| 4 | 2 | **`:ok`** (441 ms) | **`{:ok, …}`** (429 ms) |

**4/4 at `pool_size = 2`**, where round 0's shape fails. V16. The release's wall time tracks
the provisioning's — it waited behind it in the worker queue, exactly as designed, and
§4.2 shows that is not a latency regression.

### 3.7 What the pool now requires, stated plainly

- **The pool itself needs `pool_size ≥ 2`** — identical to today, and identical to what
  `Ecto.Adapters.Postgres.lock_for_migrations/3` already enforces by raising at
  `pool_size == 1`.
- **Plus one per ambient `:auto` holder** in the same VM (probe3's `holders=1` row
  establishes additivity). This is unchanged from today.
- **Decision 0009's `TEST_MIN_POOL_SIZE` floor of 2 therefore remains adequate for the pool**
  (F6). §14 OQ-6 records the check; no decision record is invalidated and none is re-decided.

### 3.8 A pre-existing marginality, found while checking F1 — not introduced here

`sandbox_pool_test.exs`'s test process acquires its own `:auto` checkout the first time it
calls `schema_exists?/1`. Any *subsequent* `claim/2` in that test then needs 3 connections
against today's shipped code too. Measured (V17): `probe3 sync 1` at `pool_size = 2` →
`ConnectionError`, **against the shipped module**. So that file already needs
`pool_size ≥ 3` in its later assertions today. Reported as a finding (§13 item 5), **not**
attributed to this change — `core-directives.md` §"Failure Attribution Is Structural" route 3,
with the measurement as its evidence.

### 3.9 Verdict on hazard 8

**Not blocked.** Provisioning in a worker is safe under `:auto` (the only mode it works in at
all); it is exactly as broken as today under the other two; per-operation demand is unchanged;
and after §2.3's reversal, **peak concurrent demand is 2 — the same as today — measured at
decision 0009's floor**. The deadlock rule of §3.4 is what rules out the concurrent-provisioning
alternative, and the corrected design is not subject to it.

---

## 4. Decision: all DB work moves off the mailbox into one serialized worker

**Chosen shape.** The pool owns a FIFO queue of DB operations (`{:provision, …}` and
`{:drop, …}`) and runs **exactly one at a time** in a `Task.Supervisor.async_nolink/3`-spawned
worker. **No `Repo` call executes inside any pool callback.** A caller whose slot is reserved
but whose `:provision` op has not started waits in that queue.

### 4.1 Why one serialized worker

| | (A) one serialized worker (**chosen**) | (A0) round 0: async provisioning, synchronous drops | (B) up to `max_concurrent` provisionings |
|---|---|---|---|
| Fixes the named defect | **yes** | yes | yes |
| Peak DB connections | **2 — today's** (V16, measured at `pool_size` 2) | **3** (V12, measured — fails at `pool_size` 2) | up to `2 × max_concurrent`; deadlocks at `pool_size ≤ max_concurrent` (§3.4) |
| Regresses at decision 0009's floor of 2 | **no** | **yes** | yes |
| `Repo` calls left in a pool callback | **none** | drops | drops |
| INV-SP-T4a | **clean guarantee** | hedged, and refuted at 5576 ms | hedged |
| New constant required | **none** | none | yes (a `pool_size`-derived cap) |
| Closes INV-SP-T4b (total latency) | no (§8.3) | no | yes |

**(A) is chosen.** (A0) is eliminated by F1. (B) is eliminated by §3.4's measured deadlock
plus the fact that it would need a new derived constant, while its only benefit — throughput
for a multi-slot pool — is unexercised by any current caller (V9).

**Two things (A) is not claimed to do:**

1. It does not make N claims complete in parallel. The *c*-th caller finding a free slot still
   waits ≈ *c* × provisioning. That is INV-SP-T4b, and §8.3 says explicitly it stays open.
2. It does not bound a *hung* provisioning. Nothing aborts one, before or after
   (`iss0220-…md` §5.3). INV-SP-A5 discloses this.

### 4.2 The one cost, and why it is not a regression

A `release/2` arriving while a provisioning is in flight now waits for that provisioning to
finish (measured: 441–601 ms, §3.6).

**Today it waits exactly as long** — the pool's mailbox is blocked by the same provisioning,
so the release message is not processed until it completes. The wait is *relocated* from the
mailbox to the work queue; it is not created. There is no latency regression.

And it is pre-authorised. `iss0220-…md` §3.2 sized `release_call_timeout/0` at
`provision_timeout_ms()` = 44 000 ms and said so in as many words: *"It is also already
correctly sized for the day provisioning stops blocking the pool's mailbox."* This is that
day. `sandbox_pool_test.exs`'s `pool_op_rendezvous_timeout()` (= 45 000 ms) covers it too.

### 4.3 Why (A) is behaviour-preserving for `claim(0, pool)`

A caller that finds a free slot while a provisioning is in flight is **not** rejected — it
reserves the slot and its `:provision` op queues. This is exactly today's behaviour: such a
caller currently just sits in the pool's *mailbox*. **The mailbox already is the queue**;
this design makes it explicit and stops it from also holding timer messages hostage.

So `claim(0, pool)` against a pool with a free slot still returns `{:ok, claim}`; against an
exhausted pool it still returns `{:error, :sandbox_unavailable}` immediately. INV-SP-T5 is
untouched and the three existing tests depending on it keep passing unchanged.

### 4.4 Rejected alternatives

- **(C) Keep provisioning synchronous but drain the timer queue first.** Impossible — a
  GenServer cannot peek past its own executing callback.
- **(D) Make provisioning fast enough not to matter.** The overshoot is a contract violation
  at any magnitude (§1.3), and 31 migrations is `req039-…md` §4.6's decision, not this
  design's to re-open.
- **(E) `Task.async/1` instead of `Task.Supervisor.async_nolink/3`.** It **links**, so a
  worker crash takes the pool down and strands every live claim. `async_nolink` gives the
  monitor without the link. Both measured working under `:auto` (§3.2); only the link differs.
- **(F) `Task.await/2` in a callback.** Blocks the mailbox — i.e. the defect. Named in §11
  because it is the likeliest way to appear to apply this fix while reverting it.
- **(G) `Task.shutdown/2` to abort a slow provisioning.** `Ecto.Migrator` runs with
  `timeout: :infinity` throughout (`iss0220-…md` §0 V4); killing mid-run abandons an open
  transaction and a half-migrated schema.
- **(H) Two workers — one for provisioning, one for drops.** Peak demand returns to 3, i.e.
  F1 again. Rejected for the same measurement (V12).
- **(I) REJECTED (round 2, F1): demonitor `owner_ref` when the release-drop is enqueued, and
  carry `owner_ref: nil` in the `{:drop, purpose: :release}` op.** This would make INV-SP-A3's
  at-most-one-collection property true again with no new clause-B case, which is exactly what
  makes it tempting. **It is wrong, and the shipped code says so.** `sandbox_pool.ex:248`
  demonitors **only** on the DROP's `:ok` path; `:253-254` replies `{:error, :release_failed}`
  and leaves the monitor deliberately live, so that a later death of that same owner still
  reaches `find_active_by_owner_ref/2` and triggers a reclaim retry. Cancelling the monitor at
  enqueue time removes the pool's only remaining handle on that owner: if the DROP then fails,
  the `active` entry is retained (INV-SP-5) with **no live monitor**, and nothing — not owner
  death, not anything else — can ever free that slot again. It converts a recoverable failure
  into a permanent slot leak. Recorded here so a future reader does not re-propose it as a
  simplification.

---

## 5. GenServer state shape

**Before** (`:228`):

```
%{
  max_concurrent: pos_integer(),
  active:  %{optional(sandbox_id :: String.t()) => %{schema_name: String.t(), owner_ref: reference()}},
  waiting: :queue.queue({from :: GenServer.from(), caller_ref :: reference(), timer_ref :: reference()})
}
```

**After** — two new fields; `active` and `waiting` are **unchanged** in key set and value
shape (this is what keeps §9's test techniques working):

```
%{
  max_concurrent: pos_integer(),

  active:  %{optional(sandbox_id :: String.t()) => %{
              schema_name: String.t(),
              owner_ref:   reference()
            }},                                        # UNCHANGED

  waiting: :queue.queue({from :: GenServer.from(),
                         caller_ref :: reference(),
                         timer_ref  :: reference()}),  # UNCHANGED

  db_queue:  :queue.queue(op()),                       # NEW -- pending DB work, FIFO
  in_flight: nil | in_flight()                         # NEW -- at most one
}
```

with

```
op() :: {:provision, provision_op()} | {:drop, drop_op()}

provision_op() :: %{
  from:        GenServer.from(),
  # owner_pid REMOVED by ISS-0227 (2026-08-22) -- write-only; derive as elem(p.from, 0). See §17.
  owner_ref:   reference(),
  sandbox_id:  String.t(),
  schema_name: String.t(),
  owner_down?: boolean()
}

drop_op() :: %{
  schema_name: String.t(),
  sandbox_id:  String.t(),
  from:        GenServer.from() | nil,   # nil on reclaim/orphan/release_orphaned paths
  owner_ref:   reference() | nil,
  purpose:     :release | :reclaim | :orphan | :release_orphaned
}

in_flight() :: %{
  op:          op(),
  task_ref:    reference(),
  task_pid:    pid()
  # schema_name REMOVED by ISS-0227 (2026-08-22) -- write-only; derive from in_flight.op
  #   ({:provision, %{schema_name: n}} | {:drop, %{schema_name: n}} -> n). See §17.
}
```

Field-by-field rationale:

- **`db_queue`** — one FIFO for both op kinds. A single queue (rather than a `reserved` queue
  plus a `pending_drops` queue) is what makes "at most one DB operation in flight" a
  structural property rather than an invariant to maintain across two structures, and FIFO
  ordering means a pending DROP always runs before a later provisioning, so the two never
  contend.

  **Bound, corrected in round 2 (F1).** Counting `db_queue` plus the one `in_flight` op:
  - `{:provision, _}` ops: **≤ `max_concurrent`**, because each one holds a slot and INV-SP-A1
    caps `slots_in_use/1` at `max_concurrent`.
  - `{:drop, _}` ops: **at most one per slot**, and therefore ≤ `max_concurrent`. Each of the
    four purposes is enqueued at a point that consumes the only thing that could produce
    another for the same slot: `:release` and `:reclaim` are the only two paths out of an
    `active` entry and both are reached from `Map.fetch(active, id)` / `find_active_by_owner_ref/2`
    on an entry that then stops being reachable as a *new* drop source (a released entry's
    second `release/2` is out of contract — see below; a reclaimed entry is deleted, so a
    later `release/2` returns `{:error, :not_found}` with no op); `:orphan` is enqueued only as
    a provision op is discarded; `:release_orphaned` is a **rewrite in place** of an existing
    `:release` op, never a new one.
  - Total, **within the moduledoc's same-process claim/release contract: ≤ `2 × max_concurrent`.**

  **Two things round 0/round 1 got wrong here, both fixed.** (i) Round 1's clause-B fall-through
  to case 5 could produce a *second* drop for one slot (`:release` still queued plus a new
  `:reclaim`), breaking this bound; §7 step 3's **case 4b** removes that path, which is what
  restores `2 × max_concurrent`. (ii) §6.4's benign duplicate — a second, **out-of-contract**
  process calling `release/2` for the same `sandbox_id` before the first DROP resolves — can
  still add one extra `{:drop, _}` per such caller. Those are bounded by the number of
  out-of-contract callers, **not** by `max_concurrent`, and the bound above is therefore stated
  as an in-contract bound. Each duplicate is idempotent (`DROP … IF EXISTS`, `Map.delete/2`)
  and self-clearing, so it is a bound question only, never a correctness one. No guard is
  added; see §6.4.
- **`in_flight`** — `nil` or exactly one record. `nil` is "idle"; there is nowhere to put a
  second operation, which is how the serialization is enforced.
- **`owner_ref`** — established at **reservation** time via `Process.monitor(owner_pid)`,
  strictly before any schema exists. This closes hazard 2's window: today the monitor is
  established only after a successful provisioning (`:300`, `:340`).
- **`sandbox_id` / `schema_name` in `provision_op()`** — **pre-minted by the pool** and
  passed into the worker. Not cosmetic: it is the only thing that lets the pool issue a
  compensating drop when the worker **crashes** without returning a value (§7 step 3 case 1).
  Without it, a crashed worker's half-created schema is unnameable and leaks permanently.
- **`task_ref` / `task_pid`** — the `async_nolink` monitor reference and pid. `task_ref` is
  the **only** place a worker reference is ever stored (INV-SP-A3).
- **`owner_down?`** — set when the owner's `:DOWN` arrives while its provisioning is still
  running. The worker is not killed (§4.4 (G)); its result is discarded and its schema
  enqueued for dropping.
- **`purpose`** — decides two things at completion, and nothing else: whether a reply is owed
  (`:release` only — the other three carry `from: nil`) and whether a **failed** DROP retains
  the `active` entry (`:release` only — see INV-SP-5 as restated in §8.2). `:release_orphaned`
  is the round-2 addition (F1): a `:release` op whose owner died while it was queued or in
  flight. It is produced **only** by §7 step 3 clause B case 4b rewriting an existing op in
  place — never enqueued fresh — and it is what makes case 4b resolve the death without a
  redundant second drop.

**Quota (hazard 1):**

```
provision_ops_pending(state) = count of {:provision, _} in :queue.to_list(state.db_queue)
                             + (1 if state.in_flight matches %{op: {:provision, _}})

slots_in_use(state) = map_size(state.active) + provision_ops_pending(state)
```

Every quota test becomes `slots_in_use(state) < state.max_concurrent`, replacing today's
`map_size(state.active) < state.max_concurrent` (`:233`). **The reservation is made before
provisioning starts and released on every failure path**, so N in-flight provisionings can
never all see the same free slot.

The `:queue.to_list/1` scan is the same "small bounded collection, scan it" idiom the module
already uses for `find_waiter/2` (`:361`) and `find_active_by_owner_ref/2` (`:372`), and
which `iss-0048-…md` §3 justified — preferred here over a separately-maintained counter,
which would be a second source of truth for the same fact.

---

## 6. Public interface and internal function signatures

### 6.1 Public API — no change whatsoever

```
@spec start_link(opts :: keyword()) :: GenServer.on_start()

@spec provision_timeout_ms() :: pos_integer()
@spec claim_call_timeout(max_wait_ms :: non_neg_integer()) :: pos_integer()
@spec release_call_timeout() :: pos_integer()

@spec claim(max_wait_ms :: non_neg_integer(), pool :: GenServer.server()) ::
        {:ok, SandboxClaim.t()}
        | {:error, :sandbox_unavailable}
        | {:error, :provision_failed}
        | {:error, term()}

@spec release(sandbox_id :: String.t(), pool :: GenServer.server()) ::
        :ok | {:error, :not_found} | {:error, :release_failed}
```

Byte-for-byte identical to the shipped module. Load-bearing, not incidental: V9 shows
`definitions.ex:1495` matches on exactly `[:sandbox_unavailable, :provision_failed]`.

**What changes without appearing in a `@spec`:** both the `{:claim, _}` immediate path and
the `{:release, _}` path now return `{:noreply, state}` and reply later via
`GenServer.reply/2`. From the caller's side `GenServer.call/3` is indistinguishable — same
blocking call, same return values, same timeouts. The module already uses this idiom for
queued waiters (`:325`, `:341`).

### 6.2 New and changed private functions

```
# Pool-side minting, moved out of provision_sandbox/0 so the pool knows the schema
# name before the worker exists (§5, §7 step 3 case 1). Same fixed construction as
# today: "sandbox_" <> Ecto.UUID.generate() with hyphens stripped.
@spec mint_sandbox_identity() :: {sandbox_id :: String.t(), schema_name :: String.t()}

# Runs INSIDE the worker Task. Body identical to today's provision_sandbox/0
# (:383-409) except that it no longer mints -- it receives the identity.
@spec provision_sandbox(sandbox_id :: String.t(), schema_name :: String.t()) ::
        {:ok, SandboxClaim.t()} | {:error, :provision_failed}

# Runs INSIDE the worker Task. Body unchanged from today's drop_schema/1
# (:415-420); only its execution context moves.
@spec drop_schema(schema_name :: String.t()) :: :ok | {:error, :release_failed}

@spec slots_in_use(state :: map()) :: non_neg_integer()
@spec provision_ops_pending(state :: map()) :: non_neg_integer()

# Monitors the caller, mints an identity, appends a {:provision, _} op. Never
# runs DB work; never replies.
@spec reserve_slot(from :: GenServer.from(), state :: map()) :: map()

@spec enqueue_op(state :: map(), op :: op()) :: map()

# If in_flight == nil and db_queue is non-empty: pops the head op and spawns the
# worker via Task.Supervisor.async_nolink/3. Otherwise returns state unchanged.
# Idempotent; safe to call after any state transition.
@spec pump(state :: map()) :: map()

# Applies a completed op's result to the state and replies where a `from` exists.
@spec complete_op(state :: map(), op :: op(), result :: term()) :: map()

# Same linear-scan idiom as find_waiter/2 and find_active_by_owner_ref/2.
@spec find_pending_provision_by_owner_ref(db_queue :: :queue.queue(), owner_ref :: reference()) ::
        provision_op() | nil

@spec remove_pending_provision_by_owner_ref(db_queue :: :queue.queue(), owner_ref :: reference()) ::
        :queue.queue()

# NEW IN ROUND 2 (F1). Searches BOTH state.db_queue AND state.in_flight.op for a
# {:drop, d} with d.purpose == :release and d.owner_ref == owner_ref. Returns which
# of the two holds it, so the caller (§7 step 3 clause B case 4b) knows whether to
# rewrite in_flight or to replace in place inside db_queue. At most one such op can
# exist (§5's bound).
@spec find_release_drop_by_owner_ref(state :: map(), owner_ref :: reference()) ::
        {:in_flight, drop_op()} | {:queued, drop_op()} | nil

# Replaces one op inside db_queue while PRESERVING ITS FIFO POSITION (a rebuild of
# the queue, not a remove-then-append -- reordering would let a later provisioning
# overtake a pending DROP, which §5's FIFO argument relies on not happening).
@spec replace_queued_op(db_queue :: :queue.queue(), old :: op(), new :: op()) ::
        :queue.queue()
```

Unchanged: `handle_queue_or_reject/3` (`:317-326`), `find_waiter/2`, `remove_waiter/2`,
`find_active_by_owner_ref/2`.

Deleted: `handle_provision_now/2` (`:297-313`).

Changed: `service_next_waiter/1` (`:332-359`) — now *promotes* the head waiter into a
reservation and returns; it no longer runs DB work or replies (§7 step 5).

### 6.3 Module attribute

```
@task_supervisor Letflow.SandboxPool.TaskSupervisor
```

A name, not a tunable — no number, nothing to derive. Not a "constant" in §10.4's sense.

### 6.4 `from` held across callbacks (hazard 4)

A `GenServer.from()` is `{pid(), tag :: term()}`, valid until replied to, from any callback.
This design holds one in an op record and replies exactly once, from exactly one of six
sites:

| where | reply |
|---|---|
| `complete_op` for `{:provision, _}` with `{:ok, claim}`, `owner_down? == false` | `{:ok, claim}` |
| `complete_op` for `{:provision, _}` with `{:error, :provision_failed}`, `owner_down? == false` | `{:error, :provision_failed}` |
| `:DOWN` for `in_flight.task_ref` during a `{:provision, _}`, `owner_down? == false` (`handle_worker_death/1`'s `{:provision, p}` clause) | `{:error, :provision_failed}` |
| `complete_op` for `{:drop, d}` with `:ok` or `{:error, :release_failed}`, when `d.from != nil` (the DROP worker *returned*) | `:ok` or `{:error, :release_failed}` |
| `:DOWN` for `in_flight.task_ref` during a `{:drop, d}` with `d.purpose == :release` (`handle_worker_death/1`'s `{:drop, d}` clause — the DROP worker *crashed*, distinct from the row above) | `{:error, :release_failed}` |
| `handle_info({:claim_timeout, caller_ref}, …)` (`:260`, unchanged) | `{:error, :sandbox_unavailable}` |

**Completeness verified against the implementation, not against this table**: every
`GenServer.reply/2` call site in `lib/letflow/sandbox_pool.ex` was located directly
(`grep -n "GenServer.reply" lib/letflow/sandbox_pool.ex`, 7 call sites) and each was
traced to the row above it belongs to. Two call sites collapse into row 4 (the `:ok`
and `{:error, :release_failed}` outcomes of the same `complete_op` drop-success clause);
the remaining five call sites are the other five distinct rows. No call site was found
outside these six rows.

When `owner_down? == true`, **no reply is sent** — the caller is dead. (`GenServer.reply/2`
to a dead pid is a harmless no-op, so this is a clarity choice; stated so an implementer does
not add one and a reviewer does not flag its absence.)

**The same rule on the release path (round 2, F1).** A `{:drop, purpose: :release}` op's `from`
is the release caller itself. If that caller dies before the DROP resolves, §7 step 3 clause B
case 4b sets `from: nil` (via `purpose: :release_orphaned`), so row 4 of the table above simply
does not fire. The op is still completed; only the reply is dropped. INV-SP-A2's stated
exception ("except when its owner has died") covers this without amendment — for a release,
the owner *is* the caller.

**A benign duplicate, named rather than guarded.** With the DROP deferred, a *second*
process could call `release/2` for the same `sandbox_id` before the first DROP completes,
find the entry still in `active`, and enqueue a second `{:drop, _}`. Both callers get a
reply; `DROP SCHEMA IF EXISTS` is idempotent and `Map.delete/2` is idempotent, so the outcome
is correct. It cannot arise within contract — the moduledoc's same-process claim/release
contract (`:33-46`) means the one legitimate releaser is blocked in its own `GenServer.call`
throughout. No guard is added; INV-SP-A2 is per-`from` and holds.

### 6.5 The pool monitors the caller, never the worker (hazard 5)

Two monitors exist per in-flight provisioning, meaning different things:

- **`owner_ref = Process.monitor(elem(from, 0))`** — the ownership monitor, on *whichever
  process called `claim/2`*, exactly as today (`:300`, `:340`), only earlier. This is what
  enforces the "Same-process claim/release contract" (moduledoc `:33-46`, `iss-0048-…md`
  §13), and this design does not touch that contract.
- **`task_ref`** — the worker monitor from `async_nolink`, solely to detect DB work that died
  without returning. **A worker's death never frees, transfers, or creates a claim.** The
  worker pid is never written into `active`, never becomes an `owner_ref`, never monitored as
  an owner.

An implementer who stored `Process.monitor(task.pid)` as `owner_ref` would build a pool that
reclaims every claim the instant its provisioning finishes. §11 names this.

### 6.6 The `Task.Supervisor` — placement is load-bearing (F3)

Add one child to `Letflow.Application.start/2`, **before** `{Letflow.SandboxPool, []}`:

```
{Task.Supervisor, name: Letflow.SandboxPool.TaskSupervisor},
{Letflow.SandboxPool, []},
{Task.Supervisor, name: Letflow.Engine.PluginTaskSupervisor},
```

**Round 0 said "immediately after `PluginTaskSupervisor`", which is wrong.** V14: the pool is
at `application.ex:25` and `PluginTaskSupervisor` at `:26`, so "after" starts the supervisor
*after the process that depends on it*. A `claim/2` arriving in that window makes
`async_nolink` exit `:noproc` inside a callback and kill the pool. `Supervisor` starts
children in list order, so the dependency must precede its dependant.

Rejected alternatives: a per-pool supervisor started from `init/1` (linked, started outside
the tree — an OTP smell, and `async_nolink` already isolates crashes); a `:task_supervisor`
option on `start_link/1` (speculative API with no caller — `iss-0048-…md` §13.1 point 1
applies the same reasoning). Test pools run inside the started application, so the named
supervisor is always available; `sandbox_pool_call_timeout_test.exs`'s black-hole pid never
reaches this code.

**Measured working:** §3.2's `tasksup` row is `async_nolink` under `:auto`, and §3.6's
prototype uses it throughout.

---

## 7. Algorithms (steps, not code)

### Step 1 — `handle_call({:claim, max_wait_ms}, from, state)`

```
IF slots_in_use(state) < state.max_concurrent
  state = reserve_slot(from, state)   # monitor owner, mint identity, enqueue {:provision, _}
  state = pump(state)                 # start the worker iff idle
  {:noreply, state}
ELSE
  handle_queue_or_reject(max_wait_ms, from, state)     # UNCHANGED (:317-326)
END
```

`reserve_slot/2`: `owner_pid = elem(from, 0)`; `owner_ref = Process.monitor(owner_pid)`;
`{sandbox_id, schema_name} = mint_sandbox_identity()`; enqueue
`{:provision, %{from:, owner_ref:, sandbox_id:, schema_name:, owner_down?: false}}`.
**`owner_pid` was removed from this literal by ISS-0227 (2026-08-22)** — see §17.

`pump/1`: if `in_flight != nil` or `db_queue` is empty, return unchanged. Otherwise pop the
head op and spawn `Task.Supervisor.async_nolink(@task_supervisor, …)` — running
`provision_sandbox(sandbox_id, schema_name)` for a `{:provision, _}` op, or
`drop_schema(schema_name)` for a `{:drop, _}` op — and set `in_flight`.

### Step 2 — `handle_call({:release, sandbox_id}, from, state)`

```
CASE Map.fetch(state.active, sandbox_id) OF
  :error ->
    {:reply, {:error, :not_found}, state}          # UNCHANGED, no DB work involved

  {:ok, %{schema_name: n, owner_ref: owner_ref}} ->
    op = {:drop, %{schema_name: n, sandbox_id: sandbox_id, from: from,
                   owner_ref: owner_ref, purpose: :release}}
    {:noreply, state |> enqueue_op(op) |> pump()}
END
```

The `active` entry is **retained** until the DROP's result is known — unchanged from today,
and what keeps INV-SP-5 and the quota correct (the slot is not reusable while a schema may
still exist).

**The `owner_ref` is deliberately copied, not moved (round 2, F1).** For the whole duration of
the DROP (measured 441–625 ms, §4.2) the *same* `reference()` is present in **two** places: this
op's `owner_ref` **and** the retained `active` entry's `owner_ref`. That is intentional, and it
is the one enumerated exception to INV-SP-A3 (§8.4). The monitor is **not** cancelled at
enqueue time, exactly as the shipped code does not cancel it on the `{:error, :release_failed}`
path (`sandbox_pool.ex:253-254` replies with the error and leaves the monitor live), so that a
later owner death still routes to a reclaim retry instead of stranding the slot.

**Consequence, handled in §7 step 3 clause B case 4b:** an owner that dies inside this window
would otherwise fall through to case 5 (the reclaim path), which would delete the `active`
entry and enqueue a **second** drop for the same schema. Case 4b exists to catch it first. See
§4.4 (I) for why the obvious alternative — demonitor at enqueue and set `owner_ref: nil` — is
rejected.

### Step 3 — `handle_info/2`, one clause per message *shape* (F4)

**F4 is a real compile-time hazard, not a style note.** V15: `mix letflow.check` runs
`compile --warnings-as-errors` (`mix.exs:67`). Round 0 wrote the worker-result handler and
the unknown-ref no-op as two clauses, but their discriminator is `state.in_flight.task_ref` —
unreachable from a head or guard. Written literally the second clause is unreachable, Elixir
warns, and the build goes red. **There must be exactly one clause per message shape, branching
in the body.**

**Clause A — `{ref, result} when is_reference(ref)`** (the worker returned):

```
IF state.in_flight == nil OR ref != state.in_flight.task_ref
  {:noreply, state}                    # unknown ref: no-op (unreachable by construction)
ELSE
  Process.demonitor(ref, [:flush])     # so a successful worker never also delivers :DOWN
  state = complete_op(state, state.in_flight.op, result)
  state = service_next_waiter(state)
  state = pump(state)
  {:noreply, state}
END
```

`complete_op/3`, by op kind:

```
{:provision, p}, {:ok, claim}, p.owner_down? == false ->
    active' = Map.put(state.active, claim.sandbox_id,
                      %{schema_name: claim.schema_name, owner_ref: p.owner_ref})
    GenServer.reply(p.from, {:ok, claim})
    in_flight: nil, active: active'          # slot converts; slots_in_use unchanged

{:provision, p}, {:ok, claim}, p.owner_down? == true ->
    # owner died mid-provisioning: a schema exists for a dead owner
    enqueue {:drop, %{schema_name: claim.schema_name, sandbox_id: p.sandbox_id,
                      from: nil, owner_ref: nil, purpose: :orphan}}
    in_flight: nil                            # slot freed; no reply
    # owner_ref was already demonitored in clause B case 2

{:provision, p}, {:error, :provision_failed}, owner_down? == false ->
    # the worker's own rescue already ran its compensating drop (:406), using the
    # worker's own checkout -- no extra connection, no extra op
    Process.demonitor(p.owner_ref, [:flush])
    GenServer.reply(p.from, {:error, :provision_failed})
    in_flight: nil                            # slot freed

{:provision, p}, {:error, :provision_failed}, owner_down? == true ->
    in_flight: nil                            # nothing created; no reply

{:drop, d}, :ok ->
    IF d.from != nil THEN                     # d.purpose == :release only
      Process.demonitor(d.owner_ref, [:flush])
      GenServer.reply(d.from, :ok)
    END
    in_flight: nil, active: Map.delete(state.active, d.sandbox_id)
    # Map.delete is idempotent -- on the :reclaim, :orphan and :release_orphaned
    # paths the entry is already absent

{:drop, d}, {:error, :release_failed} ->
    IF d.purpose == :release THEN             # implies d.from != nil, d.owner_ref != nil
      GenServer.reply(d.from, {:error, :release_failed})
      active entry RETAINED, monitor left LIVE
      # INV-SP-5 (§8.2, as restated in round 2): retention is a LIVE-OWNER guarantee.
      # The owner just received the error and may retry release/2; and if it dies
      # instead, its still-live owner_ref reaches clause B case 5 and the slot is
      # reclaimed. Matches sandbox_pool.ex:253-254 exactly.
    ELSE                                       # :reclaim | :orphan | :release_orphaned
      no reply (from == nil)
      active entry already absent -- deleted at :DOWN time, unconditionally
      # INV-SP-DOWN-3: with no live owner there is nobody to retry, so the slot is
      # never held hostage by a DROP that failed. The schema may leak; that trade is
      # ISS-0048's, made here identically (§8.2).
    END
    in_flight: nil
```

**Clause B — `{:DOWN, ref, :process, _pid, _reason}`**, **six-way** dispatch plus a no-op
(hazard 3; case 4b added in round 2). The first two checks are exact equality against
singly-stored references. The last three search collections that are disjoint **except for one
enumerated pairing** — a `{:drop, purpose: :release}` op's `owner_ref` and the retained `active`
entry it was copied from (§7 step 2) — which is why **the cases are ordered, not merely
disjoint**, and why case 4b must precede case 5. See INV-SP-A3(iii)–(iv).

```
CASE
  state.in_flight != nil and ref == state.in_flight.task_ref ->
      # (1) THE WORKER DIED without returning. Necessarily abnormal: a normal
      #     return is handled in clause A, which demonitors with [:flush] first.
      IF in_flight.op is {:provision, p} THEN
        drop_schema is NOT called inline -- enqueue
          {:drop, %{schema_name: p.schema_name, sandbox_id: p.sandbox_id,
                    from: nil, owner_ref: nil, purpose: :orphan}}
        # possible ONLY because the pool pre-minted the name (§5)
        IF not p.owner_down? THEN
          Process.demonitor(p.owner_ref, [:flush])
          GenServer.reply(p.from, {:error, :provision_failed})
        END
      ELSE  # in_flight.op is {:drop, d} -- the DROP itself died
        IF d.purpose == :release THEN
          GenServer.reply(d.from, {:error, :release_failed})
          active entry RETAINED, monitor left LIVE
        END
        # Exactly the same live-owner/dead-owner split as clause A's
        # {:error, :release_failed} branch, for the same reason (INV-SP-5 vs
        # INV-SP-DOWN-3, §8.2). On :reclaim / :orphan / :release_orphaned there is
        # no `from` to reply to and the entry is already absent.
      END
      in_flight: nil ; service_next_waiter ; pump

  state.in_flight != nil and in_flight.op is {:provision, p} and ref == p.owner_ref ->
      # (2) THE OWNER DIED WHILE ITS PROVISIONING IS RUNNING (hazard 2).
      #     Do NOT kill the worker (§4.4 (G)). Do NOT free the slot yet -- a schema
      #     is being created right now and must be dropped deterministically once
      #     its name is known.
      Process.demonitor(ref, [:flush])          # ref IS p.owner_ref here
      in_flight: %{in_flight | op: {:provision, %{p | owner_down?: true}}}
      # no reply, no other transition

  find_waiter(state.waiting, ref) != nil ->
      # (3) A PARKED WAITER DIED -- unchanged (:274-276), INV-SP-6
      Process.cancel_timer(timer_ref) ; waiting: remove_waiter(...)

  find_pending_provision_by_owner_ref(state.db_queue, ref) != nil ->
      # (4) NEW: an owner died while its {:provision, _} op was still QUEUED.
      #     No schema exists, so nothing to drop; just free the slot.
      db_queue: remove_pending_provision_by_owner_ref(...) ; service_next_waiter ; pump

  find_release_drop_by_owner_ref(state, ref) != nil ->
      # (4b) NEW IN ROUND 2 (F1): an owner died while ITS OWN {:drop, purpose: :release}
      #      op was still QUEUED or IN FLIGHT. Reachable: Definitions.safe_release/2
      #      calls release/2 from a `rescue` path (definitions.ex:1818-1826), and
      #      ISS-0048's existing test kills an owner outright.
      #
      #      MUST be evaluated BEFORE case 5. In this window `ref` is present in TWO
      #      places -- this op's owner_ref and the retained active entry's owner_ref
      #      (§7 step 2, INV-SP-A3(iii)) -- so case 5 would also match. Case 5 would
      #      delete the active entry AND enqueue a SECOND drop for the same schema.
      #
      #      Searches BOTH state.db_queue and state.in_flight.op for a {:drop, d} with
      #      d.purpose == :release and d.owner_ref == ref. At most one can exist
      #      (§5's bound), so no ambiguity.
      Process.demonitor(ref, [:flush])

      # (i) free the slot in THIS callback, exactly as case 5 does -- INV-SP-DOWN-2/3
      active: Map.delete(state.active, d.sandbox_id)

      # (ii) rewrite the op IN PLACE; do NOT enqueue a second drop
      d' = %{d | from: nil, owner_ref: nil, purpose: :release_orphaned}
      IF the op is in state.in_flight THEN
        in_flight: %{in_flight | op: {:drop, d'}}
        # Legal: in_flight.op is pool-local data. The worker holds only the
        # schema_name STRING and is unaffected; the rewrite changes only what
        # complete_op/3 does when the result arrives.
      ELSE
        db_queue: replace that op in place, PRESERVING ITS FIFO POSITION
      END

      # (iii) no reply: the owner is the blocked release/2 caller and it is dead
      #       (§6.4's "no reply to a dead caller" rule; INV-SP-A2's stated exception)
      service_next_waiter ; pump

  find_active_by_owner_ref(state.active, ref) != nil ->
      # (5) ISS-0048's dead-owner reclaim. Behaviour preserved, execution relocated:
      #     the active entry is removed IMMEDIATELY and unconditionally (INV-SP-DOWN-3
      #     -- the slot must not be held hostage by a DROP nobody can retry), and the
      #     DROP is enqueued rather than run inline.
      active: Map.delete(state.active, sandbox_id)
      enqueue {:drop, %{schema_name: n, sandbox_id: sandbox_id, from: nil,
                        owner_ref: nil, purpose: :reclaim}}
      service_next_waiter ; pump

  true ->
      # (6) unchanged no-op (:288-289)
      state
END
```

**Why case 4b rewrites rather than reclaims (round 2, F1 — the decision, taken here).**

Three candidate behaviours were considered for an owner dying on top of its own release-drop.

| candidate | outcome |
|---|---|
| **do nothing new** (round 1 as written: fall through to case 5) | `active` deleted, slot freed, **a second drop enqueued for the same schema**. Safe only by luck — `DROP … IF EXISTS`, `Map.delete/2` and `GenServer.reply/2`-to-a-dead-pid are all idempotent — while contradicting §2.2/INV-SP-5, §7's `:release_failed` branch and §5's `db_queue` bound. **Rejected: correct by accident is not a design.** |
| **rewrite the op, delete `active` only at completion** (the validator's suggested shape) | No duplicate drop, no contradiction. But the slot stays counted for the remaining drop duration (441–625 ms), which weakens INV-SP-DOWN-2's "the slot is freed in that same callback". |
| **rewrite the op AND delete `active` in the `:DOWN` callback — CHOSEN** | No duplicate drop, and the slot is freed in the same callback, so case 4b becomes *exactly* case 5 with one difference: the drop it needs is already scheduled, so it retargets that one instead of enqueuing another. INV-SP-DOWN-2 and INV-SP-DOWN-3 both hold verbatim, unweakened. |

The chosen shape is safe because deleting `active` frees only a **counter**, not a name: any
claim admitted into the freed slot mints a fresh globally-unique schema (INV-SP-4), and FIFO
ordering (§5) guarantees the pending DROP runs before that new provisioning. Nothing the freed
slot admits can collide with the schema still being dropped.

**Why a ref is always classified correctly (INV-SP-A3):**

1. `task_ref` is written to exactly one place, `state.in_flight.task_ref`, and never to
   `waiting`, `db_queue`, or `active`. It is also produced by `async_nolink`, never by
   `Process.monitor/1` on a caller, so it is disjoint from every owner/caller ref by origin.
2. A **provision** op's `owner_ref` lives in exactly one collection at a time. It moves out of
   `db_queue` and into `in_flight` atomically inside `pump/1`, and out of `in_flight` and into
   `active` atomically inside `complete_op/3`.
3. A waiter's `caller_ref` is demonitored-and-flushed and its timer cancelled at promotion
   (step 5), *before* a distinct `owner_ref` is established — the two never coexist.
4. Checks (1) and (2) — clause B cases 1 and 2 — are exact `==` against fields of one record,
   evaluated first, so no search can shadow them.
5. **A `{:drop, purpose: :release}` op's `owner_ref` is the one exception, and it is why the
   case ordering (not merely case disjointness) is load-bearing.** §7 step 2 **copies** the ref
   out of the `active` entry instead of moving it, and retains the entry, precisely so the
   monitor stays live across a failed DROP (§4.4 (I)). For that op's whole lifetime the same
   ref is therefore in **both** the op and the `active` entry, and **both** case 4b and case 5
   match it. Case 4b is ordered first, so the pairing always resolves to the op — the strictly
   more informative of the two, since it alone knows a drop is already scheduled. When the op
   resolves, `complete_op/3` sets `in_flight: nil` and (on the `:release` path) the entry and
   its ref are removed together; the pairing is bounded by exactly one op's duration and
   involves exactly one ref. Round 1 stated (2) unconditionally and therefore asserted
   something false; this is the corrected statement, and INV-SP-A3 in §8.4 matches it.

The validator independently checked points 1–4 of this proof, including that Erlang orders
`{ref, result}` before `{:DOWN, ref, …, :normal}` so clause A's flush is reliable, and found
them sound. Point 5 is new in round 2 and is the finding it raised as F1.

### Step 4 — `handle_info({:claim_timeout, caller_ref}, state)`

**Completely unchanged** (`:260-270`). It was always correct; it was only ever starved. That
is the whole point of this change.

### Step 5 — `service_next_waiter/1`, rewritten to *promote*

```
IF slots_in_use(state) >= state.max_concurrent -> state
ELSE CASE :queue.out(state.waiting) OF
  {{:value, {from, caller_ref, timer_ref}}, rest} ->
      Process.cancel_timer(timer_ref)
      Process.demonitor(caller_ref, [:flush])          # both UNCHANGED (:335-336)
      reserve_slot(from, %{state | waiting: rest})     # NEW owner_ref established here
      # does NOT run DB work and does NOT reply; the caller stays blocked in its
      # GenServer.call until step 3 clause A replies
  {:empty, _} -> state
END
```

It promotes **at most one** waiter per invocation, guarded by the `slots_in_use/1` test above
rather than by an assumption about the caller.

*(Round 0 justified this with "every event that calls it frees exactly one slot", which the
validator correctly flagged as inaccurate: the `{:provision, _}` success path frees none — the
reservation converts into an `active` entry. The guard is the real reason, and it is correct
in both cases; the claim has been removed rather than repaired.)*

---

## 8. Invariants

New invariants are prefixed `INV-SP-A*`, extending `req039-…md` §4.7, `iss-0048-…md` §6 and
`iss0220-…md` §9 without renumbering any of them.

### 8.1 INV-SP-1 — preserved as written (hazard 6)

INV-SP-1 says claim/release for any two `sandbox_id`s are never processed concurrently,
because both are calls against one singleton's mailbox — the property `req039-…md` §2.3 names
as the reason a process (not a row) was chosen.

**Verdict: PRESERVED, exactly as written.** The property it exists to guarantee is that
**pool-state mutation is serialized at one arbitration point**, so two callers racing for the
last free slot cannot both win. Under this design every read and write of `active`,
`db_queue`, `in_flight` and `waiting` still happens inside a pool callback; the worker mutates
**no pool state** (it receives strings and returns a result); and the slot decision and the
reservation that follows it happen in the *same* callback with no interleaving.

**What is new, stated rather than left implicit:** the *DDL side effects* of one operation now
overlap in wall-clock time with the pool processing other messages. This is safe because every
provisioning targets a freshly-minted, globally-unique `sandbox_<32 hex>` schema, every DROP
targets a schema no longer referenced, FIFO ordering means a queued DROP always precedes a
later provisioning, and V8 confirms `Ecto.Migrator`'s lock is per-prefix.

**INV-SP-1' (recorded so the old wording is not left silently asserting more than it should):**
*pool-state mutation for any two `sandbox_id`s is never concurrent (INV-SP-1 unchanged); at
most one DB operation executes at a time, and it may overlap pool-state mutation for others,
targeting a disjoint database object by construction.*

### 8.2 Invariants carried over

- **INV-SP-2** — strengthened by INV-SP-A1.
- **INV-SP-3** — held: the `active` insert happens only on `{:ok, claim}`.
- **INV-SP-4** (`schema_name` never caller-supplied where interpolated into DDL) — held.
  Minting moves from `provision_sandbox/0` into `mint_sandbox_identity/0`, still the fixed
  `"sandbox_" <> Ecto.UUID.generate()`-with-hyphens-stripped construction, still producing
  only `sandbox_[0-9a-f]{32}`, still never reading a caller value. The identifier-injection
  argument `tenant_provisioning.ex:111-122` documents (INV-7) is unaffected. **Stated for
  SECURITY-REVIEWER explicitly**, because minting changes location in this diff.
- **INV-SP-5** — held, with its **precondition made explicit in round 2 (F1)**. `release/2`
  still replies with the DROP's real outcome, and still retains the `active` entry on
  `{:error, :release_failed}` — **while the owner is alive** (§7 step 3, the `{:drop, d}`,
  `{:error, :release_failed}` branch).

  **The precondition is not a weakening; it is what the shipped code already does.** Retention
  exists for exactly one purpose: the owner has just been told `{:error, :release_failed}` and
  may retry `release/2`, and its monitor is deliberately left live
  (`sandbox_pool.ex:253-254`) so that if it dies instead, the reclaim path frees the slot
  anyway. Both halves of that rationale require a live owner.

  **Reconciliation with INV-SP-DOWN-3 ("never hold a slot hostage"), which round 1 left in
  genuine conflict on this path.** The two invariants are not competing rules over the same
  state; they are the two halves of one rule, selected by whether the owner is alive:

  | owner | governing invariant | behaviour on a failed DROP |
  |---|---|---|
  | **alive** | INV-SP-5 | `active` entry retained, monitor left live, error returned. There is a process that can retry, and a monitor that will catch it if it dies instead. Retention costs a slot only until one of those two happens. |
  | **dead** | INV-SP-DOWN-3 | `active` entry already deleted (at `:DOWN` time, by case 4b or case 5), slot already free, no reply. Retention would be indefinite — nobody can retry and no further `:DOWN` can arrive — i.e. the exact "slot held hostage" INV-SP-DOWN-3 forbids. |

  So the priority order is **INV-SP-DOWN-3 over INV-SP-5, and the two never both apply**: an
  owner is alive or it is not, and the `:DOWN` that changes the answer is also what deletes the
  entry. The residual is a **schema** leak on a dead-owner failed DROP, which is ISS-0048's
  existing, accepted trade (INV-SP-DOWN-3 makes it deliberately: slot before schema), made here
  identically rather than re-decided.

  **§2.2's unconditional wording is corrected to match** — it now reads "retains the `active`
  entry on failure **while the owner is alive**".
- **INV-SP-6** — held (step 3 clause B case 3), and cases 4 and 4b extend the same guarantee to
  a queued reservation and to a queued-or-in-flight release-drop.
- **INV-SP-7** — held; `start_link/1` untouched.
- **INV-SP-DOWN-1** — **strengthened**: every `active` claim, every queued reservation and
  every in-flight provisioning has a live `owner_ref`. No window remains in which a
  claim-in-progress has no owner monitor.
- **INV-SP-DOWN-2** — held: reclaim still happens within one message round-trip of the
  `:DOWN`; the slot is freed in that same callback. Only the DROP itself is enqueued. **Round 2
  (F1): case 4b holds it verbatim too** — it deletes the `active` entry in the `:DOWN` callback
  rather than deferring the deletion to the op's completion, which is why the chosen shape in
  §7 step 3's candidate table beat the alternative that deferred it.
- **INV-SP-DOWN-3** — held **explicitly and deliberately** on **both** dead-owner paths: the
  `active` entry is removed unconditionally at `:DOWN` time, before the DROP has run, so a DROP
  failure can never strand a slot. §7 step 3 clause B **case 5** (no drop scheduled yet — one
  is enqueued) and **case 4b** (a drop is already scheduled — it is retargeted, not
  duplicated). See the INV-SP-5 entry above for how the two invariants are ordered.
- **INV-SP-DOWN-4, DOWN-5** — held unchanged.
- **INV-SP-T1, T2, T3** — held; no timeout derivation is touched.
- **INV-SP-T5** — held; §4.3 argues why the queue does not disturb it.

### 8.3 INV-SP-T4 — split, one half now a clean guarantee (hazard 7)

`iss0220-…md` §9 states INV-SP-T4 as a **limit, not a guarantee**, and §12 explains it is
worded that way because of this defect.

- **INV-SP-T4a (NEW — a guarantee).** **No `Repo` call executes inside any
  `Letflow.SandboxPool` callback.** A parked waiter's `{:claim_timeout, caller_ref}` is
  therefore processed within one pool callback of its timer firing, and every pool callback is
  pure message handling plus small in-memory queue operations. `max_wait_ms` is a real bound,
  modulo BEAM scheduling.

  **Measured:** post-fix waiter overshoot **1–3 ms** across 20 runs (§10.3), against a pre-fix
  overshoot equal to one full provisioning (416–1015 ms).

  *Round 0 worded this as "the longest thing that can delay it is one `drop_schema/1`
  (20–498 ms typical, 687 ms worst)". F1 refuted that twice over — the DROP can itself take
  5576 ms while waiting for a connection. Rather than re-hedge the wording, §2.3's reversal
  removes the residual: there is no `drop_schema/1` in a callback any more.*

- **INV-SP-T4b (RETAINED as a limit — NOT closed).** Total `claim/2` latency for callers that
  each find a free slot is still not bounded by `claim_call_timeout(max_wait_ms)`: DB work is
  serialized at one operation in flight, so with `max_concurrent: c` and *c* simultaneous
  claims the *c*-th caller's latency still approaches *c* × provisioning. Those callers now
  sit in `db_queue` rather than the mailbox — more legible, not faster. §4.1 says why closing
  it was rejected; §14 OQ-1 records what would have to change.

**`release_call_timeout/0` — unchanged in this fix.**

`iss0220-…md` §16 OQ-3 anticipated this run: *"Once §12's successor issue removes head-of-line
blocking, the release path's real requirement collapses to just the DROP cost, and a much
smaller, independently derived number becomes correct."*

- **Does this design remove that blocking?** From the *mailbox*, yes, completely. But a
  release's DROP is now queued behind an in-flight provisioning (§4.2), so the release path's
  real requirement is still "one provisioning plus one DROP" — **not** the DROP alone. OQ-3's
  premise for shrinking the number is therefore **not** satisfied, and this is a stronger
  reason to leave it than round 0 had.
- **Should it shrink? No.** Four reasons: (i) OQ-3's premise is unmet, per the point above;
  (ii) independent revertability — a shrunken budget silently becomes wrong if this change is
  reverted; (iii) §3.2's present-tense justification is untouched — the budget exists because
  `Definitions.safe_release/2` (`definitions.ex:1818-1826`) contains release failures with
  `rescue`, and `rescue` cannot catch the `exit` a call timeout raises; (iv) blast radius —
  `sandbox_pool_test.exs` derives five rendezvous bounds from it (`iss0220-…md` §8.2).

  And it is already correctly sized for what this design does: §4.2 measured a
  release-behind-a-provisioning at 441–601 ms against a 44 000 ms budget.

**Required doc consistency:** `iss0220-…md` §12 and §16 OQ-3 gain a prose-only cross-reference
recording that ISS-0224 removed the mailbox blocking, that the release path's requirement is
now "one provisioning plus one DROP" rather than the DROP alone, and that the re-derivation
remains open. No number and no invariant in that document changes.

### 8.4 New invariants

- **INV-SP-A1 (reservation — hazard 1).**
  `slots_in_use(state) = map_size(active) + provision_ops_pending(state) <= max_concurrent`
  at every point between callbacks, and a slot is counted from the moment `reserve_slot/2`
  returns — **before** any DB work starts — until the `active` entry is deleted or the
  reservation is discarded on a failure path. No window exists in which a provisioning is in
  progress and its slot uncounted. Strictly stronger than INV-SP-2.
- **INV-SP-A2 (exactly-one-reply).** Every `from` accepted by a `handle_call/3` is replied to
  exactly once, from exactly one of §6.4's six sites — except when its owner has died, in
  which case it is deliberately not replied to at all. Per-`from`; §6.4's benign-duplicate
  case does not violate it.
- **INV-SP-A3 (ref classification is unambiguous — RESTATED IN ROUND 2, F1).**
  *Round 1 stated this as blanket disjointness — "a given `reference()` appears in at most one
  of `in_flight.task_ref`, an op's `owner_ref`, a `waiting` entry's `caller_ref`, an `active`
  entry's `owner_ref`". **That was false**, because §7 step 2 copies `owner_ref` into the
  `{:drop, purpose: :release}` op while retaining the `active` entry it came from. The
  invariant the design actually needs — and provably has — is not disjointness but
  determinacy of classification.* At any point between callbacks:
  - **(i)** `in_flight.task_ref` is disjoint from every owner/caller ref, by origin
    (`async_nolink` vs `Process.monitor/1`) and by storage (written to exactly one field).
  - **(ii)** A `waiting` entry's `caller_ref` never coexists with an `owner_ref` for the same
    claim: promotion demonitors-and-flushes it before `reserve_slot/2` establishes a new one.
  - **(iii)** An `owner_ref` appears in exactly one collection, **with one enumerated
    exception**: from `handle_call({:release, _})` until the resulting `{:drop, purpose:
    :release}` op completes, it is in **both** that op and the retained `active` entry. This
    is deliberate (§4.4 (I)), bounded by one op's duration, and involves at most one ref per
    slot (§5's bound).
  - **(iv)** Clause B's cases are therefore **ordered, not merely disjoint**. Cases 1 and 2 are
    exact `==` and run first; **case 4b runs before case 5**, so the one pairing in (iii)
    always resolves to the op; every other pair of cases searches genuinely disjoint
    collections. **Every `:DOWN` ref reaches exactly one case, and it is the intended one.**

  §7 step 3's five-point argument is the proof; point 5 covers (iii)–(iv).
- **INV-SP-A4 (no monitor gap; no leak on any death).** An owner is monitored from reservation
  time, strictly before any schema exists. Consequently: (a) an owner dying while parked leaks
  nothing; (b) an owner dying while its reservation is queued leaks nothing and frees its slot;
  (c) an owner dying **during** provisioning leaks nothing — the worker finishes, its schema is
  enqueued for dropping, the slot is freed; (d) a worker dying abnormally leaks nothing — the
  pool enqueues a drop of the pre-minted `schema_name`, replies to a live owner, frees the
  slot; **(e) (ADDED IN ROUND 2, F1) an owner dying while its own `{:drop, purpose: :release}`
  op is queued or in flight** leaks nothing and frees its slot — clause B case 4b deletes the
  `active` entry in that same callback and rewrites the already-scheduled op to
  `:release_orphaned`, so exactly **one** drop runs for that schema, no reply is sent to the
  dead caller, and no second op is enqueued. Reachable in practice:
  `Definitions.safe_release/2` calls `release/2` from a `rescue` path
  (`definitions.ex:1818-1826`), and ISS-0048's existing test kills an owner outright. Covered
  by RT-8. In all **five** the pool survives and the quota returns to its pre-claim value.

  *Round 1 enumerated only (a)–(d) and let (e) fall through to the reclaim path, which deleted
  the `active` entry and enqueued a redundant second drop. That is F1; (e) is the fix, not a
  disclosure.*
- **INV-SP-A5 (peak DB demand — the F1 invariant).** At most one DB operation is in flight at
  any time, so peak concurrent DBConnection checkouts attributable to the pool is **2** (a
  provisioning: the worker plus `Ecto.Migrator`'s inner `Task.async`) or **1** (a DROP) —
  **identical to today's fully-synchronous module**. The pool imposes no coupling between
  `max_concurrent` and the Repo's `pool_size`. Verified 4/4 at `pool_size = 2` (V16, §3.6).
- **INV-SP-A6 (residual, disclosed).** Nothing aborts a hung DB operation; both budgets remain
  caller-side allowances (`iss0220-…md` §5.3). A worker that never returns blocks all further
  DB work for that pool indefinitely. Strictly better than today, where a hung provisioning
  blocks **everything** including timer messages and reclaims — but not a bound, and not
  claimed as one.
- **INV-SP-A7 (residual, disclosed).** Because `async_nolink` does not link, a worker
  **outlives** a pool that dies mid-operation and may complete a schema nobody tracks. A
  sub-case of `req039-…md` §11 OQ-3's accepted "pool restart loses all bookkeeping"
  limitation, and narrower than the alternative (a linked Task lets a worker crash strand
  *every* live claim — §4.4 (E)).

---

## 9. Effect on existing tests (hazard 9) — no behavioural change required

The validator independently verified this section against
`promotion_assertion_rerun_test.exs:150`'s partial map match and `sandbox_pool_test.exs:144`
/`:349`, and found it sound. It is unchanged in round 1 except where the state shape renamed a
field.

### 9.1 `promotion_assertion_rerun_test.exs`'s `active_sandbox_id!/1` (`:144-159`)

Reads `%{active: active} = :sys.get_state(pool)` and requires exactly one key. **Still works,
unchanged:**

1. `active`'s key set and value shape are unchanged (§5); `%{active: active} = …` is a partial
   map match that ignores the two new siblings.
2. The helper runs inside an `assertion_evaluator`, which `apply_promotion_assertion_rerun/6`
   invokes **after** `claim/2` returned `{:ok, claim}` — so the claim is in `active`,
   `in_flight` is `nil`, `db_queue` is empty. Exactly one key.
3. The `max_concurrent: 1` pools these tests use, driven by one synchronous caller, never
   produce a second concurrent claim.

**Required change: a comment correction only.** The moduledoc (`:47-54`) and the helper
(`:144-148`) justify reliability with "since the whole call is synchronous". The call is still
synchronous from the caller's view; what changed is where DB work executes. The sentence
should rest on the actual reason — *the evaluator runs after the claim is granted, so exactly
one entry is in `active` and no DB work is in flight*. Prose only; no assertion, bound or
technique changes.

### 9.2 `sandbox_pool_test.exs`

| site | reads | verdict |
|---|---|---|
| `wait_until_waiter_queued/2` (`:135-152`) | `state.waiting` | **unchanged** — `waiting` untouched |
| "`max_wait_ms <= 0` … without ever queueing" (`:396`) | `:queue.len(waiting) == 0` | **unchanged** — an exhausted pool still rejects immediately and never touches `db_queue` |
| "a queued waiter is served" (`:246-296`) | rendezvous + `Task.await` | **unchanged** — the waiter is promoted and its provisioning starts immediately (nothing else in flight); bounds derive from `claim_call_timeout/1`/`release_call_timeout/0`, neither of which changes |
| "when no slot frees within the wait window" (`:298-318`) | `{:error, :sandbox_unavailable}` after 150 ms | **unchanged**, and now more reliably so |
| "two immediate claims … room for both" (`:220-243`) | two sequential claims | **unchanged** — sequential, so `in_flight` is `nil` before the second |
| ISS-0048 kill test (`:410-467`) | `wait_until_schema_dropped/2` | **unchanged** — the owner dies holding an `active` claim; the reclaim frees the slot immediately and the DROP runs next (nothing else in flight), well inside the helper's `release_call_timeout/0` bound |
| `release/1,2` tests (`:322-383`) | `{:error, :sandbox_unavailable}` sanity checks | **unchanged** — §4.3 |

### 9.3 `sandbox_pool_call_timeout_test.exs`

Uses a black-hole pid, never a real pool, and asserts only client-side integers. None changes.
RT-1..RT-4 pass unchanged.

### 9.4 Nothing is weakened

No existing assertion is relaxed, no bound widened, no test deleted or skipped, no
`describe`/`test` name changed. The only edits to existing test files are §9.1's comment
corrections.

---

## 10. Regression-test contract (TEST-DESIGNER implements)

### 10.1 The two traps this contract is designed around

**Trap 1 — a test that fails pre-fix for the wrong reason.** A test calling a function the fix
introduces fails pre-fix with `UndefinedFunctionError`/`KeyError`, proving the function exists,
not that the defect did. Every case carrying fail-first weight below uses only the shipped
public surface — `start_link/1`, `claim/2`, `release/2` — and observes only wall-clock
latencies. Cases needing post-fix-only introspection (`:sys.get_state`) are the *death-path*
cases, which the handoff requires as coverage but not as fail-first demonstrations; each is
labelled **post-fix-only**.

**Trap 2 — a "mechanism" assertion that is really a race.** This is F2, and round 0 fell into
it. RT-2(c) asserted that W2's completion message arrives first pre-fix, called it "immune to
absolute timing noise", and marked it a deterministic pre-fix failure. **Measured against the
shipped pool it held 3/20 in my run and 5/20 in the validator's** (V13). Pre-fix the pool
replies to W1 inside `service_next_waiter/1` and to W2 one callback boundary later —
microseconds — so two independent senders racing to the test process is a coin flip with a
bias, not an observation of the mechanism. **(c) is deleted, not repaired.**

### 10.2 Placement

**A new `describe` block in `test/letflow/sandbox_pool_test.exs`**, not a new file: every case
needs real Postgres, Sandbox `:auto` and an isolated pool, all of which that file's `setup` and
`start_pool!/1` already provide, with a 40-line moduledoc justifying the `:auto` switch. It is
already `async: false`. (ISS-0220 took the opposite decision for the opposite reason: its cases
needed no database.)

Three helpers are needed:

```
# Snapshot of every sandbox_% schema in information_schema.schemata. Set difference
# before/after is the no-schema-leak proof where the leaked name is unknown.
defp sandbox_schema_names() :: MapSet.t(String.t())

# Runs a verification query in a SHORT-LIVED process that then exits, so the test
# process never acquires an :auto checkout of its own. This is what keeps every case
# below inside decision 0009's TEST_MIN_POOL_SIZE floor of 2 (§10.5) -- it is a
# correctness requirement of the contract, not a style preference.
defp query_without_holding(fun) :: term()

# Spawns a process that claims, reports {label, result, elapsed_ms}, then blocks
# until told to release -- honouring the same-process claim/release contract
# (moduledoc :33-46). Elapsed is measured with System.monotonic_time(:millisecond)
# INSIDE the spawned process, around the claim/2 call only.
defp spawn_claimer(pool, label, max_wait_ms) :: pid()
```

`test/specs/ISS-0224.md` is TEST-DESIGNER's companion artefact, per the `test/specs/ISS-0220.md`
convention.

### 10.3 The required cases

#### RT-1 — CONTROL: a parked waiter times out on schedule when nothing is provisioning

*Passes pre-fix AND post-fix — the control arm, not the regression.* Its job is to make RT-2's
failure attributable to the blocking rather than to the timer.

Pool `max_concurrent: 1`. O claims and holds the only slot and never releases. W1 parks with
`max_wait_ms: 60_000`; W2 parks behind it with `max_wait_ms: 50`. Wait for
`:queue.len(waiting) == 2`.

Assert: W2's result is `{:error, :sandbox_unavailable}`; `t_w2 >= 50`; W1 is never served.
Then kill W1, release O, assert no `sandbox_%` schema survives.

#### RT-2 — fail-first #1

Identical to RT-1 except **O releases** once both waiters are parked, so W1 is served while
W2's 50 ms timer runs. This is `scratch/iss0224_repro.exs`'s scenario as ExUnit. `t_w1` = W1's
claim latency (≈ one provisioning); `t_w2` = W2's.

| # | Assertion | Pre-fix (measured, shipped pool, n=20) | Post-fix (measured, prototype, n=20) |
|---|---|---|---|
| a | **Premise**, checked first: `t_w1 >= 200`, else `flunk/1` naming the measured value and this § — a host that provisions in under 200 ms cannot exhibit the defect and a green result there would be vacuous | 476–578 ms ✓ | 416–575 ms ✓ |
| b | W2's result is `{:error, :sandbox_unavailable}`; W1's is `{:ok, %SandboxClaim{}}` | ✓ | 20/20 ✓ |
| ~~c~~ | ~~"the first completion message has `label == :w2`"~~ — **DELETED in round 1**, not renumbered. Kept as a struck row so the audit trail reads correctly and so no future reader re-adds it | held **3/20** in my run, **5/20** in the validator's (V13) — a biased coin flip, not a mechanism | — |
| d | **`2 * t_w2 < t_w1`** — the load-bearing fail-first | **0/20 — FAILS**, because `t_w2 == t_w1` exactly in 20/20 runs, so `2·t_w2 < t_w1` is false | **20/20 ✓**, minimum observed ratio `t_w1/t_w2` = **7.91**, i.e. ~4× headroom over the 2× threshold |

**Lettering, fixed in round 2 (F2).** Round 1 deleted (c) and silently promoted (d) into the
(c) slot, leaving the document asserting both "(c) is deleted" and "implement RT-2(c)".
**The surviving ratio assertion is (d), everywhere in this document**, and (c) is a deleted
letter that is never reused. The struck row above exists so the table itself carries that fact
rather than relying on the prose beneath it. *(Round 1 also mistyped the pre-fix reason as
`2·t_w1 < t_w1`; the assertion is `2·t_w2 < t_w1`, and pre-fix it fails because `t_w2 == t_w1`.)*

**Round 0's assertion (c) — "the first completion message has `label == :w2`" — is deleted.**
It held 3/20 pre-fix (V13) and would have licensed a regression test that goes green against
unfixed code roughly a quarter of the time.

**Round 0's "either alone failing pre-fix is enough for fail-first" licence is removed.** RT-2(d)
and RT-7 are **both required**; neither may be dropped, and RT-2(d) may not be replaced by a
message-ordering assertion.

#### RT-3 — death path (a): the caller dies while parked in `waiting`

*Guard, not a regression — holds pre-fix via INV-SP-6; its job is to keep holding through the
refactor.* Pool `max_concurrent: 1`; O holds the slot; W parks with `max_wait_ms: 60_000`;
wait for `:queue.len(waiting) == 1`; kill W; poll until `:queue.len(waiting) == 0`. Assert: no
new `sandbox_%` schema (**no schema leak**); O releases and a fresh `claim(0, pool)` succeeds
(**no slot leak**); the pool is alive.

#### RT-4 — death path (b): the caller dies **during** its provisioning

**Post-fix-only technique**, labelled as such. Pool `max_concurrent: 1`. Snapshot
`sandbox_schema_names/0` via `query_without_holding/1`. Spawn O calling `claim(1_000, pool)`.
Poll `:sys.get_state(pool)` until `in_flight` is a `{:provision, _}` — the window that has
**no owner monitor at all today**, which is why this cannot be written against pre-fix code.
Kill O. Then, bounded by `SandboxPool.release_call_timeout/0` (the file's existing derived
polling bound — not a new constant):

- **no schema leak:** the snapshot is restored (the pool let the worker finish, then dropped
  its schema);
- **no slot leak:** a fresh `claim(0, pool)` succeeds;
- the pool is alive and `in_flight == nil`, `db_queue` empty.

#### RT-5 — death path (b'): the caller dies while its reservation is **queued**

**Post-fix-only.** Exercises §7 step 3 clause B case 4. Pool `max_concurrent: 2`. A claims (its
provisioning goes in flight). B claims **while A's is in flight** — B's `{:provision, _}` op
queues. Poll until `db_queue` holds one `{:provision, _}`. Kill B. Assert: no `sandbox_%`
schema appears for B; once A completes and releases, two fresh `claim(0, pool)` calls both
succeed (slot returned); the pool is alive.

**`pool_size` precondition: 2** (INV-SP-A5 — at most one DB operation in flight), satisfied by
decision 0009's floor, *provided* the test process holds no checkout — hence
`query_without_holding/1` (§10.2, §10.5).

#### RT-6 — death path (c): the worker itself crashes

**Post-fix-only.** Exercises §7 step 3 clause B case 1. Pool `max_concurrent: 1`. Snapshot
schemas. Spawn O calling `claim(1_000, pool)`. Poll until `in_flight` is a `{:provision, _}`,
read `in_flight.task_pid`, and `Process.exit(task_pid, :kill)` — a genuine abnormal exit, not
a stub. Assert:

- O receives `{:error, :provision_failed}` — the exact atom `definitions.ex:1495` matches on;
- **no schema leak:** the snapshot is restored (guaranteed *only* because the pool pre-minted
  the name — §5);
- **no slot leak:** a fresh `claim(0, pool)` succeeds;
- **the pool survives** — what `async_nolink` buys over `Task.async` (§4.4 (E)); assert
  `Process.alive?(pool)` and a successful subsequent claim.

#### RT-7 — fail-first #2 (NEW in round 1; replaces round 0's RT-7)

*Round 0's RT-7 asserted that `release/2` stays fast during a provisioning. Under the corrected
design that is false by construction — the release queues behind the provisioning (§4.2) — and
it was also the exact scenario F1 showed round 0 could not survive at `pool_size = 2`. It is
replaced by a case that tests what the design actually guarantees: that the **mailbox** stays
responsive.*

Pool `max_concurrent: 1`. B claims, so the only slot is reserved and its provisioning is in
flight. The test process then calls `claim(0, pool)` — a DB-free path that must return
`{:error, :sandbox_unavailable}` immediately. Let `t_probe` be its latency and `t_b` B's.

| # | Assertion | Pre-fix (measured, shipped pool, n=15) | Post-fix (measured, prototype, n=15) |
|---|---|---|---|
| a | **Premise**, checked first (**ADDED IN ROUND 2, F3**): `t_b >= 200`, else `flunk/1` naming the measured value and §10.4 — same shape, same threshold and same rationale as RT-2(a), reusing the **same** vacuity floor rather than introducing a second constant | ≥ 369 ms ✓ (the (c)-row latencies below are `t_probe ≈ t_b − 60`, so every `t_b` ≥ 429) | 416–575 ms ✓ (same host, same provisioning cost as RT-2(a)) |
| b | result is `{:error, :sandbox_unavailable}` | 15/15 ✓ | 15/15 ✓ |
| c | **`4 * t_probe < t_b`** | **0/15 — FAILS**: latency 369/375/376/379/389/421/432/465/472/503/510/521/525/1129 ms, i.e. the probe sat in the blocked mailbox for a full provisioning | **15/15 ✓** — latency **min 0, max 0 ms** |

**Why RT-7 needs (a), and why round 1's version was unsound without it (F3).** RT-7's ratio
`4 * t_probe < t_b` goes green pre-fix on any host that provisions in under 80 ms — pre-fix
`t_probe ≈ t_b − 60`, so the ratio holds whenever `t_b < 80`. That is exactly the vacuous-pass
hazard RT-2(a) exists to prevent, and round 1 gave the guard to one of the two mandatory
fail-firsts and not the other. The floor is **the same 200 ms**, applied to the same quantity
class (one provisioning), so this adds **no** new constant — see §10.4.

**Lettering note (round 2).** RT-7's rows were re-lettered when (a) was inserted: round 1's
(a) → (b), round 1's (b) → **(c)**. This is stated rather than done silently, and every
reference in this document was updated in the same pass (§10.4, §15) — F2's lesson applied to
the change F3 required. RT-2 and RT-7 now share a shape: **(a) is the premise guard in both**;
the load-bearing ratio is RT-2(**d**) and RT-7(**c**), the letters differing only because RT-2
carries a deleted (c) that is never reused.

The same atom is returned in both arms, so the discriminator is purely latency, with a margin of
**≥ 369 ms against 0 ms**. Deterministic in a way round 0's deleted ordering assertion never
was, and it needs no constant: `t_b` is measured in the same test. Pre-fix `t_probe ≈ t_b − 60`
(the probe starts 60 ms after B), so `4·t_probe < t_b` requires `t_b < 80` — never true for a
≥ 411 ms provisioning, which is precisely what (a) now asserts instead of assuming.

#### RT-8 — death path (e): the owner dies while its **release-drop** is queued or in flight

**NEW IN ROUND 2 (F1).** **Post-fix-only** (pre-fix there is no `db_queue` and no deferred
DROP at all, so the scenario has no pre-fix analogue). Exercises §7 step 3 clause B **case 4b**
and INV-SP-A4(e). Its job is to prove that the case-4b path — not the case-5 fall-through
round 1 would have taken — is what actually runs.

**The scenario is built to make the window wide and the state stable**, so the anti-duplicate
assertion is a direct read rather than a race:

Pool `max_concurrent: 2`; `pool_size` requirement **2** (one provisioning in flight, INV-SP-A5),
every verification query through `query_without_holding/1` (§10.2, §10.5).

1. Snapshot `sandbox_schema_names/0`.
2. `spawn_claimer(pool, :o1, 0)` claims and holds a slot; the test records its `sandbox_id`
   from the reported `{:ok, %SandboxClaim{}}`.
3. `spawn_claimer(pool, :a, 0)` claims the second slot. Poll `:sys.get_state(pool)` until
   `in_flight` is a `{:provision, _}` for A — a ≥ 411 ms window.
4. Tell O1 to release. O1 calls `release/2` **itself** (same-process contract, moduledoc
   `:33-46`) and blocks in its `GenServer.call`. Poll until `db_queue` holds a
   `{:drop, %{purpose: :release, sandbox_id: <O1's id>}}` op — it is **queued**, not in flight,
   because A's provisioning owns the worker.
5. `Process.exit(o1_pid, :kill)`.

Assert — first **synchronously**, on the next `:sys.get_state(pool)` after the pool has
processed the `:DOWN` (poll until `active` no longer holds O1's `sandbox_id`; A's provisioning
is still running, so the pool state is quiescent and inspectable):

- **no duplicate drop — the direct assertion against the case-5 fall-through:** `db_queue`
  contains **exactly one** `{:drop, _}` op whose `sandbox_id` is O1's. Round 1's behaviour
  would show **two** here (the original `:release` op plus a `:reclaim` op). This is the whole
  point of the case, and it is deterministic, not timing-dependent;
- that op has `purpose == :release_orphaned`, `from == nil`, `owner_ref == nil`;
- **the slot was freed in the `:DOWN` callback** (INV-SP-DOWN-2/3): O1's `sandbox_id` is absent
  from `active`.

Then let the pool drain and assert, bounded by `SandboxPool.release_call_timeout/0` (the file's
existing derived polling bound — **no new constant**):

- **no schema leak:** once A completes and releases, the `sandbox_schema_names/0` snapshot is
  restored — O1's schema was dropped exactly once and A's was dropped on release;
- **no slot leak:** two fresh `claim(0, pool)` calls both succeed;
- `in_flight == nil` and `db_queue` empty;
- **the pool is alive** (`Process.alive?/1`), and it never received a reply-to-a-dead-caller
  crash.

*Not a fail-first, and not counted as one.* Like RT-3..RT-6 it is a death-path guard; the two
mandatory fail-firsts remain RT-2(d) and RT-7(c).

### 10.4 No new constant — and the round-0 self-calibration claim, corrected

The handoff requires any new constant to be derived from measurement and to survive a different
but equally legitimate sample window. **This contract introduces none.**

- RT-2(d) and RT-7(c) are **ratios of two quantities measured inside the same test on the same
  host**.
- The premise guards — **RT-2(a) and RT-7(a)** — use `200` ms, which is not a tolerance but a
  **vacuity floor**: below it the defect cannot exist and the test says so loudly instead of
  passing green. **They share one value, deliberately.** RT-7(a) was added in round 2 (F3)
  because RT-7 was a mandatory fail-first with no guard while its sibling had one; it guards
  the same quantity class (one provisioning latency) against the same floor, so it introduces
  **no second constant** — the count of new constants in this contract is still **zero**.
- RT-3..RT-6 and RT-8's polling bounds already exist in the file, derived from
  `SandboxPool.release_call_timeout/0` — reused, not re-derived.

**The vacuity floor's derivation, corrected (F5).** Round 0 cited 446 ms as the project-wide
minimum provisioning and "2.2× below". Both figures were wrong.

| window | n | minimum single provisioning |
|---|---|---|
| ISSUE-FIXER, ~20 windows on this host (**their measurement, attributed, not re-derived by me**) | ~1500 | **411 ms** |
| Mine, `scratch/iss0224_provision_latency.exs` | 120 | 434 ms (p50 564, p90 688, max 1015) |
| Mine, RT-2 prototype `t_w1` | 20 | **416 ms** |
| Mine, `scratch/iss0224_repro.exs` | 10 | 446 ms |
| Validator's independent window | — | 464 ms (p50 524, p90 603, max 1035) |
| Validator's round-2 re-check, a fresh window (**their measurement, attributed**) | 150 | **423 ms** |

Governing figure: **411 ms** (the lowest, from much the largest sample). **200 ms sits 2.06×
below it**, and 2.08× below my own first-hand lowest of 416 ms. **Six** windows now agree —
the validator's round-2 window of 150 samples put the minimum at 423 ms, above the governing
figure, so the floor is unchanged and is not being re-derived here. The conclusion holds and
the arithmetic is right. **The same floor now serves RT-7(a) as well as RT-2(a)** (F3), which
is why no second figure had to be derived.

**Round 0's self-calibration claim was wrong, and the fix is structural, not arithmetical.**
Round 0 argued that ratio assertions "self-calibrate in the safe direction because a slower
host inflates both sides". The validator correctly showed the two sides inflate on different
scales *for round 0's design*: `t_w2` sat behind a `drop_schema/1` running in a pool callback
(20–687 ms, and 5576 ms under connection contention), while `t_w1` is one provisioning
(~2–3× spread) — giving, at `t_w1 = 464` and `t_w2 = 50 + 687`, `1474 < 464`: **red post-fix**,
with RT-2(a)'s guard passing and therefore not catching it.

**That objection is answered by §2.3's reversal, not by re-deriving a tolerance.** With no
`Repo` call in any pool callback, `t_w2` is `max_wait_ms` plus BEAM scheduling only. **Measured
on the prototype: overshoot 1–3 ms across 20 runs, `t_w2` ∈ [51, 53] against `w2_wait = 50`,
minimum ratio `t_w1/t_w2` = 7.91.** The two sides no longer inflate on different scales because
the smaller side no longer contains DB work at all. The `2×` threshold has ~4× headroom against
the measured minimum ratio, and the measurement was taken at `pool_size = 2` — the worst
configuration decision 0009 permits.

### 10.5 `pool_size` preconditions — stated, and satisfied by decision 0009's floor

F1's third consequence required every case to state its `pool_size` requirement.

| case | concurrent DB ops | `pool_size` needed | met at 0009's floor of 2? |
|---|---|---|---|
| RT-1 | 0 (nothing provisions) | 1 | ✓ |
| RT-2, RT-3, RT-4, RT-6 | 1 provisioning | 2 | ✓ |
| RT-5, RT-7, **RT-8** | 1 provisioning (INV-SP-A5 — serialized; RT-8's queued DROP runs only *after* A's provisioning completes, never beside it) | 2 | ✓ |

**Every case fits within `TEST_MIN_POOL_SIZE = 2`, on one condition: the test process must not
hold an `:auto` checkout of its own** — hence `query_without_holding/1` (§10.2). This is a
correctness requirement of the contract, not a style preference: probe3's `holders = 1` row
(V17) shows one extra holder is enough to break a provisioning at `pool_size = 2`.

TEST-DESIGNER must use `query_without_holding/1` for every verification query in these seven
cases. Note that this is *stricter* than the existing tests in the file, which query directly
from the test process — see §13 item 5 for why those are already marginal and why that is a
pre-existing finding rather than something this contract may quietly change.

---

## 11. What ELIXIR-DEV must NOT change

1. **Do not call `Task.await/2`, `Task.yield/2` or `Task.shutdown/2` from a pool callback.**
   Any of them re-blocks the mailbox and reverts this fix while leaving the diff looking
   correct.
2. **Do not use `Task.async/1` or `Task.start_link/1`.** They link; a worker crash would take
   the pool down. Use `Task.Supervisor.async_nolink/3` (§4.4 (E), §6.6).
3. **Do not leave, or re-introduce, any `Repo` call inside a pool callback** — including
   `drop_schema/1` on the release path (`:246`) and the reclaim path (`:283`). That is F1, and
   it regresses the module at `pool_size = 2` (§3.5). INV-SP-A5 is the invariant to check
   against.
4. **Do not run more than one DB operation at a time.** `pump/1` must be a no-op while
   `in_flight != nil` (§3.4's measured deadlock; §4.1).
5. **Do not store the worker's pid or ref as an `owner_ref`, and never write the worker pid
   into `active`** (§6.5).
6. **Do not change `claim/2`'s or `release/2`'s `@spec`, arities, defaults, or error
   taxonomy** (V9).
7. **Do not change `provision_timeout_ms/0`'s value, `claim_call_timeout/1`, or
   `release_call_timeout/0`** (§2.2, §8.3).
8. **Do not change `handle_info({:claim_timeout, caller_ref}, state)`** (`:260-270`).
9. **Do not change `handle_queue_or_reject/3`** (`:317-326`), `find_waiter/2`,
   `remove_waiter/2`, or `find_active_by_owner_ref/2`.
10. **Do not change `release/2`'s observable contract.** It must still reply only once the
    DROP has resolved, still return `:ok` / `{:error, :not_found}` / `{:error,
    :release_failed}`, and still **retain** the `active` entry on `{:error, :release_failed}`
    **while the owner is alive** (INV-SP-5 as restated in §8.2). On the dead-owner path the
    entry is already gone and INV-SP-DOWN-3 governs — that is not a contract change, it is the
    contract having no observer left.
11. **Do not change how `schema_name` is constructed** (INV-SP-4 / INV-7).
12. **Write one `handle_info/2` clause per message *shape*, branching in the body** — the
    worker-result handler and the unknown-ref no-op must be a single
    `{ref, result} when is_reference(ref)` clause. Two clauses cannot be distinguished by
    pattern match, so the second is unreachable, and `mix letflow.check`'s
    `compile --warnings-as-errors` (`mix.exs:67`, V15) turns that into a red build. Equally:
    **do not add a catch-all `handle_info(_msg, state)`**, which would mask genuinely
    unexpected messages.
13. **Register `Letflow.SandboxPool.TaskSupervisor` BEFORE `{Letflow.SandboxPool, []}`** in
    `application.ex`'s child list (§6.6, V14). "After" starts the supervisor after its
    dependant.
14. **Do not weaken, widen, skip or delete any existing test.** The only permitted edits to
    existing test files are §9.1's comment corrections.
15. **Do not add a `:task_supervisor` option, a `claim/3`, or any other new public surface.**
16. **Do not demonitor `owner_ref` when the release-drop is enqueued, and do not set that op's
    `owner_ref: nil`.** It looks like a simplification — it would make INV-SP-A3 hold as plain
    disjointness and remove the need for clause B case 4b — and it is a permanent slot leak on
    the failed-DROP path. §4.4 (I) states the full reason. The monitor must stay live exactly
    as `sandbox_pool.ex:253-254` keeps it live today.
17. **Order clause B's cases as written: case 4b BEFORE case 5.** They are ordered, not
    disjoint (INV-SP-A3(iv)). Swapping them, or writing case 4b as a subcase of case 5,
    reintroduces the duplicate `{:drop, _}` op and re-breaks §5's `db_queue` bound. RT-8 is
    the test that catches it.
18. **Case 4b must rewrite the existing op in place, preserving its FIFO position, and must
    NOT enqueue a second drop** (§6.2's `replace_queued_op/3`). Removing-and-appending would
    let a later provisioning overtake a pending DROP, which §5's FIFO argument relies on not
    happening.

---

## 12. Files the implementation must touch

| File | Change | Owner step |
|---|---|---|
| `lib/letflow/sandbox_pool.ex` | §5 state shape, §6.2 private functions, §7 algorithms, moduledoc paragraph describing the serialized-worker shape and the "at most one DB operation in flight" property | ELIXIR-DEV |
| `lib/letflow/application.ex` | one child added, **before** `{Letflow.SandboxPool, []}` (§6.6) | ELIXIR-DEV |
| `lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` | prose-only addendum under §12 and §16 OQ-3 (§8.3) | ELIXIR-DEV |
| `test/letflow/sandbox_pool_test.exs` | new `describe` block (RT-1..RT-8), three new helpers (§10.2), one comment correction | TEST-DESIGNER |
| `test/letflow/definitions/promotion_assertion_rerun_test.exs` | comment-only correction (§9.1) | TEST-DESIGNER |
| `test/specs/ISS-0224.md` | case rationale + pre-fix/post-fix expectations | TEST-DESIGNER |
| `docs/issues/ISS-0224.yaml` | status transitions | DOC-UPDATER |

**Explicitly NOT touched:** any `config/*.exs`, `docs/migration/decisions/0009-*.md`, anything
under `priv/repo/migrations/`, `lib/letflow/definitions.ex`,
`lib/letflow/sandbox_pool/fixture_loader.ex`, `test/letflow/sandbox_pool_call_timeout_test.exs`,
`test/letflow/sandbox_pool/fixture_loader_test.exs`, `test/support/data_case.ex`,
`scripts/test_parallel.sh`.

---

## 13. Findings to report to ORCH as candidate successor issues

Per `core-directives.md` §"No Issue Left Local-Only" and `ISSUE_QUEUE.md` — **reported**, not
filed; this agent allocates no id and calls neither the queue nor `gh`.

1. **INV-SP-T4b remains open: total `claim/2` latency under multi-slot contention is still
   unbounded by `claim_call_timeout/1`** (§8.3, §14 OQ-1). Severity: medium, **not currently
   observable** — no caller drives a pool with `max_concurrent > 1` concurrently (V9) and
   `config/test.exs` pins the singleton to 1 (V11).
2. **`release_call_timeout/0` is still over-sized, but less re-derivable than ISS-0220 §16 OQ-3
   assumed** — the release path's requirement is now "one provisioning plus one DROP", not the
   DROP alone (§8.3). Severity: low.
3. **The `pool_size ≥ P + 1` deadlock rule for concurrent `Ecto.Migrator` runs under Sandbox
   `:auto` is undocumented anywhere in the repo** (§3.4). Measured at P=3 and P=5, and
   independently reproduced by CODE-DESIGN-VALIDATOR. It bounds any future concurrency work on
   this module. Severity: low-medium. Candidate home: `docs/anti-patterns.md`.
4. **A `Repo` call in a GenServer callback silently adds a concurrent checkout to whatever that
   process spawned** — the F1 class, and the reason round 0 shipped a `pool_size = 2`
   regression. Worth an `anti-patterns.md` entry in its own right: *"counted the connections
   the Tasks need and forgot the process that spawned them."* Severity: low.
5. **Pre-existing (NOT caused by this change): `sandbox_pool_test.exs` is already marginal at
   `pool_size = 2`.** Once the test process calls `schema_exists?/1` it holds an `:auto`
   checkout, so any subsequent `claim/2` needs 3 connections against **today's shipped code**.
   Measured (V17): `probe3 sync 1` at `pool_size = 2` → `ConnectionError`. Attribution is
   structural: the failing path is in the shipped module, not in this branch
   (`core-directives.md` §"Failure Attribution Is Structural", route 3, with the measurement as
   evidence). §10.2's `query_without_holding/1` avoids the problem for the *new* cases only;
   retrofitting it to the existing ones is a separate change this design deliberately does not
   make (§11 item 14). Severity: low.

---

## 14. Open questions (explicit — not resolved by guess)

**OQ-1 — should DB concurrency ever be raised above one operation?** §4.1 chose one, on §3.4's
measured deadlock and F1's measured third actor. If a future caller needs parallel
provisioning, the measured rule is `pool_size ≥ P + 1` to avoid deadlock and `pool_size ≥ 2P`
for real parallelism (P=3, P=5 verified), **plus one per concurrently-active pool callback doing
DB work** — which after this design is zero. The natural cap is
`max(1, min(max_concurrent, Repo.config()[:pool_size] - 1))` — derived, no new config key.
Deliberately **not built**: no current caller needs it (V9), and its failure mode is a deadlock.

**OQ-2 — how should TEST-DESIGNER induce a genuine `{:error, :provision_failed}` *returned* by
the worker, as opposed to a worker crash?** RT-6 covers the crash path. The returned-error path
(`provision_sandbox/2`'s `rescue`) is harder without a stub: the schema name is randomly minted
so a collision cannot be forced, and the Repo is process-global so it cannot be pointed at an
unreachable database for one pool only. Two unvalidated ideas: revoking `CREATE` on the
database from the test role for one test, or deliberately exhausting the DBConnection pool.
Both are invasive under `async: false` with a shared Repo. **Flagged for TEST-DESIGNER**, with
RT-6 as the mandatory minimum. Not resolved here because resolving it well means running the
candidate techniques, which is TEST-DESIGNER's step.

**OQ-3 — should `mint_sandbox_identity/0` seed a per-pool counter for log traceability?** Not
changed; noted only because §5 moves the call site. `req039-…md` §4.4 step 4(a) settled the
construction.

**OQ-4 — `req039-…md` §11 OQ-3's accepted pool-restart leak now has a further path
(INV-SP-A7).** A worker outlives a dying pool and may complete an untracked schema. Narrower
than the alternative (§4.4 (E)) and the same accepted limitation, not a new one.
`iss0220-…md` §16 OQ-5 already flagged for ORCH that a second independent path was known; this
is a third. **Flagged, not re-filed** — re-filing an accepted limitation under a new number
would duplicate it.

**OQ-5 — `max_concurrent_sandboxes`'s default of 5 is still the placeholder `req039-…md` §11
OQ-4 named.** This design makes it the upper bound on `db_queue` depth. Still not derived;
unchanged here; named so it is not mistaken for a value this design endorses.

**OQ-6 (NEW, F6) — decision 0009's `TEST_MIN_POOL_SIZE = 2` is checked, and holds.**
`docs/migration/decisions/0009-test-parallel-pool-sizing.md` fixes the floor at 2 (`:67`,
`:76-81`). Round 0 would have made that number **inadequate** for the pool (peak 3, V12) while
citing the floor only as "V11" and never naming the record — exactly the silent-invalidation
`core-directives.md`'s decision-record rule forbids. **After §2.3's reversal the floor is
adequate: peak demand is 2, verified 4/4 at `pool_size = 2` (V16).** So 0009 is neither
re-decided nor invalidated, and no REVIEWER sign-off is required on it. What remains genuinely
open is narrower and is **not** this design's to settle: §13 item 5's pre-existing finding that
`sandbox_pool_test.exs`'s *existing* cases already exceed the floor when the test process holds
its own checkout. If ORCH decides to retrofit `query_without_holding/1` across that file, 0009's
floor should be re-examined in that run — with a measurement, not an argument.

---

## 15. Acceptance-criteria traceability

| Requirement | Concrete design element |
|---|---|
| Re-verify the diagnosis from source rather than accept it | §0.4 V1–V17, §1.1, §1.2 |
| **Re-verify the validator's own findings rather than accept them** | V12 (F1), V13 (F2), V14 (F3), V15 (F4), V16 (F1's fix), V17 — each reproduced before being acted on |
| Hazard 1 — slot bookkeeping; reservation before provisioning; released on failure | §5, §7 steps 1/2/3, INV-SP-A1 |
| Hazard 2 — owner dies during provisioning | §5, §7 step 3 clause B case 2 + clause A `owner_down?` branches, INV-SP-A4(c), RT-4 |
| Hazard 3 — three ref classes dispatched unambiguously | §7 step 3 clause B + its **five**-point proof, INV-SP-A3 (restated in round 2) |
| Hazard 4 — `from` held across callbacks | §6.1, §6.4, INV-SP-A2 |
| Hazard 5 — monitor the caller, not the worker | §6.5, §11 item 5, INV-SP-A4 |
| Hazard 6 — INV-SP-1 preserved or weakened | §8.1, INV-SP-1' |
| Hazard 7 — INV-SP-T4; `release_call_timeout/0`; ISS-0220 §16 OQ-3 | §8.3 — T4a a clean guarantee, T4b open; budget unchanged, four reasons incl. the corrected premise |
| Hazard 8 — DB connections, verified first-hand; BLOCKED acceptable | §3 (nine subsections, nine measurement tables); **not blocked** |
| **F1 — the pool process as a third DB actor** | §2.3 (reversal), §3.5 (refutation), §3.6 (fix measured 4/4 at `pool_size` 2), §3.7 (real requirement), §4.1 (corrected table), §8.3 (T4a re-worded), §10.5 (per-case `pool_size`), INV-SP-A5 |
| **F1 — decide or defer the serialization question** | §2.3 — **decided**: all `Repo` work serialized. Not blocking |
| **F2 — RT-2(c) does not fail pre-fix** | §10.1 trap 2, §10.3 (c deleted, d load-bearing, licence removed), RT-7 added |
| **F2 — re-derive the ratios against real variance** | §10.4 — the objection is answered structurally, with post-fix `t_w2` ∈ [51,53] and min ratio 7.91 measured at `pool_size` 2 |
| **F3 — supervisor ordering** | §6.6, §11 item 13, §12, V14 |
| **F4 — one `handle_info` clause per message shape** | §7 step 3, §11 item 12, V15 |
| **F5 — corrected minimum and multiple** | §10.4 — 411 ms, 2.06×, six windows tabulated |
| **F6 — name decision 0009** | §0.2, §3.7, §14 OQ-6, §12's not-touched list |
| **R2-F1 — the death-path interleaving F1's own fix created** | §7 step 2 (the copied `owner_ref`, stated), §7 step 3 clause B **case 4b** + the candidate table, §4.4 **(I)** (the rejected demonitor-at-enqueue, with its reason), §5 (`purpose`, corrected `db_queue` bound), §6.2 (two new helpers), §6.4 (no reply to a dead release caller), §8.2 (INV-SP-5 restated + reconciled with INV-SP-DOWN-3), §8.4 (INV-SP-A3 restated, INV-SP-A4(e) added), **RT-8** |
| **R2-F2 — RT-2's lettering contradicted itself** | §10.3 — survivor is **(d)** everywhere, (c) kept as a struck deleted row, `2·t_w2 < t_w1` typo fixed; every reference updated (§10.4, §15, §16, REWORK NOTICE) |
| **R2-F3 — RT-7 had no vacuity guard** | §10.3 RT-7(a) (`t_b >= 200`, same floor as RT-2(a), no new constant), rows re-lettered explicitly, §10.4 names both guards |
| Hazard 9 — `:sys.get_state/1` technique | §9.1 — valid unchanged; comment-only correction |
| Hazard 10 — `drop_schema/1` in or out | §2.3 — **IN**, reversed, with the round-0 error named |
| No implementation code | Signatures, `@spec`s, state shapes, prose/pseudocode only |
| No existing test weakened | §9.4, §11 item 14 |
| Any new constant derived and window-stable | §10.4 — **zero**; the one figure used is a vacuity floor checked against six windows, and round 2's RT-7(a) reuses it rather than adding a second |
| Regression test failing PRE-FIX behaviourally | RT-2(**d**) (0/20 pre-fix) **and** RT-7(**c**) (0/15 pre-fix), both required, both now premise-guarded |
| Explicit tests for the death paths | RT-3, RT-4, RT-5, RT-6, **RT-8** (the fifth path, round 2) |
| "Files the implementation must touch" | §12 |
| "What ELIXIR-DEV must NOT change" | §11 |
| Open questions stated, not guessed | §14 OQ-1..OQ-6 |

---

## 16. What each round deliberately did NOT change

### 16.0 Round 1

The validator listed what it had checked and found sound. Per `core-directives.md`'s
"Never resolve a conflict silently" and to keep this rework auditable, none of it was
re-litigated or silently reworded:

- INV-SP-A3's disjointness proof, including that Erlang orders `{ref, result}` before
  `{:DOWN, ref, …, :normal}` so clause A's flush is reliable (§7 step 3).
- INV-SP-A1 at every state transition (§8.4).
- INV-SP-A2's no-double-reply, including the absorbed stale `{:claim_timeout, _}` (§6.4).
- Owner-monitor semantics and §6.5.
- §9's "no existing test needs a behavioural change".
- §8.3's INV-SP-T4b retention and the `release_call_timeout/0` decision — the *conclusion* is
  unchanged; one reason was **strengthened**, because §4.2 shows OQ-3's premise for shrinking
  the number is now positively unmet rather than merely unaddressed.
- The absence of implementation code, and hazard/AC coverage.
- RT-3..RT-6's death-path coverage (renumbered nowhere; RT-7 is new, replacing round 0's).
- §3.2/§3.3/§3.4's measurements, which the validator reproduced independently.

One item the validator flagged as a word-fix was applied rather than defended: §7 step 5's
"every event that calls it frees exactly one slot" was **removed**, not repaired — the
`slots_in_use/1` guard is the real reason the promotion is correct, and the false claim added
nothing.

### 16.1 What round 2 deliberately did NOT change

Round 2's verdict re-confirmed round 1's three headline claims **by independent measurement**,
and explicitly named a set of items as not to be re-litigated. None of them was touched:

- **§3's measurements, §4's decision, and the serialized-worker shape.** Peak DB demand 2 at
  `pool_size = 2` was reproduced 5/5 by the validator against 3/3 failures with round 0's
  shape. The F1 fix is correct; round 2 changes only a death path that fix created.
- **INV-SP-A1 across all fourteen transitions**, re-checked under the new state shape.
- **INV-SP-A2 per-`from`**, including the absorbed stale `{:claim_timeout, _}`. Case 4b needed
  no amendment to it — INV-SP-A2's existing "except when its owner has died" exception already
  covers a release whose caller died (§6.4).
- **The `task_ref` half of INV-SP-A3** — clause A dispatches on `state.in_flight.op`'s kind and
  only one op is ever in flight. Point 1 of the proof is unchanged; only points 2 and 5, about
  `owner_ref`, moved.
- **§10.4's vacuity floor of 200 ms and the 411 ms / 2.06× arithmetic.** The validator's fresh
  150-sample window (min 423 ms) was *added* to the table as a sixth agreeing window, not used
  to re-derive anything.
- **F3 (supervisor ordering), F4 (single `handle_info` clause), §9.1's partial map match, and
  §4.2's "relocated not created" latency argument** — all confirmed sound in round 2.
- **§13 item 5's pre-existing finding** that `sandbox_pool_test.exs` is already marginal at
  `TEST_POOL_SIZE = 2` on **shipped** code — independently verified by the validator (5/8 at 2,
  8/8 at 3; all three failures `{:error, :provision_failed}` at `:257`/`:362`/`:410`). Still
  reported, still not fixed here.
- **The absence of implementation code**, re-checked before this round's edits and after.

---

## 17. Extension (ISS-0227, 2026-08-22) — two write-only fields removed

Authority for this change: `lib/letflow/design/iss0227-sandbox-pool-dead-field-removal.md`.

**What was removed.** `provision_op()`'s `owner_pid` and the `in_flight()` record's
`schema_name` were both **written and never read** — every path that could have wanted either
already held the same value under a different name, or could reach it in one hop from a field
sitting beside it in the same record. Both are gone from `lib/letflow/sandbox_pool.ex`.

**Derivations, with their equivalence.**

- `owner_pid` → `elem(p.from, 0)` for a provision op `p`. `from` is a `GenServer.from()`, i.e.
  `{pid(), tag}`, and was the source the removed field was computed from, in the same map
  literal. It is **never rewritten on a provision op** — the only in-place rewrite this module
  performs on one is `owner_down?: true` (§7 step 3 clause B case 2) — so the two could not
  diverge.
- `in_flight.schema_name` → the schema name of `in_flight.op`
  (`{:provision, %{schema_name: n}}` or `{:drop, %{schema_name: n}}` → `n`). `in_flight.op` is
  replaced wholesale, never patched in a way that changes its schema name: case 4b's rewrite
  changes only `from`/`owner_ref`/`purpose`, and §7 step 3's own note already says the worker
  holds only the schema-name STRING and is unaffected.

**`op_schema_name/1` went with them.** After the `in_flight` field was removed it had no call
site left, and an unused `defp` fails `mix compile --warnings-as-errors` — measured, not
assumed (that gate runs at `docs/agents/protocols/GIT_MERGE.md:166` and as step 3 of `mix.exs`'s
`letflow.check` alias). It may be re-introduced the moment something genuinely calls it.

**No invariant changes.** Nothing in this document's invariant set is added, removed, weakened,
strengthened or restated by ISS-0227: INV-SP-A1 counts ops by kind, INV-SP-A2 replies to `from`,
INV-SP-A3 classifies `reference()` values (`owner_pid` was a `pid()`; `in_flight.schema_name` a
`String.t()`), INV-SP-A4's five death paths all turn on `owner_ref` and on the **pre-minted**
`schema_name` of `provision_op()`/`drop_op()` — both retained — and INV-SP-A5 tests `in_flight`
for `nil`, not for any field. INV-SP-A6/A7, INV-SP-1..7, INV-SP-DOWN-1..5 and INV-SP-T1..T5 are
likewise untouched, and **no new invariant is introduced**: after this change there is no second
copy left that could disagree. In particular **`owner_ref` and the owner-monitor mechanism are
unchanged** — the monitor is still established on the calling process at reservation time,
strictly before any schema exists, from a surviving local `owner_pid` binding. There is no
external behaviour change either: no `@spec`, arity, return value, error atom, timeout or reply
timing moves, and the serialized single DB worker is unaffected.

**In-place markers.** The two superseded declarations are marked where they lived rather than
deleted — §5's `provision_op()` block and its `in_flight()` block — and §7 step 2's enumerated
`{:provision, _}` literal carries a one-line removal note. Everything else in this document is
ISS-0224's historical record and stands as written.
