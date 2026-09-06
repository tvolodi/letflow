defmodule Letflow.Entities.Definitions do
  @moduledoc """
  Tenant-scoped CRUD context module for `entity_definitions` (REQ-226). See
  `lib/letflow/design/req226-entity-definitions-persistence-crud.md` §3 for
  the full design this module implements: §3.3 (`create_definition/2`'s
  exact ordering guarantee and `list_definitions/2`'s REQ-067 cursor
  contract) and §3.4 (`activate_definition/4`'s thin wrapper over REQ-203's
  existing activation machinery).

  This is the **context-module** third of the document/schema/context
  three-way split named in the design's §3.1:
  `Letflow.Entities.Definition` (REQ-225) is the plain document `@type`;
  `Letflow.Entities.EntityDefinition` (REQ-226) is the persisted-row
  `Ecto.Schema`; this module is the tenant-scoped CRUD context module that
  depends on both, plus `Letflow.Entities.Definition.Validator`,
  `Letflow.Entities.Definition.Shape`, and `Letflow.Repository`/
  `Letflow.Repository.Activation` (REQ-202/REQ-203's existing pipelines) --
  never the reverse.

  Tenant scoping follows the same convention every other context module in
  this codebase uses (`Letflow.Repository`, `Letflow.Repository.Activation`,
  `Letflow.Audit`): every public function takes an explicit
  `prefix :: String.t()` argument and derives `tenant_id` from it via
  `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`. No function in
  this module accepts a separately-trusted, caller-supplied `tenant_id`.

  ## `create_definition/2` reuses `Letflow.Repository.create/2` unmodified
  (design §3.3, §4)

  No independent canonicalisation, hashing, or dedup logic lives in this
  module -- REQ-202's `create/2` pipeline is called, not reimplemented, per
  REQ-226's own text. A known, accepted cost of this reuse (design §6 OQ-1):
  a same-name/same-shape resubmission mints a redundant `artifact_versions`
  row before being rejected at the `entity_definitions` layer by the
  `(tenant_id, name, logical_shape_version)` UNIQUE constraint (design §4
  Scenario B).

  ## Activation reuses REQ-203's existing machinery -- no new mechanism
  (design §3.4)

  `activate_definition/4` calls `Letflow.Repository.Activation.activate_group/5`
  unchanged with `artifact_kind: :entity`, then -- only on that call's own
  success -- updates the matching `entity_definitions` row's `status` to
  `:active` via a plain `Ecto.Changeset`/`Repo.update`, not itself wrapped in
  `activate_group/5`'s transaction. No new activation table, pointer, or
  history mechanism is added by this requirement.
  """

  import Ecto.Query

  alias Letflow.Entities.Definition
  alias Letflow.Entities.Definition.Shape
  alias Letflow.Entities.Definition.Validator
  alias Letflow.Entities.EntityDefinition
  alias Letflow.Api.Pagination
  alias Letflow.Repo
  alias Letflow.Repository
  alias Letflow.Repository.Activation
  alias Letflow.TenantProvisioning

  @list_definitions_cursor_prefix "ED:"

  @type create_attrs :: %{
          required(:definition) => Definition.t(),
          required(:created_by) => Ecto.UUID.t()
        }

  @type create_error ::
          {:error, {:validation, [Validator.violation()]}}
          | {:error, {:repository, term()}}
          | {:error, {:persistence, Ecto.Changeset.t()}}
          | {:error, :invalid_schema_name}

  @typedoc "REQ-067's opts shape for `list_definitions/2` -- see design §3.3."
  @type list_definitions_filters :: %{
          optional(:cursor) => String.t() | nil,
          optional(:page_size) => pos_integer() | nil
        }

  @doc """
  Creates a new `entity_definitions` row (design §3.3), scoped to the tenant
  schema named by `prefix`. Steps, in this exact order:

    1. `Letflow.Entities.Definition.Validator.validate/1` -- on
       `{:error, violations}`, returns `{:error, {:validation, violations}}`
       immediately. No `Letflow.Repository.create/2` call, no
       `entity_definitions` insert attempt, no DB write of any kind happens
       on this branch.
    2. On `:ok`, computes `content_hash`/`logical_shape_version` via
       `Letflow.Entities.Definition.Shape`.
    3. Calls `Letflow.Repository.create/2` with `artifact_kind: :entity` --
       REQ-202's existing canonicalise-hash-dedup-version pipeline, not
       reimplemented. A `{:error, reason}` here is returned as
       `{:error, {:repository, reason}}` immediately -- no `entity_definitions`
       row is written on this branch either.
    4. On success, inserts one `entity_definitions` row referencing the
       returned `artifact_version_id`, `status: :inactive`. A UNIQUE-constraint
       failure here is returned as `{:error, {:persistence, changeset}}` --
       at this point step 3 has already run and may have written or reused a
       `repository_artifacts`/`artifact_versions` row (design §4's Scenario
       B, an accepted cost of reusing `create/2` unmodified).
    5. On success, returns `{:ok, %Letflow.Entities.EntityDefinition{}}`.
  """
  @spec create_definition(create_attrs(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()} | create_error()
  def create_definition(%{definition: definition, created_by: created_by}, prefix)
      when is_binary(prefix) do
    case Validator.validate(definition) do
      {:error, violations} ->
        {:error, {:validation, violations}}

      :ok ->
        with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
          content_hash = Shape.content_hash(definition)
          logical_shape_version = Shape.logical_shape_of(definition)

          repository_attrs = %{
            artifact_kind: :entity,
            artifact_name: Map.fetch!(definition, :name),
            content_type: "application/json",
            content: Jason.encode!(definition),
            created_by: created_by
          }

          case Repository.create(repository_attrs, prefix) do
            {:error, reason} ->
              {:error, {:repository, reason}}

            {:ok, %Repository.ArtifactVersion{version_id: artifact_version_id}} ->
              insert_entity_definition(
                tenant_id,
                definition,
                content_hash,
                logical_shape_version,
                artifact_version_id,
                prefix
              )
          end
        end
    end
  end

  defp insert_entity_definition(
         tenant_id,
         definition,
         content_hash,
         logical_shape_version,
         artifact_version_id,
         prefix
       ) do
    attrs = %{
      tenant_id: tenant_id,
      name: Map.fetch!(definition, :name),
      display_name: Map.fetch!(definition, :display_name),
      definition_json: definition,
      content_hash: content_hash,
      logical_shape_version: logical_shape_version,
      artifact_version_id: artifact_version_id,
      status: :inactive
    }

    %EntityDefinition{}
    |> EntityDefinition.changeset(attrs)
    |> Repo.insert(prefix: prefix)
    |> case do
      {:ok, entity_definition} -> {:ok, entity_definition}
      {:error, changeset} -> {:error, {:persistence, changeset}}
    end
  end

  @doc """
  Fetches one `entity_definitions` row by `id`, scoped to the tenant schema
  named by `prefix` (design §3.3). Never raises `Ecto.NoResultsError` --
  `nil` becomes `{:error, :not_found}`, matching this codebase's established
  tagged-tuple-for-a-caller-triggerable-not-found convention
  (`Letflow.Repository.Activation.resolve/3`'s own `{:error, :not_found}`-shaped
  return, adapted, is the direct precedent).
  """
  @spec get_definition(id :: Ecto.UUID.t(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_schema_name}
  def get_definition(id, prefix) when is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      case Repo.get(EntityDefinition, id, prefix: prefix) do
        nil -> {:error, :not_found}
        %EntityDefinition{} = entity_definition -> {:ok, entity_definition}
      end
    end
  end

  @doc """
  Fetches one `entity_definitions` row by `name`, scoped to the tenant
  schema named by `prefix` (design §3.3). Same not-found semantics as
  `get_definition/2`.
  """
  @spec get_definition_by_name(name :: String.t(), prefix :: String.t()) ::
          {:ok, EntityDefinition.t()}
          | {:error, :not_found}
          | {:error, :invalid_schema_name}
  def get_definition_by_name(name, prefix) when is_binary(name) and is_binary(prefix) do
    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query = from(e in EntityDefinition, where: e.name == ^name)

      case Repo.one(query, prefix: prefix) do
        nil -> {:error, :not_found}
        %EntityDefinition{} = entity_definition -> {:ok, entity_definition}
      end
    end
  end

  @doc """
  Ordered, paginated listing of `entity_definitions` rows (design §3.3,
  REQ-067's cursor contract), scoped to the tenant schema named by `prefix`.
  Newest first (`inserted_at desc, id desc`).

  Tenant scoping (AC5) is structural here exactly the way
  `Letflow.Repository.list_versions/4`'s moduledoc states it: because
  `entity_definitions` lives in a per-tenant Postgres schema, a query scoped
  to `prefix` cannot return another tenant's rows regardless of what a
  cursor decodes to -- the `tenant_id` WHERE clause below is the same
  belt-and-suspenders discipline every Decision-B table carries, not the
  sole isolation mechanism.
  """
  @spec list_definitions(list_definitions_filters(), prefix :: String.t()) ::
          {:ok, Pagination.Page.t(EntityDefinition.t())}
          | {:error, :invalid_schema_name}
          | {:error, :page_size_too_large}
          | {:error, :wrong_endpoint}
          | {:error, :expired}
          | {:error, :invalid_cursor}
  def list_definitions(filters, prefix) when is_map(filters) and is_binary(prefix) do
    with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, page_size} <- Pagination.validate_page_size(Map.get(filters, :page_size)),
         {:ok, cursor_seek} <- decode_list_definitions_cursor(Map.get(filters, :cursor)) do
      rows =
        EntityDefinition
        |> where([e], e.tenant_id == ^tenant_id)
        |> filter_by_list_definitions_cursor(cursor_seek)
        |> order_by([e], desc: e.inserted_at, desc: e.id)
        |> limit(^(page_size + 1))
        |> Repo.all(prefix: prefix)

      {page, next_cursor} = split_list_definitions_page(rows, page_size)

      {:ok, Pagination.page_response(page, next_cursor)}
    end
  end

  defp filter_by_list_definitions_cursor(query, nil), do: query

  defp filter_by_list_definitions_cursor(query, {inserted_at, id}) do
    from(e in query, where: {e.inserted_at, e.id} < {^inserted_at, ^id})
  end

  defp decode_list_definitions_cursor(nil), do: {:ok, nil}

  defp decode_list_definitions_cursor(raw) when is_binary(raw) do
    case Pagination.decode_cursor(
           raw,
           @list_definitions_cursor_prefix,
           byte_size(@list_definitions_cursor_prefix)
         ) do
      {:ok, %Pagination.Cursor{} = cursor} -> {:ok, decode_list_definitions_seek(cursor)}
      {:error, :wrong_endpoint} -> {:error, :wrong_endpoint}
      {:error, :expired} -> {:error, :expired}
      {:error, _invalid_base64_or_invalid_cursor} -> {:error, :invalid_cursor}
    end
  end

  # `inner` is `"ED:<mint_time_us>:<id>:<inserted_at_us>"` -- the first slot
  # after the prefix is always the mint-time timestamp decode_cursor/4's
  # expiry check reads, never a domain value (same idiom
  # `Letflow.Repository.Activation.list_history/4`'s cursor helpers use).
  defp decode_list_definitions_seek(%Pagination.Cursor{inner: inner}) do
    prefix_len = byte_size(@list_definitions_cursor_prefix)
    rest = binary_part(inner, prefix_len, byte_size(inner) - prefix_len)
    [_mint_time_us_str, id_str, inserted_at_us_str] = String.split(rest, ":", parts: 3)
    inserted_at = DateTime.from_unix!(String.to_integer(inserted_at_us_str), :microsecond)
    {inserted_at, id_str}
  end

  defp split_list_definitions_page(rows, page_size) when length(rows) > page_size do
    {page, [_extra_row]} = Enum.split(rows, page_size)
    {page, build_list_definitions_next_cursor(List.last(page))}
  end

  defp split_list_definitions_page(rows, _page_size), do: {rows, nil}

  defp build_list_definitions_next_cursor(%EntityDefinition{id: id, inserted_at: inserted_at}) do
    mint_time_us = System.system_time(:microsecond)
    inserted_at_us = DateTime.to_unix(inserted_at, :microsecond)

    @list_definitions_cursor_prefix
    |> Pagination.build_raw_cursor_timestamp_key(mint_time_us, id, inserted_at_us)
    |> Pagination.encode_cursor()
  end

  @doc """
  Activates `name`'s current `artifact_version_id` (design §3.4) -- a thin
  wrapper around `Letflow.Repository.Activation.activate_group/5`, unchanged,
  with `artifact_kind: :entity`. On that call's own success, updates the
  matching `entity_definitions` row's `status` to `:active`. Adds no new
  activation table, pointer, or history mechanism.
  """
  @spec activate_definition(
          name :: String.t(),
          activator_user_id :: Ecto.UUID.t(),
          rationale :: String.t(),
          prefix :: String.t()
        ) ::
          {:ok, EntityDefinition.t()}
          | {:error, :not_found}
          | {:error, :empty_group}
          | {:error, :duplicate_artifact_in_group}
          | {:error, :invalid_schema_name}
          | {:error, {:group, Ecto.Changeset.t()}}
          | {:error, {atom(), Ecto.Changeset.t()}}
  def activate_definition(name, activator_user_id, rationale, prefix)
      when is_binary(name) and is_binary(prefix) do
    with {:ok, entity_definition} <- get_definition_by_name(name, prefix),
         {:ok, _result} <-
           Activation.activate_group(
             [
               %{
                 artifact_kind: :entity,
                 artifact_name: name,
                 version_id: entity_definition.artifact_version_id
               }
             ],
             activator_user_id,
             rationale,
             prefix
           ) do
      entity_definition
      |> EntityDefinition.changeset(%{status: :active})
      |> Repo.update(prefix: prefix)
    end
  end
end
