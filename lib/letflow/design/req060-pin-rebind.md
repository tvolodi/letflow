# Design: REQ-060 — Explicit instance pin rebind (`pin_rebind.zig`, PIN-05)

**Requirement:** REQ-060 (stage S3, `depends_on: [REQ-059 (done)]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ060-20260819`, WF-02 Step 1
**This document produces:** module/function signatures, `@spec`s, error taxonomy,
event-payload shape, the exact `Ecto.Multi` call-order ELIXIR-DEV must build, and
explicit moduledoc content requirements — no implementation code. **No
`priv/repo/migrations` change of any kind is part of this design** — PIN-05 writes
exactly one new event type into the existing `events` table; no new table, no new
column.

---

## 0. Sources read for this design

`docs/agents/instructions/core-directives.md`,
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1,
`docs/anti-patterns.md`, `.claude/agents/code-designer.md`,
`docs/guides/backend_developer_guide.md`, `docs/migration/stage-3-instance-engine.md`.
REQ-060/REQ-059/REQ-055/REQ-053's full entries in `docs/requirements.yaml`.
Shipped code read in full: `lib/letflow/engine/pin_resolver.ex` (REQ-059 — the actual
merged module, not just its design doc, per this run's own instructions: the design
doc drifted slightly, see §1 below), `lib/letflow/design/req059-pin-resolver.md`,
`lib/letflow/engine/reconstruction.ex` (`write_back/3`, `lock_projection_nowait/2` —
the only existing `FOR UPDATE NOWAIT` precedent in this codebase),
`lib/letflow/engine.ex` in full (`cancel_instance/3`'s whole pre-transaction/`Multi`
structure — the closest existing sibling to this requirement's own shape; `complete_task/3`'s
locking discipline; the EE-12/REQ-055 lock-inventory moduledoc section;
`InstanceProjection.terminal?/1`'s exact status set), `lib/letflow/event_store.ex`
in full (`append/2`'s `append_attrs`/`append_error`, `Registry.validate_payload/3`
call, `active_instance_guard/3`), `lib/letflow/event_store/registry.ex`
(`get_type/2`, `register_type/2`), `lib/letflow/event_store/instance_projection.ex`
(`@type status`, `terminal?/1`), `lib/letflow/tenant_provisioning.ex`
(`maybe_seed_platform_event_types/2` — confirms **only** `"INSTANCE_STARTED"` is
auto-registered; every other event type, including `"TASK_COMPLETED"`/
`"INSTANCE_CANCELLED"`, is registered by its own test fixture, never by
provisioning), `test/letflow/engine_cancel_instance_test.exs` (confirms the
register-your-own-event-type precedent by direct example, lines 63-97).

## 1. Confirmed against shipped code, not assumed (drift from REQ-059's design doc)

- **`PinResolver.reconstruct_effective_pins/2`'s actual shipped signature takes
  `opts :: [prefix: String.t()]` as its second argument**, not a bare `prefix`
  string — confirmed `pin_resolver.ex:499-501` — matching the design doc's own
  §6 `@spec`. No drift here; noted only because this design's own call sites (§4)
  must use the same `opts` keyword-list form.
- **`merge_effective_pins/2` already folds ALL `INSTANCE_PINS_REBOUND` events, not
  just the most recent one** (`pin_resolver.ex:413-427`, resolving REQ-059's own
  design-doc OQ-2 in the direction this requirement's delta-only payload shape
  needs) — confirmed by direct read of the shipped `merge_effective_pins/2` body,
  not just its moduledoc claim. **This is the single most load-bearing confirmed
  fact for this design**: it means REQ-060 needs no reconstruction-side code change
  at all (§7) — the fold already exists and already reads the exact payload keys
  this design's §5 payload shape must produce.
- **`apply_rebind_event/2`'s exact expected payload shape is already fixed by
  shipped code**, not free for this design to choose (`pin_resolver.ex:450-465`):
  it reads `payload["entries"] || payload[:entries]` (a list), and per entry reads
  `entry["kind"] || entry[:kind]`, `entry["ref"] || entry[:ref]`,
  `entry["new_version"] || entry[:new_version]` — **`prior_version` is never read
  by the fold** (it is carried in the payload for audit/AC1 purposes only, not
  because replay needs it). §5 below's payload shape is therefore not a fresh
  design choice for the `entries` sub-shape — it is dictated by this already-shipped
  reader. Since `Event.payload` is stored via `Ecto.Schema`'s `:map` type (confirmed
  `lib/letflow/event_store/event.ex:84`) and decoded from the JSON string
  `EventStore.append/2` requires (`fetch_payload/1`, `event_store.ex:236-239`) via
  `Jason.decode!/1` (`event_store.ex:198`), the payload map read back by
  `Reconstruction`/`PinResolver` always has **string** keys — this design's §5
  `Jason.encode!/1` call therefore needs no special key-casing care, standard
  `Jason.encode!/1` of a map with atom keys already produces string keys in the
  JSON, which decode back as strings.
- **`InstanceProjection.terminal?/1` does NOT include `:error`**
  (`instance_projection.ex:178-179`: `terminal?/1` is `true` only for
  `:completed`/`:cancelled`; `:active` and `:error` both return `false`). This is
  the single most important divergence this design must NOT silently inherit:
  `cancel_instance/3` (§6's sibling precedent) correctly treats `:error` as
  cancellable by reusing `terminal?/1` verbatim, because EE-08's own scope wants
  that. REQ-060's own text explicitly wants the **opposite** — `:error` IS terminal
  for rebind purposes. **This module must NOT call `InstanceProjection.terminal?/1`
  at all** — it defines its own, differently-scoped eligibility predicate (§4 M2).
- **`EventStore.append/2` requires its `event_type` to already be registered in
  `event_type_registry` for the calling tenant, or the whole append fails with
  `{:error, :unknown_event_type}`** (`event_store.ex:186`'s
  `Registry.validate_payload/3` call is unconditional, propagating `get_type/2`'s
  `{:error, :unknown_event_type}` verbatim when no `EventType` row exists —
  `registry.ex:139-156`, `169-180`). `Letflow.TenantProvisioning.replay_migrations/2`
  auto-registers **only** `"INSTANCE_STARTED"` (`tenant_provisioning.ex:508-544`,
  its own comment states this explicitly: *"No other event type is seeded here"*).
  `"TASK_COMPLETED"`/`"INSTANCE_CANCELLED"` are therefore **not** pre-registered
  either — `test/letflow/engine_cancel_instance_test.exs:63-97` confirms this by
  registering both itself before exercising `cancel_instance/3`/`complete_task/3`.
  **`"INSTANCE_PINS_REBOUND"` is a brand-new event type this requirement
  introduces and this module does NOT self-register it** (matching the
  `TASK_COMPLETED`/`INSTANCE_CANCELLED` precedent, not the `INSTANCE_STARTED`
  one) — §8's moduledoc requirement states this explicitly so TEST-DESIGNER
  registers `"INSTANCE_PINS_REBOUND"` in every fixture the same way
  `engine_cancel_instance_test.exs` already does for its own two event types,
  rather than discovering `{:error, :unknown_event_type}` by surprise. Flagged
  as **OQ-1** (§9) since this is a caller-responsibility choice, not something
  R-Co source could settle (unreachable in this environment) — REVIEWER may
  prefer this module call `Registry.register_type/2` itself, idempotently, the
  same way `maybe_seed_platform_event_types/2` does for `INSTANCE_STARTED`.
- **`cancel_instance/3`'s own locking convention is plain `lock("FOR UPDATE")`
  (blocking), not `NOWAIT`** (`engine.ex:2002`, `2015`, `2061` — confirmed by
  direct read) — REQ-060's own requirement text explicitly asks for the
  **opposite** convention (`NOWAIT` + a distinct `ConcurrentModification`-shaped
  error), citing REQ-055's "zero-cross-instance-contention" rule and R-Co's own
  `CompleteTaskError` shape. The **only** existing `NOWAIT` precedent in this
  codebase is `Reconstruction.write_back/3`'s `lock_projection_nowait/2`
  (`reconstruction.ex:706-720`) — this design's §4 M1 ports that exact
  rescue-`Postgrex.Error`-on-`:lock_not_available` pattern against
  `InstanceProjection` (the same table, same query shape `cancel_instance/3`'s
  own `fetch_and_lock_instance_projection_for_cancel/3` already locks, differing
  only in `NOWAIT` vs. plain `FOR UPDATE`), not `cancel_instance/3`'s own blocking
  helper.
- **`EventStore.append/2`'s own `active_instance_guard/3` is a plain, unlocked
  read** (`event_store.ex:355-365`, design-doc-cited as "invariant 10, ES-01" in
  its own comment) that rejects only `terminal?/1`-true statuses
  (`:completed`/`:cancelled`) with `{:error, {:instance_terminated, status}}` —
  **it does not reject `:error`-status instances**, consistent with
  `terminal?/1`'s own scope noted above. This module's own M2 eligibility check
  (§4) must therefore run and reject `:error` **before** `append/2` is ever
  called — `append/2`'s own guard cannot be relied on to catch REQ-060's
  three-way terminal set.

## 2. Module

`Letflow.Engine.PinRebind` — new module, `lib/letflow/engine/pin_rebind.ex`
(mirrors `lib/letflow/engine/pin_resolver.ex`/`reconstruction.ex` sibling
placement).

### Moduledoc — required content (verbatim-in-substance, per this design)

1. Ports `pin_rebind.zig` (R-Co, 388 lines, PIN-05) — no R-Co source tree was
   reachable at design time; every behavioural claim traces to REQ-060's own
   requirement text or to already-shipped Letflow code, cited by file/line, never
   to a second, unverifiable read of R-Co.
2. States plainly, in its opening paragraph: this module is **the sole write
   path to an instance's effective pin set after `INSTANCE_STARTED`**. No
   scheduled job, catalog publication, or definition promotion may change a
   running instance's pins through any other route — pins are otherwise
   immutable by design (REQ-059's own moduledoc "no fallback, ever" section,
   cited by name), and this module exists specifically to be the one
   deliberate, audited, explicit exception.
3. **Terminal-status naming note (verbatim structure required, §1 finding)**:
   states that PIN-05's own requirement text says "FAILED", but neither R-Co's
   `InstanceStatus` enum nor Letflow's own `InstanceProjection.status`
   (`:active | :completed | :cancelled | :error`) has a `FAILED` variant —
   `ERROR` is the status PIN-05's text means, and `ERROR` (unlike
   `cancel_instance/3`'s own EE-08 scope) counts as **terminal for rebind
   purposes specifically** — a running-but-halted-on-error instance's pins must
   not be silently changeable via this path either. States explicitly that this
   module does **not** call `InstanceProjection.terminal?/1` (which excludes
   `:error`) — it defines its own three-way eligibility check (§4 M2).
4. States the `Reconstruction`/`PinResolver` reuse: this module calls
   `PinResolver.reconstruct_effective_pins/2` (REQ-059, unchanged) to obtain the
   instance's current effective pin set, and appends its own
   `INSTANCE_PINS_REBOUND` event in a payload shape `PinResolver.merge_effective_pins/2`
   **already** folds correctly (§1's confirmed-not-assumed finding) — no
   `Reconstruction`/`PinResolver` code changes are part of this requirement.
5. States the `NOWAIT` locking convention and its provenance: ported from
   `Reconstruction.write_back/3`'s `lock_projection_nowait/2`
   (`reconstruction.ex:706-720`), the only existing precedent, chosen over
   `cancel_instance/3`'s own blocking `lock("FOR UPDATE")` convention because
   REQ-060's own requirement text explicitly asks for immediate, distinct
   contention surfacing rather than blocking — cites REQ-055's
   zero-cross-instance-contention rule (the lock is `instance_id`-scoped only,
   same discipline as every other lock `engine.ex`'s own EE-12 section
   inventories) and states that this inventory should be extended with this
   module's own lock, the same header-sync-gap-fix shape other S3 requirements
   already applied to that section.
6. States the event-type-registration responsibility (§1's finding): this
   module does **not** call `Registry.register_type/2` for
   `"INSTANCE_PINS_REBOUND"` — matching the `TASK_COMPLETED`/`INSTANCE_CANCELLED`
   precedent (registered by the caller/test fixture, not by provisioning or by
   the writing module itself) rather than the `INSTANCE_STARTED` precedent
   (auto-seeded). Cites `tenant_provisioning.ex:508-544`'s own comment and
   `test/letflow/engine_cancel_instance_test.exs:63-97` by name.
7. States the all-or-nothing invariant explicitly: **no `Repo` write of any kind
   happens until every requested entry has been validated against the current
   effective pin set** — an `UnknownPinRef` on entry N means entries `1..N-1`
   (even if individually valid) are also not applied, because validation is a
   separate, complete pass over the whole request before the `Multi`'s one
   event-append step ever runs (§4).

## 3. Public API

```
@type entry_kind :: Letflow.Engine.PinResolver.kind()
# :catalog_entry | :variable_schema | :module -- reused verbatim from REQ-059,
# never redefined here.

@type rebind_entry :: %{
  kind: entry_kind() | String.t(),
  ref: String.t(),
  version: String.t()
}
# Caller-supplied request entry. kind may arrive as either the atom or its
# string form (mirroring PinResolver.merge_effective_pins/2's own
# normalize_kind/1 tolerance for both) -- this module normalizes to the atom
# form as its first validation step (§4 M0.5).

@type rebind_attrs :: %{
  required(:entries) => [rebind_entry()],
  required(:reason) => String.t(),
  required(:actor_id) => Ecto.UUID.t(),
  required(:idempotency_key) => String.t()
}

@type rebind_opts :: [prefix: String.t()]

@type changed_entry :: %{
  kind: entry_kind(),
  ref: String.t(),
  prior_version: String.t(),
  new_version: String.t()
}

@type rebind_result :: %{
  instance_id: Ecto.UUID.t(),
  changed: [changed_entry()],
  rebound_at: DateTime.t()
}

@type rebind_error ::
        {:error, :invalid_instance_id}
        | {:error, :invalid_schema_name}
        | {:error, :missing_actor_id}
        | {:error, :missing_idempotency_key}
        | {:error, :invalid_reason}
        | {:error, :empty_entries}
        | {:error, {:malformed_entry, index :: non_neg_integer(), reason :: term()}}
        | {:error, :instance_not_found}
        | {:error, {:instance_not_rebindable, status :: :completed | :cancelled | :error}}
        | {:error, {:unknown_pin_ref, entry_kind(), ref :: String.t()}}
        | {:error, {:concurrent_modification, instance_id :: Ecto.UUID.t()}}
        | {:error, {:event_append_failed, term()}}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}

@spec rebind_pins(
        instance_id :: Ecto.UUID.t() | String.t(),
        attrs :: rebind_attrs(),
        opts :: rebind_opts()
      ) :: {:ok, rebind_result()} | rebind_error()
```

`rebind_pins/3` is the module's **only** public entry point. No other function in
this module is part of PIN-05's public surface — the "sole write path" invariant
(§2 point 2) applies at the `rebind_pins/3` boundary itself: `Letflow.Engine`
gains no new `rebind_*` function of its own (unlike `create/2`/`complete_task/3`/
`cancel_instance/3`, which are `Letflow.Engine` functions calling into sibling
`Letflow.Engine.*` modules) — `POST /api/v1/instances/{id}/rebind-pins` (S4) calls
`Letflow.Engine.PinRebind.rebind_pins/3` directly, the same way S4 will call
`Letflow.Engine.Reconstruction.reconstruct_instance/2` directly for its own read
route. This placement choice is stated explicitly rather than left for ELIXIR-DEV
to invent a `Letflow.Engine.rebind_pins/3` wrapper no other S3 read-side module
needed.

## 4. Call-order specification (pre-transaction phase + one `Ecto.Multi`)

Mirrors `cancel_instance/3`'s own two-phase shape (design doc precedent: validate
everything requiring **no** `Repo` call first, then run one `Multi`/
`Repo.transaction/1` for everything else) — described here as numbered
call-order steps, each naming the function, its inputs, and its success/failure
contract, never literal Elixir control-flow syntax. The first step to fail
becomes `rebind_pins/3`'s own return value immediately; no later step runs.

### Pre-transaction phase (zero `Repo` calls)

- **M0.1** `cast_instance_id(instance_id)` — `Ecto.UUID.cast/1`; failure →
  `{:error, :invalid_instance_id}`. Mirrors `cancel_instance/3`'s own
  `cast_instance_id/1` verbatim (same defensive INV-8 rationale: a malformed,
  non-UUID value must never reach a `where` clause raw).
- **M0.2** `fetch_actor_and_idempotency_key(attrs)` — `Map.get(attrs, :actor_id)`/
  `Map.get(attrs, :idempotency_key)`, both required, `nil` → `:missing_actor_id`/
  `:missing_idempotency_key` respectively. Mirrors `cancel_instance/3`'s own
  helper of the same name verbatim.
- **M0.3** `fetch_reason(attrs)` — `Map.get(attrs, :reason)`; `nil`, non-binary,
  or a binary that is empty after `String.trim/1` → `{:error, :invalid_reason}`
  (PIN-05 AC4's "missing or empty reason" collapsed into one distinct atom,
  per this design's own reading — see §9 OQ-2). A non-empty, non-blank string →
  proceeds with the trimmed value.
- **M0.4** `fetch_entries(attrs)` — `Map.get(attrs, :entries)`; not a list, or a
  list with zero elements → `{:error, :empty_entries}` (this one atom covers
  both "missing entries key" and "entries: []" — a missing key and an empty
  list are the same "nothing to rebind" condition, no separate atom needed
  since neither AC4 nor any other AC distinguishes them).
- **M0.5** `normalize_and_validate_entries(entries)` — for each entry, in
  request order, checked in this order per entry (first failure for the
  *whole* list halts immediately, index-tagged):
  1. entry is a map (or keyword-list-shaped map, per this codebase's
     established `attrs`-as-map convention) with exactly the three required
     keys `:kind`/`"kind"`, `:ref`/`"ref"`, `:version`/`"version"` present and
     non-`nil` — a missing key or extra unexpected key →
     `{:error, {:malformed_entry, index, :missing_or_unexpected_keys}}`.
  2. `kind` is one of the atoms `:catalog_entry`/`:module`/`:variable_schema`,
     or one of the equivalent strings `"catalog_entry"`/`"module"`/
     `"variable_schema"` (normalized to the atom form for every later step,
     mirroring `PinResolver.normalize_kind/1`'s own tolerance,
     `pin_resolver.ex:468-471`) — anything else →
     `{:error, {:malformed_entry, index, {:invalid_kind, value}}}`.
  3. `ref` is a non-empty (post-`String.trim/1`) binary — anything else →
     `{:error, {:malformed_entry, index, {:invalid_ref, value}}}`.
  4. `version` is a non-empty (post-`String.trim/1`) binary — anything else →
     `{:error, {:malformed_entry, index, {:invalid_version, value}}}`.
  On success: the whole list, normalized (`kind` as atom, `ref`/`version`
  trimmed), is threaded into the `Multi` below as `normalized_entries`.
- **M0.6** `TenantProvisioning.tenant_id_for_schema_name(prefix)` — same
  pre-transaction tenant/schema validation `create/2`/`cancel_instance/3` both
  already perform via this exact call; failure → `{:error, :invalid_schema_name}`
  (matching those two functions' own documented divergence from their design
  docs' stated-but-unproduced `:tenant_not_provisioned` atom — REQ-059's design
  doc §1 already flagged this same divergence once; this design does not
  re-litigate it, just reuses the same call and the same actual failure atom).

Every step above is pure or a single read-only lookup — no `instance_projections`,
`tasks`, `tokens`, or `events` row is read or written until the `Multi` below
opens.

### Atomic phase — one `Ecto.Multi`/`Repo.transaction/1`

- **M1 — `lock_projection_nowait(instance_id, prefix)`.** `InstanceProjection`
  filtered `where p.instance_id == ^instance_id`, `lock("FOR UPDATE NOWAIT")`
  (ported from `Reconstruction.lock_projection_nowait/2`, `reconstruction.ex:706-720`
  — §1). Three outcomes:
  - Postgres raises `%Postgrex.Error{postgres: %{code: :lock_not_available}}`
    (SQLSTATE `55P03`) — rescued, `Repo.rollback({:concurrent_modification, instance_id})`.
    Any other `Postgrex.Error` re-raises unrescued (same scope-limiting discipline
    `lock_projection_nowait/2` itself already documents).
  - Row absent → `Repo.rollback(:instance_not_found)`.
  - Row present → `{:ok, projection}`, threaded to M2. **This lock is held for
    the remainder of the transaction** — the same discipline `cancel_instance/3`'s
    own M2 projection lock already establishes, just `NOWAIT` instead of blocking.
- **M2 — eligibility check (pure, no I/O), the module's own predicate (§1/§2
  point 3), NOT `InstanceProjection.terminal?/1`.** `projection.status in
  [:completed, :cancelled, :error]` → `Repo.rollback({:instance_not_rebindable,
  status})`. `:active` → proceeds. (This is the one place this design
  deliberately does NOT reuse an existing shared predicate — `terminal?/1`'s
  scope is wrong for this call site, per §1's finding; a genuinely new, small,
  local check is the correct choice here, not a variant reuse that would risk
  silently changing `terminal?/1`'s own meaning for its other three call sites.)
- **M3 — `PinResolver.reconstruct_effective_pins(instance_id, prefix: prefix)`.**
  Runs **after** M1's lock is acquired and **inside** the same transaction —
  load-bearing for the concurrency guarantee: a second concurrent
  `rebind_pins/3` call on the same instance cannot observe this call's
  soon-to-be-appended event before this transaction commits or rolls back,
  because it would already have failed at its own M1 with
  `:concurrent_modification` the moment it tried to acquire the same `NOWAIT`
  lock. Outcomes: `{:ok, effective_pins}` → proceeds; `{:error, :instance_not_found}`
  → cannot occur here (M1 already proved the projection row exists, and a
  projection row implies at least one event exists) but if it somehow did,
  propagate as `{:error, :instance_not_found}` (defensive, matching this
  design's "never assume, always route the real outcome" discipline elsewhere);
  any other `{:error, reason}` → `Repo.rollback(reason)`.
- **M4 — per-entry `{kind, ref}` lookup against `effective_pins` (pure, no
  I/O), ALL entries checked before ANY is accepted (PIN-05 AC2, all-or-nothing).**
  For every `normalized_entries` item, in order: `PinResolver.pin_for(effective_pins,
  kind, ref)` (REQ-059's own no-fallback accessor, reused verbatim — §1's
  moduledoc-cited reuse discipline). The **first** entry whose `pin_for/3` call
  returns `{:error, {:pin_missing, kind, ref}}` halts the whole pass:
  `Repo.rollback({:unknown_pin_ref, kind, ref})` — **no entries from this
  request are applied**, including any that were individually found. Every
  entry resolving successfully carries its current `effective_pin()` (this is
  where `prior_version` — the effective pin's own `.version` — comes from).
- **M5 — compute `changed_entries` (pure, no I/O).** For each `{request_entry,
  effective_pin}` pair from M4, in request order: if
  `request_entry.version == effective_pin.version`, contributes **no** entry to
  `changed_entries` (not a change, per PIN-05 AC1's own "an entry whose
  requested version equals the current pinned version is not a change and
  contributes no payload entry"). Otherwise, contributes one
  `%{kind: request_entry.kind, ref: request_entry.ref, prior_version:
  effective_pin.version, new_version: request_entry.version}`.
  `changed_entries` may legitimately be `[]` (every requested entry already
  matched its current version) — this is not itself an error; §9 OQ-3 flags
  whether an event should still be appended in that case.
- **M6 — `EventStore.append/2`.** `attrs = %{instance_id: instance_id,
  event_type: "INSTANCE_PINS_REBOUND", payload: Jason.encode!(%{entries:
  Enum.map(changed_entries, &Map.take(&1, [:kind, :ref, :prior_version,
  :new_version])), actor: actor_id, reason: reason}), actor_id: actor_id,
  idempotency_key: idempotency_key}`, `opts = [prefix: prefix]` — §5 below is
  this exact payload's full shape. `{:ok, result}` → proceeds to M7 with
  `result.sequence_number`/`result.event_id` available if a future caller needs
  them (not part of `rebind_result()` itself — REQ-060's own ACs don't ask for
  them in the return value, only in the persisted event). `{:error, reason}` →
  `Repo.rollback({:event_append_failed, reason})`.
  - **Note on `EventStore.append/2`'s own internal `active_instance_guard/3`**:
    it re-reads `instance_projections.status` (unlocked, but this transaction
    already holds the `NOWAIT` lock from M1, so no other writer can have
    changed it) and rejects only `:completed`/`:cancelled` — `:active` (the
    only status that reaches M6, since M2 already rejected `:error` along with
    the other two) always passes this internal guard. No conflict with M2's own
    check; M6 never needs to special-case the guard's narrower scope.
- **M7** — no separate `instance_projections` write. Unlike `cancel_instance/3`
  (which flips `status` to `:cancelled`, a real state transition),
  `rebind_pins/3` does not change instance status, tokens, or variables — the
  effective pin set lives entirely in the event log (§2 point 4), and M6's own
  `EventStore.append/2` call already advances `instance_projections.last_event_seq`
  as its own internal M7-equivalent step (the same "already advanced, no second
  write" precedent `cancel_instance_projection/4`'s own comment cites for
  `cancel_instance/3`). **No additional `Repo` write happens after M6.**

`Repo.transaction/1`'s result is unwrapped exactly like `cancel_instance/3`'s own
`interpret_cancel_result/3`: an `{:ok, ...}` outcome builds `rebind_result()` from
`instance_id`, `changed_entries` (M5), and `DateTime.utc_now() |> DateTime.truncate(:microsecond)`
computed once, before the transaction opens (matching `cancel_instance/3`'s own
`cancelled_at` timing) and threaded through as `rebound_at`; an `{:error,
_failed_step, reason, _changes}` outcome unwraps to `{:error, reason}` — every
`Repo.rollback/1` reason above already carries its own correctly-shaped tag, so
this unwrap is a pure pass-through, not a second translation layer.

## 5. `INSTANCE_PINS_REBOUND` event payload (PIN-05 AC1)

```
%{
  "entries" => [
    %{
      "kind" => "catalog_entry" | "module" | "variable_schema",
      "ref" => String.t(),
      "prior_version" => String.t(),
      "new_version" => String.t()
    },
    ...
  ],
  "actor" => Ecto.UUID.t(),    # attrs[:actor_id], JSON-encoded as a string
  "reason" => String.t()       # attrs[:reason], trimmed
}
```

- `"entries"` may be `[]` (§4 M5's "every requested entry already matched"
  case — see §9 OQ-3).
- Every key present in every entry is exactly the set
  `PinResolver.apply_rebind_event/2` already reads (`"kind"`, `"ref"`,
  `"new_version"`) plus `"prior_version"` (carried for audit/AC1 purposes,
  never read by the fold — §1). No entry ever omits `"prior_version"`, even
  though the fold doesn't need it — PIN-05 AC1's own wording ("carrying ref,
  prior_version, new_version...") requires it in the persisted event
  regardless of what replay happens to use.
- `"actor"`/`"reason"` are **event-level**, not per-entry — one actor and one
  reason apply to the whole rebind call, matching PIN-05 AC1's own "for each
  CHANGED entry" phrasing naming `ref`/`prior_version`/`new_version` as the
  per-entry fields and `actor`/`reason` as the (implicitly call-level) fields
  around them.

## 6. Concurrency (REQ-055 port — PIN-05's own `ConcurrentModification`)

- **Lock scope**: exactly one row, `instance_projections` filtered by this
  call's own `instance_id` — never wider, matching REQ-055's own
  zero-cross-instance-contention bar and every other lock `engine.ex`'s EE-12
  section already inventories (§1, §2 point 5).
- **Contention shape**: `NOWAIT`, not blocking — a concurrent `rebind_pins/3`
  call (same instance) or a concurrent `complete_task/3`/`cancel_instance/3`
  call that has already acquired this same row's lock (via their own plain
  `FOR UPDATE`) makes this call's M1 fail immediately with
  `{:error, {:concurrent_modification, instance_id}}` rather than queueing
  behind it. This is a **deliberate cross-function interaction**, not a bug:
  `complete_task/3`/`cancel_instance/3` block each other (both use plain
  `FOR UPDATE`), but `rebind_pins/3` never blocks — it either gets the lock
  immediately or fails immediately. Flagged **OQ-4** (§9): whether
  `rebind_pins/3` racing a concurrent `complete_task/3` should really surface
  as `ConcurrentModification` (this design's literal reading of "surfaces
  contention as a distinct ConcurrentModification error rather than blocking")
  or whether R-Co's own `pin_rebind.zig` scopes this narrower (e.g. only
  concurrent rebind-vs-rebind) is unverifiable without R-Co source access.
- **Deadlock**: since `rebind_pins/3` never blocks (only `NOWAIT`), it cannot
  participate in a lock-ordering deadlock with `complete_task/3`'s/
  `cancel_instance/3`'s own `tasks`-before-`instance_projections`(-before-`tokens`)
  ordering — it acquires exactly one lock, once, and either gets it or fails
  immediately. No lock-ordering statement is needed beyond "exactly one lock,
  `instance_projections`, acquired once."

## 7. Reconstruction/replay integration (PIN-05's own AC5)

**No code change to `Letflow.Engine.Reconstruction` or
`Letflow.Engine.PinResolver` is part of this requirement** — §1's confirmed
finding. Concretely:

- `PinResolver.merge_effective_pins/2` already folds every
  `"INSTANCE_PINS_REBOUND"` event found (not just the most recent), applying
  each entry's `"kind"`/`"ref"`/`"new_version"` — exactly the shape §5 produces.
- `PinResolver.reconstruct_effective_pins/2` already filters
  `Reconstruction.read_full_log/3`'s merged (`events` + `events_archive`)
  result for `event_type in ["INSTANCE_STARTED", "INSTANCE_PINS_REBOUND"]` —
  a rebind event appended by this module, once committed, is picked up by the
  next `reconstruct_effective_pins/2` call with **zero** additional plumbing,
  whether that call reads from the live `events` table or (after a future
  archival pass) `events_archive`.
- This design's own §4 M3 already calls `reconstruct_effective_pins/2` itself
  (to validate the request against the *current* effective set) — so this
  requirement's own write path and REQ-053's replay path share the identical
  read function, the strongest possible guarantee that "the effective pin set
  after rebind" and "what replay derives" cannot drift apart (they are, by
  construction, the same function call).
- TEST-DESIGNER's coverage for PIN-05 AC5 should therefore be an
  integration-level test: append a rebind via `rebind_pins/3`, then call
  `PinResolver.reconstruct_effective_pins/2` independently and confirm the
  returned set reflects the new version(s) — no new reconstruction-specific
  test fixture or mock is needed, since no reconstruction code changed.

## 8. Event-type registration (integration note for ELIXIR-DEV/TEST-DESIGNER)

Per §1/§2 point 6: `"INSTANCE_PINS_REBOUND"` must be registered
(`Letflow.EventStore.Registry.register_type/2`) against the tenant under test
**before** any `rebind_pins/3` call, exactly the way
`test/letflow/engine_cancel_instance_test.exs:63-97` already registers
`"TASK_COMPLETED"`/`"INSTANCE_CANCELLED"` — `rebind_pins/3` itself performs no
registration. A permissive `%{"type" => "object"}` schema (this codebase's own
`register_event_type!/2` test-helper default) is sufficient; PIN-05 states no
payload-schema-validation acceptance criterion of its own beyond the shape §5
already fixes structurally.

## 9. Open questions (explicit, not silently resolved)

- **OQ-1 — event-type self-registration (§1, §2 point 6, §8).** This design
  has `rebind_pins/3` **not** self-register `"INSTANCE_PINS_REBOUND"`, matching
  the `TASK_COMPLETED`/`INSTANCE_CANCELLED` precedent rather than the
  `INSTANCE_STARTED` one. REVIEWER should confirm this reading — the
  alternative (idempotent self-registration inside `rebind_pins/3`, mirroring
  `maybe_seed_platform_event_types/2`'s own idempotent-on-duplicate handling)
  would remove a footgun for every future caller but was not chosen here since
  no other S3 write path in this codebase does that for its own event type.
- **OQ-2 — "missing or empty reason" collapsed into one `:invalid_reason`
  atom (§4 M0.3).** PIN-05 AC4's literal wording lists "a missing or empty
  reason" as one single tested scenario (not two), which this design reads as
  license to use one atom for both; a nil-reason and an empty-string reason are
  therefore indistinguishable in the returned error. Flagged in case
  REVIEWER/TEST-DESIGNER wants them split into `:missing_reason` vs.
  `:empty_reason` for a more precise test assertion — no acceptance criterion
  demands the split.
- **OQ-3 — is a zero-`changed_entries` rebind still an event append (§4 M5,
  §5)?** This design's literal reading of PIN-05 AC1 ("appends exactly one
  INSTANCE_PINS_REBOUND event ... for each CHANGED entry") is that exactly one
  event is **always** appended on a successful, valid, in-range rebind call —
  even one whose `entries` list ends up `[]` because every requested version
  already matched. The alternative reading (no event at all when nothing
  actually changed, since there is nothing to record) is equally defensible
  from the same sentence and was not ruled out by any AC text found. This
  design picks "always append, possibly empty" because it is the simpler,
  more uniform contract for a caller checking "did my rebind call succeed" —
  but flags this for REVIEWER/TEST-DESIGNER rather than assuming it silently.
- **OQ-4 — `ConcurrentModification` scope: rebind-vs-rebind only, or
  rebind-vs-any-writer (§6)?** This design's `NOWAIT` lock on
  `instance_projections` makes `rebind_pins/3` surface `ConcurrentModification`
  against **any** concurrent holder of that row's lock, including
  `complete_task/3`/`cancel_instance/3` mid-transaction — not just a second
  concurrent `rebind_pins/3` call. No R-Co source was reachable to confirm
  `pin_rebind.zig`'s own scope here; REVIEWER should confirm this reading is
  the intended one before ELIXIR-DEV builds against it, since a narrower scope
  (only guard against a second rebind) would need a different, non-`instance_projections`
  lock target (e.g. a rebind-specific advisory lock) to achieve.
- **OQ-5 — no R-Co source available**, same standing caveat REQ-059's design
  doc carried (its own OQ-1): every claim in this document traces to REQ-060's
  own requirement text or already-shipped Letflow code, never a second read of
  `pin_rebind.zig` itself.

## 10. Acceptance-criteria → design element map (self-check)

| AC (REQ-060) | Design element |
|---|---|
| AC1 (atomic append, per-CHANGED-entry payload, unchanged-version contributes nothing) | §4 M5/M6, §5 |
| AC2 (UnknownPinRef rejects the WHOLE request, all-or-nothing, verified by unchanged effective set) | §4 M4, §7 (shared read function makes "verify by reading back" trivially consistent) |
| AC3 (InstanceNotRebindable for COMPLETED/CANCELLED/ERROR) | §4 M2, §1/§2 point 3 |
| AC4 (missing/empty reason, empty entries, malformed entry — each a distinct invalid-input error) | §4 M0.3/M0.4/M0.5 |
| AC5 (effective pin set reflects new versions; reconstruction derives the same set, no catalog read) | §7 |
| AC6 (lock contention → distinct ConcurrentModification; moduledoc states ERROR is PIN-05's real terminal status, not a non-existent FAILED) | §4 M1, §6, §2 point 3 |
