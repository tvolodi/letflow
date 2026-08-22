# WF03-ISS0258-20260822 — Step 3 — ELIXIR-DEV

**Verdict:** IMPLEMENTED. **Divergence from the design: none.**
**next_action:** Route to SECURITY-REVIEWER (scope test already recorded OUT_OF_SCOPE at
`step-03b-security-scope-test.md`), then REVIEWER. I do not mark my own handoff PASS.

**Design implemented verbatim:** `lib/letflow/design/iss0258-deferral-staleness-detection.md`
(as corrected at the Step-2b gate; rules **S1–S6**, S6 added by that gate).

---

## 1. What was built

### `lib/mix/tasks/letflow.check_deferral_staleness.ex` — NEW

`Mix.Tasks.Letflow.CheckDeferralStaleness`. One module holding the pure audit core and the
CLI wrapper, following the `letflow.lint_handoffs` / `check_requirements_registration`
precedent (no new `Letflow.*` namespace invented for pipeline meta-tooling).

Public surface, exactly the shapes §6.2 specifies:

| function | note |
|---|---|
| `audit(content :: String.t()) :: audit()` | **content-in, not path-in** (D1). The whole point: the live corpus has 0 deferrals, so hermetic fixtures are the entire regression value. Deliberately not named `scan/1`. |
| `stage_activity([map()]) :: [stage_facts()]` | The §3.3 ruling isolated, so MS1/MS2/MS3 have a single target. |
| `classify_deferral(map(), [stage_facts()], statuses) :: deferral()` | Single-entry and total; `reason` populated in **every** branch including `:legitimate`. |
| `parse_scope(String.t() \| nil) :: scope()` | The §D6 grammar, anchored. |
| `normalise_status(String.t() \| nil) :: status()` | Total; non-member branch is `:unknown`. |
| `render(audit()) :: iodata()` | Pure, so tests assert on the roster without capturing task IO. |
| `run([String.t()]) :: :ok` | `@impl Mix.Task`; reads the file, prints `render/1`, `Mix.raise/1` iff violations. |

House style matched to the precedent module: module attributes for every regex, `@spec` on
every function (private ones included), `@rule`/`@thin_rule` banners, the same
`format_violation/1` shape (`[S1] REQ-118 (line 5602): ...`), and a substantial moduledoc
stating the rules, the derivation and the reasoning.

**Type shapes are byte-for-byte the design's §6.1** — `status`, `activity`, `scope`,
`verdict`, `deferral`, `stage_facts`, `violation`, `audit`. Nothing added to them. The
report's entry count is derived as `map_size(result.statuses)` rather than by widening the
`audit()` type.

Rule placement, as the gate directed:

- **S6 lives in `audit/1`**, not in `classify_deferral/3` — `cycle_violations/1` runs over
  the full deferral list after every entry is classified, exactly as
  `duplicate_id_violations/1` sits outside `classify_entry/1` in the precedent module.
  Cycle detection is a DFS per hatch-bearing deferral, canonicalised by min-rotation and
  de-duplicated so an n-cycle yields one violation naming every id in order. Length-1
  (self-reference) is **rejected** here and left to S3, which is where the gate put it.
- **Self-exclusion** is `active_witnesses/2`: `facts.witnesses -- [id]`. The entry under
  test is removed from **its own** computation only, so two deferred siblings still see
  each other.
- **`:unknown` hard-fails** (S4) across all 115 entries, not just deferred ones (OQ-2). The
  known set is a module attribute map; the fallthrough is `Map.get(..., :unknown)`. There
  is no branch anywhere that treats an unrecognised status as acceptable.

### `lib/mix/tasks/letflow.check_requirements_registration.ex` — additive only

The single bounded change of D4, **+17 lines, 0 deletions**:

- `@status_re ~r/^\s+status:\s*(\S+)/` — a direct copy of `@stage_re`'s shape, with a
  comment stating why (first token only; the 8 trailing-comment lines) and that the token
  is stored **raw and uninterpreted**.
- `status: String.t() | nil` added to `@type entry`.
- `status: extract_status(attributed)` added to `classify_entry/1`'s `base` map.
- `extract_status/1`, a private mirror of `extract_stage/1`.

Verified touched: **none** of the `:deferred` code path, `@marker_form_re`, R1–R6, rule
ordering, `render/1`'s "never gates" line, or the exit contract. The diff is reproduced in
§3 below so the Step-3 gate can check the boundedness claim directly rather than trust it.

### `mix.exs` — slot 3 (D5)

```
"letflow.check": [
  "letflow.check_toolchain",
  "letflow.check_requirements_registration",
  "letflow.check_deferral_staleness",     # <- added
  "format --check-formatted",
  "compile --warnings-as-errors",
  "letflow.check.test"
]
```

### `docs/agents/protocols/TASK_QUEUE.md` — companion doc edit (D7)

+27 lines immediately after the existing deferral-convention paragraph (the one ending
"...which is the condition ISS-0221 was filed about"), stating (a) that a deferral goes
stale once its stage becomes active, (b) the derivation in one sentence, (c) the
`blocked-by: REQ-NNN` grammar with all five properties. Without it, S1 would hard-fail on
a condition the protocol never stated — a gate enforcing an undocumented rule. Registers
nothing; changes no `impl_order`.

### `docs/requirements.yaml` — line 8 comment ONLY (OQ-3)

```diff
-# Status values: pending | in_progress | done | blocked
+# Status values: pending | in_progress | done | blocked | cancelled
```

`git diff --stat` = `2 +-` (1 insertion, 1 deletion) = **one line**. No `status:` value, no
`impl_order`, no entry data touched.

### The §6.5 moduledoc hazard — handled

The new moduledoc contains both `# impl_order: UNREGISTERED` and `blocked-by: REQ-042`.
The task reads `@requirements_file "docs/requirements.yaml"` and **only** that — no
directory walk, no `lib/` scan. The moduledoc says so explicitly and cites
`docs/anti-patterns.md`. Confirmed empirically: the task is green on the live tree while
its own source contains both forms.

---

## 2. Verifications — real output, all run in this worktree

### V1 — `mix compile --warnings-as-errors`

```
$ mix compile --warnings-as-errors
Compiling 2 files (.ex)
Generated letflow app
```

Clean.

### V2 — `mix format` then `mix format --check-formatted`

```
$ mix format && mix format --check-formatted && echo "FORMAT_OK"
FORMAT_OK
```

### V3 — `mix letflow.check_deferral_staleness` on the live tree — **exit 0**

```
========================================================================
mix letflow.check_deferral_staleness -- docs/requirements.yaml
========================================================================
STAGE ACTIVITY (derived, always reported, never gates):
  S0  ACTIVE  [2 cancelled, 5 done]  active via REQ-010, REQ-011, REQ-012 (+2 more)
  S1  ACTIVE  [2 cancelled, 7 done]  active via REQ-015, REQ-016, REQ-017 (+4 more)
  S2  ACTIVE  [21 done]  active via REQ-022, REQ-023, REQ-024 (+18 more)
  S3  ACTIVE  [1 cancelled, 26 done]  active via REQ-043, REQ-044, REQ-045 (+23 more)
  S4  ACTIVE  [2 cancelled, 14 done, 20 pending]  active via REQ-065, REQ-066, REQ-067 (+11 more)
  S8  INACTIVE  [1 cancelled, 10 pending]
  S9  INACTIVE  [4 pending]
------------------------------------------------------------------------
DEFERRALS (legitimate ones are reported and never gate): none
------------------------------------------------------------------------
0 deferred of 115 entries; 0 stale
========================================================================
EXIT=0
```

**The derived table reproduces the design's §3.4 prediction exactly** — S0–S4 active,
S8/S9 inactive, and the histograms match §1.1's measured cross-tab row for row. That is
independent corroboration of the derivation, not merely a green exit. The green is
vacuous for S1–S3 (0 deferrals), genuinely load-bearing for S4/S5.

### V4 — `mix letflow.check_requirements_registration` unperturbed — **exit 0**

```
========================================================================
mix letflow.check_requirements_registration -- docs/requirements.yaml
========================================================================
DEFERRED (visible debt -- always reported, never gates): none
------------------------------------------------------------------------
115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified
========================================================================
EXIT=0
```

Byte-identical totality line to the pre-change run. D4's addition is provably bounded.

### V5 — `mix letflow.check` (full alias) — slots 1–5 GREEN, slot 6 red on a **pre-existing, documented** failure

Head of the real run (`tmp/letflow_check.log`, exit 1):

```
letflow.check_toolchain: OK -- Elixir 1.20.3 / OTP 29 matches .tool-versions.
========================================================================
mix letflow.check_requirements_registration -- docs/requirements.yaml
========================================================================
DEFERRED (visible debt -- always reported, never gates): none
------------------------------------------------------------------------
115 entries = 115 registered + 0 deferred + 0 neither + 0 unclassified
========================================================================
========================================================================
mix letflow.check_deferral_staleness -- docs/requirements.yaml
========================================================================
STAGE ACTIVITY (derived, always reported, never gates):
  S0  ACTIVE  [2 cancelled, 5 done]  active via REQ-010, REQ-011, REQ-012 (+2 more)
  ... (as V3) ...
  S9  INACTIVE  [4 pending]
------------------------------------------------------------------------
DEFERRALS (legitimate ones are reported and never gate): none
------------------------------------------------------------------------
0 deferred of 115 entries; 0 stale
========================================================================
```

The new task runs in **slot 3**, between registration and `format --check-formatted`,
exactly as D5 rules. Aliases abort on the first failing step, so slots 4
(`format --check-formatted`) and 5 (`compile --warnings-as-errors`) passing is proven by
the suite having started at all.

Tail:

```
Result: 1581 passed (5 properties, 1576 tests)
** (Mix) mix letflow.check.test: FAILED -- "default values for the optional arguments" warning found (ISS-0069's own class recurring):
.    warning: default values for the optional arguments in the private function entry/2 are never used
.    warning: default values for the optional arguments in the private function unique_idempotency_key/1 are never used
```

**1581 tests passed, 0 failures.** The alias's exit 1 comes solely from
`letflow.check.test`'s warning scan, on **two warnings this branch did not cause**:

| emitting file | last commit touching it | date |
|---|---|---|
| `test/letflow/engine_sub_process_test.exs:96` (`unique_idempotency_key/1`) | `ca8c9d0` (#351) | 2026-08-20 |
| `test/letflow/engine/sub_process_test.exs:44` (`entry/2`) | `c6c1e0e` REQ-062 (#258) | 2026-08-19 |
| the detector `lib/mix/tasks/letflow.check.test.ex` | `7f73f30` ISS-0069 (#254) | 2026-08-19 |

All three predate this branch, and `git diff --stat main..HEAD -- test/` shows this branch
touches neither emitting file. It is **already recorded** as a known pre-existing failure,
with the same two locations and the same attribution reasoning, at
`test/reports/report-20260822-WF03-ISS0231-20260822.yaml`, key
`preexisting_failures_not_caused_by_this_branch`, whose routing note reads *"New issue for
ELIXIR-DEV — drop the two unused defaults. Not a blocker on this branch."*

I am **not** fixing it here: it is outside this run's scope, and touching two unrelated
test files to green a gate would be exactly the scope creep REVIEWER gates on. Flagging it
loudly instead, per the no-speculation rule. **`mix letflow.check` cannot be green on any
branch right now**, mine included, until that separate issue lands.

`letflow.check.test` needs the DB and took **430.3 s** (7.6 s async, 422.7 s sync). It ran
to completion synchronously in this turn; nothing was backgrounded.

### V6 — `git diff --stat docs/requirements.yaml` — exactly 1 line

```
$ git diff --stat docs/requirements.yaml
 docs/requirements.yaml | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

$ git diff docs/requirements.yaml
-# Status values: pending | in_progress | done | blocked
+# Status values: pending | in_progress | done | blocked | cancelled
```

### V7 — **the detector actually fires** (the load-bearing verification)

A live corpus with 0 deferrals demonstrates nothing about S1/S2/S3, so I built a
synthetic-fixture probe at `tmp/iss0258_fixture_probe.exs` — **`tmp/` is gitignored
(`.gitignore:26:/tmp/`, verified with `git check-ignore -v`), so nothing entered `lib/` or
the commit** — and ran it with `mix run --no-start`. Left on disk for TEST-DESIGNER at
Step 4; every fixture below maps to a named spec in design §7.4.

Real output, abridged to the verdict/violation lines:

```
--- F-STALE-BASIC ---
  verdicts: [{"REQ-002", :stale, :stage_scoped}]  stale=1
  S1 REQ-002: STALE deferral -- stage-scoped; stage S4 is ACTIVE -- made active by REQ-001 (done). ...

--- F-S8-SHAPE-LEGIT ---
  verdicts: [{"REQ-012", :legitimate, :stage_scoped}]  stale=0
  (no violations)

--- F-STATUS-TRAILING-COMMENT --- :cancelled

--- F-TYPO-DOES-NOT-DEACTIVATE ---
  verdicts: [{"REQ-021", :legitimate, :stage_scoped}]  stale=0
  S4 REQ-020: unrecognised status "donee" -- known values are blocked | cancelled | done | in_progress | pending. ...

--- F-SELF-EXCLUSION ---
  verdicts: [{"REQ-031", :legitimate, :stage_scoped}]  stale=0
  (no violations)

--- F-HATCH-BASIC ---
  verdicts: [{"REQ-043", :legitimate, {:blocked_by, "REQ-042"}}]  stale=0
  (no violations)

--- F-HATCH-BLOCKER-DONE ---
  verdicts: [{"REQ-043", :stale, {:blocked_by, "REQ-042"}}]  stale=1
  S1 REQ-043: STALE deferral -- its `blocked-by: REQ-042` scope has EXPIRED -- REQ-042 is done, ...
  S3 REQ-043: `blocked-by: REQ-042` has EXPIRED -- REQ-042 is done. The hatch is not an exemption; ...

--- F-HATCH-BLOCKER-CANCELLED ---
  verdicts: [{"REQ-043", :stale, {:blocked_by, "REQ-042"}}]  stale=1
  S1 REQ-043: ... EXPIRED -- REQ-042 is cancelled, ...
  S3 REQ-043: ... EXPIRED -- REQ-042 is cancelled. ...

--- F-HATCH-DANGLING ---
  verdicts: [{"REQ-051", :stale, {:blocked_by, "REQ-999"}}]  stale=1
  S1 REQ-051: STALE deferral -- its `blocked-by:` scope is unusable (names REQ-999, which is not present in the corpus); stage S4 is ACTIVE ...
  S3 REQ-051: `blocked-by:` scope does not resolve -- it names REQ-999, which is not present in the corpus. ...

--- F-HATCH-SELF ---
  verdicts: [{"REQ-051", :stale, {:blocked_by, "REQ-051"}}]  stale=1
  S1 REQ-051: ... unusable (names its own id REQ-051, which would be an unfalsifiable self-license); stage S4 is ACTIVE ...
  S3 REQ-051: ... names its own id REQ-051 ...

--- F-HATCH-ANCHOR ---        verdicts: [{"REQ-051", :stale, :stage_scoped}]  stale=1   (S1; hatch NOT activated)
--- F-HATCH-MALFORMED ---     verdicts: [{"REQ-051", :stale, :stage_scoped}]  stale=1   (S1; `REQ_042` never becomes a hatch)
--- F-HATCH-NO-RATIONALE ---  verdicts: [{"REQ-051", :stale, :stage_scoped}]  stale=1   (S1; bare id rejected as a hatch)

--- F-HATCH-CYCLE-2 ---
  verdicts: [{"REQ-061", :legitimate, {:blocked_by, "REQ-062"}}, {"REQ-062", :legitimate, {:blocked_by, "REQ-061"}}]  stale=0
  S6 REQ-061: `blocked-by:` cycle -- REQ-061 -> REQ-062 -> REQ-061. No member of a cycle can ever reach done or cancelled while it waits on the others, ...

--- F-HATCH-CYCLE-3 ---
  verdicts: [3x :legitimate]  stale=0
  S6 REQ-071: `blocked-by:` cycle -- REQ-071 -> REQ-072 -> REQ-073 -> REQ-071. ...

--- F-DEFERRED-NO-STAGE ---
  verdicts: [{"REQ-081", :undecidable, :stage_scoped}]  stale=0
  S2 REQ-081: deferred requirement carries no `stage:` -- its staleness is undecidable, and an undecidable deferral is a violation rather than a silent exemption

--- F-STAGE-EXACT-MATCH ---
  verdicts: [{"REQ-091", :legitimate, :stage_scoped}]  stale=0     (a `done` REQ in S10 does NOT activate S1)
  (no violations)

--- F-NO-REQUIREMENTS-KEY ---  S5 : the requirements section contains zero entries (or the file has no top-level `requirements:` key) -- ...
--- F-EMPTY-SECTION ---        S5 : (same)
```

`render/1` on the stale fixture (**F-ROSTER-EXPLAINS** — names the id, its stage, and a
witness id, and the violation is in the exit-code-bearing list, not merely printed):

```
========================================================================
mix letflow.check_deferral_staleness -- docs/requirements.yaml
========================================================================
STAGE ACTIVITY (derived, always reported, never gates):
  S4  ACTIVE  [1 done, 1 pending]  active via REQ-001
------------------------------------------------------------------------
DEFERRALS (legitimate ones are reported and never gate):
  REQ-002  S4  stage-scoped  STALE
      stage-scoped; stage S4 is ACTIVE -- made active by REQ-001 (done)
------------------------------------------------------------------------
1 deferred of 2 entries; 1 stale
------------------------------------------------------------------------
VIOLATIONS (each one fails the run):
  [S1] REQ-002 (line 6): STALE deferral -- stage-scoped; stage S4 is ACTIVE -- made active by REQ-001 (done). Either register it (`register_task`, which is the only source of an `impl_order`), or re-scope the rationale to a live `blocked-by: REQ-NNN -- <reason>`
========================================================================
```

Three results worth calling out:

1. **F-STALE-BASIC is also F-HISTORICAL-S4-STALE.** Its rationale is the real historical
   string `-- see the S8 note above` on a `pending` entry in an S4 that holds a `done`
   sibling — the exact shape of REQ-128…REQ-135 at `75f553d`. The detector calls it
   **`:stale`** and names the witness. That is the only real-world evidence this gate does
   useful work, and it now exists as an executed result rather than a claim.
2. **F-TYPO-DOES-NOT-DEACTIVATE behaves as the design demands, which is subtle**: the
   deferral itself reads `:legitimate` (the typo'd sibling confers no activity) but the run
   is **RED via S4**. There is no quiet green. That is exactly §7.4's wording, and it is
   the MS6 defence working.
3. **F-HATCH-CYCLE-2/3**: both members stay `:legitimate` by the per-entry hatch rules —
   which is precisely why the gate would have been defeated without S6 — and the run is red
   on the file-level **S6** violation naming the whole cycle in order. This confirms the
   Step-2b gate's MAJOR #2 was a real hole and that placing S6 in `audit/1` rather than
   `classify_deferral/3` was the correct call.

---

## 3. The bounded diff to the precedent module, in full

```diff
   @stage_re ~r/^\s+stage:\s*(\S+)/
+  # First whitespace-delimited token only, mirroring @stage_re: 8 real `status:`
+  # lines carry a trailing `# ...` comment, which a rest-of-line capture would
+  # sweep in. Stored raw and uninterpreted -- all status semantics live in
+  # `Mix.Tasks.Letflow.CheckDeferralStaleness` (ISS-0258), never here.
+  @status_re ~r/^\s+status:\s*(\S+)/

           stage: String.t() | nil,
+          status: String.t() | nil,
           state: state(),

       stage: extract_stage(attributed),
+      status: extract_status(attributed),
       state: :unclassified,

+  @spec extract_status([{pos_integer(), String.t()}]) :: String.t() | nil
+  defp extract_status(attributed) do
+    Enum.find_value(attributed, fn {_n, line} ->
+      case Regex.run(@status_re, line) do
+        [_, status] -> status
+        nil -> nil
+      end
+    end)
+  end
+
   @spec token?(String.t()) :: boolean()
```

17 insertions, 0 deletions, 0 modifications. `attributed` is the existing >=4-space-filtered
line list, so the second half of §6.3's trap (block notes) is handled by construction —
`extract_status/1` cannot see an unattributed line because it is never given one.

---

## 4. Divergence from the design

**None.** Every rule S1–S6, every type in §6.1, every public signature in §6.2, D1–D7, and
I1–I8 are implemented as written. No rule was added, removed, widened, or reinterpreted.
No dependency was added; parsing stays line-oriented via the single shared
`CheckRequirementsRegistration.scan/1` (I3).

Two implementation choices the design left to the implementer, recorded so REVIEWER can
object rather than discover them:

1. **An expired hatch yields both S3 and S1.** §7.4's F-HATCH-BLOCKER-DONE says "`:stale`,
   S1/S3 violation", which is ambiguous between "S1 or S3" and "both". I emit both: S3
   states the hatch expired, S1 states the resulting staleness, and the verdict is `:stale`
   per §D6 ("the deferral is stale again"). Emitting both is strictly louder and neither
   can mask the other. One-line change if REVIEWER prefers S3 alone.
2. **S5 covers "no `requirements:` key" as well as "zero entries"**, in one message naming
   both conditions. §7.4 says F-NO-REQUIREMENTS-KEY must yield "a violation" without naming
   a rule, while F-EMPTY-SECTION names S5; `scan/1` renders both as `entry_count == 0`, so
   distinguishing them would require a second look at the content and would break I3's
   one-parser invariant. Both are red; neither is a silent green.

Open questions the design left for this gate: **OQ-1 and OQ-3 were closed at Step 2b** and
are not re-opened here. **OQ-4** (alias slot) is live — I implemented slot 3 per D5; the
design is indifferent to the index and firm only about being in the alias, so say so if
another slot is preferred.

---

## 5. Things I could not do / must flag

- **`mix letflow.check` cannot exit 0 on any branch right now.** Two unused-default-arg
  warnings in `test/letflow/engine_sub_process_test.exs:96` and
  `test/letflow/engine/sub_process_test.exs:44` trip `letflow.check.test`'s ISS-0069 gate.
  Pre-existing (attribution table in V5), already documented in the ISS-0231 test report,
  already routed as a separate ELIXIR-DEV issue there. Not fixed here — out of scope.
- **No tests were written.** That is TEST-DESIGNER's job at Step 4
  (`test/mix/tasks/letflow_check_deferral_staleness_test.exs`, per §6.4). §7.1 requires
  mutation-based fail-first because the pre-fix failure for a *new* module is only
  `UndefinedFunctionError`. **MS3** (remove `:done` from `@active_statuses`) and **MS9**
  (accept `blocked-by:` regardless of the blocker's status) are the two mandatory mutants;
  `tmp/iss0258_fixture_probe.exs` already exercises the fixtures both need.
- **Concurrency note.** A sibling session in this worktree committed my in-flight files as
  a WIP checkpoint (`7f40371`) while the 430 s suite was running, moving HEAD from the
  briefed `288fe81` to `7b88f02`. I verified the checkpoint contains my five files
  unmodified (`git diff HEAD` empty, content byte-identical to what I wrote) and continued
  rather than reverting or re-applying. All verifications above were run against the
  working tree in its current, committed state.
- **No `lib/letflow/` domain code was touched**, so the ELIXIR-DEV self-review items about
  `:gen_statem`, the README state diagram, the `process_instance.ex` property test, and
  migrations are all N/A for this change.
