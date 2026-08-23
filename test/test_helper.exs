Letflow.TenantSchemaReaper.sweep_orphans()

# REQ-134: excludes test/letflow/integration/keycloak_auth_pipeline_test.exs
# (@moduletag :keycloak) from every default invocation -- plain `mix test`, `mix test
# <path>`, and each scripts/test_parallel.sh partition alike, since all three load this
# same test_helper.exs. Deliberate inclusion: `mix test --include keycloak
# test/letflow/integration/keycloak_auth_pipeline_test.exs`. See
# lib/letflow/design/req134-real-keycloak-token-integration.md §2.
ExUnit.start(exclude: [:keycloak])

ExUnit.after_suite(fn _stats -> Letflow.TenantSchemaReaper.sweep_orphans() end)
