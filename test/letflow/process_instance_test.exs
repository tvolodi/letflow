defmodule Letflow.ProcessInstanceTest do
  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Letflow.InstanceSupervisor
  alias Letflow.ProcessInstance

  defp start_instance! do
    id = Ecto.UUID.generate()
    {:ok, _pid} = InstanceSupervisor.start_instance(id)
    id
  end

  test "the happy path: draft -> submitted -> approved" do
    id = start_instance!()

    assert %{state: :draft} = ProcessInstance.get(id)
    assert :ok = ProcessInstance.submit(id)
    assert %{state: :submitted} = ProcessInstance.get(id)
    assert :ok = ProcessInstance.approve(id)
    assert %{state: :approved} = ProcessInstance.get(id)
  end

  test "reject then resubmit loops back to draft" do
    id = start_instance!()

    :ok = ProcessInstance.submit(id)
    :ok = ProcessInstance.reject(id)
    assert %{state: :rejected} = ProcessInstance.get(id)

    :ok = ProcessInstance.resubmit(id)
    assert %{state: :draft} = ProcessInstance.get(id)
  end

  test "an action illegal in the current state is rejected, not silently accepted" do
    id = start_instance!()

    # approve is not legal from :draft
    assert {:error, {:invalid_transition, :approve, :draft}} = ProcessInstance.approve(id)
    assert %{state: :draft} = ProcessInstance.get(id)
  end

  test "every successful transition is persisted to Postgres" do
    id = start_instance!()

    :ok = ProcessInstance.submit(id)
    :ok = ProcessInstance.approve(id)

    import Ecto.Query

    events =
      Letflow.Events.TransitionEvent
      |> where(instance_id: ^id)
      |> order_by(:inserted_at)
      |> Repo.all()

    assert Enum.map(events, & &1.action) == ["submit", "approve"]
  end

  # This is the part standing in for what Rust or OCaml's compiler would
  # catch for free: since nothing here is statically typed, we assert the
  # invariant directly — no sequence of actions can ever leave an instance
  # in something other than one of the four known states.
  property "no sequence of actions produces an invalid state" do
    check all actions <- list_of(action_generator(), max_length: 20) do
      id = start_instance!()

      Enum.each(actions, fn action ->
        apply(ProcessInstance, action, [id])
      end)

      assert %{state: state} = ProcessInstance.get(id)
      assert state in [:draft, :submitted, :approved, :rejected]
    end
  end

  defp action_generator do
    StreamData.member_of([:submit, :approve, :reject, :resubmit])
  end
end
