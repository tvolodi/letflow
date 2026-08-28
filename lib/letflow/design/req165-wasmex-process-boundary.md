# REQ-165 — Adopt `wasmex` behind a mandatory process boundary, with a pinned Rust toolchain in CI

**Requirement:** REQ-165 (WASM-01 restated, OQ-7). First requirement of S5's WASM half;
every other WASM requirement `depends_on` it.
**Stage:** S5
**Owner (design):** CODE-DESIGNER — **Owner (implementation):** ELIXIR-DEV
**Date:** 2026-08-28
**Depends on (settled context, cited not re-derived):**
`docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md` Decision (2)/(4),
Reasoning (a)/(d)/(f); `docs/migration/decisions/0005-pin-formatting-toolchain.md`
(toolchain-pinning convention); `lib/letflow/engine/plugin_interface.ex` (the
`@behaviour` and `invoke/2,3` this design reuses verbatim); `lib/letflow/design/
req163-wasm-abi-choice.md` (core-modules ABI choice, `wasmex` v0.15.1 evidence);
`lib/letflow/design/req164-wasm-compilation-hosting.md` (no hosted compilation — this
requirement only ever receives/handles an already-produced `.wasm`/`.wat` artifact).

This design does **not** design the full plugin ABI (`init`/`execute`/`deinit`/
`get_capabilities`, `alloc`) — that is REQ-166's scope, built on REQ-163's decision.
This requirement's guest is deliberately trivial: its only job is to prove (1) `wasmex`
actually builds its native code in this repo, (2) a guest call is dispatched through
`PluginInterface.invoke/2,3`'s existing process boundary, never inline, and (3) a
hanging guest surfaces as `{:error, reason}`, never an exception/exit.

---

## §0 — Research finding that changes OQ-7's scope (read this before §2)

OQ-7 ("Rust toolchain pinning in CI") was framed as "mechanism is S6 operational
scope," but the mechanism turns out to be pure S5/CI scope, and one fact narrows it
further than assumed: **`wasmex` does not always need a local Rust build to produce a
usable NIF.**

Verified directly (not inferred) on 2026-08-28:

- `wasmex`'s own `mix.exs` `deps/0` (fetched from
  `https://github.com/tessi/wasmex/blob/main/mix.exs`) lists exactly four dependency
  entries: `{:rustler_precompiled, "~> 0.9"}`, `{:rustler, "~> 0.38"}`,
  `{:ex_doc, "~> 0.40.3", only: [:dev, :test]}`, and
  `{:credo, "~> 1.7.19", only: [:dev, :test], runtime: false}`.
  `rustler_precompiled` means: on a platform `wasmex` publishes a precompiled NIF
  artifact for, `mix deps.get` + `mix compile` can succeed by **downloading** a
  prebuilt `.so`, never invoking `cargo`/`rustc` at all. A "successful fetch" in that
  mode proves nothing about whether Letflow's own toolchain can build the native code
  — which is exactly the gap REQ-165's AC1 calls out ("a successful fetch alone does
  not satisfy this").
- `wasmex`'s own README (fetched 2026-08-28), quoted: *"If you plan to change something
  on the Rust part of this project, set the following ENV `WASMEX_BUILD=true`"* — this
  is `wasmex`'s own documented switch that forces `rustler_precompiled` to build from
  source (`force_build: true`) rather than fetch a precompiled artifact, regardless of
  whether a precompiled one exists for the running platform.
- `wasmex`'s own CI (`https://github.com/tessi/wasmex/blob/main/.github/workflows/
  elixir-ci.yml`, fetched 2026-08-28) sets `WASMEX_BUILD: true` at workflow scope and
  installs a Rust toolchain unconditionally in every job that touches native code — the
  maintainers themselves never trust the precompiled path to prove their own CI green,
  they force a real build every run.
- `wasmex`'s own `.tool-versions` (repo root, fetched via `gh api repos/tessi/wasmex/
  contents/.tool-versions` 2026-08-28), verbatim:
  ```
  erlang 29.0.3
  elixir 1.20.2-otp-29
  rust 1.97.1
  ```
  This is the **identical asdf/`.tool-versions` convention** Letflow's own
  `0005-pin-formatting-toolchain.md` already established for Elixir/Erlang — `wasmex`
  itself pins its Rust toolchain the same way, in the same file shape, which is direct
  corroborating precedent (not merely 0005's own precedent) for §2 below.
- `wasmex`'s own CI installs that pinned Rust version via `dtolnay/rust-toolchain@stable`
  with `toolchain: 1.97.1` — the GitHub-Actions-native equivalent of `setup-beam`'s
  role for Elixir/OTP (there is no asdf-rust `setup-beam`-style action that reads
  `.tool-versions` directly; `dtolnay/rust-toolchain` is the closest CI action to that
  role, exactly as `erlef/setup-beam` is for Elixir/OTP).

**Consequence for this design:** OQ-7's real scope is not "does CI need Rust at all" —
on `ubuntu-latest` (Letflow's CI runner), `wasmex` v0.15.1 likely *does* ship a
precompiled NIF and a bare `mix deps.get && mix compile` might well succeed without
`cargo` ever running. That would satisfy REQ-165 AC1's first half ("`mix compile`...
completes") while failing its explicit second half ("the native build succeeding...
a successful fetch alone does not satisfy this"). The design therefore mandates
**forcing** a real source build — via `wasmex`'s own `WASMEX_BUILD=true` switch — both
for the one-time proof run this requirement's acceptance criteria demand and inside
Letflow's own CI job, so Letflow never mistakes "a precompiled binary happened to
exist" for "our pinned Rust toolchain can build our own native dependency." This must
be stated as a deliberate choice, not left implicit: **without `WASMEX_BUILD=true`, CI
would likely never touch Rust at all**, and OQ-7 would go unanswered by a passing
build.

---

## §1 — `mix.exs` dependency addition and config

**Exact dependency line**, in `defp deps do ... end` (alphabetical position per the
existing list's ordering — after `{:ueberauth_oidcc, ...}`, before `{:lua, "~> 1.0"}`
would break the existing near-alphabetical-by-topic grouping; ELIXIR-DEV should append
it at the end of the list next to `:lua`, since both are the two scripting/plugin-runtime
binds decision 0014 introduces):

```elixir
{:wasmex, "~> 0.15.1"}
```

Grounded in: `https://github.com/tessi/wasmex` README's own installation snippet
(`{:wasmex, "~> 0.15.1"}`, fetched 2026-08-28) and hex.pm's package page
(`https://hex.pm/packages/wasmex`, current release **v0.15.1**, published
**2026-08-07**, accessed 2026-08-28) — matching the version `req163-wasm-abi-choice.md`
§1 already grounded its own ABI evidence in, so both artefacts cite the same version.

**No `config/*.exs` entry is required for this requirement.** `wasmex` needs no
`config.exs` block to compile or to be called from a handler with per-call options
(`Wasmex.start_link/1`'s engine/store config is passed as call-site arguments, not
global config, per `req163-wasm-abi-choice.md` §1). A future requirement introducing
engine-wide tuning (`Wasmex.EngineConfig`'s `:consume_fuel`/`:cranelift_opt_level`,
`Wasmex.StoreLimits`) may add one; REQ-165's trivial handler does not need it and must
not add speculative config.

**Transitive dependencies** `mix deps.get` resolves and locks into `mix.lock`, not
added directly to Letflow's own `deps/0`: `rustler_precompiled ~> 0.9`, `rustler
~> 0.38` (both `wasmex`'s own deps, quoted in §0). Letflow does not depend on
`rustler`/`rustler_precompiled` directly and must not add a redundant direct entry —
Mix already resolves and locks the versions `wasmex` itself constrains.

**Required environment for the acceptance-proving build.** Per §0, the fetch/compile
run(s) ELIXIR-DEV executes to satisfy AC1 must set `WASMEX_BUILD=true` in the shell
environment, e.g.:

```
WASMEX_BUILD=true mix deps.get
WASMEX_BUILD=true mix compile
```

and quote the real `cargo`/`rustc` invocation output `mix compile` prints when it
actually builds the NIF (a `Compiling wasmex v0.x.x (native/wasmex)` / `cargo build
--release` style line), not merely `Resolving Hex dependencies...` / `* Getting
wasmex...`, which is what a precompiled-fetch path alone would print.

---

## §2 — Rust toolchain pinning, mirroring decision 0005's convention exactly

**Decision 0005's chosen mechanism, restated precisely (not just its Options list):**
a single repo-root `.tool-versions` file (asdf-style) is the one source of truth for
every pinned toolchain version; `.github/workflows/ci.yml` reads that same file via
the corresponding setup action's version-file input (`erlef/setup-beam`'s
`version-file: .tool-versions`) rather than duplicating the version as a hardcoded
string in the workflow, specifically "so CI and local `mix letflow.check_toolchain`
can never silently drift apart — the same file backs both" (`ci.yml`'s own inline
design-note comment, quoted verbatim); and an **advisory, never-failing** Mix task
(`lib/mix/tasks/letflow.check_toolchain.ex`) warns on local drift without ever
changing another check's exit code (0005's 2026-08-21 amendment, Constraint 2/3).

**This requirement adds exactly one line to the same file — no second toolchain-pin
file or mechanism is introduced:**

`.tool-versions`, new contents (diff — one line appended):

```
elixir 1.20.3-otp-29
erlang 29.0.5
rust 1.97.1
```

**Version grounding for `1.97.1`.** Per §0, this is the exact version `wasmex`'s own
maintainers pin in their own `.tool-versions` and verify their own native code against
in their own CI (`dtolnay/rust-toolchain@stable` with `toolchain: 1.97.1`,
`https://github.com/tessi/wasmex/blob/main/.github/workflows/elixir-ci.yml`, fetched
2026-08-28). This is the strongest evidence-grounded choice available: not "whatever
Rust happens to be newest," but the exact version the library's own authors compile
and test the native code Letflow is adopting against.

**CI config diff (`.github/workflows/ci.yml`, `jobs.backend.steps`):** insert a new
step immediately after "Set up Elixir/OTP (from .tool-versions)" and before "Cache
deps and `_build`" (Rust must be available before `mix deps.get`/`mix compile` run,
and caching the Rust toolchain setup itself is out of scope for this minimal step):

```yaml
      - name: Read pinned Rust version from .tool-versions
        id: rust_pin
        run: |
          version=$(grep -E '^rust ' .tool-versions | awk '{print $2}')
          echo "version=$version" >> "$GITHUB_OUTPUT"

      - name: Set up Rust (pinned via .tool-versions)
        uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: ${{ steps.rust_pin.outputs.version }}
```

This mirrors `setup-beam`'s `version-file: .tool-versions` role as closely as GitHub
Actions' Rust-toolchain actions allow: there is no `dtolnay/rust-toolchain`
`version-file:` input (confirmed against its documented inputs — only `toolchain`,
`components`, `target`, `profile`), so the pinned version is read out of
`.tool-versions` by a preceding shell step and threaded into `toolchain:` via
`$GITHUB_OUTPUT`, rather than hardcoding `1.97.1` a second time inside `ci.yml`. This
preserves 0005's actual property under test ("the same file backs both"): a future
Rust-version bump changes one line in `.tool-versions` and nothing in `ci.yml`.

**The "Run backend gate" step gains `WASMEX_BUILD: true`** (env, scoped to that one
step — not the whole job, since other steps never touch `wasmex`):

```yaml
      - name: Run backend gate
        run: mix letflow.check
        env:
          WASMEX_BUILD: true
```

Per §0, without this, `mix letflow.check`'s own `mix compile` (nested inside `mix
test`'s alias chain, and standalone in the alias) could pass via a precompiled fetch
and never exercise the pinned Rust toolchain at all — silently defeating the point of
pinning it.

**`mix letflow.check_toolchain` extension (advisory, never-failing — same shape as its
existing Elixir/OTP checks).** `lib/mix/tasks/letflow.check_toolchain.ex`'s
`@recognised_tools` list (currently `["elixir", "erlang"]`) gains `"rust"`, and its
`parse/1`/`report/3` pipeline (already a *total* function over `.tool-versions`
contents — see its moduledoc's "Failure modes" section) gains a third pin row. Unlike
the Elixir/OTP comparisons (`System.version/0`, `:erlang.system_info(:otp_release)` —
both BIFs that cannot fail), the running Rust value can only be obtained by shelling
out (`System.cmd("rustc", ["--version"])`), which **can** fail (binary absent, `PATH`
without `rustc`, execution error) in a way the existing two comparisons structurally
cannot. This is a genuinely new failure mode, not present in the shipped module, and
must be designed for explicitly rather than assumed away:

a new private helper is needed: `@spec running_rust_version() :: {:ok, String.t()} | :not_found`.

- `:not_found` (covers `System.cmd/2` raising `ErlangError` for a missing executable,
  or returning a non-zero exit status) folds into a **new**, symmetrical failure-mode
  row alongside F1–F8 in the moduledoc — e.g. **F9**: "rust pinned in `.tool-versions`
  but `rustc` not found or not runnable on this host" — printed via the same
  `not_checked`/`warn_block` machinery, never raising, exactly like every other path in
  this module. If `.tool-versions` has no `rust` line at all, the existing "not
  pinned" row shape (F3/F4's pattern) extends to Rust with no new logic needed, since
  that path never shells out at all (`expected_rust(nil)` short-circuits, mirroring
  `expected_elixir(nil)`/`expected_otp_major(nil)`).
- The comparison itself is `rustc --version`'s output, e.g. `rustc 1.97.1 (abc1234
  2026-01-01)`, parsed for the leading semantic-version token and compared to the pin
  by exact string equality — same "no fuzzy version-range logic, exact string compare"
  discipline the Elixir/OTP checks already use.
- This extension is **additive only**: it must not change the module's core
  guarantee ("never fails the build," `run/1` always returns `:ok`) or its output
  discipline (unsuppressible, `:stderr`, first in the alias). ELIXIR-DEV implements
  this; CODE-DESIGN-VALIDATOR should treat "the shape of the existing Elixir/OTP rows,
  extended by one more tool and one new not-found failure mode" as the full spec —
  there is no further design decision left open here.

---

## §3 — The new handler module

**Location:** `lib/letflow/engine/wasm/plugin_handler.ex` (new directory
`lib/letflow/engine/wasm/`, as the task's `owned_modules` scope names).
**Module:** `Letflow.Engine.Wasm.PluginHandler`. Declares
`@behaviour Letflow.Engine.PluginInterface`.

### 3.1 Public contract

`@spec handle_node(Letflow.Engine.PluginInterface.ExecutionContext.t()) ::
Letflow.Engine.PluginInterface.outcome()` — the sole `@callback` implementation `PluginInterface` requires (per
`plugin_interface.ex`'s own `@callback handle_node(context) :: outcome()`). Per that
module's own moduledoc, **this function is never called directly** by anything this
requirement adds — the only caller path this design specifies or tests is through
`Letflow.Engine.PluginInterface.invoke/2,3`, exactly as `plugin_interface.ex`'s own
moduledoc mandates for every handler.

### 3.2 Internal flow (spec-level, no literal bodies)

A private helper, `@spec run_trivial_guest() :: {:ok, integer()} | {:error, String.t()}`,
carries out the following steps in order:

1. Read the trivial guest fixture's `.wat` source from
   `priv/wasm_fixtures/req165_trivial.wat` (checked into the repo — see §3.3; a `priv/`
   location, not `test/`, because this module is production code REQ-166 and later
   requirements may reuse as a smoke-test guest, not test-only scaffolding).
2. `Wasmex.start_link(%{bytes: <fixture bytes>})` — instantiates a fresh Wasmtime
   instance for **this call only** (per decision 0014 (e)'s per-invocation isolation
   principle already established for Lua; REQ-165 does not attempt `wasmex`'s
   Store-pooling optimization, which decision 0014 (e) itself flags as a WASM-13/OQ
   concern, not this requirement's).
3. `Wasmex.call_function(instance_pid, "answer", [], timeout_ms)` — the guest's one
   export (§3.3). `timeout_ms` here is `wasmex`'s **own**, call-level timeout
   (`call_function/4`'s fourth argument; per `req163-wasm-abi-choice.md` §1's quoted
   "default timeout 5 seconds"); it is deliberately set **longer** than the outer
   `PluginInterface.invoke/3`'s `timeout_ms` option in the hang test (§5) so the test
   proves the *outer* task boundary is what terminates a hang, not `wasmex`'s own
   internal interrupt — the two timeouts are independent layers by design, mirroring
   how LUA-08 (in-band) and LUA-10 (out-of-band) are two independent layers per
   decision 0014 (a).
4. `GenServer.stop(instance_pid)` — `Wasmex.start_link/1` returns an ordinary
   `GenServer` pid with no automatic cleanup hook on the caller side; a `wasmex`
   instance not explicitly stopped after use would leak a live Wasmtime instance per
   invocation. This call happens on every path, including the error path (`after`-style
   cleanup at the design level — ELIXIR-DEV's implementation must not skip this on the
   `{:error, _}` branch).
5. Map the guest's raw `:i32` result to the `outcome()` shape: `{:complete, %{"answer"
   => value, "executed_in_pid" => self()}}` on success (see §4 for why the pid is
   included), `{:error, reason}` on any `Wasmex` call failure (a guest trap, a call
   timeout at `wasmex`'s own layer, or an instantiation failure).

### 3.3 The trivial guest fixture

`priv/wasm_fixtures/req165_trivial.wat` (checked in verbatim — WAT text, not Elixir
code; `wasmex` compiles `.wat` bytes directly per `req163-wasm-abi-choice.md` §1, so no
second toolchain such as WABT/`wat2wasm` is introduced to produce a `.wasm` binary
ahead of time):

```wat
(module
  (func (export "answer") (result i32)
    i32.const 42))
```

This is deliberately **not** WASM-02's four-export ABI (`init`/`execute`/`deinit`/
`get_capabilities` + implicit `alloc`, `req163-wasm-abi-choice.md` §3.1) — REQ-165's
own scope line states the guest need only be "enough to prove the process boundary and
the toolchain, not the full ABI (REQ-166's)." No `memory` export is needed either,
since `answer`'s signature uses only a bare `:i32` result — no string/buffer payload
crosses the boundary, so §3.1's memory convention does not apply here at all.

---

## §4 — Proving the process boundary structurally

**Mechanism (mirrors `plugin_interface.ex`'s own `invoke/2,3`, read at
`lib/letflow/engine/plugin_interface.ex:187-193` — cited, not restated, and not
modified by this requirement):** `invoke/2,3` starts the handler call via
`Task.Supervisor.async_nolink/2` under `Letflow.Engine.PluginTaskSupervisor`, passing it
an anonymous function whose sole body is a call to `handler.handle_node(context)`; it
then bounds that task with `Task.yield/2` against `timeout_ms`, and routes the yield
result through the existing private `handle_yield_result/4` clauses (`{:ok, outcome}`,
`{:exit, reason}`, or `nil` on timeout).

`Letflow.Engine.Wasm.PluginHandler.handle_node/1` runs **inside the anonymous function
passed to `Task.Supervisor.async_nolink/2`**, i.e. inside a process the already-running,
already-supervised `Letflow.Engine.PluginTaskSupervisor` (started in
`lib/letflow/application.ex`, unchanged by this requirement — confirmed by grep, no new
supervisor is added) spawns fresh per call. `self()`, evaluated inside `handle_node/1`,
therefore returns that Task process's pid — necessarily different from whatever process
called `PluginInterface.invoke/2,3`.

**The proof mechanism this design specifies:** `handle_node/1`'s `{:complete, %{...}}`
outcome includes `"executed_in_pid" => self()` (§3.2 step 5) — captured at the one
point in the whole call graph where "which BEAM process is this?" is the exact fact
under test, independent of anything `wasmex`/Wasmtime does internally (the boundary
decision 0014 mandates is the **Elixir process** boundary `Task.Supervisor.async_nolink`
creates, not a property of the NIF call itself). The corresponding test captures the
test process's own pid before the call, invokes
`Letflow.Engine.PluginInterface.invoke(Letflow.Engine.Wasm.PluginHandler, context)`,
pattern-matches the returned `{:complete, %{"executed_in_pid" => handler_pid}}` shape,
and asserts `handler_pid != test_pid` while also asserting the test process itself is
still alive (`Process.alive?/1` on the captured test pid) — a positive check that no
exit signal reached the caller. This is the same technique the acceptance criterion itself names ("comparing `self()`
captured inside the handler against the test process pid") and requires no `wasmex`
internals, no `:sys.get_state/1` probing, and no timing dependency — it is a direct,
deterministic structural assertion.

---

## §5 — Hanging guest → supervised-task timeout → `{:error, reason}`

**Second fixture**, `priv/wasm_fixtures/req165_hang.wat`:

```wat
(module
  (func (export "hang")
    (loop $forever
      br $forever)))
```

An unconditional `br` back to the top of the loop, with `consume_fuel` left at its
documented default `false` (`req163-wasm-abi-choice.md`/decision 0014's own evidence
quotes `Wasmex.EngineConfig`'s `:consume_fuel` default), so nothing internal to
Wasmtime bounds this loop — it genuinely never returns on its own, which is the
precondition the acceptance criterion's word "hangs" requires (a fuel-bounded trap
would be a guest trap, not a hang, and is a different — already-covered by
`handle_yield_result`'s `{:exit, reason}` clause — code path).

**Mechanism under test:** `PluginInterface.invoke/3`'s existing `opts[:timeout_ms]`
path (`plugin_interface.ex:187-232`, unchanged): `Task.yield(task, timeout_ms)` returns
`nil` once `timeout_ms` elapses (regardless of whether the task's own body has
returned), and the `nil` clause of `handle_yield_result/4` runs
`Task.shutdown(task, :brutal_kill)` then returns `{:error, "plugin handler ... did not
respond within #{timeout_ms}ms"}`. This path is **entirely existing code** — REQ-165
adds no new timeout mechanism, per decision 0014's own instruction that guest
invocation reuses `PluginInterface.invoke/2,3` exactly as written.

**Why this genuinely proves the boundary bounds a hang, and not merely a fast guest
trap:** the test calls `PluginInterface.invoke(handler, context, timeout_ms: 100)` (a
short outer bound) while the handler's own `Wasmex.call_function/4` call passes no
`wasmex`-level timeout override (defaulting to `wasmex`'s documented 5-second
call-level timeout, per §3.2 step 3) — i.e. the *outer* task-level timeout fires first,
so the assertion exercises `PluginInterface`'s own mechanism, not `wasmex`'s internal
interrupt. (`wasmex`'s own interrupt, per its docs, would also eventually fire and
"keep the Store available for subsequent calls" — but that is a different, `wasmex`-
internal safety net decision 0014 (a)(iii) already credits separately, and is not what
this acceptance criterion is testing.)

The corresponding test builds an `ExecutionContext` pointed at the hang fixture, calls
`Letflow.Engine.PluginInterface.invoke/3` with `timeout_ms: 100`, pattern-matches the
result as `{:error, reason}`, and asserts `reason` contains the substring `"did not
respond within 100ms"` (the exact wording `handle_yield_result/4`'s `nil` clause
already produces, per `plugin_interface.ex`'s cited source). No `rescue`/`catch` appears
in this test, by design — the acceptance criterion's
"never as an exception or exit propagating into the calling process" is proven by the
test process being able to make ordinary assertions on an ordinary `{:error, _}` tuple
immediately afterward, not by having to guard against one.

**Residual note, carried from §0/decision 0014 (a), not papered over:** `Task.shutdown
(task, :brutal_kill)` terminates the **Task process**; whatever native thread Wasmtime
was using to run the guest's infinite loop is not itself guaranteed to stop the instant
the Elixir process is killed (this is the scheduler-blocking hazard OQ-5 names and
which this requirement does not resolve). What *is* guaranteed, and what this
requirement's acceptance criterion actually asks for, is that the **caller** sees
`{:error, reason}` promptly and correctly — the Wasmex GenServer instance the killed
Task process started is itself linked to that Task (via `Wasmex.start_link/1` called
from inside it), so the ordinary link-propagation semantics that terminate a linked,
non-trapping process on a non-`:normal` exit signal (here, `:killed`, propagated from
the brutally-killed Task) tear the orphaned Wasmex GenServer down too rather than
leaking it — a cleanup property worth stating, not a load-bearing part of the AC5 proof
itself.

---

## §6 — Confirmation: `lib/letflow/engine/plugin_interface.ex` needs no edit

Per decision 0014's Decision (2)/(4) and Reasoning (d) (both quoted in full at the top
of this file): `PluginInterface` stays in-process-Elixir-only; WASM plugins arrive as a
**separate handler family** — a `wasmex`-backed module implementing the existing
`@behaviour`, not a change to the contract. §3-§5 above confirm this concretely:
`Letflow.Engine.Wasm.PluginHandler` implements `@callback handle_node/1` exactly as
declared, and is dispatched exclusively through the **existing, unmodified**
`invoke/2,3`. No new `@callback`, no new field on `ExecutionContext`, no new clause in
`handle_yield_result/4` is needed or added.

**Files this requirement touches, for the `git diff --stat` check AC6 names:**
`mix.exs`, `mix.lock`, `.tool-versions`, `.github/workflows/ci.yml`,
`lib/mix/tasks/letflow.check_toolchain.ex`, `lib/letflow/engine/wasm/plugin_handler.ex`
(new), `priv/wasm_fixtures/req165_trivial.wat` (new), `priv/wasm_fixtures/
req165_hang.wat` (new), `test/letflow/engine/wasm/plugin_handler_test.exs` (new),
`lib/letflow/design/req165-wasmex-process-boundary.md` (this file),
`test/specs/REQ-165.md`. **`lib/letflow/engine/plugin_interface.ex` is absent from
this list** — ELIXIR-DEV's implementation commit(s) must show zero diff against that
path, confirmed the same way `req163`/`req164` confirmed their own out-of-scope-path
claims: `git diff --stat main...HEAD -- lib/letflow/engine/plugin_interface.ex`
producing no output.

---

## §7 — Moduledoc content

Both obligations below (WASM-01's mechanism restatement, and decision 0014 (a)'s
residual-risk disclosure) belong in `Letflow.Engine.Wasm.PluginHandler`'s own
`@moduledoc`, in the same terms `plugin_interface.ex`'s own moduledoc already uses for
its own disclosed-and-uncovered crash class (its "Does NOT cover" paragraph, quoted at
the top of this file's context and in `plugin_interface.ex:60-64`) — this is a
restatement in the same vocabulary, not a rewrite of that existing paragraph.

### 7.1 WASM-01 mechanism restatement (AC7)

Required moduledoc content, verbatim in substance (ELIXIR-DEV may adjust prose flow but
must preserve every factual clause below):

> This module restates WASM-01 (Wasmtime Integration). WASM-01's literal text requires
> the platform to "embed Wasmtime via its C API, linked statically into the platform
> binary." That mechanism clause is not satisfiable here: `wasmex` embeds Wasmtime
> through a **Rust NIF**, not the C API, and there is no "platform binary" to link
> statically into — the BEAM loads `wasmex`'s native library as a runtime-loaded shared
> library. WASM-01's own **acceptance criterion** — "No external Wasm runtime
> dependency at deploy time" — is met exactly as literally worded: Wasmtime is compiled
> into the NIF's shared library at build time and loaded in-process by the BEAM; no
> separate Wasmtime binary, daemon, or system package is installed, configured, or
> reached over any IPC/network boundary at deploy time. Only the mechanism clause is
> restated; the acceptance criterion is satisfied, not reinterpreted.

Corresponding test (deployment-check style, per AC7's "a test or deployment check
asserts no external Wasm runtime dependency is required at deploy time"): a test named
along the lines of "the wasmex NIF is a loaded shared library, not an external
process/dependency" that demonstrates the NIF is loaded in-process — e.g. an assertion
against whatever `wasmex` exposes for introspecting its own NIF load path (a
`:code.which/1`-style check on the loaded native module), or an assertion that no
`wasmtime`/`wasmer` binary, daemon, or system package is configured or reachable from
Letflow's own runtime configuration. This one test's exact mechanics are intentionally
left as an implementation detail —
see Open Questions §9 — because it depends on what `wasmex` v0.15.1 actually exposes
for NIF-load introspection, which was not verified against a compiled build in
producing this design per CLAUDE.md's "no speculation" rule; ELIXIR-DEV verifies this
by actually running it, not by this design guessing wasmex's introspection API.)

### 7.2 Residual native-crash risk disclosure (AC8)

Required moduledoc content, verbatim in substance, deliberately mirroring
`plugin_interface.ex`'s own "Does NOT cover" phrasing:

> **Residual risk — NOT covered by the process boundary.** Per decision 0014
> Reasoning (a): a Wasmtime- or NIF-layer crash inside a call this module makes does
> not raise, exit, or trap in the ordinary BEAM sense observable by
> `PluginInterface.invoke/2,3`'s `Task.yield/2` — it can crash the **entire BEAM node**,
> the same disclosed-and-uncovered class `Letflow.Engine.PluginInterface`'s own
> moduledoc already names for "a hard kill of the BEAM node itself, or
> `System.halt/0`": no monitor, task, or supervisor observes it from inside the same
> node, because supervision is a process-level mechanism and a NIF segfault is a
> process-level event only in the sense that the OS process *is* the node. The process
> boundary this module relies on (`Task.Supervisor.async_nolink/2` +
> `Task.yield/2` + `Task.shutdown(task, :brutal_kill)`) bounds **hangs and guest
> traps** — both observable as an ordinary task outcome (`nil` from `Task.yield/2`, or
> `{:exit, reason}` for a trap) — it does **not** bound a native crash. This is an
> accepted, stated limitation, not a gap this module papers over.

No test can assert this paragraph's substance by exercising an actual node crash
(doing so would crash the test run's own BEAM node); AC8 is satisfied by the
moduledoc text itself plus a `moduledoc =~ ...` string-content test, the same
technique `test/letflow/engine/lua/executor_test.exs:506`'s AC-5 moduledoc test already
uses for an analogous disclosure obligation.

---

## §8 — Traceability: REQ-165's 9 real acceptance criteria

| # | Acceptance criterion (verbatim, abbreviated) | Concrete design element |
|---|---|---|
| 1 | `wasmex` in `mix.exs`; `deps.get`+`compile` succeed with the **native build** succeeding, real output quoted; fetch alone insufficient | §1 (exact dep line, version-grounded); §0 (why a bare fetch could pass without building); §1's `WASMEX_BUILD=true` requirement for the proving run |
| 2 | Rust toolchain pinned by the same mechanism as 0005; CI installs it; CI config diff + real CI run shown | §2 in full: `.tool-versions` diff, version grounding (wasmex's own pin), `ci.yml` diff (Rust setup step + `WASMEX_BUILD` env), `letflow.check_toolchain` extension |
| 3 | Module implementing `@behaviour PluginInterface`; `handle_node/1` invokes a wasm guest; test asserts `{:complete, map}` for a trivial guest | §3 (module location/spec), §3.3 (trivial guest fixture), §4's test (asserts `{:complete, %{...}}`) |
| 4 | Test asserts guest invocation runs in a **different process** from the caller (`self()` comparison), proving the boundary structurally | §4 in full: `"executed_in_pid" => self()` mechanism + test |
| 5 | Test asserts a hanging guest is terminated by the supervised-task timeout, surfaces as `{:error, reason}`, never an exception/exit | §5 in full: hang fixture, mechanism (existing `handle_yield_result/4` `nil` clause), test |
| 6 | `plugin_interface.ex` unmodified, confirmed by `git diff --stat` | §6: reasoning (decision 0014 (d)) + exact file list this requirement touches, explicitly excluding that path |
| 7 | Moduledoc restates WASM-01's mechanism clause (Rust NIF, not C API; runtime-loaded shared lib, not static binary) while its AC is met as worded; test/deployment check asserts no external Wasm runtime dependency | §7.1: required moduledoc prose + deployment-style test (mechanics flagged as an open question, §9) |
| 8 | Moduledoc discloses decision 0014 (a)'s residual risk (native crash takes the node down, uncovered by the boundary), same terms as `PluginInterface`'s own disclosure | §7.2: required moduledoc prose, mirrors `plugin_interface.ex`'s "Does NOT cover" language |
| 9 | `mix test` and `mix compile --warnings-as-errors` both pass, real output quoted | Not a design element — an implementation/verification obligation for ELIXIR-DEV (and TEST-RUNNER); this design's §1/§3-§5 content is what those commands must compile and pass against |

(The doc's own 10th listed acceptance criterion — "design doc + test spec written to
the two named paths" — is satisfied by this file and `test/specs/REQ-165.md` existing
at those exact paths.)

---

## §9 — Open questions this design leaves for ELIXIR-DEV, stated rather than guessed

- **OQ-D1 — exact `wasmex` v0.15.1 API for asserting "no external Wasm runtime
  dependency" (§7.1).** Nothing was installed or run in producing this design (per
  CLAUDE.md's "no speculation" and this project's evidence discipline); the precise
  function/introspection point `wasmex` exposes (if any) for asserting the NIF is a
  loaded shared library with no external process dependency must be verified by
  actually compiling `wasmex` and inspecting what it loads (e.g. `:code.which/1` on the
  NIF module, or documentation of `Wasmex.Native`'s load path) — not assumed here.
- **OQ-D2 — precompiled-target availability for `ubuntu-latest`.** §0 states "likely"
  ships a precompiled NIF for Letflow's CI runner target; this was not confirmed
  against a real checksums manifest (the `wasmex` repo does not commit one at the paths
  checked — release-time-generated checksum files are typically attached to GitHub
  Releases, not the git tree). This does not change the design (§1's `WASMEX_BUILD=true`
  forces a real build regardless of precompiled availability either way), but ELIXIR-DEV
  should note in its own PR/handoff whether the unforced path would have used a
  precompiled artifact, for future maintainers' information.
- **OQ-D3 — `letflow.check_toolchain`'s new F9 failure-mode wording.** §2 specifies the
  behavior (never fails, warns on missing/unrunnable `rustc`) but leaves the exact
  warning string to ELIXIR-DEV, consistent with how F1-F8's existing wording is
  implementation detail this design does not dictate verbatim either.

None of these open questions block implementation — each names a concrete,
verifiable-at-build-time fact rather than an ambiguity in what to build.
