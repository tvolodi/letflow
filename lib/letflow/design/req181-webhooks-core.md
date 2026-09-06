# REQ-181 — Webhook subscription schema and core CRUD context module

PROVENANCE (historical, not current decision authority):
Design for the `webhook_subscriptions` table and its backing context module,
`Letflow.Webhooks`. Greenfield within S6: no prior webhook-subscription code
exists to extend. Binding contract per the requirement text and this run's
handoff: `web/src/api/dlq.ts`'s `webhooksApi` object and
`web/src/types/api.ts`'s `WebhookSubscription` type (already shipped under
S8, currently calling routes that 404) — **not** R-Co's `webhooks.zig`/
`src/webhook/`, unreachable from this drafting session, per the requirement
text's own "CONTRACT SOURCE" note. Read field-for-field:

```
webhooksApi.list: () => GET /api/v1/webhooks/subscriptions -> { items: WebhookSubscription[] }
webhooksApi.create: (body: { target_url, secret?, description?, event_types? }) -> POST -> WebhookSubscription
webhooksApi.update: (id, body: Partial<{ status: 'ACTIVE'|'PAUSED', is_active: boolean }>) -> PATCH -> WebhookSubscription
webhooksApi.delete: (id) -> DELETE -> void

WebhookSubscription {
  id: string
  subscription_id?: string
  target_url?: string
  url?: string
  description?: string
  event_types?: string[]
  status?: 'ACTIVE' | 'PAUSED'
  is_active?: boolean
  consecutive_failures?: number
  max_attempts?: number
  last_attempt_at?: string | null
  last_failure_at?: string | null
  paused_at?: string | null
  hmac_secret_once?: string
  created_at: string
  updated_at?: string
}
```

**Scope boundary, restated from the requirement:** this design covers only
the `webhook_subscriptions` migration and four context-module functions
(`create/2`, `list/1`, `update/2`, `delete/2`) plus the `get/2` helper
`create`/`list`/`update`/`delete` are proven against. **No route, no
controller, no Plug module** — that is REQ-182. No delivery attempts,
dispatch, HMAC signing of outgoing payloads, or the deliveries route
(`webhooksApi.getDeliveries`) — that is REQ-183/REQ-184, entirely out of
scope here; this design does not name a shape for `WebhookDeliveryAttempt`
at all.

## 0. Naming choices this design makes explicit up front

1. **The DB column is `secret_hash`, not `secret`.** The requirement text's
   field list says "`secret` (stored hashed — see below, never returned once
   created)" — read as "the concept named `secret` in the contract is stored
   hashed," not as a literal instruction that the column itself must be
   named `secret`. This design instead mirrors this codebase's own existing
   hashed-secret-storage precedent exactly (§2.2): `Letflow.Identity.ApiToken`
   stores its analogous once-shown value in a column named `token_hash`, not
   `token`, specifically so a column name never implies a plaintext value
   lives there. `secret_hash` follows that same discipline. Nothing in
   `WebhookSubscription`'s own field list is a literal `secret` key at all
   (it has `hmac_secret_once`, only present on the `create/2` response) — so
   there is no wire-contract field this naming choice could collide with.
2. **`event_types` is `{:array, :string}`**, matching `DlqEntry`-adjacent
   precedent of using plain array-of-string for an open, extensible set (the
   requirement text does not name a closed list of valid event type strings
   anywhere, and `WebhookSubscription.event_types` is `string[]`, untyped).
3. **`status` is stored as the two literal uppercase strings `"ACTIVE"` /
   `"PAUSED"`**, per the requirement text's explicit instruction that this is
   "a DIFFERENT convention from DlqEntry's lowercase status" — deliberately
   **not** unified with `Letflow.Dlq.Entry`'s lowercase `Ecto.Enum` (`§2.1`
   of `req176-dlq-core.md`). This design still uses `Ecto.Enum` at the schema
   layer (Elixir-side atoms `:ACTIVE`/`:PAUSED`, matching this codebase's own
   "TEXT-typed status columns become `Ecto.Enum` fields" convention from
   decision `0003-ecto-schema-strategy.md` Dimension A) — only the *stored
   string values* differ from `DlqEntry`'s, not the general mechanism.

## 1. Migration — `webhook_subscriptions`

Tenant-scoped migration, following decision `0003-ecto-schema-strategy.md`
Decision B (schema-per-tenant + intra-schema `tenant_id` retained) and the
`if prefix() do ... end` guard idiom, identical in shape to
`20260829000001_create_dlq_entries.exs` (REQ-176's precedent) and
`20260818110003_create_tasks.exs`. **Mandatory**, per that precedent's own
established discipline: this migration must also be registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` — both halves (the
guard and the registry entry) are required, not just the guard.

`id` is the explicit `:binary_id` primary key (`primary_key: false` on the
table, `add :id, :binary_id, primary_key: true` — no default primary-key
generator), same idiom as `dlq_entries`/`tasks`.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | — | primary key |
| `tenant_id` | `:binary_id` | not null | — | intra-schema invariant column, Decision B; not itself the isolation boundary (the Postgres schema is) |
| `target_url` | `:string` | not null | — | required per `create/2`'s contract; `webhooksApi.create`'s `target_url` field |
| `secret_hash` | `:string` | not null | — | **hashed storage only** — see §0.1 and §2.2; never the plaintext |
| `description` | `:string` | nullable | — | optional |
| `event_types` | `{:array, :string}` | not null | `[]` | array of strings, open set (§0.2) |
| `status` | `:string` | not null | `"ACTIVE"` | `Ecto.Enum`, closed set `:ACTIVE` \| `:PAUSED`, stored uppercase (§0.3) — a newly-created subscription is always `ACTIVE` per `create/2`'s own behavior (§3.1), never caller-settable at creation |
| `consecutive_failures` | `:integer` | not null | `0` | |
| `last_attempt_at` | `:utc_datetime` | nullable | — | |
| `last_failure_at` | `:utc_datetime` | nullable | — | |
| `paused_at` | `:utc_datetime` | nullable | — | set/cleared by `update/2`'s status reconciliation (§3.3) |
| `created_at` | `:utc_datetime` | not null | — | set by `create/2`, not by Ecto's `timestamps/1` macro (see note below) |

No `updated_at`/`inserted_at` pair from `timestamps/1`: `WebhookSubscription`
carries an optional `updated_at` field, but no acceptance criterion in this
requirement requires this module to populate one (the frontend type marks it
optional, and no listed function's behavior below writes to it) — declaring
a column this module never writes would be dead schema surface. Left as an
open question in §5 rather than silently added.

Indexes, each scoped to the same tenant schema as the table:

- A single-column index named `idx_webhook_subscriptions_status` on `status`
  — backs a future status filter (REQ-182 may or may not expose one; this
  index costs nothing to add now and mirrors `dlq_entries`' own
  `idx_dlq_entries_status` precedent for a status column with few distinct
  values that a list endpoint plausibly filters on).

No index on `tenant_id` alone, matching `dlq_entries`/`tasks`' own precedent
(the Postgres schema, not this column, is the actual isolation boundary).
No unique constraint on `target_url` — the requirement text does not state
one subscription per URL, and `WebhookSubscription` has no field implying
uniqueness beyond `id`.

## 2. Ecto schema — `Letflow.Webhooks.Subscription`

`lib/letflow/webhooks/subscription.ex`. Ordinary `Ecto.Schema`
(`@primary_key {:id, :binary_id, autogenerate: true}`), no process — matches
`Letflow.Dlq.Entry`/`Letflow.Identity.ApiToken`'s plain-CRUD-table precedent.

### 2.1 `status` — `Ecto.Enum`

Declared as `Ecto.Enum`, closed value set `:ACTIVE`, `:PAUSED` — stored as
the literal uppercase strings `"ACTIVE"`/`"PAUSED"` (§0.3). `Ecto.Enum` casts
`"ACTIVE"` (DB) <-> `:ACTIVE` (struct) automatically; the struct-level API
this design and the context module use is atoms, the wire format (via
whatever encoder REQ-182 applies, out of this requirement's scope) is the
uppercase string form, matching `WebhookSubscription.status`'s own
`'ACTIVE' | 'PAUSED'` literal-string union type exactly.

### 2.2 `secret_hash` — hashing precedent (established, not invented)

This codebase already has exactly one hashed-secret-storage precedent for
"generate a plaintext, return it once, store only a hash": `Letflow.Identity`
's API-token issuance (`lib/letflow/identity.ex`, `insert_token/3` +
`generate_token_plaintext/0` + `hash_token_value/1`, backing
`Letflow.Identity.ApiToken`'s `token_hash` column). No `bcrypt`/`argon2`
dependency exists anywhere in `mix.lock`/`mix.exs`, and no other hashing
scheme is used for a comparable "opaque server-generated secret" case
anywhere in `lib/letflow/` (checked by grep before writing this design, per
this run's handoff instruction) — `Letflow.Identity.User.password_hash` is a
*user-supplied-password* field, an unrelated concern with its own sentinel
values (`"__OIDC_ONLY__"`, `"__NO_PASSWORD_SET__"`) and no actual hashing
call site in this codebase yet either, so it sets no precedent to follow.
This design therefore reuses `Letflow.Identity`'s own token mechanism
in substance, not a new invention: a private plaintext-generation helper
produces a cryptographically random byte string via
`:crypto.strong_rand_bytes/1` (same 32-byte length as `Letflow.Identity`'s
own token generator), hex-encodes it lowercase via `Base.encode16/2` with
`case: :lower`, and prepends a literal string prefix so the value is
recognizable as a webhook secret at a glance. A separate private hashing
helper takes that plaintext and produces its SHA-256 digest via
`:crypto.hash/2`, hex-encoded lowercase the same way via `Base.encode16/2`
— the digest, never the plaintext, is what `insert_changeset/2` receives as
`secret_hash`.

The literal prefix is this design's own choice (distinguishing a
webhook secret from `Letflow.Identity`'s `"lf_tok_"`-prefixed API tokens at a
glance in logs/UI, the same reasoning that gave API tokens their own
prefix) — not otherwise load-bearing; REVIEWER/ELIXIR-DEV may substitute
another literal prefix without it being a design deviation, so long as the
generation/hashing *mechanism* (`:crypto.strong_rand_bytes/1` +
`:crypto.hash(:sha256, _)`, both hex-encoded) stays exactly this one.

**The plaintext is never assigned to any field on this schema, never passed
to `Ecto.Changeset.cast/3`, and no changeset function defined for this
schema accepts a `"secret"`/`"plaintext"` key even if a caller supplied
one** — the same invariant `Letflow.Identity.ApiToken`'s own moduledoc
states for `token_hash` (INV-4 there), restated here for `secret_hash`.

### 2.3 Full field type list (struct/`@type`)

```
@type t :: %__MODULE__{
  id: Ecto.UUID.t(),
  tenant_id: Ecto.UUID.t(),
  target_url: String.t(),
  secret_hash: String.t(),
  description: String.t() | nil,
  event_types: [String.t()],
  status: :ACTIVE | :PAUSED,
  consecutive_failures: non_neg_integer(),
  last_attempt_at: DateTime.t() | nil,
  last_failure_at: DateTime.t() | nil,
  paused_at: DateTime.t() | nil,
  created_at: DateTime.t()
}
```

Note there is deliberately **no `hmac_secret_once` field on this struct at
all** — it is not persisted anywhere, it exists only as a key in `create/2`'s
own return map (§3.1). A `Letflow.Webhooks.Subscription` struct, wherever it
appears (a `create/2` result's `subscription` half, a `list/1` item, an
`update/2` result), never carries a plaintext or an `hmac_secret_once` key —
this is what makes AC2's "list/1 or get never includes the plaintext secret
or an hmac_secret_once key at all" true **by construction**, not by a
serialization-layer filter that could be forgotten at the route layer later.

### 2.4 Changesets

```
@spec insert_changeset(t(), map()) :: Ecto.Changeset.t()
```
Casts `:target_url, :secret_hash, :description, :event_types, :tenant_id,
:created_at` (all caller/context-module-supplied at insert time —
`secret_hash` is computed by the context module before this changeset ever
sees `attrs`, per §3.1; `created_at` is computed by `create/2` via
`current_timestamp()` and must be in this whitelist or `cast/3` silently
drops it, leaving the NOT NULL `created_at` column unset and the insert
failing with a `not_null_violation`). `validate_required/2` on
`:target_url, :secret_hash, :tenant_id, :created_at`.
`status` is **not** cast here — it is fixed at `:ACTIVE` via
`put_change/3` inside the changeset function itself, never accepted from
`attrs`, matching `create/2`'s own "always ACTIVE on creation" rule (§1).
`consecutive_failures` defaults to `0` via the schema's own column default
and this changeset's `put_change/3` (not caller-settable at creation either).

```
@spec status_changeset(t(), map()) :: Ecto.Changeset.t()
```
Casts exactly `:status, :paused_at` — the two columns `update/2`'s
reconciliation (§3.3) ever writes together. `validate_inclusion/3` on
`:status` against the two `Ecto.Enum` values is provided free by
`Ecto.Enum`'s own cast behavior (an unrecognized string fails `cast/3`
outright). Does not touch `:target_url, :description, :event_types` — this
requirement's `update/2` (§3.3) reconciles status only; a future requirement
that lets a caller PATCH `target_url`/`description`/`event_types` would add
its own changeset function, not extend this one silently.

## 3. Context module — `Letflow.Webhooks`

`lib/letflow/webhooks.ex`. Plain Ecto context module, no process — same
shape as `Letflow.Dlq`/`Letflow.Tasks`/`Letflow.Identity`. Every function
takes `opts :: [prefix: String.t()]`, `prefix` always supplied by the caller
(the future REQ-182 route, via `Letflow.Api.Context.scoped_repo_opts/1`) —
this module never itself decides tenant scope, matching every REQ-072+
context module's own "Tenant scoping (INV-1)" precedent, restated verbatim
from `Letflow.Dlq`'s own moduledoc. `tenant_id` is never accepted from
caller-supplied attrs; it is derived from `opts[:prefix]` via
`Letflow.TenantProvisioning.tenant_id_for_schema_name/1`, the same
"derived, never accepted" discipline `Letflow.Dlq.enqueue/2` documents as an
open question and this design resolves the same way for consistency (no
reason for this sibling S6 module to diverge).

```
@type opts :: [prefix: String.t()]
```

### 3.1 `create/2`

```
@type create_attrs :: %{
  required(:target_url) => String.t(),
  optional(:secret) => String.t() | nil,
  optional(:description) => String.t() | nil,
  optional(:event_types) => [String.t()] | nil
}

@spec create(create_attrs(), opts()) ::
  {:ok, %{subscription: Subscription.t(), hmac_secret_once: String.t()}}
  | {:error, Ecto.Changeset.t()}
```

Behavior:
1. Resolve `tenant_id` from `opts[:prefix]` (as above).
2. Determine the plaintext secret: if `attrs[:secret]` is a non-nil,
   non-empty string, use it as the plaintext exactly as supplied (a caller
   may bring their own secret, per `webhooksApi.create`'s `secret?` being
   caller-suppliable); otherwise generate one via
   `generate_webhook_secret_plaintext/0` (§2.2).
3. Hash the plaintext via `hash_webhook_secret/1` (§2.2); this hash — never
   the plaintext — is what is passed into `insert_changeset/2`'s
   `secret_hash` key.
4. Insert a new `Subscription` row with `status: :ACTIVE` (always, not
   caller-settable — `create_attrs()` has no `:status`/`:is_active` key at
   all), `consecutive_failures: 0`, `event_types: attrs[:event_types] || []`,
   `description: attrs[:description]`, `created_at` set to the current UTC
   wall-clock time (second precision), read inside this function.
5. On successful insert, return `{:ok, %{subscription: subscription,
   hmac_secret_once: plaintext}}` — the plaintext appears **only** in this
   one return value, this one time. It is not logged, not re-derivable from
   `subscription` (§2.3's struct has no field for it), and no other function
   in this module ever returns it again (§3.2/§3.3/§3.4/`get/2` below all
   return only `Subscription.t()` values, which structurally cannot carry
   it).
6. On changeset failure (e.g. missing `target_url`), `{:error,
   changeset}` — the attempted insert is rolled back by `Repo.insert/2`
   itself; no plaintext was persisted or leaked in this branch since the
   hash computation happens before the insert attempt and the plaintext is
   simply discarded when the calling function returns an error tuple.

**AC2's two-test requirement, mapped:** (a) "create/2 with no secret supplied
generates one, stores only a hashed form... and returns the plaintext
exactly once as `hmac_secret_once`" — steps 2-5 above, verified by asserting
the DB row's `secret_hash` is the SHA-256 hex digest of the returned
`hmac_secret_once` value, and that they are not equal to each other as
strings. (b) "a subsequent `list/1` or `get` of the same subscription never
includes the plaintext secret or an `hmac_secret_once` key at all" — true by
construction per §2.3 (the struct itself has no such field), verified by
asserting the returned struct's own field list / a `Map.from_struct/1` of it
has no `hmac_secret_once` key and its `secret_hash` value does not equal the
plaintext captured from the `create/2` call.

### 3.2 `list/1`

```
@spec list(opts()) :: {:ok, [Subscription.t()]}
```

**Plain `list/1`, not cursor-paginated** — a deliberate divergence from
`Letflow.Dlq.list/2`'s keyset convention, stated and justified rather than
silently different: `webhooksApi.list()` takes **no query parameters at
all** (`web/src/api/dlq.ts:88-89` — no `cursor`/`page_size`/filter argument
of any kind, unlike `dlqApi`'s own list function), and `WebhookSubscription`
carries no cursor-shaped type analogous to `CursorPage<DlqEntry>` anywhere in
`web/src/types/api.ts`. Mirroring REQ-176's cursor convention here would add
a `cursor`/`page_size` parameter and a `next_cursor` return field that no
consumer of this contract can supply or read — the binding contract itself
(the already-shipped SPA, per this requirement's own "CONTRACT SOURCE" rule)
settles this rather than a stylistic preference. Ordered `created_at DESC`
for a stable, predictable display order (no acceptance criterion requires a
specific order, this is the same "most-recent-first" convention every other
list function in this codebase defaults to absent a stated requirement).

Tenant scoping: one query against the caller's `prefix`, the same
"prefix is the only tenant input" structure `Letflow.Dlq.list/2` and
`Letflow.Routers.Audit` both already establish — no parameter through which
a caller could widen scope past one tenant's own schema. **AC4** ("a
subscription created under tenant A is absent from a `list/1` call scoped to
tenant B") holds structurally: `Repo.all(query, prefix: prefix_b)` executes
against tenant B's own Postgres schema, which never contains tenant A's row
at all (schema-per-tenant, Decision B) — not a `WHERE tenant_id = ...`
filter that could be omitted by mistake.

### 3.3 `update/2` — status/is_active reconciliation

```
@type update_attrs :: %{
  optional(:status) => String.t(),
  optional(:is_active) => boolean()
}

@spec update(id :: String.t(), update_attrs()) :: ...
```

Signature note, matching this module's own `opts` convention used by every
other function here (the same "prose shorthand omits the mandatory
tenant-scoping parameter" note `req176-dlq-core.md` §3.1 makes for
`enqueue/1`): the real arity is 3, not 2.

```
@spec update(id :: String.t(), update_attrs(), opts()) ::
  {:ok, Subscription.t()}
  | {:error, :invalid_id}
  | {:error, :not_found}
  | {:error, :invalid_status}
  | {:error, Ecto.Changeset.t()}
```

**Reconciliation table — the exact mapping this design fixes, per AC3:**

| Caller input | Resulting stored `status` | `paused_at` effect |
|---|---|---|
| `%{status: "ACTIVE"}` | `:ACTIVE` | cleared to `nil` (only if previously non-nil; a no-op update from `ACTIVE` to `ACTIVE` leaves it `nil`) |
| `%{status: "PAUSED"}` | `:PAUSED` | set to the current UTC wall-clock time, read inside this function, **only if the row's current status is not already `:PAUSED`** — a caller pausing an already-paused subscription does not push `paused_at` forward (idempotent re-pause preserves the original pause moment) |
| `%{is_active: true}` | `:ACTIVE` | same clearing rule as `%{status: "ACTIVE"}` |
| `%{is_active: false}` | `:PAUSED` | same setting rule as `%{status: "PAUSED"}` |
| both `:status` and `:is_active` supplied, agreeing (e.g. `%{status: "PAUSED", is_active: false}`) | the one they agree on | as above |
| both supplied, **disagreeing** (e.g. `%{status: "ACTIVE", is_active: false}`) | `{:error, :invalid_status}` — this design does not silently pick one; a caller sending contradictory intent is a caller error, not a resolvable ambiguity | n/a |
| `%{status: <anything other than "ACTIVE"/"PAUSED">}` | `{:error, :invalid_status}` | n/a |
| neither key supplied (empty `update_attrs`) | `{:error, :invalid_status}` — this function's only documented job in this requirement is the status/is_active reconciliation; a no-op call is treated as a caller error rather than silently succeeding with no effect (see §5 open question — a future requirement letting `update/2` also patch `target_url`/`description`/`event_types` would need to revisit this branch) |

Implementation shape: resolve the two inputs to one target atom
(`:ACTIVE`/`:PAUSED`) via a private `reconcile_status/1` step *before*
touching the database, so the transaction below either has a single
unambiguous target or never starts. Then, same lock-then-check-then-write
`Ecto.Multi` idiom `Letflow.Dlq.retry/2`/`discard/2` establish (row-locked
via `SELECT ... FOR UPDATE`, an in-Elixir comparison of current vs. target
status to decide the `paused_at` effect, then a single conditional
`status_changeset/2` update) — reused here even though there is no
concurrent-conflicting-transition state machine as elaborate as DLQ's four
states, because the "read current `paused_at`-relevant state, then decide,
then write" shape is exactly the same hazard class (a bare racing
`UPDATE ... WHERE` could otherwise let two concurrent PAUSE calls both think
they're the first and each stamp a different `paused_at`).

`id`/`not_found` handling mirrors `Letflow.Dlq.get/2` exactly:
`Ecto.UUID.cast/1` first (`{:error, :invalid_id}` on failure, no DB
round-trip), then row-lock-and-fetch scoped to `opts[:prefix]`
(`{:error, :not_found}` when absent — a genuinely nonexistent id and a real
id belonging to a different tenant's schema both resolve through this same
branch, the same structural cross-tenant-404-by-construction mechanism
REQ-072 established).

**AC3's test, mapped:** call `update/2` with `%{status: "PAUSED"}` on one
freshly-created subscription and `%{is_active: false}` on a second, then
assert both subsequently `list/1`-read back (or are re-fetched) with
`status: :PAUSED` and a non-nil `paused_at`.

### 3.4 `delete/2`

```
@spec delete(id :: String.t(), opts()) ::
  {:ok, Subscription.t()}
  | {:error, :invalid_id}
  | {:error, :not_found}
```

Tenant-scoped hard delete (`Repo.delete/2` with `prefix: prefix`) — no soft
delete/tombstone column exists on this schema (§1 names none), and no
acceptance criterion asks for one. `id` validation and not-found handling
mirror `update/2`/`Letflow.Dlq.get/2` exactly: `Ecto.UUID.cast/1` first,
then a scoped fetch; if the row is absent (never existed, already deleted,
or belongs to a different tenant's schema), `{:error, :not_found}` — no row
lock needed here (no read-then-conditionally-write state machine, just
fetch-then-delete), so this one function does **not** need the
`Ecto.Multi`/`lock/3` machinery §3.3 uses.

**AC5's two-part test, mapped:** (a) delete a subscription, then `list/1`
the same tenant and assert the id is absent — holds because the row is
actually gone from the Postgres table, not marked inactive. (b) call
`delete/2` again with the same id: the fetch-before-delete step now finds no
row (it was really removed by the first call), so this returns
`{:error, :not_found}` — structurally impossible to return a "duplicate
success," since there is no row left to re-delete.

### 3.5 `get/2` (private helper, not itself an acceptance-criterion target)

```
@spec get(id :: String.t(), opts()) :: {:ok, Subscription.t()} | {:error, :invalid_id | :not_found}
```

Included because AC2 says "a subsequent `list/1` **or get**" — this module
needs some single-row fetch for `update/2`/`delete/2`'s own not-found
handling and for a future REQ-182 detail route to call. Same shape as
`Letflow.Dlq.get/2`: `Ecto.UUID.cast/1` first, then `Repo.get/3` scoped to
`prefix`. Returns `Subscription.t()`, which per §2.3 structurally never
carries `hmac_secret_once` or a plaintext.

## 4. What this module explicitly does not do (restated from the requirement)

No route, controller, or Plug module (REQ-182). No delivery attempts,
dispatch, outgoing-payload HMAC signing, retry/backoff on delivery failure,
or the `webhooksApi.getDeliveries` endpoint's backing data (REQ-183/184) —
`consecutive_failures`/`last_attempt_at`/`last_failure_at` are reserved
columns this requirement's migration creates and this requirement's
functions never write to (only a future dispatch-subsystem requirement
would), matching the same "reserve the column, write nothing to it yet"
pattern `req176-dlq-core.md` §1 uses for its own `reference_id` column.
`WebhooksManage`'s authorization gating is entirely REQ-182's concern — this
module has no notion of caller identity or permission at all, matching
`Letflow.Dlq`'s own "this module never itself decides tenant scope [or
authorization]" precedent.

## 5. Open questions (not resolved here — for ELIXIR-DEV/REVIEWER)

1. **`updated_at` column.** `WebhookSubscription.updated_at` is optional in
   the frontend type and no acceptance criterion requires this module to
   populate one (§1). This design omits the column entirely rather than add
   one no function writes to. If REQ-182 or a later requirement needs it
   (e.g. to reflect the true last-modified time after `update/2`), that is a
   new migration + `timestamps(inserted_at: false)`-shaped addition made at
   that time, not an oversight here.
2. **Caller-supplied `secret` validation.** `create/2` (§3.1 step 2) accepts
   a caller-supplied plaintext `attrs[:secret]` verbatim with no minimum
   length/entropy check, because no acceptance criterion specifies one and
   `webhooksApi.create`'s own type places no constraint on it either
   (`secret?: string | null`). If a minimum-strength rule is wanted, that is
   a REVIEWER/ELIXIR-DEV decision to add a validation clause to
   `insert_changeset/2`-adjacent logic, not something this design invents.
3. **Empty-`update_attrs` and disagreeing-input behavior (§3.3's last two
   table rows).** This design treats both as `{:error, :invalid_status}`
   rather than a no-op success, since AC3 does not test either case and the
   requirement text does not say what should happen. If a future
   caller genuinely needs a true no-op PATCH (e.g. to update only
   `description` once that capability exists), this error shape would need
   revisiting alongside whatever requirement adds that capability.
4. **Whether `event_types` is validated against a known set.** This design
   stores it as an open `{:array, :string}` with no `Ecto.Enum`-style
   membership check (§0.2) because the requirement text does not name a
   closed set anywhere reachable from this drafting session. If S6's later
   dispatch requirements (REQ-183/184) settle on a fixed event-type
   vocabulary, a validation clause could be added to `insert_changeset/2` at
   that time — not a gap in this requirement's own acceptance criteria.

## 6. Acceptance-criteria coverage checklist

| AC | Design element |
|---|---|
| `webhook_subscriptions` lives in tenant schema, `tenant_id` retained | §1 migration, Decision B guard + column |
| `create/2` generates-or-accepts secret, stores hash only, returns plaintext once as `hmac_secret_once`; `list/1`/`get` never expose it | §3.1 steps 1-6, §2.2 hashing mechanism, §2.3 struct has no such field (structural guarantee) |
| `update/2` reconciles `%{status: "PAUSED"}` and `%{is_active: false}` to the same stored `PAUSED` state | §3.3 reconciliation table |
| `list/1` is tenant-scoped (tenant A absent from tenant B's list) | §3.2, schema-per-tenant structural guarantee |
| `delete/2` hard-deletes; second delete on same id is not-found, not duplicate success | §3.4 |
| no route/controller file added | §0 scope boundary, §4 — this design defines only `lib/letflow/webhooks.ex`, `lib/letflow/webhooks/subscription.ex`, and one migration file |
