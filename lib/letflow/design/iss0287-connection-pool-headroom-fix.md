# ISS-0287 — mid-run Postgres connection-pool-exhaustion fix design

**Status:** design, awaiting CODE-DESIGN-VALIDATOR.
**Run:** WF03-ISS0287-20260823, branch `feature/WF03-ISS0287-20260823`.
**Scope:** resource-budgeting only — `scripts/test_parallel.sh`'s pool-size clamp
formula (Step 1.5), plus an addendum to
`docs/migration/decisions/0009-test-parallel-pool-sizing.md`.
**Explicitly out of scope (per the diagnosis and the dispatching handoff):**
`test/support/tenant_schema_reaper_test.exs` and `test/letflow/engine_concurrency_test.exs`
— both files' connection behavior is deliberate and load-bearing for their own
acceptance criteria (ISS-0110's liveness guard, REQ-055/EE-12 AC1/AC4's genuine
cross-partition parallelism). No implementation code below — formulas, constants,
and prose only.

---

## 0. Sources read for this design

- `docs/issues/ISS-0287.yaml` (full) — ISSUE-FIXER's diagnosis, restated in the
  dispatching handoff's Background section and not re-derived here.
- `scripts/test_parallel.sh` (full) — current Step 1.5 clamp formula, its existing
  three knobs (`TEST_MAX_CONNECTIONS`, `TEST_CONNECTION_HEADROOM`,
  `TEST_MIN_POOL_SIZE`), and the ISS-0194/ISS-0219/ISS-0222/ISS-0217 notes already
  documented inline.
- `docs/migration/decisions/0009-test-parallel-pool-sizing.md` (full) — the locked
  decision this design adds an addendum to, including its "why three separate env
  knobs" rationale (§ "Why three separate env knobs...") and its own N=16
  verification arithmetic.
- `test/support/tenant_schema_reaper_test.exs:270-320` (ISS-0110 liveness-guard
  test) — confirms the raw `Postgrex.start_link/1` connection is opened outside
  `Letflow.Repo`'s pool, closed via `on_exit`, and (per grep across `test/` for
  `Postgrex.start_link`) is the **only** such raw connection anywhere in the suite.
- `test/letflow/engine_concurrency_test.exs:1-40,292-310` (moduledoc + AC1
  describe block) — confirms `:auto` sandbox mode and the deliberate full-pool
  saturation via 100 concurrent `Task.async` bodies.
- `lib/letflow/design/iss0260-ac1-timing-flake.md` — read for this repo's own
  precedent on distinguishing "real contention noise under `test_parallel.sh`'s
  full-parallelism mode" from a correctness regression; not itself in scope here,
  cited only as a related prior fix in the same file.
- `docs/agents/instructions/core-directives.md` — in particular "A
  `docs/migration/decisions/` record is never overridden by anything above it" (an
  addendum, not a silent rewrite, is required) and "Never Satisfy a Gate by Editing
  What It Measures" (the fix must genuinely widen the accounted-for margin, not
  just relabel the existing shortfall).
- `docs/anti-patterns.md` (partial — first ~880 lines; no entry found specific to
  connection-pool arithmetic beyond what ISS-0287/0009/0194/0219/0222 already
  document).

---

## 1. Root cause, restated (not re-diagnosed — from the dispatching handoff)

Three independent, additive gaps, none individually sufficient to explain the
failure, together sufficient:

1. `TEST_MAX_CONNECTIONS` (default 100) is treated as the full ceiling available to
   test connections. Postgres's own `superuser_reserved_connections` (measured live
   = 3) is reserved off the top and is **never usable by the test role's regular
   connections**, so the true usable ceiling is ~97, not 100 — this was silently
   eating into the existing `TEST_CONNECTION_HEADROOM` margin rather than being
   accounted for as its own quantity.
2. `tenant_schema_reaper_test.exs`'s ISS-0110 test opens one real `Postgrex`
   connection entirely outside `Letflow.Repo`'s Ecto pool — invisible to the
   `N × TEST_POOL_SIZE` arithmetic 0009 encodes. At most 1 concurrently, closed via
   `on_exit` before the next test (confirmed above: the only such connection in the
   suite).
3. `engine_concurrency_test.exs`'s AC1/AC4 tests are the one place in the suite
   where a partition's real connection demand deliberately reaches its **full**
   budgeted `pool_size` at once (100 concurrent `Task.async` checkouts against a
   `pool_size`-capped Ecto pool, `:auto` mode) — not a typical mid-suite handful.

When (3)'s saturation in one partition coincides with (2)'s raw connection in
another partition, under (1)'s inflated notion of the ceiling, real demand can
exceed the true usable ceiling — intermittent because it depends on that timing
coincidence. This is a resource-budgeting gap in the clamp formula, not a defect in
either test file.

---

## 2. Fix shape: widen the clamp formula with two new, separately-named reservations

Keep decision 0009's chosen shape (Option B — clamp `pool_size` to fit a computed
budget, with a floor and explicit override knobs) entirely intact. Do **not** touch
`N`-derivation, `TEST_MIN_POOL_SIZE`'s meaning, or `TEST_CONNECTION_HEADROOM`'s
existing meaning (ad-hoc human/tooling connections — a `psql` session, LiveDashboard,
`iex -S mix` left open). Add two new, independently-overridable reservations rather
than folding either into an existing knob, per 0009's own stated rationale for
keeping concerns separable ("each answers a different question a future operator
might need to override independently").

### 2.1 New env knobs

| Knob | Default | What it answers | Who/what consumes it |
|---|---|---|---|
| `TEST_SUPERUSER_RESERVED` | `3` | How many of `TEST_MAX_CONNECTIONS` are reserved by Postgres itself (`superuser_reserved_connections`) and never usable by the test role's regular connections, regardless of headroom. | Postgres server config — varies by host/container, hence overridable; `3` documented as the measured value on this project's dev/test Postgres (`docker-compose`'s Postgres 16 image default). |
| `TEST_NONPOOL_CONNECTION_RESERVE` | `2` | How many connections the test **suite itself** opens outside `Letflow.Repo`'s Ecto pool at any point during a run, invisible to `N × TEST_POOL_SIZE`. | Currently exactly one source: `tenant_schema_reaper_test.exs`'s ISS-0110 raw `Postgrex.start_link/1` (measured max 1 concurrent). Default set to `2`, one above the measured maximum, so a single additional non-pooled connection introduced by a future test does not silently reopen this class of failure before this doc is updated — see §4 rationale. |

Both are plain non-negative integers, validated the same way `TEST_MAX_CONNECTIONS`
already is (`^[0-9]+$` — `0` is a legal value, e.g. a host with no
`superuser_reserved_connections` configured, unlike `TEST_MAX_CONNECTIONS` itself
which must stay positive). An explicit `TEST_POOL_SIZE` override from the caller
still bypasses all of this arithmetic, unchanged from 0009.

**Why a documented constant, not a live `SHOW superuser_reserved_connections;`
query, for `TEST_SUPERUSER_RESERVED`.** Considered and rejected as the *default*
mechanism: Step 1.5 runs before any partition's own DB connection is established,
and querying live would require the script to independently know/derive
host/port/user/password (duplicating `config/test.exs`'s own connection config) and
depend on `psql` or a DB round-trip being available in every environment this
script runs in (Windows Git Bash dev hosts and Linux CI both, per
`docs/anti-patterns.md`'s existing toolchain-availability notes for this project).
A documented, overridable constant matches the existing `TEST_MAX_CONNECTIONS`
knob's own shape (also a fact about the Postgres server, also not queried live) and
keeps Step 1.5 free of a new DB round-trip / new failure mode of its own. Flagged
as an explicit open question (§6) rather than silently decided as unimprovable.

### 2.2 New formula

Replaces the existing two-line formula in decision 0009 and in
`scripts/test_parallel.sh`'s Step 1.5 comment:

```
usable_ceiling = TEST_MAX_CONNECTIONS − TEST_SUPERUSER_RESERVED
budget         = usable_ceiling − TEST_CONNECTION_HEADROOM − TEST_NONPOOL_CONNECTION_RESERVE
computed       = budget / N                                    (integer division)
TEST_POOL_SIZE = computed, or TEST_MIN_POOL_SIZE if computed is smaller, with a WARN
```

Order of subtraction does not matter arithmetically; state it as
`usable_ceiling` first, then `budget`, for readability and to keep the
"Postgres-level ceiling" concept (§2.1 row 1) visibly distinct from the
"suite-level reservations" concept (headroom + nonpool) in both the script's own
comments and the addendum text.

**Error/clamp conditions, same shape as the existing ones (Step 1.5), extended to
the new terms:**
- `TEST_MAX_CONNECTIONS` must be a positive integer (unchanged check).
- `TEST_SUPERUSER_RESERVED` and `TEST_NONPOOL_CONNECTION_RESERVE` must each be a
  non-negative integer — malformed value is a hard `ERROR` and exit 1, matching the
  existing `TEST_MAX_CONNECTIONS` validation's style.
- If `budget < TEST_MIN_POOL_SIZE`: hard `ERROR`, exit 1 (unchanged condition,
  now naturally covering the case where the two new reservations alone consume the
  whole ceiling — e.g. a misconfigured host reporting an implausibly large
  `TEST_SUPERUSER_RESERVED`).
- If `computed < TEST_MIN_POOL_SIZE` (but `budget ≥ TEST_MIN_POOL_SIZE`): clamp to
  the floor with the existing `WARN`, message extended to name all four
  quantities (`max_connections`, `superuser_reserved`, `headroom`,
  `nonpool_reserve`) so an operator debugging a clamp sees the full accounting,
  not just two of four terms.
- The log line that reports the computed `TEST_POOL_SIZE` (currently `"computed:
  N=$N, max_connections=$max_conn, headroom=$headroom"`) must be extended to also
  report `superuser_reserved` and `nonpool_reserve`, for the same reason.

### 2.3 `scripts/test_parallel.sh` changes (description, not code)

- Step 1.5's comment block: add a short ISS-0287 note in the same style as the
  existing ISS-0194 note immediately above it, stating the two new terms and
  pointing at decision 0009's addendum (§3 below) rather than re-deriving the
  rationale inline — matching how the existing ISS-0194/ISS-0219/ISS-0222 notes
  each point at their own issue file / decision doc instead of restating.
- Two new `if [ -z "${TEST_SUPERUSER_RESERVED:-}" ]` / `TEST_NONPOOL_CONNECTION_RESERVE`
  default-assignment lines, same shape as the existing `max_conn`/`headroom`/
  `min_pool` three lines directly above the current `budget=$((...))` line.
- Two new validation blocks (regex `^[0-9]+$`, i.e. allowing `0` unlike
  `max_conn`'s `^[1-9][0-9]*$`), same shape/placement as the existing
  `max_conn` validation block.
- The `budget=$((...))` line extended to subtract both new terms.
- The `WARN`/log lines extended per §2.2's last two bullets.
- **Nothing else in the script changes** — N-derivation (Step 0), the pre-compile
  step (Step 1), partition launch/wait (Steps 2-3), and result aggregation (Steps
  4-5) are untouched, matching the "no behavioral change to either test file, pure
  resource-budgeting change to the script" scope stated in the dispatching handoff.

---

## 3. `docs/migration/decisions/0009-test-parallel-pool-sizing.md` addendum

0009 is a locked/confirmed decision record — per core-directives.md, this is an
**addition**, not a silent edit of its existing "Decision" section, matching how
`0001-web-framework.md`'s own `## Addendum (2026-08-20)` section and this repo's
`0006-identity-tables-schema-per-tenant.md` addendum both add a new section rather
than rewriting the original text. Append a new section after "## What this does not
change":

```
## Addendum (2026-08-23, ISS-0287) — superuser-reserved and non-pooled-connection
   headroom

ISS-0287 (queue task 287, GH#569): even with N=4 (ISS-0219's documented remedy for
this project's own dev hosts), a same-day full-suite run hit a mid-run,
timing-dependent `too_many_connections`/`DBConnection.ConnectionError` failure —
distinct from ISS-0194 (the original quadratic-scaling defect this decision fixes)
and from ISS-0222 (the launch-time spike noted in the script's own comments).

Root cause: the Decision above's `budget = TEST_MAX_CONNECTIONS -
TEST_CONNECTION_HEADROOM` formula treats TEST_MAX_CONNECTIONS as the full usable
ceiling. It is not: Postgres reserves `superuser_reserved_connections` (measured
live = 3 on this project's dev/test Postgres) off the top, unusable by the test
role's regular connections regardless of headroom — silently shrinking the
formula's effective margin by that amount. Separately, exactly one test in this
suite (`test/support/tenant_schema_reaper_test.exs`'s ISS-0110 liveness-guard test)
opens a real Postgrex connection outside `Letflow.Repo`'s Ecto pool entirely, so it
is invisible to the `N × TEST_POOL_SIZE` arithmetic — at most 1 concurrently,
confirmed by grep across `test/` for `Postgrex.start_link` finding no other
occurrence. Neither gap is a defect in the connections themselves: both are
deliberate and load-bearing for their own test's acceptance criteria (see
`lib/letflow/design/iss0287-connection-pool-headroom-fix.md` §1). The gap is that
the clamp formula never accounted for either quantity.

**This addendum does not reopen Option B vs. A/C/D above** — the clamp-not-hard-fail
shape stands; this only corrects two under-counted terms feeding its `budget`
computation.

Formula, extended (full derivation and per-knob rationale:
`lib/letflow/design/iss0287-connection-pool-headroom-fix.md` §2):

    usable_ceiling = TEST_MAX_CONNECTIONS − TEST_SUPERUSER_RESERVED   (default 3)
    budget         = usable_ceiling − TEST_CONNECTION_HEADROOM − TEST_NONPOOL_CONNECTION_RESERVE   (default 2)
    computed       = budget / N
    TEST_POOL_SIZE = computed, or TEST_MIN_POOL_SIZE if computed is smaller, with a WARN

Two new knobs, each answering a question distinct from the three this decision
already separates (deliberately not folded into `TEST_CONNECTION_HEADROOM`, whose
meaning — ad-hoc human/tooling connections — is unchanged):

- `TEST_SUPERUSER_RESERVED` (default 3): what Postgres itself reserves
  (`superuser_reserved_connections`), a server-config fact, not a test-suite fact.
- `TEST_NONPOOL_CONNECTION_RESERVE` (default 2): connections the test suite opens
  outside the Ecto pool, a test-suite-shape fact, not a server-config fact.

**Verification, at this decision's own documented remedy value (N=4).**
`usable_ceiling` = 100 − 3 = 97. `budget` = 97 − 10 − 2 = 85. `computed` = 85 / 4 =
21 (integer division). `TEST_POOL_SIZE` = 21 (no floor clamp: 21 > TEST_MIN_POOL_SIZE
default 2). `N × TEST_POOL_SIZE` = 84. Worst-case accounted demand — every
partition's pool simultaneously saturated (the AC1/AC4 scenario) plus the one
non-pooled connection actually observed — is 84 + 1 = 85, against a real usable
ceiling of 97: **12 connections of genuine slack**, not merely a looser-looking
number. Even under the pessimistic case of the *full* `TEST_NONPOOL_CONNECTION_RESERVE`
budget consumed (2, not just the 1 ever measured) plus the *full*
`TEST_CONNECTION_HEADROOM` ad-hoc budget consumed (10, an interactive `psql`/
LiveDashboard session concurrently open) at the same moment as full N×pool_size
saturation: 84 + 2 + 10 = 96 ≤ 97 — still inside the true ceiling by 1 connection,
which is the case this decision's own floor-and-WARN escape hatch (reduce
`TEST_PARALLEL_N`) exists for if a host needs more margin than that.

Compare to the pre-addendum formula at the same N=4: `budget` = 100 − 10 = 90,
`computed` = 90 / 4 = 22, `N × TEST_POOL_SIZE` = 88. Nominally 88 + 1 = 89 ≤ 100,
which looks safe under the (wrong) assumption that all 100 connections are usable
— but only 97 actually are, so the *effective* margin the operator believed was 10
(headroom) was actually 7 (headroom minus the unaccounted superuser reservation),
and shrinks further once the one non-pooled connection is drawn against it. That
narrowed, uncounted-for margin is what a timing coincidence between AC1/AC4's
saturation and the ISS-0110 test's connection could exhaust intermittently — this
addendum's fix is not a larger safety margin chosen because it "feels safer," it is
the same nominal margin now computed against the real ceiling.

Confirmed for N=16 (this decision's own original verification host) that the
addendum does not regress the general case: `usable_ceiling` = 97, `budget` = 97 −
10 − 2 = 85, `computed` = 85 / 16 = 5 (integer division) — identical to the
pre-addendum `computed` = 5 this decision already verified, so no behavior change
for that host's own documented case.

**What this addendum does not change.** `TEST_MIN_POOL_SIZE`'s meaning and default;
`TEST_CONNECTION_HEADROOM`'s meaning (still ad-hoc human/tooling connections only);
`N`-derivation; anything in `test/support/tenant_schema_reaper_test.exs` or
`test/letflow/engine_concurrency_test.exs` (both explicitly out of scope — see
`lib/letflow/design/iss0287-connection-pool-headroom-fix.md`'s own scope
statement).
```

---

## 4. Why `TEST_NONPOOL_CONNECTION_RESERVE` defaults to 2, not 1

The measured worst case today is exactly 1 concurrent non-pooled connection
(`tenant_schema_reaper_test.exs`'s ISS-0110 test, `async: false`, closed via
`on_exit` before the next test starts — confirmed no other test file in the suite
opens a raw `Postgrex`/non-`Repo` connection). Defaulting the reserve to exactly 1
would leave **zero** slack for a second such connection introduced by a future
test before anyone thinks to bump this constant — silently reopening exactly the
class of gap this fix exists to close, and in a way a future ELIXIR-DEV adding an
unrelated raw-connection test would have no reason to know about. Defaulting to 2
costs one connection of `budget` (worth it — see §3's slack arithmetic, still 12
connections of margin at N=4) and buys a one-connection buffer against that
specific recurrence shape. This is a judgment call, not a re-derivation from a
second measured data point — flagged explicitly rather than silently presented as
equally well-founded as the `TEST_SUPERUSER_RESERVED=3` constant, which *is* a
direct live measurement.

---

## 5. Verification ELIXIR-DEV must perform (not implementation, but the fix's acceptance bar)

1. **Arithmetic check, not just "the script runs."** After implementing, run
   `scripts/test_parallel.sh` with `TEST_PARALLEL_N=4` (unset `TEST_POOL_SIZE` so
   the clamp computes it) and confirm the printed log line reports
   `TEST_POOL_SIZE=21` with `N=4, max_connections=100, superuser_reserved=3,
   headroom=10, nonpool_reserve=2` — i.e. confirm the formula in §2.2/§3 is what
   actually ran, not merely that the run passed.
2. **Regression check on the two previously-fixed issue classes.** ISS-0194's
   quadratic-scaling defect (large `nproc`-derived N) and ISS-0222's launch-time
   spike are unaffected by this change (neither `N`-derivation nor Step 2's launch
   logic changed) — no new verification needed beyond confirming the script still
   runs cleanly at a large `TEST_PARALLEL_N` on a multi-core host if one is
   available, matching 0009's own original N=16 verification.
3. **Repeated full-suite runs at N=4, since the failure is probabilistic.** A
   single clean run does not prove the fix — ISS-0287's own filing notes an
   identical immediate rerun did *not* reproduce the original failure either. Run
   the full suite via `scripts/test_parallel.sh` (`TEST_PARALLEL_N=4`) **at least
   3 times**, back-to-back, and report each run's pass/fail and connection-related
   log output. A clean set does not retroactively prove the arithmetic in §3 —
   report the arithmetic re-derivation (step 1 above) as the primary evidence, and
   the repeated clean runs as corroborating, not the other way around.
4. **Targeted math-only re-check, cheaper than a full-suite run, usable as a fast
   sanity gate before each full run above:** with the real host's own
   `nproc`/`getconf` value (not just `TEST_PARALLEL_N=4`), recompute `usable_ceiling`,
   `budget`, and `computed` by hand from the formula in §2.2 and confirm
   `N × computed + TEST_NONPOOL_CONNECTION_RESERVE ≤ usable_ceiling` holds — the
   same inequality §3's N=4 and N=16 verifications both satisfy.
5. **Confirm `docker exec <postgres-container> psql -U letflow -d letflow_dev -tAc
   "show superuser_reserved_connections;"`** (or the project's documented
   equivalent) still reports `3` on the verifying host before relying on the
   default — if a host's Postgres reports a different value, that host must set
   `TEST_SUPERUSER_RESERVED` explicitly rather than silently trusting the default;
   report whatever value was actually observed.

---

## 6. Open questions (explicit, not silently resolved)

- **OQ-1.** Should `TEST_SUPERUSER_RESERVED` eventually be queried live (via
  `docker exec ... psql -tAc "show superuser_reserved_connections;"`, guarded by a
  `command -v psql`/`docker` availability check with a fallback to the documented
  constant) rather than only documented? §2.1 rejects this as the *default*
  mechanism for this fix, but does not rule it out as a future enhancement. Left
  unresolved here — flag for ORCH/REVIEWER if a future host's Postgres config
  drifts from the `3` default without anyone noticing to override it.
- **OQ-2.** `TEST_CONNECTION_HEADROOM` and `TEST_MIN_POOL_SIZE` are not currently
  format-validated the way `TEST_MAX_CONNECTIONS` is (no regex check on a
  caller-supplied value before it hits `$(( ))`). This design deliberately gives
  the two *new* knobs the same validation `TEST_MAX_CONNECTIONS` already has
  (§2.2), but does not retrofit validation onto the two pre-existing unvalidated
  knobs — that is a separate, smaller latent gap, out of this fix's scope; noted
  here rather than silently expanded into.
- **OQ-3.** Whether `TEST_NONPOOL_CONNECTION_RESERVE`'s default should later be
  derived mechanically (e.g. a `grep -rc Postgrex.start_link test/ | grep -v Repo`
  style check run in CI that fails if the count exceeds the constant) rather than
  hand-maintained. Not designed here — flagged as a possible follow-up if this
  class recurs a second time, matching this project's own pattern of promoting a
  documentation-only fix to a mechanical check after a second occurrence (see
  `docs/anti-patterns.md`'s 255-char ExUnit test-name entry for the precedent).
