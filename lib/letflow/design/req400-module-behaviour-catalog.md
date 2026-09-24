# Design: REQ-400 — `Letflow.Modules.Module` behaviour, `Letflow.Modules.Catalog`, manifest validation, test-only fixture module

**Requirement:** REQ-400 (`docs/requirements.yaml`, search `id: REQ-400`, stage S11,
`depends_on: []`, letflow-queue task 789, GH-1774, owner ELIXIR-DEV)
**Decision record implemented:** `docs/migration/decisions/0039-platform-module-solution-layering.md`
(read in full) — D3 (file-level core/module split) and D4 (the module contract).
Status `decided`, second-review **PASS** (2026-09-24).
**This document produces:** the `Letflow.Modules.Module` behaviour's exact callback
and manifest-map shape (§1), `Letflow.Modules.Catalog`'s exact public-function shape
and its plain-module justification (§2), the six manifest-validation rules' precise
semantics (§3), the test-only fixture module's exact contents (§4), the
`config/config.exs` / `config/test.exs` / `mix.exs` wiring (§5), a security-relevance
note (§6), explicit out-of-scope restatement (§7), and a traceability map against all
5 acceptance criteria (§8). **No implementation code** — no function bodies, no real
`.ex`/`.exs` code blocks; signatures, type shapes and validation rules only, in prose
and pseudocode.

---

## 0. Sources read for this design

- `docs/migration/decisions/0039-platform-module-solution-layering.md` — full read,
  including the REVIEWER FAIL→PASS history (R1–R7) and the "Non-blocking" note at the
  end (module permissions typed `atom()` at the Catalog boundary is a known,
  accepted type-safety gap for this phase, filed as a future `docs/issues/` item once
  P1 lands — not this requirement's job to close).
- `docs/requirements.yaml` REQ-400 entry in full (title, description, all 5
  acceptance-criteria bullets under `acceptance_criteria` — see §8 for the exact
  AC1–AC5 mapping used) and REQ-401's entry (to confirm what REQ-401 does and does NOT expect
  from this requirement's `Catalog` surface — the `role_grants` lookup and the
  `permissions` union, both named explicitly in REQ-400's own BUILDS §2).
- `lib/letflow/api/authorization.ex` lines 219–401 (full read of `@type role`,
  `@type permission`, `@roles`, `@permissions`, `def roles/0`, `def permissions/0`,
  `def roles_from_strings/1`, `role_from_string/1` private clauses) — the exact core
  atom sets and functions the manifest-validation rules (§3) and `Catalog` (§2) read
  against. `@roles` today: `PLATFORM_ADMIN, PROCESS_DESIGNER, PROCESS_OPERATOR,
  TASK_WORKER, AGENT_RUNNER, CANDIDATE`. `@permissions` today (38 atoms, includes the
  six `Exam*`/`ExamCertificateIssue` atoms 0039 moves out in P2/REQ-408 — **not this
  requirement**, they stay in core `@permissions` here and therefore stay reachable
  as "core permissions" for §3 rule 3's collision check as of REQ-400).
- `mix.exs` lines 10, 20–21 — confirms the existing
  `elixirc_paths(:test), do: ["lib", "test/support"]` / `elixirc_paths(_), do:
  ["lib"]` convention this design's `test/support/modules/fixture/` placement (§4)
  relies on: any file under `test/support/` is compiled in `:test` env only, with no
  `mix.exs` change needed.
- `lib/letflow/definitions/json_schema_shape.ex` moduledoc (read) — the existing
  precedent for how this codebase validates a stored JSON-Schema-shaped map
  structurally (a pure leaf predicate, no `Repo`, depth-bounded). REQ-400's
  `settings_schema` field does not need this module or any enforcement logic — REQ-400
  only needs the manifest field's *shape* and the fixture's example value; validating
  a tenant's settings *write* against a module's `settings_schema` is REQ-414's job
  (named explicitly in REQ-400's own requirement text: "REQ-414 relies on it").
- `CLAUDE.md`'s reference to `Letflow.Engine`'s "Process-vs-row decision" moduledoc
  and REQ-045 (row-lock engine, deliberately empty `Letflow.InstanceSupervisor`) — the
  established precedent this design's §2.4 cites for why `Catalog` is a plain module.
- `docs/agents/instructions/security-invariants.md` INV-1 (tenant data isolation)
  read in full — checked against `on_install/2`'s `prefix` parameter (§1.3); no other
  invariant has surface area in this requirement (§6).
- `docs/anti-patterns.md` — skimmed; no entry directly applicable to a behaviour/
  plain-module design of this shape.

---

## 1. `lib/letflow/modules/module.ex` — `Letflow.Modules.Module`

### 1.1 File placement and namespace (D3)

Lives at `lib/letflow/modules/module.ex` — **one level, no subdirectory** — per D3's
exact file-level rule: the module *mechanism* (`Module`, `Catalog`, and the later
`Installs`/`TenantModule` from REQ-402) is core code living directly under
`lib/letflow/modules/*.ex`. This file is not itself a "module" in the D1/D3 sense; it
is the behaviour a module's entry file implements. `defmodule Letflow.Modules.Module`.

### 1.2 The behaviour: three callbacks, two optional

```
@callback manifest() :: Letflow.Modules.Module.manifest()
@callback router() :: module()
@callback on_install(prefix :: String.t(), settings :: map()) ::
            :ok | {:error, term()}

@optional_callbacks router: 0, on_install: 2
```

- `manifest/0` is **required** — every entry module must implement it; a module with
  no `manifest/0` is not a valid entry module (D4).
- `router/0` is **optional** (D4: "optional; a Plug router the platform mounts under
  `/api/v1/modules/<id>/…`") — returns the `Plug.Router`-implementing module itself
  (a `module()`, not an instance), matching this codebase's existing convention of
  routers being modules mounted via `forward`, not started processes (consistent
  with `api_pipeline.ex`'s existing `forward(...)` calls per 0039's own REVIEWER
  citation of `api_pipeline.ex:83`). REQ-400 does not mount any router — that is
  REQ-403's job; this requirement only defines the shape.
- `on_install/2` is **optional** — receives `prefix` (the tenant's schema prefix,
  the same string every other tenant-scoped call in this codebase threads through,
  per INV-1, §6) and `settings` (the module's settings map at install time — REQ-400
  does not define where `settings` comes from at call time; REQ-402's install context
  owns that). Returns `:ok` or `{:error, term()}`. D4: "runs inside the install
  transaction after the module's pack is installed" — REQ-400 defines only the
  callback's own contract, not the transaction that calls it (REQ-402).
- AC1's own wording (`behaviour_info(:callbacks)` / `behaviour_info(:optional_callbacks)`)
  is satisfied by construction: Elixir's `@behaviour`/`@callback` machinery
  auto-generates `behaviour_info/1` from the `@callback`/`@optional_callbacks`
  declarations above — no separate function needs to be written for this; the test
  in AC1 calls the compiler-generated introspection function directly.

### 1.3 The manifest map — exact type shape (D4 + WF-01 rework 1's `route_policies` addition)

```
@type manifest() :: %{
  required(:id)               => String.t(),
  required(:version)          => String.t(),
  required(:depends_on)       => [String.t()],
  required(:pack)             => String.t() | nil,
  required(:permissions)      => [atom()],
  required(:role_grants)      => %{atom() => [atom()]},
  required(:required_roles)   => [String.t()],
  required(:settings_schema)  => map() | nil,
  required(:route_policies)   => [route_policy()]
}

@type route_policy() :: {method :: String.t(), path_pattern :: String.t(), permission :: atom()}
```

Field-by-field semantics, each tied to D4/the requirement text:

- **`id`** — the module's own id string (e.g. `"exam"`, `"fixture"`). Used as the
  `<id>` segment in `lib/letflow/modules/<id>/`, `Letflow.Modules.<Id>`, the mount
  path `/api/v1/modules/<id>`, and the `tenant_modules.module_id` column REQ-402
  introduces. REQ-400 does not enforce any string format (lowercase, no slashes,
  etc.) beyond uniqueness (§3 rule 5) — open question (§9 item 1).
- **`version`** — a version string, opaque to this requirement (no semver parsing
  required by any of REQ-400's acceptance criteria).
- **`depends_on`** — a list of other module `id` strings this module requires
  installed first (D5). §3 rule 4 validates every entry is a registered module id.
  The fixture module (§4) declares `depends_on: []`.
- **`pack`** — either a path (`String.t()`) to the module's solution-pack document,
  or `nil` when the module has no pack of its own. D4: "`pack` is a path" (cited by
  0039's own REVIEWER sign-off, "that holds only while the manifest carries no
  executable content; `pack` is a path, so it holds"). The fixture declares
  `pack: nil` per the requirement text.
- **`permissions`** — the list of permission atoms this module declares and owns.
  §3 rule 3 forbids any atom here also appearing in
  `Letflow.Api.Authorization.permissions/0`'s *core* list (i.e. no module may declare
  a permission atom that collides with an existing core atom — this also
  transitively prevents a module from re-declaring another already-registered
  module's permission atom once REQ-401 unions module permissions into
  `Authorization.permissions/0`, though REQ-400 itself validates only against the
  *core* list since `Authorization.permissions/0` does not yet consult the Catalog
  until REQ-401 lands — this requirement's own `Authorization.permissions/0` read
  is therefore of the **unmodified, pre-REQ-401 core list**, see §3 rule 3's note).
- **`role_grants`** — `%{role_atom => [permission_atom]}`, restricted to atoms this
  module itself declares in `permissions` (§3 rule 2) and to role atoms already in
  `Authorization.roles/0` (§3 rule 1) — a module cannot create a role.
- **`required_roles`** — `[String.t()]`, **advisory only** (D4, citing 0029 §2):
  REQ-400 defines the field's shape and stores it; no validation rule in §3
  constrains its contents, and no enforcement mechanism reads it in this
  requirement or is implied by it.
- **`settings_schema`** — `map() | nil`. A JSON-Schema-shaped map (same document
  shape `Letflow.Definitions.JsonSchemaShape` already validates elsewhere in this
  codebase, §0) describing the module's configurable settings, or `nil` if the
  module has none. REQ-400 does **not** validate `settings_schema`'s own
  well-formedness (no acceptance criterion asks for it) and does **not** validate
  any settings *value* against it (that is REQ-414). REQ-400's only obligation
  regarding this field is that the fixture module's `settings_schema` forbids
  undeclared keys (`"additionalProperties": false` at its top level, or the
  well-formedness predicate's equivalent for a "no undeclared keys" JSON-Schema
  shape) — a concrete example value REQ-414 depends on existing, not a validation
  rule REQ-400 itself enforces.
- **`route_policies`** — `[{method, path_pattern, permission}]`. `method` is an HTTP
  method as an upper-case string (`"GET"`, `"POST"`, …, matching the example in the
  requirement text — `{"GET", "/items/:id", :FixtureRead}`). `path_pattern` is
  relative to the module's mount `/api/v1/modules/<id>` (i.e. does **not** repeat
  `/api/v1/modules/<id>` itself — for the fixture's one route mounted at
  `/api/v1/modules/fixture/items/:id`, the `path_pattern` is `"/items/:id"`).
  REQ-400 does not parse or match `path_pattern` against a real request path (that
  is REQ-401's `endpoint_policy_key/2` fallback, per REQ-401's own requirement
  text) — REQ-400 only stores the tuple and validates its `permission` element
  (§3 rule 6).

### 1.4 `@moduledoc`/`@doc` content (not code, documentation obligation)

`Letflow.Modules.Module`'s moduledoc should state D3's file-placement rule (this file
is core, not a module) and D4's contract summary, so a future module author reads the
rule at the point of use rather than only in 0039. This is a documentation-content
instruction, not implementation code — CODE-DESIGN-VALIDATOR should not read this
paragraph as license for ELIXIR-DEV to skip writing real prose here.

---

## 2. `lib/letflow/modules/catalog.ex` — `Letflow.Modules.Catalog`

### 2.1 File placement and namespace (D3)

`lib/letflow/modules/catalog.ex`, one level, no subdirectory — core code, the
**only** core file D3 permits to reference files inside a `lib/letflow/modules/<id>/`
directory (0039 D3: "except `lib/letflow/modules/catalog.ex`, which is the one
sanctioned place core learns the module list"). `mix letflow.check_boundaries`
(REQ-405, not built here) will encode this exception; REQ-400 does not build that
check, but this design must not violate the rule it enforces — `Catalog`'s own code
is the one place allowed to name `Letflow.Modules.Fixture` (or later,
`Letflow.Modules.Exam`) by module name, and it does so only via the compiled
`config :letflow, :modules` list (§2.2), never by string-building a module name (D3's
stated xref limitation — no `Module.concat/1` or similar over a string built from a
module's own `id` field).

### 2.2 Source of the module list

`Application.compile_env!(:letflow, :modules)` (or `compile_env/3` with a `[]`
default, per the requirement text's own wording "via `Application.compile_env/3`") —
read once at compile time, not at runtime via `Application.get_env/3`, matching D4's
"reads the compiled list of modules from application config" and keeping the value
inlined at compile time the same way other compile-time feature flags in this
codebase already work (`start_http`, `start_scheduler` in `config/test.exs`, §0 —
though those use `get_env`; `Catalog`'s choice of `compile_env` over `get_env` is
deliberate: the module list defines what code exists in the running build, not a
runtime-togglable flag, so a compile-time read is the more correct primitive here and
is explicitly what REQ-400's own text calls for).

### 2.3 Public functions

```
@spec entry_modules() :: [module()]
@spec fetch(id :: String.t()) :: {:ok, module()} | {:error, :not_found}
@spec permissions() :: [atom()]
@spec role_grants(role :: atom()) :: [atom()]
```

- **`entry_modules/0`** — "the list of registered entry modules" (requirement text),
  returning the raw list of entry modules from config, e.g. `[Letflow.Modules.Fixture]`
  in the test env (AC2). Order is config order (stable, no sorting requirement stated
  by any acceptance criterion).
- **`fetch/1`** — "lookup by module id" (requirement text): calls `manifest/0` on
  each `entry_modules/0` member, matches on `manifest.id == id`, returns
  `{:ok, entry_module}` or `{:error, :not_found}`. AC2 requires looking the fixture
  up "by its id string" — this is the function that satisfies that.
- **`permissions/0`** — "the union of all modules' `permissions`" (requirement
  text): the union, over every entry module returned by `entry_modules/0`, of that
  module's own declared `permissions` list (each atom taken from calling that
  module's `manifest/0` and reading its `permissions` field). This is the exact
  function REQ-401 calls to extend
  `Letflow.Api.Authorization.permissions/0` — REQ-400 builds and tests this function
  standalone (its own manifest-validation test, §3, already exercises every module's
  `permissions`); REQ-400 does **not** wire it into `Authorization` (out of scope,
  §7).
- **`role_grants/1`** — "the `role_grants` lookup `Letflow.Api.Authorization` will
  call in REQ-401" (requirement text): given a role atom, returns the union of every
  module's `role_grants[role]` (empty list if no module grants anything to that
  role or the role is absent from a given module's `role_grants` map). This is the
  function REQ-401's `role_allows?/2` fallback calls; REQ-400 defines and tests it,
  does not call it from `Authorization` (out of scope, §7).

No function in this list performs manifest validation (§3) — validation is a
separate, test-only concern (§3.1) run by a test, not a runtime guard `Catalog`
itself imposes on every call (no acceptance criterion asks for runtime validation on
every `Catalog` call, and running full 6-rule validation on every `fetch/1`/
`permissions/0` call would be wasted work at request time — the validation test
running once at `mix test` time, plus 0039's boundary/CI checks, is the enforcement
point).

### 2.4 Why `Catalog` is a plain module, not a process (AC4)

**Decision: plain module. No `GenServer`, no `Agent`, no `Supervisor`, no ETS table,
no process registration.** Justification, matching this project's own established
precedent for exactly this class of decision:

- 0039's own REVIEWER sign-off states this directly: "It should be a plain module,
  not a process (no supervision change)," citing REQ-045 by name in the Decision's
  "Relationship to earlier decisions" section: *"REQ-045 (row-lock engine, empty
  `InstanceSupervisor`) — unaffected. A module is a code boundary, not a process; no
  module gets its own supervisor unless its own design justifies one through the
  normal gates."*
- This mirrors `CLAUDE.md`'s own summary of REQ-045: `Letflow.Engine.create/2` is "a
  plain transactional context module... with concurrency arbitrated by Postgres row
  locks, not a supervised process per instance," and `Letflow.InstanceSupervisor`
  "exists but is deliberately empty." `Catalog` sits in the same idiom: its data
  (the module list) is fixed at compile time via `Application.compile_env`, there is
  no runtime mutation, no concurrent-write hazard, and therefore no reason for a
  process boundary, ETS table, or ownership question a process would introduce.
- AC4 makes this a directly checkable acceptance criterion, not just a design
  preference: `git grep -n "GenServer\|Agent.start\|Supervisor" -- lib/letflow/modules/`
  must return no hits. This design's `Catalog` (§2.1–§2.3) introduces none of those
  three, by construction — every function above is a pure read over
  `Application.compile_env`'s already-compiled value.

---

## 3. Manifest validation — six invariants (AC3)

### 3.1 What runs the validation, and where

A test (not application code) — per D4's own wording, "a test fails otherwise," and
the requirement text's "Manifest validation, run over every Catalog module by a
test." This is a `test/letflow/modules/` test file (exact path/name is
TEST-DESIGNER's call, WF-02 Step 4 — not fixed by this design) that:

1. Calls a validation function against each of six deliberately-bad **inline**
   manifests (constructed directly in the test, not registered in `Catalog`/config)
   and asserts each fails with a **named** error (AC3: "fails with a named error for
   each of six... deliberately bad inline manifests").
2. Calls the same validation function against every manifest `Catalog.entry_modules/0`
   actually returns (i.e. the fixture module in the test env, §4) and asserts `:ok`
   for each (AC3: "the same validation returns `:ok` for every module the Catalog
   lists").

The validation function itself is ordinary application code (it can live in
`Letflow.Modules.Module` as a `validate/1`-shaped helper, or in `Catalog`, or as a
private test helper called only from the test — REQ-400's text does not mandate a
call site, and no acceptance criterion names one; CODE-DESIGNER leaves this as an
open question, §9 item 2, since it affects whether the six rules are enforceable
outside a test run e.g. at `Catalog` boot). Whichever module hosts it, its shape is:

```
@spec validate(manifest()) :: :ok | {:error, {rule_name :: atom(), detail :: term()}}
```

— a single function returning `:ok` or a **named** error (`rule_name` distinguishes
which of the six rules failed, satisfying AC3's "fails with a named error" for each
case), taking the manifest under test plus (implicitly, via `Authorization.roles/0`/
`permissions/0` and `Catalog.entry_modules/0`) the ambient core/registered-module
context each rule needs.

### 3.2 The six rules, exact semantics

For a manifest `m` under validation, with `known_ids` = the set of every registered
module's `manifest.id` (from `Catalog.entry_modules/0`, **including** `m` itself when
`m` is one of the registered modules — a module's own id counts as "registered" for
its own `depends_on`/uniqueness checks):

1. **`role_grants` keys ⊆ `Authorization.roles/0`.** Every key of `m.role_grants`
   must be a member of `Letflow.Api.Authorization.roles/0`'s current atom list.
   Violation: a `role_grants` key naming a role that does not exist (e.g.
   `:NOT_A_ROLE`). Named error suggestion: `{:unknown_role, role_atom}`.
2. **Granted atoms ⊆ the module's own `permissions`.** Every atom appearing in any
   value-list of `m.role_grants` must also appear in `m.permissions`. A module
   cannot grant a permission it did not itself declare. Violation: a `role_grants`
   value containing an atom absent from `m.permissions`. Named error suggestion:
   `{:ungranted_permission_declared, permission_atom}`.
3. **No `m.permissions` atom collides with a core permission.** No atom in
   `m.permissions` may also appear in `Letflow.Api.Authorization.permissions/0`'s
   *core* list — i.e. the list `Authorization.permissions/0` returns as of this
   requirement (REQ-400 lands before REQ-401 wires the Catalog into
   `Authorization.permissions/0`, so at REQ-400's own test-run time this is simply
   `Authorization.permissions/0`'s existing, unmodified return value; the rule's
   *intent*, matching D4's wording exactly — "no module permission may collide with
   a core permission" — continues to hold after REQ-401 lands because REQ-401 does
   not remove any core atom, it only appends module atoms, so the core-atom set this
   rule checks against is a stable subset regardless of when the test runs).
   Violation: a module declaring, e.g., `:InstancesRead` in its own `permissions`.
   Named error suggestion: `{:core_permission_collision, permission_atom}`.
4. **Every `depends_on` id is registered.** Every string in `m.depends_on` must be a
   member of `known_ids`. Violation: a `depends_on` entry naming an id no registered
   module has as its `manifest.id`. Named error suggestion:
   `{:unknown_dependency, module_id_string}`.
5. **Module ids are unique.** Across every manifest `Catalog.entry_modules/0`
   returns, no two share the same `manifest.id`. This rule is necessarily checked
   across the **whole registered set**, not a single manifest in isolation — the
   test's six-bad-manifest case for this rule constructs two inline manifests
   sharing one id and asserts the validation (run over that pair, or over the pair
   appended to the real registered set, TEST-DESIGNER's call) fails. Named error
   suggestion: `{:duplicate_module_id, module_id_string}`.
6. **Every `route_policies` permission is in the module's own `permissions`.** For
   every `{_method, _path_pattern, permission}` tuple in `m.route_policies`,
   `permission` must appear in `m.permissions` — mirrors rule 2's shape but for
   route policies instead of role grants. Violation: a `route_policies` entry naming
   a permission atom the module never declared. Named error suggestion:
   `{:undeclared_route_permission, permission_atom}`.

Rules 1, 2, 3 and 6 are single-manifest checks (need only `m` plus ambient
`Authorization.roles/0`/`permissions/0`); rules 4 and 5 are set-relative checks (need
`known_ids`/the full registered list). This distinction is noted for TEST-DESIGNER
and ELIXIR-DEV, not enforced as a structural split in this design — a single
`validate/1` (or `validate/2` taking the known-id set explicitly) satisfying all six
in one call is equally acceptable; open question §9 item 2 covers the exact function
boundary.

---

## 4. `Letflow.Modules.Fixture` — the test-only fixture module

### 4.1 File placement

`test/support/modules/fixture/fixture.ex`, defining `Letflow.Modules.Fixture` — the
entry-module file placement mirrors D3's real-module rule (`lib/letflow/modules/<id>/<id>.ex`)
one directory level under `test/support/modules/` instead of `lib/letflow/modules/`.
Compiled only in `:test` env via the existing `elixirc_paths(:test), do: ["lib",
"test/support"]` (`mix.exs:20`, §0) — no `mix.exs` change needed, since
`test/support/` is already in that path list.

### 4.2 What it implements (`@behaviour Letflow.Modules.Module`)

- **`manifest/0`** returns a manifest (§1.3's shape) with:
  - `id: "fixture"`, `version` some literal string (e.g. `"0.1.0"`, exact value not
    acceptance-criterion-bearing).
  - `depends_on: []`.
  - `pack: nil` (requirement text, explicit).
  - `permissions: [:FixtureRead]` — one permission atom of the fixture's own,
    matching the requirement text's example (`:FixtureRead` is literally the atom
    used in the requirement text's own `route_policies` example, so this design
    reuses it rather than inventing a different name).
  - `role_grants: %{TASK_WORKER: [:FixtureRead]}` — "granted to one existing role"
    (requirement text). `TASK_WORKER` is chosen as a plain, already-existing,
    non-`PLATFORM_ADMIN` role (`Authorization.roles/0`, §0) so the fixture's
    `role_grants` test coverage exercises the non-catch-all path REQ-401 will build;
    ELIXIR-DEV may pick a different existing role if `TASK_WORKER` turns out
    unsuitable for an unrelated reason — no acceptance criterion names the specific
    role, only that it must be "one existing role."
  - `required_roles: []` (advisory, unused — §1.3).
  - `settings_schema`: a minimal JSON-Schema-shaped map declaring at least one named
    property and `"additionalProperties": false` at its top level (or this
    codebase's equivalent "no undeclared keys" shape, confirmed against
    `JsonSchemaShape`'s own supported vocabulary at implementation time, §0) — e.g.
    in prose: an object schema with one string property (name TBD by ELIXIR-DEV,
    e.g. `"greeting"`) and `additionalProperties: false`. This is the exact value
    REQ-414 depends on existing; REQ-400 itself runs no test *against* this schema
    beyond confirming the manifest as a whole passes the six validation rules
    (§3, none of which inspect `settings_schema`'s internals).
  - `route_policies: [{"GET", "/items/:id", :FixtureRead}]` — "a one-route `router/0`
    with a matching `route_policies` entry for that route" (requirement text),
    reusing the requirement text's own example tuple verbatim.
- **`router/0`** returns a `Plug.Router`-implementing module (e.g.
  `Letflow.Modules.Fixture.Router`, defined alongside `Fixture` under the same
  `test/support/modules/fixture/` directory) exposing exactly one route matching
  `route_policies`' single entry: `GET /items/:id` (relative to the module's own
  mount, which REQ-400 does not mount — §7). This design does not specify the
  route's handler body (implementation code, forbidden) beyond "returns some
  response identifying the fixture route was reached" — sufficient for REQ-403/404
  to prove routing later; REQ-400 itself does not test this router being mounted or
  reachable over HTTP (no acceptance criterion asks for that — routing/mounting is
  REQ-403/404, §7).
- **`on_install/2`** — receives `prefix` and `settings`, and "writes an observable
  marker (e.g. returns `:ok` after a tenant-scoped insert the test can read back)"
  (requirement text). REQ-400 does not mandate a specific table — the simplest
  compliant shape is inserting a row into an existing, already-tenant-scoped test
  table the test suite can already query (or a new minimal test-only table/schema
  under `test/support/`, ELIXIR-DEV's call), scoped by `prefix` per INV-1 (§6),
  returning `:ok`. REQ-400 does not call `on_install/2` from any real install
  transaction (REQ-402 owns that) — REQ-400's own test coverage (if any exercises
  this callback directly) calls it standalone, asserting the marker becomes
  observable and `:ok` is returned. No acceptance criterion under REQ-400 explicitly
  requires a test invoking `on_install/2` (AC1–AC4 as read, §8) — its presence
  satisfies the requirement text's BUILDS §4 wording; whether TEST-DESIGNER adds a
  direct unit test for it is TEST-DESIGNER's call, not blocked by anything here.

### 4.3 Registration — test env only

`config/test.exs` gains `config :letflow, :modules, [Letflow.Modules.Fixture]`
(exact line placement near the file's other `config :letflow, ...` entries, §0 —
no acceptance criterion constrains placement). **Not** added to `config/config.exs`
or any other env file — AC2's own wording states the fixture is the Catalog's list
"in the test env," and BUILDS §5 states `config/config.exs` registers `[]`.

---

## 5. `config/config.exs` — `[]` in this phase (AC2)

`config/config.exs` gains `config :letflow, :modules, []` — an empty list. No real
module exists yet; REQ-408 (P2, not this requirement) is what first appends a real
entry (`Letflow.Modules.Exam`). AC2's own checkable clause —
`` `git grep -n "config :letflow, :modules" config/config.exs` shows the list is `[]` ``
— is satisfied by this single line. `Catalog.entry_modules/0` therefore returns `[]`
in `:dev`/`:prod` env and `[Letflow.Modules.Fixture]` in `:test` env, by ordinary
Mix config-env layering (`config/test.exs` overrides `config/config.exs`) — no new
mechanism, the same layering every other `config :letflow, ...` key in this codebase
already uses.

---

## 6. Security relevance (explicit statement, per this task's instruction)

**No SECURITY-REVIEWER gate is triggered by REQ-400 itself**, for the following
checked reasons — named explicitly rather than silently assumed:

- **No tenant-data path is opened.** `Catalog` reads only compile-time application
  config (§2.2); it issues no `Repo` query, no HTTP response, and mounts no route
  (`router/0`'s mounting is REQ-403's job, out of scope here, §7). There is no new
  `Plug` pipeline stage and no new response shape a tenant-scoped request could
  observe.
- **`on_install/2`'s `prefix` parameter is INV-1-shaped, but unused in this
  requirement.** The callback's signature exists (§1.2) so the *type* is correct
  ahead of REQ-402, but REQ-400 does not call it from any real install transaction —
  the only call site in REQ-400's own scope is the fixture's own
  self-test/demonstration (§4.2), not a tenant request path. The load-bearing INV-1
  check (does the real install transaction thread `prefix` correctly into
  `on_install/2` and does `on_install/2` actually scope its own writes by it) applies
  to **REQ-402**, not this requirement — flagged here so ORCH/REQ-402's own design
  does not skip it on the mistaken assumption REQ-400 already covered it.
- **No new permission is enforced yet.** `:ModulesManage` and the
  `role_allows?/2`/`endpoint_policy_key/2` Catalog fallback are REQ-401's scope
  (§7). REQ-400's manifest-validation rules (§3) are static/test-time checks over
  in-memory data, not runtime authorization decisions.
- **If this reasoning is wrong** — e.g. if CODE-DESIGN-VALIDATOR or REVIEWER finds a
  path by which `Catalog`'s compile-time list becomes attacker-influenced, or finds
  `on_install/2`'s signature itself insufficient for INV-1 once REQ-402 calls it —
  that should be raised as a blocking finding on this design, not silently waved
  through by a later requirement's SECURITY-REVIEWER gate discovering it late.

---

## 7. Explicitly out of scope (restated from REQ-400's own text)

- **Authorization wiring** — `Authorization.permissions/0`/`role_allows?/2`/
  `endpoint_policy_key/2` consuming `Catalog` at all. REQ-401.
- **Persistence** — `tenant_modules` table, `Letflow.Modules.Installs`,
  `Letflow.Modules.TenantModule` schema. REQ-402.
- **HTTP** — mounting any `router/0` under `/api/v1/modules/<id>`, the install/list
  routes. REQ-403/404.
- **The boundary check** — `mix letflow.check_boundaries`, the ESLint
  `no-restricted-imports` rule. REQ-405.
- **Uninstall** — explicitly deferred by 0039 D5 itself ("No uninstall in S11") and
  restated as an open item in the stage file; REQ-400 defines no uninstall-adjacent
  shape.
- **Exam code migration** — no file under `lib/letflow/exam/` moves; 0039's P2 phase
  (REQ-408 and neighbors), not P1.
- **`settings_schema` enforcement against a real settings write** — REQ-414.

---

## 8. Acceptance-criteria traceability

| # | REQ-400 acceptance criterion (as written in `docs/requirements.yaml`) | Design section(s) |
|---|---|---|
| AC1 | `Letflow.Modules.Module` defines `@callback manifest/0`, `@callback router/0`, `@callback on_install/2`; `router/0`/`on_install/2` in `@optional_callbacks`; verified via `behaviour_info(:callbacks)`/`behaviour_info(:optional_callbacks)` | §1.2 |
| AC2 | `Catalog` returns `[Letflow.Modules.Fixture]` in test env, looks it up by id string; `config/config.exs`'s list is `[]` | §2.2–§2.3 (`entry_modules/0`, `fetch/1`), §4.3, §5 |
| AC3 | Manifest-validation test fails with a named error for each of six deliberately-bad inline manifests, and returns `:ok` for every module the Catalog lists | §3 (full: 3.1 test shape, 3.2 the six rules) |
| AC4 | `git grep -n "GenServer\|Agent.start\|Supervisor" -- lib/letflow/modules/` returns no hits — Catalog is a plain module | §2.4 |
| AC5 (`mix letflow.check` passes, real output quoted) | Not a design-section concern — TEST-RUNNER's/ELIXIR-DEV's job at WF-02 Step 5/6; no design decision needed here. Note: `mix letflow.check_boundaries` (REQ-405) does not exist yet at REQ-400's own implementation time, so `mix letflow.check`'s current alias set (confirm exact composition at implementation time) is what AC5 refers to, not a boundary check this requirement doesn't build. | n/a |

The fixture module (§4) is also the direct subject of §3's "returns `:ok` for every
module the Catalog lists" clause and of AC2's lookup-by-id clause — both load-bearing
on §4.2's manifest being fully well-formed against all six §3 rules (TASK_WORKER role
existing, `:FixtureRead` not colliding with any core permission as of REQ-400,
`depends_on: []` needing no registered-id check, one module id so no duplicate, and
`route_policies`' single permission matching `permissions`).

---

## 9. Open questions (do not silently resolve — ELIXIR-DEV/REVIEWER to weigh in)

1. **§1.3, `id` string format.** No acceptance criterion constrains whether module
   ids must be lowercase, hyphen/underscore-free, etc. This design leaves format
   unconstrained beyond uniqueness (§3 rule 5); if a future module's id needs to
   double as a URL path segment safely, that constraint should be added explicitly
   (by whichever requirement first needs it — likely REQ-403's router mounting),
   not silently assumed here.
2. **§3.1, where the `validate/1`-shaped function lives.** Candidates: a function on
   `Letflow.Modules.Module` itself (co-located with the type it validates), a
   function on `Letflow.Modules.Catalog` (co-located with the registered-set
   context rules 4/5 need), or a private helper local to the validation test file
   (simplest, but then no other future caller — e.g. a `mix letflow.modules.check`
   task, if one is ever wanted — could reuse it without duplicating the six rules).
   This design intentionally does not pick one; ELIXIR-DEV's choice does not change
   any acceptance criterion's outcome, since AC3 only requires *a* test exercising
   the six rules, not a particular call-site shape.
3. **§4.2, `on_install/2`'s exact storage target for its "observable marker."**
   Whether it inserts into an existing multi-purpose test-support table or a new
   minimal one is left to ELIXIR-DEV; no acceptance criterion names a table.
4. **§3.2 rule 5's exact call shape for the "duplicate id" bad-manifest case** —
   whether the test constructs two full inline manifests and calls validation
   pairwise, or calls validation with the real registered set plus one intentionally
   colliding inline manifest appended. Either satisfies AC3's "fails with a named
   error"; TEST-DESIGNER's call.
