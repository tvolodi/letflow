# Security Invariants — Letflow

**Audience:** every agent in the pipeline. Canonical location for Letflow's hard
security constraints. `SECURITY-REVIEWER` gates against this exact list; every other
role that touches tenant-scoped data (ELIXIR-DEV, FRONTEND-DEV, ISSUE-FIXER) must know
these exist even though only SECURITY-REVIEWER is the formal gate.

**Status:** AUTHORITATIVE for security constraints. Where this file and any other doc
disagree, this file wins.

**Why this file exists now, before S1 lands.** R-Co's own history
(`docs/agents/instructions/security-invariants.md` in R-Co) shows tenant-isolation bugs
shipped and recurred *twice* before a security gate existed to catch them (schema-scoping
incidents GH #335/#338). Identity and multi-tenancy (S1) is the next stage after S0, and
"everything downstream is tenant-scoped" per `docs/migration/stage-1-identity.md` — so
this file is written now, ahead of S1 requirements being expanded, rather than bolted on
after the first incident.

**Provisional status of INV-1's mechanism.** Letflow has not yet decided *how*
multi-tenancy is represented at the schema level —
`docs/migration/decisions/0003-ecto-schema-strategy.md` (REQ-012) is still pending, and
it may choose schema-per-tenant (R-Co's approach), a `tenant_id` row predicate on shared
tables, or database-per-tenant. INV-1 below is written to hold under any of the three;
its "How to verify" section names the concrete check to write once REQ-012 lands and the
mechanism is chosen, without assuming which one wins in advance.

---

## How to read this file

Each invariant has: **Rule**, **Reference** (what enforces it today — several have none
yet, stated plainly), **How to verify**, **Severity** (all BLOCKER — there is no
MAJOR/MINOR tier for cross-tenant data exposure or secret leakage on a multi-tenant
platform).

---

## INV-1 — Tenant data isolation

**Rule.** Every access to tenant business data is scoped to exactly one tenant, with no
exception for internal, admin, or system-worker paths. Regardless of which mechanism
`docs/migration/decisions/0003-ecto-schema-strategy.md` settles on (schema-per-tenant,
`tenant_id` predicate, or database-per-tenant), a query that reaches business data
without going through that mechanism's scoping is a cross-tenant leak.

**Reference.** None yet — S1 (identity/tenancy) has not started; MVP-1's schema
(REQ-102) is explicitly single-tenant and out of scope for this invariant per its own
moduledoc.

**How to verify.** Not yet checkable — becomes checkable once 0003 lands and S2/S3
migrations exist. When it does: SECURITY-REVIEWER must confirm every new Ecto schema
module either (a) scopes its queries through the chosen tenancy mechanism (a Postgres
`search_path` set per-connection, a `tenant_id` clause enforced via an Ecto query
prefix/callback, or a distinct Repo per tenant), and (b) that no migration creates a
business table reachable outside that mechanism. Until an automated check exists, this
is a manual per-migration review — note explicitly in the SECURITY-REVIEWER handoff
whether one was possible or not.

**Severity.** BLOCKER (once S1/S2 land — not yet applicable to MVP-1-scoped or S0 work).

---

## INV-2 — Server-side field authorisation

**Rule.** Field-level visibility is enforced by the server (the Elixir API layer)
before a response is serialised. `web/` (or whatever S8 settles on as the frontend
integration surface) is never the authorisation boundary — it may hide fields for UX
reasons, but an unauthorised field must never leave the server in the first place.

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

**How to verify.**
```bash
grep -rn "System.get_env" config/ lib/ --include=*.ex   # confirms env-sourced, not hardcoded
grep -rniE "(password|secret|client_secret|token)\s*=\s*\"[^\"]{8,}" lib/ config/ --include=*.ex
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

INV-1, INV-2, INV-3, INV-5 are written for stages (S1, S4, S5) that have not started —
they exist now so the language is settled before the first requirement that needs them,
per this file's opening rationale. SECURITY-REVIEWER's scope test (see its role file)
determines which invariants apply to a given diff; an invariant whose stage hasn't
started is automatically NOT-APPLICABLE, not a blocker. INV-4, INV-7, INV-8 apply today.
