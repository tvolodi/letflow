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
