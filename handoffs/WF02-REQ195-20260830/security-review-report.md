# SECURITY-REVIEWER report — REQ-195 (WF02-REQ195-20260830)

**Verdict: PASS**

## 1. `Letflow.Tasks.assign_task/3` actor_id discrepancy — verified independently

Read `lib/letflow/tasks.ex` directly (not the design doc, not ELIXIR-DEV's claim).
Confirmed at line 475:

```elixir
@type assign_attrs :: %{required(:user_id) => String.t()}
```

No `actor_id` field anywhere in `assign_attrs`, `assign_opts`, or `assign_task/3`'s
body (lines 497-516). Only `claim_attrs` (line 371, used by `claim_task/3`) carries
`actor_id`. ELIXIR-DEV's claim is correct; the design's §3.2 table row for
`Letflow.Tasks.assign_task/3` was wrong on this point (third instance of this defect
class, as flagged).

Checked for an alternate route actor_id could reach `assign_task/3` through: grepped
callers of `assign_task(` across `lib/` — the only call site is
`lib/letflow/routers/tasks.ex`'s `handle_assign/1`. No non-router caller exists, and
the design's own AC11 forbids editing router files in this requirement. There is no
parameter, opts key, or process-dictionary/session mechanism anywhere in
`assign_task/3`'s real call chain that carries an actor id — `actor_id: nil` is the
only AC11-respecting disposition, identical reasoning to the already-approved
§3.1a/§3.1b dispositions. **Agree: nil is correct, not a gap ELIXIR-DEV should have
closed differently.**

## 2. Spot-checked actor_id assignments against real code (not just the design table)

- `Letflow.Engine.cancel_instance/3` (via `run_cancel_instance/5` →
  `record_instance_cancel_audit/4`, `lib/letflow/engine.ex` ~line 2890-2960): real
  `actor_id` threaded through `fetch_actor_and_idempotency_key/1` from `attrs`,
  required (`{nil, _} -> {:error, :missing_actor_id}`). Matches design.
- `Letflow.Engine.complete_task/3` (~line 1486-1590): `actor_id = Map.get(attrs,
  :actor_id)`, threaded into `record_task_complete_audit/4`. Matches design.
- `Letflow.Definitions.activate/2`/`deprecate/2`/`archive/2` (via
  `record_definition_audit/5`, line 1873): `actor_id: nil`, with an inline comment
  citing §3.1a and AC11. Matches design and disposition.
- All six `Letflow.Identity` functions (`create_user/2`, `update_user_profile/3`,
  `update_user_status/3`, `create_group/2`, `create_token/3`, `revoke_token/2`):
  grepped each — every one passes `actor_id: nil` into its `Audit.append_multi/4`
  call, each with an inline `§3.1b` comment. Matches design.
- `Letflow.Engine.create/2`: `actor_id: Map.get(attrs, :actor_id)` (line 1067,
  1281). Matches design ("already an explicit argument").

No further discrepancies found across these spot checks.

## 3. `verify_chain/2` recompute-before-linkage — traced adversarially, line by line

Read `lib/letflow/audit.ex` lines 251-302 directly.

```elixir
defp do_verify_chain([], _prev_recomputed_hash), do: {:ok, :valid}

defp do_verify_chain([%Entry{} = entry | rest], prev_recomputed_hash) do
  recomputed = compute_hash(fields_from_entry(entry))

  cond do
    recomputed != entry.chain_hash ->
      {:error, {:hash_mismatch, entry.id}}

    entry.prev_chain_hash != prev_recomputed_hash ->
      {:error, {:chain_broken, entry.id}}

    true ->
      do_verify_chain(rest, recomputed)
  end
end
```

- (a) `fields_from_entry/1` builds the hash-input struct entirely from `entry`'s own
  currently-loaded/stored columns (`entry.id`, `.tenant_id`, `.actor_id`, `.action`,
  `.resource_type`, `.resource_id`, `.timestamp`, `.before_state`, `.after_state`,
  `.trace_id`, `.prev_chain_hash`) — genuinely recomputed from stored content, not
  cached/trusted from insert time. Confirmed.
- (b) `recomputed != entry.chain_hash` compares against the entry's own **stored**
  `chain_hash` column. Confirmed.
- (c) This comparison is the *first* branch in the `cond`, evaluated before the
  `prev_chain_hash` linkage branch — recompute-then-compare happens strictly before
  linkage is checked. Confirmed.
- (d) The linkage check compares `entry.prev_chain_hash` (stored) against
  `prev_recomputed_hash` — the accumulator threaded through the recursion, which is
  set to `recomputed` (the previous entry's just-recomputed hash) only after that
  previous entry passed its own hash-mismatch check, and starts at `nil` for the
  first call. It is never the previous entry's stored `prev_chain_hash` and never
  the previous entry's stored `chain_hash` — only its freshly recomputed value.
  Confirmed.

**Adversarial trace of the exact two-entry tamper scenario named in the task:** edit
entry N's content (e.g. `after_state`) AND entry N+1's stored `prev_chain_hash` to
match a hash computed from N's tampered content, leaving N's own `chain_hash` column
unchanged (untouched, still the hash of N's *original* content). Walking
`do_verify_chain/2`: at entry N, `recomputed` is computed from N's now-tampered
columns, which will not equal N's stored `chain_hash` (still the original digest) →
`{:error, {:hash_mismatch, N}}` fires immediately, before N+1 is even examined. The
forged `prev_chain_hash` on N+1 is never reached — recursion stops at N. This defeats
the exact two-entry attack the task asked to trace: an attacker would additionally
have to recompute and overwrite N's own `chain_hash` to match the tampered content,
which requires knowing/reproducing the SHA-256 preimage relationship honestly (i.e.
is just "recompute the hash correctly," not a bypass) — the property holds.

Also confirmed by the actual adversarial test in `test/letflow/audit_test.exs` lines
190-239 ("modifying a persisted after_state directly... is caught as hash_mismatch"):
tampers `after_state` via raw SQL after disabling the immutability trigger, leaves
both hash columns untouched, asserts `{:error, {:hash_mismatch, id_1}}`, and
explicitly asserts `id_2` (the next entry) is *not* reported as `chain_broken` —
i.e. the test itself proves this is a genuine recompute check, not "any 2-row chain
fails." A second test (lines 241-271) independently exercises the true chain-broken
path (a deleted middle entry, content of surviving rows untouched) and gets
`{:chain_broken, id_3}}`, confirming the two error variants are distinguished
correctly, not conflated.

**Conclusion: verify_chain/2 genuinely implements recompute-before-linkage,
chained against the previous entry's recomputed (not stored) hash. This is the
single most safety-critical property in this requirement and it holds.**

## 4. DB-level immutability trigger — verified against real SQL

Read `priv/repo/migrations/20260830020001_create_audit_entries_tenant_scoped.exs`
lines 74-107. Two real triggers created per tenant schema:
`BEFORE UPDATE ... EXECUTE FUNCTION "<schema>".audit_entries_immutable()` and
`BEFORE DELETE ...` (same function), which unconditionally
`RAISE EXCEPTION 'audit_entries is immutable'`. This is a genuine PL/pgSQL trigger
function, not a no-op — confirmed by the migration's down-migration
(`DROP TRIGGER`/`DROP FUNCTION`) existing symmetrically, and by the test suite's own
behavior: `test/letflow/audit_test.exs` lines 99-113 issue raw
`Repo.query!/2` `UPDATE`/`DELETE` statements directly against `audit_entries` (not
through any Ecto changeset) and assert `Postgrex.Error` with message matching
`~r/audit_entries is immutable/` — this only passes if the trigger genuinely fires at
the DB layer. The adversarial hash-mismatch/chain-broken tests (lines 213, 220, 262,
268) must explicitly `DISABLE TRIGGER ALL` / re-`ENABLE TRIGGER ALL` around their own
tamper `UPDATE`/`DELETE` calls — if the trigger were a no-op, this disable/enable
dance would be pointless busywork; its presence and necessity is itself evidence the
trigger is real and blocking.

## 5. Same-transaction guarantee — verified at a real call site

Read `lib/letflow/definitions.ex` lines 1809-1861 (`insert_definition/3`, backing
`Definitions.create/2`). The `:audit` write (`record_definition_audit/5` at line
1830) is called **inside** the same `Repo.transaction(fn -> ... end)` anonymous
function that performs the `Repo.insert` of the new `ProcessDefinition` row, and on
`{:error, reason}` calls `Repo.rollback(reason)` (line 1838) — which aborts the
enclosing transaction, undoing the definition insert too. Also spot-checked
`Letflow.Tasks.assign_task/3` (line 512) and `Letflow.Engine.cancel_instance/3`
(line 103-104 relative to `run_cancel_instance/5`): both append the `:audit` step via
`Multi.merge/2` into the *same* `Ecto.Multi` pipeline submitted once to
`Repo.transaction/1` — not a second, separate transaction or a post-commit call.
Confirmed genuine in both idioms this design uses (`Multi`-based and raw
`Repo.transaction/1`-based).

## 6. AC11 — no router file touched

```
git diff --stat main...HEAD -- lib/letflow/routers/
```
returns empty (zero output). Confirmed independently — no file under
`lib/letflow/routers/` is added or modified by this branch.

## 7. INV-1..INV-8 gate

- **INV-1 (tenant isolation) — APPLIES, PASS.** New `audit_entries` table is created
  only inside `if prefix() do ... end` (migration lines 45-108); registered in
  `Letflow.TenantProvisioning`'s `@tenant_scoped_migration_manifest` (confirmed via
  `git diff` on `lib/letflow/tenant_provisioning.ex`, adding the
  `20_260_830_020_001`/`CreateAuditEntriesTenantScoped` tuple). Every query/insert in
  `lib/letflow/audit.ex` passes `prefix:` explicitly (`repo.insert(prefix: prefix)`,
  `Repo.one(query, prefix: prefix)`, `Repo.all(..., prefix: prefix)`) — no bare
  unscoped call. `tenant_id` is derived via
  `TenantProvisioning.tenant_id_for_schema_name/1` from the resolved `prefix`
  (`insert_entry/3` line 187), never accepted as a caller-supplied field on
  `entry_attrs()` (the type has no `tenant_id` key at all). (a)/(b)/(c) all satisfied.
- **INV-2 (server-side field authorisation) — NOT-APPLICABLE.** No API response
  surface exists yet (S4 not started); this requirement adds storage only, no route.
- **INV-3 (untrusted runtime sandboxing) — NOT-APPLICABLE.** S5 not started; unrelated
  to this diff.
- **INV-4 (secrets by reference only) — APPLIES, PASS.** Confirmed
  `Letflow.Audit.struct_state/2`'s call sites in `lib/letflow/identity.ex`:
  `create_user`'s `after_state` excludes `:password_hash`;
  `create_token`/`revoke_token`'s before/after states exclude `:token_hash`
  (grepped `struct_state(.*password_hash\|token_hash` across `identity.ex` — present
  at every relevant call site). No secret is logged, traced, or serialised into any
  handoff/audit payload. The migration's `execute/1` SQL interpolates only
  `prefix()`, a migration-resolved constant, never a runtime/tenant-controlled value —
  no INV-4 concern there either (that's actually INV-7's territory, checked below).
- **INV-5 (not-found/forbidden indistinguishability) — NOT-APPLICABLE.** No
  lookup-by-ID endpoint exists yet (S4 not started).
- **INV-6 (new data-access path proves its scoping) — APPLIES, PASS.** This report
  itself is the proof-of-scoping artifact INV-6 requires; INV-1 above states which
  mechanism applies and how it's satisfied.
- **INV-7 (no SQL string interpolation) — APPLIES, PASS.** The migration's `execute/1`
  calls interpolate `"#{schema}"` where `schema = prefix()` — this is a
  migration-time value Ecto itself resolves per tenant-schema-provisioning run, never
  a runtime request/tenant-controlled value reaching this code path from external
  input (there is no HTTP/API path that re-invokes this migration's `execute/1` at
  request time — migrations run once per schema provisioning). Confirmed via reading
  the migration source directly (not the design doc's claim). No `Repo.query`/
  `Ecto.Adapters.SQL.query` calls exist anywhere in `lib/letflow/audit.ex` or the new
  migration outside this already-covered trigger-creation SQL — `insert_entry/3` uses
  only `Ecto.Query`/`Repo.insert`/`Repo.one`, fully parameterised by construction.
  (Other `Repo.query!` hits found by the INV-7 grep — `sandbox_pool.ex`,
  `tenant_provisioning.ex` L259/273, `fixture_loader.ex` — are all pre-existing code
  untouched by this diff; not in scope for this review.)
- **INV-8 (no unhandled crashes on realistic failure paths) — APPLIES, PASS.** Traced
  every new/changed write path: six Identity functions' new `Multi`s unwrap
  `Repo.transaction/1`'s `{:error, failed_step, reason, changes}` envelope back to
  each function's own `{:error, reason}`/`{:error, changeset}` contract (per
  ELIXIR-DEV's summary, spot-checked in `identity.ex`'s Multi blocks above — no bare
  `{:ok, _} =` pattern introduced on these paths). `assign_task/3` uses
  `unwrap_write_result/1` after `Repo.transaction/1`, not a bare match.
  `insert_definition/3`'s `Repo.transaction(fn -> ... end)` uses `Repo.rollback/1` on
  every error branch, and the outer `case`/`rescue` handles both changeset and
  non-changeset error shapes plus a raised exception, converting to `{:error, _}`
  tuples — no unhandled crash surface introduced. The one bare-`{:ok, _} =` heuristic
  hit inside a REQ-195-adjacent file (`definitions.ex:1489`) predates this diff
  (confirmed: zero `+`/`-` lines from `git diff main...HEAD` touch
  `insert_variable_schema_rows/3`) and is unrelated to REQ-195's audit-write paths —
  out of scope for this review, not a REQ-195 defect.

## Scope test

This diff adds a new tenant-scoped migration/table and touches multiple tenant-data
write paths (Definitions/Engine/Tasks/Identity context modules) — squarely a
tenant-data path. Full INV-1..INV-8 review applies (see §7).

## Disposition carried forward to REVIEWER

- `assign_task/3`'s `actor_id: nil` disposition: **agreed correct**, same AC11 scope
  boundary as the already-approved §3.1a/§3.1b dispositions (see §1 above).
- `verify_chain/2`'s recompute-before-linkage property: **independently verified,
  holds** (see §3 above) — this is the requirement's single most safety-critical
  property and it is genuinely implemented as designed, not merely documented as such.
- DB trigger immutability and same-transaction guarantee: both independently verified
  against real SQL/code, not trusted from the handoff summary (see §4/§5).
- No new BLOCKER findings. All applicable invariants (INV-1, INV-4, INV-6, INV-7,
  INV-8) PASS. INV-2/3/5 correctly NOT-APPLICABLE (stages not started).
