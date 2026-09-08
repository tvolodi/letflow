# 0020 — Frontend architecture: design-system primitives, tenant-settings vocabulary, and the form-schema split

Status: decided (ratified before this file existed; formalized/backfilled 2026-09-09,
per ISS-0546). Owner: the underlying architecture decision was made by whichever
discovery session filed REQ-272 through REQ-289 on 2026-09-08 (evidenced below); this
record's own authorship (CODE-DESIGNER, WF03-ISS0546-20260909) is a backfill, not a new
decision — see "Backfill provenance" below.

## Question

`docs/frontend/design-system.md` (v0.1, 2026-05-20) existed as a component/token
*specification* but had never been formally ratified as the project's frontend
*architecture direction* — nothing tied it to how the backend's tenant-settings surface,
expression validation, and task form-schema plumbing should relate to it. Three
previously-separate areas needed one coordinating decision:

1. **Backend (D1):** what a tenant may configure (branding/locale), and how authored CEL
   expressions get validated before they reach a client evaluator.
2. **Frontend (D2):** whether to build `design-system.md`'s primitives by hand into
   `web/src/components/ui/`, or adopt a third-party component library instead.
3. **Form-schema (D3):** what role `tasks.form_schema` plays relative to the existing
   server-side validation authority (`variable_schemas`).

## Backfill provenance — why this file is dated 2026-09-09 but describes an earlier decision

This record did not exist when REQ-272 through REQ-289 (8 requirements, filed together
2026-09-08) began citing `docs/migration/decisions/0020-frontend-architecture.md` by
name, with three sub-decision labels (D1/D1a, D2/D2a, D3/D3a) and a numbered
"Sequencing" section, as already-settled authority. `docs/issues/ISS-0546.yaml` documents
the resulting gap: REQ-VALIDATOR checks a requirement's own testability, not whether an
external file it cites resolves on disk, so nothing caught the missing file until
RELEASE-VALIDATOR did, on REQ-272's own re-derivation. Two of the eight citing
requirements (REQ-272, REQ-273) were already built and merged, correctly, against this
decision's content before this file existed at all — they followed the constraints the
phantom citation described, they just could not point at a real file.

The content below is **reconstructed, not invented**: it is required to be consistent
with all 8 citations gathered in `docs/issues/ISS-0546.yaml`'s diagnosis (verbatim quotes
from REQ-272, REQ-273, and GitHub issues #1095–#1100 covering REQ-274, REQ-275, REQ-280,
REQ-287, REQ-288, REQ-289). Where a citation states a fact precisely (e.g. an exact
value, an exact clause label), that fact is carried over verbatim below rather than
paraphrased. Where citations imply structure this record must have (e.g. Sequencing
steps 1–3, 5–7) but no citation actually quotes that structure's content, this record
says so explicitly rather than inventing it — see "What this record does not decide."

## Decision

### D1 / D1a — Backend: tenant-settings vocabulary and expression validation

**D1 (tenant settings/branding) is a CLOSED, named vocabulary, not an open-ended
settings blob.** A tenant may supply exactly: app name, logo URL, and a small fixed set
of brand colours (branding); locales and default_locale (locale). No other keys. This is
load-bearing because these values are served by `Letflow.Routers.MobileTenantConfig`'s
`GET /api/mobile/tenant-config` — a **pre-authentication, public** endpoint (no bearer
token possible, per that module's own moduledoc) — so an open-ended tenant-controlled
blob reaching an unauthenticated response is a materially larger attack surface than a
closed, reviewed set of fields.

**D1a (platform default brand colour) must be ONE canonical value, sourced from
`tokens.css`.** At the time this decision was reached, three different values existed
for what should have been the same platform default brand colour: `tokens.css`'s
`--color-brand-600` (`#228be6`), `design-tokens/letflow.tokens.json`'s `#2563EB`
(already superseded as a token source by REQ-120, per `design-system.md` §2), and
`lib/letflow/routers/mobile_tenant_config.ex`'s own `@default_branding` (`#0B5FFF`).
`tokens.css` is canonical (REQ-120 already settled it as the single design-token source
of truth); the other two are drift to be resolved, not competing options.

`mobile_tenant_config.ex`'s own moduledoc, independently of this batch and predating it,
already flagged tenant branding as "a deliberate, explicitly-flagged placeholder (design
OQ-1) ... pending a future requirement that would give tenant branding its own
schema/migration/admin UI" — this record is that pending decision (REQ-280, Sequencing
step 4, implements it).

**D1 (expressions) — authored CEL-subset expressions must be validated at DEFINITION
time**, using the real grammar (`Letflow.Engine.Expr`), not only the current
structural/lexical check, so a bad expression fails at authoring rather than at
render/evaluation time (REQ-288, Sequencing step 8). This is a CEL *subset* by decision
(the pre-existing, closed EXP-102 decision), not by omission — REQ-288's own scope fence
forbids extending or "completing" the grammar as part of wiring in definition-time
validation.

**D1a (expressions, continued) — a language-neutral conformance corpus, exported from
`Letflow.Engine.Expr`'s own tests, must exist and be proven correct BEFORE any second
(client-side) expression evaluator is built** — TypeScript or Dart alike. This is the
single most important piece of work this clause creates: building a second
implementation before the corpus exists is how the two drift apart before anyone can
measure it. REQ-289 (Sequencing step 9) implements the corpus-export half; REQ-293
(TypeScript evaluator) and REQ-294 (Dart evaluator) both depend on it for exactly this
reason and must not begin before it lands.

### D2 / D2a — Frontend: design-system primitives, no component library

**D2: build `docs/frontend/design-system.md`'s already-specified UI primitives into
`web/src/components/ui/` — extending that existing directory, not inventing a new
location — THEN migrate existing pages onto them in later, separate requirements.**
Primitive-building and page-migration are deliberately different requirements (e.g.
REQ-272/274/275 build primitives; REQ-276..278 migrate pages onto them) so that a
component landing with zero call sites at the end of its own requirement is the expected
outcome, not an incomplete one.

**D2a explicitly and deliberately REJECTS adopting a third-party component library
(Mantine, Radix, shadcn, or equivalent) — "on process grounds."** What "on process
grounds" means concretely: this migration is building primitives matched exactly to
`design-system.md`'s own, already-specified API surface (exact prop names, exact
variant/size enums, exact status-to-token tables) — adopting a third-party library would
mean adapting *that* library's own API surface and component model to fit the spec after
the fact, or rewriting the spec to fit the library, either of which reopens design
decisions this project already closed when it wrote `design-system.md`. Rejecting a
component library is a process choice about not re-opening settled spec work, not a
verdict that component libraries are bad in general.

This rejection has a named, accepted cost: **hand-built WCAG 2.1 AA accessibility is the
known price of not adopting a library**, and D2 says so explicitly enough that it must be
actively tested (e.g. via `web/tests/guards/`-class checks and explicit a11y assertions
per component), not assumed to fall out of hand-written markup for free.

Reopening D2/D2a requires a new decision record that explicitly supersedes this clause —
it is not something a single implementation requirement may diverge from on its own
judgement.

### D3 / D3a — Form-schema: rendering payload, not a validation authority

**D3: `tasks.form_schema` is a RENDERING PAYLOAD ONLY. It is never a server-side
validation authority.** The server-side validation authority for what a tenant may
submit on task completion is, and remains, `variable_schemas` (REQ-109, done, via
`Letflow.Engine.VariableMerge`/`merge_output_variables`). Wiring `form_schema` into any
completion-path check would make a tenant-supplied rendering payload the arbiter of what
a tenant may submit — an INV-2 (server-side field authorisation) violation. This is the
largest gap D3 identifies: a renderer (`web/src/components/forms/DynamicFormRenderer.tsx`,
already built) with no data source, and a `tasks.form_schema` column
(`lib/letflow/engine/task.ex`) with no producer.

**D3a, three constraints, all mandatory:**

1. **Rendering payload, not validation authority** (restated as the binding constraint,
   not just context) — server-side validation authority stays with `variable_schemas`;
   `form_schema` must not be wired into any completion-path check.
2. **`form_schema` is UNTRUSTED INPUT.** It is an untyped `:map` reaching a renderer and
   must be shape-validated via the existing
   `Letflow.Definitions.JsonSchemaShape.check/1` — reused, not hand-rolled a second time.
3. **Version pinning reuses REQ-126's existing design.** A schema served for a running
   task must be the schema of the pinned definition version the task was created
   against (`Letflow.Tasks.get_form_version/2`), never silently substituted from the
   currently-active definition — the same silent-substitution failure REQ-126 exists to
   prevent for `form_id`/`form_version`.

REQ-273 (done, merged) implements D3/D3a: it populates `tasks.form_schema` at task
activation from `node.attributes["form_schema"]`, shape-validates it via
`JsonSchemaShape.check/1`, and leaves it `nil` (never an invented default) when the node
attribute is absent, per REQ-047's existing "no default is invented for an absent key"
discipline.

## Sequencing

A numbered rollout exists, evidenced by REQ-280 citing itself as step 4, REQ-288 as step
8, and REQ-289 as step 9. This record can state the steps citations actually establish;
it cannot reconstruct steps 1–3 or 5–7 from any citation gathered so far — see "What this
record does not decide" below, rather than guessing their content.

- Step 4 — REQ-280: tenant settings (D1/D1a closed vocabulary + canonical brand colour).
- Step 8 — REQ-288: definition-time CEL expression validation (D1/D1a).
- Step 9 — REQ-289: expression conformance corpus, preceding any client evaluator
  (D1/D1a); REQ-293 (TypeScript) and REQ-294 (Dart) are downstream dependents of this
  step, not part of it.

Steps 1–3 and 5–7 are not reconstructable from the citations gathered for ISS-0546 — no
citation quotes their content, only their existence is implied by the step-4/8/9
numbering being consistent across three independently-filed requirements. This is
flagged as an open question below rather than silently filled in.

## Consequences

- **D1/D1a** commits future tenant-settings work to the closed vocabulary named above —
  any new tenant-configurable field requires either fitting inside it or a decision
  record amending D1, not an ad hoc addition to the public mobile-config response. It
  also commits any future client-side (TypeScript/Dart) expression evaluator to being
  built only after REQ-289's conformance corpus exists and passes.
- **D2/D2a** commits all frontend primitive work in `web/src/components/ui/` to
  hand-built components matched to `design-system.md`'s spec, with accessibility as an
  explicitly tested requirement per component, not an assumed byproduct. It forecloses
  adopting a component library anywhere in this directory without a new decision record
  superseding this clause.
- **D3/D3a** commits `tasks.form_schema` to staying a pure rendering payload for the
  life of the current architecture — any future temptation to use it for server-side
  validation (e.g. "just check the submitted values against form_schema too") is an
  INV-2 violation under this record and requires reopening D3, not a local
  implementation choice.
- **This record is a backfill.** The decision it describes was already governing real,
  merged work (REQ-272, REQ-273) before this file was authored. Authoring it now does
  not change any prior requirement's correctness — REQ-272 and REQ-273 already complied
  with the content above — it closes the provenance gap ISS-0546 identified: 8
  requirements citing a named, structured decision record that did not exist on disk.
  Future citations of "0020" should point at this file; no requirement's own text needs
  retroactive correction as a result of this record's authorship (ISS-0546's own scope,
  per its `affected_files`, does not require editing `docs/requirements.yaml`'s
  already-merged REQ-272/273 entries).

## Review triggers

- A future requirement needs a tenant-settings key outside D1's closed vocabulary —
  requires amending D1, not a silent addition to the public config response.
- A future requirement proposes adopting a component library in
  `web/src/components/ui/` — requires a new decision record explicitly superseding D2,
  per D2's own text above.
- A future requirement proposes validating task-completion output against
  `form_schema` — requires reopening D3; until then this is a standing INV-2 violation.
- Sequencing steps 1–3 or 5–7 surface with concrete content (e.g. a future requirement
  cites "0020 Sequencing step 2") — at that point, amend this record's Sequencing section
  with the recovered content instead of leaving the gap open indefinitely.

## What this record does not decide

- The content of Sequencing steps 1–3 and 5–7. No citation gathered for ISS-0546 quotes
  their content; only step 4, 8 and 9 are evidenced. Left explicitly open rather than
  invented — a future amendment should fill these in only from real evidence (a citing
  requirement, a discovery-session artefact, or similar), the same discipline this
  backfill itself followed.
- Any content for D1/D2/D3 beyond what the 8 gathered citations in
  `docs/issues/ISS-0546.yaml` establish. Where two citations might have seemed to leave a
  gap (e.g. exactly which brand colours beyond "a small fixed set" are permitted, or the
  exact JSON shape of the closed tenant-settings vocabulary), this record does not invent
  specifics beyond what REQ-280's own citation states — a future reader implementing
  against D1 should consult REQ-280's own acceptance criteria for the concrete schema,
  not treat this record as a substitute for it.
- Whether `design-system.md` itself needs revision. This record ratifies it as the
  frontend architecture direction; it does not re-review its content section by section.
- Any application code, schema, or migration. This is a decision record; REQ-272,
  REQ-273 (done) and REQ-274/275/280/287/288/289 (in progress or pending, per
  `docs/requirements.yaml`) are the implementing requirements.
