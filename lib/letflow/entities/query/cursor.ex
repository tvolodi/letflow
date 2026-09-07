defmodule Letflow.Entities.Query.Cursor do
  @moduledoc """
  `cursor.zig`-equivalent (REQ-231 §2) -- a keyset-pagination cursor codec
  for entity query results, generalizing `Letflow.Entities.Definitions`'
  `list_definitions/2` fixed two-column (`inserted_at desc, id desc`)
  cursor shape to an arbitrary, caller-chosen `sort` clause list produced by
  `Letflow.Entities.Query.Compiler.compile/2`. See
  `lib/letflow/design/req231-entity-query-cursor-field-grants.md` §2 for the
  full design this module implements.

  Reuses `Letflow.Api.Pagination`'s outer envelope verbatim --
  `encode_cursor/1`, `decode_cursor/4`'s prefix+expiry check, `Cursor.t()`'s
  single-`inner`-field opacity guarantee (INV-1/INV-5), and
  `Page.t()`/`page_response/2` -- only the *domain-payload* format inside
  `Cursor.inner`'s tail is new (design §2.1). Nothing about REQ-067's
  security contract changes here.

  `cursor_prefix/0` returns the fixed literal `"EQ:"` (Entity Query), a
  sibling of `list_definitions/2`'s `"ED:"`, distinct so a cursor minted by
  one listing can never decode successfully against the other (design
  §2.2).

  ## Owns both the codec and the query-composition step (design §2.4)

  This module owns both the cursor codec (encode/decode the resume key) and
  the query-composition step that consumes `Compiler.compile/2`'s output --
  mirroring `list_definitions/2`'s own undivided responsibility. It never
  changes `Letflow.Entities.Query.Types`, `Allowlist`, or `Compiler`
  (REQ-230, already reviewed and merged) -- it only consumes their existing,
  unchanged output types.

  ## Why field name/type never travel inside the cursor (design §2.3)

  The decoded resume values are positionally re-paired against the
  *caller's own resent* `sort` list on the next request -- position `i` in
  the decoded resume-key array always corresponds to position `i` in that
  request's `sort`. A caller who submits a different `sort` order/length
  than the one that minted the cursor produces
  `{:error, :resume_key_arity_mismatch}` rather than a silently wrong resume
  point.

  ## The `id` tiebreaker (design §2.3)

  `entity_record_latest.id` (the table's binary UUID primary key) is
  appended as an implicit final ascending sort key to every compiled query
  this module executes, in addition to whatever `sort` the caller
  specified -- this is `Cursor`'s own addition on top of
  `Compiler.compile/2`'s returned query, not a change to
  `Compiler`/`Allowlist`.
  """

  import Ecto.Query

  alias Letflow.Api.Pagination
  alias Letflow.Entities.Query.Allowlist
  alias Letflow.Entities.Query.Types
  alias Letflow.Entities.Record.Latest
  alias Letflow.Repo

  @cursor_prefix "EQ:"

  @doc "The fixed cursor prefix literal for this endpoint, `\"EQ:\"` (design §2.2)."
  @spec cursor_prefix() :: String.t()
  def cursor_prefix, do: @cursor_prefix

  @typedoc """
  The decoded, positionally-ordered list of `length(sort) + 1` JSON-native
  values described in design §2.2 -- still in raw decoded form (no
  type-casting against `Allowlist` field types performed yet).
  """
  @type resume_key :: [term()]

  @typedoc "`paginate/5`'s `opts` shape (design §2.4)."
  @type paginate_opts :: %{
          optional(:cursor) => String.t() | nil,
          optional(:page_size) => pos_integer() | nil
        }

  @typedoc "One resolved sort clause -- the field's allowlist entry plus its dynamic reference."
  @type resolved_sort_term :: %{
          name: String.t(),
          dir: Types.sort_dir(),
          source: Allowlist.field_source(),
          type: term(),
          dyn: Ecto.Query.dynamic_expr()
        }

  @doc """
  Paginates `compiled_query` (already produced by
  `Letflow.Entities.Query.Compiler.compile/2` for `request`) using a keyset
  cursor generalized to `request`'s own `sort` clause list (design §2.4).

  Step order, mirroring `list_definitions/2`'s own `with` chain:

    1. `Pagination.validate_page_size/1` on `opts.page_size`.
    2. Decode `opts.cursor` via `Pagination.decode_cursor/4` with this
       module's own `cursor_prefix/0`, then JSON-parse the tail into a
       `resume_key()`.
    3. Re-resolve every `sort_clause().field` against `allowlist` to learn
       each field's `type()`/`source()` for the typed resume-filter
       comparison.
    4. If a decoded `resume_key()` is present, check its length equals
       `length(sort) + 1` -- `{:error, :resume_key_arity_mismatch}`
       otherwise.
    5. Build the row-wise resume filter and add it to `compiled_query`, add
       the implicit `id` ascending tiebreak order, add `limit(page_size + 1)`.
    6. `Repo.all(query, prefix: prefix)`, split off the possible extra row,
       and -- if a next page exists -- mint the next cursor.
  """
  @spec paginate(
          request :: Types.query_request(),
          compiled_query :: Ecto.Query.t(),
          allowlist :: Allowlist.allowlist(),
          opts :: paginate_opts(),
          prefix :: String.t()
        ) ::
          {:ok, Pagination.Page.t(Latest.t())}
          | {:error, :page_size_too_large}
          | {:error, :invalid_cursor}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :resume_key_arity_mismatch}
          | {:error, {:field_not_allowed, String.t()}}
  def paginate(request, %Ecto.Query{} = compiled_query, allowlist, opts, prefix)
      when is_map(request) and is_map(allowlist) and is_map(opts) and is_binary(prefix) do
    sort = Map.get(request, :sort, [])

    with {:ok, page_size} <- Pagination.validate_page_size(Map.get(opts, :page_size)),
         {:ok, raw_resume_key} <- decode_resume_key(Map.get(opts, :cursor)),
         {:ok, resolved_sort} <- resolve_sort(sort, allowlist),
         {:ok, resume_terms} <- build_resume_terms(raw_resume_key, resolved_sort) do
      rows =
        compiled_query
        |> apply_resume_filter(resume_terms)
        |> order_by([r], asc: r.id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page_rows, extra?} = split_page(rows, page_size)

      next_cursor =
        if extra? do
          build_next_cursor(List.last(page_rows), resolved_sort)
        else
          nil
        end

      {:ok, Pagination.page_response(page_rows, next_cursor)}
    end
  end

  # ── Step 2 -- decode the opaque cursor into a raw resume_key() (design §2.2) ──

  @spec decode_resume_key(String.t() | nil) ::
          {:ok, resume_key() | nil}
          | {:error, :invalid_cursor}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
  defp decode_resume_key(nil), do: {:ok, nil}

  defp decode_resume_key(raw) when is_binary(raw) do
    case Pagination.decode_cursor(raw, @cursor_prefix, byte_size(@cursor_prefix)) do
      {:ok, %Pagination.Cursor{inner: inner}} -> parse_resume_key_json(inner)
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"EQ:<mint_time_us>:<resume_key_json>"` -- the first slot
  # after the prefix is always the mint-time timestamp `decode_cursor/4`'s
  # own expiry check already read, never a domain value (same idiom
  # `list_definitions/2`'s cursor helpers use). The JSON tail may itself
  # legitimately contain colons (e.g. an ISO-8601 datetime string), so this
  # splits on the FIRST colon only.
  defp parse_resume_key_json(inner) do
    prefix_len = byte_size(@cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)

    case String.split(rest, ":", parts: 2) do
      [_mint_time_us_str, resume_key_json] ->
        case Jason.decode(resume_key_json) do
          {:ok, list} when is_list(list) -> {:ok, list}
          _ -> {:error, :invalid_cursor}
        end

      _ ->
        {:error, :invalid_cursor}
    end
  end

  # ── Step 3 -- resolve every sort clause against the allowlist ──────────────

  @spec resolve_sort([Types.sort_clause()], Allowlist.allowlist()) ::
          {:ok, [resolved_sort_term()]} | {:error, {:field_not_allowed, String.t()}}
  defp resolve_sort(sort, allowlist) do
    Enum.reduce_while(sort, {:ok, []}, fn clause, {:ok, acc} ->
      case Allowlist.resolve_field(allowlist, clause.field) do
        {:ok, field} -> {:cont, {:ok, [resolved_sort_term(clause, field) | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end

  defp resolved_sort_term(%{dir: dir}, %{source: :typed_column, name: name} = field) do
    {column_atom, _type} = Map.fetch!(Allowlist.typed_columns(), name)

    %{
      name: name,
      dir: dir,
      source: :typed_column,
      type: field.type,
      ecto_type: Latest.__schema__(:type, column_atom),
      dyn: dynamic([r], field(r, ^column_atom))
    }
  end

  defp resolved_sort_term(%{dir: dir}, %{source: :json_field, name: name, type: type}) do
    %{
      name: name,
      dir: dir,
      source: :json_field,
      type: type,
      ecto_type: nil,
      dyn: json_cast_dynamic(type, name)
    }
  end

  # ── Step 4 -- arity check + typed-value casting of the decoded resume key ──

  @spec build_resume_terms(resume_key() | nil, [resolved_sort_term()]) ::
          {:ok, [map()] | nil}
          | {:error, :resume_key_arity_mismatch}
          | {:error, :invalid_cursor}
  defp build_resume_terms(nil, _resolved_sort), do: {:ok, nil}

  defp build_resume_terms(raw_resume_key, resolved_sort) when is_list(raw_resume_key) do
    if length(raw_resume_key) != length(resolved_sort) + 1 do
      {:error, :resume_key_arity_mismatch}
    else
      {sort_values, [id_value]} = Enum.split(raw_resume_key, length(resolved_sort))

      with {:ok, casted_values} <- cast_all(resolved_sort, sort_values),
           {:ok, id_str} <- decode_component(:string, id_value) do
        sort_terms =
          resolved_sort
          |> Enum.zip(casted_values)
          |> Enum.map(fn {term, value} -> Map.put(term, :value, value) end)

        id_term = %{dir: :asc, value: id_str, ecto_type: :binary_id, dyn: dynamic([r], r.id)}

        {:ok, sort_terms ++ [id_term]}
      else
        :error -> {:error, :invalid_cursor}
      end
    end
  end

  defp cast_all(resolved_sort, raw_values) do
    resolved_sort
    |> Enum.zip(raw_values)
    |> Enum.reduce_while({:ok, []}, fn {term, raw_value}, {:ok, acc} ->
      case decode_component(term.type, raw_value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  # Casts one JSON-decoded resume-key component back into the Elixir term
  # its `Allowlist.allowlisted_field().type` expects for query comparison
  # (design §2.4's "type-casting... happens when the resume filter is
  # built" note) -- the same per-`field_type()` dispatch idea
  # `Compiler.build_filter_dynamic/2` already uses for JSON-field
  # comparisons, reimplemented here rather than reused directly since those
  # functions are private to `Compiler` (which this design does not touch).
  defp decode_component(:integer, v) when is_integer(v), do: {:ok, v}
  defp decode_component(:integer, v) when is_float(v), do: {:ok, trunc(v)}

  defp decode_component(:decimal, v) when is_binary(v) or is_number(v) do
    {:ok, Decimal.new(to_string(v))}
  end

  defp decode_component(:date, v) when is_binary(v) do
    case Date.from_iso8601(v) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp decode_component(:datetime, v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp decode_component(_type, v) when is_binary(v) or is_boolean(v), do: {:ok, v}
  defp decode_component(_type, _v), do: :error

  # ── Step 5 -- resume-filter composition (design §2.3) ──────────────────────

  defp apply_resume_filter(query, nil), do: query

  defp apply_resume_filter(query, resume_terms) do
    where(query, [r], ^build_row_dynamic(resume_terms))
  end

  # Row-wise (lexicographic) keyset comparison, composed left-to-right via
  # nested `dynamic/2` rather than a literal Postgres row-tuple, since
  # Ecto's fragment syntax cannot itself parameterize over a
  # runtime-variable tuple arity (design §2.3):
  #
  #   (f1 </> v1) OR (f1 == v1 AND ((f2 </> v2) OR (f2 == v2 AND (...))))
  #
  # built here by folding the term list from the last (least significant)
  # term back to the first (most significant).
  defp build_row_dynamic(resume_terms) do
    resume_terms
    |> Enum.reverse()
    |> Enum.reduce(nil, fn term, acc ->
      cmp = field_cmp(term.dyn, term.dir, term.value, term.ecto_type)

      case acc do
        nil -> cmp
        _ -> dynamic(^cmp or (^field_eq(term.dyn, term.value, term.ecto_type) and ^acc))
      end
    end)
  end

  # `ecto_type` is `nil` for `:json_field` sort terms (the fragment cast
  # already gives Postgres a native-typed comparison side) and the actual
  # schema `Ecto.Type` for `:typed_column`/`id` terms. `term.dyn` is a
  # field-reference built at runtime and composed into this dynamic via `^`
  # interpolation rather than written inline, so Ecto's own compile-time
  # dump-on-cast step (the one that would normally turn a UUID string into
  # the raw 16-byte binary Postgrex requires for a `:binary_id`/`Ecto.UUID`
  # column) never runs for `^value` here -- confirmed empirically: the `id`
  # tiebreak comparison reached Postgrex as an un-dumped string without
  # this. `maybe_dump/2` performs that dump explicitly wherever it matters.
  defp field_eq(dyn, value, ecto_type), do: dynamic(^dyn == ^maybe_dump(ecto_type, value))
  defp field_cmp(dyn, :desc, value, ecto_type), do: dynamic(^dyn < ^maybe_dump(ecto_type, value))
  defp field_cmp(dyn, :asc, value, ecto_type), do: dynamic(^dyn > ^maybe_dump(ecto_type, value))

  defp maybe_dump(nil, value), do: value
  defp maybe_dump(:binary_id, value), do: Ecto.UUID.dump!(value)
  defp maybe_dump(Ecto.UUID, value), do: Ecto.UUID.dump!(value)
  defp maybe_dump(_ecto_type, value), do: value

  # ── Step 6 -- page split + next-cursor minting ──────────────────────────────

  defp split_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, true}
  end

  defp split_page(rows, _page_size), do: {rows, false}

  defp build_next_cursor(%Latest{id: id} = row, resolved_sort) do
    mint_time_us = System.system_time(:microsecond)

    resume_values =
      Enum.map(resolved_sort, fn term ->
        term
        |> read_sort_value(row)
        |> encode_component(term.type)
      end)

    resume_key_json = Jason.encode!(resume_values ++ [id])

    @cursor_prefix
    |> Pagination.build_raw_cursor(mint_time_us, resume_key_json)
    |> Pagination.encode_cursor()
  end

  defp read_sort_value(%{source: :typed_column, name: name}, row) do
    {column_atom, _type} = Map.fetch!(Allowlist.typed_columns(), name)
    Map.fetch!(row, column_atom)
  end

  defp read_sort_value(%{source: :json_field, name: name}, %Latest{field_values: field_values}) do
    Map.fetch!(field_values, name)
  end

  defp encode_component(%DateTime{} = v, _type), do: DateTime.to_iso8601(v)
  defp encode_component(%Date{} = v, _type), do: Date.to_iso8601(v)
  defp encode_component(%Decimal{} = v, _type), do: Decimal.to_string(v)
  defp encode_component(v, _type), do: v

  # ── JSONB per-type cast fragments (design §2.3, mirroring Compiler §5.2) ──
  # Duplicated here rather than exposed from `Compiler` (which this design
  # does not touch) -- each clause has its own distinct, compile-time-literal
  # first `fragment/1` argument, never assembled at runtime.

  @string_fragment "?->>?"
  @integer_fragment "(?->>?)::bigint"
  @decimal_fragment "(?->>?)::numeric"
  @boolean_fragment "(?->>?)::boolean"
  @date_fragment "(?->>?)::date"
  @datetime_fragment "(?->>?)::timestamp"

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
end
