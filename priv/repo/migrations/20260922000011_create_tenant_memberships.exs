# Letflow.Repo.Migrations.CreateTenantMemberships
#
# REQ-384 Part A (design lib/letflow/design/req384-tenant-switcher-cache-isolation.md
# SS1.1) -- new public-schema table, same tier as `tenants` (NOT tenant-scoped,
# no `prefix()` guard -- Decision 0006's D3 tier: a real FK to `tenants`, not a
# schema-boundary echo).
#
# ADMIN-WRITE-ONLY (design SS1.1, decision-record amendment
# docs/migration/decisions/0038-tenant-membership-lookup-amendment.md point 2):
# nothing in the JIT-provisioning or claim-mapping pipeline may ever write this
# table. Only a PLATFORM_ADMIN-gated write path (out of scope for REQ-384
# itself -- see the design's OQ-2) may insert/delete rows here. This migration
# creates the table and its indexes only; no seed data, no application-code
# writer ships with REQ-384.
#
# `subject_key` is the normalized (lower-cased, trimmed) email a
# Letflow.Identity.TenantMembership.create_changeset/2 write validates and
# normalizes -- see that module for the write-side normalization this table's
# read path (Letflow.Identity.list_memberships_for_subject/1) depends on
# matching exactly.
defmodule Letflow.Repo.Migrations.CreateTenantMemberships do
  use Ecto.Migration

  def change do
    create table(:tenant_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :subject_key, :string, null: false
      add :tenant_id, references(:tenants, type: :binary_id, on_delete: :nothing), null: false
      add :display_label, :string

      timestamps()
    end

    create unique_index(:tenant_memberships, [:subject_key, :tenant_id])
    create index(:tenant_memberships, [:subject_key])
  end
end
