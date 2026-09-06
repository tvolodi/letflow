# Design: REQ-152 — Deny all four ambient Lua time sources; implement `platform.now` (LUA-14 restated, deliberately beyond its literal wording)

**Requirement:** REQ-152
**Stage:** S5
**Owner (design):** CODE-DESIGNER
**Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-26
**Extends:** `lib/letflow/design/req151-lua-sandbox.md` (REQ-151) — this design does not
restate REQ-151's deny-set, invariants, or moduledoc text; it adds to them. Read REQ-151's
design first.

---

## 0. Sources read for this design

- `handoffs/WF02-REQ152-20260826/step-01-code-designer.json` (`context.requirement_text`,
  `task.acceptance_criteria`)
- `docs/requirements.yaml` REQ-152 entry (full `description` and 8-item
  `acceptance_criteria`, read directly — quoted verbatim in §6 below)
- `lib/letflow/design/req151-lua-sandbox.md` (full — the design being extended)
- `lib/letflow/engine/lua/sandbox.ex` (the actual REQ-151 implementation — read directly,
  not assumed from its design doc; this surfaced a gap, see §4.2)
- `docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` — LUA-03's `os`
  enumeration (11 functions, library denies 6), the `:sandboxed`-replaces-defaults trap
  (both its LUA-03 and LUA-14 sections), LUA-14's own section
- `docs/migration/stage-5-scripting-plugins.md` (LUA-14 cross-reference; no additional
  LUA-14-specific content beyond decision 0014's text)
- `docs/guides/backend_developer_guide.md` (`@spec` / error-shape conventions)
- `deps/lua/lib/lua/vm/stdlib/os.ex` (actual installed `os` functions: `clock`, `date`,
  `difftime`, `exit`, `getenv`, `setlocale`, `time`, `time_ms`, `time_us`, `tmpname` — no
  `execute`, confirming REQ-151's finding)
- `deps/lua/lib/lua.ex` — `Lua.set!/3` (lines 332–360): the mechanism for exposing an
  Elixir function into the Lua VM at a dotted path, verified as the same function REQ-151
  identified `Lua.sandbox/2` (denial) is built on top of, but used here for the opposite
  direction (installing a callable, not replacing one with a raiser)
- `lib/letflow/engine/transition.ex` (existing "no ambient clock read" precedent — a
  process module that must not call `DateTime.utc_now/0` directly; read for the
  house style of stating this kind of constraint in a moduledoc, not because it is
  reused here)
- Repo-wide grep for an existing injectable-clock/behaviour pattern
  (`grep -rn "Clock\|DateTime.utc_now" lib/letflow`): **none found.** Every call site in
  `lib/` that needs "now" calls `DateTime.utc_now/0` directly. This design introduces the
  first behaviour-based clock seam in the codebase; there is no existing pattern to
  match, which is recorded here so a reviewer does not go looking for one.

---

## 1. Scope boundary

**In scope (per requirement text, restated):**
1. Extend REQ-151's sandbox construction so `os.time`, `os.date`, `os.clock`,
   `os.difftime` are all unreachable from a script, without un-denying any default.
2. Implement `platform.now()` returning Letflow's authoritative time as an ISO 8601 UTC
   string, wired into the Lua VM. Per decision 0014 / R-Co's capability matrix, `now` is
   **ungated by design**.
3. The time source must be injectable for exact-value testing — no direct system-clock
   read at the call site.

**Out of scope (explicitly, per requirement text):**
- Any other `platform.*` function (`platform.fail`, capability-gated functions, variable
  access) — REQ-157, REQ-159, REQ-160.
- Resource limits (`:max_instructions`, wall-clock kill, memory) — REQ-149, REQ-154..156.
- The `Executor` behaviour implementation — REQ-153.

**Additional finding that changes this requirement's necessary surface (§4.2, not
optional):** `os.setlocale` is **not actually in REQ-151's implemented deny-set** despite
REQ-151's own description text saying it "falls to REQ-151's general enumeration." REQ-152's
own acceptance criterion 3 (§6) requires `os.setlocale` proven `nil`-or-raise. This design
therefore adds `os.setlocale` to the deny-set alongside the four time functions — it is
REQ-152's responsibility to close this gap since REQ-151 did not, and since REQ-152's own
acceptance criteria are the first place this gap is checked by test. See §4.2 for the full
finding and §11 OQ-1 for why this is flagged rather than silently absorbed.

**File layout:**

| File | Purpose |
|---|---|
| `lib/letflow/engine/lua/sandbox.ex` | Extended (not replaced). Deny-set constant grows by 5 entries (§4). `Sandbox.new/1`'s construction sequence gains one step: installing `platform.now` (§5.4). |
| `lib/letflow/engine/lua/platform.ex` | New. `Letflow.Engine.Lua.Platform` — the time-source behaviour, its default implementation, the pure `now/0` function, and the Lua-VM installation function. |
| `test/letflow/engine/lua/sandbox_test.exs` | Extended. New test cases for the 5 additional denied paths and the trap-guard regression (still holds after this requirement's change). |
| `test/letflow/engine/lua/platform_test.exs` | New. `platform.now()` ISO 8601 parseability, exact-value injection, moduledoc content assertions. |

---

## 2. Deny-set extension — `lib/letflow/engine/lua/sandbox.ex`

### 2.1 What REQ-151 already denies vs. what remains reachable

Lua 5.3's `os` library has 11 functions (decision 0014, verified against the Lua 5.3
reference manual and `deps/lua/lib/lua/vm/stdlib/os.ex`): `clock`, `date`, `difftime`,
`execute`, `exit`, `getenv`, `remove`, `rename`, `setlocale`, `time`, `tmpname`.

REQ-151's implemented `@sandbox_deny_set` (verified by reading `sandbox.ex` directly, not
its design doc) covers: `execute` (vacuous — not installed), `exit`, `getenv`, `remove`
(vacuous), `rename` (vacuous), `tmpname`. That is 6 of 11 — matching decision 0014's count
exactly. **Not covered by REQ-151: `clock`, `date`, `difftime`, `setlocale`, `time`** — 5
functions, not 4. `setlocale` is not a time source (decision 0014 and REQ-151's own
description agree) but it is one of the 5 reachable-and-undenied functions, and REQ-152's
own acceptance criterion 3 requires it tested. This design closes all 5.

### 2.2 New deny-set entries (data shape — same `deny_entry :: {path :: [atom()], reason :: String.t()}` shape as REQ-151 §3.1)

| Path | Installed? | Reason | Category |
|---|---|---|---|
| `[:os, :time]` | **Installed** (`os.ex`: `time`, `time_ms`, `time_us` — `time` is the LUA-14-named one). Real denial. | LUA-14's literal, sole-named acceptance criterion: `os.time` MUST NOT be available. The platform's authoritative time is reachable only through `platform.now()` (§3). | LUA-14 literal text |
| `[:os, :date]` | **Installed** (`os_date/2`). Real denial. | Ambient time source reachable by default; not named by LUA-14's literal text but serves the identical intent (a script reading wall-clock time from an uncontrolled, host-clock-dependent source rather than the platform's single authoritative source). | LUA-14 intent extension |
| `[:os, :clock]` | **Installed** (`os_clock/2`). Real denial. | Same intent-extension reasoning as `os.date` — `os.clock` returns a CPU-time-derived value that is still an ambient, ungoverned time signal a script could otherwise read instead of `platform.now()`. | LUA-14 intent extension |
| `[:os, :difftime]` | **Installed** (`os_difftime/2`). Real denial. | Same intent-extension reasoning; `os.difftime` computes over two ambient time values — denying it removes computation over any ambient timestamp a script might otherwise have obtained (e.g. before this requirement, via `os.time`). | LUA-14 intent extension |
| `[:os, :setlocale]` | **Installed** (`os_setlocale/2`). Real denial. | Not a time source — locale-dependent formatting/parsing behavior is a nondeterminism and host-environment-disclosure surface (locale name reveals host configuration) of the same general class REQ-151 §1 scoped to "REQ-151's general enumeration," but REQ-151's implementation did not include it (§2.1 finding). Closed here because it is one of the 5 functions left reachable by REQ-151 and this requirement's own acceptance criterion 3 tests it explicitly. | Gap closure, not a time source |

`os.time_ms` and `os.time_us` (flagged as OQ-2 in REQ-151's design, non-blocking,
forward-looking) are **not** added to the deny-set by this requirement. They are real,
installed, ambient time sources by the same reasoning as `os.date`/`os.clock`/
`os.difftime`, but they are named in neither LUA-14's literal text nor decision 0014's
"five-function gap" enumeration, and REQ-152's 8 acceptance criteria (§6) do not test
them. Left open explicitly — see §11 OQ-2 — rather than silently added (which would be
scope creep beyond this requirement's acceptance criteria) or silently ignored (which
would repeat the exact "vacuous defaults" blind spot decision 0014's caution section
warns against).

### 2.3 Combined deny-set size after this requirement

28 (REQ-151) + 5 (§2.2) = **33 entries**, all still passed as one `sandboxed:` list to
`Lua.new/1` — never a partial one (§2.4).

### 2.4 The `:sandboxed`-replaces-defaults trap — restated for this extension specifically

Same mechanism finding as REQ-151 §5 (`Lua.new/1`'s `sandboxed:` option is not merged with
`@default_sandbox`; whatever list is passed IS the complete sandboxed set). The requirement
text names this as "the trap this requirement is most likely to reach for" — the intuitive
but wrong implementation is calling `Lua.sandbox(lua, [:os, :time])` (or constructing a
**second** `Lua.new(sandboxed: [[:os, :time], ...])` elsewhere) as a point-fix, either of
which either creates a second `Lua.new/1` call site (violating INV-SBX-1) or, if it
replaces the sandboxed list, un-denies the other 27/28 defaults.

**This design's answer:** the 5 new entries (§2.2) are appended directly to
`@sandbox_deny_set` in `sandbox.ex` — the same module attribute REQ-151 defined, not a new
list, not a second call. `Sandbox.new/1`'s existing derivation (`Enum.map(deny_set(),
fn {path, _} -> path end)` fed to `Lua.new/1`'s `sandboxed:` option) is unchanged in
mechanism; its input grows from 28 to 33 entries. There remains exactly one call site of
`Lua.new/1` under `lib/` (INV-SBX-1 is unaffected) and exactly one `sandboxed:` list ever
constructed (INV-SBX-2 is unaffected in kind, its cardinality changes from 28 to 33 — this
design updates INV-SBX-2's stated count, see §9).

---

## 3. `platform.now/0` — Elixir-side public API

### 3.1 Module: `Letflow.Engine.Lua.Platform`

```
@moduledoc  -- REQ-152 (LUA-14 restated). See §7 for required content.

@type iso8601_utc :: String.t()

@spec now() :: iso8601_utc()
```

- `now/0` returns the current authoritative time as an ISO 8601 string in UTC (e.g.
  `"2026-08-26T14:32:07.123456Z"` — exact subsecond precision is an ELIXIR-DEV
  implementation choice; the acceptance criterion (§6, AC4) only requires
  `DateTime.from_iso8601/1` to parse it into a UTC `DateTime.t()`, not a specific
  precision).
- Return type is a bare `String.t()`, never `{:ok, _} | {:error, _}` — same
  never-fails reasoning as `Sandbox.new/0,1` (REQ-151 §3): no I/O, no user input: reading
  an injected time source and formatting it cannot fail.
- `now/0` is **not parameterized** — it always reads the currently configured time source
  (§3.2), which is how "injectable for testability" (requirement scope item 3, AC5) is
  satisfied without every call site needing to thread a source through.

### 3.2 Time-source injection — behaviour + application-env resolution, not a direct clock read

**Chosen mechanism (this design's call, stated explicitly per the handoff's
instruction):** a **behaviour**, resolved through **application environment** at call
time (not compile time, not a hardcoded module attribute) — a hybrid of the two options
the handoff names, picked for these reasons:
- A behaviour (not a raw function reference or an explicit-arg-to-every-caller design)
  gives a typed contract (`@callback`) that a test double can `@behaviour` against, the
  same shape convention `docs/guides/backend_developer_guide.md` asks every `@spec` to
  follow.
- Application-env resolution (not a module attribute baked at compile time) lets a test
  swap the source with `Application.put_env/3` in `setup`/`on_exit` without recompiling,
  and matches how the rest of the codebase already configures pluggable behaviour (env
  keys under the `:letflow` OTP app).
- Explicit-arg-only (`now(source)`) was rejected: it would require every one of REQ-152's
  own Lua-installation call sites (§5) and every future `platform.*` caller to thread a
  source parameter, and would change `platform.now()`'s Lua-visible shape from a
  zero-argument call to something the installation wrapper would need to close over
  anyway — no simpler than resolving from application env at the point of the wrapper's
  construction, and less discoverable for a test author than a named application-env key.

```
@type source_now_result :: DateTime.t()

@callback now() :: source_now_result()
```

- Behaviour name: `Letflow.Engine.Lua.Platform.TimeSource`.
- Default implementation module: `Letflow.Engine.Lua.Platform.SystemClock` —
  `@behaviour Letflow.Engine.Lua.Platform.TimeSource`; its `now/0` is the **one and only**
  call site of `DateTime.utc_now/0` for this requirement's purposes (mirrors REQ-151's
  "single call site" invariant shape, applied to the ambient-clock read this requirement
  exists to eliminate from Lua-reachable code and to make legible in Elixir-reachable code
  too).
- Application-env key: `Application.get_env(:letflow, :lua_platform_time_source,
  Letflow.Engine.Lua.Platform.SystemClock)` — read inside `now/0` itself, every call
  (never cached in a module attribute or process dictionary), so a test can override it
  per-test without a supervision-tree restart. Config default (in `config/config.exs` or
  equivalent) sets the key explicitly to `SystemClock` rather than relying on
  `get_env/3`'s inline default alone, so the production configuration is legible by
  reading config rather than by reading this module's source (open question if
  ELIXIR-DEV finds no existing precedent for which file this belongs in — see §11 OQ-3).
- `now/0`'s body (not shown — implementation) is therefore shaped as: resolve the
  configured `TimeSource`-behaviour module from application env, call its `now/0`
  callback, convert the returned `DateTime.t()` to UTC if not already (`DateTime.
  shift_zone!/2` or equivalent — ELIXIR-DEV's choice) via `DateTime.to_iso8601/1`.

### 3.3 Exact-value injection for tests (AC5)

A test module implementing `@behaviour Letflow.Engine.Lua.Platform.TimeSource` with a
`now/0` that returns one fixed `DateTime.t()` (e.g. `~U[2026-01-01 00:00:00Z]`), set via
`Application.put_env(:letflow, :lua_platform_time_source, <test module>)` in `setup`,
reverted in `on_exit`. The test then asserts `Platform.now()` (or `platform.now()` called
from inside a script — both paths must agree, since the Lua wrapper (§5) calls `Platform.
now/0` directly) returns the exact ISO 8601 string `DateTime.to_iso8601(~U[2026-01-01
00:00:00Z])` — not merely a well-formed one. This is the concrete mechanism AC5 (§6)
requires.

---

## 4. Wiring `platform.now` into the Lua VM

### 4.1 Installation function

```
@spec install(lua :: Lua.t()) :: Lua.t()
```

- Lives on `Letflow.Engine.Lua.Platform` (the same module as `now/0` — keeps the
  Lua-installation concern next to the Elixir function it wraps, rather than splitting
  "what platform.now returns" from "how it's exposed to Lua" across two modules).
- Implemented via `Lua.set!(lua, [:platform, :now], <arity-1 or arity-2 wrapper fun>)`
  (mechanism verified at `deps/lua/lib/lua.ex:332-344` — the exact form `Lua.set!/3`
  already documents for exposing an Elixir function at a dotted path; REQ-151 used the
  sibling function `Lua.sandbox/2` for the opposite direction, replacing a path with a
  raiser). The wrapper closes over nothing except a call to `Platform.now/0` — no state,
  no arguments consumed from the Lua call.
- `install/1` is **additive only**: it never touches `@sandbox_deny_set` or any denied
  path, and it is a distinct operation from denial (§2) — installing a new global at
  `[:platform, :now]` and denying paths under `[:os, ...]` do not interact, since
  `platform` is a new top-level global this design introduces, not a rename or wrapper
  around anything `os.*` already exposed.

### 4.2 Composition point — where `install/1` is called

**Decision:** `Sandbox.new/1`'s construction sequence (in `sandbox.ex`) gains one step
after `Lua.new(sandboxed: sandboxed_paths)`: `|> Letflow.Engine.Lua.Platform.install()`.
Every `Lua.t()` produced by `Sandbox.new/0` or `Sandbox.new/1` therefore has
`platform.now` available, with no second call any caller must remember to make.

Reasons this composition point (not "callers install platform functions themselves"):
- Preserves REQ-151's INV-SBX-1 framing in spirit: there remains exactly one place that
  fully describes what a tenant-facing `Lua.t()` can do (deny-set + installed globals),
  not two places a future reader must both check.
- Gives REQ-157/159/160 (out of scope here, but named in the requirement text as the
  next `platform.*` work) an established pattern to extend: each adds its own
  `install/1`-shaped function to its own module and each is added to `Sandbox.new/1`'s
  same post-construction pipeline, rather than each requirement inventing its own
  wiring point.
- `Sandbox` gains a compile-time dependency on `Platform` (`sandbox.ex` calls
  `Platform.install/1`). This is a one-directional dependency (§8) and does not create a
  cycle since `Platform` does not call back into `Sandbox`.

---

## 5. `platform.now` is ungated by design — required moduledoc statement (AC7)

PROVENANCE (historical, not current decision authority):
Per decision 0014 / R-Co's `src/lua/host_api/mod.zig` capability matrix (as quoted in the
requirement text): `now` is **"a pure time read with no state reach"** and its matrix
entry is **"a POSITIVE design statement, not an omission... A test that expects a gate on
either is reading the matrix wrong."**

This design states, as a positive claim (not an absence-of-mention): **`platform.now/0`
has no capability check, no gate, no permission lookup, anywhere in its call path — by
design, permanently, not "not yet implemented."** `install/1` (§4.1) wires it
unconditionally into every `Lua.t()` `Sandbox.new/0,1` produces; there is no
`Sandbox.new/1` option that can suppress or gate it, and none should ever be added.

**Binding statement for future requirements (AC7's own text):** REQ-157's capability-gating
work (out of scope here) MUST NOT add a gate to `platform.now` "by symmetry" with whatever
gating mechanism it introduces for other `platform.*` functions. This must appear in
`Letflow.Engine.Lua.Platform`'s moduledoc verbatim in substance, so a future implementer
reads it before writing a capability check that happens to also cover `now`.

---

## 6. Acceptance-criteria traceability (all 8, verbatim from `docs/requirements.yaml` REQ-152)

| # | Acceptance criterion (verbatim) | Design element |
|---|---|---|
| 1 | "a test evaluates `os.time`, `os.date`, `os.clock`, and `os.difftime` from INSIDE a script and asserts each is nil or raises... this is LUA-14's own acceptance criterion for `os.time`, extended to the other three" | §2.2 rows 1-4 (deny-set entries); test evaluates each from inside a `Sandbox.new/0` script, same "nil or raises" assertion shape as REQ-151 §9 |
| 2 | "a test asserts the default denials still hold after this requirement's sandbox change — at minimum `os.execute` and `load` are still nil-or-raise... explicitly guarding the `:sandboxed`-replaces-defaults trap" | §2.4 (append-only extension of the same `@sandbox_deny_set`, never a second/partial list); trap-guard regression test re-run against the 33-entry list, asserting `os.execute` and `load` (REQ-151's original trap-guard targets) still denied |
| 3 | "a test evaluates `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.setlocale`, and `os.tmpname` from inside a script and asserts each is nil or raises, so that combined with the four above all ELEVEN Lua 5.3 `os` functions are proven unreachable" | §2.1-§2.2: 6 of these 7 are REQ-151's existing entries (re-tested, unchanged); `os.setlocale` is this requirement's gap-closure addition (§2.2 row 5, §11 OQ-1) — combined with criterion 1's four, all 11 `os` functions are covered |
| 4 | "`platform.now()` called from inside a script returns a string that Elixir's `DateTime.from_iso8601/1` parses successfully into a UTC `DateTime`, asserted by test" | §3.1 `now/0`'s `iso8601_utc()` return type; §4 `install/1` wiring exposes it at `[:platform, :now]`; test calls the script-visible `platform.now()`, captures the returned string, asserts `{:ok, %DateTime{}, 0}` (or equivalent UTC-offset tuple) from `DateTime.from_iso8601/1` |
| 5 | "the time source is injectable and a test asserts `platform.now()` returns one exact, pre-set timestamp rather than merely a well-formed one" | §3.2 `TimeSource` behaviour + application-env resolution; §3.3 exact-value test mechanism |
| 6 | "the moduledoc states that this requirement restates LUA-14, that `os.time` is NOT in `Lua.new/1`'s default deny-set (6 of the 11 `os` functions are denied by default; `os.clock`/`os.date`/`os.difftime`/`os.setlocale`/`os.time` are not), and that denying `os.date`/`os.clock`/`os.difftime` goes BEYOND LUA-14's literal wording as a deliberate extension of its intent" | §2.1's finding (6 of 11 denied, 5 undenied, named exactly) and §2.2's per-row "LUA-14 literal text" vs. "LUA-14 intent extension" categorization must appear in `sandbox.ex`'s moduledoc, appended to its existing REQ-151 text (not replacing it) |
| 7 | "the moduledoc records that `platform.now` is ungated by design per R-Co's... capability matrix, so a future requirement adding a capability gate to it is wrong" | §5, verbatim required moduledoc content, on `Letflow.Engine.Lua.Platform` |
| 8 | "`mix test` and `mix compile --warnings-as-errors` both pass with real output quoted" | Not a design-time artifact — ELIXIR-DEV's Step 2a responsibility. Unlike REQ-151, this design identifies no equivalent blocking OQ-1 (the `mix.exs` dependency question) since REQ-151/REQ-148 already landed the dependency by the time this run starts — see §11 OQ-4 for the one caveat on this point. |

---

## 7. Required moduledoc content — summary (full text is ELIXIR-DEV's to write; content obligations only)

**`lib/letflow/engine/lua/sandbox.ex` moduledoc (appended, not replacing REQ-151's
existing text):**
- States this file also implements REQ-152 now.
- States the 6-of-11 / 5-undenied finding (§2.1) and the "beyond LUA-14's literal
  wording" framing (§2.2) — AC6.
- States the deny-set is now 33 entries and updates INV-SBX-2's stated count (§9).
- States the `os.setlocale` gap-closure finding (§2.2 row 5, §11 OQ-1) explicitly, so a
  future reader does not conclude `setlocale` was always covered.

**`lib/letflow/engine/lua/platform.ex` moduledoc:**
- Restates LUA-14's text and REQ-152's restatement rationale (this file's own summary,
  not copied from `sandbox.ex`).
- States the `platform.now` ungated-by-design claim verbatim per §5 — AC7.
- States the injection mechanism chosen (§3.2) and why (behaviour + app-env, not a raw
  clock read at the call site) — supports AC5's testability claim being legible from the
  moduledoc, not only from test code.
- States `install/1`'s composition point (§4.2) — that `Sandbox.new/1` calls it, so a
  reader of `platform.ex` alone knows how a script ever sees `platform.now` at all.

---

## 8. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Engine.Lua.Sandbox` (REQ-151) | `Sandbox` extended in place | `@sandbox_deny_set` grows 28→33 entries (§2); `new/1` gains one pipeline step calling `Platform.install/1` (§4.2) |
| `Letflow.Engine.Lua.Platform` (new) | `Sandbox` → `Platform` | One-directional: `Sandbox.new/1` calls `Platform.install/1`. `Platform` has no dependency back on `Sandbox` |
| `Letflow.Engine.Lua.Platform.TimeSource` (new behaviour) | `Platform` → `TimeSource` | `Platform.now/0` resolves and calls the configured implementation's `now/0` callback |
| `Letflow.Engine.Lua.Platform.SystemClock` (new, default impl) | `Platform` → `SystemClock` (default, overridable) | The only production call site of `DateTime.utc_now/0` for this requirement's surface |
| `Lua` (`deps/lua`) | `Platform` → `Lua` | `Lua.set!/3` (installation), `Lua.new/1`'s `sandboxed:` consumption (unchanged mechanism, larger list) |
| REQ-153 (Executor) | consumes `Sandbox`, transitively `Platform` | Obtains its `Lua.t()` via `Sandbox.new/1` (unchanged call), which now also carries `platform.now` |
| REQ-157/159/160 (future `platform.*` work) | extend `Platform`'s composition point | Each adds its own `install/1`-shaped function and its own entry in `Sandbox.new/1`'s post-construction pipeline (§4.2); none may add a gate to `platform.now` itself (§5, AC7) |

---

## 9. Invariants (extending REQ-151's INV-SBX-1..4)

- **INV-SBX-2 (updated count):** the `sandboxed:` list passed to `Lua.new/1` by
  `Sandbox.new/1` is always the full **33-entry** list (28 REQ-151 + 5 REQ-152) — never a
  subset, never a second/partial list. No code path constructs a shorter list.
- **INV-PLAT-1 (new):** `platform.now` is reachable from every `Lua.t()` produced by
  `Sandbox.new/0` or `Sandbox.new/1` — there is no sandbox-construction path that omits
  `Platform.install/1`.
- **INV-PLAT-2 (new):** `platform.now`'s call path contains no capability check, gate, or
  permission lookup, structurally (§5) — enforced by there being no such mechanism
  anywhere in `Platform`'s code, not by a runtime assertion.
- **INV-PLAT-3 (new):** `Letflow.Engine.Lua.Platform.SystemClock.now/0` is the only
  production call site of `DateTime.utc_now/0` introduced by this requirement's module
  set (`platform.ex`); every other read of "now" for Lua-visible time goes through
  `Platform.now/0`, which resolves the configured `TimeSource` rather than reading the
  system clock directly.

---

## 10. Test suite specification additions

| Test | Asserts | Acceptance criterion |
|---|---|---|
| `sandbox_test.exs`: one case per `os.time`, `os.date`, `os.clock`, `os.difftime` | nil or raises, from inside `Sandbox.new/0` | AC1 |
| `sandbox_test.exs`: "default denials still hold after REQ-152's extension" | `os.execute`, `load` (REQ-151's original trap-guard targets) still nil-or-raise against the 33-entry list | AC2 |
| `sandbox_test.exs`: one case per `os.execute`, `os.exit`, `os.getenv`, `os.remove`, `os.rename`, `os.setlocale`, `os.tmpname` | nil or raises | AC3 |
| `platform_test.exs`: "`platform.now()` returns a `DateTime.from_iso8601/1`-parseable UTC string" | script calls `platform.now()`, captured return value parses via `DateTime.from_iso8601/1` to `{:ok, %DateTime{}, _offset}` | AC4 |
| `platform_test.exs`: "exact timestamp injection" | test `TimeSource` impl returns a fixed `DateTime.t()`; `platform.now()` (both `Platform.now/0` directly and via a script) returns exactly `DateTime.to_iso8601(<fixed value>)` | AC5 |
| `sandbox_test.exs`: moduledoc content assertions | `Code.fetch_docs/1` on `Sandbox`, moduledoc contains the 6-of-11/5-undenied text and "beyond LUA-14" framing | AC6 |
| `platform_test.exs`: moduledoc content assertions | `Code.fetch_docs/1` on `Platform`, moduledoc contains the ungated-by-design statement | AC7 |
| (all of the above) | `mix test` and `mix compile --warnings-as-errors` pass, real output quoted | AC8 |

---

## 11. Open questions — not silently resolved

**OQ-1 (blocking-in-substance, found during this design, not named in the requirement
text) — `os.setlocale` is not covered by REQ-151's implemented deny-set, contrary to
REQ-151's own description text.** REQ-151's requirement text (quoted in this run's
handoff) states `os.setlocale` "falls to REQ-151's general enumeration rather than to
this requirement's restatement." Reading `sandbox.ex` directly (§0) shows REQ-151's
`@sandbox_deny_set` has no `[:os, :setlocale]` entry — only a mention of `setlocale`
inside a comment string describing what `os.ex` installs. REQ-152's own acceptance
criterion 3 requires `os.setlocale` tested nil-or-raise, so this gap must close somewhere,
and this design closes it here (§2.2 row 5) rather than treating it as silently REQ-151's
problem to have already solved. **This is a deliberate scope decision this design makes,
not an ambiguity left for ELIXIR-DEV** — flagged as an open question only in the sense
that CODE-DESIGN-VALIDATOR and SECURITY-REVIEWER should confirm this disposition (closing
it in REQ-152 rather than reopening REQ-151) is correct, since it is a boundary call
between two requirements' `owned_modules`, not a pure implementation detail.

**OQ-2 (non-blocking, forward-looking, carried over from REQ-151's OQ-2):**
`os.time_ms` and `os.time_us` remain undenied and untested by this requirement (§2.2).
They are real ambient time sources by the same reasoning that justifies denying
`os.date`/`os.clock`/`os.difftime`, but neither LUA-14's literal text, decision 0014's
five-function enumeration, nor REQ-152's 8 acceptance criteria name them. Left open for
whichever future requirement or REVIEWER pass next touches the `os` deny-set to decide
whether to close by the same "ambient time source" reasoning this requirement applies to
the other three, or to leave as permanently out of LUA-14's intended scope.

**OQ-3 (non-blocking, sequencing) — where the application-env default is set.** §3.2
specifies `Application.get_env(:letflow, :lua_platform_time_source, SystemClock)` is read
at call time with `SystemClock` as the inline default, and states production config
"should" also set this key explicitly in `config/config.exs` for legibility. This design
does not fix which config file (`config/config.exs` vs `config/runtime.exs`) that
explicit entry belongs in — a codebase-convention question, not a REQ-152-scoped one —
left for ELIXIR-DEV to resolve by matching whatever this project's existing
`config/*.exs` layout does for comparable static module-selection keys, if any exist.

**OQ-4 (non-blocking, dependency-freshness check) — this design assumes REQ-151/REQ-148's
`{:lua, "~> 1.0"}` `mix.exs` dependency and `test/letflow/engine/lua_script_audit_test.exs`
guardrail conflict (REQ-151's OQ-1) is already resolved on this branch's parent state,
since this run starts from REQ-151 having merged. This design does not re-verify that;
ELIXIR-DEV's Step 2a `mix compile`/`mix test` run is where a stale assumption here would
surface, per AC8.**

---

## 12. What this design does NOT do (explicit non-goals, matching requirement's "NOT IN THIS REQUIREMENT")

- No other `platform.*` function (`platform.fail`, variable/service access) — REQ-157,
  REQ-159, REQ-160. `Platform.install/1`'s shape (§4.1) is written generally enough that a
  later requirement's `install/1`-shaped function can be added alongside it in
  `Sandbox.new/1`'s pipeline (§4.2), but no such function is designed or stubbed here.
- No capability-gating mechanism of any kind is introduced — `platform.now`'s ungated
  status (§5) is a property of there being no gating mechanism yet, not of `now`
  bypassing one.
- No change to `LuaScriptAudit` or the `Executor` behaviour — REQ-153's territory,
  untouched, same as REQ-151 §1's boundary.
