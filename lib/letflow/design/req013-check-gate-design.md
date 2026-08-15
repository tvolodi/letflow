# REQ-013 — CI/local-check gate (`zig build check` equivalent)

**Requirement:** `docs/requirements.yaml` REQ-013, stage S0, owner `ELIXIR-DEV`.
**Design author:** `CODE-DESIGNER`, WF02-REQ013.

## 1. What R-Co's `zig build check` does (source of the equivalence)

`zig build check` runs build-with-error-sets-fail-via-exit-code plus `zig fmt --check`
scoped to changed files, as a single gate command with one exit code. REQ-013's
description explicitly maps this to three existing Letflow/mix commands run in
sequence:

1. `mix format --check-formatted`
2. `mix compile --warnings-as-errors`
3. `mix test`

This is a **wrapping** requirement, not a new-capability requirement: all three
commands already exist and already work individually (confirmed: `docs/guides/
backend_developer_guide.md` §4's self-review checklist already lists exactly these
three as manual pre-handoff steps). REQ-013's entire scope is making them one
command with fail-fast propagation. Nothing else. Do not add coverage reporting,
linting (`mix credo`/`mix dialyzer` are not in this project's deps per `mix.exs`),
or any check beyond these three.

## 2. The REQ-003 precedent — summarized from the actual history

Read from `docs/status/requirement_status.yaml`, the full REQ-003 saga (search
`REQ-003`, first entry at line 79, resolved at line 256-284) plus the precedent
artefact `scripts/timed_test.sh` and its own header comment. This was a
**three-attempt saga**, not a single failure:

**Goal:** `mix roco.timed_test` needed to *measure the wall-clock duration of a
genuinely fresh `mix compile`* and append it to `docs/eval/dev-loop-timings.csv`,
distinguishing a true no-op recompile from a real one (the acceptance criterion was
literally "visibly different `compile_ms` between a no-op rerun and a run after
touching a source file").

**Attempt 1** (`lib/mix/tasks/roco.timed_test.ex`, in-process): timed
`Mix.Task.run("compile")` in-process, bracketed with
`System.monotonic_time(:millisecond)`. Result: `compile_ms` was always `0`, even
immediately after `rm -rf _build/test/lib/roco` when a real 10-file recompile
provably happened. **Root cause (ORCH, Docker-verified):** the task's own module
lives under `lib/mix/tasks/`, so Mix must compile the whole `lib/` tree just to
discover/load the task at all, *before `run/1`'s body — including its own
`Mix.Task.run("compile")` call — ever executes*. That in-process call always found
nothing left to do.

**Attempt 2** (same file, subprocess): replaced the in-process call with a `mix
compile` **subprocess** via `System.cmd/3`, on the theory that a fresh subprocess
would have to compile for real. Result: still failed the same acceptance criterion,
for a *deeper* structural reason, proved by direct experiment: `mix roco.timed_test
--help` — which never even calls `run/1` — still fully recompiled the app from
scratch, because **Mix must compile the whole project just to resolve/load ANY task
defined in `lib/mix/tasks/`, before the outer process can even dispatch to that
task's body.** By the time `run/1`'s inner `mix compile` subprocess launched, the
*outer* `mix roco.timed_test` invocation had already forced and absorbed the real
compile cost as a side effect of Mix's own task-resolution bootstrap. Numerically
confirmed: raw `mix compile` after a clean `_build` wipe took 8561ms measured
directly; the identical scenario through `mix roco.timed_test` produced
`compile_ms=1501` — below the no-op noise floor — because the outer process had
already eaten the real cost before the inner subprocess ever started timing.
ORCH's conclusion at this point, stated explicitly: *"This is structural: no code
living inside `lib/mix/tasks/` of this project can ever time this project's own
compile step, regardless of subprocess/in-process design."*

**Attempt 3 (final, shipped):** moved ALL timing logic to `scripts/timed_test.sh`, a
plain POSIX `sh` script invoked **directly** (`sh scripts/timed_test.sh`), never
through any `mix` task. Because the script itself is executed by `sh`, not resolved
via Mix's task-dispatch machinery, its `mix compile` is genuinely the first Mix
invocation in the whole process tree, with nothing having compiled the project
first. This is confirmed by the script's own header comment (`scripts/
timed_test.sh:1-15`) and by ORCH's final Docker verification: 4 true no-op runs gave
`compile_ms` in `[2263, 3153]`; a run right after `rm -rf _build/test/lib/roco` gave
`compile_ms=9898` — over 3x the no-op band, unambiguous signal. `lib/mix/tasks/
roco.timed_test.ex` (and the now-empty `lib/mix/tasks/`, `lib/mix/` directories) were
deleted entirely; the script is the sole real deliverable. Confirmed empirically for
this design: `lib/mix/` does not exist anywhere in the current Letflow tree.

**The precise root cause, restated generally:** any code that lives under a
project's `lib/` tree — including a custom Mix task's own module — only executes
*after* Mix has already compiled `lib/` in order to find and load that code. A
custom Mix task therefore structurally cannot be "the first thing to compile the
project," because loading the task itself already required the compile to have
happened. This makes such a task fundamentally unable to **measure** a fresh
first-compile's timing, because the event being measured (the compile) and the
measurement's start point (the task body running) can never be in the correct
order — the compile always precedes the timer, invisibly, regardless of what the
task's body subsequently does.

## 3. Does the REQ-003 root cause apply to REQ-013? Determination

**No — it does not transfer, and the reasoning is resolvable, not a coin-flip
judgment call.** Two independent lines of evidence both point the same way:

### 3.1 The failure mode is about *measurement*, not about *running a command as one of several steps*

REQ-003's acceptance criterion required a *timing differential* — "visibly different
`compile_ms` between a no-op rerun and a run after touching a source file." The
defect was that the outer Mix task-resolution bootstrap silently performed the real
compile **before the timer started**, so the number written to the CSV was wrong,
not that the compile itself failed to happen or that the process exited with the
wrong code. `mix roco.timed_test` still worked, still exited correctly, still
compiled the project — it just measured the wrong thing, because task-resolution's
side-effect compile happened *outside the span being timed*.

REQ-013 has no timing acceptance criterion at all. Its three criteria are: (1) all
three checks run in sequence with fail-fast exit propagation, (2) a documented
alias-vs-script justification, (3) a demonstrated clean-checkout run with quoted
output. None of these depend on *which specific Mix invocation in the process tree
is "first"* — a check gate that **wants** `mix compile --warnings-as-errors` to run
as one of its three steps anyway is unaffected by an earlier, redundant compile
happening as a side effect of getting to that step, because the gate was going to
run (and pay for) that compile regardless. There is no "wrong number gets written"
failure mode for a pass/fail exit-code gate the way there was for a timing
measurement — a redundant/early compile is at worst a performance non-issue, never
a correctness defect, for this use case.

### 3.2 A Mix alias is not "code under `lib/mix/tasks/`" — the REQ-003 mechanism doesn't apply to it at all, not just "applies harmlessly"

REQ-003's root cause was specific to a **custom Mix task module living under
`lib/mix/tasks/`**: Mix's *task-resolution* step compiles `lib/` to find and load
that module before the task's `run/1` body executes. A `mix letflow.check` **alias**
(via `mix.exs`'s `aliases/0`, the mechanism this project's `mix.exs` already uses
for `ecto.setup`, `ecto.reset`, and `test` — read `mix.exs:39-45`) is a categorically
different mechanism:

- Aliases are plain data returned by `aliases/0` in `mix.exs` itself — project
  configuration Mix reads to build its task-name-to-command-list mapping *before*
  dispatching to any task, not a compiled module under `lib/` that must itself be
  found and loaded via the compile-triggering task-resolution path.
- Empirically confirmed for this exact project: `lib/mix/` does not exist anywhere
  in the current tree (removed as part of REQ-003's own final fix), yet `mix help`
  already lists `ecto.setup`, `ecto.reset`, and `test` as recognized aliases. The
  alias mechanism is proven, in this project, right now, to function with zero files
  under `lib/mix/tasks/` — so there is no module-loading-forces-compile step for an
  alias to be victimized by in the first place.
- Each command an alias expands to (`format --check-formatted`, `compile
  --warnings-as-errors`, `test`) is still a real, independent Mix task invocation
  with its own genuine exit code — Mix's alias runner (`Mix.Task.run/2` per aliased
  entry) does not swallow or reinterpret exit codes, and a nonzero exit from any
  step it runs halts the alias by default (confirmed as the mechanism `test:
  ["ecto.create --quiet", "ecto.migrate --quiet", "test"]` already relies on: if
  `ecto.create`/`ecto.migrate` failed, `mix test` would not silently report green).

So the question "does an outer bootstrap compile happen before my step runs" is not
just *harmless* for REQ-013 (per §3.1) — for the alias path specifically, the
outer-bootstrap-forces-compile mechanism from REQ-003 doesn't exist to trigger at
all, because there is no custom task module under `lib/mix/tasks/` for Mix to
resolve. The REQ-003 concern is fully inapplicable to an alias, on both grounds
independently.

### 3.3 Determination, stated plainly

**A `mix letflow.check` alias is the correct choice, not a standalone shell script.**
This is not a coin-flip between comparably-weighted options — the technical
question the requirement asks CODE-DESIGNER to resolve ("does task-discovery
compile overhead apply here") has a clear answer: **no**, for two independent
reasons (§3.1: the failure mode was about measurement correctness, which REQ-013
doesn't need; §3.2: the failure mechanism was specific to custom task modules under
`lib/mix/tasks/`, which an `aliases/0` entry structurally is not, and this project's
own `mix.exs` already proves the alias path works with zero files under
`lib/mix/tasks/`). Unlike REQ-003 — which genuinely needed code outside `lib/`
because no code under `lib/` could be first — REQ-013 has no "must be first"
constraint at all, and even if it did, an alias was never subject to the mechanism
that broke REQ-003 in the first place.

A standalone `scripts/letflow_check.sh` would still *work* (it's a strictly more
powerful mechanism — nothing here says a script is broken for this use case), but it
would be needless duplication of a mechanism (`aliases/0`) this project's `mix.exs`
already uses for exactly this shape of "run several existing mix tasks in sequence,
fail fast" (see `test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]` —
REQ-013's alias is the same pattern one level up). ELIXIR-DEV should implement the
alias unless it hits a concrete, specific obstacle this design didn't anticipate —
in that case, name the obstacle explicitly in the handoff rather than silently
falling back to a script.

## 4. Design: `mix letflow.check` alias

### 4.1 `mix.exs` change

Add one new entry to the existing `aliases/0` function (`mix.exs:39-45`), alongside
the existing `"ecto.setup"`, `"ecto.reset"`, `test` entries — same list-of-strings
shape already established, no new dependency, no new file beyond `mix.exs` itself:

- **Alias name:** `letflow.check`
- **Command list (in order):**
  1. `"format --check-formatted"`
  2. `"compile --warnings-as-errors"`
  3. `"test"`
- **Fail-fast semantics:** this is Mix's default alias behavior — Mix runs each
  listed command in sequence and stops at the first nonzero exit, propagating that
  exit code as the alias's own exit code. No custom control flow is needed; do not
  hand-roll exit-code checking. This satisfies acceptance criterion 1 (single
  command, all three checks, non-zero exit on first failure) directly from Mix's
  existing alias semantics — the same semantics the project's own `test` alias
  already depends on for its `ecto.create --quiet` / `ecto.migrate --quiet` / `test`
  sequence.
- **Command 3 (`"test"`) reuses the existing `test` alias**, not a raw
  `mix test` invocation — Mix resolves an aliased command name to the other alias
  transparently (this is how `ecto.reset` already reuses `ecto.setup` at
  `mix.exs:42`), so `mix letflow.check`'s third step also gets `ecto.create --quiet`
  + `ecto.migrate --quiet` for free, matching what a developer running `mix test`
  directly would already get. Do not duplicate the DB-setup steps by hand.

### 4.2 No new module, no new script, no new file under `lib/`

Scope is exactly one edit to `mix.exs`'s existing `aliases/0` — nothing else. Do not
add `lib/mix/tasks/letflow.check.ex` (that would resurrect exactly the mechanism
§3.2 shows is unnecessary and structurally different from what's needed here — and
would reintroduce the very `lib/mix/tasks/` category REQ-003 had to remove). Do not
add a `scripts/*.sh` file for this requirement — `scripts/timed_test.sh` exists for
a genuinely different purpose (measuring compile timing, which does need to be
outside Mix) and is not touched by this design.

### 4.3 One-line justification text (acceptance criterion 2)

REQ-013's second acceptance criterion requires "an explicit one-line justification
referencing whether task-discovery compile overhead applies here, same concern
documented in `requirement_status.yaml`'s REQ-003 history." ELIXIR-DEV should place
this as a comment directly above the `"letflow.check"` entry in `aliases/0` (visible
at the point of use, matching how this project documents inline rather than only in
a separate doc). Suggested wording ELIXIR-DEV may adapt:

> `# mix.exs` alias, not a `lib/mix/tasks/` custom task: REQ-003's
> task-discovery-forces-compile problem
> (`docs/status/requirement_status.yaml`) applied only to a module Mix must load
> from `lib/mix/tasks/` before running it, and only broke a *timing measurement*
> that needed a genuinely-first compile to measure — this alias needs neither
> (it wants `mix compile` to run as one of its own steps regardless, and reads
> from `mix.exs` data, never from a compiled `lib/` module), so the concern
> doesn't apply.

This is placed as a code comment (not a docstring for an executable — `aliases/0`
has no moduledoc-style attachment point of its own), satisfying "explicit
justification" without requiring implementation code beyond the one-line `mix.exs`
diff itself.

### 4.4 Demonstration against a clean checkout (acceptance criterion 3)

ELIXIR-DEV must run `mix letflow.check` for real and quote actual output — this
environment (confirmed during this design pass) has `mix`/`elixir` on `PATH`
(`/c/Program Files/Elixir/bin/mix`), so the "no toolchain" fallback note should not
be needed here; if ELIXIR-DEV's own shell differs, fall back to
`docs/anti-patterns.md`'s Docker procedure and say so explicitly, per core-directives'
No Speculation rule. Two demonstration runs are needed to show the fail-fast
behavior is real, not assumed:

1. **Clean/passing run:** `mix letflow.check` on the current `main`-equivalent state
   — expect all three steps to run and the command to exit `0`. Quote the real
   terminal output (format check, compiler output, ExUnit summary line).
2. **Induced-failure run:** temporarily introduce one trivial violation (e.g. an
   unformatted file, or an unused-variable warning under
   `--warnings-as-errors`), rerun `mix letflow.check`, confirm it stops at that
   step with a nonzero exit and does **not** proceed to `mix test` — quote that
   output too — then revert the temporary change before finishing (this is a
   throwaway verification edit, not a committed change; treat it like the
   Docker-verification-cleanup pattern already established in `docs/anti-patterns.md`
   — don't leave the induced failure in the tree).

Quoting both runs (pass and fail-fast) is stronger evidence than the pass-only case
alone and directly demonstrates the "exits non-zero on any failure" half of
acceptance criterion 1, not just criterion 3's "ran against a clean checkout" half.

## 5. Acceptance-criteria mapping

| # | Acceptance criterion | Design element |
|---|---|---|
| 1 | Single command runs format-check + compile-with-warnings-as-errors + test, exits non-zero on first failure | §4.1 — `letflow.check` alias entry, 3 ordered commands, Mix's built-in alias fail-fast semantics (no custom code) |
| 2 | Explicit one-line justification for alias vs. script, referencing REQ-003 correctly | §3 (the resolved determination) + §4.3 (the literal comment text ELIXIR-DEV places in `mix.exs`) |
| 3 | Demonstrated against a clean checkout, actual output quoted (or explicit note if no toolchain) | §4.4 — two runs (pass, induced-fail) with real quoted output; toolchain already confirmed present in this environment |

## 6. Invariants

- The alias must not reorder the three commands — format check first (cheapest,
  catches the most common local mistake fastest), then compile (catches type/logic
  errors before spending time on the test suite), then test (most expensive, only
  worth running if the first two already pass). This mirrors why `zig build check`
  itself is described as fmt-check-then-build in R-Co's README and matches the
  existing `test` alias's own "cheap DB setup before expensive test run" ordering
  logic.
- `mix letflow.check` must not swallow or rewrite any step's exit code. Mix's
  default alias behavior already provides this; do not wrap it in any way (e.g. a
  `System.cmd` shell-out from a custom task) that could obscure it. This is also a
  direct instance of core-directives' "prefer exit-code gates... never make the
  detector stop reporting" rule — the whole point of this requirement is a reliable
  exit-code gate.
- `mix letflow.check` must not introduce any new runtime dependency, config, or
  `lib/` file. Scope is the `mix.exs` alias entry only.

## 7. Cross-module dependencies

None beyond `mix.exs` itself. This requirement touches no `lib/letflow/*.ex` module,
no migration, no Ecto schema. It depends transitively on the three underlying mix
tasks (`format`, `compile`, `test` — the latter itself already an alias per
`mix.exs:43`) continuing to behave as they currently do; no changes to those are in
scope.

## 8. Open questions

None. Unlike REQ-010/011/012 (decision records with genuinely close, roughly
equal-weight options requiring the implementer's judgment call), REQ-013's
alias-vs-script question is resolved by the reasoning in §3 above — a technical
fact about which mechanism the REQ-003 failure mode actually attaches to, not a
preference. If ELIXIR-DEV discovers a concrete obstacle to the alias approach this
design didn't anticipate (e.g. some Mix version constraint under `elixir: "~> 1.14"`
that makes alias-of-an-alias, per §4.1's reuse of `test`, behave unexpectedly), that
is new information and should be flagged explicitly rather than silently reverting
to a script — but it should not be assumed pre-emptively; the current `test` alias
already proves alias-of-an-alias works in this exact project (`ecto.reset` reuses
`ecto.setup` the same way today).
