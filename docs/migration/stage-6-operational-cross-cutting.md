# Stage 6 — Operational cross-cutting

Status: active. Depends on: S4. REQ-176 (DLQ schema and core entry
lifecycle), REQ-177 (DLQ landing hooks) and REQ-178 (DLQ route layer)
are all done as of 2026-08-29 -- the first batch's DLQ half is now
fully complete. **S6's webhooks subsystem is now fully complete:**
REQ-181 (subscription schema and core), REQ-182 (subscription CRUD
routes), REQ-183 (delivery dispatch, HMAC signing and auto-pause) and
REQ-184 (deliveries route) are all done as of 2026-08-30, mirroring the
DLQ half's REQ-176/177/178 completion. REQ-185 (scheduler
timer-firing architecture, decision-and-design-only), REQ-186 (timers
schema + scheduler core: poll-and-fire, missed-timer recovery, failure
accounting), REQ-187 (wiring TIMER nodes into transition.ex, SCH-01/03,
plus cancellation) and REQ-188 (recurrence, SCH-07, plus the periodic
retention runner) are all done as of 2026-08-29/30 -- **S6's scheduler
half is now fully complete.** S6's secrets half (REQ-189 onward) is
separate and remains open: REQ-189 (the secrets storage decision
record) is itself now done, unblocking REQ-190 and REQ-183, but
REQ-190 onward is still pending, as are the repository and observability
subsystems the second batch also registered. **S6's expr subsystem is
now fully complete:** REQ-197 (arithmetic, unary negation, structured
parse-error surface) and REQ-198 (the 8 pure builtin functions) are
both done as of 2026-08-30, mirroring how REQ-192's completion closed
the service-catalog route-layer half. REQ-200 (Instance timeline
rendering -- actor display names and human-readable descriptions,
OBS-04) is also done as of 2026-08-30, closing the real broken-contract
gap left by REQ-080: the already-shipped SPA's
`TimelineFeedItem.tsx` was reading `actor_display_name`, `description`,
`timestamp` and `sequence_num`, none of which the REQ-080 route ever
emitted. REQ-194 (Prometheus metrics subsystem and the `GET /metrics`
exposition, OBS-02) is also done as of 2026-08-30. It resolves all
three of REQ-078's deliberately-recorded-open divergences: FORMAT is
settled by the already-committed SPA Prometheus-text contract
(`web/src/api/metrics.ts`'s `parsePrometheusText`); AUTH and SCOPE are
resolved as global and unauthenticated (matching R-Co), made safe by a
label-allowlist invariant that closes the cross-tenant-disclosure risk
REQ-078 was originally worried about -- independently re-traced by
RELEASE-VALIDATOR across every emission call site, including error and
DB-unavailable degradation paths, with no path found by which a
tenant/instance/definition/task/actor id can reach a metric label.
`lib/letflow/routers/metrics.ex` (REQ-078's authenticated JSON
endpoint) is removed outright, superseded by
`lib/letflow/routers/metrics_exposition.ex`. REQ-195 (Audit-entry
storage with before/after state capture and tamper-evident chaining,
OBS-03/XC-02) is also done as of 2026-08-30, closing
`lib/letflow/routers/audit.ex`'s own documented gap (REQ-078):
`resource_type` was hardcoded to the constant `"instance"` and
`before_state`/`after_state` were always null because Letflow's event
model had no before/after capture -- both are now real, written in the
same transaction as the state change they describe, into a new
DB-immutable, tenant-scoped `audit_entries` table. The chain
verification also fixes a genuine R-Co weakness rather than just
porting it: `do_verify_chain/2` recomputes each entry's hash from its
stored content before checking `prev_chain_hash` linkage, where R-Co's
own `validateAuditChain` only checked linkage. REQ-195 is core-only,
no route change. REQ-196 (Serve `GET /api/v1/audit` from the audit
store) is also done as of 2026-08-30: the route's handler is repointed
from `Letflow.EventStore.read_global/1` to REQ-195's `audit_entries`
store, retiring `routers/audit.ex`'s own documented caveats in full --
`resource_type` now varies by real resource kind instead of the
constant `"instance"`, `before_state`/`after_state` carry real
captured state instead of always null, and the `resource_type` filter
now genuinely discriminates -- with the response envelope unchanged
against `web/src/api/audit.ts`'s `RawAuditPage`/`RawAuditEntry` and no
`web/` file touched. This closes the full audit vertical (REQ-195 +
REQ-196) in full. REQ-201 (alerting hooks with edge-triggered firing
and retry/backoff delivery, OBS-06) is also done as of 2026-08-30/31:
threshold detection for all four OBS-06 trigger types
(instance_error_stuck, dlq_depth_threshold, scheduler_lag_threshold,
webhook_subscription_paused), edge-triggered firing (no repeat fires
while an alert is active), and retry/backoff delivery via REQ-183's
existing webhook dispatch mechanism, with RELEASE-VALIDATOR
independently re-verifying all 14 acceptance criteria and 17/17
targeted tests (PASS). REQ-202 (Content-addressed artifact store and
the REPO-04 canonicaliser) is also done as of 2026-08-30:
`repository_artifacts` + `artifact_versions` (migration 045's shape,
not R-Co's conflicting migration 058 shape), a canonicaliser
deliberately kept SEPARATE from REQ-036's `PromotionDigest` (both
moduledocs cross-reference each other; merging them would silently
redrive every stored promotion digest), DB-level immutability on the
content store, and REQ-041's `solution_pack_artefact_bases`
disambiguated as an unrelated table.
**REQ-203 (per-tenant artifact activation, REPO-08/09/10) is also done
as of 2026-08-31, closing the artifact-repository pair in full:**
`artifact_activations` (the current pointer, UNIQUE (tenant_id,
artifact_kind, artifact_name) DB-enforced), `artifact_activation_history`
(append-only, mandatory rationale, `previous_version_id` null-then-
populated), and `artifact_activation_groups` (the multi-artifact
envelope). REPO-08's atomic multi-artifact activation runs as one
`Ecto.Multi` transaction, with its observability criterion -- no mixed
old/new version state observable to a concurrent reader mid-activation
-- rigorously verified as a structural consequence of Postgres's own
READ COMMITTED MVCC, with no isolation-level bump needed. REPO-09
(per-tenant isolation) and REPO-10 (activation history) are both
DB-enforced (UNIQUE/CHECK/FK, ON DELETE RESTRICT on every
version-id FK). REQ-195's `audit_entries` disambiguated in the
moduledoc as a different, non-redundant trail (subsystem-specific
queryable lineage with mandatory rationale, vs. the tenant-wide
hash-chained compliance trail). Still no route/controller surface,
per the same deferral REQ-202 already recorded.
**REQ-199 (Correlated effect re-entry ordering, ORD-01/02/03/04) is also
done as of 2026-08-31:** `effect_completions` + `correlation_cursors`
tables (per-tenant, decision 0003-B), ORD-01 claim guard (FOR UPDATE
SKIP LOCKED), ORD-02 per-correlation advisory lock, ORD-03 cursor-based
in-order apply with gap sweeper on REQ-186's scheduler, and ORD-04 lag
surface via REQ-194 metrics. All 18 ACs independently verified by
RELEASE-VALIDATOR. **S6 is now complete.** REPO-05 (form-schema indexing)
and the repository HTTP surface (REPO-11..14) remain deferred, per
REQ-202's own description. Requirements, expanded in two batches:

**Note added 2026-09-01, after the "S6 is now complete" line above was
written (not an edit to it, per this doc's own convention of appending
rather than rewriting a settled statement):** REQ-211 (instance-attachment
schema and core module) and REQ-212 (instance-attachment route surface)
were drafted and shipped after this line was written, closing GH#769/
ISS-0390 ("missing attachment/document-upload subsystem"), a finding from
REQ-206's S7 SwiftRoute simulation batch. Both are genuinely new
functionality (no R-Co source, no existing SPA consumer contract) rather
than a port, and both are S6-scoped per this doc's own "new subsystem, not
correctness gate" placement rule — see REQ-211's requirement text in
docs/requirements.yaml for the full placement rationale. This does not
reopen or contradict the sentence above; S6's originally-scoped batches
were and remain complete, and this is an additional, later-discovered
subsystem in the same stage.

**Note added 2026-09-04, after the note above (append, not an edit — same
convention):** REQ-225 through REQ-231 were drafted, closing ISS-0438
("port R-Co's dynamic entity/data-model subsystem into Letflow"). CODE-DESIGNER's
scoping recommendation (`lib/letflow/design/iss0438-entity-subsystem-scoping.md`,
passed by CODE-DESIGN-VALIDATOR) found this to be a real, already-battle-tested
R-Co subsystem (`src/entities/` — `definition.zig`, `validator.zig`,
`commands.zig`, `projector.zig`, `events.zig`, plus the `query/` subdirectory
the original ISS-0438 filing did not size at all) whose two hard dependencies,
REQ-202 (`Letflow.Repository`) and REQ-203 (per-tenant activation), are already
done, and which is S6-scoped rather than S5 because its dependency graph
resolves entirely to S2/S6 subsystems, not `src/lua/`/`src/wasm/`. Seven
requirements, chained by the artefact's dependency order and split further
where a slice was itself oversized: REQ-225 (entity definition JSON schema
and structural validation rules), REQ-226 (`entity_definitions` persistence,
CRUD, and the `ArtifactKind` `:entity` extension), REQ-227 (entity
record-payload validation, ISS-0160/GH#481 parity), REQ-228 (entity event
registration and record commands, idempotent replay, synthetic-instance-per-type),
REQ-229 (projection and replay), REQ-230 (entity query DSL — operators,
allowlist, SQL compiler — a tenant-data path under SECURITY-REVIEWER's hard
gate), and REQ-231 (entity query DSL — cursor pagination and field-grant
redaction). No route/controller layer is included in any of the seven,
matching REQ-202's own "no consumer contract, don't build the surface"
deferral — `router.ex`'s two entity-related deferred rows remain deferred.
Three genuine open design questions the recommendation deliberately did not
resolve are named explicitly inside the relevant requirement's own
description, for that slice's own CODE-DESIGNER pass to decide: the
`Letflow.EventStore.Registry.JsonSchema` cross-namespace reuse question
(REQ-227), the entity-type tenant-vs-platform ownership model (REQ-225),
and the synthetic-instance-per-type-vs-per-record model (REQ-228, defaulting
to matching R-Co's actual shipped per-type behaviour rather than its
design-doc hedge). This does not reopen or contradict "S6 is now complete"
above, nor the 2026-09-01 REQ-211/212 note; it is a third, later-discovered
subsystem landing in the same stage. ISS-0439 (the deferred 1C-style typed-template
question) remains unresolved and unaffected — its own recorded decision names
this exact port as its prerequisite, not as evidence to act on yet.

**First batch (DLQ and webhooks):** REQ-176 (Dead-letter queue schema
and core entry lifecycle, OBS-05 foundation); REQ-177 (Wire REQ-056's
and REQ-061's existing hooks into the DLQ); REQ-178 (DLQ route layer
atop REQ-176's core); REQ-181 (Webhook subscription schema and core);
REQ-182 (Webhook subscription CRUD routes); REQ-183 (Webhook delivery
dispatch, HMAC signing and auto-pause); REQ-184 (Webhook deliveries
route). REQ-179 and REQ-180 were deleted as superseded — REQ-VALIDATOR
rejected them for bundling schema, context and routes into single
oversized entries, and the core/route split they were replaced by
(REQ-181→182, REQ-183→184) is the precedent every later S6 entry
follows.

**Second batch (the six remaining subsystems):** REQ-185 (Settle the
scheduler timer-firing architecture for the BEAM — decision artefact,
gates the scheduler half); REQ-186 (Timers schema and scheduler core,
SCH-01/02/05/06); REQ-187 (Wire TIMER nodes into the engine, SCH-01/03
— closes `task_activation.ex`'s `cancel_pending_timers/2` stub);
REQ-188 (Recurring timers, SCH-07, plus the periodic retention runner);
REQ-189 (Settle the secrets storage backend and write
`decisions/0016-secrets-storage-backend.md` — gates the secrets half);
REQ-190 (Secrets core: envelope encryption and resolution by reference,
EXP-501, plus the webhook HMAC key reconciliation); REQ-191 (Service
catalog core, REPO-07/SVC-01/SVC-03); REQ-192 (Service catalog route
surface, SVC-04); REQ-193 (Structured JSON logging and trace-id
propagation, OBS-01/XC-01); REQ-194 (Prometheus metrics subsystem and
the `GET /metrics` exposition, OBS-02); REQ-195 (Audit-entry storage
with before/after capture and tamper-evident chaining, OBS-03/XC-02);
REQ-196 (Serve `GET /api/v1/audit` from the audit store); REQ-197
(Extend `expr.ex` with arithmetic and a structured error surface);
REQ-198 (`expr.ex`'s 8 pure builtin functions); REQ-199 (Correlated
effect re-entry ordering, ORD-01/02/03/04); REQ-200 (Instance timeline
rendering — actor display names and descriptions, OBS-04); REQ-201
(Alerting hooks with edge-triggered firing, OBS-06); REQ-202
(Content-addressed artifact store and the REPO-04 canonicaliser); REQ-203
(Per-tenant artifact activation with atomic groups and history).

REQ-200 and REQ-201 were added in the batch's **rework 1**
(REQ-VALIDATOR gate, 2026-08-29): `src/obs/timeline.zig` and
`src/obs/alerts.zig` had been left unscoped while this doc asserted
`src/obs` was covered. Both were investigated rather than deferred —
`timeline.zig` turned out to close a live broken contract with the
already-shipped SPA (`TimelineFeedItem.tsx` renders `description`,
`actor_display_name`, `timestamp` and `sequence_num`, none of which
the REQ-080 route emits), and `alerts.zig` had no external blocker
because all four of its triggers are produced by this stage's own
requirements.

REQ-202 and REQ-203 were added in **rework 2** (same gate, same defect
class one subsystem over): the rework-1 exhaustiveness assertion was
false for `src/repository`, where `artifacts.zig`, `canonicaliser.zig`,
`activation.zig` and `schemas.zig` had neither an owning requirement nor
a deferral behind a bare `REQ-191–192` range. The first three are one
content-addressed artifact subsystem with no blocker (verified:
`artifacts.zig` imports `canonicaliser.zig`, `activation.zig` imports
`artifacts.zig`, all three cite `src/design/repository.md`), so they
were drafted; `schemas.zig` is keyed to the `artifact_versions` table
REQ-202 creates, so it became deferral item 4 below.

## Scope

Port the remaining cross-cutting subsystems not covered by earlier
stages:

File counts below were re-verified directly against
`c:\Users\tvolo\dev\ai-dala\R-Co\` on 2026-08-29 while expanding the
second batch; a few differ from this doc's original estimates, which
predated R-Co being reachable from a drafting session.

- `src/scheduler` (6 files) — owned by REQ-185–188
- `src/secrets` (6 files) + `src/secrets/integration` (1) — all seven
  under REQ-189 (the decision) and REQ-190 (the implementation):
  `store.zig`, `crypto.zig`, `reference.zig`, `resolver.zig`,
  `redaction.zig` and `mod.zig`, plus
  `integration/webhook_keys.zig`, whose behaviour is REQ-190's webhook
  HMAC key reconciliation
- `src/obs` (5 files) — observability/metrics — named per file,
  because a range alone previously asserted coverage two of them did
  not have (REQ-VALIDATOR, rework 1): `logger.zig` → REQ-193;
  `metrics.zig` → REQ-194; `audit.zig` → REQ-195 + REQ-196;
  `timeline.zig` → REQ-200; `alerts.zig` → REQ-201.
  (`obs/dlq` equivalent, OBS-05, is REQ-176–178)
- `src/webhook` (3 files) — REQ-181–184
- `src/dlq` (1 file) — dead-letter queue — REQ-176–178
- `src/repository` (7 files) — named per file, for the same reason
  `src/obs` is (a bare range here concealed four unowned files until
  REQ-VALIDATOR caught it in rework 2): `service_catalog.zig` →
  REQ-191 + REQ-192; `artifacts.zig` + `canonicaliser.zig` → REQ-202;
  `activation.zig` → REQ-203; `mod.zig` is a re-export barrel with no
  behaviour of its own; `schemas.zig` and `process_module_catalog.zig`
  are deferrals, both listed below.
- `src/expr` (7 files) — expression evaluation — REQ-197–198
- `src/ordering` (5 files) — all five under REQ-199: `consumer.zig`,
  `cursor.zig`, `sweeper.zig`, `observability.zig` (ORD-04's lag
  measurement; its contention-driven consumer reduction is deferred
  inside that requirement) and `mod.zig`

These are grouped together because each is relatively self-contained
and none blocks S3/S4's critical path, but each still needs its own
requirement(s) once this stage starts — "cross-cutting" describes
their relationship to the rest of the system, not that they're
interchangeable or low-effort individually.

### Deliberately not covered

Five items, each with a named blocker:

1. **`src/scheduler/partition_maintenance.zig` and
   `partition_retention.zig`** — both operate on a partitioned `events`
   table Letflow does not have. Blocked by decision 0003 Decision C's
   partitioning deferral, reaffirmed by ISS-0014's adopted option (a).
   See Decisions. Stated in REQ-188.
2. **`src/expr/benchmark.zig`** — a DSL-13 latency harness (1,000
   warm-up + 10,000 measured iterations against a 10 us target), output
   via debug print, imported by nothing. No production behaviour to
   port. Stated in REQ-197.
3. **`src/repository/process_module_catalog.zig`** (PLC-01/PLC-02) —
   greenfield and unscoped to any Letflow stage; `SUB_PROCESS`
   `module_ref` resolution would need a definitions-side change first.
   Stated in REQ-191.
4. **`src/repository/schemas.zig`** (REPO-05, form-schema indexing) —
   blocked on REQ-202. It is a field-level search/discovery index over
   form artifacts **keyed to `artifact_versions`**, which is exactly the
   table REQ-202 creates, so it is not draftable until the artifact
   store exists. REQ-109 (done, S3) already names it out of scope and
   warns that grepping "form schema" lands here first and "would build
   the wrong mechanism" — that warning stands, and is why this is a
   deferral rather than an oversight.
5. **The repository HTTP surface** (R-Co REPO-11–14,
   `POST /repository/artifacts` and friends) — no consumer contract
   exists to build to, and there is nothing upstream to port: verified
   that despite REPO-11–14 being marked RELEASED, the routes were never
   built in R-Co (no `repository/artifacts` handler anywhere under
   `src/api/`, no repository policy key in its `authorization.zig`, and
   REPO-11's own `implemented_in` points at `services.zig`, which holds
   only service-catalog handlers). Letflow has no SPA consumer either.
   Stated in REQ-202.

This list is exhaustive, and deliberately falsifiable — that
falsifiability is the only reason the gaps in items 4–5 were ever
found. Every other `.zig` file in the subsystems above has a named
owning requirement in the per-subsystem list. Re-verified file by file
against the real R-Co tree at rework 2 across all six second-batch
subsystems (scheduler 6 files, secrets 6 + 1 under `integration/`, obs
5, repository 7, expr 7, ordering 5). Rework 1 added REQ-200/201
because `timeline.zig` and `alerts.zig` were missing from both lists;
rework 2 added REQ-202/203 and items 4–5 because `artifacts.zig`,
`canonicaliser.zig`, `activation.zig` and `schemas.zig` were missing
from both. Any future omission belongs here rather than being left
implicit.

## Decisions

**Two decision requirements are the gates on this stage's two hardest
halves.** Both are drafted in the shape S5 used for its open questions
(REQ-148/149/150): a requirement whose deliverable is a *decided
answer*, including a decided "no", rather than a blocker described
inside the requirement it blocks.

**1. Secrets storage backend — REQ-189, producing
`decisions/0016-secrets-storage-backend.md`.** This section previously
read "Likely needs a decision file for `src/secrets` specifically
(secret storage/retrieval backend choice) — defer until this stage
starts." The stage has started, so REQ-189 owns writing that file. It
must settle: the backend (Letflow-owned Postgres table vs. external
KMS); where the master key comes from and that startup *fails* without
it; the table's placement against decision 0003 Decision B (R-Co made
`secrets` global, which departs from the general per-tenant rule); the
secret-reference syntax; the crypto and its honestly-labelled metadata;
and the rotation model.

REQ-189 also resolves a **live contradiction between two already-pending
first-batch entries**: REQ-181 stores `webhook_subscriptions.secret`
*hashed*, while REQ-183 specifies HMAC-SHA256 signing "using the
subscription's stored secret" — and a hash cannot serve as an HMAC key.
EXP-501 assigns webhook HMAC keys to the secrets module, and R-Co
resolved the identical problem by adding `secret_ref`/`secret_key_id`
columns and blanking the plaintext (`GBL-128_exp501_secrets.sql`, with
correctives `1134_iss0112_*` and `1138_iss0635_*`). REQ-189 chooses
Letflow's resolution; REQ-190 implements it.

**2. Scheduler timer-firing architecture — REQ-185, SETTLED (done,
2026-08-29).** `lib/letflow/design/req185-scheduler-firing-architecture.md`
is the artefact of record — not a `decisions/` record, because it
selects a BEAM realisation of behaviour R-Co's SCH-02 already specifies
rather than settling a new cross-cutting policy, following REQ-148/149/
150's own S5 precedent that this class of decision lives in the design
artefact rather than a separate `decisions/*.md` file. Settled: the
firing mechanism is a supervised `GenServer` ticker
(`Process.send_after/3`, added to `lib/letflow/application.ex`'s tree);
Oban is **NOT** adopted as a `mix.exs` dependency, with REVIEWER
sign-off on that NO recorded directly in the artefact's §3; the claim
mechanism is `FOR UPDATE SKIP LOCKED`, per the correction below; no
ISS-302-equivalent session-level startup-sweep lock is adopted; the
poller iterates tenant schemas per tick, with a quantified cost stated
at 500 tenants; an exhausted-retry timer lands in REQ-176's
`dlq_entries` with `entry_type` `"timer"`. REQ-186, REQ-187 and REQ-188
were unblocked by this requirement.

**REQ-186, SETTLED (done, 2026-08-29).** Timers schema and scheduler
core built on REQ-185's artefact: the tenant-scoped `timers` migration
(status/recurrence CHECK constraints, partial index on `(fire_at)
WHERE status = 'pending'`) plus a scheduler core implementing the
`FOR UPDATE SKIP LOCKED` claim-and-fire loop, missed-timer recovery
(`fired_late: true`), and failure accounting (a failed fire attempt
increments `fire_error_count` in a separate transaction without
stopping the poll cycle; a timer exhausting its configured retries
moves to `failed` and lands in `dlq_entries` with `entry_type`
`"timer"`). Core only -- no route/controller. RELEASE-VALIDATOR
independently re-verified all 10 acceptance criteria -- PASS. REQ-187
(`transition.ex` wiring + cancellation) and REQ-188 (recurrence +
escalation) are now unblocked.

Note one correction it must carry: SCH-02's literal text mandates a
per-timer PostgreSQL advisory lock, but R-Co **removed** that
mechanism — `src/design/scheduler-concurrency-epic3.md`'s ISS-301
section deletes it as redundant against `FOR UPDATE SKIP LOCKED`. Only
a *session*-level advisory lock guarding the startup sweep survives. A
port written to SCH-02's literal text would reintroduce deleted code.

**REQ-187, SETTLED (done, 2026-08-29).** TIMER nodes wired into the
engine: `transition.ex` L294's catch-all now arms a REQ-186 timer on
token arrival (`fire_at` = arrival time + the node's parsed
`duration_iso8601`), persisted in the SAME transaction as the
state-transition event; `task_activation.ex`'s
`cancel_pending_timers/2` no-op is replaced with a real update that
cancels every PENDING timer for the instance, still called from its
original, unmoved call site inside `engine.ex`'s completion
transaction; and `engine.ex` L234-242's recorded EE-08 deferral is
closed for the timer half via an equivalent cancellation call inside
`cancel_instance/3`'s own transaction (REQ-056's SERVICE_TASK
HTTP-abort half stays deferred). `transition.ex`'s purity is preserved
throughout -- no `Repo` call was added; the timer-arming description is
carried through an existing return shape extended for this purpose.
This was the most architecturally complex requirement in this batch (a
nested SAVEPOINT transaction, a genuine AB-BA lock-ordering deadlock
hazard found by CODE-DESIGN-VALIDATOR and fixed, and a
multi-timer-in-one-hop-chain `Ecto.Multi` step-name collision hazard
closed with a typed guard), yet it ran with zero rework rounds through
the design/security/reviewer/test-design gates. RELEASE-VALIDATOR
independently re-verified all 10 acceptance criteria, including the
fragile lock-ordering fix -- PASS, no gap found. This closes REQ-186's
engine-integration half; REQ-188 (recurrence, SCH-07, plus escalation
and the retention runner) was the last remaining piece of the
scheduler half.

**REQ-188, SETTLED (done, 2026-08-29/30) -- closes the scheduler half
in full.** Two deliverables sharing REQ-186's poll loop mechanism:
SCH-07 recurring-timer re-arm (a fired recurring timer creates its NEW
pending successor in the SAME transaction as the firing; `repeat_total`
exhaustion ends the chain with no new timer; a cancelled instance's
chain does not re-arm; an interval shorter than the poll interval fires
at most once per cycle rather than catching up multiple occurrences),
and a periodic retention runner added to REQ-186's existing scheduler
process (not a second independent ticker) invoking the already-shipped
but previously zero-caller `Letflow.EventStore.archive/1`, **disabled
by default**. Path: 2 real rework rounds (CODE-DESIGN-VALIDATOR caught
literal Elixir code fences in the design; TEST-DESIGN-VALIDATOR caught
a factually-wrong claim about REQ-187's auto-rearm side-effect in test
documentation, independently traced and empirically confirmed rather
than trusted). SECURITY-REVIEWER and REVIEWER both passed cleanly.
RELEASE-VALIDATOR independently re-verified all 10 acceptance criteria
against the real shipped code (`lib/letflow/scheduler.ex`,
`lib/letflow/scheduler/poller.ex`) -- PASS, no gap found
(`handoffs/WF02-REQ188-20260829/release-validation-req188.md`). With
this, **REQ-185, REQ-186, REQ-187 and REQ-188 are all done: S6's
scheduler half is complete.** S6's secrets half (REQ-189 onward) is a
separate track and remains open.

**Deliberately deferred, blocker named:** `partition_maintenance.zig`
and `partition_retention.zig` are **not** ported. Both need a
partitioned `events` table, which Letflow does not have. Decision
0003 Decision C point 2 defers partitioning, and ISS-0014 (resolved
2026-08-17) already adjudicated exactly this — adopting option (a),
keeping REQ-026's row-level `archive/1`, and expressly rejecting option
(c) because porting partition retention now "would force partitioning
early, contradicting 0003 Decision C's deliberate deferral, and would
need REVIEWER sign-off / a new decision record". Reopening it needs a
new decision record. REQ-188 schedules the `archive/1` that does
exist, disabled by default. SCH-04 escalation timers are also
deferred: they require a `HUMAN_TASK` node carrying an
`escalation_timer_duration` attribute, and Letflow's
`Letflow.Definitions.Graph` has no such attribute and no validator for
one yet -- a definitions-side requirement is needed before escalation
timers can be built.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
