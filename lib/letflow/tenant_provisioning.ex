defmodule Letflow.TenantProvisioning do
  @moduledoc """
  PROVENANCE (historical, not current decision authority):
  Context module for schema-per-tenant provisioning — the mechanism
  `docs/migration/decisions/0003-ecto-schema-strategy.md` Decision B named but
  explicitly deferred out of REQ-015's scope (see
  `lib/letflow/design/identity-schema.md` section 1's "Follow-up work this
  creates"). Resolves that deferral: a `tenant_schemas` registry
  (`Letflow.TenantProvisioning.Registration`), a schema-provisioning function
  (`provision_tenant_schema/1`, mirroring R-Co's
  `public.bpm_provision_tenant_schema(p_tenant_id UUID)`), and a
  migration-replay mechanism (`replay_migrations/2`, mirroring R-Co's
  `src/db/migrations.zig`'s `runForSchema`).

  Matches this project's established `Letflow.Identity`-style pattern: a
  top-level context module in `lib/letflow/`, backed by schema file(s) in a
  same-named subdirectory (`lib/letflow/tenant_provisioning/registration.ex`).

  `provision_tenant_schema/1` and `replay_migrations/2` are two separate,
  composable primitives — neither calls the other. A future tenant-onboarding
  orchestration requirement sequences them explicitly; that orchestration is
  not built here (see `lib/letflow/design/req022-tenant-schema-provisioning.md`
  §3.2's "No implicit chaining invariant").

  See `lib/letflow/design/req022-tenant-schema-provisioning.md` for the full
  design this module implements.

  ## Open question (REQ-022 acceptance criterion 4 — not resolved here)

  REQ-015's `users`/`groups`/`tenant_role` tables currently live in the public
  default schema (per `lib/letflow/design/identity-schema.md` section 1's
  deferral). This requirement does not retrofit those three tables to live
  under each tenant's own schema — only `tenants` and this module's own
  `tenant_schemas` registry are structurally global (a realm→tenant lookup
  must run before any tenant schema is known, so those two cannot live inside
  a tenant schema by construction). Whether `users`/`groups`/`tenant_role`
  *should* eventually be retrofitted behind `:prefix` (precedent: R-Co's
  identity tables underwent the identical move behind schema-per-tenant,
  at migration-060) is left open for a future requirement to decide
  explicitly — not assumed either way by this module.

  ## `replay_migrations/2` also seeds platform event types (REQ-045 §9 OQ-3a,
  ## extended by ISS-0072/GH#257)

  When `replay_migrations/2` is called with its default `migration_source`
  (i.e. the real `tenant_scoped_migrations/0` manifest, not a caller-supplied
  one), it seeds 6 `event_type_registry` rows — `"INSTANCE_STARTED"`,
  `"TASK_COMPLETED"`, `"INSTANCE_CANCELLED"`, `"INSTANCE_PINS_REBOUND"`,
  `"SUB_PROCESS_COMPLETED"`, and `"EXECUTION_ERROR"` — immediately after
  migrations apply successfully. `Letflow.EventStore.Registry.validate_payload/3`
  otherwise fails closed with `{:error, :unknown_event_type}` for every
  tenant, since no shipped migration seeds these rows -- a 20-built-in-type
  seed was deliberately left out of
  `20260816163103_create_event_type_registry.exs` (that migration's own
  header comment: "nothing yet exists that emits them"). `INSTANCE_STARTED`
  was seeded first, for `Letflow.Engine.create/2` (REQ-045). The other 5 were
  added by ISS-0072/GH#257, which found each already had a real production
  writer (`Letflow.Engine.complete_task/3`, `Letflow.Engine.cancel_instance/3`,
  `Letflow.Engine.PinRebind.rebind_pins/3`, `Letflow.Engine.SubProcess`'s
  sub-process completion path, and
  `Letflow.Engine.ExecutionError.append_execution_error_event/2`
  respectively) with no corresponding registry row — a pre-existing
  operational gap, closed here. Idempotent, and skipped entirely when a
  caller passes an explicit `migration_source` (so
  `test/support/req022_migration_fixture.ex`'s fixture-only replay is
  unaffected). See `replay_migrations/2`'s own private
  `maybe_seed_platform_event_types/2` for the full reasoning.

  ## Secondary open question (surfaced during design, not in REQ-022's
  original list)

  Should `provision_tenant_schema/1` or some other entry point eventually
  validate that a tenant's `Letflow.Identity.Tenant.status` is `:active` (not
  `:migrating`) before provisioning proceeds? REQ-021's
  `Letflow.Plugs.TenantStatus` already gates *mutating requests* on this
  status for existing tenants; `provision_tenant_schema/1` does not check it —
  left for a future tenant-onboarding-orchestration requirement to decide
  explicitly.

  ## No reconciliation path for a half-provisioned tenant (ISS-0230/GH#468 —
  ## OBLIGATION ON WHOEVER BUILDS THE ONBOARDING ORCHESTRATION)

  **Read this before sequencing the two primitives above from any new call
  site.** A caller that runs `Letflow.Identity.create_tenant/1` →
  `provision_tenant_schema/1` → `replay_migrations/2` commits the `tenants` row
  first. If either later step fails, the row stays committed and the tenant is
  left half-provisioned. There is **no** reconciliation, retry, or sweep
  mechanism anywhere in this codebase that will ever notice or repair such a
  tenant — nothing calls these two functions except the caller that just failed.

  A compensating rollback is **deliberately not** the answer and must not be
  added (REVIEWER's finding on ISS-0230): if `provision_tenant_schema/1` already
  succeeded and only `replay_migrations/2` failed, deleting the `tenants` row
  orphans a real Postgres schema plus a `tenant_schemas` row pointing at a
  `tenant_id` no longer present in `tenants` — trading a recoverable partial
  state for an unrecoverable orphan.

  Measured first-hand in run `WF03-ISS0230-20260822` (real Postgres, replay
  forced to fail), so the next implementer does not have to re-derive it:

    * `replay_migrations/2` returns a clean `{:error, {:migration_failed, _}}`;
      it does not raise, so a `with/else` at the call site sees it.
    * The resulting state is: `tenants` row present, `tenant_schemas` row
      present, the Postgres schema created but **empty**, and
      `Registration.migrations_applied_at` `nil`.
    * `migrations_applied_at IS NULL` is therefore already a sufficient,
      shipped **detection** predicate for "provisioned but not migrated" — a
      sweep needs no new column.
    * Re-invoking **both** primitives with the same `tenant_id` fully converges
      the state (`migrations_applied_at` set, tables present, still exactly one
      `tenant_schemas` row). The recovery *capability* exists today; only the
      orchestration that invokes it does not.
    * The tenant's `status` was `:active` throughout — an unmigrated tenant is
      currently advertised as fully live. Whoever builds onboarding should
      decide this together with the secondary open question above: creating the
      tenant `:migrating` and flipping to `:active` only after replay succeeds
      would make the partial state self-describing and would let
      `Letflow.Plugs.TenantStatus` reject *writes* against it with 503.
      **But `:migrating` is not a complete answer, and it is not free.** That
      plug gates write methods only (`@write_methods ~w(POST PUT PATCH
      DELETE)`; its other `call/2` clause returns the conn untouched), so
      `GET`/`HEAD` pass through with no status check and no DB query at all —
      a `:migrating` half-provisioned tenant would still serve *reads* straight
      onto the empty schema, hitting a relation that does not exist. Closing or
      explicitly accepting that read gap is part of the decision, not something
      `:migrating` hands you for free.

  What REQ-076 owes is an **invocable** recovery entry point — a function an
  operator or a test calls with a `tenant_id`. An automatic reconciliation
  sweep is deliberately *not* in scope: it needs a scheduler, there is no
  scheduler subsystem to hang one on, and adding a supervision-tree child for
  it is scope creep. The `migrations_applied_at IS NULL` predicate is recorded
  above so a future sweep requirement need not re-derive it — not as licence to
  build the sweep now.

  This is left unbuilt here on purpose. Adding a function to this module that
  calls both primitives would be exactly the coupling
  `lib/letflow/design/req022-tenant-schema-provisioning.md` §3.2's "No implicit
  chaining invariant" forbids; the orchestration layer is a caller's job, not
  this module's. `REQ-076` (tenant onboarding, S4) owns that layer and carries
  an explicit acceptance criterion for this gap — see its entry in
  `docs/requirements.yaml`. `docs/issues/ISS-0230.yaml` records the full
  reasoning.
  """

  import Ecto.Query

  alias Letflow.EventStore.Registry
  alias Letflow.Repo
  alias Letflow.TenantProvisioning.Registration

  @doc """
  Derives the physical Postgres schema name for a tenant. Pure, no I/O — safe
  to unit-test directly. Returns `{:error, :invalid_tenant_id}` for anything
  `Ecto.UUID.cast/1` rejects.

  **Deliberate divergence from R-Co's `schemaNameForTenant`:** R-Co
  special-cases the all-zero UUID to the literal name `tenant_default`.
  Letflow has no equivalent reserved default-tenant UUID (every tenant,
  including `slug == "bpm-default"`, gets a normal randomly-generated
  `binary_id` — see `lib/letflow/identity/tenant.ex`), so this function
  applies the same `"tenant_" <> hex` derivation uniformly, with no special
  case.
  """
  @spec schema_name_for_tenant(tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_name :: String.t()} | {:error, :invalid_tenant_id}
  def schema_name_for_tenant(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, canonical} -> {:ok, "tenant_" <> String.replace(canonical, "-", "")}
      :error -> {:error, :invalid_tenant_id}
    end
  end

  @doc """
  The reverse of `schema_name_for_tenant/1`: derives `tenant_id` back out of an
  already-resolved physical schema name. Pure, no I/O — deliberately does
  **not** confirm the tenant is actually provisioned (no `Registration`
  query); that existence check happens downstream, for free, wherever the
  caller's own flow needs it (e.g. `Letflow.EventStore.Registry.validate_payload/3`'s
  `resolve_schema_name/1`).

  This is the mechanism `docs/migration/decisions/0003-ecto-schema-strategy.md`'s
  2026-08-17 addendum names: a context module about to write a tenant-scoped
  row reverses `schema_name_for_tenant/1`'s encoding to obtain the `tenant_id`
  it stamps on the row, rather than accepting `tenant_id` as an independently
  -trusted caller-supplied field. See `lib/letflow/design/req025-event-append.md`
  §4 for the full design.

  Total and deterministic for any `schema_name` shaped like
  `"tenant_" <> <32 lowercase hex chars>` — `schema_name_for_tenant/1` has no
  special-cased default-tenant UUID, so there is no lossy branch to invert
  incorrectly. Returns `{:error, :invalid_schema_name}` for anything else.
  """
  @spec tenant_id_for_schema_name(schema_name :: String.t()) ::
          {:ok, tenant_id :: Ecto.UUID.t()} | {:error, :invalid_schema_name}
  def tenant_id_for_schema_name(schema_name) when is_binary(schema_name) do
    with "tenant_" <> hex <- schema_name,
         true <- String.match?(hex, ~r/^[0-9a-f]{32}$/),
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>> <- hex,
         canonical = Enum.join([a, b, c, d, e], "-"),
         {:ok, _} <- Ecto.UUID.cast(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_schema_name}
    end
  end

  def tenant_id_for_schema_name(_schema_name), do: {:error, :invalid_schema_name}

  @doc """
  Lists every provisioned tenant's `Registration` row -- a plain
  `Repo.all(Registration)`, no new query logic. Added for REQ-191's
  cross-schema referential guard (`Letflow.ServiceCatalog`'s `delete/2`/
  `update_scope/2`, design `lib/letflow/design/req191-service-catalog-core.md`
  §4 step 1), which must enumerate every tenant schema to check for
  `process_definitions` rows referencing a service, since
  `process_definitions` is a per-tenant-schema table with no global home
  (Decision B) and this module is the sole registry of which schemas exist.

  This is a read-only addition -- no existing function's behavior changes.
  Flagged (per the design doc's OQ-3) as a minimal extension to this
  module's public surface beyond REQ-191's own stated scope, for REVIEWER to
  confirm is acceptable rather than scope creep.
  """
  @spec list_registrations() :: [Registration.t()]
  def list_registrations do
    Repo.all(Registration)
  end

  @doc """
  Idempotently provisions a tenant's physical Postgres schema: derives the
  schema name, serializes concurrent calls for the same tenant via a
  transaction-scoped advisory lock, issues `CREATE SCHEMA IF NOT EXISTS`, and
  records the mapping in `tenant_schemas` — all inside one `Repo.transaction/1`
  so a `tenant_id` that doesn't correspond to an existing tenant rolls back
  the whole operation, including the schema-creation DDL (Postgres DDL is
  transactional).

  Calling this twice for the same `tenant_id` is **not an error** — the
  second call returns `{:ok, %Registration{}}` with the same row the first
  call created: safe to call repeatedly, e.g. from a retried onboarding
  step, without erroring on a tenant that's already provisioned.
  """
  @spec provision_tenant_schema(tenant_id :: Ecto.UUID.t()) ::
          {:ok, Registration.t()}
          | {:error, :invalid_tenant_id}
          | {:error, :tenant_not_found}
          | {:error, term()}
  def provision_tenant_schema(tenant_id) do
    case schema_name_for_tenant(tenant_id) do
      {:error, :invalid_tenant_id} = error ->
        error

      {:ok, schema_name} ->
        Repo.transaction(fn ->
          # Ports R-Co's `PERFORM pg_advisory_xact_lock(hashtext(v_schema_name))` --
          # a normal parameterized query ($1), no identifier interpolation
          # involved at this step, no INV-7 concern here.
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema_name])

          # The only raw-SQL identifier interpolation in this module.
          # `schema_name` is never taken directly from an external caller at
          # this point -- it is always the output of schema_name_for_tenant/1
          # above, which only emits strings matching `tenant_[0-9a-f]{32}`
          # (guaranteed by construction: it only proceeds past
          # Ecto.UUID.cast/1, which normalizes to exactly that character
          # set). See this module's design doc §3.1 for the full
          # identifier-injection safety invariant. CREATE SCHEMA cannot be
          # parameterized like a normal SQL value (DDL identifiers aren't
          # bind-param targets), so this interpolation is the only available
          # mechanism -- safety here comes from schema_name's constrained
          # shape, not from parameterization.
          Repo.query!(~s(CREATE SCHEMA IF NOT EXISTS "#{schema_name}"))

          case insert_or_fetch_registration(tenant_id, schema_name) do
            {:ok, %Registration{} = registration} ->
              registration

            {:error, :tenant_not_found} ->
              Repo.rollback(:tenant_not_found)

            {:error, %Ecto.Changeset{} = changeset} ->
              Repo.rollback(changeset)
          end
        end)
    end
  end

  @doc """
  Re-applies `migration_source` (defaults to `tenant_scoped_migrations/0`)
  against a tenant's already-provisioned schema, via `Ecto.Migrator.run/4`'s
  `:prefix` option. Never provisions on the fly — returns
  `{:error, :tenant_not_provisioned}` immediately if no `Registration` row
  exists for `tenant_id`.

  `Ecto.Migrator.run/4` itself returns a bare list on success and *raises* on
  failure (confirmed directly from `deps/ecto_sql/lib/ecto/migrator.ex`); this
  function wraps that call in `try/rescue`, converting any raised exception
  into `{:error, {:migration_failed, exception}}`, to produce this project's
  established `{:ok, _} | {:error, _}` convention
  (`backend_developer_guide.md` §3.5) at this module's public boundary.

  `migration_source` defaults to `nil`, resolved to `tenant_scoped_migrations/0`
  *inside* the `try` below rather than as the parameter's own default
  expression (ISS-0019/GH#75) — an Elixir default argument is evaluated by a
  compiler-generated lower-arity clause that runs *before* the full-arity
  body, so `tenant_scoped_migrations()` used to run outside this function's
  own `try/rescue` and any raise it produced (e.g. `Code.LoadError` from a
  manifest-named migration file missing at deploy time, since
  `tenant_scoped_migrations/0` now does real `Code.require_file` work per
  ISS-0017) escaped as a raw exception instead of the `{:error,
  {:migration_failed, _}}` this `@spec` promises. Resolving the default
  inside the `try` puts it under the same guard as `Ecto.Migrator.run/4`
  itself, so both failure sources produce the identical tagged error.
  """
  @spec replay_migrations(
          tenant_id :: Ecto.UUID.t(),
          migration_source :: [{version :: pos_integer(), module()}] | nil
        ) ::
          {:ok, applied_versions :: [pos_integer()]}
          | {:error, :tenant_not_provisioned}
          | {:error, {:migration_failed, Exception.t()}}
  def replay_migrations(tenant_id, migration_source \\ nil) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      nil ->
        {:error, :tenant_not_provisioned}

      %Registration{schema_name: schema_name} ->
        try do
          using_default_manifest? = is_nil(migration_source)
          migrations = migration_source || tenant_scoped_migrations()

          applied_versions =
            Ecto.Migrator.run(Repo, migrations, :up,
              all: true,
              prefix: schema_name,
              log: false
            )

          mark_migrations_applied(tenant_id)

          with :ok <- maybe_seed_platform_event_types(using_default_manifest?, tenant_id) do
            {:ok, applied_versions}
          end
        rescue
          exception -> {:error, {:migration_failed, exception}}
        end
    end
  end

  # {version, module, filename} for every tenant-scoped migration, in ascending
  # version order. The third element exists only so tenant_scoped_migrations/0
  # can load the module — see that function's @doc. The version integers MUST
  # equal the filenames' timestamp prefixes.
  #
  # REQ-023's six event-store migrations (lib/letflow/design/req023-event-store-schema.md
  # §4) followed by REQ-024's event_type_registry migration
  # (lib/letflow/design/req024-event-type-registry.md §3), REQ-027's two
  # definition-core migrations (lib/letflow/design/req027-definition-core-schema.md §4),
  # REQ-035's promotion_reviews migration
  # (lib/letflow/design/req035-promotion-reviews-schema.md §4), REQ-040's
  # promotion_assertion_runs migration
  # (lib/letflow/design/req040-promotion-assertion-rerun.md §4), REQ-043's three
  # instance-engine-schema migrations -- the instance_projections engine-columns
  # ALTER TABLE, tokens, and tasks
  # (lib/letflow/design/req043-instance-engine-schema.md §7), REQ-063's three
  # per-tenant identity-table migrations -- groups, tenant_role, users
  # (lib/letflow/design/req063-identity-tables-schema-per-tenant.md §2/§3), and
  # REQ-064's ten Decision-0006-D2 tenant_id-drop migrations -- events,
  # events_archive, instance_projections, process_definitions, tokens, tasks,
  # promotion_reviews, promotion_assertion_runs, users, groups
  # (lib/letflow/design/req064-drop-tenant-id.md §2), REQ-054's
  # instance_state_snapshots migration
  # (lib/letflow/design/req054-instance-state-snapshots.md §3), and REQ-109's
  # variable_schemas migration
  # (lib/letflow/design/req109-variable-schemas.md §2/§2.3) — thirty-one
  # entries in total. That total also counts two entries this prose does not
  # enumerate by requirement id above: the sub-process parent-columns ALTER
  # (20260819045553) and the lua_script_execution_audit migration
  # (20260820000011); the list below, not this comment, is authoritative.
  # Each of these files carries the §4 guard pattern; registration here
  # is the other mandatory half. REQ-063's own guarded DROP migration
  # (20260819000004_drop_legacy_public_identity_tables.exs) is deliberately NOT
  # listed here -- it is a global-schema migration, not tenant-scoped, per that
  # migration's own header comment.
  @tenant_scoped_migration_manifest [
    {20_260_816_120_001, Letflow.Repo.Migrations.CreateEvents,
     "20260816120001_create_events.exs"},
    {20_260_816_120_002, Letflow.Repo.Migrations.CreateInstanceSequence,
     "20260816120002_create_instance_sequence.exs"},
    {20_260_816_120_003, Letflow.Repo.Migrations.CreateInstanceProjections,
     "20260816120003_create_instance_projections.exs"},
    {20_260_816_120_004, Letflow.Repo.Migrations.CreateEventPayloadStore,
     "20260816120004_create_event_payload_store.exs"},
    {20_260_816_120_005, Letflow.Repo.Migrations.CreateEventsArchive,
     "20260816120005_create_events_archive.exs"},
    {20_260_816_120_006, Letflow.Repo.Migrations.CreateEventIdempotency,
     "20260816120006_create_event_idempotency.exs"},
    {20_260_816_163_103, Letflow.Repo.Migrations.CreateEventTypeRegistry,
     "20260816163103_create_event_type_registry.exs"},
    {20_260_816_193_001, Letflow.Repo.Migrations.CreateProcessDefinitions,
     "20260816193001_create_process_definitions.exs"},
    {20_260_816_193_002, Letflow.Repo.Migrations.CreateInstanceDefinitionSnapshots,
     "20260816193002_create_instance_definition_snapshots.exs"},
    {20_260_816_200_001, Letflow.Repo.Migrations.CreatePromotionReviews,
     "20260816200001_create_promotion_reviews.exs"},
    {20_260_818_090_001, Letflow.Repo.Migrations.CreatePromotionAssertionRuns,
     "20260818090001_create_promotion_assertion_runs.exs"},
    {20_260_818_110_001, Letflow.Repo.Migrations.AlterInstanceProjectionsAddEngineColumns,
     "20260818110001_alter_instance_projections_add_engine_columns.exs"},
    {20_260_818_110_002, Letflow.Repo.Migrations.CreateTokens,
     "20260818110002_create_tokens.exs"},
    {20_260_818_110_003, Letflow.Repo.Migrations.CreateTasks, "20260818110003_create_tasks.exs"},
    {20_260_819_000_001, Letflow.Repo.Migrations.CreateGroupsTenantScoped,
     "20260819000001_create_groups_tenant_scoped.exs"},
    {20_260_819_000_002, Letflow.Repo.Migrations.CreateTenantRoleTenantScoped,
     "20260819000002_create_tenant_role_tenant_scoped.exs"},
    {20_260_819_000_003, Letflow.Repo.Migrations.CreateUsersTenantScoped,
     "20260819000003_create_users_tenant_scoped.exs"},
    {20_260_819_045_553, Letflow.Repo.Migrations.AddSubProcessParentColumns,
     "20260819045553_add_sub_process_parent_columns.exs"},
    {20_260_820_000_001, Letflow.Repo.Migrations.DropTenantIdEvents,
     "20260820000001_drop_tenant_id_events.exs"},
    {20_260_820_000_002, Letflow.Repo.Migrations.DropTenantIdEventsArchive,
     "20260820000002_drop_tenant_id_events_archive.exs"},
    {20_260_820_000_003, Letflow.Repo.Migrations.DropTenantIdInstanceProjections,
     "20260820000003_drop_tenant_id_instance_projections.exs"},
    {20_260_820_000_004, Letflow.Repo.Migrations.DropTenantIdProcessDefinitions,
     "20260820000004_drop_tenant_id_process_definitions.exs"},
    {20_260_820_000_005, Letflow.Repo.Migrations.DropTenantIdTokens,
     "20260820000005_drop_tenant_id_tokens.exs"},
    {20_260_820_000_006, Letflow.Repo.Migrations.DropTenantIdTasks,
     "20260820000006_drop_tenant_id_tasks.exs"},
    {20_260_820_000_007, Letflow.Repo.Migrations.DropTenantIdPromotionReviews,
     "20260820000007_drop_tenant_id_promotion_reviews.exs"},
    {20_260_820_000_008, Letflow.Repo.Migrations.DropTenantIdPromotionAssertionRuns,
     "20260820000008_drop_tenant_id_promotion_assertion_runs.exs"},
    {20_260_820_000_009, Letflow.Repo.Migrations.DropTenantIdUsers,
     "20260820000009_drop_tenant_id_users.exs"},
    {20_260_820_000_010, Letflow.Repo.Migrations.DropTenantIdGroups,
     "20260820000010_drop_tenant_id_groups.exs"},
    {20_260_820_000_011, Letflow.Repo.Migrations.CreateLuaScriptExecutionAudit,
     "20260820000011_create_lua_script_execution_audit.exs"},
    {20_260_821_000_001, Letflow.Repo.Migrations.CreateInstanceStateSnapshots,
     "20260821000001_create_instance_state_snapshots.exs"},
    {20_260_821_000_002, Letflow.Repo.Migrations.CreateVariableSchemas,
     "20260821000002_create_variable_schemas.exs"},
    {20_260_822_000_101, Letflow.Repo.Migrations.AlterGroupsAddDisplayNameDescription,
     "20260822000101_alter_groups_add_display_name_description.exs"},
    {20_260_822_000_102, Letflow.Repo.Migrations.CreateGroupMembersTenantScoped,
     "20260822000102_create_group_members_tenant_scoped.exs"},
    {20_260_823_000_001, Letflow.Repo.Migrations.CreateApiTokensTenantScoped,
     "20260823000001_create_api_tokens_tenant_scoped.exs"},
    {20_260_823_000_003, Letflow.Repo.Migrations.AddSequenceNumberToProcessDefinitions,
     "20260823000003_add_sequence_number_to_process_definitions.exs"},
    {20_260_823_000_004, Letflow.Repo.Migrations.CreateDefinitionSequence,
     "20260823000004_create_definition_sequence.exs"},
    {20_260_829_000_001, Letflow.Repo.Migrations.CreateDlqEntries,
     "20260829000001_create_dlq_entries.exs"},
    {20_260_829_010_001, Letflow.Repo.Migrations.CreateWebhookSubscriptions,
     "20260829010001_create_webhook_subscriptions.exs"},
    {20_260_829_020_001, Letflow.Repo.Migrations.CreateTimers,
     "20260829020001_create_timers.exs"},
    {20_260_830_000_004, Letflow.Repo.Migrations.AddSecretRefToWebhookSubscriptions,
     "20260830000004_add_secret_ref_to_webhook_subscriptions.exs"},
    {20_260_830_010_001, Letflow.Repo.Migrations.CreateWebhookDeliveryAttempts,
     "20260830010001_create_webhook_delivery_attempts.exs"},
    {20_260_830_020_001, Letflow.Repo.Migrations.CreateAuditEntriesTenantScoped,
     "20260830020001_create_audit_entries_tenant_scoped.exs"},
    {20_260_830_030_001, Letflow.Repo.Migrations.CreateRepositoryArtifacts,
     "20260830030001_create_repository_artifacts.exs"},
    {20_260_830_040_001, Letflow.Repo.Migrations.CreateAlertTriggerState,
     "20260830040001_create_alert_trigger_state.exs"},
    {20_260_830_040_002, Letflow.Repo.Migrations.CreateAlertHookEmissionState,
     "20260830040002_create_alert_hook_emission_state.exs"},
    {20_260_831_000_001, Letflow.Repo.Migrations.CreateArtifactActivations,
     "20260831000001_create_artifact_activations.exs"},
    {20_260_831_050_001, Letflow.Repo.Migrations.CreateEffectCompletions,
     "20260831050001_create_effect_completions.exs"},
    {20_260_831_050_002, Letflow.Repo.Migrations.CreateCorrelationCursors,
     "20260831050002_create_correlation_cursors.exs"},
    {20_260_901_000_001, Letflow.Repo.Migrations.AddContentToRepositoryArtifacts,
     "20260901000001_add_content_to_repository_artifacts.exs"},
    {20_260_901_000_002, Letflow.Repo.Migrations.CreateInstanceAttachments,
     "20260901000002_create_instance_attachments.exs"},
    {20_260_901_030_001, Letflow.Repo.Migrations.AddJoinCountersToInstanceProjections,
     "20260901030001_add_join_counters_to_instance_projections.exs"},
    {20_260_902_000_001, Letflow.Repo.Migrations.MakeTokensBranchIdNullable,
     "20260902000001_make_tokens_branch_id_nullable.exs"},
    {20_260_902_010_001, Letflow.Repo.Migrations.CreateServiceTaskDispatches,
     "20260902010001_create_service_task_dispatches.exs"},
    {20_260_906_000_001, Letflow.Repo.Migrations.CreateEntityDefinitions,
     "20260906000001_create_entity_definitions.exs"}
  ]

  @doc """
  The designated tenant-scoped subset of `priv/repo/migrations/` —
  `replay_migrations/2`'s default `migration_source`. REQ-022 itself
  contributes zero entries (its own `CreateTenantSchemas` migration is
  global-only, see the migration's header comment); REQ-023 contributes the six
  event-store migrations (`lib/letflow/design/req023-event-store-schema.md` §4),
  REQ-024 the `event_type_registry` migration
  (`lib/letflow/design/req024-event-type-registry.md` §3), REQ-027 the two
  definition-core migrations, `process_definitions` and
  `instance_definition_snapshots`
  (`lib/letflow/design/req027-definition-core-schema.md` §4), REQ-035 the
  `promotion_reviews` migration
  (`lib/letflow/design/req035-promotion-reviews-schema.md` §4), REQ-040 the
  `promotion_assertion_runs` migration
  (`lib/letflow/design/req040-promotion-assertion-rerun.md` §4), REQ-043 three
  more: the `instance_projections` engine-columns `ALTER TABLE`, `tokens`, and
  `tasks` (`lib/letflow/design/req043-instance-engine-schema.md` §7), REQ-063
  three more: `groups`, `tenant_role`, and `users` moved behind schema-per-tenant
  (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md` §2/§3),
  REQ-064 ten more: the `tenant_id`-drop migrations for `events`,
  `events_archive`, `instance_projections`, `process_definitions`, `tokens`,
  `tasks`, `promotion_reviews`, `promotion_assertion_runs`, `users`, and
  `groups` (`lib/letflow/design/req064-drop-tenant-id.md` §2), and REQ-054 one
  more: `instance_state_snapshots`
  (`lib/letflow/design/req054-instance-state-snapshots.md` §3), REQ-176 one
  more: `dlq_entries` (`lib/letflow/design/req176-dlq-core.md` §4), REQ-181
  one more: `webhook_subscriptions`
  (`lib/letflow/design/req181-webhooks-core.md` §1), REQ-186 one more:
  `timers` (`lib/letflow/design/req186-scheduler-core.md` §1), and REQ-183
  one more: `webhook_delivery_attempts`
  (`lib/letflow/design/req183-webhook-delivery-dispatch.md` §1) —
  entries in total (see `@tenant_scoped_migration_manifest` itself for the
  authoritative, up-to-date count), ordered by version. Every future tenant-scoped migration must append its
  own entry to `@tenant_scoped_migration_manifest`, in addition to following the
  required guard pattern in its own migration file (see this module's design doc
  §4) — a migration file that does one without the other is either inert
  (never selected here) or corrupts `public` on a plain `mix ecto.migrate` run
  (added here without the guard).

  **This function loads each listed migration module before returning it.**
  `Ecto.Migrator` resolves a `{version, module}` source through
  `load_migration!/1`, which requires `Code.ensure_loaded?(module)` to be true
  (`deps/ecto_sql/lib/ecto/migrator.ex`), but `priv/repo/migrations/*.exs` is
  never compiled into the application — `mix.exs` sets `elixirc_paths` to
  `["lib"]` (plus `test/support` under `:test`), so no `.beam` file exists for
  any migration module. Without this loading step `Ecto.Migrator.run/4` raises
  `Ecto.MigrationError: module ... is not an Ecto.Migration`, which
  `replay_migrations/2` surfaces as `{:error, {:migration_failed, exception}}`.

  That failure is state-dependent, which is why REQ-022 never hit it: only
  *pending* migrations reach `load_migration!/1`, and `mix.exs`'s `test:` alias
  runs `ecto.migrate` in the same VM, which defines pending migration modules via
  `Code.compile_file/1`. So the bug is invisible against a freshly-migrated test
  database and appears against an already-migrated one — and always appears in an
  `iex -S mix` session or a release, where `mix ecto.migrate` never ran in-process
  at all.

  `Code.require_file/1` is idempotent, and the `Code.ensure_loaded?/1` guard
  additionally covers the case where such a `mix ecto.migrate` run already
  defined the module in this VM — which `require_file/1` would not know about and
  would otherwise redefine, emitting a "redefining module" warning.

  This function's `@spec` is unchanged from REQ-022's: the return shape is still
  `[{version, module}]`, and the manifest's third element never escapes it.

  REQ-024's `event_type_registry` entry originally shipped in the bare
  `{version, module}` form and carried that same latent failure; routing it
  through the manifest here repairs it too, rather than leaving one entry
  loadable only by accident. Every entry added since — REQ-027's two — uses the
  three-element form for the same reason; reverting any of them to the bare
  `{version, module}` shape would reintroduce the defect.
  """
  @spec tenant_scoped_migrations() :: [{version :: pos_integer(), module()}]
  def tenant_scoped_migrations do
    Enum.map(@tenant_scoped_migration_manifest, fn {version, module, filename} ->
      ensure_migration_module_loaded!(module, filename)
      {version, module}
    end)
  end

  # Application.app_dir/2 resolves through _build, where Mix links (or, on
  # Windows, copies) priv/ on every build — so this path is correct in dev, test
  # and a release alike.
  defp ensure_migration_module_loaded!(module, filename) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      [Application.app_dir(:letflow, "priv"), "repo", "migrations", filename]
      |> Path.join()
      |> Code.require_file()

      :ok
    end
  end

  # Reuses the exact idiom already established and empirically verified in
  # Letflow.Identity's insert_or_fetch/3 + re_select_on_conflict/2 (see
  # lib/letflow/identity.ex): client-generated binary_id PKs make
  # {:ok, struct} indistinguishable between "really inserted" and
  # "suppressed by ON CONFLICT" without an extra existence check.
  defp insert_or_fetch_registration(tenant_id, schema_name) do
    attrs = %{tenant_id: tenant_id, schema_name: schema_name}
    changeset = Registration.changeset(%Registration{}, attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: :tenant_id,
           returning: true
         ) do
      {:ok, %Registration{id: id} = inserted} ->
        if Repo.get(Registration, id) do
          {:ok, inserted}
        else
          re_select_registration(tenant_id)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        if foreign_key_violation?(changeset, :tenant_id) do
          {:error, :tenant_not_found}
        else
          {:error, changeset}
        end
    end
  end

  defp re_select_registration(tenant_id) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      %Registration{} = existing -> {:ok, existing}
      nil -> {:error, :tenant_not_found}
    end
  end

  defp foreign_key_violation?(%Ecto.Changeset{errors: errors}, field) do
    Enum.any?(errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :foreign
      _ -> false
    end)
  end

  defp mark_migrations_applied(tenant_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    from(r in Registration, where: r.tenant_id == ^tenant_id)
    |> Repo.update_all(set: [migrations_applied_at: now])
  end

  # Seeds 6 event_type_registry rows (REQ-045 §9 OQ-3a, extended by
  # ISS-0072/GH#257) -- only when replay_migrations/2 ran the real, default
  # production manifest (tenant_scoped_migrations/0), never when a caller
  # passed an explicit migration_source. This distinction matters: a
  # caller-supplied migration_source (test/support/req022_migration_fixture.ex's
  # own {1, MigrationFixture} case, exercised by
  # test/letflow/tenant_provisioning_test.exs) may not include
  # event_type_registry's own migration at all, so unconditionally seeding
  # here would attempt an insert against a table that doesn't exist in that
  # schema and turn an otherwise-passing replay into a crash.
  #
  # Why this lives in replay_migrations/2 and not provision_tenant_schema/1
  # (REQ-045's own design doc names both as candidate extension points):
  # event_type_registry is a tenant-scoped table created by a *migration*
  # (priv/repo/migrations/20260816163103_create_event_type_registry.exs),
  # replayed here via Ecto.Migrator.run/4 above -- it does not exist yet at
  # provision_tenant_schema/1's own point in a tenant's onboarding sequence
  # (that function only creates the bare Postgres schema and the
  # tenant_schemas registry row; migration replay is this module's own
  # moduledoc's "two separate, composable primitives" the caller sequences
  # itself). Seeding here, immediately after this same call's own
  # Ecto.Migrator.run/4 succeeds, is the earliest point the table is
  # guaranteed to exist.
  #
  # Idempotent by construction: Letflow.EventStore.Registry.register_type/2's
  # own (name, schema_version) collision -- {:error, :duplicate_event_type_version}
  # -- is treated as success here, for every entry in the list below, so a
  # second replay_migrations/2 call against an already-seeded tenant schema
  # (Ecto.Migrator.run/4 itself is already idempotent on re-applying
  # migrations) is also a no-op on this step for all 6 types, not a hard
  # failure.
  #
  # REQ-045's own OQ-3a was narrowly scoped to "INSTANCE_STARTED" (the one
  # event type EE-01's Letflow.Engine.create/2 actually appends). ISS-0072
  # (GH#257) found 5 additional event types with real production writers and
  # no registry row -- each was silently failing EventStore.append/2 with
  # {:error, :unknown_event_type} -- and they are seeded here too:
  # "TASK_COMPLETED" (Letflow.Engine.complete_task/3), "INSTANCE_CANCELLED"
  # (Letflow.Engine.cancel_instance/3), "INSTANCE_PINS_REBOUND"
  # (Letflow.Engine.PinRebind.rebind_pins/3), "SUB_PROCESS_COMPLETED"
  # (Letflow.Engine.SubProcess's sub-process completion path), and
  # "EXECUTION_ERROR" (Letflow.Engine.ExecutionError.append_execution_error_event/2).
  #
  # "DEFINITION_PROMOTED", "DEFINITION_VERSION_ROLLED_BACK", and
  # "PROMOTION_ASSERTION_TEARDOWN_FAILED" (REQ-140) now have production
  # writers: the three Letflow.EventStore.PlatformEvents adapter functions
  # (append_definition_promoted/2, append_definition_version_rolled_back/2,
  # append_promotion_assertion_teardown_failed/2) built by REQ-140, each
  # satisfying Letflow.Definitions's event_appender_fun/0 contract. Nothing
  # yet calls those functions from a live route -- wiring opts[:event_appender]
  # defaults into REQ-077's ported promotion routes is that requirement's
  # job, not this one's.
  @platform_event_type_seed_attrs [
    %{
      name: "INSTANCE_STARTED",
      schema_version: 1,
      description:
        "Emitted once by Letflow.Engine.create/2 (EE-01) when a new process instance starts.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "definition_id" => %{"type" => "string"},
          "correlation_key" => %{"type" => ["string", "null"]},
          "initial_variables" => %{"type" => "object"}
        },
        "required" => ["definition_id", "initial_variables"]
      }
    },
    %{
      name: "TASK_COMPLETED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.complete_task/3 (M9, EE-04) when a user task is completed.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "task_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
                "key" => %{"type" => "string"}
              },
              "required" => ["event", "key"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["task_id", "node_id", "output_variables", "activated_nodes"]
      }
    },
    %{
      name: "INSTANCE_CANCELLED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.cancel_instance/3 (M6) when a running instance is cancelled.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "cancelled_task_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
          "cancelled_token_ids" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["cancelled_task_ids", "cancelled_token_ids"]
      }
    },
    %{
      name: "INSTANCE_PINS_REBOUND",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.PinRebind.rebind_pins/3 (M6) when a definition/sub-process " <>
          "version pin is rebound.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "entries" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "kind" => %{"type" => "string"},
                "ref" => %{"type" => "string"},
                "prior_version" => %{"type" => "string"},
                "new_version" => %{"type" => "string"}
              },
              "required" => ["kind", "ref", "new_version"]
            }
          },
          "actor" => %{"type" => "string"},
          "reason" => %{"type" => ["string", "null"]}
        },
        "required" => ["entries", "actor"]
      }
    },
    %{
      name: "SUB_PROCESS_COMPLETED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.SubProcess (M-series) on the parent instance's stream when " <>
          "a called sub-process instance completes and its output is merged back.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "child_instance_id" => %{"type" => "string"},
          "output_variables" => %{"type" => "object"},
          "merged_variable_events" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "event" => %{"type" => "string", "enum" => ["variable_overwritten"]},
                "key" => %{"type" => "string"}
              },
              "required" => ["event", "key"]
            }
          },
          "activated_nodes" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["child_instance_id", "output_variables", "activated_nodes"]
      }
    },
    %{
      name: "EXECUTION_ERROR",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.ExecutionError.append_execution_error_event/2 (EE-10 AC1) " <>
          "when an instance transitions to the :error status.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "error_type" => %{"type" => "string"},
          "affected" => %{
            "type" => "object",
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => ["node", "field"]},
              "node_id" => %{"type" => "string"},
              "key" => %{"type" => "string"}
            },
            "required" => ["kind"]
          },
          "reason" => %{"type" => "string"},
          "variables" => %{"type" => "object"},
          "details" => %{"type" => "object"}
        },
        "required" => ["error_type", "affected", "reason", "variables"]
      }
    },
    %{
      name: "DEFINITION_PROMOTED",
      schema_version: 2,
      description:
        "Emitted by Letflow.Definitions.Promotion.promote_definition/3 (PRM-01, the " <>
          "review-gated path) AND Letflow.Definitions.Promotion.promote_active_definition/5 " <>
          "(REQ-077 R10/ENV-03, the reviewless test->production path) after a promotion " <>
          "commits, via Letflow.EventStore.PlatformEvents.append_definition_promoted/2. " <>
          "Bumped from schema_version 1 (REQ-140) to 2 (REQ-077 design §9.5): an ENV-03 " <>
          "promotion genuinely has no review, so `review_id` must admit `null` rather than " <>
          "forcing a synthetic id into the audit log. KNOWN GAP, flagged for REVIEWER: this " <>
          "only widens the schema seeded into TENANTS PROVISIONED FROM THIS POINT ON -- " <>
          "Letflow.EventStore.Registry.get_type/2 picks the highest schema_version already " <>
          "registered in a given tenant's own event_type_registry, and nothing here re-runs " <>
          "replay_migrations/2 against an already-provisioned tenant to seed version 2 there. " <>
          "A tenant provisioned before this change keeps validating DEFINITION_PROMOTED " <>
          "against version 1 (review_id required, non-null) until something backfills it -- " <>
          "R10 against such a tenant fails the event-append step (a committed promotion " <>
          "reported as a 500, the exact Severity-1 shape design §F-5.2 describes) until that " <>
          "backfill runs. Same class of gap as Letflow.Routers.Tenants' OQ-5 (operationally " <>
          "recoverable, not silently patched around here).",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "review_id" => %{"type" => ["string", "null"]},
          "source_tenant_id" => %{"type" => "string"},
          "target_tenant_id" => %{"type" => "string"},
          "source_definition_id" => %{"type" => "string"},
          "target_definition_id" => %{"type" => "string"},
          "process_key" => %{"type" => "string"}
        },
        "required" => [
          "review_id",
          "source_tenant_id",
          "target_tenant_id",
          "source_definition_id",
          "target_definition_id",
          "process_key"
        ]
      }
    },
    %{
      name: "DEFINITION_VERSION_ROLLED_BACK",
      schema_version: 1,
      description:
        "Emitted by Letflow.Definitions.rollback_definition_version/4 (PRM-08) after a " <>
          "version pointer swap commits, via Letflow.EventStore.PlatformEvents.append_definition_version_rolled_back/2.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "process_key" => %{"type" => "string"},
          "from_version" => %{"type" => "string"},
          "to_version" => %{"type" => "string"}
        },
        "required" => ["process_key", "from_version", "to_version"]
      }
    },
    %{
      name: "PROMOTION_ASSERTION_TEARDOWN_FAILED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Definitions.apply_promotion_assertion_rerun/6 (PRM-07) when " <>
          "sandbox release fails during assertion rerun, via " <>
          "Letflow.EventStore.PlatformEvents.append_promotion_assertion_teardown_failed/2.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{"type" => "string"},
          "sandbox_id" => %{"type" => "string"},
          "tenant_id" => %{"type" => "string"},
          "error" => %{"type" => "string"}
        },
        "required" => ["run_id", "sandbox_id", "tenant_id", "error"]
      }
    },
    %{
      name: "TIMER_FIRED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Scheduler.fire_timer/2 (SCH-01/05) when a pending timer's " <>
          "poll-and-fire transaction commits.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "timer_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "timer_type" => %{"type" => "string"},
          "fired_late" => %{"type" => "boolean"},
          "scheduled_fire_at" => %{"type" => "string"},
          "actual_fired_at" => %{"type" => "string"}
        },
        "required" => [
          "timer_id",
          "node_id",
          "timer_type",
          "fired_late",
          "scheduled_fire_at",
          "actual_fired_at"
        ]
      }
    },
    %{
      name: "SERVICE_TASK_COMPLETED",
      schema_version: 1,
      description:
        "Emitted by Letflow.Engine.advance_after_service_task_outcome/4 (REQ-215) when a " <>
          "SERVICE_TASK dispatch's :advance outcome is applied and its VariableMerge.merge/3 " <>
          "output is persisted.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "dispatch_id" => %{"type" => "string"},
          "node_id" => %{"type" => "string"},
          "decoded_body" => %{"type" => "object"}
        },
        "required" => ["dispatch_id", "node_id", "decoded_body"]
      }
    },
    %{
      name: "effect_applied",
      schema_version: 1,
      description:
        "Emitted by Letflow.Ordering.Consumer.try_apply/2 (REQ-199, ORD-01) when a " <>
          "PENDING effect completion is applied in strict sequence order.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "correlation_id" => %{"type" => "string"},
          "sequence_no" => %{"type" => "integer"},
          "completion_id" => %{"type" => "string"}
        },
        "required" => ["correlation_id", "sequence_no", "completion_id"]
      }
    },
    %{
      name: "ordering_lag_threshold_exceeded",
      schema_version: 1,
      description:
        "Emitted by Letflow.Ordering.Metrics.write_to_registry/2 (REQ-199, ORD-04) " <>
          "when a correlation's lag exceeds the configured :letflow, :ordering, :lag_threshold.",
      json_schema: %{
        "type" => "object",
        "properties" => %{
          "correlation_id" => %{"type" => "string"},
          "lag" => %{"type" => "integer"},
          "oldest_pending_age_seconds" => %{"type" => ["integer", "null"]}
        },
        "required" => ["correlation_id", "lag", "oldest_pending_age_seconds"]
      }
    }
  ]

  defp maybe_seed_platform_event_types(false, _tenant_id), do: :ok

  defp maybe_seed_platform_event_types(true, tenant_id) do
    Enum.reduce_while(@platform_event_type_seed_attrs, :ok, fn attrs, :ok ->
      case Registry.register_type(attrs, tenant_id) do
        {:ok, _event_type} -> {:cont, :ok}
        {:error, :duplicate_event_type_version} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:event_type_seed_failed, reason}}}
      end
    end)
  end
end
