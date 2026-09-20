# GUI review — migration-partial-failure-resume

**Date:** 2026-09-20
**Agent:** ORCH (direct, no nested dispatch, per this run's own instruction)
**Scenario:** `test/fixtures/uat/scenarios/platform/migration-partial-failure-resume.yaml`
**Process applied:** "agent reviews real screens before writing a blind Playwright spec"
**Sweep position:** 7th of ~15 scenarios in today's systematic GUI-review sweep.

## Path taken

**Outcome 2 of the process: the operator-facing feature genuinely does not exist —
filed as properly-sized requirements, BLOCKED recorded, no live GUI walkthrough
attempted.** This scenario's operator steps (1, 3, 4, 6) are all `via: gui`; with zero
rollout-fanout affordance anywhere in `web/src`, and no backend runner to drive it
against, there is no screen to log into, drive, screenshot, or judge. Rather than trust
the scenario's own pre-existing `NOTE (ISS-0527)` at face value, I independently
re-verified the underlying premise by reading current source directly — both
`lib/letflow/` and `web/src/` — rather than assuming from the note alone.

## What was checked, and what each source showed

**Backend — does not exist, confirmed by direct read:**

- Grepped `lib/letflow/` for `rollout|fanout|tenant_migration|TenantMigration|
  PlatformRollout` (case-sensitive and case-insensitive) — no functional hits. A
  broader case-insensitive `tenant` grep returned ~200 files, none of which implement a
  platform-wide per-company fanout with failure isolation; they are single-tenant
  provisioning/promotion machinery (see below).
- `lib/letflow/tenant_provisioning.ex` (REQ-022) provisions **one** tenant schema at
  onboarding time. `lib/letflow/tenant_provisioning/column_promotion.ex` and
  `constraint_activation.ex` (REQ-297/REQ-298) promote **one** entity definition's DDL,
  scoped to a single tenant transaction. Neither iterates every active company, records
  a per-company outcome, or supports resuming an interrupted run.
- `lib/letflow/design/req022-tenant-schema-provisioning.md` (read in full, lines
  ~290–299) names this exact gap explicitly and by citation to R-Co's own
  `src/platform/migration_fanout.zig`, calling it "a distinct orchestration layer that
  calls `runForSchema` across *all* registered tenants independently of any single
  provisioning event," and states: "a future requirement owns the onboarding
  orchestration that sequences them (not invented here)." That future requirement had
  never been filed until this run.
- Grepped `lib/letflow/routers/` for any rollout/fanout/migration-status route — no
  hits among the 13 files matching a broad `tenant`-adjacent search; none is a
  platform-admin rollout console endpoint.

**Frontend — does not exist, confirmed by direct read:**

- Grepped `web/src` (case-insensitive) for `rollout|fanout|migration.?status` — zero
  hits. No operator console page renders a per-company outcome list, a completion
  timestamp, a failure reason, or a resume/re-run control.
- Grepped `web/src` for `RolloutStatus|MigrationStatus|PlatformMigration|
  RolloutConsole` (component-name-shaped search) — zero hits.

**Requirements queue — no duplicate in flight:**

- Grepped `docs/requirements.yaml` for `migration.fanout|tenant.migration|
  platform-wide change|rollout` (case-insensitive) — the only hit was an unrelated
  requirement's own text ("app-wide i18n rollout this requirement was never asked to
  do"), confirming no existing requirement, pending or done, already covers this gap.

**Conclusion:** the scenario's own `NOTE (ISS-0527)` — "treat any run of this scenario
as BLOCKED/UNBUILT_FEATURE on the frontend leg" — is correct, and this pass confirms the
gap is not frontend-only: the backend fanout/resume/idempotency machinery this scenario
needs does not exist either. This is a larger unbuilt feature than most of this sweep's
prior findings (REQ-371/372/373), matching the task's own framing that this outcome is
"legitimate."

## Screens reviewed

None. No real GUI walkthrough against `https://qa.bizdala.com` was attempted — there is
no operator console for a platform-wide rollout to log into or drive, and no backend
endpoint to start one against. Inventing a substitute flow through an unrelated screen
would not test this scenario's actual acceptance criteria (EO-001 through EO-005 all
describe a rollout mechanism and status screen that do not exist).

## Fixed vs. filed

- **Fixed:** nothing. No real defect was found in already-shipped code — the existing
  single-tenant provisioning/promotion machinery is correct and complete for its own
  declared scope; the gap is an unbuilt platform-wide orchestration feature, not a bug
  in something that already ships.
- **Filed:** two requirements, split backend/frontend per this sweep's established
  precedent (REQ-372 → REQ-373):
  - `docs/requirements.yaml` **REQ-374** — "Platform-wide tenant-migration fanout
    runner: per-company apply with failure isolation, resume-outstanding, and
    idempotent re-run (backend)," owner `ELIXIR-DEV`, stage S6, status `pending`.
    Depends on REQ-022, REQ-297, REQ-298 (the existing single-tenant primitives it
    builds on top of, per req022's own design-note precedent). Sized to the fanout
    runner, per-company outcome record, resume, and idempotent re-run only — explicitly
    fences out inventing a general "kinds of platform-wide change" registry.
  - `docs/requirements.yaml` **REQ-375** — "Operator-facing rollout-status screen:
    per-company outcome, reason, and resume/re-run controls (frontend)," owner
    `FRONTEND-DEV`, stage S8, status `pending`, `depends_on: [REQ-374]`. Includes, as
    its own acceptance criterion, authoring and passing this scenario's named
    `pipeline_test`
    (`web/tests/e2e/pipelines/platform-migration-partial-failure-resume.pipeline.e2e.spec.ts`)
    once the screen exists, so this scenario does not stay perpetually blocked one
    requirement later.

## Run-history / status bookkeeping

- `docs/status/requirement_status.v20.yaml` — appended one `SCOPE-CHANGE`/`done` entry
  (ORCH) recording this review and REQ-374/REQ-375's filing, per the append procedure in
  that file's own header (timestamp from the clock, append verified via
  `git diff --numstat`, note re-read via `tail`).
- `docs/status/requirement_status.index.yaml` — volume 20's `entries:` count
  incremented by one in the same commit.
- The scenario file's own `pipeline_test` NOTE block was extended (not removed — the
  feature is not real) with a dated addendum pointing at REQ-374/REQ-375 and this
  report, matching the `definition-promotion-rollback` precedent from earlier in this
  sweep.

## Spec status

**Not authored.** Writing
`web/tests/e2e/pipelines/platform-migration-partial-failure-resume.pipeline.e2e.spec.ts`
now, against a runner and a screen that do not exist, would be exactly the "blind
Playwright spec" this process exists to prevent. It will be authored once REQ-375 ships
a real screen, per REQ-375's own acceptance criteria, and run for real at that time — no
assumption here that it "should" pass.

## Process-compliance note

This pass made no `lib/` or `web/` application-code change, only additions to
`docs/requirements.yaml`, `docs/status/requirement_status.v20.yaml`,
`docs/status/requirement_status.index.yaml`, this report, and the scenario fixture's own
NOTE comment block. Per this run's explicit instructions, the change was still routed
through a full branch → PR → CI → merge (no direct push to `main`), and no nested
fork/sub-dispatch was used — every step above was performed directly by this session.
Before touching anything, `git status` was checked and several pre-existing, unrelated
uncommitted/untracked changes were found in the working tree (`docs/issues/ISS-0725.yaml`
modified; `docs/issues/ISS-0728-*.yaml`, `docs/issues/ISS-0729.yaml`, two
`test/uat-reports/uat-2026-09-19-WF05-*.yaml` files, and
`web/tests/e2e/.pipeline-state/` untracked) — evidently another concurrent sibling
session's in-progress work. None of those files were touched, staged, or committed by
this run; only the files this review actually produced were added.
