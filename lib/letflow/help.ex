defmodule Letflow.Help do
  # Docs-only comment: T-0133 CD pipeline test-fire commit (ai-dala-infra),
  # confirming the QA deploy key's forced command and GitHub Actions wiring
  # end-to-end. No functional change.
  @moduledoc """
  Context module for in-app help content, tenant-scoped via `opts[:prefix]`. Implements
  REQ-363's already-validated design (`lib/letflow/design/req363-help-content-data-model.md`)
  — schema/lifecycle decisions are that design's, not reinvented here.

  Matches this project's established per-domain-context pattern (`Letflow.Identity`,
  `Letflow.TenantProvisioning`): a top-level context module in `lib/letflow/`, backed by a
  schema file in a same-named subdirectory (`lib/letflow/help/help_content.ex`).

  ## Scope (REQ-364)

  `create_draft/2`, `update_draft/3`, `publish/2`, `reconfirm/2`, `get_by_screen/2`, and
  `get_by_process_definition_id/2` — exactly the five actions REQ-364's own acceptance
  criteria name (create/update/publish/reconfirm/read), plus `withdraw/2` (see below).
  **No HTTP route/controller wiring** — REQ-364's own explicit scope boundary states this
  requirement stops at a working, tested context module, callable from IEx/tests; a route
  is a deliberately deferred fast-follow (REQ-364's requirement text names this choice
  itself, not left ambiguous).

  ## `withdraw/2` — live → draft, per design §2's transition semantics

  Design §2 states explicitly that `live → draft` is a legal transition "for REQ-364's
  context module to implement" (pulling back a published entry for correction is ordinary,
  not exceptional) and that leaving it unbuilt would be exactly the kind of unstated
  assumption CODE-DESIGNER's own guidance warns against. REQ-364's acceptance criteria
  text does not separately name this function, so it is flagged here rather than silently
  added: `withdraw/2` exists so `update_draft/3`'s own `:draft`-only precondition is
  actually reachable for a row that has already been published once, without it a
  published row could never be edited again. Flagged for REVIEWER to confirm this is the
  intended reading rather than scope creep.

  ## `process_definition_id` referential check (design §1.1 row 3)

  Every write that sets a non-nil `process_definition_id` validates, in the same tenant
  schema, that the referenced `process_definitions.id` actually exists — no DB-level FK
  (design §1.1's stated no-FK convention), so this is an application-level check, run
  before any insert/update.

  ## `confirmed_at` / `confirmed_for_definition_version` (design §4)

  Set only by `publish/2` and `reconfirm/2`, never from caller-supplied attrs (rejected
  outright if present in `attrs` — see `reject_key/4`). `confirmed_at` is always
  `DateTime.utc_now/0` at the moment of the call, never a caller value.
  `confirmed_for_definition_version` is read directly off the referenced
  `Letflow.Definitions.ProcessDefinition.version` field at that same moment when
  `process_definition_id` is non-nil, `nil` otherwise — never caller-supplied.
  """

  import Ecto.Query

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Help.HelpContent
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type opts :: [prefix: String.t()]
  @type create_error ::
          {:error, :status_not_accepted}
          | {:error, :confirmed_at_not_accepted}
          | {:error, :confirmed_for_definition_version_not_accepted}
          | {:error, :process_definition_not_found}
          | {:error, :invalid_prefix}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Creates a new help content draft. `attrs` must not carry `:status`, `:confirmed_at`, or
  `:confirmed_for_definition_version` — every new row starts `:draft`/unconfirmed
  regardless of caller input.
  """
  @spec create_draft(attrs :: map(), opts :: opts()) ::
          {:ok, HelpContent.t()} | create_error()
  def create_draft(attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         :ok <- reject_key(attrs, :status, "status", :status_not_accepted),
         :ok <- reject_key(attrs, :confirmed_at, "confirmed_at", :confirmed_at_not_accepted),
         :ok <-
           reject_key(
             attrs,
             :confirmed_for_definition_version,
             "confirmed_for_definition_version",
             :confirmed_for_definition_version_not_accepted
           ),
         :ok <- validate_process_definition_ref(attrs, prefix) do
      %HelpContent{}
      |> HelpContent.create_changeset(attrs)
      |> Repo.insert(prefix: prefix)
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
      other -> other
    end
  end

  @doc """
  Updates an existing draft's mutable fields (`:screen_id`, `:process_definition_id`,
  `:title`, `:body`). `{:error, :not_a_draft}` if the row is currently `:live` — edit a
  live row by `withdraw/2`-ing it first, matching design §2's stated transition semantics.
  """
  @spec update_draft(id :: Ecto.UUID.t(), attrs :: map(), opts :: opts()) ::
          {:ok, HelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_a_draft}
          | {:error, :process_definition_not_found}
          | {:error, :invalid_prefix}
          | {:error, Ecto.Changeset.t()}
  def update_draft(id, attrs, opts) when is_map(attrs) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, row} <- fetch(id, prefix),
         :ok <- ensure_draft(row),
         :ok <- validate_process_definition_ref(attrs, prefix) do
      row
      |> HelpContent.update_changeset(attrs)
      |> Repo.update(prefix: prefix)
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
      other -> other
    end
  end

  @doc """
  Publishes a draft: `:draft -> :live`, setting `confirmed_at` from the real clock (never
  caller-supplied) and, for process-scoped help (`process_definition_id` non-nil),
  `confirmed_for_definition_version` from that process definition's actual current
  `version` field (design §4.2 — read directly, never caller-supplied).
  """
  @spec publish(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, HelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_a_draft}
          | {:error, :process_definition_not_found}
          | {:error, :invalid_prefix}
          | {:error, Ecto.Changeset.t()}
  def publish(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, row} <- fetch(id, prefix),
         :ok <- ensure_draft(row),
         {:ok, confirmed_version} <- resolve_confirmed_version(row, prefix) do
      row
      |> Ecto.Changeset.change(%{
        status: :live,
        confirmed_at: DateTime.utc_now(),
        confirmed_for_definition_version: confirmed_version
      })
      |> Repo.update(prefix: prefix)
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
      other -> other
    end
  end

  @doc """
  Re-confirms an already-`:live` row: bumps `confirmed_at` (real clock) and, for
  process-scoped help, refreshes `confirmed_for_definition_version` from the process
  definition's current `version` — `:title`/`:body` are never touched by this changeset,
  so the body is provably unchanged.
  """
  @spec reconfirm(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, HelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_live}
          | {:error, :process_definition_not_found}
          | {:error, :invalid_prefix}
          | {:error, Ecto.Changeset.t()}
  def reconfirm(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, row} <- fetch(id, prefix),
         :ok <- ensure_live(row),
         {:ok, confirmed_version} <- resolve_confirmed_version(row, prefix) do
      row
      |> Ecto.Changeset.change(%{
        confirmed_at: DateTime.utc_now(),
        confirmed_for_definition_version: confirmed_version
      })
      |> Repo.update(prefix: prefix)
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
      other -> other
    end
  end

  @doc """
  Withdraws an already-`:live` row back to `:draft`, per design §2's explicitly-stated
  legal `live -> draft` transition (see this module's moduledoc). Does not touch
  `:confirmed_at`/`:confirmed_for_definition_version` — those are re-set only by a
  subsequent `publish/2`.
  """
  @spec withdraw(id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, HelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_live}
          | {:error, :invalid_prefix}
          | {:error, Ecto.Changeset.t()}
  def withdraw(id, opts) when is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix),
         {:ok, row} <- fetch(id, prefix),
         :ok <- ensure_live(row) do
      row
      |> Ecto.Changeset.change(%{status: :draft})
      |> Repo.update(prefix: prefix)
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
      other -> other
    end
  end

  @doc """
  Lists help content attached to `screen_id`, within the tenant schema named by
  `opts[:prefix]`.
  """
  @spec get_by_screen(screen_id :: String.t(), opts :: opts()) ::
          {:ok, [HelpContent.t()]} | {:error, :invalid_prefix}
  def get_by_screen(screen_id, opts) when is_binary(screen_id) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query = from(h in HelpContent, where: h.screen_id == ^screen_id)
      {:ok, Repo.all(query, prefix: prefix)}
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
    end
  end

  @doc """
  Lists help content scoped to `process_definition_id`, within the tenant schema named by
  `opts[:prefix]`.
  """
  @spec get_by_process_definition_id(process_definition_id :: Ecto.UUID.t(), opts :: opts()) ::
          {:ok, [HelpContent.t()]} | {:error, :invalid_prefix}
  def get_by_process_definition_id(process_definition_id, opts)
      when is_binary(process_definition_id) and is_list(opts) do
    prefix = Keyword.fetch!(opts, :prefix)

    with {:ok, _tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
      query = from(h in HelpContent, where: h.process_definition_id == ^process_definition_id)
      {:ok, Repo.all(query, prefix: prefix)}
    else
      {:error, :invalid_schema_name} -> {:error, :invalid_prefix}
    end
  end

  defp fetch(id, prefix) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(HelpContent, uuid, prefix: prefix) do
          nil -> {:error, :not_found}
          %HelpContent{} = row -> {:ok, row}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp ensure_draft(%HelpContent{status: :draft}), do: :ok
  defp ensure_draft(%HelpContent{status: :live}), do: {:error, :not_a_draft}

  defp ensure_live(%HelpContent{status: :live}), do: :ok
  defp ensure_live(%HelpContent{status: :draft}), do: {:error, :not_live}

  defp resolve_confirmed_version(%HelpContent{process_definition_id: nil}, _prefix) do
    {:ok, nil}
  end

  defp resolve_confirmed_version(
         %HelpContent{process_definition_id: process_definition_id},
         prefix
       ) do
    case Repo.get(ProcessDefinition, process_definition_id, prefix: prefix) do
      nil -> {:error, :process_definition_not_found}
      %ProcessDefinition{version: version} -> {:ok, version}
    end
  end

  defp validate_process_definition_ref(attrs, prefix) do
    case fetch_process_definition_id(attrs) do
      nil ->
        :ok

      process_definition_id ->
        case Ecto.UUID.cast(process_definition_id) do
          {:ok, uuid} ->
            case Repo.get(ProcessDefinition, uuid, prefix: prefix) do
              nil -> {:error, :process_definition_not_found}
              %ProcessDefinition{} -> :ok
            end

          :error ->
            {:error, :process_definition_not_found}
        end
    end
  end

  defp fetch_process_definition_id(attrs) do
    case Map.get(attrs, :process_definition_id) || Map.get(attrs, "process_definition_id") do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp reject_key(attrs, atom_key, string_key, error) do
    if Map.has_key?(attrs, atom_key) or Map.has_key?(attrs, string_key) do
      {:error, error}
    else
      :ok
    end
  end
end
