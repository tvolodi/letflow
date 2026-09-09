defmodule Letflow.Entities.Definition.DDL do
  @moduledoc """
  Generates the `CREATE TABLE` DDL text for one entity type's per-tenant
  table, as a pure function of `Letflow.Entities.Definition.t()` (REQ-296).
  See `lib/letflow/design/req296-entity-table-ddl-generator.md` for the full
  design this module implements.

  ## Pure function -- no I/O, no tenant/schema awareness

  This module never calls `Letflow.Repo`, never opens a database
  connection, and never knows which tenant or schema a table belongs to.
  It only turns a `Letflow.Entities.Definition.t()` (plus a caller-supplied
  `table_name`) into raw SQL text. Deciding the physical `table_name` from
  an `entity_type`, executing the returned SQL against a real schema, and
  wiring promoted columns into any write path are all REQ-297/298's job,
  not this module's (see `docs/migration/decisions/0023-entity-storage-hybrid.md`
  and `docs/migration/decisions/0024-entity-promotion-ddl-execution.md`).

  ## Precondition: the definition has already passed `Validator.validate/1`

  Callers must have already run `Letflow.Entities.Definition.Validator.validate/1`
  on `definition` and received `:ok` before calling `generate_table_ddl/2` --
  this module does not re-run structural validation (FK coverage, the
  `:json`/`queried` conflict, name-format checks). It leans on those
  already-enforced invariants. The one exception is `valid_identifier?/1`
  (see below), which this module checks itself anyway, as a defence-in-depth
  measure independent of the Validator's own name-format rule, because a
  SQL-injection-shaped defect is exactly the kind of failure that should not
  depend solely on an upstream precondition silently continuing to hold.

  ## Output form: raw SQL text, not an `Ecto.Migration` AST

  `generate_table_ddl/2` returns `{:ok, sql}` where `sql` is a complete
  `CREATE TABLE` statement as a `String.t()` -- not an `Ecto.Migration`
  macro call list. This matches REQ-295/297's own `ALTER TABLE ... ADD
  COLUMN` half of table DDL, which already executes raw SQL text directly
  (the same way `Letflow.TenantProvisioning.provision_tenant_schema/1`
  already executes `CREATE SCHEMA IF NOT EXISTS ...` directly rather than
  through the migrator) -- one representation used consistently across both
  halves of table DDL, not two.

  ## Extension point for REQ-301 (generated-column-per-locale)

  `promoted_columns/1`'s per-field dispatch (via `field_type_to_pg_type/1`
  and `promotion_trigger/2`) is a **closed case dispatch over
  `Definition.field_type()`**, not a single monolithic string-building
  block. REQ-301, when it adds a localized-text type (or a
  `localized: true` flag on `:string`, whichever REQ-301 itself decides),
  can extend this dispatch with one more case that emits N generated
  columns per configured locale instead of the current one-column-per-attribute
  shape -- without needing to touch `structural_columns/0` or the
  structural/promoted/blob split in `generate_table_ddl/2`. This module
  does **not** implement that case, add a locale configuration shape, or
  reserve a field name/flag for it -- only the dispatch shape that makes
  adding it additive.
  """

  alias Letflow.Entities.Definition

  @typedoc "One column in a generated `CREATE TABLE` statement."
  @type column_spec :: %{
          name: String.t(),
          pg_type: String.t(),
          nullable: boolean()
        }

  @typedoc "Failure reason for `generate_table_ddl/2` -- identifier-shape failures only."
  @type ddl_error :: {:invalid_identifier, field: :table_name | :attribute, value: String.t()}

  @identifier_format_regex ~r/^[a-z][a-z0-9_]{0,63}$/

  @doc """
  Generates the full `CREATE TABLE` DDL text for `definition`'s per-entity-type
  table, named `table_name`.

  `table_name` is supplied by the caller (REQ-297/provisioning's job to
  derive a physical table name from `entity_type`) -- this module does not
  invent a table-naming convention; it validates whatever name it is given
  and uses it verbatim in the emitted `CREATE TABLE "<table_name>" (...)`.

  Returns `{:error, ddl_error()}` only for a defence-in-depth identifier-shape
  failure (`table_name` or a promoted column name not matching the safe
  identifier format) -- never for a structurally-invalid `Definition.t()`,
  which is the Validator's job and is assumed already passed per the
  precondition stated in the moduledoc.
  """
  @spec generate_table_ddl(Definition.t(), table_name :: String.t()) ::
          {:ok, String.t()} | {:error, ddl_error()}
  def generate_table_ddl(definition, table_name) do
    promoted = promoted_columns(definition)
    columns = structural_columns() ++ promoted

    with :ok <- check_identifier(:table_name, table_name),
         :ok <- check_column_identifiers(columns) do
      enum_checks = enum_check_constraints(definition, promoted)
      {:ok, build_create_table_sql(table_name, columns, enum_checks)}
    end
  end

  @doc """
  The fixed, definition-independent list of structural columns every
  per-entity-type table carries. A constant-shaped function (no
  `Definition.t()` input) so REQ-297/provisioning can also introspect the
  structural set independently of generating full DDL (e.g. to confirm a
  promoted attribute name never collides with a structural column name).

  `entity_type` is deliberately absent here -- `entity_record_latest`
  (the shared table this per-type table splits apart) carries it because
  that table holds every entity type in a tenant's schema; a per-entity-type
  table is, by construction, all one type, so the column would be a
  redundant constant on every row.
  """
  @spec structural_columns() :: [column_spec()]
  def structural_columns do
    [
      %{name: "id", pg_type: "uuid", nullable: false},
      %{name: "record_id", pg_type: "uuid", nullable: false},
      %{name: "field_values", pg_type: "jsonb", nullable: false},
      %{name: "deleted", pg_type: "boolean", nullable: false},
      %{name: "entity_def_version", pg_type: "bytea", nullable: true},
      %{name: "last_event_global_seq", pg_type: "bigint", nullable: false},
      %{name: "inserted_at", pg_type: "timestamp(6) without time zone", nullable: false},
      %{name: "updated_at", pg_type: "timestamp(6) without time zone", nullable: false}
    ]
  end

  @doc """
  Applies the promotion rule to `definition.fields`, using
  `definition.foreign_keys` to determine trigger 1 (foreign key). Returns
  one `column_spec()` per promoted attribute, in `definition.fields`'s
  original order (stable, deterministic output).

  A field is filtered on `field_type_to_pg_type/1` returning `{:ok, _}`,
  not merely on `promotion_trigger/2`'s result -- this is the
  defence-in-depth that keeps a `:json`-typed field excluded even if it is
  somehow marked `queried: true` (Validator's Rule 3 bypassed, or relaxed
  by a future change) or somehow appears as an `fk_def().field`.
  """
  @spec promoted_columns(Definition.t()) :: [column_spec()]
  def promoted_columns(definition) do
    fk_field_names = MapSet.new(Map.get(definition, :foreign_keys, []), &Map.get(&1, :field))

    definition
    |> Map.get(:fields, [])
    |> Enum.filter(fn field -> promotion_trigger(field, fk_field_names) != :not_promoted end)
    |> Enum.flat_map(fn field ->
      case field_type_to_pg_type(field) do
        {:ok, pg_type} ->
          [%{name: Map.get(field, :name), pg_type: pg_type, nullable: true}]

        :never_promoted ->
          []
      end
    end)
  end

  @doc """
  The type-mapping table as a function. Takes the full `field_def()` (not
  just its `field_type()`) because `:decimal`'s Postgres type depends on
  the field's optional `decimal_precision`/`decimal_scale`, and `:enum`'s
  depends on its `enum_values`.

  Returns `:never_promoted` for `:json` -- the defence-in-depth measure
  described in `promoted_columns/1`'s doc. Never raises on any of the 8
  `field_type()` values.

  Exposed publicly so REQ-297's own `column_spec` construction for a single
  later promotion (its own, separate `ALTER TABLE ADD COLUMN`) reuses the
  same mapping rather than re-deriving it.
  """
  @spec field_type_to_pg_type(Definition.field_def()) :: {:ok, String.t()} | :never_promoted
  def field_type_to_pg_type(field) do
    case Map.get(field, :type) do
      :string -> {:ok, "text"}
      :integer -> {:ok, "bigint"}
      :decimal -> {:ok, decimal_pg_type(field)}
      :boolean -> {:ok, "boolean"}
      :date -> {:ok, "date"}
      :datetime -> {:ok, "timestamp(6) without time zone"}
      :enum -> {:ok, "text"}
      :json -> :never_promoted
    end
  end

  @doc """
  Determines which promotion trigger, if any, fires for `field`.

  - `:fk` -- `field`'s `:name` is a member of `fk_field_names` (every
    `fk_def().field` value from `definition.foreign_keys`), regardless of
    `field`'s `:queried` value.
  - `:queried` -- not `:fk`, and `field`'s `:queried` is `true`.
  - `:not_promoted` -- neither trigger fires.

  A bare decision function (no DDL concerns) so the promotion *rule* is
  independently testable from the DDL *text* it produces.
  """
  @spec promotion_trigger(Definition.field_def(), fk_field_names :: MapSet.t(String.t())) ::
          :fk | :queried | :not_promoted
  def promotion_trigger(field, fk_field_names) do
    cond do
      MapSet.member?(fk_field_names, Map.get(field, :name)) -> :fk
      Map.get(field, :queried) == true -> :queried
      true -> :not_promoted
    end
  end

  @doc """
  Whether `value` is a safe SQL identifier -- matches the same format
  `Letflow.Entities.Definition.Validator` already enforces on names
  (`~r/^[a-z][a-z0-9_]{0,63}$/`). This module does not import or call the
  Validator's private regex; it defines its own equivalent public check, so
  this module's safety property does not depend on the Validator's private
  implementation detail staying accessible or unchanged.
  """
  @spec valid_identifier?(String.t()) :: boolean()
  def valid_identifier?(value) when is_binary(value) do
    Regex.match?(@identifier_format_regex, value)
  end

  def valid_identifier?(_value), do: false

  # --- internal ---------------------------------------------------------------

  defp decimal_pg_type(field) do
    case {Map.get(field, :decimal_precision), Map.get(field, :decimal_scale)} do
      {precision, scale} when is_integer(precision) and is_integer(scale) ->
        "numeric(#{precision}, #{scale})"

      _other ->
        "numeric"
    end
  end

  defp check_identifier(_field, value) when is_binary(value) do
    if valid_identifier?(value) do
      :ok
    else
      {:error, {:invalid_identifier, field: :table_name, value: value}}
    end
  end

  defp check_column_identifiers(columns) do
    columns
    |> Enum.find(fn column -> not valid_identifier?(column.name) end)
    |> case do
      nil -> :ok
      column -> {:error, {:invalid_identifier, field: :attribute, value: column.name}}
    end
  end

  defp enum_check_constraints(definition, promoted_columns) do
    promoted_names = MapSet.new(promoted_columns, & &1.name)

    definition
    |> Map.get(:fields, [])
    |> Enum.filter(fn field ->
      Map.get(field, :type) == :enum and MapSet.member?(promoted_names, Map.get(field, :name))
    end)
    |> Enum.map(fn field ->
      name = Map.get(field, :name)
      values = Map.get(field, :enum_values, [])
      value_list = Enum.map_join(values, ", ", &enum_literal/1)

      "CHECK (\"#{name}\" IN (#{value_list}))"
    end)
  end

  defp enum_literal(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp build_create_table_sql(table_name, columns, enum_checks) do
    column_lines = Enum.map(columns, &column_sql_line/1)

    constraint_lines =
      ["PRIMARY KEY (\"id\")", "UNIQUE (\"record_id\")"] ++ enum_checks

    lines = column_lines ++ constraint_lines

    """
    CREATE TABLE "#{table_name}" (
      #{Enum.join(lines, ",\n  ")}
    )\
    """
  end

  defp column_sql_line(%{name: name, pg_type: pg_type, nullable: nullable} = column) do
    null_clause = if nullable, do: "", else: " NOT NULL"
    default_clause = default_clause_for(column)

    ~s("#{name}" #{pg_type}#{null_clause}#{default_clause})
  end

  defp default_clause_for(%{name: "field_values"}), do: " DEFAULT '{}'::jsonb"
  defp default_clause_for(%{name: "deleted"}), do: " DEFAULT false"
  defp default_clause_for(_column), do: ""
end
