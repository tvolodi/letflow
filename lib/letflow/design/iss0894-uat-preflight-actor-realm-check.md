# Design: ISS-0894 — `scripts/uat_preflight.sh` actor exact-name/realm matching + app-side role/definition checks

Status: draft, for CODE-DESIGN-VALIDATOR
Issue: `docs/issues/ISS-0894.yaml`
Related: ISS-0886 (RoleBackfill — merged, PR #2007), ISS-0888 (QA credentials, still
open for promo-proposer/master-admin), ISS-0892 (QA realm/tenant/actor provisioning,
`ai-dala-infra` run T-0150), ISS-0893 ("null key" — swiftroute definition has no
resolvable key), ISS-0897 (meridian/vortex definitions not yet seeded), ISS-0895
(sibling design, same file, same conventions — merged as of `7e7c88a3`)

## Problem restated

Two independent gaps in `scripts/uat_preflight.sh`'s `actors` check (`CHECKS` at
line 298; the per-scenario `actors` branch at lines 339–365):

**(a) Name heuristic vs. exact realm-qualified naming.** The heuristic
(script header lines 35–40, mirrored in `docs/agents/uat-scenario-schema.md`
lines 256–259) assumes `actor-<tenant>-<name>` maps to a seeded Keycloak
username *starting with* `<name>-` (line 353: `u == nm or u.startswith(nm +
"-")`). `ai-dala-infra` run T-0150 (`scripts/qa-uat-env.sh`) now provisions QA
accounts named **exactly** `actor-<realm>-<name>` — the Keycloak username
equals the scenario actor id verbatim inside the tenant's own realm (platform
admin stays the existing special case, `admin-user`). The heuristic still
technically matches these (a username equal to the id also satisfies `u ==
nm`... no — it doesn't: `nm` is only `m.group(2)`, the trailing `<name>`
segment, e.g. `"lena"` for `actor-swiftroute-lena`, not the full id
`"actor-swiftroute-lena"`. The new exact usernames are literally
`actor-swiftroute-lena`, which matches neither `u == nm` (`"lena"`) nor
`u.startswith(nm + "-")` (`"lena-"`). So today's heuristic does **not** match
the new accounts at all — every scenario actor on swiftroute/meridian/vortex
currently resolves to `missing: no seeded user` (`GAP`) even though the
account exists.

**(b) Token validity is not the same as "usable."** The `actors` check today
only proves a password grant succeeds (`try_login`, `token_status[user]`).
Two known-real gaps slip through as if the actor were fully usable:

1. ISS-0886-class: a tenant provisioned before the fix (or before its
   backfill mix task is actually run against QA) has no `tenant_role`/
   `group_members` rows for a role — the actor logs in fine (valid password,
   valid token) but every app route 403s (`roles: []`). `mix
   letflow.backfill_platform_roles` (merged, ISS-0886) is the remediation;
   the QA database itself still needs it run (per that issue's own
   resolution note as of this writing).
2. ISS-0893/ISS-0897-class: a scenario's `process_id` doesn't resolve to a
   deployed, active definition — either because the definition was never
   seeded (meridian/vortex, ISS-0897) or because the seeded definition's key
   is null and doesn't match the scenario's expected key at all
   (swiftroute, ISS-0893).

Both currently surface only at UAT-RUNNER execution time (a scenario FAILs or
gets marked BLOCKED ad hoc) rather than at Step 0 preflight, where WF-05
expects them to be caught and classified.

## What this design does NOT do

- Does not fix ISS-0893 (null key) or ISS-0897 (missing meridian/vortex
  definitions) — it makes preflight **detect and report** those states as
  `GAP` with a reason naming the issue, per this issue's own instruction.
- Does not implement a full definition-key-resolution algorithm — see
  "Decision 3" below for the deliberately minimal check.
- Does not touch UAT-RUNNER, WF-05, or the scenario corpus.
- Does not vendor or invoke `ai-dala-infra`'s `qa-uat-env.sh` from inside this
  repo — see "Decision 4."

## Decision 1 — app-side HTTP checks reuse the existing auth mechanism; no new one

`try_login(user, realms)` (lines 215–231) already does the only HTTP
authentication this script performs: an OIDC Resource Owner Password Credentials
grant against `%s/realms/%s/protocol/openid-connect/token`, caching
`tokens[user] = (realm, access_token)` in memory (never printed/logged/written).
The new app-side checks (Decision 2's `app_roles`, Decision 3's `definitions`)
issue plain `GET`s through the existing `http(method, url, headers, data)`
helper (lines 93–101) using `auth(tok)` (line 258, `{"Authorization": "Bearer
" + tok, "Accept": "application/json"}") — exactly the same pattern
`deployed_sha`/`tenants` already use with `admin_tok`. No new credential path,
no new token cache, no new HTTP client. The only change is *which* token gets
used per scenario (see below), not *how* a token is obtained or used.

**Per-scenario token capture (new).** The `actors` per-scenario loop (lines
339–365) already calls `try_login(users[0], realms_for(users[0], [t]))` for
each login actor and gets back `(state, realm)`. This design adds one new
local accumulator per scenario, `scenario_ok_tokens`, a list of
`(aid, label_hint, access_token)` for every actor whose `try_login` call
returned `state == "OK"` — `access_token` read from the existing `tokens[user]`
cache (`tokens[user][1]`), not re-fetched. `label_hint` is the scenario's own
`actors:` mapping **key** for that `aid` (e.g. `"candidate"`, `"dispatcher"`,
`"ops_manager"` — see `parse_scenario`'s `actors` dict, `d.get("actors")`,
keyed by label -> aid) so the two new checks below can tell a candidate-class
actor from an operator-class one without inventing a role taxonomy. This
requires `parse_scenario`'s returned dict to also retain the label->aid
mapping (today it discards it after computing `actor_ids`) — add a new key
`"actor_labels"` (dict `aid -> [label, ...]`, since a scenario could in
principle map more than one label to the same aid) to the dict `parse_scenario`
returns, populated the same way `actor_ids` already is (from `d.get("actors")`
in the YAML-available path, and from the tolerant-fallback regex path's `acts`
dict — both already parse `label: aid` pairs, just need to also keep the
label, not only the value).

## Decision 2 — exact-name matching: surgical change to the existing heuristic, old heuristic kept as fallback

The fix is one added branch inside the existing per-scenario `actors` loop
(lines 344–354), not a new code path or a rewrite of the matching function:

- `actor-platform-admin` clause (line 347–348): **unchanged**. The special
  case (`admin-user`) is exactly what the issue confirms stays the exception.
- Non-platform-admin clause (lines 349–353): before falling back to the old
  prefix heuristic, try an **exact** match first: `aid in cred_listing` (the
  full scenario actor id — e.g. `"actor-swiftroute-lena"` — appearing
  verbatim in the seeded-username listing `cred_listing`). If found,
  `users = [aid]`. Only if that exact match is absent does the existing regex
  + prefix logic run (`m = re.match(r"actor-([a-z0-9]+)-([a-z0-9]+)$", aid)`,
  `users = [u for u in cred_listing if u == nm or u.startswith(nm + "-")]`,
  unchanged).

**Why keep the old heuristic as a fallback, not replace it:** this script's
own `--credential-source` contract (header lines 15–16) is generic — "a
script that lists seeded usernames" — and is pointed at different listing
scripts depending on which environment/seed convention is in play (local dev
seeds via `scripts/seed_*_actors.sh`-created usernames like
`lena-dispatcher-user`, per ISS-0888's own description of the *pre-T-0150*
QA naming; QA post-T-0150 via whatever adapter fronts `qa-uat-env.sh`, see
Decision 4). A clean replacement would break every environment/scenario that
hasn't been (or will never be) migrated to the exact-name convention — local
dev, in particular, has no stated plan to rename its seeded users to
`actor-<realm>-<name>` verbatim, and this design does not require one. Exact
match first, prefix heuristic as fallback, costs nothing (one `in` check
against an already-loaded list) and is strictly additive: any username that
used to resolve via the prefix heuristic still does; any username that is now
named exactly like the actor id also resolves, on environments where it
wasn't resolving before.

**Text to update alongside the code** (same-issue, not a separate follow-up):
- `scripts/uat_preflight.sh` header comment lines 35–40 ("Actor -> credential
  heuristic") — add the exact-match-first sentence, keep the existing
  prefix-fallback sentence, keep the `actor-platform-admin`/`actor-system-*`/
  `actor-any` lines verbatim.
- `docs/agents/uat-scenario-schema.md` lines 256–259 (the `actors:` bullet in
  its "what preflight checks" paragraph) — same wording update, so the one
  place WF-05/BA authors read the convention doesn't go stale relative to the
  script's actual behavior.

## Decision 3 — "process definitions resolve by key": minimal check, no resolution-logic duplication

**What exists today (confirmed by reading `lib/letflow/routers/definitions.ex`
and `lib/letflow/definitions/process_definition.ex`):** `ProcessDefinition`
has no `key`/`process_key`/`process_id` column at all — only `id` (UUID),
`name` (free-text display name, e.g. `"Shipment Approval"`), `version`,
`status`. `definition_map/1` (the one response allowlist every read route
renders through, lines 1089–1103) never emits a `key`-shaped field. The only
by-string lookup route is `GET /definitions/active/:name`
(`get_active_by_name/2`, REQ-081), which matches on the **display name**, not
any key-like identifier. Scenario files' `process_id` values are two
disjoint shapes:
- `proc-<tenant>-<slug>` (e.g. `proc-swiftroute-shipment-approval`,
  `proc-meridian-loan-origination`) — these name **real, deployable process
  definitions** (grep `process_id: proc-` across
  `test/fixtures/uat/scenarios/{swiftroute,meridian,vortex}/*.yaml`).
- `sys-<slug>` (e.g. `sys-tenant-onboarding`, `sys-definition-promotion`) —
  these are **scenario-classification labels for platform-level mechanisms**,
  not literal API-resolvable definitions (confirmed: no
  `scripts/seed_*_definition.sh` or fixture JSON exists for any `sys-*` id;
  `sys-tenant-onboarding` is explicitly called out by ISS-0897 as an open
  question about whether it should even be a deployable definition at all).
  `n/a` (one platform scenario) is the third, explicitly-not-applicable value.

Given that, the minimal check that reports the real gap without pretending to
resolve it: for a scenario whose `process_id` starts with `proc-`, issue
`GET /api/v1/definitions/active/<process_id>` (using the literal `process_id`
string as the `:name` path segment, URL-encoded via
`urllib.parse.quote(s["process_id"], safe="")`) with the first token in that
scenario's `scenario_ok_tokens` (Decision 1) — the same endpoint and same
by-name shape the app already exposes, no new endpoint, no client-side
key-derivation heuristic invented. Classify:

| HTTP result | check status | reason |
|---|---|---|
| `200` | `OK` | `"GET /definitions/active/<process_id> -> 200"` |
| `404` | `GAP` | `"process definition '<process_id>' does not resolve via GET /definitions/active/:name (see ISS-0893 null-key / ISS-0897 meridian-vortex definitions not yet seeded)"` — owner: `"letflow (ISS-0893 key resolution) / ai-dala-infra (ISS-0897 seed meridian/vortex definitions)"` |
| `403` | `UNKNOWN` | `"actor token lacks DefinitionsRead; cannot check definition resolution"` |
| anything else (`0`/`5xx`/unparsed) | `UNKNOWN` | `"GET /definitions/active/<process_id> -> <status>"` |

- `process_id` is `None`/`"n/a"`/starts with `sys-` (not `proc-`): check status
  `OK`, reason `"no proc-* process_id declared (n/a, or a sys-* platform
  mechanism label, not a deployable definition)"` — this scenario is simply
  out of this check's scope, not silently passed on a technicality.
- No entry in `scenario_ok_tokens` at all (no actor authenticated OK for this
  scenario — covers both "no login actors declared" and "every login actor's
  `actors` check came back `GAP`/`UNKNOWN`"): check status `UNKNOWN`, reason
  `"no authenticated actor token available for this tenant to check
  definition resolution"`.

This deliberately does **not** try multiple tokens looking for one with
`DefinitionsRead`, does not fall back to `GET /definitions?name=` search, and
does not attempt to guess a "real" key by slugifying `name`. Any of those
would be reimplementing definition-key resolution client-side — exactly the
"don't over-engineer" instruction. A single, direct, real API call against
the one endpoint that exists, reported precisely, is the whole check.

## Decision 4 — no, this does not need to invoke `ai-dala-infra`'s script from inside this repo

`--credential-source PATH` (header lines 15–16) is already, and stays, a
generic contract: *some script, at a path the caller supplies*, that (a) with
no arguments lists seeded usernames (`run_cred([], 30)`, parsed by the
`^\s{2}([a-z0-9][\w-]*)\s` regex at line 196) and (b) with one username
argument prints a line `Password: <pw>` (`fetch_password`, lines 203–210).
This script never hard-codes a path to `ai-dala-infra` anywhere, and this
design does not add one. `docs/agents/workflows/WF-05_uat_run.md` (Step 0
item 3) already states the boundary: "ai-dala-infra... own orchestrator
workflow + approval gate. Letflow never changes QA infrastructure directly" —
and separately documents `ai-dala-infra` as a sibling checkout at a
machine-local path (`c:\Users\tvolo\dev\ai-dala\ai-dala-infra`), not a path
inside this repository or a dependency this repo's own scripts resolve.

The `qa-uat-env.sh`/`KC_SEED_<REALM>__<USER>_PASSWORD`/
`UAT_QA_ACTOR_<SLUG>_<NAME>_PASSWORD` mechanism the issue describes is an
`eval`-based, env-var-producing interface — a different shape than this
script's "list usernames / print `Password: <pw>` for one username" contract.
Reconciling those two shapes is **not** solved here: whoever runs Step 0 in
practice (`ORCH`, per WF-05 Step 0 item 2, invoking `scripts/uat_preflight.sh
--credential-source <path>`) is responsible for supplying a
`--credential-source` script that implements this repo's existing protocol on
top of whatever `ai-dala-infra` exposes — exactly the same boundary that
already existed before this issue, for the pre-T-0150 `ai-dala-infra/scripts/
qa-login.sh` this script's own header already names as the reference
implementation. This design changes nothing about that boundary; it only
changes the actor-*matching* logic (Decision 2) so that once a
`--credential-source` script produces exact-name-style usernames, preflight
recognizes them.

## Concrete change list

1. `scripts/uat_preflight.sh`
   - Header comment (lines 35–40): document exact-match-first / prefix-fallback.
   - `parse_scenario` (lines 113–149): add `"actor_labels"` to the returned
     dict (label -> aid or aid -> [labels], pick one direction — see Open
     Question 3) in both the YAML-available and tolerant-fallback code paths.
   - `CHECKS` (line 298): becomes
     `["spec", "local_deps", "feature", "tenant", "realm", "actors",
     "app_roles", "definitions", "env_limitation"]` — `app_roles` and
     `definitions` inserted between `actors` and the ISS-0895-added
     `env_limitation` (which stays last, per its own "additive, independent
     of ... above" comment, unaffected by this change).
   - Per-scenario `actors` branch (lines 339–365): add the exact-name-first
     match (Decision 2); accumulate `scenario_ok_tokens` (Decision 1)
     alongside the existing `missing`/`unknown`/`bad` accumulation — no
     change to `actors`' own existing status/reason logic.
   - New per-scenario `app_roles` branch (after `actors`, before
     `env_limitation`): for each `(aid, labels, tok)` in
     `scenario_ok_tokens`, call `GET /api/v1/tasks/inbox` (candidate-labeled actors:
     `GET /api/v1/me/modules` instead — see "app_roles endpoint choice" below) with
     `auth(tok)`; classify per actor (`200`->ok, `403`->role-not-bound gap,
     anything else->unknown); aggregate to one status/reason for the
     scenario, worst-wins (`GAP` > `UNKNOWN` > `OK`), reason joins each
     actor's own outcome (`"aid(status@endpoint)"`-shaped, mirroring how the
     existing `actors` check joins its own `bad` list at line 356:
     `"%s(%s)" % (aid, state)`).
   - New per-scenario `definitions` branch (Decision 3).
   - `== MANIFEST ==` section (lines 384–398): no change required — it
     already lists `process definitions` and `actors (login)` at the
     manifest level; the new checks are per-scenario detail only, same as
     `env_limitation` added no new manifest line either.
2. `docs/agents/uat-scenario-schema.md` lines 256–261: update the `actors:`
   bullet (Decision 2 wording) and add one clause to the same paragraph for
   `process_id`, e.g. "; a `proc-*` process_id is additionally checked
   against `GET /definitions/active/:name` — see ISS-0894."

### `app_roles` endpoint choice per actor label

`GET /api/v1/tasks/inbox` requires `:TasksRead` (`required_permission(:TasksList)`,
`authorization.ex` line 983), granted to `TASK_WORKER`/`PROCESS_OPERATOR`/
`PROCESS_DESIGNER`/`PLATFORM_ADMIN` but **not** `CANDIDATE` (`core_role_allows?
(:CANDIDATE, _permission), do: false` — a 403 there is CANDIDATE's
correct, by-design shape, not an ISS-0886-class bug). `GET /api/v1/me/modules`
(`:MyModulesRead`) is granted unconditionally to every role
(`role_allows?(_role, :MyModulesRead), do: true` — the very first clause,
deliberately ordered first per its own comment). So: if any of a scenario's
`actor_labels` for a given `aid` case-insensitively contains `"candidate"`,
use `GET /api/v1/me/modules` for that actor's `app_roles` sub-check; otherwise use
`GET /api/v1/tasks/inbox`. This is a label-text heuristic, not a role lookup (this
script has no way to ask Keycloak/letflow "what role does this actor hold"
without reimplementing `Letflow.Identity.list_effective_role_names/2`
client-side) — flagged explicitly as Open Question 1 below, not silently
assumed correct for every future actor class this heuristic hasn't seen yet.

## Report/JSON output conventions (unchanged from ISS-0895)

- Status vocabulary stays `OK`/`GAP`/`UNKNOWN` — `app_roles` and
  `definitions` are ordinary entries in `c[k]`, `(status, reason, owner)`
  3-tuples, rendered by the same existing loop (lines 407–408 gap table,
  418–424 detail, `counts`/`ready` aggregation at 411–431) with zero changes
  to that rendering code — exactly the "additive check columns" precedent
  `env_limitation` already established.
- `a.out` JSON summary (lines 435–440): `CHECKS` already drives
  `"scenarios": {s["id"]: {k: {...} for k in CHECKS} ...}` — the two new keys
  appear automatically once added to `CHECKS`, no separate JSON-shape change.
- Owner strings follow the existing convention of naming a remediation class
  (`"ai-dala-infra (...)"`, `"letflow-seed (...)"`, `"letflow (...)"`,
  `"feature-gap (...)"`, `"environment-structural (...)"`) plus, where
  relevant, the specific issue id in parentheses — matching `env_limitation`'s
  `"(issue_ref=%s)"` precedent.

## Invariants

- **INV-1**: `app_roles`/`definitions` never perform a write (`GET` only) —
  same read-only invariant the script's own header (line 27) already states
  for every other check.
- **INV-2**: no new credential/token cache; both new checks only ever read
  from `tokens`/`scenario_ok_tokens`, populated exclusively via the existing
  `try_login` path — no new place a password or token could leak into a log,
  file, or argv.
- **INV-3**: `actor-platform-admin`'s dedicated clause is untouched; this
  design's exact-name-first branch applies only to the non-platform-admin
  case, so it cannot change how the platform admin actor resolves.
- **INV-4**: the old prefix heuristic remains reachable code, not dead code —
  any environment/scenario whose `--credential-source` still lists
  non-exact usernames continues to resolve exactly as before this change.
- **INV-5**: `definitions`' `GAP` reason always names at least one concrete
  issue id (ISS-0893 and/or ISS-0897) — never a bare "not found" with no
  pointer to the known root cause class, so a preflight reader isn't left to
  rediscover context this design already has.

## Open questions (explicit, not silently resolved)

1. **`app_roles` candidate-vs-operator endpoint choice is a label-text
   heuristic, not a role lookup.** If a future actor label doesn't contain
   "candidate" but the actor's actual bound role still lacks `:TasksRead`
   (e.g. a hypothetical new low-privilege role), this check would
   misclassify a legitimate least-privilege 403 as a `GAP`. Should
   `app_roles` instead read the scenario's own (currently nonexistent) role
   annotation per actor, if/when `docs/agents/uat-scenario-schema.md` grows
   one? Out of this design's scope to add that schema field pre-emptively.
2. **`ai-dala-infra` sibling availability is a real, unresolved environmental
   dependency.** ISS-0886's own resolution note records, from this same kind
   of sandbox: "no `ai-dala-infra` sibling checkout is present in this
   workspace." If the agent/CI environment that runs `scripts/
   uat_preflight.sh --credential-source <path>` in practice has no such
   sibling checkout and no adapter script bridging `qa-uat-env.sh` to this
   script's existing protocol, Decision 4's "not this repo's problem"
   framing is correct in principle but leaves Step 0 unable to actually
   authenticate any QA actor at all, in exactly the same way it already
   can't today. This design does not create or require a specific adapter
   script name/location — should one exist as a tracked deliverable (in
   `ai-dala-infra`, filed as a request per WF-05 Step 0 item 3's own
   "ai-dala-infra: file a request to / dispatch a run" convention), or is it
   acceptable to keep leaving this as a standing manual step? Flagging for
   CODE-DESIGN-VALIDATOR/ORCH rather than deciding unilaterally, since it's
   a cross-repo coordination question, not a Letflow code question.
3. **`actor_labels` direction/shape.** The design above proposes `aid ->
   [label, ...]` (a scenario could map more than one label to the same
   actor id, though no current fixture does). An implementer could instead
   choose `label -> aid` (matching the YAML's own natural shape, `d.get
   ("actors")`) and derive the reverse lookup only where `app_roles` needs
   it. Either is fine; not fixing this choice here since it's an internal
   data-shape detail with no externally-observable difference — but noting
   it so ELIXIR-DEV... (n/a, this is a bash+Python script, so whichever
   agent implements it) doesn't have to guess which the design "meant."
4. **Should `definitions`' `403` case (actor token lacks `DefinitionsRead`)
   try a second, more-privileged token before giving up as `UNKNOWN`?** This
   design deliberately picks the *first* `scenario_ok_tokens` entry only
   (Decision 3), which could be a `CANDIDATE`/`TASK_WORKER` actor without
   `DefinitionsRead` even when a `PROCESS_OPERATOR`/`PROCESS_DESIGNER`
   co-actor on the same scenario would succeed. Retrying every available
   token before falling back to `UNKNOWN` would reduce false `UNKNOWN`s at
   the cost of more HTTP calls and slightly more complex logic — left as
   `UNKNOWN` (not `GAP`, so it fails safe) rather than resolved either way
   here.
