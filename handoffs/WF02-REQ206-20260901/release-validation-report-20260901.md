# RELEASE-VALIDATOR report — REQ-206 — WF02-REQ206-20260901

Date: 2026-09-01. Branch: `feature/WF02-REQ206-20260901` (commit `afb7cc8f` at hand-off,
verified clean/up-to-date with origin before this review). Verified independently from
source and real command output; no prior agent's verdict (step-02a ELIXIR-DEV, step-02c
SECURITY-REVIEWER, step-02d REVIEWER, step-03/03b TEST-DESIGNER/VALIDATOR, step-04
TEST-RUNNER) was trusted without re-derivation.

## Verdict: PASS — all 6 acceptance criteria genuinely met, with one non-blocking caveat

---

## Re-run tests myself (not copied from step-04's report)

```
$ mix compile --warnings-as-errors --force
Compiling 180 files (.ex)
Generated letflow app
```
Exit 0, 0 warnings — matches step-04's claim, re-derived independently.

```
$ mix test test/letflow/simulation/req206_swiftroute_test.exs
.
Finished in 8.1 seconds (0.00s async, 8.1s sync)
Result: 6 passed
```
6/6, real output — matches step-04's claim.

```
$ mix test test/letflow/simulation/runner_test.exs \
            test/letflow/simulation/runner_template_and_outcomes_test.exs \
            test/letflow/simulation/seed_idempotency_test.exs
Result: 15 passed
```
REQ-205's own pre-existing simulation coverage (15 tests, the harness foundation) still
passes unmodified after the Runner extension. Also ran
`test/fixtures/simulation/fixture_shape_test.exs` — passed.

`mix test test/letflow/simulation/` (all 4 files together) — `Result: 21 passed`
(6 + 15), confirming no cross-file interaction issue.

## Runner extension genuinely additive — confirmed by reading the diff

`git diff origin/main...HEAD -- test/support/simulation/runner.ex` reviewed line by
line: every change is either (a) a new struct field with a default reproducing today's
behavior (`unbuilt_feature: nil`, `disposition: :executed`, `severity: nil`,
`notes: nil`), (b) a widened type union (`:api | :gui` → `+ :skip`), (c) a new leading
`run/1` clause that short-circuits to an empty report when `unbuilt_feature` is set,
before any existing precondition/step/outcome logic runs, or (d) a new `:skip` branch
in the step-dispatch logic. No existing branch was deleted or altered in a way the 15
still-passing pre-existing tests would not have caught. This matches the design doc's
own additive-extension claim and step-02a's summary — independently re-confirmed, not
copied.

## Two UNIMPLEMENTED findings — independently re-verified with fresh greps

**Advance-timer endpoint** (AC3):
```
$ grep -rn "advance-timer\|advance_timer" lib/letflow/router.ex lib/letflow/routers/
(zero matches, exit 1)
```
Confirms `POST /api/v1/instances/:id/advance-timer` genuinely does not exist. The
finding in `step-02a-elixir-dev.json`'s `result.issues` (title: "POST
/api/v1/instances/:id/advance-timer does not exist", severity MINOR) is accurate, not
fabricated.

**Attachment/document API** (AC4):
```
$ grep -rln "attach\|document" lib/letflow/routers/*.ex
(10 files matched)
```
Manually inspected every match: all are either RFC 9457 "problem document" error-body
terminology, doc-comment usages of "documented", or `SolutionPack`'s unrelated "pack
document" / "attaches variable schemas to a pre-existing [definition]" language — zero
actual shipment-attachment or document-upload route/handler anywhere in
`lib/letflow/routers/`. Confirms the second finding in `step-02a`'s `result.issues` is
accurate.

Both findings are reported to ORCH via `result.issues` (not filed directly, per
core-directives.md's "No Issue Left Local-Only") with severity and affected files —
neither fabricated nor silently dropped.

## Scenario YAML disclosure headers — read all 4 files directly

Every file under `test/fixtures/simulation/swiftroute/scenarios/` opens with a
`# Synthetic --` header naming the specific unreachable R-Co source path and
cross-referencing the design doc's §0 explanation, e.g.:

```
# Synthetic — R-Co's tests/simulation/scenarios/swiftroute-shipment-attach-delivery-note.yaml is
# unreachable from this sandbox (see lib/letflow/design/req206-swiftroute-scenario-execution.md §0);
# structurally faithful to REQ-206's own requirement-text field-by-field account,
# not a byte-for-byte port.
```

This is the correct convention: contrast with `test/fixtures/simulation/swiftroute/
company.yaml`'s header (`# Ported from R-Co ... (ISS-0388)`), which correctly uses
"ported" wording because ISS-0388 already replaced that fixture set with real R-Co
content. The 4 scenario YAMLs correctly use "synthetic" wording because the
*scenario* corpus (a different R-Co file set) remains unreachable — no scenario file
silently presents invented content as real R-Co data.

## AC-to-evidence map (test name / file / command output only, not design-doc claims)

| AC | Evidence |
|----|----------|
| AC1 | `req206_swiftroute_test.exs:245-309` — real `Identity.get_onboarding_by_hostname/1`, `tenant.status == :active`, alice user+token creation against real Postgres; asserts all 5 `step_results` are `:deferred_to_s8` with `detail =~ "S8"`; asserts `report.disposition == :executed`; asserts `File.exists?/1` on the Playwright spec path to state spec-exists-but-not-integrated explicitly. Re-run: PASS. |
| AC2 | `req206_swiftroute_test.exs:314-378` — 5 real API steps via `Runner.run/1` against a real running-in-test instance, all `:ok`; 4 `outcome_results` present with concrete evidence (`assignee_ref`, instance status `COMPLETED`, variables, `audit_event`); EO-1 permitted `:pass` or `:fail` per a documented Engine limitation (role-attributed task `assignee_type == nil`) but always carries real observed evidence — satisfies AC2's literal wording ("recorded PASS or FAIL... with the specific evidence"), which does not require all 4 to be PASS. Re-run: PASS. |
| AC3 | `req206_swiftroute_test.exs:383-426` — step1 `:ok`, step2 `:skip`/severity `:minor`/detail contains `"advance-timer"`, step3 `:ok`; both `instance_state` outcomes `:pass`. Missing-endpoint finding grep-confirmed above and present in `step-02a-elixir-dev.json`'s `result.issues`. Re-run: PASS. |
| AC4 | `req206_swiftroute_test.exs:431-455` — `report.disposition == :unbuilt_feature`, all three result lists empty, `notes` cite `partition_attach.zig` and `iss501_storage_mode_routing.md` (specific R-Co paths checked) and `"No attachment/document-upload API"`. Finding grep-confirmed above and present in `result.issues`. Re-run: PASS. |
| AC5 | All 16 steps across 4 scenarios carry a closed disposition (5 `deferred_to_s8` + 5 `ok` + [`ok`,`skip`,`ok`] + 0-of-5 via `unbuilt_feature` short-circuit) — verified by reading all 4 test blocks; no step left unaddressed. Re-run: PASS. |
| AC6 | `mix compile --warnings-as-errors --force` and `mix test test/letflow/simulation/req206_swiftroute_test.exs` re-run directly by RELEASE-VALIDATOR (output quoted above, not copied from step-04). Re-run: PASS. |

## Caveat — R-Co scenario-corpus-porting follow-up not carried past the design stage

**This does NOT block marking REQ-206 done, but it is recorded so it is not lost.**

The design doc (`lib/letflow/design/req206-swiftroute-scenario-execution.md` §0) and
`step-01-code-designer-rework1.json`'s `recommendation_for_orch` field both explicitly
recommend ORCH file a follow-up issue at Step 6/Final — same shape as
`docs/issues/ISS-0388.yaml` (`discovered_by: RELEASE-VALIDATOR`, `tags:
[fixture-porting, needs-r-co-access, s7]`, `affected_files`: the 4 scenario YAMLs,
`related: [REQ-206]`) — so a future session/host with genuine R-Co filesystem access
can port the real `tests/simulation/scenarios/*.yaml` scenario content, exactly how
ISS-0388 already fixed REQ-205's company/org/process fixtures.

Grepped `step-02a`, `step-02c`, `step-02d`, `step-03`, `step-03b`, and `step-04` for
this recommendation: **zero mentions past step-01b.** It was not silently dropped
through negligence — REQ-205's own precedent
(`handoffs/WF02-REQ205-20260831/release-validation-report-20260831.md`) shows
RELEASE-VALIDATOR, not ELIXIR-DEV, is this pipeline's established vehicle for
surfacing this exact class of recommendation to ORCH at Step 6. This report re-states
it here so it reaches ORCH through the same mechanism, rather than depending on a
design-doc citation nobody downstream re-reads.

**Why this does not block REQ-206:** the requirement's mechanism (Runner extension),
its tests, and its disclosure are all genuinely correct and independently
re-verified above; only the literal byte-for-byte R-Co *scenario* content is
unavailable, and that unavailability is disclosed everywhere it appears (every
scenario file's header, the design doc, this report). This mirrors REQ-205's own
"ACCEPT WITH RECORDED CAVEAT" resolution for its AC1 gap.

**Downstream consequence if ORCH does not act on it:** REQ-207 and REQ-208 (Vortex and
Meridian scenario corpora) will hit the identical unreachable-R-Co-scenario-corpus
situation. Without a tracked issue, each requirement risks re-discovering and
re-justifying the same synthetic-content gap independently instead of it being
centrally tracked and resolved once a host with real R-Co access becomes available.

**Action requested of ORCH:** file the follow-up issue via `letflow-queue` at Step
6/Final per the design doc's own recommendation, and reference it from REQ-207/REQ-208
so they don't re-derive the same finding from scratch.

## What DOC-UPDATER should record

- REQ-206 status: `done`. Unlike REQ-205, all 6 ACs are fully met (no "partially met"
  AC — REQ-206's scenario content was disclosed as synthetic from the start per its
  own design, not discovered as a gap after the fact).
- The run-history event should reference this report and the pending
  ISS-0388-mirroring follow-up issue once ORCH files it, so a later reader of
  `requirement_status.yaml` sees the open follow-up without needing to open this file.
- Cross-reference this caveat from REQ-207/REQ-208's future implementation start so
  their ELIXIR-DEV sessions don't re-derive the same R-Co-scenario-corpus-unreachable
  finding independently.
