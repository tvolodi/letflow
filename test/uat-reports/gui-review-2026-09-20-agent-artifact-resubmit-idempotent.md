# GUI review: agent-artifact-resubmit-idempotent (PW-11)

Date: 2026-09-20
Reviewer: ORCH
Scenario: `test/fixtures/uat/scenarios/platform/agent-artifact-resubmit-idempotent.yaml`
Severity class: n/a — out of scope, not a defect or a gap in shipped scope

This is the **18th and final scenario** of today's GUI-review sweep.

## Path taken

Path 2, with a prior step this scenario specifically called for: before checking
whether *any* GUI screen exists to drive, confirm the underlying feature this
scenario describes is even part of Letflow's product at all. The task brief carried
an explicit warning that this scenario's sibling
(`platform-sandbox-cross-tenant-probe.yaml`, flagged during ISS-0527's own porting
pass) targets "R-Co's own unbuilt runtime-agent subsystem" and should not be
mis-mapped onto an unrelated existing module. That warning held here too.

## What was checked, and what each check showed

### 1. `docs/issues/ISS-0527.yaml` and the sibling scenario's own NOTE

Read in full. ISS-0527 ported all 18 `platform/` scenario files verbatim from R-Co
and flagged two for SECURITY-REVIEWER attention. `platform-sandbox-cross-tenant-probe.yaml`
(PW-12, `sys-agent-sandbox-ownership`) carries a NOTE stating Letflow never built the
equivalent runtime-agent subsystem, and specifically warns against mapping it onto
`Letflow.SandboxPool` (semantically unrelated: an internal ephemeral-Postgres-schema
pool for definition-promotion assertion reruns, no tenant-facing API, no
worker/claim/release concept).

This scenario (PW-11, `sys-agent-artifact-lifecycle`) is a direct sibling in the same
`sys-agent-*` group — worth checking for the exact same category of gap.

### 2. Backend search (`lib/letflow/`)

Grepped exhaustively for every concept the scenario's steps require:
`instruction_kind`, `repeatability_setting`, `attempt_number`, `delivery_reference`,
`authoring_agent`, `coordinating_agent`, content-hash/idempotency-by-attempt
semantics, and a reviewer-acceptance console. Zero hits for any of it as a real
implemented concept.

The two closest-sounding existing modules were read in full and ruled out:

- `Letflow.Repository.Artifact` (`lib/letflow/repository/artifact.ex`) — a
  content-addressed blob store for **process-definition promotion artifacts**
  (REQ-202), keyed by SHA-256 content hash. No attempt-number concept, no
  agent/worker actor, no reviewer-acceptance workflow of its own — it's the storage
  layer definitions/promotions use, unrelated to an autonomous-worker submission
  pipeline.
- `Letflow.RowApproval` (`lib/letflow/row_approval.ex`) — a two-approver
  (finance/ops) sign-off mechanism for a generic instance-shaped approval row.
  Structurally the nearest thing to "a reviewer accepts an entry," but has no
  delivery/attempt/dedup concept and no connection to agent-submitted work.

Neither is a real match; forcing either into this scenario's role would test the
wrong mechanism, the same mistake ISS-0527 already warned against for the sibling
file.

### 3. `lib/letflow/router.ex`'s own "Deferred routes" table

This settled it conclusively. The moduledoc's deferred-routes table lists:

| Letflow module (pending) | R-Co source | Owning stage |
|---|---|---|
| `Letflow.Routers.AgentRequests` | `agent_task_specs.zig` | post-S6 (runtime-agent subsystem) |
| `Letflow.Routers.AgentResponses` | `agent_sandboxes.zig` | post-S6 (runtime-agent subsystem) |
| `Letflow.Routers.AgentEvents` | `agent_artifacts.zig` | post-S6 (runtime-agent subsystem) |

`agent_artifacts.zig` is exactly this scenario's own source concept (artifact
delivery/dedup). "Post-S6" in this router comment is a leftover placeholder, not a
live commitment: `docs/migration/README.md`'s full S0-S9 stage table was checked and
no stage — S7 (simulation/UAT parity), S8 (frontend), or S9 (mobile, the only stage
that still doesn't exist) — claims this subsystem. It was never scheduled anywhere
past being named in this one deferred-routes stub row.

### 4. Frontend search (`web/src/`)

Grepped case-insensitively for `review.?console`, `PendingReview`, `WorkReview`,
`AgentReview`: zero hits. No screen exists for a reviewer to open, confirm one entry,
or accept it.

## Disposition

**WONTFIX / out of scope — filed as `ISS-0740` (`status: closed_not_applicable`),
not as a REQ-NNN "build the missing feature" entry.**

This is the key distinction from most of today's other findings (e.g.
`attachment-cross-tenant-probe`'s REQ-386/387/388): those gaps sit within features
Letflow already committed to building and simply hasn't finished (signed-link
expiry, audit logging on a denied read). This scenario's subject — R-Co's own
automated-coding-worker artifact-submission pipeline, complete with a
`coordinating_agent`/`authoring_agent`/`sweeper` actor split — was never adopted
into Letflow's actual scope by any migration stage, and nothing in
`docs/migration/README.md`'s S0-S9 breakdown says it will be. Building a
requirement to construct this now would silently re-decide that scope on the
strength of one ported test-fixture file, which is exactly what `core-directives.md`
and this project's decision-record discipline warn against.

A NOTE was added to the scenario file itself (same convention ISS-0527 used for the
sibling file) so a future reader hits the explanation immediately rather than
re-deriving it. Unlike the sibling file, there is no existing Letflow module a
reader might mistakenly map this onto — the subsystem is simply absent, so the NOTE
states that plainly rather than warning off a specific near-miss module.

## Spec status

No Playwright spec was authored. There is no feature, screen, or API surface for one
to exercise — writing a spec here would either be permanently skipped (dead weight)
or would have to fake the very subsystem this report just confirmed doesn't exist.
If Letflow's scope is ever extended to include a runtime-agent subsystem, the spec
belongs with that future work, not backfilled now against nothing.

## Sibling-session note

`git status`/`git fetch origin main` were checked before this report was finalized;
no conflicting local changes. A sibling session (`gui-review-continuation`) was
concurrently finishing scenario 17 of 18 (`definition-promotion-approved`, a live
verification pass against `qa.bizdala.com`) — confirmed via direct message exchange
before this report and the sweep's capstone summary were finalized, so both land
together without either being written from a stale view of the other's outcome.
