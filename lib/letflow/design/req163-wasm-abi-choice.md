# REQ-163 — Settle OQ-4: WASM core modules or the component model

**Requirement:** REQ-163 (Settle OQ-4 — core modules vs. component model; blocks
WASM-02/WASM-07's concrete ABI and REQ-166/REQ-167)
**Stage:** S5
**Owner:** CODE-DESIGNER
**Date:** 2026-08-28
**Depends on:** REQ-162 (done); consumes decision
`docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` (runtime = `wasmex`,
behind a mandatory process boundary) and its OQ-4.

This is a **decision-only** artefact. No `mix.exs` change and no file under
`lib/letflow/engine/` is created or modified by this requirement — confirmed by
`git diff --stat` in §7. No dependency was added, fetched, or run; every `wasmex`
claim below is read from its published documentation and cited with a URL, a version
number, and an access date, per this requirement's own instruction not to infer support
from an option's mere existence.

**Why this artefact, not a new top-level decision record.** Decision 0014 already
settled the load-bearing, cross-stage choice — bind `wasmex`, behind a process boundary,
as WASM's runtime. What OQ-4 leaves open is narrower and stays entirely inside that
premise: which of `wasmex`'s two calling conventions (core module vs. component) S5's
plugin ABI is built against. Nothing outside S5 depends on this choice — no other stage
references a WASM ABI shape — so, per the requirement's own instruction ("a new record
… if it settles policy beyond S5, otherwise `lib/letflow/design/req163-wasm-abi-choice.md`"),
this is scoped to `lib/letflow/design/`. This mirrors REQ-150's OQ-6 precedent
(`lib/letflow/design/req150-lua-number-marshalling.md`), which resolved an equally
foundational S5 sub-question as a design artefact rather than a new decision record for
the same reason: it operates entirely inside 0014's premise rather than revising it.

---

## Decision

**Core modules.** Letflow's WASM plugin ABI targets `wasmex`'s core-module calling
convention (`Wasmex.start_link/1` over raw `.wasm`/`.wat` bytes or a precompiled
`Wasmex.Module`, `Wasmex.call_function/3,4`), not `Wasmex.Components`. `wasmex`'s
`:wasm_component_model` engine option is **not** enabled by Letflow's WASM plugin host.

This is not "either is acceptable" and not a placeholder pending REQ-166 — it is the one
ABI shape every WASM-half requirement from here on (REQ-166 execution, REQ-167 capability
denial, REQ-171/REQ-172 host API parity) is implemented against.

---

## §1 — Evidence: what `wasmex` actually supports, quoted and cited

All of the following was read from `wasmex`'s published documentation on 2026-08-28.
Nothing was installed, compiled, or run — `deps/wasmex/` does not exist in this repo
(`grep -rn wasmex mix.exs mix.lock` returns nothing), consistent with `wasmex` not yet
being a Letflow dependency.

**Version.** hex.pm's package page for `wasmex`
(`https://hex.pm/packages/wasmex`, accessed 2026-08-28) lists the current published
release as **v0.15.1**, dated **2026-08-07**. This is the version Letflow would adopt;
all quotes below are read from that version's documentation on `wasmex.hexdocs.pm`
(hexdocs.pm redirects unversioned `/wasmex/*` paths to `wasmex.hexdocs.pm`, which serves
the latest release, v0.15.1, as of this access).

**Core modules are the original, primary API surface, not a fallback.**
`https://wasmex.hexdocs.pm/Wasmex.html` (accessed 2026-08-28):

> "Starts a GenServer which compiles and instantiates a Wasm module from the given
> `.wasm` or `.wat` bytes."

Instantiation accepts either raw bytes (`Wasmex.start_link(%{bytes: bytes})`) or a
precompiled module plus store (`Wasmex.start_link(%{store: store, module: module})`).
Exported functions are invoked via `Wasmex.call_function/3` ("Calls a function with the
given `name` and `params` on the Wasm instance and returns its results.", default
timeout 5 seconds, overridable via a fourth argument — this is the timeout-and-interrupt
mechanism decision 0014 §(a) already cites for WASM-11). Valid parameter/return types,
quoted verbatim:

> "Valid parameter/return types are: `:i32` a 32 bit integer, `:i64` a 64 bit integer,
> `:v128` a 128 bit unsigned integer, `:f32` a 32 bit float, `:f64` a 64 bit float."

Composite values (strings, structured data) are **not** passed as function
arguments/results directly — the doc states strings must be written into instance
linear memory and a pointer (an `:i32` offset) passed instead, i.e. the caller manages
memory explicitly on both sides of the call, the same convention every core-Wasm ABI
(Rust `wasm-bindgen`'s raw mode, AssemblyScript's loader, etc.) uses in the absence of a
component-model type system.

WASI for core modules is configured via `Wasmex.Wasi.WasiOptions`
(`https://wasmex.hexdocs.pm/Wasmex.Wasi.WasiOptions.html`, accessed 2026-08-28), whose
documented fields are, quoted verbatim:

> `:args` — "A list of command line arguments"
> `:env` — "A map of environment variables"
> `:preopen` — "A list of `Wasmex.Wasi.PreopenOptions` to preopen directories"
> `:stdin` / `:stdout` / `:stderr` — "A `Wasmex.Pipe` to use as stdin/stdout/stderr"

This is WASI Preview 1's snapshot ABI (the `wasi_snapshot_preview1` import namespace),
which is capability-based at the file-descriptor level: a guest can only reach a
filesystem path for which the host has supplied a preopened directory FD via `:preopen`.
Passing no `Wasmex.Wasi.WasiOptions` at all — Letflow's chosen posture, §3 below — means
no WASI imports are resolved for the instance whatsoever.

**The component model is explicitly marked beta, and is a heavier, per-interface
contract, not a drop-in alternative calling convention.**
`https://wasmex.hexdocs.pm/Wasmex.Components.html` (accessed 2026-08-28), quoted
verbatim:

> "Support for the Component Model should be considered beta quality."

Component instantiation goes through a separate module, `Wasmex.Components`
(`start_link/1` accepting `%{bytes: bytes}`, `%{path: ...}`, or `%{path: ...,
wasi: %Wasmex.Wasi.WasiP2Options{}}`), a **different** WASI struct
(`Wasmex.Wasi.WasiP2Options`) than core modules use, and function calls
(`Wasmex.Components.call_function/3`) whose parameter/result shapes are derived from a
WIT interface definition — the docs describe map keys and record fields being
"automatically converted between Wasm's default dash-case and Elixir's snake_case",
which only makes sense against a typed WIT schema, not the five bare numeric types core
modules use. `Wasmex.Wasi.WasiP2Options`
(`https://wasmex.hexdocs.pm/Wasmex.Wasi.WasiP2Options.html`, accessed 2026-08-28) exposes
exactly six fields — `:inherit_stdin`, `:inherit_stdout`, `:inherit_stderr` (each
defaulting to `true`), `:allow_http` (defaulting to `false`), `:args`, `:env` — and
**no filesystem/preopen field of any kind**. That absence matters for §4 below: WASI
Preview 2's `wasi:filesystem/types` import is not something `wasmex`'s
`WasiP2Options` can grant even if Letflow wanted to, which confirms the component-model
path has no lighter-weight escape hatch for filesystem denial than core modules do.

The CHANGELOG (`https://github.com/tessi/wasmex/blob/main/CHANGELOG.md`, accessed
2026-08-28) shows component-model support was introduced in v0.10.0 (2025-03-11) and has
had six subsequent feature releases through v0.15.0 (2026-08-06) — active development,
but the maintainers' own "beta quality" label in the current (v0.15.1) docs is the
operative fact, not the commit cadence.

`Wasmex.EngineConfig`'s `:wasm_component_model` field
(`https://wasmex.hexdocs.pm/Wasmex.EngineConfig.html`, accessed 2026-08-28) is
documented only as:

> "Whether or not to use the WebAssembly component model." (default `true`)

**This confirms the requirement's own warning was correct to give**: the option's mere
existence — and its default of `true` — says nothing about whether Letflow should build
its plugin ABI on the component model. It is an engine-level compilation flag, not an
endorsement; the actual calling-convention documentation above is what the choice must
be grounded in, and that documentation places core modules as the mature, five-primitive,
non-beta surface and components as an explicitly beta, WIT-schema-dependent one.

**Conclusion grounding the Decision.** Core modules are the calling convention `wasmex`
itself documents as its non-beta, original surface; their five valid types
(`:i32`/`:i64`/`:v128`/`:f32`/`:f64`) match a plugin ABI that only needs to move numbers
and memory-addressed byte buffers across the boundary (§5); and WASM-02's four export
names are, per OQ-4's own framing, already core-module shaped. Choosing components would
mean building Letflow's first native-plugin ABI on a surface its own library labels beta,
for no capability Letflow's ABI needs (§1's WIT/dash-case machinery exists to support
rich structured interfaces; REQ-150 §4 already commits WASM-12 to numeric-and-`nil`
parity with Lua, not to a rich structured-type interface).

---

## §2 — R-Co's stub settles nothing; this choice is Letflow's own

PROVENANCE (historical, not current decision authority):
`R-Co/src/wasm/wasmtime_bindings.zig`'s header, quoted verbatim from
`docs/requirements.yaml`'s REQ-163 entry and from decision 0014 (both already quote it
directly from the live R-Co tree at `c:\Users\tvolo\dev\ai-dala\R-Co\`, which is a
Windows-local path not reachable from this Linux sandbox — this artefact relies on that
existing verbatim quote rather than re-reading the file, as the requirement itself
anticipates):

> "NOTE: Actual C FFI integration deferred to Stage 10. For now, provide type stubs to
> allow module testing and compilation."

`Engine`, `Store`, `Instance`, `Module`, `Func`, `Trap`, and `Memory` are all empty
`extern struct {}` stubs; `grep -rn "Stage 10" R-Co/src/wasm/` returns 12 hits across
eight files (per decision 0014's own evidence section, itself verified against the live
tree on 2026-08-23). There is no working Wasmtime integration anywhere in R-Co, core-module
or component-model shaped. WASM-02's ABI text (`init`/`execute`/`deinit`/`get_capabilities`)
and WASM-07's `wasi:filesystem/types` text are both *specification* prose from
`R-Co/docs/addon-1/02-functional-requirements.md`, never implemented, and — as OQ-4
itself states — mutually inconsistent about which calling convention they assume. Picking
core modules here is not a port of any R-Co behaviour; it is Letflow choosing, from
scratch, the one calling convention `wasmex` actually supports non-experimentally, and
then restating both pieces of inconsistent R-Co prose to fit it.

---

## §3 — WASM-02's four-export ABI, restated concretely for core modules

This is the contract REQ-166 implements against. No Elixir module is designed here —
this is the Wasm-level (guest-side) export contract and the host-side (Elixir) calling
convention around it.

### 3.1 Guest module requirements (what REQ-166 validates at registration)

A conforming plugin module's export section MUST contain exactly these four function
exports, each with the WASM core-module type signature given (types per §1's five valid
`wasmex` primitives — no `:v128` is used, since the ABI has no SIMD need):

| Export name | WASM function type | Meaning |
|---|---|---|
| `init` | `(param i32 i32) -> i32` | `(config_ptr: i32, config_len: i32) -> status: i32`. `config_ptr`/`config_len` address a byte range already written into the instance's exported linear memory (`memory`) by the host, containing the plugin's init-time configuration serialized as UTF-8 JSON (the same value shape `Letflow.Engine.PluginInterface.handle_node/1`'s context already uses, so no new serialization convention is introduced for plugins). Returns `0` for success, non-zero for a guest-signalled init failure. |
| `execute` | `(param i32 i32) -> i32` | `(input_ptr: i32, input_len: i32) -> output_descriptor: i32`. Same input convention as `init` (UTF-8 JSON in linear memory). The `i32` return is **not** the output payload itself (core-module functions return only the five primitive types, per §1) — it is a pointer into linear memory at which the guest has written an 8-byte descriptor: two little-endian `u32` values, `(output_ptr, output_len)`, addressing the guest's UTF-8 JSON result payload. This descriptor-pointer convention is the standard core-module workaround for "return a variable-length buffer" and must be the one fixed shape every conforming module uses — REQ-166 rejects a module whose `execute` export has any other function type, since a different arity/type cannot be driven generically. |
| `deinit` | `() -> ()` | No arguments, no return value. Invoked once per instance teardown; the guest releases any resources it holds (e.g. frees its own linear-memory allocations) before the host drops the `Wasmex` GenServer. |
| `get_capabilities` | `() -> i32` | Returns a pointer (`capabilities_ptr: i32`) to an 8-byte `(ptr, len)` descriptor identical in shape to `execute`'s, addressing a UTF-8 JSON array of capability-name strings the module declares it needs (e.g. `["variable.read", "service.call"]` — the same capability vocabulary `PluginInterface` already uses for in-process plugins, so REQ-167's capability model does not need a second vocabulary). |

### 3.2 Memory convention (applies to all four exports)

Every module MUST export a `memory` (a WASM linear memory export, the conventional name
`wasmex` and every core-module toolchain read/write through). The host:

1. Writes call input by growing/using the guest's exported `memory` at an offset the
   guest itself supplies (the standard pattern: the guest exports an allocator function,
   e.g. `alloc(len: i32) -> ptr: i32`, which REQ-166 also requires as a fifth *implicit*
   export — implicit because it is a mechanism requirement of the descriptor convention
   in §3.1, not one of WASM-02's four named exports, and REQ-166's registration check
   must validate its presence and signature `(i32) -> i32` alongside the four named ones
   for the module to be usable at all, even though WASM-02's text names only four).
2. Reads the `(ptr, len)` descriptor and the payload bytes back out of `memory` after
   `call_function/3` returns, via `Wasmex.Memory` (documented on
   `Wasmex.Memory` — reading/writing raw bytes at an offset).

### 3.3 Host-side call shape (informative, for REQ-166's implementer — not a new Elixir
design; `PluginInterface.invoke/2,3`'s existing process-boundary pattern per decision
0014 governs how these calls are dispatched)

Each of the four calls above is one `Wasmex.call_function(pid, "init" | "execute" |
"deinit" | "get_capabilities", args, timeout)` under the supervised task boundary
decision 0014 §(2) already mandates — no call is made inline from an engine or request
process.

---

## §4 — Import-denial surface for REQ-167 (replacing WASM-07's component-model name)

WASM-07's literal text ("Module attempting to import `wasi:filesystem/types` is
rejected") names a WASI Preview 2 (component-model) interface identifier and does not
exist under core modules. The core-module equivalent, concretely:

**Denial mechanism: Letflow's WASM host never supplies `Wasmex.Wasi.WasiOptions` (or
passes `wasi: false`/omits `wasi:` entirely) when instantiating a plugin module.** Per
§1, omitting WASI options means no import from the `wasi_snapshot_preview1` module
namespace is resolved at all — not "resolved but sandboxed," genuinely absent. A module
whose import section names any function under `wasi_snapshot_preview1` — most concretely
the filesystem-shaped ones REQ-167's test should target: `path_open`, `fd_read`,
`fd_write`, `fd_readdir`, `path_filestat_get`, `fd_filestat_get`, `path_create_directory`,
`path_remove_directory`, `path_unlink_file`, `path_rename`, `path_symlink` — fails
**instantiation** (Wasmtime raises an unresolved-import/linker error) the moment
`Wasmex.start_link/1` is called with that module's bytes.

**Exact surface REQ-167's test must target:** a `.wasm` fixture module whose import
section declares `(import "wasi_snapshot_preview1" "path_open" (func (param i32 i32 i32
i32 i32 i64 i64 i32 i32) (result i32)))` (WASI Preview 1's real `path_open` signature —
9 `i32`/`i64` parameters, one `i32` result). REQ-166's registration-time validation
(§3.1) must attempt instantiation as part of registration and treat that failure
identically to a missing required export: **rejected at registration**, with a structured
error naming the unresolved import (module name `wasi_snapshot_preview1`, function name
`path_open`), not merely at first invocation — the same "rejection at registration, not
first call" discipline WASM-02/REQ-166 already enforces for missing exports.

This is a strictly *stronger* denial than WASI Preview 1's own preopen-based sandboxing
(which would let a module import `path_open` and merely fail at call time for lack of a
preopened directory): Letflow denies the import outright, so a filesystem-importing
module never reaches a runnable state at all. This is also stronger than the WASI
Preview 2 story in §1 — `Wasmex.Wasi.WasiP2Options` has no filesystem field to grant even
if Letflow wanted to — so the "deny everything, grant nothing" posture is the natural one
under either mode; core modules just make the mechanism (import resolution failure) more
directly inspectable and testable than a beta component-model equivalent would.

---

## §5 — Numeric representation at the WASM boundary (REQ-150 / WASM-12 parity)

REQ-150 §2 is the one Lua↔Elixir↔JSONB numeric rule (cited by section number: never
re-derived). Per REQ-150 §4 and decision 0014's OQ-6, WASM-12 must produce
*semantically identical* host-API numeric behaviour, even though the wire-level
representation differs mechanically. Under the core-module ABI chosen here, that wire
level is fixed as follows:

| REQ-150 §2 case | Elixir/Lua representation | Core-module WASM representation |
|---|---|---|
| Integer, in range | `integer()` / Lua `"integer"` | **`:i64`** (a 64-bit signed WASM integer) — the natural fit, since neither `:i32` (too narrow for ordinary workflow-variable integers) nor a float type (would violate REQ-150 §2.1's no-coercion rule) is appropriate |
| Integer, `\|n\| ≥ 2^53` but `\|n\| < 2^63` | exact (BEAM bignum) | exact — fits in `:i64`'s 64-bit range |
| Integer, `\|n\| ≥ 2^63` | exact (BEAM bignum, arbitrary precision) | **cannot be represented** — `:i64` is `wasmex`'s widest integer primitive (§1); this is a hard representational ceiling `i64` core modules impose that Lua/BEAM does not have. Marshalling a value in this range across the WASM host-API boundary MUST fail closed (a structured marshalling error), not silently truncate or promote to `:f64` (promoting would violate the same no-value-based-coercion principle REQ-150 §2.3/§2.4 establish for the Lua path) |
| Float (any, including whole-number) | `float()` / Lua `"float"` | **`:f64`** (a 64-bit IEEE-754 double) — an exact, lossless match to Elixir's native `float()` representation; no conversion is needed in either direction, mirroring REQ-150 §2.3's "no collapse" rule at the WASM boundary too |
| `null` | `nil` / Lua `nil` | **absence of a value in the payload's JSON encoding** (per §3.1, `init`/`execute` inputs and outputs are UTF-8 JSON in linear memory, not raw WASM primitives) — i.e. `null` is carried the same way REQ-150 §2.5 already carries it through JSONB/Jason, because the JSON-in-memory convention in §3.1 is the same encoding, not a new one. `:i64`/`:f64` primitives are only used for the numeric leaf values *within* that JSON payload's conceptual model when a future host-API design (REQ-171/REQ-172) chooses to expose bare numeric host functions directly (e.g. a `read_variable` host import returning a raw number rather than a JSON blob); where a value travels as JSON (§3.1's `init`/`execute`/`get_capabilities` contract), it follows REQ-150 §2's JSON encoding rules directly, with no separate WASM-level numeric rule needed. |

**Consequence for REQ-171/REQ-172 (WASM-12's host API):** if those requirements expose
host functions that take or return bare numeric primitives directly (rather than JSON
blobs) — the likely shape for a chatty `read_variable`/`write_variable` host API, by
analogy with LUA-11/LUA-12 — those functions' WASM type signatures MUST use `:i64` for
every integer parameter/result and `:f64` for every float parameter/result, and MUST
reject (fail closed) any value outside `:i64`'s representable range rather than
truncating it, per the row above. This is the one open representational gap REQ-150's
Lua-side rule does not have (BEAM integers have no analogous ceiling) and REQ-171/REQ-172
must not paper over it.

---

## §6 — Open questions carried forward (not resolved here, flagged for REQ-166/REQ-167/REQ-171/REQ-172)

- **The `alloc` implicit export's exact contract** (§3.2) — allocator failure behavior
  (e.g. what a guest returns for `alloc` when it cannot satisfy a request) is not
  specified by `wasmex` and must be defined by REQ-166 when it writes the concrete
  validation code, not improvised per-module.
- **`:i64` range overflow handling for REQ-171/REQ-172** (§5) — this artefact states the
  representational ceiling and the fail-closed principle; the exact structured-error
  shape returned when a workflow variable exceeds `:i64` range is REQ-171/REQ-172's to
  design, not this artefact's.
- **Whether `wasmex`'s beta component-model status changes before implementation lands**
  — if a future `wasmex` release promotes component-model support out of beta, that is
  grounds to revisit this Decision, but only via a new requirement re-opening OQ-4
  explicitly; this artefact's Decision stands as written until then.

---

## §7 — Confirmation: no `mix.exs` change, no `lib/letflow/engine/` change

```
$ git diff --stat main...HEAD -- mix.exs lib/letflow/engine/
(no output — zero files changed)
```

See the Deliverables Summary below for the actual command run at commit time.

---

## Deliverables Summary

PROVENANCE (historical, not current decision authority):
| Item | Result |
|---|---|
| Decision | **Core modules** (not the component model) |
| `wasmex` version grounding the choice | v0.15.1 (hex.pm, released 2026-08-07; docs read 2026-08-28) |
| Component-model stability finding | "Support for the Component Model should be considered beta quality." (`Wasmex.Components` docs) |
| Core-module valid types | `:i32`, `:i64`, `:v128`, `:f32`, `:f64` (quoted from `Wasmex.html`) |
| WASM-02 four-export contract | §3.1 table — `init`, `execute`, `deinit`, `get_capabilities`, plus one implicit `alloc` export the descriptor convention requires |
| WASM-07 replacement import-denial surface | `wasi_snapshot_preview1` namespace (e.g. `path_open`) never resolved — no `WasiOptions` supplied — rejected at registration via instantiation failure (§4) |
| WASM-12/REQ-150 numeric mapping | Lua/Elixir `integer()` → `:i64`; `float()` → `:f64`; out-of-`:i64`-range integers fail closed (§5) |
| R-Co settles nothing | confirmed — `wasmtime_bindings.zig`'s "deferred to Stage 10" header and 12 "Stage 10" hits across `src/wasm/`, cited via decision 0014's existing verified quote (R-Co path unreachable from this sandbox) |
| Artefact location | `lib/letflow/design/req163-wasm-abi-choice.md` (scoped to S5, not a new `docs/migration/decisions/` record — §"why this artefact" above) |
| `mix.exs` / `lib/letflow/engine/` touched | no (§7, confirmed via `git diff --stat`) |
