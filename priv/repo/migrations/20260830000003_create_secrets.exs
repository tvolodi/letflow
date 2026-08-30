# Letflow.Repo.Migrations.CreateSecrets
#
# REQ-190. Implements lib/letflow/design/req190-secrets-core.md section 1 (the
# `secrets` table) per docs/migration/decisions/0016-secrets-storage-backend.md
# section A/B/D/E (REVIEWER sign-off GRANTED 2026-08-30).
#
# GLOBAL-SCHEMA MIGRATION -- deliberately NOT tenant-scoped. This is the
# REVIEWER-sign-off-gated exception 0016 section B establishes (envelope-
# encrypted secret resolution needs one query surface before the caller's
# tenant is even known from a connection prefix -- resolve/2's own
# caller_tenant == reference_tenant check is the application-level substitute
# for the schema boundary, run before any decryption). This migration carries
# NO `if prefix() do ... end` guard (that guard is exclusively for
# tenant-scoped tables) and is NOT registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- it runs exactly
# once against `public`, via a plain `mix ecto.migrate`, the same precedent
# `20260819000004_drop_legacy_public_identity_tables.exs` already establishes
# for a global-schema migration in this codebase (that migration's own header:
# "deliberately NOT listed [in tenant_scoped_migrations/0] -- it is a
# global-schema migration").
#
# Column list, closed enums, and index shape: design doc section 1.1/1.4/1.5,
# verbatim. `wrap_nonce`/`wrap_auth_tag` column names are this design's own
# naming choice (0016 does not name them) -- see design doc section 9 OQ-1.
#
# `id` is the explicit `:binary_id` primary key (no default primary-key
# generator), same idiom as `webhook_subscriptions`/`dlq_entries`/`tasks`.
#
# `created_at`/`created_by`/`disabled_at`/`deleted_at` are explicit columns,
# not `timestamps/1` -- a secret row is immutable once written (insert-only,
# `disable/2` is the one exception, updating only `status`/`disabled_at`), and
# no acceptance criterion needs an `updated_at` column (design doc section
# 1.1).
#
# UNIQUE (tenant_id, namespace, name, key_id) -- 0016 section A, verbatim --
# doubles as put/2's next-key_id lookup index and resolve/2's pinned-reference
# lookup index (design doc section 1.5).
#
# idx_secrets_lookup on (tenant_id, namespace, name, status, created_at DESC)
# backs resolve/2's unpinned-reference query
# (WHERE tenant_id = $1 AND namespace = $2 AND name = $3 AND status = 'active'
# ORDER BY created_at DESC LIMIT 1) as an index-only scan (design doc section
# 1.5, 0016 section E).
#
# No index on tenant_id alone -- consistent with every other table's
# precedent in this codebase (design doc section 1.5): the column is a filter
# predicate, not by itself the isolation mechanism, since this table's
# isolation mechanism is resolve/2's own explicit application-level check.
defmodule Letflow.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  def change do
    create table(:secrets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tenant_id, :binary_id, null: false

      add :namespace, :string, null: false
      add :name, :string, null: false
      add :key_id, :integer, null: false

      add :purpose, :string, null: false
      add :status, :string, null: false, default: "active"

      add :algorithm, :string, null: false
      add :wrapped_key_algorithm, :string, null: false

      add :ciphertext, :binary, null: false
      add :wrapped_data_key, :binary, null: false
      add :nonce, :binary, null: false
      add :wrap_nonce, :binary, null: false
      add :auth_tag, :binary, null: false
      add :wrap_auth_tag, :binary, null: false
      add :aad, :binary, null: false

      add :wrapping_key_ref, :string, null: false
      add :wrapping_key_version, :integer, null: false, default: 1

      add :created_at, :utc_datetime, null: false
      add :created_by, :string, null: false
      add :disabled_at, :utc_datetime
      add :deleted_at, :utc_datetime
    end

    create unique_index(:secrets, [:tenant_id, :namespace, :name, :key_id],
             name: :secrets_tenant_namespace_name_key_id_index
           )

    create index(:secrets, [:tenant_id, :namespace, :name, :status, :created_at],
             name: :idx_secrets_lookup
           )
  end
end
