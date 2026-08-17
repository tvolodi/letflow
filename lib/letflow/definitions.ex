defmodule Letflow.Definitions do
  @moduledoc """
  Context module for definition-related read/compute functions. See
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3 for
  `compute_pack_update_plan/5`'s full reasoning.

  **This file did not exist before REQ-041.** The design (§5.3) names
  `Letflow.Definitions` as "the existing context module this batch's
  functions all attach to," citing `req035` §5.1 as having already
  established it as the expected home for `compute_pack_update_plan/5` by
  name — but no `lib/letflow/definitions.ex` context-module file was actually
  present in this codebase prior to this requirement (only schema submodules
  under `lib/letflow/definitions/`, e.g. `ProcessDefinition`,
  `PromotionReview`). REQ-036, whose `compute_promotion_plan/5` would have
  been this module's first function, is still `status: pending`
  (`docs/requirements.yaml`). REQ-041 creates this file; noted here as a
  deviation-from-assumption worth flagging honestly, not a silent one — the
  module name, namespace and this function's placement all match the design
  exactly, only the file's prior existence was assumed incorrectly.

  ## Scope — REQ-041 only

  `compute_pack_update_plan/5` and `classify_artefact/3` are this module's
  only functions today. Both are read-only / pure — see each function's own
  `@doc` for its scope boundary.
  """

  alias Letflow.Definitions.PackUpdateResolution
  alias Letflow.Definitions.SolutionPackArtefactBase
  alias Letflow.Repo

  @type artefact_key :: %{artefact_type: String.t(), artefact_id: String.t()}
  @type artefact_input :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          # canonical-JSON text, caller's responsibility -- see
          # classify_artefact/3's @doc and design §5.4/OQ-1.
          content: String.t()
        }
  @type classification :: :unchanged | :clean_update | :local_only | :conflict

  @type plan_entry :: %{
          artefact_type: String.t(),
          artefact_id: String.t(),
          classification: classification(),
          # nil iff no solution_pack_artefact_bases row -- AC2.
          base: String.t() | nil,
          # nil iff artefact absent from theirs_artefacts.
          theirs: String.t() | nil,
          # nil iff artefact absent from incoming_artefacts.
          incoming: String.t() | nil,
          # only meaningful when classification == :conflict; true iff a
          # matching pack_update_resolutions row exists (AC4) -- always false
          # for non-conflict entries.
          resolved: boolean()
        }

  @type plan :: %{
          tenant_id: Ecto.UUID.t(),
          pack_id: String.t(),
          incoming_version: String.t(),
          entries: [plan_entry()],
          has_unresolved_conflicts: boolean()
        }

  @doc """
  Computes a solution-pack update three-way diff plan for one tenant's
  install of one pack against an offered incoming version, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3.

  Read-only — performs no mutation (INV-PU-5). Queries
  `solution_pack_artefact_bases` (the `base` lookup, by `(tenant_id, pack_id,
  artefact_type, artefact_id)`) and `pack_update_resolutions` (the
  `has_unresolved_conflicts` lookup, by `(tenant_id, pack_id, target_version:
  incoming_version, artefact_type, artefact_id)`) but writes neither those nor
  `solution_pack_installs`.

  `theirs_artefacts`/`incoming_artefacts` are caller-supplied — no real
  install/export path exists yet to source them from (SOL-01/02/03, unscoped).
  `base` is never caller-supplied: it is always looked up from
  `solution_pack_artefact_bases` by this function itself, because AC2's core
  assertion (an artefact with no matching base row classifies `:conflict`) is
  a statement about this function's own DB-lookup behavior, not about a value
  a caller chooses to omit.

  The artefact set processed is the union of `theirs_artefacts`' and
  `incoming_artefacts`' `{artefact_type, artefact_id}` keys, in first-seen
  order (theirs first, then incoming) — an artefact named in neither list is
  not represented in the returned plan at all.

  Returns `{:error, :empty_artefact_set}` when both `theirs_artefacts` and
  `incoming_artefacts` are `[]` — an empty result would otherwise be
  ambiguous between "nothing changed" and "caller passed no data by
  mistake" (mirrors REQ-036's `compute_promotion_plan/5`'s empty-plan error;
  design §5.3, flagged there as this design's own addition, not a literal
  REQ-041 acceptance-criterion mandate).
  """
  @spec compute_pack_update_plan(
          tenant_id :: Ecto.UUID.t(),
          pack_id :: String.t(),
          incoming_version :: String.t(),
          theirs_artefacts :: [artefact_input()],
          incoming_artefacts :: [artefact_input()]
        ) :: {:ok, plan()} | {:error, :empty_artefact_set}
  def compute_pack_update_plan(_tenant_id, _pack_id, _incoming_version, [], []) do
    {:error, :empty_artefact_set}
  end

  def compute_pack_update_plan(
        tenant_id,
        pack_id,
        incoming_version,
        theirs_artefacts,
        incoming_artefacts
      ) do
    theirs_by_key = index_by_key(theirs_artefacts)
    incoming_by_key = index_by_key(incoming_artefacts)

    keys =
      (theirs_artefacts ++ incoming_artefacts)
      |> Enum.map(&{&1.artefact_type, &1.artefact_id})
      |> Enum.uniq()

    entries =
      Enum.map(keys, fn {artefact_type, artefact_id} = key ->
        base = fetch_base(tenant_id, pack_id, artefact_type, artefact_id)
        theirs = Map.get(theirs_by_key, key)
        incoming = Map.get(incoming_by_key, key)
        classification = classify_artefact(base, theirs, incoming)

        resolved =
          classification == :conflict and
            resolution_exists?(tenant_id, pack_id, incoming_version, artefact_type, artefact_id)

        %{
          artefact_type: artefact_type,
          artefact_id: artefact_id,
          classification: classification,
          base: base,
          theirs: theirs,
          incoming: incoming,
          resolved: resolved
        }
      end)

    has_unresolved_conflicts =
      Enum.any?(entries, &(&1.classification == :conflict and not &1.resolved))

    {:ok,
     %{
       tenant_id: tenant_id,
       pack_id: pack_id,
       incoming_version: incoming_version,
       entries: entries,
       has_unresolved_conflicts: has_unresolved_conflicts
     }}
  end

  @doc """
  Classifies one artefact's three-way diff, per
  `lib/letflow/design/req041-pack-update-diff-schema.md` §5.3's truth table.
  Pure — no I/O, independently testable without DB fixtures or the full
  5-argument `compute_pack_update_plan/5` orchestration.

  `base`/`theirs`/`incoming` are compared by **byte-level string equality**
  over content that MUST already be canonical-JSON text by the time it
  reaches this function (sorted keys, no insignificant whitespace) —
  REQ-041's own description says this comparison uses "same normalization as
  REQ-036's plan digest," but REQ-036's `compute_plan_digest/1` is
  `status: pending` and has no shared canonicalization helper to call yet
  (design §5.4, OQ-1). This function does not parse, re-serialize, or
  normalize anything itself, and does not reimplement REQ-036's
  canonicalization as a private duplicate — that would risk drifting from
  REQ-036's real implementation once it ships.

  `nil` is never treated as equal to any other value, including another
  `nil` compared against a third non-nil value. A `nil` `base` (no matching
  `solution_pack_artefact_bases` row) always classifies `:conflict`,
  regardless of `theirs`/`incoming` — REQ-041 acceptance criterion 2 /
  INV-PU-2, "cannot prove no modification" (PRM-09 AC5).

  | `base` | `base == theirs` | `base == incoming` | Result |
  |---|---|---|---|
  | non-nil | true | true | `:unchanged` |
  | non-nil | true | false | `:clean_update` |
  | non-nil | false | true | `:local_only` |
  | non-nil | false | false | `:conflict` |
  | `nil` | — | — | `:conflict` (always) |
  """
  @spec classify_artefact(
          base :: String.t() | nil,
          theirs :: String.t() | nil,
          incoming :: String.t() | nil
        ) :: classification()
  def classify_artefact(nil, _theirs, _incoming), do: :conflict
  def classify_artefact(base, base, base), do: :unchanged
  def classify_artefact(base, base, _incoming), do: :clean_update
  def classify_artefact(base, _theirs, base), do: :local_only
  def classify_artefact(_base, _theirs, _incoming), do: :conflict

  defp index_by_key(artefacts) do
    Map.new(artefacts, fn %{artefact_type: type, artefact_id: id, content: content} ->
      {{type, id}, content}
    end)
  end

  defp fetch_base(tenant_id, pack_id, artefact_type, artefact_id) do
    SolutionPackArtefactBase
    |> Repo.get_by(
      tenant_id: tenant_id,
      pack_id: pack_id,
      artefact_type: artefact_type,
      artefact_id: artefact_id
    )
    |> case do
      nil -> nil
      %SolutionPackArtefactBase{base_content: base_content} -> base_content
    end
  end

  defp resolution_exists?(tenant_id, pack_id, target_version, artefact_type, artefact_id) do
    not is_nil(
      Repo.get_by(PackUpdateResolution,
        tenant_id: tenant_id,
        pack_id: pack_id,
        target_version: target_version,
        artefact_type: artefact_type,
        artefact_id: artefact_id
      )
    )
  end
end
