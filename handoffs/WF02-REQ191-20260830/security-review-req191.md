# SECURITY-REVIEWER report — REQ-191 (service catalog core)

**Run:** WF02-REQ191-20260830, Step 2c
**Verdict: FAIL**

## Scope test

Diff touches: a new migration (`priv/repo/migrations/20260830000001_create_service_catalog.exs`),
a new Ecto schema (`lib/letflow/service_catalog/entry.ex`), a new context module
(`lib/letflow/service_catalog.ex`) doing tenant-visibility resolution and a cross-schema
referential query, and a new read-only accessor on `Letflow.TenantProvisioning`. This is
squarely a tenant-data path (INV-1 scope test: migration + tenant-scoped visibility logic).
In scope.

## INV-1..INV-8 disposition

- **INV-1 (tenant data isolation) — APPLIES, PASS.** `service_catalog` is deliberately
  global, not schema-per-tenant — a genuine, documented divergence from decision 0003
  Decision B. Verified the divergence is structurally justified (global-scope entries are
  referenceable by every tenant by construction; `service_id` uniqueness must hold across
  all tenants and both scopes) and matches the already-accepted `solution_pack_installs`
  precedent (`priv/repo/migrations/20260817083801_create_solution_pack_installs.exs`,
  read directly — same unprefixed/unregistered/`references(:tenants, ...)` shape). No
  `tenant_id` column exists on this table (correct — Decision B's intra-schema
  `tenant_id` clause doesn't apply to a table that isn't inside a tenant schema);
  `owner_tenant_id` is the one tenant association, FK-constrained to `tenants.id`, and is
  never derived from anything but caller-supplied `register/1` attrs plus a server-side
  existence check (`check_tenant_exists/1` against `Letflow.Identity.Tenant`) — appropriate
  for a global table where there is no `:prefix` to derive it from. `process_definitions`
  (the table actually read cross-schema by the referential guard) remains correctly
  `:prefix`-scoped per its own tenant-scoped migration; `query_referencing_definitions/2`
  passes `prefix: schema_name` to `Repo.all/2`, not a raw string-built table reference.
  This divergence is correctly flagged for REVIEWER sign-off (moduledoc, migration header,
  design doc) rather than silently taken — forwarded to Step 2d for that sign-off.

- **INV-1 cross-tenant visibility correctness (SVC-01), the core property — PASS.**
  `get_for_tenant/2` (`lib/letflow/service_catalog.ex:220-235`) does one `Repo.get(Entry,
  service_id)` (no tenant predicate at the SQL layer — deliberate, per the moduledoc, so
  the same query shape backs all three outcomes) followed by a pure in-memory match:
  `nil -> {:error, :not_found}`; `scope: :global -> {:ok, entry}` for any caller;
  `scope: :tenant` matching `owner_tenant_id` -> `{:ok, entry}`; `scope: :tenant` NOT
  matching -> `{:error, :not_found}` — the identical atom, no `:forbidden`/`:unauthorized`
  variant, and no entry data attached to the error tuple in either not-found branch. A
  tenant-scoped service owned by tenant A queried by tenant B is genuinely
  indistinguishable at this function's boundary from a nonexistent `service_id`: same
  return shape, same single query, no extra round-trip on the mismatch path (no timing
  signal). No caller of `get_for_tenant/2` in this diff (none exists yet — no route) does
  anything with the error atom beyond propagating it. `owner_tenant_id`/`request_schema`/
  other fields are only ever attached to `{:ok, entry}` and only when the visibility
  check has already passed — no code path returns partial/redacted entry data on the
  invisible branch. `list_for_tenant/2` scopes at the SQL layer
  (`where: e.scope == :global or e.owner_tenant_id == ^tenant_id`) so it never fetches
  invisible rows in the first place. `lookup_service/1` (backing `scope_validator_lookup/1`
  for `ServiceScopeValidator`) does not tenant-filter — by design, per its own doc comment:
  `ServiceScopeValidator.validate/3` performs the scope/tenant comparison itself on the
  caller side using the activation's own `tenant_id`, so this `Lookup` reporting the raw
  registered scope/owner is correct, not a leak — confirmed by reading
  `service_scope_validator.ex`'s existing branch table (unchanged by this diff, confirmed
  via `git diff`) actually does that comparison rather than trusting the Lookup's answer
  as final.

- **INV-1(c) tenant_id server-side capture — PASS.** `scope_validator_lookup/1` is built
  per-activation (`scope_validator_lookup(tenant_id)`), with `tenant_id` sourced from the
  activation's own already-authenticated context by `ServiceScopeValidator.build/1`'s
  existing closure pattern (unchanged in this diff) — never caller-suppliable through the
  `Lookup` itself. The `Lookup`'s `service_lookup` field ignores the closed-over
  `tenant_id` entirely (by design, since the caller-side comparison already uses it), so
  there is no path through this `Lookup` where a probing tenant could substitute another
  tenant's id to see a different visibility answer.

- **INV-1 cross-schema referential guard — PASS.** `referencing_active_definitions/2`
  enumerates `TenantProvisioning.list_registrations/0` and runs
  `query_referencing_definitions/2` per schema via `Repo.all(query, prefix: schema_name)`.
  The query is `Ecto.Query` composed (`from(p in ProcessDefinition, where: ..., select:
  p.id)`), not `Repo.query`/raw SQL. The one `fragment/2` use
  (`@service_task_reference_fragment`) parameterizes both the jsonb column reference and
  `service_id` via `?` placeholders bound to `p.graph` and `^service_id` — no
  string-interpolated `service_id` or schema name anywhere in the fragment text itself;
  `schema_name` reaches Postgres only through Ecto's own `:prefix` option (identifier
  quoting), the same mechanism every other tenant-scoped context module in this codebase
  already uses, not through string-built SQL. The query returns only `p.id` (a
  `definition_ids` list) and is read-only (`Repo.all` — no delete/update/insert in this
  function). It is only reachable through `delete/1` and `update_scope/2`, both
  catalog-admin operations with no route wired in this diff (confirmed: `git diff
  main...HEAD --stat` shows no router/controller file touched). The disclosure question
  the handoff raises for once REQ-192 wires a route on top ("do the returned
  `definition_ids`/`tenant_ids` in the error tuple constitute a disclosure once an HTTP
  caller can trigger this") is correctly out of scope for REQ-191 — there is no caller
  today who could receive that error tuple except test code and other backend code in the
  same trust boundary. Noted for REQ-192's own security review rather than blocking here.

- **`Letflow.TenantProvisioning.list_registrations/0` — PASS.** `Repo.all(Registration)`,
  no arguments, no mutation. Read `lib/letflow/tenant_provisioning/registration.ex`
  directly: the schema (`tenant_schemas`) carries only `tenant_id`, `schema_name`,
  `migrations_applied_at` — no credentials, no connection strings, no secret material.
  Returning full `Registration` structs is safe; there is nothing sensitive on the
  struct to over-expose.

- **INV-2, INV-3, INV-5 — NOT-APPLICABLE.** No API response-shaping code, no
  script/plugin sandboxing, and no lookup-by-ID *endpoint* exists in this diff (S4/S5 not
  started; REQ-191 explicitly has no route/controller, confirmed by `git diff --stat`).

- **INV-4 (secrets by reference only) — APPLIES, PASS.**
  `grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}"` across the
  five changed files: zero hits. No secret material is read, logged, or threaded through
  any return value in this diff.

- **INV-6 (new data-access paths prove their scoping) — APPLIES, satisfied by this
  report** — this handoff is the proof artifact.

- **INV-7 (no SQL string interpolation) — APPLIES, PASS.** `grep -rn "Repo.query"` across
  the five changed files: zero hits in the new code. (Two pre-existing `Repo.query!`
  calls exist elsewhere in `lib/letflow/tenant_provisioning.ex`, lines 259/273 —
  confirmed via `git diff main...HEAD` that neither line is part of this diff; out of
  scope for this review.) The new jsonb referential-guard query uses `Ecto.Query` +
  parameterized `fragment/2`, not raw SQL.

- **INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, FAIL.**
  `lib/letflow/service_catalog.ex:407`, inside `delete/1`:

  ```elixir
  %Entry{} = entry ->
    case referencing_active_definitions(service_id, nil) do
      [] ->
        {:ok, _deleted} = Repo.delete(entry)
        :ok
  ```

  `entry` is fetched via `Repo.get(Entry, service_id)` at the top of `delete/1`, then
  `referencing_active_definitions/2` runs a **sequential per-tenant-schema** query loop
  (one query per provisioned tenant) before this line executes — a real, and
  non-negligible, window in which the same row can be deleted by a concurrent caller.
  `Entry` has no optimistic-lock field, so `Repo.delete/1` matches on primary key alone;
  if the row is gone by the time this line runs, `Repo.delete/1` raises
  `Ecto.StaleEntryError`, and the bare `{:ok, _deleted} = ...` match cannot catch it —
  it crashes the calling process instead of returning a typed error. This is exactly the
  pattern INV-8's own "How to verify" grep is written to catch, and it touches external
  I/O (the DB) directly, so INV-8 applies regardless of whether a route exists yet.

  This diff's own precedent in the same codebase does it correctly: `Letflow.Webhooks.
  delete/2` (`lib/letflow/webhooks.ex:270`) passes `Repo.delete(subscription, prefix:
  prefix)`'s result straight through a `with` chain rather than bare-matching it, so a
  `{:error, changeset}` (or, if it occurred, a raised `StaleEntryError`) would not be
  silently assumed away by an unmatchable pattern. `Letflow.ServiceCatalog.delete/1`
  deviates from that established pattern without justification.

  **Not a cross-tenant data leak** and not reachable from any HTTP caller in this diff
  (no route exists — REQ-192), but it is a genuine, mechanically-identified INV-8
  violation on a path that already touches external I/O today (tests, IEx, and any
  internal caller), and it would become concretely exploitable as a denial-of-service on
  a single request the moment REQ-192 wires a route on top of `delete/1` without also
  fixing this. Per this file's own severity rule, every applicable invariant is BLOCKER
  with no partial credit — this fails the gate.

## Verdict

**FAIL.** One BLOCKER: INV-8 violation in `Letflow.ServiceCatalog.delete/1`
(`lib/letflow/service_catalog.ex:407`). All other reviewed invariants (INV-1, INV-4,
INV-6, INV-7) pass; INV-2/INV-3/INV-5 not applicable. Routed back to ELIXIR-DEV for
rework rather than forwarded to REVIEWER.

## Suggested fix (for ELIXIR-DEV, not prescriptive)

Replace the bare match with a `case`/`with` that maps `Repo.delete/1`'s actual
`{:ok, _} | {:error, Ecto.Changeset.t()}` result (and, if the project wants to treat a
concurrent delete as a benign outcome rather than a changeset error, catch
`Ecto.StaleEntryError` explicitly and translate it to `{:error, :not_found}`, consistent
with `get_for_tenant/2`'s and `update_scope/2`'s own not-found handling) instead of
asserting `{:ok, _deleted} = Repo.delete(entry)`.

## Re-check, rework 1 (2026-08-30) — Step 2c re-check

**Verdict: PASS.**

Diff re-verified directly (`git diff 8b9edc2 d06cf21 -- lib/letflow/service_catalog.ex`):
the fix touches only `delete/1`'s success branch (now calls a new private
`delete_entry/1` in place of the bare `{:ok, _deleted} = Repo.delete(entry); :ok`) and
adds `delete_entry/1` itself:

```elixir
defp delete_entry(entry) do
  case Repo.delete(entry) do
    {:ok, _deleted} -> :ok
    {:error, _changeset} -> {:error, :not_found}
  end
rescue
  Ecto.StaleEntryError -> {:error, :not_found}
end
```

This resolves the INV-8 BLOCKER: `Repo.delete/1`'s real `{:ok, _} | {:error, changeset}`
return is now handled by an actual `case` (no bare/irrefutable match survives), and the
raised-not-returned failure mode (`Ecto.StaleEntryError`, since `Entry` has no
optimistic-lock field and `Repo.delete/1` matches on primary key alone) is caught by an
explicit `rescue` clause. Both the changeset-error branch and the rescued-exception
branch map to `{:error, :not_found}`, consistent with `get_for_tenant/2`'s and
`update_scope/2`'s own not-found convention. `delete/1`'s `@spec` already declared
`{:error, :not_found}` as a valid return (unchanged), so no `@spec`/`@doc` edit was
needed and none was made.

Confirmed nothing else changed: the diff is exactly 16 insertions / 2 deletions, all
inside `delete/1`'s success branch and the new `delete_entry/1` helper.
`get_for_tenant/2`, `list_for_tenant/2`, `register/1`, `update_scope/2`,
`referencing_active_definitions/2`, `query_referencing_definitions/2`, and the `Lookup`
implementation are byte-for-byte unchanged from the version already verified correct
above (INV-1 including cross-tenant visibility, the global-table divergence, the
cross-schema referential guard; INV-4; INV-7).

**Overall verdict: PASS.** All applicable invariants (INV-1, INV-4, INV-6, INV-7, INV-8)
now pass; INV-2/INV-3/INV-5 remain not-applicable. Forwarded to REVIEWER (Step 2d) for
the idiom/scope-creep gate and the already-flagged decision-0003 global-table divergence
sign-off.
