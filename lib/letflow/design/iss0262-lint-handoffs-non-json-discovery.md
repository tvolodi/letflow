# Design: ISS-0262 — `letflow.lint_handoffs` discovers non-JSON handoff files (H6)

**Run:** `WF03-ISS0262-20260822` (GH#510, queue task 262) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR

No implementation code appears in this document. Signatures, type shapes, pseudocode
(`@spec`-annotated, no function bodies), and grandfather-list data only.

---

## 0. Inherited diagnosis, and what I re-verified myself

ISSUE-FIXER's Step-1 diagnosis (`handoffs/WF03-ISS0262-20260822/step-01-issue-fixer.json`,
`result.summary`) is the root-cause source. Per `core-directives.md`'s Instruction
Precedence chain, a handoff's factual claims are checkable, not authoritative — the
following were re-verified directly in this worktree rather than trusted:

| Claim | Verified how | Result |
|---|---|---|
| `handoff_files/0` (`lib/mix/tasks/letflow.lint_handoffs.ex:186-191`) globs only `**/*.json` | Read the file at `HEAD` | **Confirmed**, line 188: `Path.wildcard(Path.join(@handoffs_dir, "**/*.json"))` |
| The WF03-ISS0258-20260822 run has **10**, not 9, Markdown files (ISSUE-FIXER's own correction) | `Glob` of `handoffs/WF03-ISS0258-20260822/*` in this session | **Confirmed — exactly 10**, all `.md`, listed in §3 below |
| `@registry_file` is excluded from discovery today | Read `handoff_files/0`: `Enum.reject(&(&1 == @registry_file))` | **Confirmed** — an exact-path reject on `handoffs/registry.json`, not an extension or pattern rule |
| The full shape of what else lives under `handoffs/` | `find handoffs -mindepth 1 -maxdepth 1 -type f` and `find handoffs -mindepth 2 -type f ! -iname 'step-*'` in this worktree | See §1 — **this changes the discovery design from ISSUE-FIXER's literal suggestion** |

### 0.1 A correction to ISSUE-FIXER's suggested mechanism (found during design, stated per core-directives.md's "no silent re-decision")

ISSUE-FIXER's Recommendation 1 proposes, as one option, `Path.wildcard(Path.join(@handoffs_dir, "**/step-*.*"))`. Measuring the real corpus (§1) shows this exact
pattern is **unsafe**: 14 existing, currently-linted `.json` files are named
`step00-git-setup.json`, `step01-code-design.json`, `step02a-elixir-dev.json`, etc. —
**no hyphen after `step`**. A glob requiring the literal substring `step-` would stop
discovering these 14 files, which is a regression (files the linter sees today would
become invisible), not merely a gap the fix leaves open. §1.2 below designs the
corrected rule: basename starts with `step` (no hyphen required), which is a superset
covering both naming styles actually in use.

---

## 1. What actually lives under `handoffs/` (measured, not assumed)

```
find handoffs -mindepth 1 -maxdepth 1 -type f | sort
```
```
handoffs/escalations.yaml
handoffs/orchestrator.log
handoffs/registry.json
```

```
find handoffs -mindepth 2 -type f ! -iname 'step-*' | sort
```
```
handoffs/WF02-REQ018-20260816/step00-git-setup.json
handoffs/WF02-REQ019-20260816/step00-git-setup.json
handoffs/WF02-REQ019-20260816/step01-code-design.json
handoffs/WF02-REQ019-20260816/step01b-design-gate.json
handoffs/WF02-REQ019-20260816/step02a-elixir-dev.json
handoffs/WF02-REQ019-20260816/step02c-security-review.json
handoffs/WF02-REQ019-20260816/step02d-reviewer.json
handoffs/WF02-REQ019-20260816/step03-test-design.json
handoffs/WF02-REQ019-20260816/step03b-test-design-gate.json
handoffs/WF02-REQ019-20260816/step04-test-run.json
handoffs/WF02-REQ021-20260816/step02a-elixir-dev.json
handoffs/WF03-ISS0198-20260821/redraft-ISS0109-step-02-code-designer.md
handoffs/WF03-ISS0231-20260822/reviewer-verdict.md
handoffs/WF03-ISS0231-20260822/security-verdict.md
handoffs/WF03-ISS0231-20260822/test-design-validator-verdict.md
```

```
find handoffs -mindepth 2 -type f | sed 's/.*\.//' | sort | uniq -c
```
```
    766 json
     14 md
```

### 1.1 Classifying every file this task will ever see

| File / class | Basename starts with `step`? | Extension | Today | Must H6 fire? |
|---|---|---|---|---|
| `handoffs/registry.json` | no | `.json` | excluded by `@registry_file` reject | **stay excluded** |
| `handoffs/orchestrator.log` | no | `.log` | never matched `**/*.json`, invisible | **stay excluded** |
| `handoffs/escalations.yaml` | no | `.yaml` | never matched, invisible | **stay excluded** — not a per-step handoff record, it's a standing roster file |
| `.../step00-git-setup.json`, `.../step01-code-design.json`, … (14 files) | **yes** (no hyphen) | `.json` | matched, linted today | must **stay** matched (regression risk, §0.1) |
| `.../step-01-issue-fixer.json` etc. (752 files) | **yes** (hyphenated) | `.json` | matched, linted today | must **stay** matched |
| `.../redraft-ISS0109-step-02-code-designer.md` | **no** (starts with `redraft-`) | `.md` | invisible today | **stay excluded** — a redraft artefact referencing a step in its name, not itself a step's own handoff record |
| `.../reviewer-verdict.md`, `.../security-verdict.md`, `.../test-design-validator-verdict.md` | no | `.md` | invisible today | **stay excluded** — auxiliary verdict notes, not the step's own `step-NN-*` handoff file |
| `handoffs/WF03-ISS0258-20260822/step-*.md` (10 files) | **yes** | `.md` | invisible today | **must fire H6** — this is the defect ISS-0262 exists to close |

The dividing line the design commits to: **a "handoff-shaped" file is one whose
basename starts with the literal string `step`.** That single rule is what already
distinguishes every row above correctly, without needing a second, separate rule for
"incidental" files — `registry.json`, `orchestrator.log`, `escalations.yaml`, the
`redraft-*` file, and the three `*-verdict.md` files are excluded by the exact same
test that admits both `.json` naming styles, not by a bespoke exception list.

---

## 2. Discovery (`handoff_files/0`) — the exact new mechanism

### 2.1 Signature and glob (**RULING**)

```
@spec handoff_files(dir :: String.t()) :: [String.t()]
```

Broadened glob, replacing the `**/*.json` hardcode:

```
Path.wildcard(Path.join(dir, "**/step*.*"))
```

`step*.*` (glob syntax, not regex) matches a basename that starts with the literal
`step`, contains anything, then a `.`, then any extension — i.e. exactly the set in
§1.1's "yes" rows, both naming styles, any extension. It does **not** match
`registry.json`, `orchestrator.log`, `escalations.yaml`, `redraft-*.md`, or `*-verdict.md`,
because none of those basenames start with `step`.

Then, unchanged in spirit but re-stated precisely:

```
|> Enum.filter(&File.regular?/1)     # a wildcard can, in principle, match a directory; only files are handoff records
|> Enum.reject(&(&1 == registry_file(dir)))   # kept verbatim per the task's explicit instruction (defense in depth — see 2.2)
|> Enum.sort()
```

### 2.2 Why `@registry_file`'s reject is kept even though it is now redundant

The task description requires checking "how `@registry_file` is already excluded and
preserve that." Under the new glob, `registry.json`'s basename (`registry.json`) does
not start with `step`, so the reject clause never actually fires against real input any
more — it is now a **structural invariant statement**, not a live filter: *"whatever
the glob matches, the registry file itself is never treated as a handoff record."* It
is kept because (a) the task requires it preserved, (b) it costs nothing, and (c) it is
one line of defense if a future rename ever produced a file literally named
`stepXX-registry.json` under a run directory — an edge case worth being inert against
rather than silently mishandling.

### 2.3 The `dir` parameter — the one signature change, and why (testability, §6)

Today's `handoff_files/0` takes no argument; it is hardcoded to the module attribute
`@handoffs_dir`. This design adds one default-valued parameter:

```
@spec handoff_files(dir :: String.t() \\ @handoffs_dir) :: [String.t()]
```

`run/1` calls `handoff_files()` exactly as before (default applies, zero behavior
change to the production call site). The parameter exists solely so TEST-DESIGNER can
point discovery at an isolated fixture tree (§6) without ever reading or mutating the
real `handoffs/` directory — mirroring the "pure core, content/path-in" pattern already
used by `Letflow.CheckDeferralStaleness.audit/1` and
`CheckRequirementsRegistration.scan/1` (`lib/letflow/design/iss0258-deferral-staleness-detection.md`
§D1). `registry_file(dir)` is the corresponding one-line helper
(`Path.join(dir, "registry.json")`), replacing the module-attribute
`@registry_file` wherever discovery needs the registry path for a non-default `dir`;
`@registry_file` itself stays as the production default's fixed value, unchanged for
every other caller (`check_registry_coverage/1`, `print_registry/1`, ...).

**Scope statement:** no other function's signature changes because of this parameter.
`check_registry_coverage/1` keeps reading `@registry_file` directly (it is never called
with a non-production directory in this fix — §6 tests discovery and per-file
classification in isolation, not the full `run/1` pipeline against a fixture root).

---

## 3. The disposition of WF03-ISS0258-20260822's 10 `.md` files (**RULING: grandfather, not convert**)

> **SUPERSEDED 2026-08-22 (ISS-0262 Step 8 change-approach rework, rework_count 2).**
> The per-file `@grandfathered` ruling below (and its extension to 2 more
> `WF03-ISS0261-20260822` files by the retry-1 rework) proved unable to keep pace with
> `main`: two Step Final attempts each found new, unrelated runs had landed further
> non-JSON handoff files on `main` faster than this list could be updated
> (`handoffs/WF03-ISS0262-20260822/step-final-git-merge.json`,
> `.../step-final-git-merge-retry1.json`). **§3 and §3.1 below are the historical record
> of the original ruling only and no longer govern H6.** The live mechanism is a
> commit-boundary rule — see
> `lib/letflow/design/iss0262-h6-floor-commit-addendum.md`. H1-H4's per-file
> `@grandfathered` mechanism (§4 and the rest of this document) is unaffected and still
> governs those rules.

**Verified count, this session, against the real directory (not inherited from any
prior claim):**

```
handoffs\WF03-ISS0258-20260822\step-01-issue-fixer.md
handoffs\WF03-ISS0258-20260822\step-02-code-designer.md
handoffs\WF03-ISS0258-20260822\step-02b-code-design-validator.md
handoffs\WF03-ISS0258-20260822\step-03-elixir-dev-MISSING-RETRACTED.md
handoffs\WF03-ISS0258-20260822\step-03-elixir-dev.md
handoffs\WF03-ISS0258-20260822\step-03b-security-scope-test.md
handoffs\WF03-ISS0258-20260822\step-03c-reviewer.md
handoffs\WF03-ISS0258-20260822\step-04-test-designer.md
handoffs\WF03-ISS0258-20260822\step-04b-test-design-validator.md
handoffs\WF03-ISS0258-20260822\step-04c-test-design-validator-regate.md
```

**Exactly 10.** All ten satisfy the §1.1 "handoff-shaped" test (`step*.*` basename), so
without a disposition they would all become new, un-grandfathered `H6` failures the
instant discovery broadens — turning a currently-green `mix letflow.lint_handoffs` red
on files that predate this fix entirely. That is the wrong outcome for a linter whose
own moduledoc states grandfathering exists precisely so "the debt stays visible" without
failing the run for pre-existing, already-resolved history.

**Ruling: grandfather all 10, individually, by exact path, rule tag `"H6"`.** Rationale
(adopting ISSUE-FIXER's Recommendation 2, independently checked against this project's
own precedent rather than taken on faith):

1. **Authenticity.** These are completed, already-reviewed narrative handoffs from a
   *merged and closed* run. Retroactively reformatting finished prose into structured
   JSON risks misrepresenting what was actually attested at the time — the same concern
   `HANDOFF_PROTOCOL.md` §4.1(b)'s "no blanket backfill" rule and ISS-0209's ruling
   ("existing handoffs are not backfilled") already settle for this exact class of
   problem.
2. **Precedent already in this module.** The existing `@grandfathered` list (lines
   127-134) grandfathers 6 pre-ISS-0190 violations the same way: named individually,
   dated in the surrounding comment, traced to the issue that found them, never a
   wildcard or path-prefix rule. This fix's addition is the same shape, one rule tag
   later.
3. **Conversion is materially riskier here than ISS-0190's fixes were.** ISS-0190's
   grandfathered residue was JSON-with-a-wrong-field — a one-field edit if ever
   addressed. These 10 are not JSON at all; "converting" them means authoring 10 new
   structured documents from prose, which is reconstruction, not correction, for zero
   audit-trail benefit (the Markdown stays fully readable and diffable in git either
   way).

### 3.1 Exact `@grandfathered` list addition (data, not code)

Appended to the existing list (`lib/mix/tasks/letflow.lint_handoffs.ex:127-134`), same
tuple shape `{rule, path}`, one entry per file, dated in the surrounding comment exactly
as the existing 6-entry block already is:

```
{"H6", "handoffs/WF03-ISS0258-20260822/step-01-issue-fixer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-02-code-designer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-02b-code-design-validator.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev-MISSING-RETRACTED.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03-elixir-dev.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03b-security-scope-test.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-03c-reviewer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-04-test-designer.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-04b-test-design-validator.md"},
{"H6", "handoffs/WF03-ISS0258-20260822/step-04c-test-design-validator-regate.md"},
```

Comment header for this block (placed immediately above the 10 entries, inside the
existing list, following the existing block's own style): dated 2026-08-22, traced to
ISS-0262/GH#510, stating explicitly "10 pre-existing Markdown handoff files from the
already-closed WF03-ISS0258-20260822 run, invisible to every check before this fix
broadened discovery; grandfathered per H6 rather than converted — see
`lib/letflow/design/iss0262-lint-handoffs-non-json-discovery.md` §3 for the reasoning.
No wildcard: a NEW non-JSON file introduced later is not covered by this list and fails
the build."

**No wildcard, no path-prefix form.** This is not "every file under
`WF03-ISS0258-20260822/`" — it is these 10 exact paths. A future addition to that run
directory (there should not be one; the run is closed) would not be silently exempted.

### 3.2 A second-order consequence this fix must also state (H5 side effect)

`check_registry_coverage/1` derives `disk_run_ids` from the same `files` list
(`lint_handoffs.ex:511-514`). Today `WF03-ISS0258-20260822` contributes **zero** files
to `disk_run_ids` (its only files are `.md`, invisible to the old glob) even though
`grep -c '"run_id": "WF03-ISS0258-20260822"' handoffs/registry.json` returns 0 — the
run_id is doubly invisible: absent from disk-as-seen-by-the-linter and absent from the
registry, so H5's `MapSet.difference` never surfaces the gap. Once discovery broadens,
`WF03-ISS0258-20260822` **will** appear in `disk_run_ids`, and — since it is still not
in `registry.json` — will appear in H5's `missing_from_registry` report for the first
time. This is a **correct, intended side effect**, not a new defect: H5 is advisory-only
(`run/1:156-161`, "report-only, per ISS-0191's own acceptance criteria") and does not
gate the exit code, so this fix does not turn the build red by exposing it — it simply
makes a real, pre-existing registry gap visible where it was previously hidden by the
same bug this fix closes. No action beyond stating this is required by ISS-0262; whether
to add `WF03-ISS0258-20260822` to `registry.json` is a separate, smaller cleanup ORCH may
route separately (§7, open question OQ-2).

---

## 4. H6 — classification logic and violation shape (**RULING**, pseudocode only)

### 4.1 Three-outcome classification, exactly as ISSUE-FIXER framed it

```
@spec handoff_kind(path :: String.t()) :: :json | :non_json
```

Pure, total, no IO. `Path.extname(path) |> String.downcase()` compared against
`".json"`: equal ⇒ `:json`; anything else (including no extension) ⇒ `:non_json`.
Extension-only — content is never consulted to decide *which* branch a file takes, so a
file that happens to hold syntactically valid JSON but is named `step-01-x.md` is still
`:non_json` and still fails H6 (ISSUE-FIXER's explicit recommendation: "a valid-JSON
file with the wrong extension is still a discovery-completeness defect, not exempt").

### 4.2 Where the branch happens — `lint_file/2`'s new first decision

Today `lint_file/2` (`:234-272`) unconditionally attempts `File.read/1` then
`Jason.decode/1` and has exactly two outcomes (schema-checked success, or `PARSE`
failure). This fix inserts `handoff_kind/1` as the first decision, ahead of both:

```
@spec lint_file(path :: String.t(), not_agent_attested_schema :: map()) :: lint_result()
```

Pseudocode (three outcomes, matching the task's exact framing):

```
case handoff_kind(path) do
  :non_json ->
    # OUTCOME 3 — new H6 path. File content is NEVER read here: the defect is the
    # extension/discovery contract itself, not whether the bytes happen to parse.
    violation = %{
      path: path,
      rule: "H6",
      message: "non-JSON handoff-shaped file: #{path} has extension " <>
               "#{inspect(Path.extname(path))}, expected .json",
      grandfathered: grandfathered?("H6", path)
    }
    %{path: path,
      hard_new:          (if violation.grandfathered, do: [], else: [violation]),
      hard_grandfathered: (if violation.grandfathered, do: [violation], else: []),
      advisory: [],
      parse_error: nil}

  :json ->
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      # OUTCOME 1 — unchanged existing path: H1-H4 + advisory, exactly as today
      ...existing body, byte-for-byte...
    else
      {:error, reason} ->
        # OUTCOME 2 — unchanged existing PARSE path, exactly as today
        ...existing body, byte-for-byte...
    end
end
```

**Explicitly not merged with `PARSE`.** ISSUE-FIXER's reasoning, verified and adopted:
`PARSE` means "this claims to be a handoff and its JSON is broken"; `H6` means "this
step artefact was never written as JSON at all." Collapsing them would make the report
read as "broken JSON" for files whose true story is "written as prose, never
structured" — strictly less informative to a reader deciding what to do next.

### 4.3 Violation shape — reuses the existing `violation/4` helper unchanged

No new violation record shape is introduced. `H6`'s violation is a `%{path:, rule:,
message:, grandfathered:}` map exactly like every other rule's, so `print_hard_violations/1`,
the `hard_new`/`hard_grandfathered` split, and the exit-code tally (`run/1:154-181`) all
handle it with **zero changes** beyond `handoff_kind/1` feeding `lint_file/2`'s new
first branch. This is the same reason D4 of the ISS-0258 design reused
`CheckRequirementsRegistration.scan/1` rather than inventing a parallel shape: the
existing `{rule, path}` grandfather tuple and the existing violation map are already
general enough.

### 4.4 Gating — H6 is hard, per ISSUE-FIXER's recommendation, adopted

H6 joins H1-H4 as a **hard** rule: an un-grandfathered `H6` violation is a `hard_new`
entry and therefore participates in `total_new` (`run/1:161`), which gates the exit
code exactly like every other hard rule. Justification, restated and endorsed: "this
step's own audit record isn't machine-readable at all" is a strictly worse defect than a
malformed-but-present JSON file (`PARSE`, already hard), so treating H6 as
advisory-only would invert the module's own existing severity ordering.

**H5 stays report-only, unchanged** (§3.2) — this fix does not touch H5's
exit-code participation, only its input set.

### 4.5 Moduledoc update (scope, not optional)

The moduledoc's "## Checks" → "### Hard" list (`:20-37`) gains one bullet after H5,
stating H6 in the same style as H1-H4: rule name, one-sentence statement of what it
checks, and a note that grandfathering is per-file only, mirroring the existing text
around `@grandfathered`. No other prose in the moduledoc changes; in particular the
"### Advisory" and "## What this task deliberately does NOT check" sections are
untouched.

---

## 5. Backward compatibility — stated explicitly per the acceptance criteria

| Existing thing | Effect of this fix | Why |
|---|---|---|
| The 6 pre-existing `@grandfathered` H1/H2/H3 entries (lines 128-133) | **None.** Untouched, still present, still `{rule, path}` tuples matched by the same `grandfathered?/2` | `handoff_kind/1` for every one of those 6 paths is `:json` (they are all `.json` files) — they take Outcome 1/2, never reach the H6 branch at all |
| Every currently-passing `.json` handoff (752 hyphenated + 14 non-hyphenated `step*.json` files) | **None.** Still discovered (§2.1's glob is a strict superset of `**/*.json` restricted to `step*` basenames — every file the old glob found that also starts with `step` is still found; §1.1 confirms **all** `.json` files under run directories are `step*`-named, so nothing existing drops out) | `handoff_kind/1` returns `:json` for each, routing to the byte-for-byte-unchanged Outcome 1/2 body |
| `registry.json`, `orchestrator.log`, `escalations.yaml`, the `redraft-*.md` file, the three `*-verdict.md` files | **None — stay invisible to this task**, as they are today | None of their basenames start with `step` (§1.1); the new glob does not match them, so they never reach `handoff_kind/1` at all |
| `total_new` / exit code on today's corpus, **before** the WF03-ISS0258-20260822 grandfather entries are added | Would go from 0 to 10 new hard violations | This is exactly why §3.1's 10 grandfather entries are part of *this* fix, not a follow-up — landing the discovery change without them breaks the build |
| `total_new` / exit code on today's corpus, **after** §3.1's entries are added | **0**, same as before this fix (10 H6 violations exist, all grandfathered ⇒ `hard_new` for them is `[]`) | `grandfathered?("H6", path)` is `true` for exactly those 10 paths; `hard_new` filters them out, `hard_grandfathered` reports them (visible debt, non-gating) |
| H5's registry-coverage report | **Gains** `WF03-ISS0258-20260822` in `missing_from_registry` (§3.2) | Advisory-only; does not change the exit code |

---

## 6. Test fixture requirement (for TEST-DESIGNER)

### 6.1 Location and shape — a throwaway fixture tree, never under `handoffs/`

```
test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md
```

A real, committed file (not generated at test time) — a short piece of prose mimicking
a genuine narrative handoff (a sentence or two, no particular schema required, since H6
never reads its content per §4.1). Lives under `test/fixtures/`, **not** under the real
`handoffs/` tree, so it:

- is never discovered by production `mix letflow.lint_handoffs` (which only ever calls
  `handoff_files/0` with its default `@handoffs_dir` argument, per §2.3's scope
  statement),
- never needs a `@grandfathered` entry of its own,
- and is free to be **kept as a permanent fixture** — a real, on-disk, non-JSON,
  `step`-prefixed file — no cleanup/teardown required, no temp-dir plumbing.

The `h6/` subdirectory groups it for readability but is not itself semantically load
-bearing to the discovery glob (`handoff_files/2`'s `dir` argument is pointed directly
at `test/fixtures/lint_handoffs/h6`, or at `test/fixtures/lint_handoffs` if a sibling
`:json` fixture is later wanted for a parallel Outcome-1/2 regression test — out of
scope for this fix, noted for TEST-DESIGNER's discretion).

### 6.2 What it proves, and how, without touching the real corpus

Two independent assertions, using the two entry points this design keeps testable in
isolation (§2.3, §4.1):

1. **Discovery finds it.**
   ```
   files = Mix.Tasks.Letflow.LintHandoffs.handoff_files("test/fixtures/lint_handoffs/h6")
   assert "test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md" in files
   ```
   This is the regression test for §2.1's glob itself — it is what would have caught
   ISS-0262 before it shipped, and what would catch a future accidental narrowing back
   to `**/*.json`.

2. **Classification and violation shape are correct.**
   ```
   result = Mix.Tasks.Letflow.LintHandoffs.lint_file(
     "test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md",
     schema
   )
   assert [%{rule: "H6", grandfathered: false, path: ^path, message: msg}] = result.hard_new
   assert msg =~ ".md"
   assert result.hard_grandfathered == []
   assert result.advisory == []
   ```
   Because the fixture path is not in `@grandfathered`, this proves H6 fires as a
   **gating** (`hard_new`, not `hard_grandfathered`) violation for an un-grandfathered
   non-JSON file — the exact property that must hold for a *new* offender introduced
   after this fix ships, as distinct from the historical WF03-ISS0258-20260822 files
   which must stay grandfathered (§3, a separate fixture group: TEST-DESIGNER asserts
   `lint_file/2` against one real path from §3.1's list returns `hard_grandfathered`,
   not `hard_new`, proving the grandfather mechanism actually suppresses the exit-code
   effect rather than merely existing in the list unused).

### 6.3 Fail-first shape (WF-03 Step 4)

Both `handoff_files/2` (the new default-argument form) and the `handoff_kind/1` branch
inside `lint_file/2` are **new code**, so the pre-fix state is "the function/branch does
not exist" — `handoff_files/0` takes no argument today and `lint_file/2` has no
`:non_json` branch. Per WF-03's fail-first clause for additions, TEST-DESIGNER
additionally records at least one **mutant** (e.g. reverting `handoff_kind/1`'s branch
so `.md` also routes through the `:json` `File.read`/`Jason.decode` path) and shows it
is caught — a `.md` fixture routed through the old two-outcome logic would attempt
`Jason.decode` on prose and produce a `PARSE` violation instead of `H6`, which the
`rule: "H6"` assertion above already distinguishes from `rule: "PARSE"`.

---

## 7. Files touched

| File | Change |
|---|---|
| `lib/mix/tasks/letflow.lint_handoffs.ex` | `handoff_files/0` → `handoff_files/1` with default arg (§2.1, §2.3); new `handoff_kind/1` (§4.1); `lint_file/2` gains the `:non_json` branch ahead of the existing `File.read`/`Jason.decode` body, which is otherwise byte-for-byte unchanged (§4.2); `@grandfathered` gains the 10 `"H6"` entries (§3.1); moduledoc "### Hard" list gains one H6 bullet (§4.5) |
| `test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md` | **new** — the fixture (§6.1), committed, permanent |
| `test/mix/tasks/letflow.lint_handoffs_test.exs` | TEST-DESIGNER's new assertions (§6.2, §6.3) — existing tests in this file must remain green unchanged, since Outcome 1/2 bodies are untouched |
| `docs/issues/ISS-0262.yaml` | status transitions (DOC-UPDATER, later step) |

**Nothing else.** In particular: `mix.exs`'s `letflow.check` alias is not touched (this
task's wiring was already completed by ISS-0257, per `HANDOFF_PROTOCOL.md:1352-1358`);
`check_registry_coverage/1`'s own logic is not touched (§3.2 is a stated consequence of
its existing, unedited behavior, not a code change); no other Mix task, no
`lib/letflow/*` application code, no migration.

---

## 8. Open questions

**OQ-1 — Should `handoff_kind/1` also flag an extensionless file (`Path.extname == ""`)
distinctly from a wrong-extension file?** Not resolved here. §1's measurement found zero
extensionless files under `handoffs/` today, so this is currently a no-op distinction;
`handoff_kind/1`'s pseudocode treats "no extension" as one more case of `:non_json` (its
`message` will read `expected .json` either way), which is correct but not differentiated.
If a future file with no extension appears, H6 already catches it — this OQ is only
about whether the *message text* should special-case it, which is a wording choice, not
a correctness one.

**OQ-2 — Should `WF03-ISS0258-20260822` be added to `handoffs/registry.json` now that
H5 will report it missing (§3.2)?** Left to ORCH as a separate, smaller follow-up. H5 is
advisory-only, so nothing in *this* fix depends on the answer; folding it in here would
widen ISS-0262 past discovery-and-H6, which is not what GH#510 asked for.

---

## 9. Acceptance-criteria traceability

| Acceptance criterion | Answered in |
|---|---|
| New discovery mechanism | §2.1 (`Path.wildcard(Path.join(dir, "**/step*.*"))`), §0.1 (why ISSUE-FIXER's literal `step-*.*` suggestion was corrected), §1.1 (the classification table justifying the rule) |
| H6 check logic and violation message shape | §4 — `handoff_kind/1` (§4.1), the three-outcome branch inside `lint_file/2` (§4.2), the reused violation map (§4.3), hard/gating status (§4.4) |
| Exact grandfather-list additions, verified against disk | §3, §3.1 — 10 exact paths, matched against a fresh `Glob` of the real directory in this session, not assumed from any inherited count |
| Test fixture's exact location/shape | §6 — `test/fixtures/lint_handoffs/h6/step-01-fixture-non-json.md`, why it lives outside `handoffs/`, and the two isolated entry points (`handoff_files/1`, `lint_file/2`) TEST-DESIGNER uses against it |
| Backward compatibility: existing grandfathered entries and existing valid `.json` handoffs must not newly violate H6 | §5 (table), §4.1 (extension-only classification means every `.json` file is unaffected) |
| How `orchestrator.log` and `registry.json` remain excluded | §1.1 (neither basename starts with `step`, so the new glob never matches them), §2.2 (`@registry_file`'s reject kept as defense-in-depth on top of that) |
| No implementation code in the design | This document contains `@spec` lines, one glob pattern, one grandfather-list data table, and prose/pseudocode (`case ... do` shapes describing control flow, not compilable function bodies) |
