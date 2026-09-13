defmodule Letflow.ExamFixtures do
  @moduledoc """
  Shared REQ-332/REQ-333 test fixture: provisions a real tenant schema and
  installs just enough of the bilimbaga entity definitions (`exam`,
  `question`, `answer_option`, `exam_question_rule`, `session`,
  `session_question`, `session_answer`, `session_question_score`,
  `session_event`) for
  `Letflow.Exam.Session`/`Letflow.Exam.QuestionSetResolver`/
  `Letflow.Exam.Scoring`/`Letflow.Exam.AntiCheat` integration tests, without a full
  `Letflow.Definitions.SolutionPack.install/3` (no column promotion, no
  per-type table -- every field this suite filters on is already
  `queried: true` in the real `priv/packs/bilimbaga/entity_definitions/*.json`
  documents, so `Letflow.Entities.Query.Compiler` reads them straight off
  `entity_record_latest`'s JSONB `field_values`). Mirrors
  `test/letflow/entities/query_joins_test.exs`'s own hand-rolled
  tenant-fixture pattern (DIRECTIVE T-4).
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Ecto.Query, only: [from: 2]

  alias Letflow.Entities.Definitions
  alias Letflow.Entities.Records
  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.ColumnPromotion
  alias Letflow.TenantProvisioning.Registration

  @definitions_dir Path.join([File.cwd!(), "priv", "packs", "bilimbaga", "entity_definitions"])

  @entity_types ~w(exam question answer_option exam_question_rule
                    session session_question session_answer session_question_score
                    session_event)

  @doc """
  Provisions a fresh tenant schema, seeds event types, and activates every
  entity definition this suite needs -- real definitions read directly from
  `priv/packs/bilimbaga/entity_definitions/*.json` (converted to
  `Letflow.Entities.Definition.t()`'s atom-keyed shape), not hand-abbreviated
  copies. Sets `Ecto.Adapters.SQL.Sandbox` to `:auto` mode -- provisioning
  commits real DDL outside any sandboxed transaction, and the concurrent-
  submit test needs genuinely concurrent connections.
  """
  @spec provisioned_tenant_with_exam_definitions(slug_prefix :: String.t()) :: %{
          tenant_id: Ecto.UUID.t(),
          schema_name: String.t()
        }
  def provisioned_tenant_with_exam_definitions(slug_prefix) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!(slug_prefix)

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))

      # ISS-0648 fix note: `session_question` (and any other entity type in
      # this fixture's list that declares a `constraints` entry) is now
      # auto-promoted on activation, which inserts a real
      # `entity_column_promotions` row -- a GLOBAL table with an FK to
      # `tenants` (same class of cleanup gap
      # `test/letflow/entities/iss0648_column_promotion_trigger_test.exs`'s
      # own `provisioned_tenant/0` and
      # `test/letflow/packs/bilimbaga_pack_install_test.exs`'s own tenant
      # fixture already guard against). Without this, deleting the `tenants`
      # row below raises a `foreign_key_violation` in `on_exit` for every
      # test using this fixture, once any of its entity types has a
      # constraint.
      Repo.delete_all(from(cp in ColumnPromotion, where: cp.tenant_id == ^tenant.id))

      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)
    assert {:ok, _seed_result} = Letflow.Entities.EventTypes.seed!(schema_name)

    for entity_type <- @entity_types do
      create_active_definition!(schema_name, load_definition!(entity_type))
    end

    # ISS-0647: this is the one place in this codebase that stands up the
    # real bilimbaga `question`/`answer_option` entity definitions for
    # actual use -- so this is where the pack's answer-key field
    # restrictions get seeded too, per
    # `Letflow.Packs.Bilimbaga`'s own moduledoc "Callers" section. Without
    # this, every exam-suite test built on this fixture would exercise a
    # tenant where `is_correct`/`likert_weight`/`likert_polarity`/
    # `explanation` are reachable in clear via the generic
    # `POST /entities/query` route for any TASK_WORKER-scoped caller.
    :ok = Letflow.Packs.Bilimbaga.seed_answer_key_field_restrictions!(schema_name)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  @doc "Creates a record via `Letflow.Entities.Records.create_record/2`, asserting success."
  @spec create_record!(String.t(), String.t(), map(), Ecto.UUID.t()) ::
          Letflow.Entities.Record.Latest.t()
  def create_record!(schema, entity_type, field_values, actor_id \\ Ecto.UUID.generate()) do
    assert {:ok, %{record: record}} =
             Records.create_record(
               %{
                 entity_type: entity_type,
                 field_values: field_values,
                 actor_id: actor_id,
                 idempotency_key: Ecto.UUID.generate()
               },
               schema
             )

    record
  end

  # ---------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------

  defp insert_tenant!(slug_prefix) do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug(slug_prefix),
        display_name: "REQ-332 Exam Session Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp create_active_definition!(schema, definition) do
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

  defp load_definition!(entity_type) do
    @definitions_dir
    |> Path.join("#{entity_type}.json")
    |> File.read!()
    |> Jason.decode!()
    |> to_definition()
  end

  defp to_definition(json) do
    %{
      name: Map.fetch!(json, "name"),
      display_name: Map.fetch!(json, "display_name"),
      fields: json |> Map.get("fields", []) |> Enum.map(&to_field/1),
      indexes: json |> Map.get("indexes", []) |> Enum.map(&to_index/1),
      foreign_keys: [],
      constraints: json |> Map.get("constraints", []) |> Enum.map(&to_constraint/1)
    }
  end

  # foreign_keys are deliberately dropped: this fixture never promotes a
  # column, so a real Postgres FK is never emitted for these definitions --
  # keeping fk_def entries would be dead configuration, and REQ-300 joins are
  # not exercised by this suite (Session resolves relations via plain
  # Query.Compiler filters, not Compiler joins).
  defp to_field(field) do
    %{
      name: Map.fetch!(field, "name"),
      # `String.to_atom/1`, not `to_existing_atom/1`: this fixture can run
      # before any production code path has referenced e.g. `:localized_text`
      # as a literal, so the atom may not exist in the VM's atom table yet.
      # The field-type vocabulary is a small, fixed, closed set either way
      # (`Letflow.Entities.Definition.field_type()`), so this carries none of
      # the unbounded-atom-creation risk `to_existing_atom/1` guards against
      # in production code paths that see caller-controlled strings.
      type: String.to_atom(Map.fetch!(field, "type")),
      required: Map.get(field, "required", false),
      queried: Map.get(field, "queried", false),
      enum_values: Map.get(field, "enum_values"),
      decimal_precision: Map.get(field, "decimal_precision"),
      decimal_scale: Map.get(field, "decimal_scale"),
      locales: Map.get(field, "locales"),
      search_strategy: field |> Map.get("search_strategy") |> search_strategy_atom()
    }
  end

  defp search_strategy_atom(nil), do: nil
  defp search_strategy_atom(value) when is_binary(value), do: String.to_atom(value)

  defp to_index(index) do
    %{name: Map.fetch!(index, "name"), fields: Map.fetch!(index, "fields")}
  end

  defp to_constraint(constraint) do
    %{
      name: Map.fetch!(constraint, "name"),
      type: String.to_atom(Map.fetch!(constraint, "type")),
      fields: Map.fetch!(constraint, "fields")
    }
  end
end
