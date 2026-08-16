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
  """
  @spec replay_migrations(
          tenant_id :: Ecto.UUID.t(),
          migration_source :: [{version :: pos_integer(), module()}]
        ) ::
          {:ok, applied_versions :: [pos_integer()]}
          | {:error, :tenant_not_provisioned}
          | {:error, {:migration_failed, Exception.t()}}
  def replay_migrations(tenant_id, migration_source \\ tenant_scoped_migrations()) do
    case Repo.get_by(Registration, tenant_id: tenant_id) do
      nil ->
        {:error, :tenant_not_provisioned}

      %Registration{schema_name: schema_name} ->
        try do
          applied_versions =
            Ecto.Migrator.run(Repo, migration_source, :up,
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

  @doc """
  The designated tenant-scoped subset of `priv/repo/migrations/` —
  `replay_migrations/2`'s default `migration_source`. Starts empty: REQ-022
  itself contributes zero entries (its own `CreateTenantSchemas` migration is
  global-only, see the migration's header comment). Every future
  tenant-scoped migration (REQ-023 onward) must append its own
  `{version, module}` tuple here, in addition to following the required guard
  pattern in its own migration file (see this module's design doc §4) — a
  migration file that does one without the other is either inert
  (never selected here) or corrupts `public` on a plain `mix ecto.migrate` run
  (added here without the guard).
  """
  @spec tenant_scoped_migrations() :: [{version :: pos_integer(), module()}]
  def tenant_scoped_migrations do
    []
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
