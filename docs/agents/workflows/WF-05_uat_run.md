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
2. Confirm the scenario corpus for this stage exists under test/uat-reports/scenarios/
   (or wherever S7's own requirements land it — this workflow doc doesn't prescribe
   the exact corpus format ahead of S7 defining it, since
   docs/migration/stage-7-simulation-uat-parity.md notes R-Co's own scenario format
   as the thing being ported, not invented fresh).
3. If either check fails: do not dispatch UAT-RUNNER. Log BLOCKED, name what's missing.
```

## Step 2-3 — Run and report

**Agent:** `UAT-RUNNER`

```
1. For each scenario: perform the described action against the real running instance
   via real HTTP calls (or, once web/ integration exists per S8, by driving the actual
   GUI — see REQ-107's manual-walkthrough precedent for what this looks like before a
   browser-automation tool is wired in).
2. Observe actual resulting state (not just "no error thrown") — query the instance
   back to confirm the expected state was reached.
3. Record PASS/FAIL per scenario with the observed evidence, not an inferred one.
4. Write test/uat-reports/uat-<date>-<run-id>.yaml.
5. Complete the handoff: PASS if all scenarios passed, FAIL otherwise with each
   failing scenario named.
```

## Deferred: business-owner personas

R-Co's `BO-SWIFTROUTE`/`BO-VORTEX`/`BO-MERIDIAN`/`PRODUCT-OWNER` roles evaluate UAT
results from a specific tenant's business perspective. Letflow has no tenant business
scenario corpus yet — this workflow runs without persona-based sign-off until S7
actually defines one, per `docs/migration/decisions/0004-humanless-pipeline.md`. Until
then, RELEASE-VALIDATOR's own check (WF-04 Step 2) is the closest equivalent gate.
