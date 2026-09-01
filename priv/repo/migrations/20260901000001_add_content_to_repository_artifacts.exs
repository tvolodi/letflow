# Letflow.Repo.Migrations.AddContentToRepositoryArtifacts
#
# REQ-211 -- see lib/letflow/design/req211-instance-attachments-core.md §2A for
# the full design this migration implements.
#
# THIS IS AN ADDENDUM to REQ-202's already-shipped, `done`
# `repository_artifacts` table (priv/repo/migrations/20260830030001_create_repository_artifacts.exs),
# NOT a new table. It does NOT change REQ-202's own acceptance criteria or
# `done` status -- REQ-202's shape (`content_hash` PK, `tenant_id`,
# `content_type`, `byte_size`, the immutability triggers) is unchanged; one
# column is added.
#
# WHY POSTGRES bytea, NOT filesystem/object-store: per ORCH decision (design
# §2A), keep it in Postgres -- no new infrastructure dependency.
# `repository_artifacts` is already the canonical per-tenant,
# content-addressed home for this content; a `bytea` column keyed by the
# existing `content_hash` PK requires no new store, no new supervision tree,
# no new credential/config surface, and preserves REQ-202's existing
# tenant-schema isolation and immutability-trigger guarantees -- the
# `BEFORE UPDATE`/`BEFORE DELETE` triggers already installed on
# `repository_artifacts` (see the original migration) apply to the whole row
# including this new column with zero additional work.
#
# `null: false` IS INTENTIONAL, NOT AN OVERSIGHT REQUIRING A BACKFILL: at the
# time this addendum ships, no `repository_artifacts` rows exist yet anywhere
# in this codebase -- REQ-202's `create/2` has no live caller prior to
# REQ-211/`Letflow.Repository.Attachments.upload/2`, the first real caller
# (design §2A). If a future audit finds a live caller with rows already
# persisted before this addendum ships, a backfill strategy (or relaxing to
# nullable with a follow-up tightening migration) is required -- named here as
# a contingency, not something this migration resolves.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# matching the original migration's own guard, and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment). This table is
# per-tenant, so the ALTER must run once per tenant schema exactly as the
# original CREATE TABLE did.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- the
# `alter table` call is pure Ecto DSL, no raw `execute/2` SQL is needed for
# this addendum (unlike the original migration's trigger functions).
defmodule Letflow.Repo.Migrations.AddContentToRepositoryArtifacts do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:repository_artifacts, prefix: schema) do
        add :content, :binary, null: false
      end
    end
  end
end
