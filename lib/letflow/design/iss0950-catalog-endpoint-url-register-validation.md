# ISS-0950 -- Register/publish-time syntactic validation of catalog `endpoint_url`

Run: WF03-ISS0950-20261001. Queue Q-921, GH-2095. Severity MINOR (defense in depth).
Owner of the build: ELIXIR-DEV. Design only -- signatures and shapes, no bodies.

Sources read: step-01 diagnosis; `lib/letflow/service_catalog/entry.ex`;
`lib/letflow/service_catalog.ex` (register/1 L214-243, publish/3 -> do_publish ->
apply_publish L337-408); `lib/letflow/routers/admin_services.ex` (handle_register
L212-242, handle_publish L292-324); `lib/letflow/webhooks/url_validator.ex`;
`lib/letflow/engine.ex` (render_service_task_url, L1148-1156);
decision 0027; `docs/agents/instructions/security-invariants.md` INV-9.

---

## 1. Problem and invariant restated

`POST /admin/services` (note: the issue and decision 0027 say `/service-catalog`; the
real mount is `/admin/services`) and `POST /admin/services/:service_id/versions`
accept any string as `endpoint_url` (presence + max 2048 only). The sole control is the
dispatch-time INV-9 gate. Goal: reject statically-bad URLs at write time for fast
feedback.

**Dispatch gate stays binding and unchanged.** `ServiceTaskDispatcher.http_transport/3,4`
and its `UrlValidator.validate/2` call (real DNS, every address checked, immediately
before the request) are NOT touched, weakened, or made conditional on this change.
This design adds a second, earlier, weaker check. A URL that passes it can still be
refused at dispatch (hostname resolving to a private address, DNS failure, DNS
rebinding), and that is expected. Also untouched: `Engine.resolve_service_task_arm_attrs`,
`ServiceCatalog.resolve_pinned_version/3`, `solution_pack.ex` (decision 0027 forbids
packed `service_catalog_entries`; there is no install write path, so 0027 imposes no
install-time rule and this change adds none).

## 2. Decisions

### D1. Where the check lives: the two Entry changesets (single choke point)

The only write paths that take an `endpoint_url` from caller input are
`ServiceCatalog.register/1` (via `Entry.insert_changeset/2`) and
`ServiceCatalog.publish/3` (via `Entry.publish_changeset/2`, inside `apply_publish`).
`update_scope_changeset/2` casts only scope/owner; `retire_changeset/1` casts nothing;
`archive_current_version` copies the already-stored previous value (not new input).
Putting the check in both changesets covers both, requires no router change and keeps
INV-RT-1 (no Repo in routers) intact.

### D2. No-DNS mechanism: a new public function on `UrlValidator`, not a stub resolver

Decision: add `Letflow.Webhooks.UrlValidator.validate_syntactic/1`.

Justification:
- No resolver parameter means "no DNS at register time" is structural (the function
  cannot reach `:inet`), not a property of a closure someone might later swap.
- A stub resolver returning a fake public address (`fn _ -> {:ok, [203.0.113.1]} end`)
  makes a hostname look "verified public" and invites copy/paste of a lie into other
  call sites; it also forces Entry to know the `dns_resolver()` type.
- It reuses the SAME private `check_scheme/1`, `check_ip_literal/1`, `blocked_ipv4?/1`,
  `blocked_ipv6?/1` the dispatcher uses. The blocklist is not duplicated anywhere; a
  future range added there is picked up here automatically.
- It is greppable and independently testable (section 7, unit test U-NODNS).

Semantics of `validate_syntactic/1`: identical to `validate/2` except that a host which
is NOT an IP literal returns `:ok` without any resolution. Scheme must be `https`; host
must be non-nil/non-empty; IP-literal hosts are checked against the existing blocklist
(127/8, 10/8, 172.16/12, 192.168/16, 169.254/16 incl. 169.254.169.254, ::1, fc00::/7,
fe80::/10, IPv4-mapped and IPv4-compatible IPv6 forms). Refactor shape: `check_host/2`'s
non-IP branch is the only thing that differs, so the ELIXIR-DEV change is to split that
branch out (e.g. a shared private function taking an "on non-IP host" mode), not to
copy the checks. `validate/1` and `validate/2` observable behaviour must be byte-for-byte
unchanged (existing `url_validator_test.exs` stays green untouched).

Pre-existing gaps in the shared blocklist (0.0.0.0, 100.64.0.0/10, multicast) are
out of scope and are NOT fixed here (would change the dispatch gate and webhooks;
file separately if wanted).

### D3. Template policy

`endpoint_url` is a template: at activation the engine rewrites every match of the
`{{variables.KEY}}` pattern (whitespace tolerant) with the instance variable value
(`render_service_task_url`), so the stored string is not the string that is requested.
Variables are instance/tenant controlled, so anything an instance variable can influence
must not be able to alter scheme or host.

Policy (fail closed):

1. **Prefix extraction.** The string must contain `"://"`. Let *head* be the text from
   the start of the string up to, but excluding, the first `/`, `?` or `#` found after
   that first `"://"` (the whole string if none). *head* = scheme + `://` + authority
   (userinfo, host, port). Everything after *head* (path, query, fragment) is the
   "tail".
2. **Tail is unconstrained.** Placeholders (and any other characters) in the tail are
   allowed and not inspected, e.g. `https://example.test/iss0917/{{variables.region}}/svc`.
   The tail cannot change the host because *head* ends at the first `/`, `?` or `#`
   and a rendered value inside the tail cannot move that boundary backwards.
3. **No template tokens in *head*.** If *head* contains `{` or `}` -- a placeholder in
   scheme, userinfo, host or port position, e.g. `{{variables.absent}}`,
   `https://{{variables.h}}/x`, `https://api.{{variables.t}}.example.com/`,
   `https://example.test{{variables.p}}` (no `/` before the token, so it sits in
   authority) -- the URL is rejected. Rationale: a host that depends on a runtime
   variable cannot be checked at write time and is exactly the SSRF-shaped pattern
   (an instance variable steering the request target); the dispatch gate would still
   catch a bad rendered result, but registering such an entry defeats the purpose of
   fast feedback and widens the attack surface. A legitimate need for a templated
   subdomain is out of scope (see open question OQ-1).
4. **Literal *head* validation.** Otherwise call
   `UrlValidator.validate_syntactic(head)`. Only *head* is passed -- never the tail --
   so no placeholder masking, no copy of the engine's regex, and no drift risk against
   the engine's renderer are needed. Parity with dispatch: both sides use `URI.parse/1`
   on the same authority text, so `https://good.example@127.0.0.1/` is rejected here
   exactly as it will be at dispatch (host parses as `127.0.0.1`).
5. A string with no `"://"` (`not a url`, `example.test/x`, empty after trim handled by
   `validate_required`) is rejected.

Case/whitespace: no trimming or normalisation is added; `URI.parse/1` semantics are
inherited unchanged (scheme is lower-cased by the parser, so `HTTPS://example.test/x` is
accepted exactly as the dispatcher would accept it; leading space makes the scheme nil
and is rejected).

### D4. Error shape

On failure the changeset gets one error on `:endpoint_url`:
- message (stable, exact): `"must be an https URL whose host is not a private, loopback or link-local address; template placeholders are allowed only after the host"`
- opts keyword: `validation: :endpoint_url_not_allowed`

No new return atom. `register/1` and `publish/3` keep their existing `@spec`s
(`{:error, Ecto.Changeset.t()}` is already a member). Both router `case` statements
already map any `%Ecto.Changeset{}` to `Response.unprocessable(conn, "validation failed")`
(HTTP 422, problem+json, `detail: "validation failed"`; no field/URL leakage). **No
router change.** This deliberately avoids the `{:error, :target_url_not_allowed}` atom
route: `Routers.Webhooks.handle_create` has only a Changeset clause for that precedent
(flagged by step-01, not run, out of scope here); a new atom would need new clauses in
both router cases and a missing clause is a 500.

### D5. Pitfall the build must avoid: `validate_change` does not run on unchanged values

`Ecto.Changeset.cast/3` records no change when the supplied value equals the struct's
current value. On `publish_changeset/2` the base struct is the current row, so a new
version that re-uses the same `endpoint_url` as the current version (very common) would
silently skip a `validate_change`-based check, leaving a legacy bad URL unvalidated on
republish. Therefore the validation reads the effective value with
`get_field(changeset, :endpoint_url)` and runs on every call of both changesets. It is
skipped only when (a) the value is nil (already an error from `validate_required`) or
(b) the changeset already carries an error on `:endpoint_url` (e.g. length > 2048), to
avoid two errors for one field. Consequence, accepted and intended: republishing a
version with an unchanged legacy-bad URL now returns 422; the admin must supply a good
URL.

**Absent-key semantics on publish (corrected).** `validate_required` and `get_field` both
read the effective value (changes over data). On `publish_changeset/2` the base struct is
the current row (`service_catalog.ex:405-406`), so a publish attrs map WITHOUT the
`endpoint_url` key (the router builds it with `maybe_put`, `admin_services.ex:297`, so an
omitted body field yields exactly that) leaves `endpoint_url` = the STORED value.
`validate_required` therefore passes; it demands the field only when the effective value
is nil/blank, i.e. an explicit `nil`, `""` or whitespace-only string (cast turns these into
a nil change). Consequences, all intended:
- key absent + stored URL passes the check -> publish succeeds and keeps the old URL
  (unchanged pre-existing behaviour);
- key absent + stored URL is legacy-bad -> publish fails with the new
  `endpoint_url_not_allowed` error (the check validates the effective value, D5);
- explicit nil / `""` / whitespace -> only the `validate_required` error, no second error
  from the new step (the new step skips a nil value).

**Scope decision: making `endpoint_url` mandatory in the publish body is OUT of scope.**
Current absent-key behaviour (inherit the stored value) is not changed by ISS-0950; no
change to `handle_publish`, `publish_attrs()` or `validate_required` lists.

### D6. Already-stored bad rows

Tolerated. No migration, no backfill, no new read-path check. The dispatch gate covers
them. `resolve_pinned_version/3`, `list`, `get`, `retire` do not validate and must not.

### D7. Transactionality

`publish/3` runs `archive_current_version` BEFORE `apply_publish`. The new failure surfaces
from `apply_publish` as `{:error, changeset}`, which `do_publish` turns into
`Repo.rollback/1`, so the archive insert is rolled back too. A rejected publish leaves
the live row and `service_catalog_versions` byte-identical. This is asserted in the test
matrix (P-ROLLBACK).

## 3. Function signatures

`lib/letflow/webhooks/url_validator.ex` (new public function, additive):

    @spec validate_syntactic(url :: String.t()) :: :ok | {:error, :target_url_not_allowed}

Contract: pure, no I/O, never calls any resolver or `:inet`; `validate/1`, `validate/2`,
`default_resolver/1` and the `dns_resolver` type unchanged. Update the moduledoc with
one paragraph describing the new function and its sole intended use (write-time
fast feedback; never a substitute for `validate/2` before a request).

`lib/letflow/service_catalog/entry.ex` (new public, pure, unit-testable):

    @spec check_endpoint_url(endpoint_url :: String.t()) ::
            :ok | {:error, :endpoint_url_not_allowed}

Implements D3 steps 1-5 (calls `UrlValidator.validate_syntactic/1` on *head*; maps its
`{:error, :target_url_not_allowed}` and the brace/`"://"` rejections to the single atom
`:endpoint_url_not_allowed`). Add `@doc` stating it is advisory and the dispatch gate is
binding.

New private changeset step (name fixed for reviewability):

    @spec validate_endpoint_url(Ecto.Changeset.t()) :: Ecto.Changeset.t()

Wired into `insert_changeset/2` immediately after `validate_length(:endpoint_url, max: 2048)`
and into `publish_changeset/2` immediately after its `validate_length(:endpoint_url, max: 2048)`.
Behaviour per D4/D5. `update_scope_changeset/2` and `retire_changeset/1` unchanged.

Entry moduledoc: extend the existing "Changeset-level checks are advisory only" section
with one short paragraph (INV-9 dispatch gate is authoritative; this is fast feedback).

`Letflow.ServiceCatalog.register/1` / `publish/3` / `publish_attrs()` / `register_attrs()`:
no signature, spec, or doc-behaviour change beyond one sentence in each `@doc` listing
the new changeset error.

## 4. Files to change (exact)

Production:
1. `lib/letflow/webhooks/url_validator.ex` -- add `validate_syntactic/1`; share (not copy)
   scheme/host/IP-literal checks; moduledoc paragraph.
2. `lib/letflow/service_catalog/entry.ex` -- add `check_endpoint_url/1`, private
   `validate_endpoint_url/1`, wire into `insert_changeset/2` and `publish_changeset/2`,
   moduledoc paragraph.
3. `lib/letflow/service_catalog.ex` -- doc sentences only on `register/1` and `publish/3`
   (no code change). DO add the two @doc sentences.

Docs (DOC-UPDATER / ELIXIR-DEV, small):
4. `docs/agents/instructions/security-invariants.md` INV-9 "Reference" paragraph: add the
   catalog write path as a third (advisory, register/publish-time) call site and record
   that `validate_syntactic/1` exists. The "How to verify" list gains the new test files
   from section 6.
5. `docs/migration/decisions/0027-solution-pack-service-catalog-install-policy.md`:
   DO NOT edit decision 0027 (it is a signed-off record). The closure of its INV-9
   point-3 gap and the `POST /service-catalog` -> `POST /admin/services` correction are
   recorded only in the INV-9 paragraph (item 4) and in the issue YAML note by ORCH.
6. `docs/issues/ISS-0950.yaml` status flip is ORCH/DOC-UPDATER's, not the builder's.

Explicitly NOT changed: `lib/letflow/routers/admin_services.ex` (the Changeset clause
already maps to 422), `lib/letflow/engine*.ex`, `lib/letflow/engine/service_task_dispatcher.ex`,
`lib/letflow/definitions/solution_pack.ex`, any migration, `web/` (the
`ServicesPage.tsx` free-text form already renders the generic 422 failure; no new
client contract; the e2e pipeline spec uses `https://httpbin.org/anything` by default
and is unaffected unless CI sets an `http://` or localhost `SERVICE_TASK_MOCK_BASE_URL`,
which the dispatch gate would already reject; DO NOT edit the e2e spec or CI config).

## 5. Existing tests / fixtures to adjust (exact)

Exactly ONE existing test must change:

- `test/letflow/engine_catalog_service_task_test.exs`, test
  "an endpoint_url that renders to an empty string keeps the existing url_rendered_empty
  error (no row)" (line ~361-373), whose line 363 is
  `register_with!(%{endpoint_url: "{{variables.absent}}"})`.

  Why it must change: under D3 step 3 a bare placeholder is rejected at register time,
  so `register_with!` (which asserts `{:ok, entry}`) would fail. Why that is acceptable:
  the test's purpose is not register-time acceptance; it pins the ENGINE's behaviour
  (`:service_task_url_rendered_empty`, no dispatch row, projection `:error`) for a
  catalog row whose endpoint renders empty. That row can still legitimately exist as
  already-stored legacy data (D6), and the engine path must stay robust to it.
  How: keep the test and every assertion unchanged; replace only the setup. Register the
  entry with the default valid `@v1_url` via `register_with!(%{})`, then force the stored
  value with a direct statement that bypasses changesets, matching the file's/this
  suite's existing precedent of raw SQL writes via `Repo.query`/`Repo.query!` in
  `service_catalog_test.exs` (lines 182-248, 634, 853, 888). Either raw SQL
  (`UPDATE service_catalog SET endpoint_url = $1 WHERE service_id = $2`; confirm the real
  table/column names against the schema) or `Repo.update_all` on `Entry` (which also
  bypasses changesets; `Ecto.Query` is already imported in that file) is acceptable; the
  recommended form is `Repo.update_all(from(e in Entry, where: e.service_id ==
  ^entry.service_id), set: [endpoint_url: "{{variables.absent}}"])`. Because the pin freezes `version_id`
  resolution to the row, update the live row only (the test registers v1 and pins it; the
  engine resolves the pinned version from the current row by `version_id`). A one-line
  comment must say the value is seeded as legacy data on purpose because register now
  rejects it. The rejected-at-register behaviour of this exact string is covered by new
  test matrix row R-BARE-TPL.

Verified unaffected (all use a literal `https://example.test/...` head; a template, where
present, is in the path only): `service_catalog_test.exs` (102, 910, 947, 954, 1002; raw
SQL INSERTs at 184-250, 855, 890 bypass changesets), `routers/admin_services_test.exs:107`,
`routers/admin_services_publish_retire_test.exs` (98, 123, 147, 175, 190),
`service_catalog_resolve_pinned_version_test.exs`, `engine_pin_resolver_catalog_test.exs`,
`engine_catalog_service_task_test.exs` lines 44-45, 71, 89 and the path-template test at
~346, `routers/tasks_test.exs` (`register_catalog_entry!` at 2216, callers 2260, 2294),
`support/service_catalog_reaper_test.exs:74`. Grep of `endpoint_url: "` across `test/`
found no other non-`example.test` value. ELIXIR-DEV must re-run this grep after the
change and run the named files (not the full suite) to confirm.
`test/letflow/webhooks/url_validator_test.exs` and `webhooks_test.exs` stay unmodified
(additive tests go in new/appended blocks only).

## 6. New test files

- Append a `describe "validate_syntactic/1"` block to
  `test/letflow/webhooks/url_validator_test.exs` (async, no DB).
- New `test/letflow/service_catalog/endpoint_url_validation_test.exs`: pure
  `Entry.check_endpoint_url/1` table (async, no DB) plus `register/1` and `publish/3`
  cases (DB; follow the sandbox/cleanup conventions of `service_catalog_test.exs`).
- Append to `test/letflow/routers/admin_services_test.exs` (register 422) and
  `test/letflow/routers/admin_services_publish_retire_test.exs` (publish 422).

## 7. Test matrix

Legend: E = `Entry.check_endpoint_url/1` (pure); R = `ServiceCatalog.register/1`;
P = `ServiceCatalog.publish/3`; HTTP = router. Every REJECT row is asserted at E, R, P
and HTTP unless noted; every ACCEPT row at E, R, P and HTTP 201.

REJECT (E -> `{:error, :endpoint_url_not_allowed}`; R/P -> `{:error, %Ecto.Changeset{}}`
with `errors[:endpoint_url]` containing the D4 message and `validation: :endpoint_url_not_allowed`;
HTTP -> 422, body `detail == "validation failed"`):

| ID | URL | Class |
|---|---|---|
| R-HTTP | `http://example.test/x` | non-https scheme |
| R-FTP | `ftp://example.test/x` | other scheme |
| R-NOURL | `not a url` | not a URL |
| R-SCHEMELESS | `example.test/x` | no scheme |
| R-NOHOST | `https:///x` | host missing |
| R-LOOP4 | `https://127.0.0.1/x` | IPv4 loopback |
| R-META | `https://169.254.169.254/latest/meta-data` | link-local / cloud metadata |
| R-RFC10 | `https://10.0.0.5/` | RFC-1918 10/8 |
| R-RFC172 | `https://172.16.0.1/` and `https://172.31.255.255/` | 172.16/12 edges |
| R-RFC192 | `https://192.168.1.1/` | 192.168/16 |
| R-LOOP6 | `https://[::1]/x` | IPv6 loopback |
| R-ULA | `https://[fd00::1]/x` | fc00::/7 |
| R-LL6 | `https://[fe80::1]/x` | fe80::/10 |
| R-MAPPED | `https://[::ffff:127.0.0.1]/x` | IPv4-mapped IPv6 |
| R-USERINFO | `https://good.example@127.0.0.1/x` | userinfo trick (host is the IP) |
| R-BARE-TPL | `{{variables.absent}}` | bare template (the former fixture) |
| R-TPL-HOST | `https://{{variables.h}}/x` | templated host |
| R-TPL-SUBHOST | `https://api.{{variables.t}}.example.com/x` | partly templated host |
| R-TPL-PORT | `https://example.test:{{variables.p}}/x` | templated port (authority) |
| R-TPL-SCHEME | `{{variables.s}}://example.test/x` | templated scheme |
| R-TPL-NOSLASH | `https://example.test{{variables.p}}` | token in authority, no `/` |
| R-TPL-USERINFO | `https://{{variables.u}}@example.test/x` | token in userinfo |

ACCEPT (E -> `:ok`; R/P -> `{:ok, entry}`; HTTP -> 201):

| ID | URL | Class |
|---|---|---|
| A-PLAIN | `https://example.test/svc` | hostname, `.test` (would fail real DNS) |
| A-PORT | `https://example.test:8443/svc` | explicit port |
| A-PUBIP | `https://203.0.113.10/svc` | public IP literal |
| A-172-OUT | `https://172.32.0.1/svc` | just outside 172.16/12 |
| A-UPPER | `HTTPS://example.test/svc` | scheme case (parser lower-cases; parity with dispatch) |
| A-TPL-PATH | `https://example.test/iss0917/{{variables.region}}/svc` | placeholder in path |
| A-TPL-QUERY | `https://example.test/svc?r={{variables.region}}` | placeholder in query |
| A-TPL-FRAG | `https://example.test/svc#{{variables.f}}` | placeholder in fragment |
| A-TPL-SPACED | `https://example.test/{{ variables.region }}/x` | whitespace-tolerant token |
| A-TPL-ONLYPATH | `https://example.test/{{variables.a}}{{variables.b}}` | multiple tokens |

Write-path-specific cases:

- P-SAME-URL: current row has a legacy-bad URL inserted via raw SQL (bypass); `publish/3`
  with the SAME bad `endpoint_url` -> `{:error, %Changeset{}}` (proves D5: not skipped
  by "no change"). And `publish/3` with a good URL on that legacy row -> `{:ok, _}`
  (admin can repair).
- P-ROLLBACK: after any rejected publish, the live row (version, endpoint_url, version_id)
  is unchanged and `service_catalog_versions` has no new row for the service (D7).
- R-NO-ROW: after a rejected `register/1`, no `service_catalog` row exists for the id.
- R-LEN: 2049-char valid-looking URL yields exactly ONE `:endpoint_url` error (the length
  error), proving D5(b) de-duplication.
- R-MISSING (per write path):
  - register/1 with key absent, explicit nil, `""` or whitespace-only: exactly ONE
    `:endpoint_url` error, the `validate_required` one (no second error from the new step).
  - publish/3 with explicit nil, `""` or whitespace-only: same, exactly ONE
    `validate_required` error.
  - publish/3 with the key ABSENT: NOT a required error (see P-ABSENT).
- P-ABSENT (publish, `endpoint_url` key omitted from attrs; base is the current row):
  (a) current row has a good stored URL -> `{:ok, entry}`, new version row has the SAME
  `endpoint_url` as before (inherits the stored value); (b) current row has a legacy-bad
  URL (raw SQL seeded) -> `{:error, %Changeset{}}` with the `endpoint_url_not_allowed`
  error and NO `validate_required` error, and P-ROLLBACK holds. Both sub-cases asserted
  at P level; (a) also at HTTP (201, body omits the field in the request).
- UNTOUCHED-PATHS: `update_scope/2` and `retire/1` on a legacy-bad-URL row still succeed
  (no URL check on those paths).

Router-level (HTTP) assertions, in addition to the status/detail above: as PLATFORM_ADMIN,
`POST /admin/services` with each of R-HTTP, R-META, R-TPL-HOST -> 422 and body contains
neither the submitted URL nor the word `endpoint_url`/`validate`-internals (no leakage;
body `detail` is exactly `"validation failed"`); `POST /admin/services/:id/versions`
with R-LOOP4 -> 422 and a follow-up GET shows version unchanged. Existing non-admin 403
tests are unaffected.

Unit tests for `UrlValidator.validate_syntactic/1` (no DB, async):
- U-SCHEME / U-HOSTNIL: http, ftp, schemeless, empty string, `https://` -> `{:error, :target_url_not_allowed}`.
- U-BLOCKLIST: one named test per range, mirroring the existing `validate/1` tests:
  127.x, 10.x, 172.16-31 (both edges), 192.168.x, 169.254.x incl. 169.254.169.254 by name,
  ::1, fc00::/fd00::, fe80::, IPv4-mapped and IPv4-compatible forms.
- U-PARITY: for every IP-literal and scheme/host case above,
  `validate_syntactic(url) == validate(url)` (the IP-literal path of `validate/1`
  short-circuits before DNS, so this is safe and proves the blocklist is shared, not
  copied).
- U-NODNS (the "no DNS lookup" assertion), two parts, both required:
  (a) contrast: `validate_syntactic("https://example.test/x") == :ok` while
  `validate("https://example.test/x", fn _ -> {:error, :nxdomain} end)` returns
  `{:error, :target_url_not_allowed}` -- the only difference is the (non-)resolution.
  (b) trace: ensure the modules are loaded first (`Code.ensure_loaded!(:inet)`,
  `Code.ensure_loaded!(:inet_res)`), then in the test process
  `:erlang.trace(self(), true, [:call])` with one `:erlang.trace_pattern/3` call per
  pattern, each with match spec `true` and options `[:local]`: `{:inet, :getaddrs, 2}`,
  `{:inet, :gethostbyname, 1}`, `{:inet, :gethostbyname, 2}`, and
  `{:inet_res, :_, :_}` (wildcards are `:_`; ranges such as `1..2` are NOT valid
  arities). Then call `validate_syntactic/1` with several
  hostnames (`example.test`, `localhost`, `internal.corp`), then `refute_receive
  {:trace, _, :call, {:inet, _, _}}` within a short window; turn tracing off in
  `on_exit`. `localhost` must return `:ok` here (hostname literal is not resolved; the
  dispatch gate is what stops it after resolution) and the test documents that
  explicitly so nobody "fixes" it. If trace is unavailable in the sandboxed CI the
  build must fall back to (a) only and say so in its handoff; it must not drop (a).

No new dispatcher tests; the existing dispatcher/INV-9 tests are the evidence the gate is
unchanged, and ELIXIR-DEV must run them (`service_task_dispatcher_test.exs`,
`webhooks_test.exs`, `url_validator_test.exs`) unmodified.

## 8. Acceptance-criteria mapping

| Criterion | Element |
|---|---|
| Design file, no implementation code | this file: signatures/specs and prose only |
| No-DNS approach decided and justified | D2 `validate_syntactic/1`; tests U-NODNS (a)+(b) |
| Template policy incl. `{{variables.absent}}` fixture | D3, section 5 (fixture setup change, assertions unchanged), R-BARE-TPL |
| Files-to-change / tests-to-adjust exact | sections 4 and 5 |
| Dispatch gate unchanged, stated | section 1; section 7 closing paragraph |
| Matrix covers every rejected/accepted class and both write paths | section 7 (E/R/P/HTTP columns, P-* and R-* cases) |

## 9. Cross-module dependencies and invariants

- `Entry` gains a compile-time dependency on `Letflow.Webhooks.UrlValidator`
  (webhooks -> catalog coupling by function call only; no cycle: UrlValidator depends on
  nothing in the catalog). It is a utility module already shared by the dispatcher.
- INV-9: still satisfied at the request call site; this is the "fast tenant feedback"
  tier the invariant already describes for webhooks, extended to the catalog.
- INV-RT-1: no Repo in routers -- preserved (no router change).
- Decision 0027: honoured (no pack-install code; gap named in its INV-9 point 3 closed
  at the admin route/context layer).
- No DB change, no migration, no new index or constraint.

## 10. Open questions (decided defaults given; none block the build)

- OQ-1: Should a templated subdomain/host (`https://{{variables.tenant}}.api.example.com/`)
  ever be allowed? Default decided here: NO (reject, fail closed). Relaxing it would need
  an allowlist design plus SECURITY-REVIEWER sign-off; file a separate issue if a real
  use case appears.
- OQ-2: `localhost` and other non-IP names that resolve privately are accepted at
  register time by design (no DNS); the dispatch gate rejects them after resolution.
  Default: keep, documented in the U-NODNS test. Rejecting well-known names would be
  heuristic and bypassable, so it is deliberately not added.
- OQ-3: Webhook-side precedent `Routers.Webhooks.handle_create` may lack a clause for
  `{:error, :target_url_not_allowed}` (step-01 read it by eye, did not run it). Out of
  scope for ISS-0950; ORCH may file a separate issue.
