defmodule Letflow.Entities.Record.ValidatorTest do
  @moduledoc """
  Unit tests for `Letflow.Entities.Record.Validator` (REQ-227). See
  `lib/letflow/design/req227-entity-record-payload-validation.md` §9 for the
  acceptance-criteria traceability each test group below maps to.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency -- `async: true`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Entities.Record.Validator
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure

  @definition %{
    name: "customer",
    display_name: "Customer",
    fields: [
      %{name: "customer_name", type: :string, required: true},
      %{name: "age", type: :integer, required: true},
      %{name: "balance", type: :decimal, decimal_precision: 10, decimal_scale: 2},
      %{name: "active", type: :boolean},
      %{name: "signed_up_on", type: :date},
      %{name: "last_login_at", type: :datetime},
      %{name: "status", type: :enum, enum_values: ["open", "closed"], required: true},
      %{name: "notes", type: :json}
    ]
  }

  # ---------------------------------------------------------------------------
  # AC1 -- a conforming payload passes validation with zero violations.
  # ---------------------------------------------------------------------------

  describe "AC1 -- a conforming record payload passes with zero violations" do
    test "a fully-populated, conforming field_values map returns []" do
      field_values = %{
        "customer_name" => "Acme",
        "age" => 42,
        "balance" => 12.50,
        "active" => true,
        "signed_up_on" => "2026-01-01",
        "last_login_at" => "2026-09-06T12:00:00Z",
        "status" => "open",
        "notes" => %{"any" => ["json", "shape", 1, true, nil]}
      }

      assert Validator.validate_record_payload(@definition, field_values) == []
    end

    test "a minimal payload with only required fields set returns []" do
      field_values = %{"customer_name" => "Acme", "age" => 42, "status" => "open"}

      assert Validator.validate_record_payload(@definition, field_values) == []
    end

    test ":json field accepts any JSON value (object, array, string, number, boolean, null)" do
      base = %{"customer_name" => "Acme", "age" => 42, "status" => "open"}

      for notes <- [%{"a" => 1}, [1, 2, 3], "a string", 5, true, nil] do
        field_values = Map.put(base, "notes", notes)
        assert Validator.validate_record_payload(@definition, field_values) == []
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AC2 -- a payload violating 3+ distinct fields returns ALL violations, not
  # only the first.
  # ---------------------------------------------------------------------------

  describe "AC2 -- multiple independent field violations in one submission are all reported" do
    test "a payload violating 3 distinct fields' constraints returns all 3 (plus the missing-required) violations" do
      field_values = %{
        # wrong type (string instead of integer)
        "age" => "not-a-number",
        # not in enum
        "status" => "archived",
        # additionalProperties: false violation
        "unexpected_field" => "surprise"
        # "customer_name" (required) is missing entirely
      }

      violations = Validator.validate_record_payload(@definition, field_values)

      constraints = Enum.map(violations, & &1.constraint)
      field_paths = Enum.map(violations, & &1.field_path)

      assert "type" in constraints
      assert "enum" in constraints
      assert "additionalProperties" in constraints
      assert "required" in constraints

      assert "/age" in field_paths
      assert "/status" in field_paths
      assert "/unexpected_field" in field_paths
      assert "/customer_name" in field_paths

      # exactly one violation for each of the 4 distinct problems above --
      # confirms nothing short-circuited on the first failure.
      assert length(violations) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # AC3 -- each violation carries a correct (field_path, constraint, actual)
  # triple.
  # ---------------------------------------------------------------------------

  describe "AC3 -- each violation carries the correct field_path/constraint/actual triple" do
    test "a type violation reports the offending field's pointer, constraint name, and actual value" do
      field_values = %{"customer_name" => "Acme", "age" => "forty-two", "status" => "open"}

      assert [violation] = Validator.validate_record_payload(@definition, field_values)

      assert %ValidationFailure{
               field_path: "/age",
               constraint: "type",
               actual: "forty-two"
             } == violation
    end

    test "a required violation reports the missing field's pointer with actual: nil" do
      field_values = %{"age" => 42, "status" => "open"}

      assert [violation] = Validator.validate_record_payload(@definition, field_values)

      assert %ValidationFailure{
               field_path: "/customer_name",
               constraint: "required",
               actual: nil
             } == violation
    end

    test "an enum violation reports the offending field's pointer and the rejected value" do
      field_values = %{"customer_name" => "Acme", "age" => 42, "status" => "pending"}

      assert [violation] = Validator.validate_record_payload(@definition, field_values)

      assert %ValidationFailure{
               field_path: "/status",
               constraint: "enum",
               actual: "pending"
             } == violation
    end
  end

  # ---------------------------------------------------------------------------
  # AC4 -- the validation engine used is Letflow.EventStore.Registry.JsonSchema,
  # not a hand-rolled one.
  # ---------------------------------------------------------------------------

  describe "AC4 -- delegates to Letflow.EventStore.Registry.JsonSchema, not a hand-rolled engine" do
    test "validate_record_payload/2's result is identical to calling JsonSchema.validate/2 directly on the derived schema" do
      field_values = %{"customer_name" => "Acme", "age" => "bad", "status" => "nope"}

      schema = Validator.build_record_schema(@definition)

      assert Validator.validate_record_payload(@definition, field_values) ==
               JsonSchema.validate(field_values, schema)
    end

    test "build_record_schema/1 produces a plain string-keyed map consumable by JsonSchema.validate/2 directly" do
      schema = Validator.build_record_schema(@definition)

      assert schema == %{
               "type" => "object",
               "properties" => %{
                 "customer_name" => %{"type" => "string"},
                 "age" => %{"type" => "integer"},
                 "balance" => %{"type" => "number"},
                 "active" => %{"type" => "boolean"},
                 "signed_up_on" => %{"type" => "string"},
                 "last_login_at" => %{"type" => "string"},
                 "status" => %{"type" => "string", "enum" => ["open", "closed"]},
                 "notes" => %{}
               },
               "required" => ["customer_name", "age", "status"],
               "additionalProperties" => false
             }
    end
  end

  # ---------------------------------------------------------------------------
  # Design §4.2's worked example, exercised directly.
  # ---------------------------------------------------------------------------

  describe "design doc §4.2 worked example" do
    test "matches the design doc's literal derived-schema shape" do
      definition = %{
        name: "widget",
        display_name: "Widget",
        fields: [
          %{name: "customer_name", type: :string, required: true},
          %{name: "status", type: :enum, enum_values: ["open", "closed"], required: false},
          %{name: "notes", type: :json}
        ]
      }

      assert Validator.build_record_schema(definition) == %{
               "type" => "object",
               "properties" => %{
                 "customer_name" => %{"type" => "string"},
                 "status" => %{"type" => "string", "enum" => ["open", "closed"]},
                 "notes" => %{}
               },
               "required" => ["customer_name"],
               "additionalProperties" => false
             }
    end
  end
end
