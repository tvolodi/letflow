defmodule Letflow.TenantOnboarding.BrokenMigrationFixture do
  @moduledoc """
  Test-only migration fixture that deliberately raises when run, for REQ-076's AC9
  test (`test/letflow/tenant_onboarding_test.exs`) — forces
  `Letflow.TenantProvisioning.replay_migrations/2` to fail cleanly with
  `{:error, {:migration_failed, exception}}` so the test can exercise the
  partial-provisioning recovery path (`Letflow.TenantOnboarding.recover_provisioning/1`,
  ISS-0230).

  Kept separate from `test/support/req022_migration_fixture.ex`, which deliberately
  no-ops and must keep succeeding for REQ-022's own tests — this fixture exists purely
  to fail, and must never be added to
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s real production list or to
  `priv/repo/migrations/`.

  Raises unconditionally, even under a `nil` prefix — unlike the guard-pattern fixture,
  this one is never meant to run outside a deliberately-forced-failure test, so there is
  no "harmless when run with no :prefix" property to preserve here.
  """

  use Ecto.Migration

  def change do
    raise "REQ-076 AC9 test fixture: deliberate migration failure (ISS-0230)"
  end
end
