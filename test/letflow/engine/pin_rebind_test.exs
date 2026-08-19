defmodule Letflow.Engine.PinRebindTest do
  @moduledoc """
  Tests for REQ-060's `Letflow.Engine.PinRebind.rebind_pins/3` (PIN-05 — explicit
  instance pin rebind). See `test/specs/REQ-060.md` for the full test-case rationale
  and AC traceability.

  Uses `Letflow.DataCase` (real Postgres), Sandbox `:auto`, `async: false` -- mirrors
  `engine_cancel_instance_test.exs`'s/`engine_execution_error_test.exs`'s own
  `provisioned_tenant/0` pattern exactly. Self-contained: does not share fixtures with
  any other test file.

  Registers `"INSTANCE_PINS_REBOUND"` itself (ISS-0071/GH#257 -- no production code
  path registers it yet, same pre-existing gap `"TASK_COMPLETED"`/`"INSTANCE_CANCELLED"`
  already have), plus `"INSTANCE_CANCELLED"` and `"EXECUTION_ERROR"` (needed for the
  AC3 CANCELLED/ERROR terminal-status fixtures below).

  Every fixture rebinds the `:variable_schema` pin (the one kind every instance
  carries unconditionally, PIN-02 AC4) rather than `:catalog_entry`/`:module`, because
  `Letflow.Definitions.Graph` has no dispatchable `SERVICE_TASK`/`SUB_PROCESS`
  implementation yet -- see `test/specs/REQ-060.md`'s "Pin fixture strategy" section
  for the full reasoning (mirrors `engine_test.exs:1006-1020`'s own documented gap).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.PinRebind
  alias Letflow.Engine.PinResolver
  alias Letflow.Engine.Reconstruction
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.EventStore.Registry
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req060"),
        display_name: "REQ-060 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  defp register_event_type!(name, tenant_id) do
    assert {:ok, _event_type} =
             Registry.register_type(
               %{
                 "name" => name,
                 "schema_version" => 1,
                 "json_schema" => %{"type" => "object"},
                 "description" => "REQ-060 test fixture -- permissive schema"
               },
               tenant_id
             )

    :ok
  end

  defp provisioned_tenant do
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

    :ok = register_event_type!("INSTANCE_PINS_REBOUND", tenant.id)
    :ok = register_event_type!("INSTANCE_CANCELLED", tenant.id)
    :ok = register_event_type!("EXECUTION_ERROR", tenant.id)

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp unique_name(prefix \\ "req060-def") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp unique_idempotency_key(prefix) do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  # START -> HUMAN_TASK -> END. The instance stays :active with one open task --
  # every AC1/AC2/AC4/AC5/AC6 fixture below rebinds against this shape.
  defp graph_start_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "task", "node_type" => "HUMAN_TASK", "attributes" => %{"role" => "approver"}},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  # START -> END directly -- completes inside Engine.create/2 itself (AC3 COMPLETED
  # fixture), mirrors engine_test.exs:407-423's own fixture.
  defp graph_start_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_definition_attrs(graph) do
    %{
      name: unique_name(),
      version: "1.0.0",
      graph: graph,
      created_by: Ecto.UUID.generate()
    }
  end

  defp active_definition!(schema_name, graph) do
    assert {:ok, definition} =
             Definitions.create(create_definition_attrs(graph), prefix: schema_name)

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # Pins the instance's variable_schema entry to a known, deterministic starting
  # version ("v1") via pin_overrides -- mirrors engine_test.exs's own REQ-059 AC6
  # fixture shape (parent_attrs's pin_overrides).
  defp start_instance!(schema_name, definition, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          definition_id: definition.id,
          initial_variables: %{},
          actor_id: Ecto.UUID.generate(),
          idempotency_key: unique_idempotency_key("req060-start"),
          pin_overrides: [
            %{kind: :variable_schema, ref: definition.name, resolved_id: nil, version: "v1"}
          ]
        },
        overrides
      )

    assert {:ok, result} = Engine.create(attrs, prefix: schema_name)
    result
  end

  defp rebind_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        entries: [],
        reason: "REQ-060 test rebind",
        actor_id: Ecto.UUID.generate(),
        idempotency_key: unique_idempotency_key("req060-rebind")
      },
      overrides
    )
  end

  defp read_events(schema_name, instance_id) do
    assert {:ok, events} = Reconstruction.read_full_log(instance_id, schema_name, 1)
    events
  end

  defp pins_rebound_events(schema_name, instance_id) do
    schema_name
    |> read_events(instance_id)
    |> Enum.filter(&(&1.event_type == "INSTANCE_PINS_REBOUND"))
  end

  # ---------------------------------------------------------------------------------
  # AC1 -- exactly one event, correct payload shape, no-op entries omitted
  # ---------------------------------------------------------------------------------

  describe "AC1 -- a valid rebind appends exactly one INSTANCE_PINS_REBOUND event" do
    test "a single changed entry appends one event with entries/actor/reason, matching the returned changed list" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      actor_id = Ecto.UUID.generate()

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}],
          reason: "quarterly schema bump",
          actor_id: actor_id
        })

      assert {:ok, result} = PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)

      assert result.changed == [
               %{
                 kind: :variable_schema,
                 ref: definition.name,
                 prior_version: "v1",
                 new_version: "v2"
               }
             ]

      assert [event] = pins_rebound_events(schema_name, instance.instance_id)

      expected_ref = definition.name
      expected_actor = actor_id

      assert %{
               "entries" => [
                 %{
                   "kind" => "variable_schema",
                   "ref" => ^expected_ref,
                   "prior_version" => "v1",
                   "new_version" => "v2"
                 }
               ],
               "actor" => ^expected_actor,
               "reason" => "quarterly schema bump"
             } = event.payload
    end

    test "an entry whose requested version already matches contributes no payload entry, but one event still commits" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v1"}]
        })

      assert {:ok, %{changed: []}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)

      assert [event] = pins_rebound_events(schema_name, instance.instance_id)
      assert event.payload["entries"] == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- UnknownPinRef rejects the WHOLE request, zero writes
  # ---------------------------------------------------------------------------------

  describe "AC2 -- UnknownPinRef applies NONE of the entries, even individually-valid ones" do
    test "a valid entry ordered before an unknown ref: whole request rejected, effective pin set unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      attrs =
        rebind_attrs(%{
          entries: [
            %{kind: :variable_schema, ref: definition.name, version: "v2"},
            %{kind: :catalog_entry, ref: "does-not-exist", version: "9.9.9"}
          ]
        })

      assert {:error, {:unknown_pin_ref, :catalog_entry, "does-not-exist"}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)

      assert {:ok, effective_pins} =
               PinResolver.reconstruct_effective_pins(instance.instance_id, prefix: schema_name)

      expected_ref = definition.name

      assert [%{kind: :variable_schema, ref: ^expected_ref, version: "v1"}] = effective_pins

      assert pins_rebound_events(schema_name, instance.instance_id) == []
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- InstanceNotRebindable, all three terminal statuses tested individually
  # ---------------------------------------------------------------------------------

  describe "AC3 -- InstanceNotRebindable for COMPLETED, CANCELLED and ERROR" do
    test "COMPLETED instance rejects rebind" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_end())
      instance = start_instance!(schema_name, definition)

      assert Repo.get!(InstanceProjection, instance.instance_id, prefix: schema_name).status ==
               :completed

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}]
        })

      assert {:error, {:instance_not_rebindable, :completed}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "CANCELLED instance rejects rebind" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      assert {:ok, _cancel_result} =
               Engine.cancel_instance(
                 instance.instance_id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: unique_idempotency_key("req060-cancel")},
                 prefix: schema_name
               )

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}]
        })

      assert {:error, {:instance_not_rebindable, :cancelled}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "ERROR instance rejects rebind" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      assert {:ok, _error_result} =
               Engine.set_instance_error(
                 %{
                   instance_id: instance.instance_id,
                   error_type: :variable_schema_rejected,
                   affected: {:field, "amount"},
                   reason: "REQ-060 fixture: force ERROR status",
                   variables: %{},
                   actor_id: Ecto.UUID.generate(),
                   idempotency_key: unique_idempotency_key("req060-error")
                 },
                 prefix: schema_name
               )

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}]
        })

      assert {:error, {:instance_not_rebindable, :error}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- missing/empty reason, empty entries list, malformed entry: distinct errors
  # ---------------------------------------------------------------------------------

  describe "AC4 -- invalid-input errors are distinct" do
    setup do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)
      %{schema_name: schema_name, definition: definition, instance: instance}
    end

    test "missing :reason key", %{schema_name: schema_name, instance: instance} do
      attrs =
        rebind_attrs(%{entries: [%{kind: :variable_schema, ref: "x", version: "v2"}]})
        |> Map.delete(:reason)

      assert {:error, :invalid_reason} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "empty/whitespace-only reason", %{schema_name: schema_name, instance: instance} do
      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: "x", version: "v2"}],
          reason: "   "
        })

      assert {:error, :invalid_reason} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "missing :entries key", %{schema_name: schema_name, instance: instance} do
      attrs = rebind_attrs() |> Map.delete(:entries)

      assert {:error, :empty_entries} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "empty entries list", %{schema_name: schema_name, instance: instance} do
      attrs = rebind_attrs(%{entries: []})

      assert {:error, :empty_entries} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "malformed entry -- missing :version key", %{schema_name: schema_name, instance: instance} do
      attrs = rebind_attrs(%{entries: [%{kind: :variable_schema, ref: "x"}]})

      assert {:error, {:malformed_entry, 0, :missing_or_unexpected_keys}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end

    test "malformed entry -- invalid :kind value, a distinctly-shaped malformed_entry reason", %{
      schema_name: schema_name,
      instance: instance
    } do
      attrs =
        rebind_attrs(%{entries: [%{kind: "bogus", ref: "x", version: "v2"}]})

      assert {:error, {:malformed_entry, 0, {:invalid_kind, "bogus"}}} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC5 -- post-rebind effective pin set, and reconstruction from the event log alone
  # ---------------------------------------------------------------------------------

  describe "AC5 -- effective pin set reflects new versions; reconstruction derives it from the log alone" do
    test "reconstruct_effective_pins/2 shows the new version after a successful rebind" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}]
        })

      assert {:ok, _result} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)

      assert {:ok, [pin]} =
               PinResolver.reconstruct_effective_pins(instance.instance_id, prefix: schema_name)

      assert pin.kind == :variable_schema
      assert pin.ref == definition.name
      assert pin.version == "v2"
    end

    test "the same effective set is independently reproducible from INSTANCE_STARTED + INSTANCE_PINS_REBOUND alone" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}]
        })

      assert {:ok, _result} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)

      events = read_events(schema_name, instance.instance_id)

      started_payload =
        events
        |> Enum.find(&(&1.event_type == "INSTANCE_STARTED"))
        |> Map.fetch!(:payload)

      pins_rebound =
        events
        |> Enum.filter(&(&1.event_type == "INSTANCE_PINS_REBOUND"))
        |> Enum.map(&%{event_id: &1.event_id, payload: &1.payload})

      hand_merged =
        PinResolver.merge_effective_pins(started_payload["pinned_versions"], pins_rebound)

      assert {:ok, via_reconstruct} =
               PinResolver.reconstruct_effective_pins(instance.instance_id, prefix: schema_name)

      assert hand_merged == via_reconstruct
    end

    test "rebind_attrs() accepts no catalog/module lookup -- inspection, the structural half of \"zero catalog reads\"" do
      # PinRebind.rebind_pins/3's own @type rebind_attrs() (pin_rebind.ex) is exactly
      # %{entries, reason, actor_id, idempotency_key} -- unlike Engine.create/2's own
      # attrs[:pin_lookup], there is no lookup field a caller could even supply, so
      # rebind_pins/3 structurally cannot issue a catalog/module read: confirmed here
      # by asserting a request carrying an unexpected :pin_lookup key is simply ignored
      # (fetch_required_entry_fields/normalize_and_validate_entries never look at
      # top-level attrs keys beyond :entries/:reason/:actor_id/:idempotency_key), not
      # consulted for anything.
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}],
          pin_lookup: fn _ref ->
            Agent.update(counter, &(&1 + 1))
            {:ok, %{resolved_id: "should-never-be-called", version: "should-never-be-called"}}
          end
        })

      assert {:ok, _result} =
               PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)

      assert Agent.get(counter, & &1) == 0,
             "rebind_pins/3 must never invoke a caller-supplied lookup -- it has no lookup parameter to call"

      Agent.stop(counter)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC6 -- lock contention surfaces as ConcurrentModification; moduledoc naming note
  # ---------------------------------------------------------------------------------

  # A real second Postgres connection holds a plain `FOR UPDATE` lock on the
  # instance_projections row until told to release -- rebind_pins/3's own `FOR UPDATE
  # NOWAIT` must then fail immediately with {:concurrent_modification, id} rather than
  # blocking. Sandbox mode is :auto (provisioned_tenant/0), so this is a genuine
  # two-connection race, not serialized by shared sandbox ownership -- mirrors
  # test/letflow/engine/reconstruction_test.exs's with_locked_projection/3 and
  # test/letflow/engine_execution_error_test.exs's AC5 concurrency shape exactly.
  defp with_locked_projection(schema_name, instance_id, fun) do
    test_pid = self()

    holder =
      Elixir.Task.async(fn ->
        Repo.transaction(fn ->
          query =
            InstanceProjection
            |> where([p], p.instance_id == ^instance_id)
            |> lock("FOR UPDATE")

          _locked = Repo.one(query, prefix: schema_name)
          send(test_pid, :locked)

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end)
      end)

    receive do
      :locked -> :ok
    after
      5_000 -> flunk("lock holder task never acquired the row lock")
    end

    result = fun.()

    send(holder.pid, :release)
    Elixir.Task.await(holder, 5_000)

    result
  end

  describe "AC6 -- lock contention surfaces as ConcurrentModification, never blocks" do
    test "a concurrent FOR UPDATE holder causes {:error, {:concurrent_modification, id}}, returned promptly, row unchanged" do
      %{schema_name: schema_name} = provisioned_tenant()
      definition = active_definition!(schema_name, graph_start_human_task_end())
      instance = start_instance!(schema_name, definition)

      row_before = Repo.get!(InstanceProjection, instance.instance_id, prefix: schema_name)

      attrs =
        rebind_attrs(%{
          entries: [%{kind: :variable_schema, ref: definition.name, version: "v2"}]
        })

      {elapsed_us, result} =
        :timer.tc(fn ->
          with_locked_projection(schema_name, instance.instance_id, fn ->
            PinRebind.rebind_pins(instance.instance_id, attrs, prefix: schema_name)
          end)
        end)

      assert {:error, {:concurrent_modification, instance_id}} = result
      assert instance_id == instance.instance_id

      # "rather than blocking": NOWAIT contention must be observed near-instantly, well
      # under the lock holder's own 5s hold budget -- a genuine block (rather than a
      # NOWAIT failure) would take that long or time this test out entirely.
      assert elapsed_us < 2_000_000,
             "rebind_pins/3 took #{elapsed_us}us against a held lock -- looks like it blocked instead of failing NOWAIT"

      row_after = Repo.get!(InstanceProjection, instance.instance_id, prefix: schema_name)
      assert row_before.variables == row_after.variables
      assert row_before.current_nodes == row_after.current_nodes

      assert pins_rebound_events(schema_name, instance.instance_id) == []
    end

    test "moduledoc states ERROR is the terminal status PIN-05's \"FAILED\" text refers to" do
      {:docs_v1, _anno, _lang, _format, %{"en" => moduledoc}, _meta, _docs} =
        Code.fetch_docs(PinRebind)

      doc = String.replace(moduledoc, ~r/\s+/, " ")

      assert doc =~ ~s(PIN-05's own requirement text says "FAILED")
      assert doc =~ "`ERROR` is the status PIN-05's text means"
      assert doc =~ "counts as **terminal for rebind purposes specifically**"
    end
  end
end
