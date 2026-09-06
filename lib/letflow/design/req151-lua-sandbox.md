# Design: REQ-151 — Lua 5.3 sandbox deny-set (LUA-03, LUA-04 restated)

**Requirement:** REQ-151
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-26
**Library version verified against:** `deps/lua` on this branch, `Lua` module,
`@default_sandbox` at `deps/lua/lib/lua.ex:30-58` (tv-labs/lua; matches the `~> 1.0`
requirement REQ-148 resolved to `1.0.2`)

---

## 0. Sources read for this design

- `docs/agents/workflows/WF-02_requirement_implementation.md` Step 1
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` (full)
- `docs/migration/stage-5-scripting-plugins.md` (LUA-03/LUA-04/LUA-14 sections, sign-off
  section documenting the `:sandboxed` trap catch)
- `docs/requirements.yaml` REQ-151 (via handoff `context.requirement_text` / this run's
  `task.acceptance_criteria`), REQ-148, REQ-149, REQ-152, REQ-058 (read for scope
  boundary only)
- `lib/letflow/engine/lua_script_audit.ex` (moduledoc, S5-deferral text)
- `lib/letflow/design/req148-lua-runtime-spike.md` (empirical spike precedent, style
  precedent)
- `lib/letflow/design/req058-lua-script-audit.md` (design-doc section-numbering
  precedent)
- **`deps/lua/lib/lua.ex`** (the library's actual source, read directly rather than
  documentation, per this requirement's own directive to enumerate against the ACTUAL
  stdlib) — `@default_sandbox`, `new/1`, `sandbox/2`, `sandbox_all/2`, `template/2`
- **`deps/lua/lib/lua/vm/stdlib.ex`** (`@libraries` list, `base_globals/0`,
  `install_package_table/1`)
- **`deps/lua/lib/lua/vm/stdlib/os.ex`**, **`.../debug.ex`**, **`.../string.ex`** (actual
  installed function names, read directly)
- `git log -p -- mix.exs` (commits `55f058c`/`3a62d09` add `{:lua, "~> 1.0"}`; commits
  `30db07b`/`984bbc9` revert it) and
  `test/letflow/engine/lua_script_audit_test.exs:419-427` (the guardrail that forced the
  revert) — see Open Question 1, this is load-bearing for whether this design is even
  buildable yet.

---

## 1. Scope boundary

**In scope:** one sandbox-construction function; the full deny-set enumerated against
Lua 5.3's actual installed stdlib (not documentation, not 5.1); the `coroutine` decision;
the moduledoc's LUA-03/LUA-04 restatement text; a test suite proving the deny-set holds
and proving the `:sandboxed`-replaces-defaults trap is guarded.

**Out of scope (explicitly, per requirement text):**
- `os.time`, `os.date`, `os.clock`, `os.difftime` denial/replacement — REQ-152 (LUA-14).
- Any resource limit (`:max_instructions`, `:max_call_depth`, `:max_string_bytes`,
  memory) — REQ-149, REQ-154..156.
- Any host API (`Lua.set!/3`, `deflua`, service/variable access) — REQ-157, REQ-159,
  REQ-160.
- Any `Executor` implementation resolving `LuaScriptAudit.Executor.script_ref` — REQ-153.
- WASM/plugin work — separate S5 sub-track per decision 0014.

**No file under `lib/letflow/engine/` (other than the new
`lib/letflow/engine/lua/sandbox.ex`) is modified.** `lua_script_audit.ex` is read-only
input for scope-boundary context; nothing in it changes.

---

## 2. Module and file layout

| File | Purpose |
|---|---|
| `lib/letflow/engine/lua/sandbox.ex` | New. `Letflow.Engine.Lua.Sandbox` — the single sandbox-construction entry point and the deny-set data. |
| `test/letflow/engine/lua/sandbox_test.exs` | New. Proves the deny-set, the `:sandboxed`-replaces-defaults trap guard, and the LUA-03/LUA-04 restatement claims. |

No other file in `lib/letflow/` is touched by this requirement's `owned_modules`. (Open
Question 1 below identifies a file **outside** `owned_modules`,
`test/letflow/engine/lua_script_audit_test.exs`, that structurally conflicts with this
design and must be resolved before or alongside implementation — flagged, not silently
fixed here.)

---

## 3. Public API — `Letflow.Engine.Lua.Sandbox`

```
@spec new() :: Lua.t()
@spec new(opts :: keyword()) :: Lua.t()
```

- `new/0` is `new([])`.
- `new/1` accepts a keyword list. Only these keys are meaningful for this requirement
  (others are REQ-149/154-156's concern and are not consumed here — see §12 OQ-3 on how
  a later requirement's options compose without re-opening this deny-set):
  - no keys are required; `new/1` exists so a later requirement (REQ-152, REQ-154..156)
    can extend behavior (e.g. pass `:max_instructions`) **without** that caller ever
    constructing a `Lua.t()` via `Lua.new/1` directly. `Sandbox.new/1` is the only
    permitted call site of `Lua.new/1` anywhere under `lib/`.
- Return type: `Lua.t()` (the library's own opaque struct), never `{:ok, _} | {:error,
  _}` — construction cannot fail; there is no external I/O, no config lookup, and no
  user input at this stage. (Contrast with `LuaScriptAudit.execute_script_for_audit/6`,
  whose *execution* path is fallible; sandbox *construction* is not.)
- **Invariant SBX-1 (restated as a property, not a mechanism — see §7):** every `Lua.t()`
  value reachable anywhere in this codebase that will run tenant-supplied script text
  MUST have been produced by `Sandbox.new/0` or `Sandbox.new/1`, and by nothing else.
  This is enforced structurally (single call site) rather than by a runtime check,
  matching how `LuaScriptAudit`'s ordering invariants (INV-LSA-1/2) are enforced by
  control flow rather than by an assertion.

### 3.1 Internal deny-set constant — data shape, not implementation

The module holds one module attribute (name illustrative:
`@sandbox_deny_set` or `@denied_paths`) whose **shape** is:

```
@type deny_entry :: {path :: [atom()], reason :: String.t()}
@type deny_set :: [deny_entry()]
```

`new/1` derives the `sandboxed:` option passed to `Lua.new/1` from
`Enum.map(deny_set(), fn {path, _reason} -> path end)` (or equivalent) — the reason
strings live only in source comments / this constant, never passed to the library
(`Lua.new/1`'s `:sandboxed` option takes bare paths).

**This constant, once populated per §4, is passed as the `sandboxed:` option to
`Lua.new/1` — never the bare library default.** This is the load-bearing design
decision that avoids the `:sandboxed`-replaces-defaults trap (§5): because
`Sandbox.new/1` restates the full default list itself (plus its own additions), passing
it as `sandboxed:` cannot silently narrow anything — there is no "the default plus a
few more" call being made; there is only "the full list, written out, plus this
module's own additions."

---

## 4. The deny-set — enumerated against the ACTUAL installed Lua 5.3 stdlib

Every entry below was verified by reading `deps/lua`'s source directly (§0), not from
`lua.hexdocs.pm` documentation and not from R-Co's LuaJIT/5.1 module set. Each row states
whether the named function/table is **actually installed** in this VM (i.e. denying it
does real work) or **not installed at all** (denying it is a defensive no-op, same
category as R-Co's vacuous `jit`/`ffi`/`bit` exclusions per decision 0014).

### 4.1 Paths carried over from `Lua.new/1`'s own `@default_sandbox` (27 entries, restated explicitly per requirement scope item 2 — not referenced by pointing at the library's default)

| Path | Installed? | Reason |
|---|---|---|
| `[:io, :stdin]` … `[:io, :type]` (14 `io.*` entries: `stdin`, `stdout`, `stderr`, `read`, `write`, `open`, `close`, `lines`, `popen`, `tmpfile`, `output`, `input`, `flush`, `type`) | **Not installed.** No `io` global exists anywhere in `deps/lua` (confirmed: no file installs a global named `"io"`; no `Lua.VM.Stdlib.Io` module exists). Denying these is vacuous, same category as `jit`/`ffi`/`bit` — recorded so a future reader does not conclude the sandbox is doing filesystem-blocking work it is not. | R-Co's LUA-03 names `io` as a MUST-NOT-load module; restated for completeness even though currently vacuous under this runtime. |
| `[:file]` | **Not installed.** No `file` handle type or global exists. Vacuous, same reasoning as `io.*`. | Carried from the library default; file-handle methods (`file:read`, etc.) have nothing to attach to since no `io.open` exists to produce a handle. |
| `[:os, :execute]` | **Not installed.** `deps/lua/lib/lua/vm/stdlib/os.ex` implements only `clock`, `date`, `difftime`, `exit`, `getenv`, `setlocale`, `time`, `time_ms`, `time_us`, `tmpname` — no `execute`. Vacuous. | R-Co calls this "if reachable" — here it is not reachable at all; the strongest possible form of "MUST remove." |
| `[:os, :exit]` | **Installed** (`os_exit/2`). Real denial. | Process-termination side effect; must not be reachable from tenant script. |
| `[:os, :getenv]` | **Installed** (`os_getenv/2`). Real denial. | Host environment disclosure. |
| `[:os, :remove]` | **Not installed.** No `os_remove` function exists in `os.ex`. Vacuous. | Carried from default; filesystem mutation has nothing to attach to. |
| `[:os, :rename]` | **Not installed.** No `os_rename` function exists. Vacuous. | Same as `os.remove`. |
| `[:os, :tmpname]` | **Installed** (`os_tmpname/2`). Real denial. | Filesystem path disclosure/creation. |
| `[:package]` | **Installed** (`install_package_table/1` unconditionally sets a real `package` global table). Real denial. | Module-loading surface; not part of the MUST-load set (`math`, `string`, `table`). |
| `[:load]` | **Installed** (`base_globals/0` registers `"load"`). Real denial. | Dynamic source-text compilation from a runtime string — R-Co's LUA-03 explicit removal target. |
| `[:loadfile]` | **Not installed.** No `"loadfile"` global is ever registered anywhere in `deps/lua`. Vacuous. | Carried from default; filesystem-backed load has nothing to attach to. |
| `[:require]` | **Installed** (`base_globals/0` registers `"require"`). Real denial. | Module-loading surface, pairs with `[:package]`. |
| `[:dofile]` | **Installed** (`base_globals/0` registers `"dofile"`). Real denial. | Filesystem-backed execution. |
| `[:loadstring]` | **Not installed** — and structurally cannot be: `loadstring` is a Lua 5.1 name; Lua 5.3 (this runtime's dialect) never had it. Vacuous, and vacuous for a different reason than the `io`/`file`/`os.execute` rows above (those are installable-but-absent; this one is dialect-absent). | Restates LUA-03's literal text even though the name does not exist in this dialect — see §7(a). |

### 4.2 Path this module ADDS beyond `Lua.new/1`'s default — the requirement's central finding

PROVENANCE (historical, not current decision authority):
| Path | Installed? | Reason |
|---|---|---|
| `[:debug]` | **Installed, and NOT in `Lua.new/1`'s `@default_sandbox`.** `deps/lua/lib/lua/vm/stdlib/debug.ex` installs a real `debug` global table unconditionally (`Lua.VM.Stdlib.Debug` is in `stdlib.ex`'s `@libraries` list, run for every `Lua.new/1` call regardless of sandbox options) exposing `debug.getmetatable/1` and `debug.setmetatable/2` — its own moduledoc states these bypass `__metatable` protection — and `debug.getupvalue/2` / `debug.setupvalue/3`, which read and mutate a Lua closure's captured upvalues directly. **This is a real, non-vacuous sandbox gap in the library's own default sandbox** that R-Co's LUA-03 (which never opened `debug` at all) would have closed and that `Lua.new/1`'s defaults do not. It must be added to this module's deny-set explicitly; it is not inherited. | Metatable-protection bypass and arbitrary upvalue mutation are capabilities strictly beyond `math`/`string`/`table`'s intended surface (LUA-03's MUST-load set) and are exactly the class of introspection primitive R-Co's stdlib.zig excluded by naming `debug` outright. |

`Lua.sandbox/2`'s mechanism (`set!(lua, path, fn args -> raise ... end)`, verified at
`deps/lua/lib/lua.ex:265-270`) replaces the value at `path` with a raising callable —
the same mechanism already used for the whole-table entries `[:package]` and `[:file]`
in the library's own default list, so `[:debug]` (a single-element, whole-table path) is
a directly precedented shape, not a novel one. After sandboxing, `debug(...)` raises
directly; `debug.getmetatable(...)` raises "attempt to index a [raising function]
value" (a Lua runtime error either way) because `debug` is no longer a table. Both
outcomes satisfy this requirement's "nil or raises" acceptance criterion (AC2).

### 4.3 `string.dump` — restated per requirement scope item 2, found not installed

`deps/lua/lib/lua/vm/stdlib/string.ex` installs `lower`, `upper`, `len`, `sub`, `rep`,
`reverse`, `byte`, `char`, `format`, `find`, `match`, `gmatch`, `gsub`, `packsize`,
`pack`, `unpack` — **no `dump`.** Not installed; vacuous, and structurally so: this
runtime has no Lua bytecode representation to dump (§8, LUA-04 restatement). No
deny-set entry is needed (there is nothing at `[:string, :dump]` to sandbox), but the
test suite still asserts `string.dump` is `nil` from inside a script (AC2 lists it
explicitly), because "vacuous" is a claim this requirement must verify empirically, not
assume.

### 4.4 Total deny-set size

27 restated defaults (§4.1) + 1 addition (`[:debug]`, §4.2) = **28 entries** passed as
`Lua.new/1`'s `sandboxed:` option. `string.dump` (§4.3) needs no entry because nothing
exists at that path to deny.

---

## 5. The `:sandboxed`-replaces-defaults trap — how this design avoids it

Verified directly (§0): `Lua.new/1`'s `sandboxed:` option is consumed as `sandboxed =
Keyword.fetch!(opts, :sandboxed)` then `sandboxed |> Enum.reject(&(&1 in exclude)) |>
Enum.reduce(lua, &sandbox/2)` (`deps/lua/lib/lua.ex:146,153,175-186`) — there is no
merge with `@default_sandbox`; whatever list is passed IS the complete sandboxed set for
that VM instance. `Lua.new(sandboxed: [[:os, :time]])` therefore denies `os.time` and
**nothing else** — the trap decision 0014 and `stage-5-scripting-plugins.md`'s sign-off
section both name.

This design's `Sandbox.new/1` never passes a partial list. §4.1 restates every one of
the 27 default paths explicitly in source (not by reference to `@default_sandbox`, so a
future edit to the library's own default cannot silently change this module's behavior
underneath it), and §4.2 adds `[:debug]` as a 28th entry to the same list. `new/1`'s
`sandboxed:` argument to `Lua.new/1` is always this full 28-entry list — there is no code
path in this module that passes a shorter list. (`:exclude` is not used by this
requirement; see AC3 disposition below.)

**AC3 disposition:** this requirement passes no *additional caller-supplied* custom list
— `Sandbox.new/1`'s options (§3) do not expose a way for a caller to add or remove
individual denied paths; the 28-entry list is fixed by this module. The moduledoc must
state this explicitly and name REQ-152 as the requirement that extends the deny-set
(with the four `os` time functions) — per the acceptance criterion's stated fallback
("if no custom list is passed here, the moduledoc says so and names REQ-152"). The test
suite still asserts the trap-guard property directly (default denials, in particular
`os.execute` and `load`, hold after construction) so the guard is proven by test now
rather than only documented, and so REQ-152's extension has a passing regression test to
build on top of rather than introducing the first one.

---

## 6. `coroutine` — the explicit decision this requirement requires

**Finding:** `coroutine` does not exist in this Lua runtime at all. Confirmed by reading
`deps/lua/lib/lua/vm/stdlib.ex`'s `@libraries` list (`String`, `Math`, `Table`, `Utf8`,
`Os`, `Debug` — no `Coroutine`) and by finding zero references to `"coroutine"` anywhere
under `deps/lua/lib/`.

**Decision:** no deny-set entry for `[:coroutine]` is added. Reason: `Lua.sandbox/2`
(§4.2) works by overwriting a path with a raising function — calling it on a path that
does not currently exist would **create** a new global named `coroutine` (a callable
that raises), where none exists today. That is the opposite of the intended effect: it
manufactures a global surface rather than removing one, and a future reader diffing
`pairs(_G)` against this module's deny-set could be misled into thinking `coroutine` is
a real, sandboxed table rather than nothing at all.

**What is tested instead (§10):** a test asserts `coroutine == nil` from inside a script
constructed by `Sandbox.new/0`, proving the absence directly rather than asserting a
sandboxing action that would be a no-op at best and a fabrication at worst.

**Moduledoc requirement:** this decision and its reason (not merely "coroutine is
absent") must appear in the moduledoc, per this requirement's explicit instruction to
record the coroutine decision "either way." A one-line addendum is also required stating
that if a future `tv-labs/lua` upgrade adds a `coroutine` library, this module's test
suite (specifically the "coroutine is nil" test) will start failing (not silently pass)
and that failure is the intended trigger for revisiting this decision — recorded so
"the test broke" is legible as "the runtime changed a starting assumption," not treated
as flaky.

---

## 7. LUA-03 restatement — required moduledoc text (AC4)

The moduledoc for `Letflow.Engine.Lua.Sandbox` MUST state, in substance:

> This module restates R-Co's LUA-03 rather than satisfying its literal text, for three
> reasons:
>
> (a) **`loadstring` is a Lua 5.1 name absent from Lua 5.3.** The runtime this sandbox
> wraps implements Lua 5.3 only; there is no `loadstring` global to remove because Lua
> 5.3 never had one (renamed/merged into `load` upstream). Restated as a deny-set entry
> anyway (§4.1) for literal-text completeness, though it denies nothing that could
> otherwise be reached.
>
> PROVENANCE (historical, not current decision authority):
> (b) **`jit`, `ffi`, and `bit` do not exist in Lua 5.3 at all** — they are
> LuaJIT-specific. R-Co's exclusion of them, including `ffi` (which R-Co's own
> `stdlib.zig` calls "a COMPLETE sandbox escape"), is **vacuous** under this runtime,
> not satisfied. No deny-set entry is added for them because there is nothing at those
> paths to deny and no library file installs them.
>
> (c) **R-Co's SBX-1 invariant ("prune strictly AFTER open") does not transfer as a
> mechanism.** `Lua.new/1` sandboxes by construction — the deny-set is applied while
> building the VM state, not by opening a full stdlib and pruning it afterward — so
> there is no open-then-prune ordering for this module to get right or wrong. The
> *property* SBX-1 protects (no window during which a denied global is reachable) still
> holds and is asserted by test (§10): every test evaluates the denied path against a
> `Lua.t()` already returned by `Sandbox.new/0`, never against an intermediate
> construction state, because no such intermediate state is ever exposed by this
> module's public API.

`§4.2`'s `debug` finding is additional, not a fourth restatement reason — it is a gap in
what the *library's own default* denies, not a gap in what LUA-03's *text* could name
(R-Co's LUA-03 does name `debug` as MUST-NOT-load; this module actually satisfies that
part of LUA-03's literal text where the library's un-amended default does not).

---

## 8. LUA-04 restatement — required moduledoc text (AC5)

The moduledoc MUST state, in substance:

> This module restates R-Co's LUA-04 ("the sandbox MUST refuse to load Lua bytecode;
> only source text MAY be loaded") rather than satisfying it literally. The adopted
> runtime (`tv-labs/lua`) parses Lua source text only — it has no bytecode format, no
> bytecode loader, and therefore no bytecode-rejection code path to test. LUA-04 holds
> **structurally**: only source text can ever be loaded because nothing else is
> representable, not because a rejection check runs and returns an error. Writing a test
> that asserts "bytecode is rejected" would test a mechanism that does not exist. What
> this module tests instead (§10) is the absence of every loader capable of consuming
> either form: `load`, `loadfile`, `dofile`, and `string.dump` (§4.3) — the last of
> which is doubly structural, since without a bytecode format there is also nothing for
> `string.dump` to serialize a function *into*, and indeed no such function is installed
> at all.

---

## 9. Test suite specification (`test/letflow/engine/lua/sandbox_test.exs`)

All tests construct their `Lua.t()` exclusively via `Letflow.Engine.Lua.Sandbox.new/0`
(or `new/1` where a test needs to exercise construction-time options), never via
`Lua.new/1` directly — the test file itself is part of the "only call site" claim's
verification surface for AC1's repo search (design note: AC1's repo-search scope is
`lib/**/*.ex`, so this test file does not affect that specific grep, but its own
sandbox construction must still route through `Sandbox.new/0,1` to be testing the real
production path rather than a bypassed one).

| Test | Asserts | Acceptance criterion |
|---|---|---|
| "the only call site" | `grep -rn "Lua\.new(" lib --include=*.ex` (or equivalent `File`/`System.cmd` invocation, or a static list check) returns exactly one hit, inside `lib/letflow/engine/lua/sandbox.ex` | AC1 |
| One test per denied path in `io.open`, `io.write`, `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.tmpname`, `load`, `loadfile`, `dofile`, `require`, `package`, `debug`, `string.dump` | evaluating a script that references the path and calls it (or, for `package`/`debug` as whole-table paths, indexes into it) from inside a `Sandbox.new/0` VM returns `nil` (not installed) or raises a `Lua.RuntimeException`/similar (sandboxed) — never succeeds | AC2 |
| "default denials hold — no custom list narrows them" | after `Sandbox.new/0`, `os.execute` and `load` (at minimum, per the acceptance criterion's own wording) are still denied; because §5 establishes `Sandbox.new/1` never passes a narrower list, this test is the trap-guard regression test AC3 requires, exercised against the one options surface this module exposes | AC3 |
| "debug's metatable/upvalue functions are unreachable" | `debug.getmetatable`, `debug.setmetatable`, `debug.getupvalue`, `debug.setupvalue` each raise or are unreachable from inside a `Sandbox.new/0` VM — the concrete instance of §4.2's finding | AC2 (debug is named there), §4.2 |
| "coroutine is absent, not sandboxed" | `coroutine == nil` evaluated from inside a `Sandbox.new/0` VM | §6, AC6 |
| "math, string, table remain usable" (smoke test, not an acceptance criterion but needed so a future reader can distinguish "everything is denied" from "the intended surface is denied") | a script using `math.floor`, `string.format`, `table.insert` succeeds normally | (supporting; not itself an AC) |
| moduledoc content assertions | `Code.fetch_docs/1` on `Letflow.Engine.Lua.Sandbox`, moduledoc string contains the LUA-03 three-reason text (§7) and the LUA-04 structural text (§8) and the coroutine-decision text (§6) | AC4, AC5, AC6 |

Every "raises" assertion above is expressed against `Lua.eval!/2`'s own error-raising
behavior (confirmed shape in `deps/lua/lib/lua.ex`'s doctested examples, e.g. the
`:max_call_depth`/`:max_instructions` doctests at lines 100-102 and 129-131, which show
the pattern `{[false, message], _lua} = Lua.eval!(lua, "... pcall(...) ...")` for
in-script-caught errors, and an un-`pcall`'d raise surfaces as an Elixir exception from
`Lua.eval!/2` itself) — the exact assertion macro (`assert_raise` vs. a `pcall`-wrapped
boolean check) is an ELIXIR-DEV implementation choice, not fixed here, provided both
"nil" and "raises" outcomes are actually exercised as the acceptance criterion requires.

---

## 10. Invariants

- **INV-SBX-1** (restated SBX-1 as property, §7(c)): no `Lua.t()` used to run
  tenant-supplied script text anywhere in this codebase is constructed by any call other
  than `Sandbox.new/0` or `Sandbox.new/1`. Enforced structurally (single call site),
  verified by AC1's repo search.
- **INV-SBX-2**: the `sandboxed:` list passed to `Lua.new/1` by this module is always
  the full 28-entry list (§4.4) — never a subset, never the bare library default passed
  through unexamined. No code path in `Sandbox.new/1` constructs a shorter list.
- **INV-SBX-3**: `coroutine` is asserted absent by test, not denied by deny-set entry
  (§6) — a future library upgrade that adds `coroutine` must fail this test rather than
  silently leave it unsandboxed.
- **INV-SBX-4**: sandbox construction (`new/0`, `new/1`) never fails — no `{:error, _}`
  return shape exists for this function family (§3).

---

## 11. Open questions — not silently resolved

**OQ-1 (blocking, found during this design, not named in the requirement text) — the
mix.exs dependency does not currently exist on `main`, and a hard test guards against
re-adding it.** `mix.exs`'s `defp deps` on this branch (and on `main` as of commit
`984bbc9`) carries **no** `{:lua, ...}` entry. `git log -p -- mix.exs` shows it was added
by REQ-148 (`55f058c`/`3a62d09`) and then deliberately reverted twice
(`30db07b`, then `984bbc9` after a squash-merge reintroduced it) because
`test/letflow/engine/lua_script_audit_test.exs:419-427` ("AC5" — `describe "mix.exs and
moduledoc guardrails"`, `test "mix.exs declares no Lua/NIF-shaped dependency"`) asserts
`Mix.Project.config()[:deps]` contains no dependency name matching `"lua"`, with the
stated rationale "**while the runtime is S5-deferred**." REQ-151 cannot compile —
`Lua.new/1` does not exist as a callable without the dependency — without re-adding
`{:lua, "~> 1.0"}` to `mix.exs`, which will make that exact test fail again. This design
does not resolve which of the following ELIXIR-DEV/REVIEWER should do, because it is a
decision-record-adjacent change to a REQ-058 acceptance criterion outside this
requirement's `owned_modules`:
  - (a) update that test's assertion and its surrounding rationale comment to reflect
    that S5's Lua runtime is no longer deferred as of REQ-148's decision and this
    requirement's implementation (the test's own purpose — keeping the dependency out
    *while deferred* — no longer applies once REQ-148/151 land it for real), or
  - (b) some other resolution this design has not anticipated.
  Given SECURITY-REVIEWER and REVIEWER are already hard gates on this requirement
  (requirement text: "GATE: SECURITY-REVIEWER is a hard gate ... it is the sandbox
  boundary itself"), whichever change is made to that guardrail test should get explicit
  REVIEWER attention as part of this requirement's Step 2d, since it touches a shipped
  requirement's (REQ-058) locked acceptance criterion rather than only this
  requirement's own scope. **This is the single highest-risk item in this design** — the
  implementation cannot proceed to a passing `mix test` without addressing it, one way
  or another.

**OQ-2 (non-blocking, forward-looking):** `os.time_ms` and `os.time_us` are real,
installed functions (`deps/lua/lib/lua/vm/stdlib/os.ex:49-50`) that appear in neither
R-Co's original `os` surface nor decision 0014's "five-function gap" enumeration
(`os.time`, `os.date`, `os.clock`, `os.difftime`, `os.setlocale`). They are `os`-surface
time sources by name and are not denied by `Lua.new/1`'s default and not added by this
requirement (out of scope per §1 — REQ-152/LUA-14 territory). Recorded here so REQ-152's
designer does not miss them by enumerating only the four names decision 0014 already
listed.

**OQ-3 (non-blocking, sequencing):** this design's `Sandbox.new/1` accepts `opts ::
keyword()` but this requirement defines no meaningful keys (§3) — the parameter exists
so REQ-149/152/154-156 can add their own options (e.g. `max_instructions:`,
per-invocation `:sandboxed` additions for the time-surface) without those requirements
needing to introduce a second call site of `Lua.new/1`. This design does not specify
what those future keys are named or how they compose with the fixed 28-entry deny-set
(e.g. whether REQ-152 extends this module's own deny-set constant, or calls
`Sandbox.new/1` with an additional option this module must then merge) — left for
REQ-152's own design to resolve against whatever `Sandbox.new/1`'s actual shape becomes
once implemented.

---

## 12. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Lua` (tv-labs/lua, `deps/lua`) | `Sandbox` → `Lua` | `Lua.new/1`, `Lua.eval!/2` (test only), `Lua.RuntimeException` (test only) |
| `Letflow.Engine.LuaScriptAudit` | none (read-only context) | No code dependency; this design's scope boundary (§1) is stated relative to it, but no line of `lua_script_audit.ex` changes |
| `test/letflow/engine/lua_script_audit_test.exs` | blocks `Sandbox` | OQ-1 — the AC5 guardrail there must change (by someone, somehow) before `mix.exs` can carry the dependency this module requires to compile |
| REQ-152 (LUA-14) | consumes `Sandbox` | Will extend or wrap this module's deny-set with the four/six `os` time-surface denials (§1 out-of-scope note, OQ-2) |
| REQ-153 (Executor) | consumes `Sandbox` | The eventual `LuaScriptAudit.Executor` implementation obtains its `Lua.t()` via `Sandbox.new/1`, never `Lua.new/1` directly (INV-SBX-1) |

---

## 13. Acceptance-criteria traceability

| Acceptance criterion (verbatim, abbreviated) | Design element |
|---|---|
| Single sandbox-construction function, only call site under `lib/` | §3 `new/0,1`; INV-SBX-1; AC1 test in §9 |
| Test evaluates each named path, asserts nil-or-raises | §9 per-path test row; deny-set §4 covers every named path (`io.open`/`io.write` §4.1 vacuous, `os.execute/exit/getenv/remove/rename/tmpname` §4.1, `load/loadfile/dofile/require/package` §4.1, `debug` §4.2, `string.dump` §4.3) |
| Custom `:sandboxed` list trap guard, or moduledoc names REQ-152 | §5 (no caller-supplied custom list exists; moduledoc states this and names REQ-152); §9 trap-guard regression test |
| Moduledoc restates LUA-03, three reasons | §7 |
| Moduledoc restates LUA-04, structural/no-rejection-path | §8 |
| Deny-set written explicitly with per-entry reason; coroutine decision explicit | §4 (per-entry reason column); §6 |
| `mix test` / `mix compile --warnings-as-errors` pass with real output quoted | Not a design-time artifact — ELIXIR-DEV's Step 2a responsibility; **blocked on OQ-1** until the `mix.exs`/AC5 conflict is resolved |
