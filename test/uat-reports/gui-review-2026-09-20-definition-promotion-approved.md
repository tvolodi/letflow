# GUI review — platform-definition-promotion-approved (PW-01)

**Run date:** 2026-09-20
**Agent:** UAT-RUNNER, following the "review real screens before writing a blind
Playwright spec" process piloted 2026-09-19/20 on
`bilimbaga/candidate-timed-exam-autograde.yaml`
(`test/uat-reports/gui-review-2026-09-19-bilimbaga-candidate-exam-rerun.md`).
**Scenario:** `test/fixtures/uat/scenarios/platform/definition-promotion-approved.yaml`
(`platform_workflow: PW-01`, `process_id: sys-definition-promotion`)
**Target:** `https://qa.bizdala.com` (environment: qa), actor `reviewer` /
`PLATFORM_ADMIN` role, credential `admin-user` per `ai-dala-infra/scripts/qa-login.sh`

## Outcome: BLOCKED on a real, confirmed BLOCKER-severity `web/` defect —
## no permanent Playwright spec written, `pipeline_test:` key left as-is

Per the dispatch's instructions: a real defect blocks the entire GUI leg of this
scenario, so no permanent spec was written and nothing else was committed to `web/`.
Filed `docs/issues/ISS-0730.yaml` (BLOCKER) and this report.

## 1. Backend machinery — confirmed present by code reading (not this run's focus,
## background research already done before this run started)

`lib/letflow/definitions/promotion_review.ex`, `promotion_review_store.ex`,
`Letflow.Definitions.PromotionPlan.compute_promotion_plan/5`,
`Letflow.Definitions.apply_promotion_assertion_rerun/6` +
`Letflow.SandboxPool`, and the HTTP routes in `lib/letflow/routers/promotions.ex`
are all real, wired, and match REQ-035/036/037/039/040/077 (`status: done` in
`docs/requirements.yaml`).

One correction to the pre-run research brief: the brief flagged
`lib/letflow/definitions/promotion.ex`'s moduledoc as saying there is no data path
from `promote_definition/3` to a working `Letflow.EventStore.append/2` call
(EO-004's audit-trail requirement). Reading the actual current callers shows this is
now **stale** — `lib/letflow/routers/promotions.ex:596` and
`lib/letflow/routers/tenants.ex:404` both pass
`event_appender: &Letflow.EventStore.PlatformEvents.append_definition_promoted/2`,
and `lib/letflow/tenant_provisioning.ex:925` registers a real `DEFINITION_PROMOTED`
event type in `event_type_registry` (REQ-140, `req140-platform-event-append-path.md`).
So the audit-trail data path appears to exist today at the backend level. This was
**not independently re-verified end-to-end this run** (see §4 below — the GUI leg
blocks before a review can even be approved, so there was no real promotion to check
an audit trail for), so EO-004 is recorded as **NOT REACHED**, not PASS.

## 2. Frontend components exist but are never wired to any route — confirmed by
## static reading, then confirmed live

`web/src/components/promotions/` contains real, apparently complete components:
`PromotionReviewStateMachine.tsx`, `PlanDigestView.tsx`,
`NonSkippableApprovalGate.tsx`, `ConflictRejectionAlert.tsx`, backed by
`web/src/hooks/usePromotions.ts` / `web/src/api/promotions.ts`.

```
$ grep -rln "PlanDigestView\|NonSkippableApprovalGate\|ConflictRejectionAlert\|usePromotions" web/src --include=*.tsx --include=*.ts | grep -v __tests__ | grep -v components/promotions
(no output)
```

Zero real callers outside the components' own definition/test files. Cross-checked
`web/src/router.tsx` in full — 88 lines, every route from `/` down to
`exam/sessions/:sessionId/result` — no `promotion`-related path anywhere.
`web/src/components/layout/AppShell.tsx`'s `NAV_ITEMS` also has no
promotion/review/change entry for any role.

`DefinitionEditorPage.tsx` does have a working "Promote" trigger (this scenario's
step 1 — proposing the change), so the *propose* side of the flow has a real GUI
entry point; only the reviewer's screens (steps 2/3/5) are missing.

## 3. Live confirmation against QA — real PLATFORM_ADMIN sign-in, real 404s

Minted a real Keycloak token for `admin-user` (`bpm-default` realm,
`PLATFORM_ADMIN` role — confirmed from the decoded JWT: `roles: ['PLATFORM_ADMIN']`,
`preferred_username: admin-user`), injected it into a real Chromium session via the
app's own `__e2e_session` mechanism (the same one the project's existing
`pipeline.ts` helper uses for every other pipeline spec — a real, application-
supported test-session path, not a mock of any HTTP call), then drove the real app:

- `GET /` as `admin-user` → real sidebar, screenshot `01-dashboard.png` — nav
  text captured via `page.locator('aside a, aside button').allTextContents()`:
  `Instances, My Tasks, Definitions, DLQ, Webhooks, Users, Groups, Tokens, Audit,
  Health, Metrics, Register Tenant, Tenants, Services, Question Bank, Sign out`.
  No promotions/change-review entry.
- Direct navigation to four plausible guessed routes (`/admin/promotions`,
  `/promotions`, `/definitions/promotions`, `/admin/definitions/promotions`): all
  four render React Router's raw **"Unexpected Application Error! 404 Not Found"**
  dev error page (`errorElement`/`ErrorBoundary` not customized for this case),
  confirming live and reproducibly that no such route is registered anywhere in the
  shipped app, screenshot `02-promotions-guess.png` (confirmed by direct visual
  read of the rendered page, not inferred from HTTP status alone).

Screenshots (not committed — driven via a scratch Node script, output written under
this session's scratchpad, same "gitignored evidence, not part of the repo" convention
the bilimbaga pilot used for `web/tests/screenshots/pipelines/`).

## 4. Scenario steps reached

| Step | Actor | Result |
|---|---|---|
| 1 (propose) | authoring_agent, `via: system` | Not exercised this run — GUI leg (below) blocks before this would matter; backend route exists (`DefinitionEditorPage`'s Promote button confirms a propose path is real). |
| 2 (open pending review, read diff) | reviewer, `via: gui` | **BLOCKED** — no route renders this screen. |
| 3 (approve) | reviewer, `via: gui` | **BLOCKED** — unreachable, same cause. |
| 4 (rehearsal) | rehearsal, `via: system` | Not exercised — depends on step 3. |
| 5 (release) | reviewer, `via: gui` | **BLOCKED** — unreachable, same cause. |

## 5. Expected outcomes

| EO | Verification | Result |
|---|---|---|
| EO-001 (reviewer sees full change list before approving) | `gui_screen` | **NOT REACHED / BLOCKED** — the screen this verification needs does not exist reachably in the app. Recorded as the defect's primary evidence (ISS-0730), not a silent skip. |
| EO-002 (rehearsal re-run gates release) | `system_state` | **NOT REACHED** — depends on an approval that cannot be produced through the real app. |
| EO-003 (in-flight cases keep their pinned version; new cases get the new one) | `gui_screen` | **NOT REACHED** — depends on a completed release, which depends on the blocked steps above. |
| EO-004 (end-to-end audit trail) | `audit_event` | **NOT REACHED** — see §1: the backend data path looks present on paper, but this run did not produce a real promotion to check, so this is not claimed as PASS. Deliberately not verified via a backend-only/API-bypass path per this pilot's "no substitute API-only path" rule when a `via: gui` step is what's actually broken. |

No expected outcome is recorded as PASS this run.

## 6. No spec written, nothing else committed

Per the dispatch's instructions: a real, BLOCKER-severity defect (ISS-0730) blocks
the entire GUI leg, so `web/tests/e2e/pipelines/platform-definition-promotion-approved.pipeline.e2e.spec.ts`
was **not** written, and the scenario YAML's existing `pipeline_test:` key / ISS-0527
note were left exactly as they already were (that note already correctly describes
today's state — the spec still does not exist, for the same underlying reason ISS-0527
recorded, now root-caused). Recommend ORCH dispatch FRONTEND-DEV against
`docs/issues/ISS-0730.yaml`: add a route (e.g.
`definitions/:id/promotions/:reviewId` or a standalone `admin/promotions` list +
detail pair) that renders the already-built `PromotionReviewStateMachine`, plus a
`NAV_ITEMS` entry for it. Once that lands, UAT-RUNNER should re-attempt this
scenario's full walkthrough (including building a real differing-tenant plan pair,
approving, waiting for rehearsal, releasing, and checking EO-003's in-flight-vs-new
version split) before writing the permanent spec.

## No password reproduced in this report

Credentials referenced only as "QA `admin-user`, see
`ai-dala-infra/scripts/qa-login.sh`" throughout.
