# Design: ISS-0883 — indentation-robust `entries/1` + new A11 indent-consistency assertion

## Context / problem statement

PR #1972 appended two `requirement_status.v24.yaml` entries at 0-space `- req:`
indent instead of the documented 2-space convention (see the volume's own
header, `docs/status/requirement_status.v24.yaml` lines 22-28: `  - req: ...`
/ `    event: ...`), and left the index's declared `entries:` count at 0
instead of 2. Both were hand-fixed on `main` by 9ff7a428/ad384204.

Root cause (ISSUE-FIXER, confirmed by reading code): assertion A9
(`test/docs/requirement_status_invariants_test.exs`, "every indexed volume's
declared `entries:` count equals what is actually on disk") delegates the
on-disk count to `Letflow.Test.StatusHistory.entries/1`
(`test/support/status_history.ex`). `entries/1`'s list-item regex is
hard-anchored to exactly 2-space indent:

```
item_match = Regex.run(~r/^  - ([a-z][a-z0-9_]*): ?(.*)$/, line)
```

and its field regex to exactly 4-space indent:

```
field_match = Regex.run(~r/^    ([a-z][a-z0-9_]*): ?(.*)$/, line)
```

A 0-indent entry never matches either, so `entries/1` silently counted **0**
real entries in v24.yaml — which happened to equal the (also wrong) declared
`entries: 0`. Two bugs canceled out and produced a false-green A9. The
defect is that A9 is not indentation-robust: a malformed append can fool it
into false *agreement* instead of being caught as a mismatch.

This is a fix to test-support infrastructure only. No application code, no
migration, no `lib/letflow/` runtime change.

## Files changed

1. `test/support/status_history.ex` — `entries/1` (regex + accumulator logic)
2. `test/docs/requirement_status_invariants_test.exs` — new assertion **A11**
   (next free letter; A0–A10 already exist — A10 was added by a later fix
   without renumbering, so A11 is correct, not A10 as the issue's initial
   framing guessed)

No change to `docs/agents/instructions/core-directives.md` or
`.claude/agents/doc-updater.md`: the 2-space convention is already correctly
documented in each volume's own header (the copy an appending agent actually
reads, per A8's own rationale). Nobody was failing to follow a convention
they didn't know about; the gap was purely in the machine check.

## Part 1 — `entries/1`: indentation-tolerant matching, indent recorded per entry

### Current behavior (both regexes hard-anchored)

- Item line must be *exactly* `"  - key: value"` (2 spaces, dash, space).
- Field line must be *exactly* `"    key: value"` (4 spaces).
- Anything else (0-space, 3-space, tab, etc.) is silently invisible to
  `entries/1` — not counted, not flagged, just dropped on the floor.

### New behavior

**Item regex** — accept any non-negative amount of leading whitespace, and
capture it:

```
~r/^( *)- ([a-z][a-z0-9_]*): ?(.*)$/
```

Group 1 is the leading-space run (possibly empty string). Its length
(`String.length/1`) becomes the entry's recorded `indent` — see below. This
is the change that makes a 0-space (or 1-, 3-, 5-space, …) `- req:` line
still recognized and counted, closing the "silently invisible" gap that let
PR #1972's malformed append produce a false 0-vs-0 agreement.

**Field regex** — also widened to accept any leading-whitespace run, captured
the same way:

```
~r/^( *)([a-z][a-z0-9_]*): ?(.*)$/
```

But unlike the item regex, a field-line match is only *accepted* into the
current entry when its captured indent equals `current_entry.indent + 2` —
i.e. the field must be indented exactly 2 more than *that entry's own item
line actually was*, not a hardcoded absolute 4. This is a relative check
computed in the `Enum.reduce/3` accumulator logic (Elixir-level `if`, not
regex lookbehind — regex cannot reference a previous line's capture). A field
line whose indent doesn't match that relation is treated as no field match
(falls through to the reducer's existing no-op clause), exactly as an
unrecognized line does today.

Rationale for the relative (not absolute-widened) field check: widening the
field regex to accept *any* indent unconditionally would let unrelated
deeply-indented text inside a `note: >` block-scalar body (e.g. free text
that happens to contain `word: something` at some incidental indent) get
misparsed as a stray field of the current entry. Anchoring field-acceptance
to "exactly 2 more than this entry's actual item indent" preserves the
original precision (2-space item / 4-space field is just the `indent=2`
special case of this general rule) while still correctly re-associating an
entry's fields when the whole entry — item line *and* its field lines — was
appended at a uniform wrong offset (e.g. all at 0/2 instead of 2/4).

Concrete `cond` clause for the field_match branch (the guard that enforces
the relative-indent rule; this replaces the existing
`field_match != nil and acc != []` clause's *condition* only — the merge
body inside stays the `%{current | fields: ..., values: ..., field_lines:
...}` shown at Site 1's discussion above, untouched):

```elixir
field_match != nil and acc != [] ->
  [_, spaces, key, value] = field_match
  [current | rest] = acc

  if String.length(spaces) == current.indent + 2 do
    [
      %{
        current
        | fields: current.fields ++ [key],
          values: Map.put(current.values, key, value),
          field_lines: Map.put(current.field_lines, key, no)
      }
      | rest
    ]
  else
    acc
  end
```

If the indent relation doesn't hold, the clause returns `acc` unchanged
(same effect as falling through to the final catch-all `true -> acc` clause
today) — the line is simply not attached as a field of the current entry.

If a malformed append shifts item and fields *inconsistently* (item at 0,
fields still at 4, not 2) — a stranger and unobserved failure mode — the
fields simply fail to attach to that entry (same degraded-but-safe behavior
as today for any unrecognized line); this is out of scope to solve further
since it isn't the shape of the actual PR #1972 defect and ISSUE-FIXER found
no evidence it occurs.

### New field recorded per entry: `:indent`

`entries/1`'s return shape gains one field. Current shape:

```
%{req:, event:, agent:, at:, line:, fields:, field_lines:}
```

New shape:

```
%{req:, event:, agent:, at:, line:, fields:, field_lines:, indent: pos_integer() | 0}
```

`indent` is the number of leading spaces on that entry's own `- req:` line,
taken directly from the item regex's captured group. This is the value A11
(below) inspects; A9 and every other existing assertion that call
`SH.entries/1` (A4a, A4b, A5, A9, …) are unaffected by the added key — they
destructure the fields they use and ignore extras, per existing Elixir map
pattern-matching in the rest of the file (confirm no assertion currently does
an exhaustive `%{req: _, event: _, ...} = entry` match that would break on an
extra key — none does; they all read named fields via `.req`, `.event`, etc.
or `Map.get`/`raw.values[...]` accessors).

### Exact call sites that must carry `:indent` (both the in-progress accumulator and the final map — do not recompute or default it at either site)

`entries/1` builds entries in two passes: the `Enum.reduce/3` builds a raw,
in-progress accumulator list (each element has keys `:fields`, `:values`,
`:field_lines`, `:line`), then a trailing `Enum.map/2` turns each raw
accumulator element into the function's final, external map (keys `:req`,
`:event`, `:agent`, `:at`, `:line`, `:fields`, `:field_lines`). `:indent`
must be threaded through **both** sites explicitly — it does not exist on
the raw accumulator today, so a literal-minded implementer must add it at
both literal sites shown below, not just at the final one.

**Site 1 — the item_match branch inside `Enum.reduce/3`** (this is where the
raw accumulator element is first constructed; today it has no indent key at
all). Current code:

```elixir
item_match ->
  [_, key, value] = item_match

  [
    %{fields: [key], values: %{key => value}, field_lines: %{key => no}, line: no}
    | acc
  ]
```

Updated code — the item regex now captures the leading-whitespace group
first (`[_, spaces, key, value] = item_match`), and that group's length is
set as `indent:` on the same raw literal, in the same statement that builds
it (not added later, not defaulted):

```elixir
item_match ->
  [_, spaces, key, value] = item_match

  [
    %{
      fields: [key],
      values: %{key => value},
      field_lines: %{key => no},
      line: no,
      indent: String.length(spaces)
    }
    | acc
  ]
```

The field_match branch (the `field_match != nil and acc != []` clause) is
**unchanged in shape** — it still only merges into `current.fields`,
`current.values`, `current.field_lines` via `%{current | ...}`, and does
**not** touch `:indent`, since indent is a property of the entry's item
line, set once at creation, never mutated by its field lines. (See "Field
regex" above for how a field line's own captured indent is validated
against `current.indent + 2` — as a guard on whether to accept it as this
entry's field at all — separately from this `:indent` value itself, which
is never overwritten.)

**Site 2 — the trailing `Enum.map/2` post-processing step** (builds the
function's final, external return map). Current code:

```elixir
|> Enum.map(fn raw ->
  %{
    req: scalar(raw.values["req"]),
    event: scalar(raw.values["event"]),
    agent: scalar(raw.values["agent"]),
    at: scalar(raw.values["at"]),
    line: raw.line,
    fields: raw.fields |> Enum.map(&safe_atom/1) |> Enum.reject(&is_nil/1),
    field_lines: raw.field_lines
  }
end)
```

Updated code — reads `indent: raw.indent` straight through from the raw
accumulator element built at Site 1 above. No recomputation (no re-deriving
indent from a line number or re-running a regex here), no default/fallback
(no `Map.get(raw, :indent, 2)` — that would silently hide exactly the
0-indent malformed-append case this fix exists to catch, since a missing key
would fall back to "looks correct"):

```elixir
|> Enum.map(fn raw ->
  %{
    req: scalar(raw.values["req"]),
    event: scalar(raw.values["event"]),
    agent: scalar(raw.values["agent"]),
    at: scalar(raw.values["at"]),
    line: raw.line,
    fields: raw.fields |> Enum.map(&safe_atom/1) |> Enum.reject(&is_nil/1),
    field_lines: raw.field_lines,
    indent: raw.indent
  }
end)
```

Because `:indent` is set unconditionally at Site 1 (every item_match branch
execution sets it — there is no code path that creates a raw accumulator
entry without it) and read unconditionally at Site 2 (`raw.indent`, a strict
map access that raises `KeyError` if somehow absent, deliberately not
`Map.get/3` with a default), there is no implicit step or silent fallback
between the two sites for an implementer to accidentally skip.

### `@spec` update

```
@spec entries(Path.t()) :: [%{
  req: String.t() | nil,
  event: String.t() | nil,
  agent: String.t() | nil,
  at: String.t() | nil,
  line: pos_integer(),
  fields: [atom()],
  field_lines: %{atom() => pos_integer()},
  indent: non_neg_integer()
}]
```

### Edge cases (per ISSUE-FIXER's list)

- **Volume file that doesn't exist yet.** `entries/1` calls `read_lines/1`
  which does `File.read!/1` — this raises if the file is absent, same as
  today; no change. This is not a new gap: A9 already iterates
  `index.volumes` (i.e. only volumes the index itself declares) and A1
  already asserts "every indexed volume exists on disk, and every volume on
  disk is indexed" runs *before* A9/A11 would ever see a dangling index
  entry in practice within this test file's assertion ordering. A11 relies
  on the same precondition A9 already relies on (an indexed volume exists);
  no new handling is needed or being added.
- **`known_shape_anomalies:` / `known_anomalies:` declared exemptions.**
  These are a different anomaly class entirely — field-shape/vocabulary
  violations checked by A4b and A5 respectively (e.g. an unparseable `at:`,
  an off-vocabulary `event:` value), keyed and exempted through the index's
  own declared-exemption records. Plain list-item indentation is a
  mechanical formatting convention, not content that legitimately varies
  per volume, so **A11 has no exemption path** — it hard-fails
  unconditionally on any non-2-space entry indent, across every indexed
  volume (current and closed alike, matching A9's own already-established
  scope of running across all volumes, not just the current one — see A9's
  existing `index.volumes |> Enum.map(...)` with no status filter).

## Part 2 — new assertion A11

### Placement and numbering

Existing assertions in `test/docs/requirement_status_invariants_test.exs`
run A0 through A10 (A10 was added after this test file's original design doc
—`lib/letflow/design/iss-0119-status-file-readability.md` §7 — was written
for A0–A9 only; the moduledoc comment at the top of the test file still says
"assertions A0–A9", which is already stale independent of this fix). The new
assertion is **A11**, added as its own `test` block after A10's existing
block(s) (A10's positive test and its negative control), following this
file's established one-`test`-block-per-assertion convention (each assertion
gets an isolated block so an earlier assertion's expected failure can't
short-circuit a later one via ExUnit's abort-at-first-failure behavior —
see the moduledoc's existing rationale for A0 vs A3).

Optional, low-risk cleanup bundled with this same edit: update the moduledoc
line "(assertions A0–A9)" to "(assertions A0–A11)" since it's already
inaccurate before this change (silent drift from A10's earlier, undocumented
addition). Not an acceptance-criterion requirement for ISS-0883, but free to
fix in the same diff since ELIXIR-DEV is already touching this file.

### Assertion body (structure, not implementation)

Section comment header, matching the file's existing style:

```
# ── A11 — every on-disk entry's list item is at the documented 2-space
#         indent (ISS-0883 finding) ──────────────────────────────────────
```

Test name (exact string, matching the file's `"A<N>: <description>"`
convention):

```
test "A11: every on-disk entry's list item uses the documented 2-space indent" do
```

Logic shape:

1. Parse the index (`SH.parse_index(@index_path)`), same as A9.
2. For every volume in `index.volumes` (all statuses — current and closed,
   no filter — matching A9's scope), call `SH.entries(v.path)`.
3. Filter to entries whose `indent != 2`.
4. Collect `{path, line, indent, req}` tuples for every violation found,
   across all volumes (flat list, not just the first violation) — matching
   A9's pattern of reporting the *full* mismatch set rather than stopping at
   the first.
5. `assert violations == [], """<failure message>"""`.

### Failure message shape (matching A9's style: what, where, why it matters, what to do)

```
A11 — an entry's `- req:` list item is not at the documented 2-space indent.

  (path, line, actual indent in spaces, req) for each violation:
  #{inspect(violations)}

The 2-space indent is documented in every volume's own header (ENTRY SCHEMA)
and is what HOW-TO-APPEND's append procedure must produce. An entry at the
wrong indent is still counted correctly by A9's on-disk total (entries/1 is
indentation-tolerant), but it is malformed relative to the documented
convention regardless of whether the declared `entries:` count happens to
still be correct — fix the indent in the volume file itself; do not fix this
by changing the convention or adding an exemption, since this is a
mechanical formatting rule, not content that legitimately varies.
```

## Part 3 — the two checks are independent and additive (closing the false-green gap)

Before this fix, a malformed append could get *both* the indent and the
declared count wrong in a way that canceled out (0 real entries seen by the
old regex == 0 declared), producing a false pass on the only check that
existed (A9).

After this fix there are two independent assertions, each covering one axis:

| Scenario | A9 (count on disk == declared) | A11 (item indent == 2) |
|---|---|---|
| Correct append (2-space, count updated) | pass | pass |
| Wrong indent, count coincidentally still correct (declarer manually recomputed and got lucky, or updated it correctly despite the indent slip) | **pass** (entries/1 now counts the 0-indent entries correctly, so declared == actual) | **fail** (entry.indent == 0 ≠ 2) |
| Wrong indent, count also stale (PR #1972's actual shape) | **fail** (entries/1 now sees the real count, e.g. 2, which the stale declared 0 no longer matches) | **fail** |
| Correct indent, count stale (a plain forgot-to-update-the-declared-count slip, no indent problem) | **fail** | pass |

The critical row is the second one: it is the scenario that was previously
invisible (both wrong → false pass). With this fix, it can no longer produce
a false pass, because getting the indent wrong no longer also corrupts the
count that A9 checks — `entries/1` counts a 0-indent entry the same as a
2-space one. A future append that gets *either* the indent or the count
wrong fails at least one of A9/A11; only getting *both exactly right*
passes both.

## Worked example (concrete, using PR #1972's actual shape)

Malformed append (0-space item, fields shifted with it):

```
- req: REQ-422
  event: done
  agent: ELIXIR-DEV
  at: 2026-09-29T00:00:00Z
  note: >
    MOB-5 on-device security hardening.
```

Documented convention (2-space item, 4-space fields):

```
  - req: REQ-422
    event: done
    agent: ELIXIR-DEV
    at: 2026-09-29T00:00:00Z
    note: >
      MOB-5 on-device security hardening.
```

**Before this fix:** old item regex `^  - (...)` does not match the 0-space
line → `entries/1` never sees this entry → on-disk count excludes it. If the
index's declared `entries:` was also never incremented for this append
(PR #1972's actual mistake), declared and actual both read as whatever they
were before the append (e.g. both 0, or both N) → A9 passes → false green.

**After this fix:** new item regex `^( *)- (...)` matches with captured
indent `""` (length 0) → entry is counted → `entries/1`'s on-disk count now
correctly includes it (e.g. actual = N+1). Two independent outcomes follow:

- If the declared `entries:` count was *not* updated to match (PR #1972's
  actual case): **A9 now fails**, correctly reporting `(path, declared,
  actual)` with a real mismatch — the defect A9 was always supposed to
  catch is now caught.
- Separately, regardless of whether A9 passes or fails: **A11 fails**,
  because this entry's recorded `indent` is `0`, not `2` — reporting
  `(path, line, 0, "REQ-422")`. This fires even in the hypothetical case
  where declared and actual counts happen to agree (row 2 of the table
  above), which is exactly the case the old single-check design could not
  distinguish from a fully-correct append.

## Open questions

None outstanding for ELIXIR-DEV — the fix is fully specified: two regex
changes plus one accumulator-level relative-indent check in
`test/support/status_history.ex`, one new `:indent` key on `entries/1`'s
return maps, and one new self-contained `test` block (A11) in
`test/docs/requirement_status_invariants_test.exs` with no new exemption
machinery and no change to documentation prose.
