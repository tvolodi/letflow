# 0001 — Web framework: Phoenix vs. Plug/Bandit

Status: pending (REQ-010). Owner: ELIXIR-DEV.

## Question

Letflow currently uses plain Plug + Bandit for 3 routes
(`lib/letflow/router.ex`). R-Co's `src/api/routes/` has 22 route modules:

```
audit.zig  definitions.zig  definition_rollback.zig  dlq.zig
entities.zig  health.zig  identity.zig  instances.zig  metrics.zig
onboarding.zig  openapi.zig  pin_rebind.zig  platform_migrations.zig
promotion.zig  promotions.zig  promotion_assertion.zig
promotion_read.zig  services.zig  simulation_test.zig
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

_Not yet recorded — REQ-010 fills this in._

## Reasoning

_Must explicitly address: route count (22, cited above, not rounded);
how each of the 7 middleware modules maps onto the chosen framework's
composition mechanism (Phoenix plug pipeline vs. hand-rolled
`Plug.Builder` chain); OIDC library ecosystem fit (cross-reference
0002 once that lands)._
