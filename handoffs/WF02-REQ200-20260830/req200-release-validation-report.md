# REQ-200 Release Validation Report

Agent: RELEASE-VALIDATOR
Run: WF02-REQ200-20260830
Date: 2026-08-30
Verdict: **PASS** -- all 11 acceptance criteria independently confirmed against real code and a real re-run of the suite.

This report is my own independent basis, not a copy of prior gate reports. Where I
disagreed methodologically with a prior gate (I did not), I would have said so; I did
not find anything to dispute in the chain, but I did not take any single number from
it without reproducing it myself first.

## Method

1. Read `docs/requirements.yaml`'s REQ-200 entry in full (all 11 `acceptance_criteria`,
   lines 10971-11058).
2. Read the real `lib/letflow/instances.ex` (lines 152-330) and
   `lib/letflow/routers/instances.ex` (lines 625-680) myself.
3. Re-ran `MIX_ENV=test mix test test/letflow/routers/instances_test.exs` myself: **44
   passed, 0 failures** (41.0s).
4. Re-ran the full suite via `scripts/test_parallel.sh` myself (N=8, foreground,
   blocking, no background/Monitor use): **2749/2751 passed, 2745 tests + 6
   properties, 2 failures**, both in partition 8, both
   `Mix.Tasks.Letflow.CheckToolchainTest`, both `** (ErlangError) Erlang error:
   :enoent` from `System.cmd("rustc", ["--version"], ...)`. Confirmed `which rustc`
   returns nothing in this sandbox. Confirmed via `git diff main...HEAD --stat` that
   this branch's diff does not touch `test/mix/tasks/letflow_check_toolchain_test.exs`
   or any rustc-adjacent code -- structural attribution, not count-matching.
5. Ran `mix compile --warnings-as-errors --force` myself: clean recompile of 155
   files, 0 warnings.
6. Ran `git diff main...HEAD --stat` myself and confirmed the full file list: only
   `lib/letflow/instances.ex`, `lib/letflow/routers/instances.ex`,
   `test/letflow/routers/instances_test.exs`, `docs/status/*`,
   `lib/letflow/design/req200-instance-timeline-rendering.md`, `test/specs/REQ-200.md`,
   and `handoffs/*` are touched. `lib/letflow/api/authorization.ex` and everything
   under `web/` are absent from this list.

## Acceptance criteria, checked one by one against real code

**AC1 (non-blank actor_display_name/description over 4+ event types)** -- confirmed.
`timeline_item/2` (instances.ex L308-324) always calls `resolve_actor_display_name/3`
and `render_description/3` and assigns their results unconditionally into the item
map; neither function has a code path returning `nil` or `""`. Test:
`instances_test.exs` L868-902 exercises this over TASK_COMPLETED, INSTANCE_STARTED,
and others.

**AC2 (four fallback levels, four explicit tests)** -- confirmed genuinely distinct,
not just passing incidentally. Read `resolve_actor_display_name/4`
(instances.ex L234-248): it is a `cond` with four mutually exclusive branches in the
required order -- (1) `actor_id` present and found in the batched map, (2)
`metadata["token_description"]` non-blank, (3) `metadata["actor_label"]` non-blank,
(4) literal `"system"`. Four dedicated tests exist at L912-981, each isolating exactly
one level (verified each test's setup carries only the fields relevant to the level it
targets, per the reasoning documented in the file's own comment at L904-911).

**AC3 (deleted-user actor_id falls through, no error/null)** -- confirmed for real, not
just because the test passes. `fetch_display_names_by_actor_id/2` (instances.ex
L207-219) only inserts an id into the returned map when the batched query actually
found that user row with a non-blank `display_name`; a deleted user's id is never
looked up successfully, so it is structurally absent from `display_names_by_id` --
indistinguishable, by design, from an id that was never queried at all. Since
`resolve_actor_display_name/4`'s first branch is `Map.has_key?/2`-gated rather than an
unguarded `Map.fetch!/2`, a deleted-user actor_id falls through to the metadata levels
exactly like AC2 level 4's "none of the three" case. This is not a coincidence of the
test data; it is inherent to the guard structure. Test at L983-1009 exercises a real
`Repo.delete!/2` on a previously-inserted user row and asserts `"system"`.

**AC4 (event-type-specific descriptions)** -- confirmed. `render_description/3`
(instances.ex L263-300) has one clause per event type
(INSTANCE_STARTED/TASK_COMPLETED/INSTANCE_CANCELLED/INSTANCE_PINS_REBOUND/
SUB_PROCESS_COMPLETED/EXECUTION_ERROR/TIMER_FIRED) each producing a distinct string
naming the actor (except TIMER_FIRED, which the code comments explain deliberately
omits the actor since it is always the platform sentinel -- a documented, reasoned
exception, not an oversight). Test at L1011-1032 asserts the actual strings for two
event types and confirms they differ.

**AC5 (unrecognised event type gets a non-empty generic description)** -- confirmed.
The mandatory trailing clause at L298-300 (`"Event #{event_type} by #{actor}"`) matches
any `event_type` string not covered by an earlier clause -- necessary because
`lua/platform.ex`'s emit_event hook lets tenant scripts append arbitrary event types
with no whitelist (per the code's own comment at L259-260). Test at L1033-1052
appends a made-up event type and asserts a non-empty description.

**AC6 (field names match TimelineEntry exactly)** -- confirmed field-by-field.
`web/src/types/api.ts` TimelineEntry (L177-188) declares: `event_type`, `timestamp`,
`actor_display_name`, `description`, `instance_id`, `event_id`, `sequence_num`,
`task_id`, `node_id`, `metadata`. `timeline_item_map/1` (routers/instances.ex
L654-667) emits exactly this set under exactly these keys, including the
`timestamp`/`sequence_num` renames from the old `created_at`/`sequence_number`. Test at
L1053-1069 asserts the exact key set against the type's declared members.

**AC7 (N+1 avoidance, not just a lucky test)** -- confirmed structurally, not just by
the test's query count. In `timeline/3` (instances.ex L167-197), distinct non-nil
`actor_id`s are collected from the whole page (L185-189) and passed once to
`fetch_display_names_by_actor_id/2` (L191) *before* `Enum.map(page, &timeline_item/2)`
(L193) runs -- the batched lookup is structurally outside the per-event loop, not
merely coincidentally called once in the current test data. Independently confirmed
one of TEST-DESIGN-VALIDATOR's four cited mutations (moving the lookup inside the
per-event map to reproduce genuine N+1) is a real, meaningful mutation given this
structure -- i.e., the test genuinely constrains the implementation shape, not just its
current behavior. Test at L1070-1123 uses a named telemetry handler filtered to
`source == "users"` and asserts the query count is exactly 1 for a page sharing one
actor.

**AC8 (REQ-080 behavior unregressed -- 5 assertions)** -- confirmed via the original,
still-passing REQ-080 tests, re-run by me: route path and 200 response (L535-556),
`:InstancesRead` gating (`describe "AC6 -- permission required on every read
endpoint"`, L755+, covers all five read endpoints including timeline), ascending
`sequence_number` order (`order_by([e], asc: e.sequence_number)`, instances.ex L179,
unchanged from REQ-080), cursor pagination (`describe "AC2 -- pagination
completeness"` L611-624, "timeline: every event exactly once across three pages, no
dup, no gap"), and cross-tenant 404 (`describe "AC3 -- cross-tenant is the same as
nonexistent"` L665-684, "timeline: cross-tenant id and nonexistent id both 404"). All
five re-ran green in my standalone 44/44 run.

**AC9 (no file under web/ touched)** -- confirmed via `git diff main...HEAD --stat`
myself: no `web/` path appears in the changed-file list.

**AC10 (authorization.ex untouched)** -- confirmed via the same `git diff` run:
`lib/letflow/api/authorization.ex` does not appear in the changed-file list.

**AC11 (mix test / mix compile --warnings-as-errors pass, real output)** -- confirmed:
full suite 2749/2751 (2 pre-existing rustc-absent environment failures, independently
reproduced and attributed structurally, not by count-matching), REQ-200's own test file
44/44, `mix compile --warnings-as-errors --force` clean with 0 warnings across a full
155-file recompile.

## Flake diagnosis spot-check

Independently reproduced both `CheckToolchainTest` failures in my own
`scripts/test_parallel.sh` run, at the same file/line
(`test/mix/tasks/letflow_check_toolchain_test.exs:274` and `:289`), same error
(`:enoent` from `System.cmd("rustc", ["--version"], ...)` inside
`running_rust_raw/0` at line 69), same root cause (`which rustc` empty in this
sandbox). `git diff main...HEAD --stat` confirms
`test/mix/tasks/letflow_check_toolchain_test.exs` is not in this branch's diff. This
is a genuine pre-existing environment gap, not a masked regression.

## Cross-tenant isolation of the batched actor lookup (independent re-trace of
SECURITY-REVIEWER's claim)

`fetch_display_names_by_actor_id/2` (instances.ex L207-219) builds its query against
the `User` schema filtered by `u.id in ^actor_ids` and calls `Repo.all(query, prefix:
prefix)` -- the same `prefix` threaded in from `timeline/3`'s own `opts` (`prefix =
Keyword.fetch!(opts, :prefix)`, L168), which is the caller-scoped tenant schema used
for every other query in this function (the `Event` query at L182, the existence check
at L172). Since Ecto's `prefix:` option determines which Postgres schema the query
executes against, and this function never accepts or derives a prefix from anywhere
else, the batched lookup is confined to the same tenant schema as the timeline query
itself -- it cannot cross into another tenant's `users` table regardless of what
`actor_ids` contains. This matches SECURITY-REVIEWER's traced claim; I re-derived it
independently by reading the prefix threading myself rather than accepting the
citation.

## Conclusion

All 11 acceptance criteria are genuinely met against real, current code, not against
the status-history narrative. No rework needed. Routing to DOC-UPDATER via
`handoffs/WF02-REQ200-20260830/step-06-doc-updater.json`.
