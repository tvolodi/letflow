defmodule Mix.Tasks.Letflow.CopyIdentityTables do
  @shortdoc "Copies users/groups/tenant_role from the public schema into each tenant's own schema (Decision 0006 D1)"

  @moduledoc """
  Decision 0006 D1's data-copy cutover step
  (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md` section 4
  step 3): moves every tenant's `users`/`groups`/`tenant_role` rows out of the
  legacy public tables into that tenant's own already-provisioned Postgres schema.

  Thin wrapper around `Letflow.IdentityMigration.copy_all_tenants/0` — see that
  module for the real logic, kept separate so it is unit-testable without going
  through `Mix.Task.run/1`.

  ## Usage

      mix letflow.copy_identity_tables

  No arguments. Run once per environment, as an explicit operator (or pipeline)
  step, strictly between the three per-tenant `create table` migrations
  (`priv/repo/migrations/20260819000001/2/3_..._tenant_scoped.exs`) having been
  replayed across every tenant schema, and
  `20260819000004_drop_legacy_public_identity_tables.exs` running. **Not run
  automatically by `mix ecto.migrate`** — this is not a migration.

  Idempotent — safe to re-run after a partial failure (see
  `Letflow.IdentityMigration`'s moduledoc).
  """

  use Mix.Task

  alias Letflow.IdentityMigration

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case IdentityMigration.copy_all_tenants() do
      {:ok, summary} ->
        Mix.shell().info(
          "mix letflow.copy_identity_tables: OK -- " <>
            "#{summary.tenants_processed} tenant(s) processed, " <>
            "#{summary.groups_copied} group(s), " <>
            "#{summary.users_copied} user(s), " <>
            "#{summary.tenant_roles_copied} tenant_role(s) copied."
        )

      {:error, {:tenant_copy_failed, tenant_id, reason}} ->
        Mix.raise(
          "mix letflow.copy_identity_tables: FAILED for tenant #{tenant_id}: #{inspect(reason)}. " <>
            "Safe to re-run after diagnosing -- already-copied rows are skipped via on_conflict: :nothing."
        )
    end
  end
end
