# Design: REQ-065 — research for 0001's framework-contradiction addendum

**Requirement:** REQ-065 (`docs/requirements.yaml`), Stage S4, owner ELIXIR-DEV.
**Target artefact ELIXIR-DEV writes into:** `docs/migration/decisions/0001-web-framework.md`
  (a new, dated addendum appended in place — the existing Question/Decision/Reasoning
  sections are left intact, not deleted, per REQ-065's own instruction and the 0003/0006
  precedent this design follows).
**Also touched by ELIXIR-DEV, per REQ-065's scope:** `lib/letflow/router.ex`'s moduledoc
  (a single sentence, only if Phoenix stands), `docs/migration/stage-4-api-surface.md`'s
  Decisions section (only if it still disagrees after the addendum) and its "REVIEWER
  sign-off" section (append, per AC5).

## What kind of "design" this is

Same shape as REQ-010's own design precedent
(`lib/letflow/design/0001-web-framework-decision.md`): a decision record, not
application code. **Per REQ-065's `owner: ELIXIR-DEV` and the explicit instruction in
this design's own brief, this document does not pick a winner (Phoenix vs.
Plug/Bandit).** It re-verifies every fact ELIXIR-DEV's addendum must be reasoned from,
and — because this is a *correction* task rather than a blank-slate decision like
REQ-010 was — adds the one analysis REQ-010 didn't need: what has concretely changed
since 0001 was originally decided that a faithful re-reasoning must weigh.

## 1. Current state of the four files in play (read directly this session, not inferred)

### 1.1 `docs/migration/decisions/0001-web-framework.md`

`Status: decided (REQ-010)`. Its **Decision** section states plainly: "Letflow migrates
to **Phoenix** (router `scope`/pipeline DSL, controllers) rather than continuing to
hand-roll on plain Plug/Bandit, effective at S4." Its **Reasoning** section fully
resolves Dimensions A (route-count scaling), B (middleware-chain composition, naming
all 7 modules individually), and C (OIDC fit, orthogonal), and closes with: "Combined,
Dimensions A and B justify migrating to Phoenix at S4."

**This file already carries one self-correction.** Its own Decision section has a "Note
on the route count this decision is reasoned against" paragraph recording that the file
originally shipped with a stale 22/6 count, was corrected to 24/7 via `ISS-0001`, and
states 24/7 as current. **That correction is itself now stale** — R-Co's tree has grown
since (see §2 below); the Reasoning section's prose still says "3 → 24" (Dimension A
header) and "all 7 modules" (Dimension B header), both now behind the real 31/9. This is
exactly the "must not keep citing a number that is measurably wrong" problem REQ-065
names, applied to a file that has already been through this once.

### 1.2 `lib/letflow/router.ex`

Current moduledoc, verbatim, line 3: *"Deliberately minimal -- Plug + Bandit, no
Phoenix."* The file has shrunk since 0001 was decided: REQ-046 retired
`Letflow.ProcessInstance` and removed the three pilot-slice routes
(`POST /instances`, `POST /instances/:id/actions`, `GET /instances/:id`) that existed
when 0001's Dimension A reasoning was originally framed against "Letflow's router today
is 3 routes." **The router today has exactly two routes: `GET /health` and a catch-all
`match _` returning 404.** No Plug-pipeline plugs, no auth, no tenant awareness — same
"zero of the 7 (now 9) middleware concerns wired in" starting point 0001's Reasoning
already assumed, just with even less router-level surface than before.

### 1.3 `docs/migration/stage-4-api-surface.md`

Its **Decisions** section's "OQ-0" paragraph **already documents this exact
contradiction**, not the inverted framing REQ-065's description quotes as the original
problem. Current text states this paragraph "previously read '... (Plug + Bandit, no
Phoenix) from S0.' That is an inversion of what 0001 actually decided," quotes 0001's
real Decision (Phoenix) accurately, quotes `router.ex`'s moduledoc verbatim (including
the literal substring `no Phoenix`) as the shipped-code side of the contradiction, and
ends: "Found during the 2026-08-19 requirement expansion and escalated as **REQ-065**,
whose sole deliverable is a dated addendum to 0001 naming the surviving position plus
REVIEWER sign-off... Do not resolve this inside a route requirement." **So this
paragraph is not itself wrong or stale — it is the flag that this design/REQ-065 exists
to resolve, already correctly written.** Whether it needs any edit after the addendum
lands depends entirely on which position the addendum names (see §5, AC4).

This same file's **Source inventory** section (above the Decisions section) already
carries the corrected 31/9 counts in table form — see §2, which independently confirms
that table against R-Co's disk.

Its **"REVIEWER sign-off"** section (bottom of file) currently reads: *"(None yet —
requirements being expanded 2026-08-19; no implementation work has started.)"* — the
literal target AC5 requires an entry be appended to.

### 1.4 `mix.exs`

`deps/0`: `:ecto_sql, :postgrex, :plug, :bandit, :jason, :stream_data (test-only),
:ueberauth_oidcc`. No `:phoenix` entry. Matches REQ-065's description exactly; confirmed
by direct read this session, not inferred.

### 1.5 Incidental finding, not in REQ-065's named AC4 scope — flagged, not resolved here

`docs/guides/backend_developer_guide.md:50-51`'s project-structure diagram also carries
the phrase: `router.ex  # Plug.Router — HTTP entry point (Plug/Bandit, no Phoenix yet —
see docs/migration/decisions/0001-web-framework.md)`. AC4 only names `router.ex` and
`stage-4-api-surface.md` for the grep check, and this comment's "no Phoenix **yet** —
see [0001]" phrasing already defers to 0001 rather than asserting an independent
position, so it does not obviously contradict either outcome the way `router.ex`'s
moduledoc's unqualified "no Phoenix" does. Not required by REQ-065's stated scope, but
ELIXIR-DEV may want to update it for consistency once the addendum lands, or file it as
a follow-up issue — noted here so it isn't discovered as a surprise mid-write.

## 2. Ground-truth re-verification of route/middleware counts (independently re-run this session)

REQ-065's brief states the counts were "already spot-checked this session at 31 and 9" —
**independently re-verified here via a fresh directory listing**, not trusted from that
prior claim (per `docs/anti-patterns.md`'s "Inheriting a claim from a record instead of
re-deriving it from the source" entry — the exact failure mode this step exists to avoid
repeating).

PROVENANCE (historical, not current decision authority):
### 2.1 Routes — `C:\Users\tvolo\dev\ai-dala\R-Co\src\api\routes\*.zig`: **31** files, verified by direct glob

```
agent_artifacts.zig   agent_sandboxes.zig   agent_task_specs.zig   audit.zig
definition_rollback.zig   definitions.zig   dlq.zig   entities.zig
entity_query.zig   health.zig   identity.zig   instances.zig   metrics.zig
onboarding.zig   openapi.zig   pin_rebind.zig   platform_migrations.zig
process_modules.zig   promotion.zig   promotion_assertion.zig
promotion_read.zig   promotion_review.zig   promotions.zig
sandbox_access.zig   services.zig   simulation_test.zig   solution_packs.zig
tasks.zig   tenant_config.zig   validation.zig   webhooks.zig
```

This set matches, name-for-name, the union of `stage-4-api-surface.md`'s two route
tables ("(a) fronting subsystems already built," 19 rows, plus "(b) fronting subsystems
that do NOT exist yet," 12 rows = 31) — cross-checked exhaustively, no name present in
one list and absent from the other. **31 is confirmed correct, independently, against
both the live R-Co tree and the already-recounted stage-4 table.**

PROVENANCE (historical, not current decision authority):
### 2.2 Middleware — `C:\Users\tvolo\dev\ai-dala\R-Co\src\api\middleware\*.zig`: **9** files, verified by direct glob

```
agent_auth.zig   auth.zig   content_type.zig   outbox_cap.zig
quota_enforcement.zig   rate_limit.zig   tenant_status.zig   trace.zig   validate.zig
```

Matches `stage-4-api-surface.md`'s middleware table exactly (9 rows, same 9 names).
**9 is confirmed correct.** The two modules beyond 0001's originally-reasoned 7 are
exactly the two REQ-065's brief names: `agent_auth.zig` and `outbox_cap.zig`.

### 2.3 A nuance the addendum should not silently flatten: not all 9 middleware are in S4's practical scope right now

PROVENANCE (historical, not current decision authority):
`stage-4-api-surface.md`'s middleware table's own "Letflow status" column already draws
this line: `auth.zig` and `tenant_status.zig` are **already ported** (REQ-021,
`Letflow.Plugs.AuthPipeline`/`Letflow.Plugs.TenantStatus`, see §3.3); `content_type.zig`,
`validate.zig`, `trace.zig`, `rate_limit.zig`, `quota_enforcement.zig` are **to port**
(the same 5 of the original 7 not yet built, plus the 2 already-built ones = the
original 7 0001 reasoned over); `outbox_cap.zig` is **to port, but the outbox subsystem
itself is S6** (i.e. not actually mountable until S6 lands regardless of framework); and
`agent_auth.zig` is **out of scope entirely** — runtime-agent subsystem, explicitly
deferred project-wide per `docs/migration/README.md`'s "Two applications of the
agent-pipeline principles" section, not merely deferred past S4.

So the raw recount is 9, but the addendum has two legitimate ways to state "does the
recount change the conclusion" and should pick one deliberately rather than conflating
them: (a) report 9 as the disk-verified total (AC3's literal requirement) while noting
only 7 of those 9 are within S4's actual mounting scope, the same 7 already named
individually in 0001's Dimension B — i.e. Dimension B's per-module reasoning is
untouched in substance, only the denominator description changes; or (b) treat all 9 as
relevant to "how many cross-cutting concerns will eventually need this composition
mechanism," since `outbox_cap` is a real future consumer even if not an S4 one. Either
reading is defensible; this design surfaces the distinction rather than picking for
ELIXIR-DEV, per this step's "no silently resolving an open question" rule.

### 2.4 What the recount does, and does not, change

Both counts moved in the same direction as the growth 0001's own Dimension A prose
already reasoned from ("3 → 24, an 8x increase... real signal"): 24 → 31 routes (+29%)
and 7 → 9 middleware (+2, one in-scope-eventually via S6, one out of scope entirely).
Mechanically, more routes and more (eventually-relevant) middleware make the same
"undisciplined accumulation in one file" and "hand-building a shared pipeline mechanism"
concerns 0001's Reasoning already raises at least as strong as before, not weaker — but
whether that mechanically strengthens the case for Phoenix, is irrelevant because the
in-scope-now middleware set is unchanged (§2.3 reading (a)), or cuts some other way is
for the addendum to state explicitly, not for this design to assert. REQ-065's own text
is explicit that "the recount does not obviously flip the decision in either direction"
— this design agrees that's true and does not attempt to resolve it further.

## 3. What has changed since REQ-010's original reasoning — the fourth consideration

REQ-010 decided 0001 from a blank slate (see its own design precedent, §3's dimension
framing). REQ-065 is not a blank slate: real things have shipped since, and a faithful
re-reasoning has to weigh them as a fourth consideration alongside Dimensions A/B/C, per
this design's brief. Re-verified directly this session, not inferred from prior
narrative:

### 3.1 `lib/letflow/router.ex` shipped on Plug/Bandit, with an explicit anti-Phoenix moduledoc — but carries almost nothing Phoenix-incompatible

REQ-046 (already `done`) retired the only routes the file had ever carried beyond
`/health`. What remains is `use Plug.Router`, a `Plug.Parsers` call, and two routes.
None of this is Phoenix-incompatible surface to unwind: `Plug.Parsers` configuration
maps directly onto Phoenix's own `Plug.Parsers` usage inside an `Endpoint`, and a
`GET /health` handler is a two-line rewrite under either mechanism. **The switching cost
from the router file itself, concretely, is: rewrite ~30 lines.** This is smaller than
what existed when 0001 was first decided (which reasoned against a 3-route, ~65-line
file before REQ-046 shrank it further) — S1-S3's own work never added router surface.

### 3.2 S1-S3 were built entirely without touching the HTTP layer

`Letflow.Engine`, `Letflow.Definitions`, `Letflow.EventStore`, `Letflow.Identity`,
`Letflow.TenantProvisioning`, and every other S1-S3 module are plain
Elixir/Ecto/`gen_statem` code with no dependency on `Plug.Router` or any router-specific
API — they are called by handlers, not coupled to how requests reach them. **None of
S1-S3's ~64 already-`done` requirements' work needs to change under either framework
choice.** This means the "sunk cost" side of the ledger that would normally argue for
staying put has essentially nothing in it beyond §3.1's ~30 lines and §3.3 below.

### 3.3 `Letflow.Plugs.AuthPipeline` and `Letflow.Plugs.TenantStatus` (REQ-021) are already built and are framework-neutral by construction

Both read directly this session. Both declare `@behaviour Plug` (the plain Elixir `Plug`
behaviour — `init/1` + `call/2`), not `Plug.Router`-specific or `Phoenix`-specific
callbacks. Both moduledocs state explicitly they are "not mounted in front of any route
today... left available for S4" to mount via `plug Letflow.Plugs.AuthPipeline` ahead of
`:match` in `router.ex`. A plain `@behaviour Plug` module mounts identically as a
`pipeline :api do plug Letflow.Plugs.AuthPipeline end` entry under Phoenix or as a
`plug Letflow.Plugs.AuthPipeline` line in a hand-rolled `Plug.Router`/`Plug.Builder`
chain — **this is precisely the mechanical equivalence 0001's own Dimension B already
states** ("Both mechanisms are Plug-based under the hood"). Neither module needs to
change under either outcome. This further shrinks the switching-cost side of the ledger:
the one piece of S4-adjacent groundwork already shipped is framework-agnostic by
design, not framework-committed.

### 3.4 21 further S4 requirements were deliberately drafted framework-neutral

`stage-4-api-surface.md`'s OQ-0 paragraph states this directly: "Every other S4
requirement depends on REQ-065 transitively and is written framework-neutrally." This
was a deliberate drafting choice (confirmed by reading the file — REQ-066 through
REQ-085, 21 requirements, none of which names Phoenix or Plug/Bandit as a
precondition), made specifically so none of that backlog needs rework regardless of
which way REQ-065's addendum resolves. **This means the "cost of waiting to decide" that
existed at REQ-010's original decision point (nothing else could proceed) does not exist
at REQ-065's — the backlog was insulated from the outcome on purpose.** It does not bear
on which position should stand; it only means neither outcome carries a "we already
built 21 requirements' worth of the wrong thing" cost.

### 3.5 Net effect of §3.1-3.4 on the addendum's task

None of the above is new evidence for *which* framework should stand — that remains
Dimensions A/B/C's job, now reasoned against 31/9 instead of 24/7. What has changed is
that the **switching-cost argument that might otherwise favor "leave it on Plug/Bandit,
something is already built there"** is close to nil: ~30 lines of router file, two
already-framework-neutral plug modules, and zero coupled S1-S3 code. If the addendum's
answer differs from 0001's original Phoenix conclusion, sunk cost is not a real
obstacle. If the addendum affirms Phoenix, the "S4 execution work" 0001 always deferred
(adding the dependency, rewriting `router.ex`) is essentially unstarted work, not
abandoned work. This asymmetry — cheap to switch either way — is the one fact genuinely
new since REQ-010 and belongs in the addendum's reasoning if the addendum engages
switching cost at all.

## 4. Dimension B's tie-breaker — what "engage on its merits" requires (AC2)

0001's shipped Reasoning already names the concrete Plug-side answer REQ-065's own text
says must be written down if Plug/Bandit is to stand: its Dimension B paragraph (the
"What does break the tie" paragraph) states the hand-rolled alternative to Phoenix's
`pipeline :api do ... end` is *"(a) repeating all 7 `plug` calls in every sub-router
mounted via `forward/2`, or (b) building a bespoke shared `Plug.Builder` module to hold
the sequence and delegating to it — which is Letflow re-implementing, by hand, the exact
mechanism `pipeline`/`pipe_through` already gives Phoenix for free."*

This is exactly the "Plug.Builder plus Plug.Router.forward/2" mechanism REQ-065's own
description names as "a real answer... but it must be written down as one." **0001
already writes it down — as option (b), then rules it out as "duplicated effort with no
corresponding benefit."** So:

- If the addendum affirms Phoenix: AC2 is satisfied by pointing at 0001's existing
  Dimension B text, which already engages this mechanism on its merits and explains why
  it was found insufficient relative to Phoenix's built-in grouping. No new argument is
  required, only confirmation that nothing since (§3) changes that comparison.
- If the addendum concludes Plug/Bandit should stand instead: AC2 requires the addendum
  to make the *opposite* case from the same starting point — explain concretely why a
  shared `Plug.Builder` module (option (b)) is *not* "duplicated effort with no
  corresponding benefit" after all, e.g. because it is a one-time ~20-30 line module
  (`Letflow.Plugs.ApiPipeline` or similar shape, referenced via `Plug.Builder`'s own
  `plug`-composition macros) that, once written, is reused via `forward/2`-mounted
  sub-routers exactly the way `pipe_through` reuses a Phoenix pipeline — i.e. name why
  the "hand-building a mechanism Phoenix gives for free" framing overstates the actual
  cost. Either way, AC2 is not satisfied by silence or by asserting a different
  dimension outweighs B without engaging B's own argument directly.

This design does not decide which of the two bullets above the addendum should take —
that is the decision itself, ELIXIR-DEV's to make.

## 5. Acceptance-criteria traceability

| REQ-065 acceptance criterion | Concrete design element addressing it |
|---|---|
| AC1 — dated addendum naming exactly one surviving position, Decision/Reasoning sections left intact | §1.1 confirms 0001's existing Decision/Reasoning are present and complete today, nothing to delete; the 0003 (Addendum, dated, in-place) and 0006 (§6, "exactly what this supersedes") precedents in this repo are the two structural shapes ELIXIR-DEV should follow, cited by name in this design's header |
| AC2 — Dimension B's tie-breaker engaged on its merits, not silently reversed | §4 locates 0001's existing Dimension B argument verbatim (the `Plug.Builder`-module option (b) it already names and rules out) and states exactly what engaging it "on its merits" requires under each of the two possible surviving positions |
| AC3 — corrected counts (31 routes, 9 middleware) stated, and whether the recount changes the conclusion | §2.1/§2.2 independently re-verify 31/9 against R-Co's live tree (not trusted from any prior claim); §2.3 flags the in-scope-vs-total middleware nuance (7 of 9) the addendum should not flatten without saying so; §2.4 states plainly that growth is real but does not by itself resolve the direction, matching REQ-065's own framing |
| AC4 — `router.ex` moduledoc and `stage-4-api-surface.md`'s Decisions section agree with the surviving position; grep for `'no Phoenix'` | §1.2 gives the exact current moduledoc line (line 3) that must change only if Phoenix stands; §1.3 shows `stage-4-api-surface.md`'s OQ-0 paragraph already correctly quotes 0001 and flags the contradiction (it is not itself an inversion needing correction, only a possible post-addendum update); §1.5 flags a third `'no Phoenix'`-adjacent location (`backend_developer_guide.md`) outside AC4's named scope |
| AC5 — REVIEWER sign-off appended to `stage-4-api-surface.md`'s "REVIEWER sign-off" section | §1.3 identifies the exact placeholder text (`"(None yet — ...)"`) that entry replaces/extends |
| AC6 — no `mix.exs` dependency change, no `router.ex` behavioural change (only the moduledoc sentence, if Phoenix stands) | §1.2/§1.4 establish the current, unmodified baseline of both files this design itself does not touch; §3.1 quantifies exactly how little of `router.ex` exists to change even if a future S4 requirement later does the real migration |

## 6. What NOT to do (scope boundary this design and REQ-065 both respect)

- This design does not touch `docs/migration/decisions/0001-web-framework.md`,
  `docs/migration/stage-4-api-surface.md`, or `lib/letflow/router.ex` — those are
  ELIXIR-DEV's Step 2a files, per REQ-065's SCOPE BOUNDARY paragraph and this design's
  own brief.
- No `mix.exs` dependency addition is proposed or implied by anything above, regardless
  of which position the addendum eventually names — REQ-065's SCOPE BOUNDARY is explicit
  that adding `{:phoenix, "~>..."}` remains S4 execution work, not this requirement's.
- §2.3's "7 vs. 9" framing and §4's two-bullet split are deliberately left as open
  branches, not resolved — per this design's brief, "you do not pick the winner."

## 7. Open questions / discrepancies to register, not silently resolve

1. **7-vs-9 middleware framing (§2.3).** Whether the addendum states "9, of which 7 are
   in S4's practical mounting scope" or treats all 9 uniformly is a drafting choice for
   ELIXIR-DEV, not resolved here. Either is defensible; silently picking one without
   saying so would understate or overstate Dimension B's premises.
2. **`backend_developer_guide.md:50-51`'s "no Phoenix yet" phrasing (§1.5).** Outside
   AC4's named scope (only `router.ex` and `stage-4-api-surface.md` are named for the
   grep check), not obviously wrong under either outcome since it already defers to
   0001, but worth a follow-up consistency pass or an `docs/issues/ISS-NNNN.yaml` entry
   once the addendum lands, per `core-directives.md`'s "No Issue Left Local-Only."
3. **Which position stands (Phoenix or Plug/Bandit).** Intentionally not decided by this
   design, per REQ-065's `owner: ELIXIR-DEV` and this design's explicit brief.
   CODE-DESIGN-VALIDATOR should not fail this design for leaving it open — the design's
   job is to make sure whichever the addendum picks is reasoned against re-verified,
   current facts (§1-§3) and directly engages 0001's own Dimension B argument (§4), not
   to pre-empt ELIXIR-DEV's documented ownership of the call.
