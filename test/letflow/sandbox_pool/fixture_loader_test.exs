defmodule Letflow.SandboxPool.FixtureLoaderTest do
  @moduledoc """
  Tests for `Letflow.SandboxPool.FixtureLoader.load_fixtures_only/3` (REQ-039). See
  `test/specs/REQ-039.md` for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  ## Why this file needs the same Sandbox `:auto`-mode treatment as
  ## `sandbox_pool_test.exs`

  `load_fixtures_only/3` itself issues no `Ecto.Migrator` calls -- it only needs an
  *already-provisioned* sandbox schema to load rows into. But obtaining that schema
  means calling `Letflow.SandboxPool.claim/1,2`, which *does* call `Ecto.Migrator.run/4`
  internally. See `test/letflow/sandbox_pool_test.exs`'s moduledoc (and, underneath
  that, `test/letflow/tenant_provisioning_test.exs`'s moduledoc) for the full
  empirical investigation of why that requires Sandbox `:auto` mode rather than
  DataCase's normal rolled-back transaction. `async: false` for the same reason those
  two files are.

  Every claimed schema this file creates is dropped explicitly (`release/1,2` plus a
  defensive `on_exit/1` fallback), since nothing here is rolled back automatically.
  """

  use Letflow.DataCase, async: false

  alias Letflow.SandboxPool
  alias Letflow.SandboxPool.FixtureLoader
  alias Letflow.SandboxPool.FixtureLoader.FixtureRow
  alias Letflow.SandboxPool.SandboxClaim

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # Isolated, uniquely-named pool -- same reasoning as sandbox_pool_test.exs's
  # start_pool!/1 (design doc §4.7 INV-SP-7). max_concurrent: 2 is plenty for this
  # file's needs (never more than one claim outstanding at a time per test).
  defp start_pool!(opts \\ []) do
    name = :"fixture_loader_test_pool_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SandboxPool.start_link(Keyword.put_new(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Claims a real sandbox schema for a test to load fixtures into. release/2 is NOT
  # called automatically here -- no test in this file needs the release path itself,
  # only a schema to load fixtures into -- but a defensive on_exit/1 DROP SCHEMA
  # always runs regardless, so no test body can leak a schema.
  defp claim_schema! do
    pool = start_pool!(max_concurrent: 2)

    assert {:ok, %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name}} =
             SandboxPool.claim(2_000, pool)

    on_exit(fn -> drop_schema!(schema_name) end)

    {pool, sandbox_id, schema_name}
  end

  # All NOT NULL process_definitions columns with no DB-level default are supplied
  # explicitly -- jsonb_populate_record/2 fills any field missing from the JSON with
  # NULL, not the target table's column DEFAULT (populate_record operates on the
  # composite TYPE, which carries no knowledge of table-level defaults), so omitting
  # e.g. "status" here would insert a real NULL and violate `status text NOT NULL`,
  # not silently fall back to "draft". created_at/updated_at use NaiveDateTime
  # (no "Z"/offset suffix) because the underlying column type is `timestamp without
  # time zone` (Ecto's :utc_datetime_usec persists as naive local storage assumed to
  # be UTC, confirmed in the migration's own header comment) -- avoids relying on
  # Postgres's offset-stripping behavior for an offset-bearing string.
  defp valid_process_definition_json(overrides \\ %{}) do
    now =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:microsecond)
      |> NaiveDateTime.to_iso8601()

    %{
      "id" => Ecto.UUID.generate(),
      "tenant_id" => Ecto.UUID.generate(),
      "name" => "req039-fixture-#{System.unique_integer([:positive, :monotonic])}",
      "version" => "1.0.0",
      "status" => "draft",
      "graph" => %{"nodes" => [], "edges" => []},
      "created_by" => Ecto.UUID.generate(),
      "created_at" => now,
      "updated_at" => now
    }
    |> Map.merge(overrides)
    |> Jason.encode!()
  end

  # ::text cast -- Postgrex returns a raw 16-byte binary for a bare uuid column on a
  # hand-written query (no Ecto.Schema load step involved), not the canonical
  # hyphenated string Ecto.UUID.generate() produces. Casting in SQL sidesteps that
  # entirely and keeps the comparison below a plain string equality.
  defp process_definition_ids(schema_name) do
    %{rows: rows} =
      Repo.query!(~s(SELECT "id"::text FROM "#{schema_name}"."process_definitions" ORDER BY "id"))

    List.flatten(rows)
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 4: "load_fixtures_only/3 with a table_name not in the
  # allowlist returns InvalidTableName without issuing any SQL against that table
  # name"
  # ---------------------------------------------------------------------------------

  describe "load_fixtures_only/3 -- allowlist rejection (acceptance criterion 4)" do
    test "a table_name outside the allowlist returns {:error, :invalid_table_name}, and no SQL runs against ANY table in the batch, including allowlisted ones" do
      {_pool, _sandbox_id, schema_name} = claim_schema!()

      fixtures = [
        %FixtureRow{
          table_name: "process_definitions",
          row_json: valid_process_definition_json()
        },
        %FixtureRow{table_name: "not_on_the_allowlist", row_json: Jason.encode!(%{})}
      ]

      assert {:error, :invalid_table_name} =
               FixtureLoader.load_fixtures_only(schema_name, fixtures)

      # INV-FL-2 (design doc §5.5): the validation pass rejects the WHOLE batch
      # before any mutation runs -- even the allowlisted table's own row, which on
      # its own would have inserted cleanly, never landed. If the allowlist check
      # ran per-table instead of as a whole-batch pre-pass, this would find 1 row
      # here instead of 0.
      assert process_definition_ids(schema_name) == []
    end

    test "every fixture already violating the allowlist (no allowlisted table involved at all) is likewise rejected, no SQL issued" do
      {_pool, _sandbox_id, schema_name} = claim_schema!()

      fixtures = [%FixtureRow{table_name: "users", row_json: Jason.encode!(%{})}]

      assert {:error, :invalid_table_name} =
               FixtureLoader.load_fixtures_only(schema_name, fixtures)
    end

    test "an invalid sandbox_schema shape is rejected before any table-name check, returning {:error, :invalid_schema_name}" do
      # Deliberately does NOT call claim_schema!/0 -- INV-FL-1 (design doc §5.5)
      # means this must be rejected purely from the schema-name's shape, with no DB
      # round trip and no real sandbox needed at all.
      fixtures = [
        %FixtureRow{table_name: "process_definitions", row_json: valid_process_definition_json()}
      ]

      assert {:error, :invalid_schema_name} =
               FixtureLoader.load_fixtures_only("not-a-real-sandbox-schema", fixtures)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "load_fixtures_only/3 loading the same fixtures twice
  # against the same sandbox_schema (simulating a retry) leaves the same final row
  # set both times, via the TRUNCATE-before-insert step"
  # ---------------------------------------------------------------------------------

  describe "load_fixtures_only/3 -- idempotent retry via TRUNCATE-before-insert (acceptance criterion 5)" do
    test "loading the identical fixtures twice leaves the identical final row set both times" do
      {_pool, _sandbox_id, schema_name} = claim_schema!()

      id_a = Ecto.UUID.generate()
      id_b = Ecto.UUID.generate()

      fixtures = [
        %FixtureRow{
          table_name: "process_definitions",
          row_json: valid_process_definition_json(%{"id" => id_a})
        },
        %FixtureRow{
          table_name: "process_definitions",
          row_json: valid_process_definition_json(%{"id" => id_b})
        }
      ]

      assert :ok = FixtureLoader.load_fixtures_only(schema_name, fixtures)
      assert Enum.sort(process_definition_ids(schema_name)) == Enum.sort([id_a, id_b])

      # Simulated retry: the identical fixtures list, same sandbox_schema, called
      # again. Without the TRUNCATE-before-insert step, this second call would
      # either raise a primary-key conflict on `id` (id is process_definitions'
      # primary key -- {:error, :insert_failed}, not :ok) or, if id weren't unique,
      # silently double the row count to 4. Asserting :ok AND exactly these two ids
      # rules out both failure modes at once.
      assert :ok = FixtureLoader.load_fixtures_only(schema_name, fixtures)
      assert Enum.sort(process_definition_ids(schema_name)) == Enum.sort([id_a, id_b])
    end

    test "a changed retry (same table, different row content) replaces the prior load's rows entirely" do
      {_pool, _sandbox_id, schema_name} = claim_schema!()

      first_id = Ecto.UUID.generate()
      second_id = Ecto.UUID.generate()

      assert :ok =
               FixtureLoader.load_fixtures_only(schema_name, [
                 %FixtureRow{
                   table_name: "process_definitions",
                   row_json: valid_process_definition_json(%{"id" => first_id})
                 }
               ])

      assert process_definition_ids(schema_name) == [first_id]

      assert :ok =
               FixtureLoader.load_fixtures_only(schema_name, [
                 %FixtureRow{
                   table_name: "process_definitions",
                   row_json: valid_process_definition_json(%{"id" => second_id})
                 }
               ])

      # The first load's row is gone, not merely joined by the second -- proves the
      # TRUNCATE step actually ran on the second call, not just an insert.
      assert process_definition_ids(schema_name) == [second_id]
    end

    test "an empty fixtures list is a no-op: :ok, no rows inserted, no prior rows disturbed" do
      {_pool, _sandbox_id, schema_name} = claim_schema!()

      seeded_id = Ecto.UUID.generate()

      assert :ok =
               FixtureLoader.load_fixtures_only(schema_name, [
                 %FixtureRow{
                   table_name: "process_definitions",
                   row_json: valid_process_definition_json(%{"id" => seeded_id})
                 }
               ])

      assert :ok = FixtureLoader.load_fixtures_only(schema_name, [])

      # No TRUNCATE for an empty list (fixture_loader.zig:51's no-op semantics,
      # ported verbatim) -- the previously seeded row must survive untouched.
      assert process_definition_ids(schema_name) == [seeded_id]
    end
  end
end
