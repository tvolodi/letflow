# Fix Design — ISS-0719

Run-id: WF02-ISS0719-20260919
Type: single-file bugfix, no new public API, no migration, no schema change.
File touched: `lib/letflow/routers/tenant_config.ex`. Auth-adjacent config-resolution
path (see §5) — routed through the full WF-02 design/review pipeline, not ORCH's
direct-action exception (ORCHESTRATOR.md §10 check 5 fails: this changes a value every
browser trusts to redirect to an OIDC authority).

## 0. Root cause (verified by direct read, not just trusted from ISSUE-FIXER's summary)

Confirmed by reading `lib/letflow/routers/tenant_config.ex` lines 307-327 (as of
`10ca7a48`):

```
defp idp_base_url do
  System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
    oidc_issuer_base() ||
    @default_idp_base_url
end

defp oidc_issuer_base do
  case Application.get_env(:letflow, :oidc, [])[:issuer] do
    nil -> nil
    issuer -> issuer |> String.split("/realms/") |> List.first()
  end
end
```

Confirmed by reading `config/dev.exs` (~87-93), `config/test.exs` (~124-131),
`config/prod.exs` (~9-19), and `config/runtime.exs` (~131-170): REQ-370 retired the
`:oidc, :issuer` config key everywhere. Every config file now sets `:oidc,
:keycloak_base_url` instead (a bare host, e.g. `"https://auth.qa.bizdala.com"`, with
`Letflow.Oidc.ProviderRegistry.start_worker/2` building each realm's own issuer as
`"#{keycloak_base_url}/realms/#{realm}"` — confirmed at
`lib/letflow/oidc/provider_registry.ex` line 79 and the `keycloak_base_url/1` helper at
line 99). `Application.get_env(:letflow, :oidc, [])[:issuer]` is therefore always `nil`
in every environment, `oidc_issuer_base/0` always returns `nil`, and `idp_base_url/0`
falls through past `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL` (unset on QA — see §3) all
the way to the hardcoded `@default_idp_base_url = "http://localhost:8082"` (line 167).
That is exactly the value ISS-0719 observed live on QA. Root cause confirmed as stated.

## 1. Fix — exact change to `oidc_issuer_base/0`

Read `:keycloak_base_url` instead of `:issuer`, and **remove** the
`String.split(issuer, "/realms/") |> List.first()` post-processing entirely — it is not
a harmless no-op, it encodes a stale assumption (that the configured value is a full
issuer URL ending in `/realms/<slug>`) that no longer holds for any config file in this
repo. `:keycloak_base_url` is documented at its own definition site
(`config/dev.exs`'s comment: "No `/realms/...` suffix here") as already bare. Keeping
the split would be silently-correct-by-luck for any bare host with no `/realms/`
substring, but would silently produce a truncated, wrong value the moment a
`keycloak_base_url` value legitimately contained the substring `/realms/` earlier in
its path (unlikely today, but the split has no reason to exist once the input contract
changed) — leaving misleading code that documents the wrong shape for its own input is
exactly the kind of drift this issue already demonstrates.

New shape (signature/behavior spec, not literal implementation — see "Forbidden" in
this agent's own instructions):

- `oidc_issuer_base/0` — arity 0, private (`defp`), returns `String.t() | nil`.
  - Input: reads `Application.get_env(:letflow, :oidc, [])` and looks up the
    `:keycloak_base_url` key (via `Keyword.get/2` or equivalent — not `Keyword.fetch!/2`,
    since this function's whole contract is "return nil, let the caller fall through"
    when the key is absent; never raise).
  - Output: the raw configured value unchanged (already a bare base URL string, no
    further parsing/splitting/derivation) if present and a non-empty binary; `nil`
    otherwise (key absent, or `Application.get_env(:letflow, :oidc, [])` itself absent —
    matches the existing `[]` default already used at the call site).
  - No change to `idp_base_url/0`'s call site or precedence chain
    (`System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
    oidc_issuer_base() || @default_idp_base_url`) — see §3 for why the env-var names are
    explicitly left alone.

## 2. Moduledoc / comment updates (so this drift cannot silently recur)

Two stale-reference sites, both must be corrected:

1. **The comment immediately above `oidc_issuer_base/0`** (currently: `# Derive the IDP
   base URL from the compiled :oidc issuer, which is already set correctly via
   config/keycloak_port.exs for every workspace.`) is wrong on two independent counts:
   it names the wrong config key (`:issuer`, retired by REQ-370) and the wrong config
   source (`config/keycloak_port.exs` only supplies the *port* used to build
   `keycloak_base_url` in dev/test — it does not itself set `:oidc` config; prod/QA get
   `:keycloak_base_url` from `config/runtime.exs`'s `OIDC_KEYCLOAK_BASE_URL` env var, not
   from `keycloak_port.exs` at all). Replace with a comment stating: this reads
   `:oidc, :keycloak_base_url` (REQ-370's trust-resolution source, see
   `config/dev.exs`/`config/runtime.exs`'s own comments for the same key), which is
   already a bare host with no `/realms/...` suffix, so no further parsing is needed or
   performed; cross-reference this issue (ISS-0719) as the reason the old `:issuer`-based
   version was wrong, so a future reader who finds this function via `git blame` gets the
   full story without re-deriving it.

2. **`@default_idp_base_url`'s own comment block** (lines 156-166, the PROVENANCE
   comment referencing "R-Co's nginx gateway port... corrected under REQ-133... port
   8082, ... config/dev.exs :oidc client_id") does not itself name `:issuer` and does not
   need factual correction, but should gain one added sentence noting that this constant
   is now also the value QA fell all the way through to (ISS-0719) when the *only* other
   resolution path (`oidc_issuer_base/0`) was silently broken for months after REQ-370 —
   i.e., flag `@default_idp_base_url` as a last-resort fallback whose silent triggering
   in a non-dev environment is itself a signal something upstream is misconfigured, not
   a value that should ever be reached outside local dev. This is documentation only, no
   behavior change (do not turn this into a runtime warning/log call — out of scope, see
   §3's "smallest safe footprint" reasoning applies here too).

No change needed to the module's top-level `@moduledoc` (the long PROVENANCE narrative
at the top of the file) — that narrative documents the endpoint's *response contract*
(never-error rule, 3-key allowlist, `?host=`/`?realm=` precedence), which this fix does
not touch. Do not add unrelated narrative there; keep the correction scoped to the two
sites above.

## 3. Decision: `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL` env-var precedence in `idp_base_url/0`

**Decision: leave as-is. Do not rename, do not remove.**

Reasoning, applying the smallest-safe-footprint rule against ISS-0719's actual
acceptance criteria (QA's advertised authority resolves correctly; REQ-369 AC6/AC7
pass):

- Neither `BPM_IDP_BASE_URL` nor `KEYCLOAK_BASE_URL` matches the real runtime env var
  (`OIDC_KEYCLOAK_BASE_URL`, confirmed at `config/runtime.exs` line ~167) that actually
  drives `:oidc, :keycloak_base_url` today. That makes them dead code in the sense that
  no currently-documented deployment path sets either name — but "dead" is not the same
  as "actively harmful," and removing them is a strictly larger, riskier change than
  fixing `oidc_issuer_base/0`:
  - **Renaming** either to `OIDC_KEYCLOAK_BASE_URL` would make this endpoint's env-var
    read alias the *same* variable `config/runtime.exs` already reads into
    `:keycloak_base_url` at boot — which `oidc_issuer_base/0`'s fix (§1) already exposes
    via the compiled config lookup. A rename buys nothing new: after §1's fix, the value
    is already reachable through the third `||` branch every time
    `OIDC_KEYCLOAK_BASE_URL` is set. Adding a fourth, differently-named path to the same
    variable is duplication, not a fix.
  - **Removing** either name is an unrequested, unowned back-compat break: this file's
    own `git blame`/PROVENANCE style (see `@default_idp_base_url`'s own comment,
    correcting a stale R-Co port under REQ-133) shows this codebase treats removing an
    established override as its own decision, not a drive-by. Nothing in
    `docs/issues/ISS-0719.yaml`'s `acceptance_criteria`-equivalent scope (fix QA's wrong
    authority; unblock REQ-369 AC6/AC7) requires touching these names, and no other
    caller/deployment script reference was found for either name (a name being unused by
    the *current* runtime config does not prove no external deployment script sets it as
    a manual override — removing it without that audit is exactly the kind of
    unrequested widening ISS-0719's own scope note warns against).
  - **Keeping as-is** costs nothing: after §1's fix, `oidc_issuer_base()` correctly
    resolves the real QA authority via the compiled `:keycloak_base_url` (which itself
    now correctly reads `OIDC_KEYCLOAK_BASE_URL` per REQ-370/`config/runtime.exs`), so
    the precedence chain resolves correctly regardless of whether
    `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL` are ever set. They remain available as a
    higher-precedence manual override for an operator who might still set them (e.g. an
    emergency override that bypasses the compiled OIDC config entirely without a
    redeploy) — a strictly more flexible, strictly lower-risk state than either
    alternative.
- This is a live BLOCKER; the fix that resolves it with the fewest moving parts is
  correct `oidc_issuer_base/0` alone (§1). A rename/removal of the two legacy env-var
  names is an independent cleanup with its own (much smaller) blast radius and belongs
  in its own later requirement if anyone wants it — flagging it here as an **open
  question for a follow-up requirement, not for this fix**, is different from punting an
  in-scope question; ISS-0719's own acceptance criteria do not ask for an env-var audit,
  so scoping it out is the conservative call, not an evasion of one.

## 4. Test-env compatibility (verified, not assumed)

Verified directly, `config/test.exs` line ~127:

```
{keycloak_port, _bindings} = Code.eval_file(Path.expand("keycloak_port.exs", __DIR__))

config :letflow, :oidc,
  keycloak_base_url: "http://localhost:#{keycloak_port}",
  ...
```

Verified `config/keycloak_port.exs` resolves `keycloak_port` to `8082` by default in
this workspace (same default port `@default_idp_base_url` already hardcodes as
`"http://localhost:8082"`).

Consequence: under default local config, `keycloak_base_url` == `"http://localhost:8082"`
== `@default_idp_base_url`. Switching `oidc_issuer_base/0` from `:issuer` to
`:keycloak_base_url` therefore changes `oidc_issuer_base/0`'s return value from `nil`
(today, always) to `"http://localhost:8082"` (post-fix) in the test environment — a
change in *which branch of the `||` chain fires*, but not in `idp_base_url/0`'s final
returned value, since the previously-reached `@default_idp_base_url` fallback is
byte-identical to the newly-reached `oidc_issuer_base()` value. No existing assertion in
`test/letflow/routers/tenant_config_test.exs` should change:

- Line 40 (`@expected_keys`) and lines 80-92 (AC1: exact 3-key shape,
  `config_map/2` source-quoted assertions) — unaffected; §1's change does not touch
  `config_map/2`'s own source lines, only `oidc_issuer_base/0` (a different function,
  quoted nowhere in that test).
- Lines 146-153 — `body_unknown["oidc_authority"] =~ "/realms/bpm-default"` and
  `refute body_resolvable["oidc_authority"] =~ "/realms/bpm-default"` check the
  **realm** suffix (`idp_base_url() <> "/realms/" <> realm_id`), not the base-url
  portion this fix changes. `idp_base_url()`'s numeric value
  (`"http://localhost:8082"`) is unchanged post-fix per the equivalence above, so these
  assertions hold unchanged.
- `test/letflow/routers/req078_supporting_routes_test.exs` lines 274-275
  (`Map.keys(body) |> Enum.sort() == ["branding", "client_id", "oidc_authority"]` and
  `is_binary(body["oidc_authority"])`) — shape-only assertions, unaffected.

**New/updated assertions TEST-DESIGNER should add** (this fix has no existing
regression test that would have caught ISS-0719, since test-env's `keycloak_base_url`
and the hardcoded default happen to coincide — the bug is invisible under default local
config, which is exactly how it shipped unnoticed):

1. A unit-level test that sets `Application.put_env(:letflow, :oidc, keycloak_base_url:
   "https://auth.qa.bizdala.com", ...)` (saving/restoring the prior env, or using
   `ExUnit.Callbacks.on_exit/1`) and asserts `GET /api/tenant-config`'s
   `oidc_authority` reflects `"https://auth.qa.bizdala.com/realms/<realm>"` — proving
   `oidc_issuer_base/0` actually reads the live compiled value rather than coincidentally
   matching the default. This is the test that would have failed pre-fix (returns
   `"http://localhost:8082/realms/..."` regardless of the configured
   `keycloak_base_url`) and passes post-fix — the fail-then-pass regression proof WF-03
   Step 4 / this project's test-design convention requires.
2. A negative check that `oidc_issuer_base/0`'s old `:issuer`-keyed lookup is gone:
   assert that setting `Application.put_env(:letflow, :oidc, issuer: "http://some-other-host/realms/x", keycloak_base_url: nil)`
   does **not** cause `oidc_authority` to derive from `"http://some-other-host"` —
   confirms the retired key is truly ignored, not silently still load-bearing via some
   other path.
3. (Optional, low-value) A source-grep-style assertion, matching this file's own
   established convention (`config_map/2 is the sole, hand-built constructor -- quoted
   verbatim from source` at test line 88-95), that `lib/letflow/routers/tenant_config.ex`
   no longer contains the string `[:issuer]` and does contain `[:keycloak_base_url]` —
   guards specifically against this exact class of drift recurring silently.

## 5. Security-review scope determination

**This qualifies as a tenant-data-path / security-relevant change requiring
SECURITY-REVIEWER sign-off, even though it is a single-file, no-new-endpoint,
no-schema fix.**

Reasoning, per the module's own moduledoc framing (quoted directly, not
paraphrased-away):

- The moduledoc's own "never-error rule is LOAD-BEARING" section frames this endpoint's
  entire purpose as **INV-5**/anti-oracle-relevant server behavior, and its "What this
  endpoint discloses" section states the `oidc_authority` value is one of exactly three
  disclosed fields that "the browser must learn... before authenticating" — i.e., this
  is the value that determines where every unauthenticated browser's credentials
  ultimately get exchanged. Getting it wrong (as ISS-0719 demonstrates) is not a display
  bug; it silently redirects every real login attempt to a URL nothing is listening on,
  which is a live availability/security incident, not a cosmetic defect.
- Against `docs/agents/instructions/security-invariants.md`'s own two most relevant
  invariants:
  - **INV-2 (server-side field authorisation)** — not directly triggered (no new field,
    no changed authorization boundary), but the invariant's underlying concern —
    "an unauthorised value must never leave the server" — has a mirror-image failure
    mode here: a *misconfigured-correct-shaped* value leaving the server. The endpoint's
    field-disclosure contract (exactly 3 keys, INV-2-adjacent) is unchanged by this fix,
    but the **value** inside one of those 3 keys is exactly what was wrong, and that
    value is what every client trusts unconditionally with zero server-side
    cross-check on the client side (by design — this is the pre-auth bootstrap call).
  - **INV-4 (secrets by reference only)** — not a secrets-handling defect (an OIDC
    authority URL is not secret material, and the fix does not introduce or touch any
    `System.get_env`/logging pattern beyond what's already there), but INV-4's general
    posture — resolve trust-relevant configuration correctly, at the point of use, from
    environment/config, never hardcode or silently fall back to a wrong value in a
    non-dev environment — is precisely the property this bug violated: a real deployment
    silently fell through to `@default_idp_base_url`, a literal local-dev value, with no
    signal to anyone that this had happened.
- Precedent in this same file: the module's own moduledoc already treats every field in
  this response as **security-relevant enough to warn against a "fourth key... is a
  security change, not a feature"** framing (line 78-79 of the file). A change to the
  **value** of one of the three existing keys' resolution logic is not of a lesser kind
  than a change to the key set — both affect what a pre-auth caller learns and trusts.

**Conclusion: route through SECURITY-REVIEWER before REVIEWER, per the standard WF-02
gate order** (this is not a request to skip either gate — see §"Scope" above: this is a
single-file change with no schema/migration, so it is fast to review, but "fast to
review" and "exempt from review" are different things given the endpoint's own
moduledoc framing).

## 6. Summary of the complete change set for ELIXIR-DEV

1. `oidc_issuer_base/0` (lib/letflow/routers/tenant_config.ex ~320-325): read
   `Application.get_env(:letflow, :oidc, [])[:keycloak_base_url]` in place of
   `[:issuer]`; return it unchanged (no `String.split/2`/`List.first/1` post-processing)
   when present and non-empty; `nil` otherwise. No other line in this function's
   signature or arity changes.
2. Comment directly above `oidc_issuer_base/0` (~318-319): rewritten per §2.1.
3. `@default_idp_base_url`'s comment block (~156-166): one added sentence per §2.2.
4. `idp_base_url/0` (~312-316): **unchanged** — precedence chain, both env-var names,
   and the final `@default_idp_base_url` fallback all stay exactly as they are (§3).
5. No change to `config_map/2`, `branding_map/1`, `resolve_realm/2`, the top-level
   `@moduledoc`, or any other function in this file.
6. No migration, no new Ecto schema field, no new public function, no new route.

## 7. Open questions

None left unresolved for this fix's own scope. The env-var rename/removal question
(§3) is explicitly decided (leave as-is), not deferred. A possible future cleanup
requirement to rationalize `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL` against
`OIDC_KEYCLOAK_BASE_URL` is noted as out-of-scope follow-up work, not an open question
blocking this fix.
