defmodule Letflow.Engine.JoinCounter do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Tracks one outstanding PARALLEL_GATEWAY split/join cohort — ports
  `transition.zig`'s `JoinCounter` (EE-07, `lib/letflow/design/
  req051-parallel-gateway-split-join.md` §2, "added by R-Co's ISS-105") as a
  **set-based**, not count-based, representation: `expected_from_branches`/
  `received_from_branches` are `MapSet.t(String.t())` of `branch_id`s, not
  bare integers. This is a deliberate divergence from the literal
  `received_count` field name (design doc §2): EE-07 AC2/AC3's
  cancelled-branch-exclusion rule requires knowing **which** specific
  branches are still outstanding, not merely how many have arrived.
  `cancelled_branches` is this requirement's own addition beyond
  `transition.zig`'s two named fields — the concrete cancelled-branch
  representation REQ-051 itself defines (not deferred to REQ-052).

  Plain struct, not an `Ecto.Schema` — zero `Ecto`/`Letflow.Repo` dependency
  (see `Letflow.Engine.Transition`'s purity contract).
  """

  @enforce_keys [:join_node_id, :origin_token_id, :expected_from_branches]
  defstruct [
    :join_node_id,
    :origin_token_id,
    expected_from_branches: MapSet.new(),
    received_from_branches: MapSet.new(),
    cancelled_branches: MapSet.new()
  ]

  @type t :: %__MODULE__{
          join_node_id: String.t(),
          origin_token_id: String.t(),
          expected_from_branches: MapSet.t(String.t()),
          received_from_branches: MapSet.t(String.t()),
          cancelled_branches: MapSet.t(String.t())
        }
end
