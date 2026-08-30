# ISS-0377 regression-test evidence (WF-03 Step 4)

Branch: `feature/WF03-ISS0377-20260830`. Fix commit: `8eef01b`
(`fix(ISS-0377): cross-platform AC7 assertions + parallel-partition build
isolation`), parent (pre-fix) commit: `64eef56`.

This fix is to **existing** test-suite behavior in
`test/letflow/engine/wasm/plugin_handler_test.exs` (AC7's two assertions) and
`scripts/test_parallel.sh` (partition build-path isolation) -- not a new
module -- so the plain fail-then-pass rule from
`docs/agents/workflows/WF-03_issue_resolving.md` Step 4 applies (not the
"code under test does not exist" mutation-only carve-out).

## Part A -- `plugin_handler_test.exs` AC7 assertions

AC7 has two tests. Each needed a different proof technique.

### A.1 -- "Wasmex.Native resolves to a compiled .beam..." (`:external_resource` assertion)

This is a **real, non-simulated, fail-then-pass run on this Linux sandbox** --
no Windows simulation needed, because this host's wasmex install is a
precompiled build with an **empty** `:external_resource` list, which is
exactly the case the OLD code never handled (it had no branch for the empty
case at all).

Procedure:

1. Confirmed clean tree: `git status --porcelain` empty.
2. Temporarily replaced `test/letflow/engine/wasm/plugin_handler_test.exs`
   with the pre-fix version (`git show 8eef01b^:test/letflow/engine/wasm/plugin_handler_test.exs`).
3. Ran `MIX_ENV=test mix test test/letflow/engine/wasm/plugin_handler_test.exs --seed 0`.
4. **Result: 9/10 passed, 1 failed** --

   ```
   1) test AC7: the wasmex NIF is a loaded shared library, not an external process Wasmex.Native resolves to a compiled .beam built from Rust NIF sources (Letflow.Engine.Wasm.PluginHandlerTest)
      test/letflow/engine/wasm/plugin_handler_test.exs:180
      expected Wasmex.Native's external_resource attributes to name its Rust NIF sources
      code: assert Enum.any?(external_resources, &String.contains?(&1, "native/wasmex/src/")),
      stacktrace:
        test/letflow/engine/wasm/plugin_handler_test.exs:189: (test)
   ...
   Result: 9/10 passed, 4 excluded
   Failed: 1 test
   ```

5. Reverted: `git checkout -- test/letflow/engine/wasm/plugin_handler_test.exs`.
6. Verified revert: `git status --porcelain` empty; re-ran the same command
   on the restored (post-fix) file --

   ```
   Running ExUnit with seed: 0, max_cases: 16
   Excluding tags: [:keycloak, :wasm_hang]
   ..........
   Finished in 0.2 seconds (0.00s async, 0.2s sync)
   Result: 10 passed, 4 excluded
   ```

**Conclusion:** pre-fix code fails this exact assertion on this real host
(empty `:external_resource` from a precompiled wasmex build, an outcome the
OLD code had no fallback for); post-fix code passes. This is not a simulation
-- it is the literal bug, reproduced live.

### A.2 -- "the compiled NIF shared library is bundled inside wasmex's own priv/..." (hardcoded `.so` path)

This assertion's bug (hardcoded `Path.join(priv_dir, "native/wasmex.so")`)
only manifests on a non-Unix OS -- on this Linux sandbox a real `wasmex.so`
is always present regardless of whether the fix is applied, so a live run of
the pre-fix code against the real `:code.priv_dir(:wasmex)` tree cannot
demonstrate the bug. Per the Step-4 handoff's explicitly-sanctioned
alternative, this is proven via a **simulated Windows-shaped directory tree**
exercising the exact shipped logic.

Fixture: a temp directory `<tmp>/native/` containing only
`libwasmex-v0.15.1-nif-2.15-x86_64-pc-windows-msvc.dll` (no fixed-name
`wasmex.so`/`wasmex.dll`) -- the real shape wasmex's build output has before
any fixed-name copy step, on any OS.

- **OLD logic** (verbatim from `git show 8eef01b^:test/letflow/engine/wasm/plugin_handler_test.exs`):
  `so_path = Path.join(priv_dir, "native/wasmex.so")`; `File.exists?(so_path)`
  → **`false`** against the fixture → the OLD test would `flunk`/fail its
  `assert File.exists?(so_path)`.
- **NEW logic** (verbatim `native_artifact_check/2` from the post-fix file,
  commit `8eef01b`), called with `ext = ".dll"` (simulating what
  `expected_native_extension/0` returns for `{:win32, _}` -- `:os.type/0`
  itself cannot be faked on this sandbox, but `ext` is the *only*
  OS-dependent input to `native_artifact_check/2`, so passing it directly
  exercises the real, unmodified directory-walking logic):
  → **`{:ok, :fallback_listing, native_dir}`** — passes.

This exact comparison is now a **permanent, committed regression test**:
`test/letflow/engine/wasm/plugin_handler_ac7_cross_platform_regression_test.exs`.
It builds the same fixture in a real temp directory (`setup`/`on_exit`), runs
the OLD hardcoded check (asserting it is unsatisfiable against the fixture)
and the NEW `native_artifact_check/2` (copied verbatim, with attribution) in
the same run, both asserting the expected outcome. Verified green:

```
$ MIX_ENV=test mix test test/letflow/engine/wasm/plugin_handler_ac7_cross_platform_regression_test.exs --seed 0
Running ExUnit with seed: 0, max_cases: 16
Excluding tags: [:keycloak, :wasm_hang]
..
Finished in 0.04 seconds (0.04s async, 0.00s sync)
Result: 2 passed
```

A throwaway `elixir` script version of the same comparison (not committed,
scratch-only) was run first to sanity-check the logic before turning it into
a committed test:

```
OLD hardcoded check: File.exists?(.../win_priv/native/wasmex.so) = false
OLD: FAILS -- flunks on this Windows-shaped tree (only a .dll present, no wasmex.so)
NEW native_artifact_check(priv_dir, ".dll") = {:ok, :fallback_listing, ".../win_priv/native"}
NEW: PASSES -- fallback directory listing finds the .dll entry

OK: OLD fails / NEW passes against the simulated Windows-shaped tree, as expected.
```

### Mutation revert verification (Part A)

The only permanent-file mutation performed was the temporary full-file swap
of `test/letflow/engine/wasm/plugin_handler_test.exs` to its pre-fix content
in step A.1, immediately reverted via `git checkout --`. Verified:

- `git status --porcelain` — empty, both immediately after the revert and at
  the end of this run.
- `mix test test/letflow/engine/wasm/plugin_handler_test.exs --seed 0` on the
  restored file — green, `Result: 10 passed, 4 excluded` (quoted above).

No other committed file was mutated for Part A; the Windows-tree simulation
(A.2) never touched a committed file at all -- it ran against a scratch temp
directory and, for the permanent test, its own freshly created-and-removed
`setup`/`on_exit` fixture directory.

## Part B -- `scripts/test_parallel.sh` per-partition build isolation

The bug this fixes (partitions racing on one shared `_build/test` tree,
hard-failing on Windows/NTFS hard-link permission errors, tolerated-but-real
on POSIX) is an inherent race that cannot be reliably forced to reproduce
even on Linux. Per REVIEWER's own investigation (recorded in the Step 4
handoff), the actual mechanism eliminated by the fix is that each partition
now gets a distinct `Mix.Sync.Lock` key, because that key is derived from
`MIX_BUILD_PATH`. The strongest available proof is therefore the **direct,
structural confirmation that each partition's `mix test` subprocess actually
receives a distinct `MIX_BUILD_PATH`** -- not an attempt to force the race.

### Procedure

A shim `mix` executable was placed earlier on `$PATH` than the real `mix`
(found via `command -v mix`). It records `MIX_TEST_PARTITION` and
`MIX_BUILD_PATH` as *actually received* by each invocation (via `flock`ed
append to a log file) before `exec`ing the real `mix` with the same
arguments and environment untouched. This observes the real environment
each subprocess receives -- it does not infer it from reading the script's
source.

```bash
export PATH="<scratch>/shimbin:$HOME/.asdf/shims:$PATH"   # shim first
TEST_PARALLEL_N=2 bash scripts/test_parallel.sh test/letflow/engine/wasm/plugin_handler_test.exs
```

Observed log (`mix_build_path_observed.log`), one line per real `mix`
invocation:

```
pid=924946 MIX_TEST_PARTITION=<unset> MIX_BUILD_PATH=<unset>
pid=925250 MIX_TEST_PARTITION=2 MIX_BUILD_PATH=_build/test-partition-2
pid=925249 MIX_TEST_PARTITION=1 MIX_BUILD_PATH=_build/test-partition-1
```

The first line is Step 1's single pre-compile (`MIX_ENV=test mix compile`,
correctly unset/shared, as designed -- AC5). The two partition lines
(`MIX_TEST_PARTITION=1`/`MIX_BUILD_PATH=_build/test-partition-1` and
`MIX_TEST_PARTITION=2`/`MIX_BUILD_PATH=_build/test-partition-2`) confirm each
partition's `mix test` subprocess genuinely receives a distinct
`MIX_BUILD_PATH`, eliminating the shared-path lock-key collision by
construction.

Additionally confirmed each partition's build path is a genuinely distinct
filesystem tree (not e.g. a symlink or shared inode by accident), via inode
comparison after the same run:

```
$ stat -c '%i %n' _build/test/lib/letflow/ebin _build/test-partition-1/lib/letflow/ebin _build/test-partition-2/lib/letflow/ebin
5367075 _build/test/lib/letflow/ebin
5373759 _build/test-partition-1/lib/letflow/ebin
5373837 _build/test-partition-2/lib/letflow/ebin
```

Three distinct inode numbers -- `cp -al`'s hardlink-preserving copy produced
three genuinely separate directory trees (hardlinked *file* content is
expected and fine; what matters is each partition has its own directory
entries and its own `Mix.Sync.Lock`-relevant path).

(Aside, not a regression concern: partition 2 in this N=2 probe run reported
"Paths given to `mix test` did not match any directory/file" because the
probe restricted both partitions to a single test *file*, which Mix's
`--partitions` file-hashing assigned entirely to partition 1 -- an artifact
of using a 1-file filter with N=2 partitions for a quick probe, unrelated to
ISS-0377's build-isolation fix. The build-path isolation itself is
unaffected and is what this section verifies.)

### Fail-then-pass framing for Part B

`scripts/test_parallel.sh` has no unit-testable Elixir surface (per the
design doc's Part C note; confirmed no existing shellcheck/bats harness for
`scripts/*.sh` in this project). The "pre-fix" comparison here is structural
rather than a literal red/green ExUnit run: `git diff 8eef01b^ 8eef01b --
scripts/test_parallel.sh` shows the pre-fix script had **no Step 1.6** and
launched every partition with a bare `MIX_TEST_PARTITION="$i" mix test ...`
-- i.e., **every partition shared the same (default) `MIX_BUILD_PATH`/build
directory**, which is the exact condition eliminated above. The observed-log
evidence above is the pass-side (current, post-fix script); the diff itself
is the documented fail-side (pre-fix script had no per-partition
`MIX_BUILD_PATH` at all, by inspection of the removed/absent code, not by
assertion).

### Mutation revert verification (Part B)

No committed file was mutated for Part B -- the shim `mix` lived entirely in
scratch space (`$PATH` prepended for the probe's shell session only, never
written into the repo), and `scripts/test_parallel.sh` itself was run
unmodified. The only repo-adjacent side effects were gitignored `_build/`
artifacts:

- `_build/test-partition-1` and `_build/test-partition-2` (created by this
  probe run) were removed (`rm -rf`) after collecting the evidence above.
- `_build/test-partition-3` through `-8` pre-existed from earlier, unrelated
  work on this host and were left untouched (not created or modified by this
  step).
- `git status --porcelain` — empty (`_build/` is gitignored, confirmed via
  `.gitignore` line 2: `/_build/`, so none of this ever could have shown up
  there regardless).

## Reproducibility notes for TEST-DESIGN-VALIDATOR

- Part A.1 (real fail-then-pass): swap
  `test/letflow/engine/wasm/plugin_handler_test.exs` for
  `git show 8eef01b^:test/letflow/engine/wasm/plugin_handler_test.exs`, run
  `mix test test/letflow/engine/wasm/plugin_handler_test.exs --seed 0`,
  observe `9/10 passed, 1 failed` (the `:external_resource` test); revert
  with `git checkout --`, re-run, observe `10 passed`.
- Part A.2 (committed regression test): run
  `mix test test/letflow/engine/wasm/plugin_handler_ac7_cross_platform_regression_test.exs`
  directly -- no setup needed, it manages its own fixture. To reproduce the
  "would have failed" side as a live mutant: in that new test file, replace
  the `native_artifact_check(priv_dir, ".dll")` call with the OLD hardcoded
  `File.exists?(Path.join(priv_dir, "native/wasmex.so"))` in the "NEW"
  describe block's assertion and confirm it now fails (then revert).
- Part B: place a `mix` shim earlier on `$PATH` per the script shown above,
  run `TEST_PARALLEL_N=2 bash scripts/test_parallel.sh <a small test path>`,
  and inspect the shim's log for two distinct `MIX_BUILD_PATH` values, one
  per partition. As an alternative/independent check: diff `8eef01b^` against
  `8eef01b` on `scripts/test_parallel.sh` and confirm the pre-fix script
  passes no `MIX_BUILD_PATH` at all to any partition's `mix test`
  invocation (i.e. every partition shared the default build path), which
  Step 1.6 + the per-invocation `MIX_BUILD_PATH=...` in Step 2 (post-fix)
  eliminates.
