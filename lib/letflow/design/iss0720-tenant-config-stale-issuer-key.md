# ISS-0720 — Fix `tenant_config.ex`'s stale `:issuer` config-key read and the
unscoped localhost IDP fallback

**Module:** `lib/letflow/routers/tenant_config.ex`
**Companion (config only, not a code-logic change):** `config/dev.exs`, `config/test.exs`
**Route to:** ELIXIR-DEV (Elixir library + config code, no migration/schema change)
**Related:** REQ-370 (design `req370-multi-issuer-oidc-verification.md` §6 — retired
`:issuer`), `docs/issues/ISS-0720.yaml`, `docs/issues/ISS-0719.yaml` (the live-QA
symptom this root-causes), `handoffs/WF03-ISS0720-20260919/step-01-issue-fixer-diagnosis.json`
(ISSUE-FIXER's diagnosis and recommendation, read in full before writing this design)

## 0. Root cause, restated precisely against the current code and config

Confirmed by direct read of `lib/letflow/routers/tenant_config.ex:312-325`,
`config/runtime.exs:130-169`, `config/dev.exs`, and `config/test.exs` (all cited in
ISSUE-FIXER's diagnosis, re-verified here rather than trusted from prose alone).

`idp_base_url/0` (private, `tenant_config.ex:312-316`):

```
System.get_env("BPM_IDP_BASE_URL") || System.get_env("KEYCLOAK_BASE_URL") ||
  oidc_issuer_base() || @default_idp_base_url
```

`oidc_issuer_base/0` (private, `tenant_config.ex:320-325`) reads
`Application.get_env(:letflow, :oidc, [])[:issuer]`. REQ-370 retired the `:issuer` key
everywhere — `config/runtime.exs`, `config/dev.exs`, `config/test.exs`, and
`config/prod.exs` all set only `:keycloak_base_url` (and `:client_id`) under
`:letflow, :oidc`; `:issuer` is set nowhere. So `Application.get_env(:letflow, :oidc,
[])[:issuer]` is always `nil`, `oidc_issuer_base/0` always returns `nil`, and the third
clause of `idp_base_url/0` is permanently dead. When both env vars are unset, this
collapses to the literal `@default_idp_base_url = "http://localhost:8082"` — ISS-0719's
live QA BLOCKER.

## 1. `oidc_issuer_base/0` — repoint to `:keycloak_base_url`, remove the `/realms/`
stripping logic

**This must be stated as two distinct changes, not one** — re-pointing the key alone is
not sufficient:

1. **Key rename.** Read `Application.get_env(:letflow, :oidc, [])[:keycloak_base_url]`
   instead of `[:issuer]`.
2. **Remove the `String.split("/realms/") |> List.first()` post-processing entirely.**
   That stripping logic exists only because the old `:issuer` value was a *full issuer
   URL* (`<base>/realms/<realm-slug>`), and the function needed to peel the realm suffix
   off to recover the bare host. `:keycloak_base_url` is not that shape — it is already
   a bare base URL with no `/realms/...` suffix, confirmed by:
   - `config/dev.exs:88-90`'s own comment: "REQ-370: keycloak_base_url replaces
     `:issuer` as the trust-resolution source", set as `"http://localhost:#{keycloak_port}"`
     — no `/realms/` segment.
   - `config/runtime.exs:141-146`'s comment: `Letflow.Oidc.ProviderRegistry` derives each
     realm's issuer *from* `keycloak_base_url` (`"#{keycloak_base_url}/realms/#{realm}"`),
     i.e. `keycloak_base_url` is upstream of any `/realms/` suffix, not downstream of it.
   - `config_map/2` (`tenant_config.ex:255`) already appends `"/realms/" <> realm_id`
     itself when building `oidc_authority` — so if `oidc_issuer_base/0` kept stripping a
     (now-absent) `/realms/...` suffix, at best it's inert dead code against the new
     key's shape; at worst, if any deployment's `keycloak_base_url` value ever legitimately
     contained the literal substring `/realms/` for an unrelated reason, the stripping
     would silently truncate a correct value. Removing it is strictly safer, not just
     simpler.

   Target logic for `oidc_issuer_base/0`, in words (no implementation code): look up
   `:keycloak_base_url` under `Application.get_env(:letflow, :oidc, [])`; if present,
   return it unchanged (still a `nil`-if-absent shape, so `idp_base_url/0`'s existing
   `||` chain keeps working exactly as before). No string manipulation on the value at
   all.

No change to this function's arity, name, or private visibility.

## 2. The `@default_idp_base_url` fallback question

### 2.1 What actually reaches the fallback after §1's fix — traced, not assumed

This matters for the decision below, so it is traced explicitly rather than left
implicit. After §1's fix, `oidc_issuer_base/0` returns whatever `:keycloak_base_url` is
set to in the running node's `:letflow, :oidc` application env. Tracing every config
path that can set it:

- `config/dev.exs` and `config/test.exs` each set it unconditionally to a real, working
  local value (`"http://localhost:#{keycloak_port}"` in dev; test.exs's own equivalent).
  Neither is ever `nil`.
- `config/runtime.exs`'s `:prod` block (`if config_env() == :prod do`, lines 103-169)
  sets it to `System.get_env("OIDC_KEYCLOAK_BASE_URL") ||
  derive_base_url_from_legacy_issuer.(System.get_env("OIDC_ISSUER")) ||
  "https://placeholder-keycloak.invalid"` — note this branch **already has its own
  always-non-nil fallback literal**, independent of `tenant_config.ex`.

So in every environment that goes through the normal config pipeline,
`:keycloak_base_url` — and therefore `oidc_issuer_base/0` after §1's fix — is **never
nil**. `tenant_config.ex`'s own `@default_idp_base_url` therefore becomes reachable only
when `Application.get_env(:letflow, :oidc, [])` itself is `[]` or lacks
`:keycloak_base_url` entirely — i.e. the `:letflow, :oidc` application env was never
populated at all. That is not a "real env var happens to be unset" case; it is a sign
that `config/runtime.exs`'s `:prod` block didn't run, or `dev.exs`/`test.exs` didn't
load — a release/boot defect at least as severe as, and likely the direct cause of, the
symptom this fallback would otherwise mask.

This finding **does not remove the need for a decision** (a degenerate-but-real boot
state can still occur — e.g. a future refactor that reorders config loading, or a
release built without `config/runtime.exs` participating) — but it does mean the
fallback's practical exposure is narrower than ISSUE-FIXER's diagnosis assumed, which
strengthens rather than weakens the case for failing loud: if this path is now hit, it
almost certainly indicates the whole `:oidc` config surface is missing, not a single
missing env var.

### 2.2 Decision: scope `@default_idp_base_url` to `Mix.env() in [:dev, :test]`
equivalent — fail loudly at call time everywhere else

**Agrees with ISSUE-FIXER's recommendation**, made concrete:

- **Do not use `Mix.env()` directly.** `Mix` is not available at runtime in a compiled
  release (this codebase's own established pattern — see
  `lib/letflow/repository/activation.ex`'s `@activation_test_hooks_enabled?`,
  `lib/letflow/scheduler/poller.ex`, and `lib/letflow/supervisor/pollers.ex`, all of
  which explicitly reject a runtime `Mix.env()` check in favor of a compile-time
  `Application.compile_env/3`-resolved module attribute, defaulting `false`, flipped to
  `true` only by `config/dev.exs`/`config/test.exs`). This fix must follow that same
  established pattern, not introduce a second, inconsistent way of distinguishing
  environments.
- **New module attribute** (private, compile-time, mirrors `activation.ex`'s shape
  exactly):
  `@allow_localhost_idp_fallback? Application.compile_env(:letflow, :allow_localhost_idp_fallback, false)`
  — resolved once at compile time into a literal `true`/`false`, default `false`.
- **Companion config change (not owned by this module, but required for dev/test to
  keep working unchanged):** `config/dev.exs` and `config/test.exs` each add
  `config :letflow, :allow_localhost_idp_fallback, true`. `config/prod.exs` and
  `config/runtime.exs` add nothing (the `false` default holds), matching
  `activation.ex`'s own "only `config/test.exs` sets it; dev/prod neither set it, so the
  default holds" precedent — here it's dev *and* test that opt in, prod that doesn't,
  but the mechanism is identical.
- **Behavior when `@allow_localhost_idp_fallback?` is `true`:** unchanged from today —
  `idp_base_url/0`'s last clause returns `@default_idp_base_url` exactly as it does now.
- **Behavior when `@allow_localhost_idp_fallback?` is `false`** (i.e. every environment
  except dev/test) **and no real value resolved from any of the three preceding
  clauses:** raise, at call time, instead of returning `@default_idp_base_url`. Target
  logic in words: where the current chain's last clause is `|| @default_idp_base_url`,
  replace it with a conditional — if `@allow_localhost_idp_fallback?` is `true`, use
  `@default_idp_base_url` as before; otherwise raise (e.g. via `raise/1` with a message
  naming the missing `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL`/`:keycloak_base_url`
  resolution chain), rather than returning a value at all. No new named function is
  required to express this — it is a conditional inside `idp_base_url/0`'s existing
  body.

### 2.3 Why call-time raise (not boot-time, not logged-error-with-default-retained) —
and the explicit reckoning with the moduledoc's "never error to the caller" rule

Three options were weighed, per the task's instruction to pick one and justify it
against the moduledoc's rule rather than let the rule silently block the decision:

1. **Raise at boot** (application start / release boot check) — rejected for *this*
   fix's scope. It would require new boot-sequence code (an `Application` callback or a
   `config/runtime.exs`-time check), which is a second module/file beyond
   `tenant_config.ex` and beyond "no new module unless genuinely required." §2.1's trace
   also shows this exact condition is already effectively boot-invariant in practice
   (the `:oidc` app env is either fully populated or fully absent for the life of the
   node) — a call-time raise fires on the very first request after boot, which is
   operationally equivalent to a boot-time check for this endpoint's traffic pattern
   (the login page is typically the first thing hit in any smoke test or real session),
   without adding new structure.
2. **Log `:error` and keep serving the literal default (belt-and-suspenders)** —
   rejected. This is the same failure mode ISS-0719 already demonstrated: a 200 with a
   plausible-looking body that a human has to notice in logs, separately from the actual
   symptom (browser `ERR_CONNECTION_REFUSED`). ISSUE-FIXER's diagnosis is direct on this
   point and this design agrees: three resolution layers already failed silently once;
   adding a fourth "silent-but-logged" layer repeats the same mistake in a slightly
   more observable way, not a structurally different one.
3. **Raise at call time, scoped by `@allow_localhost_idp_fallback?`** — **selected.**

**Reckoning with the moduledoc's rule directly** (§"The never-error rule is
LOAD-BEARING", `tenant_config.ex:35-56`): that rule is stated for, and its own two
justifications (availability; INV-5/anti-oracle) are both about, the **realm/tenant
resolution branch** — `resolve_realm/2` and the DB lookup it wraps
(`Identity.safe_get_tenant_by_slug/2`). Both justifications are about *per-request,
per-tenant* variability: a DB outage, an unknown slug, a malformed host — conditions
that differ request to request and tenant to tenant, where masking one bad lookup
behind the default config preserves availability for every *other* tenant's legitimate
request, and where a differentiated error response would leak which slugs are real
(INV-5/anti-oracle).

`idp_base_url/0`'s failure mode is not that shape. Once `:keycloak_base_url` is
unresolvable, it is unresolvable identically for **every** request, on **every**
tenant/slug, until the node is redeployed with correct configuration — there is no
per-request or per-tenant variability to preserve availability *across*, and no
tenant-existence signal to leak (the failure reveals a deployment defect, not
information about any specific tenant). Continuing to serve `localhost:8082` as a 200
doesn't protect any tenant's availability — every tenant is equally broken by it,
they just don't find out until a real browser's redirect fails, which is strictly worse
than finding out immediately via a failing request/health check. This is a deliberate,
narrow carve-out from the moduledoc's rule, scoped specifically to
IDP-base-URL resolution, not to the realm/tenant-resolution branch, which keeps its
existing never-error behavior entirely unchanged by this fix.

**Consequence, stated plainly:** in a non-dev/test environment with no real IDP base
URL resolvable, `GET /api/tenant-config` will 500 (via the unhandled raise propagating
through `Plug.Router`) on every request, for as long as the misconfiguration persists —
including temporarily breaking login-page rendering for that node, the exact outcome
reason 1 of the moduledoc's rule warns against. This design accepts that tradeoff
explicitly: a loud, immediate, whole-node failure that gets caught before real traffic
(deploy smoke test, health check, or the first real user within seconds) is judged
better than a quiet, plausible-looking 200 that gets caught only when a real user's
browser hits `ERR_CONNECTION_REFUSED` deep into an OIDC redirect — which is exactly what
happened in ISS-0719.

## 3. No new public function, module, or `@spec`

Both changes (§1, §2) are body-level changes to the two existing private functions
`oidc_issuer_base/0` and `idp_base_url/0`, plus one new private, compile-time-resolved
module attribute (`@allow_localhost_idp_fallback?`) of the same kind this codebase
already uses elsewhere (`activation.ex`'s `@activation_test_hooks_enabled?`). Neither
function's arity, name, or visibility changes. No new `def`, no new `@spec`, no new
module. The companion `config/dev.exs`/`config/test.exs` one-line additions are config,
not code structure.

## 4. Acceptance-criteria mapping

| Acceptance criterion | Design element |
|---|---|
| Design doc exists at `lib/letflow/design/iss0720-tenant-config-stale-issuer-key.md` | This file, at exactly that path, per `task.description` |
| Explicitly states the `:keycloak_base_url` key rename and removal of `/realms/` stripping | §1, both sub-points stated as two distinct changes |
| Explicitly decides and justifies the localhost-default fallback question, addressing the never-error rule directly | §2.2 (decision: dev/test-scoped, fail loud elsewhere) and §2.3 (the rule reckoning, not sidestepped) |
| No `.ex` implementation code bodies | Throughout — target logic given in words/pseudocode-free prose; the one code-shaped block in §0 quotes *existing* code for citation only, not proposed code |
| Fix to existing private functions only, no new public function/module/`@spec` unless justified | §3 — explicitly states none introduced and why the one new module attribute doesn't count as new structure |

## 5. Open questions (explicitly flagged, not silently resolved)

1. **`config/runtime.exs`'s own `"https://placeholder-keycloak.invalid"` fallback
   (line ~166) is a structurally identical unscoped-fallback problem, one layer up,**
   surfaced by §2.1's trace but **out of scope for this fix** — `runtime.exs` is not in
   `owned_modules` for this handoff, and its fallback is at least distinguishable from a
   real host by name (`placeholder-keycloak.invalid` cannot resolve, unlike
   `localhost:8082` which resolves to *something* on most dev/CI machines and therefore
   fails less obviously). Flagging for a follow-up issue rather than folding it into
   this fix's scope, since ISS-0720/ISS-0719 are both about `tenant_config.ex`
   specifically. **REVIEWER should confirm this scoping call is acceptable** rather than
   CODE-DESIGNER silently deciding runtime.exs is out of reach.
2. **Exact raise message/exception type** is left to ELIXIR-DEV's judgment (a plain
   `raise "..."` with `RuntimeError` is almost certainly sufficient — no custom
   exception module is warranted for a config-resolution failure that should never
   occur in a correctly deployed release) — not specified further here since it doesn't
   change the design's shape, only its exact wording.
3. **Test coverage implication for TEST-DESIGNER:** the raise branch needs a test that
   sets `Application.put_env(:letflow, :allow_localhost_idp_fallback, false)` (or
   confirms the compiled-in `test.exs` value some other way — compile-time attributes
   don't respond to `Application.put_env/3` after compilation, so TEST-DESIGNER will
   need to verify whether this is testable via ExUnit at all without a separate
   compile-time-flag-off build, or whether the raise path can only be asserted by
   reading the code + a manual/CI-config-level check). **Flagged as a real test-design
   constraint, not resolved here** — compile-time `Application.compile_env/3` attributes
   are deliberately immune to runtime overrides, which is the point of the pattern, but
   it does mean this specific branch may not be unit-testable in the conventional way in
   this same test suite.
