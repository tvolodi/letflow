# Letflow.Repo.Migrations.CreateAuditChainLocks
#
# ISS-0979. Implements lib/letflow/design/iss0979-audit-chain-lock.md section
# 3.1 (the `audit_chain_locks` table) -- the per-tenant sentinel row
# `Letflow.Audit.insert_entry/3` locks (`SELECT ... FOR UPDATE`) before reading
# `audit_entries`' chain tail, closing the two-concurrent-writers-fork race the
# design document's section 0 describes. Mirrors
# 20260816120002_create_instance_sequence.exs's own shape/rationale verbatim --
# this is the same "insert-if-absent, then lock a real per-tenant row" idiom
# `Letflow.EventStore.assign_sequence/3`/`lock_and_increment_sequence/3` already
# uses for `instance_sequence`, applied to a new table rather than a new
# locking primitive.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4. Registered
# in Letflow.TenantProvisioning.tenant_scoped_migration_manifest/0 -- both
# halves are mandatory.
#
# NO indexes beyond the primary key (single-row-per-tenant table; the PK
# lookup is the only query shape this table ever serves), and NO timestamps():
# same rationale as `instance_sequence`'s own header -- this is the hot row
# every `insert_entry/3` call locks, and an `updated_at` would add a write to
# the most contended row in the tenant schema for no consumer that reads it.
#
# NO foreign key on tenant_id -- confirmed against `audit_entries.tenant_id`'s
# own precedent (20260830020001_create_audit_entries_tenant_scoped.exs), which
# also declines a foreign key on this same column (design doc OQ-3).
defmodule Letflow.Repo.Migrations.CreateAuditChainLocks do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:audit_chain_locks, primary_key: false, prefix: prefix()) do
        add :tenant_id, :binary_id, primary_key: true
      end
    end
  end
end
