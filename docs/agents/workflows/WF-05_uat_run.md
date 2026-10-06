# WF-05 — UAT Run

**Trigger:** a running Letflow instance exists and a stage's scenario corpus is ready
to validate against. In practice this does not become live until S7
(`docs/migration/stage-7-simulation-uat-parity.md`) — MVP-1's manual GUI walkthrough
(REQ-107) is a narrower precedent, not a full WF-05 run.
**Owner:** `ORCH`

## Overview

```
[INPUT: a running Letflow instance + a scenario corpus to validate]
        │
        ▼
┌───────────────────────┐
│  STEP 0: ENVIRONMENT  │ ← ORCH derives the PRECONDITIONS manifest, runs
│  PREPARATION          │   scripts/uat_preflight.sh, closes gaps (letflow seeds /
└──────────┬─────────────┘   ai-dala-infra request), re-checks. Unmet after prep →
           │                 run is ENV_NOT_READY, never PASS/FAIL. Skipped → same.
           ▼
┌───────────────────────┐
│  STEP 1: READINESS    │ ← ORCH verifies the instance is actually reachable
│  CHECK                │   (health endpoint, or equivalent) before dispatching
└──────────┬─────────────┘   UAT-RUNNER — do not dispatch first and discover it's
           │                 down afterward.
           ▼
┌───────────────────────┐
│  STEP 2: RUN          │ ← UAT-RUNNER
│  SCENARIOS            │   Executes each scenario against the real running
│                        │   instance (real HTTP calls, real DB state) — no mocks,
│                        │   same "real system, not simulated" principle as
│                        │   docs/guides/test_developer_guide.md's Directive T-2.
└──────────┬─────────────┘
           ▼
┌───────────────────────┐
│  STEP 3: REPORT       │ ← UAT-RUNNER writes test/uat-reports/uat-<date>-<run-id>.yaml
│                        │   Verdict per scenario stated as "system did X after
│                        │   action Y" — not "no errors were thrown."
└──────────┬─────────────┘
           ▼
      Run ENV_NOT_READY (Step 0 skipped, or BLOCKED-by-environment remain)?
      ├─ YES → no UAT result; back to Step 0 / ai-dala-infra. UAT gate NOT satisfied.
      └─ NO  → Any scenario FAIL?
      ├─ NO  → PASS, stage's UAT parity confirmed for this scenario batch
      └─ YES → file per ISSUE_QUEUE.md (or, if it blocks the current stage gate,
               route directly to WF-03 for this specific run rather than
               forwarding — a UAT failure on a stage-defining scenario is this run's
               own blocker, not an incidental one)
```

## Step 0 — Environment preparation (mandatory)

**Agent:** `ORCH`

A run dispatched against an unprepared environment produces BLOCKED scenarios, not UAT
evidence (`WF05-FULL-20260929`: 26 of 31 scenarios BLOCKED for missing tenants, Keycloak
realms/actors, deployed definitions, and specs needing local Postgres). Prepare first.

```
1. Derive the PRECONDITIONS manifest from the scenario corpus (per scenario): tenants
   (`company_id`/`scope`), Keycloak realms, actors + roles (`actors:`), deployed process
   definitions (`process_id`), credentials for those actors, deployed build == origin/main
   SHA, required spec files (`pipeline_test` exists and is not an unresolved
   `NOTE (ISS-05xx)` forward-reference), and no local-only dependencies (e.g. a spec that
   shells out to `docker compose exec psql`).
2. Run the preflight (read-only):
     scripts/uat_preflight.sh --base-url <url> --environment <slug> \
        --credential-source <path> --out <preflight.json>
   Save the output as `test/uat-reports/preflight-<date>-<environment>.txt`.
3. For each GAP, by remediation owner:
   - letflow-seed: run the idempotent `scripts/seed_*.sh` where one exists.
   - ai-dala-infra (Keycloak realm/users, tenant creation, deploy, exposing a build SHA):
     file a request to / dispatch a run in `ai-dala-infra`
     (`c:\Users\tvolo\dev\ai-dala\ai-dala-infra`, own orchestrator workflow + approval
     gate). Letflow never changes QA infrastructure directly.
   - feature-gap (missing/forward-reference spec, unbuilt feature): not environment; file
     per `ISSUE_QUEUE.md`. The scenario is UNBUILT_FEATURE, not BLOCKED-by-environment.
   - environment-structural (permanent): a
     `test/fixtures/uat/scenario-env-limitations/<scenario_id>.yaml` sidecar
     says this scenario cannot pass on this `--environment` slug for a
     structural reason (not a seeding/credential gap). No remediation is
     attempted. Confirm the sidecar's `applies_to_environments` and `review`
     condition are still accurate; if so, this GAP is expected and reported
     every run by design — do not loop trying to close it, and do not
     re-file it as a new issue (cite the sidecar's `issue_ref` instead). A
     sidecar's condition may additionally be scoped to specific expected
     outcomes via `applies_to_expected_outcomes: [<EO-id>, ...]`; when
     present, only those expected outcomes are exempted from Step 0
     remediation and are reported BLOCKED-by-environment — every other
     expected outcome in the same scenario is not exempted and must be
     verified normally by UAT-RUNNER.
   Re-run the preflight after each remediation round.
4. Only scenarios still unmet after prep are BLOCKED. Classify each:
   - BLOCKED-by-environment: `ENV_*`, `CREDENTIALS_MISSING`, `PRECONDITION_NOT_MET`,
     `ENV_NOT_SUPPORTED`.
   - `UNBUILT_FEATURE`: a real product gap, reported as such.
5. Verdict: a run where Step 0 was skipped, or where >0 BLOCKED-by-environment scenarios
   remain, is reported **`ENV_NOT_READY`** — never PASS/FAIL, never a UAT result, and it
   does not satisfy the UAT stage gate (`ORCHESTRATOR.md` §8). ORCH may still dispatch
   UAT-RUNNER for the scenarios whose manifest is met; the run as a whole stays
   `ENV_NOT_READY` until the rest are.
6. Dispatch UAT-RUNNER only with the preflight report path in the handoff `context`.
```

## Step 1 — Readiness check

**Agent:** `ORCH`

```
1. Confirm the target instance responds (health check, or a simple GET against a
   known route).
2. Confirm the scenario corpus for this stage exists under
   `test/fixtures/uat/scenarios/<company>/*.yaml` and
   `test/fixtures/uat/scenarios/platform/*.yaml` (see `.claude/agents/uat-runner.md`
   and ISS-0526/ISS-0527's design docs for the full shape).
3. Confirm this run's dispatch to UAT-RUNNER will carry an explicit environment target:
   `base_url` and `credential_source` (see `.claude/agents/uat-runner.md`'s "Environment
   target" section). Do not dispatch with an implicit/default target.
4. Confirm Step 0 completed and its preflight report path is available for the handoff.
5. If any check fails: do not dispatch UAT-RUNNER. Log BLOCKED, name what's missing.
```

## Step 2-3 — Run and report

**Agent:** `UAT-RUNNER`

```
0. Refuse a dispatch whose `context` lacks the preflight report path (return FAILED,
   naming it), and do not run any scenario the preflight lists as GAP — record it
   BLOCKED with the preflight's reason.
1. For each scenario: perform the described action against the real running instance
   via real HTTP calls (or, once web/ integration exists per S8, by driving the actual
   GUI — see REQ-107's manual-walkthrough precedent for what this looks like before a
   browser-automation tool is wired in).
2. For a scenario using the `branches:` construct (`docs/agents/uat-scenario-schema.md`),
   evaluate each branch's `when:` condition against this run's actual observed facts and
   run only the first matching branch, per `.claude/agents/uat-runner.md`'s "Evaluating a
   `when:` branch" procedure. Record which branch was run in the report.
3. Observe actual resulting state (not just "no error thrown") — query the instance
   back to confirm the expected state was reached.
3a. For a step with `expect_refusal: true`, follow `.claude/agents/uat-runner.md`'s "Refusal
   steps and actor access"; record `actors_observed` per scenario.
4. Record PASS/FAIL per scenario with the observed evidence, not an inferred one.
5. Write test/uat-reports/uat-<date>-<run-id>.yaml.
6. Complete the handoff: PASS if all scenarios passed, FAIL otherwise with each
   failing scenario named. If any scenario is BLOCKED-by-environment (not
   UNBUILT_FEATURE), the report's `result_overall` is `ENV_NOT_READY` instead — an
   all-BLOCKED run is never reported as a normal FAIL.
```

## Step 4 — PRODUCT-OWNER release recommendation

**Agent:** `PRODUCT-OWNER`

Runs once every `BA-<VERTICAL>` sign-off for this run_id has been written (see
`.claude/agents/ba-analyst.md`'s SIGN-OFF responsibility — dispatched by ORCH
per vertical, same as Step 2-3's UAT-RUNNER dispatch, for each vertical with
scenarios in this run's UAT report). Never runs in parallel with a
`BA-<VERTICAL>` sign-off step, and always runs strictly before
`RELEASE-VALIDATOR` — see `.claude/agents/product-owner.md`'s Relationship
section for why these are separate, non-substitutable gates.

```
1. Read every test/uat-reports/ba-signoff-*-<run_id>.yaml for this run_id, and
   test/uat-reports/uat-<date>-<run_id>.yaml.
2. Cross-check MUST-severity acceptance criteria for the requirement/stage batch
   under test against passing-scenario coverage.
3. Apply the single-BLOCKER-blocks-release rule.
3a. Apply the access gate: read `access_verdict` and `access_note` from every BA sign-off. The
    recommendation is NOT `APPROVED` if any sign-off has `access_verdict: FAIL`, or
    `access_verdict: NOT_COVERED` for a vertical that is not listed in `refusal_coverage_exempt`
    in `test/fixtures/uat/actors.yaml`. A missing `access_verdict` counts as `NOT_COVERED`.
    For platform-scope scenarios read the UAT report directly: any `expect_refusal` step recorded FAIL
    makes `release_recommendation` BLOCKED, with the same no-override rule.
4. Arbitrate any cross-vertical disagreement found; route to REQ-ANALYST if the
   underlying requirement is ambiguous.
5. Write test/uat-reports/po-signoff-<run_id>.yaml.
6. Complete the handoff: PASS if release_recommendation == APPROVED, FAIL
   (BLOCKED) otherwise, naming every blocking issue and its suggested_action.
```

PASS → this stage's UAT parity is confirmed **and** business-approved for
release; ORCH proceeds toward RELEASE-VALIDATOR / the stage-gate check in
`ORCHESTRATOR.md` §8.
FAIL (BLOCKED) → route per each issue's `suggested_action` (`route_to_wf03` /
`route_to_req_analyst` / `route_to_uat_runner` / `route_to_security_review`); an issue
with `route_to_security_review` is dispatched by ORCH to SECURITY-REVIEWER, never to WF-03
directly; then re-run this step once
resolved, per `.claude/agents/product-owner.md`'s rework policy (`max_rework: 1`).
