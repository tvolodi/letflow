# REQ-181 ELIXIR-DEV implementation notes

Implemented exactly per `lib/letflow/design/req181-webhooks-core.md` (design
gate PASSED, see `handoffs/WF02-REQ181-20260829/step-01b-code-design-validator.json`).

## Files changed

- `priv/repo/migrations/20260829010001_create_webhook_subscriptions.exs` —
  new tenant-scoped migration, `if prefix() do ... end` guard (Decision B),
  same shape as `20260829000001_create_dlq_entries.exs`.
- `lib/letflow/webhooks/subscription.ex` — new `Letflow.Webhooks.Subscription`
  Ecto schema. `status` is `Ecto.Enum` (`:ACTIVE`/`:PAUSED`, stored
  uppercase). `secret_hash` column, never `secret`. No `hmac_secret_once`
  field on the struct at all (structural guarantee per design §2.3).
- `lib/letflow/webhooks.ex` — new `Letflow.Webhooks` context module:
  `create/2`, `list/1`, `update/3`, `delete/2`, private `get/2`.
- `lib/letflow/tenant_provisioning.ex` — registered
  `Letflow.Repo.Migrations.CreateWebhookSubscriptions` in
  `@tenant_scoped_migration_manifest` (both the migration's own guard and
  this registry entry are mandatory per that module's own discipline).
  Also updated the manifest's descriptive moduledoc paragraph to mention
  REQ-176/REQ-181 (it was already slightly stale before this change, missing
  REQ-176's entry) and pointed the count claim at
  `@tenant_scoped_migration_manifest` itself rather than restating a number
  that will go stale again.

## Secret handling

Followed `lib/letflow/identity.ex`'s `generate_token_plaintext/0` /
`hash_token_value/1` mechanism exactly (`:crypto.strong_rand_bytes(32)` +
`Base.encode16(case: :lower)` for the plaintext, `:crypto.hash(:sha256, _)`
+ `Base.encode16(case: :lower)` for the hash), with the literal prefix
`"lf_whsec_"` (design §2.2 says this substitution is not load-bearing).
`create/2` returns `{:ok, %{subscription: subscription, hmac_secret_once:
plaintext}}` — the plaintext exists only in this one return value.

## update/3 reconciliation

Implemented the full table from design §3.3: `%{status: "ACTIVE"|"PAUSED"}`,
`%{is_active: true|false}`, both agreeing, both disagreeing
(`{:error, :invalid_status}`), invalid status string
(`{:error, :invalid_status}`), and empty attrs (`{:error, :invalid_status}`).
Uses the same row-lock (`SELECT ... FOR UPDATE`) + `Ecto.Multi` idiom as
`Letflow.Dlq.retry/2`/`discard/2`. Idempotent re-pause (`:PAUSED` -> `:PAUSED`)
does not push `paused_at` forward — returns the row unchanged without an
UPDATE.

## Deviations from the handoff's literal function names

The task description said `update/2`/`delete/2`; the design document itself
(§3.3) clarifies the real arity is 3 for `update` (`update/3`, opts is the
third param, same "prose shorthand" note `req176-dlq-core.md` uses for
`enqueue/1`). Implemented as `update/3` and `delete/2` per the design's own
explicit `@spec`s in §3.3/§3.4 — the design document is the authority per
this run's own Step 2a handoff instruction ("Implement lib/letflow/design/req181-webhooks-core.md exactly").

## Verification run in this session

- `mix compile --force --warnings-as-errors` — clean, no warnings, no
  errors (real output: "Compiling 142 files (.ex)" / "Generated letflow
  app").
- `mix format` — applied to all four changed/added files; a following
  `mix compile --warnings-as-errors` was still clean.
- `git diff --cached --stat` against this branch's prior tip confirms only
  the migration, the two `lib/letflow/webhooks*` files, and
  `lib/letflow/tenant_provisioning.ex` changed — no route/controller file.

## Out of scope, not touched

No route, controller, or Plug module (REQ-182). `lib/letflow/dlq.ex`,
`lib/letflow/identity.ex`, and REQ-176/177/178 files were not modified.

## What SECURITY-REVIEWER should focus on

1. **Secret never exposed after creation.** `Subscription.t()` structurally
   has no `hmac_secret_once`/plaintext field (see `subscription.ex`
   moduledoc + `@type t`) — `list/1`, `update/3`, `delete/2`, and the
   private `get/2` all return only `Subscription.t()` values. Only
   `create/2`'s own return tuple carries the plaintext, once.
2. **Tenant scoping.** Every function takes `opts :: [prefix: String.t()]`
   and never accepts `tenant_id` from caller attrs — it's derived via
   `Letflow.TenantProvisioning.tenant_id_for_schema_name/1`. `list/1` relies
   on the Postgres schema-per-tenant boundary (Decision B), not a `WHERE
   tenant_id = ...` filter.
2b. Confirm the migration's `if prefix() do ... end` guard and its
    `tenant_scoped_migrations/0` registry entry are both present and
    correctly paired (a mismatch here is the failure mode the codebase's own
    docs call out repeatedly).
3. **Hashing correctness.** `secret_hash` is SHA-256 hex (lowercase) of the
   plaintext, computed via `:crypto.hash/2` before any DB write; the
   plaintext is never `cast/3`-ed into any changeset (`insert_changeset/2`
   only accepts `:secret_hash`, never a `:secret` key).
