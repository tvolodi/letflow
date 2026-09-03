# REQ-217 — Wire admission control into the HTTP entry path

Design for closing ISS-0431/GH#835's PRIMARY surface, atop REQ-216's core
`Letflow.Admission` module. Ports no R-Co source (this mechanism has no R-Co
analogue). No implementation code below — signatures, `@spec`/`@type` shapes,
and prose only.

## 0. Inputs read in full before this design (confirmed, not assumed)

* `lib/letflow/admission.ex` (REQ-216) — `try_acquire(pool_selector(), server) ::
  {:ok, admission_ref()} | {:error, :capacity}`, `release(admission_ref(),
  server) :: :ok` (idempotent — releasing an id not present in the server's
  `refs` map is a documented no-op, always `:ok`, never a raise). `pool_selector
  :: :global | {:tenant, tenant_schema :: String.t()}`. `admission_ref()` is
  `Letflow.Admission.Ref.t()`, opaque, callers must not construct/pattern-match
  it directly.
* `lib/letflow/plugs/api_pipeline.ex` — current chain: `Plug.Parsers`,
  `:assign_trace_id`, `Letflow.Plugs.AuthPipeline`, `Letflow.Plugs.TenantStatus`,
  `:match`, `:dispatch`.
* `lib/letflow/plugs/auth_pipeline.ex:318-319` —
  `attach_auth_context/4` does `assign(conn, :auth_context, %{user_id:
  user_id, tenant_id: tenant_id, roles: roles})`. Confirms `conn.assigns.
  auth_context.tenant_id` is the correct, already-resolved key path this
  design reads from.
* `lib/letflow/tenant_provisioning.ex:166-171` —
  `schema_name_for_tenant(tenant_id) :: {:ok, String.t()} | {:error,
  :invalid_tenant_id}`, a **pure, no-I/O** derivation (`Ecto.UUID.cast/1` +
  string concat). This is the SAME function `AuthPipeline` itself already
  calls (`auth_pipeline.ex:140,206-209`) to get the schema name it uses for
  its own token/JIT-provisioning queries, and the same one
  `Letflow.Scheduler.Poller` conceptually mirrors (Poller instead reads
  `schema_name` directly off its own `tenant_schemas/0` query result — a
  different tenant-schema resolution path — because it never starts from a
  `tenant_id`, it starts from a schema list. `TenantProvisioning.
  schema_name_for_tenant/1` is the tenant-id-to-schema-name direction, the one
  this requirement needs). **This design reuses this function directly — it
  is not re-derived.**
* `lib/letflow/api/response.ex` — `service_unavailable(conn, detail) ::
  Plug.Conn.t()`, delegates to `send_problem/2` →
  `Letflow.Api.Error.service_unavailable/1` (`type`/`title`/`status: 503`/
  `detail`/`trace_id: ""` defaulted, resolved from `conn.assigns[:trace_id]`
  by `send_problem/2` itself). `rate_limited/2`'s doc: "Set `Retry-After` on
  the conn yourself before calling" — `service_unavailable/2` carries the
  identical convention (no `Retry-After` handling inside `Response` at all;
  every caller that needs the header sets it on `conn` first). This design's
  plug follows that exact convention.
* `lib/letflow/plugs/tenant_status.ex` — `@retry_after_seconds "30"`,
  hand-rolled `put_resp_header("retry-after", @retry_after_seconds)` +
  `Jason.encode!/1` + `send_resp/3` (predates `Letflow.Api.Response`'s
  existence for this call site; **this design does NOT copy that hand-rolled
  body-building pattern** — it uses `Response.service_unavailable/2`, per the
  requirement's explicit "do not add a new response helper" instruction).
  30s is TenantStatus's own value for a **migration-in-progress** wait,
  which can genuinely take tens of seconds. Admission rejection is
  structurally different: `Letflow.Admission.try_acquire/2` is a single
  synchronous `GenServer.call/2` against in-memory counters with **no wait
  queue at all** (admission.ex moduledoc: "There is no wait queue... never
  parked") — a slot can free up as soon as any other in-flight request's
  `release/2` runs, which for this codebase's request shapes is expected to
  be low hundreds of milliseconds at worst, not tens of seconds. Retrying
  after 1s is far more likely to succeed than waiting 30s, and costs the
  client nothing extra if it doesn't (it can be rejected again immediately).
* `test/letflow/api/error_test.exs:126-134` — `service_unavailable/1`'s own
  test asserts `type: ".../problems/service-unavailable"`, `title: "Service
  Unavailable"`, `status: 503`, `detail: <caller-supplied>`. This design's
  503 responses go through the exact same `Error.service_unavailable/1` +
  `Response.service_unavailable/2` call path, so the body shape is identical
  by construction — nothing new to assert.
* `lib/letflow/plugs/http_metrics.ex` — the only existing example in this
  codebase of request-scoped cleanup-on-response-completion, via
  `Plug.Conn.register_before_send/2`. **Read carefully below (§5) because
  this exact mechanism, used alone, does NOT cover this requirement's raise
  acceptance criterion** — verified against `deps/bandit/lib/bandit/
  pipeline.ex`, not assumed.
* `deps/bandit/lib/bandit/pipeline.ex:34-60,206-231` — `Bandit.Pipeline.run/5`
  wraps the whole `call_plug!/2` → `commit_response!/1` sequence in an outer
  `try/rescue` and an inner `try/catch`. **`register_before_send/2` callbacks
  only run inside `commit_response!/1`** (line 44, reached only on the
  non-exceptional path). On any `catch`/`rescue`, execution jumps straight to
  `handle_error/7`, which calls `Bandit.HTTPTransport.send_on_error/2`
  **directly on the raw transport** — it never touches the crashed request's
  `Plug.Conn` struct at all, so any `before_send` callbacks registered on
  that conn are never invoked. This is Bandit's existing, unrelated-to-this-
  requirement crash-response mechanism (`REQ-066`'s design doc §0.3
  independently confirms "no global rescue/`Plug.ErrorHandler` in this
  codebase currently catches" — still true; this design adds one, narrowly,
  see §5).
* `deps/plug/lib/plug/router.ex:254-271` — `Plug.Router`'s generated
  `dispatch/2` wraps the call to the MATCHED ROUTE HANDLER (`fun.(conn,
  opts)`, inside a `:telemetry.span/3`) in its own `try/catch`. On any
  `kind, reason` caught there, it calls `Plug.Conn.WrapperError.reraise(conn,
  kind, reason, __STACKTRACE__)` — and the `conn` closed over here is
  `dispatch/2`'s own function parameter, i.e. the conn as it stood
  immediately before the route handler ran: already threaded through
  `Plug.Parsers`, both admission plug mounts, `AuthPipeline`, and
  `TenantStatus`. A raise INSIDE the matched route handler is therefore
  captured together with a conn that DOES carry both admission-ref assigns.
* `deps/plug/lib/plug/conn/wrapper_error.ex` — `WrapperError.reraise/4`'s
  `:error`-kind clause builds `%Plug.Conn.WrapperError{conn: conn, kind:
  :error, reason: reason, stack: stack}` and raises that struct as the new
  exception; its `:throw`/`:exit` clauses re-raise the original kind/reason
  unchanged, without wrapping. `Plug.Router`'s `dispatch/2` is the only
  place in this codebase's dependency chain that ever constructs a
  `Plug.Conn.WrapperError`, and it only does so around the route-handler
  call, never around any plug that runs before `:match`/`:dispatch`.
* `deps/plug/lib/plug/error_handler.ex:78-96` — the module's
  `@before_compile`-generated `call/2` has TWO separate clauses, not one, and
  the earlier version of this design only examined the second: a `rescue e
  in Plug.Conn.WrapperError ->` clause, which matches the struct
  `dispatch/2` built above and calls `Plug.ErrorHandler.__catch__/6` with
  `conn = e.conn` — the DOWNSTREAM, fully-threaded conn captured inside
  `dispatch/2`, carrying both admission-ref assigns — and a SEPARATE `catch
  kind, reason ->` clause, for anything that reaches `call/2` WITHOUT already
  being a `Plug.Conn.WrapperError` (i.e. anything that never passed through
  `dispatch/2`'s own try/catch), which calls `__catch__/6` with `conn` bound
  to `call/2`'s OWN outer parameter — the conn
  `Letflow.Plugs.ApiPipeline.call/2` was originally invoked with, before
  either admission plug ran. Either way, `__catch__/6` unconditionally
  re-raises after invoking `handle_errors/2` (`:erlang.raise(kind, reason,
  stack)`), so Bandit's own `handle_error/7` still runs exactly as it does
  today and still produces the same generic crash response this codebase
  already produces with no `Plug.ErrorHandler` in the picture (§0's Bandit
  trace above is unaffected either way — no new response body/status is
  introduced by any of this).

  **Consequence, precisely scoped** (an earlier version of this design
  claimed, incorrectly, that nothing in this codebase's stack ever wraps a
  raise in `Plug.Conn.WrapperError` — that claim is false, per the two
  bullets above, and is corrected here):
  * A raise inside the MATCHED ROUTE HANDLER (during `:dispatch`, after
    `:match`) is captured via the `rescue e in Plug.Conn.WrapperError`
    clause with `e.conn` = the fully-downstream conn. `conn.assigns` IS
    reliable here — both admission-ref assigns are present, and a
    `register_before_send/2`-only cleanup would in fact be READABLE at this
    call site (though it would still never RUN, since `register_before_send`
    callbacks are skipped on every crash path regardless of which conn they
    close over — see the Bandit bullet above; that part of the earlier
    analysis was correct).
  * A raise inside a PLUG that runs BEFORE `dispatch/2` —
    `Letflow.Plugs.AuthPipeline`, `Letflow.Plugs.TenantStatus`, or
    `Letflow.Plugs.Admission`'s own believed-unreachable tenant-derivation
    crash branches (§2) — is NOT wrapped in `Plug.Conn.WrapperError` at all:
    `Plug.Builder.compile/3`'s generated pipeline body (the sequence of
    `plug` calls before `:match`/`:dispatch`) has no per-plug `try/catch` of
    its own; only `Plug.Router`'s `dispatch/2` adds one, and only around the
    final route-handler call. Such a raise propagates straight to
    `Plug.ErrorHandler`'s plain `catch` clause, whose `conn` is `call/2`'s
    own outer parameter — the PRE-PIPELINE conn. Neither admission-ref
    assign is visible on that conn: each `assign/3` call happened on a
    locally-rebound `conn` variable inside `Plug.Builder`'s generated
    function body, a binding invisible to `call/2`'s separately-bound outer
    parameter. `conn.assigns` is NOT reliable for this case.

  This design's raise-safety mechanism (§5, Mechanism B) is justified ONLY
  against this second, narrower case — an exception raised by a PLUG before
  `dispatch/2` ever runs — not against a blanket "nothing wraps in
  WrapperError" claim. That narrower case is real and still needs Mechanism
  B: it covers exactly the raise sites this requirement's own admission
  plug mounts sit adjacent to (`AuthPipeline` runs between the two admission
  mounts; `TenantStatus` runs after the second; `Admission`'s own
  "unreachable" branches, §2, are themselves plug code running before
  `dispatch/2`).

## 1. Plug shape: one parameterized module, mounted twice

`Letflow.Plugs.Admission`, a single `@behaviour Plug` module, mounted TWICE
in `lib/letflow/plugs/api_pipeline.ex`'s plug chain with different mount
options: once with an option selecting the global pool, positioned as the
very first plug (before `Plug.Parsers`), and once with an option selecting
the tenant pool, positioned after `Letflow.Plugs.AuthPipeline` and before
`Letflow.Plugs.TenantStatus`. The exact resulting chain order is given in
full in §7.

**Not two separate modules.** The two gates differ only in (a) how the
`Letflow.Admission.pool_selector()` value is derived (`:global` is a literal;
`{:tenant, schema}` requires reading `conn.assigns.auth_context.tenant_id`
and calling `TenantProvisioning.schema_name_for_tenant/1`) and (b) which
`conn.assigns` key holds the resulting ref and which telemetry/rejection
`detail` string is used. Every other line — the `try_acquire/2` call, the
`{:error, :capacity}` halt-and-respond behavior, the success-path ref-storage
and before_send registration, the process-dictionary bookkeeping for the
raise-safety net (§5) — is identical. Two near-duplicate modules would
violate `docs/anti-patterns.md`'s fragment-duplication concern for a second
mechanism (module code, not SQL) as directly as the case that entry already
warns about. `init(opts)` validates `opts[:pool] in [:global, :tenant]` at
compile-mount time (via `Plug.Router`'s `plug/2` macro, which calls `init/1`
once per mount, not per-request) and returns the validated opts unchanged —
no per-request cost to the parameterization.

```
@type mount_opt :: [pool: :global | :tenant]

@spec init(mount_opt()) :: mount_opt()
@spec call(Plug.Conn.t(), mount_opt()) :: Plug.Conn.t()
```

## 2. Pool-selector derivation per mount

* `pool: :global` → `pool_selector = :global`. No `conn.assigns` read at all.
* `pool: :tenant` → reads `tenant_id = conn.assigns.auth_context.tenant_id`
  (guaranteed present: this mount point is always after `AuthPipeline`, which
  either halts the request itself on auth failure or assigns `:auth_context`
  before allowing the request through — mirrors `TenantStatus`'s own stated
  assumption at `tenant_status.ex:70-74`, "TenantStatus is only ever mounted
  after AuthPipeline in the same pipeline"). Then calls
  `Letflow.TenantProvisioning.schema_name_for_tenant(tenant_id)`.
  * `{:ok, schema_name}` (the expected case — `AuthPipeline` already computed
    this same derivation successfully for this exact `tenant_id` earlier in
    the SAME request, at `auth_pipeline.ex:140`, or the request would never
    have reached this plug) → `pool_selector = {:tenant, schema_name}`.
  * `{:error, :invalid_tenant_id}` — documented as **unreachable in
    practice** (§0's `TenantProvisioning.schema_name_for_tenant/1` is a pure
    function of `tenant_id`; if it were going to fail for this `tenant_id` it
    would already have failed inside `AuthPipeline` itself before
    `:auth_context` was ever assigned, per `resolve_schema_name/1`'s own
    `{:error, {:api_token, :tenant_not_found}}` translation at
    `auth_pipeline.ex:206-209`). This design does not add a defensive
    fallback response for this branch — it is intentionally left to crash
    (a `MatchError`/`FunctionClauseError` on an unmatched `{:error, _}`,
    same fail-closed philosophy `TenantStatus`'s own moduledoc documents at
    §6.4/OQ-14 for a comparably "should not occur" case), so a violation of
    the stated invariant is loud (a 500 + logged crash) rather than silently
    admitting or silently rejecting every request. Flagged as an explicit
    design choice, not an oversight, for REVIEWER.
  * No `:auth_context` assigned at all (`conn.assigns[:auth_context]` is
    `nil`) — same "should not occur; not defended against" stance
    `TenantStatus` itself takes (`tenant_status.ex:70-74`): this plug is only
    ever mounted after `AuthPipeline` in `ApiPipeline`'s own fixed chain, so
    this branch does not need independent handling. Not implemented as a
    silent pass-through (unlike `TenantStatus`'s own `nil` case) because
    letting a genuinely tenant-less request skip the per-tenant admission
    gate would be a silent widening of admission capacity for an
    unauthenticated-shaped request that should never exist at this point in
    the chain; instead it crashes the same way the `{:error, :invalid_tenant_id}`
    branch above does (both are "the precondition this plug's mount position
    establishes was violated" cases, handled identically).

## 3. `{:error, :capacity}` — halt and respond

On `{:error, :capacity}` from `try_acquire/2`, `call/2` performs, in order:
(1) set the `retry-after` response header on the conn to the string form of
`retry_after_seconds/0`'s value (§4); (2) call
`Letflow.Api.Response.service_unavailable/2` with that conn and this mount's
rejection-detail string (below), which produces the RFC 9457 problem
document and sets the response status; (3) halt the conn (`Plug.Conn.halt/1`)
so no further plug in the chain runs. No other work happens on this path.

* `retry_after_seconds/0` — see §4.
* `rejection_detail(:global)` → `"server at capacity, retry shortly"`;
  `rejection_detail({:tenant, _schema})` → `"tenant at capacity, retry
  shortly"` — caller-chosen wording (AC5 only requires the RFC 9457 field
  shape to match `Error.service_unavailable/1`'s existing contract, which it
  does by construction since both call the exact same function; the `detail`
  string's exact text is not itself an acceptance criterion). `schema` is
  never interpolated into `detail` — no tenant-identifying data belongs in a
  response a caller for a DIFFERENT tenant could plausibly observe (this
  admission plug runs before any authorization check that would otherwise
  scope what a caller may learn about other tenants; keeping the string
  identical regardless of which tenant was rejected costs nothing and avoids
  a cross-tenant information leak that would otherwise need its own security
  sign-off).
* `Response.service_unavailable/2` internally resolves `trace_id` from
  `conn.assigns[:trace_id]` (`send_problem/2`'s documented precedence,
  §0). For the **global** gate specifically — mounted before both
  `Plug.Parsers` and `:assign_trace_id` — `conn.assigns[:trace_id]` is not
  yet set at rejection time, so `effective_trace_id/2`'s existing fallback
  (`conn.assigns[:trace_id] || ""`) applies and the document's `trace_id`
  field is `""`. This is an accepted, pre-existing behavior of
  `Response.send_problem/2` itself (not something this plug special-cases),
  and is the correct trade-off per this requirement's own ordering rationale
  (§0/REQ text point 1): a request rejected for lack of capacity should cost
  as little pre-rejection work as possible, and computing a trace id before
  knowing whether the request will even be admitted is exactly the kind of
  work AC1 wants avoided. The **tenant** gate runs after `:assign_trace_id`,
  so its own 503s always do carry a real trace id.
* `Plug.Conn.halt/1` — `Plug.Router`'s compiled pipeline (via
  `Plug.Builder.compile/3`) checks `conn.halted` after every plug in the
  `plug` list and skips every remaining one, including `Plug.Parsers` itself
  when the global gate halts, and `:match`/`:dispatch` in both cases. This is
  what makes AC1's "`Plug.Parsers` never runs" property hold — it is a
  structural property of `Plug.Router`'s existing halt semantics, not
  anything this plug implements itself.

## 4. `Retry-After` config

New key, `:retry_after_seconds`, added inside the SAME `:letflow, :admission`
application-config keyword list REQ-216's `Letflow.Admission.start_link/1`
already reads `:reserved_headroom` from (`admission.ex:160-164`) — not a new
top-level config namespace, since both keys govern the same feature area.
Default, when the key is absent, is `1` (second).

`retry_after_seconds/0` (private to `Letflow.Plugs.Admission`):

```
@spec retry_after_seconds() :: pos_integer()
```

Reads the `:retry_after_seconds` key out of the `:letflow, :admission`
application-config keyword list, defaulting to `1` when the key is absent —
same "read application config, default if missing" shape
`Letflow.Admission.start_link/1` already uses for `reserved_headroom`. Read
fresh on every rejection (not cached at startup or compile time), so a test
overriding this key via `Application.put_env/3` observes the new value with
no other code change, mirroring AC1/AC2's own config-override testing
convention for REQ-216's caps. This is a **fixed
configured value**, never computed from queue depth or observed contention —
per the requirement text, this admission mechanism has no queueing/backoff
model to derive an estimate from (§0's `Letflow.Admission` moduledoc: "no
wait queue... never parked").

## 5. Ref storage and release — the raise-safety mechanism

**Two independent, non-exclusive mechanisms**, justified below. Both are
active on every request; they overlap deliberately rather than trying to
cleanly partition "normal" vs. "crash" cases, because `Letflow.Admission.
release/2` is documented idempotent (§0) — a ref already removed from the
server's `refs` map is a safe no-op on a second `release/2` call. This
overlap is the design's OWN safety margin, not a bug to eliminate.

**Storage on success (both mounts):** on a successful `try_acquire/2`, `call/2`
assigns the resulting `admission_ref()` onto the conn, under one of two
distinct assign keys depending on which mount produced it (one key for the
global-pool ref, one for the tenant-pool ref) — satisfying the requirement
text's explicit "stores both `admission_ref()`s in `conn.assigns`"
instruction, and giving `TEST-DESIGNER` a conn-visible hook to assert
against directly in the normal-completion tests (AC3).

**Mechanism A — `Plug.Conn.register_before_send/2`, for every NON-crashing
response path (2xx/3xx/4xx/5xx-via-`Response.*`/`halt`, matching
`Letflow.Plugs.HttpMetrics`'s own precedent, §0):** immediately after
assigning the ref, `call/2` registers a `before_send` callback (via
`Plug.Conn.register_before_send/2`) that, when it runs, releases this
mount's ref if the corresponding assign is still present on the conn passed
to it (idempotent — a no-op if already released) and returns the conn
unchanged otherwise. This covers AC3 (normal completion) and also covers a
LATER plug's own explicit `halt/1` + response (e.g. `TenantStatus`'s 403/503,
or a route handler's ordinary error response) — any of `Plug.Conn`'s own
`send_resp`/`send_chunked`/`send_file`, which is what actually triggers
registered `before_send` callbacks (`commit_response!/1` in Bandit's
pipeline, §0), always runs on these paths since nothing crashed.

**Mechanism B — a narrowly-scoped `use Plug.ErrorHandler` on
`Letflow.Plugs.ApiPipeline` itself, for the raise sites Mechanism A cannot
reach:** Mechanism A does not cover every raise — §0's Bandit trace proves
`register_before_send/2` callbacks are skipped entirely on any
`catch`/`rescue` in `Bandit.Pipeline.run/5`, for ANY raise regardless of
where it originates. Whether `conn.assigns` would even be a reliable READ
channel if something did run `handle_errors/2`-style cleanup depends on
WHERE the raise happened, per §0's corrected trace:
* A raise inside the matched ROUTE HANDLER reaches `Plug.ErrorHandler`'s
  `rescue e in Plug.Conn.WrapperError` clause with a fully-downstream conn —
  `conn.assigns` would be reliable there, but Mechanism A still never runs
  its callback on this path (Bandit trace above), so a conn-based read
  inside `handle_errors/2` is still needed for this case, not `conn.assigns`
  cleanup via `before_send`.
* A raise inside a PLUG that runs before `dispatch/2` — `AuthPipeline`,
  `TenantStatus`, or `Letflow.Plugs.Admission`'s own believed-unreachable
  branches (§2) — reaches `Plug.ErrorHandler`'s plain `catch` clause with the
  PRE-PIPELINE conn, on which `conn.assigns` carries neither admission-ref
  assign at all, regardless of whether either admission mount had already
  run and assigned its ref on a (now-invisible) downstream conn binding.

Since `conn.assigns` is unreliable for the second case and, even where
reliable, is only reachable at all via a `Plug.ErrorHandler` `handle_errors/2`
callback (never via `register_before_send`, which never fires on a raise),
this design uses a single mechanism that works uniformly for both cases
instead of two different read strategies: `Letflow.Plugs.Admission` defines
a process-dictionary key, as a named, documented module attribute — following
the SAME convention `lib/letflow/engine/wasm/host_api.ex`
(`@staged_writes_pdict_key`, `@fail_signal_pdict_key`) and
`lib/letflow/engine/lua/platform.ex` (`@staged_writes_pdict_key`) already
establish in this codebase for exactly this class of problem (request/
execution-scoped state that must survive a callback/exception boundary
independent of which local variable binding is in scope): a
`{ModuleName, :purpose_atom}` tuple bound to a module attribute, not a bare
inline atom. This design's attribute is named `@admission_refs_pdict_key`,
value `{Letflow.Plugs.Admission, :admission_refs}`. On every successful
`try_acquire/2`, in addition to the `conn.assigns` write above, `call/2`
prepends the new ref onto a list held under this key in the process
dictionary of the process handling the request. Process dictionary state is
process-local and lives for the lifetime of the Erlang process handling this
request regardless of which `conn` value is locally bound in which stack
frame at crash time — it is unaffected by `Plug.Builder`'s per-plug conn
rebinding and by the exception unwinding that loses everything on the conn's
own call stack, so it is readable from `handle_errors/2` regardless of which
of the two raise sites above triggered it.

`Letflow.Plugs.ApiPipeline` adds `use Plug.ErrorHandler` (after `use
Plug.Router`, matching `Plug.ErrorHandler`'s own documented ordering
requirement relative to `Plug.Debugger`, not applicable here since this
codebase has no `Plug.Debugger`) and defines a `handle_errors/2` callback
(`@impl Plug.ErrorHandler`, `@spec handle_errors(Plug.Conn.t(), %{kind:
:error | :throw | :exit, reason: term(), stack: Exception.stacktrace()}) ::
Plug.Conn.t()`) whose body: reads the ref list held under
`@admission_refs_pdict_key` (defaulting to an empty list if absent), calls
`Letflow.Admission.release/1` on each entry in that list, clears the key from
the process dictionary, and returns the conn it was given unchanged. Then
`Plug.ErrorHandler`'s own generated `call/2` unconditionally re-raises the
original exception after `handle_errors/2` returns (§0) — so Bandit's
existing `handle_error/7` still runs exactly as it does today and still
produces the same generic crash response this codebase already produces
with `Plug.ErrorHandler` absent. No new response body, status code, or
contract is introduced by this requirement for the crash path — `use
Plug.ErrorHandler` here is pure cleanup plumbing, never a caller of
`Response.internal_error/1` or any other response helper, which keeps this
requirement's scope disjoint from REQ-066's own explicitly-deferred "global
Postgrex-error-to-JSON rescue" question (`req066-api-error-response.md`
§0.3) — this design does not answer that question and does not need to.

**Process-dictionary hygiene on the NON-crash path:** since `handle_errors/2`
only runs on a raise, an entry written under `@admission_refs_pdict_key`
would be left in the process dictionary after a normal (non-raising) request
completes unless something clears it. Because Bandit request-handling
processes are not guaranteed to be a fresh process per request (keep-alive
connections may reuse the same process for sequential — never concurrent —
requests, per `ThousandIsland`'s per-connection process model this codebase
already relies on transitively via Bandit), Mechanism A's `before_send`
callback ALSO clears this process-dictionary key (in addition to releasing
the `conn.assigns` ref) so a normal request leaves no stale process-
dictionary entry behind for a later request on the same reused process to
double-release against. `release/2`'s own idempotency (§0) makes the
ordering between "release the `conn.assigns` ref" and "clear the process-
dictionary list" unimportant — whichever release call runs first wins, and
the second is always a safe no-op.

**Ordering summary per gate:** the global gate's `before_send` (Mechanism A)
release/clear runs strictly before the tenant gate's, since it was
registered first and `Plug.Conn.register_before_send/2` runs callbacks in
LIFO order (`Plug.Conn`'s own documented behavior) — irrelevant here since
each callback only touches its OWN pool's ref/list entry, not the other's,
so there is no cross-gate ordering dependency to reason about.

## 6. Scope boundary — no async dispatch involved

This entire mechanism is synchronous, in-request-process code: `try_acquire/2`
and `release/2` are both plain `GenServer.call/2`s executing on the calling
request's own process, and `register_before_send/2`/`Plug.ErrorHandler`
callbacks both run on that same process before it finishes handling the
request. Nothing here spawns a `Task`, uses `Letflow`'s
`Task.Supervisor`-based fire-and-forget delivery pattern (e.g.
`deliver_with_retry`-shaped webhook dispatch), or hands work to a different
process. There is no async boundary for a leaked reference to cross, and no
"fire-and-forget" analysis applies to this requirement at all — confirming
this explicitly per the task brief, since REQ-216/REQ-217's admission budget
being about concurrent DB-connection-holding *request* work is adjacent
enough to this codebase's other async-dispatch subsystems that the
distinction is worth stating rather than leaving implicit.

## 7. Exact `api_pipeline.ex` chain after this change

In order, top to bottom: (1) `Letflow.Plugs.Admission` mounted with the
global-pool option — NEW, first plug in the chain, before `Plug.Parsers`;
(2) `Plug.Parsers`, unchanged; (3) the existing `:assign_trace_id` plug,
unchanged; (4) `Letflow.Plugs.AuthPipeline`, unchanged; (5)
`Letflow.Plugs.Admission` mounted again with the tenant-pool option — NEW,
positioned after `AuthPipeline` and before `TenantStatus`; (6)
`Letflow.Plugs.TenantStatus`, unchanged; (7) `:match`, unchanged; (8)
`:dispatch`, unchanged. Only the two new mounts at positions (1) and (5) are
added; every other plug's position and options are unchanged from today.

`use Plug.ErrorHandler` is added to the module's own `use`/`import` header
(alongside the existing `use Plug.Router`), plus the new `handle_errors/2`
callback (§5) and the two new `plug/2` mount lines above — no other line in
`api_pipeline.ex` changes. `assign_trace_id/2`'s own private wrapper function
is untouched.

## 8. Moduledoc obligations for `Letflow.Plugs.Admission`

Per the requirement text's explicit instruction, the new plug's own moduledoc
must state, in its own words (not merely by reference to this design doc):

1. The disclosed limitation: `AuthPipeline`'s own DB work (its steps 1-4) is
   covered only by the global gate, never a per-tenant one, because tenant
   identity does not exist yet at that point in the chain.
2. The independently-justified `retry_after_seconds` reasoning (§0/§4): why 1s
   here is right where `TenantStatus`'s 30s is right for ITS OWN, structurally
   different case, not a copy-uncritically situation.
3. Which cleanup mechanism is used and why (§5's two-mechanism design), with
   the precise, narrow scope of the raise-safety gap Mechanism B closes: a
   raise inside a PLUG running before `Plug.Router`'s `dispatch/2` (e.g.
   `AuthPipeline`, `TenantStatus`, or this plug's own believed-unreachable
   branches) is not wrapped in `Plug.Conn.WrapperError` and surfaces with a
   pre-pipeline conn that carries neither admission-ref assign — this, not a
   blanket claim that nothing in this codebase's stack ever wraps a raise in
   `Plug.Conn.WrapperError`, is why the process-dictionary mechanism exists.
   This is this requirement's most safety-critical property and must not be
   left for a future reader to re-derive from Bandit/Plug source the way this
   design doc had to.

## 9. Resolved decisions and open questions

**Resolved — process-dictionary key convention (was OQ-1 in an earlier
version of this design):** this design does not invent a novel idiom.
`lib/letflow/engine/wasm/host_api.ex` and `lib/letflow/engine/lua/
platform.ex` already establish, in this codebase, a documented
`@xxx_pdict_key` module-attribute convention (a `{ModuleName, :purpose_atom}`
tuple bound to a named attribute, e.g. `@staged_writes_pdict_key`,
`@fail_signal_pdict_key`) for exactly this survives-a-callback-boundary
problem. §5 follows that convention directly
(`@admission_refs_pdict_key`, `{Letflow.Plugs.Admission, :admission_refs}`)
rather than a bare inline atom, so no collision-guarding open question or
REVIEWER-blessed new idiom is needed — this is simply the existing
convention applied to a third call site.

**Resolved — tenant-derivation-failure branches (was OQ-2 in an earlier
version of this design):** CODE-DESIGN-VALIDATOR's review of this design's
prior iteration confirmed §2's choice — letting the (believed unreachable)
`{:error, :invalid_tenant_id}` and missing-`:auth_context` branches crash
rather than defensively responding via `Response.internal_error/1` — is
acceptable as-is, matching `TenantStatus`'s own fail-closed precedent for a
comparably "should not occur" case. No further design change is needed here;
§2 and §8 already commit to stating this in the plug's own moduledoc.

No further open questions remain for this design.

## 10. REWORK (step-01e, SECURITY-REVIEWER step-03 FAIL) — the double-global-consumption fix

**Defect this section fixes, restated precisely:** the design in §1–§9 above (as
shipped and FAILED by SECURITY-REVIEWER at
`handoffs/WF02-REQ217-20260903/step-03-security-reviewer.json`) has the global
gate (mount 1) acquire a `:global` unit and hold it, via Mechanism A/B, for the
ENTIRE remaining request lifetime — including the whole span the tenant gate
(mount 2) runs in. Per REQ-216's own "composing" rule (§0 of
`req216-admission-control-core.md`, item 2: "a `{:tenant, _}` acquisition
consumes the SAME global budget as `:global` acquisitions" — NOT reopened
here, see below), mount 2's `try_acquire({:tenant, schema})` ALSO consumes one
global unit. From the instant `AuthPipeline` completes to the instant the
response is sent, a single admitted request therefore holds TWO global units
simultaneously, for a budget REQ-216 calibrated to mean "one unit per
concurrently-DB-connection-holding request." This halves the effective
concurrent-request ceiling relative to `pool_size - reserved_headroom`,
confirmed by the shipped tests' own comments (`global_cap == 2` is the
minimum that admits even one request end to end — should be `1`).

### 10.1 Chosen fix: release the global gate's ref immediately after `AuthPipeline` completes, before the tenant gate acquires

This is SECURITY-REVIEWER's suggested direction, adopted as-is over the
alternative considered and rejected in §10.2. **No change to
`Letflow.Admission`'s public API, state shape, or atomicity algorithm.**
REQ-216 is already merged and released; its own design doc's acceptance
criteria (AC3: atomic check-both-mutate-both for a `{:tenant, _}`
acquisition) impose no obligation to accommodate "a caller wants to hold one
ref across two dependent, sequential gates" — that is REQ-217's own
plug-composition problem, solved entirely at the plug level below.

**What changes, precisely:**

1. **New release point, no new `Letflow.Admission` call shape.** A new plug
   function is added to `Letflow.Plugs.ApiPipeline`'s chain, positioned
   immediately after `Letflow.Plugs.AuthPipeline` and immediately BEFORE the
   `Letflow.Plugs.Admission, pool: :tenant` mount (i.e. between them, not
   replacing either). It calls a new public function on
   `Letflow.Plugs.Admission`:

   ```
   @spec release_global_ref(Plug.Conn.t()) :: Plug.Conn.t()
   ```

   Body, precisely: if `conn.assigns[:global_admission_ref]` is `nil`, return
   `conn` unchanged (defensive — should not occur on this path, since the
   global gate is mounted first and always assigns this key or halts before
   this plug is ever reached, but matching this design's existing
   "idempotent, never raise on a no-op release" posture rather than assuming
   the invariant). Otherwise: (a) call `Letflow.Admission.release/1` on that
   ref — the SAME `release/1` REQ-216 already exposes, unchanged, called one
   step earlier than before, nothing new; (b) remove that SPECIFIC ref (not
   the whole list — the tenant ref has not been pushed yet at this point in
   the chain, but removing by value rather than by "clear the list" keeps
   this function correct regardless of future reordering) from the
   `@admission_refs_pdict_key` list via `List.delete/2`; (c) `assign(conn,
   :global_admission_ref, nil)`, so mount 1's ALREADY-REGISTERED
   `before_send` callback (Mechanism A, §5, still registered and still
   fires later at response time) sees `nil` under that assign key and takes
   its existing no-op branch (`release_ref(nil) -> :ok`) — no code change
   needed in `admit/3`'s callback for this to be safe, because that callback
   was already written to treat "ref no longer present" as a safe no-op, for
   exactly this kind of early-release scenario.
   `Letflow.Plugs.ApiPipeline` mounts this the same way it already mounts
   `:assign_trace_id` (§0/§7): a thin private, local, 2-arity wrapper
   function (name: `release_global_admission/2`) that ignores its `opts`
   argument and delegates its `conn` argument straight to
   `Letflow.Plugs.Admission.release_global_ref/1`, returning that call's
   result. It is mounted in the plug chain by atom name (`Plug.Router`'s
   `plug/2` macro only accepts a module or a local-function atom — never a
   remote function capture — the identical constraint `assign_trace_id/2`'s
   own existing wrapper already exists to satisfy).

2. **The tenant gate's acquisition shape is UNCHANGED.** Mount 2
   (`Letflow.Plugs.Admission, pool: :tenant`) still calls
   `Admission.try_acquire({:tenant, schema_name})` exactly as before — still
   the full composing pair (global + tenant) in one atomic REQ-216 call, per
   REQ-216's own unmodified design. It is simply the FIRST global unit this
   request holds by the time it runs (the original one having just been
   released in step 1), not a second one stacked on an already-held first.

3. **Exact new chain order (supersedes §7):** (1) `Letflow.Plugs.Admission,
   pool: :global` — unchanged position; (2) `Plug.Parsers` — unchanged; (3)
   `:assign_trace_id` — unchanged; (4) `Letflow.Plugs.AuthPipeline` —
   unchanged; **(5) NEW — `:release_global_admission`**, releasing mount 1's
   ref; (6) `Letflow.Plugs.Admission, pool: :tenant` — unchanged call shape,
   now the sole global-unit holder from here on; (7) `Letflow.Plugs.TenantStatus`
   — unchanged; (8) `:match`; (9) `:dispatch`.

4. **Every OTHER path's release mechanism is unchanged and still needed.**
   The new step 5 plug only ever runs on the path where the global gate
   admitted AND `AuthPipeline` itself did not halt/raise. Two other paths
   still exist and still rely on the ORIGINAL Mechanism A/B exactly as §5
   already specifies, unmodified:
   * Global gate admits, but `AuthPipeline` itself halts the request (auth
     failure) before reaching step 5 — the plug chain skips every remaining
     plug including the new one (`Plug.Builder`'s `conn.halted` check, §3),
     so the global ref is still released the ORIGINAL way, via mount 1's own
     `before_send` callback firing when `AuthPipeline`'s own halt+response is
     sent. No double consumption is possible here because the tenant gate is
     never reached at all on this path.
   * Global gate admits, then something raises before reaching step 5 (inside
     `AuthPipeline` itself, or in the global gate's own believed-unreachable
     branches) — Mechanism B (`handle_errors/2` draining the pdict list)
     still releases it, unchanged, exactly as §5 already specifies. Again,
     the tenant gate is never reached, so no double consumption exists to fix
     on this path — the ONLY path this rework changes is the one where BOTH
     gates run to completion, because that is the only path where double
     consumption is possible.
   * Global gate is rejected outright (`{:error, :capacity}`) — request halts
     at mount 1 itself, unchanged, step 5 never reached, nothing to release
     beyond what `reject/2` already does (nothing was ever acquired).

5. **`release_pending_refs/0` (Mechanism B, unchanged in shape) now typically
   drains a list containing at most the TENANT ref by the time it is reached
   for a raise occurring at or after step 6** (since the global ref was
   already surgically removed from that list by `release_global_ref/1` at
   step 5) — this is exactly the intended effect, not a special case
   `handle_errors/2` needs to know about: it already iterates whatever is in
   the list and calls `release/1` on each idempotently, regardless of how
   many entries remain.

### 10.2 Alternative considered and rejected: skip the tenant gate's own global-consuming acquisition, reusing the already-held global ref

Rejected. This would require `Letflow.Admission` to expose either (a) a new
acquisition shape that acquires ONLY the per-tenant counter without
co-checking/co-incrementing the global one (contradicts REQ-216's §0 item 2
"composing" decision as a per-call OPT-OUT, meaning `Letflow.Admission` would
now need to know "the caller already holds a global unit, do not check or
increment it again for this call" — a new concept its atomicity algorithm,
§1 of `req216-admission-control-core.md`, does not have and was not designed
to reason about safely: the whole point of evaluating both conditions in one
`handle_call/3` before mutating either is that BOTH conditions are always
freshly checked together; a caller-asserted "skip the global check, trust my
already-held ref" bypasses that atomicity guarantee for the DURATION the
skip is in effect, which is exactly the kind of thing REQ-216's design
explicitly reasoned should never be split across two checks), or (b) passing
the already-held global `admission_ref()` into the tenant acquisition call
so `Letflow.Admission` recognizes and "transfers" it — again a new public
API surface and a new internal ref-identity concept neither `try_acquire/2`
nor `admission_ref()`'s current opaque, uninspectable design (§0: "opaque,
callers must not construct/pattern-match it directly") supports. Either
variant means changing `Letflow.Admission`'s already-merged, already-released
public contract and/or its core atomicity algorithm to accommodate REQ-217's
own composition bug — exactly what the task brief instructs this design to
avoid unless no plug-level fix exists. §10.1's fix requires zero changes to
`Letflow.Admission` (same `try_acquire/2`, same `release/1`, same atomicity
algorithm, same opaque ref type) and is strictly simpler. Rejected.

### 10.3 Race-condition analysis (the task brief's question (a)) — addressed explicitly, not glossed over

**Yes, a gap exists**, and it is deliberately accepted as ordinary,
correct admission-control behavior, not a defect requiring further design
work. Precisely: between `release_global_ref/1` releasing mount 1's global
unit (step 5) and the tenant gate's `try_acquire({:tenant, schema})`
re-acquiring a (global + tenant) pair (step 6), some OTHER request's
`try_acquire/2` call — global or tenant-composing — could win the
now-freed global slot first, because `Letflow.Admission`'s single-`GenServer`
mailbox serializes ALL callers' requests in arrival order (§1 of
`req216-admission-control-core.md`), and this request's own step-6 call is
just another message in that same queue, with no priority or reservation
carried over from step 1's grant. **Consequence:** a request that was
admitted at the global gate is NOT guaranteed to also be admitted at the
tenant gate — it can receive `{:error, :capacity}` at step 6 immediately
after having been told "yes" at step 1, having already spent the cost of
`Plug.Parsers`, trace-id assignment, and the full `AuthPipeline` DB round
trip.

**Why this is accepted, not a defect:**

1. **It is what "admission control" already means everywhere else in this
   design.** `Letflow.Admission`'s own moduledoc (§0, quoted above) states
   there is "no wait queue... never parked" — every `try_acquire/2` call, at
   either gate, is already documented as an independent, freshly-evaluated,
   first-come-first-served decision with no reservation semantics. Two
   `try_acquire/2` calls FROM THE SAME REQUEST were never specially linked
   by REQ-216's design in the first place; REQ-217's original (buggy) wiring
   only ACCIDENTALLY behaved as if they were linked, by holding the first
   ref open as a kind of de facto reservation through the second call — and
   that accidental behavior is precisely the mechanism causing the
   double-consumption defect this rework fixes. Removing it removes the
   defect AND the (unintended, undocumented, never-an-acceptance-criterion)
   reservation side effect together; there is no way to keep one without the
   other short of the rejected §10.2 alternative.
   
2. **It reflects real resource usage more accurately than the buggy
   version did, not less.** The global cap exists to bound concurrent
   DB-connection-holding work (REQ-216 §0 item 3's whole rationale). By the
   time `AuthPipeline` completes, this request is no longer holding any DB
   connection — released it back to the pool internally already. Holding a
   global unit open past that point (the original bug) OVER-counts this
   request's actual resource use; releasing it at step 5 makes the count
   track reality. A request that then loses the race for a fresh unit at
   step 6 is exactly as legitimate a rejection as one that loses the race
   for the FIRST unit at step 1 would be — both reflect "the pool is at
   capacity right now," which is the entire, correct purpose of this
   mechanism.

3. **No starvation risk beyond ordinary admission control's own.** The
   released slot is not specially reserved for anyone; it becomes available
   to whichever caller's message is next in the single GenServer's mailbox,
   the same arbitration every other pair of competing `try_acquire/2` calls
   in this system already gets. There is no scenario where THIS request is
   less likely to win that slot than any other waiting request — it is not
   deprioritized, only no longer artificially prioritized by an implicit
   reservation the original design never intended to grant.

**Moduledoc obligation added (supersedes/extends §8 item 1):**
`Letflow.Plugs.Admission`'s moduledoc must additionally state: admission at
the global gate is a re-checked, not reserved, precondition for admission at
the tenant gate — a request admitted at the global gate can still receive
`{:error, :capacity}` at the tenant gate, after `AuthPipeline`'s own work has
already run, because the global gate's unit is released immediately after
`AuthPipeline` completes and the tenant gate performs a fresh, independent
`try_acquire/2` call rather than reusing or extending the first grant. This
is intentional (§10.3) and must not be "fixed" by re-introducing overlap
between the two gates' held refs.

### 10.4 Acceptance-criteria arithmetic that must be re-derived (flagged for TEST-DESIGNER, not resolved here)

`test/letflow/plugs/admission_pipeline_test.exs`'s existing AC3/AC4 comments
assert `global_cap == 2` is the minimum needed to admit one full request end
to end. Under §10.1's fix, this must become `global_cap == 1`: at no instant
does an admitted request hold more than one global unit, because the second
gate's acquisition never begins until the first gate's unit has already been
released. This is a TEST-DESIGNER-owned rework (re-deriving the exact
minimum-cap values these tests assert), not something this design doc
resolves further — flagged here so it is not silently missed when tests are
updated to match this rework.
