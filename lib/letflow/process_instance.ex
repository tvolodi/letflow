defmodule Letflow.ProcessInstance do
  @moduledoc """
  One running instance of a workflow, represented as a single
  `:gen_statem` process.

  State graph:

      draft --submit--> submitted --approve--> approved (terminal)
        ^                   |
        |                 reject
        +----resubmit-------+ (rejected)

  Each instance is a supervised, isolated process. Killing one does not
  affect any other instance.

  Every successful transition is persisted to Postgres via
  `Letflow.Repo`. In a real system you'd likely decouple that write
  (cast to a logger process, publish to PubSub/Oban) rather than doing
  it synchronously inside the state machine's call path — it's left
  synchronous here on purpose, so every transition actually exercises
  the Ecto round-trip.
  """

  @behaviour :gen_statem

  alias Letflow.Events.TransitionEvent
  alias Letflow.Repo

  @type state :: :draft | :submitted | :approved | :rejected

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

  @spec submit(String.t()) :: :ok | {:error, term()}
  def submit(id), do: :gen_statem.call(via(id), :submit)

  @spec approve(String.t()) :: :ok | {:error, term()}
  def approve(id), do: :gen_statem.call(via(id), :approve)

  @spec reject(String.t()) :: :ok | {:error, term()}
  def reject(id), do: :gen_statem.call(via(id), :reject)

  @spec resubmit(String.t()) :: :ok | {:error, term()}
  def resubmit(id), do: :gen_statem.call(via(id), :resubmit)

  @spec get(String.t()) :: %{state: state(), history: [map()]}
  def get(id), do: :gen_statem.call(via(id), :get)

  defp via(id), do: {:via, Registry, {Letflow.Registry, id}}

  # :gen_statem callbacks

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init(id) do
    {:ok, :draft, %{id: id, history: []}}
  end

  @impl :gen_statem
  # draft --submit--> submitted
  def handle_event({:call, from}, :submit, :draft, data) do
    transition(from, :draft, :submitted, :submit, data)
  end

  # submitted --approve--> approved (terminal)
  def handle_event({:call, from}, :approve, :submitted, data) do
    transition(from, :submitted, :approved, :approve, data)
  end

  # submitted --reject--> rejected
  def handle_event({:call, from}, :reject, :submitted, data) do
    transition(from, :submitted, :rejected, :reject, data)
  end

  # rejected --resubmit--> draft
  def handle_event({:call, from}, :resubmit, :rejected, data) do
    transition(from, :rejected, :draft, :resubmit, data)
  end

  # state introspection, valid from any state
  def handle_event({:call, from}, :get, state, data) do
    {:keep_state_and_data, [{:reply, from, %{state: state, history: data.history}}]}
  end

  # anything else is not a legal transition from the current state
  def handle_event({:call, from}, action, state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:invalid_transition, action, state}}}]}
  end

  defp transition(from, from_state, to_state, action, data) do
    Repo.insert!(%TransitionEvent{
      instance_id: data.id,
      from_state: Atom.to_string(from_state),
      to_state: Atom.to_string(to_state),
      action: Atom.to_string(action)
    })

    entry = %{action: action, from: from_state, to: to_state, at: DateTime.utc_now()}
    new_data = %{data | history: [entry | data.history]}

    {:next_state, to_state, new_data, [{:reply, from, :ok}]}
  end
end
