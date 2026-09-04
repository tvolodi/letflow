# ISS-0442 — `--autofix` minimal-diff rewrite (design)

**Author:** CODE-DESIGNER, WF03-ISS0442-20260904 Step 2.
**Input:** ISSUE-FIXER's Step 1 diagnosis
(`handoffs/WF03-ISS0442-20260903/step-01-issue-fixer-diagnosis.json`), verified against
`lib/mix/tasks/letflow.lint_handoffs.ex` (current `main`, `write_json!/2` at line 454,
`autofix_file/1` at line 414), `mix.exs`, `mix.lock`, and `docs/issues/ISS-0442.yaml`
directly rather than inherited.

**No implementation code below** — signatures, data shapes, and the rewrite algorithm
are specified precisely enough to build from, but no `.ex` bodies appear. That is
ELIXIR-DEV's job.

---

## 0. Problem restated

`autofix_file/1`'s fixed-branch, in prose rather than as literal source: it takes the
already-decoded map, sets the `"status"` key to the corrected value, and passes the
whole resulting map into `write_json!/2`, which JSON-encodes the entire map with
pretty-printing enabled and writes the result plus a trailing newline to disk.
ISSUE-FIXER reproduced two compounding, independent effects of that whole-document
re-encode on a real 48-line fixture (88 diff lines):

- **Effect (1) — key reordering.** `Jason.decode/1` returns a plain map with no order
  metadata; `Jason.encode!/2` re-sorts every level's keys alphabetically, not just the
  top level.
- **Effect (2) — pretty-print reflow.** `pretty: true` re-flows every value's
  formatting independently of key order — e.g. a short inline array
  `["a", "b"]` explodes to one element per line. This happens even to a file whose
  keys already happen to be alphabetical.

ISSUE-FIXER also demonstrated, on the same real fixture
(`handoffs/WF03-ISS0392-20260901/step-00-git-setup.json`), that this file has **both** a
top-level `status` (lifecycle domain) and a nested `result.status` (PASS/FAIL domain),
and that a handoff with top-level status `"PASS"` sitting alongside a nested
`result.status: "PASS"` is a real, not hypothetical, collision case for any naive
"find the status line" substitution.

## 1. Options considered and the recommendation

### 1.1 Option (a) — `Jason.OrderedObject` / order-preserving round trip

**Version check (re-confirmed directly against the vendored dependency, not inherited
from ISSUE-FIXER):** `mix.exs` declares `{:jason, "~> 1.4"}`; `mix.lock` pins
`jason 1.4.5`. `Jason.OrderedObject` **is available at this exact pinned version** —
`deps/jason/lib/ordered_object.ex` fully implements it, `deps/jason/CHANGELOG.md` shows
it shipped in `1.3.0` (three minor versions before `1.4.5`, not "later in the 1.x
line"), `deps/jason/lib/jason.ex` documents the `objects: :ordered_objects` decode
option, and `deps/jason/lib/encode.ex` implements the `Jason.Encoder` clause for the
struct. No `mix.lock` bump, and no network access, is needed to use it. (An earlier
draft of this section stated the opposite — that OrderedObject was unavailable at
1.4.5 — which was checked directly here and found false; recorded so a future reader
does not have to re-derive this.)

**Rejected anyway, on grounds that don't depend on version availability at all:**
availability doesn't matter, because ordered decode/encode only ever fixes **effect
(1)** (key reordering). **Effect (2) (pretty-print reflow) is untouched by key order**:
`Jason.encode!(data, pretty: true)` always compact-encodes first and then reformats via
`Jason.Formatter.pretty_print_to_iodata` (confirmed by reading
`deps/jason/lib/jason.ex:217-226` and `deps/jason/lib/formatter.ex` directly) — that
reformatting pass reflows indentation, line breaks, and array layout unconditionally,
regardless of what order the keys came in. An inline array, or a file not already in
Jason's own 2-space pretty style, still produces a large diff on re-encode whether or
not key order is preserved. Since ISSUE-FIXER's own reproduction shows effect (2)
contributes real diff lines independently of effect (1) (several of the 88 changed
lines were pure reflow, not reordering), option (a) does not actually deliver "minimal
diff" — it delivers "no key reordering," a strictly weaker property than the one
ISS-0442 is about. It also forces a decode-shape fork: `Jason.OrderedObject.decode!/1`
yields a distinct struct, not a plain map, so either every read site (`autofix_file/1`,
and by extension the four `check_h1..h4` hard checks if they were ever asked to consume
it) needs a second decode shape, or the ordered decode is used **only** inside the
write path with its own separate `Jason.decode/1` call for the value that is already in
hand from `autofix_file/1`'s own read — itself a second decision with more than one
reasonable shape, per ISSUE-FIXER's own flag. Not worth it for a fix that, even once
built, would still only be partial.

### 1.2 Option (c) — leave the rewrite, correct the claim instead

Checked whether this is the right call by locating every place the reviewability claim
is made:

- `docs/issues/ISS-0442.yaml` itself (states the claim was false as measured — this is
  the record of the defect, not a claim to preserve).
- The `--autofix` `@moduledoc` section in `lib/mix/tasks/letflow.lint_handoffs.ex`
  (lines 112–125) states "every fixed file is reported so the action is never silent"
  — this is about **stdout** reporting (true, unaffected either way), not about git-diff
  reviewability; it does not itself overclaim.
  `write_json!/2`'s own comment (lines 448–453) reasons only about machine consumers
  (H3 checks membership, not order) and does not claim diff-minimality at all.
- SECURITY-REVIEWER's ISS-0440 sign-off reasoning (cited in ISS-0442's own
  `description`) is the one place the claim was actually relied on for a decision.

Rejected as the primary fix here: (c) is legitimate only once (a)/(b) are shown
disproportionate, and §1.3 shows (b) is proportionate (a bounded, well-specified
text-scan with no new dependency and no decode-shape fork) — so there is no reason to
retreat to "stop claiming it" when the claim can instead be made true.

### 1.3 Option (b) — RECOMMENDED, with the collision risk designed out structurally

A **structural**, position-aware text substitution — not the naive "find the string
`"status"` and substitute" ISSUE-FIXER correctly flagged as unsafe. The distinguishing
design point: the scan tracks JSON nesting depth and key-vs-value position as it walks
the raw text, so it identifies the top-level `status` member the same way `Jason.decode`
would, and it structurally cannot match `result.status` (or any other nested `status`
key) because that key is never at depth 1. This directly resolves the exact collision
ISSUE-FIXER demonstrated (top-level `"PASS"` next to nested `result.status: "PASS"`) —
not by getting lucky on serialization order, but because the nested key never has
depth 1, by construction, regardless of where it appears in the file.

It also strictly dominates (a) on the actual goal: because it never decodes+re-encodes
the document at all, it is immune to **both** effect (1) and effect (2) — the resulting
diff for a status-only fix is exactly one changed value token, nothing else in the file
is touched, byte for byte (including whitever trailing-newline convention the original
file already had — this design does not force-append `"\n"` the way the current
`write_json!/2` does, because there is no longer a full re-encode to terminate).

No new dependency, no `mix.lock` change, no decode-shape fork elsewhere in the module.

## 2. Algorithm (option (b)) — precise, for ELIXIR-DEV to implement without judgment calls

### 2.0 Where it plugs in

`autofix_file/1`'s decision logic (which case matches FAIL / legal-but-unmapped /
non-string-or-missing / already-legal / in-`@autofix_map`) is **unchanged in every
branch except one**. Only the *action* taken in the already-in-`@autofix_map` branch
changes:

- **Before:** the fixed branch mutates the decoded map's `"status"` key and passes the
  whole map to `write_json!/2`, as described in §0.
- **After:** call a new function (name below) with the **raw file text already bound
  in `autofix_file/1`'s own `with`-clause that reads the file and decodes it** — no
  second file read, and no whole-document JSON encode at all.

`raw` is already in scope in `autofix_file/1` at the point the fixed branch executes
(it is the `with`-clause binding used for `Jason.decode/1` on the very next line), so
no additional file I/O is introduced by this design.

### 2.1 New function shapes

- `rewrite_top_level_status!(path :: String.t(), raw :: String.t(), new_status :: String.t()) :: :ok`
  Top-level entry point, replaces the current call site. Computes the rewritten text via
  `splice_top_level_status/2` (below) and writes it with a single `File.write!/2` call —
  no trailing-newline append (the original file's own trailing-newline convention, or
  lack of one, is preserved automatically because it lies outside the modified span).
  Raises (`Mix.raise/1` or an equivalent loud failure, ELIXIR-DEV's choice of exact
  exception per project convention) if `splice_top_level_status/2` cannot locate a
  depth-1 `status` key — this is an **internal invariant violation**, not a normal
  refusal case: it can only happen if the raw text's structure disagrees with what
  `Jason.decode/1` (already run earlier in `autofix_file/1`, successfully, on the same
  `raw`) reported, which should never occur for valid JSON. Do not fall back to the old
  whole-document re-encode on this failure — that would silently reintroduce the bug
  ISS-0442 is about, and would hide a real bug in the scanner instead of surfacing it.

- `splice_top_level_status(raw :: String.t(), new_status :: String.t()) :: String.t()`
  Pure function (no I/O), implements the scan in §2.2. Returns the rewritten text.
  Raises if no depth-1 `status` key is found (see above).

`write_json!/2` (the current full-document encoder) is removed entirely: `grep` confirms
its **only** call site is the one being replaced (line 420); nothing else in the module
or its test file calls it directly by that name. (The test file's own comment at
`test/mix/tasks/letflow.lint_handoffs_test.exs:399` lists `write_json!/2` as one of the
functions ISS-0440 added — that comment will need a small update by whoever also
updates the tests, noting it's superseded by `rewrite_top_level_status!/3`, but that is
a test-file concern, not part of this design.)

### 2.2 The scan itself — depth- and position-aware, string-and-escape-aware

Walk `raw` left to right, one character at a time, maintaining:

- `depth` — an integer, starts at `0`. Incremented on every `{` or `[` encountered
  **while not inside a string**; decremented on every matching `}` or `]` **while not
  inside a string**. (Both object and array nesting count, because a top-level value
  that is itself an array — none exist in this schema today, but the scanner must not
  assume the schema — would otherwise be mis-tracked.)
- A string-scanning sub-state used whenever the top-level walk encounters an unescaped
  `"` outside of an existing string: consume characters until the next unescaped `"`,
  treating `\` as starting a two-character escape (so `\"` inside a string never ends
  it). This produces, for each string token, its start offset, its end offset, and its
  **depth at the moment the opening `"` was seen** (strings do not themselves change
  `depth`).
- The **root object's members sit at `depth == 1`** (depth becomes `1` the instant the
  file's own opening `{` is consumed; it returns to `1` after each nested container
  closes; anything scanned while `depth >= 2` is inside some nested value and must be
  ignored for key-matching purposes).

For every string token found at `depth == 1`, decide KEY vs VALUE by a purely
syntactic rule — **not** by alternating parity, so it needs no extra bookkeeping and
cannot desync on an odd/malformed structure: **a depth-1 string token is a KEY iff, after
skipping any whitespace that immediately follows its closing quote, the very next
character is `:`.** Any depth-1 string token not immediately followed (mod whitespace)
by `:` is a VALUE token and is never a key candidate.

Algorithm:

1. Scan the whole file once, left to right, as described above.
2. Each time a depth-1 KEY string token's *decoded* content (i.e., with JSON escapes
   resolved) equals exactly `"status"`, that member is a candidate. Keep the **first**
   candidate found and do not let any later depth-1 `status` match overwrite it — this
   matches `Jason.decode/1`'s own confirmed FIRST-key-wins duplicate-key semantics
   (verified directly against the pinned `jason 1.4.5`: `Jason.decode!(~s({"status":"a",
   "status":"b"}))` returns `%{"status" => "a"}`, not `"b"`) — so the span this scan
   edits is guaranteed to be the same member the decision logic in `autofix_file/1`
   (`Map.get(data, "status")`) actually acted on. Scanning does not need to stop once the
   first candidate is found — the rest of the input still must be walked so the pass
   completes and any remaining structure is validated — but no candidate found after the
   first is allowed to replace it. (An earlier version of this design stated the last
   candidate wins, "mirroring" a last-key-wins `Jason.decode/1` semantics — this was
   false; `Jason.decode/1` is first-key-wins, corrected here per ISS-0457.)
3. For the (final) candidate KEY token, continue scanning forward from its closing
   quote: skip the mandatory `:` and any surrounding whitespace, then expect the next
   non-whitespace character to open a JSON string (`"`) — this is guaranteed to hold at
   this call site, because `autofix_file/1` only reaches the fixed branch when
   `Map.get(data, "status")` was already a **string** matching `@autofix_map`'s keys
   (`"PASS"` / `"COMPLETE"` / `"DONE"`), so the raw text's corresponding value token is
   necessarily a JSON string literal, never a number/bool/null/object/array. Capture
   this value token's full span, start quote through matching end quote
   (escape-aware, same string-scan rule as above).
4. Build the replacement text: encode `new_status` as a JSON string literal via
   `Jason.encode!/1` applied to the **plain string** `new_status` alone (e.g.
   `Jason.encode!("COMPLETED")`) — this is a safe, scoped use of `Jason.encode!/1`: it
   quotes/escapes exactly one scalar value with no ordering or pretty-print
   consequence, unlike the whole-document `Jason.encode!(data, pretty: true)` this
   design removes. Since `@autofix_map`'s values are always the literal ASCII string
   `"COMPLETED"` today, this step never actually needs escaping in practice, but the
   design does not special-case that — it uses the general, correct primitive.
5. Splice: return `(text before the value token's start) <> (replacement from step 4)
   <> (text after the value token's end)`. Every other byte of `raw` — indentation,
   other keys, arrays, nested objects, trailing newline or its absence — is copied
   through unchanged because it lies outside the one modified span.
6. If step 2 finds zero depth-1 `status` candidates by the end of the scan, raise (see
   §2.1) — this is the internal-invariant-violation case, and must never be reached in
   practice given `autofix_file/1`'s calling contract.

**Implementation note for ELIXIR-DEV (not a judgment call, a clarification of what
"walk one character at a time" means for a UTF-8 binary):** implement the walk as a
recursive descent over the string using pattern matching on graphemes/codepoints (the
same style already used elsewhere in this module, e.g. `find_dir_flag/1`'s list-based
recursion), accumulating the "already-scanned, unchanged" prefix as you go, rather than
computing numeric byte offsets and slicing — this sidesteps any multi-byte-character
offset arithmetic entirely, since the prefix accumulator is just string concatenation of
pieces already consumed.

## 3. Preserved behavior — explicit, per the issue's own acceptance criteria

- **"FAIL/missing/null/non-string refusal behaviour verified in ISS-0440 is
  unchanged":** `autofix_file/1`'s `case` expression is untouched in every branch
  except the single `status when is_map_key(@autofix_map, status)` branch's action —
  the `"FAIL"` branch, the "legal-but-unmapped" branch, the missing/non-string branch,
  and the already-legal `:skip` branch are not modified at all by this design: same
  match patterns, same `{:refused, ...}` / `:skip` return shapes, same reasons strings.
  Nothing about *which* files get fixed vs. refused vs. skipped changes — only *how* a
  fix is physically written to disk.
- **"no change to the no-flag CI path":** `run/1`'s `if autofix? do ... end` guard
  (line 288) means `run_autofix/1` — and therefore `autofix_file/1`,
  `rewrite_top_level_status!/3`, and `splice_top_level_status/2` — are never invoked at
  all unless `--autofix` is present in `args`. CI's own invocation, via the
  `letflow.check` alias, calls plain `letflow.lint_handoffs` with no `--autofix`. This
  design touches no code on that path; `resolve_dir/1`, `guard_empty_scope/2`,
  `lint_file/2`, and the H1–H6/H-SIZE checks are not modified.
- **Nested-field collision (ISS-0442's core concern):** structurally excluded by §2.2's
  depth tracking — a nested `result.status` (or any `status` key at `depth >= 2`) is
  scanned over but never considered a candidate, regardless of its value or position
  relative to the top-level key in the file.

## 4. Open questions (for ELIXIR-DEV/TEST-DESIGNER, not resolved here)

- **Exception type on the internal-invariant-violation path (§2.1).** This design says
  "raise loudly, do not fall back" but leaves the exact exception module/message format
  to ELIXIR-DEV's judgment, consistent with this module's existing use of `Mix.raise/1`
  elsewhere for user-facing usage errors — this path is not user-facing (it indicates a
  scanner/decoder disagreement), so a plain `raise/1` with a descriptive message is
  likely more appropriate than `Mix.raise/1`, but this is not prescribed.
- **Test coverage this design implies but does not itself write** (TEST-DESIGNER's
  job, WF-03 Step 4): a regression fixture combining a top-level `status: "PASS"` with
  a nested `result.status: "PASS"` (mirroring ISSUE-FIXER's demonstrated collision)
  should assert (a) the file's diff after `--autofix` touches only the top-level value
  token — e.g. by asserting the rewritten file is byte-identical to the original except
  for that one substring — and (b) the nested `result.status` value is untouched. A
  second fixture with an inline single-line array elsewhere in the document should
  assert that array's formatting is untouched post-fix (proof effect (2) is gone, not
  just effect (1)). A third fixture without a trailing newline should assert the
  rewritten file still has no trailing newline (proof this design's write path no
  longer force-appends one).
