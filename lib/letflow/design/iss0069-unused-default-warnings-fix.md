# ISS-0069: Remove unused default values in test helpers

## Diagnosis (from ISSUE-FIXER)

`mix compile --warnings-as-errors` (or plain `mix test`) emits 4 "default values
for the optional arguments ... are never used" warnings. In each case every call
site already supplies the argument explicitly, so the `\\` default is dead code.
Same mechanical pattern as the already-resolved ISS-0044.

## Fix

Purely deletive: remove the ` \\ "<literal>"` / ` \\ %{}` default from each of
the 4 private function heads below. No call site changes — every call site
already passes the argument. No new functions, modules, or `@spec`s.

### 1. `test/letflow/engine/service_task_routing_test.exs:100`

- Before: `defp unique_idempotency_key(prefix \\ "req056-idk") do`
- After:  `defp unique_idempotency_key(prefix) do`

### 2. `test/letflow/engine/service_task_routing_test.exs:175`

- Before: `defp give_up_context(instance_id, overrides \\ %{}) do`
- After:  `defp give_up_context(instance_id, overrides) do`

### 3. `test/letflow/engine_plugin_error_routing_test.exs:128`

- Before: `defp unique_idempotency_key(prefix \\ "req057-idk") do`
- After:  `defp unique_idempotency_key(prefix) do`

### 4. `test/letflow/engine_cancel_instance_test.exs:106`

- Before: `defp unique_idempotency_key(prefix \\ "req052-idk") do`
- After:  `defp unique_idempotency_key(prefix) do`

## Function bodies

Unchanged in all 4 cases — only the argument list in the `defp` head changes.

## Invariants

- Every existing call site in these 3 test files must already pass the
  argument explicitly (confirmed during diagnosis); if ELIXIR-DEV finds a
  call site relying on the default, that call site must be updated to pass
  the value explicitly rather than restoring the default.
- No change to test behavior/assertions — this is a warning-only cleanup.

## Open questions

None.

## Verification (ELIXIR-DEV / TEST-RUNNER)

1. `mix compile --warnings-as-errors` — must succeed with none of the 4
   "default values ... never used" warnings present.
2. `mix test test/letflow/engine/service_task_routing_test.exs test/letflow/engine_plugin_error_routing_test.exs test/letflow/engine_cancel_instance_test.exs`
   — confirm the warnings are gone from compile output and all tests pass.
3. Full `mix test` — confirm no regressions elsewhere.
