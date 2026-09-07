# ISS-0523 — remove the real-corpus coupling in lint_handoffs' zero-flag test

Design for the fix to ISS-0523 (resolves the incident ISS-0445 diagnosed in
full). Diagnosis: step-01 (ISSUE-FIXER), this session
(`WF03-ISS0523-20260907`). No implementation code below — only the exact
test-body replacement and the reasoning for it.

## 0. Independently re-verified against source (not taken on ISSUE-FIXER's word)

Read `test/mix/tasks/letflow.lint_handoffs_test.exs` directly.

- **The defect, confirmed at its real current location**:
  `T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS`, lines 686-698:

  ```
  test "T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS -- default no-flag invocation still scans @handoffs_dir" do
    io = capture_io(fn -> assert LintHandoffs.run([]) == :ok end)
    assert io =~ ~s(under "handoffs")
    refute io =~ "AUTOFIX"
  end
  ```

  `run([])` resolves via `resolve_dir/1` (`lib/mix/tasks/letflow.lint_handoffs.ex:354`,
  confirmed **public**) to `@handoffs_dir` (`"handoffs"`) and scans the REAL
  `handoffs/` directory. `assert ... == :ok` transitively asserts the whole
  repository's handoff corpus is currently H1-H6-clean at the moment this
  branch's suite runs — the exact cross-session coupling ISS-0445 reproduced
  live (a sibling session's malformed handoff turned this test red on an
  unrelated branch).

- **F-DIR-DEFAULT already exists and already covers the real claim**, lines
  416-420:

  ```
  test "F-DIR-DEFAULT -- resolve_dir/1 with no --dir returns @handoffs_dir unchanged" do
    assert LintHandoffs.resolve_dir([]) == "handoffs"
  end
  ```

  Confirmed: this is a pure unit assertion on `resolve_dir/1`'s zero-flag
  branch — no directory scan, no corpus read, no `capture_io`. It proves
  exactly the property T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS's own inline
  comment (lines 687-693) says is the *only* thing still in scope for it:
  "only proves resolve_dir([]) still feeds run/1 @handoffs_dir."

- **T-DIR-SCOPED-SCAN already exists and already covers the banner-threading
  claim end-to-end**, lines 521-533:

  ```
  test "T-DIR-SCOPED-SCAN -- --dir <fixture> scans ONLY the fixture, and the banner names it",
       %{dir: dir} do
    write_handoff!(Path.join(dir, "step-01-agent.json"), "COMPLETED")
    io = capture_io(fn -> assert LintHandoffs.run(["--dir", dir]) == :ok end)
    assert io =~ inspect(dir)
    assert io =~ "across 1 handoff files"
    refute io =~ "handoffs/WF"
  end
  ```

  Confirmed: this exercises `run/1`'s full banner-printing path (`io =~
  inspect(dir)`, i.e. "under \"<dir>\"" in the same format
  T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS checks for) against an isolated
  `System.tmp_dir!/0` fixture, never the real `handoffs/` tree. Same code
  path (`run/1` → `resolve_dir/1` → banner print), different — safe — input.

Both claims ISSUE-FIXER made are independently confirmed true by direct
reading, not just trusted.

## 1. The fix — chosen option (i): rewrite the test body, keep the slot

Replace T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS's body (lines 694-697) with a
direct unit assertion on `resolve_dir/1`, dropping `run/1`, `capture_io`, and
the real-corpus scan entirely:

```
test "T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS -- default no-flag invocation still scans @handoffs_dir" do
  # ISS-0523: this used to invoke `LintHandoffs.run([])` against the REAL
  # handoffs/ directory and assert :ok, transitively claiming the whole
  # repository's handoff corpus is clean -- see ISS-0445 for the incident
  # this caused (a sibling session's handoff turned this test red on an
  # unrelated branch). The property this test actually owns is narrower:
  # that run/1's zero-flag path still resolves to @handoffs_dir after the
  # --dir branch was added (ISS-0440). That is exactly what resolve_dir/1's
  # own unit test, F-DIR-DEFAULT (line ~416), already asserts -- so this
  # test now asserts the same thing directly, without a corpus scan. The
  # banner-threads-resolve_dir's-output claim is covered end-to-end,
  # corpus-scan-free, by T-DIR-SCOPED-SCAN (line ~521) via a tmp fixture.
  assert LintHandoffs.resolve_dir([]) == "handoffs"
end
```

Net effect: `capture_io`, `LintHandoffs.run([])`, the `io =~ ~s(under
"handoffs")` assertion, and the `refute io =~ "AUTOFIX"` assertion are all
removed from this test. The test name and its slot in the `"ISS-0440 -- run/1
end-to-end via --dir, isolated tmp fixtures"` `describe` block are kept
unchanged.

### 1.1 Why (i) over (ii), and the codebase's own precedent for this choice

ISSUE-FIXER's diagnosis offered two equally-sound options: (i) rewrite to a
direct `resolve_dir/1` assertion, keeping the name/slot; or (ii) delete the
test entirely, leaving a superseded-by comment at F-DIR-DEFAULT and/or
T-DIR-SCOPED-SCAN.

Checked this file for a precedent on how it handles "this coverage turned out
to be redundant/misplaced" — found one directly on point.
T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS's own existing comment (lines 687-693,
quoted above) is itself an example of the *first* style: it already
explains, in place, why its own scope is narrower than it looks ("does not
re-verify the whole H1-H6/... corpus ... already covered by ... this same
file"), rather than being deleted once that narrowing was understood. The
file's convention throughout (see also the ISS-0440/ISS-0442 section banners
at lines 391-413, 701 area) is: **keep a name-addressable test slot per
acceptance-criterion/regression-hook, with an inline comment stating what it
does and does not still verify, rather than deleting slots and pointing
elsewhere.** This matters concretely here because
"T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS" is the literal test name a future
reader (or a `mix test --only` invocation, or a future incident report) would
grep for when reasoning about "is the zero-flag/@handoffs_dir-resolution
property tested" — deleting it removes a searchable anchor for a property
that is still, in substance, tested (now via F-DIR-DEFAULT). Rewriting in
place keeps that anchor and keeps the "why" local to the test itself, matching
how this file already documents its own coverage decisions elsewhere (e.g.
lines 398-408's mutant-table note, lines 475-482's carve-out note).

Also weighed: option (ii) would need the superseding comment placed at BOTH
F-DIR-DEFAULT and T-DIR-SCOPED-SCAN to fully replace what the single deleted
test's docstring conveyed (the "default resolves + banner threads it" pairing
is currently stated as one coherent claim in one place) — that's two edits
carrying one deleted test's intent versus one edit that keeps it local. (i) is
simpler to review and matches file convention. **Chosen: (i).**

## 2. Exact scope

**Only** `test/mix/tasks/letflow.lint_handoffs_test.exs` changes — the body of
one test, lines 694-697 (plus its added comment). No other test in the file
changes. No `lib/` change: `resolve_dir/1`
(`lib/mix/tasks/letflow.lint_handoffs.ex:354`) is already public and its
behavior is already correct and unchanged by this fix — this issue is a
test-only defect (a test asserting more than its own stated claim requires),
not an application-code defect.

## 3. Does anything still need to verify the real corpus is scannable?

**Yes, and it already does, at a better-scoped layer: `mix letflow.check`'s
CI invocation of the actual `mix letflow.lint_handoffs` task.**

Confirmed by direct reading (not assumed):

- `mix.exs` line 105 lists `"letflow.lint_handoffs"` inside the alias chain
  the `letflow.check` alias runs.
- `.github/workflows/ci.yml` lines 50-55 carry a comment explicitly stating
  `mix letflow.lint_handoffs` is "one of `letflow.check`'s own steps" and
  that the workflow's `fetch-depth: 0` exists *because* of what that task
  needs (`git merge-base --is-ancestor`, `git show` against full history).

This means: on every CI run, `mix letflow.lint_handoffs` (the real mix task,
zero-flag, scanning the real `handoffs/` directory) already runs as its own
gate step, independent of `mix test`. If the corpus has an un-grandfathered
violation, `letflow.check` fails there — with a failure that correctly
attributes to "the handoff corpus has a problem," not to a misleading
"ISS-0523's branch broke something" reading the way the removed test's
failure misattributed in the ISS-0445 incident. This is **strictly better**
coverage of "can the real corpus be scanned without raising" than the test
being removed: same underlying check, run at the layer whose job it actually
is (a repo-wide hygiene gate), instead of being smuggled into one unrelated
test file where a failure there could not be traced back to its real cause
without GIT_MERGE.md's "Failure Attribution Is Structural" rule (which is
exactly what saved the ISS-0445 incident, per its own writeup, but is a
safety net that shouldn't need to fire routinely).

So: removing T-DEFAULT-NO-FLAG-SCANS-REAL-CORPUS's real-corpus assertion
leaves **zero net coverage loss** at the CI-gate level, and removes the one
place a real-corpus assertion was living somewhere it didn't belong (a
per-branch unit-test file, coupling unrelated branches' `mix test` results to
global repo state) instead of where it already belongs (the repo-hygiene gate
step).

## 4. Test-ability

**No fail-then-pass proof needed for the new test body itself** — this is not
a bug fix to application code; it is the removal of an overreaching assertion
from a test. `LintHandoffs.resolve_dir([]) == "handoffs"` is not a new claim:
it is byte-for-byte the same assertion F-DIR-DEFAULT (line 419) already makes
and already passes today. There is no "old broken behavior" in `resolve_dir/1`
to prove was fixed, because nothing in `resolve_dir/1` changes. TEST-DESIGNER
does not need to demonstrate a red-to-green transition for the rewritten
assertion's own correctness — it is trivially true by inspection and by
F-DIR-DEFAULT's own passing status.

**What TEST-DESIGNER SHOULD positively verify** is the actual property this
issue is about: that the NEW test no longer couples to real-corpus state,
where the OLD one did. Concretely:

1. Confirm (by reading, or by a throwaway local run) that the rewritten test
   passes regardless of `handoffs/`'s current contents — e.g. temporarily
   writing a scratch file into `handoffs/` with a top-level `status` value
   that would trip an H1/H6 violation (mirroring ISS-0445's actual
   reproduction shape), running just this test, confirming it still passes,
   then removing the scratch file. This demonstrates the coupling is
   genuinely gone, not just reworded.
2. This should be a **manual/one-time verification step during this fix's own
   review** (documented in TEST-DESIGNER's or the implementing agent's
   handoff notes), not a new permanent test — a permanent test that
   deliberately corrupts `handoffs/` (even temporarily, even with cleanup)
   reintroduces exactly the "a test touches the real corpus" risk class this
   issue is removing, and duplicates what a mutation/fixture-based test
   already proves more safely: that `resolve_dir/1`'s zero-flag branch is
   pure and takes no directory-state-dependent path (confirmed by reading its
   body at `lib/mix/tasks/letflow.lint_handoffs.ex:354-360` — a `case` over
   `find_dir_flag/1`'s return, no filesystem access at all).
3. Full-suite regression: `mix test test/mix/tasks/letflow.lint_handoffs_test.exs`
   should still report the same total test count minus zero (no tests
   deleted under option (i)), all green, with the corpus in whatever state it
   happens to be in at review time — this is itself proof the coupling is
   gone, since a real corpus violation present at review time would no longer
   turn this file's suite red.

## 5. Open questions

None. This is a narrowly-scoped test-only fix; §3 already resolves what would
otherwise be the one open question (whether removing the real-corpus
assertion leaves a coverage gap) with a confirmed "no."
