# ISS-0910: reset `role_claims_synced_at` for backfill-affected tenants

Design for the fix ISSUE-FIXER recommended in
`handoffs/WF03-ISS0910-20260930/step-01-issue-fixer-diagnose.json`: for every
tenant `RoleBackfill.run/0` classifies as `:seeded` (genuinely changed by this
run — held fewer than all six platform roles before it), reset
`role_claims_synced_at` to `nil` for every user in that tenant, so the
existing marker-gated call sites in `lib/letflow/identity.ex`
(`upsert_by_external_identity/4` line ~1713, `re_select_on_conflict/3` line
~1826) re-run `sync_role_claims_from_token/3` on that user's next login/token
verification. No new sync-triggering code path — this only clears the guard
that already exists.

## 0. Load-bearing fact: what "a user with a membership in tenant X" means here

Per Decision 0006 D1/D2 (`docs/migration/decisions/0006-identity-tables-schema-per-tenant.md`)
and `Letflow.Identity.User`'s own moduledoc, `users` is a **per-tenant-schema**
table — it carries no `tenant_id` column because the Postgres schema itself
(`schema_name`, e.g. `Registration.schema_name`, the same value
`RoleBackfill.process_registration/2` already threads into
`RoleRegistry.seed_default_platform_role_groups(prefix: schema_name)`) is what
scopes a `users` row to a tenant. Consequently **"every user with a membership
in tenant X" is exactly "every row of tenant X's own `users` table"** — there
is no separate cross-tenant membership/join table to consult for this
scoping. (`group_members` is a *different, narrower* concept — which groups a
user belongs to *within* their tenant's schema — and is irrelevant to scoping
*which tenant* a user belongs to.) This resolves the task prompt's "which
join to scope 'users with a membership in tenant X'" question: **no join** —
a bare `Repo.update_all(User, ..., prefix: schema_name)` scoped by the
tenant's own Postgres schema is the entire scoping mechanism.

## 1. Query shape

**Bulk `Repo.update_all/3`, not a per-user changeset loop.**

```
@spec reset_role_claims_sync_markers(schema_name :: String.t()) ::
        {reset_count :: non_neg_integer(), nil}
```

- Table: `Letflow.Identity.User` (unfiltered `from(u in User)` — every row in
  that tenant schema's `users` table; no `where` clause needed given §0).
- Operation: `Repo.update_all(User, [set: [role_claims_synced_at: nil]], prefix: schema_name)`
  shape (exact call site TBD by ELIXIR-DEV, but the shape is: `Ecto.Query`/
  queryable `+ [set: [role_claims_synced_at: nil]] + prefix: schema_name`,
  matching the established pattern at `lib/letflow/definitions/promotion.ex:474`,
  `lib/letflow/definitions.ex:1700`/`2660`/`2666`, `lib/letflow/entities/definitions.ex:434`).
- Return: `Repo.update_all/3`'s native `{count, nil}` (no `:select` needed —
  nothing downstream needs the affected rows, only the count for logging,
  §5).
- **Why bulk, not per-user changeset loop:** (a) this may touch every user
  row in a tenant that predates ISS-0778 — potentially large; a changeset
  loop would be N round-trips and N `Ecto.Multi`/changeset allocations for a
  single-column, no-validation, no-business-logic write; (b) there is no
  changeset invariant to enforce here — `role_claims_synced_at: nil` is not
  gated by any `validate_required/2`/`unique_constraint/2` the way
  `User`'s other changesets are (§ `lib/letflow/identity/user.ex` has no
  changeset function for this field at all — it is only ever set via
  `Ecto.Changeset.change/2` inside `sync_role_claims_from_token/3` itself);
  (c) precedent — every existing bulk tenant-schema-scoped status/marker
  reset in this codebase (`promotion.ex:474`, `definitions.ex:2660/2666`)
  uses exactly this `Repo.update_all([set: ...], prefix: ...)` shape, none
  loop per-row.

## 2. Where in `RoleBackfill.run/0`'s control flow, and transaction placement

**Per-tenant, inside `process_registration/2`, immediately after
`seed_default_platform_role_groups/1` returns `{:ok, _tenant_roles}` and
*before* classifying/returning `{:cont, ...}`** — not deferred to a
post-`reduce_while` pass over the finalized `:seeded` list. Reasoning:
`process_registration/2` already holds `schema_name` and already knows, from
`held_platform_role_names_before` classification, whether this specific
tenant call was a `:seeded` case — reusing that in-hand information avoids a
second pass that would need to re-derive "which registrations correspond to
these tenant_ids" from `list_registrations/0` a second time.

Concretely, the new step slots into `process_registration/2`'s `{:ok, _tenant_roles}`
branch, guarded on the *same* `held_platform_role_names_before` classification
`classify/3` already uses — i.e. the reset only runs when
`length(held_platform_role_names_before) < 6` (the tenant is genuinely
`:seeded`), never for an `:unchanged` tenant. Two acceptable shapes for
ELIXIR-DEV, either is fine, no preference:

- (a) compute `classify/3`'s outcome first, branch, and only call the new
  reset function in the `:seeded` branch, or
- (b) call the reset function unconditionally but make it itself a no-op
  for `:unchanged` tenants by gating on the same boolean before doing the
  `Repo.update_all` — **not recommended**, since it hides the "only seeded
  tenants" invariant inside the reset function instead of at the call site
  where `classify/3` already expresses it; keep the gate visible at the
  `process_registration/2` call site (shape (a)).

**Transaction placement: a *separate* transaction from
`seed_default_platform_role_groups/1`'s own internal one — never the same
transaction, and never wrapping both in a new outer transaction.**

Reasoning (idempotency / partial-failure implications):
- `seed_default_platform_role_groups/1` is already internally transactional
  (RoleBackfill's own moduledoc, "each tenant's own
  `seed_default_platform_role_groups/1` call is already internally
  transactional per `upsert_role/4`") and returns before this new step runs
  — reusing or extending that transaction would require threading a
  `Repo.transaction/1` boundary across a module boundary
  (`RoleRegistry` → `RoleBackfill`), which neither module does today and
  which would break `RoleRegistry`'s own "no coupling" invariants for no
  benefit.
- If the marker reset's `Repo.update_all` fails (e.g. connection drop)
  *after* `seed_default_platform_role_groups/1` already committed its
  `groups`/`tenant_role` rows, the tenant is left with the roles seeded but
  markers not yet reset — this is the **same halting behavior** the module's
  moduledoc already establishes for other failures ("A hard failure on one
  tenant halts the sweep immediately... No rollback of tenants already
  processed before the halt... a retried `run/0` call converges the
  remaining tenants via idempotency"). A retried `run/0` call re-derives
  `held_platform_role_names_before` for that tenant, finds it now holds all
  six roles (already seeded), classifies it `:unchanged` this time, and
  **skips the reset** — which is fine only if the reset already succeeded on
  a prior attempt for that tenant. If the reset itself is what failed and
  the tenant now reads `:unchanged` on retry, the reset never gets retried.
  **This is a known, accepted gap, not silently resolved — flagged as
  Open Question OQ-1 below**, since closing it (e.g. re-deriving "reset
  needed" from a source other than the 6-role count) is a bigger design
  change than this issue's scope and the marker-reset failure mode is a
  transient-connection case, not a routine one.
- Making the reset's failure `{:halt, {:error, {:backfill_failed, tenant_id, reason}}}`
  (same shape as a `seed_default_platform_role_groups/1` failure) rather
  than silently swallowing it: **yes, halt** — matches the module's existing
  "every failure halts the sweep for operator attention" policy; an
  operator seeing `{:error, {:backfill_failed, tenant_id, reason}}` for a
  marker-reset failure re-runs `run/0` the same way they would for a seeding
  failure (OQ-1 above still applies on retry, but that's no worse than not
  halting at all).

## 3. Idempotency — confirmed explicitly

Running `RoleBackfill.run/0` twice must not error and must not need to
"reset an already-nil marker a second time in a way that matters":

- `Repo.update_all(User, [set: [role_claims_synced_at: nil]], prefix: schema_name)`
  is naturally idempotent at the SQL level: setting a column to `NULL` when
  it is already `NULL` is a no-op write (Postgres does not error, and the
  row is not even considered "changed" for trigger-firing purposes since
  there are no triggers on this column). No `WHERE role_claims_synced_at IS
  NOT NULL` filter is required for correctness — it is a pure optimization
  ELIXIR-DEV may add (reduces rows touched/WAL volume when most users are
  already `nil`) but its absence does not change behavior or correctness.
  (ISSUE-FIXER's diagnosis already noted this: "excluding already-nil rows
  is a pure optimization, not a correctness requirement.")
- On a second `run/0` call, every tenant that was `:seeded` on the first
  call now holds all six platform roles (seeding is itself idempotent per
  `upsert_role/4`), so `classify/3` places it in `:unchanged` this time —
  the reset step (gated on the same `:seeded` classification, §2) does
  **not** run again for that tenant on the second call. This is the
  intended, harmless outcome: a second `run/0` neither re-nulls already-nil
  markers for that tenant nor disturbs a marker a user's login has since
  legitimately re-stamped with a fresh sync timestamp (re-nulling a
  *freshly-synced* marker on a second backfill run would be the actual bug
  to avoid — a real "in a way that matters" case — and gating on `:seeded`
  classification is exactly what prevents it, since an already-fully-seeded
  tenant's users are never touched again).
- Blast radius stays correctly scoped: `:unchanged` tenants (never affected
  by the original ISS-0886 gap) are never touched by this reset, on the
  first `run/0` call or any subsequent one.

## 4. Migration needed? No.

`role_claims_synced_at` already exists on `users` (`Letflow.Identity.User`
schema, `lib/letflow/identity/user.ex:45`, `field(:role_claims_synced_at, :utc_datetime_usec)`)
— confirmed by reading the schema module directly. This fix only ever writes
`nil` to an existing, already-nullable column (REQ-378's own marker semantics
already require it to be nullable, since a brand-new/unsynced user's value is
`nil` by definition). **No new migration.**

## 5. Logging/telemetry

Matches `RoleBackfill`'s existing style: the module already reports its work
via its `{:ok, %{seeded: [...], unchanged: [...]}}` return value rather than
ad hoc `Logger` calls scattered through the reduce (the one existing
`Logger.warning` call in this file's neighborhood is
`sync_role_claims_from_token/3`'s own, in `identity.ex`, not `RoleBackfill`'s
— `RoleBackfill` itself currently has no `Logger` calls at all). Follow that
precedent: extend the accumulator/return shape rather than introducing
per-tenant log lines.

```
@spec run() ::
        {:ok,
         %{
           seeded: [Ecto.UUID.t()],
           unchanged: [Ecto.UUID.t()],
           role_claims_markers_reset: non_neg_integer()
         }}
        | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
```

- `role_claims_markers_reset`: the **sum**, across every `:seeded` tenant
  this `run/0` call processed, of the row count `Repo.update_all/3` returns
  for that tenant's reset. This gives an operator the same kind of
  at-a-glance signal the module's moduledoc says `:seeded`/`:unchanged` was
  designed for ("operators want to know which tenants changed, to narrow
  what needs re-verifying after a QA run") — now extended to "how many
  users will need to re-authenticate/re-sync as a result."
  `process_registration/2`'s accumulator gains a third counter alongside
  `seeded`/`unchanged` (threaded through the same `Enum.reduce_while/3`,
  no shape change to the halt/cont control flow itself).
- No per-tenant `Logger` line is introduced by this fix, to stay consistent
  with the module's existing all-in-the-return-value reporting style; if
  ORCH/operators want per-tenant visibility during a live sweep, that is a
  separate, follow-on concern (not this issue's scope) rather than something
  to bolt on inconsistently here.
- The CLI wrapper, `lib/mix/tasks/letflow.backfill_platform_roles.ex`
  (owned module, in scope per this handoff's `owned_modules`), must be
  updated to print/`Mix.shell().info/1` the new
  `role_claims_markers_reset` count alongside however it currently reports
  `seeded`/`unchanged` — exact wording left to ELIXIR-DEV to match that
  task's existing output style; no new flags or behavior beyond surfacing
  the new count.

## 6. New/changed function surface (signatures only)

```
# lib/letflow/identity/role_backfill.ex

@spec run() ::
        {:ok,
         %{
           seeded: [Ecto.UUID.t()],
           unchanged: [Ecto.UUID.t()],
           role_claims_markers_reset: non_neg_integer()
         }}
        | {:error, {:backfill_failed, tenant_id :: Ecto.UUID.t(), reason :: term()}}
def run()

@spec process_registration(
        Registration.t(),
        %{
          seeded: [Ecto.UUID.t()],
          unchanged: [Ecto.UUID.t()],
          role_claims_markers_reset: non_neg_integer()
        }
      ) ::
        {:cont, {:ok, map()}}
        | {:halt, {:error, {:backfill_failed, Ecto.UUID.t(), term()}}}
defp process_registration(%Registration{} = registration, acc)

# New private helper -- the bulk reset itself.
@spec reset_role_claims_sync_markers(schema_name :: String.t()) ::
        non_neg_integer()
defp reset_role_claims_sync_markers(schema_name)

# classify/3 gains no new clause -- its existing two clauses (< 6 vs. not)
# are reused as the same gate that decides whether
# reset_role_claims_sync_markers/1 is called at all (see §2 shape (a)).
```

`lib/letflow/identity/user.ex`, `lib/letflow/identity.ex`,
`lib/letflow/identity/role_registry.ex`: **no changes** — this fix is
entirely contained in `RoleBackfill` (and its CLI wrapper's output). Reuses
`Letflow.Identity.User`'s existing schema struct as the `Repo.update_all/3`
queryable; does not call, alias, or modify
`sync_role_claims_from_token/3` or either of its call sites, satisfying the
acceptance criterion that no new sync-triggering path is invented.

## 7. Invariants (new, this fix)

- **INV-BF5:** the marker reset touches only `users` rows in a tenant schema
  classified `:seeded` by this same `run/0` call (§0, §2) — never an
  `:unchanged` tenant's users, never a `group_members` row (still INV-BF2,
  unchanged), never any table outside the `users` row's own
  `role_claims_synced_at` column.
- **INV-BF6:** the reset is a pure marker clear, not a grant — it relies
  entirely on `sync_role_claims_from_token/3`'s own existing,
  already-reviewed claims-resolution logic to decide what a user actually
  gets on their next login. `RoleBackfill` still never determines or grants
  any individual user's roles itself (moduledoc's existing INV-BF1/INV-BF2
  framing extended, not contradicted).

## 8. Open questions (explicit, not silently resolved)

- **OQ-1 (§2):** if `Repo.update_all` for the marker reset fails *after*
  `seed_default_platform_role_groups/1` already committed for that tenant,
  a retried `run/0` reclassifies that tenant `:unchanged` (roles are already
  fully seeded) and never retries the reset — that tenant's pre-existing
  users stay stuck with a stale, non-nil marker indefinitely. Accepted as a
  known gap for this issue's scope (a genuine "roles seeded but reset
  failed" case is expected to be rare — a transient connection failure
  mid-sweep — and is already operator-visible via the halted
  `{:error, {:backfill_failed, tenant_id, reason}}` return, same as any
  other halt this module produces); a durable fix (e.g. tracking "reset
  done" independently of the 6-role count) is out of scope here and should
  be raised as a follow-on issue if it recurs in practice.
- **OQ-2:** whether `reset_role_claims_sync_markers/1`'s `Repo.update_all`
  should filter `where: is_nil(u.role_claims_synced_at) == false` (skip
  already-nil rows) purely as a write-volume optimization. Not required for
  correctness (§3) — left to ELIXIR-DEV's discretion at implementation
  time.
