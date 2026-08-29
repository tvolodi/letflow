# Stage 6 — Operational cross-cutting

Status: active. Depends on: S4. REQ-176 (DLQ schema and core entry
lifecycle) done as of 2026-08-29 -- the stage's first completed
requirement. Requirements, expanded in two batches:

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
effect re-entry ordering, ORD-01/02/03/04).

## Scope

Port the remaining cross-cutting subsystems not covered by earlier
stages:

File counts below were re-verified directly against
`c:\Users\tvolo\dev\ai-dala\R-Co\` on 2026-08-29 while expanding the
second batch; a few differ from this doc's original estimates, which
predated R-Co being reachable from a drafting session.

- `src/scheduler` (6 files) — owned by REQ-185–188
- `src/secrets` (6 files) + `src/secrets/integration` (1) — REQ-189–190
- `src/obs` (5 files) — observability/metrics — REQ-193–196
  (`obs/dlq` equivalent, OBS-05, is REQ-176–178)
- `src/webhook` (3 files) — REQ-181–184
- `src/dlq` (1 file) — dead-letter queue — REQ-176–178
- `src/repository` (7 files) — REQ-191–192
- `src/expr` (7 files) — expression evaluation — REQ-197–198
- `src/ordering` (5 files) — REQ-199

These are grouped together because each is relatively self-contained
and none blocks S3/S4's critical path, but each still needs its own
requirement(s) once this stage starts — "cross-cutting" describes
their relationship to the rest of the system, not that they're
interchangeable or low-effort individually.

Three parts of the above are deliberately **not** covered by the two
batches, each with its blocker recorded in the owning requirement:
`src/scheduler/partition_maintenance.zig` and `partition_retention.zig`
(partitioning deferral — see Decisions); `src/expr/benchmark.zig` (a
latency harness with no production behaviour, imported by nothing); and
`src/repository/process_module_catalog.zig` (PLC-01, greenfield and
unscoped to any Letflow stage — `SUB_PROCESS` `module_ref` resolution
would need a definitions-side change first).

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
