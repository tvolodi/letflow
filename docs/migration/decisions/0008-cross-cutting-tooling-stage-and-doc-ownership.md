# 0008 — Stage tag for non-porting tooling requirements, and ownership of workflow/role docs

Status: proposed, pending REVIEWER confirmation at REQ-114's WF-02 Step 2d gate.
Owner: ORCH → REVIEWER.

## Question

REQ-VALIDATOR's WF-01 gate on REQ-113/REQ-114 (`WF01-TESTPARALLEL-20260821`, the
mix-test-partitioning capability) surfaced two schema/roster gaps that neither
REQ-ANALYST nor REQ-VALIDATOR should resolve unilaterally per
`core-directives.md`'s Zero Manual Work item 1 ("two or more genuinely equivalent
options... no agent can infer... file it as a decision draft, do not silently pick
one and do not stall waiting for a human to answer"). Both are process/schema
questions, not architecture, so this file is intentionally lighter than 0001-0005.

**1. `stage:` tag for a requirement that is dev-pipeline tooling, not an R-Co
source-path port.** `docs/requirements.yaml`'s `stages:` block (S0-S8) is defined
entirely in terms of R-Co subsystem ports (S0's own description is a closed,
already-fully-done itemized list: Phoenix decision, OIDC decision, Ecto schema
strategy, the `zig build check`-equivalent gate, and a wrap-up REVIEWER verdict).
REQ-013 (the prior "single-command check gate" precedent REQ-ANALYST cited) fit S0
because it is item 5 of that closed list verbatim — not because it was tooling
drafted during S0's timeframe. Test-suite parallelization matches none of the five
S0 items, and no other stage's description fits a cross-cutting tooling concern
either (every other stage is also a closed R-Co-source-path port).

Options:
- **(A)** Tag with whichever stage is currently active/in-progress at draft time
  (S4 as of 2026-08-21). No schema change; the tag becomes "which stage's pipeline
  this tooling was built to speed up," not a claim of subsystem lineage.
- **(B)** Add a dedicated non-chained tag (e.g. a `cross-cutting` value alongside
  S0-S8, or a new `S-TOOLING` stages: entry with `depends_on: []` that never gates
  anything). Requires a `docs/requirements.yaml` schema-comment update and
  REQ-VALIDATOR's stage-fit check (c) to special-case it.
- **(C)** Tag with the nearest downstream stage the tooling primarily unblocks.
  Rejected here as too vague for a requirement with no single downstream stage
  (this one serves every future WF-02/03/04 run, not one stage).

**Provisional pick (this file): Option A.** Smallest deviation from the existing
schema, and reads honestly ("built during S4, no subsystem-port claim implied")
rather than requiring a schema amendment for what is, so far, a single instance.
Revisit as Option B if a second non-porting tooling requirement shows up and the
pattern repeats. REQ-113 and REQ-114 are tagged `stage: S4` under this pick.

**2. Ownership of edits to `docs/agents/workflows/*.md` and `.claude/agents/*.md`.**
`docs/agents/AGENT_SYSTEM.md` §6's Artifact locations table marks both paths
"canonical, hand-maintained" with no producing role assigned — a real gap now that
a requirement (REQ-114) needs one of them edited under humanless operation.
DOC-UPDATER's own enumerated remit (§3) is `docs/requirements.yaml`'s status field,
`docs/status/requirement_status.yaml`, `README.md`, and stage/decision docs a
requirement names — workflow/role docs are outside that list as written.
ELIXIR-DEV's remit is `lib/`, `priv/repo/migrations/`, `config/*.exs` only.
ORCH-direct is disqualified outright by `ORCHESTRATOR.md` §10 check 1 (REQ-114
touches 2-4 files, not exactly one).

Options:
- **(A)** Widen DOC-UPDATER's remit to include `docs/agents/workflows/*.md` and
  `.claude/agents/*.md` whenever a requirement's `acceptance_criteria` explicitly
  names them. Smallest generalization of an existing "docs" role.
- **(B)** Widen the remit of whichever role owns the requirement this one
  `depends_on` (here, ELIXIR-DEV, continuing from REQ-113) for the specific case of
  "wire a tool I just built into the pipeline docs that invoke it."
- **(C)** A new standing exception to `ORCHESTRATOR.md` §10's sizing rule
  specifically for `docs/agents/` and `.claude/agents/` edits, since ORCH already
  directly maintains `handoffs/registry.json` per its own MUST list — extend that
  precedent to pipeline-doc maintenance generally.

**Provisional pick (this file): Option A.** REQ-114's owner is `DOC-UPDATER` under
this pick. `docs/agents/AGENT_SYSTEM.md` §3/§6 should be updated to state this
widened remit explicitly — filed as a follow-on note rather than done inline here,
since editing AGENT_SYSTEM.md itself is exactly the kind of change this decision is
about and shouldn't be done by the same pass that's still proposing the rule.

## What happens next

Both picks are provisional, not final — REVIEWER confirms or overrides at REQ-114's
WF-02 Step 2d gate (idiom/process-consistency review), per this file's Status line.
If REVIEWER overrides either pick, it appends a dated sign-off section here (same
append-only convention as a stage file's REVIEWER sign-off section) rather than a
new decision file, since the question doesn't change — only the answer might.
