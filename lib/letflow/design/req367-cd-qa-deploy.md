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

Constants the script establishes up front (named, not hardcoded
inline, mirroring `redeploy-test.sh`'s `APP_DIR`/`COMPOSE`/`DATE`
pattern):
- `APP_DIR` = `/opt/apps/letflow-qa`
- `WEB_DIST_DIR` = `$APP_DIR/web-dist` (the live, nginx-served
  frontend bundle directory)
- `COMPOSE` = the `docker compose --project-directory $APP_DIR -f
  $APP_DIR/deploy/docker-compose.qa.yml` invocation, analogous to
  `redeploy-test.sh`'s `$COMPOSE` variable. **Open question**: whether
  `deploy/docker-compose.qa.yml` already exists is not resolvable from
  this checkout — see §7.
- `DATE`/timestamp variable for backup/rollback-tag naming, mirroring
  `redeploy-test.sh`'s `$(date +%Y%m%d)` — REQ-367's ordered-outline
  below uses a finer-grained timestamp for the web-dist backup (see
  step 5) since a same-day redeploy must not clobber an earlier
  same-day backup.

Ordered procedure (`set -euo pipefail` throughout, matching
`redeploy-test.sh`'s convention):

1. **Announce start.** Echo a UTC timestamp banner, same style as
   `redeploy-test.sh`'s `echo "=== letflow test redeploy: ... ==="`.

2. **Git pull.** `cd "$APP_DIR"`, `git pull`, capture
   `CURRENT_REF=$(git rev-parse --short HEAD)` and echo it — identical
   shape to `redeploy-test.sh` steps 1-2 (no credential injection
   needed; same public-repo assumption).

3. **Backend: rebuild + recreate.**
   - (Optional best-effort rollback tag, mirroring
     `redeploy-test.sh` step 2 — `docker tag` the current
     `letflow-qa:latest` image to `letflow-qa:rollback-$DATE`,
     `2>/dev/null || true` so a first-run with no prior image doesn't
     fail the script.)
   - Build the backend image: `docker build -f deploy/Dockerfile -t
     letflow-qa:latest .` (same `-f deploy/Dockerfile` as
     `redeploy-test.sh`; the Dockerfile is shared/reused, not
     duplicated — no new Dockerfile is in scope for this requirement).
   - Ensure the db service is up first (`$COMPOSE up -d db`), same
     ordering rationale as `redeploy-test.sh` step 4 (keep the db
     container from being torn down/recreated on every redeploy; app's
     own `depends_on` already enforces ordering, this just avoids an
     unnecessary db restart).
   - Recreate the app container: `$COMPOSE up -d --force-recreate
     app`. Migrations run automatically on boot via the supervision
     tree's `Ecto.Migrator`, same as `redeploy-test.sh` step 5 — no
     separate migration step here.

4. **Frontend: throwaway-container rebuild.**
   - Run a throwaway `node:22` container (no Node installed on the
     host — matches the requirement's stated minimal-footprint
     precedent and `ci.yml`'s own frontend job pinning Node 22) that:
     mounts/copies `web/` from the freshly-pulled checkout, runs the
     equivalent of `npm ci` then the frontend production build (`npm
     run build`, matching `web/package.json`'s existing build script —
     the exact script name should be confirmed against
     `web/package.json` by ELIXIR-DEV; not re-derived here since this
     doc must not duplicate that file's contents) with two build-time
     environment variables passed in as real values, not placeholders:
     `VITE_OIDC_AUTHORITY` and `VITE_OIDC_CLIENT_ID`.
   - The container writes its build output to a fresh directory
     **outside** the live `$WEB_DIST_DIR` (e.g. a `$APP_DIR/web-dist.new`
     staging path), never building directly into the path nginx is
     currently serving from — this is what step 5's atomic swap
     depends on.
   - **Open question**: the exact source of the real
     `VITE_OIDC_AUTHORITY`/`VITE_OIDC_CLIENT_ID` values (an `.env`-style
     file already on the QA host, from the manual T-0125/T-0128/T-0129/
     T-0131 precedent referenced in the requirement text) is not
     visible from this checkout — see §7. The script should read them
     from a named host-local file (not hardcode them in the script
     body, and not accept them as new GitHub Actions secrets unless
     ELIXIR-DEV finds evidence the manual precedent used that route),
     with the exact file path/name confirmed by ELIXIR-DEV against the
     actual host state or the T-01xx task records if reachable.

5. **Frontend: atomic swap with backup.**
   - Back up the current live bundle before replacing it: rename/move
     `$WEB_DIST_DIR` to a timestamped backup path (e.g.
     `$APP_DIR/web-dist.backup.<timestamp>`), matching "backing up the
     previous build first" from the requirement text and the existing
     manual-deploy pattern it cites.
   - Atomically move the new staging build (`web-dist.new`, from step
     4) into place as `$WEB_DIST_DIR` — a single `mv` (rename) on the
     same filesystem, so nginx never observes a partially-populated
     directory. No nginx reload/restart — nginx serves the directory
     path directly and a rename is transparent to an already-open
     directory handle / new requests resolve the new inode; matches
     the requirement's explicit "do not restart nginx" instruction.
   - No retention/pruning policy for old backups is specified by the
     requirement — flagged in §7 as an open question (unbounded growth
     risk) rather than silently deciding a retention count.

6. **Health check: backend.** Same retry-loop shape as
   `redeploy-test.sh` step 6: poll `http://127.0.0.1:<backend-port>/health`
   (port matches the app's existing published port — `redeploy-test.sh`
   uses `3113`; the QA host's actual published port is not confirmed
   from this checkout, see §7), parse `status` from the JSON body, retry
   for up to 30s (10 attempts × 3s sleep), `exit 1` on exhaustion.

7. **Health check: frontend.** New check, not present in
   `redeploy-test.sh` (that script has no separate frontend artefact).
   `curl -sf https://qa.bizdala.com/` against the public HTTPS URL
   (through nginx + TLS, not a local port — this is checking the
   *served* shell, not the container, since there is no frontend
   container/process to health-check directly). Non-2xx/curl failure
   → `exit 1` with a clear error, matching the backend check's
   fail-loud convention. A short bounded retry (mirroring step 6's
   shape) is reasonable but not mandated by the requirement; ELIXIR-DEV
   may choose a single-attempt check with a short curl timeout instead
   if a full retry loop is judged unnecessary for a locally-served
   static file — either is acceptable, not an open question requiring
   sign-off.

8. **Done banner.** Echo the deployed ref (`$CURRENT_REF`), same as
   `redeploy-test.sh`'s closing line.

## 2. `.github/workflows/cd.yml` — structural outline

### Triggers

- `on: workflow_run: workflows: ["CI"], branches: [main], types:
  [completed]` — matches letflow-queue's exact mechanism, with
  `branches: [main]` (this repo's default branch, confirmed by
  `ci.yml`'s own `on.push.branches: [main]`) in place of letflow-queue's
  `[master]`.
- No `push`/`pull_request` triggers on this file — deploy only ever
  follows a completed CI run on `main`, never runs directly on a PR.

### Jobs

One job, `deploy`, same shape as letflow-queue's `cd.yml`:

- `runs-on: ubuntu-latest`
- Job-level `if`, two conditions ANDed (both required; see below for
  how the second is obtained):
  1. `github.event.workflow_run.conclusion == 'success'` — identical
     to letflow-queue's own gate (don't deploy over a failed/cancelled
     CI run).
  2. The reused `changes` job's gate signal (see next subsection) —
     `backend == 'true' OR frontend == 'true'`.

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
   new job, not a change to its diff logic): after computing
   `backend`/`frontend`, it writes those two values to a small file
   (e.g. `changes.json`, `backend=<bool>` / `frontend=<bool>`) and
   uploads it as a build artifact (`actions/upload-artifact@v4`) named
   e.g. `path-filter-outputs`. This does not touch `.github/workflows/ci.yml`'s
   existing `filter`/`fallback` steps or their `git diff`/regex logic
   at all — it is a pure downstream consumer of the outputs those
   steps already produce.
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
2. **`cd.yml`'s `deploy` job downloads that artifact** using
   `actions/download-artifact@v4` with `run-id:
   ${{ github.event.workflow_run.id }}` (cross-workflow download by run
   ID, requiring `github-token: ${{ secrets.GITHUB_TOKEN }}` on that
   step per that action's documented cross-run usage) as its first
   step, before any SSH/deploy step.
3. A subsequent step reads the two values out of the downloaded file
   and exposes them as that step's own `$GITHUB_OUTPUT` (e.g.
   `deploy=true`/`false`, OR'd from `backend`/`frontend`).
4. All later steps in the job (the SSH deploy step) are gated with
   `if: steps.<read-step-id>.outputs.deploy == 'true'` — a **step-level**
   condition, matching `ci.yml`'s own documented preference (its header
   comment: "step-level rather than job-level path-filter `if:`") so
   the job itself still runs and reports a (skipped-steps) success
   rather than the whole job vanishing — same rationale as `ci.yml`'s
   own `backend`/`frontend` jobs.
   - The job-level `if` (item 2 above, `conclusion == 'success'`) stays
     job-level since that condition is about CI having run at all, not
     about what changed — same split `ci.yml` itself already draws
     between its job-level `!cancelled()` and step-level
     `needs.changes.outputs.X != 'false'` conditions.

### Steps (in order)

1. Download the `path-filter-outputs` artifact from the triggering
   `workflow_run` (as above).
2. Read/parse it, set the combined `deploy` step output.
3. SSH deploy step (`appleboy/ssh-action@v1`, same action as
   letflow-queue), gated by the step-level `if` from above, with:
   - `host: ${{ secrets.QA_DEPLOY_HOST }}`
   - `username: ${{ secrets.QA_DEPLOY_USER }}`
   - `key: ${{ secrets.QA_DEPLOY_SSH_KEY }}`
   - `script: bash /opt/apps/letflow-qa/deploy/redeploy-qa.sh`
   - A comment, matching letflow-queue's own, noting the script value
     is documentation-only since the restricted `command=` on the
     deploy key's `authorized_keys` entry forces the real command
     server-side.

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
