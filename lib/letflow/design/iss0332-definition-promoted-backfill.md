# Design: ISS-0332 — DEFINITION_PROMOTED schema_version 2 backfill

**Issue:** ISS-0332  
**Run:** WF03-ISS0332-20260826  
**Stage:** S4 (fix, not a new stage requirement)  
**Designed by:** CODE-DESIGNER

---

## 1. Problem statement (brief)

`Letflow.TenantProvisioning.maybe_seed_platform_event_types/2` is called only during
`replay_migrations/2` (provisioning time). REQ-077 bumped the `DEFINITION_PROMOTED`
seed from `schema_version 1` (review_id: required, non-null) to `schema_version 2`
(review_id: required, nullable), but that new seed is only written for tenants
provisioned after the change. Pre-existing tenants still have v1 in their
`event_type_registry`.

When R10 (`promote_active_definition/5`) runs against such a tenant, the promotion DB
write commits (step 7/8 transaction), then `append_promotion_event/9` calls
`validate_payload/3` which resolves `get_type/2` returning the v1 row — and a null
`review_id` fails the v1 `"type": "string"` constraint. Result: committed promotion,
no audit event, HTTP 500. This is the Severity-1 broken-audit shape described in
`req077-promotion-pipeline-routes.md` §F-5.2.

---

## 2. Scope decision — structural commit-before-event gap

### The gap

`do_promote_definition/7` in `Letflow.Definitions.Promotion` intentionally runs step 9
(event-append) **outside** the step 7/8 `Repo.transaction/1`. This is an architectural
design decision stated explicitly in the moduledoc OQ-1: the injected `event_appender`
function carries no transactionality contract, and the module does not assume anything
about how it manages its own DB work. If the event-append fails after the transaction
commits, the promotion is durable but the audit trail is missing.

### Feasibility of a structural fix in ISS-0332 scope

Wrapping both the `write_target_definition` call and the `event_appender` invocation in
a single outer `Repo.transaction/1` is **not feasible as a scoped ISS-0332 change**:

1. `event_appender` is an opaque injected function (`(map(), String.t() -> {:ok, term()}
   | {:error, term()})`). Its callers (currently `Letflow.EventStore.PlatformEvents`)
   may open their own transactions or hold their own DB state. Nesting it inside an
   outer `Repo.transaction/1` would change semantics non-trivially and require auditing
   every `event_appender` implementation.
2. The step-9-outside-transaction shape is a deliberate architectural invariant, stated
   in the moduledoc. Changing it requires REVIEWER sign-off on a design that reasons
   through the full transactionality contract of every `event_appender` implementation
   — that is a separate design exercise, not a targeted bug fix.
3. The structural gap predates ISS-0332 (it existed before REQ-077 widened the
   schema). Closing it belongs to a follow-on issue rather than this one.

### Decision

**ISS-0332 scope = backfill only.** The structural commit-before-event gap is filed as
a follow-on issue note below.

### Follow-on issue note (to be registered by ORCH after this design is accepted)

> **ISS-FOLLOW-0332-A (structural gap):** `do_promote_definition/7` commits the
> definition write before calling the injected `event_appender`, with no rollback or
> retry mechanism if the append fails. This produces a durable committed promotion with
> no audit event for any `event_appender` failure (not just the schema-version mismatch
> ISS-0332 addresses). Fixing it requires: (a) formalizing the `event_appender`
> transactionality contract across all implementations, (b) deciding between an outer
> transaction wrapper, an idempotent re-run path, or an explicit compensating sweep.
> Architecturally non-trivial; needs its own CODE-DESIGNER → CODE-DESIGN-VALIDATOR →
> REVIEWER pass. Not blocked by ISS-0332's fix.

---

## 3. Backfill mechanism

### Module placement

New module: **`Letflow.TenantProvisioning.Backfill`** in
`lib/letflow/tenant_provisioning/backfill.ex`.

Rationale: the backfill iterates `tenant_schemas` (a `TenantProvisioning.Registration`
concern) and calls `Letflow.EventStore.Registry.register_type/2` per tenant — the same
two modules `maybe_seed_platform_event_types/2` already coordinates. Keeping the backfill
under `TenantProvisioning` preserves the existing module boundary: `TenantProvisioning`
coordinates provisioning-time seeding; its `Backfill` sub-module owns the post-hoc
reconciliation of that same data. This does not create a new inter-module dependency;
both dependencies already exist in `tenant_provisioning.ex` itself.

### Public function

```
Letflow.TenantProvisioning.Backfill.run/1
```

`@spec`:

```
@spec run(event_type_attrs :: map()) ::
        {:ok, %{updated: non_neg_integer(), skipped: non_neg_integer()}}
        | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
```

- `event_type_attrs` — the full attrs map for the event type version to register
  (shape: `%{name: string, schema_version: pos_integer, json_schema: map, description:
  string}`). Callers supply the exact v2 attrs literal from
  `@platform_event_type_seed_attrs`.
- Iterates all `Letflow.TenantProvisioning.Registration` rows (full table scan via
  `Repo.all/1` on the public schema, no prefix). For each, calls
  `Letflow.EventStore.Registry.register_type/2` with `attrs` and the registration's
  `tenant_id`.
- Returns `{:ok, %{updated: N, skipped: M}}` when every tenant is processed
  successfully (where `updated` = count of `{:ok, _}` results, `skipped` = count of
  no-op results).
- Returns `{:error, {:backfill_failed, tenant_id, reason}}` on the first unrecoverable
  failure, with the offending tenant's id and reason.

### Mix task

**`mix letflow.backfill_event_type_versions`** in
`lib/mix/tasks/letflow.backfill_event_type_versions.ex`.

The task is a thin wrapper: it resolves the target event type name from a CLI arg (or
defaults to `"DEFINITION_PROMOTED"`), looks up the matching entry in
`Letflow.TenantProvisioning`'s `@platform_event_type_seed_attrs` equivalent (exposed
via a private helper or a module attribute the task can access), and calls
`Letflow.TenantProvisioning.Backfill.run/1`. Prints a summary line on success, or a
clear error message with the failing tenant_id on failure. Exits non-zero on error so
CI/ops scripts can detect failure.

`@spec` for the Mix task module's `run/1`:

```
@spec run(argv :: [String.t()]) :: :ok
```

(Standard Mix task contract — returns `:ok` or raises/exits on failure.)

---

## 4. `register_type/2` return value handling in `Backfill.run/1`

| Return | Interpretation | Action |
|---|---|---|
| `{:ok, _}` | New version registered successfully (tenant was at a lower version, or had no entry) | Increment `updated` counter; continue |
| `{:error, :duplicate_event_type_version}` | Tenant already has this exact `(name, schema_version)` registered | Increment `skipped` counter; no-op; continue |
| `{:error, :schema_version_not_monotonic}` | Tenant already has a **higher** version registered (ahead of the backfill target) | Increment `skipped` counter; no-op; continue |
| `{:error, :tenant_not_provisioned}` | `Registration` row exists (since we iterated it) but `resolve_schema_name/1` found no row — this is a data-integrity anomaly, not a normal case | Log a warning with tenant_id; increment `skipped`; continue (do not halt — a partially-provisioned tenant must not abort the entire backfill run) |
| `{:error, other}` | Unexpected DB error, changeset validation failure, or other hard failure | Halt immediately with `{:error, {:backfill_failed, tenant_id, other}}` |

**Rationale for `:duplicate_event_type_version` and `:schema_version_not_monotonic`
both being no-ops (not errors):** both indicate the tenant is already at or ahead of
the backfill target. This is the idempotency contract ISS-0332 AC3 requires. The
backfill is safe to re-run; subsequent runs over already-updated tenants produce only
`skipped` increments.

**Rationale for `:tenant_not_provisioned` being a warned skip rather than a halt:** the
`Registration` row was fetched from `tenant_schemas` a moment earlier by the
`Repo.all/1` scan. If `resolve_schema_name/1` then returns `:tenant_not_provisioned`,
the tenant row was deleted concurrently or a `Registration` row exists without an
`event_type_registry` schema. Neither case should stop other tenants from being
backfilled. The warning surfaces the anomaly for operator investigation without aborting
the run.

---

## 5. Acceptance criteria mapping

| ISS-0332 acceptance criterion | Design element that satisfies it |
|---|---|
| AC1: A backfill mechanism updates already-provisioned tenants' `event_type_registry` `DEFINITION_PROMOTED` entries to `schema_version 2` | `Letflow.TenantProvisioning.Backfill.run/1` iterates all `Registration` rows and calls `register_type/2` per tenant with the v2 attrs. The Mix task `mix letflow.backfill_event_type_versions` provides the ops-facing entry point. |
| AC2: R10 against a pre-existing (pre-REQ-077) tenant succeeds end-to-end | After `Backfill.run/1` completes, every tenant has `DEFINITION_PROMOTED` schema_version 2 registered. `validate_payload/3` calls `get_type/2` which returns v2 (ORDER BY schema_version DESC LIMIT 1). The v2 schema admits null `review_id`, so the payload validates and the event appends successfully. |
| AC3: No regression to tenants already at schema_version 2 (idempotent/no-op on higher-version collision) | `{:error, :duplicate_event_type_version}` and `{:error, :schema_version_not_monotonic}` are both treated as `skipped` (no-op, no error). `Backfill.run/1` returns `{:ok, %{updated: 0, skipped: N}}` for a fully-up-to-date tenant population. |

---

## 6. Open questions

None that block implementation. The follow-on structural gap is registered under
§2's "Follow-on issue note" and requires its own design pass — it does not affect
the correctness of this backfill design.

---

## 7. Files to be created/modified by ELIXIR-DEV

| File | Action |
|---|---|
| `lib/letflow/tenant_provisioning/backfill.ex` | New — `Letflow.TenantProvisioning.Backfill` module |
| `lib/mix/tasks/letflow.backfill_event_type_versions.ex` | New — Mix task wrapper |
| `test/letflow/tenant_provisioning/backfill_test.exs` | New — unit + integration tests (TEST-DESIGNER's responsibility) |
| `lib/letflow/tenant_provisioning.ex` | Possible minor edit: expose the v2 `DEFINITION_PROMOTED` attrs as a public function or module attribute so the Mix task and tests can reference them without duplicating the literal. ELIXIR-DEV to decide; if the attrs map is just inlined in the Mix task's call site that is also acceptable. |
