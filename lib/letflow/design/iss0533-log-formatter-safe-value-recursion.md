# Design: ISS-0533 — Recursive metadata sanitization + level/message-preserving fallback in `Letflow.Obs.Logger`

**Status:** design only — no implementation code below, signatures/shapes and precise
before/after code *sketches* only, per
`docs/agents/workflows/WF-02_requirement_implementation.md` Step 1's convention (this
design doc follows the same presentation style as
`lib/letflow/design/iss0399-attachment-content-scanning.md`, read in full before writing
this one).

**This document produces:** a rewrite of two private functions in
`lib/letflow/obs/logger.ex` — `safe_value/1` (made recursive) and `encode_entry/3`'s
`rescue` branch (made level/message-preserving) — plus one new module attribute
(`@max_sanitize_depth`). No public API, no schema, no migration, no new module. Not a
tenant-data path (see §6); SECURITY-REVIEWER is not a hard gate on this change, but
INV-4 is still discussed in §6 because the fix touches how metadata reaches the log
sink.

Both confirmed-accurate diagnosis line citations from `docs/issues/ISS-0533.yaml`
(`safe_value/1` at lines 177-181, the `rescue` branch at lines 121-135) were re-verified
against the actual current file before writing this design — see §0.

---

## §0. Context read before writing this design

- `lib/letflow/obs/logger.ex` read in full (227 lines). Confirmed against the issue's
  diagnosis:
  - `safe_value/1` is exactly as diagnosed, lines 177-181:
    ```
    defp safe_value(v) when is_pid(v), do: inspect(v)
    defp safe_value(v) when is_reference(v), do: inspect(v)
    defp safe_value(v) when is_function(v), do: inspect(v)
    defp safe_value(v) when is_port(v), do: inspect(v)
    defp safe_value(v), do: v
    ```
    No tuple/list/map recursion anywhere. The catch-all clause passes a bare tuple like
    `{Router, []}` straight through unchanged.
  - `encode_entry/3`'s `rescue` branch is exactly as diagnosed, lines 121-135: on any
    `Jason.EncodeError`/`Protocol.UndefinedError` from `Jason.encode!/1`, it builds a
    **brand-new** `fallback` map hardcoding `"level" => "error"` and
    `"component" => "letflow"`, discarding the real `level_str`/`message_str` computed
    earlier in the same function (lines 87-97) even though both are already in scope as
    local variables at the point of failure — this is a scoping/discipline bug, not a
    missing-data problem. **Answering the task's concrete question directly: yes, `level`
    (raw atom) and `message_str` (formatted string) are already local variables in
    `encode_entry/3`'s body by the time the `try` block runs (`level_str` computed line
    88, `message_str` computed line 97) — no restructuring of the function's parameter
    or call shape is needed to recover them; the rescue branch simply needs to reference
    the existing locals instead of hardcoding new ones.**
  - `redact_sensitive/1` (lines 187-192) is explicitly documented as top-level-only
    ("Only top-level keys are checked; nested maps are not traversed.") and is called
    **before** `safe_value/1` in `encode_entry/3`'s pipeline (line 110-111:
    `clean |> redact_sensitive() |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)`).
    This pre-existing nested-redaction gap is untouched by this design — flagged as
    OQ-2, not silently conflated with this issue's scope.
- `lib/letflow/design/iss0399-attachment-content-scanning.md` — read in full for this
  project's design-doc structure/conventions (header framing, §0 context-read section,
  explicit before/after shapes, `Status`/tenant-data-path framing, `Open questions`
  section, acceptance-criteria mapping table). Followed here at proportionate scale for
  a MINOR two-function bugfix — not padded to that document's length artificially.
- `docs/issues/ISS-0533.yaml` — full `diagnosis:` block read; both reproductions
  (Bandit's `plug: {Router, []}` tuple; OTP's nested `meta.error_logger.report_cb`
  function reference) are the two concrete cases this design must handle. `fix_direction`
  names exactly the two functions this design touches — no additional function is in
  scope.
- `docs/anti-patterns.md` — grepped for `logger`/`jason`/`encode`; no prior anti-pattern
  entry on this file or on Jason-encoding metadata exists yet.
- Grepped `lib/letflow/obs/` for other callers of `safe_value/1`: private function, only
  called from `encode_entry/3` line 111. No other call site to update.

---

## §1. `safe_value/1` — made recursive

### 1.1 What "recurse into tuples/lists/maps" means, precisely (per the task's own
question)

**Maps and lists are Jason-encodable containers — recurse into their elements/values,
keep the container shape.** A `list` stays a JSON array; a `map` stays a JSON object.
Each element (list) or value (map) is individually re-checked by `safe_value/2`.

**A tuple is NOT a Jason-encodable container at all — Jason has no `Encoder` for the
tuple *type* itself, at any depth, regardless of what it contains.** So a tuple is never
walked element-by-element and reassembled as a JSON array (that would silently change
its shape from "an opaque BEAM tuple" to "a JSON list," which is not what `inspect/1`
does and not what a human reading the log line expects to see for something that was
never a list in the source data). Instead, **the whole tuple is replaced by
`inspect/1` of itself, in one shot, with no further recursion inside it.**
`inspect/1` already recursively and correctly formats anything nested inside the tuple
(a pid inside a tuple renders as `#PID<0.123.0>` inside the inspected string, a nested
list renders as `[...]` inside the string, etc.) — so `plug: {MyApp.Router, []}` becomes
`"plug": "{MyApp.Router, []}"`, matching the issue's own stated expected shape
verbatim, and no separate recursive-descent-into-tuple-elements logic is needed or
correct here.

Structs are technically maps (`is_map/1` is `true` for a struct) but must be
distinguished from plain maps **before** the plain-map clause matches, because a struct
may already have a real `Jason.Encoder` implementation (e.g. `DateTime`, or any
Ecto/app struct with `@derive Jason.Encoder`) that this sanitizer must not
second-guess or reshape — re-deriving a struct's JSON shape by walking its fields
ourselves could silently produce a *different* JSON shape than that struct's own
encoder would (e.g. a `DateTime`'s own encoder produces an ISO-8601 string, not a
field-by-field object). So: **a struct with an existing `Jason.Encoder` impl passes
through unchanged (left for `Jason.encode!/1` itself to handle downstream); a struct
with no `Jason.Encoder` impl is treated the same as a tuple — inspected wholesale, not
decomposed field-by-field**, because a struct with no defined encoder has no
codebase-sanctioned canonical JSON projection for this formatter to invent one for.

Pid/reference/function/port keep their existing direct-value treatment (`inspect/1`),
now reachable both at the top level (unchanged) and at any nesting depth reached via
map/list recursion (the actual fix).

### 1.2 Depth bound — precise value and justification (per the task's own question)

**`@max_sanitize_depth 6`**, module attribute alongside the existing
`@beam_reserved_keys`/`@reserved_fields`/`@exact_sensitive` attributes (lines 11-58).

This is a hot path — every single log line in the system passes through this function,
per the task's own framing — so unbounded recursion into arbitrarily deep or
attacker/bug-influenced metadata is a real (if narrow) concern: a pathologically deep
metadata structure could make one log call do disproportionate work. Elixir terms
constructed through normal code cannot be cyclic (no back-references), so this bound is
not a cycle guard — it is a **work-bound** guard, and a shallow one is sufficient: both
of this issue's own confirmed reproductions are depth 1 (`plug: {Router, []}`) and depth
2 (`error_logger.report_cb`, one level inside a top-level metadata key), and realistic
OTP/library metadata in this codebase (checked: Bandit's own metadata shapes, Ecto's
telemetry metadata, Oban-shaped job metadata if/when used) does not exceed a small handful
of levels. `6` is chosen as roughly double the deepest case seen in practice, cheap
insurance against a not-yet-seen but plausible one-or-two-levels-deeper case, without
leaving the bound so high that a genuinely pathological structure (e.g. a deeply nested
struct dumped into metadata by mistake) still costs meaningful work before being cut off.

**At the cutoff (depth exhausted mid-recursion):** the remaining sub-term, whatever
shape it is, is replaced wholesale by `inspect/1` of itself — the same "no further
structural interpretation past this point" treatment tuples and encoder-less structs
already get at any depth (§1.1), just triggered here by depth rather than by type. This
guarantees the function's own postcondition — **every value `safe_value/2` returns is
individually Jason-encodable** — holds unconditionally, including at the depth
boundary; it never returns a raw, unexamined sub-term just because the budget ran out.

### 1.3 Before/after code sketch (shape only, not full implementation)

**Before** (current, lines 176-181):
```
# Converts non-JSON-safe BEAM values to their inspect representation.
defp safe_value(v) when is_pid(v), do: inspect(v)
defp safe_value(v) when is_reference(v), do: inspect(v)
defp safe_value(v) when is_function(v), do: inspect(v)
defp safe_value(v) when is_port(v), do: inspect(v)
defp safe_value(v), do: v
```

**After** (shape — arity-1 entry point unchanged for the one existing call site at
line 111; new arity-2 recursive worker):
```
# Converts non-JSON-safe BEAM values to their inspect representation, recursively.
# Postcondition: the returned term is always Jason-encodable, at any input nesting
# depth up to @max_sanitize_depth, beyond which the remaining sub-term is inspected
# wholesale rather than walked further.
defp safe_value(v), do: safe_value(v, @max_sanitize_depth)

defp safe_value(v, 0), do: safe_leaf(v)

defp safe_value(v, depth) when is_struct(v) do
  if jason_encodable?(v), do: v, else: inspect(v)
end

defp safe_value(v, depth) when is_map(v) do
  Map.new(v, fn {k, val} -> {k, safe_value(val, depth - 1)} end)
end

defp safe_value(v, depth) when is_list(v) do
  Enum.map(v, &safe_value(&1, depth - 1))
end

defp safe_value(v, _depth) when is_tuple(v), do: inspect(v)

defp safe_value(v, _depth), do: safe_leaf(v)

# Non-container leaf: pid/reference/function/port get inspected; everything else
# (numbers, atoms, binaries, booleans, nil, already-encodable structs) passes through.
defp safe_leaf(v) when is_pid(v), do: inspect(v)
defp safe_leaf(v) when is_reference(v), do: inspect(v)
defp safe_leaf(v) when is_function(v), do: inspect(v)
defp safe_leaf(v) when is_port(v), do: inspect(v)
defp safe_leaf(v) when is_struct(v), do: if(jason_encodable?(v), do: v, else: inspect(v))
defp safe_leaf(v) when is_tuple(v), do: inspect(v)
defp safe_leaf(v), do: v

defp jason_encodable?(v), do: Jason.Encoder.impl_for(v) != nil
```

`jason_encodable?/1` via `Jason.Encoder.impl_for/1` (returning the implementing module,
or `nil` when the protocol has no implementation for that struct) is the exact
mechanism — not a heuristic guess about which struct names are "known safe." This is
the same question `Jason.encode!/1` itself answers internally; asking it here directly
is more reliable than re-deriving the same answer some other way, and stays correct
automatically if a struct later gains/loses a `@derive Jason.Encoder`.

**Map key handling — deliberately unchanged, stated explicitly so it isn't read as an
oversight:** `safe_value/2`'s map clause above sanitizes **values** only, not keys.
This matches the existing (line 111) top-level behavior, where keys are separately
`to_string/1`'d in `encode_entry/3` itself, not via `safe_value/1`. Nested map keys are
left as their original atoms/binaries — Jason's own `Map` encoder already handles atom
keys directly (encoding them via their string form), so no nested-key-sanitization
step is needed for the two confirmed reproductions or for realistic OTP/library
metadata shapes. If a future case surfaces a non-atom/non-binary/non-number nested map
key (e.g. a pid used as a map key), that is a new, narrower gap than anything this
issue reports — named in OQ-3 rather than speculatively handled now.

---

## §2. `encode_entry/3`'s `rescue` branch — preserve real `level`/`message`

### 2.1 Is the rescue branch still needed after §1's fix, or does it become dead code?
(per the task's own question)

**Kept, and not dead — reclassified as a defense-in-depth safety net whose primary
trigger conditions (bare pid/ref/fun/port/tuple/encoder-less-struct anywhere in
metadata) are eliminated by §1, but whose branch is not unreachable in general.**
Concretely, Jason can still raise `Jason.EncodeError` on inputs §1 does not — and must
not be scope-crept into — sanitizing:

- **Non-finite floats** (`:infinity`, `:neg_infinity`, `:nan`) — Jason has no JSON
  representation for these (JSON's number grammar has none either); a metric or
  computed value landing in metadata as one of these is plausible and is a `is_float`
  value, not a pid/ref/fun/port/tuple/struct, so §1's clauses correctly leave it
  untouched and Jason's own encode call is where it fails.
- **Binaries that are not valid UTF-8** — Jason requires valid UTF-8 for JSON strings
  and raises on an invalid one; a raw byte blob landing in metadata (e.g. from a
  malformed request body echoed into a debug log) is a `is_binary` value, again correctly
  left untouched by §1.
- Any future Jason version behavior or metadata shape this design did not anticipate.

Recursing `safe_value/2` into every float/binary to defensively re-validate would be
disproportionate scope for a MINOR-severity, two-confirmed-reproduction issue, and
would add real per-log-line cost (§1.2's hot-path concern) for cases this issue never
observed. The `rescue` branch is the right place for these — it is genuinely a
**catch-all for the unanticipated**, which is exactly what a `rescue` clause is for; §1
existing specifically eliminates the two *anticipated, confirmed* cases from ever
reaching it.

### 2.2 The fix itself

The bug is not "the rescue branch exists" — it's that the rescue branch **replaces the
whole entry** instead of replacing only the part that actually failed to encode
(the sanitized-metadata map, `additional`). `ts`, `level_str`, `trace_id`, `component`,
and `message_str` are all already computed and in scope as local variables before the
`try` block (lines 87-97) and are **never themselves a source of the encode failure** —
they are always plain strings by construction (`format_timestamp/1`,
`level_to_string/1`, `to_string/1`, `extract_component/1`, and `format_msg/1` all
return binaries). Only `additional` (the metadata map) can contain a term Jason cannot
encode. So the fix separates the two: keep `base` (built from those five always-safe
values, unchanged) as the thing the rescue branch **preserves verbatim**, and replace
only `additional` with a diagnostic fallback on failure.

**Before** (current, lines 108-136):
```
additional =
  clean
  |> redact_sensitive()
  |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)

base = %{
  "timestamp" => ts,
  "level" => level_str,
  "trace_id" => trace_id,
  "component" => component,
  "message" => message_str
}

try do
  Jason.encode!(Map.merge(additional, base)) <> "\n"
rescue
  e ->
    fallback = %{
      "timestamp" => ts,
      "level" => "error",
      "trace_id" => "",
      "component" => "letflow",
      "message" =>
        "log encoding failed: #{inspect({level, msg, redact_sensitive(Map.drop(meta, @beam_reserved_keys)), e})}"
    }

    Jason.encode!(fallback) <> "\n"
end
```

**After** (shape — `base`'s five fields untouched in both the success and failure
branches; only `additional`'s shape changes on failure):
```
additional =
  clean
  |> redact_sensitive()
  |> Map.new(fn {k, v} -> {to_string(k), safe_value(v)} end)

base = %{
  "timestamp" => ts,
  "level" => level_str,
  "trace_id" => trace_id,
  "component" => component,
  "message" => message_str
}

try do
  Jason.encode!(Map.merge(additional, base)) <> "\n"
rescue
  e ->
    # Defense-in-depth net for a metadata term safe_value/1 did not anticipate
    # (e.g. a non-finite float, invalid-UTF-8 binary — see design §2.1). The
    # event's REAL level/message/timestamp/trace_id/component (base, computed
    # above and never itself a source of this failure) are always preserved;
    # only the additional-metadata portion is replaced.
    fallback_additional = %{
      "metadata_encode_error" => "log metadata encoding failed: #{inspect(e)}",
      "metadata_raw" => inspect(additional)
    }

    Jason.encode!(Map.merge(fallback_additional, base)) <> "\n"
end
```

`Map.merge(fallback_additional, base)` keeps the same left-loses/right-wins argument
order as the original `Map.merge(additional, base)` (line 122) — `base`'s five reserved
field names always win on any (here practically impossible, since
`"metadata_encode_error"`/`"metadata_raw"` don't collide with
`"timestamp"`/`"level"`/`"trace_id"`/`"component"`/`"message"`) key collision, same
invariant the success path already relies on.

**Why the second `Jason.encode!/1` call (on `Map.merge(fallback_additional, base)`) is
safe and cannot itself raise:** every value in both maps is a plain binary
(`inspect/1` and string interpolation always return binaries; `base`'s five values are
established as always-safe strings above) — a flat map of string keys to string values
has no term Jason cannot encode. This is stated explicitly rather than left implicit,
since "the rescue branch's own fallback path might itself raise" would otherwise be a
fair question for CODE-DESIGN-VALIDATOR to ask.

**What a real crash/shutdown report now looks like post-fix, concretely, for the
issue's own instance 2:** the OTP shutdown report's true `level` (whatever OTP assigned
it — typically `:error` or `:warning` for a genuine shutdown cascade, `:info` would be
unusual but is preserved exactly as reported either way) and its true formatted
`message` (from `format_msg/1`, e.g. the actual `:io_lib.format`-rendered shutdown
reason) are what the emitted JSON line shows — not a synthetic
`"log encoding failed: ..."` string. The `error_logger.report_cb` function reference,
after §1's fix, either encodes cleanly as an inspected string inside the
`"error_logger"` metadata field (the expected, common case) or — only if some other,
unanticipated term is also present — triggers this rescue branch, in which case the
line still reads with the **real** level/message and only the metadata fields carry the
diagnostic `metadata_encode_error`/`metadata_raw` substitute. Either way, "port 4000 was
already in use" (the issue's own worked example of information that was previously
buried) is legible directly in `message`, not escaped inside a nested inspect-of-inspect
string.

---

## §3. Function signature changes — summary

`lib/letflow/obs/logger.ex`:

```
defp safe_value(v :: term()) :: term()          # unchanged public shape (still arity-1,
                                                   # still called once, from encode_entry/3
                                                   # line 111) — now delegates to:
defp safe_value(v :: term(), depth :: non_neg_integer()) :: term()   # new
defp safe_leaf(v :: term()) :: term()                                 # new
defp jason_encodable?(v :: term()) :: boolean()                       # new
```

`encode_entry/3`'s own signature (`level, msg, meta -> iodata()`, called from
`format/2`) is **unchanged** — this is a purely internal control-flow fix inside the
function body, not a signature or call-site change. No caller of `Letflow.Obs.Logger`
(the `:logger_formatter` behaviour, configured wherever `:logger`'s formatter is set)
needs any change.

No new module attribute besides `@max_sanitize_depth 6` (§1.2), placed alongside the
existing attribute block (lines 10-58).

---

## §4. What this design does NOT change (scope discipline)

- `redact_sensitive/1`'s top-level-only redaction gap (§0, OQ-2) — out of scope for
  this issue; the issue's own diagnosis and fix_direction never mention redaction depth,
  only encodability.
- `@beam_reserved_keys`'s top-level-only stripping of `:report_cb` (line 11) — still
  only strips a literal top-level `:report_cb` key; this design does not change that
  list or its stripping mechanism, because §1's recursive `safe_value/2` now handles the
  *nested* `error_logger.report_cb` case (the issue's own instance 2) by inspect-ing the
  function reference wherever it's found, making a corresponding change to
  `@beam_reserved_keys`'s stripping mechanism unnecessary — sanitizing the value is
  sufficient; stripping the key is not additionally required for this issue's
  acceptance criteria.
- No behavior change to `redact_sensitive/1`'s call ordering relative to `safe_value/1`
  (still redact-then-sanitize, unchanged) — nested sensitive keys were already
  unredacted before this fix and remain so; §1 does not widen or narrow that pre-existing
  gap, it only changes what happens to *non-encodable* nested values, not *sensitive*
  ones (the two concerns are orthogonal: an already-non-sensitive but non-encodable
  tuple, and an already-sensitive-but-unredacted nested string, are different problems).

---

## §5. For SECURITY-REVIEWER (not a hard-gate tenant-data path, stated for completeness)

This change touches `lib/letflow/obs/` only — a cross-cutting logging formatter, not a
tenant-scoped `Repo` call, route, migration, or secrets path. Per
`docs/agents/instructions/security-invariants.md`, SECURITY-REVIEWER's hard gate is
tenant-data-path changes; this is not one, so this is not a required gate for this
issue's Step 3. Noted anyway, briefly, since the fix does change what data reaches the
log sink:

- **INV-4 (secrets by reference only / no secrets in logs).** Unaffected in either
  direction by this fix. `redact_sensitive/1` still runs before `safe_value/1` (§4);
  this design neither adds nor removes any redaction behavior. The one new thing this
  fix causes to appear in log output that didn't before is `inspect/1` renderings of
  previously-crash-inducing structural values (tuples, function refs, pids) — none of
  which are the sensitive-key-matched values `redact_sensitive/1` already guards
  (passwords/tokens/secrets/credentials/cookies, §`@exact_sensitive`/`@sensitive_suffixes`
  at lines 27-58) — those, if nested, were **already** unredacted and already reaching
  `safe_value/1` pre-fix (just then crashing `Jason.encode!/1` instead of encoding). This
  fix does not newly expose a sensitive value that was previously safely blocked; it
  makes a previously-crashing entry successfully encode, with the same (pre-existing,
  out-of-scope-here per OQ-2) nested-redaction gap it always had.
- No new data-access path, no new external call, no new persisted data — this fix is
  pure in-process string/term transformation.

---

## §6. Open questions — not silently resolved

- **OQ-1.** `@max_sanitize_depth 6` (§1.2) is a judgment call based on the two
  confirmed reproductions (depth 1 and depth 2) plus a look at this codebase's other
  metadata-emitting call sites, not an exhaustively surveyed constant. If a real
  metadata shape deeper than 6 levels surfaces later (unlikely per the survey, but not
  proven impossible), it degrades gracefully — the excess depth is inspect-stringified
  rather than crashing — so a too-low bound is a *readability* regression at worst, not
  a correctness one; flagged for REVIEWER at Step 2d if 6 reads as too conservative or
  too generous.
- **OQ-2.** `redact_sensitive/1`'s nested-key gap (§0, §4) is a real, pre-existing,
  separate concern (a sensitive key nested one level deep is never redacted today) —
  named here explicitly so it is not mistaken for something this issue's fix
  incidentally closes. Candidate for its own future issue if a concrete nested-secret
  logging incident occurs; not designed here.
- **OQ-3.** Non-atom/non-binary/non-number map keys at any nesting depth (e.g. a pid
  used as a map key) are not sanitized by this design (§1.3) — no confirmed
  reproduction exists for this shape in this codebase's actual metadata, and
  `encode_entry/3`'s own top-level key handling (`to_string(k)`, line 111) already
  doesn't extend to nested keys either, so this is consistent pre-existing scope, not a
  new gap this design introduces.
- **OQ-4.** Non-finite floats and invalid-UTF-8 binaries (§2.1) are deliberately left to
  the `rescue` branch rather than added to `safe_value/2`'s recursion — named as a
  candidate for a future, separately-scoped hardening pass if either is ever actually
  observed in production metadata (neither is part of this issue's confirmed
  reproductions).

---

## §7. Acceptance-criteria mapping

| Issue's fix_direction item | Resolved in |
|---|---|
| Recursive/deep sanitizer walking maps, lists, tuples; rewrites non-encodable values (pids, refs, funs, ports, tuples, encoder-less structs) at the point found | §1, §1.3 |
| `plug: {Router, []}` → `plug: "{Router, []}"` (whole-tuple inspect, not element-wise) | §1.1, §1.3 |
| `error_logger.report_cb` (nested one level) sanitized | §1.1 (map-value recursion), §1.3 |
| Rescue branch preserves original `level`/`message`, replaces only the metadata portion that failed | §2.2 |
| Whether the rescue branch is still needed post-fix | §2.1 (kept — defense-in-depth net for unanticipated terms, not dead code) |
| Hot-path performance / depth bound | §1.2 |
