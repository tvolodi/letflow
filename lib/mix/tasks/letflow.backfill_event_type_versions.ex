defmodule Mix.Tasks.Letflow.BackfillEventTypeVersions do
  @shortdoc "Backfills event type schema versions for pre-existing tenants (ISS-0332, ISS-0583)"

  @moduledoc """
  Backfills event type schema versions for all tenants provisioned before a
  given bump landed. Sweeps a list of event-type version bumps
  (`@event_type_backfills`) rather than a single hardcoded one.

  Backfills the DEFINITION_PROMOTED event type to schema_version 2 for all
  tenants provisioned before REQ-077 bumped the seed (ISS-0332).

  Backfills the TASK_COMPLETED event type to schema_version 3 for all tenants
  provisioned before REQ-292/REQ-391 bumped the seed (ISS-0583, then REQ-391):
  `merged_variable_events` now also carries the `computed_field_disagreement` and
  `visible_when_false_value_discarded` event kinds alongside the original
  `variable_overwritten` (v1->v2), and the payload now also carries
  `attachments_at_decision`, a snapshot of the instance's attachments at
  completion time (v2->v3, REQ-391). `Registry.register_type/2`'s own
  strictly-greater-than-every-existing-version check (`registry.ex`) means a
  tenant still pinned at v1 jumps straight to v3 here rather than needing two
  separate backfill calls -- both bumps are additive/optional fields, so a v1
  or v2 row validates identically against the wider v3 schema for every
  payload either version already produced.

  Backfills the two new REQ-391 event types, ATTACHMENT_ATTACHED and
  ATTACHMENT_REMOVED (both schema_version 1), for all tenants provisioned
  before REQ-391 added them to the seed list -- `Letflow.Repository.Attachments`
  `upload/2`/`delete/2` calls append these types post-commit, best-effort;
  without this backfill, an unbackfilled tenant simply never gets the history
  entry (logged via `Logger.warning/2`, never a hard failure -- see
  `lib/letflow/design/req391-attachment-history-approval-attribution.md` §2.3).

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

  @task_completed_v3_attrs %{
    name: "TASK_COMPLETED",
    schema_version: 3,
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
        "are present depends on which event kind a given array element is. Bumped from " <>
        "schema_version 2 to 3 (REQ-391): the payload now also carries " <>
        "\"attachments_at_decision\", a snapshot of every instance_attachments row present on " <>
        "the instance at completion time. KNOWN GAP, flagged for REVIEWER, same shape as " <>
        "DEFINITION_PROMOTED's own schema_version 1->2 bump above: this only widens the schema " <>
        "seeded into TENANTS PROVISIONED FROM THIS POINT ON -- a tenant provisioned before this " <>
        "change keeps validating TASK_COMPLETED against an earlier version until something " <>
        "backfills it.",
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
        "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}},
        "attachments_at_decision" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "attachment_id" => %{"type" => "string"},
              "file_name" => %{"type" => "string"},
              "content_type" => %{"type" => "string"},
              "byte_size" => %{"type" => "integer"},
              "uploaded_by" => %{"type" => "string"},
              "created_at" => %{"type" => "string"}
            },
            "required" => ["attachment_id", "file_name"]
          }
        }
      },
      "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
    }
  }

  @attachment_attached_v1_attrs %{
    name: "ATTACHMENT_ATTACHED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Repository.Attachments.upload/2 (REQ-391) when an " <>
        "attachment is added to an instance.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "attachment_id" => %{"type" => "string"},
        "file_name" => %{"type" => "string"},
        "content_type" => %{"type" => "string"},
        "byte_size" => %{"type" => "integer"},
        "description" => %{"type" => ["string", "null"]}
      },
      "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
    }
  }

  @attachment_removed_v1_attrs %{
    name: "ATTACHMENT_REMOVED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Repository.Attachments.delete/2 (REQ-391) when an " <>
        "attachment is removed from an instance.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "attachment_id" => %{"type" => "string"},
        "file_name" => %{"type" => "string"},
        "content_type" => %{"type" => "string"},
        "byte_size" => %{"type" => "integer"}
      },
      "required" => ["attachment_id", "file_name", "content_type", "byte_size"]
    }
  }

  @event_type_backfills [
    @definition_promoted_v2_attrs,
    @task_completed_v3_attrs,
    @attachment_attached_v1_attrs,
    @attachment_removed_v1_attrs
  ]

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
