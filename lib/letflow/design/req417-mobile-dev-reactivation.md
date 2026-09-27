# Design: REQ-417 — Reactivate MOBILE-DEV

## Scope classification

REQ-417 has **no affected `lib/letflow/` module**. It is a documentation/process
change only, per WF-02's Step 3 "no application-executable surface" category
(established precedent: a decision-record/docs-only requirement's Step 1 produces
a minimal design note confirming docs-only scope, Step 1b confirms it, and the run
skips 2a/2b/2c/2d/3b/4 straight to Step 5/RELEASE-VALIDATOR).

Files this requirement will touch (all edits performed by DOC-UPDATER at Step 6,
not by this design step):

1. `.claude/agents/mobile-dev.md`
2. `docs/agents/AGENT_SYSTEM.md`
3. `CLAUDE.md`
4. `docs/agents/instructions/core-directives.md`
5. `docs/agents/workflows/WF-02_requirement_implementation.md`
6. `docs/migration/stage-9-mobile.md`
7. `docs/mobile/architecture.md`
8. `docs/mobile/requirements.md`
9. `docs/mobile/README.md`

No `lib/`, `priv/`, `web/`, or `apps/` file is touched. No Ecto schema, no
gen_statem, no DB migration, no application module (0039 D8) is created or
modified.

## Acceptance-criteria mapping

| # | Acceptance criterion (abridged) | File/section that satisfies it | Concrete change |
|---|---|---|---|
| 1 | `git grep -n -i dormant` across the five listed files returns no live "dormant" claim (historical "was dormant" sentences OK) | `.claude/agents/mobile-dev.md` frontmatter + Status section; `docs/agents/AGENT_SYSTEM.md` roster/matrix/artifact rows; `CLAUDE.md` roster row; `docs/agents/instructions/core-directives.md` producer/validator table; `docs/migration/stage-9-mobile.md` line 3 and Roles section | Replace each "dormant"/"Dormant" occurrence with an active-status statement (e.g. mobile-dev.md frontmatter: "DORMANT..." → "ACTIVE — owns REQ-417..430"; AGENT_SYSTEM.md rows: drop "(dormant)"/"Dormant"; CLAUDE.md row: drop "Dormant"; core-directives.md: drop "dormant until S9"; stage-9-mobile.md line 3: "Status: not started" → "Status: in progress"). Any dated historical mention (e.g. "registered on 2026-08-21 as dormant") is rewritten to past tense ("was dormant") rather than deleted. |
| 2 | `git grep` for "something is probably wrong" and for `Creating .apps/mobile/. before` in mobile-dev.md both return no hits | `.claude/agents/mobile-dev.md` Status section and Forbidden list | Delete the sentence "If you have been dispatched, something is probably wrong ... stop and report blocked to ORCH" from the Status section; delete the Forbidden bullet "Creating apps/mobile/ before REQ-124, REQ-125, and REQ-126 are done". |
| 3 | mobile-dev.md's three-constraint section is byte-identical to pre-change text (`git diff origin/main -- .claude/agents/mobile-dev.md` shows no hunk inside it) | `.claude/agents/mobile-dev.md` — the three tier-constraint bullets (including constraint 2's D1a carve-out quoted by REQ-294 AC#2) | DOC-UPDATER edits only the Status section, the two Forbidden bullets named above, the frontmatter description, and the write-scope bullet; the constraints section itself is left untouched — verified by diffing that section specifically before commit. |
| 4 | AGENT_SYSTEM.md matrix row and mobile-dev.md both name `.github/workflows/ci.yml` (mobile job only) as a write location, and both state MOBILE-DEV owns `apps/mobile/test/` | `docs/agents/AGENT_SYSTEM.md` capability-matrix MOBILE-DEV row; `.claude/agents/mobile-dev.md` write-scope bullet | Widen both rows' write scope from "apps/mobile/" alone to "apps/mobile/, docs/mobile/, handoffs/, the mobile job only in .github/workflows/ci.yml, and docs/migration/stage-9-mobile.md (outside REVIEWER sign-off sections)". Add sentence: "MOBILE-DEV owns its own Dart tests under apps/mobile/test/, as FRONTEND-DEV owns web/'s; TEST-DESIGN-VALIDATOR and TEST-RUNNER still gate them." |
| 5 | WF-02 contains a MOBILE-DEV implementation step naming `flutter analyze`, `flutter test` (run from apps/mobile/), and the SECURITY-REVIEWER routing condition; mobile-dev.md's mandatory-reading bullet points at that step's actual heading | `docs/agents/workflows/WF-02_requirement_implementation.md` (new step, e.g. "Step 2b-mobile"); `.claude/agents/mobile-dev.md` mandatory-reading bullet (currently says "WF-02 ... Step 2b") | Insert a new step mirroring Step 2b's structure: verify branch; read design artefact + docs/mobile/; change apps/mobile/ only; run `flutter analyze` and `flutter test` from apps/mobile/, quoting real output; route to SECURITY-REVIEWER (2c) when the change touches auth, token storage, or transport (MOB-2, MOB-5, MOB-6). Mention it in the Overview diagram's routing line. Update mobile-dev.md's mandatory-reading bullet to cite the new step's heading verbatim. |
| 6 | WF-02 Step 2c names MOB-5 as the checklist for an in-scope apps/mobile/ diff; Step 3's scope test names the mobile step beside 2a/2b; Step 4 requires TEST-RUNNER to run `flutter analyze`/`flutter test` from apps/mobile/ when the diff touches apps/mobile/ | `docs/agents/workflows/WF-02_requirement_implementation.md` Steps 2c, 3, 4 | 2c: add that an apps/mobile/ diff touching auth/token storage/transport is in scope (security-reviewer.md's "anything resolving a ... token" clause), checklist = MOB-5's acceptance criteria in docs/mobile/requirements.md, applied alongside INV-4/INV-5. 3: scope test additionally names the mobile step's `artifacts_out`; states Dart tests under apps/mobile/test/ are written by MOBILE-DEV in the mobile step (still reviewed by TEST-DESIGN-VALIDATOR). 4: when diff touches apps/mobile/, TEST-RUNNER additionally runs `flutter analyze` and `flutter test` from apps/mobile/ and records real output in the test report. |
| 7 | stage-9-mobile.md line 3 no longer says "not started" / lists REQ-123; gap table marks each of the three rows closed with requirement id + date sourced from docs/status/ | `docs/migration/stage-9-mobile.md` line 3 and gap table (~line 42) | Line 3: "Status: not started. Depends on: S4. Requirements: REQ-123 ... REQ-126" → "Status: in progress. Depends on: S4. Requirements: REQ-124..127, REQ-282, REQ-289..294, REQ-385, REQ-417..430" (drop REQ-123, an S8 requirement). Gap table: annotate each of the three rows "closed by REQ-124/REQ-125/REQ-126" with the done date read from `docs/status/requirement_status.v*.yaml` (DOC-UPDATER must quote source file+line, not guess). Roles section: drop "dormant". Keep the 2026-08-21 verification text as dated history (not deleted). |
| 8 | docs/mobile/architecture.md §3 and requirements.md's MOB-2/MOB-3 gap paragraphs each carry a dated "closed by REQ-124/REQ-125/REQ-126" note; original 2026-08-21 text still present (git diff shows additions only) | `docs/mobile/architecture.md` §3; `docs/mobile/requirements.md` MOB-2 and MOB-3 "Letflow gap" paragraphs; `docs/mobile/README.md` Status section | Append (not replace) a dated closed-by note to each of the three locations, e.g. "Closed 2026-09-27 by REQ-124/REQ-125/REQ-126." The original 2026-08-21 dated verification text is preserved verbatim; README.md's "Nothing is built" sentence stays true and is explicitly NOT changed here (that's REQ-419's job). |
| 9 | `git diff --name-only origin/main...HEAD` lists only files under docs/, `.claude/agents/mobile-dev.md`, and CLAUDE.md — nothing under lib/, web/, apps/, or .github/ | Whole-requirement constraint | The 9-file list above is exhaustive and matches this constraint exactly: 6 files under docs/, 1 under .claude/agents/, 1 is CLAUDE.md itself. No .github/ file is touched by REQ-417 (the ci.yml mobile-job write-scope grant is documentation about a future write location, granted in deliverable b's text edit to mobile-dev.md/AGENT_SYSTEM.md — it does not itself edit ci.yml). |

## Open questions

None. REQ-417's description (deliverables a–g plus explicit OUT OF SCOPE list) is
fully prescriptive: exact sentences to delete, exact files and sections to edit,
and explicit exclusions (MOB-7 locale note is REQ-429's job; REQ-294's text is not
touched; README.md's "Nothing is built" sentence is not touched). No ambiguity
requiring a design decision was found.

## Statement per WF-02 Step 1 structural requirement

No implementation code in this design; no Ecto schema/gen_statem/DB changes; this
design exists to satisfy WF-02 Step 1's structural requirement for a docs-only
requirement, per established precedent.
