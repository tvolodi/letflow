defmodule Letflow.Entities.Record.Validator do
  @moduledoc """
  Validates one entity record's `field_values` payload against the
  JSON-Schema-shaped constraint set derived from its REQ-225
  `Letflow.Entities.Definition.t()` document (REQ-227). See
  `lib/letflow/design/req227-entity-record-payload-validation.md` for the
  full design this module implements.

  ## Reuses `Letflow.EventStore.Registry.JsonSchema` -- no second engine

  This module performs **no constraint-checking logic of its own**.
  `build_record_schema/1` only reshapes a REQ-225 definition's `fields` list
  into a plain, string-keyed JSON-Schema-shaped map (data reshaping, not
  evaluation); `validate_record_payload/2` then delegates the actual
  checking to the existing `Letflow.EventStore.Registry.JsonSchema.validate/2`
  (REQ-024), returning its violation list unchanged. See the design doc §5.1
  for why this cross-namespace reach is accepted as-is rather than extracting
  a shared top-level module: `JsonSchema` is already a pure, dependency-free
  leaf module with an existing cross-namespace caller
  (`Letflow.Definitions.JsonSchemaShape`), and extraction now would touch
  `Letflow.EventStore.Registry`'s own call site and tests for zero behavior
  change.

  ## Scope boundary

  This module validates only a record's `field_values` map against its
  definition's derived schema (the **inner** check). It does not validate
  the outer event envelope (`Letflow.EventStore.Registry.validate_payload/3`,
  a separate, pre-existing concern) and defines no route, controller, event
  registration, or command function -- all REQ-228's job (design doc §3/§7).

  ## Malformed-shape precondition (design §4 preamble)

  `definition` is expected to have already passed
  `Letflow.Entities.Definition.Validator.validate/1` (`:ok`) -- same divide
  of responsibility `Letflow.Entities.Definition.Shape` already documents.
  `build_record_schema/1` does not re-run those structural rules.
  """

  alias Letflow.Entities.Definition
  alias Letflow.EventStore.Registry.JsonSchema
  alias Letflow.EventStore.Registry.ValidationFailure

  @typedoc "A record's already-decoded field name -> value map."
  @type field_values :: %{required(String.t()) => term()}

  @typedoc "A plain, string-keyed, JSON-Schema-shaped map -- `JsonSchema.validate/2`'s `schema` argument shape."
  @type record_schema :: map()

  @typedoc "The complete list of violations found. Empty means the payload conforms."
  @type violations :: [ValidationFailure.t()]

  @doc """
  Translates `definition`'s `fields` list into a JSON-Schema-shaped
  constraint map: `"type" => "object"`, one per-field subschema under
  `"properties"`, the `"required"` list (fields with `required: true`), and
  `"additionalProperties" => false`. See the design doc §4.1 for the full
  per-field-type keyword mapping and §4's explicit finding that
  `"minimum"`/`"maximum"`/`"maxLength"` are never emitted -- `field_def()`
  (REQ-225) carries no length- or range-constraint attribute to translate.
  """
  @spec build_record_schema(definition :: Definition.t()) :: record_schema()
  def build_record_schema(definition) do
    fields = Map.get(definition, :fields, [])

    %{
      "type" => "object",
      "properties" => Map.new(fields, &{Map.get(&1, :name), field_subschema(&1)}),
      "required" =>
        fields |> Enum.filter(&Map.get(&1, :required)) |> Enum.map(&Map.get(&1, :name)),
      "additionalProperties" => false
    }
  end

  @doc """
  Builds `definition`'s derived schema via `build_record_schema/1`, then
  validates `field_values` against it via
  `Letflow.EventStore.Registry.JsonSchema.validate/2`, returning its
  complete violation list unchanged (every violation, not just the first --
  inherited from `JsonSchema.validate/2` itself).
  """
  @spec validate_record_payload(definition :: Definition.t(), field_values :: field_values()) ::
          violations()
  def validate_record_payload(definition, field_values) do
    schema = build_record_schema(definition)
    JsonSchema.validate(field_values, schema)
  end

  # --- per-field type mapping (design §4.1) -----------------------------------

  defp field_subschema(%{type: :string}), do: %{"type" => "string"}
  defp field_subschema(%{type: :integer}), do: %{"type" => "integer"}
  defp field_subschema(%{type: :decimal}), do: %{"type" => "number"}
  defp field_subschema(%{type: :boolean}), do: %{"type" => "boolean"}
  defp field_subschema(%{type: :date}), do: %{"type" => "string"}
  defp field_subschema(%{type: :datetime}), do: %{"type" => "string"}

  defp field_subschema(%{type: :enum, enum_values: enum_values}),
    do: %{"type" => "string", "enum" => enum_values}

  defp field_subschema(%{type: :json}), do: %{}
end
