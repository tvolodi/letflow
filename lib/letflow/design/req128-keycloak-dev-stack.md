# REQ-128 — Keycloak in the dev stack, real issuer, five-role realm

Status: design. Owner: ELIXIR-DEV. Gated by CODE-DESIGN-VALIDATOR before implementation.

## Problem

`docs/migration/stage-1-identity.md`'s "What S1 deferred" section: no identity
provider exists anywhere in this system. `config/dev.exs`/`config/test.exs` point
`Oidcc.ProviderConfiguration.Worker` at `https://placeholder-keycloak.invalid/...`,
which retries forever (`backoff_type: :random`) and never becomes ready. No test
in this repo has ever exercised a real token.

## Scope

1. Add a `keycloak` service to `docker-compose.yml` (S1-only concern: dev/test
   convenience, not a production deployment artefact — `config/prod.exs` is
   untouched).
2. Add a tracked realm-import file, `priv/keycloak/realms/letflow-default.json`,
   imported via `start-dev --import-realm`.
3. Point `config/dev.exs` and `config/test.exs`'s `:oidc` issuer at the real
   local Keycloak (`http://localhost:${port}/realms/letflow-default`).
4. `config/test.exs` keeps `token_verifier: Letflow.Oidc.TokenVerifierDouble` —
   REQ-128 does not touch the test doubles; ExUnit still runs with no real
   Keycloak reachable, only the issuer string changes so
   `Oidcc.ProviderConfiguration.Worker` has something real to resolve
   discovery against when Keycloak happens to be up. `config/prod.exs`
   unchanged — a real production issuer is a deployment concern (README
   "Migration status": no production deployment exists yet), and inventing one
   here would put a fictional hostname in a file that reads as authoritative.

## Not in scope

- Per-tenant realm provisioning (REQ-135).
- Any nginx/gateway layer — R-Co fronts Keycloak with nginx solely to raise
  `large_client_header_buffers` past 8k for large service-account JWTs. Letflow
  exposes Keycloak directly; revisit only if a real 400 from an oversized
  header appears.
- Any change to `Letflow.Oidc.ClaimMapping`, `Letflow.Api.Authorization`, or
  the SPA — the realm is shaped to match what those modules already expect
  (`roles_claim_paths: ["realm_access.roles", "roles"]` already accepts a flat
  `roles` claim; `Letflow.Api.Authorization.role/0` already has all five
  roles).

## docker-compose.yml addition

```yaml
  keycloak:
    image: quay.io/keycloak/keycloak:26.2
    command: ["start-dev", "--import-realm"]
    environment:
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
      KC_HEALTH_ENABLED: "true"
      KC_HTTP_MANAGEMENT_HEALTH_ENABLED: "false"
    ports:
      # Host port is per-workspace, not global -- same pattern as postgres
      # above (LETFLOW_DB_PORT). Default 8082: R-Co's stack uses 8081 for its
      # nginx-fronted Keycloak gateway (docker-compose.yml:26) and 5432/5433
      # for postgres, so 8082 avoids all three. A workspace running its own
      # instance alongside another sets LETFLOW_KEYCLOAK_PORT in the
      # untracked .env next to this file.
      - "${LETFLOW_KEYCLOAK_PORT:-8082}:8080"
    volumes:
      - ./priv/keycloak/realms:/opt/keycloak/data/import:ro
    healthcheck:
      test: ["CMD-SHELL", "echo > /dev/tcp/127.0.0.1/8080"]
      interval: 5s
      timeout: 5s
      retries: 20
```

No nginx service. No `expose`-only hiding of the port — Letflow's Router talks
to Keycloak over `http://localhost:<port>` directly via `Oidcc`, same as any
dev client would.

## `config/keycloak_port.exs` (new, mirrors `config/db_port.exs`)

Same three-tier precedence (`LETFLOW_KEYCLOAK_PORT` env → `.env` file →
`8082` default), evaluated via `Code.eval_file/1` from `config/dev.exs` and
`config/test.exs`, exactly matching `db_port.exs`'s existing shape (including
its integer-parse guard and error message). Not a new abstraction — same
existing pattern, second instance.

## `config/dev.exs` / `config/test.exs` changes

Replace:
```elixir
config :letflow, :oidc,
  issuer: "https://placeholder-keycloak.invalid/realms/bpm-default",
  ...
```
with:
```elixir
{keycloak_port, _bindings} = Code.eval_file(Path.expand("keycloak_port.exs", __DIR__))

config :letflow, :oidc,
  issuer: "http://localhost:#{keycloak_port}/realms/letflow-default",
  provider_name: Letflow.Oidc.DefaultProvider,
  client_id: "letflow-web",
  signing_algs: ["RS256"],
  token_verifier: Letflow.Oidc.TokenVerifier.Oidcc  # dev; test.exs keeps TokenVerifierDouble
```

`config/dev.exs` and `config/test.exs`'s `:oidc_claim_mapping` map's key
changes from `"bpm-default"` to `"letflow-default"` (must match the realm
name used for claim-mapping lookup — `Letflow.Oidc.ClaimMappingConfig.for_realm/1`
keys off the realm, and the realm name IS the new value) — same for
`:oidc_jit_provisioning`'s key. Everything else under those two keys is
unchanged (`roles_claim_paths: ["realm_access.roles", "roles"]` already
covers a flat `roles` claim).

`config/prod.exs`: **unchanged, no edit**. Left with its own placeholder
issuer, per the requirement's explicit instruction and this doc's Scope
section above.

## Realm file: `priv/keycloak/realms/letflow-default.json`

Modeled on R-Co's `bpm-default.json`, corrected per `docs/migration/decisions/0013-authorization-role-set.md`:

- `realm`: `letflow-default` (not `bpm-default` — this is a Letflow-owned
  fixture, not an R-Co copy, and the name change also makes "did the port
  forget to update this file" impossible to miss).
- `roles.realm`: **five** entries — `PLATFORM_ADMIN`, `PROCESS_DESIGNER`,
  `PROCESS_OPERATOR`, `TASK_WORKER`, `AGENT_RUNNER` — matching
  `Letflow.Api.Authorization.role/0` exactly.
- One public client, `letflow-web` (matches `config/dev.exs`'s new
  `client_id`), `standardFlowEnabled: true`, `directAccessGrantsEnabled: true`
  (needed to mint a password-grant token for verification without a browser),
  with the required protocol mapper:
  ```json
  {
    "name": "realm-roles",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-realm-role-mapper",
    "consentRequired": false,
    "config": {
      "multivalued": "true",
      "userinfo.token.claim": "true",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "roles",
      "jsonType.label": "String"
    }
  }
  ```
  This is the mapper the requirement calls non-optional — without it the SPA
  gets zero roles silently. No audience mapper is added (R-Co's exists for its
  own resource-server client id check, which Letflow's `Oidcc`-based
  `TokenVerifier.Oidcc` does not require; adding one unasked would be scope
  creep — flag only, don't add).
- Users seeded, one per role for dev convenience (matches R-Co's shape) —
  **`operator-user` holds `PROCESS_OPERATOR`, not `PLATFORM_ADMIN`**. This is
  the one deliberate content difference from R-Co beyond the role list itself,
  and it is the crux of decision 0013: R-Co's `operator-user` @
  `realmRoles: ["PLATFORM_ADMIN"]` must NOT be carried across.
  - `admin-user` → `PLATFORM_ADMIN`
  - `designer-user` → `PROCESS_DESIGNER`
  - `operator-user` → `PROCESS_OPERATOR`
  - `worker-user` → `TASK_WORKER`
  - No seeded human user holds `AGENT_RUNNER` — decision 0013's Consequences
    section is explicit that it's a machine role with no human seed, same as
    R-Co's fixture seeds no `AGENT_RUNNER` user either.

## Verification plan (executed by ELIXIR-DEV post-implementation, evidenced in the handoff — not a new test suite; TEST-DESIGNER's scope below is narrower)

1. `docker compose up -d keycloak` (plus `postgres`, since the compose file
   has no default depends_on wiring across them) → poll
   `docker compose ps`/`docker inspect --format='{{json .State.Health}}'`
   until `healthy`, quote it.
2. `curl -s http://localhost:$PORT/realms/letflow-default/.well-known/openid-configuration`
   → quote the fetched JSON (or at least `issuer` field) proving reachability.
3. Keycloak Admin REST API (`/admin/realms/letflow-default/roles`, bearer
   token from `admin-cli` password grant against the `master` realm) → quote
   the five role names read back.
4. `/admin/realms/letflow-default/users?username=operator-user` then
   `/role-mappings/realm` for that user id → quote the single role,
   `PROCESS_OPERATOR`.
5. Password-grant a token for `operator-user` against `letflow-web`
   (`direct_access_grants`), decode the JWT payload (base64), quote it,
   confirming a flat top-level `roles` array.
6. Start the app (`iex -S mix` or equivalent) with `config/dev.exs`'s new
   issuer active and Keycloak running, inspect
   `Oidcc.ProviderConfiguration.Worker`'s process state / call
   `Oidcc.ProviderConfiguration.Worker.get_provider_configuration/1` to show
   it resolved discovery instead of retrying.

## Test-designer scope (after security/idiom gates)

No new `lib/letflow/` runtime logic is introduced by this requirement — it is
config, a static JSON fixture, and a compose service. TEST-DESIGNER's job here
is narrower than usual: add a `config/keycloak_port.exs`-parity unit test
(mirroring however `db_port.exs` is or isn't tested today — check first, match
it) and, if this repo has any existing docker/integration-tagged test
convention, a smoke test gated behind that tag that fetches the discovery
document when Keycloak is reachable and is a no-op skip otherwise (must not
break `mix test`/`scripts/test_parallel.sh` in CI/sandboxes with no Docker).
Do not invent a docker-in-CI dependency where none exists today.

## Correction after CODE-DESIGN-VALIDATOR PASS (implementation-time, 2026-08-22)

The design as validated proposed renaming the realm from `bpm-default` to
`letflow-default`. During implementation this turned out to be wrong:
`bpm-default` is not merely the OIDC placeholder's realm segment, it is a
**pinned domain invariant**. `Letflow.Identity.Tenant.@default_tenant_slug`
is the literal string `"bpm-default"`, and `create_changeset/3` additionally
pins the default tenant's `idp_realm_id` to equal `"bpm-default"` exactly
(see that module and `lib/letflow/design/req019-tenant-realm-binding.md`).
Dozens of existing tests (`identity_test.exs`, `claim_mapping_test.exs`,
`jit_provisioning_config_test.exs`, `auth_pipeline_test.exs`,
`auth_pipeline_configurable_verifier_test.exs`,
`api_pipeline_integration_test.exs`, `test/support/token_verifier_double.ex`,
`test/support/configurable_token_verifier_double.ex`) hardcode
`"bpm-default"` as the realm under test, matching that pinning. Renaming the
realm would have silently orphaned `config/dev.exs`/`config/test.exs`'s
`:oidc_claim_mapping`/`:oidc_jit_provisioning` entries from every one of
those fixtures (falling back silently to `ClaimMappingConfig.default/1`/
`JitProvisioningConfig.default/1` instead) without touching a single test
file — exactly the kind of "silently re-decide a settled invariant" this
project's core-directives forbid.

**Correction actually implemented:** the realm keeps the name `bpm-default`
throughout — `priv/keycloak/realms/bpm-default.json` (`"realm":
"bpm-default"`), `config/dev.exs`/`config/test.exs`'s issuer
`http://localhost:<port>/realms/bpm-default`, and both
`:oidc_claim_mapping` and `:oidc_jit_provisioning` keep their existing
`"bpm-default"` key unchanged. Only the client id changed, to `letflow-web`
(not pinned anywhere, safe to name freely), and the five-role/operator-role
content of the realm file, which is the actual substance of decision 0013.
No other part of this design changed; the verification plan above still
applies with `bpm-default` in place of `letflow-default` wherever it
appeared.

## Correction after ISS-0275 (2026-08-22)

This design's "Realm file" section above states:

> This is the mapper the requirement calls non-optional — without it the SPA
> gets zero roles silently. No audience mapper is added (R-Co's exists for its
> own resource-server client id check, which Letflow's `Oidcc`-based
> `TokenVerifier.Oidcc` does not require; adding one unasked would be scope
> creep — flag only, don't add).

That "No audience mapper is added ... does not require" sentence is
**factually wrong** and is superseded by this fix. It was written on the
(unverified) assumption that `Oidcc`'s token validation does not check `aud`;
the opposite is true — `Oidcc.Token.validate_jwt/3`
(`deps/oidcc/src/oidcc_token.erl`) unconditionally requires `aud` to contain
the configured `client_id`, with no configuration flag to disable the check.
This was not a deliberate library behavior this project chose to route
around; it was an unverified claim about a dependency's behavior that turned
out false the first time a real Keycloak-issued token was checked
(ISS-0275). R-Co's own audience mapper existing for a *different* reason
(its own resource-server client id check) does not mean Letflow's
`Oidcc`-based verifier has no such requirement of its own — it does,
independently, and this project's realm fixture needs the mapper regardless
of R-Co's original reason for having one.

**Correction actually implemented:** a mapper of type `oidc-audience-mapper`
now exists on `letflow-web`, named `letflow-web-audience`, appended after
the existing `realm-roles` mapper in `priv/keycloak/realms/bpm-default.json`.
See `lib/letflow/design/iss0275-audience-mapper-fix.md` §2 for the exact
JSON and field-by-field rationale, rather than duplicating it here.

No other part of this design changes — this is an addendum note, not a
rewrite; the realm name (`bpm-default`, per the "Correction after
CODE-DESIGN-VALIDATOR PASS" section above), the five roles, the four seeded
users, and the `realm-roles` mapper all stand as already documented.
