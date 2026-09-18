# Design: REQ-370 — Multi-issuer OIDC token verification

**Requirement:** REQ-370 (`docs/requirements.yaml`, SECURITY-CRITICAL)
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the changed `Letflow.Oidc.TokenVerifier` callback contract
and both implementations' `@spec`s, the new `Letflow.Oidc.ProviderRegistry` module
(per-realm supervised-worker lifecycle) and its `@spec`s, the fate of `config/runtime.exs`'s
`:oidc, :issuer`, and a decision-record verdict. No implementation code — signatures and
shapes only.

## 0. Sources read for this design

- REQ-370's full requirement text (`docs/requirements.yaml`), especially its ROOT CAUSE
  and SCOPE sections — cited, not re-derived. `docs/issues/ISS-0690.yaml`'s `followup_2`
  block (`checked_by: ISSUE-FIXER`, `2026-09-18T14:35:00Z`) — the live-confirmed 401
  result and its root-cause trace, cited verbatim, not re-executed.
- `lib/letflow/oidc/token_verifier.ex`, `lib/letflow/oidc/token_verifier/oidcc.ex` (current
  callback + real adapter, full files).
- `lib/letflow/supervisor/infrastructure.ex` (current single static
  `{Oidcc.ProviderConfiguration.Worker, %{issuer: ..., name: ...}}` child spec, child #3 of
  19).
- `config/runtime.exs`, `config/dev.exs`, `config/prod.exs`, `config/test.exs` — every
  `:oidc` config-key site.
- `lib/letflow/plugs/auth_pipeline.ex` (full file) — confirms step 1 (`verify_token/1`) is
  the only call site of the `TokenVerifier` behaviour; steps 2-6 are untouched by this
  design, exactly per REQ-370's stated out-of-scope.
- `lib/letflow/identity.ex` — `resolve_tenant_by_realm/1` (`Repo.get_by(Tenant,
  idp_realm_id: idp_realm_id)` → `{:ok, Tenant.t()} | {:error, :not_found}`), already
  `done` (REQ-019), reused as-is by this design — no change to its own signature.
- `lib/letflow/design/req019-tenant-realm-binding.md` (full file) — confirms
  `idp_realm_id` is create-time-only/immutable via `update_changeset/2`'s structural field
  omission (§3.1/§3.3), confirms the `tenants_idp_realm_id_partial_index` partial unique
  index already enforces one-to-one binding, and confirms (its own OQ-3) that **no
  `priv/repo/seeds.exs` and no real default-tenant row exists anywhere in this codebase
  today** — load-bearing for §5 below.
- `docs/migration/decisions/0002-oidc-integration.md` — confirms multi-issuer supervision
  was explicitly **foreshadowed, not ruled out**, at decision time: "if/when
  `ueberauth_oidcc` is wired in, `Oidcc.ProviderConfiguration.Worker` needs a supervised
  child spec... likely one per configured realm/issuer, given the per-realm JIT config
  invariant" (§ "Deferred to S1 execution"). Load-bearing for §7's decision-record verdict.
- `docs/agents/instructions/security-invariants.md` INV-1, INV-7, INV-8 — assessed
  explicitly in §9.
- `deps/oidcc/lib/oidcc/client_context.ex` (`from_configuration_worker/4`'s real `@spec`:
  `provider_name :: GenServer.name()` — confirmed this accepts any valid OTP name form,
  not only a bare atom).
- `deps/oidcc/lib/oidcc/provider_configuration/worker.ex` (`start_link/1`'s real clauses:
  when `opts[:name]` is an atom it's wrapped `{:local, name}`; any other name value —
  including a `{:via, Registry, _}` tuple — is passed through unchanged to
  `:oidcc_provider_configuration_worker.start_link/1`, which is a plain `gen_server`
  start accepting the full `GenServer.name()` union). **Confirms `{:via, Registry, _}`
  naming is directly supported by the installed `oidcc` 3.9.0** — not an assumption.
- `deps/jose/lib/jose/jwt.ex` (`peek_payload/1`, `@spec peek_payload(binary()) :: t()`) —
  confirms an already-vendored, signature-**not**-checked JWT-payload peek exists via
  `:jose` (an existing transitive dependency of `oidcc`), so no new dependency is needed
  for the "read the claimed issuer before trusting it" step REQ-370 point 1 requires.
- `test/support/token_verifier_double.ex`, `config/test.exs`/`config/dev.exs` — confirms
  the test double and the `:provider_name` config key's current shape (both change, §3/§6).
- `test/letflow/router_test.exs` (REQ-071 AC3, `Letflow.Oidc.DefaultProvider` liveness
  test) and `test/letflow/integration/keycloak_auth_pipeline_test.exs` (line 383,
  `Keyword.fetch!(oidc_config, :provider_name)`) — both are existing tests that hardcode
  the single-static-provider-name assumption this design removes; flagged as impacted
  files for TEST-DESIGNER (§10), not edited by this design.
- Confirmed: `Letflow.Registry` (a plain `Registry, keys: :unique`) already exists as
  infrastructure child #4 — reused by this design for realm→pid naming rather than
  starting a second `Registry` process (§4.2).

## 1. Problem restated (no re-derivation of ISS-0690's diagnosis)

`Letflow.Oidc.TokenVerifier.verify_bearer_token/2`'s current contract verifies every
incoming JWT against exactly one supervised `Oidcc.ProviderConfiguration.Worker`,
registered under one static name, configured from one static `:oidc, :issuer` value. A
token whose `iss` claims any other realm — including a real tenant's own bound realm —
fails signature verification outright (wrong JWKS) and is rejected 401, before tenant
resolution ever runs. This is documented, shipped-knowingly behavior (REQ-016/REQ-019),
not a defect (§0's citations). REQ-370 commits to option (b) from ISS-0690's
`followup_2.next_action`: dynamic/multi-issuer verification within one deployment,
resolved from the `tenants` table's already-existing `idp_realm_id` column — never a
wildcard, never "accept any issuer."

## 2. Trust model (governs every decision below)

**The `tenants` table is the sole source of truth for which issuers are trusted.** A
token is admitted only if:

1. its (as-yet-unverified) `iss` claim's realm segment matches some tenant row's
   `idp_realm_id`, **and**
2. its signature verifies against that specific realm's own Keycloak JWKS.

Check 1 must run **before** check 2 trusts anything about the claim (REQ-370 point 1's
explicit ordering: "before trusting the claimed issuer's signature, since the claim
itself is exactly what verification must not blindly trust"). Concretely: the realm named
in an unverified `iss` claim is used only to decide **which** issuer's JWKS to verify
against — it is never treated as proof of tenant identity by itself. Real tenant identity
is established only after step 2 succeeds, and only via the *verified* claims map handed
back to `Letflow.Plugs.AuthPipeline`'s step 2 (`extract_realm/1` → `resolve_tenant/1`),
unchanged by this design.

Check 1 is re-run **fresh, from the database, on every single verification call** — never
cached as a permanent "this realm is trusted" fact. This is the mechanism (not a
side-effect) that makes AC5 (revocation) hold: even if a per-realm `Oidcc.ProviderConfiguration.Worker`
process is still alive in memory for a realm whose `idp_realm_id` binding has since been
removed, the fresh tenant-lookup gate in front of it rejects before that worker is ever
consulted. Worker liveness is purely a JWKS-fetch performance cache; it carries no trust
decision. See §4.3 for exactly why this decouples cleanly.

## 3. `Letflow.Oidc.TokenVerifier` — new callback contract

```
@type claims :: %{optional(String.t()) => term()}

@type verify_error ::
        :malformed_token
        | :untrusted_issuer
        | {:verifier_crashed, %{kind: :error | :exit | :throw, classification: module() | atom()}}
        | term()

@callback verify_bearer_token(raw_token :: String.t()) ::
            {:ok, claims()} | {:error, verify_error()}
```

**Change from the current contract:** arity drops from 2 to 1 — `provider_name` is
**removed** as a caller-supplied argument. The old contract let the caller (`AuthPipeline`)
tell the verifier which single provider to check against, because there was only ever one.
Under multi-issuer verification, *which* provider to check against is itself something
only the verifier can determine — by peeking the token's own claimed issuer and resolving
it against the tenants table (§2) — so it can no longer be a caller-supplied parameter.
Pushing that resolution into the verifier is also what correctly localizes "must not
blindly trust the claimed issuer" as the verifier's own internal responsibility, not
something `AuthPipeline` needs to know about.

**New error atom: `:untrusted_issuer`.** Returned when the claimed realm resolves to no
tenant row (AC4) or no longer resolves to one (AC5) — distinct from `:malformed_token`
(the raw string isn't a parseable JWT at all) and from a genuine signature/expiry
verification failure. `Letflow.Plugs.AuthPipeline.handle_auth_error/2`'s existing
`{:error, {:verify, _reason}}` clause already collapses **every** verifier error to the
same 401 `"invalid or expired bearer token"` body regardless of which specific reason
fired (§0, current `auth_pipeline.ex` lines 156-157) — so `:untrusted_issuer` requires
**no change** to `handle_auth_error/2`'s anti-oracle behavior; it is just one more value
that same catch-all clause already handles identically to every other verify failure. This
is stated explicitly so ELIXIR-DEV does not feel compelled to add a new `handle_auth_error/2`
clause — none is needed or wanted (a distinct HTTP-visible message here would itself leak
which realms exist, an oracle this design must not introduce).

**Call-site change (in scope, not a steps-2-6 change):** `AuthPipeline`'s private
`verify_token/1` (lines 245-254) currently reads `provider_name` from `:oidc` config and
passes it as the verifier's second argument. It must be updated to call
`verifier.verify_bearer_token(raw_token)` (one argument) instead. This is purely
adapting step 1's call arity to the new callback contract — it does not touch step 1's
place in the pipeline, nor steps 2-6's own logic/order, which REQ-370 explicitly leaves
untouched.

## 4. `Letflow.Oidc.ProviderRegistry` — new module, per-realm worker supervision

### 4.1 Responsibility

Owns the lifecycle of one `Oidcc.ProviderConfiguration.Worker` per **trusted** realm,
started lazily (on first verification attempt against that realm) rather than
enumerated eagerly at boot. A `DynamicSupervisor` (not a fixed child list) because the
trusted-realm set is exactly the `tenants` table's current contents, which changes at
runtime as tenants are created — a fixed `Supervisor` child list, computed once at
`Letflow.Application` boot, could not include a tenant created afterward without a
restart, which is precisely the requirement REQ-370 point 2 asks CODE-DESIGNER to close.

**Why lazy-on-demand, not "enumerate `tenants` and eager-start one worker per row at
`init/1`":**

1. It trivially satisfies "a newly created tenant's realm becomes verifiable without a
   full application restart" **by construction** — the very next verification attempt
   against that realm calls `ensure_started/1`, which is the same function every prior
   verification attempt already calls. No tenant-creation call site needs to be hooked at
   all; `Letflow.Identity`'s tenant-creation path (wherever REQ-3xx onboarding wires it)
   needs **zero changes** for this requirement.
2. It matches this supervisor's own established precedent of not reading the DB inside
   `init/1` — `Letflow.Admission`'s and `Letflow.Engine.Wasm.InvocationLease`'s own
   moduledocs (cited in `infrastructure.ex`, §0) both state "init/1 reads only static
   application config, makes no Repo call" as their placement justification; this design
   follows the same discipline rather than introducing the first DB-reading `init/1` in
   this supervisor.
3. A worker that fails to start because a realm's Keycloak discovery endpoint is
   unreachable (e.g. mid-outage) does not block every *other* realm's login, nor does it
   retry-loop forever inside a fixed child spec the way an eager `init/1` failure would
   affect the whole supervisor's boot sequence.

**Trade-off named explicitly, not hidden:** the very first request against a freshly
created tenant's realm pays the cost of a fresh OIDC-discovery + JWKS fetch inline (no
warm cache) — the same first-use latency `Oidcc.ProviderConfiguration.Worker` already
has for the single-provider case today (its own moduledoc: "fetches provider metadata and
JWKS on first use"). This is not a regression relative to today's behavior, just now paid
per-realm instead of once globally. No pre-warming is built.

### 4.2 Supervision + naming shape

- `Letflow.Oidc.ProviderRegistry` is a `DynamicSupervisor`, `strategy: :one_for_one`,
  started as `Letflow.Supervisor.Infrastructure`'s child #3, in the exact list position the
  current static `{Oidcc.ProviderConfiguration.Worker, ...}` child spec occupies today —
  no other child's relative order changes.
- Each per-realm `Oidcc.ProviderConfiguration.Worker` is registered under
  `{:via, Registry, {Letflow.Registry, {:oidc_provider, realm}}}` — **reusing** the
  already-supervised generic `Letflow.Registry` (infrastructure child #4) for name
  registration, rather than starting a second `Registry` process. `{:oidc_provider, realm}`
  is a two-element tuple key (namespaced, so no collision with any other current or future
  use of `Letflow.Registry` keyed by a bare string).
- Confirmed directly against the vendored `oidcc` 3.9.0 source (§0): a `{:via, Registry,
  _}` name is accepted unchanged by both `Oidcc.ProviderConfiguration.Worker.start_link/1`
  (only a bare-atom `:name` gets special-cased to `{:local, name}`; every other name form,
  via-tuples included, passes straight through) and by
  `Oidcc.ClientContext.from_configuration_worker/4` (`provider_name :: GenServer.name()`,
  which the via-tuple type satisfies). No oidcc-internal change or workaround needed.

```
@type realm :: String.t()
@type provider_ref :: {:via, Registry, {Letflow.Registry, {:oidc_provider, realm()}}}

@spec start_link(term()) :: Supervisor.on_start()
def start_link(init_arg)

@doc """
Idempotently ensures a running, JWKS-fetching provider worker exists for `realm`,
after first confirming a tenant row is actually bound to it (§2 — the trust check
that must precede any worker start or reuse).
"""
@spec ensure_started(realm()) ::
        {:ok, provider_ref()} | {:error, :unknown_realm | term()}
def ensure_started(realm)

@doc """
Pure name construction — no process lookup, no I/O. Exposed so
`Letflow.Oidc.TokenVerifier.Oidcc` (and tests) can compute the same via-tuple a prior
`ensure_started/1` call registered a worker under, without duplicating the tuple shape.
"""
@spec via_name(realm()) :: provider_ref()
def via_name(realm)
```

`ensure_started/1`'s internal steps (behavior, not code):

1. `Letflow.Identity.resolve_tenant_by_realm(realm)` — the exact, unchanged, already-`done`
   REQ-019 function. `{:error, :not_found}` → `{:error, :unknown_realm}`, **no worker
   start attempted** (this is the trust gate itself, §2).
2. `{:ok, _tenant}` → check whether `via_name(realm)`'s Registry entry already resolves to
   a live pid. If yes, return `{:ok, via_name(realm)}` immediately (cache hit — no new
   worker, no new DB write).
3. If no live entry: compute `issuer = "#{keycloak_base_url()}/realms/#{realm}"` (§6) and
   `DynamicSupervisor.start_child/2` a `{Oidcc.ProviderConfiguration.Worker, %{issuer:
   issuer, name: via_name(realm), backoff_type: :random, provider_configuration_opts:
   %{quirks: %{allow_unsafe_http: ...}}}}` — the same options shape
   `infrastructure.ex`'s current single child spec already uses (§0), just parameterized
   by `realm`/`issuer` instead of hardcoded.
4. A `{:error, {:already_started, _pid}}` race (two concurrent first-requests for the same
   brand-new realm) is treated as success — re-resolve and return `{:ok, via_name(realm)}`,
   not an error. Any other `start_child/2` error (e.g. discovery genuinely unreachable)
   propagates as `{:error, reason}`.

**Not built by this design:** no `stop_provider/1`/teardown function. A worker for a realm
whose tenant row is later deleted is simply never reached again (§2's trust gate blocks it
upstream) and lingers as an idle process holding a stale JWKS cache until the node
restarts. This is a deliberate, bounded resource trade-off (one idle GenServer + one ETS
JWKS table per ever-registered realm, for the life of the node) rather than added teardown
complexity for a case (tenant deletion) no current acceptance criterion exercises removing
cleanly — **flagged explicitly as OQ-1 (§8)**, not silently decided as "obviously fine,"
since an operator that creates and deletes many tenants over a long-lived node's lifetime
could accumulate idle workers. No `done`/`pending` requirement currently defines tenant
deletion at all, so there is no concrete trigger to hook a teardown into yet.

### 4.3 Why AC5 (revocation) does not require any worker-teardown mechanism

AC5 asks for a test proving that revoking/removing a tenant's `idp_realm_id` binding
causes subsequent tokens from that realm to be rejected. Given §2's fresh-per-call trust
gate (step 1 of `ensure_started/1`, run unconditionally before any cached worker is ever
reused), this holds **regardless of §4.2's "no teardown" decision**: removing/nulling the
`idp_realm_id → tenant` mapping makes `resolve_tenant_by_realm/1` return `{:error,
:not_found}` on the very next call, which `ensure_started/1` turns into `{:error,
:unknown_realm}` before it ever looks at whether a live worker process still exists for
that realm. The worker's continued liveness is irrelevant to the outcome. This is why §4.2
can defer worker teardown as an open question without weakening AC5 — the two concerns
(trust-gating and worker-caching) are independent by construction.

**Caveat named explicitly for TEST-DESIGNER (§10):** because REQ-019's `update_changeset/2`
structurally omits `:idp_realm_id` from its `cast/3` fields (immutable-after-creation,
§0's citation), there is **no application-level "revoke a binding" function to call** in
this codebase today. AC5's test must simulate revocation by a mechanism REQ-019's design
did not anticipate a caller needing — e.g. deleting the tenant row outright
(`Repo.delete/1`), or a direct `Repo.update_all`/raw struct update bypassing
`update_changeset/2` for test purposes only, never through any public `Letflow.Identity`
function (none exists, and this design does not add one — adding a real admin-facing
"revoke realm binding" operation is out of REQ-370's scope, which is verification, not
tenant-administration). This is flagged as **OQ-2 (§8)** for REVIEWER: is a
test bypassing `update_changeset/2`'s immutability guard (via direct `Repo` manipulation,
not through any public API) an acceptable way to satisfy AC5, or does AC5 imply a real
"unbind realm" admin operation this requirement should also add? This design's own
reading of REQ-370's text ("teach the token-verification layer to look up..." — scoped to
verification, not tenant administration) is that the former (test-only DB manipulation) is
correct and sufficient, but it is stated as a judgment call, not silently assumed.

## 5. `Letflow.Oidc.TokenVerifier.Oidcc` — real adapter, new shape

```
@spec verify_bearer_token(raw_token :: String.t()) ::
        {:ok, claims :: %{optional(String.t()) => term()}} | {:error, verify_error()}
def verify_bearer_token(raw_token) when is_binary(raw_token)
```

Behavior, in order (replacing the current single `with` chain):

1. **Unverified peek.** `JOSE.JWT.peek_payload(raw_token)` (§0 — already-vendored via the
   `:jose` transitive dependency, no new dep). Wrapped in the same `rescue`/`catch`
   boundary the current implementation already has (§0, lines 59-82) — a garbage/
   non-JWT-shaped `raw_token` crashes `peek_payload/1` internally; caught here exactly as
   today's implementation already catches every other crash, classified and returned as
   `{:error, {:verifier_crashed, ...}}` (not the new `:malformed_token` atom — reserved
   for a case §5's own logic detects structurally, e.g. a payload that decodes but has no
   `"iss"` string field at all, distinct from "the whole token isn't parseable JWT shape,"
   which stays a crash-boundary case for consistency with the existing crash-handling
   policy).
2. **Extract realm from the unverified `iss`.** Same `"/realms/"`-suffix parse
   `AuthPipeline.extract_realm/1` already performs on *verified* claims (§0) — this design
   does **not** duplicate that as a new shared helper; it is a small, independent parse
   performed here on the *unverified* payload, for the sole purpose of selecting which
   provider to verify against. A malformed/missing `"iss"`, or an `iss` with no
   `"/realms/<realm>"` suffix → `{:error, :malformed_token}`.
3. **Resolve the provider.** `Letflow.Oidc.ProviderRegistry.ensure_started(realm)`.
   `{:error, :unknown_realm}` → `{:error, :untrusted_issuer}` (the new callback contract's
   dedicated atom, §3). Any other `ensure_started/1` error (a genuine JWKS-fetch/discovery
   failure for a realm that IS trusted) propagates as `{:error, reason}` — distinguishable
   internally from `:untrusted_issuer` for logging, even though `AuthPipeline`'s
   `handle_auth_error/2` still collapses both to the same 401 body (§3).
4. **Verify the signature.** Exactly as today (§0, current lines 49-58): `with {:ok,
   client_context} <- Oidcc.ClientContext.from_configuration_worker(provider_ref,
   client_id, :unauthenticated), {:ok, claims} <- Oidcc.Token.validate_jwt(raw_token,
   client_context, %{signing_algs: signing_algs}) do {:ok, claims} end` — `provider_ref`
   here is step 3's returned via-tuple, not a config-read atom. `client_id`/`signing_algs`
   still come from `Application.fetch_env!(:letflow, :oidc)` unchanged (§6 — these two
   config keys are untouched by this design). `oidcc`'s own `validate_jwt/3` independently
   re-validates the token's `iss` claim against the specific worker's own configured
   issuer as part of standard OIDC validation — this is `oidcc`'s existing, unmodified
   behavior, and is what makes step 2's unverified peek safe to use only as a *routing*
   decision: even if a forged token's unverified `iss` claim were manipulated between
   step 2 and step 4, `validate_jwt/3` itself would reject a signature that doesn't match
   the routed-to realm's JWKS, or (if it happens to verify against a DIFFERENT realm's
   key by some pathological collision) still assert its own `iss` matches that specific
   provider's configured issuer, not an attacker-chosen one. No new trust is placed in the
   unverified peek beyond "which JWKS to try."

The existing `rescue`/`catch` boundary (§0, lines 59-82) wraps this entire revised body,
unchanged in mechanism — every unhandled crash from any of steps 1-4 still collapses to
`{:error, {:verifier_crashed, %{kind: ..., classification: ...}}}`, preserving the
existing "never raises or exits" guarantee (INV-8, §9).

## 6. Config: fate of `config/runtime.exs`'s `:oidc, :issuer`

**Decision: `:oidc, :issuer` is retired as the source of verification trust. It is
replaced by a new key, `:oidc, :keycloak_base_url`** — the Keycloak host common to every
tenant realm (e.g. `"https://auth.qa.bizdala.com"`, no `/realms/...` suffix) — from which
`Letflow.Oidc.ProviderRegistry` builds each realm's own issuer URL as
`"#{keycloak_base_url}/realms/#{realm}"`.

**Why a shared base URL, not per-tenant issuer hosts:** the `tenants` table's
`idp_realm_id` column (REQ-015/REQ-019) stores a bare realm slug (e.g. `"bilimbaga"`, per
ISS-0690's own live evidence, §0), not a full issuer URL — there is no per-tenant host
column anywhere in the current schema. This design assumes (does not silently assume —
states explicitly) **one Keycloak deployment, N realms**, which matches every piece of
concrete evidence available: ISS-0690's own live trace shows `bpm-default` and
`bilimbaga` both resolving under the same `auth.qa.bizdala.com` host, differing only in
realm path segment. **Flagged as OQ-3 (§8):** if a future tenant genuinely needs an
entirely separate Keycloak host (not just a separate realm on the same host), this design
does not support it — that would require adding a host column to `tenants` and is out of
this requirement's scope, named here so it isn't silently assumed impossible either.

**Concrete `config/runtime.exs` change (`if config_env() == :prod`, §0's current lines
131-143):**

```
config :letflow, :oidc,
  keycloak_base_url:
    System.get_env("OIDC_KEYCLOAK_BASE_URL") ||
      derive_base_url_from_legacy_issuer(System.get_env("OIDC_ISSUER")) ||
      "https://placeholder-keycloak.invalid",
  client_id: System.get_env("OIDC_CLIENT_ID") || "letflow-placeholder-client"
```

`derive_base_url_from_legacy_issuer/1` (a small pure helper, inline logic — a `Regex.run`
stripping a trailing `"/realms/<anything>"` suffix from a full legacy `OIDC_ISSUER` URL) —
**a one-deprecation-cycle backward-compatibility fallback only**, so an already-deployed
environment that has only ever set `OIDC_ISSUER` (not yet `OIDC_KEYCLOAK_BASE_URL`)
continues to resolve its bpm-default realm correctly without an immediate operator action.
`OIDC_ISSUER`/`:oidc, :issuer` are **not read for anything else** — specifically, they are
never consulted to decide whether a *non*-default realm is trusted; the `tenants` table is
the sole source of truth for that (§2), exactly per REQ-370's SCOPE section. This
resolves REQ-370 point 3's explicit either/or: `:oidc, :issuer` becomes a **bootstrap/
derivation-only** value (not "the bpm-default realm's dedicated verifier," since
bpm-default is now verified through the exact same tenants-table path as every other
realm, §7's decision-record verdict makes this uniformity explicit) — it is superseded by
the tenants table for trust, retained only as `keycloak_base_url`'s legacy-derivation
source.

**`config/dev.exs`/`config/test.exs`:** both currently set `:oidc, :issuer` directly
(compile-time, not env-var-driven — §0). Both are updated to set `keycloak_base_url:
"http://localhost:#{keycloak_port}"` directly instead — no derivation logic needed at
compile time since these files already compute the value inline.

**`:oidc, :provider_name` is removed entirely** from every config file
(`dev.exs`/`test.exs`/`prod.exs`) — it named the one static worker's registered atom,
which no longer exists as a concept; per-realm names are computed by
`ProviderRegistry.via_name/1`, not configured.

**`:oidc, :client_id` and `:oidc, :signing_algs` are unchanged** — both are genuinely
deployment-wide, not per-realm, values (the same public client / signing-algorithm
allowlist applies to every realm's token verification), confirmed by their current
`prod.exs` placement ("don't vary per environment" — actually per-realm here, same
reasoning applies) and by §5 step 4 continuing to read them exactly as before.

## 7. Decision-record verdict (REQ-370 point 3's explicit REVIEWER-flag requirement)

**This design's mechanism does imply a real multi-issuer OIDC policy that was not
previously written down as a decision** — REQ-370's own text says exactly this ("no
`docs/migration/decisions/` record currently states a multi-issuer policy... should be
raised for REVIEWER sign-off as this requirement's own design artifact, not adopted
silently"). Per that explicit instruction, this is raised **as this design artifact's own
flag**, not resolved by filing a new decision record unilaterally:

- `docs/migration/decisions/0002-oidc-integration.md` (§0) already **explicitly
  foreshadowed** per-realm provider supervision as the likely S1-execution shape ("likely
  one per configured realm/issuer, given the per-realm JIT config invariant") — so this
  design is not introducing a policy that contradicts 0002; it is the first requirement to
  actually *execute* the shape 0002's own text already anticipated but explicitly deferred
  ("Deferred to S1 execution, not this decision record").
- **Recommendation to REVIEWER: amend `0002-oidc-integration.md` with a short dated
  addendum** (not a new decision-record file) stating that REQ-370 executed the
  already-foreshadowed per-realm-worker shape, and recording the trust model (§2 — tenants
  table is the sole source of issuer trust) as the concrete policy that was previously
  only sketched as a supervision-shape prediction. This design does **not** draft that
  addendum itself — REVIEWER (or DOC-UPDATER under REVIEWER's instruction) should add it
  once this design is PASSed, since the addendum should describe what was actually built,
  not what was designed before REVIEWER's own review might adjust it.
- **If REVIEWER instead judges a genuinely new decision record is warranted** (rather than
  an addendum to 0002), that is REVIEWER's call to make, not silently pre-empted here —
  this design states its own recommendation (addendum, not new record) but defers the
  final choice, per REQ-370's own instruction that this is "REVIEWER sign-off," not a
  CODE-DESIGNER decision to make unilaterally.

This satisfies REQ-370 AC8 ("if the mechanism implies an undocumented multi-issuer OIDC
policy, the close-out states whether a decision record was filed or REVIEWER sign-off was
obtained") — the close-out step (DOC-UPDATER, after REVIEWER PASSes) must state which of
the two paths above REVIEWER actually chose.

## 8. Open questions (explicit, not silently resolved)

1. **OQ-1 (§4.2)** — no worker-teardown mechanism is built for a realm whose tenant row is
   later deleted; the idle worker/ETS-JWKS-table resource persists for the node's
   lifetime. Acceptable for this batch (no `done`/`pending` requirement defines tenant
   deletion at all yet) but named for REVIEWER to confirm, and as a candidate follow-up
   requirement once tenant deletion is a real operation.
2. **OQ-2 (§4.3)** — AC5's "revoke a realm binding" test has no corresponding public
   `Letflow.Identity` API to call (REQ-019's `update_changeset/2` structurally excludes
   `idp_realm_id`, by design). This design's reading is that a test-only direct-`Repo`
   manipulation (bypassing the public changeset API) is the correct way to satisfy AC5
   without expanding this requirement's scope into tenant administration — flagged for
   REVIEWER to confirm or override.
3. **OQ-3 (§6)** — this design assumes one shared Keycloak host across every tenant realm
   (no per-tenant host column exists in `tenants` today). If a future tenant needs a
   genuinely separate IdP host, that needs a schema change out of this requirement's
   scope. Named, not silently assumed impossible.
4. **OQ-4 (§5)** — `:malformed_token` vs. the existing generic `{:verifier_crashed, ...}`
   crash-boundary classification: this design reserves `:malformed_token` narrowly (a
   payload that decodes but lacks a usable `iss`/realm) and routes "not JWT-shaped at all"
   through the existing crash boundary for consistency with the current implementation's
   established policy. ELIXIR-DEV should confirm this split is implementable cleanly
   against `JOSE.JWT.peek_payload/1`'s actual failure modes (it may raise for some
   malformed inputs and return a peculiar but non-raising struct for others — the exact
   boundary between "raises" and "returns garbage claims" was not empirically verified in
   this design pass, since running `mix test`/`iex` against arbitrary malformed tokens is
   implementation-phase work, not design-phase research). Flagged rather than guessed.
5. **OQ-5 (§5 step 1)** — this design deliberately does **not** introduce a shared
   `AuthPipeline`/`TokenVerifier.Oidcc`-straddling helper for "parse a realm out of an
   `iss` string," even though both now do structurally similar parsing (one on verified
   claims, one on unverified). Duplicating ~3 lines of parsing was judged not worth a
   shared-module extraction that would otherwise blur the verified/unverified trust
   boundary between the two call sites (a shared helper risks a future edit applying it
   somewhere it shouldn't be trusted). REVIEWER should confirm this duplication is
   accepted rather than flagged as reuse-avoidance debt.

## 9. Security invariants — explicit assessment (INV-1, INV-7, INV-8)

**INV-1 (tenant data isolation) — APPLIES, satisfied, and is the central mechanism this
design strengthens, not merely preserves.** Before this design, INV-1's tenant-isolation
guarantee at the verification layer was trivially (if uselessly) satisfied by rejecting
every non-bpm-default token outright — this design is what actually makes multi-tenant
OIDC login *possible* while keeping that guarantee: §2's trust gate ensures a token is
never even signature-checked, let alone handed to `AuthPipeline`'s tenant-resolution step,
unless its claimed realm resolves to a real tenant row **right now**, re-checked on every
call (§2, not cached). The specific cross-tenant risk REQ-370's own text names — "a token
minted for one tenant's realm being accepted for another tenant's context" — is not a risk
this design's own scope (verification, step 1 of the pipeline) can itself cause or
prevent by construction beyond what it already does: `verify_bearer_token/1` returns the
*verified* claims (including the *correct* `iss` for whichever realm actually signed the
token), and `AuthPipeline`'s unchanged steps 2-3 (`resolve_tenant/1` +
`guard_realm_ownership/2`, both REQ-019/REQ-021, both untouched) are what turn that `iss`
into a specific `tenant_id` and independently re-verify the binding — this design supplies
correctly-routed, correctly-verified claims into that unchanged downstream machinery; it
does not (and must not) itself decide which tenant a request belongs to. The one new
failure mode this design must not introduce — verifying a token against the WRONG realm's
JWKS due to a routing bug — is closed by §5 step 4's observation that `oidcc`'s own
`validate_jwt/3` independently re-checks `iss` against the specific worker's own
configured issuer, so even a routing mistake would fail closed (signature/issuer mismatch)
rather than fail open.

**INV-7 (no SQL string interpolation) — APPLIES, satisfied by construction.** The one new
DB query this design adds (`ensure_started/1`'s call to `resolve_tenant_by_realm/1`) is
the exact same already-shipped `Repo.get_by/2` call REQ-019 built and SECURITY-REVIEWER
already passed (§0) — no new query shape, no raw SQL, no string interpolation anywhere in
this design.

**INV-8 (no unhandled crashes) — APPLIES, satisfied, with the same residual risk class
REQ-019/REQ-018 already flagged and left open (a genuine DB connection-level failure
inside `resolve_tenant_by_realm/1` propagates as a raised exception, not a typed tuple —
this design does not change that policy, consistent with REQ-019's own OQ-4 precedent,
§0). The new `JOSE.JWT.peek_payload/1` call (§5 step 1) is wrapped by the same
`rescue`/`catch` boundary the current implementation already has, preserving "never raises
or exits" for the verifier as a whole (OQ-4, §8, flags one implementation-detail
uncertainty in exactly how that boundary is drawn, not whether one exists).

## 10. Instructions to ELIXIR-DEV (non-code, procedural)

- Modified files: `lib/letflow/oidc/token_verifier.ex` (callback arity 2→1, new
  `verify_error()` type), `lib/letflow/oidc/token_verifier/oidcc.ex` (§5's revised body),
  `lib/letflow/supervisor/infrastructure.ex` (child #3: static worker spec →
  `Letflow.Oidc.ProviderRegistry`), `lib/letflow/plugs/auth_pipeline.ex` (`verify_token/1`'s
  call-site arity update only — §3), `config/runtime.exs`, `config/dev.exs`,
  `config/prod.exs`, `config/test.exs` (§6).
- New file: `lib/letflow/oidc/provider_registry.ex` (§4).
- **No new migration for schema purposes** — `idp_realm_id` and its partial unique index
  already exist (REQ-015/REQ-019, confirmed §0), and this design adds no new table/column.
  **However, one new DATA migration IS needed**, closing REQ-019's own previously-flagged
  OQ-3 (§0's citation: "no `priv/repo/seeds.exs`... no real default-tenant row exists
  anywhere") as a necessary side effect of this requirement, not an optional nice-to-have:
  without a real `tenants` row bound to `idp_realm_id = "bpm-default"` in every deployed
  environment, §2's trust gate would reject **every** currently-working login (including
  PLATFORM_ADMIN's own) the moment this design ships, since the tenants table becomes the
  sole source of verification trust. Add an idempotent data migration
  (`priv/repo/migrations/<timestamp>_seed_default_tenant.exs`) that inserts a `tenants` row
  with `slug: "bpm-default"`, `idp_realm_id: "bpm-default"`, `display_name` a reasonable
  literal (e.g. `"Default Tenant"`), guarded by `ON CONFLICT (slug) DO NOTHING` (or
  equivalent Ecto-migration-safe idempotent insert) so it is safe to run against an
  environment that may already have such a row (e.g. QA, per ISS-0690's own evidence that
  `GET /tenants` already lists tenants there) as well as one that doesn't (a fresh dev/test
  DB). **This migration must run and be verified BEFORE this requirement's own
  `TokenVerifier`/`ProviderRegistry` changes are considered safe to deploy to any shared
  environment** — ELIXIR-DEV's handoff must state explicitly that this ordering was
  respected. `config/test.exs`-driven tests continue constructing their own per-test
  tenant fixtures (REQ-019's existing precedent, §0) rather than relying on this
  migration's seeded row, since ExUnit's sandboxed transactions don't see it as a shared
  fixture in the same way a real deployment does — the migration exists for real
  environments' continuity, not as a test fixture.
- Self-review per `backend_developer_guide.md` §4, plus:
  - Confirm `AuthPipeline.verify_token/1`'s updated call site no longer reads
    `Keyword.fetch!(oidc_config, :provider_name)` at all (that config key is removed, §6).
  - Confirm `ProviderRegistry.ensure_started/1` calls `Letflow.Identity.resolve_tenant_by_realm/1`
    on **every** invocation (not only when no cached worker exists) — this is the exact
    mechanism §2/§4.3 rely on for AC5; a cache-first ordering that skips the tenant lookup
    when a worker is already running would silently break AC5.
  - Confirm the new data migration's `INSERT` is genuinely idempotent (re-running
    `mix ecto.migrate` against a DB that already has the row must not raise or duplicate).
  - Confirm `:oidc, :provider_name` has no remaining reference anywhere in `lib/` after
    this change (grep the diff).
  - Update `test/support/token_verifier_double.ex`'s `@behaviour Letflow.Oidc.TokenVerifier`
    implementation to the new 1-arity callback (flagged for TEST-DESIGNER too, §11 —
    listed here since it's a support file ELIXIR-DEV may touch first for compile-cleanliness
    before TEST-DESIGNER's own pass).

## 11. Testing notes for TEST-DESIGNER (all 5 REQ-370 acceptance-criteria tests)

- **AC2 — the NEW multi-issuer verification step itself does not cross-accept.**
  REQ-370's AC2 is explicit that this must target `verify_bearer_token/1`'s own new
  routing/verification logic, not merely re-exercise REQ-019's already-tested
  `verify_realm_ownership/2` guard (that guard runs strictly *after* verification and is
  out of this design's own change surface, §1). Construct two real, concurrently-bound
  tenant fixtures (`idp_realm_id: "realm-a"`, `idp_realm_id: "realm-b"`), each with its own
  distinguishable signing-key material (§0 — `Letflow.Oidc.TokenVerifierDouble`'s existing
  single-fixed-claims shape needs extending to support **multiple** realm/claims/key
  pairs selectable by input; this is a `test/support/` change TEST-DESIGNER owns, not this
  design's own file list). With BOTH realms' providers concurrently registered/started
  (`ProviderRegistry.ensure_started/1` called for both before this test's own assertions,
  so a routing bug has an actual second provider present to mis-route into — a test with
  only one realm registered could not detect a mix-up at all), two assertions, both
  exercising `verify_bearer_token/1` directly (not through the full `AuthPipeline`, so
  the guard genuinely cannot be what's producing the result):
  1. **Positive routing-isolation check:** a token genuinely signed by realm A's own key,
     `iss` claiming realm A, verifies successfully (`{:ok, claims}`) with
     `claims["iss"]` confirmed to be realm A's — proving realm B's concurrently-registered
     provider was not the one consulted (if it had been, verification would fail: A's
     token is not signed by B's key).
  2. **Negative cross-accept/forgery check — the actual "does not cross-accept" property.**
     Fabricate a token whose `iss` claims realm A but whose signature was produced with
     realm B's own signing key (constructing this directly via the test double's/fixture's
     own key material — not obtainable from a real Keycloak, since that would require
     possessing another realm's private key, which is exactly the point: this simulates an
     attacker who controls realm B's tenant but is attempting to have a token accepted
     *as* realm A). Assert `verify_bearer_token/1` **rejects** this token. This is the
     test that actually proves the new verification step cannot be tricked into accepting
     a token for the wrong realm's identity, independent of and prior to anything
     `verify_realm_ownership/2` would ever see (a forged token like this never reaches the
     guard at all under this design, since step 1 rejects it first) — this is the concrete
     test named in §5 step 4/§9 INV-1's "the one new failure mode this design must not
     introduce" discussion, moved here under AC2 rather than left folded into AC3's
     "each realm independently verifies" framing (AC3's own test, below, is a positive-only
     per-realm-success check and does not by itself prove non-cross-acceptance between two
     *concurrently* registered realms — that isolation property is AC2's, not AC3's).
  Downstream of these two `verify_bearer_token/1`-level assertions, TEST-DESIGNER may
  additionally exercise the same scenario through the full `AuthPipeline` to confirm
  `verify_realm_ownership/2` still independently rejects whatever cross-tenant-context
  cases it already covers (REQ-019's own tests already pin that behavior; repeating it here
  is optional regression coverage, not this design's own AC2 obligation) — but that
  full-pipeline check must not be presented as AC2's primary evidence; the two
  `verify_bearer_token/1`-level assertions above are.
- **AC3 — ≥2 distinct, independently-registered realms each verify successfully.**
  Extend the test double (or, preferably, exercise this against the real
  `Letflow.Oidc.TokenVerifier.Oidcc` adapter with a local Keycloak that can be configured
  with ≥2 realms — `docker-compose.yml`'s existing `keycloak` service, per `config/dev.exs`'s
  own precedent of pointing at a real local Keycloak — since AC3's "genuinely issued by...
  that realm's own issuer" wording favors a real multi-realm integration test over a
  double wherever this environment's Keycloak reachability allows it, mirroring
  `test/letflow/integration/keycloak_auth_pipeline_test.exs`'s existing precedent, §0). For
  each realm: create the matching tenant fixture (`idp_realm_id` set), mint or fabricate a
  token whose `iss` matches, call `verify_bearer_token/1` directly, assert `{:ok, claims}`
  with `claims["iss"]` matching that specific realm — proving the routing genuinely
  selected the correct per-realm worker/JWKS, not just "some" worker.
- **AC4 — unknown-issuer rejection.** Token whose `iss` claims a realm with **no**
  corresponding tenant row → `verify_bearer_token/1` returns `{:error, :untrusted_issuer}`
  directly (unit-testable against `Letflow.Oidc.TokenVerifier.Oidcc` without needing
  `AuthPipeline` at all), **and** an integration-level test through the full pipeline
  asserting the resulting HTTP response is 401 with the existing generic body (confirming
  §3's "no new oracle" claim holds in practice, not just in this design's stated
  intention).
- **AC5 — revocation causes rejection.** Per §4.3's OQ-2: construct a tenant with a real
  `idp_realm_id`, `ensure_started/1` (or a full `verify_bearer_token/1` call) against it
  successfully once, then remove the binding via direct `Repo` manipulation (not through
  `update_changeset/2`, which structurally cannot express this — §4.3), then assert a
  **second** `verify_bearer_token/1` call with a token from that same realm now returns
  `{:error, :untrusted_issuer}` — this is the test that specifically proves §2's
  fresh-every-call trust-gate claim, not merely a restatement of AC4 with extra steps;
  the assertion should explicitly confirm the SAME realm that verified successfully moments
  earlier now fails, to rule out a test that accidentally only proves AC4's "never was
  trusted" case instead of AC5's "was trusted, then wasn't" case.
- **Unit coverage for `Letflow.Oidc.ProviderRegistry` directly** (not only through the
  verifier): `ensure_started/1` for a trusted realm returns `{:ok, via_name(realm)}` and a
  second call for the same realm reuses the same registered pid (no duplicate worker);
  `ensure_started/1` for an untrusted realm returns `{:error, :unknown_realm}` and starts
  no process at all (assert `Registry.lookup/2` finds nothing for that realm's via-key).
- **`:malformed_token` vs. crash-boundary coverage (OQ-4, §8).** A garbage
  (non-base64/non-JWT-shaped) `raw_token` and a well-formed-JWT-shaped-but-missing-`iss`
  token should each be tested against `verify_bearer_token/1` directly, asserting whichever
  concrete error shape ELIXIR-DEV's implementation actually produces (per OQ-4, this
  design does not pre-commit to exactly which of `:malformed_token` /
  `{:verifier_crashed, ...}` fires for which input shape — TEST-DESIGNER should pin
  whatever ELIXIR-DEV's implementation actually does, and flag to REVIEWER if the split
  looks arbitrary rather than principled).

## 12. Acceptance-criteria traceability

| REQ-370 acceptance criterion | Concrete design element |
|---|---|
| AC1 — this design artifact exists, resolves the 3 SCOPE points, SECURITY-REVIEWER + REVIEWER PASS before implementation | This file; §3 (callback shape), §4 (supervision shape + new-tenant-without-restart), §6 (`:oidc, :issuer` fate) |
| AC2 — cross-tenant rejection test | §11 "AC2" — targets the NEW `verify_bearer_token/1` routing/verification step itself (positive routing-isolation + negative cross-realm-forgery checks with two realms concurrently registered), distinct from and prior to REQ-019's existing `verify_realm_ownership/2` guard |
| AC3 — ≥2 realms verify successfully | §4 (per-realm worker resolution), §5 (adapter routing), §11 "AC3" |
| AC4 — unknown-issuer rejection | §2 (trust gate), §3 (`:untrusted_issuer`), §4.2 step 1, §11 "AC4" |
| AC5 — revocation causes rejection | §4.3 (why no teardown mechanism is needed for this to hold), §11 "AC5" |
| AC6 — SECURITY-REVIEWER states INV-1 satisfaction + cross-tenant risk | §9's INV-1 assessment, written so SECURITY-REVIEWER's gate is straightforward, not reconstructed from scratch |
| AC7 — close-out states ISS-0690 remains open | Not this design's own artifact to state (DOC-UPDATER's close-out step) — noted here so DOC-UPDATER's instructions inherit it: this requirement does not touch ISS-0690's own `status` field |
| AC8 — decision-record verdict | §7 — explicit recommendation (amend 0002 via addendum) plus explicit deferral of the final call to REVIEWER, not silently resolved |
| AC9 — `mix test`/`mix compile --warnings-as-errors` pass, real output quoted | Implementation-phase; not this design's own artifact, but §10's migration-ordering instruction and §4's lazy-start design are both chosen partly to keep the change compile-clean and supervision-tree-safe without new dependencies (§0 confirms `JOSE.JWT.peek_payload/1` and `{:via, Registry, _}` naming both already work against vendored deps) |

Every element REQ-370's SCOPE section names is addressed: (1) `TokenVerifier` callback +
both implementations — §3, §5; (2) per-realm provider-worker supervision shape, including
new-tenant-without-restart — §4; (3) fate of `:oidc, :issuer` — §6, with the decision-record
question resolved via explicit REVIEWER-flag rather than silent adoption — §7.
