# GUI review: instance-pin-survives-catalog-change

**Date:** 2026-09-20
**Scenario:** `test/fixtures/uat/scenarios/platform/instance-pin-survives-catalog-change.yaml`
(PW-03, `sys-instance-version-pinning`)
**Process:** "review real screens before writing a blind Playwright spec"
**Result:** BLOCKED / UNBUILT_FEATURE (partial) -- filed as **REQ-373** (backend),
GitHub issue **#1594**. No live-instance UAT run was performed, per the process's own
step 2 ("if it genuinely doesn't exist, file it... move on").

## Path taken

Step 1 of the assigned process: check whether the feature exists by reading current
source, not by trusting the scenario's own stale NOTE (ISS-0527, which already says
this scenario's `pipeline_test` is an aspirational forward-reference gated on a missing
feature). Verified directly rather than assumed.

## What exists today (verified by direct source read)

- `lib/letflow/engine/pin_resolver.ex` (`Letflow.Engine.PinResolver`, REQ-059,
  PIN-01..04, status `done`) -- the full event-sourced pin-freezing MACHINERY:
  `resolve/4` freezes every `catalog_entry`/`module`/`variable_schema` dependency into
  the `INSTANCE_STARTED` event payload at case-start time; `reconstruct_effective_pins/2`
  / `merge_effective_pins/3` replay-derive the effective pin set purely from
  already-appended events, with zero catalog reads by construction (confirmed: neither
  function accepts a `Lookup.t()` parameter at all); `apply_inheritance/2` handles child-
  instance pin inheritance with conflict recording; `pin_for/3` is a no-fallback accessor
  that never substitutes a "current" value for a missing pin.
- REQ-060 (PIN-05, explicit rebind, status `done`) -- a real, already-shipped rebind path
  that appends exactly one `INSTANCE_PINS_REBOUND` event per call, atomically,
  all-or-nothing, carrying `ref`/`prior_version`/`new_version`/`actor`/`reason` per
  changed entry. This is exactly EO-005's "recorded with who asked, what changed, and
  why" requirement -- the backend mechanism for it is real and tested.
- `source` provenance taxonomy (`:resolved` / `:override` / `:inherited` / `:rebound`)
  is already a first-class field on every pin record -- exactly the taxonomy EO-003 asks
  a case-detail screen to display.

This is substantial, real, tested machinery -- not a stub pretending to work.

## What does not exist (verified by direct source read, not inference)

- **`service_catalog` has no version or status column at all.**
  `lib/letflow/service_catalog.ex` and `lib/letflow/service_catalog/entry.ex` (REQ-191/
  REQ-192, both `done`) implement a plain CRUD registry: `service_id` is the table's own
  primary key, one row per service, `register/1` / `get_for_tenant/2` /
  `list_for_tenant/2` / `update_scope/2` / `delete/1` -- no `publish`, `retire`, or
  `version` concept anywhere in the module (grepped for `publish|retire|republish`,
  zero hits). There is structurally nothing to "publish a newer version" of or "retire"
  in this scenario's sense.
- **No real `PinResolver.Lookup` exists anywhere in the shipped codebase.**
  `Letflow.ServiceCatalog.scope_validator_lookup/1` builds a *different* Lookup type
  (`Letflow.Definitions.ServiceScopeValidator.Lookup`, for global/tenant scope
  comparison) -- not `PinResolver.Lookup`. Every call site of `PinResolver.resolve/4`
  (`Engine.create/2`'s `pin_lookup/2` helper) falls through to `PinResolver.default_lookup/0`,
  whose `catalog_lookup`/`module_lookup` always return `{:error, :not_found}`. Grepped
  `lib/` for `PinResolver.Lookup` construction: only the module's own definition and its
  design docs, no real implementation.
  **Consequence, confirmed by reading `pin_resolver.ex`'s own moduledoc SCOPE GAP
  section (unchanged since REQ-059 shipped):** a shipped case referencing a
  `SERVICE_TASK`'s `service_id` cannot resolve a `catalog_entry` pin in production today
  at all -- it would hit `{:unresolved_catalog_ref, ref}` and fail to start, unless a
  caller-supplied override is used. `pin_resolver.ex` itself names this exact gap and
  cites R-Co's own precedent for holding the same gap open (`ISS-0672`/`GH-306`).
- **No case-detail screen anywhere in `web/src`** shows a case's dependency versions,
  their source (`:resolved`/`:override`/`:inherited`/`:rebound`), or any per-dependency
  provenance. Grepped `web/src` broadly; no real hits (all matches were unrelated word
  collisions, e.g. "opinion"-shaped strings).
- **No requirement in `docs/requirements.yaml` already covers this** -- searched for
  `catalog.*version`, `version.*publish`, `PIN-05`, `REQ-060` neighbourhood; REQ-191/192
  are confirmed CRUD-only, no versioning follow-on exists.

## Disposition

This is a genuine, architecturally significant gap, not a small defect -- exactly the
"large unbuilt feature" outcome the assigned process anticipates as legitimate. No
attempt was made to drive the live `https://qa.bizdala.com` flow (steps EO-001..EO-005),
since step 2's short-circuit applies: the feature the scenario's every step depends on
(a versioned, publishable/retirable catalog item) does not exist in any form the GUI
could exercise. Driving the UI would only reconfirm what source reading already shows
conclusively: there is nothing to publish, nothing to retire, and no screen to read a
pin's provenance from.

Filed as **REQ-373** (backend: version/status lifecycle on `service_catalog`, a real
`PinResolver.Lookup` wired to it, publish/retire routes under the already-shipped
`:AdminServicesManage` permission) in `docs/requirements.yaml`, `stage: S6`,
`depends_on: [REQ-059, REQ-060, REQ-191, REQ-192]`. A frontend follow-on (the
case-detail version-with-provenance screen, EO-003/EO-004) is explicitly named as
out of scope for REQ-373 and left to be filed once the backend lands, matching the
REQ-288/REQ-291 and REQ-372 precedent of splitting backend-then-frontend across two
requirements. PLC-01 (module_ref/sub-process catalog versioning) remains an
already-named, unscoped-to-any-stage gap and is explicitly excluded from REQ-373.

GitHub issue: https://github.com/tvolodi/letflow/issues/1594

## No spec authored

Per the assigned process's step 2, the permanent Playwright regression spec at
`web/tests/e2e/pipelines/platform-instance-pin-survives-catalog-change.pipeline.e2e.spec.ts`
was **not** authored -- there is no real feature yet for it to exercise, and authoring a
spec against a non-existent screen would be exactly the "blind Playwright spec" this
process exists to avoid. The scenario file's stale ISS-0527 NOTE is left in place
unedited (it already correctly states this scenario is blocked pending the feature),
matching the precedent set by the REQ-372 filing on
`definition-type-error-blocked.yaml` in this same sweep.

## No code change

No small defect was found to fix -- the gap here is the absence of an entire
version-lifecycle subsystem, not a bug in existing code. `docs/requirements.yaml` is the
only content change in this PR.
