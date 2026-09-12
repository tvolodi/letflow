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

    test "permissions/0 returns exactly R-Co's fourteen Permission values plus REQ-075's :TenantsManage, REQ-076's :RolesManage, REQ-212's :AttachmentsManage/:AttachmentsRead, ISS-0389's :InstancesAdvanceTimer, REQ-309's four Entities* permissions, REQ-315's :EntitiesAggregate, REQ-318's three entity-record export/import permissions, and REQ-317's :EntitiesAttachmentsManage/:EntitiesAttachmentsRead" do
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
               :InstancesAdvanceTimer,
               :EntitiesDefinitionsRead,
               :EntitiesDefinitionsWrite,
               :EntitiesRecordsWrite,
               :EntitiesQuery,
               :EntitiesAggregate,
               :EntitiesRecordsExport,
               :EntitiesRecordsExportUnredacted,
               :EntitiesRecordsImport,
               :EntitiesAttachmentsManage,
               :EntitiesAttachmentsRead
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

  # ==========================================================================
  # REQ-309 — the four entity-subsystem permissions
  # (design lib/letflow/design/req308-entity-http-surface.md §1 route table,
  # §3 permission vocabulary + role matrix).
  # ==========================================================================

  @req309_permissions [
    :EntitiesDefinitionsRead,
    :EntitiesDefinitionsWrite,
    :EntitiesRecordsWrite,
    :EntitiesQuery
  ]

  describe "REQ-309 AC1 — permissions/0 contains the four new atoms and the @doc count is computed, not hardcoded" do
    test "permissions/0 contains all four new atoms" do
      for permission <- @req309_permissions do
        assert permission in Authorization.permissions(),
               "expected permissions/0 to contain #{inspect(permission)}"
      end
    end

    test "the permissions/0 @doc's stated count equals length(permissions()) exactly" do
      # The count is DERIVED from the live list and then spelled out in English,
      # then looked for in the real @doc string. Nothing here hardcodes 23: add
      # or remove a permission without touching the @doc and this fails.
      {:docs_v1, _anno, _lang, _fmt, _moduledoc, _meta, fn_docs} =
        Code.fetch_docs(Letflow.Api.Authorization)

      permissions_doc =
        Enum.find_value(fn_docs, fn
          {{:function, :permissions, 0}, _anno, _sig, %{"en" => doc}, _meta} -> doc
          _ -> nil
        end)

      assert is_binary(permissions_doc),
             "expected permissions/0 to carry a @doc string"

      actual_count = length(Authorization.permissions())

      spelled =
        %{
          14 => "fourteen",
          15 => "fifteen",
          16 => "sixteen",
          17 => "seventeen",
          18 => "eighteen",
          19 => "nineteen",
          20 => "twenty",
          21 => "twenty-one",
          22 => "twenty-two",
          23 => "twenty-three",
          24 => "twenty-four",
          25 => "twenty-five",
          26 => "twenty-six",
          27 => "twenty-seven",
          28 => "twenty-eight",
          29 => "twenty-nine"
        }
        |> Map.get(actual_count)

      assert is_binary(spelled),
             "permissions/0 now returns #{actual_count} entries, outside this test's " <>
               "number-word table -- extend the table (and the @doc) rather than deleting " <>
               "this assertion"

      assert permissions_doc =~ "All #{spelled} `Permission` values",
             """
             permissions/0's @doc does not state the live count.
             permissions/0 currently returns #{actual_count} entries, so the @doc must \
             open with "All #{spelled} `Permission` values". Actual @doc:

             #{permissions_doc}
             """
    end

    test "permissions/0 has no duplicate entries" do
      permissions = Authorization.permissions()
      assert permissions == Enum.uniq(permissions)
    end

    test "there is deliberately no :EntitiesRecordsRead atom (design §3 — record reads happen only via :EntitiesQuery)" do
      refute :EntitiesRecordsRead in Authorization.permissions()
    end
  end

  describe "REQ-309 AC2 — endpoint_policy_key/2 for all ten routes in design §1's route table" do
    # Full external paths, i.e. as seen after the /api/v1 prefix is stripped --
    # `Letflow.Routers.Entities` is mounted at /entities (design §2), so these
    # are the mount prefix "/entities" <> each router-local match pattern, the
    # same composition authorization_enforcement_test.exs's own full_path/2
    # helper performs.
    test "1/10 — POST /entities/definitions -> :EntitiesDefinitionsWrite" do
      assert Authorization.endpoint_policy_key("POST", "/entities/definitions") ==
               :EntitiesDefinitionsWrite
    end

    test "2/10 — GET /entities/definitions -> :EntitiesDefinitionsRead" do
      assert Authorization.endpoint_policy_key("GET", "/entities/definitions") ==
               :EntitiesDefinitionsRead
    end

    test "3/10 — GET /entities/definitions/active/:name -> :EntitiesDefinitionsRead" do
      assert Authorization.endpoint_policy_key("GET", "/entities/definitions/active/:name") ==
               :EntitiesDefinitionsRead
    end

    test "4/10 — GET /entities/definitions/by-name/:name -> :EntitiesDefinitionsRead" do
      assert Authorization.endpoint_policy_key("GET", "/entities/definitions/by-name/:name") ==
               :EntitiesDefinitionsRead
    end

    test "5/10 — GET /entities/definitions/:id -> :EntitiesDefinitionsRead" do
      assert Authorization.endpoint_policy_key("GET", "/entities/definitions/:id") ==
               :EntitiesDefinitionsRead
    end

    test "6/10 — POST /entities/definitions/:name/activate -> :EntitiesDefinitionsWrite" do
      assert Authorization.endpoint_policy_key("POST", "/entities/definitions/:name/activate") ==
               :EntitiesDefinitionsWrite
    end

    test "7/10 — POST /entities/records/:entity_type -> :EntitiesRecordsWrite" do
      assert Authorization.endpoint_policy_key("POST", "/entities/records/:entity_type") ==
               :EntitiesRecordsWrite
    end

    test "8/10 — PUT /entities/records/:entity_type/:record_id -> :EntitiesRecordsWrite" do
      assert Authorization.endpoint_policy_key("PUT", "/entities/records/:entity_type/:record_id") ==
               :EntitiesRecordsWrite
    end

    test "9/10 — DELETE /entities/records/:entity_type/:record_id -> :EntitiesRecordsWrite" do
      assert Authorization.endpoint_policy_key(
               "DELETE",
               "/entities/records/:entity_type/:record_id"
             ) == :EntitiesRecordsWrite
    end

    test "10/10 — POST /entities/query -> :EntitiesQuery" do
      assert Authorization.endpoint_policy_key("POST", "/entities/query") == :EntitiesQuery
    end

    test "none of the ten routes resolves to :Unknown" do
      routes = [
        {"POST", "/entities/definitions"},
        {"GET", "/entities/definitions"},
        {"GET", "/entities/definitions/active/:name"},
        {"GET", "/entities/definitions/by-name/:name"},
        {"GET", "/entities/definitions/:id"},
        {"POST", "/entities/definitions/:name/activate"},
        {"POST", "/entities/records/:entity_type"},
        {"PUT", "/entities/records/:entity_type/:record_id"},
        {"DELETE", "/entities/records/:entity_type/:record_id"},
        {"POST", "/entities/query"}
      ]

      assert length(routes) == 10

      for {method, path} <- routes do
        key = Authorization.endpoint_policy_key(method, path)

        refute key == :Unknown,
               "#{method} #{path} resolved to :Unknown -- a route declaring its policy key " <>
                 "would fail authorization_enforcement_test.exs"
      end
    end

    test "the new clauses did not widen /entities matching -- an undeclared /entities path is still :Unknown" do
      assert Authorization.endpoint_policy_key("GET", "/entities") == :Unknown
      assert Authorization.endpoint_policy_key("GET", "/entities/query") == :Unknown
      assert Authorization.endpoint_policy_key("DELETE", "/entities/definitions/:id") == :Unknown

      assert Authorization.endpoint_policy_key("GET", "/entities/records/:entity_type") ==
               :Unknown
    end
  end

  describe "REQ-309 AC3 — required_permission/1 identity mapping for the four new policy keys" do
    for permission <- [
          :EntitiesDefinitionsRead,
          :EntitiesDefinitionsWrite,
          :EntitiesRecordsWrite,
          :EntitiesQuery
        ] do
      @permission permission

      test "required_permission(#{inspect(permission)}) == #{inspect(permission)}" do
        assert Authorization.required_permission(@permission) == @permission
      end
    end
  end

  describe "REQ-309 AC4 — the exact 4-permission x 5-role grid from design §3's role-matrix table" do
    # Written out literally, exactly as design §3's table reads. Twenty pairs.
    @new_permission_grid %{
      PLATFORM_ADMIN: %{
        EntitiesDefinitionsRead: true,
        EntitiesDefinitionsWrite: true,
        EntitiesRecordsWrite: true,
        EntitiesQuery: true
      },
      PROCESS_DESIGNER: %{
        EntitiesDefinitionsRead: true,
        EntitiesDefinitionsWrite: true,
        EntitiesRecordsWrite: false,
        EntitiesQuery: true
      },
      PROCESS_OPERATOR: %{
        EntitiesDefinitionsRead: true,
        EntitiesDefinitionsWrite: false,
        EntitiesRecordsWrite: true,
        EntitiesQuery: true
      },
      TASK_WORKER: %{
        EntitiesDefinitionsRead: true,
        EntitiesDefinitionsWrite: false,
        EntitiesRecordsWrite: false,
        EntitiesQuery: true
      },
      AGENT_RUNNER: %{
        EntitiesDefinitionsRead: false,
        EntitiesDefinitionsWrite: false,
        EntitiesRecordsWrite: false,
        EntitiesQuery: false
      }
    }

    test "the grid covers every role x every new permission -- 20 pairs, none missing" do
      assert Map.keys(@new_permission_grid) |> Enum.sort() ==
               Authorization.roles() |> Enum.sort()

      pairs =
        for {_role, by_permission} <- @new_permission_grid,
            {permission, _} <- by_permission,
            do: permission

      assert length(pairs) == 20

      for {role, by_permission} <- @new_permission_grid do
        assert Enum.sort(Map.keys(by_permission)) == Enum.sort(@req309_permissions),
               "grid row for #{role} does not name exactly the four new permissions"
      end
    end

    test "role_allows?/2 matches the grid for all 20 role/permission pairs" do
      for {role, by_permission} <- @new_permission_grid,
          {permission, expected} <- by_permission do
        actual = Authorization.role_allows?(role, permission)

        assert actual == expected,
               "role_allows?(#{inspect(role)}, #{inspect(permission)}) returned " <>
                 "#{inspect(actual)}, design §3's role matrix says #{inspect(expected)}"
      end
    end

    test "evaluate_access/2 agrees with the grid end-to-end (policy key -> permission -> role)" do
      # Guards against the four new permissions being right in role_allows?/2 but
      # unreachable through evaluate_access/2 (e.g. a missing
      # required_permission/1 clause), which is the path Letflow.Plugs.Authorize
      # actually takes at request time.
      for {role, by_permission} <- @new_permission_grid,
          {policy_key, expected_allowed} <- by_permission do
        ctx = %AccessContext{user_id: "u-#{role}", roles: [role]}
        decision = Authorization.evaluate_access(ctx, policy_key)
        expected_kind = if expected_allowed, do: :Allow, else: :Deny403

        assert decision.kind == expected_kind,
               "evaluate_access(roles: [#{inspect(role)}], #{inspect(policy_key)}) returned " <>
                 "#{inspect(decision.kind)}, expected #{inspect(expected_kind)}"
      end
    end
  end

  describe "REQ-309 AC5 — regression grid: no PRE-EXISTING role/permission pair changed" do
    # THE POINT OF THIS BLOCK. Every one of the nineteen permissions that
    # existed before REQ-309, crossed with all five roles: 95 pairs, each
    # expected value transcribed by hand from `lib/letflow/api/authorization.ex`
    # as it stood at commit 09b77692 (before this change). It is deliberately
    # NOT derived from the module under test in any way -- not from
    # Authorization.permissions(), not from role_allows?/2, not by filtering the
    # live list. If an existing permission were added to or removed from any
    # role's list by this change, the corresponding cell here disagrees and the
    # test fails.
    @pre_req309_permissions [
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

    # role => the EXACT set of pre-REQ-309 permissions that role was allowed
    # before this change. PLATFORM_ADMIN: all nineteen (catch-all `do: true`).
    # AGENT_RUNNER: none (catch-all `do: false`). The other three are the
    # literal `permission in [...]` lists as they read before REQ-309 appended
    # to them.
    @pre_req309_allowed %{
      PLATFORM_ADMIN: @pre_req309_permissions,
      PROCESS_DESIGNER: [
        :DefinitionsWrite,
        :DefinitionsRead,
        :InstancesStart,
        :InstancesRead,
        :TasksRead,
        :RolesManage,
        :AttachmentsRead
      ],
      PROCESS_OPERATOR: [
        :DefinitionsRead,
        :InstancesStart,
        :InstancesCancel,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :TasksAssign,
        :AuditRead,
        :DlqOperate,
        :MetricsRead,
        :WebhooksManage,
        :AttachmentsManage,
        :AttachmentsRead,
        :InstancesAdvanceTimer
      ],
      TASK_WORKER: [
        :DefinitionsRead,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :AttachmentsRead
      ],
      AGENT_RUNNER: []
    }

    test "the regression grid is complete: 5 roles x 19 pre-existing permissions = 95 pairs" do
      assert length(@pre_req309_permissions) == 19
      assert Enum.sort(Map.keys(@pre_req309_allowed)) == Enum.sort(Authorization.roles())

      # Every expectation named is a real permission, and no pre-existing
      # permission was dropped from the module's own list by this change.
      live = Authorization.permissions()

      for permission <- @pre_req309_permissions do
        assert permission in live,
               "#{inspect(permission)} existed before REQ-309 but is no longer in " <>
                 "permissions/0 -- a permission was REMOVED, not added"
      end

      # The live list STARTS WITH the pre-existing nineteen plus REQ-309's
      # four, in that order: proves REQ-309's own change was purely an append.
      # A prefix check (not exact equality) is deliberate here -- REQ-315 and
      # REQ-318 (later requirements) append further permissions after these
      # (REQ-315's :EntitiesAggregate, then REQ-318's three entity-record
      # export/import atoms), and this test asserts only what REQ-309 itself
      # is responsible for.
      expected_prefix = @pre_req309_permissions ++ @req309_permissions
      assert Enum.take(live, length(expected_prefix)) == expected_prefix

      pair_count = length(Authorization.roles()) * length(@pre_req309_permissions)
      assert pair_count == 95
    end

    test "all 95 pre-existing role/permission pairs return exactly what they returned before REQ-309" do
      for role <- [
            :PLATFORM_ADMIN,
            :PROCESS_DESIGNER,
            :PROCESS_OPERATOR,
            :TASK_WORKER,
            :AGENT_RUNNER
          ],
          permission <- @pre_req309_permissions do
        expected = permission in Map.fetch!(@pre_req309_allowed, role)
        actual = Authorization.role_allows?(role, permission)

        assert actual == expected,
               "REGRESSION: role_allows?(#{inspect(role)}, #{inspect(permission)}) is now " <>
                 "#{inspect(actual)} but was #{inspect(expected)} before REQ-309. This " <>
                 "change must be purely additive -- no existing role/permission pair may " <>
                 "change hands."
      end
    end

    test "required_permission/1 still returns exactly what it returned before REQ-309 for every pre-existing policy key" do
      # The second half of "no existing behaviour changed": a new clause
      # inserted in the wrong place could shadow an existing one. Every
      # pre-existing endpoint_policy_key -> permission mapping, transcribed from
      # the module as it stood before this change.
      expected = [
        {:DefinitionsCreate, :DefinitionsWrite},
        {:DefinitionsUpdate, :DefinitionsWrite},
        {:DefinitionsPatch, :DefinitionsWrite},
        {:DefinitionsActivate, :DefinitionsWrite},
        {:DefinitionsDeprecate, :DefinitionsWrite},
        {:DefinitionsArchive, :DefinitionsWrite},
        {:DefinitionsDelete, :DefinitionsWrite},
        {:DefinitionsImport, :DefinitionsWrite},
        {:DefinitionsRead, :DefinitionsRead},
        {:InstancesStart, :InstancesStart},
        {:InstancesCancel, :InstancesCancel},
        {:InstancesRead, :InstancesRead},
        {:InstancesAdvanceTimer, :InstancesAdvanceTimer},
        {:TasksList, :TasksRead},
        {:TasksGetById, :TasksRead},
        {:TasksComplete, :TasksComplete},
        {:TasksAssign, :TasksAssign},
        {:TasksReassign, :TasksAssign},
        {:UsersManage, :UsersGroupsRolesManage},
        {:GroupsManage, :UsersGroupsRolesManage},
        {:TokensManage, :TokensManage},
        {:AuditRead, :AuditRead},
        {:DlqReadRetryDiscard, :DlqOperate},
        {:MetricsRead, :MetricsRead},
        {:WebhookSubscriptionsManage, :WebhooksManage},
        {:ServicesRead, :DefinitionsRead},
        {:AdminServicesManage, :UsersGroupsRolesManage},
        {:AdminServicesRead, :UsersGroupsRolesManage},
        {:TenantsManage, :TenantsManage},
        {:RolesManage, :RolesManage},
        {:AttachmentsManage, :AttachmentsManage},
        {:AttachmentsRead, :AttachmentsRead},
        {:Unknown, :MetricsRead}
      ]

      for {key, permission} <- expected do
        assert Authorization.required_permission(key) == permission,
               "REGRESSION: required_permission(#{inspect(key)}) changed"
      end
    end

    test "endpoint_policy_key/2 still returns exactly what it returned before REQ-309 for a representative route from every existing family" do
      # One route per pre-existing clause family: a mis-ordered new clause (e.g.
      # a too-greedy "/entities" <> _rest pattern placed above these) would
      # shadow one of them and flip it to a different key or :Unknown.
      expected = [
        {"POST", "/definitions", :DefinitionsCreate},
        {"PUT", "/definitions/:id", :DefinitionsUpdate},
        {"PATCH", "/definitions/:id", :DefinitionsPatch},
        {"POST", "/definitions/:id/activate", :DefinitionsActivate},
        {"POST", "/definitions/:id/deprecate", :DefinitionsDeprecate},
        {"POST", "/definitions/:id/archive", :DefinitionsArchive},
        {"DELETE", "/definitions/:id", :DefinitionsDelete},
        {"POST", "/definitions/import", :DefinitionsImport},
        {"GET", "/definitions", :DefinitionsRead},
        {"GET", "/definitions/:id", :DefinitionsRead},
        {"GET", "/definitions/active/:name", :DefinitionsRead},
        {"GET", "/definitions/search", :DefinitionsRead},
        {"GET", "/definitions/:id/export", :DefinitionsRead},
        {"GET", "/definitions/delta", :DefinitionsRead},
        {"POST", "/instances", :InstancesStart},
        {"POST", "/instances/:id/cancel", :InstancesCancel},
        {"POST", "/instances/:id/advance-timer", :InstancesAdvanceTimer},
        {"GET", "/instances", :InstancesRead},
        {"GET", "/instances/:id", :InstancesRead},
        {"GET", "/instances/:id/history", :InstancesRead},
        {"GET", "/instances/:id/timeline", :InstancesRead},
        {"GET", "/instances/:id/pins", :InstancesRead},
        {"GET", "/tasks", :TasksList},
        {"GET", "/tasks/inbox", :TasksList},
        {"GET", "/tasks/:id", :TasksGetById},
        {"POST", "/tasks/:id/complete", :TasksComplete},
        {"POST", "/tasks/:id/claim", :TasksComplete},
        {"POST", "/tasks/:id/assign", :TasksAssign},
        {"POST", "/tasks/:id/reassign", :TasksReassign},
        {"POST", "/users", :UsersManage},
        {"GET", "/users", :UsersManage},
        {"GET", "/users/:id", :UsersManage},
        {"PATCH", "/users/:id", :UsersManage},
        {"POST", "/users/:id/status", :UsersManage},
        {"POST", "/groups", :GroupsManage},
        {"GET", "/groups", :GroupsManage},
        {"DELETE", "/groups/:id", :GroupsManage},
        {"POST", "/tokens", :TokensManage},
        {"GET", "/tokens", :TokensManage},
        {"DELETE", "/tokens/:id", :TokensManage},
        {"GET", "/audit", :AuditRead},
        {"GET", "/dlq", :DlqReadRetryDiscard},
        {"POST", "/dlq/:id/retry", :DlqReadRetryDiscard},
        {"GET", "/metrics", :MetricsRead},
        {"POST", "/webhooks/subscriptions", :WebhookSubscriptionsManage},
        {"GET", "/webhooks/subscriptions", :WebhookSubscriptionsManage},
        {"PATCH", "/webhooks/subscriptions/:id", :WebhookSubscriptionsManage},
        {"DELETE", "/webhooks/subscriptions/:id", :WebhookSubscriptionsManage},
        {"GET", "/webhooks/subscriptions/:id/deliveries", :WebhookSubscriptionsManage},
        {"GET", "/services", :ServicesRead},
        {"GET", "/admin/services", :AdminServicesRead},
        {"POST", "/admin/services", :AdminServicesManage},
        {"PATCH", "/admin/services/:id", :AdminServicesManage},
        {"DELETE", "/admin/services/:id", :AdminServicesManage},
        {"POST", "/tenants", :TenantsManage},
        {"GET", "/tenants", :TenantsManage},
        {"GET", "/tenants/:slug", :TenantsManage},
        {"PATCH", "/tenants/:slug", :TenantsManage},
        {"POST", "/tenants/:slug/deactivate", :TenantsManage},
        {"POST", "/tenants/:slug/reactivate", :TenantsManage},
        {"POST", "/onboarding", :TenantsManage},
        {"GET", "/onboarding", :TenantsManage},
        {"GET", "/onboarding/:id", :TenantsManage},
        {"GET", "/roles", :RolesManage},
        {"POST", "/roles", :RolesManage},
        {"POST", "/instances/:id/attachments", :AttachmentsManage},
        {"DELETE", "/instances/:id/attachments/:attachment_id", :AttachmentsManage},
        {"GET", "/instances/:id/attachments", :AttachmentsRead},
        {"GET", "/instances/:id/attachments/:attachment_id", :AttachmentsRead},
        {"POST", "/definitions/:id/validate", :Unknown},
        {"POST", "/instances/:id/rebind-pins", :Unknown},
        {"GET", "/nope", :Unknown}
      ]

      for {method, path, key} <- expected do
        assert Authorization.endpoint_policy_key(method, path) == key,
               "REGRESSION: endpoint_policy_key(#{inspect(method)}, #{inspect(path)}) changed"
      end
    end
  end

  # ==========================================================================
  # REQ-315 — the aggregation/reporting query route's new permission,
  # :EntitiesAggregate (design lib/letflow/design/req312-query-aggregation.md
  # §3's role matrix).
  # ==========================================================================

  describe "REQ-315 AC1 — permissions/0 contains :EntitiesAggregate, @doc count matches, endpoint_policy_key resolves" do
    test "permissions/0 contains :EntitiesAggregate" do
      assert :EntitiesAggregate in Authorization.permissions()
    end

    test "the permissions/0 @doc's stated count equals length(permissions()) exactly" do
      {:docs_v1, _anno, _lang, _fmt, _moduledoc, _meta, fn_docs} =
        Code.fetch_docs(Letflow.Api.Authorization)

      permissions_doc =
        Enum.find_value(fn_docs, fn
          {{:function, :permissions, 0}, _anno, _sig, %{"en" => doc}, _meta} -> doc
          _ -> nil
        end)

      actual_count = length(Authorization.permissions())

      spelled =
        %{
          20 => "twenty",
          21 => "twenty-one",
          22 => "twenty-two",
          23 => "twenty-three",
          24 => "twenty-four",
          25 => "twenty-five",
          26 => "twenty-six",
          27 => "twenty-seven",
          28 => "twenty-eight",
          29 => "twenty-nine"
        }
        |> Map.get(actual_count)

      assert is_binary(spelled),
             "permissions/0 now returns #{actual_count} entries, outside this test's " <>
               "number-word table -- extend the table (and the @doc) rather than deleting " <>
               "this assertion"

      assert permissions_doc =~ "All #{spelled} `Permission` values",
             """
             permissions/0's @doc does not state the live count.
             permissions/0 currently returns #{actual_count} entries, so the @doc must \
             open with "All #{spelled} `Permission` values". Actual @doc:

             #{permissions_doc}
             """
    end

    test "endpoint_policy_key(\"POST\", \"/entities/query/aggregate\") returns :EntitiesAggregate, never :Unknown" do
      key = Authorization.endpoint_policy_key("POST", "/entities/query/aggregate")
      assert key == :EntitiesAggregate
      refute key == :Unknown
    end

    test "required_permission(:EntitiesAggregate) == :EntitiesAggregate" do
      assert Authorization.required_permission(:EntitiesAggregate) == :EntitiesAggregate
    end
  end

  describe "REQ-315 AC2 — role matrix: PROCESS_DESIGNER/PROCESS_OPERATOR/TASK_WORKER gain :EntitiesAggregate, mirroring :EntitiesQuery" do
    @req315_grid %{
      PLATFORM_ADMIN: true,
      PROCESS_DESIGNER: true,
      PROCESS_OPERATOR: true,
      TASK_WORKER: true,
      AGENT_RUNNER: false
    }

    test "role_allows?/2 matches the grid for all 5 roles" do
      for {role, expected} <- @req315_grid do
        actual = Authorization.role_allows?(role, :EntitiesAggregate)

        assert actual == expected,
               "role_allows?(#{inspect(role)}, :EntitiesAggregate) returned #{inspect(actual)}, " <>
                 "design §3's role matrix says #{inspect(expected)}"
      end
    end

    test "every role holding :EntitiesQuery also holds :EntitiesAggregate, and vice versa" do
      for role <- Authorization.roles() do
        assert Authorization.role_allows?(role, :EntitiesQuery) ==
                 Authorization.role_allows?(role, :EntitiesAggregate),
               "#{inspect(role)}'s :EntitiesQuery/:EntitiesAggregate grants disagree"
      end
    end

    test "evaluate_access/2 agrees with the grid end-to-end" do
      for {role, expected_allowed} <- @req315_grid do
        ctx = %AccessContext{user_id: "u-#{role}", roles: [role]}
        decision = Authorization.evaluate_access(ctx, :EntitiesAggregate)
        expected_kind = if expected_allowed, do: :Allow, else: :Deny403

        assert decision.kind == expected_kind,
               "evaluate_access(roles: [#{inspect(role)}], :EntitiesAggregate) returned " <>
                 "#{inspect(decision.kind)}, expected #{inspect(expected_kind)}"
      end
    end
  end

  describe "REQ-315 AC3 — regression grid: no PRE-EXISTING role/permission pair changed" do
    # Every permission that existed before REQ-315 (the pre-REQ-309 nineteen
    # plus REQ-309's own four), crossed with all five roles: 115 pairs. Same
    # discipline as REQ-309's own AC5 above -- transcribed by hand from this
    # module as it stood immediately before REQ-315, NOT derived from the
    # module under test.
    @pre_req315_permissions [
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
      :InstancesAdvanceTimer,
      :EntitiesDefinitionsRead,
      :EntitiesDefinitionsWrite,
      :EntitiesRecordsWrite,
      :EntitiesQuery
    ]

    @pre_req315_allowed %{
      PLATFORM_ADMIN: @pre_req315_permissions,
      PROCESS_DESIGNER: [
        :DefinitionsWrite,
        :DefinitionsRead,
        :InstancesStart,
        :InstancesRead,
        :TasksRead,
        :RolesManage,
        :AttachmentsRead,
        :EntitiesDefinitionsRead,
        :EntitiesDefinitionsWrite,
        :EntitiesQuery
      ],
      PROCESS_OPERATOR: [
        :DefinitionsRead,
        :InstancesStart,
        :InstancesCancel,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :TasksAssign,
        :AuditRead,
        :DlqOperate,
        :MetricsRead,
        :WebhooksManage,
        :AttachmentsManage,
        :AttachmentsRead,
        :InstancesAdvanceTimer,
        :EntitiesDefinitionsRead,
        :EntitiesRecordsWrite,
        :EntitiesQuery
      ],
      TASK_WORKER: [
        :DefinitionsRead,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :AttachmentsRead,
        :EntitiesDefinitionsRead,
        :EntitiesQuery
      ],
      AGENT_RUNNER: []
    }

    test "the regression grid is complete: 5 roles x 23 pre-existing permissions = 115 pairs" do
      assert length(@pre_req315_permissions) == 23
      assert Enum.sort(Map.keys(@pre_req315_allowed)) == Enum.sort(Authorization.roles())

      live = Authorization.permissions()

      for permission <- @pre_req315_permissions do
        assert permission in live,
               "#{inspect(permission)} existed before REQ-315 but is no longer in " <>
                 "permissions/0 -- a permission was REMOVED, not added"
      end

      # The live list STARTS WITH the pre-existing twenty-three plus REQ-315's
      # one, in that order: proves REQ-315's own change was purely an append.
      # A prefix check (not exact equality) is deliberate here -- REQ-318 and
      # REQ-317 (both later requirements) each append more permissions after
      # these, and this test asserts only what REQ-315 itself is responsible
      # for.
      expected_prefix = @pre_req315_permissions ++ [:EntitiesAggregate]
      assert Enum.take(live, length(expected_prefix)) == expected_prefix

      pair_count = length(Authorization.roles()) * length(@pre_req315_permissions)
      assert pair_count == 115
    end

    test "all 115 pre-existing role/permission pairs return exactly what they returned before REQ-315" do
      for role <- [
            :PLATFORM_ADMIN,
            :PROCESS_DESIGNER,
            :PROCESS_OPERATOR,
            :TASK_WORKER,
            :AGENT_RUNNER
          ],
          permission <- @pre_req315_permissions do
        expected = permission in Map.fetch!(@pre_req315_allowed, role)
        actual = Authorization.role_allows?(role, permission)

        assert actual == expected,
               "REGRESSION: role_allows?(#{inspect(role)}, #{inspect(permission)}) is now " <>
                 "#{inspect(actual)} but was #{inspect(expected)} before REQ-315. This " <>
                 "change must be purely additive -- no existing role/permission pair may " <>
                 "change hands."
      end
    end

    test "required_permission/1 and endpoint_policy_key/2 are unchanged for the pre-existing entity-subsystem routes" do
      assert Authorization.endpoint_policy_key("POST", "/entities/query") == :EntitiesQuery
      assert Authorization.required_permission(:EntitiesQuery) == :EntitiesQuery

      assert Authorization.endpoint_policy_key("POST", "/entities/records/:entity_type") ==
               :EntitiesRecordsWrite
    end

    test "an undeclared /entities path is still :Unknown, and the new clause did not widen matching" do
      assert Authorization.endpoint_policy_key("GET", "/entities/query/aggregate") == :Unknown

      assert Authorization.endpoint_policy_key("POST", "/entities/query/aggregate/extra") ==
               :Unknown
    end
  end

  # ==========================================================================
  # REQ-318 — the three entity-record export/import permission atoms
  # (design lib/letflow/design/req314-entity-record-bulk-export-import.md §5,
  # governing verdict: the "SECURITY-REVIEWER Final Verdict (re-check after
  # §5/§6 rework)" section). This requirement mints the vocabulary only —
  # REQ-319/REQ-320 add the routes/handlers that consume it.
  # ==========================================================================

  @req318_permissions [
    :EntitiesRecordsExport,
    :EntitiesRecordsExportUnredacted,
    :EntitiesRecordsImport
  ]

  # REQ-317 — the two record-attachment permissions, :EntitiesAttachmentsManage
  # / :EntitiesAttachmentsRead (design
  # lib/letflow/design/req313-entity-record-attachments.md §4's permission
  # vocabulary, §7 OQ-2's role-matrix proposal). Landed on main after REQ-318
  # (see this module's own moduledoc for the append order), so this atom pair
  # sits at the tail of permissions/0, after REQ-318's three.
  @req317_permissions [:EntitiesAttachmentsManage, :EntitiesAttachmentsRead]

  describe "REQ-318 AC1 — permissions/0 includes all three new atoms" do
    test "permissions/0 contains :EntitiesRecordsExport, :EntitiesRecordsExportUnredacted and :EntitiesRecordsImport" do
      for permission <- @req318_permissions do
        assert permission in Authorization.permissions(),
               "expected permissions/0 to contain #{inspect(permission)}"
      end
    end

    test "permissions/0 has no duplicate entries after the append" do
      permissions = Authorization.permissions()
      assert permissions == Enum.uniq(permissions)
    end

    # The generic "@doc count equals length(permissions())" test already lives
    # in acceptance-criteria-7/8's describe block above and is computed (not
    # hardcoded), so it automatically re-verifies against the new, larger
    # count once these three atoms are appended -- no separate test needed
    # here to duplicate that assertion.
  end

  describe "REQ-318 AC2 — endpoint_policy_key/2 for both real routes, never :Unknown" do
    test "POST /entities/records/:entity_type/export -> :EntitiesRecordsExport" do
      assert Authorization.endpoint_policy_key(
               "POST",
               "/entities/records/:entity_type/export"
             ) == :EntitiesRecordsExport
    end

    test "POST /entities/records/:entity_type/import -> :EntitiesRecordsImport" do
      assert Authorization.endpoint_policy_key(
               "POST",
               "/entities/records/:entity_type/import"
             ) == :EntitiesRecordsImport
    end

    test "neither route resolves to :Unknown" do
      refute Authorization.endpoint_policy_key("POST", "/entities/records/:entity_type/export") ==
               :Unknown

      refute Authorization.endpoint_policy_key("POST", "/entities/records/:entity_type/import") ==
               :Unknown
    end

    test "the new clauses did not widen matching -- a similar but different path is still :Unknown" do
      assert Authorization.endpoint_policy_key("GET", "/entities/records/:entity_type/export") ==
               :Unknown

      assert Authorization.endpoint_policy_key("GET", "/entities/records/:entity_type/import") ==
               :Unknown

      assert Authorization.endpoint_policy_key(
               "POST",
               "/entities/records/:entity_type/exports"
             ) == :Unknown

      assert Authorization.endpoint_policy_key("DELETE", "/entities/records/:entity_type/export") ==
               :Unknown
    end
  end

  describe "REQ-318 AC3 — :EntitiesRecordsExportUnredacted is never route-derived" do
    test "no (method, path) pair among every route this module knows about resolves to :EntitiesRecordsExportUnredacted" do
      # Every route this module maps, gathered from the existing regression
      # lists in this file plus the two new REQ-318 routes and a handful of
      # unmapped/garbage paths -- a positive, enumerable proof (not just "grep
      # finds no clause") that :EntitiesRecordsExportUnredacted is unreachable
      # via endpoint_policy_key/2.
      routes = [
        {"POST", "/definitions"},
        {"PUT", "/definitions/:id"},
        {"PATCH", "/definitions/:id"},
        {"POST", "/definitions/:id/activate"},
        {"POST", "/definitions/:id/deprecate"},
        {"POST", "/definitions/:id/archive"},
        {"DELETE", "/definitions/:id"},
        {"POST", "/definitions/import"},
        {"GET", "/definitions"},
        {"GET", "/definitions/:id"},
        {"GET", "/definitions/active/:name"},
        {"GET", "/definitions/search"},
        {"GET", "/definitions/:id/export"},
        {"GET", "/definitions/delta"},
        {"POST", "/instances"},
        {"POST", "/instances/:id/cancel"},
        {"POST", "/instances/:id/advance-timer"},
        {"GET", "/instances"},
        {"GET", "/instances/:id"},
        {"GET", "/tasks"},
        {"GET", "/tasks/:id"},
        {"POST", "/tasks/:id/complete"},
        {"POST", "/tasks/:id/assign"},
        {"POST", "/tasks/:id/reassign"},
        {"POST", "/users"},
        {"POST", "/groups"},
        {"POST", "/tokens"},
        {"GET", "/audit"},
        {"GET", "/dlq"},
        {"GET", "/metrics"},
        {"POST", "/webhooks/subscriptions"},
        {"GET", "/services"},
        {"GET", "/admin/services"},
        {"POST", "/tenants"},
        {"POST", "/onboarding"},
        {"GET", "/roles"},
        {"POST", "/instances/:id/attachments"},
        {"GET", "/instances/:id/attachments"},
        {"GET", "/entities/definitions"},
        {"POST", "/entities/definitions"},
        {"POST", "/entities/definitions/:name/activate"},
        {"POST", "/entities/records/:entity_type"},
        {"PUT", "/entities/records/:entity_type/:record_id"},
        {"DELETE", "/entities/records/:entity_type/:record_id"},
        {"POST", "/entities/query"},
        {"POST", "/entities/records/:entity_type/export"},
        {"POST", "/entities/records/:entity_type/import"},
        {"POST", "/definitions/:id/validate"},
        {"POST", "/instances/:id/rebind-pins"},
        {"GET", "/nope"},
        {"GET", "/entities/records/:entity_type/export"},
        {"DELETE", "/entities/records/:entity_type/import"}
      ]

      for {method, path} <- routes do
        # apply/3 here (rather than a direct `==`) is deliberate: a direct
        # comparison is statically provable-always-false by Elixir's type
        # checker (endpoint_policy_key/2's inferred return set has no clause
        # producing :EntitiesRecordsExportUnredacted at all), which is exactly
        # the property this test exists to demonstrate -- but a
        # compiler-warned comparison is noisy in test output. Routing through
        # apply/3 keeps the real runtime assertion while avoiding that
        # otherwise-correct static-type warning.
        key = apply(Authorization, :endpoint_policy_key, [method, path])

        refute key == :EntitiesRecordsExportUnredacted,
               "#{method} #{path} resolved to :EntitiesRecordsExportUnredacted -- this atom " <>
                 "must never be route-derived, only checked in-handler"
      end
    end

    test "required_permission(:EntitiesRecordsExportUnredacted) still returns :EntitiesRecordsExportUnredacted" do
      assert Authorization.required_permission(:EntitiesRecordsExportUnredacted) ==
               :EntitiesRecordsExportUnredacted
    end
  end

  describe "REQ-318 AC4 — required_permission/1 identity clauses for the two route-level atoms" do
    test "required_permission(:EntitiesRecordsExport) == :EntitiesRecordsExport" do
      assert Authorization.required_permission(:EntitiesRecordsExport) ==
               :EntitiesRecordsExport
    end

    test "required_permission(:EntitiesRecordsImport) == :EntitiesRecordsImport" do
      assert Authorization.required_permission(:EntitiesRecordsImport) ==
               :EntitiesRecordsImport
    end
  end

  describe "REQ-318 AC5 — evaluate_access/2 accepts :EntitiesRecordsExportUnredacted as a direct argument" do
    test "a role holding it (PLATFORM_ADMIN, via the catch-all) is granted" do
      ctx = %AccessContext{user_id: "u1", roles: [:PLATFORM_ADMIN]}

      assert %Authorization.AccessDecision{kind: :Allow} =
               Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted)
    end

    test "a role not holding it (PROCESS_OPERATOR) is denied" do
      ctx = %AccessContext{user_id: "u2", roles: [:PROCESS_OPERATOR]}

      assert %Authorization.AccessDecision{kind: :Deny403} =
               Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted)
    end

    test "no roles at all is denied, never defaulted to allow" do
      ctx = %AccessContext{user_id: "u3", roles: []}

      assert %Authorization.AccessDecision{kind: :Deny403} =
               Authorization.evaluate_access(ctx, :EntitiesRecordsExportUnredacted)
    end

    test "evaluate_access/2 also accepts the two route-level atoms directly, same grant/deny shape" do
      admin_ctx = %AccessContext{user_id: "u1", roles: [:PLATFORM_ADMIN]}
      operator_ctx = %AccessContext{user_id: "u2", roles: [:PROCESS_OPERATOR]}

      for permission <- [:EntitiesRecordsExport, :EntitiesRecordsImport] do
        assert %Authorization.AccessDecision{kind: :Allow} =
                 Authorization.evaluate_access(admin_ctx, permission)

        assert %Authorization.AccessDecision{kind: :Deny403} =
                 Authorization.evaluate_access(operator_ctx, permission)
      end
    end
  end

  describe "REQ-317 AC1 — permissions/0 contains the two new atoms, @doc count matches, endpoint_policy_key resolves all four routes" do
    test "permissions/0 contains both new atoms" do
      for permission <- @req317_permissions do
        assert permission in Authorization.permissions(),
               "expected permissions/0 to contain #{inspect(permission)}"
      end
    end

    test "the permissions/0 @doc's stated count equals length(permissions()) exactly" do
      {:docs_v1, _anno, _lang, _fmt, _moduledoc, _meta, fn_docs} =
        Code.fetch_docs(Letflow.Api.Authorization)

      permissions_doc =
        Enum.find_value(fn_docs, fn
          {{:function, :permissions, 0}, _anno, _sig, %{"en" => doc}, _meta} -> doc
          _ -> nil
        end)

      actual_count = length(Authorization.permissions())

      spelled =
        %{
          24 => "twenty-four",
          25 => "twenty-five",
          26 => "twenty-six",
          27 => "twenty-seven",
          28 => "twenty-eight",
          29 => "twenty-nine"
        }
        |> Map.get(actual_count)

      assert is_binary(spelled),
             "permissions/0 now returns #{actual_count} entries, outside this test's " <>
               "number-word table -- extend the table (and the @doc) rather than deleting " <>
               "this assertion"

      assert permissions_doc =~ "All #{spelled} `Permission` values",
             """
             permissions/0's @doc does not state the live count.
             permissions/0 currently returns #{actual_count} entries, so the @doc must \
             open with "All #{spelled} `Permission` values". Actual @doc:

             #{permissions_doc}
             """
    end

    test "endpoint_policy_key/2 resolves the four new routes, never :Unknown" do
      cases = [
        {"POST", "/entities/records/:entity_type/:record_id/attachments",
         :EntitiesAttachmentsManage},
        {"GET", "/entities/records/:entity_type/:record_id/attachments",
         :EntitiesAttachmentsRead},
        {"GET", "/entities/records/:entity_type/:record_id/attachments/:attachment_id",
         :EntitiesAttachmentsRead},
        {"DELETE", "/entities/records/:entity_type/:record_id/attachments/:attachment_id",
         :EntitiesAttachmentsManage}
      ]

      for {method, path, expected} <- cases do
        key = Authorization.endpoint_policy_key(method, path)

        assert key == expected,
               "endpoint_policy_key(#{inspect(method)}, #{inspect(path)}) returned " <>
                 "#{inspect(key)}, expected #{inspect(expected)}"

        refute key == :Unknown
      end
    end

    test "required_permission/1 identity mapping for both new atoms" do
      assert Authorization.required_permission(:EntitiesAttachmentsManage) ==
               :EntitiesAttachmentsManage

      assert Authorization.required_permission(:EntitiesAttachmentsRead) ==
               :EntitiesAttachmentsRead
    end
  end

  describe "REQ-317 AC2 — exact 2-permission x 5-role grid from design §7 OQ-2's table" do
    @req317_grid %{
      PLATFORM_ADMIN: %{EntitiesAttachmentsManage: true, EntitiesAttachmentsRead: true},
      PROCESS_DESIGNER: %{EntitiesAttachmentsManage: false, EntitiesAttachmentsRead: true},
      PROCESS_OPERATOR: %{EntitiesAttachmentsManage: true, EntitiesAttachmentsRead: true},
      TASK_WORKER: %{EntitiesAttachmentsManage: false, EntitiesAttachmentsRead: true},
      AGENT_RUNNER: %{EntitiesAttachmentsManage: false, EntitiesAttachmentsRead: false}
    }

    test "the grid covers every role x both new permissions -- 10 pairs, none missing" do
      assert Map.keys(@req317_grid) |> Enum.sort() == Authorization.roles() |> Enum.sort()

      pairs =
        for {_role, by_permission} <- @req317_grid,
            {permission, _} <- by_permission,
            do: permission

      assert length(pairs) == 10

      for {role, by_permission} <- @req317_grid do
        assert Enum.sort(Map.keys(by_permission)) == Enum.sort(@req317_permissions),
               "grid row for #{role} does not name exactly the two new permissions"
      end
    end

    test "role_allows?/2 matches the grid for all 10 role/permission pairs" do
      for {role, by_permission} <- @req317_grid,
          {permission, expected} <- by_permission do
        actual = Authorization.role_allows?(role, permission)

        assert actual == expected,
               "role_allows?(#{inspect(role)}, #{inspect(permission)}) returned " <>
                 "#{inspect(actual)}, design §7 OQ-2's role matrix says #{inspect(expected)}"
      end
    end

    test "evaluate_access/2 agrees with the grid end-to-end" do
      for {role, by_permission} <- @req317_grid,
          {policy_key, expected_allowed} <- by_permission do
        ctx = %AccessContext{user_id: "u-#{role}", roles: [role]}
        decision = Authorization.evaluate_access(ctx, policy_key)
        expected_kind = if expected_allowed, do: :Allow, else: :Deny403

        assert decision.kind == expected_kind,
               "evaluate_access(roles: [#{inspect(role)}], #{inspect(policy_key)}) returned " <>
                 "#{inspect(decision.kind)}, expected #{inspect(expected_kind)}"
      end
    end
  end

  describe "REQ-318 AC6 — regression: no EXISTING role/permission pair changed, and only PLATFORM_ADMIN's catch-all grants the three new atoms" do
    # Snapshot of every permission that existed before REQ-318 (the 23
    # REQ-309-era permissions plus REQ-315's :EntitiesAggregate, which merged
    # to main ahead of this rebase), crossed with all five roles --
    # transcribed by hand from the module as it stood immediately before this
    # change, the same discipline the REQ-309 AC5 regression grid above
    # already establishes for its own predecessor state.
    @pre_req318_permissions [
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
      :InstancesAdvanceTimer,
      :EntitiesDefinitionsRead,
      :EntitiesDefinitionsWrite,
      :EntitiesRecordsWrite,
      :EntitiesQuery,
      :EntitiesAggregate
    ]

    @pre_req318_allowed %{
      PLATFORM_ADMIN: @pre_req318_permissions,
      PROCESS_DESIGNER: [
        :DefinitionsWrite,
        :DefinitionsRead,
        :InstancesStart,
        :InstancesRead,
        :TasksRead,
        :RolesManage,
        :AttachmentsRead,
        :EntitiesDefinitionsRead,
        :EntitiesDefinitionsWrite,
        :EntitiesQuery,
        :EntitiesAggregate
      ],
      PROCESS_OPERATOR: [
        :DefinitionsRead,
        :InstancesStart,
        :InstancesCancel,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :TasksAssign,
        :AuditRead,
        :DlqOperate,
        :MetricsRead,
        :WebhooksManage,
        :AttachmentsManage,
        :AttachmentsRead,
        :InstancesAdvanceTimer,
        :EntitiesDefinitionsRead,
        :EntitiesRecordsWrite,
        :EntitiesQuery,
        :EntitiesAggregate
      ],
      TASK_WORKER: [
        :DefinitionsRead,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :AttachmentsRead,
        :EntitiesDefinitionsRead,
        :EntitiesQuery,
        :EntitiesAggregate
      ],
      AGENT_RUNNER: []
    }

    test "the live permissions/0 list's first twenty-seven entries are exactly the pre-existing twenty-four plus REQ-318's three, in that order" do
      # A prefix check (not exact equality) is deliberate here -- REQ-317 (a
      # later requirement, landed after REQ-318) appends two more permissions
      # after these, and this test asserts only what REQ-318 itself is
      # responsible for.
      assert length(@pre_req318_permissions) == 24
      expected_prefix = @pre_req318_permissions ++ @req318_permissions
      live = Authorization.permissions()
      assert Enum.take(live, length(expected_prefix)) == expected_prefix
    end

    test "all 120 pre-existing role/permission pairs return exactly what they returned before REQ-318" do
      for role <- [
            :PLATFORM_ADMIN,
            :PROCESS_DESIGNER,
            :PROCESS_OPERATOR,
            :TASK_WORKER,
            :AGENT_RUNNER
          ],
          permission <- @pre_req318_permissions do
        expected = permission in Map.fetch!(@pre_req318_allowed, role)
        actual = Authorization.role_allows?(role, permission)

        assert actual == expected,
               "REGRESSION: role_allows?(#{inspect(role)}, #{inspect(permission)}) is now " <>
                 "#{inspect(actual)} but was #{inspect(expected)} before REQ-318. This " <>
                 "change must be purely additive -- no existing role/permission pair may " <>
                 "change hands."
      end
    end

    test "PROCESS_DESIGNER, PROCESS_OPERATOR and TASK_WORKER are denied all three new atoms" do
      for role <- [:PROCESS_DESIGNER, :PROCESS_OPERATOR, :TASK_WORKER],
          permission <- @req318_permissions do
        refute Authorization.role_allows?(role, permission),
               "expected #{inspect(role)} to be denied #{inspect(permission)} -- design §5 " <>
                 "deliberately adds no new role_allows?/2 clause for this role against any " <>
                 "of the three REQ-318 atoms"
      end
    end

    test "PLATFORM_ADMIN's pre-existing catch-all is the only thing granting the three new atoms" do
      for permission <- @req318_permissions do
        assert Authorization.role_allows?(:PLATFORM_ADMIN, permission),
               "expected PLATFORM_ADMIN's catch-all to grant #{inspect(permission)}"
      end

      # AGENT_RUNNER's catch-all is `do: false` -- confirm it stays denied too,
      # since it is a role, not a no-role case, and easy to miss.
      for permission <- @req318_permissions do
        refute Authorization.role_allows?(:AGENT_RUNNER, permission),
               "expected AGENT_RUNNER to be denied #{inspect(permission)}"
      end
    end
  end

  describe "REQ-317 AC3 — regression grid: no PRE-EXISTING role/permission pair changed" do
    # Every permission that existed before REQ-317 (the pre-REQ-315 twenty-
    # three plus REQ-315's own :EntitiesAggregate), crossed with all five
    # roles: 120 pairs. Same discipline as REQ-309's AC5 / REQ-315's AC3 /
    # REQ-318's AC6 above -- transcribed by hand from this module as it stood
    # immediately before REQ-317, NOT derived from the module under test. By
    # the time this branch rebased, REQ-318 had already landed on main ahead
    # of REQ-317, so this baseline (24 entries, ending in :EntitiesAggregate)
    # predates REQ-318's three atoms too -- see the prefix-check test below,
    # which accounts for that.
    @pre_req317_permissions [
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
      :InstancesAdvanceTimer,
      :EntitiesDefinitionsRead,
      :EntitiesDefinitionsWrite,
      :EntitiesRecordsWrite,
      :EntitiesQuery,
      :EntitiesAggregate
    ]

    @pre_req317_allowed %{
      PLATFORM_ADMIN: @pre_req317_permissions,
      PROCESS_DESIGNER: [
        :DefinitionsWrite,
        :DefinitionsRead,
        :InstancesStart,
        :InstancesRead,
        :TasksRead,
        :RolesManage,
        :AttachmentsRead,
        :EntitiesDefinitionsRead,
        :EntitiesDefinitionsWrite,
        :EntitiesQuery,
        :EntitiesAggregate
      ],
      PROCESS_OPERATOR: [
        :DefinitionsRead,
        :InstancesStart,
        :InstancesCancel,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :TasksAssign,
        :AuditRead,
        :DlqOperate,
        :MetricsRead,
        :WebhooksManage,
        :AttachmentsManage,
        :AttachmentsRead,
        :InstancesAdvanceTimer,
        :EntitiesDefinitionsRead,
        :EntitiesRecordsWrite,
        :EntitiesQuery,
        :EntitiesAggregate
      ],
      TASK_WORKER: [
        :DefinitionsRead,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :AttachmentsRead,
        :EntitiesDefinitionsRead,
        :EntitiesQuery,
        :EntitiesAggregate
      ],
      AGENT_RUNNER: []
    }

    test "the regression grid is complete: 5 roles x 24 pre-existing permissions = 120 pairs" do
      assert length(@pre_req317_permissions) == 24
      assert Enum.sort(Map.keys(@pre_req317_allowed)) == Enum.sort(Authorization.roles())

      live = Authorization.permissions()

      for permission <- @pre_req317_permissions do
        assert permission in live,
               "#{inspect(permission)} existed before REQ-317 but is no longer in " <>
                 "permissions/0 -- a permission was REMOVED, not added"
      end

      # The live list STARTS WITH the pre-existing twenty-four, in that
      # order: proves nothing before REQ-317 was disturbed. A prefix check
      # (not exact equality with `@pre_req317_permissions ++ @req317_permissions`)
      # is deliberate -- REQ-318 landed on main ahead of this branch's own
      # rebase and inserted its own three atoms between this baseline and
      # REQ-317's two, so REQ-317's own atoms are checked separately below
      # (this file's "REQ-317 AC1" describe block already confirms both are
      # present in permissions/0).
      assert Enum.take(live, length(@pre_req317_permissions)) == @pre_req317_permissions

      pair_count = length(Authorization.roles()) * length(@pre_req317_permissions)
      assert pair_count == 120
    end

    test "all 120 pre-existing role/permission pairs return exactly what they returned before REQ-317" do
      for role <- [
            :PLATFORM_ADMIN,
            :PROCESS_DESIGNER,
            :PROCESS_OPERATOR,
            :TASK_WORKER,
            :AGENT_RUNNER
          ],
          permission <- @pre_req317_permissions do
        expected = permission in Map.fetch!(@pre_req317_allowed, role)
        actual = Authorization.role_allows?(role, permission)

        assert actual == expected,
               "REGRESSION: role_allows?(#{inspect(role)}, #{inspect(permission)}) is now " <>
                 "#{inspect(actual)} but was #{inspect(expected)} before REQ-317. This " <>
                 "change must be purely additive -- no existing role/permission pair may " <>
                 "change hands."
      end
    end

    test "required_permission/1 and endpoint_policy_key/2 are unchanged for the pre-existing entity-subsystem routes" do
      assert Authorization.endpoint_policy_key("POST", "/entities/query") == :EntitiesQuery
      assert Authorization.required_permission(:EntitiesQuery) == :EntitiesQuery

      assert Authorization.endpoint_policy_key("POST", "/entities/records/:entity_type") ==
               :EntitiesRecordsWrite

      assert Authorization.endpoint_policy_key("POST", "/entities/query/aggregate") ==
               :EntitiesAggregate
    end

    test "an undeclared /entities/records/.../attachments path is still :Unknown, and the new clauses did not widen matching" do
      assert Authorization.endpoint_policy_key(
               "GET",
               "/entities/records/:entity_type/attachments"
             ) == :Unknown

      assert Authorization.endpoint_policy_key(
               "PATCH",
               "/entities/records/:entity_type/:record_id/attachments"
             ) == :Unknown

      assert Authorization.endpoint_policy_key(
               "GET",
               "/entities/records/:entity_type/:record_id/attachments/:attachment_id/extra"
             ) == :Unknown
    end
  end
end
