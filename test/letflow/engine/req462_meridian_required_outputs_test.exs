defmodule Letflow.Engine.Req462MeridianRequiredOutputsTest do
  @moduledoc """
  REQ-462 (c, d, e, f) -- the Meridian "Loan Origination" QA fixture (v1.13) declares
  `required_outputs` on `l1-approval` (l1_decision), `l2-approval` (l2_decision),
  `escalate-l2-approval-to-ceo` (l2_decision; the D-ESC task inherits nothing, design req459
  section 9) and `kyc-manual-review` (kyc_outcome).

  One test per node, NAMED BY NODE ID, on the real fixture and the real completion path: the
  decision key omitted (empty output, explicit null, other keys only) -> refused with
  `missing_keys: [key]` (the shape the tasks router renders as 422 `output_refused`), task still
  open, instance unchanged; then a valid value completes and routes.

  See `test/specs/REQ-462.md`. Real Postgres, `async: false`; no HTTP, no wall clock.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.Req462Adoption, as: A

  @fixture "meridian_loan_origination_process_definition.json"
  @vars %{"application_id" => "app-462", "requested_amount_eur" => 100_000}
  @extra %{"unrelated_note" => "x"}

  setup do
    A.sandbox_auto!()
  end

  defp started!, do: A.started_instance!(@fixture, @vars)

  defp kyc_screening_result!(schema, id, kyc_status),
    do: A.advance_service_task!(schema, id, "kyc-aml-check", %{"kyc_status" => kyc_status})

  # clear KYC, credit pass, risk low -> l1-approval.
  defp at_l1_approval! do
    {schema, id} = started!()
    kyc_screening_result!(schema, id, "clear")
    A.complete!(schema, A.task!(schema, id, "credit-memo-review"), %{"credit_decision" => "pass"})
    A.complete!(schema, A.task!(schema, id, "risk-assessment"), %{"risk_rating" => "low"})
    assert A.projection(schema, id).current_nodes == ["l1-approval"]
    {schema, id}
  end

  defp at_l2_approval! do
    {schema, id} = at_l1_approval!()
    A.complete!(schema, A.task!(schema, id, "l1-approval"), %{"l1_decision" => "approve"})
    assert A.projection(schema, id).current_nodes == ["l2-approval"]
    {schema, id}
  end

  defp at_escalated_l2! do
    {schema, id} = at_l2_approval!()
    assert A.fire_escalation!(schema, id).node_id == "l2-approval"
    assert A.projection(schema, id).current_nodes == ["escalate-l2-approval-to-ceo"]
    {schema, id}
  end

  defp tasks_at(schema, id, node_id) do
    EngineTask
    |> where([t], t.instance_id == ^id and t.node_id == ^node_id)
    |> Repo.all(prefix: schema)
  end

  test "l1-approval: omitting l1_decision is refused (missing_keys [l1_decision]), task open, instance unchanged; a valid decision routes to l2-approval / decline" do
    {schema, id} = at_l1_approval!()
    A.assert_omitted_refused!(schema, id, "l1-approval", "l1_decision", @extra)

    assert A.projection(schema, id).current_nodes == ["l1-approval"]
    # the old behaviour: omission fell through the fallback edge to l2-approval
    assert [] == tasks_at(schema, id, "l2-approval")

    A.complete!(schema, A.task!(schema, id, "l1-approval"), %{"l1_decision" => "escalate"})
    assert A.projection(schema, id).current_nodes == ["l2-approval"]

    {schema2, id2} = at_l1_approval!()
    A.assert_omitted_refused!(schema2, id2, "l1-approval", "l1_decision", @extra)
    A.complete!(schema2, A.task!(schema2, id2, "l1-approval"), %{"l1_decision" => "reject"})
    assert A.projection(schema2, id2).current_nodes == ["decline-application"]
  end

  test "l2-approval: omitting l2_decision is refused (missing_keys [l2_decision]), task open, instance unchanged; a valid decision routes to create-facility / decline" do
    {schema, id} = at_l2_approval!()
    A.assert_omitted_refused!(schema, id, "l2-approval", "l2_decision", @extra)

    assert A.projection(schema, id).current_nodes == ["l2-approval"]
    # the old behaviour: omission fell through the fallback edge to the CEO escalation task
    assert [] == tasks_at(schema, id, "escalate-l2-approval-to-ceo")

    A.complete!(schema, A.task!(schema, id, "l2-approval"), %{"l2_decision" => "approve"})
    assert A.projection(schema, id).current_nodes == ["create-facility"]

    {schema2, id2} = at_l2_approval!()
    A.assert_omitted_refused!(schema2, id2, "l2-approval", "l2_decision", @extra)
    A.complete!(schema2, A.task!(schema2, id2, "l2-approval"), %{"l2_decision" => "reject"})
    assert A.projection(schema2, id2).current_nodes == ["decline-application"]
  end

  test "escalate-l2-approval-to-ceo: the D-ESC task inherits nothing; omitting l2_decision is refused, task open, instance unchanged; a valid decision routes" do
    {schema, id} = at_escalated_l2!()
    A.assert_omitted_refused!(schema, id, "escalate-l2-approval-to-ceo", "l2_decision", @extra)

    assert A.projection(schema, id).current_nodes == ["escalate-l2-approval-to-ceo"]
    refute "decline-application" in A.dispatched_nodes(schema, id)

    A.complete!(schema, A.task!(schema, id, "escalate-l2-approval-to-ceo"), %{
      "l2_decision" => "approve"
    })

    assert A.projection(schema, id).current_nodes == ["create-facility"]

    {schema2, id2} = at_escalated_l2!()
    A.assert_omitted_refused!(schema2, id2, "escalate-l2-approval-to-ceo", "l2_decision", @extra)

    A.complete!(schema2, A.task!(schema2, id2, "escalate-l2-approval-to-ceo"), %{
      "l2_decision" => "reject"
    })

    assert A.projection(schema2, id2).current_nodes == ["decline-application"]
  end

  test "kyc-manual-review: omitting kyc_outcome is refused (missing_keys [kyc_outcome]), task open, instance unchanged; 'cleared' proceeds to l1-approval, 'rejected' declines" do
    {schema, id} = started!()
    kyc_screening_result!(schema, id, "hit")
    A.assert_omitted_refused!(schema, id, "kyc-manual-review", "kyc_outcome", @extra)

    review = A.task!(schema, id, "kyc-manual-review")
    assert review.status == :pending
    refute Map.has_key?(A.projection(schema, id).variables, "kyc_outcome")

    A.complete!(schema, review, %{"kyc_outcome" => "cleared"})
    assert A.task_status(schema, review) == :completed
    A.complete!(schema, A.task!(schema, id, "credit-memo-review"), %{"credit_decision" => "pass"})
    A.complete!(schema, A.task!(schema, id, "risk-assessment"), %{"risk_rating" => "low"})
    # eligibility gate edge e15-kyc-cleared reads kyc_outcome == 'cleared'
    assert A.projection(schema, id).current_nodes == ["l1-approval"]

    {schema2, id2} = started!()
    kyc_screening_result!(schema2, id2, "inconclusive")
    A.assert_omitted_refused!(schema2, id2, "kyc-manual-review", "kyc_outcome", @extra)

    A.complete!(schema2, A.task!(schema2, id2, "kyc-manual-review"), %{
      "kyc_outcome" => "rejected"
    })

    A.complete!(schema2, A.task!(schema2, id2, "credit-memo-review"), %{
      "credit_decision" => "pass"
    })

    A.complete!(schema2, A.task!(schema2, id2, "risk-assessment"), %{"risk_rating" => "low"})
    assert A.projection(schema2, id2).current_nodes == ["decline-application"]
  end
end
