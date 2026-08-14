defmodule Letflow.ApprovalSupervisor do
  @moduledoc """
  Owns one `Letflow.ParallelApproval` per running approval instance.

  Kept separate from `Letflow.InstanceSupervisor` on purpose: this is a
  structurally different workflow (parallel sign-off, not a linear
  chain), not a variant of `Letflow.ProcessInstance`, so it gets its own
  supervisor entry rather than being folded in.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_instance(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_instance(id) do
    DynamicSupervisor.start_child(__MODULE__, Letflow.ParallelApproval.child_spec(id))
  end
end
