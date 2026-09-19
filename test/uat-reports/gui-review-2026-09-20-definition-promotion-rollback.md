# GUI review — definition-promotion-rollback

**Date:** 2026-09-20
**Agent:** ORCH (direct, no nested dispatch, per this run's own instruction)
**Scenario:** `test/fixtures/uat/scenarios/platform/definition-promotion-rollback.yaml`
**Process applied:** "agent reviews real screens before writing a blind Playwright spec"
**Sibling reviews (same machinery, same day):** `definition-promotion-approved.yaml`,
`definition-promotion-conflict-rejected.yaml` — see the other
`test/uat-reports/gui-review-2026-09-20-*.md` files. Real gaps already found in the
shared promotion-review machinery: ISS-0732 (rehearsal not enforced before release),
ISS-0733 (no audit event on release), ISS-0734 (no review-queue GUI screen), ISS-0735
(fixed — 409 conflict responses were mismessaged).

## Path taken

**Outcome 2 of the process: the operator-facing feature genuinely does not exist —
filed as a properly-sized requirement, BLOCKED recorded, no live GUI walkthrough
attempted.** This scenario's steps are all `via: gui`; with zero rollback affordance
anywhere in `web/src`, there is no screen to drive, screenshot, or judge. Rather than
trust the scenario's own pre-existing `NOTE (ISS-0527)` at face value, I independently
re-verified both facts it implies (missing Playwright spec, and — separately — whether
the underlying feature is actually built) by reading current source directly.

## What was checked, and what each source showed

**Backend — fully built and wired, not a gap:**

- `lib/letflow/definitions.ex` — `Letflow.Definitions.rollback_definition_version/4`
  exists (REQ-038/PRM-08): permission check before any row read, `FOR UPDATE` lock,
  the `:active ⇄ :deprecated` pointer swap, `:version_never_active` /
  `:already_active` / `:process_key_not_found` error handling, and a
  `promotion_reviews` supersede step.
- `lib/letflow/routers/definitions.ex` — `POST /api/v1/definitions/:process_key/rollback`
  (`handle_rollback/2`, REQ-077 R9) is live, validates `target_version`, maps every
  backend error to a real HTTP status (403/404/422/422/500), and — checked directly,
  this was the one place the design doc's own history flagged as a real gap at design
  time — the event-append leg is **not** a stub today:
  `opts[:event_appender]` is wired to
  `Letflow.EventStore.PlatformEvents.append_definition_version_rolled_back/2`, a real
  function, not an injected no-op. A successful rollback genuinely writes a
  `DEFINITION_VERSION_ROLLED_BACK` audit event.
- `lib/letflow/design/req038-promotion-rollback.md` — read in full for the design
  rationale (R-Co→Letflow status-vocabulary mapping, the `promotion_reviews`
  exactly-one-match safe default, the two injectable opts). Confirms the backend
  design is deliberate and complete for its own declared scope, and explicitly
  deferred the HTTP layer and any UI to later requirements/stages — which is exactly
  where this gap now sits.

**Frontend — does not exist, confirmed by direct read, not by absence-of-grep alone:**

- `grep -i "rollback|withdraw|restore_version|revert"` across `web/src` — zero
  functional hits (one unrelated `Button.tsx` match, a generic CSS/variant token, not
  this feature).
- `web/src/pages/definitions/DefinitionListPage.tsx` — read in full. It has a
  "Version history" expandable row (`data-testid="version-history-row"`) listing each
  version with a status badge, but the only row-level actions anywhere on the page are
  **Activate** (DRAFT only) and **Archive** (ACTIVE/DEPRECATED only). No
  rollback/withdraw button, no confirmation dialog, no reason field, and no call to
  the rollback endpoint anywhere in `web/src/api/`.
- No change-history/audit-trail screen exists anywhere in `web/src` that could satisfy
  EO-005 (who/when/restored-version/reason).

**Conclusion:** the scenario's own `NOTE (ISS-0527)` — "treat any run of this scenario
as BLOCKED/UNBUILT_FEATURE on the frontend leg" — is correct, not stale. It was
previously only a forward-looking disclaimer about the missing Playwright spec file
specifically (confirmed against `docs/issues/ISS-0527.yaml`, which is about porting
scenario fixtures generally, not this feature); this pass independently confirmed the
underlying premise (no operator-facing rollback UI at all) holds today by reading the
actual frontend source, not by re-citing the note unread.

## Screens reviewed

None. No real GUI walkthrough against `https://qa.bizdala.com` was attempted, because
there is no rollback screen to walk through — attempting to invent one, or to log a
promotion/rollback flow through some unrelated screen, would not test this scenario's
actual acceptance criteria (EO-001 through EO-005 all describe a rollback UI that does
not exist).

## Fixed vs. filed

- **Fixed:** nothing. No real defect was found in already-shipped code — the backend
  is correct and complete for what it claims to do; the gap is an unbuilt frontend
  feature, not a bug.
- **Filed:** `docs/requirements.yaml` **REQ-371** — "Operator-facing rollback/withdrawal
  screen for a released process definition," owner `FRONTEND-DEV`, stage S8, status
  `pending`. Sized as a real requirement (not a one-line bug): the rollback/withdraw
  action and confirmation UI, error-state rendering for all four backend error shapes,
  confirming a new case reflects the restored version, and a change-history/audit view
  for EO-005 — with an explicit acceptance criterion that this scenario's own
  `pipeline_test` (`web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`)
  gets authored and run for real as part of REQ-371's own close-out, so this scenario
  does not stay perpetually blocked one requirement later. REQ-371 also flags, as an
  open check for whoever designs it, that the backend's `@rollback_schema` currently
  takes no `reason` parameter — the scenario's step 3 asks the operator to record one —
  and instructs FRONTEND-DEV to confirm that directly and file a small backend
  follow-up if the reason genuinely has nowhere to go server-side, rather than
  collecting and silently discarding it.

## Run-history / status bookkeeping

- `docs/status/requirement_status.v20.yaml` — appended one `SCOPE-CHANGE`/`done` entry
  (ORCH, 2026-09-20T00:00:00Z) recording this review and REQ-371's filing. Append
  verified clean (`git diff --numstat`: 44 insertions, 0 deletions).
- `docs/status/requirement_status.index.yaml` — volume 20's `entries:` count updated
  8 → 9 in the same pass.
- The scenario file's own `pipeline_test` NOTE block was extended (not removed — the
  feature is not real yet) with a dated addendum pointing at REQ-371 and this report,
  so a future run does not have to re-derive the same finding from scratch.

## Spec status

**Not authored.** Writing `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts`
now, against screens that do not exist, would be exactly the "blind Playwright spec"
this process exists to prevent. It will be authored once REQ-371 ships a real screen,
per REQ-371's own acceptance criteria, and run for real at that time — no assumption
here that it "should" pass.

## Process-compliance note

No direct push to `main` occurred and none was needed — this pass made no `lib/`,
`web/`, or CI-relevant code change; the only writes were to `docs/requirements.yaml`,
`docs/status/requirement_status.v20.yaml`, `docs/status/requirement_status.index.yaml`,
this report, and the scenario fixture's own comment block. No nested fork/sub-dispatch
was used, per this run's explicit instruction.
