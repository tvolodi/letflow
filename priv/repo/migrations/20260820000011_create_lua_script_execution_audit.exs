# Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit
#
# REQ-058. Implements lib/letflow/design/req058-lua-script-audit.md §6 (the
# `lua_script_execution_audit` table) -- ports the persistence half of R-Co's
# `src/engine/lua_script_audit.zig` (LUA-07) per that design's own scope boundary (§1):
# only the audit-persistence path, never the real Lua execution runtime (S5,
# docs/migration/stage-5-scripting-plugins.md). See
# `Letflow.Engine.LuaScriptAudit`'s moduledoc for the full narrowness statement; this
# migration builds schema only.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY. See
# lib/letflow/design/req022-tenant-schema-provisioning.md section 4 and
# 20260818090001_create_promotion_assertion_runs.exs's header for the full rationale.
# Registered in Letflow.TenantProvisioning.@tenant_scoped_migration_manifest -- both
# halves are mandatory: a guarded-but-unregistered migration is inert forever, a
# registered-but-unguarded one corrupts `public` on every plain `mix ecto.migrate` run.
#
# MUST SORT AFTER 20260820000010_drop_tenant_id_groups.exs (the current tail as of this
# design) -- re-checked via `ls priv/repo/migrations/ | tail -5` at Step 2a per
# docs/anti-patterns.md's migration-numbering-collision class.
#
# No FK on `instance_id`/`actor_id` -- design §6.2: an audit row's purpose (attributing a
# script execution) must not be blocked by a since-archived instance/actor row, matching
# this codebase's general pattern of not FK-ing audit/event tables back to mutable
# projection state (`events`/`events_archive` carry no such FK either). No `tenant_id`
# column (Decision 0006 D2) -- the per-tenant Postgres schema alone provides isolation.
#
# `manifest_hash` carries no length/format CHECK constraint (unlike
# `promotion_assertion_runs.plan_digest`'s SHA-256-shaped validation) because S5's
# build-vs-bind decision (which determines what hash algorithm a real Lua manifest hash
# actually is) has not been made yet -- design §6.2, §9 OQ-2.
defmodule Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit do
  use Ecto.Migration

  def change do
    if prefix() do
      create table(:lua_script_execution_audit, primary_key: false, prefix: prefix()) do
        add :id, :binary_id, primary_key: true
        add :instance_id, :binary_id, null: false
        add :manifest_hash, :string, null: false
        add :actor_id, :binary_id, null: false

        add :executed_at, :utc_datetime_usec,
          null: false,
          default: fragment("(now() AT TIME ZONE 'utc')")

        timestamps(type: :utc_datetime_usec)
      end

      create index(:lua_script_execution_audit, [:instance_id],
               name: :idx_lua_script_execution_audit_instance,
               prefix: prefix()
             )
    end
  end
end
