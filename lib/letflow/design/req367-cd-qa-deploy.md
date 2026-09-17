# REQ-367 Design: CD to QA on merge (`cd.yml` + `deploy/redeploy-qa.sh`)

Stage: S7. Owner agents downstream: ELIXIR-DEV (implementation),
CODE-DESIGN-VALIDATOR (this doc's gate).

This is infrastructure (a bash script + a GitHub Actions workflow), not
Elixir application code — this design describes procedure and structure,
not code. No `.sh`/`.yml` bodies appear below; ELIXIR-DEV writes those.

## 0. Sources consulted

- `.github/workflows/ci.yml` (read in full) — the `changes` job (lines
  ~124-195: `backend`/`frontend` boolean outputs computed from a real
  `git diff` against base SHA, with fail-open defaults), and the
  `backend`/`frontend` gate jobs' own `needs: changes` /
  `if: needs.changes.outputs.X != 'false'` pattern.
- `deploy/redeploy-test.sh` (read in full) — existing precedent for a
  single-artefact (`letflow-test`, backend-only Docker image) redeploy
  script targeting `/opt/apps/letflow-test` on `hetzner-prod`, invoked
  by a stale/aspirational `cd.yml` reference that does not exist in this
  repo.
- **Sibling repo `c:\Users\tvolo\dev\ai-dala\letflow-queue` was locally
  available** — its real `.github/workflows/cd.yml` and
  `deploy/redeploy-test.sh` were read directly (not reconstructed from
  the requirement text's description). Key facts taken from it:
  - `cd.yml` triggers via `on: workflow_run: workflows: ["CI"], branches:
    [master], types: [completed]`, with the deploy job gated by
    `if: github.event.workflow_run.conclusion == 'success'`.
  - One `deploy` job, one step, using `appleboy/ssh-action@v1` with
    `host`/`username`/`key` from `secrets.HETZNER_DEPLOY_HOST` /
    `HETZNER_DEPLOY_USER` / `HETZNER_DEPLOY_SSH_KEY`, and `script: bash
    /opt/apps/<app>/deploy/redeploy-test.sh` (present only for
    documentation — the restricted `command=` on the deploy key's
    `authorized_keys` entry ignores it and forces the real script).
  - **letflow-queue's `cd.yml` has no path-filter/`changes`-job gate at
    all** — it deploys unconditionally whenever CI succeeds on
    `master`. This is a genuine divergence point for REQ-367: this repo
    (unlike letflow-queue) already computes `backend`/`frontend` diff
    outputs in `ci.yml`'s `changes` job specifically to skip cost on a
    docs-only change, and REQ-367's own text requires reusing that
    signal rather than deploying unconditionally. See §3 for how the
    gate is threaded across the `workflow_run` boundary.

## 1. `deploy/redeploy-qa.sh` — ordered procedure outline

Target host: `ubuntu-16gb-nbg1-1`. Target path: `/opt/apps/letflow-qa`.
Runs as the QA deploy account (or root), same invocation shape as
`redeploy-test.sh`: `bash /opt/apps/letflow-qa/deploy/redeploy-qa.sh`.

Header comment must state explicitly (see §4 for exact wording
requirements):
- This script targets `/opt/apps/letflow-qa` on `ubuntu-16gb-nbg1-1`
  (qa.bizdala.com) — a different host/path/Compose project than
  `deploy/redeploy-test.sh`'s `/opt/apps/letflow-test` on
  `hetzner-prod`.
- It is a sibling script, not a replacement — `redeploy-test.sh` is
  untouched and continues to serve its own (currently unwired) target.
- Invoked automatically by `.github/workflows/cd.yml` over a
  restricted SSH deploy key (same mechanism as letflow-queue's
  `redeploy-test.sh`, per `ai-dala-infra`'s T-0111 pattern), and may
  also be invoked manually the same way `redeploy-test.sh` is.

Constants the script establishes up front as named variables (not
hardcoded inline at point of use), mirroring `redeploy-test.sh`'s
`APP_DIR`/`COMPOSE`/`DATE` pattern:
- An app-directory variable holding the absolute path
  `/opt/apps/letflow-qa`.
- A web-dist-directory variable holding that app directory's
  `web-dist` subpath — the live, nginx-served frontend bundle
  directory.
- A compose-invocation variable analogous to `redeploy-test.sh`'s own
  `$COMPOSE` variable: it should express the Compose call scoped to
  the app directory as the project directory and to a QA-specific
  compose file living under that directory's `deploy/` subpath.
  **Open question**: whether that QA-specific compose file already
  exists is not resolvable from this checkout — see §7.
- A timestamp variable for backup/rollback-tag naming, mirroring
  `redeploy-test.sh`'s own day-granularity date variable — REQ-367's
  ordered outline below uses a finer-grained (sub-day) timestamp for
  the web-dist backup specifically (see step 5) since a same-day
  redeploy must not clobber an earlier same-day backup.

Ordered procedure (strict-mode shell options throughout, matching
`redeploy-test.sh`'s convention of failing fast on any error, unset
variable, or pipeline failure):

1. **Announce start.** Print a UTC timestamp banner, same style as
   `redeploy-test.sh`'s own opening banner line.

2. **Git pull.** Move into the app directory, pull the latest commit
   on the checked-out branch, then capture the resulting short commit
   ref into a variable and print it — identical shape to
   `redeploy-test.sh`'s first two steps (no credential injection
   needed; same public-repo assumption).

3. **Backend: rebuild + recreate.**
   - Optional best-effort rollback tag, mirroring `redeploy-test.sh`'s
     own second step: re-tag the currently-running backend image under
     a rollback-labelled tag that incorporates the timestamp variable,
     tolerating (not failing the script on) the case where no prior
     image exists yet — a first-ever run on a fresh host.
   - Build the backend image using the shared, existing deploy
     Dockerfile (the same one `redeploy-test.sh` already builds from —
     no new Dockerfile is in scope for this requirement), tagging the
     result as the QA backend's `latest` image.
   - Bring the database service up first, on its own, before touching
     the app service — same ordering rationale as `redeploy-test.sh`'s
     corresponding step: avoid tearing down/recreating the db
     container on every redeploy (the app service's own dependency
     ordering already enforces db-before-app; this is purely about not
     disturbing an already-healthy db container).
   - Force-recreate only the app service against the freshly built
     image. Migrations run automatically on boot via the supervision
     tree's `Ecto.Migrator`, same as `redeploy-test.sh`'s corresponding
     step — no separate migration invocation in this script.

4. **Frontend: throwaway-container rebuild.**
   - Run a throwaway container from the official Node 22 image (no
     Node installed on the host itself — matches the requirement's
     stated minimal-footprint precedent and `ci.yml`'s own frontend job
     pinning Node 22). Inside that container: make the freshly-pulled
     `web/` checkout available, install dependencies via a clean,
     lockfile-exact install, then run the frontend's existing
     production build script from `web/package.json` (the exact script
     name should be confirmed against that file by ELIXIR-DEV at
     implementation time; not re-derived here so this doc doesn't go
     stale if that file changes). Pass two build-time environment
     variables into that build step as real values, not placeholders:
     the OIDC authority URL and the OIDC client ID the QA frontend
     bundle must be built against.
   - The container must write its build output to a fresh staging
     directory location outside the live web-dist directory — never
     building directly into the path nginx is currently serving from.
     This separation is what step 5's atomic swap depends on.
   - **Open question**: the exact source of the real OIDC authority/
     client-ID values (most plausibly an environment file already
     present on the QA host, per the manual QA-deploy precedent the
     requirement text cites) is not visible from this checkout — see
     §7. The script should read those values from a named, existing
     host-local file rather than hardcoding them into the script body,
     and should not introduce new GitHub Actions secrets for them
     unless ELIXIR-DEV finds evidence the manual precedent actually
     used that route; the exact file path/name is for ELIXIR-DEV to
     confirm against actual host state (or the task records the
     requirement text cites, if reachable).

5. **Frontend: atomic swap with backup.**
   - Back up the current live bundle before replacing it: move the
     live web-dist directory aside to a backup path that incorporates
     the timestamp variable, matching "backing up the previous build
     first" from the requirement text and the manual-deploy pattern it
     cites.
   - Move the new staging build (produced in step 4) into place as the
     live web-dist directory, as a single rename on the same
     filesystem so it completes atomically and nginx never observes a
     partially-populated directory. No nginx reload or restart —
     nginx serves that directory path directly, and a rename is
     transparent to new requests, which resolve against the new
     directory once the rename completes; this matches the
     requirement's explicit instruction not to restart nginx.
   - No retention/pruning policy for old backups is specified by the
     requirement — flagged in §7 as an open question (unbounded growth
     risk) rather than this design silently deciding a retention
     count.

6. **Health check: backend.** Same retry-loop shape as
   `redeploy-test.sh`'s own health-check step: repeatedly poll the
   backend's local health endpoint on its published port (the port
   number itself matches whatever the app's existing published port
   is — `redeploy-test.sh` uses one specific port for its own
   environment; the QA host's actual published port is not confirmed
   from this checkout, see §7), inspecting a status field in the JSON
   response body, retrying across a bounded total window (matching
   `redeploy-test.sh`'s own retry count and sleep interval), and
   failing the script loudly once that window is exhausted without a
   healthy response.

7. **Health check: frontend.** A new check, not present in
   `redeploy-test.sh` (that script has no separate frontend artefact).
   Issue a single HTTPS request to the public QA site's root URL
   (through nginx and TLS, not a local port — this checks the *served*
   shell, not any container, since there is no frontend
   container/process to health-check directly), treating a non-2xx
   response or a request failure as a script failure, matching the
   backend check's fail-loud convention. A short bounded retry
   (mirroring step 6's shape) is reasonable but not mandated by the
   requirement; ELIXIR-DEV may choose a single-attempt check with a
   short request timeout instead, if a full retry loop is judged
   unnecessary for a locally-served static file — either is
   acceptable, not an open question requiring sign-off.

8. **Done banner.** Print the deployed ref captured in step 2, same as
   `redeploy-test.sh`'s own closing line.

## 2. `.github/workflows/cd.yml` — structural outline

### Triggers

- The workflow fires on completion of the CI workflow (named `"CI"`),
  restricted to the `main` branch — matching letflow-queue's exact
  trigger mechanism, but with `main` in place of letflow-queue's
  `master`, since `main` is this repo's default branch (confirmed by
  `ci.yml`'s own push trigger targeting `main`).
- No direct push or pull-request trigger on this file — deploy only
  ever follows a completed CI run on `main`, never runs directly
  against a PR.

### Jobs

One job, named `deploy`, same shape as letflow-queue's `cd.yml`, running
on a standard GitHub-hosted Ubuntu runner.

Job-level condition, two requirements both of which must hold (see the
next subsection for how the second is obtained):
  1. The triggering CI workflow run's conclusion was a success —
     identical to letflow-queue's own gate (don't deploy over a
     failed/cancelled CI run).
  2. The reused `changes` job's gate signal indicates at least one of
     the backend or frontend paths changed.

### How the gate reuses `ci.yml`'s `changes` job without duplicating diff logic

This is the one place REQ-367's design **must diverge from
letflow-queue's literal cd.yml**, because letflow-queue's cd.yml has no
gate to reuse in the first place (§0). A `workflow_run`-triggered
workflow runs as a **separate workflow** and cannot read another
workflow's job outputs via a `needs:` reference — `needs` only works
within the same workflow run. The mechanism specified here is the
standard documented pattern for passing data across that boundary
without a second diff computation:

1. **`ci.yml`'s `changes` job gains one small addition** (a step, not a
   new job, not a change to its diff logic): after computing its
   backend/frontend booleans, that job writes those two values to a
   small file and uploads that file as a build artifact, using the
   standard artifact-upload action, under a name identifying it as the
   path-filter outputs. This does not touch `.github/workflows/ci.yml`'s
   existing filter/fallback steps or their diff/regex logic at all — it
   is a pure downstream consumer of the outputs those steps already
   produce.
   - **Note on scope**: `.github/workflows/ci.yml` is not listed in this
     requirement's `owned_modules` (only `deploy/redeploy-qa.sh` and
     `.github/workflows/cd.yml` are). This one-step addition to
     `ci.yml` is nonetheless necessary to satisfy REQ-367's own explicit
     instruction to gate on the `changes` job's outputs "via
     `workflow_run` ... or an equivalent that avoids a second
     independent diff computation" — there is no way to honor that
     instruction under a `workflow_run` trigger without either this
     artifact-passing addition or literally duplicating the diff logic
     (which the requirement explicitly forbids). Flagged explicitly in
     §7 as something CODE-DESIGN-VALIDATOR and ELIXIR-DEV should
     confirm is acceptable scope, rather than silently touching a file
     outside `owned_modules` without comment.
2. **`cd.yml`'s `deploy` job downloads that artifact** using the
   standard artifact-download action, addressed to the triggering
   workflow run's ID for a cross-workflow download, supplying the
   built-in repo token that action's documented cross-run usage
   requires, as its first step, before any SSH/deploy step.
3. A subsequent step reads the two values out of the downloaded file
   and exposes a single combined boolean (true if either the backend
   or frontend value is true) as that step's own output.
4. All later steps in the job (the SSH deploy step) are gated by a
   **step-level** condition on that combined output being true —
   matching `ci.yml`'s own documented preference (its header comment
   favors step-level over job-level path-filter conditions) so the job
   itself still runs and reports a (skipped-steps) success rather than
   the whole job vanishing — same rationale as `ci.yml`'s own
   backend/frontend jobs.
   - The job-level condition (item 2 above, CI-run-succeeded) stays
     job-level since that condition is about CI having run at all, not
     about what changed — the same split `ci.yml` itself already draws
     between its job-level "not cancelled" condition and its
     step-level "changes output is not false" conditions.

### Steps (in order)

1. Download the path-filter-outputs artifact produced by the
   triggering CI run (as described above).
2. Read/parse that downloaded file and set the combined deploy-or-not
   step output.
3. Run the SSH deploy step, using the same third-party SSH-action
   letflow-queue uses, gated by the step-level condition from above.
   Its connection details are drawn from three repository secrets
   (named below) supplying the target host, the connecting username,
   and the private key; its remote command invokes
   `redeploy-qa.sh` at its full path under the QA app directory. A
   comment on this step should match letflow-queue's own, noting that
   the remote-command value is documentation-only, since the
   restricted `command=` entry on the deploy key's authorized-keys
   line forces the real command to run server-side regardless of what
   this step requests.

### Secret names (explicitly not required to exist yet)

Three new secrets, named distinctly from letflow-queue's own
(`HETZNER_DEPLOY_HOST`/`HETZNER_DEPLOY_USER`/`HETZNER_DEPLOY_SSH_KEY`)
so the two repos' credentials can never be confused or accidentally
shared:

- `QA_DEPLOY_HOST`
- `QA_DEPLOY_USER`
- `QA_DEPLOY_SSH_KEY`

None of these are provisioned by this requirement. Per the requirement
text and `step-00`'s handoff, provisioning (a fresh purpose-built SSH
key, `command=`-restricted per T-0111's precedent, `gh secret set` run
by the user directly) is a companion `ai-dala-infra` task, out of scope
here. `cd.yml` referencing these names before they exist is expected
and correct — the workflow will simply fail at the SSH step (a
`workflow_run`-triggered failure, not a required status check, so it
does not block anything) until that companion task lands.

## 3. Why this avoids duplicating `ci.yml`'s diff logic

Covered in full in §2's "How the gate reuses..." subsection. Summary:
the `git diff`/regex computation exists in exactly one place
(`ci.yml`'s `changes` job, untouched). `cd.yml` never re-derives
`backend`/`frontend` from a diff — it consumes the already-computed
values via an artifact produced by that same job, which is the only
way to cross the `workflow_run` trigger boundary without either a
second diff (forbidden) or a same-workflow `needs:` (unavailable
because `cd.yml` and `ci.yml` are different workflow files/runs).

## 4. `deploy/redeploy-test.sh` is left untouched

Not modified, not renamed, not deleted, as instructed by the
requirement text (its own future target may still need it). Its
existing header comment's claim of being "Automatically, by
.github/workflows/cd.yml" invocation is stale/aspirational (no such
workflow exists in this repo today) and REQ-367 does not fix that
claim, since `redeploy-test.sh` is explicitly out of scope to touch.

The relationship between the two scripts must be stated in both
files' own header comments (not left implicit):
- `deploy/redeploy-qa.sh`'s header (per §1) states it is a sibling to,
  not a replacement for, `redeploy-test.sh`, and names the concrete
  differences (host, `APP_DIR`, Compose project, presence of a second
  frontend artefact).
- No edit to `redeploy-test.sh`'s own header is in scope for this
  requirement — it is not touched at all, per the requirement text's
  explicit instruction. (If its stale `cd.yml` claim is ever judged
  worth correcting, that is a separate, explicitly-scoped requirement,
  not folded into REQ-367.)

`.github/workflows/cd.yml`'s own top-of-file comment should similarly
state it deploys **only** to QA via `redeploy-qa.sh`, and that
`letflow-test`'s own eventual CD wiring (if `redeploy-test.sh` is ever
activated) is a separate, not-yet-filed concern — so a future reader
of `cd.yml` doesn't assume it also covers the test environment.

## 5. Explicit scope

**In scope for REQ-367 (this design + its implementation):**
- `deploy/redeploy-qa.sh` — new file, full procedure per §1.
- `.github/workflows/cd.yml` — new file, full structure per §2.
- The one small artifact-upload step added to `.github/workflows/ci.yml`'s
  existing `changes` job (§2), needed only to satisfy the "don't
  duplicate diff logic" requirement under a `workflow_run` trigger.

**Out of scope (explicitly, per the requirement text and step-00's
handoff):**
- Provisioning the actual SSH deploy key, its `command=` restriction,
  or any change to the `ubuntu-16gb-nbg1-1` host's filesystem/config —
  companion `ai-dala-infra` task, following T-0111's precedent.
- Setting the three new GitHub Actions secrets (`gh secret set`, run by
  the user directly — agents do not have write access to this repo's
  own Actions secrets).
- Modifying or deleting `deploy/redeploy-test.sh`.
- Creating `deploy/docker-compose.qa.yml` if it does not already exist
  on the host/in the repo — flagged in §7; `redeploy-qa.sh`'s `$COMPOSE`
  variable references it, but authoring that compose file is not
  self-evidently part of "the script must exist and be correct" unless
  ELIXIR-DEV confirms it's missing and REQ-367's acceptance criteria
  are read to include it. Flagged rather than silently assumed either
  way.
- Any change to `nginx/` config — the requirement explicitly says not
  to restart/reconfigure nginx as part of an application-code deploy.
- Making the deploy actually live/functional end-to-end (blocked on
  the credential-provisioning companion task, per step-00's own
  close-out framing: this requirement's job is "provably ready to
  receive a working deploy key," not a live deploy).

## 6. Acceptance criteria mapping

| REQ-367 acceptance criterion (from step-00's context) | Concrete design element |
|---|---|
| Deploy on merge to main changes deployable code | §2 Triggers (`workflow_run` on `ci.yml` completion, `branches: [main]`) + §2 gate (job/step `if` conditions) |
| Reuse letflow-queue's proven SSH-restricted-key CD pattern, not a new mechanism | §0 sources + §2 Steps (same `appleboy/ssh-action@v1`, same `command=`-restriction-does-the-real-work framing) |
| Two-artefact QA deploy: git pull, backend rebuild+recreate, frontend throwaway-container rebuild+atomic-swap-with-backup, both health checks | §1 steps 2-7 (git pull; backend build+`$COMPOSE up -d --force-recreate app`; `node:22` throwaway build with real `VITE_OIDC_*` args + atomic swap with timestamped backup; backend `/health` + frontend `https://qa.bizdala.com/` checks) |
| Gate on `ci.yml`'s existing `changes` job outputs, no duplicated diff logic | §2 "How the gate reuses..." + §3 (artifact-passing across the `workflow_run` boundary; zero second `git diff`/regex) |
| Credentials out of scope; script/workflow exist, are correct, reference not-yet-existing secret names | §2 "Secret names" (three new, distinctly-named secrets, explicitly not provisioned here) + §5 scope table |

(The requirement text names five specific themes across step-00's
narrative; this table maps each to its design element per the handoff
task's item (f) instruction. All five are covered — no "TBD" entries.)

## 7. Open questions (not silently resolved)

1. **`ci.yml` falls outside `owned_modules` but needs a one-step
   addition** (§2) to satisfy the "no duplicated diff logic" mandate
   under a `workflow_run` trigger. CODE-DESIGN-VALIDATOR should confirm
   this is acceptable scope for REQ-367 rather than requiring a
   separate requirement/handoff for that one step.
2. **`deploy/docker-compose.qa.yml`'s existence is unconfirmed.** This
   checkout has `deploy/docker-compose.test.yml` but no `.qa.yml`
   sibling. `redeploy-qa.sh`'s `$COMPOSE` variable (§1) references it
   by convention with `redeploy-test.sh`'s own pattern; ELIXIR-DEV must
   check the actual repo state (and, if reachable, the QA host itself)
   before assuming it exists, and treat authoring it as in-scope only
   if it's genuinely missing and needed for the script to be "correct"
   per the acceptance criteria.
3. **Source of the real `VITE_OIDC_AUTHORITY`/`VITE_OIDC_CLIENT_ID`
   values** (§1 step 4) — the requirement text cites prior manual QA
   deploys (`ai-dala-infra` tasks T-0125/T-0128/T-0129/T-0131) as
   precedent for "the real" values already being used, but those task
   records were not read as part of this design (not present in this
   checkout). ELIXIR-DEV should locate the actual host-local source
   (most likely an `.env`-style file already on `ubuntu-16gb-nbg1-1`)
   rather than this design guessing a file path.
4. **Backend health-check port on the QA host.** `redeploy-test.sh`
   uses `3113` for `letflow-test`; QA's actual published backend port
   is not confirmed from this checkout (could be the same or different
   depending on how the QA Compose project maps ports). ELIXIR-DEV
   should confirm against the QA host's actual `docker-compose.qa.yml`
   /running state rather than this design assuming `3113` carries over.
5. **Old `web-dist` backup retention/pruning.** §1 step 5 backs up the
   previous build before each swap but the requirement does not specify
   a retention policy; unbounded accumulation on the host is a real but
   unaddressed risk. Left as an open question rather than this design
   inventing a retention count (e.g. "keep last 5") the requirement
   never asked for.
6. **Exact frontend build script name.** §1 step 4 refers to "the
   frontend production build" without asserting `web/package.json`'s
   exact script name, to avoid this design doc silently going stale if
   that script is renamed; ELIXIR-DEV should read `web/package.json`
   directly at implementation time.
