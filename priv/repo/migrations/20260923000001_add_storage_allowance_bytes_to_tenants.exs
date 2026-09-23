defmodule Letflow.Repo.Migrations.AddStorageAllowanceBytesToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :storage_allowance_bytes, :bigint, null: false, default: 1_073_741_824
    end
  end
end
