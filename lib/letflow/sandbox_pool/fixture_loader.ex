defmodule Letflow.SandboxPool.FixtureLoader do
  @moduledoc """
  Loads a fixed list of fixture rows into a claimed sandbox schema's allowlisted tables,
  TRUNCATE-ing each distinct target table first (ports R-Co's
  `src/definition/fixture_loader.zig` per PRM-06 §3 — see
  `src/design/prm-batch1-promotion-assertion-rerun.md`).

  The allowlist is the SQL-injection boundary: a fixture's `table_name` is checked
  against a hardcoded list (`process_definitions`, `instance_definition_snapshots`)
  before any SQL is issued for it — see `lib/letflow/design/
  req039-sandbox-pool-fixture-loader.md` §5.2 for why this list diverges from R-Co's own
  (two of R-Co's three allowlisted tables have no Letflow equivalent yet), and §11 OQ-1
  for how a future requirement extends it. `sandbox_schema` is independently validated
  against the exact shape `Letflow.SandboxPool.claim/1` always produces before any
  interpolation, closing the same injection class on the schema-name dimension (design
  doc §5.5 INV-FL-1) — this hardening goes beyond what R-Co's own source validates, since
  R-Co's caller-trust assumption does not carry over to this module's differently-shaped
  Elixir call graph.
  """

  alias Letflow.Repo

  defmodule FixtureRow do
    @moduledoc """
    One fixture row to load: its target table name and raw JSON row content.
    `row_json` is bound as a `$1::jsonb` parameter — never decoded into an Elixir map
    by this module and never string-interpolated into SQL (design doc §5.1).
    """

    @enforce_keys [:table_name, :row_json]
    defstruct [:table_name, :row_json]

    @type t :: %__MODULE__{table_name: String.t(), row_json: String.t()}
  end

  # The SQL-injection boundary (INV-FL-2): no table name reaches a TRUNCATE or
  # INSERT statement unless it appears verbatim here. Extend only when a
  # concrete future consumer needs another table (design doc §5.2, §11 OQ-1) --
  # not speculatively.
  @allowlist ["process_definitions", "instance_definition_snapshots"]

  # The exact shape Letflow.SandboxPool's provisioning sequence always
  # produces ("sandbox_" <> a 32-hex-digit UUID with hyphens stripped) --
  # INV-FL-1, added beyond R-Co's own source because this function has no
  # caller-trust guarantee enforced by the type system (security-invariants.md
  # INV-7).
  @schema_name_pattern ~r/^sandbox_[0-9a-f]{32}$/

  @doc """
  Loads `fixtures` into `sandbox_schema`, TRUNCATE-ing each distinct target table
  immediately before (re-)inserting its rows, all inside one transaction. An empty
  `fixtures` list is a no-op that issues no SQL at all. `opts` is currently unused (a
  forward-compatible extension point).
  """
  @spec load_fixtures_only(
          sandbox_schema :: String.t(),
          fixtures :: [FixtureRow.t()],
          opts :: keyword()
        ) ::
          :ok
          | {:error, :invalid_table_name}
          | {:error, :invalid_schema_name}
          | {:error, :insert_failed}
          | {:error, term()}
  def load_fixtures_only(sandbox_schema, fixtures, opts \\ [])

  def load_fixtures_only(_sandbox_schema, [], _opts), do: :ok

  def load_fixtures_only(sandbox_schema, fixtures, _opts) do
    table_names = distinct_table_names(fixtures)

    with :ok <- validate_schema_name(sandbox_schema),
         :ok <- validate_table_names(table_names) do
      apply_fixtures(sandbox_schema, table_names, fixtures)
    end
  end

  defp validate_schema_name(sandbox_schema) do
    if Regex.match?(@schema_name_pattern, sandbox_schema) do
      :ok
    else
      {:error, :invalid_schema_name}
    end
  end

  # First-seen order preserved, matching fixture_loader.zig:71-85.
  defp distinct_table_names(fixtures) do
    fixtures
    |> Enum.map(& &1.table_name)
    |> Enum.uniq()
  end

  # A full validation pass over every distinct table completes before any
  # mutating statement is issued for any of them (INV-FL-2) -- the first
  # non-allowlisted name found short-circuits the whole load.
  defp validate_table_names(table_names) do
    if Enum.all?(table_names, &(&1 in @allowlist)) do
      :ok
    else
      {:error, :invalid_table_name}
    end
  end

  # Both identifiers interpolated below are already validated by this point:
  # sandbox_schema passed validate_schema_name/1's fixed-shape check, every
  # table_name passed validate_table_names/1's allowlist check -- neither is
  # raw, unvalidated caller input at the point of interpolation (INV-7).
  # row_json is always bound as $1, never interpolated (INV-FL-3).
  #
  # Wrapped in the whole call's own try/rescue, not a {:error, _} match on
  # Repo.transaction/1's return: a Repo.query!/2 failure inside the
  # transaction function *raises*, which Repo.transaction/1 rolls back and
  # then re-raises to its caller (it does not convert the exception into an
  # {:error, _} return on its own) -- design doc §5.4 step 5c/§5.6.
  defp apply_fixtures(sandbox_schema, table_names, fixtures) do
    Repo.transaction(fn ->
      Enum.each(table_names, fn table_name ->
        Repo.query!(~s(TRUNCATE "#{sandbox_schema}"."#{table_name}" CASCADE))
      end)

      Enum.each(fixtures, fn %FixtureRow{table_name: table_name, row_json: row_json} ->
        # A plain double-quoted string, not ~s(...): this toolchain's sigil
        # parser does not treat raw parens inside a ~s(...) sigil's own
        # content as nestable (verified directly -- `~s(a(b)c)` alone fails
        # to parse with "unexpected token: )" here), so the literal
        # `jsonb_populate_record(...)` call below cannot be written inside a
        # ~s()-delimited sigil. table_name/sandbox_schema are interpolated
        # (not concatenated) here, identically safe to the TRUNCATE statement
        # above: both already passed validate_schema_name/1 and
        # validate_table_names/1 by this point (INV-7). row_json is always
        # bound as a parameter, never interpolated (INV-FL-3).
        #
        # `($1::text)::jsonb`, not the design doc's literal `$1::jsonb`
        # (verified empirically, not a stylistic choice): when a bound
        # parameter's immediately-annotated cast is `::jsonb`, Postgrex's
        # jsonb type extension infers the parameter is a native Elixir term
        # to be JSON-*encoded* client-side (via Jason) before sending -- since
        # row_json here is already-encoded JSON *text*, that produces double
        # encoding (the object becomes a JSON *string* literal wrapping the
        # original text), which Postgres then rejects from
        # jsonb_populate_record with "cannot call populate_composite on a
        # scalar". Casting to `::text` first makes Postgrex bind the
        # already-correct text verbatim; the `::jsonb` cast then happens
        # server-side in Postgres, which parses it correctly. row_json is
        # still bound as a parameter either way -- never interpolated.
        sql =
          "INSERT INTO \"#{sandbox_schema}\".\"#{table_name}\" SELECT * FROM " <>
            "jsonb_populate_record(NULL::\"#{sandbox_schema}\".\"#{table_name}\", ($1::text)::jsonb)"

        Repo.query!(sql, [row_json])
      end)
    end)

    :ok
  rescue
    _exception -> {:error, :insert_failed}
  end
end
