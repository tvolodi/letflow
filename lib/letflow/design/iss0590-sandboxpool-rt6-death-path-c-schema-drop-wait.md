# ISS-0590: `SandboxPoolTest` RT-6 (death path c) schema-drop-wait flake — design

## Status

Fix design for `WF03-ISS0590-20260911`, Step 2. Scope: **test-only**. No
`lib/letflow/sandbox_pool.ex` change.

## Root cause (from ISSUE-FIXER's Step 1, restated for traceability)

`test/letflow/sandbox_pool_test.exs:1085-1125` ("RT-6 (death path c): the
provisioning worker Task crashing fails the claim without taking the pool, a
slot or a schema with it") gates its post-crash `information_schema.schemata`
check on `wait_until_pool_state(pool, "the pool drains after the worker
crash", &pool_drained?/1)` (line 1110-1111) alone, then immediately samples
`sandbox_schema_names()` (line 1117) and asserts `o_schema` is absent (line
1118).

`pool_drained?/1` is a proxy over `SandboxPool`'s *internal* GenServer state
(`in_flight == nil`, empty `db_queue`) — it becomes true as soon as the pool
has finished its own in-memory bookkeeping for the crash. The actual
compensating `DROP SCHEMA` for the half-created schema is a separate,
downstream Postgres statement (traced by ISSUE-FIXER through
`lib/letflow/sandbox_pool.ex:461-490, 603-619, 741-774, 976-985`) that can
still be in flight, or committed but not yet visible to this connection,
at the instant `pool_drained?/1` turns true. There is no gap in the
crash/cleanup code path itself — only in what this test treats as proof
that the drop has landed in real Postgres. Under contention the schemata
snapshot can be taken before the `DROP SCHEMA` commits, producing the
observed false failure (`refute MapSet.member?(final, o_schema)` seeing
`o_schema` still present).

This is the same class of bug ISS-0048 already fixed for the owner-crash-
reclaim test, and that fix's helper is directly reusable here.

## Chosen approach

**Add one call to the existing `wait_until_schema_dropped/1` helper**
(`test/letflow/sandbox_pool_test.exs:176-198` — a private, file-scoped
helper that polls `information_schema.schemata` directly via
`schema_exists?/1`, bounded by a monotonic deadline derived from
`SandboxPool.release_call_timeout()`), mirroring its existing use in the
ISS-0048 test at line 461 (`wait_until_schema_dropped(schema_name)` /
`refute schema_exists?(schema_name)` immediately after).

No new helper is invented. No `lib/` file changes.

## Exact call to add and its placement

In RT-6 (currently lines 1110-1119), between the existing
`wait_until_pool_state(...)` call and the `sandbox_schema_names()` /
`baseline` snapshot:

```
drained =
  wait_until_pool_state(pool, "the pool drains after the worker crash", &pool_drained?/1)

assert drained.in_flight == nil

# <-- INSERT HERE, before the schemata snapshot below:
wait_until_schema_dropped(o_schema)

# NO SCHEMA LEAK -- possible only because the pool pre-minted the schema name, so
# a worker that died without returning anything is still nameable.
final = sandbox_schema_names()
refute MapSet.member?(final, o_schema)
assert final == baseline
```

Concretely: insert `wait_until_schema_dropped(o_schema)` as its own
statement immediately after the `assert drained.in_flight == nil` line
(current line 1113) and before the `# NO SCHEMA LEAK` comment / `final =
sandbox_schema_names()` line (current line 1116-1117). `o_schema` is
already bound in scope from the earlier `{:provision, %{schema_name:
o_schema}} = state.in_flight.op` destructure (line 1099) — no new
variable needs introducing.

This exactly mirrors the ISS-0048 precedent's shape: pool-internal-state
wait first (there: the `:DOWN`-handler-driven equivalent isn't even
present — ISS-0048 has no `wait_until_pool_state` step, it waits on the
monitor `:DOWN` message instead, which is itself already a real
cross-process synchronization point), then `wait_until_schema_dropped`
as the direct real-Postgres gate, and only then the assertion against the
DB fact. RT-6's addition slots the DB-level wait in after its existing
pool-internal-state wait, in the same relative position ISS-0048 uses
relative to its own pre-assertion synchronization step.

No change to the `refute schema_exists?(schema_name)` line is needed in
RT-6 — RT-6 doesn't have that exact duplicate-style line; its existing
`refute MapSet.member?(final, o_schema)` / `assert final == baseline`
pair (lines 1118-1119, unchanged) already is the DB-fact assertion, and it
now runs strictly after `wait_until_schema_dropped/1` has confirmed the
drop via a fresh direct query — the ordering fix is the whole point, not a
new assertion.

## Confirmation: no `lib/` change

ISSUE-FIXER's diagnosis, which this design treats as authoritative, traced
the complete crash → compensating-drop → DB-commit chain in
`lib/letflow/sandbox_pool.ex` (lines 461-490, 603-619, 741-774, 976-985)
and found no gap: the pool always issues the compensating `DROP SCHEMA` for
a crashed worker's pre-minted schema name, and always transitions out of
`in_flight` only after that op is dispatched. The flake is entirely in this
test's observation timing, not in that code path. No `lib/letflow/` or
`priv/repo/migrations/` file is touched by this fix.

## SECURITY-REVIEWER scope

**Out of scope.** This change touches only
`test/letflow/sandbox_pool_test.exs` — a single `defp`-helper call added
to an existing test — and does not touch any tenant-data path: no API
route, no migration, no secrets handling, no response shaping, and no
`lib/letflow/` production code at all (`security-invariants.md`'s INV-1..
INV-8 gate on changes to those paths). This matches the established
pattern for this session's other pure test-timing fixes (e.g. ISS-0581's
`Poller.PollerTest` AC8 fix, also test-file-only, also routed past
SECURITY-REVIEWER as out of scope). ORCH should route this WF-03 straight
from TEST-DESIGNER/TEST-RUNNER through REVIEWER (idiom check on the added
call) without a SECURITY-REVIEWER stop, consistent with that precedent.

## Explicitly NOT changing

- `lib/letflow/sandbox_pool.ex` — confirmed correct by ISSUE-FIXER; no edit.
- `wait_until_schema_dropped/1` / `poll_until_schema_dropped/2`
  (lines 176-198) — reused as-is, no signature or behavior change.
- `wait_until_pool_state/3` / `pool_drained?/1` — kept in place; the fix
  adds a second, DB-level wait after them, it does not replace them (the
  pool-internal-state wait is still useful as a cheap first-order check
  that the pool itself has finished bookkeeping before polling Postgres).
- RT-6's other assertions (slot/pool-survival checks at lines 1121-1124) —
  unchanged.

## Open questions

None. This is a small, fully-scoped, mechanical test-file fix reusing an
already-existing, already-tested helper against its established precedent
usage in the same file.
