# REQ-183 — Webhook delivery dispatch core (HMAC signing, retry/backoff, auto-pause, DLQ landing)

Design for `Letflow.Webhooks.Delivery` (the `webhook_delivery_attempts` table
+ its Ecto schema) and `Letflow.Webhooks.deliver/3`, the dispatch-core half
of the REQ-180 split (REQ-184 is the route-layer half, out of scope here).
Extends the already-shipped `Letflow.Webhooks` context module
(`lib/letflow/webhooks.ex`, REQ-181) and its `Subscription` schema — this
design does not re-derive REQ-181's `create/2`/`list/1`/`update/3`/`delete/2`,
only adds to the same module and its migration.

**R-Co's own `src/webhook/` dispatch implementation is NOT inspectable from
this session.** The HMAC header name/encoding (§6) and the auto-pause
failure threshold (§4) are **Letflow's own choices**, stated explicitly
below, not a port of any R-Co value.

**Scope boundary, restated from the requirement:**
- IN SCOPE: `deliver/3`, the `webhook_delivery_attempts` table/schema,
  retry/backoff up to `max_attempts`, `consecutive_failures` increment,
  auto-pause at the named threshold, DLQ landing on retry exhaustion via
  `Letflow.Dlq.enqueue/2`.
- OUT OF SCOPE, deferred, explicitly not built here:
  (a) the `GET .../deliveries` route (REQ-184) — no route/controller/Plug
      file is added or modified by this design;
  (b) automatically invoking `deliver/3` after every matching domain-event
      append. That is a cross-cutting mechanism (how Letflow hooks a
      post-commit side effect into the event-store append path generically,
      plausibly shared by other future consumers) this requirement does not
      decide unilaterally. `deliver/3` is directly callable and fully
      tested; wiring its automatic trigger is a named, deferred follow-up,
      not silently implemented and not silently forgotten.

## 0. The architectural question: where does the HMAC signing key come from? (resolve before anything else)

**Restating the contradiction this section resolves, not silently assumes
away:** REQ-181's already-shipped `create/2` (`lib/letflow/webhooks.ex`,
read in full for this design) generates a plaintext secret, hashes it via
SHA-256, stores **only the hash** in `secret_hash`, and returns the
plaintext exactly once as `hmac_secret_once`. `Letflow.Webhooks.Subscription`
(read in full) has no field that ever carries a plaintext or a hash-reversal
path — by that schema's own moduledoc, this is structural, not an oversight:
"the plaintext secret is never assigned to any field on this schema."
HMAC-SHA256 requires the actual key **bytes** at signing time — a one-way
hash cannot be un-hashed back into the key material `:crypto.mac/4` needs.
As REQ-181 shipped, **no usable secret representation exists anywhere for
`deliver/3` to sign with.** This is a genuine architectural gap, not a
detail to paper over with an assumption.

**This is resolution (a) from the task framing: the schema/storage changes.**
It is not this design's own invention — it is already decided, with
REVIEWER sign-off, in `docs/migration/decisions/0016-secrets-storage-backend.md`
§F (REQ-189's decision record), and is being implemented by REQ-190 (a
sibling requirement, not this one). This design's job is to state that
resolution precisely enough that `deliver/3` can be specified against it,
and to flag exactly what is and is not yet true in this codebase as of this
design (§0.3).

### 0.1 The chosen resolution: `secret_ref`/`secret_key_id` supersede `secret_hash`, resolved through a new global `Letflow.Secrets` module — not a reversible encryption bolted onto `webhook_subscriptions` itself

Per 0016 §F (quoted precisely, not paraphrased loosely):

- A new, tenant-aware but **globally-stored** Postgres table `secrets`
  (0016 §A/§B — envelope-encrypted: AES-256-GCM over the plaintext under a
  fresh per-write data key, the data key itself wrapped by a second
  AES-256-GCM pass under a master key read once from the environment
  variable `LETFLOW_SECRETS_MASTER_KEY`, which fails application **startup**
  outright if absent, malformed, or a trivially-guessable value like
  all-zeros — 0016 §B) is the durable home for the plaintext HMAC signing
  key. This is reversible (envelope-decryptable) storage, deliberately not
  a one-way hash, because signing needs the actual bytes back — but it is
  **not** "store the plaintext in `webhook_subscriptions` itself, encrypted
  or otherwise." The plaintext lives in exactly one place: the `secrets`
  table, resolvable only through `Letflow.Secrets.resolve/2`'s
  tenant-and-purpose-checked read path (§0.2).
- `webhook_subscriptions` gains two new columns — **`secret_ref`** (an
  unpinned `sec://tenant/<tenant>/webhook/<subscription-id>` reference
  string, 0016 §C) and **`secret_key_id`** (the specific version pinned at
  creation time) — **superseding** the existing `secret_hash` column, which
  is blanked (set to `NULL`, not dropped, matching R-Co's own migration
  shape) once the reconciliation lands. `Subscription.t()` no longer carries
  a plaintext or a hash at all in the sense REQ-181 originally meant by
  `secret_hash` — it carries a *reference*, which is exactly as useless to
  an attacker who only reads `webhook_subscriptions` rows as a hash was,
  since resolving that reference still requires a live call to
  `Letflow.Secrets.resolve/2`, which itself re-checks tenant ownership and
  the caller's declared purpose/consumer identity before ever touching
  ciphertext (§0.2).
- **This is REQ-190's schema change, not this requirement's own migration.**
  This design's own migration (§1) adds only `webhook_delivery_attempts` —
  it does **not** touch `webhook_subscriptions.secret_hash`/`secret_ref`/
  `secret_key_id` at all. `deliver/3` (§3) is written to read
  `subscription.secret_ref` as a field that REQ-190 has already added to
  `Subscription.t()` by the time this design is implemented (§0.3 states
  exactly what that dependency requires to be true first).

### 0.2 Why this does not defeat REQ-181's original security intent

REQ-181's stated intent (`lib/letflow/webhooks.ex` moduledoc, "Secret
handling" section, and its own acceptance criteria) was never "no plaintext
should exist anywhere, ever" — `hmac_secret_once` already commits to
showing the plaintext to the creating caller once, by design, because a
webhook consumer needs to configure its own verifier with that exact value.
The actual invariants REQ-181 protects are: (1) the plaintext is never
returned or listable a **second** time through `Letflow.Webhooks`' own
functions (`list/1`, `get`, a subsequent `create/2` call), and (2) a
`Subscription` struct never carries a field that leaks it. Both invariants
survive this resolution unchanged:

- `list/1`/`get`/`update/3`/`delete/2` still never return a plaintext or a
  `secret_ref`-resolved value — nothing in this design or in 0016/REQ-190
  adds a "reveal the signing key again" function to `Letflow.Webhooks`
  itself. Reading `secret_ref` off a `Subscription` struct gives a caller
  only an opaque reference string — resolving it to plaintext requires a
  **separate**, tenant-and-purpose-checked call to `Letflow.Secrets.resolve/2`
  (0016 §F/REQ-190 §3.2), which independently re-validates that the calling
  tenant matches the reference's own tenant segment and that the calling
  consumer identity (`:webhook_dispatcher`) is permitted to unwrap a
  `:webhook_hmac`-purpose secret — a `webhook_subscriptions` row leaking to
  an unrelated caller (e.g. a cross-tenant bug) no longer directly discloses
  usable key material the way a plaintext column would; it discloses only a
  reference that a *second*, independently-gated system call is required to
  resolve.
- `hmac_secret_once`'s one-time-reveal contract at `create/2` is **unchanged**
  — 0016 §F states this explicitly ("the plaintext is still shown to the
  caller exactly once at creation time; what changes is where it is durably
  stored afterward"). This design does not touch `create/2`'s response
  shape at all (that is REQ-190's change, already specified in
  `lib/letflow/design/req190-secrets-core.md` §5.4, not re-specified here).
- What changes, concretely: **before**, a compromised `webhook_subscriptions`
  row disclosed a SHA-256 hash of the secret (already useless for signing,
  but also useless for an attacker — a hash can't forge a signature
  either). **After**, a compromised row discloses an opaque reference
  string that is *also* useless for signing without a second, gated call —
  the actual security property ("reading this table does not hand you a
  usable signing key") is preserved, not weakened, by moving from
  "irreversible but also unusable to Letflow itself" to "reversible only
  through a narrow, audited, purpose-checked resolution path." The
  trade-off this resolution makes — plaintext becomes recoverable by
  *Letflow's own signing code*, where before it was recoverable by nobody,
  including Letflow — is the unavoidable cost of HMAC needing real key
  material; 0016 §F's own reasoning ("there is no routing-around this
  within REQ-181's schema as drafted; any construction that kept only a
  hash durably stored and still produced a valid HMAC would itself be a
  crypto defect") is restated here because it is the load-bearing argument
  for why this is not a security regression but a correction of an
  originally-unimplementable design.

### 0.3 What is NOT yet true in this codebase, stated explicitly rather than assumed

**As of this design being written, `Letflow.Secrets` does not exist.**
`find lib/letflow -iname '*secret*'` returns nothing in this branch's
working tree. `docs/requirements.yaml`'s REQ-190 entry carries
`status: in_progress` (not `done`), and its own git history
(`WF02-REQ190-20260830 step-03 PARTIAL, rework Step 2a for empty-plaintext
defect`) shows its most recent implementation attempt was sent back for
rework, not merged. **This design is written against REQ-190's own already
-produced, REVIEWER-adjacent design artefact**
(`lib/letflow/design/req190-secrets-core.md`, found on
`origin/feature/WF02-REQ190-20260830`, itself built directly on 0016's
REVIEWER-signed-off decision) — specifically its §3.2 `resolve/2` contract,
reproduced verbatim in §3.2 below — **not against a stub, and not against
guessed function names**, because that real design already fixes the exact
signature. This is legitimate design-time work: 0016 §F is decided and
REVIEWER-signed-off, and REQ-190's own design commits to a concrete,
implementation-ready `resolve/2` contract — the interface this design needs
is settled even though the module's code is not yet merged.

**What this means for build sequencing, stated so it is not silently
skipped:** `docs/requirements.yaml`'s REQ-183 entry itself already records
this as "REWORK 2" — `depends_on: [REQ-181, REQ-176, REQ-189, REQ-190]`,
with build order **REQ-189 → REQ-190 → REQ-183 → REQ-184**, and states
plainly: "deliver/3 calls Letflow.Secrets.resolve/2 against REQ-190's real,
already-shipped module — no stub." **This design (Step 1) is legitimate to
produce now** — it does not itself write or stub any `.ex` code — but
**ELIXIR-DEV's Step 2a implementation of this design must not begin until
REQ-190 actually merges `lib/letflow/secrets.ex` (and the
`webhook_subscriptions.secret_ref`/`secret_key_id` migration/schema change,
§0.1) to this branch's ancestry.** ORCH is expected to hold Step 2a
dispatch on this requirement until REQ-190's own status flips to `done`
(matching the documented `requirement_status` convention) — this design
does not decide that scheduling itself, it states the precondition
explicitly per this project's own "no silent guessing" rule, matching the
identical flag REQ-183's own prior (pre-resequencing) design iteration
raised in its §7 OQ-1 before the resequencing that produced the current
`depends_on` list.

## 1. Migration — `webhook_delivery_attempts`

New migration file, tenant-scoped, following the identical pattern
`20260829010001_create_webhook_subscriptions.exs` and
`20260829000001_create_dlq_entries.exs` already establish: the mandatory
`if prefix() do ... end` guard (Decision B,
`0003-ecto-schema-strategy.md`), registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` (both halves
mandatory, per that module's own established discipline). `id` is the
explicit `:binary_id` primary key (`primary_key: false` on the table,
explicit `add :id, :binary_id, primary_key: true`), same idiom as every
other tenant-scoped table in this codebase.

**This migration does not touch `webhook_subscriptions` at all** — the
`secret_ref`/`secret_key_id`/`secret_hash`-blanking migration is REQ-190's
own (§0.1/§0.3), not this requirement's.

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | — | primary key; this is the table's own row id, distinct from `delivery_id` below |
| `tenant_id` | `:binary_id` | not null | — | intra-schema invariant column, Decision B; not itself the isolation boundary |
| `delivery_id` | `:binary_id` | not null | — | the logical delivery's own identifier — see §1.1. Generated once per `deliver/3` call (one delivery = one or more attempt rows sharing this value, see §3.1) |
| `subscription_id` | `:binary_id` | not null | — | reference to `webhook_subscriptions.id`, **no DB-level `references/2` FK constraint** — matches `dlq_entries.instance_id`'s own "no FK reference" precedent (`req176-dlq-core.md` §1): an attempt row must be able to outlive a deleted subscription (REQ-181's `delete/2` is a hard delete), and no acceptance criterion requires referential integrity here |
| `event_type` | `:string` | not null | — | the domain event type string this delivery carries, e.g. `"INSTANCE_STARTED"` — free-form, matching `dlq_entries.entry_type`'s own "plain `:string`, not `Ecto.Enum`" precedent |
| `status` | `:string` | not null | — | `Ecto.Enum`, closed set `:SUCCESS` \| `:FAILED` (§2.3) — uppercase, matching `webhook_subscriptions.status`'s own uppercase convention (REQ-181 §0.3), since this is the sibling table in the same webhook feature, not `dlq_entries`' lowercase convention |
| `http_status_code` | `:integer` | nullable | — | the response's HTTP status; `nil` for a transport-level failure with no HTTP status at all (connection refused, DNS failure, timeout) |
| `attempted_at` | `:utc_datetime` | not null | — | wall-clock time this specific attempt was made, read inside `deliver/3`, second precision — not `timestamps/1` (an attempt row is immutable once written, matching `dlq_entries`' own explicit-column precedent) |
| `attempt_count` | `:integer` | not null | — | 1-indexed ordinal of this attempt within its `delivery_id` group (1 = first attempt, 2 = first retry, …) |
| `max_attempts` | `:integer` | not null | — | the configured ceiling this delivery was dispatched under (§4) — stored on every row so a row is self-describing without a join back to a delivery-level record that doesn't exist (§1.1) |
| `last_error` | `:text` | nullable | — | populated on `:FAILED` — an HTTP-status-and-response-body summary for a non-2xx response, or the transport exception's message for a connection-level failure; `nil` on `:SUCCESS` |

Indexes, each scoped to the same tenant schema as the table:

- `idx_webhook_delivery_attempts_delivery` on `(delivery_id, attempt_count)`
  — backs REQ-184's future "attempts for one delivery, in order" query and
  this design's own exhaustion check (§3.4 needs "how many attempts exist
  for this `delivery_id` so far").
- `idx_webhook_delivery_attempts_subscription` on `subscription_id` — backs
  REQ-184's future "deliveries for this subscription" query.

No index on `tenant_id` alone, matching every sibling table's precedent
(the Postgres schema is the isolation boundary).

### 1.1 Why `delivery_id` is a column, not the primary key, and why there is no separate `webhook_deliveries` table

The acceptance criteria talk about "a delivery" (singular) landing "exactly
one DLQ entry" after exhausting `max_attempts`, and separately require
"exactly one `webhook_delivery_attempts` row per attempt" — i.e. N rows per
delivery when there are N attempts (1 initial + retries), not one row
overwritten in place. This design models a "delivery" as a **group of
attempt rows sharing one `delivery_id`**, generated fresh by `deliver/3` at
the start of a call (§3.1) — there is no separate `webhook_deliveries`
header table, since no acceptance criterion or requirement-text field list
names one, and every field the requirement asks a "delivery" to carry
(`event_type`, `max_attempts`, the DLQ `reference_id`) is already present on
each attempt row. `reference_id` in REQ-176's DLQ landing (§3.4) is
`delivery_id`, not any individual attempt row's own `id`.

## 2. Ecto schema — `Letflow.Webhooks.Delivery`

`lib/letflow/webhooks/delivery.ex`. Ordinary `Ecto.Schema`
(`@primary_key {:id, :binary_id, autogenerate: true}`), no process — same
plain-CRUD-table shape as `Letflow.Webhooks.Subscription`/`Letflow.Dlq.Entry`.
Every row is written once and never updated — `deliver/3` always inserts a
new row, never updates an existing one.

### 2.1 Full field type list

Field list, one struct field per §1 column: `id`, `tenant_id`,
`delivery_id`, `subscription_id`, `event_type` (`String.t()`), `status`
(`:SUCCESS | :FAILED`), `http_status_code` (`non_neg_integer() | nil`),
`attempted_at` (`DateTime.t()`), `attempt_count` (`pos_integer()`),
`max_attempts` (`pos_integer()`), `last_error` (`String.t() | nil`).

### 2.2 Changeset

`insert_changeset/2 :: (t(), map()) -> Ecto.Changeset.t()`. Casts
`:tenant_id, :delivery_id, :subscription_id, :event_type, :status,
:http_status_code, :attempted_at, :attempt_count, :max_attempts,
:last_error`. `validate_required/2` on everything except
`http_status_code` and `last_error` (both legitimately `nil`, per §1).
No other changeset function exists on this schema — every field is
supplied at insert time by `deliver/3`; there is no partial-update caller.

### 2.3 `status` — `Ecto.Enum`

Closed set `:SUCCESS`, `:FAILED`, stored as the literal uppercase strings
`"SUCCESS"`/`"FAILED"` — the requirement text's own vocabulary verbatim
("classifies the result as `SUCCESS` ... or `FAILED`"), matching
`WebhookDeliveryAttemptStatus` in `web/src/types/api.ts` exactly (`'SUCCESS'
| 'FAILED'`).

### 2.4 Field-by-field match against `WebhookDeliveryAttempt` (`web/src/types/api.ts`, read in full for this design)

| `WebhookDeliveryAttempt` field | Source on this design's `Delivery` row |
|---|---|
| `delivery_id` | `delivery_id` column, verbatim |
| `subscription_id` | `subscription_id` column, verbatim |
| `event_type` | `event_type` column, verbatim |
| `status` | `status` column, verbatim (`'SUCCESS' \| 'FAILED'`) |
| `http_status_code` | `http_status_code` column, verbatim (`number \| null`) |
| `attempted_at` | `attempted_at` column, ISO-8601-serialized by REQ-184's future route (not this requirement's concern — no route exists here) |
| `attempt_count` | `attempt_count` column, verbatim |
| `max_attempts` | `max_attempts` column, verbatim |
| `last_error` | `last_error` column, verbatim (optional/nullable both sides) |

Every field `WebhookDeliveryAttempt` names has a direct column — no field
is synthesized at the route layer beyond straightforward serialization,
which is REQ-184's concern, not this one's.

## 3. Context module additions — `Letflow.Webhooks`

All functions below are added to the **existing** `lib/letflow/webhooks.ex`
(REQ-181's module), not a new module — one context module owns the whole
`webhook_subscriptions` + `webhook_delivery_attempts` feature pair, matching
`Letflow.Dlq` owning its single `dlq_entries` table. `alias
Letflow.Webhooks.Delivery` is added alongside the existing `Subscription`
alias. `alias Letflow.Secrets` is added (REQ-190's module — see §0.3 for
why this alias does not yet resolve to real code and what must be true
before it does).

### 3.1 `deliver/3`

`deliver/3 :: (Subscription.t(), event_type :: String.t(), payload :: map()) -> {:ok, Delivery.t()} | {:error, term()}`

**Real arity 3, matching the requirement text's own `deliver/3(subscription,
event_type, payload)` naming exactly** — unlike REQ-181's/REQ-176's
`opts`-as-last-argument functions, `deliver/3` does **not** take a separate
`opts :: [prefix: ...]` list. Tenant scope for the DB writes it performs is
derived from `subscription.tenant_id` (already present on the `Subscription`
struct passed in) resolved to a `prefix` via
`Letflow.TenantProvisioning.schema_name_for_tenant/1` — **this function
already exists** in `lib/letflow/tenant_provisioning.ex` (`@spec
schema_name_for_tenant(tenant_id :: Ecto.UUID.t()) :: {:ok, schema_name ::
String.t()} | {:error, :invalid_tenant_id}`), so unlike the prior iteration
of this design, this is not an open question — the reverse-derivation
function this call shape needs is already shipped and requires no new
`Letflow.TenantProvisioning` addition.

**Step-by-step behavior:**

1. Generate `delivery_id = Ecto.UUID.generate()` once, at the start of this
   call — every attempt row this call produces shares this one value.
2. Resolve `prefix` from `subscription.tenant_id` via
   `schema_name_for_tenant/1` (above). An `{:error, :invalid_tenant_id}`
   here is a programming-error condition (a `Subscription` struct never
   legitimately carries an invalid `tenant_id` once it has been persisted
   and re-fetched by REQ-181's own code) — `deliver/3` lets this propagate
   as a raised error rather than adding a new `{:error, _}` branch no
   acceptance criterion asks for.
3. **Resolve the signing key** via `Letflow.Secrets.resolve/2` (§3.2 states
   the exact, real contract this call is made against — see §0.3 for what
   must be true in the tree before this line can compile). Call:
   `Letflow.Secrets.resolve(subscription.secret_ref, tenant_id:
   subscription.tenant_id, consumer: :webhook_dispatcher)`. **The
   `consumer: :webhook_dispatcher` option is mandatory on this call, not
   optional** — REQ-190's own purpose/consumer matrix (§3.2 below) permits
   only `:webhook_dispatcher` or an already-`:generic`-purpose secret to
   resolve a non-`:generic` purpose; omitting it defaults to `:generic`,
   which would make this exact call fail against the `:webhook_hmac`-purpose
   secret REQ-190's own reconciliation writes (§0.1) with
   `{:error, :purpose_not_allowed}` — this is stated as a hard requirement
   of this call site, not a style preference, precisely because an earlier
   iteration of this design omitted it and REQ-190's own design (§8 of
   `req190-secrets-core.md`) flagged that omission as a real mismatch.
   - On success: `{:ok, %{plaintext: signing_key, key_id: _key_id, purpose:
     :webhook_hmac}}` — `deliver/3` uses `signing_key` for HMAC computation
     (§6) and does not otherwise inspect `key_id`/`purpose` (no acceptance
     criterion needs them logged or persisted on the `Delivery` row).
   - On any `{:error, reason}` (`:invalid_reference`, `:tenant_mismatch`,
     `:not_found`, `:purpose_not_allowed`, `:disabled`, `:deleted`):
     `deliver/3` returns `{:error, {:key_resolution_failed, reason}}`
     immediately, **without** inserting any `webhook_delivery_attempts` row
     and **without** incrementing `consecutive_failures` — this is a
     configuration/data-integrity failure distinct from a delivery attempt
     actually being made and failing over the network, so it is not itself
     an "attempt" for this table's purposes. Not directly named by any
     acceptance criterion; flagged as an explicit design choice in §7 OQ-2.
4. **Attempt loop**, `attempt_count` from `1` to `max_attempts` (§4),
   stopping early on the first `:SUCCESS`:
   a. JSON-encode `payload` via `Jason.encode!/1` — the exact byte string
      that goes into both the HTTP request body and the HMAC computation
      (§6) must be the same bytes, computed once per attempt (not once per
      `deliver/3` call).
   b. Compute the HMAC-SHA256 signature of the encoded JSON body under the
      resolved `signing_key` (§6).
   c. POST to `subscription.target_url` via the HTTP client (§5), with the
      signature header (§6) and `Content-Type: application/json`.
   d. Classify the outcome (§2.3/§2.4):
      - Any 2xx HTTP status → `:SUCCESS`, `http_status_code` = the actual
        status, `last_error` = `nil`.
      - Any other HTTP status (non-2xx, response actually received) →
        `:FAILED`, `http_status_code` = the actual status, `last_error` =
        a string summarizing the status and (if present) a truncated
        response body.
      - A transport-level error (connection refused, DNS resolution
        failure, timeout, TLS failure — no HTTP response received at all)
        → `:FAILED`, `http_status_code` = `nil`, `last_error` = the
        transport exception's message.
   e. Insert exactly one `webhook_delivery_attempts` row (§1/§2) via
      `Delivery.insert_changeset/2` + `Repo.insert/2`, scoped to `prefix`,
      with this attempt's `delivery_id`, `subscription_id`, `event_type`,
      `status`, `http_status_code`, `attempted_at` (read at the moment of
      this attempt), `attempt_count`, `max_attempts`, `last_error`.
   f. If `:SUCCESS`: return `{:ok, delivery}` immediately (the just-inserted
      row) — no `consecutive_failures` increment (AC1), no further
      attempts, no retry/backoff/DLQ logic runs.
   g. If `:FAILED`:
      - Increment `subscription.consecutive_failures` by 1 (§4) via
        `record_delivery_failure/2` (§3.4).
      - If `attempt_count < max_attempts`: sleep for this attempt's backoff
        duration (§4.2), then continue the loop at `attempt_count + 1`.
      - If `attempt_count == max_attempts` (this was the last configured
        attempt and it also failed): stop the loop, land the delivery in
        the DLQ (§3.5), and return `{:ok, last_delivery}` — **returning
        `{:ok, _}`, not `{:error, _}`, is deliberate**: every attempt was
        correctly persisted, the subscription's failure state was correctly
        updated, and the DLQ landing succeeded — `deliver/3` did its job
        completely even though the underlying HTTP delivery never
        succeeded. A caller distinguishes "delivered" from "exhausted,
        landed in DLQ" by reading the returned `Delivery.t()`'s own
        `status` field (`:FAILED`) combined with `attempt_count ==
        max_attempts`, not by the `{:ok, _} | {:error, _}` tag — mirroring
        `Letflow.Dlq.retry/2`'s own precedent of `{:ok, entry}` on every
        state-machine-legal outcome.

**AC1 mapped:** "`deliver/3` against 200 persists one SUCCESS row, no
`consecutive_failures` increment" — step 4.f, single-iteration loop exit.

**AC2 mapped:** "`deliver/3` against 500, and separately connection-refused,
both persist FAILED rows with `last_error` populated (500 for the first,
`nil` `http_status_code` for the second)" — step 4.d's two `:FAILED`
branches; two explicit test cases, each satisfiable with `max_attempts`
configured to 1 for that test (so the single row inserted is directly the
row under test), or by reading back `attempt_count: 1` from a
multi-attempt scenario.

### 3.2 Signing-key resolution contract — `Letflow.Secrets.resolve/2` (real contract, per `req190-secrets-core.md` §3.2)

```
resolve(reference :: String.t(),
        opts :: [tenant_id: Ecto.UUID.t(), consumer: :webhook_dispatcher | :generic]) ::
  {:ok, %{plaintext: binary(), key_id: pos_integer(), purpose: :webhook_hmac | :generic}}
  | {:error, :invalid_reference}
  | {:error, :tenant_mismatch}
  | {:error, :not_found}
  | {:error, :purpose_not_allowed}
  | {:error, :disabled}
  | {:error, :deleted}
```

This is **not a guess** — it is REQ-190's own committed design contract
(`lib/letflow/design/req190-secrets-core.md` §3.2, built against 0016's
REVIEWER-signed-off decision), reproduced here verbatim rather than
re-derived, per §0.3's framing: this design does not stub or invent this
function's shape, it depends on REQ-190's already-fixed one. `deliver/3`
calls it with the **unpinned** `subscription.secret_ref` (0016 §C: an
unpinned reference resolves to "the newest version whose `status =
active`"), never `secret_key_id` pinned — signing a new outgoing delivery
should use the current active key, not a historical one; pinning is for a
verifier checking an old signature after rotation (0016 §E's grace-window
use case), not this function's concern.

**`opts[:tenant_id]` and `opts[:consumer]` are both required at this call
site** (§3.1 step 3) — `consumer: :webhook_dispatcher` specifically, since
omitting it defaults to `:generic` and would fail the purpose/consumer
matrix against the `:webhook_hmac`-purpose secret REQ-190's reconciliation
writes (§0.1).

**This assumes `Subscription.t()` carries a `secret_ref` field by the time
this code is built** — a REQ-190 schema change to REQ-181's `Subscription`
(§0.1/§0.3), not something this design's own migration (§1) adds.

### 3.3 HMAC signing — header name, encoding: Letflow's own choice

**Header:** `X-Letflow-Signature`
**Value format:** `sha256=<hex>` — the literal ASCII string `"sha256="`
followed by the lowercase-hex-encoded HMAC-SHA256 digest, e.g.
`X-Letflow-Signature: sha256=5d41402abc4b2a76b9719d911017c592...`.

**Computation:** `:crypto.mac(:hmac, :sha256, signing_key, json_body)`,
hex-encoded via `Base.encode16(case: :lower)` — `signing_key` is the
`plaintext` field of `Letflow.Secrets.resolve/2`'s success map (§3.2),
`json_body` is the exact `Jason.encode!/1` byte string sent as the request
body (§3.1 step 4.a — computed from the same bytes, not re-serialized
separately, so a verifier re-encoding the same map could theoretically
diverge on key ordering; a real verifier must sign/verify the raw bytes
actually transmitted, not re-derive them from a decoded structure).

**This is Letflow's own choice**, explicitly not a port of any R-Co
header/format (R-Co's `src/webhook/` is unreachable from this session) —
the moduledoc for `Letflow.Webhooks` must state this plainly, per the
requirement's own acceptance criterion.

**AC3 mapped ("signature is independently verifiable"):** a test resolves
the same subscription's signing key through the same `Letflow.Secrets.resolve/2`
mechanism `deliver/3` itself calls (same reference, same `tenant_id`, same
`consumer: :webhook_dispatcher`), computes
`:crypto.mac(:hmac, :sha256, key, expected_json_body)` independently, and
asserts it equals the hex digest inside the `X-Letflow-Signature` header
value the mock HTTP endpoint under test actually received — "the test and
the signer obtain the key the same way, which is what makes this criterion
satisfiable at all," quoting the acceptance criterion directly.

### 3.4 `consecutive_failures` increment + auto-pause (shared write path)

Not a new public function — this is the private write path step 4.g of
`deliver/3` calls, specified here on its own because it is the mechanism
behind AC4.

`record_delivery_failure/2 :: (Subscription.t(), prefix :: String.t()) -> Subscription.t()`

(private `defp`, returns the updated struct rather than a tagged tuple —
a DB error here is a genuine crash, not a `{:error, _}` `deliver/3` should
recover from; flagged as a design choice rather than asserted with full
confidence, see §7 OQ-3)

Mechanics: same row-locked (`SELECT ... FOR UPDATE`) then in-Elixir-decide
then conditional-write shape as REQ-181's `update/3` (`req181-webhooks-core.md`
§3.3) — reused because this is the identical hazard class (two concurrent
failing deliveries for the same subscription must not both read
`consecutive_failures = 4`, both increment to `5`, and only one "win" the
auto-pause transition while losing a count). Inside one `Ecto.Multi`:

1. Lock and re-fetch the subscription row by `id`.
2. `new_count = locked.consecutive_failures + 1`.
3. `last_failure_at` set to the current UTC wall-clock time (read inside
   this step).
4. If `new_count >= @auto_pause_threshold` (§4.1) **and** `locked.status !=
   :PAUSED`: write `consecutive_failures: new_count, last_failure_at: ...,
   status: :PAUSED, paused_at: <now>` in one update — via a new
   `failure_changeset/2` (§3.4.1) since REQ-181's existing
   `status_changeset/2` does not cast `consecutive_failures`/
   `last_failure_at`, and REQ-181's own design explicitly reserved those two
   columns as "this requirement's functions never write to."
5. Otherwise (threshold not reached, or already `:PAUSED`): write only
   `consecutive_failures: new_count, last_failure_at: ...` via
   `failure_changeset/2` — the already-`:PAUSED` case does not re-stamp
   `paused_at` (idempotent, same reasoning REQ-181's `update/3` already
   applies to a repeated `%{status: "PAUSED"}` call).

**3.4.1 `Subscription.failure_changeset/2`** (new function added to
`lib/letflow/webhooks/subscription.ex` by this design):
`failure_changeset/2 :: (t(), map()) -> Ecto.Changeset.t()`. Casts
`:consecutive_failures, :last_failure_at, :status, :paused_at` —
`validate_required/2` on `:consecutive_failures, :last_failure_at`. This is
the first writer of `consecutive_failures`/`last_failure_at` since REQ-181's
insert defaulted `consecutive_failures` to `0` and never wrote
`last_failure_at` at all.

**AC4 mapped:** "`consecutive_failures` reaching the threshold flips status
to PAUSED and sets `paused_at`" — step 4 above, driven by repeated
`deliver/3` calls against a subscription whose failures accumulate. Every
failed attempt increments once (not once per `deliver/3` call), so a single
`deliver/3` call whose `max_attempts` already exceeds the threshold can
auto-pause the subscription within one call — this is intentional: "5
consecutive failures" means five failed delivery attempts in a row,
regardless of whether they span one `deliver/3` call or several.

### 3.5 DLQ landing on retry exhaustion

Not a new public function — this is step 4.g's final branch (attempt
exhausted) inside `deliver/3`. Calls the **already-shipped**
`Letflow.Dlq.enqueue/2` (verified real arity 2 by reading `lib/letflow/dlq.ex`
in full for this design — the handoff's own alternative-arity hedge,
"enqueue/2 or enqueue/1," is resolved here: it is `enqueue/2`, taking
`attrs :: map()` and `opts :: [prefix: String.t()]`):

Call shape: `Letflow.Dlq.enqueue(%{entry_type: "webhook", reference_id:
delivery_id, reason: "webhook delivery exhausted max_attempts",
source_payload: payload, context_json: %{subscription_id:
subscription.id, target_url: subscription.target_url, event_type:
event_type, attempt_count: max_attempts}, last_failed_at: <the final
attempt's attempted_at>}, prefix: prefix)`.

- `entry_type: "webhook"` — the requirement's own literal string, matching
  `Letflow.Dlq.Entry.entry_type`'s documented open-set column (`"event"` |
  `"timer"` | `"webhook"` today, per `req176-dlq-core.md` §1).
- `reference_id: delivery_id` — the delivery's **own** `delivery_id`
  (§1.1), not any individual attempt row's `id`, and specifically **not**
  `instance_id`. `Letflow.Dlq.Entry`'s schema (read in full for this
  design) carries both columns as independent, optional fields —
  `instance_id :: Ecto.UUID.t() | nil` and `reference_id :: String.t() |
  nil` — exactly so a non-instance-originated entry (this one) can populate
  `reference_id` while leaving `instance_id` `nil`, which this call does:
  `instance_id` is omitted entirely (defaults to `nil` per `enqueue/2`'s
  own `enqueue_attrs()` optionality), since a webhook delivery has no
  originating `instance_projections` row by construction (deferred trigger
  wiring, §0(b) restated below — even once wired, a webhook subscription is
  not itself an instance).
- One `enqueue/2` call per exhausted delivery — never more than one, since
  this branch runs exactly once per `deliver/3` invocation (the loop exits
  immediately after this call).

**AC5 mapped:** "a delivery exhausting `max_attempts` lands exactly one DLQ
entry with `entry_type: "webhook"` and `reference_id` = the delivery's own
`delivery_id`" — the single `enqueue/2` call above, read back from
`dlq_entries` by the test.

## 4. Auto-pause threshold and backoff — Letflow's own choices

**Neither value below is ported from R-Co — R-Co's `src/webhook/` dispatch
code is not inspectable from this session.** Both are stated here as
Letflow's own choices, per the requirement's explicit instruction, and both
must be named the same way in the eventual moduledoc.

### 4.1 Auto-pause threshold: `5` consecutive failures

`@auto_pause_threshold 5` (module attribute on `Letflow.Webhooks`). Chosen
as a round, conservative number that tolerates a brief target-side blip (a
couple of failed deliveries during a deploy/restart on the receiving end)
without pausing, while still catching a genuinely dead endpoint within a
handful of delivery attempts rather than silently accumulating failures
indefinitely. This is a **Letflow-authored default**, not a port — REVIEWER
or a later requirement may adjust it. Not currently per-tenant-configurable
(no requirement text or acceptance criterion asks for that); see §7 OQ-4.

### 4.2 Backoff scheme: exponential, base 2 seconds, capped at 4 attempts total

`@max_attempts 4` (default, module attribute — see §7 OQ-5 for whether this
is meant to be per-subscription-configurable). Backoff between attempt `n`
and attempt `n+1`: `:timer.seconds(2 ** (n - 1))` — i.e. 1s after attempt 1,
2s after attempt 2, 4s after attempt 3 (no backoff needed after attempt 4).
Chosen as a standard exponential-backoff shape (doubling, small base)
rather than any R-Co value.

**Test-suite consequence, flagged explicitly:** a test exercising the full
retry-to-exhaustion path with real sleep-equivalent backoff would take
`1 + 2 + 4 = 7` real seconds. §7 OQ-6 flags this for TEST-DESIGNER: this
design recommends `deliver/3`'s backoff step be a separately callable
private function (`defp backoff_delay_ms(attempt_count)`) so a test can
either inject a near-zero backoff via an application-env-configurable
backoff base (checked/established at implementation time — no existing
precedent for "configurable sleep duration for tests" was found elsewhere
in this codebase) or assert the delay computation directly without
sleeping through it.

## 5. HTTP client — no existing dependency, this design's own choice

**`mix.exs` contains no HTTP client library today** — checked directly
(`grep -n "{:" mix.exs`, plus a grep for `Finch\.`/`HTTPoison\.`/`Req\.` use
sites across `lib/`): neither `Req`, `Finch`, `HTTPoison`, `Tesla`, nor a
bare `Mint` dependency exists anywhere in this project (the two hits for
"Req." in `lib/letflow/engine/transition.ex` and its design doc are
comments *ruling out* an HTTP call inside the transition kernel, not a
client usage). This requirement is the first to need one.

**This design chooses Erlang/OTP's built-in `:httpc`** (via `:inets`,
already part of the OTP standard library — no new `mix.exs` dependency, no
`mix deps.get` network fetch required to build this requirement), over
adding a new hex dependency (`Req` would be the obvious modern choice).
Reasoning: `:httpc` is available with zero new dependencies. **Flagged as an
open question for REVIEWER, not silently decided as final** — see §7 OQ-7:
if REVIEWER prefers adding `{:req, "~> 0.5"}` for this and future
outbound-HTTP needs (this is the *first* place Letflow makes an outbound
HTTP call to an external system), this design's step 4.c changes to a
`Req.post/2` call with an equivalent options shape; nothing else in this
design changes. `extra_applications: [:logger]` in `mix.exs` would need
`:inets` and `:ssl` added if `:httpc` is kept (`:httpc.request/4` requires
`:inets` and `:ssl` started, neither currently listed).

Call shape assumed either way, for §3.1 step 4.c:
- Method: `POST`
- URL: `subscription.target_url`, used verbatim (no validation/allowlist
  logic — REQ-181's `create/2` already accepts `target_url` with no format
  constraint beyond `validate_required/2`, and no acceptance criterion here
  asks for SSRF-style target validation; flagged as a security-relevant gap
  for SECURITY-REVIEWER's own judgment at Step 2c, not resolved by this
  design — see §7 OQ-8)
- Headers: `Content-Type: application/json`, plus the signature header (§3.3)
- Body: the exact `Jason.encode!/1` byte string computed in step 4.a
- Timeout: bounded (this design proposes 10 seconds; not load-bearing on
  any acceptance criterion, ELIXIR-DEV may adjust) — a hung connection must
  not block the calling process indefinitely.
- A non-2xx response and a transport-level error/timeout are the two
  outcomes step 4.d already classifies; a timeout specifically is treated
  as the transport-error branch (`http_status_code: nil`), since no
  response was received.

## 6. What this design explicitly does not do (restated from the requirement)

No route, controller, or Plug module — REQ-184's `GET .../deliveries` route
is entirely out of scope; this design defines only
`lib/letflow/webhooks/delivery.ex`, additions to the existing
`lib/letflow/webhooks.ex` and `lib/letflow/webhooks/subscription.ex`
(`failure_changeset/2` only — no field addition, since `secret_ref` is
REQ-190's field to add), and one migration file
(`webhook_delivery_attempts` only).

**Automatic triggering of `deliver/3` after every matching domain-event
append is explicitly OUT OF SCOPE and a deferred follow-up** — not silently
implemented, not silently forgotten. It requires a generic post-commit hook
mechanism (how Letflow hooks a side effect into the event-store append path
generically, plausibly shared by other future consumers) that this
requirement should not decide unilaterally as a side effect of building
webhook delivery. `deliver/3` is built, tested, and directly callable by
any future caller (a route handler, a background worker, a future
event-append hook) — wiring its automatic trigger is left for a future
requirement to scope deliberately.

No change to REQ-181's `create/2`/`list/1`/`update/3`/`delete/2` behavior
beyond what REQ-190 itself specifies (§0.1) — this design does not
duplicate or re-decide any part of REQ-190's own scope.

## 7. Open questions (not silently resolved — for ELIXIR-DEV/REVIEWER/ORCH)

1. **Build sequencing on REQ-190 (restated from §0.3, the most important
   open item here).** `Letflow.Secrets` does not exist in this tree as of
   this design. ORCH must not dispatch this design's ELIXIR-DEV
   implementation step until REQ-190's own status is `done` and its module
   is merged into this branch's ancestry — this design commits to REQ-190's
   real, already-designed `resolve/2` contract (§3.2) specifically so that
   when that day comes, the diff is "write the code this design already
   specifies," not "guess again."
2. **Whether a key-resolution failure (§3.1 step 3) should itself count as
   a `:FAILED` attempt row / increment `consecutive_failures`.** This
   design says no (a distinct, earlier failure mode that never reaches the
   HTTP call at all) because no acceptance criterion names this case. If
   ELIXIR-DEV/REVIEWER judge that a subscription whose secret was disabled/
   deleted out from under it should still count toward auto-pause, that is
   a deliberate change to make at build time, not an oversight here.
3. **Whether `record_delivery_failure/2`'s internal write failure should be
   `Repo.update!` (crash) or return a threaded `{:error, _}` up through
   `deliver/3`.** This design leans toward `update!` but does not assert
   this with full confidence — flagged for REVIEWER's judgment at Step
   2c/2d.
4. **Whether `@auto_pause_threshold` (5) should be per-tenant/per-
   subscription configurable rather than a global module attribute.** No
   acceptance criterion or requirement text asks for configurability; this
   design picks the simplest global-constant shape.
5. **Whether `@max_attempts` (4) should be per-subscription configurable
   (a column on `webhook_subscriptions`) rather than a global module
   attribute.** The requirement text says "retries with backoff up to a
   configured `max_attempts`" without stating where the configuration
   lives. This design defaults to a single global module attribute; adding
   a per-subscription column is a migration this requirement's own scope
   does not obviously include, and no existing column reserves one.
6. **Backoff duration and test runtime (§4.2).** Flagged for
   TEST-DESIGNER: no existing precedent in this codebase for injecting a
   shorter sleep duration under test.
7. **`:httpc` vs. adding `Req` as a new dependency (§5).** This design
   defaults to `:httpc` (zero new dependencies) but explicitly does not
   treat this as final — REVIEWER should weigh in given this is the
   project's first outbound-HTTP-call requirement.
8. **SSRF-style target-URL validation.** Not addressed by this design at
   all (§5) — `target_url` is used verbatim from REQ-181's already-created
   subscription, with no scheme/host allowlist or private-IP-range
   rejection. Flagged for SECURITY-REVIEWER's own judgment at Step 2c.

## 8. Acceptance-criteria coverage checklist

| AC | Design element |
|---|---|
| 200 → one SUCCESS row, no `consecutive_failures` increment | §3.1 step 4.f |
| 500 and connection-refused → FAILED rows, `last_error` populated, `http_status_code` 500 / `nil` respectively | §3.1 step 4.d, two explicit test cases |
| Signature independently verifiable via the same key-resolution mechanism | §3.3, §3.2 |
| `consecutive_failures` reaching threshold (5) flips `PAUSED` + `paused_at` | §3.4, §4.1 |
| Exhausting `max_attempts` lands exactly one DLQ entry, `entry_type: "webhook"`, `reference_id = delivery_id` | §3.5 |
| Moduledoc names HMAC header/format + PAUSED threshold as Letflow's own choices, names auto-trigger as deferred | §3.3 (header), §4.1 (threshold), §6 (deferred trigger) — to be transcribed into the actual moduledoc at implementation time |
| No route/controller file touched | §0 scope boundary, §6 |
| The architectural question (plaintext-for-HMAC) is resolved, not assumed | §0 in full |
