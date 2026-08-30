# REQ-192 CODE-DESIGN-VALIDATOR report (Step 1b, iteration 1)

Verdict: **FAIL**

## Checks that passed (verified independently against real source, not the design's narrative)

1. **Two-router claim (§1).** Read `test/letflow/api/authorization_enforcement_test.exs`
   L55-90 directly. `@mount_prefix` is a `router_module => single_prefix_string` map, and
   the per-router test does `prefix = Map.fetch!(@mount_prefix, @router)` then
   `full_path = full_path(prefix, local_path)` for every route the router declares. This
   is genuinely a strict one-router-to-one-mount-prefix mechanism with no dual-mount
   provision anywhere in the file. The design's claim that this forces two separate
   router modules (`Letflow.Routers.Services` + `Letflow.Routers.AdminServices`) rather
   than one dual-mounted router is accurate, not a dressed-up preference.

2. **Permission mapping (§3).** Read `lib/letflow/api/authorization.ex` L108-113 (policy
   key type), L308-313 (`endpoint_policy_key/2` clauses for `/services` and
   `/admin/services...`), L417-419 (`required_permission/1`: `:ServicesRead ->
   :DefinitionsRead`; `:AdminServicesManage`/`:AdminServicesRead ->
   :UsersGroupsRolesManage`), and L453-484 (`role_allows?/2`). Confirmed: every
   `role_allows?/2` clause except `:AGENT_RUNNER` (`false` unconditionally) lists or
   implies `:DefinitionsRead` (`:PLATFORM_ADMIN`'s catch-all `true`, plus
   `:PROCESS_DESIGNER`/`:PROCESS_OPERATOR`/`:TASK_WORKER` all explicitly list it), and
   only `:PLATFORM_ADMIN`'s catch-all grants `:UsersGroupsRolesManage` (no other clause
   names it). The design's claims match the real mapping exactly.

3. **409 mechanism (§11).** Read `lib/letflow/api/error.ex` L55-65 (`t()` struct:
   `type/title/status/detail/trace_id/errors/extensions`) and L351-360
   (`promotion_conflict/2`: `type: @problems_base <> "promotion-conflict"`, `status: 409`,
   `extensions: %{"conflicts" => conflicts}`), and `lib/letflow/api/response.ex`
   (`send_problem/2`, `conflict/2`, etc.). The two proposed constructors
   (`service_referenced_by_active_definitions/1`, `service_scope_narrowing_conflict/1`)
   genuinely follow this precedent's real shape (same struct fields, same string-keyed
   `extensions` convention). Also cross-checked the design's §9/§12 result-mapping tables
   against `Letflow.ServiceCatalog.update_scope/2`'s and `delete/1`'s real `@spec`s
   (service_catalog.ex L357-360, L399-403) — the design correctly distinguishes
   `delete/1`'s flat `[String.t()]` definition-id list from `update_scope/2`'s
   `[reference_conflict()]` (`%{tenant_id:, definition_ids:}`) list, matching the real
   return shapes exactly despite both using the same `:referenced_by_active_definitions`
   tag.

4. **Field-gap findings (§8).** Read `web/src/api/services.ts` (the real binding contract
   — note it lives at `web/src/api/services.ts`, not `web/src/types/api.ts`, which has no
   `ServiceRecord`/`RegisterServiceBody`/`UpdateServiceScopeBody` at all) and
   `lib/letflow/service_catalog/entry.ex` and `service_catalog.ex`'s `register_attrs()`
   type (L115-124). Confirmed both gaps as real: (a) `ServiceRecord.max_retries: number`
   (required) has no backing `Entry` column and no `register_attrs()` key — `Entry` only
   has `retry_policy :: String.t() | nil`; (b) `request_schema`/`response_schema` are
   required, non-nullable `string` in `ServiceRecord`/`RegisterServiceBody`, but
   `optional(...) => String.t() | nil` in `register_attrs()` and not in
   `insert_changeset/2`'s `validate_required/2` list. Both interim resolutions stated in
   the design are concrete and buildable, not guessed away.

5. **Stale-comment finding (§3).** Read `authorization.ex` L416-419 directly: the comment
   `# platform-admin enforced in handler, per Zig's comment` sits above the
   `:AdminServicesManage`/`:AdminServicesRead` clause, and no handler-level
   `PLATFORM_ADMIN`-only check exists anywhere in this design or the current codebase —
   the permission mapping alone achieves the restriction. The design correctly leaves
   this as a flagged finding rather than fixing `authorization.ex`, which is out of
   scope for this requirement.

6. **No implementation code.** `grep -n '```'` over the full 443-line design file returns
   zero matches — no fenced code block of any kind, let alone one reproducing real `.ex`
   content.

## The defect (real, not a nitpick) — §5's claimed router direct-schema-query precedent is false

Section 5 justifies `Letflow.Routers.AdminServices`'s `GET /` handler querying
`Letflow.ServiceCatalog.Entry` directly via `Repo`/`Ecto.Query` (bypassing the context
module, since `Letflow.ServiceCatalog` has no tenant-agnostic list-all function and adding
one is out of scope) with this sentence:

> "reading it via `Ecto.Query`/`Repo.all/1` from a router is not different in kind from
> `Letflow.Routers.Audit`'s or `Letflow.Routers.Metrics`'s own direct-schema-query
> precedents"

I read both cited routers in full. Neither one is a precedent for this:

* `lib/letflow/routers/audit.ex` delegates to `Letflow.EventStore.read_global/1` — a
  context-module function, not a raw `Repo`/`Ecto.Query` call from the router.
* `lib/letflow/routers/metrics.ex` delegates to `Letflow.Engine.count_instances_by_status/1`,
  `Letflow.Engine.count_tasks_by_status/1`, and
  `Letflow.Definitions.count_definitions_by_status/1` — again context-module functions,
  not direct schema queries.

I then checked every router under `lib/letflow/routers/` for any `Ecto.Query`/`Repo.all`/
`Repo.one`/`Repo.get` usage at all (`grep -rln`). The only hit is a code *comment* in
`promotions.ex` mentioning `Ecto.Query.CastError` — not an actual query call. **There is
no existing precedent anywhere in this codebase for a router module directly querying an
`Ecto.Schema` module, bypassing its owning context module.** The design's own hedge
("verify by inspection before implementing — the design does not claim a specific line
number for that precedent") does not fix this: it still asserts the precedent exists in
substance ("not different in kind from... own... precedents"), and on inspection it does
not.

This matters for more than accuracy. `Letflow.ServiceCatalog.Entry` being `alias`ed
elsewhere *inside* `Letflow.ServiceCatalog` itself is not evidence that routers-querying-
schemas-directly is an established, accepted pattern in this codebase — every other router
in this codebase (including the two the design cites) goes through its context module,
without exception. Per `docs/agents/instructions/core-directives.md`'s "no speculation"
rule and this role's mandate to catch "an ambiguous design that reaches implementation... 
exactly the failure mode this gate exists to prevent," a fabricated precedent used to wave
away a real layering-discipline question is not acceptable, even though the underlying
design decision (query `Entry` directly, since no `service_catalog.ex` change is permitted
and AC2 must be buildable) may well still be the right — or only — call available under
this requirement's stated scope boundary.

**What CODE-DESIGNER must fix:** remove the false Audit/Metrics precedent claim from §5.
State plainly that this is a genuine, first-of-its-kind exception to this codebase's
router→context-module layering discipline, made necessary only because (a) REQ-192's own
scope forbids adding a list-all function to `Letflow.ServiceCatalog`, and (b) AC2 cannot
be satisfied any other way — and that this exception should be called out explicitly for
REVIEWER sign-off at Step 2d (not folded quietly into "consistent with existing
precedent," since REVIEWER needs to independently weigh a real layering exception, not
rubber-stamp a false one). The OQ-1 open question already flags the duplication cost
correctly; it just needs to stop resting on a precedent that does not exist. This does not
require reversing the design's actual query-Entry-directly decision, which appears to be
the only buildable option given the stated scope boundary — only correcting the
justification given for it.

## Everything else

No other defect found. All 10 acceptance criteria map to concrete design sections (§4
AC1, §5 AC2, §6/§7 AC3, §13 AC4, §9/§12 AC5, §6 AC6, §10 AC7, §14 AC8, §14 AC9, out of
design scope AC10/mix test+compile). No TBD/deferral language. Function-result mapping
tables are unambiguous. Cross-module dependencies are listed (§1, §4, §5, §11).
