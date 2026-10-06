# ISS-0995 -- authorization-denial attribution log line (design)

Run `WF03-Q976-20261006` / queue Q-976 / GH #2257 / issue record `docs/issues/ISS-0995.yaml`.
Owner of the build: ELIXIR-DEV. Gates: SECURITY-REVIEWER (INV-4 is the load-bearing invariant,
INV-5 and INV-10 are touched but must stay byte-for-byte unchanged), REVIEWER, TEST-DESIGNER.

Design only: signatures, type shapes, formats and a test plan. No implementation code.

---

## 0. Problem, scope, root cause

`Letflow.Plugs.Authorize.call/2` is the single place an authorization policy denial is turned into a
403 (`case decision.kind do :Deny403 -> Response.forbidden(...)`). It logs nothing (its moduledoc
says "Nothing is logged here"). PR A2 (Q-960) deleted the A1 `platform_scope_shadow_deny` line, which
carried the policy key and one boolean, and added nothing. Result: a denial cannot be attributed to
a request, a caller or a tenant after the fact (UAT and incident review had to match by call timing).

Required (issue text): ONE structured log line on every authorization denial (platform and tenant
scope) with the HTTP method, the route PATTERN, the policy key, the platform-scope boolean, and a
keyed hash of the caller id and of the tenant id, under INV-4 (no token, email, raw tenant id,
secret), with the hash key a config secret (not a literal), plus sampling for repeated denials.

Root cause is a feature gap, not a defect: no other code path is wrong. Diagnosis:
`handoffs/WF03-Q976-20261006/step-01-issue-fixer-diagnose.json`.

### Scope boundary (state it so nobody widens it later)

IN scope: every `:Deny403` outcome of `Authorization.evaluate_access/2` as consumed by
`Letflow.Plugs.Authorize.call/2`. That covers, with one code path: a platform-scope permission denied
(INV-10), a tenant-scope permission denied (role lacks the permission), `:Unknown` (route with no
policy key), `:UnmatchedPlatformPath` and `:UnmatchedRoute` (router catch-all markers, denied for
non-operators).

OUT of scope (not changed, not logged by this issue):
* The 500 branch (`Context.scoped_repo_opts/1` error) -- not a denial.
* Handler-level 403s (`Response.forbidden/2` called from routers for business rules such as
  "a reviewer cannot approve their own promotion request", task-assignment mismatches, promotion
  `:forbidden`). They are not policy-key denials and carry domain detail of their own.
* `lib/letflow/routers/entities.ex` `check_unredacted_permission/2`, the only other caller of
  `evaluate_access/2`: its `:Deny403` becomes `{:error, :unredacted_not_authorized}`, a handler
  response, not this plug's 403. Left alone; see Open question OQ-1 (informational).
* 401s from `AuthPipeline` (no identity yet; nothing to attribute with an id hash).
* Telemetry/metrics (decision 8).

---

## 1. Decisions (all eight recommended answers adopted, two refinements with evidence)

| # | Decision | Verdict |
|---|---|---|
| D1 | New module `Letflow.Api.AuthzDenyLog` (`lib/letflow/api/authz_deny_log.ex`); ONE call from the `:Deny403` branch of `Authorize.call/2`, before `Response.forbidden/2`. `Authorization.evaluate_access/2` and the response are not touched. | adopted |
| D2 | Key = derived sub-key `HMAC-SHA256(master_key, "letflow/authz-deny-log/v1" <> <<1>>)`; no new env var, no boot failure, no `runtime.exs` change. | adopted |
| D3 | Hash = `HMAC-SHA256(subkey, "user:" <> id)` / `"tenant:" <> id`, lowercase hex, first 16 chars. | adopted |
| D4 | Route pattern from `conn.private[:plug_route]`, guarded by `Map.has_key?`, `"unmatched"` when absent, trailing catch-all kept, printable allow-regexp. | adopted **with one refinement (R1 below, evidence-driven)** |
| D5 | Method allow-list; policy key atom guard; `platform_scope` boolean with explicit marker mapping; additionally log `caller_platform_tenant`. | adopted |
| D6 | `Logger.warning`, one line, fixed message in `key=value` form AND the same fields as metadata. | adopted |
| D7 | Sampling by 4096-slot `:atomics` pair in `:persistent_term`, lazy, CAS-guarded, window 60 s, 0 disables. | adopted **with one refinement (R2 below)** |
| D8 | No telemetry in this change. | adopted |

### R1 -- the composed route template contains the `forward` glob; normalise it (deviation from the recommendation's premise)

The task text (and `Letflow.Plugs.HttpMetrics`' moduledoc) assume `Plug.Router.match_path/1` returns
`"/api/v1/instances/:id"` inside a forwarded router. VERIFIED to be false for a nested router, by
running a two-level `Plug.Router` against this repo's compiled plug (`deps/plug` 1.20.3):

    request GET /api/v1/instances/SECRET-1  ->  match_path = "/api/v1/*glob/instances/:id"
    request GET /api/v1/zzz/SECRET-2        ->  match_path = "/api/v1/*glob/*_path"

Cause: the `forward/2` macro (`deps/plug/lib/plug/router.ex:473-500`) compiles `match path <> "/*glob"`,
so the forward clause itself records `path <> "/*glob"` via `__put_route__/3`, and
`append_match_path/2` (`router.ex:523-525`) concatenates the child route onto it. In Letflow the chain
is `Letflow.Router` -> `forward "/api/v1"` -> `ApiPipeline` -> `forward "/tenants"` -> sub-router, so a
real tenant route has the template `"/api/v1/*glob/tenants/*glob/:slug"`.

Is request text ever in the template? NO. Every segment is either a literal written in router source
at compile time, a `:name` parameter placeholder, or the literal `*glob` / `*_path` wildcard NAME. Plug
records the pattern (the compile-time `path` binding), never the matched `conn.path_info` segments;
the forward glob's matched value goes to `Plug.forward/4` as a separate argument and is not stored in
`:plug_route`. The empirical run above shows `SECRET-1` / `SECRET-2` absent from the template.

Refinement: `route_pattern/1` removes every `"/*glob"` substring (the forward artefact; no Letflow route
declares a `*glob` of its own -- grep of `lib/letflow/routers`, `lib/letflow/router.ex`,
`lib/letflow/plugs`, `lib/letflow/modules` for `/\*[a-z_]+` returned only HttpMetrics comments), giving
`"/api/v1/tenants/:slug"` and, for a router catch-all, `"/api/v1/tenants/*_path"` (the catch-all
`"/*_path"` is KEPT, see D4 below). Without the refinement the field would be correct but unreadable and
would differ between the unit-test form (`"/:slug"` when a sub-router is called directly) and the
runtime form. HttpMetrics is NOT changed (out of scope; its tests use a single non-nested router so
they are unaffected). SECURITY-REVIEWER may want a follow-up note that HttpMetrics' `route_template`
label also carries `*glob` in production (cardinality-safe, cosmetic): see OQ-2.

### R2 -- timestamps are wall-clock seconds, not monotonic

`System.monotonic_time/1` can be negative on the BEAM, which collides with the "0 = never emitted"
slot sentinel. Use `System.system_time(:second)` (always positive) and treat a clock that moved
backwards (`now < last`) as "window elapsed" (emit). A backwards NTP step then costs at most one extra
line per slot; it can never silence a slot for longer than one window. See section 6.

---

## 2. Public surface -- `Letflow.Api.AuthzDenyLog`

File: `lib/letflow/api/authz_deny_log.ex` (new). Pure helpers are public with `@doc false`-style
"exposed for tests" docs so the algorithm can be pinned by tests; nothing outside `Authorize` and the
tests calls them.

    @type policy_key :: atom()
    @type hashed_id :: String.t()            # exactly 16 chars of [0-9a-f], or the literal "none"
    @type fields :: %{
            method: String.t(),              # allow-listed token or "OTHER"
            route: String.t(),               # sanitised pattern or "unmatched"
            policy: String.t(),              # printable atom name or "unknown"
            platform_scope: boolean(),
            caller_platform_tenant: boolean(),
            caller: hashed_id(),
            tenant: hashed_id()
          }

    @spec log_denial(Plug.Conn.t(), Letflow.Api.Authorization.AccessContext.t(), policy_key()) :: :ok
    @spec build_fields(Plug.Conn.t(), Letflow.Api.Authorization.AccessContext.t(), policy_key()) :: fields()
    @spec format_message(fields(), non_neg_integer()) :: String.t()
    @spec metadata(fields(), non_neg_integer()) :: keyword()
    @spec hash_id(:user | :tenant, term(), binary()) :: hashed_id()
    @spec subkey() :: binary()                         # 32 bytes
    @spec route_pattern(Plug.Conn.t()) :: String.t()
    @spec method_token(term()) :: String.t()
    @spec policy_token(term()) :: String.t()
    @spec platform_scope?(policy_key()) :: boolean()
    @spec reset() :: :ok                               # TEST ONLY (@doc false): zero sampler + clear one-time flags

Contract of `format_message/2` and `metadata/2` (both pure, same arguments: the `fields()` map and the
suppressed count `n`, the number of denials withheld since the previous emitted line for the slot):
* `format_message/2` returns the section-6 message; the trailing `" suppressed=<n>"` is present only when
  `n > 0`.
* `metadata/2` returns a keyword list with atom keys in this fixed order: `authz_method`, `authz_route`,
  `authz_policy`, `authz_platform_scope`, `authz_caller_platform_tenant`, `authz_caller`, `authz_tenant`,
  and, ONLY when `n > 0`, a final `authz_suppressed` (positive integer). Values are exactly the
  corresponding `fields()` values (strings and booleans), nothing else.
* `log_denial/3` emits `Logger.warning(format_message(f, n), metadata(f, n))`, so message and metadata
  cannot drift; test (a) compares them by calling both functions on one `fields()` map and by checking a
  captured event.

Contract of `log_denial/3`:
* Always returns `:ok`. It never raises, never exits, never throws into the request process (section 8).
* Called exactly once per `:Deny403`, before `Response.forbidden/2`, with the `AccessContext` the plug
  already built and the resolved `policy_key` (including the `:Unknown` default and the two markers).
* Has no effect on `conn` (it does not receive or return one beyond reading it). The caller's 403 bytes
  cannot change.
* Reads only: `conn.method`, `conn.private[:plug_route]`, `conn.assigns.auth_context.tenant_id` (the
  database-resolved tenant the plug already validated via `Context.scoped_repo_opts/1`), `ctx.user_id`,
  `ctx.platform_tenant?`, `policy_key`. It never reads `conn.request_path`, `conn.path_info`,
  `conn.query_string`, `conn.params`, `conn.body_params`, `conn.path_params`, `conn.req_headers`,
  `conn.remote_ip`.

The caller's "tenant" is the caller's own database-resolved tenant (`auth_context.tenant_id`), never the
tenant addressed by a path or body value (INV-10: a path value never selects the tenant; that value is
not logged either).

### Change to `Letflow.Plugs.Authorize`

In the `:Deny403` branch only: `AuthzDenyLog.log_denial(conn, ctx, policy_key)` as the first expression,
then the existing `Response.forbidden("insufficient permissions") |> halt()` unchanged. Add the alias.
Replace the moduledoc sentence "Nothing is logged here: the denial response carries no tenant id, role
or token." with a paragraph stating: every `:Deny403` emits one attribution line through
`Letflow.Api.AuthzDenyLog` (fields, hashed ids, sampling, INV-4 safety); the response is still identical.
No other function in `authorize.ex` changes; the allow branch gains nothing.

---

## 3. Key source and hashing (D2, D3)

### Key

    subkey = HMAC-SHA256(key = master, data = "letflow/authz-deny-log/v1" <> <<1>>)     (32 bytes)
    master = Application.get_env(:letflow, :secrets_master_key)   # 32 raw bytes, validated at boot in EVERY env

This is exactly HKDF-Expand (RFC 5869) with `L = 32`, `PRK = master`, `info = label`, i.e.
`T(1) = HMAC(PRK, info || 0x01)`. Domain separation by `label` means the master key is never used
directly as a MAC key and the derived key is useless for `Letflow.Secrets` envelope encryption, and
vice versa. The label embeds `v1` so the algorithm can be rotated by changing the constant.

Why this source, with evidence:
* `config/runtime.exs:30-72` reads `LETFLOW_SECRETS_MASTER_KEY`, rejects absent/malformed/all-zero/
  all-0xFF values in every environment, and does `config :letflow, :secrets_master_key, <32 bytes>`;
  `Letflow.Secrets` reads it with `Application.fetch_env!(:letflow, :secrets_master_key)`
  (`lib/letflow/secrets.ex:446-448`). So a validated 32-byte secret is already present at runtime in
  every environment, including test/CI.
* It satisfies the issue's "the hash key must be a config secret, not a literal" without a new env var,
  without a new boot failure, and without touching `config/runtime.exs`.
* The login-directory pepper (`LETFLOW_LOGIN_DIRECTORY_PEPPER*`, REQ-435, decisions 0042/0043) is a
  separate, rotating, tenant-directory pepper pair: it must NOT be reused (different purpose, has a
  `_PREVIOUS` rotation semantics that would silently change log hashes), and nothing is added to it.

Rotation note (accepted limitation): hashes are stable for the lifetime of the master key. A master-key
change changes every hash, so correlation across a key change is lost. Logs are an operational, short
retention signal; this is acceptable and is stated in the moduledoc.

### Derivation cadence: compute per call, do not cache (decision)

Computed on every `log_denial/3` that reaches the emit path (one extra HMAC over 26 bytes, microseconds,
on a path that already did a database lookup and is about to serialise a response). Not cached in
`:persistent_term` because:
1. tests change `Application.put_env(:letflow, :secrets_master_key, ...)` to prove the hash depends on
   the key (test (e)); a cache keyed by label would serve a stale key and need invalidation machinery;
2. `:persistent_term.put` on replacement triggers a global GC scan; adding it for a sub-microsecond
   saving on a cold path is a bad trade;
3. there is no hot path: sampling (section 6) already bounds emit-path calls, and suppressed denials
   skip hashing the log fields entirely (the sampler key still needs the two hashes, i.e. two HMACs;
   see section 6 for why that is required and cheap).

Net per-denial cost: 1 sub-key HMAC + 2 id HMACs, each a single SHA-256 block-pair on tiny input.

### Fallback (defensive only; cannot happen after a successful boot)

If `Application.get_env(:letflow, :secrets_master_key)` is not a 32-byte binary (it cannot be: boot
fails first): use a per-boot random 32-byte key, created lazily with `:crypto.strong_rand_bytes/1` and
stored in `:persistent_term` under `{Letflow.Api.AuthzDenyLog, :fallback_key}` (race tolerant: a lost
race means two nodes-of-one-VM briefly derive from different keys; the later `put` wins; harmless for a
correlation pseudonym). Emit ONE notice per VM boot, text exactly `"authz deny log hash key fallback in
use"`, no metadata, no key material, no id. The sub-key is then derived from the fallback key with the
same label, so `subkey/0` has one code shape. `reset/0` erases the fallback key and its one-time flag.

### What is hashed (D3)

    hash_id(kind, id, subkey):
      id is a non-empty binary   -> HMAC-SHA256(subkey, tag(kind) <> id) -> Base.encode16(lowercase) -> first 16 chars
      anything else (nil, "", integer, atom, map, ...) -> "none"
    tag(:user)   = "user:"
    tag(:tenant) = "tenant:"

* Domain-separated: the same UUID string hashed as a user and as a tenant yields different values (M7).
* The id is never coerced with `to_string/1`, `inspect/1` or interpolation: only a binary is hashed
  (it is the HMAC input, never the output). A non-binary id renders `"none"`. (The decision text allowed
  "to_string for binaries/UUID strings"; a binary needs no coercion, so there is no coercion at all.)
* Output length: 16 hex = 64 bits, truncated from the 256-bit MAC.
  Justification: the value is a correlation pseudonym, not an authenticator. 64 bits keeps lines short
  (the line already has 7 fields), makes an accidental collision between two real ids negligible at this
  system's scale (birthday bound about 2^32 distinct ids), exceeds the NIST SP 800-107 minimum
  truncated-MAC length, and gives a reader less material than a full digest (an offline guesser without
  the key learns nothing either way). A full digest would not make the line any safer: the safety comes
  from the key, not the length. A 64-bit space is also what a 4096-slot sampler needs (section 6).

---

## 4. Route pattern (D4, with R1)

`route_pattern(conn)`:
1. If `Map.has_key?(conn.private, :plug_route)` is false -> `"unmatched"`. (HttpMetrics precedent:
   `Plug.Router.match_path/1` does `Map.fetch!` and RAISES when absent; the plug unit tests call
   `Authorize.call/2` directly with no router, so the key is absent there. That is the only reachable
   absent case.)
2. Else `template = Plug.Router.match_path(conn)`; remove every `"/*glob"` substring (R1); the result is
   the pattern. A trailing `"/*_path"` (a router's own `match _` catch-all, which `Plug.Router`
   rewrites from `_` at `router.ex:663`) is KEPT, e.g. `"/api/v1/tenants/*_path"`. Reasoning: it is a
   compile-time literal, bounded in cardinality (one per router), and strictly more informative for the
   marker denials (`:UnmatchedPlatformPath` / `:UnmatchedRoute`) than collapsing to `"unmatched"`; the
   operator can tell WHICH router's catch-all denied. (HttpMetrics collapses it because it needs ONE
   label value for cardinality of a metric; a log field does not have that constraint.)
3. Sanitise: emit only if it matches `~r/\A[\x21-\x7E]{1,200}\z/` (printable ASCII, no space, no CR/LF/
   TAB/NUL/control/non-ASCII, length 1..200); otherwise `"unmatched"`. This is defence in depth: by
   construction the template is a compile-time literal (see R1), and the regexp makes a future change
   (a macro that interpolates something unexpected) fail safe rather than inject into a log line.
4. Wrapped by the section-8 `try`; any exception yields `"unmatched"` for this field only.

Can the pattern ever contain request-derived text? No: (a) it is the template bound at compile time by
the route macro; (b) `forward`'s glob VALUE is passed to `Plug.forward/4`, not recorded; (c) `*glob` /
`*_path` are names, not values; (d) `Plug.Conn.put_private(:plug_route, ...)` is only written by
`Plug.Router.__put_route__/3`. Test (d) proves it end to end with a unique path value.

---

## 5. Remaining fields (D5)

### method

`method_token(m)`: `m` is a binary in the exact set `GET POST PUT PATCH DELETE HEAD OPTIONS` -> itself;
anything else (`PURGE`, lower-case, a 5 KB string, CRLF, non-binary) -> `"OTHER"`. `conn.method` is
client-supplied (Bandit accepts arbitrary tokens; `authz_unmatched`'s `match _` catch-all has no `via:`
so any method reaches `Authorize`), so it is never logged raw.

### policy

`policy_token(key)`: if `is_atom(key)` and `Atom.to_string(key)` matches `~r/\A[\x21-\x7E]{1,200}\z/` ->
that string, else `"unknown"`. The key is the route macro's compile-time literal atom
(`conn.private[:policy_key]`) or the plug's own `:Unknown` default; `Atom.to_string/1` allocates no atom
(it renders an existing one). Never `String.to_atom`, never derived from the request.

### platform_scope (boolean)

`platform_scope?(key)`:
* `:UnmatchedPlatformPath` -> `true` (explicit clause).
* `:UnmatchedRoute` -> `false` (explicit clause).
* `:Unknown` -> `false` (explicit clause).
* any other key -> `Authorization.permission_scope(Authorization.required_permission(key)) == :platform`.
* any raise inside -> `true` (fail closed, same default as `permission_scope/1`'s own "any other term is
  platform" rule).

Why the explicit clauses (verified, `lib/letflow/api/authorization.ex`): `required_permission/1` is TOTAL
(final clause `def required_permission(endpoint), do: endpoint`; clause 1208 maps `:Unknown` to
`:MetricsRead`) and `permission_scope/1` is TOTAL ("ANY OTHER term is `:platform`"), so neither raises
for any atom. But for the two markers the fallthrough would return the marker itself, which is not in
the scope table nor `Catalog.permissions/0`, hence `:platform` for BOTH markers -- wrong for
`:UnmatchedRoute` (ordinary routers; the decision rule is "PLATFORM_ADMIN of any tenant may reach the
404", a tenant-scope-like rule). `:Unknown` maps to `:MetricsRead` (a tenant permission) and is stated
explicitly so a future table edit cannot flip it silently. `platform_scope` therefore means "the policy
being enforced is platform-scope", not "the route is under a platform prefix" (OQ-3 records that this is
the chosen meaning).

### caller_platform_tenant (boolean)

`ctx.platform_tenant?` as computed by the plug (`PlatformTenant.platform_tenant?/1` on the DB-resolved
tenant; never the stored cache flag). `== true` is required to render `true`; anything else renders
`false`. It was in the A1 line and explains the dominant denial class (non-operator caller on a
platform-scope policy). It reveals nothing about the caller beyond what the platform-scope boolean plus
roles already imply to an operator.

---

## 6. Log shape (D6)

`Logger.warning/2`, exactly one call per emitted denial.

### Message (fixed grammar, space-separated `key=value`, values contain no space/CR/LF by construction)

    authz_deny method=<M> route=<R> policy=<P> platform_scope=<true|false> caller_platform_tenant=<true|false> caller=<16hex|none> tenant=<16hex|none>

and, only when the sampler reports `n > 0` events withheld since the previous line for this slot,
`" suppressed=<n>"` appended (integer, no padding). Example:

    authz_deny method=GET route=/api/v1/tenants/:slug policy=TenantsManage platform_scope=true caller_platform_tenant=false caller=3fa91c07be2d4a10 tenant=9b0c55e1a7d3f642

`route` and `policy` contain no space (`[\x21-\x7E]` excludes 0x20), so `key=value` tokenising is
unambiguous; `=` inside a route (no Letflow route has one) would not break a `key=` prefix parser.

### Metadata (same facts, structured)

    [authz_method: String.t(), authz_route: String.t(), authz_policy: String.t(),
     authz_platform_scope: boolean(), authz_caller_platform_tenant: boolean(),
     authz_caller: hashed_id(), authz_tenant: hashed_id()]   # + authz_suppressed: pos_integer() only when n > 0

Why message AND metadata (both, deliberately):
* Production/dev format with `Letflow.Obs.Logger` (`config/dev.exs:154`, `config/prod.exs:46`), which
  emits `message` plus every non-reserved metadata key as a JSON field (`encode_entry/3`). The metadata
  gives queryable fields (`authz_caller = "3fa9..."`) with no regex over the message.
* Test env keeps the default console formatter (`config/test.exs` has no logger formatter) and
  `ExUnit.CaptureLog` renders the MESSAGE only (metadata is not printed unless a `:metadata` format is
  configured); and the Elixir default formatter silently drops list/map metadata. The message therefore
  must be self-sufficient so `capture_log` assertions (and a human reading a plain console) see every
  field.
* The two are generated from the SAME `fields()` map in one place (`format_message/2` and a
  `metadata/2` builder), so they cannot drift; a test asserts equivalence (test (a)).

Name safety (verified `lib/letflow/obs/logger.ex`, `lib/letflow/secrets/redaction.ex`):
* Reserved formatter fields are `timestamp level trace_id component message`; none of the `authz_*`
  names collides, so no `formatter_violation` warning is raised.
* Redaction (`Letflow.Secrets.Redaction`) redacts exact keys `authorization password password_hash token
  access_token refresh_token bootstrap_token api_token secret client_secret credential credentials
  set-cookie cookie secret_key_base` and key SUFFIXES `_token _secret _password _credential`
  (case-insensitive). `authz_caller`, `authz_tenant`, `authz_route`, `authz_method`, `authz_policy`,
  `authz_platform_scope`, `authz_caller_platform_tenant`, `authz_suppressed` match none, so they are NOT
  replaced with `"[REDACTED]"` and stay queryable. (Do not name any field `*_token`/`*_secret`.)
* `component` is derived from the calling `mfa` automatically: the JSON line carries
  `component: "Letflow.Api.AuthzDenyLog"`, a ready filter.

Level: `warning` (a denial is expected traffic but security-relevant, above the `info` noise floor).
`LOG_LEVEL` (`config/runtime.exs:198`, applied at :218 as `config :logger, level`) can still raise the floor above `warning`;
that is the operator's existing, intended lever.

---

## 7. Sampling (D7, with R2)

Requirement (issue): repeated denials need a rate bound. Design: at most ONE line per
`{policy, caller_hash, tenant_hash}` per window, plus a count of what was withheld, with NO supervision
tree change and NO owner process.

### State

One term in `:persistent_term` under key `{Letflow.Api.AuthzDenyLog, :sampler}`:

    {last_ref :: :atomics.atomics_ref(), suppressed_ref :: :atomics.atomics_ref()}

each created by `:atomics.new(4096, signed: true)` (all zero). Slot index
`:erlang.phash2({policy_key, caller_hash, tenant_hash}, 4096)` (range `0..4095`, add 1 for atomics'
1-based index). `last_ref[slot]` = system-time second of the last EMITTED line for the slot (0 = never);
`suppressed_ref[slot]` = number of denials withheld since then.

The sampler key uses the two HASHES (not the raw ids), so (i) no raw id is ever held outside the
request process, and (ii) an attacker cannot choose a victim's slot: the slot depends on the keyed HMAC
of the victim's id, which is unknowable without the key. (A caller can only choose its OWN slot.)

### Creation (lazy, race tolerant -- chosen over creating in `Letflow.Application.start/2`)

`:persistent_term.get(key, nil)`; if `nil`, build both atomics refs and `:persistent_term.put` them.
Two requests racing at first use may each create a pair; the later `put` wins; events recorded against
the losing pair are lost (worst case: one extra emitted line in the first window). Creation is idempotent in
intent: `get` with a `nil` default, and `put` only when it is `nil`. The first put of a new key does not
trigger the global-GC scan; in the rare first-use race the loser's put REPLACES the term and does trigger
that scan once, ever. That is rare, one time and harmless, and accepted. Creating it from `Application.start/2` was rejected: it
couples the boot path to a log helper, and lazy creation has no failure mode that matters. NO child is
added to the supervision tree (satisfies the explicit constraint; also keeps the S3 "empty
InstanceSupervisor" and 0004 shape untouched).

### Algorithm (decision procedure, written as prose, not code)

Inputs: `window` seconds, `now` seconds, `slot`.
1. `window == 0` -> EMIT, touch no atomics (sampling disabled). `window` is
   `Application.get_env(:letflow, :authz_deny_log_window_s, 60)`; if it is not a non-negative integer
   the default 60 applies.
2. `last = get(last_ref, slot)`.
3. If `last == 0` or `now < last` (never emitted / clock went backwards) or `now - last >= window`:
   attempt `compare_exchange(last_ref, slot, expected: last, desired: now)`.
   * `:ok` (this process won): `n = exchange(suppressed_ref, slot, 0)`; EMIT with `suppressed=n`
     (omitted when `n == 0`).
   * not `:ok` (another process changed the slot between get and CAS, so it already emitted for this
     window): `add(suppressed_ref, slot, 1)`; do NOT emit.
4. Else (inside the window): `add(suppressed_ref, slot, 1)`; do NOT emit.

Guarantees:
* Concurrent denials of one key emit at most one line per window: all of them read the same `last`, and
  `compare_exchange` admits exactly one winner per distinct `last` value; every loser increments the
  counter. A loser's increment landing just after the winner's `exchange(...,0)` is carried into the
  NEXT line's `suppressed=` (no event is double counted or dropped; the count is exact barring the
  first-use creation race and VM restart).
* Global ceiling: at most 4096 lines per window system-wide (one per slot), about 68 lines/s at the
  default 60 s, regardless of how many distinct identities denial-flood. This is the flood bound the
  issue asked for.
* Hash collision (documented, accepted): two distinct keys that map to the same slot share one budget;
  within a window the second is suppressed and its count rides on the next emitted line (the line shows
  the emitted key's fields, so a collision can attribute a `suppressed=N` to the wrong caller). Chance
  per pair 1/4096; consequence is a delayed/absent line for a rare denial, and the suppressed count
  still reveals that withheld events exist. Not an authorisation matter (the 403 is never affected).
* Cross-route: the key excludes method/route, so one caller hammering several routes under ONE policy
  key shares a budget; the emitted line carries the first route seen. Accepted (the bound is per
  caller+policy, matching the issue's "repeated denials" wording).
* Suppressed denials cost: `phash2` of three small terms and two HMAC id hashes (needed for the key),
  two atomic ops. The log-field formatting, the sub-key derivation and the `Logger` call are skipped.

### Injectable clock (no sleeps in tests)

`now` comes from an optional zero-arity fun in Application env (`:authz_deny_log_clock`) returning integer
seconds; when it is absent, `now` is `System.system_time(:second)`. Documented `@doc false`, test-only; never set outside tests. A non-integer
or raising fun is a sampler failure, handled as FAIL-OPEN: the denial is EMITTED (a broken sampler must
never silence security logging) and nothing about the failure is logged beyond the standard one-time
notice of section 8 (the exception text is never logged).

### `reset/0` (test only)

Zeroes every slot of both atomics (`:atomics.put/3` over 1..4096, cheap; no `persistent_term` replace,
so no global GC), erases `{..., :fallback_key}`, the fallback notice flag and the failure-notice flags
(section 8). Tests call it in `setup` and `on_exit`.

### Alternative evaluated: ETS table

Rejected. An ETS table needs an owner process (a GenServer/`Task`) in a supervision tree or a heir hack
-- exactly the supervision-tree change the task forbids and the S3 decision (empty `InstanceSupervisor`,
`Letflow.Engine` moduledoc "Process-vs-row decision") argues against adding casually. A table created
lazily by a request process dies with that process (the table is owned by its creator), losing state
and racing on re-creation. `:ets.update_counter` would give a similar CAS-free counter, but unbounded
growth (one row per distinct caller) needs a sweeper -- yet more process. `:atomics` is fixed-size,
lock-free, ownerless, and its worst-case memory is `2 * 4096 * 8 = 64 KiB`. The cost of that choice is
collisions, which are acceptable (above).

### Alternative evaluated: reuse of the existing rate-limit plugs

(`test/letflow/plugs/login_discovery_rate_limit*` and `public_read_rate_limit_test.exs` show rate-limit plugs exist.) Those protect
an endpoint by REJECTING traffic and need per-IP/tenant state with an owner. This sampler only WITHHOLDS
a log line; it must not become a second enforcement surface and must not depend on a process that could
be down. Not reused. (ELIXIR-DEV: do not couple them.)

---

## 8. Never raise into the request; failure path logs nothing identifying

`log_denial/3` body shape (prose): everything -- field building, sampling, formatting, `Logger.warning`
-- runs inside ONE `try` with `rescue` (any exception) and `catch` (throw/exit). Nested narrower
protections:
* `route_pattern/1`, `platform_scope?/1`, `hash_id/3` each have a local fallback (`"unmatched"`, `true`,
  `"none"`) so a single field failure still yields a line (degraded, not lost, never identifying).
  `method_token/1` is total over any term (non-binary -> `"OTHER"`) but the READS of `conn.method`,
  `conn.private` and `conn.assigns.auth_context.tenant_id` have deliberately NO local fallback: a value
  that is not a `%Plug.Conn{}` falls to the single outer rescue (failure line only).
* The sampler is wrapped separately: failure -> emit (fail-open), see section 7.
* The outer failure handler logs NO value from the failed call: not `Exception.message/1`, not
  `inspect(reason)`, not `__STACKTRACE__`, not the conn/ctx/ids. Exception messages are the realistic leak
  vector (a `FunctionClauseError`/`ArgumentError` renders the offending argument, i.e. the raw user id or a
  header). The failure line is the constant text `"authz_deny_log_failed"` with the only variable being
  `class=<error|exit|throw>` and `exception=<module name>` (the struct's module name, e.g.
  `Elixir.ArgumentError`, only when the reason is an exception struct; otherwise `exception=none`).
  Module names are compile-time atoms, never request data.
* The failure line is emitted at most ONCE PER BOOT PER `{class, exception module}`
  (`:persistent_term` flag `{Letflow.Api.AuthzDenyLog, :failure_noted, class, module}`; the number of
  distinct values is bounded by the number of exception types in the VM), so a persistently broken log
  path cannot itself flood the log or be a DoS amplifier. `reset/0` clears the flags.
* `log_denial/3` returns `:ok` on every path. If even the failure handler raises, it is swallowed
  (`rescue _ -> :ok`).
* Order in `Authorize`: the call precedes `Response.forbidden/2`, so nothing it does (including a
  swallowed failure) can alter the response; a raising call would otherwise turn a 403 into a 500, which
  is why the wrapper exists.
* `Logger` itself is not a raise risk in normal operation (it is async with overload protection and the
  `:logger` filter in `Application.start/2` is already hardened per ISS-0769); a formatter crash inside
  `Letflow.Obs.Logger` has its own fallback (`metadata_encode_error`) that does not run in the request
  process.

---

## 9. Acceptance-criteria map (issue text -> design element)

| Issue requirement | Element |
|---|---|
| one structured line on every authorization denial, platform AND tenant scope | `log_denial/3` called from the single `:Deny403` branch (section 2); covers :Unknown + both markers |
| HTTP method | `method_token/1`, section 5 |
| route PATTERN, not the raw path | `route_pattern/1`, sections 4 and R1 |
| policy key | `policy_token/1` |
| platform-scope boolean | `platform_scope?/1` + `caller_platform_tenant`, section 5 |
| keyed hash of caller id and tenant id | `hash_id/3`, section 3 |
| INV-4: no token / email / raw tenant id / secret | audit table section 11, tests (d), (i) |
| hash key is a config secret, not a literal | derived from `:secrets_master_key`, section 3 |
| sampling / rate on repeated denials | section 7 |
| design (what hashed, which key, sampling) | sections 3, 7 |
| SECURITY-REVIEWER pass | sections 10, 11, 12 give the reviewer's evidence |

---

## 10. Invariants

### INV-4 (secrets by reference only) -- primary

See the table in section 11. Summary: every logged value is a constant, an allow-listed token, a boolean,
or a 16-hex keyed pseudonym; the key never appears; the failure path logs no variable text.

### INV-5 (not-found/forbidden indistinguishability)

Unchanged and cannot regress: the denial decision (`evaluate_access/2`) is made from `ctx` and the policy
key BEFORE any handler or `Repo` call, so the 403 is identical for an existing and a nonexistent
resource; this change adds a log call in that same branch and does not change status, body, headers or
the number of DB round trips (the call does none). The only new difference between two denials is
log-side (emit vs suppressed), observable only to whoever reads the logs and never an existence signal
(the target resource is not even looked up). Test (f) pins identical status+body+content-type against
the expected `Response.forbidden/2` bytes and between existing/nonexistent resource.

### INV-6 (data-access paths prove their scoping)

No data-access path is added: the module reads no database table and no tenant data. Scope statement for
SECURITY-REVIEWER: it reads only the already-derived `auth_context` and `AccessContext`; "tenant" in the
line is the caller's own DB-resolved tenant, never a path/body value.

### INV-10 (platform authority bound to platform tenant)

Platform-scope denial paths are touched ONLY by a logging call placed before the unchanged 403. No
decision logic, role matrix, scope table or `PlatformTenant` code changes; denial outcomes cannot change
because `log_denial/3` returns `:ok` regardless and receives no capability to alter the conn. Existing
evidence that stays authoritative for INV-10 (must keep passing unmodified):
`test/letflow/api/platform_prefix_uniform_403_test.exs`, `platform_scope_authorization_test.exs`,
`platform_scope_not_conferred_test.exs`, `platform_scope_inventory_test.exs`,
`platform_marker_not_writable_test.exs`, `promote_source_tenant_test.exs`, `tenant_target_test.exs`,
`authorization_test.exs`, `authorization_enforcement_test.exs`, `platform_admin_role_binding_test.exs`,
`test/letflow/plugs/authorize_test.exs`, `platform_scope_facts_test.exs`.

NEW negative evidence added by this change (tests (a), (b), (c), (f)): a non-operator caller of every
platform-scope shape (A's PLATFORM_ADMIN, A's PROCESS_DESIGNER of another tenant, P's PROCESS_DESIGNER)
still receives the byte-identical uniform 403 AND the log line attributes the denial with
`platform_scope=true` while containing no value of the other tenant (its slug/id) and no raw id of the
caller -- i.e. the log does not become a new cross-tenant disclosure channel.

---

## 11. INV-4 audit: every value that can reach the log line

| Field | Source | Possible values | Why safe |
|---|---|---|---|
| message prefix `authz_deny`, field names | string literal | constant | constant |
| method | `conn.method` (client supplied) | one of 7 literals or `OTHER` | allow-list; no client text ever passes |
| route | `conn.private[:plug_route]` | compile-time template or `unmatched` | template is router source text; `*glob` removed; regexp-gated `[\x21-\x7E]{1,200}`; raw path/query/body/params never read |
| policy | route macro literal atom, `:Unknown`, 2 markers | existing atom name or `unknown` | compile-time atom; regexp-gated; never `String.to_atom` |
| platform_scope | table lookup | `true`/`false` | boolean |
| caller_platform_tenant | `ctx.platform_tenant?` | `true`/`false` | boolean, coerced with `== true` |
| caller | `ctx.user_id` | 16 lowercase hex or `none` | HMAC-SHA256 keyed by a derived secret, truncated; non-binary -> `none`; raw id never output |
| tenant | `auth_context.tenant_id` | 16 lowercase hex or `none` | same; domain-separated from caller |
| suppressed | atomics counter | integer >= 1 | integer |
| metadata `authz_*` | same values | as above | same facts; no extra keys; `:logger` filter and Redaction see only these names |
| failure line | constant + `class` + exception module | `error`/`exit`/`throw`; module atom or `none` | no message/reason/stacktrace/ids |
| fallback-key notice | constant text | constant | no key material |

NEVER reaches the line: bearer token, `Authorization` or any header, email, username, raw user id, raw
tenant id/slug/schema name, path parameter values, query string, request body, remote IP, role list, the
master key, the sub-key, any exception message, the policy decision's `task_scope`.

Roles are deliberately NOT logged (a role list is not requested, enlarges the line, and partly
identifies a person); the platform booleans carry the needed explanation.

### Log-injection analysis

A log forging attack needs CR/LF or a delimiter the parser trusts, in a value the attacker controls.
* method: attacker-controlled but allow-listed -> only the 8 literals (test (g) sends `"PURGE"`/an
  injection string and asserts `OTHER` and a single line).
* route/policy: not attacker-controlled (compile-time) and additionally `[\x21-\x7E]` gated: CR (0x0D),
  LF (0x0A), TAB, space, NUL and non-ASCII are all excluded, so neither a newline nor a space can appear.
* ids: output is `[0-9a-f]` or `none` regardless of input bytes (the input only feeds the HMAC).
* suppressed: an integer printed with `Integer.to_string/1`.
* The JSON formatter additionally escapes message and metadata (`Jason.encode!`); in the plain formatter,
  the absence of CR/LF in every field is the guarantee.
Result: one denial produces exactly one line; an attacker cannot create a second record, a fake
`caller=` value or fake fields.

### Residual risk accepted

* Master-key change breaks hash continuity (section 3).
* A flooder can consume a slot's budget and delay a colliding victim's line (section 7); 403s are never
  affected, only the log line timing, with a suppressed count.
* An operator holding BOTH the logs and the master key could confirm a guessed id against a hash; they
  already hold the key to every stored secret (`Letflow.Secrets`), so no new capability.
* Test console noise: existing denial tests will now print `authz_deny` warning lines. Harmless; do not
  silence them by changing logger config in this change (see Files). Tests that already assert the exact
  absence of any log output around a denial would break. This is an explicit BUILD STEP for ELIXIR-DEV, see
  section 12a.

---

## 12. Answers requested by ORCH

* New env var? **NO.** (`LETFLOW_SECRETS_MASTER_KEY` is existing and unchanged.)
* New boot failure? **NO.** `config/runtime.exs` is not modified.
* Supervision tree change? **NO.** No child, no process, no ETS table; `Letflow.Application` untouched.
* Migration / schema change? **NO.**
* New dependency? **NO** (`:crypto`, `:atomics`, `:persistent_term`, `Logger`, `Plug.Router` are present).
* Telemetry: **NOT added** in this change (decision 8): the line plus its JSON fields is the deliverable;
  a counter would need a Metrics.Registry family (OBS-02), a cardinality review and a doc update, and the
  issue does not ask for it. Candidate follow-up if wanted: `[:letflow, :authz, :deny]` with `policy` and
  `platform_scope` labels only (never ids).

### 12a. Build steps for ELIXIR-DEV (ordered)

1. Create `lib/letflow/api/authz_deny_log.ex` per sections 2-8.
2. Edit `lib/letflow/plugs/authorize.ex` (alias, one call in the `:Deny403` branch, moduledoc paragraph).
3. AUDIT existing tests that capture logs around a denial: run
   `grep -rln "capture_log" test/` (42 files at design time), intersect with files that exercise denials
   (`test/letflow/plugs/authorize_test.exs`, `test/letflow/api/platform_*`, `authorization_*`,
   `tenant_status_test.exs`, router/integration tests), read each hit, and fix any assertion that expects an
   empty or exact log across a denial (the new `authz_deny` line is expected). Record the files checked in
   the handoff. Do not change logger config to hide the new line.
4. Run `mix compile --warnings-as-errors` and the focused tests listed in section 13.

### Files changed (expected)

| File | Change |
|---|---|
| `lib/letflow/api/authz_deny_log.ex` | NEW (module per section 2, moduledoc stating INV-4 policy, key derivation, sampling, fail-safe) |
| `lib/letflow/plugs/authorize.ex` | `alias Letflow.Api.AuthzDenyLog`; one call in the `:Deny403` branch; moduledoc sentence replaced (section 2) |
| `test/letflow/api/authz_deny_log_test.exs` | NEW (section 13) |
| `docs/issues/ISS-0995.yaml` | ORCH: `queue_ref: Q-976`, `github_ref: GH-2257`, `status: resolved`, regression tests named |
| `docs/anti-patterns.md` | only if a trap is recorded; candidate entry: "do not assume `Plug.Router.match_path/1` in a forwarded router is `/api/v1/x/:id`; it contains `/*glob` per `forward`" (R1). ELIXIR-DEV/DOC-UPDATER decide |

No other file changes; in particular NOT `config/*.exs`, `Letflow.Application`, `Letflow.Api.Authorization`,
`Letflow.Api.Response`, `Letflow.Plugs.HttpMetrics`, `Letflow.Obs.Logger`.

---

## 13. Test plan (for TEST-DESIGNER)

New file `test/letflow/api/authz_deny_log_test.exs`, `use Letflow.DataCase, async: false` (global state:
`capture_log`, Application env, `:persistent_term`). `setup`: `AuthzDenyLog.reset()`; save and restore
(`on_exit`) `:secrets_master_key`, `:authz_deny_log_window_s`, `:authz_deny_log_clock`; use
`Fixture.three_tenants!()`, `Fixture.pin!/1`/`unpin!/0`, `Fixture.mint_token!/2`, `Fixture.api_conn/5`,
`Fixture.dispatch_api/1` (`test/support/platform_tenant_fixture.ex`) for real-router requests. Unless a test
is about sampling, set `:authz_deny_log_window_s` to `0` so each denial logs. Assertion helper: parse the
captured log into lines, select those containing `authz_deny `, parse `key=value` tokens into a map.

(a) Platform-scope deny: (1) direct `Letflow.Plugs.Authorize.call/2` with `conn.private[:policy_key] =
:TenantsManage`, caller roles `["PLATFORM_ADMIN"]` on a non-platform tenant (pin set to another tenant):
`capture_log` yields exactly ONE `authz_deny` line; tokens: `method=GET`, `route=unmatched` (no
`:plug_route` in a direct call), `policy=TenantsManage`, `platform_scope=true`,
`caller_platform_tenant=false`, `caller` equals the independently recomputed HMAC (e) of the caller's
user id, `tenant` equals the recomputed HMAC of the tenant id; no `suppressed=`. (2) through
`Letflow.Router` with a real token (`mint_token!(ctx.a, ["PROCESS_DESIGNER"])`, GET
`/api/v1/tenants/<unique-slug>`): exactly one line with `route=/api/v1/tenants/:slug`,
`policy=TenantsManage`, `platform_scope=true`. Also assert the logged metadata equals the message fields
(attach a `:logger` handler or `Logger.metadata`-capturing handler, e.g. the existing
`test/support/logger_collector.ex`, or call `format_message/2` + a metadata builder directly).

(b) Tenant-scope deny: a role lacking a tenant permission (e.g. `TASK_WORKER` on a definitions-write
route via the full router, `POST /api/v1/definitions`), asserts `policy=DefinitionsCreate`,
`platform_scope=false`, route `/api/v1/definitions/` (VERIFIED: `definitions.ex:248` declares `authz_post "/"`, so the trailing slash survives the `/*glob` strip; any other `"/"` route behaves the same), one line.

(c) `:Unknown` and markers: direct plug call with no `:policy_key` -> `policy=Unknown`,
`platform_scope=false`; `:UnmatchedPlatformPath` (non-operator caller) -> `platform_scope=true`; through
the full router an unmatched path under `/api/v1/tenants/zzz/zzz` as a non-operator -> `route` ends with
`/*_path`, `policy=UnmatchedPlatformPath`, `platform_scope=true`; `:UnmatchedRoute` under an ordinary
router with a non-admin -> `platform_scope=false`.

(d) No leak: for the real-router requests of (a)/(b)/(c), the caller has a known raw user id, raw tenant
id, tenant slug, email (`mint_token!` generates it; read it back), the bearer token plaintext, and a
UNIQUE path param value (`"uniq-5f0c1ad9"`), a unique query string value and body value. `refute log =~`
each one individually (user id, tenant id, tenant schema name, slug, email, token, path value, query
value, body value, the master key as hex and as raw bytes, the sub-key as hex). Also `refute log =~
"user_id"`-style key names that would suggest raw dumps.

(e) Hash algorithm pin: for fixed ids, recompute in the test with `:crypto.mac(:hmac, :sha256, key,
data)`: `subkey = mac(master, "letflow/authz-deny-log/v1" <> <<1>>)`; `expected_user = mac(subkey, "user:"
<> id) |> Base.encode16(case: :lower) |> binary_part(0, 16)`; assert `hash_id(:user, id, subkey())` equals
it; assert `hash_id(:tenant, id, ...)` differs from the user one for the SAME id; stable across two calls;
differs for a different id; differs after `Application.put_env(:letflow, :secrets_master_key, other_32)`;
`hash_id(:user, nil, ...) == "none"`, `""`, `123`, and a map all `"none"`; result matches `~r/\A[0-9a-f]{16}\z/`.

(f) INV-5 / response bytes: capture `conn.status`, `resp_body`, and the `content-type` header of the
platform-scope 403 (existing vs nonexistent slug, `PATCH` too) with logging enabled; assert equality
against the expected `Letflow.Api.Response.forbidden(Plug.Test.conn(...), "insufficient permissions")`
bytes (status 403, `application/problem+json`, same body) and between existing and nonexistent resource.
(`request-id`/trace header excluded, as in `platform_prefix_uniform_403_test.exs`.) The pre-existing
`platform_prefix_uniform_403_test.exs` also stays green unchanged.

(g) Method allow-list and injection: dispatch requests with method `PURGE` (and an arbitrary token if
Plug.Test allows) at a router catch-all so the plug runs; assert `method=OTHER`. Unit-test
`method_token/1` over `"GET"`..`"OPTIONS"` (identity), `"get"`, `"PURGE"`, `"GET\r\nFAKE"`, a 5000-char
string, `nil`, `:get` -> `OTHER`. Assert the captured text has exactly one newline-terminated record per
denial for a request carrying `\r\n` in the method/path/header (no second `authz_deny` line, no
injected `caller=`).

(h) Sampling (injectable clock via `:authz_deny_log_clock`, e.g. an `:atomics`/Agent-backed fun the test
advances; no sleeps). Window `60`, `reset/0` in setup. Every expected value below follows the section-7
algorithm exactly: a withheld denial increments the slot counter; the next EMITTED line for that slot
carries `suppressed=<counter>` and zeroes it. "K" = caller A, tenant T, policy `TenantsManage`.
1. Clock `1000`: denial K#1 -> EMIT, no `suppressed=` (slot never used, counter 0). Denials K#2..K#5 at
   `1000` -> no line (counter 4). A DIFFERENT caller at `1000` -> its own line. Same caller, DIFFERENT
   policy key at `1000` -> its own line. Captured lines so far: exactly 3.
2. Clock `1059` (`59 < 60`): K#6 -> no line (counter 5). This pins the window boundary.
3. Clock `1060` (`60 >= 60`): K#7 -> EMIT with `suppressed=5` (counter 5 -> 0, last = 1060). K#8 at `1060`
   -> no line (counter 1).
4. Clock `1120`: K#9 -> EMIT with `suppressed=1` (counter 1 -> 0, last = 1120).
5. Clock `1180`: K#10 -> EMIT with NO `suppressed=` (counter was 0). This is the "truly zero withheld"
   window.
6. Clock set BACKWARDS to `500` (`now < last`): K#11 -> EMIT, no `suppressed=` (R2).
Window `0` (fresh `reset/0`): 5 denials of K -> 5 lines, none with `suppressed=`. Invalid windows (`-1`,
`"x"`, `1.5`) behave as 60 (repeat step 1: one line, four withheld).
Concurrency: after `reset/0`, clock `1000`, spawn 50 `Task`s that each deny K once and await all:
`capture_log` contains EXACTLY ONE `authz_deny` line (no `suppressed=`; one CAS winner, 49 counted).
Then clock `1060` and one more K denial: that line carries `suppressed=49`. Collision behaviour is
document-only (section 7) and is not tested.

(i) Never raises / fail-safe: (1) master key absent or non-32-byte binary in Application env ->
response still the same 403, one line emitted, plus exactly one "authz deny log hash key fallback in use"
notice per boot (a second denial logs no second notice), notice contains no key material; (2) non-binary
`user_id` (e.g. `12_345`) in `AccessContext` -> `caller=none`, 403 unchanged; (3) a clock fun that raises
`RuntimeError` whose MESSAGE contains the sentinel `"SENTINEL-USER-ID-777"` -> sampler fail-open: the
denial line IS emitted, the response unchanged, and the sentinel does not appear in the captured log; (4) force the outer failure path (deterministic because `conn.method`, `conn.private`, and the `auth_context`/tenant reads have NO per-field fallback: only `route_pattern/1`, `platform_scope?/1` and `hash_id/3` degrade locally, so a non-conn argument reaches the single outer `rescue`) by calling `AuthzDenyLog.log_denial(:not_a_conn, ctx, :X)`: returns `:ok`,
logs only the constant `authz_deny_log_failed class=error exception=Elixir.FunctionClauseError`
(or whatever module the implementation raises, asserted against the same regexp), once per boot per
class/module (call twice, one line), and the line contains no id, no `inspect` of the args.

(j) Allowed requests log nothing: a matched route with a permitted role (e.g. platform operator `GET
/api/v1/tenants/<slug>`, and a tenant admin on a tenant route) -> `capture_log` contains no `authz_deny`.
The 500 branch (`conn` without `auth_context`) also logs nothing from this module.

### Fail-first

Against `origin/main` (no `Letflow.Api.AuthzDenyLog`, no log call): (a)-(d) and (g)-(j) fail (no
`authz_deny` line; (j) passes vacuously and is kept as a regression guard); (e), (h) and the module-
level halves of (g)/(i) fail with `UndefinedFunctionError`; (f) passes on main (it is the byte-identity
regression guard that must STILL pass after the change, not a fail-first test). TEST-DESIGNER must run the
suite once on the pre-change tree (before ELIXIR-DEV's commit) and record the failing names.

### Mutants (TEST-DESIGNER runs these in a throwaway `git worktree` AFTER committing; NEVER `git checkout`
or `git stash` in the main worktree -- see memory note on a destroyed uncommitted tree)

| # | Mutant | Must be killed by |
|---|---|---|
| M1 | hash with the raw id (no HMAC) | (e) pin test (recomputed value mismatch) and (d) (raw id appears in log) |
| M2 | plain SHA-256, no key | (e) (mismatch; and "differs when master key differs" fails) |
| M3 | log the raw `conn.request_path` instead of the pattern | (d) (unique path value appears) and (a2) (route value mismatch) |
| M4 | sampling removed (always emit) | (h) 5-denials-one-line, `suppressed=4`, and the 50-task race |
| M5 | sampler key ignores caller (policy only) | (h) different-caller-own-line |
| M6 | line also emitted on the allow branch | (j) |
| M7 | domain label dropped (user and tenant hash of the same id equal) | (e) user-vs-tenant inequality for the same id |
| M8 | response body (or status/content-type) changed in the deny branch | (f) and the unchanged `platform_prefix_uniform_403_test.exs` |

Additional recommended mutants (cheap): M9 `"/*glob"` normalisation removed -> (a2)/(c) route value
mismatch; M10 method allow-list removed -> (g); M11 failure path includes `Exception.message/1` ->
(i)(3)/(i)(4) sentinel assertion; M12 `compare_exchange` replaced by unconditional `put` -> the race test
in (h).

### Verification commands for the TDD cycle (ELIXIR-DEV / TEST-RUNNER; do not run all at once)

    mix test test/letflow/api/authz_deny_log_test.exs
    mix test test/letflow/plugs/authorize_test.exs test/letflow/api/platform_prefix_uniform_403_test.exs
    mix compile --warnings-as-errors
    grep -rn "Nothing is logged here" lib/    # must return zero hits after the change

---

## 14. Open questions

* OQ-1 (informational, not blocking): `Letflow.Routers.Entities.check_unredacted_permission/2` is a second
  `evaluate_access/2` caller whose `:Deny403` is a handler decision, not this plug's 403. Left unlogged
  by scope. If product wants it attributed, it is a follow-up using the same module (a second call site).
* OQ-2 (informational, not blocking): `Letflow.Plugs.HttpMetrics` `route_template` label carries the
  forward `*glob` segments in the composed production template (cardinality-safe, cosmetic); its own docs
  claim a cleaner value. Candidate follow-up: reuse `AuthzDenyLog.route_pattern/1`'s normalisation
  there. Not changed here.
* OQ-3 (decision recorded, flag for REVIEWER): `platform_scope` means "the policy being enforced is
  platform-scope" (with explicit marker mapping), not "the matched route sits under a platform URL
  prefix". The two coincide for matched routes; they differ only for `:UnmatchedRoute` (false) and
  `:UnmatchedPlatformPath` (true, by its marker meaning). Chosen because it is the same fact
  `evaluate_access/2` acts on.

No open question blocks the build.
