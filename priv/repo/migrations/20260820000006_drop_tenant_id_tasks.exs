# Letflow.Repo.Migrations.DropTenantIdTasks
#
# Decision 0006 D2, REQ-064 -- drops `tenant_id` from `tasks`. See
# lib/letflow/design/req064-drop-tenant-id.md sections 1-2. Neither
# `idx_task_instance` (on instance_id alone) nor `idx_task_token` (on token_id
# alone) references `tenant_id`, so this is a pure column drop with no
# index-shape consequence.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both
# halves are mandatory. Sorts after 20260820000005_drop_tenant_id_tokens.exs
# for narrative consistency with the FK-ordering the original create migrations
# established (tasks.token_id FKs onto tokens.id), though this drop touches
# neither table's FK relationship.
defmodule Letflow.Repo.Migrations.DropTenantIdTasks do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:tasks, prefix: prefix()) do
        remove :tenant_id, :binary_id
      end
    end
  end
end
