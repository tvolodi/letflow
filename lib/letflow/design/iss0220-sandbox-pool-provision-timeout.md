# Design: ISS-0220 — `Letflow.SandboxPool` claim/release call-timeout budgets

**Issue:** ISS-0220 / GH#450 / `letflow-queue` task 220.
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF03-ISS0220-20260822`, WF-03 Step 2
**Branch:** `fix/WF03-ISS0220-20260822`

**This document produces:** the root-cause statement re-derived from source, the
two-budget split, the derivation of the new default from measurement, public
`@spec`s, the config shape, prose algorithm changes, the exact test-side
rendezvous-bound re-sizing table, new/changed invariants, the regression-test
contract for TEST-DESIGNER, the successor issue to file, and open questions.
**No implementation code** — no function bodies, no `.ex`/`.exs` blocks with real
logic. Signature/`@spec`/config-shape blocks and pseudocode (`IF`/`CASE`) only,
matching the convention `iss-0048-sandbox-pool-owner-crash-reclaim.md` and
`iss-0047-username-race-conflict-target.md` §2.2 already use for a surgical,
non-full-module design.

---

## 0. Sources, and which factual premises this design verified first-hand

Per `core-directives.md` "This chain governs what you are told to DO, not what you
are told IS TRUE" and `HANDOFF_PROTOCOL.md` §1.1: ISSUE-FIXER's diagnosis was
treated as a hypothesis to check, not as fact to copy. Two of its stated premises
are **wrong** and one omission was found (§2.5); the conclusion survives all three,
and each correction strengthens rather than weakens it.

**Read in full for this design:** `lib/letflow/sandbox_pool.ex` (326 lines);
`test/letflow/sandbox_pool_test.exs` (433 lines, including its moduledoc's
`:auto`-mode argument); `test/letflow/sandbox_pool/fixture_loader_test.exs`
(helpers + moduledoc); `test/letflow/definitions/promotion_assertion_rerun_test.exs`
(moduledoc, every `assert_receive`/`max_wait_ms` site); `config/test.exs`;
`docs/migration/decisions/0009-test-parallel-pool-sizing.md`;
`docs/agents/instructions/core-directives.md`; `docs/anti-patterns.md` (section
index, plus "Inheriting a claim from a record instead of re-deriving it from the
source" and "Re-deriving the count while inheriting the unit being counted" in
full — both directly applicable here); `lib/letflow/design/req039-sandbox-pool-fixture-loader.md`
§2, §4.2, §4.3, §4.4, §4.7, §11 (OQ-3, OQ-4).

**Read targetedly:** `lib/letflow/tenant_provisioning.ex`
(`@tenant_scoped_migration_manifest`, `tenant_scoped_migrations/0`);
`lib/letflow/definitions.ex` (`apply_promotion_assertion_rerun/6`,
`claim_sandbox_and_proceed/8`, the three `SandboxPool.release/2` call sites);
`test/test_helper.exs`; `test/support/tenant_schema_reaper.ex`;
`deps/ecto_sql/lib/ecto/migrator.ex` (`async_migrate_maybe_in_transaction/7`,
`run_maybe_in_transaction/4`, `lock_for_migrations/4`);
`deps/ecto_sql/lib/ecto/adapters/postgres.ex` (`lock_for_migrations/3`);
`deps/db_connection/lib/db_connection/ownership/proxy.ex`;
`scratch/provision_latency.awk` and `scratch/claim_latency.exs` (ISSUE-FIXER's
measurement instruments, read to confirm what they actually measure).

**Verified first-hand in this worktree** (VERIFIED = read from source, or a command
was run and its real output observed):

| # | Premise | Status |
|---|---|---|
| V1 | `@call_timeout_buffer_ms = 5_000` at `sandbox_pool.ex:77`, and its comment's provenance is "not smaller than `GenServer.call`'s own default 5_000" — never sized against provisioning | VERIFIED (read) |
| V2 | `claim/2` (`sandbox_pool.ex:114`) derives its call timeout as `max_wait_ms + @call_timeout_buffer_ms` | VERIFIED (read) |
| V3 | `provision_sandbox/0` (`:288-314`) does `CREATE SCHEMA` + `Ecto.Migrator.run/4` over `TenantProvisioning.tenant_scoped_migrations/0`, called from inside `handle_call/3` (via `handle_provision_now/2`, `:202`) and from `service_next_waiter/1` (`:243`) | VERIFIED (read) |
| V4 | `Ecto.Migrator` has **no internal timeout**: `async_migrate_maybe_in_transaction/7` is `Task.async \|> Task.await(:infinity)` (`migrator.ex:342-343`), the per-migration transaction is `timeout: :infinity` (`migrator.ex:353`), and `Ecto.Adapters.Postgres.lock_for_migrations/3` merges `timeout: :infinity` (`postgres.ex:314`) | VERIFIED (read) |
| V5 | ExUnit's default per-test timeout is `60_000` ms in this toolchain; `test/test_helper.exs` calls bare `ExUnit.start()` and sets no `:timeout` | VERIFIED — ran `ExUnit.configuration()`, observed `exunit_default_test_timeout_ms: 60000` (Elixir 1.20.3 / OTP 29) |
| V6 | `assert_receive/2,3` accepts a **runtime** timeout expression (a variable or a function call), not only a literal | VERIFIED — probe: `assert_receive :hi, t` compiled and passed; `assert_receive :hi2, bound(), "custom"` compiled and failed at 300 ms with the custom message |
| V7 | `GenServer.call/3`'s timeout exit reason carries the exact timeout integer: `{:timeout, {GenServer, :call, [server, request, timeout]}}` | VERIFIED — probe observed `{:timeout, {GenServer, :call, [#PID<0.112.0>, {:claim, 0}, 300]}}` |
| V8 | Test counts per module: `sandbox_pool_test.exs` 8, `fixture_loader_test.exs` 6, `promotion_assertion_rerun_test.exs` 12 | VERIFIED (counted) |
| V9 | The one `SandboxPoolTest` test that never provisions (`:349`, unknown `sandbox_id` → `{:error, :not_found}`) is structurally the only one of the 8 that cannot be affected | VERIFIED (read) |
| V10 | In `fixture_loader_test.exs`, exactly 5 of 6 tests go through `claim_schema!/0` (`:120, :142, :171, :201, :230`); the 6th (`:151`) documents in its own comment that it deliberately does not | VERIFIED (read) |
| V11 | `promotion_assertion_rerun_test.exs` passes `max_wait_ms: 2_000` into `apply_promotion_assertion_rerun/6` at 8 call sites, reaching `SandboxPool.claim(2_000, pool)` via `claim_sandbox_and_proceed/8` (`definitions.ex:1482`) | VERIFIED (read) |
| V12 | 0009's clamp arithmetic at N=4: `budget = 100 - 10 = 90`; `computed = 90/4 = 22`; `4 × 22 = 88 ≤ 90` — no clamp, within budget | VERIFIED (arithmetic against 0009's own formula) |
| V13 | `test/support/tenant_schema_reaper.ex` sweeps only `tenant_[0-9a-f]{32}` schemas, keyed off `tenant_schemas` rows. **`sandbox_%` schemas are never swept by anything.** | VERIFIED (read) |
| V14 | `Ecto.Adapters.Postgres.lock_for_migrations/3` **raises** if the repo's `:pool_size` is exactly 1 (`postgres.ex:310-312`) | VERIFIED (read) |
| V15 | No HTTP route reaches `apply_promotion_assertion_rerun/6`; `Letflow.Definitions` is its only caller, and the router subtree references neither `sandbox_pool` nor `max_wait` | VERIFIED (grepped `lib/letflow/api/`, `lib/letflow/router*`) |

**Could NOT be verified in this worktree, and this design does not depend on the
unverified parts:** every latency number in §4 is **ISSUE-FIXER's measurement,
attributed as such** — the partition logs are not present here, `scratch/` holds
only the two instruments and not their output, and this run is explicitly forbidden
to run the suite. §4's derivation is constructed to hold for any distribution
consistent with those samples, and §10's regression-test contract depends on no
latency measurement at all. The `max_connections = 100` reading on
`letflow-2-postgres-1` is likewise ISSUE-FIXER's (no container access here); it
enters only §13, which argues that number is *not* the mechanism.

---

## 1. Scope boundary

**In scope:**

1. `lib/letflow/sandbox_pool.ex` — split the single 5_000 ms constant into an
   explicit, configurable **provisioning budget**; derive both `claim/2`'s and
   `release/2`'s `GenServer.call` timeouts from it; expose the derivation publicly.
2. `test/letflow/sandbox_pool_test.exs` — re-size five rendezvous/polling bounds
   from that same public derivation (§8). **No assertion is removed, weakened,
   skipped, tag-excluded, or `async`-serialized away** (§8.0).
3. A regression-test contract for TEST-DESIGNER (§10) plus `test/specs/ISS-0220.md`.

**Out of scope, deliberately, each named so it is not read as an oversight:**

4. **The head-of-line blocking defect** — `provision_sandbox/0` runs inside
   `handle_call/3`, so `max_wait_ms` is not honoured while the pool is provisioning
   for someone else. Real contract violation, materially larger fix. **File as a
   successor issue** — §12.
5. `docs/migration/decisions/0009-test-parallel-pool-sizing.md` — **no amendment**;
   its clamp is not the mechanism, and this design says so explicitly so a later
   reader does not re-suspect it (§13).
6. `config/dev.exs`, `config/prod.exs`, `config/test.exs` — **not touched**; the new
   key is code-defaulted, not config-required (§6).
7. `fixture_loader_test.exs` and `promotion_assertion_rerun_test.exs` — **no test
   edits**; both are fixed transitively by the `claim/2` change. Checked against the
   measured failure set, not assumed (§8.4).
8. Server-side enforcement of the provisioning budget (aborting a slow
   `Ecto.Migrator.run/4`). Not added; §5.3 states what that means.

---

## 2. Root cause, re-derived from source

### 2.1 The mechanism

`claim/2` (`sandbox_pool.ex:112-115`) computes its `GenServer.call/3` timeout as
`max_wait_ms + @call_timeout_buffer_ms`, with `@call_timeout_buffer_ms = 5_000`.

`max_wait_ms` is defined — by `req039-sandbox-pool-fixture-loader.md` §4.4 step 3, by
`claim/2`'s own `@doc`, and by the `Process.send_after(self(), {:claim_timeout,
caller_ref}, max_wait_ms)` timer at `sandbox_pool.ex:228` — as **how long a caller may
be parked in the pool's `waiting` queue**. It bounds queueing, and nothing else.

Therefore the constant `5_000` is the **entire budget for `provision_sandbox/0`**: one
`CREATE SCHEMA`, then `Ecto.Migrator.run/4` over every entry of
`tenant_scoped_migrations/0` — each in its own `Task`, its own transaction, its own
commit, plus the migration lock and a `schema_migrations` bookkeeping insert per
migration.

The constant was never sized against that. `sandbox_pool.ex:67-76`'s own comment
states its provenance in full: it exists so the call timeout is *not smaller than
`GenServer.call`'s own default 5_000 ms* when `max_wait_ms` is large. That is a
statement about `GenServer`'s default, not about provisioning cost. `req039-…md` §11
**OQ-4** conceded exactly this gap at design time — "left open for whoever tunes real
sandbox-provisioning cost … once real DB load from `tenant_scoped_migrations/0`'s
replay-per-claim cost is measurable." It is now measurable, and measured (§4.1).

### 2.2 The defect is the absent margin, not the contention that exposes it

This is the framing the record must carry, and it is the one point where the
evidence changed the argument rather than merely reinforcing it.

The tempting reading of "it fails at `TEST_PARALLEL_N=4`" is *this is an environment
problem, not a code defect.* **Reject that reading.** ISSUE-FIXER's direct probe
(`scratch/claim_latency.exs` — one BEAM, one pool, `max_concurrent: 1`, one claim at
a time, **zero test parallelism**, `max_wait_ms: 600_000` so a slow provision is
measured rather than converted into an exit) shows:

- On a **demonstrably idle host** (`docker stats` measured `letflow-postgres-1`
  dropping 197% → 0.42% CPU and `letflow-2-postgres-1` 20.95% → 4.95% before the
  run), n=20, the observed maximum is **3621 ms against a 5000 ms budget — a margin
  of 1.38×.**
- On the same host under its ordinary load, single-process still, n=40: **8 of 40
  provisions (20%) exceed the entire `claim(0)` budget**, with a maximum of
  **15 373 ms — 3.07× the budget.**

1.38× headroom at rest is not engineering margin; it is a coin flip against ordinary
host jitter, for an operation that is 32 transactions of DDL whose latency is
dominated by host I/O. And this project's documented operating reality is a machine
that is *expected* to be busy: `0009-test-parallel-pool-sizing.md`'s entire premise
is N concurrent partitions, and `docs/anti-patterns.md`'s "Running `docker compose
up` from a secondary worktree checkout" documents the several-workspaces-each-with-
its-own-Postgres arrangement this repo is actually checked out into.

So the budget is under-sized against `provision_sandbox/0`'s **own single-threaded
cost distribution**, not merely against a contended one. N=4 contention is what makes
it fail *often*; it is not what makes it wrong. **The contention is evidence, not
cause.**

### 2.3 Why the failure set has exactly the shape it has

The fingerprint is structural, not statistical:

- `SandboxPoolTest`: the only test in the file that never provisions a sandbox
  (`:349` — `release/2` on an unknown `sandbox_id` → `{:error, :not_found}`) is the
  only one structurally immune (V9).
- `FixtureLoaderTest`: exactly the 5 of 6 tests routing through `claim_schema!/0`
  are exposed; the 6th documents in its own comment that it deliberately does not
  (V10).
- `PromotionAssertionRerunTest`: the exposed subset is the one reaching
  `SandboxPool.claim(2_000, pool)` through `claim_sandbox_and_proceed/8` (V11) — call
  timeout `2_000 + 5_000 = 7_000`, against measured provisioning up to 15 373 ms.

ISSUE-FIXER's second, complete N=4 run decomposes the failures into exactly two
mechanisms, and both land where §2.1 predicts:

| Mechanism | Count | Sites |
|---|---|---|
| **(1) caller-side `GenServer.call` timeout** — the library defect | 9 | `GenServer.call(pid, {:claim, 2000}, 7000)` × 6: `PromotionAssertionRerunTest:394, :479, :527, :617, :760` and `FixtureLoaderTest:170`. `GenServer.call(pid, {:claim, 1000}, 6000)` × 3: `SandboxPoolTest:180, :276, :319`. |
| **(2) test-side rendezvous bound below measured provisioning latency** | 2 | `SandboxPoolTest:367` — `no matching message after 2000ms`, `{:owner_claimed, …}`. `SandboxPoolTest:216` — `no matching message after 3000ms`, `{:waiter_claimed, …}`. |

Total 11 failures out of 1433 tests / 5 properties, **all 11 inside the three files
ISS-0220 named, zero failures anywhere else in the suite**. Mechanism (1) is fixed
entirely by §7.2; mechanism (2) is fixed entirely by §8.2 — and the two mechanism-(2)
sites are precisely the two sites §8.2 identifies as *not* fixed by the library
change, independently derived here before this run's data arrived.

**The per-file counts differ between runs (the filing reported 4/5/7; this run
measured 5/1/3 by file) and that difference is not evidence in either direction.**
Per `core-directives.md` §"Failure Attribution Is Structural, Never By
Count-Matching", a bound with sub-1× margin produces a different subset every run —
which is itself corroboration of the mechanism, not noise to be explained away. The
attribution rests on §2.3's structural partition (route 1: only sandbox-provisioning
tests are exposed) and on §2.4's demonstrated mechanism (route 3), never on a count.

### 2.4 There is no other bound — the call timeout is the *only* one

V4 is load-bearing and was not in the diagnosis. `Ecto.Migrator` applies
`timeout: :infinity` at every level it controls: the per-migration `Task.await`, the
per-migration transaction, and the migration lock. A slow — or genuinely hung —
provisioning has **no server-side deadline whatever**. Before this fix, the caller's
5_000 ms `GenServer.call` timeout was the single deadline in the entire path, and it
was set by a constant chosen for an unrelated reason.

Two consequences that shape §4 and §5:

- Raising the budget cannot "mask a hang", because nothing else was catching a hang
  either. The budget is the only detector, so it must be sized to make *legitimate*
  provisioning never trip it — not sized to detect pathology.
- A budget that is too small does not merely delay a test: it converts a *correct*
  provisioning into a caller-side `exit`, which under ExUnit kills the test process,
  which kills the `Ecto.Migrator` `Task` linked to it, which is what produces the
  `Postgrex.Protocol … client #PID<…> exited` lines the issue filing mistook for the
  cause (§2.5 C3).

### 2.5 Corrections to the diagnosis

**C1 — the migration count is 31, not 28.** `@tenant_scoped_migration_manifest`
(`tenant_provisioning.ex:301-…`) holds **31** entries and `tenant_scoped_migrations/0`
maps all 31 through unfiltered (counted in this worktree: 31).
`scratch/provision_latency.awk`'s header comment and both ISSUE-FIXER messages say
"28"/"29 transactions", so the number appears to be inherited from an earlier read
rather than re-derived — the shape `docs/anti-patterns.md`'s "Re-deriving the count
while inheriting the unit being counted" warns about. **Direction of the error: the
real per-claim cost is ~11% higher than stated**, so the correction strengthens the
argument. Throughout this document the count is **31 migrations → 32 transactions**.

**C2 — `Ecto.Adapters.SQL.Sandbox`'s `:ownership_timeout` default is 120 000 ms, not
60 000 ms.** `deps/db_connection/lib/db_connection/ownership/proxy.ex:9`
(`@ownership_timeout 120_000`), read into `ownership_timeout = Keyword.get(pool_opts,
:ownership_timeout, @ownership_timeout)` at `:31`. Both ISSUE-FIXER messages state
60 000. Two consequences: the binding ceiling in §4.4 is **ExUnit's 60 000 ms
per-test timeout alone**, not a coincidence of two 60 000s; and in any case all three
affected files run under `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)`, where
ownership is not in play at all. `:ownership_timeout` is therefore **not** a ceiling
for this decision and is not used as one.

**C3 — the filing's own hypothesis (connection-pool resource contention) is wrong.**
ISSUE-FIXER's counter-argument is adopted: the causal arrow runs claim-timeout →
connection death, not the reverse. The structural half is independently checkable
here and checks out — a `GenServer.call` timeout raises an `exit` in the calling
process; under ExUnit that is the test process; when it dies, the `Task`
`Ecto.Migrator` spawned (`migrator.ex:342`) dies with it and its checked-out
connection is torn down, which is precisely a `Postgrex.Protocol … client #PID<…>
exited` line. The log-line tally (10 of 11 `client … exited` vs. 1 genuine queue
drop) is ISSUE-FIXER's measurement and could not be re-verified here — but nothing
rests on it: §2.2's zero-parallelism probe already excludes contention as the cause,
because a single-process, single-claim measurement has nothing to contend with. See
§13 for why 0009's clamp is likewise not the mechanism.

**C4 — one omission: `release/2` carries the same defect and was not named.** §3.2.

---

## 3. Decision: split the two budgets `claim/2` conflates

### 3.1 The split

| Budget | Means | Set by |
|---|---|---|
| `max_wait_ms` | how long the caller may be **parked in the pool's `waiting` queue** | the caller, per call — unchanged semantics, unchanged `@spec`, unchanged timer |
| `provision_timeout_ms` | how long **one provisioning of a sandbox schema** may take before the caller gives up | configuration, with a derived default (§4) |

`claim/2`'s `GenServer.call` timeout becomes `max_wait_ms + provision_timeout_ms()` —
the queue wait the caller explicitly asked for, plus one calibrated provisioning.

### 3.2 `release/2` is in scope too — a third mis-sizing nobody named

`release/2` (`sandbox_pool.ex:126`) calls `GenServer.call(pool, {:release,
sandbox_id})` **with no timeout argument at all** — i.e. `GenServer`'s own default
5_000 ms. Same defect class, same function pair, same code path, same load.

Notably, the measured `DROP SCHEMA … CASCADE` cost is **not** the reason: ISSUE-FIXER
measured 20–498 ms across 40 samples, max 687 ms under N=4 load — two orders of
magnitude cheaper than a provisioning, and comfortably inside 5_000 ms on its own.
**The reason is head-of-line blocking.** `release/2` must additionally wait out
whatever the pool is already doing, and the pool's mailbox is blocked for the whole
of any in-flight provisioning (§12) — up to 15 373 ms measured, i.e. 3× `release/2`'s
current implicit budget, before its own DDL even begins.

Including it is not scope creep, and the argument is decisive rather than aesthetic:
**`test/letflow/sandbox_pool_test.exs:273`'s `Task.await(waiter, 3_000)` wraps a
`SandboxPool.release/2` call.** Raising that test-side bound (§8) while leaving
`release/2`'s own 5_000 ms cliff in place would convert one failure mode into another
— the `Task` would exit on the release call's timeout instead of the `await` expiring
— and ISS-0220 would recur wearing a different stack trace.
`core-directives.md` §"Unblock-Everything" covers exactly this: a defect standing in
the way of the current fix actually landing is fixed here.

`release_call_timeout/0` returns `provision_timeout_ms()` — the *same* calibrated
number, deliberately, so no second uncalibrated constant is introduced. It is sized
for **one in-flight provisioning ahead of it in the mailbox**, which the measurements
show dominates the release path's real latency risk by two orders of magnitude over
the DROP itself. It is **not** sized for a full provisioning *plus* a pathological
DROP simultaneously; §9 INV-SP-T4 states that limit honestly rather than
over-claiming, and §12's successor issue is what actually removes it.

### 3.3 Alternatives considered and rejected

- **(A) Just raise `@call_timeout_buffer_ms` to 45_000.** Rejected. It leaves the
  same untestable, undocumented, unconfigurable magic constant in place, one edit
  away from the identical failure — and it gives the tests nothing to derive their
  own bounds from, so §8's second magic-number class (which produced 2 of the 11
  measured failures, §2.3 mechanism 2) survives untouched. The issue is not that the
  number is 5_000; it is that the number answers a question nobody asked it.
- **(B) Make `max_wait_ms` mean "total time including provisioning".** Rejected. It
  silently changes the meaning of a parameter on a shipped public API with an
  external caller (`Definitions.apply_promotion_assertion_rerun/6`'s own
  `max_wait_ms` argument), contradicts `req039-…md` §4.4 step 3 and `claim/2`'s
  `@doc`, and would make `claim(0, pool)` — used by three tests as a *deterministic
  immediate-rejection* probe (`sandbox_pool_test.exs:304, :331, :396`) — start
  timing out instead of returning `{:error, :sandbox_unavailable}`. That is changing
  what the tests measure, which `core-directives.md` §"Never Satisfy a Gate by
  Editing What It Measures" forbids outright.
- **(C) Per-pool `:provision_timeout_ms` option on `start_link/1`, mirroring
  `:max_concurrent`.** **Rejected — an amendment to the shape the handoff proposed.**
  `:max_concurrent` works as a `start_link/1` option because it is enforced
  *server-side*, in `handle_call/3`. The provisioning budget's whole job is to set a
  **client-side** `GenServer.call` timeout, and `claim/2` running in the caller
  process cannot learn a specific pool's server-side setting without a second
  `GenServer.call` — which would itself queue behind the very blocked mailbox the
  budget exists to survive (§12), and would still be racing the value it read. A
  `start_link/1` option here would be **dead configuration for the number that
  actually matters**, and a pool whose server-side budget silently disagrees with its
  callers' client-side derivation is a trap, not a feature. If a per-call override is
  ever genuinely needed, the coherent shape is an explicit caller-side argument
  (`claim/3`) — **OQ-2** (§16), not built now.
- **(D) Server-side enforcement: run provisioning under a `Task.yield/2` deadline and
  abort.** Rejected for this issue as materially larger and riskier — it requires
  slot bookkeeping across an async completion, which is exactly §12's successor
  issue. §5.3 states the consequence of not doing it.

---

## 4. The default: 45 000 ms, derived from measurement

**Constraint on this section, from the run's own task block:** the number is
justified from the measured distribution, never from "what made the run go green." No
value here was chosen by running the suite and seeing what passed. The number below
is **higher than the 30 000 ms both the handoff and ISSUE-FIXER proposed**; §4.5
states exactly why, on the strength of the n=40 direct measurement that superseded
the log-derived samples.

### 4.1 The measurements (ISSUE-FIXER's, attributed — see §0)

Two instruments. `scratch/provision_latency.awk` extracts, from a partition log, the
gap between `provision_sandbox/0`'s logged `CREATE SCHEMA "sandbox_X"` and the next
logged query naming the same `sandbox_X` — because `Ecto.Migrator.run/4` is invoked
with `log: false` (`sandbox_pool.ex:303`), that gap **is** the 31-migration replay.
`scratch/claim_latency.exs` measures the same thing far more directly and far more
cleanly: one BEAM, one pool at `max_concurrent: 1`, one claim at a time, `claim(600_000,
pool)` so a slow provision is measured rather than converted into an exit, timed with
`System.monotonic_time(:millisecond)`.

| Conditions | Instrument | n | min | median | max | > 5000 ms |
|---|---|---|---|---|---|---|
| **quiet host, single process** (`docker stats` confirmed idle) | direct probe | 20 | 918 ms | 1662 ms | **3621 ms** | 0/20 |
| **loaded host, single process** (sample A) | direct probe | 20 | 2112 ms | 3407 ms | **15 373 ms** | 3/20 |
| **loaded host, single process** (sample B) | direct probe | 20 | 1119 ms | 2471 ms | 8711 ms | 5/20 |
| loaded host, N=4 suite, partition 4 | log-derived | 5 | 4594 ms | 5596 ms | 12 053 ms | 3/5 |
| green N=4 suite, 2026-08-21 | log-derived | 26 | 897 ms | ≈1240 ms | 2302 ms | 0/26 |

Combined direct-probe measurement under load: **n=40, 8/40 = 20% of provisions exceed
the entire `claim(0)` budget of 5000 ms. Highest single observed provision across
every measurement: 15 373 ms.**

`DROP SCHEMA … CASCADE`, for completeness: 20–498 ms across the same 40 samples, max
687 ms under N=4 load. Used in §3.2 and §8.2.

### 4.2 Cold start is the relevant regime, and every test is in it

Sample B's raw series is the observation that decides *which* statistic to size
against. Claims 1–7 measured **7004, 3770, 5167, 3566, 5780, 8711, 5062 ms**; from
claim 10 onward it settles to **1119–2471 ms**. The expensive provisions are the
**first ones in a fresh process** — Postgres and OS caches cold for 31 migrations'
worth of DDL.

Every test file in this suite is in exactly that regime: a handful of claims, all of
them cold, in a freshly started BEAM. So the statistic to size against is the
**cold-start tail**, not the steady-state median. Sizing to a warm median is a
category error here, and it is close to the error `@call_timeout_buffer_ms` already
embodies.

### 4.3 What the current budget actually provides

| Reference | 5000 ms is… |
|---|---|
| quiet-host max (3621 ms) | **1.38×** |
| loaded-host max (15 373 ms) | **0.33×** — i.e. *below* the observed maximum |
| loaded-host distribution | exceeded by **20%** of provisions (8/40) |

A per-claim operation performing 32 sequential transactions has no business running
on 1.38× headroom over its own idle-host maximum, on a machine documented to be busy
(§2.2).

### 4.4 Bounds

**Floor 1 — the worst *legitimate* provisioning observed: 15 373 ms.** A budget at or
below this converts an observed-correct provisioning into a false failure. This is
the hard floor; everything below it is excluded outright.

**Floor 2 — one further excursion of the magnitude the data itself exhibits.** This
is what fixes the multiple rather than picking one by feel. The maximum of an n=20
window is itself a random variable, and we have two such windows measured under
nominally identical conditions: **15 373 ms and 8711 ms — the window maximum varies
by 1.76× between two runs of the same probe on the same host.** A budget that cannot
absorb the next window's maximum landing 1.76× above the worst one seen so far is
under-sized by the data's own demonstrated variability:

```
15 373 ms  ×  1.76  =  27 057 ms
```

So the budget must be **≥ ~27 060 ms**. This eliminates every tempting middle option:
15 000 ms (below floor 1 — it would have failed outright against an observed sample),
20 000 ms (1.30× floor 1, fails floor 2), and 25 000 ms (1.63× floor 1, still fails
floor 2).

**Ceiling — ExUnit's default per-test timeout, 60 000 ms (V5).** The provisioning
budget must stay meaningfully below it so ExUnit's own timeout remains the outer
bound and a genuinely stuck claim is reported as a legible `claim/2` timeout rather
than pre-empting, or being pre-empted by, the framework's deadline. Per **C2**,
`:ownership_timeout` (120 000 ms, and inactive under `:auto` mode anyway) is **not** a
ceiling here and is not used as one.

### 4.5 Decision: 45 000 ms

```
floor  (§4.4 floor 2):    ≥ 27 060 ms
ceiling(§4.4):            <  60 000 ms
chosen:                      45 000 ms
```

Its multiples:

| Reference | Multiple at 45 000 ms |
|---|---|
| quiet-host median (1662 ms) | **27.1×** |
| quiet-host max (3621 ms) | **12.4×** |
| green N=4 max (2302 ms) | **19.5×** |
| N=4 partition-4 max (12 053 ms) | **3.73×** |
| **highest observed sample (15 373 ms)** | **2.93×** |
| floor 2 (27 057 ms) | **1.66×** |
| ExUnit per-test ceiling (60 000 ms) | **0.75×** |

Per-migration sanity check on the mechanism rather than the statistics: 31 migrations
/ 32 transactions. Quiet-host median ≈ 54 ms per migration; the worst observed sample
≈ 496 ms per migration (≈9× degradation); a 45 000 ms budget tolerates ≈1450 ms per
migration, ≈27× the quiet-host per-migration cost. For a `CREATE TABLE`-shaped DDL
statement in its own transaction against a local containerised Postgres, ~1.4 s per
statement is a generous but not absurd ceiling.

**Why 45 000 and not the 30 000 both the handoff and ISSUE-FIXER proposed.** 30 000
clears floor 2 by only 11% (30 000 / 27 057 = 1.11×), and floor 2 is itself derived
from a two-sample comparison of window maxima — a soft estimate that deserves margin,
not a tight fit. 45 000 clears it by 66% while still leaving the ExUnit ceiling a
clear 15 000 ms of separation. ISSUE-FIXER explicitly invited this re-derivation
("I would rather ship your derivation than my guess") after its own direct probe
raised the observed maximum from 12 053 ms to 15 373 ms, which cut its stated 2.5×
multiple to ~1.95× — below what its own new data supports.

**Why not higher still (55 000).** It would erode the ExUnit ceiling's separation to
5000 ms without buying tail coverage the data justifies: 55 000 is 3.58× the observed
maximum, and nothing in the distribution asks for that.

**Why the asymmetry favours the larger of two defensible values.** Per §2.4 the
budget is the *only* deadline in the whole path. Sizing it too small produces false
failures on correct work — the actual issue, 9 of the 11 measured failures. Sizing it
too large costs only *failure legibility* in an already-pathological case: a hung
provisioning surfaces at 45 s as a claim timeout instead of at 30 s, and in either
case ExUnit's 60 s catches it. False failures are the expensive error here; late
detection of a genuine hang is the cheap one.

### 4.6 The one consequence this choice accepts, stated explicitly

At 45 000 ms, a single test performing **two** pathological provisionings reaches
ExUnit's 60 000 ms per-test timeout before the second claim's own timeout fires, so it
would fail as an ExUnit test timeout rather than as a clean claim timeout. Two tests
can do this: `sandbox_pool_test.exs:319` (claim → release → claim) and `:367`
(claim → kill → claim).

This is a **failure-legibility** cost in an already-pathological case, not a
correctness one — both outcomes are failures, neither is a false pass. It is
**not** a reason to choose a lower value: the property is already lost at 30 000
(2 × 30 000 = 60 000, exactly the ceiling), so it cannot discriminate between the
candidates, while floor 2 excludes everything low enough to preserve it.

If it is ever observed for real, the correct response is `@moduletag timeout: <n>` on
that file — which raises a *framework* deadline, not an assertion — **not** lowering
the budget. Deliberately **not** applied pre-emptively: there is no evidence it has
occurred (the measured failure set contains zero ExUnit test timeouts), and adding an
untriggered tag now would be a speculative change to a file this fix is otherwise
touching surgically.

---

## 5. `Letflow.SandboxPool` — public interface

### 5.1 New public functions

```
@doc """
The configured per-provisioning budget, in milliseconds: how long one sandbox
schema may take to CREATE + migrate before a caller gives up. Derived from
measurement in lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md §4 --
do not change this number without redoing that derivation.
"""
@spec provision_timeout_ms() :: pos_integer()

@doc """
The GenServer.call/3 timeout claim/2 uses for a given max_wait_ms:
`max_wait_ms + provision_timeout_ms()`. Public so callers and tests derive their
own bounds from this one source of truth rather than re-deriving a second
constant that can drift (ISS-0220).
"""
@spec claim_call_timeout(max_wait_ms :: non_neg_integer()) :: pos_integer()

@doc """
The GenServer.call/3 timeout release/2 uses: `provision_timeout_ms()` -- sized
for one in-flight provisioning ahead of it in the pool's mailbox, not for the
DROP itself. See the design doc's §3.2.
"""
@spec release_call_timeout() :: pos_integer()
```

`claim_call_timeout/1` guards `is_integer(max_wait_ms) and max_wait_ms >= 0`, matching
`claim/2`'s existing guard exactly.

### 5.2 Unchanged public `@spec`s — stated so a reviewer can confirm no API drift

`start_link/1`, `claim/2`, `release/2` keep their current `@spec`s **byte-for-byte**.
No new argument, no new return value, no new error atom. `max_wait_ms`'s meaning, its
guard, and its `Process.send_after` timer are untouched. The only change to
`claim/2`/`release/2` is which integer is passed as `GenServer.call/3`'s third
argument.

### 5.3 `provision_timeout_ms/0` is a caller-side allowance, not a server-side abort

Stated plainly so the name cannot mislead: **nothing aborts a slow provisioning.** Per
V4, `Ecto.Migrator` runs with `timeout: :infinity` throughout; when the budget
elapses, the *caller* exits with `{:timeout, {GenServer, :call, …}}` while the pool
keeps provisioning to completion.

The name `:provision_timeout_ms` is kept (over `:provision_budget_ms`) because it is
accurate about the only thing any caller can observe — the caller does time out — and
because it matches the vocabulary of every other `*_timeout` in this codebase. The
non-enforcement is documented in the `@doc` and in the moduledoc section §7.4, not
encoded in the name.

**What happens to an abandoned provisioning, unchanged by this fix and re-verified
here:** `handle_provision_now/2` completes, `Process.monitor(elem(from, 0))` runs
against a caller that may already be dead — in which case `:erlang.monitor/2` delivers
`{:DOWN, ref, :process, pid, :noproc}` immediately, `handle_info/2`'s
`find_active_by_owner_ref/2` branch (`sandbox_pool.ex:184-192`) matches, and the schema
is dropped. So an abandoned claim from a *dead* caller self-reclaims via ISS-0048's
mechanism. A caller that survives its own timeout exit (i.e. wrapped it in
`catch_exit`) instead strands the schema until it dies — and per **V13** nothing
sweeps `sandbox_%` schemas. Pre-existing behaviour, unchanged here, and the reason
§10's regression test is designed to create **zero** schemas.

---

## 6. Config shape

```
# lib/letflow/sandbox_pool.ex
@default_provision_timeout_ms 45_000
```

```
# optional override, in any config/*.exs -- NOT added to any of them by this fix
config :letflow, :sandbox_pool,
  max_concurrent_sandboxes: 1,
  provision_timeout_ms: 45_000
```

**Resolution order, normative:**

```
provision_timeout_ms() =
  CASE Application.get_env(:letflow, :sandbox_pool)[:provision_timeout_ms]
    nil                            -> @default_provision_timeout_ms
    n WHEN is_integer(n) AND n > 0 -> n
    other                          -> raise ArgumentError naming :provision_timeout_ms,
                                            the offending value, and this design doc
  END
```

**Why `Application.get_env` + a code default, and not `fetch_env!` like
`max_concurrent_sandboxes`.** Three reasons; the divergence from the sibling key is
deliberate:

1. The default is a *derived* number whose derivation lives in §4 of this document and
   in the module's own `@doc`. Putting the literal in three config files triplicates
   it away from its justification — which is how a number stops being re-derived and
   starts being inherited (`docs/anti-patterns.md`, "Inheriting a claim from a record
   instead of re-deriving it from the source"). That is precisely how
   `@call_timeout_buffer_ms` survived unexamined for four months.
2. `fetch_env!` on a newly introduced key turns any config surface not yet defining it
   into a `KeyError` at claim time — a new crash class introduced by a fix whose whole
   purpose is removing a spurious crash class.
3. It makes §10's RT-4 non-trivial: with the key absent everywhere by default, "the
   default is in force" is a real, observable property of a real call rather than a
   restatement of a config file.

**No floor clamp**, deliberately: §10's regression test must be able to configure a
*deliberately tiny* budget (1234 ms) to observe the override end-to-end in
milliseconds. A minimum-value clamp would defeat exactly that test. Validation is
type-only (positive integer), catching the misconfiguration class that matters
(`"45000"`, `nil`, `45.0`) without prohibiting a legitimate small value.

---

## 7. Changes to `lib/letflow/sandbox_pool.ex` (prose, not code)

### 7.1 Delete `@call_timeout_buffer_ms` and its comment (`:67-77`)

Both are superseded. The comment's *live* content — that `GenServer.call`'s own default
5_000 ms would raise a caller-side `:timeout` before the pool ever replies if
`max_wait_ms` exceeds it — is preserved by `claim_call_timeout/1`'s `@doc` and by the
moduledoc section in §7.4. Nothing that comment asserted is lost; what is removed is
the constant that answered a different question.

### 7.2 `claim/2`

```
GenServer.call(pool, {:claim, max_wait_ms}, claim_call_timeout(max_wait_ms))
```

Body, guard, `@spec`, and the rest of `@doc` unchanged. Add to `claim/2`'s `@doc` one
short paragraph naming the two budgets and pointing at `claim_call_timeout/1`. **This
single line fixes all 9 mechanism-(1) failures in §2.3.**

### 7.3 `release/2`

```
GenServer.call(pool, {:release, sandbox_id}, release_call_timeout())
```

Previously the two-argument `GenServer.call/2` form (implicit 5_000 ms). `@spec` and
the rest of `@doc` unchanged; add one sentence naming `release_call_timeout/0` and why
the release path needs a budget at all (§3.2).

### 7.4 New moduledoc section

Add a section titled **"Two budgets: queue wait vs. provisioning"** stating, in prose:
that `max_wait_ms` bounds queue parking only; that `provision_timeout_ms/0` bounds one
provisioning; that the two are summed for `claim/2`'s call timeout and that `release/2`
uses the provisioning budget alone (and why — head-of-line blocking, not DROP cost);
that the budget is a **caller-side** allowance and not a server-side abort (§5.3); and
that the default is derived in
`lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §4, with an explicit
"do not change this number without redoing that derivation."

The existing moduledoc sections ("Process-per-instance vs. row-based state",
"Same-process claim/release contract") are **not** modified.

### 7.5 No change to any `handle_call/3`, `handle_info/2`, or private function

`handle_provision_now/2`, `handle_queue_or_reject/3`, `service_next_waiter/1`,
`find_waiter/2`, `remove_waiter/2`, `find_active_by_owner_ref/2`,
`provision_sandbox/0`, and `drop_schema/1` are untouched. The GenServer state shape
(`%{max_concurrent:, active:, waiting:}`) is untouched. This fix is entirely in the
client half of the module.

---

## 8. Test-side rendezvous bounds — re-sized from the same source of truth

### 8.0 HARD CONSTRAINT — what is and is not changing

**Every assertion stays intact.** Nothing in this section removes a test, skips one,
tag-excludes one, serializes one away, weakens a pattern, relaxes an equality, or
converts an `assert` into a `refute`/`assert_raise`. `async: false` is neither added
nor removed anywhere; the `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` setup
that the file's moduledoc justifies at length is untouched.

After this change each test still proves *exactly* what it proves today:

- the queued waiter **is** served once the held slot frees (`:262`), with a
  **different** sandbox id (`:268`) and a **real** schema in
  `information_schema.schemata` (`:269`);
- the killed owner's schema **is** dropped for real (`:407-408`) and its quota slot
  **is** freed (`:412-419`);
- the held claim **is** untouched by a timed-out waiter (`:291`);
- `max_wait_ms <= 0` **is** rejected without ever queueing (`:304-306`).

**Only the "how long may the correct answer take to arrive" bound moves, and only to a
value derived from measurement.** This is stated here because a reviewer reading a diff
of raised timeouts, absent this paragraph, would be right to suspect a weakened test.
A rendezvous bound is not an assertion about the system under test; it is the patience
of the observer. What ISS-0220 proved is that these observers were less patient than
the operation they were observing — `:387`'s 2000 ms bound is **0.55×** the quiet-host
maximum (3621 ms) for the very operation it waits on, i.e. it was miscalibrated on an
*idle* machine, before any host load or test parallelism entered the picture at all.

### 8.1 Two derived helpers in `sandbox_pool_test.exs`

```
@rendezvous_slack_ms 1_000

defp claim_rendezvous_timeout(max_wait_ms)   # SandboxPool.claim_call_timeout(max_wait_ms) + @rendezvous_slack_ms
defp pool_op_rendezvous_timeout()            # SandboxPool.release_call_timeout()          + @rendezvous_slack_ms
```

`@rendezvous_slack_ms` covers what happens *after* the pool call returns and before the
waiting side observes it: one BEAM message hop, the spawned process's own `assert`,
and (for `:249`) one `schema_exists?/1` round trip. Its real cost is sub-millisecond to
low-milliseconds; 1000 ms is three orders of magnitude of slack and performs **no
provisioning-cost work whatsoever** — that job belongs entirely to
`SandboxPool.provision_timeout_ms()`. It is deliberately a separate, visibly small
constant rather than folded into the budget, so it can never quietly become a second
un-derived provisioning allowance. **This is the one new magic number this design
introduces, and this paragraph is its justification.**

Both helpers are runtime expressions, and V6 confirms empirically that
`assert_receive/2,3`, `receive … after`, and `Task.await/2` all accept a runtime
timeout expression in this toolchain (Elixir 1.20.3 / OTP 29) — verified rather than
assumed, because the whole approach depends on it.

### 8.2 The re-sizing table (normative — these five, and only these five)

| Site | Current | New | What the site waits for | Why the new bound is the right one |
|---|---|---|---|---|
| `:387` `assert_receive {:owner_claimed, …}, 2_000` | 2000 ms | `claim_rendezvous_timeout(1_000)` = 47 000 ms | a spawned owner's `claim(1_000, pool)` to complete and relay | **NOT fixed by the `claim/2` change** — one of the two measured mechanism-(2) failures (`SandboxPoolTest:367`, `no matching message after 2000ms`). 2000 ms is **0.55×** the quiet-host max (3621 ms) and **0.13×** the worst observed (15 373 ms) for the operation it waits on. |
| `:262` `assert_receive {:waiter_claimed, …}, 3_000` | 3000 ms | `claim_rendezvous_timeout(2_000)` = 48 000 ms | the queued waiter's `claim(2_000, pool)` to be served after `release(held_id)` frees the slot | The other measured mechanism-(2) failure (`SandboxPoolTest:216`, `no matching message after 3000ms`). The waited-on work is a full cold-start provisioning; the bound must be the claim budget, not a hand-picked 3000 (0.83× the quiet-host max). |
| `:249` waiter's `receive … after 3_000 -> flunk(…)` | 3000 ms | `pool_op_rendezvous_timeout()` = 46 000 ms | the **test process** to send `:release_waiter_claim`, which it does after `:262` succeeds plus two asserts and one `schema_exists?/1` query | Must not expire before the test process gets there. Derived from the pool-operation budget rather than inventing a "one Repo query" constant — one source of truth, generous in the safe direction (if the test process dies, `Task.async`'s link kills the waiter regardless, so an over-generous bound cannot hang the suite). |
| `:273` `Task.await(waiter, 3_000)` | 3000 ms | `pool_op_rendezvous_timeout()` = 46 000 ms | the waiter's own `SandboxPool.release/2` (mailbox wait + `DROP … CASCADE`) plus its return | Release-only: `:262` has already succeeded, so no provisioning remains *for this caller* — but the pool may still be busy. Pairs exactly with §3.2's `release_call_timeout/0`; raising this bound without §3.2 would only relocate the failure into the release call. |
| `:130` `wait_until_schema_dropped(schema_name, attempts \\ 400)` | 400 × 5 ms = 2000 ms | **deadline-based**, default `SandboxPool.release_call_timeout()` = 45 000 ms | the pool's `handle_info({:DOWN, …})` reclaim to finish a `DROP SCHEMA … CASCADE` over a 31-table schema | Measured DROP cost is 20–498 ms (max 687 ms under load), so the DROP itself fits inside 2000 ms — but the reclaim runs on the pool's own mailbox, which may be blocked by an in-flight provisioning (§12), and *that* is what 2000 ms cannot absorb. Also convert attempts→deadline: an attempt count is an implicit time bound that silently changes meaning if the poll interval ever changes. Use `System.monotonic_time(:millisecond)` with the existing 5 ms poll interval. **`flunk/1` on expiry is retained verbatim.** |

Derived values shown at the 45 000 ms default; every one tracks a config override
automatically, which is the point of deriving them.

### 8.3 Two bounds in the same file deliberately NOT changed

Named explicitly so their absence from §8.2 reads as a decision, not an omission.
Neither appears in the measured failure set (§2.3).

- **`:107` `wait_until_waiter_queued(pool, attempts \\ 200)` (1000 ms).** Waits only for
  a `Task`'s `claim/2` message to reach the pool's mailbox and be appended to
  `waiting`. At that moment the pool is **idle** — the held claim was provisioned
  before the `Task` was spawned, and `handle_queue_or_reject/3` on the no-free-slot
  path issues no SQL at all (`sandbox_pool.ex:226-231`). So this bound covers one
  process spawn plus one `GenServer.call` round trip against an idle process.
- **`:402` `assert_receive {:DOWN, ^owner_monitor_ref, …, :killed}, 2_000`.** Waits for
  the BEAM's own monitor message after `Process.exit(owner_pid, :kill)` — no database,
  no pool interaction, delivered by the runtime.

### 8.4 The other two affected test files need no edits — checked against the measured failure set

- **`test/letflow/sandbox_pool/fixture_loader_test.exs`.** Its only bound is
  `SandboxPool.claim(2_000, pool)` inside `claim_schema!/0` (`:63`), whose call timeout
  rises from 7000 to 47 000 by §7.2 alone. Its measured failure (`:170`) is a
  mechanism-(1) `GenServer.call(pid, {:claim, 2000}, 7000)` timeout — a library
  failure, not a test-side bound. The file contains no `assert_receive`, no
  `Task.await`, no `receive … after`, and no polling helper (grepped). **No edit.**
- **`test/letflow/definitions/promotion_assertion_rerun_test.exs`.** Its eight `2_000`
  literals are `max_wait_ms` *arguments* to `apply_promotion_assertion_rerun/6`,
  reaching `SandboxPool.claim(2_000, pool)` — likewise covered by §7.2, and all five of
  its measured failures (`:394, :479, :527, :617, :760`) are mechanism-(1)
  `GenServer.call(pid, {:claim, 2000}, 7000)` timeouts. Its `assert_receive …, 1_000`
  sites (`:512, :594, :641`) all wait on messages **already sent during the synchronous
  call that has already returned**, so they are mailbox reads, not rendezvous. The file
  spawns no process (grepped). **No edit.**

The measured decomposition therefore confirms §8.2's list is exhaustive: **11 failures
= 9 fixed by one line in `claim/2` + 2 fixed by two bounds in one test file**, and
those 2 are exactly `:387` and `:262`.

---

## 9. New and changed invariants

- **INV-SP-T1.** `claim/2`'s `GenServer.call` timeout is always exactly
  `claim_call_timeout(max_wait_ms)`, which is always exactly
  `max_wait_ms + provision_timeout_ms()`. No caller-observable timeout in this module
  is a literal.
- **INV-SP-T2.** `release/2`'s `GenServer.call` timeout is always exactly
  `release_call_timeout()`, which is always exactly `provision_timeout_ms()`. In
  particular it is **never** `GenServer.call/2`'s implicit 5_000 ms default.
- **INV-SP-T3.** `provision_timeout_ms()` returns a positive integer or raises
  `ArgumentError`; it never returns `nil`, a float, or a string.
- **INV-SP-T4 (stated limit, not a guarantee).** These budgets bound **one**
  provisioning per call. They do **not** bound total `claim/2` latency when several
  callers contend for a pool whose mailbox is serialized behind in-flight
  provisionings: with `max_concurrent: c` and *c* simultaneous claims against free
  slots, the *c*-th caller's real latency approaches *c* × provisioning, none of which
  is counted in `max_wait_ms` (those callers are in the pool's **mailbox**, not its
  `waiting` queue). This is §12's successor issue. It does not affect the three test
  files at issue — `sandbox_pool_test.exs` and `promotion_assertion_rerun_test.exs` use
  per-test pools with at most one claim in flight, and `config/test.exs` pins the
  application singleton to `max_concurrent_sandboxes: 1`.
- **INV-SP-T5.** `max_wait_ms`'s meaning is unchanged: it bounds queue parking only,
  and `claim(0, pool)` against an exhausted pool still returns
  `{:error, :sandbox_unavailable}` immediately, without queueing and without any
  timeout being involved. Three existing tests depend on this (`:304-306`, `:331`,
  `:396`) and none may change.
- **INV-SP-2, INV-SP-3, INV-SP-5, INV-SP-6, INV-SP-7** (`req039-…md` §4.7) and
  **INV-SP-DOWN-1/2/3** (`iss-0048-…md` §6) are **unaffected** — no state-shape, quota,
  provisioning, or reclaim logic is touched (§7.5).

---

## 10. Regression-test contract (TEST-DESIGNER implements; this section specifies it)

### 10.1 The trap this contract is designed around

This fix **changes existing behaviour** rather than adding a module, so WF-03 Step 4's
ordinary fail-then-pass rule applies. But the obvious test — asserting the new constant
equals the new constant — is vacuous: it would pass against any value the
implementation happened to pick, including a wrong one, and would fail pre-fix only
because a function does not exist yet (a compile error, not a behavioural
demonstration).

**The contract below pins the derived number where it is actually consumed: inside a
real `GenServer.call/3`'s own timeout exit reason.** V7 confirms empirically that
`GenServer.call/3` exits with `{:timeout, {GenServer, :call, [server, request,
timeout]}}` — the third list element **is** the integer the client computed. Observing
it is a direct behavioural observation of the derivation, not a restatement of it.

### 10.2 Placement and shape

**New file: `test/letflow/sandbox_pool_call_timeout_test.exs`**, using
`ExUnit.Case, async: false` — **not** `Letflow.DataCase`.

- `async: false` because RT-2/RT-3 mutate `Application.env` at runtime, which
  `config/test.exs`'s own `jit-disabled-test-realm` comment already establishes is
  unsafe under `async: true` in this repo.
- **No `Letflow.DataCase` and no Postgres at all**, deliberately: the whole contract is
  about a *client-side* computation, and the black-hole technique below reaches it
  without a pool, without a schema, and without a connection. That independence is
  worth preserving in its own file rather than burying inside `sandbox_pool_test.exs`,
  which would drag in the `:auto`-mode switch its moduledoc spends 40 lines justifying
  and would obscure that this test needs none of it.

**The black-hole technique.** `claim/2`'s `pool` argument is a `GenServer.server()` —
any pid. A process that receives and never replies
(`spawn(fn -> Process.sleep(:infinity) end)`) makes `GenServer.call/3` run to its full
timeout **deterministically**, with:

- **zero** schemas created — nothing to clean up, and per **V13** nothing would sweep a
  leaked `sandbox_%` schema if there were;
- **zero** dependence on real provisioning latency — the test's runtime is exactly the
  tiny configured budget, so it is fast and cannot itself become flaky under the very
  host load ISS-0220 is about (a test for a timing defect that is itself timing-
  sensitive would be self-defeating);
- **zero** stale-reply pollution, since `catch_exit/1` keeps the exit inside the
  assertion and no reply is ever sent.

Rejected alternatives, for the record: `:sys.suspend/1` on a real pool leaves the
`{:"$gen_call", …}` message queued for after `:sys.resume/1`, provisioning a sandbox
for a dead caller; and letting a real provisioning race a tiny budget makes the test
depend on the very distribution it is meant to be independent of.

### 10.3 The four required cases

**RT-1 — the derivation is a function of the configured budget.**
Assert `claim_call_timeout(w) == w + provision_timeout_ms()` for
`w ∈ {0, 1, 1_000, 2_000, 60_000}`, and `release_call_timeout() == provision_timeout_ms()`.
*Pre-fix:* the functions do not exist → fails.
*Non-vacuity:* on its own this IS the tautology §10.1 warns about. It is included only
as a drift guard on the two derivations and is meaningful **only in combination with
RT-2/RT-3**, which observe the same numbers behaviourally. Say so in the test's own
comment so a future reader does not mistake it for the substance of the contract.

**RT-2 — a config override is honoured end-to-end by a real `claim/2` call.**

```
setup:   capture the ORIGINAL Application.get_env(:letflow, :sandbox_pool) keyword list
         Application.put_env(:letflow, :sandbox_pool,
             Keyword.put(original, :provision_timeout_ms, 1_234))
         on_exit -> Application.put_env restoring the captured original exactly

body:    hole = a process that receives and never replies
         assert {:timeout, {GenServer, :call, [^hole, {:claim, 0}, 1_234]}} =
                  catch_exit(SandboxPool.claim(0, hole))
         assert {:timeout, {GenServer, :call, [^hole, {:claim, 2_000}, 3_234]}} =
                  catch_exit(SandboxPool.claim(2_000, hole))
```

*Pre-fix:* the computed timeouts are `0 + 5_000 = 5_000` and `2_000 + 5_000 = 7_000`;
both pattern matches fail against the literals `1_234` / `3_234`. **This is a
behavioural fail-then-pass, not a compile error** — the assertion is written against
literals derived from the config value the test itself sets, so it does not depend on
any new function existing.
*Non-vacuity:* it observes the real public `claim/2` making a real `GenServer.call/3`,
and pins both that the override reaches the client **and** that `max_wait_ms` is *added
to* rather than *replaced by* the budget — the second assertion is what makes `1_234`
vs `3_234` discriminating.
*Deliberate:* `1_234` is a distinctive non-round value, so a passing match cannot be a
coincidence of some other default.

**RT-3 — `release/2` uses the budget, not `GenServer`'s 5_000 ms default.**
Same override and same black hole:

```
assert {:timeout, {GenServer, :call, [^hole, {:release, ^some_uuid}, 1_234]}} =
         catch_exit(SandboxPool.release(some_uuid, hole))
```

*Pre-fix:* the third element is `5_000` → fails. This pins §3.2 — the mis-sizing nobody
named; without RT-3 nothing prevents `release/2` silently reverting to
`GenServer.call/2`.

**RT-4 — the shipped default is in force, and is under the ceiling.**
With **no** `:provision_timeout_ms` key present (the shipped state per §6):

```
assert SandboxPool.provision_timeout_ms() == 45_000
assert SandboxPool.provision_timeout_ms() < 60_000     # ExUnit's per-test ceiling, §4.4
assert SandboxPool.provision_timeout_ms() > 15_373     # the highest observed provisioning, §4.1
```

The first assertion is an honest change-detector — justified *only* because this entire
issue is a number silently left un-sized, and required to carry a comment naming
`lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §4 so that changing it
forces re-reading the derivation. The second and third are genuine properties, not
tautologies: they fail if anyone later raises the budget past the point where it would
pre-empt ExUnit's own deadline, or lowers it back below a provisioning latency this
project has actually measured.

### 10.4 Also required of TEST-DESIGNER

- **`test/specs/ISS-0220.md`**, following the `test/specs/ISS-0048.md` precedent: case
  rationale, pre-fix/post-fix expectation per case, and the §8.0 statement that no
  existing assertion was weakened.
- **The pre-fix demonstration must be run and its real output quoted** in the WF-03
  Step 4 report — `core-directives.md` §"No Speculation" applies without exception on
  this run. RT-2/RT-3/RT-4 are runnable against pre-fix code as written (they use no
  new function), so this is a real fail-then-pass demonstration, not an assertion that
  one would occur.
- **Do NOT add a test that runs the suite at `TEST_PARALLEL_N=4`** to "prove" ISS-0220
  is fixed. That is a load-dependent, non-deterministic observation with a ~20-minute
  cost, and RT-1..RT-4 pin the actual defect deterministically in milliseconds. Note
  further that ISSUE-FIXER's own quiet-host measurement (0/20 provisions over 5000 ms)
  means **a green N=4 run on a quiet host would prove nothing pre- or post-fix** — the
  verification has to be against measured provisioning latency, not against a green
  run. That is RELEASE-VALIDATOR's problem to solve, not a unit test's.

---

## 11. What ELIXIR-DEV must NOT change

1. **`max_wait_ms`'s semantics, guard, `@spec`, or its `Process.send_after` timer.**
   INV-SP-T5.
2. **Any `handle_call/3`, `handle_info/2`, or private function in `sandbox_pool.ex`**
   (§7.5). If the fix seems to require one, stop — that is §12's issue, not this one.
3. **The GenServer state shape.**
4. **Any assertion, `describe`, `test`, `async:` setting, or the `:auto`-mode setup in
   the three affected test files.** Only the five bounds in §8.2.
5. **`config/dev.exs`, `config/prod.exs`, `config/test.exs`** — including
   `max_concurrent_sandboxes: 1` in test config, which `sandbox_pool_test.exs`'s
   moduledoc explicitly relies on.
6. **`docs/migration/decisions/0009-test-parallel-pool-sizing.md`** — §13.
7. **`Letflow.Definitions.apply_promotion_assertion_rerun/6`'s signature**, including
   its `max_wait_ms` argument. It keeps meaning queue wait; it is fixed transitively.
8. **`Ecto.Migrator.run/4`'s options in `provision_sandbox/0`** — in particular do not
   add a `:timeout`; V4 shows the surrounding machinery pins `:infinity` at three levels
   and a partial override there would be misleading rather than effective.

---

## 12. Successor issue to file: provisioning blocks the pool's mailbox

**Not fixed here. Report to ORCH for `register_task` per
`docs/agents/protocols/ISSUE_QUEUE.md`** — the discovering agent does not allocate an id
or call `gh` itself.

**Title:** `SandboxPool: provision_sandbox/0 inside handle_call/3 blocks the pool
mailbox, so max_wait_ms is not honoured under contention`

**Statement.** `provision_sandbox/0` runs synchronously inside `handle_call/3`
(`sandbox_pool.ex:202-218`) and inside `service_next_waiter/1` (`:243`). While it runs,
the pool processes **no** messages — including a queued waiter's own
`{:claim_timeout, caller_ref}` timer message (`:165`). A waiter whose window elapses
during someone else's provisioning is therefore replied to late, by up to one full
provisioning — **measured at up to 15 373 ms**, against `max_wait_ms` values callers
routinely set to 1000–2000 ms. Since `max_wait_ms` is documented as the bound on that
wait (`claim/2`'s `@doc`, `req039-…md` §4.4 step 3), this is a genuine violation of a
documented contract, not a quality-of-service nicety. It is also why INV-SP-T4 must be
stated as a limit rather than a guarantee, and why §3.2's `release_call_timeout/0` has
to absorb a possible in-flight provisioning ahead of it.

**Why it is deliberately scoped out of ISS-0220.** The fix means moving provisioning
into a monitored `Task` and carrying slot bookkeeping across an asynchronous
completion: reserving the slot before provisioning starts, releasing the reservation on
`Task` failure, handling an owner that dies *during* provisioning (whose monitor does
not exist yet), and replying to a `from` held across callbacks. That touches every
invariant in `req039-…md` §4.7 and every one in `iss-0048-…md` §6 — exactly the state
machine §7.5 forbids this fix from touching. ISS-0220 is a false-failure-under-load
defect fixable entirely in the client half of the module, and mixing the two would make
both harder to review and to revert independently.

**Severity:** medium. Not currently observable as a test failure — every current caller
uses a pool with at most one claim in flight (INV-SP-T4) — but a real contract
violation that will surface the moment a caller drives a pool with
`max_concurrent > 1` concurrently.

---

## 13. Decision-record consistency: 0009 is not the mechanism, and needs no amendment

Recorded explicitly, per the run's own task block, so a later reader does not
re-suspect it.

`docs/migration/decisions/0009-test-parallel-pool-sizing.md`'s clamp is **working
exactly as designed** at N=4. Re-derived here (V12): `budget = 100 - 10 = 90`;
`computed = 90 / 4 = 22`; `TEST_POOL_SIZE = 22` with no floor clamp; total demand
`4 × 22 = 88 ≤ 90`. Nothing in ISS-0220's measured failure set is a connection refusal
or a `:queue_timeout`; all 11 failures decompose into 9 caller-side `GenServer.call`
timeouts and 2 test-side rendezvous bounds (§2.3).

**The decisive evidence is §2.2's zero-parallelism probe:** a single BEAM, a single
pool, one claim at a time — no partitions, no siblings, nothing to contend for — still
exceeds the 5000 ms budget in 20% of provisions (8/40). A pool-sizing decision cannot
be the mechanism behind a failure reproducible with a pool of one.

**One genuine interaction worth recording, found while checking this and not previously
written down anywhere:** `Ecto.Adapters.Postgres.lock_for_migrations/3` **raises**
outright if the repo's `:pool_size` is exactly 1 (V14, `postgres.ex:310-312`) — every
`SandboxPool.claim/2` would fail with `{:error, :provision_failed}`, since
`provision_sandbox/0`'s `rescue` swallows the exception. 0009's `TEST_MIN_POOL_SIZE`
floor of **2** is therefore load-bearing for sandbox provisioning specifically, not
merely the graceful-degradation nicety 0009's own "Why a floor rather than a hard
failure" paragraph frames it as. This is a **strengthening observation about an
existing record, not a contradiction of it** — 0009's chosen floor is correct, and
correct for one more reason than it knew. Per `core-directives.md` ("Don't silently
re-decide what a decision record already settled") no amendment is proposed and no
REVIEWER sign-off is required, because nothing 0009 decided is being changed.
Recommend REVIEWER consider appending this observation to 0009's "What this does not
change" section in a later docs-only run.

**No new decision record is proposed for ISS-0220 itself.** It settles a tuning
constant with a measured derivation inside one module, contradicts no existing record,
and introduces no framework or library choice — `docs/migration/decisions/` is for the
latter class. This design document is the durable home of the derivation, and §7.4's
moduledoc section is the in-code pointer to it.

---

## 14. Files the implementation must touch

| File | Change | Owner |
|---|---|---|
| `lib/letflow/sandbox_pool.ex` | Delete `@call_timeout_buffer_ms` + comment (§7.1). Add `@default_provision_timeout_ms 45_000`. Add public `provision_timeout_ms/0`, `claim_call_timeout/1`, `release_call_timeout/0` with `@spec`s + `@doc`s (§5.1, §6). Change `claim/2`'s and `release/2`'s `GenServer.call` timeout arguments (§7.2, §7.3). Add the moduledoc section (§7.4). | ELIXIR-DEV |
| `test/letflow/sandbox_pool_test.exs` | Add `@rendezvous_slack_ms` + the two derived helpers (§8.1). Re-size the five bounds in §8.2, including converting `wait_until_schema_dropped/2` to a deadline. **No assertion changes** (§8.0). | ELIXIR-DEV (mechanical, per §8.2) |
| `test/letflow/sandbox_pool_call_timeout_test.exs` | **New.** RT-1..RT-4 (§10). | TEST-DESIGNER |
| `test/specs/ISS-0220.md` | **New.** Case rationale + the §8.0 no-weakening statement (§10.4). | TEST-DESIGNER |
| `docs/issues/ISS-0220.yaml` | Written by ORCH from the `register_task` response per `ISSUE_QUEUE.md`. Not present in this worktree (§0). | ORCH |

**Explicitly NOT touched:** `config/*.exs`, `lib/letflow/definitions.ex`,
`lib/letflow/tenant_provisioning.ex`, `lib/letflow/application.ex`,
`test/letflow/sandbox_pool/fixture_loader_test.exs`,
`test/letflow/definitions/promotion_assertion_rerun_test.exs`,
`docs/migration/decisions/0009-test-parallel-pool-sizing.md`,
`lib/letflow/design/req039-sandbox-pool-fixture-loader.md`.

**Scratch artefacts produced by this design step** (git-ignored per
`core-directives.md` §"File Placement Rules", safe to delete):
`scratch/iss0220_assert_receive_probe.exs`, `scratch/iss0220_exunit_defaults.exs`,
`scratch/iss0220_exit_shape_probe.exs` — the three probes behind V5, V6, V7.

---

## 15. Acceptance-criteria traceability

The issue record was not available in this worktree (§0), so the criteria are taken
verbatim from this run's own `task` block (rank 1 of `core-directives.md`'s Instruction
Precedence chain), which enumerated five, plus its closing instruction.

| # | Criterion | Where satisfied | Concrete element |
|---|---|---|---|
| 1 | Split the two budgets `claim/2` conflates; `max_wait_ms` keeps its meaning; introduce a configurable provisioning budget; call timeout becomes the sum; expose the derivation publicly so tests derive from one source of truth | §3.1, §5.1, §6, §7.2 | `provision_timeout_ms/0`, `claim_call_timeout/1`, `release_call_timeout/0`; `config :letflow, :sandbox_pool, provision_timeout_ms:`; INV-SP-T1/T2/T5 |
| 1a | *(sub-decision)* per-pool override via `start_link/1` — "if that is coherent with the existing `:max_concurrent` precedent" | §3.3 (C) | **Rejected with reasons** — not coherent: the budget is consumed client-side, `:max_concurrent` server-side. Deferred as OQ-2. |
| 2 | Justify the default from the measurements, never from "what made the run go green"; state the number, the distribution, the multiples, the ceiling | §4 (all), §4.5 tables | **45 000 ms**; floor 27 057 ms from the data's own 1.76× window-maximum variability; ceiling 60 000 ms (ExUnit); 27.1× quiet median, 12.4× quiet max, 2.93× the highest observed sample, 0.75× ceiling |
| 3 | Re-size the test-side bounds from the same source of truth; every assertion stays intact; say so explicitly | §8.0, §8.1, §8.2, §8.3, §8.4 | five sites re-sized via `claim_rendezvous_timeout/1` / `pool_op_rendezvous_timeout/0`; §8.0's explicit no-weakening statement; two bounds deliberately unchanged with reasons; two files verified to need no edit, cross-checked against the measured failure decomposition |
| 4 | Name but do not fix the adjacent defect (provisioning blocks the mailbox); recommend a successor issue with reasoning | §12, INV-SP-T4 | successor-issue title, statement, why-scoped-out, severity; INV-SP-T4 states the limit rather than over-claiming a bound |
| 5 | Specify a regression-test contract that fails pre-fix and passes post-fix, and is not vacuous | §10 (all) | RT-1..RT-4; black-hole + `catch_exit` technique; RT-2/RT-3 pin the derived integer inside the real call's own exit reason (V7) and fail pre-fix **behaviourally**, not by compile error; RT-4's ceiling/floor assertions are real properties |
| 6 | *(closing instruction)* report anything in the diagnosis that is wrong | §2.5 | **C1** 31 migrations, not 28. **C2** `:ownership_timeout` is 120 000 ms, not 60 000 — and inapplicable under `:auto` mode, so ExUnit's 60 000 is the sole ceiling. **C3** the filing's contention hypothesis is wrong (adopted, and re-grounded on the zero-parallelism probe rather than the log tally this worktree cannot see). **C4** one omission: `release/2`'s own 5000 ms default (§3.2). Plus §4.5: the proposed 30 000 ms default is raised to 45 000 ms, because ISSUE-FIXER's own superseding n=40 data cut its stated multiple to ~1.95×. |

---

## 16. Open questions (explicit — not silently resolved)

**OQ-1 — the 45 000 ms default rests on ISSUE-FIXER's measurements, which this worktree
could not re-run.** §0 states which premises were verified first-hand and which were
not; every latency figure in §4.1 is in the "not re-verified" set (the partition logs
are absent here, and re-measuring means running the suite, which this run is explicitly
forbidden to do). §4.4's derivation is constructed to hold for any distribution
consistent with those samples, and §10's contract depends on none of them — but if a
later direct measurement produces a maximum materially above 15 373 ms, floor 2 changes
and the default must be **re-derived, not nudged**. `scratch/claim_latency.exs` is the
instrument and is already written.

**OQ-2 — a per-call provisioning-budget override (`claim/3`).** §3.3 (C) rejects the
`start_link/1` shape as incoherent and names the coherent alternative as an explicit
caller-side argument. Not built: no current caller needs one
(`Definitions.apply_promotion_assertion_rerun/6` is the only caller and passes only
`max_wait_ms`), and adding an unused arity now would be speculative API surface. Add it
when a concrete caller needs a non-global budget — not pre-emptively.

**OQ-3 — whether `release_call_timeout/0` should eventually diverge from
`provision_timeout_ms/0`.** §3.2 deliberately reuses the one calibrated number, and the
measurements now show why the two are *currently* the same size for a reason that is
not about the DROP at all: the DROP costs 20–498 ms (max 687 ms), while the mailbox
wait ahead of it costs up to 15 373 ms. Once §12's successor issue removes head-of-line
blocking, the release path's real requirement collapses to just the DROP cost, and a
much smaller, independently derived number becomes correct. Left open rather than
pre-committed, because the successor issue's shape determines it.

**OQ-4 — a production HTTP timeout for the sandbox path, once one exists.** V15
confirms no HTTP route currently reaches `apply_promotion_assertion_rerun/6`, so a
45 000 ms client-side budget has no user-facing latency consequence today. When PRM-06's
HTTP integration lands (REQ-040's own deferred half), that route needs its own
request-level deadline and must not simply inherit this one — a 45-second hanging HTTP
request is a different, worse failure than a 45-second hanging test. Named now so the
route's designer does not discover the coupling by accident.

**OQ-5 — nothing sweeps orphaned `sandbox_%` schemas** (V13:
`test/support/tenant_schema_reaper.ex` keys off `tenant_schemas` rows and matches only
`tenant_[0-9a-f]{32}`). `req039-…md` §11 OQ-3 already named this for the pool-restart
case; V13 confirms the test-suite reaper does not cover it either, so a claim abandoned
by a caller that *survives* its own timeout exit strands a schema indefinitely (§5.3).
§10's regression test is designed to create zero schemas specifically so it does not
depend on the answer. **Not filed as a successor issue here** — it is the same defect
`req039-…md` §11 OQ-3 already records as accepted, and re-filing it under a new number
would duplicate an accepted limitation. Flagged for ORCH to decide whether OQ-3's
accepted status should be revisited now that a second, independent path to the same
leak (a `catch_exit`-wrapping caller) is known.
