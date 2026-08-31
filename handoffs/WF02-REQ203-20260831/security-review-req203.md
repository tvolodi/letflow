# SECURITY-REVIEWER report — REQ-203 (per-tenant artifact activation)

**Run:** WF02-REQ203-20260831, Step 2c
**Branch:** feature/WF02-REQ203-20260831
**Reviewed against:** `git diff main...HEAD` (19 files, +2215/-17), `docs/agents/instructions/security-invariants.md` INV-1..INV-8.

## Scope test

This diff adds three new tenant-scoped tables (`artifact_activations`,
`artifact_activation_history`, `artifact_activation_groups`), a new migration, a
new context module (`Letflow.Repository.Activation`) performing lookups/inserts/
updates keyed by tenant, and edits to `Letflow.TenantProvisioning`'s migration
manifest. This is squarely a tenant-data path. Gate applies.

## Invariant-by-invariant

**INV-1 — Tenant data isolation. APPLIES. PASS.**
- (a) Every query/insert in `lib/letflow/repository/activation.ex` passes
  `prefix: prefix` to `Repo.one/2`, `Repo.get!/3`, `Repo.all/2`, `Repo.transaction/1`'s
  `Multi.insert/Multi.run` steps (all `repo.insert(prefix: prefix)`/
  `repo.update(prefix: prefix)`/`repo.get!(..., prefix: prefix)`), and `list_history/4`'s
  `Repo.all(prefix: prefix)`. No query reaches these tables outside `:prefix`-scoping.
  Confirmed by reading `resolve/3` (L144-161), `activate_group/4` and its helpers
  `upsert_activation_pointer/8` (L337-383) and `insert_activation_history/12`
  (L385-423), and `list_history/4` (L473-490).
- (b) The migration (`priv/repo/migrations/20260831000001_create_artifact_activations.exs`)
  creates all three tables inside `if prefix() do ... end`, i.e. only reachable via
  tenant-schema provisioning, never left in `public`. Confirmed registered in
  `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`
  (`lib/letflow/tenant_provisioning.ex` diff, new entry
  `{20_260_831_000_001, ..., "20260831000001_create_artifact_activations.exs"}`) —
  both halves of the "tenant-scoped migration" contract are present.
- (c) `tenant_id` on all three tables is derived from the resolved `prefix` via
  `TenantProvisioning.tenant_id_for_schema_name/1` at write time
  (`activate_group/4` L200: `{:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix)`,
  then threaded into every insert), never accepted as a separate caller-supplied
  field on any public function's argument list (`resolve/3`, `activate_group/4`,
  `list_history/4` all take `prefix`, not `tenant_id`, as their tenant argument).

**FOR UPDATE lock scoping (explicit check requested):** `upsert_activation_pointer/8`'s
locked read (L347-353) is `from(a in __MODULE__, where: a.artifact_kind == ^artifact_kind
and a.artifact_name == ^artifact_name, lock: "FOR UPDATE")` issued via
`repo.one(query, prefix: prefix)`. Because this is schema-per-tenant (Decision B), the
`:prefix` option targets a physically separate Postgres schema per tenant — the query
cannot structurally reach another tenant's rows regardless of the `where` clause's own
predicate (there is no cross-schema table to lock). This is the same structural argument
REQ-202's design already relies on for its own per-tenant queries, applied here to a
locked read. No cross-tenant lock-scope leak.

**AC4 — UNIQUE (tenant_id, artifact_kind, artifact_name), DB-enforced.** Confirmed in the
migration: `create unique_index(:artifact_activations, [:tenant_id, :artifact_kind,
:artifact_name], name: :artifact_activations_tenant_kind_name_idx, prefix: schema)`
(L73-78) — a real Postgres unique index, not an application-level check-then-insert.
Genuinely DB-level.

**ON DELETE RESTRICT FKs (AC9).** Confirmed all three targeted FKs use
`on_delete: :restrict`, no CASCADE/SET NULL:
- `artifact_activations.active_version_id` → `artifact_versions.version_id`,
  `on_delete: :restrict` (migration L54-62).
- `artifact_activation_history.previous_version_id` → `artifact_versions.version_id`,
  `on_delete: :restrict`, nullable (migration L111-118) — nullable is correct per design
  (null on first activation), restrict is correct (a version referenced as "previously
  active" can never be deleted).
- `artifact_activation_history.new_version_id` → `artifact_versions.version_id`,
  `on_delete: :restrict`, not-null (migration L120-128).
- (Also `artifact_activation_history.group_id` → `artifact_activation_groups.group_id`,
  `on_delete: :restrict`, nullable — not one of the three named in the task brief but
  checked anyway; consistent, no CASCADE.)
No accidental CASCADE/SET NULL anywhere in this migration.

**Audit cross-write (`Letflow.Audit.append_multi/4`).** `add_activation_steps/9`'s
`Multi.merge/2` step (activation.ex L317-334) calls `Audit.append_multi/4` with
`prefix` threaded through (same prefix as the rest of the transaction — no separate/
untrusted prefix value), `actor_id: activator_user_id` (the real activator, not
mis-attributed), `resource_id: artifact_id` (the artifact's own stable id, not another
tenant's or another artifact's), and `before_state`/`after_state` built from
`Audit.struct_state/2` over this same tenant's just-written `Activation` struct (no
join across tenants, no other tenant's data folded in). One audit row per artifact
activated, matching the design's stated granularity — no leak of the activator's
identity into another tenant's trail, since the whole `Multi` runs under one `prefix`.

**CHECK (rationale <> '') constraints.** Confirmed present as raw `execute/1` DDL on
both tables: `artifact_activation_groups_rationale_check` (migration L97-103) and
`artifact_activation_history_rationale_check` (migration L147-153), both
`CHECK (rationale <> '')`. Reviewed and accepted the design's own stated residual gap
(whitespace-only string bypasses the raw `CHECK` but is caught by the changeset-level
`validate_required/2` via `cast/4`'s trim-leading pipeline for every real call path
this module exposes) — no changeset-bypassing writer is introduced by this diff.

**Secrets/PII.** No secret material or PII-shaped column on any of the three new
tables (UUIDs, enum, string name, timestamps, free-text rationale). `grep` for
`System.get_env`/`password`/`secret`/`token` across the new/changed repository files
and the migration returned no hits.

**Route/controller check.** `git diff --stat` scoped to `lib/letflow_web`/
`lib/letflow/router*`/`lib/letflow/routers*` against `main...HEAD` returns empty — no
route or controller file added or modified. Matches AC11 and the requirement's own
stated scope.

**Behavior-preservation of the shared `artifact_kind` refactor (REQ-202).** Diffed
`lib/letflow/repository.ex` and `lib/letflow/repository/artifact_version.ex`: the
`artifact_kind` type/enum previously declared inline
(`[:definition, :form, :schema, :service_catalog, :script, :module, :scenario]`) is now
sourced from the new `Letflow.Repository.ArtifactKind.values/0`, which declares the
identical seven-atom list, in the identical order. `Letflow.Repository.artifact_kinds/0`
is added as a new backward-compatible delegate, not a replacement of any existing public
function signature. No tenant-scoping logic in either file changed. This is genuinely
behavior-preserving for REQ-202's shipped code — no enum-value or tenant-scoping change.

**INV-2 (server-side field authorisation).** NOT-APPLICABLE — no API response type or
serialization boundary is touched; S4 has not started.

**INV-3 (untrusted runtime sandboxing).** NOT-APPLICABLE — no scripting/plugin code;
S5 has not started.

**INV-4 — Secrets by reference only. APPLIES (live). PASS.**
```
grep -rn "System.get_env" config/ lib/ --include=*.ex --include=*.exs   # unrelated to this diff, no new hits in changed files
grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}" lib/ config/ --include=*.ex --include=*.exs
```
No hardcoded secret literal in any file this diff touches. No secret is logged, traced,
or serialised anywhere in the new module.

**INV-5 (not-found/forbidden indistinguishability).** NOT-APPLICABLE — no lookup-by-ID
HTTP endpoint exists; S4 has not started. (`resolve/3`'s `{:error, :not_activated}` is an
internal context-function return, not an HTTP response shape.)

**INV-6 (new data-access paths prove their scoping).** This handoff itself is the proof
artifact — see the INV-1 section above for the explicit (a)/(b)/(c) statement.

**INV-7 — No SQL string interpolation. APPLIES (live). PASS.**
```
grep -rn "Repo.query" lib/ priv/repo/migrations/ --include=*.ex --include=*.exs
```
No `Repo.query`/`Repo.query!` call anywhere in this diff. The migration's two
`execute/1` calls (L97-103, L147-153) interpolate only `schema`, the migration-time
`prefix()` value Ecto itself resolves for the current migration run — not tenant- or
user-controlled request data. This is the same pattern already accepted for REQ-202/
REQ-195's migrations and matches INV-7's own stated risk surface (raw-SQL escape
hatches with *untrusted* interpolation) — a migration-authored, framework-resolved
schema name is not untrusted input in this sense.

**INV-8 — No unhandled crashes on realistic failure paths. APPLIES (live). PASS.**
```
grep -rn "^\s*{:ok, .*} = " lib/letflow/repository/activation.ex lib/letflow/repository/activation_group.ex lib/letflow/repository/activation_history.ex lib/letflow/repository/artifact_kind.ex
```
One hit, inside a `case` branch (`{:ok, %Pagination.Cursor{} = cursor} -> {:ok,
decode_history_seek(cursor)}`, L514) — a pattern-matched case clause, not a bare
`{:ok, x} = external_call()` that can raise; every other branch of that same `case`
returns a typed `{:error, _}` tuple (L515-517). All context functions
(`resolve/3`, `activate_group/4`, `list_history/4`) return typed `{:ok, _} | {:error, _}`
tuples throughout, using `with` chains for external-I/O-touching paths. No bare
irrefutable match on a value that can legitimately fail was found.

## Verdict

**STATUS: PASS.** All applicable invariants (INV-1, INV-4, INV-6, INV-7, INV-8) verified
satisfied; INV-2/INV-3/INV-5 correctly NOT-APPLICABLE (their stages have not started).
No BLOCKER found. Routing to REVIEWER per WF-02 Step 2c → 2d.

Note: this review could not independently re-run `mix compile --warnings-as-errors` or
`mix test` in this environment (`mix` is not on `PATH` here) — relies on ELIXIR-DEV's own
reported PASS output in `handoffs/WF02-REQ203-20260831/step-02a-elixir-dev.json`
(`mix_compile_warnings_as_errors: PASS`, targeted `mix_test`: PASS, full-suite run
explicitly reported NOT COMPLETED and flagged for TEST-RUNNER). This is a tooling-access
limitation of this review pass, not a security finding, and TEST-RUNNER's own step is
expected to independently re-verify the full suite per WF-02.
