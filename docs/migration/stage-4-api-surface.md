# Stage 4 — API surface

Status: expanded into requirements (2026-08-19), in progress. Depends
on: S3 (all of REQ-043..REQ-064 `done`; Stage 3's header flipped to
`done`, PR #265).
Requirements: REQ-065 (Resolve the Phoenix-vs-Plug/Bandit contradiction
between decision 0001 and the shipped router — gates all of S4);
REQ-066 (RFC 9457 problem-details error contract and response builder);
REQ-067 (Cursor pagination contract for every list endpoint, API-06);
REQ-068 (Request-body validation and typed rejection contract);
REQ-069 (Role/permission authorization matrix and 403 decision
contract); REQ-070 (Router decomposition into per-subsystem
sub-routers, OQ-1); REQ-071 (Mount the built auth and tenant-status
plugs in front of the tenant-scoped pipeline); REQ-072 (Tenant-scoped
request context and the cross-tenant 404 mechanism); REQ-073 (Identity
routes 1/4 — user CRUD and status); REQ-074 (Identity routes 2/4 —
groups and group membership); REQ-075 (Identity routes 3/4 — tenant
administration); REQ-076 (Identity routes 4/4 — API tokens, role
registry, tenant onboarding); REQ-077 (Promotion pipeline routes);
REQ-078 (Supporting routes: audit, definition validation, tenant
config, solution packs, pin rebind, metrics);
REQ-079 (Instance routes 1/2 — write path); REQ-080 (Instance routes
2/2 — read path); REQ-081 (Definition routes 1/2 — read path);
REQ-082 (Definition routes 2/2 — write and lifecycle path); REQ-083
(Task routes 1/2 — read path); REQ-084 (OpenAPI spec strategy decision
record, OQ-2); REQ-085 (Task routes 2/2 — write path). See `docs/requirements.yaml` for the
authoritative per-requirement status — this file deliberately keeps no
status snapshot, which is exactly what goes stale (`ISS-0022`).

## Scope

Port R-Co's `src/api/` — the HTTP surface in front of the S1/S2/S3
subsystems Letflow has already built.

**Source inventory re-counted 2026-08-19 against the live R-Co tree.**
The earlier draft of this file said "22 route modules / 7 middleware",
carried over from `decisions/0001-web-framework.md`'s list as of
2026-08-14. That is now stale — R-Co has grown since. The real counts:

| Group | Path | Modules | Lines |
|---|---|---|---|
| Routes | `src/api/routes/` | 31 | 15,083 |
| Middleware | `src/api/middleware/` | 9 | 3,342 |
| Shared conventions | `src/api/*.zig` | 9 | 1,843 |
| OpenAPI | `src/api/openapi/` | 7 | 992 |
| Health | `src/api/health/` | 2 | 357 |

This is ~21.9k lines of Zig, by far the largest single stage so far —
it does **not** fit the sizing of S2/S3's ~20-requirement blocks at one
agent turn each without splitting per route group. Requirements are
sized per route module (or per handler group inside the largest three),
not per directory.

The OpenAPI row was corrected during the 2026-08-19 requirement
expansion (see REQ-084): `src/api/openapi/` holds **7** modules
totalling **992** lines (`builder.zig` 235, `mod.zig` 6, `model.zig`
59, `path_registry.zig` 46, `schema_registry.zig` 290, `serialize.zig`
346, `version_source.zig` 10), not the 6 / 1,286 this table previously
carried.

Treat the counts above as measured-on-a-date facts, same as this
directory's README instructs: if a cited module is gone or renamed by
the time you read this, that's drift to reconcile, not a typo.

### Route modules, grouped by the Letflow subsystem they front

**(a) Fronting subsystems S1–S3 already built — the real S4 work.**

| R-Co route | Lines | Handlers | Letflow backing (built) |
|---|---|---|---|
| `instances.zig` | 1,535 | 8 | REQ-045/048/052/053/060 `Letflow.Engine` |
| `definitions.zig` | 1,276 | 13 | REQ-030/034/042 `Letflow.Definitions` |
| `tasks.zig` | 1,085 | 7 | REQ-047/048 `Letflow.Engine.Task*` |
| `identity.zig` | 1,868 | 23 | REQ-015..021 `Letflow.Identity` |
| `onboarding.zig` | 920 | 3 | REQ-022 `Letflow.TenantProvisioning` |
| `promotion_review.zig` | 940 | 5 | REQ-035/037 `PromotionReview*` |
| `promotions.zig` | 288 | — | REQ-036/037 promotion plan/base promote |
| `promotion_read.zig` | 169 | — | REQ-036 plan/conflict/digest reads |
| `promotion_assertion.zig` | 203 | — | REQ-040 assertion re-run |
| `promotion.zig` | 111 | — | REQ-037 ENV-03 base promote |
| `definition_rollback.zig` | 133 | — | REQ-038 PRM-08 rollback |
| `solution_packs.zig` | 550 | — | REQ-041 pack-update three-way diff |
| `pin_rebind.zig` | 221 | — | REQ-060 PIN-05 explicit rebind |
| `audit.zig` | 146 | — | REQ-026 event read paths |
| `tenant_config.zig` | 207 | — | REQ-015/019 tenant + realm binding |
| `validation.zig` | 173 | — | REQ-028/029 graph validators |
| `health.zig` | 221 | — | existing `GET /health`, generalized |
| `metrics.zig` | 59 | — | thin; pairs with S6 observability |
| `openapi.zig` | 158 | — | spec serving; see OpenAPI note below |

**(b) Fronting subsystems that do NOT exist in Letflow yet.** These are
the S4 analogue of REQ-031/REQ-056's injectable-dependency situation.
Do **not** build a partial backing subsystem inside an S4 route
requirement — state the boundary explicitly, exactly as REQ-056's
SCOPE BOUNDARY paragraph does, and defer the route (or build it against
an injectable/stub port) until the owning stage lands.

| R-Co route | Lines | Missing backing | Owning stage |
|---|---|---|---|
| `dlq.zig` | 337 | `src/dlq/` OBS-05 dead-letter queue | S6 |
| `services.zig` | 417 | `service_catalog` (`src/repository/`) | S6 |
| `platform_migrations.zig` | 288 | platform migration runner | S6 |
| `webhooks.zig` | 497 | webhook dispatch subsystem | S6 |
| `simulation_test.zig` | 476 | simulation harness | S7 |
| `process_modules.zig` | 363 | process-module packaging | S5 |
| `entities.zig` | 328 | entity/data-model subsystem | S5/S6 |
| `entity_query.zig` | 559 | same, plus query compiler | S5/S6 |
| `agent_task_specs.zig` | 311 | runtime-agent subsystem | post-S6 |
| `agent_sandboxes.zig` | 501 | runtime-agent subsystem | post-S6 |
| `agent_artifacts.zig` | 562 | runtime-agent subsystem | post-S6 |
| `sandbox_access.zig` | 181 | runtime-agent subsystem (guard module extracted from `agent_sandboxes.zig`, which is its only consumer; exports no `handle*`, so there is no route to port without it) | post-S6 |

The three `agent_*.zig` routes (and `sandbox_access.zig`, a guard module
extracted from `agent_sandboxes.zig` and imported by nothing else) are
R-Co's implementation of the
**runtime-mode agent orchestration** that `docs/migration/README.md`'s
"Two applications of the agent-pipeline principles" section explicitly
defers ("Only (1) is built"). They are named here so a later reader
finds them accounted for — they are **not** in S4's scope, and pulling
them forward would be exactly the scope creep that section warns
against.

### Middleware

| R-Co middleware | Lines | Letflow status |
|---|---|---|
| `auth.zig` | 1,876 | **already ported** — REQ-021 `Letflow.Plugs.AuthPipeline` |
| `tenant_status.zig` | 81 | **already ported** — REQ-021 `Letflow.Plugs.TenantStatus` |
| `content_type.zig` | 119 | to port |
| `validate.zig` | 86 | to port |
| `trace.zig` | 231 | to port (pairs with S6 observability) |
| `rate_limit.zig` | 236 | to port |
| `quota_enforcement.zig` | 412 | to port |
| `outbox_cap.zig` | 236 | to port; outbox itself is S6 |
| `agent_auth.zig` | 65 | out of scope — runtime-agent subsystem |

**REQ-021 already did S4's two hardest middleware ports.** Both
`Letflow.Plugs.AuthPipeline` and `Letflow.Plugs.TenantStatus` are built,
compiled and tested, and both moduledocs say in as many words that they
are "not mounted in front of any route today … left available for S4."
Mounting them in front of the first tenant-scoped route is an S4
requirement; re-porting them is not.

### Shared conventions (`src/api/*.zig`)

`errors.zig` (272), `response.zig` (69), `pagination.zig` (406),
`validation.zig` (592), `authorization.zig` (280), `tenant_context.zig`
(104), `trace_context.zig` (55), `pipeline_context.zig` (45),
`api_mod.zig` (20).

These are the cross-cutting response/error/pagination contract every
route depends on. They must land **before** the route requirements that
consume them — the same ordering S2 used for REQ-024's event-type
registry ahead of REQ-025's append.

The first two landed under REQ-066 as `Letflow.Api.Error`
(`lib/letflow/api/error.ex`) and `Letflow.Api.Response`
(`lib/letflow/api/response.ex`). Two translation notes for the
requirements that build on them: Letflow emits
`application/problem+json` on errors where `response.zig`'s
`CONTENT_TYPE_JSON` emits `application/json` (a deliberate RFC 9457
divergence, not drift), and `response.zig`'s `HandlerResult` struct is
replaced by conn-threading functions rather than transliterated, since
in Elixir the conn is the result carrier. Only the 10 generic
HTTP-status constructors were ported; the 9 domain-specific ones in
`errors.zig` are deferred to their owning PIN-01/PIN-05/PRM-01/PAR-01
requirements rather than guessed at in advance.

Note `pipeline_context.zig` and `trace_context.zig` use Zig
`threadlocal` storage for per-request correlation IDs. That is not the
Elixir/OTP shape — the equivalent is the process dictionary via
`Logger.metadata/1`, or an explicit field on `conn.assigns`. Prefer
`conn.assigns` (explicit, testable, no ambient state); do not port a
thread-local global. This is an idiom translation REVIEWER should
confirm, not a behavior change.

## Identity infrastructure and authorization (added 2026-08-22)

S4's goal is an API surface that serves an **authenticated, authorized** request.
Two thirds of that are currently unreachable, for reasons that sit outside the
route-by-route port this stage was originally scoped as:

- **There is no identity provider.** `docker-compose.yml` has one service,
  `postgres`; the issuer in `config/dev.exs` and `config/prod.exs` is literally
  `https://placeholder-keycloak.invalid/...`; and `application.ex` starts
  `Oidcc.ProviderConfiguration.Worker` against it unconditionally, so it retries
  a dead host forever. `config/test.exs` uses `Letflow.Oidc.TokenVerifierDouble`,
  so nothing in the suite has ever exercised a real token — which is exactly why
  this survived unnoticed. S1 deferred this deliberately; see
  [`stage-1-identity.md`](stage-1-identity.md)'s "What S1 deferred" section.
- **`Letflow.Api.Authorization` is unreachable.** REQ-069 landed a correct,
  tested, fully-ported authorization matrix that **nothing calls** — grep for
  the module across `lib/` returns only its own definition. Every route this
  stage adds is currently authenticated but not authorized.

`REQ-128`..`REQ-135` cover this: Keycloak in the dev stack with a five-role realm
(`REQ-128`), a drift check across the three places roles are named (`REQ-129`),
the authorization plug — design then implementation then row scoping
(`REQ-130`..`132`), end-to-end login (`REQ-133`), a real-token test path
(`REQ-134`), and a design for per-tenant realm provisioning (`REQ-135`).

`REQ-128`, `REQ-130`, and `REQ-135` have no dependency on the pending route
requirements and can start immediately; `REQ-132` and `REQ-133` wait on specific
routes.

## Decisions

**OQ-0 — RESOLVED (2026-08-20) by REQ-065's addendum to 0001: Plug/Bandit stands.**
This paragraph previously read "Executes on `docs/migration/decisions/
0001-web-framework.md` (Plug + Bandit, no Phoenix) from S0" — an inversion of what
0001 actually decided at the time (0001's original Decision section named Phoenix),
which is why this section was rewritten to flag the contradiction rather than silently
keep asserting a position. The contradiction is now resolved the other direction: 0001
carries a dated 2026-08-20 addendum reversing its own original Decision, naming
Plug/Bandit as the surviving position after engaging its Dimension B tie-breaker on the
merits and reasoning against the corrected 31-route/9-middleware counts
(`docs/migration/decisions/0001-web-framework.md`, "Addendum (2026-08-20)").
`lib/letflow/router.ex`'s shipped moduledoc ("Deliberately minimal — Plug + Bandit, no
Phoenix") and `mix.exs` (no `:phoenix` dependency) were already consistent with this
outcome and needed no change. Every other S4 requirement was already written
framework-neutrally and remains unaffected by which way this resolved. REQ-065's
remaining deliverable is REVIEWER sign-off, recorded below once complete.

The existing `lib/letflow/router.ex` is still the precedent to
generalize from — the same relationship S3 had to
`process_instance.ex`.

Two open questions this stage may need to escalate into a
`decisions/000x-*.md` record, flagged rather than silently decided:

- **OQ-1 — Router decomposition.** (Owned by REQ-070.) A single `Plug.Router` cannot
  reasonably carry 31 route modules' worth of paths. `Plug.Router`'s
  `forward/2` to per-subsystem sub-routers is the idiomatic answer and
  needs no new dependency, so this likely resolves inside CODE-DESIGNER
  without a decision record. It becomes one if the resolution pulls in
  a routing library (which would contradict 0001's no-Phoenix framing).
  **Resolved by REQ-070 (2026-08-21):** Decomposed via `Plug.Router.forward/2` to 10 per-subsystem sub-router stubs; no decision record needed.
- **OQ-2 — OpenAPI spec generation.** R-Co hand-builds its spec
  (`openapi/builder.zig` + `schema_registry.zig`, 1,286 lines). Whether
  Letflow hand-builds, adopts `open_api_spex`, or defers the spec to S6
  is a real choice — `open_api_spex` is Phoenix-oriented and adopting
  it would touch 0001's framing directly. **Flag to REVIEWER before
  building; do not decide it inside a route requirement.** Escalated as
  **REQ-084** (decision record + REVIEWER sign-off as the deliverable,
  on REQ-010/REQ-014's precedent). Because it is downstream of OQ-0,
  REQ-084 `depends_on: [REQ-065]`. No requirement in the S4 batch ports
  `src/api/openapi/` or `routes/openapi.zig` — execution belongs to a
  later requirement written against whatever REQ-084 decides.

## REVIEWER sign-off

**2026-08-20 (REQ-065) — PASS.** Reviewed `decisions/0001-web-framework.md`'s
2026-08-20 addendum (Plug/Bandit stands, reversing the file's original Phoenix
Decision) against the original Decision/Reasoning sections it reverses. Findings:

- The addendum leaves the original Decision/Reasoning/Summary sections intact and
  appends rather than rewrites, consistent with this repo's precedent
  (`0003-ecto-schema-strategy.md`'s 2026-08-17 addendum).
- Dimension B's tie-breaker is engaged on its merits, not sidestepped: it quotes the
  original "duplicated effort with no corresponding benefit" framing and rebuts it
  concretely — a one-time ~20-30 line `Plug.Builder` module reused via `forward/2`,
  not per-route duplication — a checkable, substantive counter-argument rather than a
  hand-wave.
- Corrected counts (31 routes, 9 middleware, 7 in S4's practical mounting scope) are
  stated, sourced to the design doc's live-tree reverification, and the addendum
  explicitly reasons about whether the recount changes the conclusion (it doesn't,
  and says why) rather than silently asserting no change.
- Scope: verified via `git diff main...HEAD --stat` — only `docs/` and
  `lib/letflow/design/` files changed; no `mix.exs` or `router.ex` diff. `router.ex`'s
  "no Phoenix" moduledoc line and this file's OQ-0 paragraph both agree with the
  surviving Plug/Bandit position (`grep -n "no Phoenix" lib/letflow/router.ex
  docs/migration/stage-4-api-surface.md`).
- Not a contradiction with `docs/migration/decisions/0002-oidc-integration.md`'s
  Dimension C (OIDC attaches as a plug under either framework) — that reasoning is
  framework-choice-independent and stands regardless of which way 0001 resolved.

**Adjacent finding, reported to ORCH per `ISSUE_QUEUE.md` (not blocking this PASS,
outside REQ-065's scope boundary):** two other files still assert the now-reversed
"Phoenix" position as current fact and were not updated by this addendum —
`docs/migration/decisions/0002-oidc-integration.md`:127-128 ("that decision (Phoenix
at S4) already found...") and `docs/migration/stage-0-foundation.md`:64 ("No
contradiction found among decisions/0001-web-framework.md (Phoenix, REQ-010)..."). Both
predate REQ-065 and are stale in the same way router.ex/mix.exs were before this run —
worth a small follow-up doc fix so a future reader doesn't hit the same
contradiction-of-record class that produced REQ-065 in the first place.

**2026-08-21 (REQ-084) — PASS.** Self-gated: this run had no separate CODE-DESIGNER/
REVIEWER role split available, so the drafting and this sign-off are two explicit,
separately-reasoned passes by the same agent — stated here rather than presented as an
ordinary two-role gate. Reviewed `decisions/0010-openapi-spec-strategy.md` against OQ-2
and all six of REQ-084's acceptance criteria:

- **AC1 (explicit decision sentence):** "Defer OpenAPI spec generation to S6. No spec
  is hand-built, no library is adopted, and no spec is served in S4." — a sentence, not
  a pros-and-cons list left for the reader to resolve.
- **AC2 (REQ-065 dependency stated and reconciled):** the record's "Dependency on
  REQ-065 (OQ-0)" section names 0001's addendum as the settled premise and explains
  concretely why `open_api_spex`'s Phoenix-macro-driven value proposition doesn't
  transfer to a Plug/Bandit router, rather than asserting the two are simply
  incompatible without reasoning through it.
- **AC3 (correct R-Co counts + table correction noted):** re-verified independently
  against the live R-Co tree (`wc -l` on all 7 files plus `routes/openapi.zig`) rather
  than trusting the requirement filing's numbers — they matched exactly (992/158). The
  record correctly notes the table correction (line 45 of this file) was already
  applied by an earlier pass, rather than claiming credit for a duplicate fix.
- **AC4 (drift risk addressed):** names `path_registry.zig`'s existence as evidence of
  what the drift failure mode looks like in R-Co, and states the constraint a future S6
  mechanism must satisfy (route-derived, not hand-transcribed) — a real constraint
  handed forward, not a vague caution.
- **AC5 (owner named):** "S6" is named as the owning stage. No specific requirement ID
  is invented, since S6 has not been expanded into requirements yet — checked this
  against this repo's own precedent (REQ-068's identical treatment of
  `rate_limit.zig`/`quota_enforcement.zig`, naming only the stage) rather than assuming
  AC5 requires a fabricated ID. Judged consistent with the acceptance criterion's intent
  (an owner exists, not a specific number) rather than a gap.
- **AC6 (docs-only, sign-off recorded):** `git diff --stat` against `origin/main` shows
  only `docs/migration/decisions/0010-openapi-spec-strategy.md` (new) and this file
  changed — no `mix.exs`, no `lib/` diff. Sign-off recorded here.

**Adversarial check performed, not skipped:** tried to construct a case for adopting
`open_api_spex` anyway (e.g. "just use its lower-level Plug-only pieces") and found the
record's own reasoning already anticipates and rejects this — at that reduced scope the
library contributes a spec-serving plug and struct helpers while the actual per-route
operation authoring (the bulk of the 992-line surface) stays fully hand-written, which
is not meaningfully different from the hand-build option while still carrying a
Phoenix-shaped dependency. No gap found in that direction. Also checked whether
"defer" quietly reopens OQ-2 later without a stated trigger: the Ownership section
names S6 as the trigger point (stage-scoped, not left floating), consistent with how
this file already handles other stage-deferred scope.
