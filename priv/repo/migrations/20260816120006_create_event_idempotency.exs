# Letflow.Repo.Migrations.CreateEventIdempotency
#
# REQ-023, migration 6 of 6. Implements lib/letflow/design/req023-event-store-schema.md
# section 3.5 (the idempotency sidecar). Ported from R-Co
# migrations/1147_par01_events_partitioning.sql:200-207's `plat_event_idempotency`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# TABLE NAME: `event_idempotency`, NOT R-Co's `plat_event_idempotency`. REQ-023 leaves
# the choice to the implementer and asks for a citation either way. R-Co's `plat_`
# prefix denotes a platform/cross-tenant table, and R-Co's own design doc flags this
# specific table as an exception to its own convention: "one new `plat_`-prefixed table
# that is *itself* per-tenant ... this is NOT the cross-tenant
# platform.platform_migrations case" (src/design/par-01-monthly-range-partitioning.md:
# 203-209), confirmed by 1147:31-46's PER_TENANT classification. Letflow's sidecar is
# unambiguously per-tenant -- 0003's closing paragraph: "a cross-tenant-shared sidecar
# table would reintroduce exactly the shared-table blast-radius risk Decision B
# rejected". Carrying over a prefix whose meaning Letflow's own design rejects would
# import a known misnomer, so the prefix is dropped and the domain-meaningful part of
# the name is preserved -- exactly what 0003 Decision A prescribes.
#
# WHY THIS TABLE EXISTS AND WHAT IT SUPERSEDES (REQ-023 acceptance criterion 4; stated
# in full in Letflow.EventStore.IdempotencyRecord's moduledoc): 0003 Decision C point
# 2(b) resolves event_store.md's "Open Question #1" -- which had recommended a two-phase
# deduplication check (INSERT into events with ON CONFLICT (idempotency_key) DO NOTHING,
# then a fallback SELECT against events_archive) -- in favour of this sidecar table,
# adopted from day one rather than deferred to partitioning time. R-Co itself abandoned
# the two-phase recommendation: 1147:162-165 and 1147:192-193 remove the unique indexes
# from `events` and `events_archive` respectively, and store.zig:588-598 writes the
# sidecar first, in the same transaction. Neither `events` nor `events_archive` carries a
# unique index on idempotency_key in Letflow; `uq_event_idempotency_key` below is the
# single enforcement point for the whole ES-03 invariant.
#
# `id` is a binary_id surrogate PK per 0003 Decision A (REQ-023's exception list does not
# include this table), which is why the uniqueness of idempotency_key is expressed as an
# explicit unique INDEX rather than as R-Co's `idempotency_key TEXT PRIMARY KEY`
# (1147:201).
#
# NO foreign key to `events`, deliberately: the claimed event may legitimately live in
# `events` OR `events_archive` (R-Co additionally searches events_ephemeral --
# store.zig:670-675 enumerates all three), so an FK to `events` alone would break the
# moment REQ-026's archive/1 moves the row. R-Co's sidecar likewise carries no FK
# (1147:200-204).
#
# `event_created_at` rather than R-Co's `created_at` (1147:203) -- same disambiguation as
# event_payload_store: `event_created_at` is the *event's* created_at (the second half of
# the events PK, which is what lets REQ-025 resolve the original record on a duplicate
# hit), while `inserted_at` from timestamps/1 is this row's own creation time.
defmodule Letflow.Repo.Migrations.CreateEventIdempotency do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:event_idempotency, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :idempotency_key, :string, null: false
        add :event_id, :binary_id, null: false
        add :event_created_at, :utc_datetime_usec, null: false

        timestamps(updated_at: false)
      end

      create unique_index(:event_idempotency, [:idempotency_key],
               name: :uq_event_idempotency_key,
               prefix: prefix()
             )

      create index(:event_idempotency, [:event_id, :event_created_at],
               name: :idx_event_idempotency_event,
               prefix: prefix()
             )
    end
  end
end
