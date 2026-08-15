defmodule Letflow.ParallelApprovalTest do
  use Letflow.DataCase, async: false
  use ExUnitProperties

  alias Letflow.ApprovalSupervisor
  alias Letflow.ParallelApproval

  defp start_instance! do
    id = Ecto.UUID.generate()
    {:ok, _pid} = ApprovalSupervisor.start_instance(id)
    id
  end

  test "finance then ops reaches :approved" do
    id = start_instance!()

    assert %{state: :pending} = ParallelApproval.get(id)
    assert :ok = ParallelApproval.approve(id, :finance)
    assert %{state: :pending, approved_by: [:finance]} = ParallelApproval.get(id)
    assert :ok = ParallelApproval.approve(id, :ops)
    assert %{state: :approved} = ParallelApproval.get(id)
  end

  test "ops then finance also reaches :approved (order-independent)" do
    id = start_instance!()

    assert :ok = ParallelApproval.approve(id, :ops)
    assert %{state: :pending, approved_by: [:ops]} = ParallelApproval.get(id)
    assert :ok = ParallelApproval.approve(id, :finance)
    assert %{state: :approved} = ParallelApproval.get(id)
  end

  test "approving the same approver twice is idempotent" do
    id = start_instance!()

    assert :ok = ParallelApproval.approve(id, :finance)
    assert :ok = ParallelApproval.approve(id, :finance)
    assert %{state: :pending, approved_by: [:finance]} = ParallelApproval.get(id)

    assert :ok = ParallelApproval.approve(id, :ops)
    assert %{state: :approved} = ParallelApproval.get(id)
  end

  test "get/1 reports which approvers have signed while :pending" do
    id = start_instance!()

    assert %{state: :pending, approved_by: []} = ParallelApproval.get(id)
    :ok = ParallelApproval.approve(id, :ops)
    assert %{state: :pending, approved_by: [:ops]} = ParallelApproval.get(id)
  end

  test "an unsupervised approver atom is rejected, not silently accepted" do
    id = start_instance!()

    assert {:error, {:unknown_approver, :legal}} = ParallelApproval.approve(id, :legal)
    assert %{state: :pending, approved_by: []} = ParallelApproval.get(id)
  end

  test "each instance is its own supervised process, isolated from siblings" do
    id_a = start_instance!()
    id_b = start_instance!()

    :ok = ParallelApproval.approve(id_a, :finance)

    assert %{approved_by: [:finance]} = ParallelApproval.get(id_a)
    assert %{approved_by: []} = ParallelApproval.get(id_b)

    children = DynamicSupervisor.which_children(ApprovalSupervisor)
    assert length(children) >= 2
  end

  test "killing one instance's process does not affect a sibling instance's state" do
    survivor_id = start_instance!()
    victim_id = start_instance!()

    # Give both instances real state to check for corruption/preservation,
    # not just freshly-initialized data.
    :ok = ParallelApproval.approve(survivor_id, :finance)
    :ok = ParallelApproval.approve(victim_id, :finance)
    :ok = ParallelApproval.approve(victim_id, :ops)

    assert %{state: :pending, approved_by: [:finance]} = ParallelApproval.get(survivor_id)
    assert %{state: :approved} = ParallelApproval.get(victim_id)

    victim_pid = victim_pid!(victim_id)
    victim_ref = Process.monitor(victim_pid)

    Process.exit(victim_pid, :kill)
    assert_receive {:DOWN, ^victim_ref, :process, ^victim_pid, :killed}

    # Sibling is completely unaffected: same pid, same state, still answers.
    assert %{state: :pending, approved_by: [:finance]} = ParallelApproval.get(survivor_id)
    assert Process.alive?(GenServer.whereis(via_tuple(survivor_id)))

    # `child_spec/1` sets `restart: :transient`. Per OTP semantics, :transient
    # restarts a child on ABNORMAL termination (any reason other than :normal,
    # :shutdown, or {:shutdown, term}) and does NOT restart it after a normal
    # exit. `Process.exit(pid, :kill)` delivers the un-trappable :kill reason,
    # which is reported to monitors as :killed (asserted above) — abnormal,
    # not :normal/:shutdown — so the DynamicSupervisor restarts this child
    # using the same stored child_spec (same `id` baked into its `start` MFA),
    # re-registering the same `via(id)` key under a brand-new pid.
    #
    # The restarted process is a fresh `init/1` run: its :gen_statem data was
    # only ever in the killed process's memory, never persisted, so the
    # instance comes back reachable at the same id but reset to :pending with
    # no approvals — the prior :approved progress is gone, not recovered.
    new_pid = wait_for_new_pid(victim_id, victim_pid)
    assert new_pid != victim_pid
    assert %{state: :pending, approved_by: []} = ParallelApproval.get(victim_id)
  end

  defp via_tuple(id), do: {:via, Registry, {Letflow.Registry, {:approval, id}}}

  defp victim_pid!(id) do
    case GenServer.whereis(via_tuple(id)) do
      pid when is_pid(pid) -> pid
      nil -> flunk("expected #{id} to already be registered with a live pid")
    end
  end

  # The DynamicSupervisor restarts the child asynchronously after the :DOWN
  # message we already awaited, so poll briefly rather than assuming the new
  # pid is registered the instant the old one is confirmed dead.
  defp wait_for_new_pid(id, old_pid, attempts \\ 50)

  defp wait_for_new_pid(id, old_pid, 0) do
    flunk(
      "expected a fresh process for #{id} to replace #{inspect(old_pid)} " <>
        "after :transient restart, but none appeared"
    )
  end

  defp wait_for_new_pid(id, old_pid, attempts) do
    case GenServer.whereis(via_tuple(id)) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        wait_for_new_pid(id, old_pid, attempts - 1)
    end
  end

  property "no sequence of approvals produces an invalid state" do
    check all(actions <- list_of(approver_generator(), max_length: 20)) do
      id = start_instance!()

      Enum.each(actions, fn approver -> ParallelApproval.approve(id, approver) end)

      assert %{state: state, approved_by: approved_by} = ParallelApproval.get(id)
      assert state in [:pending, :approved]
      assert Enum.all?(approved_by, &(&1 in [:finance, :ops]))

      if state == :approved do
        assert Enum.sort(approved_by) == [:finance, :ops]
      end
    end
  end

  defp approver_generator do
    StreamData.member_of([:finance, :ops, :legal])
  end
end
