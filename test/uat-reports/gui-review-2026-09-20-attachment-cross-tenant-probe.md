# GUI review: attachment-cross-tenant-probe (PW-09)

Date: 2026-09-20
Reviewer: ORCH
Scenario: `test/fixtures/uat/scenarios/platform/attachment-cross-tenant-probe.yaml`
Severity class: high (cross-tenant document isolation, existence-probing resistance,
signed-link expiry, audit logging)

## Path taken

Path 2: verified against current source (and the absence of any frontend surface or
e2e spec to drive) that the scenario's own GUI-level steps cannot be executed today.
No browser session was driven against `qa.bizdala.com` — there is no document-viewer
screen, no attachment-upload widget, and no signed-link concept anywhere in `web/src/`
for a session to exercise. This matches the scenario file's own stale NOTE (ISS-0527),
which this pass re-verified from source rather than trusting.

Per this sweep's process, "if it genuinely doesn't exist: file it as a properly-sized
requirement/security issue, record BLOCKED in a review report, move on" — that is what
follows below. No code was changed; no branch other than this doc-only one was needed
for an actual fix, since nothing found here is a regression in existing behavior — the
gaps are unbuilt scope, not a defect in what's shipped.

## What was checked, and what each check showed

### 1. Backend attachment store (REQ-211/212, `status: done`)

Read `lib/letflow/repository/attachments.ex` and `lib/letflow/routers/instances.ex` in
full (the `GET/POST/DELETE /instances/:id/attachments[/:id]` routes and their handlers).

**Good news — this part is real and correctly built:**

- `Attachments.upload/2`/`list/2`/`get/2`/`delete/2` are all tenant-scoped via
  `opts[:prefix]`, structurally incapable of returning another tenant's row (the query
  never crosses Postgres schemas).
- `handle_get_attachment_content/3`'s helper, `fetch_scoped_attachment_content/3`
  (`lib/letflow/routers/instances.ex` ~line 1156), folds **four** distinct cases to the
  exact same `{:error, :not_found}` tuple, rendered via the same `Response.not_found(conn)`
  call: (a) a cross-tenant attachment id (not visible under the caller's own schema at
  all), (b) a cross-instance-same-tenant attachment id (exists, but
  `attachment.instance_id` doesn't match the path's `:id`), (c) a malformed/never-valid
  UUID (`:invalid_id`), and (d) a syntactically valid but never-issued UUID
  (`:not_found`). No branch introduces a different status code, header, or body shape.
  I read this code path specifically looking for exactly the class of subtle
  distinguishability bug this sweep found before (ISS-0736/ISS-0737 elsewhere) and did
  not find one here — the moduledoc explicitly documents this folding as deliberate
  design (design §5.1, AC5/AC6/INV-5), and the code matches the doc.
- **EO-001 and EO-002, at the API layer, are satisfied by what's already shipped.**

This is a case where the earlier BLOCKER pattern (a GUI implying a control that doesn't
enforce anything) does *not* repeat — the backend enforcement here is real and was
built carefully (explicit comments calling out the exact cross-tenant-probe concern
this scenario tests).

### 2. Signed-link / expiry mechanism

Grepped `lib/letflow/` exhaustively for `signed_url`, `presign`, and any
attachment-scoped `expires_in`/expiry concept: **zero hits.** The only `expire`-related
code anywhere in the codebase concerns OIDC tokens and exam sessions — unrelated
features. `handle_get_attachment_content/3` serves attachment bytes directly from a
plain authenticated `GET`, with no time bound at all: a valid session can fetch the
same attachment id indefinitely.

This means steps 4/5 and **EO-003 (expired-link message)** and part of **EO-004**
(re-fetch after expiry) describe a mechanism — a browser-visible link that is issued
once, expires quickly, and must be re-requested — that has never existed in this
codebase. Not a regression; never built.

### 3. Frontend GUI surface

Grepped `web/src/` exhaustively (case-insensitive) for `attachment`: **zero hits** in
any component, page, route, or API client. There is no document-viewer screen, no
upload widget on the task/instance detail pages, and no client for
`GET/POST/DELETE /instances/:id/attachments*` at all. The scenario's own
`pipeline_test` (`web/tests/e2e/pipelines/attachment-cross-tenant.pipeline.e2e.spec.ts`)
does not exist, confirmed via `ls`. Nothing exists for a browser session to drive.

### 4. Audit logging of probe attempts (EO-005)

Grepped `handle_get_attachment_content/3` and its helpers for any call into
`Letflow.Audit`: none. `Letflow.Audit`'s `audit_entries` table (REQ-195/196) is written
to only by mutation-shaped operations today — there is no existing precedent anywhere
in this codebase for auditing a *denied read*. A Vortex user's attempts against a
SwiftRoute attachment id (steps 2/3) would leave no trace in
`web/src/pages/admin/AuditLogPage.tsx` today.

## Disposition

BLOCKED — genuinely unbuilt on three independent axes (frontend GUI, signed-link
expiry, denied-read audit logging), on top of a correctly-built backend isolation
layer. Filed as three requirements rather than one, since they are independently
buildable and independently valuable:

- **REQ-386** (ELIXIR-DEV) — signed, time-limited link issuance + expiry enforcement
  for attachment content, without reopening the existence-probing gap REQ-211/212
  already closed. Depends on REQ-211/212 (done).
- **REQ-387** (FRONTEND-DEV) — the document-viewer screen and the permanent Playwright
  spec at this scenario's own `pipeline_test` path. Depends on REQ-386. Removes the
  stale NOTE (ISS-0527) once both REQ-386 and REQ-387 ship.
- **REQ-388** (ELIXIR-DEV) — audit-log entry for a denied cross-tenant/cross-instance
  attachment fetch, without introducing a new timing/response-shape side channel into
  the denied response itself. Depends on REQ-211/212 (done); independent of REQ-386/387.

No SECURITY-REVIEWER referral was needed for *this* pass, since no code changed — each
of REQ-386/388 explicitly requires SECURITY-REVIEWER sign-off before merge, per their
own acceptance criteria, when they're eventually built.

## Sibling-session note

Before merging this doc-only branch, `git pull --ff-only` picked up a concurrent
session's work cleanly (ISS-0737, REQ-384/385, and related frontend/e2e files for an
unrelated `tenant-switch-cache-isolation` scenario) — no conflicts, nothing to recover,
straightforward fast-forward.

## Spec status

No permanent Playwright spec was written — the feature it would exercise doesn't exist
yet (see REQ-387's own acceptance criteria, which is where that spec will be authored,
against a real shipped feature, once REQ-386/387 land). The scenario's stale NOTE
(ISS-0527) was left in place, since the feature it warns about is still not real.
