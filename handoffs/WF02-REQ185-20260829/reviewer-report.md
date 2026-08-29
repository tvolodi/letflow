# REVIEWER report — WF02-REQ185-20260829 Step 2d

**Verdict: PASS**

## Scope of this gate

REQ-185 is decision-and-design-only (no migration, no `lib/letflow/engine/`
file, no `mix.exs` change). `git diff --stat main...HEAD` confirmed: only
`lib/letflow/design/req185-scheduler-firing-architecture.md` plus this run's
own handoff/security-report bookkeeping files are touched. No code diff to
review for gen_statem/supervision idiom in the usual sense — this gate
checks the design artefact itself.

## Idiom/scope/decision-record review

- **Genuine decisions, not left open.** All 7 decisions in the summary table
  (§9) are reached explicitly, each with stated reasoning and rejected
  alternatives. The three items intentionally left open (§11 OQ-1/OQ-2/OQ-3)
  are legitimately out of this artefact's scope (OQ-1 is REQ-186's own field
  mapping per the acceptance criterion's own wording; OQ-2 is a future-scale
  mitigation not needed at the stated 500-tenant scale; OQ-3 is an R-Co
  citation re-verification caveat, already flagged honestly in §0) — none of
  the three is a load-bearing question this artefact was asked to close.
- **All of REQ-185's acceptance criteria are addressed**, checked one by one
  against `docs/requirements.yaml`'s REQ-185 entry: (1) one recommended
  mechanism named, alternatives evaluated (§2, 2a/2b/2c) — satisfied; (2)
  explicit Oban YES/NO with REVIEWER sign-off recorded in the artefact itself
  (§3) — now satisfied by this gate's edit; (3) claim mechanism named as `FOR
  UPDATE SKIP LOCKED`, ISS-301 cited, the deliberately-removed per-timer
  advisory lock stated in those words (§4) — satisfied; (4) ISS-302
  equivalent decided NO with a stated reason (§5) — satisfied; (5)
  poller-vs-tenancy relationship stated and quantified at a stated tenant
  count (§6, 500 tenants / ~100 qps) — satisfied; (6) locked/nothing-due/hard
  -error distinguished in one section, ISS-0618 cited, "propagate everything"
  explicitly refuted (§7) — satisfied; (7) exhausted-retry timer → DLQ
  decided YES with `entry_type: "timer"` (§8) — satisfied; (8) no
  migration/engine/mix.exs change (confirmed via `git diff --stat`) —
  satisfied.
- **No fenced code blocks reproduce real `.ex` content.** Read the file in
  full; it contains no literal Elixir code blocks (only prose, decision
  statements, and one inline SQL-shaped query description in prose, not a
  code fence).
- **`git diff --stat main...HEAD`**: 6 files changed, all under
  `handoffs/WF02-REQ185-20260829/` and
  `lib/letflow/design/req185-scheduler-firing-architecture.md`. No
  migration, no `lib/letflow/engine/` file, no `mix.exs` change.
- **Consistency with `docs/migration/decisions/0003-ecto-schema-strategy.md`
  Decision B**: read Decision B in full. The design correctly treats
  Decision B as binding table *placement* (schema-per-tenant,
  `tenant_id` retained intra-schema) without reopening it — §6 explicitly
  rejects a global-queue poller design *because* it would conflict with
  Decision B, and correctly frames the poller's *iteration strategy* as the
  open question Decision B leaves for this artefact to answer (Decision B's
  own text is about table placement, not poller shape). §8's DLQ write path
  is correctly tenant-scoped via `Letflow.Dlq.enqueue/2`'s `opts[:prefix]`,
  matching Decision 0003's 2026-08-17 addendum on `tenant_id` being derived
  from the resolved schema rather than caller-supplied. No decision here
  contradicts or silently re-decides 0003 or any other decision record.
- **Supervision idiom (task acceptance criterion 2)**: confirmed directly
  against `lib/letflow/application.ex` that the project's existing idiom is
  one dedicated `Task.Supervisor` per concern (five today: SandboxPool,
  Engine plugin, Lua, Wasm module registry, Wasm capability gate, Wasm
  module version registry). §2b's recommended design — a supervised
  `GenServer` ticker plus a sixth, scheduler-owned `Task.Supervisor` for
  per-tick fire attempts — follows this idiom exactly rather than
  introducing a new supervision shape.
- **Scope creep**: none found. The artefact is unusually scope-disciplined
  for a decision document — it explicitly declines to build machinery ahead
  of need (§6 defers query-cost mitigation to a future requirement should it
  become necessary; §3 point 1 rejects Oban partly *because* it is more
  machinery than the current requirement's scope calls for). §10 states
  explicitly what REQ-186/187/188 inherit unmodified, keeping this
  artefact's own footprint to decisions, not implementation.
- **Type-safety gaps (non-blocking, informational only)**: none observed
  worth filing under `docs/issues/` at this design-only stage — there is no
  new struct/schema/transition logic in this artefact itself (that's
  REQ-186's job). Noted forward: REQ-186's design should be explicit about
  which failure-isolation mechanism (a `Task.Supervisor` process boundary, a
  `Repo.transaction/1` + rescue boundary, or both together) it actually
  uses for per-timer fire attempts — see the sign-off note in §3 of the
  design file — since this artefact's own §2b and §7 each describe one of
  the two without stating whether both apply.

## Part 2 — the Oban sign-off

Read §3's full reasoning (four grounds) critically, not as a formality.
**Verdict: AGREE with the NO-on-Oban decision.** Full reasoning recorded
directly in the design file itself (§3, replacing the PENDING placeholder),
per this task's explicit instruction that the sign-off must live in the
artefact, not only in this report. Summary: grounds 1 (scope mismatch), 3
(duplicate retry-counter bookkeeping against REQ-186's ported
`fire_error_count`/DLQ machinery) and 4 (project dependency-adoption
precedent, per decision 0003 and REQ-148) are each independently sufficient
on their own terms and I concur with each; ground 2 (tenant-scoping
impedance) is real but only partially dispositive on its own, since Oban
could in principle be used purely as a cluster-wide tick driver while the
actual per-tenant claim query stays custom — noted in the sign-off so a
future reader doesn't treat it as air-tight in isolation, but this does not
change the verdict since grounds 1/3/4 do not depend on it.

## Disposition

PASS. Design-file edit (§3 sign-off, §9 summary table) committed alongside
this report. Routing to TEST-DESIGNER per Step 3 handoff — no code exists
yet to test; TEST-DESIGNER's task here is to verify this artefact's own
empirical claims (the `entry_type` column claim, the qps arithmetic in §6)
are checkable, not to write ExUnit tests.
