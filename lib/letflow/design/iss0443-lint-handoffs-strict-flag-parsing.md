# ISS-0443 — reject unrecognized `lint_handoffs` flags instead of silently ignoring them

Design for the fix to ISS-0443. Diagnosis: step-01 (ISSUE-FIXER), this session
(`WF03-ISS0443-20260907`). No implementation code below — exact replacement
shape, `@spec`s, and message text only.

## 0. Independently re-verified against source

Read `lib/mix/tasks/letflow.lint_handoffs.ex` directly (not taken on
ISSUE-FIXER's word).

- `run/1`, lines 279-281: `dir = resolve_dir(args)` / `autofix? = "--autofix"
  in args` — confirmed, no `OptionParser` anywhere in this module.
- `resolve_dir/1`, lines 353-360 (public, `@spec [String.t()] :: String.t()`):
  dispatches on `find_dir_flag/1`'s three-way return
  (`:not_present`/`{:ok, value}`/`:missing_value`).
- `find_dir_flag/1`, lines 362-365: hand-walks `args`, matching only
  `["--dir", value | _rest]` / `["--dir"]` / `[]`; every other head shape
  (`[_other | rest]`) is skipped via recursion with **no record kept** that
  an unrecognized token was seen. Confirmed root cause: this clause is exactly
  where `--bogus-flag-xyz` (and a mistyped `--autofx`/`--dr`) silently
  disappears.
- Reproduced live: `mix letflow.lint_handoffs --bogus-flag-xyz` — exit 0,
  normal healthy banner, no mention of the flag.
- Confirmed via `Grep` that `resolve_dir/1` and `find_dir_flag/1` have exactly
  two callers in the whole repo: `lib/mix/tasks/letflow.lint_handoffs.ex`
  itself (`run/1` calls `resolve_dir/1`; `resolve_dir/1` calls
  `find_dir_flag/1`) and `test/mix/tasks/letflow.lint_handoffs_test.exs`
  (direct unit calls to `LintHandoffs.resolve_dir/1` only — `find_dir_flag/1`
  is private and never called from the test file). No other `lib/` module
  calls either function.
- Confirmed via `mix.exs` line 105: `letflow.check`'s alias chain invokes the
  task as the bare string `"letflow.lint_handoffs"` — zero flags, every CI
  run. No other invocation form appears anywhere in `.github/workflows/ci.yml`
  or `mix.exs`.
- Confirmed ISS-0442/ISS-0457 (both touching `run_autofix/1` and its
  downstream re-serialization) are merged to `main` — no live sequencing
  conflict; this fix touches a disjoint region of the file (flag parsing
  only, lines ~279-365).
- Verified `OptionParser.parse/2`'s exact `strict:` semantics for this
  module's two flags, by direct execution (`elixir`, this session):

  ```
  OptionParser.parse(["--dir"], strict: [dir: :string, autofix: :boolean])
  #=> {[], [], [{"--dir", nil}]}
  OptionParser.parse(["--dir", "x/y"], strict: [dir: :string, autofix: :boolean])
  #=> {[dir: "x/y"], [], []}
  OptionParser.parse(["--autofix", "--dir", "x/y"], strict: [dir: :string, autofix: :boolean])
  #=> {[autofix: true, dir: "x/y"], [], []}
  OptionParser.parse(["--bogus-flag-xyz"], strict: [dir: :string, autofix: :boolean])
  #=> {[], [], [{"--bogus-flag-xyz", nil}]}
  OptionParser.parse(["--dir", "x/y", "extra"], strict: [dir: :string, autofix: :boolean])
  #=> {[dir: "x/y"], ["extra"], []}
  OptionParser.parse([], strict: [dir: :string, autofix: :boolean])
  #=> {[], [], []}
  ```

  Load-bearing finding: **a `--dir` given with no following value and an
  unrecognized flag both land in the `invalid` list as `{flag, nil}`** — they
  are only distinguishable by which `flag` string appears, not by the `nil`.
  A trailing bare positional token (no leading `--`) lands in `remaining`,
  not `invalid`, and is **not** rejected by `strict:` on its own.

## 1. The replacement shape

### 1.1 New private helper: `parse_flags/1`

Single parse point, called once per `run/1` invocation, replacing
`find_dir_flag/1` entirely (removed) and absorbing the `"--autofix" in args`
check.

```
@spec parse_flags([String.t()]) :: {dir :: String.t(), autofix? :: boolean()}
defp parse_flags(args)
```

Body shape:

1. `{parsed, remaining, invalid} = OptionParser.parse(args, strict: [dir: :string, autofix: :boolean])`
2. If `invalid != []`: call `raise_invalid_flag(hd(invalid))` (see §1.2) —
   raises, `no_return`. Only the **first** invalid entry is ever reported
   (`OptionParser`'s own list order is left-to-right over `args`); this
   matches the project's existing precedent of reporting one clear cause
   rather than dumping every problem at once (e.g. `guard_empty_scope/2`'s
   single-cause `Mix.raise`).
3. If `remaining != []` (after `invalid` is confirmed empty): `Mix.raise`
   with `"letflow.lint_handoffs: unexpected argument(s) #{inspect(remaining)} -- this task takes no positional arguments"`.
   Rationale in §1.4.
4. Otherwise: `dir = Keyword.get(parsed, :dir, @handoffs_dir)`,
   `autofix? = Keyword.get(parsed, :autofix, false)`, return `{dir, autofix?}`.

### 1.2 `raise_invalid_flag/1` — message shape, preserving the existing `--dir` wording

```
@spec raise_invalid_flag({String.t(), String.t() | nil}) :: no_return()
defp raise_invalid_flag(invalid_entry)
```

Three clauses, matched on the `{flag, value}` shape `OptionParser`'s
`invalid` list entries carry:

- `{"--dir", nil}` → `Mix.raise("letflow.lint_handoffs: --dir given with no path argument")`
  — **byte-identical to today's message** (currently raised by
  `resolve_dir/1`'s `:missing_value` branch). This is deliberately
  special-cased ahead of the generic clause below so
  `test/mix/tasks/letflow.lint_handoffs_test.exs`'s existing
  `F-DIR-MISSING-VALUE` test (`assert_raise Mix.Error, ~r/--dir given with no
  path argument/, fn -> LintHandoffs.resolve_dir(["--dir"]) end`, lines
  431-435) keeps passing with **zero test-file changes** for that one case.
- `{flag, nil}` (any other flag — unrecognized, e.g. `"--bogus-flag-xyz"`,
  or `"--autofx"`, `"--dr"`) →
  `Mix.raise("letflow.lint_handoffs: unrecognized flag #{inspect(flag)} -- known flags are --dir <path> and --autofix")`.
  This is ISS-0443's own AC1: names the offending flag, exits non-zero.
- `{flag, value}` (a flag `strict:` recognized but whose value failed its
  declared type — e.g. `--autofix=notabool`) →
  `Mix.raise("letflow.lint_handoffs: invalid value #{inspect(value)} for flag #{inspect(flag)}")`.
  Included for completeness (`OptionParser` can produce this shape for a
  declared `:boolean`/`:string` switch given a malformed value); no known
  legitimate call form triggers it today.

### 1.3 `resolve_dir/1` — external contract, preserved signature, widened raise surface (deliberate)

Kept **public**, same input type (`[String.t()]`) and same success return
type (`String.t()`), so no caller needs to change its call shape:

```
@spec resolve_dir([String.t()]) :: String.t()
def resolve_dir(args) do
  {dir, _autofix?} = parse_flags(args)
  dir
end
```

`find_dir_flag/1` is deleted — fully subsumed by `parse_flags/1`.

**What is preserved byte-for-byte:**
- `resolve_dir([])` → `@handoffs_dir` (`"handoffs"`) — `F-DIR-DEFAULT`.
- `resolve_dir(["--dir", "some/fixture/dir"])` → `"some/fixture/dir"` —
  `F-DIR-EXPLICIT`.
- `resolve_dir(["--autofix", "--dir", "x/y"])` and
  `resolve_dir(["--dir", "x/y", "--autofix"])` → `"x/y"` —
  `F-DIR-ORDER-INDEPENDENT` (order-independence now comes from
  `OptionParser.parse/2` itself rather than hand-walked recursion, same
  observable result).
- `resolve_dir(["--dir"])` → raises `Mix.Error`, message matching
  `~r/--dir given with no path argument/` — `F-DIR-MISSING-VALUE`.

**What deliberately widens (this is the fix, not a side effect):**
`resolve_dir(args)` now also raises when `args` contains any flag other than
`--dir`/`--autofix` (previously silently ignored by `find_dir_flag/1`'s
catch-all), or any positional token. No existing test calls `resolve_dir/1`
with such input, so no existing assertion changes — this is a pure behavior
addition on a previously-untested (because previously silently-wrong) input
class. Justified: `resolve_dir/1` is the one function in the call chain
`run/1` relies on for flag handling, so making it (via `parse_flags/1`)
reject unknown flags is the mechanism ISS-0443 asks for, not a scope
overreach — the alternative (leaving `resolve_dir/1` lenient and only
validating in `run/1` separately) would require two parse points and risks
exactly the kind of drift ISS-0443's root cause already demonstrates (logic
duplicated across `run/1` and a helper, one path stricter than the other).

### 1.4 `remaining` (bare positional args) — decision: also raise

A stray token with no leading `--` (e.g. `mix letflow.lint_handoffs foo`)
survives `strict:`'s validation untouched, landing in `remaining` rather
than `invalid`. Decision: **treat non-empty `remaining` as a hard error
too**, same `Mix.raise` family, distinct message (§1.1 step 3). Rationale:
this task defines no positional arguments anywhere in its `@moduledoc`
Usage section (lines 87-91) — a bare token is never a legitimate invocation,
and silently accepting it would reopen a narrower version of the exact
"confident green for something that didn't happen" shape ISS-0443 exists to
close (e.g. a caller who meant `--dir foo` but dropped the `--dir` by typo
would previously have had `foo` silently discarded by the old
`[_other | rest]` catch-all too — this closes that variant, not just the
`--`-prefixed-flag variant).

### 1.5 `run/1` — updated call shape

Lines 279-281 become:

```
def run(args) do
  {dir, autofix?} = parse_flags(args)

  files = handoff_files(dir)
  ...
```

Everything from `guard_empty_scope(dir, files)` (current line 285) onward is
**unchanged, byte-for-byte** — `dir` and `autofix?` are still plain
`String.t()`/`boolean()` values with the same possible contents as before;
downstream code has no visibility into how they were produced.

## 2. Confirming downstream consumers are unaffected

Traced every use of `dir` and `autofix?` after line 281 in current `run/1`:

- `handoff_files(dir)` (discovery), `guard_empty_scope(dir, files)`
  (ISS-0440's empty-scope refusal), the banner's `inspect(dir)` /
  `"under #{inspect(dir)}"` text (ISS-0440), `check_registry_coverage(files,
  dir)` — all take `dir` as an opaque `String.t()`. None inspect *how* `dir`
  was resolved, only its value. Since §1.3 preserves `resolve_dir/1`'s
  return value byte-for-byte for every legitimate call shape, all four are
  unaffected.
- `if autofix? do ... end` (branches into `run_autofix(files)` /
  `print_autofix_report/1` / refused-tracking) — takes `autofix?` as an
  opaque `boolean()`. `Keyword.get(parsed, :autofix, false)` produces `true`
  exactly when `"--autofix" in args` would have (the only two forms
  `OptionParser` accepts for a declared `:boolean` switch from a caller
  passing bare `--autofix` are presence → `true`, absence → default
  `false`— both match the old `"--autofix" in args` check's own two
  outcomes for every call shape used anywhere in this codebase, per the
  `mix.exs`/CI grep in §0).
- **`run_autofix/1` and everything inside it** (`autofix_file/1`,
  `rewrite_top_level_status!/3`, `splice_top_level_status/2`,
  `scan_for_status/4` and its helpers — ISS-0442/ISS-0457's domain) — takes
  only `files` (from `handoff_files(dir)`) as input, never `args` or the
  parsed flag values directly. **Entirely untouched by this design.**

## 3. Exact scope

**Only** `lib/mix/tasks/letflow.lint_handoffs.ex`, lines ~279-365 (`run/1`'s
flag-extraction prologue, `resolve_dir/1`, `find_dir_flag/1` — the last
deleted, replaced by `parse_flags/1` and `raise_invalid_flag/1`). No change
to:

- `guard_empty_scope/2` (ISS-0440) — unchanged, still called with the same
  `dir`/`files` values.
- `run_autofix/1` and its full downstream re-serialization chain
  (ISS-0442/ISS-0457) — untouched, per §2.
- Any lint rule (H1-H6), advisory check, or registry-coverage logic.
- `@moduledoc` Usage section content (lines 87-91) — the four documented
  invocation forms (`mix letflow.lint_handoffs`, `--dir <path>`,
  `--autofix`, `--autofix --dir <path>`) are exactly what `strict: [dir:
  :string, autofix: :boolean]` accepts; no doc update needed for those. A
  one-line moduledoc addition noting "unrecognized flags now raise" is
  optional polish, not required for correctness — left to
  ELIXIR-DEV/DOC-UPDATER's judgment, not prescribed here.

### 3.1 Follow-up candidate, explicitly out of scope

`lib/mix/tasks/letflow.check_async_sandbox_reachability.ex` documents itself
as mirroring this same hand-rolled flag-parsing pattern (per ISSUE-FIXER's
note). **Not touched by this design** — flag it as a follow-up issue
candidate for the same `OptionParser.parse(strict: ...)` treatment, filed
separately rather than folded in here, since ISS-0443's own scope (per its
`affected_files:`) is `lib/mix/tasks/letflow.lint_handoffs.ex` only.

## 4. Test-ability — ISS-0443's 4 acceptance criteria

1. **AC1 — an unrecognized flag raises `Mix.Error` naming the flag, exit
   non-zero.** Cover both `resolve_dir/1` directly (unit-level, e.g.
   `assert_raise Mix.Error, ~r/unrecognized flag "--bogus-flag-xyz"/, fn ->
   LintHandoffs.resolve_dir(["--bogus-flag-xyz"]) end`) and `run/1`
   end-to-end via a tmp fixture dir (matching this file's existing
   `capture_io`/tmp-dir convention, e.g. `System.tmp_dir!/0`, never the real
   `handoffs/`), asserting the raise and that no banner/"OK" line is
   printed. Also cover the two named-in-the-issue typo shapes,
   `--autofx` and `--dr`, as concrete regression cases (both are just
   "unrecognized flag" under `strict:`, but the issue names them
   specifically as the motivating scenarios).
2. **AC2 — `--dir`/`--autofix` continue to work exactly as before, via a
   real run.** The existing `F-DIR-DEFAULT`/`F-DIR-EXPLICIT`/
   `F-DIR-ORDER-INDEPENDENT`/`F-DIR-MISSING-VALUE` tests (lines 416-435)
   and the `ISS-0440 -- run/1 end-to-end via --dir` describe block's
   existing tests must all still pass unmodified (§1.3 guarantees the
   return values and the `--dir`-missing-value message are byte-identical).
   TEST-DESIGNER should run the full existing file, not just add new tests,
   to prove no regression.
3. **AC3 — the no-flag CI path is unchanged.** `mix letflow.lint_handoffs`
   with zero args must still resolve `dir` to `@handoffs_dir` and produce
   the same `"OK -- 0 new violations across N handoff files under
   \"handoffs\" (M pre-existing grandfathered...)"` banner shape against the
   real corpus — `parse_flags([])` returns `{[], [], []}` from
   `OptionParser.parse/2` (confirmed §0), so `dir = @handoffs_dir`,
   `autofix? = false`, identical to today. Verify via an actual
   `mix letflow.lint_handoffs` run (or the existing `letflow.check` alias
   invocation) reporting the current real-corpus figures (0 new, 25
   pre-existing grandfathered per this task's own current baseline —
   TEST-DESIGNER should re-confirm the live count at review time rather
   than hardcode it, since the grandfathered count is data, not part of
   this fix).
4. **AC4 — `OptionParser` doesn't reject/reinterpret any existing
   legitimate call form.** Confirmed by direct execution in §0: all four
   documented forms (`[]`, `["--dir", path]`, `["--autofix"]`,
   `["--autofix", "--dir", path]`, and the reverse order) parse cleanly
   with empty `invalid`/`remaining`. `mix.exs`'s `letflow.check` alias
   (line 105) invokes the bare zero-arg form only — no other invocation
   form exists anywhere in `mix.exs` or `.github/workflows/ci.yml`
   (confirmed by grep, §0) — so there is no hidden fifth call shape to
   worry about breaking.

## 5. Open questions

None. `resolve_dir/1`'s contract is preserved for every call shape any
existing caller (production code or test) actually uses; the one
intentional widening (§1.3, §1.4) is exactly the behavior ISS-0443 asks
for and is stated explicitly rather than silently assumed.
