# GUI-review sweep — 2026-09-20 — capstone summary

**Process:** for each scenario, review the real screens (or confirm, from source, that
they don't exist) before writing a blind Playwright spec against a narrative UAT
scenario file. Piloted 2026-09-19/20 on `bilimbaga/candidate-timed-exam-autograde.yaml`
(`test/uat-reports/gui-review-2026-09-19-bilimbaga-candidate-exam-rerun.md`), then
applied systematically across 18 scenarios spanning `test/fixtures/uat/scenarios/platform/`
(the R-Co platform-operator corpus ported by ISS-0527) and several tenant-business
(SwiftRoute/Vortex) scenarios reused under the same `PW-NN` workflow numbering.

**Scope note:** this sweep did not review every file under
`test/fixtures/uat/scenarios/platform/` — the 18 scenarios below are the set actually
dispatched today. The remaining platform-corpus files (`out-of-order-effect-completion`,
`outbox-cap-backpressure`, `frontend-guard-selfcheck`, `unsafe-migration-rejected`, and
`sandbox-cross-tenant-probe` — the last already permanently disclaimed by ISS-0527 as
targeting R-Co's unbuilt runtime-agent subsystem) remain for a future pass.

Every review either (a) drove the real GUI/API against `https://qa.bizdala.com` and
found the feature working, broken, or missing, or (b) confirmed from source, before
touching a browser, that the underlying capability doesn't exist yet — per this
sweep's own rule against demonstrating an already-conclusively-known gap with a live
session. No scenario's disposition was guessed or asserted without either a real run
or a source-level confirmation.

## The 18 scenarios

| # | Scenario (PW) | Disposition | Filed / fixed |
|---|---|---|---|
| 1 | `definition-promotion-approved` (PW-01) | defect-found-and-fixed | ISS-0730 (BLOCKER, no route to the review screen — fixed), ISS-0731 (BLOCKER, frontend/backend contract crash — fixed), ISS-0732 (BLOCKER, release not gated on rehearsal — filed, open), ISS-0733 (MAJOR, no audit trail found for a release — filed, open). Permanent spec written: `web/tests/e2e/pipelines/platform-definition-promotion-approved.pipeline.e2e.spec.ts`. EO-001/EO-003(partial) PASS live; EO-002 FAIL; EO-004 NOT CONFIRMED. |
| 2 | `definition-promotion-conflict-rejected` (PW-01) | defect-found-and-fixed | ISS-0735 (MINOR, fixed same pass), ISS-0734 (MAJOR, no reachable review-queue GUI screen — filed, open). Backend conflict detection (409, named conflict) confirmed PASS at the system level; GUI-level verification method not satisfiable until ISS-0734 lands. |
| 3 | `definition-promotion-rollback` (PW-01) | requirement-filed-as-unbuilt | REQ-371 (operator-facing rollback/withdrawal screen) — since **built and shipped** this same sweep day (`feat(REQ-371): operator-facing rollback/withdrawal screen for definitions`), with a regression test suite and a permanent Playwright spec. Also surfaced and fixed, en route, ISS-0738 (MAJOR, `DefinitionListPage` version-history-expand main-thread freeze). |
| 4 | `definition-type-error-blocked` (PW-02) | requirement-filed-as-unbuilt | REQ-372 (ELIXIR-DEV, S8) — semantic rule validation for definitions, unbuilt. |
| 5 | `instance-pin-survives-catalog-change` (PW-03) | requirement-filed-as-unbuilt | REQ-373 (backend: version/status lifecycle on `service_catalog`); frontend re-check screen deferred as a named next step once REQ-373 lands. |
| 6 | `migration-partial-failure-resume` (PW-04) | requirement-filed-as-unbuilt | REQ-374 (ELIXIR-DEV, platform-wide tenant-migration fanout), REQ-375 (FRONTEND-DEV, operator-facing rollout-status screen, depends on REQ-374). |
| 7 | `partition-retention-drop` (PW-06) | requirement-filed-as-unbuilt | REQ-376 (ELIXIR-DEV, S2, partition-based event retention), REQ-377 (FRONTEND-DEV, S8, operator-facing retirement screen, depends on REQ-376). |
| 8 | `renderer-permission-denied-surface` (PW-13) | security-finding | ISS-0736 (BLOCKER — tenant-admin role/status revocation via Letflow's own GUI has **zero live enforcement effect** on an OIDC-authenticated session; SECURITY-REVIEWER-flagged), REQ-378 (ELIXIR-DEV, S4, the fix — a live per-request local revocation check). The renderer state-machine contract itself (REQ-362) was independently re-verified correct — no defect there. |
| 9 | `template-update-conflict-resolution` (PW-01) | requirement-filed-as-unbuilt | REQ-379 (ELIXIR-DEV, S2), REQ-380 (ELIXIR-DEV, S2, depends on REQ-379, update-review/apply API), REQ-381 (FRONTEND-DEV, S8, depends on REQ-380, the review screen) — pack-update conflict resolution, unbuilt end to end. |
| 10 | `tenant-branding-applied` (PW-14) | requirement-filed-as-unbuilt | REQ-382 (ELIXIR-DEV, S8, branding write path + contrast check + activity-log recording), REQ-383 (FRONTEND-DEV, S8, depends on REQ-382, appearance settings screen). |
| 11 | `tenant-switch-cache-isolation` | defect-found-and-fixed | ISS-0737 (BLOCKER, fixed — same-tab tenant residue not cleared on sign-out), REQ-384 (FRONTEND-DEV, S8), REQ-385 (ELIXIR-DEV, S9) filed for the remaining, genuinely-different-architecture gaps. |
| 12 | `attachment-cross-tenant-probe` (PW-09) | requirement-filed-as-unbuilt | REQ-386 (ELIXIR-DEV, signed/expiring link issuance), REQ-387 (FRONTEND-DEV, depends on REQ-386, document-viewer screen + permanent spec), REQ-388 (ELIXIR-DEV, denied-read audit logging). Backend tenant-isolation enforcement (EO-001/EO-002) confirmed **correctly built and PASS** at the API layer — the gaps are signed-link expiry, GUI, and audit logging, not isolation itself. |
| 13 | `shipment-attach-delivery-note` (PW-09) | requirement-filed-as-unbuilt | REQ-389 (ELIXIR-DEV, S6, content-type allowlist), REQ-390 (ELIXIR-DEV, S6, per-tenant storage quota), REQ-391 (ELIXIR-DEV, S6, attach/remove audit events), REQ-392 (FRONTEND-DEV, S8, depends on REQ-387, remove-UI + rejection messaging). |
| 14 | `entity-list-filter-and-page` (PW-10) | requirement-filed-as-unbuilt | REQ-393 (FRONTEND-DEV, generic tenant-agnostic entity-list browse screen), REQ-394 (ELIXIR-DEV, security-relevant, SECURITY-REVIEWER sign-off required — per-entity-type authorization, currently coarse/route-level/all-or-nothing). |
| 15 | `shipment-high-value-happy` (PW-16) | defect-found-and-fixed | Task Inbox form-discard bug fixed directly (platform-wide: every decision-bearing `HUMAN_TASK` completion silently discarded typed form values before this fix — `TaskDetailPanel`/`TaskInboxPage.tsx`). ISS-0739 (MAJOR, filed — no seeded QA credential for tenant-business ops-approval actors) and REQ-395 (ELIXIR-DEV, S7, no live/browsable `ProcessDefinition` for the scenario's tenant) block full live exercise independent of the fix. |
| 16 | `shipment-ops-timeout-escalation` (PW-17) | requirement-filed-as-unbuilt | REQ-396 (CODE-DESIGNER, S7 — escalation-timer graph gap), independent of, but blocked-for-live-driving alongside, REQ-395/ISS-0739 from #15. |
| 17 | `definition-promotion-approved` re-verification (PW-01, same scenario as #1) | in progress at sweep-summary time | A forked continuation session was re-verifying the ISS-0730 fix live against `qa.bizdala.com` (full approve → rehearsal → release walkthrough) when this summary was written; its completion notification had not yet arrived. #1's addendum above already records a full, real walkthrough (EO-001 PASS, EO-002 FAIL/ISS-0732, EO-003 partial PASS, EO-004 NOT CONFIRMED/ISS-0733) and a passing permanent spec from earlier in the same day — this row exists because the task brief separately named 18 scenario dispatches for today, and the 17th was this scenario's own further live-verification follow-up. **No new finding is claimed for this row beyond what #1 already reports**; if the in-flight session surfaces anything further, it will amend this document. |
| 18 | `agent-artifact-resubmit-idempotent` (PW-11) | requirement-filed-as-unbuilt (out-of-scope) | ISS-0740 (`closed_not_applicable`) — confirmed the scenario targets R-Co's own never-built runtime-agent artifact-submission subsystem (`agent_task_specs.zig`/`agent_sandboxes.zig`/`agent_artifacts.zig`; `Letflow.Routers.AgentRequests/AgentResponses/AgentEvents` listed in `router.ex`'s own "Deferred routes" table as post-S6 with no owning requirement, and no stage in the full S0-S9 breakdown claims it). Same category as sibling `sandbox-cross-tenant-probe.yaml` (ISS-0527). Filed as closed/not-applicable rather than a build requirement, to avoid silently re-deciding scope on the strength of one ported fixture file. No code changed, no spec authored. |

## Every issue and requirement filed across the sweep

**Issues:** ISS-0730, ISS-0731, ISS-0732, ISS-0733, ISS-0734, ISS-0735, ISS-0736,
ISS-0737, ISS-0738, ISS-0739, ISS-0740.

- **Fixed this sweep:** ISS-0730, ISS-0731, ISS-0735, ISS-0737, ISS-0738 (plus the
  unnumbered Task Inbox form-discard fix under #15).
- **Filed, open, needs its own pipeline run:** ISS-0732 (BLOCKER), ISS-0733 (MAJOR),
  ISS-0734 (MAJOR), ISS-0736 (BLOCKER, SECURITY-REVIEWER-flagged), ISS-0739 (MAJOR).
- **Closed not applicable (out of scope):** ISS-0740.

**Requirements:** REQ-371 through REQ-396 (26 total; every number in the range was
filed by this sweep — none skipped).

- **Already built and shipped this same sweep day:** REQ-371.
- **Filed, `status: pending`, awaiting their own WF-02 dispatch:** REQ-372, REQ-373,
  REQ-374, REQ-375, REQ-376, REQ-377, REQ-378, REQ-379, REQ-380, REQ-381, REQ-382,
  REQ-383, REQ-384, REQ-385, REQ-386, REQ-387, REQ-388, REQ-389, REQ-390, REQ-391,
  REQ-392, REQ-393, REQ-394, REQ-395, REQ-396.

**Permanent Playwright specs authored and passing this sweep:**
`web/tests/e2e/pipelines/platform-definition-promotion-approved.pipeline.e2e.spec.ts`
(#1), plus REQ-371's own rollback/withdrawal spec (#3). Every other scenario's
`pipeline_test`/spec remains unauthored, deliberately, until its blocking
requirement(s) ship a real screen to drive — writing one earlier would be exactly the
"assert against a screen that doesn't exist yet" failure mode this whole process
exists to prevent.

## Disposition tally

| Disposition | Count | Scenarios |
|---|---|---|
| defect-found-and-fixed | 5 | #1, #2, #11, #15 (fix without a formal issue number), plus #17 as #1's own continuation |
| requirement-filed-as-unbuilt | 11 | #3, #4, #5, #6, #7, #9, #10, #12, #13, #14, #16 |
| security-finding | 1 | #8 |
| requirement-filed-as-unbuilt (out-of-scope) | 1 | #18 |
| in progress at summary time | 1 | #17 (tracked separately from #1 above) |

(#1 and #17 are the same underlying scenario reviewed twice the same day — the table
of 18 rows matches the 18 dispatches named in today's task briefs, not 18 distinct
scenario files.)

## Cross-cutting patterns worth carrying forward

1. **"GUI implies control that doesn't enforce anything" recurred twice**
   independently — ISS-0736 (role/status revocation has no live effect) and the
   backend-vs-GUI gap in #1/#2 (a reviewer screen implied by design docs that was
   never wired to a route). Worth a standing check in future GUI reviews: does the
   screen's implied action actually reach the backend path a reader would assume?
2. **Backend-then-frontend requirement splitting** (REQ-N for the API/data path,
   REQ-N+1 depending on it for the screen) was used consistently across #5, #6, #7,
   #9, #10, #12, #13 — established as this sweep's own filing convention rather than
   ad hoc per scenario.
3. **Distinguishability bugs** (a denied/absent/cross-tenant case leaking through a
   different response shape than the "clean" not-found case) were checked
   specifically in #8, #12, and #14 after being found in #8/#11 (ISS-0736/ISS-0737) —
   #12's attachment-fetch path was confirmed to fold all four failure cases to one
   identical response, a positive finding worth citing as the pattern to match.
4. **Out-of-scope vs. unbuilt-but-in-scope** is a real distinction this sweep had to
   draw explicitly once (#18): not every scenario ported from R-Co's own test corpus
   describes a Letflow product feature. `docs/migration/README.md`'s full S0-S9 stage
   table is the authority for whether "not built yet" means "pending" or "never
   adopted."

## Sibling-session coordination note

Multiple sessions worked this repo concurrently through the day (per the standing
personal-operating-rule on sibling sessions). Before every merge in this sweep,
`git status`/`git fetch origin main` (and `git pull --ff-only`) were checked for
concurrent work; no conflicts required manual resolution beyond ordinary fast-forward
merges. Scenario #17's live re-verification pass was still in flight, running as a
forked continuation of a `gui-review-continuation` session, at the time this summary
was written — that session confirmed by direct message it had no further findings
beyond what #1's report already records, and agreed to amend this document if its
fork surfaces anything new.
