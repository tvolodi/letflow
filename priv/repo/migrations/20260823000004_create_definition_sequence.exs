# Letflow.Repo.Migrations.CreateDefinitionSequence
#
# REQ-125, migration 2 of 2. Implements
# lib/letflow/design/req125-definitions-delta-sync.md section 5.2 -- one row per
# tenant schema, mirroring `instance_sequence`'s shape
# (20260816120002_create_instance_sequence.exs) at tenant-schema granularity instead of
# per-instance granularity. New work; no R-Co source to port.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# `tenant_id` is the primary key (not an autoincrement id) so the row is addressable
# without a lookup -- same shape as `instance_sequence`'s `instance_id` primary key.
# ONE row per tenant schema, not per-definition and not per-instance: the delta
# endpoint's ordering guarantee (AC1: "only definitions changed after the supplied
# cursor") is over the whole tenant's definition set, not any one definition's own
# history (design doc section 5.2).
#
# NO indexes beyond the primary key, NO timestamps() -- same "hot row every
# create/activate/deprecate/archive takes a `SELECT ... FOR UPDATE` on, no consumer for
# updated_at" reasoning as `instance_sequence`'s own migration header.
#
# NO foreign key on tenant_id -- same platform-sentinel/no-FK-across-schema-boundary
# reason `instance_sequence` and every other tenant-scoped counter table in this
# codebase already use.
defmodule Letflow.Repo.Migrations.CreateDefinitionSequence do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:definition_sequence, primary_key: false, prefix: prefix()) do
        add :tenant_id, :binary_id, primary_key: true
        add :next_seq, :bigint, null: false, default: 1
      end
    end
  end
end
