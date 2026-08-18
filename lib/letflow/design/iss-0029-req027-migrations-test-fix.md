# Fix design: ISS-0029 / GH#87 — vacuous `refute table_exists_in_schema?("public", ...)`

**Run:** WF03-ISS0029-20260818
**Workflow step:** WF-03 Step 2 (fix design), following ISSUE-FIXER's Step 1 diagnosis
in `handoffs/WF03-ISS0029-20260818/step-01-issue-fixer-diagnose.json`.
**Scope:** test-file and spec-file text only. No `lib/`, no `priv/repo/migrations/`, no
implementation code. This document contains no `.ex`/`.exs` code blocks — line-range
instructions and literal replacement text only, per this role's constraint.

## 1. Root cause (carried forward from ISSUE-FIXER, restated for traceability)

`test/letflow/definitions/migrations_test.exs`'s AC1 test contains
`refute table_exists_in_schema?("public", table)`. `Ecto.Migration.__prefix__/1` injects
the migrator run's own `:prefix` onto every table regardless of what the migration's own
`prefix: prefix()` calls say, and `TenantProvisioning.replay_migrations/2` always supplies
a concrete tenant `:prefix`. There is therefore no reachable state, under
`replay_migrations/2`, in which either REQ-027 table lands in `public` — the assertion
cannot fail and provides zero detection. ISSUE-FIXER independently reproduced this via a
`prefix: prefix()` → `prefix: nil` mutation across both REQ-027 migrations: all 14 tests
in the file, including this one, stayed green.

The real, load-bearing coverage of the `:prefix`-guard property is
`test/letflow/event_store/migrations_test.exs`'s section-4 guard test (current line 484,
name quoted in full in §3 below), which runs every registered tenant-scoped migration
with **no** `:prefix` at all — the one condition under which the guard can actually fail
— and asserts nothing appears in `public`. ISSUE-FIXER independently reproduced this too
(flipping `if prefix() do` to `if true do` in both REQ-027 migrations' `change/0` bodies
failed exactly this test, listing both `CreateProcessDefinitions` and
`CreateInstanceDefinitionSnapshots` as candidates).

Chosen remedy: **option (a)** from both ISS-0029.yaml and the diagnosis — delete the
vacuous assertion rather than reword it. Per ISS-0029.yaml's own stated preference: "a
test that cannot fail is worse than no test, because it occupies the space where a real
one would be looked for."

## 2. Edit 1 — `test/letflow/definitions/migrations_test.exs`

All line numbers below are from the file's current state on branch
`feature/WF03-ISS0029-20260818` (read in full by this agent before writing this design;
do not re-derive from ISS-0029.yaml's own approximate `~line 283-300` / `~line 300`
citations, which predate this file's current line count).

### 2a. Delete lines 297–301 in full

Current text (verbatim, lines 297–301):

```
        # ...and does NOT exist under public. This half is what proves :prefix is doing
        # the work: a migration that ignored :prefix and wrote to the default schema
        # would still satisfy a naive "does the table exist" check.
        refute table_exists_in_schema?("public", table),
               "#{table} leaked into the public schema -- the :prefix guard is not working"
```

Delete these 5 lines entirely — the 3-line inline comment (the "now-misleading" comment
the handoff names) and the 2-line `refute` assertion (statement + failure-message
continuation line) together, since the comment only exists to explain the `refute` that
is being removed.

### 2b. Tidy the immediately preceding comment, lines 292–296 (line 293 specifically)

Current text (verbatim, lines 292–296):

```
      for {table, _module} <- @req027_tables do
        # The table exists under the tenant's own schema...
        assert table_exists_in_schema?(schema_name, table),
               "#{table} is missing from tenant schema #{schema_name}"

```

Line 293's trailing `...` exists solely to lead into the now-deleted "...and does NOT
exist under public" continuation. With that continuation gone, change line 293 from:

```
        # The table exists under the tenant's own schema...
```

to:

```
        # The table exists under the tenant's own schema.
```

(Trailing ellipsis → period. No other change to this line or to lines 292, 294–296.)

### 2c. Net shape of the `for` loop after 2a+2b

After both edits, the loop body (currently lines 292–302) reads as exactly:

```
      for {table, _module} <- @req027_tables do
        # The table exists under the tenant's own schema.
        assert table_exists_in_schema?(schema_name, table),
               "#{table} is missing from tenant schema #{schema_name}"
      end
```

The blank line that currently sits at line 296 (between the `assert` and the deleted
`refute` block) is also removed as part of deleting 297–301, so the loop body has no
internal blank line — matching the shape above.

**What is explicitly preserved, unchanged:** the `assert table_exists_in_schema?(schema_name, table)` line and its failure message (current lines 294–295) — this is AC1's
positive-half assertion, and ISSUE-FIXER's diagnosis confirms it is real coverage
(demonstrated by the filed issue's own MUT-2b: unregistering
`CreateInstanceDefinitionSnapshots` from `tenant_scoped_migrations/0` failed 6 tests with
a precise diagnostic). Every other test in the file — the column-set-equality test, the
two index-shape tests, the two FK tests, the two column-default tests, the
`tenant_scoped_migrations/0` registration test — is untouched by this fix; none of them
reference `table_exists_in_schema?("public", ...)`.

### 2d. Rename the test description, line 285

The test's own name currently over-claims the same property the deleted assertion
over-claimed, and would keep doing so even after 2a–2c: a reader who only sees the test
name (in `mix test` output, in an IDE's test list, in `test/specs/REQ-027.md`'s verbatim
citation) has no way to tell the "never in public" clause is no longer checked by this
test. Leaving a false claim in the test's own name would re-create ISS-0029's defect
class one level up, so this rename is included as part of the same fix rather than
deferred as a new issue.

Current text, line 285:

```
    test "replay_migrations/2 applies both REQ-027 migrations and both definition tables land in the tenant's own schema, never in public",
```

New text:

```
    test "replay_migrations/2 applies both REQ-027 migrations and both definition tables land in the tenant's own schema",
```

(Drop the `, never in public` clause only. No other part of the string, and no other line
of the test's `def`/argument list — line 286 — changes.)

## 3. Edit 2 — `test/specs/REQ-027.md`, test case 1 (currently lines 107–114)

Current text, verbatim (lines 107–114):

```
1. **`replay_migrations/2` applies both REQ-027 migrations and both tables land in the
   tenant's own schema, never in `public`** —
   `migrations_test.exs`: *"replay_migrations/2 applies both REQ-027 migrations and both
   definition tables land in the tenant's own schema, never in public"*.
   The `public` half is what actually proves `:prefix` is doing the work: a migration
   that ignored `:prefix` and wrote to the default schema would still satisfy a naive
   "does the table exist" check. "Applying cleanly" is asserted as `{:ok, versions}` from
   the real replay, not as an absence of exceptions.
```

Replace the whole block (all 8 lines) with:

```
1. **`replay_migrations/2` applies both REQ-027 migrations and both tables land in the
   tenant's own schema** —
   `migrations_test.exs`: *"replay_migrations/2 applies both REQ-027 migrations and both
   definition tables land in the tenant's own schema"*.
   "Applying cleanly" is asserted as `{:ok, versions}` from the real replay, not as an
   absence of exceptions. The companion guarantee — that neither REQ-027 table lands in
   `public` — is **not** owned by this test: under `TenantProvisioning.replay_migrations/2`,
   `Ecto.Migration.__prefix__/1` sets each table's runtime prefix from the migrator's own
   `:prefix` option regardless of what the migration's own `prefix: prefix()` calls
   declare, so a `refute table_exists_in_schema?("public", table)` assertion in this
   describe block could never observe a failure and was removed (ISS-0029/GH#87) rather
   than kept as false coverage. The real, load-bearing owner of the `:prefix`-guard
   property is `test/letflow/event_store/migrations_test.exs`'s section-4 guard test,
   *"every migration registered in tenant_scoped_migrations/0 creates nothing in public
   when run with no :prefix (§4 guard pattern)"* (~line 484): it runs each registered
   migration with **no** `:prefix` at all — the one condition under which the guard can
   actually fail — and asserts `public` gains nothing.
```

Notes for the implementer (ELIXIR-DEV — this is a `test/specs/` doc edit, may also be
done by TEST-DESIGNER depending on how ORCH routes Step 3; either way this is the exact
replacement text either role must apply verbatim):

- The bolded summary line and the verbatim test-name quote both drop `, never in public` /
  `never in \`public\``, matching Edit 1 §2d's rename exactly — the quote must stay a
  byte-exact match of the renamed test string, since this doc's own convention (see every
  other numbered test case in this file) is a literal quote of the ExUnit test name.
- The line number cited for the section-4 guard test (`~line 484`) is this design's
  as-read value on `feature/WF03-ISS0029-20260818`; carry the `~` (approximate) prefix
  rather than asserting it exactly, consistent with this doc's own convention elsewhere
  (e.g. "migrations/014_definition_stage.sql" citations carry no promise of exact line
  stability either) — a later unrelated edit to `event_store/migrations_test.exs` could
  shift it without that being this fix's concern.
- No other test case (2 through 20) in `test/specs/REQ-027.md` references the deleted
  assertion or the `never in public` phrasing (verified: `grep -n "never in public\|public
  half\|:prefix guard\|prefix guard" test/specs/REQ-027.md` on the current file matches
  only line 110, inside the block replaced above). No other line of the file changes.
- The "Carry-forward (c)" section (current lines 295–306, describing the section-4 guard
  test's extended cleanup allowlist) already correctly attributes `:prefix`-guard coverage
  completeness to the section-4 guard test and requires no change — it is left untouched.

## 4. What this fix does NOT touch (explicit negative scope)

- `test/letflow/event_store/migrations_test.exs` — the section-4 guard test itself is
  already correct per both ISSUE-FIXER's and ISS-0029.yaml's diagnosis; not modified.
- `priv/repo/migrations/20260816193001_create_process_definitions.exs` and
  `..193002_create_instance_definition_snapshots.exs` — no migration code changes; the
  `:prefix` mechanism itself is not defective, only the test claiming to verify it here.
- `docs/requirements.yaml`'s REQ-027 acceptance-criteria text — AC1's requirement wording
  ("applying cleanly") never mentioned `public`/`never in public`; nothing there needs
  correcting.
- `test/letflow/definitions/schemas_test.exs` — pure/no-I/O file, unrelated to this
  assertion.
- Any other test in `migrations_test.exs` beside the one named in §2 — none reference
  `table_exists_in_schema?("public", ...)` (confirmed by reading the full file: it is the
  only call site of that helper's `"public"` argument in the file).

## 5. Regression-test guidance for TEST-DESIGNER (Step 4)

Per WF-03 Step 4, the regression test must be shown to fail against pre-fix code and pass
post-fix. Since this fix is a deletion/correction of test/spec text rather than new
production behavior, the "regression" being proven is: **the vacuous assertion no longer
exists to give false confidence, and the real property is still covered elsewhere.**
Concretely:

- Confirm (by reading the diff, not by re-running old code) that
  `test/letflow/definitions/migrations_test.exs` no longer contains any
  `table_exists_in_schema?("public", ...)` call.
- Re-run `test/letflow/event_store/migrations_test.exs`'s section-4 guard test and confirm
  it still passes and still fails when the same `if prefix() do` → `if true do` mutation
  ISSUE-FIXER used is re-applied — this is the "fail-first" proof appropriate here: the
  property's real owner still detects the defect the deleted assertion never could. Revert
  the mutation afterward and confirm the tree is clean.
- Full suite (`MIX_ENV=test mix test`) must stay green after the edit, with test count
  reduced by zero (no test is removed, only one assertion inside one existing test), i.e.
  still all tests in `migrations_test.exs` present, same count as before minus zero.

## 6. Open questions

None. Both edits are fully specified above; no unresolved ambiguity is left for
ELIXIR-DEV/TEST-DESIGNER to guess at.
