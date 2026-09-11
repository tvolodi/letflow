# ISS-0601: `SandboxPoolTest` RT-6 (death path c) schema-drop-wait flake, take 2 — design

## Status

Fix design for issue #1248 (queue task 601), branch `fix/ISS-0601-20260911`.
Scope: **test-only**. No `lib/letflow/sandbox_pool.ex` change.

## Restated problem

RT-6 ("death path c", `test/letflow/sandbox_pool_test.exs:1085-1125`) flunked
once during ISS-0600's own full-suite verification run, with the exact
ISS-0590-era message:

```
expected schema ... to be dropped by SandboxPool's owner-crash reclaim, but
it still exists in information_schema.schemata
```

ISS-0590 (same day, earlier) added the `wait_until_schema_dropped/2` call at
line 1119 specifically to close this race. That call is confirmed present
and DID run. It lost the race anyway, once, under heavier full-suite
Postgres/DDL contention than whatever run validated ISS-0590's fix.
REVIEWER's immediate targeted re-run of just this test did NOT reproduce —
consistent with a genuinely slow-but-eventually-completing race, not a
stuck or permanently broken one.

## What `wait_until_schema_dropped/2` actually bounds today

`test/letflow/sandbox_pool_test.exs:176-198`:

```
defp wait_until_schema_dropped(schema_name, timeout_ms \\ SandboxPool.release_call_timeout())
```

`SandboxPool.release_call_timeout/0` (`lib/letflow/sandbox_pool.ex:265-266`)
returns `provision_timeout_ms/0`, default `44_000` ms
(`@default_provision_timeout_ms`, `lib/letflow/sandbox_pool.ex:147`). Per
that module's own moduledoc ("Two budgets" section,
`lib/letflow/sandbox_pool.ex:85-122`), this number is a **caller-side
allowance for one production `release/2` call** — "one provisioning plus
one DROP" — measured at 441-601 ms in practice, i.e. the 44_000 ms budget
already carries roughly 70-100x headroom over the real cost of a *single*
uncontended provision+drop cycle. It was never calibrated against, or with
any awareness of, N concurrent `SandboxPoolTest` processes all issuing
`CREATE SCHEMA` / `DROP SCHEMA ... CASCADE` against the same Postgres
instance at once, which is the actual condition ISS-0600's full-suite run
exercises. A full-suite run is a categorically different contention regime
from the single-call production scenario the number was derived for, so
"44_000 ms proved insufficient once, under heavier contention" is
consistent with the budget's own documented derivation rather than a
surprise.

## Confirming the crash/cleanup path itself is not the bug

Traced `lib/letflow/sandbox_pool.ex`'s crash-cleanup path
(`handle_info({:DOWN,...}, ...)` clause B case 1 at lines 461-477,
`handle_worker_death/1` at lines 743-762, `pump/1` at lines 602-619,
`drop_schema/1` at lines 976-989) end to end:

- Case 1 (worker Task died without returning) synchronously, within the
  same `handle_info/2` invocation, both clears `in_flight` to `nil` **and**
  enqueues the compensating `{:drop, purpose: :orphan}` op
  (`handle_worker_death/1`), then calls `pump/1`, which immediately
  dequeues that op and dispatches it as a **new** async
  `Task.Supervisor.async_nolink/3` — setting `in_flight` non-nil again
  before the callback returns.
- `pool_drained?/1` (`in_flight == nil` and empty `db_queue`) therefore
  cannot become true until that second, drop-task's own async execution
  completes and the pool has received and processed its result message
  (the ordinary Task-completion clause, not the `:DOWN` clause) — i.e.
  `wait_until_pool_state(pool, ..., &pool_drained?/1)` (RT-6 line
  1110-1111) already is a real, message-passing synchronization point on
  the drop having *run to completion from the worker Task's own
  perspective*, not a bookkeeping-only proxy that can turn true before the
  `DROP SCHEMA` statement itself has even executed.
- `drop_schema/1` (lines 976-989) already retries once on a transient
  Postgrex/DBConnection error (ISS-0536) and returns `{:error,
  :release_failed}` only if both attempts raise — it does not silently
  swallow a hang, and nothing in this path loops, blocks indefinitely, or
  skips issuing the `DROP SCHEMA` statement.
- ISS-0590's own diagnosis (restated in its design doc, treated as
  authoritative and not re-litigated here) is that the residual gap is
  between "the pool's bookkeeping has observed the drop Task's own
  completion" and "the drop is visible to a *different* Postgres
  connection's fresh query" — a real but bounded ordering/visibility gap,
  not a defect in the compensating-drop logic itself.

Conclusion: no `lib/letflow/sandbox_pool.ex` bug. This is a test-patience
(deadline-sizing) problem, not a correctness problem, exactly as ISS-0590
already established for the underlying mechanism — ISS-0601 is about the
bound ISS-0590's own fix chose, not about that fix's shape.

## Chosen direction: (a) raise the timeout — not (b) a different signal

Rejected (b) (NOTIFY/LISTEN or some other completion signal) because:

- `wait_until_schema_dropped/2` already polls the single most-authoritative
  signal available for what RT-6 is actually asserting: the literal
  Postgres catalog fact the test's own `refute MapSet.member?(final,
  o_schema)` depends on. There is no more-real signal to switch to for
  *that* fact — the only way to know a schema is gone from
  `information_schema.schemata` on this connection is to ask this
  connection.
- The pool-internal signal one layer up (`pool_drained?/1` /
  `wait_until_pool_state/3`) is already consulted first, and per the trace
  above is already a genuine cross-process synchronization point (Task
  completion message processed by the pool) — not something that itself
  needs replacing.
- A bespoke NOTIFY/LISTEN would require a `lib/letflow/sandbox_pool.ex`
  production-code change (`drop_schema/1` would need to emit it) whose
  only consumer would be this one test file. That is a materially larger,
  riskier change than this MINOR-severity test-infra flake justifies, and
  it would not even change the actual mechanism being waited on (Postgres
  DDL commit-then-cross-connection-visibility) — it would only change how
  the test learns the fact, at the cost of touching production code for a
  test's benefit.
- The situation matches a slow-but-terminating race (confirmed by
  REVIEWER's immediate, successful re-run), which is exactly the case a
  larger bounded deadline is the right, minimal, standard tool for — the
  same shape of fix ISS-0590 itself used, and the same principle
  `release_call_timeout()`'s own moduledoc already documents (a budget
  sized from measurement, revisited if the measured regime changes).

## Exact changes

All four changes are confined to `test/letflow/sandbox_pool_test.exs`.

### 1. Widen `wait_until_schema_dropped/2`'s default deadline

At line 178, change the default `timeout_ms` expression from

```
timeout_ms \\ SandboxPool.release_call_timeout()
```

to

```
timeout_ms \\ SandboxPool.release_call_timeout() * 2
```

New default: `88_000` ms (with `provision_timeout_ms/0` at its current
`44_000` default). Still derived from the one existing single source of
truth every other bound in this file uses (no second, independently
drifting magic number is introduced) — only the multiplier is new, and it
is applied at the one call site that needs it rather than by changing
`SandboxPool.release_call_timeout/0` itself (that function's production
meaning — one caller's `GenServer.call/3` budget for `release/2` — is
correct as-is and must not be inflated for a test-only concern).

Rationale for `* 2` specifically, not a larger or smaller multiplier:

- The single observed data point is "exceeded `44_000` ms once, under
  full-suite contention, then succeeded immediately on an isolated
  re-run" — evidence of a slow-but-bounded race, not evidence of a stall
  needing an order-of-magnitude larger ceiling or an unbounded wait.
- `44_000` ms already carries ~70-100x headroom over the measured
  uncontended cost (441-601 ms); doubling it gives a full second
  independent multiple of that already-generous budget as slack for
  cross-test contention specifically, without moving to an unbounded
  (`:infinity`) wait that would let a genuinely-broken future regression
  hang the suite instead of failing it.
- This changes nothing about the common case: the poll (`poll_until_schema_dropped/2`,
  lines 183-198, unchanged) still returns via its `:ok` branch the instant
  `schema_exists?/1` goes false, typically well under a second — the
  larger ceiling only matters on the rare run this issue is about.

This one-line change affects both existing call sites of
`wait_until_schema_dropped/2` (RT-6 at line 1119, and the ISS-0048 test
"a killed owner's claim is reclaimed..." at line 461) identically, since
neither passes an explicit `timeout_ms` override today. This is
deliberate, not incidental: both call sites wait on the exact same
underlying mechanism (compensating `DROP SCHEMA` after a crash, then
cross-connection visibility of that drop) and are equally exposed to the
same full-suite contention regime, even though only RT-6 has been observed
to flake so far. Bumping the one shared default is a smaller and more
consistent diff than adding a RT-6-only override, and pre-empts the
identical latent risk in the ISS-0048 test rather than leaving it for a
future ISS-06xx to rediscover independently.

### 2. Remove ExUnit's own 60_000 ms per-test ceiling as a competing bound, for these two tests only

`test/test_helper.exs`'s `ExUnit.start(exclude: [...])` call
(`test/test_helper.exs:52`) carries no `:timeout` option, and no
`@moduletag timeout: ...` exists anywhere in
`test/letflow/sandbox_pool_test.exs` today (confirmed by search) — so
every test in this file runs under ExUnit's built-in default per-test
timeout of `60_000` ms, a number sized for nothing in particular about
this file.

Both `wait_until_pool_state/3` (lines 718-725, deadline also derived from
`SandboxPool.release_call_timeout()`, i.e. `44_000` ms today, unchanged by
this fix) and, after change 1 above, `wait_until_schema_dropped/2`
(`88_000` ms) can each individually approach or exceed their own bound
before flunking. RT-6 calls both, sequentially, in the same test
(`wait_until_pool_state` at line 1110-1111, then `wait_until_schema_dropped`
at line 1119) — so RT-6's own worst-case internal wait time is now
`44_000 + 88_000 = 132_000` ms, comfortably past ExUnit's generic `60_000`
ms default. Left unaddressed, that mismatch would mean ExUnit's default
timeout fires FIRST on a sufficiently contended run, killing the test with
a generic `ExUnit.TimeoutError` before our own, intentionally-bounded,
clearly-worded `flunk/1` message ever gets a chance to run — trading a
diagnostic failure for an opaque one, and silently defeating the entire
point of widening the internal deadline in change 1.

(This mismatch is not new — `wait_until_pool_state` alone was already
capable of approaching `44_000` ms pre-existing this fix, and RT-6 already
stacked it before `wait_until_schema_dropped`'s prior `44_000` ms bound,
for a pre-existing worst-case sum of `88_000` ms already past the `60_000`
ms default. It has apparently just never been hit in practice. Change 1
makes the collision meaningfully more likely by construction, so it must
be addressed together with change 1, not left as a separate latent bug —
see "Explicitly not changing" below for why this design does not also
sweep the rest of the file for the same pre-existing latent pattern.)

Add, immediately above each of the two `test "..."` lines that call
`wait_until_schema_dropped/2`:

```
@tag timeout: :infinity
```

- Immediately above `test "RT-6 (death path c): ..."` (line 1085).
- Immediately above `test "a killed owner's claim is reclaimed: schema
  dropped and quota slot freed for a subsequent claim/2"` (line 421).

`:infinity` here does not make either test able to hang forever in
practice: `wait_until_schema_dropped/2` (`88_000` ms) and
`wait_until_pool_state/3` (`44_000` ms) are still both individually
bounded and will each still `flunk/1` with their own specific, diagnostic
message on genuine expiry — `@tag timeout: :infinity` only removes
ExUnit's redundant, badly-timed, non-diagnostic outer ceiling from racing
those two well-reasoned inner ones. Every other test in this file keeps
ExUnit's default `60_000` ms unchanged — this tag is added to exactly the
two tests whose own internal bounds can legitimately exceed it.

### 3. Poll interval unchanged

`poll_until_schema_dropped/2`'s `Process.sleep(5)` (line 195) is untouched.
At `88_000` ms that is up to ~17_600 iterations of a single, cheap
`information_schema.schemata` query — granularity was never the
bottleneck (the flunk fired at the OLD, 8_800-iteration-capacity deadline,
not from running out of poll attempts at a fixed interval), so there is no
reason to change it.

### 4. `SandboxPool.release_call_timeout/0` itself unchanged

Not touched. It remains correctly scoped to its actual production meaning
(one caller's `release/2` budget) per its own moduledoc — this fix layers
a test-only multiplier on top of it at the one call site that needs more
headroom, rather than inflating the shared production-facing budget for a
test-suite-contention concern that has nothing to do with any real
`release/2` caller.

## Scope confirmation

**Confined to `test/letflow/sandbox_pool_test.exs`.** No
`lib/letflow/sandbox_pool.ex` or `priv/repo/migrations/` change. The
crash/cleanup path was already traced end-to-end above and shows no gap;
the only thing this design changes is how long two tests are willing to
wait for a real, already-correct, eventually-consistent fact to become
observable under heavier-than-usual Postgres contention, plus removing an
unrelated fixed ExUnit ceiling that would otherwise silently race the
widened wait.

## SECURITY-REVIEWER scope

**Out of scope**, for the same reasons ISS-0590 was routed past it: this
change touches only `test/letflow/sandbox_pool_test.exs` (a default-value
tweak on one existing private helper's optional argument, plus two
`@tag timeout: :infinity` annotations) and touches no tenant-data path —
no API route, no migration, no secrets handling, no response shaping, and
no `lib/letflow/` production code at all
(`security-invariants.md`'s INV-1..INV-8 gate on changes to those paths).
ORCH should route this WF-03 straight from TEST-DESIGNER/TEST-RUNNER
through REVIEWER (idiom check on the multiplier and the two tags) without
a SECURITY-REVIEWER stop, consistent with the ISS-0590 precedent this
issue is a direct sequel to.

## Explicitly NOT changing

- `lib/letflow/sandbox_pool.ex` — confirmed correct end-to-end by this
  design's own trace (see "Confirming the crash/cleanup path itself is
  not the bug" above); no edit.
- `SandboxPool.release_call_timeout/0` / `provision_timeout_ms/0` — kept
  exactly as-is; this fix multiplies the derived value at the one test
  call site that needs headroom, it does not touch the shared,
  production-facing function.
- `wait_until_pool_state/3` / `poll_pool_state/4` (lines 713-741) — left at
  its existing `SandboxPool.release_call_timeout()` (`44_000` ms) deadline.
  No evidence implicates it: the observed flunk text
  ("expected schema ... to be dropped ... but it still exists") is emitted
  only by `poll_until_schema_dropped/2` (line 189-192), never by
  `poll_pool_state/4`'s own message (line 735), so `wait_until_pool_state`
  was not what timed out in the reported flake. Widening it without
  evidence would only enlarge this fix's blast radius for no demonstrated
  benefit.
- The rest of `test/letflow/sandbox_pool_test.exs`'s tests that do NOT call
  `wait_until_schema_dropped/2` — their ExUnit `60_000` ms default is left
  alone; only the two tests whose own internal bounds can now legitimately
  exceed it get `@tag timeout: :infinity`.
- The 5ms poll interval in `poll_until_schema_dropped/2` — unchanged; not
  the bottleneck (see change 3 above).
- `poll_until_schema_dropped/2`'s flunk message text — unchanged; still
  accurate and still fires on genuine expiry of the new, larger deadline.

## Open questions

1. **Pre-existing latent ExUnit-ceiling collision elsewhere in this file.**
   `wait_until_pool_state/3` alone (`44_000` ms) is used by several other
   tests in this file at their default ExUnit `60_000` ms ceiling with no
   `@tag timeout` override, and some of those tests stack it with other
   waits of their own (e.g. `claim_rendezvous_timeout/1`,
   `@rendezvous_slack_ms`-bounded `assert_receive`s). This design does not
   audit or fix that broader, pre-existing pattern — it only adds
   `@tag timeout: :infinity` to the two tests this specific fix's own
   change (widening `wait_until_schema_dropped/2` to `88_000` ms) newly
   pushes past the default. Whether the rest of the file has similar
   latent exposure is a separate question worth a dedicated pass, not
   folded into this MINOR test-timing fix.
2. **Whether `* 2` is the right permanent multiplier long-term.** This
   design picks `* 2` from one data point plus the documented ~70-100x
   headroom `release_call_timeout()` already carries for the uncontended
   case, not from a controlled measurement of full-suite-contention DROP
   SCHEMA latency (per this task's own scope instruction, no live
   experimentation/repeated-run reproduction was performed to avoid
   burning time for low-confidence signal). If this same flake recurs
   again at the new `88_000` ms bound, that would be real evidence the
   contention regime is worse than a 2x multiplier covers, and would
   argue for either a further-widened bound or reopening the "does a
   genuine `lib/` slowdown exist" question — not for another blind
   multiplier bump.
