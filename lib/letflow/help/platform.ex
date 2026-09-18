defmodule Letflow.Help.Platform do
  @moduledoc """
  Context module for platform-scope (not tenant-owned) in-app help content. Implements
  REQ-365's already-validated design
  (`lib/letflow/design/req365-platform-help-authoring.md`) — schema/lifecycle
  decisions are that design's, not reinvented here.

  Backed by `Letflow.Help.PlatformHelpContent`, itself backed by the
  `platform_help_content` table (`public`/default Postgres schema, no `prefix()`
  concept — design §1/§1.3).

  ## A separate module, not a platform-scoped variant of `Letflow.Help`'s functions
  ## (design §3.1)

  `Letflow.Help.Platform` mirrors `Letflow.Help`'s public surface (same function
  names, same conceptual shape, same error-atom vocabulary) with `opts :: [prefix:
  String.t()]` dropped from every signature, rather than folding a platform branch
  into `Letflow.Help` itself. There is no prefix/tenant concept for this table at
  all — accepting an `opts` parameter that is either ignored or required-but-
  meaningless would be worse than a signature that accurately reflects "this table is
  not tenant-scoped." See design §3.1 for the full reasoning (including why this
  mirrors req363 §3's `HelpContent`-vs-`PlatformHelpContent` schema split one level
  up, rather than a `scope` column on one shared schema/context). A future reader
  should not "simplify" these two modules back into one without re-deriving why they
  were split.

  ## `process_definition_id` — always rejected today (design §3.3)

  req363 left OQ-2 ("does a platform-scope process definition concept exist at all?")
  open, and this module does not resolve it either. `create_draft/1` and
  `update_draft/2` both reject any `attrs` map carrying a non-nil
  `:process_definition_id`/`"process_definition_id"` key with
  `{:error, :process_definition_id_not_supported}`, checked before any other
  validation — there is no single tenant schema a platform-level row could validate
  such a reference against. `publish/1`/`reconfirm/1` therefore always resolve
  `confirmed_for_definition_version` to `nil` unconditionally; there is no
  `resolve_confirmed_version/2`-shaped branch here, unlike `Letflow.Help`.

  ## `created_by` for agent-authored platform content (design §3.4)

  Platform-scope content is explicitly not authored through any UI — there is no
  signed-in human user backing a platform-content write. This module's callers
  (REQ-ANALYST/the agent pipeline) are expected to pass `@agent_pipeline_author_id`
  (the well-known nil-UUID, `"00000000-0000-0000-0000-000000000000"`) as
  `:created_by` for agent-authored rows — the one documented, greppable sentinel for
  "this row was authored by the agent pipeline, not attributable to an individual
  signed-in user," rather than each call site inventing its own placeholder. Flagged
  for REVIEWER to confirm this is the intended convention (design §3.4) — a new one,
  with no prior precedent in this codebase.
  """

  alias Letflow.Help.PlatformHelpContent
  alias Letflow.Repo

  @agent_pipeline_author_id "00000000-0000-0000-0000-000000000000"

  @type create_error ::
          {:error, :status_not_accepted}
          | {:error, :confirmed_at_not_accepted}
          | {:error, :confirmed_for_definition_version_not_accepted}
          | {:error, :process_definition_id_not_supported}
          | {:error, Ecto.Changeset.t()}

  @doc """
  The documented sentinel `created_by` value for agent-pipeline-authored platform
  content (design §3.4) — no signed-in human user backs a platform-content write.
  """
  @spec agent_pipeline_author_id() :: String.t()
  def agent_pipeline_author_id, do: @agent_pipeline_author_id

  @doc """
  Creates a new platform-scope help content draft. Same reject-caller-supplied-
  status/confirmed_at/confirmed_for_definition_version rule as
  `Letflow.Help.create_draft/2`. See moduledoc for `:process_definition_id_not_supported`.
  """
  @spec create_draft(attrs :: map()) :: {:ok, PlatformHelpContent.t()} | create_error()
  def create_draft(attrs) when is_map(attrs) do
    with :ok <- reject_key(attrs, :status, "status", :status_not_accepted),
         :ok <-
           reject_key(attrs, :confirmed_at, "confirmed_at", :confirmed_at_not_accepted),
         :ok <-
           reject_key(
             attrs,
             :confirmed_for_definition_version,
             "confirmed_for_definition_version",
             :confirmed_for_definition_version_not_accepted
           ),
         :ok <- reject_process_definition_id(attrs) do
      %PlatformHelpContent{}
      |> PlatformHelpContent.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates an existing platform draft's mutable fields (`:screen_id`, `:title`,
  `:body` — NOT `:process_definition_id`, see moduledoc). `{:error, :not_a_draft}` if
  currently `:live`.
  """
  @spec update_draft(id :: Ecto.UUID.t(), attrs :: map()) ::
          {:ok, PlatformHelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_a_draft}
          | {:error, :process_definition_id_not_supported}
          | {:error, Ecto.Changeset.t()}
  def update_draft(id, attrs) when is_map(attrs) do
    with {:ok, row} <- fetch(id),
         :ok <- ensure_draft(row),
         :ok <- reject_process_definition_id(attrs) do
      row
      |> PlatformHelpContent.update_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Publishes a draft: `:draft -> :live`, `confirmed_at` from the real clock.
  `confirmed_for_definition_version` is always set to `nil` (see moduledoc — no
  `process_definition_id` is ever set on a platform row today, so there is nothing
  to resolve a version against).
  """
  @spec publish(id :: Ecto.UUID.t()) ::
          {:ok, PlatformHelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_a_draft}
          | {:error, Ecto.Changeset.t()}
  def publish(id) do
    with {:ok, row} <- fetch(id),
         :ok <- ensure_draft(row) do
      row
      |> Ecto.Changeset.change(%{
        status: :live,
        confirmed_at: DateTime.utc_now(),
        confirmed_for_definition_version: nil
      })
      |> Repo.update()
    end
  end

  @doc """
  Re-confirms an already-`:live` row: bumps `confirmed_at` (real clock). `:title`/
  `:body` untouched, same contract as `Letflow.Help.reconfirm/2`.
  """
  @spec reconfirm(id :: Ecto.UUID.t()) ::
          {:ok, PlatformHelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_live}
          | {:error, Ecto.Changeset.t()}
  def reconfirm(id) do
    with {:ok, row} <- fetch(id),
         :ok <- ensure_live(row) do
      row
      |> Ecto.Changeset.change(%{
        confirmed_at: DateTime.utc_now(),
        confirmed_for_definition_version: nil
      })
      |> Repo.update()
    end
  end

  @doc """
  Withdraws an already-`:live` row back to `:draft`. Same live->draft legality as
  design req363 §2 / `Letflow.Help.withdraw/2`.
  """
  @spec withdraw(id :: Ecto.UUID.t()) ::
          {:ok, PlatformHelpContent.t()}
          | {:error, :not_found}
          | {:error, :not_live}
          | {:error, Ecto.Changeset.t()}
  def withdraw(id) do
    with {:ok, row} <- fetch(id),
         :ok <- ensure_live(row) do
      row
      |> Ecto.Changeset.change(%{status: :draft})
      |> Repo.update()
    end
  end

  @doc """
  Lists platform help content attached to `screen_id`. No `opts`/`prefix` parameter
  — this table has exactly one copy.
  """
  @spec get_by_screen(screen_id :: String.t()) :: {:ok, [PlatformHelpContent.t()]}
  def get_by_screen(screen_id) when is_binary(screen_id) do
    import Ecto.Query

    query = from(h in PlatformHelpContent, where: h.screen_id == ^screen_id)
    {:ok, Repo.all(query)}
  end

  defp fetch(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(PlatformHelpContent, uuid) do
          nil -> {:error, :not_found}
          %PlatformHelpContent{} = row -> {:ok, row}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp ensure_draft(%PlatformHelpContent{status: :draft}), do: :ok
  defp ensure_draft(%PlatformHelpContent{status: :live}), do: {:error, :not_a_draft}

  defp ensure_live(%PlatformHelpContent{status: :live}), do: :ok
  defp ensure_live(%PlatformHelpContent{status: :draft}), do: {:error, :not_live}

  defp reject_process_definition_id(attrs) do
    value = Map.get(attrs, :process_definition_id) || Map.get(attrs, "process_definition_id")

    if value in [nil, ""] do
      :ok
    else
      {:error, :process_definition_id_not_supported}
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
