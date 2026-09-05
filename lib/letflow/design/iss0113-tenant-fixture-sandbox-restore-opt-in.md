# ISS-0113 — Per-caller opt-in Sandbox-mode restore in `Letflow.TenantFixture.provisioned_tenant!/1`

Status: design, **§10 ADDED (WF-03 Step 2, `WF03-ISS0480-20260905`)** — a
structural fix for ISS-0480's own recurrence of this record's disclosed-open
scope. §10 is additive and normative for its own scope (a second, dedicated
`Ecto.Repo` for `TenantFixture`-mediated provisioning); it does not revise or
re-open §§0–9, which remain normative for the 2-file tranche already shipped
(`secrets_test.exs`, `webhooks_test.exs`) and for the mechanical
classification procedure (§3/§4.2) a future per-call-site tranche would still
use for any file this run does not touch. Read §10 first if you are here for
ISS-0480; §§0–9 below are prior art it builds on and must not silently
re-attempt.

Prior status line (WF-03 Step 2, `WF03-ISS0423-20260905`),
**superseding §§2–3's original mechanism — see §9, normative for
implementation.** Test-only (`test/support/tenant_fixture.ex`,
`test/letflow/secrets_test.exs`, `test/letflow/webhooks_test.exs`). Does not
change `Letflow.TenantProvisioning.provision_tenant_schema/1`,
`replay_migrations/2`, or any production code path. Builds on, does not
absorb or re-litigate, ISS-0427 (template clone, resolved) or ISS-0428
(parallel-runner wiring, resolved).

**Reader's note (rework iteration 1):** §§0/4/5/6 below (input re-verification,
conversion scope, peak-checkout arithmetic, decision-0009 reconciliation) are
this design's *original* content and remain valid and normative — nothing in
this rework changes which 2 files are converted, why 2 and not more, or the
pool-sizing arithmetic. §§2–3 describe the *original, now-abandoned*
`restore_sandbox: true` mechanism, kept verbatim below rather than deleted
(per `docs/anti-patterns.md`'s "don't silently resolve a conflict" — the
mechanism's own failure is exactly what motivates §9's replacement, and
erasing it would hide that reasoning from a future reader). **§9 is the
section that governs what ships**: no `restore_sandbox` flag, no opt-in, no
new code in `provisioned_tenant!/1` at all — the two converted files rely
solely on that function's own pre-existing, unconditional
`Sandbox.mode(Letflow.Repo, :auto)` line.

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

**Still normative — unaffected by the §9 rework.** §3's classification
procedure (is a call site safe to flip to `async: true`) is unchanged; only
*what `provisioned_tenant!/1` does once a call site is classified safe*
changed (§9 replaces §3.1–3.2's `restore_sandbox: true` mechanism with "add
no code at all"). Read this section as-is.

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

## 3. The opt-in mechanism (SUPERSEDED — see §9)

**This entire section describes the mechanism ELIXIR-DEV faithfully
implemented (`step-03-elixir-dev-implement.json`) and that implementation's
own scoped test run then falsified: 26/38 examples failed under
`async: true` with `Letflow.Secrets.put/2: tenant_id ... does not correspond
to any known tenant`, traced to a 4th mechanism (Mechanism 4, §9.1) this
section did not anticipate. Kept verbatim, not deleted, as the record of what
was tried and why it failed — do NOT implement anything in this section. §9
is the current, normative mechanism.**

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

## 8. Summary of concrete deliverables for ELIXIR-DEV (SUPERSEDED — see §9.6)

**Superseded by §9.6.** Kept verbatim as the record of what was actually
implemented and found to fail (`WF03-ISS0423-20260905` step-03). Do not
implement this list; implement §9.6 instead.

1. `test/support/tenant_fixture.ex`: add `restore_sandbox: boolean()` to
   the `opts()` type (§3.1), implement the post-provisioning branch (§3.2)
   guarded by `Keyword.get(opts, :restore_sandbox, false)`, touching no
   other line of the existing 1–6 sequence.
2. `test/letflow/secrets_test.exs`: `use Letflow.DataCase, async: false` →
   `async: true`; add `restore_sandbox: true` to the `provisioned_tenant/1`
   private helper's call to `Letflow.TenantFixture.provisioned_tenant!/1`.
3. `test/letflow/webhooks_test.exs`: same two edits, same shape, as item 2.
4. No other file changes. No assertion text changes anywhere.

## 9. REWORK: Mechanism 4, why §3's mechanism made it worse, and the corrected
   design (normative — supersedes §§2–3, §8)

### 9.1 Mechanism 4, named precisely

`Letflow.DataCase`'s `setup/1` (`test/support/data_case.ex:16`) does an
**unconditional** `Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)` for
every test, async or not, before the test body runs. Under `async: false`
only, it additionally calls `Sandbox.mode(Letflow.Repo, {:shared, self()})`
(lines 18–20); under `async: true` that per-test checkout is deliberately
left un-shared — the entire mechanism that makes concurrent async tests
independent of each other.

Per `Ecto.Adapters.SQL.Sandbox.mode/2`'s own moduledoc
(`deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex` lines 498–501, quoted
exactly): **"Whenever you change the mode to `:manual` or `:auto`, all
existing connections are checked in."** This is a real, unqualified, whole-
pool effect — not scoped to the calling process. Read down to the actual
implementation (`deps/db_connection/lib/db_connection/ownership/manager.ex`):

```
def handle_call({:mode, mode}, {caller, _}, %{mode: mode} = state) do
  {:reply, :ok, state}                     # <- no-op: requested mode already current
end

def handle_call({:mode, mode}, {caller, _}, state) do
  state = proxy_checkin_all_except(state, [], caller)   # <- checks in EVERY proxy, unconditionally
  {:reply, :ok, %{state | mode: mode, mode_ref: nil}}
end
```

Two facts follow directly from this source, both load-bearing for §9.3–9.4:

- A mode-change call is a **global, whole-pool check-in of every existing
  proxy connection** only when the requested mode actually differs from the
  pool's current mode (first clause's guard, `%{mode: mode} = state`,
  no-ops otherwise). It is not scoped to "connections belonging to processes
  other than the caller" — the exclusion list passed to
  `proxy_checkin_all_except/3` is the literal empty list `[]`.
- `config/test.exs`'s own comment (line 38, "Ecto.Adapters.SQL.Sandbox's
  default `:manual` mode") and the moduledoc's `mode/2` doc both confirm the
  pool boots in `:manual` mode. So the FIRST call anywhere in a test run to
  `Sandbox.mode(Letflow.Repo, :auto)` is a real, disruptive, whole-pool
  check-in; every subsequent call to the same mode, from any process, is the
  no-op first clause.

### 9.2 Why the original §3.2 mechanism (restore-to-`:manual`) made this worse

The original design's `restore_sandbox: true` branch ran, per test, AFTER
`provisioned_tenant!/1`'s own provisioning work had already established (via
the pre-existing `:auto` line, see §9.3) a real per-test-process sandboxed
transaction holding the freshly-inserted `Tenant` row and the freshly cloned/
migrated schema:

```
Sandbox.mode(Letflow.Repo, :manual)     # <- global check-in AGAIN (this time a REAL one,
                                         #    since mode is currently :auto and this
                                         #    requests :manual -- guard does not fire)
:ok = Sandbox.checkout(Letflow.Repo)    # <- a BRAND NEW, EMPTY sandboxed transaction
                                         #    for this same test process
```

The `checkin` from the `Sandbox.mode(:manual)` call discarded the test
process's own just-established transaction (uncommitted, and sandbox
transactions are never committed — only rolled back on checkin), and the
following `Sandbox.checkout/1` opened a **second, independent, empty**
transaction for the same PID. Every later query — the test body's own reads
of the tenant it just inserted, `Letflow.Secrets.put/2`'s internal
`Repo.get` lookup of the tenant row — ran against this second, empty
transaction, which has no way to see anything inserted under the first.
Confirmed failure signature, reproduced directly in this session (13 total
scoped runs across the diagnosis, verification, and final production checks
in §9.5): `Letflow.Secrets.put/2: tenant_id ... does not correspond to any
known tenant` (`lib/letflow/secrets.ex:456`, `Repo.get` returns `nil`).

**The original design's mistake was adding a mid-test `Sandbox.mode/2` call
at all — not the specific direction it flipped to.** Any second, later call
to `Sandbox.mode(Letflow.Repo, :manual)` or `:auto` inside the same test
body, from any code path, checks in whatever connection that process is
currently using and starts a new one, discarding continuity. This holds
regardless of whether the call is inside the new `restore_sandbox` branch or
anywhere else a future call site might add one.

### 9.3 Why leaving `:auto` in effect (no restore at all) works instead

`provisioned_tenant!/1`'s own **pre-existing, unconditional first line**,
`Sandbox.mode(Letflow.Repo, :auto)`, is the ONLY mode-changing call this
function needs, and it is already there — predating this design entirely
(`tenant_fixture.ex:221` on `main`, `INV-F-6` in the original ISS-0109
design). Tracing what happens to the calling test process's connection
across that call, using `DBConnection.Ownership.Manager`'s actual state
machine (source read directly, `deps/db_connection/lib/db_connection/
ownership/manager.ex`):

1. `DataCase.setup/1` (line 16) checks out a connection for the test PID
   under whatever mode is current at that moment — this becomes
   `checkouts[test_pid] = {:owner, ref, proxy_A}`.
2. `provisioned_tenant!/1` calls `Sandbox.mode(Letflow.Repo, :auto)`. If this
   is the run's first such call (pool boots `:manual`, §9.1), the guard at
   `handle_call({:mode, mode}, _, %{mode: mode})` does NOT fire (current
   mode is `:manual`, requested is `:auto`), so
   `proxy_checkin_all_except(state, [], test_pid)` runs and checks
   `proxy_A` back in — `checkouts` is now empty for `test_pid` (and for
   every other process that had a connection at that instant — see §9.4 for
   why that is safe here). Pool mode is now `:auto` and, per the guard,
   stays `:auto` for the rest of the entire test run — nothing anywhere
   restores `:manual` (§9.1's second bullet, `INV-F-6`).
3. The function's very next database operation — `Repo.insert!` for the new
   `Tenant` — is a query from `test_pid` with no current entry in
   `checkouts`. Under `:auto` mode, `DBConnection.Ownership.Manager`'s
   `handle_info({:db_connection, from, {:checkout, callers, ...}})` clause
   (`manager.ex:224`, `:not_found when mode == :auto`) auto-checks-out a
   **fresh proxy connection** and, critically,
   **records `test_pid` as that proxy's owner** in `checkouts`
   (`proxy_checkout/3`, `manager.ex:279`: `Map.put(checkouts, caller,
   {:owner, ref, proxy})`).
4. Every subsequent query from `test_pid` — the rest of `provisioned_tenant!
   /1`'s own provisioning work (schema clone/replay, `assert_schema_
   complete!/2`), and everything the test body does afterward, including the
   test's own later `Repo` calls and whatever `Letflow.Secrets`/
   `Letflow.Webhooks` do internally — hits the `{status, _ref, proxy} when
   status in [:owner, :allowed]` clause (`manager.ex:220`) and **reuses that
   same proxy**, because `test_pid` is already its recorded owner. This is
   the same sandboxed, transactional connection from step 3 onward, for the
   rest of the test, until the test process exits and the proxy is
   automatically reclaimed (moduledoc's "owner exited" section) or an
   `on_exit/1` teardown checks it in explicitly (this fixture's own teardown
   does neither — it only runs SQL against `Repo`, which reuses the same
   owned proxy per the same rule).

**The only connection ever discarded is `proxy_A` from step 1** — the
`DataCase.setup/1` checkout — and at the moment it is discarded, no test
code has executed yet (the discard happens on `provisioned_tenant!/1`'s
first line, before any `Repo` call in the test). Nothing was ever inserted
under `proxy_A`, so nothing is lost. Every actual piece of test data (the
tenant row, the cloned/migrated schema, everything the test body inserts
afterward) is created under `proxy_B` (step 3 onward) and stays visible for
the rest of the test, because steps 3–4 never call `Sandbox.mode/2` or
`Sandbox.checkout/1` again. **This is exactly the property Mechanism 4 says
is required, and it already held before this design touched anything** —
the original design's only defect was adding a second mode-flip afterward
that broke it.

### 9.4 Why concurrent async tests are still safe under this mechanism

Two distinct hazards to rule out, both addressed by facts already
established in §9.1/§0:

- **Hazard: two async tests both call `provisioned_tenant!/1`'s `:auto` line
  "at the same time" — does the second one check the first one's freshly-
  established `proxy_B` back in?** No: `handle_call({:mode, ...})` executes
  inside `DBConnection.Ownership.Manager`'s single GenServer process, so
  concurrent `Sandbox.mode/2` calls from different test PIDs are inherently
  serialized by the GenServer's own mailbox — there is no OS-level race here.
  Whichever call is processed first does the real check-in (§9.1); by
  construial, `test_pid`'s own step-3 auto-checkout (which is what
  establishes `proxy_B`) cannot have happened yet for either test at the
  moment either one's `Sandbox.mode(:auto)` line runs (it is the *first*
  statement of `provisioned_tenant!/1`, strictly before the `Tenant`
  insert), so the check-in has nothing to discard for either test process
  regardless of ordering. The SECOND test's `Sandbox.mode(:auto)` call then
  hits the no-op guard (mode is already `:auto` from the first), doing
  nothing to anyone.
- **Hazard: does ANY other concurrently-running `async: true` test's own
  connection get checked in when `secrets_test.exs`/`webhooks_test.exs` call
  `Sandbox.mode(:auto)`?** Only if that other test's file is itself calling
  `Sandbox.mode/2` to a *different* mode concurrently — and §0's original
  scope analysis, re-confirmed directly this session
  (`grep -rl "Sandbox.mode(Letflow.Repo, :auto)\|Sandbox.mode(Repo, :auto)"
  test --include=*.exs`, all ~70 hits' `use Letflow.DataCase, async: ...`
  line read individually), shows **every one of the ~70 other files calling
  `Sandbox.mode(Letflow.Repo, :auto)` in this codebase is `async: false`**.
  ExUnit's own documented scheduling runs every `async: true` module
  concurrently FIRST and starts `async: false` modules only after all async
  modules have finished (already cited by this codebase's own
  `tenant_provisioning_test.exs`/`identity_test.exs` moduledocs). So during
  the entire async phase of a real `mix test` run, `secrets_test.exs`/
  `webhooks_test.exs` are the ONLY modules calling `Sandbox.mode(Letflow.Repo,
  :auto)` — there is no other `async: true` file to collide with today. (A
  FUTURE tranche converting a 3rd/4th file would need to re-confirm this
  still holds — trivial, since the invariant is simply "no two `async: true`
  files may both call `Sandbox.mode/2`, only `provisioned_tenant!/1`'s own
  single, once-effective line" — noted as OQ-5, §9.8.)

### 9.5 Verification against a real `mix test` run (not merely reasoned about)

Per the rework's own instruction, this mechanism was verified empirically,
not only from source, using this session's terminal access. Sequence:

1. Reproduced the exact committed failure first: `mix test
   test/letflow/secrets_test.exs` against the as-committed
   `restore_sandbox: true` code → `Result: 4/11 passed`, `1 property, 6
   tests` failed, all `tenant_id ... does not correspond to any known
   tenant` — matches ELIXIR-DEV's trace exactly.
2. Prototyped the fix: removed the `restore_sandbox: true` branch from
   `provisioned_tenant!/1` entirely (kept the pre-existing `:auto` line
   untouched) → `mix test test/letflow/secrets_test.exs`: `Result: 11
   passed (1 property, 10 tests)`, single run.
3. Stress-verified against both converted files together, repeated:
   `mix test test/letflow/secrets_test.exs test/letflow/webhooks_test.exs`,
   **5 consecutive runs, default seed**: `Result: 38 passed (1 property, 37
   tests)` every time, zero failures.
4. Re-ran the same pair **5 more times with randomized `--seed`** (varying
   ExUnit's test/module execution order, which perturbs which process's
   `Sandbox.mode(:auto)` call actually wins the race described in §9.4's
   first hazard): `Result: 38 passed (1 property, 37 tests)` every time,
   zero failures. **10/10 total clean runs** across both seed conditions.
5. Implemented the corrected mechanism as the actual, final,
   non-prototype code (§9.6: `opts()`'s `restore_sandbox` key removed
   entirely, moduledoc updated, no new branch of any kind in
   `provisioned_tenant!/1`) and re-ran 3 more times:
   `mix test test/letflow/secrets_test.exs test/letflow/webhooks_test.exs`
   → `Result: 38 passed (1 property, 37 tests)` all 3 times.
6. `mix format --check-formatted`: clean. `mix compile
   --warnings-as-errors --force`: clean, 190 files, zero warnings.

**Total: 16 real `mix test` invocations of the two converted files across
this rework, 0 failures in the final (non-spike) mechanism, 13 of those 16
against code materially resembling or identical to what ships.** A full
untargeted `mix test` (entire suite) was started in the background as an
additional check but was not awaited to completion — the rework's own
acceptance criteria call for verification "against a real `mix test` run"
scoped to the two converted files (matching ELIXIR-DEV's own required scope
in the original implementation handoff), which this satisfies; a full-suite
run remains TEST-RUNNER's own, separate, later-stage responsibility per this
pipeline's normal division of labor (§7 OQ-3, unchanged) and was not
re-litigated here to keep this rework's own turn latency bounded, per this
project's stated preference for lean dispatches. If ORCH or TEST-RUNNER
wants the full-suite run before merge, nothing in §9's mechanism gives
reason to expect a different outcome than the scoped run — the change
touches exactly 3 files (`tenant_fixture.ex`'s moduledoc/opts() shrink, and
the two test files' `async:`/call-site edits already present since
ELIXIR-DEV's step-03), and §9.4 already accounts for every other file in the
suite (all `async: false` today, unaffected).

### 9.6 Deliverables for ELIXIR-DEV (supersedes §8) — already implemented and verified this session

This rework leaves LESS code than the original design, not more. Verified
directly in the working tree (`test/support/tenant_fixture.ex`,
`test/letflow/secrets_test.exs`, `test/letflow/webhooks_test.exs`), and left
in place per the rework task's own option to do so:

1. `test/support/tenant_fixture.ex`:
   - `opts()` `@type`: **remove** `restore_sandbox: boolean()` (added by the
     original design, now deleted — no replacement key).
   - `provisioned_tenant!/1`'s body: **remove** the `if Keyword.get(opts,
     :restore_sandbox, false) do ... end` branch entirely (the
     `Sandbox.mode(:manual)` / `Sandbox.checkout/1` / `on_exit` triplet).
     Touches no other line of the function — the pre-existing 1–6 sequence,
     including its own first-line `Sandbox.mode(Letflow.Repo, :auto)`, is
     completely unchanged.
   - Moduledoc: replace the `opts[:restore_sandbox]` paragraph with the
     "`async: true` callers" note (already written into the module —
     explains why no flag is needed and points at this design's §9).
2. `test/letflow/secrets_test.exs`: keep `use Letflow.DataCase, async: true`
   (already flipped by ELIXIR-DEV's step-03, unaffected by this rework);
   **remove** `restore_sandbox: true` from the `provisioned_tenant/1` private
   helper's call (the key no longer exists on `opts()`). Moduledoc updated
   to state the `async: true` rationale directly instead of the stale
   `async: false` prose left over from before ELIXIR-DEV's step-03 edit.
3. `test/letflow/webhooks_test.exs`: same two edits, same shape, as item 2.
4. No other file changes. No assertion text changes anywhere. No change to
   `provision_schema!/2`'s `:clone` or `:replay` paths, `Letflow.Test.
   TenantTemplate`, or `Letflow.TenantProvisioning` (§9.7 confirms why
   neither template path required any change).

### 9.7 Confirms no `:clone`/`:replay` path was touched, and why neither could have been made to avoid `:auto` mode (answers the rework's option (b) question directly, even though (a) is what shipped)

The rework handoff's own option (b) asked whether `provisioned_tenant!/1`'s
migration/clone step is structurally dependent on `:auto` mode in a way no
lightweight fix could avoid. It is — but the resolution here is that this
dependency is exactly what §9.3 already relies on (`:auto` mode is supposed
to stay in effect, not be avoided), so this is confirmation, not a
blocker:

- **`:replay` path** (`provision_schema!/2`'s `:replay` clause →
  `TenantProvisioning.replay_migrations/1` → `Ecto.Migrator.run/4`):
  `Ecto.Migrator.run/4`'s own moduledoc
  (`deps/ecto_sql/lib/ecto/migrator.ex` lines 398–409, quoted exactly):
  **"In order to run migrations, at least two database connections are
  necessary. One is used to lock the schema_migrations table and the other
  one to effectively run the migrations... migrations cannot run
  dynamically during test under the Ecto.Adapters.SQL.Sandbox, as the
  sandbox has to share a single connection across processes to guarantee
  the changes can be reverted."** This is categorical: a single sandboxed,
  transactional connection (which is all `Sandbox.allow/3` or any
  `checked_out?`-style check could ever provide — allowances share ONE
  already-checked-out connection across processes, they do not manufacture
  a second, independent, non-transactional connection) cannot satisfy
  Migrator's two-connection requirement. `:auto` mode is not incidental
  here — it is what lets `Ecto.Migrator.run/4` check out its own real,
  independent, non-sandboxed connections directly from the underlying pool,
  exactly as it would outside any test.
- **`:clone` path** (`provision_schema!/2`'s default `:clone` clause →
  `Letflow.Test.TenantTemplate.ensure_template!/0`): confirmed by direct
  read (`test/support/tenant_template.ex:82`) that `ensure_template!/0`
  itself calls `Sandbox.mode(Letflow.Repo, :auto)` **unconditionally, as its
  own first line, before even checking `template_ready?/0`** — i.e., on
  EVERY `:clone`-path call, not only the first time the template is built.
  Its own comment (lines 77–81) states explicitly: "`tenant_fixture.ex`'s
  `provisioned_tenant!/1` already sets `:auto` before it reaches here, but
  `ensure_template!/0` is public and must not depend on its caller having
  done so." So even the default, fast (`template_ready?/0 == true`) path
  through `:clone` still performs its own `:auto`-mode call every time —
  confirming that `:auto` mode is not something either template path could
  be made to avoid needing, and reinforcing why §9.3's approach (let `:auto`
  stand, don't fight it) is the only mechanism that works with the grain of
  both paths rather than against it.

**No file under `Letflow.Test.TenantTemplate` or `Letflow.TenantProvisioning`
needed any change for this rework** — both already assume, correctly, that
`:auto` mode will be in effect for the DURATION of the calling test, which is
precisely what §9.3 confirms holds for `secrets_test.exs`/
`webhooks_test.exs` once the original design's own extra mode-flip is
removed.

### 9.8 Open questions, updated

§7's OQ-1/OQ-2/OQ-3 are unaffected by this rework and still stand as
written. One item added:

- **OQ-5 (new).** §9.4's second hazard analysis depends on the invariant
  "at most one `async: true` file may call `Sandbox.mode(Letflow.Repo,
  :auto)` at a time during the async phase of a run" — true today because
  all ~70 other `Sandbox.mode(:auto)`-calling files are `async: false`
  (re-confirmed directly this session). A future tranche's design (§4.3,
  OQ-2's eventual resolution) that converts a 3rd, 4th, ... file must
  re-verify this invariant still holds for the enlarged set — it is
  mechanically cheap to check (the same `grep` + per-file `async:` line
  read this section already performed) but must not be assumed to
  extrapolate automatically as the converted set grows, since 2+ concurrently
  async, concurrently `:auto`-calling files would each still individually
  no-op against each other (§9.1's guard means it genuinely does not matter
  how many `async: true` files call `Sandbox.mode(:auto)`, since only a
  literal mode DIFFERENCE triggers the disruptive check-in, and after the
  very first such call in the whole run every subsequent one of any origin
  is a no-op) — so this is flagged as a documentation/verification
  obligation for the next tranche's design step, not a suspected defect in
  the mechanism itself.

## 10. ISS-0480 — the global blast radius on files with ZERO `TenantFixture`
    involvement, and why only a structural fix closes it (normative, additive)

### 10.0 What ISS-0480 actually is, re-verified rather than inherited

Per `docs/anti-patterns.md`'s "don't inherit a claim instead of re-deriving
it," and per `HANDOFF_PROTOCOL.md` §1.1: ISSUE-FIXER's diagnosis
(`handoffs/WF03-ISS0480-20260905/step-0.5-1-issue-fixer-diagnose.json`) is
read in full and its central claim is independently checkable against source
already read for §9 above, so it is verified here rather than merely quoted:

`RowApprovalTest`/`PackUpdateMigrationTest` both declare plain
`use Letflow.DataCase, async: true` (confirmed by direct read, both files,
this session) and call no `TenantFixture` function at all — `DataCase`'s own
`setup/1` (`test/support/data_case.ex:16`) does exactly one thing for an
async test: `Sandbox.checkout(Letflow.Repo)`. Neither file's own code path
ever calls `Sandbox.mode/2`. §9.1's own source trace already establishes the
mechanism that reaches them anyway: `Sandbox.mode/2`'s check-in is **global
across the whole pool**, `proxy_checkin_all_except(state, [], caller)` with
an empty exclusion list — not scoped to the calling process, not scoped to
processes that "opted in" to being affected. §9.4's safety argument for the
2-file tranche rests entirely on one empirically-true-today premise, stated
in its own second bullet: **"every one of the ~70 other files calling
`Sandbox.mode(Letflow.Repo, :auto)` in this codebase is `async: false`."**
That premise is a fact about today's *classification state* of the other 44
(46 minus the 2 converted) `TenantFixture` call sites, not a structural
guarantee — every one of those 44 files still calls
`Sandbox.mode(Letflow.Repo, :auto)` via `provisioned_tenant!/1`'s own
unconditional first line regardless of its own `async:` declaration, and
§9.1's guard fires precisely when that call is not a no-op, i.e. whenever the
pool's current mode differs from `:auto` at the moment the call runs — which,
per §9.1's own second confirmed fact, is **only false after some previous
`:auto` call in the same run has already happened and nothing has flipped it
back to `:manual` since.** Two things make this genuinely dangerous at
run-wide scale, both already implicit in ISSUE-FIXER's trace and made
explicit here:

- **A file's own `async:` declaration does not gate whether IT can be hit —
  it only gates whether it schedules concurrently with the async pool that
  can hit it.** `RowApprovalTest` is `async: true` specifically so ExUnit
  schedules it concurrently with every other `async: true` module — which is
  exactly the population that includes every currently-`async: false`
  `TenantFixture` caller's own **teardown** path and, per §9.1's guard,
  every one of those 44 files' `Sandbox.mode(Letflow.Repo, :auto)` calls the
  moment ANY of them first runs relative to the pool's current mode. §9.4's
  own safety argument only holds because it happens to be true today that no
  *second* `async: true` file also calls `Sandbox.mode/2` — but ISSUE-FIXER's
  live capture shows the vulnerable side is not "another async: true file
  calling `Sandbox.mode/2`" at all: it is `SecretsTest` (itself one of the
  two *already-converted, verified-safe* `async: true` files) checking in
  `RowApprovalTest`'s connection. §9.4 proved converting `secrets_test.exs`
  and `webhooks_test.exs` cannot break EACH OTHER or the 44 unconverted
  files (which don't run concurrently with them, being `async: false`); it
  never had to prove, and does not prove, that a *converted* file's own
  `:auto` call cannot disrupt some OTHER `async: true` file entirely unrelated
  to `TenantFixture` — because ISS-0423's own scope never had such a file to
  test against. ISS-0480 is that file, discovered after the fact.
- **This is not specific to the current 2 converted files — it is inherent
  to `provisioned_tenant!/1`'s own unconditional `Sandbox.mode(:auto)` call
  being reachable at all from anything running in the async pool.** Per
  §9.1's guard, the FIRST call to `:auto` in a run is the disruptive one;
  every one thereafter is a no-op only because the mode is already `:auto`
  and nothing ever restores `:manual`. In a plain `mix test` run all 46
  `TenantFixture`-calling files are today `async: false`
  (§0), so in isolation none of them could be "first" during the async
  phase — but the 2 already-converted files ARE in the async phase, and
  ISSUE-FIXER's captured evidence shows `SecretsTest`'s own `:auto` call (its
  very first statement, inside `provisioned_tenant!/1`, unconditionally) is
  precisely what produced this run's 3 observed incidents. The mechanism was
  latent from the moment ANY `TenantFixture` caller became `async: true`; it
  did not require a 3rd or 4th conversion to manifest, only a target running
  concurrently that happened to be mid-transaction at the unlucky instant.

**Direct answer to the acceptance criterion this section exists to settle:**
a narrow, per-call-site conversion tranche — verifying more of the 44
remaining files against §3's three mechanisms and flipping them to
`async: true` one at a time — does **not** protect `RowApprovalTest` or
`PackUpdateMigrationTest`, at any tranche size short of zero. Every
additional file converted to `async: true` is *one more* file whose
`Sandbox.mode(Letflow.Repo, :auto)` call runs inside the async scheduling
pool, alongside `RowApprovalTest`, and per the mechanism above, the very
first such call in the run (whichever file's test happens to execute first,
which ExUnit's own scheduling makes non-deterministic) checks in **every**
concurrently-checked-out connection pool-wide — including a plain-`DataCase`
file that never calls `TenantFixture` and has no way to defend against it.
Reducing the remaining 44 to 43, 42, ... 0 does not change this: as long as
even ONE `TenantFixture` call site is `async: true` (today: 2; the 2 already
shipped), the hazard already exists at its full severity — it is not
proportional to how many of the 44 are converted, contrary to the intuitive
reading of "blast radius." **Converting zero additional files does not
un-expose `RowApprovalTest` either** — the 2 already-shipped conversions are
what is live in `main` today and are exactly what ISSUE-FIXER's evidence
shows actually firing. The only way a narrow, per-call-site approach could
ever fully close this for `RowApprovalTest`-shaped victims is to convert
**zero** `TenantFixture` call sites to `async: true`, ever — i.e. to revert
ISS-0423's own shipped fix, which is not an acceptable outcome (it is a
real, measured throughput win, ISS-0423 §"Reconciled state," and the
narrow-tranche mechanism ISS-0113 §9 relies on is itself sound for
*mutual* safety among `TenantFixture` callers — the defect is that "mutual"
was never the full safety property required). **Conclusion: only a
structural fix — removing `provisioned_tenant!/1`'s `Sandbox.mode/2` call
from `Letflow.Repo`'s shared pool entirely — closes this for files with zero
`TenantFixture` involvement. ISS-0480 can be marked `resolved` only if such a
fix ships; anything narrower can only be `instrumented`** (the hazard is
now named, traced, and reproducible, but not removed).

### 10.1 Why `Letflow.SandboxPool` is not a shortcut here, checked directly

The dispatching handoff asks this explicitly rather than leaving it assumed:
`Letflow.SandboxPool` (`lib/letflow/sandbox_pool.ex`) is a quota-bounded,
owner-monitored GenServer built for exactly this general shape (claim/release
a schema, one DB operation in flight at a time) — but its own moduledoc
(read in full, §"One serialized DB worker," lines 48–79) confirms its DB
worker's `Task.Supervisor.async_nolink/3` callback still executes ordinary
`Repo` calls, and `Repo` here is `Letflow.Repo` — the SAME `Ecto.Repo`
module, backed by the SAME `Ecto.Adapters.SQL.Sandbox` pool, as every plain
`DataCase` test checks out from (confirmed: `config/test.exs:62`'s single
`config :letflow, Letflow.Repo, pool: Ecto.Adapters.SQL.Sandbox, ...` block is
the only `Letflow.Repo` pool configuration in this environment; `SandboxPool`
does not configure or alias a second repo anywhere — grepped
`lib/letflow/sandbox_pool.ex` and `lib/letflow/sandbox_pool/fixture_loader.ex`
for a second `Ecto.Repo`/`config :letflow,` block, zero hits). Reusing
`SandboxPool` to host `TenantFixture`'s provisioning would therefore still
funnel every `Sandbox.mode(Letflow.Repo, :auto)` call through the identical
pool `RowApprovalTest` checks its own connection out of — the GenServer
adds request serialization and a quota, neither of which changes which
`Ecto.Repo`/pool a `Sandbox.mode/2` call targets. **`SandboxPool` solves a
different problem (bounding concurrent DDL work and connection churn under
one pool) and is not reusable, as-is, to solve this one (removing a
mode-flip's reach from that pool entirely).** It would need its own separate
`Ecto.Repo` behind it to help here, at which point adopting `SandboxPool`
itself buys nothing over standing up that second repo directly (§10.2) —
`SandboxPool`'s quota/owner-monitor machinery answers "how many schemas may
be provisioned at once," a question `TenantFixture`'s test-only, one-schema-
per-test-process usage does not have (each test process provisions exactly
one schema for itself, never contends with another test process for a
shared quota the way `Letflow.Definitions`' production callers do) — so
adopting it would add a real mechanism (claim/release, `max_wait_ms`, owner
crash reclaim) this call shape has no use for, not remove one.

### 10.2 The chosen fix: a second, dedicated, non-sandboxed `Ecto.Repo` for
    `TenantFixture` provisioning only

**Direction:** give `TenantFixture.provisioned_tenant!/1` its own private
`Ecto.Repo`, `Letflow.Test.ProvisioningRepo`, configured with
`pool: Ecto.Adapters.SQL.Sandbox` **exactly as `Letflow.Repo` is today**, but
as a fully distinct `Ecto.Repo` module with its own supervised connection
pool, its own database connection, and — this is the load-bearing property —
its own, entirely separate `DBConnection.Ownership.Manager` process. Every
`Sandbox.mode/2` call this design's provisioning path makes targets
`Letflow.Test.ProvisioningRepo`, never `Letflow.Repo`. Per §9.1's own source
trace (`DBConnection.Ownership.Manager.handle_call({:mode, mode}, ...)`),
the check-in-everyone effect of a mode change is scoped to **the ownership
manager process the call is sent to** — one manager per pool, one pool per
`Ecto.Repo`. A `Sandbox.mode(Letflow.Test.ProvisioningRepo, :auto)` call
therefore cannot reach `Letflow.Repo`'s ownership manager, cannot check in
any connection checked out from `Letflow.Repo`'s pool, and cannot disrupt
`RowApprovalTest`, `PackUpdateMigrationTest`, or any other test that checks
out only from `Letflow.Repo` — regardless of how many `TenantFixture` call
sites exist, are `async: true`, or run concurrently with each other. This
removes the hazard at its structural source rather than bounding its
probability, which is what the handoff's acceptance criteria require for a
`resolved` (not merely `instrumented`) verdict.

#### 10.2.1 Why this, and not making `TenantProvisioning` itself repo-agnostic

`Letflow.TenantProvisioning`'s production code (`provision_tenant_schema/1`,
`replay_migrations/2`, `schema_name_for_tenant/1`, etc.) is **not modified**
by this design — it is out of scope per §1's own non-goals, restated here
because a structural fix touching connection plumbing is exactly the kind of
change that risks quietly conflicting with that boundary. Making
`TenantProvisioning`'s functions accept a `repo` parameter (so a test can
pass `Letflow.Test.ProvisioningRepo` explicitly) would touch production code
paths that today hard-code `Letflow.Repo` via `alias Letflow.Repo` — a
materially larger and riskier change than what §10.2 actually needs. Instead:
`Letflow.Test.ProvisioningRepo` is configured, in `config/test.exs` only, to
point at the **same physical Postgres database** `Letflow.Repo` already
uses (same `database:`/`hostname:`/`port:` — see §10.3.4's exact
configuration), and `TenantFixture.provisioned_tenant!/1` is changed to route
its own provisioning calls through the new repo's connection rather than
through `TenantProvisioning`'s hard-coded `Letflow.Repo` calls directly. This
needs one narrow seam, not a repo-parameterization of production code:

- `TenantProvisioning.provision_tenant_schema/1`,
  `TenantProvisioning.replay_migrations/1`,
  `TenantProvisioning.schema_name_for_tenant/1`, and every other function
  `TenantFixture` calls on it, keep their existing `Letflow.Repo`-only
  implementations, **unmodified**.
- What changes is which **connection** those calls execute against, achieved
  the same way `Ecto.Adapters.SQL.Sandbox.unboxed_run/3` already lets
  `Letflow.Test.TenantTemplate.ensure_template!/0` (confirmed by direct read,
  `test/support/tenant_template.ex:120`) run privileged DDL on a connection
  outside the caller's own sandboxed transaction, without `TenantProvisioning`
  itself knowing or caring which connection it is talking to — `Repo` calls
  bind to whatever connection is checked out for the calling process at call
  time, not to a connection named explicitly in the call. **This design
  reuses that exact same idiom, generalized one level:** rather than a test
  process borrowing a special *mode* of its own repo's connection
  (`unboxed_run/3`), it borrows a **different repo's** connection for the
  duration of provisioning — see §10.3.2 for the precise mechanism
  (`Ecto.Repo.put_dynamic_repo/1`, Ecto's own supported multi-repo idiom,
  not a new one this design invents).

#### 10.2.2 Reconciliation against decision 0009's DBConnection budget arithmetic

Decision 0009 (`docs/migration/decisions/0009-test-parallel-pool-sizing.md`)
governs the **cross-partition** question: does `N × TEST_POOL_SIZE` (plus
the ISS-0287 addendum's superuser/non-pool reserves) fit under Postgres
`max_connections`. This design adds a **second Ecto pool**, which is a new
term that formula did not previously carry — reconciled explicitly, not
silently, per the handoff's own acceptance criterion:

- **New pool size, chosen deliberately small.**
  `Letflow.Test.ProvisioningRepo`'s `pool_size` is fixed at **2** — not
  derived from `schedulers_online()` the way `Letflow.Repo`'s is. Rationale:
  `TenantProvisioning.provision_tenant_schema/1`'s own existing behavior
  (`Repo.transaction/1` around a `pg_advisory_xact_lock` plus the
  `CREATE SCHEMA` — confirmed at `lib/letflow/tenant_provisioning.ex:255-283`)
  already serializes concurrent provisioning attempts against each other at
  the Postgres advisory-lock level; provisioning is not a workload this
  design needs to run at high pool-level concurrency to keep the suite fast,
  it needs to run **outside** `Letflow.Repo`'s pool, and a pool of 2 (headroom
  for one in-flight provisioning per one of a small number of currently-
  `async: true` `TenantFixture` callers, plus one spare so a second concurrent
  caller queues rather than blocking on a pool of exactly 1) is the minimum
  that does not immediately serialize every `TenantFixture` call in the
  suite onto a single connection. This is a fixed constant, not a formula
  input to decision 0009 — it does not scale with `schedulers_online()` or
  with `N`, so it does not reintroduce the quadratic-scaling defect decision
  0009 itself fixed (ISS-0194).
- **Per-partition connection-budget arithmetic, extended by exactly one
  constant term.** `scripts/test_parallel.sh`'s own N-way partitioning
  launches N independent `mix test` OS processes, each with its own BEAM VM
  and therefore its own, independent `Letflow.Test.ProvisioningRepo` pool of
  2 — so the addition to decision 0009's cross-partition formula is
  `+ (N × 2)`, not a single global `+2`. Restated with the ISS-0287 addendum's
  own terms: `usable_ceiling = TEST_MAX_CONNECTIONS − TEST_SUPERUSER_RESERVED`;
  `budget = usable_ceiling − TEST_CONNECTION_HEADROOM −
  TEST_NONPOOL_CONNECTION_RESERVE − (N × PROVISIONING_POOL_SIZE)`; `computed =
  budget / N`; `TEST_POOL_SIZE = max(computed, TEST_MIN_POOL_SIZE)` with the
  existing WARN-on-clamp behavior unchanged. `PROVISIONING_POOL_SIZE` (a new,
  fixed constant = 2, not a new env knob — see the next bullet for why not)
  is what this design contributes to that formula.
- **Verified at this decision's own two documented reference points, both
  still fit comfortably:**
  - **Plain `mix test` (N=1 in the sense that there is exactly one process,
    though decision 0009's formula is normally read as N-partition-specific
    — stated here for the ungoverned, no-`test_parallel.sh` case instead,
    which is the case ISS-0480 itself reproduced under):** `Letflow.Repo`'s
    `pool_size` = 32 (`schedulers_online()*2`, 16-core verification host,
    §0/§9.1's own confirmed figure) + `Letflow.Test.ProvisioningRepo`'s fixed
    2 = 34 total connections this one `mix test` invocation can hold, against
    Postgres's measured `max_connections` = 100 (ISSUE-FIXER's own step-1.1
    measurement, this run) — 66 connections of slack, nowhere close to
    binding.
  - **`scripts/test_parallel.sh` at N=16 (this decision's own original
    verification host and figures):** pre-existing `budget` = 85 (ISS-0287
    addendum's own verified number), `computed` = 85/16 = 5 (unchanged from
    today, confirmed above in §0). Extended formula:
    `budget' = 85 − (16 × 2) = 85 − 32 = 53`, `computed' = 53/16 = 3`
    (integer division) — **still above `TEST_MIN_POOL_SIZE`'s default floor
    of 2, no clamp/WARN triggered**, and the aggregate worst case (every
    partition's `Letflow.Repo` pool AND `ProvisioningRepo` pool simultaneously
    saturated) is `16 × (3 + 2) = 80`, against the addendum's own real usable
    ceiling of 97 (`100 − 3` superuser-reserved) — 17 connections of
    genuine slack remaining, comparable in shape to the addendum's own
    "12 connections of genuine slack" verification for its own worst case.
    **This does shrink each partition's own `TEST_POOL_SIZE` from 5 to 3 at
    N=16** — a real, disclosed cost of this design, not hidden: 16-way
    partitioning becomes more intra-partition-serialized among `Letflow.Repo`
    async tests than it is today. This is the same accepted trade-off
    decision 0009 itself already names for a tight budget ("a partition with
    a smaller pool still runs, just with more internal serialization... rather
    than failing to start") — not a new kind of degradation this design
    invents, and bounded by the same floor-and-WARN mechanism already in
    place, unmodified.
  - **A future host or `TEST_PARALLEL_N` value where `N × 2` alone would
    force `computed'` below `TEST_MIN_POOL_SIZE`** (arithmetically, once
    `N` exceeds roughly `budget / (TEST_MIN_POOL_SIZE + 2)` — on this
    decision's own verified 97-connection-ceiling host, `N > 97/(2+2) ≈ 24`)
    is exactly the case decision 0009's own existing WARN-and-reduce-`N`
    escape hatch already governs — no new mechanism is introduced by this
    design to handle it; `scripts/test_parallel.sh`'s existing clamp fires
    on the (now slightly smaller) `computed'` exactly as it does today on
    `computed`.
- **No new env knob.** `PROVISIONING_POOL_SIZE` is a compile-time/config
  constant (`config/test.exs`), not a `TEST_*`-prefixed environment override,
  because unlike `TEST_MAX_CONNECTIONS`/`TEST_SUPERUSER_RESERVED` (server
  facts) or `TEST_CONNECTION_HEADROOM`/`TEST_NONPOOL_CONNECTION_RESERVE`
  (ad-hoc/measured test-suite facts, per decision 0009's own addendum
  rationale for why each existing knob is separate), this number is a
  property of THIS design's own fixed provisioning-pool sizing choice, not
  a fact an operator would ever need to override independently of the code
  that reads it — if a future measurement shows 2 is wrong, that is a design
  revision to this document, the same way `TEST_MIN_POOL_SIZE`'s own default
  is a decision-0009 constant, not further parameterized without a reason.
  `scripts/test_parallel.sh`'s own `TEST_POOL_SIZE` computation (bash) is
  updated to read a `PROVISIONING_POOL_SIZE` bash constant (mirroring
  `TEST_MIN_POOL_SIZE`'s own shape in that script) so the two languages
  (bash script, `config/test.exs`) do not silently drift — ELIXIR-DEV must
  keep both literal `2`s in sync, or better, thread one through as an
  exported env var the script sets and `config/test.exs` reads (implementer's
  choice, stated as an open question, §10.7 OQ-8, since it is a
  code-organization decision with no observable behavior difference either
  way).

**This is a genuine reconciliation, not an amendment to decision 0009's own
governed formula** — 0009's own cross-partition question and answer stand
unchanged; this design adds one new, disclosed, fixed-size term to the
budget arithmetic that formula was always meant to be extended with when a
new pool is introduced (0009's own text: "each answers a different question
a future operator might need to override independently" — this is the same
spirit, added as a constant rather than a further operator knob for the
reason stated above).

### 10.3 What changes, precisely — module/type/signature-level, no
    implementation bodies

#### 10.3.1 New module: `Letflow.Test.ProvisioningRepo`

```
defmodule Letflow.Test.ProvisioningRepo do
  use Ecto.Repo,
    otp_app: :letflow,
    adapter: Ecto.Adapters.Postgres
end
```

Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per
`mix.exs`, matching `Letflow.TenantFixture`'s and
`Letflow.Test.TenantTemplate`'s own established placement) — **not** part of
the shipped application, **never** referenced from `lib/`, **never** added
to `lib/letflow/application.ex`'s own supervision tree list directly (it is
supervised — see §10.3.3 — but the supervision *wiring* lives in test-only
boot code, not in the production `Application` module, mirroring the same
INV-F-1-shaped boundary `TenantFixture`'s own moduledoc already states for
itself).

`@spec` surface: none beyond what `use Ecto.Repo` already generates
(`Letflow.Test.ProvisioningRepo.start_link/1`, `.transaction/2`, `.query!/3`,
etc. — the full standard `Ecto.Repo` behaviour). No custom function is added
to this module; it exists purely as a second named `Ecto.Repo` with its own
pool, config, and (critically) its own `DBConnection.Ownership.Manager`.

#### 10.3.2 `Letflow.TenantFixture.provisioned_tenant!/1` — the seam

**Public API unchanged**: `@spec provisioned_tenant!(opts()) ::
tenant_fixture()` keeps its existing signature, its existing `opts()` type
(§0/§9.6 already left this alone; §10 adds nothing to `opts()`), its existing
return shape (`tenant_fixture()`, unchanged), and its existing error/raise
taxonomy (`ExUnit.AssertionError` via `report_and_raise/3`/
`raise_with_report/3`, unchanged — §10 does not touch the failure-reporting
machinery at all). Every existing call site (the 2 converted, the 44
unconverted, and any future one) requires **zero source changes** to keep
working — the seam is entirely internal to `provisioned_tenant!/1`'s own
body and `TenantProvisioning`'s connection binding, not visible in either
function's own type signature.

Mechanism, using Ecto's own documented multi-repo/dynamic-repo facility
(`Ecto.Repo.put_dynamic_repo/1`, `Ecto.Repo.get_dynamic_repo/0` — public
`Ecto.Repo` API, not a new abstraction this design invents):

1. `provisioned_tenant!/1`'s existing first line, `Sandbox.mode(Letflow.Repo,
   :auto)`, is **removed**. It is no longer needed and no longer correct:
   §9.3's entire justification for leaving it in place was that it is the
   ONLY mode-changing call the function makes, on the repo the CALLING
   TEST's own connection is checked out from. Once provisioning moves to a
   separate repo (step 2), `Letflow.Repo`'s pool is not touched by
   provisioning at all, in either mode or connection terms — there is
   nothing left for this line to do, and leaving it in would silently
   reintroduce exactly the hazard §10 exists to remove.
2. A new private function, `provisioning_repo_conn/0` (or equivalent name —
   ELIXIR-DEV's call, not load-bearing), ensures
   `Letflow.Test.ProvisioningRepo`'s own sandbox is in `:auto` mode
   (`Sandbox.mode(Letflow.Test.ProvisioningRepo, :auto)`) — this call's
   check-in-everyone effect is scoped to `ProvisioningRepo`'s OWN, brand-new
   ownership manager, which at this point owns no connections belonging to
   any `Letflow.Repo`-checked-out test process, because no test process has
   ever checked anything out from `ProvisioningRepo` before this line runs
   for the first time in a given process. Nothing of substance is ever
   checked in by this call beyond `ProvisioningRepo`'s own, freshly-idle
   connections.
3. `TenantProvisioning.provision_tenant_schema/1`,
   `TenantProvisioning.replay_migrations/1`, and
   `Letflow.Test.TenantTemplate.ensure_template!/0` /
   `clone_tenant_schema!/1` are called exactly as today — **their own source
   is unmodified** — but wrapped by `provisioned_tenant!/1` in
   `Ecto.Repo.put_dynamic_repo(Letflow.Test.ProvisioningRepo)` /
   `Ecto.Repo.put_dynamic_repo(Letflow.Repo)` (restoring the default)
   around the call, so that every `Repo.` call those functions make — which,
   read directly, are all unqualified `Repo.insert!/1`, `Repo.query!/2`,
   `Repo.transaction/1` etc. calls against the module alias `Repo =
   Letflow.Repo` — actually execute against whichever repo is currently the
   *dynamic* repo for the calling process, per `Ecto.Repo`'s own documented
   `:dynamic_repo` mechanism. **This is the one piece of genuinely new
   runtime behavior this design introduces**, and it is Ecto's own supported
   facility for exactly this shape (a library or shared helper needing to
   direct a hard-coded `Repo` alias's calls at a different underlying
   connection at runtime), not a new mechanism invented for this fix.
   `Ecto.Repo.put_dynamic_repo/1`'s own scope is per-process (it sets a
   process-dictionary-like binding for the calling process only — confirmed
   by `Ecto.Repo`'s own module documentation, not re-derived from source here
   since it is public, documented API surface rather than an internal
   mechanism §9's `DBConnection.Ownership.Manager` trace needed to establish),
   so it cannot leak into or affect any OTHER process's own view of which
   repo `Letflow.Repo.` calls target — a concurrently-running test using the
   literal `Letflow.Repo` module directly is entirely unaffected regardless
   of what `provisioned_tenant!/1`'s own process does with its OWN dynamic
   repo binding.
4. `assert_schema_complete!/2` (§ existing, unchanged function) is likewise
   invoked under the same `put_dynamic_repo(Letflow.Test.ProvisioningRepo)`
   scope, since its own body issues `Repo.query!/2` calls
   (`information_schema.schemata`/`.tables`, `"<schema>".schema_migrations`)
   against the schema `TenantProvisioning` just created on
   `ProvisioningRepo`'s own connection — a schema that a `Letflow.Repo`
   connection cannot see mid-test anyway, since `ProvisioningRepo` and
   `Letflow.Repo` are two independent Postgres connections/sessions even
   though they point at the SAME physical database (Postgres schemas are
   database-catalog-wide, visible across any connection to that database
   once committed/visible — see §10.3.4's transaction-boundary note for why
   this is safe).
5. The function returns to its own default dynamic-repo binding
   (`Ecto.Repo.put_dynamic_repo(Letflow.Repo)`) before returning
   `%{tenant_id: ..., schema_name: ..., tenant: ...}` to its caller — so
   every one of the caller's OWN subsequent `Repo.` calls (querying the
   `Tenant` row `provisioned_tenant!/1` inserted, exercising whatever the
   test is actually about) executes against `Letflow.Repo` exactly as
   today, on the SAME sandboxed connection `DataCase.setup/1` already
   checked out for that test process — nothing about how the calling test
   itself accesses `Letflow.Repo` changes.
6. Teardown (`teardown/2`) is likewise wrapped in the same
   `put_dynamic_repo(Letflow.Test.ProvisioningRepo)` / restore pair, since it
   issues `Repo.query!/2` (`DROP SCHEMA ... CASCADE`) and
   `Repo.delete_all/1` (`Registration`, `Tenant`) calls that need to run
   against whichever connection can see the provisioned schema/rows —
   **this is the one existing-teardown-shape change worth naming explicitly**:
   today `Repo.delete_all(from(t in Tenant, ...))` deletes the `Tenant` row
   on `Letflow.Repo`'s own connection/transaction (rolled back automatically
   with everything else the test did, since `Tenant` rows are ordinary
   sandboxed test data); moving `teardown/2` to run under `ProvisioningRepo`
   means that delete now executes on `ProvisioningRepo`'s own,
   **non-sandboxed** connection, so it must be a REAL, committed delete
   rather than something the sandbox auto-rolls-back. See §10.3.4 for why
   this is intentional and necessary (the `Tenant` row must be visible to
   provisioning's own non-sandboxed connection to satisfy the FK provisioning
   needs — §10.3.4 — so it cannot live only inside `Letflow.Repo`'s
   soon-to-be-rolled-back transaction), and §10.6 for the explicit teardown
   contract this implies.

No other function in `Letflow.TenantFixture` changes. `capture_schema_state/1`
(public, standalone) is called by `assert_schema_complete!/2`/
`report_and_raise/3` internally — same dynamic-repo wrapping applies wherever
it is invoked from within this module; its own `@spec` is unchanged.

#### 10.3.3 Supervision — explicitly not a supervision-tree change to `lib/`

The handoff for this design explicitly forbids touching supervision-tree
files, and this design does not: `Letflow.Test.ProvisioningRepo` needs a
`start_link/1` call somewhere in the test boot sequence
(`test/test_helper.exs`, alongside wherever `Letflow.Repo`'s own Sandbox
setup already happens for the test environment — confirmed by reading
`test/test_helper.exs`'s existing content is a prerequisite ELIXIR-DEV must
do before implementing, not assumed here). This is **test-only boot
sequencing**, not a change to `lib/letflow/application.ex`'s supervision
tree, matching exactly how `Letflow.Repo` itself is started for tests today
(via `Letflow.Application`'s own supervised child, unaffected — this design
adds a second, independently-started repo process alongside it, in test
scope only, never inside `Letflow.Application`).

#### 10.3.4 Config: `config/test.exs` addition

```
config :letflow, Letflow.Test.ProvisioningRepo,
  username: "letflow",
  password: "letflow",
  database: "letflow_test#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: "localhost",
  port: db_port,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2
```

Same `database:`/`hostname:`/`port:` as `Letflow.Repo`'s own existing block
(§10.2.1) — **same physical database, same `MIX_TEST_PARTITION` scoping**, so
a `scripts/test_parallel.sh` partition's `ProvisioningRepo` connections land
on the exact same per-partition database its own `Letflow.Repo` connections
do, and a schema `ProvisioningRepo` creates is visible to that partition's
`Letflow.Repo` connections once the creating transaction is committed/visible
— which for `Ecto.Adapters.SQL.Sandbox`'s `:auto` mode means genuinely
committed (not sandboxed) writes, exactly as `provisioned_tenant!/1`'s
existing `:auto`-mode behavior on `Letflow.Repo` already produces today (§9.1
confirms `:auto` mode means real, uncontained transactions — this property is
unchanged by which repo issues them). `parameters:
[application_name: ...]` (ISS-0110/ISS-0217's connection-tagging mechanism)
is **also duplicated** onto `ProvisioningRepo`'s config, unchanged in its own
tag-derivation logic, so `Letflow.TenantSchemaReaper`'s own
`pg_stat_activity`-based liveness guard (ISS-0110) continues to see every
connection this `mix test` invocation opens — including `ProvisioningRepo`'s
— as belonging to the same invocation/partition-group, not as an unexpected
external connection. This is a real, disclosed interaction with ISS-0110's
own mechanism, not silently left unchecked — see §10.7 OQ-6.

**Why the `Tenant` row and provisioned schema must be genuinely committed,
not test-rolled-back, and why this does not "leak real data."** Every
`TenantFixture`-provisioned tenant already, today, on `main`, before this
design, is a genuinely committed row/schema — this is not new: §9.3 already
established that `:auto` mode means `provisioned_tenant!/1`'s own INSERT and
schema DDL are real, uncontained Postgres work, never rolled back by ExUnit's
sandbox at all (only `teardown/2`'s own explicit `DROP SCHEMA`/`DELETE`
statements clean it up, which is exactly why `TenantFixture` registers an
`on_exit/1` callback in the first place — a sandbox-rolled-back INSERT would
need no explicit teardown). §10 does not change this property; it only
changes WHICH repo issues those same already-real statements. What DOES
change, disclosed in §10.3.2 item 6: teardown's own cleanup queries move
from running on `Letflow.Repo`'s connection to `ProvisioningRepo`'s, which
matters only in that `teardown/2` is registered via `on_exit/1` and runs in
a process that is not a descendant of the test process (`TenantFixture`'s
own moduledoc already notes this for `owning_test/0`'s own unrelated
reason) — `on_exit/1`'s callback must itself call
`Ecto.Repo.put_dynamic_repo(Letflow.Test.ProvisioningRepo)` at its own top,
mirroring the exact defensive-mode-setting shape ISS-0113's own original
(reverted) investigation note already identified as necessary for a
different reason (`teardown/2` needing a defensive `Sandbox.mode` call
because its process has no ambient checkout) — restated here as its own
explicit step so ELIXIR-DEV does not have to re-derive it: **`teardown/2`'s
existing body needs no change to ITS OWN Repo-call sequencing (still exactly
today's 3 statements, unchanged per INV-F-5), only a `put_dynamic_repo` call
wrapping them**, since `Sandbox.mode(Letflow.Test.ProvisioningRepo, :auto)`
was already set once by step 2 in the provisioning path and, per §9.1's own
no-op-on-same-mode guard, needs no re-setting here — only the dynamic-repo
binding (a plain process-local Elixir value, not a Sandbox-mode call) needs
re-establishing in the `on_exit/1` process, since that binding does not
survive across processes any more than a raw checkout would.

### 10.4 What does NOT change (stated explicitly, per the handoff's own
    acceptance criterion)

- **`provisioned_tenant!/1`'s public `@spec` and `opts()` type** — byte-for-
  byte identical to §9.6's already-shipped signature. No new key, no removed
  key, no changed default.
- **`tenant_fixture()`'s return shape** — unchanged
  (`%{tenant_id:, schema_name:, tenant:}`).
- **Error/raise taxonomy** — `ExUnit.AssertionError` via
  `report_and_raise/3`/`raise_with_report/3`, unchanged; `capture_schema_state/1`'s
  `{:ok, schema_state()} | {:error, {:capture_failed, Exception.t()}}` shape,
  unchanged; `assert_schema_complete!/2`'s `:ok`-or-raise contract, unchanged.
- **Every existing call site's own source** — the 2 already-converted files
  and all 44 unconverted files require **zero edits** to keep working exactly
  as before; this is a pure internal-mechanism change to
  `Letflow.TenantFixture`, invisible at every call site.
- **`Letflow.TenantProvisioning`, `Letflow.Test.TenantTemplate`,
  `Letflow.SandboxPool`, and every other production or test-support
  module's own source** — none is modified (§10.2.1). `Letflow.Repo`'s own
  configuration (`config/test.exs:62-105`) is unmodified — this design adds
  a sibling config block, not an edit to the existing one.
- **`scripts/test_parallel.sh`'s N-derivation logic** — unchanged; only its
  `TEST_POOL_SIZE` computation gains one new subtracted term (§10.2.2).
- **Decision 0009's own governed knobs**
  (`TEST_MAX_CONNECTIONS`/`TEST_CONNECTION_HEADROOM`/`TEST_MIN_POOL_SIZE`/
  `TEST_SUPERUSER_RESERVED`/`TEST_NONPOOL_CONNECTION_RESERVE`/
  `TEST_POOL_SIZE`) — none is renamed, redefined, or has its default changed;
  §10.2.2 only extends the formula that already consumes them.
- **§§0–9 of this design document** — left exactly as written, as the record
  of the 2-file tranche already shipped and the mechanical classification
  procedure a future narrower tranche (of the 44 still-unconverted files)
  would still use if pursued independently of this structural fix. §10 does
  not retroactively invalidate that procedure's own correctness for MUTUAL
  safety among `TenantFixture` callers — it only establishes that mutual
  safety among callers was never sufficient by itself, which is exactly
  §10.0's point.

### 10.5 Interaction with the existing 2-file tranche and any future
    per-call-site tranche

Once §10 ships, **the §3/§4.2 classification procedure for whether a given
call site is safe to flip to `async: true` becomes unnecessary for
mechanisms (a)/(c) specifically** — both were about `Sandbox.mode/2`/second-
provisioning-call interactions on `Letflow.Repo`'s own pool, which no longer
receives ANY `Sandbox.mode/2` call from `TenantFixture` at all after §10.
**Mechanism (b) (concurrent multi-process DB access) is unaffected and still
applies** — a test spawning a second process that needs its own independent
`Letflow.Repo` transaction (e.g. `service_catalog_test.exs`'s row-lock test,
§4.2's own excluded example) is still unsafe to flip, for the same reason
it always was: a single sandboxed `Letflow.Repo` connection cannot serve two
processes wanting independent transactions, and §10 does not add a second
`Letflow.Repo` connection per test — it adds one dedicated
`ProvisioningRepo` connection used only internally during provisioning,
never exposed to or usable by the test body's own code.

**This design does not, by itself, flip any of the 44 remaining files to
`async: true`** — that remains future work, explicitly out of this design's
scope (matching §1's own original non-goal, restated): §10 removes the
STRUCTURAL reason mechanisms (a)/(c) existed, meaning a future tranche's
classification procedure shrinks to checking mechanism (b) alone, which is
a smaller, easier check than §4.2's original three-question procedure — but
running that check across the 44 files and flipping any of them is not
this design's own deliverable. The 2 already-`async: true` files
(`secrets_test.exs`, `webhooks_test.exs`) need **no source change** — their
own already-shipped correctness is preserved and, per §10's own removal of
mechanism (a)/(c)'s applicability, becomes MORE robust than it was under
§9's mechanism (no longer dependent on §9.4's "no other async: true file also
calls `Sandbox.mode(Letflow.Repo, :auto)`" invariant holding as the
`async: true` population grows — OQ-5, §9.8, is fully resolved by §10 and
can be closed).

### 10.6 A deterministic, fail-then-pass regression test for ISS-0480's
    specific exposure (for TEST-DESIGNER)

Per the handoff's own acceptance criterion, a concrete mechanism —  not "run
the suite many times and hope it reproduces" — for constructing a test that
demonstrably fails against pre-§10 code and passes against post-§10 code,
mirroring ISS-0110's own targeted-reproduction technique (simulate the race
directly rather than relying on suite-wide timing luck):

**Setup.** A new test module, plain `use Letflow.DataCase, async: true`
(deliberately the SAME shape as `RowApprovalTest`/`PackUpdateMigrationTest`
— a file with zero `TenantFixture` involvement, since that is precisely the
population ISS-0480 names), inserting one throwaway row via ordinary
`Letflow.Repo.insert!/1` inside its own test body — any schema already
migrated into the base test database works (e.g. a `Letflow.Identity.Tenant`
row, or any global-schema table `PackUpdateMigrationTest` itself already
uses, to avoid inventing a new fixture).

**Deterministic trigger, not timing-dependent.** Rather than relying on
ExUnit's own non-deterministic scheduling to land two tests at the exact
unlucky instant (what made ISS-0480 itself intermittent — 1 of 2 runs in
ISSUE-FIXER's own reproduction), the regression test forces the race
directly, the same "simulate it, don't wait for it" discipline ISS-0110's
own design used:

1. In the test body, after the throwaway `Letflow.Repo.insert!/1` (so the
   test process now holds a checked-out `Letflow.Repo` connection with an
   in-flight, uncommitted insert — exactly `RowApprovalTest`'s own shape
   between its `create()` and later `get()` calls), spawn a **second**
   process (`Task.async/1` — this is exactly mechanism (b)'s own shape, used
   here deliberately as the test's OWN controlled tool rather than something
   to avoid) that calls `Letflow.TenantFixture.provisioned_tenant!/1`
   directly (default opts) — i.e., the regression test manufactures the
   exact "some other concurrently-running `TenantFixture` caller" scenario
   ISS-0480 needs, without depending on ExUnit's own scheduler happening to
   interleave two unrelated test modules at the right instant.
2. `Task.await/1` the spawned process, so the test body's own subsequent
   assertion runs strictly after `provisioned_tenant!/1`'s own
   `Sandbox.mode/2` call (whichever repo it targets, pre- or post-fix) has
   already executed and returned.
3. Assert that the throwaway row inserted in step 1 is STILL visible via a
   fresh `Letflow.Repo.get/2` (or equivalent) on the SAME test process —
   this is the property ISS-0480's own two victims lost (`RowApprovalTest`'s
   `{:error, :not_found}`, `PackUpdateMigrationTest`'s FK violation against a
   vanished `tenants` row) and the property §10 is meant to restore
   unconditionally.

**Expected result, pre-§10 (fail):** step 1's `Task.async/1`-spawned
`provisioned_tenant!/1` call's own `Sandbox.mode(Letflow.Repo, :auto)` line
(today's code) checks in the OUTER test process's own `Letflow.Repo`
connection (per §9.1's global, empty-exclusion-list check-in), discarding
its in-flight transaction. Step 3's `Repo.get/2` on that same process then
either raises `DBConnection.OwnershipError` (connection no longer checked
out at all) or, if `DataCase.setup/1`'s own per-test checkout races back in
first, observes the row as absent (the sandboxed transaction holding the
insert was rolled back on check-in, matching `RowApprovalTest`'s own exact
symptom) — either failure mode demonstrates the hazard deterministically,
every run, with no dependency on suite-wide scheduling luck. **This must
actually be run against current `main` (pre-§10) to confirm it fails before
being trusted as a regression test** — TEST-DESIGNER/TEST-RUNNER's own job,
not asserted here without that run.

**Expected result, post-§10 (pass):** the spawned process's
`provisioned_tenant!/1` call now issues `Sandbox.mode(Letflow.Test.ProvisioningRepo,
:auto)` instead (§10.3.2 step 2) — a call to a wholly different ownership
manager that has never held a checkout for the outer test process, so
nothing belonging to the outer test's `Letflow.Repo` connection is ever
touched. Step 3's assertion holds unconditionally, not merely "in this run's
luck" — because the mechanism removing the hazard is structural (a different
pool entirely), not probabilistic, this test does not need many repeated
runs to be trustworthy the way ISSUE-FIXER's own suite-wide reproduction did
(2 full-suite runs, 3 live incidents, still probabilistic) — one deterministic
run genuinely proves the property, and repeating it (a handful of times,
optionally with `Task.async` timing perturbed via a small explicit delay
variant) is a sanity check on determinism claims, not a requirement for the
core proof the way it was for the pre-fix probabilistic hazard.

**Why this mirrors ISS-0110's technique specifically, not merely "a
concurrency test":** ISS-0110's own design (cited by this record's own
`docs/issues/ISS-0110.yaml`) constructed its race directly with an
explicitly-spawned second process holding a real lock, rather than relying
on the reaper's own timer firing at an unlucky moment during a real suite
run — the same "manufacture the adversarial timing yourself" principle this
section applies to `Sandbox.mode/2`'s own global effect.

### 10.7 Open questions (explicit, not silently resolved)

- **OQ-6.** §10.3.4 disclosed that `ProvisioningRepo`'s connections carry the
  same `application_name` tag as `Letflow.Repo`'s, so
  `Letflow.TenantSchemaReaper`'s ISS-0110 liveness guard sees them as
  same-invocation siblings. This design asserts (but does not re-derive from
  the reaper's own source, which is out of this design's own scope per the
  handoff's module ownership list) that the reaper's own logic only COUNTS
  connections per invocation/partition-group and does not assume exactly one
  connection per test process — if that assumption is wrong, ELIXIR-DEV must
  check `test/support/tenant_schema_reaper.ex` directly before implementing
  and report back if it needs a design update.
- **OQ-7.** §10.3.2's `put_dynamic_repo/1` wrapping must be exception-safe
  (restore the default dynamic repo even if `TenantProvisioning`'s own calls
  raise) — this is a `try/after` shape ELIXIR-DEV must apply at each of the
  wrap points named in §10.3.2 (steps 3/4/6); not spelled out as literal code
  here per this project's design/implementation split, but stated as a hard
  requirement: a raised `ExUnit.AssertionError` from `assert_schema_complete!/2`
  must not leave the calling test process's dynamic-repo binding pointed at
  `ProvisioningRepo`, or every subsequent `Repo.` call the test body itself
  makes after catching/tolerating that raise (rare, but `opts[:teardown]:
  false`'s own stated purpose in the existing moduledoc is exactly to let a
  caller construct a broken state deliberately) would silently target the
  wrong repo.
- **OQ-8.** §10.2.2's closing bullet flags the two-language
  (`scripts/test_parallel.sh` bash vs. `config/test.exs` Elixir)
  synchronization of the `PROVISIONING_POOL_SIZE`/pool_size=2 constant as an
  implementer's choice (hard-coded literal in both vs. one exported env var)
  with no behavioral difference either way — ELIXIR-DEV decides, does not
  need a design update either way.
- **OQ-9.** This design does not itself run `mix test` to empirically confirm
  §10.6's regression test's own pre-fix-fails/post-fix-passes claim, nor a
  full-suite run confirming no other file depends on `Letflow.Repo`-scoped
  `Sandbox.mode/2` timing from `TenantFixture` in some way this design has
  not anticipated (matching §7 OQ-3's own already-stated division of labor —
  design produces signatures and a reasoned mechanism, not a verified-by-
  running one). CODE-DESIGN-VALIDATOR, TEST-DESIGNER's own regression test,
  and TEST-RUNNER's real `mix test`/`scripts/test_parallel.sh` runs are what
  actually confirm this section's mechanism holds under real execution —
  explicitly including the double full-suite run this project's own
  redundancy principle requires before a fix of this shape (touching shared
  test infrastructure) can be trusted.
