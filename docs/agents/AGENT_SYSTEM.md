# Letflow — Agent System Overview

**Audience:** every agent operating within this project. Read this before beginning any
task, alongside `docs/agents/instructions/core-directives.md`.

---

## 1. Purpose

This is the root reference for Letflow's multi-agent development pipeline. It replaces
the earlier 4-agent roster (`ORCH`/`ELIXIR-DEV`/`TEST-RUNNER`/`REVIEWER`) with the full
roster below, per `docs/migration/decisions/0004-humanless-pipeline.md` — every
producing role is paired with a validating role, the pipeline runs commit-to-merge
without a human gate, and every role file is written explicitly enough for a
weak/inexpensive model to execute reliably.

## 2. Core principle

**The system is the documentation.** Agents don't hold state in memory between
sessions — state lives in `docs/requirements.yaml`, `docs/status/`, `handoffs/`, and
the codebase itself.

**Every producing step has a validating step.** See `core-directives.md`'s
producer/validator table — restated here as the roster's organizing shape.

---

## 3. Agent roster

| Agent ID | Role | Responsibility | May write to |
|---|---|---|---|
| `ORCH` | Orchestrator | Routes work, classifies requests, delegates, escalates. Does no implementation work itself. | `handoffs/`, `docs/status/`, `docs/requirements.yaml` (status field only) |
| `REQ-ANALYST` | Requirement Analyst | Drafts and structures requirements into `docs/requirements.yaml` | `docs/requirements.yaml`, `handoffs/` |
| `REQ-VALIDATOR` | Requirement Validator | Validates requirements for completeness, testability, consistency with existing requirements and decision records | `handoffs/` |
| `CODE-DESIGNER` | Code Designer | Produces module interfaces, `@spec`s, gen_statem/Ecto shape, and data-flow notes before any implementation code is written | `lib/letflow/design/`, `handoffs/` |
| `CODE-DESIGN-VALIDATOR` | Code Design Validator | Reviews CODE-DESIGNER's artefact — every acceptance criterion covered, no implementation code present, design is unambiguous enough for ELIXIR-DEV/FRONTEND-DEV to proceed. **Hard gate.** | `handoffs/` |
| `ELIXIR-DEV` | Elixir Developer | Implements `lib/letflow/` and `priv/repo/migrations/` per the design artefact | `lib/`, `priv/repo/migrations/`, `config/*.exs`, `handoffs/` |
| `FRONTEND-DEV` | Frontend Developer | Integration/config wiring of `web/` (R-Co's existing React/TS SPA) against Letflow's API — not a rewrite of `web/`, per `docs/migration/stage-8-frontend-cutover.md`'s own scope framing | `web/` (config/integration only), `handoffs/` |
| `REVIEWER` | Idiom & Scope Reviewer | Checks changes for idiomatic OTP usage (crutch vs. real behaviour), supervision integrity, scope creep, and consistency with `docs/migration/decisions/` records | `handoffs/`, `docs/migration/stage-N-*.md` (REVIEWER sign-off sections only) |
| `SECURITY-REVIEWER` | Security Reviewer | Gates any change touching a tenant-data path against `docs/agents/instructions/security-invariants.md`. **Hard gate for in-scope changes.** | `handoffs/` |
| `TEST-DESIGNER` | Test Designer | Produces test specs and test code (ExUnit, StreamData properties) | `test/specs/`, `test/`, `handoffs/` |
| `TEST-DESIGN-VALIDATOR` | Test Design Validator | Reviews TEST-DESIGNER's output — every MUST acceptance criterion has a runnable test, no skipped/deferred coverage, fixtures are isolated. **Hard gate.** | `handoffs/` |
| `TEST-RUNNER` | Test Runner | Executes `mix test`, diagnoses failures, produces a structured test report | `test/reports/`, `handoffs/` |
| `ISSUE-FIXER` | Issue Fixer | Root-cause diagnosis for a queued issue (WF-03 Step 0.5/1). Does not implement the fix itself — routes to ELIXIR-DEV/FRONTEND-DEV once CODE-DESIGNER has a fix design | `docs/issues/`, `handoffs/` |
| `RELEASE-VALIDATOR` | Release Validator | Validates a stage/requirement-batch meets all MUST acceptance criteria before it's marked RELEASED; re-runs the full suite rather than trusting TEST-RUNNER's report alone | `handoffs/`, `docs/status/` |
| `DOC-UPDATER` | Documentation Updater | Updates `docs/requirements.yaml` status, `docs/status/requirement_status.yaml`, `README.md` where it documents current behavior, and any stage/decision doc a requirement's acceptance criteria named | `docs/`, `README.md`, `handoffs/` |
| `UAT-RUNNER` | UAT Runner | Executes scenario-based acceptance checks against a running Letflow instance once one exists to test against; role defined now, scenario corpus deferred to S7 (`docs/migration/stage-7-simulation-uat-parity.md`) | `test/uat-reports/`, `handoffs/` |

**Deliberately not reproduced yet:** R-Co's `BO-SWIFTROUTE`/`BO-VORTEX`/`BO-MERIDIAN`
business-owner personas and `PRODUCT-OWNER` — see
`docs/migration/decisions/0004-humanless-pipeline.md`'s "What is explicitly NOT
reproduced" section. These represent fictional tenant companies' business interests
during UAT; Letflow has no tenant business scenario corpus yet (that's S7). Adding them
before S7 starts would be scope creep against a stage that hasn't been reached.

### 3.1 Capability matrix

| Agent | Reads | Writes | Runs terminal commands | Spawns subagents |
|---|:---:|:---:|:---:|:---:|
| `ORCH` | ✓ | handoffs, status only | ✗ | ✓ |
| `REQ-ANALYST` | ✓ | ✓ | ✗ | ✗ |
| `REQ-VALIDATOR` | ✓ | handoffs | ✗ | ✗ |
| `CODE-DESIGNER` | ✓ | ✓ | ✗ | ✗ |
| `CODE-DESIGN-VALIDATOR` | ✓ | handoffs | ✗ | ✗ |
| `ELIXIR-DEV` | ✓ | ✓ | ✓ (mix, git, gh) | ✗ |
| `FRONTEND-DEV` | ✓ | ✓ (web/ config only) | ✓ (npm, git, gh) | ✗ |
| `REVIEWER` | ✓ | handoffs, stage sign-off | ✗ | ✗ |
| `SECURITY-REVIEWER` | ✓ | handoffs | ✓ (grep-based checks, mix test) | ✗ |
| `TEST-DESIGNER` | ✓ | ✓ | ✗ | ✗ |
| `TEST-DESIGN-VALIDATOR` | ✓ | handoffs | ✗ | ✗ |
| `TEST-RUNNER` | ✓ | reports | ✓ (mix test only) | ✗ |
| `ISSUE-FIXER` | ✓ | docs/issues only | ✗ | ✗ |
| `RELEASE-VALIDATOR` | ✓ | status | ✓ (tests) | ✗ |
| `DOC-UPDATER` | ✓ | ✓ | ✗ | ✗ |
| `UAT-RUNNER` | ✓ | uat-reports | ✓ (HTTP calls against a running instance) | ✗ |

---

## 4. Handoff system

Agents communicate through handoff files under `handoffs/<RUN-ID>/`. Full schema,
timestamp rules, and completion mechanics: `docs/agents/shared/HANDOFF_PROTOCOL.md`.

For a genuinely single-file, single-concern request, ORCH may act directly rather than
formally spawning a subagent and writing a handoff file — this stays true from the
earlier 4-agent system and is not overridden by the fuller roster (see
`docs/agents/ORCHESTRATOR.md`'s sizing note). The handoff-file machinery exists for
multi-step work where independent validation actually matters; forcing it onto a
one-line typo fix would be ceremony without benefit.

---

## 5. Requirement status tracking

`docs/requirements.yaml`'s `status:` field is authoritative for a requirement's current
state (`pending | in_progress | done | blocked`) — this file's schema is **not**
replaced by the fuller pipeline, only routed through it. `docs/status/requirement_status.yaml`
remains the append-only event history (started/done/blocked), same as before.

The pipeline overlays a finer-grained status internal to a single WF-02 run (tracked in
that run's handoff files, not in `docs/requirements.yaml` itself):

```
pending → validated → designed → design-reviewed → implemented →
test-designed → test-design-reviewed → tested → released
```

Only `pending`, `in_progress`, `done`, `blocked` are ever written to
`docs/requirements.yaml` — the finer states above live in the run's own handoffs, so a
requirement's file-level status stays exactly as terse as it's always been.

---

## 6. Artifact locations

| Type | Location | Owner | Format |
|---|---|---|---|
| Elixir source | `lib/` | `ELIXIR-DEV` | `.ex` |
| Ecto migrations | `priv/repo/migrations/` | `ELIXIR-DEV` | `.exs` |
| Frontend integration | `web/` (config/wiring only) | `FRONTEND-DEV` | `.ts`/`.tsx`/config |
| Design artefacts | `lib/letflow/design/` | `CODE-DESIGNER` | `.md` |
| Test specs | `test/specs/` | `TEST-DESIGNER` | `.md` |
| Test source | `test/` | `TEST-DESIGNER` | `.exs` |
| Test reports | `test/reports/` | `TEST-RUNNER` | `.yaml` |
| UAT reports | `test/uat-reports/` | `UAT-RUNNER` | `.yaml` |
| Handoff files | `handoffs/` | all (via ORCH) | `.json` (exception) |
| Requirement queue | `docs/requirements.yaml` | `ORCH`/`DOC-UPDATER` (status field) | `.yaml` (pre-existing schema, unchanged) |
| Requirement event history | `docs/status/requirement_status.yaml` | `DOC-UPDATER` | `.yaml` |
| Issue registry | `docs/issues/` | any agent (via ISSUE_QUEUE protocol) | `.yaml` |
| Release decisions | `docs/status/` | `RELEASE-VALIDATOR` | `.yaml` |
| Migration decision records | `docs/migration/decisions/` | any agent, REVIEWER sign-off | `.md` |
| Stage detail + REVIEWER sign-off | `docs/migration/stage-N-*.md` | `REVIEWER` | `.md` |
| Agent role files | `.claude/agents/*.md` | canonical, hand-maintained | `.md` |
| Cross-cutting instructions | `docs/agents/instructions/` | canonical, hand-maintained | `.md` |
| Protocols | `docs/agents/protocols/` | canonical, hand-maintained | `.md` |
| Workflows | `docs/agents/workflows/` | canonical, hand-maintained | `.md` |
| Developer guides | `docs/guides/` | canonical, hand-maintained | `.md` |
| Scratch | `scratch/` | any agent | any (git-ignored) |

**Output format rule:** YAML for everything except handoff files (JSON — machine-read
by ORCH as structured data). See `core-directives.md`.

---

## 7. Conflict prevention

An agent MUST check the registry (`handoffs/registry.json`) for a handoff already
`IN_PROGRESS` against the same artifact before starting. ORCH is responsible for
sequencing concurrent work to avoid collisions — see `docs/agents/ORCHESTRATOR.md`'s
`owned_modules` lock, same mechanism as R-Co's.

---

## 8. Agent identity contract

When an agent is invoked, it operates under a stated `AGENT_ID` from the roster above.
Default, if none is stated: `ORCH` — same default as the earlier 4-agent system, see
`CLAUDE.md`.

---

## 9. Canonical instruction surfaces

| Content | Canonical location |
|---|---|
| Per-`AGENT_ID` role instructions | `.claude/agents/*.md` |
| Cross-cutting rules binding every role | `docs/agents/instructions/core-directives.md` |
| Security invariants | `docs/agents/instructions/security-invariants.md` |
| Handoff lifecycle mechanics | `docs/agents/shared/HANDOFF_PROTOCOL.md` |
| Git branch/merge mechanics | `docs/agents/protocols/GIT_SETUP.md`, `GIT_MERGE.md` |
| Incidental-issue forwarding | `docs/agents/protocols/ISSUE_QUEUE.md` |
| Standard workflow step chains | `docs/agents/workflows/WF-*.md` |
| Roster, handoff schema, capability matrix, artifact locations | this document |
| Orchestration decision logic, stage gates | `docs/agents/ORCHESTRATOR.md` |

`CLAUDE.md` stays a pointer file — it names the roster and links here, it does not
restate role instructions.
