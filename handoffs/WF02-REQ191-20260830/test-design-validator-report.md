# TEST-DESIGN-VALIDATOR report — WF02-REQ191-20260830 Step 3b

**Verdict: PASS**

## Scope

Independently validated `test/letflow/service_catalog_test.exs` (26 tests)
against REQ-191's 11 acceptance criteria (per
`handoffs/WF02-REQ191-20260830/step-01-code-designer.json`), the AC-to-test
mapping in `test/specs/REQ-191.md`, and TEST-DESIGNER's mutation-testing
claims on `handoffs/WF02-REQ191-20260830/step-03b-test-design-validator.json`.

## Per-AC coverage check

Read every `describe` block against its named AC. All 11 ACs have real,
non-vacuous coverage:

- AC1/AC2 (DB-level CHECK constraints): raw `Repo.query/2` SQL bypassing
  `Entry.insert_changeset/2` entirely — correctly proves DB-level, not
  changeset-level, enforcement. Boundary values (`timeout_ms` 0 and
  3_600_001) are exercised, not just a mid-range violation.
- AC3 (three-way visibility): all three branches covered, plus a fourth
  test asserting the invisible-vs-missing result tuples are `==` to each
  other, not merely both `{:error, :not_found}` in isolation — this catches
  a regression that attaches distinguishing metadata to only one branch.
- AC4 (global uniqueness): registers under a second tenant, asserts
  `{:error, :duplicate_service_id}`, and re-reads the surviving row to rule
  out silent overwrite.
- AC5 (non-existent tenant): asserts both the `{:error, :tenant_not_found}`
  return and `refute Repo.get(Entry, service_id)` (no row created).
- AC6 (referential guard): four tests — blocked-by-reference,
  succeeds-when-unreferenced, the substring-vs-structural proof (plants the
  service_id inside a `HUMAN_TASK` node's unrelated attribute, not a
  `SERVICE_TASK` node's own `service_id` attribute), and the
  concurrent-delete-race regression test (see Mutation reproduction below).
- AC7 (narrow/widen): narrow-refused, narrow-self-exemption, and
  widen-always-succeeds (deliberately registers an unrelated tenant's ACTIVE
  reference first to prove "always" is unconditional).
- AC8 (ServiceScopeValidator integration): builds a `Graph.t()` directly and
  calls `validate/3` with `ServiceCatalog.scope_validator_lookup/1` — both
  the rejected and activated paths are exercised. `git diff --stat main...HEAD
  -- lib/letflow/definitions/service_scope_validator.ex` reproduced myself:
  empty output, confirming no change to the frozen validator.
- AC9 (documentation cites decision 0003 / REVIEWER sign-off): simple
  content-presence checks, appropriately non-behavioral per the AC's own
  wording.
- AC10 (SolutionPack hard-fail retained, REQ-192 named): three tests,
  including the all-or-nothing check that no `process_definitions` row was
  written when `install/3` rejects a non-empty `service_catalog_entries`.
- AC11 (no route/controller): structural `File.ls!/1` check, git-history
  independent. Reproduced myself: `git diff --stat main...HEAD --
  lib/letflow/routers/` is empty, and no filename in `lib/letflow/routers/`
  mentions the service catalog.

No `@tag :skip`, no "TODO: implement test" anywhere in the file (grepped
directly). Fixtures are self-sufficient: every `service_id` is generated via
`unique_service_id/1` (a monotonic counter), every tenant is a freshly
inserted row, and every test cleans up its own rows via `on_exit/1` — no
test depends on another having run first, and no shared hardcoded state
(no hardcoded UUIDs/service_ids reused across tests, no hardcoded
secrets/connection strings — grepped and confirmed clean).

## Fresh `mix test` run (this session, not copied from TEST-DESIGNER)

```
MIX_ENV=test mix compile --warnings-as-errors   -> exit 0, no warnings
mix test test/letflow/service_catalog_test.exs  -> Result: 26 passed, 0 failures
```

## Mutation reproduction (mandatory, independent)

Applied TEST-DESIGNER's reported mutant 4 myself — removed the
`rescue Ecto.StaleEntryError -> {:error, :not_found}` clause from
`delete_entry/1` in `lib/letflow/service_catalog.ex` (direct edit, not a
worktree; reverted via `git checkout --` immediately after).

Result: `mix test test/letflow/service_catalog_test.exs` -> **25/26 passed,
1 failure**, matching TEST-DESIGNER's reported count exactly. The failure
output shows the real `%Ecto.StaleEntryError{}` propagating out of
`Task.Supervised.invoke_mfa/2` through `Task.await/2` in the
`"a concurrent delete of the same row is treated as a benign not-found, not
a crash"` test — i.e. the mutant genuinely crashes rather than the test
failing on a soft assertion mismatch.

This confirms the concurrent-delete-race test's mechanism is real: it holds
an actual Postgres row lock open in a second process
(`Repo.transaction(fn -> Repo.delete_all(...) ; receive do :release_lock ->
:ok end end)`), synchronizes on `assert_receive :row_locked`, then releases
the lock only after `delete/1`'s own `Task.async` has had time to reach its
own `Repo.delete/1` and block on the same row. This is a deterministic
lock-based mechanism, not a sleep-based race that could pass vacuously
regardless of scheduling — the `Process.sleep(200)` present in the test is
only there to give `delete/1` time to reach and block on the lock before it
is released, not to manufacture the race itself; the actual race window is
enforced by the real Postgres row lock, independently reproduced above.

Revert confirmed: `git checkout -- lib/letflow/service_catalog.ex`, then
`git status --porcelain lib/ test/` returned empty output, and
`mix test test/letflow/service_catalog_test.exs` was re-run and returned to
`Result: 26 passed` (fresh output, quoted above in this session's tool
history).

## Other claims spot-checked directly

- `service_scope_validator.ex` untouched: confirmed via `git diff --stat`
  myself (empty).
- No route/controller file: confirmed via `git diff --stat` and `ls`
  myself (empty / no match).
- Postgres reachable: `sudo docker compose ps` confirmed
  `letflow-1-postgres-1` healthy before running any test.

## Conclusion

All 11 acceptance criteria have real, non-vacuous, runnable coverage. No
skipped tests, no stubs, fixtures are isolated and self-sufficient. The
concurrent-delete-race test's mutation-catching behavior was independently
reproduced with a matching failure count and a failure mode (a genuine
`Ecto.StaleEntryError` crash) that proves the lock-based mechanism is real,
not probabilistic. **PASS** — routing to TEST-RUNNER.
