defmodule Letflow.EngineFormExpressionReevaluationTest do
  @moduledoc """
  Tests for REQ-292's server-side re-evaluation of `visible_when`, `computed`, and
  `cross_field_validation` form-field-logic expressions on a task's PINNED
  `form_schema` at `Letflow.Engine.complete_task/3` completion. See
  `lib/letflow/design/req292-server-side-form-expression-reevaluation.md` (the
  gate-approved design this file verifies) and
  `lib/letflow/engine/form_expression_reevaluation.ex` (the pure module this exercises
  end-to-end, through the real transactional `complete_task/3` path -- no unit-level
  bypass of the Multi).

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1. Self-contained fixtures -- does not share state with
  `test/letflow/engine_complete_task_test.exs` (DIRECTIVE T-4), even though the
  provisioning/graph-building helpers below are structurally similar.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.FormExpressionReevaluation
  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.EventStore.Event
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req292"),
        display_name: "REQ-292 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req292-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> task(HUMAN_TASK, form_schema) -> END.
  defp graph_with_form_schema(form_schema) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver", "form_schema" => form_schema}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp create_definition_attrs(name, version, graph) do
    %{
      name: name,
      version: version,
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph, name, version) do
    assert {:ok, definition} =
             Definitions.create(
               create_definition_attrs(name || unique_name(), version, graph),
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp start_attrs(definition, overrides) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{"seed" => "value"},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("start")
      },
      overrides
    )
  end

  defp start_instance_with_pending_task!(schema_name, graph, opts \\ []) do
    name = Keyword.get(opts, :name)
    version = Keyword.get(opts, :version, "1.0.0")
    initial_variables = Keyword.get(opts, :initial_variables, %{"seed" => "value"})

    definition = active_definition!(schema_name, graph, name, version)

    assert {:ok, result} =
             Engine.create(
               start_attrs(definition, %{initial_variables: initial_variables}),
               prefix: schema_name
             )

    [task] = Repo.all(EngineTask, prefix: schema_name)
    assert task.status == :pending

    {result.instance_id, task, definition}
  end

  defp complete_attrs(overrides) do
    Map.merge(
      %{
        output_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("complete")
      },
      overrides
    )
  end

  defp task_completed_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "TASK_COMPLETED")
    |> Repo.all(prefix: schema_name)
  end

  defp execution_error_events(schema_name, instance_id) do
    Event
    |> where([e], e.instance_id == ^instance_id and e.event_type == "EXECUTION_ERROR")
    |> Repo.all(prefix: schema_name)
  end

  # Shared schema for the computed/visible_when scenarios (AC1a/AC1b, AC2, AC3).
  defp schema_computed_and_visible_when do
    %{
      "type" => "object",
      "properties" => %{
        "amount" => %{"type" => "number"},
        "bonus" => %{"type" => "number", "x-ui" => %{"computed" => "amount + 1"}},
        "note" => %{"type" => "string", "x-ui" => %{"visible_when" => "amount > 0"}}
      }
    }
  end

  # Schema for the cross_field_validation scenario (AC1c).
  defp schema_cross_field do
    %{
      "type" => "object",
      "properties" => %{
        "amount" => %{"type" => "number"},
        "confirm" => %{
          "type" => "boolean",
          "x-ui" => %{
            "cross_field_validation" => %{
              "expression" => "amount > 0",
              "message" => "amount must be positive"
            }
          }
        }
      }
    }
  end

  # Schema for AC4 -- a visible_when expression whose referenced field can be
  # either genuinely absent (a real Expr.eval/2 failure) or explicitly present
  # and false (a legitimate {:ok, false}) -- the two outcomes this AC requires
  # to be distinguishable.
  defp schema_eval_failure_vs_false do
    %{
      "type" => "object",
      "properties" => %{
        "trigger" => %{"type" => "boolean"},
        "conditional_field" => %{
          "type" => "string",
          "x-ui" => %{"visible_when" => "trigger == true"}
        }
      }
    }
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- every visible_when/computed/cross-field-validation expression is
  # re-evaluated on completion, one test per key.
  # ---------------------------------------------------------------------------------

  describe "AC1 -- computed re-evaluated server-side" do
    test "a computed field's server-derived value is persisted even though the client submitted none" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_computed_and_visible_when())
        )

      attrs = complete_attrs(%{output_variables: %{"amount" => 5}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)

      # The client never submitted "bonus" at all -- its presence, with the
      # correct server-computed value, in the MERGED instance variables proves
      # the server's own evaluation ran. (`tasks.output_variables` stays the
      # raw, literal submission verbatim by design -- design doc §2 -- so it
      # is not asserted on here; the corrected value only reaches
      # `instance_projections.variables`/`result.variables`.)
      assert result.variables["bonus"] == 6

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      refute Map.has_key?(completed_task.output_variables, "bonus")
    end
  end

  describe "AC1 -- visible_when re-evaluated server-side" do
    test "a submitted value for a server-hidden field is dropped, proving the server evaluated visible_when" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_computed_and_visible_when())
        )

      attrs =
        complete_attrs(%{output_variables: %{"amount" => -1, "note" => "should be hidden"}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)

      # A naive pass-through (no server-side re-evaluation) would have kept
      # "note" verbatim in the MERGED instance variables -- its absence there
      # proves visible_when actually ran. (`tasks.output_variables` keeps the
      # raw literal submission regardless -- design doc §2 -- so "note" is
      # still present there; that is the audit trail of what was submitted,
      # not what got persisted as a process variable.)
      refute Map.has_key?(result.variables, "note")

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.output_variables["note"] == "should be hidden"
    end
  end

  describe "AC1 -- cross_field_validation re-evaluated server-side" do
    test "a submission violating a cross_field_validation rule is rejected, proving the server evaluated it" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_cross_field())
        )

      attrs = complete_attrs(%{output_variables: %{"amount" => -5, "confirm" => true}})

      assert {:error,
              {:instance_execution_error, :form_cross_field_validation_failed,
               {:field, "confirm"}}} =
               Engine.complete_task(task.id, attrs, prefix: schema_name)

      untouched_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched_task.status == :pending

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error

      assert [event] = execution_error_events(schema_name, instance_id)
      assert event.payload["error_type"] == "form_cross_field_validation_failed"
      assert event.payload["reason"] == "amount must be positive"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- a falsified computed value never wins; the server's value is used,
  # the disagreement is logged, and completion proceeds normally.
  # ---------------------------------------------------------------------------------

  describe "AC2 -- falsified computed value: server wins, disagreement logged, not an error" do
    test "the server's recomputed value is persisted and the disagreement rides inside merged_variable_events" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_computed_and_visible_when())
        )

      attrs =
        complete_attrs(%{output_variables: %{"amount" => 5, "bonus" => 999, "note" => "ok"}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)

      # Server wins in the MERGED instance variables -- not the falsified
      # client value.
      assert result.variables["bonus"] == 6

      # `tasks.output_variables` deliberately keeps the raw, literal
      # submission verbatim (design doc §2) -- the falsified 999 stays there
      # as the forensic record of what the client actually sent, separate
      # from the corrected process variable above.
      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.output_variables["bonus"] == 999

      assert [event] = task_completed_events(schema_name, instance_id)

      disagreement_events =
        Enum.filter(
          event.payload["merged_variable_events"],
          &(&1["event"] == "computed_field_disagreement")
        )

      assert [
               %{
                 "event" => "computed_field_disagreement",
                 "field" => "bonus",
                 "submitted_value" => 999,
                 "server_value" => 6
               }
             ] = disagreement_events
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- a submitted value for a visible_when: false field is dropped, and the
  # drop is logged -- not an error.
  # ---------------------------------------------------------------------------------

  describe "AC3 -- visible_when: false on a submitted field: dropped, logged, not an error" do
    test "the discarded submission rides inside merged_variable_events, completion proceeds" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_computed_and_visible_when())
        )

      attrs =
        complete_attrs(%{output_variables: %{"amount" => -1, "note" => "secret"}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)

      # Dropped from the MERGED instance variables -- not from
      # `tasks.output_variables`, which deliberately keeps the raw, literal
      # submission verbatim (design doc §2) as the audit record of what was
      # actually submitted.
      refute Map.has_key?(result.variables, "note")

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.output_variables["note"] == "secret"

      assert [event] = task_completed_events(schema_name, instance_id)

      discard_events =
        Enum.filter(
          event.payload["merged_variable_events"],
          &(&1["event"] == "visible_when_false_value_discarded")
        )

      assert [
               %{
                 "event" => "visible_when_false_value_discarded",
                 "field" => "note",
                 "discarded_value" => "secret"
               }
             ] = discard_events
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- a genuine evaluation FAILURE must never silently read as "hide the
  # field": it produces a different outcome than a legitimate {:ok, false}.
  # ---------------------------------------------------------------------------------

  describe "AC4 -- an evaluation failure is distinguishable from a legitimate false" do
    test "a visible_when referencing a genuinely undefined variable aborts completion with an execution error" do
      %{schema_name: schema_name} = provisioned_tenant()

      {instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_eval_failure_vs_false())
          # "trigger" is never in initial_variables and never submitted below --
          # Expr.eval/2 sees an undefined variable, a genuine eval failure.
        )

      attrs = complete_attrs(%{output_variables: %{"conditional_field" => "value"}})

      assert {:error,
              {:instance_execution_error, :form_expression_evaluation_failed,
               {:field, "conditional_field"}}} =
               Engine.complete_task(task.id, attrs, prefix: schema_name)

      untouched_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert untouched_task.status == :pending

      projection = Repo.get!(InstanceProjection, instance_id, prefix: schema_name)
      assert projection.status == :error
    end

    test "the same expression shape, evaluating cleanly to false, only drops the field and completes normally" do
      %{schema_name: schema_name} = provisioned_tenant()

      {_instance_id, task, _definition} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_eval_failure_vs_false()),
          initial_variables: %{"seed" => "value", "trigger" => false}
        )

      attrs = complete_attrs(%{output_variables: %{"conditional_field" => "value"}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)
      refute Map.has_key?(result.variables, "conditional_field")

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.status == :completed
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- re-evaluation uses the task's PINNED form_schema, not a later-activated
  # definition's schema.
  # ---------------------------------------------------------------------------------

  describe "AC5 -- re-evaluation uses the PINNED form_schema (form_version, REQ-126)" do
    test "advancing the definition after the instance started does not change what the pinned task re-evaluates against" do
      %{schema_name: schema_name} = provisioned_tenant()

      process_name = unique_name("req292-pin")

      schema_v1 = %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "number"},
          "note" => %{"type" => "string", "x-ui" => %{"visible_when" => "amount > 0"}}
        }
      }

      {_instance_id, task, _definition_v1} =
        start_instance_with_pending_task!(
          schema_name,
          graph_with_form_schema(schema_v1),
          name: process_name,
          version: "1.0.0"
        )

      assert task.form_schema == schema_v1

      # Advance the SAME process name to a new, activated version whose
      # visible_when rule for the identical field is the OPPOSITE of v1's.
      schema_v2 = %{
        "type" => "object",
        "properties" => %{
          "amount" => %{"type" => "number"},
          "note" => %{"type" => "string", "x-ui" => %{"visible_when" => "amount < 0"}}
        }
      }

      assert {:ok, definition_v2} =
               Definitions.create(
                 create_definition_attrs(
                   process_name,
                   "2.0.0",
                   graph_with_form_schema(schema_v2)
                 ),
                 prefix: schema_name
               )

      assert {:ok, _} = Definitions.activate(definition_v2.id, prefix: schema_name)

      # Completing the ORIGINAL instance's already-pinned task with amount = 5
      # (positive): under the PINNED v1 rule ("amount > 0"), "note" stays. Under
      # the now-current v2 rule ("amount < 0"), it would have been dropped. Its
      # presence here proves the PINNED schema, not the current one, was used.
      attrs = complete_attrs(%{output_variables: %{"amount" => 5, "note" => "hello"}})

      assert {:ok, result} = Engine.complete_task(task.id, attrs, prefix: schema_name)
      assert result.variables["note"] == "hello"

      completed_task = Repo.get!(EngineTask, task.id, prefix: schema_name)
      assert completed_task.output_variables["note"] == "hello"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- variable_schemas remains the sole authority for value-shape validation;
  # this module never validates a submitted value against form_schema's own
  # JSON-Schema type/constraint keywords.
  # ---------------------------------------------------------------------------------

  describe "AC6 -- variable_schemas remains sole authority" do
    test "form_expression_reevaluation.ex's CODE never references form_schema's JSON-Schema validation keywords" do
      contents =
        File.read!(Path.join(File.cwd!(), "lib/letflow/engine/form_expression_reevaluation.ex"))

      # The moduledoc itself names these keywords in PROSE, deliberately --
      # it is exactly this module's own statement of the boundary AC6 checks
      # (its own describe block below asserts on that prose). Only the CODE
      # after the moduledoc's closing `"""` must never reach for one of them.
      [_moduledoc, code_after_moduledoc] = String.split(contents, "\"\"\"", parts: 3) |> tl()

      for keyword <-
            ~w("required" "minimum" "maximum" "pattern" "enum" "minLength" "maxLength" "minItems" "maxItems") do
        refute code_after_moduledoc =~ keyword,
               "form_expression_reevaluation.ex's code must never reference the " <>
                 "JSON-Schema validation keyword #{keyword} -- that remains " <>
                 "variable_schemas' sole authority"
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Moduledoc content assertions -- the requirement's own acceptance criteria require
  # these dispositions stated in the moduledoc, not merely implied by code.
  # ---------------------------------------------------------------------------------

  describe "FormExpressionReevaluation moduledoc" do
    test "states the failure-vs-false rule, the computed disagreement and visible_when-false dispositions, and the variable_schemas boundary" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(FormExpressionReevaluation)

      normalized = String.replace(moduledoc, ~r/\s+/, " ")

      # Failure vs. false
      assert normalized =~ "never treated as"
      assert normalized =~ "form_expression_evaluation_failed"
      assert normalized =~ "evaluate_condition/2"

      # Computed-field disagreement
      assert normalized =~ "server's value is used and the disagreement is recorded"

      # visible_when-false disposition
      assert normalized =~ "dropped"
      assert normalized =~ "visible_when_false_value_discarded"

      # variable_schemas boundary
      assert normalized =~ "variable_schemas"
      assert normalized =~ "expressions only"
    end
  end
end
