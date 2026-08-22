# Design: REQ-125 — `GET /definitions/delta` (MOB-3 delta sync)

## 0. Sources read for this design

- `docs/requirements.yaml` REQ-125 (handed in full as `context.requirement_text` —
  not re-read from the file).
- `docs/guides/backend_developer_guide.md` — naming, error-shape, migration, and
  multi-tenancy conventions.
- `docs/migration/stage-9-mobile.md` — confirms this is genuinely new work (no R-Co
  source), and that `MOB-3`'s two backend gaps (`GET /definitions/delta`, and
  `{form_id, form_version}` on task payloads — the latter out of scope here, REQ-126)
  are independent.
- `docs/migration/decisions/0003-ecto-schema-strategy.md` — Decision B (schema-per-
  tenant) and its 2026-08-17 addendum (`tenant_id` always derived from `opts[:prefix]`,
  never caller-supplied).
- `lib/letflow/routers/definitions.ex` — existing route table, ordering-hazard
  precedent (`/active/:name`, `/search`, `/:id/export` all declared above `/:id`),
  `with_authorized_scope/4` helper, INV-5 cross-tenant-is-404 precedent.
- `lib/letflow/definitions.ex` — existing context module: `list_paginated/2` and
  `search_paginated/3` (REQ-081) are the closest siblings — both are cursor-paginated
  reads scoped by `opts[:prefix]`, both delegate cursor encode/decode to
  `Letflow.Api.Pagination`.
- `lib/letflow/api/pagination.ex` — the **existing, established cursor primitive**.
  Opaque `"<prefix><mint_time_us>:<key>...".` payload, base64url-encoded, with a
  built-in 24h mint-time expiry check (`decode_cursor/4`) and an endpoint-prefix check
  (`check_prefix/2`) that makes one endpoint's cursor unusable against another's
  decoder. **INV-1/INV-5 note in its own moduledoc: `Cursor.t()` carries no
  `tenant_id`/`schema`/`prefix` field — tenant scope is never decoded from a cursor,
  only ever supplied by the caller's own authenticated request context.**
- `lib/letflow/definitions/process_definition.ex` — the `process_definitions` schema.
  `status` is a lowercase `Ecto.Enum` (`:draft | :active | :deprecated | :archived`,
  INV-DEF-3), the only legal transitions are `draft → active`, `active → deprecated`,
  `deprecated → archived` (PD-04), and — checked directly against `Letflow.Definitions`
  — **there is no delete function anywhere in this module.** A `process_definitions`
  row is never hard-deleted; `archived_at` (nullable `utc_datetime_usec`) is the
  closest thing to a "this is gone" marker and is only ever set by `archive/2`.
- `priv/repo/migrations/20260816193001_create_process_definitions.exs` — current
  columns/indexes on `process_definitions`. No sequence/version column exists today.
- `lib/letflow/event_store.ex` +
  `priv/repo/migrations/20260816120002_create_instance_sequence.exs` — the
  **established monotonic-counter pattern** this design reuses: a dedicated
  tenant-schema-scoped counter table (`instance_sequence`: `next_seq bigint`, no
  timestamps, no FK — "the hot row every append takes a `SELECT ... FOR UPDATE` on"),
  locked and incremented inside the same transaction as the row it sequences.
- `docs/anti-patterns.md` — "Duplicating an `Ecto.Query.fragment/1` SQL literal"
  (module-attribute sharing, not directly triggered here but the same discipline
  applies to the new `WHERE sequence_number > $1` predicate reused across two call
  sites).

## 1. Scope boundary

This design adds exactly one new route (`GET /definitions/delta`), one new
`Letflow.Definitions` context function (`delta/2`), one new counter table
(`definition_sequence`, mirroring `instance_sequence`), and one new column on
`process_definitions` (`sequence_number`). It does **not** touch `create/2`,
`activate/2`, `deprecate/2`, `archive/2`'s public contracts — each gets one additional
internal step (assign/stamp the next sequence number) inside its existing transaction,
not a new public parameter. It does not add a hard-delete path — REQ-125's requirement
text does not ask for one, and none exists today to port.

## 2. Cursor semantics decision (AC2) — monotonic cursor, not a timestamp

**Decision: `since` is a per-tenant-schema monotonically increasing integer
(`sequence_number`), never a wall-clock timestamp.**

Reasoning, to be stated verbatim (adapted) in `Letflow.Definitions.delta/2`'s
moduledoc:

- **Clock skew is exactly the failure mode this endpoint runs under (per REQ-125's own
  text).** A mobile device warming an offline cache compares its last-seen watermark
  against the server on every subsequent sync, often after being offline for hours or
  days, on hardware whose clock is not NTP-disciplined the way the server's is. If
  `since` were `updated_at` (a `utc_datetime_usec` written by the *server's* clock at
  write time but interpreted by comparing against a value the *device* last stored),
  every device clock's drift, timezone misconfiguration, or a leap-second smear
  becomes a correctness bug in what the device believes it already has.
  A monotonic integer has no notion of "now" on either side — it is a pure watermark,
  compared with `>`, never interpreted as elapsed time.
- **The counter is server-assigned, not derived from any timestamp column.** It is
  bumped by exactly one write path (§4), inside the same transaction as the row
  mutation it sequences, so "the cursor advanced" and "a row actually changed" can
  never disagree (no lost-update race between reading `now()` and committing).
- **This mirrors an already-established Letflow pattern, not a new one.** REQ-023/025's
  `instance_sequence` table does exactly this for per-instance event ordering
  (`lib/letflow/event_store.ex`, `assign_sequence/3`: lock the counter row `FOR UPDATE`,
  read `next_seq`, write the row with that value, increment the counter, all inside one
  transaction). This design reuses that shape at tenant-schema granularity instead of
  per-instance granularity — see §5 for why per-schema (not per-row, not global-across-
  tenants).
- **Rejected alternative — `updated_at`-based `since`:** would satisfy AC1 in the happy
  path (nothing observes clock skew in a same-session test) but fails exactly the
  scenario REQ-125 calls out by name — a device offline across a skew event — silently,
  since a timestamp comparison never raises an error, it just quietly omits or
  duplicates rows.
- **Rejected alternative — an opaque `Letflow.Api.Pagination` cursor identical to
  `list_paginated/2`'s:** `Pagination.decode_cursor/4`'s cursor carries a **mint-time
  expiry baked into the cursor payload itself** (24h from when the cursor was minted),
  which is the right property for "resume a list you were paging through a few minutes
  ago" but the wrong property for "a device that was offline for a week presents its
  last watermark." A delta `since` value must remain valid indefinitely (until it falls
  outside retained history, see §4) — REQ-125's text explicitly asks for the
  old-cursor case to be a **defined, distinguishable outcome**, not an expiry error
  reusing the pagination cursor's own `{:error, :expired}`. Reusing `Pagination`'s
  format would conflate "this cursor is stale because 24h passed" (an artifact of the
  *pagination* cursor's own mint-time design) with "this cursor predates retained
  delta history" (a fact about the *data*), which are different failure conditions with
  different remediation (retry vs. full resync). **`since` is therefore a plain
  decimal-string-encoded integer, not a `Pagination.Cursor`.** It is still validated
  as an opaque value from the client's point of view (§6), just not built on the
  pagination module's expiry machinery.

## 3. Deletion/deprecation representation (AC3)

**Decision: every definition returned in a delta response carries its current
`status`; there is no separate tombstone record type.**

Since `process_definitions` rows are never hard-deleted (§0), "deletion" for this
endpoint's purposes is a definition transitioning to `:deprecated` or `:archived`.
`delta/2`'s query is **not** filtered by status — a row that has just been created is
"changed" (new), and a row that has just been deprecated/archived is *also* "changed"
(its `sequence_number` was bumped by that transition, §4), so both land in the same
result set, distinguished only by their `status` field in the returned map, exactly
the way `Letflow.Routers.Definitions.definition_map/1` already renders `status`.

A cache consuming the delta (AC3's literal requirement) determines "this definition is
gone" by checking `status in ["DEPRECATED", "ARCHIVED"]` on an item it already has
cached and either removing it or marking it stale — the client-side policy (remove
immediately on `ARCHIVED`, or on `DEPRECATED` too since a deprecated definition should
no longer be presented for new instance starts) is a mobile-app decision outside this
backend design's scope, but the **wire shape carries enough information to make it**,
which is the property AC3 actually tests. This is a deliberate, disclosed choice not
to invent a separate `deleted: true` / tombstone-only payload shape: R-Co has no
precedent for one (this is new work, per REQ-125's own text), and reusing the existing
`status` field is strictly less surface than adding a second representation of the
same fact.

**Open question (not silently resolved):** whether a *permanently deleted* row (should
one ever be introduced by a future requirement — none exists today) would need a true
tombstone distinct from `archived`. Flagged for CODE-DESIGN-VALIDATOR / a future
requirement; out of scope here because no delete path exists to port or design against.

## 4. Behaviour when `since` predates retained history (AC4)

**Decision: `since` is never actually "too old" in the sense of missing data, because
the sequence counter's history is exactly as long as `process_definitions` itself —
there is no separate retention/pruning of sequence numbers, so this design provides no
distinguishable "history has been pruned" outcome... EXCEPT one real, checkable stale
condition: `since` is well-formed but its value is `0`, negative, non-numeric, or
otherwise not a valid watermark for this tenant's counter.** These are collapsed into
one explicit, typed outcome: `{:error, :invalid_since}`, mapped to **400** by the
route (not a silent full-history dump, and not conflated with the empty-delta 200
case).

Rationale for why "cursor predates retained history" resolves to "return everything,
type-checked" rather than a distinct error: unlike `Letflow.Api.Pagination`'s minted
cursors (which expire after 24h *by design*, so "too old" is a real, reachable state
the pagination module enforces), the `definition_sequence` counter here has **no
expiry and no pruning** — sequence numbers are permanent integers assigned once and
never reclaimed (the counter only increments). A `since=0` (or `since` omitted) is
therefore not an error at all: it is the well-defined "give me full history" case, and
`delta/2` returns every row with `sequence_number > 0`, i.e. every row that exists —
this is what AC4 calls the "cursor older than any retained history" case resolving to,
made **explicit and tested**, not silently defaulting to an incomplete delta. A
client's very first sync (no prior watermark) sends no `since` param and gets exactly
this path — full resync **by construction**, not by a special-cased "reset" response
shape.

What *is* rejected, explicitly, as `{:error, :invalid_since}` (400): a negative
integer, a non-integer string, or a `since` value than the current tenant's own
`next_seq` counter has never plausibly reached (out of scope to detect precisely —
see Open Questions §9 OQ-1) is **not** checked against the counter's current value;
only syntactic validity is checked. A `since` numerically larger than the tenant's
actual high-water mark (e.g. a device migrated from a different tenant's counter
space, or corrupted local state) simply returns an empty delta — indistinguishable
from "you are already fully caught up" — which is the correct, safe behaviour (never
returns *more* than what changed, never fabricates a "full resync required" signal
from a value that could equally mean "already current").

This resolves AC4 without inventing a "cursor too old" response class that this
counter's design (unlike `Pagination`'s expiring, minted cursors) has no factual basis
to produce truthfully.

## 5. New Ecto schema fields / migration

### 5.1 `process_definitions.sequence_number` (new column)

```
add :sequence_number, :bigint, null: false, default: 0
```

Added via a new, additive, reversible migration (Ecto `change/0`, matching §3.7 of the
backend guide and the `instance_sequence` migration's own shape). `default: 0` only
sets the value for rows that exist at migration time (none — this table has no
production data yet in any environment this pipeline runs against) and satisfies
`null: false` for the `add` statement itself; every row inserted by `create/2` from
this point forward gets a real assigned value from `definition_sequence` (§5.2), never
the literal default.

New index (delta query's own access path, §7):

```
create index(:process_definitions, [:sequence_number],
         name: :idx_def_sequence_number,
         prefix: prefix()
       )
```

Tenant-scoped migration (`if prefix() do` guard, registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0`), matching every other
`process_definitions`-touching migration.

### 5.2 `definition_sequence` (new counter table, mirrors `instance_sequence`)

```
create table(:definition_sequence, primary_key: false, prefix: prefix()) do
  add :tenant_id, :binary_id, primary_key: true
  add :next_seq, :bigint, null: false, default: 1
end
```

One row per tenant schema (not per-definition, not per-instance) — a single counter
shared across every `process_definitions` row in that schema, because the delta
endpoint's ordering guarantee (AC1: "only definitions changed after the supplied
cursor") is over the **whole tenant's definition set**, not any one definition's own
history. `tenant_id` is the primary key (not an autoincrement id) so the row is
addressable without a lookup — same shape as `instance_sequence`'s `instance_id`
primary key. No FK (same rationale as `instance_sequence`: a platform-sentinel value,
and the row for a tenant schema is provisioned once, at tenant-provisioning time or
lazily on first definition write — see Open Questions §9 OQ-2 for which). No indexes
beyond the primary key, no `timestamps/1` — same "hot row, no consumer for
`updated_at`" reasoning as `instance_sequence`'s own migration header.

**Ecto schema module:** `Letflow.Definitions.DefinitionSequence`, structurally
identical to `Letflow.EventStore.InstanceSequence` (`primary_key: false`,
`@primary_key {:tenant_id, :binary_id, autogenerate: false}`, one field `next_seq ::
non_neg_integer()`).

### 5.3 Assignment protocol — reuses `Letflow.EventStore.assign_sequence/3`'s exact shape

Every one of `create/2` (on insert), `activate/2` (both the deprecate-prior-active and
activate-this-one writes, since both are "the definition set changed"), `deprecate/2`,
and `archive/2` gains one additional step inside its **existing** transaction:

1. `SELECT next_seq FROM definition_sequence WHERE tenant_id = $1 FOR UPDATE` (lock).
   If no row exists yet, insert one first with `on_conflict: :nothing` (mirrors
   `assign_sequence/3`'s own "insert-then-lock" two-step for a tenant/instance seen for
   the first time).
2. Stamp the row being written (`INSERT`/`UPDATE ... process_definitions SET
   sequence_number = $assigned, ...`) with the locked value.
3. `UPDATE definition_sequence SET next_seq = next_seq + 1 WHERE tenant_id = $1`.

This keeps sequence assignment **inside** the same transaction and lock discipline
`activate/2` already uses for its own row locking (`design §4.1`,
`run_activate_transaction/4`), so a rolled-back activation never burns a sequence
number it didn't use, and two concurrent writers can never be assigned the same
number.

## 6. Public function signatures

### 6.1 `Letflow.Definitions.delta/2`

```elixir
@type delta_opts :: [prefix: String.t()]

@type delta_result :: %{
        items: [ProcessDefinition.t()],
        next_since: pos_integer()
      }

@type delta_error ::
        {:error, :invalid_since}
        | common_error()

@spec delta(since :: non_neg_integer() | nil, opts :: delta_opts()) ::
        {:ok, delta_result()} | delta_error()
```

Behaviour (moduledoc, mapped to AC1/AC2/AC4):

- `since` is `nil` (or `0`) → full history, per §4.
- `since` a negative integer → `{:error, :invalid_since}`.
- Otherwise: `WHERE sequence_number > since`, `ORDER BY sequence_number ASC`, scoped by
  `opts[:prefix]` exactly like every other function in this module (`tenant_id` never
  a separate argument — derived from `opts[:prefix]` via
  `TenantProvisioning.tenant_id_for_schema_name/1`, same as `list_paginated/2`).
- **No page-size limit / no pagination inside this function** — REQ-125's acceptance
  criteria describe a bounded warm-cache/incremental-refresh workload (a tenant's
  total definition count), not an unbounded feed; capping this is flagged as an Open
  Question (§9 OQ-3) rather than silently guessed at, since no acceptance criterion
  states a page size and inventing a cursor-pagination layer on top of the delta
  cursor would conflate two different cursor concepts in one response.
- `next_since` in the result is **always** the tenant's current high-water mark
  (`definition_sequence.next_seq - 1`, i.e. the highest `sequence_number` that exists,
  or the caller's own `since` unchanged if strictly higher and nothing changed) — a
  device stores this and sends it back as `since` on its next call. This is what makes
  a **zero-change delta** (device already caught up) return `{:ok, %{items: [],
  next_since: since}}`, never an error — mirrors `list_paginated/2`'s "empty page is
  `{:ok, ...}`, never an error" precedent.
- Read-only, one query (plus the `TenantProvisioning` prefix check every function in
  this module already performs) — no sequence assignment happens on a *read*, only
  on the *writes* described in §5.3.

### 6.2 Router — `GET /definitions/delta`

`lib/letflow/routers/definitions.ex` gains one route, declared **above** `get "/:id"`
for the same first-match-wins reason `/active/:name`/`/search`/`/:id/export` already
are (moduledoc "Route ordering" section) — `delta` is a literal path segment that
would otherwise be swallowed by `/:id` binding `id => "delta"`:

```elixir
get "/delta" do
  handle_delta(conn)
end
```

Handler shape (mirrors `handle_list/1`'s `with_authorized_scope/4` wiring exactly —
same permission key, §8):

```elixir
@spec handle_delta(Plug.Conn.t()) :: Plug.Conn.t()
```

- Reads `since` from `conn.query_params["since"]` — `nil` (absent) or a decimal-digit
  string. A present-but-non-numeric string is rejected by the same
  `{:error, :invalid_since}` path `delta/2` returns for a syntactically bad value (the
  route does no separate int-parsing validation layer of its own — parses via
  `Integer.parse/1` requiring full-string consumption, same idiom
  `Pagination.parse_page_size_param/1` already uses elsewhere in this codebase, then
  hands the parsed integer to `delta/2`; a parse failure is rendered the same 400 as
  `delta/2`'s own `:invalid_since`).
- 200 response body: `%{"items" => [...], "next_since" => integer}`, `items` rendered
  through the **existing** `definition_map/1` allowlist (no new response shape to
  audit for INV-2 — every field already goes through the same allowlist REQ-081's read
  routes use, `status` included).
- 400 on `{:error, :invalid_since}`.
- 500 on `common_error()` (same collapse every other handler in this router already
  uses).

## 7. DB indexes needed

- `idx_def_sequence_number` on `process_definitions(sequence_number)`, tenant-schema
  scoped (§5.1) — the delta query's own access path (`WHERE sequence_number > $1 ORDER
  BY sequence_number ASC`). Without it, every delta call is a full sequential scan of
  the tenant's entire definition table; with a monotonic btree index the query is a
  single index range scan, the same shape `idx_def_status` already serves for
  `list_paginated/2`'s `?status=` filter.
- No new index needed on `definition_sequence` — its own PK (`tenant_id`) is the only
  access path (`WHERE tenant_id = $1 FOR UPDATE`), same as `instance_sequence`'s PK-only
  access path.

## 8. Tenant isolation (AC5)

- **Row scoping.** `delta/2`'s query runs against `ProcessDefinition` with
  `prefix: opts[:prefix]` (Postgres schema-per-tenant, Decision B) — structurally the
  same isolation mechanism every other read in this module already relies on. A tenant
  A caller's `opts[:prefix]` resolves to tenant A's own Postgres schema; tenant B's
  `process_definitions` rows live in a *physically different schema* the query never
  touches. This is stronger than a `WHERE tenant_id = ?` filter (which would still be a
  single shared table one bad predicate could leak from) — there is no shared table to
  leak from at all.
- **The cursor cannot be used to probe another tenant's change volume**, because
  `since`/`next_since` are **plain integers scoped to one tenant's own
  `definition_sequence` counter** — there is no global-across-tenants sequence space
  (§5.2's per-tenant-schema counter, deliberately not a single shared table keyed by
  `(tenant_id, next_seq)` in the public schema). A caller authenticated as tenant A has
  no way to even address tenant B's counter: `opts[:prefix]` is derived from the
  caller's own authenticated context (`Letflow.Api.Context.scoped_repo_opts/1`, wired
  identically to every other route in this router — REQ-125 introduces no new
  auth/scoping mechanism), never from a client-supplied value, and the `since` integer
  itself carries no tenant identifier a client could vary to "aim" it at a different
  tenant's counter — the counter it is compared against is selected exclusively by
  which schema the authenticated request resolves into. Sending tenant A's `since`
  value to a request authenticated as tenant B simply compares it against **tenant
  B's own, unrelated** counter — meaningless, not a leak, and not informative about
  tenant A's actual change volume (tenant B's counter has no relationship to tenant
  A's).
- **Test obligation (AC5, mapped directly):** a test asserting a delta request
  authenticated as tenant A, with definitions created/mutated in both tenant A's and
  tenant B's schemas, never returns a tenant-B-owned definition in its `items` list —
  same shape as `Letflow.Routers.Instances`'s existing cross-tenant tests, adapted to
  this endpoint.
- **Permission.** `GET /definitions/delta` maps to the existing `:DefinitionsRead`
  policy key — `Letflow.Api.Authorization.endpoint_policy_key/2` gains one more path
  literal in its existing `"GET", path when path in [...]` clause for `:DefinitionsRead`
  (`lib/letflow/api/authorization.ex` lines 200-206), no new permission atom. Wired via
  the same `with_authorized_scope/4` private helper every REQ-081 handler already uses
  — no `Repo` call of any kind before both tenant-scope resolution and the permission
  check have run (this router's "Ordering guarantee" moduledoc section).

## 9. Open questions (explicitly listed, not silently resolved)

- **OQ-1 (§4).** Whether `delta/2` should validate `since` against the tenant's actual
  current high-water mark (returning some distinguishable "since is impossibly high"
  signal) rather than silently treating any `since >= current max` as "nothing new."
  Left unresolved here: REQ-125's AC4 asks specifically about `since` being *too old*
  (predates retained history), not too new, and no acceptance criterion describes a
  desired behaviour for an implausibly-high value. Flagged for ELIXIR-DEV/REVIEWER —
  current design treats it as indistinguishable from "already caught up," which is
  safe (never omits data) but not necessarily the most helpful signal to a
  buggy/corrupted client.
- **OQ-2 (§5.2).** Whether `definition_sequence`'s one row per tenant is provisioned
  eagerly (at tenant-provisioning time, alongside `instance_sequence`'s own per-
  instance lazy-insert precedent suggests otherwise) or lazily on first
  `create`/`activate`/`deprecate`/`archive` call for that tenant (mirroring
  `instance_sequence`'s actual "insert-then-lock, `on_conflict: :nothing`" pattern
  exactly). This design assumes **lazy**, matching the reused pattern precisely, but
  flags it since `Letflow.TenantProvisioning`'s own provisioning-time responsibilities
  were not audited as part of this design.
- **OQ-3 (§6.1).** Whether `delta/2` needs its own page-size cap for a tenant with an
  unusually large definition set (thousands+ of definitions all changed since a very
  old `since`). No acceptance criterion asks for pagination on this endpoint, and
  inventing one would require deciding how a `since` cursor composes with a
  `next_cursor` pagination cursor — two different cursor concepts layered together —
  which is a real design decision REQ-125's text does not scope. Left to a follow-up
  requirement if it proves necessary; not resolved here by guessing a page size.
- **OQ-4 (§3).** Whether a future hard-delete path (none exists today) would need a
  true tombstone distinct from the `archived` status. Not resolved — no delete path
  exists to design against.

## 10. Acceptance-criteria → design-element map

| AC | Design element |
|---|---|
| 1. Only definitions changed after `since`, ≥3 definitions/exactly 1 changed | §6.1 `delta/2`'s `WHERE sequence_number > since` query; §5.3 sequence assignment on every mutating operation (only the touched row's `sequence_number` advances) |
| 2. Cursor choice + reasoning + clock-skew treatment in moduledoc | §2 (monotonic cursor decision, explicit clock-skew rationale) — to be copied into `Letflow.Definitions.delta/2`'s own `@doc`/this module's moduledoc addendum |
| 3. Deletion/deprecation representable, cache can learn a definition is gone | §3 (`status` field on every delta item, no separate tombstone type, unfiltered-by-status query) |
| 4. Stale-cursor (`since` predates history) behaviour defined and tested | §4 (`since` nil/0 → full history by construction; malformed `since` → typed `:invalid_since` 400; no "too old" state exists to fabricate, reasoned explicitly) |
| 5. Tenant A never sees tenant B's definitions via delta | §8 (schema-per-tenant row scoping, per-tenant counter, no cross-tenant probing surface) |
