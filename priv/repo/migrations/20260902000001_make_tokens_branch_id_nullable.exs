# Letflow.Repo.Migrations.MakeTokensBranchIdNullable
#
# ISS-0408 -- see lib/letflow/design/iss0408-join-token-record-insert-fix.md
# for the fix this migration supports. Discovered mid-implementation (not
# anticipated by that design, which stated "no new schema usage" -- flagged
# here rather than silently worked around, per this project's own rule
# against quietly re-deciding a settled invariant).
#
# THIS IS AN ADDENDUM to REQ-043's already-shipped `tokens` table
# (20260818110002_create_tokens.exs), NOT a new table -- one column's
# NOT NULL constraint is relaxed.
#
# Why: `Letflow.Engine.Token.branch_id` (the pure struct, REQ-044 §3) has
# always been typed `String.t() | nil` -- `nil` documented from REQ-044 as
# meaning "a token that has never passed through a parallel split."
# REQ-051's own design doc (`req051-parallel-gateway-split-join.md`, the
# `fire_join/5` construction) deliberately extends that same `nil` meaning
# to also cover "has passed through a split and rejoined at a
# PARALLEL_GATEWAY join" -- a documented, on-record REQ-051 decision, not a
# regression this migration second-guesses.
#
# The `tokens` DB table's own `branch_id` column, however, was created
# `null: false` (20260818110002) and its changeset
# (`Letflow.Engine.TokenRecord.insert_changeset/2`) carries a matching
# `validate_required(:branch_id)` -- both written before any code path ever
# actually tried to INSERT a join-merged token (the pre-ISS-0408 gap: no
# Multi step existed that persisted one; a join firing straight to :END
# never reaches insert_token_records/4 at all, since dispatch_end/3 drops
# the token first). ISS-0408's fix is the first code path to insert a
# TokenRecord row for a join-merged token, and it surfaces this real,
# previously-latent NOT NULL/validate_required mismatch against REQ-051's
# own documented `nil` semantics. This migration brings the DB column (and
# the companion changeset edit in the same commit) in line with the pure
# struct's type and REQ-051's own decision, rather than inventing a
# synthetic non-nil placeholder value with no basis in any design doc.
#
# Additive/reversible: `null: false` -> nullable is a pure constraint
# relaxation, safe on a live table with existing non-null rows (every row
# inserted before this migration keeps its own non-null branch_id
# unchanged) and trivially reversible (Ecto.Migration's `change/0` DSL
# generates the down migration `modify :branch_id, :string, null: false`
# automatically from this same call, per its own inverse-tracking for
# `modify/3`).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching every other `tokens`-table migration. Registered in
# Letflow.TenantProvisioning.@tenant_scoped_migration_manifest.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- the
# `alter table` call is pure Ecto DSL.
defmodule Letflow.Repo.Migrations.MakeTokensBranchIdNullable do
  use Ecto.Migration

  def change do
    if prefix() do
      alter table(:tokens, prefix: prefix()) do
        modify :branch_id, :string, null: true
      end
    end
  end
end
