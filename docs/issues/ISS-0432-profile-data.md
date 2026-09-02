# Engine profiling, 2026-09-03 (ORCH-adhoc, 16-core Windows host, Docker Desktop Postgres)

| Measurement | Value | Method |
|---|---|---|
| Graph.from_map, 7-node graph | 2.8 us | 2000 iters, warmed |
| Graph.from_map, 22-node graph | 6.9 us | 2000 iters, warmed |
| Graph.from_map, 52-node graph | 17.3 us | 2000 iters, warmed |
| ETS lookup (read_concurrency) | 0.137 us | 100k iters |
| Repo.query!("SELECT 1") from BEAM | 1186-1436 us | 500 iters x3, warmed conn |
| Same query INSIDE the container (psql) | 0.110-0.113 ms | psql \timing, 3 runs |
| Repo.transaction with 3 queries | 6476 us | 50 iters |

## Conclusions

1. **Graph parse is NOT a bottleneck.** 17 us against a 1300 us round trip =
   ~1.2% of a single DB call, ~0.26% of a 5-round-trip transaction.
   An ETS graph cache would save microseconds against milliseconds. My own
   proposal #1 is REFUTED by this measurement.

2. **~92% of every DB call is host<->container network overhead**, not
   Postgres and not the BEAM. 0.11 ms in-container vs 1.3 ms from the BEAM
   on the same machine. This is Docker Desktop on Windows (port-forwarded
   5432->5462), a LOCAL DEV ARTIFACT. It inflates every timing measured on
   this host today, including the 2259 ms schema provisioning in ISS-0427
   (52 migrations x ~5 round trips each is dominated by this, not by DDL).

3. **The real lever is ROUND-TRIP COUNT, not per-call speed.** Anything that
   removes a round trip is worth ~1.3 ms here (and ~0.11 ms on a properly
   co-located deployment). Anything that speeds up BEAM-side computation is
   worth microseconds. This is the ratio that should drive optimisation
   choices.
