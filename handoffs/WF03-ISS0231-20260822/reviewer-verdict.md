# REVIEWER verdict — WF03-ISS0231-20260822

- **Agent:** REVIEWER
- **Run:** WF03-ISS0231-20260822 (WF-03 Step 3 gate — idiom / scope / decision-record consistency)
- **Branch:** `fix/WF03-ISS0231-20260822`
- **Diff reviewed:** `git diff main...HEAD` (commits 9504316, 309880a, 282956e, 06db5ea)
- **Verdict:** **PASS** — no MAJOR findings, no MINOR findings. Two NITs and two
  non-blocking observations recorded below; none require rework before TEST-DESIGNER.

Everything below was re-derived in this worktree. No number in the dispatch brief was
accepted as given.

---

## 1. Build-to-design fidelity (§11 governing)

Design read in full, including §11's PASS verdict, MAJOR-1, MINOR-1..5 and the OQ-1..OQ-5
rulings. §11 supersedes §§1–10; the implementation was checked against §11.

| §11 requirement | Result |
|---|---|
| **§11.5** — `TASK_QUEUE.md` sentence replaced with the specified text | **PASS**, see note below |
| **§11.6 / OQ-2** — alias insertion at 0-based index 1 | **PASS** — `mix.exs:66`, immediately after `"letflow.check_toolchain"`, before `"format --check-formatted"` |
| **§11.7 MINOR-2** — `rationale` is `nil` for a bare marker; R3 fires on `nil` or `""` | **PASS** — measured, see §5 M-B |
| **§11.7 MINOR-3** — `impl_order:42` (no space) → `:unclassified`, intended | **PASS** — measured, see §5 M-C |
| **§11.7 MINOR-4** — a bare marker still classifies `:deferred` (rationale is not part of the recognition shape) | **PASS** — measured: state `:deferred` **and** an R3 violation, not `:unclassified` |
| **§11.4** — §3(c) demoted to a sanity check, not a structural defence | **PASS** — the moduledoc's R5 entry (lines 62–67) states exactly this: "The equality half is a cheap aggregation sanity check, not a structural defence (it holds identically by construction); the `entry_count > 0` half does the real work". The implementer did not re-inherit the overclaim the validator struck. |
| §6.3 — `scan/1` takes content not a path; `classify_entry/1` and `render/1` public | **PASS** — all three are `def`, every helper is `defp` |

### On "byte-for-byte" for the TASK_QUEUE.md sentence

The shipped sentence is **word-for-word and punctuation-for-punctuation identical** to
§11.5's specified replacement (verified programmatically under whitespace normalisation:
match `True`). It differs from the fenced block in **line wrapping only** — §11.5 gives the
sentence as one long line; the implementation hard-wrapped it to the ~90-column convention
the rest of `TASK_QUEUE.md` uses.

I am treating this as compliant, deliberately. The fenced block in a design document is a
specification of *prose*, and re-wrapping prose to match the surrounding file is what a
careful implementer should do — shipping a single 606-character line into a hard-wrapped
Markdown file would have been the worse outcome. No word, em-dash, backtick, or bold
marker was altered.

Also verified: the permissive wording is fully gone (`"leave \`impl_order\` absent"` → 0
occurrences, `"(or note"` → 0 occurrences), and §11.5's "Note for the implementer" holds —
line 240's "new `impl_order:` field, or a comment — see the migration note below" survives
unedited and is still correct, since the comment form remains legal and it is bare
*absence* that stopped being legal.

---

## 2. Scope creep — clean

- **`docs/requirements.yaml` is untouched.** `git diff main...HEAD -- docs/requirements.yaml`
  is **empty**. Confirmed directly, not inferred from the diffstat.
- **No `impl_order` value added, removed, or altered anywhere.** Every `impl_order` hit in
  the full branch diff is in prose (`TASK_QUEUE.md`, `ISS-0221.yaml`, the design doc) or in
  the new module's moduledoc/regexes. No data line changed.
- **Files changed match the design's §6.4 table**, plus the two commits the brief named
  separately (`ISS-0221.yaml` record correction, the design doc itself). Nothing else.
- **No premature abstraction.** This is the finding I looked hardest for and did not find.
  There is no behaviour, no macro, no `Letflow.*` namespace invented for pipeline
  meta-tooling, no config knob, no `--strict` flag, no pluggable rule registry, no
  exception/grandfather list of any kind (the design forbade one and none appears). 585
  lines is large for the job, but ~135 of those are moduledoc and ~60 are types/`@spec`s;
  the executable core is roughly 250 lines of straight-line line processing. The moduledoc
  is long because it is carrying the ISS-0231 rationale that would otherwise live only in a
  commit message — that is the project's documented preference (`docs/anti-patterns.md:515`),
  not bloat.
- `test/mix/tasks/letflow_check_requirements_registration_test.exs` is **absent**, which is
  correct — §6.4 assigns it to TEST-DESIGNER at Step 4, not to ELIXIR-DEV.
- Working tree is clean (`git status --porcelain` empty); my scratch probe directories were
  removed.

---

## 3. Decision-record consistency — no re-decision

- **`0005-pin-formatting-toolchain.md` legislates the FIRST alias slot only.** Re-read
  0005: it requires `letflow.check_toolchain` to run first so the toolchain warning is on
  screen before anything else. The new entry is inserted at 0-based index **1** — *after*
  `letflow.check_toolchain`, which still holds slot 0. **0005 is not re-decided, not
  weakened, and not contradicted.** No decision-record escalation is required.
- **No new dependency.** `mix.exs` deps are unchanged: `ecto_sql`, `postgrex`, `plug`,
  `bandit`, `jason`, `stream_data`, `ueberauth_oidcc`. The one-line diff to `mix.exs` is the
  alias entry and nothing else. The design's line-oriented (non-YAML) parsing choice exists
  precisely to avoid a library choice that would need REVIEWER sign-off — the implementation
  honours it. I am not asked to sign off on a dependency because none was added.
- I have **no decision-record disagreement** to register on this change.

---

## 4. Idiom — clean

| Check | Result |
|---|---|
| `Mix.Task` shape | `use Mix.Task`, `@impl Mix.Task`, `@shortdoc`, `def run(_args)` accepting and ignoring the arg list — matches `letflow.check.test`'s precedent |
| Failure path | `Mix.raise/1` only (two call sites: unreadable file → R6, non-empty violations). **No `System.halt`, no `exit/1`.** Grep-verified |
| Supervision | Not applicable and correctly not involved — **no process is started at all**. No `spawn`, `GenServer`, `Supervisor`, `Agent`, `Process.*`, `:ets`. Nothing touches `Letflow.InstanceSupervisor` or any supervision tree; per-instance isolation is unaffected because no runtime code changed |
| Purity of `scan/1` / `classify_entry/1` / `render/1` | **PASS.** `File.` appears exactly once (line 194) and `IO.` exactly once (line 207), **both inside `run/1`**. The pure core has no IO, no filesystem access, no clock, no env read. `scan/1` takes content (`def scan(content) when is_binary(content)`), not a path — the guard makes the "raises only on a non-binary argument" contract real |
| Return value | `run/1` returns `:ok` on success, per `@spec` |
| `cond`/pattern-matching style | Multi-clause `defp classify_registration/2` dispatching on the *arity of the attributed-line list* (`[]` / `[one]` / `many`) is genuinely idiomatic — the three cases are structurally distinct and each gets its own head, rather than one function with a nested `case`. `Regex.run` + `cond` inside the single-line clause is appropriate since both shapes must be tried before falling through |
| Formatter / compiler | `mix format --check-formatted` → exit **0**. `mix compile --warnings-as-errors` → exit **0** |

The `:unclassified` fallback is implemented the way §3(b) demands: `base` is constructed
with `state: :unclassified` and the recognising clauses *override* it. There is no
"everything else is registered" branch anywhere in the module. That inversion — failure as
the default, recognition as the exception — is the structural heart of the fix and it is
built correctly.

---

## 5. The check cannot fail on itself — confirmed

`@requirements_file "docs/requirements.yaml"` is the sole input, read at one call site.
There is no directory walk, no `Path.wildcard`, no `File.ls`, no `lib/` reference anywhere
in the module. The moduledoc does contain both literal surface forms (line 15 carries
`# impl_order: UNREGISTERED -- see the S8 note above`; the field form appears at line 29),
exactly as §6.5 predicted — and it is harmless because the scan never sees `lib/`. §6.5's
standing warning is reproduced in the moduledoc itself (lines 100–104) with the
`docs/anti-patterns.md` citation, so the next person to generalise the scan is warned in
the file they would be editing. Handled correctly.

**Note for whoever writes ISS-0231's acceptance criteria or RELEASE-VALIDATOR's re-check:**
a repo-wide `grep` for either surface form now returns extra hits from this module (and, at
Step 4, from its test file). Any criterion must be scoped to `docs/requirements.yaml`.

---

## 6. Does the gate bite, and is it green today — both re-run by me

### 6a. Green on the live corpus

`mix letflow.check_requirements_registration` — **exit 0**, my actual output:

```
========================================================================
mix letflow.check_requirements_registration -- docs/requirements.yaml
========================================================================
DEFERRED (visible debt -- always reported, never gates):
  S4 (8):
    REQ-128  -- see the S8 note above
    REQ-129  -- see the S8 note above
    REQ-130  -- see the S8 note above
    REQ-131  -- see the S8 note above
    REQ-132  -- see the S8 note above
    REQ-133  -- see the S8 note above
    REQ-134  -- see the S8 note above
    REQ-135  -- see the S8 note above
  S8 (9):
    REQ-115  -- see the S8 note above
    REQ-116  -- see the S8 note above
    REQ-117  -- see the S8 note above
    REQ-118  -- see the S8 note above
    REQ-119  -- see the S8 note above
    REQ-120  -- see the S8 note above
    REQ-121  -- see the S8 note above
    REQ-122  -- see the S8 note above
    REQ-123  -- see the S8 note above
  S9 (4):
    REQ-124  -- see the S8 note above
    REQ-125  -- see the S8 note above
    REQ-126  -- see the S8 note above
    REQ-127  -- see the S8 note above
  total deferred: 21
------------------------------------------------------------------------
111 entries = 90 registered + 21 deferred + 0 neither + 0 unclassified
========================================================================
EXIT=0
```

Totality line matches the brief's expected string exactly. The roster is the full 21 —
REQ-115..135 with no gaps, correctly partitioned S8=9 / S9=4 / S4=8, which reconciles with
the design's §1 stage attribution.

### 6b. The gate bites — eight independent mutations, all against in-memory copies

Run via `mix run --no-start` on a scratch script calling `scan/1` directly. **The tracked
`docs/requirements.yaml` was never modified** (confirmed by a clean `git status` afterward).
My actual output:

```
REQ-120 marker at 0-based line 5749: "    # impl_order: UNREGISTERED -- see the S8 note above\r"
M-A remove REQ-120 marker: counts=%{registered: 90, unclassified: 0, deferred: 20, neither: 1} entry_count=111
   -> [R1] id="REQ-120" line=5745 :: carries no `impl_order` line of any form -- a deliberate deferral must
M-B bare marker REQ-120: counts=%{registered: 90, unclassified: 0, deferred: 21, neither: 0} entry_count=111
   -> [R3] id="REQ-120" line=5745 :: deferral marker carries no rationale after `UNREGISTERED` -- a deferra
   REQ-120 state=:deferred rationale=nil
M-C impl_order:42 (no space) REQ-120: counts=%{registered: 90, unclassified: 1, deferred: 20, neither: 0} entry_count=111
   -> [R2] id="REQ-120" line=5745 :: unrecognised registration form -- attributed impl_order line matches n
M-D anchor: REQ-120 state=:registered impl_order=5
M-E no requirements key: counts=%{registered: 0, unclassified: 0, deferred: 0, neither: 0} entry_count=0
   -> [R6] id=nil line=nil :: no top-level `requirements:` key found -- the file's shape changed und
M-F requirements key, zero entries: counts=%{registered: 0, unclassified: 0, deferred: 0, neither: 0} entry_count=0
   -> [R5] id=nil line=nil :: the requirements section contains zero entries -- a scan that finds no
M-G duplicate id appended: counts=%{registered: 90, unclassified: 0, deferred: 22, neither: 0} entry_count=112
   -> [R4] id="REQ-120" line=5745 :: duplicate requirement id -- appears at lines 5745, 6428
--- purity spot-check: block-note lines at 2-space indent ---
M-H hermetic fixture with 2-space block note: counts=%{registered: 1, unclassified: 0, deferred: 1, neither: 0} entry_count=2
   -> NO VIOLATIONS
```

Reading these against the brief's item 6 and §11.7:

- **M-A (the brief's required mutation)** — removing REQ-120's marker line produces exactly
  one violation, **`[R1]` naming `REQ-120` at line 5745**, and `neither` moves 0→1 while
  `deferred` moves 21→20. The gate bites, and it names the actionable unit rather than a
  bare count. **This is the ISS-0221 condition, and it is now detected.**
- **M-B** confirms **MINOR-2 and MINOR-4 simultaneously**: a bare marker classifies
  `:deferred` (not `:unclassified`), `rationale` is exactly `nil` (not `""`, not a stray
  match), and R3 fires on it naming REQ-120.
- **M-C** confirms **MINOR-3**: `impl_order:42` with no space lands in `:unclassified` and
  raises R2. Intended, and never silently coerced to 42.
- **M-D** is the anchoring check (design mutant M8) and is the one I most wanted to see:
  `impl_order: 5  # was UNREGISTERED until Tuesday` classifies **`:registered` with
  `impl_order: 5`**, *not* `:deferred`. The absorption bug does not reappear with the
  buckets reversed.
- **M-E/M-F** give R6 and R5's non-tautological half. Note M-F is the one that proves
  §11.4's ruling was right to keep R5: a `requirements:` key with zero entries is a hard
  failure, not a silent green pass.
- **M-G** gives R4 with both line numbers.
- **M-H** confirms the ≥4-space attribution rule: a 2-space block-note line mentioning
  `impl_order` between entries is attributed to no entry and produces no violation. Without
  that rule this fixture would have flipped an entry to `:unclassified`.

### 6c. One thing I checked that nobody asked about — CRLF

`docs/requirements.yaml` is **CRLF** in this worktree (visible above: the marker line ends
`...above\r`). Since the pure core splits on `"\n"`, every line carries a trailing `\r`, and
the whole classifier therefore depends on `\r` being absorbed by `\s*` in the anchored
patterns and by `String.trim/1` in `normalise_rationale/1`. If that were wrong, rationales
would silently carry a trailing `\r` and hermetic LF fixtures would diverge from the live
corpus. Measured on a CRLF fixture versus the identical LF fixture:

```
CRLF counts=%{registered: 1, unclassified: 0, deferred: 1, neither: 0} entry_count=2
  "REQ-900" state=:deferred stage="S8" io=nil rat=nil
  "REQ-901" state=:registered stage="S8" io=7 rat=nil
  -> [R3] REQ-900
LF  counts=%{registered: 1, unclassified: 0, deferred: 1, neither: 0}
LF==CRLF entries identical: true
live REQ-115 rationale="-- see the S8 note above" stage="S8"
```

**`entries` are structurally identical between CRLF and LF input** — ids, stages,
`impl_order`, and `rationale` all match, with no `\r` leaking into any extracted string.
Not a finding; recorded because it is load-bearing and was not otherwise verified anywhere
in this run, and because TEST-DESIGNER can now write LF heredoc fixtures without worrying
that they diverge from the live corpus's line endings.

---

## 7. The honest-failure question — D3 is the right call, and I do not think it under-reports

**Ruling: D3 is correct as designed and as built. I do not disagree with it.**

The argument that decides it for me is not D3's own "a red gate gets ignored" — that
argument is true but is also the argument every under-reporting check makes about itself.
What decides it is that **the check's output would have made ISS-0221's false claim
self-refuting**. ISS-0221 asserted "every requirement already carries `impl_order`". Run
this task on the same corpus and the terminal prints a 21-line roster of requirements that
do not, under a header reading `DEFERRED (visible debt -- always reported, never gates)`,
above a totality line that separates 90 from 21. Nobody can hold the ISS-0221 belief while
looking at that output. Under-reporting would mean the information is absent or muted; here
it is the largest thing on the screen, printed on green runs, unconditionally, with no
`--verbose` flag guarding it. Green-but-loud is a real signal; the design earned it by
making the roster non-optional rather than by hiding the debt behind a passing exit code.

And the split is drawn on the right axis. It follows *documentedness*, not registration
state — `:neither` hard-fails precisely because an undocumented absence is
indistinguishable from an oversight, which is the actual ISS-0221 condition. Gating on the
21 instead would gate on a state that is intended, explained in three inline block notes,
and outside this run's scope to change; the gate would be red from the moment it lands,
which is the one thing that reliably destroys a gate's signal.

**Where I do push back — a residual gap that D3 does not close and should not be asked to.**
The `:deferred` bucket is green *forever*, with no expiry and no cross-check against
reality. R3 only requires *some* non-empty text after `UNREGISTERED`, and per OQ-4's ruling
that looseness is deliberate; today all 21 rationales are the single byte-identical string
`-- see the S8 note above`. So the mechanism can tell "documented" from "undocumented", but
it cannot tell "documented and still true" from "documented once and never revisited". The
concrete failure it will not catch: **S8 becomes the active stage, nobody registers
REQ-115..123, and this check stays green while printing the same roster it printed for
months** — an idle pipeline again, with the gate saying PASS.

That is a *different* detector (deferral state cross-referenced against the active stage),
not a defect in this one, and building it now would be exactly the scope creep I am here to
block. So it does not affect this PASS. It is recorded in §8 as a follow-up for ORCH to
register, because an observation that lives only in a verdict file reaches no one.

---

## 8. Findings

### MAJOR
None.

### MINOR
None.

### NIT (no action required; noted for TEST-DESIGNER's benefit)

- **NIT-1 — `classify_entry/1` has no clause for `[]`.** The head is
  `def classify_entry([{line_no, id_line} | body])`, so an empty list raises
  `FunctionClauseError`. This is unreachable from `scan/1` (`split_entries/1` only ever
  emits groups whose first element is the entry-start line), so it is not a bug in shipped
  behaviour. But `classify_entry/1` is **public specifically so fixtures can call it
  directly** (§6.1), and its `@spec` accepts any list — so a TEST-DESIGNER fixture passing
  `[]` will get a crash rather than a defined result. Either add a clause or, more cheaply,
  simply do not write that fixture. Flagging so it is a decision rather than a surprise at
  Step 4.
- **NIT-2 — `@rule` is a horizontal-rule separator string in a module whose entire
  vocabulary is "rules R1–R6".** `@rule String.duplicate("=", 72)` sits ten lines above
  `violation.rule` meaning `"R1".."R6"`. Both readings are live in the same file. Purely
  cosmetic; `@banner`/`@hr` would read better if the file is ever touched again. Not worth a
  commit on its own.

### Type-safety observation (explicitly non-blocking, per my role brief)

`entry()`, `report()`, `violation()` and `counts()` are `@type`-annotated **bare maps**
rather than structs, and `tally/1` does `Map.update!(acc, e.state, &(&1 + 1))` — so a
`state` atom outside the four-element set would raise `KeyError` at runtime rather than
being unrepresentable. A struct with `@enforce_keys`, or a `defguard` over the four atoms,
would close it.

**I am not filing an issue for this**, and I want to be explicit about why rather than let
silence look like an oversight. The state set is produced by exactly one private function
with four total clauses, all within this 585-line self-contained Mix task; there is no
external caller and no serialisation boundary. The blast radius of the gap is one
`KeyError` in a meta-tooling task, and `letflow.lint_handoffs` — the precedent this module
was explicitly built to follow — uses the same bare-map shape. Filing it would spend a queue
slot on a hardening with no reachable failure. It is worth watching only if `Letflow.*`
domain code ever adopts this shape for a state machine's state, which is where the same gap
would actually bite.

### Follow-ups for ORCH to register (I do not allocate ids — `ISSUE_QUEUE.md` §49–50)

1. **(from §7, new — MINOR)** *Deferral staleness is undetected: `mix
   letflow.check_requirements_registration` stays green on a deferral whose stage has since
   become active.* R3 accepts any non-empty rationale (OQ-4, deliberate), so REQ-115..123
   will keep printing green after S8 opens, reproducing the idle-pipeline symptom the check
   was built to surface. Suggested shape: cross-reference each `:deferred` entry's `stage`
   against the active stage and hard-fail when a deferral outlives its justification.
   Affected: `lib/mix/tasks/letflow.check_requirements_registration.ex`.
2. **(carried, not new)** §11.6's OQ-3 ruling obliges this run to surface *"`mix
   letflow.lint_handoffs` is built but wired into no gate"* (MINOR) in `result.issues`. I
   re-confirmed the underlying fact while checking D1: `mix.exs` contains no reference to
   `letflow.lint_handoffs`. Repeating it here so it is not dropped between Step 3 and the
   run's result block.

---

## 9. Gate outcome

**PASS.** The implementation is faithful to §11 on every point the brief named and on every
point I re-derived independently; scope is clean with `docs/requirements.yaml` provably
untouched; decision record 0005 is not re-decided; no dependency was added; the Mix task is
idiomatic with a genuinely pure core; the module cannot fail its own check; the gate is
green today and bites on all six rules under my own mutations.

**TEST-DESIGNER is unblocked** for WF-03 Step 4, building §7.4 as amended by §11.4 and
§11.7, plus NIT-1 and §6c above.
