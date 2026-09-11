defmodule Mix.Tasks.Letflow.BackfillEventTypeVersions do
  @shortdoc "Backfills event type schema versions for pre-existing tenants (ISS-0332, ISS-0583)"

  @moduledoc """
  Backfills event type schema versions for all tenants provisioned before a
  given bump landed. Sweeps a list of event-type version bumps
  (`@event_type_backfills`) rather than a single hardcoded one.

  Backfills the DEFINITION_PROMOTED event type to schema_version 2 for all
  tenants provisioned before REQ-077 bumped the seed (ISS-0332).

  Backfills the TASK_COMPLETED event type to schema_version 2 for all tenants
  provisioned before REQ-292 bumped the seed (ISS-0583): `merged_variable_events`
  now also carries the `computed_field_disagreement` and
  `visible_when_false_value_discarded` event kinds alongside the original
  `variable_overwritten`, and a v1-pinned tenant's `Registry.JsonSchema`
  validation rejects them outright until backfilled.

  Usage:

      mix letflow.backfill_event_type_versions

  Exits non-zero if any event type fails to backfill for any tenant.
  """

  use Mix.Task

  @definition_promoted_v2_attrs %{
    name: "DEFINITION_PROMOTED",
    schema_version: 2,
    description:
      "Emitted by Letflow.Definitions.Promotion.promote_definition/3 (PRM-01, the " <>
        "review-gated path) AND Letflow.Definitions.Promotion.promote_active_definition/5 " <>
        "(REQ-077 R10/ENV-03, the reviewless test->production path) after a promotion " <>
        "commits, via Letflow.EventStore.PlatformEvents.append_definition_promoted/2. " <>
        "Bumped from schema_version 1 (REQ-140) to 2 (REQ-077 design §9.5): an ENV-03 " <>
        "promotion genuinely has no review, so `review_id` must admit `null` rather than " <>
        "forcing a synthetic id into the audit log.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "review_id" => %{"type" => ["string", "null"]},
        "source_tenant_id" => %{"type" => "string"},
        "target_tenant_id" => %{"type" => "string"},
        "source_definition_id" => %{"type" => "string"},
        "target_definition_id" => %{"type" => "string"},
        "process_key" => %{"type" => "string"}
      },
      "required" => [
        "review_id",
        "source_tenant_id",
        "target_tenant_id",
        "source_definition_id",
        "target_definition_id",
        "process_key"
      ]
    }
  }

  @task_completed_v2_attrs %{
    name: "TASK_COMPLETED",
    schema_version: 2,
    description:
      "Emitted by Letflow.Engine.complete_task/3 (M9, EE-04) when a user task is completed. " <>
        "Bumped from schema_version 1 to 2 (REQ-292): merged_variable_events now also carries " <>
        "the two new FormExpressionReevaluation.reevaluation_event() kinds " <>
        "(\"computed_field_disagreement\", \"visible_when_false_value_discarded\") alongside " <>
        "the original \"variable_overwritten\" -- widened to a single flat item schema (this " <>
        "validator has no oneOf/anyOf support, Letflow.EventStore.Registry.JsonSchema's own " <>
        "moduledoc) whose \"required\" only still names \"event\" (the one key every kind " <>
        "shares); \"key\"/\"field\"/\"old_value\"/\"new_value\"/\"submitted_value\"/" <>
        "\"server_value\"/\"discarded_value\" are all declared but optional, since which ones " <>
        "are present depends on which event kind a given array element is. KNOWN GAP, flagged " <>
        "for REVIEWER, same shape as DEFINITION_PROMOTED's own schema_version 1->2 bump above: " <>
        "this only widens the schema seeded into TENANTS PROVISIONED FROM THIS POINT ON -- a " <>
        "tenant provisioned before this change keeps validating TASK_COMPLETED against version " <>
        "1 (which would reject the two new event kinds outright) until something backfills it.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "task_id" => %{"type" => "string"},
        "node_id" => %{"type" => "string"},
        "output_variables" => %{"type" => "object"},
        "merged_variable_events" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "event" => %{
                "type" => "string",
                "enum" => [
                  "variable_overwritten",
                  "computed_field_disagreement",
                  "visible_when_false_value_discarded"
                ]
              },
              "key" => %{"type" => "string"},
              "field" => %{"type" => "string"},
              "old_value" => %{},
              "new_value" => %{},
              "submitted_value" => %{},
              "server_value" => %{},
              "discarded_value" => %{}
            },
            "required" => ["event"]
          }
        },
        "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
    }
  }

  @event_type_backfills [@definition_promoted_v2_attrs, @task_completed_v2_attrs]

  @impl Mix.Task
  @spec run(argv :: [String.t()]) :: :ok
  def run(_args) do
    Mix.Task.run("app.start")

    any_failed? =
      Enum.reduce(@event_type_backfills, false, fn attrs, acc_failed? ->
        name = attrs[:name] || attrs["name"]

        case Letflow.TenantProvisioning.Backfill.run(attrs) do
          {:ok, %{updated: u, skipped: s}} ->
            Mix.shell().info("#{name}: backfill complete: #{u} updated, #{s} skipped")
            acc_failed?

          {:error, {:backfill_failed, tenant_id, reason}} ->
            Mix.shell().error(
              "#{name}: backfill failed for tenant #{tenant_id}: #{inspect(reason)}"
            )

            true
        end
      end)

    if any_failed? do
      System.halt(1)
    else
      :ok
    end
  end
end
