# ISS-0876 — bare 2-arity `execute_with_manifest/2` wallclock-race gap — fix design

**Status:** design, initial pass.
**Scope:** test-only. `test/letflow/engine/lua/executor_test.exs` — 9 call sites across 7
tests. No production code changes: `lib/letflow/engine/lua/executor.ex`'s
`execute_with_manifest/2,3`, `run_script_sync/3`, and `run_with_heap_limit_sync/4` are
all pre-existing (shipped by ISS-0426, commit `370fd93f`) and require **zero** edits —
this design only repoints 9 already-existing test call sites onto an already-existing
seam. `lib/letflow/design/iss426-wallclock-test-contention.md` is read-only reference,
not edited.
**Explicitly out of scope:** every other test file (see §0 — repo-wide check found no
other at-risk call sites), `config/config.exs`, `config/test.exs`, and every function in
`executor.ex` not already covered by this paragraph.

## 0. Repo-wide 2-arity blind-spot check (ISS-0876's own required step)

`grep -rn "execute_with_manifest(" test/` (arity determined by hand per call, not by a
`timeout_ms:`-keyed search — same method ISSUE-FIXER used) was run across the whole
`test/` tree, not just `executor_test.exs`. Findings:

- **`test/letflow/engine/lua/executor_test.exs`** — the 9 sites this design covers (§1),
  plus 3 short-circuit sites (lines 235, 236, 239 — `12345`, `%{}`, and a
  `%{manifest: :not_a_manifest, ...}` `script_ref`, all rejected synchronously by
  `normalize_script_ref/1` before any `Task` is spawned — **not at risk**, same
  exclusion ISSUE-FIXER's diagnosis already applied) and 24 already-3-arity call sites
  (Group 1/Group 2 per ISS-0426, already mitigated).
- **`test/letflow/engine/lua/manifest_test.exs:293`** — a bare 2-arity call, but inside
  the `{:ok, manifest_hash} -> Executor.execute_with_manifest(...)` branch of a `case`
  whose *only* input (`Manifest.validate_at_load/3` on a deliberately-modified manifest)
  always returns `{:error, _}` in this test. The test's own comment states this
  explicitly: *"Since it will not pass here (modified manifest), Executor is never
  invoked — proven by never reaching the call, not by mocking."* **Not at risk** — dead
  code path at runtime, same class of exclusion as the 3 short-circuit sites above (never
  reaches a `Task` spawn), just for a different structural reason (branch never taken vs.
  synchronous rejection).
- **`test/letflow/engine/lua_script_audit_test.exs`** (lines 55, 66, 78, 92) — these are
  `def execute_with_manifest(script_ref, registered_hash)` **function definitions**
  inside inline test-double modules (`EchoExecutor`, `MismatchExecutor`,
  `RaiseIfCalledExecutor`, `RecordingExecutor`) implementing the
  `Letflow.Engine.LuaScriptAudit.Executor` `@behaviour` — not calls to the real
  `Letflow.Engine.Lua.Executor` at all. **Not at risk** — no real Lua VM, no `Task`, no
  wall clock involved.
- **`test/specs/REQ-154.md`** (lines 67, 135) — a `.md` spec/rationale document, not a
  `.exs` file; not compiled or run by `mix test`. **Not at risk** — not code.

**Conclusion: no additional at-risk call site exists anywhere in `test/` outside the 9
sites in `executor_test.exs` already identified by ISSUE-FIXER's diagnosis.** No new
file needs converting beyond the one named in ISS-0876.yaml.

## 1. Remediation option chosen: Option 1 — extend ISS-0426's Group-1 synchronous seam

**Chosen, not Option 2 (`@tag :lua_wallclock_race`).** Reasoning:

1. **Identical shape to ISS-0426's own Group 1, which ISS-0426 itself resolved this way,
   not by tagging.** Every one of these 9 call sites is nil-heap (`max_heap_words: nil`
   per `config/config.exs:40`, unmodified by `config/test.exs`), fast (microsecond-scale
   Lua), and — per the "asserted outcome" column below — none of the 9 assertions
   mentions wall-clock time, an in-flight task, or `wallclock_timeout`. This is
   byte-for-byte the same "generous timeout wrapping tiny work, any timeout outcome is a
   wrong-branch failure" shape `iss426-wallclock-test-contention.md` §2.1 used to place
   14 call sites in Group 1 rather than Group 2. ISS-0426's own design (§2.1, "Both
   Group-1 mechanisms produce the same structural guarantee... never left racing... with
   no mitigation" as the *rejected* fallback) treats tag-isolation as the explicitly
   weaker fallback for Group 1, used only when a synchronous seam "turns out to be
   undesirable during implementation" — no such obstacle exists here.
2. **The seam these 9 sites need already exists and requires no new code.** ISS-0426
   shipped `Executor.run_script_sync/3` (`executor.ex:518-527`) as a `@doc false`,
   test-only, additive function — exactly the shape all 9 of these call sites need,
   already used by the 9 nil-heap Group-1 sites ISS-0426 itself converted (e.g.
   `executor_test.exs:257-267`, `:1036-1042`). Extending it here is literally repointing
   9 more call sites onto a seam that is already load-bearing production-adjacent test
   code, not inventing anything.
3. **Structural, not statistical, verifiability (this project's stated preference,
   `iss426-wallclock-test-contention.md` §4).** Per §4 of the ISS-0426 design: "a fix
   whose correctness is structurally evident is strongly preferred... ISSUE-FIXER could
   not reproduce the filed flake." ISS-0876's own diagnosis states the identical thing —
   reproduction attempts did not succeed; the root cause is confirmed by source read.
   Option 1 makes `{:error, {:wallclock_timeout, _}}` unreachable from these 9 call sites
   *by construction* (no `Task.yield` anywhere in `run_script_sync/3`'s call chain) —
   verifiable by a one-time source/diff read, not a repeated-run flake hunt. Option 2
   would leave the race live (merely isolated to a low-concurrency partition), which is a
   strictly weaker guarantee for call sites that don't need it.
4. **Tagging is reserved, by ISS-0426's own design intent, for tests that actually assert
   on the race's outcome.** `iss426-wallclock-test-contention.md` §2.2's Group-2 table is
   explicitly "property genuinely under test: race outcome / numeric elapsed-time
   comparison." None of these 9 tests assert anything of that kind (global isolation,
   table isolation, manifest-hash correctness, syntax-error shape) — tagging them would
   misrepresent what they test and would be inconsistent with how every other
   non-timing-dependent test in this file is already treated.

Option 2 is not used for any of the 9 sites in this design.

## 2. The 9 call sites, before → after

All 9 sites are nil-heap and use `Executor.run_script_sync(manifest, script_source,
budget)` (`executor.ex:518-527`) — never `run_with_heap_limit_sync/4` (no site here is
heap-limited). `registered_hash` is dropped from every converted call: it was already
unused by `execute_with_manifest/3` at this arity (`def execute_with_manifest(script_ref,
_registered_hash, opts)`, `executor.ex:354` — the parameter is bound and discarded), so
no assertion in any of these 9 tests depends on it.

**Budget:** the bare 2-arity call reads `default_budget()` →
`Application.fetch_env!(:letflow, :lua_max_instructions)` → `100_000`
(`config/config.exs:22`; not overridden in `config/test.exs`, confirmed by direct read —
no `lua_max_instructions` key exists in `config/test.exs`). The converted calls pass the
literal `100_000` to preserve the exact effective budget these tests run under today, per
this project's own precedent (ISS-0426's converted Group-1 sites use explicit literal
budgets — see `executor_test.exs:257-267` — never `Application.fetch_env!/2` inline in a
test).

**Manifest:** for bare-binary `script_ref` sites, the wrapper passes
`%Manifest{script_id: "", capabilities: []}` (REQ-158's normalize-bare-binary rule,
`executor.ex:389-391`) — the converted calls construct this literal directly, matching
existing Group-1 precedent (e.g. `executor_test.exs:260`,
`@empty_manifest`/inline-literal usage throughout the file). For the two REQ-158 sites
that already pass a `%{manifest: ..., script_source: ...}` map, the map's own `manifest`
and `script_source` fields are passed directly — `normalize_script_ref/1` is a no-op
pass-through for an already-valid map (`executor.ex:393-396`), so this is behaviorally
identical, not an approximation.

| # | Line(s) | Test | Before | After |
|---|---|---|---|---|
| 1 | 66 | AC3 "global isolation", call 1 | `Executor.execute_with_manifest("MY_GLOBAL = 42", "any-hash")` | `Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, "MY_GLOBAL = 42", 100_000)` |
| 2 | 72-76 | AC3 "global isolation", call 2 | `Executor.execute_with_manifest("if MY_GLOBAL ~= nil then error(...) end", "any-hash")` | `Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, "if MY_GLOBAL ~= nil then error(...) end", 100_000)` |
| 3 | 88 | AC4 "distinct state", call 1 | `Executor.execute_with_manifest("T = {}; T.x = 99", "h1")` | `Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, "T = {}; T.x = 99", 100_000)` |
| 4 | 92-96 | AC4 "distinct state", call 2 | `Executor.execute_with_manifest("if T ~= nil then error(...) end", "h2")` | `Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, "if T ~= nil then error(...) end", 100_000)` |
| 5 | 187-188 | "manifest hash correctness", bare-binary | `Executor.execute_with_manifest(script, "ignored")` | `Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, script, 100_000)` |
| 6 | 192 | "a Lua syntax error returns {:error, reason}" | `Executor.execute_with_manifest("this is not lua ===", "h")` | `Executor.run_script_sync(%Manifest{script_id: "", capabilities: []}, "this is not lua ===", 100_000)` |
| 7 | 208-212 | REQ-158 "manifest+script_source produces compute_hash/2's output" | `Executor.execute_with_manifest(%{manifest: manifest, script_source: script}, "ignored")` | `Executor.run_script_sync(manifest, script, 100_000)` |
| 8 | 224-225 | REQ-158 "capabilities change → hash changes", call 1 | `Executor.execute_with_manifest(%{manifest: manifest_a, script_source: script}, "h")` | `Executor.run_script_sync(manifest_a, script, 100_000)` |
| 9 | 227-228 | REQ-158 "capabilities change → hash changes", call 2 | `Executor.execute_with_manifest(%{manifest: manifest_b, script_source: script}, "h")` | `Executor.run_script_sync(manifest_b, script, 100_000)` |

**Not converted (excluded per §0, re-stated for CODE-DESIGN-VALIDATOR):** lines 235, 236,
239 (`normalize_script_ref/1` short-circuit cases: `12345`, `%{}`,
`%{manifest: :not_a_manifest, ...}`) stay as literal `execute_with_manifest/2` calls,
unchanged — they return `{:error, :invalid_script_ref}` synchronously, before any `Task`
exists, so they are not at risk and converting them would be pointless churn (there is no
`Task`-spawning path for `run_script_sync/3` to skip that these calls ever entered).

**Return-shape equivalence, asserted per site (so ELIXIR-DEV/TEST-DESIGNER can check
each conversion preserves what's actually being tested):**

- Sites 1-4 (AC3/AC4): assert `{:ok, _}` only — `run_script_sync/3` returns
  `{:ok, %{manifest_hash: _}}` on natural completion (`run_script/3`,
  `executor.ex:405-411`), matching `{:ok, _}` trivially.
- Site 5: asserts `{:ok, %{manifest_hash: ^expected_hash}}` where `expected_hash =
  Manifest.compute_hash(%Manifest{script_id: "", capabilities: []}, script)` —
  `run_script/3` computes `Manifest.compute_hash(manifest, script_source)` internally
  (`executor.ex:410`) with the exact same manifest, so the hash is identical.
- Site 6: asserts `{:error, _reason}` (generic) — `run_script/3` rescues
  `Lua.CompilerException` as `{:error, Exception.message(e)}` (`executor.ex:420-421`),
  the same branch `execute_with_manifest/3` reaches via the same `run_script/3` call
  today (the wrapper adds no additional shaping on this branch).
- Sites 7-9: assert `{:ok, %{manifest_hash: ^expected_hash}}` /
  `refute hash_a == hash_b` — `run_script_sync/3` computes the hash via the same
  `Manifest.compute_hash(manifest, script_source)` call with the exact `manifest` value
  the test constructs, preserving both the exact-match and the differs-by-capability
  properties.

## 3. What does NOT change

- `lib/letflow/engine/lua/executor.ex` — zero edits. `execute_with_manifest/2,3`,
  `run_script_sync/3`, `run_with_heap_limit_sync/4` all pre-exist, byte-for-byte
  unchanged.
- The 9 tests' own assertions, workload scripts, and `describe`/`test` structure —
  unchanged. Only the call expression itself changes, per the table in §2.
- The 3 short-circuit `normalize_script_ref/1` rejection tests (lines 235, 236, 239) —
  unchanged, left as literal `execute_with_manifest/2` calls (§2's exclusion note).
- `test/letflow/engine/lua/manifest_test.exs:293` — unchanged. It is a real 2-arity call
  to the real `Executor`, but on a dead branch never taken at runtime (§0) — converting
  it would be editing unreachable code for no safety benefit, and this design does not
  do that.
- Every other file in `test/` — unchanged (§0's repo-wide check found nothing else at
  risk).
- `test/test_helper.exs`'s `exclude:` list and `lib/mix/tasks/letflow.check.test.ex` —
  unchanged. This design adds no new tag, so ISS-0426's existing `:lua_wallclock_race`
  wiring needs no further changes.

## 4. Regression-test guidance for TEST-DESIGNER

**The literal fail-then-pass rule (WF-03 Step 2-4) does not transfer mechanically here,
for the same reason it didn't for ISS-0426 itself** (`iss426-wallclock-test-contention.md`
§4, restated in `executor_test.exs:1177-1182`): ISSUE-FIXER could not reproduce the race
directly (ISS-0876.yaml's own repro-attempts section — 8 concurrent runs, 0 failures).
"Run it many times and see if it still flakes" is not available as evidence here, on
either side of the fix. Follow the exact same class of proof ISS-0426 itself used
(`executor_test.exs:1167-1236`'s "seam-equivalence and tag-partition integrity coverage"
block), applied to these 9 sites specifically:

1. **Structural check (primary evidence, no flake reproduction needed):** confirm via
   `git diff`/source read that each of the 9 sites in §2's table now calls
   `Executor.run_script_sync/3` and that no bare
   `Executor.execute_with_manifest(script_ref, registered_hash)` 2-arity call remains
   anywhere in `executor_test.exs` **except** the 3 short-circuit sites (235, 236, 239)
   explicitly excluded in §2 — a test asserting this by reading the file's own source
   (e.g. `File.read!/1` + a `refute source =~ ~r/execute_with_manifest\(\s*[^,]+,\s*"[^"]*"\s*\)/`-shaped
   check, scoped to exclude the 3 known-safe lines, or a simpler line-count assertion
   pinned to the 3 expected survivors) is in the same spirit as this file's own AC2 test
   (line 51, `refute source =~ "Letflow.Engine.Lua.Executor"`) and AC1's
   `function_exported?/3` check — a source-level assertion, not a runtime race
   reproduction. This is the load-bearing check: it proves the 9 sites are structurally
   incapable of reaching `{:error, {:wallclock_timeout, _}}` again, the same "failure
   branch made unreachable, confirmed by reading the diff" standard ISS-0426's own §4
   used for its 14 sites.
2. **Behavioral equivalence, for each of the two return shapes these 9 sites introduce
   that ISS-0426's own seam-equivalence suite (`executor_test.exs:1212-1236` and
   following) did not yet exercise:**
   - **Non-empty-manifest hash equivalence.** ISS-0426's own equivalence tests
     (`executor_test.exs:1217-1236`) compare `run_script_sync/3` against
     `execute_with_manifest/3` only for `%Manifest{script_id: "", capabilities: []}`
     (empty-manifest) workloads. Sites 7-9 in this design (§2) are the first
     `run_script_sync/3` callers to pass a **non-empty** manifest
     (`%Manifest{script_id: "script-abc", capabilities: [...]}`). Add one test proving
     `run_script_sync/3`'s returned `manifest_hash` for a non-empty manifest matches
     `execute_with_manifest/3`'s (racing counterpart, generous timeout, same
     `max_heap_words: nil`) for the same `(manifest, script)` pair — mirroring
     `executor_test.exs:1217-1232`'s existing pattern exactly, just with a non-empty
     manifest input.
   - **Syntax-error (`Lua.CompilerException`) shape equivalence.** ISS-0426's own
     equivalence suite covers `:ok`, `budget_exceeded`, `script_error`, and
     `memory_limit_exceeded` outcomes (per `executor_test.exs:1183-1198`'s own stated
     scope) — it does not cover the `Lua.CompilerException` branch (site 6, a bare
     syntax error, `{:error, Exception.message(e)}`). Add one test proving
     `run_script_sync/3` and `execute_with_manifest/3` (racing counterpart) return the
     identical `{:error, _}` value for the same invalid-syntax script — closing the one
     outcome-shape gap this design's own conversions introduce beyond what ISS-0426
     already proved equivalent.
3. **Regression guard against the exact 9 sites being silently re-widened back to the
   racing path.** A source-level test (or an extension of item 1) that pins the count of
   `run_script_sync(`/`run_with_heap_limit_sync(` call sites in `executor_test.exs`
   (mirroring this file's own existing self-check pattern at line 1376 for
   `:lua_wallclock_race` tag count) to `14 (ISS-0426) + 9 (ISS-0876) = 23`, so a future
   edit that reverts one of these 9 conversions back to a bare `execute_with_manifest/2`
   call fails loudly rather than silently reintroducing the race.
4. **Confirmatory, not load-bearing (optional, matching ISS-0426's own §4 point 4
   treatment):** `mix test test/letflow/engine/lua/executor_test.exs` passes serially,
   and, if time permits, a `scripts/test_parallel.sh TEST_PARALLEL_N=6` run — this
   remains end-to-end confirmatory only, per the same reasoning ISS-0426's own design
   gives for why it isn't required to trust the structural fix.

**Mutation/fail-first per WF-03's own "code under test does not exist" carve-out does
NOT apply here** — unlike ISS-0426's *seam*, which was new code, `run_script_sync/3`
already exists and is already exercised by 14 other call sites; this design only adds
new *callers* of already-tested code. The correct fail-first proof is: (a) on
**pre-fix** code (these 9 sites still calling `execute_with_manifest/2`), the structural
check in item 1 above fails (the bare 2-arity calls are still present) — a real,
non-probabilistic, immediate failure, not a flake-dependent one; (b) on **post-fix**
code, it passes. This is the correct application of WF-03's fail-then-pass rule for a
fix whose defect was itself structural (a call-shape gap), not behavioral.

## 5. Acceptance-criteria coverage (ISS-0876)

| Requirement (from ISS-0876.yaml's `recommended_next_step`) | Design element |
|---|---|
| Extend ISS-0426's Group-1 treatment (or tag) to the 9 call sites / 7 tests | §1 (option chosen + why), §2 (exact before/after for all 9) |
| Repo-wide check for the same 2-arity blind spot elsewhere | §0 |
| State which option and why | §1 |
| Exact before/after code shapes, unambiguous | §2's table |
| What "proof" should look like, given the race can't be reproduced on demand | §4 |

## 6. Open questions

None. Every call site converts to an already-existing seam with a directly-checkable
return-shape equivalence (§2); no new production code or new design latitude is needed.
