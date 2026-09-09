defmodule Letflow.Entities.Definition.DDLTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Definition.DDL` (REQ-296). See
  `lib/letflow/design/req296-entity-table-ddl-generator.md` §9 for the
  test-coverage plan each `describe` block below maps to.

  Most of this module is a pure function of `Definition.t()`, so most tests
  run `async: true` with no `Letflow.Repo`/Sandbox dependency. The one
  exception is the "real ephemeral Postgres" describe block, which uses
  `Letflow.DataCase` to get a real Postgres connection and creates/drops a
  throwaway schema within it.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Entities.Definition.DDL

  # ---------------------------------------------------------------------------
  # AC1 -- exact output shape: FK-promoted field + queried:true-promoted field.
  # ---------------------------------------------------------------------------

  describe "generate_table_ddl/2 -- exact output shape" do
    test "produces structural columns plus both promoted columns, in field order, and nothing else" do
      definition = %{
        name: "invoice",
        display_name: "Invoice",
        fields: [
          %{name: "customer_id", type: :string},
          %{
            name: "amount",
            type: :decimal,
            decimal_precision: 10,
            decimal_scale: 2,
            queried: true
          },
          %{name: "internal_notes", type: :json}
        ],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "invoice_table")

      assert sql =~ ~s|CREATE TABLE "invoice_table" (|

      # Structural columns.
      assert sql =~ ~s|"id" uuid NOT NULL|
      assert sql =~ ~s|"record_id" uuid NOT NULL|
      assert sql =~ ~s|"field_values" jsonb NOT NULL DEFAULT '{}'::jsonb|
      assert sql =~ ~s|"deleted" boolean NOT NULL DEFAULT false|
      assert sql =~ ~s|"entity_def_version" bytea|
      refute sql =~ ~s|"entity_def_version" bytea NOT NULL|
      assert sql =~ ~s|"last_event_global_seq" bigint NOT NULL|
      assert sql =~ ~s|"inserted_at" timestamp(6) without time zone NOT NULL|
      assert sql =~ ~s|"updated_at" timestamp(6) without time zone NOT NULL|

      # Promoted columns: customer_id (FK) and amount (queried).
      assert sql =~ ~s|"customer_id" text|
      assert sql =~ ~s|"amount" numeric(10, 2)|

      # Not promoted / never promoted.
      refute sql =~ "internal_notes"

      # No entity_type column (dropped from the per-type table).
      refute sql =~ "entity_type"

      assert [customer_id, amount] = DDL.promoted_columns(definition)
      assert customer_id.name == "customer_id"
      assert amount.name == "amount"
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- type-mapping table, one test per type (except :json).
  # ---------------------------------------------------------------------------

  describe "field_type_to_pg_type/1 and generate_table_ddl/2 -- type mapping" do
    test ":string maps to text" do
      assert {:ok, "text"} = DDL.field_type_to_pg_type(%{type: :string})
      assert_column_type_in_ddl(%{name: "s", type: :string, queried: true}, "text")
    end

    test ":integer maps to bigint" do
      assert {:ok, "bigint"} = DDL.field_type_to_pg_type(%{type: :integer})
      assert_column_type_in_ddl(%{name: "i", type: :integer, queried: true}, "bigint")
    end

    test ":decimal with precision/scale maps to numeric(p, s)" do
      field = %{type: :decimal, decimal_precision: 12, decimal_scale: 4}
      assert {:ok, "numeric(12, 4)"} = DDL.field_type_to_pg_type(field)

      assert_column_type_in_ddl(
        %{name: "d", type: :decimal, decimal_precision: 12, decimal_scale: 4, queried: true},
        "numeric(12, 4)"
      )
    end

    test ":decimal without precision/scale falls back to bare numeric" do
      assert {:ok, "numeric"} = DDL.field_type_to_pg_type(%{type: :decimal})
      assert_column_type_in_ddl(%{name: "d", type: :decimal, queried: true}, "numeric")
    end

    test ":boolean maps to boolean" do
      assert {:ok, "boolean"} = DDL.field_type_to_pg_type(%{type: :boolean})
      assert_column_type_in_ddl(%{name: "b", type: :boolean, queried: true}, "boolean")
    end

    test ":date maps to date" do
      assert {:ok, "date"} = DDL.field_type_to_pg_type(%{type: :date})
      assert_column_type_in_ddl(%{name: "dt", type: :date, queried: true}, "date")
    end

    test ":datetime maps to timestamp(6) without time zone" do
      assert {:ok, "timestamp(6) without time zone"} =
               DDL.field_type_to_pg_type(%{type: :datetime})

      assert_column_type_in_ddl(
        %{name: "dtm", type: :datetime, queried: true},
        "timestamp(6) without time zone"
      )
    end

    test ":enum maps to text with a CHECK constraint enumerating the allowed values" do
      assert {:ok, "text"} = DDL.field_type_to_pg_type(%{type: :enum})

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "status", type: :enum, enum_values: ["active", "inactive"], queried: true}
        ]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "widget_table")
      assert sql =~ ~s|"status" text|
      assert sql =~ ~s|CHECK ("status" IN ('active', 'inactive'))|
    end

    defp assert_column_type_in_ddl(field, expected_pg_type) do
      definition = %{
        name: "typetest",
        display_name: "Type test",
        fields: [field]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "typetest_table")
      assert sql =~ ~s|"#{field.name}" #{expected_pg_type}|
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 (defence-in-depth) -- :json is NEVER promoted, even if queried: true.
  # ---------------------------------------------------------------------------

  describe ":json fields are never promoted (defence in depth)" do
    test "field_type_to_pg_type/1 returns :never_promoted for :json" do
      assert :never_promoted = DDL.field_type_to_pg_type(%{type: :json})
    end

    test "a :json field forced to queried: true is absent from promoted_columns/1 and from generated DDL" do
      # This definition would fail Validator.validate/1's Rule 3
      # (queried_json_violations/1) -- deliberately bypassing the Validator
      # here to prove this module's own independent defence-in-depth filter,
      # not merely relying on upstream validation never letting this through.
      definition = %{
        name: "leaky",
        display_name: "Leaky",
        fields: [
          %{name: "blob", type: :json, queried: true}
        ]
      }

      assert DDL.promoted_columns(definition) == []

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "leaky_table")
      refute sql =~ "blob"
    end

    test "a :json field that is also an fk_def field is still never promoted" do
      definition = %{
        name: "leaky2",
        display_name: "Leaky2",
        fields: [
          %{name: "blob", type: :json}
        ],
        foreign_keys: [
          %{name: "blob_fk", field: "blob", references_entity: "other"}
        ]
      }

      assert DDL.promoted_columns(definition) == []
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- an attribute that is neither an fk_def field nor queried: true is
  # NOT promoted.
  # ---------------------------------------------------------------------------

  describe "an attribute with neither promotion trigger is not promoted" do
    test "queried: false and not an FK -> :not_promoted, absent from promoted_columns/1 and generated DDL" do
      field = %{name: "internal_note", type: :string, queried: false}
      assert DDL.promotion_trigger(field, MapSet.new()) == :not_promoted

      definition = %{
        name: "thing",
        display_name: "Thing",
        fields: [field]
      }

      assert DDL.promoted_columns(definition) == []

      assert {:ok, sql} = DDL.generate_table_ddl(definition, "thing_table")
      refute sql =~ "internal_note"
    end

    test "queried key absent and not an FK -> :not_promoted" do
      field = %{name: "internal_note", type: :string}
      assert DDL.promotion_trigger(field, MapSet.new()) == :not_promoted
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- an fk_def field IS promoted even when queried: false or absent.
  # ---------------------------------------------------------------------------

  describe "an fk_def field is promoted regardless of queried" do
    test "promotion_trigger/2 returns :fk when queried: false is explicit" do
      field = %{name: "customer_id", type: :string, queried: false}
      fk_field_names = MapSet.new(["customer_id"])

      assert DDL.promotion_trigger(field, fk_field_names) == :fk
    end

    test "the field is present in promoted_columns/1's result" do
      definition = %{
        name: "invoice2",
        display_name: "Invoice2",
        fields: [
          %{name: "customer_id", type: :string, queried: false}
        ],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ]
      }

      assert [%{name: "customer_id"}] = DDL.promoted_columns(definition)
    end
  end

  # ---------------------------------------------------------------------------
  # valid_identifier?/1 and the defence-in-depth identifier check.
  # ---------------------------------------------------------------------------

  describe "valid_identifier?/1 and generate_table_ddl/2's identifier check" do
    test "accepts lowercase snake_case identifiers" do
      assert DDL.valid_identifier?("customer")
      assert DDL.valid_identifier?("customer_records_v2")
    end

    test "rejects identifiers with SQL-injection-shaped content" do
      refute DDL.valid_identifier?("customer\"; DROP TABLE users; --")
      refute DDL.valid_identifier?("Customer")
      refute DDL.valid_identifier?("")
      refute DDL.valid_identifier?("1customer")
    end

    test "generate_table_ddl/2 rejects a malicious table_name" do
      definition = %{name: "x", display_name: "X", fields: []}

      assert {:error, {:invalid_identifier, field: :table_name, value: _}} =
               DDL.generate_table_ddl(definition, "x\"; DROP TABLE users; --")
    end

    test "generate_table_ddl/2 rejects a malformed promoted attribute name" do
      definition = %{
        name: "x",
        display_name: "X",
        fields: [%{name: "Bad Name", type: :string, queried: true}]
      }

      assert {:error, {:invalid_identifier, field: :attribute, value: "Bad Name"}} =
               DDL.generate_table_ddl(definition, "x_table")
    end
  end

  # ---------------------------------------------------------------------------
  # Moduledoc extension point for REQ-301.
  # ---------------------------------------------------------------------------

  describe "moduledoc states the REQ-301 extension point without implementing it" do
    test "the moduledoc mentions REQ-301 and the extension point, with no locale-related code" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(DDL)

      assert moduledoc =~ "REQ-301"
      assert moduledoc =~ "locale"

      # Defence-in-depth against silently implementing the REQ-301 feature
      # itself: no locale *configuration* shape (a `:locale`/`:locales` key
      # on a field_def(), or a dedicated generated-column-per-locale
      # function) exists yet -- only the dispatch-shape/prose extension
      # point the moduledoc describes.
      source = File.read!("lib/letflow/entities/definition/ddl.ex")
      refute source =~ ":locale"
      refute source =~ "locale:"
      refute source =~ "generated_column"
    end
  end

  # ---------------------------------------------------------------------------
  # AC5 -- run the generated DDL against a real ephemeral Postgres schema.
  # ---------------------------------------------------------------------------

  describe "generate_table_ddl/2 output runs against a real ephemeral Postgres schema" do
    test "creates the table with exactly the structural + promoted columns" do
      schema_name = "ddl_test_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      table_name = "widget"

      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "customer_id", type: :string},
          %{
            name: "amount",
            type: :decimal,
            decimal_precision: 10,
            decimal_scale: 2,
            queried: true
          },
          %{name: "status", type: :enum, enum_values: ["active", "inactive"], queried: true},
          %{name: "notes", type: :json, queried: false}
        ],
        foreign_keys: [
          %{name: "customer_fk", field: "customer_id", references_entity: "customer"}
        ]
      }

      assert {:ok, sql} = DDL.generate_table_ddl(definition, table_name)

      # ExUnit runs on_exit callbacks LIFO, most-recently-registered first --
      # this one runs before Letflow.DataCase's own checkin/rollback, so the
      # connection here is still the same checked-out sandbox connection the
      # rest of this test uses; no separate checkout/mode switch is needed.
      on_exit(fn ->
        Repo.query!(~s|DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE|)
      end)

      Repo.query!(~s|CREATE SCHEMA "#{schema_name}"|)
      Repo.query!(~s|SET search_path TO "#{schema_name}"|)

      result = Repo.query!(sql)

      # Real, complete output of running the generated DDL -- this is the
      # `result` this test asserts against (Postgrex.Result struct from the
      # single CREATE TABLE statement, which carries the record_id UNIQUE
      # constraint as a table constraint rather than a separate statement).
      assert %Postgrex.Result{} = result

      columns_result =
        Repo.query!(
          """
          SELECT column_name, data_type
          FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2
          """,
          [schema_name, table_name]
        )

      actual_columns =
        columns_result.rows
        |> Enum.map(fn [name, _type] -> name end)
        |> MapSet.new()

      expected_columns =
        (DDL.structural_columns() ++ DDL.promoted_columns(definition))
        |> Enum.map(& &1.name)
        |> MapSet.new()

      assert actual_columns == expected_columns

      Repo.query!(~s|SET search_path TO public|)
    end
  end
end
