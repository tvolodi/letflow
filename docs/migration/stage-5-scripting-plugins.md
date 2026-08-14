# Stage 5 — Scripting & plugins

Status: not started. Depends on: S3 (runs in parallel with S4 — both
only need the instance engine, not each other). Requirements: none
expanded yet.

## Scope

Port `src/lua/` (29 files, including `host_api/` — the service-task
scripting host) and `src/wasm/` (19 files, including `host_api/` — the
plugin host API).

## Decisions

Needs its own decision record before requirements are expanded:
build-vs-bind — Elixir NIFs/Ports/Rustler wrapping existing Lua/WASM
runtimes, vs. reimplementing scripting support natively. This is a
materially different kind of decision than S0's (library ecosystem
maturity and NIF safety/crash-isolation tradeoffs matter more here
than for, say, OIDC), so treat it as a new `decisions/000x-*.md` file
scoped to this stage rather than assuming S0's decisions cover it.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
