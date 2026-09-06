# REQ-072 — Tenant-scoped request context and the cross-tenant 404 mechanism

PROVENANCE (historical, not current decision authority):
**Module:** `Letflow.Api.Context` (new), `lib/letflow/api/context.ex`.
**Depends on:** `Letflow.TenantProvisioning.schema_name_for_tenant/1` (REQ-022),
`Letflow.Plugs.AuthPipeline` (REQ-071, populates `conn.assigns[:auth_context]`),
`Letflow.Api.Response`/`Letflow.Api.Error` (REQ-066, already define `not_found/1` and
`conn.assigns[:trace_id]` as the trace-id read site).
**Ports:** `src/api/tenant_context.zig` (104 lines), `src/api/trace_context.zig` (55
lines), `src/api/pipeline_context.zig` (45 lines) — folded into this one module, no
separate Letflow module for any of the three. Stated explicitly in the moduledoc (AC1).

---

## 0. Why one module, and why these three fold together

R-Co's three files are all the same shape: a `threadlocal` global set once per
request by request-entry middleware, read by everything downstream, cleared at
request end. Zig has no per-request object to carry state on, so a thread-local
stands in for one. Elixir/Plug has that object already — `conn` — so the
threadlocal shape has no reason to exist here at all; **every one of the three
becomes a `conn.assigns` key, populated once, read directly off the conn by
whoever needs it.** There is nothing left for a `pipeline_context`-equivalent
module to do once its one field (`pipeline_run_id`) is just another
`conn.assigns` key — hence "folds in, not ported separately" (AC1, and this
requirement's own text says so explicitly; the moduledoc must repeat the
reasoning, not just the conclusion).

PROVENANCE (historical, not current decision authority):
`pipeline_context.zig`'s `pipeline_run_id` has **no current Letflow caller** —
grep confirms no S1–S3 module reads or writes a pipeline-run correlation id yet.
This module reserves the `conn.assigns[:pipeline_run_id]` key name (documented,
not implemented as a real assignment anywhere) so a future caller has a fixed
place to put it, consistent with how `tenant_context.zig`'s `StorageMode`
enum/`storage_mode` fields are **not** ported at all — Letflow has no
`LEGACY_RLS` mode (decision 0003 Dimension B: schema-per-tenant from the first
migration, never a dual-mode period) — recorded as an open question below
rather than silently dropped.

---

## 1. `conn.assigns` keys this module owns

| Key | Type | Set by | Read by |
|---|---|---|---|
| `:trace_id` | `String.t()` | `Letflow.Api.Context.assign_trace_id/1` (a plug-shaped function, see §2) | `Letflow.Api.Response.send_problem/2` (already reads it — REQ-066), any handler/plug logging a request-scoped line |
| `:auth_context` | `%{user_id:, tenant_id:, roles:}` | **Not this module** — `Letflow.Plugs.AuthPipeline` (REQ-071), already shipped | `Letflow.Api.Context.scoped_repo_opts/1` (this module, read-only) |
| `:pipeline_run_id` | `String.t()` | **Reserved, not assigned by anything today** (see §0) | nothing today |

No new key stores a tenant id, schema name, or `:prefix` value directly on
`conn.assigns` — those are derived on demand by `scoped_repo_opts/1` (§3) from
`:auth_context`, not cached onto the conn, so there is exactly one place
(`:auth_context[:tenant_id]`) a tenant identity can be read from anywhere in the
request lifecycle. This is deliberate: caching a derived `:prefix` onto assigns
would create a second, potentially-stale place to read tenant scope from, which
is the shape AC6/INV-1 exist to prevent.

---

## 2. The trace-id mechanism (AC1, AC2)

### 2.1 Function signatures

```
@spec assign_trace_id(Plug.Conn.t()) :: Plug.Conn.t()
```
PROVENANCE (historical, not current decision authority):
A plug-shaped function (same `conn -> conn` signature as a function plug, callable
as `plug :assign_trace_id` or `plug &Letflow.Api.Context.assign_trace_id/1` from
`Letflow.Plugs.ApiPipeline`), not a `@behaviour Plug` module — matches this
project's existing convention of small conn-transforming helpers that don't need
`init/1` (contrast with `Letflow.Plugs.AuthPipeline`, which is a full `@behaviour
Plug` because it has real `opts`; this function takes none). **Design decision,
not silently assumed:** mounting point is `Letflow.Plugs.ApiPipeline`, immediately
after `Plug.Parsers` and before `Letflow.Plugs.AuthPipeline` — mirrors
`trace.zig`'s own doc comment ("This middleware MUST run FIRST — before auth,
content-type, and all other middleware — so that even authentication failures
are traceable"). ELIXIR-DEV wires this mount point; this design only specifies
where it must go and why.

```
@spec generate_trace_id() :: String.t()
```
PROVENANCE (historical, not current decision authority):
Private-or-public pure helper: a UUID v4 string, matching `trace.zig`'s
`generateUuidV4/1` (36-char canonical form). Uses `Ecto.UUID.generate/0` (already
a project dependency via `ecto`) rather than hand-rolled byte-twiddling — Elixir
has no allocator to manage, so `trace.zig`'s manual buffer-filling has no
Elixir-idiomatic reason to survive the port.

### 2.2 Behavior

PROVENANCE (historical, not current decision authority):
1. Read the `x-trace-id` request header (Plug lower-cases header names; R-Co's
   `X-Trace-Id` request header name is preserved on the **response** side, see
   below — R-Co's own convention, confirmed directly from `trace.zig`'s module
   doc and `MAX_TRACE_ID_LEN` constant).
PROVENANCE (historical, not current decision authority):
2. If present and non-empty: propagate it as-is, **truncated to 256 bytes**
   (`trace.zig`'s `MAX_TRACE_ID_LEN`) — no UUID-shape validation, matching
   `extractOrGenerate/2`'s explicit "no UUID validation is performed on incoming
   values" behavior. This is a direct behavioral port, not an idiom translation;
   preserved intentionally (a caller-supplied trace id is a correlation
   convenience, not a security-checked value).
3. If absent or empty: generate a fresh UUID v4 via `generate_trace_id/0`.
4. `assign(conn, :trace_id, trace_id)`.
5. Mirror into `Logger.metadata(trace_id: trace_id)` **immediately after step
   4**, so every `Logger.info/1`-style call made anywhere later in the same
   process during this request automatically carries `trace_id` — this is the
   sanctioned log-correlation mechanism the requirement text names ("mirror it
   into Logger.metadata/1 for log correlation only"). `Logger.metadata/1` is
   itself process-dictionary-backed under the hood (that's `:logger`'s own
   implementation, not this module's choice) — **this does not violate AC1's
   "no module in lib/letflow/api/ uses Process.put/Process.get" rule**, because
   this module never calls `Process.put/2`/`Process.get/1` directly itself; it
   calls the public `Logger.metadata/1` API, which is the standard, idiomatic
   Elixir mechanism for exactly this purpose (every Elixir/Phoenix app that logs
   a request id does this). The moduledoc must state this distinction
   explicitly — "we call `Logger.metadata/1`, we do not touch the process
   dictionary ourselves" — so a future grep-based audit doesn't misflag it.
6. `Logger.metadata/1` is per-process and Plug/Bandit does not guarantee the
   request is handled on a fresh process per call in every adapter configuration
   — **open question below (OQ-1)**, not silently resolved.
PROVENANCE (historical, not current decision authority):
7. Response header: set `x-trace-id` (Plug downcases; emitted on the wire as
   `x-trace-id`, matching R-Co's own convention of a `X-Trace-Id`-named header,
   case differences being purely an HTTP/1.1 wire convention Plug enforces) to
   the same value assigned in step 4, via `put_resp_header/3`, **at the same
   point `assign_trace_id/1` runs** (i.e. this function both assigns AND sets
   the response header eagerly — it does not wait until the response is actually
   sent) — this differs from R-Co's own arrangement (`trace.zig`'s doc comment:
   "HTTP server writes X-Trace-Id response header from trace_context.get()" —
   i.e. R-Co sets it at send-time, reading the threadlocal). Setting it eagerly
   here is safe and simpler because `put_resp_header/3` merely stages the header
   on the conn struct; Plug/Bandit doesn't finalize response headers until
   `send_resp/3` (or equivalent) is actually called later in the pipeline, so an
   early-set header survives unless a later plug explicitly overwrites it (no
   such later plug exists in this design). Stated as a deliberate simplification
   in the moduledoc, not left implicit.

### 2.3 Test design (AC2)

`test/letflow/api/context_test.exs`:

- `describe "assign_trace_id/1 propagation"`
  - `test "propagates an incoming X-Trace-Id header value onto conn.assigns and the response header"` —
    build a conn with `put_req_header("x-trace-id", "caller-supplied-id")`, call
    `assign_trace_id/1`, assert `conn.assigns.trace_id == "caller-supplied-id"`
    and `get_resp_header(conn, "x-trace-id") == ["caller-supplied-id"]`.
  - `test "generates a UUID v4 when no incoming header is present"` — assert
    `conn.assigns.trace_id` matches `~r/^[0-9a-f-]{36}$/` and the response
    header carries the identical value.
  - `test "truncates an incoming header longer than 256 bytes"`.
- `describe "log correlation (AC2)"`
  - `test "the same trace id appears on the response header and in a log line emitted during the request"` —
    use `ExUnit.CaptureLog.capture_log/1` wrapping a full plug-pipeline call (a
    minimal `Plug.Test.conn/3` through `assign_trace_id/1` followed by a
    `Logger.info("handling request")` call standing in for a real handler's own
    logging), assert the captured log text contains the trace id string AND
    that `get_resp_header(conn, "x-trace-id")` returns the same string — this
    is the "captures both" demonstration AC2 requires. `Logger.metadata/1`'s
    effect can only be observed through an actual `Logger.*` call during the
    test, which is why the test must make one rather than asserting on
    `Logger.metadata()`'s return value alone (asserting only the metadata call
    happened would not prove a log line actually carried it).

### 2.4 AC1's grep + moduledoc obligation

- `grep -rn "Process\.\(put\|get\)\|:ets\." lib/letflow/api/` must return zero
  hits — a bare grep, run by ELIXIR-DEV during self-review and re-run
  independently by SECURITY-REVIEWER/CODE-DESIGN-VALIDATOR/REVIEWER, each per
  their own gate.
- The moduledoc's opening section (mirroring §0 above) must state: (a) R-Co
  used Zig `threadlocal` for per-request trace/tenant/pipeline context, (b) Zig
  has no request object so a thread-local stood in for one, (c) Elixir's `conn`
  already is that per-request object, so every threadlocal becomes an explicit
  `conn.assigns` key, (d) the one place `Logger.metadata/1` (which is itself
  process-dictionary-backed inside `:logger`) is used is documented as *not*
  this module reaching for `Process.put/2` itself, per §2.2 step 5.

---

## 3. The scoping function (AC3, AC6) — the load-bearing half

### 3.1 Name and signature

```
@spec scoped_repo_opts(Plug.Conn.t()) ::
        {:ok, prefix: String.t()} | {:error, :missing_auth_context | :invalid_tenant_id}
```

Named `scoped_repo_opts/1`, chosen over the requirement text's other example
(`fetch_scoped/3`) because:
- Its **only** input is `conn` (in practice, only `conn.assigns[:auth_context]`
  is read from it) — a 1-arity function makes "derives its `:prefix` solely
  from `conn.assigns[:auth_context][:tenant_id]`" true by the shape of the
  signature itself, not just by convention. A `fetch_scoped/3`-shaped function
  invites a caller to pass a schema/query/id triple, which is exactly the
  "caller-supplied tenant/schema/prefix argument" AC6 forbids — naming and
  shaping the function to make that mistake structurally impossible is the
  point of picking this name over the alternative.
- Its return shape is literally an Ecto keyword-opts list fragment
  (`[prefix: schema_name]`), so every caller's own query call reads as
  `Repo.get(Schema, id, opts)` / `Repo.all(query, opts)` with `opts` spread
  in — no caller has to know or restate the keyword key name `:prefix` itself,
  reducing the chance a future caller mistypes it.

Returns `{:ok, prefix: schema_name}` on success. Returns
`{:error, :missing_auth_context}` if `conn.assigns[:auth_context]` or its
`:tenant_id` key is absent (a caller invoked this before `AuthPipeline` ran, or
against a route that doesn't require auth — a programmer error this function
must not paper over by falling through to an unscoped query). Returns
`{:error, :invalid_tenant_id}` when `Letflow.TenantProvisioning.
schema_name_for_tenant/1` itself returns `{:error, :invalid_tenant_id}` — this
mirrors REQ-071's own `AuthPipeline.provision_user/3` precedent for handling
that exact error tuple (see `lib/letflow/plugs/auth_pipeline.ex`'s
`provision_user/3`), and is very unlikely in practice (the tenant id reaching
here already round-tripped through `AuthPipeline`'s own successful
`Identity.resolve_tenant_by_realm/1` + `verify_realm_ownership/2` calls to get
onto `conn.assigns` in the first place) but is not treated as "impossible" —
**no silent fallback to an unscoped query in either error case.** A caller
receiving `{:error, _}` from this function MUST NOT proceed to call
`Repo.*` without a prefix; it must render a 401/403/500 (caller's choice,
scoped to the caller's own route context — not prescribed here) or otherwise
halt the conn. This module does not itself decide which status code a caller
maps `{:error, _}` to, since that is route-specific policy this module has no
visibility into — **left as an explicit convention for the fifteen route
requirements, not resolved here** (OQ-2 below).

### 3.2 Why not derive tenant id from anywhere else

The function signature takes `conn`, not `tenant_id`, specifically so a future
caller cannot be tempted to pass a value read from the request path/query/body —
there is no parameter slot for one. Internally, the **only** field read is
`conn.assigns[:auth_context][:tenant_id]`; a request-path `:tenant_id`
parameter, a `?tenant_id=` query string value, and an `X-Tenant-Id` request
header are never read by this function or by anything in this module — not
"read and then discarded," literally never touched, so there is no code path
where they could accidentally win a precedence fight.

### 3.3 AC3's negative-input test design

`test/letflow/api/context_test.exs`, `describe "scoped_repo_opts/1 ignores request-supplied tenant hints (INV-1, AC3)"`:

- Build a conn with `conn.assigns[:auth_context][:tenant_id] = tenant_a_id`
  (a real, provisioned tenant fixture — see §4.1 for the fixture mechanism),
  **and simultaneously**:
  - a path param `conn.params["tenant_id"] = tenant_b_id` (or path_params, per
    how the route under test declares its param — `Plug.Conn`'s `params`
    field, populated the way a real matched route would),
  - a query string `conn.query_params["tenant_id"] = tenant_b_id` (or
    `conn.query_string = "tenant_id=#{tenant_b_id}"` then
    `Plug.Conn.fetch_query_params/1`),
  - a request header `put_req_header(conn, "x-tenant-id", tenant_b_id)`.
- Call `scoped_repo_opts(conn)`.
- Assert `{:ok, prefix: schema_name}` where `schema_name` is
  **`tenant_a`'s** schema name (`TenantProvisioning.schema_name_for_tenant/1`
  applied to `tenant_a_id`), never `tenant_b`'s — proving all three
  conflicting hints were ignored and only the token's tenant (`:auth_context`)
  won.
- A second test asserts the **absence of any tenant_id/schema/prefix
  parameter** in the function's own signature by calling it with only one
  argument (`conn`) and confirming (via `Kernel.function_exported?/3` or simply
  the fact that the test file compiles calling it 1-ary) that no 2-, 3-, or
  4-arity overload exists — this is the mechanical half of AC6's "confirmed by
  inspection of every public function's signature," backing the moduledoc
  prose with a compiled-code check.

---

## 4. The cross-tenant-404 test design (AC4/AC5) — the hardest pair

### 4.1 Design decision: prove the property one level below full HTTP dispatch, using a minimal, deliberately-scoped test-only fixture table — not a fake production route

**Stated explicitly, per this task's own instruction, rather than left implicit.**

REQ-070's fifteen sub-routers (`lib/letflow/routers/*.ex`) are all still stubs —
every one matches nothing but a catch-all 404 (confirmed directly: `grep -c
"match _" lib/letflow/routers/identity.ex` shows only the stub clause; no real
handler exists in any sub-router yet). Two options were weighed:

**(a) Invent a fake production route/handler inside a stub sub-router,
purely to have something to GET.** Rejected: this would add real-looking
route code to `lib/letflow/routers/identity.ex` (or another stub) that no
requirement actually asked for and that a later route requirement (REQ-073..085)
would then have to either keep, rename around, or delete — scope creep this
requirement's own text does not authorize, and exactly the shape
`core-directives.md`'s Unblock-Everything "scope boundary" warns against
manufacturing.

**(b) Prove the property directly at the level this module actually owns: the
scoping-function's output composed with a generic Ecto query, using a small
test-only fixture schema/table that exists only under `test/support/`.**
**Adopted.** This module's actual contract is "produce `[prefix: schema_name]`
opts a caller composes into their own `Repo.*` call" — it has no handler, no
route, no HTTP verb of its own. The INV-5 property this requirement discharges
("this module is where INV-5 is discharged for the whole stage," per the
requirement text) is a property of **the scoping mechanism**, not of any
specific future route's handler logic — every one of the fifteen route
requirements inherits the SAME guarantee from the SAME `scoped_repo_opts/1`
call, so demonstrating it once, correctly, against a generic tenant-scoped
`Repo.get/3` call proves it for all of them structurally, exactly as the
requirement's own rationale states ("so INV-5 is discharged once,
structurally, instead of being re-implemented and re-tested in each of the
fifteen route requirements that follow"). A fake HTTP route would not test
anything the direct Ecto-level test doesn't already cover, and would
additionally test Plug dispatch machinery this requirement doesn't own.

**Test fixture:** a minimal `test/support/req072_probe.ex` Ecto schema (e.g.
`Letflow.Api.Context.Test.Probe` — namespaced under `test/support/`, never
under `lib/`, so it never ships in a release) backed by a small
tenant-scoped table created **only inside the test database**, via a
migration-shaped fixture the same way `test/support/req022_migration_fixture.ex`
already does for `Letflow.TenantProvisioning`'s own tests (cited directly in
that module's `replay_migrations/2` doc as the established precedent for a
caller-supplied `migration_source` fixture) — i.e. this reuses an established
pattern rather than inventing a new one. Shape: `id :: binary_id` (primary
key), `label :: String.t()` — nothing else; no production meaning, its only
purpose is "a row a `Repo.get/3` call can find or not find."

### 4.2 Fixture provisioning inside the test

1. Provision two real tenant schemas via
   `Letflow.TenantProvisioning.provision_tenant_schema/1` (tenant A, tenant B —
   both real, randomly generated `binary_id`s, per this project's established
   `provisioned_tenant/0` test-support convention already used elsewhere, e.g.
   `PinRebindTest`'s own fixture cited in `docs/anti-patterns.md`).
2. Replay the probe fixture's own migration into **both** schemas via
   `TenantProvisioning.replay_migrations/2` with an explicit
   `migration_source` naming only the probe table's migration (mirroring
   `req022_migration_fixture.ex`'s own narrow-`migration_source` convention —
   this is exactly why that function accepts a caller-supplied
   `migration_source` at all).
3. Insert exactly one row into **tenant B's** schema only (`Repo.insert(changeset,
   prefix: tenant_b_schema)`) — tenant A's schema gets no row.
4. Build `conn_a`, a conn whose `conn.assigns[:auth_context][:tenant_id]` is
   **tenant A's** id (never tenant B's).
5. Compute `{:ok, prefix: schema_a}` from `scoped_repo_opts(conn_a)`.

### 4.3 The two probes and the comparison (AC4)

- **Probe 1 — cross-tenant:** `Repo.get(Probe, tenant_b_row_id, schema_a)` (the
  row's real id, which exists, but only in tenant B's schema). Under
  schema-per-tenant with no `tenant_id`-on-shared-table fallback (decision 0006
  dropped `tenant_id` from schema-isolated tables entirely — the Postgres
  schema IS the only scoping these rows have, per the requirement text), this
  query runs against schema A's own (nonexistent-for-this-id) `probe` table
  and returns `nil`, structurally, with no code path that ever looks at schema
  B.
- **Probe 2 — never-existed:** `Repo.get(Probe, Ecto.UUID.generate(), schema_a)`
  — a fresh random id that was never inserted anywhere.
- Both `nil` results are passed through the **same** caller-side "not found"
  handling a real handler would use: `case Repo.get(...) do nil ->
  Letflow.Api.Response.not_found(conn) ; row -> ... end`. Build two real
  `Plug.Conn.t()` responses this way (probe 1's conn and probe 2's conn), then
  assert:
  - `resp_1.status == resp_2.status` (both 404)
  - `resp_1.resp_body == resp_2.resp_body` (byte-identical — both go through
    `Error.not_found/0`, which per its own moduledoc takes no `detail`
    argument specifically so no per-call variation is possible, and both
    responses' `trace_id` fields are pinned to the same fixed test value so
    that field doesn't vary between the two conns either, isolating the
    comparison to exactly the property under test)
  - This directly demonstrates AC4: "a GET for a resource id that exists in
    tenant B ... returns a response byte-identical to a GET for a randomly
    generated id that exists nowhere."

### 4.4 Query-count telemetry (AC5)

Attach a test-local telemetry handler on `[:letflow, :repo, :query]` (the
standard `Ecto.Repo` telemetry event every `Ecto.Repo` emits automatically per
query — no application code change needed to observe it) via
`:telemetry.attach/4` inside the test's `setup`, counting emitted events into
an `Agent`/counter keyed by a probe-run identifier passed through
`telemetry_span_context` or simply reset between the two probes:

1. Reset the counter.
2. Run probe 1 (cross-tenant), record `count_1`.
3. Reset the counter.
4. Run probe 2 (never-existed), record `count_2`.
5. Assert `count_1 == count_2`.

This directly demonstrates AC5: "the cross-tenant path and the never-existed
path execute the same number of database queries." The mechanism that makes
this true by construction (not by coincidence of this specific test) is
`scoped_repo_opts/1` + a plain `Repo.get/3`: there is no existence-check
branch anywhere in this call path that could run an extra query for one case
and not the other, because both cases run through the identical `Repo.get/3`
call with the identical `prefix:` option — the only difference between the two
probes is the id argument's value, which cannot itself cause Ecto to emit a
different number of telemetry events for a `Repo.get/3` primary-key lookup.
`:telemetry.detach/1` in `on_exit/1` to avoid leaking the handler across tests.

---

## 5. Moduledoc content (AC1, AC6, AC7) — required prose, not implementation

The moduledoc for `Letflow.Api.Context` must state, in substance (CODE-DESIGN-VALIDATOR
checks for presence of each point, not verbatim wording):

PROVENANCE (historical, not current decision authority):
1. **§0's threadlocal-to-assigns translation reasoning** (AC1): R-Co's
   `tenant_context.zig`/`trace_context.zig`/`pipeline_context.zig` all use Zig
   `threadlocal` storage because Zig has no per-request object; Elixir's
   `Plug.Conn` already is that object, so every threadlocal becomes an
   explicit `conn.assigns` key; `pipeline_context.zig` has no separate module
   because its one field is just another assigns key with no behavior of its
   own to port. State plainly: no `Process.put/2`/`Process.get/1`/ETS table is
   used for per-request context anywhere in this module, and the one place
   `Logger.metadata/1` appears is a call to a public logging API, not this
   module reaching into the process dictionary itself.
2. **AC6's no-caller-supplied-tenant-argument constraint**: every public
   function in this module is enumerated (`assign_trace_id/1`,
   `generate_trace_id/0`, `scoped_repo_opts/1`) and for each, state which
   argument, if any, could be mistaken for a tenant/schema/prefix input, and
   confirm none exists — `assign_trace_id/1` and `generate_trace_id/0` take no
   tenant-shaped argument at all (they're trace-only), and `scoped_repo_opts/1`
   takes only `conn`, reading `conn.assigns[:auth_context][:tenant_id]`
   internally and nothing else. State explicitly: "no function in this module
   accepts a tenant id, schema name, or prefix as a caller-supplied argument."
3. **AC7's INV-5 argument against a cross-tenant existence check**: because
   `scoped_repo_opts/1`'s `:prefix` is derived solely from the authenticated
   token (never from the request), a lookup for a resource belonging to
   another tenant simply finds nothing in the caller's own schema — the 404
   this produces is not a *deliberately suppressed* "yes it exists, but not
   yours" result, it is the **only** result the query could ever produce,
   because the query never had visibility into the other tenant's schema in
   the first place. Adding a second query that checks "does this id exist in
   ANY tenant's schema" to produce a different error message ("exists,
   forbidden" vs. "truly not found") would (a) require a caller-supplied
   tenant/schema argument this module's own AC6 forbids taking, (b) run an
   extra query only on the cross-tenant path, which is exactly the query-count
   asymmetry AC5 exists to rule out, and (c) leak, via response-time
   difference and/or a different error body, the fact that *some* tenant owns
   the resource — the exact signal INV-5 defines as the property to prevent.
   State this as the reason no handler may add such a check "for a better
   error message," per the requirement text's own framing, citing INV-5 by
   name.

---

## 6. Open questions (not silently resolved)

- **OQ-1 (trace-id / `Logger.metadata/1` process scope).** `Logger.metadata/1`
  is per-BEAM-process. If Bandit/Plug ever handles a single HTTP request across
  more than one process (e.g. streaming, or a future async-handoff pattern),
  metadata set in `assign_trace_id/1`'s process would not automatically appear
  in a different process's log lines. Today's synchronous
  request-in-one-process model (matching every existing plug in this pipeline)
  makes this a non-issue, but it is not verified against Bandit's actual
  process model in this design — flagged for ELIXIR-DEV/REVIEWER to confirm
  during implementation rather than assumed.
- **OQ-2 (error-to-status-code mapping for `scoped_repo_opts/1`'s `{:error,
  _}` returns).** This design specifies that a caller MUST NOT proceed to an
  unscoped query on error, but does not prescribe which HTTP status
  (401/403/500) each of `:missing_auth_context`/`:invalid_tenant_id` maps to —
  that is route-specific and left to each of the fifteen route requirements,
  or to a future shared convention if one becomes clearly common across all of
  them.
PROVENANCE (historical, not current decision authority):
- **OQ-3 (`StorageMode`/`LEGACY_RLS` non-port).** `tenant_context.zig`'s
  `StorageMode` enum (`LEGACY_RLS`/`SCHEMA`) and its resolved-once-per-request
  tracking are **not ported** — Letflow has no legacy-RLS storage mode
  (decision 0003 Dimension B: schema-per-tenant from the first migration).
  Recorded here so a future reader doesn't wonder whether this was missed;
  it was a deliberate non-port, not an oversight.
- **OQ-4 (`pipeline_run_id` — reserved key, no writer).** See §0/§1 — this
  design reserves the `conn.assigns[:pipeline_run_id]` key name but does not
  wire any plug to populate it, since no current Letflow module consumes a
  pipeline-run correlation id. A future requirement that needs it should
  populate this exact key rather than inventing a new one.

---

## 7. Cross-module dependencies

- `Letflow.TenantProvisioning.schema_name_for_tenant/1` (REQ-022) — called by
  `scoped_repo_opts/1`, no other tenant-schema derivation exists or is added
  here.
- `Letflow.Plugs.AuthPipeline` (REQ-071) — upstream producer of
  `conn.assigns[:auth_context]`; this module never duplicates any of its
  logic, only reads its output.
- `Letflow.Api.Response` / `Letflow.Api.Error` (REQ-066) — `Response.not_found/1`
  is the single call site every "not found" path (true-missing or
  cross-tenant) must funnel through; `Response.send_problem/2` already reads
  `conn.assigns[:trace_id]`, which is why this module's key name for the trace
  id (`:trace_id`) matches what REQ-066 already expects rather than
  introducing a second name for the same concept.
- `Letflow.Plugs.ApiPipeline` (REQ-070/071) — mounts `assign_trace_id/1` as a
  new plug entry, positioned first in the chain (§2.1).

## 8. Invariants

- INV-1: `scoped_repo_opts/1`'s only tenant-identity input is
  `conn.assigns[:auth_context][:tenant_id]`; no other source is read.
- INV-5: the cross-tenant and never-existed paths are the same code path
  (`Repo.get/3` with `[prefix: schema_name]`) with no branch that varies query
  count or response body between them.
- INV-6: this design document, plus SECURITY-REVIEWER's own Step 2c pass, is
  the demonstration this new data-access path (the scoping mechanism itself)
  proves its tenant scoping before merge.

## 9. DB objects touched

**None in `lib/letflow/api/context.ex` itself** — this module reads existing
tables (`tenant_schemas`, via `TenantProvisioning`) and adds no migration of
its own. The test-only probe fixture (§4.1) adds exactly one migration under
`test/support/` (not `priv/repo/migrations/`, since it is never part of the
production schema): one table, two columns (`id :: binary_id` PK, `label ::
:string`), no indexes beyond the implicit PK, no constraints beyond `NOT NULL`
on both columns — deliberately minimal, since its only job is "exists in one
schema, doesn't exist in another."
