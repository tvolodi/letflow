# Letflow.Repo.Migrations.CreateEventPayloadStore
#
# REQ-023, migration 4 of 6. Implements lib/letflow/design/req023-event-store-schema.md
# section 3.4 (the `event_payload_store` side table). Ported from R-Co
# migrations/012_event_retention.sql:16-22 and its composite-FK rebuild at
# 1147_par01_events_partitioning.sql:215-223. This is the side table for payloads over
# 4096 bytes (event_store.md's "Payload size boundary" invariant).
#
# MUST SORT AFTER 20260816120001_create_events.exs -- it carries a foreign key to
# `events`.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260816120001_create_events.exs's header for the full rationale. Registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- both halves are mandatory.
#
# COMPOSITE FOREIGN KEY (event_id, event_created_at) -> events(event_id, created_at).
# Mandatory, not a choice: `events`' primary key is composite, so a single-column FK
# would have no unique constraint to reference. R-Co hit exactly this at 1147:209-223.
# The `references/2` call takes NO :prefix option -- a %Reference{} with none falls back
# to the referencing table's own prefix
# (deps/ecto_sql/lib/ecto/adapters/postgres/connection.ex:1872), so the FK stays inside
# the tenant schema automatically.
#
# `on_delete: :restrict`, DIVERGING from R-Co's ON DELETE CASCADE (012:18, 1147:222) --
# decided, with rationale. Under CASCADE, REQ-026's archive/1 (which DELETEs from
# `events` after copying to `events_archive`) would silently destroy the side-table
# payload of every archived large event, leaving archived events unreadable and
# contradicting 003_event_archive.sql:6-7 ("Archived rows are moved here, not deleted").
# R-Co's CASCADE is no longer evidence about archival behaviour at all, because
# Store.archive() has been retired there (store.zig:1287-1310) -- nothing in current
# R-Co ever deletes an `events` row. `:restrict` makes the unresolved question (design
# OQ-2: how do large payloads survive archival?) fail loudly at REQ-026's first
# integration test instead of silently losing tenant data.
#
# NAMING DIVERGENCE, deliberate: `event_created_at`, not R-Co's `created_at`. R-Co's own
# `created_at` on this table means two different things in two revisions -- the row's own
# insert time at 012:21 (DEFAULT NOW()) and the *event's* created_at at 1147:218 (the FK
# component), silently swapped. Letflow splits them: `event_created_at` is the FK
# component, `inserted_at` (from timestamps/1) is this row's own time. `event_created_at`
# is the unambiguous name R-Co itself chose for the same job on webhook_deliveries
# (1147:250). See design section 10, contradiction C-3.
#
# `payload` is `:map` -> jsonb. REQ-023's own text offers the looser "text/bytea"
# phrasing; jsonb is chosen because it is R-Co's actual type in BOTH revisions
# (012:19 and 1147:219 are both JSONB) and it keeps read-time payload splicing
# type-uniform with `events.payload`. No acceptance criterion constrains the choice.
#
# NO CHECK constraint on byte_size > 4096 -- REQ-023 states the boundary is "enforced at
# the append logic layer in REQ-025, not the migration layer". A DB-level duplicate
# would create a second source of truth with a different error shape.
#
# The single-column unique index on event_id is kept (rather than R-Co's later composite
# UNIQUE (event_id, created_at) at 1147:221): single-column uniqueness is strictly
# stronger (one payload row per event, full stop), it matches REQ-023's own wording, and
# the composite constraint the FK needs is satisfied on the parent side by `events`' own
# primary key.
defmodule Letflow.Repo.Migrations.CreateEventPayloadStore do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:event_payload_store, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true

        add :event_id,
            references(:events,
              column: :event_id,
              with: [event_created_at: :created_at],
              type: :binary_id,
              on_delete: :restrict
            ),
            null: false

        add :event_created_at, :utc_datetime_usec, null: false
        add :payload, :map, null: false
        add :byte_size, :integer, null: false

        timestamps(updated_at: false)
      end

      create unique_index(:event_payload_store, [:event_id],
               name: :uq_event_payload_event,
               prefix: prefix()
             )
    end
  end
end
