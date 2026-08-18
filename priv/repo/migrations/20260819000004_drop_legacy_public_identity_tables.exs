# Letflow.Repo.Migrations.DropLegacyPublicIdentityTables
#
# Decision 0006 (docs/migration/decisions/0006-identity-tables-schema-per-tenant.md)
# section 4 step 4 -- drops the three legacy public identity tables
# (`public.tenant_role`, `public.users`, `public.groups`) after their data has been
# copied into each tenant's own schema by `mix letflow.copy_identity_tables`
# (Letflow.IdentityMigration.copy_all_tenants/0). Follows R-Co's
# `GBL-112_tnt01_drop_legacy_public_business_tables.sql` precedent of a separate,
# guarded cutover migration -- NOT bundled into
# 20260819000001/2/3_create_*_tenant_scoped.exs, per
# lib/letflow/design/req063-identity-tables-schema-per-tenant.md section 5.
#
# NOT added to Letflow.TenantProvisioning.tenant_scoped_migrations/0 -- this is a
# global-schema migration (same category as CreateTenantSchemas and the four
# original S1 identity migrations), runs exactly once via a plain
# `mix ecto.migrate`. It carries NO `prefix()` guard -- that guard pattern is
# exclusively for tenant-scoped tables; this migration is the opposite case and
# MUST run on a plain `mix ecto.migrate`, not be skipped.
#
# GUARD MECHANISM -- design section 5 explicitly left this as an open question
# (section 7 item 3): GBL-112's own guard checks a `migration_window_active` flag on
# a separate `onboarding_registry` table, which Letflow has no equivalent of.
# ENGINEERING CALL MADE HERE BY ELIXIR-DEV (flagged for REVIEWER, not silently
# invented): a per-row EXISTENCE check, not a row-count-parity check or an
# operator-set flag. Reasoning:
#   - No `onboarding_registry`-equivalent table/flag exists in Letflow today, so the
#     GBL-112 flag mechanism can't be reused verbatim without inventing new
#     migration-window-tracking infrastructure this requirement doesn't otherwise
#     need -- that would be scope creep beyond what section 1's scope boundary asks
#     for.
#   - A row-count-parity check (comparing public.<table>'s count against the sum of
#     matching rows across all tenant schemas) is weaker than it looks: it cannot
#     detect a corrupted copy where row A's data landed in the wrong tenant schema
#     while row B's went missing, if the counts still happen to balance. A per-row
#     existence check (by primary key, since `copy_tenant/2`'s inserts explicitly
#     preserve `id` verbatim -- see the design doc's section 4) closes that gap and
#     is what this migration implements.
#   - `public.tenant_schemas` (REQ-022's own registry, `schema_name` column) is a
#     safe identifier source for the dynamic `EXECUTE format(...)` below:
#     `schema_name` is never caller-supplied here -- it only ever holds values
#     `Letflow.TenantProvisioning.schema_name_for_tenant/1` produced at
#     provisioning time, which are constrained by construction to
#     `tenant_[0-9a-f]{32}` (Ecto.UUID.cast/1-derived, never free text). No
#     tenant/user input is interpolated (INV-7) -- schema_name is read back out of
#     a column this project's own provisioning code populated, not accepted as a
#     parameter to this migration.
#
# Skip behavior: if ANY row in ANY of the three public tables lacks a matching row
# (by id) in its owning tenant's schema copy, the DROP is skipped entirely for ALL
# THREE tables (logged via RAISE NOTICE) rather than partially dropping -- an
# incomplete copy for even one tenant/table is exactly the kind of partial state
# this guard exists to catch, matching the design's own stop-on-first-failure
# discipline in section 4's copy_all_tenants/0.
#
# `DROP TABLE IF EXISTS ... CASCADE`, in dependency order (tenant_role first, it FKs
# to groups) -- idempotent, matching GBL-112's own shape. No other migration in
# priv/repo/migrations/*.exs references users/groups/tenant_role from outside this
# same three-table group (confirmed by grep), so CASCADE is belt-and-suspenders
# only, matching GBL-112's own precedent.
#
# This migration must never run before the data copy (mix letflow.copy_identity_tables)
# has completed for every registered tenant -- the guard below enforces that
# mechanically rather than relying on operator discipline alone.
defmodule Letflow.Repo.Migrations.DropLegacyPublicIdentityTables do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      v_all_copied BOOLEAN := TRUE;
      v_tenant RECORD;
      v_missing_count BIGINT;
    BEGIN
      -- Only check if the legacy public tables still exist at all -- a re-run
      -- after a successful drop must no-op cleanly (idempotent), not fail because
      -- public.users/groups/tenant_role no longer exist to query.
      IF to_regclass('public.users') IS NULL
         AND to_regclass('public.groups') IS NULL
         AND to_regclass('public.tenant_role') IS NULL THEN
        RAISE NOTICE 'DropLegacyPublicIdentityTables: legacy public identity tables already absent -- nothing to do.';
        RETURN;
      END IF;

      FOR v_tenant IN SELECT tenant_id, schema_name FROM public.tenant_schemas LOOP
        -- groups: every public.groups row for this tenant must exist (by id) in
        -- the tenant's own groups copy.
        EXECUTE format(
          'SELECT count(*) FROM public.groups g WHERE g.tenant_id = %L
             AND NOT EXISTS (SELECT 1 FROM %I.groups tg WHERE tg.id = g.id)',
          v_tenant.tenant_id, v_tenant.schema_name
        ) INTO v_missing_count;

        IF v_missing_count > 0 THEN
          v_all_copied := FALSE;
          RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % missing % groups row(s) in schema %.',
            v_tenant.tenant_id, v_missing_count, v_tenant.schema_name;
        END IF;

        -- users: same check.
        EXECUTE format(
          'SELECT count(*) FROM public.users u WHERE u.tenant_id = %L
             AND NOT EXISTS (SELECT 1 FROM %I.users tu WHERE tu.id = u.id)',
          v_tenant.tenant_id, v_tenant.schema_name
        ) INTO v_missing_count;

        IF v_missing_count > 0 THEN
          v_all_copied := FALSE;
          RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % missing % users row(s) in schema %.',
            v_tenant.tenant_id, v_missing_count, v_tenant.schema_name;
        END IF;

        -- tenant_role: no tenant_id column -- partitioned via groups' tenant_id,
        -- same join shape as Letflow.IdentityMigration.copy_tenant/2 uses.
        EXECUTE format(
          'SELECT count(*) FROM public.tenant_role tr
             JOIN public.groups g ON tr.group_id = g.id
             WHERE g.tenant_id = %L
             AND NOT EXISTS (SELECT 1 FROM %I.tenant_role ttr WHERE ttr.id = tr.id)',
          v_tenant.tenant_id, v_tenant.schema_name
        ) INTO v_missing_count;

        IF v_missing_count > 0 THEN
          v_all_copied := FALSE;
          RAISE NOTICE 'DropLegacyPublicIdentityTables: tenant % missing % tenant_role row(s) in schema %.',
            v_tenant.tenant_id, v_missing_count, v_tenant.schema_name;
        END IF;
      END LOOP;

      IF NOT v_all_copied THEN
        RAISE NOTICE 'DropLegacyPublicIdentityTables: data copy incomplete for at least one tenant -- skipping DROP of legacy public identity tables. Run mix letflow.copy_identity_tables and re-migrate.';
        RETURN;
      END IF;

      DROP TABLE IF EXISTS public.tenant_role CASCADE;
      DROP TABLE IF EXISTS public.users CASCADE;
      DROP TABLE IF EXISTS public.groups CASCADE;

      RAISE NOTICE 'DropLegacyPublicIdentityTables: legacy public identity tables dropped (Decision 0006 D1 cutover complete).';
    END $$;
    """)
  end

  def down do
    # Deliberately a no-op, not a re-create of the dropped tables -- matches this
    # migration's own nature as a guarded, data-dependent cutover step rather than a
    # reversible structural change. If the drop actually ran, the per-tenant schema
    # copies (created by 20260819000001/2/3_create_*_tenant_scoped.exs) remain the
    # authoritative data; re-creating empty public tables here would be misleading,
    # not a genuine rollback. If the guard skipped the drop, there is nothing to
    # undo.
    :ok
  end
end
