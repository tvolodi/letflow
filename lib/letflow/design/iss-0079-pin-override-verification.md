# ISS-0079: verify pin overrides against the injected `Lookup` (GH#298)

## Problem (restated from the issue, design scope only)

`Letflow.Engine.PinResolver.resolve_one_ref/4` and `resolve_variable_schema/3`
take a caller-supplied `pin_overrides` entry (`kind`, `ref`, `resolved_id`,
`version`) verbatim, with **zero verification against `lookup`**, and
`override_entry()` unconditionally permits `kind: :module`. R-Co's
`pin_resolver.zig` treats overrides as an overlay applied *after* normal
resolution, re-verifies every override against a fresh catalog lookup,
rejects `kind: module` overrides unconditionally, and treats an override
naming a ref outside the enumerated pin set as an error
(`UnresolvedPinOverride`, HTTP 422) rather than a silent no-op. Full citations
are in `docs/issues/ISS-0079.yaml`; not repeated here except where a specific
line anchors a decision below.

**Line-number verification (per this run's instructions).** ISS-0079's
`letflow_evidence` cites line numbers from the audit run
(`WF03-REQ110-20260819`). The moduledoc has grown since (ISS-0078's fix,
merged after that audit) and every cited function has moved, though **no
cited function's content changed** — confirmed by direct re-read of
`lib/letflow/engine/pin_resolver.ex` this run:

| Issue's citation | Current location (verified this run) |
|---|---|
| `resolve_one_ref/4` verbatim override, `:317-328` | `:353-364` |
| `resolve_variable_schema/3` verbatim override, `:353-379` | `:389-415` |
| `override_entry()` permits `kind: :module`, `:153-158` | `@type override_entry`, `:190-195` |
| stray override refs never consulted, `:304-315` | `resolve_refs/4` + `find_override/3`, `:340-370` |
| `resolve_error()` has no `unresolved_pin_override` variant, `:184-187` | `@type resolve_error`, `:221-224` |
| `Enum.uniq()` dedup (adjacent delta a), `:292` | `:328` |
| `Atom.to_string/1` sort key (adjacent delta b), `:383-385` | `:419-421` |

All findings in the issue still hold against current code. This design cites
current line numbers going forward.

## Decision records checked (none touch this ground directly)

`docs/migration/decisions/0001` through `0007` were checked. None address pin
overrides, `resolve_error()` mapping conventions, or PLC-01/module scoping —
the closest is `0007-variable-merge-validates-new-keys.md`, which is about a
different module (`VariableMerge`) and does not generalize to this decision.
The only prior record touching this exact ground is
`lib/letflow/design/req059-pin-resolver.md` itself (§4.1, §9 OQ-1/OQ-6),
addressed point-by-point below. Nothing here silently re-decides a
`docs/migration/decisions/` entry.

## Decision 1 — `resolve/4` re-verifies every override against `lookup`; §4.1's "no lookup call for an override" is explicitly superseded

**Decision: yes. Every override is verified against the corresponding
`lookup.catalog_lookup` / `lookup.module_lookup` / `lookup.variable_schema_lookup`
function before being accepted. `resolve/4` remains pure/side-effect-free in
every sense that matters (still zero `Repo` calls, still deterministic given
a fixed `lookup`) — it simply now calls `lookup` for override refs too, not
only non-override refs.**

Current §4.1 text (`req059-pin-resolver.md:306-310`) reads: "If `overrides`
contains a matching `{kind, ref}` entry: use it verbatim ... **no**
`lookup.catalog_lookup`/`lookup.module_lookup` call made for this ref at all
(the override fully substitutes for resolution, consistent with
`source: :override` meaning 'not resolved by this module's own lookup
path')." **This design supersedes that sentence.** It was written before
R-Co's actual mechanism was read (§9 OQ-1 of that same document says so
explicitly); OQ-1's own resolution already flags the delta as real and routes
it here. There is no invariant elsewhere in the codebase (`INV-PIN-*` in the
`.ex` moduledoc, or any `docs/migration/decisions/` entry) asserting
`resolve/4` must never call `lookup` for an override ref — the "no lookup
call" property was this design's own original invention for §4.1, not a
requirement-text or R-Co-verified constraint, so overriding it does not
violate anything load-bearing outside this same file.

Reasoning for verifying rather than continuing to trust verbatim:

- The issue's own severity framing is decisive: an unverified override
  "poisons every later execution-time lookup for that instance's whole
  lifetime" (pins are immutable after `INSTANCE_STARTED` except via PIN-05
  rebind, and `pin_for/3` has "no fallback, ever"). A tenant-facing input
  that can assert an unverified fact into a permanent, replay-authoritative
  event payload is exactly the class of trust-boundary gap this project's
  `security-invariants.md` exists to close.
- "Purity" in the sense §4.1 cared about was never "makes no calls to
  `lookup`" — `resolve/4` already calls `lookup` for every non-override ref.
  The real property worth keeping is "no `Repo`/database call, deterministic
  given a fixed `lookup` and fixed inputs" — calling `lookup.catalog_lookup`
  one more time per override ref does not touch that property at all, since
  `lookup` is already an injected, referentially-transparent-by-contract
  function (`ServiceScopeValidator.Lookup`'s own established shape).
- Matches R-Co's actual, source-verified mechanism exactly on this specific
  point (verify-before-accept), which is the point ISS-0079 was filed to
  close.

## Decision 2 — `resolve_error()` gains `{:unresolved_pin_override, ref}`; `Letflow.Engine.create_error()` gains the same variant, mapped like its siblings

**Decision: yes, new variant on both `PinResolver.resolve_error()` and
`Engine.create_error()`. Documented HTTP-422 analogue, following the exact
pattern already established for `unresolved_catalog_ref`/`unresolved_module_ref`.**

```
# PinResolver, @type resolve_error (pin_resolver.ex:221-224) becomes:
@type resolve_error ::
        {:error, {:unresolved_catalog_ref, ref :: String.t()}}
        | {:error, {:unresolved_module_ref, ref :: String.t()}}
        | {:error, {:unresolved_pin_override, ref :: String.t()}}
        | {:error, {:graph_structure_invalid, term()}}
```

```
# Engine, @type create_error (engine.ex:374-393) gains one new member,
# inserted next to its two existing pin-resolution siblings:
| {:error, {:unresolved_catalog_ref, ref :: String.t()}}
| {:error, {:unresolved_module_ref, ref :: String.t()}}
| {:error, {:unresolved_pin_override, ref :: String.t()}}
```

Mapping convention confirmed by direct read of `engine.ex`: `lib/letflow/router.ex`
exists (a `Plug.Router` with a `/health` route), but **no controller or route
anywhere in this codebase maps `create/2`'s errors to an HTTP status** —
grepped for any `create_error()`-to-HTTP-status mapping and found none; the
S4 API surface that will eventually own that mapping has not been built yet
(S3 is pre-API-route scope for `Engine.create/2` specifically). The established convention (`engine.ex:114-127`'s
`complete_task/3` moduledoc section, "HTTP and assignee authorization are out
of scope") is: `Letflow.Engine` returns tagged tuples only, and its moduledoc
**documents** the HTTP status a future S4 caller should map each variant to,
without any code performing that mapping yet. `resolve_error()`'s two
existing siblings (`unresolved_catalog_ref`/`unresolved_module_ref`) are
themselves undocumented for HTTP purposes today — this design adds the
documentation convention for all three at once rather than leaving a third
undocumented sibling:

- **Moduledoc addition (both `pin_resolver.ex` and `engine.ex`):** state
  that `{:unresolved_pin_override, ref}` — like `{:unresolved_catalog_ref,
  ref}` and `{:unresolved_module_ref, ref}` — is the HTTP 422 analogue once
  an S4 route exists (matching R-Co's own `UnresolvedPinOverride` → HTTP 422,
  cited in the issue), and that `ref` is the override's own `ref` field (the
  same value the caller supplied), not a pin-set index, so a 422 response
  body can echo back exactly what the caller named.
- Where `{:unresolved_pin_override, ref}` is raised, by function: both
  `resolve_one_ref/4` (catalog/module overrides, current `:353-364`) and
  `resolve_variable_schema/3` (variable_schema override, current `:389-415`)
  gain this as their verification-failure outcome — see Decisions 1 and 4
  below for exactly which verification failures produce it.
- `Engine.create/2`'s existing `with` chain (§3 of `req059-pin-resolver.md`,
  step 2, `PinResolver.resolve/4`'s call site) needs no new branch: it
  already propagates any `resolve_error()` member through unchanged (the
  existing `{:unresolved_catalog_ref, _}`/`{:unresolved_module_ref, _}`
  pass-through is the precedent — `{:unresolved_pin_override, _}` is a third
  member of the same union flowing through the identical `with` clause,
  mechanical, no new code path).

## Decision 3 — `kind: :module` overrides: still legal in Letflow, on Letflow's own merits (not a port of R-Co's stopgap)

**Decision: `kind: :module` remains a legal override in Letflow. Do not
adopt R-Co's unconditional rejection.**

R-Co's own comment for the rejection is explicit and load-bearing for this
decision: `pin_resolver.zig:642`, "a module override can never verify —
`UnresolvedPinOverride`." That is not a principled rule about module
overrides being inherently untrustworthy — it is a direct consequence of
PLC-01 (R-Co's process module catalog) not existing in R-Co at all, so
*nothing* can verify a module override there, ever, for any input. Once
Decision 1 makes verification real, R-Co's rejection collapses to "verifying
a module override is impossible because there is nothing to verify it
against," which is a statement about *R-Co's* missing catalog, not about
`kind: :module` overrides as a concept.

Letflow's own situation is checked directly, not assumed:

- `Letflow.Engine.PinResolver.Lookup` already has a `module_lookup` field
  (`:catalog_lookup, :module_lookup, :variable_schema_lookup`,
  `pin_resolver.ex:234-235`) — the same injectable shape `catalog_lookup`
  uses, not a stub with a different contract.
- Grepped `lib/letflow/engine/sub_process.ex` (the only other module in this
  codebase touching `SUB_PROCESS`/module-ref concepts) for any
  `module_lookup`/`PinResolver` reference: none found. No production
  `module_lookup` implementation exists yet — same as `catalog_lookup`,
  which is likewise `{:error, :not_found}`-only in `default_lookup/0`
  (`pin_resolver.ex:270`). This is the **identical SCOPE GAP already
  documented** in the moduledoc's own "SCOPE GAP — service_catalog (S6) and
  PLC-01 (unscoped) are not built" section (`pin_resolver.ex:27-49`):
  `catalog_entry` and `module` are already both only resolvable against an
  injectable `Lookup`, never a real registry, and this has never been reason
  to reject `catalog_entry` overrides.
- Under Decision 1's verification rule, a `kind: :module` override against
  `default_lookup/0` (whose `module_lookup` always returns `{:error,
  :not_found}`) is **already rejected** the same way an unverifiable
  `catalog_entry` override would be — `{:error, {:unresolved_pin_override,
  ref}}` (Decision 4 below settles exactly this: verification failure ==
  unresolved override, uniformly across all three kinds). Letflow does not
  need a *categorical* `kind: :module` ban to get "a module override that
  can't be verified is rejected" — that already falls out of Decision 1
  applied uniformly. A separate categorical ban would only add value the
  day Letflow ships a real `module_lookup` and specifically wants module
  overrides to be un-overridable even when verifiable — no acceptance
  criterion (PIN-01 through PIN-04) asks for that, and inventing it now
  would be adding a restriction with no requirement behind it.
- No `docs/migration/decisions/` entry addresses PLC-01 or module-override
  scoping (checked above) — so keeping `kind: :module` legal does not
  contradict any settled decision; it is simply "treat all three `kind`
  values uniformly under the same verification rule," which is the simpler,
  more consistent design and is explicitly the class of choice this run was
  told not to resolve by blind R-Co-parity ("Item 3 in particular is a case
  where copying R-Co would be copying a stopgap").

**No `override_entry()` type change is needed for this decision** — it
already permits `kind: :catalog_entry | :module | :variable_schema`
(`pin_resolver.ex:190-195`); this decision is "leave it as-is," not "widen
it."

## Decision 4 — an override naming a ref the graph doesn't enumerate is an error, not a no-op

**Decision: error, matching R-Co. `resolve/4` returns `{:error,
{:unresolved_pin_override, ref}}` for every `overrides` entry that does not
match any enumerated `{kind, ref}` pin, in addition to every entry that fails
per-kind verification (Decision 1).**

Reasoning:

- The issue's own recommendation ("Recommend matching R-Co's 'error'
  behavior unless you find a concrete reason Letflow's needs differ") is
  followed — no reason to diverge was found. A stray override naming a ref
  that does not exist in the graph is, on its face, evidence of a caller
  mistake (a typo'd `ref`, a stale override from a previous version of the
  definition, an override meant for a different process) — silently
  ignoring it hides exactly the class of caller error a 422 response exists
  to surface immediately. Rejecting the instance-creation attempt outright,
  with a specific `ref` the caller can act on, is preferable to starting an
  instance against a set of overrides the caller did not fully understand
  was only partially applied.
- This is consistent with Decision 1/2's shape: both categories of failure
  (fails per-kind verification against `lookup`, and names no enumerated
  ref at all) collapse into the same `{:unresolved_pin_override, ref}`
  outcome — one error variant, two ways to reach it, matching R-Co's own
  `applyOverrideToPins()` returning `false` (unmatched ref) and
  `applyPinOverrides()`'s verification failure both terminating in the same
  `UnresolvedPinOverride`.

### Combined control-flow specification for Decisions 1/2/4 (§4.1/§4.2 supersession)

This replaces `req059-pin-resolver.md` §4.1 point 1 and §4.2's override
branch. **No implementation code — control flow only, for ELIXIR-DEV to
build against directly:**

For each enumerated `{kind, ref}` pin (catalog_entry/module from §4.1's node
walk, plus the always-present variable_schema entry from §4.2):

1. If `overrides` contains a matching `{kind, ref}` entry, **verify it**
   before accepting:
   - `kind: :catalog_entry` → call `lookup.catalog_lookup.(ref)`. Accept
     (`source: :override`, `resolved_id`/`version` taken from the *lookup
     result*, not the caller-supplied override — see note below) only if
     the call returns `{:ok, %{version: v}}` **and** `v` equals the
     override's own `version`. Any other outcome (`{:error, :not_found}`,
     or `{:ok, %{version: v}}` with `v` different from the override's
     `version`) → `{:error, {:unresolved_pin_override, ref}}`, halting
     resolution immediately (same halt-on-first-error discipline §4.1
     already uses for `unresolved_catalog_ref`/`unresolved_module_ref`).
   - `kind: :module` → identical rule against `lookup.module_lookup.(ref)`
     (Decision 3: no categorical rejection; same verify-then-accept path as
     `:catalog_entry`).
   - `kind: :variable_schema` → call `lookup.variable_schema_lookup.(nil,
     ref)` (§4.2's existing `tenant_id: nil` convention, OQ-7). Accept only
     if the call's `version` equals the override's `version`. Mismatch or
     any non-matching outcome → `{:error, {:unresolved_pin_override, ref}}`.
   - **`resolved_id`/`version` on an accepted override come from the fresh
     lookup result, not verbatim from the caller**, for `catalog_entry` and
     `module`. R-Co's own wire shape carries no `resolved_id` at all (§9
     OQ-1's citation of `pin_resolver.zig:206`) and verifies `version` only.
     Letflow's `override_entry()` wire shape *does* carry a caller-supplied
     `resolved_id` (unlike R-Co) — this design keeps accepting that field on
     the wire (`override_entry()`'s type is unchanged, per Decision 3) but
     does **not** use the caller-supplied value in the accepted pin: only
     `version` is checked against the lookup result (matching R-Co's own
     verification scope, which never verifies a caller-asserted identifier),
     and the accepted pin's `resolved_id` is always the lookup result's own
     `resolved_id`, since that is the value that was just confirmed to
     exist. This avoids a caller successfully verifying a real `version`
     while still asserting an arbitrary, unverified `resolved_id` alongside
     it — closing the same trust gap Decision 1 exists to close, not
     reopening a narrower version of it.
   - **Sub-decision — `kind: :variable_schema`'s accepted `resolved_id` is
     forced to `nil`, never the caller-supplied value.** This is the
     `variable_schema` analogue of the bullet directly above, made explicit
     because `Lookup.variable_schema_lookup_result` (`pin_resolver.ex:241`)
     has **no `resolved_id` field at all** — there is no lookup-confirmed
     value to substitute the way `catalog_entry`/`module` substitute the
     lookup's own `resolved_id`. Two options were weighed: (a) keep the
     caller-supplied `resolved_id` verbatim on an accepted override (current
     shipped behaviour, `resolve_variable_schema/3`, `pin_resolver.ex:389-415`),
     or (b) force it to `nil` on every accepted `variable_schema` override,
     matching every non-override `variable_schema` pin (`resolved_id: nil`
     unconditionally, §4.2/moduledoc — no `variable_schema` pin, override or
     not, has ever carried a real `resolved_id` in this module's design).
     **Decision: (b), force `nil`.** Option (a) reopens exactly the
     unverified-identity trust gap Decision 1 exists to close, just scoped
     to one `kind`: `version` would be confirmed against the lookup, but
     `resolved_id` would still be an arbitrary, never-checked value asserted
     by the caller and written permanently into `INSTANCE_STARTED` — the
     same poisoning risk the issue itself describes ("poisons every later
     execution-time lookup for that instance's whole lifetime"), merely
     narrowed to a field most consumers won't think to distrust because its
     sibling fields (`version`) *are* verified. There is also no lookup
     result to justify accepting *any* particular non-`nil` value as
     "confirmed" — unlike `catalog_entry`/`module`, where the lookup result
     supplies a value that was just proven to exist, `variable_schema`'s
     lookup supplies no `resolved_id` of any kind, so `nil` is the only
     value with no unverified claim attached to it. Forcing `nil` also keeps
     `pinned_version()`'s existing invariant intact without a special case:
     a reader inspecting any `variable_schema` pin already knows
     `resolved_id` carries no identity information, override or not — this
     preserves that uniformly rather than making it override-dependent.
     **Implementation note for ELIXIR-DEV:** this is a one-line behavioural
     change to `resolve_variable_schema/3`'s override-hit branch
     (`pin_resolver.ex:391-400`) — `resolved_id: resolved_id` (from the
     override) becomes `resolved_id: nil`, unconditionally, once verification
     (this sub-decision's sibling bullet) passes.
2. If `overrides` contains no matching `{kind, ref}` entry: resolve
   normally via `lookup` (§4.1's existing non-override path, unchanged).
3. **After all enumerated pins are processed**, check for any `overrides`
   entry whose `{kind, ref}` matched **no** enumerated pin at all (Decision
   4's stray-ref case): `{:error, {:unresolved_pin_override, ref}}` for the
   first such stray entry found, in `overrides`' own list order. This check
   only needs to run if steps 1-2 completed without halting (an earlier
   verification failure already halts resolution — no need to also scan for
   stray refs after an unrelated failure already aborted).

`sort_pins/1`'s stability and `resolve/4`'s halt-on-first-error discipline
are both otherwise unchanged.

## Moduledoc update requirements (`pin_resolver.ex` lines 116-144)

**Mandatory for ELIXIR-DEV — this is not optional polish.** The moduledoc's
"OQ-1 is RESOLVED as of 2026-08-19" section (`pin_resolver.ex:116-144`,
verified current this run) states, as present-tense fact, exactly the
behaviour this design changes. Once this fix ships, several of its clauses
become false and must not be left standing. Each affected sentence/paragraph
is named below with the required effect — not a full rewrite in code form
(forbidden for this design doc), but precise enough that ELIXIR-DEV cannot
ship code leaving the moduledoc self-contradictory.

1. **Lines 126-129** ("This module, by contrast, takes a caller-supplied
   override verbatim in `resolve_one_ref/4` below — no lookup call, no
   verification, no `unresolved_pin_override` error variant — so an override
   may assert a version that was never confirmed to exist.") — **must be
   removed or rewritten in the past tense as history**, since after this fix
   `resolve_one_ref/4` (and `resolve_variable_schema/3`) *do* call `lookup`,
   *do* verify, and `unresolved_pin_override` *does* exist as a
   `resolve_error()` member (Decision 2). Replace with a statement that
   Letflow's override mechanism now matches R-Co's verify-then-accept shape
   (Decision 1), citing this document (`iss-0079-pin-override-verification.md`)
   as the design that closed the gap, the same way the moduledoc already
   cites `iss-0078-pin-rebind-provenance.md` for the rebind-provenance fix
   two paragraphs later (line 137-144's pattern is the template to follow).
2. **Lines 129-132** ("R-Co additionally sets `source: :override` from a
   SECOND producer this module's design never anticipated: a PIN-05 rebind
   ...") — **unaffected, leave as-is**; this is ISS-0078's finding, not this
   design's concern, already correctly described as resolved two paragraphs
   later.
3. **Lines 134-135** ("The override-mechanism delta is recorded, not
   repaired, per REQ-110's audit-only scope: `docs/issues/ISS-0079.yaml`
   (GH#298).") — **must change**: this sentence is precisely the "filed, not
   fixed" status this change closes. Once ELIXIR-DEV implements this design,
   rewrite to state the delta **was** repaired, citing both
   `docs/issues/ISS-0079.yaml` (GH#298) and this design document, following
   the exact phrasing template lines 135-137 already use for ISS-0078
   ("The rebind-provenance delta was fixed under `docs/issues/ISS-0078.yaml`
   (GH#299, `lib/letflow/design/iss-0078-pin-rebind-provenance.md`) — ...").
   The replacement sentence must summarize, in the same one-clause style as
   that template, the four settled decisions: overrides are now verified
   against `lookup` before acceptance (Decision 1); `kind: :module` remains
   legal, verified the same way as `catalog_entry` (Decision 3); a stray
   override ref is an error, `{:unresolved_pin_override, ref}` (Decision 4);
   and a `variable_schema` override's `resolved_id` is forced to `nil` on
   acceptance regardless of what the caller supplied (the sub-decision
   above).
4. **Line 8** (top-of-moduledoc pointer: "and that reconstruction did **not**
   hold on the override path: see the OQ-1 resolution below,
   `docs/issues/ISS-0079.yaml` (GH#298) and `docs/issues/ISS-0078.yaml`
   (GH#299)") — **must add a forward pointer** to this design document
   alongside the existing `ISS-0079.yaml` citation, so a reader lands on the
   fix's reasoning, not only the original finding (matching how the
   `ISS-0078.yaml` citation on the same line is already paired with its own
   design doc further down).
5. **`resolve/4`'s own `@doc` (`pin_resolver.ex:277-291`, "PIN-01 —
   enumerates ... in `overrides` first, `lookup` otherwise")** — the phrase
   "in `overrides` first, `lookup` otherwise" **must change** to state that
   an `overrides` entry is now verified against `lookup` before being
   accepted, and that an unverifiable or stray override entry halts
   resolution with `{:error, {:unresolved_pin_override, ref}}` — this is the
   `@doc`'s own summary of §4.1's algorithm and must not continue describing
   the pre-fix verbatim-acceptance behaviour once §4.1 itself changes
   (Decision 1's control-flow spec, above).
6. **Disposition (b)'s own required addition (already specified in that
   section below, restated here for completeness):** one sentence stating
   the `{Atom.to_string(kind), ref}` sort order is Letflow's deliberately
   chosen canonical order, diverging from R-Co's `PinKind` ordinal order by
   design.

No other part of the moduledoc (the SCOPE GAP section, the persistence
section, the "no fallback, ever" section, OQ-2 through OQ-7) is affected by
this design and must not be touched under this change.

## Disposition (a) — `Enum.uniq()` dedup vs. R-Co's no-dedup

**Recommendation: keep as-is. Not part of this fix. No follow-up issue
needed for a deliberate-deviation decision record — document it as a
deliberate, already-justified deviation directly in this design instead.**

Reasoning:

- The issue's own framing already calls this "arguably the better
  behaviour" — two `SERVICE_TASK` nodes sharing one `service_id` producing
  one pin entry (Letflow) rather than two byte-identical entries (R-Co) is a
  strict improvement in payload clarity with no acceptance criterion (PIN-01
  AC1's byte-identical-ordering requirement is about *sort determinism*, not
  about matching R-Co's entry *count*) that depends on the duplicate.
- No caller anywhere reads `pinned_versions` by list length or by
  positional index (`pin_for/3` is the only accessor, and it is a `{kind,
  ref}` keyed find, `pin_resolver.ex:698-703` — duplicate entries would be
  invisible to it either way except for wasted bytes).
  A dedup'd list is a strictly more useful invariant for
  `pin_for/3`'s callers to rely on ("at most one entry per `{kind, ref}`")
  than a list that may or may not contain duplicates depending on how many
  graph nodes happen to share a reference.
- This is a genuine behavioural improvement over the port, not an
  unexamined accident — recording the reasoning here (rather than filing a
  separate issue whose entire content would be "confirm this is fine") is
  sufficient documentation; a future reader auditing this file against R-Co
  finds the deviation already explained, which is exactly what a
  deliberate-deviation decision record exists to do. No code change,
  moduledoc change is optional but harmless: if ELIXIR-DEV wants to make
  this explicit in the moduledoc's SCOPE GAP-adjacent section, that's a
  welcome addition but not required by this design.

## Disposition (b) — sort order: `Atom.to_string/1` vs. R-Co's `@intFromEnum`

**Recommendation: lock down `{catalog_entry, module, variable_schema}` as
Letflow's canonical order now, in this change, rather than leaving it a
follow-up. This is exactly what shipped code already does — no code change
required, only making the choice explicit and permanent in this design
record so a future refactor doesn't casually "fix" it toward R-Co's order
under the mistaken belief that would be a parity improvement.**

Reasoning:

- PIN-01 AC5 is explicit that ordering is load-bearing (byte-identical
  serialization across repeated `resolve/4` calls given the same inputs) —
  this is a property about Letflow's **own** internal determinism, not
  about matching R-Co's enum-ordinal choice. R-Co's own order
  (`catalog_entry < variable_schema < module`,
  `PinKind` enum at `pin_resolver.zig:25`) is itself an arbitrary
  declaration-order artifact of a Zig `enum`, not a value with independent
  meaning any consumer depends on.
- The issue is explicit that R-Co's own order for `module` is **entirely
  unobservable** in R-Co today (`module_ref` resolution returns
  `UnresolvedModuleRef` unconditionally there, PLC-01 not built) — R-Co has
  never actually shipped a payload exercising its own claimed order for
  that kind. There is nothing to be "compatible with" on this specific
  axis; R-Co's ordering choice for `module` is speculative on its own side.
- Decision 3 makes `kind: :module` a real, verifiable override in Letflow
  starting with this change, and Decision 1 makes `catalog_entry`/`module`
  resolution now consult `lookup` uniformly — the moment a real
  `module_lookup` lands, Letflow (unlike R-Co) *will* produce `module` pins
  in ordinary operation. Locking the order down now, before that happens,
  avoids a payload-shape change (and the byte-identical-serialization
  break PIN-01 AC5 is written to prevent) landing later as an unplanned
  side effect of some unrelated module-catalog requirement.
- Concretely: `sort_pins/1`'s existing `{Atom.to_string(kind), ref}` key
  (`pin_resolver.ex:419-421`) already produces
  `"catalog_entry" < "module" < "variable_schema"` via plain string
  comparison — this is already Letflow's canonical order in shipped code.
  **No change to `sort_pins/1` is required by this design.** The only
  action item is documentation: add one sentence to the moduledoc's PIN-01
  AC5 discussion (or `resolve/4`'s own doc comment) stating this order is
  the deliberately-chosen canonical order, not an unexamined byproduct of
  `Atom.to_string/1`, and that it diverges from R-Co's `PinKind` enum
  ordinal order by design, citing this document.

## Acceptance-criteria / decision-item → design-element map (self-check)

| Item (from `scoping_note`) | Design element |
|---|---|
| 1. Verify overrides against `lookup`? Supersede §4.1's "no lookup" text? | Decision 1 |
| 2. `resolve_error()` gains `{:unresolved_pin_override, ref}`? `Engine.create/2` mapping? | Decision 2 |
| 3. Is `kind: :module` still legal? | Decision 3 |
| 4. Stray override ref: error or no-op? | Decision 4 |
| Combined control flow for 1/2/4 | "Combined control-flow specification" section |
| `variable_schema` override `resolved_id` on acceptance | Control-flow spec, "Sub-decision" bullet |
| (a) dedup via `Enum.uniq()` | Disposition (a) |
| (b) sort key `Atom.to_string/1` vs. R-Co ordinal | Disposition (b) |
| Line-number currency check (per run instructions) | "Line-number verification" section |
| Decision-record check (per run instructions) | "Decision records checked" section |
| Moduledoc-update requirements (rework Gap 2) | "Moduledoc update requirements" section |

## Open questions carried forward (not silently resolved)

- **`variable_schema` override verification granularity — settled, not
  open.** §4.2's existing `variable_schema_lookup` returns `%{version:,
  json_schema:}`, no `resolved_id` field at all
  (`Lookup.variable_schema_lookup_result`, `pin_resolver.ex:241-242`). The
  control-flow spec's `kind: :variable_schema` bullet verifies only
  `version` for this kind (the only field the lookup can confirm), and its
  paired sub-decision (same section) settles `resolved_id`: forced to `nil`
  unconditionally on acceptance, never the caller-supplied value — see that
  sub-decision for the full reasoning. Listed here only so a reader scanning
  "open questions" sees this was actively decided, not overlooked.
- **Existing OQ-6 (req059 §9) interaction, not reopened here but noted:**
  §9 OQ-6 already establishes that PIN-04 AC3 inheritance wins even over a
  caller-supplied `:override`. That rule is untouched by this design — a
  verified override still loses to inheritance at `apply_inheritance/2`
  time, same as an unverified one did before. This design only changes
  *whether an override is accepted into `own_pins` in the first place*, not
  what happens to it afterward.
