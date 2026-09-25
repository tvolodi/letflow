# Design: `defmanifest/1` compile-time check — role_grants ⊆ permissions

**Issue:** ISS-0790 / ISS-0806  
**Run ID:** WF03-ISS0806-20260925  
**Requirement source:** pre-announced deferred item in `docs/migration/decisions/0039-platform-module-solution-layering.md` (lines ~333–337)  
**Acceptance criteria:**
1. A compile-time mechanism catches a `role_grants` atom not present in `permissions`
2. Existing runtime `validate/1` behaviour unchanged

---

## §1 — Interface decisions

### §1.1 Option selected

`defmanifest/1` macro added to `Letflow.Modules.Module`.  
Rationale: the simplest mechanism that provides genuine compile-time feedback; no process, no ETS, no runtime overhead; no change to the existing callback contract; opt-in.

### §1.2 Macro signature

```text
defmanifest(fields)
```

`fields` is a keyword list **literal** written at the call site. The caller writes:

```text
defmanifest(
  id: "fixture",
  version: "0.1.0",
  depends_on: [],
  pack: nil,
  permissions: [:FixtureRead],
  role_grants: %{TASK_WORKER: [:FixtureRead]},
  required_roles: [],
  settings_schema: %{ ... },
  route_policies: [{"GET", "/items/:id", :FixtureRead}]
)
```

All values must be **compile-time literals** (atom lists, string literals, literal maps).  
Non-literal values (runtime-computed fields) cannot use `defmanifest` and must continue to use `def manifest/0` directly, deferring to `Catalog.validate/1`.

### §1.3 What the macro expands to

The macro expands to exactly one public function definition:

```text
def manifest() :: Letflow.Modules.Module.manifest()
```

Return value: the keyword `fields` coerced to the `t:Letflow.Modules.Module.manifest/0` map shape, identical in structure to what an author would write by hand in a `def manifest do ... end` body.

The expansion preserves the `@callback manifest/0` contract: modules using `defmanifest` still satisfy the `@behaviour Letflow.Modules.Module` callback check, because the expansion is a valid `def manifest/0`.

### §1.4 Compile-time validation performed during macro expansion

At macro-expansion time (i.e., when the module containing `defmanifest(...)` is compiled), the macro executes the following check:

1. Extract `permissions` from `fields` — a literal list of atoms, e.g. `[:FixtureRead]`.
2. Extract `role_grants` from `fields` — a literal map of `%{role_atom => [permission_atom, ...]}`.
3. For each `{role, perms}` pair in `role_grants`, for each `perm` atom in `perms`:  
   - Assert `perm in permissions`.  
   - If not: raise `CompileError` with the message below.

The check runs **only over literal values present at macro expansion time**. Non-literal expressions (variables, function calls) in the `fields` keyword list are not evaluated at expansion time; modules using such patterns must use `def manifest/0` directly.

### §1.5 `CompileError` message

```text
role_grants atom :<ATOM> is not declared in permissions for module Elixir.<CallerModule>
```

Example for a module `Letflow.Modules.Exam` that uses `:UndeclaredPerm` in `role_grants` but not in `permissions`:

```text
role_grants atom :UndeclaredPerm is not declared in permissions for module Elixir.Letflow.Modules.Exam
```

The calling module's name is obtained via `__CALLER__.module` inside the macro body.

### §1.6 Why `@callback manifest/0` is kept (not removed)

`defmanifest` is **opt-in syntactic sugar**. It is not a replacement for the callback; it is one way to satisfy it.

- Existing modules that implement `def manifest/0` directly (including any test-inline manifests used in `CatalogTest`) continue to work without any change.
- Modules whose manifest values are not all compile-time literals must implement `def manifest/0` directly and rely on `Catalog.validate/1` for runtime enforcement.
- Removing `@callback manifest/0` would break every module that does not use `defmanifest`, which is out of scope.
- `@optional_callbacks` is unchanged.

---

## §2 — Argument type contract (`defmanifest` doc, not `@spec`)

`@spec` does not apply to macros. The `@doc` for `defmanifest/1` in `module.ex` must state:

> **Argument contract:**  
> `fields` must be a keyword list literal at the call site. Required keys and their expected value shapes mirror `t:manifest/0`:
>
> | Key | Expected literal type |
> |---|---|
> | `:id` | `String.t()` literal |
> | `:version` | `String.t()` literal |
> | `:depends_on` | `[String.t()]` literal list |
> | `:pack` | `String.t()` literal or `nil` |
> | `:permissions` | `[atom()]` literal list |
> | `:role_grants` | `%{atom() => [atom()]}` literal map |
> | `:required_roles` | `[String.t()]` literal list |
> | `:settings_schema` | `map()` literal or `nil` |
> | `:route_policies` | `[{String.t(), String.t(), atom()}]` literal list |
>
> If any `role_grants` value atom is absent from `permissions`, a `CompileError` is raised at the call site during compilation. Non-literal values are silently passed through to `manifest/0` (no compile-time check is possible for them; use `Catalog.validate/1` at test time).

---

## §3 — Affected files

### `lib/letflow/modules/module.ex`

**Change:** add `defmacro defmanifest/1`.

- Placed in the `Letflow.Modules.Module` module body, after the existing `@optional_callbacks` declaration.
- Annotated with `@doc` describing the argument contract (§2) and the `CompileError` condition (§1.5).
- No existing declaration in this file is removed or modified.
- The `@callback manifest/0`, `@type manifest()`, `@type route_policy()`, and `@optional_callbacks` declarations are untouched.

**Public interface addition (signatures only):**

```
defmacro defmanifest(fields) :: Macro.t()
```

Expansion output: `def manifest() :: Letflow.Modules.Module.manifest()` — a zero-arity public function returning the map built from `fields`.

### `test/support/modules/fixture/fixture.ex`

**Change:** replace `@impl true\ndef manifest do ... end` with `defmanifest(...)` using the same field values.

Purpose: demonstrates opt-in usage and exercises the compile-time check on a known-valid manifest (all `role_grants` atoms are in `permissions`). Must compile cleanly.

`@behaviour Letflow.Modules.Module` and `@impl true` annotations:
- `@behaviour` declaration is kept.
- `@impl true` before `defmanifest` is **not required** (the macro emits `def manifest/0` internally; `@impl true` may optionally be placed immediately before `defmanifest(...)` and the macro should preserve it, but this is implementation detail — design does not mandate it either way). The important thing: the module still satisfies the `@behaviour` contract.

### `lib/letflow/modules/catalog.ex`

**No change.** `validate/1`, `validate/2`, and all six private validation helpers are untouched. See §5.

### `test/letflow/modules/catalog_test.exs`

No changes to existing tests. New tests added (§4) are in this file or a new `test/letflow/modules/defmanifest_test.exs` — the implementing agent chooses the file; either is acceptable.

---

## §4 — What tests prove AC1

### Test 1 — bad atom fails to compile (AC1)

Mechanism: `Code.compile_string/1` compiles a string containing a module that uses `defmanifest` with a `role_grants` value atom not in `permissions`. The test asserts that `Code.compile_string/1` raises `CompileError` (or a subtype — Elixir surfaces macro-expansion errors via `CompileError`).

Minimal test module string to compile:

```text
defmodule Letflow.Test.BadManifestModule do
  @behaviour Letflow.Modules.Module
  import Letflow.Modules.Module, only: [defmanifest: 1]

  defmanifest(
    id: "bad",
    version: "0.0.1",
    depends_on: [],
    pack: nil,
    permissions: [:DeclaredPerm],
    role_grants: %{TASK_WORKER: [:UndeclaredPerm]},
    required_roles: [],
    settings_schema: nil,
    route_policies: []
  )
end
```

Expected `CompileError` message contains `"role_grants atom :UndeclaredPerm is not declared in permissions"`.

### Test 2 — valid manifest compiles cleanly (AC1, positive path)

Mechanism: `Letflow.Modules.Fixture` already uses `defmanifest` after the fixture change in §3. Its inclusion in the test compilation (it is always compiled in `:test` env) serves as the positive-path test. Additionally a `Code.compile_string/1` positive test can confirm no error is raised for a correct `defmanifest` call.

### Test 3 — `defmanifest` module satisfies the `@callback` contract

`Letflow.Modules.Fixture.manifest()` must return the expected map — all existing assertions in `CatalogTest` that call `Letflow.Modules.Fixture.manifest()` continue to pass after the fixture switches to `defmanifest`.

---

## §5 — Existing behaviour preserved (AC2)

`Letflow.Modules.Catalog.validate/1` and `validate/2` are **not modified**.

All six validation rules continue to run exactly as today:

| Rule helper | Rule name | Status |
|---|---|---|
| `validate_role_grants_known/1` | `:unknown_role` | unchanged |
| `validate_granted_permissions_declared/1` | `:ungranted_permission_declared` | unchanged |
| `validate_no_core_permission_collision/1` | `:core_permission_collision` | unchanged |
| `validate_depends_on_registered/2` | `:unknown_dependency` | unchanged |
| `validate_unique_id/2` | `:duplicate_module_id` | unchanged |
| `validate_route_policy_permissions_declared/1` | `:undeclared_route_permission` | unchanged |

`validate_granted_permissions_declared/1` remains the **runtime / second-line** enforcement point. It now fires for:
- Modules using `def manifest/0` directly (first and only enforcement point for those).
- Test-inline manifests passed to `validate/2` directly in `CatalogTest`.
- Any future module whose manifest contains non-literal fields and therefore cannot use `defmanifest`.

`defmanifest` adds a **first-line, earlier** enforcement point for modules whose manifest is entirely literal — it fires at compile time, before any test runs. Both lines coexist; neither replaces the other.

The net effect for module authors is improved **feedback timing** (compile-time error rather than test-time error), not a change in the invariant being enforced or the runtime behaviour of `Catalog`.

---

## §6 — Open questions

None.

All design decisions are fully resolved:
- Macro approach selected over `@before_compile` (see ISSUE-FIXER §step_1_diagnosis.feasibility_assessment — simpler, earlier error, no `use` required).
- `@callback manifest/0` retained — opt-in sugar, not a replacement.
- Error message wording fixed (§1.5).
- Non-literal manifest policy fixed (§1.3 / §2 — pass-through, defer to `Catalog.validate/1`).
- Fixture is the demonstration site (§3).
- No new module type alias is introduced (a bare `atom()` rename to `declared_permission()` was assessed as insufficient by ISSUE-FIXER and is confirmed insufficient here — it provides no structural enforcement).
