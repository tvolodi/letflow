defmodule Letflow.EventStore.RegistryTest do
  @moduledoc """
  Tests for `Letflow.EventStore.Registry` (REQ-024): `register_type/2`,
  `validate_payload/3`, `get_type/2`, and the tenant-scoped
  `event_type_registry` migration. See `test/specs/REQ-024.md` for the full
  test-case rationale, including why this file needs the same
  Sandbox-`:auto`-mode + manual-cleanup pattern
  `test/letflow/tenant_provisioning_test.exs` (REQ-022) established, and the
  concurrent-insert race test added in response to ELIXIR-DEV's Step 2a
  handoff flag that the DB-level unique-constraint backstop path was
  otherwise unexercised.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file. `Letflow.EventStore.Registry.JsonSchema`'s own
  keyword-by-keyword behavior is tested independently and exhaustively in
  `test/letflow/event_store/registry/json_schema_test.exs` (a pure, `async:
  true` file) -- this file only needs enough `validate_payload/3` coverage to
  prove the DB-backed wiring (event-type lookup, tenant scoping, the
  root-level malformed/non-object-JSON short-circuit) is correct, not to
  re-derive every JSON Schema keyword's behavior again.

  `event_type_registry` is created by a **tenant-scoped** migration (guarded
  by `if prefix() do ... end`, matching every other tenant-scoped migration in
  this project) -- it does not exist under `public` at all, and only comes
  into being for a given tenant once
  `Letflow.TenantProvisioning.replay_migrations/2` has actually run against
  that tenant's schema. Every test that exercises `Registry`'s real DB paths
  therefore needs a genuinely provisioned-and-migrated tenant, built via the
  `provisioned_tenant/1` setup helper below (mirroring
  `tenant_provisioning_test.exs`'s own "replay_migrations/2 -- successful
  replay" setup exactly, including the same Sandbox-`:auto`-mode /
  `on_exit/1`-cleanup treatment and the same reasoning for why it's safe: see
  that file's moduledoc and `test/specs/REQ-022.md` for the full empirical
  investigation this file reuses rather than re-deriving).

  `async: false` for the whole module (ExUnit's `async` setting is
  module-wide, not per-test) -- required by every describe block that uses
  the `:auto`-mode `provisioned_tenant/1` helper, for the same reason
  `tenant_provisioning_test.exs` is `async: false`: this makes the mode
  switch safe against any other concurrently-running async test file (see
  that file's moduledoc for the full ExUnit-source-level proof this file
  relies on rather than re-deriving).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.EventStore.Registry.EventType
  alias Letflow.EventStore.Registry.ValidationFailure
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req024-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-024 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp unique_name(prefix \\ "EVENT_TYPE") do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp columns_in_schema(schema_name, table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = $1 AND table_name = $2",
        [schema_name, table_name]
      )

    List.flatten(rows)
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Works around a genuine functional gap ELIXIR-DEV's own Step 2a handoff
  # flagged (handoffs/WF02-REQ024-20260816/step-02a-elixir-dev.json, issue 1)
  # and this file empirically reproduces: priv/repo/migrations/*.exs files
  # are not part of :test's elixirc_paths, and Ecto.Migrator's directory scan
  # only Code.compile_file/1's a migration file when it decides that specific
  # version still needs to run -- once 20260816163103 is already recorded in
  # schema_migrations (true for any test DB that has run `mix ecto.migrate`
  # even once before, since the migration's own no-op-under-public guard
  # pattern still lets the migration "complete" and get recorded), the
  # module Letflow.Repo.Migrations.CreateEventTypeRegistry is never loaded
  # into this run's BEAM VM at all, and Ecto.Migrator.run/4's explicit
  # `[{version, module}]` form (what tenant_scoped_migrations/0 -- and hence
  # replay_migrations/2 -- actually uses) then fails with `%Ecto.
  # MigrationError{message: "module ... is not an Ecto.Migration"}`.
  # **Empirically confirmed** by running this file before adding this
  # helper: every test using provisioned_tenant/1 failed with exactly that
  # error.
  #
  # Fix, mirroring the exact technique ELIXIR-DEV's own Step 2a handoff used
  # for its manual AC1 demonstration ("Worked around ... via an explicit
  # Code.require_file/2 of the migration (mirroring what the Migrator's
  # directory-scan does internally) -- not a change to any shipped file"):
  # explicitly require the real migration file before calling
  # replay_migrations/2. Code.require_file/2 caches by path, so calling this
  # once per test (many times across this file's test run) is cheap and
  # idempotent -- it does not recompile/redefine the module on repeat calls.
  # This is a test-file-scoped workaround only; it does not touch any
  # shipped file, and it exercises the REAL migration file's REAL content
  # (not a stand-in fixture), so replay_migrations/2's actual, shipped
  # tenant_scoped_migrations/0 default is still what's under test.
  @event_type_registry_migration_file Path.expand(
                                        "../../../priv/repo/migrations/20260816163103_create_event_type_registry.exs",
                                        __DIR__
                                      )

  defp ensure_migration_module_loaded! do
    Code.require_file(@event_type_registry_migration_file)
  end

  # Shared setup helper for every describe block that needs a real,
  # provisioned-AND-migrated tenant (event_type_registry only exists once
  # replay_migrations/2 has actually run for that tenant). Mirrors
  # tenant_provisioning_test.exs's "replay_migrations/2 -- successful replay"
  # setup block exactly -- see this file's moduledoc for the full reasoning
  # (Ecto.Migrator needs a second connection the DataCase sandbox can't hand
  # out, so this switches to Sandbox :auto mode and cleans up manually in
  # on_exit/1 instead of relying on the normal rolled-back transaction).
  #
  # Used via `setup :provisioned_tenant` in each describe block that needs
  # it -- every test gets its OWN freshly-provisioned, freshly-migrated,
  # empty event_type_registry table, so no event-type-name collisions are
  # possible between tests even without per-test unique naming, though tests
  # still use unique_name/1 for clarity and defense-in-depth.
  defp provisioned_tenant(_context) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    ensure_migration_module_loaded!()

    tenant = insert_tenant!()

    # Registered immediately after the tenant row commits -- before
    # provision_tenant_schema/replay_migrations even run -- so that a
    # failure in either of THOSE steps still cleans up the tenant row (and
    # whatever schema/registration state, if any, got created before the
    # failure) rather than leaking real, committed :auto-mode data that
    # would then collide with a later run's own unique_integer-suffixed
    # slug. drop_schema!/1's IF EXISTS and Repo.delete_all/1's zero-rows
    # case both tolerate "never got that far" cleanly.
    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  # A minimal, valid register_type/2 attrs map -- every field required by
  # EventType.changeset/2 present, schema_version always the caller's choice
  # (no DB default -- design doc section 3).
  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => unique_name(),
        "schema_version" => 1,
        "json_schema" => %{"type" => "object"},
        "description" => "REQ-024 test fixture"
      },
      overrides
    )
  end

  # Registers an event type with a specific json_schema, for
  # validate_payload/3's describe block below. Asserts the registration
  # itself succeeds (a fixture-setup failure should never masquerade as the
  # test-under-assertion failing).
  defp register_fixture_type!(tenant_id, schema, name \\ nil) do
    name = name || unique_name()

    assert {:ok, %EventType{}} =
             Registry.register_type(
               valid_attrs(%{"name" => name, "json_schema" => schema}),
               tenant_id
             )

    name
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp fetch_schema_name(tenant_id) do
    %Registration{schema_name: schema_name} = Repo.get_by(Registration, tenant_id: tenant_id)
    schema_name
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "priv/repo/migrations gains an event_type_registry
  # migration (schema-per-tenant per REQ-022) applying cleanly"
  # ---------------------------------------------------------------------------------

  describe "event_type_registry migration (acceptance criterion 1)" do
    setup :provisioned_tenant

    test "applies cleanly for a real provisioned tenant: table exists under the tenant's own schema with the expected columns, and does NOT exist under public",
         %{schema_name: schema_name} do
      # provisioned_tenant/1's own replay_migrations/2 call already implicitly
      # proves the migration applies cleanly (a migration error would raise
      # inside that helper, failing setup itself for every test in this
      # describe block) -- this test goes further and confirms the specific
      # table/column shape directly via information_schema, matching
      # REQ-022's own established verification pattern
      # (tenant_provisioning_test.exs's "the migration applied cleanly" test).
      assert table_exists_in_schema?(schema_name, "event_type_registry")

      columns = columns_in_schema(schema_name, "event_type_registry")
      assert "id" in columns
      assert "name" in columns
      assert "schema_version" in columns
      assert "json_schema" in columns
      assert "description" in columns
      assert "inserted_at" in columns
      assert "updated_at" in columns

      # The tenant-scoped-migration guard pattern's own point: this table
      # must never appear under public, proving it landed under the tenant's
      # schema because of :prefix, not some accidental default (matches
      # REQ-022's own "replays ... NOT under public" assertion style).
      refute table_exists_in_schema?("public", "event_type_registry")
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "register_type/2 rejects a second registration with
  # the same (name, schema_version) with a distinct, testable error, not a
  # generic changeset failure"
  # ---------------------------------------------------------------------------------

  describe "register_type/2 (acceptance criterion 2)" do
    setup :provisioned_tenant

    test "registering a new (name, schema_version) succeeds and persists the row", %{
      tenant_id: tenant_id,
      schema_name: schema_name
    } do
      attrs = valid_attrs()

      assert {:ok, %EventType{id: id, name: name, schema_version: 1}} =
               Registry.register_type(attrs, tenant_id)

      # Re-select from Postgres directly rather than trusting the in-memory
      # reply -- matches process_instance_test.exs's/identity_test.exs's
      # established "every successful write is persisted" convention.
      assert %EventType{id: ^id, name: ^name} = Repo.get(EventType, id, prefix: schema_name)
    end

    test "registering the exact same (name, schema_version) twice returns {:error, :duplicate_event_type_version}, not a generic changeset failure" do
      # This is AC2's own literal wording, satisfied exactly as specified.
      %{tenant_id: tenant_id} = provisioned_tenant(%{})
      attrs = valid_attrs()

      assert {:ok, %EventType{}} = Registry.register_type(attrs, tenant_id)

      assert {:error, :duplicate_event_type_version} = Registry.register_type(attrs, tenant_id)
    end

    test "registering a version lower than the current maximum returns the distinct {:error, :schema_version_not_monotonic}, not :duplicate_event_type_version",
         %{tenant_id: tenant_id} do
      name = unique_name()

      assert {:ok, %EventType{}} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 2}),
                 tenant_id
               )

      assert {:error, :schema_version_not_monotonic} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 1}),
                 tenant_id
               )
    end

    test "registering a strictly greater version than the current maximum succeeds (monotonicity satisfied)",
         %{tenant_id: tenant_id} do
      name = unique_name()

      assert {:ok, %EventType{schema_version: 1}} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 1}),
                 tenant_id
               )

      assert {:ok, %EventType{schema_version: 2}} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 2}),
                 tenant_id
               )
    end

    test "an empty name is rejected via a changeset error (name presence, not a bespoke atom)",
         %{tenant_id: tenant_id} do
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Registry.register_type(valid_attrs(%{"name" => ""}), tenant_id)

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "a name longer than 128 characters is rejected via a changeset error",
         %{tenant_id: tenant_id} do
      too_long = String.duplicate("a", 129)

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Registry.register_type(valid_attrs(%{"name" => too_long}), tenant_id)

      assert %{name: [_ | _]} = errors_on(changeset)
    end

    test "schema_version 0 is rejected via a changeset error (validate_number greater_than: 0)",
         %{tenant_id: tenant_id} do
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Registry.register_type(valid_attrs(%{"schema_version" => 0}), tenant_id)

      assert %{schema_version: [_ | _]} = errors_on(changeset)
    end

    test "an explicit nil json_schema is rejected via a changeset error (validate_required)",
         %{tenant_id: tenant_id} do
      # Deliberately an explicit "json_schema" => nil, not Map.delete/2:
      # EventType's field carries `default: %{}` (design doc section 5), so
      # simply omitting the key from attrs leaves the new %EventType{}
      # struct's own default (%{}, not nil) in place -- cast/4 never touches
      # an absent key, and validate_required only flags nil (or a blank
      # string), not an empty map. An explicit nil value in attrs, by
      # contrast, IS cast (Ecto.Changeset.cast/4 processes any key present
      # in attrs, including an explicit nil), which validate_required does
      # then catch -- this is the only way to genuinely exercise this
      # validation from outside the module.
      attrs = valid_attrs(%{"json_schema" => nil})

      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Registry.register_type(attrs, tenant_id)

      assert %{json_schema: [_ | _]} = errors_on(changeset)
    end

    test "a non-map json_schema value fails changeset casting rather than being silently accepted",
         %{tenant_id: tenant_id} do
      assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
               Registry.register_type(valid_attrs(%{"json_schema" => "not-a-map"}), tenant_id)

      assert %{json_schema: [_ | _]} = errors_on(changeset)
    end

    test "a tenant_id with no Registration row returns {:error, :tenant_not_provisioned}, no changeset attempted" do
      never_provisioned_tenant_id = Ecto.UUID.generate()

      assert {:error, :tenant_not_provisioned} =
               Registry.register_type(valid_attrs(), never_provisioned_tenant_id)
    end

    # ---------------------------------------------------------------------
    # Beyond AC2's literal (sequential) wording: the DB-level unique-index
    # backstop path ELIXIR-DEV's Step 2a handoff flagged as unexercised
    # (handoffs/WF02-REQ024-20260816/step-02a-elixir-dev.json issue 2) --
    # "insert_with_monotonicity_check/2's DB-level unique-constraint backstop
    # path ... was not exercised by this handoff's manual demonstration".
    # This test genuinely forces two concurrent register_type/2 calls to
    # both read current_max == 0 before either commits, so both attempt the
    # identical (name, schema_version) insert and only the table's own
    # unique_index(:event_type_registry, [:name, :schema_version]) (not the
    # application-level pre-check, which both calls pass) decides the
    # winner.
    # ---------------------------------------------------------------------

    test "a concurrent race registering the identical (name, schema_version) resolves to exactly one success, the loser getting :duplicate_event_type_version",
         %{tenant_id: tenant_id} do
      attrs = valid_attrs()
      parent = self()

      # Sandbox mode is :auto for this describe block's tests (via
      # provisioned_tenant/1) -- unlike identity_test.exs's own concurrent
      # race test (which needs Sandbox.allow/3 to share the parent's single
      # sandboxed connection under :shared mode), :auto mode gives every
      # process, including these spawned Tasks, its own real, independent
      # Postgres connection automatically -- no explicit connection sharing
      # needed for genuine concurrency here.
      run_task = fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        after
          5000 -> flunk("barrier release never arrived")
        end

        Registry.register_type(attrs, tenant_id)
      end

      task1 = Task.async(run_task)
      task2 = Task.async(run_task)

      assert_receive {:ready, pid1}, 5000
      assert_receive {:ready, pid2}, 5000
      assert pid1 != pid2

      send(pid1, :go)
      send(pid2, :go)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      results = [result1, result2]

      # Exactly one success, exactly one loss to the distinct
      # :duplicate_event_type_version atom -- never both succeeding (which
      # would mean the unique index isn't actually enforced), never a raw
      # %Ecto.Changeset{} leaking through instead of the clean atom (which
      # would mean unique_violation?/2's constraint-name matching is wrong).
      assert Enum.count(results, &match?({:ok, %EventType{}}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :duplicate_event_type_version})) == 1

      # Confirm against real Postgres, not just the in-memory replies: exactly
      # one row exists for this (name, schema_version), regardless of which
      # task "won".
      row_count =
        EventType
        |> where([e], e.name == ^attrs["name"] and e.schema_version == ^attrs["schema_version"])
        |> Repo.aggregate(:count, :id, prefix: fetch_schema_name(tenant_id))

      assert row_count == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "validate_payload/2 against a payload missing a
  # required field returns a failure result whose detail names the specific
  # field_path (JSON Pointer form) and constraint, not just a boolean false"
  #
  # JsonSchema's own per-keyword behavior is exhaustively covered by
  # json_schema_test.exs -- these tests exist to prove validate_payload/3's
  # own DB-backed wiring (event-type lookup by name/tenant, JSON decoding,
  # the root-level malformed/non-object short-circuit), not to re-derive
  # every keyword.
  # ---------------------------------------------------------------------------------

  describe "validate_payload/3 (acceptance criterion 3)" do
    setup :provisioned_tenant

    test "a payload missing a required field returns a failure naming the specific field_path (JSON Pointer) and constraint",
         %{tenant_id: tenant_id} do
      schema = %{"type" => "object", "required" => ["order_id"]}
      name = register_fixture_type!(tenant_id, schema)

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload(name, Jason.encode!(%{}), tenant_id)

      assert [%ValidationFailure{field_path: "/order_id", constraint: "required"}] = failures
    end

    test "a minLength violation is reported with its own constraint name", %{tenant_id: tenant_id} do
      schema = %{"type" => "object", "properties" => %{"order_id" => %{"minLength" => 3}}}
      name = register_fixture_type!(tenant_id, schema)

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload(name, Jason.encode!(%{"order_id" => "ab"}), tenant_id)

      assert [%ValidationFailure{field_path: "/order_id", constraint: "minLength"}] = failures
    end

    test "an enum violation is reported with its own constraint name", %{tenant_id: tenant_id} do
      schema = %{"type" => "object", "properties" => %{"status" => %{"enum" => ["a", "b"]}}}
      name = register_fixture_type!(tenant_id, schema)

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload(name, Jason.encode!(%{"status" => "bogus"}), tenant_id)

      assert [%ValidationFailure{field_path: "/status", constraint: "enum"}] = failures
    end

    test "a type-mismatch violation is reported with its own constraint name", %{
      tenant_id: tenant_id
    } do
      schema = %{"type" => "object", "properties" => %{"amount" => %{"type" => "number"}}}
      name = register_fixture_type!(tenant_id, schema)

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload(
                 name,
                 Jason.encode!(%{"amount" => "not-a-number"}),
                 tenant_id
               )

      assert [%ValidationFailure{field_path: "/amount", constraint: "type"}] = failures
    end

    test "an unsupported-but-inert keyword ($ref) present in the schema does not cause a payload that would otherwise satisfy it to be rejected",
         %{tenant_id: tenant_id} do
      schema = %{
        "type" => "object",
        "properties" => %{
          "code" => %{
            "type" => "string",
            "$ref" => "#/definitions/never-resolved",
            "pattern" => "^[0-9]+$"
          }
        }
      }

      name = register_fixture_type!(tenant_id, schema)

      # "abc" satisfies "type": "string" but would VIOLATE "pattern" (not
      # all-digits) if pattern were enforced -- accepted here, proving $ref
      # and pattern are genuinely inert end-to-end through validate_payload/3,
      # not just inside the pure validator in isolation.
      assert :ok = Registry.validate_payload(name, Jason.encode!(%{"code" => "abc"}), tenant_id)
    end

    test "a fully valid payload against a well-formed schema returns :ok", %{tenant_id: tenant_id} do
      schema = %{
        "type" => "object",
        "required" => ["order_id"],
        "properties" => %{"order_id" => %{"type" => "string", "minLength" => 1}}
      }

      name = register_fixture_type!(tenant_id, schema)

      assert :ok =
               Registry.validate_payload(name, Jason.encode!(%{"order_id" => "abc"}), tenant_id)
    end

    test "malformed (non-parseable) JSON is reported as field_path \"/\", constraint \"type\", with the raw payload as actual",
         %{tenant_id: tenant_id} do
      schema = %{"type" => "object"}
      name = register_fixture_type!(tenant_id, schema)

      raw = "{not valid json"

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload(name, raw, tenant_id)

      assert [%ValidationFailure{field_path: "/", constraint: "type", actual: ^raw}] = failures
    end

    test "syntactically valid JSON that decodes to a non-object root (an array) is reported as field_path \"/\", constraint \"type\"",
         %{tenant_id: tenant_id} do
      schema = %{"type" => "object"}
      name = register_fixture_type!(tenant_id, schema)

      raw = Jason.encode!([1, 2, 3])

      assert {:error, {:payload_validation_failed, failures}} =
               Registry.validate_payload(name, raw, tenant_id)

      assert [%ValidationFailure{field_path: "/", constraint: "type", actual: ^raw}] = failures
    end

    test "an unregistered event type returns {:error, :unknown_event_type}, propagated from get_type/2",
         %{tenant_id: tenant_id} do
      assert {:error, :unknown_event_type} =
               Registry.validate_payload(
                 unique_name("NEVER_REGISTERED"),
                 Jason.encode!(%{}),
                 tenant_id
               )
    end

    test "validates against the most recently registered schema_version, not an earlier one",
         %{tenant_id: tenant_id} do
      name = unique_name()

      assert {:ok, %EventType{}} =
               Registry.register_type(
                 valid_attrs(%{
                   "name" => name,
                   "schema_version" => 1,
                   "json_schema" => %{"type" => "object"}
                 }),
                 tenant_id
               )

      assert {:ok, %EventType{}} =
               Registry.register_type(
                 valid_attrs(%{
                   "name" => name,
                   "schema_version" => 2,
                   "json_schema" => %{"type" => "object", "required" => ["must_have_v2"]}
                 }),
                 tenant_id
               )

      # Payload satisfies v1's permissive schema but not v2's -- proves
      # validation ran against v2 (the most recent), not v1.
      assert {:error,
              {:payload_validation_failed, [%ValidationFailure{field_path: "/must_have_v2"}]}} =
               Registry.validate_payload(name, Jason.encode!(%{}), tenant_id)
    end

    test "a tenant_id with no Registration row returns {:error, :tenant_not_provisioned}" do
      never_provisioned_tenant_id = Ecto.UUID.generate()

      assert {:error, :tenant_not_provisioned} =
               Registry.validate_payload(
                 "ANY_NAME",
                 Jason.encode!(%{}),
                 never_provisioned_tenant_id
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "get_type/1 against an unregistered name returns an
  # explicit :unknown_event_type-shaped error rather than nil or an exception"
  # ---------------------------------------------------------------------------------

  describe "get_type/2 (acceptance criterion 4)" do
    setup :provisioned_tenant

    test "an unregistered name returns {:error, :unknown_event_type}, never nil, never an exception",
         %{tenant_id: tenant_id} do
      refute match?(nil, Registry.get_type(unique_name(), tenant_id))
      assert {:error, :unknown_event_type} = Registry.get_type(unique_name(), tenant_id)
    end

    test "a registered name with a single version returns that version", %{tenant_id: tenant_id} do
      name = unique_name()

      assert {:ok, %EventType{}} =
               Registry.register_type(valid_attrs(%{"name" => name}), tenant_id)

      assert {:ok, %EventType{name: ^name, schema_version: 1}} =
               Registry.get_type(name, tenant_id)
    end

    test "a registered name with multiple versions returns the highest schema_version",
         %{tenant_id: tenant_id} do
      # register_type/2 enforces strict monotonicity (design doc section
      # 4.1's callout) -- versions must be registered in strictly increasing
      # order, so this registers 1, then 2, then 5 (not sequential, proving
      # "highest" means numerically highest, not "most recently
      # registered" or "count of registrations").
      name = unique_name()

      assert {:ok, %EventType{}} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 1}),
                 tenant_id
               )

      assert {:ok, %EventType{}} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 2}),
                 tenant_id
               )

      assert {:ok, %EventType{}} =
               Registry.register_type(
                 valid_attrs(%{"name" => name, "schema_version" => 5}),
                 tenant_id
               )

      assert {:ok, %EventType{name: ^name, schema_version: 5}} =
               Registry.get_type(name, tenant_id)
    end

    test "a tenant_id with no Registration row returns {:error, :tenant_not_provisioned}" do
      never_provisioned_tenant_id = Ecto.UUID.generate()

      assert {:error, :tenant_not_provisioned} =
               Registry.get_type(unique_name(), never_provisioned_tenant_id)
    end

    test "get_type/2 is tenant-isolated: an event type registered for one tenant is invisible to another",
         %{tenant_id: tenant_id_a} do
      %{tenant_id: tenant_id_b} = provisioned_tenant(%{})
      name = unique_name()

      assert {:ok, %EventType{}} =
               Registry.register_type(valid_attrs(%{"name" => name}), tenant_id_a)

      assert {:error, :unknown_event_type} = Registry.get_type(name, tenant_id_b)
      assert {:ok, %EventType{}} = Registry.get_type(name, tenant_id_a)
    end
  end
end
