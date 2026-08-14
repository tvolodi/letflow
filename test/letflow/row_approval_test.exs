defmodule Letflow.RowApprovalTest do
  use Letflow.DataCase, async: true

  alias Letflow.RowApproval

  defp create_instance! do
    {:ok, id} = RowApproval.create()
    id
  end

  test "finance then ops reaches :approved" do
    id = create_instance!()

    assert %{status: :pending} = RowApproval.get(id)
    assert :ok = RowApproval.approve(id, :finance)
    assert %{status: :pending, approved_by: [:finance]} = RowApproval.get(id)
    assert :ok = RowApproval.approve(id, :ops)
    assert %{status: :approved} = RowApproval.get(id)
  end

  test "ops then finance also reaches :approved (order-independent)" do
    id = create_instance!()

    assert :ok = RowApproval.approve(id, :ops)
    assert %{status: :pending, approved_by: [:ops]} = RowApproval.get(id)
    assert :ok = RowApproval.approve(id, :finance)
    assert %{status: :approved} = RowApproval.get(id)
  end

  test "approving the same approver twice is idempotent" do
    id = create_instance!()

    assert :ok = RowApproval.approve(id, :finance)
    assert :ok = RowApproval.approve(id, :finance)
    assert %{status: :pending, approved_by: [:finance]} = RowApproval.get(id)

    assert :ok = RowApproval.approve(id, :ops)
    assert %{status: :approved} = RowApproval.get(id)
  end

  test "get/1 reports which approvers have signed while :pending" do
    id = create_instance!()

    assert %{status: :pending, approved_by: []} = RowApproval.get(id)
    :ok = RowApproval.approve(id, :ops)
    assert %{status: :pending, approved_by: [:ops]} = RowApproval.get(id)
  end

  test "an unsupervised approver atom is rejected, not silently accepted" do
    id = create_instance!()

    assert {:error, {:unknown_approver, :legal}} = RowApproval.approve(id, :legal)
    assert %{status: :pending, approved_by: []} = RowApproval.get(id)
  end
end
