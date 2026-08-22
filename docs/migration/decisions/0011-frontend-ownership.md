# 0011 — Letflow owns the frontend; `web/` is migrated, not referenced

Status: decided (2026-08-21, user-directed). Owner: FRONTEND-DEV.

## Question

Through S0–S7, Letflow's plan treated the frontend as **someone else's code**.
`docs/migration/stage-8-frontend-cutover.md` said it directly:

> Point R-Co's `web/` (React/TypeScript) — or a compatible surface — at the
> Elixir backend instead of the Zig one. […] `web/` itself is out of scope to
> rewrite — this stage is about the integration boundary, not porting the
> frontend.

`docs/guides/frontend_developer_guide.md` and `.claude/agents/frontend-dev.md`
both hard-coded that narrow mandate ("Letflow does not own a frontend codebase
to build UI features in"). The question this record settles: does the frontend
stay in the R-Co repository and get *pointed at* Letflow, or does it move into
Letflow and become Letflow's own?

## Decision

**The frontend moves.** R-Co's `web/` was migrated into this repository on
2026-08-21, together with its specification (`docs/frontend/`). Letflow owns it:
changes are made here, gated here, merged here. `web/` is no longer "out of
scope to rewrite" — it is a first-class subsystem of this repository, on the
same footing as `lib/letflow/`.

The same commit migrates the mobile tier specification and gives it a stage —
see [`0012-mobile-tier-stack.md`](0012-mobile-tier-stack.md).

## Reasoning

**1. The original framing had an expiry date built into it.** "Point `web/` at
the Elixir backend" describes a moment, not a steady state. Once the Zig backend
is deprecated — which is S8's own stated job — a frontend living in the Zig
repository has no repository. The narrow mandate was correct for as long as R-Co
was the running system and Letflow was the newcomer; it stops being correct at
precisely the point S8 executes.

**2. Integration work is not separable from frontend work in practice.** S8's
scope note anticipated this and half-admitted it: *"Close any API-contract gaps
found in practice (this is where undocumented behavior the earlier stages'
route-by-route port missed will actually surface)."* A contract gap surfaces as
a broken screen. Fixing it means changing a response shape **or** changing a
component, and the guide's rule — always fix it on the Letflow side, never adapt
inside `web/` — is only enforceable when both sides are one codebase with one
gate. Split across two repositories, the rule degrades into "whichever repo the
agent has open."

**3. Two repositories, two pipelines, no shared gate.** Letflow's central
principle is that every producing step has a validating step
(`decisions/0004-humanless-pipeline.md`). A frontend change made in R-Co passes
R-Co's gates, not Letflow's. Keeping the SPA there meant the one part of the
system a user actually sees was the one part outside the redundancy model this
project exists to maintain.

**4. It cost nothing to verify.** The migrated tree passes on its own, in this
checkout, on Node 24.5.0 — type-check clean, ESLint clean at `--max-warnings 0`,
178 unit tests across 30 files, 47 guard tests including a full production
build. Ownership did not require a rewrite; it required a copy and four
one-line rebrands.

## What was migrated

R-Co's **git-tracked** `web/` files, minus tracked run-output that is not a
baseline: `tests/screenshots/` (92 files, 16 MB of `page.screenshot()` evidence —
nothing asserts against them, there is no `toHaveScreenshot()` in the suite),
`tests/reports/`, `handoffs/`, `eo004-screenshots/`, captured console logs, and
build artifacts. All are now in `.gitignore`. 242 files landed. Full inventory
and rationale: [`../../../web/README.md`](../../../web/README.md).

Four changes were made on arrival and no others: package name `bpm-web` →
`letflow-web`, `index.html` title, the `AppShell` sidebar brand, and the
`vite.config.ts` dev-proxy default from `:8080` (Zig) to `:4000` (Plug/Bandit).
Everything else is byte-identical, deliberately: a faithful copy gives the later
reconciliation an honest baseline to diff against.

The specification moved with the code — `docs/frontend/` now holds the
consolidated frontend requirements, the design system, and 66 per-requirement
files (`ADM-UI`, `DLQ-UI`, `IN-UI`, `PD-UI`, `SH`, `TK-UI`, `WH-UI`).

## What this decision does *not* change

- **No framework change.** The SPA stays React 18 + TypeScript + Vite.
  `decisions/0001-web-framework.md`'s Plug/Bandit conclusion is about Letflow's
  *server*; it is not an argument for rewriting the client in LiveView, and this
  record does not open that question.
- **No rewrite is authorised by ownership.** Owning the code means the code is
  changeable, not that it should be changed. The known drift carried over from
  R-Co (documented in `web/README.md`) is recorded rather than fixed, and each
  item is a candidate S8 requirement to be sized and gated normally.
- **Auth wiring, CORS, and contract gaps remain S8 requirement work.** The
  migration did not make the app function end-to-end against Letflow, and could
  not have: the API surface it needs is S4, still in progress.

## Consequences

- `docs/migration/stage-8-frontend-cutover.md` is rewritten from
  "integration boundary" to "Letflow owns the GUI."
- `docs/guides/frontend_developer_guide.md` and `.claude/agents/frontend-dev.md`
  lose their "you do not own a frontend codebase" framing. FRONTEND-DEV's
  mandate widens from config/CORS to the SPA itself, and therefore now needs the
  same producer/validator pairing as backend work.
- The frontend acquires a real quality gate in this repository. `web/tests/guards/`
  is the structural equivalent of the backend's validator chain — it enforces
  architectural invariants by scanning source and the built bundle. Weakening a
  guard pattern to make a change pass is now a Letflow anti-pattern, not an
  R-Co one.
- `web/` needs a CI job — but so does everything else. There is no
  `.github/workflows/` directory in this repository at all. The backend's own CI
  is S0's `REQ-013`, which is `done` — but what REQ-013 delivered was a
  *local* single-command gate (`mix letflow.check`), never GitHub Actions,
  which is why `docs/agents/protocols/GIT_MERGE.md` still carries a
  precondition stating that no `.github/workflows/` CI is configured yet.
  CI-as-a-service is split in two: `REQ-136` (backend job) and `REQ-138`
  (frontend job); `REQ-139` corrects the stale `GIT_MERGE.md` precondition
  once `REQ-136` lands. A frontend gate equivalent to
  `mix letflow.check` —
  `type-check` + `lint` + `test` + `guards` — is filed as S8 requirement work
  rather than bolted on inline here.
