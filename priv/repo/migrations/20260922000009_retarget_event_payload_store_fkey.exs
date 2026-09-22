# Letflow.Repo.Migrations.RetargetEventPayloadStoreFkey
#
# REQ-376, migration 9 of 9 (post-hoc addition -- see design doc section 2.1's
# updated migration list and decision 0037's third "Implementation-discovered
# correction" section for the full incident writeup). Fixes a real,
# load-bearing FK-correctness defect left behind by migration 4
# (20260922000004_swap_events_partitioned.exs): `event_payload_store`'s
# composite FK (`event_payload_store_event_id_fkey`,
# 20260816120004_create_event_payload_store.exs) still references the
# renamed-aside `events_pre_partition_20260922` table instead of the new
# partitioned `events` table.
#
# ROOT CAUSE: Postgres foreign-key constraints bind to their target table by
# OID internally, not by name. `ALTER TABLE events RENAME TO
# events_pre_partition_20260922` followed by `ALTER TABLE events_p RENAME TO
# events` (migration 4) renames both tables but does NOT retarget any FK that
# pointed at the original `events` OID -- it silently keeps pointing at the
# now-renamed-away table. Confirmed directly against `tenant_template`
# (`\d tenant_template.event_payload_store`): the constraint's own
# `REFERENCES` clause names `events_pre_partition_20260922` verbatim, in a
# fully `replay_migrations`-provisioned schema, not just a `:clone`-path test
# fixture. This means any `event_payload_store` insert for an event created
# AFTER the partition swap needs a matching row in the frozen,
# no-longer-written-to `events_pre_partition_20260922` table -- an FK
# violation on every such insert, which is exactly what TEST-DESIGNER's
# rework1 traced 50/261 full-suite failures to.
#
# SCOPE CONFIRMED NARROW: grepped every `priv/repo/migrations/*.exs` for
# `references(:events` and `references(:events_archive` --
# `event_payload_store`'s single composite FK
# (20260816120004_create_event_payload_store.exs) is the ONLY foreign key
# anywhere in this codebase's tenant schema that references either `events`
# or `events_archive`. `events_archive` has zero incoming FKs (no migration
# ever declares `references(:events_archive`), so migration 8's identical
# rename-based swap
# (20260922000008_swap_events_archive_partitioned.exs) introduced no
# equivalent defect -- nothing to fix there.
#
# FIX: drop the stale constraint and recreate it by NAME against `events`
# (unqualified) -- Postgres resolves that name reference against the
# CURRENT `events` table (the new partitioned one, post-swap), correctly
# binding to its OID. Same column list, same ON DELETE RESTRICT, same
# constraint name (`event_payload_store_event_id_fkey`, Ecto's default
# `#{table}_#{column}_fkey` shape) as the original migration -- this is a
# retarget, not a redesign; ON DELETE RESTRICT's rationale
# (20260816120004_create_event_payload_store.exs's own header comment,
# REQ-026 archival must not silently lose archived-event payloads) is
# unchanged and still applies against the new partitioned `events` table.
#
# Ecto's `drop_constraint`/`constraint` DSL do not cleanly express a
# composite-column FK's `REFERENCES parent(col1, col2)` shape (confirmed
# against the original migration's own header comment, which hit the same
# limitation and used a bare `references/2` column option instead -- there is
# no DSL equivalent for an ALTER-time add on an existing table with a
# multi-column reference), so this migration uses `execute/1,2` for both
# halves, matching the style already established by migrations 4 and 8
# (`if prefix() do` guard, raw DDL) for this exact requirement's DDL that the
# DSL cannot express.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.tenant_scoped_migrations/0 --
# both halves are mandatory.
defmodule Letflow.Repo.Migrations.RetargetEventPayloadStoreFkey do
  use Ecto.Migration

  def up do
    if prefix() do
      schema = prefix()

      execute(~s{
        ALTER TABLE "#{schema}".event_payload_store
        DROP CONSTRAINT event_payload_store_event_id_fkey
      })

      execute(~s{
        ALTER TABLE "#{schema}".event_payload_store
        ADD CONSTRAINT event_payload_store_event_id_fkey
        FOREIGN KEY (event_id, event_created_at)
        REFERENCES "#{schema}".events (event_id, created_at)
        ON DELETE RESTRICT
      })
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      execute(~s{
        ALTER TABLE "#{schema}".event_payload_store
        DROP CONSTRAINT event_payload_store_event_id_fkey
      })

      execute(~s{
        ALTER TABLE "#{schema}".event_payload_store
        ADD CONSTRAINT event_payload_store_event_id_fkey
        FOREIGN KEY (event_id, event_created_at)
        REFERENCES "#{schema}".events_pre_partition_20260922 (event_id, created_at)
        ON DELETE RESTRICT
      })
    end
  end
end
