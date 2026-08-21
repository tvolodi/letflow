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
measurement instruments, read to confirm what they actually measure — the `.awk`
instrument's sampling bias, found by reading it, is §10.4's caveat); and every
ISSUE-FIXER **output** file now present in `scratch/`, read line by line rather than
via its summary — see the evidence table below.

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
attributed as such** — this run is explicitly forbidden to run the suite, so none of it
could be reproduced here.

**What `scratch/` actually contains — corrected.** An earlier revision of this paragraph
said `scratch/` "holds only the two instruments and not their output". That was true when
it was written and is no longer: ISSUE-FIXER left its raw output there as well, and this
revision read all of it.

| `scratch/` file | What it holds | Produced by | Used by |
|---|---|---|---|
| `claim_latency.exs` | the direct probe (instrument) | ISSUE-FIXER | §4.1, OQ-1 |
| `provision_latency.awk` | the log-gap extractor (instrument) | ISSUE-FIXER | §4.1, §10.4 |
| `db_load.sh` | the **controlled load generator** used to produce the "loaded host" condition | ISSUE-FIXER | §2.2, §4.1 rows 2–3 |
| `claim-latency-quiet-host.txt` | quiet-host n=20 raw series + summary | ISSUE-FIXER | §4.1 row 1 |
| `claim-latency-sample-B.txt` | loaded-host n=20 raw series + summary | ISSUE-FIXER | §4.1 row 3, §4.2 |
| `failing-run-provision-latency.txt` | log-derived partition-4 series, run 1 | ISSUE-FIXER | §4.1 row 4 |
| `green-run-provision-latency.txt` | log-derived series, 2026-08-21 green run | ISSUE-FIXER | §4.1 row 5 |
| `run2-N4-reproduction.log` | pre-fix N=4 run 2 summary (11 failures) | ISSUE-FIXER | §2.3, §10.4 |
| `run3-prefix-quiet-N4.log` | pre-fix N=4 run 3 summary (5 failures, siblings idle) | ISSUE-FIXER | §10.4 |
| `run3-provision-latency-p4.txt` | run 3's partition-4 provision series | ISSUE-FIXER | §10.4 |

**Provenance is uniform: ISSUE-FIXER produced every one of them**, including run 3, which
it ran after the first gate round. This design step produced no measurement of its own and
re-ran none of them; the only things it executed are the three `iss0220_*` probes behind
V5/V6/V7 (§14).

**`scratch/` is gitignored, so a future reader of this document cannot open any of those
files.** Every load-bearing figure is therefore **quoted inline where it is used** rather
than cited by filename: §4.1's table carries each series' own summary line verbatim, and
§10.4 carries run 3's complete partition-4 series and per-partition failure counts.

**One figure has no artefact in this worktree, and it is the load-bearing one.** The
loaded-host **sample A** series (§4.1 row 2) is not in `scratch/`; only ISSUE-FIXER's
reported summary exists for it — n=20, min 2112, median 3407, **max 15 373**, 3/20 over
5000 ms. Since **floor 1 = 15 373 ms is taken from sample A**, and §4.5's P4 separation
rule is derived from that same number at the other end, the single most load-bearing input
to §4.5 rests on a report rather than on an artefact this run inspected. Stated plainly
here and carried into **OQ-1**.

§4's derivation is constructed to hold for any distribution consistent with those samples,
and §10's regression-test contract depends on no latency measurement at all. The
`max_connections = 100` reading on `letflow-2-postgres-1` is likewise ISSUE-FIXER's (no
container access here); it enters only §13, which argues that number is *not* the
mechanism.

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
- On the same host under a **controlled synthetic load**, single-process still, n=40:
  **8 of 40 provisions (20%) exceed the entire `claim(0)` budget**, with a maximum of
  **15 373 ms — 3.07× the budget.**

  **"Loaded" here means deliberately generated, and an earlier revision of this section
  wrongly called it "the host's ordinary load".** Reading `scratch/db_load.sh` for this
  revision corrected it: the load is four shell workers, each looping `CREATE SCHEMA` +
  28 `CREATE TABLE` + `DROP SCHEMA CASCADE` against `letflow-2-postgres-1`. That matters
  and is stated rather than glossed, because **floor 1 (15 373 ms) comes from this
  condition**, so the reader must know it was manufactured, not observed in the wild.
  **It is nonetheless the right condition to size against, for a reason established
  independently in §10.4:** the generator reproduces *the same shape of work* the N=4
  suite inflicts on itself, and run 3 showed the suite producing over-budget provisions
  with the sibling workspaces verifiably idle — i.e. the contention this budget must
  survive is generated by the suite itself, and `db_load.sh` is a controllable stand-in
  for it rather than an artificial stressor with no counterpart in operation.

  One detail, noted because C1 makes it relevant: each generator worker creates **28**
  tables per cycle, the same superseded figure C1 corrects to 31. The generator is
  therefore marginally *lighter* than the real provisioning shape, ~10% per cycle. The
  direction is favourable — floor 1 is not inflated by an over-heavy stand-in — so no
  re-measurement is required on this account, but it is recorded so nobody later reads
  the load as calibrated to the real unit when it is not.

1.38× headroom at rest is not engineering margin; it is a coin flip against ordinary
host jitter, for an operation that is 32 transactions of DDL whose latency is
dominated by host I/O. And this project's documented operating reality is a machine
that is *expected* to be busy: `0009-test-parallel-pool-sizing.md`'s entire premise
is N concurrent partitions, and `docs/anti-patterns.md`'s "Running `docker compose
up` from a secondary worktree checkout" documents the several-workspaces-each-with-
its-own-Postgres arrangement this repo is actually checked out into.

So the budget is under-sized against `provision_sandbox/0`'s cost distribution when it
is the **only claim in flight** — one BEAM, one pool, `max_concurrent: 1`, no partitions,
nothing else claiming. The precise claim, stated so the synthetic load above cannot be
read as smuggling contention back in: the *host* is contended in samples A and B, and
deliberately so; the **pool and the caller are not**. `TEST_PARALLEL_N=4` is therefore
not a precondition of the failure — it only makes it fail *often*, by supplying the host
contention `db_load.sh` supplies on purpose. It is not what makes the budget wrong.
**The contention is evidence, not cause.**

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
provisioning therefore has **no server-side deadline at any level `Ecto.Migrator`
controls**.

One qualification, carried with the same hedge as the sentence above so the claim is not
read as broader than it is: **DBConnection's `:queue_target`/`:queue_interval` still
govern connection *checkout*** and can drop a request that cannot obtain a connection —
§2.5 C3 counts exactly one genuine queue drop in the run-2 failure log. That timer bounds
*waiting for a connection*, not the DDL executed once one is held, so it is not a deadline
on provisioning work; it is named here so a reader who finds it later does not conclude
§2.4 overlooked it. Before this fix, the caller's 5_000 ms `GenServer.call` timeout was
the single deadline on the provisioning *work* in the entire path, and it was set by a
constant chosen for an unrelated reason.

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

**What the reason is NOT.** The measured `DROP SCHEMA … CASCADE` cost does not
motivate this: 20–498 ms across 40 samples, max 687 ms under N=4 load — two orders of
magnitude cheaper than a provisioning, and 7× inside 5_000 ms on its own.

**And an earlier revision of this section got the reason wrong, in a way worth
recording** because it is exactly what `core-directives.md` §"No Speculation" exists
to prevent. It claimed as *decisive* that `sandbox_pool_test.exs:273`'s
`Task.await(waiter, 3_000)` wraps a `release/2` call, so leaving `release/2` unfixed
would merely relocate the failure. The wrapping is real; the consequence was asserted,
not measured. At `:252` that per-test pool holds one active claim, an empty `waiting`
queue, and no other caller — **the pool is idle**, so no head-of-line blocking is
available to make that release slow, and the DROP alone fits 7× inside the existing
budget. Worse, the claim contradicted this document's own §12 and INV-SP-T4, which
state that the head-of-line defect is **not** currently observable because every
present caller has at most one claim in flight. Both could not be true.
CODE-DESIGN-VALIDATOR caught it. Withdrawn.

**The real, present-tense reason — verified first-hand in this worktree.**
`Letflow.Definitions.safe_release/2` (`lib/letflow/definitions.ex:1821-1826`) is the
best-effort wrapper written specifically to contain release failures on the
exception-recovery path, and it contains them with `rescue`:

```
defp safe_release(sandbox_id, sandbox_pool) do
  SandboxPool.release(sandbox_id, sandbox_pool)
rescue
  _exception -> {:error, :release_failed}
end
```

`rescue` **structurally cannot catch the `exit` a `GenServer.call` timeout raises.**
So a `release/2` that exceeds its budget escapes the one wrapper built to swallow
release failures, and does so on the path that is *already* handling an exception —
turning a contained, best-effort cleanup failure into an uncaught exit during error
recovery. This is precisely the `rescue`-doesn't-catch-`exit` shape
`iss-0048-sandbox-pool-owner-crash-reclaim.md` was written about, recurring one
function away from where ISS-0048 fixed it. It needs no contention, no load and no
concurrency to occur — only a release call that takes longer than its budget.

Including `release/2` is therefore not scope creep: same mis-sizing, one line, zero
behavioural risk, pinned by RT-3, on a path with a demonstrated failure-containment
hole. `core-directives.md` §"Unblock-Everything" covers it.

**On `release_call_timeout/0`'s *size*, as distinct from its existence.** It returns
`provision_timeout_ms()` — the same calibrated number, so no second uncalibrated
constant is introduced. That size is **future-proofing against §12, not a mechanism
operating today**: with every present caller holding at most one claim in flight
(INV-SP-T4), nothing currently blocks the pool's mailbox ahead of a release, and the
DROP alone would fit in a far smaller number. Once §12's successor issue is decided,
the right size is separately derivable from DROP cost — which is exactly what OQ-3
leaves open, and §3.2 does not pre-empt it.

### 3.3 Alternatives considered and rejected

- **(A) Just raise `@call_timeout_buffer_ms` to 44_000.** Rejected. It leaves the
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

## 4. The default: 44 000 ms, derived from measurement

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
| **loaded host, single process** (sample A) — load from `scratch/db_load.sh`, §2.2 | direct probe | 20 | 2112 ms | 3407 ms | **15 373 ms** | 3/20 |
| **loaded host, single process** (sample B) — same generated load | direct probe | 20 | 1119 ms | 2471 ms | 8711 ms | 5/20 |
| loaded host, N=4 suite, partition 4 | log-derived | 5 | 4594 ms | 5596 ms | 12 053 ms | 3/5 |
| green N=4 suite, 2026-08-21 | log-derived | 26 | 897 ms | ≈1240 ms | 2302 ms | 0/26 |

**Quoted inline, because `scratch/` is gitignored (§0)** — each direct-probe file's own
trailing summary line, verbatim, and the two log-derived series in full:

```
claim-latency-quiet-host.txt : n=20 min=918ms  max=3621ms  median=1662ms mean=1831ms
                               samples over 5000ms: 0/20
claim-latency-sample-B.txt   : n=20 min=1119ms max=8711ms  median=2471ms mean=3287ms
                               samples over 5000ms: 5/20
                               -- "loaded" = scratch/db_load.sh, 4 synthetic DDL
                                  workers; see §2.2 for why that is the right
                                  condition to size against
loaded-host sample A         : n=20 min=2112ms max=15373ms median=3407ms  (3/20 over 5000)
                               -- ISSUE-FIXER's reported summary; no raw file in scratch/ (§0)
failing-run-provision-latency.txt (run 1, partition 4, log-derived, n=5):
                               4594, 4903, 5849, 12053, 5596  ms
green-run-provision-latency.txt (2026-08-21 green run, log-derived, n=26):
                               1900 1200 1201 1135 1088 1146 1240 1473 1302 1154 1420
                               1484 1432  995  897 1947 1162 1341 1242 1207 1045 1291
                               1041 2302 1177 1428  ms
```

Combined direct-probe measurement under load: **n=40, 8/40 = 20% of provisions exceed
the entire `claim(0)` budget of 5000 ms. Highest single observed provision across
every measurement: 15 373 ms.**

**Both log-derived rows (4 and 5) are biased low and must not be read as tail estimates**
— `provision_latency.awk` can only report provisions that *completed*, so a provisioning
killed by its caller's timeout is invisible to it. §10.4 states the mechanism and its
consequence in full. This is why §4.4's floor 1 comes from a direct-probe sample, where
`max_wait_ms: 600_000` guarantees the slow cases are measured rather than dropped.

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

**No second numeric floor is derivable from this data, and this section deliberately
does not manufacture one.** An earlier revision of this document did: it multiplied
floor 1 by 1.76 — the ratio between the two loaded n=20 window maxima (15 373 and
8711) — to produce a "floor 2" of 27 057 ms, and used it as the sole discriminator
against 20 000/25 000/30 000. CODE-DESIGN-VALIDATOR rejected that construction and was
right to. It is recorded here rather than quietly deleted, because §5.1's `@doc`
instructs a future reader to redo this derivation, and they must not re-invent it:

1. The multiplier is a **sample of size two** with unquantified variability. It is not
   a confidence bound and cannot be read as one.
2. It is **anti-conservative exactly where the data is most alarming**: had the two
   window maxima happened to agree closely, the method would have demanded almost no
   margin over floor 1 — the opposite of what agreement between two heavy-tailed
   samples should imply.
3. It is **unstable under an equally legitimate window choice.** §4.1 contains a third
   n=20 window (quiet host, max 3621 ms). Pairing that one with 15 373 gives 4.24× and
   a "floor" of 65 200 ms — **above this document's own 60 000 ms ceiling**, i.e. no
   admissible value would exist at all. The original silently picked the two "loaded"
   windows without stating any comparability rule.
4. Applying the ratio to the larger *maximum* rather than to a central estimate was a
   further unstated choice with no justification behind it.

**What the two-window spread actually tells us is the opposite of a multiplier: the
tail is not estimable from this data.** n=40 total, cold-start-dominated (§4.2), and
two same-conditions windows whose maxima differ by 1.76× — that spread is evidence
that no tail quantile can be estimated here, not a quantity to multiply by. Saying so
is the honest position; inventing a percentile from 40 cold-start samples would be
the same class of error as `@call_timeout_buffer_ms` itself.

**So the selection is made by decision rule, not by a second floor** — see §4.5.

**Ceiling — ExUnit's default per-test timeout, 60 000 ms (V5).** The provisioning
budget must stay meaningfully below it so ExUnit's own timeout remains the outer
bound and a genuinely stuck claim is reported as a legible `claim/2` timeout rather
than pre-empting, or being pre-empted by, the framework's deadline. **"Meaningfully
below" is quantified in §4.5 as P4** — the separation must itself be at least one
worst-observed provisioning — and that quantification, not a preference for round
distances, is what selects the value. Per **C2**,
`:ownership_timeout` (120 000 ms, and inactive under `:auto` mode anyway) is **not** a
ceiling here and is not used as one.

### 4.5 Decision: 44 000 ms

**The decision rule, stated before the number so it can be checked against it.** Four
premises. Each is established elsewhere in this document, and none is a tail estimate —
P1 and P4 both use a single *observed* quantity (15 373 ms), not an extrapolation from
one:

- **(P1)** Floor 1 is a hard exclusion: 15 373 ms was *observed* as legitimate work
  (§4.4).
- **(P2)** This budget is the **only deadline on the provisioning work anywhere in the
  path** (§2.4 / V4 — `Ecto.Migrator` pins `timeout: :infinity` at all three levels it
  controls; DBConnection's checkout timers bound waiting for a *connection*, not the DDL
  run once one is held, per §2.4's qualification). It therefore must **not** be sized as
  a pathology detector; it has no such job, and ExUnit's 60 000 ms per-test timeout is
  the actual backstop for a genuine hang.
- **(P3)** The error costs are strongly asymmetric. Sizing too small produces **false
  failures on correct work** — the actual issue, 9 of the 11 measured failures, and a
  class that recurs indefinitely because it is load-dependent. Sizing too large costs
  only **late detection of a hang**, bounded by ExUnit at 60 s, in a case that has
  never been observed (the measured failure set contains zero ExUnit test timeouts).
  **P3 is not free — §4.6 quantifies what sizing large actually costs, and §4.5's "Why
  not 30 000" weighs it rather than dismissing it.**
- **(P4)** **Separation from the ceiling must itself be at least one worst-observed
  provisioning: ≥ 15 373 ms.** This is not a preference for round distances; it is the
  condition under which the two deadlines stay *distinguishable outcomes*. If the gap
  between the budget and ExUnit's 60 000 ms is smaller than a single legitimate
  provisioning, then one slow-but-legitimate provisioning plus ordinary test overhead
  can straddle both, and which deadline fires first becomes a coin flip — destroying
  exactly the legibility the claim timeout exists to provide (§4.6). Note that the same
  measured quantity does two different jobs at the two ends: floor 1 excludes budgets
  *below* 15 373 ms, and P4 excludes budgets above `60 000 − 15 373`.

Since the tail is not estimable (§4.4) and the costs are asymmetric (P3), the rational
choice is **the largest value P4 admits** — not the smallest value that clears some
manufactured floor. P1 and P4 together bound the interval from both sides, and P2/P3
say which end of it to take:

```
hard exclusion   (§4.4 floor 1, P1):   budget            >  15 373 ms
ceiling          (§4.4):               budget            <  60 000 ms
separation rule  (P4):                 60 000 - budget   >= 15 373 ms
                                    => budget            <= 44 627 ms
admissible interval:                   (15 373 ms, 44 627 ms]
selection        (P2, P3):             take the largest admissible value
chosen:                                44 000 ms
                                       separation 16 000 ms  (> 15 373, P4 satisfied)
                                       2.86x floor 1, 0.73x the ceiling
                                       627 ms below the admissible ceiling, trimmed
                                       downward to a clean kilosecond
```

**45 000 ms — this document's previous choice — is excluded by this rule, by 373 ms.**
Recorded rather than quietly replaced, because §5.1's `@doc` sends a future reader here
to redo the derivation and they must be able to see what went wrong. The earlier
revision chose 45 000 and justified it with "45 000 keeps a full observed
provisioning's worth of separation, and then some" — which is arithmetically false:
`60 000 − 45 000 = 15 000`, and the worst observed provisioning is `15 373`, so the
separation was **0.976** of one provisioning, not "a full one", and certainly not "and
then some". What actually produced 45 000 was `0.75 × 60 000`; §4.5 then presented
`0.75×` as a *property* of the number rather than as the rule that generated it, and
bolted on a data anchor the number misses. CODE-DESIGN-VALIDATOR caught it. The fix is
not to soften the sentence but to let the stated basis determine the value, which it
does: `≤ 44 627`. Nothing here is chosen for roundness except the final 627 ms trim,
which moves in the conservative direction the rule already points.

Its multiples:

| Reference | Multiple at 44 000 ms |
|---|---|
| quiet-host median (1662 ms) | **26.5×** |
| quiet-host max (3621 ms) | **12.1×** |
| green N=4 max (2302 ms) | **19.1×** |
| N=4 partition-4 max (12 053 ms) | **3.65×** |
| **highest observed sample (15 373 ms)** | **2.86×** |
| ExUnit per-test ceiling (60 000 ms) | **0.73×** (16 000 ms separation) |

Per-migration sanity check on the mechanism rather than the statistics: 31 migrations
/ 32 transactions. Quiet-host median ≈ 54 ms per migration; the worst observed sample
≈ 496 ms per migration (≈9× degradation); a 44 000 ms budget tolerates ≈1420 ms per
migration, ≈26× the quiet-host per-migration cost. For a `CREATE TABLE`-shaped DDL
statement in its own transaction against a local containerised Postgres, ~1.4 s per
statement is a generous but not absurd ceiling.

**Why not higher.** P4 excludes it arithmetically rather than by taste: every value
above 44 627 ms leaves less than one observed provisioning between the budget and
ExUnit's deadline. At 55 000 the separation collapses to 5000 ms — **less than a third
of a single observed provisioning (15 373 ms)** — and the two deadlines stop being
distinguishable outcomes at all: one slow-but-legitimate provisioning plus ordinary test
overhead straddles both, and the claim timeout stops being the legible failure it exists
to be. 44 000 leaves 16 000 ms, which is one full observed provisioning with 627 ms to
spare, and that "to spare" is the entire margin this rule allows itself.

**Why not 30 000 (the value both the handoff and ISSUE-FIXER proposed).** It is fully
**admissible**: it clears floor 1, and its separation from the ceiling (30 000 ms) is
nearly twice what P4 demands. Nothing in the data excludes it, and this document should
not pretend otherwise. It is rejected on **P3** — and because P3 is then the whole load
the decision rests on, both sides of the trade are stated rather than one:

*In 30 000's favour — a real, non-zero cost of the higher value.* §4.6's
failure-legibility property is lost when a test's **first** provisioning exceeds
`60 000 − budget`: that threshold is **16 000 ms at 44 000** and **30 000 ms at
30 000**. The worst observed provisioning is 15 373 ms, so at 44 000 the loss region
starts just above the top of the measured data — close enough to sit inside measurement
noise — while at 30 000 it starts at roughly twice the observed maximum. §4.6 therefore
**does** discriminate between the candidates, in 30 000's favour, right at the margin the
data reaches. An earlier revision of §4.6 asserted the opposite ("it cannot discriminate
between the candidates at all"), which zeroed out precisely the counterweight P3 has to
be argued *against*; CODE-DESIGN-VALIDATOR caught it, and §4.6 now quantifies it.

*Against 30 000, decisively — the asymmetry P3 names.* What §4.6 costs is the
*legibility of a failure in a case that is already a failure*: two pathological
provisionings inside one test, where both outcomes are failures and **no false pass is
available in either direction**, in a scenario the measured failure set contains **zero**
instances of. What sizing too small costs is a **false failure on correct work** — the
actual issue, 9 of the 11 measured failures, recurring indefinitely because it is
load-dependent. 30 000 gives up 14 000 ms of coverage against a tail §4.4 establishes is
*not estimable*, and buys in exchange a legibility improvement in a never-observed case
plus 14 seconds' earlier detection of a hang that has also never been observed and that
ExUnit catches anyway. That is trading an expensive, observed error class for a cheap,
hypothetical one.

The higher value therefore wins on a weighed argument, not on an empty one. ISSUE-FIXER
explicitly invited this re-derivation ("I would rather ship your derivation than my
guess") after its own direct probe raised the observed maximum from 12 053 ms to
15 373 ms, cutting its stated 2.5× multiple to ~1.95×.

**What would change this number.** Not a green run, and not a preference. Only a direct
measurement (`scratch/claim_latency.exs`) producing an observed *legitimate* provisioning
above 15 373 ms — or a change to `tenant_scoped_migrations/0`'s size, which changes the
mechanism. See OQ-1.

**Note that 15 373 ms now enters the derivation at both ends**, so a new maximum `M` moves
both: floor 1 rises to `M`, and P4's admissible ceiling falls to `60 000 − M`. The
admissible interval `(M, 60 000 − M]` is therefore non-empty **only while `M < 30 000 ms`**.
If a legitimate provisioning above 30 000 ms is ever observed, this rule admits no value at
all against a 60 000 ms ceiling, and the correct response is to raise the *framework*
deadline (`@moduletag timeout:`, §4.6) rather than to abandon P4 — the conclusion that the
two deadlines must stay one provisioning apart does not weaken just because it becomes
inconvenient.

### 4.6 The one consequence this choice accepts, stated explicitly

At 44 000 ms, a single test performing **two** pathological provisionings can reach
ExUnit's 60 000 ms per-test timeout before the second claim's own timeout fires, in
which case it fails as an opaque ExUnit test timeout rather than as a clean, legible
claim timeout. "Can", not "does" — the exact condition is derived below, and at 44 000
it requires the *first* provisioning alone to exceed 16 000 ms.

**Four** tests in `sandbox_pool_test.exs` perform two real provisionings — enumerated
by re-reading every `SandboxPool.claim(` site in the file, not estimated (an earlier
revision of this section said "two", missing the first two rows; CODE-DESIGN-VALIDATOR
caught it, and §0 makes first-hand verification of this exact file this document's own
standard):

| Test | Provisioning claims | Note |
|---|---|---|
| `:180` two immediate claims | `:184`, `:189` | |
| `:216` queued waiter is served | `:220`, `:242` | **tightest post-change** — `:242`'s waiter also carries `max_wait_ms: 2_000`, so its own call timeout is 46 000 ms, and the two claims plus that queue wait are the closest this file comes to ExUnit's 60 000 ms |
| `:319` release frees the slot | `:323`, `:340` | the `claim(0)` at `:331` provisions nothing |
| `:367` killed owner reclaimed | `:379`, `:413` | the `claim(0)` at `:396` provisions nothing |

**What this costs, quantified — because §4.5 rejects 30 000 on P3, P3 is the claim that
sizing too large costs *only* late detection of a hang, and with floor 2 withdrawn (§4.4)
nothing else in the data excludes 30 000. This section is where the counterweight to P3
is measured, so it must not be zeroed out.**

For a budget `B` and a first provisioning of `T1` ms, a second pathological provisioning
still produces a **clean claim timeout** at `T1 + B`, unless ExUnit fires first at
60 000. The legibility is therefore lost exactly when `T1 ≥ 60 000 − B`:

| Budget | Legibility lost once the first provisioning exceeds | vs. the observed maximum (15 373 ms) |
|---|---|---|
| **44 000 ms** (chosen) | **16 000 ms** | just *above* it — within measurement noise of the data |
| 30 000 ms | 30 000 ms | ~2× it — never observed |
| 45 000 ms (previous revision) | 15 000 ms | *below* it — the data already contains such a provisioning |

So the property **does** discriminate between the candidates, and it discriminates in
favour of the lower budget, right at the margin the data actually reaches. **An earlier
revision of this section claimed it "cannot discriminate between the candidates at all",
on the grounds that "the property is already lost at 30 000 (2 × 30 000 = 60 000,
exactly the ceiling)". That is false.** `2 × B = 60 000` describes only the case where
the *first* provisioning consumes its **entire** budget — 30 000 ms of legitimate
provisioning, never observed anywhere in §4.1. The real threshold is `T1 ≥ 60 000 − B`,
which is a far more demanding condition at `B = 30 000` than at `B = 44 000`.
CODE-DESIGN-VALIDATOR caught it. It is recorded rather than silently deleted, because
erasing this counterweight is exactly what made §4.5's P3 argument look free when it is
not.

**It is nonetheless not a reason to choose the lower value — and §4.5 now makes that
argument instead of assuming it.** The cost is failure *legibility* in a case that is
already a failure (no false pass is available in either direction), and it requires two
pathological provisionings inside one test, of which the measured failure set contains
zero instances. The cost it is weighed against is a false failure on correct work,
observed 9 times out of 11. §4.5's "Why not 30 000" states both sides and does the
weighing.

**One consequence worth stating, since B1's re-derivation moved the number anyway:**
this is a second, independent point in 44 000's favour over the 45 000 an earlier
revision chose. At 45 000 the loss region begins at `T1 ≥ 15 000 ms`, which is *below*
the observed maximum of 15 373 — the measured data already contains a provisioning that
would trigger it. At 44 000 it begins at 16 000 ms, just outside the data. The
rule-derived value is better on this axis too, not merely more honestly derived.

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
The GenServer.call/3 timeout release/2 uses: `provision_timeout_ms()` -- the same
calibrated number, so the release path has a derived bound rather than
GenServer.call/2's implicit 5_000 ms default. It is not sized from the DROP cost,
and not because anything currently blocks the pool's mailbox ahead of a release.
See the design doc's §3.2.
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
@default_provision_timeout_ms 44_000
```

```
# optional override, in any config/*.exs -- NOT added to any of them by this fix
config :letflow, :sandbox_pool,
  max_concurrent_sandboxes: 1,
  provision_timeout_ms: 44_000
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
uses the provisioning budget alone — and why, stated as §3.2 and §7.3 now state it:
**not** because the DROP costs anything like that (it does not, by two orders of
magnitude) and **not** because anything currently blocks the pool's mailbox ahead of a
release (nothing does — INV-SP-T4, §12), but so that the release path has a *derived*
bound instead of `GenServer.call/2`'s implicit 5_000 ms default, and so it is already
correctly sized once §12's head-of-line blocking is fixed; that the budget is a
**caller-side** allowance and not a server-side abort (§5.3); and
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
| `:387` `assert_receive {:owner_claimed, …}, 2_000` | 2000 ms | `claim_rendezvous_timeout(1_000)` = 46 000 ms | a spawned owner's `claim(1_000, pool)` to complete and relay | **NOT fixed by the `claim/2` change** — one of the two measured mechanism-(2) failures (`SandboxPoolTest:367`, `no matching message after 2000ms`). 2000 ms is **0.55×** the quiet-host max (3621 ms) and **0.13×** the worst observed (15 373 ms) for the operation it waits on. |
| `:262` `assert_receive {:waiter_claimed, …}, 3_000` | 3000 ms | `claim_rendezvous_timeout(2_000)` = 47 000 ms | the queued waiter's `claim(2_000, pool)` to be served after `release(held_id)` frees the slot | The other measured mechanism-(2) failure (`SandboxPoolTest:216`, `no matching message after 3000ms`). The waited-on work is a full cold-start provisioning; the bound must be the claim budget, not a hand-picked 3000 (0.83× the quiet-host max). |
| `:249` waiter's `receive … after 3_000 -> flunk(…)` | 3000 ms | `pool_op_rendezvous_timeout()` = 45 000 ms | the **test process** to send `:release_waiter_claim`, which it does after `:262` succeeds plus two asserts and one `schema_exists?/1` query | Must not expire before the test process gets there. Derived from the pool-operation budget rather than inventing a "one Repo query" constant — one source of truth, generous in the safe direction (if the test process dies, `Task.async`'s link kills the waiter regardless, so an over-generous bound cannot hang the suite). |
| `:273` `Task.await(waiter, 3_000)` | 3000 ms | `pool_op_rendezvous_timeout()` = 45 000 ms | the waiter's own `SandboxPool.release/2` (`DROP … CASCADE`) plus its return | **Prophylactic, like `:130` — not in the measured failure set.** Per §3.2 the pool is **idle** at this point: `:262` has already succeeded, this per-test pool has one active claim and an empty `waiting` queue, and no other caller exists — so nothing can be ahead of this release in the mailbox, and the measured DROP (20–498 ms, max 687 ms) fits ~7× inside even the *existing* 3000 ms bound. The raise is taken for the two reasons that apply with the pool idle: it makes the bound **derived from the one source of truth** (`release_call_timeout/0`) instead of hand-picked, so it tracks a config override automatically; and it **future-proofs against §12**, after which a release genuinely can queue behind an in-flight provisioning. **An earlier revision instead justified this row by claiming it "pairs exactly with §3.2's `release_call_timeout/0`; raising this bound without §3.2 would only relocate the failure into the release call" — §3.2 has since withdrawn exactly that claim as unmeasured and self-contradictory (it presumed head-of-line blocking that INV-SP-T4 says is unreachable today), and it must not survive here.** |
| `:130` `wait_until_schema_dropped(schema_name, attempts \\ 400)` | 400 × 5 ms = 2000 ms | **deadline-based**, default `SandboxPool.release_call_timeout()` = 44 000 ms | the pool's `handle_info({:DOWN, …})` reclaim to finish a `DROP SCHEMA … CASCADE` over a 31-table schema | **Prophylactic, and labelled as such — see the note below.** The attempts→deadline conversion is the real improvement: an attempt count is an implicit time bound that silently changes meaning if the poll interval ever changes. Use `System.monotonic_time(:millisecond)` with the existing 5 ms poll interval. **`flunk/1` on expiry is retained verbatim.** |

**Note on `:130`, added after CODE-DESIGN-VALIDATOR review — this row is the weakest
in the table and is not disguised as the others' equal.** It is **not** in the measured
failure set (§2.3), and the head-of-line-blocking justification an earlier revision
gave it does not hold: at the kill in `:367` that per-test pool is idle, so nothing can
be blocking its mailbox, and the measured DROP cost (20–498 ms, max 687) fits inside
the existing 2000 ms with ~3× to spare. So the raise is **prophylactic** — it protects
against a DROP excursion nobody has observed.

It also carries a real cost, stated rather than hidden: a schema that is *never*
dropped (a genuine reclaim regression) now takes 44 s to report instead of 2 s, and in
`:367` — which per §4.6 also performs two provisionings — that will often collide with
ExUnit's 60 000 ms per-test timeout, **replacing a legible `flunk/1` message with an
opaque framework timeout**. That is a real regression in failure legibility for the
exact defect the helper exists to catch.

It is nonetheless kept at the derived value rather than at a DROP-derived one, for a
single reason: `release_call_timeout/0` is the one source of truth this file derives
from, and introducing a second, separately-derived polling constant here would
reintroduce exactly the drift class §8.1 exists to prevent — for a bound that has never
failed. If REVIEWER or TEST-DESIGN-VALIDATOR prefers the opposite trade, deriving this
one default from measured DROP cost (say 5 000 ms, ~7× the 687 ms maximum) is a
defensible alternative and **this design does not object to it**; what it rules out is
leaving the value un-derived, or leaving the attempts-based form in place.

Derived values shown at the 44 000 ms default; every one tracks a config override
automatically, which is the point of deriving them.

### 8.3 Three bounds in the same file deliberately NOT changed

Named explicitly so their absence from §8.2 reads as a decision, not an omission.
None appears in the measured failure set (§2.3).

- **`:107` `wait_until_waiter_queued(pool, attempts \\ 200)` (1000 ms).** Waits only for
  a `Task`'s `claim/2` message to reach the pool's mailbox and be appended to
  `waiting`. At that moment the pool is **idle** — the held claim was provisioned
  before the `Task` was spawned, and `handle_queue_or_reject/3` on the no-free-slot
  path issues no SQL at all (`sandbox_pool.ex:226-231`). So this bound covers one
  process spawn plus one `GenServer.call` round trip against an idle process.
- **`:402` `assert_receive {:DOWN, ^owner_monitor_ref, …, :killed}, 2_000`.** Waits for
  the BEAM's own monitor message after `Process.exit(owner_pid, :kill)` — no database,
  no pool interaction, delivered by the runtime.
- **`:242`'s `SandboxPool.claim(2_000, pool)` — the waiter's own `max_wait_ms`.** This
  one is genuinely load-sensitive, and is left alone anyway, on principle: `max_wait_ms`
  is a **parameter of the system under test**, not an observer's patience. The test's
  own comment at `:224-228` explains that the value is chosen long enough that the
  timeout path cannot be what produces the success — i.e. the number is load-bearing for
  what the test *proves*, and moving it would change what is measured, which §8.0
  forbids and `core-directives.md` §"Never Satisfy a Gate by Editing What It Measures"
  forbids outright. Its *call* timeout does rise (to 46 000 ms) via §7.2, which is the
  correct fix; its queue-wait semantics stay exactly as they are. Named here because
  §8.3 exists so that absences read as decisions, and this is the one omission a
  reviewer would most reasonably question.

### 8.4 The other two affected test files need no edits — checked against the measured failure set

- **`test/letflow/sandbox_pool/fixture_loader_test.exs`.** Its only bound is
  `SandboxPool.claim(2_000, pool)` inside `claim_schema!/0` (`:63`), whose call timeout
  rises from 7000 to 46 000 by §7.2 alone. Its measured failure (`:170`) is a
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

**Which cases carry fail-first weight — read this before writing any of them.** WF-03
Step 4 requires a demonstration that the test fails against pre-fix code *for the right
reason*. A test that fails pre-fix because a function does not exist proves nothing:
it is a compile/`UndefinedFunctionError` failure, not a behavioural one.

| Case | Pre-fix outcome | Fail-first weight |
|---|---|---|
| RT-1 | `UndefinedFunctionError` — `claim_call_timeout/1` etc. do not exist | **none** |
| **RT-2** | **observes 5000 / 7000 against expected 1234 / 3234** | **yes** |
| **RT-3** | **observes 5000 against expected 1234** | **yes** |
| RT-4 | `UndefinedFunctionError` — `provision_timeout_ms/0` does not exist | **none** |

**Only RT-2 and RT-3 are the fail-then-pass demonstration.** RT-1 and RT-4 are drift
guards that happen to be unwritable pre-fix; report them as such rather than counting
them toward Step 4's evidence. (An earlier revision of this document asserted in §10.4
that RT-4 was runnable pre-fix, contradicting §10.3's own RT-1 entry;
CODE-DESIGN-VALIDATOR probed the real pre-fix module — `function_exported?/3` → `false`
for `provision_timeout_ms/0` — and rejected the design over it. Corrected.)

The pre-fix numbers in the table above are **measured, not predicted**:
CODE-DESIGN-VALIDATOR ran the black-hole probe against the unmodified module and
observed `{:timeout, {GenServer, :call, [pid, {:claim, 0}, 5000]}}` and
`{:timeout, {GenServer, :call, [pid, {:release, "..."}, 5000]}}`. TEST-DESIGNER should
expect exactly these and quote its own run of them.

**Implementation note:** `catch_exit/1` is an `ExUnit.Assertions` macro, **not** a
`Kernel` import. It is available inside a module that does `use ExUnit.Case`; a bare
script or a module without it will not compile. (CODE-DESIGN-VALIDATOR's first probe
failed on precisely this.)

**RT-1 — the derivation is a function of the configured budget.**
Assert `claim_call_timeout(w) == w + provision_timeout_ms()` for
`w ∈ {0, 1, 1_000, 2_000, 60_000}`, and `release_call_timeout() == provision_timeout_ms()`.
*Pre-fix:* `UndefinedFunctionError` — the functions do not exist. **Carries no
fail-first weight** (see the table above).
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

*Pre-fix:* **measured** by CODE-DESIGN-VALIDATOR against the unmodified module —
`{:timeout, {GenServer, :call, [pid, {:claim, 0}, 5000]}}`, i.e. the computed timeouts
are `0 + 5_000 = 5_000` and `2_000 + 5_000 = 7_000`, and both pattern matches fail
against the literals `1_234` / `3_234`. **This is a behavioural fail-then-pass, not a
compile error** — the assertion is written against literals derived from the config
value the test itself sets, so it does not depend on any new function existing. **One
of the two cases that carry fail-first weight.**
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

*Pre-fix:* **measured** — CODE-DESIGN-VALIDATOR observed
`{:timeout, {GenServer, :call, [pid, {:release, "..."}, 5000]}}` against the unmodified
module, so the third element is `5_000` and the match fails. **The second of the two
cases that carry fail-first weight.** This pins §3.2 — the mis-sizing nobody named;
without RT-3 nothing prevents `release/2` silently reverting to `GenServer.call/2`.

**RT-4 — the shipped default is in force.**
With **no** `:provision_timeout_ms` key present (the shipped state per §6):

```
assert SandboxPool.provision_timeout_ms() == 44_000
assert SandboxPool.provision_timeout_ms() < 60_000     # ExUnit's per-test ceiling, §4.4
assert SandboxPool.provision_timeout_ms() > 15_373     # the highest observed provisioning, §4.1
```

*Pre-fix:* `UndefinedFunctionError`. **Carries no fail-first weight.**

The first assertion is an honest change-detector — justified *only* because this entire
issue is a number silently left un-sized, and required to carry a comment naming
`lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §4 so that changing it
forces re-reading the derivation.

**The second and third are also drift guards, not independent properties** — an earlier
revision of this section claimed they were "genuine properties, not tautologies", which
overstates them: given the equality assertion on the line above, both are strictly
implied and can never fail independently of it. They earn their place only as
*documentation of the bounds inside the test file*, so that a future engineer editing
the equality is confronted with the ceiling (§4.4) and the hard exclusion (§4.4 floor 1)
in the same screen rather than having to find §4 of this document. Write them with that
justification in the comment, and do not report them as separate coverage.

### 10.4 Also required of TEST-DESIGNER

- **`test/specs/ISS-0220.md`**, following the `test/specs/ISS-0048.md` precedent: case
  rationale, pre-fix/post-fix expectation per case, and the §8.0 statement that no
  existing assertion was weakened.
- **The pre-fix demonstration must be run and its real output quoted** in the WF-03
  Step 4 report — `core-directives.md` §"No Speculation" applies without exception on
  this run. **Only RT-2 and RT-3 are runnable against pre-fix code** (they call no new
  function, asserting instead against literals derived from the config value the test
  itself sets), and only those two constitute the fail-then-pass demonstration. RT-1
  and RT-4 call `claim_call_timeout/1` / `provision_timeout_ms/0`, which do not exist
  pre-fix — verified by CODE-DESIGN-VALIDATOR's probe (`function_exported?/3` →
  `false`) — so they fail with `UndefinedFunctionError` and prove nothing. Report them
  as drift guards; do not count them toward Step 4's evidence. See §10.3's weight
  table for the measured pre-fix values to expect.
- **Do NOT add a test that runs the suite at `TEST_PARALLEL_N=4`** to "prove" ISS-0220
  is fixed. That is a load-dependent, non-deterministic observation with a ~20-minute
  cost, and RT-1..RT-4 pin the actual defect deterministically in milliseconds. Note
  further that the single-process quiet-host probe (0/20 provisions over 5000 ms) does
  **not** support the conclusion an earlier revision of this section drew from it — that
  "a green N=4 run on a quiet host would prove nothing pre- or post-fix". **That claim
  has since been refuted by direct measurement and must not be carried into
  RELEASE-VALIDATOR's writeup.**

  **The refuting measurement (run 3), attributed and quoted.** ISSUE-FIXER ran the suite
  pre-fix at `TEST_PARALLEL_N=4` with the sibling workspaces verifiably idle
  (`docker stats` during the run: `letflow-postgres-1` 5.84%, `letflow-3-postgres-1`
  6.32% — i.e. neither sibling running a suite) and got **5 failures out of 1433 tests /
  5 properties, zero anywhere outside the ISS-0220 files** — three
  `GenServer.call({:claim, N}, max_wait_ms + 5000)` timeouts plus the two `:367`/`:216`
  `assert_receive` bounds. Per-partition: `partition 1: 0 failures`, `partition 2: 0
  failures`, `partition 3: 1 failure`, `partition 4: 4 failures`.
  **Those five span only *two* of the three ISS-0220 files** —
  `test/letflow/definitions/promotion_assertion_rerun_test.exs` contributed none in this
  run. "All in the ISS-0220 files" is true as set membership and is the claim being made;
  it is *not* a claim that each of the three files failed.

  **The count correction, and it matters more than it looks.** An earlier revision of
  this bullet wrote that "partition-4 provisions in that same run measured 2745, 2785,
  2977, 4288, 4848 and 6642 ms — **three** over the 5000 ms budget." **Only one of those
  six exceeds 5000.** The six figures are the complete partition-4 series and are
  correct; the count is not. Re-measured by CODE-DESIGN-VALIDATOR and re-read from the
  raw series here: within partition 4 it is **1 of 6** (`6642`); the figure "three" is
  correct only at **run level — 3 of 20 completed provisions across all four partitions
  (p1 `5083`, p3 `5007`, p4 `6642`)**. The count arrived with ISSUE-FIXER's report of
  run 3 and was inherited into this document unchecked: a **run-level** count attached to
  a **partition-level** list, which is this repo's own documented anti-pattern
  ["Re-deriving the count while inheriting the unit being counted"](../../../docs/anti-patterns.md)
  — the same anti-pattern §2.5 C1 invokes against the "28 migrations" figure, recurring
  in this document's own text rather than in the source it was auditing. ISSUE-FIXER
  re-measured and flagged it. The correct statements are: partition 4 → **1 of 6 over
  5000 ms, max 6642 ms**; whole run → **3 of 20 over 5000 ms**, with no sibling load
  whatever.

  **The methodological caveat, which is the more important half of this correction.**
  `scratch/provision_latency.awk` measures the gap from a logged `CREATE SCHEMA
  "sandbox_X"` to the **next logged query naming the same `sandbox_X`**. A provisioning
  that never reaches a subsequent logged query — because the caller's `GenServer.call`
  timeout fired, the test process exited, and the migration's connection was torn down
  with it (§2.4 / §2.5 C3) — **never closes that gap and is therefore invisible to the
  instrument entirely.** The instrument thus **systematically under-samples exactly the
  tail this design is arguing about**: it can only ever report provisions that finished.
  That is why a run producing **three `{:claim, N}` call-timeout failures** simultaneously
  shows only **3 of 20 *completed* provisions** over 5000 ms — those three timeouts are
  themselves evidence of three further over-budget provisions the instrument could not
  see. On the reading that each timeout corresponds to one distinct provisioning in
  flight — which these per-test pools support, holding at most one claim at a time
  (INV-SP-T4) — run 3's true over-budget count is **at least 6 of at least 23**, not
  3 of 20. The exact number is not recoverable from the logs; the *direction* is, and
  the direction is the point. **This is a real limitation on every log-derived latency
  figure in §4.1 (rows 4 and 5), and it biases all of them low.** It does not touch the
  direct-probe rows (1–3), which use
  `max_wait_ms: 600_000` precisely so a slow provision is measured rather than converted
  into an exit — which is why §4.4's floor 1 is taken from a direct-probe sample and not
  from a log-derived one.

  **Why a post-fix green N=4 run is informative at all: the pre-fix base rate.** Two of
  two pre-fix N=4 runs in this worktree were red — **run 2: 11 failures** (partitions
  1/3/4 at 5/1/5), **run 3: 5 failures with siblings verifiably idle**. A condition that
  reproduces 2 out of 2 is what licenses reading a subsequent green as evidence of
  anything. **The signal is asymmetric, and RELEASE-VALIDATOR must not treat the two
  directions as equivalent:** a **red** N=4 run whose failures land in the ISS-0220 files
  means the fix did not land — that is a strong, near-conclusive signal. A **green** N=4
  run is **corroboration only**, because the failure is load-dependent and a green run is
  also what a lucky run looks like.

  The single-process probe and the N=4 suite are measuring different regimes, and only
  the latter is the regime the issue lives in. **A green N=4 run with idle siblings IS
  meaningful post-fix evidence**, and RELEASE-VALIDATOR should reproduce that condition
  and state explicitly whether siblings were idle when reporting it — but it corroborates;
  RT-1..RT-4 are the proof.

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
stated as a limit rather than a guarantee, and why §3.2's `release_call_timeout/0` is
sized to absorb a possible in-flight provisioning ahead of it **once this case becomes
reachable** — it is not reachable today, which is exactly why §3.2 rests on
`safe_release/2`'s `rescue` hole rather than on head-of-line blocking.

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
| `lib/letflow/sandbox_pool.ex` | Delete `@call_timeout_buffer_ms` + comment (§7.1). Add `@default_provision_timeout_ms 44_000`. Add public `provision_timeout_ms/0`, `claim_call_timeout/1`, `release_call_timeout/0` with `@spec`s + `@doc`s (§5.1, §6). Change `claim/2`'s and `release/2`'s `GenServer.call` timeout arguments (§7.2, §7.3). Add the moduledoc section (§7.4). | ELIXIR-DEV |
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
`scratch/iss0220_exit_shape_probe.exs` — the three probes behind V5, V6, V7 — plus
`scratch/b1_cascade.py`, `scratch/b1b2_prose.py`, `scratch/b3b4_prose.py`,
`scratch/s0_prose.py`, `scratch/final_prose.py`, which are edit scripts for this
document's rework rounds and carry no findings of their own. **None of these is
ISSUE-FIXER's evidence** — that set is listed, with its provenance, in §0.

---

## 15. Acceptance-criteria traceability

The issue record was not available in this worktree (§0), so the criteria are taken
verbatim from this run's own `task` block (rank 1 of `core-directives.md`'s Instruction
Precedence chain), which enumerated five, plus its closing instruction.

| # | Criterion | Where satisfied | Concrete element |
|---|---|---|---|
| 1 | Split the two budgets `claim/2` conflates; `max_wait_ms` keeps its meaning; introduce a configurable provisioning budget; call timeout becomes the sum; expose the derivation publicly so tests derive from one source of truth | §3.1, §5.1, §6, §7.2 | `provision_timeout_ms/0`, `claim_call_timeout/1`, `release_call_timeout/0`; `config :letflow, :sandbox_pool, provision_timeout_ms:`; INV-SP-T1/T2/T5 |
| 1a | *(sub-decision)* per-pool override via `start_link/1` — "if that is coherent with the existing `:max_concurrent` precedent" | §3.3 (C) | **Rejected with reasons** — not coherent: the budget is consumed client-side, `:max_concurrent` server-side. Deferred as OQ-2. |
| 2 | Justify the default from the measurements, never from "what made the run go green"; state the number, the distribution, the multiples, the ceiling | §4 (all), §4.5 | **44 000 ms**; hard exclusion at floor 1 = 15 373 ms (observed legitimate max); tail explicitly **not estimable** from n=40 cold-start samples, and no second numeric floor manufactured (§4.4 records the withdrawn one and why); separation rule: ceiling − floor 1 = 60 000 − 15 373 = **44 627 ms admissible ceiling**, largest clean value below it = 44 000 (separation 16 000 ms > 15 373); 26.5× quiet median, 12.1× quiet max, 2.86× the highest observed sample, 0.73× the ExUnit ceiling |
| 3 | Re-size the test-side bounds from the same source of truth; every assertion stays intact; say so explicitly | §8.0, §8.1, §8.2, §8.3, §8.4 | five sites re-sized via `claim_rendezvous_timeout/1` / `pool_op_rendezvous_timeout/0`; §8.0's explicit no-weakening statement; two bounds deliberately unchanged with reasons; two files verified to need no edit, cross-checked against the measured failure decomposition |
| 4 | Name but do not fix the adjacent defect (provisioning blocks the mailbox); recommend a successor issue with reasoning | §12, INV-SP-T4 | successor-issue title, statement, why-scoped-out, severity; INV-SP-T4 states the limit rather than over-claiming a bound |
| 5 | Specify a regression-test contract that fails pre-fix and passes post-fix, and is not vacuous | §10 (all) | RT-1..RT-4; black-hole + `catch_exit` technique; RT-2/RT-3 pin the derived integer inside the real call's own exit reason (V7) and fail pre-fix **behaviourally**, not by compile error; RT-1/RT-4 are drift guards, reported as such and not counted toward Step 4's evidence (§10.3's weight table) |
| 6 | *(closing instruction)* report anything in the diagnosis that is wrong | §2.5 | **C1** 31 migrations, not 28. **C2** `:ownership_timeout` is 120 000 ms, not 60 000 — and inapplicable under `:auto` mode, so ExUnit's 60 000 is the sole ceiling. **C3** the filing's contention hypothesis is wrong (adopted, and re-grounded on the zero-parallelism probe rather than the log tally this worktree cannot see). **C4** one omission: `release/2`'s own 5000 ms default (§3.2). Plus §4.5: the proposed 30 000 ms default is raised to 44 000 ms, because ISSUE-FIXER's own superseding n=40 data cut its stated multiple to ~1.95×. |

---

## 16. Open questions (explicit — not silently resolved)

**OQ-1 — the 44 000 ms default rests on ISSUE-FIXER's measurements, which this worktree
could not re-run.** §0 states which premises were verified first-hand and which were not;
every latency figure in §4.1 is in the "not re-verified" set, because re-measuring means
running the suite or the probe, which this run is forbidden to do. §10's contract depends
on none of them.

**Two specific weaknesses, named rather than averaged into "measurements":**

1. **Floor 1's artefact is absent.** Of the nine ISSUE-FIXER files in `scratch/` (§0),
   none is the loaded-host **sample A** series — yet that is where **15 373 ms** comes
   from, and §4.5 uses that one number twice: as floor 1, and (via P4) to fix the
   admissible ceiling at 44 627 ms. Both ends of the decision therefore rest on a
   reported summary this run could not inspect. Compounding it, sample A was taken under
   a **deliberately generated** load (`scratch/db_load.sh`, §2.2), not an observed one —
   so floor 1 is "the worst legitimate provisioning under a load we chose", and the
   choice of load is itself an input to the answer. §2.2 argues that choice is the right
   one (the generator matches the shape of contention the N=4 suite self-inflicts, per
   §10.4's run 3), but it is an argument, not a measurement. If sample A's raw series is
   ever recovered, or re-measured under a different load, and its maximum differs, **redo
   §4.5's rule** — do not adjust the answer.
2. **The log-derived rows under-sample the tail by construction** (§10.4): a provisioning
   killed by its caller's timeout never completes the gap `provision_latency.awk`
   measures. Rows 4 and 5 of §4.1 are therefore lower bounds on their own distributions.
   This biases against the chosen value, not for it — the real tail is at least as heavy
   as the one 44 000 was sized against — but it must not be forgotten when anyone reads
   those rows as evidence that provisioning is fast.

**What would force a re-derivation**, stated precisely because §5.1's `@doc` sends a
future reader here: a direct measurement producing an observed *legitimate*
provisioning above **15 373 ms**, which moves floor 1 — the only numeric input the
decision actually has (§4.4/§4.5). Nothing else does: not a green suite run, not a red
one, not a differing failure count, and not a preference. If floor 1 moves, redo §4.5's
rule against the new value; do **not** nudge 44 000. `scratch/claim_latency.exs` is the
instrument and is already written.

**And do not re-invent a second numeric floor from window-maximum ratios** — §4.4
records that construction, why it was withdrawn, and the specific way it is unstable
(a different but equally legitimate window pairing yields a floor above this document's
own ceiling, admitting no value at all).

**OQ-2 — a per-call provisioning-budget override (`claim/3`).** §3.3 (C) rejects the
`start_link/1` shape as incoherent and names the coherent alternative as an explicit
caller-side argument. Not built: no current caller needs one
(`Definitions.apply_promotion_assertion_rerun/6` is the only caller and passes only
`max_wait_ms`), and adding an unused arity now would be speculative API surface. Add it
when a concrete caller needs a non-global budget — not pre-emptively.

**OQ-3 — whether `release_call_timeout/0` should eventually diverge from
`provision_timeout_ms/0`.** §3.2 deliberately reuses the one calibrated number, and the
measurements now show why the two are *currently* the same size for a reason that is
not about the DROP at all: the DROP costs 20–498 ms (max 687 ms), whereas a mailbox wait
behind an in-flight provisioning **would** cost up to 15 373 ms. That wait is not
reachable today (INV-SP-T4), so reusing the calibrated number is one-source-of-truth plus
future-proofing, not a present mechanism (§3.2). Once §12's successor issue removes head-of-line
blocking, the release path's real requirement collapses to just the DROP cost, and a
much smaller, independently derived number becomes correct. Left open rather than
pre-committed, because the successor issue's shape determines it.

**OQ-4 — a production HTTP timeout for the sandbox path, once one exists.** V15
confirms no HTTP route currently reaches `apply_promotion_assertion_rerun/6`, so a
44 000 ms client-side budget has no user-facing latency consequence today. When PRM-06's
HTTP integration lands (REQ-040's own deferred half), that route needs its own
request-level deadline and must not simply inherit this one — a 44-second hanging HTTP
request is a different, worse failure than a 44-second hanging test. Named now so the
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
