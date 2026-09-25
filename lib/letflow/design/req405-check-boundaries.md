# Design — REQ-405: `mix letflow.check_boundaries`

**Requirement:** REQ-405 — P1. `mix letflow.check_boundaries`: xref-based module boundary check, wired into `mix letflow.check`.  
**Decision basis:** `docs/migration/decisions/0039-platform-module-solution-layering.md` §D3 (backend boundary check).  
**Artefact type:** Design only — no implementation code.  
**Code-Designer:** CODE-DESIGNER / WF02-REQ405-20260925

---

## §1 — Module structure

### §1.1 New file

**`lib/mix/tasks/letflow.check_boundaries.ex`** — implements `Mix.Task`.

Module name: `Mix.Tasks.Letflow.CheckBoundaries`  
Shortdoc: `"Enforces D3 module boundary rules (0039) via xref file-level edges"`

No new hex dependency. `mix xref graph --format plain` is a built-in Mix command; `System.cmd/3` is Erlang/OTP stdlib. `Letflow.Modules.Catalog` is already compiled into the project — no `app.start` requirement needed (its data is `compile_env`-baked, not runtime-fetched).

### §1.2 Public function signatures

```
@spec run([String.t()]) :: :ok
```
Implements `Mix.Task`. Entry point called by `mix letflow.check_boundaries`.  
- Shells out to `mix xref graph --format plain` via `System.cmd("mix", ["xref", "graph", "--format", "plain"], stderr_to_stdout: false)`.
- Parses xref output into edge list `[{source_path :: String.t(), target_path :: String.t()}]` via `parse_xref_output/1`.
- Builds `depends_on_map` from `Letflow.Modules.Catalog.all_manifests/0` via `build_depends_on_map/1`.
- Calls `classify_edge/2` for every edge; collects violations.
- If no violations: prints OK summary, returns `:ok`.
- If any violations: prints each offending edge (one per line, format `"VIOLATION: <source> -> <target> (<reason>)"`), then calls `Mix.raise/1` with a summary count.

```
@spec parse_xref_output(String.t()) :: [{String.t(), String.t()}]
```
Pure. Parses the plain-text tree emitted by `mix xref graph --format plain` into a flat list of `{source, target}` pairs.  
**Format contract:** Each non-indented line is a source file path. Lines indented by one or more spaces are target paths that source references (may carry a suffix annotation like `" (compile)"` or `" (runtime)"` — strip everything from the first `" ("` to end when present). A line that is entirely whitespace is skipped.  
Returns `[]` on empty or blank input; never raises.

```
@spec build_depends_on_map([Letflow.Modules.Module.manifest()]) :: depends_on_map()
@type depends_on_map :: %{String.t() => [String.t()]}
```
Pure. Converts the flat manifest list into `%{manifest.id => manifest.depends_on}`. Used to feed `classify_edge/2` at call time.

```
@spec classify_edge({String.t(), String.t()}, depends_on_map()) :: :ok | {:violation, String.t()}
```
Pure classification function. Stateless; takes one edge and the pre-built depends_on map. Returns `:ok` or `{:violation, reason}`.  
Unit-testable with synthetic edge lists — no side effects, no I/O.  
Full classification algorithm: see §2.

```
@spec classify_edges([{String.t(), String.t()}], depends_on_map()) :: [:ok | {:violation, String.t()}]
```
Maps `classify_edge/2` over a list of edges; returns results in the same order. Convenience wrapper used by `run/1` to collect all violations in one pass before printing.

### §1.3 Private helpers (signatures only)

```
@spec path_in_module_subdir?(String.t()) :: boolean()
```
Returns `true` iff `path` matches `lib/letflow/modules/<id>/<rest>` where `<id>` is a non-empty path component (a module's own subdirectory) and `<rest>` is at least one more path component. Returns `false` for files directly at `lib/letflow/modules/<name>.ex` (one level, core mechanism files).

```
@spec module_id_from_path(String.t()) :: String.t()
```
Extracts the first path component after `lib/letflow/modules/`. Pre-condition: caller guarantees `path_in_module_subdir?(path)` is true. Example: `"lib/letflow/modules/exam/session.ex"` → `"exam"`.

### §1.4 No new `@requirements` declaration

`Letflow.Modules.Catalog.all_manifests/0` → `entry_modules/0` → `@modules` (a `compile_env`-baked constant, not a runtime ETS/process lookup). No `app.start` is required for this call. The Mix task compiles and loads the project's modules as part of normal task dispatch; calling a function on `Letflow.Modules.Catalog` in `run/1` is safe after compilation without an explicit `@requirements` annotation.

---

## §2 — Edge classification rules (D3)

### §2.1 Scope gate (applied first, before any boundary check)

An edge `{source, target}` is **out of scope** and immediately returns `:ok` if either:
- `source` does NOT start with `"lib/"` — edges from outside `lib/` are not checked (test harness, generated files, etc.).
- `source` starts with `"test/support/"` — explicitly excluded per REQ-405 scope.

Only edges with `source` under `lib/` proceed to classification.

### §2.2 Classification rules (applied in order, first match wins)

**Rule 0 — Target not in a module subdir → `:ok`**  
If `path_in_module_subdir?(target)` is false, no boundary is crossed regardless of source. Return `:ok`.

**Rule 1 — Sanctioned importer exception → `:ok`**  
If `source == "lib/letflow/modules/catalog.ex"`, return `:ok`. `Letflow.Modules.Catalog` is the one core file D3 explicitly permits to reference files inside a `lib/letflow/modules/<id>/` subdirectory (it learns the module list here).

**Rule 2 — Source is in a module subdir: intra-module → `:ok`**  
If `path_in_module_subdir?(source)` AND `module_id_from_path(source) == module_id_from_path(target)`: same-module reference. Return `:ok`.

**Rule 3 — Source is in a module subdir: authorized cross-module → `:ok`**  
If `path_in_module_subdir?(source)` AND `module_id_from_path(target) in Map.get(depends_on_map, module_id_from_path(source), [])`: return `:ok`.

**Rule 4 — Source is in a module subdir: unauthorized cross-module → VIOLATION**  
If `path_in_module_subdir?(source)` AND not Rule 3: return `{:violation, "unauthorized cross-module: lib/letflow/modules/#{src_id}/ → lib/letflow/modules/#{tgt_id}/ (#{tgt_id} not in #{src_id}'s depends_on)"}`.

**Rule 5 — Source is outside all module subdirs: outsider imports module → VIOLATION**  
At this point: target is in a module subdir, source is under `lib/`, source is not `catalog.ex`, source is not in any module subdir. Return `{:violation, "boundary violation: #{source} → #{target} (only lib/letflow/modules/catalog.ex may reference module-subdir files)"}`.

### §2.3 The five test cases for AC1 (plus the scope rule)

| # | Source | Target | `depends_on_map` | Result | Rule |
|---|--------|--------|-----------------|--------|------|
| 1 | `lib/letflow/routers/x.ex` | `lib/letflow/modules/m/y.ex` | `%{}` | **VIOLATION** (outsider imports module) | Rule 5 |
| 2 | `lib/letflow/modules/catalog.ex` | `lib/letflow/modules/m/m.ex` | `%{}` | **OK** (sanctioned importer) | Rule 1 |
| 3 | `lib/letflow/modules/installs.ex` | `lib/letflow/modules/catalog.ex` | `%{}` | **OK** (target not in a module subdir) | Rule 0 |
| 4 | `lib/letflow/modules/a/x.ex` | `lib/letflow/modules/b/y.ex` | `%{"a" => []}` | **VIOLATION** (b not in a's depends_on) | Rule 4 |
| 5 | `lib/letflow/modules/a/x.ex` | `lib/letflow/modules/b/y.ex` | `%{"a" => ["b"]}` | **OK** (authorized cross-module) | Rule 3 |
| 6 | `test/support/z.ex` | `lib/letflow/modules/m/y.ex` | `%{}` | **OK** (source excluded from scope) | Scope gate |

Case 3 note: `lib/letflow/modules/catalog.ex` is a core mechanism file (one level, no subdir). `path_in_module_subdir?("lib/letflow/modules/catalog.ex")` returns `false`. So Rule 0 fires (target not in a module subdir) and returns `:ok`. This correctly captures "core → core is fine" — both `installs.ex` → `catalog.ex` and `module.ex` → `catalog.ex` pass through Rule 0.

### §2.4 Intra-module reference (not explicitly in AC1 but implied)

`lib/letflow/modules/a/x.ex` → `lib/letflow/modules/a/y.ex` with any `depends_on_map` → **OK** (Rule 2). Unit test should cover this as a non-violation guard.

---

## §3 — @spec annotations

```elixir
@type depends_on_map :: %{String.t() => [String.t()]}

@spec run([String.t()]) :: :ok

@spec parse_xref_output(String.t()) :: [{String.t(), String.t()}]

@spec build_depends_on_map([Letflow.Modules.Module.manifest()]) :: depends_on_map()

@spec classify_edge({String.t(), String.t()}, depends_on_map()) :: :ok | {:violation, String.t()}

@spec classify_edges([{String.t(), String.t()}], depends_on_map()) :: [:ok | {:violation, String.t()}]
```

Private helpers:

```elixir
@spec path_in_module_subdir?(String.t()) :: boolean()
@spec module_id_from_path(String.t()) :: String.t()
```

Error shape: `{:violation, reason :: String.t()}` where `reason` is a human-readable single-line string naming the offending edge and which rule was violated.

---

## §4 — mix.exs alias update

### §4.1 Insertion slot

The `"letflow.check_boundaries"` step must be inserted in `mix.exs`'s `"letflow.check"` alias immediately **after** `"compile --warnings-as-errors"` and immediately **before** `"letflow.check.test"`.

Rationale: boundary violations are pure structural checks on compiled code; they must run after compilation so xref has complete call-graph information. They must run before the full test suite so that a boundary violation reports in seconds without waiting for the test run.

Before (current alias tail):
```
"compile --warnings-as-errors",
"letflow.check.test"
```

After (updated alias tail):
```
"compile --warnings-as-errors",
# REQ-405: D3 backend boundary check (xref-based module boundary enforcement).
# Must run after compile (xref needs fully compiled call graph) and before
# check.test (fail fast on boundary violations without waiting for the test run).
"letflow.check_boundaries",
"letflow.check.test"
```

### §4.2 T-ALIAS-SLOT test update

The existing `T-ALIAS-SLOT` test pattern (established by ISS-0258 in `test/mix/tasks/letflow_check_deferral_staleness_test.exs`) uses relative-index assertions. ELIXIR-DEV must add a parallel `T-ALIAS-WIRED` / `T-ALIAS-SLOT` pair to the boundaries task's own test file (`test/mix/tasks/letflow.check_boundaries_test.exs`) in a `describe "the letflow.check alias wiring (AC4)"` block:

**T-ALIAS-WIRED assertion:**  
`assert "letflow.check_boundaries" in aliases`

**T-ALIAS-SLOT assertions:**
```
assert at.("compile --warnings-as-errors") < at.("letflow.check_boundaries")
assert at.("letflow.check_boundaries") < at.("letflow.check.test")
```

Where `at = &Enum.find_index(aliases, fn step -> step == &1 end)` and `aliases = Mix.Project.config()[:aliases][:"letflow.check"]`.

---

## §5 — Test structure

### §5.1 Test file

`test/mix/tasks/letflow.check_boundaries_test.exs`

Two test modules:

**`Mix.Tasks.Letflow.CheckBoundariesTest`** — `use ExUnit.Case, async: true` (pure function tests, no I/O).  
**`Mix.Tasks.Letflow.CheckBoundariesTaskTest`** — `use ExUnit.Case, async: false` (system invocation tests via `System.cmd("mix", ["letflow.check_boundaries"])` or `Mix.Task.run/2`).

### §5.2 Unit tests — AC1 (edge classification, synthetic edges)

All in `Mix.Tasks.Letflow.CheckBoundariesTest`. One `describe "classify_edge/2"` block, one test per case:

| Test name | Edge | `depends_on_map` | Expected |
|---|---|---|---|
| `"VIOLATION: core file outside modules imports module-subdir file"` | `{"lib/letflow/routers/x.ex", "lib/letflow/modules/m/y.ex"}` | `%{}` | `{:violation, _}` |
| `"OK: catalog.ex is the sanctioned importer"` | `{"lib/letflow/modules/catalog.ex", "lib/letflow/modules/m/m.ex"}` | `%{}` | `:ok` |
| `"OK: core mechanism file references another core mechanism file"` | `{"lib/letflow/modules/installs.ex", "lib/letflow/modules/catalog.ex"}` | `%{}` | `:ok` |
| `"VIOLATION: cross-module ref when target not in depends_on"` | `{"lib/letflow/modules/a/x.ex", "lib/letflow/modules/b/y.ex"}` | `%{"a" => []}` | `{:violation, _}` |
| `"OK: cross-module ref when target is in depends_on"` | `{"lib/letflow/modules/a/x.ex", "lib/letflow/modules/b/y.ex"}` | `%{"a" => ["b"]}` | `:ok` |
| `"OK: test/support source is excluded from scope"` | `{"test/support/z.ex", "lib/letflow/modules/m/y.ex"}` | `%{}` | `:ok` |
| `"OK: intra-module reference (same module subdir)"` | `{"lib/letflow/modules/a/x.ex", "lib/letflow/modules/a/y.ex"}` | `%{}` | `:ok` |

Also one `describe "parse_xref_output/1"` block to assert:
- Blank input → `[]`
- A non-indented line with one indented line → one edge pair
- Type annotation `" (compile)"` stripped from target paths
- Entries with no dependencies produce no edges

### §5.3 System invocation test — AC2

In `Mix.Tasks.Letflow.CheckBoundariesTaskTest`:

```
test "exits 0 on the current branch tree (AC2)" do
  {output, exit_code} = System.cmd("mix", ["letflow.check_boundaries"], stderr_to_stdout: true)
  assert exit_code == 0, "expected exit 0; got #{exit_code}. Output:\n#{output}"
  assert output =~ "OK"
end
```

ELIXIR-DEV must quote the real output in the handoff (AC2 requires "real output quoted").

### §5.4 Probe test description — AC3

AC3 is NOT a persisted test. ELIXIR-DEV's procedure:

1. Create a temporary file (e.g., `lib/letflow/probe_boundary_violation.ex`) that aliases or calls a function in a (real or synthetic) `lib/letflow/modules/<id>/` directory.
2. Run `mix letflow.check_boundaries` and confirm exit non-zero with the violating edge named in output.
3. Delete the probe file.
4. Quote the full output (both the violation run and the clean re-run after removal) in `handoffs/WF02-REQ405-20260925/step-02a-elixir-dev.json`'s `result.summary`.

Since no `lib/letflow/modules/<id>/` subdirectory exists on the current branch, ELIXIR-DEV must also create a minimal synthetic module directory (e.g., `lib/letflow/modules/probe/probe.ex`) as part of the probe, remove both the probe module dir and the probe caller before committing.

### §5.5 Alias wiring tests — AC4

In `Mix.Tasks.Letflow.CheckBoundariesTaskTest`, `describe "the letflow.check alias wiring (AC4)"` block:  
`T-ALIAS-WIRED` and `T-ALIAS-SLOT` as specified in §4.2.

---

## §6 — No new dependency (AC5)

`mix xref graph --format plain` is a **built-in Mix task** shipped with Elixir. It requires no new hex package.

`System.cmd/3` is part of Erlang/OTP's `System` module, already in every Elixir project's stdlib.

`Letflow.Modules.Catalog` is an **existing module** in this codebase (REQ-400); calling `all_manifests/0` in the task incurs no new external dependency.

`git diff mix.exs mix.lock` for this requirement shows:
- `mix.exs`: one new alias step (`"letflow.check_boundaries"`) in the `"letflow.check"` list — no `deps` change.
- `mix.lock`: **no change** (no new packages added).

---

## §7 — AC traceability

| Acceptance criterion | Design element(s) |
|---|---|
| AC1: unit tests with synthetic xref edges for all 5 cases | §2.3 (classification table) + §5.2 (test cases) |
| AC2: `mix letflow.check_boundaries` exits 0 on branch tree, output quoted | §1.2 `run/1` (prints OK + returns `:ok`); §5.3 system test |
| AC3: probe test — bad edge → non-zero; probe removed before commit | §5.4 (probe procedure) |
| AC4: `mix.exs` alias updated; `mix letflow.check` passes | §4.1 (insertion slot) + §4.2 (T-ALIAS-SLOT test) |
| AC5: `git diff mix.exs mix.lock` adds no dependency | §6 |

---

## §8 — Open questions

None. All classification rules are fully specified from D3. The `depends_on_map` source (`Letflow.Modules.Catalog.all_manifests/0`) is identified. The alias slot is unambiguous. The probe procedure for AC3 is specified in §5.4.
