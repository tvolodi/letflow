defmodule Letflow.ServiceCatalogDeletePinnedInstancesTest do
  @moduledoc """
  ISS-0923 regression suite (AC-1..AC-14 of
  `lib/letflow/design/iss0923-catalog-delete-blocks-on-pinned-instances.md`
  section 10): `Letflow.ServiceCatalog.delete/1` must refuse to delete a catalog
  entry while a NON-TERMINAL (`:active` / `:error`) instance in ANY provisioned
  tenant has a frozen definition snapshot referencing the service, must delete
  the service's archived `service_catalog_versions` rows atomically with the
  entry on success, and `DELETE /admin/services/:service_id` must map the new
  error to a 409 problem document.

  See `test/specs/ISS-0923.md` for the per-test rationale, the pre-fix
  (origin/main) failure record and the mutant table.

  Fixtures: committed-row style (`Sandbox.mode :auto`, `async: false`) like
  `engine_catalog_service_task_test.exs` (ISS-0917). Most cases insert the
  projection + snapshot rows directly (`Repo.insert!`, the AC-8 seam of design
  section 10.2) so the instance status / graph / tenant are fully controlled;
  AC-1 / AC-2 additionally drive the real engine (`Engine.create/2`,
  `Engine.cancel_instance/3`) end to end.

  RUN WITH an isolated database: `MIX_ENV=test MIX_TEST_PARTITION=<n> mix test
  <this file>`. The shared `letflow_test` DB can hold other sessions' stale
  `tenant_template_build_*` registrations whose schema does not exist, and
  `delete/1` iterates EVERY registration (raises Postgrex 42P01 there).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Letflow.Support.PlatformTenantFixture
  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Definitions.InstanceDefinitionSnapshot
  alias Letflow.Engine
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.Version
  alias Letflow.TenantFixture

  @opts Letflow.Routers.AdminServices.init([])
  @v1_url "https://example.test/iss0923/v1"
  @v2_url "https://example.test/iss0923/v2"
  @cap 50

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers (no optional-argument defaults -- anti-patterns.md ISS-0069)
  # ---------------------------------------------------------------------------------

  defp unique(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  defp tenant!, do: TenantFixture.provisioned_tenant!(slug_prefix: "iss0923")

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(v in Version, where: v.service_id == ^service_id))
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register_with!(overrides) do
    attrs =
      Map.merge(
        %{
          service_id: unique("iss0923-svc"),
          endpoint_url: @v1_url,
          required_auth: :NONE,
          timeout_ms: 5_000,
          scope: :global
        },
        overrides
      )

    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  defp register!, do: register_with!(%{})

  defp publish_v2!(service_id) do
    assert {:ok, updated} =
             ServiceCatalog.publish(service_id, "2", %{
               endpoint_url: @v2_url,
               required_auth: :NONE,
               timeout_ms: 9_000
             })

    updated
  end

  defp entry_count(service_id),
    do: Repo.aggregate(from(e in Entry, where: e.service_id == ^service_id), :count)

  defp version_count(service_id),
    do: Repo.aggregate(from(v in Version, where: v.service_id == ^service_id), :count)

  # START -> SERVICE_TASK(service_id) -> END
  defp graph_start_catalog(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"service_id" => service_id, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "svc"},
        %{"id" => "e2", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # START -> HUMAN_TASK(role) -> SERVICE_TASK(service_id) -> END (a real instance
  # stays :active at the HUMAN_TASK after create/2)
  defp graph_task_then_catalog(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"service_id" => service_id, "timeout_ms" => 5_000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  # Mentions `needle` ONLY as plain text inside a non-SERVICE_TASK node.
  defp graph_text_mention_only(needle) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver", "description" => "see #{needle} later"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # A DRAFT definition: a real `process_definitions` row (the snapshot FK target)
  # that is NOT :active, so it never trips the active-definitions guard.
  defp draft_definition!(tenant, graph) do
    attrs = %{
      name: unique("iss0923-def"),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: tenant.schema_name)
    definition
  end

  defp active_definition!(tenant, graph) do
    definition = draft_definition!(tenant, graph)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: tenant.schema_name)

    activated
  end

  # Design 10.2 seam: minimal projection + snapshot rows via Repo.insert!
  # (NOT insert_all: started_at/updated_at are NOT NULL with no DB default).
  # Returns the instance id.
  defp insert_instance!(tenant, definition, graph, status) do
    instance_id = Ecto.UUID.generate()

    Repo.insert!(
      %InstanceProjection{
        instance_id: instance_id,
        status: status,
        definition_id: definition.id,
        last_event_seq: 0
      },
      prefix: tenant.schema_name
    )

    Repo.insert!(
      %InstanceDefinitionSnapshot{
        instance_id: instance_id,
        definition_id: definition.id,
        definition_name: definition.name,
        definition_ver: definition.version,
        graph: graph
      },
      prefix: tenant.schema_name
    )

    instance_id
  end

  defp set_status!(tenant, instance_id, status) do
    InstanceProjection
    |> Repo.get!(instance_id, prefix: tenant.schema_name)
    |> Ecto.Changeset.change(%{status: status})
    |> Repo.update!(prefix: tenant.schema_name)
  end

  defp remove_instance!(tenant, instance_id) do
    Repo.delete_all(from(s in InstanceDefinitionSnapshot, where: s.instance_id == ^instance_id),
      prefix: tenant.schema_name
    )

    Repo.delete_all(from(p in InstanceProjection, where: p.instance_id == ^instance_id),
      prefix: tenant.schema_name
    )
  end

  # ---------------------------------------------------------------------------------
  # AC-1 / AC-2 -- the real engine path
  # ---------------------------------------------------------------------------------

  describe "AC-1/AC-2: a real engine instance pins the service" do
    test "AC-1: blocks (no write) while the instance is :active and no ACTIVE definition references the service; AC-2: succeeds, versions gone, once cancelled" do
      tenant = tenant!()
      entry = register!()
      publish_v2!(entry.service_id)
      assert version_count(entry.service_id) == 1

      definition = active_definition!(tenant, graph_task_then_catalog(entry.service_id))

      assert {:ok, %{instance_id: instance_id}} =
               Engine.create(
                 %{
                   definition_id: definition.id,
                   initial_variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique("iss0923-start")
                 },
                 prefix: tenant.schema_name
               )

      assert Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name).status ==
               :active

      # While the definition is ACTIVE the definitions guard fires first (D-D).
      assert {:error, {:referenced_by_active_definitions, [_ | _]}} =
               ServiceCatalog.delete(entry.service_id)

      assert {:ok, _} = Definitions.deprecate(definition.id, prefix: tenant.schema_name)

      # AC-1: only the instance pins the service now.
      assert {:error, {:referenced_by_active_instances, refs}} =
               ServiceCatalog.delete(entry.service_id)

      assert refs.instance_ids == [instance_id]
      assert refs.truncated == false
      # ... and performs NO write.
      assert entry_count(entry.service_id) == 1
      assert version_count(entry.service_id) == 1

      # AC-2: after the instance reaches a terminal status the delete succeeds.
      assert {:ok, _} =
               Engine.cancel_instance(
                 instance_id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: unique("iss0923-cancel")},
                 prefix: tenant.schema_name
               )

      assert Repo.get!(InstanceProjection, instance_id, prefix: tenant.schema_name).status ==
               :cancelled

      assert :ok = ServiceCatalog.delete(entry.service_id)
      assert entry_count(entry.service_id) == 0
      assert version_count(entry.service_id) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-1 (direct seam), AC-2 (terminal statuses), AC-3 (:error), AC-14 (drift)
  # ---------------------------------------------------------------------------------

  describe "AC-1/AC-2/AC-3/AC-14: status filter == not InstanceProjection.terminal?/1" do
    test "AC-1 (direct rows): a non-terminal :active instance with a SERVICE_TASK snapshot blocks, naming exactly that instance id" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      instance_id = insert_instance!(tenant, definition, graph, :active)

      assert {:error, {:referenced_by_active_instances, %{instance_ids: [^instance_id]}}} =
               ServiceCatalog.delete(entry.service_id)

      assert entry_count(entry.service_id) == 1
    end

    test "AC-3: an :error instance blocks exactly like :active (D-C)" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      instance_id = insert_instance!(tenant, definition, graph, :error)

      assert {:error, {:referenced_by_active_instances, %{instance_ids: [^instance_id]}}} =
               ServiceCatalog.delete(entry.service_id)

      assert entry_count(entry.service_id) == 1
    end

    for status <- [:completed, :cancelled] do
      test "AC-2: a #{status} instance does not block; delete succeeds and removes the live row and every archive row" do
        tenant = tenant!()
        entry = register!()
        publish_v2!(entry.service_id)
        graph = graph_start_catalog(entry.service_id)
        definition = draft_definition!(tenant, graph)
        _instance_id = insert_instance!(tenant, definition, graph, unquote(status))

        assert :ok = ServiceCatalog.delete(entry.service_id)
        assert entry_count(entry.service_id) == 0
        assert version_count(entry.service_id) == 0
      end
    end

    test "AC-14: for EVERY InstanceProjection status, the instance blocks iff terminal?/1 is false (drift guard)" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      statuses = Ecto.Enum.values(InstanceProjection, :status)

      # Sanity: the enum still has both kinds, so the loop below discriminates.
      assert Enum.any?(statuses, &InstanceProjection.terminal?/1)
      assert Enum.any?(statuses, &(not InstanceProjection.terminal?(&1)))

      for status <- statuses do
        instance_id = insert_instance!(tenant, definition, graph, status)
        result = ServiceCatalog.delete(entry.service_id)

        if InstanceProjection.terminal?(status) do
          assert result == :ok, "terminal status #{status} must not block, got #{inspect(result)}"
          # re-create the entry for the remaining iterations
          remove_instance!(tenant, instance_id)
          cleanup_entry!(entry.service_id)
          assert {:ok, _} = ServiceCatalog.register(register_attrs_for(entry))
        else
          assert {:error, {:referenced_by_active_instances, %{instance_ids: [^instance_id]}}} =
                   result

          remove_instance!(tenant, instance_id)
        end
      end
    end

    test "AC-1: a status change from :active to :completed releases the block" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      instance_id = insert_instance!(tenant, definition, graph, :active)

      assert {:error, {:referenced_by_active_instances, _}} =
               ServiceCatalog.delete(entry.service_id)

      set_status!(tenant, instance_id, :completed)
      assert :ok = ServiceCatalog.delete(entry.service_id)
    end
  end

  defp register_attrs_for(entry) do
    %{
      service_id: entry.service_id,
      endpoint_url: entry.endpoint_url,
      required_auth: :NONE,
      timeout_ms: entry.timeout_ms,
      scope: :global
    }
  end

  # ---------------------------------------------------------------------------------
  # AC-4 -- every tenant is covered; tenant-scoped services
  # ---------------------------------------------------------------------------------

  describe "AC-4: the instance guard covers every provisioned tenant" do
    test "an instance in ANY ONE of three tenants blocks (registration order is unspecified, so each tenant takes a turn as the sole holder)" do
      tenants = [tenant!(), tenant!(), tenant!()]
      entry = register!()
      graph = graph_start_catalog(entry.service_id)

      for tenant <- tenants do
        definition = draft_definition!(tenant, graph)
        instance_id = insert_instance!(tenant, definition, graph, :active)

        assert {:error, {:referenced_by_active_instances, %{instance_ids: ids}}} =
                 ServiceCatalog.delete(entry.service_id)

        assert ids == [instance_id],
               "instance in #{tenant.schema_name} must be detected, got #{inspect(ids)}"

        remove_instance!(tenant, instance_id)
      end

      assert entry_count(entry.service_id) == 1
      assert :ok = ServiceCatalog.delete(entry.service_id)
    end

    test "instances in two different tenants are both reported, ascending" do
      tenant_a = tenant!()
      tenant_b = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)

      id_a = insert_instance!(tenant_a, draft_definition!(tenant_a, graph), graph, :active)
      id_b = insert_instance!(tenant_b, draft_definition!(tenant_b, graph), graph, :error)

      assert {:error, {:referenced_by_active_instances, %{instance_ids: ids, truncated: false}}} =
               ServiceCatalog.delete(entry.service_id)

      assert ids == Enum.sort([id_a, id_b])
    end

    test "a scope: :tenant service pinned by an instance in its owning tenant is detected" do
      tenant = tenant!()
      entry = register_with!(%{scope: :tenant, owner_tenant_id: tenant.tenant_id})
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      instance_id = insert_instance!(tenant, definition, graph, :active)

      assert {:error, {:referenced_by_active_instances, %{instance_ids: [^instance_id]}}} =
               ServiceCatalog.delete(entry.service_id)

      assert entry_count(entry.service_id) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-5 -- equality, not substring / LIKE
  # ---------------------------------------------------------------------------------

  describe "AC-5: reference match is structural equality on the SERVICE_TASK service_id" do
    test "an instance pinned to a DIFFERENT service whose id contains this one does not block" do
      tenant = tenant!()
      entry = register!()
      longer_id = entry.service_id <> "-extended"
      graph = graph_start_catalog(longer_id)
      definition = draft_definition!(tenant, graph)
      _instance_id = insert_instance!(tenant, definition, graph, :active)

      assert :ok = ServiceCatalog.delete(entry.service_id)
    end

    test "an instance pinned to a service whose id is a PREFIX-substring of this one does not block either" do
      tenant = tenant!()
      entry = register!()
      shorter_id = String.slice(entry.service_id, 0..-3//1)
      refute shorter_id == entry.service_id
      graph = graph_start_catalog(shorter_id)
      definition = draft_definition!(tenant, graph)
      _instance_id = insert_instance!(tenant, definition, graph, :active)

      assert :ok = ServiceCatalog.delete(entry.service_id)
    end

    test "the service id appearing only as plain text in a non-SERVICE_TASK node does not block" do
      tenant = tenant!()
      entry = register!()
      graph = graph_text_mention_only(entry.service_id)
      definition = draft_definition!(tenant, graph)
      _instance_id = insert_instance!(tenant, definition, graph, :active)

      assert :ok = ServiceCatalog.delete(entry.service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-6 / AC-7 -- precedence and not_found unchanged
  # ---------------------------------------------------------------------------------

  describe "AC-6/AC-7: guard precedence and not_found" do
    test "AC-6: with an ACTIVE referencing definition AND a non-terminal instance, the definitions error is reported (D-D); clearing the definition then surfaces the instance error" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = active_definition!(tenant, graph)
      instance_id = insert_instance!(tenant, definition, graph, :active)

      assert {:error, {:referenced_by_active_definitions, definition_ids}} =
               ServiceCatalog.delete(entry.service_id)

      assert definition.id in definition_ids

      assert {:ok, _} = Definitions.deprecate(definition.id, prefix: tenant.schema_name)

      assert {:error, {:referenced_by_active_instances, %{instance_ids: [^instance_id]}}} =
               ServiceCatalog.delete(entry.service_id)
    end

    test "AC-7: delete of a nonexistent service is :not_found, even when instances reference that id" do
      tenant = tenant!()
      ghost_id = unique("iss0923-ghost")
      graph = graph_start_catalog(ghost_id)
      definition = draft_definition!(tenant, graph)
      _instance_id = insert_instance!(tenant, definition, graph, :active)

      assert {:error, :not_found} = ServiceCatalog.delete(ghost_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-8 / AC-9 -- bound, determinism, shape
  # ---------------------------------------------------------------------------------

  describe "AC-8/AC-9: the reported id list is bounded, ascending and carries nothing else" do
    test "exactly 50 referencing instances -> all 50 ids, truncated false; one more -> the 50 smallest ids, truncated true" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)

      first_fifty = for _ <- 1..@cap, do: insert_instance!(tenant, definition, graph, :active)

      assert {:error, {:referenced_by_active_instances, at_cap}} =
               ServiceCatalog.delete(entry.service_id)

      assert at_cap.truncated == false
      assert at_cap.instance_ids == Enum.sort(first_fifty)
      assert length(at_cap.instance_ids) == @cap

      extra = insert_instance!(tenant, definition, graph, :active)
      all_ids = Enum.sort([extra | first_fifty])

      assert {:error, {:referenced_by_active_instances, over_cap}} =
               ServiceCatalog.delete(entry.service_id)

      assert over_cap.truncated == true
      assert length(over_cap.instance_ids) == @cap
      assert over_cap.instance_ids == Enum.take(all_ids, @cap)
      assert entry_count(entry.service_id) == 1
    end

    test "AC-8 across tenants: 30 + 30 instances -> exactly the globally smallest 50 of the union, truncated true" do
      tenant_a = tenant!()
      tenant_b = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      def_a = draft_definition!(tenant_a, graph)
      def_b = draft_definition!(tenant_b, graph)

      ids_a = for _ <- 1..30, do: insert_instance!(tenant_a, def_a, graph, :active)
      ids_b = for _ <- 1..30, do: insert_instance!(tenant_b, def_b, graph, :active)

      assert {:error, {:referenced_by_active_instances, refs}} =
               ServiceCatalog.delete(entry.service_id)

      assert refs.truncated == true
      assert refs.instance_ids == Enum.take(Enum.sort(ids_a ++ ids_b), @cap)
    end

    test "AC-9: the returned map has exactly the keys instance_ids and truncated" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      _instance_id = insert_instance!(tenant, definition, graph, :active)

      assert {:error, {:referenced_by_active_instances, refs}} =
               ServiceCatalog.delete(entry.service_id)

      assert refs |> Map.keys() |> Enum.sort() == [:instance_ids, :truncated]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-10 -- orphaned archive rows (D-F)
  # ---------------------------------------------------------------------------------

  describe "AC-10: archive rows do not outlive the deleted service" do
    test "after delete + re-register of the same service_id, publishing a previously-archived version is not rejected and a {:version, v} pin never resolves to the previous incarnation's endpoint" do
      entry = register!()
      service_id = entry.service_id
      publish_v2!(service_id)
      # incarnation 1: version "1" (@v1_url) is archived, "2" (@v2_url) is current.
      assert version_count(service_id) == 1

      assert :ok = ServiceCatalog.delete(service_id)
      assert version_count(service_id) == 0

      # incarnation 2, with a different endpoint, same service_id.
      assert {:ok, reborn} =
               ServiceCatalog.register(%{
                 service_id: service_id,
                 endpoint_url: "https://example.test/iss0923/reborn",
                 required_auth: :NONE,
                 timeout_ms: 5_000,
                 scope: :global
               })

      assert reborn.version == entry.version

      # Publishing "2" archives the reborn "1"; a stale archived (service_id,"1")
      # row from incarnation 1 would collide with it.
      assert {:ok, _} =
               ServiceCatalog.publish(service_id, "2", %{
                 endpoint_url: "https://example.test/iss0923/reborn-v2",
                 required_auth: :NONE,
                 timeout_ms: 5_000
               })

      tenant_id = Ecto.UUID.generate()

      assert {:ok, resolved} =
               ServiceCatalog.resolve_pinned_version(service_id, {:version, "1"}, tenant_id)

      assert resolved.endpoint_url == "https://example.test/iss0923/reborn"
      refute resolved.endpoint_url == @v1_url
    end

    test "delete of a never-published entry (zero archive rows) is :ok" do
      entry = register!()
      assert version_count(entry.service_id) == 0
      assert :ok = ServiceCatalog.delete(entry.service_id)
      assert entry_count(entry.service_id) == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-11 -- atomicity under a concurrent delete
  # ---------------------------------------------------------------------------------

  describe "AC-11: version-row deletion is atomic with the entry deletion" do
    test "a concurrent delete of the same row is a benign :not_found AND the archive-row deletion is rolled back" do
      entry = register!()
      publish_v2!(entry.service_id)
      assert version_count(entry.service_id) == 1
      test_pid = self()
      service_id = entry.service_id

      {:ok, locker} =
        Task.start(fn ->
          Repo.transaction(fn ->
            Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
            send(test_pid, :row_locked)

            receive do
              :release_lock -> :ok
            end
          end)
        end)

      assert_receive :row_locked, 1_000

      delete_task = Task.async(fn -> ServiceCatalog.delete(service_id) end)

      # Wait (bounded, no fixed sleep) until delete/1's own DELETE is blocked on the
      # row lock held by `locker`.
      assert wait_until_a_backend_waits_on_a_lock(100)

      send(locker, :release_lock)

      assert {:error, :not_found} = Task.await(delete_task, 5_000)

      # The entry was removed by `locker`; delete/1's transaction rolled back, so the
      # archive row it deleted first is still there.
      assert entry_count(service_id) == 0
      assert version_count(service_id) == 1
    end
  end

  defp wait_until_a_backend_waits_on_a_lock(0), do: false

  defp wait_until_a_backend_waits_on_a_lock(attempts) do
    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE datname = current_database() AND wait_event_type = 'Lock'",
        []
      )

    if waiting > 0 do
      true
    else
      Process.sleep(20)
      wait_until_a_backend_waits_on_a_lock(attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC-12 / AC-13 -- HTTP
  # ---------------------------------------------------------------------------------

  defp http_delete(service_id, roles) do
    conn(:delete, "/#{service_id}")
    |> assign(
      :auth_context,
      PlatformTenantFixture.operator_auth_context(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        roles
      )
    )
    |> assign(:trace_id, "fixed-test-trace-id")
    |> then(&Letflow.Routers.AdminServices.call(&1, @opts))
  end

  describe "AC-12/AC-13: DELETE /admin/services/:service_id" do
    test "AC-12: 409 service-referenced-by-active-instances with only instance_ids + truncated extensions, no id in detail" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = draft_definition!(tenant, graph)
      instance_id = insert_instance!(tenant, definition, graph, :active)

      resp = http_delete(entry.service_id, ["PLATFORM_ADMIN"])

      assert resp.status == 409
      body = Jason.decode!(resp.resp_body)

      assert String.ends_with?(body["type"], "service-referenced-by-active-instances")
      assert body["title"] == "Service Referenced By Active Instances"
      assert body["status"] == 409
      assert body["instance_ids"] == [instance_id]
      assert body["truncated"] == false
      refute body["detail"] =~ instance_id

      allowed = ~w(type title status detail trace_id instance_ids truncated)
      assert Map.keys(body) -- allowed == []
      assert entry_count(entry.service_id) == 1
    end

    test "AC-13: an ACTIVE referencing definition still yields the definitions 409" do
      tenant = tenant!()
      entry = register!()
      graph = graph_start_catalog(entry.service_id)
      definition = active_definition!(tenant, graph)
      _instance_id = insert_instance!(tenant, definition, graph, :active)

      resp = http_delete(entry.service_id, ["PLATFORM_ADMIN"])

      assert resp.status == 409
      body = Jason.decode!(resp.resp_body)
      assert String.ends_with?(body["type"], "service-referenced-by-active-definitions")
      assert body["definition_ids"] == [definition.id]
    end

    test "AC-13: unreferenced -> 204; unknown -> 404; non-PLATFORM_ADMIN -> 403 with no write" do
      entry = register!()
      other = register!()

      forbidden = http_delete(entry.service_id, ["PROCESS_DESIGNER"])
      assert forbidden.status == 403
      assert entry_count(entry.service_id) == 1

      ok = http_delete(entry.service_id, ["PLATFORM_ADMIN"])
      assert ok.status == 204
      assert entry_count(entry.service_id) == 0
      assert entry_count(other.service_id) == 1

      missing = http_delete(unique("iss0923-missing"), ["PLATFORM_ADMIN"])
      assert missing.status == 404
    end
  end
end
