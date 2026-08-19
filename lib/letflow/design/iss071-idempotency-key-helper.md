# ISS-0071: shared helper + module attributes for sub_process idempotency-key suffixes

## Problem (ISSUE-FIXER's diagnosis, restated for design scope)

`lib/letflow/engine/sub_process.ex` derives a secondary `idempotency_key` at three
call sites by hand-interpolating a literal suffix string directly into an
inline string, with no shared constant or helper enforcing that the three
suffixes stay pairwise-distinct:

- `append_instance_started_event_for_child/8` (~line 617):
  `"#{Map.get(attrs, :idempotency_key)}::sub_process_start::#{child_instance_id}"`
- `append_completion_multi/4` (~line 716):
  `"#{idempotency_key}::sub_process_completion_error::#{parent_token.instance_id}::#{child_instance_id}"`
- `append_sub_process_completed_event/8` (~line 1124):
  `"#{idempotency_key}::sub_process_completed::#{parent_instance_id}::#{child_instance_id}"`

Each comment at the three sites explains **why** a derived (not verbatim) key is
required: `event_idempotency.idempotency_key` (migration
`20260816120006_create_event_idempotency.exs`) is a schema-wide-unique index, not
per-instance, so reusing the caller-supplied base `idempotency_key` unchanged for a
second event appended in the same transaction would collide against the first
event's own use of that same base key. The three suffixes
(`sub_process_start`, `sub_process_completion_error`, `sub_process_completed`)
exist specifically to keep those three derived keys distinct from each other and
from the base key — but today that distinctness is only true by the accident of
three humans typing three different literals, with nothing that would flag it if
a future edit made two of them collide.

Confirmed by ISSUE-FIXER against current code and tests: no test asserts on the
derived suffix string's exact text (only on the caller-supplied base
`idempotency_key` and on downstream event counts), so this is a **pure
refactor** — same three literal values, same `"::"`-join format, same runtime
output byte-for-byte for the same inputs. No other call site in `lib/` or
`test/` duplicates these three literals. The unrelated atom-tuple pending-event
tags (e.g. `{:sub_process_start, ...}`) are a different, unrelated namespace and
are explicitly not touched by this design.

## Scope

**In scope:** `lib/letflow/engine/sub_process.ex` only — the three call sites
listed above, plus the three new module attributes and one new private helper
this design introduces.

**Out of scope, explicitly:**
- No change to `event_idempotency`'s schema, migration, or unique index.
- No change to any caller of `append_instance_started_event_for_child/8`,
  `append_completion_multi/4`, or `append_sub_process_completed_event/8` — their
  own signatures are unchanged; only the internal expression that computes
  `idempotency_key`/`error_idempotency_key` inside each is refactored.
- No test file changes — per ISSUE-FIXER's confirmation above, no test depends
  on the derived string's internal shape, so none should need to change. If
  TEST-RUNNER finds one that does, that is a signal the refactor broke
  byte-identical output (see Acceptance criteria below), not a reason to update
  the test to match new output.
- No change to the `{:sub_process_start, ...}` (etc.) atom-tuple pending-event
  tags used elsewhere in this module for in-memory pending-event bookkeeping —
  same words, unrelated namespace (atoms in a tuple key, not string suffixes in
  an idempotency key), not implicated by ISSUE-FIXER's diagnosis.

## New module attributes (exact names, exact values)

Add near the top of `Letflow.Engine.SubProcess` (alongside any existing
module-level `@` attributes, or immediately before first use if none exist yet):

```
@spec (module attributes have no @spec; documented here as name :: String.t() = value)

@sub_process_start_suffix "sub_process_start"
@sub_process_completion_error_suffix "sub_process_completion_error"
@sub_process_completed_suffix "sub_process_completed"
```

- `@sub_process_start_suffix :: String.t()` — value `"sub_process_start"`, exactly
  today's literal at line 617.
- `@sub_process_completion_error_suffix :: String.t()` — value
  `"sub_process_completion_error"`, exactly today's literal at line 716.
- `@sub_process_completed_suffix :: String.t()` — value `"sub_process_completed"`,
  exactly today's literal at line 1124.

These three values must remain pairwise-distinct (they already are); no
change to any of the three literal values themselves is in scope — this
design only relocates them from three inline occurrences to three named
constants.

## New private helper

```
@spec derive_idempotency_key(
        base :: String.t() | nil,
        suffix :: String.t(),
        ids :: [String.t()]
      ) :: String.t()
defp derive_idempotency_key(base, suffix, ids)
```

**Join semantics (exact, zero ambiguity):** the result is
`[base, suffix | ids]` joined with the literal separator `"::"`, using the same
string-conversion behavior Elixir's `#{}` interpolation and `Enum.join/2` both
already apply per element (via the `String.Chars` protocol) — in particular
`nil` converts to `""` (confirmed: `"#{nil}"` and `Enum.join([nil, "a"], "::")`
both already yield `""`/`"::a"` in this project's Elixir version; no custom nil
handling needed). Equivalent to:

```
Enum.join([base, suffix | ids], "::")
```

- `base` is placed first, unconditionally (even if `nil`).
- `suffix` is placed second, unconditionally.
- Each element of `ids` is placed in the given order after `suffix`, one `"::"`
  between every adjacent pair including between `suffix` and `ids`'s first
  element and between consecutive `ids` elements.
- No trimming, no deduplication, no reordering — literal positional join only.
- `ids` elements are already `String.t()` (UUIDs) at every call site; the
  helper does not need to coerce non-string types.

### Exact call-site arguments (must reproduce today's output byte-for-byte)

1. **`append_instance_started_event_for_child/8`**, replacing line 616-617:
   ```
   idempotency_key:
     derive_idempotency_key(
       Map.get(attrs, :idempotency_key),
       @sub_process_start_suffix,
       [child_instance_id]
     )
   ```
   Reproduces `"#{Map.get(attrs, :idempotency_key)}::sub_process_start::#{child_instance_id}"`.

2. **`append_completion_multi/4`**, replacing line 715-716:
   ```
   error_idempotency_key =
     derive_idempotency_key(
       idempotency_key,
       @sub_process_completion_error_suffix,
       [parent_token.instance_id, child_instance_id]
     )
   ```
   Reproduces
   `"#{idempotency_key}::sub_process_completion_error::#{parent_token.instance_id}::#{child_instance_id}"`.
   Note `parent_token.instance_id` before `child_instance_id`, in that order —
   matching today's literal exactly.

3. **`append_sub_process_completed_event/8`**, replacing line 1123-1124:
   ```
   idempotency_key:
     derive_idempotency_key(
       idempotency_key,
       @sub_process_completed_suffix,
       [parent_instance_id, child_instance_id]
     )
   ```
   Reproduces
   `"#{idempotency_key}::sub_process_completed::#{parent_instance_id}::#{child_instance_id}"`.
   Note `parent_instance_id` before `child_instance_id`, in that order —
   matching today's literal exactly. (Site 3's local variable is also named
   `idempotency_key`, same as site 2's — both are the caller-supplied base
   value threaded in from that function's own parameter/arg list, not the
   derived value; this is pre-existing naming in the current code and this
   design does not rename either.)

All three sites' existing surrounding code (the rest of `event_attrs`, the
doc comments explaining *why* a derived key is needed, the `case
EventStore.append(...)` handling, etc.) is unchanged — only the expression
that computes the derived key value is replaced by the `derive_idempotency_key/3`
call shown above.

## Placement

`derive_idempotency_key/3` is a `defp` — private to `Letflow.Engine.SubProcess`,
placed near the other private helpers in the module (no new public API surface;
nothing outside this module calls it today, and nothing in this design adds an
external caller). The three module attributes are placed together, near the top
of the module, above first use.

## Acceptance criteria (pure-refactor constraint)

1. **Byte-identical output.** For every one of the three call sites, for any
   given set of inputs, the string produced by `derive_idempotency_key/3` via
   the new call site is byte-for-byte identical to what today's inline
   interpolated string would produce for those same inputs — including the
   `nil`-base edge case (`Map.get(attrs, :idempotency_key)` returning `nil`
   converts to `""` exactly as today's `"#{nil}"` does).
2. **No behavior change.** No caller of any of the three functions
   (`append_instance_started_event_for_child/8`, `append_completion_multi/4`,
   `append_sub_process_completed_event/8`) observes any change — same
   `{:ok, _}`/`{:error, _}` shapes, same events written, same
   `event_idempotency` rows, same collision/non-collision behavior against the
   schema-wide-unique index.
3. **No test file changes needed.** Per ISSUE-FIXER's confirmation, no existing
   test asserts on the derived suffix string's internal shape. If
   TEST-RUNNER's run surfaces a test that now fails, treat that as evidence the
   refactor deviated from byte-identical output (criterion 1) — fix the
   refactor, do not edit the test to match new output.
4. `mix compile --warnings-as-errors` exits 0 (no unused-attribute or
   unused-variable warnings introduced by the refactor).
5. `mix format --check-formatted` passes on the changed file.
6. Full `mix test` suite passes with the same pass/fail counts as before this
   change (no regression, no newly-skipped test).

## Security scope note (for SECURITY-REVIEWER)

This change touches `lib/letflow/engine/sub_process.ex`, which does write to a
tenant-scoped event stream (`EventStore.append/2` with a `prefix:` tenant
schema option) — so it is not automatically "no tenant-data path touched" the
way a pure test-harness fix would be. However, the change is scoped narrowly
to **key-derivation formatting only**:

- It does not change which `prefix:` (tenant schema) any event is written to.
- It does not change what data is written in any event's `payload`, `actor_id`,
  `event_type`, or `instance_id` fields — only the `idempotency_key` field's
  value, and only in a way that reproduces today's value byte-for-byte (see
  Acceptance criteria above).
- It does not change the caller-supplied base `idempotency_key`'s own scoping
  or validation — that value flows in unchanged from `create/2`/`complete_task/3`
  callers, exactly as today.
- It introduces no new string interpolation of raw tenant/user input into SQL —
  `idempotency_key` is bound as an Ecto changeset field value, not
  interpolated into a raw SQL string, both before and after this refactor.

Given this, SECURITY-REVIEWER's INV-1..INV-8 checklist should apply cleanly and
quickly — flagging this explicitly here so the pass doesn't need to rediscover
the scope from scratch, not to preempt or skip the gate itself.

## Invariants

- The three suffix literal values (`"sub_process_start"`,
  `"sub_process_completion_error"`, `"sub_process_completed"`) are unchanged —
  only their storage location moves from inline string literals to module
  attributes.
- The `"::"` join separator and positional order (`base`, `suffix`, then each
  id in the order shown per call site above) are unchanged from today's
  interpolated strings.
- `derive_idempotency_key/3` has exactly one implementation, used at all three
  call sites — no call site keeps its own inline interpolation after this
  refactor lands.
- No new public function is added; `derive_idempotency_key/3` stays `defp`.

## Open questions

None — ISSUE-FIXER's diagnosis fully specifies the three literal values and
call sites, and no test depends on the derived string's shape, so there is no
unresolved design decision left for ELIXIR-DEV to guess at.
