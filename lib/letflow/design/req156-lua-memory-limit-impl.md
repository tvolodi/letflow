# REQ-156 Design: Configurable Memory Limit for Lua Script Execution (LUA-09 restated)

**Requirement:** REQ-156 — Configurable memory limit, per REQ-149's decided mechanism
**Stage:** S5 (Scripting & plugins)
**Related:** REQ-149 (mechanism decision, `lib/letflow/design/req149-lua-memory-limit.md`),
REQ-154 (LUA-08 layer 1, in-band instruction budget), REQ-155 (LUA-10 layer 2, host
wall-clock kill, `lib/letflow/design/req155-lua-wallclock-kill.md`), decision 0014
(`docs/migration/decisions/0014-scripting-plugin-runtime-strategy.md`, OQ-1)
**Also owns:** `test/specs/REQ-156.md` (sibling test-spec skeleton)
**Gate:** SECURITY-REVIEWER is a hard gate (tenant-supplied script execution path).

**Acceptance-criterion mapping is in §8 below.**

---

## 1. LUA-09 Restatement — Why This Requirement Exists, and Which Clause It Meets

LUA-09 literal text: *"Each script execution MUST have a configurable memory limit.
Allocations exceeding the limit MUST fail gracefully and terminate the script."*
Acceptance: *"Script attempting to allocate 1 GB with 16 MB limit fails cleanly."*

LUA-09 has **two clauses**, and this requirement satisfies only one of them:

| Clause | Satisfied by this design? | Why |
|---|---|---|
| "**terminate the script**" | **YES** | `:max_heap_size` with `kill: true` (REQ-149 §3, empirically verified: exit reason `:killed`) gives a hard, unconditional allocation boundary — the BEAM scheduler kills the process the instant its heap exceeds the configured word count, with no cooperation from the running script. |
| "**fail gracefully**" (an in-script, `pcall`-observable allocation failure) | **NO** | There is no allocator hook in a pure-BEAM Lua VM (`tv-labs/lua`), and no allocation-failure exception exists for `pcall` to intercept. The BEAM kills the process before any Lua-level trap can fire. The script observes nothing; it simply stops running. This is not a gap this design can close without replacing the Lua runtime with one that has a custom allocator hook — REQ-149 §3 established this is not achievable, and decision 0014 named it "the weakest point of the Lua decision." |

**This requirement's moduledoc MUST state this table's content in those words** — not a
general claim that LUA-09 is "met." Per decision 0014: *"S5 must not mark LUA-09 met
without resolving it."* This design resolves it by stating plainly which half is real.

**`:max_instructions` is rejected as a memory proxy.** Decision 0014 OQ-1 states this
explicitly: *"approximate via `:max_instructions` (unsound — allocation is not
proportional to instruction count)."* A single Lua opcode can allocate an arbitrarily
large string (`string.rep("x", 1_000_000_000)`); conversely a tight arithmetic loop
allocates nothing while exhausting an instruction budget. No code path in this design
tightens `:max_instructions` in response to a memory concern, and the moduledoc must
state that this shortcut was considered and rejected, citing decision 0014 OQ-1 by name.

---

## 2. The Central Research Finding: `Task.Supervisor.async_nolink/2,3` Cannot Carry `spawn_opt`

This is the question the task brief called out as the one to answer honestly rather
than assume. It was answered by reading the actual Elixir standard-library source
installed in this environment — `/home/tvolodi/.asdf/installs/elixir/1.20.3-otp-29/lib/elixir/lib/task/supervisor.ex`
and `.../lib/elixir/lib/task/supervised.ex` — which is the exact Elixir version pinned
by this repo's `.tool-versions` (`elixir 1.20.3-otp-29`), not a doc-only inference.

**Finding, read directly from source, not assumed:**

- `Task.Supervisor.async_nolink/2,3`'s options type is declared as:
  `@type async_opts :: [shutdown: :brutal_kill | timeout()]` (`task/supervisor.ex`).
  **`:shutdown` is the only key this type accepts.** There is no `:spawn_opt` key, no
  `:max_heap_size` key, and no escape hatch to pass arbitrary spawn options through
  `async_nolink/2,3`.
- Tracing one level deeper, into what actually spawns the task's BEAM process
  (`task/supervised.ex`): `Task.Supervised.start_link/2` and `start_link/3` call bare
  `spawn_link/3` / `spawn/4` (the zero-options `Kernel` functions) — **not**
  `:erlang.spawn_opt/2,3`, and not `:proc_lib.spawn_opt/…` either. There is no options
  list anywhere in this call chain for a caller to inject into.

**Conclusion: `Task.Supervisor.async_nolink/2,3` structurally cannot be used to apply
`:max_heap_size` (or any other `spawn_opt` flag) to the task's process.** This is not a
missing feature that a keyword option would unlock from the outside — the process is
spawned via a hardcoded, options-free `spawn_link`/`spawn` call inside
`Task.Supervised`, a module this repo does not own and must not patch.

**Real alternative mechanism, specified honestly (no Task.Supervisor involved when a
memory limit is configured):** spawn the task's process directly via
`:erlang.spawn_opt/2` (Elixir: `Process.spawn/3`, which is a thin wrapper over the same
BIF), passing the option list `[:monitor, max_heap_size: %{size: max_heap_words, kill:
true, error_logger: false}]`. Since OTP 24, `:monitor` is a valid element of a
`spawn_opt` options list and causes the BIF to atomically return `{pid, monitor_ref}` —
this is the direct, race-free equivalent of "spawn, then `Process.monitor/1`," and
gives the same *unlinked-but-monitored* relationship between caller and task that
`Task.Supervisor.async_nolink/2` provides, without going through a `Task.Supervisor` at
all. §3 below specifies exactly how this composes with REQ-154's budget and REQ-155's
wall-clock kill.

This finding is empirical to the extent source-reading can be: no `mix run` was
performed for this design step (CODE-DESIGNER does not run code), but the conclusion
rests on reading the actual installed `task/supervisor.ex` and `task/supervised.ex`
source files rather than on documentation or memory of the API surface.

---

## 3. Configuration Shape — `max_heap_words`

Matches REQ-149 §3's configuration shape exactly.

| Element | Type / shape |
|---|---|
| Option key | `:max_heap_words` |
| Type | `pos_integer() \| nil` |
| Meaning of `nil` | Unconstrained — no `max_heap_size` spawn option is set at all for that invocation. A `nil` limit must **never** be translated into `%{size: nil}`; the key must be absent from the spawn-option list entirely when `max_heap_words` is `nil` (REQ-149 §3 states this explicitly). |
| Unit | Words, not bytes. To reach a byte-denominated limit (e.g. the "16 MB" LUA-09 names in its acceptance text), a caller/test must convert: `bytes = max_heap_words * word_size_bytes`, where `word_size_bytes` comes from `:erlang.system_info(:wordsize)` (typically 8 on a 64-bit BEAM) rather than a hardcoded `8` literal, so the conversion stays correct if this ever runs on a different word size. |
| Applied via | `max_heap_size: %{size: max_heap_words, kill: true, error_logger: false}` — identical shape to REQ-149 §3's recommendation. `error_logger: false` suppresses the BEAM's own crash-log noise for an expected, intentional kill (this repo's existing convention: REQ-155's `Task.shutdown(task, :brutal_kill)` is likewise a deliberate, expected kill, not a fault to be logged as one). |

### 3.1 Where `:max_heap_words` is threaded through

`opts` on `execute_with_manifest/3` (the explicit-opts overload REQ-154/REQ-155 already
established) gains one more required key, following the same convention as
`:max_instructions` and `:timeout_ms` — required at this arity, no default, so a test
can drive two different configured limits in the same run without round-tripping
through `Application.put_env/3` (this is exactly AC-1's own justification, restated
from REQ-154 §6/REQ-155 §3.2 for the new key):

| Key | Type | Required | Description |
|---|---|---|---|
| `:max_instructions` | `pos_integer()` | yes (REQ-154, unchanged) | In-band VM instruction budget. |
| `:timeout_ms` | `pos_integer()` | yes (REQ-155, unchanged) | Wall-clock timeout, milliseconds, enforced from outside the executing process. |
| `:max_heap_words` | `pos_integer() \| nil` | **yes, new in REQ-156** | Per-process heap word limit. `nil` = unconstrained. No hardcoded literal is permitted in the implementation — this is what AC-1's two-different-configured-limits test drives. |

### 3.2 `execute_with_manifest/2` (behaviour callback, unchanged arity)

Delegates to the 3-arity overload with all three defaults, exactly as REQ-155 added
`:timeout_ms` alongside REQ-154's `:max_instructions`:

| Element | Type / shape |
|---|---|
| `@impl` | `Letflow.Engine.LuaScriptAudit.Executor` (unchanged) |
| Params | `script_source :: binary()`, `registered_hash :: String.t()` |
| Guard | `when is_binary(script_source)` (unchanged) |
| Return | 6-arm union, §4 |

### 3.3 `default_max_heap_words/0` (new private helper, mirrors `default_budget/0` and `default_timeout_ms/0`)

| Element | Type / shape |
|---|---|
| `@spec` | `default_max_heap_words() :: pos_integer() \| nil` |
| Visibility | `defp` |
| Behavior | Reads `Application.fetch_env!(:letflow, :lua_max_heap_words)`. Called by the 2-arity callback before delegating to `/3`, parallel to `default_budget/0` and `default_timeout_ms/0`. The config value itself may be `nil` (production default: unconstrained) or a tuned `pos_integer()` — ELIXIR-DEV's choice, per OQ-1 below, following the same pattern REQ-154 §11/REQ-155 §11 OQ-1 already established for their own defaults. |

ELIXIR-DEV must add `config :letflow, lua_max_heap_words: <value>` to
`config/config.exs`, and, since AC-2's test needs a small limit to trigger the kill
quickly and deterministically, `config/test.exs` should set a materially small value
(or `nil`, if tests always drive an explicit small value via the 3-arity overload as
AC-1/AC-2 require) — following the identical precedent REQ-154 §6/§11 and REQ-155 §3.3
already set for `:lua_max_instructions` and `:lua_wallclock_timeout_ms`.

---

## 4. Return-Value Union — 6 Arms

The existing 5-arm union (REQ-153/154/155) gains exactly one new arm:

| Element | Type / shape |
|---|---|
| `@spec` (both arities) | `{:ok, %{manifest_hash: String.t()}} \| {:error, {:budget_exceeded, pos_integer()}} \| {:error, {:wallclock_timeout, pos_integer()}} \| {:error, :memory_limit_exceeded} \| {:error, String.t()} \| {:error, :invalid_script_ref}` |
| New arm | `{:error, :memory_limit_exceeded}` |

### 4.1 Distinguishability by pattern match (AC-3)

| Error | Pattern | Origin |
|---|---|---|
| Instruction budget exhaustion (REQ-154, layer 1) | `{:error, {:budget_exceeded, limit}}` | In-band `Lua.RuntimeException`, caught inside the task/process body |
| Wall-clock timeout (REQ-155, layer 2) | `{:error, {:wallclock_timeout, timeout_ms}}` | Out-of-band: no result observed within `timeout_ms`; the process is then killed by the caller |
| **Memory limit exceeded (REQ-156, this requirement)** | **`{:error, :memory_limit_exceeded}`** | Out-of-band: the BEAM's `max_heap_size` kill fired before the caller's own timeout or the task's own result arrived |
| Other runtime Lua error | `{:error, message}` where `message :: String.t()` | Unchanged |
| Non-binary script ref | `{:error, :invalid_script_ref}` | Unchanged |

All three resource-limit arms carry structurally distinct shapes — a 2-tuple with
`:budget_exceeded`, a 2-tuple with `:wallclock_timeout`, and a bare atom
`:memory_limit_exceeded` — so no pattern can confuse any two of them, and a single
`case`/`cond` in a test can match all three (and the other two arms) distinctly in one
assertion, which is exactly what AC-3 requires.

---

## 5. Mechanism: How `:max_heap_words` Wires Into REQ-155's Supervised Path

Because §2 established that `Task.Supervisor.async_nolink/2,3` cannot carry
`max_heap_size`, this design does not attempt to force it through that API. Instead,
`execute_with_manifest/3` branches on whether a memory limit is configured for that
call:

| `max_heap_words` value | Execution path used |
|---|---|
| `nil` | **Unchanged from REQ-155.** `Task.Supervisor.async_nolink(Letflow.Engine.Lua.TaskSupervisor, fn -> run_script(script_source, budget) end)`, then `Task.yield/2` bounded by `timeout_ms`, then `Task.shutdown(task, :brutal_kill)` on a `nil` yield — exactly REQ-155 §4.1–§4.3, byte-for-byte. |
| `pos_integer()` | **New path, this requirement.** The script body runs in a process started directly via `:erlang.spawn_opt/2` (not under `Letflow.Engine.Lua.TaskSupervisor`, and not via `Task` at all), monitored from the moment of spawn (the `:monitor` spawn option), with `max_heap_size: %{size: max_heap_words, kill: true, error_logger: false}` also set at spawn time. |

### 5.1 The new path's message protocol and outcome table

When `max_heap_words` is a `pos_integer()`, the spawned process's body is the same
script-evaluation logic REQ-154/155 already specify (`run_script/2`'s existing
`Lua.eval!/2` + `rescue` clauses, producing one of the same four in-band outcomes), with
one addition: on completion, the process sends its result back to the calling process
tagged with the monitor reference it was given (the same `{ref, reply}` shape
`Task.Supervised`'s own protocol uses internally, reused here deliberately for
symmetry — but implemented directly in this module's own code, not by borrowing
`Task`'s private message contract).

The calling process then waits for exactly one of four events, bounded by
`timeout_ms`, mirroring REQ-155 §4.3's table but with a new row inserted for the
memory-kill case:

| Event observed | Meaning | This function's return |
|---|---|---|
| `{ref, reply}` where `reply` is one of REQ-154's four existing in-band outcomes | Script completed, or failed in-band, within the timeout, without hitting the heap limit | That same shape, unchanged (e.g. `{:ok, %{manifest_hash: _}}`, `{:error, {:budget_exceeded, limit}}`) |
| `{:DOWN, ref, :process, pid, :killed}`, observed **before** the caller has issued its own kill | The BEAM's `max_heap_size` enforcement fired — this is the only actor that can deliver a `:killed` exit reason to this process before the caller's own timeout-triggered kill (§5.2) has been issued, because the process is unlinked and monitored by no one else | `{:error, :memory_limit_exceeded}` |
| `{:DOWN, ref, :process, pid, reason}` for any other `reason` | The process crashed for a reason neither the in-band `rescue` clauses nor the memory-kill case covers | `{:error, <descriptive string derived from the exit reason>}`, same formatting convention as REQ-155's `format_exit_reason/1` |
| Nothing observed within `timeout_ms` | Wall-clock timeout — REQ-155's case, now handled by this path's own bounded wait instead of `Task.yield/2` | The caller issues its own unconditional kill of the process (§5.2), then returns `{:error, {:wallclock_timeout, timeout_ms}}` |

### 5.2 The caller's own kill on timeout (this path's `Task.shutdown(:brutal_kill)` equivalent)

When the bounded wait in §5.1 expires with nothing observed, the caller kills the
process directly (the raw-process equivalent of `Task.shutdown(task, :brutal_kill)`) and
then drains the resulting `:DOWN` message before returning, exactly as REQ-155's
`handle_yield_result(nil, task, timeout_ms)` clause already does for the
`Task.Supervisor`-based path. This preserves REQ-155's core guarantee (§6 of that
design) unchanged for the memory-limited path too: the wall-clock bound is blind to
in-band script behavior and fires unconditionally regardless of what the script's own
`:max_instructions` handling did.

### 5.3 Why the ordering in §5.1's table resolves the apparent `:killed` ambiguity

Both a caller-issued kill (§5.2, on wall-clock timeout) and a BEAM-issued
`max_heap_size` kill produce the identical exit reason `:killed` on the resulting
`:DOWN` message — `:killed` is not, by itself, self-describing about *who* killed the
process. This design resolves the ambiguity structurally, not by inspecting the
reason: the caller only ever issues its own kill *after* its bounded wait has already
expired with nothing observed. Therefore any `:killed` `:DOWN` message the caller
receives **during** that bounded wait — i.e., before the caller has taken any killing
action of its own — cannot be attributed to the caller, because nothing else in this
design links to, monitors, or otherwise has standing to kill that process. It can only
be the BEAM's own `max_heap_size` enforcement. This is why §5.1's table lists the
memory-kill row as conditioned on "observed **before** the caller has issued its own
kill" rather than on inspecting the `:DOWN` reason atom alone.

### 5.4 What this path does NOT provide, relative to the `nil` path — stated as an explicit divergence

When `max_heap_words` is configured, the executing process is **not** a child of
`Letflow.Engine.Lua.TaskSupervisor` and does not appear in `Task.Supervisor.children/1`
on that supervisor. REQ-155 §9 AC-3 and its OQ-2 recommended `Task.Supervisor.children/1`
as the primary mechanism for a test to observe process death after a timeout — that
recommendation applies only to the `nil`-limit path. For the memory-limited path, no
equivalent supervisor-registry-based observability exists, because the process is
spawned directly rather than through any supervisor. This is not expected to block
REQ-156's own acceptance criteria (none of REQ-156's seven criteria ask for a
supervisor-registry-based liveness assertion — AC-2 only requires that the call
*returns a structured error rather than hanging*, which the return value itself already
evidences), but it is a real, stated difference in observability between the two code
paths and TEST-DESIGNER must not assume `Task.Supervisor.children/1` on
`Letflow.Engine.Lua.TaskSupervisor` reflects a memory-limited execution's process.

---

## 6. Divergence From REQ-149's Literal Recommendation — Assessment

**No divergence from REQ-149's recommended mechanism itself.** REQ-149 §3 recommends
"`:max_heap_size` on the script's executing process, with `kill: true`," "applied via
`spawn_opt(...)`" — this design implements exactly that: `:erlang.spawn_opt/2` with
`max_heap_size: %{size: max_heap_words, kill: true, error_logger: false}`, matching
REQ-149 §3's configuration shape verbatim (§3 above).

**What REQ-149 left unaddressed, which this design had to resolve:** REQ-149's
artefact recommends the mechanism in isolation and does not discuss how it composes
with REQ-155's already-merged `Task.Supervisor`-based execution path (REQ-149 predates
the need to compose with that path being worked out in detail; its Section 3 is silent
on `Task.Supervisor` entirely). §2 and §5 of this design fill that gap, and the finding
in §2 — that `Task.Supervisor.async_nolink/2,3` cannot carry `spawn_opt` at all — is new
information not present in REQ-149's artefact.

**Recommendation for `req149-lua-memory-limit.md`:** since this is a gap-fill rather
than a contradiction, REQ-149's artefact does not need correction, but a short addendum
noting "composition with REQ-155's `Task.Supervisor` path is resolved by
`req156-lua-memory-limit-impl.md` §2/§5; `Task.Supervisor.async_nolink/2,3` cannot carry
`spawn_opt`, so the memory-limited path bypasses `Task.Supervisor` entirely" would make
REQ-149's artefact self-contained for a future reader. This is offered as a
recommendation, not stated as a required divergence-correction under AC-4, because
AC-4 is triggered by an actual divergence from REQ-149's recommended mechanism, and
none exists here.

---

## 7. Required Moduledoc Content (for `executor.ex`)

The updated `@moduledoc` for `Letflow.Engine.Lua.Executor` must add, alongside the
existing REQ-153/154/155 sections, a REQ-156 section stating:

1. **LUA-09 restatement**, verbatim in substance to §1's table above: the requirement
   restates LUA-09, and states explicitly which of its two clauses ("fail gracefully" /
   "terminate the script") the shipped mechanism satisfies (terminate: yes) and which it
   does not (fail gracefully: no), citing REQ-149's empirical finding (exit reason
   `:killed`, no `pcall`-observable allocation-failure path in `tv-labs/lua`).
2. **`:max_instructions` rejected as a memory proxy**, citing decision 0014 OQ-1 by
   name and restating why (allocation is not proportional to instruction count).
3. **The `Task.Supervisor.async_nolink/2,3` finding from §2** — stated plainly, not
   silently resolved: `async_opts` accepts only `:shutdown`; `Task.Supervised` spawns via
   bare `spawn_link`/`spawn` with no options list; therefore the memory-limited path
   uses `:erlang.spawn_opt/2` directly instead of `Task.Supervisor`, for exactly the
   reason recorded here.
4. **The branching mechanism** (§5): `nil` limit → unchanged REQ-155 `Task.Supervisor`
   path; configured limit → direct `spawn_opt`/monitor path with its own timeout-bound
   wait and its own caller-issued kill, per §5.1–§5.3.
5. **The observability divergence** (§5.4): a memory-limited execution's process is not
   a `Letflow.Engine.Lua.TaskSupervisor` child and will not appear in
   `Task.Supervisor.children/1` on that supervisor.

---

## 8. Acceptance Criterion Mapping

REQ-156's 7 acceptance criteria, from `docs/requirements.yaml`, mapped to concrete
design elements:

| # | Acceptance criterion (paraphrased) | Concrete design element |
|---|---|---|
| 1 | Memory limit is configurable per execution (not hardcoded); a test drives two different configured limits and asserts the smaller halts an allocating script sooner, with real `mix test` output quoted | §3's `:max_heap_words` opt (required, no default in `/3`) and §3.3's `default_max_heap_words/0` reading `Application.fetch_env!(:letflow, :lua_max_heap_words)` for `/2`; no module attribute or literal constant used. Test spec item T1 |
| 2 | A test runs a script attempting a large allocation under a small configured limit and asserts termination with a structured error rather than hanging/exhausting the node/returning success — LUA-09's own acceptance, at the scale it names | §5.1's memory-kill row → `{:error, :memory_limit_exceeded}`; §3's word/byte conversion note so the test can size the limit to match LUA-09's "16 MB" example. Test spec item T2 |
| 3 | Memory-limit breach surfaces as a structured error distinguishable by pattern match from REQ-154's and REQ-155's errors, tested matching all three arms specifically | §4.1's distinguishability table — three structurally distinct shapes (`{:budget_exceeded, _}`, `{:wallclock_timeout, _}`, bare `:memory_limit_exceeded`). Test spec item T3 |
| 4 | Implemented mechanism is the one REQ-149 recommends; if it diverges, moduledoc names the divergence and REQ-149's artefact is updated | §6: no divergence from REQ-149's recommended mechanism (`:max_heap_size`, `kill: true`, `spawn_opt`-based); the composition detail with `Task.Supervisor` is new information REQ-149 was silent on, not a contradiction — a non-mandatory addendum is recommended for REQ-149's artefact |
| 5 | Moduledoc states this RESTATES LUA-09 and which of its two clauses is/is not satisfied, in those words | §1's table, §7 item 1 |
| 6 | No code path uses `:max_instructions` as a memory proxy; moduledoc states that shortcut was rejected per decision 0014 OQ-1 | §1's rejection statement, §7 item 2. This design's memory-limit path is entirely separate from the `:max_instructions`/`budget` opt — no shared code, no tightening of one to serve the other |
| 7 | `mix test` and `mix compile --warnings-as-errors` both pass with real output quoted | TEST-RUNNER step produces real output; this design's signatures and reused patterns (REQ-154/155's existing shapes) do not introduce anything that should fail either check on its own |

---

## 9. Cross-Module Dependencies and Invariants

| Module | Change required in REQ-156 |
|---|---|
| `Letflow.Engine.Lua.Executor` | Extend `execute_with_manifest/2,3` per §3–§5: add `:max_heap_words` opt, add `default_max_heap_words/0`, add the branching execution path (§5) alongside the unchanged `nil`-limit path, extend the return-value union (§4) |
| `Letflow.Application` | No change — `Letflow.Engine.Lua.TaskSupervisor` (added by REQ-155) is reused unchanged for the `nil`-limit path; the memory-limited path does not register under any supervisor (§5.4) |
| `Letflow.Engine.Lua.Sandbox` | No change — unaffected by this requirement, as it was by REQ-155 |
| Application config | New key `:letflow, :lua_max_heap_words` (`pos_integer() \| nil`), alongside REQ-154's `:lua_max_instructions` and REQ-155's `:lua_wallclock_timeout_ms` |

| Invariant | This module's role |
|---|---|
| Per-invocation isolation (LUA-EC-1, carried from REQ-153/154/155) | Maintained on both paths: each call still constructs a fresh sandbox inside a fresh process; no process or sandbox is reused across invocations |
| Memory-kill non-catchability (new, this requirement) | The `max_heap_size` kill is unconditional and delivered by the BEAM scheduler itself — no code path in this module, and no Lua-level construct, can intercept, delay, or cancel it |
| `:max_instructions` is never tightened as a memory proxy (decision 0014 OQ-1) | No code path in this design reads `max_heap_words` when computing or adjusting `max_instructions`, or vice versa; the two are independently configured and independently enforced |
| Two-layer wall-clock guarantee (REQ-155 §6) unchanged on the memory-limited path | §5.2's caller-issued kill on timeout is blind to in-band script behavior exactly as `Task.shutdown(:brutal_kill)` is on the `nil`-limit path |
| `is_binary` guard on tenant input path (ISS-0350, carried forward) | Unchanged — guard remains on both arities |

---

## 10. Open Questions

| ID | Question | Blocks |
|---|---|---|
| OQ-1 | The exact value for the production default `:lua_max_heap_words` (a `pos_integer()` word count, or `nil` for unconstrained) is ELIXIR-DEV's choice, documented in the config comment, following the same pattern REQ-154 §11 OQ-2 and REQ-155 §11 OQ-1 already established for their own defaults. A materially small value should be usable from `config/test.exs` or driven explicitly per-call so AC-1/AC-2's tests run quickly and deterministically. | REQ-156 implementation |
| OQ-2 | §5.4's observability divergence (no `Task.Supervisor.children/1` visibility for the memory-limited path) is judged non-blocking against REQ-156's own 7 acceptance criteria, since none require a supervisor-registry-based liveness assertion. If a later requirement (e.g. an operational dashboard) needs to enumerate in-flight memory-limited Lua executions, a new observability mechanism (e.g. a `Registry` entry, or a telemetry event on spawn) would need to be added then. Not designed here. | Not blocking — informational only |
| OQ-3 | Whether `req149-lua-memory-limit.md` should receive the non-mandatory addendum recommended in §6 is left to whoever next touches that document; this design does not require it as a precondition for REQ-156's own implementation. | Not blocking — informational only |
| OQ-4 | The relationship between a configured `:max_heap_words` and a configured `:max_instructions`/`:timeout_ms` is not itself validated by this design (e.g. no check that a script plausibly hits its heap limit before its instruction budget or wall-clock timeout under non-adversarial expectations) — mirrors REQ-155 §11 OQ-3's identical open question about `:max_instructions` vs. `:timeout_ms`. | Not blocking — informational only |
| OQ-5 | Whether `default_max_heap_words/0`, `default_budget/0`, and `default_timeout_ms/0` should be consolidated into one "default execution opts" helper is a stylistic choice left to ELIXIR-DEV — mirrors REQ-155 §11 OQ-4's identical open question. This design specifies three independent helpers for parity with the existing structure and does not mandate consolidation. | Not blocking — informational only |
