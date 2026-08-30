# REQ-190 — Secrets core: envelope-encrypted per-tenant secret storage and resolution by reference

Design for `Letflow.Secrets` (the global `secrets` table + its Ecto schema),
`Letflow.Secrets.Redaction` (log redaction), and the webhook HMAC key
reconciliation on `webhook_subscriptions` (adds `secret_ref`/`secret_key_id`,
retires `secret_hash`). Builds exactly what
`docs/migration/decisions/0016-secrets-storage-backend.md` (§A–§F, REVIEWER
sign-off GRANTED 2026-08-30) specifies — this design does not re-derive or
re-litigate any of 0016's decisions, it maps them to concrete Elixir/Ecto
shapes.

**Scope boundary, restated from the requirement:** core only — no route, no
controller (that is REQ-191, not REQ-192; confirmed against the current
`docs/requirements.yaml` text), no secrets admin UI, no OIDC client-secret
rotation.

**Resequencing note (read before anything else).** This requirement was
moved ahead of REQ-183 (webhook delivery dispatch) specifically so REQ-183
has a real `resolve/2` to build against. REQ-183 does not exist yet in this
tree, but a preserved design artefact on the paused
`feature/WF02-REQ183-20260830` branch
(`lib/letflow/design/req183-webhook-delivery-dispatch.md` at that branch,
read via `git show`) already specifies the exact contract it assumes:

```
@spec Letflow.Secrets.resolve(reference :: String.t(), opts :: [tenant_id: Ecto.UUID.t()]) ::
  {:ok, plaintext :: binary()} | {:error, term()}
```

**§3.2 below adopts this signature verbatim** — see §8 "Contract
reconciliation with REQ-183" for the point-by-point comparison and the one
deliberate refinement (the error-tuple shapes, which REQ-183's design left
as a bare `term()` and this design makes concrete without breaking that
contract's `{:error, term()}` compatibility).

---

## 0. Cross-module dependency map

- `Letflow.Secrets` (this design) — new module, `lib/letflow/secrets.ex`.
- `Letflow.Secrets.Secret` — new Ecto schema, `lib/letflow/secrets/secret.ex`.
- `Letflow.Secrets.Redaction` — new module, `lib/letflow/secrets/redaction.ex`.
- `Letflow.Webhooks` (REQ-181, existing) — `create/2` is changed to write the
  plaintext HMAC key through `Letflow.Secrets.put/2` instead of hashing it,
  and `Letflow.Webhooks.Subscription` gains `secret_ref`/`secret_key_id`
  fields, losing `secret_hash`. No other REQ-181 function
  (`list/1`/`update/3`/`delete/2`) changes.
- `Letflow.TenantProvisioning` (existing) — `tenant_id_for_schema_name/1` is
  reused by `Letflow.Webhooks.create/2` exactly as today; `Letflow.Secrets`
  itself never resolves a `prefix`, since the `secrets` table is global (0016
  §B) and every `Letflow.Secrets` function takes `tenant_id` directly, never
  `opts: [prefix: ...]`. This is a deliberate, stated divergence from every
  other tenant-scoped context module's `opts()` convention in this codebase
  — see §3.0.
- `Logger` (stdlib) — configured with a custom formatter/filter per §6, so
  `Letflow.Secrets.Redaction.redact_map/1` (or equivalent) is invoked on
  structured log metadata before it reaches any backend.
- REQ-183 (not built yet) — the sole external consumer of `resolve/2` this
  design is written to unblock. Nothing in `lib/letflow/webhooks.ex` beyond
  `create/2`'s secret-handling calls into `Letflow.Secrets` from this
  requirement; `deliver/3` (REQ-183) is a future caller, not built here.

---

## 1. Schema — `secrets` table (global, `public`, per 0016 §A/§B)

**Placement:** `public` schema, NOT tenant-scoped — this is the
REVIEWER-sign-off-gated exception 0016 §B establishes and this design
follows verbatim. The migration is a plain (non-tenant-scoped) migration,
i.e. it does **not** carry the `if prefix() do ... end` guard every
tenant-scoped migration in this codebase uses (see
`20260829010001_create_webhook_subscriptions.exs`'s header for that guard's
normal shape) and it is **not** registered in
`Letflow.TenantProvisioning.tenant_scoped_migrations/0` — it runs exactly
once against `public`, the same way `20260819000004_drop_legacy_public_identity_tables.exs`
(referenced in that manifest's own comment as "deliberately NOT listed
here -- it is a global-schema migration") already establishes as this
project's precedent for a global-schema migration.

### 1.1 Columns

| Column | Type | Null | Default | Notes |
|---|---|---|---|---|
| `id` | `:binary_id` | not null | — | primary key; explicit `:binary_id`, `primary_key: true`, matching every other table's idiom in this codebase (`webhook_subscriptions.id`, `dlq_entries.id`) — this is the row's own PK, distinct from `key_id` below |
| `tenant_id` | `:binary_id` | not null | — | the owning tenant's id (`Letflow.TenantProvisioning.Registration.tenant_id`'s FK target type) — NOT the isolation boundary by itself (0016 §B: the boundary is `resolve/2`'s explicit `caller_tenant == reference_tenant` check, run before any query) |
| `namespace` | `:string` | not null | — | `[a-z0-9_-]` lowercase, e.g. `"webhook"`, `"oidc"`, `"plugin"` (0016 §C) — validated at the changeset layer, not DB-constrained beyond `:string` |
| `name` | `:string` | not null | — | `[a-z0-9_-]` lowercase, the secret's name within `namespace` |
| `key_id` | `:integer` | not null | — | per-version identifier within `(tenant_id, namespace, name)` — see §1.3 for how it is assigned; NOT a UUID, since the reference syntax's `#<key_id>` segment (0016 §C) is rendered as a short human-typeable integer, matching R-Co's own schema shape (0016 Evidence: `UNIQUE (tenant_id, namespace, name, key_id)`) |
| `purpose` | `:string` | not null | — | `Ecto.Enum`-backed at the schema layer (see §1.4 on why a closed set is used here despite the column being `:string` — mirrors `webhook_subscriptions.status`'s own "Ecto.Enum over a string column" idiom) — closed set defined in §1.4 |
| `status` | `:string` | not null | `"active"` | `Ecto.Enum`, closed set `:active \| :disabled \| :deleted` (0016 §E) — **lowercase**, matching `dlq_entries.status`'s lowercase convention, not `webhook_subscriptions.status`'s uppercase one, since this table has no prior convention of its own to match and lowercase is the more common convention across this codebase's tables generally |
| `algorithm` | `:string` | not null | — | `Ecto.Enum`, closed set — see §1.4. Stores `"aes_256_gcm"` for every row this design ever writes (0016 §D) |
| `wrapped_key_algorithm` | `:string` | not null | — | `Ecto.Enum`, closed set — see §1.4. Stores `"aes_256_gcm"` for every row this design ever writes (0016 §D's corrected metadata — the direct fix for R-Co's defect (b): this design's `put/2` never writes `"aes_kw_256"`, and the schema's own closed enum makes writing that value a compile-time-impossible `Ecto.Changeset` cast error, not just a documentation promise) |
| `ciphertext` | `:binary` | not null | — | AES-256-GCM ciphertext of the plaintext secret value under the per-version data key (0016 §D) — never the plaintext |
| `wrapped_data_key` | `:binary` | not null | — | the 32-byte data key, itself AES-256-GCM-encrypted under `LETFLOW_SECRETS_MASTER_KEY` (0016 §D's "second AES-256-GCM pass") |
| `nonce` | `:binary` | not null | — | the 12-byte nonce used for the **payload** encryption (`ciphertext`'s own nonce) — distinct from the key-wrap nonce below |
| `wrap_nonce` | `:binary` | not null | — | the 12-byte nonce used for the **key-wrap** encryption (`wrapped_data_key`'s own nonce) — **not named in 0016's column list verbatim** (0016 §D says "its own fresh 96-bit nonce, stored as `wrapped_data_key`/its own nonce field, distinct from the payload's nonce" without naming the column) — flagged explicitly as a naming decision this design makes, see §9 OQ-1 |
| `auth_tag` | `:binary` | not null | — | GCM's 128-bit tag for the **payload** encryption. Per 0016 §D ("Authentication tag: GCM's 128-bit tag, stored in `auth_tag`, for both the payload encryption and (separately) the key-wrap encryption") two tags exist; see `wrap_auth_tag` below for the second, same naming-gap flagged in §9 OQ-1 |
| `wrap_auth_tag` | `:binary` | not null | — | GCM's 128-bit tag for the **key-wrap** encryption — see `wrap_nonce` above, same naming rationale |
| `aad` | `:binary` | not null | — | the exact AAD bytes used for the payload's GCM authentication: `"{tenant_id}:{namespace}:{name}:{purpose}"` (0016 §D) — stored so `resolve/2` reconstructs and verifies it deterministically rather than re-deriving it purely from other columns at read time (defends against a future column rename silently breaking decryption without an explicit failure) |
| `wrapping_key_ref` | `:string` | not null | — | identifies *which* master key wrapped this row's data key — see §1.2 for what value this design writes now (single-master-key era) and how it supports future rotation without a schema change |
| `wrapping_key_version` | `:integer` | not null | `1` | companion to `wrapping_key_ref` — see §1.2 |
| `created_at` | `:utc_datetime` | not null | — | explicit column, not `timestamps/1` — matches `webhook_subscriptions.created_at`'s own precedent (no acceptance criterion needs `updated_at`, and a secret row is immutable once written, same "no update, only insert-new-version" idiom `webhook_delivery_attempts` will use) |
| `created_by` | `:string` | not null | — | the identifier of the actor that created this version (a user id, or a system/context-module identifier for a machine-originated secret like the webhook HMAC key) — **never overwritten**, including by `disable/2` (this is the explicit fix for R-Co's `disableSecretVersion` defect the requirement text names) |
| `disabled_at` | `:utc_datetime` | nullable | `nil` | set by `disable/2`, alongside `status: :disabled` |
| `deleted_at` | `:utc_datetime` | nullable | `nil` | reserved for a future hard/soft-delete path — **no function in this design's scope writes this column**; `status: :deleted` and `deleted_at` both exist in the schema (0016 §A's column list requires them) but no public function transitions a row to `:deleted` in REQ-190. Flagged explicitly, see §9 OQ-2 |

Primary key: `id` (`:binary_id`). Unique constraint:
**`UNIQUE (tenant_id, namespace, name, key_id)`** (0016 §A, verbatim).

### 1.2 `wrapping_key_ref` / `wrapping_key_version` — what this design writes now

REQ-190 supports exactly one master key at a time (`LETFLOW_SECRETS_MASTER_KEY`,
§2). `wrapping_key_ref` is written as the literal string `"env:LETFLOW_SECRETS_MASTER_KEY"`
for every row `put/2` creates — naming *where* the wrapping key came from,
not its value (the value never appears in any column). `wrapping_key_version`
is written as `1` for every row. Neither column is read or branched on by
`resolve/2` in this design — they exist so a **future** master-key-rotation
mechanism (out of scope, per 0016 Consequences: "fronting `LETFLOW_SECRETS_MASTER_KEY`
with a real KMS/HSM later ... is out of scope now") has a place to record
which key wrapped which row, without a later migration. Unwrapping in this
design always uses the single currently-configured `LETFLOW_SECRETS_MASTER_KEY`
regardless of what these two columns say — see §9 OQ-3 for the explicit
statement that these columns are write-only/inert in REQ-190's own scope.

### 1.3 `key_id` assignment

`key_id` is a **per-`(tenant_id, namespace, name)` monotonically increasing
integer**, starting at `1`. `put/2` computes the next `key_id` as
`COALESCE(MAX(key_id), 0) + 1` scoped to `(tenant_id, namespace, name)`,
inside the same transaction as the insert (row-level serialization handled
by the unique constraint: a concurrent double-write racing on the same
computed `key_id` fails the unique constraint and is retried once — see
§3.1 step 5).

### 1.4 Closed enums

- `purpose` — `Ecto.Enum`, values: `[:webhook_hmac, :generic]`. Only these
  two values are needed by REQ-190/REQ-183's own scope (0016 §F's
  `purpose: "webhook_hmac"`, and 0016 §C's `<namespace>` examples naming
  `oidc`/`plugin` as *future* namespaces that do not yet need their own
  `purpose` value — a namespace and a purpose are different axes: `oidc`
  secrets, when they exist, may still resolve under `purpose: :generic`
  until a dedicated purpose is needed). Adding a new purpose value later is
  an additive `Ecto.Enum` change, not a redesign.
- `status` — `Ecto.Enum`, values: `[:active, :disabled, :deleted]` (0016 §E).
- `algorithm` — `Ecto.Enum`, values: `[:aes_256_gcm]`. A single-value closed
  enum is deliberate, not premature: it makes "claims a cipher this code
  doesn't run" (0016 defect (b)) a compile-time-impossible `Ecto.Changeset`
  error rather than a documentation promise, per REVIEWER's own sign-off
  note flagging this exact type-safety gap.
- `wrapped_key_algorithm` — `Ecto.Enum`, values: `[:aes_256_gcm]`. Same
  rationale. 0016's own Decision text states a genuine future AES-KW value
  would be "a new, distinct `wrapped_key_algorithm` value introduced
  alongside the old one" — this design's closed enum is exactly what makes
  that addition an explicit, reviewable schema change instead of a silent
  string value drifting in.

### 1.5 Indexes

- The unique constraint `UNIQUE (tenant_id, namespace, name, key_id)` itself
  serves as the primary lookup index for both `put/2`'s next-`key_id`
  computation and `resolve/2`'s pinned-reference lookup.
- A composite index `idx_secrets_lookup` on `(tenant_id, namespace, name,
  status, created_at DESC)` — backs `resolve/2`'s unpinned-reference query
  (`WHERE tenant_id = $1 AND namespace = $2 AND name = $3 AND status =
  'active' ORDER BY created_at DESC LIMIT 1`, 0016 §E) directly as an
  index-only scan.
- No index on `tenant_id` alone — consistent with every other table's
  precedent in this codebase (the column is a filter predicate, not by
  itself the isolation mechanism, since this table's isolation mechanism is
  `resolve/2`'s own explicit application-level check, not a schema
  boundary).

---

## 2. Master key — `LETFLOW_SECRETS_MASTER_KEY` (0016 §B)

**Read location:** `config/runtime.exs`, in a new top-level block that runs
for **every** `config_env()`, not only `:prod` — this is a deliberate
departure from `config/runtime.exs`'s current shape, where every existing
`raise`-on-missing-env-var check (`DATABASE_URL`) is scoped inside
`if config_env() == :prod do`. 0016 §B requires startup to fail in every
environment including CI/test (0016 Consequences: "REQ-190's test setup
must inject a real (test-only) 64-hex-char value; it must not weaken this
record's startup-failure rule to make tests pass"), so the new block is NOT
nested inside the existing `if config_env() == :prod` guard.

**Validation, in order, each with an explicit user-facing message (no
default value returned at any step):**

1. `System.get_env("LETFLOW_SECRETS_MASTER_KEY")` — absent (`nil`) → `raise`.
2. `String.length/1 == 64` and every character matches `[0-9a-f]`
   (lowercase hex only, matching 0016 §B's stated format exactly) — fails
   either check → `raise`.
3. `Base.decode16(value, case: :lower)` succeeds and yields exactly 32
   bytes — this is implied by check 2 (64 lowercase-hex chars always decode
   to 32 bytes) but is asserted explicitly as its own step rather than
   trusted as a corollary, per "no speculation."
4. Literal-value rejection: the decoded 32 bytes are NOT `<<0::256>>`
   (all-zeros) and NOT `<<0xFF::256>>` (wrapped 32 bytes of `0xFF`, i.e. the
   64-char string `"f" * 64`) — compared as raw bytes, not as the hex
   string, so this check cannot be bypassed by re-encoding — fails →
   `raise`.

All four checks raise via `raise "..."` from `config/runtime.exs` — this
runs at boot, before `Letflow.Application.start/2`'s supervision tree
starts, so a `raise` here is equivalent to `System.stop/1` for this
purpose: the application never reaches a state where it could serve a
request or run a migration.

**Resolved value storage:** `config :letflow, :secrets_master_key,
<32 raw bytes>` — read once at boot, held in application env exactly like
`Letflow.Repo`'s own connection config, never re-read from `System.get_env/1`
at call time (matches this codebase's existing `config/runtime.exs`
pattern for `DATABASE_URL`). `Letflow.Secrets` reads it via
`Application.fetch_env!(:letflow, :secrets_master_key)` inside `put/2`/
`resolve/2` — `fetch_env!` (not `get_env` with a default) so a
programming error that skips the `config/runtime.exs` block (impossible in
normal boot, but defensive against a test harness that stubs config) fails
loudly rather than silently falling back to `nil` and crashing somewhere
less legible.

**`.env.example`:** this repository currently has no `.env.example` file
committed (only an untracked `.env` — confirmed by directory listing at
design time). This design creates `.env.example` at the repo root for the
first time, documenting `LETFLOW_SECRETS_MASTER_KEY`'s name/format with a
comment (`# generate with: openssl rand -hex 32` — 0016 §B's own suggested
command) and no working value, per 0016 §B's explicit "never a working
value" rule. This is a new file this design introduces, not an edit to an
existing one — flagged so ELIXIR-DEV doesn't search for a nonexistent file
to edit.

**Test environment:** `config/test.exs` (or a `System.put_env/2` call in
`test/test_helper.exs`, ELIXIR-DEV's implementation choice — both satisfy
0016's requirement equally, not decided here) must set
`LETFLOW_SECRETS_MASTER_KEY` to a real, valid (non-all-zeros, non-all-`f`s)
64-hex-char test-only value before `config/runtime.exs` runs. This is
listed as an open question only in the sense of *which* mechanism
(`config/test.exs` vs. `System.put_env/2` in a `.env`-loading step) — the
requirement itself (a real value must be present) is not open.

---

## 3. `Letflow.Secrets` — public API

`lib/letflow/secrets.ex`. Plain Ecto context module, no process — same
shape as `Letflow.Dlq`/`Letflow.Webhooks`.

### 3.0 Why no `opts: [prefix: ...]`

Every other tenant-scoped context module in this codebase takes
`opts :: [prefix: String.t()]` because its table lives in a tenant schema
and the caller must supply which schema. `secrets` is global (0016 §B) — a
`Letflow.Secrets` function has no schema to select. Instead, every function
that needs tenant scoping takes `tenant_id :: Ecto.UUID.t()` directly as an
explicit argument or option, always **the caller's own authenticated
tenant_id**, never derived from a `prefix`. This is the same
"explicit-predicate, not inferred" preference 0016 §B and INV-1 both cite,
applied to this module's own argument shape.

### 3.1 `put/2`

```
@type put_attrs :: %{
  required(:tenant_id) => Ecto.UUID.t(),
  required(:namespace) => String.t(),
  required(:name) => String.t(),
  required(:purpose) => :webhook_hmac | :generic,
  required(:plaintext) => binary(),
  required(:created_by) => String.t()
}

@spec put(put_attrs(), opts :: []) ::
  {:ok, %{reference: String.t(), key_id: pos_integer(), created_at: DateTime.t()}}
  | {:error, :invalid_namespace}
  | {:error, :invalid_name}
  | {:error, Ecto.Changeset.t()}
```

`opts :: []` is reserved (present for call-shape consistency with the rest
of this codebase's context modules and forward-compatibility) but currently
accepts no keys — `Letflow.Secrets` has no `:prefix` to thread.

**Behavior, in order:**

1. Validate `namespace` and `name` each match `^[a-z0-9_-]+$` — reject
   before touching the DB (`{:error, :invalid_namespace}` /
   `{:error, :invalid_name}`; the two are distinguished, not folded into one
   generic error, so a caller/test can assert on which segment was wrong).
2. Inside one transaction:
   a. Compute `key_id = COALESCE(MAX(key_id), 0) + 1` for
      `(tenant_id, namespace, name)` (§1.3).
   b. Generate a fresh 32-byte data key: `:crypto.strong_rand_bytes(32)`.
   c. Generate a fresh 12-byte payload nonce: `:crypto.strong_rand_bytes(12)`.
   d. Compute `aad = "#{tenant_id}:#{namespace}:#{name}:#{purpose}"` (0016
      §D, exact format).
   e. `{ciphertext, auth_tag} = :crypto.crypto_one_time_aead(:aes_256_gcm,
      data_key, nonce, plaintext, aad, true)` — AES-256-GCM encrypt.
   f. Generate a fresh 12-byte wrap nonce: `:crypto.strong_rand_bytes(12)`.
   g. `{wrapped_data_key, wrap_auth_tag} = :crypto.crypto_one_time_aead(
      :aes_256_gcm, master_key, wrap_nonce, data_key, "", true)` —
      AES-256-GCM-wrap the data key under the master key. AAD for the
      key-wrap pass is the empty binary `""` — 0016 §D states the AAD binds
      only the **payload's** identity; it does not specify a second AAD for
      the key-wrap pass, and this design does not invent one (flagged
      explicitly, see §9 OQ-4, rather than silently choosing a non-empty
      value 0016 never asked for).
   h. Insert the row: `algorithm: :aes_256_gcm, wrapped_key_algorithm:
      :aes_256_gcm, status: :active, wrapping_key_ref:
      "env:LETFLOW_SECRETS_MASTER_KEY", wrapping_key_version: 1,
      created_at: <now>` plus every field computed above.
   i. Zero the plaintext `data_key` binary from step (b) — Erlang binaries
      are immutable so this is best-effort (rebinding the variable, not a
      true in-place wipe; the BEAM has no primitive for the latter) — noted
      as an honest limitation, not a guarantee, consistent with this
      design's general "state limitations honestly" instruction (§6).
3. On a unique-constraint violation on `(tenant_id, namespace, name,
   key_id)` (a concurrent `put/2` computed the same `key_id`): retry once
   from step 2a with a fresh transaction. A second collision is treated as
   a genuine write failure (`{:error, changeset}`), not retried further —
   this bounds retry storms without silently swallowing a real conflict.
4. Return `{:ok, %{reference: <unpinned reference string, 0016 §C>,
   key_id: key_id, created_at: created_at}}` — **the returned map contains
   exactly these three keys and nothing else.** No `plaintext`, no
   `ciphertext`, no `wrapped_data_key`, no `nonce`/`auth_tag` field of any
   kind appears anywhere in the return value — this is what AC2 (REQ-190's
   acceptance criteria) asserts by matching over the whole structure.
   `reference` is always the **unpinned** form
   (`sec://tenant/<tenant>/<namespace>/<name>`, no `#<key_id>` suffix) —
   callers that need the pinned form compose it themselves from the
   returned `key_id` (e.g. `"#{reference}##{key_id}"`), since `put/2` has
   no way to know whether a given caller wants pinned or unpinned.

### 3.2 `resolve/2`

```
@spec resolve(reference :: String.t(), opts :: [tenant_id: Ecto.UUID.t(), consumer: :webhook_dispatcher | :generic]) ::
  {:ok, %{plaintext: binary(), key_id: pos_integer(), purpose: :webhook_hmac | :generic}}
  | {:error, :invalid_reference}
  | {:error, :tenant_mismatch}
  | {:error, :not_found}
  | {:error, :purpose_not_allowed}
  | {:error, :disabled}
  | {:error, :deleted}
```

**This is the exact call shape REQ-183's preserved design assumes**
(`Letflow.Secrets.resolve(reference, tenant_id: subscription.tenant_id)`),
with one addition: `opts` also accepts `:consumer` (defaulted to `:generic`
when omitted — see step 3 below), needed to implement the purpose/consumer
matrix REQ-190's own acceptance criteria require and which REQ-183's design
text does not exercise (REQ-183 always resolves as a webhook consumer, but
does not itself need to *name* that in its call — see §8 for why omitting
`:consumer` still resolves REQ-183's own webhook-purpose secret correctly).
The success return type is a superset-compatible refinement of REQ-183's
assumed `{:ok, plaintext :: binary()}` — see §8 for the exact reconciliation
statement.

**Behavior, in order (0016's own `resolveSecret` ordering, Evidence
section, preserved exactly):**

1. **Parse the reference.** Regex:
   `^sec://tenant/([a-z0-9_-]+)/([a-z0-9_-]+)/([a-z0-9_-]+)(?:#(\d+))?$`
   capturing `tenant_segment`, `namespace`, `name`, and optional
   `key_id_segment`. No match → `{:error, :invalid_reference}`, no query
   run at all.
2. **Tenant check, before any query.** `opts[:tenant_id]` is required
   (`Keyword.fetch!/2` — a caller that omits it is a programming error, not
   a runtime `{:error, _}` case, matching this codebase's `Keyword.fetch!`
   idiom for mandatory options elsewhere). Resolve `tenant_segment` (the
   reference's own tenant identifier string) to a `tenant_id` UUID via
   `Letflow.TenantProvisioning`'s existing tenant-identifier lookup — if
   `tenant_segment` does not resolve to any known tenant, OR resolves to a
   `tenant_id` different from `opts[:tenant_id]`, return
   `{:error, :tenant_mismatch}` for **both** cases alike (0016 requirement:
   "the error does not disclose whether that secret exists" — a reference
   naming a genuinely nonexistent tenant and one naming a real-but-different
   tenant are indistinguishable in the returned error, matching INV-5's
   not-found/forbidden-indistinguishability principle applied here even
   though INV-5 itself is scoped to S4 lookup-by-ID endpoints — the same
   reasoning applies structurally). This check runs and can fail **before
   any `secrets` table query** — the literal ordering the acceptance
   criteria require.
3. **Purpose/consumer matrix.** `opts[:consumer]` defaults to `:generic`
   when omitted. The matrix (0016 Evidence, "a `webhook_dispatcher`
   consumer may only unwrap `webhook_hmac` or generic secrets"):

   | `opts[:consumer]` | may resolve `purpose:` |
   |---|---|
   | `:webhook_dispatcher` | `:webhook_hmac`, `:generic` |
   | `:generic` (default) | `:generic` only |

   This check is applied **after** the row is fetched (step 4) since the
   row's `purpose` column is the input to this check — a caller cannot know
   a secret's purpose without resolving it first, so this ordering is
   forced, not a design choice. Failing this check returns
   `{:error, :purpose_not_allowed}` — deliberately distinguishable from
   `:not_found`/`:tenant_mismatch`, since REQ-190's own acceptance criteria
   demonstrate this failure mode as its own explicit test case (unlike
   `:tenant_mismatch`, which must NOT be distinguishable from not-found —
   this is a different property being tested and the two are not meant to
   share a shape).
4. **Row lookup.**
   - **Pinned** (`key_id_segment` present): `WHERE tenant_id = $1 AND
     namespace = $2 AND name = $3 AND key_id = $4` — exactly one row or
     none. None → `{:error, :not_found}`. **A pinned reference is not
     filtered by `status` at the query level** — 0016 §E: "remains
     resolvable by an explicit `#key_id` pin" even when `disabled`. If the
     found row's `status == :disabled`, this design still returns success
     for a pinned reference (0016 §E's explicit grace-window use case) —
     **but if `status == :deleted`, `resolve/2` returns `{:error,
     :deleted}`** even when pinned, since 0016 §E only names `disabled` as
     still-pinnable, never `deleted` (a deleted row's ciphertext "may be
     physically removed" per 0016 §E, so pinning cannot be relied on to
     resolve it regardless). This asymmetry (pinned-disabled succeeds,
     pinned-deleted fails) is the design's own reading of 0016 §E's silence
     on the deleted case — flagged explicitly, see §9 OQ-5.
   - **Unpinned** (`key_id_segment` absent): `WHERE tenant_id = $1 AND
     namespace = $2 AND name = $3 AND status = 'active' ORDER BY
     created_at DESC LIMIT 1` (0016 §E, exact query shape, filtered
     in-query not post-fetch — the direct fix for R-Co's defect (c)). No
     row → `{:error, :not_found}` (this covers both "no secret with this
     name exists" and "every version is disabled/deleted" — both are
     legitimately "nothing currently resolvable," and the acceptance
     criteria do not require distinguishing them).
5. Apply the purpose/consumer check (step 3) against the fetched row.
6. **Decrypt.**
   a. Unwrap: `:crypto.crypto_one_time_aead(:aes_256_gcm, master_key,
      row.wrap_nonce, row.wrapped_data_key, "", row.wrap_auth_tag, false)`
      → `data_key` (or `:error` on tag mismatch — see error handling
      below).
   b. Decrypt: `:crypto.crypto_one_time_aead(:aes_256_gcm, data_key,
      row.nonce, row.ciphertext, row.aad, row.auth_tag, false)` →
      `plaintext` (or `:error` on tag mismatch).
   c. Either step returning `:error` (GCM authentication failure — the
      stored `aad`/tag no longer matches, e.g. corrupted row or, in
      principle, a master-key mismatch after an unsupported manual key
      change) is a genuine internal-consistency failure, not a caller-input
      error — this design raises (lets it crash) rather than returning a
      new `{:error, :decryption_failed}` tag, since no acceptance criterion
      calls for a graceful-degradation path here and a silently-swallowed
      decryption failure is a worse outcome than a loud crash. Flagged as a
      design choice, see §9 OQ-6.
7. Return `{:ok, %{plaintext: plaintext, key_id: row.key_id, purpose:
   row.purpose}}`.

**AC mapping (REQ-190's acceptance criteria, this function):**
- "put/2 + resolve/2 round-trip, ciphertext column does not contain
  plaintext" — §3.1 step 2e + §3.2 step 6, asserted directly against
  `Secret.ciphertext` in a test.
- "tenant A vs. tenant B rejected before any query" — step 2, literal
  ordering.
- "purpose/consumer matrix" — step 3/5, the table above.
- "disabled-newest falls back to active" — step 4's unpinned query,
  `status = 'active'` filtered in-query.
- "master key unset/malformed fails startup" — §2, not this function (a
  startup-time check, not a `resolve/2`-time one).

### 3.3 `disable/2`

```
@spec disable(reference_pinned :: String.t(), opts :: [tenant_id: Ecto.UUID.t()]) ::
  {:ok, %{key_id: pos_integer(), disabled_at: DateTime.t()}}
  | {:error, :invalid_reference}
  | {:error, :tenant_mismatch}
  | {:error, :not_found}
  | {:error, :already_disabled}
```

Takes a **pinned** reference (`#<key_id>` required — disabling "the newest
version" ambiguously by an unpinned reference is not a case any acceptance
criterion requires, and would be a race-prone operation the requirement
does not ask this design to solve; a caller wanting to disable "whatever is
currently active" resolves first via `resolve/2`, reads back `key_id`, then
calls `disable/2` with that pinned reference — two steps, deliberately, so
the disable target is always an explicit `key_id` the caller has already
observed). Same tenant-check-before-query ordering as `resolve/2` step 2.
`{:error, :already_disabled}` if `status` is already `:disabled` or
`:deleted` (idempotency: a repeated `disable/2` call is not silently
treated as success, since REQ-190's own acceptance criteria don't require
idempotent-success and a caller re-disabling an already-deleted row is more
likely a bug worth surfacing than a benign retry).

**Behavior:** sets `status: :disabled, disabled_at: <now>` via a changeset
that casts **only** `:status, :disabled_at` — `created_by` is not in this
changeset's cast list at all, structurally preventing the R-Co defect the
requirement text names ("R-Co's `disableSecretVersion` overwrites
`created_by` with the disabling actor, losing the original creator — do not
port that"). No parameter on `disable/2` even accepts an "acting actor"
value to write into `created_by` — the only way this design could
reintroduce that defect is by adding a field to the changeset's cast list
that isn't there.

---

## 4. Ecto schema — `Letflow.Secrets.Secret`

`lib/letflow/secrets/secret.ex`. Ordinary `Ecto.Schema`
(`@primary_key {:id, :binary_id, autogenerate: true}`), no `@schema_prefix`
(global table). No process.

```
@type t :: %__MODULE__{
  id: Ecto.UUID.t(),
  tenant_id: Ecto.UUID.t(),
  namespace: String.t(),
  name: String.t(),
  key_id: pos_integer(),
  purpose: :webhook_hmac | :generic,
  status: :active | :disabled | :deleted,
  algorithm: :aes_256_gcm,
  wrapped_key_algorithm: :aes_256_gcm,
  ciphertext: binary(),
  wrapped_data_key: binary(),
  nonce: binary(),
  wrap_nonce: binary(),
  auth_tag: binary(),
  wrap_auth_tag: binary(),
  aad: binary(),
  wrapping_key_ref: String.t(),
  wrapping_key_version: pos_integer(),
  created_at: DateTime.t(),
  created_by: String.t(),
  disabled_at: DateTime.t() | nil,
  deleted_at: DateTime.t() | nil
}
```

**No field on this struct is ever named `plaintext`, and no changeset
function on this schema accepts a `"plaintext"`/`:plaintext` key** —
`put/2` computes `ciphertext`/`wrapped_data_key`/etc. in `Letflow.Secrets`
itself (§3.1) before ever constructing a changeset; the plaintext value
never reaches this module. This is the same "structurally impossible, not
just policy" pattern `Letflow.Webhooks.Subscription`'s own moduledoc uses
for `secret_hash`/`hmac_secret_once`.

### 4.1 Changesets

```
@spec insert_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Casts every column in §1.1 except `disabled_at`/`deleted_at` (both remain
`nil` at insert). `validate_required/2` on every non-nullable column.
`validate_format/3` on `namespace` and `name` against `~r/^[a-z0-9_-]+$/`
(defense in depth alongside `Letflow.Secrets.put/2`'s own pre-DB check,
§3.1 step 1 — the changeset-level check is what actually enforces this at
the DB-write boundary if `put/2`'s own regex check were ever bypassed by a
future caller).

```
@spec disable_changeset(t(), attrs :: map()) :: Ecto.Changeset.t()
```
Casts **only** `:status, :disabled_at` (§3.3's structural fix for the
R-Co `created_by`-overwrite defect).

---

## 5. Webhook HMAC reconciliation (0016 §F, requirement scope item 6)

### 5.1 `webhook_subscriptions` migration

New tenant-scoped migration (carries the `if prefix() do ... end` guard,
registered in `Letflow.TenantProvisioning.tenant_scoped_migrations/0` —
**both halves mandatory**, per that module's own established discipline
and per REQ-190's own text explicitly naming R-Co's ISS-0112 mistake of
scoping this exact migration to `public` only). Applies to **every**
existing tenant schema, not just newly-provisioned ones — this is what
"registered in `tenant_scoped_migrations/0`" achieves structurally, since
`replay_migrations/2` (existing machinery) re-applies the full manifest to
every tenant schema.

**Column changes to `webhook_subscriptions`:**
- ADD `secret_ref :: :string`, nullable at the column level (existing rows
  — see §5.2 — legitimately have none if `secret_hash` is being blanked
  without a re-encryptable plaintext, though §5.2 concludes there are no
  such rows in practice).
- ADD `secret_key_id :: :integer`, nullable at the column level.
- The existing `secret_hash :: :string` column is **blanked** (every row's
  value set to `NULL`), not dropped — matching R-Co's own `GBL-128`
  migration shape the requirement text explicitly asks to follow
  ("BLANKS the plaintext column rather than dropping it"). The column
  itself is left in place by this migration (dropping it is a separate,
  later cleanup this design does not perform, since no acceptance
  criterion requires the column's physical removal — only that "no
  plaintext secret persist[s] in `webhook_subscriptions`," which blanking
  already satisfies).

**Idempotency/re-runnability:** `add_if_not_exists`/Ecto's standard
`change/0` semantics — running this migration twice against the same
schema must not error. Use `execute/2` with `UPDATE ... SET secret_hash =
NULL` guarded by nothing extra (setting an already-NULL column to NULL
twice is naturally idempotent; no special-case needed).

### 5.2 "No existing secrets need migrating" — asserted, not assumed

Per the requirement text's own instruction ("assert it rather than assuming
it"): this design's migration includes an `execute/2` step, run inside the
`if prefix() do` guard for every tenant schema, that queries
`SELECT count(*) FROM webhook_subscriptions WHERE secret_hash IS NOT NULL`
**before** blanking, and raises (fails the migration loudly) if that count
is nonzero in any environment where this migration is actually exercised
against real data with a `secret_hash` this design cannot recover a
plaintext for. This makes "there are none to migrate" a runtime-verified
fact for whichever environment actually runs the migration, not a
design-time assumption baked in silently — matching the requirement text's
own instruction to assert rather than assume. If a future environment
somehow does have rows, this raise is the intended failure mode (surfacing
the gap loudly) rather than silently blanking real key material with no
recovery path, since `secret_hash` is one-way and cannot be migrated into
`secrets` regardless — there is no way to "genuinely migrate existing
secrets" for THIS specific column, only to detect that none exist (the
requirement text's own "or state that there are none" branch, which this
design takes, backed by a runtime assertion rather than only prose).

### 5.3 `Letflow.Webhooks.Subscription` schema change

Add fields `secret_ref :: String.t() | nil` and
`secret_key_id :: pos_integer() | nil`. Remove `secret_hash` field
entirely from the struct (the column stays in the DB per §5.1, but no
`Ecto.Schema` field maps to it — `Ecto.Schema` tolerates an unmapped
column silently, matching every other "column exists, no field" precedent
this codebase would use if one existed; if `mix ecto.gen.migration`
tooling or `Ecto.Schema`'s own runtime warns about this, ELIXIR-DEV
resolves it by explicit `field(:secret_hash, :string, virtual: true)` or
equivalent — implementation detail not gating this design).

### 5.4 `Letflow.Webhooks.create/2` change

**Behavior change, `create/2`'s secret handling only** (every other line
of `create/2` — tenant resolution, `target_url`/`description`/`event_types`
handling — unchanged):

1. Resolve the plaintext exactly as today (`resolve_secret_plaintext/1`,
   unchanged — caller-supplied or generated).
2. Instead of `hash_webhook_secret/1` + `secret_hash` insert attr: call
   `Letflow.Secrets.put/2` with `namespace: "webhook", name: <the new
   subscription's id, generated via Ecto.UUID.generate/0 before the
   Subscription insert since the name needs to exist before the row that
   references it>, purpose: :webhook_hmac, plaintext: plaintext,
   created_by: "system:webhooks.create"`.

   **Open question on `name`, flagged not silently resolved:** using the
   subscription's own id as the secret's `name` requires generating that
   id before the `Subscription` insert (today, `Repo.insert/2` autogenerates
   it). This design's answer: generate the id explicitly via
   `Ecto.UUID.generate/0`, pass it into both `Letflow.Secrets.put/2`'s
   `name` and the `Subscription` changeset's `:id` field (added to
   `insert_changeset/2`'s cast list, since `@primary_key {:id, :binary_id,
   autogenerate: true}` already permits an explicit id to be supplied
   instead of autogenerated — standard Ecto behavior, not a schema change).
   See §9 OQ-7 for the alternative this design rejected (a stable derived
   name not requiring id pre-generation) and why.
3. On `Letflow.Secrets.put/2` success: build `insert_attrs` with
   `secret_ref: <the returned reference>, secret_key_id: <the returned
   key_id>` in place of `secret_hash: secret_hash`.
4. `hmac_secret_once` in `create/2`'s own return value is **unchanged** —
   still the plaintext, still returned exactly once, still never persisted
   as itself anywhere (0016 §F: "The response-shape contract REQ-181
   already committed to ... is unchanged").
5. On `Letflow.Secrets.put/2` failure (any `{:error, _}`): `create/2`
   returns that error, wrapped or passed through as
   `{:error, {:secret_write_failed, reason}}` — no `Subscription` row is
   inserted (the whole operation is one `Ecto.Multi` transaction spanning
   both the `secrets` insert and the `webhook_subscriptions` insert, so a
   `Subscription` row is never left referencing a `secret_ref` that failed
   to write — see §9 OQ-8 for why this crosses the "global table + tenant
   schema in one transaction" boundary and whether that's actually
   supported by this codebase's `Repo`/prefix machinery, flagged as a real
   implementation risk, not asserted as definitely fine).

### 5.5 AC mapping (REQ-190's webhook-reconciliation acceptance criterion)

"a secret written via `put/2` with a webhook purpose, referenced from a
`webhook_subscriptions` row's `secret_ref`/`secret_key_id` columns,
resolving via `resolve/2` to the correct plaintext for a webhook consumer,
and shows no plaintext secret persisting in `webhook_subscriptions`" — §5.4
steps 2-3 (the write path) + a test calling
`Letflow.Secrets.resolve(subscription.secret_ref, tenant_id: ...,
consumer: :webhook_dispatcher)` and asserting the returned plaintext
matches `create/2`'s own `hmac_secret_once`, plus a direct read of the
`webhook_subscriptions` row confirming `secret_hash` is `NULL`.

---

## 6. Redaction — `Letflow.Secrets.Redaction` + Logger configuration

### 6.1 `Letflow.Secrets.Redaction`

`lib/letflow/secrets/redaction.ex`.

```
@sensitive_exact_keys ~w(authorization password password_hash token access_token
  refresh_token bootstrap_token api_token secret client_secret credential
  credentials set-cookie cookie)

@sensitive_suffixes ~w(_token _secret _password _credential)

@spec redact_map(map()) :: map()
```

Recursively walks a map (and any nested map/list-of-maps) and, for every
key (string or atom, compared case-insensitively against the exact list
and suffix list above — a key matches if its lowercased string form
equals an entry in `@sensitive_exact_keys`, or ends with one of
`@sensitive_suffixes`), replaces the corresponding value with the literal
string `"[REDACTED]"`. The key itself is always kept, unmodified. A
non-matching key's value is recursed into if it is itself a map or a list
of maps, otherwise left as-is.

```
@spec render_reference(reference :: String.t()) :: String.t()
```

Renders a `sec://tenant/...` reference for logging with the `#<key_id>`
segment masked: `sec://tenant/<tenant>/<namespace>/<name>#***` if the
input reference has a `#<key_id>` suffix, or the reference unchanged
(no `#` segment to mask) if it is already unpinned. This is distinct
from `redact_map/1` — it operates on a single reference *string*, not a
map — because a reference string is not itself secret material (it names
*where* a secret is, not the secret's value), the requirement asks only
for the `key_id` portion to be masked, not the whole reference withheld.

**Moduledoc, verbatim honest-limitation statement (this exact sentence, or
one materially equivalent, is REQUIRED per REQ-190's acceptance criteria):**
"Redaction keys on the field NAME only. A secret value placed under a key
this module does not recognize as sensitive (a typo, a new call site using
an unlisted key name, or a value nested under a generic key like `data`)
is NOT caught and will appear in log output in plaintext. This module
provides no content-based detection of secret-shaped values — it is a
name-based denylist, not a guarantee."

### 6.2 Logger configuration

`config/config.exs` (or `config/runtime.exs`, ELIXIR-DEV's choice —
whichever this codebase's existing Logger config already lives in, not
yet confirmed by this design since no `Logger.configure` currently exists
in this tree per this design's own research; flagged, see §9 OQ-9) adds a
custom `Logger` formatter or `:erlang.trace`-free filter function that
calls `Letflow.Secrets.Redaction.redact_map/1` on every log event's
metadata map before formatting. Concretely: a module implementing the
`:logger` filter behaviour (`filter/2`, returning the event with its
`meta` map redacted) registered via `:logger.add_primary_filter/2` in
`Letflow.Application.start/2`, OR an `Elixir.Logger.Formatter`-level hook
— **this design does not pin the exact mechanism** (both are valid Erlang
`:logger`-API-level integration points and either satisfies "a value
stored under a sensitive key never reaches a log line") — ELIXIR-DEV picks
one, states which, and the test (§ acceptance criterion "a log call
passing a value under each of the keys ... emits `[REDACTED]`... asserted
against captured log output") is what actually proves it works, regardless
of which mechanism was chosen. Flagged as an intentionally-left
implementation-detail open question, see §9 OQ-9 — not a silently-resolved
one, since which Logger integration point is chosen could matter for
performance/ordering in a way this design does not have grounds to decide.

---

## 7. Invariants

- **INV-4 (secrets by reference only):** `Letflow.Secrets.put/2` never
  returns plaintext or ciphertext (§3.1 step 4). `resolve/2` returns
  plaintext only to the calling process's return value, never logged —
  every log call in this module's own implementation must pass through
  `Redaction.redact_map/1` or avoid logging the resolved value/metadata map
  at all.
- **INV-7 (no SQL string interpolation):** every query in §3 uses
  `Ecto.Query`'s `from/2` or parameterized `Repo.query/3` — the reference
  parser (§3.2 step 1) never feeds regex-captured segments into a raw SQL
  string; they become bound query parameters (`^tenant_segment` etc. in
  `Ecto.Query` pin syntax).
- **INV-8 (no unhandled crash on external-I/O path):** `resolve/2`'s
  reference-parsing and lookup paths never bare-match `{:ok, x} =` on
  caller-supplied input — every step returns a tagged tuple the caller
  (eventually REQ-183/REQ-191) must handle. The one deliberate exception
  is §3.2 step 6c (GCM authentication failure on decrypt) — an internal
  consistency failure, not caller-input-shaped, explicitly justified there
  rather than silently included under "no unhandled crash."
- **Tenant isolation (0016 §B's application-level substitute for
  Decision B's schema boundary):** `resolve/2`'s tenant check (step 2) is
  the FIRST operation after reference parsing, unconditionally, on every
  call — no code path reaches the `secrets` table query without first
  passing this check.
- **`created_by` immutability:** no changeset in this design (§3.3,
  `disable_changeset/2`) ever casts `:created_by` — structurally enforced,
  not merely documented.
- **No plaintext at rest outside `ciphertext`:** no column other than the
  transient in-memory `plaintext`/`data_key` local variables inside
  `put/2`/`resolve/2` ever holds unencrypted secret material — the
  `Secret` struct itself has no `plaintext` field (§4).

---

## 8. Contract reconciliation with REQ-183's preserved design

REQ-183's design (`req183-webhook-delivery-dispatch.md` §3.2 on the paused
branch) assumes:

```
@spec Letflow.Secrets.resolve(reference :: String.t(), opts :: [tenant_id: Ecto.UUID.t()]) ::
  {:ok, plaintext :: binary()} | {:error, term()}
```

called as `Letflow.Secrets.resolve(subscription.secret_ref, tenant_id:
subscription.tenant_id)` — no `:consumer` option passed.

**This design's actual signature (§3.2):**

```
@spec resolve(reference :: String.t(), opts :: [tenant_id: Ecto.UUID.t(), consumer: :webhook_dispatcher | :generic]) ::
  {:ok, %{plaintext: binary(), key_id: pos_integer(), purpose: :webhook_hmac | :generic}}
  | {:error, :invalid_reference} | {:error, :tenant_mismatch} | {:error, :not_found}
  | {:error, :purpose_not_allowed} | {:error, :disabled} | {:error, :deleted}
```

**Match / no-match, stated explicitly:**

1. **Function name, module, first argument, `opts[:tenant_id]` key:**
   MATCH exactly.
2. **`opts` is a superset, backward-compatible:** REQ-183's call
   (`tenant_id: subscription.tenant_id`, no `:consumer` key) is a valid
   call against this design's actual signature — `:consumer` defaults to
   `:generic` when omitted (§3.2 step 3). **This means REQ-183's own call
   site, as literally written in its preserved design, would resolve a
   `webhook_hmac`-purpose secret as a `:generic` consumer and FAIL the
   purpose/consumer matrix** (§3.2's table: `:generic` may only resolve
   `:generic` purpose). **This is a real mismatch, not a compatible
   superset in practice, and is flagged here for ORCH to reconcile when
   REQ-183 resumes**, per this task's own instruction: REQ-183's call site
   must be updated to pass `consumer: :webhook_dispatcher` explicitly once
   it resumes, or `deliver/3`'s design updated to state that. This design
   does not retroactively edit REQ-183's paused branch — it states the
   required one-line diff (add `consumer: :webhook_dispatcher` to the
   `opts` REQ-183's `deliver/3` passes) exactly as REQ-183's own §3.2 text
   anticipated: "If REQ-190 lands a different function name, module, or
   argument order, the call site in `deliver/3` ... is updated to match —
   this design does not block on that happening first."
3. **Return shape on success:** REQ-183 assumed a bare
   `{:ok, plaintext :: binary()}`. This design returns
   `{:ok, %{plaintext: ..., key_id: ..., purpose: ...}}` — a map, not a
   bare binary. **This is also a real mismatch**, not just an addition:
   REQ-183's own §3's pseudocode (`Compute the HMAC-SHA256 signature of the
   encoded JSON body under the resolved signing key`) would need
   `result.plaintext` instead of `result` directly. Flagged as the second
   required one-line diff for REQ-183's resumption. **Reason for the
   richer return shape, not deferred to REQ-183 to ask for:** REQ-190's own
   acceptance criteria require `resolve/2` to "return the plaintext value
   with its key_id and purpose" (requirement text, scope item 3) — REQ-190
   cannot satisfy its own acceptance criteria with a bare-binary return, so
   this is not a gratuitous divergence from REQ-183's design, it is
   REQ-190's own text overriding what REQ-183 could only guess at without
   seeing REQ-190's actual requirement.
4. **Error shape:** REQ-183 assumed bare `{:error, term()}`. This design's
   six concrete atoms are each individually compatible with `term()` — no
   diff needed at REQ-183's call site for this part, since REQ-183's design
   never pattern-matches on a *specific* error atom in the text quoted
   above (it treats key-resolution failure as one undifferentiated branch,
   §3.1 step 3 of that design: "If key resolution itself fails (e.g.
   `{:error, :not_found}` ...)").

**Summary for ORCH:** two required one-line updates to REQ-183's design/
implementation when it resumes (pass `consumer: :webhook_dispatcher`;
unwrap `result.plaintext` instead of using `result` directly) — both
already anticipated and pre-authorized by REQ-183's own design text's "the
call site ... is updated to match" clause, not a surprise requiring a new
design round for REQ-183.

---

## 9. Open questions (not silently resolved)

1. **`wrap_nonce`/`wrap_auth_tag` column names.** 0016 §D describes "its
   own fresh 96-bit nonce, stored as `wrapped_data_key`/its own nonce
   field, distinct from the payload's nonce" and "the key-wrap encryption"
   tag, without naming either column. This design names them
   `wrap_nonce`/`wrap_auth_tag`. If CODE-DESIGN-VALIDATOR or REVIEWER
   prefers different names, this is a low-risk rename, not a structural
   change.
2. **`deleted_at`/`status: :deleted` — no writer exists in REQ-190's own
   scope.** The column and enum value exist (0016 §A requires them) but no
   function here transitions a row to `:deleted`. Left for a future
   requirement (retention/GC policy, explicitly out of 0016's own scope
   per its Decision §E).
3. **`wrapping_key_ref`/`wrapping_key_version` are write-only/inert in this
   design.** `resolve/2` never branches on them — always unwraps with the
   single currently-configured master key. If a future rotation mechanism
   needs to read them to select among multiple historical master keys,
   `resolve/2` gains that branch then; not built now, since 0016
   explicitly defers master-key rotation.
4. **Key-wrap AAD is the empty binary.** 0016 §D does not specify an AAD
   for the key-wrap pass distinct from the payload's. This design uses
   `""` rather than inventing one. If a future decision wants the key-wrap
   pass bound to `tenant_id` as well, that is a new column/AAD scheme, not
   assumed here.
5. **Pinned-reference resolution of a `:disabled` vs. `:deleted` row.**
   0016 §E states a `disabled` version "remains resolvable by an explicit
   `#key_id` pin"; it is silent on whether a `deleted` version does too.
   This design reads that silence as "no" (§3.2 step 4's pinned-lookup
   branch) since a deleted row's ciphertext "may be physically removed"
   per the same section, making pinned-resolution of a deleted row
   potentially impossible regardless of policy. Flagged for
   CODE-DESIGN-VALIDATOR/REVIEWER to confirm this reading rather than
   silently trusting it.
6. **GCM authentication failure on decrypt raises rather than returning a
   tagged error.** No acceptance criterion requires a graceful path for a
   corrupted/tampered row; this design chose to let it crash loudly. If a
   future requirement wants `{:error, :decryption_failed}` instead, that
   is an additive change to `resolve/2`'s error set.
7. **Secret `name` for a webhook subscription's HMAC key.** This design
   chose "the subscription's own id, pre-generated via `Ecto.UUID.generate/0`
   before either insert" over a stable derived name (e.g. hashing something
   else) because the subscription's id is already the natural stable
   identifier and pre-generating a `binary_id` before insert is ordinary,
   well-supported Ecto usage — not because the alternative was evaluated
   and rejected on some other concrete ground. Flagged as the specific
   point where "REQ-190 must add secret_ref/secret_key_id... so name = the
   subscription's id or a stable derived name" (0016 §F's own text) leaves
   two options open, and this design picks the first named one.
8. **Cross-table transaction spanning the global `secrets` table and a
   tenant-schema `webhook_subscriptions` insert (§5.4 step 5).** This
   design asserts both writes belong in one `Ecto.Multi`/transaction but
   does not verify Letflow's `Repo`/prefix machinery actually supports a
   single transaction touching both `public` (no prefix) and a tenant
   prefix cleanly under this project's existing Ecto setup — flagged as an
   implementation-time risk ELIXIR-DEV must confirm, not asserted as
   definitely working. If it is not supported cleanly, the fallback is:
   write the `secrets` row first (outside any tenant transaction, since it
   lives in `public` regardless), then the `webhook_subscriptions` row; on
   `webhook_subscriptions` insert failure, the `secrets` row is orphaned
   (not referenced by any subscription) but not itself a correctness bug
   (no plaintext leak, just an unreferenced encrypted row) — ELIXIR-DEV
   states which approach was actually used.
9. **Logger integration mechanism (`:logger` filter vs. `Logger.Formatter`
   hook), and which config file it lives in.** Deliberately left to
   ELIXIR-DEV's implementation choice, per §6.2 — the acceptance criterion
   is behavioral (captured log output shows `[REDACTED]`), not mechanism-
   specific.
10. **`Letflow.Secrets.put/2`'s `opts :: []` parameter currently accepts no
    keys.** Reserved for call-shape consistency across this codebase's
    context modules; if a future need arises (e.g. an audit-context option)
    it is additive.
