defmodule Letflow.EventStore.RetentionPolicyTest do
  @moduledoc """
  Integration + pure tests for REQ-026's `event_retention_policies` table and
  `Letflow.EventStore.RetentionPolicy` schema module —
  `priv/repo/migrations/20260817181240_create_event_retention_policies.exs`. See
  `test/specs/REQ-026.md` for the full test-case rationale and
  `lib/letflow/design/req026-event-read-archive-platform-sentinels.md` §6/§8 for
  the design this implements. Covers REQ-026 acceptance criterion 5.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## Why this file does NOT provision a tenant schema

  `event_retention_policies` is GLOBAL (public/default schema, no `:prefix`,
  design doc §6) -- created by the ordinary `mix ecto.migrate --quiet` step
  `mix test`'s own alias already runs before any test starts, exactly the same
  structural situation `test/letflow/definitions/pack_update_migration_test.exs`
  documents for REQ-041's three GLOBAL tables (that file is this file's direct
  structural precedent). There is therefore no `Ecto.Migrator`-needs-a-second-
  connection problem to work around: this file uses the perfectly ordinary
  `Letflow.DataCase` sandboxed transaction, `async: true` -- every row this file
  inserts is rolled back automatically at the end of each test, and no other
  test in the suite can observe it (unlike `event_store_test.exs`'s
  `provisioned_tenant/1`-using tests, which must switch to Sandbox `:auto` mode
  for unrelated `Ecto.Migrator` reasons and therefore need explicit `on_exit/1`
  cleanup for any `event_retention_policies` row they seed).
  """

  use Letflow.DataCase, async: true

  alias Letflow.EventStore.RetentionPolicy

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp unique_event_type(prefix \\ "EVT") do
    prefix <> "_" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp columns_in(table_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = $1",
        [table_name]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "event_retention_policies exists (via this
  # requirement's own migration) with columns
  # id/event_type(unique)/policy(default keep_forever)/keep_days/keep_count/
  # created_at/updated_at and the
  # chk_retention_policy/chk_keep_days/chk_keep_count CHECK constraints,
  # matching R-Co's 003_event_archive.sql shape"
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 5 -- table existence and column shape" do
    test "event_retention_policies exists under the public schema" do
      %{rows: [[exists?]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'event_retention_policies')",
          []
        )

      assert exists?
    end

    test "its real column set matches exactly: id, event_type, policy, keep_days, keep_count, created_at, updated_at" do
      assert columns_in("event_retention_policies") ==
               Enum.sort([
                 "id",
                 "event_type",
                 "policy",
                 "keep_days",
                 "keep_count",
                 "created_at",
                 "updated_at"
               ])
    end

    test "the schema module's field list agrees with the real column set" do
      expected = RetentionPolicy.__schema__(:fields) |> Enum.map(&Atom.to_string/1) |> Enum.sort()
      assert columns_in("event_retention_policies") == expected
    end

    test "the schema module pins no @schema_prefix -- GLOBAL, not per-tenant (design §6)" do
      assert RetentionPolicy.__schema__(:prefix) == nil
    end
  end

  describe "acceptance criterion 5 -- event_type uniqueness" do
    test "a second row for the same event_type is rejected by uq_retention_policy_event_type" do
      event_type = unique_event_type()

      assert {:ok, _first} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: event_type,
                 policy: :keep_forever
               })
               |> Repo.insert()

      assert {:error, changeset} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: event_type,
                 policy: :keep_forever
               })
               |> Repo.insert()

      assert %{event_type: ["has already been taken"]} = errors_on(changeset)
    end

    test "two different event_type rows both insert cleanly" do
      assert {:ok, _} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: unique_event_type(),
                 policy: :keep_forever
               })
               |> Repo.insert()

      assert {:ok, _} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: unique_event_type(),
                 policy: :keep_forever
               })
               |> Repo.insert()
    end
  end

  describe "acceptance criterion 5 -- policy defaults to keep_forever" do
    test "insert_changeset/2 with no :policy key produces a changeset whose data already carries :keep_forever (struct-level default), and it persists that value" do
      changeset =
        RetentionPolicy.insert_changeset(%RetentionPolicy{}, %{event_type: unique_event_type()})

      assert changeset.valid?
      assert changeset.data.policy == :keep_forever
      refute Map.has_key?(changeset.changes, :policy)

      assert {:ok, %RetentionPolicy{policy: :keep_forever}} = Repo.insert(changeset)
    end

    test "the DATABASE column itself defaults to 'keep_forever' -- a raw insert that omits policy entirely still reads back keep_forever" do
      # Proves the migration's own `default: "keep_forever"` DDL, independent of the
      # Ecto struct/changeset default tested above -- a raw SQL INSERT bypasses both
      # the struct and the changeset entirely, so this is the one test that can fail
      # if the migration's column-level DEFAULT clause were ever dropped while the
      # changeset-level default silently kept masking it.
      event_type = unique_event_type()

      Repo.query!(
        "INSERT INTO event_retention_policies (id, event_type, created_at, updated_at) VALUES (gen_random_uuid(), $1, now(), now())",
        [event_type]
      )

      %{rows: [[policy]]} =
        Repo.query!("SELECT policy FROM event_retention_policies WHERE event_type = $1", [
          event_type
        ])

      assert policy == "keep_forever"
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5 -- CHECK constraints. Per the design doc §8.2's own
  # interpretation (requirements.yaml names the three constraints, not their
  # literal predicates): a `policy = 'X'` row must have its own companion column
  # set (and positive) and every OTHER policy value's row must have that
  # companion column NULL. Each test below exercises real Postgres, not just the
  # changeset -- `validate_number/3`'s app-level checks only fire when the field
  # is PRESENT (design §8.3's own stated "absent is valid" caveat), so the
  # "required companion column is missing" half of each constraint can only be
  # observed by actually hitting the DB constraint, matching
  # migrations_test.exs's established "declared constraint name vs. real DB
  # constraint" idiom.
  # ---------------------------------------------------------------------------------

  describe "acceptance criterion 5 -- chk_keep_days" do
    test "policy=keep_days with keep_days=nil is rejected by chk_keep_days" do
      changeset =
        RetentionPolicy.insert_changeset(%RetentionPolicy{}, %{
          event_type: unique_event_type(),
          policy: :keep_days
        })

      # The changeset itself is valid at the app layer -- keep_days absent is
      # "valid" per validate_number/3's own stated caveat (design §8.3). The DB
      # CHECK is the only thing that catches this.
      assert changeset.valid?

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{keep_days: [_ | _]} = errors_on(changeset)
    end

    test "policy=keep_forever with keep_days set is rejected by chk_keep_days (the companion column must be NULL for every OTHER policy)" do
      changeset =
        RetentionPolicy.insert_changeset(%RetentionPolicy{}, %{
          event_type: unique_event_type(),
          policy: :keep_forever,
          keep_days: 30
        })

      assert changeset.valid?

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{keep_days: [_ | _]} = errors_on(changeset)
    end

    test "policy=keep_days with a positive keep_days and no keep_count inserts cleanly" do
      assert {:ok, %RetentionPolicy{policy: :keep_days, keep_days: 30, keep_count: nil}} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: unique_event_type(),
                 policy: :keep_days,
                 keep_days: 30
               })
               |> Repo.insert()
    end

    test "policy=keep_days with a non-positive keep_days is rejected at the app layer already (validate_number/3), never reaching the DB" do
      changeset =
        RetentionPolicy.insert_changeset(%RetentionPolicy{}, %{
          event_type: unique_event_type(),
          policy: :keep_days,
          keep_days: 0
        })

      refute changeset.valid?
      assert %{keep_days: [_ | _]} = errors_on(changeset)
    end
  end

  describe "acceptance criterion 5 -- chk_keep_count" do
    test "policy=keep_count with keep_count=nil is rejected by chk_keep_count" do
      changeset =
        RetentionPolicy.insert_changeset(%RetentionPolicy{}, %{
          event_type: unique_event_type(),
          policy: :keep_count
        })

      assert changeset.valid?

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{keep_count: [_ | _]} = errors_on(changeset)
    end

    test "policy=keep_forever with keep_count set is rejected by chk_keep_count" do
      changeset =
        RetentionPolicy.insert_changeset(%RetentionPolicy{}, %{
          event_type: unique_event_type(),
          policy: :keep_forever,
          keep_count: 5
        })

      assert changeset.valid?

      assert {:error, changeset} = Repo.insert(changeset)
      assert %{keep_count: [_ | _]} = errors_on(changeset)
    end

    test "policy=keep_count with a positive keep_count and no keep_days inserts cleanly" do
      assert {:ok, %RetentionPolicy{policy: :keep_count, keep_count: 5, keep_days: nil}} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: unique_event_type(),
                 policy: :keep_count,
                 keep_count: 5
               })
               |> Repo.insert()
    end
  end

  describe "acceptance criterion 5 -- chk_retention_policy" do
    test "an invalid policy string bypassing Ecto.Enum (raw SQL) is rejected by chk_retention_policy" do
      # Ecto.Enum's own cast already refuses any atom outside
      # [:keep_forever, :keep_days, :keep_count] at the changeset layer, so the
      # only way to reach the DB CHECK for THIS constraint is a raw SQL insert
      # that bypasses the schema/changeset entirely -- exactly mirroring this
      # file's "database column default" test above for the same reason.
      assert_raise Postgrex.Error, ~r/chk_retention_policy/, fn ->
        Repo.query!(
          "INSERT INTO event_retention_policies (id, event_type, policy, created_at, updated_at) VALUES (gen_random_uuid(), $1, 'not_a_real_policy', now(), now())",
          [unique_event_type()]
        )
      end
    end

    test "keep_forever with both keep_days and keep_count NULL inserts cleanly (the baseline valid shape)" do
      assert {:ok, %RetentionPolicy{policy: :keep_forever, keep_days: nil, keep_count: nil}} =
               %RetentionPolicy{}
               |> RetentionPolicy.insert_changeset(%{
                 event_type: unique_event_type(),
                 policy: :keep_forever
               })
               |> Repo.insert()
    end
  end

  describe "no update/delete API is built by this requirement (design §8.5)" do
    test "RetentionPolicy's own public API is exactly insert_changeset/2" do
      own_public_api =
        RetentionPolicy.__info__(:functions)
        |> Enum.reject(fn {name, _arity} ->
          name |> Atom.to_string() |> String.starts_with?("__")
        end)
        |> Enum.sort()

      assert own_public_api == [insert_changeset: 2]
    end
  end
end
