defmodule Letflow.InstanceSupervisor do
  @moduledoc """
  Owns one `Letflow.ProcessInstance` per running workflow instance.
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
    DynamicSupervisor.start_child(__MODULE__, Letflow.ProcessInstance.child_spec(id))
  end
end
