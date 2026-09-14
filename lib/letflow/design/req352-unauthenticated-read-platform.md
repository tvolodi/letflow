# REQ-352 — Design: the unauthenticated-read platform machinery (mount, registry, writer, limiter, refusal path)

Stage S10 (motivation: **S10 gap 6**, cited by number only, per decision 0022 rule 1). Per
that rule this document names no vertical — see §13. Bucket **B**.
Owner: `CODE-DESIGNER` → `ELIXIR-DEV`. Status: design only.

This document builds the **first concrete artefacts** of the pattern
`lib/letflow/design/req323-unauthenticated-read-pattern.md` ("req323", cited by section
number below) and decision `docs/migration/decisions/0028-unauthenticated-read-boundary.md`
("0028") already fixed. It does not re-derive the mount point, the resolution mechanism,
or the response allowlist — those are taken as given. It resolves the two open questions
req323 left to "the requirement that needs the first instance": **OQ-1** (the permission
atom for the authenticated issue path) and **OQ-2** (whether the rate limiter is new or
reused). It registers **no kind** of its own (§10, test-only fixture only) and ships **no
projection** for any real resource (that is REQ-357, bucket C).

---

## 0. Premises taken as fixed (not re-derived)

- Route shape: `GET /api/public/<kind>/:handle`, plus a catch-all (req323 §1).
- Mount: a fourth top-level `forward("/api/public", to: Letflow.Routers.PublicRead)` on
  `Letflow.Router`, after `/metrics` (`lib/letflow/router.ex:114`) and before
  `/api/v1` (`:116`) (req323 §2, 0028 point 1).
- `Letflow.Routers.PublicRead`'s plug chain: the rate limiter (this document, §5), then
  `plug(:match)`, then `plug(:dispatch)` — no `Plug.Parsers`, no trace-id plug (req323 §2,
  §8).
- `public_read_handles` is a **global** table (no tenant prefix), alongside `tenants`
  (req323 §3.5, 0028 point 2).
- Handle construction: 32 bytes `:crypto.strong_rand_bytes/1`, URL-safe base64, stored as
  a hash only (req323 §3.3, §3.5, 0028 point 3).
- One refusal: every non-success case is `404` `application/problem+json` via
  `Letflow.Api.Response.not_found/1`, byte-identical across cases (req323 §4.2, 0028
  point 4).
- Round-trip discipline: exactly one DB round-trip before any refusal decision, exactly
  two on success; a malformed handle must not short-circuit ahead of the first query
  (req323 §4.3, 0028 point 4).
- The projection contract (`Letflow.PublicRead.Projection` behaviour: `@callback
  schema/0`, `@callback project/2`) and the router-side `@spec resolve(kind :: String.t(),
  handle :: binary()) :: {:ok, %{optional(String.t()) => term()}} | :not_found` (req323
  §4.4) — reused verbatim; not redesigned here.
- Kind registration via `Application.fetch_env!/2` at request time, no resource-type
  branch in the router (req323 §4.5, 0028 point 5).
- Rate limiter is a mounting precondition: per-IP (`conn.remote_ip`, never a forwarded
  header absent trusted-proxy config) plus a tighter global bucket, first plug inside
  `PublicRead`, before resolution, `429` via `Letflow.Api.Response.rate_limited/2`
  (req323 §5, 0028 point 6).
- Response headers: `Cache-Control: private, no-store`, `Referrer-Policy: no-referrer`,
  `X-Robots-Tag: noindex, nofollow` (req323 §5).

---

## 1. Module map (new files this requirement adds)

| Module | File | What it is |
|---|---|---|
| `Letflow.Routers.PublicRead` | `lib/letflow/routers/public_read.ex` | The sub-router: plug chain, `get "/:kind/:handle"`, catch-all. Contains no resource-type branch. |
| `Letflow.PublicRead` | `lib/letflow/public_read.ex` | Context module: `resolve/2` (resolution) and `issue_handle/4` (the writer). The one place both the read side and the write side of the registry live. |
| `Letflow.PublicRead.Handle` | `lib/letflow/public_read/handle.ex` | Ecto schema for `public_read_handles`. |
| `Letflow.PublicRead.Projection` | `lib/letflow/public_read/projection.ex` | The behaviour req323 §4.4 already specified — extracted into its own file here since REQ-323 shipped no code, only the design doc. Signature reused verbatim, not altered. |
| `Letflow.Routers.PublicReadHandles` | `lib/letflow/routers/public_read_handles.ex` | The generic **authenticated** issue route, mounted under `Letflow.Plugs.ApiPipeline` at `/api/v1/public-read-handles`. |
| `Letflow.Plugs.PublicReadRateLimit` | `lib/letflow/plugs/public_read_rate_limit.ex` | The plug enforcing §5's token buckets. |
| `Letflow.Plugs.PublicReadRateLimit.Bucket` | `lib/letflow/plugs/public_read_rate_limit/bucket.ex` | The `GenServer` that owns the ETS table backing the buckets. |
| `priv/repo/migrations/<ts>_create_public_read_handles.exs` | — | The migration (global schema, no `prefix`). |
| `config/config.exs` (edit, not new) | — | Registers `:public_read_kinds` config key; test fixture entry added only in `config/test.exs`. |

No directory outside those listed in §1 (`lib/letflow/routers/`, `lib/letflow/public_read/`,
`lib/letflow/plugs/`, `priv/repo/migrations/`, `config/`) is added or touched — in
particular, no vertical-specific directory anywhere under `lib/letflow/` or `web/src/pages/`
gains a module from this requirement.

---

## 2. `Letflow.Routers.PublicRead` — the sub-router

```elixir
defmodule Letflow.Routers.PublicRead do
  use Plug.Router

  plug(Letflow.Plugs.PublicReadRateLimit)
  plug(:match)
  plug(:dispatch)

  get "/:kind/:handle" do
    # delegates to Letflow.PublicRead.resolve/2, §4 below
  end

  match _ do
    # delegates to Letflow.Api.Response.not_found/1 -- case 9/10 of §4's table
  end
end
```

(Shown only to fix the route shape and plug ordering per req323 §2/§5 — no function
bodies are specified here; ELIXIR-DEV writes them. Prose, not code, governs from here.)

**Success-path behaviour**, stated as the exact steps the `get "/:kind/:handle"` clause
performs, in order:

1. Set the three response headers (§8 below) unconditionally, before dispatch is decided
   — so they are present on both the 200 and every 404 (a header that appeared only on
   success would itself be a case-distinguishing signal, which §4's single-refusal rule
   forbids).
2. Call `Letflow.PublicRead.resolve(kind, handle)`.
3. `{:ok, data}` → `Letflow.Api.Response.send_json(conn, 200, data)`.
4. `:not_found` → `Letflow.Api.Response.not_found(conn)`.

No `case` branch on `kind`'s value anywhere in this module — `resolve/2` is the only
caller of the kind registry (§7), and this router's own source contains no resource-type
string literal. This is grep-verifiable per AC-10: `grep -n '"' lib/letflow/routers/public_read.ex`
must show no kind-name literal other than the path template `"/:kind/:handle"`.

---

## 3. `public_read_handles` — the migration

Global table, default (`public`) schema — same convention as `tenants`
(`priv/repo/migrations/20260816000001_create_tenants.exs`: no `prefix:` option passed to
`create table/2`, stated in a header comment, and excluded from
`Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest`/`tenant_scoped_migrations/0`
list).

Header-comment content ELIXIR-DEV's migration must carry (stated as prose, not as a code
block, since the migration itself is implementation code this document does not write):
a note that this is a **global table, not tenant-scoped**, that it is the lookup that
decides which tenant schema to enter (so it cannot itself live inside one — same
reasoning as `tenants`), that it is deliberately excluded from
`Letflow.TenantProvisioning`'s tenant-scoped migration manifest, and that it lands
together with its first writer (`Letflow.PublicRead.issue_handle/4`, this same diff) per
0028's standing prohibition — the REQ-056 "table with no producer" failure mode.

Table spec, `public_read_handles`, `primary_key: false` (an explicit `:id` column below
supplies the primary key instead of the schema-default integer key):

| Column | Type | Constraints |
|---|---|---|
| `id` | `:binary_id` | primary key |
| `handle_hash` | `:string` | `null: false` |
| `tenant_id` | `:binary_id` | `null: false`, FK → `tenants.id`, `on_delete: :delete_all` |
| `kind` | `:string` | `null: false` |
| `resource_id` | `:binary_id` | `null: false` |
| `expires_at` | `:utc_datetime_usec` | nullable |
| `revoked_at` | `:utc_datetime_usec` | nullable |
| `inserted_at` / `updated_at` | timestamps | per `timestamps()` convention |

Indexes:

| Columns | Kind |
|---|---|
| `[:handle_hash]` | unique |
| `[:tenant_id]` | non-unique |
| `[:kind, :resource_id]` | non-unique |

No `prefix:` option anywhere in this table's definition (global schema, matching
`tenants`'s own migration).

**Column-type decision, stated explicitly since req323 §3.5 left it open (`bytea`
suggested there, not fixed):** `handle_hash` is `:string` (hex-encoded SHA-256, 64 ASCII
characters), **not** `:binary`/`bytea`. This follows the codebase's existing precedent for
exactly this shape rather than req323's provisional suggestion:
`Letflow.Identity.hash_token_value/1` (`lib/letflow/identity.ex:1058-1060`) does
`:crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)` and `ApiToken.token_hash`
(`lib/letflow/identity/api_token.ex:29`, migration
`20260823000001_create_api_tokens_tenant_scoped.exs:31`) stores it as `:string`. Matching
that convention means one hashing idiom in the codebase, not two, and `unique_index` on a
`:string` column behaves identically to one on `:binary` for an equality lookup — no
functional cost to the round-trip-count property in §4.

`on_delete: :delete_all` on the `tenant_id` FK: if a tenant row is ever hard-deleted (not
the same as `status: :inactive`, which is a soft state, §6), its handles are deleted with
it rather than orphaned into rows that would otherwise resolve to a schema that no longer
exists — consistent with §4's fail-closed posture (a resolution against a deleted schema
must not be reachable in the first place if this cascade holds).

`index(:public_read_handles, [:kind, :resource_id])`: supports revocation/lookup by
"which handles exist for this resource" from the authenticated side (e.g. "does this
`{kind, resource_id}` pair already have a live handle" — an idempotency question OQ-3 in
req323 leaves open, but the index costs nothing to add now and nothing to redesign later
if a future kind's issue path needs it).

**Not added, deliberately:** no partial index on `revoked_at IS NULL` or
`expires_at > now()` — liveness is evaluated in application code from the row already
fetched (§4), never re-queried, so no index serves a second query that must not exist.

---

## 4. `Letflow.PublicRead.Handle` — the Ecto schema

Backing table: `public_read_handles` (§3). Primary key: `{:id, :binary_id,
autogenerate: true}`.

Field list (Ecto type, matching §3's column types exactly):

| Field | Ecto type |
|---|---|
| `id` | `:binary_id` |
| `handle_hash` | `:string` |
| `tenant_id` | `Ecto.UUID` |
| `kind` | `:string` |
| `resource_id` | `Ecto.UUID` |
| `expires_at` | `:utc_datetime_usec` |
| `revoked_at` | `:utc_datetime_usec` |
| `inserted_at` / `updated_at` | via `timestamps()` |

No `belongs_to`/association fields (see the paragraph below §4's field list).

`@type t/0`: a struct type over exactly the fields above, `expires_at`/`revoked_at`
typed as `DateTime.t() | nil`, the rest non-nullable per §3's `null: false` constraints.

`insert_changeset/2` — signature and invariants only:

- `@spec insert_changeset(t(), map()) :: Ecto.Changeset.t()`
- Casts: `:handle_hash`, `:tenant_id`, `:kind`, `:resource_id`, `:expires_at`.
- Required: `:handle_hash`, `:tenant_id`, `:kind`, `:resource_id`.
- Constraint: `unique_constraint(:handle_hash)`, backing the migration's unique index.

No association to `Letflow.Identity.Tenant` is declared (`belongs_to`) — the schema holds
the FK column only. A `belongs_to`/preload is unnecessary machinery: every read path
either joins explicitly (§6) or does not need the tenant row at all (the writer only
needs `tenant_id` as an opaque value it was handed).

---

## 5. `Letflow.PublicRead.issue_handle/4` — the writer

```elixir
@type issue_opts :: [expires_at: DateTime.t() | nil]

@spec issue_handle(
        tenant_id :: Ecto.UUID.t(),
        kind :: String.t(),
        resource_id :: Ecto.UUID.t(),
        opts :: issue_opts()
      ) :: {:ok, %{handle: String.t(), record: Letflow.PublicRead.Handle.t()}}
         | {:error, Ecto.Changeset.t()}
```

**Construction, mirroring `Letflow.Identity.insert_token/3`'s shape
(`lib/letflow/identity.ex:1009-1052`) exactly, with the same division of labour:**

1. Mint the plaintext handle: `:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)`
   — 43 URL-safe characters, chosen over the token precedent's hex encoding because this
   value appears in a URL path (req323 §0.8, §3.3).
2. Hash it: `:crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)` — same
   function shape as `hash_token_value/1`, stored in `handle_hash`.
3. Build `Handle.insert_changeset/2` with `tenant_id`, `kind`, `resource_id`,
   `expires_at: Keyword.get(opts, :expires_at)`.
4. `Ecto.Multi.new() |> Multi.insert(:handle, changeset) |> Multi.merge(fn %{handle: handle} -> Audit.append_multi(Multi.new(), :audit, %{actor_id: <caller's actor, from auth context>, action: "public_read_handle.issue", resource_type: kind, resource_id: handle.resource_id, before_state: nil, after_state: Audit.struct_state(handle, [:handle_hash]), trace_id: <caller's trace id>}, tenant_prefix) end) |> Repo.transaction()`.
   The `Multi.insert(:handle, ...)` step passes **no** `prefix:` (global table); the audit
   step's `Audit.append_multi/4` **does** take the tenant's derived prefix — one
   `Repo.transaction/1` spanning both a global-schema insert and a tenant-schema insert,
   which is ordinary Ecto (`Multi` steps share one connection/transaction regardless of
   each step's own `prefix:`).
5. `{:ok, %{handle: record}} -> {:ok, %{handle: plaintext, record: record}}`. The
   plaintext is returned **once**, to the caller, and is never persisted (mirrors
   `ApiToken`'s own moduledoc rule, `identity.ex:1048`) and never logged (§13's grep
   check covers this file).

**Why the audit entry, when req323 didn't specify one:** `Letflow.Identity`'s token issuance
already establishes that minting a bearer credential is an audited action in this
codebase; a public read handle is the same class of object (a bearer credential a server
mints on someone's behalf) and skipping the audit trail here would be an unexplained
inconsistency, not a simplification. `after_state` excludes `handle_hash` for the same
reason `token_hash` is excluded from token audit rows (INV-4 — a hash is still a
credential-adjacent secret with no audit value).

**Idempotency (OQ-3, req323):** not decided here. `issue_handle/4` always inserts a new
row and mints a new handle; a caller wanting "reuse the existing live handle for this
resource if one exists" builds that check itself against the `[:kind, :resource_id]`
index (§3) before calling this function. Stated so a later reader does not assume
idempotency this function does not provide.

---

## 6. `Letflow.PublicRead.resolve/2` — resolution

```elixir
@spec resolve(kind :: String.t(), handle :: binary()) ::
        {:ok, %{optional(String.t()) => term()}} | :not_found
```

Exact query plan, case-by-case against §7's table:

**Round-trip 1 (always runs, regardless of `handle`'s shape):**

```elixir
handle_hash = :crypto.hash(:sha256, handle) |> Base.encode16(case: :lower)

from(h in Handle,
  join: t in Letflow.Identity.Tenant, on: t.id == h.tenant_id,
  where: h.handle_hash == ^handle_hash,
  select: %{handle: h, tenant_status: t.status}
)
|> Repo.one()
```

`Repo.one/1` returns `nil` or `%{handle: %Handle{}, tenant_status: atom()}`. **No
`prefix:` option anywhere in this query** — both `public_read_handles` and `tenants` are
global-schema tables, so this is an ordinary same-schema join, not a cross-prefix one.
This is the join §4.2/§7.2 of req323 requires to fold the deactivated-tenant check into
round-trip 1 without a second query.

The handle is hashed **unconditionally**, before any length/charset check — `:crypto.hash/2`
accepts any binary, so there is no input for which hashing can fail or raise, and
therefore no reason to branch before it (this is what makes case 1's non-short-circuit
requirement automatic rather than something to remember).

**Decided in memory from this one row (zero further queries):**

| Result | Verdict |
|---|---|
| `nil` | case 2 → `:not_found` |
| row, `revoked_at != nil` | case 3 → `:not_found` |
| row, `expires_at` present and `DateTime.compare(expires_at, DateTime.utc_now()) != :gt` | case 4 → `:not_found` |
| row, `handle.kind != kind` (the path's `<kind>` segment) | case 5 → `:not_found` |
| row, `tenant_status == :inactive` | folded tenant check → `:not_found` (§7.2 of req323; never the `TenantStatus` 403) |
| row, live, kind matches, tenant active or migrating | proceed to round-trip 2 |

**Round-trip 2 (only reached on the last row above):**

```elixir
{kind_string, projection_module} = <kind registry lookup, §7 below — already
                                     performed once at dispatch, reused here, not
                                     re-fetched>
schema = projection_module.schema()

case Letflow.TenantProvisioning.schema_name_for_tenant(handle.tenant_id) do
  {:ok, prefix} -> Repo.get(schema, handle.resource_id, prefix: prefix)
  {:error, :invalid_tenant_id} -> nil  # treated as case 6 below -- never raises (INV-8)
end
```

| Result | Verdict |
|---|---|
| `resource == nil` | case 6 → `:not_found` |
| `resource`, `projection_module.project(resource, %{issued_at: handle.inserted_at, kind: handle.kind}) == :skip` | case 7 → `:not_found` |
| `resource`, `project/2` returns `{:ok, data}` | success → `{:ok, %{"kind" => kind, "issued_at" => DateTime.to_iso8601(handle.inserted_at), "data" => data}}` |

Both round-trips are counted by the telemetry mechanism in §9; the plan above is what
that count must measure.

---

## 7. The ten-case refusal table (AC-4, AC-6, AC-7)

| # | Case | Detection point | Round-trips |
|---|---|---|---|
| 1 | Handle malformed (wrong length, non-base64url) | Round-trip 1's query runs anyway (hash accepts any binary) → falls to case 2 in practice (no row) | 1 |
| 2 | Handle well-formed, not present | Round-trip 1 returns `nil` | 1 |
| 3 | Handle present, `revoked_at` set | Decided in memory from round-trip 1's row | 1 |
| 4 | Handle present, `expires_at` passed | Decided in memory from round-trip 1's row | 1 |
| 5 | Handle present, live, `kind` mismatched vs. path | Decided in memory from round-trip 1's row | 1 |
| 6 | Handle present, live, kind-matched, resource row gone | Round-trip 2 returns `nil` | 2 |
| 7 | Handle present, live, kind-matched, resource unpublishable | Round-trip 2's row, `project/2` returns `:skip` | 2 |
| 8 | `<kind>` not a registered kind | `Application.fetch_env!/2` lookup (§8) misses, before any query | 0 |
| 9 | Wrong HTTP method on a valid path | `Plug.Router`'s own `match`/catch-all, no clause reached | 0 |
| 10 | Any other path under `/api/public` | Sub-router catch-all | 0 |

Every one of the ten produces the identical `404 application/problem+json` via
`Letflow.Api.Response.not_found/1` — no case-specific `detail`, no distinguishing header.
No case returns 401 or 403 (AC-5). Case 1 explicitly does **not** short-circuit ahead of
round-trip 1 (AC-7): the hashing step has no failure mode to branch on, so there is no
code path that could skip the query for a malformed handle without deliberately adding
one — a later reviewer checks for the *absence* of such a branch, not the presence of a
guard.

---

## 8. Kind registration — config shape and lookup

```elixir
# config/config.exs (or config/runtime.exs, per environment)
config :letflow, :public_read_kinds, %{
  # "kind_string" => ProjectionModule
}

# config/test.exs only (test-only fixture, §10)
config :letflow, :public_read_kinds, %{
  "public-read-fixture" => Letflow.PublicReadFixtureSupport.Projection
}
```

Lookup, performed once per request inside `Letflow.Routers.PublicRead`'s `get`
clause, **before** calling `resolve/2` (so an unregistered kind costs the promised zero
round-trips, per req323 §4.3/§6 point 3):

```elixir
@spec fetch_kind(kind :: String.t()) :: {:ok, module()} | :error
def fetch_kind(kind) do
  Application.fetch_env!(:letflow, :public_read_kinds)
  |> Map.fetch(kind)
end
```

`Application.fetch_env!/2` is called on the **config key itself** (`:public_read_kinds`),
which always exists (defaulting to `%{}` in `config/config.exs` if no kind is registered
in a given environment) — so `fetch_env!/2` never raises in production use; it is
`Map.fetch/2` on the returned map that distinguishes a registered kind from an
unregistered one. This resolves the one real ambiguity in req323 §4.5's phrasing
("reads ... via `Application.fetch_env!/2`"): the raising call is on the always-present
config key, not on the possibly-absent kind, which is exactly what makes case 8 a
zero-round-trip, non-raising 404 rather than a 500.

`Letflow.Routers.PublicRead` calls `fetch_kind/1` exactly once per request and contains
no other reference to any kind string — this is what AC-10's grep check verifies.

---

## 9. Telemetry round-trip counting (AC-6)

Test mechanism (not application code): a named telemetry handler attached to
`[:letflow, :repo, :query]`, following the established idiom already in
`test/letflow/router_test.exs:297-330` and `test/letflow/plugs/tenant_status_test.exs`
(named function, not an anonymous closure, filtering `self() == test_pid` because the
event name is node-global) — reused verbatim, not reinvented.

```elixir
def handle_query_telemetry(_event, _measurements, metadata, test_pid) do
  if self() == test_pid, do: send(test_pid, {:query_fired, metadata.query})
end
```

**Transaction-control statements — stated explicitly, per AC-6's requirement:**
`BEGIN`/`COMMIT` DO fire their own `[:letflow, :repo, :query]` events in this app's Ecto
setup (confirmed: `test/letflow/metrics/registry_test.exs:60` exercises exactly this,
`query: "BEGIN"` landing in the `"other"` `query_type` bucket). **They count toward the
totals in this design's test, and that is deliberate, not an oversight to filter out:**

- `resolve/2` (§6) issues no `Ecto.Multi`/`Repo.transaction/1` of its own — both
  round-trips are plain `Repo.one/1` / `Repo.get/3` calls outside any explicit
  transaction, so **no BEGIN/COMMIT fires on the resolution path at all**, in every
  case in §7's table. The "exactly one" / "exactly two" counts in AC-6 are therefore
  counts of `SELECT` events only, with zero transaction-control noise to subtract —
  stated here so the test does not need a filter it turns out not to require.
- `issue_handle/4` (§5) DOES wrap its insert in `Ecto.Multi.new() |> Repo.transaction/1`,
  so a test asserting round-trip counts on the **write** path (not this AC, which is
  about resolution) would need to account for `BEGIN`/`COMMIT` separately. Flagged so
  TEST-DESIGNER does not conflate the two paths' counting rules.

---

## 10. Test-only fixture kind (AC-10)

Proves dispatch works and an unregistered kind 404s, without naming any vertical or
adding a real resource type:

- **Fixture Ecto schema:** `Letflow.PublicReadFixtureSupport.Resource` — a minimal
  tenant-scoped schema (`id`, `publishable :boolean`), migration added under
  `test/support/` conventions (not `priv/repo/migrations/`, since it exists only for
  this test — mirroring how other fixture-only schemas in this tree are scoped to
  `test/support/`), living in whichever tenant schema the test provisions.
- **Fixture projection:** `Letflow.PublicReadFixtureSupport.Projection`, implementing
  `Letflow.PublicRead.Projection`: `schema/0` returns the fixture resource module;
  `project/2` returns `{:ok, %{"label" => "fixture"}}` when `resource.publishable`,
  `:skip` otherwise.
- **Kind string:** `"public-read-fixture"` — domain-neutral, registered only in
  `config/test.exs` (§8), never in `config/config.exs` or `config/runtime.exs`, so it
  does not exist in any non-test environment.
- **What the test proves:** `GET /api/public/public-read-fixture/:handle` for an issued
  handle returns the fixture's 200 envelope; `GET /api/public/not-a-kind/:handle` (an
  unregistered kind) returns the same 404 as every other refusal, at zero round-trips.

---

## 11. The rate limiter (AC-8; OQ-2 resolved)

### 11.1 OQ-2 — new module, not a reuse

**Decision: `Letflow.Plugs.PublicReadRateLimit` is a new module, not built on
`Letflow.Plugs.RateLimit`.**

Reasoning: `Letflow.Plugs.RateLimit` does not exist in the tree today (confirmed —
`lib/letflow/plugs/` has no rate-limit module; the only hit for the name is the
deferred-plugs table row at `lib/letflow/plugs/api_pipeline.ex:59`, reserved for the
general `/api/v1` limiter, "to port" from `rate_limit.zig`, S4, no owning requirement
yet). req323 §5 states reuse is "preferable... if the general limiter lands first and
is mount-point-agnostic" but explicitly leaves the choice to "a judgement for the
implementing requirement." That module has not landed, has no design, and has no owning
requirement — waiting for it would make this requirement's limiter (a hard mounting
precondition per 0028 point 6) dependent on unscheduled work. Building a new, narrower
module now and leaving the general limiter free to reuse this one's algorithm later (or
not) is the only option that does not block this requirement on someone else's undated
work. This does not discharge the deferred-plugs row — stated here so a later reader
does not treat `PublicReadRateLimit`'s existence as satisfying it.

### 11.2 Module shape

```elixir
defmodule Letflow.Plugs.PublicReadRateLimit do
  @behaviour Plug
  @spec init(keyword()) :: keyword()
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
end
```

`call/2` performs, in order:

1. `Letflow.Plugs.PublicReadRateLimit.Bucket.consume(:global, @global_capacity, @global_refill_per_sec)`.
2. If that succeeds, `Bucket.consume({:ip, conn.remote_ip}, @ip_capacity, @ip_refill_per_sec)`.
3. Either bucket refusing → `conn |> Letflow.Api.Response.rate_limited(...) |> halt()`,
   **before** `plug(:match)` runs, so no resolution work ever begins for a limited
   request (AC-8's input-independence requirement).

**Test plan (AC-8):** a test issues N+1 requests within the bucket window using a VALID
handle from a fixture (the §10 test-only kind) and asserts the (N+1)th response is 429,
proving the limiter fires before/independently of resolution succeeding — i.e. that a
handle which would otherwise resolve successfully is still refused once its bucket is
exhausted, in the same manner as AC-1/AC-2/AC-10's test plans are stated.

`@global_capacity`/`@ip_capacity`/refill rates are module attributes sourced from
application config (`config :letflow, Letflow.Plugs.PublicReadRateLimit, ip_capacity: ...`),
not hardcoded literals, so they are tunable per environment without a code change.

**Keying, restated as a checkable rule:** the only key ever derived from the connection
is `conn.remote_ip` (populated by Bandit/Plug from the actual socket peer). No header
(`X-Forwarded-For`, `Forwarded`, or any other) is read by this module under any
configuration this requirement ships — a trusted-proxy override is explicitly **out of
scope** here and would be a separate, reviewed change (req323 §5's own rule).

### 11.3 `Letflow.Plugs.PublicReadRateLimit.Bucket` — the ETS-backed token bucket

```elixir
defmodule Letflow.Plugs.PublicReadRateLimit.Bucket do
  use GenServer

  @type bucket_key :: :global | {:ip, :inet.ip_address()}

  @spec start_link(keyword()) :: GenServer.on_start()
  @spec consume(bucket_key(), capacity :: pos_integer(), refill_per_sec :: number()) ::
          :ok | :rate_limited
end
```

- **Table:** one named ETS table, `:letflow_public_read_rate_limit`, created in
  `init/1` with `:named_table, :public, :set, {:write_concurrency, true}, {:read_concurrency, true}`
  — same visibility/concurrency shape `Letflow.Metrics.Registry` already uses for its own
  ETS tables, so `consume/3` can be called directly from the calling process (the plug's
  own process, i.e. the request) without a `GenServer.call/2` round-trip through the
  owning process on every request; the `GenServer` exists solely to own the table's
  lifetime under supervision, not to serialize access to it.
- **Row shape:** `{key :: bucket_key(), tokens :: float(), last_refill_ms :: integer()}`.
- **Algorithm (token bucket, lazy refill, no background timer):** `consume/3` reads the
  current row (or treats a missing key as a full bucket at `capacity`), computes
  `elapsed_ms = System.monotonic_time(:millisecond) - last_refill_ms`, refills
  `tokens = min(capacity, tokens + elapsed_ms / 1000 * refill_per_sec)`, and either
  decrements by 1 and writes the new `{tokens - 1, now_ms}` row (`:ok`) or leaves the row
  unchanged and returns `:rate_limited` if `tokens < 1`. Implemented via `:ets.lookup/2`
  plus `:ets.insert/2` under this scheme — **not** `:ets.update_counter/4`, because the
  refill computation is not a pure integer increment (it depends on elapsed wall time) —
  ELIXIR-DEV: this is a check-then-write, not atomic across the two ETS calls; a small
  race under concurrent requests for the *same* key can let slightly more than
  `capacity` tokens through in a burst, which is an accepted imprecision for a
  best-effort limiter (not a security boundary — no case in §7's table depends on the
  limiter being exact) and must not be "fixed" with a lock that would serialize this
  route class's hot path.
- **Owning process:** started under `Letflow.Application`'s supervision tree (a sibling
  of wherever `Letflow.Metrics.Registry` is started), `restart: :permanent` — the table
  must survive for the life of the node; losing it mid-run would silently reset every
  bucket to full, which is an availability degradation, not a security one, and is
  accepted as equivalent to a node restart's existing effect on any other in-memory
  limiter state.
- **Multi-node:** per-node, exactly like req323 §5/OQ-4 already discloses for the
  pattern in general — not solved here, not silently assumed away.

---

## 12. Response headers (AC-9)

Set on **every** response this router returns — success and every refusal alike, so
their presence cannot become an eleventh case-distinguishing signal:

| Header | Value |
|---|---|
| `Cache-Control` | `private, no-store` |
| `Referrer-Policy` | `no-referrer` |
| `X-Robots-Tag` | `noindex, nofollow` |

Set via `Plug.Conn.put_resp_header/3` at the top of `Letflow.Routers.PublicRead`'s
`get "/:kind/:handle"` clause and its `match _` clause identically (or, more simply, as a
private plug function run for both, so the two clauses cannot drift out of sync over
time) — ELIXIR-DEV's choice of mechanism, but the requirement that both code paths set
identical values is not.

---

## 13. The authenticated issue route (OQ-1 resolved) — `Letflow.Routers.PublicReadHandles`

### 13.1 OQ-1 — the permission atom

**Decision: `:PublicReadHandlesIssue`.**

Minted following the existing `endpoint_policy_key()` naming convention in
`lib/letflow/api/authorization.ex` — PascalCase, resource-plural-plus-verb, no colons, no
snake_case (`:EntitiesRecordsWrite`, `:TokensManage`, `:InstancesStart` are the closest
precedents in shape). `:PublicReadHandlesIssue` names the generic registry table
(`public_read_handles`, already the migration's own table name) and the one write
operation it exposes (`issue`), and names no vertical — satisfying rule 1 exactly as
every other identifier in this document must (§14). It is added to
`Letflow.Api.Authorization`'s `endpoint_policy_key()` type union in the same diff that
adds the route consuming it (ELIXIR-DEV's implementation step; this document fixes the
atom's spelling and reasoning, not the edit to that file's line count).

**Why here and not left to REQ-355/357:** the permission atom gates the **writer**
(§5), and 0028's standing prohibition already places the writer on this requirement's
side of the split (per this requirement's own description). A permission atom minted by
a later, vertical-specific requirement would mean the atom's own name and grant would be
authored under bucket-C scrutiny for a capability that is not vertical-specific — the
opposite of what rule 1 wants. Minting it here keeps the atom's definition and the write
path it gates in the same diff, which is also what req323 §3.5 asked OQ-1's resolution to
preserve.

**Role grant:** left to the requirement that authors the first concrete issue path
consuming this permission (REQ-355, per the requirement text). This document does not
decide which role(s) hold `:PublicReadHandlesIssue` — that is a per-instance
authorization-matrix decision, not a bucket-B platform one, and req323's own generic
positioning (§9.3, "the per-instance parts... who is authorized to issue a handle on the
authenticated side") already assigns it there.

### 13.2 The route itself

A route is shipped here — not left as a bare context function with no HTTP surface —
because the requirement text commits to "an authenticated, authorized issue path," and a
generic, kind-agnostic administrative surface is itself bucket B: it proves
`issue_handle/4` end-to-end without depending on any future vertical's own route ever
being built, and every future kind may call `Letflow.PublicRead.issue_handle/4` directly
in-process instead (as REQ-357's issue path does — see §5's function, not this route) or
via this route, whichever its own design prefers.

Mounted under `Letflow.Plugs.ApiPipeline` (tenant-scoped, authenticated — this is
**not** a public route and mounts nowhere near `/api/public`):

```elixir
# lib/letflow/plugs/api_pipeline.ex
forward("/public-read-handles", to: Letflow.Routers.PublicReadHandles)
```

```elixir
defmodule Letflow.Routers.PublicReadHandles do
  use Letflow.Api.AuthorizedRouter

  authz_post "/", :PublicReadHandlesIssue do
    # body: %{"kind" => String.t(), "resource_id" => Ecto.UUID.t(), "expires_at" => String.t() | nil}
    # tenant_id taken from conn.assigns.auth_context.tenant_id (never from the body --
    # INV-1: this route's own tenant scoping is the ordinary authenticated-path one,
    # unrelated to the public route's handle-based scoping)
    # calls Letflow.PublicRead.issue_handle/4, responds 201 with %{"handle" => plaintext}
  end
end
```

`kind` in the request body is **not** validated against the kind registry (§8) by this
route — a kind need not yet have a projection registered at the moment a handle is
issued for it (issuance and public exposure are independent steps; a handle issued for
an as-yet-unregistered kind simply 404s at read time, case 8, until the kind is
registered). This is a deliberate non-check, not an oversight — ELIXIR-DEV/REVIEWER
should not add one.

---

## 14. Acceptance-criteria checklist

| AC | Design element |
|---|---|
| 1 | §2 (mount fixed at req323 §2/0028 point 1, restated); test plan: assert an unauthenticated request to `/api/public/<kind>/:handle` is not rejected by `Letflow.Plugs.AuthPipeline` (it is structurally unreachable, since the forward precedes `/api/v1` — router-level test asserting no 401 with no `Authorization` header). |
| 2 | §5 (handle minting: `strong_rand_bytes(32)` + `Base.url_encode64`), §4 (stored value is `handle_hash`, never the plaintext) — test asserts `record.handle_hash != plaintext`; §13.2/§5's "never logged" rule + §15's grep. |
| 3 | §3 (migration) and §5 (writer) are specified in this one document and land in the one diff ELIXIR-DEV produces from it. |
| 4 | §7 (ten-case table), §6 (query plan producing each case's verdict). |
| 5 | §7's table — no row emits 401/403; §2's success/failure dispatch only ever calls `send_json(200, ...)` or `not_found/1`. |
| 6 | §6 (exact query plan: 1 round-trip pre-refusal via the joined query, 2 on success via the joined query + `Repo.get/3`), §9 (telemetry counting mechanism, transaction-control statements explicitly addressed — none fire on the resolution path). |
| 7 | §6, §7 case 1 — hashing is unconditional; no branch exists to short-circuit ahead of it. |
| 8 | §11 (limiter: keyed on `conn.remote_ip`, enforced first in `PublicRead`'s chain, before `:match`; 429 fires identically for a valid handle, per §11.2 step 3's ordering); test plan in §11.2. |
| 9 | §12 (three headers, set identically on every response). |
| 10 | §8 (config shape + `fetch_kind/1`), §2 (router has no kind-specific branch — grep target named), §10 (test-only fixture kind + its own 404 test). |
| 11 | §13.1 — `:PublicReadHandlesIssue`, minted and justified. |
| 12 | §11.1 — new module, justified against the deferred `Letflow.Plugs.RateLimit` row. |
| 13 | §15 below. |
| 14 | §16 below (checkable conditions restated per module). |

---

## 15. Decision 0022 rule 1 — vocabulary check

Every file this requirement adds is listed in §1. Since none of them exist as files yet
(design stage only), the check runs textually over this design document's own prose and
every identifier it proposes — exactly as req323 §13 performed its check on itself before
any code existed, and using the same term list and flags (`-rnwiE`, word-boundary) it
used:

```
$ grep -rnwiE "exam|exams|certificate|certificates|certification|candidate|candidates|quiz|grading|grader|proctor|bilimbaga|student|teacher|course|diploma|assessment" \
    lib/letflow/design/req352-unauthenticated-read-platform.md
```

Re-run against this document as it now stands (post-rework): **two hits, both of them
this section's own two grep-pattern literals on their own command lines** (this command's
line, plus the narrower command's line below, since its shorter term list is a subset of
this one's and so also matches its own citation of that subset). Zero hits anywhere in the
prose, identifiers, or examples — the same class of result, by the same method, req323
§13 reports for itself.

A second, narrower term list was also run — the exact list named in the rework
instruction that flagged §3's former illustrative example (a vertical-specific noun this
document no longer uses anywhere, having been replaced with a vocabulary-neutral
`{kind, resource_id}` phrasing):

```
$ grep -rnwiE "exam|exams|certificate|certificates|candidate|candidates|assessment|assessments" \
    lib/letflow/design/req352-unauthenticated-read-platform.md
```

Same result: two hits, the same two command lines above (each contains bare words this
narrower list also matches), and nothing else. Both runs confirm rule 1 is met, with every
remaining hit being one grep pattern's own literal citation on a command line in this
section — never a hit in prose, an identifier, or an example.

- Module names: `Letflow.Routers.PublicRead`, `Letflow.PublicRead`,
  `Letflow.PublicRead.Handle`, `Letflow.PublicRead.Projection`,
  `Letflow.Routers.PublicReadHandles`, `Letflow.Plugs.PublicReadRateLimit`,
  `Letflow.Plugs.PublicReadRateLimit.Bucket`, `Letflow.PublicReadFixtureSupport.Resource`,
  `Letflow.PublicReadFixtureSupport.Projection` — none contains a vertical term.
- Function/field names: `issue_handle/4`, `resolve/2`, `fetch_kind/1`, `consume/3`,
  `handle_hash`, `tenant_id`, `kind`, `resource_id`, `expires_at`, `revoked_at`,
  `:PublicReadHandlesIssue` — none contains a vertical term.
- The one test-only kind string, `"public-read-fixture"`, is deliberately generic.

A reader of this document cannot tell which vertical motivated it. That is the test rule
1 sets, and it is met.

---

## 16. For SECURITY-REVIEWER — checkable conditions, restated per module built here

req323 §12 already lists seven conditions binding "the implementing requirement." Mapped
onto this document's own modules so the gate can check them mechanically against actual
files rather than against req323's prose a second time:

1. **Round-trip 1 is a single joined query over `public_read_handles` → `tenants.status`**
   — §6's `Repo.one/1` query, `Letflow.PublicRead.resolve/2`.
2. **No syntactic pre-check short-circuits ahead of it** — §6/§7 case 1: confirm no `case`
   or `with` clause in the shipped `resolve/2` inspects `handle`'s length/charset before
   the hash+query.
3. **The limiter ships with the mount, before resolution, keyed on `conn.remote_ip`**
   — §11.2's plug ordering inside `Letflow.Routers.PublicRead`'s own chain (§2).
4. **The migration lands with its first writer** — §3 + §5, this same diff.
5. **Every refusal goes through `Response.not_found/1`** — §2 step 4, §7's table; confirm
   no hand-rolled 404 body anywhere in `Letflow.Routers.PublicRead`.
6. **The three cache/referrer/robots headers are added** — §12, and confirm they are set
   identically on both the success clause and the catch-all (not only one).
7. **No 401, no 403, no collection route, ever** — §7's table (no such case), §2 (exactly
   two route clauses: one `get`, one catch-all — no index/list route exists to check
   against).

Additionally, specific to this document's own new surface beyond req323's original
seven: **INV-1 on the authenticated issue route (§13.2)** — confirm `tenant_id` is read
only from `conn.assigns.auth_context.tenant_id`, never from the request body, exactly as
every other authenticated tenant-scoped write in this codebase; and **INV-4 on the writer
(§5)** — confirm the plaintext handle appears in `issue_handle/4`'s return value and
nowhere else (no `Logger` call anywhere in `Letflow.PublicRead`, and audit's
`after_state` excludes `handle_hash`... excludes the plaintext by construction, since the
plaintext is never a field on `Handle` at all).
