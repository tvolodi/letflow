# Stage 5 — Scripting & plugins

Status: decision made, requirements not yet expanded. Depends on: S3
(runs in parallel with S4 — both only need the instance engine, not
each other). Requirements: none expanded yet.

## Scope

Port `src/lua/` (29 files, including `host_api/` — the service-task
scripting host) and `src/wasm/` (19 files, including `host_api/` — the
plugin host API).

PROVENANCE (historical, not current decision authority):
Verified against the live R-Co tree 2026-08-23: the two directories are
9,761 lines of Zig, but the split is **8,365 Lua / 1,396 WASM**, and
that asymmetry is not a measure of relative complexity — it is a
measure of how much of each half actually exists. `src/lua/` binds a
real, statically linked LuaJIT 2.1. **`src/wasm/` is stubs
end-to-end** (`wasmtime_bindings.zig`: "Actual C FFI integration
deferred to Stage 10"; placeholder clocks; no working fuel metering).
S5 therefore covers both halves, but the WASM half is a port of R-Co's
**requirement specification** (WASM-01..14 in
`R-Co/docs/addon-1/02-functional-requirements.md`), not of its code.
That scoping is a user decision (2026-08-23) and is not reopened by
requirement expansion.

## Decisions

**Settled: [`decisions/0014-scripting-plugin-runtime-strategy.md`](decisions/0014-scripting-plugin-runtime-strategy.md)**
— the build-vs-bind record this stage required before requirements
could be expanded. Outcome: **bind on both halves, at two different
depths.** Lua adopts `tv-labs/lua` (pure-Elixir Lua 5.3 VM — no NIF, no
C, no Port), which eliminates the NIF crash-isolation hazard class
rather than mitigating it. WASM adopts `wasmex` (Wasmtime via Rust
NIF), but every guest invocation must cross a process boundary via the
supervised-task pattern `PluginInterface.invoke/2,3` already
implements. Neither runtime is reimplemented. **Lua lands first and
defines the host API; WASM follows and conforms to it per WASM-12** —
expansion must order the requirements that way.

Both S3 seams survive unchanged: `LuaScriptAudit.Executor`'s
`@callback execute_with_manifest/2` (whose `script_ref` was
deliberately left opaque pending exactly this decision) and
`PluginInterface`'s `@behaviour`. A WASM plugin is an ordinary Elixir
module implementing that existing behaviour which happens to call
`wasmex` inside `handle_node/1`, so `PluginInterface`'s
"in-process Elixir modules only" boundary stays literally true.

**Before expanding requirements, read that record in full** — in
particular its two lists. Twelve of R-Co's LUA-xx/WASM-xx requirements
are **not satisfiable as literally worded** under the chosen runtimes
and must be restated rather than claimed met (LUA-01, LUA-03, LUA-04,
LUA-08/LUA-10 as a pair, LUA-09, LUA-14, LUA-15, LUA-16, WASM-01,
WASM-03/04/05, WASM-07, WASM-13). REQ-VALIDATOR treats an unrestated
one as a validation failure. The record also carries seven open
questions; **OQ-1 blocks LUA-09, and OQ-3/OQ-4 block the WASM half's
expansion.**

## REVIEWER sign-off

**2026-08-23 — `decisions/0014-scripting-plugin-runtime-strategy.md`: PASS.**
Gated over two rounds. Round 1 returned PASS-WITH-NITS on a
substantive defect: LUA-14 was listed as satisfiable, but its sole
acceptance criterion is that `os.time` be `nil`, and `os.time` is not
in `Lua.new/1`'s documented default deny-set — a false "this one's
fine," which is the more dangerous error because the watchlist only
polices restated requirements. Fixing it surfaced two further findings
neither agent had anticipated: `os.setlocale` is a fifth reachable
`os` function, and `:sandboxed` **replaces** the default deny-set
rather than adding to it, so the obvious fix
(`sandboxed: [[:os, :time]]`) would have silently un-denied all 27
defaults including `os.execute` and `load` — a hardening change that
would have opened a sandbox escape. Round 2 verified both claims
directly against published documentation (6 denied + 5 reachable = the
11 functions in Lua 5.3's `os` library) and returned PASS. LUA-15 and
LUA-16 were also moved to the restatement list during the same pass.

One correction applied by ORCH after sign-off: the record justified its
evidence discipline by claiming this sandbox has no network access for
`mix deps.get`. That is false — `hex.pm` and `repo.hex.pm` were both
reached over HTTPS — and it was removed, because it would have led
future agents to skip verification they can actually perform (notably
OQ-2's spike). The narrower true statement stands: nothing was run.
