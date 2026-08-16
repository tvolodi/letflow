# Letflow.Repo.Migrations.CreateEvents
#
# REQ-023, migration 1 of 6. Implements lib/letflow/design/req023-event-store-schema.md
# section 3.1 (the `events` table). Ported from R-Co migrations/001_event_store.sql's
# `events` table (behavior ported, not the raw SQL) with the shape 0003 Decision C
# point 2(a) requires from day one.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY, not
# stylistic. lib/letflow/design/req022-tenant-schema-provisioning.md section 4 states
# the reason: priv/repo/migrations/ is one shared directory, and a plain
# `mix ecto.migrate` (the ordinary dev/CI/`mix test` bootstrap) runs every .exs file in
# it with no :prefix at all. `create table(:events, prefix: prefix())` would then be
# handed `prefix: nil` and would silently create a stray, never-queried `public.events`
# on every bootstrap. Branching on `prefix()`'s truthiness and no-op-ing on the nil
# branch is what prevents that; the version is still recorded in public.schema_migrations
# having created nothing there, which is harmless bookkeeping (req022 design section 4,
# design section 2.2). The shipped reference for this shape is
# test/support/req022_migration_fixture.ex.
#
# The other mandatory half: this migration is registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0. A guarded-but-unregistered
# migration is inert forever; a registered-but-unguarded one corrupts public.
#
# PRIMARY KEY (event_id, created_at) -- composite, NOT a bare event_id. This is REQ-023
# acceptance criterion 2 and docs/migration/decisions/0003-ecto-schema-strategy.md
# Decision C point 2(a) verbatim: define it this way "from the start, even before
# partitioning exists, so the future retrofit isn't also a primary-key-shape migration".
# R-Co paid that cost later, at 1147_par01_events_partitioning.sql. Both PK components
# are NOT NULL by virtue of the PRIMARY KEY constraint Ecto emits from the two
# `primary_key: true` columns, so neither carries a redundant `null: false`.
#
# NO unique index on idempotency_key here. R-Co's 001's `uq_event_idempotency` is
# deliberately NOT ported: 0003 Decision C point 2(b) moves that invariant to the
# `event_idempotency` sidecar (migration 6), and R-Co reached the same end state at
# 1147:162-165 ("deliberately NOT recreated here -- global idempotency now lives in
# plat_event_idempotency"). Two competing sources of truth for one invariant is the
# failure mode being avoided.
#
# NO `idx_events_instance_seq` (R-Co 001:60-61) -- byte-for-byte the same column list
# and order as `uq_event_sequence` below. Not porting that redundancy follows the
# precedent req022-tenant-schema-provisioning.md:138-142 already set.
#
# NO foreign keys, deliberately (design section 3.1.3): instance_id has no FK because
# R-Co's PLATFORM_INSTANCE_ID sentinel is "Never inserted into instance_projections"
# (src/event_store/platform.zig:5); event_type has no FK because REQ-024 owns
# event_type_registry and REQ-025 enforces the relationship at the application layer;
# actor_id has no FK because `users` lives in the public schema while this table lives
# in a tenant schema (and this codebase already omits that FK -- see
# 20260816000004_create_users.exs's header).
#
# global_seq is `:bigserial` rather than R-Co's explicitly named
# `CREATE SEQUENCE events_global_seq`. Postgres creates the owning sequence in the same
# schema as the table, so it lands inside the tenant schema automatically with no prefix
# threading and no raw `execute/2` DDL (which would have required interpolating the
# schema name). Semantics are identical -- monotone, transaction-safe, gaps after
# rollback expected. Stated divergence: the generated sequence is named
# `events_global_seq_seq`, not `events_global_seq`; nothing in Letflow references it by
# name (design section 3.1.1).
#
# created_at's default is written as `(now() AT TIME ZONE 'utc')`, not bare `now()`:
# `:utc_datetime_usec` emits `timestamp` WITHOUT time zone, so a bare `now()` would be
# implicitly cast from timestamptz using the session's local time zone. REQ-025 binds
# this value explicitly anyway (the same value must reach events, event_idempotency and
# event_payload_store -- design INV-EV-5); the default is a safety net only.
defmodule Letflow.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:events, primary_key: false, prefix: prefix()) do
        add :event_id, :binary_id, primary_key: true

        add :created_at, :utc_datetime_usec,
          primary_key: true,
          default: fragment("(now() AT TIME ZONE 'utc')")

        add :instance_id, :binary_id, null: false
        add :event_type, :string, null: false
        add :payload, :map, null: false, default: %{}
        add :actor_id, :binary_id, null: false
        add :sequence_number, :bigint, null: false
        add :idempotency_key, :string, null: false
        add :metadata, :map, null: false, default: %{}
        add :global_seq, :bigserial, null: false
        add :tenant_id, :binary_id, null: false
      end

      create unique_index(:events, [:instance_id, :sequence_number],
               name: :uq_event_sequence,
               prefix: prefix()
             )

      create index(:events, [:global_seq], name: :idx_events_global_seq, prefix: prefix())

      create index(:events, [:instance_id, :created_at],
               name: :idx_events_instance_time,
               prefix: prefix()
             )

      create index(:events, [:event_type], name: :idx_events_type, prefix: prefix())
    end
  end
end
