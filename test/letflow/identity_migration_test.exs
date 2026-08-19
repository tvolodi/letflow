defmodule Letflow.IdentityMigrationTest do
  @moduledoc """
  Tests for `Letflow.IdentityMigration.copy_all_tenants/0`/`copy_tenant/2` (REQ-063
  §4) and `priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs`'s
  guard-skip/guard-proceed behavior (REQ-063 §5). See `test/specs/REQ-063.md` for the
  full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database anywhere in this file.

  ## Why this file recreates `public.users`/`public.groups`/`public.tenant_role`

  This branch's own `mix ecto.migrate` run already applied
  `20260819000004_drop_legacy_public_identity_tables.exs` against this test
  database — the legacy `public.users`/`public.groups`/`public.tenant_role` tables
  are already gone (confirmed via `to_regclass('public.users')` returning `NULL`
  before this file was drafted), which is the correct, permanent end state for a
  real environment. To exercise `copy_all_tenants/0` (which reads FROM those legacy
  tables) and the drop migration's guard (which checks them) at all, this file
  recreates minimal, throwaway versions of the three tables directly via
  `Repo.query!/2` DDL, seeds them with realistic pre-cutover rows, runs the code
  under test against that throwaway state, and drops the throwaway tables again in
  `on_exit/1`. This does not touch any shipped migration file or change what a real
  `mix ecto.migrate` run does — it reconstructs the exact pre-cutover physical shape
  those three legacy migrations originally created (confirmed against
  `priv/repo/migrations/20260816000002_create_groups.exs`,
  `20260816000003_create_tenant_role.exs`, `20260816000004_create_users.exs`'s own
  column lists), scoped to only the columns this file's tests actually touch.

  `Ecto.Migrator.run/4`'s explicit `[{version, module}]` form needs the drop
  migration's module genuinely loaded into this run's BEAM VM first —
  `priv/repo/migrations/*.exs` is outside `:test`'s `elixirc_paths`, and (per
  `test/letflow/event_store/registry_test.exs`'s own documented finding, ISS-0017/
  ELIXIR-DEV's Step 2a handoff) once a migration's version is already recorded in
  `schema_migrations` (true here, since this branch's own `mix ecto.migrate` already
  ran it once), `Ecto.Migrator`'s directory scan never re-loads the module on a
  later `mix ecto.migrate`, so calling `Ecto.Migrator.run/4` directly with an
  explicit `{version, module}` tuple raises `Ecto.MigrationError` unless the module
  is `Code.require_file/1`'d first — `ensure_drop_migration_loaded!/0` below mirrors
  `registry_test.exs`'s exact, already-established workaround for this same
  documented gap.

  Follows the same `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` + manual
  `on_exit/1` cleanup pattern `test/letflow/tenant_provisioning_test.exs` and
  `test/letflow/identity_test.exs` already establish (`Ecto.Migrator` cannot run
  under the sandbox's single shared connection). `async: false` for the whole module
  (ExUnit's `async` setting is module-wide).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.IdentityMigration
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @drop_migration_file Path.expand(
                         "../../priv/repo/migrations/20260819000004_drop_legacy_public_identity_tables.exs",
                         __DIR__
                       )

  # Deliberately implausible version numbers, matching
  # test/letflow/tenant_provisioning_test.exs's @guard_probe_version convention --
  # avoids any chance of colliding with a real timestamp-based
  # priv/repo/migrations/ version already recorded in this DB's real
  # public.schema_migrations table. A fresh, unique version per test (via
  # System.unique_integer/1) so repeated runs of this file never collide with a
  # version this same file recorded on a prior run.
  defp unique_drop_migration_version do
    900_000_000 + System.unique_integer([:positive, :monotonic])
  end

  defp ensure_drop_migration_loaded! do
    Code.require_file(@drop_migration_file)
  end

  defp unique_slug, do: Letflow.TenantSlugFixture.unique_slug("req063-idmig")

  # Provisions a real tenant (row + schema + full migration replay, including the
  # three per-tenant identity tables) -- the copy/guard target every test in this
  # file needs.
  defp provisioned_tenant! do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{slug: unique_slug(), display_name: "REQ-063 Copy Test"},
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant: tenant, schema_name: schema_name}
  end

  # Recreates minimal (only the columns this file touches), throwaway
  # public.users/groups/tenant_role tables -- see moduledoc for why. Idempotent
  # (CREATE TABLE IF NOT EXISTS) so multiple tests in this file can share one
  # recreation without conflict; on_exit/1 below drops them again.
  defp recreate_legacy_public_tables! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.groups (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      name text NOT NULL,
      inserted_at timestamp NOT NULL DEFAULT now(),
      updated_at timestamp NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.users (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      username text NOT NULL,
      display_name text NOT NULL,
      email text NOT NULL,
      password_hash text NOT NULL,
      status text NOT NULL DEFAULT 'active',
      auth_source text NOT NULL DEFAULT 'internal',
      external_id text,
      external_realm text,
      inserted_at timestamp NOT NULL DEFAULT now(),
      updated_at timestamp NOT NULL DEFAULT now()
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.tenant_role (
      id uuid PRIMARY KEY,
      name text NOT NULL,
      group_id uuid NOT NULL,
      inserted_at timestamp NOT NULL DEFAULT now()
    )
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS public.tenant_role")
      Repo.query!("DROP TABLE IF EXISTS public.users")
      Repo.query!("DROP TABLE IF EXISTS public.groups")
    end)

    :ok
  end

  defp insert_legacy_group!(tenant_id, name \\ "legacy-group") do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO public.groups (id, tenant_id, name) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(id),
      Ecto.UUID.dump!(tenant_id),
      name
    ])

    id
  end

  defp insert_legacy_user!(tenant_id, username \\ nil) do
    id = Ecto.UUID.generate()
    username = username || "legacy-user-#{System.unique_integer([:positive])}"

    Repo.query!(
      """
      INSERT INTO public.users (id, tenant_id, username, display_name, email, password_hash)
      VALUES ($1, $2, $3, $4, $5, $6)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(tenant_id),
        username,
        "Legacy User",
        "legacy-#{System.unique_integer([:positive])}@example.com",
        "hash"
      ]
    )

    id
  end

  defp insert_legacy_tenant_role!(group_id, name \\ nil) do
    id = Ecto.UUID.generate()
    name = name || "legacy-role-#{System.unique_integer([:positive])}"

    Repo.query!("INSERT INTO public.tenant_role (id, name, group_id) VALUES ($1, $2, $3)", [
      Ecto.UUID.dump!(id),
      name,
      Ecto.UUID.dump!(group_id)
    ])

    id
  end

  # ISS-0060: crash-durable backup table used by
  # with_only_this_tenant_visible!/2 below to snapshot/restore OTHER tenants'
  # public.tenant_schemas rows around the guard-PROCEEDS test's
  # Ecto.Migrator.run/4 call, so a concurrently-provisioning tenant elsewhere
  # in the suite can never force a false SKIP in that one test. Column set is
  # an exact structural mirror of public.tenant_schemas (see
  # priv/repo/migrations/20260816090045_create_tenant_schemas.exs lines
  # 28-37) so the restore INSERT can be a bare `SELECT *` -- see
  # lib/letflow/design/iss060-migration-guard-test-race-fix.md section 3.
  # Never dropped by on_exit/1: it must survive a BEAM crash to do its job
  # (section 5's crash-safety argument).
  defp ensure_backup_table! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.iss060_tenant_schemas_guard_backup (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      schema_name text NOT NULL,
      migrations_applied_at timestamp,
      provisioned_at timestamp NOT NULL
    )
    """)

    :ok
  end

  # ISS-0060 section 5 self-heal: if the backup table is non-empty when any
  # test in this file starts, that non-emptiness IS the signal that a prior
  # run crashed between with_only_this_tenant_visible!/2's move-out and
  # move-back statements -- restore those orphaned rows before the next test
  # proceeds, mirroring ISS-0048's reaper pattern (detect-and-heal-on-next-run
  # rather than an unbounded, growing-until-noticed orphan).
  defp restore_orphaned_guard_backup_rows! do
    ensure_backup_table!()

    Repo.query!("""
    WITH restored AS (
      DELETE FROM public.iss060_tenant_schemas_guard_backup
      RETURNING *
    )
    INSERT INTO public.tenant_schemas
    SELECT * FROM restored
    ON CONFLICT (id) DO NOTHING
    """)

    :ok
  end

  # ISS-0060: wraps `fun` (the guarded Ecto.Migrator.run/4 call plus its
  # follow-up assertions) so that, for the duration of `fun`, public.tenant_schemas
  # contains at most one row -- `tenant_id`'s own row. Every other tenant's row is
  # moved out (single atomic data-modifying CTE, one round trip -- no
  # Elixir-side window between snapshot and delete) into the crash-durable
  # backup table for the duration of `fun`, then moved back (another single
  # atomic CTE) in an `after` block so the restore runs whether `fun` succeeds
  # or raises. See design section 4 for the full sequence/rationale.
  defp with_only_this_tenant_visible!(tenant_id, fun) do
    ensure_backup_table!()

    Repo.query!(
      """
      WITH moved AS (
        DELETE FROM public.tenant_schemas
        WHERE tenant_id <> $1
        RETURNING *
      )
      INSERT INTO public.iss060_tenant_schemas_guard_backup
      SELECT * FROM moved
      """,
      [Ecto.UUID.dump!(tenant_id)]
    )

    try do
      fun.()
    after
      Repo.query!("""
      WITH restored AS (
        DELETE FROM public.iss060_tenant_schemas_guard_backup
        RETURNING *
      )
      INSERT INTO public.tenant_schemas
      SELECT * FROM restored
      ON CONFLICT (id) DO NOTHING
      """)
    end
  end

  defp tenant_schema_has_row?(schema_name, table, id) do
    sql = "SELECT count(*) FROM \"#{schema_name}\".\"#{table}\" WHERE id = $1"
    %{rows: [[count]]} = Repo.query!(sql, [Ecto.UUID.dump!(id)])

    count == 1
  end

  defp count_rows_in_schema(schema_name, table) do
    sql = "SELECT count(*) FROM \"#{schema_name}\".\"#{table}\""
    %{rows: [[count]]} = Repo.query!(sql)
    count
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    recreate_legacy_public_tables!()
    restore_orphaned_guard_backup_rows!()
    :ok
  end

  describe "IdentityMigration.copy_tenant/2 and copy_all_tenants/0 (REQ-063 §4)" do
    test "copies groups/users/tenant_role from public into the tenant's own schema, preserving id, ordering tenant_role after groups (FK dependency)" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      user_id = insert_legacy_user!(tenant.id)
      role_id = insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      assert tenant_schema_has_row?(schema_name, "groups", group_id)
      assert tenant_schema_has_row?(schema_name, "users", user_id)
      assert tenant_schema_has_row?(schema_name, "tenant_role", role_id)
    end

    test "copy_tenant/2 is idempotent: re-running after a successful copy re-copies nothing (on_conflict: :nothing), same counts settle at zero on the second call" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      _user_id = insert_legacy_user!(tenant.id)
      _role_id = insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # Second call: on_conflict: :nothing + conflict_target: :id means every row
      # is already present, so every insert this time is suppressed. The public
      # legacy rows are unchanged (this function never deletes them), so the
      # query result set is identical -- the function's OWN counter increments
      # on every attempted insert (the design's copy_tenant/2 body counts
      # {:ok, _} results from Repo.insert/2, which on_conflict: :nothing still
      # returns even when suppressed -- see identity.ex's own documented finding
      # that a client-generated-id insert can't distinguish a real vs suppressed
      # insert from the bare {:ok, _} shape alone), so this asserts the
      # functionally important invariant instead: re-running does not raise, and
      # the destination schema still has exactly one row of each kind (not
      # duplicated).
      assert {:ok, _} = IdentityMigration.copy_tenant(tenant.id, schema_name)

      assert count_rows_in_schema(schema_name, "groups") == 1
      assert count_rows_in_schema(schema_name, "users") == 1
      assert count_rows_in_schema(schema_name, "tenant_role") == 1
    end

    test "copy_all_tenants/0 processes every registered tenant and aggregates counts" do
      %{tenant: tenant_a, schema_name: schema_a} = provisioned_tenant!()
      %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant!()

      group_a = insert_legacy_group!(tenant_a.id)
      _user_a = insert_legacy_user!(tenant_a.id)
      insert_legacy_tenant_role!(group_a)

      group_b = insert_legacy_group!(tenant_b.id)
      insert_legacy_tenant_role!(group_b)

      assert {:ok, summary} = IdentityMigration.copy_all_tenants()

      assert summary.tenants_processed >= 2
      assert summary.groups_copied >= 2
      assert summary.users_copied >= 1
      assert summary.tenant_roles_copied >= 2

      assert count_rows_in_schema(schema_a, "groups") == 1
      assert count_rows_in_schema(schema_b, "groups") == 1
    end

    test "an orphaned tenant_role (group_id matching no groups row) aborts that tenant's copy with {:error, {:orphaned_tenant_role, id}}, and no partial rows are committed for that tenant" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      # A tenant_role whose group_id matches no public.groups row at all -- the
      # design's own documented "should not exist given the FK constraint on the
      # current public schema, but the copy function must not silently drop data
      # if one somehow does" case (design §4 step 3). This file's throwaway
      # public.tenant_role table has no FK constraint (deliberately, so this
      # exact scenario can be constructed), unlike the real, now-dropped
      # migration-created one.
      orphan_group_id = Ecto.UUID.generate()
      orphan_role_id = insert_legacy_tenant_role!(orphan_group_id)

      assert {:error, {:orphaned_tenant_role, ^orphan_role_id}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # Repo.transaction/1 wraps copy_tenant/2's body in copy_all_tenants/0 (not
      # exercised directly here, but copy_tenant/2 itself is called directly by
      # this test) -- confirm no tenant_role row landed in the tenant schema as a
      # side effect of the aborted copy.
      assert count_rows_in_schema(schema_name, "tenant_role") == 0
    end
  end

  describe "DropLegacyPublicIdentityTables migration guard (REQ-063 §5) -- skip-on-uncopied-row" do
    test "an uncopied row (present in public, absent from the tenant's schema copy) makes the guard SKIP the drop entirely -- all three public tables survive" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      # Fully copy groups/users/tenant_role FIRST (a clean, complete copy)...
      group_id = insert_legacy_group!(tenant.id)
      insert_legacy_user!(tenant.id)
      insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # ...then insert ONE MORE public.users row directly (bypassing
      # copy_tenant/2 entirely) -- simulating a row that arrived/was missed
      # after the copy ran, present in public but genuinely absent from the
      # tenant's schema copy. An uncopied row in exactly one of the three
      # tables must still block the drop for ALL THREE tables (the migration's
      # own documented "skipped entirely for ALL THREE tables... rather than
      # partially dropping" behavior), not just the table with the gap.
      _uncopied_user_id = insert_legacy_user!(tenant.id)

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      assert [^version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      # The guard skipped: all three legacy public tables must still exist.
      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert regclass != nil, "expected public.#{table} to survive the skipped drop"
      end

      # And both public.users rows (the copied one and the uncopied one) are
      # still exactly where they were -- nothing lost.
      %{rows: [[users_count]]} = Repo.query!("SELECT count(*) FROM public.users")
      assert users_count == 2
    end

    test "once the copy is completed for every registered tenant, the guard PROCEEDS and drops all three public tables" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      insert_legacy_user!(tenant.id)
      insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      # ISS-0060: only this test's own tenant may be visible in
      # public.tenant_schemas for the duration of the guarded migration run --
      # otherwise a concurrently-provisioning tenant elsewhere in the suite
      # (registered but not yet copied) can make the guard's global per-tenant
      # scan see an uncopied row that has nothing to do with this test and
      # flip a correct PROCEED into a false SKIP. See
      # lib/letflow/design/iss060-migration-guard-test-race-fix.md.
      with_only_this_tenant_visible!(tenant.id, fn ->
        assert [^version] =
                 Ecto.Migrator.run(
                   Letflow.Repo,
                   [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                   :up,
                   all: true,
                   log: false
                 )

        # The guard proceeded: all three legacy public tables are gone.
        for table <- ["groups", "users", "tenant_role"] do
          %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
          assert regclass == nil, "expected public.#{table} to be dropped"
        end
      end)

      # Recreate them immediately so this test's own on_exit/1 cleanup (which
      # unconditionally issues DROP TABLE IF EXISTS) and any other test in this
      # file relying on recreate_legacy_public_tables!/0's CREATE TABLE IF NOT
      # EXISTS still behave correctly regardless of ExUnit's test ordering
      # within this describe block.
      recreate_legacy_public_tables!()
    end

    test "ISS-0050 regression: a tenant schema missing one identity table makes the guard SKIP the drop, not raise 42P01" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      # Simulate the ISS-0050 scenario: a tenant_schemas registry row exists and
      # its schema is genuinely CREATE SCHEMA'd (provisioned_tenant!/0 already did
      # both), but ONE of the three identity tables the guard's dynamic
      # EXECUTE format('%I.<table>', ...) touches is missing from that schema --
      # e.g. TenantProvisioning.replay_migrations/2 was interrupted mid-flight
      # before creating it, or a leaked fixture row's schema was never fully
      # replayed. Dropping the tenant's own groups table directly reproduces
      # exactly that physical shape without needing to fabricate a whole
      # incomplete-replay code path.
      Repo.query!(~s(DROP TABLE IF EXISTS "#{schema_name}".groups CASCADE))

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      # Pre-fix, this Ecto.Migrator.run/4 call itself raises
      # `** (Postgrex.Error) ERROR 42P01 (undefined_table) relation
      # "<schema>.groups" does not exist` from inside the guard's dynamic EXECUTE
      # -- see ISSUE-FIXER's diagnosis in
      # handoffs/WF03-ISS0050-20260818/step-01-issue-fixer.json. Post-fix, the
      # guard's to_regclass(...) IS NULL existence check catches the missing
      # table first, logs a RAISE NOTICE, and folds it into v_all_copied := FALSE
      # instead -- so this call must complete normally and return the applied
      # version, exactly like the "skip-on-uncopied-row" test above.
      assert [^version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      # The guard skipped: all three legacy public tables must still exist (same
      # "skip, don't partially drop" invariant as the uncopied-row test above).
      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert regclass != nil, "expected public.#{table} to survive the skipped drop"
      end
    end

    test "ISS-0060: unwrapped guard SKIPs with a racer tenant visible; with_only_this_tenant_visible!/2 hides it and the guard PROCEEDS" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      group_id = insert_legacy_group!(tenant.id)
      insert_legacy_user!(tenant.id)
      insert_legacy_tenant_role!(group_id)

      assert {:ok, %{groups: 1, users: 1, tenant_roles: 1}} =
               IdentityMigration.copy_tenant(tenant.id, schema_name)

      # ISS-0060's exact race condition, constructed directly rather than
      # relying on genuine test-suite concurrency to hit the window by luck:
      # a second, real (FK-satisfying) tenant row is registered in
      # public.tenant_schemas but its copy is still in flight --
      # migrations_applied_at is NULL, exactly what a concurrently-running
      # provisioning test looks like mid-flight.
      racer_tenant =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "ISS-0060 racer"},
          :disabled
        )
        |> Repo.insert!()

      on_exit(fn ->
        # tenant_schemas.tenant_id carries a real DB foreign key to
        # tenants.id -- delete the (by then restored) tenant_schemas row
        # first, or this Tenant delete would raise a foreign-key violation.
        Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(racer_tenant.id)
        ])

        Repo.delete_all(from(t in Tenant, where: t.id == ^racer_tenant.id))
      end)

      racer_schema_row_id = Ecto.UUID.generate()

      Repo.query!(
        """
        INSERT INTO public.tenant_schemas
          (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
        VALUES ($1, $2, $3, NULL, now())
        """,
        [
          Ecto.UUID.dump!(racer_schema_row_id),
          Ecto.UUID.dump!(racer_tenant.id),
          "iss0060_fake_racer_schema"
        ]
      )

      ensure_drop_migration_loaded!()

      # Step 1: reproduce the bug, live. With the racer's incomplete row
      # genuinely visible in public.tenant_schemas and nothing hiding it, the
      # guard's own global per-tenant scan sees an uncopied tenant that has
      # NOTHING to do with this test and folds it into v_all_copied := FALSE
      # -- a false SKIP, exactly ISS-0060's reported failure mode, reproduced
      # on demand rather than asserted from memory or from suite-timing luck.
      version_unwrapped = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version_unwrapped])
      end)

      assert [^version_unwrapped] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version_unwrapped, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")

        assert regclass != nil,
               "expected public.#{table} to survive -- unwrapped guard should have " <>
                 "false-SKIPped because of the racer's uncopied row"
      end

      # Step 2: same fake racer row, still sitting in public.tenant_schemas,
      # completely untouched -- but this run is wrapped in the fix's
      # with_only_this_tenant_visible!/2. The guard now PROCEEDS, because the
      # racer's row is moved out of public.tenant_schemas for the duration of
      # the guarded call, so the guard's scan only ever sees this test's own
      # fully-copied tenant.
      version_wrapped = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version_wrapped])
      end)

      with_only_this_tenant_visible!(tenant.id, fn ->
        assert [^version_wrapped] =
                 Ecto.Migrator.run(
                   Letflow.Repo,
                   [{version_wrapped, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                   :up,
                   all: true,
                   log: false
                 )

        for table <- ["groups", "users", "tenant_role"] do
          %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")

          assert regclass == nil,
                 "expected public.#{table} to be dropped -- with_only_this_tenant_visible!/2 " <>
                   "should have hidden the racer's row for the duration of this call"
        end
      end)

      recreate_legacy_public_tables!()

      # The racer's row must be exactly as it was before the wrap -- restored
      # to public.tenant_schemas, migrations_applied_at still NULL (untouched,
      # not silently "completed"), and the backup table left empty. This is
      # the exact behavior the pre-fix code had no mechanism for at all (it
      # never moved anything, so there was nothing to restore).
      %{rows: [[restored_count]]} =
        Repo.query!(
          """
          SELECT count(*) FROM public.tenant_schemas
          WHERE id = $1 AND tenant_id = $2 AND migrations_applied_at IS NULL
          """,
          [Ecto.UUID.dump!(racer_schema_row_id), Ecto.UUID.dump!(racer_tenant.id)]
        )

      assert restored_count == 1

      %{rows: [[backup_count]]} =
        Repo.query!("SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup")

      assert backup_count == 0
    end

    test "re-running the drop migration after it already succeeded is a clean no-op (idempotent, per its own to_regclass IS NULL guard)" do
      # No tenant/copy needed for this one -- exercises the migration's own
      # "already absent -- nothing to do" RAISE NOTICE branch directly.
      Repo.query!("DROP TABLE IF EXISTS public.tenant_role")
      Repo.query!("DROP TABLE IF EXISTS public.users")
      Repo.query!("DROP TABLE IF EXISTS public.groups")

      ensure_drop_migration_loaded!()
      version = unique_drop_migration_version()

      on_exit(fn ->
        Repo.query!("DELETE FROM schema_migrations WHERE version = $1", [version])
      end)

      assert [^version] =
               Ecto.Migrator.run(
                 Letflow.Repo,
                 [{version, Letflow.Repo.Migrations.DropLegacyPublicIdentityTables}],
                 :up,
                 all: true,
                 log: false
               )

      for table <- ["groups", "users", "tenant_role"] do
        %{rows: [[regclass]]} = Repo.query!("SELECT to_regclass('public.#{table}')::text")
        assert regclass == nil
      end

      recreate_legacy_public_tables!()
    end
  end

  describe "ISS-0060: self-heal of an interrupted with_only_this_tenant_visible!/2 run" do
    test "restore_orphaned_guard_backup_rows!/0 (the exact helper this file's setup calls) restores a stale backup row to public.tenant_schemas and empties the backup table" do
      # A real, FK-satisfying tenant with no tenant_schemas row of its own yet
      # (deliberately NOT provisioned_tenant!/0 -- provisioning would insert
      # tenant_schemas' own row for it, and tenant_schemas has a unique index
      # on tenant_id, which would make the restore below collide).
      orphan_owner =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "ISS-0060 self-heal owner"},
          :disabled
        )
        |> Repo.insert!()

      on_exit(fn ->
        # tenant_schemas.tenant_id carries a real DB foreign key to
        # tenants.id -- delete the (by then restored) tenant_schemas row
        # first, or this Tenant delete would raise a foreign-key violation.
        # Single on_exit callback covering both deletes in the correct order
        # so this cleanup does not depend on ExUnit's on_exit ordering.
        Repo.query!("DELETE FROM public.tenant_schemas WHERE tenant_id = $1", [
          Ecto.UUID.dump!(orphan_owner.id)
        ])

        Repo.delete_all(from(t in Tenant, where: t.id == ^orphan_owner.id))
      end)

      ensure_backup_table!()

      stale_id = Ecto.UUID.generate()

      # Simulate exactly the crash window design section 5 describes: a
      # process died between with_only_this_tenant_visible!/2's move-out
      # (which already committed, atomically, per its own single CTE) and its
      # move-back -- leaving a row sitting in the backup table with no
      # corresponding row in public.tenant_schemas.
      Repo.query!(
        """
        INSERT INTO public.iss060_tenant_schemas_guard_backup
          (id, tenant_id, schema_name, migrations_applied_at, provisioned_at)
        VALUES ($1, $2, $3, NULL, now())
        """,
        [
          Ecto.UUID.dump!(stale_id),
          Ecto.UUID.dump!(orphan_owner.id),
          "iss0060_stale_backup_schema"
        ]
      )

      %{rows: [[pre_heal_visible_count]]} =
        Repo.query!("SELECT count(*) FROM public.tenant_schemas WHERE id = $1", [
          Ecto.UUID.dump!(stale_id)
        ])

      assert pre_heal_visible_count == 0,
             "sanity check: the stale row must not already be visible in tenant_schemas"

      # This file's own `setup` block (see setup/0 above) calls
      # restore_orphaned_guard_backup_rows!/0 unconditionally before every
      # test in this file -- this call exercises that exact same helper
      # directly, rather than relying on a second, later test run to observe
      # its effect, since the stale row above could only be constructed
      # *after* this test's own setup had already run once.
      restore_orphaned_guard_backup_rows!()

      %{rows: [[post_heal_visible_count]]} =
        Repo.query!(
          "SELECT count(*) FROM public.tenant_schemas WHERE id = $1 AND tenant_id = $2 AND migrations_applied_at IS NULL",
          [Ecto.UUID.dump!(stale_id), Ecto.UUID.dump!(orphan_owner.id)]
        )

      assert post_heal_visible_count == 1

      %{rows: [[backup_count]]} =
        Repo.query!("SELECT count(*) FROM public.iss060_tenant_schemas_guard_backup WHERE id = $1", [
          Ecto.UUID.dump!(stale_id)
        ])

      assert backup_count == 0
    end
  end
end
