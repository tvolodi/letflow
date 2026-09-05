# 0007 — `VariableMerge.merge/3` validates every output key, not only overwrite candidates

Status: decided and shipped in the same change that records it. Owner: this record's
author acted in REVIEWER's role, as ISS-0077/GH#300 explicitly asked for ("REVIEWER
should decide... it likely warrants a decision record").

Supersedes: `lib/letflow/design/req049-variable-merge.md` §3.1 step 3's
overwrite-candidates-only rule, and `docs/requirements.yaml` REQ-109's AC5 second clause
("a brand-new key... is still inserted unvalidated").

Resolves: ISS-0077 / GH#300.

## Question

`Letflow.Engine.VariableMerge.merge/3` validates a key against its registered
`variable_schemas` row only if that key already exists in `current_variables` (an
"overwrite candidate"). A brand-new key — one this write is creating for the first
time — is inserted unconditionally, with no schema check, even when a schema is
registered for it and the value violates it.

PROVENANCE (historical, not current decision authority):
R-Co's `mergeVariables` (`instance.zig:2389-2430`) does not do this: Phase 1 iterates
every key of `output_variables` and checks `schema_map.get(key)` unconditionally, with no
comparison against `current_vars` at all. Collision detection (`current_vars.get(key)` at
`:2432`) is a separate, later check whose only job is deciding whether to emit a
`VARIABLE_OVERWRITTEN` event. In R-Co, a brand-new key with a registered schema is
validated and can be rejected.

Does Letflow adopt R-Co's semantic (validate every key), or keep its own
(overwrite-only)?

## Decision

**Adopt R-Co's semantic.** `merge/3` now scans every incoming key for a rejection, not
only the ones already present in `current_variables`. Collision detection (which keys
produce a `VARIABLE_OVERWRITTEN` event) remains a separate concern, exactly as in R-Co —
new-key inserts still produce no event.

## Reasoning

PROVENANCE (historical, not current decision authority):
**The current behavior was never a considered choice.** ISS-0077's own provenance trace
(and this record's own re-verification, both source trees read directly — R-Co
`instance.zig:2389-2430`/`:2432`, Letflow `variable_merge.ex:196-207` as it stood before
this change) shows the overwrite-only rule was an unverified claim in REQ-049's design
doc, written when no R-Co source tree was reachable, that got propagated as fact through
three later briefings and then implemented and shipped. `req049-variable-merge.md` §3.1
states the rule but supplies no rationale for diverging from R-Co beyond stating it. A
divergence with no recorded reason is not a decision to preserve out of respect for
"shipped behavior" — it is a bug that happened to ship.

**The bug is a real validation bypass, not a cosmetic difference.** A registered
`variable_schemas` row is a promise: values written to this key satisfy this schema.
Exempting the very first write — the one with no prior good value, the one most likely to
be malformed — breaks that promise on exactly the write it matters most for. Every
subsequent write of the same key is protected; only the first is not. A validation
feature that silently does not apply on first write is worse than no feature, because it
is trusted (ISS-0077's own framing, and correct).

**No compatibility cost exists today.** Per `docs/migration/decisions/0004-humanless-pipeline.md`,
there is no production deployment and no real tenant traffic at stake yet (pre-S8). The
"this would reject payloads accepted today" argument against adopting R-Co's semantic
only has weight once a real tenant is relying on first-write leniency; none is. Waiting
would only let more callers accumulate an assumption that then has to be broken later,
under real compatibility pressure instead of none.

**Migration fidelity is this project's default posture.** Every other place this
codebase diverges from R-Co on a validation or fail-closed question does so with an
explicit, reasoned decision record (see 0006 D2, 0003 Dimension B). This divergence had
none. Bringing it in line with R-Co is the default; keeping it would be the exception,
and exceptions need justification this one never had.

## What changes

- `lib/letflow/engine/variable_merge.ex` — `merge/3`'s rejection scan runs over
  `all_keys` (every incoming key), not `overwrite_keys`. Phase 2 (insert/overwrite
  application, event emission) is unchanged: a new-key insert still produces no event, an
  overwrite still produces exactly one `VARIABLE_OVERWRITTEN` event, and the same
  whole-batch-abort-on-rejection semantics (§3.2) apply regardless of which key rejected.
- `lib/letflow/engine/variable_schema.ex` — `variable_validations/5` builds its
  candidate-key set from every incoming key, not the intersection with
  `current_variables`. The `current_variables` parameter is kept (for its input-shape
  guard and because both call sites already have it in scope) but no longer filters
  candidates; the private helper that used to compute the overwrite-only intersection
  now just returns all incoming keys. This is a lookup-volume increase — a brand-new key
  now causes a `variable_schemas` SELECT lookup for it, where it previously short-circuited
  — matching R-Co's own unconditional Phase-1 lookup exactly.
- `lib/letflow/design/req049-variable-merge.md` §3.1 corrected in place to describe the
  new algorithm, with the superseded overwrite-only text kept as a historical note rather
  than deleted outright, per this codebase's own established convention for correcting a
  design doc after it ships (matching `instance_projection.ex`'s "superseded... retained
  for history" precedent).
- `docs/requirements.yaml` REQ-109's AC5 second clause corrected: a brand-new key
  violating a seeded schema is now rejected, not inserted unvalidated.
  `docs/status/requirement_status.yaml` gets a `revised` event for REQ-109 recording this,
  matching the GH#308/ISS-0090 precedent for amending a shipped requirement's AC.
- Tests: `variable_merge_test.exs`, `variable_schema_test.exs`, and
  `engine_variable_schema_merge_test.exs` each have one test whose assertion inverts
  (previously "the bypass happens," now "it doesn't") — all three said explicitly, in
  their own comments, that they were pinning the old behavior specifically pending this
  decision.

## Open questions this record does not resolve

- Whether an operator-facing error message or API-level documentation should call out
  that variable-schema validation now applies uniformly regardless of new/overwrite —
  left to whichever requirement next touches the tenant-facing surface for this feature;
  no such surface exists yet (validation errors surface only via `EXECUTION_ERROR`
  events today).
- The registration (INSERT) path for `variable_schemas` rows is still unbuilt (REQ-078/
  REQ-082, per `variable_schema.ex`'s own moduledoc) — this decision does not change that
  scope boundary.
