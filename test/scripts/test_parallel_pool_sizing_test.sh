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

# --- Extract Step 1.4's block verbatim (ISS-0287 §4.2 host-ceiling check) --
#
# Added for WF03-ISS0287-20260928's N-scaling reopening (design doc
# lib/letflow/design/iss0287-pool-headroom-n-scaling.md §5 item re: a
# "Step-1.4 host-verification test"). Same discipline as Step 1.5's own
# extraction above: bounded start/end markers, a closed-vs-ran-off-EOF
# distinction via awk's own exit code, a line-count ceiling, and a
# negative-token guard -- so this, too, evals only Step 1.4's own body, never
# spills into Step 1.5's arithmetic or beyond.
step_1_4_block=$(awk '
  /^# --- Step 1\.4:/ { flag=1 }
  flag { print }
  /^# --- Step 1\.5:/ { if (flag) { closed=1; exit 0 } }
  END { if (!closed) exit 1 }
' "$target")
awk_rc=$?

if [ "$awk_rc" -ne 0 ]; then
  echo "FAIL: Step 1.4 extraction from $target never reached a '# --- Step 1.5:' end marker after starting at '# --- Step 1.4:' (marker missing/renamed?) -- refusing to eval an unbounded/unclosed capture" >&2
  exit 1
fi

if [ -z "$step_1_4_block" ] || ! printf '%s' "$step_1_4_block" | grep -q 'psql'; then
  echo "FAIL: could not locate a usable Step 1.4 block in $target (comment markers found but host-verification body changed shape?)" >&2
  exit 1
fi

step_1_4_line_count=$(printf '%s\n' "$step_1_4_block" | wc -l | tr -d ' ')
if [ "$step_1_4_line_count" -gt 70 ]; then
  echo "FAIL: extracted Step 1.4 block from $target is $step_1_4_line_count lines (> 70) -- refusing to eval a suspiciously large capture; end marker may be misplaced/renamed" >&2
  exit 1
fi

for telltale in 'computed_pool' 'usable_ceiling' 'TEST_POOL_SIZE=' 'TEST_MIN_POOL_SIZE'; do
  if printf '%s' "$step_1_4_block" | grep -qF "$telltale"; then
    echo "FAIL: extracted Step 1.4 block from $target contains '$telltale', a token unique to Step 1.5 or later -- extraction over-captured; refusing to eval" >&2
    exit 1
  fi
done

# --- Extract Step 2's opt-in connection-sampler gating verbatim -----------
#
# ISS-0287 §4.3's sampler (design doc §5 item re: an opt-in-sampler test).
# This deliberately captures only the *gating* logic (should the background
# poll loop start at all, given TEST_PARALLEL_SAMPLE_CONNECTIONS and psql's
# presence) -- not the loop body itself, so evaling this in a test never
# blocks. Start marker is the sampler's own first statement
# (`_test_parallel_sampler_pid=""`, unique in the file); end marker is the
# partition-launch loop's `i=1` that immediately follows it in the real
# script. Because that end marker is executable code (not a comment), the
# awk program checks it BEFORE printing each line, so the terminating `i=1`
# itself is excluded from the captured block (unlike Step 1.5/1.4's own
# extraction above, whose end markers are inert comment lines and so are
# safely included).
sampler_block=$(awk '
  /^i=1$/ { if (flag) { closed=1; exit 0 } }
  /^_test_parallel_sampler_pid=""$/ { flag=1 }
  flag { print }
  END { if (!closed) exit 1 }
' "$target")
awk_rc=$?

if [ "$awk_rc" -ne 0 ]; then
  echo "FAIL: sampler-gating extraction from $target never reached the terminating 'i=1' partition-loop line after starting at '_test_parallel_sampler_pid=\"\"' (marker missing/renamed?) -- refusing to eval an unbounded/unclosed capture" >&2
  exit 1
fi

if [ -z "$sampler_block" ] || ! printf '%s' "$sampler_block" | grep -q 'TEST_PARALLEL_SAMPLE_CONNECTIONS'; then
  echo "FAIL: could not locate a usable sampler-gating block in $target (marker found but body changed shape?)" >&2
  exit 1
fi

sampler_line_count=$(printf '%s\n' "$sampler_block" | wc -l | tr -d ' ')
if [ "$sampler_line_count" -gt 30 ]; then
  echo "FAIL: extracted sampler-gating block from $target is $sampler_line_count lines (> 30) -- refusing to eval a suspiciously large capture; end marker may be misplaced/renamed" >&2
  exit 1
fi

for telltale in 'mix test --partitions' 'wait "${pids' 'declare -a exits' 'declare -a pids'; do
  if printf '%s' "$sampler_block" | grep -qF "$telltale"; then
    echo "FAIL: extracted sampler-gating block from $target contains '$telltale', a token unique to the partition-launch loop or later -- extraction over-captured; refusing to eval" >&2
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
      echo "RESULT_BUDGET=${budget:-UNSET}"
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
    poolbudget=*)
      # ISS-0287 §5 item 1/2 (N-sweep + live-knob proof): checks BOTH the
      # computed pool size and the intermediate `budget` value in one case,
      # so a test can assert the knob's effect on the pre-division budget
      # (shrinks by exactly N*value) independently of its effect on the
      # post-division pool size (shrinks by exactly value, when unclamped).
      local rest="${expect#poolbudget=}"
      local want_pool="${rest%%:*}"
      local want_budget="${rest#*:}"
      if [ "$rc" -eq 0 ] \
        && printf '%s' "$out" | grep -q "RESULT_POOL_SIZE=$want_pool\$" \
        && printf '%s' "$out" | grep -q "RESULT_BUDGET=$want_budget\$"; then
        echo "PASS: $name (TEST_POOL_SIZE=$want_pool, budget=$want_budget)"
        pass=$((pass + 1))
      else
        echo "FAIL: $name -- expected TEST_POOL_SIZE=$want_pool and budget=$want_budget, exit 0; got exit=$rc, output:"
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

# --- ISS-0287 (reopened) N-scaling cases (WF03-ISS0287-20260928) -----------
#
# lib/letflow/design/iss0287-pool-headroom-n-scaling.md §5 closes the
# coverage gap that let the N=8 reopening through undetected: the cases
# above only ever validated N=4 and N=16. All defaults below are the same
# as cases 1-2: TEST_MAX_CONNECTIONS=100, TEST_CONNECTION_HEADROOM=10,
# TEST_MIN_POOL_SIZE=2, TEST_SUPERUSER_RESERVED=3,
# TEST_NONPOOL_CONNECTION_RESERVE=5 -> usable_ceiling=97.
#
# 6. N-sweep at TEST_PER_PARTITION_HEADROOM unset (default 0): N x 0 = 0, so
#    budget must come out to exactly 82 (97 - 10 - 5) at EVERY N below --
#    byte-identical to what the pre-this-fix formula (no
#    TEST_PER_PARTITION_HEADROOM term at all) would have computed, proving
#    the new knob's zero-default is a genuine no-op, not just something
#    manually eyeballed once. computed_pool = floor(82/N), clamped to the
#    TEST_MIN_POOL_SIZE floor of 2 if the raw division would go below it
#    (only reached at N=32, where 82/32 floors to exactly 2, still >= floor
#    so no clamp fires here either -- clamping IS exercised in the
#    per=1 sweep below at the same N).
#    N=8 (case 6h) is the reopening's own N -- a dedicated, named regression
#    guard for this specific issue, not just a byproduct of a wider sweep,
#    per the design's explicit "add a dedicated N=8 case" instruction.
run_case "6a. N=1,  per=0 (default) -> no-op sweep"  1  -- "poolbudget=82:82"
run_case "6b. N=2,  per=0 (default) -> no-op sweep"  2  -- "poolbudget=41:82"
run_case "6c. N=3,  per=0 (default) -> no-op sweep"  3  -- "poolbudget=27:82"
run_case "6d. N=4,  per=0 (default) -> no-op sweep"  4  -- "poolbudget=20:82"
run_case "6e. N=5,  per=0 (default) -> no-op sweep"  5  -- "poolbudget=16:82"
run_case "6f. N=6,  per=0 (default) -> no-op sweep"  6  -- "poolbudget=13:82"
run_case "6g. N=7,  per=0 (default) -> no-op sweep"  7  -- "poolbudget=11:82"
run_case "6h. N=8,  per=0 (default) -> no-op sweep, THE REOPENING'S OWN N" 8 -- "poolbudget=10:82"
run_case "6i. N=9,  per=0 (default) -> no-op sweep"  9  -- "poolbudget=9:82"
run_case "6j. N=12, per=0 (default) -> no-op sweep"  12 -- "poolbudget=6:82"
run_case "6k. N=16, per=0 (default) -> no-op sweep (decision 0009's host)" 16 -- "poolbudget=5:82"
run_case "6l. N=24, per=0 (default) -> no-op sweep"  24 -- "poolbudget=3:82"
run_case "6m. N=32, per=0 (default) -> no-op sweep"  32 -- "poolbudget=2:82"

# 7. Same N-sweep, TEST_PER_PARTITION_HEADROOM=1 (a nonzero test value) --
#    proves the knob is LIVE, not dead code: budget must shrink by exactly
#    N*1 at every N (budget = 82 - N, an exact, N-scaling reduction --
#    unlike TEST_NONPOOL_CONNECTION_RESERVE, proven N-independent in the
#    design's §2). computed_pool = floor(budget/N) shrinks by exactly 1
#    (the knob's own value) at every N EXCEPT N=32, where floor(50/32)=1
#    falls below TEST_MIN_POOL_SIZE=2 and the WARN-clamp fires -- exercising
#    the clamp path together with the knob for the first time in this file.
#    (rc stays 0 either way: the clamp WARNs, it does not hard-fail.)
run_case "7a. N=1,  per=1 -> knob live"  1  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=81:81"
run_case "7b. N=2,  per=1 -> knob live"  2  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=40:80"
run_case "7c. N=3,  per=1 -> knob live"  3  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=26:79"
run_case "7d. N=4,  per=1 -> knob live (20->19, exactly -1)" 4 "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=19:78"
run_case "7e. N=5,  per=1 -> knob live"  5  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=15:77"
run_case "7f. N=6,  per=1 -> knob live"  6  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=12:76"
run_case "7g. N=7,  per=1 -> knob live"  7  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=10:75"
run_case "7h. N=8,  per=1 -> knob live (10->9, THE REOPENING'S OWN N)" 8 "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=9:74"
run_case "7i. N=9,  per=1 -> knob live"  9  "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=8:73"
run_case "7j. N=12, per=1 -> knob live"  12 "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=5:70"
run_case "7k. N=16, per=1 -> knob live"  16 "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=4:66"
run_case "7l. N=24, per=1 -> knob live"  24 "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=2:58"
run_case "7m. N=32, per=1 -> knob live, WARN-clamp path (raw 1 < floor 2 -> clamped to 2, budget still 50)" \
  32 "TEST_PER_PARTITION_HEADROOM=1" -- "poolbudget=2:50"

# 8. Dynamic case using the REAL host's own nproc/getconf-derived N --
#    catches a formula that only happens to work at hand-picked N values
#    (exactly this issue's own history: N=4 and N=16 were checked, N=8
#    wasn't, because nobody's dev host had 8 cores when the original fix
#    was verified). Uses the same defaults as cases 1/2/6/7 above
#    (budget=82) -- independently recomputes the expected pool size in bash
#    arithmetic (not sourced from the script under test) from whatever N
#    this host actually derives, so this case is meaningful on any host,
#    not just the one it was authored on.
if command -v nproc >/dev/null 2>&1; then
  _host_n=$(nproc)
  _host_n_source="nproc"
elif command -v getconf >/dev/null 2>&1; then
  _host_n=$(getconf _NPROCESSORS_ONLN)
  _host_n_source="getconf"
else
  _host_n=""
fi

if [ -n "$_host_n" ] && printf '%s' "$_host_n" | grep -Eq '^[1-9][0-9]*$'; then
  _host_expected_pool=$((82 / _host_n))
  if [ "$_host_expected_pool" -lt 2 ]; then
    _host_expected_pool=2
  fi
  run_case "8. dynamic host-derived N=$_host_n (via $_host_n_source), all defaults" \
    "$_host_n" -- "poolbudget=${_host_expected_pool}:82"
else
  echo "SKIP: dynamic host-derived-N case -- neither nproc nor getconf available on this host to derive a real N"
fi

# --- ISS-0287 §4.2: Step 1.4 host-ceiling verification (WARN, never fail) --
#
# Step 1.4 is the design's own answer to "or is the real gap a config-drift
# ceiling mismatch, not an arithmetic one" -- it queries the live Postgres
# instance's max_connections/superuser_reserved_connections and WARNs (never
# hard-fails) on a mismatch against TEST_MAX_CONNECTIONS/TEST_SUPERUSER_RESERVED's
# assumed defaults. These cases don't need a live Postgres: a fake `psql` on
# PATH stands in for the real server, so the SCRIPT LOGIC itself (not
# Postgres) is what's under test here -- whether it warns-and-continues (never
# exits nonzero) across every combination of reachable/unreachable and
# matching/mismatched.
_step1_4_fakebin_dir=$(mktemp -d "${TMPDIR:-/tmp}/letflow_pool_sizing_test_fakepsql.XXXXXX")
_step1_4_minbin_dir=$(mktemp -d "${TMPDIR:-/tmp}/letflow_pool_sizing_test_minbin.XXXXXX")
for _tool in tr psql bash env; do
  _toolpath=$(command -v "$_tool" 2>/dev/null || true)
  if [ -n "$_toolpath" ]; then
    ln -sf "$_toolpath" "$_step1_4_minbin_dir/$_tool"
  fi
done
rm -f "$_step1_4_minbin_dir/psql" # only tr/bash/env belong in the "no psql" PATH
# NOTE: bash/env must be reachable so the fake psql's own "#!/usr/bin/env
# bash" shebang can resolve when PATH is deliberately restricted below --
# restricting PATH to just "tr" (omitting bash/env) made every fake-psql
# invocation silently fail to exec, which read from the block's own
# perspective as "server unreachable" -- indistinguishable from the actual
# case 12 below without this fix. Caught by running this file for real, not
# assumed.

cat > "$_step1_4_fakebin_dir/psql" <<'FAKEPSQL'
#!/usr/bin/env bash
# Fake psql for ISS-0287 Step 1.4 regression cases. Ignores connection args;
# answers the trailing -tAc query text via FAKE_PSQL_MAX_CONN/
# FAKE_PSQL_SUPERUSER, or fails outright (simulating an unreachable server)
# if FAKE_PSQL_FAIL is set.
if [ -n "${FAKE_PSQL_FAIL:-}" ]; then
  exit 1
fi
query="${*: -1}"
case "$query" in
  *max_connections*) printf '%s\n' "${FAKE_PSQL_MAX_CONN:-100}" ;;
  *superuser_reserved_connections*) printf '%s\n' "${FAKE_PSQL_SUPERUSER:-3}" ;;
  *) printf '' ;;
esac
FAKEPSQL
chmod +x "$_step1_4_fakebin_dir/psql"

# run_step1_4_case NAME EXPECT_SUBSTRING [FORBIDDEN_SUBSTRING] -- ENV=val ...
# Always requires exit 0 -- Step 1.4 must never hard-fail (design §4.2).
run_step1_4_case() {
  local name="$1" expect_present="$2" expect_absent="$3"; shift 3
  shift # drop the --
  local envs=("$@")

  local out rc
  out=$(
    (
      set -u
      for kv in "${envs[@]}"; do export "$kv"; done
      eval "$step_1_4_block"
    ) 2>&1
  )
  rc=$?

  local ok=1
  [ "$rc" -eq 0 ] || ok=0
  if [ -n "$expect_present" ] && ! printf '%s' "$out" | grep -qF "$expect_present"; then ok=0; fi
  if [ -n "$expect_absent" ] && printf '%s' "$out" | grep -qF "$expect_absent"; then ok=0; fi

  if [ "$ok" -eq 1 ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name -- expected exit 0, output containing '$expect_present' (and NOT containing '$expect_absent'); got exit=$rc, output:"
    echo "$out" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

# 9. psql not on PATH at all -> WARN + skip verification, exit 0.
run_step1_4_case "9. Step 1.4: psql not found -> WARN, exit 0 (never fails)" \
  "WARN psql not found -- skipping host Postgres ceiling verification" "" -- \
  "PATH=$_step1_4_minbin_dir" "LETFLOW_DB_PORT=5462"

# 10. psql present, values match assumed defaults (100/3) -> "verified" line,
#     no mismatch WARN.
run_step1_4_case "10. Step 1.4: psql present, values match defaults -> verified, no WARN" \
  "host ceiling verified" "does not match assumed" -- \
  "PATH=$_step1_4_fakebin_dir:$_step1_4_minbin_dir" "LETFLOW_DB_PORT=5462" \
  "FAKE_PSQL_MAX_CONN=100" "FAKE_PSQL_SUPERUSER=3"

# 11. psql present, live max_connections=90 (host drift) -> mismatch WARN,
#     exit 0 (config-drift is reported, never hard-failed -- design §4.2).
run_step1_4_case "11. Step 1.4: psql present, max_connections drift -> WARN, exit 0" \
  "live Postgres max_connections=90 does not match assumed TEST_MAX_CONNECTIONS=100" "" -- \
  "PATH=$_step1_4_fakebin_dir:$_step1_4_minbin_dir" "LETFLOW_DB_PORT=5462" \
  "FAKE_PSQL_MAX_CONN=90" "FAKE_PSQL_SUPERUSER=3"

# 12. psql present but server unreachable (query returns nothing) -> WARN
#     "could not reach", exit 0.
run_step1_4_case "12. Step 1.4: psql present, server unreachable -> WARN, exit 0" \
  "could not reach Postgres" "" -- \
  "PATH=$_step1_4_fakebin_dir:$_step1_4_minbin_dir" "LETFLOW_DB_PORT=5462" \
  "FAKE_PSQL_FAIL=1"

rm -rf "$_step1_4_fakebin_dir" "$_step1_4_minbin_dir"

# --- ISS-0287 §4.3: opt-in connection sampler -- gating only, no live loop -
#
# The sampler is meant to be zero-cost on an ordinary run (default unset)
# and to fail soft (WARN, not start) if psql is unavailable even when
# explicitly requested -- both are gating-logic properties, checkable
# without ever letting the sampler's own infinite polling loop run. Case 15
# is the one exception: it proves the knob genuinely starts a background
# process when both conditions are met (opt-in truly is live, not dead
# code), immediately killing that process again so the test suite never
# leaks a runaway background job.
run_sampler_case() {
  local name="$1" expect_present="$2" expect_absent="$3"; shift 3
  shift # drop the --
  local envs=("$@")

  # NOTE: case 15 below actually starts a real background polling loop
  # (`while true; do ...; sleep 1; done &`). Capturing output via ordinary
  # `out=$( ... )` command substitution (a pipe) would hang forever here --
  # the backgrounded loop inherits that pipe's write end, and a command
  # substitution only returns once EVERY holder of the write end has closed
  # it, which the loop never does on its own. Caught by actually running
  # this file (it hung past a 60s timeout) rather than assumed safe by
  # analogy with run_case/run_step1_4_case above, neither of which ever
  # backgrounds anything. Fix: redirect to a real file instead of a pipe --
  # a file has no such EOF-on-last-writer-close semantics, so the parent
  # returns as soon as ITS OWN foreground work (the eval + echo) is done,
  # leaving the backgrounded loop to keep appending to the file
  # independently until killed below.
  local out_file rc pid_line sampler_pid
  out_file=$(mktemp "${TMPDIR:-/tmp}/letflow_pool_sizing_test_sampler_out.XXXXXX")
  (
    set -u
    for kv in "${envs[@]}"; do export "$kv"; done
    tmp_dir="$_sampler_case_tmp_dir"
    eval "$sampler_block"
    echo "RESULT_SAMPLER_PID=${_test_parallel_sampler_pid:-}"
  ) >"$out_file" 2>&1
  rc=$?
  local out
  out=$(cat "$out_file")
  rm -f "$out_file"

  pid_line=$(printf '%s' "$out" | grep '^RESULT_SAMPLER_PID=' | tail -n 1)
  sampler_pid="${pid_line#RESULT_SAMPLER_PID=}"
  if [ -n "$sampler_pid" ]; then
    kill "$sampler_pid" 2>/dev/null
    wait "$sampler_pid" 2>/dev/null
  fi

  local ok=1
  [ "$rc" -eq 0 ] || ok=0
  if [ -n "$expect_present" ] && ! printf '%s' "$out" | grep -qF "$expect_present"; then ok=0; fi
  if [ -n "$expect_absent" ] && printf '%s' "$out" | grep -qF "$expect_absent"; then ok=0; fi

  if [ "$ok" -eq 1 ]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name -- expected exit 0, output containing '$expect_present' (and NOT containing '$expect_absent'); got exit=$rc, sampler_pid='$sampler_pid', output:"
    echo "$out" | sed 's/^/    /'
    fail=$((fail + 1))
  fi
}

_sampler_case_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/letflow_pool_sizing_test_sampler.XXXXXX")
_step1_4_minbin_dir2=$(mktemp -d "${TMPDIR:-/tmp}/letflow_pool_sizing_test_minbin2.XXXXXX")
for _tool in tr bash env date; do
  _toolpath=$(command -v "$_tool" 2>/dev/null || true)
  [ -n "$_toolpath" ] && ln -sf "$_toolpath" "$_step1_4_minbin_dir2/$_tool"
done
_step1_4_fakebin_dir2=$(mktemp -d "${TMPDIR:-/tmp}/letflow_pool_sizing_test_fakepsql2.XXXXXX")
cat > "$_step1_4_fakebin_dir2/psql" <<'FAKEPSQL2'
#!/usr/bin/env bash
printf '0\n'
FAKEPSQL2
chmod +x "$_step1_4_fakebin_dir2/psql"

# 13. Default (TEST_PARALLEL_SAMPLE_CONNECTIONS unset) -> sampler never
#     starts, no "enabled" message -- opt-in means truly OFF by default.
run_sampler_case "13. Sampler: unset (default) -> not started, no message" \
  "" "connection sampler enabled" -- \
  "PATH=$_step1_4_minbin_dir2"

# 14. Set, but psql not on PATH -> WARN + not started (fails soft, does not
#     crash the whole script over a missing diagnostic tool).
run_sampler_case "14. Sampler: set but psql missing -> WARN, not started" \
  "WARN TEST_PARALLEL_SAMPLE_CONNECTIONS set but psql not found -- sampler not started" \
  "connection sampler enabled" -- \
  "PATH=$_step1_4_minbin_dir2" "TEST_PARALLEL_SAMPLE_CONNECTIONS=1"

# 15. Set AND psql present -> the knob is genuinely live: sampler actually
#     starts (nonempty pid captured above, killed immediately after).
run_sampler_case "15. Sampler: set and psql present -> actually starts (knob is live)" \
  "connection sampler enabled" "" -- \
  "PATH=$_step1_4_fakebin_dir2:$_step1_4_minbin_dir2" "TEST_PARALLEL_SAMPLE_CONNECTIONS=1"

rm -rf "$_sampler_case_tmp_dir" "$_step1_4_minbin_dir2" "$_step1_4_fakebin_dir2"

echo "---"
echo "test_parallel_pool_sizing_test: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
