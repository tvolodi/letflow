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
# Overridable knob: TEST_PARALLEL_KEEP_LOGS=<any non-empty value> to keep the
# per-partition tmp_dir (create/migrate + test logs) even after a fully clean
# (exit 0) run -- see ISS-0699 below. Unset by default, meaning a clean run's
# tmp_dir is removed automatically; a run with any real failures always
# preserves it regardless of this var.
#
# Overridable knob: TEST_PER_PARTITION_HEADROOM=<non-negative integer>
# (default 0, a deliberate no-op -- N*0=0 leaves Step 1.5's formula
# unchanged) -- ISS-0287 §4.1, adds an N-scaling connection-budget margin
# (N * TEST_PER_PARTITION_HEADROOM) to Step 1.5's pool clamp, for once a
# real per-partition overshoot has been measured (see
# lib/letflow/design/iss0287-pool-headroom-n-scaling.md §4.1/OQ-2).
#
# Overridable knob: TEST_PARALLEL_SAMPLE_CONNECTIONS=<any non-empty value>
# (default unset/off) -- ISS-0287 §4.3, opt-in pg_stat_activity
# connection-count sampler logged to the run's own tmp_dir, purely
# diagnostic (see design doc §4.3). Zero cost when unset.
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

# ISS-0917 §3.2 step 1: enable bash job control (`set -m`) so every
# backgrounded job launched from here on (Step 2's partitions in
# particular) gets its OWN process group, with pgid == the job's own pid
# (bash's own job-control convention, not something this script computes).
# This is the "equivalent job-control idiom" the design allows in place of
# an external `setsid` binary -- deliberately NOT `setsid`: this script also
# runs on Windows/Git-Bash hosts (this issue's own title names one), where
# `setsid` does not exist, while `set -m` is a bash builtin. It is what
# makes `kill -- -$pid` (a negative pid = "the whole process group", not
# just the immediate child) reach the real `erl.exe`/`beam.smp` grandchild a
# plain `kill $pid` or a default `timeout` invocation cannot -- the
# documented gap in docs/anti-patterns.md's zombie-BEAM entry. Side effect:
# bash may print its own "[N]+ Done/Terminated ..." job-control notices to
# this script's stderr as jobs complete -- harmless noise, not parsed by
# anything (the aggregator in Step 4 reads each partition's own redirected
# log file, never this script's own stdout/stderr).
set -m

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

# --- Step 1.4: verify host Postgres ceiling assumptions (ISS-0287 §4.2) ----
#
# Step 1.5 below treats TEST_MAX_CONNECTIONS/TEST_SUPERUSER_RESERVED as
# known facts about the real server (defaults 100/3), but they are
# hardcoded assumptions, not measurements -- decision 0009 already flags
# TEST_MAX_CONNECTIONS as host/container-config-dependent, and
# lib/letflow/design/iss0287-pool-headroom-n-scaling.md §3.1(3) names an
# unverified-ceiling mismatch as a candidate cause of the ISS-0287 N=8
# reopening. This step queries the real, live Postgres instance (if
# reachable) via `psql` and WARNs -- never hard-fails -- on a mismatch: a
# config-drift gap, not an arithmetic gap, and no formula change fixes a
# wrong input to a correct formula (design doc §4.2). It is best-effort
# evidence gathering, not a gate: missing `psql`, an unreachable DB, or any
# query failure all degrade to a single WARN and the script continues
# exactly as it would have before this step existed.
_test_parallel_db_port="${LETFLOW_DB_PORT:-}"
if [ -z "$_test_parallel_db_port" ] && [ -f ".env" ]; then
  _test_parallel_db_port=$(grep -E '^LETFLOW_DB_PORT=' ".env" | tail -n 1 | cut -d= -f2- | tr -d '[:space:]')
fi
_test_parallel_db_port="${_test_parallel_db_port:-5462}"
_test_parallel_db_host="${LETFLOW_DB_HOST:-localhost}"
_test_parallel_db_user="${LETFLOW_DB_USER:-letflow}"
_test_parallel_db_password="${LETFLOW_DB_PASSWORD:-letflow}"

if ! command -v psql >/dev/null 2>&1; then
  echo "test_parallel: WARN psql not found -- skipping host Postgres ceiling verification (ISS-0287 §4.2); TEST_MAX_CONNECTIONS/TEST_SUPERUSER_RESERVED assumptions unverified against the live server" >&2
else
  _live_max_conn=$(PGPASSWORD="$_test_parallel_db_password" psql -h "$_test_parallel_db_host" -p "$_test_parallel_db_port" -U "$_test_parallel_db_user" -d postgres -tAc "show max_connections;" 2>/dev/null | tr -d '[:space:]')
  _live_superuser_reserved=$(PGPASSWORD="$_test_parallel_db_password" psql -h "$_test_parallel_db_host" -p "$_test_parallel_db_port" -U "$_test_parallel_db_user" -d postgres -tAc "show superuser_reserved_connections;" 2>/dev/null | tr -d '[:space:]')

  if [ -z "$_live_max_conn" ] || [ -z "$_live_superuser_reserved" ]; then
    echo "test_parallel: WARN could not reach Postgres at $_test_parallel_db_host:$_test_parallel_db_port to verify host ceiling assumptions (ISS-0287 §4.2) -- continuing with configured/default TEST_MAX_CONNECTIONS/TEST_SUPERUSER_RESERVED unverified" >&2
  else
    _assumed_max_conn="${TEST_MAX_CONNECTIONS:-100}"
    _assumed_superuser_reserved="${TEST_SUPERUSER_RESERVED:-3}"
    _host_check_mismatch=0
    if [ "$_live_max_conn" != "$_assumed_max_conn" ]; then
      echo "test_parallel: WARN live Postgres max_connections=$_live_max_conn does not match assumed TEST_MAX_CONNECTIONS=$_assumed_max_conn -- set TEST_MAX_CONNECTIONS=$_live_max_conn explicitly if this is intentional (config-drift, not an arithmetic defect; see decision 0009's ISS-0287 §4.2 addendum)" >&2
      _host_check_mismatch=1
    fi
    if [ "$_live_superuser_reserved" != "$_assumed_superuser_reserved" ]; then
      echo "test_parallel: WARN live Postgres superuser_reserved_connections=$_live_superuser_reserved does not match assumed TEST_SUPERUSER_RESERVED=$_assumed_superuser_reserved -- set TEST_SUPERUSER_RESERVED=$_live_superuser_reserved explicitly if this is intentional (config-drift, not an arithmetic defect; see decision 0009's ISS-0287 §4.2 addendum)" >&2
      _host_check_mismatch=1
    fi
    if [ "$_host_check_mismatch" -eq 0 ]; then
      echo "test_parallel: host ceiling verified -- live max_connections=$_live_max_conn, superuser_reserved_connections=$_live_superuser_reserved match assumed/configured defaults"
    fi
  fi
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
# ISS-0515/ISS-0426: a second, distinct source now also falls outside this
# arithmetic -- executor_test.exs's isolated-partition self-check spawns a
# NESTED `mix test` subprocess (its own OS process/BEAM VM), which that
# test's own System.cmd/3 call now caps to a small, fixed-size Ecto pool
# (TEST_POOL_SIZE=4 passed via :env -- NOT 1; a pool of exactly 1 was tried
# first and caused its own DBConnection checkout-queue timeout under this
# file's `async: true`, see the test's own comment) rather than an entire
# uncapped sibling-partition-sized pool. TEST_NONPOOL_CONNECTION_RESERVE's
# default is bumped from 3 to 5 to reserve room for both named sources at once:
# the ISS-0287 reaper-test connection (at most 1 concurrently) plus this
# nested subprocess's full capped pool (up to 4 concurrently, by the cap
# above). They don't overlap in practice, but the reserve is sized for the
# worst case, not the common case. See
# docs/migration/decisions/0009-test-parallel-pool-sizing.md's ISS-0515
# addendum.
#
# TEST_POOL_SIZE, if the caller already set it, is never overridden here --
# an explicit choice always wins over this clamp. ISS-0287 §4.1 (lib/letflow/design/iss0287-pool-headroom-n-scaling.md): TEST_PER_PARTITION_HEADROOM adds an N-scaling margin below, default 0 (no-op: N×0=0 reduces to today's formula exactly).
if [ -z "${TEST_POOL_SIZE:-}" ]; then
  max_conn="${TEST_MAX_CONNECTIONS:-100}"
  headroom="${TEST_CONNECTION_HEADROOM:-10}"
  min_pool="${TEST_MIN_POOL_SIZE:-2}"
  superuser_reserved="${TEST_SUPERUSER_RESERVED:-3}"
  nonpool_reserve="${TEST_NONPOOL_CONNECTION_RESERVE:-5}"
  per_partition_headroom="${TEST_PER_PARTITION_HEADROOM:-0}"

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

  if ! printf '%s' "$per_partition_headroom" | grep -Eq '^[0-9]+$'; then echo "test_parallel: ERROR TEST_PER_PARTITION_HEADROOM='$per_partition_headroom' is not a non-negative integer" >&2; exit 1; fi
  usable_ceiling=$((max_conn - superuser_reserved))
  budget=$((usable_ceiling - headroom - nonpool_reserve - (N * per_partition_headroom)))
  if [ "$budget" -lt "$min_pool" ]; then
    echo "test_parallel: ERROR TEST_MAX_CONNECTIONS=$max_conn minus TEST_SUPERUSER_RESERVED=$superuser_reserved minus TEST_CONNECTION_HEADROOM=$headroom minus TEST_NONPOOL_CONNECTION_RESERVE=$nonpool_reserve minus (N=$N times TEST_PER_PARTITION_HEADROOM=$per_partition_headroom) leaves no room for even the TEST_MIN_POOL_SIZE=$min_pool floor" >&2
    exit 1
  fi

  computed_pool=$((budget / N))
  if [ "$computed_pool" -lt "$min_pool" ]; then
    echo "test_parallel: WARN N=$N partitions would need pool_size=$computed_pool to fit within $budget connections (max_connections=$max_conn - superuser_reserved=$superuser_reserved - headroom=$headroom - nonpool_reserve=$nonpool_reserve - N*per_partition_headroom=$((N * per_partition_headroom))); clamping to the TEST_MIN_POOL_SIZE floor of $min_pool instead. This means N*pool_size ($((N * min_pool))) may still exceed the connection budget -- reduce N (TEST_PARALLEL_N=<n>) if you hit too_many_connections." >&2
    export TEST_POOL_SIZE="$min_pool"
  else
    export TEST_POOL_SIZE="$computed_pool"
  fi
  echo "test_parallel: TEST_POOL_SIZE=$TEST_POOL_SIZE (computed: N=$N, max_connections=$max_conn, superuser_reserved=$superuser_reserved, headroom=$headroom, nonpool_reserve=$nonpool_reserve, per_partition_headroom=$per_partition_headroom)"
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

# --- Step 1.7: capped-concurrency pre-create/pre-migrate (ISS-0698) -------
#
# Root cause (see lib/letflow/design/iss0698-test-parallel-create-burst-fix.md
# for the full design): Step 2 below backgrounds all N partitions' `mix test`
# processes with no stagger. Each of those, via mix.exs's `test:` alias, used
# to independently run `ecto.create --quiet` then `ecto.migrate --quiet`
# before ever reaching the test phase -- and `ecto.migrate` calls
# Mix.Ecto.ensure_started/2, which starts a full Letflow.Repo pool at that
# partition's own TEST_POOL_SIZE. All N partitions hit this pool-open at the
# same wall-clock instant, transiently exceeding Postgres's max_connections
# even though Step 1.5's clamp already bounds steady-state N*TEST_POOL_SIZE
# test-phase demand -- this is a distinct, launch-time-synchronized pool-open
# the clamp was never sized to cover. Fix: run ecto.create+ecto.migrate here,
# sequentially within each partition but capped in flight across partitions,
# fully before Step 2 ever backgrounds a single test-phase process; Step 2's
# `mix test` invocations then pass LETFLOW_SKIP_ECTO_SETUP=1 so mix.exs's
# `test:` alias does not redundantly re-run (and re-burst) create/migrate.
#
# ISS-0699: tmp_dir below was never removed on any exit path, leaking one
# directory (partition create/test logs) per invocation -- ~280 accumulated
# on the host that filed this issue. Fix: a single `trap ... EXIT` registered
# right after tmp_dir is created (see lib/letflow/design/iss0699-test-
# parallel-tmpdir-cleanup-fix.md for the full design/rationale) removes it
# only on a clean (exit 0) run, unless TEST_PARALLEL_KEEP_LOGS is set --
# every nonzero-exit path (including the create/migrate failures at lines
# below that cite "$tmp_dir/create-$i.log" in their own error message)
# preserves it so that citation stays inspectable.
cleanup_tmp_dir() {
  local exit_code=$?          # MUST be the first statement -- capturing $?
                               # here is what recovers this script's own real
                               # exit status; any earlier statement would
                               # clobber it before it can be read.

  # ISS-0287 §4.3: defensive kill of the opt-in connection sampler (started
  # in Step 2 below, if enabled) on ANY exit path, not just the normal one
  # after Step 3 -- so a background polling loop never outlives this script.
  if [ -n "${_test_parallel_sampler_pid:-}" ]; then
    kill "$_test_parallel_sampler_pid" 2>/dev/null
  fi

  # ISS-0917 §3.2 step 3 / AC6: reap any partition PID still alive at trap
  # time, on EVERY exit path (normal completion, the new Fix 2 hard-fail,
  # an external interruption, or any pre-existing `exit 1` path) -- not
  # just the tmp-dir/sampler cleanup above. `pids[]` is declared later in
  # the script (Step 2) but expands to an empty list here under `set -u` if
  # this trap fires before Step 2 is ever reached (e.g. an early Step 1
  # failure), so this is safe at every exit point, not just the late ones.
  # `kill -TERM -- "-$pid"` targets the WHOLE process group (pgid == pid,
  # per Step 2's `set -m`), not just the immediate child -- reaching the
  # real erl.exe/beam.smp grandchild the zombie-BEAM anti-pattern entry
  # names as the actual gap in a plain `kill $pid`.
  _reap_pgid=0
  for _idx in "${!pids[@]}"; do
    _pid="${pids[$_idx]}"
    if kill -0 "$_pid" 2>/dev/null; then
      echo "test_parallel: EXIT trap reaping still-alive partition $_idx (pid=$_pid) -- sending TERM to its process group" >&2
      kill -TERM -- "-$_pid" 2>/dev/null
      _reap_pgid=1
    fi
  done
  if [ "$_reap_pgid" -eq 1 ]; then
    sleep "${TEST_PARALLEL_PARTITION_KILL_GRACE_S:-10}"
    for _idx in "${!pids[@]}"; do
      _pid="${pids[$_idx]}"
      if kill -0 "$_pid" 2>/dev/null; then
        echo "test_parallel: EXIT trap partition $_idx still alive after TERM+grace -- escalating to KILL on its process group" >&2
        kill -KILL -- "-$_pid" 2>/dev/null
      fi
    done
  fi

  # Per-partition watchdogs (Step 2) are no longer needed once we're
  # tearing down -- kill any still-sleeping ones so they don't linger past
  # this script's own exit.
  for _idx in "${!watchdog_pids[@]}"; do
    kill "${watchdog_pids[$_idx]}" 2>/dev/null
  done

  if [ "$exit_code" -eq 0 ] && [ -z "${TEST_PARALLEL_KEEP_LOGS:-}" ]; then
    rm -rf "$tmp_dir"
  else
    echo "test_parallel: preserving $tmp_dir (exit_code=$exit_code, TEST_PARALLEL_KEEP_LOGS=${TEST_PARALLEL_KEEP_LOGS:-unset})" >&2
  fi
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/letflow_test_parallel.XXXXXX")
trap cleanup_tmp_dir EXIT
echo "test_parallel: partition logs in $tmp_dir"

max_concurrent_creates="${TEST_PARALLEL_MAX_CONCURRENT_CREATES:-4}"
if ! printf '%s' "$max_concurrent_creates" | grep -Eq '^[1-9][0-9]*$'; then
  echo "test_parallel: ERROR TEST_PARALLEL_MAX_CONCURRENT_CREATES='$max_concurrent_creates' is not a positive integer" >&2
  exit 1
fi

echo "test_parallel: seeding+migrating $N partition databases (capped at $max_concurrent_creates concurrent)"

declare -A create_pid_to_partition
in_flight=0

i=1
while [ "$i" -le "$N" ]; do
  if [ "$in_flight" -ge "$max_concurrent_creates" ]; then
    wait -n -p finished_pid
    finished_exit=$?
    finished_partition="${create_pid_to_partition[$finished_pid]}"
    unset 'create_pid_to_partition[$finished_pid]'
    in_flight=$((in_flight - 1))
    if [ "$finished_exit" -ne 0 ]; then
      echo "test_parallel: ERROR partition $finished_partition ecto.create/ecto.migrate failed with exit $finished_exit -- no partition launched (see $tmp_dir/create-$finished_partition.log)" >&2
      echo "test_parallel: ---- create-$finished_partition.log content (ISS-0779: printed inline since this dir is not a CI artifact) ----" >&2
      cat "$tmp_dir/create-$finished_partition.log" >&2
      echo "test_parallel: ---- end create-$finished_partition.log ----" >&2
      exit 1
    fi
  fi

  (
    MIX_ENV=test MIX_TEST_PARTITION="$i" MIX_BUILD_PATH="_build/test-partition-$i" mix ecto.create --quiet &&
      MIX_ENV=test MIX_TEST_PARTITION="$i" MIX_BUILD_PATH="_build/test-partition-$i" mix ecto.migrate --quiet
  ) > "$tmp_dir/create-$i.log" 2>&1 &
  create_pid_to_partition[$!]=$i
  in_flight=$((in_flight + 1))

  i=$((i + 1))
done

# Drain remaining in-flight create/migrate jobs.
while [ "$in_flight" -gt 0 ]; do
  wait -n -p finished_pid
  finished_exit=$?
  finished_partition="${create_pid_to_partition[$finished_pid]}"
  unset 'create_pid_to_partition[$finished_pid]'
  in_flight=$((in_flight - 1))
  if [ "$finished_exit" -ne 0 ]; then
    echo "test_parallel: ERROR partition $finished_partition ecto.create/ecto.migrate failed with exit $finished_exit -- no partition launched (see $tmp_dir/create-$finished_partition.log)" >&2
    echo "test_parallel: ---- create-$finished_partition.log content (ISS-0779: printed inline since this dir is not a CI artifact) ----" >&2
    cat "$tmp_dir/create-$finished_partition.log" >&2
    echo "test_parallel: ---- end create-$finished_partition.log ----" >&2
    exit 1
  fi
done

echo "test_parallel: all $N partition databases created+migrated"

# --- Step 1.8: capped-concurrency template-build admission control (ISS-0917) -
#
# See lib/letflow/design/iss0917-test-parallel-template-contention.md §1.3.
# Root cause: Step 2 below used to launch all N partitions' `mix test`
# processes with no stagger at all, and each one's test_helper.exs
# immediately calls ensure_template!/0 -- which, on this partition's first
# run, does a full CREATE SCHEMA + 53-migration replay pinned to ONE
# checked-out connection for the whole build. At N partitions simultaneously,
# that is N full migration replays hitting Postgres at the same instant -- a
# real CPU/IO/lock-manager contention burst, not a connection-count overflow
# (Step 1.5's clamp already prevents that part). Under that load, a
# straggler partition's pinned connection can exceed Repo.checkout/2's
# default 15000ms client-side timeout and abort before ever producing a
# Result: line. Same idiom as Step 1.7's ecto.create/ecto.migrate burst fix
# (ISS-0698), one phase later: cap how many partitions are simultaneously
# INSIDE their own template build, without serializing the whole suite --
# every partition still gets launched by the end of this step, just not all
# at once.
#
# tenant_template.ex's own advisory lock (build_template!/0 -> ensure_template!/0)
# is unchanged and unaffected by this -- it serializes callers WITHIN one
# partition database, which is a different (already-solved) problem; this
# step serializes ACROSS partitions, at the launch level, before any of
# them ever calls that lock.
template_ready_dir="$tmp_dir/template-ready"
mkdir -p "$template_ready_dir"
export TEST_PARALLEL_TEMPLATE_READY_DIR="$template_ready_dir"

# OQ-1 (design doc §7): default re-measured against this host's own N=nproc
# full-suite run (not assumed from ISS-0698's reused value without
# verification) -- see docs/issues/ISS-0917.yaml's resolution notes / this
# change's own PR description for the measurement this default is based on.
max_concurrent_template_builds="${TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS:-4}"
if ! printf '%s' "$max_concurrent_template_builds" | grep -Eq '^[1-9][0-9]*$'; then
  echo "test_parallel: ERROR TEST_PARALLEL_MAX_CONCURRENT_TEMPLATE_BUILDS='$max_concurrent_template_builds' is not a positive integer" >&2
  exit 1
fi

echo "test_parallel: template-build admission control capped at $max_concurrent_template_builds concurrent (ready dir: $template_ready_dir)"

# partition index -> pid, tracked ONLY while that partition's own template
# build is in flight (its ready-file has not yet appeared). Populated by
# Step 2's launch loop below.
declare -A building_partition_pid
in_flight_builders=0

# Polls the ready-dir/PID-liveness once. Decrements in_flight_builders for
# every newly-seen ready-file. If a tracked partition's OWN process has
# exited without ever producing a ready-file (design §1.3 mechanism 5 --
# e.g. it crashed during its own build, or Step 3.2's own per-partition
# watchdog killed it for running past TEST_PARALLEL_PARTITION_TIMEOUT_S),
# that is an immediate, loud, script-level failure -- admission control
# must not hang forever waiting for a ready-file that will never arrive.
poll_template_ready_dir() {
  local progressed=0
  local idx pid
  for idx in "${!building_partition_pid[@]}"; do
    pid="${building_partition_pid[$idx]}"
    if [ -e "$template_ready_dir/partition-$idx.ready" ]; then
      unset 'building_partition_pid[$idx]'
      in_flight_builders=$((in_flight_builders - 1))
      progressed=1
    elif ! kill -0 "$pid" 2>/dev/null; then
      echo "test_parallel: ERROR partition $idx's process exited during its own template build, before producing a ready-file ($template_ready_dir/partition-$idx.ready) -- no further partitions admitted (see $tmp_dir/partition-$idx.log)" >&2
      exit 1
    fi
  done
  if [ "$progressed" -eq 0 ]; then
    sleep 0.2
  fi
}

# Blocks (via the bounded ready-file/PID-liveness poll above -- never an
# unbounded spin, since a genuinely-stuck partition is itself bounded by its
# own wall-clock deadline, §3.2) until fewer than the cap are mid-build.
wait_for_build_admission_slot() {
  while [ "$in_flight_builders" -ge "$max_concurrent_template_builds" ]; do
    poll_template_ready_dir
  done
}

# --- Step 2: launch N background partitions -------------------------------

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
# ISS-0917 §3.2: partition index -> watchdog-process pid (the background
# sleep-then-maybe-kill job Step 2 launches alongside each partition).
declare -A watchdog_pids

# ISS-0917 §3.2 / OQ-3: per-partition wall-clock deadline. Must be generous
# enough to never false-positive on a genuinely slow-but-healthy partition.
# Measured directly (not guessed): a full, clean run on this host (8-core,
# TEST_PARALLEL_N=8, the full 5079-test suite) completed end to end in
# ~495s wall-clock, and a TEST_PARALLEL_N=6 run in ~520s -- i.e. every real
# partition finishes in well under 10 minutes here. 1800s (30 minutes) is
# set as the default: a >3x margin over this host's own slowest observed
# partition, generous enough to absorb a materially slower/busier CI host
# without false-positiving, while still bounding a genuinely-stuck
# partition to well under an hour rather than hanging indefinitely.
partition_timeout_s="${TEST_PARALLEL_PARTITION_TIMEOUT_S:-1800}"
if ! printf '%s' "$partition_timeout_s" | grep -Eq '^[1-9][0-9]*$'; then
  echo "test_parallel: ERROR TEST_PARALLEL_PARTITION_TIMEOUT_S='$partition_timeout_s' is not a positive integer" >&2
  exit 1
fi
# Grace window between TERM and KILL, both for the per-partition watchdog
# below and for the EXIT trap's own sweep (cleanup_tmp_dir, Step 1.7 area).
partition_kill_grace_s="${TEST_PARALLEL_PARTITION_KILL_GRACE_S:-10}"

# ISS-0287 §4.3: opt-in pg_stat_activity connection-count sampler, gated
# behind TEST_PARALLEL_SAMPLE_CONNECTIONS=1 (default unset/off -- adds zero
# cost to an ordinary run). Diagnostic-only, not a fix: while partitions run
# (this step and Step 3), polls pg_stat_activity every 1s and appends a
# timestamped count to $tmp_dir/connection_samples.log, to measure whether
# real concurrent connection count ever exceeds the formula's modeled worst
# case -- see lib/letflow/design/iss0287-pool-headroom-n-scaling.md §4.3.
# Each poll is a short-lived `psql` connection (opened, queried, closed),
# NOT a connection this script's own TEST_POOL_SIZE arithmetic budgets for
# -- noted, not silently assumed harmless, per the design's own OQ-4: this
# adds a small, transient, one-connection-at-a-time load of its own,
# informally covered by TEST_CONNECTION_HEADROOM's existing ad-hoc-tooling
# margin, same as a human's own interactive psql session would be.
_test_parallel_sampler_pid=""
if [ -n "${TEST_PARALLEL_SAMPLE_CONNECTIONS:-}" ]; then
  if ! command -v psql >/dev/null 2>&1; then
    echo "test_parallel: WARN TEST_PARALLEL_SAMPLE_CONNECTIONS set but psql not found -- sampler not started" >&2
  else
    _test_parallel_sampler_log="$tmp_dir/connection_samples.log"
    echo "test_parallel: connection sampler enabled -- logging to $_test_parallel_sampler_log every 1s"
    (
      while true; do
        _sample_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        _sample_count=$(PGPASSWORD="$_test_parallel_db_password" psql -h "$_test_parallel_db_host" -p "$_test_parallel_db_port" -U "$_test_parallel_db_user" -d postgres -tAc "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'letflow_mixtest_%';" 2>/dev/null | tr -d '[:space:]')
        echo "$_sample_ts count=${_sample_count:-ERROR}" >> "$_test_parallel_sampler_log"
        sleep 1
      done
    ) &
    _test_parallel_sampler_pid=$!
  fi
fi

i=1
while [ "$i" -le "$N" ]; do
  # ISS-0917 §1.3 step 3: admission control -- blocks here (bounded, never
  # forever, see wait_for_build_admission_slot/poll_template_ready_dir
  # above) until fewer than max_concurrent_template_builds partitions are
  # still mid-template-build, so at most that many partitions are ever
  # simultaneously inside ensure_template!/0's migration replay.
  wait_for_build_admission_slot

  # MIX_BUILD_PATH is set per-invocation (command-scoped), not exported
  # globally, because every partition must see a *different* value --
  # unlike TEST_PARALLEL_GROUP/TEST_POOL_SIZE above, which are deliberately
  # global-exported since every partition shares the same value there.
  #
  # ISS-0917 §3.2 step 1: launched under `set -m` (top of script), so this
  # job gets its own process group with pgid == its own pid -- what makes
  # the watchdog below (and the EXIT trap) able to signal the WHOLE tree
  # (mix + erl.exe/beam.smp), not just this immediate child.
  MIX_TEST_PARTITION="$i" MIX_BUILD_PATH="_build/test-partition-$i" LETFLOW_SKIP_ECTO_SETUP=1 \
    mix test --partitions "$N" --no-color $high_pool_demand_exclude "$@" \
    > "$tmp_dir/partition-$i.log" 2>&1 &
  pids[$i]=$!
  building_partition_pid[$i]=$!
  in_flight_builders=$((in_flight_builders + 1))

  # ISS-0917 §3.2 step 2: per-partition wall-clock deadline, enforced by a
  # small background watchdog rather than an external `timeout` binary --
  # `timeout` only signals its own immediate child by default and would
  # miss the grandchild erl.exe the same way a bare background job does;
  # this watchdog signals the process GROUP instead (TERM, then KILL after
  # a grace window if TERM is ignored), same as the EXIT trap's own sweep.
  # Killed off in Step 3 as soon as its partition's own `wait` returns, so
  # it does not linger for the rest of partition_timeout_s once the
  # partition finishes normally.
  (
    _watchdog_pid=${pids[$i]}
    sleep "$partition_timeout_s"
    if kill -0 "$_watchdog_pid" 2>/dev/null; then
      echo "test_parallel: WARNING partition $i exceeded TEST_PARALLEL_PARTITION_TIMEOUT_S=${partition_timeout_s}s -- sending TERM to its process group" >&2
      kill -TERM -- "-$_watchdog_pid" 2>/dev/null
      sleep "$partition_kill_grace_s"
      if kill -0 "$_watchdog_pid" 2>/dev/null; then
        echo "test_parallel: WARNING partition $i still alive after TERM+grace -- escalating to KILL on its process group" >&2
        kill -KILL -- "-$_watchdog_pid" 2>/dev/null
      fi
    fi
  ) &
  watchdog_pids[$i]=$!

  i=$((i + 1))
done

# --- Step 3: wait for each partition individually --------------------------

i=1
while [ "$i" -le "$N" ]; do
  wait "${pids[$i]}"
  exits[$i]=$?
  # This partition is done (one way or another) -- its own watchdog is no
  # longer needed. Kill it now rather than letting it sleep uselessly for
  # the rest of partition_timeout_s (ISS-0917 §3.2).
  if [ -n "${watchdog_pids[$i]:-}" ]; then
    kill "${watchdog_pids[$i]}" 2>/dev/null
    wait "${watchdog_pids[$i]}" 2>/dev/null
  fi
  i=$((i + 1))
done

# ISS-0287 §4.3: stop the sampler (if started above) now that every
# partition has finished, so its log file reflects the run's full duration.
if [ -n "$_test_parallel_sampler_pid" ]; then
  kill "$_test_parallel_sampler_pid" 2>/dev/null
  wait "$_test_parallel_sampler_pid" 2>/dev/null
  echo "test_parallel: connection sampler stopped ($_test_parallel_sampler_log)"
fi

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
# ISS-0917 §2 -- explicit, structural "did everyone report" invariant,
# independent of (in addition to) the per-partition has_result/
# partition_failed anomaly checks below. reporting_count counts partitions
# whose log had a real Result: line; missing_partition_indices names every
# partition index that did NOT (see the hard check right after this loop).
reporting_count=0
declare -a missing_partition_indices=()

i=1
while [ "$i" -le "$N" ]; do
  log="$tmp_dir/partition-$i.log"
  ex="${exits[$i]}"

  result_line=$(grep -E '^Result: ' "$log" | tail -n 1)
  failed_line=$(grep -E '^Failed: ' "$log" | tail -n 1)

  has_result=1
  if [ -z "$result_line" ]; then
    has_result=0
    missing_partition_indices+=("$i")
  else
    reporting_count=$((reporting_count + 1))
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

# ISS-0917 §2.2/AC3: explicit, structural invariant -- reporting_count == N
# -- checked ONCE here, independent of (in addition to) the per-partition
# has_result/partition_failed anomaly checks the loop above already does.
# ALWAYS a hard failure when it doesn't hold, regardless of what
# total_failures parsed to (the exact "1553 tests/0 failures" shape this
# issue reports, with only 5/16 partitions having actually reported).
# Printed BEFORE the combined summary line below, so this is the first
# thing visible, not something a reader has to scroll up past a
# misleadingly-clean-looking totals line to find.
if [ "$reporting_count" -ne "$N" ]; then
  echo "test_parallel: ERROR only $reporting_count/$N partitions reported a Result: line -- missing (never reported) partition(s): ${missing_partition_indices[*]}" >&2
  any_failed=1
fi

echo "---"
echo "combined: $total_tests tests, $total_properties properties, $total_failures failures ($total_passed/$total_all passed) -- $reporting_count/$N partitions reported"

# --- Step 5: exit-code contract (AC3) --------------------------------------
#
# Authoritative signal is the parsed failure count (any_failed, set above
# from failures_i and the has-Result-line check), not raw per-partition
# exit codes -- see design doc section 4.6.

exit "$any_failed"
