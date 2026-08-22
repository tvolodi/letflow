# Design: ISS-0227 — remove two write-only fields from `Letflow.SandboxPool`

**Run:** `WF03-ISS0227-20260822` (GH#465, queue task 227) · **Author:** CODE-DESIGNER ·
**Status:** proposed — awaiting CODE-DESIGN-VALIDATOR

**Severity:** MINOR. **Not a recurrence** (ISSUE-FIXER's Step 0.5 registry lookup found no
prior resolved `docs/issues/*.yaml` entry with matching symptoms).

**Verdict up front.** Two fields introduced by ISS-0224 are written and never read:
`provision_op()`'s `owner_pid`, and the `in_flight` record's `schema_name`. Both are exactly
derivable from state the pool already holds for the whole lifetime of the record that carries
them. This change removes both, plus the one private helper that exists only to compute the
second (`op_schema_name/1`, which becomes unused and would therefore break the
warnings-as-errors gate — measured, §3.3). **No invariant changes, no external behaviour
changes, no test changes.** `owner_ref` and the owner-monitor mechanism are untouched.

---

## 0. Sources, and which factual premises this design verified first-hand

### 0.1 Read in full

| Source | Why |
|---|---|
| `lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md` (1903 lines) | the design this change edits; its §5 state shape, §7 step 2, §8.4 INV-SP-A1..A7 and §12 file table are all load-bearing here |
| `docs/agents/instructions/core-directives.md` | mandatory |
| the relevant regions of `lib/letflow/sandbox_pool.ex` (`:150-180`, `:295-322`, `:340-370`, `:475-500`, `:518-600`, `:660-730`, `:865-910`) | the module under change; every line number cited below was re-read at `HEAD` of `fix/WF03-ISS0227-20260822` |

### 0.2 Read in the named scope

- `mix.exs` `:55-70` — the `letflow.check` alias.
- `docs/agents/protocols/GIT_MERGE.md` `:155-175`, `:228-240` — the pre-merge gate commands.
- `test/letflow/sandbox_pool_test.exs` — every `in_flight`, `owner_pid` and `schema_name`
  occurrence (§4).
- `test/letflow/sandbox_pool_call_timeout_test.exs` — grepped in full for all three tokens (§4).
- `test/letflow/definitions/promotion_assertion_rerun_test.exs` `:155-180` (the
  `active_sandbox_id!/1` partial map match and its ISS-0224 comment) plus every `schema_name`
  occurrence (§4).
- `test/specs/ISS-0224.md` — every `in_flight` / `owner_pid` occurrence (§4).
- `lib/letflow/design/iss-0048-sandbox-pool-owner-crash-reclaim.md` `:20-40`, and
  `lib/letflow/design/iss064-orphaned-tenant-schemas-fix.md` `:619-660` — the two existing
  supersede conventions in this repo (§5.1).

### 0.3 Premises verified first-hand (W-numbers, referenced throughout)

Required by `core-directives.md` §"Instruction Precedence" ("this chain governs what you are
told to DO, not what you are told IS TRUE"). ISSUE-FIXER's Step 1 diagnosis was re-derived
here rather than inherited — every W below is my own measurement or my own read, and every one
agreed with the diagnosis.

| W | Premise | Status |
|---|---|---|
| W1 | `owner_pid` exists at exactly three places in `lib/`: the `@typep` field (`:160`), the local binding (`:527`), and the op-literal write (`:535`). The local at `:527` is genuinely read at `:528` by `Process.monitor/1` | **VERIFIED (read + grep)** |
| W2 | No pattern match, guard, or dynamic access ever reads `owner_pid` **off an op**. The only `Map.fetch/get/take/has_key?/pop` call anywhere in the module is `Map.fetch(state.active, sandbox_id)` at `:344` — on `active`, never on an op | **VERIFIED (grep of `Map\.(get\|fetch\|take\|has_key\?\|pop)\(` over the whole module, 1 hit)** |
| W3 | `test/letflow/sandbox_pool_test.exs:420` binds a **local** variable named `owner_pid` for a spawned test process (used at `:443-445` for `Process.monitor` / `Process.exit` / `assert_receive`). It is not the struct field and has no relationship to it | **VERIFIED (read)** |
| W4 | Every `in_flight.<field>` access in the **code** of `lib/` and `test/` is one of `.op`, `.task_ref`, `.task_pid`. **Zero** `.schema_name` | **VERIFIED (measured):** `grep -rohE --include=*.ex --include=*.exs "in_flight[a-z_]*\.[a-z_]+" lib test \| sort \| uniq -c` → **12 hits** — `.op` ×7, `.task_ref` ×4, `.task_pid` ×1. The `--include` restriction is load-bearing, not tidiness: see §4.1 |
| W5 | No map pattern anywhere binds `schema_name` out of an `in_flight` record | **VERIFIED (read of all 32 sites + the two `%{in_flight \| …}` updates at `:958`-equivalent and case 4b)** |
| W6 | `op_schema_name/1` has exactly one call site — `:572`, the `in_flight` literal — and two clause heads at `:592-593`. Nothing else in `lib/` or `test/` names it | **VERIFIED (measured):** `grep -rn "op_schema_name" lib test` → 3 lines, all in `sandbox_pool.ex` |
| W7 | An unused `defp` is a warning, and `mix compile --warnings-as-errors` **exits 1** on it | **VERIFIED (measured, §3.3)** — throwaway mix project in `scratch/iss0227/probeproj/`, this exact two-clause `op_schema_name/1` shape, `EXIT=1`, "Compilation failed due to warnings while using the --warnings-as-errors option" |
| W8 | `elixirc --warnings-as-errors` on a bare `.ex` file emits the same warning but **exits 0** — so an out-of-mix probe is *not* evidence for this gate | **VERIFIED (measured, §3.3)** — recorded because it is the probe an implementer is likely to reach for first, and it would have given the wrong answer |
| W9 | This repo has **no `.github/workflows/`** and no GitHub Actions definition of any kind (`git ls-files` finds none). The warnings-as-errors gate is `mix compile --warnings-as-errors`, run by agents at `GIT_MERGE.md:166` before merge and as step 3 of the `letflow.check` alias (`mix.exs`) | **VERIFIED (read + `git ls-files`)** |
| W10 | Removing `owner_pid` from the op literal at `:535` does **not** orphan the local at `:527` — it is still read at `:528`. No unused-variable warning results | **VERIFIED (read)** |
| W11 | `in_flight.schema_name` is asserted only in `iss0224-…md` §5's `in_flight()` block (`:517-522`, field at `:521`) and the module's state-shape comment (`:312-317`, field at `:316`). §5's field-by-field rationale list has bullets for `db_queue`, `in_flight`, `owner_ref`, `sandbox_id`/`schema_name` **of `provision_op()`**, `task_ref`/`task_pid` and `owner_down?` — **no bullet exists for `in_flight`'s `schema_name`**, so there is no prose rationale to retract, only two shape declarations | **VERIFIED (read of `:462-598`)** |

---

## 1. The defect

ISS-0224 introduced a `db_queue` of ops and an `in_flight` record (`iss0224-…md` §5). Two of
the fields it declared are **write-only**: every code path that could want them either already
holds the same value under a different name, or can compute it in one expression from a field
sitting beside it in the same record.

This is not a correctness bug. It is a maintenance hazard of the specific kind
`docs/anti-patterns.md` exists to catch: a declared field is read by a maintainer as a
*contract* — something the pool promises to keep accurate — and a future change that lets
`owner_pid` and `from` disagree, or `in_flight.schema_name` and `in_flight.op`'s schema name
disagree, would be a real bug that nothing detects, because nothing reads either field. Removing
them makes the single source of truth the only source.

### 1.1 Field 1 — `owner_pid` on `provision_op()`

- **Declared:** `lib/letflow/sandbox_pool.ex:160` (`owner_pid: pid(),` inside `@typep provision_op`).
- **Written:** `:535`, inside `reserve_slot/2`'s `{:provision, %{…}}` literal, from the local
  bound at `:527`.
- **Read:** nowhere (W1, W2). The `test/…:420` `owner_pid` is an unrelated local (W3).

### 1.2 Field 2 — `schema_name` on the `in_flight` record

- **Declared:** the state-shape comment at `lib/letflow/sandbox_pool.ex:316`
  (inside the `in_flight:` block, `:312-317`; the whole comment runs `:299-318`), and
  `iss0224-…md` §5's `in_flight()` block at `:521`.
- **Written:** `:572`, in `pump/1`'s `in_flight = %{…}` literal, as `op_schema_name(op)`.
- **Read:** nowhere (W4, W5).
- **`op_schema_name/1`** (`:592-593`) exists for that one call site and nothing else (W6).

---

## 2. Exact removal set

This is the complete change. Nothing outside this table is touched in `lib/`.

| # | File | Location (at `HEAD` of `fix/WF03-ISS0227-20260822`) | Change |
|---|---|---|---|
| R1 | `lib/letflow/sandbox_pool.ex` | `:160` | delete the line `owner_pid: pid(),` from `@typep provision_op` |
| R2 | `lib/letflow/sandbox_pool.ex` | `:535` | delete the line `owner_pid: owner_pid,` from `reserve_slot/2`'s `{:provision, %{…}}` literal |
| R3 | `lib/letflow/sandbox_pool.ex` | `:316` | delete the line `#                  schema_name: String.t()` from the `in_flight:` block of the state-shape comment, and drop the now-trailing comma from `:315`'s `task_pid: pid(),` so the comment stays well-formed |
| R4 | `lib/letflow/sandbox_pool.ex` | `:572` | delete `schema_name: op_schema_name(op)` from `pump/1`'s `in_flight = %{…}` literal, and drop the now-trailing comma from `:571`'s `task_pid: task.pid,` |
| R5 | `lib/letflow/sandbox_pool.ex` | `:592-593` | delete both clause heads of `defp op_schema_name/1` — **mandatory, not optional**; see §3 |

### 2.1 What is explicitly NOT removed or changed

- **`owner_ref` — stays, everywhere.** R1/R2 remove `owner_pid` only. The line above R2
  (`:528`, `owner_ref = Process.monitor(owner_pid)`) is untouched, so the monitor is
  established from the same local, at the same instant, on the same process as before.
- **The local `owner_pid = elem(from, 0)` at `:527` — stays** (W10). It is read at `:528`.
  An implementer who deletes it too will produce an undefined-variable compile error at `:528`.
- **`from` on `provision_op()` — stays.** It is both replied to and, after this change, the sole
  carrier of the owner pid (§2.2).
- **`schema_name` on `provision_op()` and `drop_op()` — stays.** Those are read (`run_op/1` at
  `:586-590`, `complete_op/3` at `:675`, and the pre-minting rationale in `iss0224-…md` §5).
  Only the `in_flight` record's *duplicate copy* of that value goes.
- **`in_flight`'s `op`, `task_ref`, `task_pid` — stay.** All three are read (W4).
- Every `@spec`, every arity, the moduledoc, the error taxonomy, `application.ex`, any config,
  any migration, any test file.

### 2.2 Derivation for `owner_pid`, and why it is equivalent

**Derivation at any future point of use:** `elem(p.from, 0)`, for an op `p`.

**Equivalence argument.** `from` is a `GenServer.from()`, i.e. `{pid(), tag :: term()}`, whose
first element *is* the calling process's pid. In `reserve_slot/2` the removed field was
computed as `owner_pid = elem(from, 0)` (`:527`) and written into the very same map literal
(`:535`) that carries `from` — so at the instant of construction the two are equal by
definition, not by coincidence. They cannot subsequently diverge, because:

1. `from` is set **exactly once**, at reservation, and is never rewritten on a `{:provision, _}`
   op. The only in-place rewrites this module performs on a provision op are `owner_down?: true`
   (`iss0224-…md` §7 step 3 clause B case 2, `sandbox_pool.ex` `:958`-region) — which touches
   `owner_down?` and nothing else — and the `:release` → `:release_orphaned` purpose rewrite,
   which applies to `drop_op()`, never to `provision_op()`, and which sets `from: nil` on a
   record that never had an `owner_pid` field at all.
2. The op is otherwise immutable for its whole lifetime: `db_queue` → `in_flight` → discarded.

Therefore `elem(p.from, 0) == p.owner_pid` holds at every point the field existed, and the
derivation is exact rather than approximate.

**Nothing is added to the module to perform this derivation.** No helper, no `@spec`. The
expression is recorded here so that a future reader who needs the owner pid writes
`elem(p.from, 0)` instead of re-adding the field.

### 2.3 Derivation for `in_flight.schema_name`, and why it is equivalent

**Derivation at any future point of use:** the schema name of the in-flight op — for a
`{:provision, %{schema_name: n}}` or `{:drop, %{schema_name: n}}`, the `n`. (This is exactly
what `op_schema_name/1` computed; if a future change ever needs it again, it re-introduces that
helper *with a live call site*, which is the only condition under which it may exist — §3.)

**Equivalence argument.** `pump/1` computes the removed field as `op_schema_name(op)` (`:572`)
from the *same* `op` value it stores in `in_flight.op` on the adjacent line (`:569`), in one map
literal, in one expression. So `in_flight.schema_name == op_schema_name(in_flight.op)` at the
instant of construction, by construction. It stays true because:

1. `in_flight.op` is replaced wholesale, never patched, and only by the two enumerated in-place
   rewrites: `owner_down?: true` on a provision op, and the case-4b rewrite
   `%{d | from: nil, owner_ref: nil, purpose: :release_orphaned}` on a release drop op.
   **Neither touches `schema_name`** — and case 4b's own design note says so explicitly
   (`iss0224-…md` `:724-726`: "The worker holds only the schema_name STRING and is unaffected;
   the rewrite changes only what `complete_op/3` does when the result arrives").
2. `in_flight` as a whole is only ever set by `pump/1` or cleared to `nil` by `complete_op/3` /
   the worker-death path. There is no path that swaps `op` for a different schema's op while
   keeping the record.

Therefore the removed field was, at every instant of its existence, a redundant copy of a value
reachable in one hop from a field that survives.

### 2.4 The tests already do it the derived way

This is corroboration, not an argument from authority: `test/letflow/sandbox_pool_test.exs:920`
and `:1007` both need the in-flight provisioning's schema name and both obtain it as

```
{:provision, %{schema_name: o_schema}} = state.in_flight.op
```

i.e. from `in_flight.op`, never from `in_flight.schema_name` — which is the derivation of §2.3
written out. The field being removed was never the path anyone took.

---

## 3. `op_schema_name/1` — removed, not retained. The decision and its measurement

**Decision: R5 removes it.** It is not retained as a "documented derivation helper."

### 3.1 Why retention is not available

After R4 its only call site is gone (W6). An Elixir `defp` with no call site is an unused
private function, which the compiler warns about; the project's gate compiles with
`--warnings-as-errors`, so retaining it turns the build red. That is not a stylistic preference
that can be overridden by a comment — a `# credo:disable` or an explanatory comment does not
silence a compiler warning, and suppressing the warning by any means (e.g. adding a fake call
site, or exporting it as a `def`) would be a "Never Satisfy a Gate by Editing What It Measures"
violation in the opposite direction: it makes a real detector stop reporting a real fact.

### 3.2 What "CI" is on this project — checked, not assumed

W9: **there is no `.github/workflows/` directory and no GitHub Actions definition in this
repository.** The warnings-as-errors gate is not a hosted CI job; it is a command that agents
run:

- `mix compile --warnings-as-errors` at `docs/agents/protocols/GIT_MERGE.md:166`, in the
  post-rebase pre-merge check every run passes through, and reported verbatim in the PR body
  template at `:235` ("`mix compile --warnings-as-errors`: PASS");
- step 3 of the `letflow.check` alias in `mix.exs` (`"letflow.check": ["letflow.check_toolchain",
  "format --check-formatted", "compile --warnings-as-errors", "letflow.check.test"]`);
- `WF-02_requirement_implementation.md:176` and `:195` as an explicit checklist item.

So the consequence of retention is concrete and reachable on this branch's own merge path, not
hypothetical.

### 3.3 Measured, because "unused `defp` is a warning" is a claim, not a fact I may assume

Two probes, in `scratch/iss0227/` (git-ignored, per `core-directives.md` §"File Placement
Rules"). Both use the **exact** two-clause shape being deleted.

| probe | command | warning emitted | exit code |
|---|---|---|---|
| bare `.ex` file | `elixirc --warnings-as-errors -o . unused_priv_probe.ex` | yes — `function op_schema_name/1 is unused` | **0** (W8) |
| throwaway mix project | `mix compile --warnings-as-errors` in `scratch/iss0227/probeproj/` | yes — same warning, then `Compilation failed due to warnings while using the --warnings-as-errors option` | **1** (W7) |

**W8 is recorded deliberately.** The out-of-mix probe is the cheaper one and it is the one an
implementer or validator is most likely to reach for — and it returns 0, which would license
exactly the wrong conclusion. Only the `mix compile` form reproduces the gate that actually
runs. This is `core-directives.md` §"Re-derive under the conditions the property is actually
about": a green run under conditions where the property could not have failed is not evidence.

### 3.4 The rule this leaves behind for future readers

`op_schema_name/1` may be re-introduced the moment something genuinely calls it. What may not
happen is a private function kept alive with no caller "for documentation" — the documentation
of the derivation is §2.3 of this file, which costs nothing at compile time.

---

## 4. No test bound moves

**Confirmed from the actual test files: zero assertions, zero pattern matches and zero helper
bodies in the EXISTING suite reference either removed field. No existing test needs rewriting at
all, not even a weakened one.** That is a statement about *rewrites*, not about coverage: §4.2
specifies **one new test, RT-9**, which ISS-0227 does require. Round 1 conflated the two and
concluded no test was needed at all; CODE-DESIGN-VALIDATOR overruled that (D1) and §4.2 carries
the ruling.

| File | `owner_pid` (the field) | `in_flight.schema_name` | Verdict |
|---|---|---|---|
| `test/letflow/sandbox_pool_test.exs` | **absent.** The only `owner_pid` token in the file is the local at `:420`, spawned-process pid, used at `:443` (`Process.monitor`), `:444` (`Process.exit`), `:445` (`assert_receive {:DOWN, ^owner_monitor_ref, :process, ^owner_pid, :killed}`) — never read off an op (W3) | **absent.** `in_flight` is touched at `:653-654`, `:669-675`, `:681`, `:920`, `:930`, `:1007`, `:1008`, `:1021`, `:1146`, `:1169` — via `.op`, `.task_pid`, and `in_flight: nil`. `:920`/`:1007` derive the schema name from `.op` (§2.4) | **no change** |
| `test/letflow/sandbox_pool_call_timeout_test.exs` | **absent** — zero occurrences of `owner_pid` | **absent** — zero occurrences of `in_flight` or `schema_name` | **no change** |
| `test/letflow/definitions/promotion_assertion_rerun_test.exs` | **absent** | **absent.** Its only `in_flight` mention is the prose comment at `:163` explaining that `active_sandbox_id!/1`'s partial map match `%{active: active} = :sys.get_state(pool)` deliberately **ignores** the `db_queue`/`in_flight` siblings. That comment names the two siblings as a pair; it makes no claim about `in_flight`'s internal fields, so it stays accurate verbatim | **no change** |
| `test/specs/ISS-0224.md` (the test spec, checked for completeness) | **absent** | **absent.** Its many `in_flight` references are to `in_flight` being `nil` / a `{:provision, _}` / `.task_pid`, plus one literal pre-fix failure dump at `:505` (`in_flight: nil, db_queue: {[], []}, max_concurrent: 1`) which contains no field list | **no change** |

**Method** (so this is re-derivable rather than asserted). **The grep must be restricted to
code files** — `lib/` also contains `lib/letflow/design/*.md`, and an unrestricted run returns
prose hits including `.schema_name` ones, which is a scare, not a finding (§4.1):

```
grep -rohE --include=*.ex --include=*.exs "in_flight[a-z_]*\.[a-z_]+" lib test | sort | uniq -c
```

→ **12 hits: `in_flight.op` ×7, `in_flight.task_ref` ×4, `in_flight.task_pid` ×1, and zero
`.schema_name`** (W4). Second grep: `grep -rn "owner_pid" lib test docs` → the four `lib/letflow/`
lines of §1.1, the three unrelated test locals of W3, two `test/specs/ISS-0048.md` prose lines
about `Process.exit(owner_pid, :kill)`, and four `lib/letflow/design/` prose lines (§5).

*Round 1 of this design stated the first command without `--include` and reported "32 hits".
Neither figure was reproducible: run verbatim it returns ~50 hits (ten of them `.schema_name`,
all prose); the 32 was a miscount of `-n`-prefixed lines, which `uniq -c` cannot aggregate
because the line-number prefix makes every line unique. CODE-DESIGN-VALIDATOR caught both
(D3); the **conclusion** was correct and was independently re-derived by it. Corrected above,
command and count together.*

**Had one been found**, this section would have specified an equivalent-strength rewrite —
`assert elem(op.from, 0) == pid` in place of `assert op.owner_pid == pid`, and the §2.4 form in
place of any `in_flight.schema_name` read — never a deleted or loosened assertion. None was
found, so there is nothing to rewrite.

### 4.1 The grep hazard this design is itself an instance of

`git grep -lE "in_flight[a-z_]*\.schema_name" -- lib test` returns **exactly one file: this
design document.** The only thing in the repository that still contains the literal string
`in_flight.schema_name` is the document proving the field is gone.

That is `docs/anti-patterns.md:1195` — **"A grep-shaped acceptance criterion can be tripped by
the module's own moduledoc describing the invariant"** (REQ-072: a moduledoc sentence stating
"this module never calls `Process.put/2`" contained the literal substring its own AC's grep was
hunting for) — recurring here with a design doc in the moduledoc's place. Found by ISSUE-FIXER
during D3 rework.

**The response is to restrict the grep, never to garble the prose.** A design that cannot name
the field it removes is not a design. Every structural grep in this document, and the one
GH #465 acceptance criterion 4 asks for (§12), is therefore code-file-restricted.

### 4.2 The regression test: RT-9 (TEST-DESIGNER implements)

> **This section replaces round 1's §4.1, which declined to specify any regression test.
> CODE-DESIGN-VALIDATOR OVERRULED that position (D1, MAJOR) and its decisive ground is one
> round 1 never weighed, so this is a reversal on the merits, not a wording pass:** upholding
> §4.1 would leave ISS-0227 with **no truthful terminal status**. `ISSUE_QUEUE.md:180-247`'s
> vocabulary is `open` / `in_progress` / `resolved` / `instrumented` / `no_defect`. `resolved`
> (`:187`) requires "a root cause was actually removed, **and a regression test proves it**";
> `no_defect` is false (a defect existed); `instrumented` is false (the root cause *is*
> removed, and that status additionally demands a `superseded_by` successor carrying remaining
> work, which does not exist). A design that forbids the test forces the run to write a false
> `resolved` or to leave a genuinely-fixed issue non-terminal. Round 1's evidence — (a) a clean
> warnings-as-errors compile and (b) the existing suites still green — is **absence-of-regression
> evidence only: both would read identically if ELIXIR-DEV changed nothing at all.** It is kept
> below as *additional* evidence, never as the sole evidence.
>
> Round 1's "it pins an implementation detail" objection is also withdrawn. ISS-0227's defect
> **is** structural — a second stored copy of derivable state that can silently diverge — so a
> white-box key-set assertion is not a gratuitous pin, it is the only mechanical detector of the
> filed hazard, and it is this suite's standing style already (`:sys.get_state/1` at `:920`,
> `:1007`, `:1008`, `:1146`). Round 1's further objection that the test "would have to be
> deleted the day the field is legitimately re-introduced" is the guard **working as intended**:
> re-introduction should require a deliberate edit that confronts this design's rationale, which
> is precisely what silent re-introduction is not.

**One test. No new file.** Appended to the existing ISS-0224 RT block in
`test/letflow/sandbox_pool_test.exs`, named:

```
RT-9 (ISS-0227): the in-flight provision op and the in_flight record carry no duplicate
of a derivable value
```

#### Reaching the observation point — existing helpers, no sleep

The file already has everything needed; this is the **exact** synchronisation `:917-918` uses,
so no new helper and no timing constant is introduced:

- `pool = start_pool!(max_concurrent: 1)`
- `spawn_claimer(pool, :o, 1_000)` — returns the claiming pid, which assertion (3) needs
- `state = wait_until_pool_state(pool, "O's provisioning is in flight", &provision_in_flight?/1)`

#### The three assertions

1. **Exact key set of the in-flight provision op.** Bind `{:provision, p} = state.in_flight.op`
   and assert
   `Enum.sort(Map.keys(p)) == [:from, :owner_down?, :owner_ref, :sandbox_id, :schema_name]`.
   **Sorted-key-list equality, NOT `refute Map.has_key?(p, :owner_pid)`.** Equality is what makes
   it a drift guard in *both* directions: it fails if `owner_pid` returns, and it fails if some
   future change quietly adds another undeclared field. A `refute Map.has_key?` guards one
   direction only and is not an acceptable substitute.
2. **Exact key set of the record.** `assert Enum.sort(Map.keys(state.in_flight)) == [:op, :task_pid, :task_ref]`
   — same equality form, same reason.
3. **The derivations still reach their values**, so the case documents the *replacement* and not
   merely the removal: `assert elem(p.from, 0) ==` the claiming pid returned by
   `spawn_claimer/3`, and `{:provision, %{schema_name: n}} = state.in_flight.op` with
   `assert is_binary(n)`.

#### Fail-then-pass (WF-03 Step 4, `WF-03_issue_resolving.md:99-103`)

A genuine fail-then-pass is available and must be shown — the module exists and both fields
exist pre-fix, so `:105-117`'s "when the pre-fix failure is non-existence" escape hatch does
**not** apply here.

| | assertion (1) | assertion (2) | assertion (3) |
|---|---|---|---|
| **pre-fix** (`sandbox_pool.ex` at this branch's `a64159d`, both fields present) | **FAILS** on `:owner_pid` | **FAILS** on `:schema_name` | passes |
| **post-fix** (R1-R5 applied) | passes | passes | passes |

TEST-DESIGNER states both runs explicitly, with real output, per `WF-03:99-103`.

#### Coverage map — so nothing is left unproven

| Removal | Proven by |
|---|---|
| **R2** (`owner_pid` out of `reserve_slot/2`'s op literal) | RT-9 assertion (1) |
| **R4** (`schema_name` out of `pump/1`'s `in_flight` record) | RT-9 assertion (2) |
| **The §2.2 / §2.3 derivations remain reachable** | RT-9 assertion (3) |
| **R5** (`op_schema_name/1` deleted) | `mix compile --warnings-as-errors` exiting **0** — evidence (a) |
| **No behavioural drift** | the existing `sandbox_pool_test.exs` / `sandbox_pool_call_timeout_test.exs` / `promotion_assertion_rerun_test.exs` suites passing unchanged — evidence (b) |
| **R1** (the `owner_pid: pid(),` line in `@typep provision_op`) | **NOT runtime-observable by any test, and named as such rather than left silently uncovered.** A `@typep` is erased at compile time: no `:sys.get_state/1` read, no `Map.keys/1`, no dialyzer run in this project's gate can distinguish a map's runtime key set from its declared typespec. R1 is discharged by **ELIXIR-DEV's diff** (the line is deleted, visibly, in the PR) and by **REVIEWER**, whose idiom gate covers a typespec that no longer matches the value it describes. RT-9 assertion (1) makes the *runtime* half true; R1 makes the *declared* half agree with it, and only a human-or-agent reading of the diff closes that half. |

#### Evidence (a) and (b), retained

Both stay in the record as **additional** evidence, with their limitation stated: `mix compile
--warnings-as-errors` exiting 0 proves R5 was done and nothing was orphaned, and the unchanged
suites prove no behavioural drift — but neither, alone or together, proves a root cause was
removed, because both would read identically against an empty diff. RT-9 is what makes the
`resolved` status truthful.

#### One thing RT-9 must not become

RT-9 asserts key sets and derivations at one observation point. It must **not** be grown into a
grep-shaped assertion over source text (`refute File.read!("lib/letflow/sandbox_pool.ex") =~
"owner_pid"` or similar) — §4.1 is the standing reason: this design document itself contains
every one of those literals, and the AC-4 grep of §12 is code-file-restricted for exactly that
reason. Structural facts about the pool are asserted against the pool's **runtime state**, never
against file contents.
---

## 5. Companion edits to `iss0224-sandbox-pool-async-provisioning.md`

ISS-0224's design records the state shape as it was built. Left alone, it keeps asserting two
fields that no longer exist — a record that disagrees with the code is worse than no record.
It also may **not** be silently deleted from: `core-directives.md` §"Bookkeeping Is Not
Optional" treats the design artefacts as an audit trail, and ISS-0224's own round-2 R2-F2
finding is precisely that a removal recorded only in prose, with the artefact quietly
re-lettered, made the document contradict itself.

### 5.1 The supersede convention this repo already uses — found, not invented

Three existing precedents, all in `lib/letflow/design/`:

1. **`iss-0048-sandbox-pool-owner-crash-reclaim.md:20-40`** — a dated **REWORK NOTICE** at the
   top of the file that (a) names the later section as authoritative, (b) states the earlier
   sections are "left unedited in place as the historical record", and (c) **enumerates
   specifically what is superseded** ("§13 supersedes: §1's scope-boundary table …").
2. **`iss064-orphaned-tenant-schemas-fix.md:619`** — a new numbered, dated, issue-attributed
   section appended at the end: `## 11. Extension (ISS-0110, 2026-08-21) — <what changed>`,
   followed at `:656` by `## 12. Extension (ISS-0217, 2026-08-21) — …`.
3. **`iss0224-…md` round 2's own R2-F2 fix** (`:38`) — for a *removal inside a table*, the
   removed row is kept "as an explicit struck-through **deleted** row in the table so the audit
   trail lives in the table, not only in prose."

**ISS-0227 uses all three, in the combination each was designed for:** (2) for the new
authoritative section, (1) for the top-of-file pointer to it, (3)'s principle — mark the removal
where it lived — for the two code blocks. Because precedent 3's removals were markdown *table*
rows (strikethrough renders) and ISS-0227's are lines inside fenced code blocks (strikethrough
does **not** render inside a fence), the in-place marker is written as a comment line occupying
the removed field's position, which is the same idea in the medium that block allows.

### 5.2 Edit C1 — §5's `provision_op()` block (`iss0224-…md:500-507`)

Line `:502` currently reads `  owner_pid:   pid(),`. **Replace that line in place** with a
comment line marking the removal (keep it inside the fence, keep the block's alignment):

```
  # owner_pid REMOVED by ISS-0227 (2026-08-22) -- write-only; derive as elem(p.from, 0). See §17.
```

Do not delete the line outright and do not renumber or re-order the surviving five fields
(`from`, `owner_ref`, `sandbox_id`, `schema_name`, `owner_down?`).

### 5.3 Edit C2 — §5's `in_flight()` block (`iss0224-…md:517-522`)

Line `:521` currently reads `  schema_name: String.t()`. Line `:520` reads `  task_pid:    pid(),`.
**Replace `:521` in place** with the removal marker, and **drop the trailing comma from `:520`**
so the surviving three fields (`op`, `task_ref`, `task_pid`) form a well-formed map:

```
  # schema_name REMOVED by ISS-0227 (2026-08-22) -- write-only; derive from in_flight.op
  #   ({:provision, %{schema_name: n}} | {:drop, %{schema_name: n}} -> n). See §17.
```

**Nothing else in §5 needs touching, and this was checked rather than assumed (W11):** §5's
field-by-field rationale list has bullets for `db_queue`, `in_flight`, `owner_ref`,
`sandbox_id`/`schema_name` **of `provision_op()`**, `task_ref`/`task_pid`, and `owner_down?` —
there is **no bullet for `in_flight`'s `schema_name`** and **no bullet for `owner_pid`**. The
`task_ref`/`task_pid` bullet (`:566-567`) makes no claim about a sibling `schema_name` field and
stays verbatim. `:559`'s `owner_ref` bullet says the ref is established "via
`Process.monitor(owner_pid)`" — that is a reference to the **local variable at `:527`, which
survives** (§2.1), so it also stays verbatim and must not be edited.

### 5.4 Edit C3 — §7 step 2's `reserve_slot/2` prose (`iss0224-…md:802-804`)

The task brief located this at "~:804"; the exact block is `:802-804`. Two lines change and one
does not:

- **`:802`** — `` `reserve_slot/2`: `owner_pid = elem(from, 0)`; `owner_ref = Process.monitor(owner_pid)`; ``
  → **unchanged.** It describes the two surviving *local bindings*, which is still exactly what
  the function does.
- **`:804`** — currently
  `` `{:provision, %{from:, owner_pid:, owner_ref:, sandbox_id:, schema_name:, owner_down?: false}}`. ``
  → **edit:** drop `owner_pid:,` from the enumerated literal, leaving
  `` `{:provision, %{from:, owner_ref:, sandbox_id:, schema_name:, owner_down?: false}}`. ``
- **immediately after `:804`**, add one line:
  `**`owner_pid` was removed from this literal by ISS-0227 (2026-08-22)** — see §17.`

*(§7 step 1's pseudocode at `:794` says only "`reserve_slot(from, state)` # monitor owner, mint
identity, enqueue `{:provision, _}`" and names no fields, so it needs no edit. Checked.)*

### 5.5 Edit C4 — the new authoritative section

Append, after §16 (the last section, ending at `:1903`), following precedent 2's exact heading
shape:

```
## 17. Extension (ISS-0227, 2026-08-22) — two write-only fields removed
```

Its required content, and nothing more:

1. That `provision_op()`'s `owner_pid` and the `in_flight` record's `schema_name` were written
   and never read, and are removed — naming this design file
   (`lib/letflow/design/iss0227-sandbox-pool-dead-field-removal.md`) as the authority for the
   change.
2. The two derivations of §2.2 and §2.3, one line each, with the equivalence stated (`from` is
   never rewritten on a provision op; `in_flight.op` is never patched in a way that changes its
   schema name).
3. That `op_schema_name/1` went with them because it lost its only call site and an unused
   `defp` fails `mix compile --warnings-as-errors` (measured — W7).
4. **The explicit no-invariant-change statement of §6 below**, so a reader of ISS-0224 alone
   learns it without following a link.
5. A pointer to C1/C2/C3's in-place markers, so the audit trail is navigable in both directions.

### 5.6 Edit C5 — the top-of-file pointer

Following precedent 1's shape, add one dated line immediately after `iss0224-…md`'s **Status**
line (`:3-4`), before the round-1 REWORK NOTICE blockquote:

> **ISS-0227 (2026-08-22):** §5's `provision_op()` no longer carries `owner_pid` and its
> `in_flight()` record no longer carries `schema_name` — both were write-only. **§17 is
> authoritative for those two fields;** §5 and §7 step 2 are marked in place and otherwise left
> as the historical record. Nothing else in this document is affected.

### 5.7 What must NOT be edited in `iss0224-…md`

Stated because the file is 1903 lines and a well-meaning implementer may over-reach:

- Any INV-SP-* statement, including all of §8.4's INV-SP-A1..A7 (§6 below explains why none is
  affected).
- §7 step 3 clause A or clause B, including case 4b — its `%{in_flight | op: …}` rewrites name
  `op`, never `schema_name`.
- §10's regression-test contract (RT-1..RT-8), §11, §13, §14, §15, §16.
- Both REWORK NOTICE blockquotes and every F-/R2-F- finding row: those are round-1/round-2
  history and ISS-0227 is neither.
- §12's file table — it records what **ISS-0224's** implementation touched. ISS-0227's own file
  list is §7 below.

---

## 6. Invariants: none change. Explicitly.

**No invariant is added, removed, weakened, strengthened, or restated by this change.** Each is
addressed by name rather than as a group, because "nothing changed" is exactly the kind of claim
that needs itemising:

| Invariant | Effect of ISS-0227 | Why |
|---|---|---|
| **INV-SP-A1** (reservation: `map_size(active) + provision_ops_pending(state) <= max_concurrent`) | **none** | Counts ops by *kind* (`{:provision, _}`) via `provision_ops_pending/1`; reads no removed field |
| **INV-SP-A2** (exactly-one-reply, from one of §6.4's six sites) | **none** | Replies are issued to `from`, which stays. No reply site ever read `owner_pid` |
| **INV-SP-A3** (ref classification is unambiguous, incl. (iii)'s enumerated `owner_ref` overlap and (iv)'s case ordering) | **none** | Concerns `reference()` values — `task_ref`, `owner_ref`, `caller_ref`. `owner_pid` is a `pid()`, not a ref, and was never one of the classified quantities. `in_flight.schema_name` is a `String.t()` |
| **INV-SP-A4** (no monitor gap; no leak on any of the five death paths (a)-(e)) | **none** | All five turn on `owner_ref` and on the *pre-minted* `schema_name` carried by `provision_op()`/`drop_op()` — both retained (§2.1). Path (d)'s compensating drop reads `p.schema_name` (`:675`), the op's own field, never `in_flight.schema_name` |
| **INV-SP-A5** (peak DB demand 2; at most one op in flight) | **none** | A property of `pump/1`'s "no-op while `in_flight != nil`" guard, which tests `in_flight` for `nil`, not for any field |
| **INV-SP-A6**, **INV-SP-A7** (disclosed residuals) | **none** | Unchanged text, unchanged truth |
| **INV-SP-1..7** (REQ-039), **INV-SP-DOWN-1..5** (ISS-0048), **INV-SP-T1..T5** (ISS-0220) | **none** | Predate ISS-0224 and never named either field |

**And no new invariant is introduced.** In particular, "`owner_pid` equals `elem(from, 0)`" is
**not** promoted to an invariant — it is retired. After this change there is no second copy that
could disagree, which is the whole point; an invariant asserting agreement between one value and
itself would be vacuous.

### 6.1 Owner-monitor semantics — unchanged, spelled out

This is the one thing a reviewer should check hardest, because the removed field's *name* looks
like it belongs to the monitor mechanism. It does not:

- `owner_ref` **stays**, in `provision_op()`, in `drop_op()`, and in every `active` entry.
- The monitor is still established at `lib/letflow/sandbox_pool.ex:528`, from the local
  `owner_pid` bound at `:527`, i.e. **on the calling process, at reservation time, strictly
  before any schema exists** — ISS-0224's hazard-2 fix, byte-for-byte.
- Every `Process.demonitor(…, [:flush])` site continues to demonitor an `owner_ref`.
- Clause B's six-way `:DOWN` dispatch matches on `ref`, never on a pid. The `_pid` element of
  `{:DOWN, ref, :process, _pid, _reason}` is already discarded today and is not made more or
  less available by this change.
- The same-process claim/release contract (moduledoc `:33-46`, `iss-0048-…md` §13) is untouched.

### 6.2 Everything else that is unaffected

- **Serialized DB worker (ISS-0224 §4):** unaffected. `pump/1` still spawns exactly one
  `Task.Supervisor.async_nolink/3` worker at a time; `run_op/1` (`:586-590`) takes the schema
  name from the **op**, not from `in_flight`, and is not edited.
- **No external behaviour change.** No `@spec`, arity, return value, error atom, timeout, or
  reply timing changes. `claim/2` and `release/2` are byte-for-byte identical in contract.
- **No `:sys.get_state/1` consumer breaks.** `promotion_assertion_rerun_test.exs`'s partial map
  match binds `active` only (`:169`); `sandbox_pool_test.exs`'s helpers read `in_flight.op`,
  `.task_pid` and `in_flight == nil`. Both survive a *narrower* `in_flight` record for the same
  reason ISS-0224's §9.1 said they survive a wider one: a partial match ignores what it does not
  name, and none of them names `schema_name`.
- **No security surface.** No tenant-data path, no route, no query, no migration, no config.
  `schema_name` values are still never caller-supplied (moduledoc `:281`, `:872-877`).

---

## 7. Files the implementation must touch

| File | Change | Owner step |
|---|---|---|
| `lib/letflow/sandbox_pool.ex` | R1-R5 (§2) — five deletions plus two trailing-comma fixes. Nothing else | ELIXIR-DEV |
| `lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md` | C1-C5 (§5) — two in-place markers, one prose-literal edit + one added line, one new §17, one top-of-file pointer | ELIXIR-DEV |
| `test/letflow/sandbox_pool_test.exs` | **RT-9 appended to the existing ISS-0224 RT block** (§4.2) — one new test, no new file, no new helper, no new constant. No existing test in this file changes | TEST-DESIGNER |
| `docs/issues/ISS-0227.yaml` | status transitions | DOC-UPDATER |

**Explicitly NOT touched:** every test file **except** `test/letflow/sandbox_pool_test.exs`
(which gains RT-9 and nothing else — §4.2) — so in particular
`test/letflow/sandbox_pool_call_timeout_test.exs` and
`test/letflow/definitions/promotion_assertion_rerun_test.exs` are untouched (§4) —
`test/specs/ISS-0224.md`,
`lib/letflow/application.ex`, `lib/letflow/definitions.ex`,
`lib/letflow/sandbox_pool/fixture_loader.ex`, any `config/*.exs`, any
`priv/repo/migrations/*`, any `docs/migration/decisions/*`, `mix.exs`, `scripts/test_parallel.sh`.

**Post-change checks ELIXIR-DEV must run and quote** (not "should pass" — actually run, per
`core-directives.md` §"No Speculation", synchronously in-turn per §"No Background Wait"):

1. `mix format --check-formatted` — R3/R4's comma removals are exactly the kind of edit that
   drifts formatting.
2. `mix compile --warnings-as-errors` — must exit **0**. If it reports `function
   op_schema_name/1 is unused`, R5 was skipped; if it reports an undefined variable at `:528`,
   the local at `:527` was deleted in error (§2.1).
3. `mix test test/letflow/sandbox_pool_test.exs test/letflow/sandbox_pool_call_timeout_test.exs
   test/letflow/definitions/promotion_assertion_rerun_test.exs` — the pre-existing cases are
   expected unchanged, since §4 establishes no existing test reads either field. **RT-9 is
   TEST-DESIGNER's at WF-03 Step 4, after ELIXIR-DEV's step**, and its pre-fix run is made
   against `a64159d` per §4.2 — ELIXIR-DEV does not run or author it here.

---

## 8. What ELIXIR-DEV must NOT do

1. **Do not delete `owner_ref` anywhere.** Only `owner_pid` goes (§2.1, §6.1). These two names
   differ by four characters and mean entirely different things; conflating them silently
   removes ISS-0048's reclaim mechanism and ISS-0224's hazard-2 fix at once.
2. **Do not delete the local `owner_pid` at `:527`.** It is read at `:528` (W10).
3. **Do not keep `op_schema_name/1` "just in case."** §3 — it is a red build.
4. **Do not add a `defp owner_pid(op), do: elem(op.from, 0)` helper**, or any other accessor, to
   "preserve the interface." There is no interface to preserve: nothing called it. Adding one
   re-creates the unused-`defp` problem of §3 and re-introduces the second source of truth this
   change exists to remove.
5. **Do not "improve" anything else in `sandbox_pool.ex` while in the file** — no renames, no
   reordering, no extra typespecs. ISS-0227 is five deletions and two commas.
6. **Do not delete the superseded lines from `iss0224-…md`.** They are marked in place (§5.2,
   §5.3), per this repo's own convention (§5.1).
7. **Do not write RT-9 yourself, and do not skip it.** §4.2's RT-9 is **TEST-DESIGNER's** to
   write, in the existing `test/letflow/sandbox_pool_test.exs` — **no new test file is created**,
   it is appended to the ISS-0224 RT block. ELIXIR-DEV does not author it and does not treat the
   fix as complete without it; WF-03 Step 4 owns it, and `resolved` is not a truthful terminal
   status for ISS-0227 until it exists and its fail-then-pass is on record (§4.2).
   *(Round 1 stated this item as "Do not write any new test file", which forbade RT-9 outright.
   Inverted per D1.)*

---

## 9. Cross-module dependencies

**None.** `Letflow.SandboxPool`'s only in-`lib/` consumer is `Letflow.Definitions`
(`definitions.ex:1466-1500`, `:1591`, `:1633`, `:1818-1826`), which calls `claim/2` and
`release/2` and matches on `[:sandbox_unavailable, :provision_failed]` — the public surface, all
of which is unchanged (§6.2). Neither removed field was ever reachable from outside the module:
both live in `@typep`-private op/record shapes, and the only external window into pool state is
`:sys.get_state/1` in tests, which §4 shows never reads them. No other module, no route, no
schema, no migration.

---

## 10. Invariants introduced by this design

**None.** Stated as its own section rather than left implicit, since a CODE-DESIGNER artefact is
expected to enumerate them: this change removes duplicated state and therefore removes the *need*
for an invariant, rather than adding one (§6).

---

## 11. Open questions

**OQ-1 — Should `elem(p.from, 0)` be given a name at the point some future code needs it?**
Not resolved here, and deliberately not guessed. If a future change needs the owner pid in more
than one place, that change decides whether to inline `elem(p.from, 0)` at each site or add a
helper *with call sites*. ISS-0227 takes no position because it has zero such sites; §8 item 4
forbids adding one **now**, not forever.

**OQ-2 — Does any other ISS-0224 field have the same write-only property?** Out of scope and
**not investigated exhaustively.** ISSUE-FIXER's diagnosis named exactly two fields, and this
design verified exactly those two (W1-W6). I did **not** audit `db_queue`/`drop_op()`/`active`
field-by-field for further dead fields, and I do not claim there are none. If ORCH wants that
audit it is a separate issue, not a silent expansion of this one
(`core-directives.md` §"Unblock-Everything" scope boundary — a dead field is not blocking this
fix). Recorded so nobody reads §2's removal set as "the complete set of dead fields in the
module"; it is the complete set of fields **this issue is about**.

**OQ-3 — none.** There is no third open question; this section is not padded.

---

## 12. Acceptance-criteria traceability

| Acceptance criterion (from the ISS-0227 task) | Concrete design element |
|---|---|
| Exact removal set: `owner_pid` from the `@typep` and from `reserve_slot/2`'s literal | §2 R1, R2, with exact line numbers and the §2.1 carve-out for the surviving local and `owner_ref` |
| Exact removal set: `schema_name` from `pump/1`'s `in_flight` record and from the state-shape comment | §2 R3, R4, incl. the two trailing-comma fixes |
| Decide and justify whether `op_schema_name/1` is removed or retained; verify what CI does first | §3 — **removed** (R5). CI verified in §3.2 (**no `.github/workflows/` exists**; the gate is `GIT_MERGE.md:166` + `mix.exs`'s `letflow.check`), and the warning-to-red-build link measured in §3.3 (W7 exit 1; W8 records the misleading cheaper probe) |
| Derivation for each removed field, with an equivalence argument | §2.2 (`elem(p.from, 0)`; `from` set once, never rewritten on a provision op) and §2.3 (`op_schema_name(in_flight.op)`'s value; `in_flight.op` never patched in a way that changes its schema name, citing case 4b's own note), plus §2.4's corroboration that the tests already derive it this way |
| Explicit statement that no invariant changes: INV-SP-A1..A7, owner monitor, `owner_ref` stays, serialized worker, no external behaviour change, no new invariant | §6 (per-invariant table incl. INV-SP-1..7 / DOWN-1..5 / T1..T5), §6.1 (owner monitor, spelled out), §6.2 (worker, behaviour, `:sys.get_state` consumers, security), §10 (no new invariant) |
| Companion edits to `iss0224-…md` §5 and §7 step 2, precisely located, annotated as superseded rather than silently deleted, following an existing convention | §5.1 (the three precedents found in-repo, with file:line), §5.2 C1 (`:502`), §5.3 C2 (`:520-521`), §5.4 C3 (`:802-804`), §5.5 C4 (new §17), §5.6 C5 (top-of-file pointer), §5.7 (what must not be edited) |
| "No test bound moves" section, confirmed from the actual test files; an equivalent-strength rewrite if any assertion is found | §4 — per-file table with line numbers, the code-restricted re-derivable grep method (§4 Method, corrected per D3), and the explicit statement of what the rewrite *would* have been had one been found. None was |
| **A regression test that proves the root cause was removed** (`ISSUE_QUEUE.md:187`'s condition for a truthful `resolved`; `WF-03_issue_resolving.md:99-103`'s fail-then-pass) | **§4.2 — RT-9**, with its observation point (existing helpers, no sleep), its three equality-form assertions, its pre-fix/post-fix table against `a64159d`, and its coverage map. R1 is explicitly named as compile-time-only and discharged by ELIXIR-DEV's diff + REVIEWER rather than left silently uncovered. §7 assigns it to TEST-DESIGNER; §8 item 7 forbids ELIXIR-DEV writing it and forbids skipping it |
| **GH #465 AC4: "`git grep` confirms no remaining writer of either field"** | Run **code-file-restricted**, so this design document's own prose cannot trip it: `git grep -nE "owner_pid:\|schema_name: op_schema_name\|op_schema_name" -- 'lib/**/*.ex' 'test/**/*.exs'`. **Pre-fix it returns exactly the five removal-set lines** (`sandbox_pool.ex:160`, `:535`, `:572`, `:592`, `:593` — i.e. R1, R2, R4, R5); **post-fix it must return nothing and exit non-zero.** The restriction is mandatory, not cosmetic: an unrestricted pattern matches this file and `iss0224-…md`, which name the removed fields in prose by necessity — see §4.1 and `docs/anti-patterns.md:1195` |
| No implementation code in the design | This document contains `@typep`/field-shape fragments, prose algorithm references, comment text to be inserted into another **markdown** document, and exact line-number deletion instructions. It contains no `.ex`/`.exs` function bodies and no code block presented as source to paste into `lib/` |

---

## 13. Findings to report to ORCH as candidate successor issues

Per `core-directives.md` §"No Issue Left Local-Only" — **reported**, not filed by me, and not
fixed here.

1. **A module-wide dead-field audit of `sandbox_pool.ex`'s post-ISS-0224 state shape has not
   been performed** (OQ-2). Two fields were found by ISSUE-FIXER and are fixed here; whether
   `drop_op()`, `db_queue` entries or the `active` value map carry further write-only fields is
   unknown. Candidate issue, MINOR, `lib/letflow/sandbox_pool.ex`.
2. **`elixirc --warnings-as-errors` exits 0 where `mix compile --warnings-as-errors` exits 1**
   for the same warning (W7 vs W8, both measured §3.3). This is a live foot-gun for any agent
   verifying a warnings claim, and `docs/anti-patterns.md` has no entry for it. Candidate
   anti-patterns entry — "Verifying a mix-gate property with a non-mix probe" — MINOR.
