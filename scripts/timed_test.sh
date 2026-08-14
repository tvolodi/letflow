#!/bin/sh
# Times `mix compile` and `mix test` as two separate, genuinely-fresh Mix
# invocations and appends one row to docs/eval/dev-loop-timings.csv.
#
# Why this is a shell script and not a `mix letflow.timed_test` task:
# any code living under this project's lib/ (including a custom Mix
# task) only runs after Mix has already compiled lib/ to find and load
# it — confirmed empirically (see docs/status/requirement_status.yaml's
# REQ-003 history): even a one-line pass-through task that just exec'd
# this script still measured a no-op compile, because invoking `mix
# letflow.timed_test` itself forces the real compile before the task's
# body — and therefore this script — ever runs. There is no Mix task
# wrapper; this script IS the command. Run it directly so `mix compile`
# below is the first Mix invocation in the whole process tree, with
# nothing pre-compiled to hide behind.
#
# Usage: sh scripts/timed_test.sh [args passed through to `mix test`]

set -eu

csv_path="docs/eval/dev-loop-timings.csv"
csv_header="timestamp_utc,compile_ms,test_ms,total_ms,note"

now_ms() {
  # nanoseconds -> milliseconds
  date_ns=$(date +%s%N)
  echo $((date_ns / 1000000))
}

ensure_csv_exists() {
  mkdir -p "$(dirname "$csv_path")"
  if [ ! -f "$csv_path" ]; then
    printf '%s\n' "$csv_header" > "$csv_path"
  fi
}

sanitize_note() {
  # strip CR/LF, turn commas into semicolons (so a bad note can't shift
  # CSV columns), then truncate to 200 chars.
  printf '%s' "$1" | tr -d '\r\n' | tr ',' ';' | cut -c1-200
}

# --- compile phase: the first mix invocation of the whole run ---
# `set +e` around each mix call: under `set -e`, a non-zero exit here
# would abort the script immediately, skipping the CSV append below —
# we need to capture the exit code and keep going so a failing run
# still gets its row written (and still exits non-zero afterward).
compile_start=$(now_ms)
set +e
mix compile
compile_exit=$?
set -e
compile_end=$(now_ms)
compile_ms=$((compile_end - compile_start))

# --- test phase ---
test_start=$(now_ms)
set +e
mix test "$@"
test_exit=$?
set -e
test_end=$(now_ms)
test_ms=$((test_end - test_start))

total_ms=$((compile_ms + test_ms))

if [ "$compile_exit" -ne 0 ]; then
  note="compile phase exited $compile_exit"
elif [ "$test_exit" -ne 0 ]; then
  note="test phase exited $test_exit"
else
  note="ok"
fi

timestamp=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z)
safe_note=$(sanitize_note "$note")

ensure_csv_exists
printf '%s,%s,%s,%s,%s\n' "$timestamp" "$compile_ms" "$test_ms" "$total_ms" "$safe_note" >> "$csv_path"

if [ "$compile_exit" -ne 0 ]; then
  exit "$compile_exit"
elif [ "$test_exit" -ne 0 ]; then
  exit "$test_exit"
else
  exit 0
fi
