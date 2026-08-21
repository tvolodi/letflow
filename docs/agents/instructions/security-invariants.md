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

**Reference.** None yet — no multi-tenant API surface exists (S4 not started).

**How to verify.** Manual, once applicable: for any new or changed API response type
touching tenant-scoped data, trace the controller/plug function and confirm field
selection happens before serialisation (`Jason.Encoder` derivation, view module, or
explicit map-building), never as a post-hoc redaction on a client-visible struct.

**Severity.** BLOCKER (once S4 lands).

---

## INV-3 — Untrusted runtime sandboxing

**Rule.** Tenant-authored scripts (Lua service-task scripting, WASM plugins — S5) run
only inside a sandbox gated by an explicit host-capability allowlist. No ambient
network or filesystem access; no host function reachable unless the script's granted
capability set names it.

**Reference.** None yet — S5 (scripting/plugins) has not started, and per
`docs/migration/stage-5-scripting-plugins.md` needs its own build-vs-bind decision
record before this invariant becomes concrete (NIF/Port capability boundaries look
different from R-Co's in-process Zig sandbox).

**How to verify.** Deferred until S5's decision record exists.

**Severity.** BLOCKER (once S5 lands).

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

**Reference.** None yet — no multi-tenant lookup-by-ID endpoints exist (S4 not
started).

**How to verify.** Deferred until S4. Once applicable: SECURITY-REVIEWER confirms, for
any lookup-by-ID endpoint resolving tenant-scoped resources, that the not-found and
forbidden-cross-tenant code paths return byte-identical responses and take a comparable
number of DB round-trips (a cross-tenant existence check that short-circuits earlier
than an equivalent not-found check is itself a timing signal).

**Severity.** BLOCKER (once S4 lands).

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
a multi-tenant platform — one tenant's malformed input crashing a shared process
(unless deliberately isolated, per `Letflow.ProcessInstance`'s one-process-per-instance
model) can degrade other tenants' in-flight work. Where OTP's own let-it-crash
philosophy is the deliberate choice (a supervised, per-instance process that should
restart clean on genuinely unexpected state), that is not a violation of this invariant
— the distinction is between "let a doomed process crash and restart under supervision"
(fine, idiomatic) and "let an unhandled crash inside a shared process take down
unrelated tenants' work" (not fine).

**Reference.** `lib/letflow/process_instance.ex`'s per-instance `:gen_statem` isolation
is the existing architectural answer to this for engine state — REVIEWER already checks
supervision integrity for this reason (see `.claude/agents/reviewer.md`).

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
now."** INV-2, INV-3, INV-5 are still written for stages (S4, S5) that have not
started — they exist now so the language is settled before the first requirement that
needs them, per this file's opening rationale, and remain automatically NOT-APPLICABLE
until those stages begin. INV-1 no longer belongs in that group: S1 is done and S2
migrations exist, so it is checkable on any diff touching a tenant-scoped table,
schema, or migration — SECURITY-REVIEWER's scope test (see its role file) determines
applicability per diff, same mechanism as always, but INV-1 is now a live invariant to
run that test against, not a default skip. INV-1, INV-4, INV-7, INV-8 apply today.
