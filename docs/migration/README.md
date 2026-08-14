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

## Milestones vs. stages

Stages (S0-S8 above) are subsystem-scoped ports of specific R-Co
source directories — the full migration target. A **milestone** is a
different kind of thing: a thin, deliberately narrow slice cutting
across several stages at reduced depth, aimed at a concrete visible
outcome sooner than waiting for those stages to fully land would
allow. Milestones don't get an `id` in the `stages:` table above or a
slot in the dependency chain; they get their own detail file (e.g.
[mvp-1-vertical-slice.md](mvp-1-vertical-slice.md)) and their
requirements carry both a `stage:` (the real stage each requirement
narrowly front-runs) and a `milestone:` tag, so "the milestone's slice
through S1 is done" is never confused with "S1 is done." See
[mvp-1-vertical-slice.md](mvp-1-vertical-slice.md)'s "Relationship to
S0-S8" section for what that distinction looks like in practice.

## Requirement expansion

Only Stage 0 is currently broken into `docs/requirements.yaml`
requirements (REQ-010..014). Expand a later stage into requirements
only once the stage(s) it `depends_on` are done — sizing a stage's
requirements correctly generally requires the interfaces/decisions the
prior stage produced. Follow the same schema and one-agent-turn sizing
as the existing requirements.

## Two applications of the agent-pipeline principles (forward note, not built yet)

`docs/migration/decisions/0004-humanless-pipeline.md` records that Letflow's
development now runs the full agent-pipeline shape (producer/validator pairing,
humanless commit-to-merge, weak-model-sized documentation — see
`docs/agents/AGENT_SYSTEM.md`). That decision explicitly names **two** places the same
three principles apply, confirmed directly by the user rather than assumed:

1. **Building Letflow itself** (this repository, this VS Code / Claude Code
   environment) — live now, roster and workflows already in place.
2. **Letflow's own runtime**, once it exists as a BPM engine: end-users' business
   process requirements ("it would be good to have goods receiving") get designed,
   implemented, tested, validated, and deployed by agents at runtime, producing real
   screen forms, DB tables, and process logic — with the same no-human-gate,
   every-producer-has-a-validator, weak-model-reliable principles, not a looser set.

**Only (1) is built.** (2) is real future scope, not a hypothetical — but it is
explicitly *not* being designed or built now, because the BPM engine capable of hosting
agent-driven runtime process design doesn't exist yet (that's most of S2-S6). Building
runtime-mode agent orchestration ahead of the engine it would orchestrate would be
scope creep against stages that haven't been reached. When a later stage's
requirements reach the point where this becomes concrete — plausibly around S6
(scripting/plugins) or as its own milestone after S6, the same way MVP-1 cut across
stages — expand it into its own requirements at that point, applying
`docs/agents/AGENT_SYSTEM.md`'s roster shape to the runtime domain (a
`PROCESS-DESIGNER` agent role, a runtime equivalent of CODE-DESIGN-VALIDATOR for
business-process definitions, etc.) rather than inventing a different set of
principles for it.
