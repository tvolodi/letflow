defmodule Letflow.ParallelApproval do
  @moduledoc """
  One running instance of a two-approver sign-off workflow, represented
  as a single `:gen_statem` process.

  Unlike `Letflow.ProcessInstance`'s linear chain, this workflow has two
  independent approvers (`:finance` and `:ops`) who can sign in either
  order. The combination in progress (neither/one/both signed) is
  tracked as data on a single `:pending` state, not as a separate atom
  per combination — `:finance` signing first and `:ops` signing first
  are the same state with different data, not different states.

  State graph:

      pending (0 or 1 of [:finance, :ops] signed) --approve(both)--> approved (terminal)

  Each instance is a supervised, isolated process, owned by
  `Letflow.ApprovalSupervisor` — a separate `DynamicSupervisor` from
  `Letflow.InstanceSupervisor`, since this is a structurally different
  workflow, not a variant of `Letflow.ProcessInstance`.
  """

  @behaviour :gen_statem

  @type approver :: :finance | :ops
  @type state :: :pending | :approved

  @approvers [:finance, :ops]

  @spec approvers() :: [approver()]
  def approvers, do: @approvers

  # Client API

  def start_link(id) do
    :gen_statem.start_link(via(id), __MODULE__, id, [])
  end

  def child_spec(id) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [id]},
      restart: :transient
    }
  end

  @spec approve(String.t(), approver()) :: :ok | {:error, term()}
  def approve(id, approver), do: :gen_statem.call(via(id), {:approve, approver})

  @spec get(String.t()) :: %{state: state(), approved_by: [approver()]}
  def get(id), do: :gen_statem.call(via(id), :get)

  defp via(id), do: {:via, Registry, {Letflow.Registry, {:approval, id}}}

  # :gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(id) do
    {:ok, :pending, %{id: id, approved_by: MapSet.new()}}
  end

  @impl :gen_statem
  # unsupervised approver atom: rejected in any state, does not touch data
  def handle_event({:call, from}, {:approve, approver}, _state, _data)
      when approver not in @approvers do
    {:keep_state_and_data, [{:reply, from, {:error, {:unknown_approver, approver}}}]}
  end

  # already-approved instance: further approvals are a no-op, not an error
  def handle_event({:call, from}, {:approve, approver}, :approved, _data)
      when approver in @approvers do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  # pending + a known approver signing (idempotent even if already signed)
  def handle_event({:call, from}, {:approve, approver}, :pending, data)
      when approver in @approvers do
    new_approved_by = MapSet.put(data.approved_by, approver)
    new_data = %{data | approved_by: new_approved_by}

    if MapSet.size(new_approved_by) == length(@approvers) do
      {:next_state, :approved, new_data, [{:reply, from, :ok}]}
    else
      {:keep_state, new_data, [{:reply, from, :ok}]}
    end
  end

  # state introspection, valid from any state
  def handle_event({:call, from}, :get, state, data) do
    reply = %{state: state, approved_by: MapSet.to_list(data.approved_by)}
    {:keep_state_and_data, [{:reply, from, reply}]}
  end
end
