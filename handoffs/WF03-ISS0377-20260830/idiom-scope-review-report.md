# REVIEWER report — WF03-ISS0377-20260830 Step 3d

**Verdict: PASS**

Scope reviewed: commit `8eef01b` on `feature/WF03-ISS0377-20260830`
(`test/letflow/engine/wasm/plugin_handler_test.exs` Part A,
`scripts/test_parallel.sh` Part B), against
`lib/letflow/design/iss0377-cross-platform-test-fixes.md` and
`docs/issues/ISS-0377.yaml`.

## 1. Idiomatic OTP / gen_statem / supervision

Not applicable to this diff — no OTP process, supervision-tree, or state-machine
code is touched (test-infrastructure only), consistent with SECURITY-REVIEWER's
same finding.

## 2. Scope creep

`git diff --stat main...HEAD` touches exactly:
`test/letflow/engine/wasm/plugin_handler_test.exs`, `scripts/test_parallel.sh`,
plus `lib/letflow/design/iss0377-cross-platform-test-fixes.md` and this run's
`handoffs/WF03-ISS0377-20260830/*` artifacts. No other file changed. No
abstraction/behaviour/macro was introduced ahead of what Part A/B need.

Minor style note (non-blocking): `expected_native_extension/0` and
`native_artifact_check/2` are defined as `defp` nested *inside* the `describe
"AC7: ..."` block, whereas this file's existing precedent (`context/1` at the
module top, `wasmex_pids/0` immediately before its own `describe` block but
still at module level) keeps all helpers at module scope, not nested inside a
`describe`. It compiles and scopes correctly (ExUnit's `describe/2` doesn't
create a separate module), and there's a real locality argument for keeping
AC7-only helpers next to the block that uses them. Worth conforming to the
file's existing pattern (hoist both `defp`s to module level, matching
`wasmex_pids/0`) next time this file is touched, but not worth a rework cycle
on its own.

## 3. Decision-record / anti-goal consistency

Confirmed: no `:os.type()`-guarded skip/tag-exclude was introduced for either
symptom. Part A's `expected_native_extension/0` `flunk`s loudly on an
unmapped OS (A.4's explicit non-goal, A.6). Part B has no host-conditional
branching at all — the seed step runs identically regardless of OS (B.3's
explicit rejection of Approach 1, "detect-Windows-and-retry").

## 4. Design-vs-implementation fidelity

- Extension-mapping table (A.4 step 1): implemented as a single `case`
  collapsing `:linux`/`:freebsd`/`:darwin` into one `.so` branch and
  `{:win32, _}` into `.dll`, functionally identical to the table's four rows,
  loud `flunk` on anything else. Matches.
- Fixed-name-then-fallback-listing check (A.4 steps 2-3): implemented in
  `native_artifact_check/2`, returns tagged tuples distinguishing which
  branch fired and, on failure, which reason — matches A.4's message-clarity
  requirement.
- A.5's "at least one `.rs`" fix from rework 1 is present (`Enum.any?/2` +
  `String.ends_with?/2`, not "every entry"), with the empty-list branch
  falling back to the A.4-step-3 artifact-presence check rather than failing.
  This is exactly the corrected assertion the two prior design-validator
  rework cycles were chasing.
- Part B: sequential per-partition seeding (Step 1.6) runs entirely before
  Step 2's partition loop backgrounds anything — confirmed by reading the
  script top-to-bottom, the `while` loop with `cp -al`/`cp -r` fallback has
  no `&` and completes (with `exit 1` on failure) before the partition-launch
  loop begins. `MIX_BUILD_PATH="_build/test-partition-$i"` is set as a
  leading per-command env assignment on the same line as `MIX_TEST_PARTITION`
  and `mix test`, not `export`ed — matches B.4's explicit instruction and the
  script's own precedent contrast with `TEST_POOL_SIZE`/`TEST_PARALLEL_GROUP`.
  `.gitignore`'s existing `/_build/` entry already covers
  `_build/test-partition-*` (OQ-B3, verified, no action needed).

## 5. Hardlink-safety investigation (SECURITY-REVIEWER's flagged item)

Traced this against real Elixir/Mix source (`elixir` 1.18.3-otp-27 and
1.20.3-otp-29 installs on this host, `lib/mix/lib/mix/sync/lock.ex` and
`lib/mix/lib/mix/compilers/elixir.ex`), not documentation alone.

**Finding: the fix is sound, but for a more specific reason than "Mix's
manifest writes use replace-via-rename."** That premise is actually false as
a general statement — `Mix.Compilers.Elixir.write_manifest/9` calls
`File.write!(manifest, manifest_data)`, which is Erlang's
`:file.write_file/3` (open with `O_CREAT|O_TRUNC`, i.e. **in-place
truncate**, not unlink+rename). If two sibling partitions' `mix test`
processes both triggered a real recompile against a hardlinked-shared
manifest inode concurrently, an in-place truncating write like this could in
principle corrupt what the other partition reads.

What actually makes this safe is a different, load-bearing fact:

1. **The reported symptom (`MIX_OS_CONCURRENCY_LOCK` hard-link contention)
   is produced by `Mix.Sync.Lock`, whose lock files live entirely outside
   `_build/` — under `Path.join(System.tmp_dir!(), "mix_lock_<user>")` — and
   are keyed by `Mix.Sync.Lock.with_lock(build_path, ...)` (called from
   `Mix.Project.build_path`/`deps_path` locking, `mix/project.ex:926,943`).
   Giving every partition a distinct `MIX_BUILD_PATH` gives every partition a
   distinct lock key/hash, hence distinct lock files in the tmp dir. This
   fully and directly eliminates the *reported* contention — it has nothing
   to do with whether files inside `_build/test-partition-<i>` share inodes.
2. **The residual "could a shared manifest inode get corrupted" question**
   only matters if `write_manifest/9` actually runs during a partition's
   `mix test` invocation. Reading `Mix.Compilers.Elixir.compile/6`, the
   manifest is only rewritten when `stale != [] or stale_modules != %{}` (a
   real recompile happened) or `status != :noop`. Step 1 already performs
   the one full compile before any partition launches, `cp -al` preserves
   the original tree's mtimes identically across every partition copy
   (nothing about the seeding pass touches source or dest mtimes
   selectively), and no partition's own test run modifies `lib/`/`test/`
   sources — so no partition should ever observe a stale source and trigger
   a real recompile in the first place. Under that (correctly-assumed-here)
   condition, `write_manifest/9` never runs during Step 2, so the in-place
   truncate hazard in (this section's opening paragraph) never actually
   fires in practice.

Net: the fix is safe by construction for the failure mode it was built to
fix (lock-key collision — provably eliminated, independent of hardlinking),
and safe in practice for the residual manifest-corruption concern (contingent
on "no partition ever triggers a real recompile," which Step 1's
already-fresh compile plus unchanged sources should always guarantee, but
which is a real-world invariant rather than something the OS's filesystem
semantics prove unconditionally). This is a meaningfully stronger basis for
sign-off than "Mix's writes are rename-based" (which isn't true in general),
so I'm recording it precisely rather than repeating the design/security
docs' framing verbatim. Not a blocker — no code change requested — but worth
carrying forward: if a future change to this script's Step 1.6 or a wasmex
version bump ever caused source files to be regenerated/touched between the
pre-compile and a partition's run, this safety argument would need
re-checking.

## Conclusion

PASS. No rework required. Routing to TEST-DESIGNER (WF-03 Step 4) per the
attached handoff.
