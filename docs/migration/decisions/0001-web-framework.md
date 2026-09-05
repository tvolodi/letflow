# 0001 — Web framework: Phoenix vs. Plug/Bandit

Status: decided (REQ-010). Owner: ELIXIR-DEV.

## Question

Letflow currently uses plain Plug + Bandit for 3 routes
(`lib/letflow/router.ex`). R-Co's `src/api/routes/` has 24 route modules:

PROVENANCE (historical, not current decision authority):
```
audit.zig  definitions.zig  definition_rollback.zig  dlq.zig
entities.zig  health.zig  identity.zig  instances.zig  metrics.zig
onboarding.zig  openapi.zig  pin_rebind.zig  platform_migrations.zig
promotion.zig  promotions.zig  promotion_assertion.zig
promotion_read.zig  promotion_review.zig  services.zig  simulation_test.zig
solution_packs.zig  tasks.zig  tenant_config.zig  webhooks.zig
```

plus `src/api/middleware/`:

PROVENANCE (historical, not current decision authority):
```
auth.zig  content_type.zig  quota_enforcement.zig  rate_limit.zig
tenant_status.zig  trace.zig  validate.zig
```

Does Letflow migrate to Phoenix (router pipelines, plugs, controllers) or
continue hand-rolling on Plug/Bandit at this scale?

## Decision

Letflow migrates to **Phoenix** (router `scope`/pipeline DSL, controllers) rather than
continuing to hand-roll on plain Plug/Bandit, effective at S4 (`docs/migration/stage-4-api-surface.md`
owns the actual execution — this record does not touch `lib/letflow/router.ex` or
`mix.exs`).

PROVENANCE (historical, not current decision authority):
Note on the route count this decision is reasoned against: R-Co's `src/api/routes/`
contains **24** route modules. That count was verified directly against disk twice
during design (`lib/letflow/design/0001-web-framework-decision.md` §2.1) and includes
`promotion_review.zig`. At the time this record was originally written, this file's own
Question section and `docs/requirements.yaml`'s REQ-010 entry both stated a stale **22**
(omitting `promotion_review.zig`, among other gaps), tracked as
`docs/issues/ISS-0001.yaml`; both have since been corrected in place (Question section
above, and REQ-010's `description`/`acceptance_criteria` in `docs/requirements.yaml`) to
match the 24 ground truth the reasoning below always used. The middleware count of 7
(used below) already matched this file's own Question section and
`docs/migration/stage-4-api-surface.md` from the start; only REQ-010's `description`
field was stale on that count (said 6, omitted `content_type`) — also corrected as part
of the same ISS-0001 fix.

## Reasoning

### Dimension A — route-count scaling (3 → 24)

Letflow's router today is 3 routes in one file with no sub-structure. R-Co's equivalent
surface is 24 route modules. `Plug.Router`'s macro-based route table (`get`/`post`/`match`
clauses accumulating in one module, or manually split via `Plug.Router.forward/2` into
per-resource sub-routers once one file stops being legible) has no forced structure at
that count — the split into sub-routers is a discipline the team would have to impose
and maintain by convention. Phoenix's `scope`/`resources` router DSL plus a
controller-per-resource convention forces that same split for free: each of the 24
R-Co resources (`audit`, `definitions`, `definition_rollback`, `dlq`, `entities`,
`health`, `identity`, `instances`, `metrics`, `onboarding`, `openapi`, `pin_rebind`,
`platform_migrations`, `promotion`, `promotion_assertion`, `promotion_read`,
`promotion_review`, `promotions`, `services`, `simulation_test`, `solution_packs`,
`tasks`, `tenant_config`, `webhooks`) maps naturally to its own controller module under
Phoenix's convention, while under `Plug.Router` nothing stops all 24 from accumulating
in a single `router.ex` short of someone manually reaching for `forward/2` — which is
exactly the kind of self-imposed discipline Phoenix's router DSL makes structural
instead of optional.

Route-count growth alone (3 → 24, an 8x increase) is real signal but is not, by itself,
decisive — a disciplined team could keep a 24-route `Plug.Router` legible via consistent
use of `forward/2`. It becomes decisive combined with Dimension B: the same growth that
strains route legibility is what also introduces the 7 middleware modules currently
absent from Letflow's router entirely, and Phoenix's pipeline mechanism addresses both
concerns with one convention rather than two separately-maintained ones.

### Dimension B — middleware-chain composition (all 7 modules named individually)

Letflow's router today wires in zero of R-Co's 7 middleware concerns — this is a
greenfield choice between "plug chain in `Plug.Router`" and "pipeline in
`Phoenix.Router`," not a migration of an existing chain. Both mechanisms are Plug-based
under the hood (Phoenix pipelines are themselves `Plug.Builder`-composed), so the
question is what Phoenix's `pipeline :api do plug ... end` block adds on top of plain
composition — namely router-level, per-scope pipeline grouping, declared once and
applied to every route in that scope, versus hand-rolling the same grouping via nested
`Plug.Builder` modules or repeated `plug` calls guarded by path/method conditionals in
`Plug.Router`. Each of the 7 modules maps 1:1 onto a single `plug` entry either way, and
each is addressed individually below per acceptance criterion 2:

PROVENANCE (historical, not current decision authority):
1. **`trace.zig`** → a single `plug Letflow.Plugs.Trace` entry, placed first in the
   pipeline (Phoenix) or first in the plug sequence (hand-rolled) — both mechanisms give
   the same "runs before everything else" guarantee, since both execute plugs in
   declaration order.
PROVENANCE (historical, not current decision authority):
2. **`auth.zig`** → a single `plug Letflow.Plugs.Auth` entry, immediately after trace in
   either mechanism. Bearer-token validation and role resolution short-circuiting with
   401/403 is a standard plug halt (`conn |> send_resp() |> halt()`) under both options —
   no framework-specific behavior needed here.
PROVENANCE (historical, not current decision authority):
3. **`content_type.zig`** → a single `plug Letflow.Plugs.ContentType` entry (or Phoenix's
   own `Plug.Parsers` configuration could absorb part of this, but the design treats it
   as its own discrete module to preserve the 1:1 mapping R-Co uses); applies to
   POST/PUT/PATCH only under both mechanisms via the same per-route/pipeline scoping.
PROVENANCE (historical, not current decision authority):
4. **`validate.zig`** → a single `plug Letflow.Plugs.Validate` entry, running after
   `content_type` and before business logic in both options; per-route JSON-schema
   validation is equally expressible as a plug under either mechanism.
PROVENANCE (historical, not current decision authority):
5. **`tenant_status.zig`** → a single `plug Letflow.Plugs.TenantStatus` entry; needs
   `auth`'s resolved tenant identity first under both mechanisms, so it is ordered after
   `auth` either way.
PROVENANCE (historical, not current decision authority):
6. **`quota_enforcement.zig`** → a single `plug Letflow.Plugs.QuotaEnforcement` entry;
   same ordering dependency on `auth` as `tenant_status`.
PROVENANCE (historical, not current decision authority):
7. **`rate_limit.zig`** → a single `plug Letflow.Plugs.RateLimit` entry; same ordering
   dependency on `auth`.

Ordering (`trace` first; `auth` before `tenant_status`/`quota_enforcement`/`rate_limit`,
which all need `auth`'s resolved tenant/principal) is a wash between the two options —
Phoenix pipelines execute in declared-list order per `pipe_through`, and a manual `plug`
sequence in `Plug.Builder`/`Plug.Router` gives the identical guarantee. Ordering
correctness is not what breaks the tie.

What does break the tie is that Phoenix's `pipeline :api do ... end` declares this
7-plug sequence exactly **once** and reuses it via `pipe_through :api` across every
`scope` — the grouping is a named, router-level artefact. Under hand-rolled
`Plug.Router`, the same reuse requires either (a) repeating all 7 `plug` calls in every
sub-router mounted via `forward/2`, or (b) building a bespoke shared `Plug.Builder`
module to hold the sequence and delegating to it — which is Letflow re-implementing, by
hand, the exact mechanism `pipeline`/`pipe_through` already gives Phoenix for free. At 3
routes and 0 wired-in middleware this cost was invisible; at 24 routes and 7 concerns
that need consistent, ordered application across nearly all of them, hand-building that
shared mechanism is duplicated effort with no corresponding benefit — Phoenix's version
is the same underlying `Plug` composition, just with the grouping convention already
built in.

### Dimension C — OIDC/library ecosystem fit

This dimension is **orthogonal** to the Phoenix-vs-Plug/Bandit decision and does not
factor into it either way. `docs/migration/decisions/0002-oidc-integration.md` (REQ-011,
owner ELIXIR-DEV) is still `pending` as of this writing; its two candidate libraries,
`ueberauth` and `assent`, are both Plug-based, not Phoenix-specific — each attaches to a
request pipeline as a `Plug`, and that attachment point exists identically under Phoenix
(as a pipeline entry) or hand-rolled Plug/Bandit (as a plug in the chain). Nothing about
0001's Decision above depends on, or is contradicted by, whatever 0002 eventually
decides. REQ-010's `depends_on: []` confirms this was never meant to block on REQ-011,
and this record does not wait on it. A future reader of 0002 should note the reverse
holds too: OIDC library choice does not need to reconsider this Decision, since the
integration point is a plug regardless of which router owns the pipeline.

### Summary

Dimension A (route-count scaling) is real but not independently decisive. Dimension B
(middleware-chain composition across all 7 named modules) is decisive: Phoenix's
`pipeline`/`pipe_through` mechanism gives Letflow, for free, the exact shared-sequence
grouping that 7 ordered, cross-cutting concerns applied across 24 routes would otherwise
require hand-building from `Plug.Builder` primitives. Dimension C (OIDC fit) does not
move the decision in either direction. Combined, Dimensions A and B justify migrating to
Phoenix at S4; the migration itself (adding `{:phoenix, "~>..."}` to `mix.exs`, rewriting
`lib/letflow/router.ex`) is out of scope for this decision record and is S4 execution
work, not S0 decision-recording.

## Addendum (2026-08-20) — Plug/Bandit stands; the Decision above is reversed

**Trigger — REQ-065.** `lib/letflow/router.ex`'s shipped moduledoc ("Deliberately
minimal — Plug + Bandit, no Phoenix", present since before REQ-046 and unchanged by it)
and `mix.exs` (no `:phoenix` dependency, confirmed by direct read) have directly
contradicted this record's Decision section above since S1. `docs/migration/
stage-4-api-surface.md`'s Decisions section flagged the contradiction during the
2026-08-19 requirement expansion and escalated it as REQ-065, whose sole deliverable is
this addendum: name the surviving position, engage Dimension B's tie-breaker on its
merits either way, and state whether the corrected route/middleware counts change the
conclusion. This addendum does that; the Decision and Reasoning sections above are left
as originally written, per this repo's own precedent for correcting a decision record in
place (`0003-ecto-schema-strategy.md`'s 2026-08-17 addendum, `0006-identity-tables-
schema-per-tenant.md`'s "exactly what this supersedes" section) rather than deleting or
rewriting them.

PROVENANCE (historical, not current decision authority):
**Corrected counts.** R-Co's `src/api/routes/` now holds **31** route modules (up from
the 24 this file's Decision section already corrected once, via `ISS-0001`), and
`src/api/middleware/` holds **9** (up from 7) — reverified directly against R-Co's live
tree during REQ-065's design step, independently of the prior 24/7 figures
(`lib/letflow/design/0001-web-framework-addendum-req065.md` §2). Of the two middleware
modules added since this file's Reasoning was written, `outbox_cap.zig` is not
mountable until S6's outbox subsystem exists regardless of framework choice, and
`agent_auth.zig` is out of scope entirely — deferred runtime-agent subsystem work, per
`docs/migration/README.md`'s "Two applications of the agent-pipeline principles"
section. **The middleware set actually within S4's practical mounting scope today is
still the same 7 modules Dimension B's Reasoning already named individually** (`trace`,
`auth`, `content_type`, `validate`, `tenant_status`, `quota_enforcement`, `rate_limit`);
only the routes count materially grew (24 → 31, +29%). **The recount does not change the
conclusion below** — if anything it strengthens the premise that S4's router carries
real structural weight, which is exactly why Dimension A's `forward/2` decomposition
answer (not a new framework) is the one this addendum adopts.

**Decision: Plug/Bandit stands as Letflow's S4 web framework — Phoenix is not
adopted, reversing this file's original Decision above.**

**Reasoning.**

*Dimension B's tie-breaker, engaged on its merits, not sidestepped.* The Reasoning
section above already names the Plug-side answer and rules it out: "(b) building a
bespoke shared `Plug.Builder` module to hold the sequence and delegating to it — which
is Letflow re-implementing, by hand, the exact mechanism `pipeline`/`pipe_through`
already gives Phoenix for free," then calls that "duplicated effort with no
corresponding benefit." That framing overstates the actual cost. A shared
`Plug.Builder` module holding the 7 in-scope-today plugs in order (e.g.
`Letflow.Plugs.ApiPipeline`, using `Plug.Builder`'s own `plug`-composition macros) is a
**one-time, ~20-30 line module**, not effort duplicated per route or per sub-router: it
is written once, and every sub-router mounted via `Plug.Router.forward/2` delegates to
it with a single `plug Letflow.Plugs.ApiPipeline` line — structurally the same
reuse shape `pipe_through :api` gives Phoenix, just spelled with `Plug.Builder`'s
primitives instead of `Phoenix.Router`'s DSL sugar around those same primitives (0001's
own Dimension B text already concedes "Both mechanisms are Plug-based under the hood").
The two already-shipped, already-framework-neutral plugs this composition would carry
(`Letflow.Plugs.AuthPipeline`, `Letflow.Plugs.TenantStatus`, REQ-021) mount into a
`Plug.Builder` chain identically to how they would mount into a Phoenix `pipeline`
block — no rework either way. What Phoenix buys over this is the DSL syntax for
declaring the grouping, not the capability to group; that syntactic convenience does not
justify importing and maintaining an entire additional framework dependency (Phoenix,
Phoenix.PubSub, and their own transitive tree) on top of a BPM engine core (`gen_statem`
process-per-instance, `DynamicSupervisor`) that has no other Phoenix-shaped need, when a
~20-30 line module inside `lib/letflow/plugs/` already closes the gap.

*Dimension A revisited — the `forward/2` decomposition already named for OQ-1 answers
the accumulation concern directly.* Dimension A's own text says route-count growth "is
real signal but is not, by itself, decisive... a disciplined team could keep a
24-route `Plug.Router` legible via consistent use of `forward/2`." `stage-4-api-surface
.md`'s OQ-1 independently reaches the same place from the routing side: "`Plug.Router`'s
`forward/2` to per-subsystem sub-routers is the idiomatic answer and needs no new
dependency... It becomes [a decision record] if the resolution pulls in a routing
library." At 31 routes, the discipline Dimension A worried would be "self-imposed" is
exactly what OQ-1 already plans to impose structurally via per-subsystem sub-routers,
matching Dimension A's own accepted fallback rather than requiring Phoenix's `scope`
DSL to force it.

*Switching cost is low either way, and that cuts toward not switching, not toward
switching.* REQ-065's design step confirms the sunk cost in the current Plug/Bandit
router is minimal — `router.ex` is ~30 lines with two routes, and both already-built S4
plugs are framework-neutral by construction
(`lib/letflow/design/0001-web-framework-addendum-req065.md` §3). That fact means neither
position wins by inertia. It is weighed here on the merits above: minimal added
dependency surface for a project whose own governing rule (`CLAUDE.md`'s "Keep it
light, but match effort to the active stage"; `.claude/agents/elixir-dev.md`'s
"Forbidden" section, "Don't add abstractions... the current requirement doesn't need
yet") already disfavors introducing a framework-scale abstraction to solve a
plug-composition problem a ~20-30 line module solves directly.

*Dimension C — unaffected.* Still orthogonal, as originally reasoned: `ueberauth`/OIDC
integration attaches as a plug under either framework, and nothing about this addendum
changes that.

**What this supersedes.** The Decision section's naming of Phoenix, and the Summary's
"Combined, Dimensions A and B justify migrating to Phoenix at S4" sentence, are
superseded by this addendum's Plug/Bandit conclusion. Dimension B's per-module mapping
(all 7 plugs, their ordering constraints) is **not** superseded — it remains the
accurate list of what must be mounted and in what order; this addendum revises only the
*tie-breaker conclusion* (which composition mechanism assembles them), not the
per-module analysis itself. Dimension C is untouched, as always.

**Scope.** This addendum does not add a `mix.exs` dependency, does not change
`lib/letflow/router.ex`'s behavior (its "no Phoenix" moduledoc line was already
consistent with the position named here and needed no correction), and does not resolve
OQ-1 (router decomposition, owned by REQ-070) or OQ-2 (OpenAPI spec strategy, owned by
REQ-084) — both proceed against this addendum's Plug/Bandit conclusion as their now-
settled premise rather than an open question.
