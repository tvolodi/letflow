# GUI review — platform-definition-promotion-conflict-rejected (PW-01)

**Run date:** 2026-09-20
**Agent:** ORCH (acting directly per an explicit no-further-delegation
instruction — the sibling `definition-promotion-approved` review's own
nested-fork attempt earlier today stalled without a result).
**Scenario:** `test/fixtures/uat/scenarios/platform/definition-promotion-conflict-rejected.yaml`
(`platform_workflow: PW-01`, `process_id: sys-definition-promotion`)
**Target:** `https://qa.bizdala.com` (environment: qa)

## Outcome: feature partially exists — backend conflict-detection is real and
## correct at both check points; the GUI screen this scenario's step 2 names
## does not exist and structurally cannot show a submit-time refusal even if
## it did. Permanent Playwright spec written, run for real, PASSES.

Per the dispatch's instructions: drove the real flow as far as the system
allows, fixed one small real defect found along the way (ISS-0735), filed the
larger GUI-visibility gap (ISS-0734) rather than fixing it in this pass, and
wrote/ran the permanent regression spec against what is actually real.

## 1. Backend machinery — confirmed present and correct by reading the code,
## then confirmed live

`Letflow.Definitions.PromotionConflict.reject_if_conflicts/4` is real, wired,
and called at **two** independent points, both confirmed live:

- **Submit time** (`lib/letflow/routers/promotions.ex`'s `do_submit/3`,
  R1): a conflicting submission is rejected *before*
  `PromotionReviewStore.insert_review/2` ever runs — no review row is
  created. This is the mechanism behind this scenario's step 1/EO-001.
- **Apply time** (`Letflow.Definitions.Promotion.do_promote_definition/7`,
  called from `apply_review/4`, R7): the SAME conflict check runs again right
  before the version-pointer swap, using the base_version frozen in the
  approved review's own `serialised_plan`. This is the mechanism behind this
  scenario's step 5/EO-004 — a stale approval genuinely cannot release,
  independent of anything the frontend does or doesn't show.

Both paths were exercised for real against `https://qa.bizdala.com`:

```
=== SUBMIT-TIME conflict (EO-001) ===
409 https://bpm.example.com/problems/promotion-conflict
conflicts: [{ process_key, base_version: "1.0.0", target_active_version: "2.0.0", target_definition_id }]

=== APPLY-TIME conflict (EO-004) — approval reused after target moved again ===
409 https://bpm.example.com/problems/promotion-conflict
conflicts: [{ process_key, base_version: "2.0.0", target_active_version: "4.0.0", target_definition_id }]
review context after: "status": "failed"   (never "applied")
```

EO-002 (nothing in the live workspace changes on a refusal) was confirmed
indirectly but concretely: re-submitting with `base_version` set to exactly
the conflict's own reported `target_active_version` succeeded cleanly (201),
proving the target had not moved between the refusal and the retry.

EO-003 (rebuild + resubmit + approve works normally) was confirmed via a real
GUI walkthrough — see §3.

## 2. This scenario's own step 2 has no reachable GUI — two independent,
## confirmed-live reasons (filed as ISS-0734)

The scenario's step 2 (`via: gui`, `expected_screen: "refused change review
detail"`) and EO-001's `verification.method: gui_screen` ask for a reviewer
screen showing the refused proposal. This does not exist today, for reasons
independent of each other:

1. **No row is ever created for a refused submission.** `do_submit/3`'s
   `with` chain short-circuits on the conflict error before
   `insert_review/2` runs. There is nothing for any screen to display, even
   in principle, for a submit-time refusal specifically.
2. **No review-queue/list screen exists in `web/` at all**, independent of
   (1). `web/src/router.tsx` has exactly one promotion-related route,
   `definitions/:id/promotions/:reviewId` (ISS-0730, direct-URL-only by
   design — confirmed again this run, unchanged). No `GET /promotions` list
   endpoint, no nav entry.

`web/src/components/promotions/ConflictRejectionAlert.tsx` is a fully-built
component whose own header comment says it exists for exactly this ("Displays
ConflictRejection details when a promotion returns HTTP 409
PROMOTION_CONFLICT") — confirmed via `grep -rln ConflictRejectionAlert
web/src` that it has **zero callers anywhere**. Its prop shape
(`target_version`/`source_change`/`target_change`) also doesn't match the
real backend 409 body (`base_version`/`target_active_version`, no
`source_change`/`target_change` fields) — wiring it in as-is would need a
reshape too, not just a route. Filed as **ISS-0734** (MAJOR — the protection
itself is real, this is a visibility/observability gap on top of it, not the
BLOCKER the scenario's own `on_fail.severity` names, since nothing is
silently unsafe; downgraded from the scenario's own severity for that
reason, noted explicitly in the filed issue).

## 3. Real GUI screens driven and read — the one screen this flow actually has

Opened the **rebuilt** (correct, non-conflicting) review at
`/definitions/:id/promotions/:reviewId` as `admin-user` (PLATFORM_ADMIN),
matching scenario step 4:

- Status badge: `pending_review`, state-machine diagram highlighting the
  right node, "Possible transitions: approved / rejected / superseded" —
  correct.
- Serialised plan + canonical plan JSON both rendered, one `Modified
  graph_node:n2` entry shown, plan digest shown and marked "Digest Verified"
  — matches what was actually submitted (assertable digest string compared
  byte-for-byte in the spec).
- Clicked **Approve** for real: status transitioned `pending_review` →
  `approved` on screen, Apply button enabled, row_version incremented
  (1 → 2) — all correct, screenshotted.

Both screenshots read by hand, not just checked for absence of errors — see
`web/tests/screenshots/pipelines/platform-definition-promotion-conflict-rejected-06-rebuilt-review-{pending,approved}.png`
(gitignored evidence, not part of the repo, same convention as the sibling
review).

## 4. Real defect found and fixed: ISS-0735 (frontend, MINOR, small)

`NonSkippableApprovalGate.tsx`'s `handleApply()` catch block classified
**any** HTTP 409 from `/apply` as a digest mismatch
(`err2.status === 409 || err2.code === 'PLAN_DIGEST_MISMATCH'` — the second
half was dead code; `err2.code` is actually the RFC 9457 problem `type` URL,
never that literal string). This meant EO-004's own real, correctly-enforced
protection — an apply-time conflict refusal — displayed the wrong message
("Plan digest mismatch... please review again") instead of naming the real
conflict, and discarded the `conflicts` detail the backend already sends.

Fixed in this same commit: added a specific
`err2.code?.endsWith('/promotion-conflict')` branch ahead of the generic 409
check, rendering a new `PromotionConflictError` inline message that names the
real `target_active_version` from `err.details.conflicts[0]` when present.
`tsc --noEmit` and `npm run build` both pass clean. **Not** re-verified
against a live redeployed QA frontend in this run (needs this fix's PR merged
and QA redeployed first — the old, buggy classification was confirmed live
via direct API inspection of the real 409 body shape, and the fix reads
exactly that shape, not a guess). See `docs/issues/ISS-0735.yaml`.

Sized under `ORCHESTRATOR.md` §10: one file
(`NonSkippableApprovalGate.tsx`), no new public function/module/`@spec`, no
migration, no supervision-tree file, no tenant-data path, and no test
currently asserts the old (wrong) behavior (`grep` confirms no test file for
this component exists yet) — qualifies for direct action, still routed
through its own branch/PR/CI/merge per the git-mechanics clarification in
that same section.

## 5. Known gap NOT fixed: EO-005, no audit trail on either refusal

Checked `GET /api/v1/audit` as both the source tenant (`bpm-default`) and
target tenant (`bilimbaga`) callers after both the submit-time and apply-time
refusals: no entry referencing the refused review or the rejected process key
in either. Same root cause as `ISS-0733` (no event append on any
non-success promotion path) — not filed as a new issue since this scenario's
own `on_fail.suggested_action` for EO-005 is `none` (recorded here, not
routed to WF-03).

## 6. A real, separate lesson from authoring this spec: plan-digest
## collisions across unrelated fixtures

While building the multi-version fixture chain this scenario needs, an
earlier draft used generic labels (`"Review 2.0.0"`, `"Review 3.0.0"`, not
folding in a per-run fixture id) and hit a genuine
`uq_promotion_review_active_digest` collision — `Letflow.Definitions.PromotionDigest.compute_plan_digest/1`
hashes only `plan.entries` (node id/label/attributes/change_kind), which
includes neither `process_key` nor `tenant_id`. A leftover **live**
(`:approved`, never applied) review from an earlier, interrupted debug run —
same generic label text, different process_key entirely — blocked a brand
new, unrelated submission with `"a live review for this plan digest already
exists"`. This is real, reproducible backend behavior, not a test-harness
bug, but it was a fixture-authoring mistake in this run, not a defect in the
system under test (real process definitions in practice won't have
byte-identical diff content across unrelated processes) — noted here for the
next spec author rather than filed as its own issue. The final spec always
folds the per-run fixture id into every node label (see the spec file's own
comment on `graphFor()`).

## 7. Scenario steps reached

| Step | Actor | Result |
|---|---|---|
| 1 (stale propose) | authoring_agent, `via: system` | **PASS** — real 409, named conflict, confirmed live and asserted in the spec (EO-001). |
| 2 (reviewer reads refusal) | reviewer, `via: gui` | **BLOCKED** — no reachable screen (ISS-0734); not simulated, not faked. |
| 3 (rebuild + resubmit) | authoring_agent, `via: system` | **PASS** — resubmitting on the refusal's own named `target_active_version` succeeds cleanly. |
| 4 (reviewer approves) | reviewer, `via: gui` | **PASS** — real GUI screen, real click, screenshotted, digest asserted. |
| 5 (amend + release with stale approval) | authoring_agent, (no `via` in the YAML; driven as system, matching steps 1/3 and EO-004's `system_state` verification method) | **PASS**, adapted: the system has no "amend an already-approved review in place" operation (no such endpoint exists) — the equivalent real race (an independent, unrelated promotion landing and moving the target between approval and apply) was driven instead, and the apply-time conflict re-check refused it for real, exactly as EO-004 requires. |

## 8. Expected outcomes

| EO | Verification | Result |
|---|---|---|
| EO-001 (named refusal, before anything live is touched) | `gui_screen` | **Substance PASS at the system level** (real 409, real named conflict) — **method not satisfiable**: no GUI screen exists to show it (ISS-0734). |
| EO-002 (live workspace untouched by the refusal) | `system_state` | **PASS** — confirmed by the clean resubmit at the refusal's own reported version. |
| EO-003 (rebuilt proposal reviewable/approvable normally) | `gui_screen` | **PASS** — real GUI screen, real approve click, confirmed on screen and in the spec's own digest assertion. |
| EO-004 (a stale approval cannot release a different target state) | `system_state` | **PASS** — confirmed live: apply refused with the real named conflict, review status is `failed`, target's active version is the one the independent promotion set, never touched by the failed review. The scenario's own evidence text ("returns to awaiting review") is not literally what happens — the review lands in the terminal `:failed` status, not back in `:pending_review`; a fresh review must be submitted to try again. The **substance** (approval not reusable, nothing released) holds; noted here as a real but non-blocking difference between the scenario's prose and the implemented state machine. |
| EO-005 (every refusal recorded for later audit) | `audit_event` | **FAIL**, known gap, not newly filed (scenario's own `on_fail.suggested_action: none`) — see §5. |

## 9. Permanent Playwright spec written and passing

`web/tests/e2e/pipelines/platform-definition-promotion-conflict-rejected.pipeline.e2e.spec.ts`
now exists, drives the real flow described above end to end (API for the
system-actor steps, real GUI clicks for the one real reviewer screen), and
asserts EO-001/EO-002/EO-003/EO-004's substance. Needed a new fixture actor,
`uat-promo-conflict-proposer` (`bpm-default` realm, PLATFORM_ADMIN) — the
sibling `promo-proposer-uat` fixture from the `-approved` scenario's own run
turned out to have no discoverable password (created in an earlier session,
never recorded anywhere retrievable), so rather than lose more time chasing
that account down, a fresh, dedicated one was created for this scenario and
its credential is read via `UAT_QA_PROMO_CONFLICT_PROPOSER_USERNAME`/
`UAT_QA_PROMO_CONFLICT_PROPOSER_PASSWORD` env vars.

Run for real against `https://qa.bizdala.com`:

```
Running 1 test using 1 worker
  ok 1 [chromium] › ...conflict-rejected.pipeline.e2e.spec.ts:162:3 ›
  Pipeline: platform-definition-promotion-conflict-rejected (PW-01) ›
  an out-of-date proposal is refused, rebuilt cleanly, and a stale approval
  cannot release a moved target (13.3s)
1 passed (16.0s)
```

## No password reproduced in this report

Credentials referenced only as env-var names throughout; the raw values used
to run this session live only in this session's own shell environment and
`ai-dala-infra`'s host-side secrets, never written to this repo.

## Files touched by this run

- `web/tests/e2e/pipelines/platform-definition-promotion-conflict-rejected.pipeline.e2e.spec.ts` (new)
- `web/src/components/promotions/NonSkippableApprovalGate.tsx` (ISS-0735 fix)
- `test/fixtures/uat/scenarios/platform/definition-promotion-conflict-rejected.yaml` (stale ISS-0527 note replaced with a current, accurate one)
- `docs/issues/ISS-0734.yaml` (new, open)
- `docs/issues/ISS-0735.yaml` (new, resolved)
- `test/uat-reports/gui-review-2026-09-20-definition-promotion-conflict-rejected.md` (this report)
