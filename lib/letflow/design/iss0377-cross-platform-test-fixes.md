# ISS-0377 — Cross-platform test-suite fixes: wasmex artifact assertions and parallel-partition build-path isolation

Status: DESIGN (WF-03 Step 2)
Issue: `docs/issues/ISS-0377.yaml`
Diagnosis source: `handoffs/WF03-ISS0377-20260830/step-01-issue-fixer.json` (`result.summary`)
Depends on / must not contradict: `lib/letflow/design/req113-parallel-test-runner.md` (AC4, AC5,
§4.1, §4.2, §8 invariants)

This document designs fixes for two independent, unrelated portability defects.
No implementation code is included — signatures, data shapes, and pseudocode only.
Both fixes must be built by ELIXIR-DEV against this design in WF-03 Step 3.

---

## Part A — Fix 1: `test/letflow/engine/wasm/plugin_handler_test.exs` AC7 describe block

### A.1 Problem recap

Two assertions in the `"AC7: the wasmex NIF is a loaded shared library, not an
external process"` describe block (lines 180–198) hardcode Unix-only, version-blind
assumptions about wasmex's bundled NIF artifact:

- Line 189: `String.contains?(&1, "native/wasmex/src/")` against
  `Wasmex.Native`'s `:external_resource` attributes.
- Line 197: `Path.join(priv_dir, "native/wasmex.so")` + `File.exists?/1`.

### A.2 Ground truth established during design (read from the vendored dependency,
not guessed)

Inspected directly in this sandbox: `deps/wasmex/mix.exs`, `deps/wasmex/lib/wasmex/native.ex`,
`deps/wasmex/priv/native/`, `mix.lock`.

- `Wasmex.Native` is built via `use RustlerPrecompiled, otp_app: :wasmex, ...,
  targets: ~w(... x86_64-pc-windows-msvc x86_64-pc-windows-gnu
  x86_64-unknown-linux-gnu aarch64-apple-darwin ...)`. `RustlerPrecompiled`
  downloads (or builds) a *target-and-version-qualified* artifact named like
  `libwasmex-v0.15.1-nif-2.15-x86_64-unknown-linux-gnu.so`, then — because Erlang's
  `:erlang.load_nif/2` loads a NIF by a *fixed, version-free* name relative to the
  app's `priv/` directory — copies/links that qualified artifact to a **fixed
  loadable filename equal to the NIF module's declared load name, with the
  platform's native shared-library extension appended by the VM itself**. For
  wasmex that fixed load name is `wasmex`, so the loadable copy observed on this
  Linux sandbox is `priv/native/wasmex.so` (confirmed present alongside the
  qualified original in `deps/wasmex/priv/native/`).
- The platform-native extension is what changes across OS, not the fixed base
  name: it is `.so` on Linux/most BSDs, `.dylib`-shaped internally but Erlang
  still expects the OS's dynamic-library convention (see mapping table below —
  on macOS Erlang's own NIF loader still looks for `.so`, not `.dylib`; this is
  an Erlang/OTP loader convention, not a Rust/Cargo one — see A.4 note), and
  `.dll` on Windows (both `x86_64-pc-windows-msvc` and `x86_64-pc-windows-gnu`
  targets are declared).
- Package manifest (`deps/wasmex/mix.exs`'s `package: [files: [...]]`) lists
  `native/wasmex/src` as a real, hex-package-shipped source subtree — this is
  the Rust crate source directory wasmex is built from, and it is *this* path
  (not a `native/wasmex.so`-adjacent path) that `:external_resource` entries
  trace back to when the crate is compiled from source. `native/wasmex/src`
  is a source-code-layout fact about the *wasmex Cargo crate*, not an
  OS-specific fact — it does not vary across host platform. What can vary
  build-to-build is whether `:external_resource` is populated at all (a
  precompiled/downloaded-artifact build path may attach zero or a different
  set of `:external_resource` entries than a from-source build, depending on
  the installed `rustler_precompiled` version's instrumentation) — this is the
  real fragility, not a Unix-vs-Windows split.

### A.3 What AC7 actually requires (the invariant to preserve)

AC7's real claim, per the requirement this test enforces: *the wasm NIF is a
compiled-in, bundled artifact loaded in-process — not an external runtime spawned
as a subprocess or fetched over the network at invoke time.* Neither assertion
needs to know the artifact's literal filename or directory shape to prove that;
they need to observe **some** platform-appropriate compiled binary artifact
physically present under wasmex's own `priv/`, and **some** evidence that the NIF
module's build is source-tracked (not merely declared).

### A.4 Fix design — assertion 2 (the `.so` path, line 197)

Replace the single hardcoded `Path.join(priv_dir, "native/wasmex.so")` +
`File.exists?/1` check with a two-step, platform-derived check:

1. **Derive the expected extension from `:os.type/0`**, not from a literal.
   Mapping table (this table itself is the design artefact — ELIXIR-DEV
   encodes it as a `case`/map, not as prose left to interpretation):

   | `:os.type/0` result | Expected loadable-artifact extension |
   |---|---|
   | `{:unix, :linux}` | `.so` |
   | `{:unix, :freebsd}` | `.so` |
   | `{:unix, :darwin}` | `.so` (Erlang/OTP's own NIF loader convention on macOS uses `.so`, not `.dylib`, even though Cargo's own macOS dynamic-library output uses `.dylib` internally before `rustler_precompiled` renames/packages it for Erlang's loader — do not "correct" this to `.dylib`, it would break the real loader contract) |
   | `{:win32, _}` (both `nt` variants) | `.dll` |
   | anything else | fail the test explicitly with a clear message naming the unhandled `:os.type/0` value, rather than silently skipping — an unmapped OS must be a loud test failure, not a green no-op |

2. **Assert existence of the fixed-name loadable artifact for that extension**:
   `Path.join([priv_dir, "native", "wasmex" <> expected_ext])` must exist via
   `File.exists?/1` (mirrors today's structure, just with a derived extension
   instead of a literal `.so`). This keeps the assertion precise (it still
   checks the *exact* file the NIF loader will actually load) while removing
   the Unix-only literal.
3. **Defensive fallback (belt-and-suspenders, not a replacement for step 2):**
   if step 2's fixed-name file is absent (e.g. a future `rustler_precompiled`
   version changes its copy/link strategy), fall back to a directory listing
   of `Path.join(priv_dir, "native")` and assert at least one entry ends with
   the platform-derived extension from the table above. This is what the
   diagnosis's "glob-based match" suggestion becomes concretely: a fallback,
   not the primary assertion, because the primary assertion (fixed load name)
   is now known to be correct from reading the actual dependency rather than
   guessed. Fail with a message distinguishing "fixed-name file missing" from
   "no artifact of the expected extension found at all" so a future diagnosis
   doesn't have to re-derive which branch fired.

### A.5 Fix design — assertion 1 (the `:external_resource` substring, line 189)

Do not hardcode `"native/wasmex/src/"` as a substring match (even though A.2
established it's platform-invariant, coupling the test to wasmex's internal Cargo
layout is still fragile to a future wasmex restructuring, per the diagnosis).
Replace with a structural assertion that doesn't name a specific directory:

1. Fetch `external_resources` exactly as today (`Wasmex.Native.module_info(:attributes)
   |> Keyword.get_values(:external_resource) |> List.flatten()`).
2. **Branch on whether the list is empty**, because a precompiled/downloaded
   build may legitimately attach zero `:external_resource` entries (see A.2):
   - If **non-empty**: assert **at least one** entry has a source-code
     extension appropriate to the NIF's implementation language —
     `Enum.any?/2` with `String.ends_with?/2` against `.rs` (Rust source) —
     rather than asserting a specific directory substring, and rather than
     requiring *every* entry to end in `.rs`. This is deliberate, not a
     weaker stand-in for the stronger check: under this project's own
     always-on `WASMEX_BUILD=true` build configuration (`.github/workflows/
     ci.yml`, REQ-165), `Wasmex.Native` compiles through `use Rustler`'s
     from-source path, whose `Rustler.Compiler.Config.external_resources/3`
     globs the *entire* crate directory tree (rejecting only `target/` and
     directories, with no extension filter at all — see
     `deps/rustler/lib/rustler/compiler/config.ex`). The real vendored
     crate at `deps/wasmex/native/wasmex/` confirms this in practice: its
     `:external_resource` list mixes `.rs` sources under `src/` together
     with non-`.rs` files the same glob sweeps in — `README.md`,
     `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml`. An "every entry ends
     in `.rs`" assertion is therefore false on this project's own real,
     mandated build path and would raise a real `ExUnit.AssertionError` the
     moment it runs. "At least one entry ends in `.rs`" is the correct,
     non-vacuous invariant here: it still proves real Rust build inputs are
     genuinely tracked (ruling out an empty-of-substance list slipping past
     a non-empty check), without asserting anything about the *rest* of the
     list's composition, which this branch has no business constraining.
   - If **empty**: do not fail. Instead assert the fallback invariant from A.4
     step 3 holds (a real compiled artifact is present under `priv/native`)
     and record — via a passing assertion with a descriptive message, e.g.
     `assert priv_artifact_present?, "expected a compiled NIF artifact under priv/native since :external_resource is empty for this build"`
     — that this build path is the precompiled/downloaded one, not a
     from-source one. This makes the test pass correctly under both build
     strategies instead of assuming a from-source build always attaches
     `:external_resource` entries, which the diagnosis flagged as unverified.
3. Either branch must produce a clear failure message stating which branch
   ran and what was expected, so a future failure doesn't need to re-read this
   design doc to interpret it.

### A.6 Explicit non-goal (do not do this)

Do **not** wrap either assertion in `if match?({:unix, _}, :os.type()) do ... end`
or an equivalent skip/tag-exclude for non-Unix hosts. That suppresses the
assertion on Windows rather than making it correct there, which
`fix_requirements.symptom_1` in the Step 2 handoff explicitly rules out of
scope, and which CODE-DESIGN-VALIDATOR must reject if seen in the implementation.

### A.7 Open question (not silently resolved)

- **OQ-A1**: Whether `:external_resource` is actually empty or non-empty on
  a `rustler_precompiled` (non-`WASMEX_BUILD=1`) build of the currently locked
  wasmex `0.15.1` could not be directly verified in this sandbox (no `mix`
  toolchain available to run `Wasmex.Native.module_info/1` in this design
  session — see Bash tool output; only static source/priv-directory inspection
  was possible). ELIXIR-DEV must verify this empirically when implementing (a
  one-line `mix run -e` check) and confirm which of A.5 step 2's two branches
  actually fires on the CI/dev hosts this repo targets, rather than assuming.

---

## Part B — Fix 2: `scripts/test_parallel.sh` per-partition build-path isolation

### B.1 Problem recap

Step 1 (lines 96–104) does one `MIX_ENV=test mix compile` before any partition
launches specifically so partitions never race a concurrent compile. Step 2
(lines 176–204) then launches all N `MIX_TEST_PARTITION=<i> mix test --partitions
N ...` processes with **no `MIX_BUILD_PATH` override**, so every partition still
points at the one shared `_build/test` tree for its *entire* run (not just the
pre-compile), and each `mix test` process's own startup manifest/lock/
consolidation-cache touches on that shared path race against sibling partitions —
tolerated (mostly) on POSIX, but surfacing as a hard abort
(`could not create hard link ... permission denied`) on Windows/NTFS's stricter
hard-link semantics.

### B.2 The real tradeoff

| Approach | Race eliminated? | Extra disk cost | Extra time cost | Interaction with Step 1's existing single pre-compile |
|---|---|---|---|---|
| **(1) Do nothing / detect-Windows-and-retry** | No — race remains, only the failure surface is papered over | None | None | Unaffected | 
| **(2) Per-partition `MIX_BUILD_PATH`, each partition compiles independently (no shared pre-compile)** | Yes | N full `_build/test-partition-<i>` trees | N *independent* full compiles instead of 1 shared one — the single most expensive step this script's whole design (req113 AC5) exists to avoid paying N times | Would delete Step 1 entirely, directly reintroducing the cost req113 AC5 was written to prevent |
| **(3) Per-partition `MIX_BUILD_PATH`, warmed by copying/hardlinking the one Step-1-compiled tree into each partition path before backgrounding** | Yes | N full `_build/test-partition-<i>` trees on disk (copy) or N directory trees of hardlinks (near-zero extra disk, same inode data) | One extra fast copy/link pass per partition, done **sequentially before any partition backgrounds**, not concurrently — no race, because nothing runs in parallel during this pass | Keeps Step 1's single compile as the source of truth; Step 2 changes from "launch directly against the shared tree" to "seed N private trees from the shared tree, then launch directly against each partition's now-independent tree" |
| **(4) Symlink each partition's `_build/test-partition-<i>` at the directory level back to the single shared `_build/test`** | No — this is approach (1) in disguise: the underlying build path is still the same physical directory, so the same race exists | None | None | Unaffected |

### B.3 Recommendation: **Approach (3)** — per-partition `MIX_BUILD_PATH`, seeded once from Step 1's single shared compile via a sequential hardlink pass, *not* independent per-partition recompilation

Rationale, weighed explicitly against req113-parallel-test-runner.md's existing
constraints:

- **AC5 / §4.2 already requires exactly one `MIX_ENV=test mix compile` before any
  partition launches**, and the design doc's own rationale for that (§4.2: "every
  ... invocation launched in step 2 sees an already-current `_build/test` and
  performs no compilation of its own ... this is the concrete mechanism that
  prevents the concurrent-compile race") is exactly the property Approach (2)
  would destroy — N independent per-partition build paths each starting cold
  would force N full compiles, each redoing the same expensive Rust-NIF-adjacent
  and Elixir compilation Step 1 was written to pay for once. On a project whose
  own stated purpose for this script is "parallelize a single-connection-pool-
  constrained suite to keep CI fast" (see script's own header, §1's ISS-0219/
  ISS-0194/ISS-0287 tuning history), paying full compile cost N times instead of
  once is a regression this design must not reintroduce — the Step 1 handoff's
  diagnosis explicitly names this as the failure mode to avoid.
- **Approach (1)** (detect Windows, retry/serialize hard-link errors) is exactly
  what the Step 2 handoff's `fix_requirements.symptom_2` rules out of scope: it
  suppresses the *symptom* (the Windows-specific abort text) without removing
  the underlying shared-path race, which remains latent and load-bearing-fragile
  on every OS (the diagnosis is explicit that the race exists on POSIX too, just
  tolerated more often, not never).
- **Approach (4)** doesn't actually create isolation — a symlinked directory
  still resolves to the one physical `_build/test` tree Mix's lock/manifest
  logic operates on, so the race is unchanged. Rejected as a non-fix.
- **Approach (3)**'s one-time seeding cost is a **copy/hardlink of an
  already-compiled, already-current tree** — no compilation happens during
  seeding, only filesystem-level duplication of an existing build artifact set,
  and hardlinking specifically keeps the "extra disk cost" cell in the tradeoff
  table near-zero (shared inode data, N separate directory-entry namespaces) —
  while still giving each partition's `mix test` process a **path-level-distinct
  `_build/test-partition-<i>` directory** so no two partitions' OS processes ever
  touch the same physical directory path concurrently, which is what actually
  eliminates the race Mix's own internal hard-link-based build-lock/manifest
  mechanism exhibits (this is the same mechanism whose Windows-specific failure
  mode is the reported symptom — see B.1). Sequencing the seed pass strictly
  *before* any partition backgrounds (no concurrency during seeding) means the
  seed pass itself introduces no new race.
- Note for ELIXIR-DEV: whether the seeding step uses OS-level hardlinks
  (`ln`/`cp -al` on Linux) or a plain recursive copy is an implementation
  choice within Approach (3), not a design fork — hardlinks are preferred for
  disk-cost reasons per the tradeoff table, but a plain copy is an acceptable
  fallback wherever the target filesystem doesn't support hardlinks (e.g. some
  network/overlay filesystems) as long as it still produces a **fully
  independent, distinctly-pathed** directory per partition. This is not
  Windows-specific special-casing (rejected above) — it is a portable seeding
  mechanism, chosen once, that applies identically regardless of which OS
  ultimately runs the script.

### B.4 Concrete flow change to `scripts/test_parallel.sh`

Insert a new step between today's Step 1 (pre-compile) and Step 2 (partition
launch) — call it **Step 1.6** (after the existing Step 1.5 pool-size clamp,
which is unaffected and stays where it is):

**Step 1.6 — seed N per-partition build paths from the single compiled tree
(sequential, before any partition backgrounds):**

- For `i` in `1..N` (same loop shape as the existing partition loops):
  - Define `partition_build_path_i = "_build/test-partition-<i>"` (a name
    that must never collide with the plain `_build/test` the pre-compile step
    populated, and must be distinct per `i`).
  - If `partition_build_path_i` does not yet exist (first run) **or** is
    stale relative to the just-completed compile (subsequent runs of this
    script against the same checkout): (re)populate it from `_build/test` via
    a recursive hardlink-preferring copy (`cp -al` semantics on platforms that
    support it; fall back to a plain recursive copy where hardlinks aren't
    supported — see B.3's note). This must complete and exit 0 for every `i`
    before Step 2 launches any partition — a failure here must abort with a
    clear message and a nonzero exit, exactly like a Step-1 compile failure
    does today (mirrors the existing "no partition process is ever launched on
    a failed compile" invariant in §8 of req113's design doc — extend that
    invariant's wording to also cover "or a failed seed pass").
  - This step is `O(N)` sequential filesystem operations, not `O(N)` compiles —
    each iteration operates on an already-fully-compiled, static source tree,
    so there is nothing to race even though the loop itself is sequential
    (single-process, single-directory-tree-read-per-iteration).
- **Idempotency / repeated-invocation note:** a second invocation of this
  script on an unchanged checkout should be able to reuse existing
  `_build/test-partition-<i>` directories without re-seeding if they're
  already current (e.g. compare a marker/timestamp against `_build/test`'s own
  compile manifest, or simply always reseed — ELIXIR-DEV's choice, flagged as
  **OQ-B1** below since it's a performance-vs-simplicity tradeoff this design
  doesn't need to force one way).

**Step 2 change (partition launch, today's lines 176–204):** each backgrounded
`MIX_TEST_PARTITION="$i" mix test --partitions "$N" ...` invocation must now
also export `MIX_BUILD_PATH="_build/test-partition-$i"` scoped to that
subprocess only (e.g. as a leading env-var assignment on the same command line
that launches the background job, the same idiom already used for
`MIX_TEST_PARTITION`) — **not** a script-global `export` that would leak into
later unrelated Mix invocations in the same shell (contrast with
`TEST_PARALLEL_GROUP`/`TEST_POOL_SIZE`, which *are* deliberately global-exported
today because every partition is meant to see the same value; `MIX_BUILD_PATH`
is the opposite case — every partition must see a *different* value, so it must
be set per-invocation, not globally exported).

No other step changes. Step 3 (wait per-PID), Step 4 (log parsing), and Step 5
(exit-code derivation) are unaffected — they operate on the log files under
`mktemp -d`, which were never build-path-coupled.

### B.5 Invariant updates (extends req113's §8 list, does not replace it)

- No two concurrently-running `mix test` OS processes launched by this script
  may ever share a `MIX_BUILD_PATH` value.
- The Step 1.6 seed pass for all N partitions must complete (exit 0 for every
  `i`) before Step 2 backgrounds any partition — mirrors the existing
  pre-compile-before-launch invariant.
- `MIX_BUILD_PATH` must be set per-partition-invocation (command-scoped), never
  globally exported for the whole script process, to avoid leaking a specific
  partition's build path into an unrelated later Mix invocation in the same
  shell session.
- `_build/test-partition-<i>` directories are script-managed working state
  (like the `mktemp -d` log directory) — not repo-tracked, and this design does
  not require the script to delete them after a run (parallel with req113's
  existing statement that the script does not delete/truncate the
  `letflow_test<i>` databases itself); a future cleanup requirement, if wanted,
  is out of scope here.

### B.6 Open questions (not silently resolved)

- **OQ-B1**: Reseed every run vs. reuse-if-current for `_build/test-partition-<i>`.
  Reseeding every run is simpler and always correct but pays a repeated
  copy/hardlink cost on every invocation, even when nothing changed. Reuse-if-
  current is faster on repeated runs but needs a staleness check whose false-
  negative failure mode (reusing a stale partition build) would be silent and
  hard to diagnose. ELIXIR-DEV/REVIEWER should pick, informed by how often this
  script is invoked repeatedly against an unchanged checkout in this project's
  actual CI usage pattern — not decided here.
- **OQ-B2**: Exact hardlink command/library call ELIXIR-DEV uses for the seed
  pass (`cp -al`, `cp -r --link`, a small recursive-hardlink helper, etc.) is an
  implementation detail deliberately left open — the design's requirement is
  only "distinct physical directory per partition, seeded without recompiling,"
  not a specific tool invocation.
- **OQ-B3**: Whether `_build/test-partition-<i>` directories should be
  git-ignored explicitly (in case `_build/` isn't already covered by a broad
  ignore pattern) is an implementation checklist item, not a design fork —
  ELIXIR-DEV should verify `.gitignore` already covers `_build/*` and note it if
  not.

---

## Part C — Cross-cutting notes

- These two fixes are independent (different files, different failure
  mechanisms per the Step 1 diagnosis) and can be implemented and reviewed as
  two separate, small changes within the same WF-03 Step 3 pass, or split
  across two ELIXIR-DEV turns if REVIEWER prefers smaller diffs — this design
  does not require them to land in one commit.
- Regression tests (WF-03 Step 4, TEST-DESIGNER) for Part A must exercise the
  new branch logic in A.4/A.5 in a way that doesn't itself hardcode the
  current host's extension — e.g. assert the *derivation function's* output
  against a table of `:os.type/0` inputs (unit-testable independent of which
  OS the test suite actually runs on), plus the existing integration-style
  check against the real installed wasmex on whichever host runs the suite.
  Part B has no unit-testable Elixir surface (it's a bash script's control
  flow) — its regression coverage is necessarily a script-level check (e.g.
  assert that two `MIX_BUILD_PATH` values captured from two partitions' logged
  environment differ) rather than an ExUnit test; TEST-DESIGNER should confirm
  this project's existing precedent for testing `scripts/*.sh` (if any) before
  assuming ExUnit is the only vehicle.
