# ISS-0480: Sandbox checkout race between `provisioned_tenant!/1`'s `:auto` flip and bystander `async: true` tests

Status: NORMATIVE. Design for ORCH run WF03-ISS0480-20260905, Step 2.

## 0. Scope and what this document does not re-litigate

This document does not re-derive the root cause. Step 1
(`handoffs/WF03-ISS0480-20260905/step-01-issue-fixer-diagnosis.json`) established, by
source trace plus 3/4-run empirical reproduction, that:

- `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` →
  `DBConnection.Ownership.Manager.handle_call({:mode, mode}, {caller, _}, state)`
  (`deps/db_connection/lib/db_connection/ownership/manager.ex:169-172`) calls
  `proxy_checkin_all_except(state, [], caller)` — literal empty except-list — **only
  when the requested mode differs from the pool's current mode** (the `%{mode: mode} =
  state` clause at line 164 no-ops otherwise). When it does not no-op, it checks in
  **every** currently-checked-out connection belonging to **every** process in the
  pool, not just the caller's own.
- `test/letflow/secrets_test.exs` and `test/letflow/webhooks_test.exs` are
  `async: true` (ISS-0423) and reach `Letflow.TenantFixture.provisioned_tenant!/1`,
  whose unconditional first line is `Sandbox.mode(Letflow.Repo, :auto)`
  (`test/support/tenant_fixture.ex:222`).
- `Letflow.RowApprovalTest` and `Letflow.Definitions.PackUpdateMigrationTest` are
  `async: true`, hold an open Sandbox checkout for their whole test body (via
  `Letflow.DataCase.setup/1`, unconditional for every test regardless of `async`), call
  `Sandbox.mode/2` nowhere themselves, and are innocent bystanders whose connection is
  discarded by the mass check-in the moment either culprit file's line above actually
  changes the pool's mode.
- ExUnit runs every `async: true` module to completion before any `async: false`
  module starts (`ex_unit/runner.ex:104-138`, independently verified) — so the hazard
  is async-vs-async only, never async-vs-sync.
- Measured hit rate: 3 of 4 full-async-cohort runs at the default concurrency
  (`max_cases`/`pool_size` both 32 on the reproduction host) failed, all three in
  `RowApprovalTest`, three different individual tests each time. 0 of 4 reproduced
  `PackUpdateMigrationTest`'s FK symptom. Step 1's own cohort was built from
  `grep -rl "async: true" test --include=*.exs` (95 file-argument matches, a looser
  match than this document's own §1.3 count — it also matches files whose moduledoc
  prose merely mentions "async: true" without declaring it, which is harmless as extra
  `mix test` file arguments since such a file simply contributes no additional async
  module to the run).
- `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md` §9.4's second
  hazard analysis and its own self-flagged OQ-5 reasoned only about a *future
  additional file that also calls* `Sandbox.mode/2`. Neither ever considered a
  bystander process that never calls `Sandbox.mode/2` at all — that is the exact gap
  this record closes. This is re-confirmed directly against that document's own text
  above, not re-derived from scratch.

This design accepts Step 1's diagnosis as verified and answers only: what changes, why,
what it costs, what it does not fix, and how the fix is actually demonstrated.

## 1. The remedy

**Chosen: revert `test/letflow/secrets_test.exs` and `test/letflow/webhooks_test.exs`
from `async: true` to `async: false`.** This is Step 1's option 1, adopted as-is.

### 1.1 Why this over the fixture-source alternative (option 2)

Option 2 — change `provisioned_tenant!/1` so its `Sandbox.mode/2` call never actually
*changes* the pool mode (e.g. gate it behind a check-and-skip, or move the transition
to a `setup_all`/once-per-run boundary) — is rejected **for this record**, not as
wrong in principle but as the wrong size for what this issue needs fixed right now:

- The `%{mode: mode} = state` no-op guard the task brief points at
  (`manager.ex:164`) already fires whenever the requested mode **matches** the
  current one. It cannot be used to make `provisioned_tenant!/1`'s call "always a
  no-op," because the call's entire job is to be the thing that flips the pool from
  `:manual` (ExUnit's default for a fresh async worker with no shared mode set) to
  `:auto` the first time any test needs a real multi-connection provisioning
  operation. Skipping the call when the mode is already `:auto` does not help: the
  **first** async test in the run to reach this line is unconditionally the one that
  performs the real, disruptive transition, no matter how few or many call sites
  exist. Zero call sites removes the hazard; one call site does not, structurally —
  this is a property of the transition itself, not of how many places request it.
  This sinks the "make it conditional/idempotent" third option the task brief asks to
  weigh explicitly: idempotency against *repeated identical requests* is not the same
  property as idempotency against *the first state change*, and only the latter would
  help here.
- A genuine fix at the fixture source (e.g. `Sandbox.allow/3`-based connection sharing
  instead of a global mode flip, or restructuring so the transition happens at
  `setup_all` before ExUnit's async cohort starts scheduling) is real, new runtime
  logic in shared, 46-call-site-wide code. `docs/issues/ISS-0113.yaml`'s own record
  shows this exact shared fixture has already been attempted and reverted **twice**
  for different reasons (a `:manual`-restore attempt breaking 12/125 tests across
  three distinct mechanisms; a `restore_sandbox: true` opt-in breaking 26/38 scoped
  examples via the very mode-flip-discards-connection mechanism this issue is about).
  A third attempt needs the same rigor those two used — full source trace plus
  multi-seed empirical stress **against all 46 call sites**, since a fixture-source
  change cannot be scoped to "just the two culprit files" the way a test-file revert
  can. That is materially more design and verification work than this issue's own
  severity (MAJOR, but a known, narrowly-triggered intermittent, not a correctness
  defect in shipped code) justifies as a same-run fix. It is named here as the
  legitimate longer-term fix, not dismissed — see §6.
- The revert is the **only one of the three candidates that is independently
  verifiable using the exact reproduction recipe that found the bug** (§4) without
  first building new mechanism. That materially lowers the risk of this fix itself
  introducing a fifth undiscovered mechanism, which is precisely the pattern that
  produced ISS-0480 in the first place (ISS-0423's fix for ISS-0113 introduced this
  exact class of new hazard).

### 1.2 What the revert changes, precisely

| File | Before | After |
|---|---|---|
| `test/letflow/secrets_test.exs` | `use Letflow.DataCase, async: true` | `use Letflow.DataCase, async: false` |
| `test/letflow/webhooks_test.exs` | `use Letflow.DataCase, async: true` | `use Letflow.DataCase, async: false` |

Both files' moduledocs currently carry an `## async: true (ISS-0113 / ISS-0423 ...)`
section asserting the file was verified safe against ISS-0113's three-mechanism
procedure and needs no opt-in flag. That section becomes stale/wrong once reverted —
ELIXIR-DEV must replace it with a note recording:

- why it was reverted (this record, ISS-0480, cites the DBConnection empty-except-list
  mass-checkin mechanism, not a defect in either file's own test logic),
- that the file's own ISS-0113 three-mechanism classification was correct and remains
  true (self-checkout / concurrent multi-process access / second provisioning call —
  none apply to either file); the revert is not a retraction of that classification,
  it is because a **fourth**, systemic mechanism outside either file's own code makes
  `async: true` unsafe for **any** file that calls `Sandbox.mode/2` while **any other**
  concurrently-scheduled `async: true` test anywhere in the suite holds an open,
  unrelated Sandbox checkout — which is every `async: true` test in the suite, since
  `DataCase.setup/1` checks out unconditionally,
- a pointer to this document and to §6 (what would actually re-enable this).

No other file changes. No production code changes (`lib/letflow/` untouched, matching
Step 1's own confirmation that this is a test-only hazard).

### 1.3 Invariant this remedy relies on (must hold or the fix is void)

**INV-1.** No `async: true` test file anywhere in the suite may call
`Sandbox.mode(Letflow.Repo, mode)` for any `mode` other than a no-op relative to the
pool's already-current mode, for as long as any *other* `async: true` test file exists
that holds an open Sandbox checkout without itself calling `Sandbox.mode/2`. Concretely,
today: **zero** `async: true` files may call `Sandbox.mode/2` at all, because
`DataCase.setup/1` gives every `async: true` test an open checkout, and none of them is
exempt from being a victim. Re-derived directly for this document (not inherited from
Step 1's prose uncritically): `grep -rl "^\s*use.*async: true" test --include=*.exs`
— anchored on the actual `use` declaration, not on `async: true` appearing anywhere
including moduledoc prose — currently returns **66** files. Post-revert (§1.2) that
count becomes 64.

This is a strictly *narrower* invariant than ISS-0113's own §9.4/OQ-5 invariant ("at
most one async file may call `Sandbox.mode(:auto)`, and it may only ever request
`:auto`, never anything else, and it may never be a repeat call after the pool is
already elsewhere") — INV-1 supersedes it for the async-file-count question, because
OQ-5's framing ("a *future* 3rd/4th caller") is the exact framing this issue disproves:
it is not about how many files call `Sandbox.mode/2`, it is about whether **any** other
async file exists that doesn't but has an open connection — which is always true once
more than one `async: true` file exists in the suite at all. Post-revert, the count of
`async: true` files that call `Sandbox.mode/2` is exactly **zero**, so INV-1 holds
trivially and by construction, not by continued reasoning about scheduling order.

**Anyone converting a new file to `async: true` in the future, or converting a new
`TenantFixture` call site, must re-check this invariant before doing so** — a
compile/test-time guard for it does not exist (see REVIEWER's own MINOR finding on the
ISS-0423 record: the current ISS-0113 guard is prose-only). §6 names this as an open
follow-on; it is not solved by this record.

## 2. The tension with ISS-0423, named explicitly

ISS-0423 converted exactly these two files (`secrets_test.exs`, `webhooks_test.exs`)
from `async: false` to `async: true` as a deliberate, narrow, first tranche of a larger
suite-speed initiative — measured then as raising the suite's async share from 1.4% to
2.2% of wall time, with a stated intent to convert more of the remaining 44
`TenantFixture` call sites in later tranches. This design **undoes that specific
conversion**, in full, for both files.

**What that costs, quantified from ISS-0423's own verified numbers** (not re-measured
here — this record's own AC does not require a fresh full-suite timing run, since the
delta from un-converting 2 of 3227 tests is far below this suite's own measured run-to-
run noise floor):

- ISS-0423's own AC5 quoted three full-suite runs on effectively the same code:
  BEFORE (pre-conversion, `async: false` both files): **1316.3s**. AFTER run 1
  (post-conversion): **1670.4s**. AFTER run 2: **1597.1s**. The BEFORE→AFTER spread
  (+354s / +281s) already dwarfs whatever marginal wall-clock these two files'
  `async: true` status contributes on its own — the suite's run-to-run variance at this
  scale (measured elsewhere in this same record's history, e.g. ISS-0480's own
  discovery: two runs on one commit producing 3 vs. 1 failures, and 1805s vs 1670s vs
  1597s vs 1316s across the various runs cited on this branch's own history) is large
  enough that reverting 2 files' `async` flag is not separately measurable against that
  noise with the tooling available in one `mix test` run. Stated plainly: **the
  isolable cost of this specific revert is real but too small to distinguish from
  existing suite jitter in a single before/after pair**, and this design does not
  claim a fabricated precise number it cannot support.
- What **is** quantifiable directly: the async-share metric ISS-0423 introduced.
  Reverting 2 of the (post-ISS-0423) 66 genuinely-`async: true` files (§1.3's own
  freshly re-derived count, anchored on the `use` declaration) returns the "real"
  converted count to the same place ISS-0423 found it before its own work (0 of 46 real
  `TenantFixture`-async conversions holding), i.e. this record fully reverses
  ISS-0423's own headline result for those two files specifically. ISS-0423's other,
  independent levers — `scripts/test_parallel.sh` wiring (ISS-0428) and the
  template-schema clone (ISS-0427) — are untouched by this record and keep their own
  gains; this revert only gives back the "2 more files run in the async cohort"
  portion, not the parallel-runner or template-clone portions, which remain the
  dominant contributors to any suite speedup on this branch's own history (2.9x from
  parallelism vs. a claimed ~2.2%→1.4% swing in async share for 2 files).
- **The case for accepting this cost:** a MAJOR, measured-75%-hit-rate intermittent
  failure in unrelated, innocent-bystander tests is a worse outcome for a humanless
  pipeline than giving up a low-single-digit-percent share of one already-small lever.
  An intermittent failure in this pipeline costs a TEST-RUNNER/RELEASE-VALIDATOR
  rework loop, consumes `max_rework` budget on whatever unrelated requirement happens
  to draw the unlucky seed, and (per this project's own repeated experience today,
  cited in core-directives.md's Failure Attribution section) actively degrades trust
  in "green means done" — which this pipeline depends on structurally, since there is
  no human backstop. A small, honestly-disclosed timing giveback is the cheaper of the
  two costs.

**If REVIEWER or a later session judges this trade-off differently**, the reversible
alternative is §6's `Sandbox.allow/3`/`setup_all`-boundary redesign of the fixture
itself — a strictly larger design effort this record deliberately declines to attempt
under ISS-0480's own scope, per §1.1.

## 3. Blast radius

**Only `test/letflow/secrets_test.exs` and `test/letflow/webhooks_test.exs` change.**
Both files' own moduledoc `async: true` justification sections are edited to record the
revert (§1.2); no other line in either file changes, and no test case, assertion, or
fixture call within them changes.

`Letflow.TenantFixture.provisioned_tenant!/1` itself is **not modified**. This is a
deliberate, load-bearing scoping decision, stated explicitly since the task brief asks
for exact blast radius: **every one of the 46 real `TenantFixture` call sites remains
exactly as it is today** — 2 `async: true` (post-ISS-0423, pre-this-record) reverting to
`async: false` here, 44 already `async: false` and untouched. No call site becomes newly
unsafe, none becomes newly safe beyond the two reverted; the invariant in §1.3 is
satisfied for the whole 46-site population by removing the only two sites that violated
it, not by touching the other 44.

**Tests NOT affected, and how this is known:** `git diff main...HEAD` at Step 1 time
confirmed `test/letflow/row_approval_test.exs`,
`test/letflow/definitions/pack_update_migration_test.exs`, and
`test/support/data_case.ex` are all empty-diffed against `main` and untouched by this
branch — that remains true after this remedy, since the remedy touches neither file. The
mechanism (§0) does not depend on anything in `RowApprovalTest`/`PackUpdateMigrationTest`
changing; it depends on the **source** of the disruption (the two culprit files) no
longer running concurrently with them. No other test file in the suite calls
`Sandbox.mode/2` while declared `async: true` (Step 1's own grep, re-stated in §1.3);
this record does not need to touch any of them because none of them is a problem today —
only the two culprits are.

**Tests indirectly protected by this fix, not merely the two named symptom files:** per
§1.3's INV-1, the hazard's blast radius before this fix was *every* `async: true` file
in the suite (66 files by this document's own anchored count, post-ISS-0423), not just
the two that happened to be observed failing. `RowApprovalTest` and
`PackUpdateMigrationTest` are the two Step 1 could reproduce; any other `async: true`
file with an open Sandbox checkout at the unlucky moment was equally exposed and simply
was not the one caught in Step 1's 4 sample runs. This fix removes the disruption
source entirely, so it protects the full 66-file population, not only the 2 confirmed
victims — stated as a design claim, verified per §4 below.

## 4. How this is verified

A single green `mix test` run is **not** evidence, per core-directives.md's own
"Re-derive under the conditions the property is actually about" and this project's
repeated same-day experience with exactly this inference failing. The property under
test is "the mass check-in no longer fires during the async phase because nothing in
the async phase calls `Sandbox.mode/2` to a differing mode" — this is proven by the
absence of a code path, and the absence is best demonstrated two ways, both required:

**4.1 Static verification (cheap, exact, not probabilistic).** After the revert:

```
grep -rl "Sandbox.mode(Letflow.Repo\|Sandbox.mode(Repo" test --include=*.exs \
  | xargs -I{} sh -c 'grep -m1 "^\s*use Letflow.DataCase" {} | sed "s|^|{}: |"'
```

**Verified runnable during this design's own drafting** (not merely proposed): run
against the current, unmodified branch tip, this exact command returns 75 files, of
which exactly two — `test/letflow/secrets_test.exs` and `test/letflow/webhooks_test.exs`
— show `async: true`; every other row shows `async: false`. (An earlier, looser version
of this command using a bare `"async:"` match instead of anchoring on the `use
Letflow.DataCase` line was tried first and rejected: it false-positived on files whose
*moduledoc prose* mentions "async: true" in passing, e.g.
`test/letflow/definitions/store_test.exs` and
`test/letflow/api/authorization_ac9_test.exs`, neither of which is actually declared
async. The anchored version above does not have that false-positive.) After the §1.2
revert, this same command must return **zero** files showing `async: true` — that is
the postcondition. This is a stronger, purely structural guarantee than any number of
green runs: if it returns zero rows, INV-1 (§1.3) holds by construction and the mass
check-in genuinely cannot fire during the async phase, regardless of scheduling or seed.
TEST-RUNNER or ELIXIR-DEV must run this and paste its literal output in the handoff, not
summarize it.

**4.2 Empirical stress verification, using Step 1's own proven-reproducing recipe,
not a generic full-suite run.** Step 1 established that a *plain* `mix test` run does
not reliably surface this defect (it exceeds this environment's blocking-call time
budget and dilutes the async cohort among sync work); the recipe that actually
reproduced it 3/4 times was **the full async-declaring cohort run together** under real
`max_cases`/`pool_size` concurrency. Post-fix verification must use the same shape:

```
mix test $(grep -rl "async: true" test --include=*.exs) --seed <S>
```

run **at least 4 times with 4 different seeds** (reuse Step 1's own default-seed-plus-3-
random-seeds pattern, or pick 4 fresh ones — the point is varying ExUnit's module
scheduling order, which is what perturbs the race window), expecting **0 failures in
`Letflow.RowApprovalTest` or `Letflow.Definitions.PackUpdateMigrationTest`, and 0 new
failures anywhere else attributable to this change**, every time. Any failure in either
named test on any of the 4+ runs means the fix did not close the hole and must not be
reported as done. A failure in some unrelated file is handled per Failure Attribution
(core-directives.md) — checked against the diff and against whether it reproduces at
the merge-base — not assumed related or unrelated by feel.

**4.3 Required full-suite run stays required as the pipeline's normal AC5-equivalent
gate** (per WF-03's own procedure), but its role here is only to confirm no other
regression was introduced by the two moduledoc edits — it is explicitly **not** what
demonstrates the fix itself, since a single full run is exactly the kind of "green run
proves nothing" case named in the task brief. TEST-RUNNER must not substitute 4.3 for
4.2.

**Acceptance for this issue's own resolution:** 4.1's grep returns zero rows AND 4.2's
4+ stress runs are all clean for the two named tests. Both are required; neither alone
is sufficient (4.1 proves the mechanism cannot fire but doesn't rule out a documentation
mistake in how the grep was run; 4.2 proves it empirically but a single lucky run is
exactly the false-negative risk this whole issue is about, hence "4+ seeds", not "1").

## 5. The unconfirmed second symptom (`PackUpdateMigrationTest`'s FK error)

**This remedy addresses it too, on the same mechanism — but with a materially weaker
empirical confirmation than `RowApprovalTest`'s, and that gap is stated honestly, not
elided.**

Reasoning for coverage: §0/Step 1 traced `PackUpdateMigrationTest`'s reported
`Ecto.ConstraintError` on `solution_pack_artefact_bases_tenant_id_fkey` to the identical
mechanism — a bystander `async: true` test's checked-out connection discarded mid-test
by the same mass check-in, landing its next query (an FK-checked insert) on a fresh,
empty-transaction connection that has never seen the tenant row the discarded
connection's own transaction had inserted. The mechanism does not care what table a
victim test touches (Step 1's own explicit finding: the "shared table" theory ORCH's
setup handoff flagged is a red herring — the discard is per-**connection**, not
per-**table**), so there is no structural reason `PackUpdateMigrationTest` would be
exempt from a fix that removes the mass check-in's trigger entirely.

What is honestly unconfirmed: Step 1's own 4 reproduction attempts, run against the
**unmodified** branch (defect still present), did not reproduce
`PackUpdateMigrationTest`'s FK symptom even once (0/4) — only `RowApprovalTest`'s
symptom reproduced (3/4). That means this design has **no empirical baseline failure**
for `PackUpdateMigrationTest` to compare a post-fix clean run against, for the specific
low-probability window that symptom needs. §4.2's verification procedure will exercise
`PackUpdateMigrationTest` in every one of its 4+ runs (it is unconditionally included in
the async-cohort file list), and zero failures there across those runs is *consistent
with* the fix covering it, but per this project's own repeated lesson about count-
matching and intermittents (core-directives.md's Failure Attribution section), a small
number of clean runs of an already-hard-to-reproduce symptom is weak positive evidence,
not proof of closure for that specific named failure shape.

**Disposition:** ship this fix covering both symptoms by mechanism, not by direct repro
of both. Two ways this could later be shown wrong or confirmed, named so nobody has to
re-derive them: (a) a future run reproduces the FK symptom against this exact *fixed*
branch — that would mean the mechanism is NOT fully explained by this design, and
ISS-0480 must be reopened for `PackUpdateMigrationTest` specifically; or (b) this
design's mechanism-level argument above is accepted as sufficient by
CODE-DESIGN-VALIDATOR/REVIEWER without a direct empirical repro, which is a legitimate
verdict given the mechanism is identical and the file shares no other code path with
`RowApprovalTest`. This design recommends (b) — do not hold this fix hostage to
reproducing an already-rare (0/4) symptom — but states plainly that (b) is an inference
from mechanism, not a repro-confirmed closure, so RELEASE-VALIDATOR/ORCH should record
it as such rather than claim direct confirmation.

## 6. What is not fixed, and the legitimate longer-term follow-on

Not fixed by this record, disclosed per §1.1's own scoping decision:

- **The systemic hazard remains latent** for any future `async: true` conversion of one
  of the 44 untouched `TenantFixture` call sites, or any new test file that calls
  `Sandbox.mode/2` under `async: true`. INV-1 (§1.3) is not enforced by any
  compile-time or test-time guard today — it is prose, in this document and in
  `provisioned_tenant!/1`'s own moduledoc. A future agent converting a call site to
  `async: true` without reading this record (or without re-running §4.1's grep) can
  silently reintroduce this exact class of defect, and nothing will catch it except
  another intermittent-failure discovery cycle.
- **Recommended follow-on, not undertaken here** (matches Step 1's own "candidate
  remedy 2", scoped correctly this time — for a *future*, separately-sized issue): a
  fixture-source fix that makes `provisioned_tenant!/1`'s mode transition happen
  exactly once, before ExUnit's async cohort begins scheduling at all (e.g. an
  `ExUnit.after_suite`-adjacent or `case_template`-level `setup_all` hook shared by
  every `Letflow.DataCase, async: true` user, invoked once), so no *test-body-scoped*
  call to `Sandbox.mode/2` ever occurs during the async phase, structurally, rather than
  by convention. This is the redesign §1.1 declined to attempt within ISS-0480's own
  scope; it would remove the need for INV-1 entirely rather than merely satisfying it
  by keeping the call count at zero. File as its own issue if a future tranche wants to
  convert more of the 44 remaining call sites to `async: true` and finds the "zero
  callers of `Sandbox.mode/2` under async" constraint too restrictive to live with
  long-term.
- A **compile-time or `mix format`-adjacent lint** enforcing INV-1 mechanically (the
  §4.1 grep, wired into `mix letflow.check` the way the ISS-0069 warning-substring
  check already is) is a small, separately-sized follow-on worth filing — it converts
  this record's "must re-check by hand" obligation into an automatic gate. Not
  undertaken here; named so it is visible work per "No Issue Left Local-Only," to be
  filed by ORCH as its own issue rather than folded into this fix.

## 7. Open questions

None block this fix. One forward-looking item, restated from §6 for visibility:
whether a future async-conversion tranche should invest in the `setup_all`-boundary
redesign (§6) or continue operating under the manual INV-1 discipline this record
leaves in place — left for whoever picks up the next `TenantFixture` async tranche to
decide with fresh measurement of how much further speedup is actually at stake.
