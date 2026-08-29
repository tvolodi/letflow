# REQ-176 — Dead-letter queue schema and core entry lifecycle

Design for the `dlq_entries` table and its backing context module,
`Letflow.Dlq`. Greenfield: S6's first requirement, no prior DLQ code exists to
extend. Binding contract per the requirement text: `web/src/api/dlq.ts`'s
`dlqApi` functions and `web/src/types/api.ts`'s `DlqEntry` / `DlqRetryAttempt`
/ `CursorPage<T>` types (already shipped under S8, currently calling a
backend that 404s), not a guess at R-Co's unreachable `src/dlq/`.

**Scope boundary, restated from the requirement:** this design covers only
the schema/migration and the context module's five functions
(`enqueue/1`, `list/2`, `get/2`, `retry/2`, `discard/2`). No route, no
controller, no Plug module — that is REQ-178. No wiring from REQ-056/REQ-061's
existing hooks — that is REQ-177. No webhook-origin entries — REQ-180. No
"timer" entries — not drafted in this batch.

## 1. Migration — `dlq_entries`

Tenant-scoped migration, following decision
`0003-ecto-schema-strategy.md` Decision B (schema-per-tenant +
intra-schema `tenant_id` retained) and the established
`if prefix() do ... end` guard idiom used by every tenant-scoped
migration in this codebase (e.g. `20260818110003_create_tasks.exs`).
Registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0`
alongside every other tenant-scoped migration — both halves (the guard
and the registry entry) are mandatory per that module's own
established discipline.

The table is created inside the tenant's own schema (no default primary key
generator — `id` is the explicit `:binary_id` primary key, same idiom as
`20260818110003_create_tasks.exs`'s own `tasks` table). Column list:

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | — | primary key |
| `tenant_id` | `:binary_id` | not null | — | intra-schema invariant column, Decision B; not itself the isolation boundary (the Postgres schema is) |
| `entry_type` | `:string` | not null | — | `"event"` \| `"timer"` \| `"webhook"` today (per `DlqPage.tsx`'s source-type filter); **plain `:string`, not `Ecto.Enum`** — requirement text states this is extensible, not a closed set, since REQ-177 adds `"event"` usages this requirement doesn't populate and REQ-180 will add more values later |
| `instance_id` | `:binary_id` | nullable | — | set when the entry originates from engine execution; **no FK reference** — an entry must be able to outlive or precede the referenced `instance_projections` row's own lifecycle assumptions, and no acceptance criterion requires referential integrity here |
| `reference_id` | `:string` | nullable | — | opaque reference to a non-instance originating record (future webhook delivery id); this requirement only reserves the column, writes nothing to it |
| `reason` | `:string` | nullable | — | short string |
| `full_reason` | `:text` | nullable | — | |
| `error_detail` | `:map` | nullable | — | jsonb |
| `error_chain` | `{:array, :map}` | nullable | — | jsonb array |
| `source_payload` | `:map` | nullable | — | jsonb; the payload needed to eventually retry |
| `context_json` | `:map` | nullable | — | jsonb |
| `retry_history` | `{:array, :map}` | not null | `[]` | jsonb array of maps, each shaped exactly like `DlqRetryAttempt` — see §2.2 |
| `retry_count` | `:integer` | not null | `0` | |
| `retry_limit` | `:integer` | nullable | — | |
| `next_retry_at` | `:utc_datetime` | nullable | — | |
| `status` | `:string` | not null | `"pending"` | `Ecto.Enum` at the schema layer (see §2.1) — closed set is correct here, unlike `entry_type`, because the requirement's own state machine (§3) is exhaustive and closed; stored lowercase, matching `DlqStatus` exactly — **not** the engine's uppercase `COMPLETED`/`CANCELLED`/`ERROR` convention, a distinct enum for a distinct table per the requirement text |
| `created_at` | `:utc_datetime` | not null | — | set by `enqueue/1`, not by Ecto's `timestamps/1` macro (see note below) |
| `first_failed_at` | `:utc_datetime` | nullable | — | |
| `last_failed_at` | `:utc_datetime` | nullable | — | |

No `updated_at`/`inserted_at` pair from `timestamps/1`: `DlqEntry`'s
contract names `created_at` specifically (not `inserted_at`), and there is no
`updated_at` field in the frontend type at all, so this table declares its
three datetime columns explicitly with `add/3` rather than reaching for the
macro that would produce mismatched names.

Indexes, each scoped to the same tenant schema as the table:

- A composite index named `idx_dlq_entries_list_cursor` on `(created_at, id)` — backs `list/2`'s keyset pagination order (§3).
- A single-column index named `idx_dlq_entries_status` on `status` — backs the `status` filter.
- A single-column index named `idx_dlq_entries_entry_type` on `entry_type` — backs the `entry_type` filter.

No index on `tenant_id` alone, matching `20260818110003_create_tasks.exs`'s
own precedent (the column is retained per Decision B but the Postgres schema,
not this column, is the actual isolation boundary, and no filter in this
requirement's own `list/2` spec queries by `tenant_id` in isolation).

No FK on `instance_id` (see table note above) and therefore no
`idx_dlq_*_instance` FK-referencing-side index either — there is no FK to
justify one under this codebase's established "index the referencing side of
every FK" convention, since there is no FK.

## 2. Ecto schema — `Letflow.Dlq.Entry`

`lib/letflow/dlq/entry.ex`. Ordinary `Ecto.Schema` (`@primary_key
{:id, :binary_id, autogenerate: true}`), no process, no `gen_statem` —
matches this codebase's plain-CRUD-table precedent (e.g.
`Letflow.Engine.Task`).

### 2.1 `status` — `Ecto.Enum`

The `status` field is declared as an `Ecto.Enum` with the closed value set
`:pending`, `:retrying`, `:resolved`, `:discarded` — the exact four states
`DlqStatus` names, in the same order.

`Ecto.Enum` casts `"pending"` (DB) <-> `:pending` (struct) automatically —
the struct-level API this design and the context module both use is atoms;
the wire format the frontend sees (via whatever encoder REQ-178 applies,
out of this requirement's scope) is the lowercase string form. This is the
same pattern decision 0003 Dimension A already prescribes ("TEXT-typed
status columns... become `Ecto.Enum` fields") and does not conflict with the
requirement text's "do not reuse the engine's uppercase convention" — the
enum's *stored values* are exactly `DlqStatus`'s four lowercase strings, only
the *in-Elixir* representation is atoms, which is `Ecto.Enum`'s standard
behavior everywhere else it's already used in this codebase.

### 2.2 `retry_history` shape

Each element is a plain map with exactly four keys, matching
`DlqRetryAttempt` field-for-field:

| Key | Type | Notes |
|---|---|---|
| `attempt_no` | integer | 1-indexed, monotonically increasing per entry |
| `attempted_at` | ISO-8601 string (UTC) | `DateTime.to_iso8601/1` of the retry's own timestamp |
| `outcome` | `"success"` \| `"failed"` | this requirement's own `retry/2` (§3) always appends `"failed"` at enqueue-time of the retry attempt itself — see the note in §3.1: `retry/2` records that a retry was *requested*, not that a re-execution *succeeded*, since re-execution is the injectable callback REQ-177 owns, out of this module's own knowledge |
| `error_message` | string, optional/nullable | omitted (absent key) or `nil` when there is nothing to record |

Deliberately **not** an `embeds_many` — no acceptance criterion needs
changeset-level validation on historical entries (they are appended
mechanically by `retry/2`, never user-supplied), and a plain `{:array, :map}`
field keeps the append operation a direct list-cons in Elixir followed by a
full-column `Ecto.Changeset.put_change/3`, with no separate embedded-schema
changeset boilerplate for a shape this module is the only writer of.

### 2.3 Full field type list (struct/`@type`)

```
@type t :: %__MODULE__{
  id: Ecto.UUID.t(),
  tenant_id: Ecto.UUID.t(),
  entry_type: String.t(),
  instance_id: Ecto.UUID.t() | nil,
  reference_id: String.t() | nil,
  reason: String.t() | nil,
  full_reason: String.t() | nil,
  error_detail: map() | nil,
  error_chain: [map()] | nil,
  source_payload: map() | nil,
  context_json: map() | nil,
  retry_history: [retry_attempt()],
  retry_count: non_neg_integer(),
  retry_limit: pos_integer() | nil,
  next_retry_at: DateTime.t() | nil,
  status: :pending | :retrying | :resolved | :discarded,
  created_at: DateTime.t(),
  first_failed_at: DateTime.t() | nil,
  last_failed_at: DateTime.t() | nil
}

@type retry_attempt :: %{
  required(:attempt_no) => pos_integer(),
  required(:attempted_at) => String.t(),
  required(:outcome) => String.t(),
  optional(:error_message) => String.t() | nil
}
```

## 3. Context module — `Letflow.Dlq`

`lib/letflow/dlq.ex`. Plain Ecto context module, no process — same shape
as `Letflow.Tasks`/`Letflow.Identity`. Every function takes `opts :: [prefix:
String.t()]`, `prefix` always supplied by the caller (the future REQ-178
route, via `Letflow.Api.Context.scoped_repo_opts/1`) — this module never
itself decides tenant scope, matching every REQ-072+ context module's own
"Tenant scoping (INV-1)" precedent.

```
@type opts :: [prefix: String.t()]
```

### 3.1 `enqueue/1`

```
@type enqueue_attrs :: %{
  required(:entry_type) => String.t(),
  optional(:instance_id) => Ecto.UUID.t() | nil,
  optional(:reference_id) => String.t() | nil,
  optional(:reason) => String.t() | nil,
  optional(:full_reason) => String.t() | nil,
  optional(:error_detail) => map() | nil,
  optional(:error_chain) => [map()] | nil,
  optional(:source_payload) => map() | nil,
  optional(:context_json) => map() | nil,
  optional(:retry_limit) => pos_integer() | nil,
  optional(:first_failed_at) => DateTime.t() | nil,
  optional(:last_failed_at) => DateTime.t() | nil
}

@spec enqueue(enqueue_attrs(), opts()) ::
  {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
```

Note the signature takes `(attrs, opts)`, two arguments — matching this
module's own `opts :: [prefix: ...]` convention used by every other function
below. (The requirement's own prose shorthand "`enqueue/1`" names the arity
without the mandatory tenant-scoping parameter that every other function in
this module also carries; `opts` is not optional, so the real arity is 2.)

Behavior: builds and inserts a new `Entry` row with:
- `status: :pending` (always, regardless of caller input — not
  caller-settable through `enqueue_attrs`)
- `retry_count: 0` (always)
- `retry_history: []` (always)
- `created_at` set to the current UTC wall-clock time, truncated to
  second precision, read inside this function (always, never
  caller-supplied — no `created_at` key exists in `enqueue_attrs` at all)
- `tenant_id` — **not accepted as part of `enqueue_attrs`.** Derived the same
  way every other tenant-scoped write in this codebase derives it: from the
  caller's own already-resolved tenant context, passed through `opts`
  alongside `prefix` (open question: see §5 — this design leaves the exact
  mechanism, `opts[:tenant_id]` vs. a second lookup, to ELIXIR-DEV, since no
  existing S6 caller is fixed yet and REQ-072's own `scoped_repo_opts/1`
  return shape should be checked against ELIXIR-DEV's actual implementation
  session).

All other fields insert as provided, `nil` where the caller omits an
optional key.

### 3.2 `list/2`

```
@type list_params :: %{
  optional(:status) => String.t() | nil,
  optional(:entry_type) => String.t() | nil,
  optional(:search) => String.t() | nil,
  optional(:instance_id) => Ecto.UUID.t() | nil,
  cursor: String.t() | nil,
  page_size: pos_integer()
}

@spec list(list_params(), opts()) ::
  {:ok, %{items: [Entry.t()], next_cursor: String.t() | nil}}
  | {:error, :invalid_cursor | :wrong_endpoint | :expired}
```

**Cursor-pagination mechanism** — reuses `Letflow.Api.Pagination` and the
exact keyset idiom `Letflow.Tasks.list_tasks/2` already established in this
codebase (design precedent, not invented fresh):

- Ordering column(s): `(created_at DESC, id DESC)` — `created_at` is this
  table's insertion-order timestamp (the DLQ analogue of `tasks.inserted_at`,
  see §1's note on why it isn't named `inserted_at` here), `id` is the
  tie-breaker for rows sharing a `created_at` value.
- Cursor prefix literal: `"D:"` — a new prefix, distinct from every other
  endpoint's (`"T:"` tasks, `"A:"` audit, etc.), so `decode_cursor/4`'s
  `{:error, :wrong_endpoint}` rejects a cursor minted by any other list
  endpoint.
- Raw cursor payload shape (built via
  `Letflow.Api.Pagination.build_raw_cursor_timestamp_key/4` or an equivalent
  manual `"D:<mint_time_us>:<created_at_us>:<id>"` construction — mirroring
  `Letflow.Tasks`'s own `"T:<mint_time_us>:<created_at_us>:<id>"` shape):
  encodes the last row's `created_at` (as microseconds since epoch) and `id`.
  `decode_cursor/4` handles the base64url decode, prefix check, and 24h
  expiry check; this module's own `decode_list_cursor/1` (private, mirroring
  `Letflow.Tasks.decode_list_cursor/1`) then parses `created_at_us` and `id`
  back out via `find_nth_colon/2` + `parse_int_from_cursor/3`, exactly the
  two-step split `Letflow.Tasks` and `Letflow.Routers.Audit` both already
  use.
- Seek predicate for the next page: a strict tuple-less-than comparison of
  `(created_at, id)` against the decoded cursor's `(created_at, id)` pair —
  the same two-column tuple-comparison idiom
  `Letflow.Tasks.filter_by_list_cursor/2` already uses for `(inserted_at,
  id)`. This is what guarantees no repeated or skipped ids across pages: it
  is a strict, total, tie-broken order over `(created_at, id)`, so each row
  appears in exactly one page regardless of how many rows share a
  `created_at` value.
- Page-fetch: fetch `page_size + 1` rows ordered as above; if more than
  `page_size` came back, the extra row is dropped and `next_cursor` is built
  from the last row *kept*; otherwise `next_cursor` is `nil` (exhausted) —
  same `split_list_page/2` shape as `Letflow.Tasks`.
- Response shape: `%{items: [Entry.t()], next_cursor: String.t() | nil}` —
  matches `CursorPage<DlqEntry>`'s `{items, next_cursor}` half exactly
  (`CursorPage<T>`'s third field, `has_more`, is a route-layer concern per
  REQ-178's own scope — `Letflow.Api.Pagination.Page`'s existing
  `count`/`items`/`next_cursor` envelope does not carry `has_more` either,
  and no acceptance criterion of this requirement names it).

**Filter composition** — `status`, `entry_type`, `instance_id`, and `search`
are independent `WHERE` predicates, each a no-op when its param is `nil`
(same `filter_by_status/2`-style clause-per-filter idiom as
`Letflow.Tasks.list_tasks/2`), so any combination narrows the result set
without interacting:

- `status`: exact match against the `status` column, after casting the
  caller's raw string param to its `Ecto.Enum` atom (via `Ecto.Enum.cast/1`
  or an equivalent membership check against the enum's own declared values);
  an unrecognized string is `{:error, :invalid_filter}`, mirroring
  `Letflow.Routers.Audit`'s own `{:error, :invalid_filter}` handling for an
  unsupported filter value.
- `entry_type`: exact match against the plain string `entry_type` column, no
  cast needed.
- `instance_id`: exact match against the `Ecto.UUID`-typed `instance_id`
  column; an unparseable UUID string is `{:error, :invalid_filter}` (checked
  via `Ecto.UUID.cast/1` before the query, matching
  `Letflow.Tasks.get_task/2`'s own "invalid UUID never reaches the DB"
  precedent).
- `search`: free text, matched case-insensitively (`ILIKE`, wrapped
  `"%...%"`, matching `Letflow.Identity`'s own
  `filter_by_search/2`/`filter_tenants_by_search/2` wrapping idiom) across
  three columns, OR'd together: `reason` directly; `instance_id` and `id`
  each cast to text first, since `ILIKE` cannot compare a UUID-typed column
  directly — the same UUID-vs-text casting idiom `Letflow.IdentityMigration`
  already uses elsewhere in this codebase via `Ecto.Query`'s `fragment/1`
  and `type/2`. Empty string and `nil` are both no-ops, same as those two
  existing functions.

Tenant scoping: this function issues exactly one query against the caller's
`prefix`, the same "prefix is the only tenant input" structure
`Letflow.Routers.Audit`'s own INV-1 section describes — there is no
query parameter through which a caller could widen the scope past one
tenant's own schema.

### 3.3 `get/2`

```
@spec get(id :: String.t(), opts()) :: {:ok, Entry.t()} | {:error, :invalid_id | :not_found}
```

`Ecto.UUID.cast/1` first, exactly like `Letflow.Tasks.get_task/2` — an
invalid UUID never reaches the database (`{:error, :invalid_id}`, no
round-trip). A single-row fetch by primary key, scoped by `prefix`; a
genuinely nonexistent id and a real id belonging to a different tenant's own
schema are both simply absent from
this schema's own `dlq_entries` table, so both resolve through the same
`{:error, :not_found}` branch — the identical structural
cross-tenant-404-by-construction mechanism REQ-072 established, not a
second branch this module would need to invent.

### 3.4 `retry/2`

```
@spec retry(id :: String.t(), opts()) ::
  {:ok, Entry.t()}
  | {:error, :invalid_id}
  | {:error, :not_found}
  | {:error, {:invalid_state, current_status :: :resolved | :discarded}}
```

State machine (exhaustive over `DlqStatus`'s four values):

| Starting `status` | Result |
|---|---|
| `:pending` | transitions to `:retrying`; appends one `DlqRetryAttempt` map to `retry_history` (§2.2); increments `retry_count` by 1 |
| `:retrying` | same as `:pending` — also transitions to `:retrying` (a no-op on the status column itself, but still appends a `retry_history` entry and increments `retry_count`, since "on a pending or retrying entry" in the requirement's own acceptance criterion does not distinguish the two starting states' *effects*, only lists both as valid *starting* states) |
| `:resolved` | **conflict** — `{:error, {:invalid_state, :resolved}}`; entry is read but not written: `status`, `retry_count`, and `retry_history` all remain byte-for-byte unchanged |
| `:discarded` | **conflict** — `{:error, {:invalid_state, :discarded}}`; same unchanged guarantee |

Mechanics: single-row `SELECT ... FOR UPDATE` (via `Ecto.Query.lock/3`) then
an in-Elixir status check then a conditional update, inside one
`Ecto.Multi`/`Repo.transaction/1` — the same
lock-then-check-in-Elixir-then-conditionally-write idiom
`Letflow.Tasks.claim_task/3`/`assign_task/4`/`reassign_task/4` already
establish for exactly this "avoid a bare racing `UPDATE ... WHERE`" shape.
Lock scope: this row only, filtered by its own `id`, no other row or table.

The `retry_history` entry appended on a successful call (§2.2's shape):
`attempt_no` is `retry_count + 1` (the value *after* increment — i.e. the
1-indexed ordinal of this attempt); `attempted_at` is
`DateTime.utc_now()`'s ISO-8601 form, read inside the same transaction as
the row lock; `outcome` is `"failed"` (see §2.2's note — this module has no
knowledge of whether an eventual re-execution succeeds, since re-execution
is REQ-177/180's injectable-callback territory, entirely outside this
requirement); `error_message` is omitted/`nil` (this module records that a
retry was requested, not a re-execution failure detail it doesn't possess).

`retry_limit`/`next_retry_at` are **not** read or enforced by this function
— the requirement's own state machine names only `status` as the gate
(`"pending"`/`"retrying"` vs. `"resolved"`/`"discarded"`), and no acceptance
criterion ties `retry/2`'s success/failure to `retry_count` vs.
`retry_limit`. Left as an explicit open question in §5, not silently
resolved.

### 3.5 `discard/2`

```
@spec discard(id :: String.t(), opts()) ::
  {:ok, Entry.t()}
  | {:error, :invalid_id}
  | {:error, :not_found}
  | {:error, {:invalid_state, current_status :: :resolved | :discarded}}
```

Same lock-then-check-then-write mechanics as `retry/2`. State machine:

| Starting `status` | Result |
|---|---|
| `:pending` | transitions to `:discarded` (terminal) |
| `:retrying` | transitions to `:discarded` (terminal) |
| `:resolved` | **conflict** — `{:error, {:invalid_state, :resolved}}`; unchanged |
| `:discarded` | **conflict** — `{:error, {:invalid_state, :discarded}}`; unchanged — calling discard twice never silently succeeds a second time |

`discard/2` does not touch `retry_history`, `retry_count`, or any
`*_failed_at` column — only `status` changes.

## 4. What this module explicitly does not do (restated from the requirement)

`retry/2` manages only the `dlq_entries` row's own state. It has no
knowledge of, and never calls, whatever would actually re-dispatch a
`SERVICE_TASK` or resume an ERRORed instance — that origin-specific
re-execution is an injectable callback REQ-177 (and, for webhooks, REQ-180)
supplies at a boundary this module does not define or expose in this
requirement. No callback parameter, behaviour, or protocol appears anywhere
in `Letflow.Dlq` as specified here; REQ-177's own design is responsible for
introducing whatever hook shape it needs on top of this module's public
functions.

## 5. Open questions (not resolved here — for ELIXIR-DEV/REVIEWER)

1. **How `tenant_id` reaches `enqueue/1`.** This design assumes it arrives
   via `opts` (alongside `prefix`) rather than `enqueue_attrs`, matching the
   "never caller-supplied inside the attrs map, always from resolved tenant
   context" discipline elsewhere in this codebase, but the exact `opts` key
   name/shape (`opts[:tenant_id]` vs. deriving it from `prefix` via a schema
   registry lookup) is not fixed by this design — check
   `Letflow.Api.Context.scoped_repo_opts/1`'s actual return shape at
   implementation time rather than inventing a new one.
2. **Whether `retry/2` should consult `retry_limit`.** The requirement's own
   state machine and acceptance criteria gate `retry/2` solely on `status`;
   this design does not add a `retry_count >= retry_limit` rejection because
   no acceptance criterion asks for one and the requirement's own hook
   boundary (§4) suggests exhaustion-driven landing is REQ-177's concern, not
   a re-retry gate here. Confirm this reading before building, since a
   `retry_limit`-that-does-nothing column could be mistaken for dead code by
   a later reviewer if this isn't stated at the call site too.
3. **`first_failed_at`/`last_failed_at` writers.** This design has
   `enqueue/1` accept them optionally (a caller may know the original
   failure time already) but does not have any function in this module set
   `last_failed_at` automatically on `retry/2` — the requirement text does
   not name this as a `retry/2` side effect, so this design does not invent
   one. If REQ-177's landing call sites expect `last_failed_at` to advance on
   retry, that behavior needs its own explicit acceptance criterion,
   presumably on this requirement or REQ-177, before it's built.
