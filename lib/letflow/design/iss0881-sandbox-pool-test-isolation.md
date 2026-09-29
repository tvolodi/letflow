# Design: ISS-0881 — `sandbox_pool_test.exs` schema-leak checks isolated from concurrent-partition contention

## Scope and constraints (explicit)

- **Touches only** `test/letflow/sandbox_pool_test.exs`.
- **Does not touch** `lib/letflow/sandbox_pool.ex`. Per ISSUE-FIXER's diagnosis
  (`handoffs/WF03-ISS0881-20260929/step-01-issue-fixer-diagnose.json`), the crash-handling
  path (`handle_worker_death/1`, `complete_op/3`) was read in full and refuted as a source
  of the bug: no code path re-creates a schema after dropping it, and `schema_exists?/1`
  (a scoped, single-row query under a transactional-DDL guarantee) cannot report a false
  "dropped" for a schema that still exists. The defect is entirely in this test file's own
  assertions, which read a platform-wide, unscoped Postgres snapshot
  (`sandbox_schema_names/0`) and compare it for bit-identical equality across a window
  during which up to 8 *other* test files' own `SandboxPool` usage can legitimately
  create/drop their own, unrelated `sandbox_%` schemas under `scripts/test_parallel.sh`'s
  full-contention run.
- Every call site of `sandbox_schema_names/0` and `drop_sandbox_schemas_created_since!/1`
  in the file was enumerated (grep, confirmed against source) and is addressed below —
  not only RT-6.

## Root cause recap (from ISSUE-FIXER's diagnosis, not re-derived here)

`sandbox_schema_names/0` (lines 571-582) runs
`SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'sandbox\_%'`
with no filter tying the result to this test's own pool instance or run. Every test in
this file that checks "no schema leaked" captures `baseline = sandbox_schema_names()`
before starting its own pool, then later either:

- asserts `sandbox_schema_names() == baseline` (an exact-equality claim over the *entire
  platform-wide set*), or
- asserts `refute MapSet.member?(final, <name>)` for a specific schema name this test's
  own pool minted (already immune to the race, since the name is
  `Ecto.UUID.generate()`-derived and collision-proof across partitions).

The equality form is what breaks: any of the 8 other `SandboxPool`-consuming test files
(`event_store/platform_events_test.exs`, `sandbox_pool/fixture_loader_test.exs`,
`definitions/promotion_assertion_rerun_test.exs`, `admission_test.exs`,
`routers/req077_promotion_pipeline_test.exs`, `engine/plugin_registry_test.exs`,
`sandbox_pool_call_timeout_test.exs`, `supervisor/infrastructure_test.exs`) creating or
dropping its own real schema during this test's baseline-to-final window flips the
equality even though this test's own pool behaved correctly throughout.

## Key correctness property this design relies on

`mint_sandbox_identity/0` (`lib/letflow/sandbox_pool.ex:927-935`) derives every schema
name from `Ecto.UUID.generate()` before any provisioning begins, and every test in this
file that provisions a schema already has (or, per the per-test changes below, is given)
that exact name in scope via the pool's own reported state (a `SandboxClaim`, or a
`{:provision, %{schema_name: ...}}` op peeked mid-flight) — never by re-deriving it from
`sandbox_schema_names()` itself. This means **the specific-name membership check
(`refute MapSet.member?(final, own_schema)` / `assert MapSet.member?(final,
own_schema)`) already fully identifies the one thing each of these tests' own pool could
possibly have leaked or must have created**, with zero dependence on any other partition's
concurrent activity. The blanket `final == baseline` / `sandbox_schema_names() ==
MapSet.put(baseline, own_schema)` equality checks contribute no additional real
regression-detection power beyond that: in every one of these tests the pool's scenario
(`max_concurrent: 1` or `2`, one or two known `spawn_claimer/3` calls) provisions or
attempts to provision *only* the already-named schema(s) in scope — there is no code path
by which this test's own pool could create some *other*, unnamed schema that only a
platform-wide equality check would catch. Dropping the equality form therefore removes
exposure to the race without removing any real coverage.

## 1. The exact new comparison per call site

**General rule applied throughout:** replace every `assert final == baseline` / `assert
sandbox_schema_names() == baseline` that sits alongside a specific-name check with
**nothing but the specific-name check** (delete the equality line). Where a test's
equality check is the *only* leak check present (no name captured in scope), first widen
the existing claim-result pattern match to bind `schema_name`, then replace the equality
with membership checks against the now-captured name(s). No test loses a check; several
gain a previously-implicit one made explicit.

### RT-1 (control) — lines 844-846

Current:
```
final = sandbox_schema_names()
refute MapSet.member?(final, o_schema)
assert final == baseline
```
New: delete line 846 only (`assert final == baseline`). Lines 844-845 unchanged. `o_schema`
is already bound at line 805 (`{:claimed, :o, {:ok, %SandboxClaim{schema_name: o_schema}},
...}`).

### RT-2 — line 960 (no name captured today)

Widen two existing pattern matches to bind the schema names already returned but
currently discarded:
- Line 862: `assert_receive {:claimed, :o, {:ok, %SandboxClaim{}}, _t_o}, ...` →
  `assert_receive {:claimed, :o, {:ok, %SandboxClaim{schema_name: o_schema}}, _t_o}, ...`
- Line 927: `assert {:ok, %SandboxClaim{}} = w1_result` →
  `assert {:ok, %SandboxClaim{schema_name: w1_schema}} = w1_result`

Then replace line 960 (`assert sandbox_schema_names() == baseline`) with:
```
final = sandbox_schema_names()
refute MapSet.member?(final, o_schema)
refute MapSet.member?(final, w1_schema)
```
(W2 never provisions — `w2_result == {:error, :sandbox_unavailable}` is already asserted
at line 928 — so no third name applies.)

### RT-3 — lines 985 and 995

`o_schema` is already bound (line 974). Two distinct assertions here need two distinct
replacements, because they test two different things:

- **Line 985**, `assert sandbox_schema_names() == MapSet.put(baseline, o_schema)`, is a
  *positive-presence* claim ("O's schema exists"), not a leak check — it is reached while
  O still holds its claim. Replace with a positive membership check plus a
  race-free, pool-internal check of the thing the equality was really trying to prove
  (that the killed *waiter* W never caused a second schema/slot to come into existence,
  which no platform read can prove without a name to check, but the pool's own
  bookkeeping can prove directly — the same technique RT-1 already uses at its own line
  836):
  ```
  assert MapSet.member?(sandbox_schema_names(), o_schema)
  state = :sys.get_state(pool)
  assert map_size(state.active) == 1
  ```
- **Line 995**, `assert sandbox_schema_names() == baseline` (after O is released,
  reclaimed as a fresh id and released again — O's original schema is gone, no new one is
  expected), is a genuine leak check. Replace with:
  ```
  refute MapSet.member?(sandbox_schema_names(), o_schema)
  ```

### RT-4 — lines 1027-1029

Same shape as RT-1. `o_schema` already bound (line 1013). Delete line 1029
(`assert final == baseline`) only; keep lines 1027-1028.

### RT-5 — lines 1073-1075

Same shape as RT-1. `b_schema` already bound (line 1057). Delete line 1075
(`assert final == baseline`) only; keep lines 1073-1074.

### RT-6 — lines 1125-1127 (the originally diagnosed failure)

Same shape as RT-1, and the case ISS-0881 was filed against. `o_schema` already bound
(line 1101). Delete line 1127 (`assert final == baseline`) only; keep lines 1125-1126
(`final = sandbox_schema_names()`; `refute MapSet.member?(final, o_schema)`) exactly as
they stand today.

### RT-7 — line 1204 (no names captured today)

Widen two existing pattern matches:
- Line 1163: `assert {:ok, %SandboxClaim{sandbox_id: o_id}} = SandboxPool.claim(1_000,
  pool)` → `assert {:ok, %SandboxClaim{sandbox_id: o_id, schema_name: o_schema}} =
  SandboxPool.claim(1_000, pool)`
- Line 1189: `assert {:ok, %SandboxClaim{}} = w_result` →
  `assert {:ok, %SandboxClaim{schema_name: w_schema}} = w_result`

Replace line 1204 (`assert sandbox_schema_names() == baseline`) with:
```
final = sandbox_schema_names()
refute MapSet.member?(final, o_schema)
refute MapSet.member?(final, w_schema)
```

### RT-8 — line 1273 (no names captured today)

Widen two existing pattern matches:
- Line 1221: `assert_receive {:claimed, :o1, {:ok, %SandboxClaim{sandbox_id: o1_id}},
  _t_o1}, ...` → `assert_receive {:claimed, :o1, {:ok, %SandboxClaim{sandbox_id: o1_id,
  schema_name: o1_schema}}, _t_o1}, ...`
- Line 1264: `assert_receive {:claimed, :a, {:ok, %SandboxClaim{}}, _t_a}, ...` →
  `assert_receive {:claimed, :a, {:ok, %SandboxClaim{schema_name: a_schema}}, _t_a}, ...`

Replace line 1273 (`assert sandbox_schema_names() == baseline`) with:
```
final = sandbox_schema_names()
refute MapSet.member?(final, o1_schema)
refute MapSet.member?(final, a_schema)
```

### RT-9 — lines 1295-1296

No `final`/equality assertion exists in this test (confirmed by reading it in full,
lines 1294-1343) — it only captures `baseline` to hand to its `on_exit`
`drop_sandbox_schemas_created_since!/1` teardown call. **No assertion change needed.**
See "Open question" below for the one thing this call site does still expose.

### ISS-0292 / RT-8 critical-regression test — lines 1643-1648

```
diff_order =
  sandbox_schema_names()
  |> MapSet.difference(baseline)
  |> Enum.to_list()

assert diff_order == [first_schema, middle_schema, third_schema]
```

This asserts *exact equality* of the whole diff set to a 3-element list, so a concurrent
partition adding or removing any unrelated `sandbox_%` schema in this narrow window
would change the diff's *size* and break the equality — even though the *relative order*
among `first_schema`/`middle_schema`/`third_schema` (byte-wise term order, which the
comment above this code already establishes is what determines
`Enum.reduce/3`'s real traversal order) is unaffected by any other element's presence.
Fix: filter the diff to only this test's own three known names before asserting order,
so the assertion proves exactly what the surrounding comment claims it proves (their
relative traversal order) and nothing about the platform-wide set's size:
```
diff_order =
  sandbox_schema_names()
  |> MapSet.difference(baseline)
  |> Enum.filter(&(&1 in [first_schema, middle_schema, third_schema]))

assert diff_order == [first_schema, middle_schema, third_schema]
```

## 2. Does `sandbox_schema_names/0` need a signature/behavior change?

**No. The fix is purely in how each call site compares what it already gets back.**

`sandbox_schema_names/0` returns exactly what its docstring/comment (lines 567-570)
promises: the full, current, platform-wide `sandbox_%` snapshot. That data is not wrong —
it is the right building block for a *membership* check against a name this test's own
pool minted, which is already collision-proof (UUID-derived) and needs no additional
scoping parameter to be meaningful. The defect is entirely that several call sites then
compare that snapshot for *exact equality* against an earlier snapshot, which is a claim
about the whole platform's quiescence that no single test in an async, shared-Postgres,
multi-partition suite is ever entitled to make. No call site in this design needs
`sandbox_schema_names/0` to filter, exclude, or scope its own query — every fix above is
achieved by comparing the same unscoped result against a name the test already has (or is
given, via widened pattern matches) in scope. `drop_sandbox_schemas_created_since!/1`'s
own signature is likewise unchanged (see the open question below for why a scoping change
there is deliberately *not* proposed in this design).

Confirmed `@spec`-level shapes, unchanged by this design (present as plain function
definitions with no `@spec`, matching the rest of this file's private helpers; documented
here as intent, not new type annotations to add):

```
sandbox_schema_names() :: MapSet.t(String.t())
drop_sandbox_schemas_created_since!(baseline :: MapSet.t(String.t())) :: :ok
```

## 3. New/changed function signatures

None. This design adds no new function and changes no existing function's signature or
return shape. Every change above is either (a) deleting a redundant assertion line, (b)
widening an existing `%SandboxClaim{...}`/`{:provision, %{...}}` pattern match already
present at that call site to also bind `schema_name` (a field `SandboxClaim` and the
provision op already carry — confirmed by every other call site in this file that already
does this, e.g. line 805, 974, 1013, 1057, 1101), or (c) adding a `Enum.filter/2` stage to
an existing pipeline before an existing equality assertion.

## 4. Confirmation: real-leak-detection guarantee preserved

What each surviving/added assertion still proves, per test:

- **RT-1, RT-4, RT-5, RT-6**: `refute MapSet.member?(final, own_schema)` proves the exact
  schema this test's own pool minted for this scenario is gone from real Postgres after
  the death-path/leak-check window — the whole regression this file exists to catch
  (a crashed worker/dying owner/killed queued reservation must not leave its schema
  behind). This is the assertion each of these tests already had; nothing about it
  changes.
- **RT-2, RT-7, RT-8**: gain the equivalent per-schema membership proof for every schema
  their own pool minted (previously only implicitly covered by the now-removed
  platform-wide equality) — a strict strengthening of what is checked by name, in
  exchange for removing the one line that was never race-safe.
- **RT-3**: `assert MapSet.member?(sandbox_schema_names(), o_schema)` proves O's schema
  was genuinely created; `assert map_size(state.active) == 1` proves, from the pool's own
  authoritative bookkeeping rather than a platform snapshot, that killing the parked
  waiter W did not cause a second slot/schema to come into existence — a race-free
  replacement for what the exact-equality check was actually trying to establish. The
  final `refute MapSet.member?(sandbox_schema_names(), o_schema)` proves O's schema was
  genuinely dropped on release.
- **ISS-0292/RT-8 critical-regression test**: the filtered `diff_order` still proves
  `drop_sandbox_schemas_created_since!/1`'s `Enum.reduce/3` visits `first_schema`, then
  `middle_schema`, then `third_schema` in that exact order (the premise the rest of the
  test's argument about surviving-despite-a-middle-failure depends on), and the three
  `schema_exists?/1` calls at the end (already scoped, single-row, unaffected by this
  design) still prove the critical regression itself: a deterministically-failing middle
  schema does not prevent a later schema, in the same traversal, from being dropped.

What is removed, in every case, is only the assumption that no other row exists in
`information_schema.schemata` at call time — an assumption `sandbox_schema_names/0`'s
real, documented, unscoped-by-design contract never makes and callers must not make
either, matching the precedent already set by
`lib/letflow/design/iss0348-backfill-test-isolation.md`'s identical reasoning for
`Backfill.run/1`'s aggregate count.

## Open question (flagged, not resolved here — per this role's constraint not to guess)

`drop_sandbox_schemas_created_since!/1` (lines 620-641) is used in `on_exit` teardown by
every test above, and computes its own drop-candidate set the same way the now-fixed
assertions did: `MapSet.difference(sandbox_schema_names(), baseline)`. In the same
theoretical race window ISSUE-FIXER identified, if another partition creates a new real
`sandbox_%` schema between this test's `baseline` capture and its `on_exit` callback
running, that schema would appear in this test's own diff set and this helper would
attempt to `DROP` it — a schema belonging to a still-running pool in another partition,
not merely a flaky assertion but a potentially destructive cross-partition side effect.

This design deliberately does **not** propose a fix for that here, for three reasons
ELIXIR-DEV/TEST-DESIGNER should weigh rather than have silently decided for them:

1. ISSUE-FIXER's diagnosis and both its code-reading and its 18-iteration reproduction
   attempt were scoped to the assertion race (`final == baseline`), not to this teardown
   path; no failure evidence implicates it, and this design should not expand its own
   blast radius beyond what was actually diagnosed and reproduced against.
2. A scoping fix here is a materially different risk shape than the assertion fix above:
   narrowing what this helper drops risks *weakening* its actual job — opportunistic,
   belt-and-suspenders cleanup of anything this test's own pool failed to clean up via its
   normal path — if the scoping is done incorrectly (e.g. excluding a legitimately-owned
   but not-yet-named schema).
3 . Unlike the assertion fix, a wrong fix here fails silently (a schema simply never gets
   swept) rather than loudly (a test flunks), so it deserves its own diagnose-and-design
   cycle with a reproduction attempt aimed specifically at it, rather than being bundled
   into ISS-0881's fix on the strength of a plausibility argument alone.

Recommendation: file a follow-up issue against `drop_sandbox_schemas_created_since!/1`
specifically, rather than resolving it inside this fix.
