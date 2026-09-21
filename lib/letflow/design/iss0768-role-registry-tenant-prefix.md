# ISS-0768 — Thread `opts :: [prefix: String.t()]` through `RoleRegistry`

PROVENANCE (historical, not current decision authority):
`lib/letflow/identity/role_registry.ex` (REQ-020) was ported from R-Co's
`src/identity/role_registry.zig` before this project's multi-tenant-schema
convention (`opts :: [prefix: String.t()]`, established and documented in
`lib/letflow/identity.ex`'s own moduledoc, and exercised correctly in
`lib/letflow/plugs/auth_pipeline.ex`) existed in this codebase. The module has
**zero** `prefix:` usage today — every `Repo` call in it queries the default
`public` schema regardless of which tenant made the request. `GET /roles` and
`POST /roles` (REQ-076, `lib/letflow/routers/identity.ex`) therefore 500 (or
silently hit the wrong tenant's data, worse) for every tenant. This is not a
partial migration to finish — treat every call site as unmigrated and design
each one from scratch.

No implementation code below — `@spec`s, call-site prose, and the git
investigation ELIXIR-DEV must run only.

## 0. Summary of composition

| Site | Change |
|---|---|
| `RoleRegistry.list_roles/0` | → `list_roles/1`, takes `opts`, threads into `Repo.all` |
| `RoleRegistry.upsert_role/2` | → `upsert_role/3`, takes `opts`, threads into `do_upsert_role/3` → `Repo.transaction` → `Repo.get/3` and `insert_or_update_role/3` → `Repo.insert/2` |
| `RoleRegistry.resolve_role_in_tx/1` | **out of scope** for this fix — see §3 for reasoning |
| `Letflow.Routers.Identity.handle_list_roles/1` | gains `conn` param already; add `opts` param, pass `conn.assigns.scoped_opts` at call site, thread to `RoleRegistry.list_roles/1` |
| `Letflow.Routers.Identity.handle_upsert_role/1` | same shape, thread to `RoleRegistry.upsert_role/3` |

## 1. `role_registry.ex` — public function signatures

### 1.1 `list_roles/1` (was `list_roles/0`)

```
@spec list_roles(opts :: [prefix: String.t()]) :: [TenantRole.t()]
def list_roles(opts)
```

No default value for `opts` — matches `lib/letflow/identity.ex`'s convention of
requiring the caller to pass `opts` explicitly rather than defaulting to the
public schema (a default would silently reintroduce the same class of bug this
fix corrects, by letting a future caller omit `prefix:` and land back in
`public`).

**Repo call site to change:** the single `Repo.all(from(t in TenantRole, order_by:
[asc: t.name]))` call. Add `prefix: opts[:prefix]` as a second argument to
`Repo.all/2`, alongside the existing query — i.e. the call gains a
`prefix: opts[:prefix]` option keyword, exactly the same option/value pair
`auth_pipeline.ex` already passes to its own `Repo.all/2` call.

No other change to this function's body.

### 1.2 `upsert_role/3` (was `upsert_role/2`)

```
@spec upsert_role(
        name :: String.t(),
        group_id :: Ecto.UUID.t() | String.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, TenantRole.t()} | {:error, upsert_error()}
def upsert_role(name, group_id, opts)
```

Body shape unchanged except the final delegation: currently
`do_upsert_role(name, normalized_group_id)` becomes
`do_upsert_role(name, normalized_group_id, opts)` — `opts` passes straight
through the existing `with` chain's validation steps (`validate_role_name/1`,
`Ecto.UUID.cast/1`) untouched, since neither of those touches the DB.

### 1.3 `do_upsert_role/3` (private helper, was `/2`)

```
@spec do_upsert_role(
        name :: String.t(),
        group_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: {:ok, TenantRole.t()} | {:error, upsert_error()}
defp do_upsert_role(name, group_id, opts)
```

**Repo call sites to change**, both inside the `Repo.transaction/2` closure:

1. `Repo.transaction(fn -> ... end)` itself must become
   `Repo.transaction(fn -> ... end, prefix: opts[:prefix])` — `Repo.transaction/2`
   takes the prefix as an option on the transaction call itself, not on each
   inner query, per Ecto's `prefix` option contract (a transaction's prefix
   option sets the default `search_path`-equivalent for queries run inside it
   via the `Repo` module functions, but each inner call below must still name
   its own `prefix:` explicitly per this module's existing style of never
   relying on ambient state — do not rely on the transaction-level prefix
   alone; pass it explicitly at both inner call sites too, for the same
   defense-in-depth reason `auth_pipeline.ex` names `prefix:` at every call
   rather than once).
2. `Repo.get(Group, group_id)` → `Repo.get(Group, group_id, prefix: opts[:prefix])`.
3. The `insert_or_update_role(name, group_id)` delegation inside the `%Group{}
   ->` branch becomes `insert_or_update_role(name, group_id, opts)`.

The closure itself gains no new parameter — `opts` is captured from
`do_upsert_role/3`'s own argument by the closure, same as `name`/`group_id`
today.

### 1.4 `insert_or_update_role/3` (private helper, was `/2`)

```
@spec insert_or_update_role(
        name :: String.t(),
        group_id :: Ecto.UUID.t(),
        opts :: [prefix: String.t()]
      ) :: TenantRole.t()
defp insert_or_update_role(name, group_id, opts)
```

**Repo call site to change:** the `Repo.insert(conflict_target: :name,
on_conflict: [set: [group_id: group_id]], returning: true)` call. Add a
`prefix: opts[:prefix]` entry to that same keyword-list argument, alongside
the existing `conflict_target:`, `on_conflict:`, and `returning:` entries —
no other entry in that keyword list changes.

## 2. Router call sites — `lib/letflow/routers/identity.ex`

Both routes already resolve `conn.assigns.scoped_opts` upstream (set by the
router's auth pipeline before any `authz_*` macro body runs — same value every
other route in this module already passes, e.g. `handle_create(conn,
conn.assigns.scoped_opts)` at line 143). Current state (read directly, lines
203–209, 650–677): `handle_list_roles/handle_upsert_role` take only `conn`
and call `RoleRegistry.list_roles()` / `RoleRegistry.upsert_role(name,
group_id)` with no opts at all.

### 2.1 `GET /roles` (currently line 204: `handle_list_roles(conn)`)

The route macro body's call to `handle_list_roles/1` gains a second argument,
`conn.assigns.scoped_opts`, becoming a call to `handle_list_roles/2` — the
same value every other route in this module already passes at its own
call site (e.g. `handle_create(conn, conn.assigns.scoped_opts)`).

`handle_list_roles/1` becomes `handle_list_roles/2`, gaining `opts` as its
second parameter. Its body's single change: the existing
`RoleRegistry.list_roles()` call gains `opts` as its argument, becoming
`RoleRegistry.list_roles(opts)`.

### 2.2 `POST /roles` (currently line 208: `handle_upsert_role(conn)`)

The route macro body's call to `handle_upsert_role/1` gains a second
argument, `conn.assigns.scoped_opts`, becoming a call to
`handle_upsert_role/2`, matching the same established pattern.

`handle_upsert_role/1` becomes `handle_upsert_role/2`, gaining `opts` as its
second parameter. Its body's single change is inside the `{:ok, %{"name" =>
name, "group_id" => group_id}} ->` branch: the existing
`RoleRegistry.upsert_role(name, group_id)` call gains `opts` as a third
argument, becoming `RoleRegistry.upsert_role(name, group_id, opts)`. The
`Validation.validate/2` call and every response-mapping branch (`role_map/1`,
error-atom → HTTP status mapping) is unchanged — this fix touches only the
`RoleRegistry` call itself.

## 3. `resolve_role_in_tx/1` — explicitly out of scope

**Decision: out of scope for this fix. Leave its signature (`resolve_role_in_tx(name
:: String.t()) :: Ecto.UUID.t() | nil`) unchanged.**

Reasoning, for REVIEWER to check:

- The function's own moduledoc states it is designed to be called from
  *inside* a caller's own `Repo.transaction/1` (a future S3
  `applyTransition`), taking no repo/connection argument because the
  transaction context is ambient to the calling process.
- A grep of the codebase for `resolve_role_in_tx` confirms zero current
  callers — this is unreachable dead code from any live HTTP route today, so
  it cannot be responsible for ISS-0768's observed 500s (those come from
  `list_roles/0` and `upsert_role/2`, both reachable from `/roles`).
- Because it runs inside a caller-provided transaction, the correct fix
  shape when that caller exists is for **the caller's own transaction** to
  already be opened against the right tenant schema (via
  `Repo.transaction(fn -> ... end, prefix: ...)`), at which point
  `Repo.get_by(TenantRole, name: name)` inside `resolve_role_in_tx/1`
  would need `prefix:` too — but only that future caller's design can
  determine whether `resolve_role_in_tx/1` should take its own `opts`
  parameter or inherit the ambient transaction prefix some other way (Ecto
  does not automatically propagate a transaction's `prefix:` option to
  every query run inside it — each query must still name `prefix:`
  explicitly, same reasoning as §1.3 item 1 above). Designing that now would
  be speculative: there is no concrete caller shape to design against yet.
- Recommendation: when the future S3 `applyTransition` caller is designed,
  its own design doc must revisit `resolve_role_in_tx/1` and give it an
  `opts` parameter at that time, following this same convention. File that
  as a follow-up, not as part of ISS-0768.

This satisfies the acceptance criterion "resolve_role_in_tx/1 is explicitly
addressed" — it is addressed here, with reasoning, not silently skipped.

## 4. Regression-vs-always-broken investigation (for ELIXIR-DEV to run and record)

Do not answer this here — this section specifies only the exact commands and
what evidence would decide it. ELIXIR-DEV must run these against the worktree
at `c:\Users\tvolo\dev\ai-dala\letflow-wf03-iss0768` and record the actual
output/finding in its own handoff result, not this design doc.

1. Full history of the file, including its introduction:
   ```
   git log -p --follow -- lib/letflow/identity/role_registry.ex
   ```
   Read every diff hunk for a `Repo.all`, `Repo.get`, `Repo.get_by`,
   `Repo.transaction`, or `Repo.insert` call and check whether any of them
   ever carried a `prefix:` keyword, at any point in history.

2. Narrower, faster check — search every historical revision of the file for
   the literal string `prefix`:
   ```
   git log -p --follow -S"prefix" -- lib/letflow/identity/role_registry.ex
   ```
   `-S"prefix"` (the "pickaxe") shows only commits that added or removed a
   line containing `prefix` in this file. An **empty result** is strong
   evidence the module never threaded `prefix:` at any commit — i.e. this bug
   is not a regression, it has been broken since the module first shipped
   (REQ-020). A **non-empty result** means some commit touched `prefix:` in
   this file — inspect that commit's diff (`git show <sha> --
   lib/letflow/identity/role_registry.ex`) to see whether it *added* prefix
   threading that a later commit then *removed* (a genuine regression) or was
   unrelated noise (e.g. a comment mentioning the word "prefix").

3. Corroborating check — confirm the file's first commit (its introduction)
   never had `prefix:` either, to rule out "added correctly, then
   immediately reverted before any other commit":
   ```
   git log --follow --diff-filter=A --format=%H -- lib/letflow/identity/role_registry.ex
   ```
   Take the resulting SHA and run
   `git show <that-sha> -- lib/letflow/identity/role_registry.ex` to inspect
   the file as first committed.

**Evidence that would answer the question:**
- If step 2's pickaxe search returns **no commits**, and step 3's
  introduction commit has no `prefix:` usage → **always-broken since REQ-020
  shipped**, not a regression.
- If step 2 finds a commit that *removed* a `prefix:` line without another
  commit re-adding it, and a later commit is what ISS-0768 was filed
  against → **regression**, and ELIXIR-DEV must name the offending commit SHA
  in its own handoff result.

## 5. Non-goals / unaffected

- `list_roles/1`'s and `upsert_role/3`'s existing validation logic
  (`validate_role_name/1`, `Ecto.UUID.cast/1`, format constraints) is
  untouched by this fix — only `Repo` call sites gain `prefix:`.
- `role_map/1` and the router's response-shaping/error-mapping in
  `handle_list_roles`/`handle_upsert_role` are untouched.
- No migration or schema change — `TenantRole`/`Group` already support
  per-tenant schemas (`Letflow.Identity`'s own functions already query them
  correctly with `prefix:`); this fix only brings `RoleRegistry` in line with
  that existing convention.
- `:RolesManage` authorization-policy wiring (`authz_get "/roles"`,
  `authz_post "/roles"`) is unaffected — this is purely a schema-targeting
  fix, not an authorization change.

## 6. Open questions

None — every acceptance criterion in ISS-0768's handoff maps to a concrete
signature/call-site change above, except the regression-vs-always-broken
question, which is explicitly deferred to ELIXIR-DEV per §4 (that is the
handoff's own instruction, not an unresolved design gap).
