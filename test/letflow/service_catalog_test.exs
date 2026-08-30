defmodule Letflow.ServiceCatalogTest do
  @moduledoc """
  Tests for REQ-191 -- `Letflow.ServiceCatalog` (context module), its
  `Entry` schema, and the `service_catalog` migration. See
  `test/specs/REQ-191.md` for the full acceptance-criterion -> test-case
  mapping and rationale. Design authority:
  `lib/letflow/design/req191-service-catalog-core.md`. Implementation
  authority: `lib/letflow/service_catalog.ex` /
  `lib/letflow/service_catalog/entry.ex` / the
  `20260830000001_create_service_catalog.exs` migration, all of which already
  passed SECURITY-REVIEWER and REVIEWER.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database
  anywhere in this file. `service_catalog` is a GLOBAL table (no tenant
  schema, no `:prefix`), so most tests here need only a lightweight
  `Letflow.Identity.Tenant` row (`insert_tenant!/1`, no schema provisioning)
  to satisfy `owner_tenant_id`'s foreign key. The referential-guard tests
  (AC6/AC7) and the `ServiceScopeValidator` integration test (AC8) need a
  *real provisioned tenant schema* with a real `process_definitions` row,
  since `Letflow.ServiceCatalog`'s referential guard walks
  `Letflow.TenantProvisioning.list_registrations/0` and queries each tenant
  schema's own `process_definitions` table -- those use
  `Letflow.TenantFixture.provisioned_tenant!/1`.

  `async: false`: real, committed (non-sandboxed-transaction) schema
  creation/teardown for the provisioned-tenant tests, and
  `Letflow.TenantProvisioning.list_registrations/0` reads real, uncommitted-
  by-us global state -- both need serialization against every other
  `async: false` file in this suite, mirroring `dlq_test.exs` /
  `engine_complete_task_test.exs`'s own established pattern.

  Every `service_catalog` row this file creates is deleted in `on_exit/1` --
  `service_id` is this table's PK and globally unique, so a leftover row from
  a failed test run could otherwise collide with a later run's fixture.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ServiceScopeValidator
  alias Letflow.Identity.Tenant
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.TenantFixture

  # `service_catalog` is a GLOBAL table -- unlike the tenant-schema-scoped
  # data most other DataCase tests write, its rows are never cleaned up by a
  # `DROP SCHEMA ... CASCADE`, so every test needs real, explicit cleanup.
  # `on_exit/1` callbacks run in a process distinct from the test process and
  # cannot use a `:manual`/`{:shared, pid}` sandboxed connection once that
  # test process has exited (`Ecto.Adapters.SQL.Sandbox`'s "owner exited"
  # failure) -- exactly the reason `Letflow.TenantFixture.provisioned_tenant!/1`
  # itself switches to `:auto` mode before doing anything it must later clean
  # up in `on_exit/1`. This file follows the same discipline for every test,
  # not only the ones that provision a tenant schema.
  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp unique_service_id(prefix \\ "req191-svc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # Lightweight tenant: no schema provisioning, just a real `tenants` row so
  # `owner_tenant_id`'s FK is satisfiable. Used by every test that does not
  # need the referential guard (which walks real tenant schemas).
  defp insert_tenant!(slug_prefix \\ "req191-svc-tenant") do
    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
          display_name: "REQ-191 ServiceCatalog Test Tenant"
        },
        :disabled
      )
      |> Repo.insert!()

    on_exit(fn -> Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id)) end)

    tenant
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register_attrs(overrides) do
    %{
      service_id: unique_service_id(),
      endpoint_url: "https://example.test/svc",
      required_auth: :NONE,
      timeout_ms: 5_000,
      scope: :global
    }
    |> Map.merge(overrides)
  end

  defp register!(overrides) do
    attrs = register_attrs(overrides)
    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  # A real, provisioned tenant schema (`TenantFixture.provisioned_tenant!/1`)
  # -- needed only by tests exercising the referential guard or the
  # ServiceScopeValidator integration, since both walk real
  # `process_definitions` rows in real tenant schemas.
  defp provisioned_tenant(slug_prefix \\ "req191-svc") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-191 ServiceCatalog Provisioned Tenant"
    )
  end

  defp service_task_node(id, service_id) do
    %{"id" => id, "node_type" => "SERVICE_TASK", "attributes" => %{"service_id" => service_id}}
  end

  # A node that is NOT a SERVICE_TASK, whose attributes string-contain
  # `service_id` as a plain substring -- proves the referential guard's
  # structural (node_type, attribute-key) match, not a LIKE/substring scan.
  defp unrelated_substring_node(id, needle) do
    %{
      "id" => id,
      "node_type" => "HUMAN_TASK",
      "attributes" => %{"description" => "internal note mentioning #{needle} in passing"}
    }
  end

  defp insert_active_definition!(schema_name, nodes, name_prefix \\ "req191-def") do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all(
      "process_definitions",
      [
        %{
          id: Ecto.UUID.dump!(id),
          name: name_prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic])),
          version: "1.0.0",
          status: "active",
          graph: %{"nodes" => nodes, "edges" => []},
          created_by: Ecto.UUID.dump!(Ecto.UUID.generate()),
          sequence_number: 0,
          created_at: now,
          updated_at: now
        }
      ],
      prefix: schema_name
    )

    id
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- scope/owner_tenant_id consistency CHECK, enforced at the DATABASE
  # level (raw SQL, deliberately bypassing Entry.insert_changeset/2 and its
  # check_constraint/3 mapping entirely, so a passing test can only mean the
  # database itself rejects the row -- not that the changeset does).
  # ---------------------------------------------------------------------------------

  describe "AC1: scope/owner_tenant_id consistency is a DATABASE-level CHECK" do
    test "scope = 'global' with a non-null owner_tenant_id is rejected by the database" do
      tenant = insert_tenant!()
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 5000, 'global', $2, now(), now())",
                 [service_id, Ecto.UUID.dump!(tenant.id)]
               )

      refute Repo.get(Entry, service_id)
    end

    test "scope = 'tenant' with a null owner_tenant_id is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 5000, 'tenant', NULL, now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- required_auth / timeout_ms are DATABASE-level CHECKs
  # ---------------------------------------------------------------------------------

  describe "AC2: required_auth and timeout_ms are DATABASE-level CHECKs" do
    test "required_auth = 'BASIC' is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at) " <>
                   "VALUES ($1, 'https://example.test', 'BASIC', 5000, 'global', NULL, now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end

    test "timeout_ms = 0 is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 0, 'global', NULL, now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end

    test "timeout_ms = 3_600_001 is rejected by the database" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "INSERT INTO service_catalog " <>
                   "(service_id, endpoint_url, required_auth, timeout_ms, scope, owner_tenant_id, created_at, updated_at) " <>
                   "VALUES ($1, 'https://example.test', 'NONE', 3600001, 'global', NULL, now(), now())",
                 [service_id]
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- get_for_tenant/2's three-way visibility rule. Per REVIEWER's own
  # note on the handoff: this predicate is now the SOLE tenant-isolation
  # mechanism for this data (no physical schema separation backstops it), so
  # this is treated as load-bearing, not an ordinary business-rule check.
  # ---------------------------------------------------------------------------------

  describe "AC3: get_for_tenant/2 three-way visibility" do
    test "a global service is visible to any tenant" do
      entry = register!(%{scope: :global})
      requester = insert_tenant!()

      assert {:ok, %Entry{service_id: service_id}} =
               ServiceCatalog.get_for_tenant(entry.service_id, requester.id)

      assert service_id == entry.service_id
    end

    test "a tenant-scoped service is visible to its owner" do
      owner = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      assert {:ok, %Entry{service_id: service_id}} =
               ServiceCatalog.get_for_tenant(entry.service_id, owner.id)

      assert service_id == entry.service_id
    end

    test "a tenant-scoped service owned by a different tenant is NOT_FOUND, not forbidden" do
      owner = insert_tenant!()
      other = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      assert {:error, :not_found} = ServiceCatalog.get_for_tenant(entry.service_id, other.id)
    end

    test "a real-but-invisible service and a genuinely missing service produce the identical error shape" do
      owner = insert_tenant!()
      other = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      invisible_result = ServiceCatalog.get_for_tenant(entry.service_id, other.id)

      missing_result =
        ServiceCatalog.get_for_tenant(unique_service_id("req191-nonexistent"), other.id)

      assert invisible_result == {:error, :not_found}
      assert missing_result == {:error, :not_found}
      # Not merely equal atoms -- the exact same tuple shape, no extra metadata
      # anywhere that could let a caller tell the two cases apart.
      assert invisible_result == missing_result
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- service_id is globally unique across all tenants and both scopes
  # ---------------------------------------------------------------------------------

  describe "AC4: service_id is globally unique" do
    test "registering the same service_id for a second, different tenant fails, even when the first is tenant-scoped" do
      tenant_a = insert_tenant!()
      tenant_b = insert_tenant!()
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)

      assert {:ok, first} =
               ServiceCatalog.register(
                 register_attrs(%{
                   service_id: service_id,
                   scope: :tenant,
                   owner_tenant_id: tenant_a.id
                 })
               )

      assert {:error, :duplicate_service_id} =
               ServiceCatalog.register(
                 register_attrs(%{
                   service_id: service_id,
                   scope: :tenant,
                   owner_tenant_id: tenant_b.id
                 })
               )

      # The original row is untouched -- no silent overwrite.
      assert {:ok, reloaded} = ServiceCatalog.get_for_tenant(service_id, tenant_a.id)
      assert reloaded.owner_tenant_id == first.owner_tenant_id
      assert reloaded.owner_tenant_id == tenant_a.id
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- register/1 with scope: :tenant naming a non-existent tenant
  # ---------------------------------------------------------------------------------

  describe "AC5: register/1 rejects a non-existent tenant, no row created" do
    test "returns {:error, :tenant_not_found} and creates no row" do
      service_id = unique_service_id()
      on_exit(fn -> cleanup_entry!(service_id) end)
      nonexistent_tenant_id = Ecto.UUID.generate()

      assert {:error, :tenant_not_found} =
               ServiceCatalog.register(
                 register_attrs(%{
                   service_id: service_id,
                   scope: :tenant,
                   owner_tenant_id: nonexistent_tenant_id
                 })
               )

      refute Repo.get(Entry, service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- delete/1's referential guard, structural not substring
  # ---------------------------------------------------------------------------------

  describe "AC6: delete/1 referential guard" do
    test "delete of a service referenced by an ACTIVE definition is refused, naming the referencing definition id" do
      %{schema_name: schema_name} = provisioned_tenant("req191-del-ref")
      entry = register!(%{scope: :global})

      definition_id =
        insert_active_definition!(schema_name, [service_task_node("n1", entry.service_id)])

      assert {:error, {:referenced_by_active_definitions, definition_ids}} =
               ServiceCatalog.delete(entry.service_id)

      assert definition_id in definition_ids
      # Refused -- the row must still exist.
      assert Repo.get(Entry, entry.service_id)
    end

    test "delete of an unreferenced service succeeds" do
      provisioned_tenant("req191-del-unref")
      entry = register!(%{scope: :global})

      assert :ok = ServiceCatalog.delete(entry.service_id)
      refute Repo.get(Entry, entry.service_id)
    end

    test "a service id appearing only as a substring inside an unrelated string does NOT block delete" do
      %{schema_name: schema_name} = provisioned_tenant("req191-del-substr")
      entry = register!(%{scope: :global})

      # This node mentions the service_id as plain text inside an unrelated
      # HUMAN_TASK attribute -- never as a SERVICE_TASK node's own
      # "service_id" attribute. R-Co's LIKE-based guard would over-match this;
      # Letflow's structural guard must not.
      insert_active_definition!(schema_name, [
        unrelated_substring_node("n1", entry.service_id)
      ])

      assert :ok = ServiceCatalog.delete(entry.service_id)
      refute Repo.get(Entry, entry.service_id)
    end

    # Regression coverage for the SECURITY-REVIEWER rework this handoff names
    # (WF02-REQ191-20260830 Step 2c FAIL -> unhandled `Ecto.StaleEntryError`):
    # `delete_entry/1`'s own comment documents a real window between `delete/1`'s
    # initial `Repo.get/2` and its own `Repo.delete/1` in which a concurrent
    # caller can delete the same row first. This deterministically forces that
    # exact window (rather than hoping two processes race by chance) by holding
    # a real Postgres row-level lock open in one process while `delete/1` runs
    # concurrently in another: the second `DELETE` blocks on the lock, then
    # resumes against a row that is already gone once the lock releases --
    # exactly the 0-rows-affected condition `Repo.delete/1` turns into
    # `Ecto.StaleEntryError` by default.
    test "a concurrent delete of the same row is treated as a benign not-found, not a crash" do
      entry = register!(%{scope: :global})
      test_pid = self()

      {:ok, locker} =
        Task.start(fn ->
          Repo.transaction(fn ->
            Repo.delete_all(from(e in Entry, where: e.service_id == ^entry.service_id))
            send(test_pid, :row_locked)

            receive do
              :release_lock -> :ok
            end
          end)
        end)

      assert_receive :row_locked, 1_000

      delete_task = Task.async(fn -> ServiceCatalog.delete(entry.service_id) end)

      # Give delete/1's own Repo.get + Repo.delete a moment to run and block on
      # the row lock `locker` is holding, before releasing it.
      Process.sleep(200)
      send(locker, :release_lock)

      assert {:error, :not_found} = Task.await(delete_task, 5_000)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC7 -- update_scope/2: narrow refused (naming conflicting tenants),
  # widen always allowed
  # ---------------------------------------------------------------------------------

  describe "AC7: update_scope/2 narrow/widen" do
    test "narrowing global -> tenant is refused, naming the conflicting tenant, when another tenant's ACTIVE definition references it" do
      %{tenant_id: assignee_tenant_id} = provisioned_tenant("req191-narrow-assignee")

      %{tenant_id: other_tenant_id, schema_name: other_schema} =
        provisioned_tenant("req191-narrow-other")

      entry = register!(%{scope: :global})
      insert_active_definition!(other_schema, [service_task_node("n1", entry.service_id)])

      assert {:error, {:referenced_by_active_definitions, conflicts}} =
               ServiceCatalog.update_scope(entry.service_id, %{
                 scope: :tenant,
                 owner_tenant_id: assignee_tenant_id
               })

      assert Enum.any?(conflicts, &(&1.tenant_id == other_tenant_id))
      # Refused -- scope is unchanged.
      assert {:ok, %Entry{scope: :global}} =
               ServiceCatalog.get_for_tenant(entry.service_id, assignee_tenant_id)
    end

    test "narrowing global -> tenant succeeds when only the assignee tenant itself references it (self-exemption)" do
      %{tenant_id: assignee_tenant_id, schema_name: assignee_schema} =
        provisioned_tenant("req191-narrow-self")

      entry = register!(%{scope: :global})
      insert_active_definition!(assignee_schema, [service_task_node("n1", entry.service_id)])

      assert {:ok, %Entry{scope: :tenant, owner_tenant_id: ^assignee_tenant_id}} =
               ServiceCatalog.update_scope(entry.service_id, %{
                 scope: :tenant,
                 owner_tenant_id: assignee_tenant_id
               })
    end

    test "widening tenant -> global always succeeds, even with other tenants' ACTIVE references" do
      owner = insert_tenant!()
      %{schema_name: other_schema} = provisioned_tenant("req191-widen-other")

      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})
      insert_active_definition!(other_schema, [service_task_node("n1", entry.service_id)])

      assert {:ok, %Entry{scope: :global, owner_tenant_id: nil}} =
               ServiceCatalog.update_scope(entry.service_id, %{
                 scope: :global,
                 owner_tenant_id: nil
               })
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- ServiceScopeValidator.validate/3 works unchanged with a Lookup
  # backed by this catalog. service_scope_validator.ex itself is untouched
  # (confirmed via git diff, quoted in the handoff report, not re-asserted
  # here since it is a repository-history fact, not something ExUnit checks).
  # ---------------------------------------------------------------------------------

  describe "AC8: ServiceScopeValidator integration via scope_validator_lookup/1" do
    test "a definition referencing a service not visible to its tenant is rejected at activation" do
      owner = insert_tenant!()
      requester = insert_tenant!()
      entry = register!(%{scope: :tenant, owner_tenant_id: owner.id})

      graph = %Graph{
        nodes: [
          %Graph.Node{
            id: "n1",
            node_type: :SERVICE_TASK,
            attributes: %{"service_id" => entry.service_id}
          }
        ]
      }

      lookup = ServiceCatalog.scope_validator_lookup(requester.id)

      assert {:error, %ServiceScopeValidator.Violation{reason: :service_not_available_to_tenant}} =
               ServiceScopeValidator.validate(graph, requester.id, lookup)
    end

    test "a definition referencing a visible service activates" do
      entry = register!(%{scope: :global})
      requester = insert_tenant!()

      graph = %Graph{
        nodes: [
          %Graph.Node{
            id: "n1",
            node_type: :SERVICE_TASK,
            attributes: %{"service_id" => entry.service_id}
          }
        ]
      }

      lookup = ServiceCatalog.scope_validator_lookup(requester.id)

      assert :ok = ServiceScopeValidator.validate(graph, requester.id, lookup)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC9 -- migration + moduledoc state the GLOBAL divergence and cite
  # decision 0003 / REVIEWER sign-off. Simple content-presence check.
  # ---------------------------------------------------------------------------------

  describe "AC9: migration and moduledoc document the GLOBAL-table divergence" do
    test "the migration header cites decision 0003 and REVIEWER sign-off" do
      migration_source =
        File.read!("priv/repo/migrations/20260830000001_create_service_catalog.exs")

      assert migration_source =~ "0003-ecto-schema-strategy.md"
      assert migration_source =~ "REVIEWER sign-off"
      assert migration_source =~ "GLOBAL"
    end

    test "Letflow.ServiceCatalog's moduledoc cites decision 0003 and REVIEWER sign-off" do
      module_source = File.read!("lib/letflow/service_catalog.ex")

      assert module_source =~ "0003"
      assert module_source =~ "REVIEWER sign-off"
      assert module_source =~ "GLOBAL"
    end
  end

  # ---------------------------------------------------------------------------------
  # AC10 -- SolutionPack's service_catalog_entries hard-fail is still in
  # place, REQ-192 named as owner
  # ---------------------------------------------------------------------------------

  describe "AC10: SolutionPack.service_catalog_entries hard-fail retained, REQ-192 named" do
    test "SolutionPack's moduledoc names REQ-192 as the owner of the service_catalog_entries decision" do
      module_source = File.read!("lib/letflow/definitions/solution_pack.ex")

      assert module_source =~ "service_catalog_entries"
      assert module_source =~ "REQ-192"
    end

    test "export/3 always emits service_catalog_entries: []" do
      %{schema_name: schema_name} = provisioned_tenant("req191-pack-export")

      definition_id =
        insert_active_definition!(schema_name, [%{"id" => "start", "node_type" => "START"}])

      assert {:ok, %{service_catalog_entries: []}} =
               Letflow.Definitions.SolutionPack.export(
                 [definition_id],
                 nil,
                 prefix: schema_name
               )
    end

    test "install/3 rejects a non-empty service_catalog_entries array with {:error, :unsupported_pack_section}" do
      %{schema_name: schema_name} = provisioned_tenant("req191-pack-install")

      document = %{
        "pack_id" => "req191-pack-#{System.unique_integer([:positive, :monotonic])}",
        "version" => "1.0.0",
        "bpm_export_schema_version" => Letflow.Definitions.ExportImport.export_schema_version(),
        "definitions" => [],
        "variable_schemas" => [],
        "service_catalog_entries" => [%{"service_id" => "should-not-install"}]
      }

      assert {:error, :unsupported_pack_section} =
               Letflow.Definitions.SolutionPack.install(
                 document,
                 Ecto.UUID.generate(),
                 prefix: schema_name
               )

      # All-or-nothing: nothing from this document was written.
      %{rows: rows} =
        Repo.query!(
          ~s(SELECT 1 FROM "#{schema_name}".process_definitions),
          []
        )

      assert rows == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC11 -- no route/controller file added or modified (structural, no git
  # history dependency: confirms the routers directory carries nothing named
  # for this catalog, independent of when it was added).
  # ---------------------------------------------------------------------------------

  describe "AC11: no route/controller surface for the service catalog" do
    test "lib/letflow/routers/ contains no service-catalog route module" do
      routers_dir = "lib/letflow/routers"

      matches =
        routers_dir
        |> File.ls!()
        |> Enum.filter(&String.contains?(String.downcase(&1), "service_catalog"))

      assert matches == []
    end
  end
end
