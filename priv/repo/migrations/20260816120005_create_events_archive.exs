# Letflow.Repo.Migrations.CreateEventsArchive
#
# REQ-023, migration 5 of 6. Implements lib/letflow/design/req023-event-store-schema.md
# section 3.6 (the `events_archive` table). Ported from R-Co
# migrations/003_event_archive.sql:9-30, with the composite primary key R-Co only
# reached later at 1147_par01_events_partitioning.sql:167-186, plus tenant_id from
# 027_adp01_event_store_tenant.sql. Destination table for REQ-026's archive operation;
# nothing in REQ-023 writes to it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# Column list is exactly `events`' (20260816120001_create_events.exs), with the same
# types and nullability, plus `archived_at`, and with two deliberate differences:
#
#   1. global_seq is `:bigint` with NO sequence and NO default (not `:bigserial`) -- the
#      value is copied from the `events` row being archived, never freshly allocated.
#      R-Co: `global_seq BIGINT NOT NULL` (003:19, 1147:178).
#
#   2. created_at carries NO default, unlike `events.created_at`. This is deliberate and
#      is NOT an oversight of the "same defaults as events" reading. R-Co gives this
#      column no default on the archive (003:15 and 1147:176 both read
#      `created_at TIMESTAMPTZ NOT NULL` with no DEFAULT, against 001:30's defaulted
#      column on `events`) because the value is COPIED from the original event, never
#      generated here. Since created_at is half the composite primary key, a default
#      would let a future REQ-026 archive insert that omitted it silently stamp *archive*
#      time into the PK and still insert cleanly -- a latent corruption of the archived
#      event's identity. Omitting the default makes that mistake fail loudly instead.
#
# PRIMARY KEY (event_id, created_at) -- the same composite shape as `events`, for the
# same 0003 Decision C point 2(a) reason. R-Co widened this table's PK in the same
# migration that widened `events`' (1147:181, versus the bare `event_id PRIMARY KEY` of
# 003:10). Both PK components are NOT NULL by virtue of the PRIMARY KEY constraint.
#
# NO unique index on idempotency_key. R-Co's 013_event_archive_idempotency.sql:20-21
# `uq_event_archive_idempotency` is deliberately NOT ported -- superseded by the
# `event_idempotency` sidecar (migration 6) per 0003 Decision C point 2(b), exactly as
# R-Co did at 1147:192-193 ("plat_event_idempotency supersedes its purpose").
#
# NO tenant-prefixed indexes (027:18-22, 1147:187-190): under 0003 Decision B the
# Postgres schema *is* the tenant boundary, so tenant_id has at most one distinct value
# per schema and a leading-tenant_id index degenerates to its non-tenant counterpart at
# strictly higher write cost. R-Co created those while its tables still lived in shared
# public.
#
# NO foreign keys and NO timestamps() -- same reasons as `events`; `created_at` and
# `archived_at` are this table's time columns.
defmodule Letflow.Repo.Migrations.CreateEventsArchive do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:events_archive, primary_key: false, prefix: prefix()) do
        add :event_id, :binary_id, primary_key: true
        # No default -- see difference (2) in this file's header comment.
        add :created_at, :utc_datetime_usec, primary_key: true
        add :instance_id, :binary_id, null: false
        add :event_type, :string, null: false
        add :payload, :map, null: false, default: %{}
        add :actor_id, :binary_id, null: false
        add :sequence_number, :bigint, null: false
        add :idempotency_key, :string, null: false
        add :metadata, :map, null: false, default: %{}
        add :global_seq, :bigint, null: false
        add :tenant_id, :binary_id, null: false

        add :archived_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")
      end

      create index(:events_archive, [:instance_id, :sequence_number],
               name: :idx_archive_instance,
               prefix: prefix()
             )

      create index(:events_archive, [:event_type], name: :idx_archive_type, prefix: prefix())

      create index(:events_archive, [:created_at], name: :idx_archive_time, prefix: prefix())
    end
  end
end
