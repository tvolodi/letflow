# 0001 — Web framework: Phoenix vs. Plug/Bandit

Status: decided (REQ-010). Owner: ELIXIR-DEV.

## Question

Letflow currently uses plain Plug + Bandit for 3 routes
(`lib/letflow/router.ex`). R-Co's `src/api/routes/` has 24 route modules:

```
audit.zig  definitions.zig  definition_rollback.zig  dlq.zig
entities.zig  health.zig  identity.zig  instances.zig  metrics.zig
onboarding.zig  openapi.zig  pin_rebind.zig  platform_migrations.zig
promotion.zig  promotions.zig  promotion_assertion.zig
promotion_read.zig  promotion_review.zig  services.zig  simulation_test.zig
solution_packs.zig  tasks.zig  tenant_config.zig  webhooks.zig
```

plus `src/api/middleware/`:

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

1. **`trace.zig`** → a single `plug Letflow.Plugs.Trace` entry, placed first in the
   pipeline (Phoenix) or first in the plug sequence (hand-rolled) — both mechanisms give
   the same "runs before everything else" guarantee, since both execute plugs in
   declaration order.
2. **`auth.zig`** → a single `plug Letflow.Plugs.Auth` entry, immediately after trace in
   either mechanism. Bearer-token validation and role resolution short-circuiting with
   401/403 is a standard plug halt (`conn |> send_resp() |> halt()`) under both options —
   no framework-specific behavior needed here.
3. **`content_type.zig`** → a single `plug Letflow.Plugs.ContentType` entry (or Phoenix's
   own `Plug.Parsers` configuration could absorb part of this, but the design treats it
   as its own discrete module to preserve the 1:1 mapping R-Co uses); applies to
   POST/PUT/PATCH only under both mechanisms via the same per-route/pipeline scoping.
4. **`validate.zig`** → a single `plug Letflow.Plugs.Validate` entry, running after
   `content_type` and before business logic in both options; per-route JSON-schema
   validation is equally expressible as a plug under either mechanism.
5. **`tenant_status.zig`** → a single `plug Letflow.Plugs.TenantStatus` entry; needs
   `auth`'s resolved tenant identity first under both mechanisms, so it is ordered after
   `auth` either way.
6. **`quota_enforcement.zig`** → a single `plug Letflow.Plugs.QuotaEnforcement` entry;
   same ordering dependency on `auth` as `tenant_status`.
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
