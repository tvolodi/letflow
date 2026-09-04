# 0004 — Full agent pipeline, humanless operation, redundant validation

Status: decided. Owner: ORCH (user-directed).

## Question

R-Co runs an 18-role agent pipeline with a producer/validator pair for nearly every
step, JSON handoff files, a mandatory git-setup/git-merge wrapper, and a human-free
commit→push→merge→CI loop. Letflow's `CLAUDE.md` originally described a deliberately
smaller 4-agent system ("keep it light... roster grows only when a stage actually needs
it"), reasoning that R-Co's ceremony was overhead a young, single-track migration
codebase didn't yet need.

The user overrode that framing directly: reproduce R-Co's full agent system in Letflow,
not a trimmed version, and apply the same principles both to Letflow's own development
(this VS Code / Claude Code environment) and — later, as its own migration-stage
capability, not built yet — to Letflow's runtime, where end-users' business processes
get designed, implemented, tested, and deployed by agents with no human in the loop
either.

## Decision

Adopt R-Co's full agent-pipeline shape for Letflow's own development, with three
non-negotiable principles carried forward exactly as stated by the user, not softened:

1. **Every producing agent has a paired validating agent.** Requirement drafting →
   requirement validation. Design → design validation. Backend/frontend implementation →
   idiom review + security review. Test design → test-design validation. Documentation
   update → an independent check that the update actually happened. No step's completion
   is accepted on the producer's own say-so.

2. **Fully humanless operation.** Requirement → design → implementation → test →
   validation → UAT → commit → push → merge → CI → local-repo-update, all performed by
   agents at their own discretion, with no human approval gate anywhere in the chain.
   Merge itself is bounded, not unconditional, by `main`'s required-status-checks branch
   protection (0018): the ordinary merge command succeeds only when both CI gates are
   green, and bypassing a red or pending gate requires the same agent to take a second,
   distinct, individually-logged action (`--admin`) rather than being available by
   default — see 0018 for the full mechanism. This does not reintroduce a human
   checkpoint; it makes the agent's own judgement call visible in the merge history
   instead of invisible in an unprotected one.
   There is no production deployment and no real user data at stake at this stage of the
   project — errors are correctable via a later WF-03 (Issue Resolving) run, not
   prevented by adding a human checkpoint. This explicitly rejects R-Co's own §11
   "Workflow Skip Gate" pattern of asking a human before skipping ceremony — there is no
   human to ask, so ORCH may only skip what this file or `core-directives.md` explicitly
   pre-authorizes, never on its own judgement call.

3. **Documentation and role definitions are sized for weak-model execution.** Every
   role file, workflow doc, and developer guide must be explicit and mechanical enough
   that a small or inexpensive model, with no memory of this decision's reasoning beyond
   what's written down, still produces reliable, in-scope, average-or-better-quality work
   by following the steps as written. This is the justification for keeping R-Co's
   verbose, checklist-heavy style rather than Letflow's earlier terse-file style —
   redundancy here is not waste, it is what makes weak-model execution safe.

**Scope of this decision:** the full roster applies to *how Letflow itself is built*
(this repository's own `lib/letflow/`, `test/`, `priv/repo/migrations/`) starting now.
It does **not** yet build the runtime-mode capability (Letflow's own BPM engine letting
*its* end-users' business processes be agent-designed/implemented/tested/deployed) — that
is a distinct future migration-stage requirement, tracked as a forward note in
`docs/migration/README.md`, using the same three principles once it starts. Building
runtime-mode now, before the engine that would run it exists, would be scope creep
against the stage that hasn't been reached yet.

**What is explicitly NOT reproduced from R-Co, because it targets a problem Letflow
doesn't have yet:** the BO-SWIFTROUTE/BO-VORTEX/BO-MERIDIAN business-owner personas and
PRODUCT-OWNER role (R-Co's UAT layer exists to represent three fictional tenant
companies' business interests during acceptance testing — Letflow has no tenant business
scenarios to represent yet; UAT-RUNNER is defined now but the BO-persona layer is
deferred to when S7 actually starts and there is a concrete scenario corpus to validate
against, per `docs/migration/stage-7-simulation-uat-parity.md`). The full Python tooling
R-Co built to enforce its protocols mechanically (`lint_handoffs.py`,
`check_github_status.py`, `verify_schema_baseline.py`, etc.) is also not reproduced yet —
those scripts encode lessons from specific R-Co incidents (timestamp corruption,
registry truncation) that Letflow hasn't hit. The protocols they enforce are written
down in full; the enforcement scripts are noted as follow-up work
(`docs/agents/protocols/HANDOFF_PROTOCOL.md`'s "Enforcement" section) rather than
blocking this pass.

## Reasoning

The user was explicit that recommending a lighter roster "because something somewhere
is recommended" was not useful — the actual requirement is redundancy sufficient for
mediocre-model reliability, not minimalism. R-Co's own history (documented across
`docs/agents/instructions/core-directives.md` and `HANDOFF_PROTOCOL.md`'s cited
incidents — 1963-handoff audit finding 44%→0.4% compliance drop on unenforced
bookkeeping rules, 1340 lines of audit log destroyed by an unreviewed squash-merge) is
direct evidence that a pipeline without independent validation at every step degrades
silently under exactly the conditions Letflow will now run under: agents operating
without a human catching drift.

## Consequences

- `CLAUDE.md`'s "Agent roster" section changes from a 4-role table to the full roster
  in `docs/agents/AGENT_SYSTEM.md`.
- Every workflow that touches `lib/`, `priv/repo/migrations/`, or `test/` is wrapped in
  a git-setup/git-merge pair per `docs/agents/protocols/GIT_SETUP.md` and `GIT_MERGE.md`,
  and merges to `main` without waiting for human review. As of 0018, that merge is also
  gated by GitHub branch protection on `main`, not left to the wrapper's own discipline
  alone.
- `docs/requirements.yaml`'s existing schema (id/owner/status/description/
  acceptance_criteria/depends_on) is preserved — the new pipeline routes work through it,
  it does not replace it with R-Co's separate functional-requirements document.
