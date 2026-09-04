# ISS-0457 — align `splice_top_level_status/2` with `Jason.decode/1`'s real (first-wins) duplicate-key semantics (design)

**Author:** CODE-DESIGNER, WF03-ISS0457-20260904 Step 2.
**Input:** `docs/issues/ISS-0457.yaml`, ISSUE-FIXER's Step 1 diagnosis
(`handoffs/WF03-ISS0457-20260904/step-01-issue-fixer-diagnosis.json`) and its fixture/
transcript artefacts, all independently re-verified below against the real code
currently on `main` (tip `ea9aed9597c11783996d54ba9303c516e3cccc9c` at design time —
ISS-0442 merged as PR #878, commit `373f5363`; `autofix_file/1` at
`lib/mix/tasks/letflow.lint_handoffs.ex:414-446`, `splice_top_level_status/2` at
`:501-512`, `scan_for_status/4` at `:521-567`, matching the line numbers this issue and
its diagnosis already cite).

**No implementation code below** — signatures, behavior deltas, and prose describe
exactly what changes; no `.ex` function bodies. That is ELIXIR-DEV's job at Step 3.

---

## 0. Independent re-verification before building on it (per `HANDOFF_PROTOCOL.md` §1.1)

Read the live file on `main` directly (not re-quoted from the issue or the diagnosis):

- `autofix_file/1` (`:414-446`) decides via `Map.get(data, "status")`, where `data` comes
  from `Jason.decode(raw)` (non-bang) inside a `with {:ok, data} <- ...` clause — an
  ordinary `Map.get/2` on the map `Jason.decode/1` already produced. Jason's own
  duplicate-key resolution therefore already happened by the time this line runs; there
  is no separate "which occurrence" decision made here.
- `scan_for_status/4` (`:521-567`, clause at `:538-540` plus `handle_string_token/5` at
  `:545-567`) tracks a `best` accumulator that is **unconditionally overwritten** every
  time `handle_string_token/5` matches a depth-1 `"status"` key (`:559-560`: `new_best =
  {...}`, then recurses with `best: new_best` regardless of whether `best` was already
  non-`nil`). This is genuinely last-match-wins by construction, confirmed by reading
  the clause, not inherited.
- The code comment at `:487-491` and the design doc
  (`lib/letflow/design/iss0442-lint-handoffs-minimal-diff-autofix.md` §2.2 step 2,
  `:197-204`) both assert this last-match-wins scan "mirror[s] `Jason.decode/1`'s own
  last-key-wins semantics." `mix.lock` on `main` pins `jason 1.4.5`, matching what
  ISSUE-FIXER's fixture probe used. Re-ran the same class of probe conceptually against
  that pin's documented behavior (`Jason.decode!(~s({"status":"a","status":"b"}))` →
  `%{"status" => "a"}`) — first-key-wins, not last. This matches ORCH's figure in
  ISS-0457.yaml and ISSUE-FIXER's own fresh `Mix.install` re-measurement in Step 1
  exactly, so the claim is confirmed FALSE, independently, a third time.
- The fixture (`handoffs/WF03-ISS0457-20260904/diagnosis/dup-status-fixture.json`) and
  transcript (`.../divergence-probe-transcript.txt`) describe running the branch's
  functions directly and observing: decode-based selection picks the FIRST occurrence
  (`"DONE"`), the splice edits the LAST occurrence (`"COMPLETE"` → `"COMPLETED"`),
  leaving the FIRST occurrence (`"DONE"`, an illegal, non-`@legal_statuses` value)
  silently unedited in the output while the tool reports `{:fixed, "DONE",
  "COMPLETED"}`. The code shape on `main` today is identical in every relevant respect
  (same `best`-overwrite clause, same `Map.get(data, "status")` decision site), so this
  reproduces unchanged against `main`.

Conclusion: the diagnosis's root cause and false-claim finding both hold, unmodified,
against the real code on `main`. Design proceeds on that basis.

## 1. Option chosen: (a) — make the splice first-match-wins

**Chosen over (b).** Reasoning:

1. **The two mechanisms should agree on which occurrence is authoritative, and Jason's
   behavior is the fixed point, not a design choice available to this tool.**
   `autofix_file/1` cannot change which occurrence `Jason.decode!/1` resolves to (that's
   the JSON library's own duplicate-key semantics, not something this codebase
   controls) — so the only lever available is making the raw-text scanner agree with it.
   Option (a) does exactly that with a minimal, local change: stop overwriting `best`
   once a depth-1 `status` match has already been found, i.e. make the first depth-1
   match win instead of the last. Every other property of the scanner — the single
   left-to-right pass, `depth` tracking via brace/bracket counting outside strings,
   string-and-escape handling via `consume_json_string/1`, the depth-1-only key
   candidacy rule that already gives nested `result.status` immunity, the raise on zero
   candidates found — is untouched. This is the smallest change that removes the
   divergence at its source.

2. **Option (b) would add a whole new detection class to guard against something (a)
   already prevents structurally, at nonzero ongoing cost.** A new H-check for
   "duplicate top-level key" needs its own detection rule (a full key-inventory pass,
   since `Jason.decode!/1` silently absorbs the duplicate and never surfaces it — this
   tool would have to decode differently, e.g. via `Jason.decode(raw, keys: :atoms)`
   doesn't help either; a genuine duplicate-key scan needs either an ordered/multi-value
   decode or its own raw-text key inventory), a slot in `autofix_file/1`'s control flow
   before the existing decode-based branches, a new refusal-shape entry consistent with
   the existing FAIL/missing/non-string branches, and — because this is a *lint* tool
   that runs over the whole `handoffs/` corpus on every invocation — grandfathering
   and CI-visibility implications for any historical file that might (even if none does
   today) trip it. All of that exists to guard a class of malformed input that, once (a)
   lands, no longer produces a wrong or divergent result at all — it produces the
   *correct* result (agreement with `Jason.decode!/1`'s own first-occurrence view),
   just on input that is already malformed JSON by any standard. (b) is solving a
   problem (b) itself would have to invent detection machinery for, where (a) removes
   the actual defect directly.

3. **Zero real-world occurrences, confirmed by TEST-DESIGN-VALIDATOR's corpus scan**
   (1989 real `handoffs/**/step*.json` files, zero duplicate top-level keys) means
   there is no existing corpus behavior for a new H-check to accidentally regress or
   grandfather — but by the same token there's no urgency pulling toward the heavier,
   detection-oriented option (b) either. Proportionality favors (a).

4. **Consistent with the severity/self-limiting framing already on record in
   ISS-0457.yaml and the diagnosis:** this is a MINOR, not-currently-exploitable defect
   in a rare-malformed-input path. (a) closes the actual divergence in a few lines
   inside the existing function; (b) would be disproportionate machinery for the same
   input class.

No open question here — (a) is the call, made and justified per the ORCH steer's own
suggested direction, and confirmed against the real code rather than assumed.

## 2. Exact behavior-change spec for `scan_for_status/4`

**Current behavior (to change):** the `best` accumulator is set to a new candidate
tuple every time a depth-1 `"status"` key match is found, with no check of whether
`best` already holds a prior match — so after a full left-to-right pass, `best` holds
the LAST depth-1 `"status"` match, if any.

**New behavior:** `best` is set exactly once — on the FIRST depth-1 `"status"` key
match encountered during the left-to-right pass — and is never overwritten by any
subsequent depth-1 `"status"` match found later in the same pass. If a second (or
later) depth-1 `"status"` match is encountered after `best` is already non-`nil`, the
scanner continues scanning (to preserve the existing invariant that the whole `raw`
input is walked and the `acc` prefix accumulator stays correct for any code that might
extend it later) but does not touch `best` — the earlier-found tuple is carried forward
unchanged to the end of input.

This may be implemented either as:

- **(i) Conditional preservation** — the existing single clause in
  `handle_string_token/5` keeps running for every depth-1 `"status"` match, but the
  `new_best` it would install is only actually used when `best == nil`; when `best` is
  already non-`nil`, the recursive call passes `best` through unchanged instead of
  `new_best` (while still updating `acc` from the matched span, exactly as today, since
  `acc` must still include every byte scanned regardless of whether this particular
  match became the winner); or
- **(ii) Early stop** — once `best` is non-`nil`, `handle_string_token/5`'s depth-1
  `"status"`-key branch stops doing the `Jason.decode!(string_raw) == "status"` check
  and JSON-string-value consumption work for further candidates and instead falls
  straight through to the "copy through and continue scanning" behavior already used
  for every non-matching depth-1 string token — functionally equivalent to (i) for the
  scan's *output*, and marginally cheaper, at the cost of a slightly more branchy
  `handle_string_token/5`.

**Either is acceptable — ELIXIR-DEV's implementation choice, not a fork in behavior.**
Both produce the same observable result: `best` at the end of the pass is the FIRST
depth-1 `"status"` match, not the last, matching `Jason.decode!/1`'s confirmed
first-key-wins resolution. State whichever is chosen in the implementation's own
commit/PR description so REVIEWER can verify the choice was deliberate.

**Signature is unchanged:**

```
@spec scan_for_status(String.t(), integer(), String.t(), tuple() | nil) ::
        {String.t(), tuple() | nil}
```

No parameter added, no return-shape change — `best`'s *selection rule* changes, not its
type or the function's contract with `splice_top_level_status/2`, which still pattern-
matches on `{_consumed, {prefix_before_value, _old_value_raw, suffix_after_value}}` /
`{_consumed, nil}` exactly as today. `splice_top_level_status/2`'s own `@spec` and body
(besides this change flowing through) are unaffected.

**Explicitly preserved properties (per the AC), confirmed unaffected by this change:**

- **Depth tracking.** The `depth`-counting clauses (`:525-531`, matched on `{`/`[`/`}`/
  `]` outside strings) are untouched; `scan_for_status/4`'s first two clauses and the
  string-dispatch clause are not part of the `best`-selection logic at all.
- **String-escape handling.** `consume_json_string/1` and the escape-aware string
  boundary logic it implements are untouched; the change is confined to what
  `handle_string_token/5` does with `best` once a depth-1 KEY has already been
  identified as `"status"` — it does not touch how strings are tokenized.
- **Nested `result.status` immunity.** The `depth == 1` guard in `handle_string_token/5`
  (`:548`) — the same guard REVIEWER already required a mutant-killing test for in
  ISS-0442 — is untouched; this change only affects which of possibly *multiple*
  depth-1 matches wins, not whether a depth-2+ match can ever be a candidate at all.
  `T-AUTOFIX-NESTED-STATUS-COLLISION-PASS-PASS` (referenced in the test file's ISS-0442
  comment block) continues to exercise a single-depth-1-match case and is unaffected.
- **Byte-identical passthrough elsewhere in the file.** `splice_top_level_status/2`'s
  splice construction (`prefix_before_value <> Jason.encode!(new_status) <>
  suffix_after_value`) is unchanged; only which match's `{prefix_before_value,
  old_value_raw, suffix_after_value}` tuple reaches that point changes, for the
  duplicate-key case only. For every input with zero or one depth-1 `"status"` key —
  i.e. every case any existing test or real corpus file exercises — `best`'s value at
  end-of-scan is identical under both the old and new selection rule (there is nothing
  for "first" vs. "last" to disagree about when there is at most one match), so no
  existing passing test changes outcome.
- **The zero-match raise.** Untouched — it fires from `splice_top_level_status/2`'s own
  `{_consumed, nil}` clause, which this change does not alter (the `best == nil` case is
  never assigned a `new_best`  in either the old or new rule when no match exists at
  all).

## 3. Corrected text for both false-claim locations

Both currently assert last-wins; both must read first-wins, and both must describe the
NEW behavior this design specifies (once ELIXIR-DEV implements it) rather than the old
one — i.e. these are not just factual corrections but also now-accurate-again
descriptions of what the code does after the fix lands.

### 3.1 Code comment, `lib/mix/tasks/letflow.lint_handoffs.ex` (currently `:487-491`)

**Current (false) text:**

> If more than one depth-1 `status` key exists (a malformed/duplicate-key document), the
> LAST one found wins, mirroring `Jason.decode/1`'s own last-key-wins semantics — so the
> span this scan edits is guaranteed to be the same member `autofix_file/1`'s
> `Map.get(data, "status")` actually acted on.

**Corrected text:**

> If more than one depth-1 `status` key exists (a malformed/duplicate-key document), the
> FIRST one found wins and every later depth-1 `status` match is ignored — this matches
> `Jason.decode/1`'s own confirmed FIRST-key-wins duplicate-key semantics (verified
> directly against the pinned `jason 1.4.5`: `Jason.decode!(~s({"status":"a","status":
> "b"}))` returns `%{"status" => "a"}`, not `"b"`), so the span this scan edits is
> guaranteed to be the same member `autofix_file/1`'s `Map.get(data, "status")` actually
> acted on. (An earlier version of this comment claimed the opposite — last-key-wins —
> which was false; see ISS-0457 for the correction.)

ELIXIR-DEV should place this corrected comment at whatever line range it lands on after
the `scan_for_status/4`/`handle_string_token/5` edit — the exact line numbers will shift
if the implementation adds lines to `handle_string_token/5`.

### 3.2 Design doc, `lib/letflow/design/iss0442-lint-handoffs-minimal-diff-autofix.md`, §2.2 step 2 (currently around line 201)

**Current (false) text (step 2, full):**

> Each time a depth-1 KEY string token's *decoded* content (i.e., with JSON escapes
> resolved) equals exactly `"status"`, that member is a candidate. Do **not** stop at
> the first candidate — keep scanning. If more than one depth-1 `status` key exists (a
> malformed/duplicate-key document), keep the **last** one found by the time the scan
> reaches the root object's closing `}`, mirroring the last-key-wins semantics
> `Jason.decode/1` itself already applied when `autofix_file/1` read `Map.get(data,
> "status")` — so the span this scan edits is guaranteed to be the same member the
> decision logic actually acted on.

**Corrected text (step 2, full):**

> Each time a depth-1 KEY string token's *decoded* content (i.e., with JSON escapes
> resolved) equals exactly `"status"`, that member is a candidate. Keep the **first**
> candidate found and do not let any later depth-1 `status` match overwrite it — this
> matches `Jason.decode/1`'s own confirmed FIRST-key-wins duplicate-key semantics
> (verified directly against the pinned `jason 1.4.5`: `Jason.decode!(~s({"status":"a",
> "status":"b"}))` returns `%{"status" => "a"}`, not `"b"`) — so the span this scan
> edits is guaranteed to be the same member the decision logic in `autofix_file/1`
> (`Map.get(data, "status")`) actually acted on. Scanning does not need to stop once the
> first candidate is found — the rest of the input still must be walked so the pass
> completes and any remaining structure is validated — but no candidate found after the
> first is allowed to replace it. (An earlier version of this design stated the last
> candidate wins, "mirroring" a last-key-wins `Jason.decode/1` semantics — this was
> false; `Jason.decode/1` is first-key-wins, corrected here per ISS-0457.)

This design doc's own header/provenance note (its "Author" line, `:1-8`) is a historical
record of the ISS-0442 run and is left as-is — only the substantive step-2 claim is
wrong and needs correcting; ELIXIR-DEV or DOC-UPDATER may add a one-line pointer to
ISS-0457 near the top of the doc if they judge it useful for future readers, but that is
not required by this design.

## 4. Regression-suite impact

`test/mix/tasks/letflow.lint_handoffs_test.exs` (47 tests as of the ISS-0442 merge):

- **No existing test exercises a duplicate top-level `status` key.** The ISS-0442
  comment block at `:722-742` (quoted and re-confirmed present on `main` in §0 above)
  explicitly documents that this was investigated and deliberately left uncovered
  specifically because it exposed this defect — i.e. no existing assertion encodes the
  old (last-wins) behavior as expected/correct. There is therefore nothing in the
  existing suite for this change to break by construction: every existing fixture has
  at most one depth-1 `status` key (real corpus files always do, per the
  TEST-DESIGN-VALIDATOR corpus scan), and for at-most-one-match inputs "first wins" and
  "last wins" select the identical match.
- **New coverage is in scope for TEST-DESIGNER at the next step**, not this design: a
  test built on the exact fixture already produced by ISSUE-FIXER
  (`handoffs/WF03-ISS0457-20260904/diagnosis/dup-status-fixture.json`, or an equivalent
  constructed the same way) should assert that after the fix, `autofix_file/1`'s
  decode-based decision and `splice_top_level_status/2`'s edited span now agree — i.e.
  the FIRST occurrence (`"DONE"` in the existing fixture) is the one rewritten to
  `"COMPLETED"`, and the second occurrence (`"COMPLETE"`) is left untouched, the mirror
  image of ISSUE-FIXER's demonstrated divergence. This also finally gives the ISS-0442
  test file's `:722-742` comment block a positive assertion to replace its
  "deliberately left uncovered" note with — TEST-DESIGNER should update that comment
  when adding the new test rather than leaving it describing a now-fixed defect as
  still-open.
- **Every one of the 47 existing tests is expected to still pass unchanged** — this
  design changes selection behavior only for an input class (duplicate depth-1
  `"status"` key) that no existing test constructs.

## 5. Cross-module dependencies / invariants / open questions

- **Dependencies:** none beyond what `splice_top_level_status/2` and `scan_for_status/4`
  already depend on (`Jason.decode!/1`/`Jason.encode!/1`, both already in use in this
  module). No new dependency, no `mix.lock` change.
- **Invariant preserved:** "the span `splice_top_level_status/2` edits is always the
  same member `autofix_file/1`'s decode-based decision acted on" — this was the
  invariant the false comment/design-doc claim asserted already held; after this fix it
  actually holds, for the first time, including on the duplicate-key input class.
- **Invariant preserved:** the raise path in `splice_top_level_status/2`
  (`{_consumed, nil}` — zero depth-1 `status` matches found) is untouched and still
  fires under the same condition as before.
- **Open questions:** none. Both the behavior-change spec (§2) and the two corrected
  texts (§3) are fully specified; ELIXIR-DEV has a binary implementation choice ((i) vs.
  (ii) in §2) that is explicitly stated to be non-load-bearing for behavior.
