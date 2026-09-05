defmodule Letflow.Api.Validation.FieldConstraint do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  A single field constraint within a `Letflow.Api.Validation` schema. Ports
  `validation.zig`'s `FieldConstraint` struct — see
  `lib/letflow/design/req068-validation.md` §0.6-§0.8 for the two fields
  (`:uuid` as a type, `allowed_values`) that are real additions over the Zig
  source, not literal ports.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            required: false,
            type: nil,
            reject_empty_string: false,
            min_length: nil,
            max_length: nil,
            min_value: nil,
            max_value: nil,
            min_items: nil,
            max_items: nil,
            allowed_values: nil

  @type json_type :: :string | :number | :integer | :boolean | :object | :array | :uuid

  @type t :: %__MODULE__{
          name: String.t(),
          required: boolean(),
          type: json_type() | nil,
          reject_empty_string: boolean(),
          min_length: non_neg_integer() | nil,
          max_length: non_neg_integer() | nil,
          min_value: number() | nil,
          max_value: number() | nil,
          min_items: non_neg_integer() | nil,
          max_items: non_neg_integer() | nil,
          allowed_values: [term()] | nil
        }
end

defmodule Letflow.Api.Validation.FieldError do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  A single field-level validation error. Ports `validation.zig`'s `FieldError`
  struct 1:1 (field/constraint/message/received).
  """

  @derive Jason.Encoder
  @enforce_keys [:field, :constraint, :message]
  defstruct [:field, :constraint, :message, received: nil]

  @type t :: %__MODULE__{
          field: String.t(),
          constraint: String.t(),
          message: String.t(),
          received: term()
        }
end

defmodule Letflow.Api.Validation do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Request-body schema validation — ports `src/api/validation.zig` (592 lines).
  `middleware/validate.zig` (86 lines) is not ported as a separate module: its
  only job was calling this module's `validate/2`-equivalent and mapping the
  result to an HTTP response, which collapses into `problem/1` plus the
  caller pattern-matching `validate/2`'s own tagged return — see
  `lib/letflow/design/req068-validation.md` §0.1.

  Pure: no `Plug.Conn`, no I/O, never raises on any input (INV-8) — every
  function here returns a tagged value or `nil`, including for malformed or
  unexpected input shapes. The one thing this module does NOT see is a
  request whose body was not valid JSON at all: `Letflow.Plugs.SafeJsonParser`
  intercepts that before this module runs (design doc §0.3), so `validate/2`'s
  `body` parameter is always *some* already-decoded JSON term — a map for a
  well-formed object, but potentially anything else JSON can decode to (a
  list, a number, a string, `nil`, `true`/`false`), which `validate/2` handles
  structurally before any per-field constraint runs (§0.9).

  ## Security invariants

  * **INV-8** — never raises. Every branch below either returns a value or
    falls through to a named `FieldError`; there is no bare `case` without a
    catch-all clause and no `Map.fetch!/2` on caller-supplied data anywhere in
    this module.
  * A NUL byte (`0x00`) anywhere inside a string value in the decoded body —
    not only in schema-declared fields — is rejected structurally before any
    `FieldConstraint` runs, because PostgreSQL text/varchar columns reject it
    outright and this module is the last place to catch that cheaply before a
    later `Repo` call would raise. See design doc §0.9 point 3.
  * SQL metacharacters in a string value are deliberately NOT checked here.
    Every `Repo`/`Ecto.Query` call in this codebase is parameterised; a
    validator-level block on `'`/`;`/`--` would add no real defence and would
    reject legitimate values (e.g. a `description` containing an apostrophe).
    See design doc §0.9 point 5.

  ## Scope boundary

  PROVENANCE (historical, not current decision authority):
  This module, and REQ-068 as a whole, does **not** port `src/api/middleware/
  rate_limit.zig` or `src/api/middleware/quota_enforcement.zig`. Both need
  per-tenant counter storage that no Letflow requirement has built yet;
  bolting a counter store onto a validation requirement would be the
  partial-subsystem failure REQ-056's boundary paragraph exists to prevent.
  They belong to their own later requirement, or to S6 alongside the rest of
  the operational cross-cutting work.
  """

  alias Letflow.Api.Error
  alias Letflow.Api.Validation.{FieldConstraint, FieldError}

  @type schema :: [FieldConstraint.t()]

  @doc """
  Validate a single field's decoded JSON value against one constraint.

  PROVENANCE (historical, not current decision authority):
  `value` is `:missing` when the field key was absent from the body (as
  opposed to present with a JSON `null`, which decodes to Elixir `nil` and is
  passed through as `nil` — R-Co's `validateField` treats an absent key and a
  present `null` identically, per `validation.zig:162` checking
  `json_value == null or json_value.? == .null` as one condition; ported the
  same way here).

  PROVENANCE (historical, not current decision authority):
  Returns `nil` when the value passes every check the constraint declares, or
  the first violated `FieldError.t()` otherwise — `validation.zig` returns on
  the first per-field failure too (`validate/2` below is what collects one
  error per *field*, across *all* fields; a single field can only ever
  contribute one error, matching the source).
  """
  @spec validate_field(FieldConstraint.t(), term() | :missing) :: FieldError.t() | nil
  def validate_field(%FieldConstraint{} = c, value) do
    present? = value != :missing and value != nil

    cond do
      c.required and not present? ->
        %FieldError{field: c.name, constraint: "required", message: "field is required"}

      not present? ->
        nil

      c.reject_empty_string and value == "" ->
        if c.required do
          %FieldError{field: c.name, constraint: "required", message: "field is required"}
        else
          %FieldError{
            field: c.name,
            constraint: "not_empty",
            message: "field must not be empty",
            received: value
          }
        end

      c.type != nil and not type_ok?(value, c.type) ->
        %FieldError{
          field: c.name,
          constraint: type_constraint_name(c.type),
          message: type_mismatch_message(c.type),
          received: value
        }

      (err = string_length_error(c, value)) != nil ->
        err

      (err = numeric_range_error(c, value)) != nil ->
        err

      (err = array_size_error(c, value)) != nil ->
        err

      c.allowed_values != nil and value not in c.allowed_values ->
        %FieldError{
          field: c.name,
          constraint: "enum_membership",
          message: "value is not one of the allowed values",
          received: value
        }

      true ->
        nil
    end
  end

  @doc """
  PROVENANCE (historical, not current decision authority):
  Validate a decoded request body against a schema, collecting **every**
  violated constraint rather than stopping at the first — mirrors
  `validation.zig:404` ("If there are field-level errors, return them all").

  PROVENANCE (historical, not current decision authority):
  Structural checks (§0.9 of the design doc) run first and, if either fires,
  short-circuit before any `FieldConstraint` is evaluated — the same
  early-return shape as `validate/4`'s own "must be an object" check
  (`validation.zig:377-386`).

  PROVENANCE (historical, not current decision authority):
  ## Two different R-Co files are called `validation.zig`. They are unrelated.

    PROVENANCE (historical, not current decision authority):
    * `src/api/validation.zig` (592 lines) is the **request-body validator** —
      API-07, which checks an *incoming JSON request payload* against a
      field-constraint schema and returns RFC 9457 field errors. **That is
      this module** (REQ-068).
    PROVENANCE (historical, not current decision authority):
    * `src/api/routes/validation.zig` (173 lines) is the **definition-graph
      validation endpoint** — `POST /api/v1/definitions/:id/validate`,
      VLD-01/02/03, which runs validators over a *stored process-definition
      graph*. It has nothing to do with request bodies. **That is ported by
      REQ-078, onto `Letflow.Routers.Definitions`.**

  Do not conflate them, and do not "consolidate" them: they validate different
  things at different layers. `Letflow.Routers.Definitions`'s moduledoc
  carries the full statement of this distinction, so a reader arriving from
  either side finds it.
  """
  @spec validate(schema(), term()) :: {:ok, map()} | {:errors, [FieldError.t(), ...]}
  def validate(schema, body) when is_list(schema) do
    with :ok <- check_is_object(body),
         :ok <- check_no_null_bytes(body) do
      errors =
        Enum.reduce(schema, [], fn constraint, acc ->
          value = Map.get(body, constraint.name, :missing)

          case validate_field(constraint, value) do
            nil -> acc
            %FieldError{} = err -> [err | acc]
          end
        end)
        |> Enum.reverse()

      case errors do
        [] ->
          fields = Enum.map(schema, & &1.name)
          {:ok, Map.take(body, fields)}

        errs ->
          {:errors, errs}
      end
    else
      {:error, err} -> {:errors, [err]}
    end
  end

  @doc """
  Build the RFC 9457 problem document (with the validation-specific `errors`
  array extension, design doc §0.5) for a non-empty error list. Ports
  `serialiseValidationErrors/2`'s status/type/title choice (422) without
  re-implementing JSON serialisation — `Letflow.Api.Error`/`Response` (REQ-066)
  own that.
  """
  @spec problem([FieldError.t(), ...]) :: Error.t()
  def problem([_ | _] = field_errors) do
    %{Error.unprocessable("validation failed") | errors: field_errors}
  end

  # ── Structural checks (§0.9) ────────────────────────────────────────────

  @spec check_is_object(term()) :: :ok | {:error, FieldError.t()}
  defp check_is_object(body) when is_map(body), do: :ok

  defp check_is_object(_other) do
    {:error,
     %FieldError{
       field: "(root)",
       constraint: "type.object",
       message: "request body must be a JSON object"
     }}
  end

  @spec check_no_null_bytes(term()) :: :ok | {:error, FieldError.t()}
  defp check_no_null_bytes(body) do
    case find_null_byte(body, "(root)") do
      nil ->
        :ok

      path ->
        {:error,
         %FieldError{
           field: path,
           constraint: "no_null_byte",
           message: "string values must not contain a NUL byte"
         }}
    end
  end

  # Recursive walk over the fully-decoded body. Every clause either recurses
  # into a known container shape or falls through to the final `_ -> nil`
  # catch-all (INV-8: no assumed shape, no raise).
  @spec find_null_byte(term(), String.t()) :: String.t() | nil
  defp find_null_byte(s, path) when is_binary(s) do
    if String.contains?(s, <<0>>), do: path, else: nil
  end

  defp find_null_byte(m, path) when is_map(m) do
    Enum.find_value(m, fn {k, v} ->
      find_null_byte(v, "#{path}.#{k}")
    end)
  end

  defp find_null_byte(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.find_value(fn {v, i} -> find_null_byte(v, "#{path}[#{i}]") end)
  end

  defp find_null_byte(_other, _path), do: nil

  # ── Per-constraint checks ───────────────────────────────────────────────

  @spec type_ok?(term(), FieldConstraint.json_type()) :: boolean()
  defp type_ok?(v, :string), do: is_binary(v)
  defp type_ok?(v, :number), do: is_number(v)
  defp type_ok?(v, :integer), do: is_integer(v)
  defp type_ok?(v, :boolean), do: is_boolean(v)
  defp type_ok?(v, :object), do: is_map(v)
  defp type_ok?(v, :array), do: is_list(v)
  defp type_ok?(v, :uuid), do: is_binary(v) and match?({:ok, _}, Ecto.UUID.cast(v))
  defp type_ok?(_v, _unknown), do: false

  @spec type_constraint_name(FieldConstraint.json_type()) :: String.t()
  defp type_constraint_name(:string), do: "type.string"
  defp type_constraint_name(:number), do: "type.number"
  defp type_constraint_name(:integer), do: "type.integer"
  defp type_constraint_name(:boolean), do: "type.boolean"
  defp type_constraint_name(:object), do: "type.object"
  defp type_constraint_name(:array), do: "type.array"
  defp type_constraint_name(:uuid), do: "type.uuid"

  @spec type_mismatch_message(FieldConstraint.json_type()) :: String.t()
  defp type_mismatch_message(:string), do: "expected string"
  defp type_mismatch_message(:number), do: "expected number"
  defp type_mismatch_message(:integer), do: "expected integer"
  defp type_mismatch_message(:boolean), do: "expected boolean"
  defp type_mismatch_message(:object), do: "expected object"
  defp type_mismatch_message(:array), do: "expected array"
  defp type_mismatch_message(:uuid), do: "expected a UUID string"

  @spec string_length_error(FieldConstraint.t(), term()) :: FieldError.t() | nil
  defp string_length_error(%FieldConstraint{} = c, value) when is_binary(value) do
    len = String.length(value)

    cond do
      c.min_length != nil and len < c.min_length ->
        %FieldError{
          field: c.name,
          constraint: "min_length",
          message: "length must be ≥ minimum",
          received: value
        }

      c.max_length != nil and len > c.max_length ->
        %FieldError{
          field: c.name,
          constraint: "max_length",
          message: "length must be ≤ maximum",
          received: value
        }

      true ->
        nil
    end
  end

  defp string_length_error(_c, _value), do: nil

  @spec numeric_range_error(FieldConstraint.t(), term()) :: FieldError.t() | nil
  defp numeric_range_error(%FieldConstraint{} = c, value) when is_number(value) do
    cond do
      c.min_value != nil and value < c.min_value ->
        %FieldError{
          field: c.name,
          constraint: "min_value",
          message: "value must be ≥ minimum",
          received: value
        }

      c.max_value != nil and value > c.max_value ->
        %FieldError{
          field: c.name,
          constraint: "max_value",
          message: "value must be ≤ maximum",
          received: value
        }

      true ->
        nil
    end
  end

  defp numeric_range_error(_c, _value), do: nil

  @spec array_size_error(FieldConstraint.t(), term()) :: FieldError.t() | nil
  defp array_size_error(%FieldConstraint{} = c, value) when is_list(value) do
    len = length(value)

    cond do
      c.min_items != nil and len < c.min_items ->
        %FieldError{
          field: c.name,
          constraint: "min_items",
          message: "array must have ≥ minimum items",
          received: value
        }

      c.max_items != nil and len > c.max_items ->
        %FieldError{
          field: c.name,
          constraint: "max_items",
          message: "array must have ≤ maximum items",
          received: value
        }

      true ->
        nil
    end
  end

  defp array_size_error(_c, _value), do: nil
end
