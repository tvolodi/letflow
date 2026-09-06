# REQ-069 — `Letflow.Api.Authorization` design

PROVENANCE (historical, not current decision authority):
Ports `src/api/authorization.zig` (281 lines, R-Co). Pure module: no `Plug.Conn`,
no I/O, never raises on any input.

Self-gating note: this run has no separate CODE-DESIGNER/CODE-DESIGN-VALIDATOR/
SECURITY-REVIEWER/REVIEWER/TEST-DESIGNER — one agent performed every WF-02 role
directly, as clearly separated passes, because this execution context cannot spawn
subagents. Stated here per this project's convention for such runs (see
WF03-ISS0208-20260821 and others this session).

## 0.1 Scope

Ports:
- `Role` (5 values), `Permission` (14 values), `AccessDecisionKind` (3 values),
  `EndpointPolicyKey` (used internally to drive the decision table — not
  necessarily part of the public route-facing API surface yet since REQ-070's
  router decomposition and the individual REQ-08x route requirements haven't
  landed; ported as R-Co defines it so the decision table has something concrete
  to switch on, per the requirement's own framing that AGENT_RUNNER/DlqOperate/
  WebhooksManage are "ported but currently unreachable").
- `TaskRowScope` (`:all` | `{:own_user_and_groups, user_id}`).
- `AccessContext` (`user_id`, `roles`).
- `AccessDecision` (`kind`, `task_scope`).
- `endpoint_policy_key/2`, `evaluate_access/2`, `is_task_worker_only?/1`,
  `required_permission/1`, `has_permission?/2`, `has_role?/2`, `role_allows?/2`.

PROVENANCE (historical, not current decision authority):
Does NOT port: any Plug/route wiring (no consumer route exists yet — REQ-083
consumes the TasksList row-filter decision when it ports `tasks.zig`'s read
path, per the requirement text).

## 0.2 Untrusted input: roles come from a JWT claim as raw strings

`Letflow.Plugs.AuthPipeline.attach_auth_context/4` sets
`conn.assigns[:auth_context][:roles]` from
`Letflow.Oidc.ClaimMapping.resolve_roles/2`, whose own `@spec` return type is
`[String.t()]` — an arbitrary list of strings taken directly from the token's
`realm_access.roles` (or configured) claim path, with non-string array elements
mapped to `""` (never dropped, so array length is preserved but content may be
garbage). **This means `Letflow.Api.Authorization` never receives R-Co's `Role`
enum directly — it receives untrusted strings and must safely convert them.**

This is exactly the surface INV-2/AC6 care about: a caller who controls their own
token claims (or a misconfigured/compromised IdP) can put ANY string in that list,
including `""`, duplicates, or a string that happens to match a `Role` atom's
`Atom.to_string/1` spelling by coincidence. The conversion from `[String.t()]` to
`[Role.t()]` must never crash on garbage input and must never treat an unrecognized
string as any known role (silent-widen would be a default-allow bug of exactly the
kind AC6 tests against).

`Authorization.roles_from_strings/1` does this conversion: for each string, look it
up against the closed set of 5 known role-name strings (`"PLATFORM_ADMIN"`, etc.,
matching R-Co's own enum spelling exactly — `String.to_existing_atom/1` is
deliberately NOT used, since that primitive would let external, attacker-controlled
input reach the atom table, an unbounded-atom-creation vector); an unrecognized
string is silently dropped (not an error — a token can carry roles this service
doesn't know about, e.g. future R-Co roles, without crashing the whole request).
The result is always a subset of the 5 known atoms, never anything else. An empty
input list, or a list where every string is unrecognized, both correctly produce
`[]`, and `evaluate_access/2` treats `[]` identically to "no role at all" (AC6).

## 0.3 Module and type shapes

```elixir
defmodule Letflow.Api.Authorization do
  @type role ::
          :PLATFORM_ADMIN
          | :PROCESS_DESIGNER
          | :PROCESS_OPERATOR
          | :TASK_WORKER
          | :AGENT_RUNNER

  @type permission ::
          :DefinitionsWrite | :DefinitionsRead | :InstancesStart | :InstancesCancel
          | :InstancesRead | :TasksRead | :TasksComplete | :TasksAssign
          | :UsersGroupsRolesManage | :TokensManage | :AuditRead | :DlqOperate
          | :MetricsRead | :WebhooksManage

  @type access_decision_kind :: :Allow | :Deny403 | :AllowWithRowFilter

  @type endpoint_policy_key ::
          :DefinitionsCreate | :DefinitionsUpdate | :DefinitionsPatch
          | :DefinitionsActivate | :DefinitionsRead | :InstancesStart
          | :InstancesCancel | :InstancesRead | :TasksList | :TasksGetById
          | :TasksComplete | :TasksAssign | :TasksReassign | :UsersManage
          | :GroupsManage | :TokensManage | :AuditRead | :DlqReadRetryDiscard
          | :MetricsRead | :WebhookSubscriptionsManage | :Unknown

  @type task_row_scope :: :all | {:own_user_and_groups, String.t()}

  defmodule AccessContext do
    @enforce_keys [:user_id, :roles]
    defstruct [:user_id, :roles]
    @type t :: %__MODULE__{
            user_id: String.t(),
            roles: [Letflow.Api.Authorization.role()]
          }
  end

  defmodule AccessDecision do
    @enforce_keys [:kind]
    defstruct kind: nil, task_scope: nil
    @type t :: %__MODULE__{
            kind: Letflow.Api.Authorization.access_decision_kind(),
            task_scope: Letflow.Api.Authorization.task_row_scope() | nil
          }
  end
end
```

Enum values keep R-Co's exact `SCREAMING_CASE`/`PascalCase` spellings as atoms
(`:PLATFORM_ADMIN`, `:DefinitionsWrite`, `:Allow`, `:TasksList`, ...) rather than
Elixir's conventional `snake_case`, per the requirement's explicit "port R-Co's
enums exactly, not a renamed approximation" and AC1's "R-Co's exact names" —
this is one of the rare cases in this codebase where exact-port fidelity outranks
Elixir idiom, stated here so REVIEWER doesn't flag it as a style violation.

`task_scope` uses Elixir tagged tuples (`:all`, `{:own_user_and_groups, user_id}`)
rather than a struct, matching how R-Co's `union(enum)` most naturally ports — this
mirrors `TaskRowScope`'s own two-variant shape without inventing extra struct
machinery for a two-case union.

## 0.4 `evaluate_access/2` — ports `evaluateAccess` L114-139 exactly

```elixir
@spec evaluate_access(AccessContext.t(), endpoint_policy_key()) :: AccessDecision.t()
```

Same branch order as the Zig source:
1. `endpoint == :Unknown` → `:PLATFORM_ADMIN` in roles ? `Allow`/`nil` : `Deny403`/`nil`.
2. `endpoint == :MetricsRead` → always `Allow`/`:all` (no permission check — matches
   L122-124 exactly; `MetricsRead` permission exists in the enum but this endpoint
   never checks it, a direct port of what looks like an odd but deliberate R-Co
   choice, not something to "fix").
3. Otherwise: `required_permission(endpoint)` — `Deny403`/`nil` if no role in
   `ctx.roles` grants it.
4. If `endpoint == :TasksList` AND `is_task_worker_only?(ctx.roles)` →
   `AllowWithRowFilter` / `{:own_user_and_groups, ctx.user_id}` — **`ctx.user_id`
   is the `AccessContext` struct's own field, populated by the caller from
   `conn.assigns[:auth_context][:user_id]` (the AuthPipeline-resolved, DB-backed
   user id), never from a request parameter or query string — this is what makes
   AC5's proof true: nothing about a caller-supplied `assignee_id` filter ever
   reaches this function's input at all, so it structurally cannot influence the
   scope.**
5. Otherwise → `Allow`/`:all`.

`is_task_worker_only?/1` ports L141-146 exactly: `TASK_WORKER` present AND none of
`PLATFORM_ADMIN`/`PROCESS_DESIGNER`/`PROCESS_OPERATOR` present.

`required_permission/1` ports the L148-169 switch exactly, including the SVC-04
`ServicesRead`/`AdminServicesManage`/`AdminServicesRead` entries (ported since they're
in the source, though nothing in this codebase yet calls `endpoint_policy_key/2`
with a path that would produce them — same "port but unreachable" treatment as
AGENT_RUNNER).

`has_permission?/2`, `has_role?/2`, `role_allows?/2` port L171-222 exactly,
including the full 5-way `role_allows?/2` permission matrix.

## 0.5 The 403-vs-404 invariant (INV-5) — stated in the moduledoc, not enforced here

This module answers ONE question: given a caller's roles and an endpoint, is the
action allowed? It has no notion of tenant boundaries and never will — a resource
belonging to a different tenant must never even reach a call to
`evaluate_access/2` with that resource's data; REQ-072's request-context/scoping
layer is responsible for resolving "does this id exist AND belong to my tenant"
BEFORE authorization runs, and must return 404 (not delegate to this module's
`Deny403`) when a resource exists only in another tenant. Getting this backwards —
routing a cross-tenant lookup through this module and letting a `Deny403` leak
back to the caller — would let a prober distinguish "exists, not yours" (403) from
"never existed" (would otherwise also need to be 403, but from a different code
path, at different latency) violating INV-5. This module's moduledoc states this
boundary explicitly, in R-Co's own terms, so a future caller doesn't get it
backwards.

## 0.6 AGENT_RUNNER / DlqOperate / WebhooksManage — ported but unreachable

Stated in the moduledoc: `AGENT_RUNNER` (role) has no S4 route — it's the runtime
agent-orchestration role, deferred subsystem. `DlqOperate` and `WebhooksManage`
(permissions) are consumed only by `DlqReadRetryDiscard` and
`WebhookSubscriptionsManage` endpoint keys respectively, neither of which any
current route produces — DLQ and webhook dispatch are both deferred subsystems.
Ported anyway so the matrix matches R-Co's exactly (AC1's enumeration test would
fail otherwise), and so a later reader doesn't have to rediscover the gap.

## 0.7 Tests (test/letflow/api/authorization_test.exs)

Covers all 9 acceptance criteria, plus `roles_from_strings/1`'s conversion
behaviour (§0.2) since that's the actual boundary AC6 and INV-2 depend on:

- AC1: enumerate `Role`'s 5 values and `Permission`'s 14 values against literal
  expected lists.
- AC2: one test per role (5 total), each asserting a permission it grants and one
  it denies, derived directly from `role_allows?/2`'s ported matrix.
- AC3: all 3 `AccessDecisionKind` values each produced by at least one
  `evaluate_access/2` call in the suite (cross-referenced, not a separate test).
- AC4: 4 tests — TASK_WORKER-only → `AllowWithRowFilter`/own id; TASK_WORKER +
  each of the 3 widening roles individually → plain `Allow`/`:all` (3 tests) —
  matches "4 tests, one per widening role plus the TASK_WORKER-only case" exactly.
- AC5: TASK_WORKER-only `AccessContext` constructed with `user_id: "worker-1"`;
  `evaluate_access/2` is called with ONLY that struct and the endpoint key — there
  is no parameter through which a caller-supplied assignee filter could even be
  passed to this function, so the proof is structural: the function signature
  itself has no slot for request-derived data, and the test asserts the returned
  scope is `{:own_user_and_groups, "worker-1"}` regardless. (A second variant
  test also shows a *different* `user_id` in the context yields *that* user's id
  as the scope — proving the scope tracks `ctx.user_id`, not any fixed value.)
- AC6: `AccessContext` with `roles: []` (no role at all — the closed conversion
  in §0.2 guarantees this is what an all-unrecognized-strings token produces too)
  → `Deny403` for a representative permission-gated endpoint, not defaulted to
  any allow.
- AC7/AC8: moduledoc content assertions (grep the compiled moduledoc string for
  the required phrases) — a mechanical check that the required prose actually
  exists, not just a human read-through.
- AC9: runs the REAL `Letflow.Plugs.AuthPipeline.call/2` (via
  `test/letflow/plugs/auth_pipeline_test.exs`'s own established
  `Plug.Test.conn/3` + real-Postgres-tenant pattern) against the fixed
  `TokenVerifierDouble` sentinel token, reads `conn.assigns[:auth_context][:roles]`
  (which the double sets to `["VIEWER"]` — unrecognized by `roles_from_strings/1`),
  converts it, and confirms `evaluate_access/2` on the result denies a
  representative permission-gated endpoint — proving the read comes from the
  REAL assign key populated by the REAL plug, not a hand-built map, while also
  demonstrating the conversion's safe-drop behaviour on an unrecognized live
  role string end-to-end.

## 0.8 Open questions

None — R-Co's source and the requirement's acceptance criteria fully determine
this module's behaviour; no design choice here was left to guesswork.
