# ISS-0065: write cross-VM test scripts to a temp file instead of passing them via `-e`

## Problem (ISSUE-FIXER's diagnosis, restated for design scope)

`test/support/tenant_slug_test.exs` proves ISS-0059's fix by spawning genuinely
independent BEAM VM subprocesses via `System.cmd/3` and having each print a computed
slug to stdout. Two call sites pass the script inline as a `-e` argv element:

- `describe "pre-fix mechanism collides across VM runs"` / `test "collides across
  three fresh VMs"` (~line 64-86): `System.cmd("elixir", ["-e", @old_mechanism_script])`,
  `@old_mechanism_script = "IO.write(System.unique_integer([:positive, :monotonic]))"`.
- `describe "post-fix unique_slug/1 avoids the cross-VM collision"` / `test "distinct
  slugs across three fresh VMs"` (~line 101-121, currently failing on Windows):
  `System.cmd("mix", ["run", "--no-start", "-e", script], env: [...], stderr_to_stdout:
  false)`, `script = ~s|IO.write(Letflow.TenantSlugFixture.unique_slug("req027"))|`.

Per `System.cmd/3`'s own moduledoc ("Windows argument splitting" caveat, confirmed via
`Code.fetch_docs(System)` on Elixir 1.18.3): on Windows, `mix`/`elixir` resolve to
`mix.bat`/`elixir.bat`, which run implicitly through `cmd.exe`. `cmd.exe` re-parses
argv, and `(`, `)`, `"` inside an argv element (both scripts contain these) can be
mis-split, producing `{"", 255}` and a `"...) was unexpected at this time."` error —
exactly the reported symptom. This is confirmed platform-specific: both tests pass
4/4 on this Linux host, where `mix`/`elixir` are real executables, not `.bat` files.

Fix (per ISSUE-FIXER's recommendation): write the script body to a temp `.exs` file
and invoke the subprocess with a plain file path argv element instead of `-e <script>`.
A bare path has none of the characters `cmd.exe` re-splits on, so this sidesteps the
bug on Windows regardless of `cmd.exe`'s parsing quirks, while behaving identically on
Linux (a path argv element was already safe there).

## Scope

**In scope:** `test/support/tenant_slug_test.exs` only — both call sites (see "Both
call sites change" below).

**Out of scope, explicitly:**
- `test/support/tenant_slug.ex` (the `Letflow.TenantSlugFixture` fixture under test) —
  not implicated by ISSUE-FIXER's diagnosis, not touched.
- Any file under `lib/letflow/` — this is a pure test-infrastructure fix. It does not
  touch a tenant-data path (no API route, no migration, no secret, no response
  shaping), so **SECURITY-REVIEWER's INV-1..INV-8 checklist does not apply** to this
  change. Downstream agents (REVIEWER, TEST-DESIGNER) should not route this through
  SECURITY-REVIEWER on the strength of this design — it is a test-harness-only change,
  stated explicitly here so it isn't second-guessed later.
- No change to what either test proves: both still spawn genuinely independent, fresh
  OS-process BEAM VMs (a temp file does not change process boundaries — `elixir`/`mix`
  still `File.read!/1`-then-`Code.eval_string/1` the script's own content as normal
  script execution, in a subprocess with its own VM instance), and the currently-
  failing test still asserts 3 distinct slugs from 3 subprocess invocations.

## New private helper: `write_script_and_run/2`

Added as a private function inside `Letflow.TenantSlugFixtureTest` (test/support is
not a shared cross-module location for this — the helper is only used by this one
test module, so it does not need to live in a separate `test/support/*.ex` file; a
`defp` at the bottom of the test module is the right altitude, matching how other
single-file test helpers in this codebase are scoped).

```
@spec write_script_and_run(cmd :: String.t(), script_body :: String.t()) ::
        {output :: String.t(), exit_status :: non_neg_integer()}
```

- `cmd`: the executable name to hand to `System.cmd/3` — `"elixir"` for the pre-fix
  case, `"mix"` for the post-fix case. The function is shared between both call sites;
  each passes its own `cmd` and script body.
- `script_body`: the literal Elixir source to execute (today's `@old_mechanism_script`
  string, or today's `script` string) — unchanged content, just no longer passed via
  `-e`.
- Returns exactly what `System.cmd/3` returns today (`{output, exit_status}`) — callers
  keep their existing `{output, 0} = write_script_and_run(...)` match-assertion
  pattern unchanged, so no assertion-shape change ripples into the test bodies beyond
  the call itself.
- Internally: writes `script_body` to a fresh temp `.exs` path (see "Temp file
  uniqueness" below), invokes the subprocess with that path as a plain argv element
  (no `-e` flag) appended to `cmd`-appropriate args, and guarantees the temp file is
  removed before returning or raising (see "Cleanup semantics" below).

### Per-call-site invocation shape

- `elixir` call site: `cmd = "elixir"`, subprocess args become `[path]` — i.e.
  `System.cmd("elixir", [path])`, replacing today's `["-e", @old_mechanism_script]`.
  `elixir <path>.exs` runs a script file exactly the same way `elixir -e <string>`
  runs an inline string — same semantics, same fresh-VM-per-invocation behavior, only
  the argv shape differs.
- `mix` call site: `cmd = "mix"`, subprocess args become `["run", "--no-start", path]`
  — i.e. `System.cmd("mix", ["run", "--no-start", path], env: [{"MIX_ENV", "test"}],
  stderr_to_stdout: false)`, replacing today's `["run", "--no-start", "-e", script]`.
  `mix run --no-start <path>` loads and executes the file exactly as `mix run
  --no-start -e <string>` would evaluate the string — `Letflow.TenantSlugFixture` is
  still reachable because `mix run` still compiles/loads the project's code path
  first, same as today; only the "where does the code to execute come from" mechanism
  changes (file vs. inline string).

Both call sites keep their existing `env:`/`stderr_to_stdout:` options exactly as
today; `write_script_and_run/2` takes only `cmd` and `script_body` as parameters
because those are the only two things that differ between the two call sites — the
option keywords stay literal at each call site (not threaded through the helper) so
the diff stays minimal and each call site's existing options remain visibly unchanged
in place, rather than being hidden behind an opts passthrough.

**Decided: `write_script_and_run/2` stays 2-arity, no `opts` param.** Nothing in
ISS-0065's scope needs a third parameter — only two call sites exist, one has no
extra options at all (`elixir`, plain `System.cmd(cmd, args)`) and the other has a
fixed, never-varying pair (`env: [{"MIX_ENV", "test"}], stderr_to_stdout: false`) that
this design already places literally at that call site, appended to the helper's
return value's containing expression rather than threaded through it. Adding an
`opts` passthrough would only be justified by a third call site or a call site whose
options vary at runtime — neither exists here, so YAGNI applies. ELIXIR-DEV must
implement exactly `write_script_and_run(cmd, script_body)` — this is not a judgment
call left open for the implementer.

## Temp file uniqueness under `async: true` / concurrent test processes

The module is `async: true`, and the two affected tests (or repeated runs of the
`:slow`-tagged one, or a future third test reusing the helper) could run in
overlapping test processes within the same `mix test` invocation, each calling
`write_script_and_run/2` concurrently. Path collision must be avoided within that
single run (per the task framing, cross-host filesystem sharing is explicitly not a
concern — only concurrent test *processes* within one run).

- Base directory: `System.tmp_dir!/0` (the OS temp dir — `/tmp` on Linux, `%TEMP%` on
  Windows via Erlang's own OS-appropriate resolution, no hardcoded path).
- Filename: `"letflow_iss0065_#{System.unique_integer([:positive, :monotonic])}_#{:erlang.unique_integer([:positive])}.exs"`
  — two independent uniqueness sources combined defensively:
  - `System.unique_integer([:positive, :monotonic])` is unique within this one VM
    (the `mix test` runner's own VM, not the spawned subprocess's VM — no relation to
    the cross-VM-collision bug ISS-0059/this test file is about; this counter never
    leaves the parent process) and monotonically increasing, so two calls in the same
    test process in immediate succession never collide.
  - A second `:erlang.unique_integer([:positive])` call adds independent entropy in
    case of any future refactor that parallelizes calls across processes in a way
    that could otherwise interleave the first counter's values unexpectedly (defense
    in depth — the first counter alone is already sufficient for `System`'s own
    documented per-VM uniqueness guarantee, so this is redundancy, not a requirement
    dictated by a known gap).
  - Rationale for not using `System.unique_integer/1` alone plus e.g. the test PID:
    a bare monotonic integer is already collision-proof per-VM by its own contract;
    the second term exists only to make the filename visibly distinguishable in
    `/tmp` during manual debugging (e.g. if two runs' temp files ever needed to be
    told apart by eye), not because a real collision risk exists.
- Full path: `Path.join(System.tmp_dir!(), filename)`.
- `.exs` extension is kept (matches Elixir script-file convention; not required by
  `elixir`/`mix run` — either would execute a file with any extension — but keeps the
  temp artifact self-describing if a cleanup failure ever left one behind).

This scheme requires no locking: each call computes its own filename from two
independent counters before any I/O, so two concurrent calls (in this VM) always
compute two different filenames before either touches the filesystem — no
check-then-write race.

## Cleanup semantics

Must not leak the temp file even if the subprocess raises, the `File.write!/2` call
itself fails partway, or the `{output, 0}` match in the caller's test body fails after
`write_script_and_run/2` returns.

- `write_script_and_run/2` wraps the "run the subprocess" step (not the initial
  `File.write!/2`, which either fully succeeds or raises before any file exists to
  clean up) in a `try/after`:
  - `after` clause: `File.rm(path)` — note `rm/1` (not `rm!/1`) inside the `after`,
    so that if the file was somehow already gone (e.g. an external cleanup, or the
    write itself never completed) the cleanup step doesn't itself raise and mask the
    original error/result.
  - The `try` body runs `System.cmd/3` and returns its `{output, exit_status}` tuple
    as the `try`'s value; a raise inside `System.cmd/3` (e.g. `:enoent` if `cmd`
    somehow isn't on `PATH`) still triggers the `after` clause before the exception
    propagates to the caller, so no leak on that path either.
  - This deliberately does NOT rely on `ExUnit.Callbacks.on_exit/1` — `on_exit` runs
    once per *test*, but `write_script_and_run/2` is called up to 3 times per test
    (the `for _ <- 1..3 do ... end` loop in each test body), each with its own fresh
    temp file that should be removed right after that specific subprocess call
    finishes, not batched to end-of-test. Immediate per-call cleanup via `try/after`
    is both simpler and tighter than accumulating 3 paths in an `on_exit` closure.
  - If the eventual `{output, 0} = write_script_and_run(...)` match fails in the
    caller (`MatchError` on a non-zero exit status), the temp file is already gone by
    then — cleanup happened inside the helper before it returned, not conditional on
    what the caller does with the return value.

## Both call sites change

**Decision: yes, both the `elixir -e` (pre-fix-mechanism) call site and the `mix run
--no-start -e` (post-fix, currently-failing) call site move to
`write_script_and_run/2`.**

Reasoning:
- The `elixir -e` call site's own script (`"IO.write(System.unique_integer([:positive,
  :monotonic]))"`) contains the same class of characters (`(`, `)`) that trigger
  `cmd.exe`'s re-parsing bug on Windows. It is not the call site ISS-0065 reported as
  failing, and it is confirmed passing on this Linux host — but per `System.cmd/3`'s
  own documented Windows caveat, `elixir.bat` is exactly as exposed to this failure
  mode as `mix.bat` is. Leaving it on `-e` is leaving a second, currently-dormant
  instance of the identical bug in the same file, that would only surface as its own
  future issue report the next time this suite runs on a Windows host.
- Both call sites already share near-identical shape (`System.cmd(<cmd>, [...,"-e",
  <script>])` → `{output, exit_status}` destructured the same way), so one shared
  helper serving both is not a stretch — it is the natural common factor, and fixing
  both in the same pass costs no extra design complexity (same helper, same temp-file
  scheme, same cleanup) versus fixing one and leaving the other as a known landmine.
- Counter-consideration (stated for completeness, not followed): one could argue for
  minimal-diff-only-on-the-reported-line to keep this fix narrowly scoped to what
  ISS-0065 reported. Rejected here because ISSUE-FIXER's own diagnosis explicitly
  flagged the `elixir -e` site's latent risk and asked this design to decide — leaving
  a known-identical bug unfixed one call site away, when the fix is the same helper
  either way, would just relocate the next Windows failure report rather than close
  the issue's actual root cause (inline `-e` scripts with special characters, not
  "the `mix` call site specifically").

## Acceptance criteria (for TEST-DESIGNER / TEST-RUNNER)

1. Both tests still spawn genuinely independent, fresh OS-process BEAM VM subprocesses
   per iteration of their `for _ <- 1..3 do ... end` loop — `write_script_and_run/2`
   must not memoize, cache, or otherwise short-circuit repeat calls; each call writes
   its own temp file and starts its own `System.cmd/3` subprocess exactly as today's
   inline calls do.
2. `test "collides across three fresh VMs"` still asserts the pre-fix mechanism
   produces 3 identical slugs (`Enum.uniq(slugs) == [hd(slugs)]`) — assertion content
   unchanged, only the subprocess invocation mechanism changes.
3. `test "distinct slugs across three fresh VMs"` still asserts the post-fix mechanism
   produces 3 distinct slugs (`length(Enum.uniq(results)) == 3`) and that each result
   has the `"req027-"` prefix — assertion content unchanged.
4. `mix test test/support/tenant_slug_test.exs --include slow` passes on this Linux
   host after the change (re-run and confirm actual output — do not assume from the
   design alone).
5. No temp file is left behind in `System.tmp_dir!/0` after a full test run — this can
   be checked by listing `System.tmp_dir!/0` for `letflow_iss0065_*` entries
   immediately before and after the run and confirming the set is unchanged (empty
   diff), including after deliberately forcing a failing-subprocess case if
   TEST-DESIGNER wants an explicit negative-path check (not required, since the
   `try/after` cleanup is unconditional on success/failure by construction — see
   "Cleanup semantics" above).
6. **Windows execution cannot be directly verified from this host** — no Windows
   machine is available in this environment. The acceptance bar for the Windows half
   of this fix is "correct per `System.cmd/3`'s own documented Windows argument-
   splitting behavior" (a bare file-path argv element has none of the characters that
   trigger `cmd.exe` re-parsing, per that documentation) plus "still passes on Linux"
   (criterion 4) — not "verified passing on an actual Windows machine." Do not report
   this fix as Windows-verified; report it as Windows-correct-per-documentation and
   Linux-verified, which is the honest and achievable bar from this host.
7. No change to `test/support/tenant_slug.ex` or any file under `lib/letflow/` (see
   Scope above) — a diff touching either is out of this fix's scope and should be
   flagged, not merged as part of ISS-0065.

## Invariants

- `write_script_and_run/2`'s temp-file mechanism never changes the *content* of either
  script — `@old_mechanism_script` and `script` (the `unique_slug("req027")` call)
  are written to the temp file byte-for-byte as today's `-e` argument, so the code
  actually executed by each subprocess is unchanged.
- The helper does not introduce any new dependency on `:ecto`/the application being
  started in the parent (`mix test`) process — it only performs `File.write!/2`,
  `System.cmd/3`, and `File.rm/1`, all of which the test module already effectively
  depends on transitively via `ExUnit`/`Elixir` stdlib.
- No assertion in either test inspects the temp file path or its existence — the path
  is purely an internal plumbing detail of `write_script_and_run/2`, not part of
  either test's observable behavior.
