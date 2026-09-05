defmodule Letflow.Definitions.SolutionPack do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Solution-pack export and install — the backing context for
  `Letflow.Routers.SolutionPacks` (REQ-078, design
  `lib/letflow/design/req078-supporting-routes.md` §8). Ports the parts of
  R-Co's `src/solution/store.zig` (`exportPack` L46, `installPack` L284) that
  Letflow has subsystems for.

  ## This module had to be BUILT, not merely routed to

  PROVENANCE (historical, not current decision authority):
  REQ-078's description called all six of its route modules "a one-to-three
  handler surface over existing context functions". That was true of five of
  them and false of this one: R-Co's two solution-pack handlers are thin only
  because they delegate to roughly 700 lines of `src/solution/store.zig`, of
  which Letflow had ported **none**. REQ-041 delivered the pack-update
  three-way diff (`Letflow.Definitions.compute_pack_update_plan/5`) plus three
  global Ecto schemas; `Letflow.Definitions.SolutionPackInstall`'s entire
  public surface is `insert_changeset/2`. `Letflow.Definitions.ExportImport`
  is a **single-definition** path and is not a substitute for a
  multi-definition pack document; it is reused here only for its
  `bpm/definition/v1` schema-version constant, so there is one version string
  in the codebase rather than two.

  ## What a Letflow pack document carries, and what it drops

  PROVENANCE (historical, not current decision authority):
  R-Co's `SolutionPackDocument` (`src/api/routes/solution_packs.zig:153-351`)
  has four content arrays. Letflow supports two:

    * `definitions` — supported (`process_definitions`, REQ-027/030).
    * `variable_schemas` — supported (`variable_schemas`, REQ-109). This is
      the whole point of REQ-078's AC8: install is one of the two write paths
      that must populate that table, and without it the table ships empty and
      REQ-061's variable-schema rejection branch stays unreachable
      (ISS-0063 / GH#212).
    * `service_catalog_entries` — **still not supported.** A
      `Letflow.ServiceCatalog` now exists (REQ-191), but which
      tenant-visibility policy a packed catalog entry should install under
      — tenant-scoped-to-the-installer only (consistent with every other
      `install/3` write) or a `scope: :global`, cross-tenant-visible entry
      (which no other `install/3` write does, and which raises its own
      write-authorization question) — is a decision left to REQ-192, the
      requirement already positioned to decide this catalog's
      write-authorization policy for its HTTP surface (SVC-04:
      `:AdminServicesManage`). Resolving `service_catalog_entries` at the
      same time avoids inventing a second, possibly inconsistent
      authorization stance later. Export still always emits `[]`; install
      still **rejects** a non-empty array with
      `{:error, :unsupported_pack_section}` rather than silently discarding
      tenant-supplied content or guessing at a policy this module was never
      asked to decide.
    * `manifest.required_roles` — supported, **read-only**: it produces the
      advisory `role_mapping_checklist` (see `install/3`). No role is created
      and no install is ever rejected because of it.

  ## Tenant scoping (INV-1)

  Every read `export/3` performs and every write `install/3` performs runs
  with `opts[:prefix]`, which the route derives solely from
  `Letflow.Api.Context.scoped_repo_opts/1`, i.e. solely from the authenticated
  token's `tenant_id`. No function here takes a tenant id, schema name or slug
  as a caller-supplied argument. The single exception to prefix-scoping is the
  one `solution_pack_installs` row, whose table is **global** by REQ-041's own
  design — and its `tenant_id` is *derived* from the resolved prefix via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, never accepted as
  a caller-supplied field.

  A definition id belonging to another tenant is invisible in the caller's
  schema, so an export naming it can only produce
  `{:error, {:definition_not_found, id}}` — never that tenant's artefact in
  the document.

  ## Install is ALL-OR-NOTHING. There is no "skipped" definition

  `installed_definition.status` is **always** `"installed"`.
  `Letflow.Definitions.create/2` has no upsert, no skip and no idempotent
  branch: it inserts, or it returns `{:error, :duplicate_name_version}` when
  `uq_definition_version` fires, which the route maps to a **409 that aborts
  the entire install**. Every packed definition that reaches the result map
  was inserted by that call; any that was not aborted the transaction before a
  result map existed.

  PROVENANCE (historical, not current decision authority):
  Consequence: **re-installing a pack whose `(name, version)` pairs already
  exist in the caller's schema is a 409, not a no-op.** This is a real
  behavioural divergence from R-Co, whose `buildIdempotentResult`
  (`src/solution/store.zig:682`, called from `:337`) returns a synthetic
  success for an already-installed pack. Letflow has no such path, and
  `uq_solution_pack_install_active` additionally makes a second install of the
  same `(tenant_id, pack_id)` a `{:error, :duplicate_pack_install}`. Named as
  a deliberate non-port, not left as an accident. If idempotent re-install is
  wanted later it needs its own requirement; it is not smuggled in here.

  PROVENANCE (historical, not current decision authority):
  `status` is nonetheless kept as a field rather than dropped, so the response
  shape stays compatible with R-Co's `serializeInstallResult`
  (`solution_packs.zig:426-463`) and a future idempotent-install requirement
  has somewhere to put `"skipped"` without changing the wire shape.

  ## `VARIABLE_SCHEMA_CONFLICT` is a deliberate non-port — and it is unreachable

  PROVENANCE (historical, not current decision authority):
  R-Co pre-checks for a conflicting `variable_schemas` row before install
  (`store.zig:419-441`). Letflow has nothing to check, and the branch could
  not fire if it existed:

    1. `Letflow.Definitions.ProcessDefinition`'s primary key is
       `@primary_key {:id, :binary_id, autogenerate: true}`, so every
       successful `create/2` mints a fresh, previously-unused `definition_id`.
    2. `create/2` never returns a pre-existing row — it inserts or errors.
    3. Step 7 below writes `variable_schemas` rows keyed **only** to ids
       produced in step 6, resolved through the
       `source_definition_id -> new_definition_id` mapping.
    4. Therefore no row an install writes can collide on
       `(definition_id, variable_key)` — the id half is new in every case. The
       `ON CONFLICT DO NOTHING` inside
       `Letflow.Definitions.register_variable_schemas/3` can only ever absorb
       a duplicate *within the same pack's own entries*, which that function
       rejects earlier with `{:error, {:duplicate_variable_key, key}}`.

  **Standing condition:** this non-port is valid *only while* install creates
  every definition it writes schemas for. If a later requirement adds an
  install mode that attaches variable schemas to a pre-existing definition,
  the conflict becomes reachable and must be reinstated.

  ## Other deliberate non-ports

    PROVENANCE (historical, not current decision authority):
    * **`409 CATALOG_CONFLICT`** (`solution_packs.zig:135`) — there is no
      catalog to conflict with (S6 service catalog).
    PROVENANCE (historical, not current decision authority):
    * **`409 TenantInactive`** (`solution_packs.zig:127-134`) —
      `Letflow.Plugs.TenantStatus` runs in `Letflow.Plugs.ApiPipeline`, before
      any sub-router, and rejects an inactive tenant's request with
      `403 tenant_inactive` for every method. A 409 branch here could never
      fire.
    PROVENANCE (historical, not current decision authority):
    * **`MODULE_NON_EXPORTABLE`** (`solution_packs.zig:83`) — Letflow has no
      process-module packaging (`process_modules.zig`, S5).
    * **503 `PoolExhausted`** — Ecto/DBConnection surfaces pool exhaustion as
      a raised `DBConnection.ConnectionError`, not an error tuple, so there is
      no tuple to match and a 503 clause would be unreachable.

  ## Known gap

  `manifest.required_roles` is always `[]` on export: nothing in Letflow
  declares per-definition roles yet. The field exists so the wire shape is
  stable and so an install document that *does* carry required roles (from
  another system, or a future Letflow that populates them) produces a
  meaningful checklist.
  """

  alias Letflow.Api.Authorization
  alias Letflow.Definitions
  alias Letflow.Definitions.ExportImport
  alias Letflow.Definitions.JsonSchemaShape
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Definitions.SolutionPackInstall
  alias Letflow.Engine.VariableSchema
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @typedoc "One definition inside a pack document."
  @type packed_definition :: %{
          definition_id: String.t(),
          process_key: String.t(),
          name: String.t(),
          version: String.t(),
          graph: map()
        }

  @typedoc """
  PROVENANCE (historical, not current decision authority):
  One variable-schema row inside a pack document. `schema_content` is a JSON
  *string* in R-Co's wire format (`solution_packs.zig:299`), not a decoded
  document.
  """
  @type packed_variable_schema :: %{
          definition_id: String.t(),
          schema_name: String.t(),
          schema_content: String.t()
        }

  @type pack_document :: %{
          pack_id: String.t(),
          version: String.t(),
          bpm_export_schema_version: String.t(),
          exported_at: String.t(),
          definitions: [packed_definition()],
          service_catalog_entries: [],
          variable_schemas: [packed_variable_schema()],
          manifest: %{required_roles: [String.t()]}
        }

  @type installed_definition :: %{
          source_definition_id: String.t(),
          new_definition_id: Ecto.UUID.t(),
          process_key: String.t(),
          status: String.t()
        }

  @type role_checklist_entry :: %{role_name: String.t(), bound: boolean()}

  @type install_result :: %{
          pack_id: String.t(),
          version: String.t(),
          install_id: Ecto.UUID.t(),
          installed_definitions: [installed_definition()],
          variable_schemas_written: non_neg_integer(),
          role_mapping_checklist: [role_checklist_entry()],
          warnings: [String.t()]
        }

  @type export_error ::
          {:error, {:definition_not_found, definition_id :: String.t()}}
          | {:error, :empty_definition_ids}
          | Definitions.common_error()

  @type install_error ::
          {:error, :invalid_pack_document}
          | {:error, {:unknown_schema_version, actual :: String.t()}}
          | {:error, :unsupported_pack_section}
          | {:error,
             {:malformed_variable_schema, variable_key :: String.t(),
              reason :: :invalid_json | :not_a_string}}
          | {:error, Definitions.variable_schema_error()}
          | {:error, :duplicate_pack_install}
          | {:error, :missing_prefix}
          | Definitions.create_error()
          | Definitions.common_error()

  @default_pack_version "1.0.0"

  @doc """
  Builds a multi-definition pack document from `definition_ids`, all read
  within the caller's own tenant schema (`opts[:prefix]`).

  For each id, in the order given: `Letflow.Definitions.get_by_id/2`, then
  `Letflow.Engine.VariableSchema.fetch_schemas/3` for that definition's
  variable-schema rows, flattened into the document's `variable_schemas` array
  with `schema_content` re-encoded as JSON text (R-Co's wire format).

  `{:error, :not_found}` from any id becomes
  `{:error, {:definition_not_found, id}}` and no document is produced. That is
  also the cross-tenant case: an id owned by another tenant is simply not in
  this prefix (INV-1/INV-5 — the route's 422 detail must therefore not echo
  the id, or it would confirm that some id exists somewhere).

  `pack_id` is a fresh `Ecto.UUID.generate/0`; `exported_at` is
  `DateTime.utc_now/0` in ISO 8601. `bpm_export_schema_version` reuses
  `Letflow.Definitions.ExportImport`'s `bpm/definition/v1` constant —
  one version constant in the codebase, not two.
  """
  @spec export(
          definition_ids :: [String.t()],
          version :: String.t() | nil,
          opts :: Definitions.opts()
        ) :: {:ok, pack_document()} | export_error()
  def export([], _version, _opts), do: {:error, :empty_definition_ids}

  def export(definition_ids, version, opts) when is_list(definition_ids) and is_list(opts) do
    with {:ok, packed} <- pack_each_definition(definition_ids, opts) do
      {:ok,
       %{
         pack_id: Ecto.UUID.generate(),
         version: pack_version(version),
         bpm_export_schema_version: ExportImport.export_schema_version(),
         exported_at: DateTime.to_iso8601(DateTime.utc_now()),
         definitions:
           Enum.map(packed, fn {definition, _schemas} -> pack_definition(definition) end),
         service_catalog_entries: [],
         variable_schemas: Enum.flat_map(packed, &pack_variable_schemas/1),
         manifest: %{required_roles: []}
       }}
    end
  end

  @doc """
  Installs a pack document into the caller's own tenant schema
  (`opts[:prefix]`), transactionally.

  `document` is the **raw decoded JSON body** (string keys) — this function
  owns the structural parse so the route layer stays a thin dispatcher, and a
  shape failure surfaces as the typed `{:error, :invalid_pack_document}`
  rather than as hand-rolled parsing in a `Plug.Router` module.

  Order of operations. Steps 1-3 issue **zero** queries, so a malformed
  document never reaches the database:

    1. `service_catalog_entries` non-empty -> `{:error, :unsupported_pack_section}`.
    PROVENANCE (historical, not current decision authority):
    2. `bpm_export_schema_version` mismatch ->
       `{:error, {:unknown_schema_version, actual}}` (R-Co:
       `INVALID_PACK_DOCUMENT`, `solution_packs.zig:168-172`).
    3. Well-formedness pre-check on every `variable_schemas` entry:
       `schema_content` is decoded with `Jason.decode/1` and checked by
       `Letflow.Definitions.JsonSchemaShape.check/1`. Any failure aborts with
       `{:error, {:malformed_variable_schema, schema_name, reason}}` and
       **nothing is written**.

  Then, inside one `Letflow.Repo.transaction/1`:

    4. (No conflict pre-check — see the moduledoc; it is unreachable here.)
    5. Insert the global `solution_pack_installs` row via
       `Letflow.Definitions.SolutionPackInstall.insert_changeset/2`, with
       `tenant_id` **derived** from `opts[:prefix]`. Its
       `uq_solution_pack_install_active` partial unique index surfaces as
       `{:error, :duplicate_pack_install}`.
    6. `Letflow.Definitions.create/2` per packed definition, with
       `name: process_key` and `created_by: actor_id`, recording the
       `source_definition_id -> new_definition_id` mapping.
    PROVENANCE (historical, not current decision authority):
    7. `Letflow.Definitions.register_variable_schemas/3` — **the single shared
       insert path into `variable_schemas`, which REQ-082's import also
       calls** — once per installed definition, with the entries whose
       `definition_id` resolves through that mapping. An entry naming a
       definition the pack does not carry is skipped and reported in
       `warnings`, matching R-Co's `continue` at `store.zig:483`.
    8. Build the advisory `role_mapping_checklist` and commit.

  Any error in steps 5-7 rolls the whole transaction back, so a rejected
  variable schema also un-creates the definitions the same install made.
  """
  @spec install(
          document :: map(),
          actor_id :: Ecto.UUID.t(),
          opts :: Definitions.opts()
        ) :: {:ok, install_result()} | install_error()
  def install(document, actor_id, opts) when is_list(opts) do
    with {:ok, parsed} <- parse_document(document),
         :ok <- check_unsupported_sections(parsed),
         :ok <- check_schema_version(parsed),
         {:ok, decoded_schemas} <- decode_variable_schemas(parsed.variable_schemas),
         {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix(opts)) do
      run_install(parsed, decoded_schemas, tenant_id, actor_id, opts)
    end
  end

  # ── export/3 helpers ──────────────────────────────────────────────────────

  defp prefix(opts), do: Keyword.get(opts, :prefix)

  defp pack_version(version) when is_binary(version) and byte_size(version) > 0, do: version
  defp pack_version(_absent), do: @default_pack_version

  # Reads in the order the caller listed the ids, so a not-found error names
  # the first offending id deterministically.
  defp pack_each_definition(definition_ids, opts) do
    Enum.reduce_while(definition_ids, {:ok, []}, fn id, {:ok, acc} ->
      case Definitions.get_by_id(id, opts) do
        {:ok, %ProcessDefinition{} = definition} ->
          case VariableSchema.fetch_schemas(Repo, definition.id, opts) do
            {:ok, schemas} -> {:cont, {:ok, [{definition, schemas} | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, :not_found} ->
          {:halt, {:error, {:definition_not_found, to_string(id)}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Hand-built, explicit key list -- never a Jason.Encoder derivation over
  # %ProcessDefinition{} (INV-2). `process_key` is the authoritative field on
  # install; `name` is the human label. Letflow's process_definitions carries
  # one `name` column, so the two are equal on export -- R-Co separates them
  # and the wire shape is kept compatible rather than collapsed.
  defp pack_definition(%ProcessDefinition{} = definition) do
    %{
      definition_id: definition.id,
      process_key: definition.name,
      name: definition.name,
      version: definition.version,
      graph: definition.graph
    }
  end

  defp pack_variable_schemas({%ProcessDefinition{} = definition, schemas}) do
    schemas
    |> Enum.sort_by(fn {variable_key, _json_schema} -> variable_key end)
    |> Enum.map(fn {variable_key, json_schema} ->
      %{
        definition_id: definition.id,
        schema_name: variable_key,
        schema_content: Jason.encode!(json_schema)
      }
    end)
  end

  # ── install/3 parsing (step 0) ────────────────────────────────────────────

  defp parse_document(document) when is_map(document) and not is_struct(document) do
    with {:ok, pack_id} <- fetch_string(document, "pack_id"),
         {:ok, version} <- fetch_string(document, "version"),
         {:ok, schema_version} <- fetch_string(document, "bpm_export_schema_version"),
         {:ok, raw_definitions} <- fetch_list(document, "definitions"),
         {:ok, raw_variable_schemas} <- fetch_list(document, "variable_schemas"),
         {:ok, raw_catalog} <- fetch_list(document, "service_catalog_entries"),
         {:ok, definitions} <- parse_definitions(raw_definitions),
         {:ok, variable_schemas} <- parse_variable_schemas(raw_variable_schemas),
         {:ok, required_roles} <- parse_required_roles(Map.get(document, "manifest")) do
      {:ok,
       %{
         pack_id: pack_id,
         version: version,
         bpm_export_schema_version: schema_version,
         definitions: definitions,
         variable_schemas: variable_schemas,
         service_catalog_entries: raw_catalog,
         required_roles: required_roles
       }}
    end
  end

  defp parse_document(_not_an_object), do: {:error, :invalid_pack_document}

  defp fetch_string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _absent_or_wrong_type -> {:error, :invalid_pack_document}
    end
  end

  defp fetch_list(map, key) do
    case Map.get(map, key, []) do
      value when is_list(value) -> {:ok, value}
      nil -> {:ok, []}
      _wrong_type -> {:error, :invalid_pack_document}
    end
  end

  defp parse_definitions(raw_definitions) do
    Enum.reduce_while(raw_definitions, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_definition(raw) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_definition(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, definition_id} <- fetch_string(raw, "definition_id"),
         {:ok, process_key} <- fetch_string(raw, "process_key"),
         {:ok, version} <- fetch_string(raw, "version"),
         {:ok, graph} <- fetch_object(raw, "graph") do
      {:ok,
       %{
         definition_id: definition_id,
         process_key: process_key,
         name: optional_string(raw, "name", process_key),
         version: version,
         graph: graph
       }}
    end
  end

  defp parse_definition(_not_an_object), do: {:error, :invalid_pack_document}

  defp fetch_object(map, key) do
    case Map.get(map, key) do
      value when is_map(value) and not is_struct(value) -> {:ok, value}
      _absent_or_wrong_type -> {:error, :invalid_pack_document}
    end
  end

  defp optional_string(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _absent_or_wrong_type -> default
    end
  end

  defp parse_variable_schemas(raw_entries) do
    Enum.reduce_while(raw_entries, {:ok, []}, fn raw, {:ok, acc} ->
      case parse_variable_schema(raw) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_variable_schema(raw) when is_map(raw) and not is_struct(raw) do
    with {:ok, definition_id} <- fetch_string(raw, "definition_id"),
         {:ok, schema_name} <- fetch_string(raw, "schema_name") do
      {:ok,
       %{
         definition_id: definition_id,
         schema_name: schema_name,
         schema_content: Map.get(raw, "schema_content"),
         description: optional_string(raw, "description", nil)
       }}
    end
  end

  defp parse_variable_schema(_not_an_object), do: {:error, :invalid_pack_document}

  defp parse_required_roles(nil), do: {:ok, []}

  defp parse_required_roles(manifest) when is_map(manifest) and not is_struct(manifest) do
    case Map.get(manifest, "required_roles", []) do
      roles when is_list(roles) ->
        if Enum.all?(roles, &is_binary/1),
          do: {:ok, roles},
          else: {:error, :invalid_pack_document}

      nil ->
        {:ok, []}

      _wrong_type ->
        {:error, :invalid_pack_document}
    end
  end

  defp parse_required_roles(_not_an_object), do: {:error, :invalid_pack_document}

  # ── install/3 steps 1-3 (pure, zero queries) ──────────────────────────────

  # REQ-191 retains this hard-fail as-is (does not make it functional) --
  # see this module's moduledoc "service_catalog_entries" bullet. REQ-192
  # is named as the owning follow-up for deciding the install-time
  # visibility policy a packed entry would need.
  defp check_unsupported_sections(%{service_catalog_entries: []}), do: :ok
  defp check_unsupported_sections(_parsed), do: {:error, :unsupported_pack_section}

  defp check_schema_version(%{bpm_export_schema_version: version}) do
    if version == ExportImport.export_schema_version() do
      :ok
    else
      {:error, {:unknown_schema_version, version}}
    end
  end

  # Decodes every `schema_content` JSON string and checks its shape BEFORE the
  # transaction opens. `Letflow.Definitions.register_variable_schemas/3` runs
  # the identical shape check again inside the transaction -- that is the
  # authoritative one; this one exists so a malformed document is rejected
  # without opening a transaction at all.
  defp decode_variable_schemas(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decode_variable_schema(entry) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_variable_schema(%{schema_content: content, schema_name: name} = entry)
       when is_binary(content) do
    case Jason.decode(content) do
      {:ok, document} ->
        case JsonSchemaShape.check(document) do
          :ok ->
            {:ok, %{entry | schema_content: document}}

          {:error, {:not_well_formed, path}} ->
            {:error, {:not_well_formed, name, path}}

          {:error, :too_deep} ->
            {:error, {:schema_too_deep, name}}
        end

      {:error, %Jason.DecodeError{}} ->
        {:error, {:malformed_variable_schema, name, :invalid_json}}
    end
  end

  defp decode_variable_schema(%{schema_name: name}),
    do: {:error, {:malformed_variable_schema, name, :not_a_string}}

  # ── install/3 steps 5-8 (transactional) ───────────────────────────────────

  defp run_install(parsed, decoded_schemas, tenant_id, actor_id, opts) do
    Repo.transaction(fn ->
      with {:ok, install} <- insert_install_row(parsed, tenant_id),
           {:ok, installed} <- create_packed_definitions(parsed.definitions, actor_id, opts),
           {:ok, written, warnings} <- register_packed_schemas(installed, decoded_schemas, opts) do
        %{
          pack_id: parsed.pack_id,
          version: parsed.version,
          install_id: install.id,
          installed_definitions: installed_definition_maps(installed),
          variable_schemas_written: written,
          role_mapping_checklist: role_mapping_checklist(parsed.required_roles),
          warnings: warnings
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp insert_install_row(parsed, tenant_id) do
    %SolutionPackInstall{}
    |> SolutionPackInstall.insert_changeset(%{
      tenant_id: tenant_id,
      pack_id: parsed.pack_id,
      installed_version: parsed.version,
      installed_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
    })
    |> Repo.insert()
    |> case do
      {:ok, install} ->
        {:ok, install}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_conflict?(changeset, :tenant_id) or unique_conflict?(changeset, :pack_id) do
          {:error, :duplicate_pack_install}
        else
          {:error, changeset}
        end
    end
  end

  defp unique_conflict?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, meta}} -> Keyword.get(meta, :constraint) == :unique
      _other -> false
    end)
  end

  # Every definition lands in the caller's own schema via `opts[:prefix]` and
  # nowhere else. All-or-nothing: the first failure aborts (see moduledoc).
  defp create_packed_definitions(packed_definitions, actor_id, opts) do
    Enum.reduce_while(packed_definitions, {:ok, []}, fn packed, {:ok, acc} ->
      attrs = %{
        name: packed.process_key,
        version: packed.version,
        graph: packed.graph,
        created_by: actor_id
      }

      case Definitions.create(attrs, opts) do
        {:ok, %ProcessDefinition{} = created} ->
          {:cont, {:ok, [{packed, created} | acc]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # Step 7 -- the ONLY write into `variable_schemas`, and it goes through
  # Letflow.Definitions.register_variable_schemas/3, the single shared insert
  # path REQ-082's import also calls. This module adds no second one.
  defp register_packed_schemas(installed, decoded_schemas, opts) do
    by_source = Map.new(installed, fn {packed, created} -> {packed.definition_id, created.id} end)

    {resolved, warnings} =
      Enum.reduce(decoded_schemas, {%{}, []}, fn entry, {acc, warnings} ->
        case Map.fetch(by_source, entry.definition_id) do
          {:ok, new_definition_id} ->
            input = %{
              variable_key: entry.schema_name,
              json_schema: entry.schema_content,
              description: entry.description
            }

            {Map.update(acc, new_definition_id, [input], &(&1 ++ [input])), warnings}

          :error ->
            {acc,
             warnings ++
               [
                 "variable_schemas entry #{inspect(entry.schema_name)} names definition_id " <>
                   "#{inspect(entry.definition_id)}, which this pack does not carry; skipped"
               ]}
        end
      end)

    resolved
    |> Enum.reduce_while({:ok, 0}, fn {definition_id, inputs}, {:ok, total} ->
      case Definitions.register_variable_schemas(definition_id, inputs, opts) do
        {:ok, written} -> {:cont, {:ok, total + written}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, total} -> {:ok, total, warnings}
      {:error, _reason} = error -> error
    end
  end

  defp installed_definition_maps(installed) do
    Enum.map(installed, fn {packed, created} ->
      %{
        source_definition_id: packed.definition_id,
        new_definition_id: created.id,
        process_key: created.name,
        status: "installed"
      }
    end)
  end

  # PROVENANCE (historical, not current decision authority):
  # Read-only and advisory: no role is created, none is bound, and the
  # checklist never affects whether the install succeeds. This is a NARROWED
  # analogue of R-Co's `checkRoleGate` (`src/solution/store.zig:589`): that
  # gate can reject an install, but this implementation only reports and
  # proceeds. "Checklist" must not be read as an enforced precondition.
  defp role_mapping_checklist(required_roles) do
    known = MapSet.new(Authorization.roles(), &Atom.to_string/1)

    Enum.map(required_roles, fn role_name ->
      %{role_name: role_name, bound: MapSet.member?(known, role_name)}
    end)
  end
end
