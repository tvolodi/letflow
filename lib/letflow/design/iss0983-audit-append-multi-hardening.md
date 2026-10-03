# ISS-0983 — rescue-hardening eight `Audit.append_multi/4`-wrapped transaction sites

Design for closing ISS-0983: eight functions (six in `lib/letflow/identity.ex`, one in
`lib/letflow/repository/activation.ex`, one in `lib/letflow/public_read.ex`) each fold
`Letflow.Audit.append_multi/4` (`lib/letflow/audit.ex:181-190`) into their own
`Ecto.Multi`, then call `Repo.transaction/1` on the combined `Multi`, with no
function-level `rescue` anywhere in the call chain. `append_multi/4` is a thin
`Multi.run/3` wrapper around `insert_entry/3` — the same function ISS-0981 just
rescue-hardened at six *other* call sites that call `insert_entry/3` directly inside
their own `Repo.transaction/1`. The defect class is identical: a genuine raise from
`insert_entry/3` (the `Postgrex.Error`/`undefined_table` class ISS-0969/ISS-0980/
ISS-0981's own `DROP TABLE audit_entries` fault-injection tests reproduce) has no
`Multi`-level catch — `Multi.run/3`'s callback has no rescue of its own, and
`Repo.transaction/1` only intercepts a `{:error, _}` *return* from a step, not a raise
— so it propagates uncaught through `Repo.transaction/1`, out of the owning context
function, out of its router-reachable caller, to `Plug.ErrorHandler`'s cleanup-only
passthrough boundary (`lib/letflow/plugs/api_pipeline.ex`, already traced by ISS-0980's
own design §1 and ISS-0981's own design intro — it releases an admission ref and
re-raises, it does not translate), producing a raw, unstructured 500 instead of the
typed `{:error, {:transaction_failed, exception}}` shape `Letflow.Definitions.activate/2`
and ISS-0981's six sites already return in this exact situation.

ISSUE-FIXER has already confirmed all eight candidates as live, router-reachable gaps
(per ISS-0983's handoff). This design does not re-derive that trace; it designs the fix
shape, the `@spec` changes, the regression tests, and the `tasks.ex` moduledoc
correction (AC3).

**Important divergence from ISS-0981's own propagation story, found by direct read of
every router call site below:** ISS-0981's six sites all propagated their new
`{:error, {:transaction_failed, exception}}` tuple through an already-existing
catch-all clause with zero router code change. That is **not** true here for seven of
these eight sites — every `identity.ex` router handler and
`public_read_handles.ex`'s `handle_issue/1` builds an exhaustive, catch-all-free
`case`/pattern match over its callee's today-finite error union, so introducing a new
tuple shape without also adding a matching clause would produce a `CaseClauseError`
(a *worse* outcome than today's uncaught raise reaching `Plug.ErrorHandler` — still a
500, but from a different, newly-introduced crash site the fix itself would have
created). Only `activate_group/5` (§1g), whose result flows through
`Letflow.Entities.Definitions.activate_definition/4` into
`lib/letflow/routers/entities.ex`'s `render_activate_definition/2`, already has a
catch-all. Every other site's own subsection below states the exact new router clause
required; §2 gives the consolidated list.

## 1. Fix shape — identical to ISS-0981's, applied at eight sites

Exactly the shape `lib/letflow/definitions.ex`'s `activate/2` already establishes and
ISS-0981 applied at its six sites: a function-level `try ... rescue exception ->
{:error, {:transaction_failed, exception}} end` wrapping the function's *entire*
existing body, unmodified inside the `try`. No other line of logic changes. Every one
of the eight sites below has its own `Repo.transaction()`/`Repo.transaction(fn -> ...
end)` call positioned such that nothing meaningful runs after it on the normal
success/typed-error path (the transaction's own `|> case do ... end` immediately
follows it and *is* the function's return value) — so wrapping the whole body has the
same effect as wrapping only the transaction call, with zero risk of swallowing an
exception from code that should remain unprotected (same reasoning ISS-0981 §2 already
established, reused here rather than re-derived per-site below).

The returned tuple reuses the exact `{:transaction_failed, exception}` tag — never a
new or differently-named tag, matching every prior fix in this arc (ISS-0969, ISS-0980,
ISS-0981).

### 1a. `Letflow.Identity.create_user/2` (`lib/letflow/identity.ex:224-269`)

Wrap the function's entire body (lines 224-269: changeset build through the final
`Repo.transaction() |> case do ... end`) in `try/rescue`. `@spec` gains
`| {:error, {:transaction_failed, Exception.t()}}` appended to the existing union:

```
@spec create_user(attrs :: map(), opts :: opts()) ::
        {:ok, User.t()}
        | {:error, :duplicate_username}
        | {:error, Ecto.Changeset.t()}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — confirmed NOT a no-op**, same finding as §1h below for
`issue_handle/4`: `lib/letflow/routers/identity.ex:266-278`'s `handle_create/2` has an
exhaustive, catch-all-free `case Identity.create_user(attrs, opts) do {:ok, user} ->
...; {:error, :duplicate_username} -> ...; {:error, %Ecto.Changeset{}} -> ... end`
(lines 272-276) — verified by direct read, no fourth clause. Adding
`{:error, {:transaction_failed, exception}}` to `create_user/2`'s return union without
also touching this `case` produces a `CaseClauseError` here instead of the intended
typed response. ELIXIR-DEV MUST add a fourth clause, matching the pattern
`{:error, {:transaction_failed, _exception}}` and calling `Response.internal_error/1`
on `conn`, placed after the existing three clauses (`{:ok, user}`,
`{:error, :duplicate_username}`, `{:error, %Ecto.Changeset{}}`) as the new catch for
this previously-impossible return shape.

This same pattern — no pre-existing catch-all, a new clause required — repeats at
every one of this design's six `identity.ex` sites and at `issue_handle/4`; only
`activate_group/5` (§1g) propagates through an already-existing catch-all. See the
consolidated router-change list in §2.

### 1b. `Letflow.Identity.update_user_profile/3` (`lib/letflow/identity.ex:327-363`)

This function is a `case Repo.get(User, id, prefix: prefix) do nil -> ...; %User{} =
user -> <Multi/transaction pipeline> end`. The `rescue` must wrap only the `%User{} =
user ->` branch's body (the `Multi.new() |> ... |> Repo.transaction() |> case do ...
end` expression, lines ~338-361) — **not** the outer `case`'s `nil ->
{:error, :not_found}` branch, which has no transaction and must keep returning
`{:error, :not_found}` exactly as today, uninvolved in this fix. Concretely: add
`try`/`rescue` immediately inside the `%User{} = user ->` clause, around its existing
body, exactly mirroring ISS-0981's §2c treatment of `persist_timer_fired_advance/7`
being one `case`-branch-scoped `Repo.transaction` call. `@spec` gains the same member:

```
@spec update_user_profile(id :: Ecto.UUID.t(), attrs :: map(), opts :: opts()) ::
        {:ok, User.t()}
        | {:error, :not_found}
        | {:error, Ecto.Changeset.t()}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — new clause required.**
`lib/letflow/routers/identity.ex:372-390`'s `handle_patch/3` has its own inner,
catch-all-free `case Identity.update_user_profile(id, attrs, opts) do {:ok, user} ->
...; {:error, %Ecto.Changeset{}} -> ...; {:error, :not_found} -> ... end` (lines
383-387) — verified by direct read. Add a fourth clause,
`{:error, {:transaction_failed, _exception}} -> Response.internal_error(conn)`.

### 1c. `Letflow.Identity.update_user_status/3` (`lib/letflow/identity.ex:372-408`)

Identical shape and identical caveat to 1b — same `case Repo.get(...) do nil -> ...;
%User{} = user -> <Multi/transaction> end` structure (lines 379-407). Wrap only the
`%User{} = user ->` branch's body. `@spec` gains the same member:

```
@spec update_user_status(id :: Ecto.UUID.t(), status :: :active | :inactive, opts :: opts()) ::
        {:ok, User.t()}
        | {:error, :not_found}
        | {:error, Ecto.Changeset.t()}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — new clause required.**
`lib/letflow/routers/identity.ex:403-423`'s `handle_status_update/3` has its own
inner, catch-all-free `case Identity.update_user_status(id, status, opts) do
{:ok, user} -> ...; {:error, %Ecto.Changeset{}} -> ...; {:error, :not_found} -> ...
end` (lines 416-420) — verified by direct read. Add a fourth clause,
`{:error, {:transaction_failed, _exception}} -> Response.internal_error(conn)`.

### 1d. `Letflow.Identity.create_group/2` (`lib/letflow/identity.ex:431-471`)

Same shape as 1a — no preceding `case`, the whole body is the changeset build plus the
`Multi`/`Repo.transaction()` pipeline. Wrap the entire function body. `@spec`:

```
@spec create_group(attrs :: map(), opts :: opts()) ::
        {:ok, Group.t()}
        | {:error, :duplicate_group_name}
        | {:error, Ecto.Changeset.t()}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — new clause required.**
`lib/letflow/routers/identity.ex:452-464`'s `handle_create_group/2` has its own
inner, catch-all-free `case Identity.create_group(attrs, opts) do {:ok, group} -> ...;
{:error, :duplicate_group_name} -> ...; {:error, %Ecto.Changeset{}} -> ... end` (lines
458-462) — verified by direct read. Add a fourth clause,
`{:error, {:transaction_failed, _exception}} -> Response.internal_error(conn)`.

### 1e. `Letflow.Identity.insert_token/3` (private, `lib/letflow/identity.ex:1248-1291`)

**The rescue goes on `insert_token/3` only, not on `create_token/3`.** `create_token/3`
(`lib/letflow/identity.ex:1213-1226`) has its own early, legitimate non-transactional
returns — `{:error, :user_not_found}` from the `Repo.get` branch, and
`{:error, :invalid_role_set}`/`{:error, :expires_at_in_past}` from its `with` chain's
validation steps — none of which touch `Repo.transaction/1` at all; wrapping
`create_token/3`'s body in `try/rescue` would be over-broad (harmless in practice since
none of those steps can raise today, but it blurs the boundary ISS-0983's own handoff
explicitly calls out, and diverges from this design's own "wrap only the transaction
site" discipline applied everywhere else). Wrap only `insert_token/3`'s entire body
(the plaintext/hash/changeset build through the final `Repo.transaction() |> case do
... end`, lines 1248-1291).

`insert_token/3` has no `@spec` today (private function, consistent with this module's
existing style for internal helpers — same precedent ISS-0981's OQ-2 established for
`engine.ex`'s un-`@spec`'d private Multi builders). This design does not add one, for
the same reason: that would be a stylistic change outside this issue's scope.
`create_token/3`'s own public `@spec` (lines 1207-1212) DOES need the new member, since
`insert_token/3`'s new `{:error, {:transaction_failed, exception}}` return propagates
unchanged through `create_token/3`'s own `with ... do insert_token(user_id, attrs,
prefix) end` tail call:

```
@spec create_token(user_id :: Ecto.UUID.t(), attrs :: create_token_attrs(), opts :: opts()) ::
        {:ok, %{token: ApiToken.t(), plaintext: String.t()}}
        | {:error, :user_not_found}
        | {:error, :invalid_role_set}
        | {:error, :expires_at_in_past}
        | {:error, Ecto.Changeset.t()}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — new clause required.**
`lib/letflow/routers/identity.ex:603-636`'s `handle_create_token/2` has its own
inner, catch-all-free `case Identity.create_token(user_id, %{...}, opts) do
{:ok, %{token: token, plaintext: plaintext}} -> ...; {:error, :user_not_found} -> ...;
{:error, :invalid_role_set} -> ...; {:error, :expires_at_in_past} -> ...;
{:error, %Ecto.Changeset{}} -> ... end` (lines 614-633) — verified by direct read, five
clauses, no catch-all. Add a sixth clause,
`{:error, {:transaction_failed, _exception}} -> Response.internal_error(conn)`.

### 1f. `Letflow.Identity.revoke_token/2` (`lib/letflow/identity.ex:1327-1371`)

Same shape/caveat as 1b/1c: `case Repo.get(ApiToken, token_id, prefix: prefix) do nil ->
...; %ApiToken{revoked_at: revoked_at} = token when not is_nil(revoked_at) -> ...;
%ApiToken{} = token -> <Multi/transaction> end` (three branches). Wrap only the final
`%ApiToken{} = token ->` branch's body (lines 1337-1370) — the `nil ->` and
already-revoked idempotent-return branches have no transaction and must stay
untouched. `@spec`:

```
@spec revoke_token(token_id :: Ecto.UUID.t() | String.t(), opts :: opts()) ::
        {:ok, ApiToken.t()}
        | {:error, :not_found}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — new clause required.**
`lib/letflow/routers/identity.ex:657-662`'s `handle_revoke_token/3` has its own
catch-all-free `case Identity.revoke_token(id, opts) do {:ok, token} -> ...;
{:error, :not_found} -> ... end` (lines 658-661) — verified by direct read, two
clauses, no catch-all. Add a third clause,
`{:error, {:transaction_failed, _exception}} -> Response.internal_error(conn)`.

### 1g. `Letflow.Repository.Activation.activate_group/5` (`lib/letflow/repository/activation.ex:262-309`)

The `Audit.append_multi/4` call sits inside `add_activation_steps/9`'s `Multi.merge/2`
callback (line 413), which is itself invoked only while `activate_group/5` is building
its `Multi` — before `Repo.transaction()` is ever called (line 303). So the raise's
possible origin is wider than the other seven sites: it is not only a possible raise
*from inside* `Repo.transaction()`'s callback execution but could, in principle, also
originate from `Enum.reduce/3`'s own `Multi`-building loop (lines 284-300) that calls
`add_activation_steps/9`, since `Multi.merge/2`'s second argument is itself a function
not evaluated until `Repo.transaction/1` runs it — confirm during implementation that
`Multi.merge/2`'s callback indeed only runs inside `Repo.transaction/1`'s own execution,
not at `Multi.merge/2`-call time (this is `Ecto.Multi`'s documented, standard
lazy-callback behavior, so no surprise is expected, but it determines whether the
`rescue` needs to extend earlier than the `multi |> Repo.transaction() |>
format_activate_group_result(...)` line). Per the same ISS-0981 §2 "wrap the whole
body" discipline, this is moot either way: wrap `activate_group/5`'s **entire** `with
... do ... end` body (lines 263-308, i.e. from the `with :ok <- validate_non_empty_group...`
line through the final `if group_changeset.valid? do ... else ... end`) in `try/rescue`
— this covers every possible raise origin inside the function regardless of exactly
which sub-step triggers it, with no change to the `with`'s own early-return branches
(`{:error, :empty_group}`, `{:error, :duplicate_artifact_in_group}`,
`{:error, :invalid_schema_name}` from `TenantProvisioning.tenant_id_for_schema_name/1`)
since none of those can raise today and the `rescue` only ever fires on an actual raise,
never altering a normal `{:error, _}` return's shape.

`@spec` gains the new member:

```
@spec activate_group(
        [activation_input()],
        Ecto.UUID.t(),
        String.t(),
        String.t(),
        keyword()
      ) ::
        {:ok, activate_group_result()}
        | {:error, :empty_group}
        | {:error, :duplicate_artifact_in_group}
        | {:error, :invalid_schema_name}
        | {:error, {:group, Ecto.Changeset.t()}}
        | {:error, {atom(), Ecto.Changeset.t()}}
        | {:error, {:transaction_failed, Exception.t()}}
```

Propagation, confirmed already correctly handled, no router change needed:
`Letflow.Entities.Definitions.activate_definition/4`'s own `with {:ok, entity_definition}
<- get_definition_by_name(name, prefix), {:ok, _result} <- Activation.activate_group(...),
{:ok, promoted} <- promote_and_demote_siblings(...) do ... end`
(`lib/letflow/entities/definitions.ex:410-429`) passes any unmatched `{:error, _}` from
`Activation.activate_group/5` straight through as `activate_definition/4`'s own return
value, unchanged — verified by reading the full `with` (no `{:error, {_tag, Ecto.Changeset.t()}}`-
shaped catch clause that could misfire on this new tuple; `{:transaction_failed,
Exception.t()}` does not match `{atom(), Ecto.Changeset.t()}` since its second element
is an `Exception.t()`, not a `Ecto.Changeset.t()`). `lib/letflow/routers/entities.ex`'s
`render_activate_definition/2` (lines 783-803) already has a catch-all,
`defp render_activate_definition(conn, {:error, _common_error}), do: Response.internal_error(conn)`
(line 802-803) — verified it sits after every specific clause and before no other
matching clause, so it correctly catches the new tuple. `activate_definition/4`'s own
`@spec` (lines 396-409) should also gain the new member for documentation parity
(it currently ends `| {:error, {atom(), Ecto.Changeset.t()}}`, which, as just noted,
does not already cover `{:transaction_failed, Exception.t()}`):

```
@spec activate_definition(
        name :: String.t(),
        activator_user_id :: Ecto.UUID.t(),
        rationale :: String.t(),
        prefix :: String.t()
      ) ::
        {:ok, EntityDefinition.t()}
        | {:error, :not_found}
        | {:error, :empty_group}
        | {:error, :duplicate_artifact_in_group}
        | {:error, :invalid_schema_name}
        | {:error, {:group, Ecto.Changeset.t()}}
        | {:error, {:persistence, Ecto.Changeset.t()}}
        | {:error, {atom(), Ecto.Changeset.t()}}
        | {:error, {:transaction_failed, Exception.t()}}
```

### 1h. `Letflow.PublicRead.issue_handle/3` (public arity is actually `/4` — see note below; `lib/letflow/public_read.ex:52-99`)

**The rescue must wrap only lines 75-98** (the
`Multi.new() |> Multi.insert(...) |> Multi.merge(...) |> Repo.transaction() |> case do
... end` expression) — **explicitly excluding lines 53-61**, the
`case TenantProvisioning.schema_name_for_tenant(tenant_id) do {:ok, prefix} -> prefix;
{:error, :invalid_tenant_id} -> raise ArgumentError, ... end` block. That `raise` is
documented in this module's own moduledoc (lines 36-42: "an invalid `tenant_id` here
indicates a caller bug ... so that case raises rather than being folded into
`{:error, _}`") as a deliberate, intentional caller-bug detector — it must keep raising
uncaught, exactly as today. Concretely: leave the `prefix = case ... end` assignment
(lines 53-61) and the `plaintext`/`handle_hash`/`changeset` builds (lines 63-73)
outside any `try`, and wrap only the final `Multi.new() |> ... |> Repo.transaction() |>
case do ... end` pipeline (lines 75-98) in its own `try/rescue`.

Note on arity: the function is `issue_handle/4` (`tenant_id, kind, resource_id, opts \\
[]`) — the module's own moduledoc (line 33) and `PublicReadFixtureSupport`'s doc both
call it `issue_handle/4` consistently; ISS-0983's handoff text says "`issue_handle/3`"
in one place, evidently referring to the 3 required positional arguments before the
defaulted `opts`, not a distinct `/3` clause. There is only one function clause,
`def issue_handle(tenant_id, kind, resource_id, opts \\ [])`, arity 4. ELIXIR-DEV should
treat "`issue_handle/3`" in the issue title as this same `/4` function.

`@spec` gains the new member:

```
@spec issue_handle(
        tenant_id :: Ecto.UUID.t(),
        kind :: String.t(),
        resource_id :: Ecto.UUID.t(),
        opts :: issue_opts()
      ) ::
        {:ok, %{handle: String.t(), record: Handle.t()}}
        | {:error, Ecto.Changeset.t()}
        | {:error, {:transaction_failed, Exception.t()}}
```

**Router propagation — new clause required** (same pattern as every `identity.ex` site
above, see the intro's "Important divergence" note).
`lib/letflow/routers/public_read_handles.ex:43-58`'s `handle_issue/1` is the sole
router caller, and its `case PublicRead.issue_handle(...) do ... end` (lines 51-57)
has exactly two clauses today — `{:ok, %{handle: plaintext}} -> Response.created(...)`
and `{:error, %Ecto.Changeset{}} -> Response.bad_request(...)` — **no catch-all
clause**. Adding `{:error, {:transaction_failed, exception}}` to `issue_handle/4`'s
return union without also touching this `case` would make a real, previously-impossible
value reach this `case` with no matching clause, raising `CaseClauseError` here instead
of returning the typed error — defeating the whole point of this fix at this one site.
ELIXIR-DEV MUST add a third clause here, matching the pattern
`{:error, {:transaction_failed, _exception}}` and calling `Response.internal_error/1`
on `conn`, placed after the existing two clauses (`{:ok, %{handle: plaintext}}`,
`{:error, %Ecto.Changeset{}}`) as the new catch for this previously-impossible return
shape — matching this codebase's established `Response.internal_error/1` convention
for an unstructured/transaction-level failure (the same response every other site's
new clause produces for this tuple shape).

## 2. `@spec` and router-change summary table

| Site | File | Public/private | `@spec` change | Router change required |
|---|---|---|---|---|
| `create_user/2` | identity.ex | public | add member | yes — new clause, `routers/identity.ex:272-276` (`handle_create/2`) |
| `update_user_profile/3` | identity.ex | public | add member | yes — new clause, `routers/identity.ex:383-387` (`handle_patch/3`) |
| `update_user_status/3` | identity.ex | public | add member | yes — new clause, `routers/identity.ex:416-420` (`handle_status_update/3`) |
| `create_group/2` | identity.ex | public | add member | yes — new clause, `routers/identity.ex:458-462` (`handle_create_group/2`) |
| `insert_token/3` | identity.ex | private, no `@spec` | none (style precedent, see §1e) | n/a (not itself router-called) |
| `create_token/3` | identity.ex | public | add member (propagates from `insert_token/3`) | yes — new clause, `routers/identity.ex:614-633` (`handle_create_token/2`) |
| `revoke_token/2` | identity.ex | public | add member | yes — new clause, `routers/identity.ex:658-661` (`handle_revoke_token/3`) |
| `activate_group/5` | repository/activation.ex | public | add member | **no** — propagates through `render_activate_definition/2`'s existing catch-all |
| `activate_definition/4` | entities/definitions.ex | public | add member (propagates from `activate_group/5`) | no (same reason) |
| `issue_handle/4` | public_read.ex | public | add member | yes — new clause, `routers/public_read_handles.ex:51-57` (`handle_issue/1`) |

Seven new router `case` clauses total, all identical in shape and response
(`{:error, {:transaction_failed, _exception}} -> Response.internal_error(conn)`), one
per row marked "yes" above. ELIXIR-DEV should add each as the new last clause of its
named `case`, matching this codebase's existing ordering convention of
specific-then-generic clauses (every other `defp handle_*`/`defp render_*` function in
these two router files already orders its own clauses this way).

## 3. Regression tests (ISS-0983 acceptance criterion 2) — exact files/describe blocks

All reuse the identical `Repo.query!(~s(DROP TABLE "#{schema_name}".audit_entries))`
fault-injection technique already established and verified present by direct read in
`test/letflow/audit_capture_test.exs`'s `"AC3 -- an audit-write failure rolls back the
accompanying mutation"` describe block (line 268) and `test/letflow/engine_test.exs`'s
`"ISS-0969: ..."` describe block, same `on_exit` DDL-recreate shape ISS-0981's design
§4 already specified.

### 3a. Six `Letflow.Identity` sites — `test/letflow/audit_dispositions_test.exs`

This file (not `test/letflow/identity_test.exs`) is the verified, existing precedent
for testing these six functions directly against `Letflow.Identity` with a real
provisioned tenant: its `describe "actor_id: nil disposition -- Letflow.Identity"` block
(lines 404-513) already exercises `create_user/2`, `update_user_profile/3`,
`update_user_status/3`, `create_group/2`, `create_token/3`, and `revoke_token/2` in
that exact order, using this file's own `provisioned_tenant/0` (lines 65-103,
`TenantFixture.provisioned_tenant!/1` + its own `SandboxAutoMode`-aware `on_exit`) and
`unique_name/1` (line 105) helpers. `test/letflow/identity_test.exs` was checked and
does **not** test `create_user/2`/`update_user_profile/3`/`update_user_status/3`/
`create_group/2` at all (confirmed — its own describe-block list covers
`provision_oidc_user/4`, `Tenant` changesets, `safe_get_tenant_by_slug/2`,
`create_token/3`/`list_tokens/1`/`revoke_token/2`, `sync_role_claims_from_token/3`,
nothing else); `create_token/3`'s identity_test.exs coverage is REQ-076's own
happy/validation-path tests, a different concern from this fault-injection coverage.

Add a new describe block, `"ISS-0983: Letflow.Identity write paths are
rescue-hardened against a Postgres-level audit-write failure"`, immediately after the
existing `"actor_id: nil disposition -- Letflow.Identity"` block (after line 513), one
test per function:

1. **`create_user/2`**: `provisioned_tenant()`, `DROP TABLE
   "#{schema_name}".audit_entries`, call `Identity.create_user(%{"username" =>
   unique_name(...), "display_name" => ..., "email" => ...}, prefix: schema_name)`,
   assert `{:error, {:transaction_failed, %Postgrex.Error{}}} = result`, then assert
   zero `User` rows exist in `schema_name` for that username (the insert rolled back,
   not just the audit insert) — `Repo.aggregate(from(u in Letflow.Identity.User, where:
   u.username == ^username), :count, prefix: schema_name) == 0`.
2. **`update_user_profile/3`**: create a user first (table still intact), THEN drop
   `audit_entries`, call `update_user_profile(user.id, %{"display_name" => "New Name"},
   prefix: schema_name)`, assert `{:error, {:transaction_failed, %Postgrex.Error{}}}`,
   then re-fetch the user (`Repo.get!(User, user.id, prefix: schema_name)`) and assert
   `display_name` is still the ORIGINAL value, not `"New Name"` — the update rolled
   back.
3. **`update_user_status/3`**: same shape — create user (table intact, default
   `:active`), drop table, call `update_user_status(user.id, :inactive, prefix:
   schema_name)`, assert `{:error, {:transaction_failed, %Postgrex.Error{}}}`, re-fetch
   and assert `status == :active` still (not `:inactive`).
4. **`create_group/2`**: same shape as (1) — drop table, call `create_group(%{"name" =>
   unique_name(...)}, prefix: schema_name)`, assert `{:error, {:transaction_failed,
   %Postgrex.Error{}}}`, assert zero `Group` rows for that name afterward.
5. **`create_token/3`** (exercising `insert_token/3`'s own rescue): create a user
   first (table intact), drop table, call `create_token(user.id, %{roles:
   ["TASK_WORKER"], expires_at: nil}, prefix: schema_name)`, assert
   `{:error, {:transaction_failed, %Postgrex.Error{}}}`, assert zero `ApiToken` rows
   exist for that `user_id` afterward.
6. **`revoke_token/2`**: create a user and a token first (table intact), drop table,
   call `revoke_token(token.id, prefix: schema_name)`, assert
   `{:error, {:transaction_failed, %Postgrex.Error{}}}`, re-fetch the token
   (`Repo.get!(ApiToken, token.id, prefix: schema_name)`) and assert `revoked_at` is
   still `nil` (not set) — the revoke rolled back.

Each test needs its own `on_exit` to recreate `audit_entries` with the same DDL
`test/letflow/engine_test.exs`'s own `"ISS-0969"` describe block uses (confirm the
exact column/constraint list by reading that file directly before writing the DDL
literal — do not guess at it), following this arc's established
no-shared-test-helper convention (each test file inlines its own copy, per ISS-0981's
design §4 precedent and this file's own DIRECTIVE T-4 self-sufficiency statement).

### 3b. `activate_group/5` — `test/letflow/repository/activation_test.exs`

New describe block, `"ISS-0983: activate_group/5 is rescue-hardened against a
Postgres-level audit-write failure"`, placed near the existing `"audit_entries
cross-write"` describe block (line 879) since both concern this function's
`audit_entries` interaction. Uses this file's own `provisioned_tenant/0` (line 98,
`TenantFixture.provisioned_tenant!/1`) and `new_version!/3`/`activation_input/1`
helpers (lines 108-139) — no new fixture shape invented.

Test: provision a tenant, create one `artifact_versions` row via `new_version!/3`,
`Repo.query!` a `DROP TABLE "#{schema}".audit_entries`, call
`Activation.activate_group([activation_input(version)], Ecto.UUID.generate(),
"iss0983 fault injection", schema)`, assert `{:error, {:transaction_failed,
%Postgrex.Error{}}} = result`, then assert:
- `Repo.aggregate(ActivationGroup, :count, prefix: schema) == 0` (the group envelope
  row rolled back)
- `Activation.resolve(:definition, <the artifact name>, schema) == {:error,
  :not_activated}` (the activation pointer itself never committed — mirrors this
  file's own AC1 "forced-failure rollback" test's `Activation.resolve/3`-based
  assertion idiom, lines 197-256, rather than inventing a new verification idiom)
- `Repo.aggregate(ActivationHistory, :count, prefix: schema) == 0` (no history row
  either)

**Do not** add a post-DROP call to `Letflow.Routers.Audit`'s `list_entries/1` or any
other query against `audit_entries` itself — that query path has no rescue of its own
and would raise against the dropped table (the exact mistake ISS-0980's design was
FAILed for, and ISS-0981's design §4 item 1 explicitly calls out avoiding).

### 3c. `issue_handle/4` — `test/letflow/public_read_test.exs`

New describe block, `"ISS-0983: issue_handle/4 is rescue-hardened against a
Postgres-level audit-write failure"`, placed after the existing `"AC-2"` describe
block (line 66-77) since both concern `issue_handle/4`'s own persistence behavior.
Uses this file's own `PublicReadFixtureSupport.provision_tenant!/0` (returns
`TenantFixture.tenant_fixture()`, carrying `schema_name`) and `kind/0` helpers — no
new fixture invented.

Test: `%{tenant_id: tenant_id, schema_name: schema_name} =
PublicReadFixtureSupport.provision_tenant!()`, `Repo.query!` a `DROP TABLE
"#{schema_name}".audit_entries`, call `PublicRead.issue_handle(tenant_id,
PublicReadFixtureSupport.kind(), Ecto.UUID.generate())`, assert
`{:error, {:transaction_failed, %Postgrex.Error{}}} = result`, then assert zero
`Letflow.PublicRead.Handle` rows exist in `schema_name` afterward (the handle insert
rolled back along with the audit failure) —
`Repo.aggregate(Letflow.PublicRead.Handle, :count, prefix: schema_name) == 0`.

This test must use a syntactically valid, real `tenant_id` (from
`provision_tenant!/0`'s own return) so it exercises the `{:ok, prefix} -> prefix`
branch of `issue_handle/4`'s own `case` (lines 54-56), never the `ArgumentError` raise
branch (lines 58-60) — that branch is explicitly out of scope for this fix (§1h above)
and must keep raising uncaught; a new test here must not accidentally exercise or
assert on it.

### Common invariant for all three groups (3a/3b/3c)

Every new test asserts BOTH the typed `{:error, {:transaction_failed,
%Postgrex.Error{}}}` return AND a rollback check (zero rows / original value
unchanged) — proving not just "the raise was caught" but "the whole transaction,
including the primary mutation, rolled back together with the audit-write failure,"
matching ISS-0981's own design §4's stated proof-obligation shape for every one of its
six tests. Confirm the exact exception struct name (`%Postgrex.Error{}` vs. a different
Ecto-level wrapper) during implementation by running the fault-injection test first,
rather than guessing — same open-question discipline ISS-0980's/ISS-0981's own designs
both flagged.

## 4. AC3 — `lib/letflow/tasks.ex`'s moduledoc "Error handling" section correction

`lib/letflow/tasks.ex:109-116`'s "## Error handling — matches this project's
established residual-risk precedent" section currently reads (verified by direct
read):

> Every function below returns `{:ok, _} | {:error, atom}` for its *expected* failure
> modes (invalid UUID, not found, malformed cursor). A genuine DB/connection-level
> failure is not caught and converted anywhere in this module — it propagates as a
> raised exception, matching `Letflow.Identity`'s own established precedent for simple
> reads rather than inventing a new blanket-rescue policy here.

Once this issue's fix lands, `Letflow.Identity`'s own *write* paths (`create_user/2`,
`update_user_profile/3`, `update_user_status/3`, `create_group/2`, `create_token/3` via
`insert_token/3`, `revoke_token/2`) are all rescue-hardened — only its *read* paths
(`list_users/2`, `get_user/2`, `list_groups/1`, `list_group_members/3`,
`list_tokens/1`, `verify_api_token/2`, `resolve_tenant_by_realm/1`, etc.) remain
un-rescued, matching `tasks.ex`'s own read functions
(`get_task/2`/`list_tasks/2`/`resolve_principal_scope/2`). `tasks.ex`'s own
`assign_task/3`/`reassign_task/4` are WRITE functions (each builds an `Ecto.Multi`
with its own `Audit.append_multi/4` step, per ISS-0983's own description, and is left
deliberately un-rescued by this issue) — so the moduledoc's claim that this is
"matching `Letflow.Identity`'s own established precedent" is no longer accurate for
those two functions specifically: there is no longer any un-rescued *write*-path
precedent on `Letflow.Identity` for them to match. The claim remains accurate only for
`tasks.ex`'s three *read* functions.

**Required correction** (no behavior change to `tasks.ex` itself — ELIXIR-DEV must not
add a `rescue` to `assign_task/3`/`reassign_task/4` as part of this fix; that is a
separate, not-yet-made decision per ISS-0983's own acceptance criterion 3 wording):
replace the final sentence of that paragraph (currently ending "...matching
`Letflow.Identity`'s own established precedent for simple reads rather than inventing a
new blanket-rescue policy here.") with wording that:

1. States plainly that this module's three *read* functions
   (`get_task/2`/`list_tasks/2`/`resolve_principal_scope/2`) match
   `Letflow.Identity`'s own read-path precedent (true both before and after this
   issue's fix — unchanged).
2. States plainly that `assign_task/3`/`reassign_task/4` are *write* functions whose
   own un-rescued `Ecto.Multi`/`Repo.transaction/1`/`Audit.append_multi/4` shape no
   longer has an analogous un-rescued precedent on `Letflow.Identity` once ISS-0983
   lands (`Letflow.Identity`'s six comparable write functions are now
   rescue-hardened) — so leaving these two functions un-rescued is a standing,
   separate, not-yet-revisited decision for this module specifically, not something
   "matching an established precedent" elsewhere in the codebase.
3. Points at ISS-0983 (this issue) as the source of that correction, so a future
   reader can find the history, the same way other moduledoc corrections in this
   codebase cite the issue that prompted them (e.g. ISS-0981's own design §3 updates a
   stale test comment the same way).

Exact replacement text for ELIXIR-DEV to apply (replacing only the final sentence
quoted above, keeping the paragraph's first two sentences — "Every function below
returns..." and "A genuine DB/connection-level failure is not caught and converted
anywhere in this module — it propagates as a raised exception," — unchanged):

```
Only this module's three *read* functions (`get_task/2`, `list_tasks/2`,
`resolve_principal_scope/2`) match `Letflow.Identity`'s own established
precedent for simple reads — `Letflow.Identity`'s read functions
(`list_users/2`, `get_user/2`, `list_groups/1`, `list_group_members/3`,
`list_tokens/1`, `verify_api_token/2`, and friends) are likewise left
un-rescued. `assign_task/3`/`reassign_task/4` are WRITE functions (each
builds its own `Ecto.Multi` with an `Audit.append_multi/4` step, same shape
as `Letflow.Identity`'s write functions used to have) and are deliberately
left un-rescued here too, but this is no longer "matching an established
Identity precedent" — ISS-0983 rescue-hardened every comparable
`Letflow.Identity` write path (`create_user/2`, `update_user_profile/3`,
`update_user_status/3`, `create_group/2`, `create_token/3`, `revoke_token/2`),
so there is no longer an un-rescued write-path precedent on that module for
these two functions to match. Leaving `assign_task/3`/`reassign_task/4`
un-rescued is now a standing, separate decision specific to this module,
not something inherited from elsewhere — revisit as its own issue if that
asymmetry needs closing, rather than reading this comment as still
justifying it by analogy.
```

This is a doc-comment-only change — `assign_task/3`/`reassign_task/4`'s actual code is
untouched by this fix, per ISS-0983's own acceptance criterion 3 ("without necessarily
changing tasks.ex's actual behavior").

## 5. SECURITY-REVIEWER need

Same reasoning class as ISS-0969/ISS-0980/ISS-0981 (none of which required a
SECURITY-REVIEWER pass): **not required.** Every one of the eight `try/rescue` additions
wraps an already-decided mutation + audit-write pair after every authorization/
tenant-scoping decision has already been made (each function's `prefix`/`tenant_id`
derivation happens before the wrapped code, unchanged) — no new data crosses a tenant
boundary, no response shape changes beyond a new, generically-rendered
`Response.internal_error(conn)` variant (the same response every router site already
produces for other opaque failure tuples today, per §2's new clauses), and no
authorization decision is touched. `docs/agents/instructions/security-invariants.md`'s own trigger
list (API route, migration, secrets, response shaping) is not hit by this change
category. ELIXIR-DEV should still run the standard REVIEWER pass (OTP idiom, scope
creep, decision-record consistency), same as any change.

## 6. Open questions (explicitly unresolved, not guessed)

- **OQ-1**: §1g above flags, for implementation-time confirmation rather than guessing,
  whether `Ecto.Multi.merge/2`'s callback (which is where `activate_group/5`'s own
  `Audit.append_multi/4` call ultimately executes, via `add_activation_steps/9`) could
  ever run its callback outside `Repo.transaction/1`'s own execution window. This
  design's chosen fix (wrap the whole function body) is robust to either answer, but
  ELIXIR-DEV/REVIEWER should still confirm `Ecto.Multi`'s documented lazy-callback
  semantics match this design's assumption before considering this open question
  closed.
- **OQ-2**: exact exception struct name(s) the `DROP TABLE` fault injection raises
  through each of these eight distinct call paths — confirm by running each new test
  once implemented before asserting a specific struct name in its final form, same
  "do not guess" discipline ISS-0980's/ISS-0981's own designs both state.
- (Resolved in this revision — no longer open.) Every site's router-propagation
  question is settled by direct read of both router files (`lib/letflow/routers/identity.ex`,
  `lib/letflow/routers/public_read_handles.ex`, `lib/letflow/routers/entities.ex`): seven
  of the eight sites need one new `case` clause each (§1a-1f, §1h; consolidated in §2),
  and only `activate_group/5`/`activate_definition/4` (§1g) already propagate through
  an existing catch-all with no router change.
