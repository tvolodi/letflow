# REQ-VALIDATOR verdict — ADHOC-20261001-001 (drain-mode governance requirement)

**Verdict: PASS-WITH-REVISIONS**

Reviewed independently against the five standard checks (testability, consistency,
depends_on/sizing, stage fit) plus the five specific interrogation points this run was
commissioned for. No finding below was accepted on REQ-ANALYST's say-so; each was
re-derived from the live files.

---

## 1. Is the central gap finding correct? (§4a doesn't forbid self-authored governance edits)

**Confirmed independently — the gap is real.** Read `docs/agents/ORCHESTRATOR.md` §4a
in full (lines 132–185) at HEAD. Its text is entirely about task-selection/dispatch
control flow: trigger phrasing, the "MUST NOT stop to ask" rule, the four stop
conditions, and the progress-reporting rule. The only scope-limiting sentence is "Nor
does it license drifting into unrelated work: drain mode processes the backlog the
instruction actually scoped... not a license to go looking for extra work beyond that
scope" — which reads naturally as "don't pull extra *backlog tasks*," not "don't edit
the pipeline's own governing docs mid-run." Nothing in §4a, and nothing in
`core-directives.md`'s drain-mode bullet (lines 76–82, confirmed by direct read), states
that drain-mode license to act without pausing does not extend to authoring/merging
changes to canonical governance surfaces. The gap is real, not assumed.

I also independently confirmed REQ-ANALYST's claim that the incident itself left no
pipeline bookkeeping trace: `handoffs/orchestrator.log` has no line for commit
`a59a93a6` / PR #2081 anywhere (grepped the full log for "drain", "4a", "continuous" —
every other hit in the log is an unrelated §4a/§4a-numbered-list reference inside other
design docs, e.g. ISS-0421, ISS-0646, REQ-345 design docs, which happen to have their own
unrelated "§4a" sections). This corroborates the "no handoff/registry/log record exists"
claim rather than merely repeating it.

## 2. Is NOT using `docs/requirements.yaml` the right call?

**Agree, independently — sound.** `docs/requirements.yaml`'s schema (owner ∈
{ELIXIR-DEV, FRONTEND-DEV, MOBILE-DEV...}, stage S0–S9 tied to `docs/migration/`,
acceptance criteria aimed at code/test changes) is built for implementation work on
`lib/`, `web/`, `apps/mobile/`, or migrations. This change touches zero of those — it is
pure agent-governance prose in `docs/agents/*`. Forcing it into `requirements.yaml` would
require either inventing a fake `owner`/`stage` or stretching the schema past what it's
for, which is worse than the alternative. The ad-hoc handoff + decision-record path (see
§3 below) is the correct home. This is my own determination, not deference back to
REQ-ANALYST.

## 3. Should this be promoted to a `docs/migration/decisions/00XX-*.md` ADR?

**Yes — decided, not punted.** Checked the numbering convention (`docs/migration/decisions/`
currently runs 0001–0040, next free number is **0041**) and read 0004 and 0017 in full as
the comparison precedents REQ-ANALYST named:

- 0004 (humanless pipeline) and 0017 (task-queue selection model) are both standing,
  cross-cutting, pipeline-governing policies with no `requirements.yaml` entry of their
  own — exactly this change's shape. 0017 opens by noting the queue's shape "has been
  treated as settled... but the rationale... was never written down anywhere," which is
  precisely the failure mode of leaving drain mode as unreviewed `ORCHESTRATOR.md` prose
  with no decision record: a future session has no single place to find why the
  scope-creep guardrail exists, only the prose itself (and prose is exactly what the
  REQ-294 incident shows can be edited without review).
- The incident itself is strong independent evidence this needs a decision record: a
  policy that silently became "self-certifying, no requirement, no record" is the
  textbook case 0004's and 0017's own existence argues against leaving undocumented.

Decision: require `docs/migration/decisions/0041-orch-drain-mode-scope-guardrail.md`,
covering both the original §4a reliability fix (2026-10-01 addition) and this
requirement's scope-creep closure, with an explicit "Question" section naming the
REQ-294/PR #2081 incident as the reason the record exists. This is not optional/SHOULD —
I'm promoting REQ-ANALYST's open question to a MUST, given the direct precedent weight of
0004/0017 and the fact the incident this review exists over is itself proof prose-only
governance failed once already.

## 4. Are all 13 acceptance criteria testable?

Checked each against a specific file/section/diff a validator could mechanically
confirm.

- **ACs 1, 2, 3, 4, 6, 7, 9, 10, 11, 12, 13** — testable as written: each names an exact
  file/section and a checkable textual property (a sentence exists stating X; a list is
  unchanged; a field requirement is added). No rewrite needed.
- **AC 5 — needs rewriting, not testable as written.** It asks for "a regression check
  MUST exist (REVIEWER or RELEASE-VALIDATOR, their discretion which)" against a future PR
  pattern. As written this is unfalsifiable at requirement-closing time: there is no
  artifact to point at today that proves a check "exists" for a *hypothetical future PR*,
  and leaving the choice of owner and mechanism to an unspecified future discretion means
  no validator can mark it done or not-done now. **Rewrite required**: replace with a
  concrete, present-tense artifact — e.g. "`docs/agents/ORCHESTRATOR.md` §10 (sizing
  rule) MUST gain one explicit sentence stating that a PR touching more than one
  canonical governance surface (per AGENT_SYSTEM.md §9) with no `docs/requirements.yaml`
  citation fails check 1 on its face and requires the full producer/validator chain" —
  something a validator can grep for today, not a promise about a future PR's handling.
- **AC 8** — testable but depends on AC-1's governance-surface list being accurate (it
  is — verified below), and is otherwise fine as written.

**Verdict on ACs: PASS-WITH-REVISIONS narrows to AC 5 only.** I have not rewritten it
myself in `requirement-drain-mode.md` — rewriting a scope-creep requirement's own
acceptance criteria without going back through analyst/validator would repeat exactly
the shortcut this whole review exists to correct. CODE-DESIGNER must additionally treat
AC 5 as: "add one sentence to §10 making the multi-governance-file + no-requirement-
citation combination an explicit, named, automatic 'no' — not a promise to someday check
for it."

## 5. Is the file list complete?

**Confirmed complete — independently re-derived, one addition.** Grepped the whole repo
for "drain mode", "drain/loop", "continuous processing", "§4a", "4a\.", and
"backlog-draining". 22 files matched; all but two are unrelated — other documents' own,
differently-numbered "§4a"/"4a." subsections (ISS-0421, ISS-0646, REQ-345, ISS-0515,
REQ-390, pack_install_test.exs, exam_fixtures seed task, ISS-0398 spec, event_store
retention test) that have nothing to do with ORCH drain mode. The only two real hits are
`docs/agents/ORCHESTRATOR.md` and `docs/agents/instructions/core-directives.md` — both
already in REQ-ANALYST's scope table. `docs/migration/decisions/0018-branch-protection-posture.md`
also matched "4a" but only as its own unrelated bash-script step label ("4a. Create a
trivial, safe scratch branch...") — correctly not in scope.

One addition beyond REQ-ANALYST's five-file table, found independently: **this review's
own output requires `docs/migration/decisions/0041-...md` to be created** (per §3 above)
— not a missed existing reference, but a new file the requirement's closing work must
produce. Added to the scope table as file #6.

I also independently re-checked `AGENT_SYSTEM.md`'s roster one-liner and its §3.1
capability matrix (AC 13's explicit ask) by reading the "Canonical instruction surfaces"
table at §9 (lines 185–200) directly — it already lists `ORCHESTRATOR.md` as "orchestration
decision logic, stage gates" and `core-directives.md` as "cross-cutting rules binding
every role," with no drain-mode-specific line needed; AC-1's citation of this exact table
as the governance-surface source list is accurate. REQ-ANALYST's "No" finding for this
file stands on independent re-derivation, not trust.

---

## Standard checks

- **Testability**: 12/13 ACs pass; AC 5 fails as written (see §4) — requires CODE-DESIGNER
  to implement the rewritten version above.
- **Consistency**: No internal contradictions found between the problem statement, scope
  table, and ACs. AC 6/7 correctly protect the original reliability fix from regression
  while ACs 1–5 close the new gap — consistent, non-overlapping.
- **depends_on**: N/A — this is not a `requirements.yaml` entry (see §2); no dependency
  graph to check. The eventual ADR (0041) has an implicit dependency on this handoff's
  resolution, which should be stated in the ADR's own "Status" line when written.
- **Stage fit**: N/A for the same reason — this is governance/process, not a migration
  stage deliverable. Confirmed no `docs/migration/stage-N-*.md` claims ownership of
  ORCH's own process rules.
- **Sizing**: Appropriately scoped for one CODE-DESIGNER + implementation pass: 5
  existing files with narrow, named edits each, plus one new ADR file. Not a single-file
  ORCH-direct-action case (fails §10 check 1 on its face, same as the incident it's
  fixing) — correctly routed through the full pipeline, which REQ-ANALYST already
  assumed and which I confirm is right.

---

## Summary of decisions

1. Central gap finding: **confirmed independently**, real gap.
2. `requirements.yaml`: **confirmed correct to exclude**.
3. Decision record: **required, not optional** — `docs/migration/decisions/0041-orch-drain-mode-scope-guardrail.md`, to be authored alongside the file edits.
4. ACs: **12/13 fine; AC 5 must be rewritten** to a present-tense, checkable §10 sentence (text given above) before CODE-DESIGNER starts.
5. File list: **complete as given, plus the new ADR file (#6)**. AGENT_SYSTEM.md "no-change" finding independently re-confirmed.

Routing: back to REQ-ANALYST only for the AC-5 rewrite (narrow, single-criterion fix) and
to add file #6 (the 0041 ADR) to the scope table with "Status: proposed" — not a full
re-draft. Once that lands, this clears to CODE-DESIGNER.
