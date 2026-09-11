# Design: ISS-0594 — fix stale REQ-192 substring assertion in service_catalog_test.exs

## Scope

Test-file + spec-doc-only. No `lib/` change (does not touch
`solution_pack.ex`, which is already correct post-REQ-307). No tenant-data
path is touched — **out of scope for SECURITY-REVIEWER**.

Files touched by this fix:
- `test/letflow/service_catalog_test.exs` (describe block + test name +
  assertion, around line 588)
- `test/specs/REQ-191.md` (matching header/bullet, around lines 179-182)

## Ground truth read directly from source (post-REQ-307)

`lib/letflow/definitions/solution_pack.ex`:
- Moduledoc, line 44: `**is currently UNOWNED. No open` (the sentence
  continues "requirement owns it.")
- Inline comment above `check_unsupported_sections/1`, line 862: `the
  policy is currently UNOWNED --` (continues "no open requirement owns
  it.")

Both spots use the literal uppercase substring `UNOWNED`, immediately
followed by wording that the policy is undecided / has no owning
requirement. `REQ-192` still appears in both places too, but only as
historical narration ("this bullet previously deferred ... to REQ-192
... that deferral is stale ... REQ-192 is done and landed the
service-catalog route surface *without* lifting this restriction").

## Current (stale) test state

File: `test/letflow/service_catalog_test.exs`

- Describe block name (~line 588):
  `"AC10: SolutionPack.service_catalog_entries hard-fail retained, REQ-192 named"`
- Test name:
  `"SolutionPack's moduledoc names REQ-192 as the owner of the service_catalog_entries decision"`
- Assertion body:
  ```
  module_source = File.read!("lib/letflow/definitions/solution_pack.ex")

  assert module_source =~ "service_catalog_entries"
  assert module_source =~ "REQ-192"
  ```

## Designed (corrected) test state

Rename the describe block and test to state what is actually being
asserted (that the policy is documented as unowned), and swap the
`REQ-192` presence check for a check on the literal `UNOWNED` marker,
which is the property that would actually regress if someone
re-introduced an incorrect ownership claim (and which is *not* removed
by the improvement this issue anticipates — a future edit that strips
the historical "previously deferred to REQ-192" narration entirely
should still pass).

- New describe block name:
  `"AC10: SolutionPack.service_catalog_entries hard-fail retained, ownership status documented"`
- New test name:
  `"SolutionPack's moduledoc documents the service_catalog_entries policy as unowned"`
- New assertion body:
  ```
  module_source = File.read!("lib/letflow/definitions/solution_pack.ex")

  assert module_source =~ "service_catalog_entries"
  assert module_source =~ "UNOWNED"
  ```

No other test in that describe block (`"export/3 always emits
service_catalog_entries: []"`, `"install/3 rejects a non-empty
service_catalog_entries array ..."`) changes — ISS-0594 only flags the
first test.

## Matching correction to test/specs/REQ-191.md

Current text (lines ~179-182):
```
## AC10 — SolutionPack's service_catalog_entries hard-fail retained, REQ-192 named

**Tests:**
- `"SolutionPack's moduledoc names REQ-192 as the owner of the service_catalog_entries decision"`
- `"export/3 always emits service_catalog_entries: []"`
- `"install/3 rejects a non-empty service_catalog_entries array with {:error, :unsupported_pack_section}"`
```

Designed replacement — header and first bullet only (the other two
bullets are untouched, they name unrelated tests that don't change):
```
## AC10 — SolutionPack's service_catalog_entries hard-fail retained, ownership status documented

**Tests:**
- `"SolutionPack's moduledoc documents the service_catalog_entries policy as unowned"`
- `"export/3 always emits service_catalog_entries: []"`
- `"install/3 rejects a non-empty service_catalog_entries array with {:error, :unsupported_pack_section}"`
```

The `"Why each exists"` prose immediately below (currently starting
"the third test re-confirms the existing (unchanged) `install/3`
behavior...") makes no REQ-192-ownership claim and needs no edit.

## Invariants preserved

- The hard-fail behavior itself (`check_unsupported_sections/1` reject
  path, `export/3` always emitting `service_catalog_entries: []`) is
  unchanged and untested by this fix — those two other tests already
  cover it and are left alone.
- The corrected assertion (`=~ "UNOWNED"`) tests the same class of
  property the original intended (a documented ownership/policy state
  is present in the moduledoc), just naming the actual current state
  instead of a substring that survives by accident.

## Open questions

None. Both target files were read directly (not from stale citations)
to confirm exact current wording before designing the replacement
strings above.

## Out of scope confirmation

- No `lib/letflow/` change.
- No tenant-data path (API route, migration, secrets, response
  shaping) touched — SECURITY-REVIEWER gate does not apply.
- No `priv/repo/migrations/` change.
