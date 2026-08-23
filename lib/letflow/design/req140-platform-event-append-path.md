# REQ-140 — Platform event append path (`EventStore.append_platform_event/2`) and the three promotion event appenders

**Status:** design, pre-implementation. **Owner:** ELIXIR-DEV (this doc is CODE-DESIGNER's
handoff to that role). **Depends on:** REQ-022/023/024/025/026/037/038/040 (all already
shipped — this requirement is pure composition of things they built).

**Sources read for this design** (all confirmed directly against the current tree, not
assumed from the requirement text's paraphrase):

- `lib/letflow/event_store.ex` (full file, 1213 lines) — `append/2` (:157-208), M1
  `active_instance_guard/3` (:357-369), M2 `assign_sequence/3` +
  `lock_and_increment_sequence/3` (:377-411), M3 `claim_idempotency/3` (:420-447), M4
  `insert_event/3` (:474-509), M5 `maybe_store_oversized_payload/2` +
  `store_oversized_payload/3` (:337-344, :515-530), M6 `update_projection/3` (:545-558),
  `interpret_transaction_result/1` clauses (:564-610), `reject_tenant_id/1` (:215-221),
  `fetch_uuid/3` (:223-234), `fetch_payload/1` (:236-241), `fetch_idempotency_key/1`
  (:243-255), `fetch_event_type/1` (:273-278), `validate_metadata/1` (:291-318), the three
  platform sentinel accessors `platform_instance_id/0` / `platform_actor_id/0` /
  `platform_tenant_id/0` (:637-668).
- `lib/letflow/design/req026-event-read-archive-platform-sentinels.md` — platform-sentinel
  background; confirms the sentinels are 0-arity accessor functions on `EventStore` itself
  (not a separate module) and that "real emission ... using the three sentinel constants"
  was explicitly deferred to this later requirement (§1's table, quoting
  `requirements.yaml:1119-1121`).
- `lib/letflow/definitions/promotion.ex` — `promote_opts()`'s inline `event_appender` type
  (:108, `(map(), String.t() -> {:ok, term()} | {:error, term()})`), the `DEFINITION_PROMOTED`
  producer `append_promotion_event/9` (:303-333, event-building at :313-321).
- `lib/letflow/definitions.ex` — `event_appender_fun` type (:878-880, the binding contract:
  `(event_attrs :: map(), prefix :: String.t() -> {:ok, %{event_id: Ecto.UUID.t()}} |
  {:error, term()})`); `rollback_definition_version/4` + `do_rollback/6` +
  `finish_rollback/7` (:2467-2508, `DEFINITION_VERSION_ROLLED_BACK` event-building at
  :2477-2483, `%{event_id: event_id}` destructure at :2484); `supersede_matching_review/3`
  (:2518-2549, `[]` branch :2528-2529, `[single_review]` branch :2531-2540, `[_, _ | _]`
  branch :2542-2548); `apply_teardown_precedence/7` + `append_teardown_failure_event/6`
  (:2933-2954, `PROMOTION_ASSERTION_TEARDOWN_FAILED` event-building at :2941-2947).
- `lib/letflow/tenant_provisioning.ex` — `@platform_event_type_seed_attrs` (:629-...),
  the false comment (:607-627, the exact "no / production writer exists" line break is at
  :618-619 in the *requirement text's* citation; on this tree the phrase reads "no
  production writer exists for any of them yet" fully at line 625 with the leading "no"
  on line 624 — **line numbers have drifted from the requirement text's citation; the
  literal string is unchanged and is what AC11's grep targets**), `maybe_seed_platform_event_types/2`
  (:769-777).
- `priv/repo/migrations/20260816120001_create_events.exs` — confirmed "NO foreign keys,
  deliberately" language at its header (the requirement's line 43 citation; this file's
  header block spans roughly lines 1-53 and the no-FK paragraph is the one beginning "NO
  foreign keys, deliberately").
- `priv/repo/migrations/20260816120002_create_instance_sequence.exs` — confirmed "NO
  foreign key on instance_id" language in its header (requirement's line 21 citation,
  present verbatim).
- `test/letflow/tenant_provisioning_event_seed_test.exs` (:278-292) — the existing
  `assert count == 6` / describe-block text AC13 requires retargeting to 9.

**Note on citation drift:** several line numbers the requirement text cites
(`definitions.ex:595-597`, `definitions.ex:1321-1327`, `definitions.ex:1351-1381`,
`promotion.ex:~306-323`, `tenant_provisioning.ex:~617-622`) do not match this tree's
current line numbers exactly (the file has grown since those citations were written).
Every citation was re-located and re-verified by content in this design (see the source
list above); the *content* the requirement describes is present and unchanged in
substance. This is flagged per this project's "flagged, not silently resolved" convention
— nothing here required re-deciding what the requirement asked for, only re-finding it.

---

## 1. Scope

**In scope:**

1. `Letflow.EventStore.append_platform_event/2` — new public function, `lib/letflow/event_store.ex`.
2. Two new private helpers in the same module: `fetch_platform_instance_id/1` and
   `build_multi_platform/1`.
3. Two new `@type`s in the same module: `append_platform_attrs/0`, `append_platform_error/0`.
4. A new module, `Letflow.EventStore.PlatformEvents` (`lib/letflow/event_store/platform_events.ex`)
   — three public 2-arity adapter functions, one per promotion event type.
5. `lib/letflow/tenant_provisioning.ex`: three new entries appended to
   `@platform_event_type_seed_attrs`, and the comment at the top of that list corrected.
6. A short new moduledoc paragraph on `Letflow.EventStore` recording the "one
   `instance_sequence` row, one lock, for every platform event in a tenant" fact the
   requirement asks to have written down.

**Explicitly NOT in scope (forced by the requirement text, restated here so
ELIXIR-DEV doesn't second-guess it):**

| Not built here | Why |
|---|---|
| Any change to `append/2`, M1, or M6 | Requirement: "`append/2` itself must be left byte-unchanged"; M1/M6 are structurally inapplicable to the sentinel (no `instance_projections` row ever exists for it) |
| Any new migration | `events` and `instance_sequence` both declare no FK on `instance_id` (confirmed above) — nothing to add |
| Wiring these appenders into any route/context `opts[:event_appender]` default | That is REQ-077's job; REQ-077 is blocked on this requirement, not the reverse |
| Reconciling `promote_opts()`'s inline `{:ok, term()}` event_appender type with `definitions.ex`'s `event_appender_fun` `{:ok, %{event_id: ...}}` type | Requirement: "explicitly NOT in scope" — one appender satisfying the narrower type satisfies the wider one too, no code change implied |
| Any change to `test/specs/ISS-0072.md` or `lib/letflow/design/iss072-event-type-registration.md` | AC11 explicitly forbids touching that historical record |

---

## 2. Module placement decision (the requirement's open question)

The requirement asks CODE-DESIGNER to decide, and record reasoning for, where the three
adapter functions live: `Letflow.EventStore`, a new `Letflow.EventStore.PlatformEvents`,
or beside their producers in `Letflow.Definitions`.

**Decision: split placement, not a single answer, because the two halves have different
constraints.**

### 2a. `append_platform_event/2` itself: forced into `Letflow.EventStore`

This part of the question has only one legal answer. `assign_sequence/3`,
`claim_idempotency/3`, `insert_event/3`, `reject_tenant_id/1`, `fetch_uuid/3`,
`fetch_payload/1`, `fetch_idempotency_key/1`, `fetch_event_type/1`, `validate_metadata/1`,
and `interpret_transaction_result/1` are all `defp` — private to `Letflow.EventStore`,
invisible outside it. "REUSES M2 assign_sequence, M3 claim_idempotency and M4 insert_event
**verbatim**" (requirement text) is only achievable by defining `append_platform_event/2`
inside `Letflow.EventStore` itself, calling those same private functions directly, exactly
as `append/2` does. Any other module would need those five functions made public first —
an unrequested, unjustified widening of `EventStore`'s public surface this requirement
does not ask for and REVIEWER would reasonably reject as scope creep. So:
`append_platform_event/2`, `fetch_platform_instance_id/1`, and `build_multi_platform/1`
all live in `lib/letflow/event_store.ex`, as a sibling to `append/2` — matching the
existing convention that all three platform sentinel *accessors* already live directly on
`EventStore` too (§3 of the req026 design doc, quoted above: "no separate file needed").

### 2b. The three adapter functions: new module `Letflow.EventStore.PlatformEvents`

This half is a genuine judgment call. Three options, weighed:

- **Inside `Letflow.EventStore`:** rejected. `EventStore` is deliberately generic — it has
  no knowledge today of `DEFINITION_PROMOTED`, `process_key`, `review_id`, or any other
  promotion-domain vocabulary, and none of its existing code names a specific event type
  string. Adding three functions that hard-code `"DEFINITION_PROMOTED"` etc. into this
  module breaks that generality for no structural reason (unlike §2a, nothing here forces
  it — the adapters only need `append_platform_event/2`, `platform_instance_id/0`, and
  `platform_actor_id/0`, all of which are already public).
- **Beside their producers in `Letflow.Definitions`/`Letflow.Definitions.Promotion`:**
  rejected. `definitions.ex` is already ~3000 lines covering process-definition CRUD,
  promotion, rollback, and assertion-rerun logic; adding event-serialization boilerplate
  (payload-shaping, idempotency-key minting, the `%{event_id: ...}` unwrap) mixes a
  cross-cutting *event-store integration* concern into an already-large *domain-logic*
  module. It would also mean the future consumer of this adapter (REQ-077's route wiring)
  has to know to import `Letflow.Definitions` to get an "event appender" — a naming
  mismatch with its actual job.
- **New module `Letflow.EventStore.PlatformEvents`:** adopted. `Letflow.EventStore` already
  has an established `EventStore.<Noun>` submodule convention for closely-related but
  logically distinct concerns (`EventStore.Registry`, `EventStore.RetentionPolicy`,
  `EventStore.ArchivedEvent`, `EventStore.StoredPayload`, ...). `PlatformEvents` fits that
  pattern exactly: it is event-store-adjacent (its whole job is producing valid
  `append_platform_event/2` input), but domain-flavored (it knows the three event types'
  shapes) — which is exactly the kind of thing this project already puts in an
  `EventStore.*` submodule rather than in `EventStore` proper or in the domain module.
  It also gives REQ-077 (and any later requirement adding a fourth platform event type) one
  obvious, discoverable home to extend, rather than three scattered call sites.

**Not promoted to a `docs/migration/decisions/` record.** This is a single new module
with a directly analogous existing precedent (`EventStore.Registry` et al.) already on
record in the codebase — it is not introducing a new pattern, just applying one that
already exists. If a fourth platform-event adapter is added later and a different shape
looks more natural, that is the point to reconsider — worth a decision record *then*, if
the choice starts feeling load-bearing across multiple requirements. Noted here so a
future reader isn't surprised the module exists without one.

---

## 3. `Letflow.EventStore.append_platform_event/2` — exact design

### 3.1 New types (added to `lib/letflow/event_store.ex`, near `append_attrs`/`append_error`)

```
@type append_platform_attrs :: %{
        required(:instance_id) => Ecto.UUID.t(),  # MUST equal platform_instance_id/0
        required(:event_type) => String.t(),
        required(:payload) => String.t(),
        required(:actor_id) => Ecto.UUID.t(),
        required(:idempotency_key) => String.t(),
        optional(:metadata) => %{optional(String.t()) => String.t()}
      }

@type append_platform_error ::
        {:error, :tenant_id_not_accepted}
        | {:error, :invalid_schema_name}
        | {:error, :not_platform_instance_id}
        | {:error, :missing_instance_id}
        | {:error, :missing_actor_id}
        | {:error, :missing_payload}
        | {:error, :invalid_payload}
        | {:error, :missing_event_type}
        | {:error, :missing_idempotency_key}
        | {:error, :idempotency_key_too_long}
        | {:error, {:invalid_metadata, metadata_violation()}}
        | {:error, :unknown_event_type}
        | {:error, {:payload_validation_failed, [Registry.ValidationFailure.t()]}}
        | {:error, {:sequence_conflict, term()}}
        | {:error, Ecto.Changeset.t()}
        | {:error, term()}
```

Note what is deliberately **absent** from `append_platform_error/0` relative to
`append_error/0`: `:instance_not_started` and `{:instance_terminated, _}` (M1's own
errors — M1 never runs here) and `:tenant_not_provisioned` (already dead in `append/2`
too, per this module's own moduledoc note — not re-introduced). `:not_platform_instance_id`
is new — AC2's error case.

### 3.2 `@spec` and shape

```
@spec append_platform_event(attrs :: append_platform_attrs(), opts :: [prefix: String.t()]) ::
        {:ok, append_result()} | append_platform_error()
```

Same `append_result()` type `append/2` already returns (`%{event:, is_duplicate:,
sequence_number:, global_seq:}`) — unchanged, reused as-is.

### 3.3 Body — a structural sibling of `append/2`, not a wrapper around it

`append/2` cannot be called *by* `append_platform_event/2` as a black box, because
`append/2`'s own `with` chain calls `fetch_uuid(attrs, :instance_id, :missing_instance_id)`
(accepts any UUID) and its `Multi` always includes M1/M6. `append_platform_event/2`
therefore duplicates `append/2`'s pre-transaction `with` chain and its `Multi`-building
call, with exactly two substitutions:

**Pre-transaction phase** — identical to `append/2`'s (§`append/2`:178-186) except step 3
substitutes `fetch_platform_instance_id/1` for the plain `fetch_uuid(attrs, :instance_id,
:missing_instance_id)`:

1. `reject_tenant_id(attrs)` — reused verbatim (unchanged private function).
2. `TenantProvisioning.tenant_id_for_schema_name(prefix)` — reused verbatim.
3. **`fetch_platform_instance_id(attrs)`** — new private helper (§3.4 below). This is the
   *only* structurally new pre-transaction step.
4. `fetch_uuid(attrs, :actor_id, :missing_actor_id)` — reused verbatim.
5. `fetch_payload(attrs)` — reused verbatim.
6. `fetch_idempotency_key(attrs)` — reused verbatim.
7. `fetch_event_type(attrs)` — reused verbatim.
8. `validate_metadata(Map.get(attrs, :metadata) || %{})` — reused verbatim.
9. `Registry.validate_payload(event_type, payload, tenant_id)` — reused verbatim.

`ctx` is built identically to `append/2`'s (same keys: `schema_name`, `tenant_id`,
`instance_id`, `event_type`, `actor_id`, `idempotency_key`, `metadata`, `payload_bytes`,
`decoded_payload`, `event_id`, `created_at` — `event_id`/`created_at` minted exactly once,
same as `append/2`, preserving INV-EV-5 for the platform path too).

**Transactional phase** — `ctx |> build_multi_platform() |> Repo.transaction() |>
interpret_transaction_result()`. `interpret_transaction_result/1` (§`append/2`:564-610) is
reused **completely unchanged, zero edits** — every one of its clauses either pattern-matches
only on keys that still exist in the platform `Multi`'s result (`insert_event`,
`assign_sequence`, `idempotency`), or is the generic catch-all
`{:error, _failed_operation, reason, _changes}`, which never sees `:active_instance_guard`
as `_failed_operation` in the platform path simply because that step was never scheduled.
No new clause is needed and none should be added — adding one would be redundant, unreachable
code.

### 3.4 `fetch_platform_instance_id/1` — new private helper

```
@spec fetch_platform_instance_id(attrs :: map()) ::
        {:ok, Ecto.UUID.t()} | {:error, :missing_instance_id} | {:error, :not_platform_instance_id}
```

Composes with, rather than duplicates, `fetch_uuid/3`: calls
`fetch_uuid(attrs, :instance_id, :missing_instance_id)` first (reused verbatim — same
missing/malformed-UUID handling as every other `fetch_uuid/3` call site), then, only on
success, compares the resulting UUID to `platform_instance_id()`. Equal → `{:ok, instance_id}`.
Not equal → `{:error, :not_platform_instance_id}`, before any query runs — matching this
module's existing "structural checks fail with zero DB writes" discipline (`reject_tenant_id/1`
is the precedent this mirrors). This is what makes AC2 true for *both* cases it names: a
random UUID (fails `platform_instance_id()` equality) and a real started instance's id
(also fails the equality check — deliberately; `append_platform_event/2` refuses every
`instance_id` except the sentinel, full stop, regardless of whether that other id is
otherwise valid or even currently active).

### 3.5 `build_multi_platform/1` — new private helper

```
defp build_multi_platform(ctx) do
  Multi.new()
  |> Multi.run(:assign_sequence, ...)   # M2, same call shape as build_multi/1
  |> Multi.run(:idempotency, ...)       # M3, same call shape as build_multi/1
  |> Multi.run(:insert_event, ...)      # M4, same call shape as build_multi/1
  |> maybe_store_oversized_payload(ctx) # M5, same call shape as build_multi/1
end
```

(Shown here as a skeleton to specify the exact step sequence and naming — not
implementation code; ELIXIR-DEV writes the real function bodies, which are one-line
`Multi.run/3` calls identical in shape to `build_multi/1`'s own, minus the two omitted
steps.)

M1 (`active_instance_guard`) and M6 (`update_projection`) are omitted — not stubbed, not
made conditional, simply never added to this `Multi`. M5 (`maybe_store_oversized_payload/2`)
**is** included for structural symmetry with `append/2` and because it is unconditional on
`instance_projections` (it only reads `payload_bytes` from `ctx` and, when triggered, writes
`event_payload_store` keyed off the just-inserted `events` row) — nothing in the requirement
asks to omit it, and none of the three seeded payloads are expected to exceed 4096 bytes in
practice, but there is no structural reason to special-case it out, so it stays in for the
same reason `append/2` keeps it conditional rather than removing it. Reusing `maybe_store_oversized_payload/2`
and `store_oversized_payload/3` verbatim (both already pure functions of `ctx`, no
`instance_projections` dependency) costs nothing and avoids a latent gap if a payload ever
does grow past the inline threshold.

### 3.6 Placement in the file

Immediately after `append/2`'s own body (i.e., before the `# Pre-transaction phase` banner
comment at :210-213), so a reader scanning top-to-bottom sees the two public "append" entry
points adjacent to each other before descending into their (partly shared) private helpers.
Definition order has no runtime effect in Elixir — this is purely for readability, not a
requirement.

### 3.7 New moduledoc paragraph (the "note for the design" the requirement asks to be written down)

Add one short paragraph to `Letflow.EventStore`'s moduledoc (near the existing
`instance_sequence`/`event_idempotency` section, §`event_store.ex`:43-53), stating:
every platform event appended for a given tenant shares the single sentinel
`instance_id` (`platform_instance_id/0`), so M2's `instance_sequence` row for that
sentinel — and the `FOR UPDATE` lock `lock_and_increment_sequence/3` takes on it — is
shared by **every** platform-scoped append in that tenant's schema, not just the three
promotion event types this requirement wires up. This is a real per-tenant serialization
point for all platform writes: correct, matches R-Co's own design, and fine at S4
traffic volumes (three low-frequency promotion-pipeline event types) — but it is a
capacity property, not a bug, so it needs to be visible in the module's own
documentation rather than rediscovered the first time platform-event volume grows.

---

## 4. `Letflow.EventStore.PlatformEvents` — the translation-layer adapter module

New file: `lib/letflow/event_store/platform_events.ex`.

```
defmodule Letflow.EventStore.PlatformEvents do
  alias Letflow.EventStore
  ...
end
```

Three public functions, one per event type, each independently satisfying
`definitions.ex`'s `event_appender_fun/0` contract
(`(event_attrs :: map(), prefix :: String.t() -> {:ok, %{event_id: Ecto.UUID.t()}} |
{:error, term()})`) so each can be passed directly as `opts[:event_appender]` — e.g.
`event_appender: &Letflow.EventStore.PlatformEvents.append_definition_promoted/2` — by
whatever later requirement (REQ-077) wires up the real route/context call sites. That
wiring itself is out of scope here; only the three functions need to exist and satisfy
the contract.

### 4.1 Common shape all three follow

Every adapter function performs the same four transformations, in this order, before
delegating to `EventStore.append_platform_event/2`:

1. **Relocate domain fields into `:payload`.** Every key in the producer's `event_attrs`
   map *other than* `:event_type` and `:actor_id` (when present) is domain data, not an
   `append_platform_event/2` top-level field — it gets collected into a plain map and
   `Jason.encode!/1`'d into a JSON string for the `:payload` key (matching `fetch_payload/1`'s
   `is_binary/1` requirement — `append_platform_event/2`, like `append/2`, expects an
   already-encoded JSON string, not a bare map; `Registry.validate_payload/3` and the later
   `Jason.decode!/1` inside `append_platform_event/2`'s own `with` chain both assume this).
2. **Mint a deterministic `:idempotency_key`.** See §4.2.
3. **Supply `:instance_id`.** Always `EventStore.platform_instance_id()` — never taken from
   the producer's `event_attrs` (none of the three producers include an `instance_id` key
   at all).
4. **Supply `:actor_id`.** Taken from the producer's own `event_attrs[:actor_id]` when
   present (`DEFINITION_PROMOTED`, `DEFINITION_VERSION_ROLLED_BACK`); replaced with
   `EventStore.platform_actor_id()` when absent (`PROMOTION_ASSERTION_TEARDOWN_FAILED` —
   AC6).

After `EventStore.append_platform_event/2` returns, every adapter function performs one
more transformation before returning to its caller:

5. **Unwrap `append_result()` into the `event_appender_fun/0` contract shape.** `append_platform_event/2`
   returns `{:ok, %{event: %Event{event_id: event_id, ...}, is_duplicate:, sequence_number:,
   global_seq:}}` on success (§3.2/§3.3) — the same `append_result()` `append/2` returns. The
   contract at `definitions.ex`'s `event_appender_fun/0` requires `{:ok, %{event_id:
   Ecto.UUID.t()}}` specifically, nothing wider. Each adapter function therefore matches
   `{:ok, %{event: %Event{event_id: event_id}}}` and returns `{:ok, %{event_id: event_id}}` —
   never the raw `append_result()` map, and never a fabricated/stubbed id (the id returned is
   always the one `append_platform_event/2` itself resolved, whether this was a fresh insert
   or an `is_duplicate: true` replay of an already-claimed idempotency key — both cases
   return the *original* event's real `event_id`, which is exactly what AC4 and AC7 require).
   An `{:error, _} = error` from `append_platform_event/2` passes through unchanged.

### 4.2 Deterministic idempotency-key scheme

**General rule:** `"<event_type_snake_case>:" <> <colon-joined stable identifying fields
from the producer's own event_attrs>`. This mirrors the one deterministic-key precedent
already in this codebase — `Letflow.Definitions`'s own `build_idempotency_key/2` for
promotion-rerun (`"promotion_rerun:" <> review_id <> ":" <> plan_digest`,
`definitions.ex` §"Design §7.1 -- direct port of buildIdempotencyKey") — same
prefix-plus-colon-joined-identifiers shape, applied here to three new event types instead
of reusing that exact function (different domain fields, so a new key per type, not a
shared helper).

| Event type | Idempotency key | Reasoning |
|---|---|---|
| `DEFINITION_PROMOTED` | `"definition_promoted:" <> review_id` | `review_id` is the stable identifier of *this specific promotion decision* — `Promotion.promote_definition/3`'s step 9 runs at most once per successful review application. A retried call carrying the same `review_id` (the only field guaranteed stable across a retry of the same logical promotion) collapses to the same key, so a second `append_platform_event/2` call for it returns the original event rather than inserting a second row. |
| `DEFINITION_VERSION_ROLLED_BACK` | `"definition_version_rolled_back:" <> process_key <> ":" <> from_version <> ":" <> to_version` | `finish_rollback/7` runs after the pointer-swap transaction has already committed (§`definitions.ex` comment at :2447-2450, "called after TX1 commits, never nested inside it"); the triple `(process_key, from_version, to_version)` is exactly what identifies "this one pointer swap" and is stable across a retried event-append call for the same swap. This is the requirement's own named example — "a retried rollback double-appends" — so this is the key that must hold under AC4's test. |
| `PROMOTION_ASSERTION_TEARDOWN_FAILED` | `"promotion_assertion_teardown_failed:" <> run_id` | `apply_teardown_precedence/7`'s own comment states the event "is appended exactly once, regardless of which branch `pre_teardown_status` took" per assertion-rerun `run` — `run_id` alone is already the stable, unique identifier of that one rerun attempt's teardown outcome. |

**What this scheme deliberately does NOT do:** none of the three keys fold in `event_id`
or `created_at` (both are minted fresh by `append_platform_event/2` on every call, so
including either would make the key different on every retry, defeating the entire point of
deterministic idempotency — the anti-pattern REQ-025's own idempotency design already
guards against for `append/2`).

### 4.3 Per-event-type field mapping, `json_schema`, and function signatures

#### `append_definition_promoted/2`

```
@spec append_definition_promoted(event_attrs :: map(), prefix :: String.t()) ::
        {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()}
```

Producer call site: `lib/letflow/definitions/promotion.ex`, `append_promotion_event/9`
(current lines 303-333; requirement text's `~306-323` citation is the same code, shifted).
Producer's `event_attrs`:

```
%{
  event_type: "DEFINITION_PROMOTED",
  actor_id: actor_id,
  review_id: review.id,
  source_tenant_id: source_tenant_id,
  target_tenant_id: target_tenant_id,
  source_definition_id: source_row.id,
  target_definition_id: new_row.id,
  process_key: process_key
}
```

Adapter mapping: `event_type`/`actor_id` stay top-level (actor_id present — no
`platform_actor_id/0` substitution needed here); the remaining six keys
(`review_id`, `source_tenant_id`, `target_tenant_id`, `source_definition_id`,
`target_definition_id`, `process_key`) relocate into `:payload`, JSON-encoded.
Idempotency key: `"definition_promoted:" <> review_id` (§4.2). `instance_id`:
`EventStore.platform_instance_id()`.

Seeded `json_schema` (all six payload fields are `Ecto.UUID.t()` or `String.t()` in the
producer, so JSON type `"string"` for every one; all six are unconditionally present in
every call this producer makes, so all six are `required`):

```
%{
  "type" => "object",
  "properties" => %{
    "review_id" => %{"type" => "string"},
    "source_tenant_id" => %{"type" => "string"},
    "target_tenant_id" => %{"type" => "string"},
    "source_definition_id" => %{"type" => "string"},
    "target_definition_id" => %{"type" => "string"},
    "process_key" => %{"type" => "string"}
  },
  "required" => [
    "review_id", "source_tenant_id", "target_tenant_id",
    "source_definition_id", "target_definition_id", "process_key"
  ]
}
```

#### `append_definition_version_rolled_back/2`

```
@spec append_definition_version_rolled_back(event_attrs :: map(), prefix :: String.t()) ::
        {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()}
```

Producer call site: `lib/letflow/definitions.ex`, `finish_rollback/7` (current lines
2467-2508; requirement text's `~1305-1317`/`1321-1327` citations are the same code,
shifted — this file has grown substantially since those line numbers were recorded).
Producer's `event_attrs`:

```
%{
  event_type: "DEFINITION_VERSION_ROLLED_BACK",
  process_key: process_key,
  from_version: rolled_back_from_version,
  to_version: target_version,
  actor_id: actor_id
}
```

Adapter mapping: `event_type`/`actor_id` stay top-level (actor_id present); `process_key`,
`from_version`, `to_version` relocate into `:payload`. Idempotency key:
`"definition_version_rolled_back:" <> process_key <> ":" <> from_version <> ":" <> to_version`
(§4.2). `instance_id`: `EventStore.platform_instance_id()`.

This is the function whose returned `%{event_id: event_id}` AC7/AC8 depend on:
`finish_rollback/7` destructures the adapter's `{:ok, %{event_id: event_id}}` at line
2484 and threads that same `event_id` into `supersede_matching_review/3`
(current lines 2518-2549, three-way-branched on match count) and into its own returned
`rollback_result()`'s `event_id` field — so the adapter must never fabricate this id;
it is always the real value `append_platform_event/2` resolved (§4.1 step 5).

Seeded `json_schema`:

```
%{
  "type" => "object",
  "properties" => %{
    "process_key" => %{"type" => "string"},
    "from_version" => %{"type" => "string"},
    "to_version" => %{"type" => "string"}
  },
  "required" => ["process_key", "from_version", "to_version"]
}
```

#### `append_promotion_assertion_teardown_failed/2`

```
@spec append_promotion_assertion_teardown_failed(event_attrs :: map(), prefix :: String.t()) ::
        {:ok, %{event_id: Ecto.UUID.t()}} | {:error, term()}
```

Producer call site: `lib/letflow/definitions.ex`, `append_teardown_failure_event/6`
(current lines 2933-2954; requirement text's `~1767-1782` citation is the same code,
shifted). Producer's `event_attrs`:

```
%{
  event_type: "PROMOTION_ASSERTION_TEARDOWN_FAILED",
  run_id: run.id,
  sandbox_id: sandbox_id,
  tenant_id: tenant_id,
  error: teardown_error
}
```

Adapter mapping — the one producer of the three that needs both non-trivial
transformations:

- **No `actor_id` in the producer's map at all** → the adapter supplies
  `actor_id: EventStore.platform_actor_id()` (AC6's second half: persisted row's
  `actor_id` equals `platform_actor_id/0`).
- **`tenant_id` present, and `append_platform_event/2` rejects any top-level `:tenant_id`
  key outright** (`reject_tenant_id/1`, reused verbatim per §3.3 step 1 — this is the same
  guard `append/2` already has, unmodified) → `tenant_id` is **not** dropped, it is
  *relocated into `:payload`* along with `run_id`, `sandbox_id`, `error`. Reasoning: `tenant_id`
  is real audit-relevant domain data (which tenant's sandbox teardown failed), and
  `reject_tenant_id/1`'s check only inspects the top-level `attrs` map — it has no visibility
  into (and no opinion about) what the JSON `:payload` blob itself contains. Moving it into
  the payload satisfies AC1's literal requirement ("Strip `:tenant_id` from ... attrs")
  while not silently discarding a field the producer clearly considered worth recording.
  This mirrors how `source_tenant_id`/`target_tenant_id` are already payload fields for
  `DEFINITION_PROMOTED` above — tenant identifiers are ordinary payload data everywhere
  else in this adapter, this is not a special case.

Idempotency key: `"promotion_assertion_teardown_failed:" <> run_id` (§4.2). `instance_id`:
`EventStore.platform_instance_id()`.

Seeded `json_schema`:

```
%{
  "type" => "object",
  "properties" => %{
    "run_id" => %{"type" => "string"},
    "sandbox_id" => %{"type" => "string"},
    "tenant_id" => %{"type" => "string"},
    "error" => %{"type" => "string"}
  },
  "required" => ["run_id", "sandbox_id", "tenant_id", "error"]
}
```

---

## 5. `lib/letflow/tenant_provisioning.ex` changes

### 5.1 `@platform_event_type_seed_attrs` — three new entries appended

Appended (order after the existing six, per the existing list's own append-only pattern —
nothing existing is reordered) — one entry per event type, each `%{name:, schema_version: 1,
description:, json_schema:}`, matching the six existing entries' exact shape
(`Registry.register_type/2`'s own expected attrs shape, unchanged by this requirement):

```
%{
  name: "DEFINITION_PROMOTED",
  schema_version: 1,
  description:
    "Emitted by Letflow.Definitions.Promotion.promote_definition/3 (PRM-01) after a " <>
      "promotion review is applied, via Letflow.EventStore.PlatformEvents.append_definition_promoted/2.",
  json_schema: <the DEFINITION_PROMOTED schema from §4.3>
},
%{
  name: "DEFINITION_VERSION_ROLLED_BACK",
  schema_version: 1,
  description:
    "Emitted by Letflow.Definitions.rollback_definition_version/4 (PRM-08) after a " <>
      "version pointer swap commits, via Letflow.EventStore.PlatformEvents.append_definition_version_rolled_back/2.",
  json_schema: <the DEFINITION_VERSION_ROLLED_BACK schema from §4.3>
},
%{
  name: "PROMOTION_ASSERTION_TEARDOWN_FAILED",
  schema_version: 1,
  description:
    "Emitted by Letflow.Definitions.apply_promotion_assertion_rerun/6 (PRM-07) when " <>
      "sandbox release fails during assertion rerun, via " <>
      "Letflow.EventStore.PlatformEvents.append_promotion_assertion_teardown_failed/2.",
  json_schema: <the PROMOTION_ASSERTION_TEARDOWN_FAILED schema from §4.3>
}
```

`maybe_seed_platform_event_types/2` (:769-777) needs **no code change** — it already
iterates `@platform_event_type_seed_attrs` generically and already folds
`{:error, :duplicate_event_type_version}` to success for every entry, so it covers 9
entries exactly as it covered 6, unmodified. This is what makes AC12 ("a tenant provisioned
BEFORE this change gains the three registry rows after a `replay_migrations/2` call") true
structurally: the function was already generic over the list's length.

### 5.2 The comment correction (AC11)

Replace the paragraph currently reading (in substance; see §"Sources read" above for the
exact current line numbers) "No other event type is seeded here. `DEFINITION_PROMOTED`,
`DEFINITION_VERSION_ROLLED_BACK`, and `PROMOTION_ASSERTION_TEARDOWN_FAILED` remain
deliberately unseeded: no production writer exists for any of them yet ..." with a
paragraph stating the opposite fact now holds: those three types **are** seeded as of this
requirement, their production writers are the three `Letflow.EventStore.PlatformEvents`
functions (§4), and (per §1's explicit exclusion) nothing yet calls those functions from a
live route — that wiring is REQ-077's job. The corrected comment must not contain the
substring `"production writer exists"` (AC11's exact grep target) — rephrase around it
entirely (e.g., "now have production writers: the three `Letflow.EventStore.PlatformEvents`
adapter functions built by REQ-140" — deliberately avoiding that exact substring, not just
negating it, since AC11 is a substring-absence check, not a semantic one).

---

## 6. Test-file change already specified by AC13 (for TEST-DESIGNER, not built here)

`test/letflow/tenant_provisioning_event_seed_test.exs`:

- Line ~278's describe/test name (currently containing "the 6 rows are not duplicated")
  → update to name 9 rows.
- Line ~289's `assert count == 6` → `assert count == 9`.

Both are TEST-DESIGNER's edits once this design is approved, not built by this design doc
itself (design docs specify shape, not test code) — included here only so the exact
existing lines this requirement's AC13 targets are unambiguous.

---

## 7. Acceptance-criteria-to-design mapping

1. **Appends successfully with no `instance_projections` row for the sentinel.**
   §3.3/§3.5 — `build_multi_platform/1` never schedules M1, so no read against
   `instance_projections` happens at all; nothing in the platform path can fail on that
   table's absence.
2. **Rejects any `instance_id` other than the sentinel, writes nothing, for both a random
   UUID and a real instance's id.** §3.4 `fetch_platform_instance_id/1` — pure equality
   check against `platform_instance_id()`, runs pre-transaction (like `reject_tenant_id/1`),
   zero queries issued on failure, so zero rows change for either case.
3. **Three successive calls get `sequence_number` 1, 2, 3.** §3.5 reuses `assign_sequence/3`
   (M2) verbatim — the same insert-if-absent + `FOR UPDATE` + increment protocol `append/2`
   already relies on for this exact guarantee, now against the sentinel's
   `instance_sequence` row instead of an ordinary instance's.
4. **Re-appending the same deterministic key yields one row, same `event_id` both times.**
   §4.2's deterministic keys + §3.5 reusing `claim_idempotency/3` (M3) verbatim, whose
   `on_conflict: :nothing` + re-select/`resolve_duplicate/3` path (`append/2`'s own,
   unmodified) is exactly what makes a second call with the same key resolve to the
   original event via `interpret_transaction_result/1`'s `is_duplicate: true` clause
   (reused unchanged, §3.3) — and §4.1 step 5 unwraps that original event's real
   `event_id` either time.
5. **Each type validates against its seeded schema using the producer's real attrs map.**
   §4.3's three schemas were derived directly from each producer's actual `event_attrs`
   map (read from source, not guessed) minus the top-level `event_type`/`actor_id` fields
   the adapter keeps out of the payload.
6. **`PROMOTION_ASSERTION_TEARDOWN_FAILED` succeeds despite `tenant_id` present /
   `actor_id` absent; persisted `actor_id` is `platform_actor_id/0`.** §4.3's third
   subsection — `tenant_id` relocated into payload (never top-level, so
   `reject_tenant_id/1` never sees it), `actor_id` supplied as `platform_actor_id()`.
7. **Satisfies `event_appender_fun/0`; `finish_rollback/7`'s `%{event_id: ...}` and the
   persisted `superseded_by` column carry the same real id.** §4.1 step 5 (unwrap, never
   fabricate) + §4.3's rollback subsection (traces exactly how `finish_rollback/7`
   consumes that id and threads it onward).
8. **The `superseded_by` half is non-vacuous — a real one-row match.** This is a
   TEST-DESIGNER fixture concern (seed exactly one `:applied`/`:approved`
   `promotion_reviews` row), not a production-code design point; §4.3's rollback
   subsection documents that `supersede_matching_review/3`'s `[single_review]` branch
   (current lines 2531-2540) is the one that actually calls
   `PromotionReviewStore.supersede_review/3` — the design does not alter that function at
   all, satisfying "reused verbatim" by construction (nothing here touches it).
9. **`append/2` and M1/M6 unchanged; existing `EventStore` test suite still passes.**
   §1's scope table + §3.3's explicit "duplicates ... does not modify" framing — this
   design adds new functions/types, edits zero existing lines in `append/2`,
   `active_instance_guard/3`, or `update_projection/3`.
10. **No new migration; `events`/`instance_sequence` no-FK claims verified.** §"Sources
    read" above — both migration headers directly confirmed, quoted.
11. **The false comment no longer says "no production writer exists"; grep scoped to
    `tenant_provisioning.ex` only.** §5.2.
12. **A pre-existing tenant gains the three registry rows on `replay_migrations/2`; a
    second call is a no-op.** §5.1's last paragraph — `maybe_seed_platform_event_types/2`
    needs no change, already generic and already idempotent over the list.
13. **`assert count == 6` → `== 9`, test name updated, diff quoted.** §6 (TEST-DESIGNER's
    edit; design doc names the exact target).

---

## 8. Open questions carried forward (not silently resolved)

- **Real wiring of these three functions as a live `opts[:event_appender]` default** is
  REQ-077's job (§1's scope table) — this design deliberately builds functions with the
  right shape and does not call them from anywhere in production code paths.
- **`promote_opts()`'s inline `{:ok, term()}` event_appender type vs. `definitions.ex`'s
  `event_appender_fun/0`'s `{:ok, %{event_id: ...}}`** — confirmed (§"Sources read",
  `promotion.ex:327` matches `{:ok, _}`) that no reconciliation is needed; explicitly out
  of scope per the requirement text, restated here for completeness.
- **Whether `Letflow.EventStore.PlatformEvents` should eventually hold a fourth+ platform
  event adapter, and whether that would warrant a `docs/migration/decisions/` record** —
  §2b's placement reasoning notes this as the trigger to revisit, not resolved now since
  only three adapters exist as of this requirement.
