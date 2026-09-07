# ISS-0437 — `Letflow.Admission` tenant-eviction on deactivation

Closes ISS-0437's confirmed fairness bug (not the issue's original
memory-only framing): `Letflow.Admission`'s `state.tenants` map never
removes an entry once created (REQ-216 design doc §3, OQ-2), so a
`Letflow.Identity.deactivate_tenant/1`'d tenant's entry permanently and
monotonically dilutes every remaining active tenant's fair-share cap
(`per_tenant_cap/1 = max(div(global_cap, map_size(tenants)), 1)`) for the
life of the BEAM node. This document specifies interfaces, `@spec`/`@type`
shapes, and the exact wiring point. It contains no implementation code.

Scope, confirmed against `handoffs/WF03-ISS0437-20260907/step-01-issue-fixer-diagnosis.json`:
implement real eviction (resolution (a)), hooked to the existing
tenant-deactivation lifecycle, not a generic time-windowed sweep. No change
to `try_acquire/2`'s admission-decision algorithm, no route/controller
signature changes, no new config knob.

## 1. `Letflow.Admission.forget_tenant/2` — new client API

Added alongside `try_acquire/2`/`release/2`/`reserved_headroom/1`/`global_cap/1`
in `lib/letflow/admission.ex`, following this module's own existing naming
and default-`server`-argument convention exactly.

`@spec forget_tenant(schema :: String.t(), server :: GenServer.server()) :: :ok`

Function head: `forget_tenant/2`, first argument `schema` (`String.t()`,
guarded `is_binary/1` matching `try_acquire/2`'s own tenant-pool guard),
second argument `server` defaulting to `__MODULE__` (identical default-arg
shape to `try_acquire/2`, `release/2`, `reserved_headroom/1`, `global_cap/1`).

Sends `GenServer.call(server, {:forget_tenant, schema})`, handled by a new
`handle_call({:forget_tenant, schema}, _from, state)` clause added after the
existing `{:release, %Ref{}}` clause (§ordering mirrors the existing
try_acquire/release/reserved_headroom/global_cap grouping).

**Effect on state:** unconditionally removes `schema`'s key from
`state.tenants` (a `Map.delete/2`-shaped removal — no conditional check on
that entry's current `in_use` value; see §2 for why this is the correct,
not merely convenient, choice). Every other field of `state`
(`global_cap`, `global_in_use`, `refs`, `reserved_headroom`) is left
untouched by this call. Always replies `{:reply, :ok, new_state}` — there
is no error return.

**Idempotency:** forgetting a `schema` that is not currently a key in
`state.tenants` (never attempted admission at all, or already forgotten by
a prior `forget_tenant/2` call — e.g. a double-deactivation, matching
`Letflow.Identity.deactivate_tenant/1`'s own documented idempotency) is a
no-op that still returns `:ok`. This mirrors `release/2`'s own documented
idempotent-no-op precedent (moduledoc "release/2": releasing an
already-released or never-acquired ref is `:ok`, never a raise) — the same
"absent-key membership check, not an error condition" shape, applied to
`state.tenants` instead of `state.refs`.

Add a `@doc` above `forget_tenant/2` cross-referencing this design doc and
this module's own moduledoc §"Lazy tenant-entry creation; no eviction
(ISS-0437)" section (see §5 below — that moduledoc section's own text must
be corrected, since it currently asserts "Entries are never evicted within
this requirement's scope" unconditionally, which stops being true once this
lands).

## 2. In-use handling at the moment of eviction — reasoned, not hand-waved

**Decision: `forget_tenant/2` evicts the entry unconditionally, regardless
of its current `in_use` value, and does NOT refuse or defer eviction for
`in_use > 0`.**

Three options were considered:

1. **Refuse eviction while `in_use > 0`** (return an error, or block until
   drained). Rejected: there is no caller-visible retry/poll trigger for
   "try the forget again once this tenant's in-flight requests finish" —
   `Letflow.Routers.Tenants`'s deactivate handler (§3) is a single
   synchronous HTTP request/response; it cannot poll indefinitely, and
   `Letflow.Identity.deactivate_tenant/1` has no knowledge of Admission
   state to decide the DB write itself should also wait. This would need a
   brand-new async reconciliation mechanism — exactly the kind of invented,
   untested mechanism the diagnosis and REQ-216 §3 both warn against
   scope-creeping into.
2. **Force `in_use` to `0` but keep the entry.** Rejected: this reintroduces
   the identical bug ISS-0437 reports, one level down — a
   zero-`in_use`-forever entry for a tenant that will never make another
   admission attempt still permanently counts in `map_size(tenants)`, the
   fair-share divisor. This "fixes" nothing.
3. **Delete the key outright, regardless of `in_use`.** Selected.

**Why (3) is safe, not merely convenient — the race it creates and how it's
closed:** at the instant `forget_tenant/2` runs, some other process may
still be holding a live `Ref{pool: {:tenant, schema}}` from an
already-admitted, not-yet-released request (deactivation and the Admission
gate are two independent mechanisms with no shared lock — `TenantStatus`
blocks *new* requests to a deactivated tenant, but does nothing to requests
already past that plug and mid-flight). When that in-flight request later
calls `Admission.release/2`, the existing `release_tenant/2` private
function (today, `lib/letflow/admission.ex`'s `{:tenant, schema}` clause)
unconditionally applies `Map.update!/3` to decrement that schema's
`in_use` by 1, which **raises `KeyError`** if `schema` is not a key of
`tenants` — a condition that now becomes reachable, post-`forget_tenant/2`,
where it was previously unreachable (every schema referenced by a live ref
was, until now, guaranteed still present). This is a genuine new crash risk
this design must close, not leave for ELIXIR-DEV to discover.

**Required accompanying change to `release_tenant/2` (same file, same
requirement): make it tolerant of an absent key.** Its contract changes
from "the schema is always present when a live ref references it" to "the
schema may have been forgotten since this ref was acquired; if so, this
release is a silent tenant-side no-op, but is still a fully valid release
overall." Concretely: if `schema` is a key in `tenants`, decrement its
`in_use` by 1 exactly as today; if `schema` is NOT a key in `tenants`,
return `tenants` unchanged (no error, no re-creation of the entry). The
caller-facing `handle_call({:release, ...})` clause is otherwise unchanged
— `global_in_use` still decrements normally in both cases, since that
counter is untouched by `forget_tenant/2` and is not what this race
affects. `@spec` for the revised private function:

`@spec release_tenant(tenants :: %{optional(String.t()) => %{in_use: non_neg_integer()}}, pool_selector()) :: %{optional(String.t()) => %{in_use: non_neg_integer()}}`

(signature unchanged from today — only the body's behavior on a missing
key changes, from raise to identity).

This closure is consistent with the moduledoc's own already-documented
invariant ("recomputed caps gate only FUTURE decisions, never retroactively
revoke an already-held admission" — §"Per-tenant cap: computed, not
stored"): a ref already granted before eviction remains fully valid and
freely releasable for its natural lifetime; only the bookkeeping used to
gate that tenant's *future* attempts (which cannot happen post-deactivation
until reactivation, see §4) disappears. No caller of `release/2` needs to
know or care whether the tenant it was admitted under has since been
forgotten.

## 3. Wiring — where the call to `forget_tenant/2` is added

**Decision: `Letflow.Routers.Tenants`'s `handle_deactivate/2`, not
`Letflow.Identity.deactivate_tenant/1` itself.**

The diagnosis flagged this as open ("CODE-DESIGNER needs to decide whether
`Letflow.Identity.deactivate_tenant/1` calls
`Letflow.Admission.forget_tenant/2` directly ... or some other decoupled
notification shape"). This codebase already has load-bearing precedent for
exactly this class of decision, on the *creation* side of the same
`Letflow.Routers.Tenants` handler group: `Letflow.Identity.create_tenant/1`
does **not** call `Letflow.TenantProvisioning.provision_tenant_schema/1` or
`.replay_migrations/2` itself — `Identity.create_tenant/1`'s own `@doc`
states this explicitly ("matching `TenantProvisioning`'s own 'two separate,
composable primitives, neither calls the other' invariant, extended to this
third primitive"), and `Letflow.Routers.Tenants`'s create handler is the one
that sequences `Identity.create_tenant/1` -> `TenantProvisioning.
provision_tenant_schema/1` -> `TenantProvisioning.replay_migrations/2` at
the router layer.

Deactivation's own cross-context orchestration should follow the identical
convention: `Letflow.Identity` stays a single-purpose, DB-effecting context
(no dependency on `Letflow.Admission`'s existence or API), and
`Letflow.Routers.Tenants` — which already orchestrates multi-context
sequencing for this exact handler group — adds the `Admission.forget_tenant/2`
call as a second step after `Identity.deactivate_tenant/1` succeeds. This
avoids introducing Identity's first-ever direct dependency on a non-Repo,
non-Identity-owned GenServer, keeps the two contexts exactly as decoupled
as the create path already established, and requires no new
PubSub/domain-event mechanism (correctly identified by the diagnosis as
absent from `lib/letflow/identity/`).

**Exact edit location**, `lib/letflow/routers/tenants.ex`, `handle_deactivate/2`
(currently lines 352–357):

- Current behavior: the handler matches on `Identity.deactivate_tenant(slug)`'s
  result — on `{:ok, tenant}` it responds 200 with `tenant_map(tenant)`; on
  `{:error, :not_found}` it responds 404. This does not change.
- New behavior: in the success branch (`{:ok, tenant}`), before building the response,
  derive the tenant's Postgres schema name via the SAME primitive
  `Letflow.Plugs.Admission` already uses to resolve a schema for the
  tenant gate — `Letflow.TenantProvisioning.schema_name_for_tenant(tenant.id)`
  — then call `Letflow.Admission.forget_tenant/1` (arity-1 call site; the
  `server` argument is omitted, defaulting to `__MODULE__`, exactly like
  every other production call site of this module's client API — no test
  code calls this router handler against a non-default-named instance).
  `schema_name_for_tenant/1`'s `{:error, :invalid_tenant_id}` branch is not
  reachable here in practice (`tenant.id` is a real UUID just read back from
  `Repo.get_by/2` inside `Identity.deactivate_tenant/1`, not user input) —
  this design does not add a case branch for it and instead relies on
  `schema_name_for_tenant/1`'s existing contract, matching this router's
  own established pattern elsewhere of not defensively re-checking a value
  it just obtained from a trusted internal source.
  `{:error, :not_found}` branch is unchanged.

`handle_reactivate/2` (lines 359–364) is **not modified** — see §4.

**Alias note:** `lib/letflow/routers/tenants.ex` does not currently alias
`Letflow.TenantProvisioning` or `Letflow.Admission` — ELIXIR-DEV adds both
`alias Letflow.TenantProvisioning` and `alias Letflow.Admission` to this
router's existing alias block.

## 4. Reactivation — no Admission-side action needed

**Decision: `reactivate_tenant/1` requires zero corresponding
Admission-side code change**, and `handle_reactivate/2` is left as-is.

Reasoning: after `forget_tenant/2` has run for a schema, that schema is
simply absent from `state.tenants` — indistinguishable, from
`Letflow.Admission`'s point of view, from a schema that has never made an
admission attempt at all. `ensure_tenant_tracked/2`'s existing lazy-creation
behavior (`handle_call({:try_acquire, {:tenant, schema}}, ...)`, called
unconditionally before every admission decision) already creates a fresh
`%{in_use: 0}` entry the moment a reactivated tenant's *next* request
reaches the tenant admission gate — with no special-casing required,
because `ensure_tenant_tracked/2` has no notion of "previously forgotten"
versus "never seen" in the first place; both are just "not a key in
`state.tenants` right now." This is in fact the *correct* behavior, not a
lucky coincidence: a reactivated tenant starting from a clean `in_use: 0`
slate is strictly better than any alternative that tried to restore its
pre-deactivation `in_use` value (which would be stale and potentially
nonzero from before deactivation, per §2's forced-eviction decision).

## 5. REQ-216 design-doc corrections required

Two documents need updating once this design ships (ELIXIR-DEV or
DOC-UPDATER, per whichever role's workflow step lands the corresponding
code change — this design doc does not itself edit them, per
CODE-DESIGNER's own scope, but specifies the exact replacement language so
neither correction is left ambiguous):

**(a) `lib/letflow/admission.ex` moduledoc, section "Lazy tenant-entry
creation; no eviction (ISS-0437)"** (lines 63–84 as currently read) — the
section header and its second paragraph currently assert eviction never
happens at all. Replace the second paragraph (currently starting "Entries
are never evicted within this requirement's scope...") with language
stating: entries are evicted exactly once, on tenant deactivation, via
`Letflow.Routers.Tenants`'s call to `forget_tenant/2` after
`Identity.deactivate_tenant/1` succeeds (§3 of this design doc) — this
closes the correctness/fairness gap ISS-0437 reported, WITHOUT
reintroducing the oscillation risk this same section correctly warns
against for a merely-*idle*-but-still-active tenant: deactivation is a
distinct, deliberate, rare administrative act, not an idle/burst cycle, so
an entry for a tenant that is idle-but-active (no deactivation) is still
never evicted, exactly as before. The section header should drop "no
eviction" (e.g. rename to "Lazy tenant-entry creation; deactivation-triggered
eviction (ISS-0437)").

**(b) `lib/letflow/design/req216-admission-control-core.md` §3 and §9
OQ-2** — §3's "Cleanup — addressed explicitly, not left unbounded"
paragraph and OQ-2 both currently state flatly that no eviction mechanism
exists. Both should be corrected to state precisely which trigger now
evicts an entry: **deactivation-triggered eviction only** (via
`Letflow.Admission.forget_tenant/2`, called from `Letflow.Routers.Tenants`
per ISS-0437's resolution, see
`lib/letflow/design/iss0437-admission-tenant-eviction.md`) — NOT a
time-windowed or LRU mechanism, and NOT eviction of a merely-idle
active tenant (§3's reasons 1–2 for not doing that remain fully valid and
unchanged). OQ-2 should be marked resolved-for-the-deactivation-case, with
a residual, still-open note: an idle-but-never-deactivated tenant's entry
still accumulates forever, bounded only by the platform's own
administratively-controlled tenant cardinality (§3 reason 2, unchanged) —
this narrower residual case remains a distinct, still-open question, not
resolved by ISS-0437.

## 6. Required tests (specification, not code)

Both belong in `test/letflow/admission_test.exs`, following that file's
existing `start_admission/1`-per-test isolation convention (unique `:name`
per test, `async: true`, no `Letflow.DataCase`, no `:sys.get_state` — every
assertion is a black-box `try_acquire`/`release`/`forget_tenant` return
value, matching every existing test in that file).

**Test 1 — `forget_tenant/2` genuinely changes the fairness divisor (not
merely "the key disappears"):** start an isolated instance with a small,
deterministic `global_cap` and two tracked tenants — e.g. `pool_size`/
`reserved_headroom` chosen so `global_cap == 2` (mirroring existing tests'
`pool_size: N + reserved_headroom` idiom). Make one admission attempt each
for tenants `"a"` and `"b"` via `try_acquire({:tenant, "a"}, name)` and
`try_acquire({:tenant, "b"}, name)` (both succeed) — now `map_size(tenants)
== 2`, so `per_tenant_cap = max(div(2, 2), 1) == 1`; assert a *second*
`try_acquire({:tenant, "a"}, name)` returns `{:error, :capacity}` (tenant
`"a"` is already at its cap of 1). Then call `Admission.forget_tenant("b",
name)`. Assert a further `try_acquire({:tenant, "a"}, name)` now returns
`{:ok, _ref}` — this is the load-bearing assertion: it is only possible
because `map_size(tenants)` dropped from 2 to 1 (evicting `"b"`),
recomputing `per_tenant_cap` to `max(div(2, 1), 1) == 2`, which is strictly
greater than tenant `"a"`'s unchanged `in_use == 1`. This proves the
FAIRNESS property (the divisor genuinely shrank and un-gated tenant `"a"`'s
next attempt), not merely that `forget_tenant/2` returned `:ok` or that a
key vanished from an unobservable internal map.

**Test 2 — eviction while a ref is still held does not crash `release/2`
(§2's race):** start an isolated instance, `try_acquire({:tenant, "c"},
name)` to obtain `ref`, then immediately `Admission.forget_tenant("c",
name)` while that ref is still live and unreleased (`in_use` was 1 at the
moment of eviction). Assert `Admission.release(ref, name) == :ok` — no
raise, no `KeyError` — proving `release_tenant/2`'s missing-key tolerance
(§2) is real, not just specified. Follow with a global-budget-boundary
assertion that the release still freed the GLOBAL unit correctly (e.g. if
`global_cap` was exhausted by this and other refs, a subsequent
`try_acquire(:global, name)` now succeeds where it previously would not
have) — this confirms `global_in_use` decremented normally despite the
tenant-side map having no entry to update.

**Test 3 — reactivation resumes tracking with zero additional code
(§4), stated as a regression-guard, not a new mechanism test:** after
`forget_tenant/2` removes tenant `"d"`, a subsequent
`try_acquire({:tenant, "d"}, name)` succeeds exactly as it would for a
schema never seen before (asserting `{:ok, _ref}`, and that it correctly
counts into a freshly recomputed `per_tenant_cap` alongside any other
still-tracked tenant) — demonstrating `ensure_tenant_tracked/2`'s existing
lazy-creation path is sufficient with no `reactivate_tenant/1`-side
Admission call.

No new test file is needed for `Letflow.Identity`/`Letflow.Routers.Tenants`
beyond what REQ-075's existing deactivate/reactivate route tests already
cover for the HTTP contract — TEST-DESIGNER should additionally add ONE
integration-style assertion at the router-test level (wherever
`handle_deactivate/2`'s existing tests live) confirming
`Letflow.Admission.forget_tenant/1` is actually invoked on a successful
deactivation (e.g. via a named, test-isolated `Admission` instance
substituted for the router's own hardcoded `__MODULE__`-default call —
**flagged open question below**, since today's route handler tests have no
established seam for asserting a side effect against a non-default-named
GenServer instance).

## 7. Open question for TEST-DESIGNER / ELIXIR-DEV

`Letflow.Routers.Tenants`'s new call to `Admission.forget_tenant/1` (§3)
uses the same arity-1, default-`__MODULE__` convention as this router's
sibling call sites use for `Identity`/`TenantProvisioning` — there is no
`server` parameter threaded through the router today for any dependency,
so this design does not invent one solely for testability. This means the
router-level integration test in §6's last paragraph must exercise this
against the REAL, application-supervised `Letflow.Admission` process (not
an isolated named instance), which requires either resetting or
tolerating that process's shared state across test cases (existing
`admission_pipeline_test.exs`/`plugs/admission_test.exs` may already have
established a convention for this — ELIXIR-DEV/TEST-DESIGNER should check
those files for precedent before inventing a new one). This is explicitly
left open rather than guessed at, since introducing a `server` parameter to
`Letflow.Routers.Tenants`'s deactivate handler would be a larger,
unrequested API change beyond ISS-0437's scope.

## 8. Scope confirmation

No change to `try_acquire/2`'s admission-decision algorithm (§"Atomicity
algorithm" in the moduledoc is untouched), no change to `per_tenant_cap/1`'s
formula, no new route or controller beyond the one-line addition inside the
already-existing `handle_deactivate/2` handler, no new config surface. The
only new public API is `Letflow.Admission.forget_tenant/2` (§1); the only
changed existing function bodies are `release_tenant/2`'s missing-key
tolerance (§2) and `handle_deactivate/2`'s orchestration (§3).
