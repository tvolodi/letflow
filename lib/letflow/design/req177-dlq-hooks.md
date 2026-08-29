# REQ-177 — DLQ landing hooks (SERVICE_TASK exhaustion + instance ERROR)

Design for wiring the two DLQ landing call sites REQ-176 deliberately left
unwired. Greenfield in the sense that neither call site exists yet — this
requirement adds them. Binding contracts: the acceptance criteria in
`docs/requirements.yaml#REQ-177`, `lib/letflow/dlq.ex`'s `enqueue/2` (the
landing target), `lib/letflow/engine/execution_error.ex` (the ERROR-path
Multi chain to extend), and `lib/letflow/engine/service_task.ex` (the pure
module whose `:give_up` outcome must be observed from outside it).

**Scope boundary, restated from the requirement:** landing only, never
re-execution. Neither hook calls anything that would re-dispatch a
SERVICE_TASK HTTP request or resume an ERRORed instance — that is explicitly
out of scope (REQ-176 §4's own boundary, restated below in §6). This design
touches exactly two source files plus their tests:
`lib/letflow/engine.ex` and `lib/letflow/engine/execution_error.ex`. It does
**not** touch `lib/letflow/engine/service_task.ex` — that module stays pure
(no `Repo`, no `Letflow.Dlq` call, no `Letflow.Engine.set_instance_error/2`
call of its own), matching its own moduledoc's explicit purity list. It does
not touch `lib/letflow/dlq.ex` — `enqueue/2`'s signature and behavior are
consumed as-is, unchanged.

## 0. Verified precedents (read against the real files, not assumed)

- `Letflow.Engine.ServiceTask.decide_failure/3` (`lib/letflow/engine/service_task.ex:388-399`)
  is pure and returns only `:retry | :give_up` — no cause tag. The
  cause split this requirement needs (exhaustion vs. immediate
  non-retriable) is **not** carried in that return value, confirmed by
  reading the function body: `cond do not is_retriable_failure(kind) ->
  :give_up; attempt_index < retry_limit -> :retry; true -> :give_up end`.
  A caller that needs to distinguish the two causes must re-derive them by
  calling `is_retriable_failure/1` itself, exactly as
  `build_service_task_give_up_error_attrs/1` (`service_task.ex:459-485`)
  already does internally for its own `cause_text` string.
- `ServiceTask`'s moduledoc (`service_task.ex:20-33`) states every
  `:give_up` outcome is "handed to `Letflow.Engine.set_instance_error/2`
  ... via `build_service_task_give_up_error_attrs/1`" and that this module
  itself "does NOT land in a dead-letter queue here." Confirmed — grepping
  the whole `lib/letflow/` tree for `decide_failure` and `ServiceTask.`
  outside `service_task.ex` itself finds exactly one hit
  (`lib/letflow/definitions/graph.ex:697`, a comment, no call). **No
  dispatch orchestrator that calls `decide_failure/3` exists anywhere in
  this codebase yet.** This design therefore does not assume one and does
  not wait for one — see §2's "no orchestrator yet" resolution.
- `Letflow.Engine.ExecutionError.append_multi/3` (`execution_error.ex:140-158`)
  builds a 3-4-step `Ecto.Multi` (`maybe_lock_projection` ->
  `:execution_error_eligibility` -> `:execution_error_event` ->
  `:execution_error_projection_update`) and opens no transaction of its own
  — its moduledoc (`execution_error.ex:17-21`) states "zero `Repo` calls of
  its own: every step it appends runs inside the *caller's* already-open
  `Ecto.Multi`/transaction." Confirmed by reading the full function body —
  every branch is `Multi.run`/`Multi.new` composition, no `Repo.transaction`
  call anywhere in the module.
- `Letflow.Engine.set_instance_error/2` (`lib/letflow/engine.ex:2733-2760`)
  is the standalone wrapper: `Multi.new() |> ExecutionError.append_multi(...)
  |> Repo.transaction()`. Confirmed this is the **only** place in the
  codebase today that opens the transaction `ExecutionError.append_multi/3`
  runs inside for a caller with no other open `Multi` (the module comment
  immediately above it, `engine.ex:2680-2684`, names `complete_task/3`'s
  own REQ-049/050 call sites as the only other current callers of
  `append_multi/3`, and those already have their own open `Multi`).
- `Letflow.Dlq.enqueue/2` (`lib/letflow/dlq.ex:81-113`) takes
  `(attrs, opts)`, always sets `status: :pending`/`retry_count: 0`/
  `retry_history: []`/`created_at` internally, derives `tenant_id` from
  `opts[:prefix]`, and inserts via `Entry.insert_changeset/2`. Its only
  required attrs key is `:entry_type`; every other key in `enqueue_attrs()`
  (`instance_id`, `reason`, `full_reason`, `error_detail`, `error_chain`,
  `source_payload`, `context_json`, `retry_limit`, `first_failed_at`,
  `last_failed_at`) is optional and inserts verbatim when supplied.
- `req176-dlq-core.md` §4 and §5 (OQ-2, OQ-3) explicitly defer two
  questions to this requirement: (a) whether `last_failed_at` should be set
  automatically anywhere, and (b) the exact "exhaustion-driven landing"
  trigger condition. §5 resolves both — see §5 below.
- `Letflow.EventStore.append/2` (`lib/letflow/event_store.ex:214-249`)
  returns `{:ok, %{event: Event.t(), is_duplicate: boolean(),
  sequence_number: pos_integer(), global_seq: pos_integer()}}`. `Event.t()`
  declares `field(:payload, :map)` (`lib/letflow/event_store/event.ex:84`)
  — not a string. `append/2`'s own `insert_event/3`
  (`lib/letflow/event_store.ex:607-641`) inserts the row with
  `payload: decoded_payload` (the already-`Jason.decode!/1`-ed map, decoded
  earlier inside `append/2` itself), and `interpret_transaction_result/1`
  (`lib/letflow/event_store.ex:697-707`) hands that same struct straight
  back as `event`. So `event.payload` in the `{:ok, result}` returned to
  the caller is already a string-keyed map with a `"reason"` key — no
  further JSON decoding step exists or is needed. This is the mechanism
  §4 below uses to read the persisted reason back rather than re-using the
  caller's original string.

## 1. The two hook call sites, at a glance

| # | File | New element | Fires when | DLQ row produced? |
|---|---|---|---|---|
| A | `lib/letflow/engine.ex` | new function `Letflow.Engine.land_service_task_exhaustion/2` | a `ServiceTask.decide_failure/3` `:give_up` outcome whose cause is genuine retry exhaustion (§3) | yes, directly, via `Dlq.enqueue/2`, **before** delegating to `set_instance_error/2` |
| B | `lib/letflow/engine/execution_error.ex` | new `Ecto.Multi` step `:execution_error_dlq_landing` appended by `append_multi/3` | any call to `append_multi/3` (hence any call to `set_instance_error/2`, hence any REQ-049/050/056/057/062-style instance-ERROR transition) **unless the caller opts out** | yes, in the same transaction as the status flip and event append — **unless** `opts[:dlq_landed_externally]` is `true` |

Hook A and Hook B interact through one new opt (`opts[:dlq_landed_externally]`,
threaded through `set_instance_error/2`) precisely so a SERVICE_TASK
exhaustion outcome produces **exactly one** DLQ row (from Hook A), not two —
see §4 for the full interaction contract and why this is the only place a
double-landing risk exists.

## 2. Hook A — `Letflow.Engine.land_service_task_exhaustion/2` (new)

### 2.1 Why this function, and why here, not an existing orchestrator

No SERVICE_TASK dispatch orchestrator exists in this codebase (§0). The
requirement text is explicit that when no such orchestrator exists, this
requirement must add the call itself rather than assume one. This design
adds a single new public function to `lib/letflow/engine.ex`, alongside
`set_instance_error/2` (same file, same "standalone entry point for a
caller with no open `Multi` of its own" shape) — **not** to
`service_task.ex` (which must stay pure, §0) and **not** a new module,
since this is a thin composition of two already-existing capabilities
(`ServiceTask`'s pure classification + `Dlq.enqueue/2` + `set_instance_error/2`)
with no state of its own. A future SERVICE_TASK dispatch orchestrator
(the "S4 routes / future requirement" `service_task.ex`'s own moduledoc
names, §0) calls this function instead of calling `set_instance_error/2`
directly whenever `decide_failure/3` returns `:give_up` for a SERVICE_TASK
node. Until that orchestrator exists, this function is dead code reachable
only from its own tests — the same "hook exists, caller doesn't yet" shape
`set_instance_error/2` itself was built in before REQ-056/057/062 existed
to call it.

### 2.2 Input shape

A new type, `service_task_dlq_landing_context()`, extending
`ServiceTask.service_task_give_up_context()` (`service_task.ex:154-163`)
with the two additional fields needed for a DLQ row that
`service_task_give_up_context()` does not itself carry (neither an
"attempted request" snapshot nor a `retry_limit`-as-DLQ-column value is
part of that context's own purpose, which is building `error_args` for
`set_instance_error/2`, not a DLQ row):

```
@type service_task_dlq_landing_context :: %{
  required(:instance_id) => Ecto.UUID.t(),
  required(:node_id) => String.t(),
  required(:actor_id) => Ecto.UUID.t() | nil,
  required(:idempotency_key) => String.t(),
  required(:variables) => map(),
  required(:last_failure_kind) => Letflow.Engine.ServiceTask.failure_kind(),
  required(:attempt_index) => Letflow.Engine.ServiceTask.attempt_index(),
  required(:retry_limit) => non_neg_integer(),
  required(:attempted_request) => %{
    required(:method) => String.t(),
    required(:url) => String.t(),
    optional(:body) => String.t() | nil,
    optional(:headers) => %{optional(String.t()) => String.t()}
  }
}
```

`attempted_request` is the "attempted request" the requirement text names
for `source_payload` — the rendered method/URL/body/headers the future
orchestrator actually sent. This design does not invent where the
orchestrator captures these fields from (it does not exist yet); it only
fixes the shape this function requires them in, matching
`Letflow.Engine.ServiceTask.Config`'s own field names (`method`,
`url_template` rendered form, `body_template` rendered form, `headers`)
for consistency (`service_task.ex:64-93`).

### 2.3 Spec

```
@spec land_service_task_exhaustion(
        context :: service_task_dlq_landing_context(),
        opts :: Letflow.Engine.set_error_opts()
      ) ::
        {:ok, Letflow.Engine.set_error_result()}
        | {:error, :not_exhaustion}
        | Letflow.Engine.set_error_error()
        | {:error, {:dlq_enqueue_failed, Ecto.Changeset.t()}}
```

### 2.4 Behavior, in order

1. Recompute the exhaustion/non-exhaustion split via
   `ServiceTask.is_retriable_failure(context.last_failure_kind)` and
   `context.attempt_index`/`context.retry_limit` — the exact condition is
   fixed in §3. If the outcome is **not** genuine exhaustion (i.e. this
   `:give_up` came from an immediately non-retriable failure kind), this
   function returns `{:error, :not_exhaustion}` and calls neither
   `Dlq.enqueue/2` nor `set_instance_error/2` — the caller (the future
   orchestrator) is expected to call `set_instance_error/2` directly for
   that case instead, exactly as `ServiceTask`'s own moduledoc already
   describes today, so that Hook B lands it generically (§4).
2. On genuine exhaustion, calls `Letflow.Dlq.enqueue/2` with:
   - `entry_type`: the literal string `"event"` (AC1).
   - `instance_id`: `context.instance_id` (AC1).
   - `full_reason`: the same failure-kind-naming string
     `build_service_task_give_up_error_attrs/1` would build for `reason`
     (`"service task failed (#{last_failure_kind}): retries exhausted
     after #{retry_limit} attempts"`) — this function builds this string
     itself (not by calling `build_service_task_give_up_error_attrs/1`,
     which returns `Letflow.Engine.standalone_error_attrs()` shaped for
     `set_instance_error/2`, a different consumer); AC1 is satisfied
     because the classified failure kind (`context.last_failure_kind`)
     is named directly in this string.
   - `source_payload`: `context.attempted_request` (the requirement
     text's "carrying the attempted request").
   - `retry_limit`: `context.retry_limit`.
   - `first_failed_at` and `last_failed_at`: both set to the current UTC
     wall-clock time read inside this step (§5.1 resolves why both, and
     why equal).
   - `opts`: passed through unchanged (same `[prefix: ...]` shape every
     `Letflow.Dlq` function already takes).

   A `Dlq.enqueue/2` failure (`{:error, changeset}`) short-circuits this
   function with `{:error, {:dlq_enqueue_failed, changeset}}` — the
   ERROR-transition step (3) below does not run, so the instance is not
   left partially transitioned to `ERROR` with no DLQ row (there is no
   ordering ambiguity to resolve here, since step 3 has not started yet).
3. On a successful DLQ enqueue, calls
   `Letflow.Engine.set_instance_error/2` with the exact
   `Letflow.Engine.standalone_error_attrs()` shape
   `build_service_task_give_up_error_attrs/1` already builds from an
   equivalent context (this function constructs the same map inline —
   `build_service_task_give_up_error_attrs/1`'s own input type,
   `service_task_give_up_context()`, is a strict subset of
   `service_task_dlq_landing_context()`'s fields, so every field it needs
   is already present), and with `opts` extended by
   `dlq_landed_externally: true` (§4) so Hook B does not also land a row
   for this same transition.
4. Returns `set_instance_error/2`'s own result verbatim.

### 2.5 Moduledoc addition (this hook's deferred-follow-up statement)

The moduledoc comment immediately above `land_service_task_exhaustion/2`
(in `engine.ex`, alongside the existing `set_instance_error/2` doc block)
must state, per the requirement's own acceptance criterion: this function
lands a DLQ entry only — it does not itself, and `Letflow.Dlq.retry/2`
called against the entry it creates does not either, re-invoke the
original SERVICE_TASK dispatch. Naming both of the two missing pieces
explicitly: (a) a wired SERVICE_TASK transport (the injectable
`transport_fun()` `service_task.ex`'s own moduledoc already says "no
concrete implementation ... exists in this codebase yet") that some future
requirement would need to call from a `retry/2`-driven re-dispatch path,
and (b) the dispatch orchestrator itself (§2.1) that would need to exist
before anything calls `retry/2` in response to an operator action at all.

## 3. The exhaustion trigger condition (resolves REQ-176 §5 OQ, part 2)

**Exhaustion**, for the purposes of Hook A firing, is exactly:

`ServiceTask.is_retriable_failure(last_failure_kind) == true` **and**
`attempt_index >= retry_limit`

This mirrors `decide_failure/3`'s own second `cond` branch
(`attempt_index < retry_limit -> :retry; true -> :give_up`,
`service_task.ex:396-397`) restricted to the retriable-kind path — it is
**not** simply "decide_failure/3 returned `:give_up`", because that also
covers the immediately-non-retriable case (`is_retriable_failure(kind) ==
false`, which gives up on attempt 0 regardless of `retry_limit`,
`service_task.ex:395`). The acceptance criteria's own phrase "attempt_index
== retry_limit" is read as "the boundary at which `decide_failure/3` would
stop retrying a retriable kind", i.e. `attempt_index >= retry_limit` for a
retriable kind — not a literal `==` check, since `decide_failure/3` itself
never lets `attempt_index` exceed `retry_limit` by more than the single
call that observes the boundary (a caller does not re-invoke
`decide_failure/3` after it has already returned `:give_up`), so `>=` and
`==` are equivalent in every reachable call sequence; `>=` is specified
here because it is the literal predicate `decide_failure/3` itself already
uses and is defensive against a hypothetical caller bug that skips a
retry step.

Non-exhaustion (`is_retriable_failure(last_failure_kind) == false`) is
explicitly **not** a Hook A trigger — it lands via Hook B only, when the
future orchestrator calls `set_instance_error/2` directly for that case
(§2.4 step 1).

## 4. Hook B — new Multi step in `ExecutionError.append_multi/3`

### 4.1 New opts key

`append_multi/3`'s `opts` list (currently `[prefix: String.t(), locked_projection: InstanceProjection.t() | nil]`,
`execution_error.ex:135-139`) gains one more optional key:

```
opts :: [
  prefix: String.t(),
  locked_projection: InstanceProjection.t() | nil,
  dlq_landed_externally: boolean()
]
```

Defaulting to `false` when absent (`Keyword.get(opts, :dlq_landed_externally, false)`,
matching the existing `Keyword.get(opts, :prefix)`/`Keyword.get(opts,
:locked_projection)` idiom already in this function). `set_instance_error/2`
(`engine.ex:2733-2760`) gains the matching pass-through: its own
`set_error_opts()` type gains an optional `dlq_landed_externally: boolean()`
key, forwarded verbatim into `ExecutionError.append_multi(error_args, prefix:
prefix, dlq_landed_externally: Keyword.get(opts, :dlq_landed_externally,
false))`. This is the only change to `set_instance_error/2`'s own body
besides the doc addition in §4.4 — it does not otherwise change behavior
for any existing caller, since the new key defaults to `false` (i.e. "land
in DLQ", today's absent-but-now-explicit behavior) everywhere it is
omitted.

### 4.2 The new Multi step

`append_multi/3`'s chain (`execution_error.ex:145-158`) gains one
additional step, `:execution_error_dlq_landing`, appended **after**
`:execution_error_event` and **before** `:execution_error_projection_update`
(ordering rationale: the event must already be persisted for this step to
read its reason back per §4.3; placing it before the projection update
means a DLQ-enqueue failure also prevents the projection from ever
flipping to `:error` — the same "fail fast before the final visible state
change" ordering `append_multi/3` already uses for its own three existing
steps). The step is skipped entirely (not appended, matching
`maybe_lock_projection/4`'s existing conditional-append idiom for
`locked_projection`) when `opts[:dlq_landed_externally]` is `true`.

Because it is one more step inside the same `Ecto.Multi` the caller's own
`Repo.transaction/1` commits, a failure at this step rolls back the event
insert and (since it runs before `:execution_error_projection_update`)
never lets the projection update run at all — this is exactly AC3's
"forcing the DLQ insert to fail leaves the instance status, the
EXECUTION_ERROR event, and the DLQ table all unchanged" requirement,
delivered by `Ecto.Multi`'s own native rollback-on-any-step-failure
behavior, not by any new bespoke rollback logic this design has to invent.

### 4.3 What the new step does

Reads `changes.execution_error_event.event.payload["reason"]` directly.
Per §0's precedent, `changes.execution_error_event.event.payload` is
already the decoded, string-keyed map `EventStore.append/2` persisted (see
`lib/letflow/event_store/event.ex:84` and
`lib/letflow/event_store.ex:607-641,697-707`) — no `Jason.decode!/1` call
is needed or present anywhere in this path (calling it on an already-`map`
value would crash, since `Jason.decode/2` requires a binary). This is the
"read back from the just-persisted EXECUTION_ERROR event's own reason
field" the requirement text mandates, rather than forwarding
`error_args.reason` (the caller's original string) a second time.

Calls `Letflow.Dlq.enqueue/2` with:
- `entry_type`: the literal string `"event"` (AC2).
- `instance_id`: `error_args.instance_id` (AC2).
- `full_reason`: the reason string read back per above (AC2 — "equal to
  the persisted EXECUTION_ERROR event's own reason field").
- `reason`: `error_args.reason` also passed to the shorter `reason` column
  (not the AC-tested field, but present since it is `enqueue_attrs()`'s
  natural short-form counterpart and costs nothing extra to populate).
- `error_detail`: `Map.get(error_args, :details, %{})` — the same details
  map `update_projection_to_error/4` already folds into
  `instance_projections.error_detail` (`execution_error.ex:226-233`), so
  the DLQ row's own detail mirrors the projection's.
- `first_failed_at` / `last_failed_at`: both the current UTC wall-clock
  time read inside this step (§5.1).
- `opts`: `[prefix: prefix]` (the same `prefix` already threaded through
  every other step in this function).

Runs inside `Multi.run(:execution_error_dlq_landing, fn repo, changes ->
...)` per the file's own existing idiom for every other step (all four
existing steps in this module are `Multi.run/3` closures, not raw
`Multi.insert/3` calls, because each needs either `changes` or a value
computed at run time) — this design specifies the step's *inputs, outputs,
and placement*, not its literal closure body, per this project's
design/implementation split.

### 4.4 Moduledoc addition (this hook's deferred-follow-up statement)

`ExecutionError`'s moduledoc "SCOPE BOUNDARY — OBS-05 dead-letter queue
(S6), not built here" section (`execution_error.ex:23-36`) is now
partially stale — a DLQ row **is** built here, as of this requirement. The
updated moduledoc must state: `append_multi/3` now lands one `dlq_entries`
row per ERROR transition (unless the caller already landed one
externally, `opts[:dlq_landed_externally]`), but this is **landing only** —
calling `Letflow.Dlq.retry/2` against that row transitions the row's own
`status` to `:retrying` and appends to its `retry_history`; it does not
re-invoke whatever failed, and it does not move the instance itself out of
`ERROR`. The two things still missing, named explicitly per the
requirement's acceptance criterion: (a) a wired SERVICE_TASK transport for
the subset of `ERROR` transitions that originated from a SERVICE_TASK
give-up (Hook A's own case, when `dlq_landed_externally` was **not** set —
i.e. the non-exhaustion immediate-failure case, §2.4 step 1, which lands
via this hook, not Hook A), and (b) an operator-driven ERROR-recovery path
(the still-unbuilt route/controller layer, REQ-178, that would let a human
call `retry/2`/`discard/2` and separately decide whether/how to actually
un-stick the instance from `ERROR` — `instance_projections.status ==
:error` remains the durable record until that exists, exactly as the
pre-existing "ERROR is not terminal" section of this moduledoc already
states).

## 5. REQ-176's two deferred open questions — resolved

### 5.1 Should `last_failed_at` be set on landing?

**Yes — set at landing (both hooks), not by `retry/2`.** Both Hook A
(§2.4) and Hook B (§4.3) pass `first_failed_at` and `last_failed_at` as the
*same* current-UTC-timestamp value read inside the landing step. Rationale:
a landing call is, by construction, the entry's genesis — there is no
earlier failure this specific `dlq_entries` row already knows about, so
"first" and "last" failure are the same moment for a freshly-created row.
This does not touch `Letflow.Dlq.retry/2`'s own behavior at all —
`req176-dlq-core.md` §5 OQ-3 asked specifically whether *`retry/2`* should
advance `last_failed_at` automatically, and this design leaves that
question exactly as open as REQ-176 left it: `retry/2` still does not
touch `last_failed_at` (confirmed unchanged by reading `dlq.ex:231-248`
again against this design — nothing in either hook modifies `Letflow.Dlq`
itself). What this design *does* resolve is the narrower, REQ-177-scoped
half of that question — "should the two landing calls this requirement
itself adds set `last_failed_at`" — answered yes, with the value fixed
above. A later requirement wiring the SERVICE_TASK transport (§2.5/§4.4's
named follow-up) is the natural place to decide whether a *second* landing
attempt against an *existing* entry (as opposed to `retry/2`) should ever
advance `last_failed_at` — no such second-landing call exists in this
requirement's scope (each hook only ever inserts a fresh row via
`enqueue/2`, never updates an existing one).

### 5.2 The exhaustion-driven-landing trigger condition

Resolved in full in §3 above: `is_retriable_failure(last_failure_kind) ==
true and attempt_index >= retry_limit`, evaluated by Hook A itself (since
`decide_failure/3`'s own return value does not carry the distinction), and
explicitly **not** simply "`decide_failure/3` returned `:give_up`" (which
also covers the immediately-non-retriable case, deliberately excluded from
Hook A and left to land via Hook B instead).

## 6. What this design explicitly does not do (restated scope boundary)

Neither hook re-dispatches a SERVICE_TASK HTTP request or resumes an
ERRORed instance — `Letflow.Dlq.retry/2` (unmodified by this design, per
its own moduledoc already restated in REQ-176 §4) continues to manage only
the `dlq_entries` row's own state machine. No callback parameter,
`behaviour`, or protocol is added to `Letflow.Dlq` by this design — the
"injectable-callback territory" `req176-dlq-core.md` §4 names as
"REQ-177's own design ... responsible for introducing whatever hook shape
it needs" turns out, in this design, to need no callback into `Letflow.Dlq`
at all: both hooks are plain callers of the already-shipped `enqueue/2`,
nothing more. `Letflow.Engine.ServiceTask` itself is not modified — it
gains no new function, no new field, no `Repo`/`Dlq` dependency; its own
purity list (`service_task.ex:44-52`) is unchanged by this requirement.

## 7. Files touched (exhaustive)

- `lib/letflow/engine.ex` — new function `land_service_task_exhaustion/2`,
  new type `service_task_dlq_landing_context()`, extended `set_error_opts()`
  type (adds `dlq_landed_externally`), new moduledoc passage (§2.5), pass-
  through of the new opts key into `set_instance_error/2`'s call to
  `ExecutionError.append_multi/3`.
- `lib/letflow/engine/execution_error.ex` — new `:execution_error_dlq_landing`
  Multi step in `append_multi/3`, extended `opts` type (adds
  `dlq_landed_externally`), updated moduledoc (§4.4).
- Their tests (new/extended `*_test.exs` files exercising both hooks,
  written by TEST-DESIGNER against this design).

No other file changes — matches the requirement's own acceptance criterion
("no file outside the two named hook call sites and their tests is
modified").

## 8. Test-design guidance (traceability to acceptance criteria)

| AC | Where it is proven |
|---|---|
| Exhaustion -> exactly one `dlq_entries` row, `entry_type "event"`, `instance_id` set, `full_reason` names the classified kind, read back from the DB | Call `land_service_task_exhaustion/2` with `attempt_index >= retry_limit` and a retriable `last_failure_kind`; assert via `Letflow.Dlq.get/2` (or a direct `Repo.get`) — not via the function's own return value. |
| ERROR path -> exactly one row, `full_reason` equal to the persisted EXECUTION_ERROR event's own reason | Call `set_instance_error/2` (without `dlq_landed_externally`) or `ExecutionError.append_multi/3` directly inside a test-owned `Multi`; read the `EXECUTION_ERROR` event back from `Letflow.EventStore` and the `dlq_entries` row back independently; assert the two `reason`/`full_reason` strings are equal by re-reading both, not by construction. |
| Same-transaction guarantee | Force the `:execution_error_dlq_landing` step to fail (e.g. an `enqueue_attrs` shape that fails `Entry.insert_changeset/2`, or a `Sandbox`-level fault injection) and assert `instance_projections.status`, the absence of any new `EXECUTION_ERROR` event, and the absence of any new `dlq_entries` row, all three read back independently after the failed call returns. |
| `retry/2` is a landing-only no-op beyond the DLQ row | Call `Letflow.Dlq.retry/2` against an entry either hook created; assert the entry's own `status` becomes `"retrying"` (one effect) while separately asserting the instance's `instance_projections.status` is still `:error` (first non-effect) and that no second SERVICE_TASK HTTP attempt or transport call occurred (second non-effect — trivially true today since no transport exists yet to have been called, but assert on whatever test double/mock the test harness uses, e.g. a call-count of zero on an injected `transport_fun`, to make the non-effect an explicit, checked assertion rather than an absence of code that happens to prove nothing). |
| Both hook sites' moduledocs name the retry/2 no-op and the two named missing pieces | Documentation-only assertion (code review / doc grep in the test suite is not required by any AC's own wording, but TEST-DESIGNER may add a light `ExDoc`-string-presence check if this project's test conventions already do that elsewhere; otherwise this AC is satisfied by the moduledoc text itself, checked by CODE-DESIGN-VALIDATOR/REVIEWER, not by a runtime test). |
| No file outside the two hook call sites (+ tests) modified | `git diff --stat` against the merge-base, asserted by the implementing agent / REVIEWER, not a `mix test` assertion. |
| `mix test` / `mix compile --warnings-as-errors` both pass | Run by ELIXIR-DEV/TEST-RUNNER at implementation time; not something this design can pre-verify. |

## 9. Open questions (not resolved here — for ELIXIR-DEV/REVIEWER)

1. **Exact field-capture mechanism for `attempted_request`.** Since no
   SERVICE_TASK dispatch orchestrator exists yet, this design fixes the
   *shape* `land_service_task_exhaustion/2` requires (§2.2) but not how a
   future orchestrator will have captured `method`/`url`/`body`/`headers`
   at the point it observed exhaustion (e.g. whether it retains the
   rendered `Config.t()` plus a rendered body string, or a lower-level
   HTTP-client request record). That is the future orchestrator
   requirement's own concern, not this hook's.
2. **Function naming.** `land_service_task_exhaustion/2` is this design's
   proposed name; if REVIEWER or the implementing agent finds a
   established naming convention this design missed (e.g. an
   `set_*_error`-family naming precedent this design's author did not
   locate), the name may change without altering this design's behavior
   contract.
3. **Whether `:execution_error_dlq_landing` should run before or after
   `:execution_error_projection_update` in a future revision.** This
   design places it before (§4.2) for the "fail fast" reason given there;
   if a future requirement's own acceptance criteria require the
   projection update to be visible before the DLQ row exists (no such
   requirement exists today), that ordering would need explicit
   re-justification, not a silent swap.
