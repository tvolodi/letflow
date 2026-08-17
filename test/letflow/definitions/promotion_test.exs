defmodule Letflow.Definitions.PromotionTest do
  @moduledoc """
  Tests for `Letflow.Definitions.Promotion.promote_definition/3` (REQ-037,
  ENV-03). See `test/specs/REQ-037.md` for the full test-case rationale and
  `lib/letflow/design/promotion_review_state_machine.md` §3 for the
  gate-approved design this file exercises.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file.

  ## Fixture strategy -- mirrors `promotion_plan_test.exs`'s two-tenant pattern

  `promote_definition/3` reads/writes `process_definitions` under TWO tenants'
  schemas (source and target), exactly like REQ-036's
  `PromotionPlan.compute_promotion_plan/5` -- so each test that needs real
  rows provisions TWO real tenant schemas via `provisioned_tenant/0` (real
  `CREATE SCHEMA` + `TenantProvisioning.replay_migrations/1`). Sandbox
  `:auto` mode + manual `on_exit/1` cleanup, `async: false` for the whole
  module -- same reasoning as `promotion_plan_test.exs`'s own moduledoc.

  ## `promote_definition/3` takes an in-memory `PromotionReview.t()` struct,
  not a `review_id` -- no `promotion_reviews` row needs to exist

  Unlike every function in `PromotionReviewStore`, `promote_definition/3`
  never reads `promotion_reviews` at all (design §3.2 step 1 decodes
  `review.serialised_plan` directly off the struct it was handed). Every
  fixture below builds a `%PromotionReview{}` struct literal in memory --
  never persisted -- exactly matching the design's own algorithm, which has
  no `Repo.get(PromotionReview, ...)` step.

  ## `opts[:permission_checker]` and `opts[:event_appender]` are supplied
  explicitly on EVERY call in this file

  Neither has a built-in default (`Keyword.fetch!/2` for both -- design §3.2,
  reusing `PromotionPlan.promotion_opts()`'s own no-default stance for
  `permission_checker`, plus a new, equally-no-default `event_appender` opt
  this design adds since there is no working `EventStore.append/2` call site
  for a definition-level event yet, design §5 OQ-1). Every single call below
  passes both explicitly, mirroring `promotion_plan_test.exs`'s own
  `opts[:permission_checker]` convention -- never relying on a default that
  does not exist.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReview
  alias Letflow.Definitions.Promotion
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- mirrors promotion_plan_test.exs's own copies exactly
  # (per this project's established per-test-file self-sufficiency convention).
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: "req037-promo-#{System.unique_integer([:positive, :monotonic])}",
        display_name: "REQ-037 Promotion Test Tenant"
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

  defp unique_process_key(prefix \\ "req037-promo-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp insert_definition!(schema_name, attrs) do
    base = %{
      tenant_id: Ecto.UUID.generate(),
      version: "1.0.0",
      graph: %{"nodes" => [], "edges" => []},
      created_by: Ecto.UUID.generate()
    }

    %ProcessDefinition{}
    |> ProcessDefinition.create_changeset(Map.merge(base, attrs))
    |> Repo.insert!(prefix: schema_name)
  end

  # Guarded, single-statement UPDATE -- create_changeset/2 never casts :status
  # (design INV-DEF-8), mirrors migrations_test.exs's/promotion_plan_test.exs's
  # own activate!/2 helper exactly.
  defp activate!(schema_name, id) do
    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               ~s(UPDATE "#{schema_name}"."process_definitions" SET status = 'active' ) <>
                 "WHERE id = $1 AND status = 'draft'",
               [Ecto.UUID.dump!(id)]
             )
  end

  defp insert_active_definition!(schema_name, attrs) do
    definition = insert_definition!(schema_name, attrs)
    activate!(schema_name, definition.id)
    %{definition | status: :active}
  end

  defp allow, do: fn _actor_id, _source_tenant_id -> true end
  defp deny, do: fn _actor_id, _source_tenant_id -> false end

  # A no-op event_appender that records what it was called with by sending a
  # message to the test process -- real function value, no mock/stub library.
  defp recording_event_appender(test_pid) do
    fn event_attrs, prefix ->
      send(test_pid, {:event_appended, event_attrs, prefix})
      {:ok, %{event_id: Ecto.UUID.generate()}}
    end
  end

  # Builds an in-memory (never persisted) PromotionReview struct, matching the
  # exact envelope insert_review/2 would have produced (design §2.3 step 4 --
  # the FULL plan, not just entries).
  defp review_for(plan, overrides \\ %{}) do
    base = %{
      id: Ecto.UUID.generate(),
      tenant_id: plan.target_tenant_id,
      plan_digest: PromotionDigest.compute_plan_digest(plan),
      def_id: plan.process_key,
      serialised_plan: Jason.encode!(plan),
      requested_by: Ecto.UUID.generate(),
      status: :approved,
      row_version: 2
    }

    struct(PromotionReview, Map.merge(base, overrides))
  end

  # ---------------------------------------------------------------------------------
  # promote_definition/3 -- basic success path
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- basic success path" do
    test "version-pointer move (deprecate old active, activate new target row) + event-append, both succeed" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "2.0.0",
          description: "source description",
          stage: "S2",
          graph: %{"nodes" => [%{"id" => "n1", "node_type" => "START"}], "edges" => []}
        })

      # Target starts with NO existing row for this process_key -- no conflict,
      # no prior active row to have deprecated (that half is asserted below via
      # a zero-active-count check for the row that never existed).
      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)
      actor_id = Ecto.UUID.generate()
      test_pid = self()

      assert {:ok, result} =
               Promotion.promote_definition(actor_id, review,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      assert result.source_definition_id == source_def.id
      assert result.process_key == process_key
      assert is_binary(result.target_definition_id)
      refute result.target_definition_id == source_def.id

      target_row = Repo.get!(ProcessDefinition, result.target_definition_id, prefix: target_schema)
      assert target_row.status == :active
      assert target_row.tenant_id == target_tenant_id
      assert target_row.name == process_key
      assert target_row.version == "2.0.0"
      assert target_row.description == "source description"
      assert target_row.stage == "S2"
      assert target_row.created_by == actor_id

      # Source row is untouched by this operation -- promote_definition/3 only
      # ever writes to the TARGET tenant's schema.
      reloaded_source = Repo.get!(ProcessDefinition, source_def.id, prefix: source_schema)
      assert reloaded_source.status == :active

      assert_received {:event_appended, event_attrs, received_prefix}
      assert received_prefix == target_schema
      assert event_attrs.event_type == "DEFINITION_PROMOTED"
      assert event_attrs.actor_id == actor_id
      assert event_attrs.review_id == review.id
      assert event_attrs.source_tenant_id == source_tenant_id
      assert event_attrs.target_tenant_id == target_tenant_id
      assert event_attrs.source_definition_id == source_def.id
      assert event_attrs.target_definition_id == result.target_definition_id
      assert event_attrs.process_key == process_key
    end

    test "a pre-existing ACTIVE target row for the same process_key is deprecated as part of the same swap" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "3.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      # tenant_id must match target_tenant_id explicitly -- deprecate_previous_active/3
      # filters on d.tenant_id == ^target_tenant_id (belt-and-suspenders on top of
      # the schema-per-tenant prefix scoping), and insert_definition!/2's own
      # `base` map defaults tenant_id to an unrelated random UUID otherwise.
      previous_target_def =
        insert_active_definition!(target_schema, %{
          tenant_id: target_tenant_id,
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: previous_target_def.id,
        base_version: "1.0.0",
        entries: []
      }

      review = review_for(plan)
      test_pid = self()

      assert {:ok, result} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: recording_event_appender(test_pid)
               )

      new_target_row = Repo.get!(ProcessDefinition, result.target_definition_id, prefix: target_schema)
      assert new_target_row.status == :active
      assert new_target_row.version == "3.0.0"

      reloaded_previous = Repo.get!(ProcessDefinition, previous_target_def.id, prefix: target_schema)
      assert reloaded_previous.status == :deprecated

      assert_received {:event_appended, _event_attrs, _prefix}
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:permission_checker] -- fail-closed, no built-in default, checked before
  # any DB read (design §3.2 step 2, mirrors PromotionPlan's own convention).
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- opts[:permission_checker]" do
    test "permission_checker returning false -> {:error, :forbidden}, before any process_definitions read" do
      source_tenant_id = Ecto.UUID.generate()
      target_tenant_id = Ecto.UUID.generate()
      process_key = unique_process_key()

      # Neither tenant is provisioned (no CREATE SCHEMA ever ran) -- if
      # permission_checker did not short-circuit BEFORE any read, the very next
      # step (schema resolution / a Repo.get_by against a schema that doesn't
      # exist) would raise instead of cleanly returning {:error, :forbidden}.
      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      assert {:error, :forbidden} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: deny(),
                 event_appender: fn _attrs, _prefix -> {:ok, %{}} end
               )
    end

    test "omitting opts[:permission_checker] entirely raises KeyError -- no silent allow-everything default" do
      review = review_for(%{
        source_tenant_id: Ecto.UUID.generate(),
        target_tenant_id: Ecto.UUID.generate(),
        process_key: unique_process_key(),
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      })

      assert_raise KeyError, fn ->
        Promotion.promote_definition(Ecto.UUID.generate(), review,
          event_appender: fn _attrs, _prefix -> {:ok, %{}} end
        )
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:event_appender] -- fail-closed, no built-in default (design §3.2 step 9,
  # OQ-1) -- the "and event-append" half of ENV-03 this design deliberately does
  # not paper over with a silent no-op default.
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- opts[:event_appender]" do
    test "omitting opts[:event_appender] entirely raises KeyError -- no silent no-op default" do
      review = review_for(%{
        source_tenant_id: Ecto.UUID.generate(),
        target_tenant_id: Ecto.UUID.generate(),
        process_key: unique_process_key(),
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      })

      assert_raise KeyError, fn ->
        Promotion.promote_definition(Ecto.UUID.generate(), review, permission_checker: allow())
      end
    end

    test "an event_appender returning {:error, _} propagates unchanged, after the version-pointer move has already committed" do
      %{tenant_id: source_tenant_id, schema_name: source_schema} = provisioned_tenant()
      %{tenant_id: target_tenant_id, schema_name: target_schema} = provisioned_tenant()

      process_key = unique_process_key()

      source_def =
        insert_active_definition!(source_schema, %{
          name: process_key,
          version: "1.0.0",
          graph: %{"nodes" => [], "edges" => []}
        })

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: source_def.id,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      failing_event_appender = fn _event_attrs, _prefix -> {:error, :event_store_unavailable} end

      assert {:error, :event_store_unavailable} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: failing_event_appender
               )

      # Design §3.2 step 9 / §5 OQ-1: the version-pointer move is NOT rolled
      # back when the event-append fails -- the transaction (steps 7-8) already
      # committed before step 9 ever runs. This is the real, stated gap the
      # design does not paper over; this test pins that it stays that way
      # rather than silently changing shape.
      assert Repo.aggregate(
               from(d in ProcessDefinition, where: d.tenant_id == ^target_tenant_id and d.status == :active),
               :count,
               prefix: target_schema
             ) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:tenant_classifier] -- reuse, not reinvention (design INV-PRM04-5): a
  # production-classified source_tenant_id is rejected before promote_definition/3
  # ever attempts a process_definitions read.
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- opts[:tenant_classifier]" do
    test "source_tenant_id classified :production -> {:error, :invalid_promotion_source}" do
      source_tenant_id = Ecto.UUID.generate()

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: Ecto.UUID.generate(),
        process_key: unique_process_key(),
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      assert {:error, :invalid_promotion_source} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 tenant_classifier: fn _tenant_id -> :production end,
                 event_appender: fn _attrs, _prefix -> {:ok, %{}} end
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # promote_definition/3 -- :source_definition_missing (design §3.2 step 5, a new
  # error case not present on PromotionPlan.compute_error/0)
  # ---------------------------------------------------------------------------------

  describe "promote_definition/3 -- :source_definition_missing" do
    test "the source tenant has no ACTIVE row for process_key -> {:error, :source_definition_missing}" do
      %{tenant_id: source_tenant_id} = provisioned_tenant()
      %{tenant_id: target_tenant_id} = provisioned_tenant()

      process_key = unique_process_key()

      plan = %{
        source_tenant_id: source_tenant_id,
        target_tenant_id: target_tenant_id,
        process_key: process_key,
        source_definition_id: nil,
        target_definition_id: nil,
        base_version: nil,
        entries: []
      }

      review = review_for(plan)

      assert {:error, :source_definition_missing} =
               Promotion.promote_definition(Ecto.UUID.generate(), review,
                 permission_checker: allow(),
                 event_appender: fn _attrs, _prefix -> {:ok, %{}} end
               )
    end
  end
end
