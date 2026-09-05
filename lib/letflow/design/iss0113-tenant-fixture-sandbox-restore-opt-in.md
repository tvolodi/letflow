# ISS-0113 — Per-caller opt-in Sandbox-mode restore in `Letflow.TenantFixture.provisioned_tenant!/1`

Status: design (WF-03 Step 2, `WF03-ISS0423-20260905`). Test-only
(`test/support/tenant_fixture.ex`, `config/test.exs`). Does not change
`Letflow.TenantProvisioning.provision_tenant_schema/1`,
`replay_migrations/2`, or any production code path. Builds on, does not
absorb or re-litigate, ISS-0427 (template clone, resolved) or ISS-0428
(parallel-runner wiring, resolved).

## 0. Inputs treated as load-bearing facts, re-verified below rather than
   inherited

Per `docs/anti-patterns.md`'s "inheriting a claim instead of re-deriving it,"
every quantitative claim this design leans on that the dispatching handoffs
also asserted was independently re-checked against the current repository
state (`git` HEAD at design time), not copied from the handoff text:

- **ISS-0113's own investigation** (`docs/issues/ISS-0113.yaml`,
  `investigated_at: 2026-08-21T13:49:05Z`) is read in full and is this
  design's primary input: a blanket restore-to-`:manual` inside
  `provisioned_tenant!/1` was tried for real and reverted after 12/125 tests
  failed across three independently-real mechanisms (full detail in §2
  below, quoted precisely rather than paraphrased, since the decision
  procedure in §2 is keyed to their exact shape).
- **`test/support/tenant_fixture.ex:206`** — confirmed by direct read (this
  session): `Sandbox.mode(Letflow.Repo, :auto)` is the first statement of
  `provisioned_tenant!/1`, unconditional, with no matching restore anywhere
  in the function or in `teardown/2`. This is the exact call ISS-0113 and
  ISS-0423 both name.
- **The "87 call sites" / "93 async:true files" figures from the dispatching
  handoff do NOT mean what the task description implies, and this gap is the
  single most important correction this design makes before proposing
  anything.** Re-counted directly against the current tree, this session:
  - `grep -rl "provisioned_tenant!(" test --include=*.exs` (excluding the
    definition file itself): **46 distinct test files** call
    `Letflow.TenantFixture.provisioned_tenant!/1` directly (340 raw
    call-occurrences across those files — most files call it more than
    once, per-test or per-`describe`).
  - Of those 46 files, **the number declared `async: true` is zero.**
    Verified by reading each file's `use Letflow.DataCase, async: ...` line,
    not by grepping the bare string `async: true` (which produces false
    positives — see next bullet). Every one of the 46 is `async: false`.
  - A bare `grep -rl "async: true" test` (the shape that plausibly produced
    the handoff's "93 async: true files" figure) returns 147 files
    project-wide, but the intersection of that set with the 46
    `provisioned_tenant!`-calling files is **also zero** once each hit is
    read in context: the four files that superficially matched both greps
    (`test/letflow/api/context_test.exs`,
    `test/letflow/definitions/promotion_assertion_rerun_test.exs`,
    `test/letflow/identity_test.exs`,
    `test/letflow/plugs/admission_pipeline_test.exs`) all contain the
    literal substring `async: true` only inside moduledoc PROSE explaining
    *why the file is `async: false`* (e.g. "unlike its pre-REQ-063 version,
    which had ... tests running `async: true`") — none has a real
    `use Letflow.DataCase, async: true` declaration. Confirmed line-by-line
    for all four.
  - The same check against the wider 51-file superset (files matching the
    looser pattern `provisioned_tenant!` with no trailing `(`, which also
    catches moduledoc mentions of the function name) surfaces one more
    superficial hit,
    `test/letflow/routers/mobile_tenant_config_test.exs` — read in full:
    it is genuinely `async: true`, but its moduledoc explicitly documents
    that it does **not** call `TenantFixture.provisioned_tenant!/1` at all
    ("no `Letflow.TenantFixture` schema-provisioning/migration-replay/
    `:auto`-mode machinery is needed here ... `async: true` is therefore
    safe") — it only *mentions* the function name in prose contrasting
    itself with `identity_test.exs`. Confirmed by grep: zero actual calls
    in that file.

  **Conclusion, stated plainly because it changes the shape of this design
  materially from what the dispatching task assumed:** there is no existing
  file today that is both `async: true` and a caller of
  `provisioned_tenant!/1`. Fixing ISS-0113's blanket-`:auto`-leak, by
  itself, unlocks **zero** files' worth of dormant async execution, because
  no file is silently blocked from running the async mode it already
  declared — every caller already, correctly, declared `async: false`
  precisely because of the mechanism ISS-0113 describes. **"Conversion" in
  this design therefore means what it plainly has to mean: taking specific,
  individually-verified `async: false` → `async: true` flips at call sites
  that this design's own decision procedure (§3) clears against ISS-0113's
  three mechanisms — not "un-defeating" async on files that already declare
  it.** This does not make the fix pointless — the 93-file/1.4%-async
  measurement in the dispatching diagnosis is real and is about *other*
  test files entirely (files with real Postgres work that don't touch
  `TenantFixture` at all, or that already tolerate `:auto`'s ambient
  side-effects some other way); it does mean this design's own contribution
  is scoped precisely to the `TenantFixture`-calling population, and must be
  described as "make N additional files safely async-capable," not "unlock
  N already-async files."

- **`config/test.exs`** confirmed read directly: `pool_size` defaults to
  `System.schedulers_online() * 2` when `TEST_POOL_SIZE` is unset (plain
  `mix test`), and to `System.get_env("TEST_POOL_SIZE") |> String.to_integer()`
  when set (`scripts/test_parallel.sh`'s own partitions). No
  `--max-cases` override exists anywhere in `test/test_helper.exs`,
  `mix.exs`, or any config file (grepped, zero hits) — so ExUnit's own
  default async case concurrency, `System.schedulers_online()`, is what
  actually governs this host. This host (`nproc` = 16, confirmed by
  ISSUE-FIXER's step-01 handoff and independently by this design's own
  `nproc` call) therefore has ExUnit scheduling up to **16** async cases
  concurrently under a plain `mix test`, and `scripts/test_parallel.sh`
  computed `TEST_POOL_SIZE=5` per partition on the same host per decision
  0009's own verification numbers (N=16, budget=85, computed=85/16=5).

## 1. Scope and non-goals

**In scope:** the opt-in mechanism on `provisioned_tenant!/1` (§2), the
mechanical decision procedure for classifying any of the 46 current call
sites (§3), a concrete, named, bounded conversion scope for this run (§4),
the peak-concurrent-DBConnection-checkout sizing analysis (§5), and the
decision-0009/ISS-0287 reconciliation (§6).

**Out of scope, explicitly:**
- Converting all 46 files in one pass. §4 explains why.
- Any change to `Letflow.TenantProvisioning`, `Letflow.Test.TenantTemplate`,
  or any production module.
- Any change to `scripts/test_parallel.sh`'s `N`-derivation or
  `TEST_POOL_SIZE` formula (decision 0009 territory — untouched, see §6).
- A `Letflow.SandboxPool`-backed rework of `TenantFixture` itself (the
  broader lever ISSUE-FIXER's step-01 diagnosis explicitly deferred as a
  separate, larger follow-on issue if this fix's real measured speedup
  leaves a large remaining gap — not folded in here).
- Deleting, skipping, or weakening any existing test assertion (ISS-0423
  AC4/AC6) — this design's only content changes are (a) a new opt-in
  `opts` key on `provisioned_tenant!/1` with an unchanged default, and (b)
  flipping `async: false` → `async: true` plus passing that new opt-in key
  at the call sites named in §4. No assertion text changes.

## 2. ISS-0113's three failure mechanisms, restated precisely (normative for §3)

Quoted/restated from `docs/issues/ISS-0113.yaml`'s `investigation_note`,
since §3's decision procedure is keyed to these exact shapes and a
paraphrase that drifts from the original would silently narrow or widen
what the procedure catches:

- **Mechanism (a) — "self-checkout."** A test that, LATER IN THE SAME TEST
  BODY, calls `Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)` itself and
  pattern-matches on `:ok`, relying on ambient `:auto` mode making a fresh
  checkout always succeed. If the fixture has already restored `:manual`
  mode and holds a checkout for that same process, the test's own later
  checkout returns `{:already, :owner}` instead of `:ok`, and the match
  fails. (ISS-0113's own example: `identity_test.exs:268`.)
- **Mechanism (b) — "concurrent multi-process DB access."** A test that
  deliberately spawns a SEPARATE process (`Task.start/1`, `Task.async/1`,
  bare `spawn/1`, or equivalent) that itself needs to hold a real,
  independent Postgres transaction/lock concurrently with the test
  process — e.g. proving `FOR UPDATE` lock-contention behavior, or a
  concurrent-delete race. A single sandboxed connection is owned by one
  process; it cannot serve two processes wanting independent transactions
  at once. Restoring `:manual` breaks the very thing such a test is
  testing. (ISS-0113's own example:
  `engine/reconstruction_test.exs` AC5/AC6's `with_locked_projection/3`.)
- **Mechanism (c) — "second provisioning call."** A test that calls
  `TenantProvisioning.provision_tenant_schema/1` and/or
  `replay_migrations/1` (directly, or via a SECOND
  `provisioned_tenant!/1` call, or via any other path that runs
  `Ecto.Migrator`) A SECOND TIME within the same test body, beyond the
  fixture's own initial provisioning. `Ecto.Migrator` cannot run under a
  sandboxed single connection — exactly the reason `:auto` mode is needed
  in the first place — so a second provisioning call after the fixture has
  already restored `:manual` fails with `{:error, :provision_failed}` or
  equivalent. (ISS-0113's own example:
  `promotion_assertion_rerun_test.exs`, 7 tests.)

No other mechanism is on record as having caused a real, measured failure
under the attempted 2026-08-21 fix. §3's procedure checks for exactly these
three and states explicitly (§3.4) what to do about a fourth mechanism this
design has not anticipated, should one turn up during conversion.

## 3. The opt-in mechanism

### 3.1 Signature and `@spec` change

```
@type opts :: [
        slug_prefix: String.t(),
        display_name: String.t(),
        oidc_mode: :enabled | :disabled,
        expected_tables: [String.t()] | :default,
        teardown: boolean(),
        template: :clone | :replay,
        restore_sandbox: boolean()          # NEW — this design
      ]

@spec provisioned_tenant!(opts()) :: tenant_fixture()
```

`opts[:restore_sandbox]` defaults to `false` — today's exact, unchanged
behavior (`Sandbox.mode(Letflow.Repo, :auto)` left in effect for the rest of
the test, never restored). This default MUST NOT change; the whole point,
per ISS-0113's own conclusion and this design's task, is that nothing
regresses silently for the 44 files (46 minus the 2 named in §4) that are
not touched by this run.

### 3.2 Behavior when `restore_sandbox: true`

Exactly the pattern ISS-0113's own investigation note identifies as already
proven correct, independently, in the hand-rolled helpers of
`test/letflow/identity/user_test.exs`, `group_test.exs`,
`tenant_role_test.exs`, and `role_registry_test.exs` — this design adopts
that same shape as an *opt-in branch* inside the shared fixture rather than
re-inventing a new one:

1. After schema provisioning (`provision_schema!/2`) and
   `assert_schema_complete!/2` both succeed exactly as today — i.e. this
   branch is an ADDITIONAL final step, not a replacement for anything
   currently in the 1–6 step sequence documented in
   `provisioned_tenant!/1`'s own moduledoc.
2. `Sandbox.mode(Letflow.Repo, :manual)`.
3. `:ok = Sandbox.checkout(Letflow.Repo)` — a fresh checkout for the calling
   test process, mirroring the four hand-rolled helpers' own sequence.
4. Register (in addition to the teardown `on_exit/1` already registered
   earlier in the function per today's ordering) a SECOND `on_exit/1`
   callback that restores `Sandbox.mode(Letflow.Repo, :auto)` — this
   mirrors ISS-0113's own investigation note's finding that
   `teardown/2` needs a defensive `:auto` at its own top, since
   `ExUnit.OnExitHandler` runs teardown in a process with no checked-out
   connection once mode is `:manual`; specified here as its own dedicated
   callback (registered only when `restore_sandbox: true`) rather than an
   unconditional line inside the shared `teardown/2`, so the 44
   `restore_sandbox: false` (default) call sites' teardown path is provably
   byte-for-byte unchanged — ISS-0113's own attempted fix put this line
   unconditionally at the top of `teardown/2` and that is part of what this
   design deliberately avoids repeating.
5. `on_exit/1` callbacks run LIFO (ExUnit's documented behavior) — so the
   pre-existing schema-drop teardown (registered earlier, step 3 of the
   unchanged 1–6 sequence) still runs AFTER this new `:auto`-restoring
   callback fires, meaning the schema-drop teardown's own `Repo.query!`
   calls execute under `:auto` mode, unchanged from today. This ordering is
   load-bearing and must be preserved exactly: registering the `:auto`
   -restore callback AFTER the teardown-schema-drop callback is already
   registered (which step 3 of the existing sequence already does, before
   provisioning even begins) achieves this for free via LIFO ordering — no
   new sequencing logic is needed, only registering the new callback at the
   point in the function where `restore_sandbox: true`'s post-provisioning
   branch runs (i.e., last).

### 3.3 What `restore_sandbox: true` does NOT do

- Does not change `provision_schema!/2`, `assert_schema_complete!/2`, or
  any of steps 1–6 of the existing sequence — those run exactly as today,
  under `:auto` mode, for every caller regardless of `restore_sandbox`.
- Does not touch `capture_schema_state/1`, `expected_tenant_tables/0`, or
  any of the failure-reporting machinery (`report_and_raise/3`,
  `raise_with_report/3`) — those are orthogonal to sandbox mode.
- Does not retry or poll — matching the module's own existing "one-shot,
  no retry" discipline (moduledoc, `capture_schema_state/1`'s doc).

### 3.4 A fourth mechanism found during conversion, not anticipated here

If a future call site (in this run's tranche or a later one) fails under
`restore_sandbox: true` in a way that does not match mechanisms (a)/(b)/(c)
verbatim, per `docs/anti-patterns.md`'s "don't silently resolve a
conflict": do not force-fit it into one of the three above. Revert that one
call site's `restore_sandbox: true` flip, leave the default `false`
unchanged, and report the new mechanism for a design update — the same
discipline ISS-0113's own investigation followed the first time (it found
three, stated them precisely, and proposed exactly this opt-in shape
rather than a blanket change) is what this design continues, not a
one-time correction.

## 4. Conversion scope for THIS run

### 4.1 Chosen scope: 2 files

- `test/letflow/secrets_test.exs` (REQ-190)
- `test/letflow/webhooks_test.exs` (REQ-181)

Both flip `use Letflow.DataCase, async: false` → `async: true`, and both
call sites of `Letflow.TenantFixture.provisioned_tenant!/1` in each file
gain `restore_sandbox: true`.

### 4.2 Why these two, mechanically, per §3's decision procedure

For each of the 46 files, the procedure is: read the file (not grep alone —
grep surfaces candidates, only a read confirms), and answer three yes/no
questions in order, stopping at the first "yes":

1. Does this file's test body call `Sandbox.checkout/1`,
   `Sandbox.mode/2`, or any function that internally does so (a second
   `provisioned_tenant!` call with default `restore_sandbox: false` counts
   as a no-op here since it doesn't reference Sandbox directly, but see
   Q3), anywhere AFTER its own initial `provisioned_tenant!/1` call,
   expecting a specific ambient-mode-dependent return value? → **mechanism
   (a), UNSAFE, do not flip.**
2. Does this file spawn a second process (`Task.start/1`, `Task.async/1`,
   `spawn/1`, `spawn_link/1`, or equivalent) anywhere in a test body, where
   that process performs its own independent Postgres work (a query,
   transaction, or lock) concurrently with the test process? → **mechanism
   (b), UNSAFE, do not flip.**
3. Does this file call `TenantProvisioning.provision_tenant_schema/1`,
   `replay_migrations/1` (or `/2`), or `provisioned_tenant!/1` a SECOND
   time within the same test body (beyond a `setup`/`describe`-level single
   provisioning shared by every test in that block)? → **mechanism (c),
   UNSAFE, do not flip.**

Only if all three answers are "no" for EVERY test in the file is the file
classified **safe to flip**. This is deliberately whole-file, not
per-test: ExUnit's `async:` setting is module-wide (the same fact
`identity_test.exs`'s own moduledoc states), so a single mechanism-tripping
test anywhere in the module makes the whole file unsafe to declare
`async: true`, regardless of how many other tests in it are individually
clean.

Applied, this session, by direct read of each file (not inferred):

| File | Q1 (self-checkout) | Q2 (2nd process) | Q3 (2nd provisioning) | Verdict |
|---|---|---|---|---|
| `secrets_test.exs` | No — zero `Sandbox.` references outside the moduledoc's prose | No — zero `Task.`/`spawn(` in the file | No — one `provisioned_tenant!` call site (in a private `provisioned_tenant/1` helper), called once per test via `setup`-style helper, no nested second call found | **Safe** |
| `webhooks_test.exs` | No — zero `Sandbox.` references outside the moduledoc's prose | No — zero `Task.`/`spawn(` in the file | No — one `provisioned_tenant!` call site, same single-call shape as `secrets_test.exs` | **Safe** |
| `service_catalog_test.exs` | — | **Yes** — `Task.start/1` (line ~429) + `Task.async/1` (line ~443) hold a real row lock in a separate process while `ServiceCatalog.delete/1` runs concurrently (AC: "a concurrent delete of the same row is treated as a benign not-found") | — | **Unsafe (b)** |
| `routers/onboarding_test.exs` | — | — | **Borderline/unsafe** — does not call `provisioned_tenant!/1` for its own onboarding-created tenants at all (creates tenants via a real `POST /onboarding` call instead), but its own `cleanup_onboarded_tenant!/1` helper issues `Sandbox.mode(Letflow.Repo, :auto)` directly inside an `on_exit/1`, which is exactly the ambient-`:auto`-dependent shape §3's procedure exists to protect against — flipping this file's `async:` without also auditing that helper against mechanism (a)/(c) is unverified, so it is excluded from this tranche's scope entirely (not `provisioned_tenant!/1`-mediated, so §3's procedure as written does not even directly apply — flagged as an open question, §7 OQ-1, for whoever scopes a later tranche of non-`TenantFixture` `:auto`-using files) | **Excluded, not classified this run** |
| Remaining 42 files | Not individually re-verified this run | Not individually re-verified this run | Not individually re-verified this run | **Not classified this run — see §4.3** |

### 4.3 Why 2 files, not more, not all 46

- **Every file must be read, not grepped, to classify safely.** §4.2's
  table already shows two grep-clean-looking candidates
  (`onboarding_test.exs`'s bare single mention, `mobile_tenant_config_test.exs`
  from §0) that turned out to need a full read to correctly exclude or
  confirm. A mechanical grep alone is necessary but not sufficient per
  ISS-0113's own conclusion ("per-caller opt-in... each needs individual
  verification"); classifying all 46 correctly is realistically a full
  file-by-file read of every one, which this design step budget does not
  cover and which ISS-0113's own text explicitly assigns to whoever
  executes the migration (ISS-0112's territory), not to the design step.
- **A first tranche exists to prove the opt-in mechanism itself is correct
  in a real, running suite** before committing to a larger batch — the same
  incremental-adoption discipline ISS-0427's own design used (`template:
  :clone` shipped as an opt-in-by-default with an explicit `:replay`
  escape hatch, not a flag-day rewrite of every caller's assumptions).
  Two files, both single-tenant/single-process/single-provisioning-call,
  both already read in full this session and independently confirmed
  clean against all three mechanisms, is a genuinely bounded, defensible
  first step — not an arbitrary round number.
- **The peak-checkout arithmetic (§5) explicitly wants a SMALL first
  tranche.** Converting even a modest handful of files to real `async:
  true` immediately exposes them to ExUnit's full
  `System.schedulers_online()` scheduling concurrency (16 on this
  design's verification host) — see §5 for why bounding the tranche size
  is a hard constraint here, not merely a caution.
- **Zero tests may be deleted, skipped, or weakened (ISS-0423 AC4/AC6).**
  A larger, hastily-classified tranche risks a wrong classification
  surfacing as a flaky/failing test in CI, which — under this project's own
  "zero manual work" and "no speculation" rules — would then need either a
  revert (acceptable, cheap) or a rushed in-place fix (risks exactly the
  weakening this design must not introduce). Two files, both verified by
  direct read against all three named mechanisms, minimizes that risk to
  as close to zero as a design step can certify without itself running
  the suite.
- **The remaining 44 files (46 minus these 2) are explicitly NOT touched by
  this run** — their `async: false` declaration and `restore_sandbox`
  default of `false` are both left exactly as-is. A later run repeating
  §4.2's table-building procedure against the next batch is the intended
  path to closing more of the gap, not a larger scope forced into this one.

## 5. Peak concurrent DBConnection checkouts — the hard constraint

### 5.1 What changes, mechanically

Today, `secrets_test.exs` and `webhooks_test.exs` are `async: false`.
ExUnit runs every `async: false` module strictly serially, one test process
at a time, after all `async: true` modules have started (ExUnit's
documented "sync modules run after all async modules complete" scheduling —
already cited by this codebase's own `tenant_provisioning_test.exs`
moduledoc, per `identity_test.exs`'s cross-reference). Under `async: false`,
each of these two files' tests independently holds at most **1** checked-out
connection at a time, and the two files never run concurrently WITH EACH
OTHER either, since ExUnit drains the sync queue serially too.

After this design's flip, both files become `async: true`. ExUnit may then
schedule any of their tests (and any other `async: true` module's tests)
concurrently, up to its own case-concurrency default of
`System.schedulers_online()`.

### 5.2 The actual peak-checkout number this design produces

**Peak concurrent DBConnection checkouts contributed by this design's own
converted tranche: 2.**

Justification: `secrets_test.exs` and `webhooks_test.exs` are the only two
files this design flips. Neither file itself spawns a second process that
holds an independent connection (§4.2's Q2 = No for both, confirmed by
direct read) — every checkout each file's own tests hold is exactly one
per currently-running test process in that file, and ExUnit runs at most
one test per test process. So the absolute ceiling this design's own
change can add to the system is bounded by "how many of THESE two files'
tests can ExUnit run at the same literal instant" — which is capped by
`min(total test count needing simultaneous execution, scheduler
concurrency)`, but since there are only 2 files (not 2 tests — many tests
each, but ExUnit still only ever runs one test per module-owned test
process **and** the two whole files' test suites are what's newly exposed
to true `async: true` concurrency), the worst case worth stating precisely
is: **at most as many of {secrets_test.exs, webhooks_test.exs}'s
individual tests as ExUnit schedules concurrently, which is bounded above
by `System.schedulers_online()` (16 on this design's verification host),
but is NEVER attributable to this design's converted tranche alone in
isolation** — the real system-wide peak is the sum across EVERY `async:
true` module in the suite (147 files project-wide, per §0), not just these
two. This is the point §5.3 makes explicit: this design's tranche is a
small, bounded ADDITION to an already-existing, already-governed
system-wide async population, not a new peak-checkout regime of its own.

### 5.3 Fitting under pool_size — both scenarios

**Plain `mix test` (no `TEST_POOL_SIZE` set).** `pool_size =
System.schedulers_online() * 2` — on this design's 16-core verification
host, `pool_size = 32`. ExUnit's own async case concurrency defaults to
`System.schedulers_online()` = 16. **The system-wide worst case — every
scheduler slot running a distinct async test that each holds one checkout —
is 16 concurrent checkouts, against a pool_size of 32: 16 connections of
slack, before this design's 2-file tranche is even considered.** Adding
`secrets_test.exs`/`webhooks_test.exs` to the `async: true` population does
not raise this ceiling at all — ExUnit's own scheduler-bound concurrency
(16) is already the binding constraint, not the number of `async: true`
FILES (147 → 149 after this change is a change in eligible population,
not in the concurrency ceiling ExUnit will actually schedule at once,
which stays pinned to `schedulers_online()` regardless of how many files
are eligible to be picked from). **Verdict: fits, with wide margin (32 ≥
16), unconditionally, because `pool_size` already assumed
`schedulers_online()`-wide concurrency when it was set to
`schedulers_online() * 2` — this design does not change that arithmetic's
inputs.**

**`scripts/test_parallel.sh` partition (N=16 on this host, per decision
0009's own verified numbers).** `TEST_POOL_SIZE = 5` per partition
(decision 0009's own verification: `budget=85`, `computed=85/16=5`, no
floor clamp needed). Each of the 16 partitions runs its OWN `mix test`
subprocess against a DISJOINT subset of test files (`--only`/file-partition
assignment is `test_parallel.sh`'s own job, orthogonal to this design), so
each partition independently faces the same `System.schedulers_online()` =
16 ExUnit scheduling ceiling — **but** a partition's actual runnable
concurrency is also capped by how many `async: true` test files THAT
partition was actually assigned, which is at most a small fraction of the
suite's 149 total `async: true` files (147 today + this design's 2) spread
across 16 partitions, roughly 9 per partition on average, well under both
the scheduler ceiling of 16 and the partition's own `pool_size` of 5.
**This is where the hard constraint actually bites, and this design states
it plainly rather than hand-waving past it:** if a single partition were
unlucky enough to be assigned, say, 6+ genuinely-concurrent-eligible async
files whose tests all became runnable at the same instant, that partition's
own 5-connection pool WOULD be the binding constraint, not the 16-wide
scheduler ceiling — but DBConnection's own pool behavior under exhaustion
is to QUEUE the checkout request (blocking that test process until a
connection frees), not to error or crash, UNLESS the wait exceeds the
pool's checkout timeout (Ecto's default `:queue_target`/`:queue_interval`
backpressure, not an immediate failure) — so a partition with more
`async: true` eligible tests than its `TEST_POOL_SIZE` degrades to more
intra-partition serialization among its own async tests, exactly the
behavior decision 0009's own text already describes and accepts ("a
partition with a smaller pool still runs, just with more internal
serialization... rather than failing to start"). **This design's own
2-file addition does not change this dynamic's existence — it already
applies to the pre-existing 147 `async: true` files today — it only adds 2
more files to the population that dynamic already governs, a negligible
proportional increase (2/147 ≈ 1.4%).** No mechanism beyond what decision
0009 already provides (the pool_size floor + WARN) is needed to keep this
design's own tranche bounded — see §6 for why this is a reconciliation, not
a new mechanism requirement, at THIS tranche's size.

### 5.4 What would make this a hard-stop instead of a fits-comfortably case

Stated explicitly per the task's own instruction ("if your design's own
converted batch could exceed pool_size, shrink the batch or add a
mechanism"): if a FUTURE, larger tranche converts enough files that a
single `test_parallel.sh` partition could plausibly be assigned more
simultaneously-runnable async tests than its own `TEST_POOL_SIZE` floor
(2, per decision 0009's `TEST_MIN_POOL_SIZE` default) AND those tests are
long-running enough that DBConnection's queue-and-wait backpressure would
breach Ecto's checkout timeout (default 15s) rather than merely
serializing quickly, THAT is the point a future design must either (a) cap
`--max-cases` for the suite (trading scheduler-wide concurrency for a
number that provably fits every partition's own smallest `TEST_POOL_SIZE`),
or (b) group newly-async files under a shared `ExUnit.Case` tag with an
explicit concurrency limit (`async: {module_tag, N}`-style grouping is not
native ExUnit — this would require a custom partial-async harness, out of
scope for this design). **This design's own 2-file tranche is far below
that threshold** (§5.3's arithmetic), so neither mechanism is proposed
here; this subsection exists so the NEXT tranche's design does not have to
re-derive the threshold question from scratch.

## 6. Reconciliation with decision 0009 / ISS-0287

**Confirmed: this design does not change `N`, does not change
`scripts/test_parallel.sh`'s own budget formula
(`usable_ceiling`/`budget`/`computed`/`TEST_POOL_SIZE` arithmetic, decision
0009 + its ISS-0287 addendum), and does not change `config/test.exs`'s
`pool_size` computation for either the plain-`mix-test` or
`TEST_POOL_SIZE`-set branch.** Nothing in §3's opt-in mechanism reads or
writes any of `TEST_MAX_CONNECTIONS`, `TEST_CONNECTION_HEADROOM`,
`TEST_MIN_POOL_SIZE`, `TEST_SUPERUSER_RESERVED`,
`TEST_NONPOOL_CONNECTION_RESERVE`, or `TEST_POOL_SIZE` itself — those
remain exactly decision 0009/ISS-0287's own governed surface, untouched.

**The genuinely new dimension this design introduces, confirmed (not
refuted) per ISSUE-FIXER's step-01 diagnosis's own framing:** decision
0009's formula answers "does `N × TEST_POOL_SIZE` (plus the ISS-0287
addendum's superuser/non-pool reserves) fit under Postgres
`max_connections`" — a CROSS-PARTITION question about how many partitions'
worth of FULLY-SATURATED pools can coexist. It says nothing about, and was
never meant to say anything about, how many of a SINGLE partition's OWN
`TEST_POOL_SIZE` connections its own internal `async: true` tests might
try to hold AT ONCE — that is an INTRA-partition question, one level
down, which 0009's `budget/N` arithmetic treats as a black box (it assumes
whatever happens inside one partition's pool is that pool's own problem,
and sizes the pool itself, `TEST_POOL_SIZE`, as the interface between the
two levels). This design's §5 is exactly that intra-partition question,
answered for the specific, small, bounded tranche in §4: the answer is
"fits comfortably, with wide margin, because ExUnit's own
`schedulers_online()`-wide scheduling ceiling is already accounted for in
how `pool_size`/`TEST_POOL_SIZE` were originally sized" (§5.3). **This is
not an amendment to decision 0009** — 0009's formula is correct and
sufficient for the cross-partition question it was built to answer, and
this design's tranche does not stress the intra-partition dimension enough
to require a NEW formula of its own (§5.4 states the threshold at which
one might). It is confirmation that a distinct, adjacent question exists,
correctly anticipated by ISSUE-FIXER's own diagnosis, resolved for this
tranche's size by direct arithmetic rather than by a new governing
document.

## 7. Open questions (explicit, not silently resolved)

- **OQ-1.** `test/letflow/routers/onboarding_test.exs`'s
  `cleanup_onboarded_tenant!/1` helper issues its own
  `Sandbox.mode(Letflow.Repo, :auto)` directly, independent of
  `TenantFixture.provisioned_tenant!/1` (this file does not call that
  function for its own onboarding-created tenants at all). This file, and
  any other file found to manage its own ad-hoc `Sandbox.mode(:auto)` calls
  outside `TenantFixture`, is NOT covered by this design's decision
  procedure (§3.2's classification questions are `TenantFixture`-call-site
  specific) and needs either a separate design pass extending the same
  three-mechanism framework to hand-rolled `:auto` users, or a deliberate
  decision that such files are out of scope for async conversion entirely.
  Not resolved here.
- **OQ-2.** §4.2's table classifies only 4 of the 46 files
  (`secrets_test.exs`, `webhooks_test.exs` as safe;
  `service_catalog_test.exs`, `onboarding_test.exs` as unsafe/excluded).
  The remaining 42 are explicitly unclassified by this design (§4.3) — a
  future tranche's design step must apply §3's procedure to each by direct
  read, not assume any of them are safe or unsafe by extrapolation from
  this tranche's two clean examples.
- **OQ-3.** This design does not itself run `mix test` against the
  converted tranche to empirically confirm no regression — that is
  TEST-RUNNER's/ELIXIR-DEV's job per this pipeline's own division of labor
  (design produces signatures and a verified-by-reading classification,
  not a verified-by-running one). CODE-DESIGN-VALIDATOR and, later,
  TEST-RUNNER's real `mix test`/`scripts/test_parallel.sh` run are what
  actually confirm §4.2's by-inspection verdicts hold under real execution.

## 8. Summary of concrete deliverables for ELIXIR-DEV

1. `test/support/tenant_fixture.ex`: add `restore_sandbox: boolean()` to
   the `opts()` type (§3.1), implement the post-provisioning branch (§3.2)
   guarded by `Keyword.get(opts, :restore_sandbox, false)`, touching no
   other line of the existing 1–6 sequence.
2. `test/letflow/secrets_test.exs`: `use Letflow.DataCase, async: false` →
   `async: true`; add `restore_sandbox: true` to the `provisioned_tenant/1`
   private helper's call to `Letflow.TenantFixture.provisioned_tenant!/1`.
3. `test/letflow/webhooks_test.exs`: same two edits, same shape, as item 2.
4. No other file changes. No assertion text changes anywhere.
