# WF-03 Step 4b — TEST-DESIGN-VALIDATOR

Run: `WF03-ISS0258-20260822`
Agent: `TEST-DESIGN-VALIDATOR`
Branch: `fix/WF03-ISS0258-20260822` @ `85f1c52`
Gates: Step 4 (`TEST-DESIGNER`), `handoffs/WF03-ISS0258-20260822/step-04-test-designer.md`
Under review: `test/specs/ISS-0258.md`,
`test/mix/tasks/letflow_check_deferral_staleness_test.exs` (55 tests)

---

## VERDICT: **FAIL**

One MAJOR. Everything else in Step 4 is confirmed — and confirmed *by independent
measurement*, not by reading TEST-DESIGNER's table. All three mandatory mutants reproduce
to the exact test count and the exact red-test set TEST-DESIGNER reported, and three
further mutants of my own choosing were all killed.

The MAJOR is narrow and cheap: **the one line that satisfies acceptance criterion 2 is
protected by no test at all**, and I measured that by deleting it. Remedy is a single
~12-line test with existing in-repo precedent. Nothing else needs to change.

---

## 1. Acceptance-criterion coverage

| # | ISS-0258 acceptance criterion | Runnable test? | Ruling |
|---|---|---|---|
| AC1 | A mechanism surfaces a DEFERRED requirement whose stage has since become active, **distinct from** one legitimately deferred pending a not-yet-active stage | `F-STALE-BASIC`, `F-LEGIT-BASIC`, and the paired `F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE` (the real historical 13/8 split) | **COVERED.** Confirmed live: MS3 turns `F-STALE-BASIC` and the 13/8 split red. Both halves of the distinction are asserted, and the paired test means a rule that gets one half right and the other wrong is still caught. |
| AC2 | The mechanism is **wired into an actual gate** a human/CI will see — not built and left unwired | `T-TASK-RAISES`, `T-TASK-PRINTS-ON-GREEN`, `T-TASK-MISSING-FILE` cover the *gate surface* (the task raises `Mix.Error`). The **alias membership** is covered by nothing. | **PARTIAL — see MAJOR-1.** |
| AC3 | The design states explicitly why this is a separate detector rather than an extension of `check_requirements_registration` | Design §D3 (documentary); test-side consequence `T-REG-STILL-GREEN` | **COVERED**, to the extent a documentary criterion can be. `T-REG-STILL-GREEN` is the right test-side proxy: it proves D4's `status` addition to the sibling module was actually bounded, which is the falsifiable half of "separate detector". |

### Design §7.4 fixture inventory — fully covered

I enumerated all 39 fixture ids in design §7.4 and grepped each against the test file.
**All 39 are present.** Exactly one id has no test of its own name:

- `F-HISTORICAL-S4-STALE` lives inside
  `test "F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE -- the 13/8 split (MS1, MS2, MS3)"`.

**This is not a MINOR, and I am explicitly ruling against the parent's prompt on this
point.** Design §7.4 *instructs* it: *"Pair it with F-S8-SHAPE-LEGIT in one test group so
the 13/8 split is asserted as a whole — a rule that gets one half right and the other
wrong is not detected by either fixture alone."* Splitting them would weaken the
assertion, not strengthen it.

TEST-DESIGNER's §2 self-report of "two fixtures folded into neighbours" is **more
conservative than the truth**: `F-STALE-EXITS` and `F-EMPTY-STAGE-INACTIVE` both exist as
standalone tests (lines 275 and 198). Sharing a fixture *corpus* with a neighbour is not
folding. No MINOR here.

Three tests beyond the inventory (`F-STAGE-EXACT-MATCH-REVERSE`,
`F-HATCH-INVALID-STILL-JUDGED`, `F-DUPLICATE-ID-DENOMINATOR`) plus `F-STATUS-RAW-TOKEN`
are additions, not substitutions.

---

## 2. MAJOR-1 — the gate wiring is unprotected, and I broke it with 117/117 still green

ISS-0258 AC2 reads, verbatim:

> "The mechanism is wired into an actual gate or report a human/CI will see — **not built
> and left unwired (the exact failure ISS-0231 itself just fixed for a sibling case)**"

The wiring exists and is correct today — I read it:

```
mix.exs:64      "letflow.check": [
mix.exs:65        "letflow.check_toolchain",
mix.exs:66        "letflow.check_requirements_registration",
mix.exs:67        "letflow.check_deferral_staleness",
```

I then deleted line 67 and ran the suite:

```
$ python tdv_mutate.py mix.exs '        "letflow.check_deferral_staleness",<NL>' ''
MUTATE-OK mix.exs

$ sed -n '64,70p' mix.exs
      "letflow.check": [
        "letflow.check_toolchain",
        "letflow.check_requirements_registration",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "letflow.check.test"
      ]

$ mix test test/mix/tasks/
Result: 117 passed
```

**Zero failures.** The detector is fully unwired from the only gate surface this
repository has, and the entire test suite for both task modules is green. I also
confirmed no test anywhere in `test/` asserts on the `aliases` list
(`grep -rn "aliases\b" test/ --include=*.exs` returns only two unrelated prose comments in
`test/letflow/role_registry_test.exs`).

**Why this is MAJOR and not MINOR.** `test/specs/ISS-0258.md` discloses the gap honestly —
*"the alias wiring itself is verified by RELEASE-VALIDATOR running `mix letflow.check`"* —
and that is a real downstream gate, so AC2 is **satisfied by the fix as it stands today**.
But Step 4's product is *regression* coverage, and this is the one line whose silent
deletion reproduces, exactly and by name, the failure mode AC2 was written to forbid. An
issue whose entire thesis is *"a check nobody runs is not a check"* and *"the root cause is
a missing invariant — nothing notices when this rots"* cannot ship with its own wiring
guarded only by a human-run command. That is the same defect one level up, for the third
time in this issue lineage (ISS-0221 → ISS-0231 → ISS-0258).

**Remedy — one test, and there is in-repo precedent.**
`test/letflow/engine/lua_script_audit_test.exs:419` already contains a
`describe "mix.exs and moduledoc guardrails"` block that reads and asserts on `mix.exs`
content. Copy that shape:

```elixir
test "the detector is wired into the letflow.check alias (ISS-0258 AC2)" do
  aliases = Mix.Project.config()[:aliases][:"letflow.check"]

  assert "letflow.check_deferral_staleness" in aliases

  # Design: positioned AFTER the registration check, so a broken file shape
  # surfaces as R2/R6 first.
  assert Enum.find_index(aliases, &(&1 == "letflow.check_deferral_staleness")) >
           Enum.find_index(aliases, &(&1 == "letflow.check_requirements_registration"))
end
```

(`Mix.Project.config/0` is available under `mix test`; if it proves awkward, reading
`mix.exs` as a string per the `lua_script_audit_test.exs` precedent is equally acceptable.)

Route back to **TEST-DESIGNER**. Nothing else in Step 4 requires rework.

---

## 3. Mutant table — my own measurements, applied independently

**Method.** All mutation performed in a throwaway `git worktree`
(`.claude/worktrees/tdv2-iss0258`, detached at `85f1c52`), `git checkout -- lib/` after
every mutant, mutants applied by `tdv_mutate.py` which **refuses to write unless the
target string occurs exactly once** (so a mis-typed mutant fails loudly rather than
silently no-op'ing). The working checkout was never mutated.

I did **not** take TEST-DESIGNER's counts on trust — every row below is from a run I
executed, and I quote the real red-test names.

**Baseline, measured in the throwaway before any mutant:**

```
$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Finished in 1.2 seconds (1.2s async, 0.02s sync)
Result: 55 passed
```

### 3.1 The three mandatory re-applications

| # | exact change | TEST-DESIGNER claimed | **I measured** | agree? |
|---|---|---|---|---|
| **MS3** | `@active_statuses [:done, :in_progress, :blocked]` → `[:in_progress, :blocked]` | 41/55, 14 red | **`Result: 41/55 passed`, 14 red** | **exact** |
| **MS9** | `@expired_blocker_statuses [:done, :cancelled]` → `[]` | 53/55, 2 red | **`Result: 53/55 passed`, 2 red** | **exact** |
| **MS4C** | `R`: `@status_re ~r/^\s+status:\s*(.*)$/` **and** `D`: `token = String.trim(raw)` | 50/55, 5 red | **`Result: 50/55 passed`, 5 red** | **exact** |

**MS3 — the mandatory mutant, ISS-0258 reproduced inside its own fix. 14 red, verbatim:**

```
 1) test render/1 F-ROSTER-EXPLAINS -- a stale roster names id, stage and a witness
 2) test stage_activity/1 -- the activity ruling F-STAGE-EXACT-MATCH -- S10 work must not activate S1 (MS13)
 3) test status parsing (S4) F-STATUS-TRAILING-COMMENT -- a commented `done` still activates (MS4)
 4) test staleness verdicts (S1, S2) F-STALE-BASIC -- deferred in a stage with a done sibling is STALE
 5) test the historical corpus at 75f553d F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE -- the 13/8 split (MS1, MS2, MS3)
 6) test the blocked-by hatch (S3) F-HATCH-DANGLING -- an absent blocker is rejected, not honoured (MS8)
 7) test T-LIVE-* -- the real docs/requirements.yaml T-LIVE-ACTIVITY -- S0..S4 active, S8/S9 inactive (MS1, MS2, MS3)
 8) test staleness verdicts (S1, S2) F-SELF-EXCLUSION -- a deferral does not activate its own stage (MS10)
 9) test staleness verdicts (S1, S2) F-SELF-EXCLUSION-NOT-GAMEABLE -- two deferrals do not excuse each other
10) test stage_activity/1 -- the activity ruling F-DONE-IS-ACTIVE -- :done confers activity (MS3, the mandatory mutant)
11) test the blocked-by hatch (S3) F-HATCH-BASIC -- a live hatch survives an active stage
12) test staleness verdicts (S1, S2) F-STALE-EXITS -- a stale deferral is a violation, not just a roster line (MS11)
13) test stage_activity/1 -- the activity ruling F-STAGE-EXACT-MATCH-REVERSE -- S1 work must not activate S10 (MS13)
14) test T-TASK-RAISES -- a stale deferral raises Mix.Error   (…TaskTest)
```

13 of 14 are hermetic; `T-LIVE-ACTIVITY` is the only live-corpus test and is not needed
for detection.

**MS9 — the hatch never expires. 2 red, verbatim:**

```
 1) test the blocked-by hatch (S3) F-HATCH-BLOCKER-CANCELLED -- a cancelled blocker expires it too (MS9)
 2) test the blocked-by hatch (S3) F-HATCH-BLOCKER-DONE -- the hatch expires when the blocker is done (MS9)
```

Both hermetic. No live test moves — confirming design §7.2's prediction that the live
corpus has zero deferrals and therefore zero hatches, so the hermetic group is the *entire*
regression value for S3.

**MS4C — the §6.3 double-layer trap. 5 red, verbatim:**

```
 1) test normalise_status/1 F-STATUS-TRAILING-COMMENT -- first token only, not rest-of-line (MS4)
 2) test status parsing (S4) F-STATUS-TRAILING-COMMENT -- a commented `done` still activates (MS4)
 3) test T-LIVE-* -- the real docs/requirements.yaml T-LIVE-GREEN -- the real corpus produces zero violations
 4) test T-LIVE-* -- the real docs/requirements.yaml T-LIVE-STATUS-TOTAL -- no entry resolves to :unknown (MS4, MS5)
 5) test status parsing (S4) F-STATUS-RAW-TOKEN -- the parser stores the first token, not rest-of-line (MS4)
```

**`F-STATUS-RAW-TOKEN` — the test TEST-DESIGNER hand-wrote to close the hole it found — is
in the red set. Independently confirmed: the coverage hole is genuinely closed, and the
closure was necessary.** 3 hermetic + 2 live, and the 2 live are genuine signal (real
`status:` lines in the corpus carry trailing comments), which design §7.2 permits.

### 3.2 Three mutants of my own that TEST-DESIGNER did not try

I chose targets none of the 18 rows touch, biased toward code with a single detector.

| # | target — why I picked it | exact change | **measured** | red tests |
|---|---|---|---|---|
| **MV-1** | The **self-license clause** of `hatch_state/3`. `F-HATCH-SELF` exists but *no mutant in the 18-row table ever exercised it* — the design's mutant list jumps from MS8 (dangling) to MS9 (expired) and never probes self-reference, the most obvious unfalsifiable hatch. | `{:invalid, "names its own id #{id}, …"}` → `{:live, id}` | **`Result: 54/55 passed`, 1 red** | `F-HATCH-SELF -- naming your own id is an unfalsifiable self-license` |
| **MV-2** | An **entry inside `@known_statuses`**, not its default. MS6 mutated the fallback (`:pending` instead of `:unknown`); nothing mutated the map's contents, where a one-word typo is at least as likely. Also probes the OQ-1 `:blocked` ruling from the parsing side. | `"blocked" => :blocked,` → `"blocked" => :pending,` | **`Result: 53/55 passed`, 2 red** | `F-STATUS-TOKEN -- every declared status maps to its atom`; `F-BLOCKED-IS-ACTIVE -- :blocked confers activity (design OQ-1)` |
| **MV-3** | **`render/1`'s witness list** — the human-visible surface that makes a red run *actionable*, with `F-ROSTER-EXPLAINS` as sole nominal detector. A gate that fires without naming why is half a gate. | `shown = Enum.take(witnesses, 5)` → `shown = []` | **`Result: 52/55 passed`, 3 red** | `F-SELF-EXCLUSION-NOT-GAMEABLE`; `F-ROSTER-EXPLAINS -- a stale roster names id, stage and a witness`; `F-STALE-BASIC -- deferred in a stage with a done sibling is STALE` |
| **MV-4** | **The gate wiring itself** (§2 above). | delete `"letflow.check_deferral_staleness",` from `mix.exs` | **`Result: 117 passed`, 0 red** | **SURVIVES — MAJOR-1** |

**MV-1/MV-2/MV-3: killed. MV-4: survives.**

Note on MV-1: the S6 cycle rule does **not** catch a self-reference as a 1-cycle —
`F-HATCH-SELF` is the only thing standing between the corpus and a permanent
self-granted license. That is adequate (one test is coverage) but it is a single point of
failure on the most gameable construct in the design. Recorded as MINOR-2.

### 3.3 Fail-first discipline — confirmed, and confirmed to be real

The design §7.1 concession is correct and the WF-03 clause applies: this fix **adds** a
module, so the pre-fix run is `UndefinedFunctionError` for all 55 tests and proves only
that the module is new. **I did not accept that as fail-first, and I did not accept
TEST-DESIGNER's table as fail-first either.**

Six mutants applied by me against the *shipped* logic produced six *behavioural* failure
sets — assertion failures on verdicts, statuses, activity tables and rendered output, not
`UndefinedFunctionError`. The suite discriminates a correct implementation from a wrong
one. **Fail-first is satisfied on the S1/S3/S4 rules by my own measurement.**

---

## 4. Skips, exclusions, fixture isolation, secrets

| Check | Result |
|---|---|
| `@tag :skip` / `@moduletag :skip` | **None.** Only `async:` tags exist (lines 55, 888). |
| `ExUnit.configure` exclude/include filters | **None** in `test/test_helper.exs` or `mix.exs`. No test is silently filtered out. |
| `TODO: implement test` in the spec | **None.** |
| Tests requiring another test to have run first | **None.** The hermetic module is `async: true` with immutable module-attribute string constants (`@stages_section`, `@green`, `@red`) — read-only, never mutated. |
| Shared hardcoded fixture state | **None.** `in_corpus/2` builds a **unique** temp dir per call (`System.unique_integer([:positive])`) and registers `on_exit(fn -> File.rm_rf!(dir) end)`. `…TaskTest` is correctly `async: false` because `File.cd!/2` mutates process-global cwd — the right call, and the cd window is confined to the single `run/1`. |
| Hardcoded secrets / connection strings | **None.** Grepped for password / secret / token= / `postgres://` / api-key / host:port — zero hits. No DB, no network in this test file. |
| `mix format --check-formatted` | **`FORMAT_OK`** |

---

## 5. MINOR findings (do not block; record, do not necessarily fix now)

**MINOR-1 — `T-LIVE-DEFERRED-COUNT-IS-ZERO` is a foot-gun aimed at this feature's own
happy path.** It asserts `result.deferral_count == 0` against the live
`docs/requirements.yaml`. The first time anyone writes a *legitimate* deferral — the
supported, intended workflow this whole detector exists to serve — the suite goes red for
a correct action. The in-file comment is good and explains the intent ("NOT a permanent
invariant… documents today's vacuous green"), so a reader will understand it. Suggested
relaxation if it ever bites: keep `assert result.stale_count == 0` (the real invariant)
and downgrade `deferral_count` to an informational `IO.puts`. Not fixing this now is
defensible.

**MINOR-2 — the self-license hatch has exactly one detector.** See MV-1. `F-HATCH-SELF`
is the sole test standing between the corpus and a permanent self-granted license, and
S6's cycle detection does not treat a 1-cycle as a cycle. Consider extending
`cycle_violations/1` to catch self-loops so the property has two independent guards, or
accept the single detector as sufficient.

**MINOR-3 — `T-LIVE-ACTIVITY` will rot, by ruling.** It pins the exact sets
`active == ["S0","S1","S2","S3","S4"]` and `inactive == ["S8","S9"]`. This is design OQ-5,
ruled deliberately and documented in the test body with a "failure here means *expected
update*, not *regression*" note. **Accepted as-is** — the ruling is on record and the note
is where a future reader will actually see it. Flagged only so it is not later mistaken
for an oversight.

---

## 6. Mutant isolation and revert verification

Throwaway-worktree technique, per WF-03 and the `WF03-ISS0231-20260822` precedent. **The
working checkout was never mutated at any point.**

Housekeeping note: the killed prior run left a **dirty, mid-mutant** throwaway at
`.claude/worktrees/tdv-mut-iss0258` (modified `lib/`, 21 `mut_*.out` files). I did **not**
reuse it — reusing a worktree left in an unknown mutated state would have contaminated my
baseline. I removed it and created a clean one.

```
$ git worktree remove --force …/.claude/worktrees/tdv-mut-iss0258     # killed run's leftover
$ git worktree add     …/.claude/worktrees/tdv2-iss0258 HEAD --detach
Preparing worktree (detached HEAD 85f1c52)
…  six mutants, `git checkout -- lib/` after each  …
$ git checkout -- lib/ mix.exs
$ git status --porcelain lib/ mix.exs test/          # in the throwaway
(empty)
$ git worktree remove --force …/.claude/worktrees/tdv2-iss0258
$ git worktree prune
```

`git worktree list` after cleanup contains **neither** `tdv-mut-iss0258` **nor**
`tdv2-iss0258`. The nine remaining entries all belong to other concurrent runs
(`WF02-REQ077`, `WF02-REQ078`, `WF03-ISS0224/0227/0229/0230/0231`) and were not touched.

Revert verified in the working checkout, both required ways:

```
$ git status --porcelain lib/ test/
(empty)

$ git status --porcelain
?? tdv_mutate.py
?? tdv_names.py

$ mix format --check-formatted
FORMAT_OK

$ mix test test/mix/tasks/
Result: 117 passed
```

The two `??` entries are the scratch scripts the parent instructed me not to delete. No
tracked file differs from `85f1c52`.

---

## 7. The two scratch scripts — disposition

Both sit in the worktree root, untracked.

**`tdv_mutate.py` — has lasting value. Recommend promoting to `scripts/`.**
It is a single-occurrence-enforcing string replacer: it counts occurrences and **exits 2
without writing unless the count is exactly 1**. That property is the reason it is worth
keeping. Every WF-03 run whose fix adds a module must apply mutants, and the silent
failure mode of that work is a mutant that never actually landed (typo, whitespace drift,
string appears twice) producing a green run that gets misread as "the mutant was killed by
nothing" or, worse, as a passing baseline. This script makes that failure loud. It is
16 lines, has no dependencies beyond stdlib, and handles UTF-8 and newline preservation
correctly (`newline=''`), which naive `sed` on this repo's files does not. It is also
cross-platform, which matters here — this repo is worked on Windows where `sed -i`
quoting is a recurring hazard. **Suggest ORCH route a small follow-up to move it to
`scripts/mutate.py` and reference it from `WF03_issue_resolving.md`'s mutant-isolation
section.** I did not move it myself: promoting a file into the tracked tree is outside a
validator's remit, and this branch is under gate.

**`tdv_names.py` — disposable scratch. Recommend deleting.**
It reports the longest `describe` + `test` name in this one test file against ExUnit's
255-character limit, with the path **hardcoded** to
`test/mix/tasks/letflow_check_deferral_staleness_test.exs`. It answered a one-time question
(this file has unusually long, id-prefixed test names — the longest is
`"F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE -- the 13/8 split (MS1, MS2, MS3)"` inside a
`describe`) and that question is now answered: all 55 names are well under the limit, and
the suite compiles and runs, which is the real proof. It has no reusable form without
being rewritten to take a path argument, at which point it is a new script rather than
this one. No lasting value.

Neither was deleted, per instruction. Neither is staged.

---

## 8. What Step 4 got right — recorded, because a FAIL should not obscure it

- **The coverage hole TEST-DESIGNER found and closed is real, and its closure is real.**
  I confirmed by measurement that `F-STATUS-RAW-TOKEN` is in MS4C's red set. TEST-DESIGNER
  discovered that the §6.3 trap is defended twice and that mutating either layer alone is
  absorbed by the other — a genuinely subtle finding — and closed it with an assertion on
  design D4's stated contract rather than on incidental behaviour. That is the correct fix
  for that hole.
- **Splitting design MS4 into MS4/MS4B/MS4C was the right call** and TEST-DESIGNER
  flagged it for me rather than quietly reporting the design's single ambiguous row.
- **Every count I re-measured matched exactly**, including the full 14-name red set for
  MS3. Nothing in the Step 4 table was inflated or approximated.
- **Hermeticity holds.** No mutant I applied was detected only by a live-corpus test.
- The three mutants I invented independently all landed on ground the suite already
  covers, which is itself evidence the inventory is dense rather than lucky.

---

## Handoff record

| Item | Value |
|---|---|
| Verdict | **FAIL** |
| MAJOR | 1 — AC2's `mix.exs` alias wiring has no test; deleting it leaves 117/117 green |
| MINOR | 3 — live-deferral-count foot-gun; single detector on the self-license hatch; `T-LIVE-ACTIVITY` rot (accepted, OQ-5) |
| Route back to | **TEST-DESIGNER**, for one added test. No other rework. |
| Mandatory mutants re-applied | MS3, MS9, MS4C — **all three reproduce exactly** |
| Own mutants applied | MV-1, MV-2, MV-3 (killed) + MV-4 (**survives**) |
| Baseline measured by me | `Result: 55 passed` |
| Fail-first discipline | **Satisfied by behavioural mutation**, not `UndefinedFunctionError` |
| Design §7.4 inventory | 39 of 39 fixture ids covered |
| Skips / exclusions / secrets | none / none / none |
| Throwaway worktrees | `tdv-mut-iss0258` (inherited, dirty) and `tdv2-iss0258` (mine) — both removed; `git worktree list` shows neither |
| `git status --porcelain lib/ test/` | **empty** |
| `mix format --check-formatted` | `FORMAT_OK` |
| `mix test test/mix/tasks/` | `Result: 117 passed` |
| Committed by me | **No** — parent stages and commits |
