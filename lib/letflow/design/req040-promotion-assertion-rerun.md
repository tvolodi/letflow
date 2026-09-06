PROVENANCE (historical, not current decision authority):
# Design: REQ-040 — Promotion assertion re-run orchestration (`assertion_rerun.zig`, PRM-06/07)

**Requirement:** REQ-040 (`docs/requirements.yaml:1875-1937`, stage S2,
`depends_on: [REQ-039, REQ-037]`, both `done`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ040-20260817`, WF-02 Step 1
**This document produces:** the exact `Letflow.Definitions.apply_promotion_assertion_rerun/6`
signature, `@spec`s, the `promotion_assertion_runs` migration schema, the
frozen-clock/seeded-RNG injection interface, the algorithm (numbered steps, not code), the
crash-safety mechanism decision (with the investigation evidence behind it), invariants,
cross-module dependencies, acceptance-criteria traceability, and open questions —
**no implementation code**. No function bodies, no `.ex`/`.exs` files. ELIXIR-DEV writes the
real version at Step 2a.

---

## 0. Sources read in full for this design

**Letflow project docs:** `docs/requirements.yaml` REQ-040 (1875-1937, full description + 6
acceptance criteria + `depends_on`); `docs/agents/instructions/core-directives.md`;
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1;
`docs/agents/shared/HANDOFF_PROTOCOL.md`; `docs/guides/backend_developer_guide.md` (§3.2
gen_statem-vs-plain-Ecto discipline, §3.5 error shapes, §3.6 SQL parameterization, §3.7
migrations); `docs/migration/stage-2-event-store-definitions.md` ("Early findings" —
process-vs-row framing, cited by this requirement's own crash-safety open question);
`docs/agents/instructions/security-invariants.md` INV-1 (tenant scoping/derivation), INV-7
(no raw SQL interpolation), INV-8 (typed results on external-I/O paths); `docs/anti-patterns.md`;
`handoffs/WF02-REQ040-20260817/step-00-git-setup.json` (the framing handoff, including its own
citation of req039's OQ-2 as the concrete crash-safety precedent to investigate).

**Letflow shipped code, read directly (not assumed):**

- `lib/letflow/sandbox_pool.ex` (full file, 275 lines) — `claim/2`, `release/2`, and
  critically the `handle_info({:DOWN, ...})` clause (155-164) and the `waiting` queue's own
  monitor lifecycle (§2 below traces exactly what this does and does not cover).
- `lib/letflow/sandbox_pool/fixture_loader.ex` (full file) — `load_fixtures_only/3`'s
  `@allowlist`, its `{:error, :invalid_table_name} | {:error, :invalid_schema_name} |
  {:error, :insert_failed}` error taxonomy, and its own transactional-atomicity contract
  (TRUNCATE+INSERT wrapped in one `Repo.transaction/1`).
- `lib/letflow/design/req039-sandbox-pool-fixture-loader.md` (full file) — §2's full
  process-vs-row resolution for `SandboxPool` itself, and **§11 OQ-2 verbatim**: "It does
  **not** handle a caller dying *after* successfully receiving a claim but *before* calling
  `release/1`... Left for REQ-040 (or a dedicated follow-up) to decide." This is the exact
  gap this design's §7 resolves.
- `lib/letflow/event_store.ex` (full file, 1141 lines) — confirmed `append/2`'s M1
  active-instance guard (`active_instance_guard/2`, lines 357-369) hard-fails
  `{:error, :instance_not_started}` for any `instance_id` with no live
  `instance_projections` row, and that `Registry.validate_payload/3` fails
  `{:error, :unknown_event_type}` for an unregistered `event_type` — both independently
  reconfirming the exact gap `lib/letflow/design/req038-promotion-rollback.md` and
  `lib/letflow/definitions/promotion.ex`'s own moduledoc already disclose for
  `DEFINITION_PROMOTED`/`DEFINITION_VERSION_ROLLED_BACK` (§9 below extends the same finding
  to `PROMOTION_ASSERTION_TEARDOWN_FAILED`).
- `lib/letflow/definitions.ex` (full file, 1259 lines) — confirmed `rollback_definition_version/4`
  is **already shipped** (REQ-038 is `done`, not merely designed) directly in this file, with
  its own `# === REQ-038 types ===` banner + `@doc` + function + a
  `# rollback_definition_version/4 helpers` banner further down. This is this design's
  structural precedent for where/how to add `apply_promotion_assertion_rerun/6` (§1).
  Also confirmed the exact reusable `event_appender_fun` type (559-570) and the
  `common_error()` type (124-126) already defined here — both reused verbatim, not
  redefined (§3).
- `lib/letflow/definitions/promotion.ex` (full file) — `promote_definition/3`'s
  `opts[:event_appender]`: `Keyword.fetch!/2`'d, **no built-in default**, called *after*
  the transaction commits, moduledoc explicitly disclosing the `DEFINITION_PROMOTED`
  unregistered-event-type / non-instance-scoped-`append` gap. The established convention
  this design's own `opts[:event_appender]` (§3, §9) follows exactly.
- `lib/letflow/definitions/promotion_review_store.ex` (full file) — confirmed
  `mark_review_applied/2`'s exact shape (`approved -> applied`, no gates, no
  `Letflow.Definitions.Promotion` dependency) and its moduledoc's own statement that "some
  future orchestrator — REQ-040 or later" calls `promote_definition/3` then
  `mark_review_applied/2`/`mark_review_failed/2`. Confirms REQ-040's own text: the apply
  pipeline's `assertions_failed == 0` gate check happens **outside** this design's own
  function, in that future orchestrator — this design does not build or modify the
  orchestrator, only documents the contract it must honor (§6).
- `lib/letflow/definitions/promotion_review.ex` + its migration
  (`priv/repo/migrations/20260816200001_create_promotion_reviews.exs`) — confirmed
  `promotion_reviews.id` is `:binary_id`, confirmed the tenant-scoped migration guard
  pattern (`if prefix() do ... end`), confirmed `promotion_reviews` itself carries **no**
  FK to `tenant(id)`/`users(id)` (cross-schema, no FK possible) but is a same-schema
  sibling table to whatever this design adds — meaning a **real** FK from
  `promotion_assertion_runs.review_id` to `promotion_reviews.id` **is** possible here
  (§4), unlike the `tenant_id` column.
- `lib/letflow/definitions/process_definition.ex` +
  `priv/repo/migrations/20260816193002_create_instance_definition_snapshots.exs` — the
  `references(:table, column: :id, type: :binary_id, on_delete: :nothing)` FK idiom and
  its accompanying reverse-lookup index (`idx_snap_definition`), reused verbatim in §4.
- `lib/letflow/tenant_provisioning.ex` (`tenant_scoped_migrations/0`,
  `@tenant_scoped_migration_manifest`, lines 235-289) — confirmed the **mandatory
  two-halves contract**: a tenant-scoped migration file must carry the `if prefix() do`
  guard **and** a matching entry in `@tenant_scoped_migration_manifest`, or it is either
  inert (registered-but-unguarded corrupts `public`; guarded-but-unregistered never runs).
  `promotion_assertion_runs` is a **new tenant-scoped table** — §4's migration and §8's
  cross-module dependency both require this manifest edit explicitly.

**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly:**

PROVENANCE (historical, not current decision authority):
- `src/definition/assertion_rerun.zig` (full file, 641 lines) — `applyPromotionAssertionRerun`'s
  complete body (idempotency INSERT/conflict-read, sandbox claim, the single `defer`-guarded
  release, fixture load, `replayAssertions`, the final `UPDATE`), `RunStatus`, `PromotionArtifact`,
  `AssertionRerunResult`, `AssertionRerunError`, `stripNonDeterministicFields`/`stripDotPath`,
  and `recordTeardownFailure`'s own `CASE WHEN status = 'failed' THEN 'failed' ELSE
  'teardown_failed' END` precedence rule (620-631) — reused verbatim in this design's §6/§7.
  **Confirmed empirically by tracing the function body, not assumed:** (a) `candidate_definitions`
  is declared on `PromotionArtifact` and freed in `deinit`, but **no call site in
  `applyPromotionAssertionRerun` ever reads it** — it is present in the struct shape but unused
  by this specific function (§5, §11 OQ-2). (b) `replayAssertions`'s own comment says outright:
  *"Placeholder result: non-empty payload simulates a passing assertion result. PRM-05
  follow-on will replace this with the real engine call"* — R-Co's own canonical
  implementation has no real assertion-evaluation engine wired in either; §6 below ports this
  placeholder faithfully rather than inventing a fictitious "real" evaluator this codebase has
  no engine to back. (c) On a sandbox-claim failure or a fixture-load failure, R-Co's own code
  returns the tagged error **without ever touching the `promotion_assertion_runs` row again**
  — the row is left at `status = 'running'` permanently. This is a genuine, disclosed gap in
  R-Co's own reference implementation, not something this design silently inherits uncritically
  — §7.4 explains why this design deliberately improves on it (fail-closed accounting) rather
  than porting the literal stuck-`running` behavior.
- `src/design/prm-batch1-promotion-assertion-rerun.md` — "PRM-06 design" §§1-7 and "PRM-07
  design" §§1-5 in full, per this requirement's own citation. §1's table schema, §4's
  `FrozenClockProvider`/Open question 1, §6's idempotency flow, and PRM-07 §1-3's
  `defer`/teardown-failure/green-gate contract are the primary sources this design ports.

---

## 1. Scope boundary

**In scope (per REQ-040's own six acceptance criteria):**

1. One new public function, **`Letflow.Definitions.apply_promotion_assertion_rerun/6`**,
   added directly to the existing `lib/letflow/definitions.ex` context module — **not** a
   new submodule. This placement is not a free choice: REQ-040's own `docs/requirements.yaml`
   description names the target literally as `Letflow.Definitions.apply_promotion_assertion_rerun/6`,
   the exact same top-level-module placement pattern `rollback_definition_version/4` (REQ-038,
   already shipped in this same file, §0) already established — a new submodule would be an
   unrequested, inconsistent divergence from that precedent.
2. One new Ecto schema module, `Letflow.Definitions.PromotionAssertionRun`
   (`lib/letflow/definitions/promotion_assertion_run.ex`), matching
   `Letflow.Definitions.PromotionReview`'s own file-placement precedent.
3. One new plain-struct module, `Letflow.Definitions.PromotionArtifact`
   (`lib/letflow/definitions/promotion_artifact.ex`), with nested `Assertion` and
   `CandidateDefinition` structs (§5) — the input shape `apply_promotion_assertion_rerun/6`
   consumes.
4. One new tenant-scoped migration, `promotion_assertion_runs`
   (`priv/repo/migrations/20260818090001_create_promotion_assertion_runs.exs`), **plus** the
   mandatory matching entry in `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`
   (§0, §4, §8) — both halves, per that module's own stated contract.
5. Reuse of REQ-039's already-shipped `Letflow.SandboxPool.claim/2`/`release/2` and
   `Letflow.SandboxPool.FixtureLoader.load_fixtures_only/3` as building blocks — not
   reimplemented (§7).

**Explicitly NOT in scope, not silently dropped:**

| Not built here | Owned by | Citation |
|---|---|---|
| The apply pipeline itself (the future orchestrator that calls `promote_definition/3` then `mark_review_applied/2`, gating on this function's own recorded `assertions_failed == 0`) | Not yet built anywhere — `promotion_review_store.ex`'s own moduledoc names it "some future orchestrator — REQ-040 or later" | §0, §6 |
| A real, working `event_appender` implementation wired to `Letflow.EventStore.append/2` | Deferred — same disclosed gap `promotion.ex`/`req038-promotion-rollback.md` already carry for `DEFINITION_PROMOTED`/`DEFINITION_VERSION_ROLLED_BACK`; `PROMOTION_ASSERTION_TEARDOWN_FAILED` is not a registered `event_type_registry` entry either (§9) | §0, §9 |
| A real assertion-evaluation/replay engine (PRM-05's "real engine call") | Not built anywhere in this codebase yet — no `src/simulation`-equivalent exists. This design ports R-Co's own placeholder faithfully (§6) | §0(b), §6 |
| `candidate_definitions`' actual consumption (loading candidate definitions into the sandbox as something other than ordinary `fixtures[]` rows) | Not built in R-Co's own traced function either (§0(a)) — field is passed through, available to a future custom `assertion_evaluator`, unused by the default one | §0(a), §5, §11 OQ-2 |
| A sandbox-leak reaper (PRM-07 AC5's `reclaimLeakedSandboxes`-equivalent) | Explicitly deferred by REQ-039's own OQ-2/OQ-3 to "REQ-040 or a dedicated follow-up" — this design inherits, not resolves, that deferral (§7.5) | req039 design §11 OQ-2/OQ-3, this design §7.5, §11 OQ-1 |
| An HTTP route (`POST /api/v1/promotions/{review_id}/run-assertions`) | S4 (no HTTP layer exists for any S2 requirement) | prm-batch1 §7 |

---

## 2. THE crash-safety open question — investigation and decision

REQ-040's own text mandates this be investigated, not silently assumed either way. This
section is that investigation and its resulting decision.

### 2.1 What R-Co's own contract actually requires

PROVENANCE (historical, not current decision authority):
`assertion_rerun.zig`'s header: teardown runs through a single `defer` "so it covers every
exit path (normal return, assertion failure, infrastructure error, panic unwind)." The
**preserved contract** (not the mechanism) is: a teardown failure records
`PROMOTION_ASSERTION_TEARDOWN_FAILED` + `status = teardown_failed`, but **never** converts a
passing run into a failure (PRM-07 AC2). Elixir has no direct `defer`-on-hard-kill equivalent.

### 2.2 Does `SandboxPool`'s own crash-safety already cover this? — traced directly, answer: NO

`sandbox_pool.ex`'s `handle_info({:DOWN, caller_ref, :process, _pid, _reason}, state)`
(lines 155-164) only fires for a caller matched in `state.waiting` — i.e. a caller **still
parked waiting for a free slot**, monitored via `Process.monitor/1` in
`handle_queue_or_reject/3` (line 187). The monitor is explicitly cancelled
(`Process.demonitor(caller_ref, [:flush])`) the moment that waiter is serviced
(`service_next_waiter/1`, line 201). **After a claim succeeds — whether granted immediately
(`handle_provision_now/1`) or via the wait-queue hand-off — no `Process.monitor/1` is ever
established on the claiming caller's pid.** `state.active` (`%{sandbox_id => schema_name}`)
carries no pid at all — confirmed directly against the state shape (line 112) and every
insertion into it (lines 172, 206).

This means: if the process that owns `apply_promotion_assertion_rerun/6`'s own call crashes
**after** a successful `SandboxPool.claim/2` but **before** calling `SandboxPool.release/2`,
`SandboxPool` has no mechanism to notice or reclaim that sandbox — it silently remains
"active," permanently consuming one of `max_concurrent_sandboxes`' slots. This is not a gap
this design introduces: it is **exactly** what req039's own design doc already names as
**OQ-2**, verbatim: *"Left for REQ-040 (or a dedicated follow-up) to decide."* The
investigation this requirement's own text asked for confirms empirically (by reading the
shipped source, not assuming) that there is **no free crash-safety to piggyback on** for this
specific failure mode — `SandboxPool`'s existing monitor exists for a different problem
(queued-waiter death, not post-claim owner death).

### 2.3 Decision: `try/rescue`, not a new supervised process — and why

**Adopted:** the claim→load-fixtures→replay→release→record-outcome span
(`apply_promotion_assertion_rerun/6`'s own steps 3-6, §7) is wrapped in one `try/rescue` that
(a) attempts a best-effort `SandboxPool.release/2` and (b) attempts a best-effort fail-closed
row update (§7.4) in its `rescue` clause, mirroring `activate/2`'s and
`rollback_definition_version/4`'s own already-shipped `try/rescue -> {:transaction_failed,
exception}` idiom in this exact file (§0). This covers: normal completion, a typed error
return from any step, and a **raised exception** anywhere in that span (matching two of
Zig's three `defer`-trigger classes: normal return and error return/panic-as-exception).

**Explicitly NOT covered, named rather than hidden (per this requirement's own instruction):**
a hard process kill (`Process.exit(pid, :kill)`), a BEAM node crash, or `System.halt/0` —
none of these run a `rescue`/`after` clause. This is the one class of exit Zig's `defer`
truly covers (via panic unwind) that Elixir's `try` genuinely cannot replicate for an
unrecoverable kill signal — stated explicitly, not silently assumed away.

**Why not a new supervised process (a `Task.Supervisor`-owned or dedicated
`GenServer`-per-replay process), given the requirement explicitly says not to assume either
answer:**

1. **AC6 requires disclosure, not resolution.** REQ-040's acceptance criterion 6 is:
   *"the moduledoc names the crash-safety/guaranteed-teardown open question explicitly."*
   It does not ask this design to build a mechanism that closes the gap completely — the
   requirement's own text states the same thing ("leaves the concrete crash-safety mechanism
   as an explicit open question for CODE-DESIGNER"). Building a full supervised-process
   solution here would be solving an unrequested problem, not the one AC6 actually measures.
2. **A plain `Task` would not help.** A default (linked) `Task` dies **with** its caller on a
   caller kill — it adds no isolation at all. Only `Task.Supervisor.async_nolink/3` combined
   with an explicit `Process.monitor/1` on the *task's own* pid from some **third**,
   independently-supervised process would genuinely decouple "caller dies" from "sandbox gets
   released" — but that third process is itself a new, permanently-running piece of
   supervision tree surface (a `SandboxReplaySupervisor`, effectively), which is a
   meaningfully larger architectural change than "add one function to a context module." This
   is precisely the shape of `docs/migration/stage-2-event-store-definitions.md`'s "Early
   findings" test for when a process-per-unit-of-work is warranted — and per that same
   document, the deciding factor is **backpressure/arbitration needing one serialization
   point** (the reason `SandboxPool` itself is a `GenServer`, §0), not "this operation touches
   an OS-level resource." A single, non-concurrent replay call has no arbitration need at all
   — nothing here is racing for a shared resource the way `SandboxPool.claim/1`'s
   quota-contention is. Building the supervision surface anyway, with no arbitration need to
   justify it, would be exactly the kind of scope creep `core-directives.md`'s
   Unblock-Everything/anti-scope-creep boundary warns against.
3. **The concrete, already-disclosed mitigation for the residual gap already exists as a
   deferred, named follow-up — reused, not reinvented.** PRM-07 AC5's
   `reclaimLeakedSandboxes`-equivalent reaper (sweep for orphaned claims past some staleness
   threshold) is the mechanism that *would* close this gap completely, and it is *already*
   deferred by req039's own OQ-2/OQ-3 to "REQ-040 or a dedicated follow-up." This design
   inherits that exact deferral rather than either building a reaper now (unrequested,
   REQ-040's ACs don't ask for one) or inventing a *different*, ad-hoc partial mitigation
   (a new supervised process) that would leave two competing crash-safety stories in this
   codebase instead of one coherent, already-named one.

**Net effect, stated plainly for REVIEWER:** `try/rescue` closes the gap for every exit path
this codebase's own test suite can actually drive (normal return, typed error, raised
exception) and for the *overwhelming majority* of realistic operational failures. It does
**not** close the gap for a hard kill/node crash — genuinely open, named in §11 OQ-1, and in
the `@moduledoc` per AC6.

---

## 3. `apply_promotion_assertion_rerun/6` — function signature

Added directly to `lib/letflow/definitions.ex`, in a new `# === REQ-040 types ===` /
`# === REQ-040 — Promotion assertion re-run ===` section, matching this file's own established
banner convention (§0).

```
@type assertion_rerun_status :: :passed | :failed | :teardown_failed

@type assertion_rerun_opts :: [
  prefix: String.t(),
  event_appender: event_appender_fun(),              # REUSED from §0 — already defined
                                                       # in this file (line 562-564), not
                                                       # redefined here.
  assertion_evaluator: assertion_evaluator_fun() | nil  # optional; defaults to §6's
                                                         # placeholder evaluator when
                                                         # omitted or nil
]

@type assertion_evaluator_fun ::
  (assertion :: PromotionArtifact.Assertion.t(),
   injection :: %{frozen_clock_ms: integer(), rng_seed: non_neg_integer()} ->
     {:ok, result_json :: String.t()} | {:error, term()})

@type assertion_rerun_result :: %{
  run_id: Ecto.UUID.t(),
  status: assertion_rerun_status(),
  assertions_total: non_neg_integer(),
  assertions_passed: non_neg_integer(),
  assertions_failed: non_neg_integer(),
  failing_assertion_ids: [String.t()],
  sandbox_id: Ecto.UUID.t() | nil,       # nil only on the sandbox-claim-failure path (§7.2)
  teardown_error: String.t() | nil,
  idempotent_hit: boolean(),             # true iff this call returned a cached row (AC1)
                                          # and claimed no sandbox
  teardown_event_appended: boolean()     # true when no teardown failure occurred (nothing
                                          # to append) OR the append succeeded; false only
                                          # when a teardown failure occurred AND
                                          # opts[:event_appender] itself also failed (§7.5)
}

@type assertion_rerun_error ::
  {:error, :sandbox_unavailable}
  | {:error, :provision_failed}
  | {:error, :fixture_load_failed}
  | {:error, :review_not_found}          # FK violation on review_id, mapped (§4, §7.1)
  | {:error, Ecto.Changeset.t()}         # unexpected insert_changeset/2 validation failure
  | common_error()                       # REUSED from §0 -- {:error, :invalid_schema_name}
                                          # | {:error, {:transaction_failed, term()}}

@spec apply_promotion_assertion_rerun(
        review_id :: Ecto.UUID.t(),
        plan_digest :: String.t(),
        artifact :: PromotionArtifact.t(),
        sandbox_pool :: GenServer.server(),
        max_wait_ms :: non_neg_integer(),
        opts :: assertion_rerun_opts()
      ) :: {:ok, assertion_rerun_result()} | assertion_rerun_error()
```

**Arity-6 rationale, stated explicitly (this requirement's own literal `/6` is a real
constraint, not decorative):** R-Co's own 7-parameter signature
(`allocator, pool, sandbox_pool, tenant_id, review_id, plan_digest, artifact`) has two
parameters with no Elixir analogue at all (`allocator` — Elixir is garbage-collected;
`pool` — `Letflow.Repo`'s own connection pool is global, never threaded explicitly, matching
every other function in this file) and one parameter (`tenant_id`) that this codebase's
established, project-wide convention (`docs/migration/decisions/0003-ecto-schema-strategy.md`'s
2026-08-17 addendum, reused by **every** function in this file — §0) forbids accepting
directly: `tenant_id` is always derived from `opts[:prefix]`, never a separate caller-supplied
argument, so a caller-supplied value can never disagree with the schema it's actually written
into. Dropping those three yields five (`sandbox_pool, review_id, plan_digest, artifact,
opts`) — this design adds a sixth, **`max_wait_ms`**, as its own explicit positional
parameter rather than folding it into `opts`, matching `SandboxPool.claim/2`'s own
`claim(max_wait_ms, pool)` shape exactly (the same "explicit wait window, not hardcoded to
PRM-06 AC5's illustrative 60 s" reasoning `SandboxPool`'s own design already established) —
this makes the sandbox-claim wait window fully test-controllable (a test can pass `0` or a
short window) without threading it through an opaque `opts` key. **No parameter carries a
default value** — all six are required positional arguments, matching this file's own
existing convention that no top-level context function in `definitions.ex` uses `\\`
defaults (§0); `/6` is the only generated arity.

**`opts[:event_appender]` is `Keyword.fetch!/2`'d — no built-in default**, same no-default
stance `promote_definition/3`/`rollback_definition_version/4` already established (§0, §9).
**`opts[:assertion_evaluator]` DOES have a built-in default** (`Keyword.get(opts,
:assertion_evaluator, &default_assertion_evaluator/2)`) — a deliberate divergence from the
`permission_checker`/`event_appender` no-default precedent, justified because R-Co's own
canonical implementation ships a working (if placeholder) default rather than having "no
data path to a real implementation" the way event-appending does (§0(b), §6).

---

## 4. `promotion_assertion_runs` migration schema

**File:** `priv/repo/migrations/20260818090001_create_promotion_assertion_runs.exs`
(timestamp sorts after every existing migration, including
`20260817181240_create_event_retention_policies.exs` — §0).
**Module:** `Letflow.Repo.Migrations.CreatePromotionAssertionRuns`
**Kind:** tenant-scoped (per-tenant schema) — **both halves of the mandatory contract**
(§0, `tenant_provisioning.ex`):

1. The migration file itself uses the `if prefix() do ... end` guard (matching
   `20260816200001_create_promotion_reviews.exs`'s own shape exactly).
2. A new entry is added to `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest`
   (§8) — `{20_260_818_090_001, Letflow.Repo.Migrations.CreatePromotionAssertionRuns,
   "20260818090001_create_promotion_assertion_runs.exs"}`, appended after the existing
   ten-entry list's last entry (`CreatePromotionReviews`). This means every freshly
   `SandboxPool.claim/2`-provisioned sandbox schema will also carry an (empty)
   `promotion_assertion_runs` table — harmless and correct: `SandboxPool`'s own moduledoc
   already states a claimed sandbox is scaffolded to "look exactly like a real tenant
   schema" (§0), and nothing in this design ever writes a `promotion_assertion_runs` row
   *inside* a sandbox schema — every row this design writes goes into the **production**
   tenant's own schema (`opts[:prefix]`), never the sandbox's.

**Must sort after** `20260816200001_create_promotion_reviews.exs` — carries a real FK to it.

```
promotion_assertion_runs  (primary_key: false, prefix: prefix())

  id                     :binary_id   PRIMARY KEY
  tenant_id              :binary_id   NOT NULL        -- bare UUID, no FK (tenant/users
                                                       -- live in the public schema; this
                                                       -- table lives in a tenant schema --
                                                       -- same no-cross-schema-FK precedent
                                                       -- as promotion_reviews' own tenant_id)
  review_id              references(:promotion_reviews, column: :id, type: :binary_id,
                                     on_delete: :nothing), null: false
                                                       -- REAL FK: promotion_reviews lives
                                                       -- in the SAME per-tenant schema (§0),
                                                       -- unlike tenant_id's cross-schema
                                                       -- case. on_delete: :nothing matches
                                                       -- instance_definition_snapshots'
                                                       -- own precedent -- no ON DELETE
                                                       -- CASCADE, no established need for one
  idempotency_key        :string      NOT NULL        -- "promotion_rerun:<review_id>:<plan_digest>"
  plan_digest             :string      NOT NULL        -- echoed from the review; same
                                                       -- 64-char lowercase-hex shape as
                                                       -- promotion_reviews.plan_digest
  status                 :string      NOT NULL DEFAULT "running"
                                       CHECK (status IN
                                         ('running','passed','failed','teardown_failed'))
                                                       -- explicit CHECK, a deliberate,
                                                       -- flagged divergence from
                                                       -- promotion_reviews' own migration
                                                       -- (which relies on Ecto.Enum-only
                                                       -- validation, no CHECK) -- justified
                                                       -- because prm-batch1's own schema
                                                       -- explicitly specifies one for THIS
                                                       -- table (§0) and this column
                                                       -- directly feeds a downstream
                                                       -- promotion-gate decision (§6) where
                                                       -- a malformed value is a correctness
                                                       -- risk, not just a display concern
  sandbox_id             :binary_id                    -- nullable; NULL iff no sandbox was
                                                       -- ever successfully claimed (§7.2)
  assertions_total       :integer     NOT NULL DEFAULT 0
  assertions_passed      :integer     NOT NULL DEFAULT 0
  assertions_failed      :integer     NOT NULL DEFAULT 0
  failing_assertion_ids  {:array, :string}  NOT NULL DEFAULT []
                                                       -- native Postgres TEXT[], not JSONB:
                                                       -- a flat, homogeneous string list has
                                                       -- no need for JSONB's generality, and
                                                       -- {:array, :string} enables e.g.
                                                       -- `WHERE 'x' = ANY(failing_assertion_ids)`
                                                       -- natively -- a deliberate, reasoned
                                                       -- divergence from prm-batch1's own
                                                       -- JSONB choice (made for Zig's own
                                                       -- driver constraints, not a Postgres
                                                       -- requirement)
  teardown_error         :text                         -- NULL unless a teardown/release
                                                       -- failure occurred (§7.3/§7.5)
  started_at             :utc_datetime_usec  NOT NULL DEFAULT fragment("(now() AT TIME ZONE 'utc')")
  completed_at           :utc_datetime_usec             -- NULL while status = 'running'
  timestamps(type: :utc_datetime_usec)                  -- inserted_at/updated_at, matching
                                                       -- promotion_reviews' own convention

  CONSTRAINT uq_promotion_assertion_runs_idempotency
    UNIQUE (tenant_id, idempotency_key)

  INDEX idx_promotion_assertion_runs_review ON (review_id)
    -- reverse-FK-lookup index, matching idx_snap_definition's own precedent (§0) --
    -- Postgres does not auto-index the referencing side of a FK.
```

`started_at`'s default uses the same `(now() AT TIME ZONE 'utc')` fragment
`20260816193002_create_instance_definition_snapshots.exs` and REQ-023's migrations already
adopted (§0) — the same implicit-local-timezone-cast mitigation, not `NOW()` verbatim.

`status` on the **Ecto schema module** (`Letflow.Definitions.PromotionAssertionRun`, §8) is
`Ecto.Enum, values: [:running, :passed, :failed, :teardown_failed], default: :running` — bare
lowercase atoms, matching `ProcessDefinition.status`'s own dump-lowercase convention (§0),
consistent with the migration's lowercase `CHECK` predicate.

---

## 5. `PromotionArtifact` — input shape

**File:** `lib/letflow/definitions/promotion_artifact.ex`. Plain structs (no `Ecto.Schema`, no
DB backing) — matching the `SandboxClaim`/`FixtureRow` nested-struct convention (§0): small,
non-persisted value types nested in one file.

```
defmodule Letflow.Definitions.PromotionArtifact do
  defmodule Assertion do
    @enforce_keys [:id, :payload]
    defstruct [:id, :payload]
    @type t :: %__MODULE__{id: String.t(), payload: String.t()}
  end

  defmodule CandidateDefinition do
    @enforce_keys [:process_key, :graph_json, :variable_schema]
    defstruct [:process_key, :graph_json, :variable_schema]
    @type t :: %__MODULE__{
      process_key: String.t(),
      graph_json: String.t(),
      variable_schema: String.t()
    }
  end

  @enforce_keys [:id, :assertions, :fixtures, :rng_seed, :non_deterministic_fields,
                 :candidate_definitions]
  defstruct [:id, :assertions, :fixtures, :rng_seed, :non_deterministic_fields,
             :candidate_definitions]

  @type t :: %__MODULE__{
    id: String.t(),
    assertions: [Assertion.t()],
    fixtures: [Letflow.SandboxPool.FixtureLoader.FixtureRow.t()],  # REUSED directly --
                                                                    # no duplicate struct
                                                                    # (§0, §8)
    rng_seed: non_neg_integer(),          # upper 32 bits = frozen-clock epoch seconds (§6)
    non_deterministic_fields: [String.t()],  # dot-path strings, e.g. "metadata.timestamp"
    candidate_definitions: [CandidateDefinition.t()]  # passed through to a custom
                                                       # assertion_evaluator only -- unused
                                                       # by the default one (§0(a), §11 OQ-2)
  }
end
```

`fixtures` reuses `Letflow.SandboxPool.FixtureLoader.FixtureRow.t()` directly — the exact same
struct `load_fixtures_only/3` already accepts (§0, §8) — no field-for-field duplicate is
introduced.

---

## 6. Frozen-clock / seeded-RNG injection and the assertion-replay algorithm

**The injection interface (this requirement's own explicit stability requirement):**

```
%{frozen_clock_ms: integer(), rng_seed: non_neg_integer()}
```

passed as the second argument to `opts[:assertion_evaluator]` on every call. `frozen_clock_ms`
is derived, **once per `apply_promotion_assertion_rerun/6` call** (not per assertion, not
per replay-run), as `(artifact.rng_seed >>> 32) * 1000` — the upper 32 bits of `rng_seed`
treated as a Unix epoch-seconds value, multiplied to milliseconds, per prm-batch1's
`FrozenClockProvider` note and this requirement's own text. **This derivation is exactly the
part R-Co's own design flags as its Open question 1** — *"a future artifact schema could
carry an explicit `frozen_clock_ms` field instead"* — this design keeps that possibility
open by construction: the injection interface's shape (a bare map with a `frozen_clock_ms`
key) never changes regardless of which internal computation produces the value, so swapping
the derivation for a real `artifact.frozen_clock_ms` field later touches only the one
private helper that computes it, not `assertion_evaluator_fun`'s own type or any evaluator
implementation written against it. Restated in §11 OQ-3, not silently closed.

PROVENANCE (historical, not current decision authority):
`rng_seed` is passed through **unmodified** (the raw 64-bit integer) — seeding a real RNG
from it is the evaluator's own responsibility, not this function's. This function itself
reseeds Erlang's own process-scoped `:rand` state via `:rand.seed(:exsss, {rng_seed
band 0xFFFFFFFF, rng_seed >>> 32, 0})` (splitting the 64-bit seed into `:exsss`'s expected
3-integer tuple) **immediately before each of the two replay passes per assertion** (§6.1
step 3) — matching Zig's own `prng = std.Random.DefaultPrng.init(artifact.rng_seed)` reset
before each of its two runs (`assertion_rerun.zig:495`, `:510`) — so any evaluator that reads
`:rand.uniform/0,1` (rather than seeding its own independent RNG state from the passed
`rng_seed` value) still gets deterministic, reproducible output across the two runs. This is
process-scoped Erlang/OTP state (`:rand`'s seed lives in the calling process's process
dictionary), so concurrent calls to `apply_promotion_assertion_rerun/6` from different
processes never interfere with each other's RNG state.

PROVENANCE (historical, not current decision authority):
### 6.1 Replay algorithm (steps, not code) — ports `assertion_rerun.zig`'s `replayAssertions` faithfully

1. Compute `frozen_clock_ms` once (above).
PROVENANCE (historical, not current decision authority):
2. For each `assertion` in `artifact.assertions`, in order:
   a. `:rand.seed(:exsss, <derived from artifact.rng_seed>)`.
   b. `{:ok, result1} = assertion_evaluator.(assertion, %{frozen_clock_ms: ..., rng_seed:
      artifact.rng_seed})` — or `{:error, reason}` (step 2e handles this).
   c. `:rand.seed(:exsss, <same derived seed>)` — reset, matching Zig's own reset-before-each-run.
   d. `{:ok, result2} = assertion_evaluator.(assertion, %{...})` (same injection values as b).
   e. **If either call returns `{:error, _reason}`:** this assertion counts as **failed**
      (fail-closed — an evaluator that cannot produce a result is not silently treated as a
      pass), appended to `failing_assertion_ids`. Continue to the next assertion.
   f. `stripped1 = strip_non_deterministic_fields(result1, artifact.non_deterministic_fields)`;
      `stripped2 = strip_non_deterministic_fields(result2, artifact.non_deterministic_fields)`
      — a direct port of `stripDotPath`'s recursive descend-then-remove-leaf-key algorithm
      (`assertion_rerun.zig:589-601`): parse both `result1`/`result2` as JSON, for each dot-path
      in `non_deterministic_fields` descend into nested objects by `.`-separated segments and
      remove the final segment's key if present (a path that doesn't exist is silently
      skipped — matches Zig exactly), re-encode both to canonical JSON text.
   g. **Byte-level comparison** of `stripped1`/`stripped2` (matching Zig's
      `std.mem.eql(u8, stripped1, stripped2)`, `assertion_rerun.zig:523`): a **mismatch**
      means this assertion is non-deterministic (AC3's own idempotency check) — counted
      **failed**, appended to `failing_assertion_ids`.
   h. **On a match:** `assertion.payload` non-empty → counted **passed**. `assertion.payload`
      empty (`""`) → counted **failed**, appended to `failing_assertion_ids` (matches Zig's
      own "non-empty payload = pass" placeholder rule exactly, `assertion_rerun.zig:531-537`).
3. `assertions_total = length(artifact.assertions)`; `assertions_passed`/`assertions_failed`
   are the running counts from step 2; `failing_assertion_ids` is the accumulated list.

PROVENANCE (historical, not current decision authority):
**Default `assertion_evaluator` (used when `opts[:assertion_evaluator]` is omitted or
`nil`):** `default_assertion_evaluator(assertion, _injection)` returns `{:ok,
assertion.payload}` when `byte_size(assertion.payload) > 0`, else `{:ok, "{}"}` — a direct,
literal port of R-Co's own placeholder (`assertion_rerun.zig:500-501`, `513-514`), not a
richer "real" evaluator this codebase has no engine to justify (§0(b)). `frozen_clock_ms`/
`rng_seed` are accepted but unused by this default implementation, exactly as Zig's own
placeholder computes `frozen_ms` and then immediately discards it (`_ = frozen_ms;`,
`assertion_rerun.zig:491`) and calls `_ = prng.random();` without using the result
(`assertion_rerun.zig:496`, `:511`) — this design's default evaluator is exactly as
faithful (and exactly as much a placeholder) as R-Co's own is.

PROVENANCE (historical, not current decision authority):
**Open question, flagged rather than silently resolved (§11 OQ-4):** REQ-040's own
`docs/requirements.yaml` description text says non-deterministic fields are stripped "from
both expected/actual results" — language suggesting a genuine expected-vs-actual oracle
comparison, distinct from the double-run self-consistency check `assertion_rerun.zig`
actually implements (which has no notion of "expected" anywhere in its own `Assertion`
struct — only `id`/`payload`). This design adopts the double-run reading as primary, because
it is the one concretely grounded in the one written reference implementation that exists;
the "expected/actual" phrasing may be REQ-ANALYST's own informal name for "the two runs being
compared," or may signal a genuinely different, not-yet-specified oracle-comparison design a
future requirement should build. Not silently resolved either way — see §11 OQ-4.

---

## 7. `apply_promotion_assertion_rerun/6` — full algorithm (steps, not code)

**Step 0 (pure/read, no writes).**
`{:ok, tenant_id} = TenantProvisioning.tenant_id_for_schema_name(opts[:prefix])` →
`{:error, :invalid_schema_name}` short-circuits immediately (matches `common_error()`, §0).
`event_appender = Keyword.fetch!(opts, :event_appender)` (raises `KeyError` if omitted, §3).
`assertion_evaluator = Keyword.get(opts, :assertion_evaluator) || (&default_assertion_evaluator/2)`.

### 7.1 Step 1 — idempotency (AC1)

PROVENANCE (historical, not current decision authority):
`idempotency_key = "promotion_rerun:" <> review_id <> ":" <> plan_digest` (a private,
pure `build_idempotency_key/2` helper — direct port of `buildIdempotencyKey`,
`assertion_rerun.zig:120-122`).

Reuses the **exact** "attempt an insert with `on_conflict: :nothing`, then re-fetch by the
client-generated id to disambiguate real-insert-vs-suppressed" idiom already shipped in
`Letflow.EventStore.claim_idempotency/3` and `Letflow.Definitions.insert_definition/3` (§0)
— not raw SQL, not a new idiom:

1. Build an `insert_changeset` (§8) with `tenant_id` (derived, Step 0), `review_id`,
   `idempotency_key`, `plan_digest`. `status`/`assertions_*`/`failing_assertion_ids` are
   never cast here — the row starts at its column defaults (`status: :running`,
   `assertions_* : 0`, `failing_assertion_ids: []`).
2. `Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:tenant_id,
   :idempotency_key], prefix: prefix)`.
   - A changeset validation failure (malformed `plan_digest`) → `{:error, changeset}`.
   - A `review_id` foreign-key violation → mapped via `foreign_key_constraint(:review_id,
     name: :promotion_assertion_runs_review_id_fkey)` (Ecto's own default FK constraint
     name, matching `instance_definition_snapshots_definition_id_fkey`'s own naming
     precedent, §0) → `{:error, :review_not_found}`, never a leaked changeset for this one
     case (matching `duplicate_version_error?/1`'s own established constraint-mapping
     idiom, §0).
3. `Repo.get(PromotionAssertionRun, attempted_id, prefix: prefix)`:
   - **Found** → this call genuinely won the insert (a fresh `:running` row it now owns
     exclusively — no other caller can be racing on the same `(tenant_id, idempotency_key)`
     pair, since `ON CONFLICT DO NOTHING` guarantees exactly one winner). Proceed to Step 2.
   - **Not found** (suppressed by the unique-index conflict) →
     `Repo.get_by(PromotionAssertionRun, tenant_id: tenant_id, idempotency_key:
     idempotency_key, prefix: prefix)` to fetch the **real** existing row. Build the result
     directly from that row's own persisted fields, set `idempotent_hit: true`,
     `teardown_event_appended: true` (nothing attempted this call). **No sandbox is claimed
     on this path (AC1's own literal wording).** Return `{:ok, result}` immediately —
     matching `Letflow.EventStore.append/2`'s own convention of surfacing an idempotent hit
     as a tagged `{:ok, result}` (its `is_duplicate: true`), never as a pseudo-error the way
     R-Co's `AssertionRerunError.AlreadyRecorded` does — a deliberate, reasoned Elixir-idiom
     divergence from R-Co's own error-union shape, matching this codebase's own established
     precedent rather than reproducing R-Co's error taxonomy where Elixir has a cleaner
     idiom already in use one file over.

### 7.2 Step 2 — claim sandbox (AC2)

`SandboxPool.claim(max_wait_ms, sandbox_pool)`.

- `{:ok, %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name}}` → proceed to the
  `try` block (§7.6) covering Steps 3-6.
- `{:error, :sandbox_unavailable}` or `{:error, :provision_failed}` → **no sandbox was ever
  claimed, so no release is needed or possible.** Write a **fail-closed** final `UPDATE`
  (§7.4) directly (no `try` needed — nothing here can leak a sandbox), then return
  `{:error, reason}` unchanged to the caller. **This is a deliberate improvement over R-Co's
  own literal behavior** (§0's traced finding: R-Co leaves the row at `status = 'running'`
  forever on this path) — justified in §7.4.

### 7.3 Step 3 — load fixtures into the claimed sandbox (AC2)

`FixtureLoader.load_fixtures_only(schema_name, artifact.fixtures, [])` — **only** the
artifact's `fixtures[]`, never any other data (AC2's own literal requirement; this design
adds nothing beyond what `artifact.fixtures` names, so "only fixtures, never organic tenant
data" holds by construction — `load_fixtures_only/3` has no code path that reads from the
production tenant schema at all).

- `:ok` → proceed to Step 4 (still inside the `try` block).
- `{:error, :invalid_table_name | :invalid_schema_name | :insert_failed}` → **the sandbox
  WAS claimed and must be released** (this is exactly the case §2's `try/rescue` exists for,
  though this specific error is a typed return, not a raised exception, so it's handled by
  ordinary pattern matching inside the `try` body, not the `rescue` clause): attempt
  `SandboxPool.release(sandbox_id, sandbox_pool)`, then apply §7.4's fail-closed accounting
  with `sandbox_id` populated, then §7.5's teardown-failure handling if the release itself
  also failed, then return `{:error, :fixture_load_failed}` to the caller (the underlying
  `FixtureLoader` error is deliberately not surfaced verbatim — `:fixture_load_failed` is
  this function's own, coarser, stable error tag, matching R-Co's own
  `AssertionRerunError.FixtureLoadFailed` collapsing all three `FixtureLoadError` variants
  into one).

### 7.4 Step 4 — fail-closed accounting for an infrastructure failure (Steps 2/3's error paths) — a deliberate, disclosed improvement over R-Co

**R-Co's own traced behavior (§0):** on a sandbox-claim or fixture-load failure, the row is
left at `status = 'running'` forever — no `assertions_failed` value is ever written. Read
literally against this requirement's own AC4 gate rule (*"the apply pipeline... evaluates
`assertions_failed == 0`"*), a stuck `running` row's `assertions_failed` column still reads
its column default, `0` — meaning a naive future reader of this table that checks
`assertions_failed == 0` **without also checking `status`** would misread an infrastructure
failure (never even attempted) as a **green** gate. This is a real hazard, not a hypothetical
one, and this design closes it rather than silently porting R-Co's own gap.

**This design's resolution — `fail_closed_counts/1`, a private helper:**

```
assertions_total  = length(artifact.assertions)
assertions_failed = max(assertions_total, 1)     # never 0, even for a zero-assertion artifact
assertions_passed = 0
failing_assertion_ids =
  if assertions_total > 0,
    do: Enum.map(artifact.assertions, & &1.id),
    else: ["__infrastructure_failure__"]          # synthetic sentinel id -- the residual
                                                   # edge case named in §11 OQ-2
```

Every assertion in the artifact is conservatively treated as failed (fail-closed, not
fail-open) — the correct, textbook-safe default when the pipeline genuinely could not
determine real outcomes, and the `max(assertions_total, 1)` clause guarantees
`assertions_failed` is **never** `0` on this path even for a pathological zero-assertion
artifact, closing the exact hazard described above. `status` is set to `:failed` (never
`:teardown_failed` — no sandbox teardown was even attempted on the claim-failure path,
and the fixture-load-failure path's own status is set by §7.5's precedence rule, not this
step directly).

### 7.5 Step 5 — teardown (guaranteed release) and the green-gate-preserving precedence rule (AC3/AC4/AC5)

After Step 4 (assertion replay, §6) computes `pre_teardown_status = if assertions_failed ==
0, do: :passed, else: :failed` from the **real** replay counts (not the fail-closed ones —
this step only runs when replay actually happened, i.e. Steps 2 and 3 both succeeded):

`SandboxPool.release(sandbox_id, sandbox_pool)`:

- `:ok` → `final_status = pre_teardown_status`; `teardown_error = nil`;
  `teardown_event_appended = true` (nothing to append).
PROVENANCE (historical, not current decision authority):
- `{:error, :not_found}` or `{:error, :release_failed}` → **the precedence rule, a direct
  port of `recordTeardownFailure`'s own `CASE WHEN status = 'failed' THEN 'failed' ELSE
  'teardown_failed' END`** (`assertion_rerun.zig:623-627`, quoted in §0):
  - If `pre_teardown_status == :failed` → `final_status` **stays** `:failed` — a teardown
    failure never *demotes* an already-failed run into the differently-named
    `:teardown_failed` status (there is nothing to preserve; the run was already red).
  - If `pre_teardown_status == :passed` → `final_status = :teardown_failed` — **this is
    PRM-07 AC2's green-gate case**: `assertions_failed` remains `0` (the real replay
    genuinely found zero failures), only `status` changes from `:passed` to
    `:teardown_failed`. §6.2 states explicitly why this must never be read as a promotion
    failure.
  - Either way, `teardown_error` is set to a human-readable message naming the release
    failure reason.
  - `event_appender.(%{event_type: "PROMOTION_ASSERTION_TEARDOWN_FAILED", run_id: run_id,
    sandbox_id: sandbox_id, tenant_id: tenant_id, error: <release error reason as
    string>}, prefix)` is called — **exactly once**, regardless of whether
    `pre_teardown_status` was `:passed` or `:failed` (a teardown failure is worth recording
    as its own event either way; only the *status* precedence differs, not the *eventing*
    decision).
    - `{:ok, _}` → `teardown_event_appended = true`.
    - `{:error, _reason}` → `teardown_event_appended = false`. **This failure is absorbed,
      never propagated as this function's own error** (the same "don't let a side-effect's
      own failure corrupt an already-computed, already-durable-once-written outcome"
      resolution `rollback_definition_version/4`'s own OQ-6 already established for an
      analogous tension, §0) — `final_status`/`assertions_failed` are **never** altered by
      an `event_appender` failure. This is this design's own explicit, disclosed answer to
      "what if the teardown-failure event itself can't be appended" — not silently decided
      by omission (§11 OQ-5).

### 7.6 Step 6 — final `UPDATE` and the `try/rescue` crash-safety wrapper (§2.3)

Steps 3 through 5 (fixture load, replay, teardown+precedence+eventing) are wrapped in one
`try ... rescue exception -> ... end` (matching `activate/2`'s/`rollback_definition_version/4`'s
own established idiom, §0), **not** wrapping Step 2's claim itself (a claim failure needs no
release — mirrors `rollback_definition_version/4`'s own "try/rescue wraps only the [step
that can leak a resource / needs cleanup]" scoping note, §0):

PROVENANCE (historical, not current decision authority):
```
try do
  <Step 3, Step 4 (replay), Step 5>
  <Step 6 proper: one Repo.update/2 via update_changeset/2, casting status,
   sandbox_id, assertions_total/passed/failed, failing_assertion_ids,
   teardown_error, completed_at (DateTime.utc_now/0, truncated to microsecond) —
   ONE update, matching assertion_rerun.zig's own single final UPDATE (step 7),
   not two separate writes>
  {:ok, build_result(...)}
rescue
  exception ->
    # Best-effort release attempt -- may be redundant if Step 5 already ran and
    # succeeded before the exception (e.g. the exception originated in Step 6's
    # own UPDATE) -- SandboxPool.release/2 on an already-released sandbox_id
    # returns {:error, :not_found}, itself swallowed here, matching
    # provision_sandbox/0's own "cleanup, not the primary error path" stance (§0).
    safe_release(sandbox_id, sandbox_pool)
    # Best-effort fail-closed row update -- swallows its OWN failure too (the DB
    # itself may be unreachable, which is presumably why an exception fired in
    # the first place).
    safe_fail_closed_update(run_id, artifact, tenant_id, prefix, exception)
    {:error, {:transaction_failed, exception}}
end
```

This guarantees release is **attempted** (not guaranteed — §2.3's disclosed limit) on every
exit path this `try` can observe, and that the row is left in a fail-closed, gate-safe state
rather than stuck at `:running` even when an unexpected exception fires mid-replay.

---

## 8. Cross-module dependencies

| Dependency | Direction | Kind |
|---|---|---|
| `Letflow.SandboxPool.claim/2`, `.release/2` | this design → REQ-039 | Reused directly, unmodified |
| `Letflow.SandboxPool.FixtureLoader.load_fixtures_only/3`, `.FixtureRow` | this design → REQ-039 | Reused directly; `PromotionArtifact.fixtures` is typed as `[FixtureRow.t()]`, no duplicate struct |
| `Letflow.TenantProvisioning.tenant_id_for_schema_name/1` | this design → shared | Reused unchanged, matches every other function in `definitions.ex` |
| `Letflow.TenantProvisioning.@tenant_scoped_migration_manifest` | this design → `tenant_provisioning.ex` | **Requires an edit**: append the new migration's `{version, module, filename}` entry (§4) — both halves of the mandatory tenant-scoped-migration contract |
| `Letflow.Definitions.event_appender_fun` (already-defined type, §0 line 562-564) | this design → `definitions.ex` (self) | Reused verbatim, not redefined |
| `Letflow.Definitions.common_error/0`-shaped type (§0 line 124-126) | this design → `definitions.ex` (self) | Reused verbatim |
| `Letflow.Definitions.PromotionReview`/`PromotionReviewStore.mark_review_applied/2` | this design ← future orchestrator only | **No runtime call** — this function does not call `mark_review_applied/2` or `promote_definition/3` itself; it only produces the `assertions_failed` count some future orchestrator (REQ-040-or-later, per `promotion_review_store.ex`'s own moduledoc, §0) reads to decide whether to call them |
| A future `EventStore`-backed `event_appender` implementation, and a future `PROMOTION_ASSERTION_TEARDOWN_FAILED` `event_type_registry` entry | future → this design | Not built here (§9) — same deferred-wiring gap `promotion.ex`/`req038`'s own `event_appender` already carry, now independently reconfirmed for a third event type |
| A future assertion-evaluation/replay engine | future → this design | Not built here (§6) — `opts[:assertion_evaluator]` is the stable injection point a future engine attaches to |
| A future sandbox-leak reaper (PRM-07 AC5) | future → REQ-039's `SandboxPool` | Not built here — inherits req039's own OQ-2/OQ-3 deferral (§2.3, §11 OQ-1) |
| S4 (HTTP layer) | future S4 → this design | Would eventually expose `POST /api/v1/promotions/{review_id}/run-assertions`, mapping this function's error tags to HTTP codes per prm-batch1's own table (`:sandbox_unavailable`→503, `:fixture_load_failed`→422, `:review_not_found`→404-or-422). Not built here |

---

## 9. `opts[:event_appender]` and the `PROMOTION_ASSERTION_TEARDOWN_FAILED` gap — independently reconfirmed

Same disclosed gap `promotion.ex`'s and `req038-promotion-rollback.md`'s own moduledocs
already carry for `DEFINITION_PROMOTED`/`DEFINITION_VERSION_ROLLED_BACK`, independently
re-verified here for a **third** event type: `PROMOTION_ASSERTION_TEARDOWN_FAILED` is **not**
a registered `event_type_registry` entry in any tenant (no migration/seed data in this
codebase registers it — confirmed by the absence of any reference to that literal string
outside `docs/requirements.yaml` and R-Co's own source, §0), so `Registry.validate_payload/3`
would return `{:error, :unknown_event_type}` for any real `Letflow.EventStore.append/2` call
using it. This design does **not** register the event type (out of scope — no requirement
asks for it) and does **not** hardcode a call to `EventStore.append/2` (the same "no data
path exists, don't paper over it with a silently-failing or silently-no-op default" reasoning
`promote_definition/3`'s own moduledoc already states, §0) — `opts[:event_appender]` stays
`Keyword.fetch!/2`'d with no default, and the caller supplies whatever mechanism is actually
wired up by the time this function is really invoked in an integration/test context. Flagged
explicitly, not silently assumed working.

---

## 10. Invariants

PROVENANCE (historical, not current decision authority):
| id | Invariant | Enforced where |
|---|---|---|
| INV-AR-1 | `apply_promotion_assertion_rerun/6` writes to `promotion_assertion_runs` **only** in the caller's own tenant schema (`opts[:prefix]`) — a sandbox schema's own (empty, unused) `promotion_assertion_runs` table is never read or written by this function | §4, §7 |
| INV-AR-2 | A fixture load against a claimed sandbox loads **only** `artifact.fixtures[]` — no code path in this function reads from the production tenant schema to populate the sandbox (AC2) | §7.3 |
| INV-AR-3 | `tenant_id` is always derived from `opts[:prefix]`, never accepted as a separate argument — matches every other function in `definitions.ex` | §0, §3, §7 Step 0 |
| INV-AR-4 | On a genuine idempotency hit (`idempotent_hit: true`), no sandbox is claimed — `SandboxPool.claim/2` is never called on that path (AC1) | §7.1 |
| INV-AR-5 | `SandboxPool.release/2` is attempted at most once per successfully-claimed sandbox per call (Step 5's normal path or the `rescue` clause's best-effort path — never both, since the `rescue` clause's `safe_release/2` only runs when an exception interrupted the `try` body before or during Step 5) | §7.5, §7.6 |
| INV-AR-6 | A teardown (release) failure never converts a `pre_teardown_status == :passed` outcome into `:failed` — only ever into `:teardown_failed`, and `assertions_failed` is never altered by a teardown failure (PRM-07 AC2, AC4) | §7.5 |
| INV-AR-7 | An infrastructure failure (sandbox-claim or fixture-load failure) **never** produces a row with `assertions_failed == 0` — `fail_closed_counts/1`'s `max(assertions_total, 1)` guarantees this even for a zero-assertion artifact (closes the "stuck `running` row reads as green" hazard R-Co's own reference implementation does not close, §0, §7.4) | §7.4 |
| INV-AR-8 | `opts[:event_appender]`'s own failure on the teardown-failure path never alters `final_status`/`assertions_failed` — absorbed into `teardown_event_appended: false`, never propagated as this function's own error | §7.5 |
| INV-AR-9 | Exactly one final `UPDATE` is issued per call that reaches Step 6 (never two separate writes for "claimed" then "completed") — matches `assertion_rerun.zig`'s own single final `UPDATE` (its step 7) | §7.6 |

---

## 11. Open questions — explicit, not silently resolved

**OQ-1 (MAJOR, this requirement's own named crash-safety question, §2 — a residual gap
remains after this design's `try/rescue` decision, by design, not by oversight):** a hard
process kill, BEAM node crash, or `System.halt/0` during the claim→release span leaves the
sandbox permanently "active" in `SandboxPool`'s in-memory state (confirmed empirically, §2.2
— no existing monitor covers this) and the `promotion_assertion_runs` row stuck at `status =
'running'`. The concrete, disclosed mitigation (a background reaper sweeping
`information_schema.schemata`/`promotion_assertion_runs WHERE status = 'running' AND
started_at < some cutoff`, mirroring PRM-07 AC5's `reclaimLeakedSandboxes`) is **not built
here** — inherited from req039's own OQ-2/OQ-3 deferral to "REQ-040 or a dedicated
follow-up." REVIEWER should confirm `try/rescue` (covering normal/error/exception exits) plus
an explicitly-named, still-deferred reaper is an acceptable resolution for AC6's own
"name the open question" requirement, or route the reaper itself to REQ-ANALYST as its own
requirement if closing the residual gap is judged urgent now.

**OQ-2 (MINOR):** the zero-assertion-artifact-plus-infrastructure-failure edge case (§7.4)
is closed via a synthetic `"__infrastructure_failure__"` sentinel id in
`failing_assertion_ids` rather than a real assertion id (there are none to name). This is
this design's own reasoned choice, not confirmed against any source document — flagged for
REVIEWER; an alternative (a dedicated boolean column, e.g. `infrastructure_failure: boolean()`)
was considered and rejected as unrequested schema growth beyond what any acceptance criterion
asks for.

**OQ-3 (MINOR, restates R-Co's own Open question 1 verbatim per this requirement's explicit
instruction to keep it open, §6):** `frozen_clock_ms`'s derivation (upper 32 bits of
`rng_seed`) is this design's — and R-Co's own — placeholder source. If a future artifact
schema carries an explicit `frozen_clock_ms` field, only the private derivation helper
changes; `assertion_evaluator_fun`'s own injection-interface shape is unaffected. Not
resolved now — no requirement asks for the schema change.

PROVENANCE (historical, not current decision authority):
**OQ-4 (MAJOR — a genuine ambiguity between REQ-040's own descriptive text and the one
concrete reference implementation that exists, §6):** REQ-040's `docs/requirements.yaml`
description says non-deterministic fields are stripped "from both expected/actual results,"
language suggesting a genuine oracle (expected-vs-actual) comparison. `assertion_rerun.zig`'s
own `replayAssertions` implements a **different** thing: running the *same* assertion twice
and comparing the two runs against each other for self-consistency — there is no "expected"
value anywhere in R-Co's own `Assertion` struct (only `id`/`payload`). This design adopts the
double-run reading as primary (§6.1) because it is the only one concretely grounded in a
written implementation; the alternative reading, if actually intended, would require adding a
distinct `expected` field to `PromotionArtifact.Assertion` and a genuinely different
comparison algorithm — a real design change, not attempted here without confirmation.
REVIEWER/REQ-ANALYST should confirm which reading REQ-040 actually intends.

**OQ-5 (MINOR):** §7.5's decision to absorb (not propagate) an `event_appender` failure on
the teardown-failure path is this design's own reasoned choice, analogous to
`rollback_definition_version/4`'s own OQ-6 but not identical (that case absorbs a
`supersede_review/3` race; this case absorbs an event-append failure specifically because
propagating it would risk being misread as "the run itself failed," which PRM-07 AC2
explicitly forbids). Flagged for REVIEWER, not silently assumed.

---

## 12. Acceptance-criteria traceability

| # | Acceptance criterion (verbatim, `requirements.yaml:1930-1936`) | Design element |
|---|---|---|
| 1 | "calling apply_promotion_assertion_rerun/6 twice with the same (review_id, plan_digest) returns the cached outcome on the second call and claims no second sandbox, verified by sandbox claim count" | §7.1 Step 1 (the `on_conflict: :nothing`/re-fetch idempotency idiom, `idempotent_hit: true`, `SandboxPool.claim/2` never called on that path); INV-AR-4 |
| 2 | "a sandbox loaded via REQ-039 receives ONLY the artifact's fixtures[] rows, demonstrated by confirming no pre-existing tenant data appears in the sandbox schema" | §7.3 Step 3 (`FixtureLoader.load_fixtures_only/3`, unmodified reuse); INV-AR-2 |
| 3 | "an assertion replay that fails records status = failed with a non-empty failing_assertion_ids list; a passing replay whose teardown itself fails records status = teardown_failed with assertions_failed = 0 -- both distinct outcomes tested explicitly" | §6.1 (replay/counting algorithm) + §7.5 (the `recordTeardownFailure`-precedence-rule port: `pre_teardown_status == :failed` stays `:failed`; `:passed` + release failure → `:teardown_failed` with `assertions_failed` unchanged at `0`); INV-AR-6 |
| 4 | "the moduledoc explicitly states the apply pipeline gate condition is assertions_failed == 0, not status == passed, citing the teardown_failed green-gate case" | §7.5's own stated precedence rule + §11 OQ-1's framing are the underlying reasoning; **§13.1's ready-to-paste `@moduledoc` subsection and §13.2's `@doc` block are the literal text ELIXIR-DEV copies**, satisfying this AC's own literal-prose requirement directly, not via synthesis; INV-AR-6/INV-AR-7 make the underlying data safe for that gate rule to be true in practice |
| 5 | "a simulated teardown failure appends a PROMOTION_ASSERTION_TEARDOWN_FAILED event via REQ-025's already-shipped append mechanism and does not change a passing run's outcome from green to failed" | §7.5 (`event_appender.(%{event_type: "PROMOTION_ASSERTION_TEARDOWN_FAILED", ...}, prefix)`, called via the exact `opts[:event_appender]` convention `promote_definition/3`/`rollback_definition_version/4` already established, §0/§9); INV-AR-6 (never flips passed→failed) |
| 6 | "the moduledoc names the crash-safety/guaranteed-teardown open question explicitly, per this requirement's description and stage-2-event-store-definitions.md's Early findings" | §2 (full investigation + decision) + §11 OQ-1 are the underlying reasoning; **§13.1's ready-to-paste `@moduledoc` subsection and §13.2's `@doc` block are the literal text ELIXIR-DEV copies**, matching `SandboxPool`'s own moduledoc precedent (§0, req039 design §10) of stating its resolved-open-question reasoning directly in the shipped `@moduledoc`, not only in the design doc |

---

## 13. Verbatim `@moduledoc`/`@doc` text

Presented as literal documentation-string content ELIXIR-DEV copies verbatim (prose
only, no function bodies, no logic) — matching req039's design doc §10 precedent, whose
equivalent text shipped nearly verbatim into `sandbox_pool.ex`'s real `@moduledoc`.
`apply_promotion_assertion_rerun/6` is added to the existing `Letflow.Definitions`
context module (§1), not a new module, so this section gives two paste targets: §13.1 is
a new `##`-headed subsection to insert into `Letflow.Definitions`' own existing
`@moduledoc` (immediately after the "`activate/2`'s `service_scope_validator` option"
subsection, `definitions.ex:40`, §0 — the same "one `##` subsection per
requirement-specific hook/contract" convention that subsection itself establishes), and
§13.2 is the `@doc` block directly above `def apply_promotion_assertion_rerun/6` itself,
matching `activate/2`'s own `@doc` → "see this module's moduledoc" pointer pattern
(`definitions.ex:456-461`, §0) rather than duplicating the full explanation twice.

### 13.1 `Letflow.Definitions` moduledoc — new subsection

```
## `apply_promotion_assertion_rerun/6`'s gate condition and crash-safety scope (REQ-040)

The apply pipeline (REQ-037's `mark_review_applied/2` path) gates on this function's
recorded `assertions_failed == 0` -- NOT on `status == "passed"`. These are not the same
check: a passing assertion replay whose sandbox teardown itself fails is recorded as
`status = :teardown_failed` with `assertions_failed` still `0` (the real replay found
zero failures; only the *teardown* failed, tracked separately via a
`PROMOTION_ASSERTION_TEARDOWN_FAILED` event, never folded into the assertion counts). A
`teardown_failed` row is therefore a **green gate** -- a caller that checks
`status == :passed` instead of `assertions_failed == 0` will read this outcome
backwards and incorrectly block a promotion that should proceed.

Crash safety: the claim -> load-fixtures -> replay -> release -> record-outcome span is
wrapped in a single `try/rescue`. This covers three exit classes -- normal completion,
a typed error return from any step, and a raised exception anywhere in that span -- and
on all three, `SandboxPool.release/2` is attempted and the `promotion_assertion_runs`
row is written with fail-closed accounting (`assertions_failed >= 1`) rather than left
stuck at `status = :running`. It does **not** cover a hard process kill
(`Process.exit(pid, :kill)`), a BEAM node crash, or `System.halt/0` -- none of these run
a `rescue` clause, so a sandbox claimed and a row left `:running` at the moment one of
those events fires is neither released nor updated by this function. This residual gap
is a disclosed, deferred limitation, not an oversight: the concrete mitigation (a
background reaper sweeping stale `:running` rows and orphaned sandbox schemas, mirroring
R-Co's `reclaimLeakedSandboxes`) is not built here and is left to a dedicated follow-up
requirement -- the same deferral `Letflow.SandboxPool`'s own moduledoc already carries
for the analogous owner-crash-detection gap on an already-claimed sandbox.
```

### 13.2 `apply_promotion_assertion_rerun/6`'s own `@doc`

PROVENANCE (historical, not current decision authority):
```
Ports `src/definition/assertion_rerun.zig`'s `applyPromotionAssertionRerun` (PRM-06/07)
-- idempotent assertion replay against an ephemeral REQ-039 sandbox, keyed by
`(review_id, plan_digest)`.

Returns the cached `{:ok, result}` with `idempotent_hit: true` on a second call for the
same `(review_id, plan_digest)` pair, claiming no sandbox. On a fresh call: claims a
sandbox (`Letflow.SandboxPool.claim/2`), loads only `artifact.fixtures[]` into it
(`Letflow.SandboxPool.FixtureLoader.load_fixtures_only/3` -- never organic tenant data),
replays each assertion twice under a frozen clock and a seeded, reset-between-runs RNG,
and records `status` + `assertions_total`/`assertions_passed`/`assertions_failed` +
`failing_assertion_ids` in `promotion_assertion_runs`.

**Gate condition -- read before wiring this into the apply pipeline:** callers must gate
on the returned `assertions_failed == 0`, NOT on `status == :passed`. A
`status = :teardown_failed` result with `assertions_failed == 0` is a green gate -- see
this module's moduledoc, "`apply_promotion_assertion_rerun/6`'s gate condition and
crash-safety scope".

**Crash safety -- also see this module's moduledoc:** the claim-through-release span is
wrapped in `try/rescue`, covering normal completion, typed errors, and raised
exceptions. It does NOT cover a hard process kill or a BEAM crash mid-replay -- that
residual gap is disclosed, not resolved, and left to a deferred reaper follow-up.
```
