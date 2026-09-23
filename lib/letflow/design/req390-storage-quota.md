# REQ-390 Design: Per-Tenant Storage Quota Tracking

**Module(s) changed:** `Letflow.Repository.Attachments`  
**Schema changed:** `Letflow.Identity.Tenant`  
**Migration:** `20260923000001_add_storage_allowance_bytes_to_tenants.exs` (global, not tenant-scoped)  
**Stage:** S6  
**Depends on:** REQ-211 (instance_attachments core), REQ-202 (repository_artifacts)

---

## 1. Existing State

### `upload/2` today (design §4.1 + ISS-0399 §2)

1. Computes `measured_byte_size = byte_size(raw_bytes)`.  
   If `measured_byte_size > @max_upload_bytes` (26_214_400 bytes, 25 MiB):
   returns `{:error, :file_too_large}` immediately — no further work.
2. Computes `content_hash = :crypto.hash(:sha256, raw_bytes)`.
3. Calls `run_attachment_scan/2` (via the configured scanner adapter, defaulting to
   `Letflow.Repository.AttachmentScanner.SignatureHeuristic`). Infected → `{:error,
   :infected, verdict}` + audit log. Scan failure → `{:error, :scan_unavailable}`.
4. If clean: calls `do_upload_after_scan/6`, which:
   - Calls `TenantProvisioning.tenant_id_for_schema_name(prefix)`.
   - Inside `Repo.transaction`: `Repository.upsert_content/6` (artifact row), then
     `Attachment.changeset → Repo.insert` (attachment row).

`@max_upload_bytes` is a **per-file** ceiling only — it places no bound on cumulative
tenant usage. Zero per-tenant storage accounting exists today.

### `delete/2` today

Calls `get/2` for validation then `Repo.delete(attachment, prefix: prefix)`. Removes the
`instance_attachments` row. Never touches `repository_artifacts` (ON DELETE RESTRICT FK
plus REQ-202 immutability — see moduledoc).

### Relevant schema facts

- `instance_attachments.byte_size :bigint NOT NULL` — measured independently by
  `upload/2`, never caller-supplied. Populated for every row. Lives in the per-tenant
  Postgres schema.
- `repository_artifacts.byte_size` also exists but is per-artifact (potentially
  shared via content-hash dedup). For quota purposes the canonical per-tenant usage
  figure must count **attachment rows** (`instance_attachments`), not artifact rows,
  because a single artifact reused by two attachments represents two uploads against
  the tenant's storage budget.
- `tenants` table: lives in the default/global schema. Fields today:
  `id`, `slug`, `display_name`, `status`, `idp_realm_id`, `settings`. No per-tenant
  numeric limits exist.

---

## 2. Decision 1 — Usage Tracking: Computed-on-Read (REVIEWER sign-off required)

**Decision:** computed-on-read `SUM(byte_size)` from `instance_attachments` within the
tenant's own Postgres schema.

**Rationale:**

| Criterion | Computed-on-read | Maintained counter |
|---|---|---|
| Drift risk | None — query is always ground-truth | Present: any rollback, partial failure, or direct DB patch that does not update the counter leaves it permanently stale with no self-correction mechanism. |
| `delete/2` complexity | No change needed — delete already removes the row and the SUM reflects it automatically on next read. | `delete/2` must also update a cross-schema counter column on the global `tenants` row inside the same transaction — or accept that the counter drifts on every delete until manually repaired. |
| Query cost | One `SELECT COALESCE(SUM(byte_size), 0) FROM <tenant_schema>.instance_attachments` per upload attempt. Postgres full-scan of the `byte_size` column in the tenant schema. Acceptable: tenant schemas are small (bounded by the per-file ceiling; thousands of attachments is a large tenant, not the common case). | One `UPDATE tenants SET storage_used_bytes = storage_used_bytes + ? WHERE id = ?` per upload/delete. Faster per-call but adds cross-schema write coupling and drift exposure. |
| Index needed | None — a btree index on `byte_size` alone does not accelerate a SUM; the full scan is necessary regardless. | No index needed on the counter column (primary-key lookup). |
| Schema change in tenant schemas | None. | New column in `instance_attachments` or a new per-tenant-schema table — adds migration complexity to every provisioned tenant schema. |

**Performance analysis:** The per-tenant SUM issues once per `upload/2` call, before the
(more expensive) content scan and before any `Repo.transaction`. For tenants with very
large attachment counts (>100K rows), a full scan of `byte_size` may become slow; the
future mitigation is a `CREATE INDEX CONCURRENTLY ON instance_attachments (byte_size)` to
enable an index-only scan. This is not needed at current scale and is explicitly out of
scope for this requirement.

**Conclusion:** Computed-on-read is chosen. Zero drift exposure, zero counter-maintenance
complexity, no change to `delete/2`, no additional tenant-schema columns.

---

## 3. Decision 2 — Allowance Storage: New Column on `tenants` (REVIEWER sign-off required)

**Decision:** Add `storage_allowance_bytes :bigint NOT NULL DEFAULT 1_073_741_824` to the
global `tenants` table (see §7 and §8 for full schema/migration detail).

**Rationale for location:**

| Option | Verdict |
|---|---|
| `Letflow.Identity.TenantSettings` JSONB column | **Rejected.** `TenantSettings` has a deliberately closed key vocabulary (`app_name`, `logo_url`, `brand_colors`, `locales`, `default_locale`) designed for public-facing branding data exposed at a pre-authentication endpoint. Expanding it for an operational limit mixes concerns and requires re-opening a closed vocabulary surface. |
| `Letflow.TenantProvisioning` module-level config | **Rejected.** A single global constant is not per-tenant-configurable. `TenantProvisioning` is about schema-provisioning primitives, not tenant operational parameters. |
| New column on `tenants` table | **Chosen.** The `tenants` table is the canonical record of per-tenant identity and state. A per-tenant operational limit (how much storage this tenant is allowed) is a per-tenant attribute: it belongs on the tenant row. Type-safe (`bigint NOT NULL` vs. a JSONB key with ad-hoc validation), primary-key-accessible (no index needed), and immediately available via the existing `Letflow.Identity.Tenant` schema. |

**Default value:** `1_073_741_824` bytes = 1 GiB.

Rationale for 1 GiB: the per-file ceiling is 25 MiB (`@max_upload_bytes`). 1 GiB
accommodates ~40 maximum-size attachments per tenant — a generous starter allowance for
the document-attachment use case (delivery notes, signed forms, scanned receipts per
REQ-206). It is a named constant, not a magic number, making it easy to adjust per-tenant
via a future admin route (REQ-392 is explicitly out of this scope). The value is chosen
independently of the existing 2 MB JSON body-size cap and follows the same "round,
conservative" judgement that `@max_upload_bytes`'s own comment describes for its 25 MiB
value.

Named constant (no implementation code — name only):
```
@default_storage_allowance_bytes 1_073_741_824
```
This constant lives in `Letflow.Repository.Attachments` as documentation of the default.
Its actual value is enforced at the DB level (`DEFAULT 1073741824` on the column) and
mirrored in the migration — the constant in the module is for documentation/test clarity,
not for runtime logic that reads it instead of the DB.

---

## 4. Storage Usage Function

### `get_storage_usage/1` — new public function in `Letflow.Repository.Attachments`

**Why in `Letflow.Repository.Attachments`?** This function queries `instance_attachments`
— the one table this module owns. REQ-392 (quota display route) will call it directly.
Placing it here avoids a new module for a single function, follows the existing precedent
(`list/2`, `get/2` all live here), and keeps all `instance_attachments` query logic
co-located. A new `Letflow.Repository.Storage` context module would create a one-function
module with nothing else to grow into.

**Signature:**
```
@spec get_storage_usage(opts()) :: {:ok, non_neg_integer()}
def get_storage_usage(opts) when is_list(opts)
```

- `opts` — same `[prefix: String.t()]` convention as every other function in this module.
- Returns `{:ok, 0}` when the tenant has no attachments (COALESCE(SUM(...), 0) semantics).
- Cannot return `{:error, _}` — a SUM over zero rows is 0, not an error. If the schema
  does not exist, `Repo.one/2` raises — but a caller that reaches this function will have
  already obtained a valid `prefix` from `TenantProvisioning`, so this is not a reachable
  error path. No error branch in the spec.

**Query shape (SQL semantics, no Ecto bodies):**
```sql
SELECT COALESCE(SUM(byte_size), 0)
FROM <prefix>.instance_attachments
```
Issued via `Repo.one/2` with `prefix: prefix`.

---

## 5. Modified `upload/2` With-Chain — Step Order

The quota check is inserted into `do_upload_after_scan/6` (the private helper), after
`tenant_id_for_schema_name/1` (which is needed to look up the allowance on `tenants`)
and **before `Repo.transaction`** (which must not execute if the quota is exceeded —
AC2: "no DB rows for refused upload").

### New `do_upload_after_scan/6` with-chain step order:

```
Step 1  {:ok, tenant_id}      ← TenantProvisioning.tenant_id_for_schema_name(prefix)
Step 2  :ok                   ← check_storage_quota(prefix, tenant_id, measured_byte_size)
           [internal: get_storage_usage([prefix: prefix]) → current_usage]
           [internal: Repo.get(Letflow.Identity.Tenant, tenant_id) → allowance]
           [internal: if current_usage + measured_byte_size > allowance → {:error, :storage_quota_exceeded}]
Step 3  {:ok, attachment}     ← Repo.transaction (existing: upsert_content + insert attachment)
```

The scan (step 3 in the existing `upload/2` outer function) runs **before**
`do_upload_after_scan` is called, so the ordering is:

```
upload/2 outer:
  1. byte_size > @max_upload_bytes?           → {:error, :file_too_large}        [existing]
  2. hash bytes                               [existing]
  3. run_attachment_scan/2                    → {:error, :infected/scan_unavailable} [existing]
  4. call do_upload_after_scan/6:
       4a. tenant_id_for_schema_name          → {:error, :invalid_schema_name}   [existing]
       4b. check_storage_quota/3              → {:error, :storage_quota_exceeded} [NEW]
       4c. Repo.transaction (upsert + insert) → {:ok, attachment}                [existing]
```

Placement rationale for step 4b:
- **After** step 3 (scan): The scan is synchronous and must run before any DB write
  (ISS-0399 design §2). The quota check is cheap (one SUM query); placing it after the
  scan does not violate any ordering invariant, and placing it before would mean checking
  quota even for infected content (wasteful and wrong in principle — we should reject
  infected content regardless of quota).
- **Before** step 4c (`Repo.transaction`): Quota refusal must produce zero DB rows
  (AC2 requirement). The `Repo.transaction` creates both the artifact row and the
  attachment row; the quota check must precede it entirely.
- **After** step 4a (`tenant_id_for_schema_name`): The `tenant_id` is needed to look
  up `storage_allowance_bytes` on the `tenants` row (global schema). The schema-name
  derivation is pure/cheap and cannot fail for a well-formed prefix.

### Private helper: `check_storage_quota/3`

```
@spec check_storage_quota(prefix :: String.t(), tenant_id :: Ecto.UUID.t(), new_bytes :: non_neg_integer()) ::
        :ok | {:error, :storage_quota_exceeded}
defp check_storage_quota(prefix, tenant_id, new_bytes)
```

Internals (signatures/steps only — no bodies):
1. Calls `get_storage_usage([prefix: prefix])` → `{:ok, current_usage}`.
2. Fetches `storage_allowance_bytes` from `Letflow.Identity.Tenant` (global schema,
   `Repo.get/2`, no prefix) using `tenant_id`.
3. If `current_usage + new_bytes > allowance`: returns `{:error, :storage_quota_exceeded}`.
4. Otherwise: returns `:ok`.

**Cross-context dependency note (REVIEWER):** `Letflow.Repository.Attachments` will
directly read `Letflow.Identity.Tenant` via `Repo.get/2`. This adds a
`Repository → Identity` schema-module dependency. The alternative is to delegate through
a new `Letflow.Identity.get_storage_allowance/1` function so `Attachments` depends only
on the `Identity` context boundary rather than the raw schema struct. Both shapes compile
correctly; the direct shape is simpler; REVIEWER should decide if the cross-context
coupling warrants the delegation indirection.

### Updated `upload/2` `@spec`

```
@spec upload(upload_attrs(), opts()) ::
        {:ok, Attachment.t()}
        | {:error, :file_too_large}
        | {:error, :storage_quota_exceeded}   ← NEW
        | {:error, :infected, verdict :: String.t()}
        | {:error, :scan_unavailable}
        | {:error, Ecto.Changeset.t()}
```

---

## 6. New Error Tag

`{:error, :storage_quota_exceeded}`

- Distinct from `{:error, :file_too_large}`: `:file_too_large` means a single file
  exceeds the per-file ceiling (`@max_upload_bytes`). `:storage_quota_exceeded` means the
  upload would push the tenant's cumulative usage over its allowance.
- Both can coexist: a file can be `:file_too_large` independently of the tenant's
  remaining quota.
- The check order means `:file_too_large` is always returned before the quota check is
  attempted — a file above the per-file ceiling never triggers a quota query.
- AC3 ("quota check and per-file check independently testable") is satisfied by this
  separation: the per-file check is a pure integer comparison in `upload/2`'s outer
  function (no DB); the quota check is in `check_storage_quota/3` (requires DB).

---

## 7. DB Schema Changes

### `tenants` table (global schema, `Letflow.Repo.Migrations.*`)

New column:

| Column | Type | Nullable | Default | Index |
|---|---|---|---|---|
| `storage_allowance_bytes` | `bigint` | NOT NULL | `1_073_741_824` | None (PK lookup) |

The column has a DB-level default so existing tenant rows gain the default value
automatically when the migration runs — no backfill step required.

### `Letflow.Identity.Tenant` schema change

Add one field to the schema:

```
field(:storage_allowance_bytes, :integer)
```

(`bigint` maps to `:integer` in Ecto — the full 8-byte range is accessible; no overflow
risk at the values used here.)

**No change to `create_changeset/3` or `update_changeset/2`**: the default applies at
the DB level; no requirement in REQ-390 adds a route to change a tenant's allowance at
runtime (that is future scope). The field is read-only from the application's current
perspective.

### No per-tenant-schema changes

`instance_attachments` and `repository_artifacts` require no new columns. The computed-on-read approach uses the existing `byte_size` column.

---

## 8. Migration

**File:** `priv/repo/migrations/20260923000001_add_storage_allowance_bytes_to_tenants.exs`

**Type:** Global (NOT tenant-scoped — `tenants` lives in the default/public schema, no
`if prefix() do` guard needed and none must be added).

**Module name:** `Letflow.Repo.Migrations.AddStorageAllowanceBytesToTenants`

Content sketch (signatures only — no Ecto migration bodies):

```
alter table(:tenants) do
  add :storage_allowance_bytes, :bigint, null: false, default: 1_073_741_824
end
```

No index. No `execute/2`. No `create table`. No data backfill needed (the column default
covers all existing rows). No rollback concern (standard `alter table … add column` with
default is fully reversible with `remove :storage_allowance_bytes` in `down/0`).

The migration is NOT registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`
(that list is for per-tenant-schema tables only). It is a standard Ecto global migration
applied via `mix ecto.migrate`, same as `20260816000001_create_tenants.exs`.

---

## 9. Acceptance Criteria Traceability

| AC | REQ-390 criterion | Design element |
|---|---|---|
| AC1 | Context-module function returns tenant's current total byte usage, correct after upload and delete | `get_storage_usage/1` (§4): SUM of `instance_attachments.byte_size` in tenant schema. Correct after upload: the new row adds to the sum. Correct after delete: `delete/2` removes the `instance_attachments` row, so the next `get_storage_usage/1` call reflects the reduction automatically (computed-on-read, §2). |
| AC2 | Configured allowance exists; `upload/2` refuses over-quota with distinct tag; no DB rows for refused upload | `storage_allowance_bytes` column on `tenants` (§3, §7, §8). `check_storage_quota/3` returns `{:error, :storage_quota_exceeded}` (§5, §6). Placement is before `Repo.transaction` (§5) — no artifact row, no attachment row is created on refusal. |
| AC3 | Quota check and per-file check independently testable | Two distinct code paths: (1) the `byte_size > @max_upload_bytes` branch in `upload/2`'s outer function — pure, no DB, returns `{:error, :file_too_large}`; (2) `check_storage_quota/3` in `do_upload_after_scan` — requires DB, returns `{:error, :storage_quota_exceeded}`. Both return different error tags (§6). Independently exercisable in tests by controlling `raw_bytes` size vs. setting a tiny `storage_allowance_bytes`. |
| AC4 | Delete reflected in usage on next read | Computed-on-read SUM (§2): `delete/2` removes the `instance_attachments` row; the next `get_storage_usage/1` call sums the remaining rows. No counter to synchronize. |
| AC5 | `mix compile --warnings-as-errors` and `mix test` pass | Enforced by ELIXIR-DEV and TEST-RUNNER at implementation time; no design element required beyond ensuring no `{:error, _}` return shape is unhandled. The updated `@spec` for `upload/2` (§5) documents the new tag for Dialyzer. The migration (§8) is global and straightforward. |

---

## 10. Open Questions

**OQ-1 (REVIEWER — cross-context coupling):** `check_storage_quota/3` will use
`Repo.get(Letflow.Identity.Tenant, tenant_id)` directly, adding a
`Letflow.Repository.Attachments → Letflow.Identity.Tenant` schema-module dependency.
Alternative: add `Letflow.Identity.get_storage_allowance(tenant_id) :: {:ok, non_neg_integer()} | {:error, :not_found}` and depend only on that function. Both are valid;
REVIEWER should decide whether the direct coupling is acceptable or the indirection is
warranted.

**OQ-2 (future, not blocking):** If a tenant's attachment count grows large enough that
the per-upload SUM query becomes a latency concern, a `CREATE INDEX CONCURRENTLY ON
instance_attachments (byte_size)` enables an index-only scan. Out of scope for REQ-390.
No action required from ELIXIR-DEV.
