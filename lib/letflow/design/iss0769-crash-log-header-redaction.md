# Design: ISS-0769 — bearer token leaks into crash logs via `conn.req_headers`

**Status:** design, pending CODE-DESIGN-VALIDATOR.
**Issue:** `docs/issues/ISS-0769.yaml` (MINOR, security-relevant).
**Related invariants:** INV-4 (secrets never logged/traced), INV-8 (no unhandled
crashes on realistic failure paths — this is about what happens when one occurs
anyway). **This design's implementation MUST route through SECURITY-REVIEWER before
REVIEWER**, per WF-02 Step 2c — it touches the Authorization-header handling path.

---

## 1. Root cause (read from actual code, not inferred)

### 1.1 The exact leak mechanism

`deps/bandit/lib/bandit/pipeline.ex`, `Bandit.Pipeline.run/5`:

```
try do
  ...
  conn |> call_plug!(plug) |> ...
catch
  kind, value ->
    handle_error(kind, value, __STACKTRACE__, transport, span, opts, plug: plug, conn: conn)
```

Any unrescued/uncaught exception raised by *our* application code while dispatching a
request (router match, handler body, anything downstream of `Letflow.Plugs.ApiPipeline`)
is caught here by Bandit itself, **with the already-fully-built `conn` — including
`conn.req_headers`, which still holds the raw `authorization` header value — passed
as Logger metadata** (`plug: plug, conn: conn`).

`handle_error/7`'s general clause (`deps/bandit/lib/bandit/pipeline.ex` ~L230-241):

```
defp handle_error(kind, reason, stacktrace, transport, span, opts, metadata) do
  ...
  if status in Keyword.get(opts.http, :log_exceptions_with_status_codes, 500..599) do
    logger_metadata = Bandit.Logger.logger_metadata_for(kind, reason, stacktrace, metadata)
    Logger.error(Exception.format(kind, reason, stacktrace), logger_metadata)
  end
```

`Bandit.Logger.logger_metadata_for/4` (`deps/bandit/lib/bandit/logger.ex`):

```
def logger_metadata_for(kind, reason, stacktrace, metadata) do
  crash_reason = crash_reason(kind, reason, stacktrace)
  ... [domain: [:bandit], crash_reason: crash_reason] |> Keyword.merge(metadata) ...
```

`metadata` here is exactly the `plug: plug, conn: conn` keyword list from the `catch`
clause above — `Keyword.merge` puts the raw `%Plug.Conn{}` struct (with its unredacted
`req_headers`) directly into the `Logger.error/2` call's metadata under the key `:conn`.

**This fires on every 500 in every environment** (`opts.http`'s
`log_exceptions_with_status_codes` default is `500..599`; `lib/letflow/supervisor/http.ex`
starts Bandit with `plug: Letflow.Router, port: ...` and no override of that option or
of `log_protocol_errors`), and `Letflow.Plugs.ApiPipeline.handle_errors/2`
(`lib/letflow/plugs/api_pipeline.ex`) deliberately re-raises after its admission-ref
cleanup (see ISS-0743's finding: every unrescued exception in this pipeline surfaces as
a 500) — so any application bug that raises mid-request, with an `Authorization: Bearer
<token>` header present on the request, reaches this code path.

### 1.2 Why the project's EXISTING redaction machinery does not catch this

Two redaction layers already exist and both have the SAME structural blind spot:
lists of 2-tuples (the `Plug.Conn.headers()` shape — `[{"authorization", "Bearer
..."}, ...]`) are not treated as redactable.

- **`Letflow.Secrets.LogFilter`** (`lib/letflow/secrets/log_filter.ex`), the `:logger`
  primary filter registered in `Letflow.Application.start/2`, calls
  `Letflow.Secrets.Redaction.redact_map/1` on every log event's `meta` map. `redact_map/1`
  DOES recurse into the `:conn` value (a struct is a map, so `redact_value/1`'s
  `is_map(value) -> redact_map(value)` clause fires) and reaches the `:req_headers` key
  inside it. But `redact_map`'s list handling
  (`lib/letflow/secrets/redaction.ex` `redact_value/1` for `is_list(value)`) only
  recurses into list ITEMS that are themselves maps (`item when is_map(item) ->
  redact_map(item)`); every other item, including a `{"authorization", "Bearer
  <token>"}` 2-tuple, is returned unchanged (`item -> item`). `req_headers` is a list of
  2-tuples, never a list of maps, so it passes through this filter completely
  unredacted.
- **`Letflow.Obs.Logger`** (`lib/letflow/obs/logger.ex`), the configured
  `:logger_formatter`, has its own `redact_sensitive/1` — but that function only
  inspects the metadata map's TOP-LEVEL keys (doc comment: "Only top-level keys are
  checked; nested maps are not traversed."). The sensitive value here is nested three
  levels down (`meta[:conn].req_headers -> [{"authorization", token}]`), so this second
  layer does not catch it either. By the time `format/2` reaches `safe_value/2` on the
  (by-then-a-plain-map, since `LogFilter` already ran `redact_map` on the struct)
  `:conn` value, `safe_value` falls into the `is_map(v)` recursive clause and eventually
  the `req_headers` list survives untouched down to `inspect/1`-shaped leaves via
  `safe_leaf/1` (or in the `Jason.encode!` rescue fallback path, `inspect(additional)`)
  — either way the raw token string is serialised, in full, into the JSON log line's
  `"conn"` field.

**Verdict: this is a single, precise structural gap — 2-tuple header lists are not a
shape either existing redaction function recognizes — not a missing `Logger.error`
call site and not a raw `inspect(conn)`/`inspect(conn.req_headers)` written by our own
code.** No application code in `lib/letflow/` calls `inspect(conn)` or
`inspect(conn.req_headers)` directly (confirmed by grep); the leak is entirely inside
how Bandit's own crash-logging metadata interacts with our redaction utilities.

### 1.3 Why the fix belongs in the shared utility, not a one-off

Both `Letflow.Secrets.LogFilter` (used for EVERY log event, from EVERY log sink,
project-wide — Bandit's crash logs, our own `Logger.error`/`Logger.warning` call sites
listed in the issue's investigation, future call sites not yet written) and
`Letflow.Obs.Logger` share the same header-tuple blind spot, and — a second,
independent finding worth fixing in the same pass — maintain two near-identical,
independently-hand-copied sensitive-key lists
(`Letflow.Secrets.Redaction.@sensitive_exact_keys`/`@sensitive_suffixes` vs.
`Letflow.Obs.Logger.@exact_sensitive`/`@sensitive_suffixes`) that can silently drift
apart (e.g. today `Obs.Logger`'s list is a superset by wording but not
programmatically guaranteed to stay one). Fixing `Letflow.Secrets.Redaction` once and
having `Letflow.Obs.Logger` delegate to it closes the proven gap everywhere it can
occur (any future `Logger.*(msg, some_key: header_list)` call site included) and
removes the drift risk, rather than patching only the one call site this issue
happened to be reported against.

---

## 2. Fix design

### 2.1 `lib/letflow/secrets/redaction.ex` — teach `redact_map/1` to redact header-shaped tuples

No new public function; `redact_map/1`'s existing `@spec redact_map(map()) :: map()`
and its documented recursive-walk contract are unchanged from the caller's point of
view. Internal change only, to the private list-walking helper:

- **New recognized shape:** a list item that is a 2-tuple `{key, value}` where `key` is
  a `binary()` or `atom()` and `sensitive_key?/1` (the already-existing private
  predicate — case-insensitive match against `@sensitive_exact_keys` /
  `@sensitive_suffixes`) returns `true` for it. Such a tuple is replaced by `{key,
  @redacted}` — key kept as-is (matching `redact_map/1`'s existing "key is always kept"
  contract for maps), value replaced with the literal `"[REDACTED]"`.
- **Non-sensitive 2-tuples and every other list-item shape** (already-handled maps,
  plain scalars, non-2-tuples): behavior unchanged from today — maps still recurse via
  `redact_map/1`, everything else passes through as-is. In particular this does NOT
  attempt to parse or redact inside `Cookie`/`Set-Cookie` header VALUES (a single
  string like `"session=abc; other=xyz"`) — the whole value is already replaced
  wholesale because the header NAME (`"cookie"`/`"set-cookie"`) is already in
  `@sensitive_exact_keys`; no new key names need adding, this is purely a shape fix.
- **Where this fires today, concretely:** `redact_map(%{conn: %Plug.Conn{req_headers:
  [{"authorization", "Bearer tok"}, {"content-type", "application/json"}]}})` — the
  `:conn` key is not itself sensitive so `redact_value/1` recurses into the struct
  (already-existing behavior, `is_map` clause), reaches `:req_headers`, and the list
  handler now redacts the `{"authorization", "Bearer tok"}` item in place while leaving
  `{"content-type", "application/json"}` untouched.
- **No change** to `@sensitive_exact_keys`/`@sensitive_suffixes`/`@redacted` or to
  `render_reference/1` — the existing key list already contains `"authorization"`,
  `"cookie"`, and `"set-cookie"`, which is exactly what a `Plug.Conn` header-name tuple
  needs matched against (Plug lower-cases header names into `req_headers`/
  `resp_headers`).
- **Moduledoc update:** add one paragraph documenting the new tuple-shape coverage and
  its own honest limit — this still keys on the tuple's first element (the header
  name) only; a secret value embedded inside a non-sensitive-named header's VALUE (or
  inside a request body string, a query string, or a free-text exception message) is
  still not caught. Keep the module's existing "name-based denylist, not a guarantee"
  framing; extend it to say the same about header-tuple lists.

### 2.2 `lib/letflow/obs/logger.ex` — delegate `redact_sensitive/1` to `Letflow.Secrets.Redaction`

- Change `redact_sensitive/1`'s **implementation** to call
  `Letflow.Secrets.Redaction.redact_map/1` on the metadata map it receives, instead of
  maintaining its own separate `@exact_sensitive`/`@sensitive_suffixes` module
  attributes and top-level-only walk.
- **`@spec redact_sensitive(map()) :: map()` is unchanged.** Behavior strictly
  broadens (top-level-only → full recursive redaction, including the new header-tuple
  shape) — every existing passing test for this function keeps passing; this is a
  superset fix, not a behavior change existing callers could break on.
- Remove the now-dead `@exact_sensitive` and `@sensitive_suffixes` module attributes
  and the private `sensitive_key?/1` clauses in this module once nothing references
  them, so there is exactly ONE sensitive-key list in the codebase
  (`Letflow.Secrets.Redaction`'s), not two that can drift.
- This is defense-in-depth, not the primary fix — `Letflow.Secrets.LogFilter` (§2.1's
  fix) already redacts before any formatter runs, for every registered handler. This
  change makes `Letflow.Obs.Logger` correct on its own terms too (e.g. if ever invoked
  directly, or if a future handler configuration bypasses the primary filter), and
  removes the maintenance hazard of two hand-copied lists.
- **`@moduledoc`** gains one sentence noting `redact_sensitive/1` now delegates to
  `Letflow.Secrets.Redaction.redact_map/1` for the authoritative sensitive-key list and
  recursive/tuple-aware behavior.

### 2.3 No change to `Letflow.Plugs.ApiPipeline.handle_errors/2`

Confirmed out of scope: `handle_errors/2` does not itself log anything (see its own
doc comment — "pure cleanup plumbing... introduces no new response body/status"). The
leak is entirely inside Bandit's own crash-logging metadata construction interacting
with our redaction layer; nothing in `api_pipeline.ex` needs to change. Note this
explicitly so ELIXIR-DEV does not go looking for a fix there.

### 2.4 Explicitly NOT changed (open question / deliberately out of scope)

- **The log MESSAGE string itself** (`Exception.format(kind, reason, stacktrace)`,
  passed as `Logger.error/2`'s first argument, not metadata) is not touched by this
  fix — neither `LogFilter` nor `Obs.Logger`'s redaction runs against the message
  text, only against metadata. If application code ever raises an exception whose
  `message/1` (or a `raise "..."` string) itself embeds a secret value (e.g.
  interpolating a raw token into an error string), that is a separate, code-review-time
  discipline problem (don't put secrets in exception messages), not something a
  logging-layer redaction fix can generically solve — flagged here as an open question
  for SECURITY-REVIEWER/REVIEWER, not silently resolved. No known call site in
  `lib/letflow/` does this today (confirmed by grep in the investigation above); this
  design does not add a mitigation for it.
- **Request body / query string contents** are out of scope — this issue and its fix
  are specifically about the `Authorization` header (and other sensitive HTTP headers)
  reaching `conn.req_headers`, not general secret-bearing payload data.

---

## 3. Acceptance-criteria mapping

| Acceptance criterion (from issue) | Design element |
|---|---|
| Identify the exact mechanism | §1.1–1.2: Bandit `Pipeline.run/5`'s `catch` clause passes raw `conn` (with `req_headers`) into `Logger.error/2` metadata; both existing redaction layers have a list-of-2-tuples blind spot |
| Redaction fix: what/how/scope | §2.1 (primary fix, shared `Letflow.Secrets.Redaction.redact_map/1`, used by the primary `:logger` filter → covers every log sink/handler and every current+future call site) + §2.2 (dedupe/delegate `Obs.Logger`, defense-in-depth) |
| Real regression test | §4 |
| Must apply in ALL environments, not QA-only | The fix is in `Letflow.Secrets.Redaction` / `Letflow.Secrets.LogFilter`, registered unconditionally in `Letflow.Application.start/2` — no env-gated branch exists or is introduced. §4's integration test starts a real `Bandit` listener (not gated behind any QA-only flag) to prove this. |

---

## 4. Test design (for TEST-DESIGNER)

### 4.1 Unit-level — `test/letflow/secrets/redaction_test.exs` (extend existing file)

Mirrors the existing `describe "AC7: ..."` style. New cases:

1. **Header-tuple redaction, case-insensitive:** `Redaction.redact_map(%{req_headers:
   [{"authorization", "Bearer tok-123"}, {"Content-Type", "application/json"}]})` →
   asserts the `authorization` tuple's value becomes `"[REDACTED]"`, the
   `content-type` tuple is untouched, and the KEY name `"authorization"` is preserved
   (mirrors the map case's "key kept, value redacted" contract).
2. **Nested inside a struct (the actual `%Plug.Conn{}` shape):**
   `Redaction.redact_map(%{conn: %Plug.Conn{req_headers: [{"authorization", "Bearer
   secret-xyz"}]}})` → asserts the returned map's `conn.req_headers` no longer contains
   the string `"secret-xyz"` anywhere, and does contain `"[REDACTED]"`.
3. **Negative case:** a 2-tuple with a non-sensitive first element (e.g.
   `{"content-type", "application/json"}`) is returned byte-for-byte unchanged — proves
   this isn't over-broad tuple-blanking.
4. **Set-Cookie / Cookie header tuples** redacted wholesale (existing key-name coverage
   + new tuple shape combined) — `{"set-cookie", "session=abc"}` → value
   `"[REDACTED]"`.

### 4.2 Unit-level — `test/letflow/obs/logger_test.exs` (extend existing file)

Add a case proving `Letflow.Obs.Logger.redact_sensitive/1` now redacts a nested
header-tuple list too (not just top-level keys as before) — e.g. `redact_sensitive(%{conn:
%{req_headers: [{"authorization", "Bearer nested-tok"}]}})` → asserts no
`"nested-tok"` substring survives.

### 4.3 Integration-level — new file, e.g.
`test/letflow/plugs/crash_log_authorization_redaction_test.exs`

This is the "trigger a crash mid-request, assert the captured/logged output does not
contain the raw header value" regression test the issue calls for. It must exercise
the REAL path identified in §1.1 (Bandit's own `catch` clause), not just the pure
redaction function — a unit test on `Redaction.redact_map/1` alone would not catch a
regression if some future Bandit upgrade changes the metadata shape it passes, or if
this fix were wired to the wrong module.

Design:

- `config/test.exs` sets `start_http: false` (confirmed — `Letflow.Supervisor.Http`
  does not start `Bandit` under test), so this test must start its OWN `Bandit`
  instance via `start_supervised!({Bandit, plug: <test plug module>, port: 0})` — this
  does not conflict with the app-level gate, it's a self-contained listener this test
  owns and tears down.
- **Test plug:** a minimal module (defined in the test file, or a small
  `test/support/` helper) whose `call/2` reads `Plug.Conn.get_req_header(conn,
  "authorization")` (proving the header really is present on the conn Bandit builds —
  don't just assume it), then deliberately `raise`s (e.g. `raise "boom"`) — this
  reproduces "an unrescued exception mid-request" exactly as ISS-0743 characterized the
  existing crash-passthrough behavior; it does not need to go through the full
  `Letflow.Router`/`Letflow.Plugs.ApiPipeline` chain, since the bug lives in Bandit's
  own pipeline, one layer below any Letflow-specific plug.
- **HTTP call:** use `:httpc.request/4` (already a project dependency per REQ-183's
  webhook delivery — no new dependency needed) to send a real request to the
  test-owned Bandit port with header `{"authorization", "Bearer regression-sentinel-token"}`.
- **Capture:** wrap the request in `ExUnit.CaptureLog.capture_log([metadata: :all],
  fn -> ... end)` (same pattern as `log_filter_test.exs`).
- **Assertions:**
  - `refute log =~ "regression-sentinel-token"` — the raw token must never appear in
    the captured output.
  - `assert log =~ "[REDACTED]"` — proves redaction actually ran, not that the
    metadata was silently dropped or the log line never emitted.
  - (Sanity, guards against a vacuous pass) assert the log line was actually emitted
    for this crash, e.g. `assert log =~ "boom"` or `assert log =~ "crash_reason"`.
- `async: false` — starts a real listener on `port: 0` (OS-assigned) and touches
  process-global `:logger` state, same rationale as `log_filter_test.exs`.

### 4.4 Explicitly not required

No test needs to cover "message string leak" (§2.4) — that's an explicitly-out-of-scope
open question, not a claimed-fixed behavior.

---

## 5. Cross-module dependencies

- `lib/letflow/secrets/redaction.ex` (changed) ← used by `lib/letflow/secrets/log_filter.ex`
  (unchanged — no code change needed there, it already calls `redact_map/1`) ← registered
  by `lib/letflow/application.ex` (unchanged).
- `lib/letflow/obs/logger.ex` (changed) — the configured `:logger_formatter`; must keep
  its `@behaviour :logger_formatter` callbacks' specs identical (`check_config/1`,
  `format/2` untouched by this fix; only the private `redact_sensitive/1` internals and
  its module attributes change).
- No DB schema, no migration, no new Ecto types — this is a pure-function/log-pipeline
  fix.
- No `docs/requirements.yaml` entry — this is an issue fix (WF-03 territory in spirit,
  though routed here as an ad hoc design/implementation pass per the handoff), not a
  new requirement.

## 6. Invariants

- `Letflow.Secrets.Redaction.redact_map/1`'s public contract (`@spec redact_map(map())
  :: map()`, "key kept unmodified, matching value replaced") is preserved and only
  extended to a new input shape (header-tuple lists) — no existing caller/test can
  observe a behavior change for any input shape it already covered.
- `Letflow.Obs.Logger.redact_sensitive/1`'s `@spec` is unchanged; its behavior only
  broadens (strict superset of previously-redacted cases).
- The fix must not require any environment-specific configuration — `:logger.add_primary_filter/2`
  registration in `Letflow.Application.start/2` is unconditional today and stays
  unconditional.

## 7. Open questions (not silently resolved)

1. **Message-string leaks** (§2.4) — out of scope for this fix; flagged for
   SECURITY-REVIEWER to confirm no known call site raises with a secret embedded in the
   exception `message/1`, and for REVIEWER to consider whether an anti-pattern entry
   (`docs/anti-patterns.md`) is warranted ("never interpolate a raw secret value into a
   `raise`/exception message — redaction only covers metadata, not message text").
2. **`Obs.Logger`'s `@max_sanitize_depth` (6) interaction with the newly-redacted
   struct-turned-map `:conn` value** — since `LogFilter` already redacts before
   `Obs.Logger.format/2` runs, the depth limit should no longer matter for THIS bug
   (the sensitive value is gone before depth-limited `safe_value/2` ever sees it), but
   this design does not independently re-verify `@max_sanitize_depth` is deep enough to
   reach `conn.req_headers` in every possible conn shape — TEST-DESIGNER's integration
   test (§4.3) is what actually proves the full chain end-to-end regardless of this
   attribute's exact value.
3. **Whether other 2-tuple-shaped sensitive data exists elsewhere in the codebase**
   (e.g. any place logging `System.get_env/0`-style keyword lists, or other
   Plug-adjacent tuple-of-pairs data) beyond `req_headers`/`resp_headers` — this design
   fixes the shape generically (any sensitive-keyed 2-tuple in a list, not
   `req_headers` by name), so it should already cover those, but no exhaustive audit of
   every list-of-tuples call site in the codebase was performed. Flagged, not silently
   assumed complete.
