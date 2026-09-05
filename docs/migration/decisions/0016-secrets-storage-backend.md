# 0016 — Secrets storage backend, master key, reference syntax, crypto, rotation, and webhook HMAC key ownership

Status: decided. REVIEWER sign-off on the §B/§F divergences GRANTED 2026-08-30 (see
"REVIEWER sign-off" at the end of this file). Owner: CODE-DESIGNER (REQ-189).

## Question

`docs/migration/stage-6-operational-cross-cutting.md`'s Decisions section named this
gap explicitly: "Likely needs a decision file for `src/secrets` specifically (secret
storage/retrieval backend choice) — defer until this stage starts." The stage has
started. Six sub-questions, all raised by REQ-189's own text, must be settled in one
record because REQ-190 (secrets core implementation) and REQ-183 (webhook delivery
dispatch, HMAC signing) both build on it:

1. Storage backend: Letflow-owned Postgres table, or an external KMS/vault?
2. If Postgres: where does the master (wrapping) key come from, in what format, and
   what happens at startup if it is absent or malformed?
3. Table placement: per-tenant schema (decision 0003 Decision B, the general rule) or
   global (R-Co's actual choice)?
4. Secret reference syntax: does Letflow keep R-Co's `sec://tenant/...` form?
5. Crypto: algorithm, key sizes, nonce handling, AAD binding, and the stored
   `algorithm`/`wrapped_key_algorithm` metadata values — R-Co's own metadata is
   dishonest (see Evidence).
6. Rotation model: what a version carries, what an omitted `#key_id` resolves to
   (R-Co has a live bug here — see Evidence), and whether dual-read during rotation
   is in scope now.
7. (Load-bearing reason this record exists at all, not a footnote) The webhook HMAC
   key collision: REQ-181 (done) stores `webhook_subscriptions.secret` **hashed** and
   never returns it after creation. REQ-183 (pending) needs a real signing key to
   compute an HMAC — a hash cannot supply one. Something has to give.

## Evidence — what R-Co actually built (inspected fresh this batch, not inherited from EXP-501's prose)

- `migrations/GBL-128_exp501_secrets.sql` creates a **global** `secrets` table (in
  `public`, `tenant_id` as a plain column, not a per-tenant-schema table) with columns
  `secret_id, tenant_id, namespace, name, key_id, purpose, status
  (active|disabled|deleted), algorithm, wrapped_key_algorithm, ciphertext,
  wrapped_data_key, nonce, auth_tag, aad, wrapping_key_ref, wrapping_key_version,
  created_at, created_by, disabled_at, deleted_at`, `UNIQUE (tenant_id, namespace,
  name, key_id)`.
PROVENANCE (historical, not current decision authority):
- `src/secrets/crypto.zig`: a fresh random 32-byte data key per write, AES-256-GCM
  over the plaintext with AAD bound to `"{tenant_id}:{namespace}:{name}:{purpose}"`,
  and the data key wrapped by a **second** AES-256-GCM pass under the master key. The
  file's own comment states Zig has no AES-KW primitive, which is *why* the second
  AEAD pass exists in place of real key-wrapping.
PROVENANCE (historical, not current decision authority):
- `src/secrets/reference.zig`: reference syntax is literally
  `sec://tenant/<tenant>/<namespace>/<name>#<key_id>`, `#<key_id>` optional (omitted
  = latest). Segments are lowercase `[a-z0-9_-]` only.
PROVENANCE (historical, not current decision authority):
- `src/secrets/store.zig`'s `resolveSecret`: cross-checks the reference's tenant
  against the caller's tenant before anything else, enforces a purpose/consumer
  matrix (e.g. a `webhook_dispatcher` consumer may only unwrap `webhook_hmac` or
  generic secrets), and zeroes the plaintext buffer after use.
PROVENANCE (historical, not current decision authority):
- **Defect (a) — hardcoded master key.** Every call site passes the literal
  64-zero hex string: `src/api/routes/webhooks.zig:375`,
  `src/webhook/dispatcher.zig:537`, `src/webhook/subscription_store.zig:224`, and
  `src/effects/worker.zig:42`'s struct default. `grep -rniE "MASTER_KEY|WRAPPING_KEY"
  src/` across R-Co's whole tree returns **zero matches** — the env-var wiring
  EXP-501's prose describes was never actually built.
PROVENANCE (historical, not current decision authority):
- **Defect (b) — dishonest algorithm metadata.** Rows are written with
  `wrapped_key_algorithm = "aes_kw_256"` (AES Key Wrap, RFC 3394) while `crypto.zig`
  performs a second AES-256-GCM pass instead, because Zig has no AES-KW primitive
  (its own comment says so). The stored value names a cipher mode the code doesn't
  run.
- **Defect (c) — unpinned lookup ignores status until too late.** `resolveSecret`'s
  unpinned-`key_id` path takes the newest row by `created_at` and only *afterward*
  rejects it if `disabled`/`deleted` — instead of selecting the newest row whose
  `status = 'active'`. Consequence: disabling the newest key version breaks
  resolution entirely (surfaces as a hard failure) rather than falling back to the
  previous active version, which is the behavior anyone rotating a key would expect.

## Decision

### A. Storage backend: Letflow-owned Postgres table

**Chosen: a Postgres table (`secrets`), not an external KMS/vault.** Rejected
alternative: an external KMS (AWS KMS, HashiCorp Vault, etc.) — no such dependency
exists anywhere in this project today (`mix.exs` has no vault/KMS client, no decision
record introduces one), Letflow has no deployment target yet that would host or
reach one (pre-S8, no production deployment — see decision 0004), and introducing an
external network dependency into every secret resolution at execution time is a new
availability failure mode this stage does not need to accept. R-Co itself never
integrated a real KMS either (the "host KMS or env master key" language in EXP-501 is
aspirational prose; the actual code path is envelope encryption under a
locally-held master key, confirmed above). A Postgres table with envelope encryption
gives every property EXP-501 actually asked for (values never in logs/traces,
resolution by reference, per-tenant isolation) without adding an external system this
stage has no other reason to stand up. Nothing here forecloses fronting this table
with a real KMS/HSM-backed master key later — see "Consequences."

### B. Master key source, format, and startup failure — and table placement (divergence from decision 0003 Decision B)

**Master key.** The wrapping key comes from the environment variable
**`LETFLOW_SECRETS_MASTER_KEY`**, required format: a 64-character lowercase
hexadecimal string, decoding to exactly 32 bytes (an AES-256 key). Read once at boot
via `config/runtime.exs` (the same file `DATABASE_URL`/`POOL_SIZE`/`PORT` already use,
per the grep above), following the pattern R-Co never actually built. **Startup fails
hard** — `System.stop/1`/`raise` from `config/runtime.exs`, before the application
supervision tree starts — when the variable is:

- absent entirely;
- not exactly 64 hex characters (wrong length after hex-decoding, or contains a
  non-hex character);
- equal to `"0" x 64` (all-zeros) or `"f" x 64` (all-`f`s) — both rejected by explicit
  literal comparison, not just by the format check, because a well-formatted but
  trivially-guessable key is the exact failure this decision exists to close off
  (R-Co's hardcoded call sites above are literally the all-zeros case).

No default value of any kind exists in code, `.env.example`, or any committed config
file — `.env.example` documents the variable's name and format with a comment
instructing the operator to generate a real value (e.g. `openssl rand -hex 32`), never
a working value. This directly answers REQ-189's citation of R-Co's four hardcoded
call sites and the zero-match `MASTER_KEY`/`WRAPPING_KEY` grep: Letflow has exactly
one place the key can come from, it is never hardcoded, and its absence is a boot-time
failure, not a silent default.

**Table placement — DIVERGES from decision 0003 Decision B.** Decision B's general
rule is per-tenant Postgres schema, `tenant_id` retained intra-schema. This record
places `secrets` in the **global `public` schema instead, with `tenant_id` retained as
a column and part of the table's own scoping predicate/unique constraint** — following
R-Co's actual (not aspirational) implementation, for a reason grounded in R-Co's own
evidence rather than convenience:

- **Rotation and cross-cutting resolution need a single query surface.** `resolveSecret`
  (Evidence above) validates the caller's tenant against the reference's tenant as its
  *first* check, before any decryption — the tenant check is enforced in application
  code at the point of resolution, the same place INV-1/INV-5's tenant-scoping
  discipline is already enforced for every other tenant-scoped table (see
  `docs/agents/instructions/security-invariants.md` INV-1). A per-tenant-schema secrets
  table would require every consumer (webhook dispatcher, future OIDC client-secret
  consumers, future scripting-plugin credentials — decision 0014) to already know and
  supply the correct tenant `:prefix` *before* it can even parse a `sec://tenant/<t>/...`
  reference to check whether that reference's tenant matches the caller's — collapsing
  the reference format's own self-describing tenant segment into pure decoration,
  since the schema boundary would already have silently done the scoping (or silently
  failed to find the row) before the application-level tenant check ever ran. Keeping
  `secrets` global and enforcing tenant-match explicitly in `resolveSecret`-equivalent
  code makes the tenant check an auditable, testable application invariant instead of
  a side effect of which connection prefix happened to be active — the same reasoning
  INV-1's "explicit predicate, not inferred" preference already applies elsewhere in
  this project.
- **This is not new isolation weakening relative to Decision B's actual purpose.**
  Decision B's stated goal (0003 Dimension B) is that a *missing* tenant predicate
  fails loudly (wrong schema/empty result) instead of silently leaking rows. A global
  `secrets` table with an explicit, first-checked `tenant_id`/reference-tenant equality
  assertion in `resolveSecret` still fails loudly on a mismatch (an explicit
  `{:error, :tenant_mismatch}`/403-shaped rejection) — it substitutes an
  application-level hard check for a schema-level hard boundary, for one table, for a
  stated reason (cross-cutting resolution-by-reference needs one query surface before
  the tenant is even known from a connection prefix).
- **R-Co made the identical choice** for the identical table, which is itself
  corroborating (not sole) evidence: this is not a novel judgment call being smuggled
  in, it is a documented precedent this record is choosing to keep rather than
  overturn without a competing reason to.

**This divergence requires REVIEWER sign-off before this record is final** — see
"Open questions / gating" below and CLAUDE.md's don't-silently-re-decide rule. This
record is not to be treated as settled on this point until that sign-off is recorded
here.

### C. Secret reference syntax — adopted verbatim from R-Co

`sec://tenant/<tenant>/<namespace>/<name>#<key_id>` — kept exactly as R-Co defined it
(REQ-189's own description already expects this as "the expected answer," stated here
per that instruction rather than silently deviating). Concretely:

- `<tenant>` — the tenant identifier, `[a-z0-9_-]` lowercase only, matching
  `Letflow.TenantProvisioning`'s existing tenant-identifier conventions (decision
  0003 addendum).
- `<namespace>` — a logical grouping, e.g. `webhook`, `oidc`, `plugin` — `[a-z0-9_-]`.
- `<name>` — the secret's name within that namespace — `[a-z0-9_-]`.
- `#<key_id>` — **optional**. Omitted means "resolve the newest version whose
  `status = "active"`" (see §E — this is the fix for R-Co's defect (c), not a copy of
  it). Present (e.g. `#3`) pins resolution to that exact version regardless of its
  current status, for callers that must keep verifying against a specific historical
  key (e.g. a grace-window verifier — see §F).
- Example: `sec://tenant/acme-corp/webhook/order-created-hook#7`, or unpinned:
  `sec://tenant/acme-corp/webhook/order-created-hook`.

Nothing about adopting this syntax verbatim conflicts with §B's global-table
placement — the reference's `<tenant>` segment is exactly what `resolveSecret`
compares against the caller's authenticated tenant as its first check, per Evidence.

### D. Crypto: algorithm, key sizes, nonce handling, AAD, honest metadata

**Algorithm: envelope encryption with AES-256-GCM used twice — for the data and for
wrapping the data key — kept the same as R-Co's actual implementation, with the
metadata corrected to say so honestly (fixing defect (b)).**

- A fresh random 256-bit (32-byte) **data key** is generated per write (per secret
  version), via a CSPRNG (`:crypto.strong_rand_bytes/1`).
- The plaintext is encrypted with **AES-256-GCM** under the data key. Nonce: a fresh
  random 96-bit (12-byte) nonce per encryption (`:crypto.strong_rand_bytes(12)`),
  stored alongside the ciphertext (`nonce` column) — GCM nonces are never reused
  under the same key, and a fresh data key per write makes nonce reuse structurally
  impossible across versions.
- **AAD (additional authenticated data)** binds the ciphertext to its identity so a
  swapped-in ciphertext from a different secret/tenant fails authentication even if
  somehow substituted at the same row shape: `"{tenant_id}:{namespace}:{name}:{purpose}"`,
  matching R-Co's binding exactly (Evidence) — this remains correct after §B's
  placement change since `tenant_id` stays a real column.
- The data key is itself encrypted ("wrapped") with a **second AES-256-GCM pass**
  under the 256-bit master key (`LETFLOW_SECRETS_MASTER_KEY`, §B) — its own fresh
  96-bit nonce, stored as `wrapped_data_key`/its own nonce field, distinct from the
  payload's nonce.
- **Stored metadata, corrected:** the `algorithm` column stores `"aes_256_gcm"` (what
  encrypts the payload). The `wrapped_key_algorithm` column stores
  **`"aes_256_gcm"`**, not R-Co's `"aes_kw_256"` — this is the direct fix for defect
  (b). AES-KW (RFC 3394 key wrap) is a real, different construction Letflow is not
  using, and the schema must not claim it is. If Letflow later adds genuine AES-KW
  support (a native BEAM/NIF primitive, unlike Zig's stdlib gap), that would be a new,
  distinct `wrapped_key_algorithm` value introduced alongside the old one — not a
  silent redefinition of what `"aes_kw_256"` means after the fact.
- Authentication tag: GCM's 128-bit tag, stored in `auth_tag`, for both the payload
  encryption and (separately) the key-wrap encryption.

### E. Rotation model — fixing defect (c)

- Every write creates a **new row/version**, never an in-place update to
  `ciphertext`/`wrapped_data_key` — `key_id` is a per-version identifier (matching
  R-Co's schema: `UNIQUE (tenant_id, namespace, name, key_id)`).
- A reference may **pin** a specific version (`#<key_id>`) or **omit** it.
- **Unpinned resolution selects the newest row where `status = "active"`** — ordered
  by `created_at DESC`, filtered to `status = "active"` *in the query itself* (e.g.
  `WHERE status = 'active' ORDER BY created_at DESC LIMIT 1`), not filtered
  after fetching the newest row regardless of status. This is the direct fix for
  defect (c): disabling the newest version now correctly falls back to the next-newest
  active version instead of breaking resolution outright.
- `status` transitions: `active -> disabled -> deleted`, matching R-Co's three-state
  enum. A `disabled` version is excluded from unpinned resolution but remains
  resolvable by an explicit `#key_id` pin (e.g. a grace-window verifier still checking
  signatures against a just-rotated-out key). A `deleted` version's ciphertext may be
  physically removed or retained per a separate retention policy — out of this
  record's scope, since REQ-189 does not require deciding retention/GC policy to
  unblock REQ-190/REQ-183.
- **Grace-window dual-read: deferred, not built now.** REQ-190 is not required to
  implement automatic dual-verification against both the newest-active and the
  immediately-previous key during a rotation window. The constraint for when it does
  land: it must be implementable **without changing the reference syntax** (§C) —
  a dual-read consumer resolves the same unpinned reference twice, once now and once
  after checking a "previous active" lookup, rather than requiring a new syntax
  element. This is stated explicitly per REQ-189's own acceptance criteria rather than
  left implicit.

### F. Webhook HMAC key ownership — the load-bearing resolution

**Quoting the contradiction directly, as REQ-189's acceptance criteria require:**
REQ-181 (done) specifies `webhook_subscriptions.secret` "stored hashed ...
never returned once created." REQ-183 (pending) specifies HMAC-SHA256 signing "using
the subscription's stored secret (REQ-181's schema)." **A hash is not usable as an
HMAC key** — HMAC requires the actual key material to compute a MAC that a verifier
holding the same key can reproduce; a one-way hash of that material cannot be
un-hashed back into it, so a signer holding only a hash could never produce the
signature a legitimate verifier (also holding only a hash, or the plaintext
elsewhere) could check against. The two requirements' storage and consumption models
are structurally incompatible as separately drafted.

**Chosen resolution: `secret_ref`/`secret_key_id` columns on `webhook_subscriptions`,
superseding the hashed `secret` column — following R-Co's own fix.** R-Co hit this
identical problem and resolved it by adding `webhook_subscriptions.secret_ref` and
`.secret_key_id`, backfilling them, and blanking the plaintext column
(`GBL-128_exp501_secrets.sql`, with correctives
`1134_iss0112_add_secret_ref_to_tenant_schemas.sql` for tenant-schema scoping and
`1138_iss0635_webhook_secret_ref_corrective.sql` for a migration-ordering bug in the
first attempt). Concretely for Letflow:

- On `create/2` (REQ-181's context module), instead of hashing a caller-supplied or
  generated secret and storing only the hash, the plaintext HMAC signing key is
  written into the `secrets` table (namespace `"webhook"`, name = the subscription's
  id or a stable derived name, purpose `"webhook_hmac"`) via the mechanism §A–§E just
  decided, and `webhook_subscriptions` stores **`secret_ref`** (the
  `sec://tenant/<tenant>/webhook/<name>` reference string, unpinned — always resolves
  to the current active signing key) and **`secret_key_id`** (the pinned version, for
  a consumer that must keep verifying against the exact key used at delivery time,
  e.g. audit/replay).
- The response-shape contract REQ-181 already committed to (`hmac_secret_once`
  returned exactly once, on creation, never retrievable again) is **unchanged** — the
  plaintext is still shown to the caller exactly once at creation time; what changes
  is where it is durably stored afterward (the `secrets` table, resolvable by
  reference for signing) instead of only a one-way hash (which could never be used
  to sign anything again).
- The now-redundant hashed `secret` column: superseded, not left as a second home for
  the same key material (REQ-189's acceptance criteria explicitly forbid "two homes
  for the same key material in one stage"). It is dropped or blanked by a migration
  in whichever requirement implements this (REQ-190, named below) — this record does
  not write that migration itself (out of scope per REQ-189's own text).
- **REQ-190 is the requirement that implements this resolution** — REQ-190 must (a)
  add `secret_ref`/`secret_key_id` to `webhook_subscriptions` (superseding the hashed
  `secret` column, with a stated migration path for any already-created subscriptions
  from REQ-181's initial implementation — expected to be none yet in practice since
  REQ-183/184 depend on REQ-189 and REQ-181 only just merged, but the migration must
  handle the general case honestly rather than assuming an empty table), and (b)
  implement the `secrets` table itself, envelope encryption, and reference resolution
  per §A–§E.
- **This changes what REQ-181 specified** (the hashed-secret-only storage), which
  REQ-189's own acceptance criteria require stating explicitly and getting REVIEWER
  sign-off on: REQ-181's `create/2`/`update/2` behavior (the tenant-scoping, the
  ACTIVE/PAUSED reconciliation, `list/1`/`delete/2`) is **unaffected**; only the
  storage of the signing secret changes, from hash-only to reference-based envelope
  encryption. This is the same divergence needing sign-off as §B, tracked together
  below.

## Consequences

- `LETFLOW_SECRETS_MASTER_KEY` must be present, correctly formatted, and non-trivial
  in every environment that boots Letflow from REQ-190 onward, including CI/test —
  REQ-190's test setup must inject a real (test-only) 64-hex-char value; it must not
  weaken this record's startup-failure rule to make tests pass.
- The `secrets` table lives in `public`, not per-tenant schema — REQ-190's migration
  targets `public`, not a tenant-prefixed migration. Any future audit of "which tables
  are per-tenant" must treat `secrets` as a stated, sign-off-gated exception, not an
  oversight.
- REQ-181's `webhook_subscriptions.secret` column becomes dead weight the moment
  REQ-190 lands `secret_ref`/`secret_key_id` — REQ-190 owns retiring it.
- Nothing here blocks fronting `LETFLOW_SECRETS_MASTER_KEY` itself with a real
  KMS/HSM later (e.g. resolving the env var's value from a mounted secret rather than
  a raw environment variable) — that would change *how the 32 bytes are obtained*,
  not the envelope-encryption design this record settles, and is out of scope now.
- Decision 0014 (scripting-plugin runtime strategy) and any future OIDC
  client-secret storage should resolve through this same `secrets` mechanism
  (namespace-scoped references) rather than inventing a second secrets path — flagged
  here for whoever picks up plugin/OIDC credential storage next, not decided by this
  record.

## Open questions / gating

**This record's §B (global-vs-per-tenant placement) and §F (superseding REQ-181's
storage) both constitute a divergence from an existing decision/requirement, and
REQ-189's own acceptance criteria require REVIEWER sign-off recorded IN this file
before either is treated as settled — not merely noted and left for later.** That
sign-off has not yet been performed as of this writing. CODE-DESIGNER is flagging
this explicitly to ORCH: **route this record to REVIEWER for that specific sign-off
before it is treated as gating REQ-190/REQ-183/REQ-183's build**, per WF-02's normal
Step 1b design-validator gate plus this project's don't-silently-re-decide rule
(CLAUDE.md, core-directives.md). REVIEWER's sign-off, once given, should be appended
below as its own dated subsection — do not edit the Decision text above to retrofit
the appearance of prior approval.

## REVIEWER sign-off

**2026-08-30, WF02-REQ189-20260830 (ad-hoc gate, AGENT_ID REVIEWER).** Read this
record in full, independently, plus 0003 in full and REQ-181's requirements.yaml entry
(lines 9182-9242). Verdict: **SIGN-OFF GRANTED, both §B and §F**, no conditions.

**§B (global `secrets` table vs. Decision B's per-tenant-schema rule).** GRANTED.
0003 Dimension B's stated goal is explicit in its own text (line ~207): "a bug that
forgets a `tenant_id` predicate in a query fails loudly ... instead of silently
leaking rows." §B's argument is that for this one table, the schema boundary would
have to resolve *before* the reference's own tenant segment can even be checked
against the caller — collapsing `sec://tenant/<t>/...`'s self-describing tenant
segment into decoration, since a per-tenant-schema table would already have scoped
(or silently empty-result-failed) before any application check ran. Keeping `secrets`
global with `resolveSecret` checking `caller_tenant == reference_tenant` as its
*first* operation, before decryption, preserves the loud-failure property the general
rule exists for (an explicit `{:error, :tenant_mismatch}`, not a differently-shaped
loud failure, but not a silent leak either) while fitting the actual access pattern
(reference-based resolution across namespaces/consumers that don't already carry a
tenant-scoped connection). This is the same "explicit predicate, not inferred"
preference INV-1 already applies elsewhere — not a taste-based override of Decision B,
but an argued exception grounded in Decision B's own rationale, with R-Co's identical
choice as corroborating (not sole) evidence, exactly as CLAUDE.md's don't-silently-
diverge rule requires. Consequences correctly names this a "stated, sign-off-gated
exception," not a silent drop of the general rule for future tables — that scoping
is essential and is what makes this GRANTED rather than a weakening of the general
rule itself, which remains schema-per-tenant.

**§F (superseding REQ-181's hashed `secret` column with `secret_ref`/`secret_key_id`).**
GRANTED. The structural claim holds: HMAC-SHA256 requires the verifier/signer to hold
the actual key bytes to compute a reproducible MAC; a one-way hash is cryptographically
irreversible by design, so a signer holding only `hash(secret)` cannot produce
`HMAC(secret, payload)` — there is no routing-around this within REQ-181's schema as
drafted; any construction that kept only a hash durably stored and still produced a
valid HMAC would itself be a crypto defect, not a design alternative. REQ-181's
requirements.yaml entry (line 9226) confirms `hmac_secret_once` was always meant as a
one-time reveal of the plaintext, so the resolution honors — does not weaken — that
existing contract; only the durable-storage destination changes. §F correctly scopes
the blast radius: `create/2`/`update/2`/`list/1`/`delete/2`, tenant-scoping, and
ACTIVE/PAUSED reconciliation are unaffected and REQ-190 is correctly named as owning
the migration that retires the now-dead hashed column, rather than this record
attempting to write that migration itself.

**Other charter checks.** Idiomatic-vs-crutch and supervision: N/A, no code exists yet
(decision-record-only artefact, no `lib/`/`priv/repo/migrations/` diff). Type-safety
gap worth flagging for whoever implements REQ-190: `status` (active/disabled/deleted)
and the `algorithm`/`wrapped_key_algorithm` metadata are specified here as plain
strings/enum values on a Postgres table — an `Ecto.Enum` for `status` (as 0003
Dimension A already establishes as the project's convention for status-like columns)
and a constrained enum for `wrapped_key_algorithm` would make the "claims a cipher
mode it doesn't run" class of bug (defect (b), this record's own Evidence) structurally
harder to reintroduce later when AES-KW support is genuinely added. Not blocking —
REQ-190's design should account for it. Scope creep: none found — §A-F stay within
what REQ-189/190/183 actually need now (envelope encryption, one table, one reference
syntax); the deferred grace-window dual-read (§E) and the OIDC/plugin-secrets
forward-pointer (Consequences) are correctly left as future work, not built ahead of
need.

<!-- End of REVIEWER sign-off, 2026-08-30. -->
