defmodule Letflow.Definitions.JsonSchemaShape do
  @moduledoc """
  The pure well-formedness predicate for a stored JSON Schema document
  (REQ-078, design `lib/letflow/design/req078-supporting-routes.md` §9.3).

  ## Why this module exists, and why it is a leaf

  `variable_schemas.json_schema` is a `NOT NULL jsonb` column, not a
  `NOT NULL json-OBJECT` column: Postgres accepts an array, a string, a
  number or a boolean there just as readily as an object. Two read-side
  defects were latent behind that (`ISS-0089`/GH#306 and `ISS-0088`/GH#305),
  reachable for the first time the moment any code writes a row. REQ-078
  chose option (a) from its own requirement text — **validate before insert**
  — so a malformed document is rejected at install/import time with a typed
  error naming the offending `variable_key`, rather than raising hours later
  inside an open transaction on a task completion.

  Both `Letflow.Definitions` (the single registration/insert path,
  `Letflow.Definitions.register_variable_schemas/3`) and
  `Letflow.Engine.VariableSchema` (the changeset every writer must go
  through) call this function. It lives in its own leaf module rather than on
  `Letflow.Definitions` specifically so that `Letflow.Engine.VariableSchema`
  does not have to call *into* `Letflow.Definitions` — an Engine → Definitions
  dependency is the wrong direction (design OQ-2, ruled).

  Pure: no `Repo`, no clock, no `Plug.Conn`, no logging. Exactly one public
  function.

  ## What "well formed" means here

  Deliberately structural and shallow in vocabulary, deep in reach. A document
  is well formed iff:

    * it is a JSON object (a plain `map()`), **at every level**;
    * if it carries `"properties"`, that value is itself an object and every
      value inside it is itself well formed;
    * if it carries `"items"`, that value is itself well formed.

  This is exactly the shape `Letflow.EventStore.Registry.JsonSchema.validate/2`
  can consume without raising — it is not a JSON Schema *meta-schema*
  implementation, and it deliberately does not check keyword vocabularies,
  `$ref` resolution, or type names. Widening it into a meta-schema validator
  would be a new subsystem, not a route port.

  `"items"` is treated as a single subschema. JSON Schema draft-04-style
  tuple validation (`"items"` as an *array* of schemas) is therefore rejected
  as not well formed. That matches what Letflow's own validator supports
  today; if tuple validation is ever added there, this predicate must be
  widened in the same change.

  ## Depth bound (INV-8)

  The recursion is bounded by `@max_depth` (32). Caller-supplied input must
  not be able to drive unbounded recursion, so a document nested deeper than
  that returns `{:error, :too_deep}` rather than being walked. This is a
  distinct error from `{:error, {:not_well_formed, path}}` so the two failure
  modes stay distinguishable in a log and in the 422 detail the route emits.

  ## The path

  `{:error, {:not_well_formed, path}}` carries the JSON-pointer-style segment
  path to the **first** offending level, so the submitter can be told where
  their document went wrong. `[]` means the top level itself is not an
  object. Property keys are walked in sorted order so "first" is
  deterministic — map iteration order is not part of any contract.
  """

  @max_depth 32

  @doc """
  True (`:ok`) iff `document` is a well-formed JSON Schema document at every
  level. See the moduledoc for the exact definition, the depth bound and the
  meaning of `path`.

  Never raises on any input: a struct, a binary, a number, `nil` and a deeply
  nested map are all answered with a tagged tuple.
  """
  @spec check(document :: term()) ::
          :ok | {:error, {:not_well_formed, path :: [String.t()]}} | {:error, :too_deep}
  def check(document), do: check_level(document, [], 0)

  # `path` is accumulated reversed; `Enum.reverse/1` at the point of failure.
  @spec check_level(term(), [String.t()], non_neg_integer()) ::
          :ok | {:error, {:not_well_formed, [String.t()]}} | {:error, :too_deep}
  defp check_level(_document, _path, depth) when depth > @max_depth, do: {:error, :too_deep}

  defp check_level(document, path, depth) when is_map(document) and not is_struct(document) do
    with :ok <- check_properties(Map.get(document, "properties", :absent), path, depth) do
      check_items(Map.get(document, "items", :absent), path, depth)
    end
  end

  defp check_level(_not_an_object, path, _depth),
    do: {:error, {:not_well_formed, Enum.reverse(path)}}

  @spec check_properties(term(), [String.t()], non_neg_integer()) ::
          :ok | {:error, {:not_well_formed, [String.t()]}} | {:error, :too_deep}
  defp check_properties(:absent, _path, _depth), do: :ok

  defp check_properties(properties, path, depth)
       when is_map(properties) and not is_struct(properties) do
    properties
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.reduce_while(:ok, fn {key, subschema}, :ok ->
      case check_level(subschema, [to_string(key), "properties" | path], depth + 1) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_properties(_not_an_object, path, _depth),
    do: {:error, {:not_well_formed, Enum.reverse(["properties" | path])}}

  @spec check_items(term(), [String.t()], non_neg_integer()) ::
          :ok | {:error, {:not_well_formed, [String.t()]}} | {:error, :too_deep}
  defp check_items(:absent, _path, _depth), do: :ok

  defp check_items(items, path, depth), do: check_level(items, ["items" | path], depth + 1)
end
