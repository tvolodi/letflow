# GUI review: `tenant-branding-applied` (PW-14)

Date: 2026-09-20
Agent: ORCH
Sweep position: 11th of ~15 scenarios in today's systematic GUI-review sweep.
Scenario: `test/fixtures/uat/scenarios/platform/tenant-branding-applied.yaml`
Process applied: "review real screens before writing a blind Playwright spec"
(same process as the earlier scenarios in this sweep).

## Outcome: BLOCKED / PARTIALLY-BUILT (hybrid)

Unlike most of this sweep's findings so far, this scenario is not simply
unbuilt. `docs/migration/decisions` and requirement history show REQ-280
(tenant settings store), REQ-281 (`GET /api/tenant-config` branding key),
REQ-282 (mobile tenant-config branding), and REQ-283 (frontend CSS theming
apply) are all `status: done` and genuinely shipped. What is missing is
narrower and more specific than the scenario's own stale NOTE (ISS-0527)
implies: there is no HTTP-reachable way for a tenant admin to ever *write* a
branding change, no contrast/readability validation of any kind, and no
activity-log recording of a rejected change — because nothing can be
rejected when nothing can be submitted in the first place.

## What was checked, and what it showed

**Does the read/apply side of tenant branding exist?** Yes, fully.
- `lib/letflow/identity/tenant.ex`'s `settings_changeset/2` and
  `lib/letflow/identity/tenant_settings.ex`'s closed-vocabulary `Ecto.Type`
  enforce a five-key allowlist (`app_name`, `logo_url`, `brand_colors`,
  `locales`, `default_locale`), with `brand_colors` itself restricted to one
  sub-key, `"primary"`, format-checked as `#RRGGBB`.
- `GET /api/tenant-config` (`lib/letflow/routers/tenant_config.ex`) serves it
  back out as one of exactly three top-level response keys, unauthenticated
  by design (login-bootstrap endpoint).
- `web/src/theming/BrandingProvider.tsx` / `applyBranding.ts` /
  `brandingDefaults.ts` fetch that config on app mount and set
  `--color-brand-600` via `document.documentElement.style.setProperty`,
  gated by a closed `BRAND_COLOR_CSS_PROPERTY` allowlist that iterates its
  own keys, never the tenant-supplied object's keys (so an
  out-of-allowlist key could never reach the DOM even if it somehow reached
  storage).

**Does a company appearance settings *screen* (steps 1/4/5) exist?** No.
Grepped `web/src/pages/admin/` for any appearance/branding/colour settings
screen — none. `web/src/pages/admin/tenants/EditTenantPage.tsx`, the only
per-tenant admin edit screen that exists, edits `display_name` only; no
colour field, no branding section.

**Does an HTTP-reachable write path exist at all (any screen, any client)?**
No — and this is by explicit design, not an oversight the read-side
requirements simply hadn't gotten to yet.
`lib/letflow/design/req281-tenant-config-branding-key.md` section 6 states
outright: *"the existing, already-shipped context function — REQ-280 design
§8 confirms it has 'no HTTP-reachable write path' is fine for this
purpose."* Grepping every module under `lib/letflow/routers/` for
`update_tenant_settings` or a write to `tenants.settings` returns zero
routes. `Letflow.Identity.update_tenant_settings/2` exists and is fully
validated, but nothing in the HTTP surface ever calls it.

**Does colour-contrast/readability validation exist (EO-003)?** No, at any
layer. `Tenant.settings_changeset/2`'s `validate_brand_colors/2` checks
**hex format only** (`~r/^#[0-9A-Fa-f]{6}$/`) — there is no relative-
luminance or WCAG contrast-ratio computation anywhere in the codebase
touching `brand_colors`.

**Does rejected-out-of-scope-change activity-log recording exist
(EO-001's negative half)?** No — there is nothing to record from, since
there is no write path to reject a request on. The building blocks it would
reuse do exist and are real: `Letflow.Audit` (`lib/letflow/audit.ex`,
`lib/letflow/audit/entry.ex`) and `web/src/pages/admin/AuditLogPage.tsx`
are both already shipped for other purposes.

**Does status-colour immutability (EO-002) hold?** Yes, structurally,
confirmed without needing a live browser session (same reasoning class as
this sweep's `renderer-permission-denied-surface` finding — fully
determined by reading the allowlist and its one consumer, no ambiguity
left). `BRAND_COLOR_CSS_PROPERTY` in `brandingDefaults.ts` has exactly one
entry, `primary -> --color-brand-600`. `web/src/styles/tokens.css` defines
`--color-success`/`--color-warning`/`--color-error`/`--color-failure` as
entirely separate custom properties `applyBranding.ts` never touches, and
`web/src/components/ui/StatusBadge.tsx` (the platform's shared status-colour
component) reads those tokens directly. No tenant setting can reach a
status colour — not "doesn't today," but "has no code path that could."

**Does the tangential irreversible-action confirmation (EO-004) hold?**
Yes. Letflow has no literal "shipment" domain; the closest and clearly
intended real equivalent is process-instance cancellation.
`web/src/components/instances/CancelInstanceDialog.tsx`, read in full, is a
real modal (`role="dialog"`, `aria-modal="true"`, focus-trapped, Escape
closes it) with explicit "This action cannot be undone" text, a
danger-styled "Confirm cancellation" button, and no code path that fires the
cancellation before that click. Nothing happens until confirmed.

**Is there a real, confirmed EO-005 (first-paint, no-flash) defect?** Yes,
found by reading source, not by driving a browser (no browser-automation
tool is available in this environment; see "What was not done" below).
`web/src/main.tsx` renders the React tree synchronously
(`ReactDOM.createRoot(...).render(...)`) without awaiting the pre-warmed
`fetchTenantConfig(...)` promise it kicks off one line earlier.
`BrandingProvider.tsx` applies the fetched colour inside a `useEffect`,
which by React's own contract runs strictly after the first commit/paint.
So the very first drawn frame is deterministically `tokens.css`'s platform
default (`--color-brand-600: #228be6`), and only after the network
round-trip resolves does the CSS variable swap to the tenant's colour — a
real flash on every load. This scenario's own `EO-005.on_fail` names
`severity: MINOR` and `suggested_action: none`, so this finding is recorded
here and in REQ-383's description rather than routed to WF-03 or fixed
inline.

## What was NOT done, and why

No live sign-in as `actor-swiftroute-alice` / `actor-swiftroute-marco`
against `https://qa.bizdala.com`, and no screenshots were taken. This
session's toolset has no browser-automation capability (confirmed by
searching for one before starting; none is registered), and — independent
of that — the scenario's core action (steps 1, 4, 5: a tenant admin opens
appearance settings and saves a colour change) has no real screen or
endpoint to drive: there is nothing a live session could exercise beyond
what reading the source above already conclusively established, matching
this sweep's `renderer-permission-denied-surface` precedent for the same
"core action has no real backing" shape. No permanent Playwright spec was
authored at `web/tests/e2e/pipelines/tenant-branding.pipeline.e2e.spec.ts` —
there is no shipped screen to write it against yet.

## Fixed vs filed

Nothing was fixed in this dispatch. Filed:

- `docs/requirements.yaml` **REQ-382** (owner `ELIXIR-DEV`, stage S8, status
  `pending`, `depends_on: [REQ-280, REQ-281]`) — the HTTP-reachable
  settings-write endpoint, a new WCAG-AA colour-contrast check added to
  `validate_brand_colors/2` (EO-003), and rejected-out-of-scope-key
  `Letflow.Audit` recording reusing the existing audit mechanism (EO-001's
  negative half). Explicitly fenced against widening the `brand_colors`
  allowlist itself and against a general "any tenant setting" PATCH
  endpoint. Flagged for mandatory SECURITY-REVIEWER sign-off — this is the
  first HTTP-reachable write path onto `tenants.settings`.
- `docs/requirements.yaml` **REQ-383** (owner `FRONTEND-DEV`, stage S8,
  status `pending`, `depends_on: [REQ-382]`) — the appearance settings
  screen itself, including authoring and passing this scenario's own named
  `pipeline_test` once the screen exists, with an explicit instruction that
  its EO-005 acceptance criterion documents the known flash (screenshot
  pair) rather than fixes it.

## Status housekeeping

- Scenario fixture's `pipeline_test` NOTE block extended (not removed — the
  read/store side is real, but the write side is not) with a dated addendum
  citing REQ-382/REQ-383 and this report.
- `docs/status/requirement_status.v20.yaml` — appended a `SCOPE-CHANGE` done
  event (`2026-09-20T02:35:00Z`), volume now at 14 entries / 939 lines /
  60380 bytes, well under the roll ceiling.
- `docs/status/requirement_status.index.yaml` — volume 20's entry count and
  note updated to reflect the new append.
- Verified `mix letflow.check_req_id_collision` (OK, no collision),
  `mix letflow.check_requirements_registration` (350 entries = 348
  registered + 2 deferred + 0 neither + 0 unclassified, no new gate
  failures), and `mix letflow.check_issue_refs` (one pre-existing violation
  on `docs/issues/ISS-0728-exam-title-object-object-sibling-wip-rescued.yaml`
  from a concurrent sibling session's WIP, not introduced by this run — no
  issue file touched by this dispatch) all checked with real output quoted.

## Spec status

No permanent Playwright regression spec was authored —
`web/tests/e2e/pipelines/tenant-branding.pipeline.e2e.spec.ts` remains
unauthored, now explicitly the responsibility of REQ-383's acceptance
criteria once the appearance settings screen ships.
