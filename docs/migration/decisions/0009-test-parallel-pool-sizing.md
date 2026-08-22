# 0009 — `scripts/test_parallel.sh` per-partition pool_size vs Postgres max_connections

Status: confirmed — self-reviewed (ORCH acting alone; this execution context
cannot spawn a separate REVIEWER pass, stated explicitly per
`core-directives.md`'s No Speculation / Zero Manual Work discipline rather than
silently skipped). Owner: ORCH.

## Question

ISS-0194 (filed by RELEASE-VALIDATOR during `WF02-REQ113-20260821` Step 5
re-run): `scripts/test_parallel.sh` derives its partition count `N` from
`nproc`/`getconf`, and `config/test.exs` sizes each partition's own Ecto pool
as `System.schedulers_online() * 2`. Both numbers scale with the same
quantity (core count), so `N * pool_size` scales **quadratically** with core
count while Postgres's `max_connections` does not scale at all. Measured
2026-08-21 on this host: `nproc` = 16, so `N` = 16 and `pool_size` = 32,
wanting 512 simultaneous connections against `letflow-2-postgres-1`'s actual
`max_connections` of 100 (`docker exec letflow-2-postgres-1 psql -U letflow
-d letflow_dev -tAc "show max_connections;"`). The issue's own filing
independently measured the same class of failure at N=8/pool_size=16=128 on
the host that first hit it — the ratio is the defect, not a specific core
count.

This is not a REQ-113 script defect: the script correctly reports the real
failures/aborts it observes when connections are refused. It is a genuine
resource-budgeting gap between two independently-derived numbers that were
never checked against the shared ceiling they both draw from.

## Options considered

- **(A) Hard-fail if `N * pool_size` would exceed a configured budget.**
  Simplest to reason about, but means every host with more than ~6 cores
  (at the current `pool_size = cores*2` formula and a 100-connection
  Postgres) cannot run `test_parallel.sh` at its default N at all without
  manual intervention — a regression from REQ-113's whole point (use all
  available cores automatically).
- **(B) Clamp per-partition `pool_size` down to fit the budget, computed
  from `N` and a configured connection ceiling, with a floor.** Keeps `N`
  at its natural, fully-parallel value and instead shrinks each partition's
  own concurrency (how many of that partition's own async tests can hold a
  checked-out connection at once) just enough that the product fits.
  Degrades gracefully: a partition with a smaller pool still runs, just
  with more internal serialization among its own async tests, rather than
  failing to start.
- **(C) Reduce `N` instead of `pool_size` to fit the budget.** Rejected:
  this throws away the parallelism REQ-113 was built to add (running fewer
  partitions than available cores), where (B) throws away only some
  intra-partition concurrency, which is the smaller sacrifice for the
  common case (a fast local Postgres easily absorbing a few dozen
  connections).
- **(D) Raise Postgres `max_connections` in the dev/test `docker-compose`
  config instead of touching the script/config at all.** Rejected as the
  sole fix (though not incompatible with (B) — the `TEST_MAX_CONNECTIONS`
  knob below can reflect a raised ceiling): it doesn't scale — the ratio
  problem recurs on any host with enough cores, and it's this repo's own
  container, not something every future host running the script is
  guaranteed to have adjusted the same way.

## Decision: (B), with a floor and an explicit override escape hatch

`scripts/test_parallel.sh` now computes, unless the caller already set
`TEST_POOL_SIZE` explicitly:

```
budget       = TEST_MAX_CONNECTIONS (default 100) - TEST_CONNECTION_HEADROOM (default 10)
computed     = budget / N                                    (integer division)
TEST_POOL_SIZE = computed, or TEST_MIN_POOL_SIZE (default 2) if computed is smaller, with a WARN
```

and exports `TEST_POOL_SIZE` for every partition's `mix test` subprocess.
`config/test.exs` reads it (`System.get_env("TEST_POOL_SIZE")`) and falls
back to the original `schedulers_online() * 2` when unset — so a plain
`mix test` invocation (not run through `test_parallel.sh`) is byte-for-byte
unchanged.

**Why a floor rather than a hard failure when the budget is very tight.**
Ecto's Sandbox pool at `pool_size = 1` still functions — it serializes that
partition's own async tests onto one connection rather than deadlocking or
refusing to start. A floor of 2 keeps every host runnable at its full
natural `N`, at the cost of a WARN telling the operator the computed value
was clamped and that `N*floor` may still exceed the budget (in which case
reducing `N` via `TEST_PARALLEL_N` is the documented next step) — never a
silent, unexplained slowdown.

**Why three separate env knobs (`TEST_MAX_CONNECTIONS`,
`TEST_CONNECTION_HEADROOM`, `TEST_MIN_POOL_SIZE`) instead of one.** Each
answers a different question a future operator might need to override
independently: what the actual Postgres ceiling is (varies by host/container
config), how much of it to reserve for non-partition connections (a `psql`
session, LiveDashboard, `iex -S mix` left open), and how low intra-partition
concurrency is allowed to go before it's not worth running that partition at
all. Collapsing them into one number would force every override to
re-derive the other two from scratch.

**Verification.** With this host's real numbers (`N`=16, `max_connections`
=100, default `headroom`=10): `budget` = 90, `computed` = 90/16 = 5,
`TEST_POOL_SIZE`=5 (no clamp needed), `N*pool_size` = 80 ≤ 90. Confirmed by
running `scripts/test_parallel.sh` for real post-fix — see the run's own
handoff/PR for the quoted output.

## What this does not change

- `config/dev.exs`'s pool sizing (unaffected; `TEST_POOL_SIZE` is read only
  in `config/test.exs`).
- The N-derivation logic itself (`nproc`/`getconf`/`TEST_PARALLEL_N`
  override) — untouched, per option (B) over (C) above.
- Postgres's actual `max_connections` setting in `docker-compose` — not
  raised here; `TEST_MAX_CONNECTIONS` lets an operator tell this script
  about a raised ceiling if one is made later, but making that change is
  out of this issue's scope.

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
