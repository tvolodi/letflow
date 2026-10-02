# ISS-0977: SandboxPool RT-6 flake (recurrence of ISS-0881) — design

## 1. Scope

Fixes ISS-0977: `test/letflow/sandbox_pool_test.exs`'s RT-6 ("death path c")
intermittently fails its `refute MapSet.member?(final, o_schema)` assertion under
full-parallel-suite CI load. Root cause (ISSUE-FIXER, confirmed by reading
`lib/letflow/sandbox_pool.ex` in full): `drop_schema/1` (~976-986) retries a failed
`DROP SCHEMA` exactly once; on an `:orphan`-purpose drop (no live owner, so nobody can
ever retry it later — `complete_op/3`'s `:orphan`/`{:error, :release_failed}` branch,
~line 730, explicitly does not re-enqueue), exhausting that one retry under CI's heavy
concurrent-Postgres-connection load permanently leaks the schema. ISS-0048's own
"slot before schema" trade-off already accepts this as *possible*; RT-6 asserts it
*never happens*, with no mechanism in the test to distinguish "genuinely broken" from
"real Postgres had an unlucky day."

## 2. Option analysis (ISS-0977 acceptance criterion 1)

**(a) Widen `drop_schema/1`'s orphan-path retry budget alone.** Real, honest
mitigation — more attempts with backoff genuinely cuts the probability of hitting two
(now N) *consecutive* transient failures. But by itself this is dishonest if presented
as "fixes" RT-6: it only narrows the flake window. CI's own Postgres contention is not
under this codebase's control, so no finite retry budget makes the assertion
*deterministically* true. Adopted, but not alone — see §3.

**(b) Loosen RT-6 to tolerate the documented edge case, with deterministic fault
injection.** The issue is right that this must not be "loosen the assertion until it's
vacuous." The mechanism matters. Rejected as "modify RT-6 itself" because RT-6's job —
prove the *common* crash-recovery path leaves no schema behind — is still a real,
valuable, currently-passing-except-under-contention assertion; weakening its tolerance
is indistinguishable from suppressing the regression check. Adopted instead as **a new,
separate, deterministic test** that exercises exactly the retry-exhaustion branch RT-6
cannot reach on demand — see §4. This reuses a mechanism this very test file already
has, not a new one: `:sys.replace_state/2` injection of `in_flight` plus a direct
`send(pool, {fake_task_ref, result})`, exactly as
`describe "handle_info/2 survives an unrecognized worker result (ISS-0226 regression...)"`
(~line 1429 onward) already does to simulate a worker's return value without a real
Task or real Postgres fault. No new production test-seam is needed: the pool already
treats a worker's return value as untrusted input arriving over its own mailbox, which
is precisely the API surface this injection exploits.

**(c) A reconciliation/sweep mechanism.** No sandbox-schema reaper exists today (the
only reaper in the tree, `Letflow.TenantSchemaReaper`/`test/support/tenant_schema_reaper.ex`,
reconciles `Registration` rows for *tenant* schemas, not ephemeral sandbox ones, and is
test-support code, not production). Building a new production sweep subsystem — its own
scheduling, its own failure modes, its own SECURITY-REVIEWER pass over a second
tenant-schema-lifecycle code path — is disproportionate to a MAJOR *test-flake* issue
whose underlying leak is already an ISS-0048-accepted, rare, non-customer-facing
trade-off (sandbox schemas carry no `Registration` row and no tenant data; a leaked one
is wasted storage, not a tenant-data exposure). Rejected for this issue. If ISS-0977's
own fix (§3) is later found insufficient (recurs a third time), a sweep becomes the
right escalation — noted as an open question in §7, not silently built now.

**Decision: (a) + (b), not (c).** Widen the orphan-path retry budget for genuine
production robustness (an orphaned sandbox schema is a real leak independent of any
test), and add a new deterministic test that locks in `complete_op/3`'s
accepted-leak contract so the previously wholly-untested exhausted-retry branch has
real regression coverage — coverage RT-6 structurally cannot provide, since RT-6 can
only trigger retry exhaustion by hoping for real CI contention.

## 3. `drop_schema/1`: widened, backoff-scoped retry for the orphan path

### 3.1 Why orphan-only, not every purpose

The existing single-retry behavior stays unchanged only for `:release`, the one
purpose sharing `drop_schema/1`'s call site (per `run_op/1` ~line 631 and
`complete_op/3`'s existing purpose-split ~line 711, 730) that has a real other recovery
path: INV-SP-5 lets the live owner retry `release/2` itself. Every other purpose —
`:orphan`, `:release_orphaned` (by the same "no live owner left" reasoning the
moduledoc already gives `handle_worker_death/1`'s drop clause), and `:reclaim`
(driven by a `:DOWN` the pool already observed once — same no-live-owner case as
`:orphan`: the `active` entry is deleted in the same `:DOWN` callback that enqueues
the `:reclaim` op, before the DROP ever runs, so nobody is left to retry it if this
drop fails either) — has *no* other recovery path if the drop ultimately fails, and so
folds into the same widened path. Widening the budget only where it is the sole chance
avoids changing the latency/behavior contract of the one path (`:release`) that
already has a correctness story.

**Correction (CODE-DESIGN-VALIDATOR gap on ISS-0977): a third call site, no `op` in
scope.** Reading `provision_sandbox/2` directly (~938-967) shows its `rescue` clause
(~966) calls `drop_schema(schema_name)` as best-effort compensating cleanup for a
half-created schema *during provisioning itself* — before any `:drop` op, any
`in_flight.op`, and any `purpose` field ever exist. This is not a third `run_op/1`
branch (`run_op/1` has exactly one `{:drop, ...}` clause, ~line 631, shared by every
purpose); it is a wholly separate call path with no op map to read a purpose out of.

Is this the same "no live owner, no other recovery path, leak is permanent" class as
`:orphan`/`:release_orphaned`? Yes, by inspection of the actual rescue clause: the
schema this cleans up was never added to `state.active` (provisioning hadn't
succeeded yet) and was never enqueued as a tracked `:drop` op, so nothing in this
module — no `release/2` caller, no `:DOWN`-triggered reclaim, no later retry of
anything — will ever get a second chance at it if this cleanup's own DROP fails.
That is architecturally identical to `:orphan`'s justification above, not merely
similar to it.

**Decision: give it the wide budget, under its own purpose atom `:provisioning_rescue`,
not by reusing `:orphan`.** It earns the same retry budget as `:orphan`/
`:release_orphaned` for the reason just given, but it is kept as a distinct atom
rather than folded into `:orphan` because the two are observably different events:
`:orphan` denotes a tracked `:drop` op the pool queued for a schema that once lived in
`state.active` (a worker died or an owner failed to release); `:provisioning_rescue`
denotes a schema that never left provisioning, dropped inline inside
`provision_sandbox/2`'s own rescue, with no op, no queue entry, and no `in_flight`
record ever created for it. Logging and any future metrics/alerting on "why did we
drop this schema" would be actively misleading if a provisioning-time rescue showed up
labeled `:orphan`. `drop_schema/2`'s retry-budget dispatch (§3.2) therefore matches on
`purpose in [:orphan, :release_orphaned, :provisioning_rescue]` for the wide path,
keeping the atom distinct while keeping the budget shared.

### 3.2 New retry shape

- `drop_schema/2` (purpose-aware; `purpose: :orphan | :release_orphaned |
  :provisioning_rescue | :reclaim` gets the wide budget, `:release` alone keeps
  today's single retry via the same code path — one function, not two divergent
  implementations, with the existing 1-retry case expressible as the wide path's own
  `attempts: 2` floor). `:provisioning_rescue` is a new purpose atom, not a reuse of
  `:orphan` — see §3.1's correction for why it is kept distinct despite sharing the
  wide retry budget.
- Config-driven, following this module's existing
  `config :letflow, :sandbox_pool, provision_timeout_ms: n` idiom (same
  `Application.get_env/2` + validated-default pattern as `provision_timeout_ms/0`,
  ~line 227):
  - `config :letflow, :sandbox_pool, orphan_drop_max_attempts: n` — default **4** total
    attempts (i.e. 3 retries beyond the first, up from today's 1).
  - `config :letflow, :sandbox_pool, orphan_drop_backoff_ms: [n1, n2, n3, ...]` — default
    `[25, 75, 200]` (one entry per retry after the first; a list shorter than
    `max_attempts - 1` reuses its last element). Sleeps run inside the worker `Task`,
    never inside a pool callback (ISS-0224's invariant is untouched — `Process.sleep/1`
    here costs the worker, not the pool's mailbox).
- New public accessor `orphan_drop_retry_schedule() :: {max_attempts :: pos_integer(),
  backoff_ms :: [non_neg_integer()]}`, mirroring `provision_timeout_ms/0`'s
  "public so tests/callers derive from one source of truth" rationale — RT-6's
  `wait_until_schema_dropped/2` default timeout should likewise be re-derived from this
  (today it is `release_call_timeout() * 2`, already generous relative to the new
  worst-case added latency of `25+75+200 = 300ms`, but deriving it explicitly removes a
  second place this number could silently drift out of sync).
- Error/return shape unchanged: still `:ok | {:error, :release_failed}` after the
  budget is exhausted — `complete_op/3`'s `:orphan` branch (§3.3) needs no match-shape
  change, only its comment.

### 3.3 `complete_op/3`'s `:orphan` branch — comment-only change

No behavioral change to the branch itself (still no re-enqueue on exhaustion — INV-SP-DOWN-3
is unaffected: the slot is freed regardless, never held hostage by a stuck DROP). Its
inline comment must be updated to say the leak is now reached only after the widened
budget (§3.2) is exhausted, pointing at this design doc and ISS-0977 rather than only
ISS-0048, so a future reader does not mistake the still-possible leak for an
unaddressed gap.

### 3.4 Honesty about what this does and does not achieve

This narrows the flake window; it does not zero it. Four consecutive transient
Postgrex/DBConnection failures against one schema, each ~tens of ms apart, is a
materially rarer event than two, but "materially rarer" is not "impossible" — CI
contention is a variable this codebase does not control. §4's deterministic test exists
precisely because this residual probability can never be asserted to zero by a retry
count alone.

## 4. New deterministic test: `complete_op/3`'s exhausted-retry orphan contract

New `describe` block in `test/letflow/sandbox_pool_test.exs`, placed near the existing
ISS-0226 `:sys.replace_state/2`-injection block (~line 1429) it directly reuses the
idiom from. Not a modification of RT-6 — RT-6 is untouched except for re-deriving its
timeout constant from §3.2's new accessor.

### 4.1 Mechanism (deterministic, no real Postgres fault needed)

1. Create one real schema directly via `Repo.query!/1` (bypassing the pool entirely —
   this test owns its lifecycle start to finish), named with the pool's own
   `"sandbox_" <> hex` convention so it is indistinguishable from a pool-minted one for
   every assertion that matters.
2. `:sys.replace_state(pool, fn state -> %{state | in_flight: injected_in_flight} end)`
   with an `in_flight` map whose `op` is `{:drop, %{schema_name: ..., sandbox_id: ...,
   from: nil, owner_ref: nil, purpose: :orphan}}` and a fabricated `task_ref` — the
   exact shape the ISS-0226 block already constructs for a `:provision` op and a
   `:drop, purpose: :release` op; this test adds the `:drop, purpose: :orphan` case
   that block does not cover.
3. `send(pool, {fake_task_ref, {:error, :release_failed}})` — the exact worker-result
   shape `drop_schema/2` returns once its widened (§3.2) budget is exhausted, injected
   directly rather than actually exhausting four real attempts. This is a simulation of
   `run_op/1`'s return value, the same contract boundary the ISS-0226 tests already
   exploit, not a new seam into production code.

### 4.2 Assertions (the accepted-leak contract, made explicit and tested)

- `Process.alive?(pool)` — the pool survives an exhausted orphan drop.
- `:sys.get_state(pool).in_flight == nil` — bookkeeping clears.
- No new `:drop` op appears in the pool's queue/state afterward (mirrors
  `queued_provision_ops/1`'s existing pattern for drop ops) — proves `complete_op/3`
  does **not** re-enqueue on exhaustion, i.e. INV-SP-DOWN-3 holds and this is not an
  infinite-retry loop in disguise.
- The schema **still exists** in real Postgres (`schema_exists?/1`) — the leak the
  issue describes is real, is reached, and is exactly what §3.3's updated comment
  documents; this test would catch a future change that silently started retrying
  forever (an availability risk) just as readily as one that silently stopped freeing
  the slot (the original ISS-0048/ISS-0224 regression shape).
- A subsequent `SandboxPool.claim/2` + `SandboxPool.release/2` round-trip still works —
  the slot genuinely came back despite the schema leak.
- `on_exit` drops the schema directly (this test created it outside the pool, so
  nothing else will clean it up) — reuses `drop_schema_escaped!/1`'s sibling,
  `drop_schema!/1`, already in the file for this exact "test-created, not
  pool-created" cleanup shape.

### 4.3 Why this is not "just a different flaky test"

Nothing in §4.1 depends on real timing, real contention, or a race against a real
worker — every existing `:sys.replace_state/2` test in this file (ISS-0226's block) has
run deterministically since it was written, which is the direct precedent for this
claim.

## 5. Acceptance-criteria mapping

| ISS-0977 acceptance criterion | Design element |
|---|---|
| "Decide: widen retry budget... or loosen assertion... or another fix" | §2 decision: (a)+(b), (c) explicitly rejected with reasoning |
| "Root cause genuinely addressed, not just flake suppressed" | §3 is a genuine production robustness change (reduces real leak probability, not just test tolerance); §4 adds net-new regression coverage for a branch that had none, rather than removing coverage from RT-6 |

## 6. Cross-module dependencies

- `lib/letflow/sandbox_pool.ex`: `drop_schema/1` → `drop_schema/2`, exactly two call
  sites (confirmed by reading both directly, not inferred — `grep -n "drop_schema("`
  finds no others):
  - `run_op/1`'s single `{:drop, ...}` clause (~line 631) — the only `:drop` clause
    `run_op/1` has; it does not branch per purpose today. Changes from
    `defp run_op({:drop, %{schema_name: schema_name}}), do: drop_schema(schema_name)`
    to destructure and forward `purpose` from the op map it already receives:
    `defp run_op({:drop, %{schema_name: schema_name, purpose: purpose}}), do:
    drop_schema(schema_name, purpose)`. This one clause carries all four existing
    purposes (`:release`, `:reclaim`, `:release_orphaned`, `:orphan`) through to
    `drop_schema/2`, which internally dispatches the retry budget per purpose.
  - `provision_sandbox/2`'s `rescue` clause (~line 966) — has no `op` and no `purpose`
    in scope (this cleanup runs before any `:drop` op or `in_flight` record exists;
    see §3.1's correction). Changes from `drop_schema(schema_name)` to
    `drop_schema(schema_name, :provisioning_rescue)` — a literal atom passed directly
    at the call site, not read out of any map, since none exists here.

  Also: new `orphan_drop_retry_schedule/0` public accessor, `complete_op/3`'s
  `:orphan` branch comment only (no behavioral change there — the rescue clause above
  never reaches `complete_op/3` at all, since it isn't a queued op).
- `config/*.exs` (wherever `:letflow, :sandbox_pool` is configured today, alongside
  `max_concurrent_sandboxes`/`provision_timeout_ms`): two new optional keys,
  `orphan_drop_max_attempts`, `orphan_drop_backoff_ms`, both defaulted — no existing
  config file is required to change.
- `test/letflow/sandbox_pool_test.exs`: new `describe` block (§4); RT-6's
  `wait_until_schema_dropped/2` default-timeout expression re-derived from
  `orphan_drop_retry_schedule/0` instead of a hand-maintained multiplier.
- No change to `lib/letflow/tenant_provisioning.ex`, `lib/letflow/definitions.ex`, or
  any caller of `SandboxPool.claim/2`/`release/2` — the public API and every reply
  shape are unchanged.

## 7. Invariants (restated, unaffected) and open questions

- INV-7 (identifier-injection safety): unchanged — `schema_name` passed to
  `drop_schema/2` is still always either `mint_sandbox_identity/0`-derived or read back
  from `state.active`, never caller-supplied, and the interpolation itself is
  untouched. §4's test creates its own schema with the same naming convention via the
  same non-caller-facing path (direct `Repo.query!/1` in test code, not through any
  public API).
- INV-SP-DOWN-3 (a stuck DROP never holds a slot hostage): unaffected, restated in §3.3
  and now directly tested (§4.2).
- Open question (explicit, not silently resolved): should `orphan_drop_max_attempts`
  default to 4, or some other number? This design picks 4 attempts / `[25, 75, 200]`ms
  backoff as a reasonable, cheap starting budget (worst case +300ms of added latency on
  a path nothing synchronous is waiting on), but has no measured CI-contention
  distribution to size it against the way `provision_timeout_ms`'s own derivation doc
  (iss0220) did. If ISS-0977 recurs a third time after this fix ships, that is the
  signal to (a) re-measure and widen further, or (b) stop treating this as a tuning
  problem and build the reconciliation sweep rejected as disproportionate in §2(c) —
  not to re-loosen RT-6 or the new §4 test.
- Open question: `orphan_drop_backoff_ms`'s "reuse last element if list shorter than
  attempts" rule is this design's choice for configurability without requiring callers
  to size the list exactly — ELIXIR-DEV should confirm this is the least-surprising
  shape or propose a cleaner one (e.g. a `(attempt_number -> ms)` function) if the list
  form proves awkward to implement.

## 8. SECURITY-REVIEWER — explicit call: NOT required as a hard gate

This change touches tenant-schema-lifecycle code (`drop_schema/1`'s `DROP SCHEMA...
CASCADE`) but:

- Does not change identifier handling — no new caller-controllable input reaches the
  SQL text; INV-7's existing argument (`schema_name` is always pool-minted or read back
  from internal state) is untouched.
- Does not add a new API surface, new route, or new response shape — `claim/2`/
  `release/2`'s contracts are unchanged.
- Only changes a retry *count* and adds `Process.sleep/1` backoff *inside an existing
  worker Task* that already runs this exact DROP statement today.
- §4's new test manipulates only test-local `GenServer` state via `:sys.replace_state/2`
  (test-only, not shipped code) and a message already in the pool's documented worker-
  result contract — no new production test-seam.

Given no new injection vector, no new tenant-data exposure, and no new production code
path reachable from outside the pool's own worker-Task boundary, SECURITY-REVIEWER is
not required as a hard gate for this change. REVIEWER (OTP idiom, since this adds
`Process.sleep/1`-based backoff and purpose-conditional retry control flow to a worker
function, and supervision integrity is otherwise unaffected) remains required, as for
any `lib/letflow/` change.
