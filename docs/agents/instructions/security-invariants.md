# Security Invariants — Letflow

**Audience:** every agent in the pipeline. Canonical location for Letflow's hard
security constraints. `SECURITY-REVIEWER` gates against this exact list; every other
role that touches tenant-scoped data (ELIXIR-DEV, FRONTEND-DEV, ISSUE-FIXER) must know
these exist even though only SECURITY-REVIEWER is the formal gate.

**Status:** Canonical for security constraints. These are the safety rules that
`core-directives.md`'s **Instruction Precedence** chain places above every level of the
chain: no handoff, role file, or workflow step can authorize violating one. Where another
doc appears to relax an invariant here, that doc is wrong — follow this file and report
the conflict as a BLOCKER in `result.issues`.

**Why this file exists now, before S1 lands.** R-Co's own history
(`docs/agents/instructions/security-invariants.md` in R-Co) shows tenant-isolation bugs
shipped and recurred *twice* before a security gate existed to catch them (schema-scoping
incidents GH #335/#338). Identity and multi-tenancy (S1) is the next stage after S0, and
"everything downstream is tenant-scoped" per `docs/migration/stage-1-identity.md` — so
this file is written now, ahead of S1 requirements being expanded, rather than bolted on
after the first incident.

**Status of INV-1's mechanism (updated 2026-08-17, ISS-0026/GH#84): decided, not
provisional.** `docs/migration/decisions/0003-ecto-schema-strategy.md` (REQ-012) is
`decided` — Dimension B chose schema-per-tenant (Ecto `:prefix`/dynamic-repo
query-prefixing) with `tenant_id` retained inside each schema as an intra-schema
invariant, not a `tenant_id`-predicate-on-shared-tables or database-per-tenant
approach. S1 (identity/tenancy) is done and S2 migrations exist (REQ-022's
`Letflow.TenantProvisioning`, REQ-023's event-store tables, REQ-027's
`process_definitions`) — INV-1's preconditions are met and it is checkable today. This
paragraph previously described 0003 as pending and left the mechanism unnamed; both
were stale by the time REQ-023 landed (three consecutive SECURITY-REVIEWER passes —
REQ-023, REQ-024, REQ-027 — caught the staleness themselves and applied INV-1 anyway;
see ISS-0026 for the full history of that gap).

---

## How to read this file

Each invariant has: **Rule**, **Reference** (what enforces it today — several have none
yet, stated plainly), **How to verify**, **Severity** (all BLOCKER — there is no
MAJOR/MINOR tier for cross-tenant data exposure or secret leakage on a multi-tenant
platform).

---

## INV-1 — Tenant data isolation

**Rule.** Every access to tenant business data is scoped to exactly one tenant, with no
exception for internal, admin, or system-worker paths. Per
`docs/migration/decisions/0003-ecto-schema-strategy.md` Dimension B, the scoping
mechanism is schema-per-tenant (Ecto `:prefix`); a query that reaches business data
without going through `:prefix`-scoping is a cross-tenant leak.

**Reference.** `docs/migration/decisions/0003-ecto-schema-strategy.md` Dimension B
(schema-per-tenant via Ecto `:prefix`, `tenant_id` retained intra-schema) and its
2026-08-17 addendum (who populates `tenant_id` at write time). `Letflow.TenantProvisioning`
(REQ-022) is the concrete provisioning/schema-name mechanism. MVP-1's schema (REQ-102)
remains explicitly single-tenant and out of scope for this invariant per its own
moduledoc.

**How to verify.** Checkable now (0003 decided, S2 migrations exist). For every new or
changed Ecto schema module or migration touching a business table: (a) confirm queries
against it are scoped through `:prefix` (a `Repo.*(query, prefix: schema_name)` call, a
`prefix/1` callback, or equivalent dynamic-repo wiring) rather than the default/public
schema; (b) confirm the migration doesn't create the table reachable outside that
mechanism (i.e. not silently left in `public` when it should be tenant-scoped); (c) if
the table carries a `tenant_id` column, confirm it is derived from the resolved
`:prefix` at write time (per 0003's addendum), not accepted as a separate
caller-supplied field — a caller-supplied value can disagree with the schema it's
written into, which is the attribution defect 0003's addendum exists to close. Until an
automated check exists, this is a manual per-migration/per-module review — note
explicitly in the SECURITY-REVIEWER handoff which of (a)/(b)/(c) applied and how each
was confirmed.

**Severity.** BLOCKER (applies now — S1 is done, S2 migrations exist).

---

## INV-2 — Server-side field authorisation

**Rule.** Field-level visibility is enforced by the server (the Elixir API layer)
before a response is serialised. **No client is ever the authorisation boundary** —
not `web/`, and not the mobile tier specified in `docs/mobile/`. A client may hide
fields for UX reasons, but an unauthorised field must never leave the server in the
first place.

This matters more now than when this invariant was written: as of 2026-08-21 Letflow
owns `web/` outright and has a second client specified (S9). Two clients consuming one
contract makes "the UI filters it" a doubly wrong answer — a field the server should
not emit would have to be independently suppressed in TypeScript *and* in Dart, and one
of them will eventually miss it.

**Reference.** Updated 2026-09-25 (ISS-0830) — S4 landed and this is now the
established, load-bearing convention across nearly every tenant-data router, not a
future concern: `lib/letflow/routers/audit.ex`'s `page_body/2`/`audit_item/1`,
`lib/letflow/routers/identity.ex`'s `user_map/1`/`group_map/1`,
`lib/letflow/routers/tenant_config.ex`, `lib/letflow/routers/webhooks.ex`'s
`subscription_json/1`, `lib/letflow/routers/dlq.ex`'s `dlq_entry_json/1`,
`lib/letflow/routers/definitions.ex`'s `definition_map/1`,
`lib/letflow/routers/tenants.ex`, `lib/letflow/routers/services.ex`,
`lib/letflow/routers/admin_services.ex`, `lib/letflow/routers/solution_packs.ex`,
`lib/letflow/routers/promotions.ex`, `lib/letflow/routers/mobile_tenant_config.ex`,
`lib/letflow/routers/onboarding.ex` — all hand-build an explicit allowlist map
(never a bare `Jason.Encoder` derive or `Map.from_struct` pass-through) and most cite
`INV-2` by name in a `# ── Response allowlist (INV-2) ──`-style comment.

**How to verify.** For any new or changed API response type touching tenant-scoped
data, trace the controller/plug function and confirm field selection happens before
serialisation (an explicit map-building function like the ones cited above), never as
a post-hoc redaction on a client-visible struct. `grep -rn "INV-2" lib/letflow/routers/`
finds the established convention's own citations as a starting point for what "correct"
looks like on this codebase.

**Severity.** BLOCKER.

---

## INV-3 — Untrusted runtime sandboxing

**Rule.** Tenant-authored scripts (Lua service-task scripting, WASM plugins — S5) run
only inside a sandbox gated by an explicit host-capability allowlist. No ambient
network or filesystem access; no host function reachable unless the script's granted
capability set names it.

**Reference.** Updated 2026-09-25 (ISS-0830) — S5 landed (28 requirements, 27 `done`,
1 `cancelled`, 0 pending as of this update) with exactly the capability-gated model
this invariant describes: `lib/letflow/engine/lua/capabilities.ex` (REQ-157) gates
every `platform.*` host function a Lua service-task script can call before doing any
work; `lib/letflow/engine/wasm/capability_gate.ex` (REQ-167) enforces an import
allowlist where a guest importing anything outside it fails at **instantiation**, not
at call time; `lib/letflow/engine/wasm/host_api.ex` (REQ-172) is the bound host-API
surface itself. `docs/migration/stage-5-scripting-plugins.md`'s own header text is
separately stale in the same way and should be corrected alongside this file.

**How to verify.** For any new Lua/WASM host function or capability, confirm it is
unreachable unless the script's granted capability set names it (trace the call
through `capabilities.ex`/`capability_gate.ex`'s allowlist check) — no ambient access
path that bypasses the gate.

**Severity.** BLOCKER.

---

## INV-4 — Secrets by reference only

**Rule.** Secret material (API keys, webhook signing keys, OIDC client secrets,
database URLs) is never logged, traced, included in error messages, or serialised into
any payload — API response, audit record, webhook body, or **handoff file**. Code that
needs a secret resolves it at the point of use from environment/config
(`System.get_env/1`, `config/runtime.exs`), never threading the resolved plaintext
through a return value, log call, or struct field that could be serialised.

**Reference.** `config/dev.exs`'s bearer-token pattern (REQ-103) is the first concrete
instance — the token is read from config/env per its own acceptance criteria, not
hardcoded as a literal.

**How to verify.** (Both commands fixed 2026-08-17, ISS-0018/GH#74 — the file-glob fix
alone was found necessary but not sufficient by a second reviewer pass; see that issue's
UPDATE for the full history. Two independent defects, both now fixed: `--include=*.ex`
alone cannot match anything under `config/`, since every file there is `.exs`; and the
pattern was anchored on `=` assignment while Elixir config sets values in keyword form
(`password: "..."`), which `=` can never match regardless of which files are searched.)
```bash
grep -rn "System.get_env" config/ lib/ --include=*.ex --include=*.exs   # confirms env-sourced, not hardcoded
grep -rniE "(password|secret|client_secret|token)\s*(=|:)\s*\"[^\"]{8,}" lib/ config/ --include=*.ex --include=*.exs
```
The second grep is a heuristic, not a complete check — SECURITY-REVIEWER must manually
confirm any hit is genuinely a hardcoded secret vs. a config key name or test fixture.
**Applies now** — this is the one invariant already relevant at MVP-1/S0 scale, since
REQ-103's bearer token exists today.

**Severity.** BLOCKER.

---

## INV-5 — Not-found/forbidden indistinguishability

**Rule.** A cross-tenant probe against a resource that exists (but belongs to another
tenant) returns a response indistinguishable from probing a resource that never
existed — same status code, same body shape, no timing signal that lets a prober
distinguish "exists, not yours" from "never existed."

**Reference.** Updated 2026-09-25 (ISS-0830) — S4 landed, and this invariant is not
merely applicable but structurally discharged once, at the source, rather than
re-implemented per handler: REQ-072 ("tenant-scoped request context and the
cross-tenant 404 mechanism," `status: done`) derives the Ecto `:prefix` server-side
from `conn.assigns[:auth_context][:tenant_id]`, never from caller-supplied input, so a
cross-tenant lookup finds nothing in the caller's own schema by construction — the
same 404 a never-existed resource would produce. Concrete call sites:
`lib/letflow/instances.ex:338` `ensure_instance_exists/2`, `lib/letflow/tasks.ex:249`
`get_task/2`, `lib/letflow/routers/entities.ex`'s `## INV-5 — not-found and
cross-tenant are the same bytes` section, `lib/letflow/routers/exam_sessions.ex`'s
`:session_not_found`/`:not_owner` collapse, and the same `## Cross-tenant-404 (AC3,
INV-5)` convention repeated in `dlq.ex`, `webhooks.ex`, `solution_packs.ex`,
`onboarding.ex`, `help.ex`, `tenant_config.ex`. `lib/letflow/api/pagination.ex` and
`lib/letflow/entities/query/cursor.ex` also cite it as a structural (opaque-cursor)
guarantee.

**How to verify.** For any new lookup-by-ID endpoint resolving tenant-scoped
resources, confirm the query's tenant scoping is server-derived (never caller-supplied)
and that the not-found and forbidden-cross-tenant code paths return byte-identical
responses with a comparable number of DB round-trips (a cross-tenant existence check
that short-circuits earlier than an equivalent not-found check is itself a timing
signal). `grep -rn "INV-5" lib/letflow/` surfaces the established convention.

**Severity.** BLOCKER.

---

## INV-6 — New data-access paths prove their scoping

**Rule.** Every new data-access path (a new API route, a new Lua/WASM host function
touching tenant data, a new migration introducing a business table) must demonstrate
its tenant scoping to SECURITY-REVIEWER before it merges. "It compiles and the
happy-path test passes" is not proof of scoping — the proof is an explicit statement of
which invariant(s) apply and how the implementation satisfies each.

**Reference.** This is the meta-invariant `SECURITY-REVIEWER`
(`.claude/agents/security-reviewer.md`) exists to enforce — inserted into WF-02 after
implementation, before TEST-DESIGNER. See `docs/agents/workflows/WF-02_requirement_implementation.md`
Step 2c.

**How to verify.** A SECURITY-REVIEWER handoff exists for the change, `status: PASS`,
and its result explicitly lists which of INV-1..INV-8 were assessed and why each
either applies-and-is-satisfied or does-not-apply.

**Severity.** BLOCKER.

---

## INV-7 — No SQL string interpolation

**Rule.** All SQL uses parameterised placeholders via Ecto's query API
(`Ecto.Query`, `Ecto.Adapters.SQL.query/3` with `$1`/`?` bind params). Tenant- or
user-controlled data is never interpolated directly into a raw SQL string (`Repo.query!`
built via `<>` string concatenation or `"#{...}"` interpolation with untrusted input).

**Reference.** `docs/guides/backend_developer_guide.md` — Ecto's `Ecto.Query` macro and
`from/2` composition are parameterised by construction; the risk surface is
`Ecto.Adapters.SQL.query/3` / `Repo.query/3` raw-SQL escape hatches, which every
migration and any hand-written analytics query should avoid unless genuinely necessary.

**How to verify.**
```bash
grep -rn "Repo.query" lib/ priv/repo/migrations/ --include=*.ex --include=*.exs
```
Every hit must be manually confirmed to use bound parameters (`Repo.query(sql, [params])`)
rather than string-built SQL. **Applies now** — Ecto is already in use.

**Severity.** BLOCKER.

---

## INV-8 — No unhandled crashes on realistic failure paths

**Rule.** Error handling uses typed results (`{:ok, _} | {:error, _}`, tagged tuples,
or `with` chains) for any path that touches external I/O, tenant-controlled data, or
network input. A bare pattern match that can raise on realistic input (e.g. matching
`{:ok, x} = some_external_call()` where the call can legitimately fail) is a defect on
a multi-tenant platform — one tenant's malformed input crashing a shared process can
degrade other tenants' in-flight work. Where OTP's own let-it-crash philosophy is the
deliberate choice for a genuinely isolated, supervised process, that is not a
violation of this invariant — the distinction is between "let a doomed, isolated
process crash and restart under supervision" (fine, idiomatic) and "let an unhandled
crash inside a shared process take down unrelated tenants' work" (not fine).

**Reference.** Updated 2026-09-25 (ISS-0830) — this previously cited
`lib/letflow/process_instance.ex`, a module that no longer exists: REQ-045/046
explicitly retired the per-instance supervised-process model in favor of
`Letflow.Engine.create/2`, a transactional context module with Postgres row-locking as
the actual isolation mechanism (see `Letflow.Engine`'s own moduledoc, "Process-vs-row
decision," and CLAUDE.md's summary of the same). `Letflow.InstanceSupervisor` exists
but is deliberately empty — there is no per-instance process to isolate a crash to.
The real architectural answer for this invariant today is row-level locking plus typed
error handling at each transactional boundary, verified by
`test/letflow/engine_concurrency_test.exs` (REQ-055) — a crash inside one tenant's
`Engine.create/2` call rolls back that transaction without taking down a shared
process another tenant depends on, because there is no long-lived shared process in
the request path to take down.

**How to verify.**
```bash
grep -rn "^\s*{:ok, .*} = " lib/letflow/ --include=*.ex
```
A heuristic, not complete — SECURITY-REVIEWER/REVIEWER must manually confirm any hit on
a path reachable from external I/O, tenant input, or network data (vs. a genuinely
unreachable-otherwise case, e.g. immediately after a value the same function already
validated).

**Severity.** BLOCKER.

---

## Applicability note

**Updated 2026-08-17 (ISS-0026/GH#84) — INV-1 moved from "not yet applicable" to "live
now."** At that time INV-2, INV-3, INV-5 were still correctly NOT-APPLICABLE — S4/S5
genuinely had not started — and INV-1 was checked out of that group because S1/S2 had
already landed.

**Updated 2026-09-25 (ISS-0830) — INV-2, INV-3, INV-5 also moved out of the
NOT-APPLICABLE group; there is no invariant left in it.** S4 and S5 have both since
landed (S4: REQ-065/070/071/072/078/084 `done`; S5: 27 of 28 requirements `done`, one
`cancelled`, zero `pending`), and the stale "not started" text on INV-2/3/5 was not
merely cosmetic — a reviewer following this file literally would have skipped all
three on exactly the tenant-data-path and scripting/plugin changes they exist to
cover. Do not assume a NOT-APPLICABLE grouping is still accurate without checking
`docs/requirements.yaml` for the stage it names — this is the second time this exact
staleness shape has recurred (first INV-1 in 2026-08-17, now three more invariants at
once); check every invariant's Reference against real requirement/stage status before
trusting it, rather than assuming this file stays current on its own.

INV-1, INV-2, INV-4, INV-5, INV-7, INV-8 apply today, checkable per-diff via
SECURITY-REVIEWER's scope test (see its role file). INV-3 applies today for any
Lua/WASM host-capability change. INV-9 applies now (REQ-204 shipped).

## Rate limiting — current position (ISS-0826/GH#1819)

**There is no per-actor rate limit on authenticated routes.** `Letflow.Plugs.PublicReadRateLimit`
is mounted only on `Letflow.Routers.PublicRead` (unauthenticated traffic). Authenticated
traffic is bounded by `Letflow.Plugs.Admission` (concurrency, not rate).

This is a deliberate, recorded decision — see
`docs/migration/decisions/0040-authenticated-route-rate-limiting.md` for the full
rationale and the S4 plan. Per-actor rate limiting (`Letflow.Plugs.RateLimit`) is
explicitly deferred to S4. A SECURITY-REVIEWER assessing a change that could
amplify sequential request volume should cite decision 0040 rather than treating the
current absence as unexamined.

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
- fe80::/10 — IPv6 link-local (REVIEWER-approved, OQ-1 — same attack class as 169.254.0.0/16)
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
