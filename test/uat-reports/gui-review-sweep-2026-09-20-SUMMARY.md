# GUI-review sweep — final summary (2026-09-19/20)

A systematic, agent-driven review of every UAT scenario lacking a working GUI
leg, following the "review real screens before writing a blind Playwright
spec" process (piloted on `bilimbaga/candidate-timed-exam-autograde.yaml`).
18 scenarios reviewed. For each: real source read first, then — only if the
feature genuinely exists — a real browser session against `https://qa.bizdala.com`,
screenshots read by the reviewing agent itself, any real defect fixed through
the normal branch→PR→CI→merge pipeline, and a permanent Playwright regression
spec authored only once every screen was confirmed correct by direct review.

## Disposition summary

| # | Scenario | Disposition | Filed |
|---|---|---|---|
| 1 | `bilimbaga/candidate-timed-exam-autograde` | **PASS — real spec merged** (PR #1580) | Fixed ISS-0728 |
| 2 | `definition-promotion-approved` | **PASS — real spec merged** (PR #1580s follow-up) | Fixed ISS-0730, ISS-0731; filed ISS-0732 (BLOCKER), ISS-0733 |
| 3 | `definition-promotion-conflict-rejected` | **PASS — real spec merged** | Fixed ISS-0735; filed ISS-0734 |
| 4 | `definition-promotion-rollback` | BLOCKED — backend real, no UI | REQ-371 |
| 5 | `definition-type-error-blocked` | BLOCKED — unbuilt semantic validation | REQ-372 |
| 6 | `instance-pin-survives-catalog-change` | BLOCKED — unbuilt version-pinning/catalog | REQ-373 |
| 7 | `migration-partial-failure-resume` | BLOCKED — unbuilt tenant-fanout migration | REQ-374, REQ-375 |
| 8 | `partition-retention-drop` | BLOCKED — deliberate architectural deferral, not an oversight | REQ-376, REQ-377 |
| 9 | `renderer-permission-denied-surface` | Renderer contract verified correct; **real BLOCKER security bug found** (role revocation has no live effect for OIDC sessions) | ISS-0736, REQ-378 (security-gated) |
| 10 | `template-update-conflict-resolution` | BLOCKED — unbuilt pack-update conflict resolution | REQ-379, REQ-380, REQ-381 |
| 11 | `tenant-branding-applied` | Read-side already correct (EO-002/EO-004 confirmed); write path/contrast-check/audit missing | REQ-382, REQ-383 |
| 12 | `tenant-switch-cache-isolation` | **Real security bug found and fixed** — sign-out didn't clear tenant residue in the same tab | Fixed ISS-0737 |
| 13 | `attachment-cross-tenant-probe` | Backend cross-tenant isolation verified genuinely leak-free (no existence oracle); signed-URL expiry/viewer UI/audit logging missing | REQ-386, REQ-387, REQ-388 |
| 14 | `shipment-attach-delivery-note` | BLOCKED — no GUI at all; backend has upload/list/delete but no content-type allowlist, no storage-quota tracking, no attach/remove history, no approval-record attribution | (see report — requirement filing deferred to a follow-up pass) |
| 15 | `entity-list-filter-and-page` | Backend filter/sort/page + field redaction verified correct; generic list UI missing; **real security gap found** — entity-type authorization is all-or-nothing with a 404-vs-empty existence oracle | REQ-393, REQ-394 (security-gated) |
| 16 | `shipment-high-value-happy` | BLOCKED — engine capability real and already regression-tested (REQ-206), but the process definition isn't deployed to any live tenant and a credential gap blocks exercising it; one small frontend defect fixed along the way | ISS-0739, REQ-395 |
| 17 | `shipment-ops-timeout-escalation` | BLOCKED — `advance-timer` endpoint exists (ISS-0389), but HUMAN_TASK timeout-escalation itself doesn't exist in the graph engine; also blocked by the same Gap 1/Gap 2 as #16 | REQ-396 |
| 18 | `agent-artifact-resubmit-idempotent` | **Out of scope** — targets an R-Co subsystem (autonomous coding-worker artifact pipeline) never adopted into Letflow; confirmed by exhaustive grep, no Letflow module resembles it | ISS-0740 (closed_not_applicable) |

## Real defects found and fixed this sweep

- **ISS-0728** — exam title rendered as literal `[object Object]` on the candidate exam list.
- **ISS-0730** — promotion-review GUI route existed but was never mounted behind the PLATFORM_ADMIN gate.
- **ISS-0731** — promotion-review page crashed on load (frontend/backend contract mismatch in `web/src/api/promotions.ts`).
- **ISS-0735** — a 409 promotion-conflict refusal was mismessaged as a generic "digest mismatch" in the UI.
- **ISS-0737** (security) — sign-out left tenant-scoped client state behind in the same browser tab.
- One small `TaskDetailPanel` defect (discarded form input) fixed during scenario 16's review.

## Real security findings (all properly gated, none silently patched over)

- **ISS-0736 / REQ-378** — a tenant admin's "revoke access" action in the GUI has **zero live enforcement effect** for OIDC-authenticated sessions, because the role registry backing the admin UI isn't coupled to the actual JWT-claims-based authorization path. BLOCKER, SECURITY-REVIEWER sign-off required before REQ-378 can be built.
- **ISS-0737** — sign-out tenant-residue leak (fixed, see above).
- **REQ-394** — entity-type authorization is coarse (all types visible or none), and requesting a nonexistent type returns a different status than an empty-but-permitted type, creating an existence oracle. Security-gated.

## Genuine "already correct" confirmations (no action needed)

- Cross-tenant attachment fetch (scenario 13): the API folds cross-tenant, cross-instance, malformed, and never-issued references to the exact same indistinguishable `{:error, :not_found}` response.
- Field-level cost redaction and entity-list error handling (scenario 15): restricted fields are genuinely never serialized to the wire, and non-searchable-field / over-limit-page-size requests both get clear, named errors rather than silent truncation.
- Renderer permission-denied contract (scenario 9): the `PermissionDenied` component shows zero leaked content, 401/403 are indistinguishable, and no screen ever mixes partial content with a refusal.
- Tenant branding read-side and status-color immutability (scenario 11) and the irreversible-action confirmation gate (`CancelInstanceDialog`) both hold today.

## Requirements filed this sweep (for later pickup)

REQ-371, REQ-372, REQ-373, REQ-374, REQ-375, REQ-376, REQ-377, REQ-378,
REQ-379, REQ-380, REQ-381, REQ-382, REQ-383, REQ-386, REQ-387, REQ-388,
REQ-393, REQ-394, REQ-395, REQ-396.

## Issues filed this sweep

ISS-0728 (resolved), ISS-0730 (resolved), ISS-0731 (resolved), ISS-0732,
ISS-0733, ISS-0734, ISS-0735 (resolved), ISS-0736 (BLOCKER, security),
ISS-0737 (resolved, security), ISS-0739, ISS-0740 (closed_not_applicable).

## What this sweep demonstrates

Of 18 scenarios, only 3 had a fully real, already-shipped feature ready for a
genuine screen-by-screen pass — and even those 3 turned up 4 real defects
(one of them a route that was simply never wired up, invisible to any
existing test). The remaining 15 were correctly identified as either unbuilt
(11), partially built with real security gaps (3), or out of adopted scope
entirely (1) — none of them got a fabricated passing Playwright spec written
against screens that don't exist, which is exactly the failure mode this
process was built to prevent.
