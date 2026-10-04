# REQ-439 -- Design: trusted-proxy client IP (REQ-CIP)

Stage S4. Owner `CODE-DESIGNER` -> `ELIXIR-DEV`. Queue Q-948, GH#2198. Status: design only;
signatures, type shapes and prose, no implementation bodies.

Governing text: `lib/letflow/design/req434-email-first-login-directory.md` s0.3 D11/D12, s12.6
(mechanism, configuration, precondition, residuals) and s15.0 (work package); decision
`docs/migration/decisions/0042-email-first-login-tenant-directory.md` Decisions 8-9, OQ-5/OQ-12.
This file does not restate them; it fixes the points those leave open and lists where this design
refines them (section 9). Invariants: INV-4 (no IP, header value, CIDR entry or env value in any
log line or raise message) and INV-5 (a spoofable limiter key is the failure mode; every failure
falls to the stricter shared bucket).

## 1. Module and public API

File `lib/letflow/plugs/client_ip.ex`, module `Letflow.Plugs.ClientIp`, `@behaviour Plug`. No new
dependency; no reads of request body; no halt; no logging; no telemetry. Pure functions are
total (never raise on any input of the stated types).

```
@type cidr :: {:inet.ip_address(), prefix_len :: 0..128}   # v4 prefix 0..32, v6 prefix 0..128

# Plug
@spec init(keyword()) :: keyword()                  # pass-through, see s2
@spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()   # sets conn.assigns.client_ip, never halts

# Pure
@spec resolve(peer :: :inet.ip_address(), x_real_ip_values :: [String.t()], [cidr()]) ::
        :inet.ip_address()
@spec parse_cidrs(String.t()) :: {:ok, [cidr()]} | {:error, :invalid_cidr}
@spec trusted?(:inet.ip_address(), [cidr()]) :: boolean()

# Boot helpers (pure; called from config/runtime.exs, s4)
@spec parse_enabled(String.t() | nil, default :: boolean()) ::
        {:ok, boolean()} | {:error, :invalid_boolean}
@spec boot_check(env :: atom(), enabled :: boolean(), [cidr()]) ::
        :ok | :warn | {:error, :prod_requires_trusted_proxies | :prod_zero_prefix_cidr}
```

Error shapes: `parse_cidrs/1` returns the bare `{:error, :invalid_cidr}` (no entry, index or
value in the tuple, INV-4). `parse_enabled/2` returns bare `{:error, :invalid_boolean}`. No
function raises; only `config/runtime.exs` raises, with fixed messages (s4).

The assign key is `:client_ip` (type `:inet.ip_address()`), set on every request.

## 2. Plug behaviour

`init/1` returns its keyword unchanged. It must NOT read application config: `Plug.Builder`/
`Plug.Router` run `init/1` at compile time, before `config/runtime.exs` exists, so a value baked
there would be the compile-time `[]` on a release and the feature would silently never engage
(and a test could not vary it). `call/2` resolves the trust list per request: `Keyword.fetch(opts,
:trusted_proxies)` if present (tests pass it as plug opts), else
`Application.get_env(:letflow, Letflow.Plugs.ClientIp, [])[:trusted_proxies]`, else `[]`. This
matches the call-time `Application.get_env` precedent in `public_read_rate_limit.ex`.

`call/2`: `values = Plug.Conn.get_req_header(conn, "x-real-ip")` (list, one element per header
line; `get_req_header` lowercases the lookup name), `ip = resolve(conn.remote_ip, values,
trusted)`, then `Plug.Conn.assign(conn, :client_ip, ip)`. `conn.remote_ip` is never modified. The
body is never read; `x-forwarded-for` and `forwarded` are never requested.

## 3. Pure rules

`resolve(peer, values, cidrs)`:
1. `trusted?(peer, cidrs)` false (includes `cidrs == []`) -> return `peer` unchanged.
2. Peer trusted: honour `values` only when `length(values) == 1`. Zero or two-plus -> `peer`.
   (Two header lines are two elements via `get_req_header`. A server that folds duplicates into
   one `"a, b"` string yields one element containing a comma, rejected by rule 3. Either way the
   result is `peer`.)
3. The single value is trimmed of leading/trailing space and tab only, then must satisfy all of:
   non-empty; contains no `,`, no whitespace, no `%` (zone id), no `[`/`]`, no `/`; and
   `:inet.parse_strict_address(charlist)` returns `{:ok, ip}` (a single IPv4 dotted quad or IPv6
   literal; hostnames, ports and shorthand like `1.2` fail). Any failure -> `peer`.
4. Success -> the parsed `ip` as parsed (not normalised; REQ-436's key derivation already
   converts mapped addresses, its s12.2). `resolve` returns the original `peer` term on every
   fallback, so `client_ip == conn.remote_ip` holds exactly (AC 1).

`trusted?(ip, cidrs)`: true iff some cidr matches. Matching converts both sides to unsigned
integers (v4: 32 bits from 4 octets; v6: 128 bits from 8 sixteen-bit groups) and compares the
top `prefix_len` bits; address families must be equal or the entry does not match. Prefix 0
matches every address of its family (`0.0.0.0/0` all v4, `::/0` all v6, they do not cross
families); a full-width prefix (/32, /128) is exact match. Host bits set in a configured base
(`10.0.0.5/8`) are accepted and masked at match time.

IPv4-mapped IPv6: before matching, an `ip` of the form `{0,0,0,0,0,0xFFFF,hi,lo}` is converted to
the v4 tuple. So a mapped peer `::ffff:10.0.0.7` matches `10.0.0.0/8` and does not match a v6
CIDR. At parse time a v6 cidr whose base is mapped and whose prefix is >= 96 is stored as the v4
cidr (prefix - 96); a mapped base with prefix < 96 stays v6 and therefore never matches a
(normalised) peer. This normalisation applies only to the trust test; `resolve` returns the
unconverted peer or parsed header address.

`parse_cidrs(string)`: split on `,`, trim each segment, drop blank segments (so `""` and `" "`
give `{:ok, []}`, precedent: `CORS_ALLOWED_ORIGINS` in `runtime.exs`). Each segment is
`ADDR` or `ADDR/PREFIX`: `ADDR` via `:inet.parse_strict_address` (no hostnames, no zone ids);
`PREFIX` must be 1-3 ASCII digits only (no sign, no space), range 0..32 for a v4 address and
0..128 for v6; bare `ADDR` means /32 or /128. Any segment failing -> the whole result is
`{:error, :invalid_cidr}` (no partial list). Order of the list is preserved.

`parse_enabled(value, default)`: `nil` or blank-after-trim -> `{:ok, default}`; exactly `"true"`
or `"false"` (case-sensitive) -> `{:ok, boolean}`; anything else -> `{:error, :invalid_boolean}`.

`boot_check(env, enabled, cidrs)`:
- `enabled == false` -> `:ok` (the trust list is irrelevant when the mount is off).
- `env == :prod`, enabled, `cidrs == []` -> `{:error, :prod_requires_trusted_proxies}`.
- `env == :prod`, enabled, any cidr with prefix 0 -> `{:error, :prod_zero_prefix_cidr}`
  (SECURITY-REVIEWER's non-blocking advice on 0042: a `/0` trust list makes every peer trusted;
  see Open Question 4).
- `env != :prod`, enabled, `cidrs == []` -> `:warn`; otherwise `:ok`.

## 4. Configuration keys and `config/runtime.exs`

Keys (exact):
- `config :letflow, Letflow.Plugs.ClientIp, trusted_proxies: [cidr()]`
- `config :letflow, Letflow.Routers.LoginDiscovery, enabled: boolean()`

`config/config.exs`: `enabled: config_env() != :prod` (false in prod, true in dev/test) and
`trusted_proxies: []`, so the keys exist in every environment before runtime evaluation.
`config/test.exs`: `trusted_proxies: []` (explicit test default, AC 5). Plug tests do not depend
on it (they pass opts).

`config/runtime.exs`: a new block placed after the `LOG_LEVEL` block and BEFORE the
`if config_env() == :prod do` block, outside any env guard (the refusal must see `config_env()`,
and must fire before the prod-only `DATABASE_URL` raise so it is observable without a database).
Structure, in order:
1. `System.get_env("LETFLOW_TRUSTED_PROXIES")` (nil -> treated as `""`) passed to
   `Letflow.Plugs.ClientIp.parse_cidrs/1`; `{:error, :invalid_cidr}` -> `raise` with the fixed
   message: `environment variable LETFLOW_TRUSTED_PROXIES contains an invalid CIDR entry. Expected
   a comma-separated list of IPv4/IPv6 addresses or CIDRs (for example a/N). The value is not
   echoed.` (no value, no entry).
2. `System.get_env("LETFLOW_LOGIN_DISCOVERY_ENABLED")` through `parse_enabled(value, config_env()
   != :prod)`; `{:error, :invalid_boolean}` -> `raise` fixed message: `environment variable
   LETFLOW_LOGIN_DISCOVERY_ENABLED must be exactly true or false. The value is not echoed.`
3. `boot_check(config_env(), enabled, cidrs)`:
   - `{:error, :prod_requires_trusted_proxies}` -> `raise`: `LETFLOW_LOGIN_DISCOVERY_ENABLED is
     true but LETFLOW_TRUSTED_PROXIES is empty or unset: refusing to boot. Without a trusted
     proxy list the per-IP rate-limit key is the proxy hop shared by every visitor. Set
     LETFLOW_TRUSTED_PROXIES to the reverse proxy's CIDR(s), or set
     LETFLOW_LOGIN_DISCOVERY_ENABLED=false.` Names both variables, contains no value.
   - `{:error, :prod_zero_prefix_cidr}` -> `raise`: `LETFLOW_TRUSTED_PROXIES contains a /0 CIDR,
     which trusts every peer: refusing to boot in prod.`
   - `:warn` -> print exactly one fixed line to standard error via `IO.puts(:stderr, ...)`:
     `[warning] LETFLOW_LOGIN_DISCOVERY_ENABLED is true with LETFLOW_TRUSTED_PROXIES empty:
     per-IP rate limiting keys on the proxy hop (single shared bucket). Not allowed in prod.`
     (`Logger` is not guaranteed started while config evaluates, e.g. on a release.)
   - `:ok` -> nothing.
4. Unconditionally (every env) `config :letflow, Letflow.Plugs.ClientIp, trusted_proxies: cidrs`
   and `config :letflow, Letflow.Routers.LoginDiscovery, enabled: enabled`. The router gate that
   reads `enabled` is REQ-437's, not built here.

## 5. How the runtime-config test exercises it

`test/letflow/client_ip_runtime_config_test.exs`, `@moduletag :slow`, modelled on
`secrets_runtime_config_test.exs`: each case spawns `System.cmd("mix", ["run", "--no-start", "-e",
<IO.inspect of both config keys>], env: [...], stderr_to_stdout: true, cd: File.cwd!())`, with env
list always nil-ing `MIX_TEST_PARTITION` and `MIX_BUILD_PATH` and supplying
`LETFLOW_SECRETS_MASTER_KEY` (the existing committed test value; `MIX_ENV=dev` has no fallback).
`--no-start` avoids the Repo; `runtime.exs` is still evaluated. Cases: `MIX_ENV=test` unset ->
`trusted_proxies: []`, `enabled: true`; valid list (IPv4, IPv6, bare address) parses to tuples;
invalid entry -> nonzero exit, output names `LETFLOW_TRUSTED_PROXIES`, does not contain the
supplied value; `enabled` `true`/`false` accepted, `yes`/`TRUE` raise (output must not contain
the value); `MIX_ENV=dev` default true with the warning line present once and empty-list;
`MIX_ENV=prod` (with a dummy `DATABASE_URL`): default `enabled: false`, boots; enabled+unset ->
nonzero with both variable names and no value; enabled+list -> exit 0. Because the prod cases need
a prod-compiled build, the same decision table is ALSO covered in-process by a fast unit test of
`boot_check/3`, `parse_enabled/2` (the `:prod`/`:dev` rows), so the matrix is verified even if the
prod subprocess cases are excluded (Open Question 2).

## 6. nginx realip plan (`deploy/nginx/letflow-test.conf`)

In the `server {}` block, before `location /` (so before `proxy_set_header X-Real-IP
$remote_addr`, which stays unchanged): one `set_real_ip_from <range>;` line per Cloudflare edge
range (IPv4 and IPv6 lists as published by Cloudflare at its IP-ranges pages, copied verbatim and
verified by the implementer at build time, U3), then `real_ip_header CF-Connecting-IP;` and
`real_ip_recursive off;`. A request from a source outside the listed ranges leaves `$remote_addr`
as the TCP peer and any `CF-Connecting-IP` it sends is ignored. Also add a comment block recording
the same directives as the infrastructure action for QA's vhost (outside the repository, U4);
the same block is quoted in the handoff. The container-side peer address (Docker bridge gateway,
not 127.0.0.1, when nginx proxies to the published port) is what `LETFLOW_TRUSTED_PROXIES` must
contain (U4); the file documents this but no real value is committed.

`deploy/.env.example`: two commented, valueless lines, `LETFLOW_TRUSTED_PROXIES=` and
`LETFLOW_LOGIN_DISCOVERY_ENABLED=`, each with a short comment (format, default, the prod
refusal). Blank is equivalent to unset.

## 7. Acceptance-criterion map

| # | AC (REQ-439) | Element |
|---|---|---|
| 1 | empty list / untrusted peer: `client_ip == remote_ip` | `resolve` rule 1; plug test table (XFF and X-Real-IP vary) |
| 2 | trusted peer valid single v4 and v6; none/two/comma/unparsable -> remote_ip | `resolve` rules 2-4; `get_req_header` arity count; table test |
| 3 | XFF never changes result; `remote_ip` unrewritten | s2 (header never requested); full cross-product test; assert `conn.remote_ip` after `call` |
| 4 | CIDR table: v4/v6 bounds, /0, /32, /128, mapped; `parse_cidrs` rejects | `trusted?`, mapped rule, `parse_cidrs` rules in s3 |
| 5 | runtime: unset `[]`, valid parses, invalid raises, enabled true/false, other raises, defaults | s4 steps 1-2, 4; config.exs/test.exs defaults; s5 subprocess cases |
| 6 | prod refusal; message names both, no value; non-empty boots; dev/test warns | `boot_check`, s4 step 3 fixed messages; s5 |
| 7 | plug reads no body | s2; test with a conn whose adapter raises on `read_req_body` |
| 8 | stub-pipeline test | test-only `Plug.Router` (two instances: one with `trusted_proxies: [cidr]` opt, one with `[]`) of `ClientIp` then a probe plug that responds with the `client_ip` assign; two X-Real-IP values behind one trusted peer -> two distinct values; empty list + spoofed header -> unchanged |
| 9 | nginx realip, `.env.example`, infra action recorded | s6 |
| 10 | git diff empty on `public_read_rate_limit.ex`, `bucket.ex`, `auth_pipeline.ex`, `api_pipeline.ex`; SECURITY-REVIEWER vs INV-4/INV-5 | no edit to those files (the plug is mount-agnostic and is not added to any existing pipeline here); verdict recorded at the gate |
| 11 | compile, format, tests, boundaries | `mix letflow.check_boundaries`: the plug has no dependency on tenant/engine modules |

## 8. Invariants

1. `client_ip` is always set and always an `:inet.ip_address()`.
2. Every parse/arity/trust failure yields `conn.remote_ip` (stricter shared bucket), never a
   caller-chosen value.
3. `conn.remote_ip` is never rewritten; XFF/Forwarded are never read.
4. No IP, header value, CIDR entry or env value appears in a log line or raise message.
5. The trust list is read per request from config (not compile time) unless given as opts.

## 9. Discrepancies and refinements for ORCH

1. REQ-434 s12.6 types `init/1` as returning `[trusted_proxies: [cidr()]]` "from opts, else app
   config". Reading app config in `init/1` is a compile-time read under `Plug.Builder` and would
   bake `[]` into a release. This design makes `init/1` a pass-through and reads at `call/2`
   (s2). Requirement text does not say; this is a refinement of the merged design.
2. Added public functions not named in the requirement (`parse_enabled/2`, `boot_check/3`) so the
   `runtime.exs` decision logic is unit-testable without a prod build. Same file, within
   FILES.
3. Added `:prod_zero_prefix_cidr` refusal from SECURITY-REVIEWER's advice recorded in 0042.
   Requirement ACs do not list it (see Open Question 4).
4. Requirement/design agree on keys, env names, X-Real-IP-only, refusal, nginx plan; no other
   disagreement found.

## 10. Open questions

1. `runtime.exs` calling `Letflow.Plugs.ClientIp` (a project module): proven under `mix run`; the
   implementer must also verify it on a release boot (config providers run before app start, but
   the app's beams must be on the code path). Fallback if not: inline the parse in `runtime.exs`
   and add a test asserting equivalence with `parse_cidrs/1`. Default now: call the module.
2. The `MIX_ENV=prod` subprocess cases need a prod compile (slow, may be absent in CI). Default:
   keep them tagged `:slow` alongside the fast `boot_check/3` unit coverage; implementer reports
   the measured cost and ORCH may drop them if CI cannot afford it.
3. The dev/test warning prints on every `mix test` boot (test default is enabled + `[]`).
   Accepted as AC 6 requires it; implementer may confirm it does not break log-capture tests.
4. `/0` handling in prod is a refusal here, the advice allowed "reject or loudly warn".
   ORCH/REVIEWER may downgrade to a warning; dev/test uses neither (accepted, the table test
   needs `trusted?` with /0 only, not boot acceptance).
5. External facts (design U3/U4), not decidable from the repo: that Cloudflare sends
   `CF-Connecting-IP`, the current edge ranges, and the container-side peer address nginx arrives
   from on QA. Implementer/UAT-RUNNER verify; this design records no real values.
6. OTP `:inet.parse_strict_address/1` handling of IPv4 octets with leading zeros is unverified
   here; default accept whatever it returns (only a trusted proxy supplies the value). Implementer
   adds one test pinning the observed behaviour.
7. 0042 OQ-3 (lawful basis and controller) still blocks enabling the flag outside dev; this
   requirement does not authorise it.
