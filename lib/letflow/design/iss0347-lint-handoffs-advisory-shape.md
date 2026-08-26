# ISS-0347 — `lint_file/2` advisory shape drift (fix design)

## Module

`lib/mix/tasks/letflow.lint_handoffs.ex` (`Mix.Tasks.Letflow.LintHandoffs`)

## Problem (from ISSUE-FIXER diagnosis, step-01)

`lint_file/2` (line 339) has three result-construction branches. Two of them —
the `:non_json` / H6 branch (line 356) and the successful `:json` decode
branch (line 378, via `check_advisory/2` at line 541) — set `advisory` to a
map of shape:

```
%{path: String.t(), warnings: [{:warn, rule :: String.t(), msg :: String.t()}],
  size_info: %{desc_len: non_neg_integer(), summary_len: non_neg_integer()}}
```

The third branch — the `{:error, reason}` clause of the `:json` path (line
386-400), reached whenever `File.read/1` or `Jason.decode/1` fails for *any*
reason (BOM, truncated file, invalid UTF-8, empty file, any future
`Jason.DecodeError` cause) — sets `advisory: []`, a bare empty list.

`print_advisory/1` (line 695) does unchecked map dot-access
(`r.advisory.warnings` at line 697, `r.advisory.size_info` at line 708,
`.warnings` again at line 722) over every result in the list with no shape
check. When it reaches a result whose `advisory` is `[]`, dot-access raises
`BadMapError`, crashing the whole lint task (and CI).

## Chosen approach: (a) — normalize the parse-error branch's shape

Rejected (b) (defensive handling inside `print_advisory/1`) because the
map shape is not incidental here — it is the return contract every branch of
`lint_file/2` is already supposed to honor (the `:non_json` branch at line
356-362 explicitly constructs the same map shape for its own zero-content
case, i.e. a file with nothing to warn about). Adding a shape-check/fallback
inside `print_advisory/1` would treat the drift as tolerable input variance
when it is actually a bug in the producer; it would also leave `lint_file/2`
with an unstated, undocumented union return type (map with `advisory: map()`
*or* `advisory: []`) that every future maintainer of `print_advisory/1` (or
any other future consumer) has to rediscover the hard way. Fixing the
producer keeps `lint_file/2`'s contract single-shaped and self-evident, and
is the smallest correct change (one branch, no new function, no new type
introduced into the module's public surface).

## Type/signature changes

### `lint_file/2` — no signature change, only branch-body change

```
@spec lint_file(path :: String.t(), not_agent_attested_schema :: map()) :: map()
```

Return shape stays exactly what it already declares (`map()`) but the
concrete map that `lint_file/2` returns for every branch — including the
`{:error, reason}` clause — must now conform to:

```
%{
  path: String.t(),
  hard_new: [violation_map()],
  hard_grandfathered: [violation_map()],
  advisory: advisory_map(),
  parse_error: String.t() | nil
}
```

where `advisory_map()` is the shape already produced by `check_advisory/2`
and the `:non_json` branch:

```
advisory_map() :: %{
  path: String.t(),
  warnings: [{:warn, rule :: String.t(), message :: String.t()}],
  size_info: %{desc_len: non_neg_integer(), summary_len: non_neg_integer()}
}
```

### `{:error, reason}` branch (line 386-400) — new `advisory` value

Change line 398 from:

```
advisory: []
```

to a value of the same `advisory_map()` shape, reflecting that a file that
failed to parse contributes no warnings and zero-length size info (it has no
`task.description` / `result.summary` to measure):

```
advisory: %{path: path, warnings: [], size_info: %{desc_len: 0, summary_len: 0}}
```

This is the exact literal already used by the `:non_json` branch at line
360, so no new helper function is introduced — the two branches converge on
an existing, already-proven-safe expression. (A private helper such as
`empty_advisory(path)` would be a reasonable follow-up dedup if a third call
site ever appears, but with only two call sites today, inlining the literal
a second time is simpler than introducing a new function name for
CODE-DESIGN-VALIDATOR/REVIEWER to track — flagged here as an open
option, not a requirement.)

No other field in the `{:error, reason}` branch's map changes. `hard_new`
still carries the synthetic `"PARSE"` rule violation (line 389-396) so the
parse failure is still reported as a hard error where it already was;
`parse_error` still carries `inspect(reason)` for diagnostics. This fix only
touches the `advisory` key.

## Generalization check

The fix is keyed on the branch (`{:error, reason} <- with ...`), not on any
property of `reason` — it fires identically whether `Jason.decode/1` fails
because of a BOM, invalid UTF-8, truncated JSON, an empty file, or any other
future `Jason.DecodeError`/`File.read/1` `{:error, _}` cause, and equally if
`File.read/1` itself fails (e.g. permissions, ENOENT via a race). Every path
through this branch now produces the same `advisory_map()` shape regardless
of `reason`'s value, so no future parse-error variant can reintroduce the
shape drift.

## Caller/consumer trace — confirms no other break

`lint_file/2`'s return map has five keys: `path`, `hard_new`,
`hard_grandfathered`, `advisory`, `parse_error`. Searched all consumers of
`lint_file/2`'s results (the `results` list built in `run/1`, line 233-264,
and threaded into `print_advisory/1` and the hard-violation aggregation):

- `hard_new` / `hard_grandfathered`: consumed at line 246
  (`Enum.flat_map(results, & &1.hard_new)`) and lines 673-674
  (`print_hard/1`'s new/grandfathered aggregation). Untouched by this fix —
  the `{:error, reason}` branch's `hard_new` value is unchanged.
- `parse_error`: not consumed anywhere in `print_advisory/1` or
  `print_hard/1` per the grep of the module (only set, never read outside
  the branch itself as of this diagnosis) — unaffected either way.
- `advisory`: consumed exclusively by `print_advisory/1` at three sites —
  line 697 (`r.advisory.warnings`), line 708 (`r.advisory.size_info`), line
  722 (`&1.advisory.warnings`). All three now receive a `advisory_map()` for
  every result, matching what they already assume. `sizes` (line 708-710)
  folds every result's `size_info` into `desc_lens`/`summary_lens` for the
  median/max/sum report (lines 716-729); a parse-failed file now contributes
  `desc_len: 0, summary_len: 0`, which is correct (it has no measurable
  description/summary) and does not skew `median`/`max` upward — it can only
  pull `median` down if there are few samples, which is an accurate
  reflection of a real parse-failed file existing in the run, not a
  reporting artifact.
- No other function in the module (`check_h1_status/2` through
  `check_h4_not_agent_attested/3`, `check_advisory/2`, `median/1`, etc.)
  reads `advisory` from `lint_file/2`'s return — `check_advisory/2` only
  *produces* an `advisory_map()`, it is not a consumer of `lint_file/2`'s
  output.

No caller breaks under the corrected shape; `print_advisory/1` requires no
change under approach (a).

## Open questions

- None blocking. The optional `empty_advisory/1` dedup helper noted above is
  left to ELIXIR-DEV's discretion (not required by acceptance criteria,
  which call for the smallest correct fix).
