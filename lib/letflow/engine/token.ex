defmodule Letflow.Engine.Token do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  A single token's position and identity inside a running process instance —
  ports `transition.zig`'s `Token` (EE-02, `lib/letflow/design/
  req044-transition-kernel.md` §3). Plain struct, not an `Ecto.Schema` — this
  module has zero `Ecto`/`Letflow.Repo` dependency (see
  `Letflow.Engine.Transition`'s purity contract).
  """

  @enforce_keys [:node_id, :token_id]
  defstruct [:node_id, :token_id, branch_id: nil, waiting_child_instance_id: nil]

  @type t :: %__MODULE__{
          node_id: String.t(),
          branch_id: String.t() | nil,
          token_id: String.t(),
          waiting_child_instance_id: String.t() | nil
        }
end
