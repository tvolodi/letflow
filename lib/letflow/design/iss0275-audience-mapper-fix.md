# Design: ISS-0275 — add `oidc-audience-mapper` to the `letflow-web` client

**Run:** `WF03-ISS0275-20260822` · Step 2 (CODE-DESIGNER) ·
**Author:** CODE-DESIGNER · **Status:** proposed — awaiting CODE-DESIGN-VALIDATOR

**Scope statement (read this first):** this is a **narrow, scoped fix** — add one
protocol mapper object to `priv/keycloak/realms/bpm-default.json`'s single client,
`letflow-web`, and append a correction note to
`lib/letflow/design/req128-keycloak-dev-stack.md` where that file's original
(incorrect) "no audience mapper is added" scope note lives. Nothing else about the
realm, the client, `config/dev.exs`/`config/test.exs`, or the docker-compose Keycloak
service changes. No implementation code appears below — a literal JSON object and
exact prose edits only.

---

## 1. Root cause (per ISSUE-FIXER, re-confirmed against the tracked realm file above)

`priv/keycloak/realms/bpm-default.json`'s `letflow-web` client (`clients[0]`,
`protocolMappers` array, lines 31-46 as read on this branch) has exactly one protocol
mapper: `realm-roles` (`oidc-usermodel-realm-role-mapper`). No mapper of type
`oidc-audience-mapper` exists anywhere in the file.

`Oidcc.Token.validate_jwt/3` (`deps/oidcc/src/oidcc_token.erl:1166-1180`)
unconditionally requires the token's `aud` claim to contain the configured
`client_id` (`"letflow-web"`, per `config/dev.exs`/`config/test.exs`'s `:oidc`
config), returning `{error, {missing_claim, {<<"aud">>, ClientId}, Claims}}`
otherwise. Since nothing in the realm ever populates `aud` with `letflow-web`, every
real Keycloak-issued access token fails `Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2`
before `Letflow.Plugs.AuthPipeline` reaches tenant resolution — every authenticated
request 401s, regardless of route.

This was live-confirmed during REQ-116's contract sweep: hand-patching a running
container's `letflow-web` client via the Keycloak Admin REST API with an
`oidc-audience-mapper` (`included.client.audience: letflow-web`) fixed the 401s, but
that patch was never committed to the tracked realm JSON — it lived only in the
throwaway container. This fix commits the equivalent mapper to the tracked file so
every fresh `docker compose up keycloak --import-realm` gets it for free.

---

## 2. RULING: the exact JSON to add

Add one object to `priv/keycloak/realms/bpm-default.json`'s
`clients[0].protocolMappers` array (i.e. `letflow-web`'s `protocolMappers`), as a
second element alongside the existing `realm-roles` mapper — array order does not
matter to Keycloak's import, but appending after the existing entry (rather than
before) keeps the diff minimal:

```json
{
  "name": "letflow-web-audience",
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
```

### 2.1 Field-by-field justification

- **`name`**: `"letflow-web-audience"` — mirrors the existing mapper's naming style
  (`"realm-roles"`: `<purpose>`) with the client id folded in since this mapper is
  specific to asserting that client's own id as audience, not a generic "audience"
  name that could be mistaken for a different target client.
- **`protocol`**: `"openid-connect"` — matches the client and the existing mapper;
  Keycloak realm-import schema requires this on every protocol mapper.
- **`protocolMapper`**: `"oidc-audience-mapper"` — the standard Keycloak built-in
  provider id for the audience mapper (`org.keycloak.protocol.oidc.mappers.AudienceProtocolMapper`,
  registered under this string). This is the exact value the task instructions specify
  and the exact value Keycloak's own admin console emits when adding a "Audience"
  mapper of the built-in type.
- **`consentRequired`**: `false` — matches the existing mapper; `letflow-web` is a
  first-party public client, standardFlowEnabled with no consent screen configured
  anywhere else in the realm, so a stray `true` here would be the one mapper
  introducing a consent prompt no other part of the realm expects.
- **`config."included.client.audience"`**: `"letflow-web"` — the standard
  `oidc-audience-mapper` config key that names a *client* (by client id, not
  internal UUID) whose own client id gets added as an `aud` entry. Set to
  `"letflow-web"` because that is both the client this mapper lives on and the
  `client_id` value `Oidcc.Token.validate_jwt/3` checks for (per
  `config/dev.exs`/`config/test.exs`'s `:oidc` config, confirmed unchanged by
  `req128-keycloak-dev-stack.md`'s "Correction after CODE-DESIGN-VALIDATOR PASS"
  section — only the client id changed to `letflow-web`, not pinned to any other
  value). This is the field that does the actual work here.
- **`config."included.custom.audience"`**: `""` — the standard sibling key
  (`oidc-audience-mapper` in stock Keycloak exposes exactly these two mutually
  exclusive "audience source" options: a client-id lookup via
  `included.client.audience`, or a free-text custom string via
  `included.custom.audience`). Left empty/unset is how Keycloak's own admin console
  and every stock realm-export emit this mapper when only the client-audience option
  is used — the key is present with an empty string rather than omitted, matching
  that stock export shape exactly so the JSON is recognizable as a normal Keycloak
  audience mapper rather than a hand-rolled one. Not a second audience source: only
  `included.client.audience` is populated, so only one `aud` entry
  (`"letflow-web"`) is ever added.
- **`config."id.token.claim"`**: `"false"` (string, matching every other boolean
  value in this file's `config` maps, which are all Java-style string
  `"true"`/`"false"` — see the existing `realm-roles` mapper's config for the
  established convention) — audience mappers conventionally apply to the access
  token only; ID tokens are consumed by the SPA for its own display/identity
  purposes and adding an audience claim there is unnecessary and, per standard
  Keycloak guidance, the default posture stock exports use. `Letflow.Oidc.TokenVerifier.Oidcc`
  validates the **access** token (`verify_bearer_token/2`, per the root-cause
  section above) — the ID token's `aud` claim (already populated by Keycloak by
  default with the client id, independent of any mapper) is untouched by this
  fix and was never the failing check.
- **`config."access.token.claim"`**: `"true"` — this is the field that actually
  causes the mapper to run against the access token, which is the token
  `Oidcc.Token.validate_jwt/3` rejects today. Must be `"true"` for this fix to have
  any effect.

### 2.2 Placement in the file

Full resulting `protocolMappers` array for `letflow-web` (for ELIXIR-DEV's reference —
not itself an instruction to add any other content):

```json
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
    "name": "letflow-web-audience",
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
```

Nothing else in `priv/keycloak/realms/bpm-default.json` changes: not `realm`, not
`roles`, not `users`, not the client's other top-level fields
(`publicClient`, `directAccessGrantsEnabled`, `standardFlowEnabled`,
`serviceAccountsEnabled`, `redirectUris`, `webOrigins`). This fix is scoped to
`letflow-web`'s `protocolMappers` array only — the realm has exactly one client, so
there is no other client to consider touching.

---

## 3. Correction note to append to `req128-keycloak-dev-stack.md`

That file's "Realm file" section (line ~146-150 as read on this branch) currently
reads:

> This is the mapper the requirement calls non-optional — without it the SPA
> gets zero roles silently. No audience mapper is added (R-Co's exists for its
> own resource-server client id check, which Letflow's `Oidcc`-based
> `TokenVerifier.Oidcc` does not require; adding one unasked would be scope
> creep — flag only, don't add).

ELIXIR-DEV should append a new `## Correction after ISS-0275 (2026-08-22)` section
to that file, after its existing "Correction after CODE-DESIGN-VALIDATOR PASS"
section, mirroring that section's own style (state what was wrong, what is actually
true, what changed) — content:

- The "No audience mapper is added ... does not require" sentence quoted above is
  **factually wrong** and is superseded by this fix. It was written on the
  (unverified) assumption that `Oidcc`'s token validation does not check `aud`; the
  opposite is true — `Oidcc.Token.validate_jwt/3` (`deps/oidcc/src/oidcc_token.erl`)
  unconditionally requires `aud` to contain the configured `client_id`, with no
  configuration flag to disable the check. This was not a deliberate library
  behavior this project chose to route around; it was an unverified claim about a
  dependency's behavior that turned out false the first time a real Keycloak-issued
  token was checked (ISS-0275).
  R-Co's own audience mapper existing for a *different* reason (its own
  resource-server client id check) does not mean Letflow's `Oidcc`-based verifier
  has no such requirement of its own — it does, independently, and this project's
  realm fixture needs the mapper regardless of R-Co's original reason for having
  one.
- State plainly that a mapper of type `oidc-audience-mapper` now exists on
  `letflow-web` (point at `lib/letflow/design/iss0275-audience-mapper-fix.md` §2 for
  the exact JSON and field-by-field rationale, rather than duplicating it inline).
- No other part of `req128-keycloak-dev-stack.md`'s design changes — this is an
  addendum note, not a rewrite; the realm name (`bpm-default`, per that file's own
  prior correction section), the five roles, the four seeded users, and the
  `realm-roles` mapper all stand as already documented.

---

## 4. Acceptance-criteria mapping

| Acceptance criterion (from ISSUE-FIXER's diagnosis / task) | Design element |
|---|---|
| Exact JSON to add to `letflow-web`'s `protocolMappers`, `protocolMapper: "oidc-audience-mapper"` | §2, full object given |
| `config` sets `included.client.audience` to `letflow-web` | §2, `config."included.client.audience"` |
| `id.token.claim: false` | §2, `config."id.token.claim": "false"` |
| `access.token.claim: true` | §2, `config."access.token.claim": "true"` |
| Standard Keycloak `oidc-audience-mapper` config key set gotten right (not free-form) | §2.1 — `included.client.audience` / `included.custom.audience` / `id.token.claim` / `access.token.claim`, the stock four keys this mapper type uses |
| Scoped to `letflow-web` client only, no other client touched | §2.2 — realm has exactly one client; explicit "nothing else changes" list |
| `req128-keycloak-dev-stack.md`'s superseded scope-note corrected with an addendum, mirroring its existing correction-section style | §3 |

## 5. Open questions

None. The fix is a single, fully-specified mapper object plus a documentation
addendum; no ambiguity remains for ELIXIR-DEV to resolve.
