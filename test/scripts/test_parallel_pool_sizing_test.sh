#!/usr/bin/env bash
# Regression test for ISS-0287: scripts/test_parallel.sh Step 1.5's connection-
# pool headroom clamp formula, extended to account for TEST_SUPERUSER_RESERVED
# and TEST_NONPOOL_CONNECTION_RESERVE (see
# lib/letflow/design/iss0287-connection-pool-headroom-fix.md sections 2, 3, 4).
#
# This does NOT hand-duplicate the arithmetic. It extracts Step 1.5's own
# arithmetic block verbatim out of the real scripts/test_parallel.sh (via the
# script's own "# --- Step 1.5:" / "# --- Step 1.6:" comment markers, which
# ISS-0287's fix design section 2.3 explicitly says stay in place; the end
# marker was re-scoped from "# --- Step 2:" to "# --- Step 1.6:" during
# WF03-ISS0698-20260917's fix -- see the extraction section below for why)
# and `eval`s that extracted block in a controlled subshell with N and the
# relevant env vars set. This means the test exercises the actual shipped
# logic -- if someone edits the formula without updating this test, the test
# still runs against whatever the script currently says, not a copy that can
# drift.
#
# No existing shell-script-testing convention (bats, ExUnit System.cmd
# harness, etc.) was found anywhere in this repo (grep across test/ and
# scripts/ for "bats" and for a prior *_test.sh precedent found nothing) --
# this file establishes the pattern: a standalone bash test script under
# test/scripts/, POSIX-friendly assertions, explicit PASS/FAIL summary, and a
# process exit code (0 all passed, 1 otherwise) so it composes with any
# future CI step the same way `mix test`'s exit code does.
#
# Usage: test/scripts/test_parallel_pool_sizing_test.sh
# Optional: TEST_PARALLEL_SCRIPT=<path> to point at a different copy of
# test_parallel.sh (used by this test's own pre-fix/post-fix verification --
# see the WF-03 handoff for how this was invoked against the pre-fix worktree).

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
target="${TEST_PARALLEL_SCRIPT:-$repo_root/scripts/test_parallel.sh}"

if [ ! -f "$target" ]; then
  echo "FAIL: target script not found: $target" >&2
  exit 1
fi

# --- Extract Step 1.5's block verbatim from the target script --------------
#
# Hardened per TEST-DESIGN-VALIDATOR's WF03-ISS0287-20260823 rework request:
# the original version only tracked "did the start marker flag ever get set"
# and relied on a weak "output is non-empty and contains computed_pool"
# sanity check. That check does NOT distinguish "extraction correctly closed
# at the end marker" from "the end marker was never found and awk ran off
# EOF, capturing the rest of the script" -- if someone ever rewords the end
# marker's comment header, the old version would silently eval far more than
# Step 1.5's own arithmetic. That eval could then have side effects (e.g.
# actually spawning background `mix test` partitions) as a side effect of
# running what is supposed to be a lightweight, read-only arithmetic test.
#
# End marker: "# --- Step 1.6:" (re-scoped here from the original
# "# --- Step 2:" during WF03-ISS0698-20260917's fix -- ISS-0698 inserted a
# new "# --- Step 1.7:" section between the pre-existing Step 1.6 and Step 2
# markers, and relocated the `tmp_dir=$(mktemp -d ...)` line into that new
# Step 1.7 section. Since this test only ever needs Step 1.5's own
# TEST_POOL_SIZE arithmetic -- nothing from Step 1.6 or later -- stopping at
# Step 1.6 instead of Step 2 both restores the test's original intent and
# stops depending on how many intermediate steps get added between 1.5 and 2
# in the future).
#
# Two independent guards close the over-capture gap:
#
#   1. The awk program itself tracks whether it was still "flag"-active when
#      it hit the end marker (closed=1, explicit `exit 0`) vs. ran off EOF
#      without ever closing (END block, explicit `exit 1`). The two cases
#      are distinguished by awk's own process exit code, checked separately
#      from the captured text -- not inferred from a substring test on the
#      captured text itself.
#   2. Even if (1) were somehow bypassed, the captured block is positively
#      bounded before eval: it must be <= 90 lines (the real Step 1.5 block,
#      comments included, runs 87 lines as of this writing -- 90 gives a
#      small margin for comment growth while remaining far short of the
#      ~350 lines an EOF over-capture would produce), and must NOT contain
#      any of a small set of tokens that are unique to Step 1.6 and later
#      ("wait \"", "mktemp -d", "# --- Step 1.7", "# --- Step 2",
#      "# --- Step 3", "# --- Step 4", "# --- Step 5"). Either check
#      tripping is a hard, loud failure with no eval attempted.
#      ("mix test" was dropped from this list during WF03-ISS0698-20260917's
#      fix: Step 1.5's own comments now legitimately mention a nested
#      `mix test` subprocess (ISS-0515/ISS-0426), so it is no longer unique
#      to Step 1.6-or-later and would false-positive on Step 1.5's own text.
#      The remaining tokens are all still absent from Step 1.5's own body.)

step_1_5_block=$(awk '
  /^# --- Step 1\.5:/ { flag=1 }
  flag { print }
  /^# --- Step 1\.6:/ { if (flag) { closed=1; exit 0 } }
  END { if (!closed) exit 1 }
' "$target")
awk_rc=$?

if [ "$awk_rc" -ne 0 ]; then
  echo "FAIL: Step 1.5 extraction from $target never reached a '# --- Step 1.6:' end marker after starting at '# --- Step 1.5:' (marker missing/renamed?) -- refusing to eval an unbounded/unclosed capture" >&2
  exit 1
fi

if [ -z "$step_1_5_block" ] || ! printf '%s' "$step_1_5_block" | grep -q 'computed_pool'; then
  echo "FAIL: could not locate a usable Step 1.5 block in $target (comment markers found but formula body changed shape?)" >&2
  exit 1
fi

block_line_count=$(printf '%s\n' "$step_1_5_block" | wc -l | tr -d ' ')
if [ "$block_line_count" -gt 90 ]; then
  echo "FAIL: extracted Step 1.5 block from $target is $block_line_count lines (> 90) -- refusing to eval a suspiciously large capture; end marker may be misplaced/renamed" >&2
  exit 1
fi

for telltale in 'wait "' 'mktemp -d' '# --- Step 1.7' '# --- Step 2' '# --- Step 3' '# --- Step 4' '# --- Step 5'; do
  if printf '%s' "$step_1_5_block" | grep -qF "$telltale"; then
    echo "FAIL: extracted Step 1.5 block from $target contains '$telltale', a token unique to Step 1.6 or later -- extraction over-captured; refusing to eval" >&2
    exit 1
  fi
done

pass=0
fail=0

# run_case NAME N [VAR=val ...] -- pool=<n>|error=<substring>
run_case() {
  local name="$1"; shift
  local n="$1"; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift # drop the --
  local expect="$1"

  local out rc
  out=$(
    (
      set -u
      N="$n"
      for kv in "${envs[@]}"; do
        export "$kv"
      done
      eval "$step_1_5_block"
      echo "RESULT_POOL_SIZE=${TEST_POOL_SIZE:-UNSET}"
    ) 2>&1
  )
  rc=$?

  case "$expect" in
    pool=*)
      local want="${expect#pool=}"
      if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "RESULT_POOL_SIZE=$want\$"; then
        echo "PASS: $name (TEST_POOL_SIZE=$want)"
        pass=$((pass + 1))
      else
        echo "FAIL: $name -- expected TEST_POOL_SIZE=$want, exit 0; got exit=$rc, output:"
        echo "$out" | sed 's/^/    /'
        fail=$((fail + 1))
      fi
      ;;
    error=*)
      local substring="${expect#error=}"
      if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$substring"; then
        echo "PASS: $name (exit=$rc, matched error substring)"
        pass=$((pass + 1))
      else
        echo "FAIL: $name -- expected nonzero exit and stderr containing '$substring'; got exit=$rc, output:"
        echo "$out" | sed 's/^/    /'
        fail=$((fail + 1))
      fi
      ;;
    *)
      echo "FAIL: $name -- bad expectation spec '$expect' in test itself" >&2
      fail=$((fail + 1))
      ;;
  esac
}

# --- Cases -------------------------------------------------------------

# 1. N=4, all defaults: usable_ceiling = 100 - 3 = 97; budget =
#    97 - 10 - 5 = 82; computed = 82 / 4 = 20. (Expected value corrected
#    here from a stale pool=21/budget=85 during WF03-ISS0698-20260917's fix
#    -- unrelated to ISS-0698 itself: TEST_NONPOOL_CONNECTION_RESERVE's
#    documented default was bumped from 3 to 5 by ISS-0515 (2026-09-06),
#    predating this branch, and this test's expected value was never
#    updated to match.)
run_case "N=4 all defaults -> new formula" 4 -- "pool=20"

# 2. N=16, all defaults (decision 0009's original verification host):
#    usable_ceiling = 97; budget = 82; computed = 82 / 16 = 5 -- unchanged
#    from the pre-fix formula's own N=16 result, confirming no regression
#    at the value the original decision record was verified against.
run_case "N=16 all defaults -> unchanged from pre-fix" 16 -- "pool=5"

# 3. N=4, with both new knobs neutralized (0 each): usable_ceiling =
#    100 - 0 = 100; budget = 100 - 10 - 0 = 90; computed = 90 / 4 = 22 --
#    reproduces the OLD pre-fix value exactly, proving the two new knobs
#    (not something else) are what changed the N=4 default computation
#    from 22 to 21.
run_case "N=4, new knobs neutralized -> reproduces OLD pre-fix value" 4 \
  "TEST_SUPERUSER_RESERVED=0" "TEST_NONPOOL_CONNECTION_RESERVE=0" -- "pool=22"

# 4. Malformed TEST_SUPERUSER_RESERVED must hit the same ERROR+exit-1 path
#    as the pre-existing TEST_MAX_CONNECTIONS validation.
run_case "malformed TEST_SUPERUSER_RESERVED -> ERROR, exit 1" 4 \
  "TEST_SUPERUSER_RESERVED=abc" -- "error=TEST_SUPERUSER_RESERVED='abc' is not a non-negative integer"

# 5. Malformed TEST_NONPOOL_CONNECTION_RESERVE must hit the same path.
run_case "malformed TEST_NONPOOL_CONNECTION_RESERVE -> ERROR, exit 1" 4 \
  "TEST_NONPOOL_CONNECTION_RESERVE=xyz" -- "error=TEST_NONPOOL_CONNECTION_RESERVE='xyz' is not a non-negative integer"

echo "---"
echo "test_parallel_pool_sizing_test: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
