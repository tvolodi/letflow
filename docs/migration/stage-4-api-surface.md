# Stage 4 — API surface

Status: not started. Depends on: S3. Requirements: none expanded yet.

## Scope

Port `src/api/routes/` (22 modules — see
`docs/migration/decisions/0001-web-framework.md` for the full list)
and `src/api/middleware/` (7 modules: `auth.zig`, `content_type.zig`,
`quota_enforcement.zig`, `rate_limit.zig`, `tenant_status.zig`,
`trace.zig`, `validate.zig`) as Phoenix controllers/plugs or
Plug/Bandit handlers, per whichever 0001 settled on.

Letflow's existing `lib/letflow/router.ex` (3 routes) is the precedent
to generalize from, same relationship S3 has to `process_instance.ex`.

## Decisions

Executes on `docs/migration/decisions/0001-web-framework.md` from S0.
No new decision file expected unless a specific route/middleware pair
surfaces a choice 0001 didn't anticipate.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
