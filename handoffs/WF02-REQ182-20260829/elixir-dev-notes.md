# ELIXIR-DEV notes — WF02-REQ182-20260829

## Known, expected test failure — not fixed here (out of scope per task instructions)

`test/letflow/webhooks_test.exs`'s `describe "AC6: no route or controller
file exists for webhooks..."` test `"no router file for webhooks exists
anywhere in lib/letflow/routers"` now fails, because it asserts the
structural absence of any `lib/letflow/routers/*webhook*` file — an
assertion that was correct for REQ-181's own scope (which explicitly
excluded the route layer) and is now falsified by REQ-182 adding
`lib/letflow/routers/webhooks.ex` on purpose, as designed.

This is a real, mechanical consequence of REQ-182 landing, not a defect in
the new router. The Step 2a task instructions explicitly forbid touching
any REQ-176/177/178/181 test file, so this test was left as-is rather than
updated or deleted. TEST-DESIGNER/REVIEWER should decide how to retire or
narrow this now-obsolete assertion as part of REQ-182's own test-design
step (Step 2d) rather than have ELIXIR-DEV silently touch a
previous-requirement's test file.

Full `mix test` run result: `2504/2508 passed (5/5 properties, 2499/2503
tests), 10 excluded — Failed: 4 tests`. Of the four failures:

1. `Mix.Tasks.Letflow.CheckToolchainTest` — "a matching rust pin reports OK"
2. `Mix.Tasks.Letflow.CheckToolchainTest` — "a mismatched rust pin reports a MISMATCH row"
3. `Letflow.Engine.Wasm.PluginHandlerTest` — "AC7: the wasmex NIF is a loaded shared library"
4. `Letflow.WebhooksTest` — "no router file for webhooks exists" (described above)

Failures 1-3 are pre-existing, environment/toolchain-dependent failures
(rust pin mismatch, wasmex NIF not built in this sandbox) — unrelated to
this branch's diff, confirmed by inspecting `git diff` scope (no rust/wasm
files touched). Failure 4 is the one caused by this change, and is the
expected/designed-for consequence described above.

`mix compile --warnings-as-errors` and `mix format --check-formatted` both
pass clean.
