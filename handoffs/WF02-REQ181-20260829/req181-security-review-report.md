# REQ-181 Security Review — SECURITY-REVIEWER — Step 2c

**Verdict: PASS**

**Scope test.** Diff touches: a new migration creating a tenant-scoped table
(`priv/repo/migrations/20260829010001_create_webhook_subscriptions.exs`), a new
Ecto schema module (`lib/letflow/webhooks/subscription.ex`), a new context module
resolving/hashing a secret (`lib/letflow/webhooks.ex`), and a registry-entry diff in
`lib/letflow/tenant_provisioning.ex`. This is a tenant-data path (new tenant-scoped
table + secret-hashing mechanism) — SECURITY-REVIEWER gate applies. No route/plug/
controller file was added or modified (confirmed via `git diff main...HEAD --stat`
and by grepping for `Letflow.Routers`/`Plug` references — none found in the four
files reviewed); INV-2/INV-5 (server-side field auth, not-found/forbidden
indistinguishability) are therefore correctly out of reach for this change — no
API-surface exists yet to check (REQ-182's territory).

## INV-1 — Tenant data isolation — APPLIES — PASS

- (a) Every `Letflow.Webhooks` function (`create/2`, `list/1`, `update/3`,
  `delete/2`, private `get/2`) takes `opts :: [prefix: String.t()]` and threads
  `prefix: prefix` into every `Repo` call: `Repo.insert(.., prefix: prefix)`,
  `Repo.all(.., prefix: prefix)`, `repo.one(.., prefix: prefix)` (inside the
  `Ecto.Multi.run` closure), `Repo.update(.., prefix: prefix)`,
  `Repo.delete(.., prefix: prefix)`, `Repo.get(Subscription, id, prefix: prefix)`.
  No call reaches `Subscription` without an explicit `prefix:`. `list/1`'s
  isolation is structural (schema-per-tenant), not a `WHERE tenant_id = ...`
  filter — matches `lib/letflow/dlq.ex`'s own `list/2` precedent exactly (same
  `Repo.all(query, prefix: prefix)` shape, no tenant predicate in the query).
- (b) Migration: `if prefix() do ... end` wraps both the `create table` and the
  index creation (`priv/repo/migrations/20260829010001_create_webhook_subscriptions.exs`
  lines 51-72) — the table is never created in `public` when tenant-scoped.
- (c) `tenant_id` is never accepted from caller attrs. `create/2` derives it via
  `TenantProvisioning.tenant_id_for_schema_name(prefix)` (line 82) and only then
  builds `insert_attrs` with that resolved value (line 87) — `create_attrs()`'s
  own `@type` has no `:tenant_id` key at all, so a caller-supplied value could
  never reach it even if attempted.
- Registry: `{20_260_829_010_001, Letflow.Repo.Migrations.CreateWebhookSubscriptions,
  "20260829010001_create_webhook_subscriptions.exs"}` is present in
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0` (confirmed via `git diff`
  on `lib/letflow/tenant_provisioning.ex`) — version, module, and filename all
  match the actual migration file. Guard and registry entry are both present and
  correctly paired.

## INV-4 — Secrets by reference only — APPLIES — PASS

- Read `lib/letflow/identity.ex`'s real `generate_token_plaintext/0` /
  `hash_token_value/1` (lines 897-903) directly rather than trusting the design
  doc's description: `"lf_tok_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))`
  and `:crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)`.
  `lib/letflow/webhooks.ex`'s `generate_webhook_secret_plaintext/0` /
  `hash_webhook_secret/1` (lines 113-119) use the identical mechanism —
  `"lf_whsec_" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))`
  and `:crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)` — same
  entropy (32 random bytes), same digest (SHA-256), same hex encoding
  (lowercase). No weakening versus the established precedent; only the string
  prefix differs (cosmetic, matching the existing `"lf_tok_"` vs `"lf_whsec_"`
  divergence already present between token/webhook-secret naming).
- `Subscription`'s schema (`lib/letflow/webhooks/subscription.ex`) has exactly
  one secret-adjacent field, `secret_hash :: String.t()` (line 61/81) — no
  `secret`/`hmac_secret`/`plaintext` field exists on the struct at all, so no
  struct instance can ever carry the plaintext, structurally.
- `create/2` (lines 79-105) is the only function that computes/handles the
  plaintext (`resolve_secret_plaintext/1`, local variable `plaintext`) and the
  only one that returns it, as `hmac_secret_once` in its `{:ok, %{subscription:
  ..., hmac_secret_once: plaintext}}` result (line 99). `list/1` (lines 137-146)
  returns bare `Subscription.t()` structs only — no `hmac_secret_once` key
  possible since it isn't a map, and no plaintext field exists to leak. `update/3`
  and `delete/2` similarly only ever return `Subscription.t()` structs, never a
  map with an `hmac_secret_once` key.
- No `Logger` call anywhere in `lib/letflow/webhooks.ex` or
  `lib/letflow/webhooks/subscription.ex` (confirmed via grep — zero hits) — the
  plaintext is never logged.
- `insert_changeset/2` (subscription.ex lines 103-109) casts
  `[:target_url, :secret_hash, :description, :event_types, :tenant_id]` only.
  `create_attrs()`'s own `@type` (webhooks.ex lines 54-59) has no `:secret_hash`
  key at all (only `:target_url`, `:secret`, `:description`, `:event_types`),
  and `insert_attrs` (lines 86-92) is a map built fresh by the context module —
  `attrs` itself is never passed through to the changeset — so there is no path
  for caller-supplied data to land in `secret_hash`; it is always the freshly
  computed `hash_webhook_secret(plaintext)` value.
- Config/env grep (per INV-4's standard command) turns up nothing new in this
  diff — no hardcoded secret literal anywhere in the four files.

## INV-7 — No SQL string interpolation — APPLIES — PASS

No `Repo.query`/`Repo.query!`/raw SQL anywhere in the diff — `lib/letflow/webhooks.ex`
uses only `Ecto.Query` composition (`import Ecto.Query`, `order_by/2`, `where/2`,
`lock/2`) and standard `Repo.insert/update/delete/all/get` calls, all parameterized
by construction. The migration uses only the `Ecto.Migration` DSL.

## INV-8 — No unhandled crashes on realistic failure paths — APPLIES — PASS

- `create/2`: `with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix)`
  — an `{:error, _}` from that call falls through the `with` and returns it,
  no bare match. `Repo.insert/2`'s result is exhaustively `case`-matched
  (`{:ok, _}` / `{:error, _}`).
- `update/3`: `id` casting and status reconciliation both go through `with`
  chains returning typed errors (`:invalid_id`, `:invalid_status`); the
  `Ecto.Multi` transaction result is unwrapped via `unwrap_write_result/1`,
  which pattern-matches both the success shape and the generic
  `{:error, _failed_step, reason, _changes}` failure shape — no path raises on
  a `Multi.run` step returning `{:error, _}` (`fetch_and_lock_subscription/3`
  returns `{:error, :not_found}` rather than raising on a nil row).
- `delete/2`/`get/2`: `Ecto.UUID.cast/1` result is `case`-matched for both
  `:error` and `{:ok, _}` — no bare `{:ok, id} = Ecto.UUID.cast(id)` pattern
  that could raise on a malformed id string.
- No unguarded `Repo.get!`/`Repo.one!`/bang-variant calls anywhere in the diff.

## Row-lock-then-check idiom (update/3) — no TOCTOU

`update/3`'s `Ecto.Multi` (`lib/letflow/webhooks.ex` lines 185-194) matches
`Letflow.Dlq.retry/2`/`discard/2`'s idiom exactly: `Multi.run(:subscription, ...)`
calls `fetch_and_lock_subscription/3`, which issues
`Subscription |> where([s], s.id == ^id) |> lock("FOR UPDATE") |> repo.one(prefix: prefix)`
— the row is locked as part of the same `SELECT` that fetches it, inside the
`Multi`'s transaction, before `Multi.run(:apply, ...)` ever inspects
`subscription.status` to decide the target write. No separate unlocked read
precedes the lock (there is no earlier `Repo.get`/`Repo.one` call on this id in
`update/3`'s path), so no window exists between "check status" and "lock row"
for a concurrent writer to interleave — this is the identical shape as
`Letflow.Dlq`'s `fetch_and_lock_entry/3`, which SECURITY-REVIEWER previously
verified race-free for REQ-176.

## Data leakage — no other return shape checked

`create/2`, `list/1`, `update/3`, `delete/2` — every return shape traced above
contains only `Subscription.t()` structs (no secret-bearing field exists on that
struct) or, for `create/2` alone, the one-time `hmac_secret_once` map key. No
function returns a raw `Ecto.Changeset` field list, raw DB row, or any other
shape that could carry `secret_hash` in a form indistinguishable from plaintext
(`secret_hash` itself is fine to return/read since it's a one-way hash, not
tenant-identifying secret material, and is not a field the design or contract
treats as forbidden to read back — the constraint is specifically on the
plaintext, satisfied above).

## INV-2, INV-3, INV-5 — NOT-APPLICABLE

INV-2 (server-side field auth) and INV-5 (not-found/forbidden
indistinguishability) require an API surface (S4) — none exists in this diff (no
route/controller/Plug added, confirmed). INV-3 (untrusted runtime sandboxing)
requires S5 scripting/plugins — not applicable to a CRUD context module.

## INV-6 — meta-invariant — satisfied by this handoff's own existence

This document is the required explicit per-invariant statement.

## Conclusion

All four applicable invariants (INV-1, INV-4, INV-7, INV-8) verified PASS by
direct code reading (not by trusting ELIXIR-DEV's implementation notes or the
design doc's own claims) against the real `lib/letflow/identity.ex` hashing
precedent and the real `lib/letflow/dlq.ex` scoping/locking precedent. No
defect found. Routing forward to REVIEWER (Step 2d) for the idiom/scope-creep
gate.
