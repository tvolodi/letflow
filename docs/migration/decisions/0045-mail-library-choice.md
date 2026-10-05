# 0045 -- Mail library for the login-discovery notifier adapter (REQ-441)

Status: PROPOSED. Not ratified (REVIEWER and SECURITY-REVIEWER sign it off in the implementation review).
The dependency was approved by the supervisor; the chosen library is gen_smtp ALONE (see sections 8 and 9). The new hex dependency this record recommends is a HARD STOP:
it needs explicit approval from the supervisor / repo owner before ELIXIR-DEV may touch `mix.exs`
or `mix.lock`. Until then no dependency is added and `mix deps.get` is not run.

Date: 2026-10-05. Drafted by `CODE-DESIGNER` (run WF02-REQ441-20261005, step 01). Owner: `ORCH`.

Amends / supersedes: nothing. Consistent with 0042 (prohibitions, OQ-4), 0043 D-B (SMTP first,
provider-agnostic port), 0044 (Phase 1 only). It does not lift the lawful-basis gate (0042 OQ-3 /
0043 D-D); that stays OPEN and still gates enabling the feature outside dev.

Companion design: `lib/letflow/design/req441-mail-notifier-adapter.md` (module list, config,
failure handling, tests). This record holds only the library decision.

Conventions. Facts about hex packages below come from the ORCH research pass of 2026-10-05
(hex.pm API) and were NOT re-fetched by this drafter (no network call was made). They are marked
"hex.pm, ORCH" and are data for the decision, not claims about library internals. Every statement
about what a library DOES at runtime (TLS defaults, retries, logging, process model) is marked
"to verify against deps/ source after approval" per `docs/anti-patterns.md` ("Claiming a
DEPENDENCY's runtime behavior without reading its actual source"). This record deliberately does
not rest on any such claim: the recommendation is robust to each of them being false, because the
design makes every security-relevant option explicit and tests it against an in-process sink.

---

## 1. Context

REQ-441 builds the real adapter behind the REQ-437 port `Letflow.LoginDiscovery.Notifier`
(`lib/letflow/login_discovery/notifier.ex:17-20`, one callback `deliver_tenant_list/2`). The port
is the provider abstraction; SMTP is the first adapter (0043 D-B; REQ-441 text). The requirement
proposes Swoosh with its SMTP adapter over gen_smtp, and names Bamboo and bare gen_smtp as
alternatives; the choice is the CODE-DESIGNER's and must be recorded here.

What the repository has today (read 2026-10-05): outbound HTTP only through `:httpc` (OTP `inets`;
`mix.exs` `extra_applications: [:logger, :inets, :ssl]`, `mix.exs:31`); no Finch, Req, Tesla or
hackney in `mix.lock`; `deps/` contains no mail library; `mix.lock` already holds rebar3-built
packages (`yamerl`, `mix.lock:29`) and the build image runs `mix local.rebar --force`
(`deploy/Dockerfile:11`), so an Erlang/rebar3 package builds in CI and the image. The runtime image
installs `ca-certificates` (`deploy/Dockerfile:33-39`), so OS-trust-store verification works in
production. Toolchain: Elixir 1.20.3 / OTP 29 (`deploy/Dockerfile:4`), `mix.exs` `elixir: "~> 1.18"`.

Constraints on the library (from REQ-441 and the invariants):

1. Verified TLS to the relay by default; plaintext only on explicit opt-in and never in `:prod`.
2. No automatic retry (a retry loop is an email-bombing amplifier; the `:send` bucket is consumed
   once per attempt).
3. The SMTP password must not reach a log, a crash report, telemetry metadata or an inspected
   struct (INV-4).
4. No reply text or exception text may be surfaced (INV-8, REQ-441 item 3).
5. Header and body construction must leave no way for tenant text to become a header (the only
   request-derived header value is the recipient).
6. Smallest viable addition to the dependency tree: this is a security-sensitive egress path.

## 2. Options considered

### O1. Swoosh + `Swoosh.Adapters.SMTP` (gen_smtp)  -- the requirement's proposal

hex.pm (ORCH): swoosh 1.28.1 (2026-09-16), MIT, 22.7M downloads, monthly releases; required deps
idna (>= 6, < 8), jason, mime, telemetry (all but idna already in `mix.lock`: jason 1.4.5,
mime 2.0.7, telemetry 1.4.2); gen_smtp is OPTIONAL in swoosh and must be added explicitly.
gen_smtp 1.3.0 (2025-05-30), BSD-2-Clause, 36M downloads, one required dep `ranch` (>= 1.8.0;
ranch 2.3.0, ISC, no deps). idna 7.1.0, MIT, no deps. New lock entries: swoosh, gen_smtp, ranch,
idna = 4 packages.

Hazards that are documented in the Swoosh docs per the ORCH pass (still "to verify against deps/
source"): (a) the SMTP adapter does NOT verify TLS unless `tls_options` carry `verify: :verify_peer`,
CA certs, SNI and a hostname match function; (b) the documented example uses `retries: 2`, we need
0; (c) `Swoosh.Mailer` wraps `deliver` in `:telemetry.span([:swoosh, :deliver], ...)` whose
metadata carries the email struct and the adapter config (including the password) and the
`:exception` event carries reason and stacktrace; (d) a warning when `:api_client` is unset
(`config :swoosh, :api_client, false` silences it for SMTP-only use).

Mitigation if chosen: do NOT define a `use Swoosh.Mailer` module; call the adapter's `deliver/2`
directly with a config built at the call site (so no span is emitted); set `retries: 0` and explicit
verified-TLS options; set `:api_client` false. That removes hazards (c) and (d) but leaves Swoosh as
a layer that we bypass for its only value (the Mailer).

### O2. Swoosh + `Swoosh.Adapters.Mua` (pure-Elixir SMTP client)

hex.pm (ORCH): mua 0.2.6 (2025-12-07), MIT, 167k downloads, pure Elixir over `:gen_tcp`/`:ssl`,
optional `castore` only (not needed on OTP >= 25); mail 0.5.2, MIT, no deps (the Swoosh Mua adapter
doc text says "mail ~> 0.3.0": the exact requirement must be read from swoosh 1.28.1's `mix.exs`
after approval). New lock entries: swoosh, mua, mail, idna = 4 packages; no Erlang package, no
ranch. Per the ORCH pass Mua verifies TLS against system CA certs by default and uses a short-lived
connection per delivery, which is the safer default posture. Costs: roughly two orders of magnitude
fewer downloads than gen_smtp (167k vs 36M), a 0.x version line, and it is reached through Swoosh
(so the same Mailer/telemetry hazards (c) and (d) apply, and the same "bypass the Mailer" mitigation).
Whether mua retries, how it handles STARTTLS downgrade (a server that omits the STARTTLS capability)
and what it logs: to verify against deps/ source.

### O3. gen_smtp alone (`:gen_smtp_client` called from our own adapter module)  -- RECOMMENDED

New lock entries: gen_smtp, ranch = 2 packages (smallest of the library options). No Mailer, no
telemetry span, no `:api_client` warning, no extra abstraction we would bypass. Our adapter builds a
fixed text/plain message and hands it, with every security-relevant option spelled out in our own
code (TLS mode, verify options, `retries` 0, timeouts), to `:gen_smtp_client`. Message encoding of
non-ASCII display names is delegated to gen_smtp's own `mimemail` encoder rather than hand-written.
Costs: the Erlang proplist/tuple API is less idiomatic from Elixir; if a second message kind
(HTML, attachments) is needed later, the message builder grows by hand (invitations and password
recovery are expected later but are explicitly NOT built here; fixed plain-text templates are what
they would need first, and the port is not widened for them). The "retries" semantics, the exact
option names, whether the password can appear in a crash report of an internal worker process and
the STARTTLS-downgrade behaviour: all to verify against deps/ source after approval, with the design's
mitigations (section 4 of the design) independent of the answer.

### O4. In-house SMTP client over `:gen_tcp` / `:ssl`  -- NOT recommended

Zero dependencies, full control. But this is a security-sensitive protocol implementation we would
own: the STARTTLS state machine (including refusing to continue in plaintext when the server does
not offer it, and discarding pre-TLS buffered bytes after the upgrade, which is the classic
STARTTLS command-injection class), multi-line reply parsing, AUTH PLAIN/LOGIN framing, dot-stuffing
and CRLF normalisation in DATA, RFC 2047 / MIME encoding for UTF-8 text, RFC 5322 header folding
and injection defence, and TLS verification options on a connection that is upgraded in place.
Each is individually small and each is a known source of CVEs in mail libraries. Two maintained
libraries already exist at modest dependency cost. Rejected unless both O1..O3 are refused for a
concrete reason; if that happened, the decision would have to be re-opened with a separate design
and SECURITY-REVIEWER sign-off on the protocol code itself.

### O5. HTTP-API transactional-mail provider over `:httpc`  -- later second adapter, not first

Zero new dependencies (`:httpc` is already the repo's HTTP client) and the port was designed to
allow it. But a vendor must be chosen (a business/privacy/contract decision this record cannot make:
data-processing agreement, region, price, API key custody), and the REQ text and BA decision D-B
mandate SMTP first: REQ-441 acceptance criteria name an in-process local SMTP sink and the
`LETFLOW_SMTP_*` variables. It also moves the egress target from an operator-configured relay host to a
vendor URL, which brings INV-9 considerations of its own (fixed https URL from config, still not
tenant-controlled). Recorded as the expected second adapter behind the same port (a new requirement,
a new `LETFLOW_MAIL_ADAPTER` value, a new decision record naming the vendor). Nothing here forecloses it.

### O6. Bamboo -- rejected

bamboo 2.5.0 (2025-07-25), MIT (hex.pm, ORCH). Requires hackney >= 1.15.2 and its tree (certifi, idna,
metrics, mimerl, parse_trans, ssl_verify_fun, unicode_util_compat) plus mime and plug. That
introduces an HTTP client the repository does not otherwise use, for a feature that needs SMTP. Not
a candidate unless something not found in the research changes this.

## 3. Trade-off table

| Criterion | O1 Swoosh + gen_smtp | O2 Swoosh + Mua | O3 gen_smtp alone | O4 in-house | O5 HTTP provider |
|---|---|---|---|---|---|
| New lock entries | 4 (swoosh, gen_smtp, ranch, idna) | 4 (swoosh, mua, mail, idna) | 2 (gen_smtp, ranch) | 0 | 0 |
| Matches REQ text (SMTP, local sink AC) | yes (the proposal) | yes | yes | yes | no (vendor, not SMTP) |
| Verified TLS by default | no per docs (explicit options needed) | yes per docs (to verify) | no assumed; explicit options set by us | by us | https via httpc, by us |
| Mitigation burden | high (TLS, retries, telemetry span, api_client) | medium (telemetry span, api_client, mail version) | medium (TLS, retries) | highest (whole protocol) | low (but vendor) |
| Telemetry leaks password/recipient | yes unless Mailer bypassed | yes unless Mailer bypassed | none (no span) | none | none |
| Maturity / adoption (hex.pm, ORCH) | high | low (167k dl, 0.x) | high (36M dl) | none | n/a |
| Idiomatic Elixir API | high | high | low (Erlang API) | n/a | medium |
| Future HTML / attachments / templating | best | good | by hand (not needed now) | by hand | provider |
| Security-sensitive code we own | smallest | smallest | small (one adapter module) | large | small |
| Needs vendor/legal/commercial decision | no | no | no | no | YES |

## 4. Decision (PROPOSED)

Adopt **O3: gen_smtp alone**, with the library call confined to one module so the choice stays
reversible.

Reasons, in order of weight:

1. Smallest dependency footprint on a security-sensitive egress path (2 lock entries vs 4), with
   the most widely used SMTP implementation of the options.
2. The only thing Swoosh would add for this requirement is the Mailer and the `Swoosh.Email` struct.
   The Mailer is exactly the part that must be bypassed (its telemetry span would carry the
   recipient address and the adapter config including the password; the REQ forbids both in
   telemetry). A layer that must be bypassed to be safe is a net cost here.
3. The port is already the provider abstraction. A later HTTP-provider adapter (O5) and a later
   richer-message need do not depend on Swoosh being present today.
4. Every risk that differs between libraries (TLS verification, retries, password in crash reports,
   STARTTLS downgrade) is closed in our own code and proven by tests against an in-process sink,
   not assumed from a library default. The design lists each as a "to verify against deps/ source"
   item for ELIXIR-DEV and SECURITY-REVIEWER.

This DIVERGES from the requirement's proposal (Swoosh + SMTP adapter). The requirement explicitly
allows "a bare gen_smtp" and delegates the choice to CODE-DESIGNER; the divergence is therefore
within scope, but it is flagged for the supervisor to see before approving.

Acceptable alternatives if the supervisor prefers: **O1** (accept 2 more packages; the design's
module list is unchanged except the library call module; the Mailer must not be used) or **O2**
(if gen_smtp's verified-TLS or no-retry behaviour cannot be demonstrated from its source). A
fallback trigger is defined: if, after approval, reading `deps/gen_smtp` shows that STARTTLS with
verified TLS and zero retries cannot be configured and tested, ELIXIR-DEV stops and reports; the
decision is reopened toward O2, it is not worked around.

## 5. Consequences

- `mix.exs` gains exactly one direct dependency (gen_smtp, version constraint to be set by
  ELIXIR-DEV to the then-current minor line; hex.pm shows 1.3.0 on 2025-05-30). `mix.lock` gains
  gen_smtp and ranch. No other dependency, no `extra_applications` change beyond what OTP-app
  start of `:gen_smtp` requires (to verify; `:ssl` is already listed).
- License review: gen_smtp BSD-2-Clause, ranch ISC; both permissive (hex.pm, ORCH).
- Supply chain: two new packages to pin by lock hash; `mix hex.audit` / audit tooling in CI, if any,
  should be re-run after the add (ELIXIR-DEV to report the real output).
- Windows dev hosts: gen_smtp is built with rebar3 (as `yamerl` already is); `mix local.rebar` must
  work, which CI and the image already require.
- No behaviour changes until `LETFLOW_MAIL_ADAPTER=smtp` is set; the default stays the Noop adapter.

## 6. Hard stops this decision raises (none is resolved here)

1. **New runtime dependency** (gen_smtp, ranch): needs supervisor / owner approval before any
   `mix.exs`, `mix.lock` or `mix deps.get`.
2. **New environment variables, credentials and a host** (`LETFLOW_SMTP_*`, `LETFLOW_MAIL_*`,
   `LETFLOW_PUBLIC_BASE_URL`): a real SMTP relay and credentials owned by the platform operator
   (0042 OQ-4).
3. **External infrastructure, not in this repository**: ai-dala-infra secrets-inventory entries for
   the SMTP username/password and the relay per environment; sender-domain SPF / DKIM / DMARC
   alignment. Recorded only; this repository does not edit them.
4. **Legal gate (unchanged)**: 0042 OQ-3 / 0043 D-D lawful basis and controller. This work makes the
   adapter real; it does not lift the gate that keeps the feature off outside dev.

## 6a. Conditions on the approval (SECURITY-REVIEWER design review, rework 1)

Approval of the dependency is conditional on, and ELIXIR-DEV must evidence in its handoff:
1. Lock entries pinned by hash; `mix hex.audit` run and its real output quoted.
2. Starting the `:gen_smtp` application opens no listening socket (gen_smtp also ships server-side code
   and uses ranch): a test proves it, or the application is not started.
3. `deps/gen_smtp` source read and quoted for every item of design section 1.3, including the binding
   single-process Transport contract (a blocking send in the calling process, no linked or unlinked
   worker; if the library cannot meet it, this decision reopens toward Swoosh + Mua, it is not worked
   around).
4. Fail-closed STARTTLS proven against the in-process sink (server offers no STARTTLS: zero AUTH, zero
   MAIL FROM, no password bytes on the wire).
5. If Swoosh is chosen instead: no `use Swoosh.Mailer` (grep guard), no handler on `[:swoosh, ...]`,
   `config :swoosh, :api_client, false`, retries 0, and the adapter config holding the password built
   only inside the inner task.

## 7. Open questions on the decision

- OQ-A. Supervisor choice between O3 (recommended), O1 and O2, given section 4.
- OQ-B. If a later requirement wants HTML or templated mail, is that a trigger to move to O1/O2 (a
  new decision record), or is gen_smtp's `mimemail` enough? Not decided here; not needed by REQ-441.
- OQ-C. The vendor for the eventual second (HTTP) adapter (O5): out of scope; needs its own record.

## 8. Chosen library (implementation record, REQ-441 step 02a)

Status of this record stays PROPOSED: REVIEWER and SECURITY-REVIEWER sign it off in the implementation
review. The dependency itself was approved by the supervisor on the condition set recorded in the
step-02a handoff.

**The chosen library is `gen_smtp` ALONE** (O3): `{:gen_smtp, "~> 1.3"}` in `mix.exs`, resolved to
gen_smtp 1.3.0 and ranch 2.3.0, the only two new `mix.lock` entries. No Swoosh, no Mua, no Mailer, no
`mimemail` encoder call (see 9.5).

**Deviation from the requirement's proposal (Swoosh + SMTP adapter over gen_smtp), and why.** The
requirement permitted "a bare gen_smtp" and delegated the choice to CODE-DESIGNER, so this is within
scope; it is recorded here because it differs from the proposal text:

1. A `Swoosh.Mailer` wraps delivery in a telemetry span (`[:swoosh, :deliver]`) whose metadata carries
   the email and the adapter config, including the SMTP password (hex.pm / Swoosh docs per the ORCH
   research; not re-verified against Swoosh source because Swoosh is not added). REQ-441 forbids the
   address and the password in telemetry. The safe use of Swoosh is to bypass its Mailer, which is
   the part that is its value here.
2. Swoosh's SMTP adapter does not verify TLS unless `tls_options` carry verify mode, CA certs, SNI
   and a hostname match function (per the Swoosh docs); our code must set all of that anyway.
3. Swoosh's documented SMTP example uses `retries: 2`; this requirement needs a single attempt.
4. Lock footprint: 2 new entries (gen_smtp, ranch) against 4 (swoosh, gen_smtp, ranch, idna).

## 9. Verified against deps/gen_smtp 1.3.0 source

Read in this worktree on 2026-10-05, from `deps/gen_smtp/src/` (hex package gen_smtp 1.3.0; lock
inner checksum `62c3d91f0dcf6ce9db71bcb6881d7ad0d1d834c7f38c13fa8e952f4104a8442e`, outer
`0b73fbf069864ecbce02fe653b16d3f35fd889d0fdd4e14527675565c39d84e6`; ranch 2.3.0 inner
`7de7b041a9a6a5091a3aa5898d66c0564be671d87db4f9d63b1b5ee775b097df`, outer
`6168ec49409d982f7cfbd83dd083144f6cbe67caa4036551d2f0a3ad67c9d023`). `mix hex.audit` output:
`No retired or security advisory packages found`. Line numbers are those of the shipped files.

### 9.1 (a) Fail-closed STARTTLS

`gen_smtp_client.erl:32` default is `{tls, if_available}` (a fallback to plaintext), so the adapter sets
`tls: :always`. `gen_smtp_client.erl:780-802`:

```erlang
try_STARTTLS(Socket, Options, Extensions) ->
    case {proplists:get_value(tls, Options), proplists:get_value(<<"STARTTLS">>, Extensions)} of
        {Atom, true} when Atom =:= always; Atom =:= if_available ->
            ...
            case {do_STARTTLS(Socket, Options), Atom} of
                {false, always} ->
                    quit(Socket),
                    erlang:throw({temporary_failure, tls_failed});
                {false, if_available} ->
                    {Socket, Extensions};
        ...
        {always, _} ->
            quit(Socket),
            erlang:throw({missing_requirement, tls});
```

With `always`: a server that does not offer STARTTLS throws `{missing_requirement, tls}` (line 796-798),
and a failed upgrade throws `{temporary_failure, tls_failed}` (line 785-788); only `if_available`
continues in plaintext (line 789-791). The `tls_failed` retry fallback to no-TLS
(`handle_smtp_throw/4`, lines 335-350) is taken only for `if_available`; for `always` it goes to
`try_next_host/4` (line 349), which with `retries: 0` ends the attempt (9.2). AUTH is attempted after
`try_STARTTLS` (`open_smtp_session/2`, lines 389-391), so a refused upgrade means zero AUTH, zero
MAIL FROM. Proven against the sink (`smtp_smoke_test.exs`: no STARTTLS offered, untrusted
certificate, untrusted default store: `auth == []`, `mail_from == nil`).

`tls_options` reach the upgrade (`gen_smtp_client.erl:811-814`):

```erlang
catch smtp_socket:to_ssl_client(
    Socket, [binary | proplists:get_value(tls_options, Options, [])], 5000
)
```

which is `ssl:connect(Socket, ssl_connect_options(Options), Timeout)` (`smtp_socket.erl:274-275`).
The user's `tls_options` REPLACE the library default `[{versions, ['tlsv1', 'tlsv1.1', 'tlsv1.2']}]`
(`gen_smtp_client.erl:34`; the merge is `lists:ukeymerge` of the user list over the defaults, lines
201-204), so the adapter passes `verify: :verify_peer`, `cacerts`, `server_name_indication`,
`customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]` and
`versions: [:"tlsv1.3", :"tlsv1.2"]`. A verification failure comes back as `{error, _}`, which falls in
the `Else -> ... false` clause (lines 832-834), i.e. the `{false, always}` branch above. For implicit TLS
(`ssl: true`, port 465 style) the same list is passed as `sockopts`, which `connect/2` forwards to
`ssl:connect/5` (`gen_smtp_client.erl:875`, `smtp_socket.erl:108-109`).

### 9.2 (b) Retries

Default `{retries, 1}` (`gen_smtp_client.erl:38`). `gen_smtp_client.erl:354-381`:

```erlang
try_next_host({FailureType, Message}, [{_Distance, Host} | _Tail] = Hosts, Options, RetryList) ->
    Retries = proplists:get_value(retries, Options),
    RetryCount = proplists:get_value(Host, RetryList),
    case fetch_next_host(Retries, RetryCount, Hosts, RetryList, Options) of
        {[], _NewRetryList} ->
            {error, retries_exceeded, {FailureType, Host, Message}};
...
fetch_next_host(0, _RetryCount, [{_Distance, Host} | Tail], RetryList, _Options) ->
    % done retrying completely
    {Tail, lists:keydelete(Host, 1, RetryList)};
```

On the first failure `RetryCount` is `undefined`, so the two `is_integer(RetryCount)` clauses (364, 370)
are skipped and the `fetch_next_host(0, ...)` clause (375) returns the remaining hosts (`Tail`). With
`no_mx_lookups: true` (`send_it/2`, lines 280-295, builds a single host `[{0, RelayDomain}]`) `Tail` is
`[]`, so the result is `{error, retries_exceeded, ...}` after exactly one session. Proven: a 450 reply
at RCPT and a connection dropped after the greeting each produce exactly one sink connection after a
wait (`smtp_smoke_test.exs`, "retries").

### 9.3 (c) Blocking send in the calling process

`gen_smtp_client.erl:200-211`:

```erlang
send_blocking(Email, Options) ->
    NewOptions = lists:ukeymerge(1, lists:sort(Options), lists:sort(?DEFAULT_OPTIONS)),
    case check_options(NewOptions) of
        ok ->
            send_it(Email, NewOptions);
```

`send_it/2` (lines 278-314) opens the session, sends and closes in the same process; there is no
`spawn`. The only `spawn_link` calls are in the NON-blocking `send/3` (line 170) and inside the
`-ifdef(TEST)` eunit block (lines 1528, 1620). So `send_blocking/2` spawns no linked worker. The
`timeout` option bounds only the TCP/SSL CONNECT (`gen_smtp_client.erl:870-875`, default 5000); every
read uses the fixed `-define(TIMEOUT, 1200000)` (line 51; reads at 894 and 913), and the STARTTLS
handshake is hard-coded to 5000 ms (line 813). So the library has NO overall or per-phase read timeout
that we can set: the guarantee of a bounded attempt is `Dispatch`'s `Task.yield || Task.shutdown(:brutal_kill)`
of the inner task, exactly as the design states (design 4.4 item 3: "The sum of phases is not bounded
by this value; the hard timeout is the guarantee"). The adapter's `socket_timeout_ms` therefore governs
the connect phase only. `Process.flag(:trap_exit, ...)` is not used.

### 9.4 (d) Socket closure

TCP sockets opened with `gen_tcp:connect` (`smtp_socket.erl:106-107`) are owned by, and linked to, the
calling process, so they are closed when it ends or is `:brutal_kill`ed. `ssl` connections upgraded or
opened by `ssl:connect` are bound to their owner the same way by OTP `ssl`. Explicit closure:
`send_it/2` runs `quit(Socket)` in an `after` clause (lines 311-313); `quit/1` is
`smtp_socket:send(Socket, "QUIT\r\n"), smtp_socket:close(Socket)` (lines 937-940); the protocol-failure
paths call `quit(Socket)` before throwing (e.g. lines 787, 797). NOT closed explicitly: the
`{network_failure, _}` throws (e.g. a recv error or timeout, lines 907 and 925) and an
unexpected exception inside the session; in those the socket lives until the calling process exits. In
the adapter the calling process is the short-lived inner Dispatch task, which exits immediately after
the call (or is killed), so the socket closes with it. Proven by the sink: after a `:brutal_kill` of a
task blocked on a hanging server, `open_connections/1` reaches 0 and no new process survives
(`smtp_smoke_test.exs`, "a brutal kill mid-call ...").

### 9.5 (e) Logging and crash reports

- `gen_smtp_client.erl` contains no `?LOG_*` macro. It calls `error_logger:error_msg/1,2` in three
  places (lines 822, 826, 830): `"Error in ssl upgrade: ~p.~n"` with the `Reason` of a CRASH of
  `to_ssl_client` (the TLS options, no credentials and no recipient), `"Error in ssl upgrade: socket
  closed.~n"` and `"SSL not started.~n"`. The password lives only in the `Options` proplist; it is
  read at lines 602-603 (`to_binary/1`) and sent base64-encoded on the wire. The `trace/3` helper
  (line 1003) is a no-op unless a `trace_fun` option is given, which the adapter never sets
  (note that `try_STARTTLS` would pass the whole `Options`, password included, to a `trace_fun`:
  one more reason it must never be set).
- `smtp_util.erl:79`: `error_logger:info_msg` only when the node's own FQDN cannot be resolved
  (contains the local hostname, not the recipient or credentials). It runs because
  `?DEFAULT_OPTIONS` evaluates `smtp_util:guess_FQDN()` on each send (line 36); the adapter passes an
  explicit `hostname`, but the default list is still built.
- `mimemail.erl:409` (`get_header_value/3`): `?LOG_DEBUG("Headers: ~p", [Headers], ?LOGGER_META)` logs
  the COMPLETE header list, including `To` (the recipient address), at debug on every call, and
  `mimemail:encode/1` calls it repeatedly. Observed live in this implementation: a first version that
  used `:mimemail.encode/1` produced `[debug] Headers: [{"From", ...}, {"To", "someone@example.org"}, ...]`
  in the captured log. This would violate the no-leak criterion, so the adapter does NOT call mimemail:
  `Smtp.Transport` builds the RFC 5322 message itself (fixed ASCII headers and allow-list-validated
  addresses; a 7bit body when all-ASCII, base64 otherwise). `gen_smtp_client:send_blocking/2` takes the
  already-built binary and does not call mimemail. After the change a `capture_log(level: :debug)` test
  across success, an SMTP rejection and an untrusted-TLS failure contains none of the recipient, the
  username, the password, the reply text or any tenant text (`smtp_smoke_test.exs`).
- No crash report can print the options: no process is spawned (9.3), and the adapter wraps the call in
  `rescue`/`catch` returning `{:error, :failed}` without inspecting any term.

### 9.6 (f) Starting `:gen_smtp` opens no listening socket

`gen_smtp.app.src` (whole file):

```erlang
{application,gen_smtp,
             [{description,"The extensible Erlang SMTP client and server library."},
              {vsn,"1.3.0"},
              {applications,[kernel,stdlib,crypto,asn1,public_key,ssl,ranch]},
              {registered,[]},
              ...
```

There is no `mod` key: the application has no callback module, so starting it starts no process and
no listener. A listener exists only when code calls `gen_smtp_server:start/2,3` (server side, which
uses `ranch`); the adapter never does. Mix lists `gen_smtp` in the letflow application's `applications` automatically (verified in
`_build/test/lib/letflow/ebin/letflow.app`), and `gen_smtp.app` lists `kernel, stdlib, crypto, asn1,
public_key, ssl, ranch`, so `ranch` (and the OTP apps) start as its dependencies; no
`extra_applications` change was needed. Proven by `smtp_application_test.exs`: after stopping
`:gen_smtp` and `:ranch`, `Application.ensure_all_started(:gen_smtp)` leaves the set of OS sockets in
the `listen` state unchanged and `:ranch.info/0` reports no listeners.

### 9.7 Other facts the implementation relies on

- `check_options/1` (lines 943-960): `auth: :always` requires `username` and `password`
  (`{error, no_credentials}` otherwise); the adapter always passes both.
- Authentication preference is CRAM-MD5, LOGIN, PLAIN, XOAUTH2 among those the server advertises
  (`?AUTH_PREFERENCE`, lines 44-49); with `auth: :always` and no accepted mechanism the call fails with
  `{permanent_failure, auth_failed}` (line 611).
- The EHLO identity is the `hostname` option (`try_EHLO/2`, line 747); the adapter sets it to the
  sender's domain so the node's FQDN is not advertised.
- `retries_exceeded`, `no_more_hosts` and `send` error tuples carry the remote reply text; the adapter
  collapses every non-binary return to `{:error, :failed}` and never inspects or logs them.
