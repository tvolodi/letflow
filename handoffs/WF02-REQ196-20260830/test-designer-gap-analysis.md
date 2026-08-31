# TEST-DESIGNER gap-check — REQ-196 (GET /api/v1/audit from audit_entries)

Full re-check of `test/letflow/routers/req196_audit_route_test.exs` (ELIXIR-DEV's
first pass, REVIEWER spot-checked AC1/AC2) and `test/letflow/routers/
req078_supporting_routes_test.exs`'s fixture swap, against all 9 acceptance
criteria in `docs/requirements.yaml` REQ-196 and against the design
(`lib/letflow/design/req196-audit-route.md`) and the shipped code
(`lib/letflow/audit.ex`, `lib/letflow/routers/audit.ex`).

## Verdict per AC

| AC | Verdict | Notes |
|---|---|---|
| AC1 (real non-null before_state/after_state) | Already complete | `describe "AC1"` (lines 97-140 pre-existing). See "AC1 seeding" note below. |
| AC2 (resource_type varies) | Already complete | Three seeded resource_types, asserts sorted list == `["definition","instance","task"]`. |
| AC3 (resource_type filter discriminates, both directions) | Already complete | Two tests: filter-to-one-kind and omit-filter-returns-all. |
| AC4 (envelope field-for-field) | Already complete | Asserts exact key sets for both envelope and item (`Map.keys \|> Enum.sort ==`), plus a value-by-value equality check against the seeded `Entry` struct, plus a separate null-actor_id-passes-through test. |
| AC5 (:AuditRead enforced) | Already complete | PLATFORM_ADMIN 200 / TASK_WORKER 403, against REQ-069's real role matrix (`role_allows?/2`), no ad-hoc permission invented. |
| AC6 (cross-tenant isolation) | Already complete | Two real `TenantFixture.provisioned_tenant!/1` schemas, asserts neither B's `audit_id` nor B's `resource_id` leak into A's response. |
| AC7 (moduledoc no longer stale) | Already complete | `Code.fetch_docs/1` reads the real shipped `@moduledoc` string; refutes the three stale claims verbatim, asserts the new source is positively named. |
| AC8 (no web/ touched) | Confirmed this session | `git diff --stat main...HEAD -- web/` returns empty. |
| AC9 (mix test / mix compile pass) | Confirmed this session | See "Verification run" below. |

## Item-by-item response to the review brief

1. **AC1 seeding mechanism.** `seed_audit_entry!/2` calls `Letflow.Audit.insert_entry/3`
   directly rather than driving a real business operation (e.g.
   `Letflow.Definitions.activate/2`) that itself triggers REQ-195's capture logic.
   Concluded this is **not** a gap: `insert_entry/3` is REQ-195's own real, public
   write API for `audit_entries` (not a hand-built fake row bypassing it), and
   REQ-196's own design doc §9 non-goals states explicitly "No change to REQ-195's
   schema or capture logic" — REQ-196 is a read-side-only requirement. The
   `req078_supporting_routes_test.exs` fixture (pre-existing convention, also
   `Audit.insert_entry/3`-based) uses the identical idiom, so this is the
   established pattern for this boundary, not an ad hoc shortcut. What actually
   proves AC1 (the direct inverse of the old always-null behavior) is that the
   fetched response carries the *same* non-null `before_state`/`after_state` the
   seed put in, which the test does assert.
2. **AC3 both directions.** Confirmed both tests exist and are distinct: filtering
   to `"task"` returns only `resource_type == "task"` rows (count 2 of 3 seeded),
   and omitting the param returns both seeded kinds (count 2 of 2 seeded). Genuine
   discrimination, not a tautology.
3. **AC4 field-by-field.** Confirmed exhaustive: both the 3-key page envelope and
   the 8-key item shape are asserted via exact sorted-key-set equality (so an
   extra or missing key fails), plus 8 individual value equalities against the
   real `Entry` struct fields, plus `refute Map.has_key?(item, "payload"/"pipeline_run_id")`.
4. **AC5 :AuditRead.** Confirmed against REQ-069's real matrix: `TASK_WORKER` is
   one of the roles `role_allows?/2` actually excludes from `:AuditRead`
   (`lib/letflow/routers/audit.ex`'s own moduledoc names `PROCESS_DESIGNER`/
   `TASK_WORKER`/`AGENT_RUNNER` as excluded) — not an invented role.
5. **AC6 cross-tenant.** Confirmed two real, separately-provisioned tenant schemas
   (`TenantFixture.provisioned_tenant!/1` — real Postgres schema creation/
   migration, not a simulated tenant_id column value).
6. **AC7 moduledoc.** Confirmed via `Code.fetch_docs/1` against the compiled
   module's actual `@moduledoc`, not a source-file grep or a copy of the design
   doc's prose.
7. **AC8 no web/ file.** `git diff --stat main...HEAD -- web/` — empty, confirmed
   this session.
8. **AC9 mix test/compile.** Confirmed this session with real toolchain access —
   see below.
9. **Cursor pagination round-trip over the new `{timestamp, id}` scheme.** Already
   present (`describe "pagination -- cursor round-trips over (timestamp, id)"`,
   pre-existing): page 1 of 2 returns `has_more`/`next_cursor`, page 2 via that
   cursor returns the remaining row with `next_cursor: nil`, and the two pages'
   `audit_id` sets are asserted disjoint. This would catch a broken seek-pair
   implementation (e.g. one that ignored the `id` tiebreak, or used the old
   `global_seq` field).
10. **Malformed/invalid `actor_id`.** Already present (pre-existing): a
    non-UUID `actor_id` gets 422, and a well-formed one filters correctly. Both
    were implemented (`validate_actor_id/1`'s `Ecto.UUID.cast/1` check) and
    tested, not just implemented.

## Genuine gaps found and filled

The 9 ACs and the two extra checks above were already fully covered. The
remaining gaps were in the **edge-case list the step-03 handoff itself named**
("empty audit_entries table, from>to, page_size boundary, resource_id filter,
malformed cursor variants beyond the one already tested") — none of these are
separately-numbered ACs, but all are real, previously-untested behavior in the
shipped `list_entries/1`/`handle_list/1` code:

1. **`resource_id` filter never tested.** `where_resource_id/2` exists in
   `lib/letflow/audit.ex` and is wired into `list_params()`, but no test asserted
   it discriminates. Added two tests (filter-to-one / omit-returns-all), mirroring
   the existing AC3 shape.
2. **Empty `audit_entries` table never tested.** `split_list_page/2`'s `[]` branch
   and `next_cursor/2`'s `next_cursor([], _has_more)` clause were only ever
   exercised implicitly (every existing test seeds at least one row). Added a
   test against a freshly-provisioned tenant with zero rows, asserting
   `items: []`, `count: 0`, `next_cursor: nil`, not an error.
3. **`page_size` exact-boundary (`has_more: false`) never tested.** The existing
   pagination test only covers `page_size < row_count` (`has_more: true`). Added
   a test with exactly `page_size` rows in the table, asserting `next_cursor: nil`
   — the other side of `split_list_page/2`'s `length(rows) > page_size` branch.
4. **`from`/`to` time-range filter never tested**, including the `from > to` ->
   422 `invalid_time_range` check `check_time_range/2` performs before any query
   is issued. `Entry.timestamp` is stamped internally by `insert_entry/3`
   (`DateTime.utc_now()`, not attribute-overridable), so the test reads a real
   cutoff timestamp back between two seeded inserts (with a 5ms `Process.sleep/1`
   between inserts to guarantee distinct microsecond timestamps, matching the
   established idiom already used at `test/letflow/sandbox_pool_test.exs:149,186,729`)
   rather than asserting anything about wall-clock time itself. Added: one test
   for `from`/`to` each excluding the entry on the wrong side of the cutoff, one
   test for `from > to` -> 422.
5. **Malformed cursor variants beyond the one already-tested base64-garbage
   case.** Added two more, each hitting a distinct failure branch: (a) a
   cursor minted with a different endpoint's prefix (`"T:"` instead of `"A:"`),
   hitting `Pagination.decode_cursor/4`'s `:wrong_endpoint` branch specifically;
   (b) a cursor with the correct `"A:"` prefix but a malformed inner seek payload
   (no parseable `<entry_ts_us>:<entry_id>` pair), hitting
   `cursor_seek_from_cursor/1`'s own parse failure — a distinct code path from
   `Pagination.decode_cursor/4`'s. Both assert 400, matching the router's
   existing collapse-to-400 convention.

No existing test was weakened, skipped, or removed. No `@tag :skip`/`:pending`
anywhere in the file (confirmed by grep).

## Verification run (this session, real toolchain)

```
$ source ~/.asdf/asdf.sh
$ mix compile --warnings-as-errors
(no output -- clean)

$ MIX_ENV=test mix test test/letflow/routers/req196_audit_route_test.exs
Finished in 19.8 seconds (0.00s async, 19.8s sync)
Result: 26 passed

$ MIX_ENV=test mix test test/letflow/routers/req196_audit_route_test.exs \
    test/letflow/routers/req078_supporting_routes_test.exs
Finished in 37.6-38.2 seconds (0.00s async, sync)
Result: 46 passed
```

26 tests in `req196_audit_route_test.exs` (16 pre-existing + 10 gap-fill), 0
failures. Combined with `req078_supporting_routes_test.exs`'s 20 tests: 46
passed, 0 failures, in both runs performed.

`git diff --stat main...HEAD -- web/` — empty (AC8 confirmed).
`git status --short` — only `test/letflow/routers/req196_audit_route_test.exs`
modified by this step.
