# REQ-130 — Authorization generalization design

Status: design only, no implementation code. Implements REQ-130. Consumed by
REQ-131 (mechanism build-out) and, for row-filter application, REQ-132.

**Note for whoever executes REQ-131**: REQ-131's own filed entry in
`docs/requirements.yaml` was written 2026-08-22 against the same superseded
premise this design corrects in §1 below — it still describes the nine
sub-routers as empty stubs and scopes migration to "identity.ex's 11 existing
call sites" only. That text is stale. The real migration scope, per §2.4
below, is all seven already-wired routers (identity 16, audit 1,
definitions 13, instances 7, onboarding 3, tenants 6, tasks 7 call sites),
not identity.ex alone. `docs/requirements.yaml`'s REQ-131 entry should be
corrected to match before REQ-131 is executed, so an ELIXIR-DEV turn reading
only the yaml doesn't under-scope the work.

## 1. Current state (verified against `lib/letflow/routers/*.ex` on this branch,
   2026-08-23 — supersedes REQ-130's own filed premise, which was accurate as
   of 2026-08-22 but has since been overtaken by REQ-073/074/076/079-082's
   shipped work)

REQ-130's original text asserted the nine named sub-routers had zero
references to `Letflow.Api.Authorization`. That premise no longer holds. The
actual state, by grep over `lib/letflow/routers/`:

| Router | Authorization calls | State |
|---|---|---|
| `identity.ex` | wired via `with_authorized_scope/4` (REQ-073, REQ-074) | 16 routes, all gated |
| `audit.ex` | wired via `with_authorization/4` (REQ-082) | gated, moduledoc marks it temporary |
| `definitions.ex` | wired via `with_authorized_scope/4` (REQ-081) | gated, moduledoc marks it temporary |
| `instances.ex` | wired via `with_authorized_scope/4` (REQ-079/080) for most routes | gated for routes with a policy key; **two routes — `POST /instances/:id/rebind-pins` and reconstruct — call no authorization function at all**, by explicit design (no `endpoint_policy_key/2` clause exists, no R-Co precedent either); moduledoc names this an open "authorization gap" for REQ-131 |
| `onboarding.ex` | wired via `with_authorization/4` | gated |
| `tenants.ex` | wired via `with_authorization/4` | gated |
| `tasks.ex` | wired via `with_authorized_scope/4`, including the shipped `AllowWithRowFilter` consumer | gated |
| `solution_packs.ex` | **zero** calls — moduledoc explicitly documents this as an open "authorization gap" for REQ-131 | routes exist (`POST /solution-packs/export`, `POST /solution-packs/install`), reachable by any authenticated tenant caller regardless of role |
| `metrics.ex` | deliberately calls no authorization function | not a gap — `endpoint_policy_key/2` maps `GET /metrics` and `evaluate_access/2` special-cases `:MetricsRead` to unconditional `Allow` before the permission check even runs (`lib/letflow/api/authorization.ex:350-351`); a call would be a no-op. Out of scope for a mechanism change — nothing to wire. |
| `promotion.ex` | n/a | genuine stub, 12 lines, zero routes (`match _ -> not_found`); routes land with REQ-077, not yet shipped |
| `tenant_config.ex`, `mobile_tenant_config.ex` | n/a, and will **never** call `Authorization` | deliberately unauthenticated, mounted on `Letflow.Router` directly, **outside** `Letflow.Plugs.ApiPipeline` / `AuthPipeline` — public login-bootstrap config served before any token exists. `tenant_config.ex`'s own moduledoc documents this at length. Out of scope for this design entirely. |
| `validation.ex` | — | does not exist in `lib/letflow/routers/` today. REQ-130's original text named it; it is a discrepancy against the filed requirement, not a file to design for. Noted, not invented. |

So the actual open scope for this design is: (a) name the one mechanism that
governs every future call site, including `promotion.ex`'s upcoming routes
and the two already-shipped gaps in `instances.ex` and `solution_packs.ex`,
and (b) decide what happens to the seven routers that already independently
implemented a route-local call.

## 2. The central decision: replace the incumbent per-call-site convention
   with a mandatory authorization plug. Do not extend it as-is.

### 2.1 What the incumbent convention actually is, confirmed from source

`identity.ex:247-273` (`with_authorized_scope/4`) is the original. Reading it
alongside `audit.ex:159-181` (`with_authorization/4`), `definitions.ex:1034-`
(`with_authorized_scope/4`), and `tasks.ex:171-193` (`with_authorized_scope/4`)
confirms the shape is structurally identical everywhere — resolve scoped
prefix, build an `AccessContext` from `conn.assigns.auth_context`, call
`Authorization.evaluate_access/2` with `Authorization.endpoint_policy_key/2`
applied to a **literal string constant** `method`/`path_template` pair, deny
on `:Deny403`, otherwise invoke the handler — but it is **not one convention
reused**. It is five to seven structurally-identical but textually
independent private-function copies (`identity.ex`, `audit.ex`,
`definitions.ex`, `instances.ex`, `onboarding.ex`, `tenants.ex`, `tasks.ex`),
each hand-written per router. This is itself a naming/consistency-drift
finding: two names are in circulation (`with_authorized_scope/4` in four
routers, `with_authorization/4` in three), and the arities and closure shapes
differ slightly (`tasks.ex`'s and `instances.ex`'s `fun` takes
`(conn, opts, decision)`; `identity.ex`'s and `definitions.ex`'s take
`(conn, opts)`/`(conn, opts, actor_id)`; `audit.ex`'s, `onboarding.ex`'s and
`tenants.ex`'s take `(conn)` only, since those routers make no `Repo` call
needing `opts`). Not a defect to fix in this design — REQ-131 replaces all of
them — but a fact this design must not mischaracterize as "one proven
convention."

The safety property this design does ratify unconditionally is the **literal
string constant**, not the copy-per-router structure around it:
`method`/`path_template` must never be derived from `conn.request_path` or
any other request-observed value, because `Plug.Router.forward/2` rewrites
`conn.path_info` and a handler resolved after that rewrite has no reliable
view of the original route template. Every existing call site already
honours this (confirmed above); the plug design in §2.3 preserves it.

### 2.2 Why the incumbent convention does not scale, per the code's own
   evidence — not a hypothetical concern

This is not a stylistic judgment. The already-shipped routers demonstrate,
independently and repeatedly, both halves of the argument:

**(a) The routers' own authors, independently, already concluded a plug is
coming, and said so in five separate moduledocs, written across REQ-079
through REQ-082 by (presumably) different ELIXIR-DEV turns, each already
passed through SECURITY-REVIEWER and REVIEWER:**

- `tasks.ex:23-31` — "Authorization — direct `Authorization.evaluate_access/2`
  call, temporary pending REQ-131 ... REQ-131 (making `Letflow.Api.Authorization`
  a mandatory router-wide plug) is [scoped for later] ... This is temporary:
  once REQ-131 lands, this direct call is expected to be replaced."
- `audit.ex:81-95` — "This is temporary. REQ-131 builds the authorization plug
  that supersedes all three copies at once; when it lands, this helper is
  deleted, not adapted. Do not extract it into a shared module in the
  meantime — a shared always-called gate *is* REQ-131's plug under another
  name, and building it here would pre-empt REQ-130's design."
- `definitions.ex:46` — "temporary direct duplication, pending REQ-131's
  consolidation."
- `instances.ex:119-128`, `solution_packs.ex:95-107` — both title a section
  "Authorization gap — REQ-131 closes it" and state explicitly that inventing
  a route-local permission check for their ungated routes was "explicitly
  ruled out" pending "a REQ-130/REQ-131-class policy decision."

Five independent shipped modules already converged on "a mandatory plug is
coming" as their working assumption, and at least two (`audit.ex`,
`definitions.ex`) explicitly declined to even deduplicate their own copies
into a shared helper *because* doing so would itself be "REQ-131's plug under
another name" and would pre-empt this design. Treating this design's job as
open would ignore evidence the codebase already contains.

**(b) The incumbent convention has already produced the exact failure mode
REQ-130 exists to prevent, in shipped code, today:**

`solution_packs.ex`'s two routes (`POST /solution-packs/export`,
`POST /solution-packs/install`) call no authorization function at all — not
even the `:Unknown` fail-closed-except-admin path, because nothing calls
`evaluate_access/2` in the first place. `instances.ex`'s rebind-pins and
reconstruct routes are the same: authenticated and tenant-scoped (via
`Context.scoped_repo_opts/1`), but reachable by **any** authenticated tenant
caller regardless of role, because no `with_authorized_scope/4` call wraps
them. This is worse than the `:Unknown` semantics described in §3 below — it
is not "unguarded for PLATFORM_ADMIN, denied for everyone else," it is
unguarded for everyone. A per-call-site convention that requires each route
author to remember to add the wrapping call has already, twice, shipped a
route where nobody did. Both instances are individually judged non-defects by
their own authors (no policy key exists yet to enforce), but they prove the
convention's actual failure mode is not hypothetical: a missing call site is
silent and ships clean through review, because review has no artefact to
check it against beyond a human re-reading every route by eye.

### 2.3 The decision

**Replace the incumbent per-call-site convention with a mandatory
authorization plug**, built by REQ-131, inserted into the same pipeline
`Letflow.Plugs.ApiPipeline` already runs, positioned strictly after
`Letflow.Plugs.AuthPipeline` (so `conn.assigns.auth_context` is already
populated — `roles`, `user_id`) and strictly after the scoped-prefix
resolution step each router's preamble currently performs locally (so
`Context.scoped_repo_opts/1`'s tenant-validity check has already run and
`{:error, ...}` has already short-circuited to `Response.internal_error/1`
before authorization is evaluated — matching every existing router's
ordering). The plug recovers `method`/`path_template` the same way every
existing helper does today: **not** from `conn.request_path` (see §2.1's
safety property, unconditionally preserved), but as a literal-string lookup
keyed by a route-declared attribute the plug reads at each route's own
declaration site — concretely, each `Plug.Router` route macro call (`get`,
`post`, `patch`, `delete`) is annotated with a policy key expressed as a
route option or a module attribute registered immediately above the route,
so the plug consults **route metadata resolved before `forward/2`'s prefix
rewrite**, not `conn.path_info` after it. This is the same literal-constant
discipline the incumbent convention already has — the plug changes *where*
the literal lives (declared once at the route, read by shared plug logic)
and *who* enforces it runs (`ApiPipeline`, unconditionally, for every route
under it), not the safety property itself.

REQ-131 is responsible for the concrete route-metadata recovery mechanism
choice among the options REQ-130's filed text names (a route table consulted
before forwarding, `Plug.Router` private route metadata, per-sub-router
scoped keys) — this design fixes the constraint (mandatory, plug-shaped, ordered
after auth+prefix resolution, literal-constant-keyed, never
`conn.request_path`-derived) and leaves the specific Elixir mechanism for
recovering the template to REQ-131's own implementation judgment, since that
is an implementation choice, not a policy decision, and building it now would
itself be implementation code (forbidden here, AC8).

### 2.4 Migration: in scope, owned here, not left implicit

Because this design replaces the incumbent convention rather than ratifying
it, REQ-131's scope explicitly **includes** migrating every already-shipped
call site onto the plug, and deleting the per-router private helpers:

- `identity.ex:247-273` (`with_authorized_scope/4`, 16 call sites)
- `audit.ex:159-181` (`with_authorization/4`, 1 call site)
- `definitions.ex:1034-` (`with_authorized_scope/4`, 13 call sites)
- `instances.ex:743-` (`with_authorized_scope/4`, 7 call sites) — plus closing
  the two currently-ungated routes once REQ-131 decides their policy key, a
  decision this design does not make (no policy exists to port; see
  `instances.ex:119-128`)
- `onboarding.ex:148-` (`with_authorization/4`, 3 call sites)
- `tenants.ex:181-` (`with_authorization/4`, 6 call sites)
- `tasks.ex:171-193` (`with_authorized_scope/4`, 7 call sites, including the
  `AllowWithRowFilter` producer — see §5)
- `solution_packs.ex` — currently zero call sites; REQ-131 adds its policy
  keys and closes the gap the moduledoc already names

Each router's own moduledoc (`audit.ex`, `definitions.ex`, `instances.ex`,
`solution_packs.ex`, `tasks.ex`) already states its local helper is deleted,
not adapted, once the plug lands — this design confirms that is correct and
gives REQ-131 the full list above so no call site is missed. After
migration, exactly one authorization mechanism remains reachable from
`lib/letflow/routers/`: the plug. No router retains a local
`with_authorized_scope/4` / `with_authorization/4` definition.

`promotion.ex`'s future routes (REQ-077) are not a migration case — they do
not exist yet — but must be built directly against the plug from the start,
never against a new route-local helper. The convention promotion.ex's
implementation must follow: declare each route's policy key as route
metadata per §2.3 and let the mandatory plug enforce it; no per-route
`with_authorized_scope`/`with_authorization`-shaped wrapper is to be
reintroduced anywhere, including in `promotion.ex`.

## 3. No-matching-policy-key semantics: fail-closed-EXCEPT-PLATFORM_ADMIN

`endpoint_policy_key/2` is a function-head-per-route dispatch whose final,
catch-all clause returns `:Unknown` (`lib/letflow/api/authorization.ex:334`,
`def endpoint_policy_key(_method, _path), do: :Unknown`).
`evaluate_access/2` branches on this **first**, before any permission check
(`lib/letflow/api/authorization.ex:343-348`):

```
endpoint == :Unknown ->
  if has_role?(ctx.roles, :PLATFORM_ADMIN) do
    %AccessDecision{kind: :Allow, task_scope: nil}
  else
    %AccessDecision{kind: :Deny403, task_scope: nil}
  end
```

This is deliberate — a direct port of R-Co's `evaluateAccess`, and REQ-131's
own filed text (`docs/requirements.yaml`) already instructs "do not modify
`Letflow.Api.Authorization`." This design does not change it and treats it
as a fixed constraint the plug must be built around.

The guarantee is **fail-closed-EXCEPT-PLATFORM_ADMIN, not fail-closed**.
Stated as a consequence for the plug and every future route author: a route
that reaches the plug without a recognized policy key is **allowed** for any
caller holding `PLATFORM_ADMIN`, and **denied** for every other role. It is
not silently open to all callers (contrast this with the two shipped gaps in
§2.2(b), which are worse — those routes bypass `evaluate_access/2` entirely
and are open to every authenticated tenant caller regardless of role,
because no plug currently runs at all). Once the mandatory plug lands, the
`:Unknown` branch becomes the actual behavior for a missing policy key, which
is why §4's enforcement artefact matters: the failure mode after REQ-131
lands is "quietly reachable by admins," not "wide open to everyone," but it
is still a failure mode a route author must not be able to introduce
unnoticed.

## 4. Mechanism naming a route added without a policy key, so it is visible
   rather than silently accepted

**A dedicated ExUnit test, run as part of the normal suite, that walks every
route macro invocation (`get`/`post`/`patch`/`delete`) across every module
under `lib/letflow/routers/` and asserts each one resolves to a
non-`:Unknown` `endpoint_policy_key/2` clause** (mirroring the existing
route table each router's own moduledoc already documents, e.g.
`identity.ex`'s route list at its own moduledoc top, `definitions.ex`'s
handler table) — with a single, explicit, named allowlist for the routes
this design or a future one has deliberately decided stay unguarded (today:
`GET /metrics`, which resolves to a real, present clause and is excluded from
"missing," not from "present," so it does not need the allowlist; the
allowlist is for a route intentionally left at `:Unknown`, which as of this
design is not expected to exist — the two currently-ungated `instances.ex`
routes are exactly the case this test is meant to catch and turn into an
explicit decision, either "add a policy key" or "add to the allowlist with a
stated reason," rather than leaving them silently reachable). This test must
fail loudly (not skip, not warn) when a new route macro call is added to any
router file without a matching `endpoint_policy_key/2` clause and without an
allowlist entry naming it. REQ-131 builds this test as its stated
enforcement artefact; this design specifies its shape and where it must live
(a test module under `test/`, walking router modules by
introspecting their compiled route dispatch, not by re-parsing source), not
its code.

`tenant_config.ex` and `mobile_tenant_config.ex` are excluded from this
walk entirely, not allowlisted within it — they are mounted outside
`Letflow.Plugs.ApiPipeline` and never reach the plug, by design (§1).

## 5. INV-5 ordering: cross-tenant resolves to 404 before evaluate_access/2
   is ever called with that resource in scope

`Letflow.Api.Authorization`'s own moduledoc states this explicitly
(`lib/letflow/api/authorization.ex:21-38`, "SECURITY (INV-2, INV-5)"):

> **INV-5** — this module answers only "is this action allowed," never "does
> this resource exist." A cross-tenant resource lookup must be resolved to
> 404 by REQ-072's request-context/scoping layer BEFORE `evaluate_access/2`
> is ever called with that resource in scope — routing a cross-tenant lookup
> through this module and returning its `Deny403` to the caller would let a
> prober distinguish "exists, not yours" from "never existed," which is
> exactly what INV-5 forbids.

This design states the ordering explicitly for the plug and for every future
route: **tenant-scope resolution (REQ-072's mechanism — the caller's own
tenant schema via `Context.scoped_repo_opts/1`, and any per-resource
cross-tenant lookup a specific route performs) must complete, and any
cross-tenant 404 must already have been returned, before the plug's
authorization decision is evaluated with that resource identified in scope.**
The plug governs "is this class of action, at this route, allowed for this
caller's role" — a decision that needs no resource identity at all, only
`AccessContext` (`user_id`, `roles`) and the policy key, matching
`evaluate_access/2`'s actual signature (`AccessContext.t()`,
`endpoint_policy_key()` — no resource parameter exists to pass one through,
structurally enforcing INV-2/INV-5 together, per the same moduledoc section).
A route needing a resource-specific cross-tenant check (e.g. "does task `:id`
belong to my tenant") performs that check in its own handler, after the
plug's role-level `Allow`/`AllowWithRowFilter`, exactly as `instances.ex`'s
own "INV-5 — cross-tenant is 404, and it is the same 404" section already
documents for `rebind_pins/3`. This design does not change that per-handler
responsibility; the plug only replaces the role-level gate that currently
precedes it.

## 6. How `AllowWithRowFilter` is surfaced to a route handler (general shape,
   no specific future route)

The one shipped precedent is `tasks.ex`. `evaluate_access/2`'s
`AllowWithRowFilter` branch (`lib/letflow/api/authorization.ex:358-364`) is
reached only when the endpoint is `:TasksList` and the caller is task-worker
only (`is_task_worker_only?/1`); it returns
`%AccessDecision{kind: :AllowWithRowFilter, task_scope: {:own_user_and_groups, user_id}}`.
`tasks.ex`'s own `with_authorized_scope/4` (`tasks.ex:171-193`) does not
special-case this kind — its `case decision.kind do` clause groups
`:Allow` and `:AllowWithRowFilter` together (`_allow_or_allow_with_row_filter
->`) as "proceed," and passes the **whole `decision` struct**, not just its
`kind`, into the wrapped handler function (`fun.(conn, opts, decision)`).
The handler (`handle_list/3`) then pattern-matches on `decision.task_scope`
itself (`build_list_assignee_scope/3`) to decide whether to force the row
scope to `{:own_user_and_groups, user_id}` or leave it unconstrained,
documented inline as "a task-worker-only caller's scope is always forced to
their own principal scope, regardless of any assignee_id the caller
supplied (INV-2 — `AllowWithRowFilter`'s row scope can never be widened by a
request-supplied filter)."

The general shape this design commits future handlers to, without
prescribing any one route's implementation (REQ-132's job): **the
authorization mechanism (plug, per §2.3) must make the full
`AccessDecision` — not merely a boolean or the `:kind` atom — available to
the route handler on `Allow` and `AllowWithRowFilter` alike**, so a handler
that needs the row-scope constraint can read `decision.task_scope` and apply
it to its own query, while a handler that has no row-scoped concept of the
resource it serves can ignore `task_scope` entirely and treat both kinds as
unconditional proceed (matching every other already-wired router's handling,
since `:TasksList` is currently the only `endpoint_policy_key/2` value that
can ever produce `AllowWithRowFilter`). The mechanism must not collapse
`AllowWithRowFilter` into a plain "allowed" boolean anywhere between
`evaluate_access/2` and the handler, since that would silently discard the
row-scope constraint and let a task-worker-only caller see other users' rows
— this is the structural guarantee `tasks.ex` already relies on and this
design preserves it as a requirement on the plug's return value/assign
shape, not a specific data structure (REQ-131 decides whether this is a
`Plug.Conn` assign, a value passed to the handler, or another shape — this
design only requires that the full decision, not a collapsed boolean,
reaches the handler).

## 7. Open questions

None. Every acceptance criterion above is answered with a concrete decision;
none is left as a list of options for a later stage to resolve.
