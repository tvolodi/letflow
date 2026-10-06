defmodule Letflow.Api.AuthorizationTenantAdminTest do
  @moduledoc """
  REQ-447 PR 1, AC1 (`lib/letflow/design/req447-tenant-admin-role.md` sections 3.1 and 11;
  spec `test/specs/REQ-447-PR1.md`): the `TENANT_ADMIN` role and its grant rule in
  `Letflow.Api.Authorization`.

  Pure (no database, no pin): `async: true` is safe. The router-level and task-scope proofs live in
  `test/letflow/routers/tenant_admin_routes_test.exs` and `test/letflow/routers/tasks_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext
  alias Letflow.Modules.Catalog

  defp ctx(roles, platform_tenant?),
    do: %AccessContext{user_id: "u-req447", roles: roles, platform_tenant?: platform_tenant?}

  describe "roles/0" do
    test "returns seven atoms ending in TENANT_ADMIN, the six pre-existing roles first and unchanged" do
      roles = Authorization.roles()

      assert length(roles) == 7
      assert List.last(roles) == :TENANT_ADMIN

      assert Enum.take(roles, 6) == [
               :PLATFORM_ADMIN,
               :PROCESS_DESIGNER,
               :PROCESS_OPERATOR,
               :TASK_WORKER,
               :AGENT_RUNNER,
               :CANDIDATE
             ]
    end
  end

  describe "AC1: the grant rule" do
    test "role_allows?(:TENANT_ADMIN, p) is true exactly when permission_scope(p) is :tenant, for every p in permissions/0" do
      permissions = Authorization.permissions()
      assert length(permissions) > 40

      for permission <- permissions do
        expected = Authorization.permission_scope(permission) == :tenant

        assert Authorization.role_allows?(:TENANT_ADMIN, permission) == expected,
               "role_allows?(:TENANT_ADMIN, #{inspect(permission)}) disagrees with the " <>
                 "permission's scope (#{inspect(Authorization.permission_scope(permission))})"
      end
    end

    test "the rule is not vacuous: exactly the two platform atoms are refused, everything else is granted" do
      permissions = Authorization.permissions()
      granted = Enum.filter(permissions, &Authorization.role_allows?(:TENANT_ADMIN, &1))
      refused = permissions -- granted

      # Literal: the only two platform-scope core permissions (decision 0046 D2). Not derived from
      # permission_scope/1, so a drift of the scope table is caught here too.
      assert Enum.sort(refused) == Enum.sort([:TenantsManage, :PlatformServicesManage])
      assert length(granted) == length(permissions) - 2
    end

    test "Catalog (module) permissions are granted to TENANT_ADMIN: tenant scope, independent of any manifest role_grants" do
      catalog = Catalog.permissions()
      assert :FixtureRead in catalog

      for permission <- catalog do
        assert Authorization.role_allows?(:TENANT_ADMIN, permission),
               "TENANT_ADMIN must hold the Catalog permission #{inspect(permission)}"
      end

      # The fixture manifest grants :FixtureRead to TASK_WORKER only; TENANT_ADMIN holds it by the
      # tenant-scope rule, not through role_grants.
      refute :TENANT_ADMIN in Map.keys(Letflow.Modules.Fixture.manifest().role_grants)
    end

    test "TENANT_ADMIN holds the tenant-administration permissions the REQ names (literal list)" do
      for permission <- [
            :UsersGroupsRolesManage,
            :TokensManage,
            :RolesManage,
            :AuditRead,
            :TenantSettingsManage,
            :ModulesManage,
            :PromotionsRead,
            :PromotionsManage,
            :DefinitionsRollback
          ] do
        assert Authorization.role_allows?(:TENANT_ADMIN, permission), inspect(permission)
      end
    end
  end

  describe "evaluate_access/2 for TENANT_ADMIN" do
    test ":Unknown is denied, platform_tenant? true or false" do
      for flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_ADMIN], flag), :Unknown).kind ==
                 :Deny403
      end
    end

    test "the router catch-all markers deny TENANT_ADMIN (it gets 403, not the router 404)" do
      for marker <- [:UnmatchedRoute, :UnmatchedPlatformPath], flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_ADMIN], flag), marker).kind ==
                 :Deny403,
               "#{inspect(marker)} platform_tenant?=#{flag}"
      end
    end

    test "TENANT_ADMIN is never allowed a platform-scope permission, with platform_tenant? true or false" do
      for permission <- [:TenantsManage, :PlatformServicesManage], flag <- [true, false] do
        refute Authorization.has_permission_in_scope?([:TENANT_ADMIN], permission, flag),
               "has_permission_in_scope? #{inspect(permission)} flag=#{flag}"
      end

      for key <- [:TenantsManage, :AdminServicesRead, :AdminServicesManage],
          flag <- [true, false] do
        assert Authorization.evaluate_access(ctx([:TENANT_ADMIN], flag), key).kind == :Deny403,
               "#{inspect(key)} platform_tenant?=#{flag}"
      end
    end

    test "a tenant-scope key is allowed with an unfiltered task scope, in and out of the platform tenant" do
      for flag <- [true, false] do
        decision =
          Authorization.evaluate_access(ctx([:TENANT_ADMIN], flag), :TenantSettingsManage)

        assert decision.kind == :Allow
        assert decision.task_scope == :all
      end
    end
  end

  describe "role string parsing" do
    test "roles_from_strings/1 parses TENANT_ADMIN exactly; tenant_admin, Tenant_Admin and padded forms parse to nothing" do
      assert Authorization.roles_from_strings(["TENANT_ADMIN"]) == [:TENANT_ADMIN]

      for variant <- [
            "tenant_admin",
            "Tenant_Admin",
            " TENANT_ADMIN",
            "TENANT_ADMIN ",
            "TENANT-ADMIN",
            ""
          ] do
        assert Authorization.roles_from_strings([variant]) == [], inspect(variant)
      end
    end

    test "TENANT_ADMIN is a built-in role name (the H2 POST /roles guard) but not a platform-admin name" do
      assert Authorization.builtin_role_name?("TENANT_ADMIN")
      refute Authorization.platform_admin_name?("TENANT_ADMIN")
    end
  end

  describe "is_task_worker_only?/1" do
    test "false for TENANT_ADMIN + TASK_WORKER; true for TASK_WORKER alone" do
      refute Authorization.is_task_worker_only?([:TENANT_ADMIN, :TASK_WORKER])
      refute Authorization.is_task_worker_only?([:TASK_WORKER, :TENANT_ADMIN])
      assert Authorization.is_task_worker_only?([:TASK_WORKER])
    end

    test "GET /tasks (:TasksList) is Allow and unfiltered for TENANT_ADMIN + TASK_WORKER, row-filtered for TASK_WORKER alone" do
      admin = Authorization.evaluate_access(ctx([:TENANT_ADMIN, :TASK_WORKER], false), :TasksList)
      assert admin.kind == :Allow
      assert admin.task_scope == :all

      worker = Authorization.evaluate_access(ctx([:TASK_WORKER], false), :TasksList)
      assert worker.kind == :AllowWithRowFilter
      assert worker.task_scope == {:own_user_and_groups, "u-req447"}
    end
  end

  describe "legacy compatibility (PR 1: the C6 switch stays ON)" do
    test "a PLATFORM_ADMIN of a non-platform tenant still holds tenant-scope powers and no platform-scope permission" do
      assert Authorization.tenant_platform_admin_own_tenant_powers?()

      for key <- [:TenantSettingsManage, :PromotionsManage, :DefinitionsRollback] do
        assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], false), key).kind == :Allow,
               inspect(key)
      end

      for key <- [:TenantsManage, :AdminServicesRead, :AdminServicesManage, :Unknown] do
        assert Authorization.evaluate_access(ctx([:PLATFORM_ADMIN], false), key).kind == :Deny403,
               inspect(key)
      end
    end
  end
end
