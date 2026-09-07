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
not merely convenient, choice), **and** advances `schema`'s entry in the
new `state.tenant_generations` bookkeeping map by one (see §2.1 — this is
the mechanism that makes §2's release-hardening and §4's reactivation
compose safely instead of corrupting `in_use` under a deactivate ->
reactivate -> stale-release interleaving). `global_cap`, `global_in_use`,
and `reserved_headroom` are left untouched by this call, exactly as
before. Always replies `{:reply, :ok, new_state}` — there is no error
return.

**Idempotency:** forgetting a `schema` that is not currently a key in
`state.tenants` (never attempted admission at all, or already forgotten by
a prior `forget_tenant/2` call — e.g. a double-deactivation, matching
`Letflow.Identity.deactivate_tenant/1`'s own documented idempotency) leaves
`state.tenants` unchanged (`Map.delete/2` on an absent key is already a
no-op) and still returns `:ok`. This mirrors `release/2`'s own documented
idempotent-no-op precedent (moduledoc "release/2": releasing an
already-released or never-acquired ref is `:ok`, never a raise) — the same
"absent-key membership check, not an error condition" shape, applied to
`state.tenants` instead of `state.refs`.

**The one part of `forget_tenant/2` that is NOT conditioned on
`state.tenants`'s current membership:** the `state.tenant_generations`
advance (§2.1) always happens, on every call, whether or not `schema` was
a key of `state.tenants` at the time. A double-deactivation therefore
advances the counter twice in a row with no observable effect (nothing yet
holds a ref stamped with the intermediate value), which is harmless — see
§2.1's own worked double-deactivation trace.

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
overall." **This alone is NOT sufficient** — see §2.1 immediately below,
which composes this with §4's reactivation and finds a corrupting
interleaving that a bare key-presence check cannot detect. §2.1's
generation mechanism is a required part of this same change, not an
optional hardening on top of it.

### 2.1 Composing eviction with reactivation: why key-presence alone fails, and the fix

**The gap (found by CODE-DESIGN-VALIDATOR, not by this design originally):**
a key-presence check on `tenants` can only distinguish "this schema has
some entry right now" from "this schema has no entry right now." It
cannot distinguish *which* admission episode that entry belongs to. If
tenant `"A"` is deactivated (its entry deleted, discarding `in_use: 2`
knowledge for two still-live refs `ref1`/`ref2`) and then reactivated
*before* `ref1`/`ref2` release — nothing in §3/§4 prevents this timing,
since `TenantStatus` blocks only *new* requests, not requests already
admitted — a fresh request for `"A"` creates a brand-new `tenants["A"] =
%{in_use: 0}` entry via `ensure_tenant_tracked/2` and gets admitted
(`in_use: 1`, `ref3`). When `ref1` then releases, `"A"` is a key again
(from the fresh entry), so a bare presence check takes the "decrement"
branch: `1 - 1 = 0`. When `ref2` releases, same check, same branch:
`0 - 1 = -1`. `in_use` goes negative, which always satisfies
`tenant_in_use < per_tenant_cap`, silently over-admitting `"A"` relative
to every other tenant. This is exactly the composed defect
CODE-DESIGN-VALIDATOR traced through the prior revision of this document.

**Fix: a per-schema generation counter that survives eviction, kept
server-side, never trusted from the caller.** The existing
`handle_call({:release, %Ref{id: id}}, ...)` clause already treats the
caller-supplied `Ref` struct's own fields as untrusted — it sources the
pool to release from the server's own `state.refs` table, keyed by the
unforgeable `id`, specifically so a hand-altered or stale struct field
cannot mis-release (see that clause's existing comment). The generation
stamp follows the identical trust model: it is **not** added to the
public `Letflow.Admission.Ref` struct (whose shape, `%{id: reference(),
pool: pool_selector()}`, is unchanged), and it is **not** supplied by the
caller at release time. Instead it travels the same way the pool
selector already does — captured into `state.refs` at admission time,
looked up server-side at release time.

**New state field**, added alongside `tenants`/`refs`/etc.:

`@type tenant_generations :: %{optional(String.t()) => non_neg_integer()}`

Semantics: `Map.get(tenant_generations, schema, 0)` is the current
"epoch" for `schema`. Unlike `tenants`, entries in `tenant_generations`
are **never deleted** — `forget_tenant/2` only ever increments the
counter for the schema it evicts (creating it at `1` if the schema had no
prior entry, i.e. `Map.update(tenant_generations, schema, 1, &(&1 + 1))`
in effect, described here as behavior, not code). This is the one piece
of per-tenant memory that intentionally outlives eviction, precisely so a
stale reference to a prior epoch can still be recognized as stale after
the epoch's own `tenants` entry is gone. It does not reintroduce
ISS-0437's original bug: it is a single integer per administratively-known
tenant schema, not an `in_use` count, and does not feed `per_tenant_cap/1`
(§"Cleanup" reasoning in the REQ-216 doc about bounded-by-tenant-cardinality
growth, §5(b), applies to it identically to `tenants` itself).

**Revised shapes:**

`@type tenant_entry :: %{in_use: non_neg_integer(), generation: non_neg_integer()}`

`state.tenants :: %{optional(String.t()) => tenant_entry()}` (adds the
`generation` field to the map documented at `admission.ex:246-255`;
`in_use`'s meaning and type are unchanged).

`state.refs :: %{optional(reference()) => {pool_selector(), generation :: non_neg_integer() | nil}}`
(adds a paired generation stamp next to the existing `pool_selector()`
value; `nil` for a `:global` entry, which has no per-tenant generation
concept — `:global`'s release path never reads it).

**Behavior changes, stated precisely:**

- `ensure_tenant_tracked/2`, when it creates a fresh entry for a schema
  not currently in `tenants` (whether truly never-seen or previously
  forgotten — it still has no need to distinguish the two, per §4),
  stamps that fresh entry's `generation` from the CURRENT value of
  `Map.get(tenant_generations, schema, 0)` at that moment — not `0`
  unconditionally. If the schema already has an entry, that entry (and
  its `generation`) is left as-is; `generation` is set once, at entry
  creation, and never mutated afterward by any other call (`in_use`
  mutations use `%{&1 | in_use: ...}`-shaped updates that leave
  `generation` untouched, exactly as they already leave any other
  untouched field alone today).
- `handle_call({:try_acquire, {:tenant, schema}}, ...)`, on a successful
  admission, stores `{pool, tenants[schema].generation}` — the entry's
  generation AT THE MOMENT OF THIS ADMISSION — into `state.refs` under the
  new ref's `id`, instead of the pool selector alone. This read-then-store
  happens within the same serialized `handle_call`, so there is no
  window for the generation to change between being read and being
  stamped.
- **`handle_call({:try_acquire, :global}, ...)` is also changed** (this is
  a correction to the prior revision of this document, which declared
  §2.1's revised `state.refs` type as uniformly `{pool_selector(),
  non_neg_integer() | nil}` but never updated this clause to match — left
  as originally written, this clause stores the bare atom `:global` under
  the ref's `id`, producing a MIXED-shape `state.refs` map where some
  entries are bare atoms and others are `{pool, generation}` tuples; the
  first ordinary `:global`-only release would then fail to destructure as
  a 2-tuple and raise `MatchError` in the release clause below — not a
  rare corner case, this is the ordinary Poller-sweep path). The fix:
  this clause now stores `{:global, nil}` — instead of the bare atom
  `:global` — under the new ref's `id` in `state.refs`, keeping every
  entry in `state.refs` uniformly a 2-tuple regardless of pool kind. This
  is a same-`handle_call`-clause edit only: the admission decision itself
  (`state.global_in_use < state.global_cap`), `Ref{pool: :global}`'s own
  shape, and `global_in_use`'s increment are all unchanged — only the
  value written into `state.refs` changes shape, from a bare atom to a
  2-tuple with a `nil` second element (mirroring the `nil` this design
  already documents above for "`:global`'s release path never reads it").
- `forget_tenant/2`'s handler advances `tenant_generations[schema]` by one
  (§1's revised "Effect on state"), independently of whatever it does to
  `tenants[schema]`.
- `release_tenant/2`'s contract and `@spec` become:

  `@spec release_tenant(tenants :: %{optional(String.t()) => tenant_entry()}, pool_selector(), captured_generation :: non_neg_integer() | nil) :: %{optional(String.t()) => tenant_entry()}`

  For `:global`: return `tenants` unchanged (as today; `captured_generation`
  is `nil` and unused). For `{:tenant, schema}`: if `schema` is a key of
  `tenants` AND that entry's `generation` field equals `captured_generation`,
  decrement `in_use` by 1 exactly as today. In every other case — `schema`
  absent from `tenants` (forgotten and not yet reactivated), OR `schema`
  present but its `generation` does NOT match `captured_generation` (a
  stale release from a prior epoch landing on a fresh post-reactivation
  entry) — return `tenants` unchanged: a silent, tenant-side no-op. The
  caller-facing `handle_call({:release, ...})` clause is otherwise
  unchanged: `global_in_use` still decrements normally in every case,
  since that counter is untouched by `forget_tenant/2` and unaffected by
  either the absent-key or the generation-mismatch condition.

**Trace-through of CODE-DESIGN-VALIDATOR's exact 6-step interleaving,
under this fix:**

1. Tenant `"A"` active, `tenants["A"] = %{in_use: 2, generation: 0}`
   (`tenant_generations` has no entry for `"A"` yet, so generation reads
   as the default `0`). `ref1`/`ref2` both have `state.refs[id] =
   {{:tenant, "A"}, 0}`.
2. Deactivate -> `forget_tenant("A")`: `tenants["A"]` deleted;
   `tenant_generations["A"]` becomes `1`. `ref1`/`ref2`'s `state.refs`
   entries are untouched (still `{{:tenant, "A"}, 0}`) — `forget_tenant/2`
   never touches `state.refs`, exactly as before.
3. Reactivate `"A"` before `ref1`/`ref2` release. No Admission-side state
   change (§4) — `tenant_generations["A"] == 1` persists.
4. New request for `"A"` arrives. `ensure_tenant_tracked/2` creates
   `tenants["A"] = %{in_use: 0, generation: 1}` (reading the current
   `tenant_generations["A"] == 1`). It is admitted: `in_use` -> `1`,
   `ref3`'s `state.refs` entry becomes `{{:tenant, "A"}, 1}`.
5. `ref1` releases: `captured_generation = 0` (from its `state.refs`
   entry, untouched since step 1). `tenants["A"]` is present with
   `generation: 1`. `1 != 0` -> **no-op branch**: `tenants["A"]` is
   returned unchanged, still `%{in_use: 1, generation: 1}`. No decrement
   happens.
6. `ref2` releases: `captured_generation = 0`, same comparison, same
   **no-op branch**. `tenants["A"]` still `%{in_use: 1, generation: 1}`.

Final state: `tenants["A"].in_use == 1`, correctly reflecting exactly
`ref3` (the one live, current-epoch ref) and nothing else — never
negative, never wrongly zero, and matching what a freshly reactivated
tenant's true in-flight count should be. The two stale releases were
correctly recognized as belonging to a discarded epoch and had no effect
on the fresh epoch's bookkeeping.

**Variation 1 — a tenant that is deactivated and NEVER reactivated
(confirms no regression on the case §2's original hardening was written
for):** `"B"` has `tenants["B"] = %{in_use: 2, generation: 0}`, `ref1`/
`ref2` both stamped `{{:tenant, "B"}, 0}`. Deactivate -> `forget_tenant("B")`
deletes `tenants["B"]`, `tenant_generations["B"]` -> `1`. No reactivation
ever follows. `ref1` releases: `tenants["B"]` is absent entirely (not
merely generation-mismatched) -> the "absent from `tenants`" branch of
`release_tenant/2` applies directly, unchanged from the original (pre-§2.1)
hardening: no-op, no crash. `ref2` releases: same, still absent, still
no-op. No corruption, no crash, identical outcome to the pre-composition
design for this specific (non-reactivating) case — §2.1 adds a check that
only changes behavior when the schema HAS been reactivated with a fresh
entry; it is a strict refinement, not a behavior change, for the
non-reactivating case.

**Variation 2 — only one of two refs is stale; the other belongs to a
tenant that was never touched:** `ref1` belongs to `"A"` (deactivated then
reactivated, per the main trace above) and is released stale as in step 5.
`ref2` in this variation belongs to a *different*, never-deactivated
tenant `"C"` with `tenants["C"] = %{in_use: 1, generation: 0}` and
`tenant_generations` carrying no entry for `"C"` (default `0`). `ref2`
releases: `captured_generation = 0` (from `state.refs`), `tenants["C"]`
present with `generation: 0` — matches -> normal decrement branch,
`in_use` -> `0`. `"C"`'s bookkeeping is entirely unaffected by `"A"`'s
eviction/reactivation history, since generations are tracked per-schema
and `"A"`'s and `"C"`'s `state.refs` entries and `tenant_generations`
entries are independent map keys. This confirms the fix is scoped
per-tenant and does not degrade unrelated tenants' normal release path.

**Why the floor-at-0 clamp alternative was rejected:** clamping
`release_tenant/2`'s decrement at a minimum of `0` (`max(in_use - 1, 0)`)
prevents the negative excursion in the main trace's step 6, but does not
fix step 5: `ref1`'s stale release would still decrement the FRESH
entry's `in_use` from `1` to `0` (clamping only ever matters once the
value would go below `0`, and `1 - 1 = 0` doesn't trigger it) — so `ref2`'s
stale release would then clamp `0 - 1` to `0`, leaving `tenants["A"].in_use
== 0` while `ref3` is still genuinely live and un-released. This
under-counts the fresh epoch by exactly the amount CODE-DESIGN-VALIDATOR's
own review flagged as a risk: tenant `"A"` would appear to have zero
in-flight requests and could be granted a full extra `per_tenant_cap`
admissions it should not get, immediately after reactivation, for as long
as any stale release from the prior epoch keeps arriving. A clamp changes
WHERE the bug shows up (from "count goes negative, forever uncapped until
enough real admissions correct it" to "count is silently short by the
number of stale releases that land, granting temporary extra grace
admissions") — it does not eliminate the underlying defect, which is that
key-presence alone cannot tell two epochs apart. The generation mechanism
above eliminates the defect at its source instead of relocating its
symptom, and was chosen for that reason.

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

**Alias note:** `lib/letflow/routers/tenants.ex` already aliases
`Letflow.TenantProvisioning` (existing alias block, line 160) — only
`Letflow.Admission` is missing. ELIXIR-DEV adds `alias Letflow.Admission`
to this router's existing alias block; no change is needed for the
`TenantProvisioning` alias.

## 4. Reactivation — no Admission-side action needed, now composed with §2.1

**Decision: `reactivate_tenant/1` requires zero corresponding
Admission-side code change**, and `handle_reactivate/2` is left as-is. This
decision is unchanged from the prior revision of this document; what
changes here is making explicit how it composes with §2.1's generation
mechanism, since that composition — not either piece in isolation — is
what CODE-DESIGN-VALIDATOR's review found broken.

Reasoning: after `forget_tenant/2` has run for a schema, that schema is
simply absent from `state.tenants` — indistinguishable, from
`Letflow.Admission`'s point of view, from a schema that has never made an
admission attempt at all. `ensure_tenant_tracked/2`'s existing lazy-creation
behavior (`handle_call({:try_acquire, {:tenant, schema}}, ...)`, called
unconditionally before every admission decision) already creates a fresh
entry the moment a reactivated tenant's *next* request reaches the tenant
admission gate — with no special-casing required, because
`ensure_tenant_tracked/2` has no notion of "previously forgotten" versus
"never seen" in the first place; both are just "not a key in
`state.tenants` right now." This is in fact the *correct* behavior, not a
lucky coincidence: a reactivated tenant starting from a clean `in_use: 0`
slate is strictly better than any alternative that tried to restore its
pre-deactivation `in_use` value (which would be stale and potentially
nonzero from before deactivation, per §2's forced-eviction decision).

**What §2.1 adds on top of this, without changing the decision above:**
the fresh entry `ensure_tenant_tracked/2` creates is no longer bare
`%{in_use: 0}` — it is `%{in_use: 0, generation: g}`, where `g` is read
from `state.tenant_generations` (§2.1), which DOES remember that this
schema was previously forgotten, even though `state.tenants` itself does
not. This is deliberately asymmetric: `state.tenants` stays "no memory of
forgotten schemas" (so `reactivate_tenant/1` needs no Admission-side call,
preserving this section's original decision and REQ-216's precedent of
not letting Identity or the router know about Admission's internal
bookkeeping), while `state.tenant_generations` is the one piece of state
that *does* remember, specifically so that ANY ref admitted before the
forgetting (stamped with the OLD generation, per §2.1) is recognized as
stale against the NEW generation's entry at release time — without
requiring `reactivate_tenant/1` itself to do anything. The reactivation
path is therefore still a true no-op on the `Letflow.Identity`/
`Letflow.Routers.Tenants` side; all of the new bookkeeping lives entirely
inside `Letflow.Admission` and is triggered by the *next admission
attempt* for that schema, not by reactivation itself (reactivation and the
next admission attempt for a schema are not the same event, and could be
arbitrarily far apart in time — that gap is fine, since nothing needs to
happen for a schema that never gets another admission attempt, matching
this design's existing "lazy, on-demand" philosophy).

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
eviction (ISS-0437)"). This same correction must also update the state-shape
comment at `admission.ex:246-255` to reflect §2.1's revised shapes:
`tenants` entries gain a `generation: non_neg_integer()` field, `refs`
values become `{pool_selector(), non_neg_integer() | nil}` pairs instead
of bare `pool_selector()`, and a new `tenant_generations: %{optional(String.t())
=> non_neg_integer()}` field is added to the state map, initialized to
`%{}` in `init/1` alongside the existing fields.

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

**Test 2 — eviction while a ref is still held does not crash `release/2`,
and the tenant never reactivates (§2/§2.1's absent-key branch):** start an
isolated instance, `try_acquire({:tenant, "c"}, name)` to obtain `ref`,
then immediately `Admission.forget_tenant("c", name)` while that ref is
still live and unreleased (`in_use` was 1 at the moment of eviction), and
do NOT make any further admission attempt for `"c"` afterward. Assert
`Admission.release(ref, name) == :ok` — no raise, no `KeyError` — proving
`release_tenant/2`'s missing-key tolerance is real, not just specified.
Follow with a global-budget-boundary assertion that the release still
freed the GLOBAL unit correctly (e.g. if `global_cap` was exhausted by
this and other refs, a subsequent `try_acquire(:global, name)` now
succeeds where it previously would not have) — this confirms
`global_in_use` decremented normally despite the tenant-side map having no
entry to update. This test exercises §2.1's "absent from `tenants`
entirely" branch of `release_tenant/2` (schema never reactivated, so there
is no fresh entry to accidentally corrupt) — Test 4 below exercises the
generation-mismatch branch (schema IS reactivated before the stale
release lands).

**Test 3 — reactivation resumes tracking with zero additional code
(§4), stated as a regression-guard, not a new mechanism test:** after
`forget_tenant/2` removes tenant `"d"`, a subsequent
`try_acquire({:tenant, "d"}, name)` succeeds exactly as it would for a
schema never seen before (asserting `{:ok, _ref}`, and that it correctly
counts into a freshly recomputed `per_tenant_cap` alongside any other
still-tracked tenant) — demonstrating `ensure_tenant_tracked/2`'s existing
lazy-creation path is sufficient with no `reactivate_tenant/1`-side
Admission call.

**Test 4 — deactivate -> reactivate -> stale pre-eviction releases must
never corrupt the fresh entry's `in_use` (§2.1's composed fix; this is the
exact defect CODE-DESIGN-VALIDATOR's prior review found):** start an
isolated instance. Make TWO admission attempts for tenant `"a"` —
`ref1 = try_acquire({:tenant, "a"}, name)`, `ref2 = try_acquire({:tenant,
"a"}, name)` — choosing `global_cap`/`per_tenant_cap` large enough that
both succeed (e.g. a single tracked tenant, so `per_tenant_cap =
max(div(global_cap, 1), 1)`, with `global_cap >= 2`); this leaves
`tenants["a"].in_use == 2` with both refs still live and unreleased. Call
`Admission.forget_tenant("a", name)` (simulating deactivation) WITHOUT
releasing `ref1`/`ref2` first. Then make a THIRD admission attempt,
`ref3 = try_acquire({:tenant, "a"}, name)` (simulating a post-reactivation
request reaching the gate again) — assert it returns `{:ok, _ref}` and
that this fresh entry starts from `in_use == 1` (provable black-box via a
subsequent `try_acquire({:tenant, "a"}, name)` respecting a
`per_tenant_cap` computed from `in_use == 1`, not `in_use == 3` and not
`in_use == -1`/`0` — e.g. with `per_tenant_cap` pinned to exactly `1` via
`global_cap == 1` for this test's single tenant, assert a fourth attempt
`try_acquire({:tenant, "a"}, name)` returns `{:error, :capacity}`,
proving `in_use == 1` exactly, not less). THEN release the two STALE refs:
`Admission.release(ref1, name) == :ok` and `Admission.release(ref2, name)
== :ok` — both must succeed with no raise. Finally assert the fresh
epoch's admission state is UNCHANGED by those stale releases: a further
`try_acquire({:tenant, "a"}, name)` still returns `{:error, :capacity}`
(if `in_use` had been wrongly decremented to `0` or below by either stale
release, this would incorrectly return `{:ok, _ref}` instead). This is the
load-bearing assertion distinguishing this design from both the original
(pre-fix) crash/dilution bug and the rejected floor-clamp alternative:
neither the KeyError, nor a negative count, nor a wrongly-freed slot may
occur.

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
only new public API is `Letflow.Admission.forget_tenant/2` (§1); the
changed existing function bodies are `release_tenant/2` (now arity 3,
generation-aware, §2.1), `ensure_tenant_tracked/2` (stamps a generation on
fresh entries, §2.1), the `handle_call({:try_acquire, {:tenant, ...}})`,
`handle_call({:try_acquire, :global})` (now stores `{:global, nil}` instead
of the bare atom `:global` into `state.refs`, keeping every `state.refs`
entry a uniform 2-tuple — §2.1), and `handle_call({:release, ...})` clauses
(all three now read/write the paired generation in `state.refs`, §2.1),
`init/1` (adds `tenant_generations: %{}` to the initial state, §2.1/§5(a)),
and `handle_deactivate/2`'s orchestration (§3). `release_tenant/2`'s `@spec` gaining a third parameter
is a private-function signature change only — no caller outside this
module invokes it directly, and `release/2`'s own public `@spec` is
unchanged (still `admission_ref(), GenServer.server() -> :ok`). No change
to `try_acquire/2`'s or `release/2`'s PUBLIC signatures, no change to
`per_tenant_cap/1`'s formula or inputs (`tenant_generations` is never read
by it), and no change to the public `Letflow.Admission.Ref` struct's
fields (`@type t :: %{id: reference(), pool: pool_selector()}` is
unchanged — see §2.1 for why the generation stamp is deliberately kept
server-side in `state.refs` instead of added to this caller-visible
struct).
