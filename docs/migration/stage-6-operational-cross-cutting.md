# Stage 6 — Operational cross-cutting

Status: active. Depends on: S4. REQ-176 (DLQ schema and core entry
lifecycle), REQ-177 (DLQ landing hooks) and REQ-178 (DLQ route layer)
are all done as of 2026-08-29 -- the first batch's DLQ half is now
fully complete. REQ-181 (Webhook subscription schema and core) is also
done as of 2026-08-29; REQ-182 (the webhook route layer atop it) is
still pending. Requirements, expanded in two batches:

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

**2. Scheduler timer-firing architecture — REQ-185**, an artefact under
`lib/letflow/design/`, not a `decisions/` record, because it selects a
BEAM realisation of behaviour R-Co's SCH-02 already specifies rather
than settling a new cross-cutting policy. It must decide whether Oban
becomes a dependency (with REVIEWER sign-off either way), the claim
mechanism, and how the poller relates to per-tenant schemas.

Note one correction it must carry: SCH-02's literal text mandates a
per-timer PostgreSQL advisory lock, but R-Co **removed** that
mechanism — `src/design/scheduler-concurrency-epic3.md`'s ISS-301
section deletes it as redundant against `FOR UPDATE SKIP LOCKED`. Only
a *session*-level advisory lock guarding the startup sweep survives. A
port written to SCH-02's literal text would reintroduce deleted code.

**Deliberately deferred, blocker named:** `partition_maintenance.zig`
and `partition_retention.zig` are **not** ported. Both need a
partitioned `events` table, which Letflow does not have. Decision
0003 Decision C point 2 defers partitioning, and ISS-0014 (resolved
2026-08-17) already adjudicated exactly this — adopting option (a),
keeping REQ-026's row-level `archive/1`, and expressly rejecting option
(c) because porting partition retention now "would force partitioning
early, contradicting 0003 Decision C's deliberate deferral, and would
need REVIEWER sign-off / a new decision record". Reopening it needs a
new decision record. REQ-188 therefore schedules the `archive/1` that
does exist.

## REVIEWER sign-off

(None yet — this stage hasn't started.)
