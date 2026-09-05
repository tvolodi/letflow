defmodule Letflow.Definitions.PromotionConflict do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Conflict preflight check for one or more `process_key`s about to be
  promoted into a target tenant. Ported from R-Co's
  `src/definition/promotion_conflict.zig` (PRM-02), per
  `lib/letflow/design/promotion_plan.md` §4 (the gate-approved design this
  module implements).

  Read-only — performs zero `Repo` insert/update/delete/update_all calls
  (INV-PRM-1). `reject_if_conflicts/4` never opens a
  `Repo.transaction/1` and never issues a locking read (INV-PRM-4) — the
  single `Repo.get_by/3` per `process_key` is a plain read, no `lock/2`, no
  `FOR UPDATE`.

  Does not append a `DEFINITION_PROMOTION_REJECTED` event on conflict — that
  event's schema/payload and the call site that would append it are
  deferred to whichever later requirement wires this preflight into a real
  event-store call site (design §9.6).

  ## `process_key`/`base_version` are index-aligned lists (design §4.2)

  The task's fixed 4-arity signature names `process_key`/`base_version` as
  singular, but PRM-02 requires supporting multiple `process_key` conflicts
  as a list. This module's resolution: both parameters are lists,
  index-aligned by position — the *i*-th `base_version` element is checked
  against the *i*-th `process_key` element. A caller checking a single
  `process_key` passes 1-element lists.
  """

  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Repo
  alias Letflow.TenantProvisioning

  @type conflict_detail :: %{
          process_key: String.t(),
          target_definition_id: Ecto.UUID.t(),
          target_active_version: String.t(),
          base_version: String.t()
        }

  @type conflict_error ::
          {:conflicts, [conflict_detail()]}
          | :mismatched_process_key_list
          | :invalid_tenant_id

  @doc """
  Checks each `{process_key, base_version}` pair (index-aligned, see
  moduledoc) against `target_tenant_id`'s current ACTIVE version. A
  conflict is `target_active_version > base_version` (via
  `version_greater?/2`); the target having zero rows for a `process_key` is
  never a conflict.

  `actor_id` is accepted per the given signature but is **not** gated on a
  permission check here — this function is a preflight re-check an
  already-permission-gated approve/apply flow calls internally, not a fresh
  entry point (design §4.2).

  Algorithm, in order:

    1. `length(process_key) != length(base_version)` ->
       `{:error, :mismatched_process_key_list}`.
    2. Resolve `target_tenant_id`'s schema prefix -> `{:error,
       :invalid_tenant_id}` on failure.
    3. For each pair, a plain `Repo.get_by/3` read of the target's ACTIVE
       row for that `process_key`. `nil` -> no conflict for this pair. A row
       exists -> compare its `version` against `base_version` via
       `version_greater?/2`.
    4. Empty conflict list -> `:ok`. Non-empty -> `{:error, {:conflicts,
       list}}`.
  """
  @spec reject_if_conflicts(
          actor_id :: Ecto.UUID.t(),
          target_tenant_id :: Ecto.UUID.t(),
          process_key :: [String.t()],
          base_version :: [String.t()]
        ) :: :ok | {:error, conflict_error()}
  def reject_if_conflicts(_actor_id, _target_tenant_id, process_key, base_version)
      when length(process_key) != length(base_version) do
    {:error, :mismatched_process_key_list}
  end

  def reject_if_conflicts(_actor_id, target_tenant_id, process_key, base_version) do
    case TenantProvisioning.schema_name_for_tenant(target_tenant_id) do
      {:error, :invalid_tenant_id} = error ->
        error

      {:ok, target_prefix} ->
        conflicts =
          [process_key, base_version]
          |> Enum.zip()
          |> Enum.flat_map(fn {key, base} -> conflict_for_pair(target_prefix, key, base) end)

        if conflicts == [] do
          :ok
        else
          {:error, {:conflicts, conflicts}}
        end
    end
  end

  @spec conflict_for_pair(String.t(), String.t(), String.t()) :: [conflict_detail()]
  defp conflict_for_pair(target_prefix, key, base) do
    case Repo.get_by(ProcessDefinition, [name: key, status: :active], prefix: target_prefix) do
      nil ->
        []

      %ProcessDefinition{id: id, version: target_version} ->
        if version_greater?(target_version, base) do
          [
            %{
              process_key: key,
              target_definition_id: id,
              target_active_version: target_version,
              base_version: base
            }
          ]
        else
          []
        end
    end
  end

  # `process_definitions.version` is free-form text with no numeric/semver
  # constraint (design §9.4). Attempts an integer comparison first; falls
  # back to Elixir's default (byte-wise lexicographic) `>` when either side
  # doesn't parse cleanly as an integer.
  @spec version_greater?(String.t(), String.t()) :: boolean()
  defp version_greater?(target_version, base_version) do
    with {target_int, ""} <- Integer.parse(target_version),
         {base_int, ""} <- Integer.parse(base_version) do
      target_int > base_int
    else
      _ -> target_version > base_version
    end
  end
end
