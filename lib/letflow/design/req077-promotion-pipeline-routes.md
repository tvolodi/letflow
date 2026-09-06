# REQ-077 — Promotion pipeline routes (S4)

PROVENANCE (historical, not current decision authority):
Ports six R-Co route modules as one requirement: `src/api/routes/promotion_review.zig`
(940 / 5 handlers), `promotions.zig` (288), `promotion_read.zig` (169),
`promotion_assertion.zig` (203), `promotion.zig` (111), `definition_rollback.zig` (133).

No implementation code below — signatures, route tables, status matrices, response-key
allowlists and test specs only.

> ## ✅ REQ-077 IS DONE (2026-08-26) — the blocker below is historical
>
> This design's original blocker was the absence of a production platform-event appender.
> That requirement shipped as **REQ-140** (`Letflow.EventStore.append_platform_event/2` +
> `Letflow.EventStore.PlatformEvents`), done 2026-08-23 (PR #597). REQ-077 itself was
> implemented in run `WF02-REQ077-20260826`: all ten routes (R1–R10, including the four
> previously blocked on the appender — R7 apply, R8 run-assertions, R9 rollback, R10
> ENV-03 promote) are live across `lib/letflow/routers/promotions.ex`,
> `definitions.ex`, and `tenants.ex`. All six acceptance criteria were independently
> re-verified PASS by RELEASE-VALIDATOR. See
> `docs/status/requirement_status.v4.yaml`'s REQ-077 `done` entry for the full run
> history, including two rework cycles (SECURITY-REVIEWER INV-8 nil-crash fix,
> TEST-RUNNER iso8601/DateTime crash fix).
>
> The paragraphs immediately below (originally the "IS BLOCKED" banner) are left as
> written for historical context on why the design was split from the appender work;
> they no longer describe REQ-077's current status.
>
> ~~Four of the ten routes (R7 apply, R8 run-assertions, R9 rollback, R10 ENV-03 promote)
> cannot be built until a separate, not-yet-drafted requirement lands: the
> platform-event-appender requirement (id TBD, proposed
> `depends_on: [REQ-023, REQ-024]`).~~ All four call a context function that
> `Keyword.fetch!`es `opts[:event_appender]`, and no production appender existed at design
> time (**F-5**). REVIEWER ruled: build it as Option (B) — a new
> `Letflow.EventStore` sibling entry point — **in its own requirement**, not inside this
> one (**§11 OQ-1**, resolved, with the full rationale and the three grounds for the split).
> That requirement became REQ-140, and REQ-077's `depends_on` gained it alongside REQ-072.
>
> ~~Consequence for acceptance criteria: AC1, AC2 and AC4 are unreachable, and AC5 is
> reachable for only three of its four cases, until that requirement ships.~~ All six ACs
> are now reachable and have been independently verified PASS.
>
> Everything else in this design is buildable and gate-verified. §4, §5, §6, §9 and §10 are
> unaffected.

---

## 0. Findings that changed this design (verified against source, not assumed)

Each of these was re-derived from the shipped source in this worktree and/or
`c:\Users\tvolo\dev\ai-dala\R-Co\`. Three of them contradict or materially refine the
premises this requirement was handed to me with; they are listed first, loudly, because
downstream agents will otherwise re-derive them the hard way.

### F-1 — Four of R-Co's six modules are unreachable dead code; two are wired

PROVENANCE (historical, not current decision authority):
`src/main.zig` imports exactly two of the six (`L90` `promotion.zig`, `L91`
`promotions.zig`). `promotion_review.zig`, `promotion_read.zig`,
`promotion_assertion.zig` and `definition_rollback.zig` are **not imported at all** and
no request can reach them. Concretely:

PROVENANCE (historical, not current decision authority):
| R-Co module/handler | Header-doc claimed path | Actually wired? | Evidence |
|---|---|---|---|
| `promotions.zig::handleCreatePromotionPlan` | `POST /api/v1/promotions` | **YES** | `main.zig:1567,1576-1577` (`resource=="promotions" and seg4.len==0 and method==.POST`) |
| `promotion.zig::handlePromotion` | `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name` | **YES** | `main.zig:1555-1557` (`resource=="tenants"`, `seg5=="promote"`, `seg6.len>0`) |
| `promotion_review.zig::handleSubmitPromotion` | `POST /api/v1/promotions` | **NO** | loses the path to `handleCreatePromotionPlan`; no other branch reaches it |
| `promotion_review.zig::handleGetPromotionContext` | `GET /api/v1/promotions/:id/context` | **NO** | `seg4.len != 0` → `main.zig:1580-1582` → 404 |
| `promotion_review.zig::handleApproveReview` / `handleRejectReview` / `handleApplyReview` | `POST /api/v1/promotions/:id/{approve,reject,apply}` | **NO** | same 404 fall-through |
| `promotion_read.zig::handleGetPromotion` | `GET /api/v1/promotions/{id}` | **NO** | branch requires `method==.POST` |
| `promotion_assertion.zig::handleRunAssertions` | `POST /api/v1/promotions/{review_id}/run-assertions` | **NO** | same 404 fall-through |
| `definition_rollback.zig::handleRollback` | `POST /api/v1/definitions/{process_key}/rollback` | **NO** | the `definitions` branch (`main.zig:650`) has `activate`/`deprecate`/`archive`/`export`/`validate` sub-arms and **no** `rollback` arm |

**Consequence for this design.** R-Co's *route table* is not a usable authority for five
of the ten routes here — the header doc-comments and handler bodies are. Where a handler's
own doc and its body disagree (several do; see F-4), the **body** wins, and the divergence
is called out. Same shape REQ-074 already hit and documented in
`Letflow.Routers.Identity`'s moduledoc for `handleListGroupMembers`/`handleRemoveGroupMember`.

### F-2 — The `POST /api/v1/promotions` collision, resolved (a first-class deliverable)

Two handlers claim the same path and do materially different things:

PROVENANCE (historical, not current decision authority):
| | `handleCreatePromotionPlan` (`promotions.zig:52`) | `handleSubmitPromotion` (`promotion_review.zig:72`) |
|---|---|---|
| body | `source_tenant_id`, `target_tenant_id`, `process_key` | the same three **plus required `base_version`** |
| does | computes the diff, returns it | computes the diff, runs the conflict re-check, computes the digest, **inserts a `promotion_reviews` row** |
| success | **200** `{entries, human_readable}` | **201** `{review_id, plan_digest}` |
| side effects | none (read-only preview) | one row inserted |
| wired | yes (`main.zig:1577`) | no |

**Resolution (deliberate, documented divergence from R-Co):**

* `POST /api/v1/promotions` → **submit** (`handleSubmitPromotion`'s semantics), 201.
* `POST /api/v1/promotions/plan` → **plan preview** (`handleCreatePromotionPlan`'s
  semantics), 200.

Rationale, in order of weight:

1. `POST` on a collection URI that returns `201` and creates a durable resource is the
   only one of the two that is REST-correct at `/promotions`. The other creates nothing.
2. R-Co's own *documentation* assigns `/promotions` to submit; only its route *table*
   (which never imported the module) assigns it to the preview. The doc-comment reflects
   design intent, the table reflects an unfinished wiring job (F-1).
3. The reviewed/gated pipeline (PRM-04/PRM-05) is the one this requirement's ACs are
   about — AC3 ("two tenants … same plan_digest each get their own review") and AC4
   (409 on re-approve) are meaningful only against submit. Preview is the subordinate
   operation and takes the subordinate path.
4. Nothing outside R-Co consumes either contract today (`web/` has no promotion client —
   this is a greenfield API surface), so there is no compatibility cost.

PROVENANCE (historical, not current decision authority):
**This must be stated in `Letflow.Routers.Promotions`' `@moduledoc` as a deliberate
divergence**, naming both R-Co handlers and both paths, so a reader diffing against
`promotions.zig` does not "fix" the preview back onto `/promotions`.

### F-3 — `:Unknown` is PLATFORM_ADMIN-only, not `:MetricsRead`-gated

My handoff stated that a promotion path with no `endpoint_policy_key/2` clause "falls
through to `:Unknown` whose `required_permission(:Unknown)` is `:MetricsRead`", implying
any role holding `:MetricsRead` could reach these routes. **That is not what happens.**
`Letflow.Api.Authorization.evaluate_access/2`'s `cond` short-circuits on
`endpoint == :Unknown` in its **first** branch: `:Unknown` is `Allow` for `PLATFORM_ADMIN`
and `Deny403` for everyone else. `required_permission(:Unknown) -> :MetricsRead` is
unreachable dead code on this path.

The current fallthrough behaviour is therefore **fail-closed and strict**, not permissive.
ELIXIR-DEV independently reached the same reading and raised the resulting design fork
(leave it at `:Unknown` vs. add promotion-specific policy keys); §4 settles it. Recording
the correction here because the wrong premise appears in this requirement's handoff and
would otherwise propagate into the implementation.

### F-4 — R-Co defects deliberately NOT ported

Called out so a reviewer diffing handler bodies does not read their absence as an
oversight. Each is a real behavioural divergence.

PROVENANCE (historical, not current decision authority):
| # | R-Co behaviour | Evidence | Letflow |
|---|---|---|---|
| D-1 | `handleGetPromotionContext` discards `actor` entirely (`promotion_review.zig:270` `_ = actor;`) — any caller knowing a review UUID gets the full stored plan, cross-tenant | `:270` | every route is auth-gated **and** `:prefix`-scoped (§3, §5) |
| D-2 | Same for `handleRejectReview` (`:489`), `handleGetPromotion` (`promotion_read.zig:55`), `handleRunAssertions` (`promotion_assertion.zig:59`) | as cited | same |
| D-3 | `created_at` in the context response is the hardcoded literal `"1970-01-01T00:00:00Z"` — `timestampToIso` (`promotion_review.zig:854-861`) discards its argument | `:854-861` | real `inserted_at`, ISO 8601, via the `iso8601/1` convention `Letflow.Routers.Tenants` already uses |
| D-4 | `handleRunAssertions` re-serialises `artifact` and then **discards it** (`:112` `_ = artifact_json;`), builds a hardcoded empty artifact (`:103-110`), and constructs the pool with `max_concurrent = 0` (`:121`) — the endpoint **can only ever return 503** | `promotion_assertion.zig:103-121` | the artifact is really decoded (§9.4) and the real application-supervised `Letflow.SandboxPool` is used (§7.5) |
| D-5 | `handleRunAssertions` returns **HTTP 200 with an error-envelope body** (`{"error":"ALREADY_RECORDED",…}`, no `run_id`) on the idempotent-repeat path (`:133`) — a client cannot distinguish it from success by status, and it violates this requirement's own AC2 | `:133` | the repeat returns the **identical** success status and body as the first call (§8.1) |
| D-6 | `main.zig` hardcodes `.role = .PLATFORM_ADMIN` (`:1571`, `:1497`) and takes `user_id` from the unauthenticated `x-bpm-user-id` header (`:302-307`), making `handleApproveReview`'s self-approval gate trivially spoofable | `main.zig` as cited | roles come from the verified bearer token via `Letflow.Plugs.AuthPipeline` / `Authorization.roles_from_strings/1`; `actor_id` from `conn.assigns.auth_context.user_id` (§4.4) |
| D-7 | Error envelopes are inconsistent: five modules use `{"error":"UPPER_SNAKE","message":…}`, `promotion.zig` uses `{"error":"lower_snake"}` with an optional `detail` and no `message` | `promotion.zig:15-19` | one RFC 9457 problem document everywhere, via `Letflow.Api.Response` (REQ-066) |
| D-8 | `handleApproveReview` / `handleRejectReview` / `handleApplyReview` return **400** `INVALID_REVIEW_TRANSITION` for an illegal state transition (`:443`, `:539`, `:640`) | as cited | **409** — AC4 explicitly requires a 409-class problem document (§6) |
| D-9 | `plan.human_readable` (`promotions.zig:165-168`) is a domain-computed prose rendering of the plan | `promotions.zig` | **not ported** — `PromotionPlan.t()` has no such field and computing one is a domain feature, not a route concern. Response omits the key. **OQ-6.** |

### F-5 — There is no production `event_appender` anywhere in `lib/`, and it gates FOUR routes, at three different severities

`grep -rn "event_appender" lib/ --include=*.ex` finds only the three definitions of the
opt (`promotion.ex`, `definitions.ex`) and one comment. Every one is `Keyword.fetch!/2`'d
with **no default**, deliberately.

`Letflow.TenantProvisioning`'s `@platform_event_type_seed_attrs` comment states it
outright: `"DEFINITION_PROMOTED"`, `"DEFINITION_VERSION_ROLLED_BACK"` and
`"PROMOTION_ASSERTION_TEARDOWN_FAILED"` are **deliberately unseeded** because no production
writer exists. And a naive appender does not work:
`Letflow.EventStore.append/2`'s `active_instance_guard/3` hard-fails with
`{:error, :instance_not_started}` unless `attrs[:instance_id]` names an existing
`instance_projections` row, while `EventStore.platform_instance_id/0`
(`"00000000-0000-0000-0000-000000000001"`) deliberately has none — the events migration
says so in its own header (`20260816120001_create_events.exs:44`, "Never inserted into
instance_projections").

#### F-5.1 — Which routes are affected: R7, R8, R9 **and R10** (four, not two)

An earlier revision of this design scoped this to R7 and R9 only. That was wrong in two
places, both corrected here:

* **R8 is affected**, because `apply_promotion_assertion_rerun/6` reads the opt
  **eagerly and unconditionally** — `definitions.ex:805-806`, the fourth and fifth lines
  of the function body, before the idempotency claim and before any branch:
  ```
  prefix = Keyword.get(opts, :prefix)
  event_appender = Keyword.fetch!(opts, :event_appender)
  ```
  The appender is only *called* on the teardown-failure path, but it must be **present**
  or the function raises `KeyError` on every request, including the happy path. Its own
  `@doc` (`:780`) states the no-default stance explicitly.
* **R10 is affected**, because §9.5's `promote_active_definition/5` carries the same
  `promote_opts()` as `promote_definition/3`, in which `event_appender` is
  `Keyword.fetch!`'d.

#### F-5.2 — The three severities, which are NOT the same

This distinction is the difference between "REQ-077 cannot ship" and "REQ-077 ships with
one disclosed gap," so it is stated per route rather than in aggregate.

**Severity 1 — R9 needs a *real* appender: it surfaces `event_id` in a client-visible
body.** §7.6's `rollback_map/1` emits `"event_id"`, and `finish_rollback/8`
(`definitions.ex:1288-1330`) additionally feeds that id into
`supersede_matching_review/4`, which persists it in the `promotion_reviews.superseded_by`
column. A stub appender returning a fabricated UUID would put a fabrication in both a
response field and a durable audit column. **This is what disqualifies option (C) in
§11's OQ-1.**

**Severity 1 — R7 is worse than a missing event; it would make the route lie about a
durable state change.** `append_promotion_event/9` (`promotion.ex:302-338`) runs **after
the version-pointer transaction has committed** and propagates `{:error, _}` unchanged as
`promote_definition/3`'s own result. So with a stub appender: the target definition is
durably `:active`, `apply_review/4` (§9.3 step 4) sees the error and marks the review
`:failed`, and the client receives a 500 — for an operation that succeeded. The natural
client retry then hits `:duplicate_version` → 409. `finish_rollback/8` has the identical
structure for R9 (`definitions.ex:1288-1330`). A route that reports failure for a
committed write is worse than a route that is unavailable.

**Severity 2 — R8 is the least damaging of the four, but it is still blocked.** The
mechanics are the mildest: `apply_teardown_precedence/7` has exactly three clauses
(`definitions.ex:1702-1758`), and only the third — the `{:error, release_reason}`
teardown-failure clause — calls the appender at all; the `:not_attempted` and `:ok`
clauses return `{pre_teardown_status, nil, true}` without touching it. And when that third
clause does call it, `append_teardown_failure_event/6` **absorbs** the result
(`definitions.ex:1782-1789`, `{:error, _reason} -> false`), flipping only
`teardown_event_appended` — a field §7.5's 6-key response allowlist already excludes. So a
failing appender is invisible to the client and cannot corrupt a response.

**That is not sufficient to ship R8 without a real appender.** The tempting move — have
R8's handler hardcode an appender that returns
`{:error, :platform_event_writer_unavailable}`, since nothing observable depends on it —
is **option (C) in different clothing, and is rejected for the same reason**:

* On the teardown-failure branch it **silently discards a real
  `PROMOTION_ASSERTION_TEARDOWN_FAILED` event** — the one event type that exists
  specifically to make an otherwise-invisible infrastructure failure visible to operators.
  A sandbox that failed to tear down is a leaked schema; losing its audit record is a real
  operational loss, not a bookkeeping one.
* **"The gap exists today anyway, so it does not widen" is false.** R8 does not exist
  today, so nothing is dropped, because nothing runs. Shipping R8 with a stub creates a
  **new** live path on which a genuine production teardown failure loses its audit record.
* A hardcoded stub on a production handler is easy to forget to unwire once the real
  appender lands.

**Distinguish this from the existing, legitimate test injection.**
`promotion_assertion_rerun_test.exs`'s `recording_event_appender/1` /
`exploding_event_appender/0` call `apply_promotion_assertion_rerun/6` **directly** — a unit
test exercising a context module's documented, caller-injected extension point. That is
correct and stays. What is rejected is a **route handler** supplying a fixed value for
`opts[:event_appender]` on a real request path. The injection point is the same; the caller
and the consequences are not.

**Consequence: AC2 is gated on the platform-event-appender requirement, not independent of
it.** R8 is the only route AC2 exercises. §8.1's *mechanism* for AC2 is unaffected and
remains correct; only its reachability changes. See §11's AC-reachability table.

See §11's OQ-1, which is **resolved**, not open.

### F-6 — AC6's grep path does not cover the files AC6 is about

AC6 says: *"confirmed by grep for `Repo.` in `lib/letflow/api/` returning no hit in these
modules."* The route modules this requirement writes live in **`lib/letflow/routers/`**,
not `lib/letflow/api/` (REQ-070 decomposition). Running AC6's literal grep would pass
vacuously. §10 states the greps that actually verify the property, over both directories.

---

## 1. Summary of composition — the full route table

Ten routes across three sub-routers. "Letflow path" is the full path under `/api/v1`;
"router path" is what the `Plug.Router` macro declares after `forward/2` strips the mount.

PROVENANCE (historical, not current decision authority):
| # | Method | Letflow path | Router path | Sub-router | Handler | Context fn(s) | Policy key | Success | Response body keys | R-Co source |
|---|---|---|---|---|---|---|---|---|---|---|
| R1 | POST | `/promotions` | `/` | `Letflow.Routers.Promotions` | `handle_submit/2` | `PromotionPlan.compute_promotion_plan/5` → `PromotionConflict.reject_if_conflicts/4` → `PromotionDigest.compute_plan_digest/1` → `PromotionReviewStore.insert_review/2` | `:Unknown` (§4) | **201** | `review_id`, `plan_digest` | `promotion_review.zig:72-245` (`:238-242`, `:244`) |
| R2 | POST | `/promotions/plan` | `/plan` | same | `handle_plan/2` | `PromotionPlan.compute_promotion_plan/5` | `:Unknown` | **200** | `entries` | `promotions.zig:52-175` (`:139-171`, `:174`) |
| R3 | GET | `/promotions/:id` | `/:id` | same | `handle_get_assertion_run/2` | `PromotionReviewStore.get_review/2` **(NEW §9.1)** → `Definitions.get_latest_assertion_run/2` **(NEW §9.2)** | `:Unknown` | **200** | `assertion_run` (object or `null`) | `promotion_read.zig:49-156` (`:79-83`, `:102-149`) |
| R4 | GET | `/promotions/:id/context` | `/:id/context` | same | `handle_context/2` | `PromotionReviewStore.get_review/2` **(NEW §9.1)** | `:Unknown` | **200** | 9 keys, §7.2 | `promotion_review.zig:264-341` (`:321-337`, `:340`) |
| R5 | POST | `/promotions/:id/approve` | `/:id/approve` | same | `handle_approve/2` | `PromotionReviewStore.approve_review/4` | `:Unknown` | **200** | `review_id`, `status` (`"approved"`) | `promotion_review.zig:371-468` (`:461-465`, `:467`) |
| R6 | POST | `/promotions/:id/reject` | `/:id/reject` | same | `handle_reject/2` | `PromotionReviewStore.reject_review/3` | `:Unknown` | **200** | `review_id`, `status` (`"rejected"`) | `promotion_review.zig:482-558` (`:551-555`, `:557`) |
| R7 | POST | `/promotions/:id/apply` | `/:id/apply` | same | `handle_apply/2` | `Promotion.apply_review/4` **(NEW §9.3)** | `:Unknown` | **200** | `review_id`, `status` (`"applied"`) | `promotion_review.zig:580-664` (`:657-661`, `:663`) |
| R8 | POST | `/promotions/:review_id/run-assertions` | `/:review_id/run-assertions` | same | `handle_run_assertions/2` | `PromotionArtifact.from_json/1` **(NEW §9.4)** → `Definitions.apply_promotion_assertion_rerun/6` | `:Unknown` | **200** / **422** (§7.5) | `run_id`, `status`, `assertions_passed`, `assertions_failed`, `failing_assertion_ids`, `sandbox_id` | `promotion_assertion.zig:52-180` (`:145-170`, `:177`, `:179`) |
| R9 | POST | `/definitions/:process_key/rollback` | `/:process_key/rollback` | `Letflow.Routers.Definitions` (§2.3) | `handle_rollback/2` | `Definitions.rollback_definition_version/4` | `:Unknown` | **200** | `definition_id`, `version`, `rolled_back_from_version`, `superseded_review_id`, `event_id` | `definition_rollback.zig:41-118` (`:96-114`, `:117`) |
| R10 | POST | `/tenants/:test_tenant_id/promote/:process_key` | `/:test_tenant_id/promote/:process_key` | `Letflow.Routers.Tenants` (§2.4) | `handle_promote/2` | `Promotion.promote_active_definition/5` **(NEW §9.5)** | `:Unknown` | **201** | `definition_id`, `version`, `status`, `warnings` | `promotion.zig:22-96` (`:70-91`, `:95`) |

PROVENANCE (historical, not current decision authority):
All six R-Co modules are covered (AC1): `promotion_review.zig`→R1,R4,R5,R6,R7;
`promotions.zig`→R2; `promotion_read.zig`→R3; `promotion_assertion.zig`→R8;
`definition_rollback.zig`→R9; `promotion.zig`→R10.

**No `Jason.Encoder` derivation over any Ecto struct appears anywhere in this design.**
Every response body is a hand-built map with the literal key set listed, per §7.

**The `:Unknown` policy key in column 8 is a deliberate decision, not an unhandled
fallthrough — §4 states why in full.** Every route in this table is PLATFORM_ADMIN-only.

---

## 2. Mount plan

### 2.1 `/promotion` → `/promotions`, and the module renames with it

`Letflow.Plugs.ApiPipeline` currently declares
`forward("/promotion", to: Letflow.Routers.Promotion)`, pointing at a stub whose only
clause is `match _ do Response.not_found(conn) end`.

**Change both the mount and the module name:**

```
# lib/letflow/plugs/api_pipeline.ex
forward("/promotions", to: Letflow.Routers.Promotions)
```
with `lib/letflow/routers/promotion.ex` renamed to `lib/letflow/routers/promotions.ex`
and `Letflow.Routers.Promotion` renamed to `Letflow.Routers.Promotions`.

Justification:

* **Nothing breaks.** `grep -rn "Routers.Promotion"` over the whole worktree returns
  **two code hits** — `lib/letflow/plugs/api_pipeline.ex:44` (the `forward/2` line) and
  `lib/letflow/routers/promotion.ex:1` (the stub's own `defmodule`) — plus **two stale
  documentation references**, `req070-router-decomposition.md:131` and `:200`, which the
  paragraph below already requires updating. **Zero test references, zero other callers.**
  The stub serves no route, so no URL contract exists to preserve.
PROVENANCE (historical, not current decision authority):
* **`/promotions` is R-Co's path** (`main.zig:1567`, and all six modules' header docs).
  Keeping `/promotion` would diverge every path in §1 from R-Co for no reason, and would
  make `POST /promotion` read as an action rather than a collection.
* **Plural matches the sibling convention** already set by `Letflow.Routers.Tenants`
  (`/tenants`), `Instances` (`/instances`), `Definitions` (`/definitions`), `Tasks`
  (`/tasks`). `Promotion`/`/promotion` was the odd one out.
* The `/promotion` forward is **removed**, not kept alongside — two mounts for one
  subsystem is exactly the "two divergent paths to the same thing" shape REQ-075 §7.1
  argued against for tenant creation. There is no deprecation window to honour because
  there was never a served route.

**`lib/letflow/design/req070-router-decomposition.md` must be updated** — its table row
(`:131`) and its `forward` listing (`:200`) both name `/promotion`/`Letflow.Routers.Promotion`.
Leaving them stale would make the decomposition design doc lie about the shipped mount
table. Doc edit only, no behaviour change; it belongs in this requirement's commit (or
DOC-UPDATER's WF-02 Step 5 — either, but it must not be dropped).

### 2.2 Path shapes inside `Letflow.Routers.Promotions`

```
post "/",                          -> handle_submit
post "/plan",                      -> handle_plan
get  "/:id",                       -> handle_get_assertion_run
get  "/:id/context",               -> handle_context
post "/:id/approve",               -> handle_approve
post "/:id/reject",                -> handle_reject
post "/:id/apply",                 -> handle_apply
post "/:review_id/run-assertions", -> handle_run_assertions
match _,                           -> Letflow.Api.Response.not_found(conn)
```

No ambiguity: `POST /plan` is a one-segment POST and there is no `post "/:id"` route, so
the two cannot collide regardless of declaration order. Declare `post "/plan"` **before**
the two-segment `post "/:id/…"` clauses anyway — `Plug.Router` matches top-down, and an
explicit literal ahead of any pattern is the cheap, order-independent-looking form.

The trailing `match _` (404) is retained from the stub — every other sub-router has it,
and it is what makes an unrouted promotion path indistinguishable from a nonexistent
review (§5).

### 2.3 R9 (rollback) lives in `Letflow.Routers.Definitions` — one delimited route

PROVENANCE (historical, not current decision authority):
R-Co's path is `POST /api/v1/definitions/{process_key}/rollback`
(`definition_rollback.zig:3,31`). `Letflow.Plugs.ApiPipeline` already forwards
`/definitions` to `Letflow.Routers.Definitions`, a stub reserved for REQ-081/082.
`Plug.Router` cannot have two `forward/2` declarations for the same prefix, so the options
are exactly two: add the route to that stub, or invent a non-R-Co path.

**Decision: add the one route to `Letflow.Routers.Definitions`.** Inventing e.g.
`POST /promotions/rollback/:process_key` to avoid touching another requirement's stub would
put a definitions-scoped operation under a promotions mount **and** diverge from R-Co for a
purely organisational reason — worse on both counts.

**Ownership boundary, stated as a build requirement.** `Letflow.Routers.Definitions`'
`@moduledoc` MUST carry this text in substance:

PROVENANCE (historical, not current decision authority):
> This module is REQ-081/082's. It contains exactly **one** route contributed by REQ-077 —
> `POST /:process_key/rollback` (PRM-08, ports `src/api/routes/definition_rollback.zig`) —
> placed here only because `Letflow.Plugs.ApiPipeline` forwards `/definitions` here and
> `Plug.Router` permits one forward per prefix. REQ-081/082 owns every other route under
> `/definitions` and must not treat this one as precedent for its own design, nor remove
> it. Its handler, validation schema and response allowlist are specified in
> `lib/letflow/design/req077-promotion-pipeline-routes.md` §7.6.

The stub's `match _` 404 fallback stays exactly as it is.

### 2.4 R10 (ENV-03) lives in `Letflow.Routers.Tenants` — one delimited route

PROVENANCE (historical, not current decision authority):
Same reasoning: R-Co's path is `POST /api/v1/tenants/:test_tenant_id/promote/:definition_name`
(`promotion.zig:3`, wired at `main.zig:1555-1557`) and `Letflow.Routers.Tenants` (REQ-075)
already owns `/tenants`. Its `match _` currently 404s everything unmatched, so the route
must be declared there or it is unreachable.

`Letflow.Routers.Tenants`' `@moduledoc` gains the same ownership-boundary paragraph, plus
one extra sentence that matters for REQ-075's own AC6 risk statement:

> REQ-075's "these six handlers operate on the global `tenants` table, entirely outside
> REQ-072's `:prefix`-scoping" statement applies to those six handlers only. REQ-077's
> `POST /:test_tenant_id/promote/:process_key` is **not** one of them: it is
> `:prefix`-scoped like every other S4 route (the target tenant is the caller's own, from
> `Letflow.Api.Context.scoped_repo_opts/1`).

PROVENANCE (historical, not current decision authority):
**R-Co's path segment is `:definition_name`; Letflow's is `:process_key`.** Same value —
`promotion.zig:29-34` passes `seg6` to `promoteDefinition` as the definition name, and
Letflow's whole promotion stack calls that value `process_key`
(`PromotionPlan.compute_promotion_plan/5`, `PromotionConflict.reject_if_conflicts/4`,
`ProcessDefinition.name`). Renaming the path *parameter* (the URL itself is byte-identical)
keeps one vocabulary. Stated so nobody reads it as a different concept.

### 2.5 Shared `with_authorized_scope/4` — a fourth copy, flagged not resolved

`Letflow.Routers.Identity` and `Letflow.Routers.Tenants` each carry their own private
`with_authorized_scope/4` (`identity.ex:187-213` is the reference shape). This design needs
it in three routers, which would make four copies.

**This design follows the existing precedent (a private copy per router) rather than
extracting a shared module**, because extracting it would change two already-`done` modules
for a reason this requirement's ACs do not name — the scope-creep shape
`.claude/agents/elixir-dev.md` rules out. **Flagged as OQ-5**: four copies is past the point
where the duplication is obviously cheaper than the abstraction, and REVIEWER may reasonably
rule the other way. If so, the extraction is a separate change, not a silent addition here.

---

## 3. The ordering invariant every handler obeys (AC5, AC6, INV-1)

Every one of R1–R10, without exception, in this exact order:

1. **`Letflow.Api.Context.scoped_repo_opts(conn)`** — `{:error, _}` →
   `Response.internal_error(conn)` (500). §3.1. No `Repo` call has happened.
2. **Path-parameter UUID pre-validation** (§3.2), for R3–R8 and R10.
3. **`Authorization.evaluate_access/2`** against the route's policy key (§4).
   `:Deny403` → `Response.forbidden(conn, "insufficient permissions")`, return
   immediately. Still no `Repo` call.
4. **Request-body validation** (§8.4) via `Letflow.Api.Validation.validate/2`.
   `{:errors, errs}` → `Response.send_problem(conn, Validation.problem(errs))` (422).
   Still no `Repo` call.
5. **The call(s) into a context module**, threading `opts` (the `[prefix: …]` keyword
   fragment from step 1) as the `opts` argument.
6. **Map the tagged result to a status + hand-built body** (§5, §6, §7).

Steps 1–4 complete before any database access on every path, including pre-fetch reads.
This is the discipline `Letflow.Routers.Identity`'s moduledoc already states ("no `Repo`
call of any kind before this point or after this branch") and it is what makes §5's 404
guarantee cheap to verify.

### 3.1 REQ-072 OQ-2, settled for these ten routes — by following precedent, not re-deciding

| `scoped_repo_opts/1` result | Route response |
|---|---|
| `{:ok, prefix: schema}` | proceed to step 2 |
| `{:error, :missing_auth_context}` | **500** `Response.internal_error(conn)` |
| `{:error, :invalid_tenant_id}` | **500** `Response.internal_error(conn)` |

`Letflow.Api.Context`'s own `@doc` leaves the status choice as route-specific policy
(REQ-072 OQ-2). It is already settled in practice: `lib/letflow/routers/identity.ex:188-190`
maps `{:error, _}` to `Response.internal_error/1`, and REQ-074/075 followed. This design
follows the same precedent rather than opening the question again.

Both are 500 and not 401/403 because by the time a request reaches a sub-router both are
*server* faults: `Letflow.Plugs.AuthPipeline` runs ahead of every forward in
`Letflow.Plugs.ApiPipeline` and has already rejected unauthenticated requests, so a missing
`auth_context` here means the pipeline is misconfigured, not that the caller did anything
wrong. `Response.internal_error/1` is zero-detail by construction (REQ-066 §0.4, INV-4), so
neither case leaks which of the two fired.

### 3.2 Path-parameter UUID pre-validation — required, and it is also a crash fix

`PromotionReviewStore.get_review/2` (§9.1), `approve_review/4`, `reject_review/3` and the
`Repo.get(PromotionReview, id, …)` inside `transition/6` all receive the path segment
directly as a `:binary_id`. **A non-UUID path segment raises `Ecto.Query.CastError`, not a
tagged error** — so `GET /api/v1/promotions/not-a-uuid/context` would 500 or crash rather
than 404.

Every handler taking a UUID-shaped path parameter (R3–R8's `:id`/`:review_id`, R10's
`:test_tenant_id`) therefore runs, at step 2:

```
Ecto.UUID.cast(id)
  :error       -> Letflow.Api.Response.not_found(conn)   # 404, identical to §5's not-found
  {:ok, _uuid} -> proceed
```

**404, never 400.** A syntactically-invalid id cannot name a resource in any tenant, so
"malformed" and "does not exist" are the same fact from the caller's side; returning 400 for
one and 404 for the other hands a prober a free oracle for "is this id-shaped string even a
candidate," the same class of signal INV-5 forbids. This is route-layer *input parsing*, not
domain logic, so it does not violate the delegate-to-a-context-module rule — and §9.1/§9.2
specify the same defensive cast inside the new context functions, so a future non-HTTP
caller cannot trip the crash either.

R9's `:process_key` and R10's `:process_key` are free-form strings
(`process_definitions.name` is `field(:name, :string)`), so there is nothing to pre-validate;
neither is ever interpolated into SQL — every read goes through Ecto's parameterised query
building.

---

## 4. Authorization — DECISION: no change to `Letflow.Api.Authorization` (Option A)

### 4.1 The decision

**Every route in §1 resolves to `endpoint_policy_key/2`'s existing catch-all clause,
`:Unknown`, and is therefore PLATFORM_ADMIN-only.** This design adds:

* **no** `endpoint_policy_key/2` clauses,
* **no** `endpoint_policy_key/0` values,
* **no** `permission/0` values,
* **no** `required_permission/1` clauses,
* **no** entry to any `role_allows?/2` list.

`lib/letflow/api/authorization.ex` is **not modified by REQ-077 at all**.

This overrides my own earlier working position (which added two permissions and five policy
keys) after ELIXIR-DEV surfaced the fork and I re-weighed it against §4.2's evidence. The
deciding argument is §4.2 point 4, which neither of us had raised.

### 4.2 Why Option A wins on evidence

PROVENANCE (historical, not current decision authority):
1. **It matches R-Co's actual effective behaviour.** R-Co performs no finer-grained
   promotion permission check at the route layer at all: `main.zig:1571` constructs the
   actor for the `promotions` resource with `.role = .PLATFORM_ADMIN` hardcoded (`:1497`
   likewise for `tenants`). The only real gates are inside the domain layer
   (`promotion_plan.zig:191-193,217`'s `promotion.submit` query, `rollback.zig:63,74-75`'s
   `platform.admin` query). Porting "PLATFORM_ADMIN at the route layer" is faithful, not a
   narrowing.
2. **It is the strictest available gate.** `evaluate_access/2`'s `:Unknown` branch is
   `Allow` only for `PLATFORM_ADMIN` and `Deny403` for every other role, including a caller
   with no roles at all. Widening later is a one-line matrix change; an over-wide grant
   shipped now is a security regression that has to be found first.
3. **It is zero scope creep into a gate-approved module.** Option B would widen two closed
   sets (`@type permission`, `@type endpoint_policy_key`) and the `@permissions` list in
   REQ-069's shipped module, for routes whose ACs never ask for role differentiation.
   `CLAUDE.md`'s "don't add abstractions the current requirement doesn't need yet" and
   REVIEWER's scope-creep gate both point the same way.
4. **It substantially defuses this design's largest security gap (§7.9/OQ-2), which Option
   B would leave wide open.** `PromotionPlan.compute_promotion_plan/5`'s only available
   `permission_checker` is `default_permission_checker/2`, which returns `true`
   unconditionally — meaning R2 (`POST /promotions/plan`) lets its caller read the full
   graph, edges, service bindings and module refs of a definition in **any** tenant by
   passing that tenant's id as `source_tenant_id`. Under Option B's proposed
   `:PromotionsSubmit` grant, `PROCESS_DESIGNER` would hold that cross-tenant read — a
   genuine INV-1 exposure to a non-admin role. Under Option A, the only role that can reach
   it is `PLATFORM_ADMIN`, which already has legitimate cross-tenant reach through REQ-075's
   `:TenantsManage` routes. **Option A converts OQ-2 from a live cross-tenant leak into a
   documented gap with no non-admin reachability.** That is the decisive point.

### 4.3 The consequence is deliberate, and must be pinned so it reads that way

`:Unknown` is a *catch-all* clause, so relying on it for a security decision leaves the
source unable to distinguish "we chose PLATFORM_ADMIN-only" from "we forgot to add a
clause." Two build requirements close that gap without touching REQ-069:

PROVENANCE (historical, not current decision authority):
1. **`Letflow.Routers.Promotions`' `@moduledoc` states it in substance:** *every route in
   this module resolves to `Letflow.Api.Authorization.endpoint_policy_key/2`'s catch-all
   `:Unknown` clause, deliberately and not by omission.* `evaluate_access/2`'s **first**
   `cond` branch makes `:Unknown` an `Allow` for `PLATFORM_ADMIN` and a `Deny403` for every
   other role — the strictest gate available, matching R-Co's own effective behaviour
   (`main.zig:1571` hardcodes `.role = .PLATFORM_ADMIN` for the `promotions` resource). No
   promotion-specific policy key or permission is added to `Letflow.Api.Authorization` by
   REQ-077. `required_permission(:Unknown) -> :MetricsRead` exists but is unreachable from
   `evaluate_access/2` and is **not** what gates these routes. The same paragraph goes into
   `Letflow.Routers.Definitions` and `Letflow.Routers.Tenants` for R9 and R10.
2. **A pinning test (§12.8)** asserts both halves directly: that
   `endpoint_policy_key("POST", "/promotions") == :Unknown` (and the same for every other
   path template in §1), and that `evaluate_access/2` returns `:Deny403` for a
   `PROCESS_DESIGNER`/`PROCESS_OPERATOR`/`TASK_WORKER` context and `:Allow` for
   `PLATFORM_ADMIN`. If a later requirement adds a promotion clause to
   `Letflow.Api.Authorization`, that test fails and forces the change to be deliberate,
   rather than silently re-gating ten routes.

Together these make Option A auditable in exactly the way an explicit clause would be, at
zero cost to another requirement's module.

**`AccessContext` carries only `user_id` and `roles` (INV-2, structural).** No promotion
route's authorization decision can vary by which review id, tenant id or process_key is in
the path, because `evaluate_access/2` has no parameter through which such a value could
arrive. Nothing here needs that property added — it falls out of reusing the existing pure
function unchanged.

### 4.4 `actor_id`

PROVENANCE (historical, not current decision authority):
Every context call needing an actor passes `conn.assigns.auth_context.user_id` — never a
body field, never a header. R-Co's `handleApproveReview` explicitly rejects an `approved_by`
body field for this reason (`promotion_review.zig:398-406`, 422 `UNKNOWN_FIELD`). Letflow
gets the same guarantee **structurally rather than by check**:
`Letflow.Api.Validation.validate/2` returns `Map.take(body, declared_field_names)`, so a
field not in the schema cannot reach the handler's `attrs` at all. The 422 `UNKNOWN_FIELD`
response is therefore **not ported** — stronger by construction, weaker in diagnostics.
State this in the moduledoc (§7.8) so its absence is not read as a dropped check.

---

## 5. The 409-vs-404 decision matrix (INV-5, AC5)

### 5.1 Why cross-tenant and nonexistent are byte-identical, structurally

`Letflow.Api.Context.scoped_repo_opts/1` reads **only**
`conn.assigns[:auth_context][:tenant_id]` — never a path, query or header value (its own
`@doc`: "not 'read and then discarded,' literally never touched"). It returns
`[prefix: schema_name]` for the caller's own tenant schema and nothing else.

Every review lookup in this design bottoms out in
`Repo.get(PromotionReview, review_id, prefix: <caller's schema>)`. `promotion_reviews`
carries **no `tenant_id` column at all** — REQ-064 / Decision 0006 D2 dropped it, because
the Postgres schema the row lives in *is* the tenant identity. Therefore:

> Another tenant's review is not "found and then filtered out." It is not in the schema
> being queried. The lookup yields `nil` for exactly the same reason, through exactly the
> same code path, as for a review id that was never issued to anybody.

There is **no cross-tenant existence check anywhere in this design, and there must not be
one**: a second, unscoped read to detect "exists elsewhere" would (a) reintroduce the
distinguishability INV-5 forbids, (b) add a round-trip on one path and not the other, which
is itself the timing signal INV-5's verification note calls out, and (c) be a cross-tenant
read — an INV-1 violation in its own right.

The response is `Letflow.Api.Response.not_found(conn)`, which takes **no detail argument**
(REQ-066 §0.4: `Error.not_found/0` is zero-arity, `@not_found_detail` is a module
attribute). There is no parameter through which the two cases could be made to diverge, so
byte-identity is a property of the function's *signature*, not of test discipline.

### 5.2 The four verbs AC5 names, plus the two it does not

| Route | Nonexistent review id | Review id owned by another tenant | Malformed (non-UUID) id | Same response? |
|---|---|---|---|---|
| R4 `GET /:id/context` | `get_review/2` → `{:error, :review_not_found}` → **404** | lookup with caller's prefix → `nil` → `{:error, :review_not_found}` → **404** | §3.2 cast fails → **404** | **yes, byte-identical** |
| R5 `POST /:id/approve` | `approve_review/4` → `{:error, :review_not_found}` → **404** | same → **404** | **404** | **yes** |
| R6 `POST /:id/reject` | `reject_review/3` → `{:error, :review_not_found}` → **404** | same → **404** | **404** | **yes** |
| R7 `POST /:id/apply` | `apply_review/4` → `{:error, :review_not_found}` → **404** | same → **404** | **404** | **yes** |
| R3 `GET /:id` | `get_review/2` → `{:error, :review_not_found}` → **404** | same → **404** | **404** | **yes** (not AC5-required; specified for consistency) |
| R8 `POST /:review_id/run-assertions` | `apply_promotion_assertion_rerun/6` → `{:error, :review_not_found}` → **404** | same → **404** | **404** | **yes** (not AC5-required) |

Body in every cell: the RFC 9457 404 document from `Response.not_found/1`, i.e.
`{"type": "<base>not-found", "title": …, "status": 404, "detail": "the requested resource was not found", "trace_id": "<per-request>"}`,
`Content-Type: application/problem+json`. `trace_id` differs per request by design and is
excluded from the byte-identity assertion (the convention REQ-073's test helper already uses).

**INV-5's timing half, affirmatively for R4–R7 as well as R3.** For R4, R5, R6 and R7 the
nonexistent case and the cross-tenant case are not merely *mapped* to the same response —
they are produced by **the same single prefix-scoped primary-key lookup returning `nil`**,
executed at the same point in the same function, with no branch between them. There is no
second read on either path, so the DB round-trip count is identical by construction and
cannot vary with the outcome. R3 reaches the same guarantee by a different route (two reads
on every path, including the not-found one — see the paragraph below), which is why it is
argued separately.

PROVENANCE (historical, not current decision authority):
**R3's `null`-vs-404 distinction, stated because it is easy to get wrong.** R-Co's
`promotion_read.zig:79-83` returns **200** `{"assertion_run": null}` when the query finds no
row, and it filters on `review_id` alone with no tenant scoping (`:63-73`). Letflow splits
that single case in two:

* the review **exists in the caller's tenant** but has no assertion run yet → **200**
  `{"assertion_run": null}` (R-Co's shape, ported);
* the review does **not** exist in the caller's tenant (never existed, or is another
  tenant's) → **404**.

Preserving R-Co's undifferentiated 200-with-null would leak existence in the *other*
direction — a prober would learn that every id, including another tenant's, is "a review
with no assertion run." R3's handler therefore calls `get_review/2` **first** (same 404 path
as R4–R7) and only then `get_latest_assertion_run/2`. Two `:prefix`-scoped reads on every R3
path including the not-found one, so the round-trip count does not vary with the outcome.

### 5.3 The non-cross-tenant error cases, which are NOT 404

These arise only for a review the caller **can** see, so INV-5 does not apply and hiding
them would be actively unhelpful.

PROVENANCE (historical, not current decision authority):
| Context error | Status | Problem `type` slug | `detail` (exact literal) | R-Co |
|---|---|---|---|---|
| `:self_approval_forbidden` (R5) | **403** | `forbidden` | `"a reviewer cannot approve their own promotion request"` | 403 `SELF_APPROVAL_FORBIDDEN`, `promotion_review.zig:438` — **matches** |
| `:digest_mismatch` (R5, R7) | **409** | `conflict` | `"the provided plan_digest does not match the stored digest"` | 409 `PLAN_DIGEST_MISMATCH`, `:448`/`:645` — **matches** |
| `:invalid_transition` (R5, R6, R7) | **409** | `conflict` | §6.1's fixed literal | 400 `INVALID_REVIEW_TRANSITION`, `:443`/`:539`/`:640` — **deliberate divergence, D-8/§6.1** |
| `:duplicate_review` (R1) | **409** | `conflict` | `"a live review for this plan digest already exists"` | 409 `DUPLICATE_REVIEW`, `:230` — **matches** |

So of the three 409-class outcomes Letflow produces, **two match R-Co's own 409 choices
exactly** (`PLAN_DIGEST_MISMATCH`, `DUPLICATE_REVIEW`) and **one is a deliberate upgrade
from R-Co's 400** (`INVALID_REVIEW_TRANSITION`), required by AC4's own wording. Stated
together so the divergence is visible as a single, bounded decision rather than a general
disagreement with R-Co's status codes.

`:self_approval_forbidden` is 403 and not 409 because it is an *authorization* fact about
this actor (a different actor on the same row succeeds), not a state fact about the row.
Note `approve_review/4` checks it **before** the status pre-check (its documented 4-gate
order), so a self-approval attempt on an already-`:applied` review returns 403, not 409 — an
ordering the tests must pin (§12.4) rather than assume.

`:digest_mismatch` is 409 and not 422 because the submitted digest is well-formed; it simply
describes a plan that is no longer the stored one — a concurrency/staleness conflict, which
is what 409 means. It is compared constant-time inside `PromotionDigest.verify_digest/2`;
the route never compares digests itself.

---

## 6. The approve/reject/apply state-transition matrix (AC4)

### 6.1 The single-atom problem, and how the route handles it

`PromotionReviewStore` returns **the same `:invalid_transition` atom for every illegal
edge** — its moduledoc says so explicitly ("the same atom for every illegal edge
(`rejected -> approved`, `pending_review -> applied`, `superseded -> anything`, …)") — and
it returns that atom from *two* places: the pre-check (`check_status/2`) and the
row_version-guarded `UPDATE` returning zero rows (`execute_update/3`, the lost-race case).

The route therefore **cannot** produce a state-specific detail string without issuing a
second read, and it must not: a second read would be a TOCTOU (the row can move between the
failed transition and the read) and would turn the response into an oracle for the row's
exact status. So:

> **One status, one `type`, one `detail`, for every illegal edge on every one of R5/R6/R7:**
> **409**, `type: "<base>conflict"`,
> `detail: "review is not in a state that permits this transition"`.

The detail names the *operation class*, never the row's actual status. A caller needing the
real status calls `GET /promotions/:id/context` (R4), which is `:prefix`-scoped and
PLATFORM_ADMIN-gated — the information is available, but only to someone already entitled to
the row, and never as a side channel off a failed write.

**409, not R-Co's 400 (D-8).** AC4 requires a "409-class problem document"; the requirement
wins over the port. 409 is also the semantically right code — the request is well-formed
(400's meaning) and fails only because of the resource's current state. Recorded as a single
bounded divergence in §5.3's table alongside the two codes that do match R-Co.

### 6.2 The full matrix — 6 statuses × 3 operations

Derived from `PromotionReviewStore`'s hardcoded `allowed_source_statuses` lists
(`approve_review/4` → `[:pending_review]`, `reject_review/3` → `[:pending_review]`,
`mark_review_applied/2` → `[:approved]`) plus §9.3's `apply_review/4`, which requires
`:approved` before it will call `Promotion.promote_definition/3` at all.

Legend: **200** = success; **409** = §6.1's problem document, byte-identical in every 409
cell; **403** = §5.3's self-approval document; **409-D** = the digest-mismatch document.

| Current `status` | `POST /:id/approve` | `POST /:id/reject` | `POST /:id/apply` |
|---|---|---|---|
| `:pending_review` | **200** `{review_id, status:"approved"}` — or **403** if `requested_by == actor`, or **409-D** if the digest mismatches | **200** `{review_id, status:"rejected"}` | **409** |
| `:approved` | **409** | **409** | **200** `{review_id, status:"applied"}` — or **409-D** if the digest mismatches |
| `:rejected` | **409** | **409** | **409** |
| `:applied` | **409** ← **this is AC4** | **409** | **409** |
| `:failed` | **409** | **409** | **409** |
| `:superseded` | **409** | **409** | **409** |
| *(row absent / other tenant / malformed id)* | **404** (§5) | **404** | **404** |

Eighteen state×operation cells: three are 200 (two of those with conditional non-200
variants), fifteen are 409; the whole bottom row is 404.

### 6.3 AC4 in particular — approving an already-`:applied` review

AC4: *"approving a review that has already been applied returns a 409-class problem document
and does not re-apply, verified by asserting the review's state and the target definition
are unchanged."*

* **409-class:** row `:applied` × column approve = **409**, §6.1's document. Guaranteed by
  `approve_review/4`'s `allowed_source_statuses == [:pending_review]`, a closed hardcoded
  list — `:applied` is not in it, so `check_status/2` fails before any `UPDATE` is issued.
* **Does not re-apply — and cannot, structurally, for two independent reasons:**
  1. `approve_review/4` never calls `Letflow.Definitions.Promotion` at all.
     `PromotionReviewStore`'s moduledoc states the module "deliberately does not depend on
     `Letflow.Definitions.Promotion`" — there is no code path from an approve call to a
     `process_definitions` write, whatever the row's status.
  2. The only route that touches `process_definitions` is R7 (`apply_review/4`, §9.3), and
     it requires `:approved`. So even a *successful* approve-then-apply sequence on an
     already-applied review is impossible: the row is `:applied`, approve 409s, apply 409s.
* **A rolled-back, superseded review cannot be reopened into an approvable state** —
  `supersede_review/3`'s only outbound status is `:superseded`, and `:superseded` appears in
  **no** function's `allowed_source_statuses`. Matrix row 6 is permanently 409 on all three
  operations.

§12.4's test reads the target tenant's ACTIVE `process_definitions` row (`id` **and**
`version`) before and after the 409'd approve and asserts equality.

### 6.4 The lost-race cell

`execute_update/3`'s zero-rows-affected branch also yields `:invalid_transition`, so two
concurrent `POST /:id/approve` calls on the same `:pending_review` row produce one **200**
and one **409**, the 409 byte-identical to a stale-state 409. That is the correct and
intended outcome (REQ-037 AC4's own concurrency contract) and needs no route-layer handling
— recorded so nobody adds retry logic to "fix" it.

---

## 7. Per-route composition and response allowlists

Every `*_map/1` below is a **private function in its own router module building a literal
map with exactly the listed string keys**. No `@derive Jason.Encoder`, no
`Map.from_struct/1`, no `Map.drop/2`, anywhere in this design — the allowlist discipline
`Letflow.Routers.Identity`'s `user_map/1` and `Letflow.Routers.Tenants`' `tenant_map/1`
already established. A field later added to `PromotionReview`, `PromotionAssertionRun` or
`ProcessDefinition` cannot leak through any of these (INV-2).

`iso8601/1` is the `NaiveDateTime`→`Etc/UTC`→`DateTime.to_iso8601/1` helper
`Letflow.Routers.Tenants` already carries; reuse its exact shape.

### 7.1 R1 `POST /promotions` — submit

Composition (each step short-circuits):

1. `PromotionPlan.compute_promotion_plan(actor_id, attrs["source_tenant_id"], attrs["target_tenant_id"], attrs["process_key"], permission_checker: &PromotionPlan.default_permission_checker/2)`
   — §7.9 on `permission_checker`, which is a real gap, not a detail.
2. `PromotionConflict.reject_if_conflicts(actor_id, attrs["target_tenant_id"], [attrs["process_key"]], [attrs["base_version"]])`
3. `PromotionDigest.compute_plan_digest(plan)`
4. `PromotionReviewStore.insert_review(%{plan: plan, digest: digest, requested_by: actor_id}, opts)`

| Result | Status | Detail / body |
|---|---|---|
| `{:ok, review}` | **201** | `%{"review_id" => review.id, "plan_digest" => review.plan_digest}` — exactly 2 keys |
| `{:error, :forbidden}` (1) | 403 | `"insufficient permissions"` |
| `{:error, :invalid_promotion_source}` (1) | 422 | `Error.invalid_promotion_source/1` (NEW §9.6), `"source_tenant_id must name a test tenant"` |
| `{:error, :empty_plan}` (1) | 422 | `Error.empty_promotion_plan/1` (NEW §9.6), `"source and target are identical after canonicalisation"` |
| `{:error, :invalid_tenant_id}` (1) | 422 | `Response.unprocessable(conn, "source_tenant_id or target_tenant_id does not name a provisioned tenant")` |
| `{:error, {:conflicts, details}}` (2) | **409** | `Error.promotion_conflict/2` (NEW §9.6), `"target tenant has advanced past base_version"`, with the `conflicts` extension member |
| `{:error, :mismatched_process_key_list}` (2) | 500 | `Response.internal_error(conn)` — the route always passes two 1-element lists, so this is unreachable by construction; a 500 correctly says "our bug" |
| `{:error, :duplicate_review}` (4) | 409 | `"a live review for this plan digest already exists"` |
| `{:error, :digest_mismatch}` (4) | 500 | `Response.internal_error(conn)` — the route computed the digest from the same plan one line earlier; a mismatch is internal inconsistency, never caller-caused |
| `{:error, :invalid_schema_name}` (4) | 500 | `Response.internal_error(conn)` — `opts[:prefix]` came from `scoped_repo_opts/1` |
| `{:error, %Ecto.Changeset{}}` (4) | 500 | `Response.internal_error(conn)` — no caller-supplied field reaches `insert_changeset/2` unvalidated |

PROVENANCE (historical, not current decision authority):
`conflicts` extension-member element shape: **use `PromotionConflict`'s own
`@type conflict_detail` field names** (`lib/letflow/definitions/promotion_conflict.ex:34-40`),
not R-Co's — that module is the authority for what the tuple actually carries. R-Co's
equivalent is `promotion_review.zig:197-209` for cross-reference only.

**Note on `base_version`.** R-Co takes it from the body and feeds it to the conflict check
while *also* computing a plan whose own `base_version` comes from the target's current
ACTIVE row — deliberately two different values (the client's last-known vs. the current).
Letflow keeps that shape exactly: `attrs["base_version"]` goes to step 2 only, never to step
1 or step 4. `PromotionPlan.t().base_version` (stored inside `serialised_plan`) remains the
computed one.

### 7.2 R2 `POST /promotions/plan` — plan preview

`PromotionPlan.compute_promotion_plan/5`, same opts as R1. Success → **200**,
`%{"entries" => [plan_entry_map(e) | e <- plan.entries]}` — **exactly 1 top-level key**.

PROVENANCE (historical, not current decision authority):
`plan_entry_map/1`, **exactly 5 keys**, ported from `promotions.zig:145-163`: `"type"`
(`Atom.to_string/1`, one of `graph_node|graph_edge|variable_schema|service_binding|module_ref`),
`"id"`, `"change_kind"` (`Atom.to_string/1`, one of `added|modified|removed`), `"before"`,
`"after"`.

PROVENANCE (historical, not current decision authority):
`before`/`after` are `map() | String.t() | nil` per `PromotionPlan.plan_entry/0` and are
emitted as-is (JSON object, string, or `null`). R-Co stringifies both
(`promotions.zig:145-163` uses `appendJsonStr`); Letflow does not, because the underlying
values are already structured and stringifying them would lose information for no gain.

PROVENANCE (historical, not current decision authority):
R-Co's `"human_readable"` key is **not ported** (D-9, OQ-6). R-Co's `"permission_rule"`
`type` value (`promotions.zig:177-186`) has no counterpart in
`PromotionPlan.entry_type/0`'s five values, so it cannot occur; not ported.

Errors: the four `compute_error/0` cases exactly as in R1's table.

### 7.3 R4 `GET /promotions/:id/context`

`PromotionReviewStore.get_review(id, opts)` (NEW §9.1). Success → **200**,
`review_context_map/1`, **exactly 9 keys**:

| Key | Source | Type |
|---|---|---|
| `"review_id"` | `review.id` | string |
| `"plan_digest"` | `review.plan_digest` | string |
| `"serialised_plan"` | `Jason.decode!(review.serialised_plan)` | **object** (see below) |
| `"status"` | `Atom.to_string(review.status)` | `pending_review\|approved\|rejected\|applied\|failed\|superseded` |
| `"requested_by"` | `review.requested_by` | string (uuid) |
| `"def_type"` | `review.def_type` | string |
| `"def_id"` | `review.def_id` | string |
| `"created_at"` | `iso8601(review.inserted_at)` | ISO 8601 string |
| `"row_version"` | `review.row_version` | integer |

Divergences from R-Co's 11-key body (`promotion_review.zig:321-337`), each deliberate:

* **`serialised_plan` is a decoded JSON object, not a raw embedded string.** R-Co splices
  the stored text in unquoted. Decoding costs nothing and is strictly better for clients;
  the value is always well-formed because `insert_review/2` produced it with
  `Jason.encode!/1`.
* **`assertions` and `needs_review_package` are NOT ported (2 keys dropped).** R-Co builds
  both in the handler (`:696`, `:752-778`) from the plan entries — real domain logic living
  in a route, which this requirement's own text forbids ("if a handler needs logic that does
  not exist, add it to the context module, never inline in the route"). No Letflow context
  module produces either shape, and a `NEEDS_REVIEW`-package generator is a domain feature,
  not a route port. **OQ-3.**
* **`created_at` is real** — R-Co's is the hardcoded `"1970-01-01T00:00:00Z"` (D-3).
* `approved_by`, `approved_at`, `superseded_by` are on the schema and **excluded** —
  allowlist, not denylist; R-Co does not emit them either; add explicitly if a later
  requirement demonstrates a need.

Errors: `{:error, :review_not_found}` → **404** (§5). The only error case.

### 7.4 R3 `GET /promotions/:id` — latest assertion run

1. `PromotionReviewStore.get_review(id, opts)` → `{:error, :review_not_found}` → **404**
   (§5.2's rationale for why this read comes first).
2. `Definitions.get_latest_assertion_run(id, opts)` (NEW §9.2).

PROVENANCE (historical, not current decision authority):
| Result | Status | Body |
|---|---|---|
| `{:error, :not_found}` | **200** | `%{"assertion_run" => nil}` — R-Co's `promotion_read.zig:79-83` shape, ported |
| `{:ok, run}` | **200** | `%{"assertion_run" => assertion_run_map(run)}` |

PROVENANCE (historical, not current decision authority):
`assertion_run_map/1`, **exactly 7 keys**, ported from `promotion_read.zig:102-149`:
`"run_id"` (`run.id`), `"status"` (`Atom.to_string/1`), `"sandbox_id"` (string or `nil`),
`"teardown_error"` (string or `nil`), `"assertions_passed"` (integer),
`"assertions_failed"` (integer), `"failing_assertion_ids"` (array of strings).

`run.idempotency_key`, `run.plan_digest`, `run.review_id`, `run.assertions_total`,
`run.started_at`, `run.completed_at` are on the schema and **excluded**. **`plan_digest` in
particular:** emitting it would hand any reader the exact token required to approve or apply
the review (§8.3). Under §4's PLATFORM_ADMIN-only gate that is not currently an escalation
across roles, but it would silently become one the moment a later requirement widens read
access — excluded deliberately, with the reason stated in the moduledoc so the exclusion
survives that widening.

PROVENANCE (historical, not current decision authority):
R-Co's `"unknown"` status fallback (`promotion_read.zig:92`) is **not ported** —
`PromotionAssertionRun.status` is an `Ecto.Enum` over
`[:running, :passed, :failed, :teardown_failed]` on a NOT NULL column, so the null case
R-Co defends against cannot occur.

### 7.5 R5 / R6 / R7 / R8

| Route | Context call | Success body |
|---|---|---|
| R5 | `PromotionReviewStore.approve_review(id, actor_id, attrs["plan_digest"], opts)` | **200** `%{"review_id" => r.id, "status" => "approved"}` |
| R6 | `PromotionReviewStore.reject_review(id, actor_id, opts)` | **200** `%{"review_id" => r.id, "status" => "rejected"}` |
| R7 | `Promotion.apply_review(id, actor_id, attrs["plan_digest"], opts)` (NEW §9.3) | **200** `%{"review_id" => id, "status" => "applied"}` |

`"status"` is a fixed literal per route, not `Atom.to_string(r.status)` — R-Co does the same
(`:461-465`, `:551-555`, `:657-661`) and it keeps the body independent of any future
status-atom rename. Error mapping: §5.3 and §6.

R7's additional error cases beyond §5.3/§6, from `apply_review/4`'s contract (§9.3):

| Result | Status | Detail |
|---|---|---|
| `{:error, {:promotion_failed, :forbidden}}` | 403 | `"insufficient permissions"` |
| `{:error, {:promotion_failed, :invalid_promotion_source}}` | 422 | `Error.invalid_promotion_source/1` |
| `{:error, {:promotion_failed, :source_definition_missing}}` | **409** | `"the source definition is no longer active"` — a staleness conflict between plan time and apply time, not a missing *request* target, so 409 not 404 |
| `{:error, {:promotion_failed, {:conflicts, details}}}` | 409 | `Error.promotion_conflict/2` |
| `{:error, {:promotion_failed, :duplicate_version}}` | 409 | `"the target version already exists in the target tenant"` |
| `{:error, {:promotion_failed, :invalid_tenant_id}}` | 500 | `Response.internal_error(conn)` — the tenant ids come from the stored plan, not the request |
| `{:error, {:promotion_failed, _other}}` | 500 | `Response.internal_error(conn)` (covers the event-append failure path, OQ-1) |

**After a `{:promotion_failed, _}` result the review's status is `:failed`, not
`:approved`** — `apply_review/4` calls `mark_review_failed/2` on that path (§9.3 step 4).
Load-bearing for the caller: a retried apply on a `:failed` review 409s (matrix row 5); it
does not silently retry the promotion.

**R8 — `POST /promotions/:review_id/run-assertions`:**

1. `PromotionArtifact.from_json(attrs["artifact"])` (NEW §9.4) →
   `{:error, {:invalid_artifact, field}}` → **422**
   `Response.unprocessable(conn, "artifact is not a well-formed promotion artifact")`. The
   offending field name is **not** echoed into the detail (**OQ-7** covers a richer
   per-field validation).
2. `Definitions.apply_promotion_assertion_rerun(review_id, attrs["plan_digest"], artifact, sandbox_pool, max_wait_ms, opts ++ [event_appender: <appender>])`.

**`event_appender:` is mandatory here and is easy to miss** — `apply_promotion_assertion_rerun/6`
`Keyword.fetch!`es it on the fifth line of its body, unconditionally, so passing only the
`[prefix: …]` fragment from §3 step 1 makes the route raise `KeyError` on **every** request
including the happy path (F-5.1). The value is the **real** appender from the
platform-event-appender requirement (§11 OQ-1) — R8 must not ship with a hardcoded stub,
for the reasons in F-5.2's Severity-2 entry. R7, R9 and R10 take the same opt from the same
source; **all four routes are blocked on that requirement landing.**

`sandbox_pool` and `max_wait_ms` — the route does **not** hardcode either:

```
sandbox_pool = Application.get_env(:letflow, :promotion_assertion_pool, Letflow.SandboxPool)
max_wait_ms  = Application.get_env(:letflow, :promotion_assertion_max_wait_ms, 5_000)
```

`Letflow.SandboxPool` is started under the application supervisor with its module name as
its process name (`lib/letflow/application.ex:31`), so the default is a live, real pool —
**not** R-Co's `max_concurrent = 0` always-503 stub (D-4). Config-injectability exists so a
test needing its own quota can point at a separately-named pool, the mechanism REQ-039's
design (§4.7 INV-SP-7) already prescribes; `config/test.exs` sets
`max_concurrent_sandboxes: 1` on the global pool. Add both keys to `config/config.exs` with
the defaults above so they are discoverable rather than implicit.

| Result | Status | Body |
|---|---|---|
| `{:ok, %{assertions_failed: 0} = r}` | **200** | `assertion_rerun_map(r)` |
| `{:ok, %{assertions_failed: n} = r}` when `n > 0` | **422** | `assertion_rerun_map(r)` — same body shape |
| `{:error, :review_not_found}` | **404** | §5 |
| `{:error, :sandbox_unavailable}` | **503** | `Response.service_unavailable(conn, "no sandbox free within timeout")` |
| `{:error, :provision_failed}` | **503** | `Response.service_unavailable(conn, "sandbox provisioning failed")` |
| `{:error, :fixture_load_failed}` | **422** | `Response.unprocessable(conn, "fixture load into sandbox failed")` |
| `{:error, {:idempotency_lookup_failed, :sidecar_row_missing}}` | **500** | `Response.internal_error(conn)` |
| `{:error, %Ecto.Changeset{}}` / other | **500** | `Response.internal_error(conn)` |

PROVENANCE (historical, not current decision authority):
**The 200/422 split keys on `assertions_failed`, not on `status`** — a deliberate divergence
from R-Co's `result.status != .failed` check (`promotion_assertion.zig:177-179`).
`Letflow.Definitions.apply_promotion_assertion_rerun/6`'s own `@doc` states the gate
condition explicitly: *"callers must gate on the returned `assertions_failed == 0`, NOT on
`status == :passed`. A `status = :teardown_failed` result with `assertions_failed == 0` is a
green gate."* Porting R-Co's status check would 200 a `:teardown_failed` run and 422 nothing
differently — but it would also mean the HTTP layer disagrees with the documented gate
condition, which is exactly the kind of drift that produces a wrong promotion decision later.

PROVENANCE (historical, not current decision authority):
`assertion_rerun_map/1`, **exactly 6 keys**, ported from `promotion_assertion.zig:145-170`:
`"run_id"`, `"status"` (`Atom.to_string/1`), `"assertions_passed"`, `"assertions_failed"`,
`"failing_assertion_ids"`, `"sandbox_id"` (string or `nil`).

**`idempotent_hit` is deliberately NOT a key** — §8.1; this is what makes AC2 true.
`assertions_total`, `teardown_error` and `teardown_event_appended` are also excluded (R-Co
emits none of them either; `teardown_error` is reachable through R3).

### 7.6 R9 `POST /definitions/:process_key/rollback`

`Definitions.rollback_definition_version(process_key, attrs["target_version"], actor_id, prefix: prefix, permission_checker: …, event_appender: …)`
— §7.9 (`permission_checker`) and OQ-1 (`event_appender`); both are `Keyword.fetch!`'d with
no default.

PROVENANCE (historical, not current decision authority):
Success → **200**, `rollback_map/1`, **exactly 5 keys**, ported from
`definition_rollback.zig:96-114`: `"definition_id"`, `"version"` (string — below),
`"rolled_back_from_version"` (string), `"superseded_review_id"` (string or `nil`),
`"event_id"`.

Error map, matching `req038-promotion-rollback.md:773`'s own forward-specified table:

| Result | Status | Detail |
|---|---|---|
| `{:error, :forbidden}` | 403 | `"insufficient permissions"` (R-Co `:84`, matches) |
| `{:error, :process_key_not_found}` | **404** | `Response.not_found(conn)` — zero-detail, the same document as §5's, because a `process_key` with no ACTIVE definition in the caller's tenant is the same fact as one that never existed (R-Co `:87`, matches) |
| `{:error, :version_never_active}` | 422 | `"target_version was never active"` (R-Co `:85`, matches) |
| `{:error, :already_active}` | 422 | `"target_version is already the active version"` (R-Co `:86`, matches) |
| `{:error, :invalid_schema_name}` | 500 | `Response.internal_error(conn)` |
| other | 500 | `Response.internal_error(conn)` |

PROVENANCE (historical, not current decision authority):
**`version` is a string, not a number — a divergence worth stating.** R-Co parses
`target_version` as a `u32` and emits both versions as JSON numbers
(`definition_rollback.zig:69-74`, `:96-114`). Letflow's `process_definitions.version` is
`field(:version, :string)` — free-form text with no numeric or semver constraint, as
`PromotionConflict.version_greater?/2` explicitly documents ("attempts an integer comparison
first; falls back to … lexicographic"). So the request field is a **string** (§8.4) and both
response fields are strings. Porting R-Co's integer typing would reject versions this
codebase already permits.

### 7.7 R10 `POST /tenants/:test_tenant_id/promote/:process_key`

`Promotion.promote_active_definition(actor_id, test_tenant_id, target_tenant_id, process_key, opts)`
(NEW §9.5).

PROVENANCE (historical, not current decision authority):
**`target_tenant_id` is `conn.assigns.auth_context.tenant_id` — never a path, query or body
value.** The caller is authenticated *into* the production tenant and promotes a definition
*from* the named test tenant into their own. This is R-Co's semantics (`promotion.zig`
promotes from a test tenant into the production tenant it is paired with) expressed through
the one mechanism Letflow has for "which tenant is this request about," and it means the
*destination* of an irreversible write is structurally uninfluenceable by the request
(INV-1).

`test_tenant_id` **is** caller-supplied and **is** a cross-tenant read — §7.9 is required
reading before implementing this route.

PROVENANCE (historical, not current decision authority):
Success → **201**, `promote_map/1`, **exactly 4 keys**, ported from `promotion.zig:70-91`:
`"definition_id"`, `"version"` (string, per §7.6's reasoning — R-Co already emits this one
as a JSON string, `promotion.zig:76`), `"status"` (`Atom.to_string(row.status)`, i.e.
`"active"`), `"warnings"`.

**`warnings` is always `[]`.** R-Co populates it from its semantic gate
(`runSemanticGateOnSource`), which Letflow does not port — no Letflow equivalent exists and
building one is a domain feature. The key is kept rather than dropped so the response shape
stays R-Co-compatible and a later requirement can populate it without a breaking change.
**OQ-6.**

PROVENANCE (historical, not current decision authority):
Error map, from `promotion.zig:37-61` mapped onto `promote_error/0`:

| Result | Status | Detail |
|---|---|---|
| `{:error, :forbidden}` | 403 | `"insufficient permissions"` (R-Co `:56-58`, matches) |
| `{:error, :invalid_promotion_source}` | 422 | `Error.invalid_promotion_source/1` — R-Co's `not_a_test_tenant`/422 (`:40-47`), same status, same meaning |
| `{:error, :source_definition_missing}` | **404** | `Response.not_found(conn)` (R-Co's `ActiveDefinitionNotFound` → 404, `:37-39`, matches) |
| `{:error, :invalid_tenant_id}` | **404** | `Response.not_found(conn)` — **404 and not 422**: `test_tenant_id` is exactly the kind of caller-supplied id INV-5 is about; a 422 would tell a prober "that tenant does not exist," where a 404 does not distinguish it from "exists but you cannot promote from it." Diverges from R-Co, which 404s only its `TestTenantNotFound` case (`:37-39`) — same outcome, reached deliberately |
| `{:error, {:conflicts, details}}` | 409 | `Error.promotion_conflict/2` |
| `{:error, :duplicate_version}` | 409 | `"the target version already exists in the target tenant"` |
| other | 500 | `Response.internal_error(conn)` |

R-Co's `production_tenant_inactive`/409 (`:48-55`) has no Letflow analogue on this path: the
target tenant is the caller's own, and `Letflow.Plugs.TenantStatus` already runs ahead of
every sub-router in `Letflow.Plugs.ApiPipeline`. Not ported; stated so its absence is not
read as dropped.

### 7.8 Required `@moduledoc` content for `Letflow.Routers.Promotions` (build requirement)

CODE-DESIGN-VALIDATOR and REVIEWER check these against the shipped file text, not against
this design doc. All must appear as literal prose:

1. The route table (§1's rows R1–R8), one line each.
2. **The `POST /promotions` collision resolution (F-2)**, naming both R-Co handlers, both
   Letflow paths, and that this is a deliberate divergence.
3. **The `:Unknown` authorization decision (§4.3 point 1)**, verbatim in substance —
   including that it is deliberate, that `evaluate_access/2`'s first `cond` branch makes it
   PLATFORM_ADMIN-only, and that `required_permission(:Unknown) -> :MetricsRead` is
   unreachable and is not what gates these routes.
4. **The INV-5 statement (§5.1)**: a review belonging to another tenant is not found and
   then filtered — the per-tenant `:prefix` means it is not in the schema being searched,
   `promotion_reviews` has no `tenant_id` column at all (REQ-064 / Decision 0006 D2), and
   there is deliberately no second, unscoped existence check anywhere in this module.
5. **The single-atom 409 rule (§6.1)**: `PromotionReviewStore` returns `:invalid_transition`
   for every illegal edge and for the lost optimistic-lock race alike, so this module maps
   it to one 409 with one fixed detail string that never names the row's actual status —
   and that this is a deliberate upgrade from R-Co's 400, required by AC4, while R-Co's own
   409s (`PLAN_DIGEST_MISMATCH`, `DUPLICATE_REVIEW`) are ported unchanged.
6. **The idempotency-preservation obligation (§8.1)**: the assertion-run response omits
   `idempotent_hit` on purpose, so a repeat POST with the same `(review_id, plan_digest)`
   returns a byte-identical body, and R-Co's `ALREADY_RECORDED` 200-with-error-envelope
   (D-5) is not ported.
7. **The assertion-run gate condition (§7.5)**: the 200/422 split keys on
   `assertions_failed == 0`, not on `status == :passed`, per
   `apply_promotion_assertion_rerun/6`'s own documented gate condition.
8. **The unknown-field note (§4.4)**: `Validation.validate/2`'s `Map.take/2` makes an
   injected `approved_by` structurally unreachable, so R-Co's 422 `UNKNOWN_FIELD` check is
   not ported.
9. **The `permission_checker` gap (§7.9)**, verbatim in substance.
10. **The allowlist statement**: every response body is a hand-built map with the key set
    named in each `*_map/1`'s own `@doc`, never a `Jason.Encoder` derivation over an Ecto
    struct.

**Wording hazard (`docs/anti-patterns.md`, "A grep-shaped acceptance criterion can be
tripped by the module's own moduledoc"):** AC6's grep hunts the literal `Repo.`. Point 4
above and any prose about delegation must therefore describe the property **without writing
that substring** — e.g. "the schema being searched," "every read goes through a promotion
context module," not "no `Repo.get` call." Verify §10.2's greps against the final moduledoc
wording before treating AC6 as satisfied. This is a real, previously-hit failure mode in
this codebase, not a hypothetical.

### 7.9 The `permission_checker` gap — the biggest security caveat in this design

`PromotionPlan.compute_promotion_plan/5` and `Promotion.promote_definition/3` both
`Keyword.fetch!` a `permission_checker`, and the only implementation that exists is
`PromotionPlan.default_permission_checker/2`, whose own `@doc` says: *"performs **no real
enforcement**. Always returns `true`, regardless of `actor_id` or `source_tenant_id`."*

Its argument is `(actor_id, source_tenant_id)` — precisely the check on **reading another
tenant's definitions**, which R1, R2 and R10 all do by design (a promotion is inherently
cross-tenant). With the always-true default, any caller reaching R2 can read the full graph,
edges, service bindings and module refs of any process definition in any tenant, by passing
that tenant's id as `source_tenant_id` and reading the diff entries out of the 200 response.

**§4's Option-A decision materially bounds this.** The only role that can reach any of R1,
R2 or R10 is `PLATFORM_ADMIN` — which already holds legitimate cross-tenant reach through
REQ-075's `:TenantsManage` routes. So this is **not** a live privilege escalation today; it
is a missing enforcement layer that would become one the moment a later requirement grants
a non-admin role access to these routes. It is recorded here, and in the moduledoc, so that
requirement cannot widen access without meeting this first.

Three requirements on the build:

1. Every call site passes `permission_checker: &PromotionPlan.default_permission_checker/2`
   **explicitly and by name** — never an inline `fn _, _ -> true end` — so
   `grep -rn "default_permission_checker" lib/` finds every place the gap is live.
2. `Letflow.Routers.Promotions`' moduledoc states the gap in these terms, naming R1/R2/R10
   as the affected routes **and** naming §4's PLATFORM_ADMIN-only gate as the thing
   currently containing it.
3. **Escalated to SECURITY-REVIEWER for an explicit ruling (OQ-2)**, not resolved here. A
   real checker needs a "which tenants may this actor promote from" concept that does not
   exist in `Letflow.Identity`: there is no `tenant_type` column, no test↔production
   pairing, and `PromotionPlan.default_tenant_classifier/1` classifies every tenant as
   `:test` for the same reason. Building one inside a routes requirement would be the
   partial-subsystem failure this codebase's boundaries warn against — but shipping the HTTP
   surface without a ruling would be worse.

---

## 8. The two preserved contracts, and the request-validation schemas

### 8.1 REQ-040 assertion-run idempotency (AC2) — an obligation on the HTTP layer

**The idempotency is already implemented and must be preserved, not re-derived.**
`Definitions.apply_promotion_assertion_rerun/6` builds its key internally from
`(review_id, plan_digest)` (`build_idempotency_key/2`), claims it through the unique index
REQ-064 simplified, and on a repeat returns the **cached row** with `idempotent_hit: true`
and `sandbox_id` read back from that stored row — claiming no sandbox and inserting no
second row. The route's obligations are exactly three, and all three are *omissions*:

1. **Do not build, read, accept or forward an idempotency key.** No `Idempotency-Key` header
   is read; no key appears in the validation schema (§8.4); the route passes `review_id` and
   `plan_digest` and nothing else. Any route-layer key handling would be a second, divergent
   key derivation.
2. **Do not surface `idempotent_hit` in the response.** §7.5's `assertion_rerun_map/1` has 6
   keys and `idempotent_hit` is not among them. **This is what makes AC2 literally true:**
   AC2 demands "two identical successful responses," and `idempotent_hit` is the one field
   in `assertion_rerun_result/0` that *differs* between the first call (`false`) and the
   repeat (`true`). Emitting it would make the two responses non-identical and fail AC2 by
   construction. Every other key in the map is read from the same persisted row on both
   calls, so byte-identity follows.
PROVENANCE (historical, not current decision authority):
3. **Do not port R-Co's `ALREADY_RECORDED` branch** (`promotion_assertion.zig:133`), which
   returns HTTP 200 with the *error* envelope `{"error":"ALREADY_RECORDED","message":…}` and
   no `run_id` (D-5). It is a defect: it breaks AC2 outright and gives a client a 200 it
   cannot parse as success.

The status code is identical on the repeat too: §7.5 keys the 200-vs-422 split on
`assertions_failed`, read from the same row both times.

§12.2's test asserts the `promotion_assertion_runs` row count is `1` after two POSTs and
that the two responses' `status` and `resp_body` are equal. Note `trace_id` appears only in
problem documents, never in a success body, so for R8's success path the raw `resp_body`
values compare equal directly with no stripping.

**Reachability caveat.** Everything above describes the *mechanism*, and the mechanism is
correct and unaffected by OQ-1. But **AC2 cannot actually be exercised until the
platform-event-appender requirement lands**: R8 is the only route AC2 touches, and
`apply_promotion_assertion_rerun/6` `Keyword.fetch!`es `event_appender` eagerly
(`definitions.ex:806`), so the route cannot serve a request at all without one — and
supplying a stub from the handler is rejected (F-5.2, Severity 2). §11's AC-reachability
table records the consequence.

### 8.2 REQ-064 per-tenant `plan_digest` uniqueness (AC3)

Two tenants submitting the same `plan_digest` get two independent reviews, and this falls
out of `:prefix` scoping with **no route-layer work at all**:

* `promotion_reviews` has **no `tenant_id` column** — Decision 0006 D2 / REQ-064 dropped it,
  because the per-tenant Postgres schema already identifies the tenant
  (`req064-drop-tenant-id.md`; `PromotionReviewStore.insert_review/2`'s own `@doc` restates
  it).
* The partial unique index `uq_promotion_review_active_digest` is on `[:plan_digest]` alone
  (REQ-035 as narrowed by REQ-064), and **it is created inside each tenant's schema**, so
  there is one such index per tenant. A digest value in tenant A's index is simply not
  present in tenant B's.
* `insert_review/2` writes with `prefix: <caller's schema>` from `scoped_repo_opts/1`, so
  the row lands in the caller's schema and can only ever collide with that tenant's rows.

`:duplicate_review` is therefore reachable **only** within one tenant, and §12.3's test is a
direct assertion of that.

### 8.3 `plan_digest` in the request body is a concurrency token, not a secret

R5 and R7 require `plan_digest` in the body, and `approve_review/4` compares it
constant-time (`PromotionDigest.verify_digest/2`, never `==`). The route never compares
digests itself and never logs the submitted value. §7.4's exclusion of `plan_digest` from
R3's response exists so a read of the assertion run does not confer the token needed to
approve or apply. R4 **does** emit `plan_digest` (§7.3) — that is R-Co's shape and is
intentional: whoever reads a review's context is the person who then approves it.

### 8.4 Request-body validation schemas (`Letflow.Api.Validation.FieldConstraint`)

Each schema is a module attribute in its router. `Validation.validate(schema, conn.body_params)`
returns `{:ok, attrs}` with **string** keys (it is `Map.take(body, field_names)`), or
`{:errors, errs}` → `Response.send_problem(conn, Validation.problem(errs))` (422 with the
`errors` extension array).

**R1 — `@submit_schema`** (4 fields, all required):

| `name` | `required` | `type` | other |
|---|---|---|---|
| `"source_tenant_id"` | `true` | `:uuid` | `reject_empty_string: true` |
| `"target_tenant_id"` | `true` | `:uuid` | `reject_empty_string: true` |
| `"process_key"` | `true` | `:string` | `reject_empty_string: true`, `max_length: 255` |
| `"base_version"` | `true` | `:string` | `reject_empty_string: true`, `max_length: 64` |

`max_length: 255` on `process_key` matches `process_definitions.name`, which is
`add :name, :string, null: false` with no `size:`
(`20260816193001_create_process_definitions.exs:77`) — Ecto's default `varchar(255)` — and
matches `Definitions.fetch_name/1`'s own 255-byte guard.

PROVENANCE (historical, not current decision authority):
`base_version` is `:string`, diverging from R-Co's "JSON integer or decimal string parsed as
u32" (`promotion_review.zig:116-123`) — same reasoning as §7.6: Letflow versions are
free-form text.

PROVENANCE (historical, not current decision authority):
**R2 — `@plan_schema`**: the first three rows of `@submit_schema`, no `base_version` (R-Co's
`handleCreatePromotionPlan` does not take one, `promotions.zig:74-88`).

**R5 — `@approve_schema`** and **R7 — `@apply_schema`** (identical, 1 field):

| `name` | `required` | `type` | other |
|---|---|---|---|
| `"plan_digest"` | `true` | `:string` | `reject_empty_string: true`, **`min_length: 64`, `max_length: 64`** |

**The 64/64 bound is a crash guard, not a length nicety — do not widen it.**
`PromotionDigest.verify_digest/2` calls **`:crypto.hash_equals/2`** directly on the
caller-supplied binary (`promotion_digest.ex:77-83`), and `:crypto.hash_equals/2`
**raises `ArgumentError` on binaries of unequal length** rather than returning `false`
(verified: `:crypto.hash_equals("abc", "abcd")` → `ArgumentError`). Since the stored digest
is always exactly 64 characters, any request whose `plan_digest` is a different length
reaches that raise. Pinning `min_length` **and** `max_length` to 64 makes the raise
unreachable from HTTP; relaxing either bound reintroduces a remote unhandled exception
triggerable by attacker-controlled body data on an authenticated endpoint.

64 is exact, not approximate: `compute_plan_digest/1` is
`:crypto.hash(:sha256, …) |> Base.encode16(case: :lower)` (`promotion_digest.ex:57-63`) —
a 32-byte digest hex-encoded to 64 lowercase characters.

**Only R5 and R7 forward a caller-supplied value into `verify_digest/2`** — confirmed
against every call site; no other route in §1 does. So these two schemas are the complete
set of places this guard is load-bearing.

PROVENANCE (historical, not current decision authority):
**R6 — `@reject_schema` = `[]`** (empty list). `validate([], body)` still runs the structural
checks (`check_is_object/1`, `check_no_null_bytes/1`) and then returns `{:ok, %{}}`,
discarding every field. That reproduces R-Co's "empty body is legal, any field is rejected"
(`promotion_review.zig:492-508`) in *effect* while diverging in diagnostics: R-Co 422s an
unknown field, Letflow silently ignores it (§4.4). One real divergence: R-Co accepts a
completely absent body; `Plug.Parsers` yields `body_params == %{}` for that, which
`check_is_object/1` accepts, so Letflow does too.

**R8 — `@run_assertions_schema`** (2 fields):

| `name` | `required` | `type` | other |
|---|---|---|---|
| `"plan_digest"` | `true` | `:string` | as above |
| `"artifact"` | `true` | `:object` | — |

PROVENANCE (historical, not current decision authority):
**`tenant_id` is NOT accepted** — R-Co requires it in the body
(`promotion_assertion.zig:77-81`) and this design refuses it. INV-1: the tenant comes from
`conn.assigns[:auth_context][:tenant_id]` via `scoped_repo_opts/1` and from nowhere else;
accepting a body `tenant_id` would create exactly the precedence fight REQ-072's design
exists to make impossible. Because it is absent from the schema, a client that sends one has
it dropped by `Map.take/2` — it cannot reach any code path. State this in the moduledoc.

**R9 — `@rollback_schema`** (1 field):

| `name` | `required` | `type` | other |
|---|---|---|---|
| `"target_version"` | `true` | `:string` | `reject_empty_string: true`, `max_length: 64` |

PROVENANCE (historical, not current decision authority):
**`tenant_id` is NOT accepted** — same reasoning; R-Co requires it
(`definition_rollback.zig:64-68`). `:string` rather than R-Co's integer-only, per §7.6.

PROVENANCE (historical, not current decision authority):
**R10 — no schema.** Both inputs are path segments; R-Co parses no body
(`promotion.zig:22-96`). `conn.body_params` is ignored if present.

---

## 9. New context functions this design mandates

Six new functions plus three new `Letflow.Api.Error` constructors. Every one is here because
a route needs logic that does not exist and the requirement forbids inlining it.

### 9.1 `Letflow.Definitions.PromotionReviewStore.get_review/2` — NEW

`PromotionReviewStore` today has **no read function at all** — six transition functions and
nothing else (verified by reading the whole module). R3 and R4 both need one.

```
@spec get_review(review_id :: Ecto.UUID.t() | String.t(), opts :: [prefix: String.t()]) ::
        {:ok, PromotionReview.t()} | {:error, :review_not_found}
```

* `opts[:prefix]` is `Keyword.fetch!/2`'d — mandatory, no default, matching every other
  function in this module.
* Casts `review_id` with `Ecto.UUID.cast/1` **before** any repo access; `:error` →
  `{:error, :review_not_found}`. Not belt-and-braces: a lookup by `:binary_id` primary key
  **raises `Ecto.Query.CastError`** for a non-UUID binary, and this is the natural place to
  make that impossible for every caller, HTTP or otherwise (§3.2).
* Then the ordinary primary-key lookup with `prefix: prefix`; `nil` →
  `{:error, :review_not_found}`.
* **Returns the struct, not a map.** Response shaping is the router's job (§7.3's
  allowlist) — a context module that pre-shaped a response would push presentation into the
  domain and make the allowlist invisible at the router.
* No new error atom: `:review_not_found` is the atom every other function in this module
  already returns for the same fact, so the router has one mapping rule (§5), not two.

### 9.2 `Letflow.Definitions.get_latest_assertion_run/2` — NEW

`Letflow.Definitions.PromotionAssertionRun` is a schema plus two changesets and nothing else;
REQ-040 put all `promotion_assertion_runs` behaviour in `Letflow.Definitions`, so this goes
there for consistency, not in the schema module.

```
@spec get_latest_assertion_run(review_id :: Ecto.UUID.t() | String.t(), opts :: [prefix: String.t()]) ::
        {:ok, PromotionAssertionRun.t()} | {:error, :not_found}
```

* `Ecto.UUID.cast/1` first, as §9.1.
* Query: `where review_id == ^uuid`, `order_by [desc: :started_at, desc: :id]`, `limit: 1`,
  fetched with `prefix: prefix`. No row → `{:error, :not_found}`.
PROVENANCE (historical, not current decision authority):
* **`started_at` is `read_after_writes: true`** on the schema (a DB default), so two runs
  inserted in the same transaction can share a timestamp — the `:id` tiebreaker makes the
  ordering total and the result deterministic. Check R-Co's own `ORDER BY`
  (`promotion_read.zig:63-73`); where it differs, this design's total ordering wins, because
  a non-deterministic "latest" makes R3's tests flaky.
* Error atom is `:not_found`, **not** `:review_not_found` — this answers "is there a run,"
  a different question from "is there a review," and R3 maps the two to different responses
  (404 vs. `{"assertion_run": null}`, §7.4).

### 9.3 `Letflow.Definitions.Promotion.apply_review/4` — NEW

R7 is the apply *orchestration*. `PromotionReviewStore.mark_review_applied/2`'s own moduledoc
is explicit that it does **not** call `Promotion.promote_definition/3` and that the *caller*
is the orchestrator: "calls `promote_definition/3` first, then `mark_review_applied/2` on
success or `mark_review_failed/2` on failure." No such orchestrator exists in `lib/` today
(verified: `grep -rn "promote_definition\|mark_review_applied\|mark_review_failed" lib/`
finds only the definitions themselves and doc references). **REQ-077 is that orchestrator**,
and AC4's "the target definition is unchanged" only has teeth if the apply route is it.

Four steps across two modules — real domain logic that must not live in a route. It goes in
`Letflow.Definitions.Promotion` and **not** in `PromotionReviewStore`, because that module's
moduledoc states outright that it "deliberately does not depend on
`Letflow.Definitions.Promotion`," and adding this there would reverse that. `Promotion`
already depends on `PromotionReview` and on nothing that would become circular.

```
@type apply_review_error ::
        :review_not_found
        | :digest_mismatch
        | :invalid_transition
        | {:promotion_failed, promote_error()}

@spec apply_review(
        review_id :: Ecto.UUID.t() | String.t(),
        actor_id :: Ecto.UUID.t(),
        plan_digest :: String.t(),
        opts :: [prefix: String.t(), permission_checker: …, event_appender: …, tenant_classifier: …]
      ) :: {:ok, %{review_id: Ecto.UUID.t(),
                   source_definition_id: Ecto.UUID.t(),
                   target_definition_id: Ecto.UUID.t(),
                   process_key: String.t()}}
         | {:error, apply_review_error()}
```

Exact call sequence, each step short-circuiting, with every partial-failure branch named:

1. `PromotionReviewStore.get_review(review_id, opts)`.
   * `{:error, :review_not_found}` → return it unchanged. **Nothing written.**
2. `PromotionDigest.verify_digest(review.plan_digest, plan_digest)`.
   * `false` → `{:error, :digest_mismatch}`. **Nothing written.** Constant-time via that
     function, never `==` — the rule `approve_review/4`'s digest gate already follows.
3. `review.status == :approved`?
   * no → `{:error, :invalid_transition}`. **Nothing written**, and critically **no
     `process_definitions` row touched.** (`mark_review_applied/2` would also reject a
     wrong-state row, but only *after* the promotion had already committed — which is
     precisely AC4's "does not re-apply" failure mode. This step is what prevents it.)
4. `Promotion.promote_definition(actor_id, review, opts)`.
   * `{:error, reason}` → call `PromotionReviewStore.mark_review_failed(review_id, opts)`
     and **ignore its result** (a concurrent transition there must not mask the real
     failure), then return `{:error, {:promotion_failed, reason}}`. **Net effect: the review
     is `:failed`; the pointer swap either never happened or rolled back inside
     `promote_definition/3`'s own transaction.**
   * `{:ok, result}` → step 5. **The pointer swap has durably committed by this point.**
5. `PromotionReviewStore.mark_review_applied(review_id, opts)`.
   * `{:ok, _}` → `{:ok, Map.put(result, :review_id, review_id)}`. The normal path.
   * `{:error, :invalid_transition}` → **still `{:ok, …}`.** The promotion has durably
     committed; the only way this fires is a concurrent transition that moved the row out of
     `:approved` after step 3, and reporting failure for an operation that succeeded would be
     worse than a stale status. Mirrors the "don't let a side-effect's own failure corrupt an
     already-durable outcome" resolution `finish_rollback/8`'s OQ-6 and
     `append_teardown_failure_event/6` already established. **Flagged as OQ-8** — a real
     judgement call a reviewer may prefer to surface instead.
   * `{:error, :review_not_found}` → same treatment as the line above (unreachable in
     practice; the row was read in step 1).
6. `opts[:permission_checker]` and `opts[:event_appender]` pass straight through to
   `promote_definition/3`, which `Keyword.fetch!`es both. `apply_review/4` adds no defaults
   of its own — same no-default stance, same reason.

`promote_definition/3` itself is **not modified**.

### 9.4 `Letflow.Definitions.PromotionArtifact.from_json/1` — NEW

R8's request body carries `artifact` as a JSON object; `apply_promotion_assertion_rerun/6`
takes a `%PromotionArtifact{}` with
`@enforce_keys [:id, :assertions, :fixtures, :rng_seed, :non_deterministic_fields, :candidate_definitions]`
and two nested struct types. Decoding lives in the module that owns the struct.

```
@spec from_json(map()) :: {:ok, t()} | {:error, {:invalid_artifact, field :: String.t()}}
```

* Pure, no I/O, **never raises** on any input (the INV-8 stance `Letflow.Api.Validation`
  already takes) — every branch returns a tagged value. A struct with `@enforce_keys` raises
  on a missing key if built naively, so this function must validate *before* constructing,
  not construct and rescue.
* Field mapping (string key → struct field): `"id"`→`:id` (string, required);
  `"assertions"`→`:assertions` (list of `%Assertion{id: String.t(), payload: String.t()}`,
  required, may be empty); `"fixtures"`→`:fixtures` (list of
  `Letflow.SandboxPool.FixtureLoader.FixtureRow.t()` — **read that struct's real field list
  before writing this**; it is reused verbatim per `PromotionArtifact`'s own moduledoc);
  `"rng_seed"`→`:rng_seed` (non-negative integer, required);
  `"non_deterministic_fields"`→`:non_deterministic_fields` (list of dot-path strings,
  required, may be empty); `"candidate_definitions"`→`:candidate_definitions` (list of
  `%CandidateDefinition{process_key, graph_json, variable_schema}`, required, may be empty).
* Unknown keys inside `artifact` are ignored, matching the `Map.take/2` discipline of the
  outer body validation.
* On the first structural problem, returns `{:error, {:invalid_artifact, "<key path>"}}`. The
  key path is for logs and tests; §7.5 deliberately does not put it in the response.

### 9.5 `Letflow.Definitions.Promotion.promote_active_definition/5` — NEW

R10 (ENV-03) has `test_tenant_id` + `process_key` and **no review**.
`promote_definition/3` takes a `%PromotionReview{}` and derives source/target/process_key/
base_version by `Jason.decode!`ing `review.serialised_plan`. The shapes do not match, and the
mismatch is real, not cosmetic.

**Resolution: refactor, do not duplicate.** `promote_definition/3`'s body already splits
cleanly — a decode-and-extract prelude, then `do_promote_definition/7` taking the four
extracted values plus `actor_id`, `review` and `event_appender` explicitly.

1. Generalise the existing private core so it takes `review_id :: Ecto.UUID.t() | nil`
   instead of the whole `%PromotionReview{}`. It appears to use the review only for
   `review.id` in the event payload (`append_promotion_event/9`) — **verify that against the
   shipped body before relying on it**; if the core reads any other review field, the split
   point moves accordingly.
2. `promote_definition/3` becomes the thin review-decoding wrapper. **Zero behaviour
   change**, which the existing REQ-037 test suite must confirm — if any of those tests
   needs changing, the refactor was wrong.
3. Add the second public entry point:

```
@spec promote_active_definition(
        actor_id :: Ecto.UUID.t(),
        source_tenant_id :: Ecto.UUID.t(),
        target_tenant_id :: Ecto.UUID.t(),
        process_key :: String.t(),
        opts :: promote_opts()
      ) :: {:ok, %{definition_id: Ecto.UUID.t(),
                   version: String.t(),
                   status: ProcessDefinition.status(),
                   source_definition_id: Ecto.UUID.t()}}
         | {:error, promote_error()}
```

* `base_version` for the conflict re-check is read from the **target tenant's current ACTIVE
  row** (`nil` when the target has none), not from a caller-supplied value — R10 parses no
  body (§8.4), so there is nothing else it could be.
* `review_id` is `nil` in the appended `DEFINITION_PROMOTED` event payload. **The
  platform-event-appender requirement's `DEFINITION_PROMOTED` `json_schema` must therefore
  admit a null `review_id`** (`"review_id" => %{"type" => ["string", "null"]}`), because
  `Registry.validate_payload/3` runs on every append — an ENV-03 promotion genuinely has no
  review, and forcing a synthetic id would put a lie in the audit log. Carry this into that
  requirement's text; it is a constraint REQ-077 imposes on it, and §11 OQ-1 records that
  the three schemas must match their producers' real attrs shapes.
* Returns the new row's `id`, `version` and `status`, which `promote_result/0` does not
  carry, because R10's response body needs all three (§7.7).
* `opts` is the same `promote_opts()`: `permission_checker` and `event_appender`
  `Keyword.fetch!`'d, `tenant_classifier` defaulted. No new no-default stance introduced.

**Rejected alternative, stated so it is not re-proposed:** synthesising a `PromotionReview`
row for R10 so it could reuse `promote_definition/3` unchanged. That would write a
`promotion_reviews` row for an operation that has no review — corrupting exactly the audit
table the PRM-04/05 gate exists to keep honest — and would trip the per-tenant `plan_digest`
unique index in ways nobody would predict.

### 9.6 Three new `Letflow.Api.Error` constructors, and one extension mechanism

REQ-066 §0.2 deliberately deferred `problemEmptyPromotionPlan` and
`problemInvalidPromotionSource` ("PRM-01 AC3/AC4 … is itself a separate, not-yet-landed
Letflow requirement"). **REQ-077 is that requirement**, and REQ-066 §0.2 already specifies
how: add the constructor to `Letflow.Api.Error` following the identical five-line shape.

```
@spec empty_promotion_plan(String.t()) :: t()       # 422, type <base>"empty-promotion-plan",     title "Empty Promotion Plan"
@spec invalid_promotion_source(String.t()) :: t()   # 422, type <base>"invalid-promotion-source", title "Invalid Promotion Source"
```

PROVENANCE (historical, not current decision authority):
Both match `src/api/errors.zig:254-272` exactly (slug, title, status 422).

PROVENANCE (historical, not current decision authority):
The third is **not** deferred-by-REQ-066 and is a genuine addition: R1/R7/R10's conflict
response must carry the `conflicts` array (`promotion_review.zig:197-209`), and
`Letflow.Api.Error`'s only extension member today is `errors`, whose shape is
`[FieldError.t()]` and whose meaning is validation-specific.

```
@spec promotion_conflict(detail :: String.t(), conflicts :: [PromotionConflict.conflict_detail()]) :: t()
# 409, type <base>"promotion-conflict", title "Promotion Conflict"
```

**Mechanism (a change to REQ-066's shipped module — REVIEWER attention required):** add one
optional field to `Letflow.Api.Error`, `extensions :: map() | nil`, defaulting to `nil`, and
have `serialise/1` merge its string-keyed entries into the emitted document **only when it is
a non-empty map**. This is exactly the pattern `errors` already uses — REQ-066's own
`@typedoc` explains why `errors` is excluded from the `@derive` list and merged conditionally
in `serialise/1` instead, so every non-extension document stays byte-identical. `extensions`
follows that precedent verbatim, and RFC 9457 §3.2 defines extension members as the correct
mechanism for exactly this.

Constraints, so the change cannot regress REQ-066's own tests:
* `nil`/empty `extensions` must produce a byte-identical document to today's — REQ-066's
  `error_test.exs` pins the five-key contract and must still pass **unmodified**.
* `extensions` is **not** added to the `@derive {Jason.Encoder, only: [...]}` list, for the
  same reason `errors` is not.
* No existing constructor gains an `extensions` argument.

**Rejected alternative:** dropping the `conflicts` array and returning a bare 409. A client
that cannot see *which* process_key and *which* version conflicted has to re-fetch and
re-diff to find out — the array is the actionable half of the response.

---

## 10. The no-`Repo`-in-routes constraint (AC6) — as a structure and as a check

### 10.1 The structural claim

Every one of R1–R10 makes exactly one kind of database-touching call: a call into
`Letflow.Definitions`, `Letflow.Definitions.Promotion`, `Letflow.Definitions.PromotionPlan`,
`Letflow.Definitions.PromotionConflict`, `Letflow.Definitions.PromotionDigest` (pure),
`Letflow.Definitions.PromotionArtifact` (pure) or
`Letflow.Definitions.PromotionReviewStore`, threading the `[prefix: …]` keyword fragment
`Letflow.Api.Context.scoped_repo_opts/1` produced. No router module in this design aliases
`Letflow.Repo`, imports `Ecto.Query`, or builds a query fragment.

That is also why §9 exists: every gap the routes hit (a review read, an assertion-run read,
the apply orchestration, the artifact decode, the ENV-03 entry point) is closed by **adding a
function to a context module**, never by reaching into the repo from a handler.

### 10.2 The verifying greps

AC6 names `lib/letflow/api/`. The route modules are in `lib/letflow/routers/` (F-6), so the
AC's literal grep would pass vacuously. Run **both**, and treat both as the criterion:

```
# The AC's literal grep. Nothing this requirement adds to lib/letflow/api/ touches the
# database (the only additions there are Letflow.Api.Error constructors, §9.6).
grep -rn "Repo\." lib/letflow/api/

# The grep AC6 is actually about -- the route modules this requirement writes.
grep -rn "Repo\." lib/letflow/routers/
grep -rn "import Ecto.Query" lib/letflow/routers/
grep -rn "alias Letflow.Repo" lib/letflow/routers/
```

All must return zero hits **in the three modules this requirement touches**
(`promotions.ex`, `definitions.ex`, `tenants.ex` under `lib/letflow/routers/`). Record the
actual command output in the handoff per `core-directives.md` — do not report "should be
clean."

**Moduledoc hazard:** see §7.8's final paragraph. The three moduledocs must state the
delegation invariant without writing the literal `Repo.` substring, or the files documenting
compliance become the files failing the check — a mistake this project has already made once
and recorded in `docs/anti-patterns.md`.

---

## 11. Open questions — not silently resolved

**OQ-1 — RESOLVED by REVIEWER. Not an open question: a recorded dependency and a required
split.**

**Ruling: Option (B), built as its own separate requirement. REQ-077 is blocked on it for
R7, R8, R9 and R10.**

**Why (A) is rejected — a harder reason than "it contradicts a comment".**
`req023-event-store-schema.md` §3.1.3 records that the schema was shaped *around* the
sentinel having no projection row: *"Platform/scheduler events therefore carry an
`instance_id` with no projection row, which an FK would reject"* (`:428-429`). Seeding such
a row inverts the recorded rationale for an FK's absence, and leaks the sentinel into every
`instance_projections` read path — every list, every status scan, every `idx_proj_status`
partial-index match.

**Why (B) is right — it completes a design already on record rather than diverging from
one.** `event_store.ex:349-353` records a prior REVIEWER Step-2d ruling that *"append/2
never originates an instance_projections row"*. A sibling entry point that skips the
projection machinery is the idiomatic complement to that ruling, not a contradiction of it.
Two sub-questions an earlier revision of this design left for the implementer are now
**closed**:

* **M2 (`assign_sequence`) is safe to reuse verbatim.** `instance_sequence` is a separate
  table from `instance_projections`, keyed on `instance_id`, inserted `on_conflict:
  :nothing`, with no FK — and `20260816120002_create_instance_sequence.exs`'s own header
  states it "inserts this row before any projection row necessarily exists."
* **M6 must be skipped as well as M1, and this is forced, not a choice.**
  `update_projection/3` (`event_store.ex:545-556`) pattern-matches on
  `active_instance_guard: %InstanceProjection{}`, which never exists for the sentinel — so
  the new function needs its **own** `Ecto.Multi` dropping **M1 and M6** and reusing M2
  (`assign_sequence`) / M3 (`claim_idempotency`) / M4 (`insert_event`) verbatim. This is
  not a guard-clause tweak to `append/2`.

**No migration is needed** — neither `events` nor `instance_sequence` carries an FK on
`instance_id`.

**Why (C) — a no-op or unavailability-reporting appender — is rejected for all four
routes.** For R9 it fabricates a client-visible `event_id` and a persisted
`superseded_by` value. For R7 it turns a committed promotion into a reported failure. For
R8 it silently discards a real `PROMOTION_ASSERTION_TEARDOWN_FAILED` event on a path that
does not exist today, which is a new gap rather than an unchanged one. Full reasoning per
route in F-5.2.

**Why the split into a separate requirement is mandatory**, on three independent grounds:

1. **It is another requirement's explicitly deferred scope.**
   `lib/letflow/design/req026-event-read-archive-platform-sentinels.md:144` lists *"Real
   emission of scheduler/platform events using the three sentinel constants"* as not built
   there, owned by *"a later stage's engine work"*, citing `requirements.yaml:1119-1121`
   ("this requirement only needs the constants to exist"). REQ-077 absorbing it would
   swallow scope another requirement deliberately deferred.
2. **It touches four `done` requirements' modules** (REQ-022's provisioning, REQ-023's
   schema assumptions, REQ-024's registry, REQ-025's `append/2`).
3. **Not one of REQ-077's six acceptance criteria mentions an event.** A routes requirement
   is the wrong place for an event-store entry point.

**The appender requirement is substantially larger than "add a function"** — recorded here
so it is not under-sized when it is drafted:

* `append/2` **rejects `:tenant_id` outright** (`event_store.ex:216-222`,
  `{:error, :tenant_id_not_accepted}`), yet the `PROMOTION_ASSERTION_TEARDOWN_FAILED`
  producer puts `tenant_id` directly in its attrs map (`definitions.ex:1775-1780`).
* `append/2` requires `:payload` and `:idempotency_key`, and **none of the three producers
  supplies either** — verified against all three attrs maps (`promotion.ex:317-325`,
  `definitions.ex:1310-1316`, `definitions.ex:1774-1780`).
* `Registry.validate_payload/3` runs on every append, so **three seeded `json_schema`s must
  match three separate producers' real attrs shapes**.

So the work is: a new entry point + a translation/idempotency-derivation module + three
event-type schemas + a `TenantProvisioning` seed change + a backfill for already-provisioned
tenants.

**Dependency to record:** REQ-077's `depends_on` gains **the platform-event-appender
requirement (id TBD, proposed `depends_on: [REQ-023, REQ-024]`)** alongside REQ-072.
**No id is minted here** — REQ-ANALYST assigns requirement ids, and any concrete id
appearing in a gate report is a proposal, not an assignment.

### OQ-1's consequence — acceptance-criterion reachability

PROVENANCE (historical, not current decision authority):
| AC | Reachable before the appender requirement lands? |
|---|---|
| **AC1** (all six modules; five `promotion_review.zig` handlers each) | **NO** — R7 (apply) is blocked, and `promotion.zig` (R10), `promotion_assertion.zig` (R8) and `definition_rollback.zig` (R9) are each blocked in full, which means three of the six modules have no reachable route at all. R1/R2/R5/R6 are reachable. |
| **AC2** (assertion-run idempotency, one row, two identical responses) | **NO** — R8 is the only route AC2 exercises. §8.1's mechanism is unaffected; only reachability changes. |
| **AC3** (per-tenant `plan_digest`) | **YES** — submit (R1) touches no events. |
| **AC4** (409 on already-applied, nothing re-applied) | **Effectively NO** — the fixture needs a review that genuinely reached `:applied` with a real promoted target definition to assert "unchanged" against, and reaching `:applied` goes through R7. |
| **AC5** (four cross-tenant 404s) | **3 of 4** — get (R4), approve (R5) and reject (R6) are reachable; apply (R7) is blocked. |
| **AC6** (no repo access in routes) | **YES** — structural, verifiable by §10.2's greps against whatever ships. |

Sequencing consequence: REQ-077 cannot be completed before the platform-event-appender
requirement. Four of its six acceptance criteria are wholly or partly gated on it.

**OQ-2 (SECURITY-REVIEWER) — the always-true `permission_checker` leaves cross-tenant
definition reads unenforced on R1/R2/R10.** Fully stated in §7.9. §4's Option-A decision
bounds it to `PLATFORM_ADMIN` callers only, which is why this is an explicit ruling rather
than a blocker — but it must be ruled on, and the ruling must be recorded, because any later
requirement widening access to these routes inherits the gap.

**OQ-3 — R4 drops R-Co's `assertions` and `needs_review_package` response keys** (§7.3).
Both are computed inline in the Zig handler from the plan entries; no Letflow context module
produces either, and building a `NEEDS_REVIEW`-package generator is a domain feature. Confirm
dropping them is acceptable for REQ-077, or file a follow-up requirement.

**OQ-4 — §4's Option A means PLATFORM_ADMIN-only on all ten routes, including plan preview.**
This is stricter than a reading where `PROCESS_DESIGNER` (who can create and activate
definitions) could at least *preview* a promotion diff. §4.2 gives four reasons it is right
today, the strongest being that widening it would hand a non-admin role the §7.9 cross-tenant
read. Confirm the consequence is intended; if a later requirement wants designer-visible
previews, it must resolve OQ-2 first.

**OQ-5 — `with_authorized_scope/4` will exist in four copies** (§2.5). This design follows
the per-router-copy precedent rather than extracting a shared helper, to avoid scope creep
into two `done` modules. REVIEWER may reasonably rule the other way.

**OQ-6 — two R-Co response fields are not ported**: `human_readable` on R2 (D-9; no
`PromotionPlan.t()` field and no context function produces one) and a populated `warnings` on
R10 (§7.7; R-Co fills it from a semantic gate Letflow does not port — the key is emitted as
`[]` to keep the shape stable). Both are domain features, not route work.

**OQ-7 — artifact validation granularity** (§7.5/§9.4). `from_json/1` returns the first
structural problem as one tagged tuple and the route emits a generic 422. A recursive
`FieldConstraint`-based validation producing a proper per-field `errors` array would be
better for clients and is not designed here.

**OQ-8 — `apply_review/4` swallows a `mark_review_applied/2` race** (§9.3 step 5), returning
`{:ok, …}` for a promotion that durably committed even though the review's status could not
be advanced. Follows `finish_rollback/8`'s and `append_teardown_failure_event/6`'s
established "an already-durable outcome is not undone by a side-effect's failure"
resolution, but it is a judgement call.

**OQ-9 — CLOSED.** Both bounds are now read off the source and pinned in §8.4:
`plan_digest` is exactly 64 lowercase hex characters
(`:crypto.hash(:sha256, …) |> Base.encode16(case: :lower)`, `promotion_digest.ex:57-63`),
and `process_key`'s `max_length` is 255 (`process_definitions.name` is `:string` with no
`size:`, `20260816193001_create_process_definitions.exs:77`). §8.4 also records the reason
the digest bound is pinned in **both** directions: `verify_digest/2` calls
`:crypto.hash_equals/2`, which raises `ArgumentError` on unequal-length binaries, so the
bound is a crash guard on attacker-controlled input rather than a cosmetic limit.

**OQ-10 — `Ecto.Query.CastError` on a non-UUID id may not be the only raise path.** §3.2 and
§9.1 close the `promotion_reviews` primary-key case, and §3.2 applies the pre-cast to R8 as
well, so every route here is safe. The open question is whether
`apply_promotion_assertion_rerun/6` — which takes `review_id` as a plain binary into a
changeset with an FK — surfaces a malformed id as a tagged error rather than a raise for a
future *non-HTTP* caller. ELIXIR-DEV should confirm and extend the defensive cast into that
function if not.

---

## 12. Test specifications (shapes, for TEST-DESIGNER)

### 12.0 What "through the real router" means for AC1 — SETTLED, do not re-decide

AC1 says each module needs "at least one end-to-end test **through the real router**." Two
precedents exist in this codebase and the phrase does not by itself pick between them, so
this design picks, with reasons, rather than leaving TEST-DESIGNER to guess:

* **Sub-router dispatch** — `Letflow.Routers.Tenants.call(conn, @opts)` with
  `conn.assigns[:auth_context]` set directly (`test/letflow/routers/tenants_test.exs:33,57,61`;
  `identity_test.exs` likewise). The established precedent, from three gate-passed
  requirements (REQ-073/074/075).
* **Full-stack dispatch** — `Letflow.Router.call(conn, Letflow.Router.init([]))` with a
  real `Bearer valid-test-token` against a real provisioned tenant
  (`test/letflow/plugs/api_pipeline_integration_test.exs:103`).

**Decision: sub-router dispatch satisfies AC1 for all ten routes (option (a)), plus one
mandatory full-stack smoke test (§12.9).**

Reasoning:

1. **It is a real router.** `Letflow.Routers.Promotions.call/2` runs real `Plug.Router`
   `:match`/`:dispatch`, real path-segment matching and parameter extraction, the real
   clause-ordering in §2.2, and the real `match _` 404 fallback. AC1's own object — "status
   and response shape" — is entirely determined at this layer. What sub-router dispatch
   skips is the *pipeline* (`Plug.Parsers`, trace-id assignment, `AuthPipeline`,
   `TenantStatus`), none of which REQ-077 authors and all of which REQ-071 already covers
   with its own integration test.
2. **It is the established precedent for exactly this kind of test**, set by the three
   route requirements immediately preceding this one and accepted by the gates each time.
   Diverging would make REQ-077's suite inconsistent with its three siblings for no
   coverage gain.
3. **Full-stack dispatch for the happy paths is currently blocked by a test-support gap,
   and closing it buys nothing here.** §4's Option A makes every route PLATFORM_ADMIN-only,
   so a full-stack 2xx test needs a PLATFORM_ADMIN token — but **both token doubles
   hardcode `realm_access.roles`**: `test/support/token_verifier_double.ex:36` and
   `configurable_token_verifier_double.ex:69,106` both emit `["VIEWER"]` (and `:80` emits
   `[]`). `ConfigurableTokenVerifierDouble`'s grammar has `"realm-token:" <> realm`,
   `… <> ":sub=" <> subject`, and `"no-sub-token:" <> realm` forms (`:40-48`) — **no roles
   parameter**. `Letflow.Plugs.AuthPipeline` takes roles straight from claims, so a
   full-stack PLATFORM_ADMIN test would require extending a shared test-support module used
   by other suites, to re-verify path matching that sub-router dispatch already verifies.

**But option (a) alone leaves one real gap, which §12.9 closes.** §12.8's denial test uses
hand-set `assigns`, so nothing in the suite would catch it if `AuthPipeline`'s real
claim→roles mapping disagreed with what the tests assume — every promotion route could be
admin-locked (or worse, open) in production with a fully green suite.

The fix needs **no token-double change**, because the gap is on the *denial* side and the
existing double already produces a non-admin role: §12.9 dispatches a real
`Bearer valid-test-token` (`["VIEWER"]`) full-stack at a promotion route and asserts **403**.
A VIEWER token traversing the real pipeline and being denied by the real `:Unknown` gate
proves the gate is live end-to-end. The positive case stays at the sub-router layer.

**If a later requirement genuinely needs a full-stack PLATFORM_ADMIN test**, the
token-double extension is the prerequisite, and the grammar it should add is a roles-bearing
form parallel to the existing ones — e.g. `"realm-token:" <> realm <> ":roles=" <> comma_separated`,
composing with the existing `:sub=` form. Named here so that requirement does not have to
rediscover it; **not** a build requirement for REQ-077.

---

Every test dispatches through a **real router** — `Letflow.Routers.Promotions.call/2`,
`Letflow.Routers.Definitions.call/2` or `Letflow.Routers.Tenants.call/2` with a conn whose
`assigns.auth_context` is populated as `Letflow.Plugs.AuthPipeline` would — except §12.9,
which is full-stack. Tenants come from the provisioned-tenant fixture REQ-073/075's suites
already use. Every caller carries `roles: ["PLATFORM_ADMIN"]` unless the test is
specifically about denial (§12.8, §12.9).

**Sequencing:** the tests for R7, R8, R9 and R10 — and therefore AC1, AC2 and AC4 — cannot
be written against a working route until the platform-event-appender requirement lands
(§11 OQ-1). TEST-DESIGNER should expect to build this suite in two passes, not one.

PROVENANCE (historical, not current decision authority):
### 12.1 AC1 — one end-to-end test per route module, five for `promotion_review.zig`

Ten happy-path tests, one per §1 row, each asserting the HTTP status **and** the exact
response key set (`Map.keys(Jason.decode!(resp.resp_body)) |> Enum.sort()` against the literal
list from §7), not merely the status.

### 12.2 AC2 — assertion-run idempotency

```
POST /promotions/<review_id>/run-assertions  (plan_digest D, artifact A)  -> r1
POST /promotions/<review_id>/run-assertions  (plan_digest D, artifact A)  -> r2

assert r1.status    == r2.status
assert r1.resp_body == r2.resp_body     # byte-identical; no trace_id in a success body
assert <count of promotion_assertion_runs, prefix-scoped to the tenant> == 1
```
The row count is the AC's own named check. Byte-identity is what §8.1's omission of
`idempotent_hit` buys.

### 12.3 AC3 — per-tenant `plan_digest` uniqueness

Seed two provisioned tenants, each with source/target definitions producing the **same** plan
and therefore the same digest. Submit from each.
```
assert resp_a.status == 201 and resp_b.status == 201
assert body_a["plan_digest"] == body_b["plan_digest"]
assert body_a["review_id"]   != body_b["review_id"]
assert <count of promotion_reviews, prefix: schema_a> == 1
assert <count of promotion_reviews, prefix: schema_b> == 1
```
Counts must be `prefix:`-scoped per tenant, never a single global count — a global count of 2
would also pass while proving nothing about isolation.

### 12.4 AC4 — approving an already-applied review

Drive a review to `:applied` through the real routes (submit → approve → apply), capture the
target tenant's ACTIVE `process_definitions` row (`id` **and** `version`), then:
```
resp = POST /promotions/<id>/approve  (correct plan_digest)
assert resp.status == 409
assert Jason.decode!(resp.resp_body)["detail"] ==
         "review is not in a state that permits this transition"
assert <review row>.status == :applied                          # unchanged
assert <target ACTIVE definition>.id      == captured.id        # unchanged
assert <target ACTIVE definition>.version == captured.version   # unchanged
```
Plus §6.2's gate-ordering case: a **self**-approval attempt on the same `:applied` review
returns **403**, not 409, because `approve_review/4`'s self-approval gate runs before its
status pre-check. Pin it so a future gate reorder is caught.

### 12.5 AC5 — four explicit cross-tenant tests

Tenant A creates a review; tenant B calls each of R4/R5/R6/R7 with A's review id. For each:
```
resp_cross  = <B calls the route with A's review_id>
resp_absent = <B calls the route with a freshly generated, never-issued UUID>

assert resp_cross.status == 404 and resp_absent.status == 404
assert strip_trace_id(resp_cross.resp_body) == strip_trace_id(resp_absent.resp_body)
```
Byte-identity of the bodies, not just matching statuses — that is what INV-5 asks for and
what `Response.not_found/1`'s zero-arity signature guarantees. A fifth, non-AC-required case
worth adding: B's call with a malformed (non-UUID) id, asserted identical to the other two
(§3.2).

### 12.6 AC6 — the greps

Run §10.2's commands and record the literal output in the handoff. Also assert, as a plain
source-text test or a REVIEWER check, that none of the three touched router modules aliases
`Letflow.Repo` or imports `Ecto.Query`.

### 12.7 Coverage of the §6.2 matrix

The full 18-cell matrix does not need 18 route tests. A table-driven test that seeds a review
in each of the six statuses (via the store's own transition functions, `prefix:`-scoped) and
drives all three routes against each is sufficient, and is the shape that will actually stay
in sync with the matrix. The `:superseded` row needs `supersede_review/3`; the `:failed` row
needs `mark_review_failed/2`.

### 12.8 §4's authorization decision — the pinning test

Two assertions, both against `Letflow.Api.Authorization` directly (a pure module, no conn
needed), for **every** path template in §1:

```
assert Authorization.endpoint_policy_key(<method>, <path_template>) == :Unknown

for roles <- [["PROCESS_DESIGNER"], ["PROCESS_OPERATOR"], ["TASK_WORKER"], ["AGENT_RUNNER"], []] do
  ctx = %AccessContext{user_id: ..., roles: Authorization.roles_from_strings(roles)}
  assert Authorization.evaluate_access(ctx, :Unknown).kind == :Deny403
end

ctx_admin = %AccessContext{user_id: ..., roles: [:PLATFORM_ADMIN]}
assert Authorization.evaluate_access(ctx_admin, :Unknown).kind == :Allow
```

Plus one end-to-end denial through a real router: a `PROCESS_DESIGNER` caller gets **403**
with `detail == "insufficient permissions"` on `POST /promotions/plan`, and the response body
contains **no** `entries` key and no plan data of any kind.

This is what makes §4's Option A auditable rather than an invisible fallthrough: if a later
requirement adds a promotion clause to `Letflow.Api.Authorization`, the first assertion fails
and forces the change to be deliberate rather than silently re-gating ten routes.

### 12.9 Full-stack smoke test — the gate is live through the real pipeline (§12.0)

One test, dispatching through `Letflow.Router.call/2` rather than a sub-router, closing the
gap §12.0 identifies: every other test hand-sets `conn.assigns[:auth_context]`, so none of
them would catch a disagreement between `AuthPipeline`'s real claim→roles mapping and what
the suite assumes.

```
tenant = insert_tenant_for_realm!("bpm-default")     # api_pipeline_integration_test.exs's own fixture

conn =
  conn(:post, "/api/v1/promotions/plan", Jason.encode!(%{...valid body...}))
  |> put_req_header("content-type", "application/json")
  |> put_req_header("authorization", "Bearer valid-test-token")
  |> Letflow.Router.call(Letflow.Router.init([]))

assert conn.status == 403
assert conn.assigns.auth_context.roles == ["VIEWER"]          # the double's real output
body = Jason.decode!(conn.resp_body)
assert body["detail"] == "insufficient permissions"
refute Map.has_key?(body, "entries")                          # no plan data in a denial
```

Why this is the right smoke test, and why it needs no test-support change:

* It exercises the **whole** stack — `Plug.Parsers`, trace-id assignment, `AuthPipeline`
  (real token verification, real claim→roles mapping, real tenant resolution),
  `TenantStatus`, the `/promotions` forward from §2.1, and the sub-router's own matching —
  and proves §4's gate denies a real non-admin caller end-to-end.
* It uses the **denial** direction deliberately: the existing doubles already emit
  `["VIEWER"]` (`token_verifier_double.ex:36`), which is exactly the non-admin role this
  test needs. The positive direction would need a PLATFORM_ADMIN token and therefore the
  token-double extension §12.0 declines to require.
* Asserting `conn.assigns.auth_context.roles == ["VIEWER"]` pins the mapping itself, so if
  a future change to `AuthPipeline` or the doubles alters what reaches
  `Authorization.roles_from_strings/1`, this test fails rather than silently passing while
  the gate's real behaviour drifts.
* `POST /promotions/plan` is chosen as the target because it is the one route that is
  **not** blocked by OQ-1 and has a request body worth parsing — so this test is runnable in
  the first of the two passes §12.0's sequencing note describes.
