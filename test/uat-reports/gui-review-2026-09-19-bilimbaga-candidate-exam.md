# GUI review pilot — bilimbaga-candidate-timed-exam-autograde

**Run date:** 2026-09-19
**Agent:** UAT-RUNNER (pilot run, expanded authority per ORCH dispatch)
**Scenario:** `test/fixtures/uat/scenarios/bilimbaga/candidate-timed-exam-autograde.yaml`
(id `bilimbaga-candidate-timed-exam-autograde`, closed under ISS-0690)
**Target:** `https://qa.bizdala.com/` (environment: qa), actor `candidate-user` /
`CANDIDATE` role, per `ai-dala-infra/scripts/qa-login.sh`

## Outcome: BLOCKED before any exam screen was reached — invalid QA credential

The pilot's whole premise — a human-style visual review of the real exam-taking
screens, followed by a permanent regression spec encoding only verified-correct
behaviour — could not proceed past sign-in. The `candidate-user` credential handed to
this run does not authenticate against QA's Keycloak realm at all. This is not a
selector problem, a timing problem, or a missing frontend feature; it is confirmed
**below the browser, at the OAuth token-endpoint level**, so no amount of Playwright
selector tuning would have gotten past it.

### What was actually run (not simulated)

1. `web/` had no `node_modules` in this worktree — ran `npm install` (607 packages) and
   `npx playwright install chromium` (already present) before anything else could
   execute.
2. Read `web/tests/e2e/exam-taking.e2e.spec.ts`, `exam-result.e2e.spec.ts`, and
   `web/tests/e2e/pipelines/onboarding-wizard.pipeline.e2e.spec.ts` for this repo's real
   selectors/conventions, then read `web/src/pages/exam/ExamListPage.tsx` and
   `ExamSessionPage.tsx` directly to confirm the actual `data-testid` hooks
   (`exam-list-page`, `exam-list-start-<id>`, `exam-session-page`,
   `exam-question-<id>`, `exam-option-<id>`, `exam-short-text-input`,
   `exam-save-status`, `exam-submit-action`, `exam-result-page`,
   `exam-result-pending`, `exam-result-score`) and that the countdown lives in
   `PageLayout`'s title (`exam.session.remainingTime`, format `MM:SS`), sourced only
   from `remainingSeconds`, itself re-anchored on every autosave response
   (`ExamSessionPage.tsx:181-215`) — never a free-running client timer past what the
   server last confirmed.
3. Wrote a throwaway Node/Playwright script (real Chromium, `headless: true`, no
   assertions — plain navigation + `page.screenshot()`), run via plain `node` against
   `https://qa.bizdala.com` directly (not through `web/playwright.config.ts`'s
   `webServer`, which spins a *local* dev server — irrelevant here since the target is
   a real deployed instance). It:
   - navigated to `/` and followed the real off-origin redirect to
     `https://auth.qa.bizdala.com/realms/bpm-default/protocol/openid-connect/auth...`
     (confirmed: this is Keycloak's own hosted login page, "LETFLOW DEFAULT REALM",
     same mechanism `web/tests/e2e/helpers.ts`'s `loginViaRealOidcRedirect` exercises)
   - filled `#username` = `candidate-user`, `#password` = the value handed to this run,
     clicked `Sign In`
4. **Result:** Keycloak's own login form re-rendered with a real, first-party error:
   **"Invalid username or password."** — reproduced identically on a second, fully
   independent run (fresh script invocation, fresh session).

### Independent confirmation at the protocol level (rules out browser/script bugs)

Re-fetched the credential fresh from the named source (not reused from the dispatch —
refetched live, in case of drift between what was handed to this run and what is
currently seeded):

```
$ bash ai-dala-infra/scripts/qa-login.sh candidate-user
URL:      https://qa.bizdala.com/
Username: candidate-user
Role:     CANDIDATE
Password: <same 32-char value the dispatch had already provided>
```

Then bypassed the browser and UI entirely — a direct Resource Owner Password Credentials
grant straight against Keycloak's token endpoint:

```
$ curl -s -X POST 'https://auth.qa.bizdala.com/realms/bpm-default/protocol/openid-connect/token' \
    -d 'client_id=letflow-web' -d 'grant_type=password' -d 'username=candidate-user' \
    --data-urlencode 'password=<the seeded value>'
{"error":"invalid_grant","error_description":"Invalid user credentials"}
```

To rule out a realm-wide or Keycloak-wide outage (which would make this a routine
"environment down" report rather than a credential-specific one), fetched and tried
`admin-user`'s seeded credential the same way, against the same realm and token
endpoint:

```
$ bash ai-dala-infra/scripts/qa-login.sh admin-user   # fresh fetch, same host/script
$ curl ... -d 'username=admin-user' --data-urlencode 'password=<admin-user value>'
{"access_token":"eyJhbGc...", ...}     # succeeds, full JWT returned
```

`admin-user` authenticates cleanly against the same realm, same token endpoint, same
client, at the same moment. **Keycloak itself is healthy and reachable; the
`candidate-user` account's password specifically does not match what
`seeded-users.env` on `ubuntu-16gb-nbg1-1` currently reports for it** — i.e. real
drift between the deployed secrets file (`KC_SEED_CANDIDATE_USER_PASSWORD`) and the
actual Keycloak user record, or the account is disabled/locked in a way Keycloak
folds into the same generic `invalid_grant` message (a required-action / disabled-user
Keycloak error was not distinguishable from this response alone — diagnosing which of
those two it is would need Keycloak admin-console/API access this run does not have,
since `admin-user`'s token is an application-level JWT, not a Keycloak
realm-management credential).

### Why this run stopped here rather than working around it

- No second `CANDIDATE`-role seeded user exists (`qa-login.sh`'s own `ROLE_FOR` map has
  exactly one: `candidate-user`).
- The pilot's whole point was genuine human-style visual review of real screens before
  writing a spec — there is no honest substitute for that once sign-in itself is
  broken; an API-only path around it (e.g. minting a token some other way) would
  reintroduce exactly the "blind, credential-hacked walkthrough" the pilot exists to
  avoid, and still wouldn't exercise the real GUI sign-in step the scenario's own step 1
  names.
- Nothing was left dirty in QA: no exam session was ever created (sign-in never
  succeeded), so the scenario's own cleanup note ("cancel the exam session if the run
  doesn't complete it") has nothing to act on this run.

### Screens reviewed

| # | Screen | Judgment |
|---|---|---|
| 1 | Keycloak hosted login form (`https://auth.qa.bizdala.com/realms/bpm-default/...`) | Renders correctly — "LETFLOW DEFAULT REALM" heading, username/password fields, visible error banner on failed auth. Not a Letflow `web/` defect; this is Keycloak's own hosted UI working as designed. |
| 2–8 (exam list, in-progress, countdown, questions, submit, score) | **Not reached.** No judgment possible — reporting "looks fine" without having seen them would violate this whole pilot's founding principle. |

Two screenshots were captured as evidence, at:
`web/tests/screenshots/pipelines/bilimbaga-candidate-exam-pilot/` (gitignored, local
only, same convention every other pipeline spec's `scratch/`/screenshot output
follows — not committed):
- `02-login-form.png` — clean login form, pre-submit
- `03-error-state.png` — post-submit, `candidate-user` filled, "Invalid username or
  password." shown under the username field

### No defect fixed, no spec written

No `web/` code defect was found — the one screen reached (Keycloak's hosted login)
rendered and behaved correctly; the failure is a QA-environment seeded-credential
problem, outside `web/`'s own code and outside anything ORCHESTRATOR.md §10's
single-file/no-migration/no-tenant-data-path sizing rule could apply to (there is no
code change to make). Per this pilot's own instructions, no permanent
`*.pipeline.e2e.spec.ts` was written and the scenario YAML's `pipeline_test:` key was
**not** added — writing either from an unverified walkthrough would be exactly the
"blind spec with hardcoded assertions" this pilot exists to prevent. The scenario stays
BLOCKED, same as it was before this run, with a sharper, protocol-level reason recorded
now instead of the prior generic "UNBUILT_FEATURE" placeholder.

**Recommended follow-up (for ORCH to file via the queue, per
`docs/agents/protocols/ISSUE_QUEUE.md` — this run does not have `letflow-queue`
access):** "QA `candidate-user` seeded Keycloak credential (`bpm-default` realm,
`ubuntu-16gb-nbg1-1`'s `seeded-users.env` / `KC_SEED_CANDIDATE_USER_PASSWORD`) does not
authenticate — confirmed via direct token-endpoint grant, `admin-user`'s credential
confirmed working the same way at the same moment, ruling out a realm-wide outage."
Severity: BLOCKER for this pilot and for all 17 scenarios still to be piloted that need
a non-admin actor — this is squarely in scope for
`bilimbaga-candidate-timed-exam-autograde` itself (`actors.candidate:
actor-bilimbaga-candidate`) and would block any of the other 3 bilimbaga scenarios that
also need a `CANDIDATE` actor the same way.

## Process-friction feedback (the most important part of this report)

This is the first run of the new "genuine visual review before writing a spec" process,
trialed on one scenario before scaling to 17 more. Concrete friction observed, in the
order it was hit:

1. **`web/` had no installed dependencies in this worktree.** `npm install` (607
   packages, ~20s) and a Playwright browser check were both needed before a single line
   of the actual task could run. Worth deciding up front whether UAT-RUNNER pilots
   should assume a pre-warmed `web/` or budget for this every time — it's cheap but not
   free, and it's easy for an agent to burn a turn diagnosing "why does nothing work"
   before realizing it's just a missing `npm install`.

2. **Playwright's own `test`-runner/`webServer` machinery actively gets in the way for
   an against-a-real-remote-instance pilot.** `web/playwright.config.ts`'s `webServer`
   block unconditionally tries to spawn a *local* `npm run dev` server keyed off
   `E2E_BASE_URL`'s port — pointing that at `https://qa.bizdala.com` (no explicit port,
   HTTPS) would have needed either fighting the config or overriding it. Driving a
   throwaway script via plain `node` + `require('@playwright/test').chromium` sidestepped
   this cleanly and is worth naming explicitly as the pattern for the other 17 pilots:
   **do not run throwaway QA-instance scripts through `npx playwright test`; use a
   plain Node script that imports `chromium` directly.** This also sidesteps the
   `.js`-is-an-ES-module-under `web/package.json`'s `"type": "module"` trap — a
   throwaway script needs a `.cjs` extension (hit this once, one wasted run) if it uses
   `require()`, or must be written as ESM `import` from the start.

3. **The credential handed to this run in the dispatch prompt did not work, and this
   was NOT discoverable without dropping to `curl` against Keycloak's token endpoint
   directly.** The browser-level failure alone ("Invalid username or password") could
   plausibly have been mis-blamed on a typo in the dispatch prompt, a copy/paste
   corruption, or a shell-escaping issue in the throwaway script — it took a second,
   independently-fetched credential (`admin-user`, confirmed working via the exact same
   mechanism at the exact same moment) to rule those out and pin the fault on the seeded
   QA account itself. **Recommendation:** before a UAT-RUNNER pilot dispatch hands over
   a named actor's credential, the dispatcher (or a cheap pre-flight step) should
   confirm it authenticates at least once — a single `curl`/token-grant check is
   seconds of cost and would have saved this entire run's budget for actual screen
   review instead of credential forensics. This is exactly the kind of thing worth
   automating into `qa-login.sh` itself: have it optionally verify the password it just
   printed against the token endpoint before handing it back.

4. **Selector/convention research paid off and should stay in the process.** Reading
   `exam-taking.e2e.spec.ts` / `exam-result.e2e.spec.ts` first (rather than guessing
   selectors from the scenario's prose) surfaced real, load-bearing detail no scenario
   YAML states — e.g. that the countdown is *server re-anchored per autosave response*,
   not a free-running client timer, and that a `short_text` question in an exam forces
   `grading_pending` rather than a numeric score regardless of correctness (so EO-002/
   EO-003 as this scenario states them are only reachable with an exam fixture that has
   *no* short-answer questions — the scenario's own precondition already says this, but
   it would have been easy to miss without reading the real component). Keep this step
   for the other 17 pilots; it is not overhead, it is what made the (aborted) walkthrough
   script correct on its first real attempt at every step *up to* login.

5. **Screenshot storage convention worked without friction.** `web/tests/screenshots/pipelines/<name>/`
   is already gitignored consistently with how the existing `*.pipeline.e2e.spec.ts`
   files write their own screenshots (e.g. `onboarding-wizard.pipeline.e2e.spec.ts`'s
   `scratch/pipeline-...png`) — no repo change was needed to use it, and nothing here
   suggests changing that convention.

## Verification commands quoted above, for reference

```bash
# Fresh credential fetch (not reused from dispatch)
bash ai-dala-infra/scripts/qa-login.sh candidate-user
bash ai-dala-infra/scripts/qa-login.sh admin-user

# Direct token-endpoint check, bypassing the browser entirely
curl -s -X POST 'https://auth.qa.bizdala.com/realms/bpm-default/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=letflow-web' -d 'grant_type=password' -d 'username=candidate-user' \
  --data-urlencode 'password=<seeded value>'
# => {"error":"invalid_grant","error_description":"Invalid user credentials"}

curl -s -X POST 'https://auth.qa.bizdala.com/realms/bpm-default/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=letflow-web' -d 'grant_type=password' -d 'username=admin-user' \
  --data-urlencode 'password=<seeded value>'
# => {"access_token": "eyJhbGc...", ...}   (succeeds)
```

No password value is reproduced in this report or anywhere else committed —
credentials are referenced only as "QA `candidate-user`/`admin-user`, see
`ai-dala-infra/scripts/qa-login.sh`" throughout, per this pilot's constraints.
