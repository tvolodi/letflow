#!/usr/bin/env bash
# Regression test for ISS-0698: scripts/test_parallel.sh's Step 2 used to
# launch all N partitions' ecto.create+ecto.migrate simultaneously with no
# stagger, which could burst past Postgres's real max_connections and crash
# most partitions with `Postgrex.Error FATAL 53300 (too_many_connections)`
# before any of them ever reached a `Result:` line (see
# docs/issues/ISS-0698.yaml and
# lib/letflow/design/iss0698-test-parallel-create-burst-fix.md). The fix adds
# a new Step 1.7 that runs ecto.create+ecto.migrate per partition under a
# concurrency cap (TEST_PARALLEL_MAX_CONCURRENT_CREATES, default 4) before
# Step 2 launches the actual parallel `mix test` phase.
#
# This is a REAL integration test, not a formula-extraction test like
# test/scripts/test_parallel_pool_sizing_test.sh (ISS-0287) -- ISS-0698's bug
# is a genuine multi-process connection race against a real Postgres server,
# which can't be reproduced by evaluating an isolated arithmetic block. This
# test spins up a disposable, deliberately small-max_connections Postgres
# container, forces a partition count/pool size combination that is known to
# expose the pre-fix race (verified live during WF03-ISS0698-20260917: N=8,
# TEST_POOL_SIZE=2 forced, against max_connections=30 -- pre-fix, only 1/8
# partitions produced a Result: line and partitions logged real 53300 errors;
# post-fix, all 8 partitions create+migrate and all 8 produce a Result: line),
# and asserts the fixed behavior against the real target script.
#
# Requires Docker. If Docker isn't available, this test FAILS loudly rather
# than silently skipping -- a regression test that can quietly no-op is worse
# than no test (see docs/anti-patterns.md's running theme on silent no-ops).
#
# Usage: test/scripts/test_parallel_create_burst_test.sh
# Optional: TEST_PARALLEL_SCRIPT=<path> to point at a different copy of
# test_parallel.sh (kept for flexibility/documentation only -- see below for
# why it does NOT by itself reproduce the pre-fix defect).
#
# Fail-then-pass proof for THIS fix was gathered against a full pre-fix git
# worktree checkout (commit 8403e8e8, the parent of fix commit 664436fc),
# not by pointing this script's TEST_PARALLEL_SCRIPT override at an old copy
# of test_parallel.sh alone -- ISS-0698's fix spans BOTH
# scripts/test_parallel.sh and mix.exs's `test:` alias, so swapping only the
# script while running from a post-fix mix.exs would not isolate the pre-fix
# behavior. Verified live during WF03-ISS0698-20260917 (N=8, TEST_POOL_SIZE=2
# forced, against a disposable max_connections=30 Postgres container):
# pre-fix, only 1/8 partitions produced a Result: line and multiple
# partitions logged real `Postgrex.Error FATAL 53300 (too_many_connections)`;
# post-fix (same container, same N/pool), all 8 partitions created+migrated
# and all 8 produced a Result: line, combined 1008/1008 tests passed, no
# 53300 anywhere in the output. This test file encodes the POST-fix
# assertions (the ones that must hold going forward); the pre-fix failure is
# documented here and in the run's own handoff rather than re-derived by this
# script automatically on every run.

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
target="${TEST_PARALLEL_SCRIPT:-$repo_root/scripts/test_parallel.sh}"

CONTAINER_NAME="letflow-iss0698-regression-pg"
HOST_PORT="${TEST_ISS0698_DB_PORT:-5799}"
N=8
POOL_SIZE=2
MAX_CONNECTIONS=30
TEST_TARGET="test/letflow/engine"

pass=0
fail=0
cleanup_done=0

cleanup() {
  if [ "$cleanup_done" -eq 1 ]; then
    return
  fi
  cleanup_done=1
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
}
trap cleanup EXIT

if [ ! -f "$target" ]; then
  echo "FAIL: target script not found: $target" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "FAIL: docker is required to reproduce ISS-0698's real connection-burst race; not found on PATH" >&2
  exit 1
fi

echo "test_parallel_create_burst_test: starting disposable Postgres (max_connections=$MAX_CONNECTIONS) on port $HOST_PORT"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
if ! docker run -d --name "$CONTAINER_NAME" -p "$HOST_PORT:5432" \
  -e POSTGRES_USER=letflow -e POSTGRES_PASSWORD=letflow -e POSTGRES_DB=letflow_test1 \
  postgres:16 -c max_connections="$MAX_CONNECTIONS" >/dev/null 2>&1; then
  echo "FAIL: could not start disposable Postgres container $CONTAINER_NAME" >&2
  exit 1
fi

ready=0
for _ in $(seq 1 15); do
  sleep 2
  if docker exec "$CONTAINER_NAME" pg_isready -U letflow >/dev/null 2>&1; then
    ready=1
    break
  fi
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: disposable Postgres container $CONTAINER_NAME never became ready" >&2
  exit 1
fi

echo "test_parallel_create_burst_test: running $target (N=$N, TEST_POOL_SIZE=$POOL_SIZE forced) against it"
log_file="$(mktemp)"
(
  cd "$repo_root" && \
  LETFLOW_DB_PORT="$HOST_PORT" TEST_PARALLEL_N="$N" TEST_POOL_SIZE="$POOL_SIZE" \
    TEST_PARALLEL_SCRIPT="$target" \
    bash "$target" "$TEST_TARGET"
) >"$log_file" 2>&1
run_exit=$?

echo "--- test_parallel.sh output ---"
cat "$log_file"
echo "--- end output ---"

# Assertion 1: the script itself must exit 0.
if [ "$run_exit" -eq 0 ]; then
  echo "PASS: script exited 0"
  pass=$((pass + 1))
else
  echo "FAIL: script exited $run_exit (expected 0)"
  fail=$((fail + 1))
fi

# Assertion 2: every one of the N partitions must have produced its own
# "partition <i>: ... exit 0" summary line -- a missing one means that
# partition never reached a Result: line (exactly ISS-0698's symptom).
missing_partitions=0
for i in $(seq 1 "$N"); do
  if ! grep -qE "^partition $i: .* exit 0\$" "$log_file"; then
    missing_partitions=$((missing_partitions + 1))
    echo "  missing/failed: partition $i"
  fi
done
if [ "$missing_partitions" -eq 0 ]; then
  echo "PASS: all $N partitions produced a successful Result: line"
  pass=$((pass + 1))
else
  echo "FAIL: $missing_partitions of $N partitions did not produce a successful Result: line"
  fail=$((fail + 1))
fi

# Assertion 3: no partition's create/migrate or test-phase log may contain a
# 53300 too_many_connections error -- this is the literal defect ISS-0698
# filed against.
if grep -qE "53300|too_many_connections" "$log_file"; then
  echo "FAIL: 53300/too_many_connections found in combined output"
  fail=$((fail + 1))
else
  echo "PASS: no 53300/too_many_connections in combined output"
  pass=$((pass + 1))
fi

rm -f "$log_file"

echo "---"
echo "test_parallel_create_burst_test: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
exit 0
