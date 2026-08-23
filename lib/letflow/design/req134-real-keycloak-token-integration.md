# REQ-134 — Real-Keycloak token integration path for `AuthPipeline`

Status: design. Owner: CODE-DESIGNER. Run: WF02-REQ134-20260823.

## 0. Problem restated

`config/test.exs` pins `:token_verifier` to `Letflow.Oidc.TokenVerifierDouble`
(unconditionally, for every test) so the default suite never depends on a running
Keycloak. That is correct and this design does **not** change it — but it means no test
in this repository has ever driven a genuine JWT through
`Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2`'s real signature/JWKS/issuer
verification path. This design adds one tagged, excluded-by-default integration test
module that does exactly that, against the real local Keycloak `docker-compose.yml`
already stands up (REQ-128), without changing the double's status as the unit-suite
default and without making `mix test`/`scripts/test_parallel.sh` depend on Keycloak
being reachable.

## 1. Files touched

| File | Change | Category |
|---|---|---|
| `test/test_helper.exs` | add `exclude: [:keycloak]` to `ExUnit.start/1` | test-support (existing file, one-line change) |
| `test/support/keycloak_test_client.ex` | **new** | test-support only (see §4 for why) |
| `test/letflow/integration/keycloak_auth_pipeline_test.exs` | **new** | test code |
| `test/specs/REQ-134.md` | **new**, written by TEST-DESIGNER at Step 3 | test spec |

No `lib/` module changes. `config/test.exs`'s `token_verifier:
Letflow.Oidc.TokenVerifierDouble` line is untouched — the new test overrides
`Application.get_env(:letflow, :oidc)` for its own process/duration only (§3.1), it does
not touch the config file.

## 2. Default-exclusion mechanism (AC4, AC5, AC6)

**Decided, not left open:** `test/test_helper.exs` changes from

```
ExUnit.start()
```

to

```
ExUnit.start(exclude: [:keycloak])
```

`ExUnit.start/1`'s `:exclude` option applies to every invocation that loads this
`test_helper.exs` — plain `mix test`, `mix test <path>`, and
`scripts/test_parallel.sh`'s `MIX_TEST_PARTITION=<i> mix test --partitions N` processes
alike, since all three load the same `test/test_helper.exs`. This is why no change to
`scripts/test_parallel.sh` itself is needed: the exclusion is baked into the ExUnit
runtime config, not passed as a per-invocation CLI flag, so every partition already
excludes `:keycloak`-tagged tests without the script knowing tag names exist.

- **Every acceptance criterion's test module carries `@moduletag :keycloak`** (module
  level, not per-test — every test in the file needs Keycloak, there is no partial-skip
  case).
- **Normal / default run (AC4's exact command):**
  ```
  mix test
  ```
  and, for the full suite:
  ```
  scripts/test_parallel.sh
  ```
  Both run with Keycloak stopped or running — the module is excluded either way, so
  neither depends on Keycloak's state. TEST-RUNNER's AC4 evidence is the real output of
  one of these two commands, captured with the `keycloak` docker-compose service
  stopped, showing `test/letflow/integration/keycloak_auth_pipeline_test.exs`'s tests
  are not among those run (0 excluded-count mismatch, or an explicit `Excluded: N` line
  in ExUnit's summary — ExUnit prints `Excluded: <n>` in its `Result:` summary whenever
  `--exclude`/`exclude:` filters anything out).
- **Deliberate inclusion (AC6's exact command, verbatim — state this in the result and
  in the new test module's own moduledoc):**
  ```
  mix test --include keycloak test/letflow/integration/keycloak_auth_pipeline_test.exs
  ```
  `--include keycloak` overrides the `exclude: [:keycloak]` default from
  `test_helper.exs` for this invocation only (ExUnit's own precedence: an explicit
  `--include` on the CLI re-admits a tag `ExUnit.start/1` excluded). The path argument
  scopes the run to just this file, so a developer isn't also re-running the double-based
  suite redundantly, though running `mix test --include keycloak` with no path argument
  also works (every other test file has no `:keycloak` tag to match, so `--include`
  alone changes nothing for them).

## 3. Skip behavior when Keycloak isn't running (AC5)

### 3.1 `setup_all` reachability probe

```
setup_all do
  # ...
end
```

runs a single reachability probe against Keycloak's OIDC discovery endpoint before any
test in the module executes, and returns `{:skip, message}` on failure — the ExUnit
mechanism that marks every test in the `describe`/module block "skipped" (not
"failed") with `message` shown in the run summary, the same semantic
`web/tests/e2e/onboarding/onb-ui-01.e2e.spec.ts`'s `assertServicesReady/1` achieves via
a thrown `Error`, adapted to ExUnit's own skip idiom rather than a raised exception
(a raised exception would report as a *failure*, not a *skip* — AC5 explicitly asks for
a skip, not an obscure failure).

Probe target: the realm's discovery document, matching `config/test.exs`'s already-real
issuer (`http://localhost:<keycloak_port>/realms/bpm-default`, `keycloak_port` read via
`Code.eval_file(Path.expand("../../../config/keycloak_port.exs", __DIR__))` — same
per-workspace port resolution `config/test.exs` itself uses, so this test never hardcodes
a port either):

```
discovery_url = "http://localhost:#{keycloak_port}/realms/bpm-default/.well-known/openid-configuration"
```

**Exact skip message text (mirrors the onboarding e2e pattern's two components — what's
down, and what to do about it):**

```
Keycloak not ready at http://localhost:<port>/realms/bpm-default/.well-known/openid-configuration. Ensure docker-compose services are running (docker compose up -d keycloak) before executing these tests.
```

with `<port>` interpolated from the real resolved value, matching the onboarding
pattern's own interpolated-URL convention (`onb-ui-01.e2e.spec.ts` lines 29-40).

### 3.2 HTTP client for the probe and the token request (decided, not an open question)

**No HTTP client dependency exists in `mix.exs`** (`oidcc` itself has no HTTP-client
dependency of its own reachable from `mix.lock` beyond what OTP ships). Adding one
(`req`, `finch`, `httpoison`) purely for one excluded-by-default test file is not
warranted. **Decision: use Erlang/OTP's built-in `:httpc` (the `:inets` application),**
already present in every Elixir installation this project's toolchain requires — no new
`mix.exs` dependency. `test/support/keycloak_test_client.ex` (§4) is responsible for
calling `Application.ensure_all_started(:inets)` (idempotent, safe to call every time)
before issuing any `:httpc` request; `setup_all` calls this once via the client module,
not by duplicating `:inets`-startup logic inline in the test file.

Timeouts: both the discovery probe and the token-endpoint POST (§4) use a short,
explicit `:httpc` timeout (`{timeout: 2_000, connect_timeout: 1_000}` in the request's
`http_options`) — this is what turns "Keycloak is down" into a fast, clear skip instead
of ExUnit's own (much longer) default test timeout expiring mid-`setup_all`.

## 4. Genuine-token helper (test-support, not `lib/`)

**Placement decision (this project's ELIXIR-DEV/TEST-DESIGNER `lib/` vs.
`test/support/` boundary):** this helper exists solely to support the one
excluded-by-default integration suite this design adds. It is not consumed by any
production code path, not started under `Letflow.Application`'s supervision tree, and
has exactly the same "test-only, `elixirc_paths(:test)`, never referenced from `lib/`"
shape `test/support/tenant_fixture.ex`'s own moduledoc documents for itself. It
therefore belongs under `test/support/`, as **test-support code**, not as a new `lib/`
module — TEST-DESIGNER writes it (per WF-02 Step 3's `test/letflow/` **and**
`test/support/` scope), not ELIXIR-DEV.

### 4.1 `Letflow.Support.KeycloakTestClient`

```
@moduledoc "Test-only Keycloak HTTP client for REQ-134's real-token integration path. Not part of the shipped application."

@type token_error ::
        {:http_error, status :: pos_integer(), body :: String.t()}
        | {:transport_error, reason :: term()}
        | {:unexpected_response, term()}

@spec ensure_started() :: :ok
# Application.ensure_all_started(:inets) — idempotent, called at the top of
# discovery_reachable?/1 and direct_access_token/3 so callers never need to
# sequence this themselves.

@spec discovery_reachable?(discovery_url :: String.t()) :: boolean()
# GET discovery_url via :httpc with the short timeout from §3.2. true only on
# HTTP 200; false on any transport error, non-200 status, or timeout. Never
# raises -- a reachability probe that could raise would turn "Keycloak down"
# into a test *crash* in setup_all rather than the intended {:skip, _}.

@spec direct_access_token(
        token_url :: String.t(),
        username :: String.t(),
        password :: String.t(),
        opts :: [client_id: String.t()]
      ) :: {:ok, raw_token :: String.t()} | {:error, token_error()}
# POSTs a direct-access-grant (resource-owner-password) request to Keycloak's
# token endpoint: form-encoded body
# grant_type=password&client_id=<opts[:client_id]>&username=<username>&password=<password>,
# Content-Type application/x-www-form-urlencoded, via :httpc with the short
# timeout from §3.2. opts[:client_id] has no default in the @spec (always
# passed explicitly by the caller as "letflow-web", matching
# priv/keycloak/realms/bpm-default.json's public client -- see §5) so this
# module carries no realm-specific literal itself. On HTTP 200, decodes the
# JSON body via Jason.decode!/1 and returns {:ok, body["access_token"]}. Any
# non-200 status returns {:error, {:http_error, status, body}}; a transport
# failure (:httpc returning {:error, reason}) returns
# {:error, {:transport_error, reason}}; a 200 response whose body doesn't
# decode to a map with an "access_token" string key returns
# {:error, {:unexpected_response, decoded_or_raw}}.

@spec tamper_signature(raw_token :: String.t()) :: String.t()
# Splits raw_token on "." (JWT compact serialization: header.payload.signature),
# and returns the same header and payload segments with the signature segment
# replaced by a same-length string of a different base64url alphabet character
# repeated (e.g. mapping every non-"A" char to "A" and "A" to "B", so the
# result is guaranteed to differ from the original signature bit-for-bit while
# staying syntactically a three-segment JWT). Raises ArgumentError if
# raw_token does not have exactly 3 "."-separated segments (a defensive
# guard -- this helper must never silently hand back an unmodified or
# malformed token to AC2's assertion). This is the ONLY place this design
# introduces per-byte mutation logic; AuthPipeline/Oidcc verification is
# never touched.
```

No `@behaviour`, no GenServer — a plain stateless module of pure/IO functions, matching
`Letflow.TenantSchemaReaper`/`Letflow.TenantFixture`'s established `test/support/` shape
(module doc explicitly disclaiming supervision).

## 5. Fixture identity: the `bpm-default` tenant row (needed before any AC1-3 assertion)

`priv/keycloak/realms/bpm-default.json` seeds exactly one realm, `bpm-default`, with
four users (`admin-user`/`admin-pass` → `PLATFORM_ADMIN`, `designer-user`, `operator-user`,
`worker-user`) and one public client `letflow-web` (`directAccessGrantsEnabled: true`,
matching REQ-128's own AC — confirmed by reading the realm file directly, not assumed).
Every real token this test obtains therefore carries `"iss"` ending in
`/realms/bpm-default`, so `AuthPipeline.extract_realm/1` always resolves realm
`"bpm-default"` for this suite — there is no parameterization across realms here (unlike
`ConfigurableTokenVerifierDouble`'s multi-realm double, this test only ever needs one).

`Letflow.Identity.Tenant`'s `@default_tenant_slug "bpm-default"` pinning
(`lib/letflow/identity/tenant.ex`) requires a tenant row with `slug: "bpm-default"` to
also carry `idp_realm_id: "bpm-default"` exactly — this is the tenant `AuthPipeline`
must resolve via `resolve_tenant_by_realm("bpm-default")`. No migration or seed file
currently inserts this row (confirmed: `priv/repo/migrations/` and `priv/repo/seeds.exs`
both grepped, neither creates it), and `test/support/tenant_fixture.ex`'s
`provisioned_tenant!/1` cannot be reused as-is — it always generates a random
`Letflow.TenantSlugFixture.unique_slug/1`-based slug, never the literal `"bpm-default"`
the default-tenant pinning requires.

**Decided: `setup_all` provisions this tenant with a get-or-create pattern, not a
plain insert.** Because `slug` and `idp_realm_id` are both uniquely constrained and this
suite reasonably may be run more than once against the same long-lived `letflow_test`
database (it is excluded from the routine drop/recreate `mix.exs`'s `test` alias runs via
`ecto.create --quiet`/`ecto.migrate --quiet` — those don't drop existing data, they only
ensure the DB/migrations exist), a second run's plain insert would collision on the
unique index rather than reuse the existing row:

```
@spec ensure_bpm_default_tenant!() :: %{tenant_id: Ecto.UUID.t(), schema_name: String.t()}
# 1. Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto) -- same reason
#    test/support/tenant_fixture.ex sets this: TenantProvisioning's schema
#    provisioning/migration-replay steps run outside the calling test process's
#    sandboxed connection.
# 2. Repo.get_by(Tenant, slug: "bpm-default").
#    - If found: reuse it, and derive schema_name via
#      TenantProvisioning.schema_name_for_tenant(tenant.id) (assumed already
#      provisioned+migrated from a prior run -- confirmed by
#      TenantFixture.assert_schema_complete!/2 reused here, not skipped, so a
#      half-provisioned leftover from a crashed prior run is still caught).
#    - If not found: insert via
#      Tenant.create_changeset(%Tenant{}, %{slug: "bpm-default",
#      display_name: "Letflow Default Tenant", idp_realm_id: "bpm-default"},
#      :enabled) |> Repo.insert!(), then
#      TenantProvisioning.provision_tenant_schema/1 +
#      TenantProvisioning.replay_migrations/1, mirroring
#      TenantFixture.provisioned_tenant!/1's steps 4-6 exactly (§ Provisioning
#      steps of that module) but WITHOUT its on_exit teardown -- this fixture
#      is deliberately NOT torn down at the end of the run (next point).
# 3. TenantFixture.assert_schema_complete!(tenant.id) either way, so a
#    reused-but-corrupt row still fails loudly instead of silently.
```

**No teardown of the `bpm-default` tenant row or schema.** Unlike
`TenantFixture.provisioned_tenant!/1`'s per-test throwaway tenants, this fixture
represents Letflow's one pinned default tenant — the same row a real deployment would
have exactly once, permanently. Dropping it after each excluded-suite run would make
every second run redo full schema provisioning for no benefit and risks a drop racing a
concurrent developer's own manual use of the same `letflow_test` database. This is a
deliberate divergence from `TenantFixture`'s teardown convention, stated here rather
than silently copied.

**JIT-provisioning config for realm `bpm-default`:** already present in
`config/test.exs`'s `:oidc_jit_provisioning` map (`enabled: true`) — no config change
needed; `provision_oidc_user/4` will actually create a row (§7 AC3).

This tenant-provisioning helper lives in
`test/letflow/integration/keycloak_auth_pipeline_test.exs`'s own `setup_all` (private
function in the test module, not `KeycloakTestClient` — it is Repo/Ecto-shaped fixture
logic, not an HTTP client concern, matching `test/support/tenant_fixture.ex`'s existing
separation from any HTTP-facing test-support module).

## 6. Module shape

```
defmodule Letflow.Integration.KeycloakAuthPipelineTest do
  use ExUnit.Case, async: false
  @moduletag :keycloak
  ...
end
```

`async: false`: **required**, not a style choice — §7.1 below temporarily overrides
`Application.get_env(:letflow, :oidc)`'s `:token_verifier` key for the whole module,
which is process-global mutable state. Running this module concurrently with any other
`async: true` test that also calls `AuthPipeline` (indirectly reading the same config
key) would be a real race. `test/letflow/plugs/auth_pipeline_test.exs` runs under
`async: true` today and is unaffected, because `Application.put_env/3`/`delete_env`-style
overrides are scoped to this module's own `setup`/`on_exit` pair (§7.1) and restored
before this module's tests release control back to the runner — but the module itself
still must not run concurrently with anything else that could observe the intermediate
state, hence `async: false` here specifically.

Location: `test/letflow/integration/` is a new directory — no prior `test/letflow/
integration/` directory exists in this repo (confirmed by directory listing); this design
introduces it as the home for cross-cutting, real-infrastructure integration tests, as
opposed to `test/letflow/<context>/` per-module unit tests. Nothing else needs to move
into it as part of this requirement.

## 7. Assertions, mapped to acceptance criteria

### 7.1 Real-verifier override (shared setup, needed by AC1-3)

```
setup do
  original = Application.fetch_env!(:letflow, :oidc)
  real_oidc_config = Keyword.put(original, :token_verifier, Letflow.Oidc.TokenVerifier.Oidcc)
  Application.put_env(:letflow, :oidc, real_oidc_config)
  on_exit(fn -> Application.put_env(:letflow, :oidc, original) end)
  :ok
end
```

`Letflow.Application`'s already-running `Oidcc.ProviderConfiguration.Worker` (started
under `provider_name: Letflow.Oidc.DefaultProvider`, per `lib/letflow/application.ex`,
against the real local issuer `config/test.exs` already configures — see that file's own
comment, quoted in the background above) is reused as-is; this design does not start a
second worker. `AuthPipeline.verify_token/1` re-reads `Application.fetch_env!(:letflow,
:oidc)` on every call (confirmed in `lib/letflow/plugs/auth_pipeline.ex` — no caching), so
this `put_env` override takes effect on the very next `AuthPipeline.call/2` with no
additional wiring.

### 7.2 AC1 — genuine token drives the full pipeline (real assertion output required)

```
test "a genuine Keycloak token authenticates through AuthPipeline end to end" do
  %{tenant_id: tenant_id} = ensure_bpm_default_tenant!()
  {:ok, raw_token} =
    KeycloakTestClient.direct_access_token(token_url(), "admin-user", "admin-pass",
      client_id: "letflow-web"
    )

  conn =
    Plug.Test.conn(:get, "/", %{})
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_token)
    |> Letflow.Plugs.AuthPipeline.call([])

  refute conn.halted
  assert %{auth_context: %{tenant_id: ^tenant_id, user_id: user_id, roles: roles}} =
           conn.assigns
  assert is_binary(user_id)
  assert "PLATFORM_ADMIN" in roles
end
```

`Letflow.Plugs.AuthPipeline` only halts+responds on a rejected request (`reject/4`,
`lib/letflow/plugs/auth_pipeline.ex:322-329`) — a successful call returns the conn
un-halted with `:auth_context` assigned (`attach_auth_context/4`), never a 2xx status of
its own (this plug does not itself write a success response; downstream plugs do). So
"drives it through `AuthPipeline` end to end" is demonstrated by: `conn.halted == false`
and `conn.assigns.auth_context` populated with the expected shape — that is the concrete,
runnable assertion AC1 requires, and TEST-RUNNER quotes the real `mix test --include
keycloak ...` output showing this test passing (AC1's "real assertion output quoted").

### 7.3 AC2 — tampered token is rejected by the REAL verifier (not the double)

```
test "a token with a tampered signature is rejected by the real verifier" do
  {:ok, raw_token} =
    KeycloakTestClient.direct_access_token(token_url(), "admin-user", "admin-pass",
      client_id: "letflow-web"
    )
  tampered = KeycloakTestClient.tamper_signature(raw_token)

  conn =
    Plug.Test.conn(:get, "/", %{})
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> tampered)
    |> Letflow.Plugs.AuthPipeline.call([])

  assert conn.halted
  assert conn.status == 401
  assert %{"error" => "unauthorized"} = Jason.decode!(conn.resp_body)
end
```

This is the demonstration AC2 asks for: the SAME pipeline call as §7.2, with the SAME
`:token_verifier` override in effect (`Letflow.Oidc.TokenVerifier.Oidcc`, never
`TokenVerifierDouble` — `TokenVerifierDouble` has no concept of "tampered" at all, it
only recognizes one fixed sentinel string, so this test could not even be expressed
against the double), fails specifically because `Oidcc.Token.validate_jwt/3`'s real
signature check against the live JWKS rejects the mutated signature — proving the
signature-verification path is real and load-bearing, not a pass-through.

### 7.4 AC3 — JIT provisioning creates then reuses a real user row, across two calls

```
test "JIT provisioning creates a user row on first auth and reuses it on the second" do
  %{tenant_id: tenant_id, schema_name: schema_name} = ensure_bpm_default_tenant!()
  {:ok, raw_token} =
    KeycloakTestClient.direct_access_token(token_url(), "designer-user", "designer-pass",
      client_id: "letflow-web"
    )

  count_before =
    Letflow.Repo.aggregate(
      Ecto.Query.from(u in Letflow.Identity.User,
        where: u.external_realm == "bpm-default" and u.external_id == ^jwt_subject(raw_token)
      ),
      :count,
      prefix: schema_name
    )
  assert count_before == 0

  conn1 = authenticate(raw_token)
  refute conn1.halted
  user_id_1 = conn1.assigns.auth_context.user_id

  count_after_first =
    Letflow.Repo.aggregate(
      Ecto.Query.from(u in Letflow.Identity.User,
        where: u.external_realm == "bpm-default" and u.external_id == ^jwt_subject(raw_token)
      ),
      :count,
      prefix: schema_name
    )
  assert count_after_first == 1

  conn2 = authenticate(raw_token)
  refute conn2.halted
  user_id_2 = conn2.assigns.auth_context.user_id

  assert user_id_1 == user_id_2

  count_after_second =
    Letflow.Repo.aggregate(
      Ecto.Query.from(u in Letflow.Identity.User,
        where: u.external_realm == "bpm-default" and u.external_id == ^jwt_subject(raw_token)
      ),
      :count,
      prefix: schema_name
    )
  assert count_after_second == 1
end
```

`jwt_subject/1` (private helper in the test module): decodes the JWT's middle
(payload) base64url segment via `Base.url_decode64!(segment, padding: false)` and
`Jason.decode!/1`, reading `"sub"` — the same claim `Identity.provision_oidc_user/4`
upserts on (`(tenant_id, external_realm, external_id)`, `external_id` populated from
`identity_context`'s `subject`, which is the token's `"sub"` claim per
`AuthPipeline.map_claims/2`). Using `"designer-user"` here (not `"admin-user"`, already
consumed by §7.2/§7.3) keeps this test's user row independent of the other two tests'
JIT-provisioned rows, avoiding any cross-test ordering dependency within the module (both
still ultimately provision under the SAME `bpm-default` tenant/schema, which is why
`ensure_bpm_default_tenant!/0`'s get-or-create shape from §5 matters — a second test in
this module must reuse the same tenant row, not fail on a duplicate insert).

`authenticate/1` (shared private helper): the same three-line `Plug.Test.conn/3 |>
put_req_header |> AuthPipeline.call/2` sequence as §7.2/§7.3, extracted once.

The count-based before/1st/2nd assertions are the concrete "asserted across two calls"
AC3 requires: 0 → 1 → still 1, with `user_id_1 == user_id_2` as the direct row-identity
proof (not merely a matching count, which alone wouldn't rule out a delete+reinsert
pair).

## 8. Cross-check against `scripts/test_parallel.sh`'s partitioning contract

No change to that script (§2). The one thing worth confirming explicitly: because
`ExUnit.start(exclude: [:keycloak])` filters at suite-collection time, before Mix's
`--partitions N` splitting runs, the excluded module never occupies a partition slot in
any of the N parallel processes either — this is not merely "excluded from running," it
is excluded from the partition-assignment pool entirely, so it cannot skew load-balancing
across partitions.

## 9. Open questions

None. Every design element above resolves to a concrete signature, file, or exact
command string — no acceptance criterion is left as "TBD."

## 10. Acceptance-criteria cross-reference

| AC | Design element |
|---|---|
| 1 | §7.2 — real token via `KeycloakTestClient.direct_access_token/4`, driven through `AuthPipeline.call/2`, `conn.assigns.auth_context` assertion |
| 2 | §7.3 — `KeycloakTestClient.tamper_signature/1` + same pipeline call with `Letflow.Oidc.TokenVerifier.Oidcc` active (§7.1), asserts 401/halted |
| 3 | §7.4 — count-before/after-first/after-second + `user_id_1 == user_id_2` across two `authenticate/1` calls |
| 4 | §2 — `ExUnit.start(exclude: [:keycloak])` in `test/test_helper.exs`; TEST-RUNNER quotes `mix test`/`scripts/test_parallel.sh` output with Keycloak stopped |
| 5 | §3.1 — `setup_all`'s `{:skip, message}` with the exact quoted message text |
| 6 | §2 — `mix test --include keycloak test/letflow/integration/keycloak_auth_pipeline_test.exs`, stated verbatim in this design and to be restated in the eventual result |
