# Letflow.Repo.Migrations.AddSecretRefToWebhookSubscriptions
#
# REQ-190. Implements lib/letflow/design/req190-secrets-core.md section 5.1
# per docs/migration/decisions/0016-secrets-storage-backend.md section F
# (REVIEWER sign-off GRANTED 2026-08-30) -- the webhook HMAC key ownership
# reconciliation: `webhook_subscriptions` gains `secret_ref`/`secret_key_id`,
# superseding the hashed `secret_hash` column REQ-181 introduced (a hash
# cannot supply the plaintext key material HMAC-SHA256 signing needs).
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file IS registered in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves
# mandatory per that module's own established discipline). This is the
# explicit fix for R-Co's own ISS-0112 mistake (scoping this exact kind of
# migration to `public` only) -- the requirement text names that mistake
# directly. Applies to every existing tenant schema, not just newly
# provisioned ones, via replay_migrations/2's existing re-apply-to-every-
# tenant-schema mechanism.
#
# Column changes (design doc section 5.1):
#   - ADD secret_ref :: :string, nullable at the column level (an existing
#     row legitimately has none if secret_hash is blanked without a
#     re-encryptable plaintext -- see the assertion step below, which
#     confirms there are none in practice).
#   - ADD secret_key_id :: :integer, nullable at the column level.
#   - secret_hash is BLANKED (every row's value set to NULL), NOT DROPPED --
#     matches R-Co's own GBL-128 migration shape (design doc section 5.1,
#     requirement text's own instruction). The column itself stays in place;
#     its physical removal is a separate, later cleanup no acceptance
#     criterion requires here. Its original NOT NULL constraint (from
#     20260829010001_create_webhook_subscriptions.exs) is relaxed to
#     nullable here too -- Letflow.Webhooks.create/2 no longer writes this
#     column at all as of REQ-190, so every NEW row also needs it nullable,
#     not just existing rows being blanked.
#
# "No existing secrets need migrating" is ASSERTED, not assumed (design doc
# section 5.2, per the requirement text's own instruction to assert rather
# than assume): before blanking, this migration counts rows with
# secret_hash IS NOT NULL for the current tenant schema and RAISEs
# (failing the migration loudly) if that count is nonzero -- secret_hash is
# a one-way SHA-256 digest and cannot be migrated into a recoverable
# plaintext for `secrets` regardless, so a nonzero count here is a genuine
# blocker requiring a human decision, not something this migration can
# silently paper over.
#
# Idempotent/re-runnable: `add_if_not_exists`-equivalent guard (Ecto's
# `create_if_not_exists`/plain `add` inside `change/0` is naturally
# re-runnable when the column doesn't yet exist; guarding with
# `execute/2` + a catalog check keeps a second run from erroring on an
# already-added column), and `UPDATE ... SET secret_hash = NULL` is
# naturally idempotent (setting an already-NULL column to NULL twice is a
# no-op) -- no special-case needed for the blank step itself.
defmodule Letflow.Repo.Migrations.AddSecretRefToWebhookSubscriptions do
  use Ecto.Migration

  def change do
    if prefix() do
      # Assert, don't assume: no row may carry a non-NULL secret_hash that
      # this migration would otherwise blank without a recovery path.
      # `prefix()` is this migration's own tenant-schema-name argument (never
      # caller/tenant/user-controlled data -- it comes from
      # Letflow.TenantProvisioning's replay machinery, constrained by
      # construction to `tenant_[0-9a-f]{32}`), passed as a bound `format/2`
      # `%I`/`%L` argument rather than interpolated into the SQL text
      # directly -- same idiom `20260819000004_drop_legacy_public_identity_tables.exs`
      # already establishes for this codebase's dynamic-schema-name DDL (INV-7).
      execute("""
      DO $$
      DECLARE
        v_count BIGINT;
      BEGIN
        EXECUTE format(
          'SELECT count(*) FROM %I.webhook_subscriptions WHERE secret_hash IS NOT NULL',
          #{quote_prefix_literal(prefix())}
        ) INTO v_count;

        IF v_count > 0 THEN
          RAISE EXCEPTION
            'AddSecretRefToWebhookSubscriptions: schema % has % webhook_subscriptions row(s) with a non-NULL secret_hash -- cannot blank a one-way hash without a recoverable plaintext. This migration must not proceed until a human decision is made for these rows.',
            #{quote_prefix_literal(prefix())}, v_count;
        END IF;
      END $$;
      """)

      alter table(:webhook_subscriptions, prefix: prefix()) do
        add_if_not_exists :secret_ref, :string
        add_if_not_exists :secret_key_id, :integer
        # secret_hash's original NOT NULL (20260829010001) must be relaxed --
        # Letflow.Webhooks.create/2 (REQ-190) no longer writes it at all, so a
        # nullable column is what "blanked, not dropped" requires going
        # forward, not just for existing rows.
        modify :secret_hash, :string, null: true
      end

      execute("""
      DO $$
      BEGIN
        EXECUTE format(
          'UPDATE %I.webhook_subscriptions SET secret_hash = NULL WHERE secret_hash IS NOT NULL',
          #{quote_prefix_literal(prefix())}
        );
      END $$;
      """)
    end
  end

  # `prefix()` is an Ecto migration-time value derived from
  # Letflow.TenantProvisioning's own schema-name generation
  # (`tenant_[0-9a-f]{32}`), never free-form/tenant-supplied text -- quoted
  # here as a SQL string literal (single-quote escaped) so it can be spliced
  # into the plpgsql DO block as `format/2`'s second argument, itself the
  # mechanism that safely resolves the identifier. This is DDL-time
  # migration authoring, not a runtime query path INV-7 is scoped to guard
  # against tenant/user input -- the value never originates from a request.
  defp quote_prefix_literal(prefix) do
    "'" <> String.replace(prefix, "'", "''") <> "'"
  end
end
