# Stage 10 — BilimBaga vertical

Status: P1 in progress. Depends on: S4, S6, S8. Requirements: `REQ-295`–`REQ-323`
filed (29 as of 2026-09-12); P2 onward not expanded yet.

Created 2026-09-09. See
[`decisions/0022-bilimbaga-vertical.md`](decisions/0022-bilimbaga-vertical.md)
for why this stage exists, why BilimBaga is a solution pack plus a bounded
runtime rather than a fork or a federated Go service, and for the **bucket rule**
(A = definitions, B = generic platform capability, C = exam-specific runtime)
that every requirement in this stage is gated against.

## Scope

Deliver BilimBaga — a corporate exam platform: multilingual question banks,
configurable timed sessions, auto-grading, certificates with QR verification,
analytics, tenant branding, AI-assisted authoring — as **one Letflow tenant, one
solution pack, and a bounded `lib/letflow/exam/` runtime**, with its screens in
`web/`.

The port source and reference implementation is `c:\Users\tvolo\dev\BilimBaga\`
(Go 1.25 / Chi / `sqlx` / PostgreSQL 16, React 19 SPA, 19 Playwright spec files
carrying 168 `test()` blocks). Its product specification is
`c:\Users\tvolo\dev\BilimBaga\corporate_exam_platform_roadmap.md`, which is
organised as `## Phase N` / `### N.M` sections and carries **no** requirement
identifiers of its own.

BilimBaga's requirement IDs are `FR-BB<phase><section>` — `FR-BB22` (question
model), `FR-BB35` (session creation), and so on — but they are **not defined in
the roadmap**. They appear only as citations: in migration headers
(`009_questions.up.sql`: "Migration 009: FR-BB22 — Question Model"), in Go
source, and in `.github/agents/`. 78 distinct IDs are in use, and the numbering
is not uniformly two-digit — `FR-BB001`, `FR-BB110`–`FR-BB114` and
`FR-BB310`–`FR-BB318` all occur.

So the citation rule is: **every S10 requirement that ports a BilimBaga
behaviour cites the `FR-BB` ID carried by the migration or package it ports
from**, the same way S1–S8 requirements cite an R-Co source path. Where no
`FR-BB` ID exists for a behaviour, cite the roadmap section (`§3.5`) instead.
Reconstructing a canonical `FR-BB` index is P0 work, not a precondition to it.

## This stage ports no R-Co source

Like S9, and unlike S1–S8, there is no R-Co directory behind this stage. It lives
in `docs/migration/` by naming convention only — the stage list, the `detail_file`
convention, and the decision-record directory all live here. This directory's
framing as a *historical build record* does not extend to S10 or S9.

Unlike S9, S10 does have a working implementation to port **from** — just not one
written in Elixir, and not one whose code transfers. What transfers is the domain
model, the requirement set, the UX, and the acceptance scenarios. The Go code
does not.

## The thirteen platform gaps

Verified against `lib/` and `web/` on 2026-09-09, and re-checked against `main`
at each rebase — the filed rows move quickly, so trust `docs/requirements.yaml`
over this column if they ever disagree. Gaps 10–12 were added by
`REVIEWER`'s sign-off on 0022 (see that record's amendment to reasoning §1).
**Every one of these is bucket B, and all of them close before any bucket-A pack
work begins** — a pack cannot be authored against a platform whose data-model
surface has no HTTP route, and no question bank can be authored against one with
no relations and no queryable localized fields.

| # | Gap | State on 2026-09-09 | Owner |
|---|---|---|---|
| 1 | **Entity-records HTTP surface.** `Letflow.Entities.{Definitions,Records}` and the query DSL exist (`REQ-225`–`REQ-231`); nothing routes to them. `lib/letflow/router.ex`'s deferred-routes table no longer lists `Letflow.Routers.Entities` — that row was retired once the router was mounted. | **Closed 2026-09-12** -- `REQ-308` `done` (design, `lib/letflow/design/req308-entity-http-surface.md`); `REQ-309`, `REQ-310`, `REQ-311` `done` (implementation: permission atoms, `lib/letflow/routers/entities.ex` with seventeen routes, mounted at `/entities` by `Letflow.Plugs.ApiPipeline`) | closed |
| 2 | **Aggregation / reporting queries.** `Letflow.Entities.Query.Compiler` compiles allowlisted filter/sort into an `Ecto.Query`; it has no `count`/`sum`/`group_by`. `/metrics` is Prometheus *ops* metrics (`REQ-194`), not a BI surface. BilimBaga's analytics dashboard has nothing to sit on. | **Closed 2026-09-11** -- `REQ-312` `done` (design, `lib/letflow/design/req312-query-aggregation.md`); `REQ-315` `done` (implementation, `POST /entities/query/aggregate`, PR #1276) | closed |
| 3 | **Attachments beyond instances.** `Letflow.Repository.Attachments` covers `instance_attachments` only. Question images and bulk import need attachments on an *entity record*. | **Closed 2026-09-12** -- `REQ-313` `done` (design, `lib/letflow/design/req313-entity-record-attachments.md`); `REQ-316` `done` (migration + context module, PR #1264) and `REQ-317` `done` (permission atoms + four routes, PR #1279) | closed |
| 4 | **Email.** No mailer, no SMTP dependency in `mix.exs` (still absent, re-verified 2026-09-12). Mechanism settled by [decision 0027](decisions/0027-solution-pack-service-catalog-install-policy.md): any needed `service_catalog` entry is provisioned out-of-band, via `POST /service-catalog` (gated `:AdminServicesManage`), not through a pack. The capability itself remains open and unowned. | **Open (capability).** Mechanism settled by 0027; still no mailer/SMTP dependency | to file |
| 5 | **PDF + QR rendering** for certificates. Absent (re-verified 2026-09-12: no PDF or QR dependency in `mix.exs`); same out-of-band mechanism as gap 4, settled by [decision 0027](decisions/0027-solution-pack-service-catalog-install-policy.md). The capability itself remains open and unowned. | **Open (capability).** Mechanism settled by 0027; still no PDF/QR dependency | to file |
| 6 | **A public, unauthenticated route pattern** for certificate verification. Only the `/api/tenant-config` precedent exists (mounted on `Letflow.Router`, ahead of the `/api/v1` forward, with its own disclosure boundary). Needs its own design and `SECURITY-REVIEWER` gate. | **Design closed 2026-09-12** -- `REQ-323` `done` (design, `lib/letflow/design/req323-unauthenticated-read-pattern.md`, plus [decision 0028](decisions/0028-unauthenticated-read-boundary.md): capability-handle resolution, no tenant-enumeration oracle). Implementation (a route built against this pattern) not yet filed | `REQ-323` |
| 7 | **`x-ui` widget vocabulary + `Expr` evaluators.** Without these, every admin CRUD screen is hand-written React instead of generated from an entity definition. | **Closed 2026-09-11** — `REQ-284` `done` (closed vocabulary + `fieldRegistry`); `REQ-291`, `REQ-292`, `REQ-293` (the `Expr` evaluators, definition-time / server-side / TypeScript) all `done`. The 2026-09-09 reading that three of them were still `pending` no longer holds | closed |
| 8 | **i18n in `web/`.** BilimBaga is trilingual (kk/ru/en). Non-negotiable. | **Closed 2026-09-09** — `REQ-285` `done` (react-intl, decision 0021) | closed |
| 9 | **Tenant branding**, and `form_schema` exposed on the task-detail response. | **Closed 2026-09-11** — `REQ-281`, `REQ-282` `done` (both tenant-config endpoints serve branding), `REQ-286` `done` (`form_schema` exposed), and `REQ-283` (SPA theming) `done`. The 2026-09-09 reading that `REQ-283` was still outstanding no longer holds | closed |
| 10 | **Relations between entity records.** `Letflow.Entities.Query.Compiler` has no `join`/`preload`; `fk_def`'s `references_entity` is validated for shape and self-reference only, with no referential enforcement. **Now a consequence of [decision 0023](decisions/0023-entity-storage-hybrid.md)**, not separate work — per-entity-type tables with promoted FK columns make joins expressible for the first time. | **Closed 2026-09-11** — `REQ-300` `done` (joins in `Letflow.Entities.Query.Compiler` over promoted FK columns). 0023's open question, which had blocked filing this at all, was answered by `REQ-295` (`done`) | closed |
| 11 | **Localized-text field type.** Re-scoped by 0023: entity-content localization is blob-stored (it follows its parent's lifecycle), and becomes searchable via generated columns per locale when `queried: true`. Not a relations problem and not an i18n-layer problem — gap 8 (`REQ-285`, client-side) is a different concern that this does not depend on. | **Closed 2026-09-11** — `REQ-301` `done` (blob-stored localized text, generated column per locale when `queried: true`) | closed |
| 12 | **Bulk import/export of entity *records*.** `Letflow.Definitions.ExportImport` moves definitions, not records. BilimBaga has `pg_trgm`-backed import/export (`011_pg_trgm_import_export`). | **Closed 2026-09-12** -- `REQ-314` `done` (design, `lib/letflow/design/req314-entity-record-bulk-export-import.md`); `REQ-318` `done` (permission atoms, PR #1277), `REQ-319` `done` (export route, `POST /entities/records/:entity_type/export`, PR #1281), `REQ-320` `done` (import route, `POST /entities/records/:entity_type/import`, PR #1282) | closed |
| 13 | **A pack format that can carry entity definitions.** `Letflow.Definitions.SolutionPack`'s `pack_document` has four content sections — `definitions` (process definitions only), `service_catalog_entries` (rejected), `variable_schemas`, and `manifest.required_roles` (read-only, creates no role). There is **no `entity_definitions` section**, and no form-schema section. Bucket A's own delivery vehicle cannot carry two of the four things bucket A consists of. | **Closed 2026-09-11** — the pack document now carries an `entity_definitions` section: `REQ-303` `done` (design record [`0026`](decisions/0026-solution-pack-entity-definitions-section.md), which also confirmed the form-schema half was already closed), `REQ-304` `done` (export), `REQ-305` `done` (install), `REQ-306` `done` (test coverage). `service_catalog_entries` is still rejected and still unowned — see "Open questions" | closed |

Gaps 7–9 were already filed as 0020 follow-on work and were not S10's to re-file;
S10 depended on them and said so, and all three are now closed. Gaps 1–6 and
10–13 are new bucket-B requirements this stage must file first, and of those,
10, 11 and 13 — the three that make P2's exit condition reachable at all — are
closed as of 2026-09-11 (`REQ-300`, `REQ-301`, `REQ-303`–`REQ-306`). Gap 1 is
closed (`REQ-308`–`REQ-311`, all `done`). Gap 2 is now closed (`REQ-312`
design, `REQ-315` implementation, both `done`). Gap 3 is now closed
(`REQ-313` design, `REQ-316` migration/context module, `REQ-317`
permission atoms/routes, all `done`). Gap 12 is now closed
(`REQ-314` design, `REQ-318`/`REQ-319`/`REQ-320` implementation, all
`done`). Gaps 4 and 5 have their mechanism settled by decision 0027
(out-of-band provisioning via `POST /service-catalog`) but remain open as
capabilities, still unowned; gap 6 remains open and unowned as a
capability, with `REQ-323` now filed against it.

Gaps 10 and 11 are consequences of
[decision 0023](decisions/0023-entity-storage-hybrid.md), and as originally
written this file recorded that they could not be filed until that record's open
question — how a promotion's DDL is executed per tenant — was answered and gated.
**That question has since been answered:** `REQ-295` (`done`) produced
[`decisions/0024-entity-promotion-ddl-execution.md`](decisions/0024-entity-promotion-ddl-execution.md),
which settles the DDL mechanism, failure semantics, backfill and rollback. The
filing block it describes is lifted.

## Phases

Sized as milestones, not as requirements. Each is expanded into `REQ-xxx` entries
at the normal one-agent-turn sizing when it becomes the active phase.

| Phase | Deliverable | Bucket | Exit condition |
|---|---|---|---|
| **P0** | This stage file, decision 0022, an `FR-BB` index reconstructed from its actual citation sites, and the `FR-BB` → `REQ-xxx` translation with a bucket declared on each | — | every S10 requirement is filed and `REQ-VALIDATOR`-passed |
| **P1** | Close gaps 1–6 and 10–13; land 7–9 | B | `mix letflow.check` and `web/`'s `npm run check` green with all thirteen closed. As of 2026-09-12 gaps 1, 2, 3, 7, 8, 9, 10, 11, 12 and 13 are closed; gaps 4 and 5 have their mechanism settled by decision 0027 but remain open as capabilities (no mailer/SMTP, no PDF/QR dependency); gap 6 remains open and unowned as a capability, with `REQ-323` now filed against it |
| **P2** | The pack: entity definitions, process definitions, role-registry seed, Lua grading rules | A | a tenant with a working question bank and exam configuration, and **zero exam-specific Elixir**. Reachable as of 2026-09-11: gaps 10, 11 and 13 are closed — see below |
| **P3** | `lib/letflow/exam/`: live session (deadline, autosave, per-question scoring, anti-cheat), certificate issuance | C | each module carries its `REVIEWER` bucket-C sign-off |
| **P4** | `web/`: admin CRUD generated from `x-ui`, plus the hand-written candidate exam-taking UI | C (client) | screens use `web/`'s design system, not BilimBaga's component layer |
| **P5** | Parity: BilimBaga's 19 Playwright spec files (168 `test()` blocks) re-pointed at the Letflow build | — | `RELEASE-VALIDATOR` re-derives the pass, `UAT-RUNNER` runs them against a live instance |
| **P6** | *Conditional* — importer from BilimBaga's PostgreSQL into entity records | B | built only if a deployment holds real data; otherwise never built |

P2 is the stage's real test. If the question bank, exam configuration and
assignment lifecycle cannot be expressed as definitions, the premise of 0022
reasoning §1 is wrong, and that is a finding worth stopping on rather than
routing around by moving the work into bucket C.

**Part of that finding is already in, and it went deeper on a second pass.**
`REVIEWER`'s 2026-09-09 sign-off on 0022 established from the code — not from a
P2 attempt — that the question bank is not expressible as an entity definition
today: no relations (gap 10) and no queryable localized content (gap 11). Those
two rows are re-marked **B, then A** in 0022's §1 table.

A follow-on architecture review the same day found the cause underneath both,
and a third blocker that is more fundamental than either. **Both findings stand
as stated; both have since been closed.** They are kept here in full, because
the reasoning is what justifies the shape the platform now has:

- **The storage model itself.** *(Finding, 2026-09-09.)* Every entity record of
  every type shared one `entity_record_latest` table with its data in a JSONB
  blob and no index on it, so every definition-declared filter was an unindexed
  sequential scan, and there was no relational structure to join on. [Decision
  0023](decisions/0023-entity-storage-hybrid.md) resolved this to per-entity-type
  tables with a hybrid promoted-column/blob shape, and gaps 10 and 11 became
  consequences of it rather than separate work. *Closed:* its named open question
  — how a promotion's DDL is executed per tenant — was answered by `REQ-295`
  (`done`) in
  [`decisions/0024-entity-promotion-ddl-execution.md`](decisions/0024-entity-promotion-ddl-execution.md);
  gap 10 closed by `REQ-300` (joins over promoted FK columns) and gap 11 by
  `REQ-301` (localized text, generated column per locale when `queried: true`).
- **The delivery vehicle.** *(Finding, 2026-09-09.)* `SolutionPack` could not
  carry entity definitions or form schemas at all (gap 13). Bucket A is defined
  as definitions installed via `SolutionPack.install/3`; two of the four things
  bucket A consists of had no section in the pack document. *Closed:* `REQ-303`
  produced [decision
  0026](decisions/0026-solution-pack-entity-definitions-section.md), which
  designed an `entity_definitions` section and established that the form-schema
  half was already closed elsewhere; `REQ-304` landed export, `REQ-305` install,
  and `REQ-306` its test coverage — all `done`.

**Expanding P2 into bucket-A requirements was blocked until gaps 10, 11 and 13
closed; as of 2026-09-11 all three are closed and that block is lifted.** The
response chosen was to close the platform gaps rather than move the question
bank into bucket C, and that is what happened — no reclassification was needed
and none was made. The original standard still holds for what remains: if
closing a gap turns out to be disproportionate, *that* is the finding worth
stopping on, and it belongs in a new decision record rather than in a quiet
reclassification.

Also flagged there, for P3's scoping: `backend/internal/sessions/` carries
adaptive question selection (`SelectNextAdaptiveQuestion`, `026_adaptive_exam`)
and short-text autograding (`027_short_text_autograding`). Neither is expressible
as a static process definition; both should be assumed bucket C.

## Bucket-C inventory

The measured half of 0022's rule 3. Every module added under `lib/letflow/exam/`
or `web/src/pages/exam/` is listed here with its one-line justification and its
`REVIEWER` sign-off reference. Growth in this table is the stage's primary health
metric.

| Module | Why not A (a definition) | Why not B (generic) | REVIEWER sign-off |
|---|---|---|---|
| *(none yet)* | | | |

## Open questions, recorded rather than answered early

- **Anti-cheat scope.** BilimBaga's roadmap includes tab-focus and timing signals.
  Whether these are entity-record events, `Letflow.EventStore` events, or neither
  is a P3 design question; deciding it now would pre-empt gap 1's route shape.
- **Where a pack's Lua grading rules are audited.** `Letflow.Engine.LuaScriptAudit`
  exists for service-task scripts. Whether pack-supplied grading scripts pass
  through the same audit path, or need their own, is a P2 design question with a
  `SECURITY-REVIEWER` interest.
- **Whether `service_catalog_entries` in a pack document unblocks here — and who
  now owns that policy. ANSWERED by
  [decision 0027](decisions/0027-solution-pack-service-catalog-install-policy.md).**
  `Letflow.Definitions.SolutionPack` still **rejects** a non-empty
  `service_catalog_entries` array
  (`lib/letflow/definitions/solution_pack.ex`'s `check_unsupported_sections/1` →
  `{:error, :unsupported_pack_section}`), and 0027 settles that rejection as
  PERMANENT, not merely interim. The module's moduledoc and its inline comment
  previously deferred the policy to `REQ-192` — but `REQ-192` was already `done`
  (S6, "Port services.zig's route surface onto the service catalog") without
  lifting the pack restriction, so that deferral was stale. 0027 closes the
  question outright: a solution-pack document may never carry
  `service_catalog_entries`; any such entry is provisioned out-of-band through
  the existing `POST /service-catalog` route (gated `:AdminServicesManage`,
  PLATFORM_ADMIN-only in the current role matrix).

  Gaps 4 and 5 both want a packed catalog entry; both now proceed via that
  out-of-band route rather than through the pack. Correcting the stale
  `REQ-192` pointer in `solution_pack.ex` to cite 0027 instead is this
  requirement's (REQ-322's) own work, not pending P1 work.
- **AI-assisted authoring (BilimBaga phase 7).** Deliberately not phased above. It
  is the least load-bearing feature in the product and the most likely to be
  redesigned; it gets a phase when parity (P5) is real.

## Decisions

- [`decisions/0022-bilimbaga-vertical.md`](decisions/0022-bilimbaga-vertical.md) —
  the vertical shape, the bucket rule, what is discarded, and what this stage
  explicitly does not re-decide.
- **Not re-decided here:** the running-instance shape. `REQ-045` and
  `Letflow.Engine`'s "Process-vs-row decision" already settled it, and 0022 states
  why a timed exam session strengthens rather than reopens that conclusion.

## REVIEWER sign-off

**2026-09-09 — `REVIEWER`, on decision 0022 and this stage file's first
revision.** PASS on the vertical decision; recorded disagreement on 0022
reasoning §1's cost model. The full sign-off is in
[`decisions/0022-bilimbaga-vertical.md`](decisions/0022-bilimbaga-vertical.md);
its consequences for this file are gaps 10–12, P1's and P2's revised exit
conditions, and the block on expanding P2 before gaps 10 and 11 close — since
extended to gap 13, and refined by
[`decisions/0023-entity-storage-hybrid.md`](decisions/0023-entity-storage-hybrid.md),
which makes gaps 10 and 11 consequences of the storage model rather than
independent work.

No implementation sign-off yet. Re-verified 2026-09-11, one clause of the three
this line originally carried is still true:

- **"No S10 requirement exists" — no longer true.** Twenty-nine S10 requirements
  are filed (`REQ-295`–`REQ-323`, counting distinct `- id: REQ-NNN` entries whose
  own `stage:` field is S10); `REQ-322` (this requirement) and `REQ-323` are
  `pending`, the rest are `done`.
- **"No `lib/letflow/exam/` directory exists" — still true**, and
  `web/src/pages/exam/` does not exist either (`ls lib/letflow/exam/` and
  `ls web/src/pages/exam/` both fail with "No such file or directory"). The
  bucket-C inventory above is correspondingly still empty, which is the intended
  state this early.
- **"No pack document has been authored" — still true.** The pack *format* now
  carries entity definitions (`REQ-303`–`REQ-306`), but no BilimBaga pack
  document has been written against it (no such file exists under `lib/` or
  elsewhere in the tree); that is P2 work.
