defmodule Letflow.Engine.PinResolverTest do
  @moduledoc """
  Unit tests for `Letflow.Engine.PinResolver` (REQ-059, PIN-01..PIN-04). See
  `test/specs/REQ-059.md` for the full test-case rationale.

  Pure module, no `Letflow.Repo`/`Ecto.Sandbox` dependency for the majority
  of this file (`resolve/4`, `validate_initial_variables/2`,
  `merge_effective_pins/2`, `apply_inheritance/2`, `pin_for/3` are all pure)
  -- `async: true` is correct here, mirroring
  `test/letflow/definitions/service_scope_validator_test.exs`'s established
  shape for a pure, injectable-lookup module. `reconstruct_effective_pins/2`
  (the one function that does I/O, via `Reconstruction.read_full_log/3`) and
  every `Letflow.Engine.create/2` integration-level claim (zero-row write on
  failed resolution, the actual `INSTANCE_STARTED` payload shape, child
  inheritance threaded through two real instances, and AC7's
  zero-catalog-reads-during-replay demonstration) live in
  `test/letflow/engine_test.exs` instead, since those need real Postgres.
  """

  use ExUnit.Case, async: true

  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.Graph.Node
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.PinResolver.Lookup
  alias Letflow.EventStore.Registry.ValidationFailure

  # ---------------------------------------------------------------------------------
  # Fixture builders
  # ---------------------------------------------------------------------------------

  defp service_task(id, service_id) do
    %Node{
      id: id,
      node_type: :SERVICE_TASK,
      attributes: %{"endpoint" => "https://example.test/#{id}", "timeout_ms" => 1000}
      |> maybe_put("service_id", service_id)
    }
  end

  defp sub_process(id, module_ref) do
    %Node{id: id, node_type: :SUB_PROCESS, attributes: maybe_put(%{}, "module_ref", module_ref)}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp graph(nodes), do: %Graph{nodes: nodes, edges: []}

  defp definition(name), do: %ProcessDefinition{name: name}

  # A Lookup whose functions raise if ever called -- proves a lookup was
  # genuinely skipped (override path, or halt-before-reached), not merely
  # coincidentally unexercised. Mirrors
  # service_scope_validator_test.exs's raise_if_called_lookup/0 idiom.
  defp raise_if_called_lookup(variable_schema_lookup \\ &default_variable_schema_lookup/2) do
    %Lookup{
      catalog_lookup: fn service_id ->
        raise "catalog_lookup must not be called, got service_id: #{inspect(service_id)}"
      end,
      module_lookup: fn module_ref ->
        raise "module_lookup must not be called, got module_ref: #{inspect(module_ref)}"
      end,
      variable_schema_lookup: variable_schema_lookup
    }
  end

  defp default_variable_schema_lookup(_tenant_id, _process_key),
    do: {:ok, %{version: "unversioned", json_schema: nil}}

  defp pin_resolver_source do
    File.read!(Path.join([File.cwd!(), "lib", "letflow", "engine", "pin_resolver.ex"]))
  end

  defp const_lookup(catalog_result, module_result, variable_schema_result \\ nil) do
    %Lookup{
      catalog_lookup: fn _ref -> catalog_result end,
      module_lookup: fn _ref -> module_result end,
      variable_schema_lookup: fn _tenant_id, _process_key ->
        variable_schema_result || {:ok, %{version: "unversioned", json_schema: nil}}
      end
    }
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- deterministic ordering, byte-identical serialized output across two
  # resolutions (REQ-059's own AC1 wording, load-bearing per design doc §4.3)
  # ---------------------------------------------------------------------------------

  describe "resolve/4 -- AC1: deterministic {kind, ref} ordering, byte-identical serialized output" do
    test "pins are sorted catalog_entry < module < variable_schema, then ref ascending within a kind, regardless of graph node order" do
      g =
        graph([
          sub_process("n1", "mmm-module"),
          service_task("n2", "zzz-service"),
          service_task("n3", "aaa-service")
        ])

      def_ = definition("my-process")
      lookup = const_lookup({:ok, %{resolved_id: "svc-id", version: "1.0.0"}}, {:ok, %{resolved_id: "mod-id", version: "2.0.0"}})

      assert {:ok, pins, _schema} = PinResolver.resolve(g, def_, lookup, [])

      assert Enum.map(pins, & &1.ref) == ["aaa-service", "zzz-service", "mmm-module", "my-process"]
      assert Enum.map(pins, & &1.kind) == [:catalog_entry, :catalog_entry, :module, :variable_schema]
    end

    test "two resolutions of the same graph/definition/lookup produce byte-identical Jason-serialized output" do
      g =
        graph([
          service_task("n1", "svc-a"),
          service_task("n2", "svc-b"),
          sub_process("n3", "mod-a")
        ])

      def_ = definition("byte-identical-process")
      lookup = const_lookup({:ok, %{resolved_id: "sid", version: "1.0.0"}}, {:ok, %{resolved_id: "mid", version: "1.0.0"}})

      assert {:ok, pins_1, _} = PinResolver.resolve(g, def_, lookup, [])
      assert {:ok, pins_2, _} = PinResolver.resolve(g, def_, lookup, [])

      assert pins_1 == pins_2
      assert Jason.encode!(pins_1) == Jason.encode!(pins_2)
    end

    test "duplicate service_id references across two SERVICE_TASK nodes produce exactly one pinned_version entry" do
      g = graph([service_task("n1", "shared-svc"), service_task("n2", "shared-svc")])
      def_ = definition("dup-process")
      lookup = const_lookup({:ok, %{resolved_id: "sid", version: "1.0.0"}}, {:error, :not_found})

      assert {:ok, pins, _schema} = PinResolver.resolve(g, def_, lookup, [])

      assert Enum.count(pins, &(&1.kind == :catalog_entry)) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # Overrides bypass the lookup entirely (design doc §4.1)
  # ---------------------------------------------------------------------------------

  describe "resolve/4 -- overrides substitute for the lookup, no lookup call at all for an overridden ref" do
    test "a matching override entry is used verbatim, source: :override, and the corresponding lookup function is never called" do
      g = graph([service_task("n1", "svc-a"), sub_process("n2", "mod-a")])
      def_ = definition("override-process")

      overrides = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "override-sid", version: "9.9.9"},
        %{kind: :module, ref: "mod-a", resolved_id: "override-mid", version: "8.8.8"}
      ]

      assert {:ok, pins, _schema} = PinResolver.resolve(g, def_, raise_if_called_lookup(), overrides)

      assert %{kind: :catalog_entry, ref: "svc-a", resolved_id: "override-sid", version: "9.9.9", source: :override} =
               Enum.find(pins, &(&1.kind == :catalog_entry))

      assert %{kind: :module, ref: "mod-a", resolved_id: "override-mid", version: "8.8.8", source: :override} =
               Enum.find(pins, &(&1.kind == :module))
    end
  end

  # ---------------------------------------------------------------------------------
  # PIN-01's halt-on-first-unresolved semantics -- no partial list, no second
  # lookup call once the first ref fails.
  # ---------------------------------------------------------------------------------

  describe "resolve/4 -- an unresolvable reference halts resolution entirely, no partial list" do
    test "an unresolvable catalog_entry ref returns {:error, {:unresolved_catalog_ref, ref}} and never calls the lookup for a second, later ref" do
      g = graph([service_task("first", "ghost-svc-1"), service_task("second", "ghost-svc-2")])
      def_ = definition("halt-process")

      call_count = :counters.new(1, [])

      lookup = %Lookup{
        catalog_lookup: fn ref ->
          :counters.add(call_count, 1, 1)

          if :counters.get(call_count, 1) > 1 do
            raise "catalog_lookup must not be called a second time -- resolve/4 should have " <>
                    "halted after the first unresolved ref, got: #{inspect(ref)}"
          end

          {:error, :not_found}
        end,
        module_lookup: fn ref -> raise "module_lookup must not be called, got: #{inspect(ref)}" end,
        variable_schema_lookup: &default_variable_schema_lookup/2
      }

      assert {:error, {:unresolved_catalog_ref, "ghost-svc-1"}} =
               PinResolver.resolve(g, def_, lookup, [])

      assert :counters.get(call_count, 1) == 1
    end

    test "an unresolvable module ref returns {:error, {:unresolved_module_ref, ref}}, distinct from the catalog error" do
      g = graph([sub_process("n1", "ghost-module")])
      def_ = definition("halt-module-process")

      lookup = const_lookup({:error, :not_found}, {:error, :not_found})

      assert {:error, {:unresolved_module_ref, "ghost-module"}} = PinResolver.resolve(g, def_, lookup, [])
    end

    test "an unresolved module ref never runs after a resolved catalog ref -- the variable_schema lookup is also never reached" do
      g = graph([service_task("n1", "resolvable-svc"), sub_process("n2", "ghost-module")])
      def_ = definition("mixed-halt-process")

      lookup = %Lookup{
        catalog_lookup: fn _ref -> {:ok, %{resolved_id: "sid", version: "1.0.0"}} end,
        module_lookup: fn _ref -> {:error, :not_found} end,
        variable_schema_lookup: fn tenant_id, process_key ->
          raise "variable_schema_lookup must not be called once module resolution halted, got: #{inspect({tenant_id, process_key})}"
        end
      }

      assert {:error, {:unresolved_module_ref, "ghost-module"}} = PinResolver.resolve(g, def_, lookup, [])
    end
  end

  # ---------------------------------------------------------------------------------
  # PIN-02 AC4 -- zero catalog and zero module references still record exactly one
  # variable_schema entry, unconditionally.
  # ---------------------------------------------------------------------------------

  describe "resolve/4 -- PIN-02 AC4: zero catalog/module refs still records exactly one variable_schema entry" do
    test "a graph with no SERVICE_TASK/SUB_PROCESS nodes at all still produces exactly one pinned_version, kind: :variable_schema" do
      g = graph([%Node{id: "start", node_type: :START}, %Node{id: "end", node_type: :END}])
      def_ = definition("no-refs-process")

      assert {:ok, [pin], json_schema} =
               PinResolver.resolve(g, def_, raise_if_called_lookup(), [])

      assert pin.kind == :variable_schema
      assert pin.ref == "no-refs-process"
      assert pin.source == :resolved
      assert json_schema == nil
    end

    test "absent/nil/empty/non-string reference attributes contribute nothing -- still exactly one variable_schema entry" do
      g =
        graph([
          service_task("n1", nil),
          %Node{id: "n2", node_type: :SERVICE_TASK, attributes: %{"service_id" => ""}},
          %Node{id: "n3", node_type: :SERVICE_TASK, attributes: %{"service_id" => 123}},
          sub_process("n4", nil)
        ])

      def_ = definition("empty-refs-process")

      assert {:ok, [pin], _schema} = PinResolver.resolve(g, def_, raise_if_called_lookup(), [])

      assert pin.kind == :variable_schema
    end
  end

  # ---------------------------------------------------------------------------------
  # PIN-01 AC3 -- initial variable validation reuses REQ-024's validator, lists
  # every failing field.
  # ---------------------------------------------------------------------------------

  describe "validate_initial_variables/2 -- AC3: reuses REQ-024's JsonSchema.validate/2, lists every failing field" do
    test "nil variable_json_schema (no schema registered) is :ok unconditionally, whatever the variables are" do
      assert :ok = PinResolver.validate_initial_variables(%{"anything" => "goes"}, nil)
      assert :ok = PinResolver.validate_initial_variables(%{}, nil)
    end

    test "variables violating multiple constraints of the resolved schema are rejected listing EVERY failing field, not just the first" do
      schema = %{
        "type" => "object",
        "required" => ["approver", "amount"],
        "properties" => %{
          "amount" => %{"type" => "number", "minimum" => 0}
        }
      }

      variables = %{"amount" => -5}

      assert {:error, {:variable_schema_violation, failures}} =
               PinResolver.validate_initial_variables(variables, schema)

      assert length(failures) == 2

      assert Enum.any?(failures, fn %ValidationFailure{field_path: fp, constraint: c} ->
               fp == "/approver" and c == "required"
             end)

      assert Enum.any?(failures, fn %ValidationFailure{field_path: fp, constraint: c, actual: a} ->
               fp == "/amount" and c == "minimum" and a == -5
             end)
    end

    test "conforming variables against a real resolved schema are accepted" do
      schema = %{"type" => "object", "required" => ["approver"]}

      assert :ok = PinResolver.validate_initial_variables(%{"approver" => "alice"}, schema)
    end
  end

  # ---------------------------------------------------------------------------------
  # PIN-03 AC1/AC5 -- pin_for/3, the no-fallback runtime accessor.
  # ---------------------------------------------------------------------------------

  describe "pin_for/3 -- AC5: PinMissing error naming the reference, never a fallback value" do
    test "a present {kind, ref} entry is found" do
      pins = [%{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved}]

      assert {:ok, %{ref: "svc-a", version: "1.0.0"}} =
               PinResolver.pin_for(pins, :catalog_entry, "svc-a")
    end

    test "an absent {kind, ref} entry returns {:error, {:pin_missing, kind, ref}}, naming the exact kind/ref, never a substitute" do
      pins = [%{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved}]

      assert {:error, {:pin_missing, :catalog_entry, "svc-b"}} =
               PinResolver.pin_for(pins, :catalog_entry, "svc-b")

      assert {:error, {:pin_missing, :module, "svc-a"}} =
               PinResolver.pin_for(pins, :module, "svc-a")
    end

    test "an empty pins list always returns pin_missing, never raises or substitutes" do
      assert {:error, {:pin_missing, :variable_schema, "any-process"}} =
               PinResolver.pin_for([], :variable_schema, "any-process")
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 (inspection-based) -- no code path anywhere past resolve/4's own two lookup
  # call sites ever queries a catalog/module lookup as a fallback. resolve/4 itself
  # is the ONLY function with a Lookup parameter at all (structural evidence);
  # this splits the raw source text at the first occurrence of
  # `def merge_effective_pins` (which appears, in file order, strictly after
  # resolve/4's own body) and asserts nothing from that point on -- covering
  # merge_effective_pins/2, reconstruct_effective_pins/2, apply_inheritance/2, and
  # pin_for/3 -- ever references catalog_lookup/module_lookup at all.
  # ---------------------------------------------------------------------------------

  describe "inspection -- AC5: no fallback-to-current-version code path anywhere in the module" do
    test "merge_effective_pins/2, reconstruct_effective_pins/2, apply_inheritance/2, and pin_for/3 never reference catalog_lookup or module_lookup" do
      source = pin_resolver_source()

      assert source =~ "def merge_effective_pins",
             "expected marker function not found -- source layout changed, update this test's split point"

      [_resolve_and_before, replay_apply_and_pin_for] =
        String.split(source, "def merge_effective_pins(", parts: 2)

      refute replay_apply_and_pin_for =~ "catalog_lookup",
             "found a catalog_lookup reference in merge_effective_pins/2 or later -- possible fallback-to-current-version code path"

      refute replay_apply_and_pin_for =~ "module_lookup",
             "found a module_lookup reference in merge_effective_pins/2 or later -- possible fallback-to-current-version code path"
    end

    test "the only two invocations of lookup.catalog_lookup / lookup.module_lookup in the whole module are inside resolve/4 itself" do
      source = pin_resolver_source()

      assert length(Regex.scan(~r/lookup\.catalog_lookup/, source)) == 1
      assert length(Regex.scan(~r/lookup\.module_lookup/, source)) == 1
    end

    test "reconstruct_effective_pins/2 accepts no Lookup.t() parameter at all (structurally cannot reach a catalog)" do
      assert {:reconstruct_effective_pins, 2} in PinResolver.__info__(:functions)
      # confirmed by the @spec/source read at design time (design doc §6): the
      # 2-arity signature is (instance_id, opts) -- no lookup argument exists to
      # thread a catalog/module dependency through even if a caller wanted to.
    end
  end

  # ---------------------------------------------------------------------------------
  # PIN-04 AC1/AC5/AC7 -- merge_effective_pins/2, the pure replay-time fold.
  # ---------------------------------------------------------------------------------

  describe "merge_effective_pins/2 -- PIN-04: replay-time effective set, pure, folds all rebind events in order" do
    test "with zero rebind events, the effective set mirrors instance_started_pinned_versions exactly (kind/ref/resolved_id/version/source normalized)" do
      base = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved}
      ]

      assert [%{kind: :catalog_entry, ref: "svc-a", version: "1.0.0", source: :resolved}] =
               PinResolver.merge_effective_pins(base, [])
    end

    test "a single rebind event updates only the matching {kind, ref} entry's version, leaves kind/resolved_id/source untouched" do
      base = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved},
        %{kind: :module, ref: "mod-a", resolved_id: "mid", version: "1.0.0", source: :resolved}
      ]

      rebind_event_id = Ecto.UUID.generate()

      rebind_events = [
        %{
          event_id: rebind_event_id,
          payload: %{"entries" => [%{"kind" => "catalog_entry", "ref" => "svc-a", "new_version" => "2.0.0"}]}
        }
      ]

      effective = PinResolver.merge_effective_pins(base, rebind_events)

      assert %{version: "2.0.0", source_event_id: ^rebind_event_id, kind: :catalog_entry, resolved_id: "sid"} =
               Enum.find(effective, &(&1.ref == "svc-a"))

      assert %{version: "1.0.0", kind: :module} = Enum.find(effective, &(&1.ref == "mod-a"))
    end

    test "ALL rebind events are folded, in the given order, not just the most recent -- REQ-060's delta-only payload shape (design doc §6 OQ-2)" do
      base = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved},
        %{kind: :catalog_entry, ref: "svc-b", resolved_id: "sid2", version: "1.0.0", source: :resolved}
      ]

      event_1 = Ecto.UUID.generate()
      event_2 = Ecto.UUID.generate()

      rebind_events = [
        %{
          event_id: event_1,
          payload: %{"entries" => [%{"kind" => "catalog_entry", "ref" => "svc-a", "new_version" => "2.0.0"}]}
        },
        %{
          event_id: event_2,
          payload: %{"entries" => [%{"kind" => "catalog_entry", "ref" => "svc-b", "new_version" => "3.0.0"}]}
        }
      ]

      effective = PinResolver.merge_effective_pins(base, rebind_events)

      # earlier rebind of svc-a is NOT lost even though a later, unrelated
      # rebind event (svc-b) came after it -- folding only the "most recent"
      # event would have silently dropped this.
      assert %{version: "2.0.0"} = Enum.find(effective, &(&1.ref == "svc-a"))
      assert %{version: "3.0.0"} = Enum.find(effective, &(&1.ref == "svc-b"))
    end
  end

  # ---------------------------------------------------------------------------------
  # PIN-04 AC2/AC3 -- apply_inheritance/2, child-instance inheritance and conflicts.
  # ---------------------------------------------------------------------------------

  describe "apply_inheritance/2 -- PIN-04 AC2/AC3: child inheritance, source: inherited, conflict recording" do
    test "a nil parent (root instance) returns own_pins unchanged and zero conflicts" do
      own_pins = [%{kind: :variable_schema, ref: "p", resolved_id: nil, version: "unversioned", source: :resolved}]

      assert {:ok, ^own_pins, []} = PinResolver.apply_inheritance(own_pins, nil)
    end

    test "a parent pin absent from own_pins is ADDED with source: :inherited, no conflict recorded" do
      own_pins = [%{kind: :variable_schema, ref: "proc", resolved_id: nil, version: "unversioned", source: :resolved}]

      parent_pins = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved, source_event_id: Ecto.UUID.generate()}
      ]

      assert {:ok, merged, []} = PinResolver.apply_inheritance(own_pins, parent_pins)

      assert %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :inherited} =
               Enum.find(merged, &(&1.ref == "svc-a"))

      refute Map.has_key?(Enum.find(merged, &(&1.ref == "svc-a")), :source_event_id)
    end

    test "a {kind, ref} present in both with matching versions is kept as-is -- agreement is not inheritance" do
      own_pins = [%{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved}]

      parent_pins = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid", version: "1.0.0", source: :resolved, source_event_id: Ecto.UUID.generate()}
      ]

      assert {:ok, merged, []} = PinResolver.apply_inheritance(own_pins, parent_pins)
      assert [%{source: :resolved, version: "1.0.0"}] = merged
    end

    test "a {kind, ref} present in both with DIFFERING versions: the INHERITED version wins, and a conflict is recorded (PIN-04 AC3)" do
      own_pins = [%{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid-child", version: "1.0.0", source: :resolved}]

      parent_pins = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid-parent", version: "2.0.0", source: :resolved, source_event_id: Ecto.UUID.generate()}
      ]

      assert {:ok, merged, conflicts} = PinResolver.apply_inheritance(own_pins, parent_pins)

      assert [%{kind: :catalog_entry, ref: "svc-a", resolved_id: "sid-parent", version: "2.0.0", source: :inherited}] =
               merged

      assert [
               %{
                 kind: :catalog_entry,
                 ref: "svc-a",
                 child_resolved_version: "1.0.0",
                 inherited_version: "2.0.0"
               }
             ] = conflicts
    end

    test "inheritance wins even over a child's own :override source (design doc §7/OQ-6 -- no override exception)" do
      own_pins = [%{kind: :catalog_entry, ref: "svc-a", resolved_id: "override-sid", version: "9.9.9", source: :override}]

      parent_pins = [
        %{kind: :catalog_entry, ref: "svc-a", resolved_id: "parent-sid", version: "1.0.0", source: :resolved, source_event_id: Ecto.UUID.generate()}
      ]

      assert {:ok, [%{source: :inherited, version: "1.0.0"}], [_conflict]} =
               PinResolver.apply_inheritance(own_pins, parent_pins)
    end

    test "the merged result is re-sorted per resolve/4's own {kind, ref} ordering after inherited additions" do
      own_pins = [%{kind: :variable_schema, ref: "proc", resolved_id: nil, version: "unversioned", source: :resolved}]

      parent_pins = [
        %{kind: :module, ref: "zzz-mod", resolved_id: "mid", version: "1.0.0", source: :resolved, source_event_id: Ecto.UUID.generate()},
        %{kind: :catalog_entry, ref: "aaa-svc", resolved_id: "sid", version: "1.0.0", source: :resolved, source_event_id: Ecto.UUID.generate()}
      ]

      assert {:ok, merged, []} = PinResolver.apply_inheritance(own_pins, parent_pins)

      assert Enum.map(merged, & &1.ref) == ["aaa-svc", "zzz-mod", "proc"]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC8 -- moduledoc names the SCOPE GAP explicitly, citing R-Co's ISS-0672/GH-306.
  # ---------------------------------------------------------------------------------

  defp normalized_moduledoc(module) do
    {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} = Code.fetch_docs(module)
    String.replace(moduledoc, ~r/\s+/, " ")
  end

  describe "moduledoc -- AC8: names the service_catalog(S6)/PLC-01(unscoped) gap, cites ISS-0672/GH-306" do
    test "the moduledoc names service_catalog and attributes it to stage S6" do
      doc = normalized_moduledoc(PinResolver)

      assert doc =~ "service_catalog"
      assert doc =~ "stage S6" or doc =~ "S6"
    end

    test "the moduledoc names PLC-01 and states it is unscoped to any stage" do
      doc = normalized_moduledoc(PinResolver)

      assert doc =~ "PLC-01"
      assert doc =~ "unscoped"
    end

    test "the moduledoc cites R-Co's own ISS-0672/GH-306 precedent" do
      doc = normalized_moduledoc(PinResolver)

      assert doc =~ "ISS-0672"
      assert doc =~ "GH-306"
    end

    test "the moduledoc states unresolvable references return typed errors rather than a stub" do
      doc = normalized_moduledoc(PinResolver)

      assert doc =~ "unresolved_catalog_ref" or doc =~ "UnresolvedCatalogRef"
      assert doc =~ "never a silent no-op" or doc =~ "never a silent no-op or a stub"
    end
  end
end
