# ISS-0819 — single-file invocation mode for `mix letflow.lint_handoffs`

Design for the fix to ISS-0819 (`docs/issues/ISS-0819.yaml`, queue task 819,
`github_ref: GH-1809`). Diagnosis: ISSUE-FIXER, this run. This doc supersedes the issue
record's own factual claims per ISSUE-FIXER's corrections below; no re-diagnosis is
attempted here.

## 0. Facts taken as given (from ISSUE-FIXER, independently legible in the source read
   for this design)

- `lib/mix/tasks/letflow.lint_handoffs.ex` has no single-file mode today. Its only
  scoping flag is `--dir <path>` (ISS-0440). `handoff_files/1` (line 713) always globs
  `Path.wildcard(Path.join(dir, "**/step*.*"))` — pointing `--dir` at a single file's
  path matches zero files, and `guard_empty_scope/2` (line 413) then `Mix.raise/1`s
  because the supplied `dir != @handoffs_dir`.
- `parse_flags/1` (line 355) explicitly rejects positional arguments (the `remaining !=
  []` branch, line 364) — there is no "just pass a bare path" escape hatch either.
- **Correction to the issue record:** the linter already reports every violation in a
  file, not just the first — `lint_file/2`'s per-file result is threaded through
  `Enum.map(files, &lint_file(&1, ...))` (line 298) and `print_hard_violations/1` /
  `print_advisory/1` both iterate the full `results` list unconditionally (lines
  1129–1187). No first-match-stops behavior exists. **This design does not touch
  reporting/accumulation logic at all** — only the invocation/scoping surface below.
- **Correction to the issue record's `affected_files`:** the real protocol doc is
  `docs/agents/shared/HANDOFF_PROTOCOL.md`, not `docs/agents/protocols/HANDOFF_PROTOCOL.md`
  (the latter path does not exist in this repo). The doc-update item in §6 below targets
  the real path.
- Four call sites carry a directory-shaped assumption that a single-file mode must
  either satisfy or explicitly route around: `handoff_files/1` (discovery),
  `guard_empty_scope/2` (empty-scope guard), `check_registry_coverage/2` (H5,
  `Path.relative_to(dir) |> Path.split() |> hd()` at line 1102), and `run/1`'s banner
  text (lines 331–335, "N handoff files under `dir`").

## 1. Flag surface — decision: extend `--dir` to also accept a file path; no new `--file`
   flag

**Chosen: `--dir` accepts either a directory or a single file.** Detection is by
`File.dir?/1` vs `File.regular?/1` on the resolved path (see §2), not by a second flag.

**Rejected: a distinct `--file <path>` flag.** Reasons:

1. **`OptionParser.parse(args, strict: [...])` (line 357) is a single parse point** —
   adding `file: :string` there is no harder than adding a branch, but it then forces
   every downstream consumer (`run/1`, `resolve_dir/1`, `guard_empty_scope/2`,
   `check_registry_coverage/2`) to carry an `{:dir, path} | {:file, path}` sum type
   through the whole pipeline instead of a single `String.t()` scope value they already
   thread as `dir`. A file-or-directory string is a strictly smaller change surface.
2. **No mutual-exclusion validation to design or explain.** A second flag raises the
   question "what happens if both `--dir` and `--file` are given" — an entirely new
   error case with its own message and its own test. A single flag that accepts either
   shape has no such combinatorial case.
3. **Matches the existing single-parameter shape callers already rely on.**
   `resolve_dir/1` (line 401) is a **public** function other code may call expecting one
   scope string back; keeping the flag singular keeps that contract singular.
4. `git`, `mix format`, and `mix test` (this project's own toolchain) all accept a
   trailing path argument that may be a file or a directory without a separate flag —
   this is the more idiomatic Elixir/Mix precedent to follow, not a project-invented one.

**Result:** the flag stays `--dir <path>`, but its meaning is renamed in the spec from
"directory to scan" to "scan target — a directory (recursive scan) or a single handoff
file (that file only)". No change to `strict: [dir: :string, autofix: :boolean]` at
line 357 — `OptionParser` already accepts any string value for `--dir`; only the
*consumers* of that string need to branch.

## 2. `handoff_files/1` — file-vs-directory branch

Current signature (line 712) stays: `@spec handoff_files(dir :: String.t()) :: [String.t()]`.
Rename the parameter's semantic role in its own `@spec`/moduledoc to `scan_target`
without changing the function name (external callers, including any existing tests,
already call it as `handoff_files/1` — renaming the function itself is unnecessary
churn ISS-0819 does not ask for).

**New behavior, specified as a three-way classification of `target` (evaluated in this
priority order — the first matching row wins):**

| `target` is... | Result |
|---|---|
| a regular file (`File.regular?/1` true) | the one-element list containing just `target` — no wildcard, no directory walk, no filtering against the step-file glob or the `registry.json` exclusion (see the open design point just below for why) |
| a directory (`File.dir?/1` true) | unchanged from today: the existing wildcard-glob-filter-reject-sort pipeline over `Path.join(target, "**/step*.*")`, still excluding `registry_file(target)` and non-regular matches, still sorted |
| neither (path does not exist, or exists as something that is neither a plain file nor a directory) | the empty list — this is unchanged from today's behavior for a bad `--dir` path (the wildcard already finds nothing in that case); `guard_empty_scope/2` is what turns an empty result into a loud failure (see §3) — `handoff_files/1` itself stays a pure "what did I find" query, consistent with its current contract, and does not itself decide what an empty result means |

**Open design point resolved explicitly, not left implicit:** a single-file target is
**not** filtered against the `"**/step*.*"` glob pattern or the `registry_file/1`
exclusion. Rationale: those two filters exist to keep a *directory* scan from picking up
`registry.json` or non-handoff files it stumbles across; a single file the caller named
explicitly has no such ambiguity — if an agent runs
`mix letflow.lint_handoffs --dir handoffs/registry.json` by mistake, it should be linted
(and fail loudly against the handoff schema, which is itself useful signal that the
wrong path was given) rather than silently filtered to `[]` and then hard-raised by
`guard_empty_scope/2` with a confusing "0 files" message that hides the real mistake.
ELIXIR-DEV should add this exact case (`--dir` pointed at `registry.json` itself)
as a named regression test.

## 3. `guard_empty_scope/2` — single-file failure behavior

Current signature and guard (line 412–422) key off `dir != @handoffs_dir` to decide
whether an empty result is an error. That predicate is still correct and needs **no
change** — it already fires for any explicitly-supplied scope (file or directory) that
resolved to `[]`. What changes is only the **message**, so a bad single-file path
produces a message that names the failure mode correctly instead of talking about "0
files" as if a directory scan came up empty.

`@spec guard_empty_scope(scan_target :: String.t(), files :: [String.t()]) :: :ok | no_return()`
— signature unchanged.

**Governing condition, unchanged from today:** the function only takes its failure
branch when `files` is empty AND `target` is not the default `@handoffs_dir` (i.e. the
caller explicitly supplied a scope). Any other case returns `:ok`.

**Within the failure branch, the reason phrase to interpolate into the existing
`Mix.raise/1` message template** (`"letflow.lint_handoffs: --dir <target> <reason> --
refusing to report success for an empty or non-existent scan target"`, template text
unchanged from the existing raise at line 415-418) **is selected by this precedence,
first match wins:**

| Condition on `target` | Reason phrase |
|---|---|
| does not exist on disk | "does not exist" |
| exists and is a regular file | "is a file lint_handoffs could not read" — noted as a defensive branch only: per §2, a regular file always yields a one-element file list from `handoff_files/1`, so this branch is not reachable by any input this design produces; it is specified only so the function has a defined, non-crashing behavior if that invariant is ever violated by a future change |
| anything else (existing directory-empty case) | "discovered 0 files" — unchanged wording from today |

**Concretely, the case this closes:** `mix letflow.lint_handoffs --dir
handoffs/WF03-X/step-01-agent.json` where that path is mistyped or the file was never
written — today this would already `Mix.raise/1` (files == [] because the wildcard
under a non-directory path matches nothing), so the loud-failure property ISS-0819
requires ("a missing/bad file path must still fail loudly, not silently report
success") is **already satisfied by the existing predicate**, before any code changes.
The only defect being fixed here is that a *valid* file path currently also hits this
same raise (because `handoff_files/1` doesn't yet know how to scan a single file) — §2
fixes that by making `handoff_files/1` return `[target]` for a valid file, so
`guard_empty_scope/2` never even sees an empty list on the valid-file path. The message
wording above is a secondary improvement (a bad file path should say "does not exist"
rather than the directory-flavored "discovered 0 files"), not the load-bearing part of
this guard.

## 4. `check_registry_coverage/2` (H5) — single-file mode behavior

**Decision: skip H5 in single-file mode.** `check_registry_coverage/2` reports, not
gates (§ moduledoc H5 description, `run/1`'s comment at lines 309–313: "H5 ... is
report-only"), so skipping it loses no gating behavior — only a report section.

**Rationale for skip over run_id-from-path derivation:**

1. **`run_id` derivation assumes directory structure that a single file may not have.**
   The existing derivation (line 1102) is `Path.relative_to(dir) |> Path.split() |> hd()`
   — it takes the *first path segment relative to the scanned directory*, which is only
   meaningful when `dir` is the immediate parent of `<run_id>/`. A single file's own
   path segment immediately above it is not guaranteed to be a `run_id` under
   single-file mode's calling convention — an agent may reasonably invoke
   `mix letflow.lint_handoffs --dir <full/path/to/step-04-agent.json>` from any
   directory, including one where the immediate parent is not named after a run.
   Deriving a `run_id` from an unreliable assumption and reporting it as if it came from
   the same reliable path directory-mode uses would produce a *misleading* H5 report
   (a wrong "missing from registry.json" claim) — worse than reporting nothing.
2. **What H5 verifies isn't meaningful for one file anyway.** H5 checks two-way coverage
   between `handoffs/<run_id>/` directories on disk and `registry.json`'s `runs[]`
   entries — inherently a corpus-level, not a file-level, property. A single file being
   linted mid-write (the exact ISS-0819 use case: "validate a handoff at the moment they
   write it") usually has not yet had its run registered or its sibling steps written,
   so a "missing from registry.json" hit here would routinely be a false positive noise
   source for the one workflow this feature exists to serve, not a real finding.
3. Skipping is representable with **zero new state**: `check_registry_coverage/2` already
   returns `%{missing_from_registry: [...], missing_on_disk: [...]}`; single-file mode
   makes it return `%{missing_from_registry: [], missing_on_disk: []}` immediately,
   without reading `registry.json` at all.

`@spec check_registry_coverage(files :: [String.t()], scan_target :: String.t()) ::
%{missing_from_registry: [String.t()], missing_on_disk: [String.t()]}` — signature
unchanged.

**Behavior, as a two-way branch on `target`:**

| `target` is... | Result |
|---|---|
| a regular file | the fixed result `missing_from_registry: []`, `missing_on_disk: []`, returned immediately — `registry.json` is not read at all in this branch (H5 is skipped in single-file mode) |
| anything else (the existing directory-mode case) | unchanged from today: the existing body at lines 1099–1124 (disk `run_id`s vs. `registry.json`'s `runs[].run_id`s, set-differenced both ways) |

`print_registry/1` (line 1189) needs **no change** — an empty pair of lists already
prints as `run_id on disk but missing from registry.json: []` / `run_id in registry.json
but missing on disk: []`, which is accurate (H5 found nothing to report because it did
not run against a meaningful scope) but could read as "checked, found clean" rather
than "not applicable." §5 below adds a one-line banner note to disambiguate this, since
silently-empty-and-looks-clean is exactly the kind of "scoped output confused with
full-corpus result" failure mode ISS-0440 and this issue both call out. Add, printed
directly above the existing two lines in `print_registry/1`, one additional output line
that appears only when `target` is a regular file (single-file mode), stating that H5
was skipped because it is a corpus-level check — wording left to ELIXIR-DEV, matching
this file's existing terse report-line style (e.g. the two lines it already prints
immediately below).

## 5. Banner/output wording — single-file runs must be visually distinct from both
   full-corpus and `--dir <directory>` runs

`run/1`'s existing banner (lines 331–335) reads, on success:

```
letflow.lint_handoffs: OK -- 0 new violations across <N> handoff files under <inspect(dir)>
  (<G> pre-existing grandfathered, traced to ISS-0190).
```

This already disambiguates the default full-corpus run from a `--dir <directory>` run
(ISS-0440's own concern), by naming `dir` — `under "handoffs"` vs. `under
"handoffs/WF03-X"`. **That naming already extends correctly to a single file with zero
further change**, since `inspect(target)` for a file path prints the file path — e.g.
`under "handoffs/WF03-X/step-04-agent.json"` — which is already textually
distinguishable from any directory path by inspection. The literal risk ISS-0819 raises
is that "N handoff files" reads identically whether N=1 came from a directory that
happened to contain exactly one step file, or from an explicit single-file target — that
distinction is not about the *target*, it's about the *scan mode*.

**Fix: make the banner name the mode explicitly, not just the target.** Introduce a
mode-describing phrase, selected by a two-way branch on whether `dir` (the resolved
scan target) is a regular file:

| `dir` is... | Mode phrase substituted into the banner |
|---|---|
| a regular file | "the single handoff file" |
| a directory (existing behavior, unchanged) | the file count followed by "handoff files", exactly as computed today (`length(files)` interpolated) |

Splice that phrase into the existing OK-banner template in place of the current
hardcoded `"#{length(files)} handoff files"` segment — every other part of the
template (the "OK -- 0 new violations across", "under `<inspect(dir)>`", and the
trailing grandfathered-count clause) stays byte-for-byte as it is today.

Producing, concretely:

- Full corpus (unchanged): `... across 626 handoff files under "handoffs" ...`
- `--dir <directory>` (unchanged in spirit, still plural-N-based):
  `... across 3 handoff files under "handoffs/WF03-X" ...`
- Single-file (new): `... across the single handoff file under
  "handoffs/WF03-X/step-04-agent.json" ...`

The same `mode_phrase` substitution applies to the FAIL banner's line 319 message is
**not required** — that line already names the count of *violations*, not files scanned,
and always fails loudly regardless of mode; no confusion-with-full-corpus risk exists on
the failure path (a failure is a failure, scoped or not). Only the OK-path banner, which
is the one a human/agent skims to confirm "clean," needs the mode word.

## 6. Documentation updates

### 6.1 `docs/agents/shared/HANDOFF_PROTOCOL.md` — usage section (~lines 1353–1445)

Add, directly after the existing "**Run it:**" fenced block (line ~1360, `mix
letflow.lint_handoffs`) and before the "A plain `Mix.Task`..." paragraph, a new
sub-block:

```markdown
**Run it against a single handoff, before finishing your own step** (ISS-0819):

​```
mix letflow.lint_handoffs --dir handoffs/<run-id>/<your-step-file>.json
​```

Same schema checks as the full-corpus run, scoped to the one file. H5 (registry
coverage) is skipped in this mode — it is a corpus-level check, not a per-file one; the
full-corpus run at CI time still covers it. This does not replace the CI gate (which
still runs the unscoped, full-corpus `mix letflow.lint_handoffs` unconditionally as
part of `mix letflow.check`) — it is an earlier, optional, local check that lets you
catch and fix your own handoff's schema violations before they reach that gate.
```

(Backtick fences above are written as `​``` ` with a zero-width-joiner escape only for
this design doc's own Markdown rendering; ELIXIR-DEV should write ordinary triple
backticks in the real edit.)

### 6.2 `docs/agents/instructions/core-directives.md` — "lint your own handoff before
   finishing" convention

Insertion point: inside the existing "## ⛔ Bookkeeping Is Not Optional" section (line
588), as a new numbered item **4**, immediately after item 3 (the requirement-run-history
append-only rule, ending ~line 622) and before the closing `---`. This section is the
right home because it already collects mechanical, no-discretion handoff/bookkeeping
obligations ("timestamps come from the clock," "the run history is append-only") — this
is the same shape of rule: a mechanical step every agent takes before considering a
handoff finished.

```markdown
**4. Lint your own handoff before finishing.** Before your step is done, run

​```
mix letflow.lint_handoffs --dir <path to the handoff file you just wrote>
​```

against the file you are about to hand off (ISS-0819). This is scoped to your one file
— it is not a substitute for the full-corpus `mix letflow.lint_handoffs` that already
runs, unconditionally and unchanged, as part of `mix letflow.check` at the CI gate (see
`HANDOFF_PROTOCOL.md`'s Enforcement note). It exists so a schema violation is caught and
fixed at the moment of authorship, not discovered — possibly stacked with several other
agents' violations in the same run, masking each other — only when the CI gate runs
after the whole pipeline has already completed.
```

No other role file (`.claude/agents/*.md`) is edited — per ISSUE-FIXER's diagnosis, none
of them currently mention the linter at all, and `core-directives.md` is read by every
role at session start (per this project's own "Mandatory reading" convention), making
one insertion here equivalent in reach to editing every role file individually, without
the drift risk of N separately-maintained copies of the same instruction.

## 7. Summary of the exact functions/files this design touches

| Location | Change |
|---|---|
| `handoff_files/1` (line 712) | Branch: `File.regular?` → `[target]`; `File.dir?` → existing wildcard body; neither → `[]` (unchanged fallthrough) |
| `guard_empty_scope/2` (line 412) | Predicate unchanged; message branches on `File.exists?`/`File.regular?`/`File.dir?` of `target` for a more accurate reason string |
| `check_registry_coverage/2` (line 1099) | New guard clause: `File.regular?(target)` → return empty-pair result immediately, skipping registry read entirely |
| `print_registry/1` (line 1189) | One new conditional `IO.puts` line noting H5 was skipped, when in single-file mode |
| `run/1` (lines 331–335) | OK-banner text: `mode_phrase` branches on `File.regular?(dir)` between `"the single handoff file"` and `"#{length(files)} handoff files"` |
| `parse_flags/1`, `resolve_dir/1`, `@spec`s | No signature change — `--dir` already accepts an arbitrary string; only downstream consumers branch on what kind of path it names |
| `docs/agents/shared/HANDOFF_PROTOCOL.md` (~line 1360) | New usage sub-block for single-file invocation, directly under the existing "Run it:" block |
| `docs/agents/instructions/core-directives.md` (§"Bookkeeping Is Not Optional", after item 3) | New item 4: "Lint your own handoff before finishing," naming the exact command |

No change to: `lint_file/2`, any H1–H6/H-SIZE-1..3 rule body, `run_autofix/1`,
`parse_not_agent_attested_schema/1`, `.github/workflows/` (the issue's own
`fix_direction` says explicitly: "Leave the CI gate unchanged and authoritative").

## 8. Open questions

None outstanding for ELIXIR-DEV to resolve by guessing. Two decisions in this doc were
close calls and are recorded above rather than left implicit, per this project's
design-doc convention:

- §1: `--dir` accepts a file vs. a new `--file` flag — decided in favor of extending
  `--dir`, with the four reasons given.
- §4: H5 skip vs. run_id-from-path derivation in single-file mode — decided in favor of
  skip, with the three reasons given.

ELIXIR-DEV should add the following as named regression tests when implementing (test
design is TEST-DESIGNER's job, not enumerated here as a spec, only flagged as
must-cover so nothing here is silently left untested):

- A valid single-file `--dir <file>` run reports the single file's violations (or a
  clean OK) with the new single-file OK-banner wording.
- A single-file `--dir <file>` run where `<file>` does not exist still `Mix.raise/1`s
  (the existing predicate already covers this; a regression test should pin it so a
  future change to `handoff_files/1` can't silently regress it).
- A single-file `--dir <file>` run's H5 report section shows the skipped-note, not a
  false "missing from registry.json" claim.
- `--dir handoffs/registry.json` (an existing file, but not a step file) is linted (not
  silently filtered to `[]`) per §2's explicit resolution.
- The existing `--dir <directory>` and no-flag (`@handoffs_dir`) paths are unchanged —
  regression, not new coverage, but worth a smoke assertion given how many functions
  this design touches.
