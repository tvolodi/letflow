# ISS-0697: injectable executable resolver for `mix letflow.check.test`'s test suite (removes real-PATH mutation)

## Problem (ISSUE-FIXER's diagnosis, restated for design scope — do not re-diagnose)

`test/mix/tasks/letflow_check_test_test.exs` intercepts `Mix.Tasks.Letflow.Check.Test`'s
subprocess resolution by mutating the real, OS-process-global `PATH` environment
variable via `System.put_env/2` (`activate_fake_bin_dir/2`, lines 199-219), restored in
`on_exit` (lines 117-125). The file is `async: false`, which only serializes this
file's own tests against each other — it does nothing to stop the many `async: true`
test modules running concurrently in the *same* OS process from resolving `bash`,
`mix`, `rustc`, `cygpath`, etc. against the mutated `PATH` while it is active. There
are two separate, non-atomic `System.find_executable("bash")` calls per test
(`activate_fake_bin_dir/2`'s own fail-fast check, then a second one moments later
inside `run_main_suite/0`, reached via real wall-clock work). This is a TOCTOU race on
process-global mutable state: when a concurrently-scheduled test wins the race between
the two calls, `run_main_suite/0` resolves the REAL `bash.exe` and genuinely execs
`scripts/test_parallel.sh` inside the outer suite run — reproduced twice, matching the
observed symptom of ~15 new `erl.exe` processes and 16 partitions freezing
simultaneously with zero Postgres-side blocking queries (connection-pool exhaustion
from nested uncoordinated `test_parallel.sh` invocations, not a DB lock).

This is a recurrence of the hazard class despite ISS-0171's already-applied,
independently-verified PATHEXT/separator fix — **that fix is correct, stays as-is, and
is not touched by this design.** ISS-0697 is a different mechanism (concurrency /
global-mutable-state) layered on top of it.

**Chosen direction (ISSUE-FIXER's recommendation (a)):** give
`Mix.Tasks.Letflow.Check.Test`'s subprocess-resolution points an injectable override
so the test suite never needs to mutate real `PATH` at all.

## Scope

**In scope:**
- `lib/mix/tasks/letflow.check.test.ex` — new resolver seam, three call sites rewired
  through it.
- `test/mix/tasks/letflow_check_test_test.exs` — stop mutating `PATH`; use the new
  seam instead.

**Out of scope, explicitly:**
- ISS-0171's PATHEXT/`;`-vs-`:` fix — unchanged, still correct, still needed for
  `install_fake_executable/4`'s own `.bat`-vs-POSIX-script generation (that part of
  the technique is about producing a *discoverable, executable* fake file per
  platform, which is orthogonal to *how* the module under test discovers it).
- `scripts/test_parallel.sh` itself — no change (see "Secondary hardening candidate"
  below for the one related, deliberately-deferred item).
- Any non-test caller of `Mix.Tasks.Letflow.Check.Test.run/1` — the resolver's default
  behavior is byte-for-byte identical to today's `System.find_executable/1` calls, so
  a real (non-test) invocation of `mix letflow.check.test` is unaffected.

## 1. The injectable-override mechanism

### Application env key

The resolver seam reads a single Application environment key,
`{:letflow, :check_test_executable_resolver}`, and falls back to the real
`System.find_executable/1` function whenever that key is absent.

- **Key:** `{:letflow, :check_test_executable_resolver}`.
- **Default (key absent):** falls back to the real `System.find_executable/1` — i.e. a real, non-test
  invocation of `mix letflow.check.test` behaves exactly as it does today, byte for
  byte. No behavior change for CI or any human/agent running the task for real.
- **Override value shape:** a 1-arity function, `executable_resolver :: (String.t() ->
  Path.t() | nil)` — same input/output contract as `System.find_executable/1` itself,
  so swapping one in for the other is a drop-in substitution at every call site with
  no branching logic needed at the call site.
- **Why Application env, not a `run/1` argument or a module attribute:** `run/1` is
  invoked by `Mix.Task`'s own dispatch (`@impl Mix.Task def run(_args)`) with a fixed
  arity Mix controls — there is no argv-based channel from a test process into a
  `mix letflow.check.test` invocation that would reach an ExUnit-internal fake. The
  private helper functions that actually call `System.find_executable/1`
  (`run_main_suite/0`, `resolve_native_path/1`, `stream_and_capture/2`) are not part
  of this module's public interface and must stay that way (see design doc convention
  elsewhere in this module — `find_partition_log_dir/1` etc. are also deliberately
  left `defp`). Application env is the standard, already-used-elsewhere-in-this-
  codebase seam for "test needs to override a real-world side-effecting lookup without
  changing the module's public call shape."
- **Why this closes the TOCTOU, not just relocates it:** the hazard specifically
  requires that *unrelated, concurrently-scheduled `async: true` tests* can influence
  what a `System.find_executable/1` call resolves to, because `PATH` is consulted by
  every subprocess-spawning callsite in the whole OS process, not just this module's.
  `Application.get_env(:letflow, :check_test_executable_resolver, ...)` is consulted
  **only** by the three call sites this design rewires — no other code in the
  repository reads this key (confirmed: it is newly introduced by this fix). An
  unrelated concurrent test that shells out to `rustc`, nested `mix test`, etc. never
  touches this key, so it can never race or be raced by it, regardless of BEAM
  scheduling. The residual risk — two tests *within this same file* stomping on each
  other's override — is unchanged from today, and unchanged in mitigation: the file
  stays `async: false`, which already fully serializes this file's own tests against
  each other (this was never the part of the hazard ISS-0697 identified).

## 2. Exact signature changes in `lib/mix/tasks/letflow.check.test.ex`

All changes are additive-or-substitutive to existing `defp` functions; the module's
public surface (`run/1`) is unchanged.

### New type

```elixir
@type executable_resolver :: (String.t() -> Path.t() | nil)
```
Placed near the module's other `@type` declarations (alongside `wasm_hang_location`
etc.), for documentation value — not otherwise referenced in a `@spec` return/param
position except the one new function below (Elixir doesn't require re-stating a type
alias in every consuming `@spec`, but do use `executable_resolver()` in
`resolve_executable/1`'s own doc comment for clarity).

### New private function — the single resolution seam

```elixir
@spec resolve_executable(String.t()) :: Path.t() | nil
defp resolve_executable(name)
```

Body contract (design only, no implementation code): first, look up the Application
environment value for the `:check_test_executable_resolver` key under the `:letflow`
application; when that key is unset, the lookup falls back to a default meaning "use
real executable resolution" — i.e. it behaves exactly as if `System.find_executable/1`
itself had been configured as the resolver. Second, invoke whichever resolver value was
obtained (real or overridden) with `name`, and pass its return value through unchanged
as this function's own result. This is
the **only** place in the module that may call `System.find_executable/1` directly
(enforced by convention/review, not by the compiler) — every other call site below
must go through `resolve_executable/1` instead.

### Changed call sites (replace `System.find_executable(...)` with `resolve_executable(...)`)

1. `run_main_suite/0`, current line 151:
   `bash = System.find_executable("bash")` → `bash = resolve_executable("bash")`.
   No other change to `run_main_suite/0`'s logic, error message, or control flow.
2. `resolve_native_path/1`, current line 204:
   `System.find_executable("cygpath")` → `resolve_executable("cygpath")`. No other
   change to this function's logic (the `File.exists?(dir)` fast-path above it, and
   the `System.cmd(cygpath, ["-w", dir])` call below it, are unchanged).
3. `stream_and_capture/2`, current line 752:
   `System.find_executable(cmd) || raise "executable not found: #{cmd}"` →
   `resolve_executable(cmd) || raise "executable not found: #{cmd}"`. This is the
   generic seam used for **every** subprocess this module spawns — `bash` (main
   suite), `mix` (wasm_hang discovery, per-test wasm_hang runs, lua_wallclock_race) —
   so rewiring this one call site is what makes the override cover the `mix`-fake
   cases too, not just `bash`.

No other function in this module calls `System.find_executable/1` (confirmed by
reading the file in full for this design) — these three sites are exhaustive.

## 3. Test file changes — PATH mutation REMOVED entirely (not kept as fallback)

**Decision: remove real-`PATH` mutation entirely.** Do not keep it as a fallback
alongside the new resolver.

Rationale: ISSUE-FIXER's diagnosis is explicit that the `PATH` mutation *is* the
hazard, not an incidental detail of how the fake was installed. Keeping it "as a
fallback" would mean the exact recursive-real-`bash`-spawn risk described in ISS-0697
remains live on any code path, host, or future edit that doesn't go through the new
resolver seam correctly — defeating the purpose of building the seam at all. A design
that leaves the actual hazard in place "just in case" is not a fix; the resolver seam
is a strict superset in capability (same fake-executable technique, same platform-
specific `.bat`/POSIX-script generation from `install_fake_executable/4`, zero loss of
test fidelity) with none of the global-mutable-state exposure. This is a clean,
single-commit cut — no transitional dual-path period.

### `setup` block (current lines 117-146)

Remove the `original_path = System.get_env("PATH")` capture and its `on_exit` restore
(current lines 118-125) entirely — nothing in the rewritten test touches real `PATH`,
so there is nothing to save/restore. `fixture_root`/`fake_bin_dir` setup (current
lines 127-145) is unchanged.

### `install_fake_executable/4` (current lines 161-191) — unchanged

This function's job (write a real, executable fake script file to `fake_bin_dir`,
`.bat`+companion-`type`-file on Windows per ISS-0171, `#!/bin/sh` script elsewhere) is
orthogonal to *how the module under test discovers that file*. It stays exactly as-is
— the fake files it produces are still what gets executed; only the discovery
mechanism (point 4 below) changes.

### `activate_fake_bin_dir/2` → renamed `install_executable_resolver/2`, rewritten body

Same call shape at every call site (`install_executable_resolver(fake_bin_dir,
["bash", "mix"])` — mechanical rename of all 10 existing call sites, argument list
unchanged), different internals:

```elixir
@spec install_executable_resolver(Path.t(), [String.t()]) :: :ok
defp install_executable_resolver(fake_bin_dir, names)
```

Contract:
1. For each `name` in `names`, compute the expected fake file path exactly as
   `install_fake_executable/4` wrote it (`Path.join(fake_bin_dir, "#{name}.bat")` on
   `{:win32, _}`, `Path.join(fake_bin_dir, name)` elsewhere) — this mirrors, not
   duplicates in a diverging way, the path-construction logic `install_fake_executable/4`
   already uses, since both must agree on where the fake landed.
2. Build a `name => fake_path` map from step 1, then store a resolver value under the
   `{:letflow, :check_test_executable_resolver}` Application env key: the stored
   resolver's contract is to look up the given name in that override map and return
   whatever is found there — `nil`/not-found for any name absent from the map.
   Deliberately **not** falling back to `System.find_executable(n)` for unmapped names
   within this closure — every name this module resolves (`"bash"`, `"mix"`, and
   potentially `"cygpath"` — see below) must be explicitly faked or the test is
   exercising an untested path; an unmapped name returning `nil` surfaces loudly (the
   module's own `stream_and_capture/2` raises `"executable not found: #{cmd}"`) rather
   than silently falling through to a real executable, which is the whole point of
   this fix.
3. Register test cleanup (via `on_exit/1`) that removes/resets the
   `{:letflow, :check_test_executable_resolver}` Application env override after each
   test — this key is newly introduced by this fix and has no legitimate non-test setter,
   so unconditional `delete_env` (not "restore prior value") is correct; there is no
   prior value to restore in any real invocation.
4. Fail-fast check, replacing the old PATH-search-based one: for each `name`, assert
   `File.exists?(overrides[name])` (or `File.regular?/1`) — this checks that
   `install_fake_executable/4` actually wrote the file `install_executable_resolver/2`
   expects it to have written, catching a wiring bug (e.g. a future edit to
   `install_fake_executable/4`'s naming convention that this function's own path
   construction in step 1 wasn't updated to match) *before* a real subprocess spawn
   attempt, same "fail fast and legibly, not via a multi-minute real-subprocess
   timeout" purpose the old check served — but now a pure local file-existence check,
   not an OS PATH search, so the entire PATHEXT/separator class of platform-dependent
   check-semantics this function used to need is gone; the underlying `.bat`-vs-POSIX
   naming logic ISS-0171 fixed is still exercised (by `install_fake_executable/4`
   itself, step 1's path construction, and by the fake actually running when
   `resolve_executable/1` returns its path to `Port.open({:spawn_executable, ...})`),
   just no longer through a `PATH`-search.

### `cygpath` — not currently faked; decide whether it needs to be

`resolve_native_path/1`'s `System.find_executable("cygpath")` call is on a path this
test file's existing tests do not appear to exercise directly (no `cygpath` reference
anywhere in the test file today) — it is reached only when `File.exists?(dir)` is
false for the partition-log directory, which the fixture tests avoid by writing
fixture logs under `System.tmp_dir!/0` in a form the native BEAM can already see.
**No new fake is required for `cygpath`** to complete this fix — `resolve_executable/1`
being wired at that call site means a *real* `mix letflow.check.test` run's `cygpath`
resolution is unaffected (default resolver = `System.find_executable/1`, same as
today), and no existing test exercises the override path there, so there is nothing
for `install_executable_resolver/2` to additionally fake. Flagged explicitly per this
design's "no silent resolution" rule: if a future test wants to cover
`resolve_native_path/1`'s `cygpath` branch under the fake regime, it must add
`"cygpath"` to that specific test's `install_executable_resolver(fake_bin_dir, [...])`
names list and an `install_fake_executable/4` call for it — not required by ISS-0697's
scope.

### Every `activate_fake_bin_dir(fake_bin_dir, ["bash", "mix"])` call site

Mechanical rename to `install_executable_resolver(fake_bin_dir, ["bash", "mix"])` at
all 10 current call sites (lines 682, 723, 775, 801, 821, 849, 880, 897, 914, 953 as
of this design's reading) — no argument-shape change.

### `use ExUnit.Case, async: false` — unchanged

Stays `async: false`. This was never the part of the hazard ISS-0697 identified (it
already correctly serializes this file's own tests against each other); the fix here
is about what state a test mutates (Application env scoped to a key only this module
reads, vs. process-global `PATH` every subprocess-spawning call in the OS process
reads), not about this file's own internal concurrency, which stays as-is.

## 4. Fail-fast guard — replaced, not removed

`activate_fake_bin_dir/2`'s line-204 fail-fast check (`System.find_executable(name)`
compared against `fake_bin_dir`) is **replaced** by
`install_executable_resolver/2`'s step 4 above (`File.exists?/1` against the expected
fake path) — see "3." for the full contract. It is not removed outright: a wiring bug
between `install_fake_executable/4`'s naming and `install_executable_resolver/2`'s
path construction is still a realistic failure mode worth catching before a real
subprocess spawn attempt, and a local file check is strictly cheaper and more
deterministic than the OS PATH search it replaces (no PATHEXT/separator semantics to
get right, no dependency on OS-level executable-search behavior at all).

## 5. Secondary hardening candidate — DEFERRED as a follow-up issue

**Decision: defer, do not fold into this fix.** `scripts/test_parallel.sh`'s Step 1.5
connection-budget clamp having no nested-invocation guard is a real, independently
worth-tracking hardening idea, but it defends against a *different* vector than the
one ISS-0697 actually diagnosed: this design's resolver seam makes it structurally
impossible for this test file's own fake-executable technique to ever resolve to the
real `bash`/`mix` (the override map only ever contains fake paths, with no
`System.find_executable` fallback for names it's asked to cover — see point 3, step
2), which closes ISS-0697's specific root cause completely. A nested-invocation guard
in `test_parallel.sh` itself would protect against a *different* accidental-recursion
vector (e.g. a future, unrelated bug that genuinely shells out to
`test_parallel.sh` from within a partition) — worth having as defense-in-depth, but
speculative relative to this issue's actual diagnosed mechanism, and touches a
different file (`scripts/test_parallel.sh`) with its own separate review surface.
ORCH should register a follow-up issue: *"scripts/test_parallel.sh Step 1.5: add a
nested-invocation guard (e.g. `LETFLOW_TEST_PARALLEL_RUNNING=1` env marker causing a
nested invocation to refuse/defer) as defense-in-depth against accidental recursive
invocation"* — not blocking ISS-0697's resolution.

## Acceptance criteria (for TEST-DESIGNER / TEST-RUNNER / CODE-DESIGN-VALIDATOR)

1. `lib/mix/tasks/letflow.check.test.ex` has exactly one place that calls
   `System.find_executable/1` directly (`resolve_executable/1` itself); the three
   call sites in point 2 above all go through `resolve_executable/1` instead.
2. A real (non-test) `mix letflow.check.test` invocation is behaviorally identical to
   today's — the `:check_test_executable_resolver` Application environment lookup under
   `:letflow` defaults to real resolution (equivalent to `System.find_executable/1`)
   when the key is unset, which it is in every non-test context.
3. `test/mix/tasks/letflow_check_test_test.exs` contains no `System.put_env("PATH", ...)`
   or `System.get_env("PATH")` call anywhere after this fix (grep-checkable) — the
   hazard mechanism is structurally gone from the file, not merely avoided by
   convention.
4. Every one of the file's existing test cases (the two "detects a real occurrence"
   cases, both hard-failure paths, the ordering rule, the wrapper-nonzero-with-logs-
   present failure-reporting path, the wasm_hang retry fixtures) passes unchanged in
   its assertions — only the fake-installation mechanism changes, not what each test
   proves. TEST-RUNNER must re-run this file in isolation and, separately, confirm
   (by code reading, since a full concurrent repro is exactly what this fix removes
   the need for) that no `async: true` test elsewhere can influence or be influenced
   by `Application.get_env(:letflow, :check_test_executable_resolver, ...)`.
5. `mix letflow.check.test` (the real, full parallel run) no longer shows any
   `test_parallel: partition logs in` line, new `/tmp/letflow_test_parallel.*`
   directory, or new `erl.exe`/`beam.smp` burst attributable to this test file when
   run as part of a full-suite `mix test`/`scripts/test_parallel.sh` invocation —
   this is the actual regression-closing check for ISS-0697's reported symptom, best
   verified by TEST-RUNNER on a Windows host per the original report.

## Open questions

None left unresolved for ELIXIR-DEV to guess at. The one place this design
deliberately narrows scope (not adding a `cygpath` fake) is stated explicitly in "3."
above with its own rationale, not silently skipped.
