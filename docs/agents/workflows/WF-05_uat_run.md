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
      Any scenario FAIL?
      ├─ NO  → PASS, stage's UAT parity confirmed for this scenario batch
      └─ YES → file per ISSUE_QUEUE.md (or, if it blocks the current stage gate,
               route directly to WF-03 for this specific run rather than
               forwarding — a UAT failure on a stage-defining scenario is this run's
               own blocker, not an incidental one)
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
4. If either check fails: do not dispatch UAT-RUNNER. Log BLOCKED, name what's missing.
```

## Step 2-3 — Run and report

**Agent:** `UAT-RUNNER`

```
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
4. Record PASS/FAIL per scenario with the observed evidence, not an inferred one.
5. Write test/uat-reports/uat-<date>-<run-id>.yaml.
6. Complete the handoff: PASS if all scenarios passed, FAIL otherwise with each
   failing scenario named.
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
`route_to_req_analyst` / `route_to_uat_runner`), then re-run this step once
resolved, per `.claude/agents/product-owner.md`'s rework policy (`max_rework: 1`).
