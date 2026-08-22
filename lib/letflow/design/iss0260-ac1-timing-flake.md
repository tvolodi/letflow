# ISS-0260 — AC1 timing-assertion flake — fix design

**Status:** design, awaiting CODE-DESIGN-VALIDATOR.
**Scope:** test-infrastructure only — `test/letflow/engine_concurrency_test.exs`
(the `describe "AC1 -- 100 concurrent task completions across 100 distinct instances"`
block) and the corresponding rationale text in
`lib/letflow/design/req-055-concurrent-instance-isolation.md` §3.4 Case AC1 / §6 OQ2.
**Explicitly out of scope:** `lib/letflow/engine.ex`, `Letflow.Engine.Reconstruction`,
or any change to the concurrency model itself — the AC1 correctness assertions
(`{:ok, %{instance_status: :completed}}`, cross-instance corruption checks) are unaffected
and untouched; this design only touches the wall-clock "no global lock" proxy assertion.

## 1. Inputs (do not re-diagnose — restated from ISSUE-FIXER's Step 1)

- The assertion under test: `assert concurrent_micros < baseline_micros * 30`
  (`test/letflow/engine_concurrency_test.exs:306`).
- Its documented purpose (design doc §3.4 Case AC1, §6 OQ2 lines 492-500): a portable
  proxy for "no accidentally-reintroduced global lock/singleton serializer," not a tight
  performance bound. A genuine regression of that kind pushes the ratio toward
  `~@instance_count` (~100x); the current constant exists only to sit well below that.
- Two independent real-load measurements, both under `scripts/test_parallel.sh`'s actual
  16-way partitioned mode (the only mode that reproduces genuine cross-partition
  Postgres/scheduler contention — a single-file run does not):
  - Original filing (WF02-REQ083-20260822 Step 4): `baseline_micros=32460`,
    `concurrent_micros=1103564` → ratio **≈34.0x** — **failed** against the 30x constant.
  - ISSUE-FIXER's reproduction (this run, same host, 16 cores): `baseline_micros=38502`,
    `concurrent_micros=1132851` → ratio **≈29.42x** — **passed**, razor-thin margin.
  - Both are far below the ~100x a real global-lock regression would produce. This is
    load/contention noise under real full-parallelism, not a correctness regression —
    but 30x sits inside that noise band under this repo's own documented full-parallelism
    operating mode (`scripts/test_parallel.sh`, REQ-113/REQ-114, default N=nproc), so the
    flake will keep recurring under that mode specifically.
- No measurement exists (and none is claimed) for plain `mix test` (no
  `scripts/test_parallel.sh` wrapper, no sibling partitions contending for the same
  Postgres). Nothing in ISSUE-FIXER's diagnosis suggests the flake reproduces there.

## 2. Candidate shapes considered, and why (2) is chosen

**(1) Loosen the multiplier further, uniformly.** Rejected as the *sole* fix. Any single
constant loose enough to clear real 16-way contention (would need to comfortably clear
34x, so ≥~45-50x with margin) is *unconditionally* applied even to a plain, uncontended
`mix test` run — where nothing in the evidence says a looser bound is needed, and where a
looser bound trivially reduces the assertion's power to catch a real regression in the
common case every ELIXIR-DEV actually runs locally before pushing. Picking one number to
cover both regimes at once is exactly the "unfounded constant, chosen without connecting
it to what varies" anti-pattern this run's dispatch flags — the two measurements
themselves show the ratio is a function of *load regime*, not a fixed property of the
code path, so a fixed constant can't be right for both regimes simultaneously without
being loose in the one that doesn't need it.

**(3) Convert to a non-blocking benchmark (log only, no hard assertion).** Rejected.
ORCH's dispatch names this explicitly as the anti-pattern to avoid: dropping the
assertion's *power* to fail on a real regression, relying on "something else" to catch it
— and nothing else in this test suite exercises AC1's "no global serializer" property.
A silently-logged ratio that nobody reads on a red/green CI-less pipeline (no CI
configuration exists in this repo per multiple prior design docs' own re-verification,
e.g. `iss0258-deferral-staleness-detection.md` §5) is equivalent to deleting the check —
a regression would ship undetected until some *other* symptom surfaced it, at which point
the trail back to "the AC1 proxy stopped gating months ago" is cold.

**(2) Make the assertion load-aware — chosen.** Directly precedented, not invented for
this run:
- `scripts/test_parallel.sh` already exports `TEST_PARALLEL_GROUP="tp$$"` once per
  invocation, shared by every sibling partition, before forking them.
- `config/test.exs` (~lines 54-60) already reads
  `System.get_env("TEST_PARALLEL_GROUP")` for an unrelated purpose (ISS-0217's
  `application_name` tagging) — so this is already the codebase's live, working signal
  for "am I one partition of a real N-way `test_parallel.sh` run," not a new one.
- Decision `docs/migration/decisions/0009-test-parallel-pool-sizing.md` established the
  exact pattern this problem calls for: behavior that must legitimately differ between a
  plain `mix test` and a `scripts/test_parallel.sh` N-way run gets an env-var knob read at
  test/config time, with a documented default and an explicit override escape hatch —
  not a single number bent to cover both regimes.
- This keeps the assertion **exactly as strict as before (30x) in the regime the
  evidence says needs no loosening** (plain `mix test`), and loosens it **only** in the
  regime the evidence says produces genuine contention noise
  (`scripts/test_parallel.sh`'s N-way mode) — the loosening is scoped to the actual cause,
  not applied blind.

## 3. The fix, precisely

### 3.1 Two named constants, not one

Replace the single hardcoded `30` with two module attributes in
`test/letflow/engine_concurrency_test.exs`:

- `@ac1_timing_multiplier_default` — value **30**. Unchanged from today. Applies to any
  run where `TEST_PARALLEL_GROUP` is unset (plain `mix test`, or a single-file
  `mix test test/letflow/engine_concurrency_test.exs`). No evidence motivates changing
  this regime's bound, so it doesn't change.
- `@ac1_timing_multiplier_parallel` — value **60**. Applies only when
  `System.get_env("TEST_PARALLEL_GROUP")` is non-nil (a real
  `scripts/test_parallel.sh` partition). Derivation, not a guess: the worst *observed*
  ratio under real 16-way load is 34.0x; 60 gives roughly 1.75x headroom above that
  observed worst case (comfortably clears both 34.0x and 29.42x with margin for
  additional variance not yet observed), while sitting at only 60% of the ~100x
  (`@instance_count`) signature a genuine global-lock regression produces — i.e. a real
  regression would still overshoot this threshold by ~40 points, not graze it. This is
  the same "state the derivation, don't just pick a number" discipline the rejected
  option (1) was rejected for skipping.

Both are read once at compile/module-attribute-evaluation time (`Mix.env()`-style env
read, matching `config/test.exs`'s existing use of `System.get_env("TEST_PARALLEL_GROUP")`
— no new env-reading mechanism is introduced).

### 3.2 Selection logic

The test selects `@ac1_timing_multiplier_parallel` when
`System.get_env("TEST_PARALLEL_GROUP")` is present (non-nil, any value — the group's
identity does not matter, only its presence), else `@ac1_timing_multiplier_default`.
This mirrors `config/test.exs`'s existing `case System.get_env("TEST_PARALLEL_GROUP") do
nil -> ...; group -> ... end` shape exactly (same env var, same presence-check pattern) —
no new convention introduced.

### 3.3 Override escape hatch (matches decision 0009's knob pattern)

Add one additional override, read before either default applies:
`TEST_AC1_TIMING_MULTIPLIER` — if set, its value is used unconditionally (regardless of
`TEST_PARALLEL_GROUP`), letting a future operator retune without a code edit — the same
escape-hatch precedent `TEST_MAX_CONNECTIONS`/`TEST_CONNECTION_HEADROOM`/
`TEST_MIN_POOL_SIZE` set in decision 0009 for this same class of problem ("behavior must
differ across `mix test` vs. `scripts/test_parallel.sh`, and a future host/operator
needs to retune it without touching test source"). This is also the concrete mechanism
that exercises OQ2's "expected tuning latitude" grant from the REQ-055 design doc, going
forward, without needing another design-doc cycle for a pure numeric retune.

**Correction (post CODE-DESIGN-VALIDATOR review):** an earlier revision of this section
claimed decision 0009's own knobs are unvalidated. That was checked against the actual
shipped source and is **wrong** — `scripts/test_parallel.sh:124-127` explicitly
regex-validates `TEST_MAX_CONNECTIONS` (`printf '%s' "$max_conn" | grep -Eq
'^[1-9][0-9]*$'`) and exits 1 with a named error message
(`"test_parallel: ERROR TEST_MAX_CONNECTIONS='$max_conn' is not a positive integer"`)
before using it in the pool-size budget arithmetic. Decision 0009's actual precedent is
therefore: **validate an env knob that feeds a bound/arithmetic comparison, with a clear
named-value error message** — not "trust it as-is." `TEST_AC1_TIMING_MULTIPLIER` feeds
exactly that kind of comparison (the AC1 assertion's multiplier), so it follows the same
precedent, not the opposite of it.

`TEST_AC1_TIMING_MULTIPLIER`, when set, MUST be validated as a positive integer before
use, at the same point the multiplier is selected (§3.2), mirroring
`test_parallel.sh`'s own style and message shape:
- Accept only strings matching `^[1-9][0-9]*$` (same pattern `test_parallel.sh` uses for
  `TEST_MAX_CONNECTIONS` — positive integer, no leading zero/sign/decimal).
- On a non-matching value, fail loudly and immediately (test setup, not a silent
  fallback to a default) with a message naming the bad value, e.g.
  `"TEST_AC1_TIMING_MULTIPLIER='<value>' is not a positive integer"` — same message
  shape as `test_parallel.sh`'s own `TEST_MAX_CONNECTIONS` error, substituting the
  variable name.
- On a valid value, use it unconditionally as the multiplier (§3.3's original rule,
  unchanged) — this validation only rejects malformed input, it does not change what a
  valid override does.

### 3.4 Assertion failure message

The `assert` gains an explicit message interpolating the computed ratio
(`concurrent_micros / baseline_micros`), the multiplier actually used, and whether
`TEST_PARALLEL_GROUP` was set — so a future failure's `mix test` output states the ratio
and regime directly, rather than requiring the reader to recompute
`concurrent_micros / baseline_micros` from the two raw values by hand (both original
ISS-0260 reports above had to do exactly that by hand). This is message text only, not a
change to what is asserted.

### 3.5 What does NOT change

- The correctness assertions in the same test (`{:ok, %{instance_status: :completed}}`
  per result, per-instance `InstanceProjection` corruption checks) — untouched.
- `baseline_micros`'s measurement method (single freshly-started instance, measured
  immediately before the concurrent batch, outside `start_n_instances!/3`'s own timed
  span) — untouched; the flake is in the *comparison*, not the measurement.
- AC2/AC4/AC5 — untouched, no timing assertion exists in those cases.
- `lib/letflow/engine.ex`, `InstanceProjection`, `Letflow.Engine.Reconstruction` — untouched.

## 4. Detection-power statement (explicit, per this run's hard constraint)

A genuine reintroduced global lock/singleton serializer still produces a ratio near
`@instance_count` (~100x, per §3.4's own original reasoning, unchanged by this fix). Under
**both** regimes this fix produces, ~100x clears the applicable threshold decisively:
- Plain `mix test` (`@ac1_timing_multiplier_default = 30`, unchanged): ~100x vs. a 30x
  ceiling — same detection margin as the original, unmodified design.
- `scripts/test_parallel.sh` N-way (`@ac1_timing_multiplier_parallel = 60`): ~100x vs. a
  60x ceiling — a real regression still overshoots by roughly 40 points/~1.7x, not a
  near-miss. The parallel-mode ceiling was derived (§3.1) specifically to leave that
  margin, not merely to clear observed noise with the smallest number that works.

No regime this fix introduces has a multiplier anywhere near the ~100x regression
signature, so the assertion's stated purpose — catching an accidentally-reintroduced
global lock — is preserved in both regimes, not weakened in either.

## 5. Required update to `req-055-concurrent-instance-isolation.md`

Per this run's own constraint ("keep the design doc's own reasoning honest... don't just
change a number without updating why"), CODE-DESIGNER (this doc) records the required
edit for ELIXIR-DEV/DOC-UPDATER to apply to
`lib/letflow/design/req-055-concurrent-instance-isolation.md`:

- §3.4 Case AC1's "No-cross-contention" bullet (lines ~345-356): update "some multiple
  (e.g. 3x)" / "~1-3x" language to reflect the constants that actually shipped after
  TEST-RUNNER's own tuning (30x baseline, already in the test as of REQ-055's original
  implementation — the "3x" text in that bullet was already stale relative to the
  shipped 30x before this issue; this fix is a second, independent tuning event on top of
  that, this time also splitting the value in two per load regime) — and note that the
  threshold is now regime-dependent (`TEST_PARALLEL_GROUP`-gated), pointing to this design
  doc for the specific constants and their derivation.
- §6 OQ2 (lines ~492-500): append a note that the "judgment call, not a value taken from
  any existing precedent" multiplier has since been (a) measured against real
  `scripts/test_parallel.sh` 16-way contention (ISS-0260, two independent runs, 34.0x and
  29.42x observed) and (b) split into a load-aware pair of constants per this design doc,
  exercising exactly the "expected tuning latitude" OQ2 granted — this is tuning within
  that latitude, not a reopening of REQ-055's design.

This is a documentation-text edit only (prose describing rationale), not implementation
code, and is in scope for ELIXIR-DEV to apply alongside the test-file change since both
land in the same PR.

## 6. Acceptance-criteria coverage

| ISS-0260 diagnosis element | design element addressing it |
|---|---|
| flake is a wall-clock proxy issue, not a correctness issue | §3.5 — correctness assertions untouched |
| must be justified against precedent/measured data, not arbitrary (option 1's risk) | §3.1 — 60x derived from observed 34.0x worst case + explicit headroom, not guessed |
| direct precedent for load-awareness (`TEST_PARALLEL_GROUP`, decision 0009) | §2 (2) — cites both; §3.2/§3.3 reuse both mechanisms unchanged |
| must not weaken detection of a real global-lock regression (option 3's risk) | §4 — explicit per-regime margin statement |
| small, scoped, test-infrastructure only | §"Scope" header; §3.5 |
| honest update to req-055 doc's own rationale if touched | §5 |

## 7. Open questions for CODE-DESIGN-VALIDATOR / TEST-DESIGNER

- **OQ-A:** `@ac1_timing_multiplier_parallel = 60` is derived from exactly two data
  points (34.0x, 29.42x). If TEST-RUNNER's own Step-4 run (this issue's regression test,
  ideally executed for real under `scripts/test_parallel.sh` per this repo's own
  precedent for verifying timing-sensitive fixes) shows a third data point closer to 60x
  than to 34x, that is grounds to raise the constant further under the same
  derivation method (§3.1) — not evidence the load-aware *shape* of the fix is wrong.
  Flagged explicitly rather than silently picked, per this run's own anti-guessing
  constraint.
- **OQ-B — resolved, not open:** `TEST_AC1_TIMING_MULTIPLIER` MUST be validated as a
  positive integer (§3.3) before use, with a named-value error message on rejection.
  This corrects an earlier draft of this doc, which claimed decision 0009's knobs are
  unvalidated and used that as grounds to skip validation here — that claim was checked
  against `scripts/test_parallel.sh:124-127` and found false: `TEST_MAX_CONNECTIONS` is
  explicitly regex-validated there with exactly this style of error message. §3.3 now
  follows that actual precedent. TEST-DESIGNER should include an explicit
  invalid-value test case (e.g. `TEST_AC1_TIMING_MULTIPLIER=abc` or `"-1"`) asserting
  the named error, mirroring however `test_parallel.sh`'s own `TEST_MAX_CONNECTIONS`
  validation is (or isn't) covered today.
