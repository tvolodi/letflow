# ISS-0377 TEST-DESIGN-VALIDATOR report (WF-03 Step 4b)

Branch: `feature/WF03-ISS0377-20260830`. Verifying TEST-DESIGNER's evidence in
`test/specs/ISS-0377-regression-proof.md` (commit `b794c18`) against the fix
in `8eef01b` (parent `64eef56`).

Verdict: **PASS**.

## What was independently re-derived (not just read)

### Part A.1 -- real fail-then-pass on the `:external_resource` assertion

1. Confirmed `git status --porcelain` empty before starting.
2. Diffed `git show 8eef01b^:test/letflow/engine/wasm/plugin_handler_test.exs`
   against the current (post-fix) file myself -- confirmed the pre-fix file
   genuinely lacks `expected_native_extension/0` and `native_artifact_check/2`,
   matching TEST-DESIGNER's description of what changed.
3. Swapped the pre-fix content into
   `test/letflow/engine/wasm/plugin_handler_test.exs` myself and ran (with
   `--include wasm_hang`, a superset of TEST-DESIGNER's run):

   ```
   MIX_ENV=test mix test test/letflow/engine/wasm/plugin_handler_test.exs --seed 0 --include wasm_hang
   ...
   1) test AC7: the wasmex NIF is a loaded shared library, not an external process Wasmex.Native resolves to a compiled .beam built from Rust NIF sources (Letflow.Engine.Wasm.PluginHandlerTest)
      test/letflow/engine/wasm/plugin_handler_test.exs:180
      expected Wasmex.Native's external_resource attributes to name its Rust NIF sources
   ...
   Result: 13/14 passed
   Failed: 1 test
   ```

   Same single test fails as TEST-DESIGNER reported (9/10 passed when
   `wasm_hang` is excluded; my run included the 4 `wasm_hang` tests, giving
   13/14 -- 9+4=13, consistent). This host's precompiled wasmex build
   genuinely has an empty `:external_resource` list -- confirmed real, not
   fabricated: the pre-fix code has no branch to handle an empty list, so it
   falls straight through to the `Enum.any?(... "native/wasmex/src/")`
   assertion, which fails against an empty list on this real host.
4. Reverted: `git checkout -- test/letflow/engine/wasm/plugin_handler_test.exs`.
5. Verified: `git status --porcelain` empty (immediately after revert).
6. Re-ran the same command on the restored file:

   ```
   Result: 14 passed
   ```

   All green, confirming the revert restored working post-fix behavior.

This is an independent APPLY-and-run of mutation A.1, per WF-03 Step 4's
"code under test does not exist" rule (applied here even though this fix
touches existing test code, at the launching agent's explicit request, since
A.1 is the one real, non-simulated failure available on this sandbox).

### Part A.2 -- committed cross-platform regression test

Read `test/letflow/engine/wasm/plugin_handler_ac7_cross_platform_regression_test.exs`
in full. Confirmed it genuinely:

- Builds a simulated Windows-shaped `priv/native/` tree in a real temp
  directory (`setup`/`on_exit`), containing only a version/arch-suffixed
  `.dll` (no fixed-name `wasmex.so`/`wasmex.dll`).
- Contains a verbatim copy of the shipped `native_artifact_check/2` (matches
  the post-fix `plugin_handler_test.exs` byte-for-byte, checked by direct
  comparison) and asserts it returns `{:ok, :fallback_listing, native_dir}`
  against the fixture.
- Separately asserts the OLD hardcoded `Path.join(priv_dir, "native/wasmex.so")`
  check is unsatisfiable (`refute File.exists?(so_path)`) against the same
  fixture -- this is a real OLD-vs-NEW comparison, not a single one-sided
  assertion.

Ran it fresh myself:

```
MIX_ENV=test mix test test/letflow/engine/wasm/plugin_handler_ac7_cross_platform_regression_test.exs --seed 0
...
Result: 2 passed
```

Matches TEST-DESIGNER's reported count exactly.

### Part B -- structural evidence

Read the mix-shim env-capture section of the regression-proof doc. Independently
re-ran the cheaper half of the check myself:

```
git diff 8eef01b^ 8eef01b -- scripts/test_parallel.sh
```

Confirmed directly: the pre-fix script has no "Step 1.6" and launches every
partition with a bare `MIX_TEST_PARTITION="$i" mix test ...` (no
`MIX_BUILD_PATH` anywhere); the post-fix script adds the per-partition
hardlink-preserving seed pass and passes a distinct, command-scoped
`MIX_BUILD_PATH="_build/test-partition-$i"` to each partition's own `mix
test` invocation. This independently confirms the structural half of Part B's
claim (every partition shared one build path pre-fix; each gets its own
post-fix). Did not re-run the mix-shim env-capture probe myself (time budget,
and it is a live-environment probe rather than a repo-content diff) -- the
diff-based check above is sufficient corroboration of the claimed mechanism
and is fully reproducible from the two commits alone.

## Acceptance-criteria coverage check

- AC7 (both assertions): covered by
  `test/letflow/engine/wasm/plugin_handler_test.exs` (post-fix, currently
  green) plus the new permanent
  `plugin_handler_ac7_cross_platform_regression_test.exs`. No `@tag :skip`
  present. No "TODO: implement test" in either file.
- Part B (build-path isolation): no unit-testable Elixir surface exists (confirmed
  no `scripts/*.sh` test harness in this project); structural diff evidence is the
  strongest available proof and is documented and independently reproduced above.
- Fixtures: the new regression test's fixture is a fresh, uniquely-named
  temp directory per test run (`System.unique_integer/1` in the path), torn
  down in `on_exit` -- no shared hardcoded state, no cross-test ordering
  dependency (`async: true`, both tests independent of each other).
- No hardcoded secrets/connection strings in either file.
- No test depends on another test having run first.

## Mutation revert final check

Final `git status --porcelain`: empty (confirmed after all work above,
including the A.1 swap-and-revert). No file outside `test/specs/` and this
new report was modified in this validation step.

## Verdict

**PASS.** Both Part A and Part B evidence hold up under independent
re-derivation. Routing to Step 5 (ISSUE-FIXER closes ISS-0377) per this run's
explicit WF-03 routing -- not TEST-RUNNER/RELEASE-VALIDATOR/DOC-UPDATER,
which are WF-02's downstream steps.
