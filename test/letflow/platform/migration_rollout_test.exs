defmodule Letflow.Platform.MigrationRolloutTest do
  @moduledoc """
  Integration tests for REQ-374's platform-wide tenant-migration fanout
  runner. See `test/specs/REQ-374.md` for the full AC-to-test mapping, and
  `lib/letflow/design/req374-tenant-migration-fanout-runner.md` §8 for the
  design's own test-coverage plan each `describe` block below implements.

  Uses `Letflow.DataCase` (real Postgres, per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1) and `Letflow.TenantFixture.provisioned_tenant!/1` for real
  provisioned tenant schemas -- no mocks anywhere in this file. `async: false`,
  same reasoning as `test/letflow/tenant_provisioning/column_promotion_test.exs`
  and every other test in this suite that provisions real tenant schemas and
  runs real DDL against them.

  `Letflow.Platform.MigrationRollout` proves its fanout/resume/idempotent-rerun
  mechanism against exactly one concrete change (design doc §2): promoting one
  new column onto the `"invoice"` entity type. Every tenant fixture below
  therefore also creates an active `"invoice"` entity definition before any
  rollout call -- `Letflow.TenantProvisioning.run_column_promotion/1`'s
  `ensure_entity_table/2` step needs one to build the per-entity-type table
  from (`create_and_populate_entity_table/3` calls
  `Definitions.get_active_definition_by_name/2`), exactly like
  `column_promotion_test.exs`'s own fixtures.

  ## Unique `(entity_type, attribute)` per test -- why

  `platform_migration_rollouts` carries a DB-level unique index on
  `(entity_type, attribute)` (design doc §3.1 -- this is the natural key
  EO-005 depends on). `TenantFixture.provisioned_tenant!/1` forces
  `Sandbox.mode(Letflow.Repo, :auto)` (real commits, not per-test rollback),
  so two tests both calling `start_rollout("invoice", "amount", ...)` would
  resolve to the SAME rollout row and corrupt each other's company/outcome
  counts. Every test below therefore mints its own attribute name via
  `unique_attribute/1` and cleans its own rollout/outcome rows up in
  `on_exit/1`, registered AFTER every company fixture in that test so it
  runs BEFORE any company's own teardown (`on_exit/1` callbacks run
  most-recently-registered-first) -- `platform_migration_rollout_outcomes.tenant_id`
  has a real FK to `tenants` (`on_delete: :nothing`), so the outcome rows
  must be deleted before `TenantFixture`'s own teardown deletes the tenant
  row, or that teardown raises a foreign-key violation.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.EventTypes
  alias Letflow.Platform.MigrationRollout
  alias Letflow.Platform.MigrationRollout.Outcome
  alias Letflow.Platform.MigrationRollout.Rollout
  alias Letflow.Repo
  alias Letflow.TenantFixture
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion

  # ---------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------

  # Not Ecto.UUID.generate/0 -- the hyphens in a UUID are not valid Postgres
  # identifier characters, and this value is used verbatim as a physical
  # column name / ColumnPromotion.attribute. System.unique_integer/1 is
  # unique within this BEAM run, which is sufficient here because every test
  # ALSO deletes its own rollout/outcome rows in on_exit/1 (see moduledoc) --
  # unlike TenantFixture's own slug fixtures, this value has no reason to
  # need cross-run uniqueness too.
  defp unique_attribute(base), do: "#{base}_#{System.unique_integer([:positive])}"

  defp definition_fields(entity_name, overrides) do
    Map.merge(
      %{
        name: entity_name,
        display_name: String.capitalize(entity_name),
        fields: [
          %{name: "amount", type: :string, queried: true},
          %{name: "notes", type: :string}
        ]
      },
      Map.new(overrides)
    )
  end

  # No default for `overrides` -- its only call site (active_company!/3
  # below) always passes it explicitly, so a default here would be dead
  # code (docs/anti-patterns.md's ISS-0069 entry).
  defp create_active_definition!(schema, entity_name, overrides) do
    definition = definition_fields(entity_name, overrides)

    assert {:ok, entity_definition} =
             Definitions.create_definition(
               %{definition: definition, created_by: Ecto.UUID.generate()},
               schema
             )

    assert {:ok, activated} =
             Definitions.activate_definition(
               entity_definition.name,
               Ecto.UUID.generate(),
               "go-live",
               schema
             )

    activated
  end

  # A real, active, provisioned company -- registered via
  # TenantFixture.provisioned_tenant!/1 (real Postgres schema, real
  # Registration row) plus an active "invoice" definition so
  # run_column_promotion/1's table-creation step has something to build
  # from.
  defp active_company!(slug_prefix, entity_name \\ "invoice", definition_overrides \\ %{}) do
    fixture = TenantFixture.provisioned_tenant!(slug_prefix: slug_prefix)
    assert {:ok, _seed_result} = EventTypes.seed!(fixture.schema_name)
    create_active_definition!(fixture.schema_name, entity_name, definition_overrides)
    fixture
  end

  # Registered AFTER every company fixture in the calling test -- runs
  # before those companies' own TenantFixture teardown (LIFO), so the
  # tenant FK is still satisfiable when these rows are deleted. Deletes by
  # (entity_type, attribute), not by id, so it is self-sufficient even for
  # a test that never captures the rollout's id (e.g. a start_rollout/3
  # call that errors before returning one).
  #
  # Also deletes the underlying `entity_column_promotions` rows this test's
  # own `register_column_promotion/4` calls created (directly, or via
  # `MigrationRollout.start_rollout/3`) -- `TenantFixture.provisioned_tenant!/1`'s
  # own teardown has no idea `ColumnPromotion` rows exist (same reason
  # `column_promotion_test.exs`'s own fixture deletes them by hand), and
  # `entity_column_promotions.tenant_id` has a real FK to `tenants` too.
  # Order matters: outcomes first (they FK to column_promotion_id), then the
  # promotions, then the rollout row itself.
  defp cleanup_rollout_on_exit!(entity_type, attribute) do
    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

      case Repo.get_by(Rollout, entity_type: entity_type, attribute: attribute) do
        %Rollout{id: rollout_id} ->
          Repo.delete_all(from(o in Outcome, where: o.rollout_id == ^rollout_id))
          Repo.delete_all(from(r in Rollout, where: r.id == ^rollout_id))

        nil ->
          :ok
      end

      Repo.delete_all(
        from(cp in ColumnPromotion, where: cp.entity_type == ^entity_type and cp.attribute == ^attribute)
      )
    end)
  end

  defp fetch_information_schema_column(schema, table_name, column_name) do
    query = """
    SELECT data_type FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
    """

    case Repo.query!(query, [schema, table_name, column_name]) do
      %Postgrex.Result{rows: []} -> nil
      %Postgrex.Result{rows: [[data_type]]} -> data_type
    end
  end

  # Pre-poisons a company's schema: creates the entity table by hand, with a
  # same-named `column_name` column of a CONFLICTING type (bigint, not the
  # text this suite's rollouts promote) -- the exact technique
  # `column_promotion_test.exs`'s own AC2 describe block uses (design doc
  # §2's own cited rationale for why this needs no mock:
  # check_additive_only/3 rejects it via a real information_schema read,
  # not a test double).
  defp poison_company_schema!(schema, table_name, column_name) do
    Repo.query!("""
    CREATE TABLE "#{schema}"."#{table_name}" (
      id uuid PRIMARY KEY,
      record_id uuid NOT NULL UNIQUE,
      field_values jsonb NOT NULL DEFAULT '{}'::jsonb,
      deleted boolean NOT NULL DEFAULT false,
      entity_def_version bytea,
      last_event_global_seq bigint NOT NULL,
      inserted_at timestamp(6) without time zone NOT NULL,
      updated_at timestamp(6) without time zone NOT NULL,
      "#{column_name}" bigint
    )
    """)
  end

  defp cure_company_schema!(schema, table_name, column_name) do
    Repo.query!(~s(ALTER TABLE "#{schema}"."#{table_name}" DROP COLUMN "#{column_name}"))
  end

  defp create_record!(schema, entity_type, field_values) do
    attrs = %{
      entity_type: entity_type,
      field_values: field_values,
      actor_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate()
    }

    Letflow.Entities.Records.create_record(attrs, schema)
  end

  defp outcome_for(result, tenant_id) do
    Enum.find(result.outcomes, &(&1.tenant_id == tenant_id))
  end

  defp column_spec, do: %{pg_type: "text", nullable: true}

  # ---------------------------------------------------------------------
  # EO-001 / EO-002 -- failure isolation, plus the queryable-outcome AC.
  # ---------------------------------------------------------------------

  describe "EO-001/EO-002 -- one company's real DDL failure isolates from the rest" do
    test "every other active company holds the change; the poisoned company is recorded FAILED with a plain reason (EO-001)" do
      attribute = unique_attribute("amount")

      good_a = active_company!("req374-eo001-good-a")
      good_b = active_company!("req374-eo001-good-b")
      poisoned = active_company!("req374-eo001-poisoned")
      cleanup_rollout_on_exit!("invoice", attribute)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      poison_company_schema!(poisoned.schema_name, table_name, attribute)

      assert {:ok, result} = MigrationRollout.start_rollout("invoice", attribute, column_spec())

      good_a_outcome = outcome_for(result, good_a.tenant_id)
      good_b_outcome = outcome_for(result, good_b.tenant_id)
      poisoned_outcome = outcome_for(result, poisoned.tenant_id)

      assert good_a_outcome.status == "succeeded"
      assert good_a_outcome.reason == nil
      assert good_b_outcome.status == "succeeded"
      assert good_b_outcome.reason == nil

      assert poisoned_outcome.status == "failed"
      assert is_binary(poisoned_outcome.reason)
      assert poisoned_outcome.reason =~ "conflicting type"
      assert poisoned_outcome.reason =~ "existing: bigint"
      assert poisoned_outcome.reason =~ "requested: text"

      # One outcome is still outstanding -- the rollout stays resumable
      # (design §4.6's own "leaves it resumable" contract), never marked
      # complete just because most companies finished.
      assert result.rollout.completed_at == nil
      assert result.rollout.status == "running"
    end

    test "the poisoned company's schema holds none of the change, and a real write against it succeeds immediately afterward (EO-002)" do
      attribute = unique_attribute("amount")

      good_a = active_company!("req374-eo002-good-a")
      poisoned = active_company!("req374-eo002-poisoned")
      cleanup_rollout_on_exit!("invoice", attribute)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      poison_company_schema!(poisoned.schema_name, table_name, attribute)

      assert {:ok, result} = MigrationRollout.start_rollout("invoice", attribute, column_spec())
      assert outcome_for(result, poisoned.tenant_id).status == "failed"

      # No partial DDL/data change: the poisoned schema's column is still
      # its pre-attempt bigint, not text -- queried directly against
      # Postgres, not inferred from the outcome row.
      assert fetch_information_schema_column(poisoned.schema_name, table_name, attribute) ==
               "bigint"

      # The good company genuinely got the change (contrast case).
      assert fetch_information_schema_column(good_a.schema_name, table_name, attribute) == "text"

      # A real write against the poisoned company's own schema succeeds
      # immediately afterward -- proof the schema was left fully usable,
      # not partially altered (design §5.2's own literal test mechanism).
      assert {:ok, %{record: _record}} =
               create_record!(poisoned.schema_name, "invoice", %{
                 "amount" => "1",
                 "notes" => "after-fail"
               })
    end
  end

  # ---------------------------------------------------------------------
  # Queryable outcome record AC (supports EO-003's screen)
  # ---------------------------------------------------------------------

  describe "queryable outcome record -- completion timestamp + reason, per rollout_id" do
    test "rollout_status/1 returns every outcome with a completion timestamp, a reason for the failed one, and 404s for an unknown id" do
      attribute = unique_attribute("amount")

      good = active_company!("req374-ac3-good")
      poisoned = active_company!("req374-ac3-poisoned")
      cleanup_rollout_on_exit!("invoice", attribute)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      poison_company_schema!(poisoned.schema_name, table_name, attribute)

      assert {:ok, %{rollout: rollout}} =
               MigrationRollout.start_rollout("invoice", attribute, column_spec())

      assert {:ok, result} = MigrationRollout.rollout_status(rollout.id)
      # >= 2, not == 2: active_company_tenant_ids/0 scopes over EVERY active,
      # provisioned tenant in the shared test database, so a concurrently
      # leaked tenant from elsewhere in the suite could legitimately also
      # land in this rollout's outcome set (same ISS-0716 containment-not-
      # exact-equality reasoning column_promotion_test.exs's own AC1 test
      # already documents for this exact hazard).
      assert length(result.outcomes) >= 2

      for outcome <- result.outcomes do
        assert %NaiveDateTime{} = outcome.completed_at
      end

      good_outcome = outcome_for(result, good.tenant_id)
      poisoned_outcome = outcome_for(result, poisoned.tenant_id)

      assert good_outcome.status == "succeeded"
      assert good_outcome.reason == nil

      assert poisoned_outcome.status == "failed"
      assert is_binary(poisoned_outcome.reason)
      assert poisoned_outcome.reason != ""

      assert {:error, :rollout_not_found} = MigrationRollout.rollout_status(Ecto.UUID.generate())
    end
  end

  # ---------------------------------------------------------------------
  # EO-004 -- resume applies only to outstanding companies; already-
  # succeeded companies are never re-touched.
  # ---------------------------------------------------------------------

  describe "EO-004 -- resume_rollout/1 applies only to not-yet-SUCCEEDED companies" do
    test "already-succeeded companies show no second write; the corrected company's outcome flips to succeeded" do
      attribute = unique_attribute("amount")

      good = active_company!("req374-eo004-good")
      poisoned = active_company!("req374-eo004-poisoned")
      cleanup_rollout_on_exit!("invoice", attribute)

      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type("invoice")
      poison_company_schema!(poisoned.schema_name, table_name, attribute)

      assert {:ok, first_result} =
               MigrationRollout.start_rollout("invoice", attribute, column_spec())

      good_outcome_before = outcome_for(first_result, good.tenant_id)
      poisoned_outcome_before = outcome_for(first_result, poisoned.tenant_id)
      assert good_outcome_before.status == "succeeded"
      assert poisoned_outcome_before.status == "failed"

      # "Correct" the poisoned company so the real DDL now succeeds.
      cure_company_schema!(poisoned.schema_name, table_name, attribute)

      assert {:ok, resumed_result} = MigrationRollout.resume_rollout(first_result.rollout.id)

      good_outcome_after = outcome_for(resumed_result, good.tenant_id)
      poisoned_outcome_after = outcome_for(resumed_result, poisoned.tenant_id)

      # The corrected company is now succeeded -- a real re-drive happened
      # (status flipped failed -> succeeded, reason cleared). Not asserted
      # as completed_at != completed_at-before: naive_now/0 truncates to
      # the second (design §3.2), so a fast resume in the same wall-clock
      # second can legitimately produce an identical value -- asserting
      # inequality here would make the test depend on wall-clock timing,
      # which this suite avoids by design (forbidden: "don't depend on
      # wall-clock time or unseeded randomness"). The status/reason
      # transition is the real, non-timing-dependent proof a write occurred.
      assert poisoned_outcome_after.status == "succeeded"
      assert poisoned_outcome_after.reason == nil
      assert %NaiveDateTime{} = poisoned_outcome_after.completed_at

      # The already-succeeded company is byte-identical to its pre-resume
      # value -- status, completed_at, AND reason -- not just "still
      # succeeded" (design §8's own explicit "direct equality on the loaded
      # struct" instruction).
      assert good_outcome_after.status == good_outcome_before.status
      assert good_outcome_after.completed_at == good_outcome_before.completed_at
      assert good_outcome_after.reason == good_outcome_before.reason

      # Loaded directly from Postgres too, not just the returned summary
      # map.
      good_row_after =
        Repo.get_by!(Outcome, rollout_id: first_result.rollout.id, tenant_id: good.tenant_id)

      assert good_row_after.completed_at == good_outcome_before.completed_at

      # The rollout itself is now complete (every company succeeded).
      assert resumed_result.rollout.completed_at != nil
      assert resumed_result.rollout.status == "completed"
    end
  end

  # ---------------------------------------------------------------------
  # EO-005 -- idempotent re-run: zero writes, every company already-current.
  # ---------------------------------------------------------------------

  describe "EO-005 -- starting the identical rollout again once every company already holds the change" do
    test "performs zero writes and reports every company as already-current" do
      attribute = unique_attribute("amount")

      good_a = active_company!("req374-eo005-good-a")
      good_b = active_company!("req374-eo005-good-b")
      cleanup_rollout_on_exit!("invoice", attribute)

      assert {:ok, first_result} =
               MigrationRollout.start_rollout("invoice", attribute, column_spec())

      assert Enum.all?(first_result.outcomes, &(&1.status == "succeeded"))

      rollout_count_before = Repo.aggregate(Rollout, :count, :id)
      outcome_count_before = Repo.aggregate(Outcome, :count, :id)

      completed_at_a_before = outcome_for(first_result, good_a.tenant_id).completed_at
      completed_at_b_before = outcome_for(first_result, good_b.tenant_id).completed_at
      rollout_completed_at_before = first_result.rollout.completed_at

      assert {:ok, second_result} =
               MigrationRollout.start_rollout("invoice", attribute, column_spec())

      # Every entry reports already_current: true.
      assert Enum.all?(second_result.outcomes, & &1.already_current)

      # Every outcome's completed_at is unchanged from before this call.
      assert outcome_for(second_result, good_a.tenant_id).completed_at == completed_at_a_before
      assert outcome_for(second_result, good_b.tenant_id).completed_at == completed_at_b_before

      # The rollout row itself is unchanged too.
      assert second_result.rollout.completed_at == rollout_completed_at_before

      # The literal "zero writes" claim -- no row in either table changed,
      # not merely "results look the same" (design §8's own instruction).
      assert Repo.aggregate(Rollout, :count, :id) == rollout_count_before
      assert Repo.aggregate(Outcome, :count, :id) == outcome_count_before
    end
  end

  # ---------------------------------------------------------------------
  # Registration-time conflict (REVIEWER finding, WF02 rework) -- a company
  # that already holds an entity_column_promotions row for the target
  # (entity_type, attribute) BEFORE the rollout starts must get a "failed"
  # outcome with a real reason, never a silently-missing outcome row.
  # ---------------------------------------------------------------------

  describe "registration-time conflict -- a pre-existing entity_column_promotions row for the target pair" do
    test "the company is recorded failed with a plain reason, not silently absent from rollout_status/1" do
      entity_type = "widget_regconflict_#{System.unique_integer([:positive])}"
      attribute = "sku"

      conflicted = active_company!("req374-regconflict-a", entity_type)
      other_good = active_company!("req374-regconflict-b", entity_type)
      cleanup_rollout_on_exit!(entity_type, attribute)

      # A registration that has nothing to do with this rollout -- modeling
      # "a tenant already holds a matching row from an earlier, non-rollout
      # registration" (the module's own comment on this exact scenario).
      pre_existing_attrs = %{
        tenant_id: conflicted.tenant_id,
        entity_type: entity_type,
        attribute: attribute,
        column_name: attribute,
        pg_type: "text",
        status: "pending",
        query_eligible: false
      }

      assert {:ok, _pre_existing} =
               Repo.insert(ColumnPromotion.changeset(%ColumnPromotion{}, pre_existing_attrs))

      # Also poison the conflicted company's own schema (EO-001's own
      # technique) so the pre-existing "pending" promotion's DDL genuinely
      # fails too, not just the registration insert. Without this,
      # apply_outstanding/1's own `status != "succeeded"` query (design
      # §4.4) picks the freshly-"failed" registration-conflict outcome back
      # up in the SAME start_rollout/3 call (it runs register_and_seed_outcome/5
      # for every tenant, THEN apply_outstanding/1) and retries it via the
      # pre-existing, otherwise-healthy "pending" ColumnPromotion row --
      # which would succeed and mask the very outcome-row-creation bug this
      # test exists to guard. Poisoning the schema keeps the retry failing
      # too, so the FINAL state is still "failed" -- the requirement's own
      # literal wording -- while the first assertion below independently
      # proves the outcome row was never silently absent even for the one
      # instant between registration and this retry.
      assert {:ok, table_name} = TenantProvisioning.table_name_for_entity_type(entity_type)
      poison_company_schema!(conflicted.schema_name, table_name, attribute)

      assert {:ok, result} = MigrationRollout.start_rollout(entity_type, attribute, column_spec())

      # The company is NOT silently absent -- it has a real outcome row,
      # recorded "failed" with a real, human-readable reason (this is the
      # bug REVIEWER caught: previously this `{:error, _}` fell through a
      # `with`'s missing `else` silently and the company had NO outcome row
      # at all).
      conflicted_outcome = outcome_for(result, conflicted.tenant_id)
      assert conflicted_outcome != nil
      assert conflicted_outcome.status == "failed"
      assert is_binary(conflicted_outcome.reason)
      assert conflicted_outcome.reason != ""
      refute conflicted_outcome.reason =~ "#Ecto.Changeset"

      # Confirmed again via the independent read path (rollout_status/1),
      # not merely the same call's own return value.
      assert {:ok, status_result} = MigrationRollout.rollout_status(result.rollout.id)
      assert outcome_for(status_result, conflicted.tenant_id).status == "failed"

      # The unrelated, unconflicted company in the same rollout still
      # succeeds normally -- the conflict is isolated to the one company.
      assert outcome_for(result, other_good.tenant_id).status == "succeeded"
    end
  end

  # ---------------------------------------------------------------------
  # Crash-recovery catch-up branch (design §4.4/§5.2) -- a ColumnPromotion
  # already past DDL success (simulating the crash window between the DDL
  # commit and the outcome-row write) is caught up by resume_rollout/1
  # WITHOUT re-entering the advisory-locked DDL path.
  # ---------------------------------------------------------------------

  describe "crash-recovery catch-up -- apply_outstanding/1's terminal-success branch" do
    test "resume_rollout/1 catches an outcome row up to a ColumnPromotion that already succeeded, without re-issuing DDL" do
      attribute = unique_attribute("amount")

      company = active_company!("req374-crash-recovery")
      cleanup_rollout_on_exit!("invoice", attribute)

      # Register and run the DDL directly against TenantProvisioning,
      # bypassing MigrationRollout entirely -- this is the "DDL already
      # committed" half of the crash window.
      assert {:ok, [promotion]} =
               TenantProvisioning.register_column_promotion(
                 "invoice",
                 attribute,
                 column_spec(),
                 [company.tenant_id]
               )

      assert {:ok, %ColumnPromotion{status: "ddl_applied"}} =
               TenantProvisioning.run_column_promotion(promotion.id)

      # Now construct the rollout bookkeeping by hand, with the outcome row
      # still "pending" -- this is the "outcome-row write never happened"
      # half of the crash window (design §5.2: step 1 and step 2 of
      # apply_outstanding/1 are deliberately separate transactions, so a
      # crash between them leaves exactly this state).
      assert {:ok, rollout} =
               Repo.insert(
                 Rollout.changeset(%Rollout{}, %{
                   entity_type: "invoice",
                   attribute: attribute,
                   column_spec: column_spec(),
                   status: "running",
                   started_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
                 })
               )

      assert {:ok, outcome} =
               Repo.insert(
                 Outcome.changeset(%Outcome{}, %{
                   rollout_id: rollout.id,
                   tenant_id: company.tenant_id,
                   column_promotion_id: promotion.id,
                   status: "pending"
                 })
               )

      assert outcome.completed_at == nil

      # Proof the catch-up branch never re-enters the DDL path: attach to
      # the same query telemetry column_promotion_test.exs's own backfill
      # test uses, and assert no ALTER TABLE statement is issued during
      # this resume_rollout/1 call.
      test_pid = self()
      handler_id = "req374-crash-recovery-no-ddl-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if String.starts_with?(query, "ALTER TABLE") do
            send(test_pid, {:unexpected_ddl, query})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, result} = MigrationRollout.resume_rollout(rollout.id)

      refute_received {:unexpected_ddl, _query}
      :telemetry.detach(handler_id)

      caught_up_outcome = outcome_for(result, company.tenant_id)
      assert caught_up_outcome.status == "succeeded"
      assert caught_up_outcome.reason == nil
      assert %NaiveDateTime{} = caught_up_outcome.completed_at

      assert result.rollout.completed_at != nil
      assert result.rollout.status == "completed"
    end
  end

  # ---------------------------------------------------------------------
  # Sanity: active_company_tenant_ids/0 excludes non-active tenants (design
  # §4.5's own deliberate exclusion of :migrating/:inactive).
  # ---------------------------------------------------------------------

  describe "scope resolution excludes non-active tenants" do
    test "an :inactive tenant is not targeted by start_rollout/3" do
      attribute = unique_attribute("amount")

      active = active_company!("req374-scope-active")
      inactive = active_company!("req374-scope-inactive")
      cleanup_rollout_on_exit!("invoice", attribute)

      assert {:ok, _} = Repo.update(Ecto.Changeset.change(inactive.tenant, status: :inactive))

      assert {:ok, result} = MigrationRollout.start_rollout("invoice", attribute, column_spec())

      assert outcome_for(result, active.tenant_id) != nil
      assert outcome_for(result, inactive.tenant_id) == nil
    end
  end
end
