# CODE-DESIGN-VALIDATOR findings — ISS-0377 design (iteration 1) — FAIL

Design reviewed: `lib/letflow/design/iss0377-cross-platform-test-fixes.md`
Verified against real code, not the design's narrative, per task instructions.

## Verdict: FAIL — one confirmed, concrete defect in Part A (symptom 1 fix)

## What checked out

1. **wasmex artifact naming / extension mapping table.** Confirmed directly
   against `deps/rustler/lib/rustler/compiler.ex` lines 176-180
   (`suffix/2`: `{:win32,_} -> ".dll"`, `{:unix,:darwin} -> ".so"`,
   `{:unix,_} -> ".so"`) — this is the exact table the design reproduces in
   A.4. Confirmed a fixed-load-name file (`priv/native/wasmex.so`, base name
   = crate name = `:wasmex`) does exist alongside the target-qualified
   RustlerPrecompiled download (`libwasmex-v0.15.1-nif-2.15-x86_64-unknown-
   linux-gnu.so`) in `deps/wasmex/priv/native/` on this sandbox. However the
   design's narrative attributes the fixed-name copy to *RustlerPrecompiled
   itself* ("RustlerPrecompiled ... copies/links that qualified artifact to
   a fixed loadable filename"). Reading `deps/rustler_precompiled/lib/
   rustler_precompiled.ex` line 742 shows RustlerPrecompiled's own
   `load_from` tuple uses the **qualified** `lib_name` (with target triple),
   never a fixed name — RustlerPrecompiled loads the qualified file
   directly via `:erlang.load_nif`, no fixed-name copy step exists in that
   code path. The fixed name (`wasmex.so`) is actually produced by
   `Rustler.Compiler` (`deps/rustler/lib/rustler/compiler.ex`, the
   **from-source force-build** path, active whenever `WASMEX_BUILD=true` —
   which this project's own CI (`.github/workflows/ci.yml:128`) and
   REQ-165 always set). This is a real misattribution of *why* the fixed
   name exists, though it doesn't invalidate the extension table (both
   code paths independently derive the same `.so`/`.dll` suffix via the
   same OS-type switch) or the fallback design (A.4 step 3), which is
   robust to either mechanism actually firing. Downgraded from blocking to
   a narrative-accuracy note — does not by itself justify FAIL.

2. **OQ-A1 (external_resource emptiness) — resolved, not by toolchain, by
   direct BEAM inspection.** No `mix`/`elixir`/`erl` binary exists in this
   sandbox (confirmed), but the `Attr` chunk of the already-compiled
   `_build/test/lib/wasmex/ebin/Elixir.Wasmex.Native.beam` was decoded
   directly (manual BEAM chunk parse + Erlang external-term-format read):
   its `Attr` chunk is `[{:vsn, [...]}]` only — **no `:external_resource`
   key at all** for the currently-compiled artifact in this sandbox. This
   confirms the empty-list branch is a real, reachable state (this
   particular `_build/test` was evidently compiled via RustlerPrecompiled's
   non-force path, not a force build), and it is exactly the case A.5's
   "if empty" branch is designed for. No objection to A.5's branching
   structure on this count.

## The confirmed defect (blocking)

**A.5 step 2's non-empty-branch assertion ("every `:external_resource` entry
ends in `.rs`") is factually false against this project's own actual,
CI-mandated build path, and will fail as a real test in that configuration.**

- This project's CI (`.github/workflows/ci.yml`) and dev convention (per
  `test/reports/report-2026-08-28-WF02-REQ165-20260828.yaml`,
  `wasmex_build_flag: "WASMEX_BUILD=true set for all mix invocations"`)
  **always** set `WASMEX_BUILD=true`, which forces `Wasmex.Native` through
  `use Rustler, ...` (the from-source compile path), per
  `deps/rustler_precompiled/lib/rustler_precompiled.ex` lines 159-195
  (`{:force_build, only_rustler_opts} -> unquote(force)` where `force`
  quotes `use Rustler, only_rustler_opts`).
- `use Rustler` (`deps/rustler/lib/rustler.ex` lines 94-101) sets
  `@external_resource resource for resource <- config.external_resources`.
- `config.external_resources` is built by `Rustler.Compiler.Config.
  external_resources/3` (`deps/rustler/lib/rustler/compiler/config.ex` lines
  85-93): it globs `Path.join(path, "**/*") |> Path.wildcard()`, rejecting
  only entries under `#{path}/target/` and directories — **no extension
  filter of any kind**. It sweeps in every file under the crate directory.
- The real crate directory (`deps/wasmex/native/wasmex/`) verified by
  listing contains, alongside the `.rs` files under `src/`:
  `README.md`, `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml` — none of
  which end in `.rs`.
- Therefore, on this project's actual mandated build configuration
  (`WASMEX_BUILD=true`), `Wasmex.Native`'s `:external_resource` list is
  non-empty **and** contains multiple non-`.rs` entries. The design's A.5
  step-2 "non-empty ⇒ assert every entry ends in `.rs`" assertion will
  raise a real `ExUnit.AssertionError` against this dependency exactly as
  currently vendored — this is not a hypothetical or a different-wasmex-
  version concern, it is the file tree present in `deps/wasmex/native/
  wasmex/` right now.

This is exactly the class of defect CODE-DESIGN-VALIDATOR exists to catch:
an assertion that looks structurally sound in prose but is empirically
wrong against the real dependency, which would only surface once ELIXIR-DEV
implements it and TEST-RUNNER (or CI) runs it — after both the design and
implementation gates have already been spent on it.

## Required rework

Section A.5 step 2 (non-empty branch) must derive its expectation from
what the real dependency's build tooling can actually produce, not "this
is Rust so it's `.rs`". Two directions that fit AC7's actual invariant
("these are real build inputs tracked by the compiler, not merely
declared") without asserting a directory shape:
- Assert the list is merely non-empty (drop the extension check entirely
  for the non-empty branch, matching AC7's real claim per A.3: existence
  of build-input tracking, not a specific file-type composition), or
- Assert that **at least one** entry ends in `.rs` (proving real Rust
  sources are among the tracked inputs) rather than requiring **every**
  entry to.

Either fix must be re-verified against the same real files inspected here
(`deps/wasmex/native/wasmex/` file listing) before being handed back to
CODE-DESIGN-VALIDATOR, not re-derived from prose alone.

## Item 3 — hardlink / MIX_BUILD_PATH staleness claim (scrutinized, not rubber-stamped)

This is architecturally sound, on the following reasoning verified against
`scripts/test_parallel.sh`'s real Step 1 (lines ~96-104, single
`MIX_ENV=test mix compile` before any partition launch) and Step 2 launch
loop (lines ~198-204, no `MIX_BUILD_PATH` override today):

- `docs/issues/ISS-0377.yaml`'s own title names the mechanism explicitly:
  "Windows ... MIX_OS_CONCURRENCY_LOCK hard-link contention" — this is
  Elixir/Mix's own built-in per-build-path OS-level concurrency lock
  (a hard-link-based atomic-create lock file, the classic NFS-safe locking
  idiom), which exists precisely to serialize concurrent OS processes
  touching the *same* build path. Today all N partitions target the
  identical `_build/test` path, so N processes contend that one lock;
  Windows' stricter hard-link error surface (permission-denied instead of
  POSIX's more tolerant EEXIST/retry path) is what turns the underlying,
  latent-on-every-OS race into a hard abort specifically there. Giving
  each partition a **distinct** `MIX_BUILD_PATH` means each has its own,
  uncontended concurrency-lock namespace — this directly removes the
  contention the lock exists to guard, not just its Windows failure mode.
- Mix's staleness/manifest checking is keyed off **source file** mtimes
  (files under `lib/`, `test/`, `deps/*/lib`, `mix.exs`) compared against
  manifest-recorded values — not off any property of the `_build` tree's
  own directory path or inode identity. A hardlink-preserving copy
  (`cp -al` semantics, as the design specifies) duplicates `_build/test`'s
  files with their **exact original mtimes and content** into each
  partition path; since none of the actual source files are touched by
  this copy, every partition's copy presents an identical "compiled,
  up-to-date" state to Mix's staleness check. Protocol-consolidation paths
  are computed at runtime from `Mix.Project.build_path()` (which reads
  `MIX_BUILD_PATH`), so they resolve correctly per-partition without
  needing any manifest rewrite.
- The one real hazard with hardlinks — an in-place mutation of shared
  inode data corrupting all N copies at once — would only bite if some
  process performed a non-atomic in-place write (open+truncate+write
  without rename) to a file under a partition's build path after seeding.
  Mix's own writes to compiled artifacts are lock-file/rename-based
  (exactly the create-a-temp-then-link/rename idiom the OS concurrency
  lock itself uses), which replaces the directory entry in that one
  partition's path rather than mutating the shared inode — so this
  doesn't reintroduce the race, provided (as the design already requires)
  the seed pass fully completes, sequentially, before any partition is
  backgrounded.
- Confirmed the design does not silently reintroduce a windows-only
  shortcut for this: B.3 explicitly rejects Approach 1 (detect-Windows-
  and-retry) as suppressing the symptom, not the race.

One non-blocking observation for CODE-DESIGNER/REVIEWER to consider later:
the design's B.2 tradeoff table doesn't mention `MIX_OS_CONCURRENCY_LOCK`
by name even though the issue's own title does — Elixir ships a native
knob for exactly this kind of shared-build-path contention (tuning/
disabling the lock's own retry behavior). It's not clear that knob alone
would fix the underlying race as completely as per-partition isolation
does (it addresses lock *contention handling*, not the fact that N
processes still share one physical build tree), so this is a documentation
gap, not a defect in the recommended approach.

## Items 4 and 5

- No fenced code blocks in the design file (grep for `` ``` `` returns
  nothing).
- No `:os.type()`-guarded skip is proposed for either symptom: A.6
  explicitly forbids it for symptom 1, and B.3 explicitly rejects
  Approach 1 (Windows-detect-and-retry) for symptom 2. Both non-goals
  called out by the Step 1 diagnosis are honored.

---

# CODE-DESIGN-VALIDATOR findings — ISS-0377 design (iteration 2, re-check after rework 1) — PASS

Design reviewed: `lib/letflow/design/iss0377-cross-platform-test-fixes.md` at commit `697987b`.

## Scope of this re-check

Per `handoffs/WF03-ISS0377-20260830/step-02b-code-design-validator.json`, re-checked
only: (1) A.5 step 2's corrected non-empty-`:external_resource`-branch assertion, and
(2) that nothing else in the design regressed.

## (1) A.5 step 2 assertion — verified correct

The design now asserts, for the non-empty branch, that **at least one**
`:external_resource` entry ends in `.rs` (`Enum.any?/2` + `String.ends_with?/2`),
replacing the prior (empirically false) "every entry ends in `.rs`" assertion.

Re-verified independently against the real vendored tree and Rustler's own source,
not re-derived from the design's prose:

- `find deps/wasmex/native/wasmex -type f` (this session) confirms the crate
  directory contains a mix of `.rs` files under `src/` (component.rs, engine.rs,
  lib.rs, memory.rs, etc.) together with non-`.rs` files at the crate root and in
  `.cargo/`: `README.md`, `Cargo.toml`, `Cargo.lock`, `.cargo/config.toml`.
- Read `deps/rustler/lib/rustler/compiler/config.ex` lines 85-98 (`external_resources/3`
  → `expand_paths/1`) directly: it globs `Path.join(path, "**/*") |> Path.wildcard()`
  and rejects only entries under `#{path}/target/` and directories — no extension
  filter of any kind. This confirms the design's citation of this function and its
  behavior is accurate.
- Consequence: against this real tree, "at least one entry ends in `.rs`" evaluates
  **true** (many `.rs` entries present) — the assertion passes. "Every entry ends in
  `.rs`" would evaluate **false** (README.md, Cargo.toml, Cargo.lock, .cargo/config.toml
  are swept in and don't end in `.rs`) — confirming the prior FAIL was correct and the
  new assertion fixes it.

Verdict: the corrected assertion is empirically true against the real, currently
vendored dependency under this project's own mandated `WASMEX_BUILD=true` build path.
No defect found.

## (2) Regression check — nothing else changed

`git diff 10e490a 697987b -- lib/letflow/design/iss0377-cross-platform-test-fixes.md`
shows a diff scoped exactly to A.5 step 2's non-empty-branch assertion text (the
bullet replacing "assert every entry..." with "assert at least one entry..." plus its
justifying prose). Working tree is clean (no further uncommitted edits on top of
`697987b`). This confirms, byte-for-byte:

- A.2's ground-truth section (extension-derivation facts) — unchanged.
- A.4's extension-mapping table and fixed-name-plus-fallback design (steps 1-3) —
  unchanged.
- A.5 step 1 (fetch mechanism) and step 3 (failure-message requirement) — unchanged.
- A.5's empty-`:external_resource` fallback branch — unchanged.
- A.6 (explicit non-goal: no OS-skip) and A.7 (open question OQ-A1) — unchanged.
- All of Part B (build-path isolation, Step 1.6/B.3/B.4, hardlink/MIX_BUILD_PATH
  reasoning) — unchanged.

A.2's mechanism-attribution note flagged non-blocking in iteration 1 was correctly
left untouched, as the rework1 handoff did not require it and explicitly marked it
non-blocking.

No fenced code blocks present (`` ``` `` grep still empty); no `:os.type()`-guarded
skip reintroduced.

## Verdict: PASS

Routing to ELIXIR-DEV for WF-03 Step 3 implementation per
`handoffs/WF03-ISS0377-20260830/step-03-elixir-dev.json`.
