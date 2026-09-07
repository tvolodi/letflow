defmodule Letflow.Entities.Query.Types do
  @moduledoc """
  `types.zig`-equivalent (REQ-230 §2) -- the closed `filter_op()`/`sort_dir()`
  enums, the `query_request()` request shape, and `parse_filter_op/1`/
  `parse_sort_dir/1`, the **only** functions in this subsystem that ever see
  a caller-supplied raw operator/direction string. See
  `lib/letflow/design/req230-entity-query-dsl-compiler.md` §2/§4.1 for the
  full design this module implements.

  This is layer 1 of the three-layer SQL-injection defence named in
  REQ-230's own text (closed operator enum -> allowlist-only column
  resolution -> positional-parameter binding): no operator string ever
  reaches `Letflow.Entities.Query.Allowlist` or `Letflow.Entities.Query.Compiler`
  without first passing through `parse_filter_op/1`/`parse_sort_dir/1` and
  coming back `{:ok, _}`. Pure/stateless -- no `prefix`, no DB access,
  mirroring `Letflow.Engine.Expr.cmp_op()`'s own closed-union-of-atoms idiom
  for a comparison operator (design §0).
  """

  alias Letflow.Entities.Definition

  @typedoc """
  The closed set of filter operators (design §2.1). Never a free-form
  `String.t()` past `parse_filter_op/1` -- every later function in this
  subsystem accepts only this type, enforced by `@spec`.
  """
  @type filter_op ::
          :eq
          | :neq
          | :gt
          | :gte
          | :lt
          | :lte
          | :in
          | :not_in
          | :contains
          | :starts_with
          | :is_null
          | :is_not_null

  @typedoc "The closed set of sort directions (design §2.1)."
  @type sort_dir :: :asc | :desc

  @typedoc "One filter clause in a `query_request()` (design §2.2)."
  @type filter_clause :: %{
          required(:field) => String.t(),
          required(:op) => filter_op(),
          optional(:value) => term()
        }

  @typedoc "One sort clause in a `query_request()` (design §2.2)."
  @type sort_clause :: %{
          required(:field) => String.t(),
          required(:dir) => sort_dir()
        }

  @typedoc """
  The full query request shape (design §2.2). `filters`/`sort` both default
  to `[]` when absent -- an entity-type query with neither is still routed
  through the allowlist/compiler, so there is exactly one code path.
  """
  @type query_request :: %{
          required(:entity_type) => String.t(),
          optional(:filters) => [filter_clause()],
          optional(:sort) => [sort_clause()]
        }

  @filter_ops ~w(eq neq gt gte lt lte in not_in contains starts_with is_null is_not_null)a

  @sort_dirs ~w(asc desc)a

  @doc """
  Parses a caller-supplied raw operator string into a closed `filter_op()`
  atom (design §4.1, AC1). This is the entire first defence layer: an
  operator outside `filter_op()`'s closed set is rejected here, with
  `{:unknown_operator, raw}` naming the caller's own unrecognised string --
  never a generic "invalid request" error.
  """
  @spec parse_filter_op(raw :: String.t()) ::
          {:ok, filter_op()} | {:error, {:unknown_operator, String.t()}}
  def parse_filter_op(raw) when is_binary(raw) do
    case raw do
      "eq" -> {:ok, :eq}
      "neq" -> {:ok, :neq}
      "gt" -> {:ok, :gt}
      "gte" -> {:ok, :gte}
      "lt" -> {:ok, :lt}
      "lte" -> {:ok, :lte}
      "in" -> {:ok, :in}
      "not_in" -> {:ok, :not_in}
      "contains" -> {:ok, :contains}
      "starts_with" -> {:ok, :starts_with}
      "is_null" -> {:ok, :is_null}
      "is_not_null" -> {:ok, :is_not_null}
      _ -> {:error, {:unknown_operator, raw}}
    end
  end

  @doc """
  Parses a caller-supplied raw sort-direction string into a closed
  `sort_dir()` atom (design §4.1). Same closed-enum discipline as
  `parse_filter_op/1`.
  """
  @spec parse_sort_dir(raw :: String.t()) ::
          {:ok, sort_dir()} | {:error, {:unknown_sort_dir, String.t()}}
  def parse_sort_dir(raw) when is_binary(raw) do
    case raw do
      "asc" -> {:ok, :asc}
      "desc" -> {:ok, :desc}
      _ -> {:error, {:unknown_sort_dir, raw}}
    end
  end

  @doc "The closed `filter_op()` set, as atoms (design §2.1)."
  @spec filter_ops() :: [filter_op()]
  def filter_ops, do: @filter_ops

  @doc "The closed `sort_dir()` set, as atoms (design §2.1)."
  @spec sort_dirs() :: [sort_dir()]
  def sort_dirs, do: @sort_dirs

  @doc """
  Which `field_type()`s a given `filter_op()` is meaningful for (design
  §2.1's table) -- `nil` means "all types". Used by
  `Letflow.Entities.Query.Compiler.check_operator_field_type/2` (design
  §4.3).
  """
  @spec valid_field_types_for(filter_op()) :: [Definition.field_type()] | nil
  def valid_field_types_for(op) when op in [:eq, :neq], do: nil

  def valid_field_types_for(op) when op in [:gt, :gte, :lt, :lte],
    do: [:integer, :decimal, :date, :datetime]

  def valid_field_types_for(op) when op in [:in, :not_in],
    do: [:string, :integer, :decimal, :enum]

  def valid_field_types_for(op) when op in [:contains, :starts_with], do: [:string]
  def valid_field_types_for(op) when op in [:is_null, :is_not_null], do: nil
end
