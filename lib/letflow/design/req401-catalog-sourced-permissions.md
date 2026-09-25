# REQ-401 — Catalog-sourced module permissions and role_grants in `Letflow.Api.Authorization`, plus `:ModulesManage`

Design for REQ-401 (letflow-queue task 790, GH#1775). Implements
`docs/migration/decisions/0039-platform-module-solution-layering.md` D4
("Permissions and who holds them") and the permission half of D5
(`:ModulesManage`). Scope: `lib/letflow/api/authorization.ex` and its two test
files, **plus one small, disclosed cross-module fix to
`lib/letflow/modules/catalog.ex`'s `validate_no_core_permission_collision/1`**
that §1a below makes explicit and necessary (REQ-401 widening
`Authorization.permissions/0` breaks that function's own collision check
unless it is repointed — this is not incidental scope creep, it is the direct,
unavoidable consequence of §2's change, disclosed here rather than left
implicit). No implementation code below — signatures, pattern shapes, and
prose descriptions of control flow only, no real `do...end`/`case`/`with`
syntax; ELIXIR-DEV writes the real clause bodies.

Baseline facts pulled from the real file, not assumed (2026-09-25):

* `lib/letflow/api/authorization.ex` is 1140 lines. `@permissions` list:
  lines 334–373 (37 atoms, ends with `:MembershipsRead`). `@type permission`
  union: lines 227–265 (same 37, same order). `roles/0`: line 377,
  `@roles` at 325–332 (six atoms). `role_allows?/2`: lines 1001–1139.
  `endpoint_policy_key/2`: lines 461–853 (ends with the catch-all
  `def endpoint_policy_key(_method, _path), do: :Unknown` at line 853).
  `:TenantsManage` is declared in `@permissions` at line 349 and granted only
  via `PLATFORM_ADMIN`'s catch-all (line 1005) — there is **no** explicit
  `role_allows?(:PROCESS_DESIGNER, :TenantsManage)`-style clause for it
  anywhere; `:ModulesManage` follows this exact pattern (§3 below).
* `Letflow.Modules.Catalog` (REQ-400, `lib/letflow/modules/catalog.ex`) is a
  plain module (no process) exposing: `entry_modules/0`, `fetch/1`,
  `permissions/0` (union of every registered module's own `:permissions`,
  deduped), `role_grants/1` (union, per role, of every registered module's
  own `role_grants[role]`, deduped, `[]` if none), `all_manifests/0`,
  `validate/1,2`. `config/test.exs` registers `[Letflow.Modules.Fixture]`;
  `config/config.exs` registers `[]`.
* The REQ-400 fixture (`test/support/modules/fixture/fixture.ex`) manifest:
  `id: "fixture"`, `permissions: [:FixtureRead]`,
  `role_grants: %{TASK_WORKER: [:FixtureRead]}`,
  `route_policies: [{"GET", "/items/:id", :FixtureRead}]`. Its `router/0`
  returns `Letflow.Modules.Fixture.Router`, a **plain** `Plug.Router` (not an
  `Letflow.Api.AuthorizedRouter` user — it has no `__authz_routes__/0`).

---

## 1. `role_allows?/2` restructuring — the hard part

### The problem, precisely

Every existing clause already computes a **total boolean function of its own
role** in one of two shapes:

* an unconditional literal (`role_allows?(:PLATFORM_ADMIN, _permission), do: true`);
* a single `permission in [...]` membership test that is `false` for anything
  not listed (`:PROCESS_DESIGNER`, `:PROCESS_OPERATOR`, `:TASK_WORKER`,
  `:CANDIDATE` — one clause each, no separate catch-all needed because
  `in` already returns `false` for a miss);
* `:AGENT_RUNNER` alone has **three** clauses for its one role: two specific
  `true` clauses (`:HelpRead`, `:MembershipsRead`) then an explicit catch-all
  `def role_allows?(:AGENT_RUNNER, _permission), do: false`.

So "append a Catalog-fallback clause after all of these" cannot work as a
single new low-priority clause: for four of the six roles, the *existing*
clause's own head (`role, permission ->` the full 2-arg pattern with a body
that itself returns `false`) already matches and returns before any later
clause is even tried — Elixir tries clauses top-to-bottom and stops at the
first head match, and `role_allows?(:PROCESS_DESIGNER, permission)` (no
guard on `permission`) matches **every** permission, so a clause placed after
it is dead code for that role no matter what it says.

### The mechanism: rename, don't restructure

1. Rename the function that is today's public `role_allows?/2` (all of lines
   1001–1139: the `@doc`, the `@spec`, the introducing
   `def role_allows?(role, permission)` head-only declaration, and all six
   clause bodies verbatim) to a **private** helper, `defp core_role_allows?/2`,
   with **zero change to any clause's head, guard, body, or order**. This
   is a pure rename — every existing role/permission pair that reaches this
   function computes the exact same result it does on `main` today, because
   it is the exact same code.
2. Define a new **public** `role_allows?/2`, one clause, taking `role` and
   `permission` with no guards, whose body is a boolean-`or` of two terms:
   the left term calls `core_role_allows?/2` with the same two arguments;
   the right term checks whether `permission` is a member of
   `Letflow.Modules.Catalog.role_grants(role)`. Signature:
   `@spec role_allows?(role(), permission() | atom()) :: boolean()`. The
   `@doc` moves to this new public function and should state both the
   "ports `roleAllows/2`" provenance note and the Catalog-fallback
   behavior.

### Why no existing pair can change its answer

`or` short-circuits on a truthy left side, so:

* Every pair where `core_role_allows?(role, permission)` is `true` today
  (in particular every `PLATFORM_ADMIN` pair, since its clause is
  `true` unconditionally) is unaffected — `role_allows?/2` returns `true`
  without ever evaluating the Catalog side. This is exactly what the
  requirement text calls out: "`PLATFORM_ADMIN`'s existing catch-all `true`
  ... stays and therefore also covers module permissions."
* Every pair where `core_role_allows?(role, permission)` is `false` today
  falls through to `permission in Catalog.role_grants(role)`. For this to
  preserve today's answer (`false`), `Catalog.role_grants(role)` must never
  contain a `permission` atom that is *also* one of core's own 37 permission
  atoms (§1's baseline list). That invariant is what REQ-400's
  `Letflow.Modules.Catalog.validate/1` rule
  `{:core_permission_collision, permission}` (`validate_no_core_permission_collision/1`,
  `catalog.ex:166-175`) is *supposed* to guarantee — but, as written today,
  that check cannot survive §2's change unmodified. See §1a immediately
  below: this is the load-bearing safety proof for the whole restructuring,
  so it is resolved concretely there, not left as an assumption.
* A pair naming a permission atom that doesn't exist in `@type permission`
  at all *and* isn't declared by any registered module — not reachable
  through any real caller (`evaluate_access/2` only ever calls
  `has_permission?/2` → `role_allows?/2` with a `required_permission/1`
  result, which is always a real permission atom) — is out of scope; no
  test in this requirement exercises it.

### 1a. The circularity §2 creates in `Catalog`'s own collision check, and the fix

**The problem.** `catalog.ex:166-175`'s
`validate_no_core_permission_collision/1` today reads
`core_permissions = Authorization.permissions()`, then rejects a module
manifest if any of its own `:permissions` atoms is a member of that list.
That is correct *only as long as* `Authorization.permissions()` is a
core-only list. §2 of this design redefines `Authorization.permissions/0` to
be `@permissions ++ Catalog.permissions()` — core **plus every registered
module's own permissions, including the module being validated**. Once that
lands, `core_permissions` inside this function is no longer core-only: it
already contains the very module's own atoms (the fixture's `:FixtureRead`
is a member of `Catalog.permissions()`, which is now folded into
`Authorization.permissions()`), so every module manifest trivially "collides
with itself" and `Catalog.validate/1` flips from `:ok` to
`{:error, {:core_permission_collision, ...}}` for every module that has ever
passed, including the fixture. This is a real, currently-passing test this
requirement would otherwise break:
`test/letflow/modules/catalog_test.exs:104-113` ("returns `:ok` for every
module the real Catalog lists"). §1's whole safety argument rests on this
check staying meaningful, so this is not a peripheral detail — it is the
proof the restructuring depends on, and it is broken by this requirement's
own §2 change unless fixed in the same diff.

**The fix — resolution (a): narrow the check to core permissions alone,
disclosed as an explicit cross-module change.**

1. Add a new function to `lib/letflow/api/authorization.ex`, alongside
   `permissions/0`: `core_permissions/0`, returning `@permissions` exactly
   (the closed, core-only 38-atom list — core's own list plus
   `:ModulesManage`, §3 — with **no** Catalog concatenation). This is the
   list `permissions/0` itself used to return before this requirement; it
   still needs a name now that `permissions/0`'s own meaning has widened.
   Signature: `@spec core_permissions() :: [permission()]`.
2. Change `catalog.ex:166-175`'s `validate_no_core_permission_collision/1`
   so its `core_permissions = Authorization.permissions()` line reads
   `core_permissions = Authorization.core_permissions()` instead — the one
   line that changes; the rest of that function (the `Enum.find`/`case`
   shape) is untouched.
3. Add a one-sentence moduledoc/comment note at that call site in
   `catalog.ex` stating why: "`Authorization.permissions/0` now includes
   every registered module's own permissions (REQ-401); this check must
   compare against core's permissions alone, or every module would
   trivially collide with itself." This is exactly the kind of
   cross-module dependency `docs/anti-patterns.md`'s spirit asks to be
   documented at the call site, not left to be rediscovered.

This is disclosed here as an explicit, necessary part of REQ-401's own
change — not hidden inside "changes `authorization.ex` and its tests only."
ORCH/REVIEWER should treat REQ-401's real file list as
`lib/letflow/api/authorization.ex` + its two test files + this one line
(plus comment) in `lib/letflow/modules/catalog.ex`, not the narrower list
the original requirement text states. Flagged in §7 for visibility.

**Why this specific fix, not an alternative.** Two other resolutions were
considered and rejected:

* *Keep `validate_no_core_permission_collision/1` checking against
  `Authorization.permissions/0`, but exclude the manifest under test from
  the comparison set.* Rejected: this would still let module A collide with
  module B's already-registered permissions silently passing as "not a core
  collision" when it plainly should still be rejected as *some* kind of
  conflict — it just moves the bug from "collides with self" to "never
  detects two modules sharing an atom," which §1's safety proof does not
  need but which is a strictly worse validation than resolution (a) for no
  benefit, and it does not match D4's own stated invariant ("a module cannot
  grant a core permission") which is specifically about **core**, not
  inter-module collisions (out of scope for both REQ-400 and REQ-401).
* *Have `role_allows?/2`'s Catalog fallback itself re-check the collision at
  runtime* (e.g. `permission not in @permissions and permission in
  Catalog.role_grants(role)`). Rejected: this duplicates the test-time
  validation as a runtime guard on every single authorization check, adds a
  linear scan of `@permissions` to a function that runs on every request
  once module routes are live (REQ-403+), and still does not fix
  `Catalog.validate/1` itself, which would keep failing for an unrelated
  reason. Resolution (a) is the minimal, single-point fix: it repairs the
  one function whose current behavior actually breaks, and needs no new
  runtime cost anywhere.

### `@spec` widening

`core_role_allows?/2` keeps `@spec role_allows?(role(), permission()) ::
boolean()`'s old body-shape reasoning internally, but the **public**
`role_allows?/2`'s `@spec` must widen its second argument to
`permission() | atom()`, since a Catalog-granted permission (e.g.
`:FixtureRead` in the test env) is typed `atom()` at the Catalog boundary
(D4, restated in `Catalog`'s own moduledoc) — it is not, and must not become,
a member of the closed `@type permission` union. This mirrors the "module
permissions are typed `atom()` at the Catalog boundary" instruction in the
requirement text verbatim.

---

## 2. `permissions/0`'s new composition

`permissions/0`'s body becomes the list-concatenation (`++`) of `@permissions`
(unchanged, core, with `:ModulesManage` appended per §3) on the left and
`Letflow.Modules.Catalog.permissions()` on the right — nothing else in the
function changes. Signature widens to
`@spec permissions() :: [permission() | atom()]` (§1's same Catalog-boundary
`atom()` typing rule applies here too).

* `@permissions` (core, `@type permission()`-typed) is emitted **first**, in
  its existing order, with `:ModulesManage` appended as its new 38th/last
  entry (§3). `Letflow.Modules.Catalog.permissions()` (each atom `atom()`-typed
  at this boundary) is concatenated **after** it, in `Catalog.entry_modules/0`'s
  config order (i.e., whatever order `Catalog.permissions/0` itself produces
  — REQ-401 does not re-sort it).
* No further dedup between the two halves is performed by this function —
  the "no module may declare a core permission atom" invariant (§1) is what
  keeps the two halves disjoint; `permissions/0` itself does not defend
  against a collision a second time.
* The `@doc` above `permissions/0` (currently stating "All thirty-eight...")
  needs updating to state the new count is now composed of two parts: a
  literal core count (39, after `:ModulesManage`) plus
  `length(Letflow.Modules.Catalog.permissions())` — computed, not a second
  hardcoded literal, consistent with the file's existing "computed rather
  than hardcoded" precedent for exactly this failure mode (moduledoc note
  at line 395–398, "eighteen"/"nineteen" going stale).

---

## 3. `:ModulesManage` — the new core permission

Three places, `:TenantsManage`'s exact pattern (cited lines: `:349` in
`@permissions`, `:598` — actually the *grant* pattern for `:TenantsManage` is
its total **absence** from every explicit `role_allows?/2` role clause,
relying solely on `PLATFORM_ADMIN`'s catch-all at line `1005`; there is no
`role_allows?(some_role, :TenantsManage)` clause anywhere to imitate a
*positive* grant from — "same pattern" means "same non-pattern"):

1. `@type permission` union (lines 227–265): append `| :ModulesManage` as the
   new last member, directly after `:MembershipsRead`.
2. `@permissions` list (lines 334–373): append `:ModulesManage` as the new
   last element, directly after `:MembershipsRead`.
3. `role_allows?/2` (inside the now-private `core_role_allows?/2`, §1):
   **no new clause added for any of `:PROCESS_DESIGNER`, `:PROCESS_OPERATOR`,
   `:TASK_WORKER`, `:AGENT_RUNNER`, `:CANDIDATE`** — none of their
   `permission in [...]` lists gains `:ModulesManage`. Only
   `PLATFORM_ADMIN`'s existing unconditional `true` clause grants it. This
   is the literal `:TenantsManage` precedent.
4. `@type endpoint_policy_key` union and `endpoint_policy_key/2` /
   `required_permission/1`: **not touched for `:ModulesManage` in this
   requirement** — no route consumes it yet (REQ-403/415/414 do). Do not
   add a policy-key clause or an identity `required_permission/1` clause
   for it; that would be scope creep ahead of a real consuming route, unlike
   the deliberate "add ahead of consumer" precedents the moduledoc documents
   for `Entities*`/`ExamSession*` (those were minted *with* their permission
   union entry stated as reserved for an already-planned, named, near-term
   consuming router; `:ModulesManage` here is the permission atom only, per
   the requirement's own explicit scope line "any route that uses
   `:ModulesManage`" is OUT OF SCOPE).

---

## 4. `endpoint_policy_key/2` — the `/modules/<id>/<rest>` fallback

### Placement

One new clause, inserted immediately **before** the existing final catch-all
(`def endpoint_policy_key(_method, _path), do: :Unknown`, currently line
853). Every one of the ~140 existing clauses above it keeps its exact
position and body — this is a pure insertion, not a reorder, so no existing
`(method, path)` pair's result changes (AC4's "literal table captured from
main" test is exactly what proves this).

### Match shape

One new clause, matched on a method plus a path of the literal-prefix shape
`"/modules/" <> rest` (binary-prefix pattern match, the same idiom
`"/dlq" <> _rest`/`"/webhooks/subscriptions" <> _rest` already use elsewhere
in this file), placed as the second-to-last clause — immediately before the
existing final catch-all. Its body: split `rest` on the first `/` into at
most two pieces (`module_id` and everything after). When that split yields
two pieces, delegate to the resolution helper (below) with the method, the
module id, and the second piece re-prefixed with a leading `/` (so it reads
exactly like the fixture manifest's own `path_pattern`, e.g. `"/items/:id"`).
When the split yields only one piece — a path of exactly `"/modules/fixture"`
with nothing after it — there is no `<rest>` to resolve at all, and this
clause's body itself is `:Unknown` in that case, matching "no match returns
what an unmatched path returns today." The existing final catch-all clause
stays exactly as-is, after this one.

### Resolution helper

A new private function, arity 3 (method, module id, sub-path), signature
`@spec module_route_permission(String.t(), String.t(), String.t()) :: atom()`.
Its logic is a short-circuiting chain: look the module id up via
`Letflow.Modules.Catalog.fetch/1`; on `{:error, :not_found}`, the overall
result is `:Unknown`. On `{:ok, entry_module}`, read `entry_module.manifest()`
and search its `route_policies` list for the one entry whose method and path
pattern both equal this call's `method`/`sub_path` arguments; if none is
found, the result is `:Unknown`; if one is found, the result is that entry's
own permission atom (the third element of the `{method, path_pattern,
permission}` tuple, per `Letflow.Modules.Module.route_policy/0`'s shape).
Both "unknown module" and "known module, no matching route" collapse to the
same `:Unknown` outcome through this one chain — this is what AC4's
`/modules/does-not-exist/<path>` case exercises.

* Match against `route_policies` is **exact string equality** on
  `(method, path_pattern)` — the same convention every core
  `endpoint_policy_key/2` clause already uses (literal path templates like
  `"/definitions/:id"`, never runtime-substituted ids; confirmed by how
  `authorization_enforcement_test.exs` calls this function with each
  router's own **template**, not a live request path). REQ-401 does not
  build a segment-by-segment `:id`-style matcher — module manifests declare
  their own templates in exactly the form this function is called with.

### `@spec` widening

`endpoint_policy_key/2`'s `@spec` return type must widen the same way
`permissions/0`'s did: `endpoint_policy_key() | atom()` — a module's
`route_policies` permission is Catalog-boundary `atom()`, not a member of
the closed `endpoint_policy_key()` union, by the same D4 typing rule.

### Open question flagged for ELIXIR-DEV / REVIEWER (not resolved here)

`evaluate_access/2` (line 861) unconditionally calls
`required_permission(endpoint)` for any `endpoint` that isn't `:Unknown` or
`:MetricsRead`, and `required_permission/1` (line 902) is today a **closed**
set of clauses over the closed `endpoint_policy_key()` union — it has no
fallback and would raise `FunctionClauseError` if ever called with
`:FixtureRead` (or any other Catalog-sourced atom). REQ-401's own acceptance
criteria never call `evaluate_access/2` with a module-route result (AC4
tests `endpoint_policy_key/2` directly; AC5's enforcement-test extension
only asserts the resolved key is non-`:Unknown`, mirroring
`authorization_enforcement_test.exs`'s existing `real_key != :Unknown`
check, never calling `evaluate_access/2`), so this gap does not block any
of REQ-401's eight ACs. It **will** matter the moment REQ-403 actually
mounts a module's router behind `Letflow.Plugs.Authorize` (which does call
`evaluate_access/2` on every request). Left as an explicit open item for
REQ-403's own design, not silently patched here — the fix is almost
certainly an identity fallback in `required_permission/1` for any atom
`Letflow.Modules.Catalog.permissions/0` currently lists, but that decision
belongs to REQ-403's own design doc, not this one (D4's boundary: REQ-401
touches `authorization.ex`'s permission/role-grant/route-policy-key surface
only, not the runtime enforcement pipeline).

---

## 5. Test additions (per AC — specs only, no test code)

`test/letflow/api/authorization_test.exs`:

* **AC1** — extend (or add alongside) the existing closed-list test at line
  34: assert `Authorization.permissions() ==` a literal core list (the
  current 37 plus `:ModulesManage` appended) `++ Letflow.Modules.Catalog.permissions()`
  — the Catalog half sourced through the real call, never re-hardcoded as a
  second literal (the requirement's own explicit instruction: "sourced
  through the Catalog rather than hard-code a second time"). Separately (or
  in the same test), assert `Letflow.Modules.Fixture.manifest().permissions`
  (i.e. `:FixtureRead`) is a member of `Authorization.permissions()`. Add one
  more assertion alongside it: `Authorization.core_permissions() ==` that
  same literal 38-atom core-only list, with **no** Catalog atoms in it —
  this is what proves §1a's fix actually decoupled the two functions.
* **§1a follow-up (no new AC, but required by the fix itself)** —
  `test/letflow/modules/catalog_test.exs:104-113` ("returns `:ok` for every
  module the real Catalog lists") needs no test-code change, but its
  continuing to pass is the actual proof §1a's `catalog.ex` fix worked; note
  this explicitly for ELIXIR-DEV/TEST-RUNNER as a required regression check
  for this requirement, not merely an incidental side effect. Optionally,
  add one new test in `catalog_test.exs` alongside it: construct an inline
  manifest whose one `:permissions` atom deliberately equals an atom already
  in `Authorization.core_permissions()` (a real core permission, e.g.
  `:DefinitionsRead`) and assert `Catalog.validate/1` still returns
  `{:error, {:core_permission_collision, :DefinitionsRead}}` for it — proving
  the check still catches a genuine core collision after being repointed,
  not just that it stopped false-flagging modules.
* **AC2** — one test iterating `Authorization.roles()`: for the fixture's
  one granted role (`:TASK_WORKER`, read from
  `Letflow.Modules.Fixture.manifest().role_grants` rather than hardcoded, so
  the test does not silently drift if the fixture manifest ever changes) and
  its one permission (`:FixtureRead`), assert
  `role_allows?(:TASK_WORKER, :FixtureRead) == true`; for every other role in
  `Authorization.roles()` except that one and except `:PLATFORM_ADMIN`,
  assert `role_allows?(role, :FixtureRead) == false`; assert
  `role_allows?(:PLATFORM_ADMIN, :FixtureRead) == true`.
* **AC3** — one test iterating `Authorization.roles()`: assert
  `role_allows?(role, :ModulesManage) == (role == :PLATFORM_ADMIN)`.
* **AC4** — two things in one test (or two tests):
  1. `endpoint_policy_key("GET", "/modules/fixture/items/:id") == :FixtureRead`
     (the fixture's own declared method+pattern, prefixed); and
     `endpoint_policy_key("GET", "/modules/does-not-exist/items/:id") == :Unknown`.
  2. A **literal table** of `{method, path, expected_atom}` triples
     transcribed by hand from every existing `endpoint_policy_key/2` clause
     as it stands on `main` right now (the ~140 clauses at lines 464–851 of
     this design doc's baseline read) — not derived from calling the
     function itself (that would be circular and prove nothing) — iterated
     and asserted equal to `Authorization.endpoint_policy_key(method, path)`.
     This is the literal, hand-captured regression proof the AC text
     demands ("every pre-existing core `endpoint_policy_key/2` clause
     returns the same atom as on main"). Practically: this table can be one
     representative `{method, path}` sample per *distinct existing clause*
     (not necessarily every `path in [...]` guard's every member — one
     sample per clause is sufficient to prove that clause's position/body
     survived the insertion unchanged; the point is proving the new clause
     was inserted, not that clause bodies were rewritten, since ELIXIR-DEV
     is instructed not to touch them at all).
* **AC6** — the regression grid: a **literal matrix**, `%{role => %{permission => boolean}}`
  or an equivalent list-of-tuples, over `Authorization.roles()` (six roles)
  crossed with the core `@permissions` list **as it stood on `main` before
  this change** (the 37-atom list transcribed in §2/§3 above — NOT the new
  `permissions/0`, which would include `:ModulesManage` and the Catalog
  atoms and therefore not be "as it stood on main"), asserting
  `Authorization.role_allows?(role, permission) == expected_matrix[role][permission]`
  for every one of the 6×37 = 222 pairs. This is the test that actually
  proves §1's `or`-delegation preserved every old answer, independent of
  the `core_permission_collision` validation argument.
* **AC7** — the existing ISS-0646 test at line 1830 needs **no structural
  change**: it already reads `all_permissions = Authorization.permissions()`
  (now longer, including `:ModulesManage` and `:FixtureRead` in the test
  env) and asserts, for every permission in that live list,
  `role_allows?(:CANDIDATE, permission) == (permission in @candidate_permissions)`.
  For the two new atoms this is `false == false` in both cases
  (`Catalog.role_grants(:CANDIDATE)` is `[]` since the fixture only grants
  `TASK_WORKER`; `core_role_allows?(:CANDIDATE, :ModulesManage)` is `false`
  since `:CANDIDATE`'s clause is the closed six-permission `in` list, §1) —
  so this test passes unchanged, confirming D4's "must pass unchanged in
  meaning" requirement. State this explicitly as a design note so
  ELIXIR-DEV does not go looking for a change to make here.

`test/letflow/api/authorization_enforcement_test.exs`:

* **AC5** — add an enumeration, parallel to the existing per-router
  `describe` block, but keyed on `Letflow.Modules.Catalog.entry_modules/0`
  rather than the file's own `@routers` list: for every entry module whose
  behaviour exports `router/0` (`function_exported?(entry_module, :router, 0)`
  — the fixture does; a future module with no `router/0` at all is
  correctly skipped, since `Module.optional_callbacks` allows it), take
  `entry_module.manifest().route_policies` as the route source (**not**
  `__authz_routes__/0`, which only `Letflow.Api.AuthorizedRouter`-based
  routers expose — the fixture's `Router` is a plain `Plug.Router` and has
  no such function; `route_policies` is the actual mechanism available and
  is exactly what AC5's own probe — "temporarily deleting the fixture's
  `route_policies` entry makes the test fail" — confirms is the intended
  source of truth). For each `{method, path_pattern, _permission}` entry,
  prefix `path_pattern` with `/modules/<manifest.id>` and assert
  `Authorization.endpoint_policy_key(method, prefixed_path) != :Unknown`
  (same shape as the existing file's `real_key != :Unknown` check). Add
  **no** entry to `@allowlist` for this route (explicit instruction in the
  requirement text) — a module route that fails to resolve is a real
  failure, not an allowlist candidate.
* No change to `@routers`/`@mount_prefix`/`@allowlist` themselves — those
  stay scoped to `lib/letflow/routers/` (`AuthorizedRouter`-based) routers,
  per that file's own moduledoc scope.

---

## 6. SECURITY-REVIEWER — required, flagged for ORCH

**Yes, this design needs SECURITY-REVIEWER before REVIEWER.**
`lib/letflow/api/authorization.ex` is the platform's single permission/role
decision surface — its own moduledoc cites INV-2 and INV-5 directly, and
`docs/agents/instructions/security-invariants.md` gates any change to a
tenant-data-decision path. This requirement changes:

* the total set of permissions the platform recognizes (`permissions/0`);
* the total decision function every request's authorization check runs
  through (`role_allows?/2`, restructured via a rename + delegation, not a
  content change, but still the core decision path);
* the path→permission resolution function (`endpoint_policy_key/2`), adding
  a new match arm that, for the first time, resolves an atom that did not
  exist anywhere in this file's own closed unions before compile time (a
  Catalog-sourced `atom()`).

Per `core-directives.md`'s "every producing step has a validating step" and
this repo's existing gate ordering (SECURITY-REVIEWER before REVIEWER for
any tenant-data-path change), ORCH should route REQ-401's implementation
through SECURITY-REVIEWER before REVIEWER, not skip straight to REVIEWER.

---

## 7. Open questions (explicit, not silently resolved)

1. **`required_permission/1` fallback gap** (§4) — real, but out of
   REQ-401's own scope; flagged for REQ-403's design.
2. **AC4's "literal table" granularity** — this design recommends one
   representative sample per existing clause rather than every member of
   every `path in [...]` guard (would be well over 140 assertions
   otherwise); if CODE-DESIGN-VALIDATOR or SECURITY-REVIEWER wants full
   per-guard-member coverage instead, that is a cheap widening, not a
   redesign — flagged rather than assumed.
3. **Doc-count text** — §2 assumes the `@doc` above `permissions/0` states a
   new literal core count (39) plus a computed Catalog term; the exact
   prose is ELIXIR-DEV's call, not fixed here, since the requirement's own
   AC6/AC1 constraints are about the *values*, not this comment's wording.
4. **Requirement text's stated file scope is narrower than the actual
   necessary change** — REQ-401's own description says "Changes
   `lib/letflow/api/authorization.ex` and its tests only." §1a establishes
   that a one-line fix (plus a comment) to `lib/letflow/modules/catalog.ex`
   is *also* required, or a currently-passing REQ-400 test
   (`catalog_test.exs:104-113`) breaks. This is disclosed here rather than
   worked around silently; ORCH/REVIEWER should treat this as a
   requirement-text correction (the actual scope REQ-401 must touch), not
   as ELIXIR-DEV quietly going out of bounds during implementation.
