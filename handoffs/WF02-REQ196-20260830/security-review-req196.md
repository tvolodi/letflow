# SECURITY-REVIEWER report — REQ-196 (GET /api/v1/audit repointed to audit_entries)

run_id: WF02-REQ196-20260830, step: 02c, agent: SECURITY-REVIEWER
verdict: **PASS**

## Scope test

This is a tenant-data-path change: it repoints a live, authenticated
`GET /api/v1/audit` handler's data source and response-shaping logic. Scope test
applies — full substantive review performed, not a scope-out.

## Independent verification performed this session

- `git diff main...HEAD --stat`: 11 files changed. Confirmed touched: `lib/letflow/audit.ex`,
  `lib/letflow/routers/audit.ex`, `test/letflow/routers/req078_supporting_routes_test.exs`,
  new `test/letflow/routers/req196_audit_route_test.exs`, design doc, handoff/status files.
  Confirmed **zero** diff against `lib/letflow/api/authorization.ex`, anything under `web/`,
  any `priv/repo/migrations/*.exs`, and `lib/letflow/audit/entry.ex` (explicit
  `git diff --stat` on those paths returned empty).
- `mix compile --warnings-as-errors`: clean, exit 0, no output.
- `mix format --check-formatted`: clean, no output.
- `mix test test/letflow/routers/req196_audit_route_test.exs test/letflow/routers/req078_supporting_routes_test.exs test/letflow/audit_test.exs test/letflow/audit_capture_test.exs test/letflow/audit_dispositions_test.exs`:
  **63 passed**, 0 failures.
- `mix letflow.lint_handoffs`: `0 new violations across 1566 handoff files (25 pre-existing
  grandfathered, traced to ISS-0190)` — matches ELIXIR-DEV's claim.
- `grep -n "AuditRead" lib/letflow/api/authorization.ex`: line 282
  `def endpoint_policy_key("GET", "/audit"), do: :AuditRead` — unchanged, confirmed by the
  empty diff above.
- Read `lib/letflow/audit.ex` and `lib/letflow/routers/audit.ex` in full (not excerpts).
- Read the req078 fixture diff in full.

## INV-1..INV-8 gate

- **INV-1 (tenant data isolation) — APPLIES, PASS.** `list_entries/1`'s `@type list_params`
  requires `:prefix` as a non-optional map key (`lib/letflow/audit.ex:144-153`), and the
  single query in the function passes it straight to `Repo.all(query, prefix: prefix)`
  (`audit.ex:291`) with no other Repo access path in the module. The router resolves
  `prefix` exclusively from `conn.assigns.scoped_opts` (`Keyword.fetch!(scope, :prefix)`,
  `routers/audit.ex:168`), and `scoped_opts` itself is derived from
  `conn.assigns[:auth_context][:tenant_id]` upstream — never from any query param, header,
  or body field. Every filter (`from`/`to`/`actor_id`/`resource_id`/`resource_type`/`cursor`)
  is applied as an additional `WHERE` predicate (`where_from/2` etc., `audit.ex:309-336`) —
  none of them can substitute for or override the `prefix:` schema-qualification, so no
  filter value, however crafted, can widen the query past the tenant's own schema. (a)
  scoped via `prefix:` — confirmed. (b) no migration touched, N/A. (c) `tenant_id` is
  resolved server-side inside `insert_entry/3` from `prefix` via
  `TenantProvisioning.tenant_id_for_schema_name/1` (write path, unchanged by this diff) —
  not accepted as a caller field; `list_entries/1` is read-only and doesn't write `tenant_id`
  at all, so (c) doesn't apply to this diff's own code path but the invariant it protects
  is not disturbed.
- **INV-2 (server-side field authorisation)** — reference states "None yet — S4 not started,"
  formally NOT-APPLICABLE per the applicability note. Verified anyway as a courtesy since the
  handoff's own task explicitly asked for it: `audit_item/1` (`routers/audit.ex:318-330`) is
  a hand-built 8-key map (`audit_id`, `actor_id`, `action`, `resource_type`, `resource_id`,
  `timestamp`, `before_state`, `after_state`) constructed from named `Entry` struct field
  reads — never a `Jason.Encoder` derivation over the struct. `tenant_id`, `chain_hash`,
  `prev_chain_hash`, `trace_id`, and `inserted_at` (all present on `Entry`, confirmed via
  `Letflow.Audit.entry_attrs`/schema fields referenced in `audit.ex`) are absent from this
  map — none of them is read or assigned anywhere in `audit_item/1`. PASS on the merits,
  though not gating today.
- **INV-3 (untrusted runtime sandboxing)** — NOT-APPLICABLE, S5 not started, no Lua/WASM
  code touched.
- **INV-4 (secrets by reference only) — APPLIES, PASS.** No secret material, token, or
  credential is read, logged, or serialised anywhere in this diff.
  `grep -rn "System.get_env"` / secret-literal heuristics: no hits in the changed files.
  `struct_state/2`'s `exclude` mechanism (unchanged, pre-existing) is the only
  credential-adjacent code nearby and is untouched.
- **INV-5 (not-found/forbidden indistinguishability)** — NOT-APPLICABLE, S4 not started;
  `GET /audit` is a list endpoint, not a lookup-by-ID endpoint, so this invariant's
  precondition doesn't even arise here.
- **INV-6 (new data-access paths prove scoping)** — this SECURITY-REVIEWER handoff itself
  satisfies it; see INV-1 above for the explicit scoping statement.
- **INV-7 (no SQL string interpolation) — APPLIES, PASS.**
  `grep -rn "Repo.query" lib/letflow/audit.ex lib/letflow/routers/audit.ex` — no hits. All
  queries are built via `Ecto.Query`'s `where/3`/`order_by/3`/`limit/2` macros with pinned
  (`^`) values, parameterised by construction.
- **INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, PASS.** The one
  realistic external-input failure mode in this diff — a malformed (non-UUID) `actor_id`
  filter value, which would otherwise raise `Ecto.Query.CastError` from Postgrex's binary_id
  cast — is caught ahead of the query by `validate_actor_id/1`
  (`audit.ex:299-307`, using `Ecto.UUID.cast/1`) and turned into a typed
  `{:error, :invalid_actor_id}`, which `render_page/2` maps to a 422
  (`routers/audit.ex:209-211`). Confirmed no bare `{:ok, x} =` pattern was introduced in
  either changed file (`grep -n "^\s*{:ok, .*} = "` over both — no hits).

## Point-by-point findings requested by ORCH

**2. Cursor manipulation risk — no cross-tenant read possible.** The `{timestamp, id}` seek
pair only ever contributes a `WHERE (timestamp < cursor_ts) OR (timestamp = cursor_ts AND id <
cursor_id)` predicate (`where_cursor_seek/2`, `audit.ex:328-336`) against whatever schema
`prefix:` already selects. `prefix` is passed as a wholly separate function argument/`Repo.all`
option, resolved server-side and never touched by cursor content. Even a cursor forged to
name a real row-id from another tenant would only narrow the query to `id < <that id>`
*within the caller's own schema* — Postgres's schema-qualified execution means the query
literally cannot see another schema's `audit_entries` table regardless of the WHERE clause's
content. Structurally sound: cursor content and tenant scoping are orthogonal, non-interacting
mechanisms.

**5. Tenant-scoping (AC6) — confirmed structurally sound and test-covered.**
`list_entries/1`'s only query runs `Repo.all(query, prefix: prefix)`, `prefix` sourced
exclusively from `conn.assigns.scoped_opts` → `auth_context.tenant_id`, never
request-derived. `req078_supporting_routes_test.exs`'s AC2 test and the new
`req196_audit_route_test.exs` AC6 describe block both exercise this at the HTTP level with
two live tenants, asserting the foreign tenant's `resource_id`/`audit_id` never appears —
and both pass (confirmed in the 63/63 run above).

**6. Response-field leak risk (before_state/after_state exposure) — none found.**
`audit_item/1`'s response map is a fixed 8-key literal, hand-listing only
`audit_id`/`actor_id`/`action`/`resource_type`/`resource_id`/`timestamp`/`before_state`/
`after_state`. `Entry`'s schema additionally carries `tenant_id`, `chain_hash`,
`prev_chain_hash`, and `inserted_at` (confirmed present as struct fields via `audit.ex`'s own
`fields_from_entry/1` and `insert_attrs` construction) — none of these four is read or
emitted anywhere in `audit_item/1` or elsewhere in the router. `before_state`/`after_state`
are passed through as-is from the stored column (already pre-sanitized at write time via
`struct_state/2`'s `exclude` mechanism upstream in the various context modules that call
`insert_entry/3` — unchanged by this diff), so no new leak surface is introduced by populating
those two fields for real.

## req078_supporting_routes_test.exs fixture change — legitimate repair, not a weakening

Confirmed by reading the full diff: `seed_audit_entry!/2` replaces
`register_event_type!`/`seed_projection!`/`append_event!` with a direct
`Audit.insert_entry(Repo, attrs, schema_name)` call. The file's own structural assertions
are unchanged in substance — the AC2 cross-tenant test still asserts
`refute instance_b in resource_ids` and (renamed) `refute entry_b.id in audit_ids`; the
403-without-`:AuditRead` test is untouched in intent, only its seeding helper changed. This
is a stale-fixture repair tracking REQ-196's real schema change, not a loosening of any
assertion.

## Conclusion

All applicable invariants (INV-1, INV-4, INV-7, INV-8) PASS. INV-2/3/5 correctly
NOT-APPLICABLE per current stage (S4/S5 not started) — INV-2 additionally verified on the
merits despite not gating today. No defect found. Routing to REVIEWER next.
