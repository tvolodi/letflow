# ISS-0430 — Postgres LISTEN/NOTIFY as a push channel: decision document

**Status:** decision, no implementation. This document answers ISS-0430's five design
questions plus the reframed retrofit question. It does not implement a consumer.
**AC8 confirmation:** no `.ex` file bodies, no GenServer callback implementations, and
no migration DDL are included below beyond one illustrative schema-shape sketch in
Question 3, which is descriptive only (field names/types), not runnable code.

## Inputs this document builds from (not re-derived)

- `docs/issues/ISS-0430.yaml` (the task, including its SEQUENCING NOTE — REQ-214,
  REQ-219, REQ-220 have all shipped; this is a retrofit question against two
  already-existing pollers, not a greenfield sequencing choice).
- `handoffs/WF03-ISS0430-20260905/step-01-issue-fixer-diagnose.json`'s `result.summary`
  — quoted poller mechanics (poll intervals, config keys, claim-query shapes,
  supervision placement) and decision 0003 Dimension B's verbatim `:prefix` mechanism.
  Re-read directly from `lib/letflow/supervisor/pollers.ex`,
  `lib/letflow/supervisor/infrastructure.ex`, and `lib/letflow/application.ex` in this
  session to confirm the diagnosis's supervision-tree claims before building on them
  (per `core-directives.md`'s "a handoff's factual premises are checkable" — confirmed
  accurate: `Infrastructure` / `Pollers` (`restart: :temporary`) / `PollersBreaker` /
  `Http`, in that order, `Pollers` holding the two poller GenServers as `:one_for_one`
  peers at `max_restarts: 5, max_seconds: 60`).
- **Correction to the handoff's task text, reported here per HANDOFF_PROTOCOL.md §1.1
  rather than silently propagated:** the handoff's Question 5 guidance names
  "this project's own ISS-0031 precedent ... referenced in HANDOFF_PROTOCOL.md's worked
  examples as 'running one assertion via a checked-out non-sandboxed connection'."
  Checked both sources. `docs/issues/ISS-0031.yaml` on disk is real but is a *different,
  unrelated* incident (a `:telemetry.attach/4` cross-process message leak in
  `tenant_status_test.exs`, resolved 2026-08-17 by filtering on `self() == test_pid`) —
  it has nothing to do with DDL visibility or non-sandboxed connections.
  `HANDOFF_PROTOCOL.md`'s own `<example name="partial">` block (lines ~828-839) is an
  **illustrative template** showing the shape of a `PARTIAL` result, not a record of a
  real event — it reuses "ISS-0031" as a plausible-looking placeholder id for a
  hypothetical `REQ-039` sandbox-pool fixture-loader scenario. The *technique it
  describes* (observing Postgres state committed by another connection, which a
  sandboxed Ecto connection cannot see, by running that one assertion through a
  deliberately checked-out non-sandboxed connection) is sound and is what Question 5
  below builds on — but it is cited here as "the technique HANDOFF_PROTOCOL.md's worked
  example illustrates," not as prior art from a shipped fix under ISS-0031. Flagged at
  MINOR severity for the handoff record; does not change the technical answer to
  Question 5, which stands on the technique's own merits against Ecto/Postgrex's
  documented sandbox behavior (see Question 5).

---

## Question 1 — Connection ownership

**Decision: exactly ONE application-wide `Postgrex.Notifications` connection**, owned by
a new, dedicated GenServer wrapper — not a bare `Postgrex.Notifications` child spec
placed directly in a supervisor's children list, and not one connection per tenant
schema.

### Why one connection, not N (per-tenant or per-poller)

- `Postgrex.Notifications` is a raw connection outside Ecto's pool: it cannot be
  checked back in, cannot be reused for ordinary queries, and holds one TCP connection
  to Postgres for its entire lifetime (Postgrex's own documented model — LISTEN state is
  a property of the *session*, not of a query, so pooling it defeats the purpose).
  `docs/migration/decisions/0009-test-parallel-pool-sizing.md`'s whole subject is that
  connection count is a scarce, budgeted resource (`max_connections`, currently profiled
  against a 100-connection Postgres in dev/test) — a per-tenant-schema LISTEN connection
  would scale connection count with tenant count, which is exactly the unbounded-growth
  shape 0009 exists to prevent for the Ecto pool side; there is no reason to reintroduce
  it on the NOTIFY side.
- Channel names are not schema-scoped in Postgres (see Question 2) — so a per-tenant
  connection would not even buy per-tenant isolation; it would only buy N-times the
  connection cost for zero additional isolation benefit. There is no version of "one
  connection per tenant" that improves the tenant-isolation story, so the only live
  argument for more than one connection is per-consumer isolation (one for
  `Scheduler.Poller`'s wake channel, one for `ServiceTaskDispatcher.Poller`'s wake
  channel), which the design chooses not to take — see next paragraph.
- **One connection, two channels, not two connections.** `Postgrex.Notifications`
  supports `Postgrex.Notifications.listen/2` (or `listen!/2`) being called multiple
  times against the same connection process, once per channel name — a single
  `Postgrex.Notifications` GenServer can `LISTEN` on both `"dispatch_ready"` (for
  `ServiceTaskDispatcher.Poller`) and `"timer_ready"` (for `Scheduler.Poller`)
  simultaneously and demultiplexes incoming `{:notification, pid, ref, channel,
  payload}` messages by `channel`. This keeps the connection budget at exactly 1
  regardless of how many future wake-up producers are added, and avoids the two
  pollers racing to own "the" LISTEN connection.

### Does it count against `Repo.pool_size` or Postgres `max_connections`?

**Separately from `Repo.pool_size`, but yes against Postgres `max_connections`.**
`Postgrex.Notifications.start_link/1` opens its own independent `Postgrex` connection
process; it is never a member of `Letflow.Repo`'s Ecto pool (`Ecto.Adapters.SQL.Sandbox`
/ `DBConnection` pool sizing, governed by `config :letflow, Letflow.Repo, pool_size:
...`, is entirely orthogonal code). It DOES occupy one of Postgres's own
`max_connections` slots, identically to any other client connection. Budgeting
consequence: **+1** to the fixed connection count the deployment must plan for, on top
of `Repo.pool_size` and the `TEST_NONPOOL_CONNECTION_RESERVE`-tracked non-pooled test
connections that decision 0009's addendum already accounts for
(`test/support/tenant_schema_reaper_test.exs`'s own raw `Postgrex.start_link` connection
is the existing precedent for "a connection Ecto's pool-sizing arithmetic must not
silently miss"). In test config specifically, this new connection must be added to
`TEST_NONPOOL_CONNECTION_RESERVE`'s accounted set (currently at 2, one of which is the
tenant-schema-reaper's own probe) — **open item, not resolved here**, see Open
Questions.

### Where in the CURRENT supervision tree (AC5)

**As a new child of `Letflow.Supervisor.Infrastructure`, placed immediately after
`Letflow.Repo` and its `Ecto.Migrator` entry (after infra child 2, before child 3,
`Oidcc.ProviderConfiguration.Worker`), never inside `Letflow.Supervisor.Pollers` and
never as a new top-level sibling supervisor.**

Justification against the tree's own already-documented ordering/restart-intensity
reasoning, checked point by point:

1. **Not inside `Pollers`.** `Pollers`' own moduledoc states its restart-intensity
   override (`max_restarts: 5, max_seconds: 60`, looser than OTP default) exists
   specifically "to tolerate a handful of transient per-tick failures... without this
   supervisor itself exiting," and its own accepted consequence is that "once ONE
   poller's own crash-loop exhausts this shared... budget, THIS SUPERVISOR itself exits
   and restarts, which restarts BOTH pollers together." A `Postgrex.Notifications`
   connection is infrastructure with a completely different failure profile — a
   Postgres-side connection drop is not a "bad HTTP dispatch" or "a single locked row"
   the way a poller tick fault is; it is closer in kind to `Letflow.Repo` itself losing
   its connection. Placing it inside `Pollers` would make a LISTEN-connection failure
   consume `Pollers`' crash budget and potentially restart both poller GenServers
   needlessly (they do not depend on the LISTEN connection to function — see Question 4,
   "polling is retained" — so a LISTEN failure should never cascade into a poller
   restart). It would also make `Pollers`' own top-level `restart: :temporary`
   (ISS-0451: "the top-level `Letflow.Supervisor` structurally NEVER auto-restarts
   `Letflow.Supervisor.Pollers`, for any exit, ever") apply to the LISTEN connection too
   — meaning a genuinely transient LISTEN-connection blip that exhausts `Pollers`' local
   budget would need `PollersBreaker`'s state machine to notice and restart it, an
   indirection with no benefit here since the LISTEN connection has no coupling to
   either poller's own crash-loop hazard.
2. **Not a new top-level sibling supervisor.** `Letflow.Application`'s own top-level
   list (`Infrastructure`, `Pollers` (`:temporary`), `PollersBreaker`, `Http`) is a
   4-entry, already-reasoned-about ordering where `:one_for_one` was chosen specifically
   because "every named-process infra child is looked up BY NAME at its call sites,
   never by stored pid, so a rare Infrastructure exit has no pid-based dependency reason
   to also force-restart Pollers or Http." Adding a 5th top-level sibling for exactly
   one child is unjustified sprawl relative to `Infrastructure`'s own stated purpose (it
   already exists to hold "the 17 infrastructure children" as a single `:one_for_one`
   group) — a LISTEN connection is infrastructure by every criterion `Infrastructure`'s
   own moduledoc uses to justify its 17 existing children (e.g. `Letflow.Admission`:
   "NO ordering dependency in either direction... placed here as a readability choice,
   grouped with the other leaf/independently-startable infrastructure children").
3. **Ordering inside `Infrastructure`: after `Letflow.Repo`/`Ecto.Migrator`, before
   everything else.** `Postgrex.Notifications.start_link/1` needs Postgres reachable and
   (for LISTEN targets that matter, e.g. any channel a migration-created trigger fires
   on) migrations already applied — so it must start after child 1 (`Letflow.Repo`) and
   child 2 (`Ecto.Migrator`), exactly mirroring why `Ecto.Migrator` itself is child 2
   (it needs `Letflow.Repo` up first). Nothing else in `Infrastructure`'s existing 17
   children depends on the LISTEN connection starting before it (none of
   `Oidcc.ProviderConfiguration.Worker`, `Letflow.Registry`, `Letflow.Metrics.Registry`,
   `Letflow.Admission`, `Letflow.InstanceSupervisor`, the `SandboxPool`/plugin/Lua/Wasm
   Task.Supervisors, or `Obs.Alerts.TaskSupervisor` reference or depend on a NOTIFY
   channel), so placing it directly after `Ecto.Migrator` and before
   `Oidcc.ProviderConfiguration.Worker` is a readability/dependency-order choice, not a
   correctness requirement past "after Repo/Migrator" — mirroring `Letflow.Metrics.Registry`'s
   own documented placement reasoning ("a leaf, independently-startable component with
   no startup-order dependents... placed directly after the generic Elixir Registry
   above").
4. **Does not silently contradict ISS-0429's or ISS-0451's ordering guarantees.**
   ISS-0429's guarantee ("`Obs.Alerts.TaskSupervisor` must precede either Poller's first
   tick") is about the last child of `Infrastructure` preceding `Pollers`' own
   supervisor-boundary start — unaffected, since the new LISTEN-connection child sits
   earlier in `Infrastructure`'s own list, still strictly before `Pollers` starts at
   all (the `Infrastructure` → `Pollers` supervisor-boundary ordering is untouched).
   ISS-0451's guarantee (`Pollers`' `restart: :temporary`, `PollersBreaker` as sole
   restarter) is scoped to `Pollers` and its two poller GenServer children; placing the
   LISTEN connection in `Infrastructure` means it is governed by `Infrastructure`'s own
   OTP-default restart intensity (3/5s, deliberately left unloosened per that module's
   own moduledoc: "a crash-looping infra child... indicates a fault severe enough that
   taking the whole application down is still the correct behavior") — appropriate,
   since a `Postgrex.Notifications` connection that cannot stay connected to Postgres at
   all is exactly that kind of severe fault, not a transient per-tick blip.

**Wrapper, not a bare child spec.** The child registered in `Infrastructure`'s list is a
thin `GenServer` wrapper module (illustrative name: `Letflow.Notify.Listener`) that owns
the `Postgrex.Notifications` connection internally (via `Postgrex.Notifications.start_link/1`
inside its own `init/1`, or as a linked child it monitors), calls `listen/2` for each
known wake channel once connected, and re-subscribes on reconnect
(`Postgrex.Notifications` auto-reconnects on connection loss per its own documented
behavior, but a fresh connection has no LISTEN state — the wrapper must reissue
`listen/2` calls after every `{:disconnected, pid}`-then-reconnect cycle, not just at
`init/1`). The wrapper is what would, in a future consumer, translate an incoming
`{:notification, ...}` message into a wake-up signal for the relevant Poller (e.g. via
`send/2` to a registered process name) — not implemented here (AC8), only its
supervision placement and shape are decided.

---

## Question 2 — Multi-tenancy (the hardest part)

**Decision: option (a) from the issue text — a single shared channel per wake-up
category, NOTIFY payload carrying only an opaque, non-tenant-identifying routing id
(the changed row's primary key), never tenant-identifying data. The receiving side does
a normal `:prefix`-scoped fetch and silently discards an id that resolves to nothing
under the expected tenant schema.** Option (b) (per-tenant channel naming) is
considered and rejected below, not silently passed over.

### Why option (a), reasoned against decision 0003 Dimension B concretely

Decision 0003 Dimension B's mechanism (quoted verbatim in the diagnosis handoff) is:
tenant isolation is a **physical Postgres-schema boundary**, enforced **per query** via
Ecto's `:prefix` option (`Repo.all(query, prefix: tenant_schema)`), with **no
connection-level or session-level tenant context** — the 2026-08-17 addendum explicitly
rejected building one. `LISTEN`/`NOTIFY` is a database-global namespace with **zero**
concept of `search_path` or schema scoping — Postgres does not consult `:prefix`,
`search_path`, or any session GUC when routing a `NOTIFY` to listeners; every backend
that has issued `LISTEN <channel>` on that database receives every `NOTIFY <channel>`
on it, full stop, regardless of which schema the triggering transaction ran in.

This means: **there is no mechanism inside Postgres's own NOTIFY delivery path that
can enforce INV-1 the way `:prefix` enforces it for ordinary queries.** Any design that
tries to make the NOTIFY layer itself tenant-aware is fighting Postgres's actual
architecture, not working with it — so the correct design response is not to attempt
tenant-scoping AT the NOTIFY layer at all, but to ensure the NOTIFY layer **never
carries anything an unscoped delivery could leak**, and to push 100% of the actual
tenant-isolation enforcement back onto the mechanism decision 0003 already established
(the `:prefix`-scoped fetch) — the NOTIFY message is reduced to "something happened,
somewhere, go poll now," structurally incapable of being a tenant-data leak because it
never carries tenant data.

**Concretely:** a `NOTIFY` payload under this design is a bare integer/UUID primary key
(e.g. a `service_task_dispatches.id` or a `timers.id`) with no schema name, no tenant
name, no column value, no row content of any kind. The receiving `Letflow.Notify.Listener`
process (or whichever process it wakes) does **not** trust or act on that id directly —
it either (i) triggers a poll of the relevant tenant's own claim query as normal (id
used only to short-circuit "should I bother polling right now," not "fetch this exact
row"), or (ii) if a future consumer wants to fetch the specific row, it does so via
`Repo.get(Schema, id, prefix: expected_tenant_schema)` for **the tenant schema that
listener/consumer is already scoped to operate on** — never a schema derived from the
NOTIFY payload itself. If the id does not exist under that `:prefix`, the fetch returns
`nil`/empty and the id is discarded. This is exactly decision 0003's own mechanism,
applied unchanged; nothing new is invented for the tenant-isolation half of this design.

### Does this leak ANYTHING? Worked through explicitly, per the issue's own instruction

**Row-existence-adjacent timing signal:** A process that is (hypothetically, per the
issue's "future multi-listener design" framing) listening on the shared channel but
entitled to only one tenant's data receives every id fired by every tenant, and could
measure "how long did my own `Repo.get(prefix: my_schema)` fetch take, and did it return
something." This tells that process nothing about *other* tenants: it never issues a
fetch against another tenant's `:prefix` (it only knows its own), so it learns nothing
more than "a NOTIFY with id X arrived" for ids that are never resolved under its own
schema — no timing signal is generated on the *listener's own side* for tenants it does
not query. What it CAN learn, structurally, is that **some tenant, somewhere, had a row
change** at roughly that wall-clock moment — a bare existence-of-activity signal with no
tenant attribution attached, no more informative than being able to observe "Postgres's
WAL is not idle right now" from outside. **Verdict: this is an acceptable, extremely
low-information leak — activity happened, tenant unknown, row content unknown — not a
violation of INV-1**, which is specifically about *tenant DATA* exposure (a row's
content or a fact keyed to a specific tenant's identity), neither of which this signal
carries.
**Row-existence timing at the SOURCE:** does the *sender* (Postgres itself) leak more by
NOTIFYing on every insert regardless of tenant? No — `NOTIFY` fires from inside the
transaction that performed the write, at COMMIT; it does not run any code in a
listener's context, so there is no code path by which the choice "NOTIFY every insert"
reveals anything Postgres wasn't already going to reveal via the transaction commit
timing itself (observable only to something already watching Postgres internals, out of
scope for an application-level tenant-isolation invariant).

**ID-space cross-tenant enumeration risk (sequential/correlatable ids):** This is the
real risk named in the issue text, and it is real IF the routing id is a naively
sequential integer PK shared across all tenants' rows in the SAME table (Letflow's
schema-per-tenant model means `service_task_dispatches` and `timers` each exist as
**separate physical tables per tenant schema** — decision 0003 Dimension B: "Letflow
adopts Postgres schema-per-tenant as the tenant-isolation mechanism" — so a given
tenant's `service_task_dispatches.id` sequence is that tenant's own table's own
sequence, NOT a cross-tenant-shared sequence numbering all tenants' dispatches
together). Because each tenant's `id` sequence lives inside that tenant's own schema
(one physical Postgres sequence object per schema-qualified table, per how
`CREATE SCHEMA`-based multi-tenancy provisions each tenant's tables), a listener cannot
correlate "tenant A had id 41, tenant B had id 42" into "A and B are adjacent in some
shared ordering" — **there is no shared ordering to observe**, because the ids come from
disjoint per-schema sequences. A listener CAN observe the raw numeric magnitude of ids
firing on the shared channel (e.g. "ids in the low hundreds are appearing today") and
could, in principle, infer something about the *relative growth rate* of whichever
tenant happens to be generating the most NOTIFY traffic at a given moment — but cannot
attribute any specific id to any specific tenant (that attribution requires already
knowing which `:prefix` the id resolves under, which requires already being entitled to
that tenant's schema). **Verdict: the enumeration risk the issue names is real in
general for sequential ids, but is structurally defused here specifically because
Letflow's tenant tables are per-schema, not per-tenant-column-in-a-shared-table** — a
future engineer must not weaken this by ever centralizing these tables into a single
shared-table-with-tenant_id design without re-litigating this section.

### What a compromised/malicious future listener could and could not learn

Stated explicitly, per the issue's own instruction:

- **Could learn:** that *some* tenant's tracked row (a timer or a service-task dispatch)
  changed, approximately when (NOTIFY delivery is near-real-time after COMMIT), and the
  bare numeric/UUID value of that row's own per-tenant-schema primary key.
- **Could NOT learn:** which tenant the change belongs to; any column value of the
  changed row (workflow variables, dispatch payload, timer fire-time, task
  identifiers); whether two ids observed close together belong to the same or different
  tenants (no shared ordering to correlate against, per above); the existence or
  non-existence of any *other* tenant's data (a listener never issues a `:prefix`-scoped
  fetch for a tenant it is not already entitled to, so it never generates or observes a
  hit/miss signal for one).

### Why option (b) (per-tenant channel names) is rejected, not silently skipped

`NOTIFY "dispatch_ready_<tenant_schema>"` was considered. Rejected for two independent,
each-individually-sufficient reasons named in the issue text and confirmed true here:
(1) **it buys nothing.** A single BEAM-side `Postgrex.Notifications` connection (Question
1's decision: exactly one) would still need to `LISTEN` on every tenant's channel to
receive any tenant's wake-ups at all — the "entitlement" framing in option (b) only
makes sense for a *future* multi-listener design where different listener processes are
entitled to different tenant subsets, which does not exist today and is explicitly out
of scope (ISS-0430's own text: "a real-time push path to web/... NOT in scope, listed so
the design does not foreclose it"). Until such a design exists, per-tenant channels add
provisioning cost (every `Letflow.TenantProvisioning` run would need to also issue
`LISTEN` for the new channel) for zero present-day isolation benefit — the single
connection listening to everything is exactly as exposed to "some tenant's activity
happened" as the shared-channel design, just with N times the channel-name bookkeeping.
(2) **it is a worse enumeration surface, not a better one.** A channel name is plaintext
and, per Postgres's own `pg_listening_channels()` / `pg_stat_activity`-adjacent
introspection, is visible to anything with sufficient database access to query listener
state — encoding the tenant schema name directly into the channel name turns "what
tenants exist" into a queryable list for anyone who can see channel names, which is
strictly worse than the shared-channel design's opaque, tenant-blind payload. Confirmed:
this is a genuine regression relative to option (a), not merely a wash.

### Verdict

**Adopted mechanism: option (a).** No state travels in a NOTIFY payload; the payload is
an opaque, never-tenant-identifying routing id; the actual tenant-isolation enforcement
remains 100% in decision 0003's existing `:prefix`-scoped fetch, applied by the
receiving side using its own already-known tenant scope, never a scope derived from the
NOTIFY message. This satisfies the ISS-0430 acceptance criterion that "the design states
Postgres remains the source of truth and NOTIFY payloads carry only
identifiers/routing hints, always treated as untrusted" (AC2/AC3, restated explicitly in
Question 3/4 below) and satisfies INV-1's BLOCKER-severity bar because the mechanism
that actually enforces isolation is unchanged from what INV-1 already requires and
verifies today.

**Flagged for SECURITY-REVIEWER (per ISS-0430's own acceptance criterion 4 — "SECURITY-REVIEWER
signs off on it as a tenant-data-path change"):** this document is the design artefact;
SECURITY-REVIEWER sign-off on the above reasoning happens at implementation time
(WF-02 Step 2c) against the actual consumer code, not against this document alone — this
document is written so that review has a concrete mechanism to check rather than a menu.

---

## Question 3 — Payload limit (8000 bytes)

**Decision: notify-then-fetch. The NOTIFY payload is always small enough that the 8000
byte limit is a non-issue by construction, never approached, let alone hit.**

Payload contents, by wake-up category (both illustrative of the decision, not
implementation — no `.ex` bodies):

| Channel (illustrative name) | Payload shape | Approx. byte size |
|---|---|---|
| `"timer_ready"` | stringified `timers.id` (integer or UUID text) | ~10-36 bytes |
| `"dispatch_ready"` | stringified `service_task_dispatches.id` | ~10-36 bytes |

No workflow variables, no dispatch payload, no error messages, no tenant/schema name —
nothing beyond the bare id — ever goes into a NOTIFY payload. This is not a size
optimization decided independently of Question 2; it is the SAME decision (id-only,
notify-then-fetch) serving both the multi-tenancy answer and the payload-limit answer at
once, which is why option (a) above was chosen over any design that tried to shortcut a
poll by shipping a partial row through the channel.

**Illustrative schema-shape sketch, needed to make "the fetch that follows a NOTIFY" concrete
(descriptive field list only, not a migration):**

- `timers` (existing, per the diagnosis's claim-query quote): `id`, `status`,
  `fire_at`, ... — the NOTIFY-driven fetch after a `"timer_ready"` message is
  conceptually `Repo.get(Timer, id, prefix: tenant_schema)`, or more precisely (since
  the poller's own claim query already does the real work) a wake-up that simply causes
  the existing `Letflow.Scheduler.Poller` to run its tick logic immediately rather than
  waiting for its next scheduled `Process.send_after/3` delay — no new fetch-by-id path
  is strictly required; see Question 6 (retrofit) for whether this wiring is worth
  building now.
- `service_task_dispatches` (existing, per the diagnosis's claim-query quote): `id`,
  `status`, `next_attempt_at`, `instance_id`, ... — same reasoning: the NOTIFY wakes
  `Letflow.Engine.ServiceTaskDispatcher.Poller`'s tick early; no new fetch-by-id path is
  required for the minimum viable design.

**Whether a trigger emitting NOTIFY needs a new DB object at all** is deferred to
Question 6/implementation — this design does not mandate a specific trigger-vs-application-level
`NOTIFY` call, only that whichever emits it, the payload discipline above applies
regardless of which layer issues the `NOTIFY`.

---

## Question 4 — Delivery semantics

**Decision: polling is retained, unconditionally, as the reconciliation backstop for
BOTH pollers, at their CURRENT intervals — no interval change is recommended by this
design.**

- **Retained interval, `Letflow.Scheduler.Poller`:** 5000ms (5s), sourced from
  `Letflow.Scheduler.poll_interval_ms/0`'s `@default_poll_interval_ms 5_000`, config key
  `Application.get_env(:letflow, :scheduler)[:poll_interval_ms]` — unchanged.
- **Retained interval, `Letflow.Engine.ServiceTaskDispatcher.Poller`:** 5000ms (5s),
  sourced from `ServiceTaskDispatcher.poll_interval_ms/0`'s `@default_poll_interval_ms
  5_000`, config key `Application.get_env(:letflow, :service_task_dispatcher)[:poll_interval_ms]`
  — a separate, independent config namespace per the existing "independent poll
  cadences" design intent, unchanged.

**Why not lengthen the interval, even if NOTIFY is adopted.** `NOTIFY` is, by Postgres's
own documented semantics, fire-and-forget: (1) **lost if no session is listening at the
moment of COMMIT** — a `Letflow.Notify.Listener` restart (OTP-default 3/5s restart
budget inside `Infrastructure`, per Question 1) has a real window where a `NOTIFY` fires
into nothing and no redelivery ever happens; Postgres does not queue undelivered
notifications for a session that reconnects later. (2) **delivered only on COMMIT**, so
any failure between a row's insert and its transaction's commit (a crashed backend, a
rolled-back transaction that a retry later re-attempts under a NEW transaction) either
never fires a NOTIFY or fires one whose row was in fact rolled back and no longer
exists — the polling claim query's own `WHERE status = 'pending' AND ... <= now()` shape
is naturally idempotent against both cases (a phantom NOTIFY for a rolled-back row
simply finds nothing to claim), while a NOTIFY-only design would have no equivalent
safety net. (3) **connection churn**: any Postgres-side connection drop/failover between
the LISTEN connection and Postgres (a documented, non-hypothetical operational event,
not a corner case) creates a gap during which zero NOTIFYs are received regardless of
how quickly the wrapper reconnects, because Postgres does not replay history.

Given all three, lengthening either poller's interval on the theory that "NOTIFY will
catch most work anyway" would convert the reconciliation backstop from "usually
redundant, always safe" into "the only mechanism catching whatever NOTIFY structurally
cannot deliver" running at a slower cadence — directly increasing the worst-case latency
for exactly the failure modes NOTIFY cannot cover. **This design recommends interval
retention at the current 5000ms for both pollers, unconditionally, regardless of whether
NOTIFY is adopted at all.** If a future requirement wants to widen the interval, that is
a separate decision requiring its own justification against these three failure modes,
not a free byproduct of adding NOTIFY.

---

## Question 5 — Test story

**Problem, stated precisely:** `Ecto.Adapters.SQL.Sandbox`'s default `:manual` mode
wraps each test in a transaction that is rolled back at test end (not committed).
Postgres's documented behavior is that `NOTIFY` is delivered **only on COMMIT** of the
issuing transaction (per PostgreSQL's own `NOTIFY` documentation: "if we are inside a
transaction, the notify event is not delivered until and unless the transaction is
committed"). A `NOTIFY` issued (directly, or via a trigger fired by an INSERT) inside a
sandboxed test's transaction is therefore **never delivered**, because the wrapping
transaction is never committed — this is not a flaky-test problem, it is a structural
guarantee that such a test can never observe delivery, regardless of retries or timing
adjustments.

**Decision: `Ecto.Adapters.SQL.Sandbox`'s shared mode, in a dedicated, explicitly
non-`async` test module — not the checked-out-non-sandboxed-connection technique.**
Both candidates the handoff named were investigated; the reasoning for choosing shared
mode over the other technique, concretely:

- **Shared mode (`Sandbox.mode(Letflow.Repo, {:shared, self()})`)** allows every process
  involved in the test — the test process itself, plus any process spawned during the
  test (critically, including a `Letflow.Notify.Listener` GenServer started for the
  test, and the connection Postgres uses to run the `NOTIFY`-triggering write) — to
  share ONE real, checked-out database connection whose transaction genuinely commits
  when the test explicitly commits it (shared mode does not implicitly wrap the test in
  an outer rolled-back transaction the way `:manual`/`async: true` mode does; it is
  documented specifically for exercising cross-process behavior against real committed
  state). This directly matches the property under test: "does a real COMMIT cause a
  real NOTIFY to be delivered to a real listening connection" — shared mode is the one
  sandbox mode where a COMMIT is a real COMMIT.
- **The checked-out-non-sandboxed-connection technique** (illustrated, not by ISS-0031
  per the correction above, but by HANDOFF_PROTOCOL.md's own worked-example template)
  solves a different problem: observing state ALREADY COMMITTED by a fully separate,
  entirely un-sandboxed connection/process (e.g. `information_schema` reflecting a
  schema-provisioning DDL run outside the test's own transaction). It is the right tool
  when the write and the read are two independent, already-committed operations with no
  timing relationship the test needs to synchronize on. It is the WRONG tool here,
  because the property under test is not "can a separate connection see committed
  state" (trivially yes, uninteresting) but "does the LISTEN/NOTIFY *delivery
  mechanism itself* work end-to-end, synchronized to a specific COMMIT the test
  controls" — that requires the LISTEN connection and the NOTIFY-issuing write to be
  coordinated by the SAME test, which shared mode's single-shared-connection model
  supports directly and a fire-and-forget separate raw connection does not (the test
  would still need its own synchronization scaffolding on top of a raw connection, at
  which point it has reinvented what shared mode already provides).

**Concrete, buildable test strategy:**

1. A dedicated test module (e.g. `test/letflow/notify/listener_test.exs`), **not**
   `async: true` (shared mode is inherently serialized across the whole test run — every
   test using it must run on the single shared connection, so `async: true` would race
   tests against each other for that connection; this is the standard, documented
   tradeoff of shared mode and is why it is reserved for a small, dedicated module
   rather than applied suite-wide).
2. `setup` calls `Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)` then
   `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, {:shared, self()})` — this is the
   documented pattern for shared mode (checkout first to get a connection to share,
   then declare shared mode so other processes started during the test, including a
   GenServer under test, use that same connection rather than each getting isolated
   `:manual`-mode connections that can never see each other's uncommitted work).
3. Start the `Letflow.Notify.Listener` GenServer (or a directly-instantiated
   `Postgrex.Notifications` connection, for a lower-level unit test of just the
   LISTEN/NOTIFY mechanism before the wrapper exists) inside the test, `LISTEN` on a
   real or test-specific channel name.
4. From the SAME shared connection (or another connection also placed in shared mode
   via the same `{:shared, self()}` call — Postgrex's shared-mode support extends to
   any connection checked out under that mode, not only `Letflow.Repo`'s Ecto queries),
   perform the write that is expected to trigger (directly, or via trigger) a `NOTIFY`,
   and **explicitly commit it** rather than relying on the test's own teardown rollback
   (shared mode's checkout does not auto-rollback the way `:manual` mode's per-test
   checkout does, so an explicit `Repo.transaction(fn -> ... end)` that returns
   normally is sufficient — no special "force a commit" step beyond an ordinary
   Ecto transaction that isn't manually rolled back).
5. Assert delivery with `assert_receive {:notification, _pid, _ref, "channel_name",
   payload}, 1_000` (or the wrapper's own translated message shape, once it exists) —
   a bounded-timeout `assert_receive`, not a `Process.sleep/1` + `assert_received`,
   since NOTIFY delivery over a live connection is asynchronous relative to the
   COMMIT that triggered it.
6. **Teardown discipline, since shared mode does not auto-rollback:** the test itself
   is responsible for leaving the database in a clean state (delete/rollback its own
   inserted rows explicitly at test end, or scope the test to a disposable
   tenant/fixture schema already used for cross-process fixtures elsewhere in the
   suite) — flagged explicitly here because this is the one genuine cost of choosing
   shared mode over `:manual` mode, and TEST-DESIGNER must account for it rather than
   discover it as a suite-pollution bug later.

This is buildable today against the existing `Postgrex` dependency (already a transitive
dependency of `Ecto.Adapters.Postgres`, no new dependency required for
`Postgrex.Notifications` specifically) and the existing `Ecto.Adapters.SQL.Sandbox`
shared-mode support — no research spike is needed before TEST-DESIGNER can act on it.

---

## Question 6 — Retrofit vs. not, for the two already-shipped pollers

**Decision: NOT NOW. Recommend building the `Letflow.Notify.Listener` infrastructure
(Questions 1-5) as a standalone, dormant capability first, and defer wiring either
poller to consume it to a SEPARATE, later requirement — argued against the round-trip
evidence, not chosen by default, per ISS-0430's own instruction that "not worth it, keep
polling" must be an argued outcome.**

### The round-trip case FOR retrofitting (steelmanned first)

Both pollers currently pay a full Postgres round trip **per tenant schema, per tick**,
whether or not anything changed — this is the actual mechanism, not merely the raw
millisecond figure: `Letflow.Scheduler.Poller` runs its `FOR UPDATE SKIP LOCKED`
claim query once per tenant schema every 5000ms; `ServiceTaskDispatcher.Poller` runs
its two-step (unlocked-select, then lock) query, i.e. **two** round trips per tenant
per tick, also every 5000ms. For T idle tenants (no due timer/dispatch at that
moment — the common case for any tenant not currently mid-workflow), that is `T ×
(1 + 2) round trips every 5s` = `T × 3 × 12` = `36T` round trips per minute that find
nothing, purely to discover "nothing changed." A NOTIFY-driven wake pays zero when
idle — this is the actual lever, not the raw per-query latency.

### AC7 — grounding the performance claim correctly

The dev-host figure (1186-1436us per round trip, ~1.3ms) from ISS-0430's own filing is
**explicitly NOT the basis for this decision** — it is ~92% Docker Desktop
host-container network overhead specific to this one dev machine, confirmed by the
issue's own profiling (a same query run *inside* the Postgres container costs 0.110ms).
**On a co-located production deployment (application and Postgres on the same host or
same low-latency network segment, the realistic target topology), the eliminated cost
per idle round trip is closer to ~0.11ms, not ~1.3ms — an order of magnitude smaller
than the dev-host figure suggests.** At `36T` eliminated round trips/minute and ~0.11ms
each, the aggregate elimination is `36T × 0.00011s` = `0.00396T` seconds of Postgres-side
work per minute — for even a substantial tenant count (say T=500), that is ~2
seconds/minute of eliminated round-trip time, which is real but modest relative to a
5000ms polling interval that already bounds worst-case latency acceptably for both
pollers' current use cases (scheduled timers and service-task dispatch, neither
documented anywhere as needing sub-5-second reaction time today).

### Why NOT NOW, argued

1. **The benefit is round-trip COUNT reduction, not correctness or latency-SLA
   necessity.** Nothing in either poller's own moduledoc, REQ-186, or REQ-214 states a
   latency requirement tighter than "wakes within one poll interval" — both already meet
   that today. NOTIFY would improve *typical-case* latency (near-instant instead of
   up-to-5s) and reduce idle Postgres load, but does not fix a documented deficiency;
   it is an efficiency improvement, not a correctness or SLA fix.
2. **Retrofitting adds real complexity to two already-shipped, already-hardened
   subsystems** whose current supervision/restart-intensity design (ISS-0421, ISS-0429,
   ISS-0451, REQ-219) was purpose-built and iterated on for the pure-polling model.
   Wiring either poller to also react to a NOTIFY wake-up means: (a) the poller's own
   `init/1`/tick-scheduling logic gains a second event source (an async message from
   `Letflow.Notify.Listener`) alongside its existing `Process.send_after/3` timer,
   which changes its state machine and its own crash-loop risk profile (a
   badly-behaved NOTIFY message causing an unexpected tick could reintroduce exactly
   the kind of "zero-delay first tick raises repeatedly" hazard `Pollers`' own
   moduledoc already documents having fixed once for the timer-only case); (b) the
   `Pollers`/`Infrastructure` cross-supervisor coupling grows (a `Pollers`-owned
   GenServer needing to receive messages from an `Infrastructure`-owned GenServer),
   which is a new dependency edge this design's own Question 1 placement reasoning
   was careful to avoid creating unnecessarily.
3. **Nothing about adopting the infrastructure now forecloses retrofitting later.**
   Because Question 1's decision places `Letflow.Notify.Listener` as new, independent
   infrastructure with no required consumer, building it does not commit to retrofitting
   anything — it becomes available capacity a later, separately-scoped requirement can
   consume once (if) the round-trip savings are judged worth the added complexity
   against real production tenant-count/load numbers, which do not exist yet (Letflow
   is pre-S8, no production deployment). Deciding the retrofit now, before real load
   data exists, would be optimizing against a hypothetical rather than a measured need.
4. **This is consistent with ISS-0430's own instruction** that a "not worth it, keep
   polling" verdict is legitimate "IF argued against the round-trip evidence, not by
   default" — the argument above is made against the actual round-trip mechanics (36T
   eliminated round trips/minute, ~0.11ms each in a co-located deployment), not against
   the raw dev-host millisecond figure, and concludes the SAVINGS ARE REAL BUT MODEST
   relative to the RETROFIT COST for two already-hardened subsystems with no documented
   latency deficiency today.

**What IS recommended now:** build `Letflow.Notify.Listener` (Questions 1-5) as
standalone infrastructure, unconsumed by either poller, so that (a) the multi-tenancy
mechanism (Question 2) and the test story (Question 5) are established and reviewable
independent of any specific consumer, and (b) a future retrofit requirement (or the
"real-time push path to web/" ISS-0430 explicitly flags as future, out-of-scope work)
can consume it without re-deciding Questions 1-5 from scratch. This keeps polling as the
sole active mechanism for both pollers today, per Question 4's decision.

---

## Cross-module dependencies

- `Letflow.Notify.Listener` (new) depends on: `Postgrex.Notifications` (transitive dep
  of `postgrex`, already in `mix.lock` via `ecto_sql`), `Letflow.Repo`'s connection
  config (host/port/credentials — reused, not duplicated, for the raw connection).
- No dependency FROM `Letflow.Scheduler.Poller` or
  `Letflow.Engine.ServiceTaskDispatcher.Poller` TO `Letflow.Notify.Listener` under this
  decision (Question 6: not retrofitted now) — this is a deliberate absence, not an
  oversight, and should not be added incidentally by a future unrelated change.
- `Letflow.Supervisor.Infrastructure`'s children list gains one entry (Question 1).

## Invariants this design establishes

- **I1.** No `NOTIFY` payload, under any current or future channel this design's
  mechanism governs, ever contains tenant-identifying or row-content data — payload is
  always a bare opaque routing id. (Enforces Question 2/3's decision structurally.)
- **I2.** Every consumer of a `Letflow.Notify.Listener`-delivered id treats it as
  untrusted and re-derives its own tenant scope independently before any fetch — never
  a scope derived from the NOTIFY message itself. (Enforces Question 2's isolation
  argument.)
- **I3.** Polling continues at its current interval for both existing pollers
  regardless of NOTIFY adoption status, until a separate, explicitly-argued future
  decision changes it. (Enforces Question 4.)
- **I4.** `Letflow.Notify.Listener`'s connection is single, application-wide, and
  placed in `Infrastructure` — no future change may add a second general-purpose LISTEN
  connection or move it into `Pollers` without re-deriving Question 1's reasoning.

## Open questions (not silently resolved)

1. **Exact trigger-vs-application-emitted `NOTIFY` mechanism** for a future consumer —
   whether a Postgres trigger on `timers`/`service_task_dispatches` fires `NOTIFY`
   automatically on insert, or whether the inserting Elixir code calls `Repo.query!("NOTIFY ...")`
   explicitly inside the same transaction. Both satisfy this design's payload/isolation
   rules identically; the choice affects only where the `NOTIFY` call lives, and is
   deferred to whichever future requirement actually retrofits a consumer.
2. **`TEST_NONPOOL_CONNECTION_RESERVE` update.** Question 1 flags that
   `Letflow.Notify.Listener`'s connection must be added to decision 0009's non-pooled
   connection accounting once it exists in `config/test.exs` — not resolved here, since
   the connection itself is not yet implemented; whoever implements Question 1 must
   also touch that config value and re-verify decision 0009's budget arithmetic still
   holds.
3. **Exact channel name strings** (`"timer_ready"` / `"dispatch_ready"` used
   illustratively above) are not final — a future implementer should confirm no
   collision with any existing use of those channel names (none found; ISS-0430's own
   diagnosis grep found zero LISTEN/NOTIFY usage anywhere in `lib/`) and may choose
   different names, provided the payload-opacity rule (I1) is preserved regardless of
   name.
4. **Reconnect/backoff behavior of the `Letflow.Notify.Listener` wrapper** (how
   aggressively it retries after a Postgres connection drop, and whether it logs/alerts
   on repeated failure) is left to implementation-time judgment — this design fixes its
   supervision placement and restart-intensity inheritance (Question 1) but not its
   internal reconnect policy, since no requirement here depends on a specific backoff
   shape.
