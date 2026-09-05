defmodule Letflow.Engine.VariableSchema do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Ecto schema for the tenant-scoped `variable_schemas` table, and the
  per-key output-variable schema lookup that feeds
  `Letflow.Engine.VariableMerge.merge/3`'s `variable_validations` argument
  (REQ-109, `lib/letflow/design/req109-variable-schemas.md`). Ports R-Co's
  `variable_schemas` table (`migrations/012_event_retention.sql:32-49`) and
  the single SELECT `mergeVariables` issues against it
  (`src/engine/instance.zig:2318`, "Issues one SELECT on `variable_schemas`;
  no writes"). Closes ISS-0063 / GH#212.

  ## Three R-Co concepts carry the word "schema" — only one is this table

  A prior investigation conflated them (ISS-0063's
  `superseded_scoping_note`, explicitly marked do-not-act-on), so all three
  are named here and this list is the record that keeps the mistake from
  being repeatable:

    PROVENANCE (historical, not current decision authority):
    * **`tasks.form_schema`** — populated at activation from
      `node.attributes["form_schema"]` (R-Co `src/engine/instance.zig:5490`,
      `extractFormSchemaJson`) and served in the task-detail response
      (R-Co `src/api/routes/tasks.zig:896`). A UI form-**rendering** payload;
      **R-Co never validates submitted output against it.** OUT OF SCOPE, and
      REQ-047's OQ-3 stays open — answering it would not have closed
      ISS-0063.
    * **`variable_schemas`** (this module) —
      `(definition_id, variable_key) -> json_schema`, the real per-variable
      validation source, read by `mergeVariables`. IN SCOPE; REQ-109 is about
      this table and nothing else.
    * **`form_schema_registry`** — R-Co
      `migrations/047_repository_form_schemas.sql`, REPO-05: a field-level
      search/discovery index over form artifacts, keyed to
      `artifact_versions`. OUT OF SCOPE; named because grepping "form schema"
      lands here first and would build the wrong mechanism.

  ## A dedicated table, not `event_type_registry` — closes `req049-variable-merge.md` §7.3

  `req049-variable-merge.md` §7.3 left open "whether a variable schema is
  registered in the existing `event_type_registry` table under a name derived
  from the variable key, or in a new dedicated table." **REQ-109 settles it as
  the dedicated table**, on three grounds:

    1. R-Co has a distinct `variable_schemas` table keyed by
       `(definition_id, variable_key)` — this is a port, and the source
       system's own answer is a dedicated table.
    2. Reusing `event_type_registry` would require inventing a
       variable-key-to-event-type-name mangling with no source counterpart.
    3. It would pollute the event-type namespace with rows that are not event
       types, which every `Letflow.EventStore.Registry.get_type/2` caller
       would then have to filter around.

  That resolution also closes `req049-variable-merge.md` §13.1 ("where a
  registered variable schema is stored and looked up"). **The question is
  closed; do not re-open it.**

  ## The registration (INSERT) path — BUILT BY REQ-078, no longer deferred

  PROVENANCE (historical, not current decision authority):
  REQ-109 built the table, this schema module, the lookup and the engine
  wiring, and wrote **no** `variable_schemas` row: `Letflow.Engine` only ever
  reads this table. R-Co scoped it identically — variable schemas are
  "created during process definition loading (existing mechanism, not part of
  ISS-202)" (R-Co `src/design/engine-merge.md:173`), with the writes living in
  `src/api/routes/solution_packs.zig:299` (solution-pack install) and
  `src/definition/fixture_loader.zig:32`.

  Those mapped onto two S4 requirements:

    PROVENANCE (historical, not current decision authority):
    * **REQ-078** — `solution_packs.zig`'s `handleInstall` (L110). **Landed;
      it built the shared function.**
    PROVENANCE (historical, not current decision authority):
    * **REQ-082** — `definitions.zig`'s `handleImport` (L1126), plus
      `handleCreate`/`handlePut` where the submitted document carries schemas.
      **Pending; it CALLS the shared function and adds no second
      implementation.**

  **Neither description mentioned `variable_schemas` registration before
  REQ-109 added the obligation to both.** The registration logic lives in a
  **single** shared function, `Letflow.Definitions.register_variable_schemas/3`
  — the one and only insert path into this table anywhere in `lib/`. A
  re-import onto the same `definition_id` must **replace** that definition's
  rows in the same transaction rather than accumulate duplicates against
  `uq_variable_schema_definition_key`; REQ-078's install path never hits that
  case, because every `definition_id` it writes against was minted by the same
  transaction (`Letflow.Definitions.SolutionPack`'s moduledoc has the proof).

  ## OQ-3 (`req109-variable-schemas.md` §11.3) is CLOSED by REQ-078, in favour of validate-before-insert

  A `variable_schemas` row is written by exactly one function —
  `Letflow.Definitions.register_variable_schemas/3` — and that function rejects
  any `json_schema` that is not a well-formed JSON Schema document *at every
  level* with `{:error, {:not_well_formed, variable_key, path}}` before issuing
  any insert. The well-formedness predicate
  (`Letflow.Definitions.JsonSchemaShape.check/1`) is additionally wired into
  `changeset/2` below, so **every** writer is covered — including this
  module's own test seeds and any future path that bypasses the registration
  function — not only callers that remember to go through it.

  Consequence for the read path: a top-level non-object `json_schema` can no
  longer be stored, so `fetch_schemas/3`'s typed `:map` select can no longer
  raise `ArgumentError` at Ecto load time (**ISS-0089 / GH#306 — closed by
  construction**), and a nested non-map subschema can no longer be stored
  either (**ISS-0088 / GH#305 — already resolved separately by the
  `is_map(subschema)` guard now in
  `Letflow.EventStore.Registry.JsonSchema.properties_violations/3`; REQ-078
  makes that guard unreachable as well. GH#305 is closed and must not be
  reopened**).

  `validations_for/3`'s `{:ok, _not_a_map}` clause and
  `JsonSchema.properties_violations/3`'s `is_map(subschema)` guard are
  **deliberately retained** as last-resort guards against a future writer that
  bypasses `changeset/2` — for example raw SQL inside a migration, or a
  hand-built `Repo.insert_all/3`, neither of which any changeset can
  intercept. They are unreachable through every path that exists today. Do not
  read them as live defences, and do not add a new write path that would make
  them live again. REQ-078 deletes neither: removing live-looking defensive
  code in the same change that makes it unreachable removes the safety net at
  exactly the moment the new guarantee is least proven.

  ## Two other consumers remain unwired — REQ-109 changes neither

    * `lib/letflow/definitions/promotion_plan.ex`'s
      `default_variable_schema_fetcher/2` returns `nil`. REQ-109 corrects only
      the stale comment above it (which asserted no `variable_schemas` table
      exists); the function's return value and `@spec` are unchanged.
    * `lib/letflow/engine/pin_resolver.ex:267-268` (REQ-059) —
      `default_lookup/0`'s `variable_schema_lookup` returns
      `{:ok, %{version: "unversioned", json_schema: nil}}`. That is **a
      populated tuple whose `json_schema` is nil, not a nil return**;
      describing it as null-returning is wrong. It is also why the REQ-059
      pinning-vs-live-read tension recorded in `Letflow.Engine`'s moduledoc is
      latent rather than live.

  Wiring either one is a separate requirement's job.

  ## Tenant scoping (INV-1)

  `variable_schemas` lives inside the per-tenant Postgres schema and carries
  **no `tenant_id` column** (Decision 0006 D2). Every read must pass an
  explicit non-empty `prefix:`; there is no `public`-schema fallback and no
  default. A missing, nil or empty prefix returns `{:error, :missing_prefix}`
  with **zero queries issued** — `Repo.all(query, prefix: nil)` would silently
  resolve to Ecto's default schema, which for this table is a cross-tenant
  read.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Changeset
  alias Letflow.Definitions.JsonSchemaShape
  alias Letflow.EventStore.Registry.JsonSchema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "variable_schemas" do
    field(:definition_id, Ecto.UUID)
    field(:variable_key, :string)
    field(:json_schema, :map)
    field(:description, :string)
    field(:created_at, :utc_datetime_usec, read_after_writes: true)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          definition_id: Ecto.UUID.t() | nil,
          variable_key: String.t() | nil,
          json_schema: map() | nil,
          description: String.t() | nil,
          created_at: DateTime.t() | nil
        }

  @typedoc "variable_key -> the stored JSON Schema document, as decoded jsonb."
  @type schema_map :: %{optional(String.t()) => map()}

  @typedoc "Every distinct, pattern-matchable failure this module's read path returns."
  @type error_reason :: :missing_prefix | :invalid_definition_id

  @doc """
  Changeset for a `variable_schemas` row.

  REQ-109 itself wrote no rows — this exists because REQ-109's own tests seed
  rows against a provisioned tenant schema, and because REQ-078/REQ-082's
  shared registration function
  (`Letflow.Definitions.register_variable_schemas/3`) needs exactly this
  changeset rather than inventing a second one. REQ-078 has landed and calls
  it.

  **`json_schema` IS validated for well-formedness here, at every level**
  (REQ-078, closing design §11.3's OQ-3 in favour of validate-before-insert —
  see this module's moduledoc). The column is jsonb, which accepts arrays,
  strings, numbers and booleans as readily as objects; this changeset is the
  choke point that stops any of them being stored. A document that is not a
  JSON object at every level adds a `:json_schema` error and the changeset is
  invalid.

  This supersedes the earlier text here, which said the changeset "does not
  validate that `json_schema` is itself a well-formed JSON Schema document"
  and warned REQ-078/REQ-082 not to assume it does. That warning is now
  false — the guarantee holds for **every** writer that goes through a
  changeset, not only for callers of the registration function. Raw SQL in a
  migration and `Repo.insert_all/3` still bypass it; that is why the read
  path's defensive branches are retained (see `validations_for/3`).
  """
  @spec changeset(t() | Changeset.t(), map()) :: Changeset.t()
  def changeset(variable_schema, attrs) do
    variable_schema
    |> Changeset.cast(attrs, [:definition_id, :variable_key, :json_schema, :description])
    |> Changeset.validate_required([:definition_id, :variable_key, :json_schema])
    |> Changeset.validate_change(:json_schema, &validate_json_schema_shape/2)
    |> Changeset.unique_constraint([:definition_id, :variable_key],
      name: :uq_variable_schema_definition_key
    )
  end

  # REQ-078 §9.3 -- the well-formedness choke point. Delegates to the leaf
  # module Letflow.Definitions.register_variable_schemas/3 also calls, so
  # there is exactly one definition of "well formed" in the codebase.
  # JsonSchemaShape lives in its own module precisely so this Engine module
  # does not have to call into Letflow.Definitions (wrong dependency
  # direction -- design OQ-2).
  @spec validate_json_schema_shape(:json_schema, term()) :: [{:json_schema, String.t()}]
  defp validate_json_schema_shape(:json_schema, value) do
    case JsonSchemaShape.check(value) do
      :ok ->
        []

      {:error, {:not_well_formed, path}} ->
        [{:json_schema, "is not a well-formed JSON Schema document at /" <> Enum.join(path, "/")}]

      {:error, :too_deep} ->
        [{:json_schema, "nesting exceeds the maximum supported depth"}]
    end
  end

  @doc """
  Builds the `variable_validations` map `Letflow.Engine.VariableMerge.merge/3`
  consumes, for one task completion. The engine's single entry point into this
  module (design §4.5).

  Behaviour, in this exact order:

    1. Validate `opts[:prefix]` — `{:error, :missing_prefix}` on a nil,
       non-binary or empty value, **before any other work and before any query
       is constructed**.
    2. Compute the validation candidates: every key in `incoming_variables`,
       new or overwrite alike.
    PROVENANCE (historical, not current decision authority):
    3. If that set is empty (i.e. `incoming_variables` is empty), return
       `{:ok, %{}}` without issuing a query — no candidates means no schema
       lookup could possibly be needed (the same fast-path shape as
       `instance.zig:2331`'s `if (output_variables.count() == 0)`,
       generalised here to "nothing to validate"). This runs *after* step 1, so a
       missing prefix still fails closed even when there is nothing to look
       up.
    4. `fetch_schemas/3`. Any `{:error, reason}` propagates unchanged.
    5. `validations_for/3` over the candidate list.

  PROVENANCE (historical, not current decision authority):
  **Every incoming key is validated, new or overwrite alike**
  (`docs/migration/decisions/0007-variable-merge-validates-new-keys.md`,
  GH#300/ISS-0077). Before that fix, only overwrite candidates — keys present
  in both `current_variables` and `incoming_variables` — were validated, and a
  brand-new key with a registered schema was inserted unconditionally; that
  was `req049-variable-merge.md` §3.1 step 3's rule and REQ-109's AC5, and it
  diverged from R-Co, whose Phase 1 (`instance.zig:2390-2430`) validates every
  key with a schema and only afterwards checks collision. The divergence was
  flagged for REVIEWER as design §11.1 (OQ-1); this fix is that decision,
  adopting R-Co's semantic. `current_variables` is kept as a parameter — both
  call sites already have it in scope, and it still serves as an input-shape
  guard below — but no longer filters which keys get validated.
  """
  @spec variable_validations(
          repo :: module(),
          definition_id :: Ecto.UUID.t() | nil,
          current_variables :: map(),
          incoming_variables :: map(),
          opts :: [prefix: String.t() | nil]
        ) ::
          {:ok, Letflow.Engine.VariableMerge.variable_validations()} | {:error, error_reason()}
  def variable_validations(repo, definition_id, current_variables, incoming_variables, opts)
      when is_atom(repo) and is_map(current_variables) and is_map(incoming_variables) and
             is_list(opts) do
    with {:ok, prefix} <- validate_prefix(opts) do
      candidate_keys = validation_keys(incoming_variables)

      if candidate_keys == [] do
        {:ok, %{}}
      else
        with {:ok, schemas} <- fetch_schemas(repo, definition_id, prefix: prefix) do
          {:ok, validations_for(schemas, candidate_keys, incoming_variables)}
        end
      end
    end
  end

  @doc """
  The single SELECT: every `(variable_key, json_schema)` row registered for
  `definition_id`, as a `schema_map()`.

  `repo` is taken as an argument rather than aliased, because the one caller
  runs inside `Ecto.Multi.run/3`, which hands its own `repo` to the step
  function — taking it here keeps the read on the enclosing transaction's
  connection alongside the already-locked `instance_projections` row.

  PROVENANCE (historical, not current decision authority):
  One query, never one per key — avoiding an N+1 read pattern here (the same
  one-query shape `instance.zig:2318`'s own doc comment documents). The query
  is deliberately **not** filtered by candidate
  key: R-Co selects every row for the definition and filters in memory
  (`instance.zig:2345-2358`), the row count per definition is small and bounded
  by the definition's declared variables, and one stable query plan is easier
  to reason about than a variable-length `IN` list. Adding
  `and vs.variable_key in ^keys` would be a safe optimisation if profiling ever
  showed it mattered.

  Composed with `Ecto.Query` and bound parameters only — no SQL string
  interpolation anywhere (INV-7; the same parameterization discipline the
  corresponding R-Co source comment, "$1 = definition_id hex", documents).

  Order of operations is load-bearing: `opts[:prefix]` is validated first, then
  `definition_id`, and only then is a query constructed. Both failures issue
  zero queries.
  """
  @spec fetch_schemas(
          repo :: module(),
          definition_id :: Ecto.UUID.t() | nil,
          opts :: [prefix: String.t() | nil]
        ) :: {:ok, schema_map()} | {:error, error_reason()}
  def fetch_schemas(repo, definition_id, opts) when is_atom(repo) and is_list(opts) do
    with {:ok, prefix} <- validate_prefix(opts),
         {:ok, definition_id} <- validate_definition_id(definition_id) do
      rows =
        from(vs in __MODULE__,
          where: vs.definition_id == ^definition_id,
          select: {vs.variable_key, vs.json_schema}
        )
        |> repo.all(prefix: prefix)

      {:ok, Map.new(rows)}
    end
  end

  @doc """
  Pure: maps `keys_to_validate` onto per-key
  `Letflow.Engine.VariableMerge.validation_outcome()` values. No `Repo`, no
  clock, no randomness — so the mapping can be exercised without a database.

  Per key `K`:

    * no entry in `schemas` -> `K` is **omitted** from the result, not mapped
      to `:ok`. `merge/3`'s `Map.get(validations, key, :ok)` default already
      treats an absent entry as `:ok` (`variable_merge.ex:186`, documented at
      its `variable_validations` typedoc); omission is the contract, and an
      explicit `:ok` would behave identically while obscuring which keys had a
      schema at all.
    PROVENANCE (historical, not current decision authority):
    * an entry that is **not a map** -> also omitted, and logged. The column is
      `NOT NULL` jsonb, which permits an array, string, number or boolean —
      none of which satisfy `JsonSchema.validate/2`'s `when is_map(schema)`
      guard, so calling it would raise `FunctionClauseError` inside an open
      transaction on the task-completion hot path, turning one bad registration
      row into a hard failure of every completion for that definition. A
      stored schema that is not a map is therefore treated as **no
      constraint**, exactly as if no row existed. R-Co's related disposition —
      tolerate and skip an unusable stored schema rather than fail the merge —
      is at `instance.zig:2426-2428`, though it is strictly narrower (it fires
      only when the stored text fails to parse as JSON at all). The log names
      `variable_key` and deliberately logs **neither** the schema document nor
      the variable's value, both of which are tenant data. Design §6.3 also
      asked for `definition_id` in that line; this function's signature (fixed
      by design §4.2, and kept pure so the mapping can be tested without a
      database) does not carry it, so it is omitted rather than the arity
      widened — flagged for REVIEWER as a deliberate, minor deviation.
    * otherwise -> `JsonSchema.validate/2`, with `[]` mapped to `:ok` and a
      non-empty failure list to `{:rejected, failures}`, the list reused
      verbatim (it is already `[ValidationFailure.t()]`, exactly what
      `merge/3`'s `execution_error_event()` and `Letflow.Engine.ExecutionError`
      consume).

  The value and the stored schema are each wrapped in a single-key object —
  `%{K => value}` against
  `%{"type" => "object", "properties" => %{K => schema}, "required" => [K]}` —
  because a workflow variable's value may be a string, number, boolean, list or
  `nil`, and `JsonSchema.validate/2` is guarded `when is_map(payload) and
  is_map(schema)`. This is the shape already proven at
  `lib/letflow/engine/sub_process.ex:179-185`, and it **supersedes**
  `req049-variable-merge.md` §7.1's `{"value" => raw}` convention: using the
  variable's own key as the wrapper key makes the returned
  `ValidationFailure.field_path` read `/amount` rather than `/value`, so the
  failure list that reaches the `EXECUTION_ERROR` payload names the real
  variable.

  The returned map's keys are always a subset of `keys_to_validate`.
  """
  @spec validations_for(
          schemas :: schema_map(),
          keys_to_validate :: [String.t()],
          incoming_variables :: map()
        ) :: Letflow.Engine.VariableMerge.variable_validations()
  def validations_for(schemas, keys_to_validate, incoming_variables)
      when is_map(schemas) and is_list(keys_to_validate) and is_map(incoming_variables) do
    Enum.reduce(keys_to_validate, %{}, fn key, acc ->
      case Map.fetch(schemas, key) do
        :error ->
          acc

        {:ok, schema} when is_map(schema) ->
          Map.put(acc, key, outcome_for(key, Map.get(incoming_variables, key), schema))

        # UNREACHABLE BY CONSTRUCTION since REQ-078 (see this module's
        # moduledoc, "OQ-3 ... CLOSED"): changeset/2 now rejects any
        # json_schema that is not a JSON object at every level, and
        # Letflow.Definitions.register_variable_schemas/3 is the only insert
        # path in lib/. This clause is retained as a last-resort guard, NOT as
        # a live defence -- the only thing that could still fire it is a
        # writer that bypasses changeset/2 entirely (raw SQL in a migration,
        # or Repo.insert_all/3). Do not read it as evidence such a row can
        # exist today, and do not add a write path that would make it live
        # again.
        {:ok, _not_a_map} ->
          Logger.warning(
            "variable_schemas row has a non-map json_schema; treating as no constraint " <>
              "(variable_key=#{inspect(key)})"
          )

          acc
      end
    end)
  end

  @spec outcome_for(String.t(), term(), map()) ::
          Letflow.Engine.VariableMerge.validation_outcome()
  defp outcome_for(key, value, schema) do
    wrapped_schema = %{
      "type" => "object",
      "properties" => %{key => schema},
      "required" => [key]
    }

    case JsonSchema.validate(%{key => value}, wrapped_schema) do
      [] -> :ok
      [_ | _] = failures -> {:rejected, failures}
    end
  end

  # Every incoming key is a validation candidate, new or overwrite alike
  # (docs/migration/decisions/0007-variable-merge-validates-new-keys.md,
  # GH#300/ISS-0077). Before that fix this filtered to keys already present in
  # current_variables (the "overwrite candidates"); a brand-new key with a
  # registered schema bypassed validation entirely.
  @spec validation_keys(map()) :: [String.t()]
  defp validation_keys(incoming_variables) do
    Map.keys(incoming_variables)
  end

  # Fail closed (INV-1, design §6.1), matching lua_script_audit.ex:152-158's
  # and snapshot_store.ex:157's precedent exactly: unlike
  # `repo.all(query, prefix: nil)`, which silently resolves to Ecto's default
  # (`public`) schema, this returns a distinct typed error and issues zero
  # queries. `""` is rejected alongside nil and non-binaries -- an empty
  # prefix is not a schema name.
  @spec validate_prefix(prefix: String.t() | nil) :: {:ok, String.t()} | {:error, :missing_prefix}
  defp validate_prefix(opts) do
    case Keyword.fetch(opts, :prefix) do
      {:ok, prefix} when is_binary(prefix) and prefix != "" -> {:ok, prefix}
      _ -> {:error, :missing_prefix}
    end
  end

  # Defensive (design §6.4): this function's own `definition_id` parameter stays
  # `Ecto.UUID.t() | nil`, and this guard stays, even though
  # `InstanceProjection.definition_id` is now typed non-nullable (GH#310 / ISS-0091)
  # -- `fetch_schemas/3`/`variable_validations/5` are this module's public entry
  # points, not sealed to `InstanceProjection` as their only possible caller. A
  # malformed or nil value reaching a `where` here would raise
  # Ecto.Query.CastError rather than returning a typed error -- the same class
  # engine.ex's own cast_task_id/1 guards against. What's unreachable today is
  # only the specific path from `Letflow.Engine.complete_task/3`, which now says
  # so in its own @spec rather than in this module.
  @spec validate_definition_id(Ecto.UUID.t() | nil) ::
          {:ok, Ecto.UUID.t()} | {:error, :invalid_definition_id}
  defp validate_definition_id(definition_id) do
    case Ecto.UUID.cast(definition_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_definition_id}
    end
  end
end
