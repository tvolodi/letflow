# REQ-181 REVIEWER Report — PASS

**Scope:** `lib/letflow/webhooks.ex`, `lib/letflow/webhooks/subscription.ex`,
`priv/repo/migrations/20260829010001_create_webhook_subscriptions.exs`,
`lib/letflow/tenant_provisioning.ex` (registry-entry diff), reviewed against
`lib/letflow/design/req181-webhooks-core.md` and REQ-181's
`docs/requirements.yaml` entry.

## 1. Idiomatic vs. crutch

Plain Ecto context module, no process — matches `Letflow.Dlq`/`Letflow.Tasks`/
`Letflow.Identity` precedent exactly, including the `@type opts ::
[prefix: String.t()]` typedoc and `Keyword.fetch!(opts, :prefix)` convention.
No process/GenServer used to do a schema's job by hand. No finding.

## 2. Supervision

N/A — this requirement adds no process, so `Letflow.InstanceSupervisor`
isolation is unaffected. No finding.

## 3. Type-safety gaps

None worth filing. `status` is a closed `Ecto.Enum`
(`:ACTIVE`/`:PAUSED`); `update/3`'s `reconcile_status/1` resolves both
`:status` and `:is_active` inputs to one target atom *before* the
transaction, so no invalid intermediate state is representable in the DB.
The one runtime-only guard is `reconcile_status/1`'s disagreement/empty-attrs
branches returning `{:error, :invalid_status}` — this is caller-input
validation, not a state the type system could reasonably make
unrepresentable (the two keys arrive from an HTTP body a future REQ-182 will
decode), so no issue filed.

## 4. Scope creep

`git diff main...HEAD --stat` touches exactly: the migration, the schema
module, the context module, the tenant-scoped-migration-manifest registration
diff in `lib/letflow/tenant_provisioning.ex`, plus this run's own
handoffs/design/report artifacts. No route, controller, or Plug file. No
changes to `lib/letflow/dlq.ex`, `lib/letflow/identity.ex`, or any
REQ-176/177/178 file. `Letflow.Webhooks` exposes exactly `create/2`, `list/1`,
`update/3`, `delete/2`, and the private `get/2` helper — no delivery,
dispatch, or HMAC-signing code (correctly deferred to REQ-183/184). No
finding.

## 5. Decision-record consistency

Migration and schema both retain an intra-schema `tenant_id` column while
living inside each tenant's own Postgres schema (no `@schema_prefix`,
`prefix:` passed explicitly at every call site) — consistent with
`docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B, same
pattern `Letflow.Dlq`'s own migration/schema already establish. No finding.

## 6. Idiom cross-check: `Letflow.Webhooks` vs. `Letflow.Dlq`

- **Row-lock-then-check `Ecto.Multi`:** `update/3`'s `Multi.new() |>
  Multi.run(:subscription, fetch_and_lock) |> Multi.run(:apply, ...) |>
  Repo.transaction() |> unwrap_write_result()` is structurally identical to
  `Dlq.retry/2`/`discard/2`, including the `fetch_and_lock_*` helper shape
  (`where` + `lock("FOR UPDATE")` + `repo.one(prefix: prefix)`) and the
  `unwrap_write_result/1` clause pair (`{:ok, %{apply: x}}` /
  `{:error, _step, reason, _changes}`).
- **Tenant-id derivation:** `create/2` derives `tenant_id` from
  `opts[:prefix]` via `TenantProvisioning.tenant_id_for_schema_name/1`,
  never from caller attrs — matches `Dlq.enqueue/2` verbatim, including the
  `with {:ok, tenant_id} <- ...` wrapping.
- **id/not-found handling:** `Ecto.UUID.cast/1` first (no DB round-trip on a
  malformed id), then a scoped fetch — matches `Dlq.get/2`.
- **Secret hashing:** SHA-256 + `Base.encode16(case: :lower)`, `lf_whsec_`
  prefix generation via `:crypto.strong_rand_bytes(32)` — matches
  `Letflow.Identity`'s `hash_token_value/1`/token-generation idiom exactly
  (same algorithm, same encoding, same prefixed-random-hex shape).
- **Error tuple shapes:** `{:error, :invalid_id}`, `{:error, :not_found}`,
  `{:error, Ecto.Changeset.t()}` all match sibling modules' vocabulary.
  `{:error, :invalid_status}` is new but appropriately scoped to this
  module's own reconciliation semantics (no DLQ equivalent to name).

## 7. Design-vs-implementation fidelity

Checked field-by-field against `req181-webhooks-core.md`:

- Schema fields (§2.3) match the struct/migration exactly, including
  `created_at` (not `timestamps/1`) and no `@schema_prefix`.
- §3.3's reconciliation table reproduced exactly in
  `apply_status_update/3`'s four clauses: ACTIVE→ACTIVE and PAUSED→ACTIVE
  both clear `paused_at` to `nil`; PAUSED→PAUSED is a no-op (idempotent,
  preserves original `paused_at`); ACTIVE→PAUSED stamps a fresh
  `paused_at`. `reconcile_status/1`'s disagreement and empty-attrs branches
  both return `{:error, :invalid_status}` per the table's last two rows.
- §2.2/§3.1 secret handling: plaintext resolved before the changeset,
  `secret_hash` is the only persisted form, `hmac_secret_once` appears only
  in `create/2`'s return value and has no corresponding struct field
  (structurally impossible for `list/1`/`get/2` to leak it) — matches
  §2.3's "no such field on the struct at all" guarantee.
- No unresolved open question in §5 was silently implemented without
  comment; `update/3`'s real arity note (§3.3 vs. the `update/2` shorthand
  used in prose) is called out explicitly in both the design and this
  module's own moduledoc/spec, so it isn't a design/implementation
  mismatch, just documented prose shorthand.

## Verdict: PASS

No rework required. Forwarding to TEST-DESIGNER (Step 3).
