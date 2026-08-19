# Design: ISS-0072 — Register the 5 unregistered production event types (`TASK_COMPLETED`, `INSTANCE_CANCELLED`, `INSTANCE_PINS_REBOUND`, `SUB_PROCESS_COMPLETED`, `EXECUTION_ERROR`)

**Issue:** `docs/issues/ISS-0072.yaml` (GH#257), severity MAJOR
**Run:** `WF03-ISS0072-20260819`
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact `json_schema` map for each of the 5 new
`event_type_registry` rows, the restructured seed-attrs shape replacing
`@instance_started_event_type_attrs`, the new body of
`maybe_seed_platform_event_types/2`, and the moduledoc-text changes this closes
out — **no implementation code**. No function bodies, no `.ex` files.

---

## 0. Sources read for this design

- `docs/issues/ISS-0072.yaml` (full) — root cause, affected files, ISSUE-FIXER's
  recommendation.
- `lib/letflow/tenant_provisioning.ex` (full) — `replay_migrations/2` (calls
  `maybe_seed_platform_event_types/2` at line 247), the existing
  `@instance_started_event_type_attrs` module attribute (lines 523-537) and its
  seed function (lines 539-547), and the moduledoc sections that narrate this
  ("`replay_migrations/2` also seeds platform event types", lines 41-56, and the
  in-code comment block at lines 486-522).
- `lib/letflow/event_store/registry.ex` (full) — `register_type/2`'s contract
  (`attrs` map with `name`/`schema_version`/`json_schema`/`description`, string
  or atom keys), idempotency semantics (`{:error, :duplicate_event_type_version}`
  treated as success by the caller), and the moduledoc's JSON Schema keyword
  table (`type`, `minimum`/`maximum`, `minLength`/`maxLength`, `enum`,
  `required`, `properties`, `items`, `additionalProperties` — every other
  keyword, e.g. `$ref`/`pattern`/`format`/`allOf`/`anyOf`/`oneOf`/`not`/
  `patternProperties`, is silently ignored). `Letflow.EventStore.Registry.EventType`
  schema fields confirmed (`name`, `schema_version`, `description`, `json_schema`).
- `lib/letflow/event_store.ex` lines 150-208 — `EventStore.append/2`'s
  `Registry.validate_payload/3` call, confirming the failure mode ISS-0072
  describes (`{:error, :unknown_event_type}` for any unregistered `event_type`).
- `lib/letflow/engine.ex` lines 2053-2082 (`append_task_completed_event/5`, the
  `TASK_COMPLETED` payload builder) and lines 2088-2092 (`encode_merge_events/1`)
  — exact payload shape.
- `lib/letflow/engine.ex` lines 2407-2438 (`append_instance_cancelled_event/5`,
  the `INSTANCE_CANCELLED` payload builder) — exact payload shape.
- `lib/letflow/engine/pin_rebind.ex` lines 437-472
  (`append_pins_rebound_event/6`, the `INSTANCE_PINS_REBOUND` payload builder)
  — exact payload shape.
- `lib/letflow/engine/sub_process.ex` lines 1092-1137
  (`append_sub_process_completed_event/8` and its own local
  `encode_merge_events/1`) — exact payload shape.
- `lib/letflow/engine/execution_error.ex` lines 189-236
  (`append_execution_error_event/2`, `encode_affected/1`) — exact payload
  shape.
- `docs/anti-patterns.md` (full) — no entry directly applicable to this fix;
  general "don't silently resolve an open question" and "don't reintroduce a
  documented gap" disciplines both apply to §9 below.

**R-Co source of truth:** not consulted — this is a Letflow-native operational
gap (a registration/seeding omission), not a port-fidelity question; every
`json_schema` below is derived directly from Letflow's own shipped payload
builders (listed above), not from any R-Co precedent.

---

## 1. Scope boundary

**In scope:** `lib/letflow/tenant_provisioning.ex` only —
1. Register 5 new `event_type_registry` rows (`TASK_COMPLETED`,
   `INSTANCE_CANCELLED`, `INSTANCE_PINS_REBOUND`, `SUB_PROCESS_COMPLETED`,
   `EXECUTION_ERROR`), each `schema_version: 1`, seeded at the same point
   `"INSTANCE_STARTED"` already is (inside `maybe_seed_platform_event_types/2`,
   itself called from `replay_migrations/2`, only on the default production
   migration manifest).
2. Restructure the single `@instance_started_event_type_attrs` module attribute
   into a list of 6 attrs maps (§4) and rewrite `maybe_seed_platform_event_types/2`'s
   body to iterate and register all 6, still idempotently, still only on the
   default manifest.
3. Update the now-inaccurate "no other event type has a real writer" framing in
   `tenant_provisioning.ex`'s moduledoc (lines 41-56) and inline comment (lines
   486-522) to reflect the 6-type seed list and name the specific types
   deliberately excluded (§6).
4. Flag (not fix — see §7) the same "no writer exists" framing in
   `lib/letflow/event_store/registry.ex`'s moduledoc lines 47-52.

**Out of scope:**
- `DEFINITION_PROMOTED`, `DEFINITION_VERSION_ROLLED_BACK`,
  `PROMOTION_ASSERTION_TEARDOWN_FAILED` — confirmed no production writer exists
  for any of these (their `event_appender` is caller-injected with no default,
  deliberately unwired). Seeding them now would be speculative, which is the
  exact anti-pattern the original comment ISS-0072 quotes was itself trying to
  avoid — do not seed these three.
- Any change to `register_type/2`, `validate_payload/3`, `get_type/2`, or the
  `EventType` schema/changeset themselves — the registry mechanism is not
  broken, only its seed-time coverage is incomplete. No function signature in
  `registry.ex` changes.
- Any change to the 5 payload-builder call sites in `engine.ex`,
  `pin_rebind.ex`, `sub_process.ex`, `execution_error.ex` — their payload
  shapes are the *input* this design's schemas must accept, not something this
  fix touches.
- `replay_migrations/2`'s own `@spec`, its `using_default_manifest?` guard
  logic, and the `with :ok <- maybe_seed_platform_event_types(...)` call shape
  at line 247 — unchanged. Only the private function's *body* and the attrs
  data it registers change.

---

## 2. What changes, function by function

### 2.1 `Letflow.TenantProvisioning.maybe_seed_platform_event_types/2` — body only, `@spec` unchanged

No public-facing signature change; this is a private function
(`defp`), invisible outside the module.

```
@spec (unchanged, private, no @spec today — none added; matches existing convention)
maybe_seed_platform_event_types(false, _tenant_id) :: :ok
maybe_seed_platform_event_types(true, tenant_id) ::
  :ok | {:error, {:event_type_seed_failed, reason :: term()}}
```

**Current body** (single `Registry.register_type/2` call against
`@instance_started_event_type_attrs`) **becomes**: iterate the new
`@platform_event_type_seed_attrs` list (§4), calling `Registry.register_type/2`
once per entry, in list order, against the same `tenant_id`. Each call's
result is folded the same way the current single call already is:
- `{:ok, _event_type}` → continue
- `{:error, :duplicate_event_type_version}` → continue (idempotent re-seed,
  same semantics as today)
- `{:error, reason}` → **stop iterating and return**
  `{:error, {:event_type_seed_failed, reason}}` immediately (fail-fast, same
  as today's single-entry case — do not attempt to register remaining entries
  once one has failed for a non-duplicate reason, and do not partially-seed
  silently).

This is a straightforward `Enum.reduce_while/3`-shaped fold (list of attrs in,
first hard error short-circuits, `:ok` if every entry either inserted or was
already a duplicate) — described here as the required control-flow shape, not
as code; ELIXIR-DEV chooses the exact construct.

**Order matters for idempotency parity with today:** `TASK_COMPLETED` is not
required to seed before `INSTANCE_CANCELLED` or vice versa — `register_type/2`
has no cross-type ordering dependency (§5's monotonicity check is scoped to
`(name, schema_version)`, not across names) — so list order is a stable,
readable convention only (§4 lists them in the same order ISSUE-FIXER's
diagnosis named them), not a correctness requirement.

### 2.2 No other function signature in this module or `registry.ex` changes.

`register_type/2`, `replay_migrations/2`, `tenant_scoped_migrations/0`, and
every function in `registry.ex` are called exactly as before, with the same
`@spec`s.

---

## 3. Naming decision (ISS-0072's "now-inaccurate naming" callout)

**Decision: rename the module attribute, keep the function name.**

- `@instance_started_event_type_attrs` (single map) →
  **`@platform_event_type_seed_attrs`** (list of 6 maps, §4). The old name is
  actively wrong once it holds 6 unrelated types; the new name describes what
  the list *is for* (this module's own moduledoc section title, "seeds
  platform event types") rather than naming one member of it.
- `maybe_seed_platform_event_types/2` — **keep this name unchanged.** It
  already says "event_type**s**" (plural) and "platform" — it was accurate
  before and remains accurate now; only the module attribute's name was
  wrong (a single-item attribute named after its one item). No rename needed
  here, and renaming a function that already reads correctly would just churn
  every call site for no clarity gain.

---

## 4. The 6-entry `@platform_event_type_seed_attrs` list

Replaces `@instance_started_event_type_attrs` verbatim (same map shape per
entry — `name`/`schema_version`/`description`/`json_schema`, atom keys,
matching `EventType.changeset/2`'s tolerance). `INSTANCE_STARTED`'s existing
entry is carried over unchanged as the list's first element; the 5 new
entries follow.

```
@platform_event_type_seed_attrs [
  %{
    name: "INSTANCE_STARTED",
    schema_version: 1,
    description:
      "Emitted once by Letflow.Engine.create/2 (EE-01) when a new process instance starts.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "definition_id" => %{"type" => "string"},
        "correlation_key" => %{"type" => ["string", "null"]},
        "initial_variables" => %{"type" => "object"}
      },
      "required" => ["definition_id", "initial_variables"]
    }
  },
  %{
    name: "TASK_COMPLETED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Engine.complete_task/3 (M9, EE-04) when a user task is completed.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "task_id" => %{"type" => "string"},
        "node_id" => %{"type" => "string"},
        "output_variables" => %{"type" => "object"},
        "merged_variable_events" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
              "key" => %{"type" => "string"}
            },
            "required" => ["event", "key"]
          }
        },
        "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
    }
  },
  %{
    name: "INSTANCE_CANCELLED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Engine.cancel_instance/3 (M6) when a running instance is cancelled.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "cancelled_task_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
        "cancelled_token_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["cancelled_task_ids", "cancelled_token_ids"]
    }
  },
  %{
    name: "INSTANCE_PINS_REBOUND",
    schema_version: 1,
    description:
      "Emitted by Letflow.Engine.PinRebind.rebind_pins/3 (M6) when a definition/sub-process " <>
        "version pin is rebound.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "entries" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "kind" => %{"type" => "string"},
              "ref" => %{"type" => "string"},
              "prior_version" => %{"type" => "integer"},
              "new_version" => %{"type" => "integer"}
            },
            "required" => ["kind", "ref", "new_version"]
          }
        },
        "actor" => %{"type" => "string"},
        "reason" => %{"type" => ["string", "null"]}
      },
      "required" => ["entries", "actor"]
    }
  },
  %{
    name: "SUB_PROCESS_COMPLETED",
    schema_version: 1,
    description:
      "Emitted by Letflow.Engine.SubProcess (M-series) on the parent instance's stream when " <>
        "a called sub-process instance completes and its output is merged back.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "child_instance_id" => %{"type" => "string"},
        "output_variables" => %{"type" => "object"},
        "merged_variable_events" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
              "key" => %{"type" => "string"}
            },
            "required" => ["event", "key"]
          }
        },
        "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
      },
      "required" => ["child_instance_id", "output_variables", "activated_nodes"]
    }
  },
  %{
    name: "EXECUTION_ERROR",
    schema_version: 1,
    description:
      "Emitted by Letflow.Engine.ExecutionError.append_execution_error_event/2 (EE-10 AC1) " <>
        "when an instance transitions to the :error status.",
    json_schema: %{
      "type" => "object",
      "properties" => %{
        "error_type" => %{"type" => "string"},
        "affected" => %{
          "type" => "object",
          "properties" => %{
            "kind" => %{"type" => "string", "enum" => ["node", "field"]},
            "node_id" => %{"type" => "string"},
            "key" => %{"type" => "string"}
          },
          "required" => ["kind"]
        },
        "reason" => %{"type" => "string"},
        "variables" => %{"type" => "object"},
        "details" => %{"type" => "object"}
      },
      "required" => ["error_type", "affected", "reason", "variables"]
    }
  }
]
```

### 4.1 Notes on individual schema choices (so ELIXIR-DEV doesn't have to re-derive intent)

- **`TASK_COMPLETED` / `SUB_PROCESS_COMPLETED`'s `merged_variable_events`
  items schema** intentionally lists only `event`/`key` as `required` (not
  `old_value`/`new_value`) — `encode_merge_events/1` (both call sites,
  `engine.ex:2088-2092` and `sub_process.ex:1133-1137`) always emits all 4
  keys, but `old_value`/`new_value` can legitimately be `nil` (a variable's
  prior/new value, itself user-supplied and schema-less at this layer) and
  the registry's own hand-rolled `JsonSchema` validator (per `registry.ex`'s
  moduledoc) has no keyword to say "present, but any type including null"
  cleanly without over-constraining — omitting them from `required` while
  still listing `event`/`key` (both always non-nil strings) is the precise,
  non-speculative middle ground; they are simply not asserted on at all
  (`additionalProperties` is not set `false` anywhere in this design, so
  their presence is still permitted, just unchecked).
- **`INSTANCE_PINS_REBOUND`'s `entries` items `required`** matches
  `pin_rebind.ex`'s own comment (lines 437-441): `"prior_version"` is
  "carried for audit purposes" (i.e. informational, not load-bearing), so it
  is present in `properties` but not `required` — only `kind`/`ref`/
  `new_version` (the three keys `PinResolver.apply_rebind_event/2` actually
  reads, per that same comment) are required. `entries` itself is not
  wrapped in a `minItems` constraint — the same comment states `[]` is a
  valid value in some cases, and `minItems` is not in the validator's
  supported-keyword table regardless.
- **`EXECUTION_ERROR`'s `affected` sub-object** models `encode_affected/1`'s
  two-shape union (`execution_error.ex:234-235`: `{"kind" => "node", "node_id"
  => ...}` or `{"kind" => "field", "key" => ...}`) as one object schema with
  `node_id`/`key` both merely listed in `properties` (not `required` — each is
  present only for one of the two `kind` values) plus `kind` constrained via
  `enum: ["node", "field"]`. The validator's supported-keyword table (per
  `registry.ex` moduledoc) has no `oneOf`/`if`/`then` to express "exactly one
  of `node_id`/`key` present depending on `kind`" more precisely — this is the
  closest correct approximation available under the project's own documented
  keyword subset, not a missed opportunity.
- **`INSTANCE_CANCELLED`'s two `_ids` arrays** are permitted to be empty
  (`cancel_instance/3` may run with zero open tasks/live tokens) — no
  `minItems`, matching `engine.ex:2420-2424`'s unconditional
  `Enum.map(open_tasks, ...)`/`Enum.map(live_tokens, ...)` (an empty list in
  is an empty list out, and the JSON array itself is still always present and
  `required`, just possibly `[]`).
- **None of the 6 schemas set `"additionalProperties" => false`** —
  `INSTANCE_STARTED`'s existing shipped entry doesn't either, and R-Co's own
  validator contract (per `registry.ex` moduledoc) documents `pattern`/`$ref`/
  etc. as "permitted and inert," which is consistent with treating
  `additionalProperties` as opt-in tightening the original design deliberately
  didn't reach for on the one existing entry — matching that established
  convention rather than introducing a stricter policy asymmetrically on only
  the 5 new rows.

---

## 5. Idempotency / concurrency — unchanged from today's single-entry case

`register_type/2`'s own `(name, schema_version)` monotonicity/collision check
(`registry.ex` lines 221-259) is per-`name` — seeding 6 distinct names in one
call has no cross-name interaction. A second `replay_migrations/2` call
against an already-seeded tenant schema still hits
`{:error, :duplicate_event_type_version}` for every one of the 6 entries and
still resolves to overall `:ok`, exactly as it does today for
`INSTANCE_STARTED` alone. No new race condition is introduced by iterating
instead of calling once — each `register_type/2` call remains independently
transactional/race-safe via the table's own unique index (§5's backstop,
`registry.ex` line 88).

---

## 6. Moduledoc / comment text changes (`tenant_provisioning.ex`)

Both are prose-only changes (no code), listed as content requirements
ELIXIR-DEV must carry out verbatim in spirit (exact wording is
implementer's discretion, but must convey the same facts):

1. **Moduledoc section "`replay_migrations/2` also seeds platform event types
   (REQ-045 §9 OQ-3a)" (lines 41-56):** update to state that this seeding now
   covers 6 event types (`INSTANCE_STARTED`, `TASK_COMPLETED`,
   `INSTANCE_CANCELLED`, `INSTANCE_PINS_REBOUND`, `SUB_PROCESS_COMPLETED`,
   `EXECUTION_ERROR`), not just `INSTANCE_STARTED` — cite ISS-0072/GH#257 as
   the reason the other 5 were added (a pre-existing operational gap: each had
   a real production writer with no registration, closed here), alongside the
   existing REQ-045 §9 OQ-3a citation for `INSTANCE_STARTED` specifically.
2. **Inline comment block above the (renamed) seed-attrs list (lines
   486-522):** the final paragraph currently reading *"No other event type is
   seeded here ... no other already-designed event type currently has a real
   writer in this codebase that would need its own registry row yet; seeding
   one this call has no caller for would be speculative, not a fix for a
   demonstrated gap"* is now **false** and must be replaced. Replacement must:
   - State plainly that as of ISS-0072, 5 additional event types with real
     production writers were found unregistered, and are now seeded here too
     (name each of the 5, and name their writer: `TASK_COMPLETED` /
     `Letflow.Engine.complete_task/3`, `INSTANCE_CANCELLED` /
     `Letflow.Engine.cancel_instance/3`, `INSTANCE_PINS_REBOUND` /
     `Letflow.Engine.PinRebind.rebind_pins/3`, `SUB_PROCESS_COMPLETED` /
     `Letflow.Engine.SubProcess`'s sub-process completion path,
     `EXECUTION_ERROR` / `Letflow.Engine.ExecutionError.append_execution_error_event/2`).
   - Explicitly name the 3 types still deliberately excluded
     (`DEFINITION_PROMOTED`, `DEFINITION_VERSION_ROLLED_BACK`,
     `PROMOTION_ASSERTION_TEARDOWN_FAILED`) and restate — now truthfully —
     that seeding those would be speculative because no production writer
     exists for them yet, preserving the original comment's still-valid
     underlying principle rather than discarding it.

---

## 7. `registry.ex` moduledoc — flagged, not fixed here (design decision)

`registry.ex`'s moduledoc lines 47-52 (part of the "JSON Schema validation
library choice" section) does **not** repeat the "no writer exists" framing
ISS-0072's premise is about — re-reading it directly (§0 above), that section
is about the *validator implementation choice* (hand-rolled vs.
`ex_json_schema`) and doesn't make any claim about which event types are
registered. **Decision: no change needed in `registry.ex`.** The task
description's instruction to "flag... is this a moduledoc content fix within
design scope, or leave a note for ELIXIR-DEV" is resolved here: there is
nothing inaccurate in `registry.ex`'s moduledoc for this issue to correct —
ELIXIR-DEV does not need to touch this file at all beyond what §6 lists in
`tenant_provisioning.ex`. (If a future reviewer disagrees and finds a
different passage in `registry.ex` that does carry the same stale framing,
that is a new finding, not this design silently missing one — re-read of the
full file at §0 found none.)

---

## 8. How this closes ISS-0072

- **The 3 originally-named types** (`TASK_COMPLETED`, `INSTANCE_CANCELLED`,
  `INSTANCE_PINS_REBOUND`): each gets a `schema_version: 1` row seeded by
  `maybe_seed_platform_event_types/2` on every tenant's
  `replay_migrations/2` call against the default manifest, with a
  `json_schema` (§4) that accepts exactly the payload shape their real
  production writer (`engine.ex:2061-2068`, `engine.ex:2420-2424`,
  `pin_rebind.ex:452-458` respectively) already constructs — so
  `Registry.validate_payload/3` (called from `EventStore.append/2`) finds a
  registered type and a passing schema instead of
  `{:error, :unknown_event_type}`.
- **The 2 types ISSUE-FIXER additionally found**
  (`SUB_PROCESS_COMPLETED`, `EXECUTION_ERROR`): same treatment, same seed
  point, schemas matching `sub_process.ex:1102-1108` and
  `execution_error.ex:193-200` respectively.
- **Idempotency preserved:** existing tenants that already ran
  `replay_migrations/2` once (seeding only `INSTANCE_STARTED` under the old
  code) get the other 5 rows filled in the next time `replay_migrations/2`
  runs against them (it's re-runnable/idempotent per `Ecto.Migrator.run/4`
  itself and this function's own fold) — no separate backfill migration or
  one-off script is required, since `replay_migrations/2` re-running an
  already-migrated tenant schema is already this module's documented normal
  operation (moduledoc, `provision_tenant_schema/1` doc).
- **No speculative seeding:** the 3 types with no real writer remain
  unregistered, preserving the original design's stated principle (§6.2)
  while correcting its now-provably-incomplete factual premise.

---

## 9. Open questions (not silently resolved)

- **OQ-1 (test-fixture drift):** `test/support/req022_migration_fixture.ex`'s
  fixture-only replay path is unaffected by this change (`using_default_manifest?`
  stays `false` for it, so `maybe_seed_platform_event_types/2`'s first clause
  still short-circuits to `:ok` for that path, per `replay_migrations/2`'s
  existing guard at line 247) — but the many test files ISS-0072 names as
  already calling `Registry.register_type/2` directly for their own fixtures
  (`engine_cancel_instance_test.exs`, `engine_complete_task_test.exs`,
  `event_store_test.exs`, etc.) may now be seeding a `(name, schema_version)`
  pair that collides with this design's own `schema_version: 1` seed **if**
  and only if those same tests also exercise a code path that runs
  `replay_migrations/2` against the *default* manifest for the same tenant
  before their own fixture-level `register_type/2` call. This document does
  not attempt to enumerate which test files are affected (that determination
  belongs to TEST-DESIGNER/TEST-DESIGN-VALIDATOR reading the actual test
  fixtures, not to a speculative guess here) — flagging only that
  `register_type/2`'s own `{:error, :duplicate_event_type_version}` /
  `{:error, :schema_version_not_monotonic}` outcomes are the two ways such a
  collision would surface, both already handled gracefully by production code
  paths, but a test fixture calling `register_type/2` directly a *second*
  time for the same `(name, 1)` pair without itself treating
  `:duplicate_event_type_version` as success could newly fail once this
  design ships. TEST-DESIGNER should re-run the full suite and check for this
  specific failure mode rather than assume it away.
- **OQ-2 (schema strictness for `merged_variable_events`):** §4.1 already
  states the design decision (no `additionalProperties: false`, no over-tight
  `required` on the merge-event sub-object) — noting again here only because
  it's the one judgment call in this design with no single objectively-correct
  answer under the validator's supported-keyword subset; REVIEWER may want to
  confirm this reading during Step 2d rather than treat it as beyond question.
- **OQ-3 (future new event types):** this design does not create any new
  mechanism to prevent a *future* new production writer from shipping without
  a corresponding seed entry (the same class of gap ISS-0072 itself is) — no
  compile-time or test-time guard ties "a string literal passed as
  `event_type` to `EventStore.append/2`" to "a registered `event_type_registry`
  seed entry." Left open; out of scope for a MAJOR bug-fix run to invent a new
  static-analysis mechanism, but worth a future requirement/decision record if
  this class of gap recurs a second time (the project's own
  `docs/anti-patterns.md` convention for a recurring failure class).
