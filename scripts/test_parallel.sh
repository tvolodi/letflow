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
#   4. Parse each partition's log for its ExUnit summary line
#      (`"<N> tests, <M> failures"`, optionally prefixed with
#      `"<K> properties, "`) and sum properties/tests/failures across all
#      partitions into one combined total, cross-checking each partition's
#      parsed failure count against its process exit code.
#   5. Exit 0 only if every partition exited 0 and no cross-check
#      mismatch fired; exit 1 otherwise.
#
# Usage: scripts/test_parallel.sh [args passed through to every
# partition's `mix test` invocation, e.g. a path filter or --seed]
#
# Overridable knob: TEST_PARALLEL_N=<positive integer> to force the
# partition count instead of deriving it from nproc/getconf.

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

# --- Step 2: launch N background partitions -------------------------------

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/letflow_test_parallel.XXXXXX")
echo "test_parallel: partition logs in $tmp_dir"

declare -a pids
declare -a exits
declare -a properties
declare -a tests_count
declare -a failures

i=1
while [ "$i" -le "$N" ]; do
  MIX_TEST_PARTITION="$i" mix test --partitions "$N" --no-color "$@" \
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

total_properties=0
total_tests=0
total_failures=0
any_mismatch=0

i=1
while [ "$i" -le "$N" ]; do
  log="$tmp_dir/partition-$i.log"
  summary_line=$(grep -E '^[0-9]+ (propert(y|ies)|tests?), .*[0-9]+ failures?' "$log" | tail -n 1)

  if [ -n "$summary_line" ]; then
    if printf '%s' "$summary_line" | grep -q 'propert'; then
      p=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ propert(y|ies)' | grep -oE '[0-9]+')
    else
      p=0
    fi
    t=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ tests?,' | grep -oE '[0-9]+')
    f=$(printf '%s' "$summary_line" | grep -oE '[0-9]+ failures?' | grep -oE '[0-9]+')
  else
    p=0
    t=0
    f=0
  fi

  properties[$i]="$p"
  tests_count[$i]="$t"
  failures[$i]="$f"

  total_properties=$((total_properties + p))
  total_tests=$((total_tests + t))
  total_failures=$((total_failures + f))

  # Cross-check: exit code vs parsed failure count must agree, or the log
  # must show no summary line at all (compile/crash error case).
  ex="${exits[$i]}"
  mismatch=0
  if [ "$ex" -eq 0 ] && [ "$f" -ne 0 ]; then
    mismatch=1
  elif [ "$ex" -ne 0 ] && [ "$f" -eq 0 ] && [ -n "$summary_line" ]; then
    mismatch=1
  fi
  if [ "$mismatch" -eq 1 ]; then
    echo "test_parallel: WARNING partition $i exit code / parsed count mismatch (exit=$ex, failures=$f)" >&2
    any_mismatch=1
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

overall=0
i=1
while [ "$i" -le "$N" ]; do
  if [ "${exits[$i]}" -ne 0 ]; then
    overall=1
  fi
  i=$((i + 1))
done
if [ "$any_mismatch" -eq 1 ]; then
  overall=1
fi

exit "$overall"
