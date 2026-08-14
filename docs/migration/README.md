# docs/migration/ — R-Co → Elixir staged migration

This directory holds the design rationale behind each migration
stage (S0–S8, defined in `docs/requirements.yaml`'s `stages:` list) —
the detail that doesn't fit that file's terse requirement schema, plus
cross-links to the specific R-Co source paths each stage ports.

R-Co lives at `c:\Users\tvolo\dev\ai-dala\R-Co\`. Every stage file
below cites real paths confirmed to exist there as of 2026-08-14 —
if a cited path is gone or renamed by the time you read this, that's
drift to reconcile, not a typo to silently work around.

## Stage index

| Stage | Name | Depends on | Detail file |
|---|---|---|---|
| S0 | Foundation & scaffolding | — | [stage-0-foundation.md](stage-0-foundation.md) |
| S1 | Identity & multi-tenancy | S0 | [stage-1-identity.md](stage-1-identity.md) |
| S2 | Event store & workflow definitions | S1 | [stage-2-event-store-definitions.md](stage-2-event-store-definitions.md) |
| S3 | Instance engine | S2 | [stage-3-instance-engine.md](stage-3-instance-engine.md) |
| S4 | API surface | S3 | [stage-4-api-surface.md](stage-4-api-surface.md) |
| S5 | Scripting & plugins | S3 | [stage-5-scripting-plugins.md](stage-5-scripting-plugins.md) |
| S6 | Operational cross-cutting | S4 | [stage-6-operational-cross-cutting.md](stage-6-operational-cross-cutting.md) |
| S7 | Simulation & UAT parity | S4, S5, S6 | [stage-7-simulation-uat-parity.md](stage-7-simulation-uat-parity.md) |
| S8 | Frontend integration & cutover | S7 | [stage-8-frontend-cutover.md](stage-8-frontend-cutover.md) |

S5 branches off S3 in parallel with S4 (both only need the instance
engine, not each other) — everything else is a straight chain.

## Convention

Each stage file has three parts once work starts on it:

1. **Scope** — what's being ported, with real R-Co file/dir paths.
2. **Decisions** — links into `decisions/` for anything stage-specific
   that needs a recorded rationale (framework choices, library
   adoption, data-model tradeoffs). S0's decisions apply platform-wide;
   later stages only need their own file if they face a genuinely new
   choice.
3. **REVIEWER sign-off** — dated entries, append-only: a log, not a
   summary. An honest "not ready, here's why" entry is as valid as a
   "go" entry.

Stage files are created by the requirement that first needs them, not
pre-seeded — an empty or skeletal stage-N file before that stage's
first requirement runs is expected.

## Requirement expansion

Only Stage 0 is currently broken into `docs/requirements.yaml`
requirements (REQ-010..014). Expand a later stage into requirements
only once the stage(s) it `depends_on` are done — sizing a stage's
requirements correctly generally requires the interfaces/decisions the
prior stage produced. Follow the same schema and one-agent-turn sizing
as the existing requirements.
