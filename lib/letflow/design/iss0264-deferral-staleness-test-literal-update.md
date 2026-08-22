# ISS-0264 — `T-LIVE-ACTIVITY` literal update (deferral-staleness detector test)

**Issue:** ISS-0264 (WF-03, run `WF03-ISS0264-20260822`)
**Owner of implementation:** `ELIXIR-DEV`
**Author:** `CODE-DESIGNER`
**Diagnosis inherited from:** ISSUE-FIXER's Step-1 handoff for this run (already reproduced;
not re-derived here).

No implementation code appears in this document. Exact literal values, exact comment
wording, and file/line targets only.

---

## 1. What this is (and, explicitly, is not)

This is **not** a design decision. The design that governs this test —
`lib/letflow/design/iss0258-deferral-staleness-detection.md` — already ruled, in advance,
that `T-LIVE-ACTIVITY` (`test/mix/tasks/letflow_check_deferral_staleness_test.exs`, inside
`describe "T-LIVE-* -- the real docs/requirements.yaml"`) pins the **active/inactive stage
set** as a literal, on purpose, and documented in OQ-5 (§7.4 of that design, quoted in the
Step-1 handoff) exactly the event this run is: the pinned set going stale as real
`docs/requirements.yaml` data moves. §7.3's mutant table (the "must be caught by" column,
lines 716-718 of that file, re-checked verbatim) cites this same test as a joint detector
for **MS2** (`:pending` wrongly made active — row: `F-PENDING-NOT-ACTIVE,
F-S8-SHAPE-LEGIT, T-LIVE-ACTIVITY`) and **MS3** (`:done` wrongly removed from active —
"the mandatory mutant"; row: `F-DONE-IS-ACTIVE, F-STALE-BASIC, T-LIVE-ACTIVITY`). **MS1**
(`:cancelled` wrongly made active) is caught by `F-CANCELLED-NOT-ACTIVE,
F-S8-SHAPE-LEGIT, F-HISTORICAL-S4-STALE` only — T-LIVE-ACTIVITY is not in that row, and is
not required as one of MS1's detectors. (§7.4's prose description of T-LIVE-ACTIVITY
elsewhere in the same design says it "catches MS1, MS2, MS3" — that line is looser prose
than the §7.3 table and is not itself being corrected here, since it is outside this
run's scope; the §7.3 table's per-mutant "must be caught by" column is the authoritative
mapping for the claim this document makes.) §7.2 separately rules: *"No mutant in §7.3
may cite a live-corpus test as its only detector, except MS1, MS2, MS4 and MS5, where the
live corpus genuinely discriminates."* That sentence does not itself assert which
live-corpus test detects MS1 — only that some live-corpus test may. It is consistent with
MS2 and MS3 alone being T-LIVE-ACTIVITY's contribution, and MS1's contribution coming from
a different live-corpus test or none. `T-LIVE-ACTIVITY` is required to stay a real,
discriminating pin because of MS2 and MS3 alone — which is sufficient on its own — not
because of MS1.

The T-ROSTER precedent (`iss0231-requirement-registration-drift-detection.md` §11.6 OQ-5)
converted a similar pinned live-corpus assertion to an unpinned/derived form **because,
when re-derived, both forms were proven equally discriminating against the mutant that
mattered.** That precondition does not hold here: the property under test (which named
stages are active) has no self-consistency check to fall back on the way "the roster lists
exactly the deferred ids" did for T-ROSTER. So this fix does **not** unpin the test — it
performs the exact maintenance action §OQ-5 specified: update the literal, extend the
comment, move on.

This document exists only so ELIXIR-DEV has zero interpretive latitude on the two literals
and the comment text — not because the update itself is in doubt.

---

## 2. The literal update (**RULING — exact values**)

File: `test/mix/tasks/letflow_check_deferral_staleness_test.exs`
Test: `T-LIVE-ACTIVITY -- S0..S4 active, S8/S9 inactive (MS1, MS2, MS3)`
Current location: lines ~842–850 (may shift by a line or two if the comment block above it
grows per §3 below — search for the test name string, not the line number, to locate it).

Current body (to be replaced):

```elixir
    test "T-LIVE-ACTIVITY -- S0..S4 active, S8/S9 inactive (MS1, MS2, MS3)", %{result: result} do
      # Design OQ-5: this pins the SET, not the counts, which move with every
      # merge. It will change legitimately when S5/S6/S7 are expanded or when
      # S8 starts -- a failure here means "expected update", not "regression".
      active = for s <- result.stages, s.activity == :active, do: s.stage
      inactive = for s <- result.stages, s.activity == :inactive, do: s.stage

      assert active == ["S0", "S1", "S2", "S3", "S4"]
      assert inactive == ["S8", "S9"]
    end
```

New body — **exactly** this, only the two `assert` lines and the comment change; the
`active`/`inactive` `for`-comprehensions, the `%{result: result}` binding, and the
surrounding `setup` (line ~825-826, `@live_corpus |> File.read!() |> Check.audit()`) are
unchanged:

```elixir
    test "T-LIVE-ACTIVITY -- S0..S4, S8, S9 active (MS1, MS2, MS3)", %{result: result} do
      # Design OQ-5: this pins the SET, not the counts, which move with every
      # merge. It will change legitimately when S5/S6/S7 are expanded or when
      # S8 starts -- a failure here means "expected update", not "regression".
      #
      # UPDATE (WF03-ISS0264-20260822, 2026-08-22): OQ-5's predicted event
      # happened -- S8 and S9 both went active tonight (real in_progress/done
      # requirements registered under REQ-115..139, per
      # docs/migration/decisions/0011-frontend-ownership.md and
      # 0012-mobile-tier-stack.md). New true values, re-derived directly from
      # Mix.Tasks.Letflow.CheckDeferralStaleness.audit/1 against the live
      # docs/requirements.yaml, confirmed independently by CODE-DESIGNER and
      # ISSUE-FIXER: active == every stage S0..S4, S8, S9; inactive == [].
      # This is a test-data-only update -- the detector logic in
      # lib/mix/tasks/letflow.check_deferral_staleness.ex is unchanged and
      # correct; it is doing exactly its job by catching this drift. The next
      # time this assertion fails, treat it the same way: re-derive the true
      # values with audit/1 against the live corpus, don't guess, and extend
      # this comment rather than replacing it.
      active = for s <- result.stages, s.activity == :active, do: s.stage
      inactive = for s <- result.stages, s.activity == :inactive, do: s.stage

      assert active == ["S0", "S1", "S2", "S3", "S4", "S8", "S9"]
      assert inactive == []
    end
```

Notes on exact form, binding on ELIXIR-DEV:

- **Test name string changes too** (from `"S0..S4 active, S8/S9 inactive"` to `"S0..S4, S8,
  S9 active"`), because the old name asserts a now-false proposition in prose and a test
  name that contradicts its own body is confusing to the next reader independent of the
  assertions passing. Renaming a test's descriptive string is not a scope violation — it
  changes no behavior and the mutant table row (§7.3 of the parent design) references the
  test by mutant tag (MS1/MS2/MS3) and by its `describe`/file location, not by this exact
  string, so no other document needs updating for the rename.
- `assert inactive == []` is an empty list literal — not `nil`, not omitted. `stage_facts.stage`
  values are `String.t()`, so `[]` is the correct total-absence form; there is no
  special-case rendering of an empty list by `assert ... == [...]` that differs from a
  non-empty one.
- Do not reorder `["S0", "S1", "S2", "S3", "S4", "S8", "S9"]` — `stage_activity/1` per the
  parent design (§6.2) returns `stages` "sorted by stage id", and lexicographic sort of
  these ids is already ascending in this exact order (S0 < S1 < ... < S4 < S8 < S9), so no
  re-sort logic is being introduced by writing them in this order.

---

## 3. No other assertion in this test file needs to change

Checked (as part of Step-1 diagnosis, re-verified here): every other occurrence of `S8`,
`S9`, `ACTIVE`, or `INACTIVE` in
`test/mix/tasks/letflow_check_deferral_staleness_test.exs` — including the two other
literal `"S8  INACTIVE"` string assertions at (approximately) lines 801 and 975 — belongs to
a **hermetic fixture test**, not to the `T-LIVE-*` / `@live_corpus` group:

- Line ~801, `F-ROSTER-GREEN`: asserts against a `body` built from local `registered/3` +
  `deferred/4` helper calls (a synthetic 2-entry corpus), not `@live_corpus`. Its `"S8
  INACTIVE"` is correct and permanent for that fixture's own content — it does not read
  real `docs/requirements.yaml` and is untouched by tonight's data change.
- Line ~975, `T-TASK-PRINTS-ON-GREEN` (in
  `Mix.Tasks.Letflow.CheckDeferralStalenessTaskTest`): asserts against the module's own
  `@green` fixture string (lines ~932-945, a synthetic single-stage `S8` corpus written into
  a temp dir), likewise independent of the real file.

Both are correctly out of scope for this fix. No other test in the file (or, per the
Step-1 handoff's broader grep across `test/`, in any other file) hardcodes the
`["S0", "S1", "S2", "S3", "S4"]` / `["S8", "S9"]` pattern — that search has already been
run and found nothing else; ELIXIR-DEV does not need to re-run it, only to apply §2's edit.

---

## 4. Explicit scope boundary (**RULING**)

- **`lib/mix/tasks/letflow.check_deferral_staleness.ex` — NOT touched.** The detector's
  `stage_activity/1` and its `@active_statuses` set (`[:done, :in_progress, :blocked]`, per
  the parent design's §3.3 ruling) are unchanged. The detector computed the correct answer
  (`S8`/`S9` active) from the real, current, correct corpus; the test's stale literal was
  the bug, not the code that produced today's true value.
- **`docs/requirements.yaml` — NOT touched.** Its S8/S9 requirement statuses (real
  `in_progress`/`done` entries under REQ-115..139, per
  `docs/migration/decisions/0011-frontend-ownership.md` and
  `0012-mobile-tier-stack.md`) are correct, current, real data, not the defect.
- **Only `test/mix/tasks/letflow_check_deferral_staleness_test.exs` is touched**, and only
  at the one test body specified in §2.
- This is a **test-only** change. No `lib/letflow/` runtime code and no tenant-data path is
  touched, so **SECURITY-REVIEWER is out of scope for this run** (nothing in
  `docs/agents/instructions/security-invariants.md`'s INV-1..INV-8 applies to a test-literal
  edit). REVIEWER's pass over this run is idiom/scope-only: confirm the diff is exactly the
  one test body in §2 (plus the rename noted there), confirm no other file changed, and
  confirm the new comment accurately states what happened — no OTP/supervision/idiom
  surface is implicated.

---

## 5. Verification ELIXIR-DEV must perform after the edit

1. `mix test test/mix/tasks/letflow_check_deferral_staleness_test.exs` — full file green,
   57/57 (56 that already passed, plus this one now passing on the new literal).
2. Confirm via `git diff` (read-only) that the only file changed is
   `test/mix/tasks/letflow_check_deferral_staleness_test.exs`, and the only hunk touches the
   one test body in §2.
3. Re-run `mix letflow.check_deferral_staleness` directly (or `mix letflow.check`) to
   confirm it still exits 0 against the live corpus — this test's assertion and the task's
   own exit code are two independent readings of the same `audit/1` result and should agree.

---

## 6. Open questions

None. This is a fully specified maintenance edit executing a prior design ruling; there is
no design decision left open by this document.
