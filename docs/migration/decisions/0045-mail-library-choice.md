# 0045 -- Mail library for the login-discovery notifier adapter (REQ-441)

Status: PROPOSED. Not ratified. The new hex dependency this record recommends is a HARD STOP:
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
