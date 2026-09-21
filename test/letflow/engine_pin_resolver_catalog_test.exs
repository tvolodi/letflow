defmodule Letflow.EnginePinResolverCatalogTest do
  @moduledoc """
  Tests for REQ-373's integration point between `Letflow.ServiceCatalog`,
  `Letflow.ServiceCatalog.PinLookup`, `Letflow.Engine.PinResolver`, and
  `Letflow.Engine.create/2`. See
  `test/specs/req373-service-catalog-version-lifecycle.md` for the full
  acceptance-criterion -> test-case mapping and rationale. Design authority:
  `lib/letflow/design/req373-service-catalog-version-lifecycle.md` §2/§3/§5/§6.

  Distinct from `test/letflow/service_catalog_test.exs` (which covers
  `publish/3`/`retire/1`'s own context-module-level behavior and the AC1
  schema/migration) and `test/letflow/engine/pin_resolver_test.exs` (which
  covers `PinResolver`'s pure functions against hand-rolled `const_lookup`
  stubs, never a real `Repo`-backed `Lookup`) -- this file is the one place
  `Letflow.ServiceCatalog.PinLookup.build/0` (the REAL, non-default `Lookup`)
  is exercised against real Postgres, both alone (AC3, AC4) and wired all the
  way through `Engine.create/2`'s own real call site with zero
  caller-supplied `pin_lookup` override (AC2, AC5) -- the only way to prove
  the call-site wiring itself, not merely that `PinLookup` behaves correctly
  in isolation.

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1. `async: false`: this
  file writes real, committed rows to the GLOBAL `service_catalog` table
  (same reasoning `service_catalog_test.exs`'s own moduledoc documents) AND
  provisions real tenant schemas via `Letflow.TenantFixture.provisioned_tenant!/1`
  (same reasoning `engine_test.exs`'s own moduledoc documents) -- both need
  serialization against every other `async: false` file in this suite.
  `Sandbox.mode(Letflow.Repo, :auto)` is set explicitly in `setup/0` (belt and
  suspenders with `provisioned_tenant!/1`'s own identical first line) so the
  handful of tests here that touch ONLY `service_catalog` and never call
  `provisioned_tenant/0` are still covered.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Letflow.Definitions
  alias Letflow.Definitions.Graph
  alias Letflow.Definitions.ProcessDefinition
  alias Letflow.Engine
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Reconstruction
  alias Letflow.ServiceCatalog
  alias Letflow.ServiceCatalog.Entry
  alias Letflow.ServiceCatalog.PinLookup
  alias Letflow.TenantFixture

  setup do
    Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp unique_service_id(prefix \\ "req373-svc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp cleanup_entry!(service_id) do
    Repo.delete_all(from(e in Entry, where: e.service_id == ^service_id))
  end

  defp register!(overrides \\ %{}) do
    attrs =
      %{
        service_id: unique_service_id(),
        endpoint_url: "https://example.test/svc",
        required_auth: :NONE,
        timeout_ms: 5_000,
        scope: :global
      }
      |> Map.merge(overrides)

    on_exit(fn -> cleanup_entry!(attrs.service_id) end)
    assert {:ok, entry} = ServiceCatalog.register(attrs)
    entry
  end

  # ── PinResolver.resolve/4-level fixtures (no tenant schema needed) ─────────

  defp service_task_node(id, service_id) do
    %Graph.Node{
      id: id,
      node_type: :SERVICE_TASK,
      attributes: %{"service_id" => service_id, "timeout_ms" => 5000}
    }
  end

  defp graph_with_service_task(service_id) do
    %Graph{nodes: [service_task_node("svc", service_id)], edges: []}
  end

  defp definition_stub(name \\ "req373-proc") do
    %ProcessDefinition{name: name}
  end

  # ── Engine.create/2-level fixtures (real tenant schema, mirrors
  # engine_test.exs's own established discipline) ─────────────────────────

  defp provisioned_tenant do
    %{tenant_id: tenant_id, schema_name: schema_name} =
      TenantFixture.provisioned_tenant!(
        slug_prefix: "req373",
        display_name: "REQ-373 Test Tenant"
      )

    %{tenant_id: tenant_id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req373-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> HUMAN_TASK -> SERVICE_TASK(service_id: given) -> END. The
  # SERVICE_TASK is deliberately reached only AFTER a genuine HUMAN_TASK stop
  # -- create/2's own activation loop never dispatches it in this same call
  # (HUMAN_TASK has no automatic outgoing traversal, matching engine_test.exs's
  # own established idiom), so this fixture sidesteps REQ-215's own
  # out-of-scope dispatch-layer limitation entirely (a route_kind:
  # :catalog_service SERVICE_TASK always fails validate_rendered_url/1 today,
  # per engine_test.exs:1073-1079's own documented finding) while still
  # exercising real pin RESOLUTION -- PinResolver.resolve/4 walks every
  # SERVICE_TASK node in the whole graph regardless of reachability
  # (pin_resolver.ex's collect_refs/3), so the pin is resolved and recorded
  # in the INSTANCE_STARTED event either way.
  defp graph_human_task_then_service_task(service_id) do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "HUMAN_TASK",
          "attributes" => %{"role" => "approver"}
        },
        %{
          "id" => "svc",
          "node_type" => "SERVICE_TASK",
          "attributes" => %{"service_id" => service_id, "timeout_ms" => 5000}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "svc"},
        %{"id" => "e3", "source" => "svc", "target" => "end"}
      ]
    }
  end

  defp active_definition!(schema_name, graph, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: unique_name(),
          version: "1.0.0",
          graph: graph,
          created_by: Ecto.UUID.generate()
        },
        overrides
      )

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  defp base_attrs(definition, overrides \\ %{}) do
    Map.merge(
      %{
        definition_id: definition.id,
        initial_variables: %{},
        actor_id: Ecto.UUID.generate(),
        idempotency_key: "req373-#{System.unique_integer([:positive, :monotonic])}"
      },
      overrides
    )
  end

  defp started_event!(instance_id, schema_name) do
    assert {:ok, events} = Reconstruction.read_full_log(instance_id, schema_name, 1)
    Enum.find(events, &(&1.event_type == "INSTANCE_STARTED"))
  end

  defp catalog_pin(pinned_versions) do
    Enum.find(pinned_versions, &(&1["kind"] == "catalog_entry"))
  end

  # resolve/4 always additionally returns exactly one :variable_schema pin
  # (pin_resolver.ex §4.2, "unconditionally exactly one variable_schema
  # entry") alongside any :catalog_entry pins -- every fixture graph in this
  # file has exactly one SERVICE_TASK node, so a successful resolve/4 call
  # always returns a 2-element list, never a 1-element one. This helper picks
  # out just the :catalog_entry pin so tests don't have to (re-)encode that
  # unconditional-variable_schema-entry fact themselves.
  defp catalog_entry_pin!(pins) do
    assert pin = Enum.find(pins, &(&1.kind == :catalog_entry))
    pin
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- a new case after a publish resolves the newly published version via
  # PinResolver.resolve/4's real (non-default) Lookup.
  # ---------------------------------------------------------------------------------

  describe "REQ-373 AC3: a fresh resolve/4 after a publish picks up the newly published version" do
    test "PinResolver.resolve/4 + PinLookup.build/0 returns the post-publish version/version_id, source: :resolved" do
      entry = register!()

      assert {:ok, updated} =
               ServiceCatalog.publish(entry.service_id, "2", %{
                 endpoint_url: "https://example.test/svc-v2",
                 required_auth: :NONE,
                 timeout_ms: 6_000
               })

      graph = graph_with_service_task(entry.service_id)
      lookup = PinLookup.build()

      assert {:ok, pins, _json_schema} =
               PinResolver.resolve(graph, definition_stub(), lookup, [])

      pin = catalog_entry_pin!(pins)

      assert pin.ref == entry.service_id
      assert pin.version == "2"
      assert pin.resolved_id == updated.version_id
      assert pin.resolved_id != entry.version_id
      assert pin.source == :resolved
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- the two-sided retire test. Single test function, deliberately not
  # split across two -- see the spec doc's own rationale for why both halves
  # must share one service_id/retire call to genuinely prove the contract.
  # ---------------------------------------------------------------------------------

  describe "REQ-373 AC4: retire is two-sided -- a fresh resolve/4 fails outright, while pin_for/3 over an already-obtained pin is entirely unaffected" do
    test "resolve/4 against a retired ref returns {:error, {:unresolved_catalog_ref, ref}}, while pin_for/3 over the pin captured BEFORE retirement still returns {:ok, pin} AFTER retirement" do
      entry = register!()
      graph = graph_with_service_task(entry.service_id)
      lookup = PinLookup.build()

      # Capture the pin exactly as an INSTANCE_STARTED event would have
      # recorded it, BEFORE any retire happens.
      assert {:ok, pins_before_retire, _schema} =
               PinResolver.resolve(graph, definition_stub(), lookup, [])

      pin_before_retire = catalog_entry_pin!(pins_before_retire)

      assert pin_before_retire.source == :resolved
      assert pin_before_retire.resolved_id == entry.version_id
      assert pin_before_retire.version == "1"

      assert {:ok, retired} = ServiceCatalog.retire(entry.service_id)
      assert retired.status == :RETIRED

      # Side A -- a FRESH resolve/4 call now fails outright. Not a fall-through
      # to any other row (this schema has only ever one live row per
      # service_id, design §3.2's own "Explicit AC4 decision").
      assert {:error, {:unresolved_catalog_ref, ref}} =
               PinResolver.resolve(graph, definition_stub(), lookup, [])

      assert ref == entry.service_id

      # Side B -- pin_for/3 over the pin obtained BEFORE retirement is
      # completely unaffected: pin_for/3 never queries the catalog at all
      # (pure Enum.find/2 over an already-obtained list), so retiring the
      # underlying service_id changes nothing about this read.
      assert {:ok, ^pin_before_retire} =
               PinResolver.pin_for([pin_before_retire], :catalog_entry, entry.service_id)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- publish doesn't disturb an already-resolved pinned_version recorded
  # in a prior INSTANCE_STARTED event.
  # ---------------------------------------------------------------------------------

  describe "REQ-373 AC2: publish/3 does not alter an already-resolved, already-recorded pin" do
    test "resolve a pin via a real Engine.create/2 instance, publish a new version, re-derive the same instance's effective pin set -- unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = register!()

      definition =
        active_definition!(schema_name, graph_human_task_then_service_task(entry.service_id))

      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      started = started_event!(result.instance_id, schema_name)
      pin = catalog_pin(started.payload["pinned_versions"])

      assert pin["ref"] == entry.service_id
      assert pin["version"] == "1"
      assert pin["resolved_id"] == entry.version_id
      assert pin["source"] == "resolved"

      # Publish a new version of the SAME service_id -- per the design's own
      # "Explicit invariant" (§3.1), this touches only service_catalog /
      # service_catalog_versions rows, zero event-store I/O.
      assert {:ok, _updated} =
               ServiceCatalog.publish(entry.service_id, "2", %{
                 endpoint_url: "https://example.test/svc-v2",
                 required_auth: :NONE,
                 timeout_ms: 6_000
               })

      # Re-derive the SAME instance's effective pin set, purely from its own
      # event stream (no catalog read capability exists in this call path at
      # all -- reconstruct_effective_pins/2's own AC7).
      assert {:ok, effective_pins} =
               PinResolver.reconstruct_effective_pins(result.instance_id, prefix: schema_name)

      effective_catalog_pin = Enum.find(effective_pins, &(&1.kind == :catalog_entry))

      assert effective_catalog_pin.ref == entry.service_id
      # Still "1" and the ORIGINAL resolved_id -- the publish above changed the
      # live catalog row to version "2", but this instance's own recorded pin
      # never moved.
      assert effective_catalog_pin.version == "1"
      assert effective_catalog_pin.resolved_id == entry.version_id
      assert effective_catalog_pin.source == :resolved
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- Engine.create/2's pin_lookup/2 is wired to the real, catalog-backed
  # Lookup in place of PinResolver.default_lookup/0. Integration test, NO
  # caller-supplied pin_lookup override -- exercises the real call site
  # (lib/letflow/engine.ex's pin_lookup/2 private function) directly.
  # ---------------------------------------------------------------------------------

  describe "REQ-373 AC5: Engine.create/2 uses the real catalog-backed Lookup by default (no pin_lookup override)" do
    test "a real instance referencing a registered ACTIVE service_id records a :resolved pin -- not an :unresolved_catalog_ref failure" do
      %{schema_name: schema_name} = provisioned_tenant()
      entry = register!()

      definition =
        active_definition!(schema_name, graph_human_task_then_service_task(entry.service_id))

      # Deliberately NO :pin_lookup key in attrs -- this is exactly the
      # fallback Map.get(attrs, :pin_lookup, PinLookup.build()) call site the
      # design changed. Before this wiring, ANY registered service_id would
      # still fail with {:error, {:unresolved_catalog_ref, ref}}, since
      # PinResolver.default_lookup/0's catalog_lookup never reads any table at
      # all -- see PinResolverTest's own coverage of that stub.
      assert {:ok, result} = Engine.create(base_attrs(definition), prefix: schema_name)

      assert result.status == :active
      assert result.current_nodes == ["task"]

      started = started_event!(result.instance_id, schema_name)
      pin = catalog_pin(started.payload["pinned_versions"])

      refute is_nil(pin)
      assert pin["ref"] == entry.service_id
      assert pin["source"] == "resolved"
      assert pin["resolved_id"] == entry.version_id
      assert pin["version"] == entry.version
    end

    test "the identical service_id, unregistered, still fails with {:error, {:unresolved_catalog_ref, ref}} -- the real Lookup behaves like the stub for a genuinely-missing reference" do
      %{schema_name: schema_name} = provisioned_tenant()
      unregistered_service_id = unique_service_id("req373-unregistered")

      definition =
        active_definition!(
          schema_name,
          graph_human_task_then_service_task(unregistered_service_id)
        )

      assert {:error, {:unresolved_catalog_ref, ^unregistered_service_id}} =
               Engine.create(base_attrs(definition), prefix: schema_name)
    end
  end
end
