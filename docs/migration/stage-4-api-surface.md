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

PROVENANCE (historical, not current decision authority):

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

PROVENANCE (historical, not current decision authority):
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

PROVENANCE (historical, not current decision authority):

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

PROVENANCE (historical, not current decision authority):

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

PROVENANCE (historical, not current decision authority):
**Update (2026-08-30, REQ-191 and REQ-192 done):** the `services.zig` row is
now fully ported. `service_catalog` (REPO-07/SVC-01/SVC-03) shipped as
`Letflow.ServiceCatalog` — schema, migration and context module (REQ-191) —
and its HTTP route layer (SVC-04) shipped as `Letflow.Routers.Services` and
`Letflow.Routers.AdminServices` (REQ-192): `GET /api/v1/services`
(tenant-scoped) and `GET/POST/PATCH/DELETE /api/v1/admin/services`
(platform-admin-only). `services.zig`'s 417-line route surface is fully
unported now. See `requirement_status.v6.yaml`'s REQ-191 and REQ-192 `done`
entries for gate results.

PROVENANCE (historical, not current decision authority):
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

PROVENANCE (historical, not current decision authority):

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

PROVENANCE (historical, not current decision authority):
`errors.zig` (272), `response.zig` (69), `pagination.zig` (406),
`validation.zig` (592), `authorization.zig` (280), `tenant_context.zig`
(104), `trace_context.zig` (55), `pipeline_context.zig` (45),
`api_mod.zig` (20).

These are the cross-cutting response/error/pagination contract every
route depends on. They must land **before** the route requirements that
consume them — the same ordering S2 used for REQ-024's event-type
registry ahead of REQ-025's append.

PROVENANCE (historical, not current decision authority):
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

PROVENANCE (historical, not current decision authority):
Note `pipeline_context.zig` and `trace_context.zig` use Zig
`threadlocal` storage for per-request correlation IDs. That is not the
Elixir/OTP shape — the equivalent is the process dictionary via
`Logger.metadata/1`, or an explicit field on `conn.assigns`. Prefer
`conn.assigns` (explicit, testable, no ambient state); do not port a
thread-local global. **Resolved by REQ-072 (2026-08-22):** `Letflow.Api.Context`
carries the trace id as an explicit `conn.assigns[:trace_id]` field, mirrored into
`Logger.metadata/1` for log correlation only (never `Process.put/2`/an ETS table
directly) — REVIEWER's confirmation is recorded below.

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
  **Update (2026-08-23, REQ-131 done):** no longer accurate. `Letflow.Api.Authorization`
  is now reachable router-wide via `Letflow.Plugs.Authorize` +
  `Letflow.Api.AuthorizedRouter`, a mandatory plug that superseded the
  per-router `with_authorized_scope/4`/`with_authorization/4` convention
  (both helpers deleted). All 53 already-shipped call sites across
  identity/audit/definitions/instances/onboarding/tenants/tasks migrated
  onto it, and three previously-silent authorization gaps (instances
  rebind-pins/reconstruct, solution-packs export/install, definitions
  `/validate`) were closed by giving each a real policy key. See
  `requirement_status.v4.yaml`'s REQ-131 `done` entry for gate results.

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
PROVENANCE (historical, not current decision authority):
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
PROVENANCE (historical, not current decision authority):
- **AC3 (correct R-Co counts + table correction noted):** re-verified independently
  against the live R-Co tree (`wc -l` on all 7 files plus `routes/openapi.zig`) rather
  than trusting the requirement filing's numbers — they matched exactly (992/158). The
  record correctly notes the table correction (line 45 of this file) was already
  applied by an earlier pass, rather than claiming credit for a duplicate fix.
PROVENANCE (historical, not current decision authority):
- **AC4 (drift risk addressed):** names `path_registry.zig`'s existence as evidence of
  what the drift failure mode looks like in R-Co, and states the constraint a future S6
  mechanism must satisfy (route-derived, not hand-transcribed) — a real constraint
  handed forward, not a vague caution.
PROVENANCE (historical, not current decision authority):
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

**2026-08-21 (REQ-071) — PASS.** Mounted `Letflow.Plugs.AuthPipeline` then
`Letflow.Plugs.TenantStatus` in `Letflow.Plugs.ApiPipeline` ahead of every `/api/v1/*`
sub-router — reviewed against idiom/scope/supervision plus this run's own load-bearing
deliverable, **OQ-14's fail-open-vs-fail-closed confirmation**
(`lib/letflow/design/req021-auth-plug-pipeline.md` §6.4/§10).

PROVENANCE (historical, not current decision authority):
- **OQ-14 — independently confirmed, PASS on fail-closed.** Read
  `lib/letflow/plugs/tenant_status.ex` in full: `check_write_pause/2`'s `Repo.get(Tenant,
  tenant_id)` call (line 59) is wrapped in no `try`/`rescue`/`with {:ok, _} <-` anywhere in
  the module — a genuine DB error during this lookup propagates as a crash of the handling
  process, not a silent pass-through. This diverges deliberately from `tenant_status.zig`'s
  own fail-open behavior (R-Co lets a pool-exhaustion or query failure through). Evidence
  this is real, not aspirational: `test/letflow/plugs/api_pipeline_integration_test.exs`'s
  AC5 test (`"a malformed tenant_id crashes only its own request process..."`) drives a
  malformed `tenant_id` straight at `TenantStatus.call/2` and asserts the crash
  (`{:crashed, %Ecto.Query.CastError{}}`) via `Task.await`, concurrently with a second,
  valid-tenant request whose own conn passes through un-halted — both re-run directly this
  session (`mix test test/letflow/plugs/api_pipeline_integration_test.exs`: 21 passed, 0
  failures) rather than trusted from ELIXIR-DEV's own handoff claim alone.
- **Judgment on the tradeoff, not a rubber stamp.** Agree fail-closed is the right choice
  here, for the reason §6.4 itself gives and this review independently endorses: a
  tenant-write-pause during migration is a data-integrity safeguard, and a DB-level fault
  significant enough to break this single-row lookup is already a fault serious enough that
  silently waving writes through (R-Co's choice) risks writing into a tenant mid-migration
  precisely when the DB is least trustworthy — worse than the alternative (surfacing the
  fault as a 500 via the existing Bandit/Plug per-request crash isolation, matching this
  project's process-per-request fault model rather than adding bespoke swallowing logic).
  Fail-open's real argument (an unrelated DB hiccup shouldn't block all writes
  platform-wide) is weaker in this specific codebase than in R-Co's, because Letflow has no
  existing fail-open precedent elsewhere in the plug chain to stay consistent with — this is
  a fresh module, not a retrofit onto an established fail-open convention.
- **Supervision integrity, unaffected by this decision.** A crash here terminates only the
  one Bandit request-handling process for that request; `Letflow.Repo`,
  `Letflow.InstanceSupervisor`, and every other supervised child in
  `lib/letflow/application.ex`'s `:one_for_one` tree are untouched — consistent with
  REQ-071's own Test 3 (see below).
- **Test 3 / supervision open question, verified directly rather than trusted.** Read
  `lib/letflow/application.ex`: `Oidcc.ProviderConfiguration.Worker` (registered as
  `Letflow.Oidc.DefaultProvider`) is a plain child of `Letflow.Supervisor`, whose strategy
  is `:one_for_one` (line 32) — the standard OTP restart guarantee applies with no custom
  restart logic layered on top, so killing it does get it automatically restarted under the
  same name. `test/letflow/router_test.exs`'s Test 3 (`"GET /health returns 200 while
  Letflow.Oidc.DefaultProvider is dead"`) kills it with `Process.exit(pid, :kill)` and
  asserts `/health` still returns 200 — re-run this session (`mix test
  test/letflow/router_test.exs`: 17 passed, 0 failures) and confirmed it leaves no bad state
  for later tests: `Letflow.Oidc.DefaultProvider` is only ever consumed by
  `Letflow.Oidc.TokenVerifier` inside `AuthPipeline`, and this suite's own
  `TokenVerifierDouble` (used by every other test needing a verified token) never touches
  the real Oidcc worker at all, so no other test in this async-true file depends on that
  singleton's liveness.
- **Idiomatic/no crutch.** Both plugs remain simple `@behaviour Plug` modules with linear
  `call/2` clauses — no hand-rolled state machine, no singleton process holding shared
  mutable state standing in for supervision. `AuthPipeline`'s five-step orchestration and
  `TenantStatus`'s method-allowlist short-circuit are both plain function pipelines, not a
  crutch masquerading as a process.
- **Scope.** `git diff main...HEAD --stat` against `main` touches exactly: the two plug
  moduledocs, the two new/extended test files, the design doc, and run bookkeeping
  (`docs/requirements.yaml`, `docs/status/*`, `handoffs/*`) — no unrelated file. No new
  abstraction (behaviour, macro, generic plumbing) was introduced beyond what REQ-071's
  mounting task actually needed.
- **Decision-record consistency.** `Letflow.Plugs.ApiPipeline`'s declared order
  (`plug(Letflow.Plugs.AuthPipeline)` then `plug(Letflow.Plugs.TenantStatus)`, both ahead of
  `:match`/`:dispatch`) matches §6.3's calling convention and does not contradict
  `docs/migration/decisions/0001-web-framework.md`. Diffed each moduledoc's actual new text
  against the design doc's §2 replacement prose directly (not trusted from either handoff)
  — both moduledocs read the design's exact replacement paragraphs, substantively
  unchanged.

No rework requested. `docs/issues/` has no new type-safety gap worth filing from this
diff — both plugs' new transition logic (method allowlist, tenant-status match) is already
closed-set over a `Ecto.Enum`-backed `status` field and a fixed `@write_methods` list, not
a case a struct/type change would newly make unrepresentable.

**2026-08-21 (REQ-072) — PASS.** Reviewed `lib/letflow/api/context.ex`
(`Letflow.Api.Context`) against REQ-072's seven acceptance criteria and this
file's own threadlocal-translation note above.

PROVENANCE (historical, not current decision authority):
- **Idiom translation confirmed.** `tenant_context.zig`/`trace_context.zig`/
  `pipeline_context.zig`'s Zig `threadlocal` per-request storage becomes an
  explicit `conn.assigns` field (`:trace_id`), mirrored into `Logger.metadata/1`
  strictly for log-correlation — read the module directly and confirmed the one
  `Logger.metadata/1` call is the public logging API, not this module reaching
  into the process dictionary itself; `grep -rn "Process\.\(put\|get\)\|:ets\."
  lib/letflow/api/` returns zero hits.
- **The load-bearing security property** — `scoped_repo_opts/1` derives its Ecto
  `:prefix` solely from `conn.assigns[:auth_context][:tenant_id]`, is 1-arity (no
  caller-supplied tenant/schema/prefix parameter slot exists), and returns an
  error tuple rather than falling through to an unscoped query — confirmed by
  reading the function body directly, not by trusting SECURITY-REVIEWER's prior
  pass alone (`handoffs/WF02-REQ072-20260822/step-02c-security-reviewer.json`).
- **Cross-tenant-404 test soundness (AC4/AC5)** — this is the property every
  future S4 route inherits, so it warranted more than a read-through: both
  TEST-DESIGN-VALIDATOR (Step 3b) and RELEASE-VALIDATOR (Step 5) independently
  mutated `scoped_repo_opts/1` to leak a cross-tenant row and confirmed the test
  suite caught the regression each time, then cleanly reverted — real,
  demonstrated evidence the test discriminates a broken implementation rather
  than an assertion it "should."
- **Scope.** `git diff main...HEAD --stat` touches exactly: the new module, one
  plug-mount edit in `lib/letflow/plugs/api_pipeline.ex` (first in the chain,
  ahead of `AuthPipeline`, per this file's own note above), the new test
  fixture/test file, the design doc, a `docs/anti-patterns.md` addition, and run
  bookkeeping — no `lib/letflow/routers/*.ex` sub-router touched (the design
  deliberately tests one level below full HTTP dispatch rather than inventing a
  fake production route, since those sub-routers remain REQ-070 stubs).
- **Decision-record consistency.** The "Postgres schema is the only tenant
  scoping" premise this module is built on matches
  `docs/migration/decisions/0003-ecto-schema-strategy.md` Dimension B and
  `0006-*.md` (which removed `tenant_id` from schema-isolated tables entirely) —
  re-confirmed directly against both records, not re-derived from scratch.

**2026-08-22 (REQ-074) — PASS.** Reviewed `lib/letflow/identity.ex`'s six new
group/group-membership functions and `lib/letflow/routers/identity.ex`'s six
new routes (`lib/letflow/design/req074-identity-group-routes.md`) against
idiom/scope/decision-record consistency, plus this run's two load-bearing
deliverables — **OQ-1 and OQ-3 sign-off**, both explicitly deferred to this
gate rather than to CODE-DESIGN-VALIDATOR or SECURITY-REVIEWER.

PROVENANCE (historical, not current decision authority):
- **OQ-1 (§1b/§10) — PASS, single-member removal at `DELETE
  /groups/:id/members/:user_id` is the right port target; no code change
  requested.** The requirement's own text names `handleRemoveGroupMember`
  specifically — a single-`(group_id, user_id)` handler — and no acceptance
  criterion here asks for bulk removal. R-Co's live bodyless `DELETE
  /groups/:id/members` route does something else entirely (an inline
  bulk-remove-ALL-members loop, `main.zig:1400-1430`, that silently swallows
  per-member errors via `catch {}`) — that is a materially worse operation to
  port as-is: a single caller error or race deletes every membership row in
  the group with no per-row feedback, which is the opposite of the
  care this design otherwise takes (idempotent, scoped, explicit-error-tuple
  operations throughout `identity.ex`). Porting it "additionally, at the
  bodyless path" as the design's own OQ-1 floats would mean shipping a new
  route this requirement's ACs never asked for, whose only behavioral
  precedent is dead code's error-swallowing loop — that is scope creep in the
  wrong direction, not a gap. Read `lib/letflow/routers/identity.ex`'s shipped
  `@moduledoc` (the "Group member removal" section, lines ~54-74) directly:
  it states plainly that this is a **new route shape** R-Co's own table never
  binds to that handler, not merely a pagination-shape choice — an honest
  finding, matching AC6. Verdict: ship single-member removal only; bulk-remove
  stays unported and unrequested.
PROVENANCE (historical, not current decision authority):
- **OQ-3 (§3.5/§10) — PASS, uniform `:GroupsManage` policy is correct; no code
  change requested.** `handleListGroupMembers`'s `PLATFORM_ADMIN`-exclusive
  gate (`identity.zig:533`) is itself dead code in R-Co — `grep -n
  "handleListGroupMembers(" src/main.zig` (already run at Step 1b) has zero
  route-table hits, so this gate carries no live operational precedent to
  preserve; it was never actually enforced against real traffic in R-Co
  either. Every other route in this file (created by REQ-073 and this
  requirement alike) resolves to `:GroupsManage` via one shared wildcard
  authorization clause — introducing a single handler-local role-literal
  exception here, for a listing operation with no acceptance criterion
  requesting extra restriction, would itself be the kind of undocumented
  divergence `docs/migration/decisions/` is supposed to gate, not a fidelity
  win. Judgment: correct as shipped. Flagged forward, not a blocker — if a
  later stage's product requirements call for narrower listing access, that
  should be a new, explicit decision (and likely its own
  `docs/migration/decisions/000x-*.md` entry), not silently re-derived from
  R-Co's unrouted code.
- **Idiomatic Ecto, no crutch.** `delete_group/2`'s `not exists/1`-guarded
  `Repo.delete_all/2` and `list_group_members/3`'s `join`+cursor query
  (`identity.ex:435-449`, `:479-505`) are both plain `Ecto.Query` pipelines —
  no raw SQL, no hand-rolled state machine standing in for a query. Confirmed
  `delete_group/2`'s single `prefix:` option propagates to both the outer
  query and the `not exists/1` subquery (re-derived independently of
  SECURITY-REVIEWER's own confirmation of the same fact at Step 2c).
- **AC6 moduledoc check.** Both flagged findings — §1's member-listing
  duplication (`handleListGroupMembersArray` vs. `handleListGroupMembers`) and
  §1b's member-removal routing gap — appear verbatim in the shipped
  `@moduledoc`, not only in the design doc (read directly, lines ~31-74 of
  `lib/letflow/routers/identity.ex`).
- **Scope.** `git diff main...HEAD --stat` touches exactly the expected set:
  two migrations, `identity/group.ex` (extended) and the new
  `identity/group_member.ex`, `identity.ex`, the router, `tenant_provisioning.ex`
  (manifest registration), the test file, the design doc, and bookkeeping. The
  two pre-existing-regression fixes (`identity_migration.ex`'s narrowed
  `copy_groups/2` select, and the migration renumbering to avoid a test-fixture
  collision) are both proportionate, single-purpose fixes with inline
  rationale, not scope creep riding along with this requirement.
- **Decision-record consistency.** The new `group_members` migration is
  tenant-scoped (`if prefix() do`, prefixed create/index calls) matching
  `docs/migration/decisions/0003-ecto-schema-strategy.md` Dimension B and
  `0006-identity-tables-schema-per-tenant.md`'s schema-per-tenant convention —
  no contradiction.

No rework requested. SECURITY-REVIEWER's ISS-0225 (orphaned `group_members`
row on future hard user-deletion, MINOR) is out of this gate's scope — already
filed, non-blocking, and not a type-safety gap this review would separately
file.

No rework requested.

**2026-08-22 (REQ-075, out-of-sequence pre-implementation consult) — PASS.**
Not a normal post-implementation gate: `lib/letflow/design/req075-tenant-
administration-routes.md` §4.2 (OQ-7) explicitly blocks ELIXIR-DEV from
implementing until REVIEWER signs off on a behavior-contract change to an
already-`done` module, `Letflow.Plugs.TenantStatus` (REQ-021, mounted by
REQ-071). Read the design's full §4 (both §4.1's R-Co evidence and §4.2's
recommendation), the shipped `lib/letflow/plugs/tenant_status.ex`, and
`lib/letflow/identity/tenant.ex` directly before deciding.

- **Decision: approve the design's recommended shape as-is — all HTTP
  methods, 403, PLATFORM_ADMIN-exempt — matching R-Co's actual behavior
  precisely, not the narrower write-only alternative.** Reasoning:
  `:migrating` already exists as this codebase's write-pause mechanism
  (`Letflow.Plugs.TenantStatus`'s current, unchanged behavior). If the new
  `:inactive` check were also write-only, it would be operationally
  indistinguishable from `:migrating` — a "deactivated" tenant's callers
  would keep full read access indefinitely, which contradicts what
  deactivation is for (REQ-075's own AC5 and R-Co's `getTenantAdmin`'s
  deactivate/reactivate action pair exist specifically to take a tenant out
  of service, not to pause its writes). A narrower rule would be a real
  product-behavior weakening disguised as a "minimize surface change"
  engineering caution, not a neutral simplification.
- **INV-8 does not favor the narrower alternative.** This is a plain
  authorization branch (role/status comparison, no I/O beyond the existing
  `Repo.get(Tenant, tenant_id)` this plug already performs) — not a crash
  boundary, and it introduces no new failure mode `Letflow.ProcessInstance`'s
  one-process-per-instance isolation model exists to contain. The all-methods
  rule was weighed as a real tradeoff (a deactivated tenant's caller loses
  read access too, including in-flight `GET` polling), not waved through, and
  found to be the correct call: read access surviving deactivation
  indefinitely is the actual risk here, not a crash blast radius.
- **No `docs/migration/decisions/*.md` contradiction.** Checked all 13
  records. `0003-ecto-schema-strategy.md`/`0006-identity-tables-schema-per-
  tenant.md` (schema-per-tenant) are not implicated — `tenants` is a
  default-schema table already outside that mechanism (per this design's own
  intro), and this change adds an enum value, not a scoping mechanism.
  `0013-authorization-role-set.md` (the five-role matrix) is not implicated —
  this check reads `conn.assigns.auth_context.roles` for a
  `"PLATFORM_ADMIN"` string match, the same source REQ-069/071 already
  established, no new role introduced. No record addresses tenant-status
  gating scope, so there is nothing to silently re-decide.
- **No migration needed, confirmed by direct read.** `lib/letflow/identity/
  tenant.ex:56`: `field(:status, Ecto.Enum, values: [:active, :migrating],
  default: :active)` — a plain `:string` column
  (`priv/repo/migrations/20260816000001_create_tenants.exs`, no native
  Postgres enum type, no DB `CHECK` constraint). Adding `:inactive` to the
  `values:` list is an application-layer change only.
- **Idiom/scope.** The recommended shape keeps `Letflow.Plugs.TenantStatus` a
  plain `@behaviour Plug` module with two independent, linearly-composed
  checks (new all-methods `:inactive` check, then the existing write-only
  `:migrating` check) — no new abstraction, no state machine, no singleton
  process. This is the minimum change the requirement's own AC5 needs, not
  scope creep ahead of it.

**Exact shape authorized for ELIXIR-DEV (Step 2a) — no ambiguity left:**

1. `Letflow.Identity.Tenant`: extend the `status` field's `Ecto.Enum` values
   to `[:active, :migrating, :inactive]`. No migration file. Default stays
   `:active`.
2. `Letflow.Plugs.TenantStatus.call/2`: restructure so a new check runs for
   **every** HTTP method (not gated by the existing `@write_methods` guard
   clause), and runs **before** the existing `:migrating` write-only check.
3. **Trigger condition:** the resolved tenant's `status == :inactive` **AND**
   the caller's roles (`conn.assigns.auth_context.roles`, same source
   `AuthPipeline` already populates) do **not** include `"PLATFORM_ADMIN"`.
4. **On trigger:** `send_resp(conn, 403, body) |> halt()`, `Content-Type:
   application/json`, body exactly
   `{"error": "tenant_inactive", "detail": "tenant is deactivated"}` — no
   `Retry-After` header (that header is specific to the existing 503
   write-pause response and must not appear on this new 403).
5. **No trigger** (tenant `:active`, tenant `:migrating` but not `:inactive`,
   or caller has `"PLATFORM_ADMIN"`): fall through unchanged to the existing
   `:migrating`/write-method logic exactly as shipped today — no other
   behavior of the module changes.
6. The existing no-`auth_context`/no-`tenant_id`/tenant-not-found passthrough
   cases (§ shipped moduledoc) apply identically to the new check — no new
   handling invented for those edge cases.
7. Fail-closed behavior is unchanged and extends naturally: the new check's
   own tenant lookup reuses the same `Repo.get(Tenant, tenant_id)` result
   already fetched for the existing check (one lookup, not two) — a genuine
   DB error still propagates as a process crash, matching REQ-071's
   already-signed-off fail-closed determination; do not add new
   `try`/`rescue` around this.
8. Update `Letflow.Plugs.TenantStatus`'s `@moduledoc` to document the new
   `:inactive` check alongside the existing write-pause description (mirrors
   this file's own AC6 precedent for every prior S4 sign-off).

No rework requested — this is a forward-authorizing consult, not a review of
already-written code.

**2026-08-22 (REQ-075, Step 2d post-implementation gate) — PASS.** Standard
idiom/scope gate on ELIXIR-DEV's Step 2a implementation, after SECURITY-REVIEWER's
Step 2c PASS. Primary job: decide OQ-5 (design doc §7.1), carried forward
unresolved by both the design and SECURITY-REVIEWER — whether `POST /tenants`'s
`Identity.create_tenant/1` → `TenantProvisioning.provision_tenant_schema/1` →
`TenantProvisioning.replay_migrations/2` orchestration needs a compensating
rollback if a downstream step fails after the tenant row is already committed.

- **Decision: no compensating rollback.** Read `lib/letflow/tenant_provisioning.ex`
  directly rather than assuming: `provision_tenant_schema/1` is explicitly,
  deliberately idempotent by its own `@doc` ("calling this twice for the same
  `tenant_id` is not an error"), via a transaction-scoped advisory lock +
  `CREATE SCHEMA IF NOT EXISTS` + insert-or-fetch-on-conflict registration.
  `replay_migrations/2` delegates to `Ecto.Migrator.run/4`, which only applies
  pending migrations — also safely re-callable after a partial failure.
- **A rollback would be the worse fix, not a neutral safety net.** If
  `provision_tenant_schema/1` had already succeeded and only
  `replay_migrations/2` failed, deleting the just-created `tenants` row would
  orphan a real Postgres schema plus its `tenant_schemas` registration row,
  pointing at a `tenant_id` no longer present in `tenants` — trading a
  recoverable partial state for an unrecoverable orphan. The right remediation
  is a future idempotent retry/reconciliation path (re-invoke the same two
  functions with the same `tenant_id`, or a periodic sweep), not delete-on-failure.
  Filed as ISS-0230 (non-blocking) rather than left unrecorded.
- **Idiom.** `with_authorization/4` is a clean continuation of REQ-073/074's
  established pattern; `TenantStatus.call/2`'s restructure (one shared
  `Repo.get`, then a linear `cond`) is a genuine improvement, not an awkward
  refactor. No supervision/process concern applies — this diff is stateless
  request-handling code.
- **Scope.** `git diff main...HEAD --stat` matches Step 2c's confirmed file
  list exactly; the `TenantStatus` extension is scoped precisely to the
  shape this file's own prior entry authorized — re-confirmed directly against
  the shipped `call/2`, not assumed from Step 1c's approval alone.
- **AC6/AC7 moduledoc text** — read the actual shipped `@moduledoc` in
  `lib/letflow/routers/tenants.ex` (lines 1-106): the risk statement, the
  own-tenant rule (AC3), the REQ-076 relationship (AC7), and the
  deactivation-status statement (AC5) all appear as literal prose, none
  paraphrased away.
- **No `docs/migration/decisions/*.md` contradiction** beyond what this file's
  own prior REQ-075 entry already checked for the `TenantStatus` change
  specifically.

No rework requested.
