# MVP-1 — Minimum visible-GUI vertical slice

Status: not started. Requirements: none expanded yet
(`docs/requirements.yaml`, REQ-101..108 once added).

## Why this exists

MVP-1 is a **milestone**, not a 9th migration stage. The S0-S8 stages
in `docs/migration/README.md` are subsystem-scoped ports of specific
R-Co source directories; MVP-1 instead cuts a single thin path across
four of them (S0, S1, S3, S4) at deliberately reduced depth, with one
goal: get one real workflow visibly running end-to-end in R-Co's
existing `web/` GUI against a real (not stubbed) Elixir backend, as
fast as honestly possible.

It exists because, as of this writing, nothing beyond Stage 0 exists —
REQ-010..014 are all still `pending`, so no web-framework decision, no
Ecto schema strategy, and no OIDC decision have been made yet. A
useful GUI-visible milestone can't wait for all of S1-S4 to fully
land, but it also can't skip S0's decisions altogether (`CLAUDE.md`'s
"don't silently re-decide" rule) — MVP-1 is the smallest slice that
respects that constraint.

## Relationship to S0-S8

**MVP-1 does not satisfy or replace any of S0, S1, S3, S4.** Each MVP-1
requirement below is tagged with the real `stage:` it narrowly
front-runs, plus `milestone: MVP-1`, so the requirement tracker can
distinguish "the narrow MVP-1 slice through S1 is done" from "S1 is
done." Concretely:

- MVP-1 skips real OIDC/Keycloak entirely, substituting one seeded
  dev user + hardcoded bearer token. Real S1 (JIT provisioning, JWKS
  caching, multi-realm/tenant binding — `src/identity/`'s 18 files and
  `src/oidc/`'s 13 files) still has to happen later, in full. This
  shortcut is not a shortcut R-Co invented for this — `web/`'s own
  frontend spec
  (`R-Co/docs/BPM_Platform_Frontend_Requirements.md`, Constraints &
  Assumptions) already documents exchanging "credentials or a
  bootstrap token in development" for an API token, so MVP-1 is using
  a dev-mode path the frontend was already designed to support, not
  inventing a new one.
- MVP-1's Ecto schema (one `workflow_definitions` table, one
  `instances` table with a transition log) is not the eventual
  event-sourced store S2 needs, nor 143-migration parity, nor
  tenant-column multi-tenancy (single implicit tenant for MVP-1).
- MVP-1's engine is the existing `Letflow.ProcessInstance` /
  `Letflow.InstanceSupervisor` pattern generalized just enough to run
  from a stored definition row for one workflow shape — not the full
  definition-driven engine S3 needs (service task dispatch, plugin
  registry, Lua script audit).
- MVP-1's API is 3-4 Plug routes (list definitions, create instance,
  get instance, post transition) — not the other ~18 route modules
  and 7 middleware modules S4 eventually ports.
- MVP-1 does not touch `web/`'s own code (per S8's existing "the
  integration boundary, not a rewrite" framing) — only base-URL/CORS
  wiring so the existing SPA can reach the running Letflow API.

Where MVP-1's code can be reused as-is by the real stage later, that's
a bonus; where it can't, that's an accepted, explicitly named cost of
speed — not a hidden one. Every MVP-1 requirement's description says
so directly.

## Scope

One workflow definition (reuse the existing 4-state
draft→submitted→approved/rejected shape from
`lib/letflow/process_instance.ex`), create an instance, drive it
through a transition, observe the result — all visible in `web/`'s
real GUI, authenticated via a static dev bearer token (no login form
work; Keycloak SSO is out of scope for this milestone and separately
verifiable without Letflow).

## Decisions

REQ-101 records a short provisional note (not a full decision record)
on continuing with the existing Plug/Bandit router
(`lib/letflow/router.ex`) for MVP-1's 3-4 routes, explicitly
superseded by whatever `decisions/0001-web-framework.md` (REQ-010)
eventually decides for the real S4. No other new decision files are
expected — MVP-1 deliberately avoids decisions that would bind S1-S4's
real implementations.

## REVIEWER sign-off

(None yet — this milestone hasn't started. REQ-108 adds the first
entry, gating specifically on: every MVP-1 deliverable honestly
labeled provisional/narrow where it diverges from its real stage's
eventual scope, and nothing here contradicting an existing decision
record.)
