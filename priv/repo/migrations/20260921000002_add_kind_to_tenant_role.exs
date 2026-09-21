# Letflow.Repo.Migrations.AddKindToTenantRole
#
# ISS-0774 (`lib/letflow/design/iss-0774-role-domain-authorization.md` §2.1) --
# splits `tenant_role.name`'s single, string-shape-guessed domain into an
# explicit, DB-level `kind` (`:platform_role` | `:process_routing_role`), cast
# through `Ecto.Enum` at the schema layer (`Letflow.Identity.TenantRole`),
# matching this codebase's established `Ecto.Enum`-over-a-string-column
# convention (`Letflow.Identity.User.status`/`auth_source`,
# `Letflow.Identity.Tenant.status`) rather than a Postgres-native enum type.
#
# PLACEMENT: PER-TENANT (schema-per-tenant via `prefix()`), matching
# `tenant_role` itself (REQ-063) -- this migration only adds one column (plus
# its backing index) to that already-tenant-scoped table.
#
# TENANT-SCOPED MIGRATION -- the `if prefix() do` guard below is MANDATORY,
# and this file's registration in
# Letflow.TenantProvisioning.tenant_scoped_migrations/0 (both halves are
# mandatory -- see that module's own manifest comment).
#
# BACKFILL (design §2.1): a one-time, deterministic reclassification of every
# PRE-EXISTING row using the exact same closed-set test
# `Letflow.Api.Authorization.role_from_string/1` already encodes -- not a new
# judgement call, a restatement of the judgement the codebase already makes
# today, now persisted instead of re-derived from string shape on every read.
# `kind = 'platform_role'` where `name` is one of the six literal strings
# `Letflow.Api.Authorization.roles/0` maps to string form; `kind =
# 'process_routing_role'` for every other existing row (including any row
# whose `name` happens not to be one of the six -- the open-ended domain).
#
# `up/0`/`down/0` (not a bare `change/0`) because the backfill step
# (`repo().update_all/3`) is not a DDL command Ecto can auto-reverse --
# mirrors 20260918173137_seed_default_tenant.exs's own up/down shape for the
# identical reason (a data-mutating step alongside DDL).
#
# `flush/0` after each `alter table` block, BEFORE any `repo().update_all/3`
# or `create index/2` that depends on the column existing: `Ecto.Migration`
# queues DDL commands and only actually sends them to Postgres at a flush
# point (end of `up/0`, or an explicit `flush/0`) -- `repo().update_all/3`
# is a plain `Ecto.Repo` call, not a queued migration command, so without an
# explicit `flush/0` it runs immediately, against a connection that has not
# yet seen the `ADD COLUMN` DDL, and fails with
# `Postgrex.Error{postgres: %{code: :undefined_column, ...}}` (confirmed
# empirically while building this migration -- the exact failure it caused
# before this comment/fix existed).
#
# No SQL below interpolates tenant- or user-controlled data (INV-7): the
# `update_all/3` calls run through Ecto's query DSL (parameterized `where`
# clauses over a compile-time-fixed literal list), not raw SQL string
# interpolation.
defmodule Letflow.Repo.Migrations.AddKindToTenantRole do
  use Ecto.Migration
  import Ecto.Query, only: [from: 2]

  # Byte-identical to Letflow.Api.Authorization.roles/0 mapped through
  # Atom.to_string/1 -- duplicated here (not aliased) because migrations must
  # not depend on application code that can change shape independently of a
  # migration already applied in production (this codebase's established
  # migration-isolation convention; see e.g. 20260918173137_seed_default_tenant.exs's
  # own literal SQL rather than a call into Letflow.Identity).
  @platform_role_names ~w(PLATFORM_ADMIN PROCESS_DESIGNER PROCESS_OPERATOR TASK_WORKER AGENT_RUNNER CANDIDATE)

  def up do
    if prefix() do
      schema = prefix()

      alter table(:tenant_role, prefix: schema) do
        add :kind, :string, null: true
      end

      flush()

      repo().update_all(
        from(t in "tenant_role", where: t.name in ^@platform_role_names),
        [set: [kind: "platform_role"]],
        prefix: schema
      )

      repo().update_all(
        from(t in "tenant_role", where: t.name not in ^@platform_role_names),
        [set: [kind: "process_routing_role"]],
        prefix: schema
      )

      alter table(:tenant_role, prefix: schema) do
        modify :kind, :string, null: false
      end

      create index(:tenant_role, [:kind], prefix: schema)
    end
  end

  def down do
    if prefix() do
      schema = prefix()

      drop index(:tenant_role, [:kind], prefix: schema)

      alter table(:tenant_role, prefix: schema) do
        remove :kind
      end
    end
  end
end
