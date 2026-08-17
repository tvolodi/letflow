# Letflow.Repo.Migrations.CreateSolutionPackInstalls
#
# REQ-041. Implements lib/letflow/design/req041-pack-update-diff-schema.md
# section 3.1 (the `solution_pack_installs` table) and its one partial unique
# index. This table holds one row per (tenant_id, pack_id) install record --
# the tenant's current (or most recent) installed state of a given solution
# pack -- see Letflow.Definitions.SolutionPackInstall's moduledoc for the full
# picture; this migration builds schema only (design section 1's scope
# boundary).
#
# GLOBAL -- no prefix:, see REQ-041. Unlike every other S2 migration in this
# batch, this table (and its two siblings, solution_pack_artefact_bases and
# pack_update_resolutions) is deliberately NOT tenant-scoped: it lives in the
# public/default schema, carries no `if prefix() do ... end` guard, and is NOT
# registered in Letflow.TenantProvisioning's tenant_scoped_migrations/0. This
# is REQ-041 acceptance criterion 1's explicit mandate (design section 2/4.1),
# not an oversight -- "install records are cross-tenant infrastructure"
# (prm-batch1's own classification, quoted in REQ-041's docs/requirements.yaml
# entry), the same kind of classification R-Co's own service_catalog carries.
# See Letflow.Definitions.SolutionPackInstall's moduledoc for the full
# open-question flag (design section 7 / section 9 OQ-2): the GENERAL rule for
# when a table earns this GLOBAL exception is explicitly left unresolved
# beyond this requirement's own scope.
#
# tenant_id DOES carry a database-level foreign-key reference to tenants.id
# (no explicit on_delete:, so Ecto/Postgres default ON DELETE NO ACTION) --
# copied directly from 20260816090045_create_tenant_schemas.exs's
# tenant_schemas.tenant_id shape (design section 0/3.1): solution_pack_installs
# and tenants are both structurally-global siblings that are never candidates
# for moving behind a tenant's own schema prefix, so this FK never needs to be
# dropped later.
#
# `status` is a bare-atom-list Ecto.Enum ([:active, :uninstalled]), dumping
# lowercase via to_string/1 -- matching process_definitions.status/
# tenants.status's established pattern, so there is no case-mismatch risk
# against the partial-unique-index predicate below (design section 3.1).
defmodule Letflow.Repo.Migrations.CreateSolutionPackInstalls do
  use Ecto.Migration

  def change do
    create table(:solution_pack_installs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, references(:tenants, type: :binary_id), null: false
      add :pack_id, :string, null: false
      add :installed_version, :string, null: false
      add :status, :string, null: false, default: "active"
      add :installed_at, :utc_datetime_usec, null: false
      add :uninstalled_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # REQ-041 design section 3.1: at most one active install per
    # (tenant_id, pack_id) -- historical/uninstalled rows don't block a fresh
    # reinstall.
    create unique_index(:solution_pack_installs, [:tenant_id, :pack_id],
             name: :uq_solution_pack_install_active,
             where: "status = 'active'"
           )
  end
end
