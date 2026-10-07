defmodule Letflow.Engine.Req462VortexDeviationRequiredOutputsTest do
  @moduledoc """
  REQ-462 (k, l) -- the Vortex "Supplier Quality Deviation" QA fixture (v1.7) declares
  `required_outputs: ["severity"]` on `severity-classification` and on its D-ESC task
  `escalate-severity-classification-to-ceo` (no inheritance, design req459 section 9). Neither node
  has a `form_schema`, so REQ-461 check 3 is vacuous for them: these tests are the evidence.

  Before this adoption a completion that omitted `severity` fell through the severity-routing
  default edge to the 8D corrective-action sub-process (fail-closed to critical); now it is refused.
  One test per node, NAMED BY NODE ID: key omitted (empty output, explicit null, and a completion
  that supplies `false_positive` but NO severity) -> refused with `missing_keys: [severity]`
  (rendered 422 `output_refused` by the tasks router), task open, instance unchanged; then a valid
  severity completes and routes.

  See `test/specs/REQ-462.md`. Real Postgres, `async: false`; no HTTP, no wall clock.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Req462Adoption, as: A

  @fixture "vortex_supplier_quality_deviation_process_definition.json"
  # a completion that carries the OTHER decision but not the required severity
  @extra %{"false_positive" => false}

  setup do
    A.sandbox_auto!()
  end

  defp at_severity_classification! do
    {schema, id} =
      A.started_instance!(@fixture, %{"batch_ref" => "batch-462", "deviation_id" => "dev-462"})

    A.advance_service_task!(schema, id, "quarantine-batch", %{})
    assert A.projection(schema, id).current_nodes == ["severity-classification"]
    {schema, id}
  end

  defp at_escalated_classification! do
    {schema, id} = at_severity_classification!()
    assert A.fire_escalation!(schema, id).node_id == "severity-classification"
    assert A.projection(schema, id).current_nodes == ["escalate-severity-classification-to-ceo"]
    {schema, id}
  end

  test "severity-classification: omitting severity is refused (missing_keys [severity]), task open, instance unchanged; a valid severity routes" do
    {schema, id} = at_severity_classification!()
    A.assert_omitted_refused!(schema, id, "severity-classification", "severity", @extra)

    assert A.projection(schema, id).current_nodes == ["severity-classification"]
    # the old behaviour: omission reached the default-critical corrective-action sub-process
    refute "corrective-action-subprocess" in A.projection(schema, id).current_nodes

    A.complete!(schema, A.task!(schema, id, "severity-classification"), %{
      "false_positive" => false,
      "severity" => "major"
    })

    assert A.projection(schema, id).current_nodes == ["supplier-warning"]

    {schema2, id2} = at_severity_classification!()
    A.assert_omitted_refused!(schema2, id2, "severity-classification", "severity", @extra)

    A.complete!(schema2, A.task!(schema2, id2, "severity-classification"), %{
      "false_positive" => false,
      "severity" => "minor"
    })

    assert A.projection(schema2, id2).current_nodes == ["supplier-notification"]
  end

  test "escalate-severity-classification-to-ceo: the D-ESC task inherits nothing; omitting severity is refused, task open, instance unchanged; a valid severity routes" do
    {schema, id} = at_escalated_classification!()

    A.assert_omitted_refused!(
      schema,
      id,
      "escalate-severity-classification-to-ceo",
      "severity",
      @extra
    )

    assert A.projection(schema, id).current_nodes == ["escalate-severity-classification-to-ceo"]
    # a missing value must not fall through to default-critical
    refute "default-to-critical" in A.dispatched_nodes(schema, id)

    A.complete!(schema, A.task!(schema, id, "escalate-severity-classification-to-ceo"), %{
      "false_positive" => false,
      "severity" => "major"
    })

    assert A.projection(schema, id).current_nodes == ["supplier-warning"]

    {schema2, id2} = at_escalated_classification!()

    A.assert_omitted_refused!(
      schema2,
      id2,
      "escalate-severity-classification-to-ceo",
      "severity",
      @extra
    )

    A.complete!(schema2, A.task!(schema2, id2, "escalate-severity-classification-to-ceo"), %{
      "false_positive" => true,
      "severity" => "minor"
    })

    assert A.projection(schema2, id2).current_nodes == ["release-quarantine"]
  end
end
