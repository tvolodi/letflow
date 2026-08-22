# WF-03 Step 4 — TEST-DESIGNER

Run: `WF03-ISS0258-20260822`
Agent: `TEST-DESIGNER`
Branch: `fix/WF03-ISS0258-20260822`
Base HEAD at dispatch: `0f6acf4` · test commits: `60c8a75`, `e778e0d`
Spec: `test/specs/ISS-0258.md`
Test file: `test/mix/tasks/letflow_check_deferral_staleness_test.exs` (new, 55 tests)

## VERDICT: complete — **NOT self-marked PASS.** TEST-DESIGN-VALIDATOR gates this.

---

## 1. Headline numbers, measured

```
$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Result: 55 passed

$ mix test test/mix/tasks/          # both task suites together
Result: 117 passed

$ mix format --check-formatted
FORMAT_OK

$ git status --porcelain            # after all mutation work
(empty)
```

55 tests in two modules: 47 hermetic + task-level in
`Mix.Tasks.Letflow.CheckDeferralStalenessTest` (`async: true`, no filesystem, no DB) and
3 in `…TaskTest` (`async: false`, temp-directory corpora — `run/1` reads
`docs/requirements.yaml` from the cwd and has no path seam, exactly as the ISS-0231
precedent records for the same reason).

## 2. Test inventory — what each group covers

| Group | Tests | Covers |
|---|---|---|
| `normalise_status/1` | `F-STATUS-TOKEN`, `F-STATUS-TRAILING-COMMENT`, `F-STATUS-UNKNOWN-TOTAL` | S4 / I7 totality: `nil`, `""`, `donee`, `DONE` → `:unknown`, never a passing default |
| `stage_activity/1` | `F-DONE-IS-ACTIVE`, `F-IN-PROGRESS-IS-ACTIVE`, `F-BLOCKED-IS-ACTIVE`, `F-PENDING-NOT-ACTIVE`, `F-CANCELLED-NOT-ACTIVE`, `F-UNKNOWN-NOT-ACTIVE`, `F-EMPTY-STAGE-INACTIVE`, `F-STAGE-EXACT-MATCH`, `F-STAGE-EXACT-MATCH-REVERSE` | design §3.3 pinned value by value; S1/S10 leakage asserted in **both** directions, because only one direction is reachable by a prefix mutation |
| staleness verdicts | `F-STALE-BASIC`, `F-LEGIT-BASIC`, `F-STALE-EXITS`, `F-LEGIT-NEVER-GATES`, `F-DEFERRED-NO-STAGE`, `F-SELF-EXCLUSION`, `F-SELF-EXCLUSION-NOT-GAMEABLE` | S1, S2, I4, §3.5 |
| historical corpus | `F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE` (**one test**) | the real 13-legitimate / 8-stale split at `75f553d` — the only real-world evidence this gate does useful work |
| status parsing | `F-STATUS-RAW-TOKEN`, `F-STATUS-TRAILING-COMMENT`, `F-STATUS-BLOCK-NOTE`, `F-UNKNOWN-STATUS-FAILS`, `F-TYPO-DOES-NOT-DEACTIVATE`, `F-NO-STATUS-LINE`, `F-S4-ALL-ENTRIES` | S4 and design §6.3 |
| hatch grammar | `F-HATCH-GRAMMAR`, `F-HATCH-ANCHOR`, `F-HATCH-MALFORMED`, `F-HATCH-NO-RATIONALE` | D6 properties 1 and 4 |
| hatch semantics | `F-HATCH-BASIC`, `F-HATCH-BLOCKER-DONE`, `F-HATCH-BLOCKER-CANCELLED`, `F-HATCH-DANGLING`, `F-HATCH-SELF`, `F-HATCH-INVALID-STILL-JUDGED` | S3, D6 properties 2 and 3 |
| cycles | `F-HATCH-CYCLE-2`, `F-HATCH-CYCLE-3`, `F-HATCH-CHAIN-NO-CYCLE` | S6 / D6 fifth property |
| corpus shape | `F-NO-REQUIREMENTS-KEY`, `F-EMPTY-SECTION`, `F-SHAPELESS-CORPUS`, `F-DUPLICATE-ID-DENOMINATOR` | S5, plus REVIEWER MINOR-2 |
| `render/1` | `F-ROSTER-EXPLAINS`, `F-ROSTER-GREEN`, `F-ROSTER-EMPTY` | the always-printed blocks |
| live corpus | `T-LIVE-GREEN`, `T-LIVE-STATUS-TOTAL`, `T-LIVE-ACTIVITY`, `T-LIVE-DEFERRED-COUNT-IS-ZERO`, `T-REG-STILL-GREEN` | over-firing guards + genuine MS1–MS5 signal + the D4 boundedness check |
| task level | `T-TASK-PRINTS-ON-GREEN`, `T-TASK-RAISES`, `T-TASK-MISSING-FILE` | the gate surface itself: a stale deferral raises `Mix.Error` |

Design §7.4's inventory is covered in full. Two fixtures were folded into neighbours
rather than written standalone because a standalone version would have asserted nothing
extra: `F-STALE-EXITS` is a separate test but shares `F-STALE-BASIC`'s corpus, and the
"stage with no requirements" case (`F-EMPTY-STAGE-INACTIVE`) is asserted as *absence from
the derived table* plus zero violations, which is what the shipped `stage_activity/1`
actually produces (it folds over entries, so a requirement-less stage never appears).
Three tests beyond the inventory were added: `F-STAGE-EXACT-MATCH-REVERSE`,
`F-HATCH-INVALID-STILL-JUDGED` (REVIEWER MINOR-1), `F-DUPLICATE-ID-DENOMINATOR`
(REVIEWER MINOR-2), plus `F-STATUS-RAW-TOKEN` to close a measured hole (§4).

## 3. Mutant table — measured, not asserted

Method: each mutant applied in a **throwaway `git worktree`** of this branch
(`.claude/worktrees/mutants-iss0258`, then `mut2-iss0258` for the two long failure lists),
`mix test` on the suite, `git checkout -- lib/` between mutants. **This checkout was never
mutated.** Both worktrees were removed; `git worktree list` matches `iss0258` throwaways
**0** times.

Baseline: **55 passed, 0 failures.**

`D` = `lib/mix/tasks/letflow.check_deferral_staleness.ex`,
`R` = `lib/mix/tasks/letflow.check_requirements_registration.ex`.

| # | exact one-line change | result | rule |
|---|---|---|---|
| MS1 | `D`: `@active_statuses [:done, :in_progress, :blocked, :cancelled]` | **52/55 pass, 3 red** | S1 |
| MS2 | `D`: `@active_statuses [:done, :in_progress, :blocked, :pending]` | **43/55 pass, 12 red** | S1 |
| MS3 | `D`: `@active_statuses [:in_progress, :blocked]` | **41/55 pass, 14 red** | S1 |
| MS4 | `R`: `@status_re ~r/^\s+status:\s*(.*)$/` | **54/55 pass, 1 red** | S4 |
| MS4B | `D`: `token = String.trim(raw)` (drop the token split) | **54/55 pass, 1 red** | S4 |
| MS4C | MS4 **and** MS4B together — the full §6.3 trap | **50/55 pass, 5 red** | S4 |
| MS5 | `R`: `attributed = body` | **53/55 pass, 2 red** | S4 |
| MS6 | `D`: `Map.get(@known_statuses, token, :pending)` | **51/55 pass, 4 red** | S4 |
| MS7 | `D`: `@blocked_by_re ~r/(?:--\s*)?blocked-by:…` (no `^`) | **54/55 pass, 1 red** | S3 |
| MS8 | `D`: `:error -> {:live, blocker}` in `hatch_state/3` | **53/55 pass, 2 red** | S3 |
| MS9 | `D`: `@expired_blocker_statuses []` | **53/55 pass, 2 red** | S3 |
| MS10 | `D`: `facts -> facts.witnesses` (no `-- [id]`) | **53/55 pass, 2 red** | S1 |
| MS11 | `D`: `defp s1(%{verdict: :never_matches} = d) do` | **47/55 pass, 8 red** | S1 |
| MS12 | `D`: `defp s2(%{stage: :never_matches} = d) do` | **54/55 pass, 1 red** | S2 |
| MS13 | `D`: `Enum.find(stages, &String.starts_with?(stage, &1.stage))` | **54/55 pass, 1 red** | S1 |
| MS14 | `D`: `\|> Enum.reject(fn _ -> true end)` in `cycle_violations/1` | **53/55 pass, 2 red** | S6 |
| MS15 | `D`: `if false do` in place of `if entry_count == 0 do` | **53/55 pass, 2 red** | S5 |
| MS16 | `D`: `parse_scope/1` gains `[_, id] -> {:blocked_by, id}` | **54/55 pass, 1 red** | S3 |

**Every mutant is killed. Every rule S1–S6 has at least one mutant that at least one test
catches** — S1: MS1/MS2/MS3/MS10/MS11/MS13; S2: MS12; S3: MS7/MS8/MS9/MS16;
S4: MS4/MS4B/MS4C/MS5/MS6; S5: MS15; S6: MS14.

### Which tests went red, per mutant

**MS3 (mandatory mutant #1) — 14 red:**
`F-DONE-IS-ACTIVE`, `F-STAGE-EXACT-MATCH`, `F-STAGE-EXACT-MATCH-REVERSE`, `F-STALE-BASIC`,
`F-STALE-EXITS`, `F-SELF-EXCLUSION`, `F-SELF-EXCLUSION-NOT-GAMEABLE`,
`F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE`, `F-STATUS-TRAILING-COMMENT (audit)`,
`F-HATCH-BASIC`, `F-HATCH-DANGLING`, `F-ROSTER-EXPLAINS`, `T-LIVE-ACTIVITY`,
`T-TASK-RAISES`. **13 of the 14 are hermetic**; `T-LIVE-ACTIVITY` is the one live test and
is not needed for detection.

**MS9 (mandatory mutant #2) — 2 red:** `F-HATCH-BLOCKER-DONE`, `F-HATCH-BLOCKER-CANCELLED`.
Both hermetic. No live test moves at all — as design §7.2 predicted, the live corpus has
zero deferrals and therefore zero hatches.

**MS2 — 12 red:** `F-PENDING-NOT-ACTIVE`, `F-STAGE-EXACT-MATCH`,
`F-STAGE-EXACT-MATCH-REVERSE`, `F-LEGIT-BASIC`, `F-LEGIT-NEVER-GATES`,
`F-SELF-EXCLUSION-NOT-GAMEABLE`, `F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE`,
`F-STATUS-BLOCK-NOTE`, `F-HATCH-INVALID-STILL-JUDGED`, `F-ROSTER-GREEN`,
`T-LIVE-ACTIVITY`, `T-TASK-PRINTS-ON-GREEN`. 11 hermetic.

**MS11 — 8 red:** `F-STALE-BASIC`, `F-STALE-EXITS`, `F-SELF-EXCLUSION-NOT-GAMEABLE`,
`F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE`, `F-HATCH-DANGLING`, `F-HATCH-BLOCKER-DONE`,
`F-ROSTER-EXPLAINS`, `T-TASK-RAISES`. All hermetic (`T-TASK-RAISES` uses a temp-dir
fixture corpus, not the live file).

**MS1 — 3 red:** `F-CANCELLED-NOT-ACTIVE`, `F-S8-SHAPE-LEGIT + F-HISTORICAL-S4-STALE`,
`T-LIVE-ACTIVITY`. 2 hermetic. Note the historical fixture is the one that matters: under
MS1 the S8 `cancelled` entry activates S8 and its **9** deferrals flip legitimate → stale,
which is precisely the refutation design §3.3 argues from.

**MS4C — 5 red:** `F-STATUS-RAW-TOKEN`, `F-STATUS-TRAILING-COMMENT (normalise)`,
`F-STATUS-TRAILING-COMMENT (audit)`, `T-LIVE-GREEN`, `T-LIVE-STATUS-TOTAL`. 3 hermetic;
the 2 live tests here are **genuine** signal (8 of 115 real `status:` lines carry a
trailing comment), which is one of the four cases design §7.2 permits.

**MS5 — 2 red:** `F-STATUS-BLOCK-NOTE`, `T-REG-STILL-GREEN`. 1 hermetic.
**MS6 — 4 red:** `F-STATUS-UNKNOWN-TOTAL`, `F-UNKNOWN-STATUS-FAILS`,
`F-TYPO-DOES-NOT-DEACTIVATE`, `F-S4-ALL-ENTRIES`. All hermetic.
**MS7 — 1 red:** `F-HATCH-ANCHOR`. Hermetic.
**MS8 — 2 red:** `F-HATCH-DANGLING`, `F-HATCH-INVALID-STILL-JUDGED`. Both hermetic.
**MS10 — 2 red:** `F-SELF-EXCLUSION`, `F-SELF-EXCLUSION-NOT-GAMEABLE`. Both hermetic.
**MS12 — 1 red:** `F-DEFERRED-NO-STAGE`. Hermetic.
**MS13 — 1 red:** `F-STAGE-EXACT-MATCH-REVERSE`. Hermetic — and note it is the *reverse*
direction that catches it, which is why both directions are asserted.
**MS14 — 2 red:** `F-HATCH-CYCLE-2`, `F-HATCH-CYCLE-3`. Both hermetic.
**MS15 — 2 red:** `F-NO-REQUIREMENTS-KEY`, `F-EMPTY-SECTION`. Both hermetic.
**MS16 — 1 red:** `F-HATCH-NO-RATIONALE`. Hermetic.

### Hermeticity confirmation

**No mutant's red set consists only of live-corpus tests.** Every one of the 18 mutants is
detected by at least one hermetic fixture test, and 13 of the 18 move no live test at all.
The only mutants where a live test moves are MS1/MS2/MS3 (`T-LIVE-ACTIVITY`), MS4C
(`T-LIVE-GREEN`, `T-LIVE-STATUS-TOTAL`) and MS5 (`T-REG-STILL-GREEN`) — exactly the four
cases design §7.2 lists as genuinely discriminating on the live corpus, and in every one
of them the hermetic detectors would suffice on their own.

## 4. The coverage hole I found and closed

**Design MS4 as written killed nothing on the first pass: 54/54 passed.**

Cause: the §6.3 trap is defended **twice** — `@status_re` in the parser *and* the
first-token split in `normalise_status/1`. Mutating either layer alone is absorbed by the
other, so no behavioural assertion anywhere can observe it. Real robustness, but it left
the design's headline parser mutant undetected, which is a coverage hole by §7.3's own
standard ("a mutant no test detects is a coverage hole to close before Step 4 passes").

Closed by **`F-STATUS-RAW-TOKEN`** (commit `e778e0d`), which pins the *raw stored token*:

```elixir
assert [entry] = Registration.scan(doc(body)).entries
assert entry.status == "cancelled"          # not "cancelled  # MVP-1 milestone dropped, …"
```

That is the one observable separating the two layers, and design D4 explicitly guarantees
the field is stored raw and uninterpreted, so the assertion is on contract, not accident.
After closing: MS4 → 1 red, MS4B (the other layer) → 1 red, MS4C (both, the actual §6.3
failure mode) → 5 red including the two live tests carrying the real 8-of-115 signal.

I also **split MS4 into three** rather than reporting the design's single row, because the
single row is ambiguous about which layer it mutates and the answer changes the result
from 0 red to 5 red. TEST-DESIGN-VALIDATOR should re-apply **MS4C** if it wants the
design's intended trap, or MS4/MS4B for the single-layer variants.

## 5. Mutant isolation and revert verification

Preferred technique used: **throwaway `git worktree`**, so this checkout was never
mutated.

```
$ git worktree add …/.claude/worktrees/mutants-iss0258 HEAD --detach     # mutant sweep
$ git worktree add …/.claude/worktrees/mut2-iss0258 e778e0d --detach     # full failure lists
…
$ git worktree remove --force …/mutants-iss0258
$ git worktree remove --force …/mut2-iss0258
$ git worktree list | grep -c iss0258
0
```

Belt and braces, in this checkout after all mutation work:

```
$ git status --porcelain
(empty)

$ git status --porcelain lib/ test/
(empty)

$ mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs
Result: 55 passed

$ mix test test/mix/tasks/
Result: 117 passed
```

The driver scripts (`mutants.sh`, `mut2.sh`) were scratch files, never staged, and are
deleted. Both mutant worktrees also ran `git checkout -- lib/` after their last mutant and
reported an empty porcelain before removal.

## 6. Notes for TEST-DESIGN-VALIDATOR

1. **Re-apply MS3 or MS9** (the two mandatory mutants) — both are single-token changes to
   a module attribute in `lib/mix/tasks/letflow.check_deferral_staleness.ex` lines 212 and
   213, and both are listed above with their exact replacement text and expected counts
   (41/55 and 53/55). MS4C is the third worth re-applying, since it is the one I had to
   correct.
2. **`mix test` on this single file is enough** and takes under a second; the file needs no
   database, and plain `mix run` trips the shared-dev-DB guard (use `mix run --no-start`).
3. **Two design fixtures are asserted inside neighbouring tests, not standalone** — see
   §2's note. If you consider either to warrant its own test id, that is a fair MINOR.
4. **`T-LIVE-ACTIVITY` will go stale by design** (OQ-5). The note explaining that is in the
   test file itself, in the test body and in the module doc, so a future failure reads as
   "expected update".
5. **`F-BLOCKED-IS-ACTIVE` is the OQ-1 tripwire.** If REVIEWER's ruling is ever reversed,
   this test is the one line that must flip with it — deliberately loud.

## Handoff record

| Item | Value |
|---|---|
| Test file | `test/mix/tasks/letflow_check_deferral_staleness_test.exs` (55 tests) |
| Spec | `test/specs/ISS-0258.md` |
| Mutants applied | 18 (MS1–MS16 plus MS4B/MS4C) |
| Mutants killed | 18 of 18 |
| Rules with a caught mutant | S1, S2, S3, S4, S5, S6 — all six |
| Coverage holes found | 1 (design MS4), closed by `F-STATUS-RAW-TOKEN` |
| Working tree after mutation | clean (`git status --porcelain` empty) |
| Self-marked PASS | **No.** TEST-DESIGN-VALIDATOR gates this step. |
