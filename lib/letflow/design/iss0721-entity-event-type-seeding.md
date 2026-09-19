# Design: ISS-0721 — wire `Entities.EventTypes.seed!/1` into tenant provisioning

## 0. Sources read for this design

- `handoffs/WF03-ISS0721-20260919/step-01-issue-fixer-diagnosis.json` —
  `result.summary` in full. This design does not re-derive the root cause;
  it takes ISSUE-FIXER's diagnosis as given and covers only the fix shape.
- `lib/letflow/entities/event_types.ex` — `seed!/1` (`@spec` at line 116,
  body at 117-140), its moduledoc's idempotency statement (lines 101-115),
  `seed_result()` type (line 99).
- `lib/letflow/tenant_provisioning.ex` — `replay_migrations/2` (lines
  365-394, the `with`-chain at line 390), `maybe_seed_platform_event_types/2`
  (lines 1074-1084, the ISS-0072 precedent this design mirrors), and
  `tenant_id_for_schema_name/1`'s `@doc` (confirms `schema_name` round-trips
  to `tenant_id`, per ISSUE-FIXER's diagnosis).
- `lib/letflow/design/req228-entity-event-registration-commands.md` and
  `lib/letflow/design/iss072-event-type-registration.md` — prior design
  precedent for this exact seed-list-plus-wiring shape.

## 1. Root cause (as established by ISSUE-FIXER — not re-derived here)

`Letflow.Entities.EventTypes.seed!/1` (REQ-228) registers the three
`ENTITY_RECORD_*` event types but has **zero production call sites** —
every call site outside `event_types.ex` itself is a test fixture. A
freshly-provisioned tenant's `event_type_registry` table therefore has no
rows for `ENTITY_RECORD_CREATED/UPDATED/DELETED`, so the first entity-record
write 500s via `EventStore.Registry.validate_payload/3` →
`{:error, :unknown_event_type}`. This is a distinct instance of the same
*class* of gap ISS-0072 fixed for the engine's own event types (via
`maybe_seed_platform_event_types/2`), not a recurrence of ISS-0072's own
root cause — the two seed lists are separate and this one was simply never
wired at all.

## 2. New function: name, signature, placement

Add a new private function to `lib/letflow/tenant_provisioning.ex`,
immediately after `maybe_seed_platform_event_types/2` (i.e. directly below
line 1084, inside the same private-helpers region, so the two ISS-0072/
ISS-0721 seed wrappers stay visually paired for future readers):

```
@spec maybe_seed_entity_event_types(using_default_manifest? :: boolean(), schema_name :: String.t()) ::
        :ok | {:error, {:event_type_seed_failed, term()}}
```

Two clauses, mirroring `maybe_seed_platform_event_types/2`'s own
false/true split exactly:

- `maybe_seed_entity_event_types(false, _schema_name)` → `:ok` (no-op when
  the caller supplied a custom `migration_source`, same gating rationale as
  the platform seed: a partial/custom migration list may not even have
  applied the `event_type_registry` table's DDL yet).
- `maybe_seed_entity_event_types(true, schema_name)` → calls
  `Letflow.Entities.EventTypes.seed!(schema_name)` and normalizes its
  return per §3 below.

**Argument is `schema_name`, not `tenant_id`** — this is the one place this
new function's shape *differs* from its sibling `maybe_seed_platform_event_types/2`
(which takes `tenant_id`, because it calls `Registry.register_type/2`
directly). `EventTypes.seed!/1`'s own `@spec` takes `prefix :: String.t()`
and internally round-trips it back to a `tenant_id` via
`tenant_id_for_schema_name/1`. `replay_migrations/2` already has
`schema_name` bound in its own `%Registration{schema_name: schema_name}`
clause (line 376) and already passes that same `schema_name` value as
`Ecto.Migrator.run/4`'s `prefix:` option (line 384) — no new value needs to
be threaded in or derived; the call site (§4) passes that existing binding
straight through.

## 3. Return-shape normalization

`EventTypes.seed!/1` returns `{:ok, seed_result()} | {:error, term()}`
(`seed_result() :: %{registered: [Registry.EventType.t()], skipped: [String.t()]}`).
`maybe_seed_entity_event_types/2` must normalize this to match
`maybe_seed_platform_event_types/2`'s own `:ok | {:error, {:event_type_seed_failed, reason}}`
contract, so the two calls compose identically inside the same `with`-chain:

| `seed!/1` returns | `maybe_seed_entity_event_types/2` returns |
|---|---|
| `{:ok, _seed_result}` | `:ok` (the `seed_result()` map — `registered`/`skipped` lists — is discarded, same as `maybe_seed_platform_event_types/2` discards `register_type/2`'s `{:ok, event_type}`) |
| `{:error, reason}` | `{:error, {:event_type_seed_failed, reason}}` |

No `case`/`with` branch needs to special-case
`{:error, :duplicate_event_type_version}` here — see §4.

## 4. Idempotency on repeat provisioning/migration

`EventTypes.seed!/1` **already tolerates duplicates internally** (confirmed
by reading its body, event_types.ex:117-140, and its moduledoc,
lines 106-114): each of the three `Registry.register_type/2` calls that
returns `{:error, :duplicate_event_type_version}` is caught inside its own
`Enum.reduce_while/3` and folded into the `skipped` list rather than halting
or erroring — the overall call still returns `{:ok, seed_result()}` with
that event type's name in `skipped`. This is the exact same idempotency
guarantee `maybe_seed_platform_event_types/2` gets by explicitly matching
`{:error, :duplicate_event_type_version} -> {:cont, :ok}` itself — the
difference is *where* the tolerance lives (inside `seed!/1` for this call,
inline in the caller for the platform seed), not whether it exists.

**Conclusion: no extra idempotency handling is needed in
`maybe_seed_entity_event_types/2`.** A second `replay_migrations/2` call
against an already-seeded tenant schema re-invokes `seed!/1`, which re-hits
`{:error, :duplicate_event_type_version}` for all three event types
internally, still returns `{:ok, %{registered: [], skipped: [...]}}`, which
§3's mapping turns into `:ok` — the with-chain proceeds exactly as on first
call. This must be stated as a design decision (not left implicit) because
it is the one place this fix's behavior legitimately differs from copying
`maybe_seed_platform_event_types/2`'s pattern verbatim: no duplicate-atom
match arm is needed or written here, since `seed!/1` already absorbs it one
layer down.

## 5. `with`-chain change in `replay_migrations/2`

Current (tenant_provisioning.ex:390-392):

```
with :ok <- maybe_seed_platform_event_types(using_default_manifest?, tenant_id) do
  {:ok, applied_versions}
end
```

New:

```
with :ok <- maybe_seed_platform_event_types(using_default_manifest?, tenant_id),
     :ok <- maybe_seed_entity_event_types(using_default_manifest?, schema_name) do
  {:ok, applied_versions}
end
```

Notes on this change:

- Both clauses run inside the same `try` that already wraps
  `Ecto.Migrator.run/4` (lines 380-393), so an unexpected exception from
  either seed call is still caught by the existing `rescue exception ->
  {:error, {:migration_failed, exception}}` clause — no new rescue path is
  introduced.
- Order: `maybe_seed_platform_event_types/2` first (existing behavior,
  unchanged position), `maybe_seed_entity_event_types/2` second. The two
  seed lists are independent (different event type names, no shared state
  or ordering dependency between them), so this order is arbitrary but is
  specified explicitly to remove ambiguity for ELIXIR-DEV: platform first,
  entity second, matching the order the two `maybe_seed_*` function
  definitions will appear in the file (§2).
- Both clauses are gated by the *same* `using_default_manifest?` value
  (computed once at line 379) — not re-evaluated per clause — so a caller
  passing a custom `migration_source` skips both seed attempts identically,
  preserving ISS-0072's original gating rationale for the new call too.
- `{:error, {:event_type_seed_failed, reason}}` from either clause short-
  circuits the `with`, and `replay_migrations/2`'s existing `@spec` already
  promises `{:error, {:event_type_seed_failed, reason}}`'s parent type space
  is compatible — but note: **the `@spec` at lines 364-371 is not itself
  updated by this design's file list** (it is outside the diagnosis's named
  call-site scope) — ELIXIR-DEV/CODE-DESIGN-VALIDATOR should confirm whether
  `replay_migrations/2`'s public `@spec` already covers
  `{:error, {:event_type_seed_failed, term()}}` as a return value (it does,
  implicitly, if it already types the `maybe_seed_platform_event_types/2`
  failure the same way — check the existing `@spec`'s error union) or needs
  a one-line addition. **This is an explicit open question**, not silently
  resolved: if the current `@spec` does not already list this error shape
  in its union, ELIXIR-DEV must add it (mechanical, not a design decision),
  since `maybe_seed_platform_event_types/2`'s identical failure shape
  presumably already required the same treatment when ISS-0072 shipped.

## 6. Regression test TEST-DESIGNER must write

A test that:

1. Provisions a tenant end-to-end through the real path (whatever fixture/
   helper the existing entity-record write-path tests already use to get a
   provisioned tenant with `replay_migrations/2` run against it — e.g. the
   same setup `test/support/tenant_fixture.ex`-based tests use elsewhere in
   this suite), **without** any explicit/manual call to
   `Letflow.Entities.EventTypes.seed!/1` anywhere in the test's own setup.
2. Performs a real entity-record write for one of the three event types
   (e.g. drives whatever creates an `ENTITY_RECORD_CREATED` event through
   the actual production path — `Letflow.Entities.Records`' create path per
   `records.ex:18-21`'s moduledoc, or equivalently calls
   `EventStore.append_multi/3` → `Registry.validate_payload/3` for
   `"ENTITY_RECORD_CREATED"` against the freshly-provisioned tenant schema).
3. Asserts the write **succeeds** (no `{:error, :unknown_event_type}`) —
   this is the concrete, positive assertion; a passing test must show the
   event type is registered as a side effect of provisioning alone, not by
   asserting `Registry.get_type/2` returns `{:ok, _}` alone (that would be
   weaker — assert the actual write path succeeds end-to-end, since that is
   the reproduction path ISSUE-FIXER confirmed the bug through).
4. **Must fail on pre-fix code** (WF-03's fail-then-pass rule): on the
   current `main`/pre-fix `tenant_provisioning.ex` (no
   `maybe_seed_entity_event_types/2` call in `replay_migrations/2`), this
   test must reproduce ISS-0721's exact failure —
   `{:error, :unknown_event_type}` (or the enclosing 500/error tuple the
   production call path surfaces it as) — proving the test actually
   exercises the gap and is not vacuously true. TEST-DESIGNER should run it
   against the pre-fix tree (or temporarily comment out the new
   `with`-chain clause) to confirm the red state before ELIXIR-DEV's fix
   turns it green, per WF-03's protocol.
5. Should also assert idempotency per §4: calling `replay_migrations/2` a
   second time against the same already-provisioned tenant (simulating a
   tenant re-migration) does not raise, does not return
   `{:error, {:event_type_seed_failed, _}}`, and the entity-record write
   still succeeds afterward — this is the concrete assertion that exercises
   §4's "no extra idempotency handling needed" conclusion, so a regression
   in that assumption (e.g. if `seed!/1`'s internal duplicate-tolerance ever
   breaks) is caught here too.

## 7. Open questions

- Whether `replay_migrations/2`'s existing `@spec` (lines 364-371) already
  types the `{:error, {:event_type_seed_failed, term()}}` union member (it
  should, if ISS-0072's own fix updated it identically for
  `maybe_seed_platform_event_types/2`'s failure) — flagged in §5, not
  silently resolved. ELIXIR-DEV must check and add it if missing; this is
  mechanical and does not change this design's shape.
- No other open questions. `seed!/1`'s idempotency (§4), the exact argument
  value and its scope binding (§2), and the ok/error normalization (§3) are
  all fully specified above.
