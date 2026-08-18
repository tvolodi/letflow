# Letflow.Repo.Migrations.DropTenantIdUsers
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from the per-tenant `users`
# table (created by 20260819000003_create_users_tenant_scoped.exs, REQ-063
# D1). See lib/letflow/design/req064-drop-tenant-id.md section 2.2 point 9.
#
# ALSO drops `index(:users, [:tenant_id, :status, :inserted_at])` --
# generated-name `users_tenant_id_status_inserted_at_index` -- with NO
# replacement index. This is a THIRD composite index, not one of the two
# ("promotion_reviews", "promotion_assertion_runs") the original requirement
# text named; found during this design's direct read of the shipped `users`
# migration. Design decision (§2.2 point 9, §7 open question 2): drop
# outright, do not replace with `index(:users, [:status, :inserted_at])` --
# no consumer of that shape was found in `lib/letflow/identity.ex` or
# elsewhere during the design session (not an exhaustive search of every
# `users` query in the codebase; if a real consumer of `[:status,
# :inserted_at]` alone surfaces later, the correct fix is a fresh
# `index(:users, [:status, :inserted_at])`, not resurrecting the
# three-column original). `drop_if_exists` is used to sidestep any risk of a
# mismatched generated index name.
#
# `unique_index(:users, [:username])` and
# `users_external_identity_partial_index` are UNTOUCHED by this migration --
# neither references `tenant_id`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
defmodule Letflow.Repo.Migrations.DropTenantIdUsers do
  use Ecto.Migration

  def change do
    if prefix() do
      drop_if_exists index(:users, [:tenant_id, :status, :inserted_at], prefix: prefix())

      alter table(:users, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
