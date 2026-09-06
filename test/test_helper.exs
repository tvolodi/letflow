Letflow.TenantSchemaReaper.sweep_orphans()

# ISS-0414: suite-boundary safety net against leftover `service_catalog` rows -- see
# lib/letflow/design/iss0414-service-catalog-safety-net.md and
# Letflow.TenantSchemaReaper's own moduledoc ("ISS-0414" section) for the full
# rationale. Placed at the same two boundary points sweep_orphans/0 above already
# uses, since test/test_helper.exs is the one call site every invocation shape this
# project uses (plain `mix test`, `mix test <path>`, scripts/test_parallel.sh, `mix
# letflow.check.test`) already loads.
Letflow.TenantSchemaReaper.sweep_service_catalog_orphans(Letflow.Repo)

# REQ-134: excludes test/letflow/integration/keycloak_auth_pipeline_test.exs
# (@moduletag :keycloak) from every default invocation -- plain `mix test`, `mix test
# <path>`, and each scripts/test_parallel.sh partition alike, since all three load this
# same test_helper.exs. Deliberate inclusion: `mix test --include keycloak
# test/letflow/integration/keycloak_auth_pipeline_test.exs`. See
# lib/letflow/design/req134-real-keycloak-token-integration.md §2.
#
# ISS-0352: excludes every test tagged `@tag :wasm_hang` (a handful of tests in
# test/letflow/engine/wasm/call_timeout_test.exs and plugin_handler_test.exs that
# deliberately, genuinely hang a real wasmex NIF call to prove REQ-170's own
# live-verified finding -- no BEAM-side mechanism can reclaim that thread once
# hung, so it permanently occupies one slot of wasmex's shared, node-global
# native worker pool for the rest of the OS process). Left in the SAME process
# as every other WASM NIF test, these tests exhausted that shared pool on a
# busy/small CI runner and cascade-failed unrelated tests in the same run
# (first observed PR #691, recurred worse on PR #692 -- 18 cascading
# ExUnit.TimeoutErrors). `mix letflow.check.test` runs these excluded tests in
# their own dedicated, short-lived `mix test --only wasm_hang` subprocess
# afterward, so their permanent leaks die with that process instead of
# starving anything else. Deliberate inclusion for a plain local run:
# `mix test --include wasm_hang test/letflow/engine/wasm/`.
#
# ISS-0426: excludes every test tagged `@tag :lua_wallclock_race` (11 tests in
# test/letflow/engine/lua/executor_test.exs, REQ-155/156/162) whose assertion
# depends on which of two racing wall-clock outcomes wins -- e.g. a shorter
# configured timeout terminating measurably sooner, or a wall-clock kill firing
# before a script's own instruction budget would otherwise let it continue. Under
# scripts/test_parallel.sh's N-way partitioning, BEAM scheduler contention across
# partitions can make Task.yield(timeout_ms) (or run_with_heap_limit/5's own
# `after` clause) observe scheduler unavailability rather than actual Lua
# execution time, producing a spurious {:error, {:wallclock_timeout, _}} the test
# doesn't expect (ISS-0426). Unlike :wasm_hang, these tests don't leak anything --
# they finish in milliseconds, they just need to not race for scheduler time
# against 30+ concurrent siblings -- so a distinct tag name is deliberate rather
# than reusing :wasm_hang's (see lib/letflow/design/iss426-wallclock-test-contention.md
# §2.2 for why conflating the two would mislead a future reader). `mix
# letflow.check.test` runs these excluded tests in their own isolated `mix test
# --only lua_wallclock_race` subprocess, same shape as the :wasm_hang subprocess
# above. Deliberate inclusion for a plain local run: `mix test --include
# lua_wallclock_race test/letflow/engine/lua/executor_test.exs`.
ExUnit.start(exclude: [:keycloak, :wasm_hang, :lua_wallclock_race])

# ISS-0515: structural pre-build of the "tenant_template" schema, synchronous,
# BEFORE any test in this partition process can run. See
# lib/letflow/design/iss0515-tenant-template-build-race-fix.md for the full
# rationale -- summary: ExUnit.start/1 above only REGISTERS the eventual test
# run via System.at_exit/1; it does not dispatch a single test inline. That
# means this call, placed anywhere in this file, is guaranteed to complete
# before any test process exists, so no test process can ever race another to
# be the first caller of `ensure_template!/0` within this partition again --
# the ONLY concurrent caller of its advisory-lock acquisition is now this one,
# uncontested, one-time call. This removes the race's own precondition (2+
# concurrent first-callers within one scripts/test_parallel.sh partition)
# rather than widening its timing margin (design §3's rejection of a bigger
# lock-acquisition timeout as the fix). Unconditional -- not gated behind any
# "does this run touch a tenant fixture" heuristic (design §7).
Letflow.Test.TenantTemplate.ensure_template!()

ExUnit.after_suite(fn _stats ->
  Letflow.TenantSchemaReaper.sweep_orphans()
  Letflow.TenantSchemaReaper.sweep_service_catalog_orphans(Letflow.Repo)
end)
