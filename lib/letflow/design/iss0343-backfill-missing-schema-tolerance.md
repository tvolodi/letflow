# ISS-0343 fix design: `Backfill.run/1` tolerance for a concurrently-vanished tenant schema

## 0. Decision

**Tolerate a missing physical tenant schema as a per-tenant skip, not a crash.**
`Letflow.EventStore.Registry`'s DB-backed functions (`register_type/2`'s internal
`insert_with_monotonicity_check/2` query, and `get_type/2`) currently let a Postgres
`undefined_table` (`42P01`) error propagate as an **uncaught exception** whenever the
`prefix:` schema they query no longer exists. `Letflow.TenantProvisioning.Backfill.run/1`
(`lib/letflow/tenant_provisioning/backfill.ex`) has no `rescue` around its call into
`Registry.register_type/2`, so that exception unwinds straight out of the
`Enum.reduce_while/3` loop and crashes the whole backfill run — for every tenant still
left to process, not just the one whose schema vanished — which is exactly the observed
`Letflow.TenantProvisioning.BackfillTest` failure shape (`relation
"tenant_*.event_type_registry" does not exist`) under `scripts/test_parallel.sh`
(ISS-0343, per `handoffs/WF03-ISS0343-20260826/step-01-issue-fixer.json`'s diagnosis).

This is fixed at the `Registry` layer (§2), not by scoping `Backfill.run/1` to a single
`tenant_id`. Scoping is **rejected**: `Backfill.run/1`'s whole purpose (ISS-0332) is a
system-wide reconciliation sweep across every already-provisioned tenant — narrowing it
to one tenant would remove real, intended production behavior to patch a test-only
symptom, and every existing `Backfill.run/1` caller and test (`AC1`-`AC3` in
`backfill_test.exs`) already depends on the current `/1` all-tenants contract. No
change to `Backfill.run/1`'s public arity or its documented all-tenants sweep semantics.

No change to `test/support/tenant_fixture.ex`'s teardown (no advisory-lock addition
there): the issue-fixer's diagnosis offered that as an alternative direction (§4 covers
why it is not chosen as the primary fix), but a fix that only serializes teardown
against `provision_tenant_schema/1`'s advisory lock does not close the actual race —
`Backfill.run/1`'s queries take no advisory lock of their own at query time, so a
missing-schema race stays reachable through that path regardless. Making the query side
tolerant of a schema that has genuinely stopped existing is the fix that is correct
independent of *why* the schema vanished (test teardown racing in `:auto` mode today;
equally a live tenant-offboarding process in production tomorrow) — see §4.

---

## 1. Root cause recap (from step-01's diagnosis, restated precisely for this design)

`TenantFixture.provisioned_tenant!/1` flips `Sandbox.mode(Letflow.Repo, :auto)`
globally for the calling partition's connection pool and never restores `:manual`
(documented, intentional — see `test/support/tenant_fixture.ex` moduledoc). Under
`scripts/test_parallel.sh`, every `async: false` test in that same partition process —
`BackfillTest` included — therefore loses per-test transactional isolation: writes are
real and visible across every connection in that pool for the rest of the partition's
run. `TenantFixture`'s `teardown/2` (`test/support/tenant_fixture.ex` ~L330-334) issues
`DROP SCHEMA IF EXISTS "<schema>" CASCADE` for its own tenant with no lock coordinating
it against any other concurrently-running test's in-flight query. `Backfill.run/1`
(`lib/letflow/tenant_provisioning/backfill.ex` L20) calls `Repo.all(Registration)` —
**every** tenant's `Registration` row, system-wide, not just the calling test's own
tenant — then, for each one, calls `Registry.register_type/2` with that tenant's
`tenant_id`. If a *different*, concurrently-running test's `on_exit` teardown drops its
own tenant's schema in the window between `Backfill.run/1` reading that tenant's
`Registration` row and `Registry.register_type/2`'s query against
`<that tenant's schema>.event_type_registry` executing, the row still resolves via
`resolve_schema_name/1` (the `Registration` row itself is deleted only in a later step
of that same `teardown/2`, after the `DROP SCHEMA`) but the query executes against a
schema Postgres no longer has — `undefined_table`, `relation "tenant_*.event_type_registry"
does not exist`. This is a genuine DDL-vs-query race, not a naming collision (schema
names are already collision-proofed via `TenantSlugFixture.unique_slug`).

## 2. Fix specification

### 2.1 New typed error: `Letflow.EventStore.Registry` — `:tenant_schema_missing`

A new error reason distinct from `:tenant_not_provisioned` (which means "no
`Registration` row exists for this `tenant_id`" — a data-model-level absence,
checked with zero DB round-trip cost against the tenant schema itself).
`:tenant_schema_missing` means "a `Registration` row exists (so `resolve_schema_name/1`
succeeded) but the physical Postgres schema it names does not" — a
DDL-visibility race, detected only once a query against that schema is attempted and
Postgres rejects it.

Added to the result type of both public functions that query a tenant's schema:

```
@spec register_type(attrs :: map(), tenant_id :: Ecto.UUID.t()) ::
        {:ok, EventType.t()}
        | {:error, :tenant_not_provisioned}
        | {:error, :tenant_schema_missing}
        | {:error, Ecto.Changeset.t()}
        | {:error, :duplicate_event_type_version}
        | {:error, :schema_version_not_monotonic}
        | {:error, term()}

@spec get_type(event_type :: String.t(), tenant_id :: Ecto.UUID.t()) ::
        {:ok, EventType.t()}
        | {:error, :tenant_not_provisioned}
        | {:error, :tenant_schema_missing}
        | {:error, :unknown_event_type}
        | {:error, term()}
```

`validate_payload/3`'s `@spec` gains the same `{:error, :tenant_schema_missing}` variant
transitively (it forwards `get_type/2`'s error tuple verbatim, per its existing
moduledoc-documented shape — no new logic of its own).

### 2.2 Detection point: a shared private helper, not a change to every query call site

New private helper in `Letflow.EventStore.Registry`:

```
@spec rescue_missing_schema(fun :: (-> result)) ::
        result | {:error, :tenant_schema_missing}
      when result: var
```

Wraps a zero-arity closure in a `try`/`rescue` that matches specifically on
`%Postgrex.Error{postgres: %{code: :undefined_table}}` (the exact exception
`Ecto.Adapters.SQL` raises for a query against a table whose schema/relation doesn't
exist — this is the same exception class the observed `relation ... does not exist`
message comes from) and converts only that one exception shape into
`{:error, :tenant_schema_missing}`. **Any other exception is re-raised unchanged** —
this helper narrows to one specific, already-diagnosed failure mode; it must not become
a blanket rescue that hides unrelated bugs (anti-pattern: swallow-everything error
handling).

Call sites wrapped with this helper:
- `insert_with_monotonicity_check/2`'s two `Repo` calls (the `current_max` `Repo.one/2`
  query and the `Repo.insert/2` call) — both currently unguarded, both run with
  `prefix: schema_name` against the potentially-vanished schema.
- `get_type/2`'s `Repo.one/2` call.

`resolve_schema_name/1` itself needs no change — a missing `Registration` row is
already `:tenant_not_provisioned` and involves no schema-qualified query, so it cannot
raise `undefined_table`.

### 2.3 `Letflow.TenantProvisioning.Backfill.run/1` — new clause, no signature change

One new `case` clause in the existing `Enum.reduce_while/3` (mirrors the existing
`:tenant_not_provisioned` clause immediately above it in `backfill.ex`, same shape,
same counter semantics):

```
{:error, :tenant_schema_missing} ->
  Logger.warning(
    "ISS-0332 backfill: tenant #{tenant_id}'s Registration row exists but its " <>
      "physical schema is gone (concurrent teardown/offboarding race), skipping"
  )
  {:cont, {:ok, %{counts | skipped: counts.skipped + 1}}}
```

Placement: alongside the existing `:tenant_not_provisioned` clause (`backfill.ex`
L36-41) — both are "this tenant can't be reconciled right now, move on" outcomes,
counted as `skipped`, never `{:halt, {:error, ...}}`. `Backfill.run/1`'s own `@spec`
(`{:ok, %{updated: ..., skipped: ...}} | {:error, {:backfill_failed, tenant_id, reason}}`)
needs **no change** — `:tenant_schema_missing` becomes an ordinary `skipped` outcome,
not a new top-level error variant; only the internal `case` inside
`Enum.reduce_while/3` grows one clause. All other error reasons (`Ecto.Changeset.t()`,
any other `term()`) keep today's behavior: `{:halt, {:error, {:backfill_failed,
tenant_id, other}}}` — this fix narrows to the one already-diagnosed race, not a
blanket "never fail" change to `Backfill.run/1`.

### 2.4 Why this is a genuine tolerance fix, not a test-only patch

`Backfill.run/1` sweeps every `Registration` row in the database at the moment it
starts (`Repo.all(Registration)`, no snapshot isolation across the whole sweep — each
tenant's `Registry.register_type/2` call is its own independent query, run
moments apart from the initial listing). Any process that can concurrently drop a
tenant's schema after that listing was read — a live tenant-offboarding path, not only
`TenantFixture`'s test-only teardown — can reproduce this exact race in production.
Making `Registry`'s query layer tolerate "schema no longer exists" as a typed,
non-crashing outcome is correct regardless of which caller (test fixture teardown today,
a real deprovisioning flow tomorrow) causes the schema to vanish mid-sweep. This is why
§0 rejects "scope to a single tenant" and "lock the test fixture's teardown" as
sufficient fixes on their own: neither closes the underlying gap that `Registry`'s query
functions currently have no typed outcome for "the schema vanished between resolving
the `Registration` row and running the query."

## 3. Files touched

- `lib/letflow/event_store/registry.ex` — new `:tenant_schema_missing` error variant on
  `register_type/2` and `get_type/2`'s `@spec`s (transitively on `validate_payload/3`'s
  forwarded error); new private `rescue_missing_schema/1` helper; three call sites
  (`insert_with_monotonicity_check/2` ×2, `get_type/2` ×1) wrapped with it.
- `lib/letflow/tenant_provisioning/backfill.ex` — one new `case` clause in the
  `Enum.reduce_while/3` body handling `{:error, :tenant_schema_missing}` as a `skipped`
  outcome with a `Logger.warning/1` call. No `@spec` change.
- No migration, no schema/table change, no change to `test/support/tenant_fixture.ex`
  or to `Backfill.run/1`'s public arity/contract.

## 4. Alternative considered and rejected: advisory-lock the fixture's `DROP SCHEMA`

The issue-fixer's diagnosis (step-01) offered, as an alternative direction, taking the
same per-schema `pg_advisory_xact_lock(hashtext(schema_name))`
`provision_tenant_schema/1` already holds during `CREATE SCHEMA`
(`lib/letflow/tenant_provisioning.ex` L239) around `TenantFixture.teardown/2`'s
`DROP SCHEMA ... CASCADE` as well, so a query in flight against that schema is
serialized against its own teardown.

**Rejected as the primary/sole fix, kept in mind as optional future defense-in-depth:**
that lock is only ever acquired by `provision_tenant_schema/1` and (if added) by
`teardown/2` — `Backfill.run/1`'s own queries do not, and under this design still would
not, take it. Locking only the teardown side would narrow the *test-only* instance of
this race (a fixture's own teardown racing another fixture's provisioning path) without
touching the actual gap `Backfill.run/1` exposes — a query against a schema that
disappears for *any* reason after `Repo.all(Registration)` was read. It would also add
lock-acquisition overhead to every test's teardown for a race that, per §2, is better
closed once at the query layer. Not needed for this fix to be complete; not precluded
as a later, independent hardening of `TenantFixture` itself if a future issue shows a
distinct hazard the query-layer fix here doesn't cover.

## 5. Open questions

None load-bearing for implementation. One note for CODE-DESIGN-VALIDATOR/ELIXIR-DEV:
`Postgrex.Error`'s `postgres.code` field is an atom keyword (e.g. `:undefined_table`)
resolved by the `postgrex` dependency's own Postgres-error-code table — confirm at
implementation time (via `iex -S mix` or a quick `Postgrex.Error` inspection against a
deliberately-dropped-schema query) that `:undefined_table` is exactly the atom produced
for this SQLSTATE (`42P01`), rather than guessing the atom name from the SQLSTATE
mnemonic alone.
