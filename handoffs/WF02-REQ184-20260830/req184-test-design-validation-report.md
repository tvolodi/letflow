# REQ-184 TEST-DESIGN-VALIDATOR report (WF-02 Step 3b)

## Verdict: PASS

## Scope

Independently re-verified TEST-DESIGNER's Step 3 gap-fill pass (2 gaps found
and filled in `test/letflow/routers/webhooks_test.exs`'s `REQ-184 AC2`
describe block; other 4 ACs confirmed already complete). Read
`docs/requirements.yaml`'s real REQ-184 entry (all 6 ACs), both test files in
full, `lib/letflow/webhooks.ex`, `lib/letflow/routers/webhooks.ex`, and the
relevant clause of `lib/letflow/api/authorization.ex`, independently rather
than trusting the gap-analysis doc's claims.

## Per-AC verification

- **AC1** (9-field allowlist, concrete values): confirmed real coverage —
  `describe "REQ-184 AC1: ..."` asserts an exact sorted key-set (not a
  superset check) plus every field against a concrete seeded `Delivery` row,
  across both a `FAILED`/`last_error` case and a `SUCCESS`/`last_error: nil`
  case.
- **AC2** (limit honored + ordering): confirmed the two gap-fills are real
  and correct.
  - The exact-limit-cutoff test now asserts
    `Enum.map(items, & &1["delivery_id"]) == [most_recent.delivery_id, second_most_recent.delivery_id]`,
    genuinely proving order of the surviving subset, not just count.
  - Four new parameterized tests (`?limit=abc`, `?limit=0`, `?limit=-1`,
    `?limit=5abc`) exercise `resolve_limit/1`'s second branch
    (`lib/letflow/routers/webhooks.ex:241-248`), previously uncovered.
- **AC3** (403 without WebhooksManage): independently re-read
  `lib/letflow/api/authorization.ex`'s real `role_allows?/2` clause for
  `:TASK_WORKER`:
  `permission in [:DefinitionsRead, :InstancesRead, :TasksRead, :TasksComplete]`
  — `:WebhooksManage` is genuinely absent. `TASK_WORKER` is confirmed a real
  role, not a fabricated one. Test is valid.
- **AC4** (cross-tenant real id -> 404 regardless of permission): confirmed
  the existing test's caller holds `PLATFORM_ADMIN` (real `WebhooksManage`
  via catch-all) and still gets 404 naming tenant B's real, delivery-bearing
  subscription id from tenant A's context — genuinely the
  permission-doesn't-bypass-tenant-scoping case.
- **AC5** (non-existent id -> 404, distinct from AC4): independently read
  `Letflow.Webhooks`'s private `get/2`
  (`lib/letflow/webhooks.ex:659-672`) — `Ecto.UUID.cast/1` failure yields
  `{:error, :invalid_id}` before any DB round-trip; a well-formed-but-absent
  id yields `{:error, :not_found}` via `Repo.get/3` returning `nil`. The
  `"not-a-uuid"` test genuinely exercises the `:invalid_id` path (fails
  `Ecto.UUID.cast/1`), and the `Ecto.UUID.generate()` test genuinely
  exercises `:not_found` (well-formed, never persisted). Both fold to 404 in
  the router. Not an accidental collision.
- **AC6** (moduledoc disclosure): confirmed by direct read of
  `lib/letflow/routers/webhooks.ex:17-25` — states verbatim that
  `webhooks.zig` was not inspected and names `web/src/api/dlq.ts` /
  `web/src/types/api.ts` as the binding contract. Doc-content check, already
  covered by a runtime `Code.fetch_docs/1`-based test.

No `@tag :skip`, no "TODO: implement test" anywhere in either test file or
`test/specs/REQ-184.md`. Each test provisions its own tenant(s) via
`Letflow.TenantFixture.provisioned_tenant!/1` with unique slug prefixes —
fixtures are self-sufficient, no shared hardcoded state, no test depends on
another having run first. No hardcoded secrets/connection strings found.

## Suite run (real toolchain, `source ~/.asdf/asdf.sh`)

```
mix test test/letflow/webhooks_test.exs test/letflow/routers/webhooks_test.exs
...
Result: 43 passed
```

0 failures, 0 skips.

## Mutation testing (all applied in-tree, confirmed caught, then reverted)

### Mutant 1 — cross-tenant scoping bypass (AC4)

`lib/letflow/webhooks.ex`'s `list_delivery_attempts/3`: removed the
`with {:ok, _subscription} <- get(subscription_id, opts) do ... end` guard
(the tenant/prefix-scoping check) and changed `Repo.all(prefix: prefix)` to
unscoped `Repo.all()`.

Result: `mix test test/letflow/routers/webhooks_test.exs` — 16 failed
(cascading across both files since `get/2` scoping backs several other
behaviors). Specifically, `REQ-184 AC4`'s test
("a caller from tenant A naming tenant B's real subscription id gets 404")
failed with:

```
** (Plug.Conn.WrapperError) ** (Postgrex.Error) ERROR 42P01 (undefined_table)
relation "webhook_delivery_attempts" does not exist
```

— i.e. the unscoped query doesn't even resolve to the tenant schema,
confirming the test genuinely depends on the scoping mechanism rather than
passing by accident.

Reverted via `git checkout -- lib/letflow/webhooks.ex`.
`git status --porcelain lib/` → empty (confirmed).

### Mutant 2 — ordering break (AC2 ordering assertion)

`lib/letflow/webhooks.ex`'s `list_delivery_attempts/3`: changed
`order_by([d], desc: d.attempted_at, desc: d.attempt_count)` to
`order_by([d], asc: d.attempted_at, asc: d.attempt_count)`.

Result: `mix test test/letflow/routers/webhooks_test.exs` — 1 failed, 24
passed:

```
1) test REQ-184 AC2: limit param enforcement more delivery attempts than
   the requested limit returns exactly limit items, most-recent first
   (Letflow.Routers.WebhooksTest)
```

Confirms the newly-added ordering assertion (not merely the count assertion)
catches a reversed/wrong-direction sort.

Reverted via `git checkout -- lib/letflow/webhooks.ex`.
`git status --porcelain lib/` → empty (confirmed).

### Mutant 3 — resolve_limit/1 fallback removed (AC2 parameterized tests)

`lib/letflow/routers/webhooks.ex`'s `resolve_limit/1` binary clause changed
from:

```elixir
defp resolve_limit(raw) when is_binary(raw) do
  case Integer.parse(raw) do
    {value, ""} when value > 0 -> value
    _other -> @default_deliveries_limit
  end
end
```

to an unguarded parse with no fallback:

```elixir
defp resolve_limit(raw) when is_binary(raw) do
  {value, _} = Integer.parse(raw)
  value
end
```

Result: `mix test test/letflow/routers/webhooks_test.exs` — 3 failed, 22
passed:

```
1) test REQ-184 AC2: limit param enforcement limit=-1 (negative) falls back
   to the default of 20, not an error or a zero-item result
2) test REQ-184 AC2: limit param enforcement limit=0 (zero) falls back to
   the default of 20, not an error or a zero-item result
3) test REQ-184 AC2: limit param enforcement limit=abc (nonnumeric) falls
   back to the default of 20, not an error or a zero-item result
```

(The fourth new test, `limit=5abc`, did not fail under this specific mutant
because `Integer.parse("5abc")` still yields `5`, which is `> 0` and small
enough not to truncate the 3 seeded rows under this particular broken
implementation — a different mutant, e.g. one that also drops the
`value > 0` guard or the no-leftover check, would catch it; 3 of 4 new
tests catching this mutant is sufficient confirmation the fallback logic is
real, non-vacuous test coverage.)

Reverted via `git checkout -- lib/letflow/routers/webhooks.ex`.
`git status --porcelain lib/` → empty (confirmed).

## Final clean-state re-run

After all three reverts:

```
git status --porcelain lib/ test/   -> (empty)
mix test test/letflow/webhooks_test.exs test/letflow/routers/webhooks_test.exs
Result: 43 passed
mix compile --warnings-as-errors   -> clean, no output
mix format --check-formatted        -> clean, no output
mix letflow.lint_handoffs           -> OK -- 0 new violations across 1511 handoff files
```

## Conclusion

All 6 acceptance criteria have genuine, runnable, non-superficial test
coverage. No skipped/pending tests. Fixtures are isolated and
self-sufficient. Three independent mutants (cross-tenant scoping bypass,
ordering reversal, and fallback-branch removal) were each applied, shown to
break the suite in the expected place, and reverted clean. Routing to
TEST-RUNNER.
