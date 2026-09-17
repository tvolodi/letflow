# ISS-0703 — `Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2` exception handling

## 1. Defect being fixed

`Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2` (`lib/letflow/oidc/token_verifier/oidcc.ex:30-45`)
lets an exception raised deep in the `oidcc`/`jose` dependency chain — confirmed live:
`CaseClauseError` at `jose_base64url.decode!/2`, reached via
`Oidcc.Token.validate_jwt/3` → `oidcc_token.int_validate_jwt/4` →
`oidcc_jwt_util.jwe_peek_protected/1`, triggered by a non-base64url-shaped raw
bearer token — propagate uncaught. It crosses
`Letflow.Plugs.AuthPipeline.verify_token/1` (`auth_pipeline.ex:245-254`, which
only pattern-matches `{:ok, _}` / `{:error, _}` tuples, never exceptions) and
reaches Bandit, which serves a raw HTTP 500 with an empty body — instead of
the pipeline's documented single-401-collapse behavior
(`auth_pipeline.ex:241-244`).

Full diagnosis: `handoffs/WF03-ISS0703-20260917/step-01-issue-fixer-diagnosis.json`
(`result.summary`). This document designs the fix only; no root-cause
re-derivation here.

## 2. Rescue/catch boundary

**What it wraps:** the entire body of `verify_bearer_token/2` — i.e. both
oidcc calls in the existing `with` expression:

1. `Oidcc.ClientContext.from_configuration_worker/4`
2. `Oidcc.Token.validate_jwt/3`

**Why both, in one boundary, rather than isolating just `validate_jwt/3`:**
the confirmed crash is inside `validate_jwt/3`'s call chain, but
`from_configuration_worker/4` also crosses into the `oidcc` dependency and
has no documented raise-free guarantee either — auditing its full transitive
call graph inside `oidcc`/`jose` to prove it can never raise is not a
reliable way to satisfy the module's "never raises" contract, and provides
no benefit over covering it defensively in the same boundary the fix already
needs. One rescue/catch wrapping the whole function body is simpler than two
narrower ones and gives the same guarantee for both calls. This satisfies
AC2 by inclusion rather than by a per-call boundary.

**Placement, using this codebase's existing convention:** `lib/letflow/api/authorization.ex`
already uses the `def ... do ... rescue ... end` function-clause sugar (see
`safe_to_existing_atom/1`, `authorization.ex:250-254`) rather than an inline
`try do ... end` expression assigned to a variable. `verify_bearer_token/2`
follows the same shape: the existing `with` expression stays the entire
function body, unchanged, and `rescue`/`catch` clauses are appended directly
to the `def`, exactly like `try/rescue/catch/end` sugar attached to a
function head. No new helper function, no extracted private function, no
`try do` block nested inside the existing body.

**Both `rescue` and `catch` are needed, not `rescue` alone:** the confirmed
crash (`CaseClauseError`) is a `:error`-kind exception and is caught by
`rescue`. But `rescue` alone only catches exceptions raised via `raise/1`
(reified as `Exception` structs) — it does not catch a bare `throw/1` or a
process `exit/1` that a dependency might perform instead of raising. Since
the moduledoc's contract is "never raises" (interpreted broadly: never lets
an abnormal termination escape, not narrowly "never raises `RuntimeError`"),
the boundary defensively covers all three of Elixir's non-local-exit
mechanisms: `rescue exception` (kind `:error`) and `catch kind, reason` for
the remaining `:throw`/`:exit` kinds, per Elixir's standard
`try/rescue/catch` shape.

## 3. Exact `{:error, reason}` shape on a caught exception

```
@type crash_reason :: {:verifier_crashed, %{kind: :error | :exit | :throw, message: String.t()}}
```

Returned as `{:error, crash_reason}`.

- `:kind` — which non-local exit was caught: `:error` (from `rescue`),
  `:exit`, or `:throw` (both from `catch`).
- `:message` — a short, human-readable diagnostic string, safe to log:
  - for the `rescue` branch (kind `:error`), `Exception.message/1` applied
    to the rescued exception struct (e.g. `"no case clause matching: 123"`
    for the confirmed `CaseClauseError`);
  - for the `catch` branch (`:exit`/`:throw`), `inspect/1` applied to the
    caught `reason` term, since a thrown/exited value is not guaranteed to
    be an `Exception` struct and has no `Exception.message/1`.
- The map deliberately does **not** include `raw_token` or any token
  fragment — the crash reason is logged (see below) and must never place
  bearer-token material in logs.

**Why a new tag (`:verifier_crashed`) rather than reusing an existing oidcc
reason atom:** the module's existing `{:error, reason}` return (the
unmodified `with`-expression `else` fallthrough) is a straight pass-through
of whatever `Oidcc.ClientContext.from_configuration_worker/4` or
`Oidcc.Token.validate_jwt/3` themselves return as their own `reason` term —
there is no existing tagging convention on this module's own output to
match, since it has never produced its own reason values before now.
`:verifier_crashed` is chosen to read unambiguously in logs/telemetry as
"the verifier itself broke," distinct from a normal oidcc-reported
validation failure (bad signature, expired, unresolvable config, etc.),
without inventing an inconsistent shape — it is a `{atom, map}` 2-tuple,
the same shallow shape already used elsewhere in this call chain (e.g.
`AuthPipeline`'s own `{:header, reason}` / `{:verify, reason}` step tags).

**How `AuthPipeline` handles it — no change needed there (AC6):**
`Letflow.Plugs.AuthPipeline.verify_token/1` (`auth_pipeline.ex:245-254`)
already does:

```elixir
case verifier.verify_bearer_token(raw_token, provider_name) do
  {:ok, claims} -> {:ok, claims}
  {:error, reason} -> {:error, {:verify, reason}}
end
```

`{:error, {:verifier_crashed, %{...}}}` matches the existing `{:error, reason}`
clause with no code change; it becomes `{:error, {:verify, {:verifier_crashed, %{...}}}}`,
which `handle_auth_error/2`'s existing `{:error, {:verify, _reason}} -> reject(conn, 401, "unauthorized", "invalid or expired bearer token")`
clause (`auth_pipeline.ex:156-157`) already matches, unchanged. **Explicit
statement per AC6: no gap was found in `auth_pipeline.ex`'s error-collapse
logic; no change to that file is proposed.**

## 4. Logging inside the rescue/catch boundary

Per this module's own defensive intent and to preserve operability (this is
exactly the kind of unexpected-crash case an operator needs visibility
into, distinct from routine 401s which are not logged), the rescue/catch
boundary logs a single `Logger.warning/1` call before returning the
`{:error, ...}` tuple. The logged message is a string that names the module
and function (`Letflow.Oidc.TokenVerifier.Oidcc crashed verifying a bearer
token`), followed by the same `kind` and `message` values placed in the
returned tuple (as `kind=...` and `message=...` fields), so an operator can
see the same diagnostic that was returned without needing to correlate
against the response. This mirrors the existing precedent of
`AuthPipeline.handle_auth_error/2`'s own
`{:error, {:provision, reason}}` branch, which logs at `Logger.error/1`
before rejecting (`auth_pipeline.ex:177-179`) — the same "log the unexpected
case, stay silent on routine rejection" split. **Never log `raw_token`.**

## 5. Function signature / spec (unchanged surface)

```
@impl Letflow.Oidc.TokenVerifier
@spec verify_bearer_token(raw_token :: String.t(), provider_name :: atom()) ::
        {:ok, claims :: %{optional(String.t()) => term()}}
        | {:error, term()}
def verify_bearer_token(raw_token, provider_name) when is_binary(raw_token)
```

No change to the public signature, arity, or `@behaviour Letflow.Oidc.TokenVerifier`
contract (`lib/letflow/oidc/token_verifier.ex:28-29` already types the error
case as the unconstrained `term()`, so `{:verifier_crashed, %{...}}` needs no
behaviour-level type widening). The `@spec` above documents the two return
shapes explicitly for readers of this module going forward, formalizing what
was previously only in prose (the moduledoc). Clause placement is exactly as
described in §2: the existing `with` expression remains the unmodified `do`
body of the `def`, with a `rescue` clause and a `catch` clause appended to
the same `def` (function-clause sugar, not a nested `try do` block), each
producing the logged, tagged `{:error, {:verifier_crashed, %{...}}}` tuple
described in §3 and §4 — `rescue exception ->` builds `kind: :error` and
`message: Exception.message(exception)`; `catch kind, reason ->` builds
`kind: kind` and `message: inspect(reason)`. No further code-level detail is
specified here beyond what §2–§4 already state in prose.

## 6. Moduledoc correction

Current text (`oidcc.ex:20-27`, doc for `verify_bearer_token/2`) falsely
claims:

> Every `Oidcc.ClientContext.from_configuration_worker/4` and
> `Oidcc.Token.validate_jwt/3` error collapses to `{:error, reason}` — never
> raises on a realistic failure path (unresolvable provider config, expired
> token, bad signature, wrong algorithm).

Corrected text (replaces the quoted sentence; rest of the `@doc` is
unchanged):

> Every `Oidcc.ClientContext.from_configuration_worker/4` and
> `Oidcc.Token.validate_jwt/3` error collapses to `{:error, reason}`.
> Never raises or exits: a malformed/invalid `raw_token` — including one
> that is not base64url/JWT-shaped at all (e.g. garbage input, or an
> Authorization header value that is not a JWT, such as a caller
> accidentally sending a whole token-endpoint JSON response instead of its
> `access_token` field) — is caught at this function's own boundary and
> returned as `{:error, {:verifier_crashed, %{kind: ..., message: ...}}}`,
> the same as any other verification failure (unresolvable provider config,
> expired token, bad signature, wrong algorithm).

The module's top-level `@moduledoc` (`oidcc.ex:2-16`) makes no "never
raises" claim itself and needs no change; only the `@doc` above
`verify_bearer_token/2` does.

## 7. What TEST-DESIGNER's regression test must exercise

Per the handoff's AC4 and the diagnosis's "why existing tests didn't catch
it" finding: `test/letflow/plugs/auth_pipeline_test.exs` is configured
(`config/test.exs`) against `Letflow.Oidc.TokenVerifierDouble` — a
string-equality stub that never touches real `oidcc`/`jose` parsing — so it
cannot exercise this defect or its fix. The regression test must instead
run against the **real** `Letflow.Oidc.TokenVerifier.Oidcc` adapter.
`test/letflow/integration/keycloak_auth_pipeline_test.exs` already does this
(real Keycloak realm, real adapter) and is the natural home for the new
case — add to it rather than creating a new file, unless TEST-DESIGNER finds
a structural reason not to.

Required coverage:

1. **Unit-level, on the adapter directly:** call
   `Letflow.Oidc.TokenVerifier.Oidcc.verify_bearer_token/2` with a
   non-JWT-shaped `raw_token` (at minimum: a string that is not valid
   base64url at all, reproducing the confirmed live trigger — e.g. a JSON
   object string like the one that triggered the live incident,
   `~s({"access_token":"eyJ...","token_type":"Bearer"})`; additionally a
   plain non-base64url garbage string is recommended for breadth) against a
   real configured `provider_name`. Assert the return is
   `{:error, {:verifier_crashed, %{kind: :error, message: message}}}` with
   `message` a non-empty string — **fail-first**: on pre-fix code this call
   must be shown to raise/crash the test process (the test, run before the
   fix lands, demonstrates the crash; run after, demonstrates the clean
   `{:error, ...}` return).
2. **Integration-level, through the full pipeline:** an HTTP request (or
   `Plug.Conn` built and passed through `Letflow.Plugs.AuthPipeline.call/2`
   directly, matching this test file's existing style) carrying
   `Authorization: Bearer <non-JWT-shaped value>`, with the real Oidcc
   adapter configured (as this file already does — not `TokenVerifierDouble`).
   Assert: HTTP 401, `application/json` content type, body
   `%{"error" => "unauthorized", "detail" => "invalid or expired bearer token"}`
   (matching `auth_pipeline.ex:156-157`'s existing reject shape) — proving
   the crash no longer reaches Bandit as a raw 500.
3. Both cases must be shown fail-then-pass: run against the pre-fix
   `oidcc.ex` first (crash / test failure), then against the fix (clean
   `{:error, ...}` / 401), per this project's standard regression-test
   discipline.

No changes to `test/letflow/plugs/auth_pipeline_test.exs` (the
`TokenVerifierDouble`-backed suite) are required by this design — that
suite continues to validate `AuthPipeline`'s own step-tagging/401-collapse
logic in isolation from the real adapter, which is unaffected by this fix.

## 8. Explicitly out of scope / open questions

- **No change to `Letflow.Oidc.TokenVerifierDouble`** — it is a
  string-equality stub with no exception path to fix; not touched by this
  design.
- **No change to `auth_pipeline.ex`** — confirmed in §3; the existing
  `{:error, {:verify, _reason}} -> 401` clause already handles the new
  reason shape unchanged.
- **Open question for ELIXIR-DEV:** none. The rescue/catch shape, reason
  tuple, logging call, and moduledoc text above are complete and are not
  left as judgement calls.
