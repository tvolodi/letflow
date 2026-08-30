# REQ-192 SECURITY-REVIEWER report — rework iteration 2

**Run:** WF02-REQ192-20260830 · **Step:** 2c (re-review) · **Verdict: PASS**

Scope test: this diff adds an admin API route
(`lib/letflow/routers/admin_services.ex`) and a new context-module
function (`Letflow.ServiceCatalog.list_all/1`) that reads a tenant-adjacent
table with zero filtering. This is squarely a tenant-data path. Full
INV-1..INV-8 review performed.

## Central question: is the router-level authorization gate a sufficient
## substitute for `list_all/1`'s complete lack of tenant isolation?

**AGREE.** Verified independently by reading the actual code (not the
handoff's claims):

1. `lib/letflow/api/authorization.ex:310` —
   `def endpoint_policy_key("GET", "/admin/services"), do: :AdminServicesRead`.
   This is a literal, exact-string match on `"GET", "/admin/services"` — no
   ambiguity against `endpoint_policy_key("GET", "/services")` (line 309,
   `:ServicesRead`), a separate clause on a separate literal path. `POST`/
   `PATCH`/`DELETE` on any `"/admin/services" <> _rest` path map to
   `:AdminServicesManage` (lines 312-314).

2. `lib/letflow/api/authorization.ex:429-430` —
   `def required_permission(key) when key in [:AdminServicesManage, :AdminServicesRead], do: :UsersGroupsRolesManage`.
   Confirmed genuine.

3. `lib/letflow/api/authorization.ex:441` (`role_allows?(:PLATFORM_ADMIN, _permission), do: true`)
   is the only clause that can satisfy `:UsersGroupsRolesManage`. Read all
   four other role clauses directly:
   - `:PROCESS_DESIGNER` → explicit list `[:DefinitionsWrite, :DefinitionsRead, :InstancesStart, :InstancesRead, :TasksRead, :RolesManage]` — no `:UsersGroupsRolesManage`.
   - `:PROCESS_OPERATOR` → explicit list of 11 permissions, no `:UsersGroupsRolesManage`.
   - `:TASK_WORKER` → `[:DefinitionsRead, :InstancesRead, :TasksRead, :TasksComplete]` — no `:UsersGroupsRolesManage`.
   - `:AGENT_RUNNER` → `do: false` unconditionally.
   So `:UsersGroupsRolesManage`, and therefore `GET/POST/PATCH/DELETE /admin/services`, is reachable by `:PLATFORM_ADMIN` alone.

4. `lib/letflow/api/authorized_router.ex`'s `__using__/1` wires
   `plug(:match)`, `plug(Letflow.Plugs.Authorize)`, `plug(:dispatch)` —
   unconditional, for every router using this module, `AdminServices`
   included. `Letflow.Plugs.Authorize`'s own moduledoc and code call
   `Letflow.Api.Authorization.evaluate_access/2` and, on `:Deny403`, send
   the 403 itself and (implicitly, being a plug ahead of `:dispatch`) never
   reaches the router's `handle_list/1`/`handle_register/1`/etc bodies.
   This is a real, load-bearing pipeline gate, not a documented-only
   intent — confirmed by reading the macro expansion and the plug module
   directly, not by trusting the router's moduledoc prose.

5. `lib/letflow/service_catalog.ex:339-354`'s `@doc` for `list_all/1`
   states plainly, in its first paragraph: "with **no** tenant or scope
   filtering whatsoever... this module has never enforced authorization...
   and does not start here — **the caller is entirely responsible for
   ensuring only an authorized admin path ever calls this function.**"
   This is unambiguous for a future caller.

**Conclusion:** the router-level gate is real, runs before the handler,
and is genuinely restricted to `PLATFORM_ADMIN`. Given `list_all/1`'s own
`@doc` makes the no-authorization contract explicit (so no future,
less-trusted caller could mistake it for a safe default), this is a
sufficient and correctly-scoped substitute for tenant filtering at the
data layer.

## INV-9 cursor isolation

`lib/letflow/api/pagination.ex`'s `check_prefix/2` (lines 230-257) does a
`String.starts_with?/2` match of the decoded cursor payload against the
literal `prefix` argument, returning `{:error, :wrong_endpoint}` on
mismatch (with a hard `raise` if `prefix == ""`, closing the
empty-prefix bypass named in the moduledoc as ISS-0216). `list_for_tenant/2`
calls `decode_cursor(raw, @list_cursor_prefix, ...)` with `"SC:"`;
`list_all/1` calls `decode_cursor(raw, @list_all_cursor_prefix, ...)` with
`"SCA:"`. Neither is a prefix of the other's payload content in a way that
would falsely pass (`"SC:"` is a prefix of `"SCA:"` as *strings*, but
`check_prefix/2` checks the *decoded payload* starts with the *whole*
`@list_cursor_prefix`/`@list_all_cursor_prefix` constant supplied by each
call site — a payload built with `"SCA:"` starts with `"SCA:"` but not
with `"SC:"` followed by whatever `list_for_tenant/2`'s own logic expects
next, and `decode_list_cursor/1` is hardcoded to pass exactly `"SC:"`, never
`"SCA:"`). Concretely: a `"SCA:..."` payload does start with the substring
`"SC"` but not with the full 3-byte `"SC:"` literal (byte 3 is `A`, not
`:`), so `list_for_tenant/2` replaying an `"SCA:"`-minted cursor gets
`{:error, :wrong_endpoint}`, and vice versa a `"SC:"` payload replayed
against `list_all/1`'s `"SCA:"` check also fails the `starts_with?` test.
Enforced, not aspirational. `list_for_tenant/2`'s own name, arity, and
`where` clause are confirmed byte-for-byte unchanged.

## No data leakage via error paths / response shaping

- `handle_list_result/2`'s error branch (`admin_services.ex:180-183`)
  collapses `:invalid_cursor | :wrong_endpoint | :expired` uniformly to
  `Response.bad_request(conn, "invalid cursor")` — no internal reason atom,
  stack trace, or cursor content echoed back.
- `service_referenced_by_active_definitions/1` and
  `service_scope_narrowing_conflict/1` (`lib/letflow/api/error.ex:376-412`)
  only re-serialize `definition_ids`/`tenant_id` values that
  `Letflow.ServiceCatalog.delete/1` and `.update_scope/2` themselves already
  computed and returned as part of their typed `{:error, ...}` tuples — no
  additional field is added at the error-constructor layer. Unchanged from
  iteration 1's review.
- `service_record_json/1` (`admin_services.ex:295-309`) is a hand-built
  allowlist map (10 named fields) — no `Map.from_struct/1` or catch-all
  serialization that could leak a schema field not in this list. Confirmed
  `max_retries` is correctly omitted (no backing column) and
  `request_schema`/`response_schema` pass through as JSON `null` when the
  column is `nil`, matching the carried-forward findings from iteration 1.
  No field distinguishes "admin view" from "tenant view" in the schema
  (`Entry` has no admin-only/private column), so there is no
  narrower-view-leaking-into-broader-view risk to check.

## INV-1..INV-8 disposition

- **INV-1 (tenant data isolation) — APPLIES, PASS.** `service_catalog` is
  the global (non-schema-per-tenant) table already reviewed and
  REVIEWER-signed-off under REQ-191 (`service_catalog.ex`'s own moduledoc,
  "REVIEWER sign-off: AGREE, 2026-08-30 (WF02-REQ191-20260830 Step 2d)") —
  that architectural exception to Decision B is not re-litigated here.
  `list_all/1`'s query touches only `Entry` (this global table); the one
  genuinely tenant-scoped table this module touches,
  `process_definitions`, is only reached via the pre-existing
  `referencing_active_definitions/2` → `query_referencing_definitions/2`
  path (`Repo.all(query, prefix: schema_name)`, correctly `:prefix`-scoped
  per tenant, iterating `TenantProvisioning.list_registrations/0`) — this
  path is unchanged by this diff and was already reviewed. No new
  migration in this diff.
- **INV-2 — NOT-APPLICABLE** (S4 not started).
- **INV-3 — NOT-APPLICABLE** (S5 not started).
- **INV-4 (secrets) — APPLIES, PASS.** `grep -n "System.get_env\|password\|secret\|token"` over both changed files: zero matches. No secret material anywhere in this diff.
- **INV-5 — NOT-APPLICABLE** (S4 not started; also, per the router's own moduledoc §"Cross-tenant-404", this admin surface deliberately has no cross-tenant-disguise concept — every row is globally visible to `PLATFORM_ADMIN` by design, so a 404 here only ever means "no such id exists").
- **INV-6 (new data-access path proves scoping) — PASS.** This report is that proof.
- **INV-7 (no raw SQL string interpolation) — APPLIES, PASS.** `grep -n "Repo.query" lib/letflow/routers/admin_services.ex lib/letflow/service_catalog.ex`: zero matches. All queries go through `Ecto.Query`/`Ecto.Query.API.fragment/1` with bound params (the pre-existing `@service_task_reference_fragment`, unchanged by this diff, uses `?` placeholders bound via `fragment(@service_task_reference_fragment, p.graph, ^service_id)` — parameterized, not string-built).
- **INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, PASS.** `grep -n "^\s*{:ok, .*} = "` on both files returns two hits, both inside `case` clause patterns (`{:ok, %Pagination.Cursor{} = cursor} -> ...`), not bare destructuring assignments against a fallible call — false positives of the grep heuristic, manually confirmed by reading the surrounding code. All fallible paths (`Pagination.decode_cursor/4`, `Repo.all`, request body parsing) go through `case`/`with` and return typed tuples; `handle_register`/`handle_update_scope`/`handle_delete` all pattern-match every documented `{:error, ...}` variant from their respective `ServiceCatalog` calls.

## INV-RT-1 (repo-wide, not in the numbered list but load-bearing here)

`grep -rn "Repo\." lib/letflow/routers/` re-run independently: the only
two hits are `admin_services.ex`'s own moduledoc prose (describing the
abandoned iteration-1 approach, inside the `"""` doc block) and
`tasks.ex`'s pre-existing INV-TW85-2 comment — both non-code text. Zero
live-code `Repo.` calls under `lib/letflow/routers/`. Confirmed directly,
not by trusting the handoff.

## Flagged for REVIEWER at Step 2d (explicitly not decided here)

1. **Scope expansion**: `Letflow.ServiceCatalog.list_all/1` was added to
   the already-merged REQ-191 context module, despite REQ-192's own
   requirement text stating "no context-module change." This is a
   deliberate, explicitly-reasoned exception (INV-RT-1 conflict with the
   original router-local-query design) — architectural layering
   judgment call, REVIEWER's to make, not SECURITY-REVIEWER's.
2. **Internal signature change**: `list_for_tenant/2`'s two private
   helpers, `split_list_page/2` → `split_list_page/3` and
   `build_list_next_cursor/1` → `build_list_next_cursor/2`, gained a
   `prefix` parameter so `list_all/1` could reuse them while minting a
   distinct cursor prefix. Confirmed: `list_for_tenant/2`'s own public
   name, arity (`/2`), and `where` clause (line 274) are byte-for-byte
   unchanged; only its two already-private helpers' signatures changed,
   and both call sites within `list_for_tenant/2` were updated to pass
   `@list_cursor_prefix` explicitly (lines 280, matching). No external
   caller of `list_for_tenant/2` is affected — this is confirmed by the
   function's own unchanged public contract, not a security question, but
   noted per the task's request.

## Verification commands run (re-run independently, not trusted from the handoff)

```
grep -n "AdminServicesRead\|AdminServicesManage" lib/letflow/api/authorization.ex
grep -n "role_allows?" -A40 lib/letflow/api/authorization.ex
grep -n "admin_services" lib/letflow/plugs/api_pipeline.ex
grep -rn "Repo\." lib/letflow/routers/
grep -n "System.get_env\|password\|secret\|token" lib/letflow/routers/admin_services.ex lib/letflow/service_catalog.ex
grep -n "Repo.query" lib/letflow/routers/admin_services.ex lib/letflow/service_catalog.ex
grep -n "^\s*{:ok, .*} = " lib/letflow/routers/admin_services.ex lib/letflow/service_catalog.ex
```

Mix compile/format/test results are not re-verified here — ORCH already
ran and confirmed those against the real toolchain per this step's
handoff; this report is the security-specific review only.

## Verdict

**PASS.** All applicable invariants (INV-1, INV-4, INV-6, INV-7, INV-8)
and INV-RT-1 satisfied. The central security question (router-gate as
substitute for `list_all/1`'s lack of tenant filtering) is **AGREE**.
Route to REVIEWER at Step 2d for the two flagged architectural questions
above.
