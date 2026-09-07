# Letflow.Repo.Migrations.AddScanStatusToInstanceAttachments
#
# ISS-0399 -- see lib/letflow/design/iss0399-attachment-content-scanning.md
# §1 for the full design this migration implements.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), matching
# `instance_attachments` itself (REQ-211,
# 20260901000002_create_instance_attachments.exs) -- this migration only adds
# one column to that existing tenant-scoped table.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment).
#
# DB-level default of "pending" (not "clean") is deliberate, fail-closed
# behavior (design §1.1): any pre-existing row (inserted before this
# migration ships, in any environment) must never silently read as scanned-
# clean. App code (Letflow.Repository.Attachments.upload/2) always
# explicit-sets `:clean` on every new insert going forward -- `:infected`/
# `:error` are never written by upload/2 itself, only ever read back via a
# pre-existing/backfilled row.
#
# No SQL below interpolates tenant- or user-controlled data (INV-7) -- plain
# Ecto migration DSL only, identical in kind to the shipped migration's own
# INV-7 statement.
defmodule Letflow.Repo.Migrations.AddScanStatusToInstanceAttachments do
  use Ecto.Migration

  def change do
    if prefix() do
      schema = prefix()

      alter table(:instance_attachments, prefix: schema) do
        add :scan_status, :string, null: false, default: "pending"
      end
    end
  end
end
