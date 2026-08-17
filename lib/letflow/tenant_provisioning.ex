defmodule Letflow.TenantProvisioning do
  @moduledoc """
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
  *should* eventually be retrofitted behind `:prefix` (matching R-Co's own
  migration history, where identity tables also moved behind
  schema-per-tenant post-migration-060) is left open for a future requirement
  to decide explicitly — not assumed either way by this module.

  ## Secondary open question (surfaced during design, not in REQ-022's
  original list)

  Should `provision_tenant_schema/1` or some other entry point eventually
  validate that a tenant's `Letflow.Identity.Tenant.status` is `:active` (not
  `:migrating`) before provisioning proceeds? REQ-021's
  `Letflow.Plugs.TenantStatus` already gates *mutating requests* on this
  status for existing tenants; `provision_tenant_schema/1` does not check it —
  left for a future tenant-onboarding-orchestration requirement to decide
  explicitly.
  """

  import Ecto.Query

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
  Idempotently provisions a tenant's physical Postgres schema: derives the
  schema name, serializes concurrent calls for the same tenant via a
  transaction-scoped advisory lock, issues `CREATE SCHEMA IF NOT EXISTS`, and
  records the mapping in `tenant_schemas` — all inside one `Repo.transaction/1`
  so a `tenant_id` that doesn't correspond to an existing tenant rolls back
  the whole operation, including the schema-creation DDL (Postgres DDL is
  transactional).

  Calling this twice for the same `tenant_id` is **not an error** — the
  second call returns `{:ok, %Registration{}}` with the same row the first
  call created, matching R-Co's own `bpm_provision_tenant_schema`'s documented
  idempotency.
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
          migrations = migration_source || tenant_scoped_migrations()

          applied_versions =
            Ecto.Migrator.run(Repo, migrations, :up,
              all: true,
              prefix: schema_name,
              log: false
            )

          mark_migrations_applied(tenant_id)

          {:ok, applied_versions}
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
  # definition-core migrations (lib/letflow/design/req027-definition-core-schema.md §4)
  # and REQ-035's promotion_reviews migration
  # (lib/letflow/design/req035-promotion-reviews-schema.md §4) — ten entries in
  # total. Each of these files carries the §4 guard pattern; registration here is
  # the other mandatory half.
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
     "20260816200001_create_promotion_reviews.exs"}
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
  (`lib/letflow/design/req027-definition-core-schema.md` §4), and REQ-035 the
  `promotion_reviews` migration
  (`lib/letflow/design/req035-promotion-reviews-schema.md` §4) — ten entries in
  total, ordered by version. Every future tenant-scoped migration must append its
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
end
