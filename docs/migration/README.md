# docs/migration/ — historical build record of Letflow's R-Co → Elixir migration

Letflow is a multi-tenant BPM platform in its own right (see the
top-level `README.md`); this directory is the historical record of how
it got built, not live instructions for how it should be shaped going
forward. It holds the design rationale behind each migration stage
(S0–S8, defined in `docs/requirements.yaml`'s `stages:` list) — the
detail that doesn't fit that file's terse requirement schema, plus
cross-links to the specific R-Co source paths each stage ported from.
The migration itself is effectively complete; what remains here is
provenance for why Letflow's design looks the way it does, useful when
a change touches code whose rationale traces back to a ported
decision.

R-Co, the predecessor system this project migrated from, lives at
`c:\Users\tvolo\dev\ai-dala\R-Co\`. Every stage file below cites real
paths confirmed to exist there as of 2026-08-14 — if a cited path is
gone or renamed by the time you read this, that's drift to reconcile
in the historical citation, not a typo to silently work around.

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
| S9 | Mobile tier | S4 | [stage-9-mobile.md](stage-9-mobile.md) |

S5 branches off S3 in parallel with S4 (both only need the instance
engine, not each other). S9 branches off S4 in parallel with S6-S8 (the
mobile tier needs API endpoints, not the SPA's cutover) — everything
else is a straight chain.

## The two clients

Two stages cover user-facing clients, and they are independent of each
other because they share a contract rather than code:

- **S8** covers `web/`, the React SPA. As of 2026-08-21 that code lives
  **in this repository** — it was migrated out of R-Co and Letflow owns
  it. S8 was re-scoped from "integration boundary only" to cover the
  frontend itself; see
  [decisions/0011-frontend-ownership.md](decisions/0011-frontend-ownership.md).
  Specification: [`../frontend/`](../frontend/).
- **S9** covers the Flutter mobile tier, which **does not exist** — not
  here and not in R-Co. What was migrated is its specification; see
  [decisions/0012-mobile-tier-stack.md](decisions/0012-mobile-tier-stack.md).
  Specification: [`../mobile/`](../mobile/).

S9 is the one stage that ports no R-Co source, because there is none to
port.

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
source directories — together, the full scope of the original
migration. A **milestone** is a
different kind of thing: a thin, deliberately narrow slice cutting
across several stages at reduced depth, aimed at a concrete visible
outcome sooner than waiting for those stages to fully land would
allow. Milestones don't get an `id` in the `stages:` table above or a
slot in the dependency chain; they get their own detail file and their
requirements carry both a `stage:` (the real stage each requirement
narrowly front-runs) and a `milestone:` tag, so "the milestone's slice
through S1 is done" is never confused with "S1 is done."

**MVP-1 (`REQ-101..108`) was the first milestone under this model —
cancelled by the user (commit `d41beb0`) before completion, its own
detail file deleted in the same commit; see `REQ-101..108`'s
`status: cancelled` entries in `docs/requirements.yaml` for the
authoritative record (updated 2026-08-17, `ISS-0022`).** No milestone
is currently active; this section documents the concept for whenever
the next one is proposed.

## Requirement expansion

Stage 0 (REQ-010..014) and Stage 1 (REQ-015..021) are fully expanded and
done. Stage 2 is expanded into requirements (REQ-022..042, 21 total) and
in progress — check each requirement's `status:` in `docs/requirements.yaml`
directly for current per-requirement state rather than a snapshot count
here, which goes stale between edits (see `ISS-0022`, 2026-08-17). Expand
a later stage into
requirements only once the stage(s) it `depends_on` are done — sizing a
stage's requirements correctly generally requires the interfaces/decisions
the prior stage produced. Follow the same schema and one-agent-turn sizing
as the existing requirements.

**S8 and S9 are a deliberate, user-directed exception to that rule
(2026-08-21).** Both were expanded while S4 is still in progress and S5-S7
have not started. The reason the rule exists — "you would be guessing at
interfaces the prior stage hasn't decided yet" — does not bind here, because
neither stage's requirements are guesses about Letflow's internals:

- **S8's** subject is a codebase that now exists in this repository and
  passes its own gates today. Its requirements are grounded in files, not
  in anticipated interfaces.
- **S9's** requirements are a *port of an existing specification*
  (R-Co's `docs/addon-2/`), and its three backend dependencies were
  verified against `lib/` rather than assumed — all three are gaps, which
  is precisely why S9 `depends_on: [S4]`.

What both stages' requirements deliberately avoid is pre-deciding anything
S4-S7 will settle: no S8 requirement names a response shape, and no S9
requirement specifies how the tenant-config route is implemented. Where a
question genuinely needs a later stage's output — S8's cutover strategy
needs S7's correctness signal — it is left recorded as open in the stage
file rather than answered early.

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
