PROVENANCE (historical, not current decision authority):
# Design: REQ-031 — Service scope activation validator (`service_scope_validator.zig`, SVC-03)

**Requirement:** REQ-031 (`docs/requirements.yaml`, stage S2, `depends_on: [REQ-030]`)
**Owner (implementer):** ELIXIR-DEV
**Run:** `WF02-REQ031-20260817`, WF-02 Step 1
**This document produces:** module/function signatures, the injectable-lookup shape, the
violation-detail struct, the graph-walk algorithm (as numbered pseudocode, not code), the
exact plug-in point into REQ-030's already-shipped `activate/2` hook, and the required
moduledoc text — **no implementation code**. No function bodies, no `.ex` files.

---

## 0. Sources read for this design

**Letflow project docs, read in full:**

- `docs/requirements.yaml` — REQ-031's full entry (title, description, the explicit SCOPE
  GAP paragraph, all 5 acceptance criteria, `depends_on: [REQ-030]`).
- `docs/agents/AGENT_SYSTEM.md`, `docs/agents/instructions/core-directives.md`.
- `docs/guides/backend_developer_guide.md` §3.1 (naming), §3.5 (error shapes).
- `docs/anti-patterns.md` — no entry directly applicable to this module's own construction.

**Letflow shipped code, read directly (not assumed):**

PROVENANCE (historical, not current decision authority):
- `lib/letflow/definitions.ex` — **full file (819 lines)**. Confirms the exact, already-merged
  hook contract this design must fit, byte-for-byte, not paraphrased:
  - `@type service_scope_validator_fun :: (Graph.t(), tenant_id :: Ecto.UUID.t() -> :ok | {:error, term()})`
    (line 103-104) and `@type activate_opts :: [prefix: String.t(), service_scope_validator:
    service_scope_validator_fun() | nil]` (line 106-109).
  - `run_activate_transaction/4` (line 606-629): the `%ProcessDefinition{status: :draft} =
    definition ->` branch (line 622) is the **only** branch that calls
    `run_service_scope_validator/3` — never the `:active` no-op branch (line 616-617,
    returns `{:already_active, definition}` directly), never the `:deprecated`/`:archived`
    rejection branch (line 619-620, `Repo.rollback(:not_draft)`). This is called **after**
    the row's `FOR UPDATE` lock (line 608-611) and **before** `activate_draft/2`'s two
    transition `UPDATE`s (line 624 vs. line 647-662) — all inside the one open
    `Repo.transaction/1` (line 607), matching `store.zig`'s real, current structure (SVC-03
    runs inside the already-open transaction, not before `BEGIN`).
  - `run_service_scope_validator/3` (line 631-645): `run_service_scope_validator(_definition,
    _tenant_id, nil)` → `:ok` (the nil-hook skip path — **already shipped, this design adds
    no code to it**). The non-nil clause (`is_function(validator, 2)`, line 633-634) converts
    `definition.graph` (the jsonb map) via the already-shipped private
    `graph_struct_from_map/1` (line 741) — `:error` → `{:error, :graph_structure_invalid}`
    (defensive-only, per `req030-…md` §6.2 step 6); `{:ok, graph}` → calls `validator.(graph,
    tenant_id)`. A `{:error, reason}` return from `validator` is wrapped as `{:error,
    {:service_scope_violation, reason}}` (line 639) — **`reason` here is whatever this
    design's validator puts in its own `{:error, reason}` tuple**, unwrapped and passed
    through verbatim, not re-shaped by `definitions.ex`.
  - `interpret_activate_result/1`'s `{:error, {:service_scope_violation, _reason}} = error ->
    error` clause (line 679): passes the whole tuple through unchanged to `activate/2`'s
    caller. Confirms nothing between this validator's return and the eventual external
    caller inspects or reshapes `reason` — whatever shape this design gives `reason` is what
    a future S4 HTTP handler will pattern-match on directly.
  - `@node_type_map` (line 730-738) and `graph_struct_from_map/1`'s node/edge-building logic
    (line 741-818): confirms `Letflow.Definitions.Graph.Node.attributes` is passed through
    **verbatim, unvalidated, string-keyed** from the stored jsonb (`Map.get(node,
    "attributes")`, line 778) — this design's node-attribute reads (`"service_id"`,
    `"plugin_handler"`) must use the same string-keyed convention, never atom keys.
- `lib/letflow/definitions/graph.ex` — **read in full (through line ~620, the CHK-09..12
  section covering SERVICE_TASK)**. Confirms:
  - `Node.attributes :: map() | nil` (line 86), `@enforce_keys [:id, :node_type]` (line 79).
  - CHK-10 (`check_service_task_endpoint/1`, line 579-592) already validates a SERVICE_TASK
    node's `"endpoint"` attribute is a non-blank string; CHK-11 (line 594+) validates
    `"timeout_ms"`. **`"plugin_handler"` is not read or validated anywhere in this file**
    (confirmed by grep — no match), so this design's validator remains the only place in
    Letflow that interprets that attribute key. **`"service_id"` is no longer exclusive to
    this validator as of 2026-08-20 (ISS-0104/GH#334):** CHK-10 now also reads `"service_id"`
    as an alternative to `"endpoint"` (a node with a non-blank `"service_id"` passes CHK-10
    even without an `"endpoint"`) — this validator and CHK-10 both read the same key for
    different purposes (this validator resolves it to a scope check; CHK-10 only tests
    non-blankness) and do not conflict, but the "only place" claim above is stale and is
    corrected here rather than left silently wrong.
  - `Violation`'s `code`/`message` field pair (line 118-119, `@enforce_keys [:code,
    :message]`) — the direct precedent this design's own `Violation` struct follows for
    splitting a machine-matchable atom from a human-readable string (§3.2 below), rather than
    inventing a different shape.
- `lib/letflow/oidc/token_verifier.ex` + `lib/letflow/plugs/auth_pipeline.ex` — the
  codebase's one existing injectable-dependency precedent: a `@behaviour` with one
  `@callback`, resolved via `Application.get_env(:letflow, :oidc)[:token_verifier]` at the
  call site (`auth_pipeline.ex:113`). Read as a candidate pattern and **not** reused here —
  see §3.1's explicit rationale for why a struct-of-functions fits this requirement's shape
  better than a config-resolved behaviour.
- `docs/agents/instructions/core-directives.md` — INV-8 (no unresolved pattern match on
  external-I/O paths) — addressed in §9 OQ-1, since this module's "external I/O" is entirely
  delegated to injected closures it cannot itself guarantee are well-behaved.

**R-Co source of truth (`C:\Users\tvolo\dev\ai-dala\R-Co\`), read directly:**

PROVENANCE (historical, not current decision authority):
- `src/definition/service_scope_validator.zig` (full file, 225 lines) — `ServiceScopeError`,
  `ScopeViolation`, `ServiceScopeValidator.validateServiceTaskReferences`,
  `checkServiceId`, `checkPluginHandler`. This design ports the algorithm's *shape* (graph
  walk, first-violation-wins, global/tenant/not-registered three-way scope decision) but
  **not** the two real dependencies (`ServiceCatalog`, `PluginRegistry`) — see §1's scope
  gap. Confirmed directly, load-bearing for §5's asymmetry note: `checkServiceId`'s
  `ServiceNotFound` branch (line 116-130) always fails; `checkPluginHandler`'s "no
  tenant-scoped entry at all" branch (line 220-222, comment: "PD-05 already validates
  handler existence; skip") never fails — this is a genuine, deliberate asymmetry in the
  source, not a Letflow invention (§5.3).
PROVENANCE (historical, not current decision authority):
- `src/design/svc-01-04-service-scope.md` §2.5 ("Service scope activation validator") and
  §3.3 ("Definition activation scope validation") — read in full. §2.5 confirms the
  `Store.service_scope_validator: ?*ServiceScopeValidator = null` optional-injectable-field
  pattern the task briefing cites, and the exact error-to-violation mapping table (§4 of that
  doc, "ServiceScopeError (SVC-03) — HTTP 422 family") whose three message templates this
  design's `Violation.message` field reuses verbatim (§3.2). §3.3's data-flow diagram
  confirms the scope-decision tree (global → PASS; tenant + owner match → PASS; tenant +
  owner mismatch → FAIL; not found → FAIL for service, but the diagram's own plugin branch
  differs — "not found → skip" — matching the `.zig` source's asymmetry exactly, not a
  reading error).

---

## 1. Scope boundary

**In scope (this requirement):** a new module, `Letflow.Definitions.ServiceScopeValidator`
(§2), implementing the SVC-03 graph-walk-and-scope-comparison algorithm against an
**injectable lookup** (§3) rather than a concrete catalog/registry — this is not a
simplification invented by this design; it is REQ-031's own `docs/requirements.yaml`
description, quoted directly: *"This requirement therefore scopes ServiceScopeValidator's
OWN logic (the graph-walk + scope-comparison algorithm) against an injectable lookup
interface (e.g. two behaviour callbacks or a struct of functions the validator calls rather
than a concrete ServiceCatalog/PluginRegistry module) so the validator is testable and
correct in isolation now, with real catalog/registry wiring deferred explicitly to whichever
later stage actually builds those two dependencies."*

**Explicitly NOT built here, not silently papered over (AC5):**

PROVENANCE (historical, not current decision authority):
| Not built here | Real dependency | Belongs to |
|---|---|---|
| A real, DB-backed service registry answering "is `service_id` X registered, and what's its scope/owner?" | `ServiceCatalog` (R-Co: `src/repository/service_catalog.zig`) — a tenant-scoped service registry table | **S6** (operational cross-cutting / repository layer — not yet ported as of this requirement; no Letflow requirement currently owns it) |
| A real, in-process dispatch table answering "is `plugin_handler` X registered, and what's its scope/owner?" | `PluginRegistry` (R-Co: `src/engine/plugin_registry.zig`) — an in-process plugin dispatch table | **S3** (instance-engine — not yet ported as of this requirement; `Letflow.InstanceSupervisor`/`Letflow.ProcessInstance` exist, but no plugin-dispatch table does) |
| Any HTTP/Plug route layer that renders a `Violation.t()` into a 422 body | S4 HTTP layer | Not in scope for any S2 requirement (mirrors `req030-…md` §1's identical framing for its own out-of-scope HTTP row) |
| Any change to `lib/letflow/definitions.ex` | — | **Zero changes.** REQ-030 already built the full injection point (`activate_opts()`, `run_service_scope_validator/3`, the nil-skip clause) — confirmed by direct read, §0. This design's only job is to produce a value that fits that already-shipped `service_scope_validator_fun()` contract. |
| Any change to `lib/letflow/definitions/graph.ex` | — | Zero changes — CHK-10/11 already own `"endpoint"`/`"timeout_ms"`; this module owns only `"service_id"`/`"plugin_handler"`, confirmed non-overlapping by direct grep (§0). |

**DB schema:** none. This module is a pure, no-I/O validator over an already-in-memory
`Graph.t()` struct and caller-injected closures — no new `Ecto.Schema`, no migration. It
reads `ProcessDefinition.graph`'s already-persisted jsonb column only indirectly, via
`activate/2`'s own already-shipped `graph_struct_from_map/1` conversion (REQ-030) — this
design adds no new read path to that column.

---

## 2. Module and file layout

New file, new module — does not touch any existing file.

| Module | File | Kind |
|---|---|---|
| `Letflow.Definitions.ServiceScopeValidator` | `lib/letflow/definitions/service_scope_validator.ex` | **New.** Public `build/1`, `validate/3`. |
| `Letflow.Definitions.ServiceScopeValidator.Lookup` | same file, nested | **New.** Plain struct (not `Ecto.Schema`) carrying the two injected lookup functions — mirrors `Graph.Node`/`Graph.Edge`'s nested-plain-struct convention. |
| `Letflow.Definitions.ServiceScopeValidator.Violation` | same file, nested | **New.** Plain struct — mirrors `Graph.Violation`'s `code`/`message` split. |

This follows the existing `lib/letflow/definitions/*.ex` submodule convention
(`process_definition.ex` → `ProcessDefinition`, `graph.ex` → `Graph`) — a new file per
schema/logic unit inside the `definitions/` subdirectory, not a new top-level module and not
code added to `Letflow.Definitions` itself.

---

## 3. Types

### 3.1 The injectable `Lookup` — struct-of-functions, not a config-resolved `@behaviour`

**Design decision, stated explicitly (not silently picked):** `docs/requirements.yaml`
names two options — "two behaviour callbacks or a struct of functions." This design picks
**a struct of two functions**, for two concrete reasons:

1. **Ergonomics for the acceptance criteria's own shape.** AC1/AC2/AC3 each say "given an
   injected lookup returning `<a specific canned result>`" — a distinct return value **per
   test case**. A `@behaviour` resolved via `Application.get_env/2` (this codebase's one
   existing precedent, `Letflow.Oidc.TokenVerifier` — §0) fits a single,
   environment-wide-swappable implementation (dev/prod/test), not a different return value
   per call inside the same test run. Building a new named module per AC to implement a
   behaviour would be strictly more ceremony than passing two anonymous functions in a
   struct literal, for no isolation benefit this requirement needs.
2. **No global/shared mutable state.** A struct value passed as a plain function argument
   composes safely under `mix test`'s default `async: true`; a config-resolved behaviour
   would require every concurrent test that needs a different lookup result to serialize
   against `Application.put_env/3`, which is exactly the kind of cross-test coupling
   `docs/agents/workflows/WF-02_requirement_implementation.md` Step 3b's fixture-isolation
   check (line 327c) exists to catch.

```
@type scope :: :global | :tenant

PROVENANCE (historical, not current decision authority):
@type lookup_record :: %{scope: scope(), owner_tenant_id: Ecto.UUID.t() | nil}
  # owner_tenant_id is nil iff scope == :global; expected non-nil iff scope == :tenant
  # (mirrors R-Co's ServiceCatalogRecord.owner_tenant_id: ?[16]u8, "null when scope =
  # global" -- src/design/svc-01-04-service-scope.md §2.1). A :tenant record whose
  # owner_tenant_id is nil is a malformed-lookup-result case -- handled DIFFERENTLY per
  # side, faithfully porting a real R-Co asymmetry (see §5's "second asymmetry" note):
  # service side treats it as a violation (§5 service table row 4, ported from
  # checkServiceId's `owner orelse { ... "service scope data is inconsistent" ... }`,
  # .zig line 142-151); plugin side treats it as a silent pass (§5 plugin table row 4,
  # ported from checkPluginHandler's `owner = reg.owner_tenant_id orelse return;`,
  # .zig line 187 -- a bare `return` in a `ServiceScopeError!void` fn is success, not
  # an error). Do not assume both sides resolve the same way -- they deliberately don't.

@type service_lookup_result :: {:ok, lookup_record()} | {:error, :not_registered}
@type plugin_lookup_result :: {:ok, lookup_record()} | {:error, :not_registered}

PROVENANCE (historical, not current decision authority):
@type service_lookup_fun :: (service_id :: String.t() -> service_lookup_result())
@type plugin_lookup_fun ::
  (plugin_handler :: String.t(), tenant_id :: Ecto.UUID.t() -> plugin_lookup_result())
  # plugin_lookup takes tenant_id because a real future PluginRegistry adapter's own
  # resolution is inherently tenant-aware (R-Co's resolvePluginHandlerForTenant/3 takes
  # tenant_id -- src/design/svc-01-04-service-scope.md §2.4) -- this design pushes ALL of
  # that two-tier "resolve for this tenant, else scan for any other tenant's claim"
  # mechanics behind this one call, so ServiceScopeValidator's own logic only ever sees
  # the same uniform 3-way {global | {tenant, owner} | not_registered} shape for both
  # service_id and plugin_handler. The future S3 adapter implementing this function is
  # where R-Co's real two-tier resolution (checkPluginHandler, .zig line 169-223) will
  # live -- not duplicated here.
```

```
defmodule Letflow.Definitions.ServiceScopeValidator.Lookup do
  @enforce_keys [:service_lookup, :plugin_lookup]
  defstruct [:service_lookup, :plugin_lookup]

  @type t :: %__MODULE__{
    service_lookup: Letflow.Definitions.ServiceScopeValidator.service_lookup_fun(),
    plugin_lookup: Letflow.Definitions.ServiceScopeValidator.plugin_lookup_fun()
  }
end
```

No default/nil-able fields — both functions are `@enforce_keys`, mirroring `Graph.Node`'s
`@enforce_keys [:id, :node_type]` convention (a `Lookup` missing either function is a
caller programming error at construction time, not something this module defends against
at call time — `Kernel.struct!/2`-style enforcement raises immediately, which is the
desired behavior here since there is no sensible "missing lookup" default).

### 3.2 The `Violation` — `reason` atom (machine-matchable) + `message` string (human text)

```
defmodule Letflow.Definitions.ServiceScopeValidator.Violation do
  @enforce_keys [:node_id, :kind, :ref_id, :reason, :message]
  defstruct [:node_id, :kind, :ref_id, :reason, :message]

  @type kind :: :service | :plugin

  @type reason ::
    :service_not_registered
    | :service_not_available_to_tenant
    | :plugin_not_available_to_tenant

  @type t :: %__MODULE__{
    node_id: String.t(),
    kind: kind(),
    ref_id: String.t(),
    reason: reason(),
    message: String.t()
  }
end
```

**Why both `reason` (atom) and `message` (string), when R-Co's own `ScopeViolation` has only
one `reason: []const u8` string field:** AC3 requires the not-registered case to be "a
distinct not-registered violation reason, **distinguishable from the owned-by-another-tenant
case**" — and explicitly, "not just a different string." A closed-set atom
(`:service_not_registered` vs. `:service_not_available_to_tenant`) is
programmatically distinguishable by `==`/pattern-match in a way a free-form formatted
string is not guaranteed to be (two different string templates are still "just different
strings" under AC3's own wording). `Graph.Violation`'s existing `code`/`message` split
(§0) is the direct in-codebase precedent for exactly this separation — this design reuses
that shape, naming the atom field `reason` (not `code`) to match REQ-031's own
`docs/requirements.yaml` vocabulary ("node_id, kind, ref_id, reason") rather than
`Graph.Violation`'s field name, while keeping the same atom-plus-string split.
`message` carries R-Co's own template text verbatim (§0's citation of
`svc-01-04-service-scope.md` §4's message-template table) for continuity with the future S4
HTTP body, filled in with the specific `ref_id`.

**No `owner_tenant_id` field on `Violation`.** AC2 requires the violation to name "the
node_id and the service ref_id" — it does not ask for the conflicting tenant's id, and
`docs/requirements.yaml`'s own `ScopeViolation` description (mirrored from R-Co) does not
carry one either. Not added speculatively.

---

## 4. Function signatures

```
@spec build(lookup :: Lookup.t()) :: Letflow.Definitions.service_scope_validator_fun()
```

Returns the 2-arity function value that IS `Letflow.Definitions.activate/2`'s
`opts[:service_scope_validator]` hook (§6) — reuses `Letflow.Definitions`'s own
already-shipped `@type service_scope_validator_fun` alias directly (`definitions.ex:103-104`)
rather than redefining an equivalent local type, so there is exactly one source of truth for
the hook's shape. `build/1`'s own body (ELIXIR-DEV, Step 2a) captures `lookup` in a closure
and forwards its own two received arguments unchanged as `validate/3`'s first two arguments,
supplying `lookup` as `validate/3`'s third — no other logic lives in `build/1`.

```
@spec validate(
  graph :: Letflow.Definitions.Graph.t(),
  tenant_id :: Ecto.UUID.t(),
  lookup :: Lookup.t()
) :: :ok | {:error, Violation.t()}
```

The graph-walk-and-scope-comparison algorithm itself (§5). Public (not `defp`) so
TEST-DESIGNER can unit-test the algorithm directly against a hand-built `Lookup`, without
going through `build/1`'s closure indirection or `activate/2`'s transaction machinery —
`build/1` exists purely to produce the exact-arity value REQ-030's hook contract requires
(§0's citation: "a natural choice... but design it to fit this codebase's conventions" — the
task briefing's own wording anticipates this is not necessarily the literal function called
`validate/2`).

`tenant_id` is assumed always a well-formed, non-`nil` `Ecto.UUID.t()` string — REQ-030's
`activate/2` derives it via `TenantProvisioning.tenant_id_for_schema_name/1` before this
hook is ever reachable (`definitions.ex:438`), and Letflow currently has **no** equivalent
of R-Co's `ActivateParams.tenant_id: ?[16]u8` "null = platform-admin bypass" concept — see
§9 OQ-2, not silently assumed away.

---

PROVENANCE (historical, not current decision authority):
## 5. Algorithm — `validate/3` (ports `validateServiceTaskReferences`/`checkServiceId`/
`checkPluginHandler`, `.zig` lines 54-223)

**Atomic, first-violation-wins (AC1-3's own framing, and R-Co's explicit design choice,
§0):** the whole walk is one `Enum.reduce_while/3` over SERVICE_TASK nodes, in `graph.nodes`'
original order — no re-sorting, no collected list of violations.

PROVENANCE (historical, not current decision authority):
1. `service_task_nodes = Enum.filter(graph.nodes, &(&1.node_type == :SERVICE_TASK))` —
   `Enum.filter/2` preserves relative order, matching the `.zig` source's single linear pass
   over `graph.nodes` with an inline `if (node.node_type != .SERVICE_TASK) continue`
   (equivalent walk order, restated as filter-then-iterate for clarity).
PROVENANCE (historical, not current decision authority):
2. `Enum.reduce_while(service_task_nodes, :ok, fn node, :ok -> ... end)` — for each node, in
   order:
   a. `node.attributes` is `nil` → this node contributes nothing; `{:cont, :ok}`. Ports the
      `.zig` source's `const attrs_json = node.attributes orelse continue;` (line 65).
   b. **`service_id` check.** `service_id = Map.get(node.attributes, "service_id")`
      (string-keyed, per §0's confirmed convention). If `service_id` is **not** a non-empty
      binary (missing key, `nil`, non-string, or `""`) — no check is performed for this key
      at all; proceed to (c). Otherwise, call `lookup.service_lookup.(service_id)` and
      evaluate against the **service branch table** below. A violation halts immediately
      (`{:halt, {:error, violation}}`); a pass proceeds to (c).
   c. **`plugin_handler` check.** Same non-empty-string gate on
      `Map.get(node.attributes, "plugin_handler")`. If present, call
      `lookup.plugin_lookup.(plugin_handler, tenant_id)` and evaluate against the **plugin
      branch table** below. Violation halts; pass (or absent key) → `{:cont, :ok}`, moving to
      the next node.
3. The `reduce_while`'s final accumulator (`:ok` if every node passed both checks, or
   `{:error, violation}` from whichever check first failed) **is** `validate/3`'s return
   value directly — no further transformation.

### Service branch table (step 2b, `lookup.service_lookup.(service_id)` result)

PROVENANCE (historical, not current decision authority):
| Lookup result | Outcome |
|---|---|
| `{:error, :not_registered}` | **Violation.** `reason: :service_not_registered`, `message: "service #{service_id} is not registered"` (verbatim template, `.zig` line 121 / design-doc §4 table). |
| `{:ok, %{scope: :global}}` | **Pass** — `owner_tenant_id` is not inspected (global scope always passes for any tenant, AC1). |
| `{:ok, %{scope: :tenant, owner_tenant_id: owner}}` where `owner == tenant_id` | **Pass.** |
| `{:ok, %{scope: :tenant, owner_tenant_id: nil}}` | **Violation** (defensive — malformed lookup result, ports `.zig`'s `owner orelse { ... }` branch, line 142-151). `reason: :service_not_available_to_tenant`, `message: "service #{service_id} scope data is inconsistent"`. |
| `{:ok, %{scope: :tenant, owner_tenant_id: owner}}` where `owner != tenant_id` (and non-nil) | **Violation** (AC2). `reason: :service_not_available_to_tenant`, `message: "service #{service_id} is not available to this tenant"` (verbatim template). |

### Plugin branch table (step 2c, `lookup.plugin_lookup.(plugin_handler, tenant_id)` result)

PROVENANCE (historical, not current decision authority):
| Lookup result | Outcome |
|---|---|
| `{:error, :not_registered}` | **Pass — no violation.** First asymmetry with the service table above, by design (see note below, INV-SSV-5) — ports `.zig`'s `checkPluginHandler`'s "no tenant-scoped entry at all: PD-05 already validates; skip" branch (line 220-222) verbatim. |
| `{:ok, %{scope: :global}}` | **Pass.** |
| `{:ok, %{scope: :tenant, owner_tenant_id: owner}}` where `owner == tenant_id` | **Pass.** |
| `{:ok, %{scope: :tenant, owner_tenant_id: nil}}` | **Pass — no violation.** Second asymmetry with the service table above, by design (see note below, INV-SSV-9) — ports `.zig`'s `checkPluginHandler`'s `const owner = reg.owner_tenant_id orelse return;` (line 187) **verbatim**: a bare `return` inside a `ServiceScopeError!void` function is a *successful* return, not an error — R-Co does not raise a violation here. This is the exact inverse of the service table's row 4 above (`{:ok, %{scope: :tenant, owner_tenant_id: nil}}` → Violation for services), which ports `checkServiceId`'s structurally identical-shaped null-owner case (`.zig` line 142-151) the *opposite* way. Do not fold this row into the mismatched-owner row below — they are different R-Co source branches with different outcomes. |
| `{:ok, %{scope: :tenant, owner_tenant_id: owner}}` where `owner != tenant_id` **and non-nil** | **Violation** (ports `.zig` lines 188-200). `reason: :plugin_not_available_to_tenant`, `message: "plugin #{plugin_handler} is not available to this tenant"` (verbatim template). |

PROVENANCE (historical, not current decision authority):
**Why the first asymmetry (not-registered → skip) is preserved, not "fixed":** this is not a
Letflow simplification or an oversight — it is R-Co's own, deliberate design (§0's citation of
both the `.zig` source and `svc-01-04-service-scope.md` §3.3's data-flow diagram, whose plugin
branch independently confirms "not found → skip"). The stated reason in both sources is that
handler **existence** (as opposed to tenant **scope**) is validated by a different check
(PD-05, node-attribute validation) that this validator does not duplicate. Whether Letflow's
own future PD-05 port (REQ-029, already shipped) will ever actually validate `plugin_handler`
existence is unconfirmed — flagged as §9 OQ-3, not silently assumed.

PROVENANCE (historical, not current decision authority):
**Why the second asymmetry (nil `owner_tenant_id` → pass) is preserved, not "fixed":** this is
a distinct, orthogonal asymmetry from the one above — it concerns a *resolved* tenant-scoped
entry with malformed owner data, not an unresolved lookup. R-Co's `checkServiceId` (line
142-151) and `checkPluginHandler` (line 187) each handle the identically-shaped `{scope:
.tenant, owner_tenant_id: null}` case, but oppositely: the service path treats it as
inconsistent data and fails closed; the plugin path's `orelse return` falls straight through
and passes. Nothing in either `.zig` source or `svc-01-04-service-scope.md` explains this
particular difference (unlike the first asymmetry, which both sources justify via PD-05) — it
reads as an incidental consequence of `checkServiceId` and `checkPluginHandler` being written
independently, not a stated policy. This design ports it faithfully anyway, for methodological
consistency with how the first asymmetry above is handled: this design's own stance (§0, §5)
is to preserve R-Co's real branch-level behavior and flag anything questionable via an open
question, not to silently "improve" logic that looks inconsistent. Deviating here (treating
nil-owner-with-tenant-scope as a violation for plugins too, unlike R-Co) is a legitimate
alternative — flagged for REVIEWER/SECURITY-REVIEWER attention as §9 OQ-4, not silently
foreclosed.

---

## 6. Integration with REQ-030's `activate/2` hook — already-shipped, unchanged by this design

Confirmed directly against the merged `lib/letflow/definitions.ex` (§0) — restated here so
this design's own integration claim is checkable against the real file, not against a
paraphrase:

- `Letflow.Definitions.activate/2`'s `opts[:service_scope_validator]` is read once
  (`Keyword.get(opts, :service_scope_validator)`, line 436) and threaded into
  `run_activate_transaction/4` → `run_service_scope_validator/3`.
- **Nil case (AC4's "skipping... when the hook is nil"):** `run_service_scope_validator(_,
  _, nil) -> :ok` — already shipped, exercised by simply omitting the
  `:service_scope_validator` key (or passing `nil` explicitly) from `opts`. This design adds
  no code for this path.
- **Non-nil case (AC4's "calling this validator via its nil-able hook when a lookup
  implementation is supplied"):** a caller builds `lookup = %Lookup{service_lookup: ...,
  plugin_lookup: ...}`, then `hook = ServiceScopeValidator.build(lookup)`, then calls
  `Definitions.activate(id, prefix: prefix, service_scope_validator: hook)`. `hook` is
  exactly the 2-arity function `run_service_scope_validator/3`'s non-nil clause expects
  (`is_function(validator, 2)`, line 634) — no adapter needed between `build/1`'s output and
  `activate/2`'s call site.
- **The `{:error, reason}` → `{:error, {:service_scope_violation, reason}}` wrap** (line
  638-639) means a violation from this design's `validate/3` surfaces at `activate/2`'s
  caller as `{:error, {:service_scope_violation, %Violation{node_id: ..., kind: ..., ref_id:
  ..., reason: ..., message: ...}}}` — the full detail named by REQ-031's description
  ("enough detail... for a future S4 HTTP layer to render a 422 body") reaches the outermost
  caller intact, confirmed by `interpret_activate_result/1`'s pass-through clause (line 679,
  §0).

**Demonstration shape for TEST-DESIGNER (prose, not a test itself):** to prove the nil-skip
path is a **genuine** skip rather than an accidentally-permissive lookup, exercise
`activate/2` twice against a definition whose graph contains a SERVICE_TASK node that WOULD
fail validation if the hook ran (e.g. `service_id` mapped by a `lookup.service_lookup` to
`{:error, :not_registered}`): once with `service_scope_validator: build(lookup)` (expect
`{:error, {:service_scope_violation, %Violation{reason: :service_not_registered, ...}}}`),
once with the key omitted entirely (expect `{:ok, %{definition: ..., already_active:
false}}, or `already_active: true` for the second call — i.e. genuine success, on the exact
same graph).

---

## 7. Required moduledoc text (AC5)

Per AC5 ("the moduledoc explicitly names the ServiceCatalog/PluginRegistry dependency gap and
which future stage each belongs to, rather than implying real catalog integration exists
today"). ELIXIR-DEV may add surrounding prose but must not omit these sentences
(CODE-DESIGN-VALIDATOR and REVIEWER can check them literally):

```
## Scope gap — no real catalog/registry integration yet

This module implements ONLY the graph-walk-and-scope-comparison algorithm (SVC-03) against
an injectable `Lookup` (two functions the caller supplies). It does NOT implement, and does
not itself depend on, either of R-Co's two real dependencies:

  PROVENANCE (historical, not current decision authority):
  * a `ServiceCatalog` -- a tenant-scoped, DB-backed service registry
    (R-Co: `src/repository/service_catalog.zig`) -- belongs to **stage S6**
    (operational cross-cutting / repository layer), not yet ported as of this module.
  * a `PluginRegistry` -- an in-process plugin dispatch table
    (R-Co: `src/engine/plugin_registry.zig`) -- belongs to **stage S3**
    (instance-engine), not yet ported as of this module.

Whoever wires a real hook (via `build/1`) into `Letflow.Definitions.activate/2` before S3/S6
ship MUST supply a `Lookup` backed by something else (a hardcoded map, a stub) -- there is
no default, production-ready `Lookup` in this codebase yet. This mirrors R-Co's own design,
which already makes the validator an optional injectable field on `Store`
(`service_scope_validator: ?*ServiceScopeValidator = null`) -- carrying that same
optionality through, not inventing new complexity.
```

---

## 8. Invariants

PROVENANCE (historical, not current decision authority):
| id | Invariant | Enforced where |
|---|---|---|
| INV-SSV-1 | No new atom is ever created from caller/tenant-controlled input. `kind`/`reason` are drawn from a small, fixed, module-defined set; `node_id`/`ref_id` remain `String.t()` throughout. | §3.2 (`Violation.t()`'s closed `reason()`/`kind()` union types) |
| INV-SSV-2 | Returns on the first violation found; never collects or merges multiple violations. | §5 step 2 (`reduce_while`, `{:halt, ...}` on first failure) |
| INV-SSV-3 | `"service_id"`/`"plugin_handler"` are read only when present as non-empty strings; a missing key, `nil`, non-string, or empty-string value performs no lookup call and produces no violation for that key. | §5 steps 2b/2c |
| INV-SSV-4 | Pure function — no `Letflow.Repo`, no `Ecto.Changeset`, no `Logger.*`, no clock read, no HTTP/file/process-mailbox call anywhere in this module. All I/O is delegated entirely to the two injected `Lookup` functions, treated as opaque. | Whole module — mirrors `Graph`'s own "Purity" moduledoc section (§0) |
| INV-SSV-5 | `plugin_handler`'s "not registered" lookup result is explicitly **not** a violation — asymmetric with `service_id`'s identical result, which **is** a violation. | §5's plugin branch table + its "why the first asymmetry is preserved" note |
| INV-SSV-6 | Node walk order is `graph.nodes`' own order — never re-sorted, never filtered by anything other than `node_type == :SERVICE_TASK`. | §5 step 1 |
| INV-SSV-7 | `owner_tenant_id` comparison against `tenant_id` is exact value equality on the `Ecto.UUID.t()` string form — never a prefix/substring/case-insensitive comparison. On the **service** side only, a `:tenant`-scoped lookup result with a `nil` `owner_tenant_id` is treated as a violation (data inconsistency), never raises. This rule does **not** carry over to the plugin side — see INV-SSV-9, its exact inverse. | §5's service branch table, row 4 |
| INV-SSV-8 | `build/1`'s output has exactly the shape `Letflow.Definitions.service_scope_validator_fun()` requires — reused, not redefined. | §4 |
| INV-SSV-9 | On the **plugin** side only, a `:tenant`-scoped lookup result with a `nil` `owner_tenant_id` is treated as a **pass** (no violation) — the exact inverse of INV-SSV-7's service-side rule for the identically-shaped case. Faithfully ports `checkPluginHandler`'s `owner = reg.owner_tenant_id orelse return;` (`.zig` line 187); not a Letflow invention. Flagged for possible reconsideration at §9 OQ-4. | §5's plugin branch table, row 4 |

---

## 9. Open questions — not silently resolved

**OQ-1 (MINOR):** `validate/3` assumes every `Lookup` function returns a well-formed
`service_lookup_result()`/`plugin_lookup_result()`. A `Lookup` implementation that returns
something else (a caller/lookup-implementation bug, not tenant-controlled input) is not
defended against inside this module — it would raise `CaseClauseError`/`FunctionClauseError`
from within `validate/3`. This is not left silently unsafe: `build/1`'s output is only ever
called from inside `activate/2`'s `Repo.transaction/1`, which is itself wrapped in the outer
`try/rescue` REQ-030's design already built (`req030-…md` §4.0, §6.2) — any such raised
exception is caught there and surfaces as `{:error, {:transaction_failed, exception}}`, not
an uncaught crash. Whether a more specific typed error for "malformed lookup result"
would be preferable to that generic fallback is not decided here — flagged for REVIEWER at
Step 2d.

**OQ-2 (MINOR):** R-Co's `ActivateParams.tenant_id: ?[16]u8` supports a `null =
platform-admin bypass` concept this design's `validate/3` has no equivalent for — `tenant_id`
is assumed always present and non-nil, matching REQ-030's own current `activate/2` (no
platform-admin-bypass mechanic exists in Letflow's schema-per-tenant model as of this
requirement). Not built here; flagged for whichever future requirement introduces
platform-admin activation, if one ever does.

**OQ-3 (MINOR):** §5's asymmetry note observes that R-Co's own justification for "plugin not
found → skip" is "PD-05 already validates handler existence" — but this design does not
verify that Letflow's REQ-029 (`Letflow.Definitions.Graph.validate_node_attributes/1`)
actually validates `plugin_handler` existence anywhere (a grep of `graph.ex`, §0, found no
`"plugin_handler"` reference at all, in PD-05's checks or elsewhere). If it turns out nothing
in Letflow currently validates `plugin_handler` existence, R-Co's stated rationale for the
skip may not fully hold in Letflow yet — the asymmetry is still ported faithfully (§5), since
inventing a new existence check here would be scope creep against this requirement's own
acceptance criteria (none of which mention plugin-handler existence), but the gap is worth a
future requirement's attention rather than being silently assumed closed.

PROVENANCE (historical, not current decision authority):
**OQ-4 (MINOR, flag for REVIEWER/SECURITY-REVIEWER):** §5's plugin branch table treats a
resolved tenant-scoped plugin lookup with a `nil` `owner_tenant_id` as a **pass** (INV-SSV-9),
the exact inverse of the service table's identically-shaped case, which is a **violation**
(INV-SSV-7). This design ports R-Co's real `checkPluginHandler`/`checkServiceId` behavior
faithfully (`.zig` lines 187 vs. 142-151) rather than silently harmonizing the two — but unlike
the not-registered/skip asymmetry (OQ-3's subject), neither `.zig` nor
`svc-01-04-service-scope.md` states a deliberate policy reason for *this* difference; it reads
as incidental. Both `owner_tenant_id: nil` cases represent the same kind of malformed lookup
data (a `:tenant`-scoped record with no recorded owner) — reasonable engineering judgment could
go either way on whether a future `PluginRegistry` adapter (§1, S3) should be allowed to
silently pass this shape through once it's a real, DB-backed source of tenant-isolation
decisions rather than R-Co's original in-memory table. Not resolved here — flagged for
REVIEWER/SECURITY-REVIEWER to weigh in at Step 2d/Step 2b's tenant-data-path gate, since this
is tenant-scope-enforcement logic even though this specific module has no DB path yet.

---

## 10. Cross-module dependencies

| Dependency | Direction | Nature |
|---|---|---|
| `Letflow.Definitions.Graph`/`.Node` (REQ-028/029) | this design → REQ-028/029 | Reads `Graph.t()`'s `nodes` list and each `Node.t()`'s `node_type`/`attributes` fields. Zero code added to `graph.ex`. |
| `Letflow.Definitions.service_scope_validator_fun/0` (REQ-030) | this design → REQ-030 | `build/1`'s return type reuses this existing type alias directly (§4, INV-SSV-8). |
| `Letflow.Definitions.activate/2` / `run_service_scope_validator/3` (REQ-030) | REQ-030 → this design | Already-shipped call site this design's `build/1` output plugs into unchanged (§6). Zero code added to `definitions.ex`. |
| A future `ServiceCatalog` adapter | future S6 → this design | Would supply a real `service_lookup_fun()` implementation. Not built here (§1, §7). |
| A future `PluginRegistry` adapter | future S3 → this design | Would supply a real `plugin_lookup_fun()` implementation, internally handling R-Co's two-tier resolve-then-scan mechanics (§3.1's `plugin_lookup_fun` note). Not built here (§1, §7). |
| S4 (HTTP layer) | S4 → this design | Will eventually render `Violation.t()` (via `activate/2`'s `{:error, {:service_scope_violation, violation}}`) into an HTTP 422 body. Not built here. |

---

## 11. Acceptance-criteria traceability

| REQ-031 acceptance criterion | Concrete design element |
|---|---|
| 1. Given an injected lookup returning a global-scope service, a SERVICE_TASK referencing it passes validation for any `tenant_id` | §5 service branch table row 2 (`{:ok, %{scope: :global}}` → pass, `owner_tenant_id`/`tenant_id` never compared) |
| 2. Given an injected lookup returning a tenant-scoped service owned by tenant A, a SERVICE_TASK referencing it fails validation when activated by tenant B, with a violation naming `node_id` and the service `ref_id` | §5 service branch table row 4; §3.2's `Violation.t()` (`node_id`, `ref_id` fields always populated) |
| 3. Given an injected lookup returning "not registered" for a `service_id`, validation fails with a distinct not-registered violation reason, distinguishable from the owned-by-another-tenant case | §5 service branch table row 1 (`reason: :service_not_registered`) vs. row 4 (`reason: :service_not_available_to_tenant`) — distinct atoms, §3.2's rationale for why atoms (not strings) satisfy "distinguishable, not just a different string" |
| 4. REQ-030's `activate/1` is demonstrated calling this validator via its nil-able hook when a lookup implementation is supplied, and skipping the check entirely when the hook is nil | §6 (full integration section, citing exact `definitions.ex` line numbers for both the nil-skip and non-nil-call paths) + its demonstration-shape note |
| 5. The moduledoc explicitly names the ServiceCatalog/PluginRegistry dependency gap and which future stage each belongs to | §7 (required verbatim moduledoc text naming S6 and S3 by stage number) |
