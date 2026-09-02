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
ExUnit.start(exclude: [:keycloak, :wasm_hang])

ExUnit.after_suite(fn _stats ->
  Letflow.TenantSchemaReaper.sweep_orphans()
  Letflow.TenantSchemaReaper.sweep_service_catalog_orphans(Letflow.Repo)
end)
