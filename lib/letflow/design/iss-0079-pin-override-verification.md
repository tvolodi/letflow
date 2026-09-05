# ISS-0079: verify `pin_overrides` against the injected `Lookup` instead of trusting them verbatim (GH#298)

## Problem (restated from the issue, design scope only)

`PinResolver.resolve/4`'s override path (`resolve_one_ref/4`, `resolve_variable_schema/3`)
takes a caller-supplied `override_entry()` — `kind`, `ref`, `resolved_id`, `version` — and
writes it into the resulting `pinned_version()` **verbatim**, `source: :override`, with
**no call to `lookup.catalog_lookup`/`lookup.module_lookup`/`lookup.variable_schema_lookup`
for that ref at all**. A caller may assert any `resolved_id`/`version` string, including
ones naming nothing that exists, and it is written into `INSTANCE_STARTED`'s payload as an
authoritative pin. Because pins are immutable after `INSTANCE_STARTED` (except via
`PinRebind`) and `pin_for/3` is "no fallback, ever" (PIN-03 AC1/AC5), an unverified override
poisons every later execution-time lookup for that instance's whole lifetime.

PROVENANCE (historical, not current decision authority):
R-Co does not do this (`R-Co/src/engine/pin_resolver.zig`, read directly this session,
line numbers below). Verified independently rather than trusted from the issue text, per
its own instruction to do so.

## What R-Co actually does — verified directly, and it is narrower than "override" suggests

PROVENANCE (historical, not current decision authority):
`applyPinOverrides` (`pin_resolver.zig:602-691`), called as Step 5, after Steps 2-4 have
already unconditionally resolved every real graph reference via the normal catalog/registry
lookup (`:254-290`, unconditional — an override does **not** skip the base resolution):

- The override wire format is `{kind, ref, version}` — **no `resolved_id` field exists on
  the wire** (`:206`, `ResolutionInput.pin_overrides: ?[]const u8`, confirmed by
  `applyPinOverrides`'s own parse: `jsonStringField(obj, "kind"/"ref"/"version")`, nothing
  else read from the object).
- For each override, R-Co calls the **same lookup function** used for normal resolution
  (`resolveServiceCatalogRef`/`resolveVariableSchemaVersion`, fresh, not reusing Step 2/3's
  result) and requires the override's `version` to **equal** the just-obtained current
  version (`:659-661`, `:681-683`) — else `UnresolvedPinOverride`.
- The override's `resolved_id`/`version` are **never used**; `applyOverrideToPins` writes
  the **freshly-looked-up** `resolved_id`/`version` onto the matching pin (`:719`), not
  anything the caller supplied (there is nothing to supply — the wire format has no such
  field).
- `kind: module` is rejected unconditionally (`:642`) — but only because `resolveModuleRef`
  doesn't exist in R-Co at all (PLC-01 unscoped); there is no principled "modules can't be
  overridden" rule, only "nothing can verify a module override because nothing can resolve
  a module at all."
- An override naming a `{kind, ref}` absent from the pins Step 2/3 already built is an
  **error**, not a no-op — `applyOverrideToPins` returns `false` when no matching pin exists
  (`:707-723`), and both call sites turn that into `UnresolvedPinOverride`.
- Because Step 2/3 (unconditional base resolution) runs **before** Step 5, a ref that fails
  to resolve at all reports `UnresolvedCatalogRef`/`UnresolvedModuleRef`, never
  `UnresolvedPinOverride`, even when an override was supplied for it — base-resolvability
  is checked first, override-verification second.

**The consequence for what "override" means:** this is not a mechanism to *force* an
arbitrary alternate version. Verification requires the override's `version` to equal
whatever the lookup would have produced *without* the override. Functionally, `pin_overrides`
lets a caller **assert** "I expect ref X to currently resolve to version Y, and I want
instance creation to fail loudly (422) rather than silently proceed if that expectation is
stale" — an optimistic-concurrency guard against a caller and the live catalog having
drifted, not a substitution mechanism. A resulting `:override` pin is byte-identical to what
a `:resolved` pin for the same ref would have been; only the `source` tag and the
fail-loudly-if-wrong behavior differ.

## Decision 1 — yes, verify every override against the injected `Lookup`

Adopt R-Co's semantic: an override's `version` must match what `lookup.catalog_lookup`/
`lookup.module_lookup`/`lookup.variable_schema_lookup` currently reports for that ref, or
resolution fails. `resolved_id`/`version` in the resulting pin come from the **lookup**,
never from the caller.

The scoping note's own worry — "does this make `resolve/4` non-pure in a way §4.1's 'no
lookup call at all' was specifically written to avoid?" — doesn't survive inspection.
`resolve/4` was never pure in the no-I/O sense: it already calls `lookup.catalog_lookup`/
`lookup.module_lookup`/`lookup.variable_schema_lookup` for every **non**-overridden ref
today. Those are the same injected functions this decision extends to overridden refs too.
"Pure" here has only ever meant "no hardcoded I/O, parameterized via an injected `Lookup`" —
identical to `Letflow.Definitions.ServiceScopeValidator`'s own `Lookup` pattern this module
already cites as precedent. Extending an existing call pattern to a code path that
previously skipped it introduces no new impurity category. §4.1's "no lookup call at all"
was written before R-Co's source was readable (moduledoc's own SOURCING note) and encoded
an assumption, not a purity boundary — and the assumption was wrong.

**Efficiency choice, not a behavior choice:** R-Co calls the lookup **twice** for a ref that
has both a base resolution (Step 2/3) and an override (Step 5) — once unconditionally, once
again inside `applyPinOverrides`, always returning the same value absent a concurrent
catalog change mid-resolution (not a scenario this module's own transaction boundary
permits — pin resolution runs entirely before `create_snapshot/3`'s first write). This
design calls the lookup **once** per ref regardless of whether an override exists,
collapsing R-Co's redundant two-phase structure (unconditional-resolve-then-separately-
reverify) into one pass, while preserving every externally observable outcome R-Co produces,
including the ordering edge case below. This is a deliberate implementation efficiency, not
a divergence in what any caller can observe.

**Preserved edge case (matters for ordering):** because R-Co's Step 2/3 (unconditional base
resolution) runs strictly before Step 5 (override verification), a ref that cannot resolve
at all reports `{:unresolved_catalog_ref, ref}` / `{:unresolved_module_ref, ref}`, **not**
`{:unresolved_pin_override, ref}`, even when an override was supplied for that exact ref.
This design's single-lookup-per-ref structure preserves that precedence naturally: the
`{:error, :not_found}` branch is checked before the override-match branch (see "Exact
algorithm changes" below), so an unresolvable ref never reaches override verification at
all, matching R-Co's observable ordering with no extra bookkeeping required to get there.

## Decision 2 — `resolve_error()` gains `{:unresolved_pin_override, ref}`; `Engine.create_error()` mirrors it

R-Co's `UnresolvedPinOverride` is a bare error code carrying no ref. Every existing member
of `resolve_error()` — `unresolved_catalog_ref`, `unresolved_module_ref` — carries the
offending `ref` for debuggability. This design follows Letflow's own established
convention over R-Co's terser one: `{:error, {:unresolved_pin_override, ref :: String.t()}}`.

No further sub-classification (version-mismatch vs. stray-ref vs. module-kind-unverifiable)
is added — R-Co itself collapses all override-verification failures into the one code, and
a caller's actionable response is identical in every case ("your override didn't hold;
re-check your assumptions and retry"). Distinguishing them would be new information R-Co's
own HTTP 422 contract doesn't provide either.

`Letflow.Engine.create_error()` (`engine.ex:387-388`, sitting directly beside the
`unresolved_catalog_ref`/`unresolved_module_ref` members it already mirrors from
`resolve_error()`) gains the same member. No code change is needed in `start_instance/5`
beyond the type declaration — the `with` chain already propagates any `PinResolver.resolve/4`
error tuple straight through to `create/2`'s own return, exactly as it does today for the
two existing variants.

## Decision 3 — `kind: :module` remains a legal override; no special-case rejection

R-Co rejects every `kind: module` override unconditionally, but its own comment says why:
"a module override can never verify" (`:642`) — because `resolveModuleRef` doesn't exist in
R-Co at all (PLC-01 unscoped, confirmed absent from R-Co's own source tree). That is R-Co's
own build-scope limitation, not a principled rule about what a module override *should*
mean. The scoping note flags exactly this: "match R-Co exactly" is not automatically correct
here, and copying the special case would mean copying a stopgap forever, even after a real
`module_lookup` exists.

Letflow's `Lookup.module_lookup` is already a real injectable field (`Lookup` struct,
`pin_resolver.ex:226-251`) — unlike R-Co, it structurally **can** succeed once a real
implementation is supplied (a test double today; a real PLC-01-equivalent catalog whenever
one is built). Verifying `kind: module` overrides uniformly against `lookup.module_lookup`,
exactly like `kind: catalog_entry` against `lookup.catalog_lookup`, is the principled
generalization — no special case, and it degrades correctly today: `default_lookup/0`'s
`module_lookup` always returns `{:error, :not_found}`, so under the shipped default a module
ref (override or not) already fails with `{:unresolved_module_ref, ref}` before override
verification is ever reached (Decision 1's preserved edge case) — the exact same outcome
R-Co's special case produces, arrived at without needing the special case at all, and
correctly extensible the moment a real `module_lookup` exists.

## Decision 4 — a stray override ref is an error, not a no-op

R-Co: an override naming a `{kind, ref}` the graph doesn't reference is `UnresolvedPinOverride`
(`applyOverrideToPins` returns `false`, `:707-723`). This design adopts the same rule,
independently justified rather than merely inherited: silently ignoring a caller's override
would mask a caller's own mistake (a typo'd `ref`, a stale override left over from a graph
edit) behind an instance that starts successfully but silently did **not** get the pin the
caller believed it asked for — the same "trusted but not actually enforced" harm the issue's
own framing names for the unverified case. Fail-closed on caller-input mismatch matches this
codebase's consistent posture elsewhere (`VariableSchema`'s fail-closed prefix/definition_id
guards; PIN-03's own "no fallback, ever").

**Detection, adapted to this design's single-pass-per-ref structure (no incremental
tracking needed):** after every real ref resolves successfully and the full `pins` list is
built, check each entry in the caller-supplied `overrides` list — in the order given — for
whether its `{kind, ref}` matches some pin in that list. The first override whose pair
matches nothing is the stray; `{:error, {:unresolved_pin_override, ref}}`. This is
equivalent to R-Co's own check (`applyOverrideToPins` searching the Step-2/3-built `pins`
for a match) without needing R-Co's own per-override loop structure — the built `pins` list
*is* the complete real-ref set by the time this check runs, exactly as it is in R-Co by the
time Step 5 runs.

**Ordering note (deliberate, not assumed to match R-Co byte-for-byte):** R-Co processes
overrides in the caller's given list order as a single outer loop, so a version-mismatch on
one override and a stray ref on another could report either first depending on their
position in that one list. This design resolves every real ref first (catalog before module
before variable_schema, matching `resolve/4`'s existing sequencing and R-Co's own Step-2-
then-Step-3 node-type ordering) and only checks for stray overrides afterward, so a real
ref's resolution or override-verification failure always reports before any stray-ref
failure, regardless of the two errors' relative position in the caller's override list. This
project's own precedent for exactly this kind of judgment call is
`req049-variable-merge.md` §3.3 ("First-failure-wins ordering — a design decision, stated
explicitly," choosing determinism over literal R-Co iteration-order parity) — the same
reasoning applies here: both outcomes are a 422 either way, and no caller-visible contract
depends on which specific failure is named first when multiple exist simultaneously.

## A consequence of Decision 1, not separately numbered: `override_entry()` drops `resolved_id`

R-Co's override wire format is `{kind, ref, version}` — no `resolved_id`. Once overrides are
verified rather than trusted, a caller-supplied `resolved_id` is never read for anything;
keeping it in the type would be exactly the "a field that looks load-bearing but isn't"
anti-pattern this codebase flags elsewhere (`docs/anti-patterns.md`'s general theme, and the
concrete precedent this session's own GH#310 fix addressed in
`InstanceProjection.definition_id`'s typing). `override_entry()` becomes:

```elixir
@type override_entry :: %{kind: :catalog_entry | :module | :variable_schema, ref: String.t(), version: String.t()}
```

matching R-Co's actual wire shape exactly.

## Exact `@spec` changes

`pin_resolver.ex`:

```elixir
@type override_entry :: %{kind: :catalog_entry | :module | :variable_schema, ref: String.t(), version: String.t()}
# was: %{kind: ..., ref: String.t(), resolved_id: String.t() | nil, version: String.t()}

@type resolve_error ::
        {:error, {:unresolved_catalog_ref, ref :: String.t()}}
        | {:error, {:unresolved_module_ref, ref :: String.t()}}
        | {:error, {:unresolved_pin_override, ref :: String.t()}}  # NEW
        | {:error, {:graph_structure_invalid, term()}}
```

`engine.ex`, `create_error()`:

```elixir
| {:error, {:unresolved_catalog_ref, ref :: String.t()}}
| {:error, {:unresolved_module_ref, ref :: String.t()}}
| {:error, {:unresolved_pin_override, ref :: String.t()}}  # NEW, sits beside the two above
```

## Exact algorithm changes

`resolve_refs/4` (renamed conceptually, signature widened to also carry `kind`'s lookup
error atom and to check overrides — the existing `resolve_one_ref/4` per-ref branch is
where this actually changes):

```
resolve_one_ref(ref, kind, lookup_fun, overrides):
  case lookup_fun.(ref) do
    {:error, :not_found} ->
      # unresolvable takes precedence over any override for this ref (R-Co's
      # Step-2/3-before-Step-5 ordering, preserved without a second lookup)
      {:error, {unresolved_error_for(kind), ref}}

    {:ok, %{resolved_id: resolved_id, version: current_version}} ->
      case find_override(overrides, kind, ref) do
        nil ->
          {:ok, %{kind: kind, ref: ref, resolved_id: resolved_id, version: current_version, source: :resolved}}

        %{version: ^current_version} ->
          # matches -- pin the FRESH lookup values, not the caller's
          {:ok, %{kind: kind, ref: ref, resolved_id: resolved_id, version: current_version, source: :override}}

        %{version: _mismatched} ->
          {:error, {:unresolved_pin_override, ref}}
      end
  end
```

`resolve_variable_schema/3` — same shape, minus the not-found branch (`variable_schema_lookup`
is total by design, §4.2): always call the lookup, then either `:resolved` (no override),
`:override` (version matches), or `{:unresolved_pin_override, ref}` (version doesn't match).
`resolved_id` stays `nil` in both the `:resolved` and `:override` branches, unchanged from
today's `:resolved` branch — `variable_schema_lookup_result` carries no `resolved_id` field
at all (`Lookup.variable_schema_lookup_result :: {:ok, %{version: ..., json_schema: ...}}`),
so there is nothing to use even in the `:override` branch.

`resolve/4` — after building `catalog_pins ++ module_pins ++ [variable_schema_pin]` and
before `sort_pins/1`, one new step:

```
with :ok <- check_no_stray_overrides(pins, overrides) do
  {:ok, sort_pins(pins), json_schema}
end
```

```
check_no_stray_overrides(pins, overrides):
  stray = Enum.find(overrides, fn override ->
    not Enum.any?(pins, &(&1.kind == override.kind and &1.ref == override.ref))
  end)

  case stray do
    nil -> :ok
    %{ref: ref} -> {:error, {:unresolved_pin_override, ref}}
  end
```

## Edge cases

- **Empty `overrides`** (the overwhelming existing case, `[]` default): `find_override`
  always returns `nil`, `check_no_stray_overrides` always finds nothing to flag —
  behavior is **byte-for-byte identical** to today for every caller not using overrides at
  all. This is the load-bearing backward-compatibility guarantee: this fix changes nothing
  observable for `create/2`'s only currently-exercised call shape (`pin_overrides` is not
  wired to any HTTP route yet — confirmed by repo-wide grep, zero references in
  `lib/letflow_web/`).
- **Override matches, version correct:** pin is identical in value to what `:resolved` would
  have produced; only `source` differs. Matches R-Co's own observed shape exactly.
- **Override on an unresolvable ref:** `{:unresolved_catalog_ref/module_ref, ref}`, not
  `:unresolved_pin_override` — Decision 1's preserved edge case.
- **Override version mismatch on a resolvable ref:** `{:unresolved_pin_override, ref}`.
- **`kind: module` override under `default_lookup/0`:** `{:unresolved_module_ref, ref}` (the
  unresolvable-ref branch fires first) — Decision 3's "no special case needed" claim,
  confirmed by construction.
- **Stray override (ref not enumerated by the graph at all, any kind):**
  `{:unresolved_pin_override, ref}`, reported only after every real ref has already resolved
  successfully.
- **Two simultaneous problems** (e.g., one real ref's version mismatches its override, and a
  separate stray override also exists): the real ref's failure is reported; the stray check
  never runs (the `with` chain halts at the first `{:error, _}`). Decision 4's ordering note.
- **`variable_schema` override naming the wrong `ref`** (i.e., not `definition.name`): this
  IS the stray-ref case for `variable_schema` — `resolve_variable_schema/3` only ever looks
  for an override whose `ref == process_key`, so a mismatched `ref` is simply never matched
  there, and `check_no_stray_overrides` catches it exactly as it would for a stray
  catalog/module ref, since the single always-present `variable_schema` pin is part of the
  `pins` list that check scans.

## Repo-wide call-site sweep

Grepped `PinResolver\.resolve|override_entry|PinResolver\.Lookup|find_override` across
`lib/` and `test/` this session. Real hits: `pin_resolver.ex` (this fix), `engine.ex`
(`create_error()` mirror only — `start_instance/5`'s call site and `with` chain need no
change), `pin_resolver_test.exs`, `test/specs/REQ-059.md`. `engine_test.exs` references
`PinResolver.default_lookup/0`/`reconstruct_effective_pins/3` only, neither touched by this
fix. `req062-sub-process-runtime.md` does not mention overrides at all. Two other test files
(`service_scope_validator_test.exs`, `lua_script_audit_test.exs`) matched only on the
generic word "Lookup"/"find_override" from unrelated modules — confirmed by direct read, not
PinResolver-related. `pin_overrides` has **zero** references under `lib/letflow_web/` — not
wired to any HTTP route yet, which is why the "Edge cases" backward-compatibility argument
above is airtight for every currently-shipped caller.

## Exactly which existing tests break, and why

`test/letflow/engine/pin_resolver_test.exs`, describe block **"resolve/4 -- overrides
substitute for the lookup, no lookup call at all for an overridden ref"** — its own name is
the premise being fixed. The test uses `raise_if_called_lookup()` and asserts the override's
own `resolved_id`/`version` land verbatim; both assertions are now false by design. Replaced
with a describe block asserting: (a) a verified override (lookup does get called, version
matches) lands with the lookup's own `resolved_id`/`version`, `source: :override`; (b) a
version-mismatched override returns `{:error, {:unresolved_pin_override, ref}}`; (c) a
stray-ref override (not in the graph at all) returns the same; (d) a `kind: module` override
that verifies successfully (real `module_lookup` supplied) lands as `:override`, proving
Decision 3 by construction rather than by absence of a special case.

`test/specs/REQ-059.md` line 65's "A matching override is used verbatim" claim is corrected
to describe verification.

No other test in `pin_resolver_test.exs` constructs an override with a mismatched version or
a stray ref today, so no other test's assertions change — confirmed by reading every
`overrides =` / `pin_overrides:` fixture in the file (the inheritance-related fixture at
the file's PIN-04 section builds an override whose version already matches its own
`const_lookup` stub, so it continues to verify successfully and is unaffected).

## Scope confirmation — zero functional changes outside `pin_resolver.ex`/`engine.ex`

`merge_effective_pins/3`, `reconstruct_effective_pins/2`, `apply_inheritance/2`, `pin_for/3`
— untouched. `pin_rebind.ex` — untouched (ISS-0078 already settled `:rebound` as a value
distinct from `:override`; this fix does not touch rebind at all). No migration, no new
`Ecto.Schema`, no web-layer change (nothing to change — `pin_overrides` isn't wired there).

## Invariants

- **INV-PO-1 (no trust without verification):** every `pinned_version()` entry with
  `source: :override` carries a `resolved_id`/`version` that was independently confirmed
  against `Lookup` in the same `resolve/4` call that produced it — never a caller-supplied
  value written through unchecked.
- **INV-PO-2 (fail-closed on caller-input mismatch):** an override that cannot be verified —
  wrong version, or naming a ref the graph does not reference — aborts resolution entirely,
  with no partial pin set, matching PIN-01 AC1/AC4's existing "no partial list on any error"
  guarantee (already true for `unresolved_catalog_ref`/`unresolved_module_ref`; now equally
  true for `unresolved_pin_override`).
- **INV-PO-3 (empty overrides is a true no-op):** `overrides == []` produces byte-identical
  output to this fix's predecessor, for every currently-shipped caller.

## Open questions this design does not resolve

- Adjacent deltas (a) dedup via `Enum.uniq()` and (b) sort-key `Atom.to_string/1` vs.
  R-Co's `@intFromEnum`, both recorded in `ISS-0079.yaml`'s description, are **not**
  addressed here — the issue's own scoping note says these need separate dispositioning,
  and neither is the override-verification mechanism this design fixes. Left for a future
  pass; not filed as their own GH issues by this fix (a judgment call beyond what resolving
  #298 itself calls for).
- Whichever future work wires `pin_overrides` to an actual HTTP route inherits
  `{:unresolved_pin_override, ref}` as an existing `create_error()` member and should map it
  to HTTP 422, matching R-Co's own `UnresolvedPinOverride` contract and this module's other
  two `unresolved_*` variants' eventual treatment — not decided here, since no route exists
  yet to decide it for.
