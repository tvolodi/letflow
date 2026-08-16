defmodule Letflow.TenantProvisioning.MigrationFixture do
  @moduledoc """
  Test/demo-only tenant-scoped migration fixture for REQ-022's acceptance
  criterion 3 demonstration — see
  `lib/letflow/design/req022-tenant-schema-provisioning.md` §5 (which
  recommends exactly this: `tenant_scoped_migrations/0` is `[]` at this point
  in the project's history, so there is no permanent production migration yet
  to replay; a throwaway fixture proves `replay_migrations/2` correctly
  threads `:prefix` through `Ecto.Migrator` without inventing a permanent,
  unused production table).

  Deliberately lives under `test/support/`, not `priv/repo/migrations/` — it
  is never picked up by a plain `mix ecto.migrate` run and never appended to
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s real list.

  Follows §4's required guard pattern (the same pattern every real
  REQ-023-onward tenant-scoped migration file must follow): no-ops when no
  `:prefix` was supplied to the enclosing `Ecto.Migrator` run, so this file
  would be harmless even if it were ever run without one.
  """

  use Ecto.Migration

  def change do
    if prefix() do
      create table(:req022_demo_marker, primary_key: false, prefix: prefix()) do
        add(:id, :binary_id, primary_key: true)
      end
    end
  end
end
