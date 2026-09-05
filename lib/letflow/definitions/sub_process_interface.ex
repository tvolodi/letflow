defmodule Letflow.Definitions.SubProcessInterface do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Definition-time (SPC-02) half of a `:SUB_PROCESS` node's optional
  `interface` attribute: parses and validates the well-formedness of the
  `inputs`/`outputs` entry lists and each entry's `json_schema`. Ported from
  `src/definition/sub_process_interface.zig` per
  `lib/letflow/design/req032-sub-process-interface-contract.md` (the
  gate-approved design this module implements) — called from
  `Letflow.Definitions.Graph`'s CHK-18 (`check_sub_process_interface/1`),
  hooked into REQ-029's PD-05 node-attribute validation pass.

  PROVENANCE (historical, not current decision authority):
  This module ports only the SPC-02 (definition-time) half of R-Co's
  `src/definition/sub_process_interface.zig`, per
  `src/design/spc-01-sub-process-interface-contract.md` — the file's own
  header documents two halves: SPC-02 (definition-time interface
  parsing/validation, invoked from `graph.zig`'s `checkSubProcess`, hooked
  into PD-05 node-attribute validation) and SPC-01 (runtime
  activation/completion helpers, invoked from `src/engine/instance.zig`).
  **SPC-01 is explicitly out of this module's scope.** It belongs to Stage 3
  (`src/engine/` port), since it requires a running instance/token model
  that does not exist yet in Letflow — `src/engine/instance.zig` is SPC-01's
  future integration point once S3 builds it. Nothing in this module
  activates, completes, or otherwise executes a sub-process at runtime; it
  only validates that a SUB_PROCESS node's optional `interface` attribute is
  well-formed at definition time.

  ## Purity

  Depends on Elixir/Erlang stdlib only (`Enum`, `Map`, `String`, `Kernel`) —
  no `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no
  HTTP/file/process-mailbox call anywhere, matching `Letflow.Definitions.Graph`'s
  own zero-I/O contract.

  ## Never mutates or re-serializes what it validates

  `parse_interface/2`'s `parsed_interface()` return value is a
  validation-internal artifact only — it is never returned to, or used by,
  any persistence path. A well-formed `interface` attribute is persisted
  unchanged as part of the node's original `attributes` map by whatever
  caller owns that persistence (REQ-027/030's concern, unaffected by this
  module).
  """

  alias Letflow.Definitions.Graph.Violation

  @type entry :: %{name: String.t(), json_schema: map(), required: boolean()}

  @type parsed_interface :: %{inputs: [entry()], outputs: [entry()]}

  @max_schema_depth 32

  @supported_schema_keywords MapSet.new([
                               "type",
                               "minimum",
                               "maximum",
                               "minLength",
                               "maxLength",
                               "enum",
                               "required",
                               "properties",
                               "items",
                               "additionalProperties"
                             ])

  @doc """
  Check-list entry point (CHK-18) — extracts the `"interface"` key from
  `attributes` (if `attributes` is a map at all), parses it, and returns
  just the violations. Total and defensive: never raises, always returns a
  list (possibly `[]`).
  """
  @spec validate_node_interface(node_id :: String.t(), attributes :: map() | nil) ::
          [Violation.t()]
  def validate_node_interface(node_id, attributes) do
    interface_value =
      if is_map(attributes), do: Map.get(attributes, "interface"), else: nil

    {_parsed, violations} = parse_interface(node_id, interface_value)
    violations
  end

  @doc """
  Parses and validates a SUB_PROCESS node's `interface` attribute value.
  Public, standalone-testable — no `Graph.t()`/`Node.t()` construction
  required. `interface_value == nil` (the attribute absent entirely) is
  valid, not a violation, since `interface` is optional for SUB_PROCESS —
  unlike CHK-09..12, where an absent required attribute always triggers a
  violation.
  """
  @spec parse_interface(node_id :: String.t(), interface_value :: term()) ::
          {parsed_interface() | nil, [Violation.t()]}
  def parse_interface(_node_id, nil), do: {nil, []}

  def parse_interface(node_id, interface_value) when not is_map(interface_value) do
    {nil,
     [
       %Violation{
         code: :sub_process_interface_not_object,
         message:
           "Node '#{node_id}' has a SUB_PROCESS interface attribute that is not a JSON object"
       }
     ]}
  end

  def parse_interface(node_id, interface_value) when is_map(interface_value) do
    inputs_raw = Map.get(interface_value, "inputs", [])
    outputs_raw = Map.get(interface_value, "outputs", [])

    {parsed_inputs, inputs_not_array_violations} =
      validate_list_shape(node_id, "inputs", inputs_raw, :sub_process_interface_inputs_not_array)

    {parsed_outputs, outputs_not_array_violations} =
      validate_list_shape(
        node_id,
        "outputs",
        outputs_raw,
        :sub_process_interface_outputs_not_array
      )

    {input_entries, input_entry_violations} =
      case parsed_inputs do
        nil -> {[], []}
        list -> parse_entries(node_id, "inputs", list)
      end

    {output_entries, output_entry_violations} =
      case parsed_outputs do
        nil -> {[], []}
        list -> parse_entries(node_id, "outputs", list)
      end

    input_duplicate_violations = check_duplicate_names(node_id, "inputs", input_entries)
    output_duplicate_violations = check_duplicate_names(node_id, "outputs", output_entries)

    all_violations =
      inputs_not_array_violations ++
        outputs_not_array_violations ++
        input_entry_violations ++
        output_entry_violations ++
        input_duplicate_violations ++
        output_duplicate_violations

    {%{inputs: input_entries, outputs: output_entries}, all_violations}
  end

  # `raw` is the value of the `"inputs"`/`"outputs"` key (defaulting to `[]`
  # when absent, §5.3 step 3a). Returns `{list_or_nil, violations}` --
  # `nil` when `raw` is not a list (so the caller skips entry/duplicate-name
  # parsing entirely), the list itself otherwise.
  @spec validate_list_shape(String.t(), String.t(), term(), Violation.code()) ::
          {[term()] | nil, [Violation.t()]}
  defp validate_list_shape(_node_id, _list_name, raw, _code) when is_list(raw), do: {raw, []}

  defp validate_list_shape(node_id, list_name, _raw, code) do
    {nil,
     [
       %Violation{
         code: code,
         message: "Node '#{node_id}' SUB_PROCESS interface's '#{list_name}' is not a JSON array"
       }
     ]}
  end

  # Per-list entry parsing and shape/schema checks (§5.3.1). For each
  # element of `raw_entries` (order preserved): `_ENTRY_INVALID` is checked
  # first and is exclusive of `_SCHEMA_INVALID` -- if the shape check fails,
  # the entry is excluded from the returned `[entry()]` and no schema check
  # is attempted. Otherwise, `validate_schema_shape/2` runs on the entry's
  # `json_schema` at depth 1; a `false` result produces `_SCHEMA_INVALID`
  # but the entry is still included in the returned list (its tuple shape is
  # valid, only the nested schema failed).
  @spec parse_entries(String.t(), String.t(), [term()]) :: {[entry()], [Violation.t()]}
  defp parse_entries(node_id, list_name, raw_entries) do
    raw_entries
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {raw_entry, index}, {entries, violations} ->
      case entry_shape_error(raw_entry) do
        {:error, reason} ->
          violation = %Violation{
            code: :sub_process_interface_entry_invalid,
            message:
              "Node '#{node_id}' SUB_PROCESS interface's '#{list_name}' entry at index " <>
                "#{index} is invalid: #{reason}"
          }

          {entries, violations ++ [violation]}

        :ok ->
          name = Map.fetch!(raw_entry, "name")
          json_schema = Map.fetch!(raw_entry, "json_schema")
          required = Map.get(raw_entry, "required", false)

          if validate_schema_shape(json_schema, 1) do
            entry = %{name: name, json_schema: json_schema, required: required}
            {entries ++ [entry], violations}
          else
            entry = %{name: name, json_schema: json_schema, required: required}

            violation = %Violation{
              code: :sub_process_interface_schema_invalid,
              message:
                "Node '#{node_id}' SUB_PROCESS interface's '#{list_name}' entry '#{name}' " <>
                  "has a malformed json_schema"
            }

            {entries ++ [entry], violations ++ [violation]}
          end
      end
    end)
  end

  # Returns `:ok` if `raw_entry` has the well-formed entry-tuple shape
  # (§5.3.1 point 1), `{:error, reason}` otherwise -- checked first and
  # exclusive of the deeper json_schema well-formedness check.
  @spec entry_shape_error(term()) :: :ok | {:error, String.t()}
  defp entry_shape_error(raw_entry) when not is_map(raw_entry) do
    {:error, "entry is not a JSON object"}
  end

  defp entry_shape_error(raw_entry) do
    cond do
      not valid_entry_name?(raw_entry) ->
        {:error, "'name' is missing, not a string, or blank"}

      not valid_entry_json_schema_presence?(raw_entry) ->
        {:error, "'json_schema' is missing or not a JSON object"}

      not valid_entry_required_field?(raw_entry) ->
        {:error, "'required' is present but not a boolean"}

      true ->
        :ok
    end
  end

  @spec valid_entry_name?(map()) :: boolean()
  defp valid_entry_name?(raw_entry) do
    case Map.get(raw_entry, "name") do
      name when is_binary(name) -> String.trim(name) != ""
      _other -> false
    end
  end

  @spec valid_entry_json_schema_presence?(map()) :: boolean()
  defp valid_entry_json_schema_presence?(raw_entry) do
    is_map(Map.get(raw_entry, "json_schema"))
  end

  @spec valid_entry_required_field?(map()) :: boolean()
  defp valid_entry_required_field?(raw_entry) do
    case Map.fetch(raw_entry, "required") do
      :error -> true
      {:ok, value} -> is_boolean(value)
    end
  end

  # Per-list duplicate-name detection (§5.3.2): for each `entries[i]`
  # (`i > 0`) whose `name` exactly equals some earlier `entries[j]`'s name,
  # emit one violation. N occurrences of a repeated name -> N-1 violations
  # (same convention as CHK-05/CHK-16). Exact `String.t()` equality, no
  # trim/case-fold. `inputs`/`outputs` do not share a duplicate-name
  # namespace -- checked independently per list.
  @spec check_duplicate_names(String.t(), String.t(), [entry()]) :: [Violation.t()]
  defp check_duplicate_names(node_id, list_name, entries) do
    entries
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, index} ->
      earlier = Enum.take(entries, index)

      if Enum.any?(earlier, &(&1.name == entry.name)) do
        [
          %Violation{
            code: :sub_process_interface_duplicate_name,
            message:
              "Node '#{node_id}' SUB_PROCESS interface's '#{list_name}' has a duplicate " <>
                "entry name '#{entry.name}'"
          }
        ]
      else
        []
      end
    end)
  end

  @doc """
  JSON-Schema-of-schemas well-formedness check. Returns a `boolean()`, not a
  violation list -- a deliberate divergence from this file's usual
  violation-collecting convention (design doc §6): it answers one yes/no
  structural question about one `json_schema` value.

  Depth convention: the entry's own top-level `json_schema` is passed at
  `depth = 1`. Each recursive descent into a nested schema (via
  `"properties"`'s values, `"items"`, or a map-valued
  `"additionalProperties"`) increments depth by 1. A call made with
  `depth > 32` returns `false` immediately without inspecting `schema`
  further -- a schema nested exactly 32 levels deep is the maximum accepted
  depth; a 33rd level is rejected.

  Unknown/unsupported keywords (anything outside the 8-keyword supported
  set: `type`, `minimum`, `maximum`, `minLength`, `maxLength`, `enum`,
  `required`, `properties`, `items`, `additionalProperties`) are permitted
  and inert -- skipped entirely, never validated or recursed into,
  regardless of their value.
  """
  @spec validate_schema_shape(schema :: term(), depth :: pos_integer()) :: boolean()
  def validate_schema_shape(_schema, depth) when depth > @max_schema_depth, do: false

  def validate_schema_shape(schema, _depth) when not is_map(schema), do: false

  def validate_schema_shape(schema, depth) do
    schema
    |> Enum.filter(fn {key, _value} -> MapSet.member?(@supported_schema_keywords, key) end)
    |> Enum.all?(fn {key, value} -> valid_schema_keyword?(key, value, depth) end)
  end

  @spec valid_schema_keyword?(String.t(), term(), pos_integer()) :: boolean()
  defp valid_schema_keyword?("type", value, _depth), do: is_binary(value) and value != ""

  defp valid_schema_keyword?("minimum", value, _depth), do: is_number(value)

  defp valid_schema_keyword?("maximum", value, _depth), do: is_number(value)

  defp valid_schema_keyword?("minLength", value, _depth),
    do: is_integer(value) and value >= 0

  defp valid_schema_keyword?("maxLength", value, _depth),
    do: is_integer(value) and value >= 0

  defp valid_schema_keyword?("enum", value, _depth), do: is_list(value)

  defp valid_schema_keyword?("required", value, _depth) do
    is_list(value) and Enum.all?(value, &is_binary/1)
  end

  defp valid_schema_keyword?("properties", value, depth) do
    is_map(value) and
      Enum.all?(value, fn {_prop_name, prop_schema} ->
        validate_schema_shape(prop_schema, depth + 1)
      end)
  end

  defp valid_schema_keyword?("items", value, depth) do
    is_map(value) and validate_schema_shape(value, depth + 1)
  end

  defp valid_schema_keyword?("additionalProperties", value, depth) do
    is_boolean(value) or (is_map(value) and validate_schema_shape(value, depth + 1))
  end
end
