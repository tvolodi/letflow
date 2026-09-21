defmodule Letflow.Definitions.SemanticValidationActivationTest do
  @moduledoc """
  DB-backed integration tests for REQ-372's two call-site wirings:
  `Letflow.Definitions.activate/2` (the release/promotion submission gate, AC6) and
  `Letflow.Definitions.validate_definition_graph/2` (the read-only check endpoint). See
  `test/specs/REQ-372.md` for the full per-test rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file. Mirrors
  `test/letflow/definitions/store_test.exs`'s established `provisioned_tenant/1` +
  Sandbox `:auto` + `async: false` pattern exactly (`Ecto.Migrator` needs a second real
  DB connection the sandbox can't hand out) and
  `test/letflow/engine/variable_schema_test.exs`'s `seed_schema_row/5` direct-`Repo.insert`
  pattern for populating `variable_schemas` rows (REQ-109 builds no
  registration/INSERT path of its own).

  ## Why this is a separate file from `test/letflow/definitions/semantic_validation_test.exs`

  `semantic_validation_test.exs` (REQ-372's own pure-unit half) is `async: true` and
  deliberately zero-I/O -- no `Repo` connection, no tenant provisioning, exercising
  `SemanticValidation.validate/2` directly against hand-built `Graph.t()` fixtures. AC6
  specifically requires proving the behavior of the real `activate/2` call path
  (`fetch_schemas/3`'s freshness inside a real transaction against real
  `variable_schemas` rows), which cannot be demonstrated without a real tenant schema --
  so it belongs here, mirroring the same split `store_test.exs`'s own moduledoc
  documents between itself and `definitions_test.exs`.

  Every test provisions its own tenant and uses `unique_name/1`
  (`System.unique_integer/1`-suffixed) for every definition `name` and a fresh
  `Ecto.UUID.generate()` for every `created_by` -- no shared or hard-coded identifiers,
  no test depends on another test's data or on execution order, no wall-clock
  dependency anywhere (`docs/guides/test_developer_guide.md` §1's determinism rule).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine.VariableSchema
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- copied in shape from store_test.exs's/variable_schema_test.exs's
  # own established helpers (not imported: these are independent test modules, and the
  # existing convention in this project is each DB-backed test file owns its own copy).
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req372-sv"),
        display_name: "REQ-372 SemanticValidation Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp provisioned_tenant(_context) do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    tenant = insert_tenant!()

    on_exit(fn ->
      case TenantProvisioning.schema_name_for_tenant(tenant.id) do
        {:ok, schema_name} -> drop_schema!(schema_name)
        {:error, :invalid_tenant_id} -> :ok
      end

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^tenant.id))
      Repo.delete_all(from(t in Tenant, where: t.id == ^tenant.id))
    end)

    assert {:ok, %Registration{schema_name: schema_name}} =
             TenantProvisioning.provision_tenant_schema(tenant.id)

    assert {:ok, _applied_versions} = TenantProvisioning.replay_migrations(tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req372-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # A structurally/attribute/edge-condition-valid graph (passes validate_graph/1,
  # validate_node_attributes/1, validate_edge_conditions/1 -- REQ-028/REQ-029) whose
  # one EXCLUSIVE_GATEWAY edge condition compares a declared "amount" field against a
  # numeric literal, plus a default edge (CHK-15/CHK-16 need exactly one default among
  # a gateway's edges once more than one edge is conditioned).
  defp graph_referencing_amount do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{"id" => "a", "node_type" => "END"},
        %{"id" => "b", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw"},
        %{
          "id" => "e2",
          "source" => "gw",
          "target" => "a",
          "condition" => "amount > 100"
        },
        %{"id" => "e3", "source" => "gw", "target" => "b", "is_default" => true}
      ]
    }
  end

  defp create_attrs(overrides) do
    Map.merge(
      %{
        name: unique_name(),
        version: "1.0.0",
        graph: graph_referencing_amount(),
        created_by: Ecto.UUID.generate()
      },
      overrides
    )
  end

  defp create!(schema_name, overrides \\ %{}) do
    assert {:ok, definition} = Definitions.create(create_attrs(overrides), prefix: schema_name)
    definition
  end

  # Direct Repo.insert against the provisioned tenant schema -- mirrors
  # variable_schema_test.exs's seed_schema_row!/5 exactly (REQ-109 builds no
  # registration/INSERT path of its own, so REQ-372's own tests seed rows this way by
  # construction too).
  defp seed_schema_row!(schema_name, definition_id, variable_key, json_schema) do
    assert {:ok, row} =
             %VariableSchema{}
             |> VariableSchema.changeset(%{
               definition_id: definition_id,
               variable_key: variable_key,
               json_schema: json_schema
             })
             |> Repo.insert(prefix: schema_name)

    row
  end

  # Mutates an already-inserted variable_schemas row's json_schema DIRECTLY via
  # Repo.update_all -- deliberately NOT through VariableSchema's own changeset/upsert
  # path, and NOT through any cache-invalidation hook (there is none anywhere in this
  # path per the design doc's own re-verification §0 point 2/4) -- this is exactly the
  # "change the underlying state between calls, without going through any
  # cache-invalidation hook" AC6 requires.
  defp mutate_schema_row_type!(schema_name, definition_id, variable_key, new_json_schema) do
    {1, _} =
      VariableSchema
      |> where([vs], vs.definition_id == ^definition_id and vs.variable_key == ^variable_key)
      |> Repo.update_all([set: [json_schema: new_json_schema]], prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- THE RE-RUN-NOT-CACHED TEST. The semantic validation pass re-runs in full
  # (not from a cached prior result) at activate/2, proven by changing the underlying
  # VariableSchema state between an earlier clean validation and the activate/2 call,
  # and asserting activate/2 reflects the fresh, now-invalid state.
  # ---------------------------------------------------------------------------------

  describe "activate/2 (AC6) -- re-runs semantic validation in full, never a cached prior result" do
    setup :provisioned_tenant

    test "clean earlier read, variable_schemas type mutated with no cache-invalidation hook, activate/2 blocks for the NEW reason (not the earlier clean result)",
         %{schema_name: schema_name} do
      definition = create!(schema_name)

      # "amount" declared as :numeric -- the gateway edge's "amount > 100" condition
      # is clean.
      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      # --- Earlier clean validation (the read-only check endpoint) ---
      assert {:ok, %{valid: true, violations: []}} =
               Definitions.validate_definition_graph(definition.id, prefix: schema_name)

      # --- Mutate the underlying state between calls, no cache-invalidation hook ---
      # "amount" is now declared :string instead of :numeric -- "amount > 100" (numeric
      # literal) is now a numeric-vs-string incompatible comparison.
      mutate_schema_row_type!(schema_name, definition.id, "amount", %{"type" => "string"})

      # --- Submission call path: activate/2 must reflect the FRESH state ---
      assert {:error, {:semantic_validation_failed, violations}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert [%Letflow.Definitions.Graph.Violation{code: :incompatible_comparison_operand_types}] =
               violations

      [violation] = violations
      assert violation.message =~ "(numeric)"
      assert violation.message =~ "(string)"

      # The definition must still be in :draft -- activate/2 rejected it, it never
      # transitioned.
      assert {:ok, reread} = Definitions.get_by_id(definition.id, prefix: schema_name)
      assert reread.status == :draft
    end

    test "reverse: variable_schemas starts with a non-conflicting field only, \"amount\" is seeded afterward, activate/2's fresh read reflects the new clean state",
         %{schema_name: schema_name} do
      definition = create!(schema_name)

      # Per lib/letflow/design/req372-semantic-decision-rule-validation.md §2.5.4.1
      # point 2 (preferred fix): seed a field OTHER than "amount" first, so
      # declared_fields is non-empty throughout -- a bare zero-row start would fall
      # into §2.5.1's empty-declared_fields short-circuit (valid: true, violations: [])
      # rather than genuinely proving the re-run-not-cached point. "customer_name" is
      # declared but the gateway condition ("amount > 100") never references it, so
      # "amount" is still absent from a *non-empty* declared_fields map here -- a
      # genuine §2.2 :undeclared_variable_reference, not the §2.5.1 exemption.
      seed_schema_row!(schema_name, definition.id, "customer_name", %{"type" => "string"})

      assert {:ok, %{valid: false, violations: violations}} =
               Definitions.validate_definition_graph(definition.id, prefix: schema_name)

      assert Enum.any?(violations, &(&1.code == :undeclared_variable_reference))

      # Now declare "amount" too, directly, with no cache to invalidate.
      seed_schema_row!(schema_name, definition.id, "amount", %{"type" => "number"})

      # activate/2 issues its OWN fresh fetch_schemas/3 read -- it must see "amount" as
      # declared now, not reuse the earlier undeclared-field result.
      assert {:ok, %{definition: activated, already_active: false}} =
               Definitions.activate(definition.id, prefix: schema_name)

      assert activated.status == :active
    end
  end

  # ---------------------------------------------------------------------------------
  # validate_definition_graph/2 -- REQ-372's 4th concatenated violations term.
  # ---------------------------------------------------------------------------------

  describe "validate_definition_graph/2 -- REQ-372's semantic violations concatenated as the 4th term" do
    setup :provisioned_tenant

    test "a declared_fields/condition mismatch reports via the read-only endpoint, without blocking the draft save (design §3.1)", %{
      schema_name: schema_name
    } do
      # "amount" is never declared at all -- create/2 itself does not gate on this
      # (design §3.1: draft-save is deliberately NOT gated by the semantic pass), so
      # the draft save below must succeed even though the condition is semantically
      # broken.
      definition = create!(schema_name)

      # Per lib/letflow/design/req372-semantic-decision-rule-validation.md §2.5.4.1
      # point 3 (preferred fix): seed a field OTHER than "amount" first, so
      # declared_fields is non-empty -- this keeps the demonstrated mismatch a genuine
      # §2.2 violation (declared_fields non-empty, "amount" still absent from it)
      # rather than relying on §2.5.1's empty-declared_fields exemption, which would
      # silently resolve to valid: true and stop proving this test's actual intent (a
      # real semantic mismatch is reported without blocking the draft save).
      seed_schema_row!(schema_name, definition.id, "customer_name", %{"type" => "string"})

      assert {:ok, %{valid: false, violations: violations, definition_id: definition_id}} =
               Definitions.validate_definition_graph(definition.id, prefix: schema_name)

      assert definition_id == definition.id
      assert Enum.any?(violations, &(&1.code == :undeclared_variable_reference))

      # the draft itself was never rejected -- it still exists, still :draft.
      assert {:ok, reread} = Definitions.get_by_id(definition.id, prefix: schema_name)
      assert reread.status == :draft
    end
  end
end
