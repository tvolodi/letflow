# ISS-0231 — Requirement-registration drift detection

**Issue:** ISS-0231 (WF-03, run `WF03-ISS0231-20260822`)
**Owner of implementation:** `ELIXIR-DEV`
**Author:** `CODE-DESIGNER`
**Status:** design, pending CODE-DESIGN-VALIDATOR

---

## 1. What is being fixed (inherited from Step 1, not re-derived)

ISS-0221's `resolution_note` claimed that "every requirement in the current
`docs/requirements.yaml` (checked via a full-file scan, not a sample) already carries
`impl_order`". That claim was false when written and is still false.

Live measurement in this worktree (`docs/requirements.yaml`, 2026-08-22):

| measurement | command | value |
|---|---|---|
| requirement entries | `grep -cE "^  - id: REQ-" docs/requirements.yaml` | **111** |
| registered (field form) | `grep -cE "^\s+impl_order: [0-9]" docs/requirements.yaml` | **90** |
| deferred (comment form) | `grep -c "# impl_order: UNREGISTERED" docs/requirements.yaml` | **21** |
| 90 + 21 | | **111** — total |

The 21 are exactly REQ-115..REQ-135 (REQ-115..123 = S8, REQ-124..127 = S9,
REQ-128..135 = S4).

**Root cause of the false all-clear.** `docs/agents/protocols/TASK_QUEUE.md` permits two
surface forms for an unregistered requirement — "leave `impl_order` absent (or note
`# UNREGISTERED`)". The verifying scan matched only the registered *field* form
(`impl_order:`), and the comment form `# impl_order: UNREGISTERED` contains that same
substring. The 21 deferrals were therefore counted as hits and the scan concluded zero
unregistered. Nothing in the pipeline re-checks the conclusion, so a false all-clear
about queue registration is unfalsifiable by any automated gate; the only symptom of the
underlying condition is an idle pipeline.

**What the fix is NOT.** All 21 deferrals are deliberate. `docs/requirements.yaml` carries
an inline block note above REQ-115 (line ~5552) explaining that registering S8/S9 now
would make them claimable by a sibling host ahead of the stages they depend on, and
matching notes at ~5900 (S9) and ~6081 (S4 / REQ-128..135). **Registering them is out of
scope for this run.** Driving the deferred count to zero is not the goal and must not be
attempted; per `TASK_QUEUE.md`, "an unregistered requirement carries no `impl_order` at
all — never a guessed one", and `register_task` is the only source of the value.

**What the fix IS.** A mechanism that makes requirement-registration state *classified,
total, and printed on every gate run*, so the next occurrence surfaces on its own instead
of waiting for someone to notice an idle pipeline.

---

## 2. Design decisions

### D1 — Placement: a Mix task wired into the `letflow.check` alias

**Decision.** Ship `mix letflow.check_requirements_registration`
(`lib/mix/tasks/letflow.check_requirements_registration.ex`,
`Mix.Tasks.Letflow.CheckRequirementsRegistration`) **and add it to `mix.exs`'s
`letflow.check` alias**, inserted immediately after `letflow.check_toolchain`:

```
"letflow.check": [
  "letflow.check_toolchain",
  "letflow.check_requirements_registration",   # <- new, inserted here
  "format --check-formatted",
  "compile --warnings-as-errors",
  "letflow.check.test"
]
```

**Why a Mix task.** Direct precedent: `lib/mix/tasks/letflow.check_toolchain.ex`,
`lib/mix/tasks/letflow.check.test.ex`, `lib/mix/tasks/letflow.lint_handoffs.ex`. The
project's shell-script precedent (`scripts/timed_test.sh`) exists for a reason that does
not apply here (measuring a genuinely cold `mix compile`); this check has no such
constraint.

**Why in the alias — the load-bearing half of this decision.** The brief's steer, "a
check nobody runs is not a check", has a live example inside this repository:
`mix letflow.lint_handoffs` is a fully-built gate that **is not wired into `letflow.check`
or into any workflow step** — `HANDOFF_PROTOCOL.md`'s Enforcement note says only that
"every validator role and ORCH *may* now run this task as part of its own gate". A check
whose invocation is permissive prose is exactly as unfalsifiable as the scan that caused
ISS-0231. `letflow.check` is the one command this project treats as *the* gate
(`GIT_MERGE.md`, `docs/guides/backend_developer_guide.md`, decision record 0005), so that
is where the new check goes.

**Why at position 2 and not elsewhere.**

- Not position 1: `letflow.check_toolchain` is deliberately first (decision record 0005 —
  it warns about a drifted toolchain before anything measures anything).
- Not last: `letflow.check.test` runs the whole suite and needs a database. A cheap,
  pure-file check placed after it would only be seen minutes later, and would be skipped
  entirely on any host where the DB is unavailable.
- Position 2 costs nothing: the alias already forces a project compile at step 1 (Mix must
  load `letflow.check_toolchain` from `lib/mix/tasks/`), so no new compile is introduced,
  and the check itself is one read of a ~6.4k-line file with no dependencies, no network,
  and no database.

**Explicitly NOT designed here:** wiring `letflow.lint_handoffs` into the alias too. That
is a real and adjacent gap, but it is a different issue's scope — see OQ-3.

### D2 — Four states, and a partition that must be total

Every entry in the requirements section is classified into **exactly one** of four states.
The first three are the brief's required minimum; the fourth is what makes the mechanism
immune to the failure that caused ISS-0231.

| state | recognised by | today's count |
|---|---|---|
| `:registered` | exactly one attributed line matching the **field form** `impl_order: <integer>` | **90** |
| `:deferred` | exactly one attributed line matching the **marker form** `# impl_order: UNREGISTERED <rationale>` | **21** |
| `:neither` | **no** attributed line containing the token `impl_order` at all | **0** |
| `:unclassified` | an attributed `impl_order` line matching neither recognised shape, or **more than one** attributed `impl_order` line, or an entry whose `id` is not a well-formed `REQ-NNN` | **0** |

`:neither` is the genuinely invisible case: `TASK_QUEUE.md` explicitly permits "absent",
so a requirement with no `impl_order` line of any form is legal today and produces no
signal anywhere. **Today that bucket is empty (measured, 0 of 111) and the mechanism's job
is to keep it that way.**

`:unclassified` is the anti-ISS-0231 bucket. See §3.

### D3 — Hard-fail vs. always-printed report

**Hard-fail (non-zero exit, `Mix.raise/1`):** `:neither`, `:unclassified`, duplicate
requirement ids, a failed totality assertion, or an unreadable / wrongly-shaped
`docs/requirements.yaml`.

**Always printed, never affects the exit code:** the full `:deferred` roster — every
deferred requirement id, grouped by `stage`, with its rationale text and the group counts
— plus the `:registered` count and the totality line.

**Justification.** The brief's own warning is the deciding argument, and it is the same
failure class as "a check nobody runs": *a gate that is permanently red for a known,
documented, intended state gets ignored.* The 21 deferrals are intended, are explained in
three inline block notes in the file itself, and will remain intended for as long as S8/S9
are not the active stage. Failing on them would produce a `letflow.check` that is red on
every run for weeks — and a red-by-default gate teaches everyone to run it with the
failure pre-excused, which destroys its ability to signal anything new.

So the split follows *documentedness*, not *registration state*:

- A deferral that is **documented** (marker present, rationale present) is **visible
  debt**: printed loudly, every run, and counted — but green.
- A requirement that is silently unregistered (`:neither`) has **no rationale recorded
  anywhere** and is indistinguishable from an oversight. That is precisely the condition
  ISS-0221 was filed about, and it is invisible today. **Hard-fail.**
- A surface form the classifier does not recognise (`:unclassified`) is the ISS-0231 root
  cause itself reappearing. **Hard-fail.**

This is also what keeps the gate *informative*: it is green today, so any future red is a
new fact, not background noise.

**No grandfather list.** `letflow.lint_handoffs`'s individually-named, dated grandfather
list exists because its corpus had 30 pre-existing hard violations on day one. This check
has **zero** — measured: `:neither` = 0, `:unclassified` = 0 across all 111 entries. The
module therefore ships with **no exception list of any kind**, and this design forbids
adding a wildcard or pattern-based one later. If a genuine exception is ever needed it is
one exact `REQ-NNN` string, dated and traced to an issue, following the `lint_handoffs`
convention.

### D4 — The deferral marker becomes mandatory (companion doc edit)

Hard-failing on `:neither` gates on a rule that `TASK_QUEUE.md` does not currently state:
today it says "leave `impl_order` absent (**or** note `# UNREGISTERED`)", making bare
absence legal. The fix run must therefore also tighten that one sentence so that a
**deliberate** deferral **must** carry the marker with a rationale, and bare absence is the
error condition the new check reports.

This is a wording change only. It registers nothing, invents no `impl_order` value, and
does not touch the "never a guessed one" rule — that rule is what this design is built
around. See OQ-1 for the scope question.

---

## 3. How the mechanism avoids being fooled the same way

The original scan failed because it matched **one** of two legal surface forms and let the
other be absorbed into that bucket. Four structural properties prevent a repeat.

**(a) Classification is per-entry and single-valued, not per-line-count.** The scan does
not count matching lines across the file. It partitions the file into entries first, then
assigns each entry exactly one state. A grep-style count can silently double-attribute or
mis-attribute; a per-entry assignment cannot, because each entry contributes exactly 1 to
exactly one bucket by construction.

**(b) The fallback bucket is a failure, not a bucket.** The classifier's final clause is
`:unclassified`, and `:unclassified` hard-fails. There is no "everything else is
registered" or "everything else is fine" branch anywhere in the design. **A surface form
the classifier fails to recognise therefore appears as a named, failing entry rather than
being silently absorbed.** This is the direct structural answer to the root cause: had this
existed, the comment form would have shown up as an unclassified entry the first time
anyone looked, instead of inflating the registered count.

**(c) Totality is asserted against an independently-derived denominator.** The scan
computes the entry count from the `- id:` lines in the requirements section, and separately
asserts

```
registered + deferred + neither + unclassified == entry_count
```

The denominator comes from a different pattern than any of the four classifiers, so a
classifier that over- or under-matches breaks the equality rather than being absorbed by
it. A broken equality is itself a hard failure. (`docs/anti-patterns.md`, "Re-deriving the
count while inheriting the unit being counted" — the denominator and the buckets must not
share their matching rule.)

**(d) The `impl_order` token is the trigger; the shape is only the discriminator.**
Attribution of a line to an entry is decided by *position and indentation*; whether that
line concerns registration is decided by the presence of the bare token `impl_order`; and
only then is the shape matched. An entry with an `impl_order`-bearing line whose shape is
novel lands in `:unclassified` — it cannot be dropped merely because no known regex
matched it.

---

## 4. Parsing model

`docs/requirements.yaml` is ~6.4k lines and **cannot be parsed as YAML**: this project has
no YAML dependency (`mix.exs` deps: `ecto_sql`, `postgrex`, `plug`, `bandit`, `jason`,
`stream_data`, `ueberauth_oidcc`). Adding one is out of scope for a bug fix and would be a
library choice requiring REVIEWER sign-off per CLAUDE.md. The scan is therefore
**line-oriented**, and the design compensates with the totality assertion in §3(c) rather
than with parser sophistication.

### 4.1 Sectioning

The file has exactly two top-level keys, both at column 0: `stages:` (line 39) and
`requirements:` (line 162).

- Only lines **after** the `requirements:` line are scanned. This is why the 10
  `  - id: S0..S9` stage entries (which have no `impl_order` and would otherwise be 10
  spurious `:neither` hard failures) are out of scope by construction, rather than by an
  exception list.
- If the `requirements:` key is not found, that is a hard failure — the file's shape
  changed underneath the check, and that must never be a silent zero-entry pass. **A scan
  that finds zero entries is likewise always a hard failure.**

### 4.2 Entry boundaries

Within the requirements section, an entry starts at a line matching `^  - id: ` (two-space
indent, sequence item). It ends at the line before the next such line, or at EOF.

Measured: 121 such lines in the whole file, 10 of them in `stages:`, **111** in
`requirements:` — matching the 111 `^  - id: REQ-` lines exactly. So today every entry in
the requirements section is a `REQ-` entry.

An entry whose id does not match `REQ-\d+` is `:unclassified` (**not** skipped). A
requirement whose id line were malformed would otherwise be invisible to the scan entirely
— the same blindness class as the original bug, one level up.

### 4.3 Line attribution — the indentation rule

A line belongs to entry *E* iff it lies within *E*'s boundaries **and** its indentation is
**≥ 4 spaces** (the field level for this file: `    impl_order: 4`,
`    # impl_order: UNREGISTERED ...`).

This matters, and it is measured. `docs/requirements.yaml` contains 115 lines mentioning
`impl_order`: 90 field forms, 21 markers, and **4 prose block-note lines** (5552, 5554,
5900, 6081) that sit at **2-space** indent between entries and describe the convention
rather than stating any one entry's state:

```
  # NOTE ON impl_order: none of REQ-115..127 carry one. Per
  # carries no impl_order at all -- never a guessed one"), they are
  # The impl_order note in the S8 block above applies here too.
  # See the S8 note above for the impl_order convention -- REQ-128..135
```

Under the ≥4-space rule these four are attributed to no entry and are correctly ignored.
Without it, three requirements would gain a second attributed `impl_order` line and be
misclassified as `:unclassified`. Mutant **M6** exists to prove the suite is sensitive to
exactly this.

### 4.4 Recognised shapes

Anchored, whole-line, applied only to attributed lines:

| shape | pattern (anchored to the whole line) | today |
|---|---|---|
| field form | `^\s+impl_order:\s+(\d+)\s*(#.*)?$` | 90 (all carry a trailing comment) |
| marker form | `^\s+#\s*impl_order:\s*UNREGISTERED\b\s*(\S.*)?$` | 21 (all byte-identical: `    # impl_order: UNREGISTERED -- see the S8 note above`) |

Anchoring is required, not stylistic. An unanchored marker pattern would match
`impl_order: 5  # was UNREGISTERED until Tuesday`, i.e. would reproduce the absorption bug
with the buckets reversed. Mutant **M8** targets this.

A field form whose value is not a bare non-negative integer (`impl_order: TBD`,
`impl_order: 4a`, `impl_order:` with nothing after it) matches neither shape and is
therefore `:unclassified` — never coerced, never defaulted.

---

## 5. Rules and exit contract

### Hard rules (any violation → non-zero exit)

- **R1 — no silent absence.** No entry is `:neither`. *(A requirement with no `impl_order`
  line of any form. Today: 0.)*
- **R2 — no unrecognised form.** No entry is `:unclassified`. *(Novel shape, duplicate
  attributed lines, or a malformed id. Today: 0.)*
- **R3 — a deferral carries a rationale.** Every marker-form line has non-empty text after
  `UNREGISTERED`. *(Today all 21 carry `-- see the S8 note above`. An unexplained marker is
  a deferral nobody can audit, which is exactly the documented/undocumented boundary D3
  draws.)*
- **R4 — ids are unique.** No `REQ-NNN` appears as the id of two entries. *(A duplicate
  makes the partition ambiguous and would corrupt R5's accounting.)*
- **R5 — the partition is total.** `registered + deferred + neither + unclassified ==
  entry_count`, with `entry_count` derived independently per §3(c), and `entry_count > 0`.
- **R6 — the file is present and shaped as expected.** `docs/requirements.yaml` is readable
  and contains a top-level `requirements:` key.

### Always printed, never gating

- The `:registered` count.
- **The `:deferred` roster in full**: every id, its `stage`, its rationale text, grouped by
  stage, with group counts and total. This is the visible-debt report — printed on a green
  run, unconditionally. It is the thing that would have made ISS-0221's false claim
  self-refuting.
- The totality line, e.g.
  `111 entries = 90 registered + 21 deferred + 0 neither + 0 unclassified`.

### Exit contract

- Exit `0` iff R1–R6 all hold. The deferred count never influences this, whatever its
  value.
- `Mix.raise/1` otherwise, naming **every** violating entry by exact `REQ-NNN` and rule id
  (never "N violations found" alone — the actionable unit is the id).

---

## 6. Module and function shapes

No implementation code appears in this document. Signatures and type shapes only.

### 6.1 Where the logic lives

Following `letflow.lint_handoffs`'s precedent, both the pure classifier and the CLI wrapper
live in the **one Mix task module** — no new `Letflow.*` application namespace is invented
for pipeline meta-tooling, which is not domain code.

**One deliberate deviation from that precedent:** in `lint_handoffs` every helper is
`defp`, which makes the logic reachable only by running the whole task against the real
corpus. This design makes the pure core **public**, so ExUnit can call it on hermetic
fixture strings. That is a hard requirement of §7: the mutant that reproduces the original
bug (**M1**) is *invisible* to any test that only runs against the live corpus (§7.2), so
fixture-level access to the classifier is not a convenience — it is the only thing that
catches the bug this fix exists to prevent.

`scan/1` takes **file content**, not a path, for the same reason: fixtures are strings.

### 6.2 Types

```
@type state :: :registered | :deferred | :neither | :unclassified

@type entry :: %{
        id: String.t(),                        # "REQ-115", or the raw id text if malformed
        line: pos_integer(),                   # 1-based line of the `- id:` line
        stage: String.t() | nil,               # from the entry's own `stage:` field, nil if absent
        state: state(),
        impl_order: non_neg_integer() | nil,   # set iff state == :registered
        rationale: String.t() | nil,           # set iff state == :deferred
        detail: String.t() | nil               # why :unclassified; nil otherwise
      }

@type report :: %{
        entries: [entry()],
        entry_count: non_neg_integer(),        # independently derived, per §3(c)
        counts: %{registered: non_neg_integer(), deferred: non_neg_integer(),
                  neither: non_neg_integer(), unclassified: non_neg_integer()},
        violations: [violation()]
      }

@type violation :: %{
        rule: String.t(),                      # "R1".."R6"
        id: String.t() | nil,                  # REQ-NNN, or nil for file-level rules R5/R6
        line: pos_integer() | nil,
        message: String.t()
      }
```

### 6.3 Public functions

```
@spec scan(content :: String.t()) :: report()
```

Pure. Sections the content (§4.1), splits it into entries (§4.2), classifies each (§4.4),
derives `entry_count` independently, and collects R1–R6 violations. Never raises on
content; a malformed file is expressed as violations in the report. Raises only on a
non-binary argument.

```
@spec classify_entry(entry_lines :: [{pos_integer(), String.t()}]) :: entry()
```

Pure, single-entry. This is the unit the fixture tests and every mutant target. Returns
exactly one `state` per call — totality is structural here, and R5 is the cheap independent
guard on top of it.

```
@spec render(report()) :: iodata()
```

Pure. Produces the always-printed report of §5, including the full deferred roster. Split
out so a test can assert on the roster text without capturing task IO.

```
@spec run(args :: [String.t()]) :: :ok      # @impl Mix.Task
```

Reads `docs/requirements.yaml` (path in a module attribute), calls `scan/1`, writes
`render/1` to stdout, then `Mix.raise/1` iff `report.violations != []`. Accepts and ignores
Mix's arg list, matching `letflow.check.test`'s shape.

### 6.4 Files touched

| file | change |
|---|---|
| `lib/mix/tasks/letflow.check_requirements_registration.ex` | **new** — the module above |
| `mix.exs` | `letflow.check` alias gains one entry at position 2 (D1) |
| `docs/agents/protocols/TASK_QUEUE.md` | the one sentence tightened per D4 |
| `test/mix/tasks/letflow_check_requirements_registration_test.exs` | **new** — §7, written by TEST-DESIGNER at Step 4, not by ELIXIR-DEV |

**Nothing else.** In particular: no edit to `docs/requirements.yaml`'s data, no `impl_order`
value added, removed, or altered anywhere, and no call to `letflow-queue`.

### 6.5 Moduledoc hazard (must be handled at implementation time)

`docs/anti-patterns.md`, "A grep-shaped acceptance criterion can be tripped by the module's
own moduledoc describing the invariant": this module's moduledoc will naturally want to
quote both surface forms it recognises, so the new `.ex` file will itself contain the
literal strings `impl_order:` and `# impl_order: UNREGISTERED`. Consequences to respect:

- The check scans `docs/requirements.yaml` **only** — never `lib/` — so the module cannot
  fail its own check. Keep it that way; do not generalise the scan to a directory.
- Any acceptance criterion for this fix phrased as a repo-wide `grep` for either form will
  hit the new module and its test file. Phrase such criteria as scoped to
  `docs/requirements.yaml`, or expect and account for the extra hits.

---

## 7. Regression-test story (WF-03 Step 4)

### 7.1 Why mutants are mandatory here

This fix **adds** a module. The pre-fix failure is therefore `UndefinedFunctionError` for
every test in the file, which proves only that the module is new. WF-03's clause "When the
pre-fix failure is 'the code under test does not exist'" applies in full: the fail-first
requirement is satisfied **only** by additionally mutating the shipped logic and recording
which tests fail per mutant, and TEST-DESIGN-VALIDATOR must independently apply at least
one mutant and run it.

Isolation technique to copy from `WF03-ISS0106-20260821`: run the pre-fix side as `main`
plus **only the new module**. Apply mutants in a throwaway `git worktree`; if applied in
place, revert with `git checkout --` and verify (`git status --porcelain lib/ test/` empty
**and** the test file re-runs green) before completing the handoff. A mutant left in the
tree is a step failure.

### 7.2 The corpus test cannot catch the main mutant — this is load-bearing

There must be a live-corpus test (§7.4, the `T-*` group), but TEST-DESIGNER must not rely
on it for discrimination. **Under M1 — the mutant that reproduces the original ISS-0231 bug
— the live corpus classifies as 111 registered / 0 deferred / 0 neither / 0 unclassified.
R1, R2 and R5 all still hold, and a corpus test asserting only those still passes.** That
is the whole point of the bug: the false all-clear looked exactly like a true one.

Discrimination therefore has to come from **hermetic fixtures**: short
requirements.yaml-shaped strings embedded in the test file and passed to `scan/1` /
`classify_entry/1`, each pinning a specific expected state. A suite that only asserts
against `docs/requirements.yaml` is vacuous against M1 and must be rejected by
TEST-DESIGN-VALIDATOR.

### 7.3 Named mutants

Each names the trap it targets and the tests that must fail under it. A mutant that no test
detects is a coverage hole to be closed before Step 4 passes.

| # | mutant | what it reproduces | must be caught by |
|---|---|---|---|
| **M1** | **Field-form-only classifier**: drop the marker-form clause and classify any attributed line containing `impl_order` as `:registered`. | **The ISS-0231 bug verbatim** — one of two legal forms recognised, the other absorbed into it. | F-DEFERRED-BASIC, F-BOTH-FORMS, T-ROSTER. Corpus totality tests **must not** be cited here (§7.2). |
| **M2** | **Silent-absorption fallback**: change the classifier's final clause from `:unclassified` to `:registered` (variant **M2b**: to `:deferred`). | The structural cause — a fallback that is a bucket rather than a failure. | F-NOVEL-FORM, F-NONINT-VALUE |
| **M3** | **Totality assertion removed**: delete R5, or weaken its `==` to `<=`. | The independent-denominator guard of §3(c). | F-TOTALITY, T-TOTALITY-LIVE |
| **M4** | **`:neither` demoted to advisory**: remove R1 from the violation set while keeping it in the printed report. | The invisible case — the exact condition ISS-0221 described, which nothing detects today. | F-NEITHER-EXIT |
| **M5** | **`:deferred` promoted to hard-fail**: add R1-style gating on `:deferred`. | The opposite polarity error — the permanently-red gate D3 rejects. | T-LIVE-GREEN (the real `docs/requirements.yaml`, with 21 deferrals, must exit 0) |
| **M6** | **Indentation blindness**: attribute every `impl_order` line to the nearest preceding entry regardless of indent (drop the ≥4-space rule of §4.3). | The 4 two-space block-note lines being swept into entries. | F-BLOCK-NOTE, T-LIVE-GREEN (three S8/S9/S4 entries flip to `:unclassified`, so R2 fails) |
| **M7** | **Rationale check removed**: accept a bare `# impl_order: UNREGISTERED` (drop R3). | An undocumented deferral passing as a documented one — erases D3's own boundary. | F-BARE-MARKER |
| **M8** | **Marker pattern unanchored**: match `UNREGISTERED` anywhere in an attributed line rather than as a whole-line shape. | Absorption with the buckets reversed: `impl_order: 5  # was UNREGISTERED` read as deferred. | F-ANCHOR |
| **M9** | **Section guard removed**: scan the whole file instead of only the part after `requirements:`. | §4.1 — the 10 `stages:` entries becoming spurious `:neither` failures, i.e. a check red on day one for a non-reason. | T-LIVE-GREEN, F-STAGES-SECTION |
| **M10** | **Malformed-id skip**: replace `:unclassified`-for-a-bad-id with silently skipping the entry. | §4.2 — an entry invisible to the scan entirely; the original blindness one level up. | F-BAD-ID, F-TOTALITY |

**M1 is the mandatory one**: per the brief, a mutant whose classifier matches only the
`impl_order:` field form must be caught by the suite. It is also the natural candidate for
TEST-DESIGN-VALIDATOR's independent re-application.

### 7.4 Test inventory (specs, for TEST-DESIGNER to build from)

**Fixture tests** — hermetic strings through `scan/1` / `classify_entry/1`, no file IO:

- **F-REGISTERED-BASIC** — `impl_order: 42  # letflow-queue task id` → `:registered`,
  `impl_order == 42`.
- **F-DEFERRED-BASIC** — `# impl_order: UNREGISTERED -- see the S8 note above` →
  `:deferred`, rationale non-empty, `impl_order == nil`. *Explicitly asserts it is NOT
  `:registered`* — this is the assertion M1 breaks.
- **F-NEITHER** — an entry with no `impl_order` line → `:neither`.
- **F-NEITHER-EXIT** — a report containing a `:neither` entry carries an R1 violation
  (exit-code-bearing), not merely a printed line.
- **F-NOVEL-FORM** — `impl_order_hint: 7` / `impl-order: 7` → `:unclassified`, never
  absorbed into another bucket.
- **F-NONINT-VALUE** — `impl_order: TBD`, `impl_order: 4a`, `impl_order:` (empty) →
  `:unclassified`, never coerced to a number.
- **F-BOTH-FORMS** — an entry carrying *both* the field form and the marker →
  `:unclassified` (ambiguous), not silently resolved either way.
- **F-BARE-MARKER** — `# impl_order: UNREGISTERED` with no trailing text → R3 violation.
- **F-ANCHOR** — `impl_order: 5  # was UNREGISTERED until Tuesday` → `:registered` with
  `impl_order == 5`, **not** `:deferred`.
- **F-BLOCK-NOTE** — a fixture reproducing the real file's shape: a 2-space
  `  # NOTE ON impl_order: ...` line sitting between two entries, both of which must still
  classify as `:deferred` with exactly one attributed line each.
- **F-BAD-ID** — `  - id: REQ_115` / `  - id: 115` → `:unclassified`, and still counted in
  `entry_count`.
- **F-STAGES-SECTION** — a fixture containing both `stages:` and `requirements:`; the stage
  entries contribute nothing to any bucket, and `entry_count` counts only the requirements.
- **F-TOTALITY** — for every fixture above, `sum(counts) == entry_count ==
  length(entries)`.
- **F-NO-REQUIREMENTS-KEY** — content with no `requirements:` key → R6 violation, and
  **not** a silent zero-entry green pass.
- **F-EMPTY-SECTION** — `requirements:` present but zero entries → R5 violation
  (`entry_count > 0`).

**Live-corpus tests** — against the real `docs/requirements.yaml`, deliberately *not*
pinned to today's 90/21 numbers, since those change legitimately when S8/S9/S4 are
registered later:

- **T-LIVE-GREEN** — the real file produces zero violations (exit 0) *while its deferred
  count is greater than zero*. This is the D3 assertion: documented debt is green.
- **T-TOTALITY-LIVE** — `registered + deferred + neither + unclassified == entry_count` on
  the real file, with `entry_count > 100`.
- **T-LIVE-INVARIANTS** — `counts.neither == 0` and `counts.unclassified == 0` on the real
  file. These are the two properties the mechanism exists to keep true.
- **T-ROSTER** — `render/1`'s output on the real file names at least one specific
  currently-deferred id (e.g. `REQ-115`) and prints a non-zero deferred count. Fails under
  M1. *(See OQ-5 on this test's future staleness.)*

**Task-level tests:**

- **T-TASK-RAISES** — `run/1` against a fixture path whose content has an R1 violation
  raises `Mix.Error`.
- **T-TASK-PRINTS-ON-GREEN** — the deferred roster is printed even when the run is green,
  i.e. the report is unconditional.

---

## 8. Invariants

- **I1.** The classification of the entries is a **partition**: every entry lands in
  exactly one of four states, and the four counts sum to an independently-derived
  `entry_count`.
- **I2.** The check **never writes** to `docs/requirements.yaml`, never assigns or suggests
  an `impl_order` value, and makes no network call — in particular none to `letflow-queue`.
  It is a read-only classifier.
- **I3.** The deferred count **never** influences the exit code, at any value.
- **I4.** The gate is green on `main` at the moment this lands (measured: `:neither` = 0,
  `:unclassified` = 0), so any future red is a new fact.
- **I5.** No wildcard, prefix, or pattern-based suppression exists in the module. It ships
  with no exception list at all.
- **I6.** The classifier's fallback clause is `:unclassified`, and `:unclassified`
  hard-fails — there is no branch anywhere that treats an unrecognised shape as acceptable.

---

## 9. Open questions

Listed rather than guessed, per CODE-DESIGNER's own constraints. None blocks Step 3; each
needs a stated decision rather than a silent one.

- **OQ-1 (scope; needs ORCH/REVIEWER).** Is the D4 companion edit to
  `docs/agents/protocols/TASK_QUEUE.md` — tightening "absent (or note `# UNREGISTERED`)" so
  the marker becomes mandatory — in scope for ISS-0231's fix run, or a separate doc issue?
  **CODE-DESIGNER's recommendation: in scope.** Without it, R1 hard-fails on a condition the
  protocol still explicitly permits, which is a gate enforcing an undocumented rule. It is
  one sentence and it registers nothing.
- **OQ-2 (placement detail).** Position 2 in the `letflow.check` alias (after
  `letflow.check_toolchain`, before `format --check-formatted`) is recommended and justified
  in D1, but alias ordering is decision-record territory (0005). If REVIEWER prefers
  position 1, or a position after `compile`, say so at the Step 3 gate; the design is
  indifferent to the exact index, only to *being in the alias at all*.
- **OQ-3 (adjacent gap, deliberately not fixed here).** `mix letflow.lint_handoffs` is built
  but wired into nothing — `HANDOFF_PROTOCOL.md` only says agents *may* run it. That is the
  same "a check nobody runs" failure this design argues against, on a different check.
  **Not fixed in this run** (outside ISS-0231's scope, and it would change what a green
  `letflow.check` means for every other in-flight branch). It should be filed as its own
  issue via `register_task`.
- **OQ-4 (marker tolerance).** The 21 existing markers are byte-identical
  (`    # impl_order: UNREGISTERED -- see the S8 note above`). This design accepts any
  non-empty trailing text after `UNREGISTERED` as the rationale (§4.4 / R3). Should it be
  stricter — e.g. require the rationale to reference a stage note or an issue id? Looser is
  recommended for now (stricter risks a red gate over a formatting nit, which is D3's own
  argument), but it is a judgement call worth confirming.
- **OQ-5 (future staleness of T-ROSTER).** T-ROSTER pins one currently-deferred id
  (`REQ-115`). When S8 is registered, that test must be updated to another deferred id, or
  dropped if the deferred set ever legitimately empties. TEST-DESIGNER should write that
  note into the test file itself so a future failure reads as "expected update", not
  "regression". If TEST-DESIGN-VALIDATOR prefers no pinned id at all, the alternative is
  asserting only that the roster is non-empty and that every printed id appears in the
  `:deferred` bucket — weaker against M1, which is why the pinned version is proposed.

---

## 10. Traceability

| ISS-0231 concern (from the Step 1 diagnosis / dispatch brief) | where it is answered |
|---|---|
| A detection mechanism for registration drift | §2 D1, §6 |
| Placement — a check nobody runs is not a check | §2 D1 (in the `letflow.check` alias; `lint_handoffs` cited as the live counter-example) |
| Classify, not just count; ≥3 states including the invisible NEITHER | §2 D2, §5 |
| NEITHER is empty today, and the mechanism keeps it true | §2 D2 (measured 0 of 111), I4, T-LIVE-INVARIANTS |
| Hard-fail vs. warn, decided and justified in the doc | §2 D3 |
| Nothing that registers, guesses `impl_order`, or calls letflow-queue | I2, §6.4 ("Nothing else") |
| Robust to a scan matching only one legal surface form | §3 (a)–(d); mutants M1, M2, M8 |
| Regression-test story with named mutants, per WF-03's non-existence clause | §7, and §7.2's warning that the corpus test cannot catch M1 |
