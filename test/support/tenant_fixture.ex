defmodule Letflow.TenantFixture do
  @moduledoc """
  Shared, instrumented tenant-provisioning fixture for tests that need a real
  Postgres tenant schema (ISS-0109 / GH#358).

  Implements
  `lib/letflow/design/iss0109-provisioning-completeness-and-fixture-instrumentation.md`
  exactly — do not add behavior beyond it without a design update.

  Test-only (`test/support/`, compiled under `elixirc_paths(:test)` per `mix.exs`) —
  **not** part of the shipped application, never referenced from `lib/`, and never
  added to `lib/letflow/application.ex`'s supervision tree (design §4 INV-F-1). Not a
  GenServer, not a supervised process of any kind — a plain module, matching
  `Letflow.TenantSchemaReaper`'s established shape for this directory.

  ## Why this exists

  `TenantProvisioning.provision_tenant_schema/1` and
  `TenantProvisioning.replay_migrations/2` are two separate, composable primitives —
  neither calls the other, and that separation is a decided invariant
  (`lib/letflow/design/req022-tenant-schema-provisioning.md` lines 288-294). The
  obligation to verify that the *combination* produced a complete schema therefore
  belongs to whoever sequences them — which, in every ISS-0109 failure, was a test
  fixture that asserted only `{:ok, _}` from replay and never that the resulting schema
  was complete. That is the real gap, and it is at the fixture layer; there is no
  production defect and this module changes no production code (design §2, INV-F-2).

  Ecto's migrator re-applies nothing for an already-recorded version, so a schema can
  have every `schema_migrations` row present and still be missing the table one of them
  created. That is why `assert_schema_complete!/2` checks the *table* oracle and not
  just replay's return value.

  ## Adoption boundary

  Adopted in exactly two modules in this run
  (`test/letflow/definitions/promotion_test.exs`,
  `test/letflow/definitions/promotion_assertion_rerun_test.exs`, design §5). The other
  39 copy-paste fixture sites are ISS-0112 / GH#366 and are out of scope; the module is
  shaped so they can migrate one file at a time later, with all per-site variation
  carried by `opts`.

  ## Deviation from the design's literal `@type`, recorded rather than silent

  Design §3.2 declares `registration_present?` and `schema_present?` as `boolean()`,
  while design §3.5 — which INV-F-4 explicitly names as **normative** for the failure
  boundary — requires a scalar field whose own query failed to degrade to `nil`, so
  that an *unobserved* value is never reported as an observed absence. The two cannot
  both hold. §3.5's precedence is stated in the design itself, so those two fields are
  typed `boolean() | nil` here: `false` means "observed absent", `nil` means "not
  observed". Reported to ORCH as a MINOR design/implementation discrepancy.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  require Logger

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  @typedoc """
  What `provisioned_tenant!/1` hands back. Map destructuring is partial in Elixir, so
  the `:tenant` key is additive and non-breaking at call sites that bind only a subset.
  """
  @type tenant_fixture :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t(),
          tenant: Letflow.Identity.Tenant.t()
        }

  @type opts :: [
          slug_prefix: String.t(),
          display_name: String.t(),
          oidc_mode: :enabled | :disabled,
          expected_tables: [String.t()] | :default,
          teardown: boolean(),
          template: :clone | :replay
        ]

  @typedoc """
  One-shot snapshot of a tenant's provisioning state at the moment of a failure.

  `registration_present?`/`schema_present?` are `nil` (not `false`) when the query that
  would have observed them failed — see the moduledoc's deviation note and design §3.5.
  """
  @type schema_state :: %{
          schema_name: String.t(),
          tenant_id: Ecto.UUID.t(),
          registration_present?: boolean() | nil,
          provisioned_at: NaiveDateTime.t() | nil,
          migrations_applied_at: NaiveDateTime.t() | nil,
          schema_present?: boolean() | nil,
          tables_present: [String.t()],
          tables_missing: [String.t()],
          applied_versions: [integer()],
          manifest_versions: [integer()],
          versions_missing: [integer()],
          observed_at_utc: NaiveDateTime.t(),
          db_now: NaiveDateTime.t() | nil,
          pg_backend_pid: integer() | nil
        }

  # Fixed and greppable; never assembled at runtime from parts (design §3.6).
  @marker "LETFLOW_TENANT_FIXTURE"

  # Closed phase vocabulary (design §3.6). `teardown` is the ONLY phase the teardown
  # path emits, and the other three are the only phases the failure path emits — so a
  # `phase=teardown` line in a raw log is, by construction, a post-test teardown and
  # never a mid-test drop. That ambiguity is what produced ISS-0109's misdiagnosis.
  @phase_teardown "teardown"
  @phase_provision_failed "provision_failed"
  @phase_replay_failed "replay_failed"
  @phase_incomplete_schema "incomplete_schema"

  # The 22 tables the @tenant_scoped_migration_manifest's `create table(..., prefix:
  # prefix())` migrations produce. `schema_migrations` is deliberately NOT here: it is
  # the migrator's own bookkeeping, and its CONTENTS are captured separately as
  # `applied_versions`. Guarded against rot by this module's own oracle test (design
  # §3.3, INV-F-7) — removing that test invalidates this hard-coded list.
  @expected_tenant_tables [
    "alert_hook_emission_state",
    "alert_trigger_state",
    "api_tokens",
    "artifact_activation_groups",
    "artifact_activation_history",
    "artifact_activations",
    "artifact_versions",
    "audit_entries",
    "correlation_cursors",
    "definition_sequence",
    "dlq_entries",
    "effect_completions",
    "entity_definitions",
    "event_idempotency",
    "event_payload_store",
    "event_type_registry",
    "events",
    "events_archive",
    "group_members",
    "groups",
    "instance_attachments",
    "instance_definition_snapshots",
    "instance_projections",
    "instance_sequence",
    "instance_state_snapshots",
    "lua_script_execution_audit",
    "process_definitions",
    "promotion_assertion_runs",
    "promotion_reviews",
    "repository_artifacts",
    "service_task_dispatches",
    "tasks",
    "tenant_role",
    "timers",
    "tokens",
    "users",
    "variable_schemas",
    "webhook_delivery_attempts",
    "webhook_subscriptions"
  ]

  @doc """
  Provisions a real tenant schema for the calling test and asserts it is complete.

  Reproduces the behaviour of the hand-rolled `provisioned_tenant/0` copies it replaces,
  statement for statement, and then adds the completeness check and the failure capture.
  In order:

  1. `Sandbox.mode(Letflow.Repo, :auto)` — unchanged, and deliberately **not** restored
     to `:manual` (that is ISS-0113, out of scope; INV-F-6).
  2. Inserts a `Letflow.Identity.Tenant` via `Tenant.create_changeset/3` with exactly
     two cast attributes (`slug`, `display_name`) and `opts[:oidc_mode]` (default
     `:disabled`) as the third positional argument. No `:status` is cast, so the row
     gets the schema default `:active` — exactly as both adopted sites do today.
  3. Registers the `on_exit/1` teardown **before** provisioning, so a failure in any
     later step still cleans up.
  4-5. Either `Letflow.Test.TenantTemplate.ensure_template!/0` +
     `clone_tenant_schema!/1` (`opts[:template] == :clone`, the default — ISS-0427), or
     `TenantProvisioning.provision_tenant_schema/1` + `replay_migrations/1`
     (`opts[:template] == :replay`, today's exact original behaviour, kept as an
     explicit escape hatch — design §4.1).
  6. `assert_schema_complete!/2` — unchanged, runs against either path.

  Any failure in 4-6 raises `ExUnit.AssertionError` carrying the full
  `capture_schema_state/1` report, and emits it once more via `Logger.error/1` under the
  marker so it survives assertion-output truncation.

  `opts[:teardown]` defaults to `true`. `false` exists only so the design's fail-first
  tests can construct a broken state without this fixture's own teardown racing their
  assertions; neither adopted module uses it.

  `opts[:template]` defaults to `:clone` (ISS-0427,
  `lib/letflow/design/iss0427-tenant-test-schema-template-clone.md` §4.1, INV-2) —
  cloned from `Letflow.Test.TenantTemplate`'s prepared `"tenant_template"` schema
  instead of replaying all tenant-scoped migrations per call. This changes the
  provisioning *mechanism* for every existing call site by default, not the observable
  schema shape (design §3's parity check exists to guarantee that). Pass
  `template: :replay` for a test with a concrete reason to want a real,
  freshly-migrated-from-scratch schema — in particular any test that also passes a
  non-default `migration_source` downstream, which the clone path cannot serve at all.

  ## `async: true` callers (ISS-0113 / ISS-0423 — no opt-in flag, no `restore_sandbox`)

  This function's own unconditional first line, `Sandbox.mode(Letflow.Repo, :auto)`, is
  sufficient by itself to make a calling test file safe to declare `async: true`,
  *provided* the call site is independently classified safe by
  `lib/letflow/design/iss0113-tenant-fixture-sandbox-restore-opt-in.md` §3's three-
  mechanism procedure (self-checkout, concurrent multi-process DB access, a second
  provisioning call). **No additional flag, checkout, or restore step is needed, and
  none is provided** — a prior design revision (`restore_sandbox: true`, since removed)
  tried to additionally flip the sandbox back to `:manual` with a fresh checkout after
  provisioning, and that made things *worse*, not better: see the design doc's §9 for
  the full trace of why a second mid-test `Sandbox.mode/2` call is actively harmful
  (it discards the connection this function's own provisioning work just established),
  whereas leaving `:auto` mode in effect for the rest of the test (today's original,
  unchanged behavior) is exactly what makes `async: true` work, not what blocks it.
  """
  @spec provisioned_tenant!(opts()) :: tenant_fixture()
  def provisioned_tenant!(opts \\ []) do
    Sandbox.mode(Letflow.Repo, :auto)

    slug_prefix = Keyword.get(opts, :slug_prefix, "tenant-fixture")
    display_name = Keyword.get(opts, :display_name, "Tenant Fixture")
    oidc_mode = Keyword.get(opts, :oidc_mode, :disabled)
    expected = Keyword.get(opts, :expected_tables, :default)
    template = Keyword.get(opts, :template, :clone)
    owner = owning_test()

    tenant =
      %Tenant{}
      |> Tenant.create_changeset(
        %{
          slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
          display_name: display_name
        },
        oidc_mode
      )
      |> Repo.insert!()

    if Keyword.get(opts, :teardown, true) do
      on_exit(fn -> teardown(tenant.id, owner) end)
    end

    schema_name = provision_schema!(template, tenant.id)
    assert_schema_complete!(tenant.id, expected)

    %{tenant_id: tenant.id, schema_name: schema_name, tenant: tenant}
  end

  @doc """
  Captures, in one shot, everything about a tenant's provisioning state that the
  ISS-0109 diagnosis could not answer after the fact.

  **Never raises to its caller** (INV-F-4) — the caller's own failure must remain the
  reported failure, so a capture that blew up must never replace it. Mirrors
  `Letflow.TenantSchemaReaper.sweep_orphans/2`'s same contract.

  Failure boundary, per design §3.5 (normative):

    * Each field is gathered inside its own guard. If gathering *that field* raises,
      that field alone degrades — `nil` for scalars, `[]` for lists — and the call still
      returns `{:ok, schema_state()}` with every other field populated. **A single
      failing query is always a per-field degradation, never a whole-call failure.**
    * Derived fields follow their inputs: if `tables_present` degraded to `[]`, then
      `tables_missing` is `[]` too — *not* "all 19 missing" — because an unobserved set
      must never be reported as an observed absence. Same for
      `applied_versions`/`versions_missing`.
    * `{:error, {:capture_failed, exception}}` is the **outer safety net only**: a
      failure outside the per-field guards, such as a malformed `tenant_id` for which no
      field can be attempted at all. It is not reachable by any single field's query
      failing.
    * A tenant that simply does not exist, or whose schema is absent, is **not** a
      capture failure: it returns `{:ok, state}` with the `present?` flags `false`.

  One shot: no retry, no polling — a retry would observe a *different* state than the
  one that failed (design §9 item 8).
  """
  @spec capture_schema_state(tenant_id :: Ecto.UUID.t()) ::
          {:ok, schema_state()} | {:error, {:capture_failed, Exception.t()}}
  def capture_schema_state(tenant_id) do
    case do_capture(tenant_id, :default) do
      {:ok, state, _observed} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Asserts that the tenant's schema exists and is fully migrated. Returns `:ok`, or
  raises `ExUnit.AssertionError` embedding the full `capture_schema_state/1` report.

  Three checks, all required — neither of the last two subsumes the other:

  1. The schema is present in `information_schema.schemata`.
  2. `tables_missing == []` (`expected -- tables_present`, `tables_present` read from
     `information_schema.tables`). This is what catches a *recorded* migration version
     whose table is nonetheless absent — the state Ecto's migrator will never repair,
     because it re-applies nothing for a version already in `schema_migrations`.
  3. `versions_missing == []` (`tenant_scoped_migrations/0`'s versions against
     `"<schema>".schema_migrations`). This is what catches "replay never fully ran".

  Per INV-F-10, a check whose own observation failed is skipped rather than failed: only
  a *genuinely observed* absence turns a test red. A wholly failed capture logs a
  warning and returns `:ok`.
  """
  @spec assert_schema_complete!(
          tenant_id :: Ecto.UUID.t(),
          expected :: [String.t()] | :default
        ) :: :ok
  def assert_schema_complete!(tenant_id, expected \\ :default) do
    case do_capture(tenant_id, expected) do
      {:ok, state, observed} ->
        case incompleteness_reasons(state, observed) do
          [] -> :ok
          reasons -> raise_with_report(@phase_incomplete_schema, state, reasons)
        end

      {:error, {:capture_failed, exception}} ->
        # INV-F-10: a failing capture must never turn a passing test red.
        Logger.warning(
          "#{@marker} phase=#{@phase_incomplete_schema} capture_failed " <>
            "tenant_id=#{inspect(tenant_id)} reason=#{Exception.message(exception)} " <>
            "(assertion skipped, not failed)"
        )

        :ok
    end
  end

  @doc """
  The completeness oracle: the tables a fully replayed tenant schema contains.

  Hard-coded, and safe to hard-code only because of the oracle-rot test that provisions
  a throwaway tenant and asserts set equality against `information_schema.tables` in
  **both** directions (design §3.3, INV-F-7). Without that test, this list must not be
  hard-coded. Excludes `schema_migrations` — see the module attribute's comment.
  """
  @spec expected_tenant_tables() :: [String.t()]
  def expected_tenant_tables, do: @expected_tenant_tables

  # -----------------------------------------------------------------------------------
  # Provisioning steps -- the two production primitives (:replay path) are sequenced
  # explicitly here, never chained through each other (INV-F-3, req022 lines 288-294).
  # The :clone path (ISS-0427, default) is a separate, test-only fast path -- see
  # Letflow.Test.TenantTemplate, design §4.1.
  # -----------------------------------------------------------------------------------

  defp provision_schema!(:replay, tenant_id) do
    schema_name = provision!(tenant_id)
    replay!(tenant_id)
    schema_name
  end

  defp provision_schema!(:clone, tenant_id) do
    Letflow.Test.TenantTemplate.ensure_template!()

    case Letflow.Test.TenantTemplate.clone_tenant_schema!(tenant_id) do
      {:ok, schema_name} ->
        schema_name

      {:error, reason} ->
        report_and_raise(@phase_replay_failed, tenant_id, [
          "clone_tenant_schema!/1 returned {:error, #{inspect(reason)}}"
        ])
    end
  end

  defp provision!(tenant_id) do
    case TenantProvisioning.provision_tenant_schema(tenant_id) do
      {:ok, %Registration{schema_name: schema_name}} ->
        schema_name

      other ->
        report_and_raise(@phase_provision_failed, tenant_id, [
          "provision_tenant_schema/1 returned #{inspect(other)}"
        ])
    end
  end

  defp replay!(tenant_id) do
    case TenantProvisioning.replay_migrations(tenant_id) do
      {:ok, _applied_versions} ->
        :ok

      other ->
        report_and_raise(@phase_replay_failed, tenant_id, [
          "replay_migrations/1 returned #{inspect(other)}"
        ])
    end
  end

  # -----------------------------------------------------------------------------------
  # Teardown -- today's three statements, unchanged in content and order (INV-F-5),
  # plus exactly ONE log line before the DROP.
  # -----------------------------------------------------------------------------------

  defp teardown(tenant_id, owner) do
    case TenantProvisioning.schema_name_for_tenant(tenant_id) do
      {:ok, schema_name} ->
        log_teardown(tenant_id, schema_name, owner)
        Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))

      {:error, :invalid_tenant_id} ->
        :ok
    end

    Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant_id))
    Repo.delete_all(from(t in Tenant, where: t.id == ^tenant_id))
  end

  # `schema_present_before_drop` distinguishes "we tore down a schema that was still
  # there" (normal) from "we tore down a schema that had already vanished" -- the
  # ISS-0109 shape, which `DROP SCHEMA IF EXISTS ... CASCADE` silently succeeds against,
  # telling nobody.
  #
  # OQ-4, settled by measurement rather than assumption: this repo has no `config
  # :logger` in any config file, so under MIX_ENV=test `Logger.level()` is `:debug`,
  # `:logger`'s primary level is `:debug`, and the default handler's level is `:all`.
  # `[debug]` Ecto SQL lines are visibly emitted by `mix test` today. `:info` is
  # therefore NOT filtered, and this line stays at `:info` as the design specifies --
  # no raise to `:warning`, and no logger reconfiguration (which would have changed
  # output for every other test).
  defp log_teardown(tenant_id, schema_name, {test_module, test_name}) do
    present = guarded(fn -> schema_present?(schema_name) end, nil)

    Logger.info(
      "#{@marker} phase=#{@phase_teardown} schema=#{schema_name} tenant_id=#{tenant_id} " <>
        "schema_present_before_drop=#{inspect(present)} " <>
        "test_module=#{test_module} test_name=#{inspect(test_name)}"
    )
  rescue
    # INV-F-10: a failing log call must never turn a passing test red.
    _exception -> :ok
  end

  # -----------------------------------------------------------------------------------
  # Failure reporting -- emitted twice, deliberately (design §3.5): into the raised
  # AssertionError (so CI's preserved test output has it) and via Logger.error under the
  # marker (so it is greppable in a raw run log even when assertion output is truncated).
  # -----------------------------------------------------------------------------------

  defp report_and_raise(phase, tenant_id, reasons) do
    case do_capture(tenant_id, :default) do
      {:ok, state, _observed} ->
        raise_with_report(phase, state, reasons)

      {:error, {:capture_failed, exception}} ->
        message =
          "#{@marker} phase=#{phase} tenant_id=#{inspect(tenant_id)}\n" <>
            Enum.map_join(reasons, "\n", &("  - " <> &1)) <>
            "\n  - capture_schema_state/1 returned {:error, {:capture_failed, " <>
            "#{Exception.message(exception)}}}"

        Logger.error(message)
        raise ExUnit.AssertionError, message: message
    end
  end

  defp raise_with_report(phase, state, reasons) do
    message =
      "#{@marker} phase=#{phase} schema=#{state.schema_name} tenant_id=#{state.tenant_id}\n" <>
        Enum.map_join(reasons, "\n", &("  - " <> &1)) <>
        "\n\n" <> format_report(state)

    Logger.error(message)
    raise ExUnit.AssertionError, message: message
  end

  defp incompleteness_reasons(state, observed) do
    schema_reason =
      if observed.schema and state.schema_present? == false do
        ["schema #{state.schema_name} is absent from information_schema.schemata"]
      else
        []
      end

    tables_reason =
      if observed.tables and state.tables_missing != [] do
        ["tables_missing=#{inspect(state.tables_missing)}"]
      else
        []
      end

    versions_reason =
      if observed.versions and state.versions_missing != [] do
        ["versions_missing=#{inspect(state.versions_missing)}"]
      else
        []
      end

    schema_reason ++ tables_reason ++ versions_reason
  end

  defp format_report(state) do
    """
    schema_state:
      schema_name             = #{state.schema_name}
      tenant_id               = #{state.tenant_id}
      registration_present?   = #{inspect(state.registration_present?)}
      provisioned_at          = #{inspect(state.provisioned_at)}
      migrations_applied_at   = #{inspect(state.migrations_applied_at)}
      schema_present?         = #{inspect(state.schema_present?)}
      tables_present          = #{inspect(state.tables_present)}
      tables_missing          = #{inspect(state.tables_missing)}
      applied_versions        = #{inspect(state.applied_versions)}
      manifest_versions       = #{inspect(state.manifest_versions)}
      versions_missing        = #{inspect(state.versions_missing)}
      observed_at_utc         = #{inspect(state.observed_at_utc)}
      db_now                  = #{inspect(state.db_now)}
      pg_backend_pid          = #{inspect(state.pg_backend_pid)}
    """
  end

  # -----------------------------------------------------------------------------------
  # Capture -- one shot, per-field guards, no retry, no polling.
  #
  # Returns the public `schema_state()` PLUS a private per-field observation map, so
  # assert_schema_complete!/2 can tell "observed absent" from "never observed" without
  # widening the public shape. Every query below is either parameterized and scoped to
  # this one tenant/schema, or a catalog read filtered by `table_schema = $1` (INV-F-8);
  # the only identifier interpolation is `"<schema>".schema_migrations`, and <schema> is
  # always schema_name_for_tenant/1's output, never caller-supplied (INV-F-9).
  # -----------------------------------------------------------------------------------

  defp do_capture(tenant_id, expected) do
    schema_name =
      case TenantProvisioning.schema_name_for_tenant(tenant_id) do
        {:ok, name} ->
          name

        {:error, reason} ->
          # Outside the per-field guards: with no schema name, no field can be attempted.
          raise ArgumentError,
                "cannot derive a schema name for tenant_id=#{inspect(tenant_id)}: " <>
                  inspect(reason)
      end

    registration =
      guarded(fn -> {:observed, Repo.get_by(Registration, tenant_id: tenant_id)} end, nil)

    schema_present = guarded(fn -> schema_present?(schema_name) end, nil)
    tables = guarded(fn -> {:observed, tables_in(schema_name)} end, nil)
    applied = guarded(fn -> {:observed, applied_versions_in(schema_name)} end, nil)
    manifest = guarded(fn -> {:observed, manifest_versions()} end, nil)

    expected_tables =
      case expected do
        :default -> @expected_tenant_tables
        list when is_list(list) -> list
      end

    tables_present = observed_or(tables, [])
    applied_versions = observed_or(applied, [])
    manifest_versions = observed_or(manifest, [])

    versions_observed? = observed?(applied) and observed?(manifest)

    state = %{
      schema_name: schema_name,
      tenant_id: tenant_id,
      registration_present?: registration_present(registration),
      provisioned_at: registration_field(registration, :provisioned_at),
      migrations_applied_at: registration_field(registration, :migrations_applied_at),
      schema_present?: schema_present,
      tables_present: tables_present,
      # Derived fields follow their inputs: an UNOBSERVED set is never reported as an
      # observed absence, so a degraded tables_present yields [] here, not "all missing".
      tables_missing: if(observed?(tables), do: expected_tables -- tables_present, else: []),
      applied_versions: applied_versions,
      manifest_versions: manifest_versions,
      versions_missing:
        if(versions_observed?, do: manifest_versions -- applied_versions, else: []),
      observed_at_utc: NaiveDateTime.utc_now(),
      db_now: guarded(fn -> db_now() end, nil),
      pg_backend_pid: guarded(fn -> pg_backend_pid() end, nil)
    }

    observed = %{
      registration: observed?(registration),
      schema: schema_present != nil,
      tables: observed?(tables),
      versions: versions_observed?
    }

    {:ok, state, observed}
  rescue
    exception -> {:error, {:capture_failed, exception}}
  end

  # Per-field guard: `fun` either returns its value, or raises and that ONE field
  # degrades to `degraded` while every other field is still gathered.
  defp guarded(fun, degraded) do
    fun.()
  rescue
    _exception -> degraded
  end

  defp observed?({:observed, _value}), do: true
  defp observed?(_other), do: false

  defp observed_or({:observed, value}, _degraded), do: value
  defp observed_or(_other, degraded), do: degraded

  defp registration_present({:observed, %Registration{}}), do: true
  defp registration_present({:observed, nil}), do: false
  defp registration_present(_degraded), do: nil

  defp registration_field({:observed, %Registration{} = registration}, field),
    do: Map.fetch!(registration, field)

  defp registration_field(_other, _field), do: nil

  defp schema_present?(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = $1",
        [schema_name]
      )

    rows != []
  end

  defp tables_in(schema_name) do
    %{rows: rows} =
      Repo.query!(
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
        [schema_name]
      )

    rows
    |> Enum.map(fn [table_name] -> table_name end)
    |> Enum.reject(&(&1 == "schema_migrations"))
    |> Enum.sort()
  end

  defp applied_versions_in(schema_name) do
    %{rows: rows} = Repo.query!(~s(SELECT version FROM "#{schema_name}".schema_migrations))

    rows |> Enum.map(fn [version] -> version end) |> Enum.sort()
  end

  defp manifest_versions do
    TenantProvisioning.tenant_scoped_migrations()
    |> Enum.map(fn {version, _module} -> version end)
    |> Enum.sort()
  end

  defp db_now do
    %{rows: [[db_now]]} = Repo.query!("SELECT now() at time zone 'utc'")
    db_now
  end

  defp pg_backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # ExUnit stores the currently-running test under the `ExUnit.Runner` key in the
  # dictionary of the process that RUNS the module -- not of the spawned test process
  # itself -- so it is reached by walking `$ancestors`, the same shape ExUnit's own
  # `ExUnit.Runner.safe_pdict_current/1` uses. That is private API, so it is read
  # defensively and degrades to "unknown" rather than ever failing anything (INV-F-10).
  # Read at fixture-construction time and closed over, because `on_exit/1` callbacks run
  # in a process that is not a descendant of the runner at all.
  defp owning_test do
    (parent_chain(self(), 4) ++ List.wrap(Process.get(:"$ancestors")))
    |> Enum.find_value({"unknown", :unknown}, &current_test_of/1)
  rescue
    _exception -> {"unknown", :unknown}
  end

  # ExUnit spawns the test process with a bare `spawn_monitor`, so it carries no
  # `$ancestors`; the runner-held key is reached through the OTP-25+ `:parent` link.
  defp parent_chain(_pid, 0), do: []

  defp parent_chain(pid, depth) when is_pid(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> [pid | parent_chain(parent, depth - 1)]
      _other -> [pid]
    end
  end

  defp parent_chain(_not_a_pid, _depth), do: []

  defp current_test_of(pid) when is_pid(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {ExUnit.Runner, current} <- List.keyfind(dictionary, ExUnit.Runner, 0) do
      case current do
        %{__struct__: ExUnit.Test, module: module, name: name} -> {inspect(module), name}
        %{__struct__: ExUnit.TestModule, name: module} -> {inspect(module), :"(module-level)"}
        _other -> nil
      end
    else
      _other -> nil
    end
  end

  defp current_test_of(_not_a_pid), do: nil
end
