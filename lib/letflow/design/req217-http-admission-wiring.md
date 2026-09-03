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
* `deps/plug/lib/plug/error_handler.ex` — `use Plug.ErrorHandler` overrides
  `call/2` with `try do super(conn, opts) rescue/catch ... end`, invokes the
  using module's `handle_errors/2` callback, then **unconditionally
  re-raises** (`Plug.ErrorHandler.__catch__/6`'s last line: `:erlang.raise(
  kind, reason, stack)`) — so after `handle_errors/2` runs, the exception
  still propagates to Bandit's own `handle_error/7` exactly as it does
  today, and Bandit still produces the same generic crash response it
  already produces with no `Plug.ErrorHandler` in the picture. **Critical
  and easy-to-miss detail, verified by reading the macro-generated `call/2`
  literally**: the `conn` visible inside `handle_errors/2`'s calling
  `catch`/`rescue` clause is the **parameter bound at the top of the
  overriding `call/2`** — i.e. the conn `Letflow.Plugs.ApiPipeline.call/2`
  was originally invoked with, from `Letflow.Router`'s `forward/2` — **not**
  whatever `conn` a downstream plug had mutated it into by the time it
  raised. `super(conn, opts)`'s own internal sequential reassignment of a
  local `conn` variable (`Plug.Builder.compile/3`'s generated single-function
  body) is invisible to the caller's separate `conn` parameter binding, and
  nothing here wraps the exception in a `Plug.Conn.WrapperError` (that only
  happens if something upstream already did so, which nothing in this
  codebase does). **Consequence: `conn.assigns` is NOT a reliable channel to
  read the admission refs back out of at crash-cleanup time** — see §5 for
  the mechanism this design uses instead.

## 1. Plug shape: one parameterized module, mounted twice

`Letflow.Plugs.Admission`, a single `@behaviour Plug` module, mounted twice
in `lib/letflow/plugs/api_pipeline.ex` with different `init/1` opts:

```
plug(Letflow.Plugs.Admission, pool: :global)   # before Plug.Parsers
...
plug(Letflow.Plugs.Admission, pool: :tenant)   # after AuthPipeline, before TenantStatus
```

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

```
conn
|> Plug.Conn.put_resp_header("retry-after", to_string(retry_after_seconds()))
|> Letflow.Api.Response.service_unavailable(rejection_detail(pool))
|> Plug.Conn.halt()
```

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

New key inside the SAME `:letflow, :admission` keyword list REQ-216's
`Letflow.Admission.start_link/1` already reads `:reserved_headroom` from
(`admission.ex:160-164`) — not a new top-level config namespace, since both
keys govern the same feature area:

```elixir
config :letflow, :admission,
  reserved_headroom: 2,        # already exists (REQ-216)
  retry_after_seconds: 1       # new (REQ-217), default 1 if key absent
```

`retry_after_seconds/0` (private to `Letflow.Plugs.Admission`):

```
@spec retry_after_seconds() :: pos_integer()
```

reads `Application.get_env(:letflow, :admission, [])[:retry_after_seconds] ||
1` — same `Keyword.get`-with-default shape `Letflow.Admission.start_link/1`
already uses for `reserved_headroom`, read fresh on every rejection (not
cached), so a test overriding this key via `Application.put_env/3` observes
the new value with no other code change, mirroring AC1/AC2's own
config-override testing convention for REQ-216's caps. This is a **fixed
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

**Storage on success (both mounts):**

```
conn = Plug.Conn.assign(conn, assigns_key(pool), ref)   # :global_admission_ref / :tenant_admission_ref
```

satisfying the requirement text's explicit "stores both `admission_ref()`s in
`conn.assigns`" instruction, and giving `TEST-DESIGNER` a conn-visible hook to
assert against directly in the normal-completion tests (AC3).

**Mechanism A — `Plug.Conn.register_before_send/2`, for every NON-crashing
response path (2xx/3xx/4xx/5xx-via-`Response.*`/`halt`, matching
`Letflow.Plugs.HttpMetrics`'s own precedent, §0):**

```
Plug.Conn.register_before_send(conn, fn conn ->
  release_if_present(conn, assigns_key(pool))
  conn
end)
```

registered immediately after the successful `assign/3` above. This covers
AC3 (normal completion) and also covers a LATER plug's own explicit
`halt/1`+response (e.g. `TenantStatus`'s 403/503, or a route handler's
ordinary error response) — any of `Plug.Conn`'s own `send_resp/send_chunked/
send_file`, which is what actually triggers registered `before_send`
callbacks (`commit_response!/1` in Bandit's pipeline, §0), always runs on
these paths since nothing crashed.

**Mechanism B — a narrowly-scoped `use Plug.ErrorHandler` on
`Letflow.Plugs.ApiPipeline` itself, for the RAISE path (AC4):**

Mechanism A alone does **not** cover AC4 — §0's Bandit trace proves
`register_before_send/2` callbacks are skipped entirely on any
`catch`/`rescue` in `Bandit.Pipeline.run/5`. This design closes that gap with
the smallest addition that does not touch REQ-066's error-response contract:
`Letflow.Plugs.ApiPipeline` adds `use Plug.ErrorHandler` (after `use
Plug.Router`, matching `Plug.ErrorHandler`'s own documented ordering
requirement relative to `Plug.Debugger`, not applicable here since this
codebase has no `Plug.Debugger`) and defines:

```
@impl Plug.ErrorHandler
@spec handle_errors(Plug.Conn.t(), %{kind: :error | :throw | :exit, reason: term(), stack: Exception.stacktrace()}) :: Plug.Conn.t()
```

Per §0's read of `Plug.ErrorHandler`'s macro expansion, the `conn` this
callback receives is bound from the OUTER `call/2` parameter — i.e. the conn
`Letflow.Router`'s `forward/2` handed to `ApiPipeline.call/2` at the very
start of the request, **before either admission plug ran** — so
`conn.assigns` in `handle_errors/2` never carries the refs this design just
stored on a *different*, downstream-rebound `conn` value (§0's detailed
trace of why). **This is exactly why Mechanism B does NOT read
`conn.assigns`** — it reads a **process-dictionary-held list** instead,
populated by the SAME `Letflow.Plugs.Admission.call/2` success branch that
does the `assign/3` above:

```
Process.put(:letflow_admission_refs, [ref | Process.get(:letflow_admission_refs, [])])
```

Process dictionary state is process-local and lives for the lifetime of the
Erlang process handling this request regardless of which `conn` value is
locally bound in which stack frame at crash time — it is unaffected by
`Plug.Router`'s per-plug conn rebinding and by the exception unwinding that
loses everything on the conn's own call stack. This is the same class of
mechanism Elixir's own ecosystem already reaches for whenever request-scoped
state must survive a raise and be readable independent of which `conn`
binding is in scope (e.g. `Logger.metadata/0-1`, `Ecto.Adapters.SQL.
Sandbox`'s ownership tracking) — not a novel invention for this requirement,
though it has no prior in-repo example (`docs/anti-patterns.md` has no entry
against it; flagged for REVIEWER as a new-to-this-codebase idiom, justified
above, in case a different existing convention is preferred instead).

`handle_errors/2`'s body:

```
Process.get(:letflow_admission_refs, [])
|> Enum.each(&Letflow.Admission.release/1)

Process.delete(:letflow_admission_refs)

conn
```

then `Plug.ErrorHandler`'s own generated `call/2` **unconditionally
re-raises** the original exception after `handle_errors/2` returns (§0) — so
Bandit's existing `handle_error/7` still runs exactly as it does today and
still produces the same generic crash response this codebase already
produces with `Plug.ErrorHandler` absent. **No new response body, status
code, or contract is introduced by this requirement for the crash path** —
`use Plug.ErrorHandler` here is pure cleanup plumbing, never a caller of
`Response.internal_error/1` or any other response helper, which keeps this
requirement's scope disjoint from REQ-066's own explicitly-deferred "global
Postgrex-error-to-JSON rescue" question (`req066-api-error-response.md`
§0.3) — this design does not answer that question and does not need to.

**Process-dictionary hygiene on the NON-crash path:** since `handle_errors/2`
only runs on a raise, `Process.put/2`'s entry is left in the dictionary after
a normal (non-raising) request completes unless something clears it. Because
Bandit request-handling processes are not guaranteed to be a fresh process
per request (keep-alive connections may reuse the same process for
sequential — never concurrent — requests, per `ThousandIsland`'s per-
connection process model this codebase already relies on transitively via
Bandit), Mechanism A's `before_send` callback ALSO calls `Process.delete(
:letflow_admission_refs)` (in addition to `release_if_present/2` on the
`conn.assigns` value) so a normal request leaves no stale process-dictionary
entry behind for a later request on the same reused process to
double-release against. `release_if_present/2`'s own idempotency (§0) makes
the ordering between "release the `conn.assigns` ref" and "clear the
process-dictionary list" unimportant — whichever mechanism's release call
runs first wins, and the second is always a safe no-op.

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

```
plug(Letflow.Plugs.Admission, pool: :global)     # NEW — first plug, before Plug.Parsers
plug(Plug.Parsers, parsers: [...], ...)          # unchanged
plug(:assign_trace_id)                           # unchanged
plug(Letflow.Plugs.AuthPipeline)                 # unchanged
plug(Letflow.Plugs.Admission, pool: :tenant)     # NEW — after AuthPipeline, before TenantStatus
plug(Letflow.Plugs.TenantStatus)                 # unchanged
plug(:match)                                     # unchanged
plug(:dispatch)                                  # unchanged
```

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
3. Which cleanup mechanism is used and why (§5's two-mechanism design,
   including the "why not `conn.assigns` inside `handle_errors/2`" point) —
   this is this requirement's most safety-critical property and must not be
   left for a future reader to re-derive from Bandit/Plug source the way this
   design doc had to.

## 9. Open questions (explicitly unresolved, not guessed)

* **OQ-1:** Should `Letflow.Plugs.Admission`'s process-dictionary key
  (`:letflow_admission_refs`) collide-guard against some OTHER, future
  plug/library also using `Process.put/2` under an unrelated key? No
  collision exists today (grep confirms no other `Process.put/2` call site
  in `lib/letflow/` as of this design). Not a blocking question for this
  requirement, but worth a repo-wide convention (a shared "reserved process-
  dictionary key prefix" note in `docs/anti-patterns.md`) if a second
  requirement ever wants the same raise-survival trick — left to REVIEWER to
  decide whether to require that now or defer it.
* **OQ-2:** This design does not attempt to special-case the (believed
  unreachable, §2) `{:error, :invalid_tenant_id}`/missing-`:auth_context`
  branches with a clean 500 via `Response.internal_error/1` — it lets them
  crash and relies on Mechanism B's cleanup plus Bandit's existing generic
  crash response. If REVIEWER prefers an explicit `Response.internal_error/1`
  call for these two "should not occur" branches instead (still releasing
  refs first), that is a small, compatible change to §2's design, not a
  reason to rework anything else here — flagged rather than silently decided
  either way.
