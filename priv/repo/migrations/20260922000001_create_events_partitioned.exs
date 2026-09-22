# Letflow.Repo.Migrations.CreateEventsPartitioned
#
# REQ-376, migration 1 of 6. Implements
# lib/letflow/design/req376-partition-event-retirement.md section 2.1 item 1.
# Creates the new partitioned parent `events_p` alongside (not replacing) the
# existing `events` table -- migration 4 of this set (swap_events_partitioned)
# performs the atomic rename once migrations 2/3 have populated it.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching every event-store migration this requirement builds on
# (20260816120001_create_events.exs). Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are
# mandatory.
#
# Ecto.Migration's DSL has no `PARTITION BY` primitive, so this migration uses
# `execute/1,2` for the partition-specific DDL -- not an INV-7 violation
# (INV-7 concerns tenant/user-supplied data in query construction, not DDL
# with no external input; 0003-ecto-schema-strategy.md Dimension A already
# names `execute/1` as the intended escape hatch). `prefix()` here is the
# already-validated tenant schema name Letflow.TenantProvisioning generates
# (`"tenant_" <> <32 hex>`), never user input.
#
# Column list is byte-for-byte `events`' current column list minus
# `tenant_id` (already dropped, 20260820000001_drop_tenant_id_events.exs).
#
# `global_seq` is plain `bigint` here, NOT `bigserial` -- design doc section
# 2.4: creating a `bigserial`-equivalent default via the Ecto DSL's column
# type against a table created through raw `execute/1` DDL has no clean
# expression, so the sequence is created and owned explicitly instead. End
# behavior is identical to `events.global_seq` today; only the DDL authoring
# mechanism differs.
#
# Sequence is named `events_p_global_seq_seq`, NOT `events_global_seq_seq` --
# the CURRENT `events` table (20260816120001_create_events.exs's `bigserial`
# column) already owns a Postgres-auto-named sequence with that exact name,
# and both tables coexist side by side until migration 4
# (swap_events_partitioned) renames `events` aside. Migration 4 renames this
# sequence to `events_global_seq_seq` immediately after that swap, once the
# name is free.
#
# Indexes are created on the PARENT -- Postgres >= 11 propagates a
# parent-level `CREATE INDEX` to every current and future partition
# automatically, no per-partition index DDL needed. Same four indexes, same
# names, as the current `events` table.
defmodule Letflow.Repo.Migrations.CreateEventsPartitioned do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute("""
      CREATE TABLE "#{schema}".events_p (
        event_id uuid NOT NULL,
        created_at timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'utc'),
        instance_id uuid NOT NULL,
        event_type varchar NOT NULL,
        payload jsonb NOT NULL DEFAULT '{}',
        actor_id uuid NOT NULL,
        sequence_number bigint NOT NULL,
        idempotency_key varchar NOT NULL,
        metadata jsonb NOT NULL DEFAULT '{}',
        global_seq bigint NOT NULL,
        PRIMARY KEY (event_id, created_at)
      ) PARTITION BY RANGE (created_at)
      """)

      execute(
        ~s{CREATE SEQUENCE "#{schema}".events_p_global_seq_seq OWNED BY "#{schema}".events_p.global_seq}
      )

      execute(
        ~s{ALTER TABLE "#{schema}".events_p ALTER COLUMN global_seq SET DEFAULT nextval('"#{schema}".events_p_global_seq_seq')}
      )

      # `created_at` (the partition key) MUST be part of every unique index
      # on a partitioned table -- a real Postgres restriction (confirmed
      # empirically: "unique constraint on partitioned table must include
      # all partitioning columns" / 0A000 feature_not_supported), which
      # decision 0037's PK-consequences analysis addressed for the PRIMARY
      # KEY but did not separately re-check for this table's OTHER unique
      # index -- events already has one, uq_event_sequence, which decision
      # 0037 incorrectly stated does not exist ("neither table has any
      # other unique index"). Corrected here, flagged for REVIEWER's Step
      # 2d attention rather than silently left as a passing claim: widening
      # to (instance_id, sequence_number, created_at) does not weaken the
      # real uniqueness guarantee in practice -- sequence_number is only
      # ever assigned once per instance, under InstanceSequence's FOR UPDATE
      # lock, with the SAME created_at bound into the same transaction's
      # events insert (design INV-EV-5) -- so no two rows can legitimately
      # share (instance_id, sequence_number) with different created_at
      # values; this index still catches every real conflict
      # Letflow.EventStore.sequence_conflict?/1 depends on (constraint name
      # "uq_event_sequence" is unchanged, only its column list widens).
      # Index names are also `_p`-suffixed here, same reason and same fix as
      # migration 1's sequence rename: index names are schema-unique in
      # Postgres, not table-unique, so a plain `uq_event_sequence` here would
      # collide with the CURRENT `events` table's own already-existing index
      # of that exact name while both tables coexist (confirmed empirically:
      # 42P07 duplicate_table on `uq_event_sequence`). Migration 4
      # (swap_events_partitioned) renames the old table's indexes out of the
      # way first, then renames these into their permanent, unsuffixed
      # names -- exact same two-step order as its sequence rename.
      execute(
        ~s{CREATE UNIQUE INDEX uq_event_sequence_p ON "#{schema}".events_p (instance_id, sequence_number, created_at)}
      )

      execute(~s{CREATE INDEX idx_events_global_seq_p ON "#{schema}".events_p (global_seq)})

      execute(
        ~s{CREATE INDEX idx_events_instance_time_p ON "#{schema}".events_p (instance_id, created_at)}
      )

      execute(~s{CREATE INDEX idx_events_type_p ON "#{schema}".events_p (event_type)})
    end
  end

  def down do
    if prefix() do
      schema = prefix()
      # DROP TABLE on a partitioned parent drops every still-attached
      # partition and index automatically (Postgres declarative-partitioning
      # semantics); the OWNED BY sequence is dropped automatically with its
      # owning column.
      execute(~s{DROP TABLE IF EXISTS "#{schema}".events_p})
    end
  end
end
