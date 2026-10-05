# REQ-441 design: SMTP adapter behind the login-discovery notifier port

Run: WF02-REQ441-20261005, step 01 (CODE-DESIGNER), PHASE 1 (design only). Date: 2026-10-05.
Branch: `feature/WF02-REQ441-20261005`. Status of the library decision: PROPOSED, awaiting
supervisor / owner approval (`docs/migration/decisions/0045-mail-library-choice.md`). Nothing in
this file is implementation code: only signatures, type shapes, configuration shapes and tests.

Binding inputs: decisions 0042, 0043 (D-B, D-D), 0044 (Phase 1 only), design
`lib/letflow/design/req434-email-first-login-directory.md` section 13 ("Notifier port") and C-4,
`docs/agents/instructions/security-invariants.md` INV-4/5/8/9, `docs/anti-patterns.md`.

Reading order follows the handoff: 0 premises, 1 library decision, 2 module list and message
contract, 3 configuration, 4 failure handling and Dispatch changes, 5 hard stops, 6 tests mapped to
every acceptance criterion, 7 files to touch, 8 SECURITY-REVIEWER focus, 9 open questions.

---

## 0. Premises and verification ledger

Each row was read in this worktree on 2026-10-05. "Verified" means I read the cited lines; nothing
here is inherited from the handoff without a check, except where marked.

| # | Premise | Source read | Result |
|---|---|---|---|
| P1 | The port has exactly one callback `deliver_tenant_list(recipient_email :: String.t(), tenants :: [LoginDirectory.tenant_ref(), ...]) :: :ok or {:error, term()}` | `lib/letflow/login_discovery/notifier.ex:17-20` | Verified. Port stays unchanged (AC1). |
| P2 | `tenant_ref` is `%{slug: String.t(), display_name: String.t()}` | `lib/letflow/login_directory.ex:80` | Verified. |
| P3 | Dispatch emits NO `[:letflow, :login_discovery, :notifier]` event today; on non-`:ok` it logs one fixed `Logger.warning` | `lib/letflow/login_discovery/dispatch.ex:108-115` (the warning is line 113) | Verified. The event is new work in `Dispatch` (section 4.2). The handoff's claim is correct. |
| P4 | Dispatch order inside the task: `is_binary(recipient)`, `LoginDiscovery.delivery/2` returns `{:deliver, tenants}`, `LoginDirectory.email_keys/1` gives `{:ok, [key | _]}`, `Limiter.consume_email_silent(key, :send)` returns `:ok`, then the adapter runs in an inner `Task.Supervisor.async_nolink` task; every other branch is `else _skip -> :ok` | `dispatch.ex:83-94`, `96-116` | Verified. `consume_email_silent` returns `:ok or :rate_limited` and emits no event (`lib/letflow/plugs/login_discovery_rate_limit.ex:119-142`). |
| P5 | Timeout: `Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)`, default `timeout_ms` 5000 in `config/config.exs:78-81`; test config sets 1000 (`config/test.exs:291-294`) | read | Verified. |
| P6 | The request emits exactly one `[:letflow, :login_discovery, :outcome]` event (`%{count: 1}`, `%{outcome: ...}`); a refused `:send` is silent so one request keeps one outcome | `lib/letflow/routers/login_discovery.ex:34-41`, `login_discovery_rate_limit.ex:119-123` | Verified. The new `[..., :notifier]` event is a DIFFERENT event name and does not disturb REQ-437's one-outcome-per-request rule (existing tests capture only `:outcome`, `test/letflow/login_discovery/dispatch_test.exs:148-166`). |
| P7 | The test double already records `{:deliver_tenant_list, recipient, tenants}` to an owner pid and supports `:ok`, `:error` (returns `{:error, :boom}`), `:raise` (message contains the recipient), `:exit` (reason contains the recipient), `{:sleep, ms}` | `test/support/login_discovery_notifier_double.ex:10-52` | Verified. REQ-441 item 5 says reuse; nothing is added. Note: `{:sleep, ms}` returns the value of `Process.sleep/1` (`:ok`) so a sleep SHORTER than `timeout_ms` is a success; the timeout case needs a sleep longer than `timeout_ms`. |
| P8 | Adapter key `config :letflow, Letflow.LoginDiscovery.Notifier, adapter:` exists with the Noop default; `config/test.exs` overrides it with the double | `config/config.exs:78-81`, `config/test.exs:291-294` | Verified. Consequence: `config/runtime.exs` runs after `test.exs`, so it must write the adapter key ONLY when `LETFLOW_MAIL_ADAPTER` is set, otherwise tests lose the double. |
| P9 | `config/runtime.exs` already calls pure modules for parsing (`Letflow.Plugs.ClientIp.parse_cidrs`, `Letflow.LoginDirectory.parse_deployment_mode`), raises with fixed text naming only the variable, and relies on `Config` deep-merging keyword values across files | `config/runtime.exs:227-296`, comment at `:343-352` | Verified. REQ-441 follows the same pattern. |
| P10 | There is no general deployment base-URL variable. Found only: `CERTIFICATE_VERIFY_BASE_URL` (exam module, `lib/letflow/modules/exam/router.ex:710`), `OIDC_KEYCLOAK_BASE_URL` (Keycloak host, not the SPA), `BPM_IDP_BASE_URL`/`KEYCLOAK_BASE_URL`, `CORS_ALLOWED_ORIGINS` (list of origins) | grep of `config/`, `lib/` | Verified. A NEW variable is needed: `LETFLOW_PUBLIC_BASE_URL` (section 3). CORS origins is a list and could include non-SPA origins, so it is not reused. |
| P11 | The SPA resolves the tenant from a `?realm=<slug>` URL parameter at the root path | `web/src/auth/tenantConfig.ts:34` | Verified. The link in the message is `<base>/?realm=<URL-encoded slug>`. Whether the SPA is served at the base URL root in every environment is an open question (OQ-7). |
| P12 | Only `:httpc` is used for outbound HTTP; `extra_applications: [:logger, :inets, :ssl]`; `mix.lock` has jason 1.4.5 (`:10`), mime 2.0.7 (`:13`), plug 1.20.3 (`:16`), telemetry 1.4.2 (`:22`), one rebar3 package yamerl (`:29`); no swoosh, gen_smtp, ranch, mua, mail, idna in `deps/` | `mix.exs:31`, `mix.lock`, `ls deps` | Verified. |
| P13 | `lib/letflow/metrics/registry.ex` attaches exactly four events: `[:letflow, :task, :completed]`, `[:letflow, :event_store, :append, :stop]`, `[:letflow, :repo, :query]`, `[:letflow, :http, :request]`; nothing on `[:swoosh, ...]` and nothing on `[:letflow, :login_discovery, ...]` | `lib/letflow/metrics/registry.ex:102-109` | Verified. No handler to detach. The new notifier event has no subscriber after this requirement (OQ-5). |
| P14 | Runtime image installs `ca-certificates`; builder runs `mix local.rebar --force`; Elixir 1.20.3 / OTP 29 | `deploy/Dockerfile:4,11,33-39` | Verified. System-store certificate verification and a rebar3-built dependency both work in the image. |
| P15 | A `:gen_tcp` listener written for tests must thread leftover bytes between reads (a recv chunk is not a protocol line) | `docs/anti-patterns.md` entry "A hand-rolled `:gen_tcp` test HTTP server discarding bytes read alongside the headers..." | Verified. Binding on the sink design (section 6.1). |
| P16 | Runtime-config tests use a controlled-environment child `mix run --no-start`, `async: false`, `@moduletag :slow`, set or `nil` every variable under test, assert the message names the variable and does not echo the value; secrets in tests are built at compile time so the no-secret guard passes | `test/letflow/login_discovery_runtime_config_test.exs:1-84` | Verified. Binding on the boot tests (6.3). |
| P17 | The repo has a runtime secrets subsystem (`Letflow.Secrets`, `Letflow.Secrets.LogFilter`) for tenant secrets in a DB table; nothing for operator env credentials | `lib/letflow/secrets/*.ex` | Verified. Not reused: it is tenant-scoped, DB-backed, and the credentials here are operator environment references (INV-4 first sentence). |
| P18 | `.env.example` exists at the repo root and at `deploy/.env.example`; both already document the login-directory variables | `ls`, `.env.example:29-32`, `deploy/.env.example:47-57` | Verified. Both are touched. |

Not verifiable in this phase (explicitly): everything about gen_smtp's runtime behaviour. The list of
"to verify against deps/ source after the dependency is approved" items is section 1.3. This design
does not state any of them as fact.

Discrepancies found, none blocking: (a) design s13 says the Noop adapter "emits only a non-identifying
counter or fixed log line"; the code logs one fixed `:debug` line and emits no counter
(`notifier/noop.ex:14-17`). Harmless; this design makes Dispatch (not the adapters) the single
emitter of the notifier event, which also fixes that gap uniformly. (b) The Dispatch moduledoc
line 17 is a long run-on sentence; ELIXIR-DEV will rewrite that paragraph when updating the docs for
the new event, no behaviour change.

---

## 1. Library decision

Full comparison: `docs/migration/decisions/0045-mail-library-choice.md` (status PROPOSED).

### 1.1 What the requirement text mandates

SMTP is the first adapter (0043 D-B); the acceptance criteria name an in-process local SMTP sink and
the `LETFLOW_SMTP_*` variables. A transactional HTTP-API provider requires choosing a vendor (a
business, privacy and contract decision no agent can make) and so cannot be first; it is the expected
SECOND adapter behind the same port, as its own requirement and decision record. An in-house
`:gen_tcp`/`:ssl` SMTP client is rejected: STARTTLS state machine and pre-TLS buffer handling, AUTH,
dot-stuffing, MIME/RFC 2047 encoding of UTF-8 display names, header-injection defence and TLS
verification are all security-sensitive protocol code we would own, when maintained libraries exist.

### 1.2 Recommendation

| Option | New lock entries | Verdict |
|---|---|---|
| gen_smtp alone | gen_smtp, ranch (2) | RECOMMENDED. Smallest footprint; no Mailer, no telemetry span, no `:api_client` warning; every security option spelled out in our own adapter and tested against the sink. Diverges from the requirement's proposal (Swoosh), which the requirement permits ("or a bare gen_smtp"). |
| Swoosh + gen_smtp (requirement's proposal) | swoosh, gen_smtp, ranch, idna (4) | Acceptable alternative. Must call the adapter directly with no `use Swoosh.Mailer` module (so no `:telemetry.span([:swoosh, :deliver], ...)`, whose metadata per the ORCH research carries the email and the adapter config including the password), `retries: 0`, explicit verified-TLS options, `config :swoosh, :api_client, false`. |
| Swoosh + Mua | swoosh, mua, mail, idna (4) | Fallback if gen_smtp cannot be shown to do verified STARTTLS with zero retries. Verified TLS by default per the ORCH research; 0.x library, 167k downloads. |
| In-house | 0 | Not recommended (1.1). |
| HTTP provider over `:httpc` | 0 | Later second adapter; vendor undecided. |

Supervisor decision needed (hard stop, section 5). The module design below is the same for every
library option except the body of one module (`Smtp.Transport`, 2.1), which is the only place a
library is named. So the decision can change without redesign.

### 1.3 To verify against `deps/` source after the dependency is approved

For each item ELIXIR-DEV reads `deps/gen_smtp/` source and quotes it in its handoff; SECURITY-REVIEWER
re-reads it. If an answer differs from the design's assumption the design is amended, not worked around.

1. Option names and value types for: host, port, `ssl` (implicit TLS) vs `tls` (STARTTLS) modes, `auth`
   modes, `username`, `password`, `retries`, `timeout`/connect timeout, `tls_options`, `sockopts`,
   and how `hostname` (the EHLO identity) is chosen.
2. Retry semantics: does `retries: 0` mean "one attempt, no retry"? Does any internal retry exist on
   4xx replies or connection drops regardless of that option?
3. STARTTLS policy values: is there a value that REQUIRES STARTTLS (fail if the server does not offer it)
   as opposed to "use if available"? The design requires the "fail closed" behaviour (2.1 `:starttls`
   mode). If no such value exists, the adapter must pre-check, and the design is amended.
4. Whether `tls_options` apply to the STARTTLS upgrade and to implicit TLS, and what the verify
   options must be to get peer verification with SNI and a hostname match (the design needs:
   `verify: :verify_peer`, `cacerts: :public_key.cacerts_get()` (OTP 25+ OS store),
   `server_name_indication` set to the configured host, and a hostname-check match function).
   Note the OTP `:ssl` documentation, not gen_smtp, defines the TLS options themselves.
5. Return shapes of the blocking send call on success, on an SMTP-level rejection, on a connection
   failure and on a TLS failure, so the adapter can map every one to `:ok` or `{:error, reason}` without
   ever `inspect`-ing or logging the returned term (it can carry reply text and the recipient).
6. Process model: does the send run in the calling process or in a spawned process? If a worker is
   spawned and linked, does a `:brutal_kill` of our inner task (Dispatch's timeout path) kill it and
   close its socket? Can a crash report of that worker print its arguments (the option map holding the
   password)? This is the highest-risk unknown for INV-4 (section 8).
7. Whether the library itself writes anything through `Logger`/`:logger`/`error_logger`
   (including at debug) and whether any such line can contain the recipient, reply text, host or
   credentials. A `capture_log(level: :debug)` test (AC5) is the check; if the library logs, a
   targeted `:logger` primary filter scoped by `domain` or module is the contingency and is a design
   amendment.
8. Encoding: how the mime encoder treats a UTF-8 body (transfer-encoding chosen), a non-UTF-8 binary
   (raise or garble: the adapter must map either to `{:error, :invalid_message}` without surfacing text),
   header folding, and whether it adds `Date` / `Message-ID` headers and with which domain (must not
   leak an internal hostname; if it would, the adapter supplies a Message-ID domain taken from the
   configured sender's domain).
9. The OTP application start requirement for `:gen_smtp` (does `mix.exs` need an entry?), and whether it
   compiles under OTP 29 without warnings (`mix compile --warnings-as-errors`).

---

## 2. Modules, signatures and the message contract

Port, `Noop` and the test double are unchanged. New modules (names are binding; all under
`lib/letflow/login_discovery/notifier/`):

### 2.1 Module list

| Module | File | Role |
|---|---|---|
| `Letflow.LoginDiscovery.Notifier.Smtp` | `notifier/smtp.ex` | `@behaviour Letflow.LoginDiscovery.Notifier`. The adapter: composes (via `Smtp.Message`), reads the operator config (via `Smtp.Config.runtime/0`), resolves credentials at the point of use, calls `Smtp.Transport`, maps the result to `:ok or {:error, reason}`. Logs nothing, emits nothing, never `inspect`s a library return. |
| `Letflow.LoginDiscovery.Notifier.Smtp.Message` | `notifier/smtp/message.ex` | PURE. Builds the fixed-template message from `(recipient, tenants, base_url, from)`; validates the recipient; sanitises tenant text. No I/O, no config reads, no library. |
| `Letflow.LoginDiscovery.Notifier.Smtp.Config` | `notifier/smtp/config.ex` | PURE parse/validate of the environment map into the application-env shape (used by `config/runtime.exs`), plus `runtime/0` which reads the already-validated non-secret app env at call time. Never returns or stores a credential. |
| `Letflow.LoginDiscovery.Notifier.Smtp.Transport` | `notifier/smtp/transport.ex` | The ONLY module that names the mail library. One function: send a composed message with explicit connection options. Replaceable (gen_smtp / Swoosh / Mua) without touching anything else. |

No `use Swoosh.Mailer` module exists under any option. No GenServer, no supervisor child, no new
process: the existing `Letflow.LoginDiscovery.TaskSupervisor` inner task is the only process.

### 2.2 Signatures and types

```
# Letflow.LoginDiscovery.Notifier.Smtp
@behaviour Letflow.LoginDiscovery.Notifier
@type reason :: :not_configured | :invalid_recipient | :invalid_message | :failed
@impl true
@spec deliver_tenant_list(recipient_email :: String.t(),
                          tenants :: [Letflow.LoginDirectory.tenant_ref(), ...]) ::
        :ok | {:error, reason()}
```

`reason` is a closed set of atoms used only by tests; Dispatch ignores it (it matches `:ok` or
anything else), and nothing logs, emits or returns it to the HTTP layer. `:failed` is the single
bucket for every transport-level outcome (SMTP rejection, connection, TLS, auth, timeout inside the
library): the adapter deliberately does NOT classify these, because a classification (even in-process)
is a per-address signal an operator-visible surface could expose, and because the library's return
shapes are unverified (1.3 item 5).

```
# Letflow.LoginDiscovery.Notifier.Smtp.Message
@type composed :: %{from: String.t(), to: String.t(), subject: String.t(), body: String.t()}
@type opts :: %{from: String.t(), base_url: String.t()}
@spec compose(recipient :: String.t(), tenants :: [Letflow.LoginDirectory.tenant_ref(), ...], opts()) ::
        {:ok, composed()} | {:error, :invalid_recipient | :invalid_message}
@spec valid_address?(String.t()) :: boolean()          # used for recipient AND for LETFLOW_MAIL_FROM
@spec sanitize_text(String.t()) :: {:ok, String.t()} | {:error, :invalid_message}
@spec tenant_link(base_url :: String.t(), slug :: String.t()) :: String.t()
@spec subject() :: String.t()                           # the fixed subject
```

```
# Letflow.LoginDiscovery.Notifier.Smtp.Config
@type tls_mode :: :starttls | :tls | :none
@type adapter_choice :: :noop | :smtp
@type parsed :: %{
        adapter: module(),                                # Noop or Smtp (the value written to app env)
        notifier: keyword(),                              # [adapter: module()] plus [timeout_ms: pos_integer()] when smtp
        smtp: keyword() | nil                              # nil for noop; non-secret fields only (section 3.2)
      }
@spec parse(env :: %{optional(String.t()) => String.t() | nil}, config_env :: atom()) ::
        {:ok, parsed()} | {:error, {:missing | :invalid, var :: String.t()}}
@spec runtime() :: {:ok, runtime_config} | {:error, :not_configured}
  # runtime_config :: %{host: String.t(), port: 1..65535, tls: tls_mode(), from: String.t(),
  #                     base_url: String.t(), socket_timeout_ms: pos_integer()}   -- no credential
```

`parse/2` returns the NAME of the offending variable and the failure kind, never a value. It validates
presence of `LETFLOW_SMTP_USERNAME` and `LETFLOW_SMTP_PASSWORD` but returns neither.

```
# Letflow.LoginDiscovery.Notifier.Smtp.Transport      (the only module naming the mail library)
@type connection :: %{host: String.t(), port: 1..65535, tls: Config.tls_mode(), socket_timeout_ms: pos_integer()}
@spec send_message(Message.composed(), connection(), credentials :: {String.t(), String.t()}, opts :: keyword()) ::
        :ok | {:error, :failed}
```

`credentials` is a function ARGUMENT for the duration of one call, built in `Smtp` immediately before
the call from `System.get_env/1`; it is never returned from any function, stored, or placed in a struct
(INV-4). `opts` carries only the test-only TLS trust override (3.4); production passes none.

### 2.3 The message contract (design s13, REQ-441 item 4)

Fixed text. These are the exact strings (copy is subject to product review, OQ-6; the structure is
binding):

- Subject: `Your Letflow sign-in options` (fixed, ASCII; not parameterised).
- Body, plain text only (`text/plain; charset=UTF-8`), no HTML part:
  - fixed intro line: `You asked for the organisations you can sign in to with this email address.`
  - for each tenant, in the order given, one block of exactly two lines:
    `Organisation: <display_name>` and `Sign in: <link>`, followed by a third line `Code: <slug>`;
    blocks separated by one blank line.
  - fixed outro lines: `If you did not ask for this, you can ignore this message.` and
    `Do not forward this message.`
- `From`: the configured sender address only (a bare mailbox, no display name).
- `To`: the recipient address only. No `Cc`, `Bcc`, `Reply-To`, `Sender` or custom header, ever.

Rules (each is a test in 6, AC9):

1. **No header is built from tenant text.** Display names and slugs appear only in the body. The only
   request-derived header value is `To`.
2. **Recipient validation (`valid_address?/1`).** Reject, returning `{:error, :invalid_recipient}`,
   when the value is longer than 254 bytes or contains any of: NUL, any ASCII control character
   (including CR and LF), space or tab, `<`, `>`, `,`, `;`, `"`, `\`, `(`, `)`, `[`, `]`, `:`, any
   non-ASCII byte (no SMTPUTF8; internationalised addresses are simply not delivered, OQ-8), or when it
   does not contain exactly one `@` with a non-empty local part and a non-empty domain part. The
   recipient reaching the adapter is already the normalised address typed in the request (design s13),
   but the adapter does not trust that.
3. **Sender validation.** `LETFLOW_MAIL_FROM` is checked by the same `valid_address?/1` at boot.
4. **Tenant text is inert.** `sanitize_text/1` (used for display names and slugs as printed) does, in
   order: reject (`{:error, :invalid_message}`) a value that is not valid UTF-8 or longer than 256
   bytes before sanitising; replace CR, LF, NUL and every other C0/C1 control character and DEL with a
   single space; remove Unicode bidirectional controls (U+202A..U+202E, U+2066..U+2069, U+200E/F) and
   zero-width characters (U+200B..U+200D, U+2060, U+FEFF); collapse runs of whitespace to one space;
   trim; replace every occurrence of `://` with `[://]` so no scheme-qualified URL survives in tenant
   text and plain-text mail clients have nothing to auto-link by scheme; replace a leading `www.`
   (case-insensitive, at a word start) with `www[.]`; and replace `@` with `[at]` so tenant text cannot
   form a mailto-style token. An empty result becomes the fixed text `(unnamed)`. A HTML-looking
   display name (`<script>`, `&amp;`) is NOT escaped because the body is plain text and is never
   rendered as HTML by this adapter; it is only length-bounded and defanged as above. Residual risk:
   a bare domain name inside a display name may still be auto-linked by some mail clients (OQ-9);
   the acceptance criterion is met because the message contains no tenant-derived `scheme://` and no
   URL not starting with the configured base URL.
5. **Link.** The only URLs in the body are `tenant_link(base_url, slug)` = `<base_url>/?realm=<slug
   encoded with URI.encode_www_form/1>` (every character outside the unreserved set is
   percent-encoded; so no `/`, `?`, `&`, `#`, `%0d` or `@` can alter the link). `base_url` is the
   validated, normalised value from boot (3.3): scheme `https` (or `http` outside `:prod`), host,
   optional port and path, no userinfo, no query, no fragment, no trailing slash. Tenant text never
   contributes to scheme, host or path.
6. **Bounded size.** At most 50 tenants are listed; if there are more, the remaining blocks are replaced
   by the fixed line `More organisations match this address; contact your administrator.` (OQ-10: the
   cap is a design decision; the lookup already orders deterministically by display name, REQ-437).
   Total body is therefore bounded (~50 * 400 bytes).
7. **Non-throwing.** `compose/3` never raises on any binary input (it returns the error tuples above);
   a non-binary argument is a programming error caught by the adapter's `catch`-all (Dispatch's INV-8
   isolation).

---

## 3. Configuration

All names below are NEW. Read in `config/runtime.exs` in EVERY environment (placed beside the
REQ-437/439 block, outside the `:prod`-only block, like those), through `Smtp.Config.parse/2`.

### 3.1 Environment variables

| Variable | Required when | Default if unset | Validation (failure raises at boot, naming the variable only) |
|---|---|---|---|
| `LETFLOW_MAIL_ADAPTER` | never | unset or blank: Noop is kept, NOTHING is written to app env (so `config/test.exs`'s double survives) | After trimming: exactly `noop` (writes the Noop module) or `smtp`; any other value raises. Case-sensitive. |
| `LETFLOW_SMTP_HOST` | adapter `smtp` | none | Non-empty, at most 253 bytes, characters `A-Za-z0-9.-` or an IP literal (`:` allowed only for IPv6), no whitespace or control characters. |
| `LETFLOW_SMTP_PORT` | adapter `smtp` | none (no default port: 25, 465 and 587 mean different TLS modes) | Integer text, 1..65535. |
| `LETFLOW_SMTP_USERNAME` | adapter `smtp` | none | Non-empty after trim; no CR/LF/NUL. Presence-validated at boot, NOT copied to app env (3.5). |
| `LETFLOW_SMTP_PASSWORD` | adapter `smtp` | none | Non-empty (not trimmed; leading/trailing spaces are significant); no NUL. Presence-validated at boot, NOT copied to app env (3.5). |
| `LETFLOW_SMTP_TLS` | never | unset or blank: `starttls` | Exactly `starttls` (connect plain, REQUIRE STARTTLS, verified), `tls` (implicit TLS from the first byte, verified), or `none` (plaintext, no TLS). `none` raises when `config_env() == :prod`. Anything else raises. |
| `LETFLOW_MAIL_FROM` | adapter `smtp` | none | `Smtp.Message.valid_address?/1`. Bare mailbox only. |
| `LETFLOW_PUBLIC_BASE_URL` | adapter `smtp` | none | `URI.parse`-based: scheme `https` (also `http` when `config_env() != :prod`), non-empty host, no userinfo, no query, no fragment; trailing `/` stripped; length at most 200 bytes. |
| `LETFLOW_MAIL_TIMEOUT_MS` | never | unset or blank: 15000 | Integer text, 2000..60000. Sets the Dispatch hard timeout for the smtp adapter (4.4). |

The value of a variable is never echoed by any message (INV-4): each raise is fixed text of the form
"environment variable NAME is missing or invalid; the value is not echoed", plus for the TLS and
adapter variables the list of accepted keywords (which are constants, not the supplied value).

Boot behaviour matrix (each row is an AC7/AC8 test):

| Situation | Result |
|---|---|
| `LETFLOW_MAIL_ADAPTER` unset/blank | boots; `Notifier` env has no `adapter:` written by `runtime.exs` (dev/prod: Noop from `config.exs`; test: the double) |
| `noop` | boots; writes `adapter: Noop` |
| unknown value | raises naming `LETFLOW_MAIL_ADAPTER`, value not echoed |
| `smtp` + any of host, port, username, password, from, base URL missing/blank/invalid | raises naming exactly that variable, value not echoed |
| `smtp` + `LETFLOW_SMTP_TLS=none` in `:prod` | raises naming `LETFLOW_SMTP_TLS` |
| `smtp` + complete valid set | boots; writes `adapter: Smtp`, `timeout_ms`, and the `Smtp` env (3.2) |

Failure order for several simultaneous errors is the table order (first error raised); values are
never listed.

### 3.2 Application-env keys

`runtime.exs` writes (only when `smtp` is selected; `Config` deep-merges keyword values, P9):

| App-env namespace (`:letflow`) | Keys written | Values |
|---|---|---|
| `Letflow.LoginDiscovery.Notifier` | `adapter`, `timeout_ms` | `Letflow.LoginDiscovery.Notifier.Smtp`; `LETFLOW_MAIL_TIMEOUT_MS` or 15000 |
| `Letflow.LoginDiscovery.Notifier.Smtp` | `host`, `port`, `tls`, `from`, `base_url`, `socket_timeout_ms` | string; integer; `:starttls`, `:tls` or `:none`; string; normalised string; integer |

`adapter:` is the exact key the REQ-444 enablement gate reads (AC8); the gate itself is not built
here. `max_concurrent` is untouched. Non-secret values only in this env: host, port, TLS mode, sender,
base URL, timeout. `socket_timeout_ms` is derived by `Config.parse/2` as `max(1000, div(timeout_ms, 4))`
(per-phase socket timeout, strictly below the Dispatch timeout, 4.4).

### 3.3 Base URL normalisation

Stored in normalised form so `tenant_link/2` never re-parses user-influenced text. It is operator
config (not tenant-controlled), so INV-9's private-range rule does not apply to it (3.6); the scheme
rule above is the part of INV-9's intent that is still useful.

### 3.4 Test-only TLS trust override

`Smtp.Transport` accepts, via its `opts`, an optional CA-certificate list to trust in place of the OS
store. `Smtp` fills it from `Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier.Smtp)[:tls_cacerts]`.
No environment variable can set it and `Config.parse/2` never writes it; production never has it.
It exists so the TLS tests can validate success against a sink with a generated test CA while the default
path (no override) rejects an untrusted certificate (AC3 TLS-failure case). Flagged for SECURITY-REVIEWER
(OQ-4): an attacker who can write the app env already controls the node.

### 3.5 Credentials (INV-4)

Decision: the username and password are NOT copied into application env, a struct, a closure in
config, `:persistent_term` or ETS. `runtime.exs` only checks that the two variables are present and
non-empty, then discards the values. `Smtp.deliver_tenant_list/2` resolves them with `System.get_env/1`
at the point of use, inside the inner Dispatch task, builds the argument for `Transport.send_message/4`
and hands it straight on. Why not the alternatives:

- App env: `Application.get_all_env(:letflow)` prints every value in it, so any remote shell or
  diagnostic dump would show the secret (release boot mechanics for runtime config were not
  verified here and are not relied on).
- A closure/fun in app env: a fun cannot be written into a release's evaluated sys.config, so it
  would not survive boot in a release (not verified by running a release here; this is the reason
  the option was dropped without being tried).
- A struct with `@derive {Inspect, except: [:password]}`: redacts `inspect/1` but still serialises as a
  plain map in `Application.get_all_env`, and still appears in a process dictionary or crash args.

Residual and honest: the OS environment of the BEAM process is itself readable by anything running
inside the node (`System.get_env/0`); this is the same exposure every other `System.get_env`
secret in the codebase has (INV-4's own reference pattern). The "read once at boot" wording of the
requirement is satisfied for validation and for every non-secret value; the two secrets are read at
call time on purpose. The credential argument lives only in the inner task's stack for the duration of
one call; no function returns it; `Smtp` has no struct holding it. Leak vectors that remain to test, not
assume: the library's own process arguments in a crash report (1.3 item 6), library logging (item 7),
and an exception message that embeds options (adapter wraps the call so none is surfaced). AC5 tests all
three with a recognisable password marker.

### 3.6 INV-9 and the SMTP host

INV-9 covers URLs derived from TENANT-controlled input. The SMTP host, port and base URL are
OPERATOR configuration (an environment variable set by whoever deploys the platform), not tenant
input, so INV-9's scheme allowlist and private-range rejection do not apply and are not implemented.
No tenant can influence the connection target: the only tenant-influenced text is in the message body.
Host validation that IS advisable and designed: syntactic validation at boot (3.1), no redirect-like
behaviour (SMTP has none), and the documented expectation that the relay is a private/internal or
provider host chosen by the operator; a private or loopback host is legitimate here (a sidecar relay or
a local Mailpit in dev), so a private-range ban would be wrong. SECURITY-REVIEWER to confirm (8).

### 3.7 `.env.example` documentation (names only, no value)

Both `.env.example` and `deploy/.env.example` get a commented block with blank assignments, in the
existing style (P18):

```
# Optional (REQ-441) -- notifier mail adapter: unset/blank = no mail is sent (Noop); smtp = send
LETFLOW_MAIL_ADAPTER=
# REQUIRED when LETFLOW_MAIL_ADAPTER=smtp (REQ-441), each stops boot when missing; values never echoed:
LETFLOW_SMTP_HOST=
LETFLOW_SMTP_PORT=
LETFLOW_SMTP_USERNAME=
LETFLOW_SMTP_PASSWORD=
LETFLOW_MAIL_FROM=
LETFLOW_PUBLIC_BASE_URL=
# Optional: starttls (default) | tls | none (none refused in prod)
LETFLOW_SMTP_TLS=
# Optional: milliseconds, 2000..60000, default 15000 (hard timeout of one delivery attempt)
LETFLOW_MAIL_TIMEOUT_MS=
```

with the explanatory comment that credentials are issued and owned by the platform operator and are
registered in the ai-dala-infra secrets inventory (external, section 5). No value, not even a
placeholder like `changeme`, is written (AC6).

---

## 4. Failure handling, uniform response and the Dispatch change

### 4.1 Uniform response (REQ-441 item 3)

Nothing in the HTTP path changes. `Dispatch.submit/3` is called once per request, returns `:ok`
without waiting, and the whole delivery runs in the `TaskSupervisor` task. The router's response,
headers and body are produced before and independently of delivery, so every delivery result leaves
them byte-identical by construction; the AC3 test proves it with the real router, for each result.

Mapping of delivery results (all inside the notifier task):

| Result | Adapter returns | Dispatch observes | Event outcome | Log | HTTP effect |
|---|---|---|---|---|---|
| Sink accepts | `:ok` | `{:ok, :ok}` | `:delivered` (or `:skipped` for the Noop adapter, 4.2) | none | none |
| SMTP rejection of the recipient, connection refused, TLS verify failure, auth failure, library error, invalid recipient/message, missing config | `{:error, _}` | `{:ok, {:error, _}}` | `:failed` | the existing fixed line | none |
| Adapter raises, exits, throws | n/a (caught in the inner task's `rescue`/`catch`, returns `{:error, :adapter_failed}`) | same as above | `:failed` | fixed line | none |
| Adapter exceeds `timeout_ms` | n/a (`Task.shutdown(task, :brutal_kill)`) | `nil` | `:failed` | fixed line | none |
| `:send` bucket refused | adapter not called | `:rate_limited` from `consume_email_silent` | `:skipped` | none | none |
| Nothing to deliver (no match, disclosed single match, failed lookup), non-binary recipient, `email_keys` failure | adapter not called | `:none`, `false` or an error tuple | no event | none | none |
| `start_child` refused (`max_children`) or exits | task never starts | n/a | no event | none | none |

No automatic retry (REQ-441 item 3): `Transport` passes zero retries to the library (1.3 item 2) and
Dispatch has no retry. The `:send` bucket is consumed BEFORE the adapter runs (existing order, P4),
so a failure still counts as the one attempt; a second request for the same address inside the
interval is `:skipped` and the relay is not contacted.

The fixed log line stays exactly `"login discovery: notifier delivery did not complete"`
(`dispatch.ex:113`): no address, tenant, slug, SMTP reply, exception text or reason.

### 4.2 Dispatch changes (the event does not exist today, P3)

New event, emitted from `Letflow.LoginDiscovery.Dispatch` ONLY (adapters emit nothing):
`:telemetry.execute([:letflow, :login_discovery, :notifier], %{count: 1}, %{outcome: outcome})`
with `outcome :: :delivered | :failed | :skipped` and metadata EXACTLY that single key (AC4). The
measurement `%{count: 1}` follows the existing `:outcome` event.

Exactly where, and the decision:

- "Attempt" is defined as a notifier task for which `delivery/2` returned `{:deliver, _}` and an email
  key was derived. Exactly one event is emitted per such task, at its end.
- `:delivered`: the adapter returned `:ok` and the adapter is not the Noop default.
- `:failed`: the adapter returned anything else, raised, exited, threw or timed out.
- `:skipped`: (a) the per-address `:send` bucket refused (`consume_email_silent` returned
  `:rate_limited`); (b) the adapter is the Noop default (it delivered nothing, so calling it
  `:delivered` would put a false number on a dashboard). Justification for (a): AC4 requires "a second
  attempt inside the interval is skipped" to be observable, and the bucket is the only place a deliver
  intent is dropped. Justification for (b): the Noop adapter is a real code path that returns `:ok`
  today; labelling it `:skipped` keeps `:delivered` meaning "a relay accepted a message".
- NOT emitted (no event at all): nothing-to-deliver (`:none`), non-binary recipient, `email_keys`
  failure, `start_child` refusal. Reason: those are the "no match" shapes. An event there would make the
  notifier counter's `delivered+failed+skipped` total equal the number of requests, and its split
  would then expose the match rate per request; emitting only on a real deliver intent keeps the
  counter at one event per genuine attempt, the unit AC4 and REQ-441 item 3 use ("once per attempt"),
  and it stays one-outcome-per-request-compatible with REQ-437 because the `:outcome` event is a
  different name that still fires once per request (P6). Honest residual: any counter of attempts
  reveals in aggregate that some addresses have tenants. It carries no per-address dimension and no
  attribution (OQ-5).

Mechanical shape of the edit (no code here): in the private `run/5` the `with` gains explicit `else`
clauses so `:rate_limited` emits `:skipped` and every other non-deliver result emits nothing; the
private `deliver/4` computes the outcome from the existing `Task.yield`/`Task.shutdown` result and
emits once, keeping the existing fixed warning for non-`:ok`; one new private helper
`emit_notifier(outcome)` wraps `:telemetry.execute/3`. `submit/3`, `adapter/0`, `timeout_ms/0`,
`max_concurrent/0` and every public spec are unchanged. The outer `catch` stays so nothing escapes the
task. A telemetry handler that raises is detached by `:telemetry` and cannot fail the task. The moduledoc
is updated to describe the event. The adapter returns the same shapes as before, so the port and the
double are untouched.

### 4.3 Counter exposure

No handler is attached to the new event in this requirement (P13); the Prometheus registry is not
changed. Whether to expose it as a metric is a separate decision (OQ-5): the event has no per-address
dimension by construction (metadata is exactly `%{outcome: _}`).

### 4.4 Timeout versus real SMTP (explicit design decision)

Today's default `timeout_ms: 5_000` (`config/config.exs:80`) covers DNS, TCP connect, banner, EHLO,
STARTTLS, a TLS handshake, EHLO again, AUTH, MAIL, RCPT, DATA and QUIT; on a real relay across the
public internet this routinely needs more than 5 s, so with the default every real delivery would be
killed and counted `:failed`. Decision:

1. The global default in `config/config.exs` stays 5000 (Noop and the test double are unaffected).
2. When `LETFLOW_MAIL_ADAPTER=smtp`, `runtime.exs` writes `timeout_ms:` = `LETFLOW_MAIL_TIMEOUT_MS`
   (default 15000, range 2000..60000). Dispatch already reads `timeout_ms` per `submit/3`, so no
   Dispatch change is needed for this.
3. The adapter's own per-phase socket timeout is `socket_timeout_ms = max(1000, div(timeout_ms, 4))`
   (3750 ms by default), strictly below the hard timeout, so a single stalled phase fails the attempt
   cleanly (library closes its socket) well before Dispatch's `brutal_kill`. The sum of phases is not
   bounded by this value; the hard timeout is the guarantee, and a test proves a slow-drip sink is
   killed and leaves no open connection.
4. Capacity: each delivery holds two `TaskSupervisor` slots for at most `timeout_ms` (Dispatch
   `max_concurrent/0` doc); at 15 s and the default 100 concurrent, a flood of distinct addresses is
   bounded by the existing per-IP and global limiter and the `max_children` cap, which drop silently.
   No change; stated so REVIEWER need not rediscover it.

---

## 5. Hard-stop checklist (all need a supervisor / user decision; none is made here)

| # | Item | Needs | Where recorded |
|---|---|---|---|
| H1 | New runtime dependency: `gen_smtp` (recommended; transitive `ranch`). Alternatives: `swoosh` + `gen_smtp` (+ `ranch`, `idna`) or `swoosh` + `mua` (+ `mail`, `idna`). Version constraint to be chosen at add time (hex.pm shows gen_smtp 1.3.0, 2025-05-30). ELIXIR-DEV must not touch `mix.exs`/`mix.lock` or run `mix deps.get` before approval. `mix deps.get` needs network; if unavailable ELIXIR-DEV must say so. | supervisor / owner approval | decision 0045 |
| H2 | New environment variables: `LETFLOW_MAIL_ADAPTER`, `LETFLOW_SMTP_HOST`, `LETFLOW_SMTP_PORT`, `LETFLOW_SMTP_USERNAME`, `LETFLOW_SMTP_PASSWORD`, `LETFLOW_SMTP_TLS`, `LETFLOW_MAIL_FROM`, `LETFLOW_PUBLIC_BASE_URL`, `LETFLOW_MAIL_TIMEOUT_MS`; new real credentials and an SMTP relay host per environment | operator / owner | this file 3, REQ-441 open questions |
| H3 | External infrastructure (not in this repository): ai-dala-infra secrets-inventory entries for the SMTP username/password and the relay per environment (0042 OQ-4: the platform operator owns the credentials); sender-domain SPF / DKIM / DMARC alignment; a deployed `.env` change before any environment sets `LETFLOW_MAIL_ADAPTER=smtp`. Recorded, not edited from here. | operator | REQ-441 open questions |
| H4 | Legal gate unchanged: 0042 OQ-3 / 0043 D-D lawful basis and controller. This requirement does not lift it; REQ-444 owns the boot refusal. | named person | 0043 D-D |

Deploy-order note for ORCH: because `runtime.exs` only acts when `LETFLOW_MAIL_ADAPTER` is set, merging
this requirement changes no running environment. The new variables are inert until an operator sets them.

---

## 6. Test plan (every acceptance criterion mapped)

Test files are designed here, written by TEST-DESIGNER. Conventions: `async: false` for anything
using the application env or the sink; `@moduletag :slow` for child-VM boot tests (P16); secrets and
markers built at compile time; the comparison and capture helpers of `Letflow.Test.LoginDiscoveryHelpers`
(through the real `Letflow.Router` at `/api/login-discovery`) are reused.

### 6.1 The in-process SMTP sink (`test/support/smtp_sink.ex`, `Letflow.Test.SmtpSink`)

A `:gen_tcp` listener on `127.0.0.1` with port 0 (the OS assigns a free port; `start/1` returns the
port). No network egress: it binds loopback only. One acceptor process, one handler process per
connection. A line-oriented reader that keeps a buffer across `recv` calls and threads any leftover
bytes into the next read (P15; the DATA section is read to the `CRLF.CRLF` terminator the same way).
Scripted by a list of behaviours passed at start:

| Script | Sink behaviour |
|---|---|
| `:accept` | greet `220`, answer `EHLO` (advertising `AUTH PLAIN LOGIN`, and `STARTTLS` when TLS is scripted), accept `AUTH`, accept `MAIL FROM`, `RCPT TO`, `DATA`, queue |
| `{:refuse_rcpt, reply}` | everything accepted until `RCPT TO`, then a `550` reply whose text contains a distinctive marker and echoes the recipient |
| `{:tempfail_rcpt, reply}` | `450` at `RCPT TO` (proves no retry of a transient failure) |
| `:refuse_connection` | the listener is closed before the attempt, so the OS refuses the connection (the port number is kept) |
| `:drop_after_greeting` | send `220`, then close |
| `{:starttls, :trusted}` | advertise STARTTLS, upgrade with a certificate chain generated at test time (`:public_key.pkix_test_data/1`, to verify it exists and can produce a hostname-matching chain), the success path for verified TLS when the test passes the generated CA as the override (3.4) |
| `{:starttls, :untrusted}` | same, with a self-signed certificate NOT in the trust set: a verifying client must abort (AC3 TLS-failure) |
| `{:no_starttls_offered}` | never advertise STARTTLS: with mode `:starttls` the adapter must fail closed and send nothing, not downgrade |
| `:hang` | accept the connection and never reply (timeout path) |
| `:slow_drip` | reply one byte at a time with delays shorter than the per-phase timeout (proves the hard timeout, 4.4) |

It records, per connection, the full command transcript: the sender, the list of `RCPT TO` addresses,
the raw DATA (header block and body) and whether AUTH and TLS occurred. API (signatures only):
`start(script) :: {:ok, %{port: pos_integer(), pid: pid()}}`, `messages(sink) :: [%{mail_from, rcpts,
data}]`, `connections(sink) :: non_neg_integer()`, `open_connections(sink) :: non_neg_integer()`,
`stop(sink) :: :ok`. It is test-support only (`test/support`, compiled in `:test`), never referenced
from `lib/`.

Per-test setup puts the sink's port into the `Smtp` app env (host `127.0.0.1`, `tls: :none` for the
plaintext cases, `:starttls` + the generated CA override for the TLS cases), sets
`LETFLOW_SMTP_USERNAME`/`PASSWORD` in the OS env to compile-time-built markers via `System.put_env`
restored in `on_exit`, and points `Notifier` `adapter:` at `Smtp`; everything is restored in `on_exit`.

### 6.2 Acceptance criteria to tests

| AC | Test (file) | Assertion |
|---|---|---|
| AC1 | `test/letflow/login_discovery/notifier/smtp_test.exs` "conforms to the port" | `Notifier.behaviour_info(:callbacks) == [deliver_tenant_list: 2]` (port unchanged); `Smtp.module_info(:attributes)[:behaviour]` includes `Notifier`; `function_exported?(Smtp, :deliver_tenant_list, 2)`; return shapes: `:ok` against the accepting sink, `{:error, reason}` with `reason` in the closed set against every failing sink; plus a diff guard that `lib/letflow/login_discovery/notifier.ex` is unchanged (`git diff --quiet main -- <file>`). (No Mox in `mix.exs`; a behaviour-conformance test is the form used.) |
| AC2 | same file, "delivers one message": call `Dispatch.submit/3` with `Smtp` selected and a multi-tenant lookup result, wait for the notifier event, then read the sink | exactly one message; `rcpts == [typed_address]` and no other recipient on any connection; the DATA body contains each active tenant's slug and display name as plain text and the link `<configured base>/?realm=<encoded slug>`; the raw DATA has `Content-Type: text/plain`; the sink saw one connection, one `MAIL FROM` equal to the configured sender. Also a direct `Smtp.deliver_tenant_list/2` case. |
| AC3 | `test/letflow/routers/login_discovery_notifier_uniform_test.exs` | For the same multi-tenant POST through the real router (and a baseline with the Noop adapter), compare `conn.status`, the full `resp_headers` and `resp_body` with `==` for: double `:ok`, `:error`, `:raise`, `:exit`, `{:sleep, ms > timeout_ms}`; and with the real `Smtp` adapter against the sink for: accept, `{:refuse_rcpt, _}`, `:refuse_connection`, `{:starttls, :untrusted}`, `:drop_after_greeting`, `:hang`. All must equal the baseline bytes. `Process.alive?(test_pid)` (the request process) after each. The test waits for the notifier event (not `Process.sleep`) before leaving each case so the next case is not racing. |
| AC4 | `test/letflow/login_discovery/dispatch_notifier_event_test.exs` (and extension of `dispatch_test.exs` if it overlaps) | (a) a failing attempt consumes the `:send` bucket: with `send_capacity: 1` and a negligible refill, attempt 1 vs the failing sink gives one `:failed` event and one sink connection; a second `submit` for the same address in the interval gives one `:skipped` event and ZERO new sink connections (not retried); (b) event shape: a telemetry handler attached by the test receives, per attempt, exactly one `{[:letflow, :login_discovery, :notifier], %{count: 1}, metadata}` with `metadata == %{outcome: _}` (`==` on the map, so no extra key) and the outcome is `:delivered`, `:failed`, `:failed`, `:failed`, `:skipped` for ok / error / raise+exit / timeout / bucket refused respectively; the Noop adapter gives `:skipped`; nothing-to-deliver, disclosed single match and a lookup failure emit NO notifier event; (c) a `{:tempfail_rcpt, _}` and a `:drop_after_greeting` sink each see exactly ONE connection after a wait longer than any plausible retry (proves no library-level retry); (d) grep guard (a `test/letflow/login_discovery/no_retry_guard_test.exs` or an existing structural test extended): `git grep` over `lib/letflow/login_discovery/` and `lib/letflow/login_discovery.ex` finds no `Process.send_after`, `:timer.send_after`, `:timer.apply_after`, `:timer.send_interval`, `retry`/`retries` (case-insensitive) outside `smtp/transport.ex` where `retries: 0` is the single permitted occurrence (asserted by line content), and no recursion of the delivery function. |
| AC5 | `test/letflow/login_discovery/notifier_no_leak_test.exs` | One `capture_log(level: :debug)` wrapper across: success, rejected recipient (sink reply text carries `SINKREPLYMARKER` and echoes the recipient), refused connection, untrusted TLS, `:hang` timeout, double raise/exit with the typed email in the message, and an invalid-UTF-8 display name through `Smtp` (forces the encoder error path). The output must contain NONE of: the typed address and its lowercase form, any slug, any display name, `SINKREPLYMARKER`, the compile-time-built password marker and username marker, any exception message text (the raising double's message contains the typed address, so the first assertion already covers it, design s13 C-4 form). Also: `Application.get_all_env(:letflow)` rendered with `inspect/2` (large limit) contains neither marker, and no struct is defined in the new modules (a grep for `defstruct` over the new files finds none). Structural grep guard: `start_child`, `Task.start`, `spawn` under `lib/letflow/login_discovery/` appear only in closure form (extends the REQ-437 structural test if it exists; otherwise added). |
| AC6 | `test/letflow/no_smtp_secret_guard_test.exs` | `git ls-files` content scan: no line matching `LETFLOW_SMTP_(PASSWORD|USERNAME)\s*[=:]\s*\S` (a non-empty assigned value) in any tracked file; the two `.env.example` files contain `LETFLOW_SMTP_USERNAME=` and `LETFLOW_SMTP_PASSWORD=` followed by nothing (exact line match, quoted in the report). The guard's own file builds its pattern from pieces so it does not trip itself; the tests that need values use `System.put_env` with names held in module attributes and values built at compile time (P16 precedent), not `NAME=value` text. |
| AC7 | `test/letflow/mail_runtime_config_test.exs` (`@moduletag :slow`, same child `mix run --no-start` technique as P16, MIX_ENV `test` and `dev`) plus `Config.Reader.read!/2` with `env: :prod` for the prod-only case (the option to verify against the Elixir docs of the pinned version) | unset keeps the pre-existing adapter (dev: Noop; test: the double) and writes no Smtp env; `noop` boots with Noop; unknown value exits non-zero, names `LETFLOW_MAIL_ADAPTER`, output contains the supplied value NOWHERE; `smtp` with each of host, port, username, password, from, base URL missing (one at a time) exits non-zero naming exactly that variable and containing none of the other variables' values; invalid port, invalid base URL (query, userinfo, ftp scheme, http in prod), invalid TLS keyword, out-of-range timeout each raise without echo; a complete valid set boots and the probe prints the evaluated env; `LETFLOW_SMTP_TLS=none` boots in `dev`/`test` and RAISES in `prod` (the `:prod` raise also asserts the message does not contain the host). The complete-set boot also asserts the password and username markers do not appear in `Application.get_all_env(:letflow)` (3.5). |
| AC8 | same file | complete `smtp` set: `Application.get_env(:letflow, Letflow.LoginDiscovery.Notifier)[:adapter] == Letflow.LoginDiscovery.Notifier.Smtp`, `timeout_ms == 15000` (and the env value when set); unset (dev run) leaves `Letflow.LoginDiscovery.Notifier.Noop`. The key asserted is character-for-character `Letflow.LoginDiscovery.Notifier, adapter:` (the key REQ-444 reads). |
| AC9 | `test/letflow/login_discovery/notifier/smtp_message_test.exs` (unit, `async: true`, no sink) + one sink case | `compose/3` over hostile display names (CR LF with `Bcc:` and a blank-line body split, `<script>`, `http://evil.example/x`, `javascript:alert(1)`, `www.evil.example`, `a@evil.example`, bidi controls, zero-width, over-length, invalid UTF-8, empty) and hostile slugs: the composed `subject` equals the fixed string; the composed map has exactly the keys `from to subject body`; the body contains no `\r`, no NUL, and every line is a fixed line or one of the three tenant-line shapes; every URL-like token (`[A-Za-z][A-Za-z0-9+.-]*://\S+`) in the body starts with the configured base URL, and the number of URLs equals the number of tenants; no tenant-derived `://`. `tenant_link/2` over slugs containing `/ ? & # % @ ..` and non-ASCII is percent-encoded and parses back (`URI.parse`) to host == the base host. Recipient cases: CR/LF, `,`, `<>`, space, non-ASCII, two `@`, over-length each return `{:error, :invalid_recipient}` and the sink case proves NO connection is made. Sink case: a hostile display-name multi-tenant delivery; the sink's raw header block contains exactly the allow-listed header names (From, To, Subject, Date, Message-ID, MIME-Version, Content-Type, Content-Transfer-Encoding) and no others, and contains no `Bcc`. StreamData property (stream_data is in `mix.exs`): for arbitrary binaries as display names and slugs, `compose/3` never raises, and any `{:ok, composed}` satisfies the invariants above. |
| AC10 | pipeline gates | `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test` for the touched areas (`test/letflow/login_discovery*`, the new files, `test/letflow/routers/login_discovery*`), `mix letflow.check_boundaries`; ELIXIR-DEV and TEST-RUNNER quote the real output; the SECURITY-REVIEWER verdict is recorded against INV-4, INV-5, INV-8, INV-9 (8). `mix letflow.check_boundaries`: new modules live under `Letflow.LoginDiscovery.*`; `Smtp.Transport` is the only module that references the mail library (the boundary check, if it supports it, is extended; otherwise a grep test: `:gen_smtp` appears only in `transport.ex`). |

Additional tests beyond the ten criteria (design obligations):

- `Dispatch` unit: bucket-refused gives `:skipped` and no adapter call; the notifier event is emitted
  even when the fixed warning is logged; `submit/3` still returns `:ok` immediately.
- Fail-closed STARTTLS: script `{:no_starttls_offered}` with mode `:starttls`; the sink records zero
  `MAIL FROM`, zero `AUTH` and no password bytes on the wire (the adapter never downgrades).
- Verified TLS success: script `{:starttls, :trusted}` with the generated CA override; one message
  delivered over TLS; and the same script WITHOUT the override fails (default trust store), proving
  verification is on by default.
- Hard timeout: `:slow_drip` kills at `timeout_ms`, `open_connections/1` returns 0 within a bounded wait.
- Credentials in AUTH: the sink decodes the AUTH exchange and checks the username/password markers
  were presented to the SERVER (so the test that the markers are absent from logs is not vacuous).

---

## 7. Files to touch

| File | Change | Owner |
|---|---|---|
| `lib/letflow/login_discovery/notifier/smtp.ex` | new: `Smtp` | ELIXIR-DEV |
| `lib/letflow/login_discovery/notifier/smtp/message.ex` | new: pure composer | ELIXIR-DEV |
| `lib/letflow/login_discovery/notifier/smtp/config.ex` | new: parse / runtime | ELIXIR-DEV |
| `lib/letflow/login_discovery/notifier/smtp/transport.ex` | new: the only library-naming module | ELIXIR-DEV |
| `lib/letflow/login_discovery/dispatch.ex` | add notifier event (4.2); moduledoc | ELIXIR-DEV |
| `config/runtime.exs` | env parsing block (3.1/3.2), beside the REQ-437 block | ELIXIR-DEV |
| `config/config.exs` | comment only, if at all (defaults unchanged); `config/test.exs` unchanged unless a sink default is needed (prefer none) | ELIXIR-DEV |
| `mix.exs`, `mix.lock` | gen_smtp (+ ranch) ONLY after approval (H1) | ELIXIR-DEV, gated |
| `.env.example`, `deploy/.env.example` | names-only block (3.7) | ELIXIR-DEV |
| `docs/runbooks/` (optional) | one-page SMTP relay setup note, if ORCH wants it; not required by the AC | DOC-UPDATER |
| `test/support/smtp_sink.ex` | new in-process sink (6.1) | TEST-DESIGNER |
| `test/letflow/login_discovery/notifier/smtp_test.exs`, `smtp_message_test.exs`, `dispatch_notifier_event_test.exs`, `notifier_no_leak_test.exs`, `no_retry_guard_test.exs`; `test/letflow/routers/login_discovery_notifier_uniform_test.exs`; `test/letflow/mail_runtime_config_test.exs`; `test/letflow/no_smtp_secret_guard_test.exs` | new | TEST-DESIGNER |
| `test/support/login_discovery_notifier_double.ex` | NOT touched (reused; REQ-441 item 5) | none |
| `lib/letflow/login_discovery/notifier.ex`, `notifier/noop.ex` | NOT touched (port unchanged, AC1) | none |

Overlaps with the sibling worktree `letflow-4` (outside this checkout; I did not read it; ORCH to
check before dispatching ELIXIR-DEV and before merge): any `login_discovery*` file, in particular
`lib/letflow/login_discovery/dispatch.ex` and the test files under `test/letflow/login_discovery/`;
`config/runtime.exs` (the REQ-437/439/443 blocks sit directly beside the new block); `config/config.exs`;
both `.env.example` files; `mix.exs`/`mix.lock`; `docs/requirements.yaml` status. REQ-444 (the
enablement gate, depends on this entry) will also edit `config/runtime.exs` and will read the
`Notifier` `adapter:` key; place the new block as one contiguous, self-contained section to keep a
merge trivial. Per the project memory rule, ORCH commits this design before dispatching the next agent.

---

## 8. SECURITY-REVIEWER focus list

INV-4 (secrets by reference)
1. Confirm no credential enters app env, a struct, a closure, telemetry or a return value (3.5); the
   username/password resolve via `System.get_env/1` in `Smtp` and live only as an argument to
   `Transport.send_message/4`.
2. The highest unknown: does the chosen library spawn a worker whose crash report prints its
   arguments (1.3 item 6)? Read the source, then confirm with the AC5 marker test across the kill
   (`brutal_kill`) path and a worker crash.
3. Library logging (1.3 item 7). If any, the contingency filter must be specified before merge.
4. No-secret grep guard (AC6) and `.env.example` shape.
5. `Application.get_all_env(:letflow)` carries host/port/sender/base URL only.

INV-5 (indistinguishability) and uniformity
6. The HTTP response is independent of delivery (4.1, AC3 byte equality across 9 delivery results).
7. The notifier counter: metadata is exactly `%{outcome: _}`, no per-address dimension, no reason, no
   reply text. Aggregate residual: a counter of attempts shows that some addresses have tenants. Confirm
   acceptable, and that exposing it on a dashboard needs a separate decision (OQ-5). REQ-441's own open
   question 4 (is `:failed` an oracle?) is answered here as: not per address; the decision on any future
   exposure is REQ-444-adjacent.
8. Timing: delivery is off the request path; the SMTP adapter adds no request-path latency.

INV-8 (no unhandled crashes)
9. `Smtp` returns typed results for every library return and raise (library calls wrapped; no pattern
   match that can raise on a realistic failure). Dispatch's `rescue`/`catch` and timeout are unchanged;
   `Transport` runs inside the inner task.
10. Hard timeout kills a stuck library call and leaves no socket (6.2 hard-timeout test).

INV-9 (tenant-controlled outbound URL)
11. The SMTP host/port are operator config, not tenant-controlled, so INV-9's https-only and
    private-range rules do not apply (3.6); confirm. Advisable host validation is syntactic only; a
    private or loopback relay is legitimate. The base URL is also operator config and validated
    (scheme, no userinfo/query/fragment).
12. Tenant text reaches the message body only, defanged (2.3); the only links are base-URL links with the
    slug percent-encoded. Confirm the residual in OQ-9.

Other
13. Verified TLS by default and fail-closed STARTTLS (no downgrade when the server omits STARTTLS), no
    plaintext in `:prod`, the test-only CA override cannot be set from the environment (3.4, OQ-4).
14. Email-bombing: one attempt per `:send` bucket token, zero retries, recipient equals the typed
    address and nothing else (the AC2 sink check "no other recipient"); no `Cc`/`Bcc`.
15. SMTP reply text can reveal mailbox existence; it never leaves the adapter (not returned, not logged,
    not in telemetry).

---

## 9. Open questions (none silently resolved)

- OQ-1. Library: supervisor choice among gen_smtp alone (recommended), Swoosh + gen_smtp, Swoosh + Mua
  (decision 0045 OQ-A). Approval of the dependency is a hard stop (H1).
- OQ-2. Do all items in 1.3 hold for the chosen library? Answered by ELIXIR-DEV reading `deps/` source
  after approval; any "no" amends this design.
- OQ-3. Credentials-at-call-time (3.5) versus the requirement's "read once at boot": this design reads
  the two secrets at call time and validates presence at boot. Is this deviation acceptable, or does the
  supervisor prefer storing them in app env (inspectable) for literal compliance?
- OQ-4. The test-only CA override (3.4) read from app env: acceptable, or should the TLS tests use a
  differently-scoped seam (for example a compile-time-only option)? SECURITY-REVIEWER to decide.
- OQ-5. Should the `[:letflow, :login_discovery, :notifier]` event be surfaced by the Prometheus
  registry? Not done here. And: is the `:skipped`-for-Noop and the "no event when nothing to deliver"
  choice (4.2) accepted? The alternative (emit `:skipped` for every nothing-to-deliver task) makes the
  counter a per-request match-rate signal and is rejected here.
- OQ-6. Exact subject and body wording (2.3) is a product / BA copy decision; structure is binding.
- OQ-7. Is the SPA served at the root of `LETFLOW_PUBLIC_BASE_URL` in every environment so that
  `<base>/?realm=<slug>` is a working link? (P11; the SPA is served by nginx per `deploy/nginx/`, not
  checked here.) If a tenant's login is on a subdomain (`<slug>.<domain>`) instead, the link format
  changes.
- OQ-8. Internationalised (non-ASCII) recipient addresses are not delivered (no SMTPUTF8). Acceptable?
- OQ-9. Residual auto-linking of bare domains inside tenant display names by some mail clients (2.3
  rule 4). Accept, or tighten (for example by showing only the slug code and not the display name)?
- OQ-10. The 50-tenant cap and the fixed overflow line (2.3 rule 6): confirm the number, or drop the cap.
- OQ-11. Credentials for dev: `smtp` requires non-empty username and password even against a local
  relay that needs no auth (the acceptance criterion says missing credentials raise). Dev must set
  throwaway values. Acceptable?
- OQ-12. Mutating the shared `timeout_ms` per adapter (4.4) versus a separate `smtp_timeout_ms` key read
  by Dispatch: this design reuses `timeout_ms` (no Dispatch signature change). Confirm.
- OQ-13. External, not in this repository: the ai-dala-infra secrets inventory and SPF/DKIM/DMARC
  (H3), and the lawful-basis gate (H4).
