# Design — ISS-0106: toolchain pin, drift warning, reformat, struct-update fix

Run: `WF03-ISS0106-20260821`, step 2 (CODE-DESIGNER).

**Authority.** This design implements, and only implements, the section
*"Scope for the implementation (ordered; for CODE-DESIGNER)"* of
`docs/migration/decisions/0005-pin-formatting-toolchain.md`'s **amendment**
(dated `2026-08-21T01:25:50Z`), which supersedes the 2026-08-19 sign-off in
that same file **on the version target only**. Where this document and that
record disagree, the record wins (`core-directives.md`, Instruction
Precedence: a `docs/migration/decisions/` record is never overridden).

**Out of scope, deliberately, and not a gap in this design:**

- The "One finding this decision does not fix" item (three commits merging
  past a red format gate on 2026-08-20). ORCH filed it as ISS-0110 / GH#363 /
  queue task 177.
- The issue-record bookkeeping the amendment assigns to ORCH/DOC-UPDATER
  (superseding `docs/issues/ISS-0106.yaml`'s wrong Symptom-1 root cause;
  the addendum to `docs/issues/ISS-0046.yaml`'s UNCONFIRMED version
  attribution).
- Adding CI (`.github/workflows`). Decision 0005 defers it explicitly.
- Promotion of the new check from warning to hard failure. The amendment
  defers it with a stated trigger and assigns the follow-on filing to ORCH.

---

## 0. Measurements this design rests on

All taken on this host, on branch `feature/WF03-ISS0106-20260821`, during
step 2. Re-derived rather than inherited from step 1's handoff, per
`docs/anti-patterns.md`'s "Inheriting a claim from a record instead of
re-deriving it from the source".

| M# | Measurement | Result |
|---|---|---|
| M1 | `mix format --check-formatted` | exit 1, exactly 4 files (§3.1) |
| M2 | `mix compile --force` warning grep | exactly **14** `is expected on struct update` warnings, no other warning class |
| M3 | `System.version()` | `"1.20.3"` |
| M4 | `:erlang.system_info(:otp_release)` | `~c"29"` (charlist), `List.to_string/1` → `"29"` |
| M5 | `mix compile --warnings-as-errors` with the project **already compiled** and nothing to recompile | **exit 1**, all 14 warnings re-emitted from the compile manifest |

M5 is load-bearing for §2.7 and is the reason property (iii) survives the
alias-ordering side effect described there. It was measured, not assumed.

---

## 1. Part relationships and ordering (AC9)

Three parts. Per the amendment: **only Part A was blocked on the sign-off;
Parts B and C were always independent and may proceed in parallel.**

- **Part B** (reformat 4 files) and **Part C** (14 struct-update sites) are
  independent of Part A and of each other. Either may land first, in any
  order, in the same commit or in separate ones. Neither depends on the pin
  moving: step 1 measured that all four files are unformatted under Elixir
  1.18.3 as well as 1.20.3, and that the Part-C idiom compiles and formats
  clean under both.
- **Part A** is the only part gated on the amendment.
- **One ordering constraint exists, and only one:** the run cannot be
  declared green until **all three** are done, because `mix letflow.check`
  is a single command whose exit code aggregates them. B fixes the
  `format --check-formatted` step; C fixes the
  `compile --warnings-as-errors` step; A's new first step never affects
  either exit code (§2.7).
- Part A items **1 and 4 must land together in the same commit.** Item 4
  makes the alias reference `letflow.check_toolchain`, which is meaningless
  without item 3, and item 3 warns falsely without item 1 (the file on disk
  today pins 1.18.3/OTP 27, which this host does not run). Landing item 4
  before item 3 makes `mix letflow.check` fail with an unknown-task error.
  **A3 → A1 → A4** within Part A; A2 is a no-op; A5, A6, A7 are docs and
  are order-free.

---

## 2. Part A — pin and enforcement

### A1. `.tool-versions` (AC2)

The exact post-change content of the repo-root `.tool-versions`, character
for character — two lines, lowercase tool names, single space separators,
trailing newline after the second line, no leading/trailing blank lines, no
comments, LF line endings:

```
elixir 1.20.3-otp-29
erlang 29.0.5
```

Current content (to be replaced in full): `elixir 1.18.3-otp-27` /
`erlang 27.2`.

Token provenance, from the amendment: `29.0.5` is the full Erlang version
read from the Erlang installation's `OTP_VERSION` file, because asdf's
`erlang` plugin wants a full version. `erts` 17.0.5 is recorded in the
decision record for identification and is **not** pinned and **not**
written to this file.

### A2. `mix.exs` line 8 — DO NOT CHANGE (AC1)

`mix.exs:8` currently reads:

```
      elixir: "~> 1.18",
```

**Instruction to the implementer: leave this line exactly as it is. Do not
edit it. Do not "tidy" it into agreement with `.tool-versions`.**

Why this is listed as a work item even though it is a no-op: an implementer
who sees `.tool-versions` pinning 1.20.3 next to a `~> 1.18` requirement
will read the mismatch as an oversight and tighten it. That is the exact
change the amendment **REJECTS** (its constraint 2). Measured semantics
from the amendment: `~> 1.18` means `>= 1.18.0 and < 2.0.0`, whereas
`~> 1.18.0` means `>= 1.18.0 and < 1.19.0`. Tightening to `~> 1.18.0` would
make **this host — the only host confirmed live — unable to compile Letflow
at all**, and would lock any surviving 1.18.3 host out of running its own
test gate. The requirement is deliberately *wider* than the pin so that no
host is locked out by the pin moving. An off-pin host is **warned, never
blocked**.

Any future run that proposes narrowing this line must go through REVIEWER
sign-off, not through a "consistency" cleanup.

### A3. `lib/mix/tasks/letflow.check_toolchain.ex` (new) — full specification (AC3)

This is the only genuinely new code in this run.

#### A3.1 Module surface

| Item | Value |
|---|---|
| File | `lib/mix/tasks/letflow.check_toolchain.ex` |
| Module | `Mix.Tasks.Letflow.CheckToolchain` |
| Behaviour | `Mix.Task` (via `use Mix.Task`; `run/1` carries `@impl Mix.Task`) |
| Invoked as | `mix letflow.check_toolchain` |
| `@shortdoc` | `"Warns (never fails) when the running Elixir/OTP differs from .tool-versions"` |
| `@moduledoc` | Required. Must state: the four properties (i)–(iv) below and the mechanism for each; that this task is advisory and cannot fail a build; the OTP major-vs-full asymmetry and its reason; a pointer to `docs/migration/decisions/0005-pin-formatting-toolchain.md`. |
| Signature | `@spec run([String.t()]) :: :ok` |
| Return | **Always `:ok`.** Every path, including every failure path. |
| Arguments | Accepted and **ignored entirely**. No `OptionParser`, no `@switches`, no positional handling. |
| Recursion | Default (`@recursive` not set). |

The module name → task name mapping follows Mix's own
`Mix.Utils.underscore` rule and matches the in-repo precedent
`Mix.Tasks.Letflow.Check.Test` → `letflow.check.test`
(`lib/mix/tasks/letflow.check.test.ex`).

#### A3.2 File lookup and path resolution

- Working directory is obtained with **`File.cwd/0`** (the non-raising
  form), never `File.cwd!/0`. `File.cwd!/0` can raise on a permission or
  deleted-directory error and would violate property (iii).
- The target path is `.tool-versions` joined onto that directory.
- **Why this is correct:** Mix loads `mix.exs` from the current working
  directory; it does not search parent directories. If Mix has a project
  loaded at all — which it must have, since `letflow.check` is an alias
  defined in `mix.exs` and this task is compiled out of this project's own
  `lib/` — then the current working directory *is* the project root. This
  is the only supported invocation, per the amendment.
- **What happens otherwise:** if `File.cwd/0` returns `{:error, reason}`,
  the task emits failure-mode F7 (§A3.7) and returns `:ok`. If the working
  directory somehow is not the project root, `.tool-versions` is simply not
  found there and the task emits failure-mode F1. Neither path raises.
- `Mix.Project.project_file/0` is deliberately **not** used: it raises
  `Mix.NoProjectError` when no project is loaded, which is a raising API in
  a task that must never raise.

#### A3.3 Parse contract for `.tool-versions`

The file is read with **`File.read/1`** (returns `{:ok, binary}` /
`{:error, posix}`; never raises). On `{:ok, binary}`:

1. Split into lines on `\n`, then strip a trailing `\r` from each line.
   **CRLF must be handled** — this repo is developed on Windows hosts and a
   `\r` left on the end of `29.0.5` would produce a permanent false
   mismatch, which is precisely the outcome property (ii) makes expensive.
2. For each line, in file order:
   - Discard everything from the first `#` onward (asdf comment syntax).
   - Trim leading and trailing whitespace from what remains.
   - If the remainder is the empty string, **skip the line silently**
     (this covers blank lines and comment-only lines).
   - Otherwise split the remainder on runs of whitespace into tokens.
   - Token 1 is the tool name; token 2, if present, is the version.
3. **Recognised tool names: `elixir` and `erlang`, exact and lowercase, and
   nothing else.** Any other tool name (`nodejs`, `python`, …) is ignored
   **silently** — no warning, no message. `.tool-versions` is a general
   asdf file and other tools' lines are legitimate content, not errors.
4. A recognised tool name with **no** token 2 is a **malformed recognised
   line**: that tool is treated as having **no pin**, and the raw line is
   quoted in the warning (failure-mode F5).
5. Tokens after token 2 (asdf permits several fallback versions on one
   line) are **ignored silently**; only token 2 is used.
6. If the same recognised tool appears on more than one line, the **first
   occurrence wins**, matching asdf's own resolution; later ones are
   ignored silently.

The result of parsing is exactly two optional values:
`elixir_pin :: String.t() | nil` and `erlang_pin :: String.t() | nil`.

**"Unparseable" is defined concretely as: the file could not be read at
all** (F1/F6). Once read, the parse is **total** — every possible byte
sequence maps to some `{elixir_pin, erlang_pin}` pair, with `nil` standing
for absent-or-malformed. There is no third "parse error" outcome, and no
step in this contract can raise. This is the mechanism behind property (iv)
(§A3.6).

#### A3.4 Comparison rule — Elixir

- The pinned token has the shape `<version>[-otp-<major>]`, e.g.
  `1.20.3-otp-29`.
- Split the token on the literal `"-otp-"`, into at most 2 parts. Part 1 is
  the **expected Elixir version**; part 2, if present, is the **OTP-build
  suffix**.
- **The `-otp-NN` suffix does NOT participate in the OTP comparison, and is
  not compared to anything at all.** It is parsed off and discarded (it may
  be shown in the warning for context, but is never a mismatch source).
  Reason: the suffix names the OTP major that *asdf's Elixir build* was
  compiled against — a property of how the Elixir artefact was built, not a
  statement about the runtime. The authoritative OTP expectation is the
  `erlang` line. Comparing both would produce two independent OTP verdicts
  that can disagree, and there is no rule for which one wins.
- If the token contains no `-otp-`, the whole token is the expected Elixir
  version and no suffix is derived.
- **Match iff** the expected Elixir version equals `System.version()` by
  exact binary equality. `System.version()` returns `"1.20.3"` (M3) — a
  bare `MAJOR.MINOR.PATCH` string with no suffix, which is why plain string
  equality is correct here and no `Version` parsing is needed.
- `Version.match?/2` is deliberately **not** used: the pin is an exact
  version, not a requirement, and `Version.parse!/1` raises.

#### A3.5 Comparison rule — OTP (the asymmetry, resolved explicitly)

**The trap.** `.tool-versions` pins a *full* Erlang version (`29.0.5`)
because asdf needs one, but `:erlang.system_info(:otp_release)` returns
only the **major release**, as a **charlist** — measured on this host as
`~c"29"` (M4). A naive equality check between `"29.0.5"` and `"29"` would
report a mismatch on a correctly-pinned host, permanently, on every single
`mix letflow.check` run. Because property (ii) makes the warning
unsuppressible, a false positive here is not a cosmetic bug: it trains
every reader to ignore the one message the whole enforcement mechanism
consists of. It must not happen.

**The rule:**

1. Running value: `:erlang.system_info(:otp_release)` returns a charlist;
   convert with `List.to_string/1` to get e.g. `"29"`. This call cannot
   fail and cannot return `nil`.
2. Expected value: take the pinned `erlang` token and keep only the
   substring **before the first `.`** — its major component. `"29.0.5"` →
   `"29"`. A token with no `.` (e.g. `"29"`) yields itself.
3. **Match iff** those two strings are equal by exact binary equality.
4. The minor and patch of the `erlang` pin (`.0.5`) are **retained for
   display in the warning and for asdf's benefit, but are never compared.**

**Accepted, documented limitation:** a host running OTP 29.0.1 while the
pin says 29.0.5 is **not** warned, because `otp_release` cannot distinguish
them. This is deliberate. The full running OTP version is only obtainable
by reading `<:code.root_dir()>/releases/<rel>/OTP_VERSION` from disk, which
is absent in stripped/embedded installs and would reintroduce a filesystem
failure path into a task that must never fail; and the amendment names
`:erlang.system_info(:otp_release)` as the API to compare against, which is
binding. Major-release granularity is also what actually matters for the
failure this record exists to prevent (formatter and type-checker
behaviour), which tracks the Elixir version and the OTP major, not the OTP
patch. **This limitation must be stated in the `@moduledoc`** so no later
run "fixes" it by tightening the comparison into a permanent false
mismatch.

#### A3.6 The four load-bearing properties, each with its mechanism (AC4)

**(i) Runs first in the alias — mechanism.** The task is the literal first
element of the `letflow.check` alias list in `mix.exs` (§A4). Mix aliases
execute their steps in list order, so nothing else can print before it.
There is no ordering logic inside the task itself; ordering is a property
of the alias data, which is the only place it can be enforced.

**(ii) Prints on mismatch regardless of later checks, and is not
suppressible — mechanism.** Three things together, all structural:

- *Independent of later checks:* the task runs before them, does not
  invoke them, does not inspect their results, and returns before they
  start. Its decision to print depends only on `System.version()`,
  `:erlang.system_info(:otp_release)` and the file contents.
- *Not silenceable by Mix:* output goes to **`:stderr` via
  `IO.puts(:stderr, …)`**, **not** via `Mix.shell()`. This is the specific
  mechanism, and it matters because `Mix.shell()` is globally replaceable
  (`Mix.shell(Mix.Shell.Quiet)`) and honours `--quiet`/`MIX_QUIET`; a
  caller who does either would silence a `Mix.shell().info/1` warning.
  `IO.puts(:stderr, …)` bypasses Mix's shell entirely. Choosing stderr also
  means the warning survives a caller that pipes stdout into `grep`/`tee`,
  which is how agents commonly read gate output.
- *No suppression surface exists to use:* the task reads **no** environment
  variable and parses **no** command-line switch. `run/1` ignores its
  argument list by construction (§A3.1). There is no flag to pass and no
  variable to set, so non-suppressibility is an absence of mechanism rather
  than a promise about behaviour. **The implementer must not add one**, and
  the `@moduledoc` must say so.

**(iii) Never changes any other check's exit code — mechanism.** A Mix
alias aborts at the first step that raises; a step's *return value* is
otherwise ignored. So the only way this task could influence the run's exit
code is by raising or halting. It cannot, because:

- `run/1` contains **no** call to `Mix.raise/1`, `raise/1`, `throw/1`,
  `exit/1`, `System.halt/1`, or `System.stop/1`. This is a hard review
  criterion: their absence is checkable by grep on the finished file, and
  their presence is a defect regardless of the surrounding logic.
- Every external call on the path uses a non-raising form: `File.cwd/0`
  not `File.cwd!/0`; `File.read/1` not `File.read!/1`; string splitting
  rather than `Version.parse!/1` or `String.to_integer/1`.
- The **entire body of `run/1` is additionally guarded** so that any
  unforeseen exception is caught, reported as failure-mode F8, and
  converted into `:ok`. This is belt-and-braces on top of the two points
  above, and it is what makes "never fails the build" a property of the
  design rather than a consequence of having thought of every error.
- It **cannot make a failing build look passing** either: it does not wrap,
  invoke, retry or intercept any other alias step, and it never touches
  another task's exit status. It is a separate, earlier, side-effect-only
  step whose only output is text on stderr. Its power is strictly to *say
  more* (decision 0005 amendment, constraint 3).
- **Measured corroboration for the one non-obvious risk (M5).** Because
  this task lives in `lib/mix/tasks/`, Mix must load its module before it
  can run it, which forces a project compile as the first thing
  `mix letflow.check` does (this is the "task-discovery-forces-compile"
  effect the existing comment at `mix.exs:49-55` describes). The hazard
  that raises is: if the project is already compiled by then, does the
  later `compile --warnings-as-errors` step still fail on the 14 warnings,
  or does it find nothing to recompile and silently pass? **Measured: it
  still fails, exit 1, with all warnings re-emitted from the compile
  manifest** (M5). So the forced compile does not weaken the
  warnings-as-errors gate. This must be re-verified after implementation
  (§4, V4) rather than taken on this document's word.
- Consequence to be aware of, not a defect: `mix letflow.check` now
  compiles before it format-checks. If compilation fails outright, the
  toolchain warning may not print at all — recorded as open question OQ1
  (§5).

**(iv) Degrades gracefully — mechanism.** The parse is total (§A3.3): every
readable byte sequence yields a `{elixir_pin, erlang_pin}` pair with `nil`
for absent-or-malformed, so there is no error branch to fall off. The only
genuinely failing operations — obtaining the cwd and reading the file —
use non-raising APIs whose `{:error, _}` results are named failure modes
(F1, F6, F7) with their own messages. The outer guard on `run/1` catches
anything unforeseen (F8). Every one of these paths **warns and returns
`:ok`**.

#### A3.7 Output specification — exact text shapes (AC3, AC5)

All warning output goes to **`:stderr`**. The success line goes to
**`:stdout`**. Every message begins with the literal prefix
`letflow.check_toolchain:` so it is greppable and cannot be mistaken for a
format diff or a compiler warning.

**No-mismatch behaviour** — exactly one line, to stdout, then `:ok`:

```
letflow.check_toolchain: OK -- Elixir 1.20.3 / OTP 29 matches .tool-versions.
```

(A line is printed rather than nothing, so that a reader can tell the check
ran at all. It is a single line and does not bury the checks that follow.)

**Mismatch** — one block to stderr. The block is emitted **iff at least one
of the two comparisons mismatches**, and when emitted it always contains
**both** the Elixir and the OTP line, so a reader never has to infer which
comparison was silent. A comparison that matched reads `matches`; one that
did not is suffixed `<-- MISMATCH`. Rule lines are exactly 72 `=`
characters.

```
========================================================================
letflow.check_toolchain: TOOLCHAIN OFF PIN
  Elixir  expected 1.20.3   running 1.18.3   <-- MISMATCH
  OTP     expected 29 (from erlang 29.0.5)   running 27   <-- MISMATCH
  Pin file: .tool-versions
  Record:   docs/migration/decisions/0005-pin-formatting-toolchain.md
  This is a WARNING. It does NOT fail the build and never changes an
  exit code. Formatting or compiler output produced by an off-pin
  toolchain may disagree with the pin.
========================================================================
```

Constraints on the block that are load-bearing rather than cosmetic:

- **Both the expected and the running version must be named on each line.**
  The amendment requires it, and it is what makes the warning actionable
  instead of merely alarming.
- The OTP line must show **both** the compared major (`29`) and the full
  pinned token it came from (`from erlang 29.0.5`), so a reader can see for
  themselves that patch components are not being compared and does not file
  the asymmetry of §A3.5 as a bug.
- The "does NOT fail the build" sentence must be present verbatim in
  substance. Without it, a reader who sees a loud red-looking block above a
  red gate will misattribute the gate's failure to this check — which is
  the same misattribution failure ISS-0106 was filed over.

**Failure-mode messages** (AC5). Every one of these **warns and continues**;
none can raise; all return `:ok`; all go to stderr in the same block frame,
with the `TOOLCHAIN OFF PIN` title line replaced by
`TOOLCHAIN PIN NOT CHECKED` where no comparison could be made at all.

| F# | Condition | Behaviour |
|---|---|---|
| F1 | `.tool-versions` **missing** (`File.read/1` → `{:error, :enoent}`) | `TOOLCHAIN PIN NOT CHECKED` block; body line: `.tool-versions not found at <absolute path> -- cannot check the toolchain pin.` Plus a line naming the running versions: `Running: Elixir 1.20.3 / OTP 29`. No comparison performed. Returns `:ok`. |
| F2 | present but **empty** (zero bytes), or only blank/comment lines | `TOOLCHAIN PIN NOT CHECKED` block; body: `.tool-versions contains no elixir pin and no erlang pin.` Plus the `Running:` line. Returns `:ok`. |
| F3 | present, **no `elixir` line** (erlang line present) | `TOOLCHAIN OFF PIN` block. Elixir line reads `Elixir  expected (no elixir pin in .tool-versions)   running 1.20.3   <-- NOT PINNED`. OTP line is compared and rendered normally. The block is emitted even if the OTP comparison matched. Returns `:ok`. |
| F4 | present, **no `erlang` line** (elixir line present) | Symmetric to F3: `OTP     expected (no erlang pin in .tool-versions)   running 29   <-- NOT PINNED`; Elixir compared normally; block emitted regardless. Returns `:ok`. |
| F5 | **malformed recognised line** — a line whose first token is `elixir` or `erlang` with no second token | That tool is treated as unpinned, so the F3 or F4 line shape applies, **plus** one extra body line quoting the raw line verbatim: `Malformed line in .tool-versions, ignored: <raw line>`. Returns `:ok`. |
| F6 | present but **unreadable** (`File.read/1` → any `{:error, reason}` other than `:enoent`, e.g. `:eacces`, `:eisdir`) | `TOOLCHAIN PIN NOT CHECKED` block; body: `Could not read .tool-versions (<reason>) -- cannot check the toolchain pin.` Plus the `Running:` line. Returns `:ok`. |
| F7 | **working directory unavailable** (`File.cwd/0` → `{:error, reason}`) | `TOOLCHAIN PIN NOT CHECKED` block; body: `Could not determine the project directory (<reason>) -- cannot check the toolchain pin.` Plus the `Running:` line. Returns `:ok`. |
| F8 | **any unforeseen exception** anywhere in `run/1` | Caught by the outer guard. `TOOLCHAIN PIN NOT CHECKED` block; body: `Internal error in letflow.check_toolchain (<inspected exception>) -- check skipped. This never fails the build.` Returns `:ok`. |

**"A version string that does not parse" is not a failure mode, by
construction, and this is deliberate.** Both comparisons are exact string
equality on strings derived by splitting (§A3.4, §A3.5); no numeric or
`Version` parsing occurs anywhere. So `elixir abc` simply produces
`expected abc   running 1.20.3   <-- MISMATCH`, and `erlang -` produces
`expected  (from erlang -)   running 29   <-- MISMATCH`. Both are ordinary
mismatches, both warn, neither raises. Removing the parse step is what
removes the parse-failure path.

**Confirmation required by AC5: none of F1–F8, and no comparison outcome,
can raise.** The mechanisms are enumerated in §A3.6(iii)/(iv) —
non-raising APIs only, a total parse, no `Mix.raise/1`, and an outer guard.

### A4. `mix.exs` alias — exact resulting list (AC8)

`mix.exs`'s `aliases/0` currently defines (lines 56-60):

```
      "letflow.check": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "letflow.check.test"
      ]
```

After this change it must read, in exactly this order, with the new entry
**first** and the three existing entries unchanged in content and in their
relative order:

```
      "letflow.check": [
        "letflow.check_toolchain",
        "format --check-formatted",
        "compile --warnings-as-errors",
        "letflow.check.test"
      ]
```

No other alias in `aliases/0` changes. `cli/0`'s
`preferred_envs: ["letflow.check": :test]` is unchanged, so the new task
runs under `MIX_ENV=test` like the rest of the alias; nothing in its
specification is environment-dependent.

The existing explanatory comment above the alias (`mix.exs:49-55`, about
REQ-003's task-discovery-forces-compile problem) is now partly outdated,
because the alias *does* gain a `lib/mix/tasks/` task as its first step.
**Update that comment** to record that the first step is such a task, that
this forces a project compile before the format check, and that M5/V4
measured that the later `compile --warnings-as-errors` step still fails on
cached warnings and is therefore not weakened by it.

### A5. `README.md` Notes

Replace the pinned-toolchain bullet at `README.md:149-158`. It must, after
the change:

1. Name **Elixir 1.20.3 / OTP 29** as the pin and point at
   `docs/migration/decisions/0005-pin-formatting-toolchain.md`.
2. **Delete the false claim** that `mix.exs`'s `elixir: "~> 1.18"` "accepts
   any 1.18.x patch". The amendment measured this to be wrong. Replace it
   with the measured semantics: `~> 1.18` means `>= 1.18.0 and < 2.0.0`,
   i.e. it admits 1.19, 1.20 and 1.21.
3. State **why the requirement is deliberately wider than the pin**: so
   that an off-pin host is warned, never blocked — it still compiles, still
   runs the full gate, and still gets an exit code that reflects the code
   rather than the toolchain (amendment, constraint 2).
4. Mention that `mix letflow.check` now warns on an off-pin toolchain via
   `letflow.check_toolchain`, and that the warning is advisory and never
   changes an exit code.

The surrounding `.env`/`mix deps.get` bullets are untouched.

### A6. `docs/guides/backend_developer_guide.md:17`

Currently:

```
- Elixir 1.17+ / OTP 26+ (the project was scaffolded on 1.14/OTP 25 via apt; nothing
  depends on that specific version — see `README.md`'s Notes)
```

Replace with a bullet stating the pin (Elixir 1.20.3 / OTP 29 via
`.tool-versions`), pointing at decision 0005, and noting that an off-pin
host is warned by `mix letflow.check` rather than blocked. The "nothing
depends on that specific version" clause must not survive — it is exactly
the belief this decision record exists to overturn. Decision 0005's option
(b) named this guide explicitly and commit `68edfbc` updated only
`README.md`; this item closes that gap.

### A7. The decision record itself

**No edit.** The amendment was written in step 1.5 of this run and is
complete. Listed here only so the implementer does not go looking for a
seventh change.

---

## 3. Parts B and C

### 3.1 Part B — reformat 4 files (AC6)

Exactly these four files, and no others (M1 re-derived this list this
step; it matches step 1's independently measured repo-wide reformat set):

| # | File | Failing line(s) | Nature of the diff |
|---|---|---|---|
| B1 | `lib/letflow/engine/variable_merge.ex` | 92, 98 | `"""` inside the `@moduledoc` heredoc must be escaped as `\"""` |
| B2 | `test/letflow/engine/pin_resolver_test.exs` | 239, 322 | 102-char `lookup = const_lookup(...)` must wrap onto a continuation line |
| B3 | `lib/letflow/engine/pin_resolver.ex` | 541 | 99-char `def merge_effective_pins/3` head must explode one argument per line |
| B4 | `test/letflow/engine/pin_rebind_test.exs` | 516 | 100-char `"entries" => [...]` list must wrap |

The change is whatever `mix format` produces for these four files. No
hand-editing, and no other file may be touched by this part — a repo-wide
`mix format` under 1.20.3 was measured (step 1, AC4) to rewrite exactly
these four.

Note for the implementer, since it contradicts ISS-0106's own stated root
cause: these files are **not** a toolchain artefact. They are unformatted
under Elixir 1.18.3 as well, with byte-identical diffs, and three of the
four are ordinary over-98-character lines that no formatter version has
ever accepted (`.formatter.exs` sets no `line_length`, so the default 98
applies). Reformatting them is correct regardless of the pin.

**Verification that settles completeness — an exit code, not an eyeball:**

```
mix format --check-formatted
```

**must exit 0.** This checks the whole tree against `.formatter.exs`'s
inputs, so it proves both that the four files are now clean and that no
fifth file was left behind or newly broken. "Run `mix format`" is not the
verification; the exit code is.

### 3.2 Part C — 14 struct-update sites (AC6)

**Count: 14, re-derived this step (M2) and in agreement with step 1's
measurement. No disagreement to report.** By file: `transition.ex` 6,
`reconstruction.ex` 6, `sub_process.ex` 1, `engine.ex` 1 — matching the
amendment's own tally exactly.

**The single idiom to apply.** Elixir 1.20's set-theoretic type checker
cannot narrow a bare variable to a struct across a function or clause
boundary, so a struct-update expression `%S{var | …}` on a variable that
was never pattern-matched as `%S{}` warns. The fix is the one ISS-0046
already merged: **pattern-match the struct explicitly at the point where
the variable is bound** — `%S{} = var` — leaving the struct-update
expression itself unchanged. The compiler states this remedy in its own
warning text ("when defining the variable `x`, you must also pattern match
on `%S{}`").

**In-repo precedent to copy the shape from** — already merged by ISS-0046,
still present, and measured clean under both Elixir 1.18.3 and 1.20.3:

- `lib/letflow/engine/transition.ex:591` — a function head that binds both
  structs and is immediately followed by a `%Token{token | …}` update on
  the next line. This is the closest analogue to most of the sites below.
- `lib/letflow/engine/transition.ex:175`, `:329`, `:343`, `:471`, `:591`
  and the multi-line heads at `:308-309`, `:391-392`, `:481-482`,
  `:505-506`, `:538-539` are the full set of existing instances.

**The 14 sites, with the binding site to annotate.** The `update site`
column is the struct-update expression the compiler flags; the `bind site`
column is where the edit actually goes. Both columns come from the
compiler's own output (the `└─ file:line:col` trailer and the
`when defining the variable …` remedy line respectively), read this step.

| # | Update site (`file:line:col`) | Struct | Variable | Bind site — what to annotate |
|---|---|---|---|---|
| C1 | `lib/letflow/engine/sub_process.ex:843:27` | `InstanceState` | `seed_state` | `sub_process.ex:825` — the `seed_state` parameter of `build_completion_multi_from_merge/12`'s head |
| C2 | `lib/letflow/engine/reconstruction.ex:563:24` | `InstanceState` | `state` | `reconstruction.ex:561` — 2nd param of the `apply_event/4` `"INSTANCE_STARTED"` clause head |
| C3 | `lib/letflow/engine.ex:1785:35` | `InstanceState` | `seed_state` | `engine.ex:1773` — the `seed_instance_state: seed_state` key inside the map pattern of `dispatch_task_completion_hop_chain/6`'s first parameter |
| C4 | `lib/letflow/engine/transition.ex:619:25` | `Token` | `token` | `transition.ex:605` — 3rd param of `dispatch_parallel_gateway/4`'s head |
| C5 | `lib/letflow/engine/transition.ex:691:10` | `InstanceState` | `instance_state` | `transition.ex:651` — 2nd param of `dispatch_parallel_split/4`'s head |
| C6 | `lib/letflow/engine/reconstruction.ex:602:41` | `InstanceState` | `state` | `reconstruction.ex:572` — 2nd param of the `apply_event/4` `"TASK_COMPLETED"` clause head |
| C7 | `lib/letflow/engine/reconstruction.ex:619:6` | `InstanceState` | `state` | `reconstruction.ex:617` — 2nd param of the `apply_event/4` `"INSTANCE_CANCELLED"` clause head |
| C8 | `lib/letflow/engine/transition.ex:779:12` | `InstanceState` | `instance_state` | `transition.ex:767` — 2nd param of `dispatch_parallel_join/4`'s head |
| C9 | `lib/letflow/engine/reconstruction.ex:630:13` | `InstanceState` | `state` | `reconstruction.ex:628` — 2nd param of the `apply_event/4` `"EXECUTION_ERROR"` clause head |
| C10 | `lib/letflow/engine/transition.ex:845:30` | `InstanceState` | `instance_state` | `transition.ex:823` — 2nd param of `fire_join/5`'s head |
| C11 | `lib/letflow/engine/reconstruction.ex:652:28` | `Token` | `parked_token` | `reconstruction.ex:648` — the `{:ok, parked_token} <- find_sub_process_completion_token(…)` binding inside the `with` of the `apply_event/4` `"SUB_PROCESS_COMPLETED"` clause (head at `:644`) |
| C12 | `lib/letflow/engine/transition.ex:876:19` | `InstanceState` | `instance_state` | `transition.ex:864` — 2nd param of `dispatch_cancel_branch/3`'s head |
| C13 | `lib/letflow/engine/reconstruction.ex:820:11` | `InstanceState` | `state` | `reconstruction.ex:804` — the `state` element of the `{:ok, state, pending_events}` tuple pattern in `resolve_pending_events/1`'s head |
| C14 | `lib/letflow/engine/transition.ex:881:31` | `JoinCounter` | `counter` | `transition.ex:878` — the `counter ->` `case` clause head inside `dispatch_cancel_branch/3` |

By struct: 11 `InstanceState`, 2 `Token`, 1 `JoinCounter`. C12 and C14 are
in the same function and are two separate edits.

Constraints on the edits:

- **Only the binding gains a pattern.** Do not rewrite the struct-update
  expression, do not restructure control flow, do not add `@spec`s, do not
  rename anything. Twelve of the fourteen are one-token insertions in a
  function head.
- Line numbers in this table are as of this branch's current HEAD. Editing
  one site shifts later line numbers within the same file — the
  implementer should work from the compiler's live output, not from these
  numbers, once the first edit lands. The table is the authoritative
  *inventory*; the compiler is the authoritative *locator*.
- The idiom is version-agnostic: step 1 measured a two-site sample
  compiling with zero warnings and format-clean under Elixir 1.18.3 as well
  as 1.20.3. It is ordinary Elixir, not a 1.20-only construct.

**Verification that settles the count after the change:**

```
mix compile --force --warnings-as-errors
```

**must exit 0.** Counting "14 fixed" is not the check — an exit code of 0
proves both that all 14 are gone and that the edits introduced no new
warning of any class. Adding a pattern match can narrow a type enough to
surface a *further* struct-update warning that was previously masked; if
that happens, the new site is fixed with the same idiom and the count
reported honestly as `14 + N`, rather than the design being treated as
wrong.

---

## 4. Acceptance verification for the whole run

| V# | Check | Passing result |
|---|---|---|
| V1 | `.tool-versions` content | byte-identical to §A1 |
| V2 | `grep -n 'elixir:' mix.exs` | still `elixir: "~> 1.18"` — unchanged (A2) |
| V3 | `mix format --check-formatted` | exit 0 (Part B) |
| V4 | `mix compile --force --warnings-as-errors` | exit 0 (Part C) |
| V5 | `mix letflow.check` | exit 0, and the first thing printed after the compile is `letflow.check_toolchain:` output |
| V6 | On this host (Elixir 1.20.3 / OTP 29) after A1 lands | the `OK` line of §A3.7, **not** a mismatch block — the pin now names what this host runs |
| V7 | Temporarily renaming `.tool-versions` and running `mix letflow.check_toolchain` | F1 block printed to stderr, task exit status unaffected, `mix letflow.check` still exits on the merits of its other steps |
| V8 | `grep -nE 'Mix\.raise\|raise \|System\.halt\|System\.stop\|\bexit\(' lib/mix/tasks/letflow.check_toolchain.ex` | no matches (property (iii)) |
| V9 | `grep -nE 'System\.get_env\|OptionParser\|Mix\.shell' lib/mix/tasks/letflow.check_toolchain.ex` | no matches (property (ii)) |

---

## 5. Open questions

Listed explicitly rather than resolved by assumption, per this role's
brief. None blocks implementation.

- **OQ1 — the forced-compile ordering side effect.** Because
  `letflow.check_toolchain` is a `lib/mix/tasks/` module, Mix must discover
  and load it, which forces a project compile as the first thing
  `mix letflow.check` does — so the alias now compiles before it
  format-checks. Two consequences: (a) if compilation fails outright, the
  toolchain warning may never print, which is a partial weakening of
  property (i) in exactly the case where knowing the running toolchain is
  most useful; (b) the `compile --warnings-as-errors` step then finds
  nothing to recompile. Consequence (b) was measured harmless (M5: cached
  warnings are re-emitted and the step still exits 1) and must be
  re-verified as V4/V5. Consequence (a) is **not** resolved here: the
  amendment names the file path, so moving the check somewhere that runs
  without compilation is outside this design's authority. Flagged for
  REVIEWER; if it is judged material, it is a follow-on, not a change to
  this run's scope.
- **OQ2 — OTP patch granularity.** §A3.5's rule cannot detect a host on
  OTP 29.0.1 against a `29.0.5` pin. Accepted and documented; raised here
  so a later run recognises it as a decision rather than an omission.
- **OQ3 — the `-otp-NN` suffix is parsed and discarded, never
  cross-checked** against the `erlang` line's major (§A3.4). A
  `.tool-versions` with `elixir 1.20.3-otp-29` and `erlang 27.2` would
  therefore be internally inconsistent without this task saying so.
  Deliberately out of scope: the amendment specifies two comparisons, not
  three, and a third verdict would have no defined precedence against the
  other two.
