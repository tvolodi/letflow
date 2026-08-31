# REQ-204 — SSRF validation for webhook `target_url`

Design for `Letflow.Webhooks.UrlValidator` (new module) and the two
integration points it is wired into: `Letflow.Webhooks.create/2` and the
private `Letflow.Webhooks.dispatch_http/3`.

**R-Co's own `src/webhook/` SSRF handling is NOT inspectable from this
codebase's history.** All rejected ranges and the scheme allowlist are
**Letflow's own choices**, stated explicitly throughout this document, not
ports of any R-Co value.

**No new hex dependency.** OTP's own `:inet.getaddrinfo/1` performs DNS
resolution. No migration — this is a pure validation layer over the already-
existing `webhook_subscriptions` schema and write path.

---

## §0 Overview / scope

### 0.1 The gap this requirement closes

`Letflow.Webhooks.create/2` casts `:target_url` as a plain `:string` with
only a not-null constraint. No scheme check, no IP-range rejection. This
means any tenant can register a webhook pointing at `http://169.254.169.254`
or `http://10.0.0.1/internal` and `deliver/3` will HMAC-sign and POST there
— a genuine SSRF-as-a-service primitive. REQ-183's `deliver/3` also persists
up to 500 chars of the HTTP response body into
`webhook_delivery_attempts.last_error`, and REQ-184 (pending) surfaces that
column to the same tenant via `GET .../deliveries` — so the SSRF primitive
becomes a read-oracle into internal network responses once REQ-184 ships.

### 0.2 What this design adds (exactly — no scope creep)

1. A new pure-function module `Letflow.Webhooks.UrlValidator` whose sole job
   is validating a `target_url` string against Letflow's scheme allowlist and
   private-range blocklist.
2. One call to `UrlValidator.validate/2` in `create/2` — fast tenant feedback
   at subscription-creation time.
3. One call to `UrlValidator.validate/2` in `dispatch_http/3` —
   defence-in-depth before every `:httpc.request/4` call, catching DNS
   rebinding.
4. INV-9 text for `docs/agents/instructions/security-invariants.md`.

### 0.3 Out of scope

- No migration (no schema change).
- No new route, controller, or Plug module.
- No change to `update/3` (does not accept a `target_url` update today —
  that is not a scope gap for this requirement).
- No new hex dependency.
- Automatic redirect following is already disabled in `:httpc.request/4`
  (no `follow_redirects` option is passed) — the requirement asks for an
  explicit regression test confirming this status-quo, not a change to it
  (AC5).

---

## §1 Module boundary decision

**Decision: new `Letflow.Webhooks.UrlValidator` module.** Not private
functions in `Letflow.Webhooks`.

**Reasoning:**

1. **The `@moduledoc` must carry the full blocked-range list and the
   "Letflow's own choice" disclaimer** (requirement constraint §3, AC7).
   Attaching that to a `@moduledoc` on a dedicated module is far clearer
   than scattering it across several `@doc` annotations on private helpers
   in a 700-line file.

2. **Independent testability.** The acceptance criteria include one test per
   blocked address (AC2: 5 addresses), a scheme test (AC1), and a DNS-
   rebinding test (AC4). All of these require injecting a custom DNS
   resolver. With a dedicated module the `@spec` surfaces a `dns_resolver`
   argument on `validate/2`; tests import and call
   `UrlValidator.validate(url, custom_resolver)` directly without touching
   the full `create/2` machinery.

3. **Keeps `Letflow.Webhooks` focused.** That module is already 698 lines
   handling CRUD, secrets, retry logic, and DLQ. The IP-range arithmetic
   (`blocked_ipv4?/1`, `blocked_ipv6?/1`, `ipv4_mapped_to_ipv4/1`) is
   logically independent and noisy — isolating it prevents further growth
   of an already-long module.

4. **INV-9 names a concrete module** as its "Reference" (§5 below). A
   dedicated module gives SECURITY-REVIEWER an unambiguous grep target for
   future audits.

### 1.1 File location

`lib/letflow/webhooks/url_validator.ex`

---

## §2 Function signatures

### 2.1 `Letflow.Webhooks.UrlValidator` — public surface

```elixir
@type dns_resolver ::
  (charlist() ->
     {:ok, [{:inet, {byte(), byte(), byte(), byte()}, []} |
            {:inet6,
             {0..65535, 0..65535, 0..65535, 0..65535,
              0..65535, 0..65535, 0..65535, 0..65535}, []}]}
     | {:error, term()})
```

```elixir
@spec validate(url :: String.t()) ::
        :ok | {:error, :target_url_not_allowed}
```

Production entry point. Calls `validate(url, &:inet.getaddrinfo/1)`.

```elixir
@spec validate(url :: String.t(), dns_resolver()) ::
        :ok | {:error, :target_url_not_allowed}
```

Full entry point used in tests (custom resolver injected). Parses the URL
via `URI.parse/1`, then calls `check_scheme/1` and `check_host/2` in
sequence, short-circuiting on first rejection. Returns `:ok` only when both
pass.

### 2.2 `Letflow.Webhooks.UrlValidator` — private helpers

```elixir
@spec check_scheme(URI.t()) :: :ok | {:error, :target_url_not_allowed}
```

Passes iff `uri.scheme == "https"`. All other schemes (including `"http"`,
`"ftp"`, `nil`) are rejected. Empty or unparseable URL (nil scheme, nil
host) is also rejected here.

```elixir
@spec check_host(URI.t(), dns_resolver()) :: :ok | {:error, :target_url_not_allowed}
```

Dispatches to `check_ip_literal/1` first (handles bare-IP hosts without
a DNS lookup), then falls through to `resolve_and_check/2` for hostnames.
A `nil` or empty host returns `{:error, :target_url_not_allowed}`.

```elixir
@spec check_ip_literal(host :: String.t()) ::
        :ok | {:error, :target_url_not_allowed} | :not_an_ip
```

Attempts to parse `host` as a raw IPv4 or IPv6 address using
`:inet.parse_address(charlist(host))`:
- `{:ok, {a, b, c, d}}` (4-tuple) → `blocked_ipv4?/1` → reject or pass
- `{:ok, {a, b, c, d, e, f, g, h}}` (8-tuple) → `blocked_ipv6?/1` → reject
  or pass
- `{:error, _}` → host is not a bare IP literal → returns `:not_an_ip` so
  `check_host/2` falls through to DNS resolution

IPv6 literals in URLs are bracket-wrapped (`[::1]`); strip brackets before
calling `:inet.parse_address/1`.

```elixir
@spec resolve_and_check(host_charlist :: charlist(), dns_resolver()) ::
        :ok | {:error, :target_url_not_allowed}
```

Calls `dns_resolver.(host_charlist)`:
- On `{:ok, addrs}`: iterates each `{:inet, tuple, _}` and `{:inet6, tuple,
  _}` entry; if **any** resolved address passes `blocked_ipv4?/1` or
  `blocked_ipv6?/1`, returns `{:error, :target_url_not_allowed}` — all
  addresses must be public for the host to pass.
- On `{:error, _}` (NXDOMAIN, DNS timeout, unreachable): returns
  `{:error, :target_url_not_allowed}`. A hostname that does not resolve
  cannot be allowed — a non-resolving name is treated as blocked, not as
  "permitted because we couldn't check."

```elixir
@spec blocked_ipv4?({byte(), byte(), byte(), byte()}) :: boolean()
```

Returns `true` if the address falls in any of the following ranges
(Letflow's own choice, not ported from R-Co):
- 127.0.0.0/8 — loopback
- 10.0.0.0/8 — RFC-1918 private
- 172.16.0.0/12 — RFC-1918 private
- 192.168.0.0/16 — RFC-1918 private
- 169.254.0.0/16 — link-local (includes 169.254.169.254, IMDS)

```elixir
@spec blocked_ipv6?(
        {0..65535, 0..65535, 0..65535, 0..65535,
         0..65535, 0..65535, 0..65535, 0..65535}
      ) :: boolean()
```

Returns `true` if:
- Address equals `{0, 0, 0, 0, 0, 0, 0, 1}` — `::1/128` loopback
- `(a &&& 0xFE00) == 0xFC00` — `fc00::/7` ULA (unique local)
- Address is IPv4-mapped-IPv6 (`{0, 0, 0, 0, 0, 0xFFFF, hi, lo}`) or
  IPv4-compatible-IPv6 (`{0, 0, 0, 0, 0, 0, hi, lo}`) **and** the
  extracted IPv4 `{hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}` passes
  `blocked_ipv4?/1`

```elixir
@spec ipv4_from_mapped_ipv6(
        {0..65535, 0..65535, 0..65535, 0..65535,
         0..65535, 0..65535, 0..65535, 0..65535}
      ) :: {byte(), byte(), byte(), byte()} | nil
```

Returns the embedded IPv4 quad for `::ffff:A.B.C.D` and `::A.B.C.D`
forms, or `nil` for all other IPv6 addresses. Used by `blocked_ipv6?/1`
to delegate the private-range check to `blocked_ipv4?/1` for these forms.

---

## §3 Integration points

### 3.1 `Letflow.Webhooks.create/2` — exact insertion point

Location: `lib/letflow/webhooks.ex`, function `create/2`.

Current code structure:
```
def create(attrs, opts) when is_map(attrs) and is_list(opts) do
  prefix = Keyword.fetch!(opts, :prefix)
  with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
    ...Multi...
  end
end
```

ELIXIR-DEV inserts a URL validation guard **before** the `with` block, as a
separate `with` clause or a direct pattern-match short-circuit:

```
# Conceptual structure only — no implementation bodies here
with :ok <- UrlValidator.validate(Map.get(attrs, :target_url, "")),
     {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
  ...existing Multi body...
else
  {:error, :target_url_not_allowed} -> {:error, :target_url_not_allowed}
  {:error, reason} -> {:error, reason}
end
```

**Error return:** `{:error, :target_url_not_allowed}` — a new tagged atom
error, no changeset, no DB round-trip when the URL is rejected. This must be
added to `create/2`'s `@spec`:

```elixir
@spec create(create_attrs(), opts()) ::
        {:ok, %{subscription: Subscription.t(), hmac_secret_once: String.t()}}
        | {:error, :target_url_not_allowed}           # ← new
        | {:error, {:secret_write_failed, term()}}
        | {:error, Ecto.Changeset.t()}
```

**DNS resolution at `create/2` time:** `UrlValidator.validate/1` (the 1-arity
form) performs a live DNS lookup for hostname-based targets. This is
intentional: fast feedback at subscription-creation time. Bare-IP targets in
blocked ranges are rejected immediately by `check_ip_literal/1` without
any DNS round-trip (constraint §4).

### 3.2 `dispatch_http/3` — exact insertion point

Location: `lib/letflow/webhooks.ex`, private function `dispatch_http/3`.

Current code structure (lines ~358–385):
```
defp dispatch_http(target_url, json_body, signature) do
  headers = [...]
  request = {String.to_charlist(target_url), headers, ...}
  case :httpc.request(:post, request, ...) do
    ...
  end
end
```

ELIXIR-DEV inserts a validation call **before the `headers` construction**:

```
# Conceptual structure — no implementation bodies here
defp dispatch_http(target_url, json_body, signature) do
  case UrlValidator.validate(target_url) do
    {:error, :target_url_not_allowed} ->
      {:FAILED, nil, "target_url not allowed (SSRF protection)"}
    :ok ->
      headers = [...]
      ...existing :httpc.request/4 call...
  end
end
```

**Return on rejection:** `{:FAILED, nil, "target_url not allowed (SSRF
protection)"}` — the same 3-tuple shape `dispatch_http/3` already returns
for transport errors (line ~380), so `attempt_loop` receives it without any
new match arm. The `last_error` string is fixed text, not a reflection of
the rejected URL — no internal network information leaks into the
`webhook_delivery_attempts` row.

**This call uses the production `UrlValidator.validate/1` (1-arity, real
DNS).** For DNS-rebinding test coverage, see §6.

---

## §4 IP range check algorithm

### 4.1 IPv4 tuple checks (`blocked_ipv4?/1`)

Each check uses OTP integer pattern matching on the 4-tuple
`{a, b, c, d}` where each element is `0..255`. No bitwise ops needed for
most ranges:

| Range | Elixir guard / match |
|---|---|
| 127.0.0.0/8 | `a == 127` |
| 10.0.0.0/8 | `a == 10` |
| 172.16.0.0/12 | `a == 172 and b >= 16 and b <= 31` |
| 192.168.0.0/16 | `a == 192 and b == 168` |
| 169.254.0.0/16 | `a == 169 and b == 254` |

169.254.169.254 is covered by the 169.254.0.0/16 row above — no separate
clause is needed, but the `@moduledoc` must call it out explicitly by name
(constraint §3, AC7).

### 4.2 IPv6 tuple checks (`blocked_ipv6?/1`)

The IPv6 tuple is `{a, b, c, d, e, f, g, h}` where each element is
`0..65535`.

| Range | Check |
|---|---|
| `::1/128` | exact match `{0,0,0,0,0,0,0,1}` |
| `fc00::/7` | `Bitwise.band(a, 0xFE00) == 0xFC00` |
| IPv4-mapped `::ffff:A.B.C.D` | `{0,0,0,0,0,0xFFFF,hi,lo}` → extract IPv4, delegate to `blocked_ipv4?/1` |
| IPv4-compatible `::A.B.C.D` | `{0,0,0,0,0,0,hi,lo}` where `hi != 0 or lo > 1` → extract IPv4, delegate |

IPv4 extraction from `{hi, lo}` segments: `{hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}`.

Note: `Bitwise` is an OTP stdlib module (`import Bitwise` suffices — no hex
dep). For the `fc00::/7` check, a function-clause guard using
`Bitwise.band/2` is clean; alternatively, pattern-match on `a` values
`0xFC00..0xFDFF` (the exact range covered by fc00::/7) without importing
`Bitwise` at all — either is fine, ELIXIR-DEV's choice.

### 4.3 Handling `check_ip_literal/1` bracket-stripped IPv6

IPv6 literals appear in URLs as `[::1]` (RFC-3986 bracket form). `URI.parse/1`
returns the `host` field **with brackets stripped** in Elixir 1.14+. ELIXIR-DEV
must verify this at implementation time and add an explicit bracket-strip
(`String.trim_leading/2`, `String.trim_trailing/2`) as a defensive measure
regardless, since `:inet.parse_address/1` does not accept brackets.

---

## §5 INV-9 text (ready to paste into `security-invariants.md`)

---

## INV-9 — Tenant-controlled outbound URL validation

**Rule.** Any URL a Letflow server process will make an outbound HTTP/HTTPS
request to, where that URL is derived from tenant-controlled input, must pass
**both** a scheme allowlist (only `"https"` is permitted — no `"http"`, no
other scheme) **and** a private-range rejection check at the point of the
actual request call — not at ingestion time alone. DNS rebinding (a hostname
that resolved to a public IP at subscription-registration time but resolves
to a private IP at delivery time) does not defeat the protection because the
check runs immediately before every `:httpc.request/4` call.

The set of rejected IP ranges is **Letflow's own choice**, not ported from
R-Co (R-Co's `src/webhook/` SSRF handling is not inspectable from this
codebase's history):

- 127.0.0.0/8 — loopback
- 10.0.0.0/8 — RFC-1918 private
- 172.16.0.0/12 — RFC-1918 private
- 192.168.0.0/16 — RFC-1918 private
- 169.254.0.0/16 — link-local, including 169.254.169.254 (cloud metadata) explicitly
- ::1/128 — IPv6 loopback
- fc00::/7 — IPv6 ULA (unique local)
- IPv4-mapped-IPv6 forms (::ffff:A.B.C.D and ::A.B.C.D) of any of the IPv4
  ranges above

**Reference.** `Letflow.Webhooks.UrlValidator` (`lib/letflow/webhooks/url_validator.ex`,
REQ-204). Enforced at two call sites: `Letflow.Webhooks.create/2` (fast
tenant feedback at subscription-creation time, returns
`{:error, :target_url_not_allowed}` for blocked URLs) and the private
`Letflow.Webhooks.dispatch_http/3` (defence-in-depth, runs immediately
before every `:httpc.request/4` call, returns `{:FAILED, nil, "target_url
not allowed (SSRF protection)"}` for blocked URLs at dispatch time).

**How to verify.**
(1) `mix test test/letflow/webhooks/url_validator_test.exs` — must include
    a named test per blocked range (127.x, 10.x, 172.16–31.x, 192.168.x,
    169.254.x including 169.254.169.254 by name, ::1, fc00::, IPv4-mapped
    forms) plus a non-https scheme test and a legitimate-https pass test.
(2) `mix test test/letflow/webhooks_test.exs` — must include tests for
    `create/2` rejecting non-https scheme (AC1), `create/2` rejecting each
    of the five explicit addresses in AC2, `create/2` succeeding with a
    legitimate https target (AC3), `deliver/3` DNS-rebinding scenario (AC4,
    using an injected resolver that returns a private IP), and explicit
    assertion that `dispatch_http/3` does not follow 3xx redirects (AC5).
(3) SECURITY-REVIEWER confirms any new route or internal code path that
    makes an outbound HTTP request using a tenant-supplied URL has a
    corresponding `UrlValidator.validate/2` call in its dispatch path before
    the `:httpc` (or future HTTP client) call.

**Severity.** BLOCKER.

---

## §6 Test hooks

### 6.1 DNS resolver injection

`UrlValidator.validate/2` (2-arity) accepts a `dns_resolver` function as
its second argument. Its type is stated in §2.1. In production, `validate/1`
(1-arity) delegates to `validate(url, &:inet.getaddrinfo/1)`. Tests call the
2-arity form directly with a custom function, e.g.:

```
# Conceptual — no implementation body
custom_resolver = fn _host -> {:ok, [{:inet, {169, 254, 169, 254}, []}]} end
UrlValidator.validate("https://example.com", custom_resolver)
# => {:error, :target_url_not_allowed}
```

This handles AC1, AC2, AC3, and all `url_validator_test.exs` scenarios
without any real DNS round-trips and without process dictionary tricks.

### 6.2 DNS resolver injection at `dispatch_http/3`

`dispatch_http/3` is private and currently takes `(target_url, json_body,
signature)`. Because it calls `UrlValidator.validate/1` (1-arity, real DNS),
the DNS-rebinding test (AC4) cannot reach this path's validation call
directly with a custom resolver through the public `deliver/3` API.

**Recommended mechanism:** add a 4th private `dispatch_http/4` overload that
accepts `dns_resolver` as the fourth argument; the existing 3-arity calls
`dispatch_http(url, body, sig, &:inet.getaddrinfo/1)`. Tests that need to
exercise the rebinding scenario call `deliver/3` against a subscription whose
`target_url` is a hostname, and configure the DNS resolver via a test helper
or module attribute override. Alternatively, ELIXIR-DEV may thread the
resolver through `attempt_loop` and `deliver/3` — this is more invasive but
fully explicit. **ELIXIR-DEV should choose the approach most consistent with
how other DNS/HTTP-client overrides exist in the test suite today (if any);
if none exist, prefer the 4-arity `dispatch_http/4` approach to contain the
change surface.**

The key constraint: the DNS-rebinding test (AC4) must exercise the
`dispatch_http/3` path's validation call with a resolver that returns a
private IP, assert `{:FAILED, nil, "target_url not allowed (SSRF
protection)"}`, and assert that a corresponding `webhook_delivery_attempts`
row with `status: :FAILED` and the `last_error` text was persisted.

### 6.3 No-redirect assertion (AC5)

The AC5 test asserts that `:httpc.request/4` is called without any
`follow_redirects: true` option. This is a documentation/configuration
assertion, not a DNS hook. ELIXIR-DEV may implement it as a unit test that
reads `dispatch_http/3`'s source options list (source-assertion pattern —
proven robust in this codebase per `docs/anti-patterns.md` / memory notes),
or as an integration test that observes a 302 response is returned as
`{:FAILED, 302, _}`, not transparently followed.

---

## §7 Open questions

**OQ-1 — IPv6 link-local (fe80::/10) not in the explicit REQ-204 blocklist.**
`fe80::/10` is the IPv6 equivalent of 169.254.0.0/16 (both are link-local).
REQ-204's explicit list omits it. ELIXIR-DEV should flag this to REVIEWER
at implementation time and recommend adding it to `blocked_ipv6?/1` and to
the INV-9 text — but must not silently add it as scope creep. If REVIEWER
approves, the INV-9 text in §5 is updated before ELIXIR-DEV merges.

**OQ-2 — Nil / empty host after `URI.parse/1`.**
`URI.parse("https://")` returns `%URI{host: nil}`. The design specifies this
is treated as `{:error, :target_url_not_allowed}` (same atom — no new error
code introduced). If ELIXIR-DEV disagrees and prefers a distinct
`:invalid_url` atom, this must be resolved with CODE-DESIGN-VALIDATOR before
implementation, because `create/2`'s `@spec` and the test suite's expected
error shapes both depend on it.

**OQ-3 — DNS failure at `create/2` time treated as blocked.**
`resolve_and_check/2` returns `{:error, :target_url_not_allowed}` on any
DNS error (NXDOMAIN, timeout). This is conservative: a tenant registering a
valid public webhook that is temporarily unresolvable will get rejected and
must retry. This is intentional — a hostname that cannot be verified safe is
treated as unsafe. TEST-DESIGNER should add a test asserting this behaviour
explicitly (e.g. resolver returns `{:error, :nxdomain}`).

**OQ-4 — `validate/2` in `dispatch_http/3` is called on every retry attempt.**
`attempt_loop` calls `dispatch_http/3` up to `@max_attempts` (4) times.
Each call re-validates. This is the correct defence-in-depth behavior (DNS
rebinding can happen between attempts), but adds up to 4 DNS lookups per
delivery. At the current `@max_attempts = 4` and `@http_timeout_ms = 10_000`,
this is acceptable. If DNS resolution becomes a performance concern, a future
requirement may cache the resolver result within a single `deliver/3`
invocation — that is deliberately not implemented here.
