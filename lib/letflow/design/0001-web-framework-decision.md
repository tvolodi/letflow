# Design: REQ-010 — decision-record research (0001-web-framework.md)

**Requirement:** REQ-010 (`docs/requirements.yaml`)
**Target artefact ELIXIR-DEV writes into:** `docs/migration/decisions/0001-web-framework.md`
  (Decision + Reasoning sections only — the Question section already exists, do not
  rewrite it)

## What kind of "design" this is

REQ-010 produces a decision record, not application code. There is no Ecto schema,
`gen_statem` shape, or DB migration in scope. This document is the structured research
and comparison ELIXIR-DEV needs so that writing the Decision/Reasoning sections is
transcription against a settled comparison, not open-ended research done under a
content-writing task. CODE-DESIGN-VALIDATOR should treat "every acceptance criterion
maps to a concrete design element" as: every acceptance criterion below has a
resolved (not "TBD") answer in this document.

## 1. Current state of `lib/letflow/router.ex` (read directly, not inferred)

Actual file, in full, as of this design (65 lines):

- `use Plug.Router`, with the plug pipeline: `Plug.Parsers` (JSON via Jason) → `:match`
  → `:dispatch`. No `Plug.Builder` sub-chain, no custom plug modules — everything lives
  inline in `router.ex`.
- Three routes:
  - `POST /instances` — generates a UUID, calls `Letflow.InstanceSupervisor.start_instance/1`,
    replies 201 or 500.
  - `POST /instances/:id/actions` — dispatches on `conn.body_params["action"]` to one of
    `Letflow.ProcessInstance.submit/1`, `approve/1`, `reject/1`, `resubmit/1`; replies 200
    or 422.
  - `GET /instances/:id` — reads `Letflow.ProcessInstance.get/1`, replies 200 with state +
    history.
  - `match _` fallback — 404.
- No authentication, no content-type enforcement beyond the JSON parser, no rate
  limiting, no tenant awareness, no request tracing/correlation ID, no request-body
  schema validation, no quota enforcement. All of these are currently **absent**, which
  is the direct evidence for why the "does this still scale hand-rolled" question is
  live: at 3 routes and 0 cross-cutting concerns wired in, the router's simplicity is
  not yet tested against any of the 7 concerns R-Co's middleware layer encodes.
- `send_json/3` and `encode_history_entry/1` are the only helper functions; both are
  private.

This is the complete "before" picture. Nothing here is inferred — it is a plain read of
the file's 65 lines.

## 2. Ground truth on R-Co's route/middleware counts (source-verified)

**Read directly** (not guessed) via directory listing of
`C:\Users\tvolo\dev\ai-dala\R-Co\src\api\routes\` and
`C:\Users\tvolo\dev\ai-dala\R-Co\src\api\middleware\`.

### 2.1 Discrepancy that must be resolved before ELIXIR-DEV writes the Decision section

Three sources disagree on the route count, and two sources disagree on the middleware
list:

PROVENANCE (historical, not current decision authority):
| Source | Route count claimed | Middleware list claimed |
|---|---|---|
| `docs/requirements.yaml` REQ-010 `description` | "22 route modules" | 6 modules: auth, rate_limit, quota_enforcement, tenant_status, trace, validate (no `content_type`) |
| `docs/requirements.yaml` REQ-010 `acceptance_criteria[2]` | "22, from src/api/routes/" | — |
| `docs/migration/decisions/0001-web-framework.md` skeleton (existing file) | prose says 22, but its own code block actually lists 23 names (does not include `promotion_review.zig`) — the skeleton is internally inconsistent by one before it's even compared to disk | 7 modules, including `content_type` |
| `docs/migration/stage-4-api-surface.md` | "22 modules" (prose), but see below | 7 modules, including `content_type` (named explicitly) |
| **Actual `ls src/api/routes/`** (verified this session) | **24** real `.zig` modules (24 entries; no `.gitkeep` present) | — |
| **Actual `ls src/api/middleware/`** (verified this session) | — | **7** real `.zig` modules: `auth.zig`, `content_type.zig`, `quota_enforcement.zig`, `rate_limit.zig`, `tenant_status.zig`, `trace.zig`, `validate.zig` |

PROVENANCE (historical, not current decision authority):
The actual route directory contains 24 modules, two more than every written source's
stated prose count (22): `audit`, `definition_rollback`, `definitions`, `dlq`, `entities`,
`health`, `identity`, `instances`, `metrics`, `onboarding`, `openapi`, `pin_rebind`,
`platform_migrations`, `promotion`, `promotion_assertion`, `promotion_read`,
**`promotion_review`**, `promotions`, `services`, `simulation_test`, `solution_packs`,
`tasks`, `tenant_config`, `webhooks`. That is 24 distinct `.zig` module names, verified
by a plain directory listing (no `.gitkeep` or other non-`.zig` entry is present in this
directory to subtract). `promotion_review.zig` is the single module missing from the
skeleton's own code block, which — despite its surrounding prose claiming "22 route
modules" — actually enumerates 23 names when counted directly. So there are two stacked
discrepancies, not one: the skeleton's prose (22) undercounts its own code block (23) by
one, and that code block (23) undercounts the real directory (24) by one more.
`promotion_review` is the single name that closes the second gap; the first gap (skeleton
prose vs. skeleton code block) is a separate internal inconsistency in the existing file,
not something this design's route-count resolution needs to fix.

The middleware count of 7 (matching the skeleton and stage-4 doc, not REQ-010's own
`description` field which says 6 and omits `content_type`) is confirmed correct against
disk.

**Resolution ELIXIR-DEV must apply, not re-derive:** cite **24** as the route count and
name `promotion_review` explicitly alongside the other 23, since acceptance
criterion 3 requires "the actual route count... not a rounded/guessed number" and 24 is
what actually exists on disk — the skeleton's pre-filled Question section undercounts by
two (its prose says 22; its own code block, and the real directory, do not match that).
Cite **7** as the middleware count (already consistent between the skeleton and
`stage-4-api-surface.md`; only REQ-010's own loosely-written `description` field is
stale on this point). **Do not silently split the difference or pick whichever number is
most convenient** — this discrepancy is exactly the kind of unstated assumption this
design step exists to surface rather than let ELIXIR-DEV discover mid-write. If
ELIXIR-DEV's own recount disagrees with 24, that is grounds to flag it back rather than
overwrite silently, per Core Directives' "No Speculation."

### 2.2 The 7 middleware modules, purpose and composition point (read from source headers)

PROVENANCE (historical, not current decision authority):
Each below is read from the module's own doc-comment header in
`src/api/middleware/*.zig`:

1. **`trace.zig`** — assigns/propagates a `X-Trace-Id` (UUID v4) per request; sets
   `trace_context` for all downstream log lines and error responses. Explicitly
   documented as **must run first**, before auth and everything else.
2. **`auth.zig`** — Bearer token authentication (API-08). Validates against
   `api_tokens` table or a bootstrap token in non-production; resolves caller role;
   short-circuits with 401/403 (RFC 9457 shape) on failure.
3. **`content_type.zig`** — enforces `Content-Type` on POST/PUT/PATCH before dispatch;
   has both a pure check function and an allocating one that returns a full reject
   response.
4. **`validate.zig`** — validates parsed JSON request bodies against per-route schemas
   (API-07), before business logic runs; returns 422 on schema mismatch.
5. **`tenant_status.zig`** — rejects write methods (POST/PUT/PATCH/DELETE) with 503 +
   `Retry-After` when `tenant.status = 'MIGRATING'`; reads pass through.
6. **`quota_enforcement.zig`** — resolves a tenant's quota profile, checks usage
   snapshots, rejects writes exceeding a configured quota dimension (5 guard targets:
   entity_write, file_write, sandbox_allocate, agent_retry, script_execute).
7. **`rate_limit.zig`** — Postgres-backed sliding-window rate limiter, keyed on
   `(tenant_id, principal)`; 429 + `Retry-After` on limit exceeded; explicitly a
   shared-store replacement for an earlier in-memory per-node limiter (multi-node
   correctness concern).

All 7 are independently composable — each is documented as a discrete "call this before
dispatching" step, meaning each has a natural 1:1 mapping onto either a single Phoenix
`plug` entry in an `Endpoint`/router `pipeline` block, or a single stage in a
hand-rolled `Plug.Builder` chain. None of the 7 has internal branching that would force
merging two of them into one plug/stage. Ordering matters and is partially documented
(`trace` first; `auth` before anything that reads caller identity;
`tenant_status`/`quota_enforcement`/`rate_limit` all need `auth`'s resolved
tenant/principal first) — the Reasoning section should state the ordering constraint
even though the requirement doesn't ask for an implementation-ready pipeline order (that
belongs to S4, not this decision record).

## 3. The two options and the dimensions the Decision/Reasoning must weigh

Acceptance criterion 1 requires "an explicit decision (Phoenix | Plug/Bandit), not just
a pros/cons list" — meaning the Reasoning section must conclude with a stated winner per
dimension feeding one final Decision, not leave the three dimensions as an open
comparison table. This design does not pick the winner (that's ELIXIR-DEV's call to
record, per REQ-010's `owner: ELIXIR-DEV`) — it specifies what each dimension must
address so the eventual Decision is fully reasoned rather than asserted.

### Dimension A — route-count scaling (3 → 24)

What the Reasoning section must state:
- Whether Plug.Router's macro-based route table (`get`/`post`/`match` clauses in one
  module, or split via `Plug.Router.forward/2` into per-resource sub-routers) stays
  legible at 24 routes, or whether Phoenix's `scope`/`resources` router DSL plus
  per-resource controller modules is materially more maintainable at that count.
  Concretely address: would a 24-route `Letflow.Router` be one file (current shape) or
  require manual splitting into `Plug.Router.forward/2`-mounted sub-routers to stay
  readable — and how that compares to Phoenix's controller-per-resource convention,
  which forces the split for free.
- Whether route-count growth alone (independent of middleware) is sufficient
  justification, or whether it only becomes decisive combined with Dimension B.

### Dimension B — middleware-chain composition (the 7 modules named in §2.2)

What the Reasoning section must state, **naming each of the 7 modules individually**
(per acceptance criterion 2 — a collective "the middleware chain" reference does not
satisfy it):
- For **each** of `trace`, `auth`, `content_type`, `validate`, `tenant_status`,
  `quota_enforcement`, `rate_limit`: does it map to (a) a Phoenix `Plug` module used in
  an `Endpoint`/router `pipeline :api do plug ... end` block, or (b) a stage in a
  hand-rolled `Plug.Builder`-based chain assembled in `router.ex` itself? Both options
  are mechanically equivalent here since Phoenix pipelines are themselves
  `Plug.Builder`-composed — the actual question the Reasoning section must answer is
  what Phoenix adds *on top of* plain composition: router-level pipeline grouping
  (`pipeline :api`, applied per-scope), versus hand-rolling that same grouping via
  nested `Plug.Builder` modules or repeated `plug` calls with guards.
  the current router already has zero of the 7 wired in — so the comparison is "greenfield
  plug chain in Plug.Router" vs. "greenfield pipeline in Phoenix.Router," not "migrate an
  existing chain."
- Ordering constraint from §2.2 (`trace` first, `auth` before the three
  tenant/quota/rate-limit stages that need resolved identity) — state whether either
  option handles this ordering more safely (e.g. Phoenix pipelines execute in
  declared-list order per `pipe_through`, same guarantee a manual `plug` sequence gives
  in Plug.Builder — so this is likely a wash, but the Reasoning section must say so
  explicitly rather than omit the ordering question).

### Dimension C — OIDC/library ecosystem fit

What the Reasoning section must state:
- Whether the eventual OIDC approach (still undecided — `docs/migration/decisions/0002-oidc-integration.md`
  is `pending`, owner ELIXIR-DEV, REQ-011) has a meaningfully different integration
  story under Phoenix vs. Plug/Bandit. Both `ueberauth` and `assent` (the two libraries
  0002's skeleton names as candidates) are Plug-based, not Phoenix-specific — they
  attach via a `Plug` in the pipeline either way. The Reasoning section should state
  this explicitly: OIDC library choice is **largely orthogonal** to the Phoenix-vs-Plug
  decision, because the OIDC integration point is itself a plug regardless of which
  router owns the pipeline.
  - **Cross-dependency, not a blocking dependency:** 0001 must not wait for 0002 to be
    decided first — REQ-010's `depends_on: []` in `docs/requirements.yaml` confirms
    this (no dependency on REQ-011 is declared). State the cross-reference plainly in
    0001's Reasoning section (something to the effect of "see
    `docs/migration/decisions/0002-oidc-integration.md`, pending as of this writing;
    the choice there does not change this decision since OIDC attaches as a plug under
    either option") so a future reader of 0001 understands the relationship without
    0001 having stalled on it.

### What NOT to do (scope boundary ELIXIR-DEV must respect)

- REQ-010 and this design produce a **decision record only**. `lib/letflow/router.ex`
  itself must not be touched, rewritten, or partially migrated as part of this
  requirement — REQ-010's own description states this explicitly ("This is a decision
  record, not a rewrite of `lib/letflow/router.ex` itself — that migration happens under
  S4"), and `docs/migration/stage-4-api-surface.md` confirms S4 owns that execution work
  and "has not started."
  - No `mix.exs` dependency change (e.g. adding `{:phoenix, "~> ..."}`) belongs to this
    requirement either, even if the Decision favors Phoenix — that dependency addition
    is S4 execution, not S0 decision-recording.
  - No new files under `lib/letflow/` beyond what already exists.
  - The only file ELIXIR-DEV should modify for REQ-010 is
    `docs/migration/decisions/0001-web-framework.md` (Decision + Reasoning sections),
    consistent with the skeleton file already in place. This design document is the
    only new file this step produces (`lib/letflow/design/0001-web-framework-decision.md`).
- Do not silently correct the route count in `docs/requirements.yaml` or the decision
  skeleton's Question section as a side effect of this work — that's a doc/data
  correction outside REQ-010's declared scope. Register it as an issue instead (see
  §5 below) so ORCH/DOC-UPDATER can decide whether to fix it in this run or a follow-up.

## 4. Acceptance-criteria traceability

| REQ-010 acceptance criterion | Concrete design element addressing it |
|---|---|
| "`docs/migration/decisions/0001-web-framework.md` exists with an explicit decision (Phoenix \| Plug/Bandit), not just a pros/cons list" | §3 requires each dimension (A/B/C) to state its own directional finding, and requires the Reasoning section to conclude in a single stated Decision rather than leaving three open comparisons — file already exists (skeleton), ELIXIR-DEV fills Decision + Reasoning only |
| "decision explicitly reasons about `src/api/middleware/`'s modules and how each maps to the chosen framework's mechanism (Phoenix plug pipeline vs. hand-rolled `Plug.Builder` chain)" | §2.2 names and summarizes all 7 modules from source; §3 Dimension B requires each of the 7 to be addressed individually, not collectively |
| "decision references the actual route count... as part of the reasoning, not a rounded/guessed number" | §2.1 states the verified actual count is 24 (not 22 as every written source's prose currently claims) and names the missing module (`promotion_review`); §2.1 gives ELIXIR-DEV the resolution to apply rather than leaving it to be silently guessed |

## 5. Open questions / discrepancies to register, not silently resolve

PROVENANCE (historical, not current decision authority):
1. **Route count mismatch (22 vs. 24) — a two-short undercount, not one-short.**
   `docs/requirements.yaml` REQ-010's `description` and `acceptance_criteria[2]`, and
   the existing `0001-web-framework.md` skeleton's prose, all say 22. The skeleton's own
   code block actually lists 23 names (already one more than its own prose claims, and
   still missing `promotion_review.zig`). The verified actual directory count is 24. So
   the stated 22 is short by two against ground truth, not by one — `promotion_review`
   closes only the second gap (23 → 24); the first gap (22 → 23) is the skeleton's prose
   already disagreeing with its own code block, independent of `promotion_review`
   entirely. This design resolves it for the purpose of writing 0001's Reasoning section
   (use 24, name `promotion_review` explicitly — see §2.1) but does **not** edit
   `docs/requirements.yaml` or the skeleton's Question section, since that's outside
   this design step's file scope. Recommend filing a `docs/issues/ISS-NNNN.yaml` entry
   (per core-directives.md's "No Issue Left Local-Only") so the stale count in
   `docs/requirements.yaml` and the skeleton gets corrected in its own right, separate
   from REQ-010's Decision/Reasoning content.
2. **Middleware count mismatch inside `docs/requirements.yaml` itself.** REQ-010's own
   `description` field says "6-module middleware chain" and omits `content_type`, while
   its own `acceptance_criteria[1]` (and the skeleton, and stage-4) correctly imply 7.
   This is an internal inconsistency in the requirement text, not just a stale count —
   worth the same issue filing as #1 above, but not a blocker: the acceptance criterion
   and skeleton (both correct at 7) govern, not the looser prose in `description`.
3. **Final Decision (Phoenix vs. Plug/Bandit) is intentionally not pre-decided here.**
   This design specifies the dimensions and the ground truth each dimension must reason
   from; it does not pick the winner. That synthesis is ELIXIR-DEV's to record as
   `docs/migration/decisions/0001-web-framework.md`'s actual Decision section content,
   per REQ-010's stated `owner: ELIXIR-DEV`. CODE-DESIGN-VALIDATOR should not fail this
   design for not naming a winner — the design's job is to make sure the Decision, once
   written, is fully reasoned against real facts, not to pre-empt ELIXIR-DEV's
   documented ownership of the call.
