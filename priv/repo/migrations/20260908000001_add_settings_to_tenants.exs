# Letflow.Repo.Migrations.AddSettingsToTenants
#
# REQ-280 -- see lib/letflow/design/req280-tenant-settings-store.md §2 for the
# full design this migration implements.
#
# PLACEMENT: GLOBAL, not tenant-scoped. `tenants` lives in Ecto's single
# default schema (see Letflow.Identity.Tenant's own moduledoc, "This schema
# targets Ecto's single default schema") -- there is no `if prefix() do`
# guard here and this file is deliberately NOT registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0, because this table
# is not per-tenant-schema-scoped at all.
#
# `:map` (JSONB on Postgres) is nullable with NO `:default` -- an absent
# settings value must read back as `nil` ("this tenant configured nothing"),
# never an invented empty map or platform-default bundle. See design §2's
# "No default is invented" reasoning (mirrors REQ-047's established
# discipline for `tasks.form_schema`). The closed-vocabulary enforcement
# (exactly 5 allowed keys) lives in the application layer
# (Letflow.Identity.TenantSettings, the custom Ecto.Type used for this
# column in the schema) -- not here; a migration-time CHECK constraint
# cannot express "reject an unrecognized JSON key" cleanly.
#
# No index: nothing in REQ-280's acceptance criteria queries tenants *by* a
# settings value.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- plain
# Ecto migration DSL only.
defmodule Letflow.Repo.Migrations.AddSettingsToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :settings, :map, null: true
    end
  end
end
