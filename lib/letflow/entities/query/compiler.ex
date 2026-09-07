defmodule Letflow.Entities.Query.Compiler do
  @moduledoc """
  `compiler.zig`-equivalent (REQ-230 §5) -- compiles an allowlisted
  filter/sort request into a parameterised `Ecto.Query.t()`. See
  `lib/letflow/design/req230-entity-query-dsl-compiler.md` §5 for the full
  design this module implements.

  This is layer 3 of the three-layer SQL-injection defence: by the time a
  clause reaches `build_filter_dynamic/2`/`build_order_by/2`, its `field`
  has already been resolved against `Letflow.Entities.Query.Allowlist`
  (layer 2) and its `op` has already been parsed against
  `Letflow.Entities.Query.Types`'s closed enum (layer 1) -- this module's
  own job is exclusively to ensure every remaining caller-supplied VALUE is
  bound as a genuine positional Ecto/Postgres parameter, never
  string-interpolated or concatenated into any SQL text (AC4, INV-7).

  ## The fragment-literal discipline (design §5.2, AC4's core mechanism)

  `fragment/1`'s first argument must be a compile-time-literal binary --
  Ecto's own compiler rejects any attempt to build that literal at runtime
  (`Ecto.Query.CompileError`, confirmed by `docs/anti-patterns.md`'s
  "Duplicating an `Ecto.Query.fragment/1` SQL literal" entry). This module
  never attempts to build a fragment literal at runtime: `build_filter_dynamic/2`
  is a pattern-matched function with one clause per `{source, op, field_type}`
  combination that needs JSONB access, each clause containing its own
  distinct `fragment/1` call whose literal string is fixed at compile time,
  chosen by which clause matches at runtime -- the same technique
  `lib/letflow/definitions.ex`'s `select_with_rank/3`/`order_by_rank/3` use
  for their shared `@rank_case_sql` literal.

  Both the JSONB **key name** (`^field_name`, already proven to be one of
  the finite names `Allowlist.load/2` enumerated for this entity type) and
  the comparison **value** (`^value`) are bound as separate `^`-bound Ecto
  parameters -- never spliced into the fragment text. This is strictly
  stronger than AC4's own wording requires (AC4 names the comparison value
  only) -- parameterising the key name too closes a second, related
  injection surface for free.

  `compile/2` never calls `Repo.*` itself -- it returns a **not-yet-executed**
  `Ecto.Query.t()`; the caller executes it (e.g. `Repo.all(query, prefix:
  prefix)`), matching every other tenant-scoped query in this subsystem.
  """

  import Ecto.Query

  alias Letflow.Entities.Definition
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Latest

  @type compile_error ::
          {:error, :invalid_schema_name}
          | {:error, :entity_type_not_found}
          | {:error, {:unknown_operator, String.t()}}
          | {:error, {:unknown_sort_dir, String.t()}}
          | {:error, {:field_not_allowed, String.t()}}
          | {:error, {:value_arity_mismatch, Types.filter_op()}}
          | {:error, {:invalid_in_value, String.t()}}
          | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}

  @doc """
  Compiles `request` (already allowlisted per its `entity_type`) into a
  parameterised `Ecto.Query.t()` against `Letflow.Entities.Record.Latest`,
  scoped to the tenant schema named by `prefix` (design §5.1). Step order
  -- the three-layer defence in its actual call sequence, each step's
  failure short-circuiting the rest:

    1. `Allowlist.load/2`.
    2. For each filter clause: value-arity check, field resolution
       (AC2), operator/field-type compatibility check, then
       `build_filter_dynamic/2`.
    3. Fold every clause's `dynamic/2` fragment into one AND-combined
       boolean expression.
    4. For each sort clause: field resolution, then `build_order_by/2`.
    5. Assemble the final query.

  Never calls any `Repo.*` function -- the returned query is unexecuted.
  """
  @spec compile(Types.query_request(), prefix :: String.t()) ::
          {:ok, Ecto.Query.t()} | compile_error()
  def compile(%{entity_type: entity_type} = request, prefix)
      when is_binary(entity_type) and is_binary(prefix) do
    filters = Map.get(request, :filters, [])
    sorts = Map.get(request, :sort, [])

    with {:ok, allowlist} <- Allowlist.load(entity_type, prefix),
         {:ok, filter_dynamics} <- build_all_filter_dynamics(filters, allowlist),
         {:ok, order_bys} <- build_all_order_bys(sorts, allowlist) do
      combined = combine_filters(filter_dynamics)

      query =
        Latest
        |> where([r], r.entity_type == ^entity_type)
        |> where([r], ^combined)
        |> apply_order_bys(order_bys)

      {:ok, query}
    end
  end

  # ---------------------------------------------------------------------------------
  # §4.2 -- value-arity / :in-value-shape checks (pure, no allowlist needed).
  # ---------------------------------------------------------------------------------

  @doc """
  Checks that `value_present?` matches what `op` requires (design §4.2):
  `:is_null`/`:is_not_null` require no value; every other operator requires
  exactly one.
  """
  @spec check_value_arity(Types.filter_op(), value_present? :: boolean()) ::
          :ok | {:error, {:value_arity_mismatch, Types.filter_op()}}
  def check_value_arity(op, value_present?) when op in [:is_null, :is_not_null] do
    if value_present?, do: {:error, {:value_arity_mismatch, op}}, else: :ok
  end

  def check_value_arity(op, value_present?) do
    if value_present?, do: :ok, else: {:error, {:value_arity_mismatch, op}}
  end

  # ---------------------------------------------------------------------------------
  # §4.3 -- operator/field-type compatibility (needs the resolved field's type).
  # ---------------------------------------------------------------------------------

  @doc """
  Checks that `op` is meaningful for `field_type` per
  `Letflow.Entities.Query.Types.valid_field_types_for/1`'s table (design
  §4.3, §2.1).
  """
  @spec check_operator_field_type(Types.filter_op(), Definition.field_type()) ::
          :ok
          | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}
  def check_operator_field_type(op, field_type) do
    case Types.valid_field_types_for(op) do
      nil ->
        :ok

      valid_types ->
        if field_type in valid_types do
          :ok
        else
          {:error, {:operator_not_valid_for_type, op, field_type}}
        end
    end
  end

  # ---------------------------------------------------------------------------------
  # §5.4 -- build_filter_dynamic/2: source x op x type dispatch, no fallback clause.
  # ---------------------------------------------------------------------------------

  @doc """
  Builds one `Ecto.Query.dynamic_expr()` for one already-resolved filter
  clause (design §5.4). Dispatches first on `allowlisted_field().source`,
  then on `{op, field_type}` -- every combination this design considered is
  enumerated explicitly; there is no catch-all clause that could silently
  assemble an unvetted shape for a combination this design did not think
  through.
  """
  @spec build_filter_dynamic(Types.filter_clause(), Allowlist.allowlisted_field()) ::
          {:ok, Ecto.Query.dynamic_expr()}
          | {:error, {:value_arity_mismatch, Types.filter_op()}}
          | {:error, {:invalid_in_value, String.t()}}
          | {:error, {:operator_not_valid_for_type, Types.filter_op(), Definition.field_type()}}
  def build_filter_dynamic(%{field: field_name, op: op} = clause, %{source: :typed_column}) do
    value = Map.get(clause, :value)
    {column_atom, _type} = Map.fetch!(Allowlist.typed_columns(), field_name)

    with :ok <- check_in_value_shape(op, value, field_name) do
      {:ok, typed_column_dynamic(op, column_atom, value)}
    end
  end

  def build_filter_dynamic(%{op: op} = clause, %{source: :json_field, type: type} = af) do
    value = Map.get(clause, :value)
    field_name = af.name

    with :ok <- check_in_value_shape(op, value, field_name) do
      {:ok, json_field_dynamic(op, type, field_name, value)}
    end
  end

  defp check_in_value_shape(op, value, field_name) when op in [:in, :not_in] do
    if is_list(value) do
      :ok
    else
      {:error, {:invalid_in_value, field_name}}
    end
  end

  defp check_in_value_shape(_op, _value, _field_name), do: :ok

  # -- typed-column dynamics (design §5.3) -- `field(r, ^column_atom)`,
  # `column_atom` sourced only from `Allowlist.typed_columns/0`'s own fixed,
  # closed table -- never `String.to_atom/1` on caller input.

  defp typed_column_dynamic(:eq, col, value), do: dynamic([r], field(r, ^col) == ^value)
  defp typed_column_dynamic(:neq, col, value), do: dynamic([r], field(r, ^col) != ^value)
  defp typed_column_dynamic(:gt, col, value), do: dynamic([r], field(r, ^col) > ^value)
  defp typed_column_dynamic(:gte, col, value), do: dynamic([r], field(r, ^col) >= ^value)
  defp typed_column_dynamic(:lt, col, value), do: dynamic([r], field(r, ^col) < ^value)
  defp typed_column_dynamic(:lte, col, value), do: dynamic([r], field(r, ^col) <= ^value)
  defp typed_column_dynamic(:in, col, value), do: dynamic([r], field(r, ^col) in ^value)
  defp typed_column_dynamic(:not_in, col, value), do: dynamic([r], field(r, ^col) not in ^value)

  defp typed_column_dynamic(:contains, col, value) do
    pattern = "%" <> value <> "%"
    dynamic([r], ilike(field(r, ^col), ^pattern))
  end

  defp typed_column_dynamic(:starts_with, col, value) do
    pattern = value <> "%"
    dynamic([r], ilike(field(r, ^col), ^pattern))
  end

  defp typed_column_dynamic(:is_null, col, _value), do: dynamic([r], is_nil(field(r, ^col)))

  defp typed_column_dynamic(:is_not_null, col, _value),
    do: dynamic([r], not is_nil(field(r, ^col)))

  # -- JSONB-field dynamics (design §5.2) -- one compile-time-fixed
  # fragment literal per field_type(), selected by pattern match, never
  # assembled at runtime. `r.field_values` and `^field_name` are the two
  # `fragment/1` placeholders; `^value` (or `^values` for :in/:not_in) is a
  # further, separate bound parameter appended after the cast.

  @string_fragment "?->>?"
  @integer_fragment "(?->>?)::bigint"
  @decimal_fragment "(?->>?)::numeric"
  @boolean_fragment "(?->>?)::boolean"
  @date_fragment "(?->>?)::date"
  @datetime_fragment "(?->>?)::timestamp"

  # Each clause below has its own distinct, compile-time-literal first
  # `fragment/1` argument (a `@module_attribute`, never a variable holding
  # one) -- the technique this module's moduledoc states.
  defp json_cast_dynamic(:string, field_name),
    do: dynamic([r], fragment(@string_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:enum, field_name),
    do: dynamic([r], fragment(@string_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:integer, field_name),
    do: dynamic([r], fragment(@integer_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:decimal, field_name),
    do: dynamic([r], fragment(@decimal_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:boolean, field_name),
    do: dynamic([r], fragment(@boolean_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:date, field_name),
    do: dynamic([r], fragment(@date_fragment, r.field_values, ^field_name))

  defp json_cast_dynamic(:datetime, field_name),
    do: dynamic([r], fragment(@datetime_fragment, r.field_values, ^field_name))

  defp json_field_dynamic(:eq, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast == ^value)
  end

  defp json_field_dynamic(:neq, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast != ^value)
  end

  defp json_field_dynamic(:gt, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast > ^value)
  end

  defp json_field_dynamic(:gte, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast >= ^value)
  end

  defp json_field_dynamic(:lt, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast < ^value)
  end

  defp json_field_dynamic(:lte, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast <= ^value)
  end

  defp json_field_dynamic(:in, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast in ^value)
  end

  defp json_field_dynamic(:not_in, type, field_name, value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], ^cast not in ^value)
  end

  defp json_field_dynamic(:contains, _type, field_name, value) do
    cast = json_cast_dynamic(:string, field_name)
    pattern = "%" <> value <> "%"
    dynamic([r], ilike(^cast, ^pattern))
  end

  defp json_field_dynamic(:starts_with, _type, field_name, value) do
    cast = json_cast_dynamic(:string, field_name)
    pattern = value <> "%"
    dynamic([r], ilike(^cast, ^pattern))
  end

  defp json_field_dynamic(:is_null, type, field_name, _value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], is_nil(^cast))
  end

  defp json_field_dynamic(:is_not_null, type, field_name, _value) do
    cast = json_cast_dynamic(type, field_name)
    dynamic([r], not is_nil(^cast))
  end

  # ---------------------------------------------------------------------------------
  # §5.5 -- build_order_by/2.
  # ---------------------------------------------------------------------------------

  @doc """
  Builds one `{sort_dir(), Ecto.Query.dynamic_expr()}` order-by term for one
  already-resolved sort clause (design §5.5). For `:typed_column`, simply
  references the resolved column. For `:json_field`, reuses §5.2's
  per-`field_type()` cast fragments verbatim -- a sort needs the same type
  cast a comparison does, so a numeric field sorts numerically rather than
  lexicographically as text.
  """
  @spec build_order_by(Types.sort_clause(), Allowlist.allowlisted_field()) ::
          {Types.sort_dir(), Ecto.Query.dynamic_expr()}
  def build_order_by(%{dir: dir}, %{source: :typed_column, name: field_name}) do
    {column_atom, _type} = Map.fetch!(Allowlist.typed_columns(), field_name)
    {dir, dynamic([r], field(r, ^column_atom))}
  end

  def build_order_by(%{dir: dir}, %{source: :json_field, type: type, name: field_name}) do
    {dir, json_cast_dynamic(type, field_name)}
  end

  # ---------------------------------------------------------------------------------
  # Private: per-clause pipeline + fold/assemble (design §5.1 steps 2-5).
  # ---------------------------------------------------------------------------------

  defp build_all_filter_dynamics(filters, allowlist) do
    Enum.reduce_while(filters, {:ok, []}, fn clause, {:ok, acc} ->
      case build_one_filter_dynamic(clause, allowlist) do
        {:ok, dyn} -> {:cont, {:ok, [dyn | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, dyns} -> {:ok, Enum.reverse(dyns)}
      {:error, _reason} = error -> error
    end
  end

  defp build_one_filter_dynamic(%{field: field_name, op: op} = clause, allowlist) do
    value_present? = Map.has_key?(clause, :value)

    with :ok <- check_value_arity(op, value_present?),
         {:ok, allowlisted_field} <- Allowlist.resolve_field(allowlist, field_name),
         :ok <- check_operator_field_type(op, allowlisted_field.type) do
      build_filter_dynamic(clause, allowlisted_field)
    end
  end

  defp build_all_order_bys(sorts, allowlist) do
    Enum.reduce_while(sorts, {:ok, []}, fn clause, {:ok, acc} ->
      case Allowlist.resolve_field(allowlist, clause.field) do
        {:ok, allowlisted_field} ->
          {:cont, {:ok, [build_order_by(clause, allowlisted_field) | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end

  # Design §5.1 step 3: starting from a `true` identity value, fold every
  # clause's dynamic left-to-right, ANDing each successive fragment onto the
  # accumulator -- implicit AND across all filter clauses.
  defp combine_filters(dynamics) do
    Enum.reduce(dynamics, dynamic(true), fn clause_dynamic, acc ->
      dynamic(^acc and ^clause_dynamic)
    end)
  end

  defp apply_order_bys(query, []), do: query

  defp apply_order_bys(query, order_bys) do
    order_by(query, [r], ^Enum.map(order_bys, fn {dir, dyn} -> {dir, dyn} end))
  end
end
