# ISS-0987 (Q-954 / GH#2209) -- secrets master key all-0xFF literal is dead code

Status: design for WF03-Q954-20261005. Design only. Severity MINOR. Secrets path, so
SECURITY-REVIEWER applies. No `lib/` change.

## 1. Defect (from diagnosis, handoff step 01)

`config/runtime.exs:63` rejects the trivially-guessable master key with
`secrets_master_key == <<0::256>> or secrets_master_key == <<0xFF::256>>`. `<<0xFF::256>>`
is the 256-bit integer 255 (31 zero bytes then `0xFF`), never equal to 32 bytes of `0xFF`,
so the all-0xFF refusal is dead and `LETFLOW_SECRETS_MASTER_KEY=` 64 x `f` boots. The
all-zeros half works.

## 2. Change A -- `config/runtime.exs` (literal fix only)

- Line ~63: replace the second operand `<<0xFF::256>>` with `:binary.copy(<<0xFF>>, 32)`.
  The first operand `<<0::256>>` is correct and stays.
- Nothing else changes: the pepper block (REQ-435, line ~109 already uses
  `:binary.copy(<<0xFF>>, 32)`) is not touched or refactored.
- The `raise` message text stays as is. It names the variable and the class of value
  ("all-zeros or all-0xFF") and never interpolates the key, hex string, or decoded bytes.
  Invariant: no message in this check echoes a key value (INV-4). Tests assert it.
- Sequencing: PR #2201 (Q-944) already in HEAD (`b01b785e`), so the runtime.exs edit has no
  merge-order blocker.

## 3. Change B -- docs edit to `lib/letflow/design/req190-secrets-core.md`

ELIXIR-DEV edits section 2 item 4 (line ~200). Current text says "NOT `<<0xFF::256>>`
(wrapped 32 bytes of `0xFF`, ...)", which is false. Replace the literal with
`:binary.copy(<<0xFF>>, 32)` (32 bytes of `0xFF`, i.e. the 64-char string "f" * 64) and
drop the "wrapped" wording; add a short parenthetical that `<<0xFF::256>>` is the integer
255 and must not be used. Keep the rest of the item (raw-byte comparison, not hex string)
unchanged. No other docs change.

## 4. Change C -- regression tests (`test/letflow/secrets_runtime_config_test.exs`)

Add three tests to the existing module (same `@moduletag :slow`, same `System.cmd("mix",
["run", ...])` subprocess style, `stderr_to_stdout: true`, `cd: File.cwd!()`).

Shared env for all three:
- `MIX_ENV` = `"dev"`; `MIX_TEST_PARTITION` = `nil`; `MIX_BUILD_PATH` = `nil` (same reason
  as the existing first test: inherited parallel-runner vars trip config/dev.exs ISS-0015).
- Valid pepper pair so the REQ-435 pepper check cannot mask the key check:
  `LETFLOW_LOGIN_DIRECTORY_PEPPER` = a 64-lowercase-hex value distinct from the key under
  test (e.g. 64 chars of `ab` repeated), `LETFLOW_LOGIN_DIRECTORY_PEPPER_ID` = `"p1"`.
  Put these in one module attribute/helper so the three tests share them. The diagnosis
  found that without them an all-0xFF key exits 1 on "PEPPER is missing" and a naive test
  would pass before the fix for the wrong reason.
- Run `mix run --no-start -e` printing a marker atom (e.g. `booted_past_config`) so
  acceptance is observable.

Cases:
1. All-zeros key (64 x `0`): assert exit != 0, `output =~ "trivially-guessable"`,
   `output =~ "LETFLOW_SECRETS_MASTER_KEY"`, `refute output =~ marker`, and
   `refute output =~` the 64-char key string.
2. All-0xFF key (64 x `f`): same assertions as case 1. This is the fail-first case: it
   MUST fail on the unfixed tree (exit 0, marker printed) and pass after Change A. Asserting
   the message, not merely non-zero exit, is mandatory. Note the no-echo assertion for
   64 x `f` must use the full 64-char run, not a shorter substring.
3. Valid random-looking key (fixed 64-hex string that is neither all-zeros nor all-f, and
   different from the pepper): assert exit 0 and `output =~ marker`, `refute output =~
   "trivially-guessable"`.

Update the moduledoc "spiked" list with the observed pre-fix result for case 2 (exit 0,
marker printed) as evidence.

Fail-first and mutation procedure:
- ELIXIR-DEV/TEST-DESIGNER write the tests first and run case 2 on the unfixed tree to
  record the failure (quote output), then apply Change A and re-run all three.
- Mutants (e.g. revert the literal to `<<0xFF::256>>`; drop the `or` second operand;
  change `32` to `31`) are run ONLY in a throwaway worktree, never on the working branch
  (see memory: mutation agents use `git checkout` destructively). Commit before dispatching
  any mutation agent. Expected: reverting to `<<0xFF::256>>` and dropping the operand both
  fail case 2; case 1 and 3 remain green.

## 5. Acceptance mapping

| Criterion | Element |
|---|---|
| 0xFF literal refused | Change A + test case 2 |
| Zeros still refused | unchanged operand + test case 1 |
| Valid key accepted | test case 3 |
| No key echo | message unchanged; assertions in cases 1-2 |
| Design doc corrected | Change B |
| Pepper not masking | shared pepper env in all cases |

## 6. Open questions

None. Out of scope: any pepper-block change, any `lib/` change, other weak-key patterns
(repeating bytes other than zeros/0xFF), the local ISS-0987 record on PR #2210's branch.
