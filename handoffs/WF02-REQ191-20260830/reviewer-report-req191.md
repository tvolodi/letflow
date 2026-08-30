# REVIEWER report — REQ-191 service catalog core

Run: WF02-REQ191-20260830, Step 2d. Verdict: **PASS**.

## Scope check

`git diff --stat main...HEAD` touches exactly: the two handoff-adjacent
design/migration/schema/context files
(`priv/repo/migrations/20260830000001_create_service_catalog.exs`,
`lib/letflow/service_catalog/entry.ex`, `lib/letflow/service_catalog.ex`),
`lib/letflow/tenant_provisioning.ex` (one read-only addition,
`list_registrations/0`), `lib/letflow/definitions/solution_pack.ex`
(moduledoc/comment update only, no functional change — the hard-fail branch
`check_unsupported_sections(%{service_catalog_entries: []}) -> :ok` /
`_ -> {:error, :unsupported_pack_section}` is byte-identical before and
after), the design doc, and process artefacts (handoffs, design). No route,
no controller, no change to `service_scope_validator.ex`'s algorithm, no
change to `pin_resolver.ex`. Matches REQ-191's declared boundary (design §0)
exactly.

## Idiom review

- `Letflow.ServiceCatalog` is a plain Ecto context module, no process — same
  shape as `Letflow.Dlq`/`Letflow.Webhooks`/`Letflow.Identity`. No
  `gen_statem`/`GenServer` question applies here; nothing in this diff models
  a state machine.
- Typed error-atom convention (`:duplicate_service_id`, `:tenant_not_found`,
  `:not_found`, `{:referenced_by_active_definitions, conflicts}`) matches
  `Letflow.Dlq`/`Letflow.Definitions.SolutionPack`'s own established
  convention.
- `list_for_tenant/2` reuses `Letflow.Api.Pagination`'s cursor module and
  `Letflow.Dlq.list/2`'s `page_size + 1`-fetch/drop idiom verbatim — no new
  cursor format invented.
- Every other S6 context module takes `opts[:prefix]`; this one deliberately
  does not, and says why (global table, no tenant schema to scope into) — a
  documented deviation, not an inconsistency.
- `delete_entry/1`'s `Repo.delete/1` handling (rework 1, already
  SECURITY-REVIEWER-verified): case-matches the real result and rescues
  `Ecto.StaleEntryError`, both mapped to `{:error, :not_found}` — idiomatic
  and consistent with `get_for_tenant/2`'s own not-found convention.
- The referential guard (§4) uses a parameterized `fragment/2` with
  `jsonb_array_elements`/`EXISTS`, not string-built SQL or
  `LIKE`-on-serialized-JSON (explicitly rejecting R-Co's own sloppier
  original) — good use of the Decision 0003 fragment escape hatch for a
  genuinely structural need, not casual raw SQL.
- `Entry`'s caller-supplied string primary key is a deliberate, justified
  divergence (SVC-01's natural key), and the changeset-vs-DB-constraint
  split (advisory changeset checks, authoritative DB `CHECK`s) matches this
  codebase's established "changeset is a friendly pre-flight, DB constraint
  is authoritative" discipline.

No crutch found. No supervision-integrity concern (no process to isolate —
this table has nothing analogous to `Letflow.InstanceSupervisor`'s
per-instance concern).

## Type-safety observation (non-blocking)

`register_attrs.scope` and `update_scope_attrs.scope` type as
`atom() | String.t()` rather than a narrower `:global | :tenant` even where
`Ecto.Enum` already constrains the column to exactly those two values at the
schema layer — a caller passing an arbitrary string only fails at
`Repo.insert`/`Repo.update` time via the changeset, not at compile/dialyzer
time. This is the same class of gap Ecto.Enum-backed fields tend to have
across this codebase generally (not new to this module), so I'm not routing
back on it. Per `docs/agents/protocols/ISSUE_QUEUE.md`, I do not pick an
`ISS-NNNN` id or write `docs/issues/` myself (that id is allocated
atomically by `letflow-queue`'s `register_task`, which only `ORCH` calls) —
reporting this finding to ORCH below (title, description, severity,
affected_files) so it can be registered as a `type-safety`-tagged issue and
become claimable work, per this run's own handoff `context`.

## Scope-creep review

- `TenantProvisioning.list_registrations/0`: a plain `Repo.all(Registration)`,
  read-only, no new query logic, explicitly flagged by the design (§OQ-3) as
  a minimal public-surface extension beyond REQ-191's own stated boundary.
  Confirmed **not** scope creep — it's the only way to enumerate provisioned
  tenant schemas for the cross-schema referential guard, no framework
  machinery introduced, no abstraction ahead of what's needed today.
- No behaviours, macros, or generic plugin/registry plumbing introduced
  anywhere in this diff — the referential guard is a straight loop over
  `list_registrations/0`'s result, not a new abstraction layer.
- `solution_pack.ex`'s change is documentation-only (explains *why*
  `service_catalog_entries` stays hard-failed and names REQ-192 as owner) —
  correctly resists the temptation to half-wire it now.

## Decision-0003 divergence sign-off

**AGREE** with the global-table divergence. Full reasoning recorded in
`lib/letflow/design/req191-service-catalog-core.md` §0 (REVIEWER sign-off
block appended 2026-08-30) and mirrored in
`lib/letflow/service_catalog.ex`'s moduledoc and the migration's header
comment. Summary: the argument stands independently of the
`solution_pack_installs` precedent it cites (that analogy is imperfect —
`solution_pack_installs` is global for operational-infrastructure reasons,
not because a single row must be visible from every tenant's schema at
once) — `service_catalog` has its own sufficient structural argument: a
`scope = :global` row is one entity that must be visible identically from
every tenant simultaneously, which schema-per-tenant cannot express without
either replication-plus-sync machinery Decision B doesn't provide, or a
cross-schema fan-out on every read; and `service_id` must be globally unique
across all tenants and both scopes, which a per-schema unique index cannot
enforce at all. Consequence acknowledged explicitly: this table now relies
on `get_for_tenant/2`/`list_for_tenant/2`'s visibility predicate as the
*sole* tenant-isolation mechanism (no physical schema separation
backstopping it) — read both functions and confirm the predicate is correct
and applied identically in both, matching SECURITY-REVIEWER's own INV-1
pass.

## Verification note

No Elixir/Mix toolchain is available in this execution environment (`mix`
not on `PATH`) — same constraint noted in earlier steps of this run. This
review is based on direct reading of the diff and the cited sibling
modules, not a `mix compile`/`mix test` run.

## Forwarding

PASS. Forwarding to TEST-DESIGNER — `handoffs/WF02-REQ191-20260830/step-03-test-designer.json`.
