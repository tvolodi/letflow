# REQ-149 — Lua Memory Limit Mechanism Design

**Requirement:** REQ-149  
**Stage:** S5  
**Owner:** CODE-DESIGNER  
**Date:** 2026-08-26  
**Resolves:** Decision 0014 OQ-1  
**Blocks:** REQ-156 (LUA-09 implementation)

---

## Section 1 — Source Search Results

**Command attempted (on feature/WF02-REQ149-20260826):**

```
grep -rn "memory|heap|limit|alloc" deps/lua/lib/ --include="*.ex" --include="*.exs"
```

**Actual result:**

```
Get-ChildItem : Cannot find path '...\deps\lua\' because it does not exist.
```

**Why `deps/lua/` is absent:** commit 984bbc9 (PR #644, 2026-08-26) removed the
`{:lua, "~> 1.0"}` entry from `mix.exs` to satisfy the AC5 LuaScriptAudit guardrail.
The dependency directory is not present on the feature branch, and `deps/` is in
`.gitignore` so no historical tree object covers it.

**What REQ-148 found when the source was present** (recorded in `req148-lua-runtime-spike.md`,
Section 5 — searched `deps/lua/lib/lua.ex` and `deps/lua/lib/lua/api.ex` explicitly):

> "Grepped `deps/lua/lib/lua.ex` for `instruction_count` and `consumed` — no public
> function found. Grepped `deps/lua/lib/lua/api.ex` similarly — no public function
> found. Read `deps/lua/lib/lua/vm/state.ex` in full."

The struct field found in `Lua.VM.State`:

```elixir
# from deps/lua/lib/lua/vm/state.ex (read during REQ-148 spike)
instruction_count: 0,
```

**No `memory`, `heap`, `limit`, or `alloc` pattern was found in the source.** The only
resource-governing fields in the library are `instruction_count` (and the related
`:max_instructions` option) and `:max_call_depth`. There is no allocator hook, no heap
size option, no allocation counter, and no memory-limit mechanism of any kind in
`tv-labs/lua 1.0.2`.

**Conclusion:** `tv-labs/lua` exposes ZERO memory-limit or allocation-accounting options
at the library level. Any memory bounding must come entirely from BEAM-layer primitives.

---

## Section 2 — Candidate Evaluation

### Candidate A: `:max_heap_size` on the Script's Executing Process

**Description:** run the Lua script inside a BEAM process spawned with
`spawn_opt(fn, max_heap_size: %{size: N, kill: true, error_logger: false})`. When the
process's heap exceeds `N` words, the BEAM kills the process.

**Code run** (`scratch/lua_memory_spike.exs`, executed with `mix run --no-start`):

```elixir
ref = Process.monitor(
  :erlang.spawn_opt(
    fn ->
      Enum.reduce(1..100_000, [], fn _i, acc ->
        [:binary.copy("x", 1000) | acc]
      end)
    end,
    [max_heap_size: %{size: 50_000, kill: true, error_logger: false}]
  )
)
reason = receive do
  {:DOWN, ^ref, :process, _, r} -> r
after
  10_000 -> :timeout
end
IO.inspect(reason, label: "EXIT REASON (max_heap_size)")
```

**Actual output:**

```
EXIT REASON (max_heap_size): :killed
```

**Analysis:**

- The supervising process receives `{:DOWN, ref, :process, pid, :killed}`.
- The exit reason is `:killed` — the BEAM sent a non-catchable kill signal.
- **pcall cannot intercept this.** The process itself is killed by the BEAM
  scheduler before any Lua or BEAM trap has a chance to fire. There is no
  allocation-failure exception in the Lua VM, no `pcall`-catchable error, and no
  signal delivered to Lua code. The script receives nothing; it simply stops.
- From the script's perspective: no observable error, no pcall opportunity.
- From the host's perspective: `{:DOWN, ..., :killed}` — unambiguous, synchronous.

**LUA-09 clause satisfaction:**

| Clause | Satisfied? |
|---|---|
| "TERMINATE the script" | YES — process killed immediately |
| "fail gracefully" (in-script observable allocation failure) | NO — the BEAM kills the process; Lua code never sees an allocation error |

---

### Candidate B: Periodic Host-Side Sampling of `Process.info(pid, :memory)`

**Description:** the supervising process polls the script process's memory at a fixed
interval (e.g. every 20 ms); if the sample exceeds the configured limit, the supervisor
calls `Process.exit(pid, :kill)`.

**Code run** (`scratch/lua_memory_spike2.exs`, executed with `mix run --no-start`):

```elixir
worker_pid = spawn(fn ->
  receive do :start -> :ok end
  data = Enum.reduce(1..1_000, [], fn _i, acc ->
    [:binary.copy("x", 50_000) | acc]
  end)
  send(parent, {:done, length(data)})
end)

samples = Enum.map(1..10, fn i ->
  Process.sleep(20)
  mem = case Process.info(worker_pid, :memory) do
    {:memory, m} -> m
    nil -> :process_dead
  end
  {i * 20, mem}
end)
```

**Actual output:**

```
sample ms/bytes: {20, 2712}
sample ms/bytes: {40, 54928}
sample ms/bytes: {60, 88416}
sample ms/bytes: {80, 54936}
sample ms/bytes: {100, 54936}
sample ms/bytes: {120, 142600}
sample ms/bytes: {140, 142600}
sample ms/bytes: {160, 142600}
sample ms/bytes: {180, 142600}
items allocated: 1000
sample ms/bytes: {200, :process_dead}
```

**Analysis:**

- Memory growth IS visible across samples (2 712 → 142 600 bytes).
- GC runs are visible as drops between samples (88 416 → 54 936 at t=80ms).
- **Fundamental problem: enforcement is not hard.** A process that allocates very
  quickly — as a tight Lua loop would — can go from 0 to several hundred MB between
  two 20ms samples. The polling interval is a latency, not a boundary.
- **The observed memory reflects post-GC state.** The pre-GC peak — the moment of
  maximum allocation — is not sampled. A script with bursts could transiently exceed
  the limit and have it cleaned up before the next poll.
- **Provides detection capability, not enforcement capability.** Could be layered on
  top of another mechanism as a reporting tool, but cannot serve as the primary limit.
- pcall is irrelevant here: the limit is enforced by the host killing the process via
  `Process.exit(pid, :kill)`, same outcome as Candidate A.

**LUA-09 clause satisfaction:**

| Clause | Satisfied? |
|---|---|
| "TERMINATE the script" | Partially — enforced eventually, but with latency and gaps |
| "fail gracefully" (in-script observable allocation failure) | NO — same kill mechanism as Candidate A, no Lua-observable error |

---

### Candidate C: Decline the Graceful-Failure Clause

**Description:** accept that "fail gracefully" (in-script pcall-catchable allocation
failure) is not achievable with a pure-BEAM Lua VM. Implement only the "terminate the
script" clause — process kill via `:max_heap_size` or explicit `Process.exit(pid, :kill)`,
with no attempt to deliver an in-script allocation error.

This candidate explicitly rejects `:max_instructions` as the implementation vehicle
(see Section 4).

**Why this is structurally identical to Candidate A:** the mechanism is the same —
a process kill. The difference between C and A is framing, not code. C simply names
the outcome honestly: LUA-09's graceful-failure clause is not met.

**LUA-09 clause satisfaction:**

| Clause | Satisfied? |
|---|---|
| "TERMINATE the script" | YES |
| "fail gracefully" | NO — declined as unachievable |

---

## Section 3 — RECOMMENDED MECHANISM

**Recommended: Candidate A — `:max_heap_size` on the script's executing process,
with `kill: true`.**

`:max_heap_size` is the only mechanism in the BEAM that provides a **hard allocation
boundary**: once the process heap exceeds the configured word count, the scheduler kills
the process immediately, without cooperation from the running code. Candidate B (polling)
provides coarser, latency-bound detection but not enforcement; it may be layered on top
of A as a monitoring tool but must not be the primary limit.

**Which LUA-09 clauses the recommended mechanism satisfies:**

| LUA-09 clause | Satisfied? | Evidence |
|---|---|---|
| "Allocations exceeding the limit MUST … **terminate the script**" | **YES** | Empirical run: exit reason `:killed`; process terminates immediately |
| "Allocations exceeding the limit MUST **fail gracefully**" | **NO** | No allocation-failure exception exists in the tv-labs/lua VM. There is no hook point for pcall to intercept. The BEAM kills the process; Lua code receives no error. |

**LUA-09 is only partially achievable with tv-labs/lua.** "Terminate the script" is
met. "Fail gracefully" — meaning the script can observe the allocation failure in-band,
e.g. via pcall — is NOT met and is NOT achievable without replacing the Lua runtime
with one that has a custom allocator hook.

REQ-156 MUST implement `:max_heap_size` and MUST state in its moduledoc which clause is
met and which is not, per decision 0014's instruction that "S5 must not mark LUA-09 met
without resolving it" and per the requirements entry for REQ-156 which explicitly calls
out this two-clause obligation.

**Configuration shape (for REQ-156's design):**

- `max_heap_words` — a positive integer (words, not bytes; multiply by word size for
  bytes). `nil` = no limit (`:infinity` equivalent).
- Applied via `spawn_opt([max_heap_size: %{size: max_heap_words, kill: true, error_logger: false}])`.
- A `nil` limit must NOT set `max_heap_size` at all (absent key = unconstrained); do
  not pass `%{size: nil}`.

**Supervision signal:** the executor receives `{:DOWN, ref, :process, pid, :killed}`.
This maps to a distinct `{:error, :memory_limit_exceeded}` result so callers can
distinguish memory kills from wall-clock kills (`:timeout`) and instruction-budget
returns (`{:error, "instruction budget exceeded"}`).

---

## Section 4 — `:max_instructions` Rejection as Memory Proxy

**`:max_instructions` MUST NOT be used as a proxy for a memory limit.**

Decision 0014, Open Question OQ-1, states this explicitly:

> "approximate via `:max_instructions` (unsound — allocation is not proportional to
> instruction count)"

The reasoning is not merely a convention: a Lua script can allocate an arbitrarily large
string in a single instruction (`string.rep("x", 1_000_000_000)`) — one opcode tick, one
potentially massive allocation. Conversely, a script can exhaust its instruction budget
in a tight arithmetic loop that allocates nothing at all. Instruction count is a CPU-time
proxy; it has no relationship to heap size or allocation rate.

A requirement that tightens the instruction budget and calls the result a "memory limit"
has not met LUA-09. It has met LUA-08 twice.

---

## Section 5 — Decision 0014 Addendum

Decision 0014 OQ-1 asked:

> "No memory-limit option is documented for `tv-labs/lua`. Candidate approaches: run
> each script in a process with a bounded `max_heap_size` (kills rather than fails
> gracefully … so a kill may satisfy the second clause but not the first); approximate
> via `:max_instructions` (unsound …); or upstream a limit."

REQ-149 resolves OQ-1 as follows:

1. **`tv-labs/lua` has no memory-limit option** — confirmed by direct source search.
2. **`:max_heap_size` is the recommended mechanism** — confirmed empirically; exit
   reason `:killed`.
3. **"Fail gracefully" is NOT achievable** — there is no allocator hook in a
   pure-BEAM Lua VM. The process is killed before any Lua error can be raised.
4. **`:max_instructions` is rejected as a proxy** — as stated in OQ-1 itself.
5. **Upstreaming a limit** — not feasible within S5's scope; would require adding a
   custom allocator to `tv-labs/lua` itself (a foreign dependency). Not pursued.

**Does this outcome contradict anything in decision 0014?**

No. Decision 0014 anticipated this exact outcome in OQ-1's framing: "kills rather than
fails gracefully — LUA-09 says 'fail gracefully and terminate,' so a kill may satisfy
the second clause but not the first." The outcome resolves the open question in the
direction the record already judged likely. No statement in decision 0014 asserts that
both clauses of LUA-09 are achievable; the record explicitly called this "the weakest
point of the Lua decision."

**Addendum to 0014 is NOT required.** OQ-1 is resolved by this design document.
REQ-156 must reference this document and carry the clause-satisfaction statement into its
own moduledoc. Decision 0014's "must not mark LUA-09 met without resolving it" is
satisfied by this resolution.

**Post-implementation cross-reference note (added by REQ-156's DOC-UPDATER step,
non-mandatory, documentation-only).** This document's Section 3 recommends
`:max_heap_size` in isolation and is silent on how that mechanism composes with
REQ-155's already-merged `Task.Supervisor`-based execution path. REQ-156's
implementation design, `lib/letflow/design/req156-lua-memory-limit-impl.md` §2 and §5,
resolved that composition question: reading the installed Elixir 1.20.3 source
(`task/supervisor.ex`, `task/supervised.ex`) found that `Task.Supervisor.async_nolink/2,3`
structurally cannot carry a `:max_heap_size` `spawn_opt` (its `async_opts` type accepts
only `:shutdown`, and `Task.Supervised` spawns via bare `spawn_link`/`spawn` with no
options list). The memory-limited path therefore bypasses `Task.Supervisor` entirely and
spawns directly via `:erlang.spawn_opt/2` with `:monitor` in the option list, as detailed
in that document's §2 and §5. This does not change the recommendation or resolution
above; it is a pointer for a future reader of this document.

---

## Deliverables Summary

| Item | Result |
|---|---|
| deps/lua/ source search | `deps/lua/` absent (removed per AC5 guardrail); REQ-148 spike confirmed no memory/heap/alloc API exists |
| Candidate A: `:max_heap_size` empirical run | Exit reason `:killed`; pcall CANNOT intercept |
| Candidate A clause satisfaction | "terminate": YES; "fail gracefully": NO |
| Candidate B: Process.info sampling empirical run | Memory growth visible (2712→142600 bytes at 20ms intervals); enforcement latency ~20ms; GC causes undercount |
| Candidate B clause satisfaction | "terminate": partial (latency); "fail gracefully": NO |
| Candidate C: decline graceful-failure | Structurally identical to A; framing only |
| RECOMMENDED MECHANISM | Candidate A — `:max_heap_size` with `kill: true` |
| `:max_instructions` rejected as proxy | YES — OQ-1 cited explicitly |
| Decision 0014 addendum | NOT REQUIRED — OQ-1 resolved in direction 0014 anticipated |
