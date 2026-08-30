# TEST-DESIGNER gap analysis — REQ-200 (WF02-REQ200-20260830, Step 3)

Cross-checked all 11 acceptance criteria in `docs/requirements.yaml`'s REQ-200 entry
against `test/letflow/routers/instances_test.exs` as it stood after ELIXIR-DEV's/
REVIEWER's pass (`git show HEAD:test/letflow/routers/instances_test.exs` at the point
this handoff was received). Read the whole file, not a sample.

## Per-AC verdict

| AC | Verdict | Notes |
|---|---|---|
| AC1 | Already complete | Seeds 4 genuinely distinct event types (`INSTANCE_STARTED`, `INSTANCE_CANCELLED`, `INSTANCE_PINS_REBOUND`, `TIMER_FIRED`), confirmed via `Enum.uniq/1` on the actual response (`assert length(event_types) >= 4`), and asserts non-blank on **every** item via a `for item <- items do` loop, not a sample. |
| AC2 | **Gap — filled** | Requirement text explicitly says "four explicit tests." The existing test proved the chain end-to-end in one combined test, keyed by `task_id`, folding AC3 in as a fifth case. Split into 4 dedicated level tests + 1 dedicated AC3 test (see below). |
| AC3 | Already complete in substance, restructured for clarity | Genuinely creates a user row, then `Repo.delete!`s it, then references its id — a real "row existed, now gone" scenario, not merely "no actor_id." This is a different scenario from AC2 level 4 (no actor_id at all) and the two must not be conflated; pulling it into its own test (rather than a 5th case bolted onto the AC2 test) makes that distinction explicit rather than implicit. |
| AC4 | Already complete | Asserts the literal exact strings for both `INSTANCE_STARTED` and `TASK_COMPLETED` descriptions, not merely inequality/non-blankness. |
| AC5 | Already complete | Asserts the exact generic-fallback string for an event type (`TENANT_CUSTOM_LUA_EVENT`) with no dedicated clause. |
| AC6 | Already complete | Checks every `TimelineEntry` member by name, plus explicit `refute` on both old field names — catches an "emit both" compromise, not just an "emit new" check. |
| AC7 | Already complete; tightened one assertion | 6 events (`INSTANCE_STARTED` + 5 `TASK_COMPLETED`), 1 shared actor — a naive per-row implementation would issue 6 `users` queries, batched issues 1. Original assertion was `<= 1`; tightened to `== 1` so the test also fails on a resolver that silently skips the lookup (a false-negative risk the original bound didn't cover — see inline comment added at the assertion). |
| AC8 | Confirmed out of scope for new tests | Purely "existing REQ-080 tests still pass." Re-read the pre-existing `"AC1 -- five read endpoints"`, `"AC2 -- pagination completeness"`, `"AC3 -- cross-tenant is the same as nonexistent"`, and `"AC6 -- permission required on every read endpoint"` describe blocks: all five of AC8's named properties (route path, permission, ascending order, cursor pagination, 404) are exercised there, unmodified by this requirement's diff. No new test needed. |
| AC9 | Process/diff-scope check, not a runtime test | "No file under `web/` added or modified" is a `git diff --stat` claim. REVIEWER's own handoff already recorded the scoped diff (`lib/letflow/instances.ex`, `lib/letflow/routers/instances.ex`, `test/letflow/routers/instances_test.exs`, design doc, handoff/registry/status-index bookkeeping only). Forcing an ExUnit test to assert on `git diff` output would be manufactured busywork per this role's own scope-test guidance, not real coverage — same reasoning as AC10. |
| AC10 | Process/diff-scope check, not a runtime test | Same reasoning as AC9: "`lib/letflow/api/authorization.ex` is not modified" is a diff-scope claim, already confirmed by REVIEWER's own `git diff main...HEAD --stat`. |
| AC11 | Process requirement, not a unit test | `mix test`/`mix compile --warnings-as-errors` passing is TEST-RUNNER's (Step 4) and the already-recorded SECURITY-REVIEWER results' (`security-review-req200-findings.md`) responsibility, not something a test file itself asserts. TEST-DESIGNER does not run tests. |

## Changes made to `test/letflow/routers/instances_test.exs`

1. Replaced the single `"AC2/AC3: all four actor fallback levels resolve, including a
   deleted user row"` test with 5 independent tests: 4 for AC2's fallback levels
   (each isolating only the inputs relevant to that level — e.g. level 2/3/4 pass
   `actor_id: nil` explicitly rather than an actor_id that merely fails to resolve, so
   a bug that treats "any non-nil actor_id" as a hit can't produce a false pass) and
   1 dedicated to AC3 (deleted user row). Every string-equality assertion the original
   test made survives unchanged in content, just relocated to its own test — nothing
   was weakened or dropped.
2. Tightened the AC7 query-count assertion from `user_query_count <= 1` to
   `user_query_count == 1`, with an inline comment explaining why (rules out a
   vacuous pass from a resolver that silently skips the batched lookup).

No other test in the file was touched. `test/specs/REQ-200.md` was written per this
role's Step 3 deliverable, documenting each AC's criterion, the test case(s) proving
it, and why each exists.

## Fixture convention compliance

Every new/restructured test calls its own `TenantFixture.provisioned_tenant!/1` with a
unique `slug_prefix` (`req200-ac2-l1` through `l4`, `req200-ac3`) — no shared or global
state, matching this file's existing convention throughout (`req079-*`, `req080-*`,
`req200-*`). Reused this file's own pre-existing `insert_raw_event!/2` and
`create_named_user!/2` helpers verbatim, no new helpers introduced.
