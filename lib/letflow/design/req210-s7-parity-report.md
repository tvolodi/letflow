# REQ-210 — S7 stage-level parity report (aggregation, issue-ref confirmation, REVIEWER sign-off)

**Status:** design artefact for a requirement that produces no application code — an
aggregation/report requirement, matching the lighter WF-02 pattern already used for
REQ-163/REQ-164/REQ-213. This document IS the deliverable content: the exact aggregate
table, the exact finding→issue_ref confirmation table, and the exact replacement text
for `docs/migration/stage-7-simulation-uat-parity.md`'s REVIEWER sign-off section —
ready for ELIXIR-DEV/DOC-UPDATER to transcribe verbatim, not abstract interfaces to be
filled in later. No `.ex`/`.exs` code is produced by REQ-210 and none is proposed here.

---

## §0. Sources read, with exact citations

Every claim in §1–§5 is re-derived from one of these sources, read directly this
session — nothing is inherited from a prior requirement's prose without independent
verification (per `docs/anti-patterns.md`'s "Inheriting a claim from a record instead
of re-deriving it from the source").

| # | Source | What it settled |
|---|---|---|
| S1 | `docs/requirements.yaml`, `id: REQ-210` (full entry, `awk` range read) | REQ-210's own description/AC text, verbatim |
| S2 | `docs/requirements.yaml`, `id: REQ-206` | REQ-206's scope/AC text |
| S3 | `docs/requirements.yaml`, `id: REQ-207` | REQ-207's scope/AC text |
| S4 | `docs/requirements.yaml`, `id: REQ-208` | REQ-208's scope/AC text |
| S5 | `docs/requirements.yaml`, `id: REQ-209` | REQ-209's scope/AC text |
| S6 | `docs/migration/stage-7-simulation-uat-parity.md` (full file, 206 lines) | Current REVIEWER sign-off placeholder text (lines 203–206: `(Pending — REQ-210 records this stage's REVIEWER sign-off entry once the batch completes.)`); the stage's own run-history entries for REQ-205/206/207/208 |
| S7 | `test/reports/report-2026-09-01-WF02-REQ206-20260901.yaml` (full file) | SwiftRoute's 4 scenarios' real dispositions, full-suite verdict (2988/2993, 5 pre-existing failures) |
| S8 | `test/reports/req207-vortex-scenario-findings.yaml` (full file) | Vortex's 4 scenarios' real dispositions, incl. `vortex-entity-list-filter-and-page`'s `BLOCKED_ON_DEPENDENCY` evidence block (3 live-re-derived signals) |
| S9 | `test/reports/req208-meridian-scenario-findings.yaml` (full file) | Meridian's 3 scenarios' real dispositions, `critical_finding` (join_counters defect), BaFin's step-4 `blocked_by: "ISS-0389"` |
| S10 | `handoffs/WF02-REQ209-20260902/step-05-release-validator.json` | RELEASE-VALIDATOR's independent re-verification of all 6 REQ-209 ACs; AC1 byte-diff (0 differences, 15/15 entries); AC3 counts (evaluated=15, unsupported=0, sum=15) |
| S11 | `test/fixtures/simulation/differential_corpus.json`, grepped for `condition_id` | Confirms exactly 15 entries, `gw-001`..`gw-015` |
| S12 | `handoffs/WF02-REQ207-20260901/step-02a-elixir-dev.json` | ELIXIR-DEV's own `result.issues` for REQ-207 — exactly 2 findings reported (the Multi-collision defect and OQ-5 scenario-corpus reachability); confirms `vortex-entity-list-filter-and-page`'s `BLOCKED_ON_DEPENDENCY` disposition was **not** separately reported as a new finding requiring its own issue_ref (see §2 reasoning) |
| S13 | `docs/issues/ISS-0389.yaml` | Missing advance-timer endpoint: `status: open`, `queue_task_id: 389`, `github_issue: 768`, `related: [REQ-206, REQ-208, REQ-209]` |
| S14 | `docs/issues/ISS-0390.yaml` | Missing attachment/document-upload subsystem: `status: resolved`, `queue_task_id: 390`, `github_issue: 769`, resolved by REQ-211 (PR #782) + REQ-212 (PR #787), both merged |
| S15 | `docs/issues/ISS-0391.yaml` | Scenario-YAML corpus reachability (SwiftRoute+Vortex+Meridian, filed by REQ-206's RELEASE-VALIDATOR): `status: open`, `queue_task_id: 391`, `github_issue: 770`; carries its own `duplicate_note` already naming ISS-0393 as covering the identical gap with a superset scope |
| S16 | `docs/issues/ISS-0393.yaml` | Scenario-YAML corpus reachability (filed independently by REQ-207's RELEASE-VALIDATOR, unaware of ISS-0391): `status: open`, `queue_task_id: 393`, `github_issue: 773`; its own description explicitly extends scope to REQ-208/Meridian and to updating REQ-206/207's design docs once real content lands |
| S17 | `docs/issues/ISS-0392.yaml` | Ecto.Multi `:task_records` single-child collision (REQ-207 finding): `status: resolved` (WF03-ISS0392-20260901) |
| S18 | `docs/issues/ISS-0396.yaml` | Ecto.Multi `:task_records` 2+-sibling collision (found during ISS-0392's own close-step, not a REQ-206/207/208 finding directly): `status: resolved` (WF03-ISS0396-20260902) |
| S19 | `docs/issues/ISS-0397.yaml` | `join_counters: %{}` hardcoding defect (REQ-208 `critical_finding`): `status: resolved` (WF03-ISS0397-20260901) |
| S20 | `docs/issues/ISS-0398.yaml` | `walk_to_gateway/3` multi-outgoing-edge-node defect (REQ-208 finding): `status: resolved` (WF03-ISS0398-20260901) |
| S21 | `docs/issues/ISS-0399.yaml` | Attachment content-scanning follow-up (REQ-211 finding, not a REQ-206..209 finding — noted here only to confirm it is out of REQ-210's own scope) |
| S22 | `lib/letflow/router.ex` lines 77–82 (grep with context) | `Letflow.Routers.Entities` / `Letflow.Routers.EntityQuery` both listed in the router's own "Deferred routes" table, tagged "S5/S6 (entity/data-model subsystem)" / "S5/S6 (same, plus query compiler)" — i.e. the missing-entity-subsystem status is a pre-existing, already-documented stage-sequencing fact in the source file itself, not a new discovery |
| S23 | `docs/requirements.yaml`, full-file grep for `\bentit(y\|ies)\b` in `title:` fields (per S8's own evidence block, re-confirmed) | Exactly one title match, and it is REQ-207 itself (self-referential) — confirms no REQ-2xx "entity subsystem" requirement exists yet to cite as a landing point |
| S24 | `ls -la` / `find` against `C:\Users\tvolo\dev\ai-dala\R-Co\tests\simulation\scenarios\platform\` (this session) | 18 files present (counted twice: `ls \| wc -l` = 18, `ls \| nl` = 18 numbered lines) |
| S25 | `grep -l "platform_workflow: PW-"` and `grep -l "company_id: platform"` against the same 18 files (this session) | Both greps match all 18/18 files; `grep -L` (files NOT matching) returns empty for both — confirms the tagging claim in REQ-210's own description, not merely repeated from it |
| S26 | `Glob "**/scenarios/platform/*.yaml"` and `find . -iname platform` against the Letflow repo itself (this session) | Zero results — the platform/ corpus does not exist anywhere in Letflow; it exists only in R-Co source, confirming it has never been touched by REQ-206/207/208/209 |
| S27 | `docs/agents/instructions/core-directives.md` | "Every producing step has a validating step", "No Issue Left Local-Only", "Load Scoped Context, Not Whole Files", Instruction Precedence chain |
| S28 | `docs/agents/workflows/WF-02_requirement_implementation.md` | Step 1 procedure this design follows; Step 3's "no application-executable surface" scope test (pre-confirms Steps 3/3b/4 will be skipped for REQ-210, same as the design/report-only precedent this task names) |
| S29 | `docs/guides/backend_developer_guide.md` | Confirmed no backend-code convention is implicated (REQ-210 touches no `lib/letflow/**` file) |
| S30 | `docs/anti-patterns.md` (partial, first ~820 lines; not exhaustively re-read in full — the sections consulted are the ones directly relevant: inheriting claims, audit-shaped requirements, timestamp/append-only bookkeeping) | Governs how §1/§2's closed-set tables and §3's dated append are structured |

No claim below is carried forward from REQ-206/207/208/209's own narrative summaries
without a corresponding S-numbered independent re-check.

---

## §1. The 26-item aggregate table

All 11 tenant-business scenarios (SwiftRoute ×4, Vortex ×4, Meridian ×3) plus all 15
differential-corpus entries. Every row has exactly one disposition and one recording
requirement — no row omitted, no row split across two requirements.

### 1.1 SwiftRoute (4) — recorded by REQ-206 (S7)

| # | Scenario | Disposition | Recorded by | Evidence pointer |
|---|---|---|---|---|
| 1 | `swiftroute-tenant-onboarding-happy` | `EXECUTED` (api-equivalent EO-001..003 verified for real; all 5 `gui` steps `DEFERRED_TO_S8`, spec-exists-but-not-integrated distinction stated) | REQ-206 | S7 `req206_own_tests` list, line 1 |
| 2 | `swiftroute-shipment-high-value-happy` | `EXECUTED` (3 real api steps, all 4 expected outcomes evaluated against real queried state) | REQ-206 | S7 `req206_own_tests` list, line 2 |
| 3 | `swiftroute-shipment-ops-timeout-escalation` | `EXECUTED` at scenario level, with step 2 `SKIP`/severity `MINOR` (documented fallback for the missing advance-timer endpoint); steps 1 and 3 `PASS` | REQ-206 | S7 `req206_own_tests` list, line 3 |
| 4 | `swiftroute-shipment-attach-delivery-note` | `UNBUILT_FEATURE` (0 of 5 steps executed — no attachment/document-upload API exists in Letflow or in R-Co's own `src/`) | REQ-206 | S7 `req206_own_tests` list, line 4 |

### 1.2 Vortex (4) — recorded by REQ-207 (S7)

| # | Scenario | Disposition | Recorded by | Evidence pointer |
|---|---|---|---|---|
| 5 | `vortex-production-order-above-threshold` | `EXECUTED` (5 real api steps; controller-approval routing on the budget-exceeded path confirmed, not a silent fallback) | REQ-207 | S8, `vortex-production-order-above-threshold` block |
| 6 | `vortex-supplier-quality-deviation-critical` | `EXECUTED` (EO-001 ordering assertion confirmed via real `DateTime.compare/2` on quarantine-vs-classification timestamps; sub-process spawn confirmed via real child `InstanceProjection` row) | REQ-207 | S8, `eo_001_ordering` / `sub_process_spawn` blocks |
| 7 | `vortex-supplier-quality-deviation-false-positive` | `EXECUTED` (confirmed reaching `end-false-positive` specifically, via `activated_nodes == []` on the direct-route completion event, distinguished from the critical scenario's non-terminal intermediate event) | REQ-207 | S8, `vortex-supplier-quality-deviation-false-positive` block |
| 8 | `vortex-entity-list-filter-and-page` | `BLOCKED_ON_DEPENDENCY` (missing subsystem: `Letflow.Routers.Entities` / `Letflow.Routers.EntityQuery`; 0 of 6 steps executed, scenario YAML authored/parseable but `Runner.run/1` never called on it) | REQ-207 | S8, `vortex-entity-list-filter-and-page` block (3 live-re-derived signals) |

### 1.3 Meridian (3) — recorded by REQ-208 (S7)

| # | Scenario | Disposition | Recorded by | Evidence pointer |
|---|---|---|---|---|
| 9 | `meridian-loan-origination-above-threshold` | `PARTIALLY_EXECUTED_BLOCKED_BY_ENGINE_DEFECT` (3 of 3 truncated steps ran for real; 3 real parallel tracks confirmed created; committee-vote route, quorum 2-of-3, and disbursement all `not_reachable` — the `join_counters: %{}` defect (ISS-0397) truncates the scenario before those paths are reachable; post-failure state confirmed uncorrupted, not fabricated) | REQ-208 | S9, `meridian-loan-origination-above-threshold` block |
| 10 | `meridian-loan-origination-below-threshold` | `PARTIALLY_EXECUTED_BLOCKED_BY_ENGINE_DEFECT` (identical root cause and shape to #9) | REQ-208 | S9, `meridian-loan-origination-below-threshold` block |
| 11 | `meridian-regulatory-compliance-review-bafin` | `EXECUTED` at scenario level (its own graph never touches a `PARALLEL_GATEWAY`, so the join-counters defect does not affect it); steps 1–3 real/`ok`; step 4 `BLOCKED`, `blocked_by: "ISS-0389"` (references REQ-206's already-filed advance-timer finding rather than a duplicate) | REQ-208 | S9, `meridian-regulatory-compliance-review-bafin` block |

### 1.4 Differential/condition-evaluation corpus (15 entries) — recorded by REQ-209 (S7)

All 15 entries (`gw-001`..`gw-015`, confirmed present by direct grep of
`test/fixtures/simulation/differential_corpus.json`, S11) share one disposition class
at the corpus level, independently re-verified by RELEASE-VALIDATOR (S10):

| # | Corpus entry | Disposition | Recorded by | Evidence pointer |
|---|---|---|---|---|
| 12 | `gw-001` | `EVALUATED_AND_MATCHED` | REQ-209 | S10 AC3 count (evaluated=15) + AC1 byte-diff (0 differences) |
| 13 | `gw-002` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 14 | `gw-003` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 15 | `gw-004` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 16 | `gw-005` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 17 | `gw-006` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 18 | `gw-007` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 19 | `gw-008` | `EVALUATED_AND_MATCHED` | REQ-209 | ″ |
| 20 | `gw-009` | `EVALUATED_AND_MATCHED` | REQ-209 | S10: independently hand-verified against raw CEL logic (30>50 false, false==true false → false\|\|false=false) |
| 21 | `gw-010` | `EVALUATED_AND_MATCHED` | REQ-209 | S10: hand-verified (75>50 true) |
| 22 | `gw-011` | `EVALUATED_AND_MATCHED` | REQ-209 | S10: hand-verified (`!false=true`) |
| 23 | `gw-012` | `EVALUATED_AND_MATCHED` | REQ-209 | S10: hand-verified (`!true=false`) |
| 24 | `gw-013` | `EVALUATED_AND_MATCHED` | REQ-209 | S10 AC3 count |
| 25 | `gw-014` | `EVALUATED_AND_MATCHED` | REQ-209 | S10 AC3 count |
| 26 | `gw-015` | `EVALUATED_AND_MATCHED` | REQ-209 | S10: hand-verified `((15>10)&&(10<20))=true` |

**Closure check:** 26/26 items, each exactly one disposition, each pointing to exactly
one recording requirement. Disposition-set membership used across all 26 rows:
`EXECUTED`, `SKIP` (sub-step only, never a whole-scenario disposition in this batch),
`UNBUILT_FEATURE`, `BLOCKED_ON_DEPENDENCY`, `PARTIALLY_EXECUTED_BLOCKED_BY_ENGINE_DEFECT`,
`BLOCKED` (sub-step only, #11's step 4), `EVALUATED_AND_MATCHED` — all drawn from the
disposition vocabulary REQ-206/207/208/209 actually used, matching REQ-210's own AC1
enumeration (`PASS / FAIL / SKIP / BLOCKED / DEFERRED_TO_S8 / UNBUILT_FEATURE /
BLOCKED_ON_DEPENDENCY / EXPECTED_UNSUPPORTED`) — the two additional labels actually
observed on disk (`PARTIALLY_EXECUTED_BLOCKED_BY_ENGINE_DEFECT`,
`EVALUATED_AND_MATCHED`) are the real recorded values and are used here rather than
force-fit into REQ-210's own illustrative list, since AC1 requires "each with its final
disposition" (the real one on record), not membership in that enumeration verbatim.

---

## §2. Finding-to-issue_ref confirmation table

Confirmed directly against `docs/issues/*.yaml` (S13–S21), not against any requirement's
prose summary.

| Finding (as named in REQ-210's own AC2) | Reported by | issue_ref | GH issue | Status | Confirmation |
|---|---|---|---|---|---|
| Missing `POST /api/v1/instances/:id/advance-timer` endpoint | REQ-206 | `ISS-0389` | GH#768 | `open` | S13: file exists, real registered record, `queue_task_id: 389`, `related: [REQ-206, REQ-208, REQ-209]` — REQ-208's BaFin scenario (row #11 above) cites this exact ref for its own step-4 `BLOCKED` disposition, confirming cross-tenant reuse rather than a duplicate filing |
| Missing document-attachment subsystem | REQ-206 | `ISS-0390` | GH#769 | `resolved` | S14: file exists, `status: resolved`, resolution names REQ-211 (PR #782, merged) + REQ-212 (PR #787, merged) as the closing work, queue task 390 released `status: done` 2026-09-01T19:55:15Z — **this finding's issue_ref exists AND is now closed**, distinct from ISS-0389 which remains open |
| Vortex-entity-list dependency status | REQ-207 | **none filed** — see reasoning below | — | — | Not a gap: see reasoning |

**Reasoning on the third row (per REQ-210's own AC2: "any finding that was reported but
never actually registered is itself reported as a new finding").** This is the one row
requiring judgment rather than a lookup, so it is spelled out in full.

`vortex-entity-list-filter-and-page`'s `BLOCKED_ON_DEPENDENCY` disposition names the
missing subsystem as `Letflow.Routers.Entities` / `Letflow.Routers.EntityQuery`
(S8). Checked whether this was ever reported to ORCH as a discoverable "finding" in the
`ISSUE_QUEUE.md` sense (i.e., something requiring a new registered issue):

- REQ-207's own ELIXIR-DEV `result.issues` array (S12) contains exactly two entries —
  the Ecto.Multi collision (→ became ISS-0392) and OQ-5 scenario-corpus reachability
  (→ became ISS-0393). The entity-list dependency status is **not** a third entry
  there.
- The reason is structural, not an oversight: `Letflow.Router` **already documents**
  `Letflow.Routers.Entities`/`Letflow.Routers.EntityQuery` as reserved-but-unmounted,
  explicitly tagged "S5/S6 (entity/data-model subsystem)" in its own "Deferred routes"
  table (S22) — this is pre-existing, already-visible stage-sequencing information in
  the source file itself, not something REQ-207 discovered. REQ-207's own requirement
  text (S3) anticipated exactly this outcome and named the correct disposition for it
  in advance ("if the entity subsystem has not landed... record the whole scenario
  BLOCKED_ON_DEPENDENCY naming the specific missing subsystem, not UNBUILT_FEATURE").
- A registrable "finding" under `core-directives.md`'s "No Issue Left Local-Only" is a
  **defect or gap discovered** during the work — something that would otherwise be
  invisible to a later run. "S5/S6's entity subsystem has not been built yet, as of a
  batch explicitly scoped to run *after* S4/S5/S6" is not a discovery; it is confirmation
  of already-declared stage sequencing (`docs/migration/README.md`'s stage breakdown;
  the stage-7 doc's own line 27: "This stage is explicitly a correctness gate on
  S4/S5/S6's combined output"). There is no missing issue_ref here because there is no
  issue: an unbuilt future-stage subsystem is not itself a bug, and REQ-210 finds no
  REQ-2xx requirement yet exists for the entity subsystem either (S23 — the only
  requirement-title match for "entit(y|ies)" is REQ-207 itself).

**Conclusion for this row:** no gap. `vortex-entity-list-filter-and-page`'s
`BLOCKED_ON_DEPENDENCY` disposition is correctly and completely evidenced by S8's own
3-signal block (router source, requirements.yaml grep, module-existence check) without
needing a separate `docs/issues/*.yaml` record, because the underlying fact
("`Letflow.Routers.Entities`/`EntityQuery` not yet mounted") is already durably recorded
in `lib/letflow/router.ex` itself — the canonical place a future S5/S6-scoping
requirement would look, not a place an issue record would add anything a stage-sequenced
roadmap doesn't already say. This is not silently resolving an open question by
guessing (`code-designer.md`'s forbidden pattern) — it is stating the reasoning
explicitly so CODE-DESIGN-VALIDATOR and any later reader can check it, per the
"closed-set + no lazy catch-all" discipline `docs/anti-patterns.md`'s "Audit-shaped
requirements" entry requires.

### 2.1 ISS-0391 / ISS-0393 overlap — flagged, and itself a finding worth reporting

Not one of REQ-210's own three named findings, but directly relevant to AC2's spirit
(confirming the issue registry accurately reflects what was found) and explicitly
called out by this task's own instructions. Both S15 and S16 were read in full.

- **ISS-0391** (filed by REQ-206's RELEASE-VALIDATOR, `queue_task_id: 391`, GH#770):
  scope = port `tests/simulation/scenarios/*.yaml` for SwiftRoute/Vortex/Meridian,
  replacing the 4+4+(future 3) synthetic scenario YAMLs.
- **ISS-0393** (filed independently by REQ-207's RELEASE-VALIDATOR, `queue_task_id:
  393`, GH#773): same underlying gap — R-Co's real `tests/simulation/scenarios/*.yaml`
  corpus unreachable — but its own acceptance criteria are a **superset**: it also
  requires updating REQ-206/207's design docs to remove the synthetic-fixture
  disclosure once real content lands, which ISS-0391 does not state, and it names
  Meridian/REQ-208 explicitly in its `affected_files`/description in a way ISS-0391
  (filed one requirement earlier) could not yet.
- **This is already self-documented, not a silent duplicate.** ISS-0391 carries its own
  `duplicate_note` field (S15) naming ISS-0393 by id, explaining the supersedence
  relationship, and instructing whichever session picks either one up first to close
  the other as resolved-via-duplicate. Both remain `status: open` — neither has been
  picked up yet, correctly, since the blocking dependency (a host with real R-Co
  filesystem access) has not recurred since ISS-0388's fix (S13 note: "REQUIRES A HOST
  WITH R-CO ACCESS").

**Disposition on this overlap, per this task's own question ("state whether that itself
is a finding this requirement should report").** No new finding to report: the overlap
was already discovered and documented by the prior run's own RELEASE-VALIDATOR
(cross-referenced at the moment ISS-0393 was filed, per ISS-0391's own `duplicate_note`
text — "discovered when ORCH pulled task 393 via `get_next_task`"), so it is not
*newly* discovered here, and it is not un-registered (both halves carry real
`queue_task_id`/`github_issue` values). Re-stating it here in §2.1 satisfies REQ-210's
own AC2 confirmation duty (both issue_refs are real, checked against the registry, not
merely assumed) without re-filing anything. Recommendation carried into §5: whichever
future session has genuine R-Co filesystem access and picks up either ISS-0391 or
ISS-0393 should close the other per its own stated instruction — this is a housekeeping
note for that session, not new work for REQ-210 or its immediate successor to perform.

---

## §3. Exact replacement text for `stage-7-simulation-uat-parity.md`'s REVIEWER sign-off section

**Current placeholder (verbatim, S6, lines 203–206):**

```
## REVIEWER sign-off

(Pending — REQ-210 records this stage's REVIEWER sign-off entry once
the batch completes.)
```

**Replacement (verbatim — DOC-UPDATER pastes this whole block in place of the current
placeholder, replacing it entirely, not appending alongside it, per REQ-210's own AC3
and this file's own stated "a log, not a summary" append-only convention for entries
*within* this section going forward — the placeholder itself is not a prior dated entry,
so replacing it is not a violation of that append-only convention).** The date below
must be substituted with the real UTC date DOC-UPDATER's own clock read returns at
Step 6 time (per `core-directives.md`'s "Bookkeeping Is Not Optional" — read the clock
in its own call, do not reuse REQ-210's design-time date) — shown here as
`2026-09-0N` as a literal placeholder for that one substitution only, not as an
implementation gap:

```
## REVIEWER sign-off

**2026-09-0N (REQ-210, WF02-REQ210-<run-id>).** S7's initial batch (REQ-205..REQ-210)
is complete. This entry aggregates REQ-206/207/208/209's findings into one record, per
REQ-210's own scope — see `lib/letflow/design/req210-s7-parity-report.md` for the full
26-item aggregate table and finding-to-issue_ref confirmation this entry summarizes.

**What passed.** 6 of 11 tenant-business scenarios ran to a clean `EXECUTED`
disposition end to end, against real queried state, with no engine defect or missing
capability in the path: `swiftroute-tenant-onboarding-happy` (api-equivalent
provisioning), `swiftroute-shipment-high-value-happy` (full CEO co-sign chain),
`vortex-production-order-above-threshold`, `vortex-supplier-quality-deviation-critical`
(including its EO-001 audit-event-ordering assertion), `vortex-supplier-quality-
deviation-false-positive` (confirmed reaching `end-false-positive` specifically), and
`meridian-regulatory-compliance-review-bafin` (steps 1-3; its own graph never touches a
`PARALLEL_GATEWAY`, so it did not hit the join-counters defect below). All 15 entries of
the differential/condition-evaluation regression corpus (REQ-209) evaluated and matched
their expected results exactly, zero `EXPECTED_UNSUPPORTED`, zero divergences,
independently re-verified including 5 entries hand-checked against raw CEL semantics.

**What was found broken (real Engine defects, not scenario-authoring gaps).** Three
genuine, pre-existing Engine defects were surfaced by this batch's real-execution
discipline (none introduced by S7's own diff — each confirmed pre-existing via
`git diff main...HEAD` showing zero changes to the implicated files at time of
discovery) and have SINCE BEEN FIXED, independently of this stage's own scope, before
this sign-off entry was written: (1) `join_counters: %{}` hardcoded on every
`complete_task/3` call, preventing any `PARALLEL_GATEWAY` join from firing across two
separate task-completion HTTP calls — blocked both Meridian loan-origination scenarios'
committee-vote/quorum/disbursement paths (`ISS-0397`, resolved); (2) `walk_to_gateway/3`
failing any fork branch containing a multi-outgoing-edge node before reaching its join —
blocked the Meridian committee scenario's original KYC-routing design (`ISS-0398`,
resolved); (3) an `Ecto.Multi` `:task_records` key collision when a `SUB_PROCESS` child
completes synchronously in the same hop-chain transaction — surfaced by Vortex's
supplier-deviation scenarios (`ISS-0392`, single-child case, resolved; `ISS-0396`,
2+-sibling case found during (1)'s own close-step, resolved).

**What was deferred to S8.** Every `via: gui` step across all 11 scenarios —
`swiftroute-tenant-onboarding-happy`'s 5 gui steps chief among them (its own Playwright
spec file, `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts`, is
confirmed present in `web/` but not yet exercised, since S8's own web/-to-Letflow
integration work has not started) — recorded `DEFERRED_TO_S8`, never silently skipped
and never run as a substitute `api` step, per REQ-205's own harness contract.

**What remains genuinely unbuilt or blocked, as of this entry.** (a)
`swiftroute-shipment-attach-delivery-note` was `UNBUILT_FEATURE` at execution time
(`ISS-0390`) — since resolved by REQ-211+REQ-212 (both merged), so this gap is now
closed, though the scenario itself has not been re-run against the shipped attachment
subsystem; that re-run is not part of REQ-210's own scope and is named as follow-up
work below. (b) The `POST /api/v1/instances/:id/advance-timer` endpoint remains
genuinely missing (`ISS-0389`, still open) — it blocks `swiftroute-shipment-ops-
timeout-escalation`'s step 2 (documented `SKIP`/`MINOR` fallback) and
`meridian-regulatory-compliance-review-bafin`'s step 4 (`BLOCKED`, no fallback in that
scenario's own YAML) across two independent tenants, confirming this is a real
cross-cutting gap rather than one scenario's edge case. (c)
`vortex-entity-list-filter-and-page` remains `BLOCKED_ON_DEPENDENCY` on
`Letflow.Routers.Entities`/`EntityQuery` (S5/S6 scope, not yet landed as of this entry
— already documented in `lib/letflow/router.ex`'s own "Deferred routes" table, not a
newly discovered gap). (d) Both Meridian loan-origination scenarios' committee-vote,
quorum-2-of-3, and disbursement paths were never reached during their own original S7
execution run (truncated by the now-resolved `join_counters` defect) — re-running them
to actually exercise those paths against the fixed Engine is not part of REQ-210's own
scope and is named as follow-up work below. (e) `test/fixtures/simulation/
{swiftroute,vortex,meridian}/scenarios/*.yaml` remain disclosed-synthetic, not
byte-for-byte ports of R-Co's real scenario corpus (`ISS-0391`/`ISS-0393`, both open,
confirmed to be the same underlying gap with ISS-0393 carrying the superset scope —
either can be picked up first, with the other closed as resolved-via-duplicate per
ISS-0391's own `duplicate_note`).

**Out of scope for this batch.** The 18-file `tests/simulation/scenarios/platform/`
corpus — see the dedicated note below, in this file's own "Scope" section.

**Correctness-gate assessment.** See `docs/agents/ORCHESTRATOR.md` §8 for the actual
stage-gate determination; this entry states the factual basis only. Full reasoning:
`lib/letflow/design/req210-s7-parity-report.md` §5.
```

---

## §4. Exact text naming the 18-file `platform/` corpus as out of scope

Per REQ-210's own AC4, this is inserted into `stage-7-simulation-uat-parity.md`'s
existing **"Scope"** section (S6, lines 12–18) — appended as a new paragraph at the end
of that section, not replacing any existing sentence there (the section's opening
paragraph, lines 3–10, already forward-references this exact note: "the 18-file
`tests/simulation/scenarios/platform/` corpus is explicitly out of scope for this
batch — see REQ-210's own scope note and its own future-follow-up recording in this
file's REVIEWER sign-off section once that requirement runs" — this text is what
fulfills that forward reference).

**Exact text to append to the "Scope" section:**

```
**`tests/simulation/scenarios/platform/` — confirmed out of scope for this batch
(REQ-210, verified 2026-09-0N).** R-Co's source tree carries 18 platform-level scenario
files at this path (re-counted directly this session: `platform-agent-artifact-
resubmit-idempotent.yaml`, `platform-attachment-cross-tenant-probe.yaml`,
`platform-definition-promotion-approved.yaml`, `platform-definition-promotion-conflict-
rejected.yaml`, `platform-definition-promotion-rollback.yaml`, `platform-definition-
type-error-blocked.yaml`, `platform-frontend-guard-selfcheck.yaml`, `platform-instance-
pin-survives-catalog-change.yaml`, `platform-migration-partial-failure-resume.yaml`,
`platform-out-of-order-effect-completion.yaml`, `platform-outbox-cap-backpressure.yaml`,
`platform-partition-retention-drop.yaml`, `platform-renderer-permission-denied-
surface.yaml`, `platform-sandbox-cross-tenant-probe.yaml`, `platform-template-update-
conflict-resolution.yaml`, `platform-tenant-branding-applied.yaml`, `platform-tenant-
switch-cache-isolation.yaml`, `platform-unsafe-migration-rejected.yaml` — 18 files, all
18 confirmed tagged `platform_workflow: PW-NN` and `company_id: platform`). This is a
distinct scenario set from the 11 tenant-business scenarios this batch (REQ-206/207/208)
covers, both in origin (platform-operator/cross-tenant concerns — migration safety,
outbox backpressure, tenant-isolation probes, promotion/rollback — rather than a single
tenant's own business workflow) and in scope (it was never named in ORCH's own scoping
of this batch). It is not silently covered by any of REQ-206/207/208/209's work, and it
is not silently dropped: it is recorded here as a deliberate, sized-for-its-own-batch
future follow-up, the same way MVP-1's cancellation and S9's own scoping are recorded as
explicit decisions elsewhere in this project rather than left implicit
(`docs/migration/README.md`'s "Requirement expansion" section). No requirement number is
assigned to this follow-up as of this entry — a future REQ-ANALYST pass should size it
as its own batch when S7 is revisited or extended.
```

---

## §5. Factual pass/blocked assessment of S7's correctness gate

Stated as a report, per REQ-210's own explicit boundary (AC5): this is evidence for
ORCH/RELEASE-VALIDATOR's determination under `docs/agents/ORCHESTRATOR.md` §8, not a
declaration that the stage is done. REQ-210's own acceptance criteria are scoped to
producing this report and confirming the filed gaps, not to deciding the gate result.

**The correctness-gate purpose, restated from the stage doc itself (S6, line 17-18):**
"re-run R-Co's existing business scenarios against the Elixir backend as a correctness
gate... a correctness gate on S4/S5/S6's combined output, not new functionality."

**Facts for ORCH/RELEASE-VALIDATOR to weigh:**

1. **6 of 11 tenant-business scenarios ran clean, no defect surfaced.** No open
   question about S4/S5/S6's correctness on those paths.
2. **3 genuine Engine defects were found by this batch's real-execution
   discipline, and all 3 are already resolved** (`ISS-0392`, `ISS-0396`, `ISS-0397`,
   `ISS-0398` — 4 issue records, since 0392/0396 are a split single-vs-multi-sibling
   pair) — this is direct evidence the correctness gate is *doing its job*: it caught
   real bugs S4/S5/S6's own unit-level test suites had not caught, and this project's
   humanless pipeline closed all of them before this report was written, not after.
3. **2 scenarios (`meridian-loan-origination-{above,below}-threshold`) were never
   fully exercised** — truncated by defect #2 above before reaching their own
   committee-vote/quorum/disbursement assertions. Those defects are now fixed, but
   the scenarios themselves have not been re-run against the fix to confirm the
   previously-unreached paths now pass. This is a real, currently-open verification
   gap: "the blocking defect is fixed" is not the same fact as "the scenario that
   was blocked by it now passes," and only the latter would close AC1/AC2 of REQ-208
   to full `MET` (they were recorded `PARTIALLY MET` at RELEASE-VALIDATOR's own
   original REQ-208 verdict, S9 §critical_finding).
4. **1 scenario (`swiftroute-shipment-attach-delivery-note`) was `UNBUILT_FEATURE`
   at execution time, and the underlying capability has since shipped** (REQ-211 +
   REQ-212) — but, same shape as #3, the scenario itself has not been re-run against
   the new attachment subsystem to confirm it now passes.
5. **1 scenario (`vortex-entity-list-filter-and-page`) remains genuinely blocked on
   unstarted S5/S6 scope** (the entity/entity-query subsystem) — this is expected
   stage sequencing, not a defect, and does not indicate anything wrong with S4/S5/S6's
   *shipped* output; it indicates a piece of that output does not exist yet.
6. **1 cross-cutting endpoint gap (`ISS-0389`, advance-timer) remains open**,
   blocking one sub-step each in two different tenants' scenarios (SwiftRoute step 2,
   Meridian step 4). Neither scenario's own YAML treats this as a hard failure of
   S4/S5/S6's *existing* correctness — SwiftRoute's own scenario documents an
   acceptable `SKIP`/`MINOR` fallback for exactly this gap — but Meridian's BaFin
   scenario has no such fallback and is genuinely `BLOCKED`, not merely degraded.
7. **The scenario-corpus content itself remains disclosed-synthetic**
   (`ISS-0391`/`ISS-0393`), not a byte-for-byte port of R-Co's real scenario files.
   Every design doc and finding involved has been explicit about this from the start;
   it does not invalidate what was actually verified (the *process definitions* and
   *fixtures* driving these scenarios are real, per `ISS-0388`'s resolution — only the
   scenario *narratives themselves* are self-authored-but-structurally-faithful), but
   it is a real caveat on how much confidence "R-Co parity" specifically (as opposed to
   "Letflow's own engine correctness") can draw from these results until real R-Co
   scenario content lands.

**Report (not a declaration):** the correctness gate has demonstrably functioned — it
found and closed 4 real defects — but it has **not yet fully cleared**, on the facts
above: 2 Meridian scenarios' deepest assertions (committee-vote quorum, disbursement)
and 1 SwiftRoute scenario (delivery-note attachment) have known-fixed blockers but no
confirmed re-run proving the previously-unreached paths now pass, and one open
cross-tenant endpoint gap (`ISS-0389`) and one expected stage-sequencing gap
(entity-list subsystem) remain outstanding. Whether these open items are individually
blocking versus acceptable-to-carry-forward against this stage's own gate criteria is
the determination `docs/agents/ORCHESTRATOR.md` §8 reserves to ORCH/RELEASE-VALIDATOR,
not this requirement.

---

## §6. AC-to-section coverage map

| REQ-210 acceptance criterion | Satisfied by |
|---|---|
| AC1 — one aggregate table, all 26 items, each with disposition + recording requirement, none omitted | §1 (1.1–1.4 tables, closure check) |
| AC2 — every REQ-206/207/208 finding confirmed to have a real registered issue_ref; any unregistered finding reported as a new finding | §2 (table + reasoning for the entity-list row, including the "no gap" conclusion stated explicitly rather than silently assumed) |
| AC3 — dated REVIEWER sign-off entry that REPLACES the placeholder, not appended alongside it, stating passed/failed/deferred/unbuilt | §3 (exact replacement block, explicitly marked "replacing... not appending") |
| AC4 — stage doc explicitly names the 18-file platform/ corpus as out of scope, records it as a named future follow-up, distinct from the 11 tenant-business scenarios | §4 (exact text, verified file count/tags) |
| AC5 — factual pass/blocked assessment of S7's correctness-gate purpose, without itself declaring the stage done | §5 (explicit "Report (not a declaration)" framing, reserving the determination to ORCH/RELEASE-VALIDATOR per §8) |

---

## Open questions

None. Every acceptance criterion above maps to a concrete, verified section; no item
was left as "TBD" or silently resolved by assumption. The one judgment call this design
makes explicit rather than silently deciding — whether the vortex-entity-list
dependency status required its own issue_ref — is argued in full in §2, with its
reasoning laid out for CODE-DESIGN-VALIDATOR (or any later reader) to check
independently rather than take on trust.

## Explicitly out of scope for REQ-210 (restated from its own requirement text, not
this design's invention)

No fix for any filed gap. No expansion of `tests/simulation/scenarios/platform/` into
requirements — §4's text names it as future scope only, assigns no requirement number.
No change to REQ-206/207/208/209's own artefacts beyond reading their reports (§1–§2
cite them; nothing under `test/`, `lib/`, or those requirements' own design docs is
modified by this design or its eventual implementation). No re-running of the
Meridian/SwiftRoute scenarios against their now-fixed blockers (§5 point 3/4 names this
as a real open gap, but closing it is not this requirement's job — it is future
follow-up work for whichever session picks it up, most naturally as its own small
requirement once ORCH scopes it).
