# GUI review: `swiftroute/shipment-attach-delivery-note` (PW-09)

**Date:** 2026-09-20
**Reviewer:** ORCH (this GUI-review sweep, 14th of ~15 scenarios)
**Scenario:** `test/fixtures/uat/scenarios/swiftroute/shipment-attach-delivery-note.yaml`
**Result:** BLOCKED / UNBUILT_FEATURE — the scenario's own stale NOTE (ISS-0526)
turns out to still be substantially accurate, though the real picture is more
nuanced than "nothing exists." No GUI flow was driven against
`https://qa.bizdala.com`, because there is no screen in `web/src/` for any part
of this scenario to click through.

## What this scenario needs vs. what exists today

Read the scenario in full first (steps 1-5, EO-001 through EO-005). It exercises:
a dispatcher (Lena) attaching a signed delivery note to a shipment-approval
task, a refused video/oversized upload with a plain limit explanation, a
storage-usage figure that rises and falls, removing a wrong document and
attaching the right one with history recording the swap, and an ops manager
(Marco) reviewing and approving against the actual attached document with the
approval record naming it.

Checked current source directly rather than trusting the scenario's own NOTE:

### Backend (`lib/letflow/`)

| Piece | Status |
|---|---|
| Attachment upload/list/get/delete core (`Letflow.Repository.Attachments`, REQ-211) | **Done, shipped.** `upload/2`, `list/2`, `get/2`, `get_content/2`, `delete/2` all exist and work, tenant/instance-scoped. |
| Route surface (`POST/GET/DELETE /instances/:id/attachments[/:id]`, REQ-212) | **Done, shipped.** `lib/letflow/routers/instances.ex` has all four routes, `AttachmentsManage`/`AttachmentsRead` permission-gated. |
| Malware scanning on upload (`:infected`/`:scan_unavailable`) | **Present** (added after REQ-211/212 shipped — beyond that design doc's original scope, confirmed directly in `handle_upload_attachment/2`). |
| Per-file size ceiling (`@max_upload_bytes`, 25 MiB) | **Done.** Rejects oversized files before any DB write. |
| **Content-type allowlist** (reject a video, accept a PDF) | **Does not exist.** `Letflow.Repository.Attachments`' own moduledoc states INV-a explicitly: `content_type` is caller-supplied metadata, never validated. A video is accepted today exactly like a PDF if it clears the size/scan checks. Scenario step 3's video-rejection half of EO-002 has no backing mechanism. |
| **Per-tenant storage-quota tracking** (EO-003) | **Does not exist at all.** Grepped `lib/letflow/` exhaustively for `storage_quota`/`storage_usage`/`storage_allowance` — zero hits beyond unrelated design-doc prose. Nothing tracks cumulative bytes used per tenant; nothing refuses an upload for being over an allowance (only the per-file ceiling exists). |
| **Attachment attach/remove events on instance history** (EO-004) | **Does not exist.** `upload/2`/`delete/2` never call into the instance history/timeline mechanism. `uploaded_by` is stored on the row but never surfaced as a history entry; `delete/2` records no "who removed it" fact anywhere durable. |
| **Approval record naming the reviewed attachment** (EO-005) | **Does not exist.** No approval/decision-recording code path references `instance_attachments`/`content_hash`/`attachment_id` anywhere in the codebase. |

### Frontend (`web/src/`)

Grepped `web/src/` exhaustively for `attachment` (case-insensitive) — **zero
hits**. There is no upload widget, no document list, no document viewer, no
remove button, no storage-usage figure, and no history/timeline rendering of
attachment events anywhere in the SPA. Nothing a dispatcher or ops manager
could navigate to at `https://qa.bizdala.com` would exercise any part of this
scenario. This is why no screens were driven or screenshotted for this
review — there is genuinely nothing to click.

## Relationship to REQ-386/387/388 (filed earlier today, same sweep)

Scenario `platform/attachment-cross-tenant-probe` (PW-09, reviewed earlier in
this same sweep, see `test/uat-reports/gui-review-2026-09-20-attachment-cross-tenant-probe.md`)
already filed REQ-386 (signed, expiring link for attachment byte content),
REQ-387 (frontend upload/list widget + document-viewer screen), and REQ-388
(audit logging for denied cross-tenant reads). REQ-387 in particular already
scopes the upload/list widget and document-viewer screen this scenario also
needs — the new requirements filed here build on top of REQ-387 rather than
duplicating it (REQ-392 explicitly depends on REQ-387 and only adds what it
doesn't cover: remove/delete UI, type/quota rejection messaging, the
storage-usage figure, and history/approval-attribution rendering).

## Requirements filed

Four new requirements added to `docs/requirements.yaml` (REQ-389 through
REQ-392), each independently sized and testable:

- **REQ-389** (ELIXIR-DEV, S6) — content-type allowlist enforcement on
  `upload/2`, refusing a video (or other disallowed kind) with a plain limit
  explanation, before size/scan checks, nothing half-attached. States
  explicitly why this does not reopen INV-a's no-MIME-sniffing guarantee.
- **REQ-390** (ELIXIR-DEV, S6) — per-tenant storage-quota tracking: a
  queryable usage figure, a configured allowance, and a new refusal path
  distinct from the per-file size ceiling.
- **REQ-391** (ELIXIR-DEV, S6) — attach/remove events recorded on instance
  history with attribution, and approval/decision records naming the
  attachment(s) present at decision time (snapshot-vs-live-reference choice
  explicitly deferred to that requirement's own design stage).
- **REQ-392** (FRONTEND-DEV, S8) — the remove-UI, rejection messaging,
  storage-usage display, and history/approval-attribution rendering that
  REQ-387 doesn't cover, plus extending the scenario's own named
  `pipeline_test` spec once all five backend/frontend requirements
  (REQ-387, 389, 390, 391, 392) have shipped.

## Not done in this pass

- No GUI flow driven (nothing exists to drive).
- No Playwright spec authored at
  `web/tests/e2e/pipelines/shipment-attach-delivery-note.pipeline.e2e.spec.ts`
  — authoring it now would be a blind/aspirational spec against a feature
  that doesn't exist, which is exactly the anti-pattern this GUI-review
  process exists to avoid. It should be authored as part of REQ-392, once the
  real screens exist to review.
- The scenario file's own stale NOTE (ISS-0526) was left untouched — the
  file's own header comment forbids editing the ported content below it
  except to keep it byte-identical to a re-pull of the upstream R-Co commit.
  The NOTE is still accurate (frontend attachment UI does not exist) and
  should be removed only once REQ-392 (and its dependencies) ship, per
  REQ-392's own acceptance criteria.
- No code defect was found to fix through a small branch/PR — every gap here
  is a genuine missing feature, not a bug in something that already claims to
  work.

## Cleanup

No shipment/instance was created and no attachment was uploaded against
`https://qa.bizdala.com` during this review (there was no screen to create one
through), so the scenario's own cleanup step (`cancel_open_instances`) has
nothing to act on.
