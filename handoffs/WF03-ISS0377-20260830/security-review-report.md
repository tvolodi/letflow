# Security review — ISS-0377 (WF-03 Step 3c)

Reviewer: SECURITY-REVIEWER
Branch: feature/WF03-ISS0377-20260830
Implementation commit reviewed: 8eef01b
Files reviewed in full: `test/letflow/engine/wasm/plugin_handler_test.exs`,
`scripts/test_parallel.sh`, `lib/letflow/design/iss0377-cross-platform-test-fixes.md`

## Scope test

Checked against the SECURITY-REVIEWER handoff's scope criteria (API route,
migration, secret resolution, response-shaping, lookup-by-ID handler): none
apply. This is a test-infrastructure change only — a test file's assertion
logic and a local dev/CI shell script's build-path handling. No tenant-scoped
table, schema, migration, or runtime data is touched.

## INV-1..INV-8 disposition

- INV-1 (tenant isolation on schema/migration/tenant-scoped-table diffs):
  NOT-APPLICABLE — no migration, no Ecto schema, no tenant-scoped table touched.
- INV-2, INV-3, INV-5 (S4/S5-stage invariants): NOT-APPLICABLE — stages not
  reached, and nothing in this diff reaches ahead into them.
- INV-4 (secrets): APPLIES (checked per handoff instruction) — verified no new
  hardcoded credential/token/tenant-ID material in either file. PASS.
- INV-6: NOT-APPLICABLE.
- INV-7, INV-8: checked against the diff's actual content (no API surface, no
  response shaping) — NOT-APPLICABLE, nothing in the diff falls under their
  triggering conditions.

No applicable invariant failed. Overall: **PASS**.

## Specific checks requested by the routing handoff

1. **No newly hardcoded test credentials/secrets.** Read both files in full.
   None found — no API keys, tokens, tenant IDs, passwords, or connection
   strings. The only string literals added are OS-extension mappings (`.so`,
   `.dll`), path fragments (`native/wasmex`, `_build/test-partition-<i>`), and
   diagnostic messages.

2. **Per-partition build paths don't leak data across partitions or persist
   sensitive data.** Read the Step 1.6 seeding loop and the Step 2 launch
   change directly:
   - Each partition gets a distinct path, `_build/test-partition-$i`,
     computed from the loop counter, seeded once (`rm -rf` then
     `cp -al`/`cp -r`) strictly before any partition is backgrounded — the
     loop that seeds all N paths is fully sequential and completes before
     Step 2's background-launch loop starts. No partition process ever reads
     or writes another partition's path: `MIX_BUILD_PATH` is set per
     invocation (`MIX_TEST_PARTITION="$i" MIX_BUILD_PATH="_build/test-partition-$i" mix test ...`),
     not exported globally, so there's no window where one partition's
     environment could resolve to another's directory.
   - Content is ordinary compiled build/test artifacts (BEAM files, Mix
     manifests, deps' compiled NIFs) — the same class of data already covered
     by the existing `_build/` `.gitignore` entry — not tenant data, secrets,
     or anything sensitive. The design doc (§B.5) explicitly scopes cleanup
     of these directories as out of scope, consistent with req113's existing
     treatment of `_build/test` itself; this is a repo-wide precedent, not a
     new gap introduced here.

3. **Hardlink-copy cross-partition mutation risk.** This is the design's core
   claim (Part B), so I traced it specifically rather than taking it at face
   value:
   - `cp -al` (hardlink-preserving copy) makes each partition's tree share
     inode data with the original `_build/test` tree and with every sibling
     partition's tree for any file neither side has since replaced. A
     write-in-place to a shared inode (rather than an unlink+recreate/atomic
     rename) would indeed be visible across partitions and would break the
     isolation the whole fix rests on.
   - However, the mechanism this fix targets is exactly Mix's own build-lock/
     manifest write path, which operates via delete-and-replace (atomic
     rename of a fresh file over the old directory entry), not in-place
     mutation of existing file content — this is the same lock/manifest
     mechanism whose Windows-specific hard-abort ("could not create hard
     link ... permission denied") is the original symptom being fixed, i.e.
     the design is already reasoning from this exact hardlink-replacement
     semantic, not overlooking it. Since Step 1's compile already ran to
     completion before seeding, and no partition triggers a fresh compile
     during its `mix test` run (same source, same `_build/test` base), the
     in-run writes each partition performs are new/replaced manifest and log
     entries local to that partition's own directory entries, not in-place
     edits of shared file content.
   - ORCH's independently-run full invocation (stated in the task handoff)
     completed cleanly with the new seeding step working and, notably, zero
     `wasm_hang`-class flake on that run — empirical evidence consistent with
     no cross-partition corruption, though a single clean run is not a proof
     of absence for a rare race.
   - Verdict: no newly introduced *security* exposure (no data leak, no
     secret exposure) either way — a hypothetical race here would be a
     **test-flakiness/correctness** issue, not a tenant-data or secrets
     issue, so it doesn't trip any INV-1..INV-8 invariant. I flag it below as
     a note for REVIEWER (the next gate, which covers correctness/idiom)
     rather than blocking on it here.

4. **New shell injection risk in Step 1.6.** Reviewed the loop's variable
   interpolation:
   ```
   partition_build_path="_build/test-partition-$i"
   rm -rf "$partition_build_path"
   cp -al "_build/test" "$partition_build_path" ...
   ```
   `$i` is the script's own integer loop counter (`i=1`, `i=$((i + 1))`,
   bounded by `$N`), never derived from external input, environment, or file
   content. All paths are double-quoted. No new external command execution
   was added beyond `rm`/`cp`, both applied to constructed, fully-controlled
   paths. No injection risk.

## Note for REVIEWER (not a security finding, forwarded for the idiom/
correctness gate)

Worth a quick correctness sanity check on the hardlink-sharing reasoning in
point 3 above — specifically, whether any file under `_build/test` that
`mix test` might touch during a partition's run (as opposed to during
`mix compile`) is ever written in place rather than replaced. Nothing found
here indicates it is, and the empirical run was clean, but this is the load-
bearing assumption of the whole Part B fix and is squarely REVIEWER's kind of
check.

## Result

**PASS.** No applicable invariant failed. No secrets, no cross-partition data
leak, no injection risk. Routing to REVIEWER per WF-03's Step 3d.
