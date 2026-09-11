# 0022 — BilimBaga is Letflow's first vertical: a solution pack plus a bounded runtime, not a fork

Status: decided (2026-09-09, user-directed). Owner: `ORCH` (stage S10).

## Question

`c:\Users\tvolo\dev\BilimBaga\` is a working corporate exam platform for
organizations — multilingual question banks, configurable timed sessions,
auto-grading, certificates with QR verification, analytics, tenant branding, and
AI-assisted authoring. As of 2026-09-09 it is a Go 1.25 / Chi / `sqlx`
application over PostgreSQL 16 (30 numbered migration pairs, `001_init` …
`030_reset_admin_password`; 25 packages under `backend/internal/`, of which 19
are domain packages and six — `api`, `router`, `db`, `config`, `ctxkeys`,
`health` — are infrastructure), a React 19 + TypeScript + Vite 6 + Tailwind 4
SPA under `frontend/`, and a Playwright suite of 19 spec files carrying 168
`test()` blocks. It has its own agent pipeline
(`.github/agents/`, `.claude/commands/`) with an Orchestrator, a Business
Analyst, and a UAT Runner.

The user asked how to build BilimBaga **on the basis of Letflow**. That admits
three readings, and they are not variations on a theme — they produce three
different systems:

1. **Fork.** Copy Letflow, strip what exams don't need, add what they do.
2. **Federate.** Keep the Go backend; call Letflow for workflow, and let each
   system own part of the data.
3. **Vertical.** BilimBaga stops being an application and becomes a *tenant-level
   solution on Letflow* — definitions installed into a tenant, plus the small
   amount of Elixir that no definition can express.

## Decision

**(3), the vertical.** Concretely:

- BilimBaga is delivered as **one Letflow tenant** plus **one
  `Letflow.Definitions.SolutionPack` document** plus **a bounded runtime domain**
  under `lib/letflow/exam/`, with its client screens in `web/`.
- **The Go backend is discarded, not ported.** `backend/internal/{sessions,
  certificates, reports, ai, email, portal, upload}` are rewrites; `{auth, rbac,
  audit, tenant, ratelimit, middleware, db, config, ctxkeys}` are deleted
  outright, because Letflow already has each of them and having two is worse than
  having one.
- **BilimBaga's repository becomes provenance**, in the exact sense R-Co is
  provenance for Letflow (`README.md`, "Migration status"): it is the port source
  and the reference implementation, cited by path, and it is not where work
  happens after S10 starts.
- **One pipeline.** BilimBaga's own Orchestrator and agent set are retired in
  favour of Letflow's roster (`docs/agents/AGENT_SYSTEM.md`). BilimBaga's
  Business Analyst role has no Letflow counterpart and does not acquire one —
  `REQ-ANALYST` already owns "turn a business ask into a sized, testable
  requirement", which is that role's job under a different name.

## The bucket rule

This is the operative half of the decision — the part later requirements are
gated against. **Every S10 requirement declares exactly one bucket in its
`description`.**

| Bucket | What it is | Where it lands | Who builds it |
|---|---|---|---|
| **A** | Pure definitions — no Elixir, no TypeScript. Entity definitions, process definitions, form schemas, role-registry seeds, Lua grading rules. | a solution-pack document, installed via `Letflow.Definitions.SolutionPack.install/3` | `REQ-ANALYST` + `CODE-DESIGNER` |
| **B** | Generic platform capability Letflow lacks. Tenant-agnostic, useful to any vertical. | `lib/letflow/`, `web/` | the normal roster |
| **C** | Genuinely exam-specific runtime that no definition can express. | `lib/letflow/exam/`, `web/src/pages/exam/` | `ELIXIR-DEV` / `FRONTEND-DEV` |

Three rules bind the buckets, and they exist because the failure mode of a
"platform + first vertical" project is always the same one — the vertical's shape
leaks into the platform, and the platform quietly becomes an exam engine:

1. **A bucket-B requirement may not name exams.** Not in its title, not in its
   acceptance criteria, not in the module it produces. If a capability cannot be
   stated without saying "question" or "exam", it is not bucket B — it is C, and
   it goes in `lib/letflow/exam/`.
2. **Bucket C requires `REVIEWER` sign-off that A and B were tried first.** The
   sign-off states, in one sentence each, why the behaviour is not expressible as
   a definition and not generalisable as a platform capability. `REVIEWER`
   already gates scope creep (`CLAUDE.md`'s roster table); this is that gate
   applied in the one direction S10 can fail in.
3. **Bucket C stays small, and "small" is measured.** The stage file carries a
   running inventory of `lib/letflow/exam/`. Growth there is the stage's primary
   health metric, not a neutral fact.

## Reasoning

**1. Most of BilimBaga is already built, in Letflow, generically.** This is not an
estimate — it is a mapping against modules that exist today:

| BilimBaga | Letflow mechanism | Bucket |
|---|---|---|
| `auth`, `rbac`, `users`, `tenant`, `middleware`, `ratelimit` | `Letflow.Identity` + `Letflow.Identity.RoleRegistry` + Keycloak OIDC (decision 0002) + `Letflow.Plugs.ApiPipeline` + schema-per-tenant (decisions 0003/0006) | — (delete) |
| `audit` | `Letflow.Audit` + `Letflow.EventStore` | — (delete) |
| `categories`, `tags`, `departments`, `exams` (config), `exam_assignments` | `Letflow.Entities.Definition` documents + `Letflow.Entities.Records` (event-sourced) + `Letflow.Entities.Record.Projector` | A |
| `questions` (five related tables, per-locale rows) | the same, **but not as the entity subsystem stands** — see REVIEWER amendment below | **B, then A** |
| hiding correct answers from a candidate's response | `Letflow.Entities.Query.FieldGrants` — field-level redaction, already built (REQ-231) | A |
| multilingual content (kk/ru/en) | per-locale map fields in the entity definition — `:json`, therefore **not queryable** under Validator Rule 3 | **B, then A** |
| exam lifecycle: assign → notify → take → grade → certify → expire | a process definition on `Letflow.Engine`; manual grading is a user task with `form_schema` | A |
| auto-grading rules | sandboxed Lua (`lib/letflow/engine/lua/`, decision 0014) — grading logic ships *in the pack* | A |
| versioning, promotion, packaging, export/import of all of the above | `Letflow.Definitions.{Promotion,SnapshotStore,ExportImport,SolutionPack}` | free |

BilimBaga hand-wrote each of these against its own 30-migration schema. Under
Letflow **most** of them are configuration of subsystems that already pass their
own gates, under a tenant-isolation invariant (INV-1) that `SECURITY-REVIEWER`
enforces on every write path. Two rows are not — they need bucket-B platform work
before they can become definitions, and the REVIEWER amendment below states
which and why. The second vertical after BilimBaga costs a fraction of the first;
that is the entire argument for a platform, and S10 is where it either holds or
doesn't.

**2. A fork loses the shared gate, which is this project's whole premise.** This
is decision 0011's reasoning §3 applied unchanged: a change made in a fork passes
the fork's gates, not Letflow's. `decisions/0004-humanless-pipeline.md` rests on
every producing step having a validating step *in one repository, with one
roster*. Two Letflows means two pipelines and, in practice, "whichever repo the
agent has open." A fork also converts every later Letflow improvement into a
merge conflict, permanently.

**3. Federation splits tenant isolation across two codebases.** Reading (2) is
superficially the cheapest — the Go app already works. But it puts identity in
two systems, audit in two systems, and tenant scoping on both sides of an HTTP
boundary. `docs/agents/instructions/security-invariants.md`'s INV-1 is checkable
by `SECURITY-REVIEWER` precisely because every tenant-scoped read and write in
Letflow passes an explicit `prefix`. Half the data living behind a Go service
that does its own scoping makes the invariant unauditable in the place it is
enforced. That is a security regression traded for a schedule saving.

**4. It makes `docs/migration/README.md`'s forward note testable.** That note
records a second application of the agent-pipeline principles: end-users'
business-process requirements designed, built, and deployed by agents *at
runtime*. It is explicitly not being built now, and S10 does not build it. What
S10 does is supply the missing evidence for its premise — that Letflow's engine
can host a real business domain end-to-end. If BilimBaga cannot be expressed
mostly as definitions, runtime agent-driven process design is not close, and it
is far better to learn that from a vertical that has a working reference
implementation to diff against than from a green-field one.

**5. The cost is real and is stated here rather than discovered later.** Roughly
seven Go packages are rewritten with no line-level port path, the analytics tier
has nothing to sit on today (gap 2 in the stage file), and thirteen platform gaps
must close before bucket-A work can start (nine as first filed, three added by
this record's REVIEWER sign-off, and a thirteenth — the pack format itself —
found by the follow-on architecture review that produced decision 0023). The offsetting fact is that
BilimBaga's 19 live Playwright spec files (168 `test()` blocks) are a
ready-made, independent acceptance
corpus — S10 does not have to invent its own definition of parity, and
`RELEASE-VALIDATOR` can re-derive it rather than trust it.

## What this record does not decide

- **No framework or stack re-decisions.** 0001 (Plug/Bandit, no Phoenix), 0003
  (Ecto schema strategy), 0011 (React SPA), 0012 (Flutter tier), and 0014
  (Lua/WASM scripting) all stand unchanged. S10 introduces no new runtime
  language and no new client framework. BilimBaga's Go does not come with it,
  and neither does its own component layer: `web/`'s design system (0020) is
  what its screens are built from. (BilimBaga's `frontend/` is Tailwind 4 with
  hand-rolled components; earlier drafts of this record called it shadcn/ui,
  which its `package.json` does not carry.)
- **The exam session is not a process instance, and not a supervised process.**
  Stated here so it cannot be quietly re-decided. `REQ-045` and
  `Letflow.Engine`'s "Process-vs-row decision" settled the running-instance shape
  as a plain transactional context module with concurrency arbitrated by Postgres
  row locks, and `Letflow.InstanceSupervisor` is deliberately empty. A live timed
  exam session is a *higher*-write version of the same case (autosave,
  per-question scoring, anti-cheat events), so it strengthens that conclusion
  rather than reopening it. Any S10 design proposing a process or a `gen_statem`
  per candidate session is rejected at the `CODE-DESIGN-VALIDATOR` gate against
  this paragraph.
- **The mechanism for email, PDF and QR is left to its own requirement.** The
  recommendation on record — a `service_catalog` entry dispatched through
  `Letflow.Engine.ServiceTaskDispatcher` (HTTP, SSRF-gated) to an external relay
  and renderer, rather than adding a mailer and a PDF library to core — is a
  recommendation, not a ratified decision. It keeps bucket B free of a rendering
  dependency, but it trades an in-process call for an operational dependency, and
  that trade deserves its own design and its own gate.
- **Data migration is conditional and unscoped here.** Whether existing rows in
  BilimBaga's PostgreSQL are imported into entity records (phase P6 in the stage
  file) depends on whether any deployment holds real data. If none does, the
  importer is never built.
- **Nothing about BilimBaga's repository changes.** No deletion, no rewrite, no
  archival. It is read-only provenance from S10's start, exactly as R-Co is.

## Consequences

- **S10 is added** to `docs/requirements.yaml`'s `stages:` list
  (`depends_on: [S4, S6, S8]`) with detail file
  [`../stage-10-bilimbaga-vertical.md`](../stage-10-bilimbaga-vertical.md), and to
  `docs/migration/README.md`'s stage index. S10 is the second stage that ports no
  R-Co source (S9 is the first) — it lives in `docs/migration/` by naming
  convention only, and that directory's framing as a *historical* record does not
  extend to it.
- **Thirteen platform gaps become bucket-B requirements**, filed and closed before any
  bucket-A pack work begins. The full table — what is already filed (`REQ-281`–
  `REQ-286`, `REQ-291`–`REQ-293`) and what is not (an entity-records HTTP
  surface; an aggregation query surface; attachments beyond `instance_attachments`;
  email/PDF/QR; a public verification route) — is in the stage file.
- **`Letflow.Routers.Entities` acquires an owner.** `lib/letflow/router.ex`'s
  deferred-routes table lists it against "S5/S6 (entity/data-model subsystem)",
  but `REQ-225`–`REQ-231` built the entities subsystem *without* a route surface,
  and no requirement currently owns one. S10 cannot start without it; the stage
  file names it as gap 1.
- **The agent roster does not grow.** No exam-domain role, no Business Analyst. If
  S10 shows a genuine gap in the roster, that is its own decision record.
- **`docs/anti-patterns.md` gains S10's first entry when the first bucket
  violation is caught** — "expressed as `lib/` code what the platform can express
  as a definition" is the mistake this stage is most likely to make repeatedly.

## REVIEWER sign-off

**PASS on the decision, with a recorded disagreement on reasoning §1's cost
model (2026-09-09, `REVIEWER`).**

The decision itself — vertical, not fork, not federation — stands as written, and
§2 and §3 are correct as derived. §2 applies 0011 §3 unchanged; §3's point that
federation makes INV-1 unauditable in the place `SECURITY-REVIEWER` enforces it
is the strongest argument in the record. Nothing below reopens the choice.

What does not survive review is §1's claim that the mapped subsystems are
"already built, generically." Three of its rows were checked against the entity
subsystem's actual capability rather than its intent, and do not hold:

1. **The question bank is not expressible as an entity definition today.**
   `Letflow.Entities.Definition.field_type` is a closed set (`:string`,
   `:integer`, `:decimal`, `:boolean`, `:date`, `:datetime`, `:enum`, `:json`).
   BilimBaga's question model (`009_questions.up.sql`, `FR-BB22`) is five tables
   — `questions`, `question_translations`, `answer_options`,
   `answer_translations`, `question_tags`: two one-to-many relations and a
   many-to-many, with per-locale rows.

2. **Localized content becomes unqueryable.** §1's answer to multilingual
   content is "per-locale map fields," which means `:json`, and
   `Letflow.Entities.Definition.Validator`'s Rule 3
   (`queried_json_violations/1`, message `"a :json field cannot be queried:
   true"`) forbids a `:json` field from being `queried: true`. A question bank's
   primary screen is search and filter over stems. Marking this row A and free
   is wrong in a way that surfaces on the first admin screen.

3. **There are no joins, and foreign keys are declarative only.**
   `Letflow.Entities.Query.Compiler` contains no `join` or `preload` (the only
   `left_join` under `lib/letflow/entities/` is `FieldGrants`' own internal
   anti-join). `fk_def` exists in a definition, but `references_entity` is
   validated for shape and self-reference in
   `Letflow.Entities.Definition.Validator` only — there is no cross-entity
   referential enforcement at write time in `Letflow.Entities.Record.Validator`.
   Reading a question with its options and tags is a multi-entity read the query
   DSL cannot express in one query.

**Consequence for the stage, and the operative half of this sign-off.** P2's
exit condition as filed — a working question bank "and **zero** exam-specific
Elixir" — is unreachable on the current entity subsystem. The stage file says P2
is S10's real test and that failing it means §1 is wrong. That finding is
available now, from the code, rather than at P2: §1 is *partly* wrong already,
and the honest response is to move the work rather than to discover it late. The
two rows above are re-marked **B, then A** in §1's table.

Three gaps are therefore missing from the stage file's nine, and P1 is not
complete without them:

- **Gap 10 — relations between entity records.** One-to-many and many-to-many,
  with joined reads in the query DSL, and write-time referential enforcement to
  match the `fk_def` a definition already declares.
- **Gap 11 — queryable localized fields.** A localized-text field type that is
  filterable and sortable per locale, rather than `:json` under Rule 3. This is
  the platform-level counterpart of gap 8 (`REQ-285`, i18n in `web/`, which
  landed 2026-09-09) — that covers the client only, and closing it does not
  touch this.
- **Gap 12 — bulk import/export of entity records.** BilimBaga has `pg_trgm`-backed
  import/export (`011_pg_trgm_import_export`); `Letflow.Definitions.ExportImport`
  moves *definitions*, not records.

All three are bucket B by rule 1 — none of them needs to name an exam.

**Two further observations, not blocking.**

- **Reasoning §5 understates what is discarded.** `backend/internal/sessions/`
  is 997 lines of service, and it carries adaptive question selection
  (`SelectNextAdaptiveQuestion`, `026_adaptive_exam`) and short-text autograding
  (`027_short_text_autograding`). Neither appears in this record or the stage
  file. Adaptive sequencing in particular is not expressible as a static process
  definition and should be assumed bucket C when P3 is scoped.

- **The process-vs-row paragraph reaches the right answer via a weaker argument
  than the one available.** It calls a timed session "a *higher*-write version of
  the same case." `Letflow.Engine`'s moduledoc is narrower than that: REQ-045
  resolved the shape "for EE-01's own scope only" and explicitly allows that "the
  answer may legitimately differ for later engine subsystems." The stronger
  evidence is the reference implementation — BilimBaga runs no per-session
  process either; `SaveAnswer`/`SubmitSession` are plain transactional calls
  against `exam_sessions`, and the deadline is a stored `expires_at` column, not
  a live timer. The conclusion holds; the citation should be that, not the
  analogy.

Gate status: this record is **not** blocked. It is the stage's precondition and
may stand. What is blocked is expanding P2 into bucket-A requirements before
gaps 10, 11 and 13 close — a pack authored against the entity subsystem as it
stands today would fail at its first queryable localized field, and could not be
packaged at all.

**Amended the same day.** A follow-on architecture review found the cause
underneath gaps 10 and 11 — the shared-table/JSONB storage model — and resolved
it in [`0023-entity-storage-hybrid.md`](0023-entity-storage-hybrid.md), which
supersedes REQ-228's storage design and makes gaps 10 and 11 consequences of
itself rather than separate work. It also found gap 13: `SolutionPack`'s document
format has no `entity_definitions` section and no form-schema section, so bucket
A's own delivery vehicle cannot carry two of the four things bucket A consists
of. That is a more fundamental blocker on P2 than either gap this sign-off
originally raised.
