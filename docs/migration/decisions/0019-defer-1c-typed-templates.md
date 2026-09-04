# 0019 — Defer 1C-style typed business-object templates (Directory/Document/Register/Report)

Status: decided (deferred, 2026-09-02; recorded 2026-09-05). Owner: the deferral itself
is a product-direction decision the user made directly (2026-09-02); this record exists
so a future reader finds the reasoning before re-proposing the idea, per ISS-0439's own
acceptance criteria.

## Question

1C gives developers typed business-object templates rather than one generic record
type, plus low-code helpers per type:

1. **Directories** — relatively constant reference data.
2. **Documents** — record an OPERATION/INTENT, typically with a posting step.
3. **Registers** — record the CONSEQUENCES of posting (balances, turnovers).
4. **Reports** — query/presentation over registers.

Should Letflow adopt this taxonomy as a typed layer over its own (still-unbuilt at
filing time) generic entity subsystem? Raised by the user 2026-09-02, explicitly framed
as forward-looking with no committed user or domain yet.

## Why the taxonomy is good, stated so it is not dismissed

It encodes a real insight: documents record INTENT, registers record CONSEQUENCES, and
conflating them destroys the ability to re-post or reverse a document and
deterministically rebuild its registers. That maps onto machinery Letflow already has
in shape, if not in typed, tenant-facing form — see `lib/letflow/design/iss0439-1c-
taxonomy-mapping.md` (this record's companion artefact) for the concrete, module-by-
module grounding. In short: the append-only event log is structurally a document
journal, `Letflow.EventStore.InstanceProjection` is structurally a register (rebuildable
from a fold over `events`, per its own moduledoc), and `Letflow.EventStore.Registry`
already versions typed payload schemas. It is a naming/ergonomics layer over an
existing shape, not a foreign concept.

## Decision: **DEFER**, for three reasons, in weight order

Quoted verbatim from `docs/issues/ISS-0439.yaml`'s filed description, not paraphrased,
so a future reader sees the reasoning at its original weight:

**(1) THE SUBSTRATE IS NOT PORTED.**

> R-Co already designed a generic, UNTYPED dynamic entity subsystem (~3400 lines, later
> measured at 4,158 lines including query/, src/design/entities.md, EXP-201/EXP-202)
> with NO Directory/Document/Register distinction -- one flat entity concept. Typed
> templates would specialise that substrate, which at filing time was not only unported
> but untracked (ISS-0438, queue task 438). Designing the specialisation first would
> likely produce a second parallel data model rather than a layer.
>
> **Status update (2026-09-04): ISS-0438 has since resolved** -- the tracking/coverage
> gap is closed, with a scoping decision (IN SCOPE, port to S6) and 7 requirements
> (REQ-225..REQ-231) registered and independently claimable. The substrate is now on a
> concrete build path, but is not yet BUILT (no requirement has status: done) -- this
> reason is downgraded from "untracked" to "tracked but not yet built," which does not
> by itself change the deferral: reason (2) below still holds regardless of porting
> status, and no real tenant usage of the now-porting substrate exists yet to supply
> reason (2)'s missing evidence.

**Re-verified as of this record (2026-09-05):** still accurate. REQ-225 through
REQ-231 are all `status: pending` in `docs/requirements.yaml` — none is `done` or
`in_progress` (checked directly, not inherited from the 2026-09-02 filing text; see
`lib/letflow/design/iss0439-1c-taxonomy-mapping.md` §5 for the full per-requirement
table). The substrate this reason names is exactly as unbuilt today as it was when
ISS-0438 resolved.

**(2) NO EVIDENCE FOR WHICH FOUR TYPES ARE RIGHT.**

> 1C reached its taxonomy from decades of accounting-domain traffic. Letflow is a
> general BPM platform whose engine is MORE general than 1C's model. Picking four
> templates now means guessing. A wrong template is worse than none -- it becomes a
> schema every tenant builds on and cannot be retracted without breaking them.

**(3) OPPORTUNITY COST.**

> The largest scope expansion proposed in this project -- a platform layer (typed
> templates + low-code helpers + query surface + UI conventions + migration story) --
> against remaining core requirements and an open issue queue with real defects (at
> filing time: two HIGH CVEs (ISS-0420), a live platform-wide scheduler defect
> (ISS-0429), and an unfixed flake blocking parallel test adoption (ISS-0426); the
> specific set changes run to run, but the shape of the tradeoff -- speculative
> platform layer vs. real, queued defects -- does not).

## Recorded decision (user-confirmed 2026-09-02), quoted

> forward-looking, no committed user. Settle/port the GENERIC entity subsystem first
> (ISS-0438), let real workflows use it untyped, and WATCH WHAT TENANTS ACTUALLY BUILD.
> If Directory/Document/Register patterns emerge from real usage, formalise them then --
> they will fit, because they will have been EXTRACTED from evidence rather than
> guessed. Typed templates can be added later; removing them once tenants depend on them
> is far harder.

## Review triggers — named so the deferral is reviewable, not permanent

Any one of these is sufficient grounds to reopen ISS-0439 and reassess:

1. **A concrete tenant/domain** with real business objects that need typed templates —
   an actual committed user or use case, not a hypothetical one.
2. **Observed cross-tenant duplication** — several tenants independently building the
   same Directory- or Register-shaped structure on top of the generic entity subsystem
   once it exists, evidence of a real, recurring pattern rather than a guess.
3. **A deliberate decision to target an ERP-adjacent market**, where the 1C vocabulary
   itself becomes the selling point rather than an implementation detail.

## Dependency: ISS-0438 / REQ-225..231, current status

No typed-template design proceeds until the generic entity subsystem is itself
**built**, not merely scoped. ISS-0438 resolved with a scoping decision (IN SCOPE, S6,
`lib/letflow/design/iss0438-entity-subsystem-scoping.md`) and seven requirements
registered — REQ-225 (entity definition schema/validator), REQ-226
(`entity_definitions` persistence + CRUD + `ArtifactKind :entity` extension), REQ-227
(record payload validation), REQ-228 (event registration + record commands), REQ-229
(projection + replay), REQ-230 (query DSL — operators/allowlist/compiler), REQ-231
(query DSL — cursor + field-grant redaction). As of this record (2026-09-05), verified
directly against `docs/requirements.yaml`: **all seven are `status: pending`.** None
has been implemented. This record's deferral is unaffected by ISS-0438's own
resolution — reason (1) above already anticipated exactly this state ("tracked but not
yet built... does not by itself change the deferral") — and remains unaffected until
at minimum REQ-225..231 reach `done` and some real tenant usage of the resulting
untyped subsystem accumulates, per the review triggers above.

## Grounding artefact

`lib/letflow/design/iss0439-1c-taxonomy-mapping.md` maps each of Directory / Document /
Register / Report onto Letflow's actual current code — which of the four is served
(fully, partially, or not at all) by the append-only event log, by
`Letflow.EventStore.InstanceProjection`, by `Letflow.EventStore.Registry`'s typed
payload schema versioning, and by `Letflow.Repository`'s artifact/content versioning —
with an explicit reuse-vs-genuinely-new split for each concept, and a plain verdict on
whether the taxonomy should eventually be adopted at all (§4 of that artefact: not
recommended for adoption now, not rejected outright either — the sequencing above is
the actual recommendation). A future reader re-proposing this idea should start there,
not from a blank page.

## What this record does not decide

- Whether the generic entity subsystem's own requirement slicing (REQ-225..231, per the
  ISS-0438 scoping doc) is correct. Out of scope for this record; that scoping decision
  already exists independently.
- Any schema, requirement, or code for typed templates. None is created by this record
  or its companion artefact, per ISS-0439's own AC5.
- Whether the taxonomy, if eventually adopted, should be exactly 1C's four types or a
  Letflow-specific variant. Left entirely open — the whole point of the deferral is that
  this should be extracted from real usage, not decided now.
