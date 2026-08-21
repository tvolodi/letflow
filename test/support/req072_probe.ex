defmodule Letflow.Api.Context.Test.Probe do
  @moduledoc """
  Minimal, deliberately-scoped test-only fixture schema for REQ-072's
  cross-tenant-404 test (design §4.1). Backed by a tiny tenant-scoped table
  created only inside the test database, via a migration-shaped fixture
  reusing `test/support/req022_migration_fixture.ex`'s established pattern
  (a `migration_source` fixture replayed narrowly, guarded to no-op with no
  `:prefix`).

  Deliberately lives under `test/support/`, never under `lib/` or
  `priv/repo/migrations/` — it is never part of the production schema and
  never picked up by a plain `mix ecto.migrate` run.

  Shape: `id :: binary_id` (primary key), `label :: String.t()` — nothing
  else. No production meaning; its only purpose is "a row a `Repo.get/3`
  call can find or not find."
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "req072_probe" do
    field(:label, :string)
  end
end

defmodule Letflow.Api.Context.Test.ProbeMigration do
  @moduledoc """
  Migration fixture for `Letflow.Api.Context.Test.Probe`, replayed via
  `Letflow.TenantProvisioning.replay_migrations/2` with an explicit
  `migration_source` naming only this module — mirrors
  `Letflow.TenantProvisioning.MigrationFixture`'s (`test/support/
  req022_migration_fixture.ex`) narrow-`migration_source` convention and its
  required guard pattern: no-ops when no `:prefix` was supplied to the
  enclosing `Ecto.Migrator` run, so this file is harmless even if it were
  ever run without one.
  """

  use Ecto.Migration

  def change do
    if prefix() do
      create table(:req072_probe, primary_key: false, prefix: prefix()) do
        add(:id, :binary_id, primary_key: true)
        add(:label, :string, null: false)
      end
    end
  end
end
