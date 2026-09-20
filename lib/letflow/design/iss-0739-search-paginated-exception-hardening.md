PROVENANCE (historical, not current decision authority):

# Design: ISS-0739 — `Letflow.Definitions.search_paginated/3` crash-passthrough hardening

**Filed by:** ISSUE-FIXER, discovered while root-causing an intermittent `GET
/api/v1/definitions/search` HTTP 500 with an EMPTY response body, blocking REQ-371's
AC6 e2e spec.
**Owner (implementer):** ELIXIR-DEV
**This document produces:** the exact wrap point and error-tuple shape for the fix, the
scope call on sibling read endpoints, and the ExUnit coverage TEST-DESIGNER must add —
**no implementation code**. No function bodies, no `.ex` files.
**Routing:** this is a tenant-data-read-path change (`ProcessDefinition` rows, scoped by
`opts[:prefix]`) — MUST go through SECURITY-REVIEWER (Step 2c) before REVIEWER (Step
2d), same as any other change to `lib/letflow/definitions.ex`/
`lib/letflow/routers/definitions.ex`. Do not skip straight to REVIEWER.

---

## 0. Sources read for this design

- ISSUE-FIXER's handoff (this design's own task description) — the full root-cause
  trace: ~440+ direct concurrent-load reproduction attempts at the Elixir/Ecto function
  level produced zero crashes; root cause could not be pinned to a single raising line
  and could not be reproduced again. This is stated as fact, not re-derived here — see
  §6 "What this design is (and is not)" for how that shapes the fix and its test
  coverage.
- `lib/letflow/plugs/api_pipeline.ex` — full moduledoc (lines 1-90) and
  `handle_errors/2` (lines 249-260, actual line numbers in current file; task
  description cited 207-211/43-50 from an earlier read, content confirmed
  unchanged in substance). `use Plug.ErrorHandler`'s generated `call/2`
  unconditionally re-raises after `handle_errors/2` runs — this plug is pure
  admission-ref cleanup, never a response helper, and is **not** where this fix
  belongs. Confirms: any exception that escapes every layer below `:dispatch`
  becomes Bandit's raw empty-body 500.
- `lib/letflow/routers/definitions.ex` — full read of the read-route handlers
  (lines 282-580): `handle_get_active_by_name/1`, `handle_search/1`,
  `handle_delta/1`, `handle_get_by_id/2`, `handle_list/1`, `handle_export/2`, and
  every `render_*_result/2` clause set for each. Confirmed `render_search_result/2`
  (lines 539-566) **already has** a catch-all `{:error, _common_error} ->
  Response.internal_error(conn)` clause (line 566) — this is load-bearing for §2
  below: the router needs **no change** for the fix to reach a shaped JSON body,
  only `Letflow.Definitions.search_paginated/3` itself does.
- `lib/letflow/definitions.ex` — full read of `activate/2` (lines 727-747,
  `@doc` 717-726) as the established idiom, and of `search_paginated/3` (lines
  820-869 incl. `@doc`), `get_by_id/2` (line 559), `get_active_by_name/2` (line
  578), `list_paginated/2` (line 640), `delta/2` (line 701), and the
  `@type common_error` union (lines 197-204: already includes
  `{:error, {:transaction_failed, term()}}`) and `@type search_error` (lines
  289-293).
- `lib/letflow/export_import.ex` — grepped for `rescue`: none found. `export/2`
  itself delegates its read to `Definitions.get_by_id/2` per
  `handle_export/2`'s own comment (router line ~583).
- `docs/agents/instructions/security-invariants.md` INV-8 ("No unhandled crashes on
  realistic failure paths") — the exact invariant this defect violates; BLOCKER
  severity per that doc. INV-1 (tenant isolation via `:prefix`) is unaffected — this
  fix touches only exception handling, no new query shape.
- `test/specs/REQ-030.md` and `test/letflow/definitions/promotion_assertion_rerun_test.exs`
  (line 833, `"raising evaluator -> {:error, {:transaction_failed, _}}, fail-closed
  row"`) — existing precedent for how this codebase deterministically forces a real
  raised exception in a test, informing §5 below.
- `docs/issues/` — listed directory; highest existing entry is `ISS-0738.yaml`. Next
  unused slot is `ISS-0739`, confirmed by `ls docs/issues/ISS-0739.yaml` (no such
  file) before filing.

---

## 1. Root cause honesty statement (read this before implementing or reviewing)

**There is no fail-then-pass empirical protocol requiring live-crash reproduction for
this fix**, and ELIXIR-DEV/REVIEWER must not treat its absence as incomplete work.
ISSUE-FIXER attempted ~440+ direct concurrent-load calls to
`search_paginated/3` at the Elixir/Ecto function level and produced **zero** crashes —
the original 500 could not be pinned to a specific raising line and could not be
reproduced again by the time this design was written. The fix below is **defensive,
structural hardening based on code-read evidence and idiom-matching** (closing a real,
demonstrated gap: this function has zero exception handling where its closest sibling,
`activate/2`, has had it since REQ-030), not a reproduction-confirmed root-cause patch.

What IS required, and what §5 specifies: the **new rescue path itself** must be
exercised by a real, deterministic ExUnit test that forces a genuine raised exception
through `search_paginated/3` and asserts the new typed error tuple comes out the other
end — not a live-500 repro, but not merely "it will presumably work" either.

---

## 2. The fix — wrap `search_paginated/3`, not `handle_search/1`

**Wrap point: `Letflow.Definitions.search_paginated/3` itself**, mirroring
`activate/2`'s exact idiom (lines 736-745 today):

```
def activate(id, opts) when is_list(opts) do
  prefix = Keyword.get(opts, :prefix)
  validator = Keyword.get(opts, :service_scope_validator)

  with {:ok, tenant_id} <- TenantProvisioning.tenant_id_for_schema_name(prefix) do
    try do
      id
      |> run_activate_transaction(prefix, tenant_id, validator)
      |> interpret_activate_result()
    rescue
      exception -> {:error, {:transaction_failed, exception}}
    end
  end
end
```

(Shown here as existing shipped code being read, not proposed new code — see the
Forbidden section of this role's instructions: the fix below is specified as a
transformation on `search_paginated/3`'s existing structure, not written out as a full
function body.)

**Why the context-module layer, not the router handler:**
- `activate/2` already establishes this as the module's idiom — the context module owns
  translating a raised exception into a typed `{:error, _}` result; the router only ever
  renders already-typed results (`render_search_result/2`'s five existing clauses never
  handle a raw exception, they pattern-match tuples). Wrapping in `handle_search/1`
  instead would be the only function in `lib/letflow/routers/definitions.ex` doing
  exception-to-tuple translation — a new, inconsistent idiom at the wrong layer.
- `search_paginated/3` is also called directly by tests and (per its `@spec`) is a
  public API surface in its own right; callers other than the router benefit from a
  typed result too, matching `activate/2`/`create/2`'s own contract.
- **No router change is required for the response shape.** `render_search_result/2`
  (router lines 539-566) already ends in a catch-all `{:error, _common_error} ->
  Response.internal_error(conn)` clause. Once `search_paginated/3` returns
  `{:error, {:query_failed, exception}}` instead of raising, that existing clause
  renders it as `Letflow.Api.Response.internal_error/1`'s shaped JSON problem body —
  the crash never reaches `Letflow.Plugs.ApiPipeline`'s `handle_errors/2` passthrough at
  all, because it never escapes `Letflow.Definitions` in the first place.

**New error atom: `{:error, {:query_failed, exception}}`, NOT `:transaction_failed`.**
This is a deliberate, explicit divergence from reusing `activate/2`'s exact atom, and is
this design's one substantive judgment call (flagged here, not silently made):
`activate/2`'s `{:transaction_failed, _}` names a real `Repo.transaction/1` call
(`run_activate_transaction/4`) that can genuinely fail transactionally. `search_paginated/3`
runs a single `Repo.all/2` — no `Repo.transaction/1` anywhere in its body — so labeling
its failure "transaction_failed" would misdescribe the failure class to anyone reading
logs or the `@spec`. `:query_failed` names what actually happens: a raised exception
during query construction/execution. The **rescue mechanics are identical** to
`activate/2` (bare `rescue exception ->`, catching everything, consistent with
`activate/2`'s own unqualified `rescue exception ->` at line 744) — only the tag differs.

### 2.1 Exact wrap structure (spec-level, not code)

- Keep `prefix = Keyword.get(opts, :prefix)` and `page_size = Map.fetch!(params,
  :page_size)` **outside** the `try` — both are pure, cannot raise on any input this
  function's own `when` guard already admits (`is_binary(query) and is_map(params) and
  is_list(opts)`), and `activate/2` follows the same pattern (its own
  `Keyword.get/2` calls precede its `with`).
- The `try` wraps the entire existing `with :ok <- check_query_not_empty(query), ... do
  ... end` block — i.e. everything from the current `with` through the function's
  closing `end`, unchanged in every branch. This means `check_query_not_empty/1`,
  `check_query_not_too_long/1`, `TenantProvisioning.tenant_id_for_schema_name/1`, and
  `decode_definitions_search_cursor/1`'s own typed `{:error, _}` returns still surface
  exactly as they do today (the `with` chain's own non-matching-clause short-circuit is
  unaffected by wrapping it in a `try` that only adds a `rescue` — it changes nothing
  about the `with`'s control flow, only what happens if something inside it raises
  instead of returning).
- `rescue exception -> {:error, {:query_failed, exception}}` — single catch-all clause,
  no distinction by exception type, matching `activate/2`'s own unqualified catch-all.

### 2.2 Type changes required

- `@type search_error` (line ~289) gains one member:
  ```
  @type search_error ::
          {:error, :query_empty}
          | {:error, :query_too_long}
          | {:error, {:query_failed, term()}}
          | common_error()
  ```
- `@spec search_paginated/3`'s return type already includes `search_error()` in its
  union — no additional `@spec` line needed beyond the `search_error()` type gaining
  this member; ELIXIR-DEV should double check the `@spec` still reads correctly after
  the type change (it should, since it references `search_error()` by name, not by
  inline union).
- **No change needed to `@type common_error`** — `:query_failed` is specific to
  `search_paginated/3`'s own failure class (a bare read, not a transaction), so it
  belongs on `search_error()`, not the shared `common_error()` union every write path
  also uses. Do not add it to `common_error()`.

### 2.3 Router change: none required, one doc comment recommended

`render_search_result/2`'s existing catch-all clause (router line 566) already handles
`{:error, {:query_failed, exception}}` correctly via structural match on `{:error, _}` —
`_common_error` is a variable name, not a type constraint, so it matches any two-tuple
whose first element is `:error`. **ELIXIR-DEV should add one comment line** immediately
above that catch-all noting it now also covers `search_paginated/3`'s new
`:query_failed` tag, so a future reader doesn't have to re-derive that from
`definitions.ex`. This is documentation only — the clause itself needs no code change.

---

## 3. Scope review — do other unwrapped read endpoints share this gap?

**Yes, three of `Letflow.Definitions`'s other read functions have the exact same
structural gap** (zero exception handling on a path callable with untrusted/malformed
tenant input, reachable through `Letflow.Plugs.ApiPipeline`'s same crash-passthrough).
**This design does NOT fix them** — ISSUE-FIXER's task was `search_paginated/3`
specifically, per REQ-371's blocking symptom, and silently expanding scope to touch
functions nobody has reported a live crash on would violate this project's "no scope
creep past what the task asked for" norm (REVIEWER gate). They are flagged here so
ORCH/a future task can decide whether to file a follow-up issue:

| Function | Router handler | Has `rescue`? | Same gap? |
|---|---|---|---|
| `get_by_id/2` (line 559) | `handle_get_by_id/2` | No | **Yes** — plain `Repo.get/3`, no rescue |
| `get_active_by_name/2` (line 578) | `handle_get_active_by_name/1` | No | **Yes** — plain `Repo.all/2`, no rescue |
| `list_paginated/2` (line 640) | `handle_list/1` | No | **Yes** — plain `Repo.all/2`, no rescue |
| `delta/2` (line 701) | `handle_delta/1` | No | **Yes** — plain `Repo.all/2`, no rescue |
| `ExportImport.export/2` | `handle_export/2` | No (delegates to `get_by_id/2`) | **Yes**, transitively via `get_by_id/2` |
| `activate/2` (line 727) | `handle_activate/2` | **Yes** (line 744) | No — already fixed |
| `deprecate/2`/`archive/2` (`transition/4`) | `handle_deprecate/2`/`handle_archive/2` | Yes (shared `transition/4` machinery, confirmed via grep hit at line 1866/2392) | No — already fixed |
| `search/2` (line 798, non-paginated sibling) | **not routed** — grep confirms no HTTP caller | No | Gap exists but currently unreachable from any endpoint; out of scope entirely, not just deferred |

Every router handler for the four exposed gaps (`get_by_id`, `get_active_by_name`,
`list_paginated`, `delta`) already ends its own `render_*_result/2` in the same
`{:error, _common_error} -> Response.internal_error(conn)` catch-all pattern
`render_search_result/2` uses — so if any of these four functions is later wrapped the
same way `search_paginated/3` is being wrapped here, **no router change would be needed
there either**, same shape as this fix. Recommended (not performed by this design):
file a follow-up issue proposing the identical `{:error, {:query_failed,
exception}}` treatment for `get_by_id/2`, `get_active_by_name/2`, `list_paginated/2`,
and `delta/2`, referencing this design doc as precedent.

---

## 4. Invariants

- **INV-8 compliance restored for `search_paginated/3`**: after this fix, no realistic
  failure path inside this function can escape as an unhandled crash reaching a shared
  process's crash-passthrough. (INV-8 is BLOCKER severity per
  `docs/agents/instructions/security-invariants.md`.)
- **No change to tenant scoping (INV-1)**: `TenantProvisioning.tenant_id_for_schema_name/1`
  still runs exactly where it runs today, inside the (now-wrapped) `with` chain, before
  any `Repo.all/2` call. The `try/rescue` adds no new code path that could bypass or
  reorder this check.
- **No change to the query itself, its SQL shape, its pagination semantics, or its
  cursor contract.** This is exception-handling hardening only — every existing
  `{:ok, _}`/typed-`{:error, _}` branch's behavior is byte-for-byte unchanged.
- **`{:error, {:query_failed, exception}}` must never leak the raw exception message
  into the HTTP response body.** `Response.internal_error/1` takes no arguments (per
  `lib/letflow/api/response.ex` line 182-183, confirmed: `def internal_error(conn), do:
  send_problem(conn, Error.internal())`) — it already renders a fixed, generic problem
  body regardless of what `exception` actually is, so this invariant holds automatically
  via the existing `render_search_result/2` catch-all. ELIXIR-DEV must not add any code
  path that serializes `exception`'s message into the response.

---

## 5. Test coverage TEST-DESIGNER must add

`search_paginated/3` currently has **zero** test coverage (`grep -rn
"search_paginated" test/` returns nothing) — this is a pre-existing gap this fix does
not get to skip closing. Required, in `test/letflow/definitions/` (co-locate with
`store_test.exs`'s existing REQ-081 coverage, or a new
`search_paginated_test.exs` — TEST-DESIGNER's call which, consistent with the sibling
test files already in that directory):

### 5.1 Happy path (currently entirely untested — do this regardless of the exception fix)
- A basic call with a matching `query` and a default `page_size` returns `{:ok, %{items:
  [...], next_cursor: ...}}` with real seeded `ProcessDefinition` rows, ranked/ordered
  per `search_paginated/3`'s own `@doc` (name match ranks above description-only match).
- Cursor pagination: a first page followed by a second page using the returned
  `next_cursor` returns the next distinct slice, no overlap/gap — mirror the existing
  pattern `store_test.exs` already uses for `list_paginated/2`'s cursor tests.
- Each existing typed-error branch gets at least one test if not already covered
  elsewhere: `{:error, :query_empty}`, `{:error, :query_too_long}`, `{:error,
  :invalid_cursor}`, `{:error, :wrong_endpoint}`, `{:error, :expired}`.

### 5.2 Forced-exception path — exercising the NEW rescue clause deterministically

**Do not attempt to reproduce the original live 500** — per §1, that is not required and
not expected to succeed. Instead, force a **genuine, real** raised exception
deterministically, following this codebase's own established precedent (`test/specs/
REQ-030.md`'s telemetry-pause technique and `promotion_assertion_rerun_test.exs`'s
"raising evaluator" technique both force a *real* exception rather than mocking one —
this codebase has no `Mox`/`:meck` dependency for `Ecto.Repo` calls, confirmed by grep
finding none in `test/letflow/definitions/`).

**Recommended technique** (mirrors the `Postgrex.Error 42P01 undefined_table` shape
already seen and documented in `test/reports/report-20260821-WF03-ISS0119-20260821.yaml`):
inside the test's own sandboxed transaction, immediately before calling
`search_paginated/3`, execute a raw DDL statement via
`Ecto.Adapters.SQL.query!(Letflow.Repo, ~s(DROP TABLE "<schema>".process_definitions),
[])` (schema-qualified to the test's own provisioned tenant schema, never a shared/
global table) to make the subsequent `Repo.all/2` call inside `search_paginated/3`
genuinely raise a real `Postgrex.Error` (`undefined_table`). Because
`Ecto.Adapters.SQL.Sandbox` wraps the whole test in an outer transaction that rolls back
at test end, this DDL never persists or affects any other test — same isolation
guarantee every other sandboxed test in this suite already relies on.

Assert:
```
assert {:error, {:query_failed, %Postgrex.Error{}}} =
         Definitions.search_paginated(query, params, prefix: schema_name)
```
- Confirm the exception is a **real** `%Postgrex.Error{}` (or whatever the actual raised
  struct is — assert on the struct shape observed, not a guessed one; TEST-DESIGNER
  should run this once locally/in CI to see the real struct before asserting on it
  narrowly, consistent with "no speculation").
- This test's sole purpose is proving `search_paginated/3`'s new `try/rescue` clause is
  reachable and produces the documented tuple shape — it is not a regression test for
  the original unreproducible 500, and its report/docstring should say so explicitly
  (mirroring §1's honesty framing) so a future reader doesn't mistake it for a
  fail-then-pass repro of the original bug.

### 5.3 Router-level test (optional but recommended)
- One `router`/integration-level test asserting that when `search_paginated/3` returns
  `{:error, {:query_failed, _}}`, `GET /api/v1/definitions/search` responds with a
  **shaped JSON body** (via `Response.internal_error/1`'s problem shape) at HTTP 500 —
  not an empty body. This is the concrete, testable version of "the fix means Bandit's
  raw empty-body crash response no longer happens for this failure class" — achievable
  by stubbing/injecting at whatever level this codebase's existing router tests already
  use to force a context-module error tuple (check `test/letflow/routers/
  definitions_test.exs` if it exists for the established pattern before inventing a new
  one).

---

## 6. What this design is (and is not)

- **Is:** a structural hardening of `search_paginated/3` to match an idiom this
  codebase already established in `activate/2`, closing a real, code-verified gap
  (zero exception handling + zero test coverage) that is independently worth fixing
  regardless of whether it was THE cause of the one observed 500.
- **Is not:** a confirmed root-cause fix for the specific intermittent 500 ISSUE-FIXER
  observed. That symptom could not be reproduced after ~440+ attempts and no single
  raising line was identified. If the same symptom recurs after this fix ships, that is
  evidence the trigger lies elsewhere (Admission plug, AuthPipeline, Plug.Parsers, or
  Jason response encoding, per ISSUE-FIXER's own note) — not evidence this design was
  wrong, since this design never claimed to address those layers.
- **Open question (not silently resolved):** whether `get_by_id/2`, `get_active_by_name/2`,
  `list_paginated/2`, and `delta/2` (§3) should receive the identical treatment is left
  for a follow-up decision, not resolved here. Recommend ORCH file a follow-up
  `docs/requirements.yaml` entry or issue if it decides to pursue it.

---

## 7. Issue record

Filed as `docs/issues/ISS-0739.yaml` (next unused slot, verified against the directory
listing before filing — `ISS-0738.yaml` is the highest existing entry). See that file
for the full structured record: severity `MAJOR` (blocks REQ-371 AC6; real
production-reachable crash symptom even though rare/unreproduced), `queue_ref`/
`github_ref` left as placeholders for ORCH, `status: open` pending implementation.
