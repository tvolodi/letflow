# Letflow.Repo.Migrations.BackfillExamTenantModules
#
# REQ-409 -- P2: tenant-scoped migration backfilling a `tenant_modules` exam
# row for every tenant whose GLOBAL `solution_pack_installs` table has a row
# with pack_id 'bilimbaga-question-bank'.
#
# PLACEMENT: per-tenant -- the module install ledger lives in the tenant's
# own schema, per 0039 D5.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in `Letflow.TenantProvisioning`'s
# `@tenant_scoped_migration_manifest` (both halves are mandatory).
#
# No SQL string below interpolates tenant- or user-controlled data (INV-7).
# The schema name is system-derived from `prefix()` (not caller-supplied);
# the tenant UUID is passed as a parameterized query argument ($1).
#
# The insert is idempotent: ON CONFLICT (module_id) DO NOTHING -- running
# this migration twice leaves exactly one exam row (or zero, if no
# bilimbaga-question-bank install exists for this tenant).
#
# `solution_pack_installs` is a GLOBAL table (public schema). It is qualified
# as `public.solution_pack_installs` to work correctly regardless of the
# current search_path set by `Ecto.Migrator` for the tenant schema.
#
# No `on_install/2` runs -- this is a data backfill, not a fresh install.
# No new table is created, so `@expected_tenant_tables` in
# `Letflow.TenantFixture` does not change.
defmodule Letflow.Repo.Migrations.BackfillExamTenantModules do
  use Ecto.Migration

  # Exam manifest version at the time REQ-409 lands -- matches the `version:`
  # field in `lib/letflow/modules/exam/exam.ex`'s `defmanifest/1` call
  # exactly.  A compile-time constant, not a runtime lookup, because (a) the
  # manifest version is stable once shipped and (b) calling
  # `Letflow.Modules.Exam.manifest/0` from a migration would couple the
  # migration's re-run semantics to any future version bump.
  @exam_version "0.1.0"

  def change do
    if prefix() do
      schema = prefix()

      # Derive the tenant UUID from the system-generated schema name (e.g.
      # "tenant_<32 hex chars>").  `tenant_id_for_schema_name/1` is a pure
      # string function -- no DB call.  The `{:error, :invalid_schema_name}`
      # branch handles non-real-tenant schemas such as "tenant_template"
      # (the test-template schema produced by `Letflow.Test.TenantTemplate`)
      # which share the "tenant_" prefix but are not real tenants.
      case Letflow.TenantProvisioning.tenant_id_for_schema_name(schema) do
        {:ok, tenant_id} ->
          # `tenant_id_for_schema_name/1` returns the canonical string form
          # (e.g. "aabbccdd-...").  Postgrex encodes UUID parameters as 16-byte
          # binary when the column type is uuid, so we dump to the wire form.
          {:ok, tenant_id_bin} = Ecto.UUID.dump(tenant_id)

          Letflow.Repo.query!(
            """
            INSERT INTO "#{schema}".tenant_modules (id, module_id, version, installed_at, settings)
            SELECT gen_random_uuid(), 'exam', '#{@exam_version}', NOW(), '{}'::jsonb
            WHERE EXISTS (
              SELECT 1 FROM public.solution_pack_installs
              WHERE tenant_id = $1
                AND pack_id = 'bilimbaga-question-bank'
            )
            ON CONFLICT (module_id) DO NOTHING
            """,
            [tenant_id_bin]
          )

        {:error, :invalid_schema_name} ->
          # Non-real-tenant schema (e.g. test-only "tenant_template") -- no
          # action.  This is the same guard `tenant_id_for_schema_name/1`'s
          # caller in `Letflow.TenantProvisioning` applies when it encounters
          # a schema it cannot resolve to a real tenant id.
          :ok
      end
    end
  end
end
