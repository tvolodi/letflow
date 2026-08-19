defmodule Letflow.EventStore.MigrationsTest do
  @moduledoc """
  Integration tests for REQ-023's six `priv/repo/migrations/20260816120001..120006_*.exs`
  migrations and for `Letflow.TenantProvisioning.tenant_scoped_migrations/0`'s manifest,
  run against real Postgres through REQ-022's provision-then-replay mechanism. See
  `test/specs/REQ-023.md` for the full test-case rationale and the WF-02 Step 3
  scope-test verdict.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  Like `test/letflow/tenant_provisioning_test.exs`, and for the same empirically
  established reason, the `Ecto.Migrator`-touching describe blocks below do NOT run
  inside DataCase's normal rolled-back sandbox transaction: `Ecto.Migrator` needs a
  second, genuinely independent database connection beyond the one this process has
  checked out (it takes a lock on `schema_migrations`), which a sandboxed pool will not
  hand out -- the call fails with `DBConnection.ConnectionError ... :queue_timeout`.
  Those blocks therefore switch `Letflow.Repo` to `Ecto.Adapters.SQL.Sandbox` `:auto`
  mode and clean up the real schemas and rows they create in `on_exit/1` instead of
  relying on rollback.

  `async: false` for the whole module (ExUnit's `async` setting is module-wide, not
  per-test): ExUnit fully drains every `async: true` module before starting any sync
  module and runs sync modules strictly one at a time, so the `:auto`-mode switch has no
  other test's connection to disturb. The pure, no-I/O half of REQ-023's coverage lives
  in `test/letflow/event_store/schemas_test.exs`, which is `async: true`.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Event
  alias Letflow.EventStore.IdempotencyRecord
  alias Letflow.EventStore.StoredPayload
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # table name => the Ecto.Schema module that reads it (design §5.1).
  @event_store_tables %{
    "events" => Letflow.EventStore.Event,
    "events_archive" => Letflow.EventStore.ArchivedEvent,
    "event_idempotency" => Letflow.EventStore.IdempotencyRecord,
    "event_payload_store" => Letflow.EventStore.StoredPayload,
    "instance_projections" => Letflow.EventStore.InstanceProjection,
    "instance_sequence" => Letflow.EventStore.InstanceSequence
  }

  @req023_migration_modules [
    Letflow.Repo.Migrations.CreateEvents,
    Letflow.Repo.Migrations.CreateInstanceSequence,
    Letflow.Repo.Migrations.CreateInstanceProjections,
    Letflow.Repo.Migrations.CreateEventPayloadStore,
    Letflow.Repo.Migrations.CreateEventsArchive,
    Letflow.Repo.Migrations.CreateEventIdempotency
  ]

  # Synthetic migration versions for the §4 guard test. Far below any real
  # timestamp-shaped version (20260816120001 and friends) and far from the 999_999_999
  # probe test/letflow/tenant_provisioning_test.exs already uses, so nothing collides.
  # The offset comes from System.unique_integer([:positive, :monotonic]) -- a VM
  # counter, not an RNG and not a clock.
  @guard_probe_version_base 990_000_000

  # Fixed literals, never DateTime.utc_now/0 -- no test in this project may depend on
  # wall-clock time (docs/guides/test_developer_guide.md principle 3). Uniqueness of
  # these values is irrelevant: every test that uses them does so inside a tenant schema
  # no other test can see.
  @fixed_event_created_at ~U[2026-01-02 03:04:05.000000Z]

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # oidc_mode: :disabled avoids Tenant.create_changeset/3's idp_realm_id requirement --
  # irrelevant to anything this file tests, matching identity_test.exs's and
  # tenant_provisioning_test.exs's own use of :disabled.
  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req023"),
        display_name: "REQ-023 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp columns_in(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
        [schema_name, table_name]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # Ordered primary-key columns. Order matters: (created_at, event_id) would satisfy a
  # set-equality check while being the wrong shape for the partitioning retrofit 0003
  # Decision C point 2(a) exists to preserve.
  defp primary_key_columns(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT kcu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
         AND tc.constraint_schema = kcu.constraint_schema
         AND tc.table_name = kcu.table_name
        WHERE tc.constraint_type = 'PRIMARY KEY'
          AND tc.table_schema = $1
          AND tc.table_name = $2
        ORDER BY kcu.ordinal_position
        """,
        [schema_name, table_name]
      )

    List.flatten(rows)
  end

  # {index_name, index_definition} for every index on a table. pg_indexes, not
  # information_schema.table_constraints: Ecto's `create unique_index(...)` emits
  # CREATE UNIQUE INDEX, not ALTER TABLE ... ADD CONSTRAINT UNIQUE, so the constraint
  # views do not list it at all and a test written against them would pass vacuously.
  defp indexes_on(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [schema_name, table_name]
      )

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  defp public_tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
        []
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp migrations_dir do
    Path.join([Application.app_dir(:letflow, "priv"), "repo", "migrations"])
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "priv/repo/migrations gains migrations for events,
  # instance_sequence, event_payload_store, events_archive, the idempotency sidecar
  # table, and instance_projections, all using Ecto's :prefix option and applying
  # cleanly against at least one provisioned tenant schema via REQ-022's
  # migration-replay mechanism"
  #
  # ...plus acceptance criteria 2 and 4's database-level halves, which need the same
  # provisioned-and-migrated tenant schema this setup builds.
  #
  # Each test gets its own tenant, its own physical schema and its own Registration row
  # -- no identifier is shared between tests, and on_exit drops everything, because
  # these tests genuinely commit (see this module's moduledoc).
  # ---------------------------------------------------------------------------------

  describe "the six event-store migrations replayed into a provisioned tenant schema" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      tenant = insert_tenant!()

      assert {:ok, %Registration{schema_name: schema_name}} =
               TenantProvisioning.provision_tenant_schema(tenant.id)

      on_exit(fn ->
        drop_schema!(schema_name)
        Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
        Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
      end)

      assert {:ok, applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

      %{tenant: tenant, schema_name: schema_name, applied_versions: applied_versions}
    end

    test "replay_migrations/2 applies every registered tenant-scoped migration and all six event-store tables land in the tenant's own schema, never in public",
         %{tenant: tenant, schema_name: schema_name, applied_versions: applied_versions} do
      registered_versions =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 0))

      assert applied_versions == registered_versions

      for {table, _module} <- @event_store_tables do
        # The table exists under the tenant's own schema...
        assert table_exists_in_schema?(schema_name, table),
               "#{table} is missing from tenant schema #{schema_name}"

        # ...and does NOT exist under public. This half is what proves :prefix is doing
        # the work: a migration that ignored :prefix and wrote to the default schema
        # would still satisfy a naive "does the table exist" check.
        refute table_exists_in_schema?("public", table),
               "#{table} leaked into the public schema -- the :prefix guard is not working"
      end

      # REQ-022's own observable that the replay ran to completion rather than partially.
      assert %Registration{migrations_applied_at: %NaiveDateTime{}} =
               Repo.get_by(Registration, tenant_id: tenant.id)
    end

    test "each event-store table's real column set in the tenant schema matches its Ecto.Schema module's field list exactly",
         %{schema_name: schema_name} do
      # "Applies cleanly" is necessary but not sufficient: a migration can apply cleanly
      # and still disagree with the schema module that reads it, which surfaces much
      # later as a runtime Postgrex error in REQ-025. Equality, not subset -- an extra
      # column on either side is drift too. This is also acceptance criterion 5's
      # structural guard: if S3's engine-owned columns (definition_id, correlation_key,
      # current_nodes, ...) ever leaked into instance_projections' migration, the
      # moduledoc scope claim would silently become false, and this assertion is what
      # catches it.
      for {table, module} <- @event_store_tables do
        expected = module.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()

        assert columns_in(schema_name, table) == expected,
               "#{table}'s columns disagree with #{inspect(module)}.__schema__(:fields)"
      end
    end

    test "tenant_scoped_migrations/0 registers all six REQ-023 event-store migrations" do
      # req022-tenant-schema-provisioning.md §4: both halves are mandatory and
      # independent. A guarded-but-unregistered migration is inert forever (never
      # selected by replay_migrations/2, so no tenant schema ever gets the table); a
      # registered-but-unguarded one corrupts public. The §4 guard test below covers the
      # other half.
      registered_modules =
        TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 1))

      for module <- @req023_migration_modules do
        assert module in registered_modules,
               "#{inspect(module)} is not registered in tenant_scoped_migrations/0 -- it would never reach any tenant schema"
      end
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 2: "events' migration defines the primary key as
    # (event_id, created_at), not a bare event_id, per 0003 Decision C point 2(a)"
    # -------------------------------------------------------------------------------

    test "events' physical primary key in the tenant schema is (event_id, created_at), in that order, not a bare event_id",
         %{schema_name: schema_name} do
      assert primary_key_columns(schema_name, "events") == ["event_id", "created_at"]

      # Stated as its own assertion so a failure reads against the criterion's own
      # wording ("not a bare event_id").
      refute primary_key_columns(schema_name, "events") == ["event_id"]
    end

    test "events_archive carries the same composite primary key -- an archived event is the same row",
         %{schema_name: schema_name} do
      assert primary_key_columns(schema_name, "events_archive") == ["event_id", "created_at"]
    end

    test "instance_projections and instance_sequence use instance_id as their natural primary key",
         %{schema_name: schema_name} do
      assert primary_key_columns(schema_name, "instance_projections") == ["instance_id"]
      assert primary_key_columns(schema_name, "instance_sequence") == ["instance_id"]
    end

    # -------------------------------------------------------------------------------
    # Acceptance criterion 4: "the idempotency sidecar table has a unique index on
    # idempotency_key and its own moduledoc states it supersedes event_store.md's Open
    # Question #1 two-phase-check recommendation per 0003's resolution"
    #
    # The moduledoc half is asserted in schemas_test.exs. The two tests below are the
    # structural facts that prose describes.
    # -------------------------------------------------------------------------------

    test "the idempotency sidecar carries a real unique index on idempotency_key",
         %{schema_name: schema_name} do
      indexes = indexes_on(schema_name, "event_idempotency")

      assert Map.has_key?(indexes, "uq_event_idempotency_key"),
             "uq_event_idempotency_key is missing, found: #{inspect(Map.keys(indexes))}"

      definition = Map.fetch!(indexes, "uq_event_idempotency_key")

      assert String.starts_with?(definition, "CREATE UNIQUE INDEX"),
             "uq_event_idempotency_key is not UNIQUE: #{definition}"

      assert String.ends_with?(definition, "(idempotency_key)"),
             "uq_event_idempotency_key does not cover exactly idempotency_key: #{definition}"
    end

    test "neither events nor events_archive carries a unique index on idempotency_key -- the sidecar is the single enforcement point",
         %{schema_name: schema_name} do
      # The executable form of the word "supersedes" in acceptance criterion 4, and
      # design INV-EV-3. Two competing sources of truth for one invariant is the failure
      # mode being avoided; R-Co reached the same end state by REMOVING both of these
      # indexes at migrations/1147_par01_events_partitioning.sql. Without this test
      # someone could add unique_index(:events, [:idempotency_key]) back and every other
      # test here would still pass.
      for table <- ["events", "events_archive"] do
        competing =
          schema_name
          |> indexes_on(table)
          |> Enum.filter(fn {_name, definition} ->
            String.contains?(definition, "UNIQUE") and
              String.contains?(definition, "idempotency_key")
          end)

        assert competing == [],
               "#{table} carries a competing unique index on idempotency_key: #{inspect(competing)}"
      end
    end

    test "a second row claiming the same idempotency_key is rejected by uq_event_idempotency_key",
         %{schema_name: schema_name} do
      # Tests above assert the index exists and is unique; this asserts it actually
      # bites, against real Postgres, through the real insert_changeset/2 path with
      # :prefix threaded through -- exactly how REQ-025's append will hit it. The error
      # SHAPE matters too: if the changeset's declared constraint name and the real
      # index name ever drift apart, this raises Ecto.ConstraintError instead of
      # returning {:error, changeset}, which this assertion catches.
      claimed_key = "req023-idem-#{System.unique_integer([:positive, :monotonic])}"

      assert {:ok, _first} =
               %IdempotencyRecord{}
               |> IdempotencyRecord.insert_changeset(%{
                 idempotency_key: claimed_key,
                 event_id: Ecto.UUID.generate(),
                 event_created_at: @fixed_event_created_at
               })
               |> Repo.insert(prefix: schema_name)

      assert {:error, changeset} =
               %IdempotencyRecord{}
               |> IdempotencyRecord.insert_changeset(%{
                 idempotency_key: claimed_key,
                 event_id: Ecto.UUID.generate(),
                 event_created_at: @fixed_event_created_at
               })
               |> Repo.insert(prefix: schema_name)

      assert %{idempotency_key: ["has already been taken"]} = errors_on(changeset)
    end

    # -------------------------------------------------------------------------------
    # Beyond the five acceptance criteria: REVIEWER's Step 2d instruction that
    # event_payload_store's ON DELETE RESTRICT is design OQ-2's deliberate signal and
    # must NOT be "fixed" into a CASCADE. This test asserts the behaviour and changes
    # nothing, so a future flip to :delete_all fails here loudly rather than being
    # discovered as data loss in REQ-026.
    # -------------------------------------------------------------------------------

    test "deleting an events row that has an event_payload_store row is blocked by ON DELETE RESTRICT (design OQ-2's deliberate signal)",
         %{schema_name: schema_name} do
      event_id = Ecto.UUID.generate()

      assert {:ok, event} =
               %Event{}
               |> Event.insert_changeset(%{
                 event_id: event_id,
                 created_at: @fixed_event_created_at,
                 instance_id: Ecto.UUID.generate(),
                 event_type: "instance.started",
                 payload: %{"$ref" => Ecto.UUID.generate()},
                 actor_id: Ecto.UUID.generate(),
                 sequence_number: 1,
                 idempotency_key:
                   "req023-restrict-#{System.unique_integer([:positive, :monotonic])}"
               })
               |> Repo.insert(prefix: schema_name)

      # The composite FK is (event_id, event_created_at) -> events(event_id, created_at):
      # inserting with the event's own pair proves both columns are wired, since a
      # single-column FK would not accept -- or would not be constrained by -- the
      # second.
      assert {:ok, _payload} =
               %StoredPayload{}
               |> StoredPayload.insert_changeset(%{
                 event_id: event_id,
                 event_created_at: @fixed_event_created_at,
                 payload: %{"large" => String.duplicate("x", 32)},
                 byte_size: 5000
               })
               |> Repo.insert(prefix: schema_name)

      # Under CASCADE this delete would succeed and silently destroy the side-table
      # payload, leaving the archived event unreadable (design INV-EV-12), directly
      # contradicting R-Co's migrations/003_event_archive.sql:6-7 ("Archived rows are
      # moved here, not deleted"). RESTRICT makes REQ-026's unanswered OQ-2 fail loudly
      # instead.
      assert_raise Ecto.ConstraintError, fn ->
        Repo.delete(event, prefix: schema_name)
      end

      assert Repo.get_by(Event, [event_id: event_id], prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # Carry-forward 1 (REVIEWER, REQ-022 Step 2d): the §4 guard test.
  #
  # req022-tenant-schema-provisioning.md §4 requires every tenant-scoped migration to
  # branch on Ecto.Migration.prefix()'s truthiness and no-op on the nil branch, so a
  # plain `mix ecto.migrate` (which passes no :prefix at all) does not silently create
  # stray public.events / public.instance_sequence / ... tables on every dev and CI
  # bootstrap. REVIEWER suggested this test during REQ-022's own review; it was not
  # writable then because tenant_scoped_migrations/0 returned [] and there was nothing
  # to iterate (see test/specs/REQ-022.md case 14). REQ-023 populates that list, so it
  # becomes writable here -- and it now enforces §4 mechanically for every FUTURE
  # tenant-scoped migration, rather than relying on each future author having read the
  # design doc.
  # ---------------------------------------------------------------------------------

  describe "§4 guard pattern -- every registered tenant-scoped migration is a real no-op without a prefix" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      migrations = TenantProvisioning.tenant_scoped_migrations()

      # Synthetic, never-before-applied versions, so Ecto.Migrator genuinely executes
      # each change/0 instead of skipping it as already-applied. Reusing the real
      # versions would make this test pass vacuously -- they are already recorded in
      # public.schema_migrations by the `mix test` alias's ecto.migrate step.
      probe_versions =
        Enum.map(migrations, fn _migration ->
          @guard_probe_version_base + System.unique_integer([:positive, :monotonic])
        end)

      tables_before = public_tables()

      on_exit(fn ->
        for version <- probe_versions do
          Repo.query!(~s(DELETE FROM "schema_migrations" WHERE version = $1), [version])
        end

        # Defensive cleanup that can never touch pre-existing state: drops every table
        # that appeared in public during this test (ISS-0028/GH#86 -- previously
        # filtered through a hand-maintained allowlist that drifted behind
        # tenant_scoped_migrations/0's manifest twice; that allowlist is gone, this
        # drops the actual stray set directly, so it can never drift behind the
        # manifest again). Sound because this describe block is async: false (module-
        # wide) with no other test touching Postgres in this window, so anything new in
        # `strays` can only be something one of the migrations just run under a probe
        # version created -- exactly what this test asserts never happens in the
        # passing case, making this a no-op then and only firing when the guard pattern
        # it's testing has actually regressed.
        strays = MapSet.difference(public_tables(), tables_before)

        for table <- strays do
          Repo.query!(~s(DROP TABLE IF EXISTS "public"."#{table}" CASCADE))
        end
      end)

      %{migrations: migrations, probe_versions: probe_versions, tables_before: tables_before}
    end

    test "every migration registered in tenant_scoped_migrations/0 creates nothing in public when run with no :prefix (§4 guard pattern)",
         %{migrations: migrations, probe_versions: probe_versions, tables_before: tables_before} do
      # Guards against this test silently reverting to the vacuous state it was in
      # during REQ-022, when tenant_scoped_migrations/0 returned [] and iterating it
      # asserted nothing.
      refute migrations == [],
             "tenant_scoped_migrations/0 is empty -- this guard test would assert nothing"

      for {{_version, module}, probe_version} <- Enum.zip(migrations, probe_versions) do
        # No :prefix option at all -- the real shape of a plain `mix ecto.migrate`
        # bootstrap. Ecto.Migrator.run/4 returns a bare [version] list on success (not
        # an {:ok, _} tuple), and asserting on it is what proves the migration actually
        # RAN rather than being skipped as already-applied.
        assert [probe_version] ==
                 Ecto.Migrator.run(Letflow.Repo, [{probe_version, module}], :up,
                   all: true,
                   log: false
                 ),
               "#{inspect(module)} did not run under probe version #{probe_version}"
      end

      assert public_tables() == tables_before,
             "a registered tenant-scoped migration created something in public when run with no :prefix -- §4's guard pattern is missing or broken in one of: #{inspect(Enum.map(migrations, &elem(&1, 1)))}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Carry-forward 2 (REVIEWER, REQ-023 Step 2d): manifest version-to-filename
  # consistency. The manifest's version integer and its filename string are two
  # independent literals, so a wrong-but-unique version number would be caught by
  # nothing today: the module still loads, replay_migrations/2 still succeeds, and the
  # version recorded in the tenant's schema_migrations silently stops corresponding to
  # any real file.
  #
  # No :auto mode and no tenant schema needed -- tenant_scoped_migrations/0 does file
  # I/O only.
  # ---------------------------------------------------------------------------------

  describe "tenant_scoped_migrations/0 manifest consistency" do
    test "each registered migration's version matches the numeric prefix of the file it was actually loaded from" do
      migrations = TenantProvisioning.tenant_scoped_migrations()

      refute migrations == [], "tenant_scoped_migrations/0 is empty -- nothing to check"

      for {version, module} <- migrations do
        # tenant_scoped_migrations/0's own contract: it loads each listed module before
        # returning it. If the manifest's filename element pointed at a file that does
        # not define this module, this is where that shows up.
        assert Code.ensure_loaded?(module),
               "#{inspect(module)} is not loaded -- tenant_scoped_migrations/0's manifest filename does not define it"

        # module_info(:compile)[:source] is the path the module was ACTUALLY loaded
        # from -- the load-bearing fact, not a re-derivation of the naming convention.
        # Compared by basename because the loading path differs between `mix
        # ecto.migrate`'s in-VM compile (the project's own priv/) and
        # tenant_scoped_migrations/0's Code.require_file (Application.app_dir's copy
        # under _build/), while the basename is identical in both.
        loaded_basename =
          module.module_info(:compile)
          |> Keyword.fetch!(:source)
          |> List.to_string()
          |> Path.basename()

        expected_basename =
          "#{version}_#{Macro.underscore(List.last(Module.split(module)))}.exs"

        assert loaded_basename == expected_basename,
               "#{inspect(module)} is registered under version #{version} but was loaded from #{loaded_basename}"

        assert File.exists?(Path.join(migrations_dir(), expected_basename)),
               "#{expected_basename} does not exist in #{migrations_dir()}"
      end
    end

    test "registered migration versions are unique and strictly ascending" do
      versions = TenantProvisioning.tenant_scoped_migrations() |> Enum.map(&elem(&1, 0))

      assert versions == Enum.uniq(versions),
             "duplicate versions in the manifest: #{inspect(versions)}"

      assert versions == Enum.sort(versions),
             "the manifest is documented as being in ascending version order, got: #{inspect(versions)}"
    end
  end
end
