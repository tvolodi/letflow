# REQ-213 — `mix letflow.check.test` as a mandatory named step in TEST-DESIGNER and RELEASE-VALIDATOR

**Requirement:** REQ-213 (letflow-queue task 405, GH#794)
**Stage:** S7
**Owner (implementation):** DOC-UPDATER
**Pipeline:** lighter WF-02 variant, no application code — CODE-DESIGNER →
CODE-DESIGN-VALIDATOR → REVIEWER → RELEASE-VALIDATOR → DOC-UPDATER (mirrors the
REQ-163/REQ-164 precedent; no ELIXIR-DEV/SECURITY-REVIEWER/TEST-* since neither `lib/`
nor `test/` is touched).
**Date:** 2026-09-01

This is a **decision/instruction-text-only** artefact — no `.ex`/`.exs` code, no
`lib/letflow/engine/` or other application module involved. Its deliverable is the exact
text DOC-UPDATER must paste into two files, verbatim, at a stated insertion point. This
mirrors REQ-163/REQ-164's "design artefact adapted to the requirement's actual shape"
precedent, but adapted further: those were decision records; this is closer to a
copy-edit/instruction-writing spec, so the "design elements" below are literal target
text plus exact placement, not abstract interfaces.

---

## 0. Facts independently confirmed before drafting the text (do not re-derive these)

**`lib/mix/tasks/letflow.check.test.ex`, read in full (2026-09-01).** Confirmed
behavior, so the two insertions' explanatory sentences state only what this file
actually does, not an assumed shape:

- Shells out to `mix test` as a **fresh subprocess** (`Port.open({:spawn_executable,
  ...})`), streaming combined stdout+stderr live while also capturing it in full.
- After that subprocess exits, greps the captured output for the fixed, stable
  substring `"default values for the optional arguments"` (module attribute
  `@target_substring`).
- **Fails (`Mix.raise`) if either:** the subprocess itself exited nonzero (real test
  failure), **or** it exited `0` but the target substring is present anywhere in the
  captured output — i.e. it fails even on an underlying exit code of 0, specifically
  because the substring is what it's gating on, not the exit code alone.
- Then runs a second, isolated subprocess (`mix test --only wasm_hang`) with the same
  pass/fail contract, for ISS-0352's deliberately-hanging WASM tests — not itself part
  of what REQ-213's two insertions need to explain, but confirms the task's overall
  shape is "run test(s) fresh in a subprocess, grep captured output for the ISS-0069
  substring, fail the task if found regardless of exit code."
- Usage, per its own `@moduledoc`: `mix letflow.check.test` — no arguments.

**`docs/anti-patterns.md`'s "A test helper's default argument goes dead..." entry**
(lines 1830-1885), 7th-occurrence recurrence note, exact language the fix text below
quotes/paraphrases from:

> "...running `mix test` on the exact file containing the dead default is *not*
> sufficient to catch it — only `mix letflow.check.test` (or an equivalent full/isolated
> recompile) reliably surfaces this warning class, because Elixir's incremental compiler
> does not always force a fresh warnings-as-errors compile of already-compiled test
> modules across separate `mix test` invocations within the same `_build` cache."

> "...the fix here is not 'try harder to remember,' it is to add
> `mix letflow.check.test` (not merely `mix test <file>`) as a mandatory, named step in
> TEST-DESIGNER's and RELEASE-VALIDATOR's own instructions, since both are the natural
> last local checkpoints before a PR's own CI run."

These two quotes are the load-bearing source text for AC3 (the "why insufficient"
explanation) and the overall fix (naming the exact command in both files). The 4th
occurrence note (REQ-195, lines 1853-1860) supplies the corroborating mechanism: "plain
compilation of `lib/` does not recompile `test/` files — the warning only surfaces when
the test file itself is actually compiled, e.g. by `mix test` or `mix letflow.check.test`."

---

## 1. Insertion into `.claude/agents/test-designer.md`

**Current file: 68 lines** (read in full above). Structure: `Identity` →
`Mandatory reading` → `Scope test — run this first` → `What you do` (numbered list,
items 1-2, plus the WF-03 regression-test paragraphs) → `Forbidden`.

### 1.1 Exact insertion point

Insert as a **new step 3** immediately after existing step 2 of the `## What you do`
numbered list (lines 44-47 in the current file):

```
2. Test code under `test/letflow/` (unit/integration) or `test/letflow_web/` (API-layer,
   once one exists), following existing project conventions.
```

...and immediately **before** the existing unnumbered paragraph that currently starts
the WF-03 regression-test guidance:

```
For a WF-03 regression test: the test must be shown to **fail against the pre-fix
```

This placement is deliberate, not arbitrary: it sits at the natural "last thing
TEST-DESIGNER does with the test code it just wrote, before the handoff to
TEST-DESIGN-VALIDATOR" point in the existing numbered sequence, per REQ-213's own AC1
("stated as required before the handoff to TEST-DESIGN-VALIDATOR is reported complete")
— the current step 2 is the last concrete production step before the file moves to
"Forbidden"/completion framing, so a new step 3 there is the natural mandatory-gate
slot, not a bolt-on at the end of the file.

### 1.2 Exact new text to insert

```markdown
3. Before reporting the handoff to TEST-DESIGN-VALIDATOR as complete, run
   `mix letflow.check.test` and quote its real output. A bare `mix test <file>` run on
   just the file(s) you wrote is **not sufficient** on its own: Elixir's incremental
   compiler does not always force a fresh warnings-as-errors recompile of an
   already-compiled test module across separate `mix test` invocations within the same
   `_build` cache, so a dead default argument in a test helper you just wrote (e.g.
   `defp fn_name(a, b, c \\ default)` where every call site in the file ends up passing
   `c` explicitly, per `docs/anti-patterns.md`'s "A test helper's default argument goes
   dead..." entry, ISS-0069 — recurred 7 times, REQ-178/187/191/195/203) can compile
   clean in isolation and still be dead code. `mix letflow.check.test`
   (`lib/mix/tasks/letflow.check.test.ex`) forces the fresh recompile and additionally
   greps the captured output for the fixed substring `"default values for the optional
   arguments"`, failing even if the underlying test run itself exited 0 — this is the
   check that actually catches it, not merely running the file's own tests.
```

Numbering note for DOC-UPDATER: the existing WF-03 regression-test paragraph and the
mutant-testing paragraph that follows it are **not** numbered list items today (they are
free-standing paragraphs after the numbered list) — inserting a numbered "3." does not
require renumbering anything else in the file, since nothing after it is currently
numbered "3" or higher.

---

## 2. Insertion into `.claude/agents/release-validator.md`

**Current file: 57 lines** (read in full above). Structure: `Identity` →
`Mandatory reading` → `What you do — independent re-verification, not report-copying`
(prose, containing the existing `scripts/test_parallel.sh` re-run instruction and the
"Run it as a normal, blocking, foreground call..." paragraph) → `Forbidden`.

### 2.1 Exact insertion point

Insert as a **new paragraph** immediately after the existing paragraph that ends:

```
See
`docs/agents/instructions/core-directives.md`'s "No Background Wait For A Cross-Turn
Notification" (ISS-0213, reinforced under ISS-0223 after this exact role hit the stall
live).
```

...and immediately **before** the existing paragraph that currently begins:

```
For each requirement claimed `done` (WF-02) or every `done` requirement in the stage
```

This is the exact placement REQ-213's AC2 requires — "alongside or immediately after
its existing `scripts/test_parallel.sh` re-run instruction, not as a disconnected
addition" — since the `scripts/test_parallel.sh` instruction and its foreground-call
caveat form one continuous block in the current file (lines 30-41), and the new
paragraph extends that same block before the file moves on to the
per-requirement/per-stage re-check paragraph.

### 2.2 Exact new text to insert

```markdown
**Also independently run `mix letflow.check.test`** — not merely
`scripts/test_parallel.sh` or a targeted `mix test <file>` — before reporting this
requirement/stage as done. This is a separate, stricter check: Elixir's incremental
compiler does not always force a fresh warnings-as-errors recompile of an
already-compiled test module across separate `mix test` invocations within the same
`_build` cache, so a dead default argument in a test helper (`docs/anti-patterns.md`'s
"A test helper's default argument goes dead..." entry, ISS-0069 — recurred 7 times, most
recently REQ-203, where it slipped past two TEST-DESIGN-VALIDATOR passes, two REVIEWER
passes, and a RELEASE-VALIDATOR pass that ran `mix test <specific files>` and
`scripts/test_parallel.sh` but not this task) can pass every other local check and still
ship. `mix letflow.check.test` (`lib/mix/tasks/letflow.check.test.ex`) shells to a fresh
`mix test` subprocess and greps its captured output for the fixed substring "default
values for the optional arguments", failing even when the underlying run itself exited
0. You are the last local checkpoint before a PR's own CI run — quote its real output,
same as `scripts/test_parallel.sh`'s.
```

Same run-it-yourself framing as the existing `scripts/test_parallel.sh` instruction (do
not trust a report; quote real output) — this new paragraph deliberately echoes that
file's own established "re-run yourself, do not trust a report" voice per REQ-213's own
instruction, rather than introducing a different tone.

---

## 3. Cross-file consistency

Both insertions:
- Name `mix letflow.check.test` verbatim (AC1, AC2).
- State the same underlying mechanism — the incremental-compiler `_build` cache gap —
  in each file's own voice, not a copy-pasted identical sentence, but grounded in the
  same source language quoted in §0 above (AC3).
- Are concrete about *when* the step runs in that agent's own workflow: TEST-DESIGNER —
  before the handoff to TEST-DESIGN-VALIDATOR is reported complete; RELEASE-VALIDATOR —
  as part of its independent re-verification, before the requirement/stage is reported
  done (AC5).
- Cite `lib/mix/tasks/letflow.check.test.ex` and its confirmed behavior (§0 above),
  matching what the command actually does (AC6).

## 4. `git diff` constraint (AC4)

`git diff` on both files after DOC-UPDATER's edit must show **only** the new paragraph
(or numbered step) inserted at the point specified in §1.1/§2.1 — no reflow of
surrounding prose, no renumbering of any other list item, no whitespace-only changes
elsewhere in either file. DOC-UPDATER should use a single localized `Edit` (old_string =
the exact surrounding text quoted in §1.1/§2.1 above, new_string = that same text with
the new block inserted between) per file, not a full-file rewrite, specifically so the
diff cannot accidentally touch unrelated lines.

## 5. Open questions

None. Both insertion points, both exact text blocks, and the underlying mechanism are
fully specified above from directly-verified sources (the mix task's own code, the
anti-patterns.md entry's own quoted language) — nothing here is left for
ELIXIR-DEV/DOC-UPDATER to improvise or infer.

## 6. Acceptance-criteria coverage map

| AC | Where addressed |
|---|---|
| AC1 (test-designer.md names the command verbatim, before TEST-DESIGN-VALIDATOR handoff) | §1.2, new step 3 |
| AC2 (release-validator.md names the command verbatim, alongside `scripts/test_parallel.sh`, before done) | §2.2, placed immediately after that instruction |
| AC3 (both explain the incremental-compiler cache gap, citing ISS-0069/anti-patterns.md) | §1.2 and §2.2 both state it in their own words; source quotes in §0 |
| AC4 (`git diff` shows only the addition) | §4 |
| AC5 (concrete about WHEN, matching surrounding style) | §3, bullet 3 |
| AC6 (command name/behavior confirmed against the actual mix task) | §0, direct read of `lib/mix/tasks/letflow.check.test.ex` |
