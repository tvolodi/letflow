# REQ-418 — `letflow-mobile` OIDC client + sixth `client_id` key (design)

**Status:** design, pre-implementation. **Stage:** S9 (mobile tier, `docs/mobile/`).
**Gate for:** MOB-2 (REQ-421), the entire mobile-tier auth flow. **THIS IS A SECURITY
CHANGE** — identity configuration (a new OIDC public client) plus a public,
unauthenticated response-shape change. SECURITY-REVIEWER is a **required, hard gate**
per `docs/agents/instructions/security-invariants.md` (identity-configuration class
and public-response-shape class both apply) — this must not proceed to REVIEWER or
TEST-DESIGNER until SECURITY-REVIEWER signs off.

No implementation code appears below. JSON/map shape sketches are literal target
values (design contract), not executable code; `@spec`-only function signatures, no
bodies.

---

## PART 1 — `letflow-mobile` Keycloak client

### 1.1 Exact target JSON

Add one new element to `priv/keycloak/realms/bpm-default.json`'s top-level `clients`
array, **as `clients[1]`, after the existing `letflow-web` entry** (`clients[0]`,
untouched — see §1.3). This is a new array element, not a modification of the
existing one:

```json
{
  "clientId": "letflow-mobile",
  "name": "Letflow Mobile",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": true,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "implicitFlowEnabled": false,
  "serviceAccountsEnabled": false,
  "redirectUris": ["com.bizdala.letflow:/oauth2redirect"],
  "webOrigins": [],
  "attributes": {
    "pkce.code.challenge.method": "S256",
    "post.logout.redirect.uris": "com.bizdala.letflow:/oauth2redirect"
  },
  "protocolMappers": [
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
    },
    {
      "name": "letflow-mobile-audience",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "consentRequired": false,
      "config": {
        "included.client.audience": "letflow-web",
        "included.custom.audience": "",
        "id.token.claim": "false",
        "access.token.claim": "true"
      }
    }
  ]
}
```

### 1.2 Field-by-field rationale

- **`clientId: "letflow-mobile"`** — the requirement's mandated id; this is the value
  the mobile app names as `clientId` in its `flutter_appauth` call and the value
  `GET /api/mobile/tenant-config`'s new `client_id` key serves (Part 2).
- **`publicClient: true`** — a native app cannot hold a client secret; same posture as
  `letflow-web`.
- **`standardFlowEnabled: true`** — enables Authorization Code flow, required for
  PKCE.
- **`directAccessGrantsEnabled: false`** — the requirement text is explicit that the
  password grant "has no place on a device." This is the one flow flag that
  deliberately **diverges** from `letflow-web` (which has this `true`).
- **`implicitFlowEnabled: false`** — implicit flow returns tokens directly in a
  redirect fragment with no code-exchange step; PKCE Authorization Code is the only
  flow this client needs, so implicit stays off (Keycloak's own default, made
  explicit here rather than left to an unstated default).
- **`serviceAccountsEnabled: false`** — no server-to-server client-credentials use
  case for a mobile app; matches `letflow-web`.
- **`redirectUris: ["com.bizdala.letflow:/oauth2redirect"]`** — exactly one entry,
  the custom-scheme URI `flutter_appauth`'s system-browser redirect lands on. **No
  `"*"`, no `http(s)://` entry, no trailing-wildcard entry.** This is the fix for the
  defect this requirement exists to close: `letflow-web`'s `["*"]` would let any app
  registering any scheme receive a mobile authorization code. The scheme
  (`com.bizdala.letflow`) must equal the Android `applicationId`/iOS bundle id
  REQ-419 creates — confirmed identical in `docs/requirements.yaml`'s REQ-418/419/421
  text, all three pin `com.bizdala.letflow`. This value is flagged in
  `docs/requirements.yaml` itself as an **open, non-decision-record choice** ("Cheap
  to change until the app is published to a store; effectively permanent after") —
  this design does not re-decide it, only carries it through consistently across the
  three entries that must match.
- **`webOrigins: []`** — a native app makes no browser-origin CORS request against
  Keycloak; `letflow-web`'s `["*"]` exists for the SPA's own cross-origin token
  requests, which have no mobile equivalent. Empty, not `["*"]`, not omitted (an
  explicit empty array is unambiguous; an absent key could be read as "use Keycloak's
  own default," which this design does not want to depend on).
- **`attributes."pkce.code.challenge.method": "S256"`** — per the requirement text,
  this makes Keycloak reject any authorization request for this client that lacks an
  S256 `code_challenge`, i.e. server-side PKCE enforcement, not merely a
  client-side convention. This is the mechanism the live acceptance-criteria curl
  check (§4, AC3) exercises directly (a request with no `code_challenge` must fail).
- **`attributes."post.logout.redirect.uris": "com.bizdala.letflow:/oauth2redirect"`**
  — per the requirement text verbatim; Keycloak's logout-redirect allowlist for this
  client, using the same custom-scheme value as `redirectUris` (there is no other
  URI this app could plausibly redirect to post-logout).
- **`protocolMappers[0]` (`realm-roles`)** — **the same mapper `letflow-web` carries**,
  copied field-for-field from `clients[0].protocolMappers[0]` (confirmed by reading
  the tracked file, §1.3 below) — `claim.name: "roles"` is the claim
  `Letflow.Oidc.ClaimMappingConfig` (`config/dev.exs`'s `:oidc_claim_mapping` for
  realm `"bpm-default"`) reads role assignments from, and that claim-mapping config
  is realm-scoped, not client-scoped, so both clients issuing tokens against the same
  realm must supply the same `roles` claim shape for the same JIT-provisioning /
  role-assignment pipeline to work identically regardless of which client
  authenticated the user.
- **`protocolMappers[1]` (`letflow-mobile-audience`)** — an `oidc-audience-mapper`
  with `included.client.audience: "letflow-web"` — **mandatory, not optional** (see
  §1.4 for why). Field values (`included.custom.audience: ""`, `id.token.claim:
  "false"`, `access.token.claim: "true"`) mirror `letflow-web`'s own
  `letflow-web-audience` mapper (`lib/letflow/design/iss0275-audience-mapper-fix.md`
  §2.1's field-by-field rationale for each of these four keys, unchanged for this
  client — the only value that legitimately differs across the two clients'
  audience mappers is the mapper `name`, kept distinct per-client
  (`letflow-web-audience` vs. `letflow-mobile-audience`) for the same "isolated,
  auditable per-client mapper" reasoning REQ-124's design gave for splitting router
  modules rather than branching one).
- **`name: "Letflow Mobile"`** — display name only, mirrors `letflow-web`'s
  `"name": "Letflow Web"` convention; not security-relevant, included for
  Keycloak-admin-console readability parity.

### 1.3 `letflow-web` is byte-identical — explicit statement

The existing `clients[0]` object (`clientId: "letflow-web"`, currently read in full
from the tracked file as of this design):

```json
{
  "clientId": "letflow-web",
  "name": "Letflow Web",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": true,
  "directAccessGrantsEnabled": true,
  "standardFlowEnabled": true,
  "serviceAccountsEnabled": false,
  "redirectUris": ["*"],
  "webOrigins": ["*"],
  "protocolMappers": [
    { "name": "realm-roles", "...": "unchanged, see file" },
    { "name": "letflow-web-audience", "...": "unchanged, see file" }
  ]
}
```

**does not change in any way** — no field added, removed, or reordered; no mapper
added, removed, or reordered. The realm-level `attributes`, `roles`, and `users`
arrays are also untouched. This design's only change to `bpm-default.json` is
appending one new element to the `clients` array (§1.1). ELIXIR-DEV must diff the
file after editing and confirm the only hunk is an addition, not a modification —
this is exactly what the AC2 test (§4) asserts programmatically (an inline expected
map equality check on `letflow-web`'s object, not a subset/partial check).

### 1.4 Why the audience mapper is mandatory (ISS-0275 recurrence risk)

`Letflow.Oidc.TokenVerifier.Oidcc` validates every bearer token via
`Oidcc.Token.validate_jwt/3`, whose `verify_aud_claim` implementation
(`deps/oidcc/src/oidcc_token.erl:1283`) unconditionally rejects any access token
whose `aud` claim does not contain the configured `:oidc` `client_id` —
`"letflow-web"` (`config/dev.exs:97`, `config/test.exs:128`; both configs name the
same single client id regardless of which Keycloak *client* issued the token).
This check is **not parameterized per issuing client** — it checks the token's `aud`
against one fixed configured string, the same string for a token issued to
`letflow-web` or to `letflow-mobile`.

This is precisely the defect ISS-0275 fixed for `letflow-web`
(`lib/letflow/design/iss0275-audience-mapper-fix.md`): before that fix,
`letflow-web` had no `oidc-audience-mapper`, so its tokens carried no `aud` claim
naming `letflow-web`, and every authenticated request 401'd regardless of route. If
`letflow-mobile` shipped **without** its own `oidc-audience-mapper` naming
`included.client.audience: "letflow-web"`, every token Keycloak issues to the mobile
app would likewise carry no `aud` claim satisfying `verify_aud_claim`, and every
authenticated mobile API call would 401 — the identical defect, recurring on a
second client instead of being reintroduced on the same one. This design therefore
treats the mapper as a hard requirement of Part 1, not an optional hardening
addition, and gives it the exact same four `config` keys ISS-0275 established as
correct.

`validate_jwt/3` does **not** check `azp` (authorized party) — confirmed by the
requirement text and consistent with `verify_aud_claim`'s scope being `aud` only —
so `letflow-mobile`'s tokens carrying `azp: "letflow-mobile"` (Keycloak's own
default behavior, not something this design configures) alongside `aud: [...,
"letflow-web"]` is accepted without any further mapper or config change. This is
also what the AC4 live check (§4) asserts directly: `evaluate-scopes` output must
show `aud` containing `"letflow-web"` and `azp` equal to `"letflow-mobile"`.

### 1.5 Test-file plan (Part 1)

| Test | File | What it asserts |
|---|---|---|
| Static realm-JSON shape check | `test/letflow/api/keycloak_realm_mobile_client_test.exs` (new; style mirrors `test/letflow/api/keycloak_realm_audience_mapper_test.exs`, read in full for this design) | Loads and `Jason.decode!`s the tracked `bpm-default.json`; finds the `letflow-mobile` client by `clientId`; asserts `publicClient == true`, `standardFlowEnabled == true`, `directAccessGrantsEnabled == false`, `implicitFlowEnabled == false`, `serviceAccountsEnabled == false`, `attributes["pkce.code.challenge.method"] == "S256"`, `attributes["post.logout.redirect.uris"] == "com.bizdala.letflow:/oauth2redirect"`, `redirectUris == ["com.bizdala.letflow:/oauth2redirect"]` (exact list equality, not membership), `webOrigins == []`; finds a `realm-roles`-named mapper and an `oidc-audience-mapper`-typed mapper with `config["included.client.audience"] == "letflow-web"` and `config["access.token.claim"] == "true"` |
| No-wildcard guard | same file | Asserts, for both `redirectUris` and `webOrigins` on `letflow-mobile`, that no element equals `"*"` and no element starts with `"http"` (covers both the literal wildcard and any accidental `http(s)://` entry) |
| `letflow-web` unchanged | same file | Asserts `letflow-web`'s full client JSON object (`Enum.find(clients, & &1["clientId"] == "letflow-web")`) equals an **inline literal expected map** written into the test (copied from the file as read for this design, §1.3) — an exact `==` equality, not a partial/subset match. Per the requirement text, this must be an inline literal, not `git show origin/main:...` (unavailable under CI's shallow checkout, and tautological once this change lands on `main`) |
| Live: valid PKCE auth request succeeds | manual/CI live-Keycloak step (§4 AC3, run by ELIXIR-DEV/TEST-RUNNER against a freshly `--force-recreate`d dev Keycloak; not an ExUnit test, since it requires a running container) | `curl` to `/realms/bpm-default/protocol/openid-connect/auth` with `client_id=letflow-mobile`, the registered `redirect_uri`, `response_type=code`, and an `S256` `code_challenge` returns HTTP 200 (login page) |
| Live: foreign redirect_uri rejected | same live step | Same request with `redirect_uri=https://evil.example/cb` returns a non-200 error naming `redirect_uri` in the body, and does **not** redirect to `evil.example` |
| Live: missing PKCE rejected | same live step | Same request with no `code_challenge` does not return the login page; yields an error naming `code_challenge`/`code_challenge_method` (in the body, or as `error=invalid_request` in a `Location` redirect to the registered custom-scheme URI) — this is the direct proof that `pkce.code.challenge.method: "S256"` (§1.2) is enforced server-side |
| Live: `aud`/`azp` shape | same live step | Keycloak admin `evaluate-scopes/generate-example-access-token` for `letflow-mobile` against an admin user returns claims with `aud` containing `"letflow-web"` and `azp == "letflow-mobile"` |

---

## PART 2 — sixth `client_id` key on `GET /api/mobile/tenant-config`

### 2.1 Resolution function

```
@spec client_id() :: String.t()
```

Resolution order, mirroring `Letflow.Routers.TenantConfig.client_id/0`
(`lib/letflow/routers/tenant_config.ex:361`, `System.get_env("OIDC_CLIENT_ID") ||
@default_client_id`) exactly in *shape*, with this module's own env var and default:

```
System.get_env("MOBILE_OIDC_CLIENT_ID") || @default_client_id
```

where `@default_client_id "letflow-mobile"` is added as a new module attribute
alongside the existing `@default_idp_base_url`/`@default_realm`/etc. Read at point of
use (INV-4 style, same as `idp_base_url/0` and `environment_kind/0` in this module),
never threaded through a struct field, never logged.

### 2.2 Response-map change

`mobile_config_map/2`'s signature is unchanged (`realm_id, settings -> map`); its
returned map gains one entry:

```
@spec mobile_config_map(realm_id :: String.t(), settings :: map() | nil) :: %{
        required(String.t()) => String.t() | [String.t()] | map()
      }
```
target map (six keys):
```
%{
  "realm_url"        => idp_base_url() <> "/realms/" <> realm_id,
  "locales"          => locales_from_settings(settings),
  "default_locale"   => default_locale_from_settings(settings),
  "branding"         => branding_from_settings(settings),
  "environment_kind" => environment_kind(),
  "client_id"        => client_id()
}
```

`client_id` is placed last, after the five existing keys, matching the requirement
text's phrasing ("a sixth key") and keeping the diff to the map literal as an
addition rather than a reordering; key order is not semantically load-bearing (it is
serialized to a JSON object) but a minimal diff is easier for SECURITY-REVIEWER to
audit.

**`client_id` is byte-identical across every branch, by construction** — it is
computed independently of `realm_id` and `settings`, so every one of the four
never-error paths (resolvable slug, unknown slug, missing `?slug=`, lookup failure)
produces the exact same `client_id` value for a given environment/env-var state.
This places `client_id` in the same "platform-global, zero variance" category as
`environment_kind`, not in the per-tenant category `locales`/`default_locale`/
`branding` moved into under REQ-282.

### 2.3 Moduledoc rewrite — every location that must change

`lib/letflow/routers/mobile_tenant_config.ex`'s moduledoc currently states "five" /
"5" in the following locations (line numbers per the file as read for this design);
each must be updated to six/6, and the phrase **"exactly five keys" must not survive
anywhere in the file**:

1. **Header table** (moduledoc line 10): `Response` column reads `always 200,
   {realm_url, locales, default_locale, branding, environment_kind}` → append
   `, client_id` to the tuple.
2. **"This is a second, independent module" paragraph** (line 15): "this module's
   5-key allowlist" → "6-key allowlist".
3. **"What this endpoint discloses, and what it must never disclose" section**
   (lines 85–95): "It returns exactly five keys: `realm_url`, `locales`,
   `default_locale`, `branding`, `environment_kind`." → rewritten to list six keys,
   adding `client_id`, and to state the three-point client_id security reasoning
   (below) inline, since the section's whole purpose is justifying why each
   disclosed value is safe to disclose unauthenticated. The section's closing
   sentence, **"Adding a sixth key to this response is a security change, not a
   feature,"** must become **"Adding a seventh key…"** — that sentence is a
   structural invariant statement about the module (the *next* undecided key), not a
   historical fact about this change, so it must be renumbered forward, not deleted.
4. **End of the "The never-error rule is LOAD-BEARING here too" section** (moduledoc
   lines 80–83 — **not** the "locales / default_locale / branding are per-tenant;
   environment_kind remains global" section at lines 97–114, which contains a
   different, textually distinct sentence at lines 111–113
   — `` `environment_kind` remains the one field genuinely sourced from application
   config/env (`LETFLOW_ENVIRONMENT_KIND`), unrelated to any tenant, unchanged by
   this requirement — it is global in the sense the whole paragraph used to claim of
   all four fields; the other three no longer are.`` — that sentence must NOT be
   confused with, or edited in place of, the one below): the sentence
   `` `environment_kind` is the one field that is still, and remains, byte-identical
   across every branch by construction (env-derived, not tenant-derived, not touched
   by this requirement). `` (lines 80–83) must gain a clause placing `client_id`
   alongside `environment_kind` in the "byte-identical-across-every-branch, by
   construction" category — e.g. extending it to read "`environment_kind` and
   `client_id` are the two fields that are still, and remain, byte-identical across
   every branch by construction" (or an added sentence immediately after it), **not**
   folding `client_id` into the three per-tenant fields' fallback-helper description,
   since `client_id` has no `settings`-derived variance at all — it is resolved with
   no tenant input whatsoever, a stronger invariance than the three per-tenant
   fields' "same-if-no-settings-stored" convergence.

   **Test-collision warning (mandatory read before editing this sentence):** this
   exact sentence, verbatim, is hard-matched by the pre-existing REQ-282 AC4
   assertion at `test/letflow/routers/mobile_tenant_config_test.exs` lines 535–536:
   `` assert normalized =~ "`environment_kind` is the one field that is still, and
   remains, byte-identical across every branch by construction" ``. That assertion
   checks a *substring*, not full-string equality, against the moduledoc with all
   whitespace collapsed (`normalized = String.replace(moduledoc, ~r/\s+/, " ")`,
   line 530). Editing this sentence must preserve that exact substring
   uninterrupted — i.e. any extension must be **appended after** "byte-identical
   across every branch by construction" (e.g. "...by construction, and `client_id`
   joins it as a second such field.") rather than rewritten in a way that inserts
   text into the middle of the matched phrase or paraphrases any word inside it. See
   §2.4 for the corresponding test-file guidance.
5. **Existing tests' exact-key assertion literal** — not moduledoc prose, but the
   same five→six change: `test/letflow/routers/mobile_tenant_config_test.exs`'s
   module attribute `@expected_keys ["branding", "default_locale",
   "environment_kind", "locales", "realm_url"]` (line 42) must become
   `["branding", "client_id", "default_locale", "environment_kind", "locales",
   "realm_url"]` (sorted order, matching `Enum.sort/1`'s use at every call site) —
   this attribute is read by every exact-shape assertion in the file (lines 114,
   196, 321, 354), so changing it once updates every one of those call sites
   consistently. **Never loosen any of these assertions to a subset/membership
   check** — each must remain `Map.keys(body) |> Enum.sort() == @expected_keys`.

A new moduledoc paragraph (placed inside the "What this endpoint discloses" section,
item 3 above) must state the three-point reasoning from the requirement text,
verbatim in substance:

> `client_id` is added as a sixth disclosed value. It is safe to disclose
> unauthenticated for three reasons: (i) an OAuth public-client identifier is not a
> secret (RFC 6749 §2.2 — a public client has no credential to protect), and
> `Letflow.Routers.TenantConfig` already publishes its own equivalent `client_id`
> unauthenticated for the web SPA; (ii) the value is platform-global, not
> tenant-derived — byte-identical on every never-error branch (resolvable slug,
> unknown slug, missing `?slug=`, lookup failure), adding zero enumeration signal,
> the same status `environment_kind` already has; (iii) the alternative —
> compiling the client id into the mobile app — would work today but freezes it
> into every shipped build, so a deployment whose realm registers the client under
> a different name, or a later rename, would require an app store release; serving
> it from this endpoint keeps the platform's existing "one tenant-agnostic build"
> constraint (the same constraint that makes this whole endpoint exist) without
> that release coupling. This does **not** support a per-tenant client name — the
> value is platform-global by design (point ii) — a per-tenant client id would be a
> new requirement with its own disclosure analysis.

### 2.4 Test-file plan (Part 2)

| Test | File | What it asserts |
|---|---|---|
| Six-key exact shape, all four never-error paths | `test/letflow/routers/mobile_tenant_config_test.exs` (existing file — `@expected_keys` updated per §2.3 item 5; the file's existing four-path coverage — REQ-282 AC2's "resolvable slug with no stored settings / unknown slug / missing `?slug=` / simulated DB failure" describe block, lines 330–382 — is reused, not duplicated, since it already exercises exactly these four branches; only the key-set literal and one added `client_id`-equality assertion change) | `Map.keys(body) |> Enum.sort() == @expected_keys` (six keys) holds for the resolvable-with-no-settings, unknown-slug, missing-`?slug=`, and simulated-lookup-failure cases already present in that describe block |
| `client_id` value — default | same file, new `describe` block | With `MOBILE_OIDC_CLIENT_ID` unset (`System.delete_env/1` in `setup`, restored via `on_exit`, mirroring how this test module already isolates env state — confirmed pattern absent today but required by this change since this is the first env-var-driven field in this module's tests), `body["client_id"] == "letflow-mobile"` |
| `client_id` value — env override | same new block | With `MOBILE_OIDC_CLIENT_ID` set (e.g. via `System.put_env/2` in the test, `on_exit` cleanup), `body["client_id"]` equals that env value |
| `client_id` identical across all four paths | same new block | For a fixed env state, `client_id` from the resolvable-slug, unknown-slug, missing-`?slug=`, and lookup-failure responses are all `==` to each other — the byte-identical-by-construction claim from §2.2, asserted directly rather than only inferred from the shared six-key check |
| Moduledoc no longer says "exactly five keys" | same file, extending the existing `Code.fetch_docs/1`-based moduledoc test pattern (lines 291–297, 525–544) | `refute moduledoc =~ "exactly five keys"`; `assert moduledoc =~ "client_id"`; `assert moduledoc =~` the three-point-reasoning language (e.g. a distinctive substring such as `"is not a secret"` and `"platform-global"`) |
| **Existing REQ-282 AC4 assertion at lines 535–536 must still pass unmodified** | same file, `describe "REQ-282 AC4: moduledoc no longer claims branding/locales/default_locale are global"` block (lines 525–544) | This test's `assert normalized =~ "`environment_kind` is the one field that is still, and remains, byte-identical across every branch by construction"` (lines 535–536) is a **pre-existing regression assertion, not something this change adds or edits**. Because §2.3 item 4 requires the `client_id` clause to be *appended after* that exact phrase rather than inserted into it, this substring survives untouched in the edited moduledoc and the assertion continues to pass with **no change to the test file at this line**. ELIXIR-DEV must run this specific test after editing the moduledoc sentence and confirm it still passes — if it fails, the moduledoc edit broke the substring instead of appending after it, and the edit (not the test) must be corrected. Do **not** loosen or rewrite this assertion to accommodate a differently-worded moduledoc edit; the wording constraint in §2.3 item 4 exists specifically so this assertion needs no change. |
| `req124-mobile-tenant-config.md` addendum recorded | not a code test — a documentation deliverable ELIXIR-DEV must produce alongside the code change: a dated `## Addendum (REQ-418, <date>)` section appended to `lib/letflow/design/req124-mobile-tenant-config.md`, stating that `client_id` was added as a sixth key per REQ-418, pointing at this file for the full rationale, and noting §9's acceptance-criteria table and §6's response-shape table are now superseded on key-count (five→six) without rewriting them in place — REQ-VALIDATOR-style addendum-not-rewrite convention already used elsewhere in this design corpus (e.g. `req128-keycloak-dev-stack.md`'s "Correction after..." sections) |

### 2.5 Cross-module dependencies (Part 2)

- `Letflow.Routers.MobileTenantConfig` — the only module changed: one new
  `@default_client_id` attribute, one new `client_id/0` private function, one new
  map key in `mobile_config_map/2`, moduledoc rewrite (§2.3).
- `Letflow.Routers.TenantConfig` — read for pattern reference only (`client_id/0`,
  line 361); **not modified**. Its own `client_id` field, env var
  (`OIDC_CLIENT_ID`), and default (`"letflow-web"`) are untouched and unrelated —
  the two modules deliberately keep independent env vars
  (`MOBILE_OIDC_CLIENT_ID` vs. `OIDC_CLIENT_ID`) so a deployment can override the
  web client id without accidentally overriding the mobile one, mirroring how
  `@default_branding` in this module is already independent of
  `Letflow.Routers.TenantConfig`'s own branding defaults (that module's own comment,
  line 189, states this "deliberately NOT shared/reused").
- `test/letflow/routers/mobile_tenant_config_test.exs` — `@expected_keys` and new
  `client_id`-specific tests (§2.4).
- No migration, no new `Letflow.Identity` function, no change to
  `Letflow.Plugs.ApiPipeline`/`AuthPipeline`/`Cors`, no change to
  `Letflow.Routers.TenantConfig`'s own route or response shape.

---

## 3. Invariants

- **INV-2 (hand-built allowlist).** `mobile_config_map/2` remains a hand-built map
  literal, now with six keys, still never derived from `%Letflow.Identity.Tenant{}`
  or `Map.from_struct/1`. Adding a **seventh** key becomes the new "security change,
  not a feature" trigger (§2.3 item 3).
- **INV-5-flavored (anti-enumeration).** `client_id`'s addition does not create a new
  oracle: it is byte-identical across all four never-error branches (§2.2), the same
  guarantee `environment_kind` already carries.
- **INV-4 (no secret in logs/structs).** `client_id()` is read via
  `System.get_env/1` at point of use, mirroring `idp_base_url/0`/`environment_kind/0`
  in the same module; not a secret per RFC 6749 §2.2, but the resolution style is
  followed regardless, matching this module's existing stated policy.
- **Identity-configuration invariant (Part 1).** `letflow-mobile` is `publicClient:
  true` with `directAccessGrantsEnabled: false` and a single non-wildcard,
  non-http(s) `redirectUris` entry — no password grant, no open redirect. The
  `oidc-audience-mapper` is mandatory, not optional (§1.4) — its absence is a token-
  validation outage, not a soft degradation.
- **No modification to `letflow-web`.** Confirmed both by design (§1.3) and by the
  AC2 test's inline-literal equality check (§1.5) — this is the invariant
  SECURITY-REVIEWER most needs to verify mechanically, since a diff review alone
  could miss a same-line edit inside a large JSON array.

---

## 4. Acceptance-criteria resolution map (REQ-418's own `acceptance_criteria`, `docs/requirements.yaml`)

| # | Acceptance criterion (paraphrased) | Resolved by | File |
|---|---|---|---|
| 1 | Static test: `letflow-mobile` client shape (`publicClient`, `standardFlowEnabled`, `directAccessGrantsEnabled: false`, `implicitFlowEnabled: false`, PKCE S256 attribute, exact `redirectUris`, `webOrigins: []`, roles mapper, audience mapper fields) | §1.1, §1.2 | `test/letflow/api/keycloak_realm_mobile_client_test.exs` (new) |
| 2 | Same test: no `"*"`/`http` in `letflow-mobile`'s redirect/origin lists; `letflow-web`'s JSON object equals an inline literal (not `git show`) | §1.3, §1.5 | same file |
| 3 | Live: valid PKCE auth request → 200 login page; foreign `redirect_uri` → non-200 naming `redirect_uri`, no redirect to it; missing `code_challenge` → error naming `code_challenge`/`code_challenge_method` | §1.2 (`pkce.code.challenge.method`), §1.5 | live curl checks (not an ExUnit file — run against a running dev Keycloak) |
| 4 | Live: `evaluate-scopes` example token has `aud` containing `letflow-web`, `azp == letflow-mobile` | §1.4, §1.5 | live admin-API check |
| 5 | `GET /api/mobile/tenant-config` returns exactly six keys, exact-set equality, across all four never-error paths | §2.2, §2.4 | `test/letflow/routers/mobile_tenant_config_test.exs` (existing, extended) |
| 6 | `client_id` is `"letflow-mobile"` with env unset, equals env value when set, identical across all four paths | §2.1, §2.4 | same file |
| 7 | Moduledoc no longer contains "exactly five keys"; states six keys, the three-point reasoning, and platform-global framing | §2.3 | `lib/letflow/routers/mobile_tenant_config.ex` moduledoc; asserted by `Code.fetch_docs/1` tests in the same test file |
| 8 | SECURITY-REVIEWER sign-off before merge; `mix letflow.check` passes | N/A (process gate, not a design element) — flagged here as the hard blocking gate this design is written to satisfy | — |

---

## 5. Open questions

- **OQ-1.** The Android applicationId / iOS bundle id / redirect scheme
  (`com.bizdala.letflow`) is itself flagged in `docs/requirements.yaml` as an open,
  reversible-until-store-publication choice shared across REQ-418/419/421, not a
  decision this design makes independently. If REQ-VALIDATOR/REVIEWER changes it,
  it must change in `redirectUris`, `attributes."post.logout.redirect.uris"`, and
  this design's own text together — there is no second value to reconcile within
  Part 1 or Part 2 of REQ-418 itself.
- **OQ-2.** This design does not add `System.delete_env/1`/`on_exit` env-isolation
  helpers as a shared test utility — each new `client_id`-env test in §2.4 manages
  its own `setup`/`on_exit` inline, consistent with how no shared env-var-test helper
  exists elsewhere in this test file today. If a third env-driven field is added
  later, a shared helper may be worth extracting then; not preemptively here.
- **OQ-3.** The moduledoc rewrite instruction (§2.3 item 3) renumbers "sixth key is
  a security change" to "seventh key is a security change" rather than deleting the
  sentence. CODE-DESIGN-VALIDATOR should confirm this renumber-forward convention is
  the intended reading of "update... to six keys" (vs. some alternative phrasing
  that drops the forward-looking sentence entirely) — this design's position is that
  the sentence is a standing invariant statement about the *next* undecided key, not
  a one-time historical claim, so it must persist, renumbered, rather than being
  removed.
