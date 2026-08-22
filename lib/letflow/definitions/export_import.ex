defmodule Letflow.Definitions.ExportImport do
  @moduledoc """
  Definition export/import (`Letflow.Definitions.ExportImport`), REQ-034, PD-09.
  Ported from `src/definition/export_import.zig`'s `ExportImportStore`.

  `export/2` serializes one `process_definitions` row (fetched via
  `Letflow.Definitions.get_by_id/2`) into an `ExportDocument`. `import/3` takes an
  `ExportDocument` and creates a brand-new draft definition via
  `Letflow.Definitions.create/2` -- re-running every one of REQ-028/029's graph
  validators with no bypass, because create/2 is the only write path this module
  uses. The imported row's id is always freshly assigned; `document.id` (the source
  definition's id) is carried only for informational/audit purposes and is never
  read when building the create/2 call.

  ## No independent validation (see design doc INV-EI-2)

  This module intentionally implements zero structural/attribute/edge-condition
  checks of its own. A document that would be rejected by `create/2` if its graph
  were submitted directly is rejected by `import/3` identically -- there is no
  parallel, potentially-diverging validation path here.

  ## Schema-version gate runs first

  `import/3` checks `document.bpm_export_schema_version` against
  `@export_schema_version` ("bpm/definition/v1") before touching tenant resolution,
  graph validation, or the database -- a mismatch returns
  `{:error, {:unknown_schema_version, actual}}`, never conflated with a generic
  `create/2` validation failure.
  """

  alias Letflow.Definitions

  @export_schema_version "bpm/definition/v1"

  defmodule ExportDocument do
    @moduledoc """
    In-memory export document for one `process_definitions` row (REQ-034, PD-09).
    Nested under `Letflow.Definitions.ExportImport`, per `Letflow.Definitions.Graph`'s
    `Node`/`Edge`/`Violation` precedent -- has no meaning or reuse outside
    export/import.
    """

    @enforce_keys [:bpm_export_schema_version, :id, :name, :version, :graph, :exported_at]
    defstruct [
      :bpm_export_schema_version,
      :id,
      :name,
      :version,
      :description,
      :graph,
      :exported_at
    ]

    @type t :: %__MODULE__{
            bpm_export_schema_version: String.t(),
            id: Ecto.UUID.t(),
            name: String.t(),
            version: String.t(),
            description: String.t() | nil,
            graph: map(),
            exported_at: String.t()
          }
  end

  @type opts :: Definitions.opts()
  @type common_error :: Definitions.common_error()

  @type export_error :: {:error, :not_found} | common_error()

  @type import_error ::
          {:error, {:unknown_schema_version, actual :: String.t()}}
          | Definitions.create_error()

  @doc """
  The single export-document schema-version constant, `"bpm/definition/v1"`.

  Exposed as a function (REQ-078) because
  `Letflow.Definitions.SolutionPack`'s multi-definition pack document carries
  the same version string and must not invent a second one — a module
  attribute is not referenceable from another module. **One version constant
  in this codebase, not two.**
  """
  @spec export_schema_version() :: String.t()
  def export_schema_version, do: @export_schema_version

  @doc """
  Exports one `process_definitions` row, identified by `id`, into an
  `ExportDocument`. Read-only -- performs no writes (INV-EI-7). `name`, `version`,
  `description` and `graph` are copied verbatim from the fetched row, with no
  trimming, casing, or normalization; `graph` in particular passes through
  unmodified end to end (INV-EI-3).

  Delegates the read entirely to `Letflow.Definitions.get_by_id/2` -- both its
  `{:error, :not_found}` and `common_error()` shapes propagate unchanged; this
  function invents no new error atom of its own.
  """
  @spec export(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, ExportDocument.t()} | export_error()
  def export(id, opts) when is_list(opts) do
    with {:ok, definition} <- Definitions.get_by_id(id, opts) do
      {:ok,
       %ExportDocument{
         bpm_export_schema_version: @export_schema_version,
         id: definition.id,
         name: definition.name,
         version: definition.version,
         description: definition.description,
         graph: definition.graph,
         exported_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  @doc """
  Imports an `ExportDocument`, creating a brand-new draft process definition via
  `Letflow.Definitions.create/2`. `imported_by` is this module's own addition (not
  named in REQ-034's text) -- it satisfies `create/2`'s required `:created_by` key,
  since `ExportDocument` carries no creator identity of its own.

  Checks `document.bpm_export_schema_version` against `@export_schema_version`
  first, before any tenant resolution, graph validation, or database call --  a
  mismatch returns `{:error, {:unknown_schema_version, actual}}` and stops (INV-EI-4).
  Never includes `document.id` in the attrs passed to `create/2` -- the imported
  row's `id` is always freshly assigned by `create/2`'s autogenerated primary key,
  with zero dependency on whether `document.id` collides with an existing row
  (INV-EI-1). Delegates 100% of graph/attribute/edge-condition validation to
  `create/2` -- this function performs no validation of its own and its return value
  is passed through unchanged (INV-EI-2).
  """
  @spec import(document :: ExportDocument.t(), imported_by :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, Definitions.ProcessDefinition.t()} | import_error()
  def import(document, imported_by, opts) when is_list(opts) do
    case document.bpm_export_schema_version do
      @export_schema_version ->
        attrs = %{
          name: document.name,
          version: document.version,
          description: document.description,
          graph: document.graph,
          created_by: imported_by
        }

        Definitions.create(attrs, opts)

      actual ->
        {:error, {:unknown_schema_version, actual}}
    end
  end
end
