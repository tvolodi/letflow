# ISS-0771 — Automatic tenant-scoped migration replay on every app start

**Status:** design, not yet implemented. **Root cause:** already fully diagnosed in
`docs/issues/ISS-0771.yaml` — not re-derived here. Summary: `Letflow.TenantProvisioning`
auto-applies tenant-scoped migrations (`tenant_scoped_migrations/0`) only at
provisioning time (inside `provision_tenant_schema/1`'s caller-sequenced follow-up,
`replay_migrations/2`). No deploy-time or boot-time step ever replays them against
tenants that already existed before a new tenant-scoped migration was added.
`deploy/redeploy-qa.sh` restarts the app container and relies on the boot-time
`Ecto.Migrator` child (`lib/letflow/supervisor/infrastructure.ex`), which only covers
the public/default schema. REQ-378's `20260921000001_add_role_claims_synced_at_to_users.exs`
(tenant-scoped) merged, was never replayed against either existing QA tenant, and every
authenticated request 500'd until `replay_migrations/2` was called manually per tenant
through a remote console.

This document decides where the automatic fix belongs, specifies the exact
signatures/call sites, and states the idempotency and per-tenant-isolation guarantees.

---

## 1. Option comparison

### Option A — new step in `deploy/redeploy-qa.sh`

A step after `$COMPOSE up -d --force-recreate app` (script's current step 5) that
invokes the running release, e.g.
`docker compose ... exec app bin/letflow rpc "Letflow.TenantProvisioning.replay_all_pending()"`
(a release's `eval` does not start the OTP application/supervision tree — `Letflow.Repo`
would not be running — so `rpc` against the already-started `app` container, which
does have the full supervision tree up, is the only viable release-command form here;
`eval` is not).

**Rejected.** Two reasons, both structural, not stylistic:

1. **It reproduces the exact failure class ISS-0771 is about.** The root cause is "a
   step that must be remembered was not." `deploy/redeploy-qa.sh` is explicitly one
   sibling script among others (its own header: "this is a SIBLING script, not a
   replacement" of `redeploy-test.sh`), and neither script is the only current or
   future deploy entry point — a future production deploy script, or any operator
   restarting the `app` container directly via `docker compose up -d --force-recreate
   app` without going through the full script (already how the script's own step 5
   works, and indistinguishable from a manual restart to anything outside the
   script), silently reopens the identical gap. A fix that lives in one shell script
   is exactly as forgettable as the deploy-time replay call this issue is about.
2. **It does not cover `mix phx.server`/local dev or `iex -S mix`** — explicitly
   called out in the task as a gap Option A cannot close, and this codebase's own
   tenant-scoped-migration authoring workflow (add a migration, add its manifest
   entry in `tenant_scoped_migrations/0`) happens locally, against tenants a
   developer already provisioned earlier in the same session, before it ever reaches
   QA. The same silent-column-missing failure mode reproduces locally with no deploy
   script involved at all.

### Option B — boot-time hook in the supervision tree (CHOSEN)

Add one new supervised, one-shot child to `lib/letflow/supervisor/infrastructure.ex`'s
`init/1` children list, immediately after the existing `{Ecto.Migrator, ...}` entry
(current line 158-159) and before `Letflow.Oidc.ProviderRegistry`.

**Chosen because it is structural, not procedural.** It runs on every single
`Letflow.Application.start/2` — the QA container restart, any future prod deploy
script (however it ends up shaped), a bare `docker compose up -d --force-recreate
app`, and local `mix phx.server`/`iex -S mix` — with no separate script to keep in
sync and no step anyone can forget to add to a new deploy path. This mirrors the
precedent already in this exact file: the public-schema `Ecto.Migrator` child is
*already* boot-time, not deploy-script-time, for the identical reason (migrations must
apply before the app starts serving, regardless of how it was started). Extending
tenant-scoped migrations to the same mechanism, at the position directly after it,
keeps "where do migrations get applied" answerable by reading one file instead of two.

**What could still go wrong, stated explicitly (conservative, production-incident-derived):**

- **Boot latency scales with tenant count.** Every boot now does one
  `Ecto.Migrator.run/4` dry-check per tenant (cheap — a `schema_migrations` table
  query returning zero pending versions in the already-migrated common case) plus,
  for a genuinely pending migration, the real DDL. At QA's current scale (2 tenants)
  this is negligible. Accepted risk at present scale; flagged for whoever first
  provisions tenant counts large enough to make sequential per-tenant boot-blocking
  work matter (see §4, "Not built here").
- **A tenant whose migration is genuinely broken re-attempts, and re-fails loudly, on
  every single boot** (not just once) until someone fixes the migration or the
  tenant's schema state. This is accepted, not treated as a defect: `replay_migrations/2`
  is cheap to retry (Option 1 below states why), the failure is logged individually
  every time (never silent), and retry-until-fixed is a strictly better default than
  "apply once at provisioning, never again" — the exact gap this issue exists to close.
- **This still does not build an automatic reconciliation *sweep*** for a tenant
  stuck in the half-provisioned state this module's own moduledoc documents
  (`migrations_applied_at IS NULL`, ISS-0230/GH#468). That is deliberate and already
  decided against elsewhere in this module ("An automatic reconciliation sweep is
  deliberately *not* in scope... adding a supervision-tree child for it is scope
  creep") — this design reuses that decision rather than re-litigating it. What this
  design closes is narrower and different: replaying migrations against tenants that
  are already fully provisioned (`Registration` row exists) but have one or more new
  tenant-scoped migrations pending, which is exactly ISS-0771's failure mode. A
  tenant that failed *provisioning* itself (no `Registration` row, or
  `migrations_applied_at IS NULL` from a first-provisioning failure) is unaffected by
  this design in either direction — `replay_migrations/2` already returns
  `{:error, :tenant_not_provisioned}` for the former, and would simply retry (and
  keep failing, logged) for the latter, same as any other pending-migration failure.
- **This boot-time child must never itself raise or return an error to its
  supervisor**, regardless of how many tenants fail — see §3's isolation guarantee.
  If that guarantee were ever violated (a bug reintroduces an unrescued path), a
  single broken tenant migration would fail `Letflow.Supervisor.Infrastructure`'s own
  `Supervisor.start_link/2` and take the *entire application* down on every boot —
  strictly worse than today's silent-gap bug. This is the single highest-severity
  failure mode of this design and is why §3's guarantee is stated as absolute
  ("never raises, ever"), not merely "usually doesn't."

---

## 2. New/changed function signatures

### 2.1 `Letflow.TenantProvisioning.replay_all_pending/0` (new public function)

```
@spec replay_all_pending() :: %{
        ok: [tenant_id :: Ecto.UUID.t()],
        error: [{tenant_id :: Ecto.UUID.t(), reason :: term()}]
      }
def replay_all_pending()
```

- Calls `list_registrations/0` (unchanged, already exists) to enumerate every
  provisioned tenant.
- For each `%Registration{tenant_id: tenant_id}`, calls `replay_migrations(tenant_id)`
  (unchanged 2-arity function, `migration_source` defaults to `nil` →
  `tenant_scoped_migrations/0`, exactly the production manifest — this is the same
  call `replay_migrations/2`'s own moduledoc already documents as also seeding
  platform event types).
- Accumulates `tenant_id` into `:ok` on `{:ok, _applied_versions}`, or
  `{tenant_id, reason}` into `:error` on any `{:error, reason}` return
  (`:tenant_not_provisioned`, `{:migration_failed, exception}`, or
  `{:event_type_seed_failed, reason}` — `replay_migrations/2`'s existing `@spec`
  covers all three).
- Never raises: the per-tenant call is wrapped in `rescue` (belt-and-suspenders —
  `replay_migrations/2` itself already converts every exception it can reach into a
  tagged `{:error, _}`, per its own moduledoc reasoning about `Code.LoadError` and
  ISS-0019 — but this function must not depend on that invariant holding for every
  future change to `replay_migrations/2` to stay itself exception-free; see §3).
- Pure orchestration, no new query beyond the existing `list_registrations/0` +
  `replay_migrations/2` primitives. Composable and independently unit-testable
  against `test/support/req022_migration_fixture.ex`-style fixtures without touching
  the boot path.
- Return shape is a map (not a list of tuples) specifically so a caller — the boot
  hook in §2.2, or a future ops-facing mix task — can pattern-match
  `%{error: []}` for "fully clean" without re-partitioning a list itself.

### 2.2 `Letflow.TenantProvisioning.MigrationReplayBoot` (new module — boot-time child)

```
@spec start_link(term()) :: {:ok, pid()} | :ignore
def start_link(_init_arg)
```

- A minimal module, not a `GenServer`/`Supervisor` — no state, no message loop, no
  registered name. `start_link/1` runs synchronously (blocking, matching the
  `Ecto.Migrator` child it is placed directly after) and unconditionally returns
  `:ignore`.
- Body (prose, no implementation code): call `Letflow.TenantProvisioning.replay_all_pending/0`
  inside an outer `try/rescue` that can itself never propagate (the outer guard is
  redundant with `replay_all_pending/0`'s own internal per-tenant `rescue`, by
  design — see §3, "two independent layers"). Log a `Logger.warning/1` (or
  `Logger.error/1`) per failing tenant naming `tenant_id`, `schema_name` (looked up
  from the same `Registration` the loop already has in hand — no extra query), and
  the tagged `reason`; log one `Logger.info/1` summary line
  (`"tenant migration replay: N ok, M failed"`) after the loop completes, always,
  including the `N ok, 0 failed` common case — a boot-time step this significant
  logging nothing on the healthy path is exactly the kind of gap that let ISS-0771
  ship invisibly the first time.
- **Always returns `:ignore`**, never `{:error, _}`, regardless of the map
  `replay_all_pending/0` returns — see §3.
- Placed in `lib/letflow/tenant_provisioning/migration_replay_boot.ex`, matching this
  module's own established convention of schema/helper files living in a
  same-named subdirectory.

### 2.3 Call site — `lib/letflow/supervisor/infrastructure.ex`

Children list, `init/1` (current lines 156-159 shown for anchor):

```
children = [
  Letflow.Repo,
  {Ecto.Migrator,
   repos: Application.fetch_env!(:letflow, :ecto_repos), skip: skip_migrations?()},
  Letflow.TenantProvisioning.MigrationReplayBoot,
  Letflow.Oidc.ProviderRegistry,
  ...
]
```

One new entry, `Letflow.TenantProvisioning.MigrationReplayBoot` (bare module form —
no init args, no child-spec overrides needed since it is not `:temporary`/pollers-style
and carries no restart-budget concern; see §3 for why `:ignore` alone is sufficient
and no `restart:` override is needed).

**Ordering rationale (two constraints, both satisfied by this position):**

1. **After `{Ecto.Migrator, ...}`.** Global/public-schema migrations must be fully
   applied before any tenant-scoped replay runs, on the same "apply the more
   fundamental layer first" reasoning `provision_tenant_schema/1` →
   `replay_migrations/2` already follows at onboarding time (global `tenants` row
   before tenant-schema DDL). No known tenant-scoped migration today actually reads
   public-schema state, but nothing prevents a future one from needing to (e.g. a
   migration seeding a tenant-scoped row keyed off a global lookup table) — ordering
   this after `Ecto.Migrator` costs nothing and forecloses that whole class of
   future bug.
2. **Before every other Infrastructure child, and structurally before
   `Letflow.Supervisor.Http` (a wholly separate, later-starting top-level
   supervisor in `lib/letflow/application.ex`'s own children list).** Because
   `start_link/1` blocks and `Supervisor.init/2` starts children strictly in list
   order (the same guarantee `lib/letflow/application.ex`'s own moduledoc already
   documents for its own three-supervisor ordering), no request can reach any route
   until tenant-scoped replay has finished for every tenant — closing exactly the
   "request lands, column doesn't exist yet, 500" window ISS-0771 describes, not
   merely reducing it.
- **Deliberately NOT gated by `skip_migrations?()`** (`RELEASE_NAME` unset check).
  `Ecto.Migrator`'s own skip exists because local dev/test already has an equivalent
  path (`mix ecto.setup`/the `test` alias) for the *public* schema. No equivalent
  local-dev path exists for tenant-scoped replay — `mix ecto.setup` never touches a
  tenant schema — so gating this child the same way would silently reintroduce
  exactly the "doesn't cover `mix phx.server`/local dev" gap Option B exists to
  close. Running unconditionally is safe specifically because of §3's idempotency
  guarantee: a local dev boot against already-migrated tenants is a fast, safe no-op
  every time, identical in kind to `Ecto.Migrator`'s own no-op behavior for an
  already-migrated public schema.

---

## 3. Idempotency guarantee

**Statement:** calling `replay_all_pending/0` (and therefore booting the app) any
number of times, in any order, against tenants with zero pending tenant-scoped
migrations is a safe no-op — no error, no duplicate DDL, no duplicate row.

**How it is achieved — entirely by composition of guarantees `replay_migrations/2`
already has today; nothing new is added by this design:**

1. `Ecto.Migrator.run(Repo, migrations, :up, all: true, prefix: schema_name, log:
   false)` only applies migrations not already recorded in that schema's own
   `schema_migrations` table (`:prefix`-scoped, per INV-1's mechanism) — a
   fully-migrated tenant returns `{:ok, []}` (empty `applied_versions`), doing zero
   DDL. This is `Ecto.Migrator`'s own standard behavior, already relied upon by the
   existing public-schema boot child directly above this design's new one.
2. `maybe_seed_platform_event_types/2` (existing, unchanged) treats
   `{:error, :duplicate_event_type_version}` from `Registry.register_type/2` as
   success — re-seeding an already-seeded tenant's 6+ platform event types is a
   documented no-op, per this module's own moduledoc ("a second `replay_migrations/2`
   call against an already-seeded tenant schema ... is also a no-op on this step").
3. `mark_migrations_applied/1` (existing, unchanged) is an unconditional
   `Repo.update_all` timestamp set — idempotent by construction (setting the same
   column to a fresh `NaiveDateTime.utc_now/0` twice is not an error; it simply
   updates the timestamp to the latest replay's completion time, which is
   itself useful telemetry: `migrations_applied_at` becomes "last successful replay
   time," not merely "first migration time").

`replay_all_pending/0` and `MigrationReplayBoot` add **no new idempotency mechanism**
— they are pure orchestration over an already-idempotent primitive. This is a
deliberate design minimality choice: the existing primitive was already proven
idempotent (REQ-022's own onboarding retry-safety requirement), so the fix is "call
the safe thing on every boot," not "build new safety."

---

## 4. Per-tenant failure-isolation guarantee

**Statement:** one tenant's migration failure is logged/reported individually and
never aborts replay for any other tenant, and never aborts (or crashes) the
supervision tree's own boot.

**Chosen mechanism: plain sequential `Enum` iteration with a `rescue` at each
per-tenant call site — not `Task.async_stream/3`.**

Two independent layers, deliberately redundant (defense-in-depth, matching INV-8's
"no unhandled crash on a realistic failure path"):

- **Layer 1 (inside `replay_migrations/2`, existing/unchanged):** the whole
  `Ecto.Migrator.run/4` call plus event-type-seeding `with` chain is already wrapped
  in `try/rescue`, converting any exception into `{:error, {:migration_failed,
  exception}}`. `replay_all_pending/0`'s loop body therefore ordinarily only ever
  sees a clean `{:ok, _} | {:error, _}` return, never a raised exception, for each
  tenant.
- **Layer 2 (new, inside `replay_all_pending/0`'s own loop):** the call to
  `replay_migrations(tenant_id)` is additionally wrapped in its own `rescue`,
  independent of Layer 1. This is not redundant paranoia without a reason: it means
  `replay_all_pending/0`'s exception-safety does not silently depend on
  `replay_migrations/2` continuing to catch everything forever — a future change to
  that function (or to any function it calls) that reintroduces an unrescued raise
  path is caught here too, at the orchestration boundary, before it can propagate
  into `MigrationReplayBoot.start_link/1` and threaten `Supervisor.init/2` itself.
  A tenant whose call raises past Layer 1 is recorded into the `:error` accumulator
  as `{tenant_id, {:unexpected_exception, exception}}` (a new, explicitly
  distinguishable reason atom from `replay_migrations/2`'s own three — so a caller
  can tell "the function returned a typed error" from "something raised that
  shouldn't have" when triaging).

**Why sequential `Enum`, not `Task.async_stream/3`:** rejected for three reasons,
each independently sufficient:

1. **Correctness at this scale needs no concurrency.** QA today has 2 tenants; even
   at a few dozen, sequential per-tenant `Ecto.Migrator.run/4` no-op checks (the
   overwhelmingly common case — most boots find zero pending migrations for every
   tenant) complete in well under the existing 30-second backend health-check
   budget `deploy/redeploy-qa.sh`'s own step 8 already allows. Concurrency here
   would be solving a boot-latency problem that does not exist yet, at the cost of
   real complexity described in point 2.
2. **`Task.async_stream/3`'s `:on_timeout`/`:exit` handling is a second,
   independent failure-isolation surface to get right**, on top of Layer 1/Layer 2
   above — a timed-out or `:exit`-ed task's result must itself be decoded into the
   same `{tenant_id, reason}` shape, doubling the paths that must be proven never to
   propagate an unhandled crash into `MigrationReplayBoot`. Sequential `Enum` with
   `rescue` has exactly one failure path per tenant to reason about, not two.
3. **Does not reintroduce a "supervised process per tenant" shape.** `Letflow.Engine`'s
   documented process-vs-row decision (REQ-045, this codebase's own `CLAUDE.md`)
   resolved running-instance concurrency to plain transactional Postgres-row
   arbitration, explicitly rejecting a supervised process per unit-of-work.
   `Task.async_stream/3` is not literally a *supervised* process (its tasks are
   linked, ephemeral, and unsupervised by any `Supervisor`), so it would not
   *violate* that decision in the strict sense — but it is the same *shape* of
   "concurrent process per tenant unit-of-work" REQ-045 moved away from, and
   choosing it here for no compelling boot-latency reason (point 1) would cut
   against the spirit of that decision for zero benefit. Sequential `Enum` avoids
   the question entirely: no process boundary is introduced per tenant at all,
   only a per-tenant `rescue` inside one ordinary function call — nothing here
   contradicts REQ-045's decision, `Letflow.InstanceSupervisor`'s deliberate
   emptiness, or any other existing decision record.

If tenant count ever grows large enough that sequential replay meaningfully delays
boot, that is a **future, separately-scoped optimization** (bounded concurrency via
`Task.async_stream/3` with an explicit `max_concurrency`, revisiting point 1's
assumption) — not built here, matching this module's own established precedent of
naming a future scaling concern explicitly rather than either building it
prematurely or ignoring it silently (mirrors §"Not in this requirement" style
already used elsewhere in this module's moduledoc, e.g. the reconciliation-sweep
non-scope in the ISS-0230 section).

---

## 5. Security-invariants scope test (for SECURITY-REVIEWER)

Per `docs/agents/instructions/security-invariants.md`'s applicability note, this
design is assessed against each invariant currently live (INV-1, INV-4, INV-7,
INV-8) plus INV-6 (the meta-invariant, always in scope for a new data-access path):

- **INV-1 (tenant data isolation) — applies, satisfied, no new mechanism.** This
  design introduces no new query or DDL-issuing path: `replay_all_pending/0` is pure
  orchestration over the existing `replay_migrations/2`, which already scopes every
  migration via `prefix: schema_name` (`Ecto.Migrator.run/4`'s `:prefix` option),
  the exact mechanism INV-1 requires. `MigrationReplayBoot` issues no queries of its
  own at all — it only calls `replay_all_pending/0` and logs the result.
- **INV-4 (secrets by reference only) — applies, satisfied.** The only new logging
  this design adds is `tenant_id`, `schema_name`, and a migration-failure `reason`
  (an `Exception.t()` or an atom-tagged tuple) — none of which are secret-shaped.
  `Letflow.Secrets.LogFilter`'s primary filter (registered first in
  `Letflow.Application.start/2`, before any supervision-tree child, including this
  one, ever starts) already redacts any secret-shaped metadata regardless, per
  REQ-190 §6.2 — this design does not need its own redaction, it inherits the
  existing filter by construction (it starts strictly after the filter is
  registered).
- **INV-6 (new data-access paths prove their scoping) — applies; this document is
  the proof artefact.** No new data-access *mechanism* is introduced (INV-1 above);
  the new "data-access path" here is narrowly a new *caller* — an automatic,
  unconditional one — of an already-scoped, already-reviewed primitive.
- **INV-7 (no SQL string interpolation) — applies, satisfied, no new SQL.** Neither
  `replay_all_pending/0` nor `MigrationReplayBoot` issues any `Repo.query`/raw SQL of
  its own; both are pure Elixir orchestration over existing Ecto/`Ecto.Migrator`
  calls.
- **INV-8 (no unhandled crashes on a realistic failure path) — applies; this is the
  design's central guarantee.** §4 states the two-layer rescue mechanism in full;
  §2.2/§2.3 state why `MigrationReplayBoot.start_link/1` must always return
  `:ignore` regardless of outcome, so that even a total-failure boot (every tenant's
  replay fails) cannot crash `Letflow.Supervisor.Infrastructure`'s own startup.
- **INV-2, INV-3, INV-5, INV-9 — not applicable**, for the same reasons stated in
  `security-invariants.md` itself (S4/S5 not started, or unrelated subject matter —
  INV-9's outbound-URL scope is webhooks-specific and untouched here).

---

## 6. Open questions (explicit, not resolved here)

1. **Should a persistently-failing tenant's boot-time replay failure surface
   anywhere operator-visible beyond logs** (a metric via `Letflow.Metrics.Registry`,
   an alert via the existing `Letflow.Obs.Alerts` hook-delivery path)? Both already
   exist in the supervision tree as of this design's call-site position. Left open —
   this design's acceptance criteria are satisfied by "logged individually, every
   boot," and wiring a metric/alert is a natural, separately-scoped follow-up rather
   than something ELIXIR-DEV should decide unprompted while implementing this
   design.
2. **Is there any value in also adding an explicit ops-facing `mix` task** (e.g.
   `mix letflow.replay_tenant_migrations`) wrapping `replay_all_pending/0`, for a
   scenario where an operator wants to force a replay without a full app restart
   (matching the exact remote-console workaround this issue's incident used)? Not
   required by this issue's acceptance criteria (the boot hook alone closes the
   automatic-replay gap) — left open as a possible convenience follow-up, not built
   here.
3. **Tenant-count-scale boot-latency optimization** (bounded `Task.async_stream/3`
   concurrency) — named explicitly in §4 as future, out-of-scope work, not a defect
   in this design at present tenant counts.

None of the above are prerequisites for ELIXIR-DEV to implement §2's signatures;
they are explicitly deferred rather than silently assumed either way, per this
module's own established moduledoc convention of naming open questions rather than
resolving them by omission.
