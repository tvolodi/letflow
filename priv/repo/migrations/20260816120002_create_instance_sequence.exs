# Letflow.Repo.Migrations.CreateInstanceSequence
#
# REQ-023, migration 2 of 6. Implements lib/letflow/design/req023-event-store-schema.md
# section 3.2 (the `instance_sequence` table). Ported from R-Co
# migrations/001_event_store.sql:73-76 -- the per-instance sequence-lock row
# src/design/event_store.md's "Concurrency design" section describes
# (SELECT ... FOR UPDATE / increment protocol, implemented in REQ-025, not here).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale: without it a plain
# `mix ecto.migrate` would create a stray `public.instance_sequence` on every dev/CI
# bootstrap. Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
#
# NO indexes beyond the primary key, and NO timestamps(): R-Co has neither (001:73-76).
# This is the hot row every append takes a `SELECT ... FOR UPDATE` on
# (event_store.md:353-358); an `updated_at` would add a write to the most contended row
# in the system for no consumer.
#
# NO foreign key on instance_id -- same platform-sentinel reason as `events` (design
# section 3.1.3), and R-Co's "first append to a new instance" pattern
# (event_store.md:360-367) inserts this row before any projection row necessarily
# exists.
defmodule Letflow.Repo.Migrations.CreateInstanceSequence do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:instance_sequence, primary_key: false, prefix: prefix()) do
        add :instance_id, :binary_id, primary_key: true
        add :next_seq, :bigint, null: false, default: 1
      end
    end
  end
end
