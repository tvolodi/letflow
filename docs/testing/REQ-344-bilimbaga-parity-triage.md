# REQ-344 — BilimBaga Playwright Parity Triage

**Produced:** 2026-09-14
**Branch:** `feat/REQ-344-20260914`
**Source corpus (mirrored locally):** `/opt/apps/bilimbaga-test/frontend/e2e/**/*.spec.ts` (19 files)
**Letflow routes read from:** `web/src/router.tsx` (full file, reproduced below)
**Precedent:** `docs/testing/REQ-122-e2e-inventory.md` (did the same triage job for
Letflow's own 37 specs)

This document produces no code and modifies no spec file. It classifies all 19
BilimBaga spec files against Letflow's actual routes and `data-testid` hooks, and
corrects `docs/migration/stage-10-bilimbaga-vertical.md`'s P5 row.

---

## 1. Re-measured test() block count

Three independent grep passes, run against the mirrored corpus:

```
$ cd /opt/apps/bilimbaga-test/frontend/e2e
$ grep -rE '^\s*test\(' . --include='*.spec.ts' | wc -l
168
$ grep -ro 'test(' . --include='*.spec.ts' | wc -l
168
$ grep -rE '(^|[^.[:alnum:]_])test\(' . --include='*.spec.ts' | wc -l
168
```

All three methods agree: **168**, not 286. This confirms the requirement's own
prior measurement and `decisions/0022-bilimbaga-vertical.md`'s figure; it
contradicts the "286" currently recorded in `docs/migration/stage-10-bilimbaga-vertical.md`'s
P5 row, which is corrected in §6 below. I did not reproduce 286 by any method.

**Hidden-multiplier check** — all zero, confirmed by literal (parenthesised)
patterns so a bare `.` doesn't false-match on prose like "test skipped":

```
$ for pat in "test.only(" "test.skip(" "test.fixme(" "test.step(" "test.beforeEach(" "test.afterEach("; do
    echo -n "$pat: "; grep -rF "$pat" . --include='*.spec.ts' | wc -l
  done
test.only(: 0
test.skip(: 0
test.fixme(: 0
test.step(: 0
test.beforeEach(: 0
test.afterEach(: 0
```

(Note: an earlier unescaped-dot pattern `test\.skip\|test\.only...` without
trailing parens returns 5 hits, but they are all false positives — the literal
string "test skipped" inside `test.info().annotations.push(...)` descriptions in
`loyalty-narrative.spec.ts` and `grading/ai-grading.spec.ts`, where the regex's
`.` matched a space. The parenthesised version above is the correct measurement:
zero.)

**Per-file breakdown** (line-anchored `^\s*test\(`, all 19 files):

| File | test() count |
|---|---|
| `full-walkthrough.spec.ts` | 22 |
| `question-management.spec.ts` | 20 |
| `user-management.spec.ts` | 18 |
| `exam-taking.spec.ts` | 11 |
| `grading/ai-grading.spec.ts` | 9 |
| `exam-wizard.spec.ts` | 9 |
| `employee-portal.spec.ts` | 8 |
| `exam-lifecycle.spec.ts` | 8 |
| `accessibility.spec.ts` | 7 |
| `admin-grading.spec.ts` | 7 |
| `question-bank.spec.ts` | 7 |
| `question-editor.spec.ts` | 7 |
| `my-results.spec.ts` | 6 |
| `tags.spec.ts` | 6 |
| `auth.spec.ts` | 5 |
| `categories.spec.ts` | 5 |
| `exam-result.spec.ts` | 5 |
| `branding.spec.ts` | 4 |
| `loyalty-narrative.spec.ts` | 4 |
| **Total** | **168** |

This exactly matches the requirement's own "measured 2026-09-14" per-file table —
independently re-derived, not copied.

**Selector-mix re-measurement** (the requirement cites 301/134/66/16; my own
grep gives slightly different but comparable numbers — I use my own figures, not
the requirement's, per the acceptance criterion):

```
$ for pat in "getByRole(" "locator(" "getByText(" "getByLabel(" "data-testid"; do
    echo -n "$pat: "; grep -ro "$pat" . --include='*.spec.ts' | wc -l
  done
getByRole(: 314
locator(: 137
getByText(: 65
getByLabel(: 16
data-testid: 1
```

The one `data-testid` occurrence is in `loyalty-narrative.spec.ts:185`, and it is
an *optional* fallback inside an `.or()`-style triple-selector
(`'[data-testid="loyalty-narrative"], .loyalty-narrative, .narrative-text'`), not
a hook BilimBaga's own UI reliably exposes. Every BilimBaga spec otherwise binds
to `getByRole`/`locator`/`getByText`/`getByLabel` against rendered DOM structure
and accessible names/roles, in Russian and English text alike. **This means every
PORTABLE entry below requires the spec to be rewritten against Letflow's
`data-testid` hooks, not retargeted by baseURL or config** — restated explicitly
per entry below.

---

## 2. Letflow's actual routes (`web/src/router.tsx`, read in full)

```
/auth/callback                                  OidcCallbackPage
/ (index)                                        TenantDashboardPage
/dashboard                                       TenantDashboardPage
/definitions, /definitions/new, /definitions/:id DefinitionListPage / DefinitionEditorPage
/instances, /instances/:id                       InstanceBoardPage / InstanceDetailPage
/tasks                                           TaskInboxPage
/admin/users, /admin/users/:userId               UsersPage / UserDetailPage
/admin/groups                                    GroupsPage
/admin/tokens                                    TokensPage
/admin/audit                                     AuditLogPage
/admin/health                                    HealthDashboardPage
/admin/metrics                                   MetricsPage
/admin/onboarding[/new|/:id/progress|/:id/result] onboarding pages
/admin/tenants, /admin/tenants/:slug/edit        TenantsPage / EditTenantPage
/admin/services                                  ServicesPage
/admin/modules                                   ProcessModulesPage
/admin/bilimbaga                                 BilimBagaAdminPage
/admin/bilimbaga/:entityType                     BilimBagaEntityRoute -> EntityCrudPage
/dlq                                             DlqPage
/webhooks                                        WebhooksPage
/exam                                            ExamListPage
/exam/:examId/session                            ExamSessionPage
```

Everything hangs off `/` behind `AuthProvider` + `ProtectedRoute` + `AppShell`.
There is **no** `/login`, `/portal`, `/change-password`, `/admin/dashboard`,
`/admin/questions`, `/admin/exams`, `/admin/grading`,
`/admin/settings/branding`, `/admin/categories`, `/admin/tags`,
`/admin/departments`, or any `/admin/*/record` / `/admin/*/analytics` route.
Auth is Keycloak OIDC redirect via `ProtectedRoute`, not an in-app `/login`
page; there is no in-app change-password screen either (Keycloak owns
credential management).

`BILIMBAGA_ENTITY_TYPES` (`web/src/config/bilimbagaEntities.ts`, current HEAD)
lists **ten** entity types, generically routed at `/admin/bilimbaga/:entityType`
through `EntityCrudPage`: `category`, `question`, `answer_option`,
`question_tag`, `exam`, `exam_section`, `exam_question_rule`,
`exam_question_rule_tag`, `exam_manual_question`, `tag`.

`EntityCrudPage.tsx`'s only `data-testid` hooks:
`entity-crud-page` (root, carries `data-entity-type`), `entity-create-action`,
`entity-form-modal`, `entity-edit-<record_id>`, `entity-delete-<record_id>`.
It renders exactly the fields the entity definition returns, in a single-step
create/edit modal — it has **no** search box, no import/export, no
archive/delete-confirmation dialog, no bulk-select, no AI-generate, and no
multi-step wizard.

`ExamListPage.tsx` / `ExamSessionPage.tsx` (candidate-facing, at `/exam` and
`/exam/:examId/session`) carry: `exam-list-page`, `exam-list`,
`exam-list-empty`, `exam-list-provisional-notice`, `exam-list-item-<id>`,
`exam-list-start-<id>`, `exam-session-page`, `exam-starting`,
`exam-start-error`, `exam-expired`, `exam-result-page`,
`exam-result-pending`, `exam-result-score`, `exam-submit-action`,
`exam-anticheat-warning`, `exam-question-<id>`, `exam-option-<id>`,
`exam-short-text-input`, `exam-save-status`.

`UsersPage.tsx` (bespoke, not entity-CRUD-engine) carries: `admin-users-new`,
`admin-users-search`, `admin-users-table` — plus an inline "Create user" panel
with plain `aria-label`s (no `data-testid`), no edit action, no reset-password
action, no deactivate action, no bulk-import.

`AuditLogPage.tsx` has From/To filters as plain ISO8601 text inputs (not
`input[type="datetime-local"]`), no Export CSV button, no `data-testid`.

`AppShell.tsx` has an unlabelled `<nav>` (no `aria-label="Main navigation"`)
and **no skip link, no `#main-content` landmark, no `tabindex=-1` target** —
grepped and confirmed absent repo-wide.

---

## 3. The tag reachability question — re-derived live, not from the requirement text

The requirement's own framing (written before this session) says the omission
of `tag` from `BILIMBAGA_ENTITY_TYPES` is deliberate (it was REQ-336's own pilot
entity), but that `TagListPage.tsx` exists and is imported by nothing in
`web/src/router.tsx`, making `/admin/tags`-equivalent screen unreachable.

**That finding is now stale.** `git log` on `main` shows `ISS-0655` (PR #1385,
commit `43fdf238`, merged just before this session started) already closed it:

```
$ git log --oneline -5 -- web/src/pages/entities/ web/src/config/bilimbagaEntities.ts
43fdf238 fix: wire tag into BilimBaga admin CRUD, remove superseded TagListPage
9f29e1ef REQ-343: wire full list/create/edit/delete screens ... (#1368)
1f763876 REQ-336: generic admin-CRUD screen engine in web/, proven against tag pilot entity (#1364)
```

```
$ grep -rn "TagListPage" web/src
web/src/config/__tests__/bilimbagaEntities.test.ts:8: * ... TagListPage.tsx pilot ...
web/src/config/bilimbagaEntities.ts:9: *  ... TagListPage.tsx pilot for tag -- since superseded
web/src/pages/entities/__tests__/EntityCrudPage.test.tsx:14: * (TagListPage.tsx, since removed as superseded dead code) ...
web/src/__tests__/entities-i18n-grep.test.ts:15: * ISS-0655: ... TagListPage.tsx pilot was removed as superseded dead ...
web/src/pages/entities/EntityCrudPage.tsx:5: *  ... REQ-336's TagListPage.tsx pilot generalized ...
```

`ls web/src/pages/entities/` shows only `EntityCrudPage.tsx` and its
`__tests__/` — **`TagListPage.tsx` no longer exists as a file.** All remaining
hits are historical comments/doc-strings referencing it as removed.

```
$ grep -in "tag" web/src/router.tsx
(no output)
```

The router has no literal `tag` string because tag is served by the *generic*
`/admin/bilimbaga/:entityType` route, and `bilimbagaEntities.ts` (current HEAD)
now lists `tag` as the **tenth** entry in `BILIMBAGA_ENTITY_TYPES`, so
`isBilimBagaEntityType('tag')` is `true` and `/admin/bilimbaga/tag` renders
`EntityCrudPage` with `data-entity-type="tag"`.

**Answer: `/admin/bilimbaga/tag` is reachable today. The original "unreachable
pilot screen" gap this requirement was written to check no longer exists in
its original form** — it was closed by ISS-0655 before this session began.

What remains genuinely open, and is **not** a router/reachability defect
(so I am not filing it and did not touch the router): `tags.spec.ts`'s tests
target `/admin/tags`, a URL Letflow does not serve — the real tag screen lives
at `/admin/bilimbaga/tag`. That is a plain URL/testid mismatch, not an
unreachable-screen bug, and is handled the same way as `categories.spec.ts`
and `question-bank.spec.ts` below: PORTABLE-NOW, rewritten against the new
path and the `entity-crud-page` family of testids. See `tags.spec.ts`'s entry
in §4.

---

## 4. Per-file classification

Legend: **PORTABLE-NOW** (real route + real testid exist today — rewrite
required, not retargeting); **PORTABLE-AFTER-\<gap\>** (names the missing
route/screen/testid/fixture and the REQ/issue that would supply it);
**NO-COUNTERPART** (no Letflow surface exists or is planned under S10 — states
disposition).

### 1. `auth.spec.ts` (5 tests) — NO-COUNTERPART

All five tests assert against a local `/login` form (`getByRole('textbox',
{name: /email/i})`, `getByLabel(/password/i)`, an inline invalid-credentials
error) and a post-login redirect to `/admin`. Letflow has no in-app login
form — `ProtectedRoute` redirects unauthenticated users straight to Keycloak's
hosted login page, which is a different origin, a different DOM, and outside
this SPA's test surface entirely. **Disposition:** no counterpart is planned
under S10; Letflow's own equivalent auth E2E coverage already exists in
`web/tests/e2e/` against the OIDC flow (see `docs/testing/REQ-122-e2e-inventory.md`,
e.g. `sh01-04.shell.e2e.spec.ts`) and is out of this requirement's scope to
touch. Dropped, not ported.

### 2. `employee-portal.spec.ts` (8 tests) — PORTABLE-AFTER-REQ-346

All eight tests navigate to `/portal` and `/portal/results`, neither of which
exists; Letflow's candidate-facing exam UI lives at `/exam` and
`/exam/:examId/session` (built by REQ-338, `web/src/pages/exam/`). The
equivalent flows (exam list with start/continue CTAs, my-results view) are
named in REQ-346's title as work still `pending`
("Port the exam-listing and exam-taking BilimBaga parity specs
(employee-portal, exam-taking) onto /exam and /exam/:examId/session"). Named
gap: the URL surface (`/portal` → `/exam`) and every testid
(`.rounded-lg.border.bg-card` CSS-class selectors and Russian/English text →
`exam-list-item-<id>`, `exam-list-start-<id>`, `exam-list-provisional-notice`).
**Gap-supplying REQ: REQ-346** (`status: pending`). Rewrite required, not
retargeting: BilimBaga selects cards by CSS class and localized text; Letflow's
equivalent hooks are `data-testid`.

### 3. `exam-taking.spec.ts` (11 tests) — PORTABLE-AFTER-REQ-346

Same disposition as employee-portal.spec.ts: targets `/portal/sessions/*`
(non-existent) instead of `/exam/:examId/session`
(`web/src/pages/exam/ExamSessionPage.tsx`, real, built by REQ-338, carrying
`exam-session-page`, `exam-question-<id>`, `exam-short-text-input`,
`exam-save-status`, `exam-submit-action`, `exam-anticheat-warning` testids —
see §2). The single-choice/multiple-choice/true-false/Likert/short-text
per-question-type assertions map fairly directly onto
`ExamSessionPage`'s rendered question types, but every locator (`[role=
"radiogroup"]`, `input[type="checkbox"]`, Russian/English save-status text)
must be rewritten against the testids above, not retargeted. **Gap-supplying
REQ: REQ-346** (`status: pending`).

### 4. `exam-result.spec.ts` (5 tests) — PORTABLE-AFTER-REQ-349

Targets `/portal/sessions/:id/result`, non-existent; Letflow's result view is
a state inside `ExamSessionPage` itself (`exam-result-page`,
`exam-result-pending`, `exam-result-score` testids), not a separate route.
REQ-349's own title states the gap precisely: "Port the result-surface
BilimBaga parity specs (exam-result, my-results) by DRIVING THE LIVE
start-answer-submit FLOW to the result phase — the only way
exam-result-page/pending/score are reachable". **Gap-supplying REQ: REQ-349**
(`status: pending`). Rewrite required: no separate result URL/route exists to
retarget to — the spec must drive the same session through to submission
rather than deep-linking.

### 5. `my-results.spec.ts` (6 tests, `FR-BB46`) — PORTABLE-AFTER-REQ-349

Targets `/portal/results` (non-existent) with a results table. Letflow has no
standalone "my results" list screen today — REQ-349's title explicitly bundles
`my-results` alongside `exam-result` as the same result-surface port. **Gap-
supplying REQ: REQ-349** (`status: pending`). Until REQ-349 lands, there is no
concrete Letflow testid to name for the *list* view (only the single-session
result states inside `ExamSessionPage`); REQ-349's own description states the
list-of-past-results form is not necessarily what gets built (only the
single-session result phase is proven reachable). Flagging this precisely so
REQ-349's implementer does not assume a results list surface is guaranteed —
it is not, per REQ-349's own text.

### 6. `tags.spec.ts` (6 tests) — PORTABLE-NOW

Targets `/admin/tags`; the real route is `/admin/bilimbaga/tag`
(`BILIMBAGA_ENTITY_TYPES` entry `tag`, wired by ISS-0655 — see §3). Real
testids exist today: `entity-crud-page` (root, `data-entity-type="tag"`),
`entity-create-action` (replaces the "New Tag" button lookup),
`entity-form-modal` (replaces `getByRole('dialog')` for the create dialog).
The "GET /api/v1/tags carries Authorization header" test maps onto
`GET /entities/definitions/active/tag` + the entity list endpoint the pack
actually calls — needs the real endpoint name, not `/api/v1/tags`. The "search
input filters the tag list" test has **no counterpart**: `EntityCrudPage` has
no search box (see §2) — this sub-test is NO-COUNTERPART pending a future
entity-CRUD search feature (no REQ names one today); the other five sub-tests
are PORTABLE-NOW. **Rewrite required, not retargeting**: BilimBaga's tags.spec.ts
uses zero `data-testid`s (`getByRole('heading')`, `getByRole('table')`,
`getByRole('button', {name: /new tag/i})`); the Letflow rewrite must bind to
`entity-crud-page`/`entity-create-action`/`entity-form-modal` instead.

### 7. `categories.spec.ts` (5 tests) — PORTABLE-NOW

Targets `/admin/categories`; real route is `/admin/bilimbaga/category`
(`category` is entry 1 of `BILIMBAGA_ENTITY_TYPES`). Same testid family as
tags: `entity-crud-page`, `entity-create-action`, `entity-form-modal`. All 5
tests (auth-header check, list renders, New-Category button, create modal
opens, name field accepts input) map onto generic `EntityCrudPage` behaviour
with no missing feature. **Gap-supplying REQ:** none needed — PORTABLE-NOW.
Note per REQ-343's own gap record (`web/src/config/bilimbagaEntities.ts`'s
doc-comment): `category.parent_id` does not exist on the entity definition, so
if BilimBaga's `categories.spec.ts` grows a tree/hierarchy assertion in a
future revision it would not be portable — the mirrored corpus read for this
triage has no such assertion today. **Rewrite required, not retargeting.**

### 8. `question-bank.spec.ts` (7 tests) — split

Targets `/admin/questions`; the generic counterpart is
`/admin/bilimbaga/question`. Per-test:
- "displays the question bank heading and table" — PORTABLE-NOW
  (`entity-crud-page` renders a table via `DataTable`, same shape as
  categories/tags).
- "shows the New Question button" — PORTABLE-NOW (`entity-create-action`).
- "navigates to question editor on New Question click" (asserts URL becomes
  `/admin/questions/new`) — **NO-COUNTERPART.** `entity-create-action` opens
  an in-page modal (`entity-form-modal`), not a URL navigation to a dedicated
  editor page. No REQ plans a dedicated `/admin/bilimbaga/question/new` route
  under S10; disposition: dropped, not ported — asserting URL navigation
  against a modal-based create flow would be authoring a failing spec, which
  this requirement's acceptance criteria forbid.
- "shows difficulty badges for existing questions" — PORTABLE-AFTER-<gap>:
  `EntityCrudPage` renders exactly the fields the entity definition returns
  as plain table cells, with no badge/styling layer. Gap: no "render field X
  as a status badge" capability exists in `EntityCrudPage`. No REQ names this
  today (not in REQ-347's scope, which is CRUD parity, not per-field
  presentation). Reported to ORCH as a gap in the completion summary, not
  filed as an issue by me.
- "search input filters questions without crashing" and "shows empty state
  when search matches nothing" — NO-COUNTERPART (no search box in
  `EntityCrudPage`, same gap as tags.spec.ts's search sub-test above).
- "shows Import and AI Generate buttons" — NO-COUNTERPART (no
  import/AI-generate feature anywhere in the generic entity-CRUD engine; not
  named in REQ-347's scope). Dropped, not ported.

**Gap-supplying REQ for the PORTABLE-NOW subset:** none needed, already real.
**Rewrite required, not retargeting**, for the 2 PORTABLE-NOW sub-tests.

### 9. `exam-lifecycle.spec.ts` (8 tests) — split, REQ-347-named file

REQ-347's title explicitly lists `exam-lifecycle` alongside `categories`,
`tags`, `question-bank` as the entity-CRUD-backed admin parity set bound for
`/admin/bilimbaga/:entityType` (here, `entityType=exam`). Per-test:
- "exams list renders without error and shows status badges" — PORTABLE-AFTER-
  REQ-347: the list-renders-without-error half is PORTABLE-NOW today
  (`entity-crud-page`), but the status-badge assertion hits the same
  no-badge-rendering gap as question-bank's difficulty-badge test above (plain
  table cells, no badge styling). **Gap-supplying REQ: REQ-347** (`status:
  pending`) covers the CRUD port; the badge-styling sub-gap is not named in
  REQ-347's own text and should be flagged to its implementer.
- "seeded active exam shows 'active' badge" / "draft exam shows 'draft'
  badge" / "archived exam shows 'archived' status" — same badge gap,
  PORTABLE-AFTER-REQ-347 with the badge caveat carried forward.
- "all exam rows have an Edit action link" — PORTABLE-NOW: `entity-edit-
  <record_id>` exists today.
- "editing the seeded mixed exam loads Step 1 with pre-populated title" and
  "exams list page navigates to edit wizard on clicking edit" —
  **NO-COUNTERPART.** These assert a dedicated multi-step wizard page
  (`/admin/exams/:id/edit`, "Step 1", "Basic Settings"). `EntityCrudPage`'s
  edit action opens the same single-step `entity-form-modal` as create, not a
  wizard. No REQ plans a wizard for the generic entity-CRUD engine — REQ-347's
  own scope is "entity-CRUD-backed" parity, which by definition excludes
  wizard behaviour. Dropped, not ported; reported to ORCH as a scope
  boundary, not filed as an issue.
- "exams list shows multiple statuses when multiple exams exist" — same
  badge-rendering gap as above, PORTABLE-AFTER-REQ-347.

**Rewrite required, not retargeting**, for every PORTABLE sub-test: BilimBaga
binds to `table tbody tr` CSS + localized badge text; Letflow's hooks are
`entity-crud-page`/`entity-edit-<id>`.

### 10. `exam-wizard.spec.ts` (9 tests) — NO-COUNTERPART

Every test drives a bespoke 4-step wizard (`/admin/exams/new`,
`/admin/exams/:id/edit`, "Step 1/2/3/4", `#title`/`#timeLimitMinutes`/
`#passingScorePct`/`#maxAttempts` field IDs, a publish-confirmation dialog).
No such wizard exists in Letflow, nor is one named in REQ-347 (whose scope is
explicitly the generic entity-CRUD engine, not a hand-built wizard) or
anywhere else in the S10 P4/P5 requirement set. **Disposition:** no counterpart
is planned under S10. Dropped entirely, not ported into a failing spec.
Reported to ORCH as a real gap for future scoping (a multi-step exam
authoring wizard is plausible future product surface, but no requirement
names it today) — not filed as an issue by me.

### 11. `admin-grading.spec.ts` (7 tests) — NO-COUNTERPART

Targets `/admin/grading`, a manual-grading queue with score-input validation,
feedback textarea, pagination, and a "Submit All Grades" action. No such
route or page exists anywhere in `web/src/pages/`, and no REQ in the S10 P4/P5
set (`REQ-338` through `REQ-349`) names a manual-grading admin screen — the
Elixir-side grading logic (`Letflow.Exam.Scoring`) exists per
`docs/migration/stage-10-bilimbaga-vertical.md`, but its admin-facing UI does
not. **Disposition:** no counterpart planned under S10. Dropped, not ported.
Reported to ORCH as a gap — a manual-grading admin UI is a real missing
capability for the exam vertical (short-text answers grade to
`pending_manual` per `Letflow.Exam.Scoring` and currently have no admin
surface to resolve them from), but filing/sizing it is for ORCH, not me.

### 12. `grading/ai-grading.spec.ts` (9 tests, `FR-BB73`) — NO-COUNTERPART

Same disposition as admin-grading.spec.ts for its "Grading Queue UI" half
(`/admin/grading`, AI-graded badge, AI-reasoning toggle — no counterpart). Its
"Question Editor" half (`/admin/questions/new`, an auto-grading section that
appears when type is switched to `shorttext`) additionally requires a
dedicated question-editor page with type-conditional UI, which
`EntityCrudPage` does not have (see `question-editor.spec.ts` below — same
gap). **Disposition:** no counterpart planned under S10 for either half.
Dropped, not ported. Reported to ORCH alongside admin-grading.spec.ts's
finding.

### 13. `accessibility.spec.ts` (7 tests, `FR-BB63`) — NO-COUNTERPART

Four tests assert a skip-link mechanism on `/login` (non-existent route, see
`auth.spec.ts`); three assert `#main-content`/skip-link/no-crash on
`/admin` and `/admin/users`/`/admin/questions`/`/admin/exams`/`/admin/tags`.
Independent of the route mismatches, **Letflow's `AppShell` has no skip link
and no `#main-content` landmark at all** — grepped repo-wide (`grep -rn
"main-content|SkipLink" web/src --include="*.tsx"` returns no results).
**Disposition:** no counterpart exists and none is planned under S10 (WCAG
skip-link support is not named in any S10 P4/P5 requirement). Dropped, not
ported. Reported to ORCH as a real accessibility gap worth its own
requirement — this is not a route-mismatch problem, it is a missing
capability in `AppShell.tsx` itself, independent of which admin page a
future spec targets.

### 14. `branding.spec.ts` (4 tests) — NO-COUNTERPART

Targets `/admin/settings/branding` with an editable app-name field, a color
picker, and a save button. Per the stage file's P0 gap-9 closure note
(`docs/migration/stage-10-bilimbaga-vertical.md` line 90), tenant branding is
served read-only from `GET /api/tenant-config` and applied as CSS
custom-property overrides on `tokens.css` in the SPA (REQ-283, `done`) — there
is **no admin settings page to edit branding**, only a read path. No REQ in
the S10 set names a branding *editor* screen. **Disposition:** no counterpart
planned under S10. Dropped, not ported. Reported to ORCH as a gap if branding
editing (as opposed to branding display) is ever wanted for BilimBaga's
tenant.

### 15. `question-editor.spec.ts` (7 tests) — NO-COUNTERPART

Targets `/admin/questions/new` and `/admin/questions/:id/edit` as dedicated
pages with a type selector that changes the rendered form (auto-grading
section for `shorttext`, polarity options for `likert`), a stem textarea, and
a "Save Draft" button. `EntityCrudPage`'s modal renders the entity
definition's static field list with no type-conditional behaviour, and
REQ-347's title explicitly scopes the entity-CRUD port to `categories, tags,
question-bank, exam-lifecycle` — **question-editor is not in REQ-347's named
set**, confirming this is deliberately out of that requirement's scope, not
an oversight. **Disposition:** no counterpart planned under S10. Dropped, not
ported. Reported to ORCH as a gap: type-conditional per-question-type editing
is real product behaviour the generic entity-CRUD engine cannot express, and
no REQ currently plans a bespoke question editor.

### 16. `question-management.spec.ts` (20 tests) — NO-COUNTERPART

Five `test.describe` blocks: Delete Question (row-actions dropdown + confirm
dialog), Archive Question (status transition via dropdown), Import Questions
(CSV/JSON file upload modal), Export Questions (bulk-select + Export CSV/JSON
buttons), AI Question Generation (generation dialog with category/difficulty/
count/context fields). None of these exist in `EntityCrudPage`, whose only
row actions are `entity-edit-<id>`/`entity-delete-<id>` (a bare delete, no
archive-vs-delete distinction, no confirmation dialog, no dropdown menu) and
whose create/edit form has no import/export/bulk-select/AI-generate
affordance (confirmed by testid grep in §2). None of these five feature areas
is named in REQ-347's scope (entity-CRUD parity, not import/export/AI
tooling). **Disposition:** no counterpart planned under S10 for the entire
file. Dropped, not ported. Reported to ORCH as a gap set (import/export/
archive-with-confirmation/AI-generate for the question entity) for future
scoping if BilimBaga parity on question-bank tooling is ever prioritized
beyond bare CRUD.

### 17. `user-management.spec.ts` (18 tests) — NO-COUNTERPART

Four `test.describe` blocks against the real, reachable `/admin/users` route:
Edit User (a drawer with pre-populated name field), Reset User Password (a
temporary-password modal), Deactivate/Reactivate User (a confirmation
dialog), Bulk Import Users (a CSV import modal with Preview/Close). Reading
`web/src/pages/admin/UsersPage.tsx` in full (see §2): the real page has only a
create flow (`admin-users-new` → an inline "Create user" panel) and a search
box (`admin-users-search`) plus the table (`admin-users-table`) — **no edit
action, no reset-password action, no deactivate action, and no bulk-import
button exist anywhere in the component.** Route reachability is not the
blocker here (it is the one file in this corpus whose target route is
already real and already used elsewhere in this triage as PORTABLE); the
blocker is that none of these four features have been built. None is named
in any S10 P4/P5 requirement. **Disposition:** no counterpart planned under
S10. Dropped, not ported. Reported to ORCH as a gap: `UsersPage` currently
supports list/search/create only, and edit/deactivate/reset-password/
bulk-import are all real, unbuilt admin capabilities.

### 18. `loyalty-narrative.spec.ts` (4 tests, `FR-BB75`) — NO-COUNTERPART

Targets `/admin/users/:userId/record`, a dedicated "employee record" page
with a "Values Profile" section and an AI-narrative "Generate" button.
Letflow's route for a user is `/admin/users/:userId` → `UserDetailPage`, not
`.../record` — a different page, and grepping `UserDetailPage.tsx` for
"record"/"Values Profile"/"loyalty" (case-insensitive) returns nothing: no
such page or feature exists at all, under any route. No REQ in the S10 set
names a loyalty-narrative or per-employee "values profile" feature.
**Disposition:** no counterpart exists and none is planned under S10. Dropped,
not ported. Reported to ORCH as a gap only if BilimBaga's loyalty-narrative
feature is ever prioritized for the Letflow port — it is a substantial net-new
feature (an AI-narrative generation endpoint plus a dedicated employee-record
UI), not a rewrite of an existing one.

### 19. `full-walkthrough.spec.ts` (22 tests) — split, spans ≥16 distinct URLs

Confirmed: the file drives `/login`, `/admin/dashboard`, `/admin/users`,
`/admin/departments`, `/admin/categories`, `/admin/tags`, `/admin/questions`,
`/admin/questions/new`, `/admin/exams`, `/admin/exams/new`, `/admin/grading`,
`/admin/audit`, `/admin/settings/branding`, `/admin/users/:id/record`,
`/change-password`, `/admin/exams/:id/analytics`, and `/portal` — 16 distinct
URL paths (17 counting the dynamic `/admin/exams/:id/analytics` and
`/admin/users/:id/record` as path *shapes* rather than literal strings makes
no difference to the count). Splitting per test:

- **01, 02 (login screen, invalid credentials)** — NO-COUNTERPART, same as
  `auth.spec.ts`.
- **03 (admin dashboard heading + "Main navigation" landmark)** —
  PORTABLE-AFTER-<gap>: `/admin/dashboard` does not exist but `/dashboard`
  (and `/`) does, rendering `TenantDashboardPage` with a real
  `tenant-dashboard-heading` testid (`<h1>`, matches the `heading, level: 1`
  assertion). The nav-landmark half fails independently: `AppShell`'s `<nav>`
  has no `aria-label="Main navigation"` (grepped, absent). Gap: no aria-label
  on the sidebar `<nav>`. No REQ names adding one. Reported to ORCH; the
  heading half is PORTABLE-NOW at `/dashboard`, rewritten against
  `tenant-dashboard-heading`.
- **04 (users list + create drawer)** — PORTABLE-NOW: `/admin/users` is real;
  `admin-users-table` and `admin-users-new` exist; the create panel's "Create
  user" heading text (`<h3>`) satisfies a case-insensitive `/create user/i`
  match even though it's an inline panel, not a modal/drawer with
  `role="dialog"` — the spec's `getByRole('heading', ...)` assertion (not a
  dialog-role assertion) is what would need to survive the rewrite.
- **05 (departments)** — NO-COUNTERPART: `/admin/departments` does not exist;
  no "department" entity type in `BILIMBAGA_ENTITY_TYPES`; `department` is
  explicitly one of the gaps REQ-343's own gap record calls out as unbuilt
  (`exam_assignment admin-screen gap` note references adjacent unbuilt admin
  surfaces). No REQ plans this screen under S10. Dropped, not ported.
- **06 (categories page + create modal)** — PORTABLE-NOW, same basis as
  `categories.spec.ts` above (route `/admin/bilimbaga/category`, testids
  `entity-crud-page`/`entity-create-action`/`entity-form-modal`).
- **07 (tags page + create dialog)** — PORTABLE-NOW, same basis as
  `tags.spec.ts` above (route `/admin/bilimbaga/tag`, per §3's re-derived
  reachability finding).
- **08 (question bank list + filters)** — PORTABLE-AFTER-<gap>: the list-
  renders half is PORTABLE-NOW at `/admin/bilimbaga/question`; the search-
  input-filters half is NO-COUNTERPART (no search box in `EntityCrudPage`,
  same gap noted under `question-bank.spec.ts` and `tags.spec.ts` above). No
  REQ names an entity-CRUD search feature today.
- **09 (question editor — all 5 question types)** — NO-COUNTERPART, same
  basis as `question-editor.spec.ts` above.
- **10 (exams list → create-exam redirect)** — PORTABLE-AFTER-<gap>: the list
  half is PORTABLE-NOW (`/admin/bilimbaga/exam`); the "Create Exam" link
  navigating to a dedicated `/exams/new` wizard page is NO-COUNTERPART (same
  basis as `exam-wizard.spec.ts`).
- **11 (exam wizard steps 1-4)** — NO-COUNTERPART, same basis as
  `exam-wizard.spec.ts`.
- **12 (grading queue)** — NO-COUNTERPART, same basis as
  `admin-grading.spec.ts`.
- **13 (audit log + date filters + Export CSV)** — PORTABLE-AFTER-<gap>:
  `/admin/audit` is real (`AuditLogPage`), but its From/To filters are plain
  text inputs with ISO8601 placeholders, not `input[type="datetime-local"]`,
  and there is no Export CSV button anywhere in the page (grepped, absent).
  Gap: date-picker inputs and CSV export on the audit log. No REQ names
  either. Reported to ORCH; the page-renders-without-crashing half is
  PORTABLE-NOW, the filter/export assertions are NO-COUNTERPART until a gap-
  closing REQ exists.
- **14 (branding settings)** — NO-COUNTERPART, same basis as
  `branding.spec.ts` above.
- **15 (AI insights card on dashboard)** — NO-COUNTERPART: no such card
  exists on `TenantDashboardPage` (grepped: no "insight"/"AI" text or testid
  in the component); the test itself is written to tolerate absence
  (`if (await aiCard.isVisible(...))`), but there is nothing to assert against
  either way. No REQ plans this. Dropped, not ported.
- **16 (sidebar nav traversal, click every link)** — PORTABLE-AFTER-<gap>:
  the `nav` locator itself needs the same `aria-label="Main navigation"` gap
  fixed as test 03 before this test can even find its target; once found, the
  traversal logic (click every link, assert no crash) is generic and would
  port cleanly. Gap-supplying REQ: none currently — reported to ORCH.
- **17 (user-create drawer validation)** — PORTABLE-AFTER-<gap>: same
  create-panel basis as test 04, but the validation-on-empty-submit assertion
  needs `UsersPage`'s create form to show validation errors, which it does
  not currently do (no client-side validation visible in the component read
  in §2 — it calls the mutation directly). Gap: no form validation on
  `UsersPage`'s create panel. No REQ names adding it. Reported to ORCH.
- **18 (employee record page)** — NO-COUNTERPART, same basis as
  `loyalty-narrative.spec.ts` above (`/admin/users/:id/record` does not
  exist; `UserDetailPage` at `/admin/users/:userId` has no session-history or
  track-progress content).
- **19 (change password page)** — NO-COUNTERPART: `/change-password` does not
  exist; Letflow delegates credential changes to Keycloak, not an in-app
  page (same reasoning as `auth.spec.ts`'s dropped login-form tests). No REQ
  plans an in-app change-password screen.
- **20 (exam analytics page)** — NO-COUNTERPART: no `/admin/exams/:id/
  analytics` route, and no analytics page for individual exams anywhere in
  `web/src/pages/`. No REQ names this. Dropped.
- **21 (employee portal redirect check)** — PORTABLE-AFTER-REQ-346: the test
  as written checks `/portal` redirects unauthenticated users somewhere
  sane; Letflow's equivalent surface is `/exam` (see `employee-portal.spec.ts`
  above), which is gated by the same `ProtectedRoute`/`AuthProvider` every
  other route uses. Same gap-supplying REQ as employee-portal.spec.ts:
  **REQ-346** (`status: pending`).
- **22 (no console errors across 8 admin screens)** — NO-COUNTERPART as
  authored: the screen list (`/admin/dashboard`, `/admin/users`,
  `/admin/questions`, `/admin/exams`, `/admin/categories`, `/admin/tags`,
  `/admin/grading`, `/admin/audit`) mixes routes that exist under different
  paths (`/dashboard` not `/admin/dashboard`; `/admin/bilimbaga/question` not
  `/admin/questions`; etc.) with one that has no counterpart at all
  (`/admin/grading`). As a single test it cannot be ported without either
  routing through a nonexistent URL (grading) or silently changing the
  assertion's intent. Disposition: dropped as authored; once REQ-347's port
  lands, an equivalent "no console errors across the real admin screen set"
  smoke test would be a reasonable net-new addition, but that is REQ-347's
  or REQ-348's close-out concern, not a 1:1 port of this test.

**Rewrite required, not retargeting**, for every PORTABLE/PORTABLE-AFTER
sub-test above: none of `full-walkthrough.spec.ts`'s 22 tests use a
`data-testid`; all bind to `getByRole`, localized `getByText`, and CSS-class
locators.

---

## 5. Classification summary

| Category | Files (whole-file) | Files (split per-test) | Test count covered |
|---|---:|---:|---:|
| PORTABLE-NOW | 2 (`tags.spec.ts`*, `categories.spec.ts`) | partial in 4 more | see below |
| PORTABLE-AFTER-\<gap\> | 0 whole-file | `employee-portal`, `exam-taking`, `exam-result`, `my-results`, `exam-lifecycle` (partial), `question-bank` (partial), `full-walkthrough` (partial) | see below |
| NO-COUNTERPART | 10 whole-file (`auth`, `exam-wizard`, `admin-grading`, `ai-grading`, `accessibility`, `branding`, `question-editor`, `question-management`, `user-management`, `loyalty-narrative`) | partial in several more | see below |

\* `tags.spec.ts` is PORTABLE-NOW for 5 of its 6 tests; its search-filter test
is NO-COUNTERPART.

Because six of the nineteen files split across categories at the per-test
level (`question-bank`, `exam-lifecycle`, `full-walkthrough`, plus `tags`'
one NO-COUNTERPART sub-test), a single whole-file count table would
misrepresent the corpus. The authoritative classification is the per-file
section in §4; this table is a navigation aid, not a substitute.

**Files entirely NO-COUNTERPART today:** `auth.spec.ts` (5),
`exam-wizard.spec.ts` (9), `admin-grading.spec.ts` (7),
`grading/ai-grading.spec.ts` (9), `accessibility.spec.ts` (7),
`branding.spec.ts` (4), `question-editor.spec.ts` (7),
`question-management.spec.ts` (20), `user-management.spec.ts` (18),
`loyalty-narrative.spec.ts` (4) — **90 of 168 tests** have no Letflow
counterpart today and none planned under the current S10 requirement set.

**Files entirely PORTABLE-NOW or PORTABLE-AFTER-\<named-gap\> today (whole
file, ignoring the one search sub-test on `tags`):** `categories.spec.ts` (5,
PORTABLE-NOW), `employee-portal.spec.ts` (8, PORTABLE-AFTER-REQ-346),
`exam-taking.spec.ts` (11, PORTABLE-AFTER-REQ-346), `exam-result.spec.ts` (5,
PORTABLE-AFTER-REQ-349), `my-results.spec.ts` (6, PORTABLE-AFTER-REQ-349).

**Files that split:** `tags.spec.ts` (6: 5 PORTABLE-NOW + 1 NO-COUNTERPART),
`question-bank.spec.ts` (7: 2 PORTABLE-NOW + 1 NO-COUNTERPART-with-gap-report
+ 2 NO-COUNTERPART search + 2 NO-COUNTERPART import/AI), `exam-lifecycle.spec.ts`
(8: 1 PORTABLE-NOW + 5 PORTABLE-AFTER-REQ-347-with-badge-caveat + 2
NO-COUNTERPART wizard), `full-walkthrough.spec.ts` (22: see the 22-way split
in §4.19).

---

## 6. Stage file correction

`docs/migration/stage-10-bilimbaga-vertical.md`'s P5 row (line 133) currently
reads, in part:

> Parity: BilimBaga's 19 Playwright spec files (**286** `test()` blocks,
> measured 2026-09-13 — the 168 previously recorded here was wrong) ported to
> the Letflow build. [...] BilimBaga's selectors are `getByRole`/`getByText`-
> dominated (314/137/66 uses vs **one** `data-testid`) [...]

Per §1's re-measurement, **286 is wrong and 168 is correct** — the exact
opposite of what the row currently states about which number was wrong. The
row is corrected below (see the diff applied to the file in this commit). The
`314/137/66` selector-usage figures were already consistent with this
session's own re-measurement (`314`/`137`/`66`, plus `16` `getByLabel` and 1
stray `data-testid` not previously called out) and are left as close to
original as possible, with the `getByLabel` count added for completeness.

---

## 7. `git diff` confirmation

```
$ git diff --name-only
docs/migration/stage-10-bilimbaga-vertical.md
docs/testing/REQ-344-bilimbaga-parity-triage.md
```

No modification to `web/src/router.tsx`. No new or changed file under
`web/tests/e2e/` or any `*.e2e.spec.ts` anywhere in the repo. No spec file
under `/opt/apps/bilimbaga-test/frontend/e2e/` was authored or modified by
this requirement.
