defmodule Letflow.Definitions.ServiceScopeValidatorTest do
  @moduledoc """
  Unit tests for `Letflow.Definitions.ServiceScopeValidator.validate/3` (REQ-031, SVC-03).
  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this file (INV-SSV-4)
  -- `async: true` is correct here, mirroring
  `test/letflow/definitions/graph_test.exs`'s established shape for a pure validator module
  (hand-built `Graph`/`Node` fixtures, no tenant provisioning). See `test/specs/REQ-031.md`
  for the full test-case rationale, including why each of the two deliberate R-Co
  asymmetries (INV-SSV-5, INV-SSV-9) gets its own named test rather than incidental
  coverage.

  The `activate/2` hook-wiring demonstration (AC4) needs real Postgres (a real
  `ProcessDefinition` row to activate) and lives in
  `test/letflow/definitions/store_test.exs` instead, alongside REQ-030's own `activate/2`
  test fixtures -- see that file's new `"activate/2 (REQ-031 AC4)"` describe block.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Definitions.ServiceScopeValidator
  alias Letflow.Definitions.ServiceScopeValidator.{Lookup, Violation}

  # ---------------------------------------------------------------------------------
  # Fixture builders
  # ---------------------------------------------------------------------------------

  defp service_task(id, attributes),
    do: %Node{id: id, node_type: :SERVICE_TASK, attributes: attributes}

  defp node(id, type, attributes \\ nil),
    do: %Node{id: id, node_type: type, attributes: attributes}

  defp graph(nodes), do: %Graph{nodes: nodes, edges: []}

  # A Lookup whose functions raise if ever called -- used to PROVE a node/attribute was
  # genuinely skipped, or that short-circuiting genuinely happened, rather than merely
  # asserting on the returned value (which a coincidentally-passing lookup could also
  # produce). Mirrors store_test.exs's existing `exploding_validator` technique for
  # activate/2's own hook, applied here to validate/3's internal lookups.
  defp raise_if_called_lookup do
    %Lookup{
      service_lookup: fn service_id ->
        raise "service_lookup must not be called for this fixture, got service_id: #{inspect(service_id)}"
      end,
      plugin_lookup: fn plugin_handler, tenant_id ->
        raise "plugin_lookup must not be called for this fixture, got: #{inspect({plugin_handler, tenant_id})}"
      end
    }
  end

  defp lookup(service_lookup, plugin_lookup) do
    %Lookup{service_lookup: service_lookup, plugin_lookup: plugin_lookup}
  end

  # Constant-result lookup helpers, one function each, for tests that only exercise one
  # side (the other side is given the raise-if-called guard so an accidental call is
  # caught immediately rather than silently passing).
  defp service_result_lookup(result) do
    lookup(fn _service_id -> result end, fn plugin_handler, tenant_id ->
      raise "plugin_lookup must not be called, got: #{inspect({plugin_handler, tenant_id})}"
    end)
  end

  defp plugin_result_lookup(result) do
    lookup(
      fn service_id ->
        raise "service_lookup must not be called, got service_id: #{inspect(service_id)}"
      end,
      fn _plugin_handler, _tenant_id -> result end
    )
  end

  @tenant_a "11111111-1111-1111-1111-111111111111"
  @tenant_b "22222222-2222-2222-2222-222222222222"

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "given an injected lookup returning a global-scope service,
  # a SERVICE_TASK referencing it passes validation for any tenant_id."
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- AC1: global-scope service passes for any tenant_id" do
    test "a SERVICE_TASK referencing a global-scope service_id passes for tenant A" do
      g = graph([service_task("n1", %{"service_id" => "global-svc"})])

      lu = service_result_lookup({:ok, %{scope: :global, owner_tenant_id: nil}})

      assert ServiceScopeValidator.validate(g, @tenant_a, lu) == :ok
    end

    test "the same global-scope service_id passes for a completely different tenant B, same Lookup, unchanged" do
      g = graph([service_task("n1", %{"service_id" => "global-svc"})])

      lu = service_result_lookup({:ok, %{scope: :global, owner_tenant_id: nil}})

      assert ServiceScopeValidator.validate(g, @tenant_a, lu) == :ok
      assert ServiceScopeValidator.validate(g, @tenant_b, lu) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "given an injected lookup returning a tenant-scoped service
  # owned by tenant A, a SERVICE_TASK referencing it fails validation when activated by
  # tenant B, with a violation detail naming the node_id and the service ref_id."
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- AC2: tenant-scoped service owned by tenant A fails for tenant B" do
    test "a SERVICE_TASK referencing a service owned by tenant A fails when validated as tenant B, violation names the exact node_id and service ref_id" do
      g = graph([service_task("checkout-node", %{"service_id" => "billing-svc"})])

      lu = service_result_lookup({:ok, %{scope: :tenant, owner_tenant_id: @tenant_a}})

      assert {:error,
              %Violation{
                node_id: "checkout-node",
                kind: :service,
                ref_id: "billing-svc",
                reason: :service_not_available_to_tenant
              }} = ServiceScopeValidator.validate(g, @tenant_b, lu)
    end

    test "the same tenant-scoped service passes when validated as its own owning tenant A" do
      g = graph([service_task("checkout-node", %{"service_id" => "billing-svc"})])

      lu = service_result_lookup({:ok, %{scope: :tenant, owner_tenant_id: @tenant_a}})

      assert ServiceScopeValidator.validate(g, @tenant_a, lu) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "given an injected lookup returning 'not registered' for a
  # service_id, validation fails with a distinct not-registered violation reason,
  # distinguishable from the owned-by-another-tenant case."
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- AC3: not-registered is a distinct, comparable reason from owned-by-another-tenant" do
    test "a not-registered service_id fails with reason :service_not_registered" do
      g = graph([service_task("n1", %{"service_id" => "ghost-svc"})])

      lu = service_result_lookup({:error, :not_registered})

      assert {:error, %Violation{reason: :service_not_registered, ref_id: "ghost-svc"}} =
               ServiceScopeValidator.validate(g, @tenant_a, lu)
    end

    test "the not-registered reason and the owned-by-another-tenant reason are distinct, comparable atom values -- not merely different message strings" do
      not_registered_graph = graph([service_task("n1", %{"service_id" => "ghost-svc"})])
      not_registered_lookup = service_result_lookup({:error, :not_registered})

      owned_elsewhere_graph = graph([service_task("n2", %{"service_id" => "billing-svc"})])

      owned_elsewhere_lookup =
        service_result_lookup({:ok, %{scope: :tenant, owner_tenant_id: @tenant_a}})

      assert {:error, %Violation{reason: reason_1}} =
               ServiceScopeValidator.validate(
                 not_registered_graph,
                 @tenant_a,
                 not_registered_lookup
               )

      assert {:error, %Violation{reason: reason_2}} =
               ServiceScopeValidator.validate(
                 owned_elsewhere_graph,
                 @tenant_b,
                 owned_elsewhere_lookup
               )

      assert is_atom(reason_1)
      assert is_atom(reason_2)
      assert reason_1 == :service_not_registered
      assert reason_2 == :service_not_available_to_tenant

      refute reason_1 == reason_2,
             "not-registered and owned-by-another-tenant must be distinct reason values, " <>
               "got the same atom for both: #{inspect(reason_1)}"
    end
  end

  # ---------------------------------------------------------------------------------
  # Asymmetry 1 (INV-SSV-5): plugin_handler "not registered" is a PASS, service_id
  # "not registered" is a VIOLATION -- one of the two most-scrutinized decisions in this
  # requirement's design (design doc §5's "why the first asymmetry is preserved" note).
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- asymmetry 1 (INV-SSV-5): plugin not-registered passes, service not-registered fails" do
    test "a not-registered plugin_handler passes validation (no violation)" do
      g = graph([service_task("n1", %{"plugin_handler" => "ghost-plugin"})])

      lu = plugin_result_lookup({:error, :not_registered})

      assert ServiceScopeValidator.validate(g, @tenant_a, lu) == :ok
    end

    test "the identical not-registered condition fails on the service side (confirms the asymmetry is real)" do
      plugin_graph = graph([service_task("n1", %{"plugin_handler" => "ghost-plugin"})])
      plugin_lookup = plugin_result_lookup({:error, :not_registered})

      service_graph = graph([service_task("n2", %{"service_id" => "ghost-svc"})])
      service_lookup = service_result_lookup({:error, :not_registered})

      assert ServiceScopeValidator.validate(plugin_graph, @tenant_a, plugin_lookup) == :ok

      assert {:error, %Violation{kind: :service, reason: :service_not_registered}} =
               ServiceScopeValidator.validate(service_graph, @tenant_a, service_lookup)
    end
  end

  # ---------------------------------------------------------------------------------
  # Asymmetry 2 (INV-SSV-7 vs INV-SSV-9): a resolved tenant-scoped lookup with a nil
  # owner_tenant_id is a VIOLATION on the service side but a silent PASS on the plugin
  # side -- the exact inverse for the identically-shaped malformed-lookup case. This is
  # the decision that triggered a CODE-DESIGN-VALIDATOR rework cycle (per this run's
  # task briefing) -- its own named test, not incidental coverage.
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- asymmetry 2 (INV-SSV-7 vs INV-SSV-9): nil owner_tenant_id is a violation for service, a pass for plugin" do
    test "a tenant-scoped service lookup with owner_tenant_id: nil is a violation" do
      g = graph([service_task("n1", %{"service_id" => "inconsistent-svc"})])

      lu = service_result_lookup({:ok, %{scope: :tenant, owner_tenant_id: nil}})

      assert {:error,
              %Violation{
                kind: :service,
                reason: :service_not_available_to_tenant,
                message: "service inconsistent-svc scope data is inconsistent"
              }} = ServiceScopeValidator.validate(g, @tenant_a, lu)
    end

    test "the identically-shaped tenant-scoped plugin lookup with owner_tenant_id: nil is a pass (inverse of the service-side case)" do
      g = graph([service_task("n1", %{"plugin_handler" => "inconsistent-plugin"})])

      lu = plugin_result_lookup({:ok, %{scope: :tenant, owner_tenant_id: nil}})

      assert ServiceScopeValidator.validate(g, @tenant_a, lu) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # Plugin-side "owned by another tenant" violation -- the one plugin-side branch-table
  # row not otherwise exercised above (not one of the two asymmetries, but needed so the
  # plugin branch table's real violation row isn't left completely untested).
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- plugin-side mismatched-owner violation" do
    test "a plugin_handler owned by tenant A fails with :plugin_not_available_to_tenant when validated as tenant B" do
      g = graph([service_task("n1", %{"plugin_handler" => "billing-plugin"})])

      lu = plugin_result_lookup({:ok, %{scope: :tenant, owner_tenant_id: @tenant_a}})

      assert {:error,
              %Violation{
                kind: :plugin,
                ref_id: "billing-plugin",
                reason: :plugin_not_available_to_tenant
              }} =
               ServiceScopeValidator.validate(g, @tenant_b, lu)
    end
  end

  # ---------------------------------------------------------------------------------
  # First-violation-wins / short-circuit semantics (design doc §5 step 2,
  # Enum.reduce_while/3) -- proven via a lookup that raises if called a second time,
  # rather than merely asserted on the returned violation alone.
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- first-violation-wins: Enum.reduce_while/3 genuinely halts, proven not just asserted" do
    test "a graph with 2 violating SERVICE_TASK nodes returns only the FIRST node's violation, and the second node's lookup function is never called" do
      g =
        graph([
          service_task("first-violator", %{"service_id" => "ghost-svc-1"}),
          service_task("second-violator", %{"service_id" => "ghost-svc-2"})
        ])

      call_count = :counters.new(1, [])

      lu =
        lookup(
          fn service_id ->
            :counters.add(call_count, 1, 1)

            if :counters.get(call_count, 1) > 1 do
              raise "service_lookup must not be called a second time -- validate/3 should have " <>
                      "halted after the first violation, but was called again for: #{inspect(service_id)}"
            end

            {:error, :not_registered}
          end,
          fn plugin_handler, tenant_id ->
            raise "plugin_lookup must not be called, got: #{inspect({plugin_handler, tenant_id})}"
          end
        )

      assert {:error, %Violation{node_id: "first-violator", ref_id: "ghost-svc-1"}} =
               ServiceScopeValidator.validate(g, @tenant_a, lu)

      assert :counters.get(call_count, 1) == 1
    end

    test "a violation on the service check for a node short-circuits before that same node's plugin check runs" do
      g =
        graph([
          service_task("n1", %{"service_id" => "ghost-svc", "plugin_handler" => "some-plugin"})
        ])

      lu =
        lookup(
          fn _service_id -> {:error, :not_registered} end,
          fn plugin_handler, tenant_id ->
            raise "plugin_lookup must not be called -- the service check on the same node " <>
                    "should have already halted the walk, got: #{inspect({plugin_handler, tenant_id})}"
          end
        )

      assert {:error, %Violation{kind: :service, reason: :service_not_registered}} =
               ServiceScopeValidator.validate(g, @tenant_a, lu)
    end
  end

  # ---------------------------------------------------------------------------------
  # Malformed/garbage lookup results (SECURITY-REVIEWER OQ-1): confirm fail-closed
  # (raise) rather than silently passing.
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- malformed Lookup results fail closed, never silently pass (SECURITY-REVIEWER OQ-1)" do
    test "a service_lookup returning a completely out-of-contract value raises rather than silently passing" do
      g = graph([service_task("n1", %{"service_id" => "some-svc"})])

      lu = service_result_lookup(:not_a_valid_result_shape_at_all)

      assert_raise FunctionClauseError, fn ->
        ServiceScopeValidator.validate(g, @tenant_a, lu)
      end
    end

    test "a plugin_lookup returning a completely out-of-contract value also raises rather than silently passing" do
      g = graph([service_task("n1", %{"plugin_handler" => "some-plugin"})])

      lu = plugin_result_lookup(:not_a_valid_result_shape_at_all)

      assert_raise FunctionClauseError, fn ->
        ServiceScopeValidator.validate(g, @tenant_a, lu)
      end
    end
  end

  # ---------------------------------------------------------------------------------
  # Nodes with no service_id/plugin_handler attribute, and non-SERVICE_TASK nodes, are
  # skipped -- never misclassified as violations. Each uses a raise-if-called Lookup so
  # a passing test genuinely proves the skip, not a coincidental pass.
  # ---------------------------------------------------------------------------------

  describe "validate/3 -- nodes with no service_id/plugin_handler attribute, and non-SERVICE_TASK nodes, are skipped" do
    test "a SERVICE_TASK node with attributes: nil contributes no violation and is skipped entirely" do
      g = graph([service_task("n1", nil)])

      assert ServiceScopeValidator.validate(g, @tenant_a, raise_if_called_lookup()) == :ok
    end

    test "a SERVICE_TASK node with attributes present but neither 'service_id' nor 'plugin_handler' keys contributes no violation" do
      g = graph([service_task("n1", %{"other_key" => "value"})])

      assert ServiceScopeValidator.validate(g, @tenant_a, raise_if_called_lookup()) == :ok
    end

    test "a SERVICE_TASK node whose service_id attribute is an empty string, or not a string at all, is skipped for that key (INV-SSV-3)" do
      empty_string = graph([service_task("n1", %{"service_id" => ""})])
      non_string = graph([service_task("n2", %{"service_id" => 123})])
      missing_key = graph([service_task("n3", %{})])

      assert ServiceScopeValidator.validate(empty_string, @tenant_a, raise_if_called_lookup()) ==
               :ok

      assert ServiceScopeValidator.validate(non_string, @tenant_a, raise_if_called_lookup()) ==
               :ok

      assert ServiceScopeValidator.validate(missing_key, @tenant_a, raise_if_called_lookup()) ==
               :ok
    end

    test "a non-SERVICE_TASK node (e.g. HUMAN_TASK) carrying a service_id-shaped attribute is never inspected at all" do
      g = graph([node("n1", :HUMAN_TASK, %{"service_id" => "some-service"})])

      assert ServiceScopeValidator.validate(g, @tenant_a, raise_if_called_lookup()) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # build/1 -- returns the exact 2-arity closure activate/2's hook contract requires
  # (design doc §4, INV-SSV-8). The behavioral wiring through the real activate/2 (AC4)
  # is tested against real Postgres in store_test.exs; this is the pure-layer check that
  # build/1's own output forwards both arguments and the supplied Lookup correctly.
  # ---------------------------------------------------------------------------------

  describe "build/1 -- returns a 2-arity closure forwarding to validate/3 with the captured Lookup" do
    test "the closure's :ok/{:error, _} outcome matches calling validate/3 directly with the same Lookup" do
      g = graph([service_task("n1", %{"service_id" => "ghost-svc"})])
      lu = service_result_lookup({:error, :not_registered})

      hook = ServiceScopeValidator.build(lu)

      assert is_function(hook, 2)
      assert hook.(g, @tenant_a) == ServiceScopeValidator.validate(g, @tenant_a, lu)
    end

    test "the closure passes for a Lookup that permits the reference" do
      g = graph([service_task("n1", %{"service_id" => "global-svc"})])
      lu = service_result_lookup({:ok, %{scope: :global, owner_tenant_id: nil}})

      hook = ServiceScopeValidator.build(lu)

      assert hook.(g, @tenant_a) == :ok
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 5: "the moduledoc explicitly names the ServiceCatalog/
  # PluginRegistry dependency gap and which future stage each belongs to, rather than
  # implying real catalog integration exists today."
  # ---------------------------------------------------------------------------------

  # Local copy of the whitespace-normalizing moduledoc helper -- matches the pattern
  # independently established in definitions_test.exs and promotion_review_test.exs,
  # each of which defines its own copy rather than sharing one across files.
  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(module)

    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "moduledoc -- AC5: ServiceCatalog/PluginRegistry dependency gap is named, with owning stages" do
    test "the moduledoc names ServiceCatalog as the real service-registry dependency and attributes it to stage S6" do
      doc = normalized_moduledoc(ServiceScopeValidator)

      assert doc =~ "ServiceCatalog",
             "moduledoc does not name ServiceCatalog"

      assert doc =~ "stage S6",
             "moduledoc does not attribute ServiceCatalog to stage S6"
    end

    test "the moduledoc names PluginRegistry as the real plugin-dispatch dependency and attributes it to stage S3" do
      doc = normalized_moduledoc(ServiceScopeValidator)

      assert doc =~ "PluginRegistry",
             "moduledoc does not name PluginRegistry"

      assert doc =~ "stage S3",
             "moduledoc does not attribute PluginRegistry to stage S3"
    end

    test "the moduledoc states this module does NOT implement or depend on either dependency today" do
      doc = normalized_moduledoc(ServiceScopeValidator)

      assert doc =~ "does NOT implement, and does not itself depend on",
             "moduledoc does not explicitly state it does not implement/depend on the real catalog/registry today"

      assert doc =~ "no default, production-ready `Lookup` in this codebase yet",
             "moduledoc does not state that no production-ready Lookup exists yet"
    end
  end
end
