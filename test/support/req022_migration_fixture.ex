defmodule Letflow.TenantProvisioning.MigrationFixture do
  @moduledoc """
  Test/demo-only tenant-scoped migration fixture for REQ-022's acceptance
  criterion 3 demonstration — see
  `lib/letflow/design/req022-tenant-schema-provisioning.md` §5 (which
  recommends exactly this: at REQ-022's time `tenant_scoped_migrations/0`
  returned `[]`, so there was no permanent production migration yet to
  replay; a throwaway fixture proves `replay_migrations/2` correctly
  threads `:prefix` through `Ecto.Migrator` without inventing a permanent,
  unused production table).

  **Refreshed by REQ-023 (ISS-0017).** `tenant_scoped_migrations/0` no longer
  returns `[]` — REQ-023 registered six real event-store migrations, and
  `test/letflow/event_store/migrations_test.exs` replays that real manifest
  against a provisioned tenant schema. This fixture is deliberately kept
  regardless: it is the one guard-pattern-following tenant-scoped migration
  that is *not* part of the production manifest, which is what keeps
  REQ-022's own tests independent of whatever that manifest happens to
  contain at any later point.

  Deliberately lives under `test/support/`, not `priv/repo/migrations/` — it
  is never picked up by a plain `mix ecto.migrate` run and never appended to
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s real list.

  Follows §4's required guard pattern (the same pattern every real
  REQ-023-onward tenant-scoped migration file must follow): no-ops when no
  `:prefix` was supplied to the enclosing `Ecto.Migrator` run, so this file
  would be harmless even if it were ever run without one. That pattern is no
  longer enforced by convention alone — REQ-023's
  `test/letflow/event_store/migrations_test.exs` iterates every entry in
  `tenant_scoped_migrations/0` and asserts each one creates nothing in
  `public` when run with no `:prefix`.
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
