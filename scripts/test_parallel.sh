#!/usr/bin/env bash
# Runs the suite as N parallel `mix test --partitions N` processes and
# aggregates their real reported counts into one combined total.
#
# Why bash and not POSIX sh (a deliberate deviation from
# scripts/timed_test.sh's `#!/bin/sh` precedent, not a silent
# inconsistency): this script needs PID-indexed bookkeeping across N
# background jobs (`pids[i]`, `exits[i]`, per-partition counts), which is
# materially simpler with bash arrays than with POSIX-sh workarounds.
# bash is present on every host this repo's dev/CI guide names (Linux,
# per docs/guides/backend_developer_guide.md).
#
# What this does, in order (see lib/letflow/design/req113-parallel-test-
# runner.md for the full design/rationale this implements):
#   0. Derive N: $TEST_PARALLEL_N env override, else `nproc`, else
#      `getconf _NPROCESSORS_ONLN`, else hard-fail (never a hardcoded
#      fallback number).
#   1. `MIX_ENV=test mix compile` exactly once, before any partition is
#      launched, so no two partition processes ever race to compile the
#      same _build/test artifacts.
#   2. Launch N background `MIX_TEST_PARTITION=<i> mix test --partitions N
#      --no-color "$@"` processes (1-based partition indices, as required
#      by Mix's own MIX_TEST_PARTITION contract), each partition's
#      stdout+stderr captured to its own log file under a `mktemp -d`
#      temp directory.
#   3. Wait for each one individually (`wait "$pid"` per PID, not a bare
#      `wait`) so each partition's own exit code is recoverable.
#   4. Parse each partition's log for its ExUnit summary -- a
#      `"Result: <passed>[/<total>] passed [(<type breakdown>)]"` line
#      (always present) plus an optional `"Failed: <n> <type>[, ...]"`
#      line (present only when that partition had real failures) -- and
#      sum properties/tests/failures across all partitions into one
#      combined total, cross-checking each partition's parsed failure
#      count against its process exit code (see design doc section 2.2:
#      on this toolchain exit 2, not 1, is the normal "had ExUnit
#      failures" code).
#   5. The parsed failure count (not the raw per-partition exit code) is
#      the authoritative success signal: exit 0 only if every partition
#      has a Result: line and 0 parsed failures; exit 1 otherwise.
#
# Usage: scripts/test_parallel.sh [args passed through to every
# partition's `mix test` invocation, e.g. a path filter or --seed]
#
# Overridable knob: TEST_PARALLEL_N=<positive integer> to force the
# partition count instead of deriving it from nproc/getconf.
#
# ISS-0222: running this script again immediately after a prior full-suite run
# on the same host (no gap between two consecutive launches) can produce a
# transient "too_many_connections"/DBConnection.ConnectionError in one
# partition -- a launch-time connection-count spike, not steady-state pool
# exhaustion (pg_stat_activity showed the DB well under max_connections both
# during and immediately after the failure). If you hit this, wait a few
# seconds and re-run rather than assuming a real regression.
#
# ISS-0219: on a host whose `nproc`-derived N exceeds what its Postgres
# instance/CPU budget can sustain, every partition can crash outright during
# `ecto.create`/`ecto.migrate` (DBConnection.ConnectionError + a build-
# directory lock contention message), before any partition ever reaches a
# Result: line. This is NOT fixed by capping N in this script's own
# derivation logic -- req113-parallel-test-runner.md's AC4 (see design doc
# section 4.1) requires N to derive from a real signal (env override or
# nproc/getconf) and explicitly forbids a hardcoded fallback number anywhere
# in this script's body, so silently capping the auto-derived value here
# would re-decide that acceptance criterion rather than respect it. If N
# derived from nproc/getconf crashes every partition before any Result: line,
# set TEST_PARALLEL_N explicitly to a smaller value for this host (4 has
# been verified clean on the host this note was written from) rather than
# assuming a code regression.

set -u

# --- Step 0: derive N (AC4 -- never hardcoded) ---------------------------

n_source=""
if [ -n "${TEST_PARALLEL_N:-}" ] && printf '%s' "$TEST_PARALLEL_N" | grep -Eq '^[1-9][0-9]*$'; then
  N="$TEST_PARALLEL_N"
  n_source="env override"
elif command -v nproc >/dev/null 2>&1; then
  N=$(nproc)
  n_source="nproc"
elif command -v getconf >/dev/null 2>&1 && getconf _NPROCESSORS_ONLN >/dev/null 2>&1; then
  N=$(getconf _NPROCESSORS_ONLN)
  n_source="getconf"
else
  echo "test_parallel: ERROR could not derive partition count (no TEST_PARALLEL_N, no nproc, no getconf)" >&2
  exit 1
fi

if ! printf '%s' "$N" | grep -Eq '^[1-9][0-9]*$'; then
  echo "test_parallel: ERROR derived N='$N' (source: $n_source) is not a positive integer" >&2
  exit 1
fi

echo "test_parallel: N=$N (source: $n_source)"

# --- Step 1: pre-compile MIX_ENV=test exactly once (AC5) -----------------

echo "test_parallel: pre-compiling MIX_ENV=test (single compile, before any partition launches)"
MIX_ENV=test mix compile
compile_exit=$?
if [ "$compile_exit" -ne 0 ]; then
  echo "test_parallel: ERROR pre-compile failed with exit $compile_exit -- no partition launched" >&2
  exit "$compile_exit"
fi

# --- Step 1.5: clamp per-partition pool_size to fit Postgres's ceiling ----
#
# ISS-0194: config/test.exs sizes each partition's own Ecto pool as
# schedulers_online()*2. N partitions launched concurrently (step 2 below)
# each open that many connections at once, and N*pool_size regularly
# exceeds Postgres max_connections (measured 2026-08-21: N=16, pool_size=32
# on a 16-core host -- 512 wanted against a max_connections of 100). See
# docs/migration/decisions/0009-test-parallel-pool-sizing.md for the
# tradeoff this clamp encodes and why a floor (never silently disabling
# parallelism entirely) was chosen over a hard failure.
#
# ISS-0287: TEST_MAX_CONNECTIONS - TEST_CONNECTION_HEADROOM alone treats
# TEST_MAX_CONNECTIONS as the full usable ceiling. It isn't: Postgres reserves
# superuser_reserved_connections off the top (TEST_SUPERUSER_RESERVED), and
# exactly one test in this suite opens a real Postgrex connection outside
# Letflow.Repo's Ecto pool, invisible to the N*TEST_POOL_SIZE arithmetic
# (TEST_NONPOOL_CONNECTION_RESERVE). See
# docs/migration/decisions/0009-test-parallel-pool-sizing.md's ISS-0287
# addendum for the full rationale and verification arithmetic.
#
# TEST_POOL_SIZE, if the caller already set it, is never overridden here --
# an explicit choice always wins over this clamp.
#
# ISS-0480 (design lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md
# §10.2.2/§10.3.4): each partition also starts its own, independent
# Letflow.Test.ProvisioningRepo pool (a second Ecto.Repo used only by
# Letflow.TenantFixture.provisioned_tenant!/1 for tenant-schema provisioning, kept off
# Letflow.Repo's own pool entirely -- see that module's moduledoc). Its pool_size is a
# FIXED constant, not derived from schedulers_online()/N, so PROVISIONING_POOL_SIZE
# here is a literal, not a further env override -- keep it in sync with
# config/test.exs's own `pool_size: 2` for Letflow.Test.ProvisioningRepo (design §10.2.2
# closing bullet, OQ-8: two-language sync is an implementer's choice with no behavior
# difference, resolved here as duplicated literals rather than a shared exported var).
# Subtracted as `N * PROVISIONING_POOL_SIZE` from the budget below, since every one of
# the N independently-launched `mix test` OS processes (step 2) has its own BEAM VM and
# therefore its own, independent ProvisioningRepo pool of this size.
PROVISIONING_POOL_SIZE=2

if [ -z "${TEST_POOL_SIZE:-}" ]; then
  max_conn="${TEST_MAX_CONNECTIONS:-100}"
  headroom="${TEST_CONNECTION_HEADROOM:-10}"
  min_pool="${TEST_MIN_POOL_SIZE:-2}"
  superuser_reserved="${TEST_SUPERUSER_RESERVED:-3}"
  nonpool_reserve="${TEST_NONPOOL_CONNECTION_RESERVE:-2}"

  if ! printf '%s' "$max_conn" | grep -Eq '^[1-9][0-9]*$'; then
    echo "test_parallel: ERROR TEST_MAX_CONNECTIONS='$max_conn' is not a positive integer" >&2
    exit 1
  fi

  if ! printf '%s' "$superuser_reserved" | grep -Eq '^[0-9]+$'; then
    echo "test_parallel: ERROR TEST_SUPERUSER_RESERVED='$superuser_reserved' is not a non-negative integer" >&2
    exit 1
  fi

  if ! printf '%s' "$nonpool_reserve" | grep -Eq '^[0-9]+$'; then
    echo "test_parallel: ERROR TEST_NONPOOL_CONNECTION_RESERVE='$nonpool_reserve' is not a non-negative integer" >&2
    exit 1
  fi

  usable_ceiling=$((max_conn - superuser_reserved))
  budget=$((usable_ceiling - headroom - nonpool_reserve - (N * PROVISIONING_POOL_SIZE)))
  if [ "$budget" -lt "$min_pool" ]; then
    echo "test_parallel: ERROR TEST_MAX_CONNECTIONS=$max_conn minus TEST_SUPERUSER_RESERVED=$superuser_reserved minus TEST_CONNECTION_HEADROOM=$headroom minus TEST_NONPOOL_CONNECTION_RESERVE=$nonpool_reserve minus (N=$N * PROVISIONING_POOL_SIZE=$PROVISIONING_POOL_SIZE) leaves no room for even the TEST_MIN_POOL_SIZE=$min_pool floor" >&2
    exit 1
  fi

  computed_pool=$((budget / N))
  if [ "$computed_pool" -lt "$min_pool" ]; then
    echo "test_parallel: WARN N=$N partitions would need pool_size=$computed_pool to fit within $budget connections (max_connections=$max_conn - superuser_reserved=$superuser_reserved - headroom=$headroom - nonpool_reserve=$nonpool_reserve - N*provisioning_pool_size=$((N * PROVISIONING_POOL_SIZE))); clamping to the TEST_MIN_POOL_SIZE floor of $min_pool instead. This means N*pool_size ($((N * min_pool))) may still exceed the connection budget -- reduce N (TEST_PARALLEL_N=<n>) if you hit too_many_connections." >&2
    export TEST_POOL_SIZE="$min_pool"
  else
    export TEST_POOL_SIZE="$computed_pool"
  fi
  echo "test_parallel: TEST_POOL_SIZE=$TEST_POOL_SIZE (computed: N=$N, max_connections=$max_conn, superuser_reserved=$superuser_reserved, headroom=$headroom, nonpool_reserve=$nonpool_reserve, provisioning_pool_size=$PROVISIONING_POOL_SIZE)"
else
  echo "test_parallel: TEST_POOL_SIZE=$TEST_POOL_SIZE (caller override, not computed)"
fi

# ISS-0297: exclude tests that need pool_size >= 100 (impossible at N >= 2)
if [ "$TEST_POOL_SIZE" -lt 100 ]; then
  high_pool_demand_exclude="--exclude high_pool_demand"
else
  high_pool_demand_exclude=""
fi

# --- Step 1.6: seed N per-partition build paths (sequential, before any ---
# --- partition backgrounds) -- ISS-0377 -----------------------------------
#
# Step 1 above compiles _build/test exactly once (AC5). Without this step,
# every partition launched in Step 2 would still point at that one shared
# _build/test tree for its *entire* run (not just the pre-compile), and
# each mix test process's own startup manifest/lock/consolidation-cache
# touches on that shared path race against sibling partitions -- tolerated
# (mostly) on POSIX, but a hard abort ("could not create hard link ...
# permission denied") on Windows/NTFS. Fix: give each partition its own
# _build/test-partition-<i> tree, seeded from the single compiled _build/
# test tree via a hardlink-preferring recursive copy, done sequentially
# (no concurrency) so the seed pass itself introduces no race. This is
# filesystem duplication of an already-compiled tree, not a recompile --
# it does not reintroduce the N-independent-compiles cost req113's AC5
# exists to avoid. See lib/letflow/design/iss0377-cross-platform-test-fixes.md
# Part B for the full rationale.
echo "test_parallel: seeding $N per-partition build paths from _build/test (sequential)"

i=1
while [ "$i" -le "$N" ]; do
  partition_build_path="_build/test-partition-$i"
  rm -rf "$partition_build_path"

  if cp -al "_build/test" "$partition_build_path" 2>/dev/null; then
    : # hardlink-preserving copy succeeded (near-zero extra disk cost)
  elif cp -r "_build/test" "$partition_build_path"; then
    : # fallback: plain recursive copy on filesystems without hardlink support
  else
    echo "test_parallel: ERROR failed to seed $partition_build_path from _build/test -- no partition launched" >&2
    exit 1
  fi

  i=$((i + 1))
done

# --- Step 2: launch N background partitions -------------------------------

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/letflow_test_parallel.XXXXXX")
echo "test_parallel: partition logs in $tmp_dir"

# ISS-0217: a single tag shared by every partition THIS invocation launches, so
# config/test.exs can fold it into each partition's application_name and
# TenantSchemaReaper's ISS-0110 liveness guard can recognise these N partitions
# as expected siblings of each other rather than as N separate external
# invocations (which made the guard defer every sweep unconditionally under any
# N>1 run -- see docs/issues/ISS-0217.yaml). $$ is this script's own shell PID:
# unique per test_parallel.sh invocation, no external dependency, and every
# partition process it forks below inherits it as an exported env var.
export TEST_PARALLEL_GROUP="tp$$"
echo "test_parallel: TEST_PARALLEL_GROUP=$TEST_PARALLEL_GROUP (shared by all $N partitions)"

declare -a pids
declare -a exits
declare -a properties
declare -a tests_count
declare -a failures

i=1
while [ "$i" -le "$N" ]; do
  # MIX_BUILD_PATH is set per-invocation (command-scoped), not exported
  # globally, because every partition must see a *different* value --
  # unlike TEST_PARALLEL_GROUP/TEST_POOL_SIZE above, which are deliberately
  # global-exported since every partition shares the same value there.
  MIX_TEST_PARTITION="$i" MIX_BUILD_PATH="_build/test-partition-$i" \
    mix test --partitions "$N" --no-color $high_pool_demand_exclude "$@" \
    > "$tmp_dir/partition-$i.log" 2>&1 &
  pids[$i]=$!
  i=$((i + 1))
done

# --- Step 3: wait for each partition individually --------------------------

i=1
while [ "$i" -le "$N" ]; do
  wait "${pids[$i]}"
  exits[$i]=$?
  i=$((i + 1))
done

# --- Step 4: aggregate each partition's real reported counts (AC1, AC2) ---
#
# Real ExUnit summary shape on this toolchain (design doc section 4.5, not
# the "<N> tests, <M> failures" shape an earlier design iteration wrongly
# assumed):
#   Result: <passed> passed[/<total>][ (<type breakdown>)]
#   Failed: <n> <type>[, <n> <type>...]     (only present when >0 failures)

total_properties=0
total_tests=0
total_failures=0
any_failed=0

i=1
while [ "$i" -le "$N" ]; do
  log="$tmp_dir/partition-$i.log"
  ex="${exits[$i]}"

  result_line=$(grep -E '^Result: ' "$log" | tail -n 1)
  failed_line=$(grep -E '^Failed: ' "$log" | tail -n 1)

  has_result=1
  if [ -z "$result_line" ]; then
    has_result=0
  fi

  passed_i=0
  total_i=0
  if printf '%s' "$result_line" | grep -Eq '^Result: [0-9]+/[0-9]+ passed'; then
    nums=$(printf '%s' "$result_line" | grep -oE '^Result: [0-9]+/[0-9]+' | grep -oE '[0-9]+')
    passed_i=$(printf '%s\n' "$nums" | sed -n '1p')
    total_i=$(printf '%s\n' "$nums" | sed -n '2p')
  elif printf '%s' "$result_line" | grep -Eq '^Result: [0-9]+ passed'; then
    passed_i=$(printf '%s' "$result_line" | grep -oE '^Result: [0-9]+' | grep -oE '[0-9]+')
    total_i="$passed_i"
  fi

  # Parenthesized per-type breakdown, e.g. "(5 properties, 1269 tests)" or
  # "(2/5 properties, 115/117 tests)". Absent entirely when only one test
  # type ran in this partition.
  paren=$(printf '%s' "$result_line" | grep -oE '\([^)]*\)')

  p=0
  t=0
  if [ -n "$paren" ]; then
    prop_entry=$(printf '%s' "$paren" | grep -oE '[0-9]+(/[0-9]+)? propert(y|ies)')
    test_entry=$(printf '%s' "$paren" | grep -oE '[0-9]+(/[0-9]+)? tests?')
    if [ -n "$prop_entry" ]; then
      p=$(printf '%s' "$prop_entry" | grep -oE '[0-9]+' | tail -n 1)
    fi
    if [ -n "$test_entry" ]; then
      t=$(printf '%s' "$test_entry" | grep -oE '[0-9]+' | tail -n 1)
    fi
  else
    # No breakdown present -> exactly one type ran. Attributed to plain
    # tests per design doc section 4.5's documented assumption (OQ-2b).
    t="$total_i"
  fi

  f=0
  if [ -n "$failed_line" ]; then
    f=$(printf '%s' "$failed_line" | grep -oE '[0-9]+ (propert(y|ies)|tests?)' | grep -oE '^[0-9]+' | awk '{s+=$1} END{print s+0}')
  fi

  properties[$i]="$p"
  tests_count[$i]="$t"
  failures[$i]="$f"

  total_properties=$((total_properties + p))
  total_tests=$((total_tests + t))
  total_failures=$((total_failures + f))

  # Cross-check (design doc section 4.5/2.2): on this toolchain exit 2 is
  # the normal "had ExUnit failures" code, not 1 -- and the parsed
  # failure count, not the raw exit code, is authoritative for AC3.
  partition_failed=0
  if [ "$has_result" -eq 0 ]; then
    echo "test_parallel: WARNING partition $i has no Result: line in its log (compile/config/crash abort), exit=$ex" >&2
    partition_failed=1
  elif [ "$ex" -eq 0 ] && [ "$f" -eq 0 ]; then
    : # consistent clean pass, no warning
  elif [ "$ex" -eq 2 ] && [ "$f" -gt 0 ]; then
    : # consistent failure, no warning
  elif [ "$ex" -eq 2 ] && [ "$f" -eq 0 ]; then
    echo "test_parallel: WARNING partition $i exit 2 but 0 parsed failures (see design section 2.2/OQ-5)" >&2
  else
    echo "test_parallel: WARNING partition $i exit code / parsed count mismatch (exit=$ex, failures=$f)" >&2
    partition_failed=1
  fi

  if [ "$f" -gt 0 ]; then
    partition_failed=1
  fi
  if [ "$partition_failed" -eq 1 ]; then
    any_failed=1
  fi

  plural_p="properties"
  [ "$p" -eq 1 ] && plural_p="property"
  echo "partition $i: $t tests, $p $plural_p, $f failures, exit $ex"

  i=$((i + 1))
done

total_passed=$((total_properties + total_tests - total_failures))
total_all=$((total_properties + total_tests))

echo "---"
echo "combined: $total_tests tests, $total_properties properties, $total_failures failures ($total_passed/$total_all passed)"

# --- Step 5: exit-code contract (AC3) --------------------------------------
#
# Authoritative signal is the parsed failure count (any_failed, set above
# from failures_i and the has-Result-line check), not raw per-partition
# exit codes -- see design doc section 4.6.

exit "$any_failed"
