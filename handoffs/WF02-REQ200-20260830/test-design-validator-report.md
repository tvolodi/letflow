# TEST-DESIGN-VALIDATOR report -- REQ-200 (WF02-REQ200-20260830, Step 3b)

**Verdict: PASS.** This report covers two things: the rework-1 recheck of the single
BLOCKER raised in the original review, and the mutation-testing pass explicitly deferred
from that original review pending a working baseline.

## 1. Rework-1 recheck

**Prior FAIL (rework 0):** three tests -- "AC2 level 2", "AC2 level 3", "AC2 level 4" in
`test/letflow/routers/instances_test.exs` -- passed `actor_id: nil` to
`insert_raw_event!/2`. `Letflow.EventStore.Event.insert_changeset/2` lists `:actor_id` in
`@required_fields`, and the `events` table's `actor_id` column is `null: false` at the DB
level (`priv/repo/migrations/20260816120001_create_events.exs:80`). `Repo.insert` on such
a row returns `{:error, changeset}`, so each test's own `insert_raw_event!` helper
(which presumably raises/pattern-matches on `{:ok, _}`) would fail before the test body's
actual assertion on `actor_display_name` ever ran -- a false-positive-shaped failure that
proves nothing about the fallback logic under test.

**Fix applied (verified myself, not taken on the handoff's word):**

```
git diff e3ed5c63 723460d6 -- test/letflow/routers/instances_test.exs
```

confirms exactly three one-line changes, all `actor_id: nil` -> `actor_id:
Ecto.UUID.generate()`, at the three named tests and nowhere else in the file:

- "AC2 level 2: no actor id, metadata token_description resolves to that"
- "AC2 level 3: no actor id and no token_description, metadata actor_label resolves to that"
- "AC2 level 4: none of actor id, token_description, or actor_label -- falls to the literal \"system\""

This is a syntactically valid but non-existent user id -- it satisfies the `null: false`
constraint while still exercising "actor_id present but doesn't resolve to a real user",
which is exactly what levels 2-4 need. It is a distinct scenario from AC3's dedicated
test ("an event whose actor_id refers to a user row that no longer exists"), which uses
a real user row that is created and then `Repo.delete!`d -- a genuine miss on
`fetch_display_names_by_actor_id/2`'s batched query, rather than an id that never existed
in the first place. Both are legitimate, non-overlapping fallback-chain scenarios.

**Real re-run**, myself, via `source ~/.asdf/asdf.sh && mix test
test/letflow/routers/instances_test.exs`:

```
Finished in 41.2 seconds (0.00s async, 41.2s sync)
Result: 44 passed
```

44/44, 0 failures. Recheck: **PASS**.

## 2. Deferred mutation-testing pass

The original review declined to mutation-test against a broken baseline ("mutation
testing against a broken baseline wouldn't produce a meaningful signal"). With the fix
landed and the baseline green, that work is now done. All four mutants below were
applied directly to `lib/letflow/instances.ex`, one at a time, with the full file's test
suite (`mix test test/letflow/routers/instances_test.exs`) run against each, then
reverted via `git checkout -- lib/letflow/instances.ex` before the next -- `git status
--porcelain lib/ test/` confirmed empty after every single revert.

### (a) Collapse the actor-fallback chain -- skip token_description/actor_label, jump to "system"

Mutated `resolve_actor_display_name/3`'s `cond` to drop the `token_description` and
`actor_label` clauses entirely, leaving only the resolved-actor clause and the `"system"`
fallback.

Result: **41/44 passed, 3 failed** -- "AC2 level 2" and "AC2 level 3" failed with the
wrong resolved string (expected the metadata value, got `"system"`); a third,
unrelated-by-name test (AC5) also failed because it exercises the same path. "AC2 level
4" did not fail, which is expected and correct -- level 4's expected output is already
`"system"`, so collapsing the chain cannot change its outcome; it is levels 2 and 3 whose
job is to catch exactly this mutation, and they did.

Reverted; `git status --porcelain lib/ test/` empty.

### (b) Break deleted-user handling -- crash instead of falling through

Mutated `resolve_actor_display_name/3`'s first `cond` clause guard from `actor_id != nil
and Map.has_key?(display_names_by_id, actor_id)` to `actor_id != nil`, so a present but
unresolved `actor_id` calls `Map.fetch!/2` unconditionally instead of falling through to
the metadata-based fallbacks.

Result: **34/44 passed, 10 failed**, including:

```
10) test REQ-200 -- actor display name and description rendering AC3: an event whose
    actor_id refers to a user row that no longer exists still falls through, never
    nil/error (Letflow.Routers.InstancesTest)
```

AC3's dedicated test (the genuinely-deleted-user scenario) caught it, along with several
other tests sharing the same "actor_id present, unresolved" shape (including the three
AC2 level 2-4 tests just fixed in part 1, and AC7) -- confirming the fix from part 1 is
itself now pulling weight as a mutation-catcher, not just a passing assertion.

Reverted; `git status --porcelain lib/ test/` empty.

### (c) Break N+1 avoidance -- one query per event instead of one batched query

This is the mutation the task flagged as most important, since TEST-DESIGNER specifically
tightened this bound to `== 1` (not `<= 1`). A naive mutation to
`fetch_display_names_by_actor_id/2`'s own body (looping over already-deduped
`actor_ids`) would NOT have been a real N+1 mutation, because `timeline/2` already
dedupes `actor_id`s via `Enum.uniq()` before calling it -- for AC7's test, which uses one
shared actor across 6 events, that dedup collapses to a single id regardless of the
function body. To construct a mutation that actually reproduces a genuine N+1, I moved
the lookup call itself inside the per-event `Enum.map`, so each event calls
`fetch_display_names_by_actor_id/2` with only its own `actor_id`, bypassing the page-level
dedup entirely:

```elixir
items =
  Enum.map(page, fn event ->
    per_event_ids = if event.actor_id, do: [event.actor_id], else: []
    display_names_by_id = fetch_display_names_by_actor_id(per_event_ids, prefix)
    timeline_item(event, display_names_by_id)
  end)
```

Result: **43/44 passed, 1 failed**:

```
1) test REQ-200 -- actor display name and description rendering AC7: a page whose
   events share one actor issues at most one user-lookup query
   expected exactly one `users` lookup query for a page sharing one actor, got 6
```

Exactly the failure mode AC7's `== 1` (not `<= 1`) bound exists to catch -- 6 queries for
6 events sharing one actor. Caught.

Reverted; `git status --porcelain lib/ test/` empty.

### (d) Swap TASK_COMPLETED's description clause for INSTANCE_STARTED's

Mutated `render_description/3`'s `"TASK_COMPLETED"` clause body to return `"Instance
started by #{actor}"` (INSTANCE_STARTED's sentence) instead of `"Task #{node_id}
completed by #{actor}"`.

Result: **43/44 passed, 1 failed**:

```
1) test REQ-200 -- actor display name and description rendering AC4: INSTANCE_STARTED
   and a task-completion item render different, actor-naming sentences
   Assertion with == failed
   code:  assert completed["description"] == "Task approve completed by Grace Hopper"
```

AC4's exact-string assertion caught it.

Reverted; `git status --porcelain lib/ test/` empty.

### Final state

After the fourth revert, re-ran the full file once more as a final sanity check:

```
Finished in 42.5 seconds (0.00s async, 42.5s sync)
Result: 44 passed
```

44/44 clean, and `git status --porcelain lib/ test/` empty.

## 3. Static gates

Re-run myself, on the reverted (clean) tree:

- `mix compile --warnings-as-errors` -- clean, no output.
- `mix format --check-formatted` -- clean, no output.
- `mix letflow.lint_handoffs` -- `letflow.lint_handoffs: OK -- 0 new violations across
  1523 handoff files (25 pre-existing grandfathered, traced to ISS-0190).`

## Conclusion

The rework-1 fix is correct, minimal, and exactly matches what the original FAIL
specified. All four requested mutants were applied to the shipped logic, each was caught
by the specific acceptance-criteria test(s) it targeted, and each was cleanly reverted
with an empty `git status --porcelain lib/ test/` confirmed after every revert. Routed to
TEST-RUNNER via `handoffs/WF02-REQ200-20260830/step-04-test-runner.json`.
