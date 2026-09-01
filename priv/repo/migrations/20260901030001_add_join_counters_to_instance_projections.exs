# Letflow.Repo.Migrations.AddJoinCountersToInstanceProjections
#
# ISS-0397 -- see lib/letflow/design/iss0397-join-counters-fix.md §4 for the
# full design this migration implements.
#
# THIS IS AN ADDENDUM to REQ-043's already-shipped `instance_projections`
# engine columns (priv/repo/migrations/20260818110001_alter_instance_projections_add_engine_columns.exs),
# NOT a new table. It does NOT change REQ-043's own acceptance criteria or
# `done` status -- one column is added, closing REQ-048 design doc's own
# MAJOR OQ-3 / INV-EE48-7 gap (durably persisting `Letflow.Engine.JoinCounter`
# state across separate `complete_task/3`/`advance_after_timer_fired/3`
# calls, not just within one call's own in-memory hop-chain).
#
# UNLIKE 20260901000001_add_content_to_repository_artifacts.exs's own
# "no rows exist yet" precondition, `instance_projections` DOES carry live
# rows in every provisioned tenant by this point -- every `Letflow.Engine.
# create/2` call since REQ-045 shipped inserts one. This is exactly why this
# column needs a real DB-level default (`%{}`) rather than relying on
# "table is empty" the way that addendum's header could truthfully claim.
#
# `join_counters` is `:map` (jsonb), `null: false`, `default: %{}` -- the
# identical `add :field, :map, null: false, default: %{}` idiom the
# already-shipped `variables` column on this same table uses
# (20260818110001, cited above), confirmed accepted by Ecto's migration DSL
# for a bare map literal (unlike `current_nodes`'s list-shaped case, which
# needed `fragment("'[]'::jsonb")`). The serialized shape is a JSON object
# keyed by `join_node_id` strings (design §2.2/§2.3), so no custom Ecto.Type
# is needed here.
#
# No index is added -- `join_counters` is never queried/filtered on by
# column value anywhere in this design (always read/written by `instance_id`
# primary-key lookup, which `instance_projections` already has via its own
# `@primary_key {:instance_id, ...}`).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY.
# Registered in Letflow.TenantProvisioning.@tenant_scoped_migration_manifest
# (both halves are mandatory -- see that module's own manifest comment). MUST
# SORT AFTER 20260818110001_alter_instance_projections_add_engine_columns.exs
# -- it alters that same table's own engine-columns addendum.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- the
# `alter table` call is pure Ecto DSL.
defmodule Letflow.Repo.Migrations.AddJoinCountersToInstanceProjections do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:instance_projections, prefix: prefix()) do
        add :join_counters, :map, null: false, default: %{}
      end
    end
  end
end
