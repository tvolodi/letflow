defmodule Letflow.Api.Authorization do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Role/permission authorization matrix and 403 decision contract — ports
  `src/api/authorization.zig` (281 lines, R-Co). Pure module: no `Plug.Conn`,
  no I/O, never raises on any input. See
  `lib/letflow/design/req069-authorization.md` for the full design.

  ## Untrusted input: roles are caller-influenced strings, not R-Co's enum

  `Letflow.Plugs.AuthPipeline` populates `conn.assigns[:auth_context][:roles]`
  from `Letflow.Oidc.ClaimMapping.resolve_roles/2`, whose contract is
  `[String.t()]` — an arbitrary list of strings taken from the bearer token's
  own claims. `roles_from_strings/1` converts that untrusted list into the
  closed `role/0` atom set: an unrecognized string is silently dropped (never
  raises, never widens to any role), and an all-unrecognized or empty input
  list both correctly yield `[]`, which `evaluate_access/2` treats identically
  to "the caller holds no role at all." `String.to_existing_atom/1` is
  deliberately NOT used for this conversion — it would let attacker-controlled
  token content reach the atom table, an unbounded-atom-creation vector.

  ## SECURITY (INV-2, INV-5)

  * **INV-2** — every decision `evaluate_access/2` returns is a pure function
    of its two arguments (`AccessContext.t()`, `endpoint_policy_key()`). There
    is no third parameter through which request-derived data (a query string,
    a body field, an `assignee_id` filter) could reach this function, so
    `AllowWithRowFilter`'s row scope can only ever be the `AccessContext`'s own
    `user_id` — never anything a caller supplies elsewhere in the same
    request. This is structural, not merely tested.
  * **INV-5** — this module answers only "is this action allowed," never
    "does this resource exist." A cross-tenant resource lookup must be
    resolved to 404 by REQ-072's request-context/scoping layer BEFORE
    `evaluate_access/2` is ever called with that resource in scope — routing a
    cross-tenant lookup through this module and returning its `Deny403` to the
    caller would let a prober distinguish "exists, not yours" from "never
    existed," which is exactly what INV-5 forbids. Wrong role, right tenant is
    correctly `Deny403`; any resource outside the caller's own tenant is
    REQ-072's 404, never this module's `Deny403`.

  ## Ported-but-currently-unreachable entries

  `AGENT_RUNNER` (role) and `DlqOperate`/`WebhooksManage` (permissions) have no
  S4 route consumer today — runtime agent orchestration, the DLQ, and webhook
  dispatch are all deferred subsystems. Ported anyway so the matrix matches
  R-Co's exactly, and so a later reader doesn't have to rediscover the gap.

  ## `AttachmentsManage`/`AttachmentsRead` (REQ-212) — genuinely new, not pre-ported

  Unlike `DlqOperate`/`WebhooksManage` above (ported ahead of their consuming
  routes, matching R-Co's matrix exactly even before any route consumed them),
  `AttachmentsManage` and `AttachmentsRead` have **no R-Co counterpart at
  all** — `instance_attachments` (REQ-211) is new functionality this
  migration invents, not a ported R-Co subsystem. Added *for*
  `Letflow.Routers.Instances`'s four `/instances/:id/attachments...` routes,
  immediately consumed, never in a "ported but currently unreachable" state.
  Two permissions, not one collapsed permission, is also a deliberate split
  (unlike `DlqOperate`/`WebhooksManage`'s single-permission precedent):
  `AttachmentsManage` gates upload/delete (mutation), `AttachmentsRead` gates
  list/download (read) — REQ-212's own acceptance criteria require the split
  kept, not collapsed. See design
  `lib/letflow/design/req212-instance-attachments-routes.md` §6.
  """

  @type role ::
          :PLATFORM_ADMIN
          | :PROCESS_DESIGNER
          | :PROCESS_OPERATOR
          | :TASK_WORKER
          | :AGENT_RUNNER

  @type permission ::
          :DefinitionsWrite
          | :DefinitionsRead
          | :InstancesStart
          | :InstancesCancel
          | :InstancesRead
          | :TasksRead
          | :TasksComplete
          | :TasksAssign
          | :UsersGroupsRolesManage
          | :TokensManage
          | :AuditRead
          | :DlqOperate
          | :MetricsRead
          | :WebhooksManage
          | :TenantsManage
          | :RolesManage
          | :AttachmentsManage
          | :AttachmentsRead
          | :InstancesAdvanceTimer

  @type access_decision_kind :: :Allow | :Deny403 | :AllowWithRowFilter

  @type endpoint_policy_key ::
          :DefinitionsCreate
          | :DefinitionsUpdate
          | :DefinitionsPatch
          | :DefinitionsActivate
          | :DefinitionsDeprecate
          | :DefinitionsArchive
          | :DefinitionsDelete
          | :DefinitionsImport
          | :DefinitionsRead
          | :InstancesStart
          | :InstancesCancel
          | :InstancesRead
          | :TasksList
          | :TasksGetById
          | :TasksComplete
          | :TasksAssign
          | :TasksReassign
          | :UsersManage
          | :GroupsManage
          | :TokensManage
          | :AuditRead
          | :DlqReadRetryDiscard
          | :MetricsRead
          | :WebhookSubscriptionsManage
          | :ServicesRead
          | :AdminServicesManage
          | :AdminServicesRead
          | :TenantsManage
          | :RolesManage
          | :AttachmentsManage
          | :AttachmentsRead
          | :InstancesAdvanceTimer
          | :Unknown

  @type task_row_scope :: :all | {:own_user_and_groups, String.t()}

  @roles [:PLATFORM_ADMIN, :PROCESS_DESIGNER, :PROCESS_OPERATOR, :TASK_WORKER, :AGENT_RUNNER]

  @permissions [
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

  @doc "All five `Role` values, R-Co's exact names. See `roles_from_strings/1` for untrusted-input conversion."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc "All eighteen `Permission` values — R-Co's fourteen plus REQ-076's `:RolesManage` plus REQ-212's `:AttachmentsManage`/`:AttachmentsRead` plus ISS-0389's `:InstancesAdvanceTimer`."
  @spec permissions() :: [permission()]
  def permissions, do: @permissions

  defmodule AccessContext do
    # PROVENANCE (historical, not current decision authority):
    @moduledoc "Ports `authorization.zig`'s `AccessContext` struct."
    @enforce_keys [:user_id, :roles]
    defstruct [:user_id, :roles]

    @type t :: %__MODULE__{
            user_id: String.t(),
            roles: [Letflow.Api.Authorization.role()]
          }
  end

  defmodule AccessDecision do
    # PROVENANCE (historical, not current decision authority):
    @moduledoc "Ports `authorization.zig`'s `AccessDecision` struct."
    @enforce_keys [:kind]
    defstruct kind: nil, task_scope: nil

    @type t :: %__MODULE__{
            kind: Letflow.Api.Authorization.access_decision_kind(),
            task_scope: Letflow.Api.Authorization.task_row_scope() | nil
          }
  end

  @doc """
  Converts an untrusted list of role strings (as read from
  `conn.assigns[:auth_context][:roles]`) into the closed `role/0` atom set.
  An unrecognized string is silently dropped — never raises, never widens to
  any role. `String.to_existing_atom/1` is deliberately not used (see
  moduledoc). An empty or all-unrecognized input list both correctly yield
  `[]`.
  """
  @spec roles_from_strings([String.t()]) :: [role()]
  def roles_from_strings(role_strings) when is_list(role_strings) do
    Enum.reduce(role_strings, [], fn s, acc ->
      case role_from_string(s) do
        nil -> acc
        role -> [role | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp role_from_string("PLATFORM_ADMIN"), do: :PLATFORM_ADMIN
  defp role_from_string("PROCESS_DESIGNER"), do: :PROCESS_DESIGNER
  defp role_from_string("PROCESS_OPERATOR"), do: :PROCESS_OPERATOR
  defp role_from_string("TASK_WORKER"), do: :TASK_WORKER
  defp role_from_string("AGENT_RUNNER"), do: :AGENT_RUNNER
  defp role_from_string(_other), do: nil

  @doc """
  PROVENANCE (historical, not current decision authority):
  Maps an HTTP method + path template to an `endpoint_policy_key/0`. Ports
  `endpointPolicyKey/2` (authorization.zig L77-112) exactly, including the
  SVC-04 service-catalog entries.
  """
  @spec endpoint_policy_key(String.t(), String.t()) :: endpoint_policy_key()
  def endpoint_policy_key(method, path_template)

  def endpoint_policy_key("POST", "/definitions"), do: :DefinitionsCreate
  def endpoint_policy_key("PUT", "/definitions/:id"), do: :DefinitionsUpdate
  def endpoint_policy_key("PATCH", "/definitions/:id"), do: :DefinitionsPatch
  def endpoint_policy_key("POST", "/definitions/:id/activate"), do: :DefinitionsActivate

  # PROVENANCE (historical, not current decision authority):
  # REQ-082 -- deprecate/archive/delete/import. authorization.zig has NO
  # entries for these four (confirmed by grep against that source, zero hits) --
  # same "no endpoint_policy_key clause, not permission-gated" pattern REQ-078/079
  # already established for rebind-pins/reconstruct. REQ-082's own acceptance
  # criterion 7 ("a caller without DefinitionsWrite receives 403 on all eight
  # endpoints") is a DELIBERATE Letflow-side divergence from that R-Co gap, not an
  # oversight -- these four route-local mutations are exactly the kind of state
  # change REQ-131's future policy work is meant to generalize, but REQ-082's own
  # acceptance criteria require the gate now rather than deferring it, so these four
  # get real endpoint_policy_key clauses (all mapping to :DefinitionsWrite, same as
  # the four R-Co-sourced ones above) instead of joining the rebind-pins/reconstruct
  # no-clause precedent.
  def endpoint_policy_key("POST", "/definitions/:id/deprecate"), do: :DefinitionsDeprecate
  def endpoint_policy_key("POST", "/definitions/:id/archive"), do: :DefinitionsArchive
  def endpoint_policy_key("DELETE", "/definitions/:id"), do: :DefinitionsDelete
  def endpoint_policy_key("POST", "/definitions/import"), do: :DefinitionsImport

  def endpoint_policy_key("GET", path) when path in ["/definitions", "/definitions/:id"],
    do: :DefinitionsRead

  # REQ-081 -- same permission, three more path templates, no new atom.
  # REQ-125 adds a fourth (/definitions/delta), same permission, still no
  # new atom.
  def endpoint_policy_key("GET", path)
      when path in [
             "/definitions/active/:name",
             "/definitions/search",
             "/definitions/:id/export",
             "/definitions/delta"
           ],
      do: :DefinitionsRead

  def endpoint_policy_key("POST", "/instances"), do: :InstancesStart
  def endpoint_policy_key("POST", "/instances/:id/cancel"), do: :InstancesCancel

  # ISS-0389 -- a genuine new permission, fully wired (not the
  # rebind-pins/reconstruct ad-hoc route-declared-atom pattern; see
  # lib/letflow/design/iss0389-advance-timer-endpoint.md Decision 2).
  def endpoint_policy_key("POST", "/instances/:id/advance-timer"),
    do: :InstancesAdvanceTimer

  def endpoint_policy_key("GET", path)
      when path in [
             "/instances",
             "/instances/:id",
             "/instances/:id/history",
             "/instances/:id/timeline",
             "/instances/:id/pins"
           ],
      do: :InstancesRead

  def endpoint_policy_key("GET", "/tasks"), do: :TasksList

  # PROVENANCE (historical, not current decision authority):
  # REQ-083 (OQ-8) -- GET /tasks/inbox maps to the same :TasksList policy key
  # as GET /tasks, because there is only one evaluateAccess call site for
  # this whole flow: handleInbox (tasks.zig L960-982) builds a
  # ListTasksParams and calls handleList itself, which is where that ONLY
  # evaluateAccess call happens -- handleInbox performs no authorization
  # call of its own. Additive-only: changes no existing clause's behavior, since every
  # endpoint_policy_key/2 call site is matched by exact string.
  def endpoint_policy_key("GET", "/tasks/inbox"), do: :TasksList

  def endpoint_policy_key("GET", "/tasks/:id"), do: :TasksGetById
  def endpoint_policy_key("POST", "/tasks/:id/complete"), do: :TasksComplete

  # REQ-085 (design doc §2) -- claim is gated by the SAME :TasksComplete
  # permission /complete uses, not :TasksAssign (same as handleClaim's own
  # evaluateAccess(..., .TasksComplete) call): TASK_WORKER holds
  # :TasksComplete but not :TasksAssign, and a task worker claiming a
  # group/role-assigned task before completing it is exactly the caller this
  # endpoint exists for. Additive-only, no existing clause's behavior changes.
  def endpoint_policy_key("POST", "/tasks/:id/claim"), do: :TasksComplete
  def endpoint_policy_key("POST", "/tasks/:id/assign"), do: :TasksAssign
  def endpoint_policy_key("POST", "/tasks/:id/reassign"), do: :TasksReassign

  def endpoint_policy_key("POST", "/users"), do: :UsersManage
  def endpoint_policy_key("GET", path) when path in ["/users", "/users/:id"], do: :UsersManage
  def endpoint_policy_key("PATCH", "/users/:id"), do: :UsersManage
  def endpoint_policy_key("POST", "/users/:id/status"), do: :UsersManage

  def endpoint_policy_key(method, "/groups" <> _rest)
      when method in ["POST", "DELETE", "GET"],
      do: :GroupsManage

  def endpoint_policy_key(method, "/tokens" <> _rest)
      when method in ["POST", "GET", "DELETE"],
      do: :TokensManage

  def endpoint_policy_key("GET", "/audit"), do: :AuditRead

  def endpoint_policy_key(method, "/dlq" <> _rest) when method in ["GET", "POST"],
    do: :DlqReadRetryDiscard

  def endpoint_policy_key("GET", "/metrics"), do: :MetricsRead

  def endpoint_policy_key(method, "/webhooks/subscriptions")
      when method in ["POST", "GET"],
      do: :WebhookSubscriptionsManage

  def endpoint_policy_key("GET", "/webhooks/subscriptions/:id/deliveries"),
    do: :WebhookSubscriptionsManage

  # REQ-182 -- the PATCH route this requirement adds
  # (Letflow.Routers.Webhooks) was, until now, the one confirmed real gap in
  # this endpoint-policy-key table: no clause existed for
  # PATCH "/webhooks/subscriptions/:id" even though GET/POST on the
  # collection and DELETE on the member route were already mapped below and
  # above. Same policy key as the other three /webhooks/subscriptions...
  # clauses -- no new permission atom, no new required_permission/1 clause.
  def endpoint_policy_key("PATCH", "/webhooks/subscriptions/:id"),
    do: :WebhookSubscriptionsManage

  def endpoint_policy_key("DELETE", "/webhooks/subscriptions/:id"),
    do: :WebhookSubscriptionsManage

  def endpoint_policy_key("GET", "/services"), do: :ServicesRead
  def endpoint_policy_key("GET", "/admin/services"), do: :AdminServicesRead

  def endpoint_policy_key(method, "/admin/services" <> _rest)
      when method in ["POST", "PATCH", "DELETE"],
      do: :AdminServicesManage

  # REQ-075 — tenant administration (Letflow.Routers.Tenants), a top-level
  # sibling router, NOT under Letflow.Routers.Identity's own /identity mount
  # (see that router's own moduledoc for why). One permission
  # (:TenantsManage), granted to PLATFORM_ADMIN only via the existing
  # catch-all clause in role_allows?/2 — no new role clauses added anywhere.
  def endpoint_policy_key("POST", "/tenants"), do: :TenantsManage

  def endpoint_policy_key("GET", path) when path in ["/tenants", "/tenants/:slug"],
    do: :TenantsManage

  def endpoint_policy_key("PATCH", "/tenants/:slug"), do: :TenantsManage
  def endpoint_policy_key("POST", "/tenants/:slug/deactivate"), do: :TenantsManage
  def endpoint_policy_key("POST", "/tenants/:slug/reactivate"), do: :TenantsManage

  # REQ-076 -- onboarding (Letflow.Routers.Onboarding), a top-level sibling
  # router mounted at /onboarding (not under Letflow.Routers.Identity's own
  # /identity mount). Reuses the existing :TenantsManage permission -- same
  # risk class and same PLATFORM_ADMIN-only intent as Letflow.Routers.Tenants
  # (design doc §8.3). No new permission added for onboarding.
  def endpoint_policy_key("POST", "/onboarding"), do: :TenantsManage
  def endpoint_policy_key("GET", "/onboarding/:id"), do: :TenantsManage
  def endpoint_policy_key("GET", "/onboarding"), do: :TenantsManage

  # REQ-076 -- role registry routes (Letflow.Routers.Identity, mounted
  # relative to /identity, matching the "/tokens" convention above). A new,
  # distinct :RolesManage permission -- see role_allows?/2's PROCESS_DESIGNER
  # clause below for why :UsersGroupsRolesManage cannot be reused here
  # (design doc §4 point 2).
  def endpoint_policy_key("GET", "/roles"), do: :RolesManage
  def endpoint_policy_key("POST", "/roles"), do: :RolesManage

  # REQ-212 — instance-attachment routes (Letflow.Routers.Instances), mounted
  # under /instances/:id/attachments... See design §6.3.
  def endpoint_policy_key("POST", "/instances/:id/attachments"), do: :AttachmentsManage

  def endpoint_policy_key("DELETE", "/instances/:id/attachments/:attachment_id"),
    do: :AttachmentsManage

  def endpoint_policy_key("GET", "/instances/:id/attachments"), do: :AttachmentsRead

  def endpoint_policy_key("GET", "/instances/:id/attachments/:attachment_id"),
    do: :AttachmentsRead

  def endpoint_policy_key(_method, _path), do: :Unknown

  @doc """
  PROVENANCE (historical, not current decision authority):
  Ports `evaluateAccess/2` (authorization.zig L114-139) exactly, branch order
  included.
  """
  @spec evaluate_access(AccessContext.t(), endpoint_policy_key()) :: AccessDecision.t()
  def evaluate_access(%AccessContext{} = ctx, endpoint) do
    cond do
      endpoint == :Unknown ->
        if has_role?(ctx.roles, :PLATFORM_ADMIN) do
          %AccessDecision{kind: :Allow, task_scope: nil}
        else
          %AccessDecision{kind: :Deny403, task_scope: nil}
        end

      endpoint == :MetricsRead ->
        %AccessDecision{kind: :Allow, task_scope: :all}

      true ->
        required = required_permission(endpoint)

        if not has_permission?(ctx.roles, required) do
          %AccessDecision{kind: :Deny403, task_scope: nil}
        else
          if endpoint == :TasksList and is_task_worker_only?(ctx.roles) do
            %AccessDecision{
              kind: :AllowWithRowFilter,
              task_scope: {:own_user_and_groups, ctx.user_id}
            }
          else
            %AccessDecision{kind: :Allow, task_scope: :all}
          end
        end
    end
  end

  @doc "Ports `isTaskWorkerOnly/1` (L141-146) exactly."
  @spec is_task_worker_only?([role()]) :: boolean()
  def is_task_worker_only?(roles) do
    has_role?(roles, :TASK_WORKER) and
      not has_role?(roles, :PLATFORM_ADMIN) and
      not has_role?(roles, :PROCESS_DESIGNER) and
      not has_role?(roles, :PROCESS_OPERATOR)
  end

  @doc "Ports `requiredPermission/1` (L148-169) exactly, including the SVC-04 entries."
  @spec required_permission(endpoint_policy_key()) :: permission()
  def required_permission(endpoint)

  def required_permission(key)
      when key in [
             :DefinitionsCreate,
             :DefinitionsUpdate,
             :DefinitionsPatch,
             :DefinitionsActivate,
             :DefinitionsDeprecate,
             :DefinitionsArchive,
             :DefinitionsDelete,
             :DefinitionsImport
           ],
      do: :DefinitionsWrite

  def required_permission(:DefinitionsRead), do: :DefinitionsRead
  def required_permission(:InstancesStart), do: :InstancesStart
  def required_permission(:InstancesCancel), do: :InstancesCancel
  def required_permission(:InstancesRead), do: :InstancesRead
  def required_permission(:InstancesAdvanceTimer), do: :InstancesAdvanceTimer
  def required_permission(key) when key in [:TasksList, :TasksGetById], do: :TasksRead
  def required_permission(:TasksComplete), do: :TasksComplete
  def required_permission(key) when key in [:TasksAssign, :TasksReassign], do: :TasksAssign

  def required_permission(key) when key in [:UsersManage, :GroupsManage],
    do: :UsersGroupsRolesManage

  def required_permission(:TokensManage), do: :TokensManage
  def required_permission(:AuditRead), do: :AuditRead
  def required_permission(:DlqReadRetryDiscard), do: :DlqOperate
  def required_permission(:MetricsRead), do: :MetricsRead
  def required_permission(:WebhookSubscriptionsManage), do: :WebhooksManage
  # any authenticated role — matches Zig's comment on this branch
  def required_permission(:ServicesRead), do: :DefinitionsRead
  # platform-admin enforced in handler, per Zig's comment
  def required_permission(key) when key in [:AdminServicesManage, :AdminServicesRead],
    do: :UsersGroupsRolesManage

  def required_permission(:TenantsManage), do: :TenantsManage
  def required_permission(:RolesManage), do: :RolesManage
  def required_permission(:AttachmentsManage), do: :AttachmentsManage
  def required_permission(:AttachmentsRead), do: :AttachmentsRead

  def required_permission(:Unknown), do: :MetricsRead

  @doc "Ports `hasPermission/2` (L171-176) exactly."
  @spec has_permission?([role()], permission()) :: boolean()
  def has_permission?(roles, permission) do
    Enum.any?(roles, &role_allows?(&1, permission))
  end

  @doc "Ports `hasRole/2` (L178-183) exactly."
  @spec has_role?([role()], role()) :: boolean()
  def has_role?(roles, target) do
    target in roles
  end

  @doc "Ports `roleAllows/2` (L185-222) exactly, the full 5-role permission matrix."
  @spec role_allows?(role(), permission()) :: boolean()
  def role_allows?(role, permission)

  def role_allows?(:PLATFORM_ADMIN, _permission), do: true

  def role_allows?(:PROCESS_DESIGNER, permission),
    do:
      permission in [
        :DefinitionsWrite,
        :DefinitionsRead,
        :InstancesStart,
        :InstancesRead,
        :TasksRead,
        :RolesManage,
        :AttachmentsRead
      ]

  def role_allows?(:PROCESS_OPERATOR, permission),
    do:
      permission in [
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
      ]

  def role_allows?(:TASK_WORKER, permission),
    do:
      permission in [
        :DefinitionsRead,
        :InstancesRead,
        :TasksRead,
        :TasksComplete,
        :AttachmentsRead
      ]

  def role_allows?(:AGENT_RUNNER, _permission), do: false
end
