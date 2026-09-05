# ISS-0113 — Per-caller opt-in Sandbox-mode restore in `Letflow.TenantFixture.provisioned_tenant!/1`

Status: design, **§11.10.2/§11.10.2a/§11.10.4a CORRECTED (WF-03 Step 2,
`WF03-ISS0480-20260905` REWORK ITERATION 5, documentation-only — no
implementation change).** §11.10.2's own stated safety premise ("the
shared connection is ordinarily-committing, never rolled back at
teardown") was FALSE, per ISSUE-FIXER's mechanical reassessment
(`handoffs/WF03-ISS0480-20260905/step-13-issue-fixer-reassessment.json`):
`Ecto.Adapters.SQL.Sandbox.checkout/2` unconditionally installs
rollback-at-checkin hooks regardless of `:auto`/`:manual`/`{:shared, pid}`
mode, so `provision_via_shared_connection/1`'s writes on the
`DataCase`-checked-out `Letflow.Repo` connection are always removed by the
ambient Sandbox rollback before `teardown_wrap`'s own DROP SCHEMA/DELETE
ever runs, for the `async: false` + `template: :clone` default path (44 of
47 real call sites). `teardown_wrap`'s DROP/DELETE is retained as harmless,
already-idempotent defense-in-depth for this path (and remains the genuine,
load-bearing cleanup for a caller provisioning via
`with_provisioning_repo/1`/`ProvisioningRepo` directly, per §10's original
mechanism, whose writes ARE durable) — not the operative cleanup mechanism
§11.10.2 originally believed it to be for the shared-connection path. See
§11.10.2 (corrected premise), §11.10.2a (new — what `teardown_wrap`
actually accomplishes and why no new hazard exists), and §11.10.4a (new —
corrects `test/letflow/support/tenant_fixture_test.exs`'s C5 test, which
asserted `schema_present_before_drop=true` as the expected/only case; that
assertion encoded the same false premise). No code/behavior change to
`teardown/2`, `guarded/2`, or `log_teardown/3` follows from this
correction — §11.10.5's implementation list gains only a comment-text fix
(item 4a).

Prior status line, superseded above but kept for the historical record:
**§11 ADDED (WF-03 Step 2, `WF03-ISS0480-20260905` REWORK
ITERATION 2), §11.2/§11.4 CORRECTED (same run, REWORK ITERATION 2 re-gate),
§11.9 ADDED + §11.2/§11.4/§11.7 CORRECTED AGAIN (WF-03 Step 2, REWORK
ITERATION 3) — SUPERSEDES §10.2/§10.3/§10.3.2 for `async: false` callers.**
The iteration-2 correction: §11.2/§11.4 originally stated their safety
property only in terms of `{:shared, self()}` mode being left alone;
CODE-DESIGN-VALIDATOR found that premise false for
`test/support/tenant_fixture_dispatch_test.exs` (ambient mode is `:auto`
there, per that file's own local `setup`), so both sections now state the
property mode-agnostically (no `Sandbox.mode/2` call issued, so whichever
mode is ambient — `{:shared, self()}` or `:auto` — is undisturbed) and cite
§9.3's single-owner-under-`:auto` trace for the `:auto` sub-case.

**The iteration-3 correction (§11.9, normative): §11.2/§11.4's own claim
that `provision_via_shared_connection/1`'s path "issues zero `Sandbox.mode/2`
calls of any kind" was FALSE as originally stated** — ELIXIR-DEV's own
required §11.7 regression run (`backfill_test.exs` fail-then-pass) caught it
empirically before it shipped: `test/support/tenant_template.ex:82`'s
`Letflow.Test.TenantTemplate.ensure_template!/0`, called by every
`template: :clone` provisioning call (the default, §11.1's own dispatch
target for `provision_via_shared_connection/1`), issues its own unconditional
`Sandbox.mode(Letflow.Repo, :auto)` as its own first line — already
documented by §9.7, but never reconciled against §11.2/§11.4's own "zero
calls" claim. §11.9 is the reconciliation: it makes `ensure_template!/0`'s
own mode-setting conditional on the template not already being built
(`template_ready?/0`), the fast/steady-state path for every real call after
a partition's first, which is what removes the disruptive call from
`provision_via_shared_connection/1`'s reachable path without touching the
one case (first-ever build) that genuinely needs `:auto` mode to run
`unboxed_run/3`'s DDL. §11.2/§11.4's own text is corrected in place (not
merely appended to) to state the property precisely: "zero `Sandbox.mode/2`
calls once the template is already built" — see §11.9 for why that
qualifier is both necessary and sufficient.
§10's structural fix (route ALL provisioning through a second, dedicated
`Ecto.Repo`, `Letflow.Test.ProvisioningRepo`) was implemented, and a
full-suite `mix test` run (not the 172-test scoped run §10.7's OQ-9 status
line reported clean) found 18-19 reproducible failures — every one of them
an `async: false` caller of `provisioned_tenant!/1` whose OWN later
`Letflow.Repo` reads (e.g. `backfill_test.exs`'s `Repo.all(Registration)`)
could no longer see the fixture's own provisioning writes, because those
writes now commit on `ProvisioningRepo`'s separate connection while the
caller's own shared-mode `Letflow.Repo` connection, opened earlier by
`DataCase.setup/1` and never touched since, has no way to see a different
connection's commit — ordinary Postgres MVCC, not a sandbox defect. See
§11.0 for the full re-diagnosis and why this population (44 of 47 real call
sites, confirmed by `ISSUE-FIXER`'s rediagnosis,
`handoffs/WF03-ISS0480-20260905/step-06-issue-fixer-rediagnosis.json`) was
never the vector for the ORIGINAL ISS-0113/ISS-0480 hazard in the first
place, and therefore needs — and can safely use — a different code path than
`async: true` callers.

**§11 is normative for `provisioned_tenant!/1`'s own dispatch between two
paths, superseding §10.3.2 steps 1-6's "every call always goes through
`ProvisioningRepo`" framing.** §10.0/§10.1/§10.2 (why a structural,
separate-pool fix is needed at all, why `SandboxPool` is not a shortcut, the
connection-budget reconciliation) remain fully valid and are UNCHANGED —
`ProvisioningRepo` still exists, is still the correct and only mechanism for
`async: true` callers, and closes ISS-0480's original zero-`TenantFixture`-
involvement hazard exactly as designed. §10.3.1 (`ProvisioningRepo` module
itself), §10.3.3 (supervision), §10.3.4 (config) are UNCHANGED. §10.4-§10.8
are revised only where §11 explicitly says so (§11.5). Read §11 in full if
you are here for this rework; §10 (all of it, including §10.8) is prior art
it builds on, not a mechanism it discards wholesale — most of §10 is still
exactly what ships.

Earlier status line, superseded by the above but kept for the historical
record: "§10 ADDED (WF-03 Step 2, `WF03-ISS0480-20260905`), §10.8 ADDED (WF-03
Step 2 REWORK ITERATION 1, same run) — a structural fix for ISS-0480's own
recurrence of this record's disclosed-open scope, plus a narrow, 2-file
exception-handling addendum found only by real execution (ELIXIR-DEV's own
scoped test run, not a static read)." §§0–9 below are prior art both §10 and
§11 build on and must not silently re-attempt.

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
- **Every existing call site's own source, WITH ONE NARROW, NAMED EXCEPTION
  — see §10.8.** Re-verified by real execution (not merely re-derivation from
  this section's own original reasoning) during this rework:
  **44 of the 46 `TenantFixture` call sites require zero edits**, exactly as
  originally claimed — confirmed by ELIXIR-DEV's own scoped 172-test run
  (the 2 already-async files, both actual ISS-0480 victims, and 9 more
  `TenantFixture`-calling files, zero unexpected failures). **The remaining
  2 — `test/letflow/support/tenant_fixture_test.exs` and
  `test/letflow/definitions/promotion_assertion_rerun_test.exs` — require a
  small, specific edit to their OWN local helpers, stated precisely in §10.8,
  because each has its own hand-rolled helper that calls `Repo` (i.e.
  `Letflow.Repo`, via `DataCase`'s own `alias Letflow.Repo`) directly, bypassing
  `provisioned_tenant!/1`'s own call boundary entirely, and structurally
  depended on this design's own removed side effect (§10.3.2 step 1: the old
  unconditional `Sandbox.mode(Letflow.Repo, :auto)` line no longer runs).**
  This is not a weakening of the "zero call-site edits" property for the
  other 44 — it was never true, and is not claimed, for a call site whose own
  code reaches around `TenantFixture`'s public API to touch `Letflow.Repo`
  directly; the original claim's scope was, and remains, "every call site
  that only calls `provisioned_tenant!/1` itself, and does not also call
  `Repo` on its own for state provisioning created," which the other 44 do
  and these 2 do not.
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
- **OQ-9 status, updated by the §10.8 rework below: RESOLVED for the 2 named
  exception files** — ELIXIR-DEV's own scoped run (172 tests, both actual
  ISS-0480 victims plus 11 more `TenantFixture`-calling files) empirically
  confirmed §10's core mechanism (§10.3.2/§10.3.4) holds exactly as designed,
  and empirically surfaced the 2-file gap §10.8 now closes — this is OQ-9
  doing its job, not a failure of it. A full-suite / double-full-suite run
  incorporating §10.8's own edit remains open and is TEST-RUNNER's, not this
  design's, responsibility, unchanged from the original OQ-9 text above.

## 10.8 REWORK: the 2 named exception files — precise, narrow scope, and why
     this does not reopen or weaken §10.3 (normative for these 2 files only)

### 10.8.1 What real execution found, re-verified against source rather than
     inherited from the rework handoff's own claim

Per `docs/anti-patterns.md`'s "don't inherit a claim instead of re-deriving
it": both files named in ELIXIR-DEV's BLOCKER
(`handoffs/WF03-ISS0480-20260905/step-03a-elixir-dev.json` `result.issues[0]`)
were read directly this session, not merely trusted from the handoff's own
description.

- **`test/letflow/support/tenant_fixture_test.exs`** (lines 420–434,
  confirmed by direct read): `broken_state_tenant!/1` calls
  `TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix, teardown:
  false)` — i.e. it deliberately opts OUT of the fixture's own `on_exit/1`
  teardown (`opts[:teardown] == false`, an existing, unmodified feature,
  §10.3.2 untouched) — and registers its OWN `on_exit(fn -> hard_cleanup(...)
  end)` instead. `hard_cleanup/1` (lines 426–434) issues `Repo.query!(DROP
  SCHEMA IF EXISTS ... CASCADE)`, `Repo.delete_all(Registration ...)`, and
  `Repo.delete_all(Tenant ...)` — the exact same three statements
  `TenantFixture`'s own internal `teardown/2` (§10.3.2 item 6) issues, copied
  into this file's own helper specifically so the test can drop **additional**
  tables/state (`drop_table!/2`, confirmed present elsewhere in this file)
  before the schema itself is dropped, a sequencing `teardown/2`'s own
  fixed order cannot express. Because `Repo` here resolves to `Letflow.Repo`
  (via `DataCase`'s own `alias Letflow.Repo`, confirmed by direct read of
  `test/support/data_case.ex:11`) and this helper calls it directly, with no
  `with_provisioning_repo/1`-equivalent wrapping of its own, it depends on
  whatever the ambient dynamic-repo/sandbox-mode state happens to be at the
  moment `on_exit/1` runs it — before §10, that was always `Letflow.Repo`
  itself in `:auto` mode (the now-removed unconditional first line); after
  §10, `Letflow.Repo`'s pool is never touched by provisioning at all, so this
  helper's calls hit `Letflow.Repo`'s own **still-`:manual`-mode, no-ambient-
  checkout** connection from a process (the `on_exit/1` callback process) that
  is not a descendant of the test process and holds no checkout of its own —
  exactly the `** (EXIT) shutdown: "owner ... exited"` ELIXIR-DEV observed.
- **`test/letflow/definitions/promotion_assertion_rerun_test.exs`** (lines
  100–160, confirmed by direct read): `drop_schema!/1` (100–102),
  `schema_exists?/1` (142–149), and `sandbox_process_definition_ids/1`
  (155–160) all call bare `Repo.query!/2` — again `Letflow.Repo`, same
  `DataCase` alias — against a `SandboxPool`-provisioned sandbox schema (NOT
  a `TenantFixture`-provisioned tenant schema; the moduledoc's own §"Fixture
  strategy" is explicit these are two distinct provisioning mechanisms used
  side by side in this file). These 3 helpers are unaffected by §10 in
  themselves (they never went through `TenantFixture` or `ProvisioningRepo`
  at all — `SandboxPool`'s own DB worker, per §10.1, still issues ordinary
  `Letflow.Repo` calls, unchanged) — **the actual regression is elsewhere in
  this file**: `provisioned_tenant/0` (lines 113–118, confirmed) is this
  file's own thin wrapper around `TenantFixture.provisioned_tenant!/1` with no
  `opts[:teardown]` override (default `true`, ordinary shape, no local
  helper bypassing `TenantFixture`'s own teardown here) — called once per
  test, an ordinary, single-call, mechanism-(c)-clear call site by §3/§4.2's
  own procedure. What ELIXIR-DEV's trace found is the **AC1 test**'s own
  second, REAL claim against a dedicated `SandboxPool` instance
  (`start_pool!(max_concurrent: 1)`, line 430, then a genuine second
  `SandboxPool.claim/0, pool)` at line 462 to exhaust the pool) racing against
  `Letflow.Repo`'s own now-`:manual` mode in a way the pre-§10 code's
  ambient `:auto` mode from `TenantFixture` masked — this is a live
  **mechanism (c)-shaped** interaction (§2's "second provisioning call,"
  restated: `SandboxPool.claim/2`'s own provisioning sequence, per the
  moduledoc's own line 18, "internally calls `Ecto.Migrator.run/4`") that
  previously worked ONLY because `provisioned_tenant/0`'s call, earlier in
  the same test, had left `Letflow.Repo` in `:auto` mode for the rest of the
  test body — precisely the ambient side effect §10.3.2 step 1 correctly
  removes. The observed symptom (`{:error, :provision_failed}` expected vs.
  `{:error, {:transaction_failed, exception}}` observed) is this file's own
  `SandboxPool`-mediated migrator work failing to get a real, independent
  connection once `Letflow.Repo` sits in `:manual` mode with no ambient
  `:auto` window left open by `TenantFixture` to run inside of.

### 10.8.2 Direction chosen: (a) — both files' own helpers call the same seam
     `TenantFixture` itself now uses, explicitly, themselves

**Chosen: (a).** Both files gain a small, local, explicit
`Ecto.Repo.put_dynamic_repo(Letflow.Test.ProvisioningRepo)` +
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Test.ProvisioningRepo, :auto)` wrap
around their own bare `Repo` calls that touch `TenantFixture`-provisioned
state — mirroring, not re-inventing, `with_provisioning_repo/1`'s own shape
(§10.3.2/§10.3.4, already shipped, unmodified). **(b) is explicitly rejected**
for the reason the rework handoff itself names: any mechanism that restores
`Letflow.Repo`'s own pool to `:auto` mode as a general or even
file-scoped-but-ambient side effect reintroduces exactly the global,
whole-pool check-in ISS-0480 exists to remove — `Letflow.Test.
ProvisioningRepo` already exists, is already test-support public surface
(a plain, no-custom-function `Ecto.Repo` module, §10.3.1), and calling
`Sandbox.mode/2`/`put_dynamic_repo/1` on it from a SECOND caller besides
`TenantFixture` does not create a new global-reach hazard — §10.2's own
load-bearing property (a mode change's check-in effect is scoped to the
ownership-manager process for the SPECIFIC repo targeted) holds identically
regardless of which test-support code issues the call, since the property is
about which POOL is affected, not about a single privileged caller.

This is deliberately **not** a change inside `Letflow.TenantFixture` itself,
`Letflow.Test.ProvisioningRepo` itself, or §10.3's normative mechanism — both
edits are entirely local to the 2 named test files' own already-existing
private helper functions, adding a wrapping call at the point each helper
issues its `Repo.query!`/`Repo.delete_all` calls, not touching
`provisioned_tenant!/1`, `with_provisioning_repo/1`, or any call-site's own
`provisioned_tenant!(...)` invocation.

#### 10.8.2.1 `test/letflow/support/tenant_fixture_test.exs` — precise edit

`hard_cleanup/1` (the private helper at lines 426–434) must issue its 3
existing `Repo` calls (unchanged: the DROP SCHEMA query, the two
`Repo.delete_all` calls) from inside the SAME wrap
`with_provisioning_repo/1` performs internally — i.e., before its first
`Repo` call, this helper's own body must:

1. Call `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Test.ProvisioningRepo, :auto)`
   (idempotent/no-op if already `:auto`, per §9.1's own guard, restated here
   as still true for `ProvisioningRepo`'s own ownership manager).
2. Capture `Ecto.Repo.get_dynamic_repo()` (or equivalently, `Letflow.Repo`'s
   own dynamic-repo binding — this is the SAME `Repo` alias-target,
   `Letflow.Repo`, whose `put_dynamic_repo/1`/`get_dynamic_repo/0` functions
   this design already relies on elsewhere, §10.3.2), then
   `Ecto.Repo.put_dynamic_repo(Letflow.Test.ProvisioningRepo)`.
3. Issue the 3 existing `Repo.query!`/`Repo.delete_all` calls, unchanged in
   content, order, and target table.
4. Restore the previously-captured dynamic repo in an `after` block (OQ-7's
   own exception-safety requirement, restated as equally load-bearing here:
   `on_exit/1` callbacks in this codebase run other callbacks afterward,
   e.g. `LogCollector`-related ones in this same file per its own moduledoc,
   so leaving the dynamic-repo binding pointed at `ProvisioningRepo` past
   this helper's own return would be a new, local hazard this edit must not
   introduce).

No change to `broken_state_tenant!/1`'s own call to
`provisioned_tenant!(slug_prefix: ..., teardown: false)` — that call site is
untouched, ordinary, and already covered by the "zero edits" claim for the
other 44 files' shape (it is `hard_cleanup/1`'s OWN bypass of
`TenantFixture`'s teardown path, not the `provisioned_tenant!/1` call itself,
that needs this wrap). No change to `drop_table!/2`,
`table_exists?/2`, or any other helper in this file whose own calls run
inside the test body proper (a descendant of the test process, which still
holds its own ordinary `Letflow.Repo` checkout via `DataCase.setup/1`,
unaffected by §10 — only `on_exit/1`-run code, with no ambient checkout of
its own, needs this wrap).

#### 10.8.2.2 `test/letflow/definitions/promotion_assertion_rerun_test.exs` —
     precise edit

Unlike file 1, this file's 3 bare-`Repo` helpers (`drop_schema!/1`,
`schema_exists?/1`, `sandbox_process_definition_ids/1`) are **not** the
defect — they operate on `SandboxPool`-provisioned schemas, run from
ordinary test-body or `on_exit/1` contexts that were never dependent on
`TenantFixture`'s own `:auto`-mode side effect for THEIR OWN correctness
(confirmed §10.8.1: `SandboxPool`'s DB worker was never routed through
`ProvisioningRepo`, and still is not — §10.1's own finding that `SandboxPool`
reuses `Letflow.Repo` directly is unchanged by this rework). **Do not wrap
these 3 helpers** — doing so would be a change with no defect to fix and
would misrepresent which mechanism this file's regression actually involves.

The actual, narrow fix: `provisioned_tenant/0` (lines 113–118) is this file's
own thin, single-call wrapper around `TenantFixture.provisioned_tenant!/1`.
Per §10.8.1's trace, the AC1 test's real second `SandboxPool.claim/2` call
(line 462, exhausting the dedicated pool) needs `Letflow.Repo` to have a real
window of `:auto`-mode availability to run its own migrator work in, a window
the pre-§10 code got for free (as an unintended side effect) from
`provisioned_tenant/0`'s own call earlier in the same test, and which §10.3.2
step 1 correctly removes as a `Letflow.Repo`-pool-wide effect. This file's
`provisioned_tenant/0` wrapper gains its own explicit
`Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` call, made **once, by
this file itself, deliberately and locally** — i.e., the same call
`provisioned_tenant!/1` used to make unconditionally for every one of the 46
callers, now scoped to exactly the one caller (this file) whose own test body
independently, and for reasons unrelated to `TenantFixture`, needs
`Letflow.Repo` in `:auto` mode for the rest of the test. This is safe under
the same §9.4/§10 argument that governs everywhere else the pool-wide
`:auto` call is made deliberately: this file is `async: false` (its own
moduledoc line 26, confirmed, unchanged by this rework), so ExUnit never
schedules it concurrently with `RowApprovalTest`/`PackUpdateMigrationTest`
or any other `async: true` file — the ISS-0480 hazard is specifically about
an `async: true` caller's `:auto` call reaching an unrelated `async: true`
victim, and an `async: false` file's own `Sandbox.mode(Letflow.Repo, :auto)`
call, made once, is exactly what §9.4's second bullet already establishes as
harmless (ExUnit drains the sync queue serially, no concurrently-checked-out
`async: true` connection exists to disrupt at the moment an `async: false`
module's test runs).

Precisely: `provisioned_tenant/0`'s body becomes (call ordering, not literal
code): call `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` as its own
first statement, THEN call `Letflow.TenantFixture.provisioned_tenant!(...)`
exactly as today (unchanged arguments) and return its result unchanged. No
`after`/restore is added — this mirrors §9.3's own established finding
(restated, not reopened) that leaving `:auto` in effect for the rest of an
`async: false` test, with no restore, is the correct and only mechanism that
does not discard an in-flight connection; a restore-to-`:manual` step here
would repeat exactly the Mechanism-4 mistake §9.2 already diagnosed and
rejected, this time on `Letflow.Repo` in a file that, unlike the original
mechanism, has no concurrent-async exposure to worry about masking. No
`Repo.put_dynamic_repo/1` call is needed here (unlike §10.8.2.1) because this
edit's own target is `Letflow.Repo` itself, not `ProvisioningRepo` — the AC1
test's own `SandboxPool`-driven migrator work runs against `Letflow.Repo`
directly (per §10.1), not against `ProvisioningRepo`, so no dynamic-repo
redirection applies to it.

### 10.8.3 What this does NOT change, stated explicitly

- **§10.3's normative mechanism** (the `Letflow.Test.ProvisioningRepo`
  module, `with_provisioning_repo/1`'s own shape, `provisioned_tenant!/1`'s
  public `@spec`/`opts()`/return shape) — untouched. Neither of §10.8.2.1's
  or §10.8.2.2's edits modifies `test/support/tenant_fixture.ex` or
  `test/support/provisioning_repo.ex` at all.
- **§10.4's "zero call-site edits" claim for the other 44 files** — still
  true, unaffected; §10.4 above is revised only to name these 2 files'
  narrow exception precisely rather than leaving a false blanket claim
  standing.
- **`Letflow.Repo`'s pool-wide `:auto` mode is NOT restored as a general
  side effect anywhere** — §10.8.2.2's `Sandbox.mode(Letflow.Repo, :auto)`
  call is made by exactly one `async: false` file's own test-support code,
  for exactly the reason §9.3/§9.4 already establish is safe for an
  `async: false` caller, and is not a change to `TenantFixture` or to any
  shared/global mechanism — it is the SAME kind of call the 44 unconverted
  `TenantFixture`-calling files already trigger via `provisioned_tenant!/1`
  itself before this rework and continue to trigger after it (indirectly,
  through `TenantFixture`'s replacement mechanism) — this file simply also
  makes that call directly, once, for its own additional, non-`TenantFixture`
  reason. It does not reintroduce ISS-0480's hazard because ISS-0480's
  hazard requires an `async: true` caller; this caller is not one.
- **No test assertion text changes in either file** — both edits are
  additions to existing private helper functions' own bodies (a wrap in one
  case, one new leading statement in the other), not changes to any `assert`/
  `test`/`describe` block.
- **No new file, no new module, no new config** — both edits live entirely
  inside the 2 named `.exs` files' own existing private functions.

### 10.8.4 Verification ELIXIR-DEV must run for this rework specifically

In addition to §10.6's regression test and the scoped run §10's own original
acceptance criteria already require:

1. `mix test test/letflow/support/tenant_fixture_test.exs` — must return to
   14/14 passing (the pre-§10 baseline ELIXIR-DEV's own `git stash`
   comparison established), not merely "no crash."
2. `mix test test/letflow/definitions/promotion_assertion_rerun_test.exs` —
   must return to 12/12 passing (same baseline method), with particular
   attention to the AC1 test's own exact `{:error, :sandbox_unavailable}` /
   `{:ok, result2}` assertions (lines 462–498) — the specific interaction
   §10.8.1 traced — passing for the RIGHT reason (a real, working
   `Letflow.Repo` `:auto`-mode window), not by accident.
3. Re-run the original §10 scoped set (the 172-test run: both actual
   ISS-0480 victims, the 2 already-async files, and the other 9
   `TenantFixture`-calling files) to confirm this rework's 2 local edits
   introduce no new regression outside the 2 named files.
4. `mix compile --warnings-as-errors --force` — clean, as before.

## 11. REWORK ITERATION 2 — dual-path dispatch in `provisioned_tenant!/1`:
    `ProvisioningRepo` for `async: true`, `Letflow.Repo` directly for
    `async: false` (normative, supersedes §10.3.2 steps 1-6 and §10.4's
    "every call routes through ProvisioningRepo" framing)

### 11.0 Re-diagnosis, re-verified rather than inherited

Per `docs/anti-patterns.md`'s "don't inherit a claim instead of re-deriving
it" and `HANDOFF_PROTOCOL.md` §1.1: ISSUE-FIXER's rediagnosis
(`handoffs/WF03-ISS0480-20260905/step-06-issue-fixer-rediagnosis.json`) is
read in full; its two load-bearing claims are re-checked here against
source already read for §§9-10 above, not merely quoted.

**Claim 1 — population size and shape.** 44 of 47 files calling
`Letflow.TenantFixture.provisioned_tenant!/1` (47 = 46 real call sites per
§0's own original count, plus this design's own §10.6 regression test,
`test/letflow/iss0480_provisioning_repo_isolation_test.exs`, added since —
confirmed by direct re-read of that file, line 55: `use Letflow.DataCase,
async: true`, so it is one of the 3 `async: true` files, not one of the 44)
are `async: false`. Re-verified this session by reading
`test/letflow/tenant_provisioning/backfill_test.exs` directly (line 20: `use
Letflow.DataCase, async: false`) — TEST-RUNNER's own root-caused failing
example — and spot-checking `test/letflow/secrets_test.exs`/
`test/letflow/webhooks_test.exs` (both `async: true`, confirmed, the only 2
real callers in that state, matching §0/§9's own original count exactly).
**This is the default shape of the call population, not an edge case** — any
mechanism §11 specifies for `async: false` callers is specifying the
mechanism for the overwhelming majority of `provisioned_tenant!/1`'s real
callers, not a narrow addendum the way §10.8's 2-file exception was.

**Claim 2 — the failure mechanism is ordinary cross-connection MVCC
isolation, not a sandbox defect.** Re-derived directly from `test/support/
data_case.ex:15-23` (already read in full, §9.1 above) plus `test/support/
tenant_fixture.ex`'s current `with_provisioning_repo/1` (lines 291-301,
already read in full above): for an `async: false` test, `DataCase.setup/1`
does `Sandbox.checkout(Letflow.Repo)` then `Sandbox.mode(Letflow.Repo,
{:shared, self()})` — ONE connection, opened once, held for the test's
entire body. `provisioned_tenant!/1`'s current (post-§10) body never touches
that connection at all: it calls `Repo.put_dynamic_repo(Letflow.Test.
ProvisioningRepo)`, does its `Tenant` insert and schema provisioning there,
and restores the dynamic-repo binding — the Tenant row is genuinely
committed, but on `ProvisioningRepo`'s own separate physical connection.
`backfill_test.exs`'s later `Repo.all(Registration)`
(`lib/letflow/tenant_provisioning/backfill.ex:20`, confirmed by the
rediagnosis's own citation) runs on the caller's ORIGINAL `Letflow.Repo`
connection from `DataCase.setup/1` — a connection that began its
transaction before `ProvisioningRepo`'s insert committed, and Postgres's own
MVCC snapshot semantics mean an already-open transaction on one connection
never sees a different connection's later commit, sandboxed or not. **This
is not a bug in `Ecto.Adapters.SQL.Sandbox` and not something any Sandbox
API can bridge** — re-confirmed directly against `deps/ecto_sql/lib/ecto/
adapters/sql/sandbox.ex`'s own `mode/2`/`checkout/2`/`allow/3` specs (lines
480-620, already read for §9.1): `{:shared, pid}` and `allow/3` both operate
WITHIN one repo's one already-checked-out connection — broadening WHO may
use it, never WHICH connection is in play — and neither has any parameter or
mode that spans two different `Ecto.Repo` modules' pools. There is no
`Sandbox.share_connection_across_repos/2`-shaped API and none is possible
within the library's own architecture (a connection belongs to exactly one
pool; "sharing a connection across two `Ecto.Repo`s" is not a concept
`DBConnection.Ownership` or `Ecto.Adapters.SQL.Sandbox` expresses anywhere).
**Confirmed, not merely inherited from the rediagnosis's own claim to the
same effect.**

**Claim 3 — `async: false` callers were never exposed to the ORIGINAL
ISS-0113/ISS-0480 hazard, and this is the asymmetry §11's dispatch relies
on.** Re-derived from `docs/agents/instructions/core-directives.md`-cited
ExUnit scheduling behavior already established at §5.1/§9.4 above ("ExUnit
runs every `async: false` module strictly serially, one test process at a
time, after all `async: true` modules have started/completed") plus
`data_case.ex:18`'s own `unless tags[:async]` guard: `{:shared, pid}` mode is
set ONLY for `async: false` tests, and ExUnit's own documented scheduling
guarantees at most one `async: false` test process is running (hence, at
most one `{:shared, pid}` mode is live on `Letflow.Repo`'s pool) at any
instant. The ORIGINAL ISS-0113/ISS-0480 hazard (`Sandbox.mode(Letflow.Repo,
:auto)`'s global, empty-exclusion-list check-in of every OTHER checked-out
connection, `proxy_checkin_all_except(state, [], caller)`, §9.1/§10.0 above)
is a hazard specifically about *concurrently scheduled* connections
colliding — `RowApprovalTest`'s own victimization required it to be running
CONCURRENTLY with `SecretsTest`'s `:auto` call, both `async: true`, both
scheduled into ExUnit's shared concurrent pool at the same moment. An
`async: false` caller's own `Sandbox.mode/2`-adjacent activity, by contrast,
runs during a phase of the suite (or a serialized slot within the async
phase's aftermath) where it is — by ExUnit's own documented scheduling
guarantee, not by luck — the ONLY test process that could be affected,
because no other test is running concurrently with it at all. **Restated
plainly: the ORIGINAL hazard's blast radius is "whoever else happens to be
concurrently checked out," and `async: false` execution structurally
guarantees nobody else is.** This holds regardless of which repo's pool an
`async: false` caller's own connection work touches — the property that
matters is "is anything else concurrently checked out to be collateral
damage," and for a serially-scheduled `async: false` test process, the
answer is structurally no. This is independently re-derived here, not
inherited from ISSUE-FIXER's rediagnosis text, though it reaches the
identical conclusion.

### 11.1 The dispatch: how `provisioned_tenant!/1` picks its path, with zero
    call-site edits

**Mechanism chosen: runtime detection via a value `Letflow.DataCase.setup/1`
already deterministically knows and can pass along a channel every one of
the 47 call sites already goes through — not a new `opts` key.** This
satisfies the "prefer runtime detection over asking 47 call sites to know
about this plumbing" instruction directly: no call site's own
`provisioned_tenant!(...)` invocation is edited, because `Letflow.DataCase`
is a fixed, shared dependency EVERY one of the 47 files already `use`s, and
it already receives the exact signal needed (`tags[:async]`, the literal
boolean ExUnit itself passes into `setup/1` — not inferred, not guessed).

**Why this is reliable where a Sandbox-introspection call is not.**
`Ecto.Adapters.SQL.Sandbox` exposes no function that reports a repo's
current mode back to the caller (confirmed: `sandbox.ex`'s only
mode-related exports are `mode/2` (write-only, returns `:ok`) and
`checkout/2` (returns `:ok | {:already, :owner | :allowed}`, not the mode) —
grepped the module's full export list this session, no `get_mode/1` or
equivalent exists). So "detect the mode `Letflow.Repo` is currently in" is
not an available primitive — confirming the rediagnosis's own framing that
the real candidates are (i) an explicit signal threaded through from the
caller's own test context, or (ii) a Sandbox-native bridge, which §11.0
Claim 2 already ruled out. **§11 chooses (i), routed through `DataCase`
rather than through each of the 47 call sites**, because `tags[:async]` is
already exactly the fact this dispatch needs, is already computed by ExUnit
itself (not derived or guessed by this design), and `DataCase.setup/1` is
the one place already common to all 47 callers.

**Concrete mechanism — process dictionary, set once per test process by
`DataCase.setup/1`, read once per call by `provisioned_tenant!/1`:**

- `Letflow.DataCase.setup/1` (`test/support/data_case.ex`) gains one new
  statement: after its existing `Sandbox.checkout(Letflow.Repo)` and the
  existing `unless tags[:async] do Sandbox.mode(Letflow.Repo, {:shared,
  self()}) end` block (both untouched, same order), set
  `Process.put(:letflow_data_case_shared_mode?, !tags[:async])` — a plain
  boolean, computed the exact same way the existing `unless tags[:async]`
  guard already is, stored in the calling TEST process's own dictionary
  (not a global, not an ETS table — process-scoped, exactly like `Ecto.Repo.
  put_dynamic_repo/1`'s own `{Letflow.Repo, :dynamic_repo}` process
  dictionary key that `with_provisioning_repo/1` already relies on, §10.3.2
  — this design reuses that exact idiom rather than introducing a new
  storage mechanism).
  - `@spec` addition to `Letflow.DataCase` (a `using`-macro module, no
    existing `@spec`-bearing public function of its own to extend): none —
    `setup/1` is an ExUnit callback, not a function this design's own
    callers invoke directly. Nothing about `Letflow.DataCase`'s own public
    surface (the `using do ... end` block, `alias Letflow.Repo`) changes.
- `Letflow.TenantFixture.provisioned_tenant!/1`'s dispatch point (replacing
  the unconditional `with_provisioning_repo/1` wrap around the `{tenant,
  schema_name}` block, §10.3.2's current shape) becomes: read
  `Process.get(:letflow_data_case_shared_mode?, false)` (default `false` —
  see §11.1.1 for why defaulting to the `ProvisioningRepo`/`async: true`
  path when the key is absent is the correct, safe default) and dispatch to
  one of two private functions:
  - `true` (an `async: false` caller, `DataCase` set the flag) →
    `provision_via_shared_connection(fn -> ... end)` (§11.2).
  - `false` (an `async: true` caller, or — defensively — any caller whose
    test process did not go through `Letflow.DataCase.setup/1` at all, e.g.
    a hypothetical future call site using a different `ExUnit.CaseTemplate`)
    → `with_provisioning_repo(fn -> ... end)` (§10.3.2, UNCHANGED, already
    shipped).
- **No `opts()` key is added.** `provisioned_tenant!/1`'s public `@spec`,
  `opts()` type, and return shape (`tenant_fixture()`) are BYTE-FOR-BYTE
  unchanged from §10.4's own already-normative statement — this dispatch is
  entirely internal, invisible at every one of the 47 call sites' own
  source. Re-affirms the "zero call-site edits" property for all 44
  `async: false` callers AND the existing 3 `async: true` files (2 shipped
  callers plus this design's own §10.6 regression test) simultaneously — a
  stronger claim than §10.4's own (which only covered the 44).

#### 11.1.1 Why defaulting the flag's absence to the `ProvisioningRepo` path
    (not the shared-connection path) is the safe choice

`Process.get(:letflow_data_case_shared_mode?, false)`'s default matters only
for a test process that calls `provisioned_tenant!/1` without ever having
run through `Letflow.DataCase.setup/1` — today, no such call site exists
(every one of the 47 files `use`s `Letflow.DataCase`, confirmed by the
original §0 count's own methodology), but a design must state the
degenerate case rather than leave it silently underspecified. Defaulting to
`false` (the `ProvisioningRepo` path, §10's original, already-proven-correct
mechanism) rather than `true` (the shared-connection path, §11.2) is the
conservative choice: an unrecognized/未-established caller falling through
to `ProvisioningRepo` reproduces exactly today's shipped, verified-safe §10
behavior (correct for `async: true`, and merely loses read-your-own-write
visibility for a hypothetical unclassified `async: false`-shaped caller —
a visible, debuggable test failure, not a silent cross-test corruption).
Defaulting the other way would risk executing §11.2's shared-connection path
for a caller this design has no evidence is actually running serially,
re-opening exactly the blast-radius question §11.0 Claim 3 depends on
`{:shared, pid}`'s own serialization guarantee to answer. **The default is a
safety fallback for an situation §11 does not believe can currently occur,
not a third supported mode.**

### 11.2 `provision_via_shared_connection/1` — the `async: false` path

**Purpose:** run provisioning's `Repo.` calls directly against
`Letflow.Repo`, on the SAME connection the caller's own test process is
already using at the moment this function runs — whatever mode that
connection is under (`{:shared, self()}`, established by `DataCase.setup/1`
for the common case; or `:auto`, if some other `setup` callback in the same
module changed it afterward, as `tenant_fixture_dispatch_test.exs`'s own
local setup does — see the third bullet below and §11.4) — i.e., restore the
pre-§10 behavior for this population specifically, without reintroducing the
pre-§10 code's OWN defect (§9's Mechanism 4 — a stray `Sandbox.mode
(Letflow.Repo, ...)` call disrupting the caller's connection) or the
ORIGINAL ISS-0113/ISS-0480 defect (an unconditional `Sandbox.mode
(Letflow.Repo, :auto)` reaching into the shared pool at all).

**Concrete mechanism — no `Sandbox.mode/2` call on `Letflow.Repo` at all,
by this path, ever:**

1. `Ecto.Repo.put_dynamic_repo(Letflow.Repo)` — a no-op in the ordinary case
   (the calling process's dynamic repo is already `Letflow.Repo`, since
   nothing has redirected it), but stated explicitly rather than assumed,
   so this path's own behavior does not depend on what a PRIOR call in the
   same test process may have left the dynamic-repo binding pointed at (the
   same defensive-explicitness discipline §10.3.2's own `after` block
   already applies in the other direction).
2. Run the caller's existing 3-6 step provisioning sequence (`Tenant`
   insert, `provision_schema!/2`'s `:clone`/`:replay` branch,
   `assert_schema_complete!/2`) EXACTLY as `with_provisioning_repo/1`'s own
   body already sequences them (§10.3.2 steps 3-4, same functions, same
   arguments, same order) — the only difference is which connection these
   `Repo.` calls resolve to, which is now `Letflow.Repo` itself (the dynamic
   repo binding step 1 just confirmed), not `ProvisioningRepo`.
3. **No `Sandbox.mode(Letflow.Repo, ...)` call of any kind, anywhere in this
   function's OWN body, and — once the template is already built,
   `template_ready?/0 == true`, the steady-state case for every call after a
   partition's first — none in anything it calls either, per §11.9's fix to
   `Letflow.Test.TenantTemplate.ensure_template!/0`.** (**CORRECTED, REWORK
   ITERATION 3:** the original text here claimed this held unconditionally,
   for the whole call tree, with no qualifier. That was false —
   `ensure_template!/0`, called from this path's own step 2 via
   `provision_schema!/2`'s `:clone` clause, issued its own unconditional
   `Sandbox.mode(Letflow.Repo, :auto)` regardless of template state, until
   §11.9's fix made that call conditional. The qualifier is real and load-
   bearing: this path is safe from the FIRST call in a partition (which
   still builds the template and still needs `:auto` mode to do so, §11.9)
   onward, but the FIRST call itself does issue one `Sandbox.mode/2` call —
   §11.9 states exactly why that single, one-time, per-partition call does
   not reopen anything §11.2/§11.4 need.) This is the single load-bearing
   property distinguishing §11.2 from both the original (pre-ISS-0113) code
   and the reverted §3.2 mechanism (§9.2): since this path issues no
   `Sandbox.mode/2` call itself (nor, post-§11.9, does its steady-state call
   tree), whichever mode/connection the caller's test process is ALREADY
   using at the moment this function runs is left completely undisturbed — that is
   normally `{:shared, self()}`, established once by `DataCase.setup/1`
   before this function ever runs, but it is not always: if a later `setup`
   callback declared in the same test module changes the mode again before
   `provisioned_tenant!/1` runs — as `tenant_fixture_dispatch_test.exs`'s own
   local `setup do Sandbox.mode(Letflow.Repo, :auto) end` (line 60) does,
   which ExUnit runs after `Letflow.DataCase`'s injected `setup` callback —
   the ambient mode at call time is `:auto` instead, and this path leaves
   THAT undisturbed just the same, for the identical reason (it issues no
   `Sandbox.mode/2` call to disturb it with). Either way, every
   `Repo.insert!/1`/`Repo.query!/2` call this function's own provisioning
   sequence makes is an ordinary query from the SAME already-checked-out
   connection — reusing it, never checking it in or replacing it, by the
   same `DBConnection.Ownership.Manager` rule §9.3 already traced
   (`{status, _ref, proxy} when status in [:owner, :allowed]` — this test
   process is already the proxy's recorded owner, whether that ownership was
   established by `DataCase.setup/1`'s own checkout under `{:shared,
   self()}`, or, for `tenant_fixture_dispatch_test.exs`'s own `:auto`-mode
   case, by the auto-checkout-and-record-owner step §9.3 itself traces —
   so every subsequent call just reuses it). **`Ecto.Migrator.run/4`'s own
   documented two-connection requirement (§9.7, quoted there) is why the
   pre-§9-rework, pre-§10 code needed `:auto` mode in the first place — does
   this path need it too?** Answered in §11.2.1: no, because of WHICH
   provisioning path (`:clone` vs `:replay`) is actually exercised by
   `async: false` callers today, and what happens if a future caller needs
   `:replay` under this path.

4. The function's own return value — `{tenant, schema_name}` — is identical
   in shape to `with_provisioning_repo/1`'s own return (§10.3.2's existing
   body), so `provisioned_tenant!/1`'s own final `%{tenant_id: ..., ...}`
   construction is unchanged regardless of which of the two dispatch
   branches ran.

**Teardown.** The `on_exit/1` callback registered for this path (mirroring
§10.3.2 step 6's shape, but for THIS path) must likewise run its 3
statements (`DROP SCHEMA`, 2x `Repo.delete_all`) via
`provision_via_shared_connection/1`'s own connection-targeting, i.e. against
`Letflow.Repo` with `Ecto.Repo.put_dynamic_repo(Letflow.Repo)` (a no-op,
stated for the same explicitness reason as step 1) — **not** wrapped in
`with_provisioning_repo/1`. This is a real, disclosed difference from
today's shipped code (§10.3.2 step 6 currently wraps teardown in
`with_provisioning_repo/1` unconditionally for every caller) — §11.3 states
precisely how `teardown/2`'s own single implementation dispatches the same
way `provisioned_tenant!/1` itself does, rather than duplicating `teardown/2`
into two copies.

#### 11.2.1 Why `Ecto.Migrator.run/4`'s two-connection requirement does not
     block this path — confirmed for `:clone`, flagged as a real constraint
     for `:replay`

§9.7 (already normative, re-confirmed here rather than re-litigated) quotes
`Ecto.Migrator.run/4`'s own moduledoc: migrations "cannot run dynamically
during test under the Ecto.Adapters.SQL.Sandbox, as the sandbox has to share
a single connection across processes." This is categorical for the
`:replay` path (`provision_schema!/2`'s `:replay` clause →
`TenantProvisioning.replay_migrations/1` → `Ecto.Migrator.run/4` directly) —
a single sandboxed connection, shared-mode or not, cannot satisfy
Migrator's real two-connection requirement.

**This does not block §11.2 for the overwhelming majority of the `async:
false` population, but it is NOT a zero-count case — corrected here after
this design's own first-pass grep missed a real file.** Re-grepped directly:
`grep -rl "template: :replay" test --include=*.exs` finds exactly ONE real
caller, `test/support/tenant_fixture_dispatch_test.exs` (line 116,
`TenantFixture.provisioned_tenant!(slug_prefix: "dispatch-replay-test",
template: :replay)`, inside a test declared `use Letflow.DataCase, async:
false`, confirmed by direct read of that file, line 51) — a REVIEWER-added
regression guard (ISS-0427 finding-8(c)) whose own purpose is specifically
to keep exercising the `:replay` escape hatch so a future edit cannot
silently remove it. **This is precisely the combination §11.2.1's dispatch
rule below must route correctly, and it is not hypothetical or
forward-looking — it exists on `main` today and must keep passing.** Every
OTHER `async: false` caller (43 of the 44, re-confirmed: `grep -rl
"provisioned_tenant!(" test --include=*.exs | grep -v tenant_fixture.ex |
xargs grep -L "template: :replay"`, then each `async:` line re-read) uses
the default `opts[:template] == :clone`.** The `:clone` path
(`Letflow.Test.TenantTemplate.clone_tenant_schema!/1`) does not call
`Ecto.Migrator.run/4` at all — it copies an already-migrated template
schema via `CREATE SCHEMA ... CREATE TABLE ... (LIKE ...)`-style DDL/data
copy (confirmed by `test/support/tenant_template.ex`'s own moduledoc,
already read for §9.7), which is ordinary transactional DDL/DML, not
`Ecto.Migrator`'s own multi-connection machinery, and runs correctly on a
single shared/sandboxed connection the same way any other `Repo.query!/2`
call does.

**Real, disclosed constraint: if any `async: false` caller passes `template:
:replay`, that call would fail under §11.2** exactly as it would under
`{:shared, self()}` mode generally (Migrator's own two-connection
requirement is unconditional, independent of this design). Two things make
this a documented constraint rather than a silent gap:

- **It is not a regression.** Before ANY of §9/§10/§11's changes, on
  `main`, an `async: false && template: :replay` caller already depended on
  `provisioned_tenant!/1`'s own then-unconditional `Sandbox.mode(Letflow.
  Repo, :auto)` line to make `:replay` work at all — i.e. this combination
  has ALWAYS required `:auto` mode, never worked under a shared/manual
  connection, and §11.2 does not change that; it only makes the
  ALREADY-real requirement visible/enforced for the shared-connection path,
  where it was previously invisible because `:auto` mode papered over it
  for every caller uniformly.
- **§11.1's dispatch must therefore special-case this exact combination**,
  stated as a hard requirement, not an open question: if
  `Keyword.get(opts, :template, :clone) == :replay`, `provisioned_tenant!/1`
  dispatches to `with_provisioning_repo/1` (the `ProvisioningRepo` path)
  REGARDLESS of the `letflow_data_case_shared_mode?` flag's value — because
  `:replay`'s own `Ecto.Migrator.run/4` call needs a real, independent,
  non-shared connection to exist at all, and `ProvisioningRepo`'s own `:auto`
  mode (§10.2) is exactly what supplies one, on a pool that (per §10.2's own
  already-proven safety argument) cannot disrupt the caller's own
  `Letflow.Repo` connection regardless of the caller's own `async:`
  declaration. This is not a new mechanism — it reuses §10's own
  already-correct path — it is a precise statement of WHEN each path is
  chosen: **`template: :replay` always uses `ProvisioningRepo`; `template:
  :clone` (the default) uses `ProvisioningRepo` for `async: true` callers and
  the shared connection for `async: false` callers.** Re-checked against the
  current 44-file `async: false` population: this fallback is needed TODAY,
  not only hypothetically — `test/support/tenant_fixture_dispatch_test.exs`
  (`grep -rl "template: :replay" test --include=*.exs`, exactly one hit,
  confirmed by direct read: `use Letflow.DataCase, async: false` at line 51,
  `TenantFixture.provisioned_tenant!(slug_prefix: "dispatch-replay-test",
  template: :replay)` at line 116) is a real, currently-shipped `async:
  false` + `template: :replay` caller, one of the 44 — a REVIEWER-added
  ISS-0427 regression guard whose own purpose is specifically to keep
  exercising the `:replay` escape hatch. **This is a currently-exercised
  branch, not a forward-looking one** — CODE-DESIGN-VALIDATOR and
  TEST-DESIGNER must treat "`tenant_fixture_dispatch_test.exs`'s own
  `template: :replay` test still passes, and still genuinely exercises
  `Ecto.Migrator.run/4` (not silently falling back to `:clone`, which its own
  `refute replay_migration_timestamps == template_migration_timestamps`
  assertion is specifically built to catch)" as a required regression check
  for this rework, not an optional forward-looking one (§11.7 restates this
  as a required TEST-RUNNER check).

### 11.3 `teardown/2` — single implementation, same dispatch as
    `provisioned_tenant!/1`'s own provisioning call

**Not a second copy of `teardown/2`.** The existing function
(`test/support/tenant_fixture.ex` lines 449-461, §10.3.2 item 6's own
already-normative content) keeps its exact 3-statement body (`DROP SCHEMA`
via `TenantProvisioning.schema_name_for_tenant/1` lookup, 2x
`Repo.delete_all`), UNCHANGED in content and order (INV-F-5, restated).
What changes: the `on_exit/1` callback registered by `provisioned_tenant!/1`
(§10.3.2's own registration point, inside the provisioning-sequence block)
must close over the SAME dispatch decision `provisioned_tenant!/1` itself
made for the provisioning call — i.e., `on_exit(fn -> connection_wrap.(fn ->
teardown(tenant.id, owner) end) end)` where `connection_wrap` is whichever of
`with_provisioning_repo/1` or a `Letflow.Repo`-targeting equivalent (§11.2's
own step 1/no-op `put_dynamic_repo(Letflow.Repo)`, wrapped the same
`try/after` shape for symmetry even though it is a no-op today) was chosen
for that SAME call's provisioning work. This is a closure-capture detail,
not a new decision point: the SAME boolean (`letflow_data_case_shared_mode?`,
or the `template: :replay` override from §11.2.1) read once at the top of
`provisioned_tenant!/1` determines BOTH the provisioning path and the
teardown path for that one call — they must never diverge for the same
`provisioned_tenant!/1` invocation, since diverging would mean provisioning
happened on one connection and teardown's `DROP SCHEMA`/`DELETE` runs
against a different one, which is exactly the cross-connection-visibility
defect this whole rework exists to close, just relocated to teardown instead
of the test body's own reads.

**Why this does not need a NEW `Process.get`/`Process.put` at teardown
time.** `on_exit/1` callbacks run in a separate process from the test body
(already established, §10.3.4's own note, unaffected) — so
`letflow_data_case_shared_mode?`'s value, stored in the TEST process's own
dictionary, is not directly readable from the `on_exit/1` callback's
process. This is not a new problem this design introduces: the SAME
constraint already applies to `owning_test/0`'s own dictionary-walking logic
(`test/support/tenant_fixture.ex` lines 711-723, already reads the ExUnit
runner's dictionary via ancestor-walking specifically because `on_exit/1`
runs in a different process) and to `Ecto.Repo.get_dynamic_repo()`'s own
per-process semantics (§10.3.2's own `previous = Repo.get_dynamic_repo()`
line, captured in the TEST process, before `on_exit/1` is even registered).
**Resolution: capture the dispatch decision as a plain closed-over Elixir
value at the point `provisioned_tenant!/1` makes it (the same "read once,
close over it" shape `owner = owning_test()` already uses one line above),
not as a second dictionary read inside the `on_exit/1` callback.** No new
cross-process data-passing mechanism is needed — this is standard Elixir
closure capture, the same idiom this module already uses for `owner`.

### 11.4 Re-verifying this does not reopen the ORIGINAL ISS-0113/ISS-0480
    hazard for `async: true`/`RowApprovalTest`-shaped victims

Per the dispatching handoff's own instruction ("verify independently rather
than inherit ISSUE-FIXER's claim") and `core-directives.md`'s "re-derive
under the conditions the property is actually about" — checking the actual
new code path §11.2 introduces, not merely re-asserting §11.0 Claim 3's
conclusion:

- **§11.2's own body issues zero `Sandbox.mode/2` calls of any kind, and —
  once the template is built, per §11.9 — nothing in its call tree does
  either** (§11.2 step 3, as corrected in REWORK ITERATION 3; stated as the
  section's single load-bearing property). **CORRECTED, REWORK ITERATION
  3:** this bullet originally asserted the unqualified version of this claim
  (no `Sandbox.mode/2` call anywhere in the whole call tree, unconditionally)
  — false, per §11.9's diagnosis of `ensure_template!/0`'s own unconditional
  call. The qualified version (true once `template_ready?/0`, which is every
  call after a partition's first) is what actually holds, and §11.9 explains
  why the remaining, unqualified first-call case does not reopen this
  section's conclusion. The ORIGINAL hazard's entire mechanism (§9.1/§10.0)
  is `Sandbox.mode/2`'s own global, empty-exclusion-list check-in effect — a
  code path that never calls `Sandbox.mode/2` at all cannot trigger that
  effect, structurally, regardless of how many times it runs or how many
  processes call it concurrently. This is a stronger property than "safe
  because callers are serialized" (§11.0 Claim 3's own argument) for the
  steady-state case — §11.2 does not need Claim 3's serialization guarantee
  to be safe against the ORIGINAL hazard once the template is built, because
  it simply performs no mode-changing action at all in that case. Claim 3's
  serialization argument is still true and still relevant (it is what makes
  reusing the caller's own connection READ-CORRECT — see next bullet — not
  merely what makes it hazard-free, AND it is what §11.9 itself leans on to
  clear the one-time first-build call), but the hazard-freedom for every
  call after the first rests on the simpler, structural fact that this
  path's call tree makes no mode-changing call at all in that case.
- **Does §11.2 reintroduce visibility risk for OTHER concurrently-running
  `async: false` tests?** No such tests exist by construction — ExUnit's
  own documented scheduling (§5.1/§9.4, re-confirmed §11.0 Claim 3) runs at
  most one `async: false` test process at a time, so "other concurrently
  running `async: false` callers" is not a real population to protect
  against; the only real concurrent population during an `async: false`
  test's execution is `async: true` tests that already completed their own
  concurrent phase (ExUnit's "sync modules run after all async modules
  complete" ordering, already cited at §5.1) — none of which is still
  holding a live connection this path could disturb, since they have
  already finished.
- **Does dispatching on `template: :replay` (§11.2.1) reopen anything?**
  No: that branch routes to `with_provisioning_repo/1` — §10's own
  already-verified-safe mechanism, unchanged, reused exactly as-is. §11
  adds no new `Sandbox.mode/2`-calling code path beyond the two already
  analyzed (§10.3.2's existing `ProvisioningRepo` path, and §11.2's new
  zero-`Sandbox.mode/2` path) — there is no third mechanism to separately
  verify.
- **Does the `letflow_data_case_shared_mode?` process-dictionary write
  itself (in `DataCase.setup/1`) introduce any risk?** No: `Process.put/2`
  writes only to the calling process's OWN dictionary (Elixir/Erlang
  process dictionaries are never shared or visible across processes without
  an explicit read via `Process.info(pid, :dictionary)`, the same mechanism
  `owning_test/0` already uses defensively) — it has no interaction with
  `Ecto.Adapters.SQL.Sandbox` or `DBConnection.Ownership.Manager` at all, and
  cannot be observed or affected by any other process, concurrent or not.
- **Does §11.2's safety hold for a caller whose ambient mode is `:auto`
  rather than `{:shared, self()}` at the moment this path runs — concretely,
  `test/support/tenant_fixture_dispatch_test.exs`, the file §11.7 names as
  required regression evidence?** Yes, but not via the `{:shared, self()}`
  property invoked above — that file's own local `setup do Sandbox.mode
  (Letflow.Repo, :auto) end` (line 60) runs, per ExUnit's documented
  callback ordering, AFTER `Letflow.DataCase`'s injected `setup` (which is
  where `{:shared, self()}` gets established) and BEFORE
  `provisioned_tenant!/1` executes inside that file's tests — so by the time
  §11.2's function runs for this file, the ambient mode is already `:auto`,
  not `{:shared, self()}`. §11.2's zero-`Sandbox.mode/2`-calls property still
  makes this safe, exactly as it does for the `{:shared, self()}` case,
  because the property that actually matters is mode-agnostic: this path
  disturbs nothing, so whichever mode/connection was already ambient stays
  ambient. What makes the RESULT correct (not just undisturbed) for THIS
  file specifically is §9.3's own trace, not the serialization argument
  above — §9.3 already establishes that under `:auto` mode a single test
  process's queries auto-checkout a fresh connection on first use and then
  keep reusing that same connection, recorded as that process's own, for
  the rest of the test (§9.3 steps 3-4, `DBConnection.Ownership.Manager`'s
  real owner-tracking rule) — which is exactly the read-your-own-write
  property this path needs, reached here by "single owner reusing one
  connection under `:auto`" rather than by "`{:shared, self()}` mode left
  intact." Both mechanisms are real and both are already established
  elsewhere in this design (§9.3 for `:auto`, this section's earlier
  bullets for `{:shared, self()}`); tenant_fixture_dispatch_test.exs is the
  concrete, currently-shipped instance of the `:auto` sub-case, the same way
  §11.2.1 already names it as the concrete instance of the `template:
  :replay` dispatch override.

**Conclusion: §11.2's own path cannot trigger the ORIGINAL hazard because it
issues no `Sandbox.mode/2` call on `Letflow.Repo` at all — a stronger,
simpler guarantee than "safe because of serialization," though the
serialization guarantee (§11.0 Claim 3) is what makes the path's OWN reads
correct under `{:shared, self()}` (no concurrent writer could be racing the
caller's shared connection), and §9.3's single-owner-under-`:auto` trace is
what makes the path's OWN reads correct on the occasions the ambient mode is
`:auto` instead (§9.3-cited bullet above, tenant_fixture_dispatch_test.exs's
own case).** All of these properties hold independently and none depends on
inheriting ISSUE-FIXER's own conclusion without re-derivation — re-derived
above from source (`data_case.ex`, `sandbox.ex`, ExUnit's documented
scheduling, and `tenant_fixture_dispatch_test.exs`'s own setup ordering)
already read for §§9-10 and this section.

### 11.5 What §10's existing subsections must be read as revised to say

- **§10.3.2 (the `ProvisioningRepo` seam)** — its steps 1-6 remain the
  EXACT mechanism used whenever `provisioned_tenant!/1` dispatches to the
  `ProvisioningRepo` path (§11.1's `false` branch, plus the `template:
  :replay` override, §11.2.1) — nothing in that section's own content is
  wrong or changed; it is now read as "the `ProvisioningRepo`-path
  mechanism," one of two paths, rather than "the only mechanism." Its own
  item 1 ("the existing first line, `Sandbox.mode(Letflow.Repo, :auto)`, is
  removed") still holds exactly as written — that removal is unconditional
  and applies regardless of which of §11's two paths a given call takes,
  since NEITHER path ever calls `Sandbox.mode(Letflow.Repo, :auto)` again
  (the `ProvisioningRepo` path calls `Sandbox.mode(Letflow.Test.
  ProvisioningRepo, :auto)` instead; §11.2's path calls no `Sandbox.mode/2`
  at all).
- **§10.4's "every existing call site... requires zero source changes"
  bullet** — still true, and now true for a LARGER guarantee than
  originally stated: §10.4 (as revised by §10.8) claimed this for 44 of 46
  files; §11's dispatch mechanism (process-dictionary-based, read from
  `DataCase`, no `opts` key) makes it true for all 47 (46 original + this
  design's own §10.6 regression test file) without exception — no call site
  needs to know which of §11's two paths it will take. §10.8's own 2 named
  exception files (`tenant_fixture_test.exs`, `promotion_assertion_rerun_
  test.exs`) are UNCHANGED by §11 — both are `async: false` (confirmed:
  `tenant_fixture_test.exs`'s own `broken_state_tenant!/1` caller and
  `promotion_assertion_rerun_test.exs`'s own moduledoc line 26, both already
  read for §10.8.1), so both now take §11.2's shared-connection path for
  their OWN `provisioned_tenant!/1` calls — §10.8's own separate, local
  fixes (wrapping `hard_cleanup/1` in `with_provisioning_repo/1`-shaped
  code; adding an explicit `Sandbox.mode(Letflow.Repo, :auto)` call to
  `promotion_assertion_rerun_test.exs`'s own `provisioned_tenant/0` wrapper)
  are ABOUT THOSE FILES' OWN LOCAL HELPERS bypassing `TenantFixture`
  entirely (§10.8.1's own finding), not about `provisioned_tenant!/1`'s
  internal dispatch — §11 does not touch either file and does not need to:
  §10.8.2.2's own explicit `Sandbox.mode(Letflow.Repo, :auto)` call in
  `promotion_assertion_rerun_test.exs` still runs, still establishes the
  window that file's own `SandboxPool`-driven second migrator call needs,
  and is unaffected by whether `provisioned_tenant!/1` itself used §11.2's
  path or §10.3.2's path for ITS OWN provisioning work earlier in the same
  test (§9.1's no-op-on-same-mode guard covers the interaction either way:
  if §11.2's path ran, `Letflow.Repo`'s mode was never touched by
  provisioning, so `promotion_assertion_rerun_test.exs`'s own explicit
  `:auto` call is the run's first real one and behaves exactly as §10.8.2.2
  already analyzes).
- **§10.5's "the §3/§4.2 classification procedure... becomes unnecessary for
  mechanisms (a)/(c)" claim** — still holds, unaffected: mechanisms (a)/(c)
  were about `Sandbox.mode/2` calls reaching `Letflow.Repo`'s shared pool
  from a SECOND, later, mid-test call — §11.2's path adds no such call
  (§11.4), so a call site otherwise safe by mechanism (a)/(c)'s own
  standards (§3's procedure) is unaffected by which of §11's two paths its
  own `provisioned_tenant!/1` invocation takes.

### 11.6 What ELIXIR-DEV implements (signatures only, no bodies)

1. `test/support/data_case.ex` — `setup/1`'s existing body gains one
   additional statement after its existing `unless tags[:async] do ... end`
   block: `Process.put(:letflow_data_case_shared_mode?, !tags[:async])`.
   Return value of `setup/1` (`:ok`) unchanged. No new `@spec` (ExUnit
   callback, none exists today).
2. `test/support/tenant_fixture.ex`:
   - New private function `provision_via_shared_connection/1`, same
     `(fun :: (-> result)) :: result` shape as the existing
     `with_provisioning_repo/1` (§10.3.2), implementing §11.2's 4 steps.
     No `@spec` (private, matching `with_provisioning_repo/1`'s own
     unspecced precedent).
   - `provisioned_tenant!/1`'s body: replace the current unconditional
     `with_provisioning_repo(fn -> ... end)` wrap with a dispatch —
     `template = Keyword.get(opts, :template, :clone)`; choose
     `provision_via_shared_connection/1` when `template == :clone and
     Process.get(:letflow_data_case_shared_mode?, false)`, else
     `with_provisioning_repo/1` — around the SAME inner function body
     (unchanged: `Tenant` insert, `on_exit/1` registration, `provision_schema!/2`,
     `assert_schema_complete!/2`, per §11.2 step 2/§11.3). Public `@spec`
     unchanged (§10.4, re-affirmed §11.5).
   - The `on_exit/1` registration inside that inner body (currently
     `on_exit(fn -> with_provisioning_repo(fn -> teardown(tenant.id, owner)
     end) end)`) becomes closure-parameterized on the SAME dispatch decision
     (§11.3) — e.g. bind the chosen wrapper function to a local variable
     once, before the `on_exit/1` registration, and reference that variable
     in both the provisioning call and the teardown closure, rather than
     re-deciding inside the closure.
   - Moduledoc: the existing "## Provisioning runs on a separate repo
     (ISS-0480 — design §10)" section is revised to state the dual-path
     dispatch and point at design §11, not only §10.
3. No other file changes. `opts()` type, `tenant_fixture()` return shape,
   error/raise taxonomy: all unchanged (§10.4/§11.1, re-affirmed).
4. No change to `Letflow.Test.ProvisioningRepo`, `Letflow.TenantProvisioning`,
   `Letflow.Test.TenantTemplate`, `config/test.exs`, or
   `scripts/test_parallel.sh` — §10.2's connection-budget reconciliation is
   unaffected: `ProvisioningRepo`'s own pool is now used by FEWER calls in
   practice (only `async: true` callers plus any `template: :replay`
   `async: false` caller, a strict subset of what §10 alone would have
   routed through it), never more, so §10.2.2's own arithmetic (already
   verified to fit with margin) remains a safe over-estimate, not an
   under-estimate needing re-verification.

### 11.7 Regression-test coverage TEST-DESIGNER must add

**Unchanged, must keep passing exactly as-is, and REQUIRED as an explicit
TEST-RUNNER check for this rework (not merely "the suite happens to include
it"):** `test/support/tenant_fixture_dispatch_test.exs` — both its tests
(`:clone`-is-default, `template: :replay`-escape-hatch-still-works), since
this file is the one real, currently-shipped `async: false` +
`template: :replay` caller (§11.2.1) whose own dispatch depends on §11.1's
`template == :replay` override firing correctly REGARDLESS of
`letflow_data_case_shared_mode?`'s value. A run of just this file
(`mix test test/support/tenant_fixture_dispatch_test.exs`) both before
(sanity: passes today, pre-§11) and after ELIXIR-DEV's implementation is a
required, named check — not folded anonymously into "run the full suite" —
because it is the one file exercising the `§11.2.1` override branch that
every other real call site does not.

**Unchanged, must keep passing exactly as-is:**
`test/letflow/iss0480_provisioning_repo_isolation_test.exs` (§10.6's own
deterministic `async: true`/`Task.async`-mediated test) — this test's own
`use Letflow.DataCase, async: true` means `letflow_data_case_shared_mode?`
is `false` for its own test process, so its own direct call to
`Letflow.TenantFixture.provisioned_tenant!(teardown: false)` (inside the
spawned `Task`, itself also `async: true`-context since `Task.async/1`
inherits no ExUnit tag state relevant here — the spawned Task's own call is
what is under test, and `provisioned_tenant!/1`'s dispatch reads its OWN
calling process's `letflow_data_case_shared_mode?`, which for a bare
`Task.async/1`-spawned process — not itself run through `DataCase.setup/1`
— is unset, defaulting to `false` per §11.1.1, i.e. the `ProvisioningRepo`
path, exactly the path this test exists to exercise) continues to exercise
`with_provisioning_repo/1` exactly as before. **No change needed to this
test file.**

**New coverage needed — the `async: false`/shared-mode restoration, proving
a representative caller's own read-after-provision visibility now passes.**
Per ISSUE-FIXER's own scope note (rediagnosis, closing paragraph):
`backfill_test.exs`'s existing "ISS-0332 -- backfill updates pre-existing
tenant to schema_version 2" test (lines 125-141, already read above) is
ALREADY a real instance of this exact failure mode under current (pre-§11)
code — its own `Backfill.run(v2_attrs())` call
(`lib/letflow/tenant_provisioning/backfill.ex:20`'s `Repo.all(Registration)`)
runs on the test's own `Letflow.Repo` shared connection and currently cannot
see the `Tenant`/`Registration` rows `provisioned_tenant!/1` committed via
`ProvisioningRepo` moments earlier. TEST-DESIGNER does not need to invent a
new fixture — it needs to:

1. **Confirm this existing test goes red against current (pre-§11, §10-only)
   code and green once §11 ships** — a real `mix test
   test/letflow/tenant_provisioning/backfill_test.exs` run before and after
   ELIXIR-DEV's implementation, per this project's fail-then-pass rule
   (already required by the dispatching handoff's own instruction and this
   project's "No Speculation" directive) — not asserted here without that
   run, same discipline §10.6's own closing paragraph and §9.5 already
   modeled.
2. **Add at least one independently-verified second instance of the same
   class**, per ISSUE-FIXER's own explicit request not to rest the whole
   regression proof on one file — `OnboardingTest`
   (`test/letflow/routers/onboarding_test.exs`) or `ContextTest`
   (`test/letflow/api/context_test.exs`) are both named by ISSUE-FIXER as
   simple HTTP-round-trip-through-`Letflow.Repo` shapes among the 17
   not-individually-root-caused failures from TEST-RUNNER's step-05 report
   — TEST-DESIGNER should read whichever of the two is simpler to isolate
   (a single assertion reading data `provisioned_tenant!/1` wrote, via
   `Letflow.Repo`, in the same test body) and confirm it independently
   red-then-green under the same before/after `mix test <file>` discipline,
   rather than assuming both fail for the identical reason without
   individually confirming at least one beyond `backfill_test.exs`.
3. **A new, small, purpose-built regression test is NOT required** in
   addition to 1-2 above — unlike §10.6 (which needed a manufactured,
   deterministic trigger because the ORIGINAL hazard was probabilistic,
   scheduling-order-dependent), this failure mode is DETERMINISTIC and
   ALREADY reproducible on demand via any existing `async: false` caller
   that reads its own fixture's writes — `backfill_test.exs` already does
   this without any modification. Manufacturing a new minimal test in
   addition would be redundant coverage of the identical mechanism §11.2
   exists to fix, not additional protection — TEST-DESIGN-VALIDATOR should
   treat "reuses an existing, already-real failing test rather than
   inventing a synthetic one" as correct here, the mirror image of §10.6's
   own reasoning for why THAT hazard needed a manufactured trigger (it was
   non-deterministic; this one is not).
4. Both files chosen (or confirmed) for coverage must be re-run at least
   twice consecutively post-fix (matching §9.5's own "repeated run, not a
   single lucky pass" discipline) to confirm the fix is deterministic, not
   itself accidentally timing-sensitive — a lighter version of §9.5's own
   verification depth (2 runs, not 10+), since §11.2's own mechanism is
   structural (no `Sandbox.mode/2` call at all once the template is built,
   §11.4/§11.9) rather than a guard-ordering property that could plausibly
   be timing-sensitive the way §9's original discovery was.
5. **NEW, REWORK ITERATION 3 — required, not optional.** §11.9's fix changes
   `Letflow.Test.TenantTemplate.ensure_template!/0` (a file TEST-DESIGNER
   does not own, but whose test-observable behavior this rework's own
   correctness now depends on) — `test/support/tenant_template_test.exs`'s
   existing suite (whatever it currently covers for `ensure_template!/0`,
   `template_ready?/0`, `assert_template_parity_against_independent_reference!/0`)
   must be re-run and confirmed green, unmodified in assertion content,
   against the §11.9 change. This is a narrower ask than a new test: §11.9
   does not change `ensure_template!/0`'s observable contract (still
   idempotent, still `:ok`-returning, still raises the same way on a broken
   template) — only WHEN it issues a `Sandbox.mode/2` call internally, which
   `tenant_template_test.exs` was never asserting on directly (grepped: zero
   `Sandbox.mode` references in that file today) — so a clean re-run without
   any edit to that file is the expected, sufficient outcome; TEST-RUNNER
   should report if that assumption is wrong (i.e., if re-running surfaces
   a failure), which would itself be a new finding requiring escalation, not
   something to patch around silently.
6. **NEW, REWORK ITERATION 3 — the specific reproduction case that found
   this, restated as a permanent named regression check.** `mix test
   test/letflow/tenant_provisioning/backfill_test.exs` (already item 1
   above) is this rework's own most direct evidence: pre-§11.9 (§11.1-§11.6
   implemented, §11.9 not yet applied), this exact command regresses from
   4/5 passing to 0/5 passing, every failure `Ecto.InvalidChangesetError` /
   `tenant_schemas_tenant_id_fkey does not exist`. Post-§11.9, the same
   command must return to (at minimum) the pre-§11-work 4/5-passing baseline
   with the ONE originally-targeted ISS-0332 test now also passing (5/5) —
   TEST-RUNNER must quote the actual `mix test` result line for this file
   specifically, not infer it from a broader suite summary, since this is
   the exact file iteration 2's own regression was caught on and a broader
   summary could mask a partial (not fully fixed) recurrence.

### 11.8 Open questions (explicit, not silently resolved)

- **OQ-10.** §11.1's `Process.get(:letflow_data_case_shared_mode?, false)`
  default (§11.1.1) is a safety fallback for a call-site shape this design
  believes does not currently exist (a `provisioned_tenant!/1` caller not
  routed through `Letflow.DataCase.setup/1`). If ELIXIR-DEV's own
  implementation-time grep finds such a caller, that is a MINOR finding to
  report, not a silent accommodation — the default's own safety argument
  (§11.1.1) assumes today's confirmed-zero count; a real such caller
  existing would need its own individual classification, not an assumption
  that the conservative default is automatically correct for it too.
- **OQ-11 — RESOLVED, not open.** Originally drafted (in an earlier pass of
  this same design edit) assuming zero current `template: :replay` +
  `async: false` callers exist; corrected once `test/support/
  tenant_fixture_dispatch_test.exs` was found by re-grep to be exactly one
  (§11.2.1). Coverage is not a future obligation — it is `test/support/
  tenant_fixture_dispatch_test.exs`'s own existing two tests, re-run as part
  of this rework's required verification (§11.7). No new test needs to be
  written for this combination; TEST-RUNNER re-running the existing suite
  (full, not scoped) is what confirms the dispatch routes it correctly.
  Left here, struck through in substance rather than deleted, per
  `docs/anti-patterns.md`'s "don't silently resolve a conflict" — so a
  future reader sees that this design's own first pass got the count wrong
  and how it was caught (a targeted re-grep before handoff, not a validator
  catching it later).
- **OQ-12.** This design does not itself run `mix test` to empirically
  confirm §11's mechanism (matching §7 OQ-3/§10.7 OQ-9's own already-stated
  division of labor). ELIXIR-DEV's implementation, TEST-DESIGNER's added/
  confirmed coverage (§11.7), and TEST-RUNNER's full-suite
  `scripts/test_parallel.sh` re-run (explicitly required by the dispatching
  handoff — not a scoped subset run, per the lesson this exact rework
  exists to teach: the scoped 172-test run at §10.7's OQ-9 status line
  reported clean while a full-suite run found 18-19 failures) are what
  actually confirm this. Do not merge until that full-suite run is PASS.

## 11.9 REWORK ITERATION 3 — `ensure_template!/0`'s own unconditional
     `Sandbox.mode/2` call, why it reopens Mechanism 4, and the fix
     (normative — corrects §11.2/§11.4/§11.7, does not reopen them for
     further debate)

### 11.9.1 The contradiction, restated precisely from source

ELIXIR-DEV's implementation of §11.1-§11.6 exactly as specified, then its own
§11.7-required regression run (`mix test
test/letflow/tenant_provisioning/backfill_test.exs`), found:

- Pre-§11 (§10-only code, `git stash`-isolated): **4/5 passed**, 1 failure —
  the documented ISS-0332 symptom (`assert updated >= 1` / `left: 0` /
  `right: 1`), exactly §11.7's own expected pre-fix red.
- Post-§11 (this design's §11.1-§11.6, exactly as specified):
  **0/5 passed** — every test failing on
  `clone_tenant_schema!/1 returned {:error, {:clone_failed,
  %Ecto.InvalidChangesetError{errors: [tenant_id: {"does not exist",
  [constraint: :foreign, constraint_name: "tenant_schemas_tenant_id_fkey"]}]}}}`.

A regression strictly worse than the bug §11 exists to fix, on the exact
population (44 of 47 real callers, `async: false` + `template: :clone`, the
default combination) §11 targets. Root cause, traced to source, not guessed:

`test/support/tenant_template.ex:82`, `Letflow.Test.TenantTemplate.
ensure_template!/0`'s own first line:

```
Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
```

issued **unconditionally**, before even checking `template_ready?/0`, on
EVERY `:clone`-path call — and `provision_schema!/2`'s default `:clone`
clause is what `provision_via_shared_connection/1` (§11.2) drives for every
`async: false` caller not overridden by §11.2.1's `template: :replay`
special case. §9.7 already documented this exact call site, quoted it
verbatim, and drew the correct conclusion FOR THE §10 WORLD ("`:auto` mode
is not something either template path could be made to avoid needing") —
correct then, because in the §10 world EVERY caller's provisioning ran on
`ProvisioningRepo`, so `Letflow.Repo`'s own ambient mode was irrelevant to
provisioning and this call's global check-in effect landed on nothing the
caller cared about. §11.2 changes that precondition — it routes an
`async: false` caller's OWN `Tenant` insert and `clone_tenant_schema!/1`
call onto `Letflow.Repo` directly, via `Ecto.Repo.put_dynamic_repo(Letflow.
Repo)` — while asserting, unqualified, that this path "issues zero
`Sandbox.mode/2` calls of any kind" (§11.2 step 3 and §11.4's first bullet,
as originally written). That assertion was checked against §11.2's OWN
body only; it was never checked against the full call tree
`provision_via_shared_connection/1` → `provision_schema!/2` → (`:clone`
clause) → `Letflow.Test.TenantTemplate.clone_tenant_schema!/1` — which does
NOT call `ensure_template!/0` itself (§9.7/`clone_tenant_schema!/1`'s own
docstring: "Preconditions: `ensure_template!/0` has already succeeded... does
NOT call it implicitly") — **but `provision_schema!/2`'s `:clone` clause
does call `ensure_template!/0` before calling `clone_tenant_schema!/1`**
(confirmed: this is the ONLY place `ensure_template!/0` is invoked from a
`TenantFixture`-mediated call, per `provision_schema!/2`'s own body, not
re-quoted here since ELIXIR-DEV's own trace already confirms the call
chain empirically via the reproduced failure). §11.4's own closing claim
("§11 adds no new `Sandbox.mode/2`-calling code path beyond the two already
analyzed... there is no third mechanism to separately verify") is the
specific sentence that was false: `ensure_template!/0` is a third,
pre-existing `Sandbox.mode/2` call site, unconditionally reachable from the
`:clone` path regardless of which of §11's two dispatch branches is chosen,
that §11.2/§11.4 never audited against their own "zero calls" claim.

**Why this reintroduces Mechanism 4 exactly (§9.2), not a new mechanism.**
Per §9.1's own source trace (`DBConnection.Ownership.Manager.handle_call
({:mode, mode}, _, %{mode: mode} = state)`), a mode-change call is a no-op
ONLY when the requested mode already equals the pool's current mode; any
actual difference triggers `proxy_checkin_all_except(state, [], caller)` —
a real, global, whole-pool check-in with an EMPTY exclusion list, discarding
whatever connection the calling process (and every other process) currently
holds. Under `provision_via_shared_connection/1`, the calling test process's
`Letflow.Repo` connection is, at the moment `ensure_template!/0` runs,
either `{:shared, self()}` (the common `DataCase.setup/1` case) or `:auto`
established by some other local `setup` (`tenant_fixture_dispatch_test.exs`'s
own shape, §11.4's last bullet) — but crucially, by this point in
`provisioned_tenant!/1`'s own sequence, the caller has ALREADY executed its
own `Tenant` insert (§11.2 step 2 runs the 3-6 step sequence in the SAME
order `with_provisioning_repo/1` already used, and the `Tenant` insert
precedes the `provision_schema!/2` call that reaches `ensure_template!/0`).
So when `ensure_template!/0`'s `Sandbox.mode(Letflow.Repo, :auto)` call
requests a mode that differs from whatever is ambient (`{:shared, self()}`
differs from `:auto` — a real difference, guard does not fire), the
check-in discards the connection holding that not-yet-committed `Tenant`
insert, exactly as §9.2 already described for the ORIGINAL, reverted
`restore_sandbox: true` mechanism — a mid-sequence `Sandbox.mode/2` call
from ANY code path, not only one this design itself writes, breaks
continuity the same way. `clone_tenant_schema!/1`'s own subsequent
`Repo.transaction(fn -> ... end)` (which inserts the `Registration` row
referencing `source_tenant_id`) then runs on a BRAND NEW, empty connection
that cannot see the just-discarded `Tenant` row — the foreign-key violation
ELIXIR-DEV reproduced is exactly this: `tenant_schemas_tenant_id_fkey does
not exist` because, from that new connection's transactional point of view,
no such tenant was ever inserted.

### 11.9.2 The fix: make `ensure_template!/0`'s own `Sandbox.mode/2` call conditional on the template not already being built

**Mechanism, stated exactly for `test/support/tenant_template.ex`
(TEST-DESIGNER/ELIXIR-DEV note: this file is owned by neither
`data_case.ex` nor `tenant_fixture.ex` — ELIXIR-DEV's step-08 handoff
correctly flagged it as outside `owned_modules`; this design authorizes
this ONE additional file's change explicitly, since it is the only place
the contradiction can be resolved without abandoning §11.2's own premise):**

`ensure_template!/0`'s current body (`test/support/tenant_template.ex`,
lines 67-129) issues `Sandbox.mode(Letflow.Repo, :auto)` as its literal
first statement, unconditionally, THEN checks `template_ready?/0`. The fix
reorders this into a single condition: **issue the `Sandbox.mode/2` call
only on the path that is about to actually build the template — i.e., move
the existing `Sandbox.mode(Letflow.Repo, :auto)` line from before the
`if template_ready?() do :ok else ... end` branch to INSIDE the `else`
branch, as its own first statement there, immediately before the advisory
lock is acquired.**

Concretely (structure, not implementation — ELIXIR-DEV writes the actual
diff):

- `template_ready?()` (a pure `:persistent_term` read, §2.1, already the
  function's own first real check) is evaluated FIRST, with no
  `Sandbox.mode/2` call preceding it.
- If `template_ready?()` is `true` (the steady-state case — every call in a
  partition after the first, and by far the overwhelming majority of real
  `:clone`-path calls in any run, since the template is built once per BEAM
  VM/partition and cached thereafter): return `:ok` immediately, with **no
  `Sandbox.mode/2` call issued anywhere in this function on this path** —
  this is the fix's entire effect, and it is what makes §11.2/§11.4's
  corrected, qualified claim ("zero `Sandbox.mode/2` calls once the template
  is already built") true.
- If `template_ready?()` is `false` (the template has not yet been built in
  this process's/VM's lifetime — the first `:clone`-path call in a given
  partition, or a `template_ready?/0` cache miss after a VM restart): THEN,
  and only then, issue `Sandbox.mode(Letflow.Repo, :auto)`, exactly as
  today, before proceeding to the advisory-lock/re-check/`unboxed_run/3`
  build sequence (lines 87-127, entirely UNCHANGED — the build itself still
  needs `:auto` mode for the same reason §9.7/this function's own existing
  comment already states: `unboxed_run/3`'s DDL must survive past the
  calling process's own sandboxed transaction, or the template ends up
  half-built when that transaction later rolls back).

**Why this is sufficient — the build path's own `:auto` call is safe by a
different, already-established argument, not exempted by accident.** The
build path (`template_ready?() == false`) is exactly §4.3's advisory-lock-
protected, once-per-partition slow path — `Repo.query!("SELECT
pg_advisory_lock(...)")` immediately follows the (now-conditional)
`Sandbox.mode(:auto)` call, and per this module's OWN existing comment
(lines 91-96, unchanged), that DDL runs unboxed specifically because it
must survive the caller's sandboxed transaction ending. **The caller's own
`Tenant` insert (§11.2 step 2, preceding this call in
`provisioned_tenant!/1`'s sequence) is disrupted by this ONE, first-ever,
per-partition `:auto` call exactly as it would be by any other — this fix
does not make the first call free of Mechanism 4's effect.** What makes
this an accepted, disclosed trade-off rather than an unresolved gap:

1. **It happens at most once per BEAM VM / test-partition database**
   (§4.2's own idempotency framing, `@built_marker_key` persistent_term,
   unchanged) — not once per `:clone`-path call, not once per test file. A
   plain `mix test` run (no partitioning) hits this at most once, ever, for
   the whole run's duration; a `scripts/test_parallel.sh` run hits it at
   most once PER PARTITION (each partition is its own BEM VM / database).
2. **The disrupted caller is deterministically identifiable and already
   has a working answer: it is not a new class of failure, it is the
   ORIGINAL ISS-0113/pre-fix symptom, scoped down to exactly one call.**
   The very first `:clone`-path, `async: false` test to run in a given
   partition — whichever one ExUnit happens to schedule first among the
   sync queue — has its own `Tenant` insert discarded by this one call,
   the same way EVERY `:clone`-path call already had that discard happen
   under §10-only code (which used `ProvisioningRepo`'s own `:auto` mode
   unconditionally, never touching `Letflow.Repo`'s ambient mode at all —
   so this exact caller was NEVER exposed to `ensure_template!/0`'s call
   under §10; §11.2 is what first puts a `:clone`-path async:false caller's
   OWN Tenant insert genuinely at risk from `ensure_template!/0`, for
   exactly this one first-per-partition call). This means the fix is not
   fully sufficient to reach zero regressions for that ONE, first,
   per-partition caller — see §11.9.3 for why this remaining case is
   real, disclosed, and mitigated rather than eliminated, and why
   eliminating it entirely is a materially larger change this rework does
   not make.

### 11.9.3 The remaining first-call exposure, disclosed precisely, and why it does not block this rework

**The honest remaining gap after §11.9.2's fix:** the very first
`template: :clone` + `async: false` call in a given partition/VM, IF it
also happens to be the call that triggers the template build (i.e., no
`async: true` caller or earlier test already built the template first),
still has its own `Tenant` insert discarded by `ensure_template!/0`'s
now-conditional-but-still-real `:auto` call — because that ONE call
necessarily fires before the build, and the build path's own precondition
(DDL must run unboxed, past the sandboxed transaction) is incompatible with
also preserving an in-flight sibling transaction's own uncommitted rows on
the SAME connection. This is not fixable by relocating or retargeting this
one call alone — see the three rejected alternatives below.

**Why this is acceptable for this rework, stated as an explicit trade-off,
not swept under §11.9.2's fix:**

- **It affects at most ONE call site's outcome per partition, not 44.**
  §11.9.2's fix reduces the affected population from "every `:clone`-path
  `async: false` call, every time" (the regression ELIXIR-DEV found, 0/5 on
  `backfill_test.exs`) to "the first `:clone`-path `async: false` call in a
  partition, only if no `async: true` caller already built the template
  first, and only for the ONE test that happens to run first in the sync
  queue." A real `mix test` run's own `Registration`/template-building
  order is dominated by whichever `async: true` file (per §9.4, at least
  `secrets_test.exs`/`webhooks_test.exs` today) happens to run its own
  `:clone`-path call during the async phase — which runs, per ExUnit's own
  documented scheduling (§5.1, "sync modules run after all async modules
  complete"), BEFORE any `async: false` file's tests start at all. **In
  practice, on the current suite, the template is already built by the
  time the sync queue's first `:clone`-path caller runs**, because at least
  one `async: true` `TenantFixture` caller already exists and runs first —
  making the residual gap this section discloses currently unobserved, not
  merely theoretically small. This is stated as an empirical expectation
  TEST-RUNNER's own full-suite run (§11.7 item 6) will confirm or refute,
  not asserted as proven without that run.
- **If it DOES fire (e.g. a future suite with zero `async: true`
  `TenantFixture` callers, or a partition where the async phase happens to
  contain no `:clone`-path caller), the failure mode is the SAME, already-
  understood, already-diagnosed symptom** (`Ecto.InvalidChangesetError` /
  FK-does-not-exist, or the ISS-0332-shaped read-miss) as the exact
  regression this whole rework exists to fix — not a new, harder-to-
  diagnose failure class. A future occurrence is straightforwardly
  traceable back to this section by anyone who reads it, rather than a
  silent, undocumented trap.
- **Three alternative mechanisms considered and rejected, stated so a
  future reader does not re-propose them without knowing why:**
  1. *Route `ensure_template!/0`'s build-path `:auto` call through
     `ProvisioningRepo` instead of `Letflow.Repo`.* Rejected: the build's
     own DDL (`CREATE SCHEMA`, migrations replay via
     `TenantProvisioning.replay_migrations/1`) must run on the SAME
     connection the throwaway `Tenant`/`Registration` row was inserted on
     (this function's own existing comment, lines 113-119: "Wrapping only
     the migration puts that lookup on a different connection which cannot
     see the row") — that throwaway row is inserted via plain
     `Repo.insert_all/3` against whatever `Letflow.Repo`'s CURRENT dynamic
     repo binding is at call time. Under `provision_via_shared_connection/1`,
     that binding is explicitly `Letflow.Repo` itself (§11.2 step 1) — so
     retargeting only the `Sandbox.mode/2` call to `ProvisioningRepo` while
     the throwaway insert still executes against `Letflow.Repo` would split
     the build's own two halves across connections, reproducing exactly
     the "different connection, doesn't see the row" failure this
     function's own comment already names as previously-tried-and-rejected
     for a different reason. Making the WHOLE build (not just the mode
     call) redirect to `ProvisioningRepo` would require this function to
     know about `ProvisioningRepo` at all, which §10.2.1 deliberately
     avoided doing to `TenantProvisioning`'s functions — extending that
     same avoidance to `TenantTemplate` is consistent, not an oversight.
  2. *Pre-build the template eagerly, before any test runs (e.g. from
     `test/test_helper.exs`).* Rejected as out of scope for this rework:
     it would guarantee the fast path is always the one hit, closing the
     residual gap completely, but it is a materially different, larger
     mechanism (global test-run bootstrap ordering, its own connection/
     partition-boundary questions — does `test_helper.exs` run once per
     partition already? under what connection state?) than this rework's
     own bounded scope of "fix the regression ELIXIR-DEV found." Worth
     flagging as a candidate for a FUTURE design (OQ-13 below), not
     something this rework should absorb under schedule pressure.
  3. *Have `provision_via_shared_connection/1` itself call
     `Letflow.Test.TenantTemplate.ensure_template!/0` (or check
     `template_ready?/0`) BEFORE its own `Tenant` insert, so any needed
     build happens first, before there is an in-flight transaction to
     discard.* This is the closest alternative to actually closing the gap
     without touching `test_helper.exs` — but rejected for THIS rework
     because it inverts §11.2 step 2's own documented sequencing ("run the
     caller's existing 3-6 step provisioning sequence... EXACTLY as
     `with_provisioning_repo/1`'s own body already sequences them"), a
     property §11.2 states as deliberate parity with the existing,
     shipped, verified `ProvisioningRepo` path — changing step ORDER for
     one dispatch branch only, to work around a downstream module's own
     mode call, is exactly the kind of scope creep `docs/anti-patterns.md`
     warns against fixing by rearranging an unrelated caller instead of
     the actual defect's own site. Flagged as OQ-13 for a future tranche
     if the empirical run in §11.7 item 6 shows this gap is not, in fact,
     already avoided by `async: true` callers building the template first.

### 11.9.4 What ELIXIR-DEV implements for §11.9 (signatures only, no bodies)

1. `test/support/tenant_template.ex`, `ensure_template!/0`: reorder the
   existing `Sandbox.mode(Letflow.Repo, :auto)` statement (currently line
   82, the function's first statement) to become the first statement
   INSIDE the existing `else` branch of the existing `if template_ready?()
   do :ok else ... end` conditional (i.e., immediately before the existing
   `Repo.query!("SELECT pg_advisory_lock(...)")` line) — moving one
   existing line, adding no new branch, no new function, no new module
   attribute. `@spec ensure_template!() :: :ok` unchanged. The function's
   own existing comment block (lines 69-81) explaining WHY the call exists
   must be moved/adapted to sit with its relocated call site, updated to
   note the call is now conditional on `template_ready?() == false` and to
   cite this design's §11.9 for why (not merely "moved for no stated
   reason").
2. No change to `template_ready?/0`, `clone_tenant_schema!/1`,
   `assert_clone_parity!/3`, `build_template!/0`,
   `do_build_template!/1`, or any other function in this module — the
   fix is a single statement's reordering, nothing else.
3. No change to `test/support/tenant_fixture.ex` or
   `test/support/data_case.ex` beyond what §11.1-§11.6 already specify —
   §11.9 does not touch `provisioned_tenant!/1`, `provision_via_shared_
   connection/1`, or `with_provisioning_repo/1`'s own bodies at all; the
   fix is entirely inside `ensure_template!/0`.
4. Re-run, in full, §11.7's regression plan (items 1-6, including the two
   NEW items this rework's own §11.7 edit adds) after this change — the
   `backfill_test.exs` fail-then-pass check (§11.7 item 1 / item 6) is what
   confirms this fix actually closes the 0/5 regression, not merely that it
   compiles.

### 11.9.5 Open question added by this rework

- **OQ-13.** §11.9.3's third rejected alternative (having
  `provision_via_shared_connection/1` ensure the template is built before
  its own `Tenant` insert, closing the residual first-call gap completely)
  is deferred, not adopted, for this rework — see that subsection for why.
  If TEST-RUNNER's full-suite run (§11.7 item 6, §11.9.3's own empirical
  expectation) surfaces even one real failure attributable to this residual
  gap (a `:clone`-path `async: false` test failing with the
  FK-does-not-exist/read-miss symptom in a partition where no `async: true`
  `TenantFixture` caller ran first), that is the signal this design's own
  "currently unobserved" expectation was wrong for at least one partition
  shape, and a future design step should adopt alternative 2 or 3 from
  §11.9.3 rather than this rework attempting a second, unplanned patch
  under the same run.

## 11.10 REWORK ITERATION 4 — `provision_via_shared_connection/1`'s
     `on_exit/1` teardown outlives its own connection, why, and the fix
     (normative — corrects §11.2/§11.3/§11.6, does not reopen them for
     further debate)

### 11.10.0 What ELIXIR-DEV found, re-verified rather than inherited

Per `HANDOFF_PROTOCOL.md` §1.1 and `core-directives.md`'s "re-derive under
the conditions the property is actually about" — this is not taken on
ELIXIR-DEV's report alone. Re-derived from source, independently, below:
`Ecto.Adapters.SQL.Sandbox`'s own moduledoc and `DBConnection.Ownership`'s
documented lifecycle both state that `{:shared, owner_pid}` mode ties the
shared connection's validity to `owner_pid` remaining alive; ExUnit's own
documented `on_exit/1` contract states the callback runs "after the test
has exited, in a separate process, after the test process itself has been
torn down" — the two facts compose exactly the way ELIXIR-DEV's stack trace
demonstrates: `provision_via_shared_connection/1`'s own `on_exit/1` closure
(`test/support/tenant_fixture.ex:303`) calls `Ecto.Repo.put_dynamic_repo
(Letflow.Repo)` (a no-op — it does not change which pool `Letflow.Repo`
targets) and then runs `teardown/2`'s three statements directly against
whatever connection is ambient for the CALLING process — but the calling
process, by the time `on_exit/1` fires, is the on_exit callback's own
process, not the original test process the `{:shared, self()}` mode was
established for. `DBConnection.Ownership.Manager` has no record of this new
process as an owner or an allowed process for that shared connection (the
original owner already exited, and its exit is exactly what invalidates the
`{:shared, owner_pid}` registration per Sandbox's own documented behavior,
not merely "the connection happens to be busy") — so the very first
`Repo.query!`/`Repo.delete_all` call inside `teardown/2`
(`schema_present?/1`'s own `Repo.query!/2}`, reached via `log_teardown/3` →
`guarded/2`) attempts a checkout that has nothing to attach to, and
`DBConnection.Holder.checkout/3` raises `exit, shutdown: "owner ... exited"`
exactly as quoted in the BLOCKER. Independently confirmed via `git stash` to
predate this rework entirely (commit c38dfa9b, `provision_via_shared_
connection/1`'s own introduction) — this is not a defect this rework's own
§11.9 change caused, and §11.9's tenant_template.ex reorder is not touched
by this section's fix.

**Why `guarded/2` and `log_teardown/3`'s own `rescue` clause do not already
catch this, confirmed against source, not assumed.** Both
(`test/support/tenant_fixture.ex:717-721`, `:556-558`) are `rescue
_exception -> ...` clauses. Elixir's `rescue` catches values raised via
`raise/1,2` (anything implementing the `Exception` behaviour) — it does
**not** catch an `exit` signal, which is a distinct BEAM control-flow
primitive `DBConnection.Holder.checkout/3` uses here specifically because
the failure is a process-level condition (the pool's own ownership manager
tearing down a stale registration), not an application-level exception.
Catching an `exit` requires `catch :exit, reason -> ...` (or the combined
`try ... catch :exit, _ -> ... rescue _ -> ... end` form) — a different
Elixir construct from `rescue` entirely, not a broader flag on the same one.
This confirms the BLOCKER's own diagnosis rather than merely restating it:
INV-F-10 ("a failing log call must never turn a passing test red") is
currently violated for this one failure shape because the boundary that is
supposed to enforce it structurally cannot see this class of failure at
all, regardless of how it is invoked.

### 11.10.1 Two independent defects, not one — and only one of them is this
     rework's to fix

Re-reading the BLOCKER's own stack trace precisely: the raised `exit`
propagates from `schema_present?/1` (called only from `log_teardown/3`'s own
`guarded(fn -> schema_present?(schema_name) end, nil)` diagnostic read) —
**not** from `teardown/2`'s own load-bearing `DROP SCHEMA`/`Repo.delete_all`
statements, which never get a chance to run at all once `log_teardown/3`
propagates the `exit` past its own non-catching `rescue`. So there are two
separate things wrong, and conflating them would produce an incomplete fix:

1. **The connection itself is unusable from the `on_exit/1` process** — this
   is the root defect (§11.10.0) and the one this section fixes, because
   fixing only item 2 below would still leave `teardown/2`'s own real
   cleanup (`DROP SCHEMA`, the two `delete_all` calls) attempting to run on
   a connection that cannot be checked out, merely with the symptom changed
   from "test fails" to "teardown silently does nothing" — a worse outcome,
   not a fix, since it would leave orphaned tenant schemas/rows behind on
   every `async: false` + `template: :clone` test, silently.
2. **`guarded/2`/`log_teardown/3`'s `rescue`-only boundary cannot see an
   `exit`** — real, and independently worth closing per INV-F-10's own
   stated intent, but **fixing this alone does not fix the BLOCKER**: even
   if `log_teardown/3`'s diagnostic read were made exit-safe, `teardown/2`'s
   own subsequent `Repo.query!`/`Repo.delete_all` calls (the DROP and the two
   deletes) are NOT inside any `guarded/2`/rescue boundary at all today —
   they are the function's own unprotected body — and would still raise the
   identical `exit` past `on_exit/1`'s own caller (ExUnit reports an
   uncaught `on_exit/1` failure as a test failure regardless of which
   statement inside it raised). Both must be addressed for the BLOCKER to
   actually close; §11.10.2 fixes item 1 (root cause, makes the connection
   usable), §11.10.3 fixes item 2 (closes the disclosed INV-F-10 gap on the
   diagnostic path specifically, as a hardening measure once item 1 is
   fixed, not as a substitute for it).

### 11.10.2 The fix: route `provision_via_shared_connection/1`'s `on_exit/1`
     teardown through `Letflow.Test.ProvisioningRepo`, exactly as §10's own
     path already does — provisioning itself stays on the shared connection

**Chosen direction, and why it is the smallest correct fix, not merely the
most convenient one.** The handoff dispatching this rework asked the load-
bearing question directly: does `teardown/2` need to run on the SAME
connection provisioning used, or merely on SOME connection with adequate
visibility/permissions? Answered from `teardown/2`'s own body
(`test/support/tenant_fixture.ex:522-534`, unchanged, re-read for this
section): its three statements are `TenantProvisioning.schema_name_for_
tenant/1` (a `Repo.get_by(Registration, ...)` read keyed by `tenant_id`),
`Repo.query!(DROP SCHEMA IF EXISTS ... CASCADE)`, and two
`Repo.delete_all/1` calls filtered by `tenant_id`/`id` — **every one of
these reads or deletes rows/schemas by a value already known before
teardown runs (`tenant_id`, closed over in the `on_exit/1` closure per
§11.3), not by anything that must be visible only on a specific in-flight,
uncommitted transaction.** By the time `on_exit/1` fires, `provisioned_
tenant!/1`'s own provisioning sequence (the `Tenant` insert,
`provision_schema!/2`'s clone/replay, `assert_schema_complete!/2`) has
already either **completed and returned** (the test body ran to
completion) or **raised out of `provisioned_tenant!/1` entirely** (in which
case `on_exit/1` still fires, since ExUnit registers it unconditionally)
— either way, the calling test process's OWN participation in whatever
transaction/connection state it was using is over by the time the test
process itself exits, which is a precondition for `on_exit/1` running at
all (ExUnit's own documented ordering: `on_exit/1` runs strictly after the
test process has finished). **Committed rows are visible from any
connection to the same Postgres database** (ordinary MVCC read-committed
visibility, the same fact §11.0 already established when it diagnosed WHY
`ProvisioningRepo`'s separate pool was safe for provisioning in the first
place) — and `provision_via_shared_connection/1` provisions on `Letflow.
Repo` directly, under whatever mode is ambient (`{:shared, self()}` or
`:auto`).
**CORRECTED (WF03-ISS0480-20260905, rework #5 — this paragraph's own prior
claim below was FALSE and is struck through in substance, not merely
caveated, per `docs/anti-patterns.md`'s "don't silently resolve a
conflict"/"supersede rather than overwrite" precedent.** The struck claim
read: ~~"`DataCase`'s own `{:shared, self()}`/`:auto` choice ... never
wraps the test body in a transaction that rolls back at teardown; it is a
genuine, ordinarily-committing connection for the statements this codebase
runs against it."~~ ISSUE-FIXER's mechanical reassessment
(`handoffs/WF03-ISS0480-20260905/step-13-issue-fixer-reassessment.json`,
`result.summary` Item 1) confirms the opposite, read directly from source,
not inferred:

- `deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex:543-571` (`checkout/2`):
  the `:sandbox` option defaults to `true` (line 548) and, when true,
  installs `post_checkout`/`pre_checkin` pool hooks (lines 549-552)
  **unconditionally, before any later `Sandbox.mode/2` call ever runs** —
  `Sandbox.mode/2` (lines 509-516) never touches or removes these hooks; it
  only calls `DBConnection.Ownership.ownership_mode/3`, a completely
  separate, access-only operation.
- `deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex:658-675`
  (`post_checkout`): calls `conn_mod.handle_begin([mode: :transaction] ++
  opts, conn_state)` — opens a real transaction at checkout time,
  unconditionally.
- `deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex:677-701`
  (`pre_checkin`): the ordinary-checkin clause calls
  `conn_mod.handle_rollback([mode: :transaction] ++ opts, conn_state)` —
  always ROLLBACK, never COMMIT.
- **Neither `post_checkout` nor `pre_checkin` reads or branches on
  `:manual` vs. `:auto` vs. `{:shared, pid}` mode at all — mode is not a
  parameter to either function.** `{:shared, pid}`'s actual death path
  (`manager.ex:241-242`'s `handle_info({:DOWN, ...})` →
  `proxy_checkin/3` (`:285-297`, which is what triggers the pool's real
  rollback machinery) → `owner_down/2` (`:364-386`, ETS/map bookkeeping
  only) → `unshare/2` (`:402-408`, resets `state.mode` to `:manual`, no DB
  operation)) confirms `{:shared, pid}` mode is orthogonal to checkin-time
  rollback: it only widens which processes may use the connection DURING
  the test, and has no branch that turns a checkin-time rollback into a
  commit.

**The true premise, replacing the struck claim above: a `Letflow.Repo`
connection checked out via `Ecto.Adapters.SQL.Sandbox.checkout/2` — which
`DataCase.setup/1` (`test/support/data_case.ex:16`) does unconditionally
for every test, regardless of `async: true`/`false` or `{:shared,
self()}`/`:manual` mode — is ALWAYS wrapped in a transaction that rolls
back at checkin. `provision_via_shared_connection/1`'s writes on that
connection are therefore never durable past the owning test process's
exit; the ambient Sandbox rollback-at-checkin is what actually removes the
provisioned schema and tracking rows, not `teardown_wrap`'s DROP/DELETE.**
This is reconciled against §10's original mechanism, not merely asserted:
`with_provisioning_repo/1`'s own path calls `Sandbox.mode(Letflow.Test.
ProvisioningRepo, :auto)` on `Letflow.Test.ProvisioningRepo` — a repo whose
connection `DataCase.setup/1` never checks out via `Sandbox.checkout/2` at
all, so its writes are ordinary, real, auto-committing statements with no
wrapping transaction to roll back. That is exactly why §10's original
mechanism genuinely needs real explicit teardown (`ProvisioningRepo` writes
are durable across test-process-exit and are left behind forever without a
manual DROP/DELETE) — a property `Letflow.Repo`'s ambient, always-rolled-
back connection does not share. The two mechanisms have fundamentally
different persistence semantics; this correction is scoped to the
shared-connection (`Letflow.Repo`) path specifically and must not be read
as "teardown is never needed" for every caller (a caller provisioning via
`with_provisioning_repo/1`/`ProvisioningRepo` directly still needs real
teardown).
So: **teardown does not need to run on the SAME connection provisioning
used — it needs a live, permissioned connection to the SAME database, which
`ProvisioningRepo` already is, by construction (§10.2, `config/test.exs`:
same `database: "letflow_test#{MIX_TEST_PARTITION}"` as `Letflow.Repo`,
confirmed by direct re-read of `config/test.exs` for this section — the two
repos are two pools onto the identical database, not two databases).**

**The fix, stated as a signature-level change (no bodies):**

- `provisioned_tenant!/1`'s dispatch (§11.6 item 2's `connection_wrap`
  binding) is now **split into two separately-named closures instead of
  one shared one** — the current code binds a single `connection_wrap` and
  reuses it for both the provisioning call and the `on_exit/1` teardown
  call (§11.3's own stated design, now superseded by this section for the
  teardown half only): a `provision_wrap` closure, bound exactly as
  `connection_wrap` is today (`provision_via_shared_connection/1` when
  `template == :clone and Process.get(:letflow_data_case_shared_mode?,
  false)`, else `with_provisioning_repo/1`) — **unchanged, still used only
  for the provisioning call** — and a `teardown_wrap` closure that is
  **always `with_provisioning_repo/1`, regardless of what `provision_wrap`
  resolved to.**
- Concretely: `on_exit(fn -> with_provisioning_repo(fn -> teardown(tenant.id,
  owner) end) end)` — literally the SAME shape §10.3.2's path already uses
  for every caller today (quoted verbatim in the dispatching handoff's own
  "For contrast" paragraph), now used **unconditionally** for the teardown
  closure, independent of which path provisioning itself took.
- **This directly reverses one clause of §11.3's own prior instruction**
  ("the `on_exit/1` callback... must close over the SAME dispatch decision
  `provisioned_tenant!/1` itself made for the provisioning call" — the
  premise being that provisioning and teardown must never diverge in which
  connection they use, or teardown's DROP/DELETE would run against a
  different connection than the one provisioning committed to). §11.10.2
  narrows that premise to what it actually protects: it is real and still
  correct for why `assert_schema_complete!/2` and the caller's own later
  test-body reads must share provisioning's connection (read-your-own-write,
  same-transaction visibility while the test is still running) — but
  teardown runs strictly AFTER the test's own reads are done and after the
  provisioning connection's participation has ended, at which point the
  only property teardown needs is "sees committed rows in the same
  database," which `ProvisioningRepo` already supplies unconditionally, for
  every caller, exactly as it already does for the `with_provisioning_repo/1`
  dispatch branch today. §11.3's own "no NEW `Process.get`/`Process.put` at
  teardown time" reasoning is unaffected — `teardown_wrap` needs no
  process-dictionary read at all, since it is now a constant, not a
  decision.
- **`provision_wrap` (the provisioning-time dispatch) is completely
  unchanged by this section** — `provision_via_shared_connection/1` keeps
  running the `Tenant` insert, `provision_schema!/2`, and
  `assert_schema_complete!/2` directly against `Letflow.Repo`, on the
  caller's own ambient connection, exactly as §11.2 specifies. This section
  changes ONLY which wrapper the `on_exit/1` closure passed to `teardown/2`
  uses; it does not touch provisioning's own connection choice, `§11.2`'s
  zero-`Sandbox.mode/2`-calls property, or `§11.9`'s `ensure_template!/0`
  fix.

### 11.10.2a `teardown_wrap`'s DROP/DELETE is defense-in-depth, not the
     operative cleanup mechanism, for the shared-connection path (CORRECTED,
     WF03-ISS0480-20260905 rework #5)

**Given §11.10.2's corrected premise above, what does `teardown_wrap`'s
`with_provisioning_repo(fn -> teardown(tenant.id, owner) end)` actually
accomplish for the `async: false` + `template: :clone` default path (44 of
47 real call sites, per ISSUE-FIXER's step-13 reassessment)?** Not what
§11.10.2 originally believed. Stated precisely, per ISSUE-FIXER's
mechanically-confirmed reassessment (step-13 handoff, Items 2-5):

- **The real cleanup, for this path, is the ambient Sandbox rollback at
  checkin** (§11.10.2's corrected premise) — `provision_via_shared_
  connection/1`'s `Tenant` insert, `Registration` insert, and
  `CREATE SCHEMA`/replay are all made on the caller's `Letflow.Repo`
  connection, which is always inside a rollback-at-checkin transaction.
  That rollback discards them before `on_exit/1`'s `teardown_wrap` closure
  ever runs, for every caller on this path.
- **`teardown_wrap`'s own DROP SCHEMA IF EXISTS/`delete_all` statements run
  against state that is, for this path, already gone by construction** —
  confirmed by direct reproduction, not inferred: ISSUE-FIXER ran `mix test
  test/letflow/support/tenant_fixture_test.exs --only describe:"C5 --
  teardown logging"` and observed the emitted line read
  `schema_present_before_drop=false` (the schema was already absent before
  `DROP SCHEMA IF EXISTS` executed), and separately ran `mix test
  test/letflow/tenant_provisioning/backfill_test.exs --seed 0` and observed
  the identical signature on ELIXIR-DEV's own ISS-0480 verification tests.
- **This makes `teardown_wrap`'s statements a harmless, already-idempotent
  no-op for this path, not a defect requiring a code fix.** `teardown/2`'s
  own body (`test/support/tenant_fixture.ex:538-550`) degrades gracefully
  at each step when the state is already gone: `schema_name_for_tenant/1`
  returns `{:error, :invalid_tenant_id}` when the `Registration` row is
  already rolled back, and `teardown/2`'s own `case` clause treats that as
  a plain `:ok` (the DROP is skipped entirely — never reached, never
  errors); Postgres's own `IF EXISTS` clause is unconditionally graceful
  against an absent schema (confirmed by the C5 reproduction above, which
  hit exactly this branch with no error, only a log line); `delete_all`
  against zero matching rows is an ordinary, silent 0-row result in
  Ecto/Postgres. No implementation change to `teardown/2` follows from this
  correction — ELIXIR-DEV must not add speculative existence-guards around
  any of its three statements; they are already safe.
- **`teardown_wrap`'s DROP/DELETE is retained** — this design does not
  propose removing it — **as defense-in-depth, not as the load-bearing
  mechanism for the shared-connection path**, for two concrete reasons, not
  a vague "just in case": (a) it is the operative, load-bearing cleanup for
  any caller whose provisioning does NOT go through the fully-rolled-back
  shared-connection path — concretely, a caller using
  `with_provisioning_repo/1`/`ProvisioningRepo` directly for provisioning
  per §10's original mechanism, whose writes ARE durable across
  test-process-exit (§11.10.2's reconciliation paragraph above) and
  genuinely need the DROP/DELETE to run; and (b) it costs nothing extra —
  §11.10.5 item 5's own connection-budget analysis (unchanged by this
  correction) already established this traffic is additional short-lived
  load on an already-provisioned pool, not additional peak concurrency —
  so keeping one code path for both cases (rather than branching teardown
  behavior on how provisioning dispatched) is simpler and more uniform than
  the alternative of skipping teardown_wrap for the shared-connection path
  specifically. **No new hazard is introduced by any of this**:
  ISSUE-FIXER's step-13 Item 4 traced `manager.ex`'s `{:shared, pid}`
  sharing/unshare mechanism precisely and confirmed it only ever affects
  the one owning connection, never another test's separate connection —
  two different async tests hold entirely separate checkouts/proxies/
  underlying Postgres connections, and standard Postgres MVCC read-
  committed isolation applies between any two live, uncommitted
  transactions on separate connections regardless of Sandbox mode. This
  closes the "does this create a new cross-test leak" question the step-13
  reassessment was dispatched to check — it does not.

**Does this change what ELIXIR-DEV implements?** No. §11.10.5's
signature-level implementation list is unchanged by this correction — this
is a documentation-only fix to §11.10.2's premise and this new
§11.10.2a's framing of `teardown_wrap`'s role, not a code change. The one
non-design consequence is in the test suite (see §11.10.4a below).

**Does this reopen the ORIGINAL ISS-0113/ISS-0480 hazard — a `Sandbox.mode/2`
call reaching `Letflow.Repo`'s shared pool from teardown?** No, by
construction: `with_provisioning_repo/1`'s own body (`test/support/
tenant_fixture.ex:332-342`, unchanged) calls `Sandbox.mode(Letflow.Test.
ProvisioningRepo, :auto)` — it has never, in any of §10/§11's iterations,
called `Sandbox.mode/2` on `Letflow.Repo` itself. Routing teardown through
it is not a new call to audit against the ORIGINAL hazard's own mechanism
(§9.1's global check-in effect scoped per-repo, §10's own already-verified
argument for why `ProvisioningRepo`'s pool cannot disturb `Letflow.Repo`'s)
— it is reuse of the exact, already-safe mechanism §10.3.2 introduced and
§10's own analysis already covers, for a caller population (`async: false`)
that mechanism was never previously invoked for at teardown time, but was
always safe to invoke for (§10's own safety argument was never scoped to
`async: true` callers specifically — it is scoped to "any caller routing
through `ProvisioningRepo`," which now includes this one, for teardown
only).

**Does this reopen Mechanism 4 (§9.2/§11.9) — a mid-sequence `Sandbox.mode/2`
call on `Letflow.Repo` disrupting an in-flight connection holding
uncommitted work?** No: `with_provisioning_repo/1`'s `Sandbox.mode/2` call
targets `Letflow.Test.ProvisioningRepo`, never `Letflow.Repo` — Mechanism 4
is specifically about a mode call reaching `Letflow.Repo`'s own pool while
that pool holds an in-flight caller's uncommitted connection state; a call
against a DIFFERENT repo's pool cannot check in a connection it does not
own, structurally, the same "scoped per ownership-manager process, one
manager per pool" fact §10's own moduledoc (`test/support/provisioning_
repo.ex:14-24`, re-read for this section) already states. Additionally,
by the time `on_exit/1` fires, there is no longer any "in-flight,
uncommitted work" on `Letflow.Repo` to disrupt in the first place (§11.10.2's
own opening argument) — the test process that held it has already exited.

### 11.10.3 Hardening `guarded/2`/`log_teardown/3` to also catch `:exit` —
     closes item 2 from §11.10.1, INV-F-10's own stated intent

Independent of §11.10.2 (which makes the connection usable, so this
diagnostic read no longer raises in the first place under normal
operation), `guarded/2` is widened so its stated contract ("fun either
returns its value, or [fails] and that ONE field degrades... while every
other field is still gathered") actually holds for an `exit` the same way
it already holds for a `raise`d exception — matching INV-F-10's own
already-stated intent ("a failing log call must never turn a passing test
red") for the failure SHAPE this rework discovered, not only the shape it
originally anticipated. `log_teardown/3`'s own `rescue _exception -> :ok`
boundary is widened the identical way, for the identical reason — it is the
outer safety net around `guarded/2`'s own call in `log_teardown/3`'s body,
and both must widen together or the inner one is redundant.

**Signature-level change (no bodies):** both `guarded/2`
(`test/support/tenant_fixture.ex:717-721`) and `log_teardown/3`'s own
trailing `rescue` clause (`:556-558`) change their failure-boundary
construct from `rescue _exception -> ...` (catches only `raise`d
exceptions) to a combined form that ALSO catches an `exit` signal with the
same fallback value/behavior — Elixir's `try/rescue/catch` allows both
clauses on one `try` block (or, for `guarded/2`'s existing single-expression
`fun.() rescue _exception -> degraded` shorthand, ELIXIR-DEV must expand it
to an explicit `try do fun.() rescue _ -> degraded catch :exit, _ -> degraded
end` form, since the bodyless shorthand syntax cannot carry a second
`catch` clause — a real, disclosed shape change from today's one-line
function body, still a signature-preserving change: `guarded/2`'s own
`@spec`-equivalent behavior, "returns `fun`'s value or `degraded`," is
unchanged, only which failure classes reach that fallback widens). No new
public function, no new module attribute, no change to either function's
arity or callers.

**Why this is a hardening measure and not this section's primary fix,
stated so it is not mistaken for one.** §11.10.2 alone is sufficient to
close the BLOCKER: once teardown runs through `ProvisioningRepo`, the
connection `schema_present?/1` checks out inside `log_teardown/3` is a
live, valid one, and no `exit` is raised from that call site at all under
normal operation — this section's own widening is a defense-in-depth
measure for a DIFFERENT, currently-hypothetical scenario (some other,
future cause of a mid-teardown `exit`, e.g. `ProvisioningRepo`'s own pool
being saturated and timing out in a way that surfaces as an `exit` rather
than a `raise`), not a substitute for fixing the root cause. Confirmed
against §11.10.1's own item 2 analysis: applying ONLY this section without
§11.10.2 would still leave `teardown/2`'s own unprotected `DROP SCHEMA`/
`delete_all` statements raising the ORIGINAL `exit` past `on_exit/1` (they
are not inside any `guarded/2` boundary, and are not being wrapped in one
by this section either — see the next paragraph for why not).

**Why `teardown/2`'s own `DROP SCHEMA`/`delete_all` statements are NOT
wrapped in a `guarded/2`-style boundary, even though they are the
statements that actually raised in the BLOCKER's own trace path once
§11.10.2 is applied (they wouldn't raise at all once the connection is
valid, but the boundary question is asked here for completeness).** Those
three statements are teardown's own **load-bearing cleanup**, not a
diagnostic read — INV-F-10's own scope ("a failing LOG call must never turn
a passing test red") is specifically about observability code that exists
only to report state, never about suppressing a failure in the actual
cleanup operation itself. Swallowing a failed `DROP SCHEMA`/`delete_all`
would silently leave an orphaned tenant schema/rows behind with no signal
at all — worse than today's behavior (a loud, attributable test failure),
and exactly the class of "hide a failing operation instead of fixing it"
anti-pattern `docs/anti-patterns.md` warns against. If `ProvisioningRepo`'s
connection is itself unavailable for some reason even after §11.10.2 (pool
exhaustion, database unreachable), teardown SHOULD fail loudly — that is
correct, not a gap this rework needs to close.

### 11.10.4 Verification TEST-DESIGNER/ELIXIR-DEV must run for this rework
     specifically

Re-running §11.7's existing regression plan (items 1-6) is necessary but,
per `core-directives.md`'s "re-derive under the conditions the property is
actually about," **not sufficient on its own** to confirm teardown actually
completed correctly — a test file returning `N/N passed` proves ExUnit
did not observe a failure; it does not by itself prove the schema was
actually dropped and the tracking rows actually deleted (a `guarded/2`
swallowing a real failure, pre-§11.10.3, could in principle have produced
the same green result while leaking state — exactly the gap this
subsection exists to close empirically, not merely reason about):

1. **Re-run §11.7 items 1-6 in full**, with real quoted output — this is
   the existing required plan, unchanged, and is what confirms the BLOCKER
   itself (the `exit`/`shutdown: "owner ... exited"` failures) is gone:
   `backfill_test.exs` must return **5/5** (not merely "no exit raised" —
   the ISS-0332 assertion itself, `assert updated >= 1`, must also still
   pass, since that is what §11.9's own fix already closes and this
   section must not regress), and `context_test.exs` must return **11/11**
   (its pre-existing 5/11 was entirely this teardown defect, per the
   BLOCKER's own git-stash-confirmed evidence — TEST-DESIGNER/ELIXIR-DEV
   must re-confirm this file's own failures are fully gone, not merely
   reduced, since a partial improvement here would mean a second,
   undiagnosed defect remains).
2. **New, explicit post-teardown state check — not merely "the test
   passed."** For at least one `async: false` + `template: :clone` test
   already exercising `provision_via_shared_connection/1`'s teardown path
   (e.g. add this directly to `backfill_test.exs`, or as a new small
   dedicated regression test — TEST-DESIGNER's choice of file, not
   prescribed further here), assert AFTER the test's own body — most
   simply, from a SEPARATE test in the same file that runs after, since
   `on_exit/1` for a given test fires before the NEXT test in the same
   sync queue starts, per ExUnit's own documented ordering — that:
   - the tenant's schema no longer appears in
     `information_schema.schemata` (`TenantFixture.capture_schema_state/1`
     already exposes `schema_present?`, or a direct
     `SELECT 1 FROM information_schema.schemata WHERE schema_name = $1`
     against `Letflow.Repo` — any live connection, since teardown's own
     DROP already committed by the time the NEXT test runs, ordinary
     cross-connection MVCC visibility, no special wiring needed for the
     ASSERTION side either), and
   - the tracking rows are gone: `Letflow.Repo.get_by(Letflow.
     TenantProvisioning.Registration, tenant_id: tenant_id)` and
     `Letflow.Repo.get(Letflow.Identity.Tenant, tenant_id)` both return
     `nil`.
   This is what distinguishes "ExUnit didn't observe a red" from "teardown
   actually ran its DROP/DELETE to completion" — the exact gap a
   swallowed-`exit` scenario (pre-§11.10.3, or any future failure class
   `guarded/2` might absorb) could otherwise hide silently.
3. **Confirm the widened `guarded/2`/`log_teardown/3` boundary (§11.10.3)
   does not mask a genuine teardown failure.** A test that forces
   `schema_present?/1`'s own diagnostic read to raise (any mechanism
   TEST-DESIGNER judges reproduces a `raise`, e.g. temporarily renaming
   the table `information_schema.schemata` is not itself feasible/safe —
   TEST-DESIGNER should instead verify this at the unit level by calling
   `guarded/2`/`log_teardown/3` directly, or an equivalent fake, with a
   function that raises and one that exits, confirming both degrade to
   the same fallback rather than propagating) still allows the SAME test's
   own `teardown/2` DROP/DELETE statements to run and be observed (per
   item 2's own assertions) — i.e., the widened diagnostic boundary must
   not be confused with, or accidentally extended to, the load-bearing
   cleanup statements themselves (§11.10.3's own closing point).
4. **`mix compile --warnings-as-errors --force` and
   `mix format --check-formatted`**, both clean — unchanged standard gates,
   restated because §11.10.3's `guarded/2` body-shape change (single
   expression → explicit `try/rescue/catch`) is exactly the kind of
   syntactic change most likely to introduce an incidental formatting/
   warning regression if rushed.

### 11.10.4a CORRECTION (WF03-ISS0480-20260905, rework #5) — C5's teardown-
     logging test asserts the wrong expected value for the default path;
     item 2 above is reframed, not retracted

**§11.10.4 item 2 above (the "new, explicit post-teardown state check")
remains required and correct as written** — asserting, from a later test,
that the schema is gone from `information_schema.schemata` and the
`Registration`/`Tenant` rows are gone is still the right verification, and
still distinguishes "ExUnit didn't observe a red" from "the state is
actually gone." §11.10.2a's correction does not weaken that check; it only
corrects *why* the state is expected to be gone (ambient rollback, not
`teardown_wrap`'s DROP/DELETE, for this path) — the observable outcome
item 2 checks for is unchanged.

**What DOES need correction: `test/letflow/support/tenant_fixture_test.exs`'s
existing C5 test, "emits one marked teardown line naming the schema and its
presence" (currently at line 343, `assert_teardown_line/1` at line 541),
whose final assertion (line 556) is**

```
assert String.contains?(line, "schema_present_before_drop=true")
```

**This assertion encodes §11.10.2's now-corrected false premise as a test
expectation**, not merely as prose: it asserts the schema is STILL present
immediately before `teardown_wrap`'s DROP runs, which ISSUE-FIXER's direct
run of this exact test showed is false on the majority path — the schema
is already gone (`schema_present_before_drop=false`) by the time
`log_teardown/3`'s diagnostic read fires, because the ambient Sandbox
rollback already removed it. The test as currently written would only pass
if the false premise were true; it does not currently correctly describe
what the C5 test class is testing (log-line shape/content — that a
correctly-marked line is emitted at all, naming the right schema and
tenant_id — not the specific truth value of `schema_present_before_drop`
for this call site's own dispatch path).

**Corrected assertion, prescribed exactly (ELIXIR-DEV/TEST-DESIGNER must
implement this, not invent an alternative):** replace line 556's
hardcoded-`true` assertion with a check that the field is present and
holds a valid boolean, without asserting which one — because, per
§11.10.2a, `false` is the EXPECTED value for this test's own dispatch path
(`provisioned_tenant!/1` under `DataCase`'s default `async: false` +
`template: :clone`, i.e. `provision_via_shared_connection/1`, i.e. exactly
`teardown_wrap`'s "state already gone by the time teardown runs" case), not
an anomaly to guard against:

```
assert String.contains?(line, "schema_present_before_drop=false") or
         String.contains?(line, "schema_present_before_drop=true")
```

(or equivalently, a regex extracting the field's value and asserting it
`in [true, false]` — TEST-DESIGNER's choice of exact ExUnit idiom; the
requirement is that the assertion accepts `false` as the expected/majority
case for this call site, not merely as a tolerated edge case, and does not
regress to a bare presence-only check that would silently accept a typo'd
field name). **Add a one-line comment above the assertion** stating that
`false` is expected here specifically because this test's own tenant is
provisioned via `provision_via_shared_connection/1` (the default,
ambient-rollback path — §11.10.2a), so a future reader does not
reintroduce a hardcoded-`true` expectation without rereading this section.

**Do not rename or re-scope the `schema_present_before_drop` field itself**
(ISSUE-FIXER's step-13 handoff raised this as something for CODE-DESIGNER
to decide) — the field's diagnostic value is exactly that it now reliably
distinguishes the two dispatch paths' persistence semantics (`false` for
the shared-connection path per §11.10.2a's corrected premise, `true`-or-
gone-more-slowly for a `with_provisioning_repo/1`-provisioned caller whose
writes are durable until `teardown_wrap`'s own DROP actually runs), which
is diagnostically useful precisely because it now differs by path rather
than being expected to always read one way. Renaming it would lose that
signal for no benefit; the fix belongs in the test's assertion (and this
design's prose), not in the field or the logging code.

**§11.10.4 item 5's docstring-comment note above `schema_present_before_
drop`'s definition in `test/support/tenant_fixture.ex` (lines 552-556,
quoted verbatim: "distinguishes 'we tore down a schema that was still
there' (normal) from 'we tore down a schema that had already vanished' --
the ISS-0109 shape") also encodes the same false premise** — it frames
`false` as the rare/anomalous ("ISS-0109 shape") case, when §11.10.2a
establishes `false` is actually the EXPECTED, majority-path outcome for
every `async: false` + `template: :clone` shared-connection caller.
ELIXIR-DEV must update this comment to state the corrected framing: `false`
is normal/expected for a `provision_via_shared_connection/1`-provisioned
tenant (ambient Sandbox rollback already removed the schema before
teardown ran); `true` is expected for a `with_provisioning_repo/1`-
provisioned tenant (writes durable until this DROP actually runs). This is
a comment-only change — no code/signature change to `log_teardown/3` or the
field itself follows from it.

### 11.10.5 What ELIXIR-DEV implements for §11.10 (signatures only, no
     bodies)

1. `test/support/tenant_fixture.ex`, `provisioned_tenant!/1`: the existing
   single `connection_wrap` local binding (§11.6 item 2, currently reused
   for both the provisioning call and the `on_exit/1` teardown closure) is
   replaced by two bindings — `provision_wrap` (identical value/logic to
   today's `connection_wrap`: `provision_via_shared_connection/1` when
   `template == :clone and Process.get(:letflow_data_case_shared_mode?,
   false)`, else `with_provisioning_repo/1`) and `teardown_wrap` (always
   `&with_provisioning_repo/1`, no condition). `provision_wrap` replaces
   `connection_wrap`'s use at the provisioning call site (currently
   `connection_wrap.(fn -> ... end)` wrapping the whole 3-6 step body);
   `teardown_wrap` replaces `connection_wrap`'s use inside the `on_exit/1`
   registration (currently `on_exit(fn -> connection_wrap.(fn ->
   teardown(tenant.id, owner) end) end)`, becomes `on_exit(fn ->
   teardown_wrap.(fn -> teardown(tenant.id, owner) end) end)`). Public
   `@spec provisioned_tenant!(opts()) :: tenant_fixture()` unchanged.
2. `test/support/tenant_fixture.ex`, `guarded/2`
   (`defp guarded(fun, degraded)`): body changes from the current
   `fun.() rescue _exception -> degraded` shorthand to an explicit
   `try do fun.() rescue _exception -> degraded catch :exit, _reason ->
   degraded end` form (or equivalent — ELIXIR-DEV's exact clause naming/
   ordering, same two-fallback behavior). No signature change (still
   `defp guarded(fun, degraded)`, still returns `fun`'s value or
   `degraded`).
3. `test/support/tenant_fixture.ex`, `log_teardown/3`'s own trailing
   `rescue _exception -> :ok` clause: same widening —
   `rescue _exception -> :ok` becomes `rescue _exception -> :ok catch
   :exit, _reason -> :ok` (or the equivalent combined-clause form). No
   other change to `log_teardown/3`'s body (the `Logger.info/1` call and
   its arguments, unchanged).
4. `teardown/2`'s own body (`test/support/tenant_fixture.ex:522-534`):
   **unchanged** — no `guarded/2` wrapping added to its three statements,
   per §11.10.3's own closing argument (load-bearing cleanup must still
   fail loudly, not degrade silently).
4a. **NEW, WF03-ISS0480-20260905 rework #5.** `test/support/tenant_fixture.ex`
    lines 552-556 (the docstring-comment above `log_teardown/3`'s
    `schema_present_before_drop` computation): comment text only, corrected
    per §11.10.4a's closing paragraph — `false` is the expected/normal
    outcome for a `provision_via_shared_connection/1`-provisioned tenant
    (ambient Sandbox rollback already removed the schema before teardown
    ran), `true` is expected for a `with_provisioning_repo/1`-provisioned
    tenant (writes durable until this DROP runs). No change to
    `log_teardown/3`'s code/behavior.
5. No change to `provision_via_shared_connection/1`, `with_provisioning_
   repo/1`, `Letflow.Test.ProvisioningRepo`, `Letflow.Test.TenantTemplate`
   (including §11.9's own `ensure_template!/0` fix, which this section
   does not touch or re-open), `config/test.exs`, or
   `scripts/test_parallel.sh`. §10.2.2's connection-budget arithmetic is
   unaffected: this section adds no new connection acquisition beyond what
   `with_provisioning_repo/1` already performs for every `ProvisioningRepo`-
   dispatched caller today — it only adds ADDITIONAL callers of that
   already-budgeted path at teardown time (previously: every `async: true`
   caller's teardown, plus every caller's provisioning that dispatches
   there; now, additionally: every `async: false` caller's teardown) —
   §10.2.2's own headroom argument (advisory-lock-serialized provisioning,
   pool sized for "one in-flight plus one spare," §10.2's own comment,
   re-read for this section) was never contingent on teardown NOT also
   using this pool; `with_provisioning_repo/1`'s pool usage per call is
   brief (three simple statements, no advisory lock contention since
   teardown never overlaps with template building) and each call still
   fully releases its checkout before returning (`with_provisioning_repo/1`'s
   own `after` block, unchanged), so this is additional short-lived
   traffic on an already-provisioned pool, not additional peak concurrency
   — flagged as OQ-14 below for TEST-RUNNER's own full-suite run to confirm
   empirically rather than asserted as proven without that run, matching
   this design's own established discipline (§11.9.3's identical framing
   for its own empirical claim).

### 11.10.6 Open questions added by this rework

- **OQ-14.** §11.10.5 item 5's own closing claim — that routing every
  `async: false` caller's teardown through `ProvisioningRepo`'s pool adds
  short-lived traffic without raising PEAK concurrent checkouts against
  `Letflow.Test.ProvisioningRepo` (pool_size 2, §10.2's own headroom
  arithmetic) — is stated as an expectation grounded in `async: false`
  tests never running concurrently with each other (ExUnit's own
  documented sync-queue serialization, already established at §5.1/§11.4)
  plus `with_provisioning_repo/1`'s own bounded/short checkout, not as an
  empirically-measured peak. If TEST-RUNNER's full-suite run (§11.10.4
  item 1) shows any `DBConnection.ConnectionError`/checkout-timeout
  symptom against `Letflow.Test.ProvisioningRepo` specifically (distinct
  from the BLOCKER's own `Letflow.Repo`-targeted `exit`), that is the
  signal this expectation needs re-verification against §10.2.2's own
  arithmetic, which assumed teardown traffic at a smaller population than
  this section now routes through it.
- **OQ-15.** §11.10.3's `guarded/2`/`log_teardown/3` widening catches
  `:exit` broadly (any exit reason), matching `rescue`'s own
  already-established breadth (any exception). This means a
  `:killed`/`:normal`/shutdown-for-unrelated-reasons exit reaching this
  boundary during a diagnostic read would ALSO degrade silently rather
  than propagate, which is consistent with INV-F-10's own stated intent
  for this specific, narrow diagnostic call site (`schema_present?/1`'s
  read inside `log_teardown/3`, never anything load-bearing per §11.10.3's
  own scope argument) but is recorded here as a deliberate breadth choice,
  not an oversight, in case a future reader wants a narrower `catch :exit,
  {:shutdown, _}` match instead — left as broad `catch :exit, _reason` for
  this rework since INV-F-10's own precedent (`rescue _exception`, not a
  narrower exception-type match) already established "broad, narrowly-
  scoped-by-call-site" as this module's own chosen idiom.

## 11.11 REWORK ITERATION 7 — §11.9.2's fix gated on the wrong condition
     (`template_ready?()` instead of `template_built_in_db?()`); corrects
     §11.9.2/§11.9.3/§11.9.4/§11.9.5 (OQ-13), does not reopen §11.10 or
     earlier sections for further debate

### 11.11.0 What ELIXIR-DEV found, re-verified against source rather than inherited

Per `handoffs/WF03-ISS0480-20260905/step-16-elixir-dev.json`'s BLOCKER
(read in full; not restated here beyond what this section's own diagnosis
depends on) — re-derived directly against
`test/support/tenant_template.ex` lines 67-141, 148-151, and 243-251
(read first-hand for this rework, not taken on the handoff's line numbers
alone):

- `ensure_template!/0` (lines 67-141) opens with `if template_ready?() do
  :ok else ... end` (line 69). `template_ready?/0` (lines 148-151) is a
  **pure `:persistent_term` read, scoped to this BEAM VM/process** — it
  answers "did THIS VM already run a successful `ensure_template!/0]` to
  completion," never "does the template physically exist in the
  database."
- Per §11.9.2's fix (rework #3, unchanged by this rework — see §11.11.1
  below for exactly what changes and what does not), `Sandbox.mode
  (Letflow.Repo, :auto)` (line 97) sits as the `else` branch's own first
  statement — i.e. it fires whenever `template_ready?()` is `false`,
  which is **every call, in every VM, that has not itself personally
  observed a prior successful build** — regardless of whether the
  template already exists in the real database from an earlier `mix
  test` invocation or a different partition sharing the same steady-state
  database.
- `template_built_in_db?/0` (lines 243-251) is the function that actually
  answers "does the template exist in the database" — a single
  `information_schema.schemata` query, no VM-local state. It is called at
  line 114, **after** the `Sandbox.mode(:auto)` call (line 97) and the
  advisory-lock acquisition (line 109) have already run, purely to decide
  whether `build_template!/0` needs to run at all (`unless
  template_built_in_db?() do ... end`).
- **§11.9.2's own text already named the intended condition in prose**
  ("issue the `Sandbox.mode/2` call only on the path that is about to
  actually build the template") **but implemented it against the wrong
  proxy.** `template_ready?() == false` and "a build is about to happen"
  coincide only when the template has genuinely never been built anywhere
  against this database. They diverge exactly when the template
  physically exists (built by an earlier `mix test` invocation, or by a
  sibling partition sharing the same steady-state database) but this
  particular VM has not itself, in its own lifetime, called
  `ensure_template!/0` before — which is precisely "this VM's first call,"
  the common case for any single-file `mix test <path>` invocation.
- ELIXIR-DEV's own reproduction (step-16's `_fk_probe_test.exs`, not
  committed) is accepted as the operative evidence for this diagnosis,
  per `HANDOFF_PROTOCOL.md` §1.1: a fresh VM, `template_ready?()` reading
  `false` on first call while `template_built_in_db?()` reads `true`
  (schema already exists from a prior invocation), reproduces the exact
  `tenant_schemas_tenant_id_fkey does not exist` symptom this whole
  design exists to eliminate — via the same Mechanism 4 discard §11.9.1
  already diagnosed (a mode-switch to a genuinely different mode discards
  the calling connection's own in-flight, uncommitted `Tenant` insert),
  just reached through a broader trigger condition than §11.9.3 disclosed.

**Why this is a correction to §11.9.2's mechanism, not a new mechanism.**
No new failure class is introduced by this finding. It is the SAME
Mechanism 4 discard §11.9.1/§11.9.2 already fully diagnosed, firing on a
LARGER trigger population than §11.9.2's own fix believed it had reduced
it to. §11.9.3's disclosed residual gap ("the first call in a VM, IF it
also happens to be the call that triggers the build") is not what
ELIXIR-DEV reproduced; what was reproduced is broader — "the first call
in a VM, full stop, whether or not a build follows" — exactly as
step-16's BLOCKER states under its own
`why_this_exceeds_11.9.3s_disclosed_trade-off` heading.

### 11.11.1 The corrected fix: check `template_built_in_db?()` BEFORE any `Sandbox.mode/2` call; gate the mode-switch on that, not on `template_ready?()`

**Mechanism, stated exactly for `test/support/tenant_template.ex`
(same file §11.9.2 already authorized changing; no new file is touched):**

Restructure `ensure_template!/0` into a three-way sequence instead of the
current two-way `if template_ready?() do :ok else <mode-switch + build>
end`:

1. **`template_ready?()` check, UNCHANGED, evaluated first, no I/O.** If
   `true`: return `:ok` immediately, exactly as today — this is the
   already-correct steady-state fast path for a VM that has itself
   already built or observed the template, and §11.9.2's fix already
   established it issues zero `Sandbox.mode/2` calls. Nothing about this
   branch changes.
2. **If `template_ready?()` is `false`: call `template_built_in_db?()`
   NEXT, still with no `Sandbox.mode/2` call issued anywhere yet.** This
   is a single `information_schema.schemata` query on whatever connection
   is already ambient for the caller (no mode-switch needed to run a
   plain read-only `SELECT` on the caller's own current connection/mode —
   `Repo.query!/2` does not require `:auto` mode to execute; it runs on
   the connection the caller's current sandbox mode already provides,
   exactly as `template_built_in_db?/0`'s own existing callers at line
   114 already rely on, just moved earlier).
   - **If `template_built_in_db?()` is `true`** (the template physically
     exists already — built by an earlier invocation, or a sibling
     partition sharing this database — but this VM has not personally
     observed it): `:persistent_term.put(@built_marker_key, true)`
     immediately (priming this VM's own cache from the DB read, so every
     SUBSEQUENT call in this VM hits step 1's fast path with zero DB
     round-trips, exactly the caching behavior `template_ready?/0`'s own
     moduledoc already promises), then return `:ok`. **No
     `Sandbox.mode/2` call is issued on this path at all** — this is the
     entire fix: the caller's own ambient connection/mode is never
     touched, so its in-flight, uncommitted work (e.g. a `Tenant` insert
     under `provision_via_shared_connection/1`'s `{shared, self()}`/
     `:auto` mode) survives untouched, closing the gap ELIXIR-DEV
     reproduced.
   - **If `template_built_in_db?()` is `false`** (no prior build exists
     anywhere against this database — the genuine, once-per-database
     build path): THEN, and only then, proceed to exactly what §11.9.2
     already specified — `Sandbox.mode(Letflow.Repo, :auto)`, then the
     advisory lock, then the re-check-inside-the-lock
     (`unless template_built_in_db?() do ... end`, UNCHANGED, see
     §11.11.2 below for why it stays), then `build_template!/0` via
     `unboxed_run/3`, then `:persistent_term.put/2`, then `:ok` — this
     whole tail is copied forward from §11.9.2's fix verbatim; nothing in
     it changes.

Concretely (structure, not implementation — ELIXIR-DEV writes the actual
diff): the existing `if template_ready?() do :ok else <body> end` becomes
`if template_ready?() do :ok else if template_built_in_db?() do
<prime-cache-and-return-ok> else <mode-switch + advisory-lock + build,
body unchanged from §11.9.2> end end` — or equivalently a `cond`/pattern
worth of the same three branches; ELIXIR-DEV chooses the idiomatic
Elixir shape, the three-branch DECISION STRUCTURE is what this design
mandates, not the specific control-flow construct.

**Why this closes the gap without reintroducing the very hazard §4.3's
advisory lock exists to prevent — the concurrency check.** The
outer, pre-lock `template_built_in_db?()` call this section adds is
NEW, but it is read-only and does not gate whether a build happens if
it (wrongly, under a race) says `false` — the build path's own EXISTING
re-check at (current) line 114, `unless template_built_in_db?() do
build_template!() end`, run **inside** the advisory lock, is UNCHANGED
by this rework and remains the sole authority for "does a build
actually run." Concretely, walk the two-concurrent-callers race:

- Caller A and caller B both observe `template_ready?() == false`
  (neither VM has built it yet — e.g. two partitions' first calls) and
  both then observe the new pre-lock `template_built_in_db?() == false`
  (genuinely not yet built anywhere). Both proceed to `Sandbox.mode
  (:auto)` + advisory lock acquisition. Postgres's `pg_advisory_lock`
  serializes them: whichever acquires first re-checks
  `template_built_in_db?()` inside the lock (line 114, unchanged) — still
  `false` for the first caller, so it builds; the second caller, once it
  acquires the lock after the first releases it, re-checks and now finds
  `true` (the first caller's build already renamed the staging schema
  into place — §0.7's atomic build-then-rename, unaffected by this
  rework), so it skips `build_template!/0` and falls through to
  `:persistent_term.put/2` + `:ok`, exactly as the pre-existing code
  already handles this race today. **Nothing about this rework changes
  that inner re-check or its role** — it is the single mechanism that
  has always protected against two concurrent builds, and this rework
  does not touch it.
- The only new possible interleaving is at the OUTER, pre-lock
  `template_built_in_db?()` check this rework adds: if it happens to run
  while ANOTHER caller's build is already complete but that other
  caller hasn't yet run, this caller's outer check correctly reads `true`
  and takes the priming fast path — correct and desired, since no
  advisory lock is needed to safely read a fact that is already durably
  true in the database (a completed rename is atomic and visible to any
  connection per §0.7/INV-8). If it runs while another caller's build is
  **in progress** (mid-way through `do_build_template!/1`'s staging-schema
  sequence, before the final `RENAME TO "tenant_template"`), the outer
  check reads `false` (the literal name `"tenant_template"` does not
  exist yet — INV-8's own guarantee: the name only ever appears
  post-rename), so this caller falls through to the mode-switch +
  advisory-lock path exactly as it does today, and the existing inner
  re-check (line 114) is what correctly discovers the build completed
  while this caller waited on the lock. **No new race is introduced: the
  outer check can only ever produce a FALSE NEGATIVE relative to a
  build that finishes between the outer check and the lock acquisition,
  and that false negative is exactly what the pre-existing inner
  re-check already exists to catch — it was already handling this
  before this rework, for the identical reason (a concurrent caller could
  have raced ahead between `template_ready?()` and the lock, under
  §11.9.2's own fix too).** The outer check changes only where the
  disruptive `Sandbox.mode/2` call sits relative to a DB read that used
  to happen only after it — it adds no new decision that determines
  whether a build runs; that decision stays exactly where §4.3 and
  §11.9.2 already placed it, inside the lock.

### 11.11.2 What does NOT change, stated explicitly

- **The inner re-check at (current) line 114,
  `unless template_built_in_db?() do build_template!() end`, run inside
  the advisory lock — UNCHANGED, verbatim.** This is not "the same check
  moved" — it is a SECOND, independent call to the same pure function,
  kept exactly where it is for exactly the reason §11.9.1's own comment
  already states (a concurrent first-caller may have built the template
  while this call waited on the lock). §11.11.1 ADDS a new, earlier call
  to `template_built_in_db?()`; it does not remove, relocate, or dedupe
  the existing one. Two calls to the same pure, cheap
  (`information_schema.schemata`, one row lookup) query in one function
  body is the accepted cost of correctness here — not a "clean it up to
  one call" opportunity for ELIXIR-DEV to take.
- **`template_ready?/0`'s own body — UNCHANGED.** Still a bare
  `:persistent_term.get/2`, still pure, still VM-local. This rework does
  not turn it into a DB-backed check; it keeps it as the fast,
  intra-VM cache it already is, and adds the one missing link (priming
  that cache from a DB-confirmed `true`, on the branch that previously
  fell through to the disruptive mode-switch instead).
- **`template_built_in_db?/0`'s own body — UNCHANGED.** Still the plain
  existence check §0.7/INV-8 already established as correct and
  sufficient (no defensive self-check re-run "just in case", per that
  function's own existing comment, lines 234-242) — this rework calls it
  from one additional call site; it does not change what it does or
  means.
- **The build path itself (`build_template!/0`,
  `do_build_template!/1`, the advisory-lock acquire/release, the
  `unboxed_run/3` wrap) — UNCHANGED, byte-for-byte.** §11.9.2's own
  argument for why the build path's `:auto` call is safe (§4.3's
  advisory-lock protection, §11.9.2's own "why this is sufficient"
  paragraph) is untouched by this rework and still applies verbatim to
  the one case that still reaches it: a genuine, first-ever,
  once-per-database build.
- **No change to `test/support/tenant_fixture.ex` or
  `test/support/data_case.ex`** — same boundary §11.9.4 item 3 already
  stated; this rework, like §11.9, is entirely inside
  `ensure_template!/0`'s own body (now also touching its immediate
  private-function neighbor call graph, not its signature).
  `@spec ensure_template!() :: :ok` is unchanged.
- **§11.10's teardown-routing fix (rework #4) and its own §11.10.4a
  correction (rework #5) — untouched, not reopened.** This section is
  purely a §11.9-lineage correction; it shares no call site or code path
  with §11.10's `on_exit/1`/`teardown_wrap` mechanism.

### 11.11.3 Why the residual gap §11.9.3 disclosed (OQ-13) is now CLOSED, not merely narrowed

§11.9.3's disclosed residual case was: "the very first `template::clone`
`async: false` call in a partition, IF it also happens to be the call
that triggers the template BUILD, still has its own `Tenant` insert
discarded — because that one call necessarily fires before the build,
and the build's own precondition (DDL must run unboxed) is incompatible
with preserving an in-flight sibling transaction on the same connection."

**That residual case is real and is NOT closed by this rework — it is
the one case §11.11.1's third bullet still routes through the mode-switch
+ advisory-lock + build sequence, by construction, because a build IS
about to happen and the existing §11.9.2 argument for why that is an
accepted, disclosed trade-off still applies unchanged (§11.11.2's fourth
bullet).**

**What IS closed is the DIFFERENT, BROADER gap step-16 found**, which is
the population §11.9.3's own framing implicitly assumed did not exist:
calls where `template_ready?()` is `false` (this VM's first call) but
`template_built_in_db?()` is `true` (no build is actually about to
happen — the template already exists, built by a prior invocation or a
sibling partition). §11.9.2's fix, as literally implemented, routed that
whole population through the disruptive mode-switch anyway, because it
gated on the wrong condition; §11.11.1 routes it through the
zero-`Sandbox.mode/2`-calls priming path instead, matching what
§11.9.2's own prose already claimed the fix would do
("only on the path that is about to actually build the template").

**OQ-13's disposition: NARROWED, not fully resolved — restated precisely
so a future reader does not conflate the two populations.** OQ-13, as
written in §11.9.5, asks whether the residual "first call IN A BUILD"
gap needs alternative 2 or 3 from §11.9.3 adopted in a future tranche if
TEST-RUNNER's full-suite run finds it firing in practice. That question
is UNCHANGED and STILL OPEN after this rework — §11.11 does not touch
the build path, so a genuine first-ever-per-database build still
discards its own triggering caller's in-flight insert exactly as before.
What changes is the OBSERVABLE FREQUENCY OQ-13's own resolution depends
on: §11.9.3's empirical argument for "currently unobserved" rested on
"an `async: true` `TenantFixture` caller already builds the template
before the sync queue's first `async: false` caller runs" — an argument
about SCHEDULING ORDER within one run. That argument was never about,
and does not protect against, a STANDALONE single-file invocation (`mix
test test/letflow/support/tenant_fixture_test.exs` alone) where no
`async: true` builder ever runs in the same VM at all — before this
rework, EVERY such standalone invocation hit the disruptive mode-switch
regardless of DB state, per step-16's reproduction; after this rework, a
standalone invocation only hits the genuine-build branch (and therefore
only remains exposed to OQ-13's still-open residual gap) on a database
that has never had the template built before — e.g. a fresh CI database,
or the very first `mix test` invocation ever run against a given
partition database. **Practically, this rework converts OQ-13's
population from "every standalone invocation, every time" (unconditional
on DB state) to "only a standalone invocation against a database whose
template has genuinely never been built" (conditional on DB state,
matching what §11.9.2 always intended)** — a materially smaller and
now-correctly-scoped population, worth re-running §11.9.3's own
empirical check against once this rework ships, but not something this
design asserts is empirically zero without that run. TEST-RUNNER's
regression run (§11.11.4 below) is what confirms or narrows this
further, per this design's own established discipline of not asserting
an empirical claim without the run that checks it (§11.9.3, §11.10.4a's
own precedent).

### 11.11.4 What ELIXIR-DEV implements for §11.11 (signatures only, no bodies)

1. `test/support/tenant_template.ex`, `ensure_template!/0`: restructure
   the existing `if template_ready?() do :ok else <body> end` into the
   three-branch decision §11.11.1 specifies — `template_ready?() == true`
   returns `:ok` (unchanged); `template_ready?() == false` AND
   `template_built_in_db?() == true` primes `:persistent_term` and
   returns `:ok`, issuing NO `Sandbox.mode/2` call; `template_ready?() ==
   false` AND `template_built_in_db?() == false` runs the existing
   mode-switch + advisory-lock + build tail from §11.9.2/§11.9.4,
   UNCHANGED in its own internal body (including its own inner
   `template_built_in_db?()` re-check inside the lock, per §11.11.2's
   first bullet — do not remove or merge it with the new outer check).
   `@spec ensure_template!() :: :ok` unchanged.
2. The comment block §11.9.4 item 1 required to move alongside the
   (now further-conditioned) `Sandbox.mode/2` call must be updated again,
   in place, to state the corrected condition (gated on
   `template_built_in_db?()`, checked before the mode-switch — not on
   `template_ready?()` alone) and to cite this section (§11.11) for why,
   the same way §11.9's own comment cited §11.9 over the pre-§11.9 text
   it replaced — a reader must not find a comment that still describes
   only §11.9.2's superseded two-way branch.
3. No change to `template_ready?/0`, `template_built_in_db?/0`,
   `clone_tenant_schema!/1`, `build_template!/0`, `do_build_template!/1`,
   or any other function in this module beyond `ensure_template!/0`'s own
   body — matching §11.9.4 item 2's discipline, extended to this rework.
4. Re-run, in full, the same regression plan §11.9.4 item 4 and §11.7
   already specify (including the standalone single-file invocations
   ELIXIR-DEV used to reproduce this BLOCKER —
   `mix test test/letflow/tenant_provisioning/backfill_test.exs` alone
   and `mix test test/letflow/support/tenant_fixture_test.exs` alone,
   both run against a database where the template ALREADY exists from a
   prior invocation, since that is the exact condition step-16 reproduced
   under and the corrected code's central claim is that this condition no
   longer discards the caller's insert) — this is what confirms the fix
   actually closes the broader gap, not merely that it compiles. Also
   re-run this handoff's own two already-applied, already-verified
   corrections' tests (`tenant_fixture_test.exs`'s C5 case,
   `tenant_fixture.ex`'s docstring — both unaffected by this section and
   must remain green) to confirm they still pass unchanged.

### 11.11.5 Open questions

- **OQ-13, restated (see §11.11.3 for the full reasoning) — STILL OPEN,
  narrower scope.** Whether a genuine first-ever-per-database build's own
  triggering caller still needs alternative 2 or 3 from §11.9.3 adopted
  in a future tranche remains unresolved, exactly as §11.9.5 left it. What
  changed is the population this now protects: only a caller whose
  database has never had the template built at all is still exposed
  (never a caller running against a database that already has it,
  regardless of this VM's own build history) — re-run §11.9.3's own
  empirical expectation against THIS corrected code once TEST-RUNNER's
  §11.11.4 regression plan lands, rather than assuming zero without that
  run.
- No new open question beyond OQ-13's restatement is introduced by this
  section — §11.11.1's three-branch restructuring is a strictly more
  precise gating condition over the same two functions
  (`template_ready?/0`, `template_built_in_db?/0`) §11.9 already
  established as this module's own vocabulary; it adds no new state, no
  new module attribute, no new cross-module dependency.
