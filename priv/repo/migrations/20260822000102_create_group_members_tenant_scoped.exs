# Letflow.Repo.Migrations.CreateGroupMembersTenantScoped
#
# REQ-074 (design §8a) -- new join table backing group membership
# (`Letflow.Identity.GroupMember`, `Identity.add_group_member/3`,
# `Identity.list_group_members/3`, `Identity.remove_group_member/3`). No
# `group_members` table exists anywhere in this codebase before this
# migration (confirmed: `grep -rl "group_members" priv/repo/migrations/` had
# zero hits prior to this file).
#
# `on_delete: :nothing` (not `:delete_all`) on both FKs is deliberate, per
# design §5/§8a: R-Co's own `deleteGroupIfEmpty` REFUSES deletion of a
# non-empty group at the application layer (`Identity.delete_group/2`'s own
# guarded `NOT EXISTS` delete) rather than relying on a DB-level cascade. A
# `ON DELETE CASCADE` here would be a silent behavioral addition this design
# does not intend -- `delete_group/2` never issues the delete when members
# exist, so this FK's `on_delete` clause is never really exercised against a
# non-empty group in practice.
#
# No surrogate `:id` primary key (OQ-7, ELIXIR-DEV's call) -- this is a pure
# join table and every `Letflow.Identity` function signature operates on
# `(group_id, user_id)`, never a bare `GroupMember` id. The composite unique
# index below is this table's real identity.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory.
#
# See lib/letflow/design/req074-identity-group-routes.md section 8a.
defmodule Letflow.Repo.Migrations.CreateGroupMembersTenantScoped do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:group_members, primary_key: false, prefix: prefix()) do
        add :group_id, references(:groups, type: :binary_id, on_delete: :nothing), null: false
        add :user_id, references(:users, type: :binary_id, on_delete: :nothing), null: false

        # added_at semantics -- no update path exists for a membership row.
        timestamps(updated_at: false)
      end

      create unique_index(:group_members, [:group_id, :user_id], prefix: prefix())
      create index(:group_members, [:user_id], prefix: prefix())
    end
  end
end
