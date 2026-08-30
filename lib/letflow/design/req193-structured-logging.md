# REQ-193 — Structured JSON logging with trace-id propagation

Design for `Letflow.Obs.Logger` (the `:logger_formatter` behaviour implementation),
`Letflow.Obs.Logger.redact_sensitive/1` (shared sensitive-value redaction mechanism),
and `Letflow.Obs.Logger.with_trace/1` (background trace origination). Also covers
the `config :logger` entries required in `config/config.exs` and `config/runtime.exs`.

**REQ-193 implements the shared sensitive-value redaction mechanism** (grep of
`lib/letflow/` at WF-02 start returned zero `redact`/`REDACTED` matches); REQ-190
is already done and does not need to consume it, but the mechanism is available for
any future caller.

**What already exists and is NOT rebuilt here:** `Letflow.Api.Context.assign_trace_id/1`
(lib/letflow/api/context.ex L155–162) reads the incoming `x-trace-id` header, falls back
to `generate_trace_id/0`, assigns `conn.assigns[:trace_id]`, and calls
`Logger.metadata(trace_id: trace_id)`. The request-side half of XC-01 is done.
This design makes that metadata appear in structured output and adds the background
origination path for processes with no conn.

---

## 0. Cross-module dependency map

- `Letflow.Obs.Logger` — new module, `lib/letflow/obs/logger.ex`.
  Implements `:logger_formatter` OTP behaviour (`format/2` callback).
  Depends on `Jason` (JSON encoding), `Letflow.Api.Context.generate_trace_id/0`
  (UUID v4 for `with_trace/1`), `Logger` (stdlib metadata access).
- `Letflow.Api.Context` (REQ-072, existing) — `generate_trace_id/0` called by
  `with_trace/1` only. `assign_trace_id/1` is NOT called or referenced from
  `Letflow.Obs.Logger`; its interaction is one-way (it writes `Logger.metadata`,
  the formatter reads it).
- `config/config.exs` — gains two `config :logger` entries (backends and handler formatter).
- `config/runtime.exs` — gains LOG_LEVEL validation and `config :logger, level:` entry.
- No DB tables, migrations, or Ecto schemas.

---

## 1. Module: `Letflow.Obs.Logger`

**File:** `lib/letflow/obs/logger.ex`

Implements the OTP `:logger_formatter` behaviour. The only public callback required by
that behaviour is `format/2`. Additional public functions exported for use by other
modules or tests are `redact_sensitive/1` and `with_trace/1`.

### 1.1 Behaviour

```
@behaviour :logger_formatter
```

The `:logger_formatter` behaviour contract (OTP ≥ 21):
- `format(log_event :: :logger.log_event(), config :: :logger.formatter_config()) :: unicode_binary()`
  where `:logger.log_event()` is `%{level: atom(), msg: term(), meta: map()}`.

### 1.2 `format/2`

```elixir
@spec format(
  log_event :: %{level: :debug | :info | :warning | :error, msg: term(), meta: map()},
  config :: map()
) :: iodata()
```

**Output shape:** one line of JSON followed by `\n`. The JSON object has these fields
in the specified order:

| Field        | JSON type | Source                                                                                  |
|--------------|-----------|-----------------------------------------------------------------------------------------|
| `timestamp`  | string    | `log_event.meta[:time]` (BEAM `:logger` monotonic microseconds) formatted as ISO 8601 UTC with microsecond precision: `"2026-08-30T11:46:43.123456Z"` |
| `level`      | string    | `log_event.level` atom coerced to string. OTP 21+ uses `:warning`; the formatter emits `"warn"` for `:warning` (matches OBS-01 and R-Co's enum). |
| `trace_id`   | string    | `log_event.meta[:trace_id]` cast to string; empty string `""` when absent. NEVER omitted. |
| `component`  | string    | `log_event.meta[:mfa]` — take the first element (module atom), call `inspect/1`, strip the leading `"Elixir."` prefix. Fallback to `"letflow"` when `:mfa` is absent. |
| `message`    | string    | `log_event.msg` formatted to string (see §1.3 for msg format handling).                |
| (additional) | any       | All remaining entries in `log_event.meta` after: (a) stripping the BEAM-reserved metadata keys (`:time`, `:mfa`, `:file`, `:line`, `:domain`, `:gl`, `:pid`, `:report_cb`), (b) applying `redact_sensitive/1`, (c) enforcing the reserved-field rule (§1.4). Key order within the additional section is unspecified. |

JSON encoding is performed by `Jason.encode!/1`. If `Jason.encode!/1` raises, the
formatter emits a fallback line:
`{"timestamp":"<ts>","level":"error","trace_id":"","component":"letflow","message":"log encoding failed: <inspect of original>"}`.

### 1.3 Message formatting

`:logger` delivers `msg` in one of three shapes:
- `{:string, iodata()}` — use as-is, flatten to a binary.
- `{format_string, args}` where `format_string` is a charlist — call
  `:io_lib.format(format_string, args)`, flatten result.
- `%{label: _, report: _}` or any other map — `inspect/1` it.

### 1.4 Reserved field enforcement

**Reserved keys** (five): `:timestamp`, `:level`, `:trace_id`, `:component`, `:message`
(also their string forms `"timestamp"`, `"level"`, `"trace_id"`, `"component"`, `"message"`).

When any reserved key is found in `log_event.meta` (after stripping the BEAM-internal
keys in §1.2):

1. The real computed value for that field is used in the output — the caller's value is
   NOT written and does NOT shadow the real value.
2. A `:warning`-level log is emitted at the formatter itself (via `:logger.warning/2`
   with metadata `%{formatter_violation: true}`) naming the offending key. This warning
   itself must not trigger re-entry: the formatter checks for the presence of the
   `formatter_violation: true` metadata key and short-circuits that re-entrant call to
   a plain-text line (no JSON) to avoid infinite recursion.
3. The offending key/value pair is dropped from the additional-metadata section.

This matches R-Co's `OBS-01` "caller supplying a reserved key is an error" rule.

---

## 2. Function: `Letflow.Obs.Logger.redact_sensitive/1`

```elixir
@spec redact_sensitive(map()) :: map()
```

Takes a map (metadata or any map with string or atom keys) and returns a new map with
the same keys, but with sensitive values replaced by the string `"[REDACTED]"`.

### 2.1 Exact key list (always-redacted regardless of suffix rule)

Both the atom and string form of each key are matched:

```
:authorization,      "authorization"
:password,           "password"
:password_hash,      "password_hash"
:token,              "token"
:access_token,       "access_token"
:refresh_token,      "refresh_token"
:bootstrap_token,    "bootstrap_token"
:api_token,          "api_token"
:secret,             "secret"
:client_secret,      "client_secret"
:credential,         "credential"
:credentials,        "credentials"
:"set-cookie",       "set-cookie"
:cookie,             "cookie"
```

This list matches R-Co's exact key list from the requirement description verbatim.

### 2.2 Suffix rule (wildcard redaction)

Any key (atom or string) whose string representation ends with one of these suffixes is
also redacted (value replaced with `"[REDACTED]"`):

- `_token`
- `_secret`
- `_password`
- `_credential`

String representation of an atom key is obtained via `Atom.to_string/1`. Example:
`:db_password` → `"db_password"` → ends with `"_password"` → redacted.

### 2.3 Case sensitivity

**Matching is case-sensitive, lowercase only.** The exact-key list uses lowercase keys
(matching R-Co's own list); the suffix rule matches against the lowercase string form of
the key without case-normalisation. Keys like `"Authorization"` (capital A) or
`:PASSWORD` are NOT redacted.

Rationale: R-Co's list is lowercase; HTTP headers in Elixir/Plug are always
lowercased by the time they reach `Logger.metadata`; log callers in this codebase
follow atom-as-lowercase convention. Case-insensitive matching would add complexity
with no benefit for the expected key shapes.

**Open question OQ-1:** If a future caller passes mixed-case keys (e.g. from an
external API response), case-insensitive matching may be desired. A separate
requirement should add it if needed; REQ-193 does not.

### 2.4 Value replacement

Only the value is replaced. The key is preserved exactly as passed. Nested maps are
NOT recursively traversed by default — only the top-level keys of the input map are
checked. If nested-map recursion is needed (e.g. for structured error reports), it
should be added in a later requirement.

**Open question OQ-2:** Should nested map values be recursively redacted? REQ-193
targets log metadata (one level deep in practice); not recursed. A later requirement
may add it.

---

## 3. Function: `Letflow.Obs.Logger.with_trace/1`

```elixir
@spec with_trace((() -> result)) :: result when result: var
```

Background trace origination. Used by callers (first consumer: REQ-186's scheduler
poll cycle) that have no HTTP conn and therefore no `assign_trace_id/1` in scope.

**Lifecycle:**

1. Generate a fresh trace id: `Letflow.Api.Context.generate_trace_id/0` (UUID v4).
2. Save the existing `:trace_id` from `Logger.metadata()` (may be absent/nil).
3. Put the new trace id into Logger metadata: `Logger.metadata(trace_id: new_id)`.
4. Call the provided zero-arity function.
5. In an `after` block (runs on both normal return and exception/throw/exit):
   - If the saved value was absent: call `Logger.metadata(:erase)` scoped to
     `:trace_id` only — specifically `Logger.delete_metadata([:trace_id])` or
     equivalent so that other metadata keys set by the function are preserved.
   - If the saved value was present: restore it via `Logger.metadata(trace_id: saved)`.
6. Return the function's return value (propagate exceptions normally — do not catch them).

**Note:** "even on raise/throw" is achieved by using `try/after`, not `rescue/catch`.
The after block runs for any exit from the try body, including raises, throws, and exits.

---

## 4. Config changes

### 4.1 `config/config.exs` additions

Two new `config :logger` entries, added after the existing `import_config "..."` call
(or before it — placement is flexible since `:logger` is not environment-specific):

```
config :logger, backends: []
```
Disables all legacy `:logger` backends (the default OTP console backend). Required for
clean handoff to the new handler-based config introduced in OTP 21+ and used below.

```
config :logger, :default_handler, formatter: {Letflow.Obs.Logger, []}
```
Wires `Letflow.Obs.Logger` as the formatter for the OTP `:logger` default handler.
The second element `[]` is the formatter config map (empty = use defaults).

### 4.2 `config/runtime.exs` additions

Placement: after the existing `LETFLOW_SECRETS_MASTER_KEY` block (so the config file
retains its existing validation logic untouched).

```
config :logger, level: <validated_level_atom>
```

where `<validated_level_atom>` is one of `:debug`, `:info`, `:warning`, `:error`,
derived from the `LOG_LEVEL` environment variable as follows:

**Startup validation mechanism:** inline `raise` in `runtime.exs` (same pattern as
the existing `LETFLOW_SECRETS_MASTER_KEY` block — consistent with the project's
established "boot-time failure via raise" pattern, no separate `validate!/0` function).

**Mapping:**

| `LOG_LEVEL` value | Atom           |
|-------------------|----------------|
| `"debug"`         | `:debug`       |
| `"info"`          | `:info`        |
| `"warn"`          | `:warning`     |
| `"warning"`       | `:warning`     |
| `"error"`         | `:error`       |
| absent / `nil`    | `:info` (default, no raise) |
| any other value   | `raise` with a descriptive message listing valid values |

Note: both `"warn"` and `"warning"` are accepted for forward-compatibility with callers
using either spelling. The BEAM atom is always `:warning` (OTP 21+).

**No default fallback for unrecognised values** — an unrecognised `LOG_LEVEL` causes a
startup error. This mirrors the `LETFLOW_SECRETS_MASTER_KEY` pattern and satisfies
OBS-01's "fatal startup error rather than silent fallback" requirement.

---

## 5. Module: `Letflow.Obs` (wrapper / namespace module)

**File:** `lib/letflow/obs.ex`

A minimal namespace module with only a `@moduledoc` describing the `Letflow.Obs`
subsystem. No public functions. Its purpose is to make `Letflow.Obs` appear as an
intentional namespace in `mix docs` output rather than an implicit parent of
`Letflow.Obs.Logger`. No design elements beyond the module declaration.

---

## 6. Test surface (for TEST-DESIGNER reference)

The following acceptance criteria require specific test strategies:

### 6.1 Tests requiring `ExUnit.CaptureLog` / `:capture_log`

| Criterion | Test approach |
|-----------|--------------|
| `format/2` emits one-line JSON with all five required fields | `ExUnit.CaptureLog.capture_log/1`, parse output with `Jason.decode!/1`, assert keys present |
| `trace_id` is `""` when not set in Logger.metadata | Ensure no metadata set before call; assert `trace_id == ""` in decoded JSON |
| `trace_id` is present and non-empty when set | `Logger.metadata(trace_id: "test-id")` before call; assert JSON's `trace_id == "test-id"` |
| `level` is `"warn"` for `:warning` | Emit a `:warning` level log; assert `level == "warn"` in JSON |
| `component` falls back to `"letflow"` when `:mfa` absent | Use a log call without MFA metadata; assert `component == "letflow"` |
| Reserved-key enforcement emits `:warning` | Pass a metadata key matching a reserved name; assert warning log contains the offending key name |
| `redact_sensitive/1` replaces exact-list keys | Unit test; no capture_log needed |
| `redact_sensitive/1` replaces suffix-matched keys | Unit test |
| `with_trace/1` sets and clears trace_id | Assert `Logger.metadata()[:trace_id]` is absent before; call `with_trace/1`; assert returned value; assert `:trace_id` absent after |
| `with_trace/1` restores prior trace_id if one existed | Set `Logger.metadata(trace_id: "prior")`; call `with_trace/1`; assert restored to `"prior"` after |
| `with_trace/1` clears trace_id even on raise | Use `assert_raise`; assert metadata cleared after |
| LOG_LEVEL=unknown causes startup error | Requires runtime.exs evaluation; test via `System.put_env/2` + `Application.stop/1` + eval, or document as an integration test only |

### 6.2 Tests requiring a Plug test through the real router

| Criterion | Why plug test is required |
|-----------|--------------------------|
| A log emitted during a request carries the SAME `trace_id` as the request | `assign_trace_id/1` writes to `Logger.metadata` in the request process; verifying that the trace_id in the JSON log matches `conn.assigns[:trace_id]` requires a real HTTP request going through `Letflow.Plugs.ApiPipeline` with `capture_log` active — a unit test cannot verify the end-to-end propagation chain |

### 6.3 No DB tests needed

This requirement has no Ecto schemas, migrations, or Repo calls. All tests are
pure-function unit tests or Plug integration tests.

---

## 7. Acceptance criteria mapping

| Acceptance criterion | Design element |
|---------------------|----------------|
| Every AC from requirement text maps to a concrete element | Addressed row-by-row below |
| Public function signatures with @spec types | §1.2 (`format/2`), §2 (`redact_sensitive/1`), §3 (`with_trace/1`) |
| DB tables/columns: none | §0: no migration |
| Config changes fully described (config/*.exs, runtime.exs LOG_LEVEL, startup validation) | §4.1 (config.exs), §4.2 (runtime.exs including raise mechanism) |
| Reserved field enforcement specified — how a caller supplying a reserved key causes an error | §1.4 |
| Sensitive-value redaction list matches R-Co's exact key list | §2.1 (exact list), §2.2 (suffix rule), §2.3 (case) |
| `with_trace/1` signature and lifecycle specified (generate, set metadata, call function, clear metadata) | §3 |
| No implementation code | Confirmed — all sections contain only signatures, type shapes, field tables, and config keys |

### 7.1 OBS-01 criterion mapping (from requirement text)

| OBS-01 requirement | Design element |
|-------------------|----------------|
| Single-line JSON per entry | §1.2 output shape |
| `timestamp` ISO 8601 UTC microsecond | §1.2 field table |
| `level` one of debug/info/warn/error | §1.2 field table + level mapping |
| `trace_id` always present, empty string when no active trace | §1.2 field table |
| `component` (emitting module/subsystem) | §1.2 field table |
| `message` | §1.2 field table |
| Additional metadata as key/value | §1.2 field table (additional section) |
| Reserved fields: caller supplying one is an error | §1.4 |
| LOG_LEVEL via env var, invalid value = fatal startup error | §4.2 |

### 7.2 XC-01 criterion mapping

| XC-01 requirement | Design element |
|-------------------|----------------|
| Request trace_id appears in log output | §1.2: formatter reads `log_event.meta[:trace_id]` set by `assign_trace_id/1` |
| Background trace origination (no conn) | §3: `with_trace/1` |

---

## 8. Open questions

**OQ-1** (from §2.3): Should `redact_sensitive/1` match case-insensitively for keys
that may arrive in mixed case? REQ-193 is lowercase-only. A future requirement should
extend if needed.

**OQ-2** (from §2.4): Should `redact_sensitive/1` recurse into nested maps? REQ-193
is top-level-only. A future requirement should extend if needed.

**OQ-3:** Should `component` fall back to the OTP application name (`:letflow`)
rather than the string `"letflow"` — i.e. read `Application.get_application(__MODULE__)`
at format time? Both yield `"letflow"` in practice. Using the string literal is simpler
and avoids a runtime lookup. Tentative answer: string literal `"letflow"`, no
Application lookup needed.

**OQ-4:** The `:logger` default handler's `formatter` config tuple is `{Letflow.Obs.Logger, []}`.
OTP 21+ passes the second element as the config map to `format/2`. If the module is not
yet compiled when the handler is first activated (rare but possible in test environments),
the handler falls back to the default formatter. No mitigation needed — the module is
compiled before any test runs.

**OQ-5:** `Logger.delete_metadata/1` (the correct function for removing a single key)
was introduced in Logger before OTP 25, but confirm the Elixir/OTP version floor for
this project supports it. If not, the fallback is: fetch all metadata, `Keyword.delete/2`
the key, then call `Logger.reset_metadata/1`.
