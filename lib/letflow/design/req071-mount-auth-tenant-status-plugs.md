# REQ-071 — Mount the built auth and tenant-status plugs in front of the tenant-scoped pipeline

**Status of this design: verification + moduledoc + test-spec design only.** No new
mounting code, no plug re-porting. See the scoping note below and the run's own
`handoffs/WF02-REQ071-20260821/step-00-git-setup.json` for how this was discovered.

## 0. Scoping finding (read first)

`lib/letflow/plugs/api_pipeline.ex` already carries, as an unplanned side effect of
REQ-070's router decomposition (commit `cc1051b`):

```
lib/letflow/plugs/api_pipeline.ex:28   plug(Letflow.Plugs.AuthPipeline)
lib/letflow/plugs/api_pipeline.ex:29   plug(Letflow.Plugs.TenantStatus)
```

immediately after `Plug.Parsers` (line 27) and immediately before `:match`/`:dispatch`
(lines 30-31). `git log --oneline -- lib/letflow/plugs/api_pipeline.ex` shows exactly one
commit touching this file — no re-mount is needed. `lib/letflow/router.ex:42-50` already
handles `GET /health` inline, before the `forward("/api/v1", ...)` line, so health stays
outside this chain by construction, unchanged by REQ-071.

**This design covers only:** (1) verifying that wiring actually satisfies REQ-071's seven
acceptance criteria as written in `docs/requirements.yaml` (the exact text, not the
6-item paraphrase in this run's own Step 00 handoff — see §1a below for the
discrepancy), (2) exact moduledoc replacement text (AC6), (3) precise end-to-end test
specifications through the real mounted chain (AC1-AC5), (4) what REVIEWER's AC7
sign-off needs to check and where it's recorded.

## 1. Structural verification against each acceptance criterion

### 1a. Correction to this run's own Step 00 handoff

The handoff summarized REQ-071 as having acceptance criteria "AC1...AC4, AC6, AC7"
(6 items, with AC4 bundling both the 503/GET-200 pair and the concurrent-isolation
property). The actual `docs/requirements.yaml` entry has **7** acceptance criteria,
listed in order below — AC4 (migrating/GET) and AC5 (concurrent isolation) are two
separate criteria, not one. Per `core-directives.md`'s "a handoff's factual premises are
checkable, and may be wrong" — verified by reading the entry directly
(`awk '/^  - id: REQ-071$/,/^  - id: REQ-072$/' docs/requirements.yaml`). This design
uses the real 7-item list below; report this discrepancy in the handoff `result.issues`
at MINOR severity per the Instruction Precedence chain's "never resolve a conflict
silently" rule.

### AC1 — no Authorization header → 401, zero Repo queries

> "a request to a tenant-scoped path with no Authorization header returns 401 and
> executes zero Repo queries, demonstrated by a test that asserts on query telemetry or
> a Repo sandbox with no checkout rather than by inspection"

**Structurally satisfied.** `api_pipeline.ex:28` mounts `AuthPipeline` before
`TenantStatus` and before `:match`/`:dispatch`. `auth_pipeline.ex:102-107`
(`extract_bearer_token/1`) short-circuits to `{:error, {:header, :missing_or_malformed}}`
before any of `verify_token/1`, `resolve_tenant/1`, `guard_realm_ownership/2`,
`provision_user/3` run — all of which are the only functions in this chain that could
issue a `Repo` call (`resolve_tenant/1` → `Identity.resolve_tenant_by_realm/1`;
`provision_user/3` → `TenantProvisioning.schema_name_for_tenant/1` +
`Identity.provision_oidc_user/4`). `auth_pipeline.ex:69-70` maps that error to
`reject(conn, 401, ...)`. No gap found. Needs a **new** end-to-end test (§3 Test 1) —
the existing `auth_pipeline_test.exs` tests the plug standalone via
`Plug.Test.conn/3` + `AuthPipeline.call/2` directly, not through
`Letflow.Router`/`Letflow.Plugs.ApiPipeline`.

### AC2 — valid token → reaches handler with auth_context populated

> "a request to a tenant-scoped path with a valid token reaches the handler with
> conn.assigns[:auth_context] populated with user_id, tenant_id and roles, demonstrated
> end-to-end through the real router rather than by unit-testing the plug alone"

**Structurally satisfied for the auth_context population; genuine gap on "the handler."**
`auth_pipeline.ex:192-194` (`attach_auth_context/4`) assigns exactly
`%{user_id:, tenant_id:, roles:}` on success. But **every one of REQ-070's ten
sub-routers (`lib/letflow/routers/*.ex`) is a stub whose only route is
`match _ -> Letflow.Api.Response.not_found(conn)`** (confirmed by reading
`lib/letflow/routers/identity.ex`; the other nine are structurally identical per
REQ-070's design). There is no real business handler for any tenant-scoped path yet —
"the handler" a valid-token request "reaches" is, today, only the stub's own 404
catch-all. This is not a REQ-071 code gap (REQ-070 deliberately left sub-routers as
stubs; wiring real handlers is out of scope here and belongs to the REQ-073-and-later
requirements `identity.ex`'s own moduledoc names) — it is a genuine mismatch between
AC2's literal wording ("reaches the handler") and what exists to reach. **Design
decision: the test hits an existing stub sub-router path (e.g. `POST /api/v1/identity/
anything`) and asserts (a) status is 404, not 401/403/500/503 (proving the request
passed both `AuthPipeline` and `TenantStatus` and reached `:dispatch`), and (b) the
final `conn.assigns[:auth_context]` returned by `Letflow.Router.call/2` equals the
expected `%{user_id:, tenant_id:, roles:}` shape** — Plug conns thread the same struct
through `forward/2`, so assigns set by `ApiPipeline`'s own plugs survive into the
sub-router's returned conn; this is the honest, non-invented way to observe it without
adding a fake production route. **Report this AC2/stub-router mismatch in the handoff's
`result.issues` as a finding for ORCH** (not a defect to fix here — REQ-070 already
correctly scoped stubs as stubs).

### AC3 — GET /health 200 while OIDC provider config worker unavailable

> "GET /health returns 200 while the OIDC provider configuration worker is unavailable,
> demonstrated by a test — proving health sits outside the auth chain"

**Structurally satisfied.** `router.ex:42-50`: `plug(:match)`/`plug(:dispatch)` are
declared at the top level, and the `get "/health"` handler (line 46-48) sends
`200 {"status":"ok"}` with zero calls into `Letflow.Plugs.ApiPipeline`,
`Letflow.Oidc.*`, or `Letflow.Repo`. The `forward("/api/v1", ...)` line (line 50) is
textually after the health route, and `Plug.Router` matches routes in declaration
order — `/health` is matched and returned before the forward clause is ever considered.
No gap found. Needs a new end-to-end test (§3 Test 3) that actually stops
`Letflow.Oidc.DefaultProvider` (the `Oidcc.ProviderConfiguration.Worker` instance
registered under that name per `config/test.exs:77`/`application.ex:15-19`) and proves
`/health` still answers while it is confirmed dead.

### AC4 — POST against `:migrating` tenant → 503 + Retry-After; equivalent GET → 200

> "a POST against a tenant whose status is :migrating returns 503 with a Retry-After
> header, and the equivalent GET returns 200, through the mounted chain — two explicit
> tests"

**POST half: structurally satisfied.** `api_pipeline.ex:29` mounts `TenantStatus` right
after `AuthPipeline`. `tenant_status.ex:44-47` matches on `@write_methods` (`POST`,
`PUT`, `PATCH`, `DELETE`), reads `tenant_id` from
`conn.assigns[:auth_context][:tenant_id]` (populated by `AuthPipeline`, which ran
first — ordering confirmed by `api_pipeline.ex:28-29`'s literal declaration order),
and `check_write_pause/2` (lines 58-71) returns 503 + `Retry-After: 30` for
`%Tenant{status: :migrating}` (lines 60-61, 74-86). No gap.

**GET half: same genuine gap as AC2, worse — the literal "returns 200" is currently
unachievable end-to-end.** `tenant_status.ex:49` (`def call(conn, _opts), do: conn`)
passes any non-write method through unchanged with zero DB query, which is the correct,
already-implemented behavior — but the conn then proceeds to `:match`/`:dispatch`
(`api_pipeline.ex:30-31`) and hits the same sub-router stub as AC2, which returns 404
for every path, never 200. **No test against a real mounted route can honestly produce
a literal `200` for this GET today** without inventing a fake production route, which
the task scope explicitly forbids. **Design decision: the GET test (§3 Test 4b) asserts
the property AC4 is actually protecting — that `TenantStatus` does not reject the GET
(no 503, no `Retry-After` header) and that zero `Repo` queries for tenant-status
purposes occur for the GET path (same telemetry technique as AC1) — and the test's own
`@moduledoc`/comment states explicitly that it substitutes for AC4's literal "200"
wording until a real GET handler exists on some tenant-scoped route (a future
requirement's scope), and that this substitution is not a behavioral gap in
`TenantStatus` itself.** **Report this as a second AC-wording finding in
`result.issues`** — distinct from AC2's, since this one also affects the *test's own
assertion*, not only which path it hits.

### AC5 — concurrent isolation (tenant-status lookup failure on one request doesn't affect a concurrent request for a different tenant)

> "a tenant-status lookup failure on one request does not affect a concurrent request
> for a different tenant, demonstrated by a test running both concurrently (INV-8)"

**Structurally confirmed fail-closed, no rescue present.** `tenant_status.ex:58-59`:
`check_write_pause/2`'s only DB access is `Repo.get(Tenant, tenant_id)` with **no**
`try`/`rescue`, no `with {:ok, ...} <- ...` around it — a genuine lookup failure (a
malformed `tenant_id` causing `Ecto.Query.CastError`, or a real connection-level
failure) raises inside the request's own handling process and is never caught anywhere
in this module. This is real, not aspirational (OQ-14's design text in
`req021-auth-plug-pipeline.md` §6.4 states this as a *recommendation*; reading the
shipped code confirms it was actually implemented that way). Because Bandit/Plug
dispatches each HTTP request in its own OTP process, a crash here terminates only that
one process — it cannot corrupt a sibling request's process or its own `Ecto` pool
checkout, which is a structural BEAM guarantee, not something this plug's code has to
implement itself. Needs a new end-to-end/concurrency test (§3 Test 5).

### AC6 — moduledoc phrase removal

> "both plugs' moduledocs no longer contain the phrase 'Not mounted in front of any
> route today', confirmed by grep, and instead name the pipeline they are mounted in"

Not yet satisfied — both plugs' moduledocs still contain the literal phrase
(`auth_pipeline.ex:23`, `tenant_status.ex:24`). Exact replacement text: §2 below.

### AC7 — REVIEWER records the OQ-14 confirmation

> "the REQ-021 OQ-14 fail-closed divergence is explicitly confirmed by REVIEWER in this
> requirement's review, recorded in docs/migration/stage-4-api-surface.md's REVIEWER
> sign-off section"

Not yet satisfied — no REQ-071 entry exists yet under
`docs/migration/stage-4-api-surface.md`'s `## REVIEWER sign-off` section (confirmed:
only REQ-065 and REQ-084 entries exist there today, per the grep in this run's Step 00
notes). Exact requirement + insertion point: §4 below.

## 2. Moduledoc replacement text (AC6)

### `lib/letflow/plugs/auth_pipeline.ex` — replace lines 23-33

Current text (to remove, verbatim):

```
**Not mounted in front of any route today.** `Letflow.Router` currently
serves only `GET /health` (the earlier `POST /instances`,
`POST /instances/:id/actions`, `GET /instances/:id` pilot-slice routes
this note used to reference were removed as of REQ-046, alongside
`Letflow.ProcessInstance`'s own retirement — see
`lib/letflow/design/req046-process-instance-retirement.md` §6a); none of
today's routes are tenant-scoped or have tenant/user context to use even
if this plug ran ahead of them. This module is built, compiled, and
directly tested — left available for S4 (the first tenant-scoped route)
to add via `plug Letflow.Plugs.AuthPipeline` ahead of `:match` in
`router.ex`.
```

Replacement text (exact prose to write, ELIXIR-DEV should not paraphrase):

```
**Mounted since REQ-071.** `Letflow.Plugs.ApiPipeline` (the shared middleware chain for
every `/api/v1/*` sub-router, forwarded to from `Letflow.Router`) declares
`plug Letflow.Plugs.AuthPipeline` immediately after `Plug.Parsers` and immediately
before `Letflow.Plugs.TenantStatus`, ahead of its own `:match`/`:dispatch` — so every
request under `/api/v1` runs through this plug first, before reaching any of
REQ-070's sub-routers. `GET /health` is declared directly on `Letflow.Router`, before
the `/api/v1` forward, and never enters this chain.
```

### `lib/letflow/plugs/tenant_status.ex` — replace lines 24-27

Current text (to remove, verbatim):

```
**Not mounted in front of any route today** — see
`Letflow.Plugs.AuthPipeline`'s moduledoc for the full reasoning (none of
`Letflow.Router`'s 3 existing routes are tenant-scoped). Left available
for S4 to mount after `Letflow.Plugs.AuthPipeline` in the same pipeline.
```

Replacement text (exact prose to write):

```
**Mounted since REQ-071**, immediately after `Letflow.Plugs.AuthPipeline` in
`Letflow.Plugs.ApiPipeline`'s plug chain, matching this module's own calling
convention above — every `/api/v1/*` request has `conn.assigns[:auth_context]`
populated by `AuthPipeline` before this plug runs.
```

ELIXIR-DEV must also update the `## Deferred plugs` comment inconsistency, if any —
none found here (`api_pipeline.ex`'s own deferred table already excludes
`AuthPipeline`/`TenantStatus`, both are absent from it, so no edit needed there).

## 3. End-to-end test specifications (AC1-AC5)

All five tests belong in `test/letflow/router_test.exs` (extending the existing
`Letflow.RouterTest` module, which already calls `Letflow.Router.call(conn, @opts)` —
see that file's precedent) under a new `describe "REQ-071 ..."` block per test, matching
the file's existing `describe "REQ-070 AC..."` convention. Tests that need a real
tenant row (Tests 2, 4a, 4b, 5) need `Letflow.DataCase` (real Postgres) rather than
plain `ExUnit.Case` — since `router_test.exs` today is plain `ExUnit.Case, async: true`
(no DB), these DB-needing tests must live in a **second** test module,
`test/letflow/plugs/api_pipeline_integration_test.exs`, using `Letflow.DataCase` and
the same `insert_tenant!/1` / `insert_tenant_for_realm!/1` + `:auto` sandbox-mode
pattern already established in `test/letflow/plugs/auth_pipeline_test.exs:66-120`
(provisions a real tenant schema so `AuthPipeline`'s JIT-provisioning step succeeds).
Test 1 and Test 3 have no DB dependency and belong in the existing plain
`router_test.exs`.

### Test 1 (AC1) — `test/letflow/router_test.exs`, no DB

```
describe "REQ-071 AC1: no Authorization header returns 401, zero Repo queries" do
  test "POST /api/v1/identity/anything with no Authorization header returns 401" do
    # Attach a :telemetry handler on [:letflow, :repo, :query] (Ecto's default
    # telemetry event name for Letflow.Repo, per `otp_app: :letflow` in repo.ex)
    # before the call, detach in on_exit/1. Assert the handler fired zero times.
    conn =
      conn(:post, "/api/v1/identity/anything", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> Letflow.Router.call(@opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"] == "unauthorized"
    # assert telemetry handler call count == 0
  end
end
```

Expected body per `auth_pipeline.ex:70`:
`%{"error" => "unauthorized", "detail" => "missing or malformed Authorization header"}`.

### Test 2 (AC2) — new file, `Letflow.DataCase`

```
describe "REQ-071 AC2: valid token reaches the (stubbed) handler with auth_context populated" do
  test "POST /api/v1/identity/anything with a valid token passes auth+tenant-status and reaches the stub 404, with auth_context populated" do
    tenant = insert_tenant_for_realm!("bpm-default")  # helper per auth_pipeline_test.exs

    conn =
      conn(:post, "/api/v1/identity/anything", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer valid-test-token")
      |> Letflow.Router.call(Letflow.Router.init([]))

    assert conn.status == 404  # the stub sub-router's own not_found — NOT 401/403/500/503
    assert conn.assigns.auth_context.tenant_id == tenant.id
    assert conn.assigns.auth_context.roles == ["VIEWER"]  # TokenVerifierDouble's fixed claim
    assert is_binary(conn.assigns.auth_context.user_id)
  end
end
```

Uses `Letflow.Oidc.TokenVerifierDouble`'s fixed sentinel `"valid-test-token"` (already
wired via `config/test.exs`'s `:oidc` key, claiming realm `bpm-default` per
`test/support/token_verifier_double.ex:19-37`) — no real IdP needed, matching
`auth_pipeline_test.exs`'s own established precedent (§3.2 of the REQ-021 design).

### Test 3 (AC3) — `test/letflow/router_test.exs`, no DB

```
describe "REQ-071 AC3: /health survives the OIDC provider worker being down" do
  test "GET /health returns 200 while Letflow.Oidc.DefaultProvider is dead" do
    pid = Process.whereis(Letflow.Oidc.DefaultProvider)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    refute Process.alive?(pid)

    conn = conn(:get, "/health") |> Letflow.Router.call(@opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    # No on_exit restart needed — Letflow.Supervisor's :one_for_one strategy
    # restarts Oidcc.ProviderConfiguration.Worker automatically; confirm this
    # is true in this codebase's supervision tree (application.ex) rather than
    # asserting it, since a stale worker would otherwise affect later tests.
  end
end
```

**Open question for TEST-DESIGNER/REVIEWER, flagged rather than silently decided:**
whether this test needs `async: false` for its module (killing a shared, globally
named singleton process is not isolatable per-test the way a DB row is) — this design
recommends `async: false` for whichever module holds Test 3, to avoid a second
concurrent test observing the brief restart window, but does not mandate the exact
mechanism.

### Test 4a (AC4, POST half) — new file, `Letflow.DataCase`

```
describe "REQ-071 AC4: migrating tenant rejects writes" do
  test "POST against a :migrating tenant returns 503 with Retry-After" do
    tenant = insert_tenant_for_realm!("bpm-default")
    tenant |> Ecto.Changeset.change(status: :migrating) |> Repo.update!()

    conn =
      conn(:post, "/api/v1/identity/anything", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer valid-test-token")
      |> Letflow.Router.call(Letflow.Router.init([]))

    assert conn.status == 503
    assert get_resp_header(conn, "retry-after") == ["30"]
    assert Jason.decode!(conn.resp_body)["error"] == "tenant_migrating"
  end
end
```

### Test 4b (AC4, GET half — substituted assertion per §1's flagged gap)

```
describe "REQ-071 AC4: migrating tenant does not block reads" do
  @moduledoc_note "Substitutes for AC4's literal 'GET returns 200' wording — see this " <>
                   "design doc §1 AC4 for why a literal 200 is unachievable against " <>
                   "today's stub sub-routers without a fake production route."
  test "GET against a :migrating tenant is not rejected by TenantStatus (no 503, zero tenant-status Repo query), reaches the stub's own 404" do
    tenant = insert_tenant_for_realm!("bpm-default")
    tenant |> Ecto.Changeset.change(status: :migrating) |> Repo.update!()
    # attach telemetry on [:letflow, :repo, :query], detach in on_exit/1

    conn =
      conn(:get, "/api/v1/identity/anything")
      |> put_req_header("authorization", "Bearer valid-test-token")
      |> Letflow.Router.call(Letflow.Router.init([]))

    assert conn.status == 404  # stub's own not_found, not 503
    refute "30" in get_resp_header(conn, "retry-after")
    # assert telemetry handler recorded zero queries attributable to the
    # tenant-status check specifically (the JIT-provisioning lookups in
    # AuthPipeline itself DO query the DB — this assertion is scoped to
    # TenantStatus's own Repo.get(Tenant, tenant_id) call, not the whole request)
  end
end
```

### Test 5 (AC5) — new file, `Letflow.DataCase`, concurrency

```
describe "REQ-071 AC5: a tenant-status lookup failure on one request does not affect a concurrent request for a different tenant" do
  test "a malformed tenant_id crashes only its own request process; a concurrent valid request for a different tenant still succeeds" do
    good_tenant = insert_tenant_for_realm!("bpm-default")
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)  # already :auto via insert_tenant!

    bad_conn_fun = fn ->
      conn(:post, "/whatever")
      |> Plug.Conn.assign(:auth_context, %{tenant_id: "not-a-uuid", user_id: "u", roles: []})
      |> Letflow.Plugs.TenantStatus.call(Letflow.Plugs.TenantStatus.init([]))
    end

    good_conn_fun = fn ->
      conn(:post, "/whatever")
      |> Plug.Conn.assign(:auth_context, %{tenant_id: good_tenant.id, user_id: "u", roles: []})
      |> Letflow.Plugs.TenantStatus.call(Letflow.Plugs.TenantStatus.init([]))
    end

    bad_task = Task.async(fn ->
      try do
        {:ok, bad_conn_fun.()}
      rescue
        e -> {:crashed, e}
      end
    end)

    good_task = Task.async(good_conn_fun)

    assert {:crashed, %Ecto.Query.CastError{}} = Task.await(bad_task)
    good_conn = Task.await(good_task)
    assert good_conn.status == nil  # TenantStatus passes an :active tenant through unhalted
  end
end
```

**Design rationale for the concurrency mechanism:** this test is deliberately at the
`Letflow.Plugs.TenantStatus.call/2` level, not through the full `Letflow.Router`, for
the same reason `tenant_status_test.exs`'s own moduledoc already gives for its
standalone-plug convention — the property under test (OTP process isolation on a
`Repo.get/2` crash) is a structural BEAM guarantee independent of which plug or router
triggers the call, and isolating it at this level removes `AuthPipeline`'s own JIT-
provisioning DB work as a confound in the "did the bad request's queries interfere
with the good one" reasoning. `Ecto.Query.CastError` (raised by `Repo.get/2` when
`tenant_id` fails to cast to the schema's `:binary_id` primary key type) is a genuine,
reproducible lookup failure raised from inside `check_write_pause/2` with **no**
`rescue` anywhere in `tenant_status.ex` (confirmed §1 AC5) — using it, rather than
trying to force a real Postgrex connection-level error, keeps the test deterministic
and avoids destabilizing the shared connection pool other concurrent tests may be
using. Both tasks run under `Ecto.Adapters.SQL.Sandbox` `:auto` mode (real concurrent
connections from the pool, established by `insert_tenant!/1`), which is what actually
exercises "concurrent," not merely "sequential-looking-concurrent" Elixir code.

## 4. What REVIEWER's AC7 confirmation needs to check and where to record it

**Exact code to verify:** `lib/letflow/plugs/tenant_status.ex:58-59` —

```
defp check_write_pause(conn, tenant_id) do
  case Repo.get(Tenant, tenant_id) do
```

Confirm: (a) no `try`/`rescue`/`with {:ok, ...} <-` wraps this call anywhere in the
module, (b) a raised exception here is therefore uncaught inside `TenantStatus`, (c)
per Bandit/Plug's per-request-process model, the crash terminates only the process
handling that one request. REVIEWER should also independently re-run (or read the
result of) §3's Test 5 above once TEST-RUNNER has executed it, per
`core-directives.md`'s "every producing step has a validating step" — REVIEWER's own
sign-off should cite that test's actual pass/fail, not just re-derive the reasoning
from reading the source.

**Where to record it:** `docs/migration/stage-4-api-surface.md`'s existing
`## REVIEWER sign-off` section (confirmed present, currently holding a
`**2026-08-20 (REQ-065) — PASS.**` entry and a `**2026-08-21 (REQ-084) — PASS.**`
entry, in that chronological order). Append a new dated entry,
`**2026-08-21 (REQ-071) — PASS|FAIL.**`, in the same prose-paragraph format the
existing two entries use (a short intro sentence, then a bulleted list of concrete
findings) — do not restructure the section's existing entries, append only.

## 5. Cross-module dependencies

- `Letflow.Plugs.ApiPipeline` (unchanged by this requirement, already correct)
- `Letflow.Plugs.AuthPipeline` (moduledoc edit only, §2)
- `Letflow.Plugs.TenantStatus` (moduledoc edit only, §2)
- `Letflow.Router` (unchanged — health already correctly excluded)
- `Letflow.Routers.*` (all ten, read-only for this requirement — their stub status is
  the AC2/AC4 finding in §1, not something this requirement fixes)
- `Letflow.Oidc.TokenVerifierDouble` / `config/test.exs`'s `:oidc` key (test-only,
  already exists, reused as-is)
- `Letflow.Oidc.DefaultProvider` (the named `Oidcc.ProviderConfiguration.Worker`
  instance Test 3 stops)
- `docs/migration/stage-4-api-surface.md` (REVIEWER's AC7 entry, §4)

## 6. Invariants

- `AuthPipeline` must always run before `TenantStatus` in `ApiPipeline`'s plug list —
  `TenantStatus` depends on `conn.assigns[:auth_context][:tenant_id]` being already
  resolved (OQ-12 in the REQ-021 design explicitly leaves the reverse order
  undefined/unsupported).
- `GET /health` must never be reachable through `Letflow.Plugs.ApiPipeline` — it must
  stay declared directly on `Letflow.Router`, ahead of the `/api/v1` forward.
- No `try`/`rescue` may be added around `TenantStatus`'s `Repo.get/2` call as part of
  this requirement — doing so would silently reverse the OQ-14 fail-closed decision
  AC7 exists specifically to have REVIEWER confirm, not re-decide.

## 7. Open questions (not silently resolved)

1. **Test 3's `async` setting** (§3) — recommended `async: false`, not mandated; left
   to TEST-DESIGNER/REVIEWER per §3's note.
2. **Whether AC2/AC4-GET's literal wording should itself be corrected in
   `docs/requirements.yaml`** (retroactively acknowledging the stub-router reality) or
   left as-is with the substituted-assertion tests standing in until a real handler
   exists — this design does not decide that; it is exactly the kind of finding
   `core-directives.md`'s "No Issue Left Local-Only" says to report to ORCH rather than
   silently resolve. Recorded here so REVIEWER/TEST-DESIGN-VALIDATOR do not
   independently re-discover it as if novel.
3. **Whether AC1/AC4b's "zero Repo queries" telemetry assertion should use a shared
   test helper** (a `Letflow.TelemetryTestHelper` or similar) rather than each test
   attaching/detaching its own handler inline — not specified here; either is
   acceptable, left to TEST-DESIGNER's judgment matching this project's existing test
   style.

## 8. Acceptance-criteria traceability

| REQ-071 acceptance criterion (verbatim from `docs/requirements.yaml`) | Concrete design element |
|---|---|
| AC1: no Authorization header → 401, zero Repo queries | §1 AC1 (structural verification); §3 Test 1 |
| AC2: valid token → reaches handler, auth_context populated, end-to-end | §1 AC2 (verification + flagged stub-router gap); §3 Test 2 |
| AC3: GET /health 200 while OIDC provider worker unavailable | §1 AC3 (structural verification); §3 Test 3 |
| AC4: migrating POST → 503+Retry-After; equivalent GET → 200 | §1 AC4 (verification + flagged GET-200 gap); §3 Test 4a, Test 4b |
| AC5: concurrent isolation of a tenant-status lookup failure | §1 AC5 (fail-closed confirmation); §3 Test 5 |
| AC6: moduledoc phrase removal | §2 (exact replacement text, both plugs) |
| AC7: REVIEWER records OQ-14 confirmation | §4 (exact code to check, exact insertion point) |
