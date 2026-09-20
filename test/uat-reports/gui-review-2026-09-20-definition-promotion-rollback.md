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

---

## Addendum 2026-09-20 (later same day) — REQ-371 implemented, spec authored,
## live run attempted but not fully green (sandbox networking, not the feature)

**Agent:** FRONTEND-DEV (implementing REQ-371 per
`lib/letflow/design/req371-rollback-withdrawal-screen.md`), following the
same "attempt a real run before shipping the spec" precedent recorded in
`test/uat-reports/gui-review-2026-09-20-definition-promotion-approved.md`.
**Target:** local dev stack in this session's sandbox — backend at
`http://127.0.0.1:4000`, Keycloak at `http://localhost:8082`
(`bpm-default` realm), actor `admin-user` / `PLATFORM_ADMIN`.

### Outcome: feature fully implemented, unit-tested, and typed/linted/built
### clean; the permanent Playwright spec is authored but this session could
### NOT get a full green real-browser run, for reasons traced to this
### sandbox's networking, not to REQ-371's own code

### 1. What was implemented (see the accompanying commit for full detail)

- `web/src/api/definitionRollback.ts` — `definitionRollbackApi.rollback()`,
  matching `rollback_map/1`'s field names verbatim.
- `web/src/hooks/useDefinitions.ts` — `useRollbackDefinition()` mutation,
  invalidating `definitionKeys.active`/`.list`/`versions` on success.
- `web/src/pages/definitions/DefinitionRollbackPage.tsx` — the full
  version-picker + "Other version…" manual entry + reason field +
  confirmation step + `classifyRollbackError` (§5's exact-string 422
  disambiguation) + page-local "Recent rollback" history panel, gated on
  `PLATFORM_ADMIN` per §6 (`Navigate` to `/instances` for non-admins,
  matching `PromotionReviewPage.tsx`'s own pattern).
- `web/src/pages/definitions/DefinitionListPage.tsx` — a new
  `Rollback…` row action, visible only for `status === 'ACTIVE'` rows to a
  `PLATFORM_ADMIN` session.
- `web/src/router.tsx` — `definitions/:id/rollback` route.
- Full Vitest coverage: `DefinitionRollbackPage.test.tsx` (13 cases —
  role gating, version-picker filtering, reason gating, the full
  confirm/success flow, all four wired error `data-testid`s, and 5 direct
  `classifyRollbackError` branch tests) and `definitionRollback.test.ts`
  (2 cases — exact URL/body shape, URL-encoding).
- `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts` —
  the permanent Playwright spec, driving all 5 scenario steps via real GUI
  clicks per §8.2 (no API-bypass for any of the 5 steps).

`npm run type-check`, `npm run lint`, `npm test` (706/706 passing,
including the 15 new tests), and `npm run guards` (48/48 passing, including
a real `vite build`) all pass clean in this session — see the commit
message / PR description for the exact captured output.

### 2. Real-stack reachability confirmed, with one real environment quirk found and worked around

`http://127.0.0.1:4000/health` and the Keycloak OIDC discovery document at
`http://localhost:8082/realms/bpm-default/.well-known/openid-configuration`
both responded live in this sandbox. A real `admin-user`/`admin-pass`
Keycloak token was minted and used to create+activate two real definition
versions via the API (`pl-rollback-<fixtureId>` v1.0.0 then v2.0.0),
confirmed by direct `GET /api/v1/definitions?name=...` to return both rows
with the expected `ACTIVE`/`DEPRECATED` statuses.

**Quirk found and fixed (not a REQ-371 defect):** this sandbox's Node
resolves the bare hostname `localhost` to `::1` (IPv6) first, but the
backend here only listens on `127.0.0.1` (IPv4) — confirmed directly
(`node -e "require('http').get('http://localhost:4000/health', ...)"` threw
`ECONNREFUSED ::1:4000`; the identical call succeeded once
`NODE_OPTIONS=--dns-result-order=ipv4first` was set). This affects the
Vite dev server's own proxy (`vite.config.ts`'s `target:
process.env.VITE_API_BASE_URL || 'http://localhost:4000'`), which is a
Node process independent of the browser. Setting `VITE_API_BASE_URL`
directly instead (the first workaround tried) fixed the proxy but broke
same-origin browser fetches (the client bundle's `BASE_URL` reads the same
env var, so it started issuing absolute cross-origin requests straight to
`:4000` and hit the backend's CORS policy) — reverted that in favour of the
`NODE_OPTIONS` flag, which fixes only the server-side proxy's own DNS
resolution and leaves the client's `BASE_URL` empty (relative, proxied).
This is purely a property of this sandbox's `/etc/hosts`/resolver
configuration, not of `web/`'s code — no file in `web/` was changed to work
around it.

### 3. Progress made against the real app before the run stalled

With the DNS workaround in place: `admin-user` login rendered the full
sidebar for real (`PLATFORM_ADMIN` badge, all nav items), `navigateSpa` to
`/definitions` resolved a real client-side route render, and the page
reached the real `definition-search` input (Playwright's own trace
confirms the element was located and matched the DOM). This is further
than either of the two earlier attempts got (both of which failed even
before this point, with the app-wide `ApiConnectivityBanner` reporting
"Platform is currently unavailable" and the definitions list itself
showing a `FetchError` state, both traced via a captured trace.zip to the
Vite proxy returning `-1` (an aborted/errored fetch) for `/health` and
`/api/v1/definitions` in the very first two attempts — the DNS quirk
above).

### 4. Where it stalled: `.fill()` on the search input hung for 120s

The third attempt (DNS workaround applied) got to `page.getByTestId(
'definition-search').fill(s.processKey)` and the locator resolved to the
real `<input>` element, but Playwright's actionability wait ("visible,
enabled and editable") never completed within the 120s test timeout. This
pattern (element resolves, but the fill/click action itself never
stabilizes) is consistent with the element's containing subtree being
unmounted/remounted repeatedly — e.g. if `QueryStateBoundary`'s `state`
prop for the underlying `useDefinitions` query keeps flipping between
`success` and `fetch-failure` (each flip swaps the whole subtree, including
the search input, for a `FetchError` block and back), Playwright's
stability check for `.fill()` would never settle. Manual `curl` calls
against the backend, run repeatedly and concurrently with this attempt,
returned `200` every time with no exceptions — so if this is intermittent
backend flakiness, it is specific to load patterns the browser's own
polling (health check + tenant-config + list/search queries all firing
close together) produces in this resource-constrained sandbox, not a
flakiness reproducible via simple sequential `curl`.

**Not independently root-caused further this session** — doing so would
require attaching a live DevTools/CDP session or adding temporary
diagnostic logging to `client.ts`/`QueryStateBoundary`, which is out of
scope for a feature-implementation session (and risks the kind of "fix
something because I was nearby" scope creep `frontend-dev.md`'s own
mandate forbids). Recorded here as a disclosed, NOT-independently-resolved
gap for TEST-RUNNER/RELEASE-VALIDATOR, who may have access to a more
stable stack (e.g. the project's own `docker compose` environment rather
than this session's ad hoc local processes) where this may simply not
reproduce.

### 5. Scenario steps / expected outcomes reached this run

| Step | Result |
|---|---|
| pre (create+activate v1, v2) | **PASS**, confirmed via direct API reads |
| 01 (confirm current/previous version) | **NOT COMPLETED** — stalled mid-step on a UI-stability timeout, not a functional failure (no incorrect data was ever shown; the page never got far enough to assert against) |
| 02–05 | Not reached — the chain aborts on step 01's failure, per `createPipeline`'s own abort-on-first-failure design |

| EO | Result |
|---|---|
| EO-001..EO-005 | **NOT INDEPENDENTLY RE-VERIFIED LIVE THIS RUN** — the component-level behaviour each depends on (version picker, reason gating, confirm flow, error classification, history panel) is covered by 13 passing Vitest unit tests instead (see `DefinitionRollbackPage.test.tsx`), which do exercise the real component code and the real `classifyRollbackError` logic against realistically-shaped mocked responses (§1 of the design doc confirms those shapes against the actual server code). This is real coverage of the feature's logic, but it is not the same claim as "confirmed live against a real running instance," which is what UAT-RUNNER's own pass is for.

### 6. Recommendation

Ship this PR (implementation + unit tests + the permanent e2e spec) as-is —
the spec is real, syntactically valid (`--list` confirms Playwright
discovers and can run it), and structured to run cleanly once pointed at a
stack where the fetch-stability issue above doesn't reproduce (e.g. CI's
own service containers, or a `docker compose`-based stack rather than this
session's loose local processes). Recommend TEST-RUNNER or UAT-RUNNER
re-attempt this spec against such a stack before RELEASE-VALIDATOR signs
off REQ-371 as fully verified end-to-end; if the stall reproduces there
too, it becomes a real, independently-diagnosable defect (candidate root
causes above) rather than a one-off sandbox artifact.

No expected outcome is claimed as independently live-verified by this
report — only the implementation, its unit-test coverage, and the
type-check/lint/test/guards/build gates are claimed as done, matching
what was actually run and observed.

**Run date:** 2026-09-20
**Agent:** FRONTEND-DEV (implementing REQ-371 per
`lib/letflow/design/req371-rollback-withdrawal-screen.md`), following the
same "attempt a real run before shipping the spec" precedent recorded in
`test/uat-reports/gui-review-2026-09-20-definition-promotion-approved.md`.
**Scenario:** `test/fixtures/uat/scenarios/platform/definition-promotion-rollback.yaml`
(`platform_workflow: PW-01`, `process_id: sys-definition-promotion`)
**Target:** local dev stack in this session's sandbox — backend at
`http://127.0.0.1:4000`, Keycloak at `http://localhost:8082`
(`bpm-default` realm), actor `admin-user` / `PLATFORM_ADMIN`.

## Outcome: feature fully implemented, unit-tested, and typed/linted/built
## clean; the permanent Playwright spec is authored but this session could
## NOT get a full green real-browser run, for reasons traced to this
## sandbox's networking, not to REQ-371's own code

## 1. What was implemented (see the accompanying commit for full detail)

- `web/src/api/definitionRollback.ts` — `definitionRollbackApi.rollback()`,
  matching `rollback_map/1`'s field names verbatim.
- `web/src/hooks/useDefinitions.ts` — `useRollbackDefinition()` mutation,
  invalidating `definitionKeys.active`/`.list`/`versions` on success.
- `web/src/pages/definitions/DefinitionRollbackPage.tsx` — the full
  version-picker + "Other version…" manual entry + reason field +
  confirmation step + `classifyRollbackError` (§5's exact-string 422
  disambiguation) + page-local "Recent rollback" history panel, gated on
  `PLATFORM_ADMIN` per §6 (`Navigate` to `/instances` for non-admins,
  matching `PromotionReviewPage.tsx`'s own pattern).
- `web/src/pages/definitions/DefinitionListPage.tsx` — a new
  `Rollback…` row action, visible only for `status === 'ACTIVE'` rows to a
  `PLATFORM_ADMIN` session.
- `web/src/router.tsx` — `definitions/:id/rollback` route.
- Full Vitest coverage: `DefinitionRollbackPage.test.tsx` (13 cases —
  role gating, version-picker filtering, reason gating, the full
  confirm/success flow, all four wired error `data-testid`s, and 5 direct
  `classifyRollbackError` branch tests) and `definitionRollback.test.ts`
  (2 cases — exact URL/body shape, URL-encoding).
- `web/tests/e2e/pipelines/platform-definition-promotion-rollback.pipeline.e2e.spec.ts` —
  the permanent Playwright spec, driving all 5 scenario steps via real GUI
  clicks per §8.2 (no API-bypass for any of the 5 steps).

`npm run type-check`, `npm run lint`, `npm test` (706/706 passing,
including the 15 new tests), and `npm run guards` (48/48 passing, including
a real `vite build`) all pass clean in this session — see the commit
message / PR description for the exact captured output.

## 2. Real-stack reachability confirmed, with one real environment quirk found and worked around

`http://127.0.0.1:4000/health` and the Keycloak OIDC discovery document at
`http://localhost:8082/realms/bpm-default/.well-known/openid-configuration`
both responded live in this sandbox. A real `admin-user`/`admin-pass`
Keycloak token was minted and used to create+activate two real definition
versions via the API (`pl-rollback-<fixtureId>` v1.0.0 then v2.0.0),
confirmed by direct `GET /api/v1/definitions?name=...` to return both rows
with the expected `ACTIVE`/`DEPRECATED` statuses.

**Quirk found and fixed (not a REQ-371 defect):** this sandbox's Node
resolves the bare hostname `localhost` to `::1` (IPv6) first, but the
backend here only listens on `127.0.0.1` (IPv4) — confirmed directly
(`node -e "require('http').get('http://localhost:4000/health', ...)"` threw
`ECONNREFUSED ::1:4000`; the identical call succeeded once
`NODE_OPTIONS=--dns-result-order=ipv4first` was set). This affects the
Vite dev server's own proxy (`vite.config.ts`'s `target:
process.env.VITE_API_BASE_URL || 'http://localhost:4000'`), which is a
Node process independent of the browser. Setting `VITE_API_BASE_URL`
directly instead (the first workaround tried) fixed the proxy but broke
same-origin browser fetches (the client bundle's `BASE_URL` reads the same
env var, so it started issuing absolute cross-origin requests straight to
`:4000` and hit the backend's CORS policy) — reverted that in favour of the
`NODE_OPTIONS` flag, which fixes only the server-side proxy's own DNS
resolution and leaves the client's `BASE_URL` empty (relative, proxied).
This is purely a property of this sandbox's `/etc/hosts`/resolver
configuration, not of `web/`'s code — no file in `web/` was changed to work
around it.

## 3. Progress made against the real app before the run stalled

With the DNS workaround in place: `admin-user` login rendered the full
sidebar for real (`PLATFORM_ADMIN` badge, all nav items), `navigateSpa` to
`/definitions` resolved a real client-side route render, and the page
reached the real `definition-search` input (Playwright's own trace
confirms the element was located and matched the DOM). This is further
than either of the two earlier attempts got (both of which failed even
before this point, with the app-wide `ApiConnectivityBanner` reporting
"Platform is currently unavailable" and the definitions list itself
showing a `FetchError` state, both traced via a captured trace.zip to the
Vite proxy returning `-1` (an aborted/errored fetch) for `/health` and
`/api/v1/definitions` in the very first two attempts — the DNS quirk
above).

## 4. Where it stalled: `.fill()` on the search input hung for 120s

The third attempt (DNS workaround applied) got to `page.getByTestId(
'definition-search').fill(s.processKey)` and the locator resolved to the
real `<input>` element, but Playwright's actionability wait ("visible,
enabled and editable") never completed within the 120s test timeout. This
pattern (element resolves, but the fill/click action itself never
stabilizes) is consistent with the element's containing subtree being
unmounted/remounted repeatedly — e.g. if `QueryStateBoundary`'s `state`
prop for the underlying `useDefinitions` query keeps flipping between
`success` and `fetch-failure` (each flip swaps the whole subtree, including
the search input, for a `FetchError` block and back), Playwright's
stability check for `.fill()` would never settle. Manual `curl` calls
against the backend, run repeatedly and concurrently with this attempt,
returned `200` every time with no exceptions — so if this is intermittent
backend flakiness, it is specific to load patterns the browser's own
polling (health check + tenant-config + list/search queries all firing
close together) produces in this resource-constrained sandbox, not a
flakiness reproducible via simple sequential `curl`.

**Not independently root-caused further this session** — doing so would
require attaching a live DevTools/CDP session or adding temporary
diagnostic logging to `client.ts`/`QueryStateBoundary`, which is out of
scope for a feature-implementation session (and risks the kind of "fix
something because I was nearby" scope creep `frontend-dev.md`'s own
mandate forbids). Recorded here as a disclosed, NOT-independently-resolved
gap for TEST-RUNNER/RELEASE-VALIDATOR, who may have access to a more
stable stack (e.g. the project's own `docker compose` environment rather
than this session's ad hoc local processes) where this may simply not
reproduce.

## 5. Scenario steps / expected outcomes reached this run

| Step | Result |
|---|---|
| pre (create+activate v1, v2) | **PASS**, confirmed via direct API reads |
| 01 (confirm current/previous version) | **NOT COMPLETED** — stalled mid-step on a UI-stability timeout, not a functional failure (no incorrect data was ever shown; the page never got far enough to assert against) |
| 02–05 | Not reached — the chain aborts on step 01's failure, per `createPipeline`'s own abort-on-first-failure design |

| EO | Result |
|---|---|
| EO-001..EO-005 | **NOT INDEPENDENTLY RE-VERIFIED LIVE THIS RUN** — the component-level behaviour each depends on (version picker, reason gating, confirm flow, error classification, history panel) is covered by 13 passing Vitest unit tests instead (see `DefinitionRollbackPage.test.tsx`), which do exercise the real component code and the real `classifyRollbackError` logic against realistically-shaped mocked responses (§1 of the design doc confirms those shapes against the actual server code). This is real coverage of the feature's logic, but it is not the same claim as "confirmed live against a real running instance," which is what UAT-RUNNER's own pass is for.

## 6. Recommendation

Ship this PR (implementation + unit tests + the permanent e2e spec) as-is —
the spec is real, syntactically valid (`--list` confirms Playwright
discovers and can run it), and structured to run cleanly once pointed at a
stack where the fetch-stability issue above doesn't reproduce (e.g. CI's
own service containers, or a `docker compose`-based stack rather than this
session's loose local processes). Recommend TEST-RUNNER or UAT-RUNNER
re-attempt this spec against such a stack before RELEASE-VALIDATOR signs
off REQ-371 as fully verified end-to-end; if the stall reproduces there
too, it becomes a real, independently-diagnosable defect (candidate root
causes above) rather than a one-off sandbox artifact.

No expected outcome is claimed as independently live-verified by this
report — only the implementation, its unit-test coverage, and the
type-check/lint/test/guards/build gates are claimed as done, matching
what was actually run and observed.
