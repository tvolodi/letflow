# ISS-0078: restore rebind provenance in `merge_effective_pins/2` (GH#299)

## Problem (restated from the issue, design scope only)

`Letflow.Engine.PinResolver.merge_effective_pins/2` (`pin_resolver.ex:461-480`)
and its helper `apply_rebind_event/2` (`:482-498`) lose provenance on every
`INSTANCE_PINS_REBOUND` fold, on four separable points the issue's
`scoping_note` requires this design to settle:

1. A rebound pin keeps `source: :resolved` (or whatever it already was) —
   `apply_rebind_event/2` never touches `source`.
2. A rebound pin keeps its **stale** `resolved_id` from the original
   resolution, while `version` moves — the two fields end up describing two
   different versions of the same ref.
3. A rebind entry naming a `{kind, ref}` absent from the base set matches
   nothing in `apply_rebind_event/2`'s `Enum.map/2` and is silently dropped.
4. `merge_effective_pins/2` never receives the `INSTANCE_STARTED` event id,
   so `source_event_id` is seeded `nil` (`:475`) for every never-rebound pin
   — contradicting `effective_pin()`'s own `@type` (`:200-207`), which
   declares `source_event_id :: Ecto.UUID.t()`, not nilable.

All four are read-side only. `Letflow.Engine.PinRebind` (the writer) is
confirmed unaffected: its `INSTANCE_PINS_REBOUND` payload carries
`entries: [%{kind, ref, prior_version, new_version}]`
(`pin_rebind.ex:456-459`) — no `resolved_id`, and PIN-05 never re-verifies
against a catalog before writing. Nothing in this design asks `PinRebind` to
carry more than it already does; each decision below works from that payload
as it exists today, not as R-Co's differently-shaped payload does.

## Decision 1 — `source` becomes a new `:rebound` value, not `:override`

**Decision: widen `source()` to `:resolved | :override | :inherited |
:rebound`. A rebound pin's `source` becomes `:rebound`, not `:override`.**

Reasoning:

- R-Co conflates two distinct producers (caller-supplied override at
  instance start, vs. an operator's mid-flight PIN-05 rebind) under one
  `.override` value. The issue's own `scoping_note` names this as a real
  information loss ("loses the distinction between 'caller overrode at
  start' and 'operator rebound mid-flight'"), not an accident worth
  preserving.
- PIN-04 AC4's entire purpose is provenance: "where did this version come
  from?" Collapsing two different answers into one value directly works
  against that purpose. `:rebound` keeps the distinction Letflow can afford
  to keep.
- Cost is contained and already confirmed: no file outside `pin_resolver.ex`
  pattern-matches `source` atom values (grepped `lib/` and `priv/`; the one
  hit, `tenant_provisioning.ex`, is unrelated), and no HTTP layer consumes
  `EffectivePin` yet (PIN-04 AC4's `GET .../pins` route is not wired up in
  this codebase). There is no external JSON contract to break by adding a
  fourth value today. If that route is built later, it inherits the more
  informative four-value set from day one instead of needing a breaking
  migration off `:override`.
- Matching R-Co exactly would be the lower-effort choice, but "lower risk"
  here is illusory: R-Co's own choice is the thing losing information, not a
  constraint Letflow is bound by (no shipped external consumer depends on
  Letflow's `source` matching R-Co's enum).

## Decision 2 — `resolved_id` becomes `nil` on rebind, not `change.new_version` and not left stale

**Decision: a rebound entry's `resolved_id` is set to `nil`.**

Reasoning:

PROVENANCE (historical, not current decision authority):
- R-Co sets `resolved_id = dupe(change.new_version)` (`pin_resolver.zig:130`)
  — i.e., it stores a **version string** into a field every other producer
  in this module (`resolve_one_ref/4`, `interpret_lookup/3`,
  `resolve_variable_schema/3`) uses for a catalog/module-lookup's own
  **opaque resolved identifier**, distinct from `version` by construction
  (`pinned_version()`'s own field list, `:177-183`, keeps them as two
  separate keys precisely because a lookup can return an id that isn't the
  version string itself). Copying `new_version` into `resolved_id` there is
  exactly the kind of "R-Co quirk, not an intention worth porting" the
  issue's own text calls out — the scoping note is explicit that this is
  the clearest case where copying R-Co would be copying a defect. Rejected.
- Leaving `resolved_id` stale (today's shipped behavior) is worse than
  cosmetic (per the issue): a consumer that trusts `resolved_id` over
  `version` reads the pre-rebind target. Rejected — this is the bug being
  fixed, not a baseline to preserve.
- `nil` is the only value that doesn't assert something false.
  `PinRebind`'s payload carries no `resolved_id` at all
  (`pin_rebind.ex:456-459`) and never calls a catalog/module lookup to
  produce one (confirmed: `rebind_pins/3`'s own moduledoc and body resolve
  entries only against the current effective pin set, never against
  `PinResolver.Lookup`). `resolved_id` elsewhere in this module always means
  "a lookup vouched for this identity" (`interpret_lookup/3`) or "the caller
  supplied one they claim is valid" (`resolve_one_ref/4`'s override branch,
  still unverified per ISS-0079 but at least a real value the caller
  provided). A rebind has neither — no lookup ran, no id was supplied. `nil`
  says exactly that: "not reverified," which `pinned_version()`'s own field
  already allows (`resolved_id: String.t() | nil`, `:180` — nilable by
  design, e.g. `resolve_variable_schema/3`'s no-override branch already
  produces `resolved_id: nil` for the same "no lookup produced an opaque
  id" reason, `:404`). This reuses an existing, already-meaningful value
  rather than inventing a new one.

## Decision 3 — an unknown-ref rebind entry is appended, not dropped or errored

**Decision: `apply_rebind_event/2` appends a new `effective_pin()` for any
entry whose `{kind, ref}` matches nothing in the accumulator, instead of
silently discarding it (today) or raising/returning an error.**

Reasoning:

- This path is defensive-only under normal operation: PIN-05's own
  `UnknownPinRef` gate (`pin_rebind.ex:129`,
  `{:error, {:unknown_pin_ref, entry_kind(), ref}}`, produced by
  `resolve_entries_against_effective_pins/2` before any `Repo` write) is the
  reason no live `rebind_pins/3` call can ever produce this payload shape.
  The question is what `merge_effective_pins/2` does if that gate is ever
  bypassed, or the fold is fed a payload from elsewhere (a hand-constructed
  test fixture, a future second writer, replay of a payload written by a
  since-changed gate) — not normal flow.
- Error/raise is wrong for a **read path**. `merge_effective_pins/2` backs
  PIN-04 AC4's audit view — the entire point is to let an operator see what
  happened to an instance's pins. Making that view fail to load (or making
  `reconstruct_effective_pins/2` return an error) for an instance whose
  event log contains one out-of-band entry destroys the audit capability
  for exactly the instance where it matters most. This module's own "no
  fallback, ever" principle is about never *substituting* a value; it says
  nothing about refusing to *read* the record that exists.
- Drop (today's behavior) silently discards a recorded fact from the event
  log — the event log is the sole source of truth for pins in this module
  (moduledoc, "Persistence"), so a fold that discards part of it produces a
  reconstructed view that disagrees with the log it was built from, with no
  signal that anything was dropped.
PROVENANCE (historical, not current decision authority):
- Append matches R-Co's own tested, deliberate choice
  (`pin_resolver.zig:143-160`, "so the merged set stays a superset rather
  than silently dropping a recorded rebind") and is the only option that
  keeps the reconstructed set a true superset of what the log recorded,
  without treating a read as an occasion to fail.
- The appended entry uses `source: :rebound` (Decision 1) and
  `resolved_id: nil` (Decision 2) — same fields a normal rebind update
  gets, since from the reader's perspective an appended entry and an
  updated entry both mean "this ref's current value came from a rebind
  event, never independently verified since." No separate `source` value is
  introduced for the appended case.

## Decision 4 — thread `started_event_id` into `merge_effective_pins`, changing its arity 2 → 3

**Decision: `merge_effective_pins/2` becomes `merge_effective_pins/3`,
adding `started_event_id` as the **third** parameter (after the existing
two, in their existing order) — not a keyword option, not a reordering of
the existing two arguments.**

PROVENANCE (historical, not current decision authority):
Reasoning for parameter position: appending at the end means every existing
call site adds exactly one trailing argument rather than restructuring two
existing ones — smallest possible diff at both call sites
(`reconstruct_effective_pins/2` and the three test call sites). It also
mirrors R-Co's own `mergeEffectivePins()`, which likewise takes
`started_event_id` as its third parameter (`pin_resolver.zig:90-95`/`:93`),
so a reader cross-checking against R-Co finds the same shape.

`reconstruct_effective_pins/2` supplies it from the **same** `Enum.find`
result it already computes today (`:543`,
`Enum.find(&(&1.event_type == "INSTANCE_STARTED"))`) — no second query, no
second pass over `events`. Today that result feeds only
`extract_pinned_versions/1`; after this change it also feeds the new
`started_event_id` argument, via `started_event.event_id` (bind the found
event to a name once, instead of piping it directly into
`extract_pinned_versions/1` as today). No new call to `Reconstruction`, no
new field read from any event beyond `event_id`, which every event struct
already carries (`reconstruct_effective_pins/2` already reads `.event_id`
for `pins_rebound_events`, `:549`).

**Nilability:** the new parameter's `@spec` type is `Ecto.UUID.t()`, not
`Ecto.UUID.t() | nil` — matching `effective_pin()`'s own non-nilable
`source_event_id` field this parameter exists to seed, which is the whole
point of this decision. This is safe in practice because
`reconstruct_effective_pins/2` only reaches this call inside the
`{:ok, events}` branch where `events` is non-empty (the `{:ok, []}` branch
already short-circuits to `{:error, :instance_not_found}` before this code
runs), and every non-empty instance event stream is structurally guaranteed
to begin with exactly one `INSTANCE_STARTED` event (the sole entry point,
`Letflow.Engine.create/2`). The defensive `nil`-tolerant branch
`extract_pinned_versions(nil)` (`:558`) exists purely for symmetry with that
same theoretical not-found case and is paired at the call site: if
`Enum.find` ever did return `nil` (unreachable under the current invariant,
not newly introduced by this design), `extract_pinned_versions(nil)` yields
`[]` for the base set, so there would be no `pinned_version()` entries left
to seed a `source_event_id` onto in the first place — `merge_effective_pins/3`
would fold an empty base with whatever `started_event_id` it was handed
(harmless either way, since the empty base produces an empty `effective_pin()`
list regardless, and any rebind entries would still append via Decision 3's
new unmatched-entry path, each stamped with its own **rebind event's**
`event_id`, never the missing `started_event_id`). No new `case`/`nil`-branch
is required in `reconstruct_effective_pins/2` beyond binding the found event
to a variable once.

**`engine.ex:633` confirmed unaffected.** Grepped: the only two call sites of
either function in `lib/letflow/engine.ex` are via `reconstruct_effective_pins/2`
at `:633` — `engine.ex` has zero direct calls to `merge_effective_pins`.
`reconstruct_effective_pins/2`'s own arity (`instance_id`, `opts`) is
unchanged by this design (confirmed in the task brief and by this read), so
`engine.ex:633`'s call (`PinResolver.reconstruct_effective_pins(parent_instance_id,
prefix: prefix)`) needs no change of any kind.

## Exact `@spec` changes

```
@type source :: :resolved | :override | :inherited | :rebound
```

(`pinned_version()` and `effective_pin()` types are unchanged themselves —
both already reference `source()`, so widening the shared type widens them
automatically. No field is added or removed from either.)

```
@spec merge_effective_pins(
        instance_started_pinned_versions :: [pinned_version()],
        pins_rebound_events :: [%{event_id: Ecto.UUID.t(), payload: map()}],
        started_event_id :: Ecto.UUID.t()
      ) :: [effective_pin()]
```

(arity 2 → 3; parameter order is the existing two parameters, unchanged,
plus `started_event_id` appended third.)

`apply_rebind_event/2` — **signature unchanged** (still
`apply_rebind_event(%{event_id: event_id, payload: payload}, effective_pins)`,
still private, still the accumulator function `Enum.reduce/3` folds over one
`INSTANCE_PINS_REBOUND` event at a time inside `merge_effective_pins/3`).
Only its internal algorithm changes — see next section.

`reconstruct_effective_pins/2` — **signature unchanged**
(`instance_id :: Ecto.UUID.t(), opts :: [prefix: String.t()]`, same return
type `{:ok, [effective_pin()]} | {:error, :instance_not_found} | {:error, term()}`).
Only its body's call into `merge_effective_pins/3` (new arity) and its one
extra local binding (the found `INSTANCE_STARTED` event, reused for both
`extract_pinned_versions/1` and the new third argument) change.

`normalize_source/1` — **no functional change required.** `:rebound` is
assigned as a literal atom directly inside `apply_rebind_event/2`'s own
logic (see below); it never arrives as a raw string that needs normalizing,
because `PinRebind`'s payload carries no `"source"` key at all — rebind
entries only ever carry `kind`/`ref`/`new_version`
(`pin_rebind.ex:456-459`). `normalize_source/1`'s existing `is_atom/1`
catch-all clause (`:505`) already passes `:rebound` through unchanged if it
were ever handed one. For symmetry with the other three source values (the
issue's own `scoping_note` flags `normalize_source/1` as something that
"would need widening ... with it"), add one additional string clause,
`normalize_source("rebound"), do: :rebound`, purely as defensive
completeness for any future caller that constructs a base pin list from a
string-keyed map — not required by any reachable code path today, and its
absence would not be a bug, but its presence costs one line and keeps the
four `source()` values uniformly handled by this function rather than three
uniformly handled plus one handled only by the generic atom clause.

## Exact algorithm changes

### `merge_effective_pins/3`'s base-seeding step

Today (`:467-477`) seeds every base pin with `source_event_id: nil`
unconditionally. Change: seed every base pin with
`source_event_id: started_event_id` (the new third parameter) instead of
the literal `nil`. No other field of the base-seeding map changes.

### `apply_rebind_event/2`'s fold, per rebind event

Today: for each entry in the event's `entries` list, `Enum.map/2` over the
whole accumulator, updating `version` and `source_event_id` in place on a
match, leaving non-matches (including "no entry anywhere matches this ref")
untouched — with no signal when an entry matched nothing.

New algorithm, per entry within one rebind event's `entries` list:

1. Compute `kind`/`ref`/`new_version` exactly as today (`normalize_kind/1`,
   `entry["ref"] || entry[:ref]`, `entry["new_version"] || entry[:new_version]`).
2. Scan the current accumulator for a pin matching `{kind, ref}` (same
   predicate as today: `pin.kind == kind and pin.ref == ref`).
3. **If a match exists:** replace that pin's `version`, `resolved_id`,
   `source`, and `source_event_id` fields — `version: new_version`,
   `resolved_id: nil` (Decision 2), `source: :rebound` (Decision 1),
   `source_event_id: event_id` (this rebind event's own id, unchanged from
   today's behavior for this field) — leaving `kind` and `ref` untouched,
   and leaving every other pin in the accumulator untouched, in its
   existing position.
4. **If no match exists** (Decision 3): append one new `effective_pin()` to
   the end of the accumulator — `kind: kind, ref: ref, resolved_id: nil,
   version: new_version, source: :rebound, source_event_id: event_id`. This
   newly-appended entry is now part of the accumulator for the *next*
   entry/event processed in the same fold — see Edge Case 2 below for what
   happens when a later event references the same previously-unknown ref.
5. Every entry within the same rebind event's `entries` list is processed
   against the accumulator left by the previous entry (same
   left-to-right, sequential-fold discipline the existing `Enum.reduce/3`
   already uses across entries — no change to that discipline, only to
   what happens per entry).

PROVENANCE (historical, not current decision authority):
The output list is **not re-sorted** after either an in-place update or an
append — same as today (`merge_effective_pins/2` never calls `sort_pins/1`;
that is a `resolve/4`/`apply_inheritance/2`-only step). An appended entry
therefore lands at the end of the effective-pin list, not re-inserted at its
`{kind, ref}`-sorted position. This matches R-Co's own append behavior
(`pin_resolver.zig:143-160`, also a plain append, not a re-sort) and is
called out explicitly here since it is an observable ordering difference
from `resolve/4`'s output for the same instance.

## Edge cases

**1. A pin rebound twice** (two `INSTANCE_PINS_REBOUND` events touching the
same `{kind, ref}`, e.g. `svc-a` rebound in event 1 then again in event 2).
`merge_effective_pins/3`'s outer `Enum.reduce/3` over `pins_rebound_events`
(unchanged — still trusts caller-supplied ascending-`sequence_number` order,
per the existing docstring) applies `apply_rebind_event/2` once per event,
each time re-running the match/update-or-append logic above against the
accumulator left by the previous event. Event 2's entry for `svc-a` matches
the pin event 1 already updated (case 3 above, not case 4 — it is no longer
"unknown" after event 1's update), so it is updated again, in place,
overwriting event 1's `version`/`resolved_id`/`source`/`source_event_id`
with event 2's. **Confirmed:** the final entry reflects the LAST rebind
unconditionally — there is no "already rebound, skip" branch anywhere in
this fold, so a later event's update always wins over an earlier one for
the same ref, matching the existing (unchanged) fold-order guarantee the
moduledoc already documents for `version` alone ("folds ALL rebind events,
in order, not just the most recent") — this design extends that same
already-correct ordering guarantee to `resolved_id`/`source`/
`source_event_id` too, rather than introducing a new one.

**2. An unknown-ref rebind entry reaching the fold** (a payload naming a
`{kind, ref}` absent from the base set — the PIN-05 gate-bypass scenario
Decision 3 covers). Handled by step 4 above: appended once, with
`source: :rebound`, `resolved_id: nil`, `source_event_id` set to that
event's id. If a **second**, later event also references the same
previously-unknown ref, it now matches the entry the first event appended
(step 3, not step 4, on the second pass) and is updated in place exactly as
edge case 1 describes — the append only ever happens once per ref, on the
first event that introduces it; every subsequent reference to that same ref
updates in place like any other rebind.

**3. A rebind event with an empty `entries` payload**
(`payload["entries"] || payload[:entries] || []` evaluating to `[]` —
`PinRebind`'s own docstring confirms this is a legitimate, expected shape:
"`changed_entries` may legitimately be `[]`... exactly one event is always
appended on a successful, valid, in-range rebind call", `pin_rebind.ex:445-447`,
covering the case where every requested entry's version already matched the
current pin). `Enum.reduce/3` over an empty `entries` list returns its
initial accumulator (the effective-pins list as it stood before this event)
completely unchanged — no update, no append, on any pin. **Confirmed
no-op**, unaffected by any of the four decisions above: none of steps 1-4 in
the new per-entry algorithm ever executes when there are zero entries to
iterate, so there is nothing for the new `resolved_id: nil`/`source:
:rebound`/append logic to touch. The pin's `source_event_id` from a *prior*
non-empty rebind event (or from `started_event_id` if never rebound) is
left exactly as that prior fold step left it.

## Repo-wide call-site sweep (not just the two files already read)

Re-grepped the **whole repository** for `merge_effective_pins` (not scoped
to `lib/letflow/engine/` or `test/letflow/engine/`) specifically to close
this gap after CODE-DESIGN-VALIDATOR's rework request. Full result set,
categorized:

- **Production call sites:** exactly one — `pin_resolver.ex:551`, inside
  `reconstruct_effective_pins/2` itself (the call this design already
  updates to arity 3 as part of Decision 4; not a separate break, it's the
  implementation).
- **Test call sites:** exactly four, across exactly two files —
  `test/letflow/engine/pin_resolver_test.exs:442,470,523` (already covered
  below) **and** `test/letflow/engine/pin_rebind_test.exs:483` (missed in
  the first pass of this design; added below). No other test file under
  `test/` calls `merge_effective_pins`.
- **Prose-only references, not call sites** (no code change needed, appear
  only as function-name mentions in comments/docs/moduledocs/handoff
  records): `docs/requirements.yaml:3182,3240`,
  `docs/status/requirement_status.yaml:5158`,
  `docs/migration/stage-3-instance-engine.md:106`,
  `test/letflow/engine_test.exs:937` (a comment listing pure functions,
  not a call), `test/letflow/engine/pin_resolver_test.exs:8,387,389,394,
  397,401,404,407,426,429` (moduledoc/describe-block prose and a
  `String.split` on the literal text `"def merge_effective_pins("` for an
  unrelated structural test — not a call to the function), `pin_resolver.ex`'s
  own moduledoc lines (`78,88,132,194,520,566` — prose, already addressed by
  this design's body text), `pin_rebind.ex:41` (moduledoc prose, addressed
  in "Scope confirmation" below), `test/specs/REQ-060.md:74,156`,
  `test/specs/REQ-059.md:209,222,223`, `lib/letflow/design/req060-pin-rebind.md`
  and `lib/letflow/design/req059-pin-resolver.md` (multiple lines, prior
  design docs' own prose, not touched by this design), and several
  `handoffs/WF02-REQ059-20260819/*.json` / `handoffs/WF02-REQ060-20260819/*.json`
  historical run records (immutable audit trail, never edited).

No call site exists anywhere in the repo beyond the five (one production,
four test) enumerated above.

## Exactly which existing tests break, and why (for TEST-DESIGNER)

**Four** existing call sites break — three in
`test/letflow/engine/pin_resolver_test.exs`, one in
`test/letflow/engine/pin_rebind_test.exs` — all currently at arity 2. After
this change the function is arity 3, so **all four fail to compile**
(`UndefinedFunctionError`/mismatched-arity call) until updated to pass a
third argument:

- **`:442`** — `PinResolver.merge_effective_pins(base, [])`. Needs a third
  argument (any `Ecto.UUID.t()`, e.g. `Ecto.UUID.generate()`, since this
  test asserts nothing about `source_event_id`). The test's existing
  assertion (`:441`, pattern match on `kind`/`ref`/`version`/`source` only,
  not `source_event_id`) does **not** need to change beyond the call itself
  — it happens to not assert the field this design changes for this case.
  A **new** test should be added asserting `source_event_id` now equals the
  passed-in `started_event_id` for an un-rebound pin (this is the direct
  regression coverage for Decision 4 / the issue's core complaint that this
  field was permanently `nil`).

PROVENANCE (historical, not current decision authority):
- **`:470`** — `PinResolver.merge_effective_pins(base, rebind_events)`.
  Needs a third argument (same as above). Its assertion at `:472-477`
  **genuinely breaks on content, not just arity**: it currently asserts
  `resolved_id: "sid"` (the pre-rebind value) survives the rebind
  unchanged. Under Decision 2 this must become `resolved_id: nil`. The
  `version`/`source_event_id`/`kind` assertions on the same pattern are
  unaffected by this design (still `version: "2.0.0"`,
  `source_event_id: ^rebind_event_id`, `kind: :catalog_entry`). The test
  currently makes **no assertion on `source`** for the rebound pin — a new
  assertion (`source: :rebound`) should be added here as direct coverage
  for Decision 1; this is the exact shape of R-Co's own portable regression
  test the issue's `scoping_note` names (`pin_resolver.zig:898-914`, seed
  `:resolved`, fold one rebind, assert the source flipped) — here asserting
  `:rebound` instead of R-Co's `:override`, per Decision 1.

- **`:523`** — `PinResolver.merge_effective_pins(base, rebind_events)`.
  Needs a third argument only; its assertions (`:528-529`) check `version`
  only, for two independently-rebound refs, and are unaffected in content
  by any of the four decisions.

- **`test/letflow/engine/pin_rebind_test.exs:483`** —
  `PinResolver.merge_effective_pins(started_payload["pinned_versions"], pins_rebound)`,
  inside `describe "AC5 -- effective pin set reflects new versions;
  reconstruction derives it from the log alone"` (`:435`), test `"the same
  effective set is independently reproducible from INSTANCE_STARTED +
  INSTANCE_PINS_REBOUND alone"` (`:457-489`). **Not a purely mechanical
  arity fix** — this design states the required change explicitly rather
  than leaving it for TEST-DESIGNER to invent:

  This test hand-builds the effective set from raw event data
  (`merge_effective_pins`) and separately calls `reconstruct_effective_pins/2`
  (which goes through the real, updated code path), then asserts
  `hand_merged == via_reconstruct` (`:488`) — a cross-check that the two
  computations agree. Today, `started_payload` is extracted at `:472-475` as
  **only** the `INSTANCE_STARTED` event's `payload` map (`Map.fetch!(:payload)`
  discards everything else about that event, including its `event_id`). Once
  `source_event_id` is populated from `started_event_id` on every base-seeded
  pin (Decision 4), `via_reconstruct`'s pins will carry that instance's real
  `INSTANCE_STARTED` event id as `source_event_id` — so for `hand_merged` to
  still equal `via_reconstruct`, `hand_merged` must be built with that same
  id, not a placeholder or an omitted third argument.

  **Required change:** at `:472-475`, extract the *entire* found event (not
  just its `:payload`) — bind it to a name (e.g. `started_event`) — and read
  both `started_event.payload["pinned_versions"]` (replacing today's
  `started_payload["pinned_versions"]`) and `started_event.event_id` from
  that one binding. Pass `started_event.event_id` as `merge_effective_pins/3`'s
  new third argument at `:482-483`. With that change, `hand_merged`'s base
  pins are seeded with the exact same `started_event_id` value
  `reconstruct_effective_pins/2` independently derives from the same event
  inside its own body (both sides read `event_id` off the identical
  `INSTANCE_STARTED` row fetched by the identical `Enum.find(&(&1.event_type
  == "INSTANCE_STARTED"))` predicate — `read_events/2`, this test's own
  helper, and `Reconstruction.read_full_log/3`, `reconstruct_effective_pins/2`'s
  source, both read the same underlying event log for the same
  `instance.instance_id`), so the equality assertion at `:488` continues to
  hold with no change to the assertion itself — only to how `hand_merged` is
  computed. No other line in this test changes.

**New tests to add** (not modifications — genuinely new coverage this
design introduces obligations for): an unknown-ref rebind entry appended
per Decision 3 (assert the appended entry's `kind`/`ref`/`version`/
`resolved_id: nil`/`source: :rebound`/`source_event_id`, and that the
original base entries are untouched); the twice-rebound-same-ref case
(Edge Case 1, asserting the final entry reflects the second event, not the
first, across all four provenance fields, not just `version` as today's
`:483-530` test already covers); an empty-`entries` rebind event producing
a byte-for-byte-unchanged accumulator (Edge Case 3). `reconstruct_effective_pins/2`
has no direct unit test asserting `source_event_id` is non-nil for a
never-rebound instance today (confirmed by this design's read of the test
file's `merge_effective_pins/2` describe block, `:429-531`) — TEST-DESIGNER
should add one at the `reconstruct_effective_pins/2` level too, not only at
`merge_effective_pins/3`'s, since that is the function whose docstring and
`@spec` this issue says contradicts itself today.

## Scope confirmation — zero functional changes outside `pin_resolver.ex`

Confirmed by this design's own reads, not assumed:

- `Letflow.Engine.PinRebind` (`pin_rebind.ex`) needs **no code change**.
  Its payload shape (`entries: [%{kind, ref, prior_version, new_version}]`,
  `:456-459`) already carries everything this design's fold needs
  (`kind`, `ref`, `new_version`) and nothing this design asks it to add.
  Its call into `PinResolver` is `reconstruct_effective_pins/2` only
  (`:342`), arity unchanged.
- `lib/letflow/engine.ex` needs **no code change**. Its sole call into this
  area is `PinResolver.reconstruct_effective_pins(parent_instance_id,
  prefix: prefix)` at `:633`, arity unchanged, confirmed by grep to be the
  only call site of either function in that file.
- No migration, no `Ecto.Schema` change, no new DB column — this module
  persists nothing of its own (moduledoc, "Persistence"); every field this
  design touches lives only in already-appended event payloads and their
  in-memory fold, never in a new table.
- **One documentation-only note, not a functional change:**
  `pin_rebind.ex`'s own moduledoc (`:38-44`, "`Reconstruction`/`PinResolver`
  reuse — no code change needed there") currently describes
  `merge_effective_pins/2` by name and arity and asserts it "already folds
  correctly" — both statements become stale once this fix ships (arity
  becomes 3; "already folds correctly" was true for `version` only, which
  is exactly what ISS-0078 disputes for the other three fields). Updating
  that comment is recommended for accuracy as part of this fix's PR, but it
  is prose only, changes no behavior, and does not count against "zero
  changes outside `pin_resolver.ex`" in the sense that scoping question is
  actually asking (no other module's *runtime behavior* changes).

## Invariants

- `source()` has exactly four values after this change; `:rebound` is
  produced by exactly one code path (`apply_rebind_event/2`'s per-entry
  match-or-append logic) and never by `resolve/4`, `apply_inheritance/2`,
  or any override path — those remain exactly as they are today (ISS-0079's
  scope, not this design's).
- `resolved_id: nil` after a rebind is not an error state or a "missing
  data" bug to fix later — it is this design's deliberate, permanent
  answer for "a rebind never re-verifies against a catalog," matching the
  field's existing nilable type and existing "no lookup ran" precedent
  (`resolve_variable_schema/3`'s no-override branch).
- `merge_effective_pins/3`'s fold remains pure, zero I/O — no decision here
  adds a lookup call, a `Repo` read, or any dependency on `Lookup.t()`.
  PIN-04 AC7 ("issues zero reads against any catalog or module registry")
  is preserved by construction, same as today.
- Fold order remains caller-supplied (`pins_rebound_events` must arrive
  sorted by ascending `sequence_number` — unchanged contract,
  `reconstruct_effective_pins/2` continues to be the only production
  supplier and continues to build that list via `Enum.filter/2` over
  `read_full_log/3`'s already-ordered result).
- No re-sort of the output list is introduced by the append case (Decision
  3) — an appended entry's position (end of list) is an intentional,
  documented divergence from `resolve/4`'s `{Atom.to_string(kind), ref}`
  ordering, not an oversight.

## Addendum — SECURITY-REVIEWER rework (INV-8)

SECURITY-REVIEWER's first pass flagged `reconstruct_effective_pins/2`'s
`started_event.event_id` access (Decision 4's implementation) as an
unguarded crash on `nil` if `Enum.find` ever failed to locate an
`INSTANCE_STARTED` event in a non-empty stream — the `{:ok, []}` branch
above it only covers the fully-empty case. Fixed by `case`-wrapping the
`Enum.find` result: a `nil` match now returns `{:error, :instance_not_found}`,
matching the existing empty-stream convention, before any field access on
`started_event` is attempted.

This makes the defensive `extract_pinned_versions(nil), do: []` clause this
design originally called out (see Decision 4's "Nilability" paragraph above)
genuinely unreachable — `extract_pinned_versions/1` is now only ever called
inside the branch where `started_event` is non-`nil` — so that clause was
removed as dead code rather than left in place. `Decision 4`'s own
conclusion (`started_event_id`'s `@spec` stays non-nilable `Ecto.UUID.t()`)
is unaffected; this addendum only changes how that invariant is *enforced*
in `reconstruct_effective_pins/2`'s own body, from an implicit assumption to
an explicit guard.

Regression coverage: `test/letflow/engine/pin_rebind_test.exs`'s new
`"reconstruct_effective_pins/2 returns {:error, :instance_not_found} for a
non-empty event stream with no INSTANCE_STARTED"` test constructs the
malformed stream by inserting directly through
`Letflow.EventStore.Event.insert_changeset/2` + `Repo.insert/2`, bypassing
`EventStore.append/2`'s own (pre-existing, independently discovered)
`:instance_not_started` guard — confirming this scenario is unreachable
through any real writer, and that the new case-guard is defense-in-depth on
the read path regardless.

## Open questions

None. All four items the issue's `scoping_note` requires this design to
settle have a made, justified decision above (`:rebound` as a new value;
`resolved_id: nil` on rebind; append on unknown-ref; `started_event_id`
threaded as `merge_effective_pins/3`'s new third parameter). The one
adjacent finding this design surfaced on its own — `pin_rebind.ex`'s
moduledoc going stale — is recorded above as a recommended documentation
fix, not left as an unresolved question blocking implementation.
