defmodule Letflow.Api.AuthorizationTest do
  @moduledoc """
  Tests for REQ-069's `Letflow.Api.Authorization` — pure-function acceptance
  criteria (AC1-AC8) plus `roles_from_strings/1`'s untrusted-input conversion.
  AC9 (the real-`AuthPipeline` end-to-end proof) lives in
  `authorization_ac9_test.exs`, a separate `async: false` module, since it needs
  `Letflow.Oidc.ConfigurableTokenVerifierDouble` wired in via a global
  `Application.put_env/3` swap — see that file's moduledoc for why. This module
  needs no database at all (pure functions only), so it stays plain
  `ExUnit.Case, async: true` rather than `Letflow.DataCase`.

  See `lib/letflow/design/req069-authorization.md` §0.7 for the full AC-to-test
  mapping.
  """

  use ExUnit.Case, async: true

  alias Letflow.Api.Authorization
  alias Letflow.Api.Authorization.AccessContext

  describe "acceptance criterion 1 — exact Role and Permission enumeration" do
    test "roles/0 returns exactly R-Co's five Role values" do
      assert Authorization.roles() == [
               :PLATFORM_ADMIN,
               :PROCESS_DESIGNER,
               :PROCESS_OPERATOR,
               :TASK_WORKER,
               :AGENT_RUNNER
             ]
    end

    test "permissions/0 returns exactly R-Co's fourteen Permission values plus REQ-075's :TenantsManage, REQ-076's :RolesManage, REQ-212's :AttachmentsManage/:AttachmentsRead, and ISS-0389's :InstancesAdvanceTimer" do
      assert Authorization.permissions() == [
               :DefinitionsWrite,
               :DefinitionsRead,
               :InstancesStart,
               :InstancesCancel,
               :InstancesRead,
               :TasksRead,
               :TasksComplete,
               :TasksAssign,
               :UsersGroupsRolesManage,
               :TokensManage,
               :AuditRead,
               :DlqOperate,
               :MetricsRead,
               :WebhooksManage,
               :TenantsManage,
               :RolesManage,
               :AttachmentsManage,
               :AttachmentsRead,
               :InstancesAdvanceTimer
             ]
    end
  end

  describe "REQ-075 — :TenantsManage permission/policy key" do
    test "endpoint_policy_key/2 resolves all six tenant-administration routes to :TenantsManage" do
      assert Authorization.endpoint_policy_key("POST", "/tenants") == :TenantsManage
      assert Authorization.endpoint_policy_key("GET", "/tenants") == :TenantsManage
      assert Authorization.endpoint_policy_key("GET", "/tenants/:slug") == :TenantsManage
      assert Authorization.endpoint_policy_key("PATCH", "/tenants/:slug") == :TenantsManage

      assert Authorization.endpoint_policy_key("POST", "/tenants/:slug/deactivate") ==
               :TenantsManage

      assert Authorization.endpoint_policy_key("POST", "/tenants/:slug/reactivate") ==
               :TenantsManage
    end

    test "required_permission(:TenantsManage) is :TenantsManage" do
      assert Authorization.required_permission(:TenantsManage) == :TenantsManage
    end

    test "PLATFORM_ADMIN is granted, every other role is denied" do
      for role <- [:PROCESS_DESIGNER, :PROCESS_OPERATOR, :TASK_WORKER, :AGENT_RUNNER] do
        refute Authorization.role_allows?(role, :TenantsManage),
               "expected #{role} to be denied :TenantsManage"
      end

      assert Authorization.role_allows?(:PLATFORM_ADMIN, :TenantsManage)
    end

    test "evaluate_access/2 grants PLATFORM_ADMIN and denies everyone else" do
      admin_ctx = %AccessContext{user_id: "u1", roles: [:PLATFORM_ADMIN]}

      assert %Authorization.AccessDecision{kind: :Allow} =
               Authorization.evaluate_access(admin_ctx, :TenantsManage)

      other_ctx = %AccessContext{user_id: "u2", roles: [:PROCESS_DESIGNER]}

      assert %Authorization.AccessDecision{kind: :Deny403} =
               Authorization.evaluate_access(other_ctx, :TenantsManage)

      no_roles_ctx = %AccessContext{user_id: "u3", roles: []}

      assert %Authorization.AccessDecision{kind: :Deny403} =
               Authorization.evaluate_access(no_roles_ctx, :TenantsManage)
    end
  end

  describe "acceptance criterion 2 — one test per role, grant + deny" do
    test "PLATFORM_ADMIN grants everything (grants AuditRead, and there is nothing it denies)" do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, :AuditRead)
      assert Authorization.role_allows?(:PLATFORM_ADMIN, :DlqOperate)
    end

    test "PROCESS_DESIGNER grants DefinitionsWrite, denies AuditRead" do
      assert Authorization.role_allows?(:PROCESS_DESIGNER, :DefinitionsWrite)
      refute Authorization.role_allows?(:PROCESS_DESIGNER, :AuditRead)
    end

    test "PROCESS_OPERATOR grants InstancesCancel, denies DefinitionsWrite" do
      assert Authorization.role_allows?(:PROCESS_OPERATOR, :InstancesCancel)
      refute Authorization.role_allows?(:PROCESS_OPERATOR, :DefinitionsWrite)
    end

    test "TASK_WORKER grants TasksComplete, denies InstancesStart" do
      assert Authorization.role_allows?(:TASK_WORKER, :TasksComplete)
      refute Authorization.role_allows?(:TASK_WORKER, :InstancesStart)
    end

    test "AGENT_RUNNER denies everything (denies DefinitionsRead, and there is nothing it grants)" do
      refute Authorization.role_allows?(:AGENT_RUNNER, :DefinitionsRead)
      refute Authorization.role_allows?(:AGENT_RUNNER, :TasksRead)
    end
  end

  describe "acceptance criterion 3 — all three AccessDecisionKind variants reachable" do
    test "Allow is returned for an allowed endpoint" do
      ctx = %AccessContext{user_id: "u1", roles: [:PLATFORM_ADMIN]}
      decision = Authorization.evaluate_access(ctx, :AuditRead)
      assert decision.kind == :Allow
    end

    test "Deny403 is returned for a denied endpoint" do
      ctx = %AccessContext{user_id: "u1", roles: [:TASK_WORKER]}
      decision = Authorization.evaluate_access(ctx, :DefinitionsCreate)
      assert decision.kind == :Deny403
    end

    test "AllowWithRowFilter is returned for TasksList with a TASK_WORKER-only caller" do
      ctx = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER]}
      decision = Authorization.evaluate_access(ctx, :TasksList)
      assert decision.kind == :AllowWithRowFilter
    end
  end

  describe "acceptance criterion 4 — TasksList row-filter vs widening roles (4 tests)" do
    test "TASK_WORKER-only caller gets AllowWithRowFilter with own user id as scope" do
      ctx = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER]}
      decision = Authorization.evaluate_access(ctx, :TasksList)

      assert decision.kind == :AllowWithRowFilter
      assert decision.task_scope == {:own_user_and_groups, "worker-1"}
    end

    test "TASK_WORKER + PLATFORM_ADMIN gets plain Allow with unrestricted scope" do
      ctx = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER, :PLATFORM_ADMIN]}
      decision = Authorization.evaluate_access(ctx, :TasksList)

      assert decision.kind == :Allow
      assert decision.task_scope == :all
    end

    test "TASK_WORKER + PROCESS_DESIGNER gets plain Allow with unrestricted scope" do
      ctx = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER, :PROCESS_DESIGNER]}
      decision = Authorization.evaluate_access(ctx, :TasksList)

      assert decision.kind == :Allow
      assert decision.task_scope == :all
    end

    test "TASK_WORKER + PROCESS_OPERATOR gets plain Allow with unrestricted scope" do
      ctx = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER, :PROCESS_OPERATOR]}
      decision = Authorization.evaluate_access(ctx, :TasksList)

      assert decision.kind == :Allow
      assert decision.task_scope == :all
    end
  end

  describe "acceptance criterion 5 — row scope is authorization-derived, not request-derived (INV-2)" do
    test "evaluate_access/2 has no parameter through which a caller-supplied filter could reach the scope" do
      # Structural proof: evaluate_access/2 takes only (AccessContext, endpoint) — there
      # is nothing named "assignee_id" or "filter" anywhere in its signature or the
      # AccessContext struct for a caller-supplied value to occupy. The decision's scope
      # can only ever come from ctx.user_id, which the CALLER OF THIS MODULE (not the
      # HTTP caller) sets from the AuthPipeline-resolved, DB-backed user id.
      ctx = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER]}
      decision = Authorization.evaluate_access(ctx, :TasksList)

      assert decision.task_scope == {:own_user_and_groups, "worker-1"}
      # No amount of extra data on ctx (there is none to add — the struct is closed via
      # @enforce_keys [:user_id, :roles]) can widen this; a would-be "assignee_id: other"
      # field simply has nowhere to be attached to AccessContext at all.
    end

    test "the scope always tracks ctx.user_id, proving it is context-derived rather than a fixed/default value" do
      ctx_a = %AccessContext{user_id: "worker-1", roles: [:TASK_WORKER]}
      ctx_b = %AccessContext{user_id: "worker-2", roles: [:TASK_WORKER]}

      decision_a = Authorization.evaluate_access(ctx_a, :TasksList)
      decision_b = Authorization.evaluate_access(ctx_b, :TasksList)

      assert decision_a.task_scope == {:own_user_and_groups, "worker-1"}
      assert decision_b.task_scope == {:own_user_and_groups, "worker-2"}
      refute decision_a.task_scope == decision_b.task_scope
    end
  end

  describe "acceptance criterion 6 — no role at all is denied, never defaulted to allow" do
    test "empty roles list is denied a permission-gated endpoint" do
      ctx = %AccessContext{user_id: "u1", roles: []}
      decision = Authorization.evaluate_access(ctx, :DefinitionsRead)
      assert decision.kind == :Deny403
    end

    test "empty roles list is denied even the TasksList row-filtered endpoint" do
      ctx = %AccessContext{user_id: "u1", roles: []}
      decision = Authorization.evaluate_access(ctx, :TasksList)
      assert decision.kind == :Deny403
    end

    test "an unrecognized-only role-string list converts to [] and is denied, never defaulted to allow" do
      # This is the live version of the same bug class: a token whose claim
      # contains only strings this service doesn't recognize as any Role must
      # not silently grant anything.
      assert Authorization.roles_from_strings(["SUPER_ADMIN", "not-a-real-role"]) == []

      ctx = %AccessContext{user_id: "u1", roles: Authorization.roles_from_strings(["bogus"])}
      decision = Authorization.evaluate_access(ctx, :DefinitionsRead)
      assert decision.kind == :Deny403
    end
  end

  describe "ISS-0389 AC3 — InstancesAdvanceTimer role matrix (all four named roles)" do
    # Design doc lib/letflow/design/iss0389-advance-timer-endpoint.md §6 AC3 is a
    # closed four-assertion criterion naming these exact roles; each is asserted
    # directly here (not only indirectly via router-level 200/403 tests) so that a
    # regression in the role's permission list is caught at the unit level.
    test "PROCESS_OPERATOR grants InstancesAdvanceTimer" do
      assert Authorization.role_allows?(:PROCESS_OPERATOR, :InstancesAdvanceTimer)
    end

    test "TASK_WORKER denies InstancesAdvanceTimer" do
      refute Authorization.role_allows?(:TASK_WORKER, :InstancesAdvanceTimer)
    end

    test "AGENT_RUNNER denies InstancesAdvanceTimer" do
      refute Authorization.role_allows?(:AGENT_RUNNER, :InstancesAdvanceTimer)
    end

    test "PLATFORM_ADMIN grants InstancesAdvanceTimer" do
      assert Authorization.role_allows?(:PLATFORM_ADMIN, :InstancesAdvanceTimer)
    end
  end

  describe "roles_from_strings/1 — untrusted-input conversion (§0.2)" do
    test "recognizes all five real role-name strings" do
      assert Authorization.roles_from_strings([
               "PLATFORM_ADMIN",
               "PROCESS_DESIGNER",
               "PROCESS_OPERATOR",
               "TASK_WORKER",
               "AGENT_RUNNER"
             ]) ==
               [
                 :PLATFORM_ADMIN,
                 :PROCESS_DESIGNER,
                 :PROCESS_OPERATOR,
                 :TASK_WORKER,
                 :AGENT_RUNNER
               ]
    end

    test "drops unrecognized strings without raising" do
      assert Authorization.roles_from_strings(["PLATFORM_ADMIN", "not-a-role", ""]) == [
               :PLATFORM_ADMIN
             ]
    end

    test "never raises on garbage input (empty strings, duplicates, mixed case)" do
      assert Authorization.roles_from_strings([]) == []
      assert Authorization.roles_from_strings([""]) == []
      assert Authorization.roles_from_strings(["platform_admin"]) == []

      assert Authorization.roles_from_strings(["PLATFORM_ADMIN", "PLATFORM_ADMIN"]) == [
               :PLATFORM_ADMIN
             ]
    end
  end

  describe "acceptance criteria 7/8 — moduledoc content assertions" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, %{"en" => moduledoc}, _meta, _fn_docs} =
        Code.fetch_docs(Letflow.Api.Authorization)

      %{moduledoc: moduledoc}
    end

    test "AC7 — moduledoc names AGENT_RUNNER, DlqOperate and WebhooksManage as ported-but-unreachable",
         %{moduledoc: moduledoc} do
      assert moduledoc =~ "AGENT_RUNNER"
      assert moduledoc =~ "DlqOperate"
      assert moduledoc =~ "WebhooksManage"
      assert moduledoc =~ "S4 route consumer"
    end

    test "AC8 — moduledoc states the 403-vs-404 rule explicitly (INV-5)", %{moduledoc: moduledoc} do
      assert moduledoc =~ "INV-5"
      assert moduledoc =~ "404"
      assert moduledoc =~ "Deny403"
    end
  end
end
