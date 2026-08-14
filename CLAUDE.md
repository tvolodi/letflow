# CLAUDE.md — Letflow

Read automatically by Claude Code at session start. Letflow (working
name during early development: RoCo) is the full migration target for
R-Co (see `README.md`) — this file stays short on purpose; it is a
pointer, not a rulebook.

## What this project is

The staged Elixir/OTP rewrite of R-Co
(`c:\Users\tvolo\dev\ai-dala\R-Co\`), a multi-tenant BPM platform. See
`README.md` in full before doing anything, especially "Migration
status." `docs/migration/README.md` has the full stage breakdown
(S0–S8) and the R-Co source paths each stage ports — read the relevant
stage file before starting work in that stage. A few findings from
early development (idiomatic OTP usage, process-per-instance design)
are folded directly into the stage-2 and stage-3 migration docs where
they're still relevant, rather than tracked separately.

## Agent roster

This project uses a 4-agent system, intentionally much smaller than
R-Co's own 18-role multi-agent pipeline
(`c:\Users\tvolo\dev\ai-dala\R-Co\`) — no handoff files, no workflow
YAML, no dual-harness mirroring. **The roster is expected to grow as
migration stages define real subsystem boundaries** (e.g. a dedicated
identity/OIDC role once Stage 1 starts, a frontend role once Stage 8
starts) — but only when a stage actually needs it, not preemptively.
Match the roster to the active stage's real complexity.

| `AGENT_ID` | Role | Canonical instructions |
|---|---|---|
| `ORCH` | Routes work, classifies requests, delegates, reports outcome. Never writes application code itself. | [`.claude/agents/orchestrator.md`](.claude/agents/orchestrator.md) |
| `ELIXIR-DEV` | Implements/changes `lib/letflow/` and `priv/repo/migrations/` | [`.claude/agents/elixir-dev.md`](.claude/agents/elixir-dev.md) |
| `TEST-RUNNER` | Runs `mix test`, diagnoses failures, maintains the property test | [`.claude/agents/test-runner.md`](.claude/agents/test-runner.md) |
| `REVIEWER` | Checks changes for idiomatic OTP usage (crutch vs. real behaviour), supervision integrity, and scope creep, and gates migration-stage work against `docs/migration/decisions/` records | [`.claude/agents/reviewer.md`](.claude/agents/reviewer.md) |

**Default `AGENT_ID`:** if none is stated, default to `ORCH`. For a
small single-file fix, `ORCH` may act directly rather than formally
delegating — see the "keep it light" rule below.

## Where work comes from

`docs/requirements.yaml` is the source of truth for work packages —
each is sized to one agent turn with an explicit `owner`,
`description`, and `acceptance_criteria`. Before starting unscoped
work ("build the next thing"), check it for the next `pending`
requirement whose `depends_on` are all `done`. When told to work on a
specific `REQ-XXX`, read its entry in full before touching code.

Every requirement carries a `stage` (S0–S8, tie back to
`docs/migration/`). `docs/migration/stage-N-*.md` holds migration
design rationale and REVIEWER sign-off per stage. Only Stage 0 is
currently broken into requirements — if the next `pending` requirement
doesn't exist yet because its stage hasn't been expanded, that's
expected; expand the next stage's requirements (matching this file's
existing sizing/schema) rather than skipping ahead into an unscoped
stage.

After finishing a requirement: flip its `status` in
`docs/requirements.yaml`, and append one event to
`docs/status/requirement_status.yaml` (started/done/blocked, with a
real UTC timestamp — from the clock, not memory).

## Core rules (apply to every agent)

- **No speculation.** Never report "this should work" or "tests
  should pass." Run it (`mix test`, `mix compile`) and quote the
  actual result. If you can't run it in this environment — no
  toolchain, or `mix deps.get` has no network access (see README
  Notes) — say so explicitly instead of guessing.
- **Zero manual work.** Don't tell the user to run a command you can
  run yourself. Apply migrations, run tests, start `docker compose`
  yourself.
- **Keep it light, but match effort to the active stage.** Don't build
  R-Co-style handoff-file machinery, workflow pipelines, or role
  ceremony a given stage doesn't need. Judge scope per-requirement/
  per-stage, not against the size of the earliest code in this repo.
- **Don't silently re-decide what a decision record already settled.**
  S0's decision records (`docs/migration/decisions/`) are load-bearing
  for every later stage — if a stage's requirement seems to need a
  framework/library choice that contradicts one already on record,
  flag it and get REVIEWER sign-off rather than quietly diverging.
- Check `docs/anti-patterns.md` before non-trivial changes, and add to
  it when you find a mistake worth not repeating.

## Mandatory reading at session start

- `README.md` (full)
- `docs/requirements.yaml` — find or confirm the requirement in scope
- `docs/migration/README.md` — stage breakdown
- `docs/anti-patterns.md` (if it has entries)
