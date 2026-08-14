# Stage 8 — Frontend integration & cutover

Status: not started. Depends on: S7. Requirements: none expanded yet.

## Scope

Point R-Co's `web/` (React/TypeScript) — or a compatible surface — at
the Elixir backend instead of the Zig one. Close any API-contract gaps
found in practice (this is where undocumented behavior the earlier
stages' route-by-route port missed will actually surface). Decide on
cutover timing and whether/when to deprecate the Zig backend.

`web/` itself is out of scope to rewrite — this stage is about the
integration boundary, not porting the frontend.

## Decisions

Needs a cutover-strategy decision (big-bang vs. gradual/dual-running)
once S7 has produced a real correctness signal to decide from — too
early to record anything now.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
