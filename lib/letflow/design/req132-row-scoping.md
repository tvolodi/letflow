# REQ-132 — Row scoping for `AllowWithRowFilter` on the task read path

**Status note (read first).** This design documents the row-scoping mechanism the
requirement asks for — and, on inspection of the already-shipped code, **that mechanism
is already fully implemented** in `lib/letflow/routers/tasks.ex` and `lib/letflow/tasks.ex`
(landed under REQ-083/REQ-085/REQ-130/REQ-131, ahead of REQ-132's own formal gate). Every
acceptance criterion below maps to code that already exists on `main`, not to new code
this design calls for ELIXIR-DEV to write. See "Open questions" for what that means for
Step 2a, and for the one real gap found (test coverage, not implementation).

## 1. How the `AllowWithRowFilter` decision reaches the query layer

`Letflow.Plugs.Authorize` (mounted by every router via `use Letflow.Api.AuthorizedRouter`)
calls `Letflow.Api.Authorization.evaluate_access/2` once per request and, on any non-`Deny403`
kind (`:Allow` **or** `:AllowWithRowFilter` — both fall through the same `case` clause,
`lib/letflow/plugs/authorize.ex:114-124`), assigns two conn keys before the router's handler
runs:

* `conn.assigns[:scoped_opts]` — `[prefix: schema]`, from `Letflow.Api.Context.scoped_repo_opts/1`
  (REQ-072). This is the *only* source of tenant scope; it is resolved before authorization is
  evaluated and is never touched by this requirement.
* `conn.assigns[:access_decision]` — the **full** `%Letflow.Api.Authorization.AccessDecision{}`
  struct (`kind` + `task_scope`), not collapsed to a boolean. This is the only conn key that
  carries `task_scope`, and `GET /tasks`/`GET /tasks/inbox` are the only handlers in the
  codebase that read it (`lib/letflow/plugs/authorize.ex:63-76`'s own moduledoc note).

`Letflow.Routers.Tasks`'s two `authz_get` route bodies pass this straight to their handlers:

```
authz_get "/inbox", :TasksList do
  handle_inbox(conn, conn.assigns.scoped_opts, conn.assigns.access_decision)
end

authz_get "/", :TasksList do
  handle_list(conn, conn.assigns.scoped_opts, conn.assigns.access_decision)
end
```

(`lib/letflow/routers/tasks.ex:111-117`). No other conn assign, header, or query param is
part of this path — `decision` is the router's only view of "was this filtered, and how."

## 2. `handle_list/3` (`GET /tasks`) — exact scope-selection function

```
@spec build_list_assignee_scope(
        Authorization.AccessDecision.t(),
        assignee_id :: String.t() | nil,
        Letflow.Tasks.opts()
      ) :: Letflow.Tasks.assignee_scope()
```

Three clauses, matched on `decision.task_scope` first (`lib/letflow/routers/tasks.ex:186-204`):

1. `task_scope: {:own_user_and_groups, user_id}` (AllowWithRowFilter, task-worker-only) →
   `{:principal, Letflow.Tasks.resolve_principal_scope(user_id, opts)}`. **The clause's own
   second parameter is bound as `_assignee_id` — structurally unread**, not merely unused by
   convention: there is no branch inside this clause that inspects the query-string value at
   all, so a caller-supplied `?assignee_id=` cannot reach this scope by any code path (AC4).
   `user_id` here is `ctx.user_id` from `Letflow.Api.Authorization.AccessContext` — the same
   value `Letflow.Plugs.Authorize` read from `conn.assigns.auth_context.user_id`
   (`authorize.ex:104`) when it built the `AccessContext` the matrix evaluated — never a
   request-observed value at this layer either.
2. `task_scope: :all`, `assignee_id: nil` → `:unfiltered` — the plain-allow, no-filter case
   (AC3).
3. `task_scope: :all`, `assignee_id: <value>` → `{:explicit_user, assignee_id}` — an
   operator/designer/admin's own optional query-string filter, only reachable when
   `task_scope` is `:all` (i.e. `evaluate_access/2` did *not* return `AllowWithRowFilter` for
   this caller).

Clause 1 is matched before clause 2/3 are ever considered (Elixir pattern-matches top to
bottom on the full 3-arg call), so a `:AllowWithRowFilter` decision can never fall through to
the `assignee_id`-reading clauses — this is what makes AC4 structural rather than incidental.

## 3. `handle_inbox/3` (`GET /tasks/inbox`) — same scope, decision unused by design

`handle_inbox/3` does **not** read `conn.assigns.access_decision` at all (bound as `_decision`,
`lib/letflow/routers/tasks.ex:208`) — R-Co's own `handleInbox` never calls `evaluateAccess`
itself either (it delegates entirely to `handleList`'s single call), so `/tasks/inbox`'s
authorization decision is `:AllowWithRowFilter`/`:Allow` exactly like `/tasks`'s would be for
the same caller, but the *scoping* decision here is re-derived independently via
`build_inbox_assignee_scope/3` (`lib/letflow/routers/tasks.ex:234-242`): it converts
`conn.assigns.auth_context.roles` to role atoms, and branches on
`Authorization.is_task_worker_only?/1` — the worker-only branch returns
`{:principal, Tasks.resolve_principal_scope(user_id, opts)}`, the else branch returns
`:unfiltered`; no other clause or condition is present.

This reaches the *same* `{:principal, principal_scope()}` shape via a direct
`is_task_worker_only?/1` role check rather than by reading `task_scope` off the decision —
both routes converge on identical `Letflow.Tasks.assignee_scope()` values for a task-worker
caller, so §4/§5 below (the actual query and tenant-scoping mechanics) apply identically to
both. `/inbox` never reads any query param at all (no `status`/`instance_id`/`assignee_id`
parsing exists in `handle_inbox/3`), so there is no widening surface to close here beyond what
§2 already closes for `/tasks`.

## 4. The Ecto query shape — groups-inclusive `WHERE`, in `Letflow.Tasks`

`Letflow.Tasks.list_tasks/2` (`lib/letflow/tasks.ex:202-223`) builds the query by piping
through `filter_by_assignee_scope/2` (`lib/letflow/tasks.ex:613-634`), a 3-clause private
function matched on its second argument: the `:unfiltered` clause returns `query`
unchanged (identity, no `where`); the `{:explicit_user, user_id}` clause adds
`where: t.assignee_type == "USER" and t.assignee_ref == ^user_id`; the `{:principal,
%{user_id:, group_ids:, role_names:}}` clause adds a 3-way `or`-composed `where` — user
match on `assignee_type == "USER"`/`assignee_ref == ^user_id`, group match on
`assignee_type == "GROUP"`/`assignee_ref in ^group_ids`, role match on `assignee_type ==
"ROLE"`/`assignee_ref in ^role_names`.

This is the groups-inclusive `WHERE` the requirement calls for: a task-worker's row set is the
union of (a) directly assigned to them, (b) assigned to a group they belong to, and (c)
assigned to a role bound to a group they belong to (role inclusion, not in the requirement's
own wording but present in REQ-083's original text/tests and left as-is — narrowing it now
would itself be the "silent behaviour change to a done module" the requirement text warns
against, just in the other direction). No `LIMIT`/`OFFSET` or pagination interaction: this
`WHERE` composes with `filter_by_status/2`, `filter_by_instance_id/2`, and the cursor `WHERE`
via ordinary `Ecto.Query` `from/2` re-binding, no raw SQL, all three call sites use bound `^`
parameters (no interpolation, INV-7).

`principal_scope()` (`user_id`, `group_ids`, `role_names`) is built by
`resolve_principal_scope/2` (`lib/letflow/tasks.ex:331-352`):

```
@spec resolve_principal_scope(user_id :: String.t(), opts()) :: principal_scope()
```

* `group_ids` — `Repo.all(from m in GroupMember, where: m.user_id == ^user_id, select: m.group_id, prefix: prefix)`.
* `role_names` — `Repo.all(from t in TenantRole, where: t.group_id in ^group_ids, select: ..., prefix: prefix) |> Enum.map(& &1.name)`.

Both reads take `user_id` from the single argument the router passed in (itself sourced from
`AccessDecision.task_scope`'s tuple, or from `auth_context.user_id` on the `/inbox` path per
§3) — never from a second, independently-read value.

## 5. `assignee_id` query param — validated for shape, then routed or discarded

`handle_list/3` (`lib/letflow/routers/tasks.ex:145-166`) parses `assignee_id` once,
generically, with no awareness yet of whether it will be used: it binds
`assignee_id` to `non_empty(Map.get(query, "assignee_id"))`, then passes that value
straight into `build_list_assignee_scope(decision, assignee_id, opts)` (§2) as the
scope-selection call's second argument — no intermediate branching on `assignee_id`
happens in `handle_list/3` itself.

`non_empty/1` only normalizes `""`/`nil` — it performs no authorization-relevant check. The
authorization-relevant decision is made entirely inside `build_list_assignee_scope/3` (§2):
the value is either threaded into `{:explicit_user, assignee_id}` (only reachable when
`task_scope == :all`) or never read (when `task_scope == {:own_user_and_groups, _}`). There is
no code path — no `Map.merge`, no fallback, no `||`-chain — that combines a caller-supplied
`assignee_id` with a `{:own_user_and_groups, _}` scope's own `user_id`. This is the concrete
answer to the requirement text's central risk ("the query parameter and the row filter want to
feed the same Ecto where clause") — they don't: they are two disjoint branches of one 3-clause
function, never merged.

## 6. Composition with REQ-072 tenant scoping

`opts` (`[prefix: schema]`) is threaded unchanged from `conn.assigns.scoped_opts`
(`Letflow.Api.Context.scoped_repo_opts/1`, REQ-072) through the router into
`Letflow.Tasks.list_tasks/2`, and from there into every `Repo.all/Repo.one` call in this
module, including `resolve_principal_scope/2`'s own two group/role queries — all under the
*same* `:prefix` value the request's tenant resolved to. There is no second, independent
tenant-derivation anywhere in this path: a task, a group, or a role from a different tenant's
schema is structurally unreachable (a different Postgres schema, not a filtered row) regardless
of what `task_scope`/`assignee_scope` narrowing is layered on top. This is proven for
`GET /tasks/inbox` today by `test/letflow/routers/tasks_test.exs`'s "AC2 extra assurance" case
(role-name collision across tenants); §8's open question below is that the identical case is
not yet asserted for plain `GET /tasks`.

## 7. Plain-allow callers stay unfiltered (AC3)

Any endpoint/role combination that does **not** hit `is_task_worker_only?/1`'s narrow
definition (`has_role?(:TASK_WORKER) and not PLATFORM_ADMIN and not PROCESS_DESIGNER and not
PROCESS_OPERATOR`, `authorization.ex:376-381`) receives `%AccessDecision{kind: :Allow,
task_scope: :all}` from `evaluate_access/2`. `build_list_assignee_scope/3`'s clause 2/3 (§2)
apply, and `filter_by_assignee_scope(query, :unfiltered)` (§4) is a pure identity — no `WHERE`
clause is added by this mechanism at all. This is what keeps the filter from applying
indiscriminately: it is reached only through the one decision shape (`{:own_user_and_groups,
_}`) that names it, never as a default.

## 8. Acceptance criteria → design element map

| AC | Design element |
|---|---|
| 1 (task-worker sees own+group rows, nothing else) | §4's `filter_by_assignee_scope/2` `{:principal, _}` clause, fed by §2 clause 1 and `resolve_principal_scope/2` (§4) |
| 2 (`?assignee_id=<other user>` does not widen) | §2 clause 1's structurally-unread `_assignee_id` parameter; §5's "no merge path" argument |
| 3 (plain-allow role stays unfiltered) | §7; §2 clause 2; §4's `:unfiltered` identity clause |
| 4 (scope derived from the decision tuple only, in code) | §1 (decision sourced from `Letflow.Plugs.Authorize`, itself from `evaluate_access/2`'s `ctx.user_id`) + §2's pattern match on `decision.task_scope` — no other input feeds `build_list_assignee_scope/3`'s `{:principal, _}` branch |
| 5 (REQ-072 tenant scoping still applies underneath) | §6 — single `:prefix` threaded through every query in this path, including group/role resolution |

## 9. DB tables/columns touched

**None new.** This design reads three already-shipped, tenant-schema-scoped tables, no
migration:

* `tasks` (`Letflow.Engine.Task`, REQ-043) — `assignee_type`, `assignee_ref` (both already
  indexed/queried by the existing `filter_by_assignee_scope/2` clauses).
* `group_members` (`Letflow.Identity.GroupMember`, REQ-074) — `user_id`, `group_id`.
* `tenant_roles` (`Letflow.Identity.TenantRole`) — `name`, `group_id`.

## 10. Cross-module dependencies

`Letflow.Routers.Tasks` → `Letflow.Api.Authorization` (decision shape) → `Letflow.Tasks`
(`resolve_principal_scope/2`, `list_tasks/2`, `filter_by_assignee_scope/2`) →
`Letflow.Identity.GroupMember`/`Letflow.Identity.TenantRole` (Ecto schemas, read-only from this
path) → `Letflow.Repo` (tenant-`:prefix`-scoped). `Letflow.Plugs.Authorize` /
`Letflow.Api.AuthorizedRouter` (REQ-130/131) supply `conn.assigns.access_decision`/
`conn.assigns.scoped_opts`; `Letflow.Api.Context.scoped_repo_opts/1` (REQ-072) supplies the
tenant prefix underlying both.

## 11. Invariants

* **INV-2 structural, not tested-only.** `evaluate_access/2` takes no third parameter (§1's
  own read of `authorization.ex`'s moduledoc); `build_list_assignee_scope/3`'s
  `{:own_user_and_groups, _}` clause has no code path that reads its own `assignee_id`
  parameter (§2/§5). Both hold today, unconditionally.
* **A `:AllowWithRowFilter` decision is never treated as `:Deny403` nor as unfiltered
  `:Allow`.** `Letflow.Plugs.Authorize`'s `case decision.kind` groups `:Allow` and
  `:AllowWithRowFilter` on the same non-deny branch (§1) — the router, not the plug, is what
  turns that into an actual filter, via `task_scope`, never via `kind` alone.
* **Tenant scope is never derived from anything other than `conn.assigns.scoped_opts`/opts's
  `:prefix`** — no function in this path accepts or infers a schema from a different source
  (§6).

## 12. Open questions

1. **This design's every element already exists on `main`** (verified: `git diff
   main...HEAD --stat` on this branch, before any change, is empty). ELIXIR-DEV's Step 2a
   review should confirm this same finding independently rather than write new code on
   spec — if the independent read agrees no `lib/` change is needed to satisfy AC1-5, Step
   2a's `artifacts_out` should say so explicitly (citing this doc) rather than force a
   no-op diff to exist. This is unusual for a WF-02 run and is flagged here, not silently
   assumed, per this project's "don't silently resolve" rule — CODE-DESIGN-VALIDATOR and
   ORCH should treat "no code change needed, confirm via reading" as a legitimate Step 2a
   outcome for this specific requirement, not a sign the step was skipped.
2. **Real gap found: test coverage, not implementation.** `test/letflow/routers/tasks_test.exs`
   already has AC1/AC2/AC5-shaped coverage — but scoped to `GET /tasks/inbox` (lines
   401-473) and to a **user-only** `assignee_id`-widening case on `GET /tasks` (lines
   690-712, no group/role fixtures). REQ-132's own AC1/AC2/AC5 wording targets "a TASK_WORKER
   listing tasks" (`GET /tasks`, REQ-083's `handleList`) with a seeded third-user task, a
   member group task, a non-member group task, and (AC5) a cross-tenant proof — none of that
   exact combination is yet asserted against `GET /tasks` specifically (only against
   `/inbox`, which shares the mechanism but is a textually distinct endpoint/test target).
   TEST-DESIGNER (Step 3) should add `GET /tasks` variants of the existing `/inbox` AC2 test
   (line 401) and AC2-extra-assurance cross-tenant test (line 440), plus extend the existing
   INV-2 test (line 690) with a group-task fixture, rather than treating the `/inbox` tests as
   sufficient coverage for a `GET /tasks`-specific acceptance criterion.
3. **Role-inclusive scope beyond the requirement's own wording.** §4's `WHERE` also includes
   `assignee_type == "ROLE"` rows, which the requirement's own prose ("assigned to the caller
   AND tasks assigned to groups the caller belongs to") does not mention. This is
   REQ-083's pre-existing, already-`done`, already-tested behavior — removing it now would
   itself be the kind of silent behavior change to a done module the requirement explicitly
   warns against making in the other direction. Not changed by this design; named here so a
   later reader does not mistake the omission from the requirement's prose for a gap.
