defmodule Letflow.Engine.Lua.PlatformTest do
  @moduledoc """
  Tests for `Letflow.Engine.Lua.Platform` (REQ-152, LUA-14 restated). See
  `test/specs/REQ-152.md` for the full test-case rationale and the acceptance-criteria
  mapping.

  Every script-visible assertion constructs its `Lua.t()` exclusively via
  `Letflow.Engine.Lua.Sandbox.new/0` (never `Lua.new/1` directly, never
  `Letflow.Engine.Lua.Platform.install/1` called by hand) so each assertion exercises
  the real production composition path -- `platform.now` is reachable from a script only
  because `Sandbox.new/1` calls `Platform.install/1` itself.

  The `Application.put_env(:letflow, :lua_platform_time_source, ...)` swap used below
  is reverted in `on_exit` in every test that sets it, so tests remain order-independent
  and never leak a fixed clock into an unrelated test. `async: false` because these
  tests mutate a shared, process-independent piece of state (application env) that
  `Platform.now/0` reads fresh on every call -- running them concurrently with each
  other (or with any other test that happens to call `Platform.now/0` while a swap is
  active) would race.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Engine.Lua.Capabilities
  alias Letflow.Engine.Lua.Platform
  alias Letflow.Engine.Lua.Sandbox
  alias Letflow.EventStore.InstanceProjection
  alias Letflow.Identity.Tenant
  alias Letflow.TenantProvisioning
  alias Letflow.TenantProvisioning.Registration

  defmodule FixedTimeSource do
    @moduledoc false
    @behaviour Platform.TimeSource

    @impl Platform.TimeSource
    def now, do: ~U[2026-01-01 00:00:00.000000Z]
  end

  describe "platform.now() returns an ISO 8601 UTC string parseable by DateTime.from_iso8601/1 (AC4)" do
    test "called from inside a script" do
      {[result], _lua} = Lua.eval!(Sandbox.new(), "return platform.now()")

      assert is_binary(result)
      assert {:ok, %DateTime{} = dt, 0} = DateTime.from_iso8601(result)
      assert dt.time_zone == "Etc/UTC"
    end

    test "Platform.now/0 called directly also returns a DateTime.from_iso8601/1-parseable string" do
      result = Platform.now()

      assert is_binary(result)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(result)
    end
  end

  describe "the time source is injectable -- exact pre-set timestamp, not merely well-formed (AC5)" do
    setup do
      previous = Application.get_env(:letflow, :lua_platform_time_source)
      Application.put_env(:letflow, :lua_platform_time_source, FixedTimeSource)

      on_exit(fn ->
        if previous do
          Application.put_env(:letflow, :lua_platform_time_source, previous)
        else
          Application.delete_env(:letflow, :lua_platform_time_source)
        end
      end)

      :ok
    end

    test "Platform.now/0 returns the exact fixed timestamp, not a merely well-formed one" do
      expected = DateTime.to_iso8601(~U[2026-01-01 00:00:00.000000Z])

      assert Platform.now() == expected
    end

    test "platform.now() called from inside a script also returns the exact fixed timestamp" do
      expected = DateTime.to_iso8601(~U[2026-01-01 00:00:00.000000Z])

      {[result], _lua} = Lua.eval!(Sandbox.new(), "return platform.now()")

      assert result == expected
    end

    test "swapping the fixed source back out restores real, non-fixed values" do
      fixed = Platform.now()

      Application.put_env(:letflow, :lua_platform_time_source, Platform.SystemClock)

      real = Platform.now()

      refute real == fixed
    end
  end

  describe "moduledoc content (AC7)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "states platform.now is ungated by design, not an omission", %{moduledoc: text} do
      assert text =~ "ungated by design"
      assert text =~ "not an omission"
    end

    test "states no capability check, gate, or permission lookup exists in now's call path", %{
      moduledoc: text
    } do
      assert text =~ "no capability"
      assert text =~ "gate"
    end

    test "states a future requirement adding a capability gate to platform.now by symmetry is wrong",
         %{moduledoc: text} do
      assert text =~ "REQ-157"
      assert text =~ "symmetry"
    end

    test "states the injection mechanism -- behaviour + application-env resolution", %{
      moduledoc: text
    } do
      assert text =~ "TimeSource"
      assert text =~ "application env"
    end

    test "states install/1's composition point -- Sandbox.new calls it", %{moduledoc: text} do
      assert text =~ "Sandbox.new"
      assert text =~ "install"
    end
  end

  describe "REQ-157: closed-set enumeration (AC1)" do
    test "a script enumerates exactly the 8 platform.* names via pairs(platform), no more, no fewer" do
      script = """
      local names = {}
      for k, _v in pairs(platform) do
        table.insert(names, k)
      end
      table.sort(names)
      return table.concat(names, ",")
      """

      {[result], _lua} = Lua.eval!(Sandbox.new(), script)

      expected =
        ~w(call_service emit_event fail get_instance_state log now read_variable write_variable)
        |> Enum.sort()
        |> Enum.join(",")

      assert result == expected
    end

    test "platform.ex's source contains exactly one Lua.set!(_, [:platform, occurrence (the single fold)" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      # Matches only an actual call-site pattern (`Lua.set!(<accumulator>, [:platform,`),
      # not the moduledoc/comment prose describing the invariant in words -- guards
      # against a future hand-added 9th `Lua.set!` call bypassing the matrix fold,
      # regardless of what the fold's own accumulator variable happens to be named.
      occurrences =
        ~r/Lua\.set!\([a-z_]+,\s*\[:platform,/
        |> Regex.scan(source)
        |> length()

      assert occurrences == 1
    end
  end

  describe "REQ-157: per-function capability-denial tests, empty grant set (AC2)" do
    setup do
      lua = Platform.install(Sandbox.new(), Capabilities.new())
      %{lua: lua}
    end

    # Each case below asserts not merely "some Lua.RuntimeException was raised" but that
    # the raised exception's `capability_required` field is present and matches the exact
    # capability the row's own matrix entry names. This distinguishes a genuine capability
    # DENIAL from that function's own "not yet implemented" stub raise (which never carries
    # a `capability_required` field, per `run_stub(:not_yet_implemented, ...)`). Without
    # this distinction, a bug that skipped `Capabilities.check!/3` entirely for one row
    # (the stub still raises "not implemented" either way, granted or not) would pass a
    # bare `assert_raise Lua.RuntimeException` unnoticed -- confirmed by mutation-testing
    # the shipped code: temporarily short-circuiting the `check!/3` call for
    # `write_variable` left every test in this file passing until this field assertion
    # was added.
    test "platform.read_variable(...) raises a capability denial for variable:read", %{
      lua: lua
    } do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.write_variable(...) raises a capability denial for variable:write", %{
      lua: lua
    } do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.write_variable('x', 'y')")
        end

      assert exception.original[:function] == :write_variable
      assert exception.original[:capability_required] == "variable:write"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.log(...) raises a capability denial for audit:log", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.log('hello')")
        end

      assert exception.original[:function] == :log
      assert exception.original[:capability_required] == "audit:log"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.emit_event(...) raises a capability denial for event:emit", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.emit_event('evt')")
        end

      assert exception.original[:function] == :emit_event
      assert exception.original[:capability_required] == "event:emit"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.get_instance_state(...) raises a capability denial for instance:read", %{
      lua: lua
    } do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.get_instance_state()")
        end

      assert exception.original[:function] == :get_instance_state
      assert exception.original[:capability_required] == "instance:read"
      assert exception.original[:capabilities_granted] == []
    end

    test "platform.call_service(\"any-service\") raises a capability denial for service:call:any-service",
         %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('any-service')")
        end

      assert exception.original[:function] == :call_service
      assert exception.original[:capability_required] == "service:call:any-service"
      assert exception.original[:capabilities_granted] == []
    end
  end

  describe "REQ-157: structured denial fields (AC3)" do
    test "rescuing read_variable's denial exposes function, required, and granted" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
      assert exception.original[:capabilities_granted] == []
    end
  end

  describe "REQ-157: call_service denial without any grant (AC4)" do
    test "platform.call_service(\"billing\") without a service:call:billing grant raises with the exact required capability" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('billing')")
        end

      assert exception.original[:capability_required] == "service:call:billing"
    end
  end

  describe "REQ-157: call_service grant is parameterised, not blanket (AC5)" do
    setup do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["service:call:alpha"]))
      %{lua: lua}
    end

    test "a service:call:alpha grant lets platform.call_service('alpha') pass the gate (reaches the stub's own raise)",
         %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('alpha')")
        end

      # Passed the gate: this is the stub's "not yet implemented" raise, not a capability
      # denial -- no capability_required field on this exception.
      assert exception.original[:capability_required] == nil
      assert exception.original[:stub] == true
    end

    test "the same grant does NOT authorise platform.call_service('beta')", %{lua: lua} do
      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.call_service('beta')")
        end

      assert exception.original[:capability_required] == "service:call:beta"
      assert exception.original[:capabilities_granted] == ["service:call:alpha"]
    end
  end

  describe "REQ-157: now and fail are callable with an empty capability set (AC6)" do
    test "platform.now() returns its normal value with no raise at all" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      {[result], _lua} = Lua.eval!(lua, "return platform.now()")

      assert is_binary(result)
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(result)
    end

    test "platform.fail() raises the stub's own explicit-failure error, not a capability denial" do
      lua = Platform.install(Sandbox.new(), Capabilities.new())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.fail()")
        end

      assert exception.original[:reason] == :explicit_fail
      assert exception.original[:capability_required] == nil
    end
  end

  describe "REQ-157: moduledoc content (AC7)" do
    setup do
      {:docs_v1, _anno, _lang, _fmt, moduledoc, _meta, _docs} =
        Code.fetch_docs(Letflow.Engine.Lua.Platform)

      %{"en" => text} = moduledoc
      %{moduledoc: text}
    end

    test "reproduces the 8-row capability matrix in substance", %{moduledoc: text} do
      for name <-
            ~w(call_service read_variable write_variable log emit_event get_instance_state now fail) do
        assert text =~ name
      end

      assert text =~ "service:call:"
      assert text =~ "variable:read"
      assert text =~ "variable:write"
      assert text =~ "audit:log"
      assert text =~ "event:emit"
      assert text =~ "instance:read"
    end

    test "states the now/fail ungated rationale", %{moduledoc: text} do
      assert text =~ "pure time read with no state reach"
      assert text =~ "may always terminate itself"
    end

    test "carries the binding statement guarding against a future gate on now or fail", %{
      moduledoc: text
    } do
      assert text =~ "A test that expects a gate on `now` or `fail` is reading the matrix wrong"
    end
  end

  # =====================================================================================
  # REQ-159 -- lib/letflow/design/req159-lua-host-api-read.md
  # =====================================================================================

  # ---------------------------------------------------------------------------------
  # Fixtures -- mirrors test/letflow/event_store_test.exs's provisioned_tenant/1 and
  # seed_projection!/4 exactly (same real-Postgres-tenant-schema idiom), trimmed to what
  # this file's REQ-159 tests need.
  # ---------------------------------------------------------------------------------

  defp insert_tenant! do
    %Tenant{}
    |> Tenant.create_changeset(
      %{
        slug: Letflow.TenantSlugFixture.unique_slug("req159"),
        display_name: "REQ-159 Test Tenant"
      },
      :disabled
    )
    |> Repo.insert!()
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
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

    %{tenant_id: tenant.id, schema_name: schema_name}
  end

  defp seed_projection!(schema_name, instance_id, attrs \\ %{}) do
    %InstanceProjection{}
    |> InstanceProjection.insert_changeset(
      Map.merge(
        %{
          instance_id: instance_id,
          status: :active,
          last_event_seq: 0,
          definition_id: Ecto.UUID.generate(),
          variables: %{}
        },
        attrs
      )
    )
    |> Repo.insert!(prefix: schema_name)
  end

  defp execution_context(overrides \\ %{}) do
    Map.merge(Platform.empty_execution_context(), overrides)
  end

  # ---------------------------------------------------------------------------------
  # platform.read_variable -- current value or nil (AC1), number-marshalling round trip
  # (AC6), malformed argument, capability denial (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-159: platform.read_variable" do
    test "returns the current value for a set variable" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"greeting" => "hello"}})
        )

      assert {["hello"], _lua} = Lua.eval!(lua, "return platform.read_variable('greeting')")
    end

    test "returns nil for an unset variable" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"greeting" => "hello"}})
        )

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.read_variable('missing')")
    end

    test "returns nil for a malformed (non-string) argument, rather than raising" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"x" => 1}})
        )

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.read_variable(42)")
    end

    test "round-trips an integer AND a float, proving LuaNumberMarshalling.to_lua/1 is genuinely applied (AC6)" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:read"]),
          execution_context(%{variables: %{"int_var" => 3, "float_var" => 3.0}})
        )

      script = """
      local int_val = platform.read_variable('int_var')
      local float_val = platform.read_variable('float_var')
      return math.type(int_val), math.type(float_val), int_val, float_val
      """

      assert {["integer", "float", 3, 3.0], _lua} = Lua.eval!(lua, script)
    end

    test "capability denial for variable:read (AC4)" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:function] == :read_variable
      assert exception.original[:capability_required] == "variable:read"
    end

    test "capability denial happens even when a real execution context is supplied" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(),
          execution_context(%{variables: %{"x" => 1}})
        )

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.read_variable('x')")
        end

      assert exception.original[:capability_required] == "variable:read"
    end
  end

  # ---------------------------------------------------------------------------------
  # platform.get_instance_state -- valid self instance (AC3), structured errors (AC3),
  # the self-instance-only security proof, capability denial (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-159: platform.get_instance_state -- valid instance, scoped to self" do
    setup do
      %{tenant_id: _tenant_id, schema_name: schema_name} = provisioned_tenant()
      instance_id = Ecto.UUID.generate()

      seed_projection!(schema_name, instance_id, %{
        status: :active,
        variables: %{"count" => 1, "ratio" => 2.5}
      })

      %{schema_name: schema_name, instance_id: instance_id}
    end

    test "returns state for the script's own valid instance", %{
      schema_name: schema_name,
      instance_id: instance_id
    } do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: instance_id, prefix: schema_name})
        )

      script = """
      local state = platform.get_instance_state('#{instance_id}')
      return state.status, math.type(state.variables.count), state.variables.count,
             math.type(state.variables.ratio), state.variables.ratio
      """

      assert {["ACTIVE", "integer", 1, "float", 2.5], _lua} = Lua.eval!(lua, script)
    end
  end

  describe "REQ-159: platform.get_instance_state -- structured errors, never a raise" do
    test "non-UUID-shaped argument returns {nil, reason: invalid_id}, even with a valid own instance_id set" do
      own_id = Ecto.UUID.generate()

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: "irrelevant_schema"})
        )

      script = """
      local state, err = platform.get_instance_state('not-a-uuid')
      return state, err.reason
      """

      assert {[nil, "invalid_id"], _lua} = Lua.eval!(lua, script)
    end

    test "empty-context sentinel (prefix == nil) returns {nil, reason: no_execution_context}, no Repo call attempted" do
      lua =
        Platform.install(Sandbox.new(), Capabilities.new(["instance:read"]), execution_context())

      script = """
      local state, err = platform.get_instance_state('#{Ecto.UUID.generate()}')
      return state, err.reason
      """

      assert {[nil, "no_execution_context"], _lua} = Lua.eval!(lua, script)
    end

    test "own instance_id with no corresponding row returns {nil, reason: not_found}" do
      %{schema_name: schema_name} = provisioned_tenant()
      own_id = Ecto.UUID.generate()

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: schema_name})
        )

      script = """
      local state, err = platform.get_instance_state('#{own_id}')
      return state, err.reason
      """

      assert {[nil, "not_found"], _lua} = Lua.eval!(lua, script)
    end

    test "a real same-tenant sibling instance AND a nonexistent instance id both return the IDENTICAL forbidden result" do
      %{schema_name: schema_name} = provisioned_tenant()
      own_id = Ecto.UUID.generate()
      sibling_id = Ecto.UUID.generate()
      nonexistent_id = Ecto.UUID.generate()

      seed_projection!(schema_name, own_id)
      seed_projection!(schema_name, sibling_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: schema_name})
        )

      script = fn target_id ->
        """
        local state, err = platform.get_instance_state('#{target_id}')
        return state, err.reason
        """
      end

      sibling_result = Lua.eval!(lua, script.(sibling_id))
      nonexistent_result = Lua.eval!(lua, script.(nonexistent_id))

      assert {[nil, "forbidden"], _lua} = sibling_result
      assert {[nil, "forbidden"], _lua} = nonexistent_result

      # The key security proof: identical outcome for a real sibling vs. a fabricated
      # id -- a script cannot use this response to probe which other ids exist.
      {sibling_values, _} = sibling_result
      {nonexistent_values, _} = nonexistent_result
      assert sibling_values == nonexistent_values
    end

    # Mutation-testing finding (TEST-DESIGNER, REQ-159 Step 3): the design and moduledoc
    # both state "forbidden" is returned with NO `Repo` call attempted at all -- but
    # every test above only asserts the RETURN VALUE. A mutation that runs
    # `fetch_instance_state/3` (i.e. calls `Repo.get/3`) UNCONDITIONALLY and only
    # afterward substitutes the "forbidden" error for a non-matching id produces the
    # exact same return values on every test above and is caught by none of them --
    # confirmed directly: reordering `do_get_instance_state/3`'s self-instance equality
    # check to run after `fetch_instance_state/3` rather than before it left all
    # pre-existing tests in this file passing (56/56). This test closes that gap by
    # asserting, via `:telemetry`, that the `[:letflow, :repo, :query]` event never
    # fires for a same-tenant-sibling id -- the same telemetry-counter idiom
    # `test/letflow/api/context_test.exs` already uses to prove a `Repo` call did or
    # did not happen.
    test "no Repo.get/3 (no [:letflow, :repo, :query] telemetry event) fires for a same-tenant sibling id" do
      %{schema_name: schema_name} = provisioned_tenant()
      own_id = Ecto.UUID.generate()
      sibling_id = Ecto.UUID.generate()

      seed_projection!(schema_name, own_id)
      seed_projection!(schema_name, sibling_id)

      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["instance:read"]),
          execution_context(%{instance_id: own_id, prefix: schema_name})
        )

      handler_id = {__MODULE__, :get_instance_state_query_counter, make_ref()}
      counter = :counters.new(1, [])

      :telemetry.attach(
        handler_id,
        [:letflow, :repo, :query],
        fn _event, _measurements, _metadata, _config -> :counters.add(counter, 1, 1) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      script = """
      local state, err = platform.get_instance_state('#{sibling_id}')
      return state, err.reason
      """

      assert {[nil, "forbidden"], _lua} = Lua.eval!(lua, script)

      assert :counters.get(counter, 1) == 0
    end
  end

  describe "REQ-159: platform.get_instance_state -- capability denial (AC4)" do
    test "raises a capability denial for instance:read" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.get_instance_state('#{Ecto.UUID.generate()}')")
        end

      assert exception.original[:function] == :get_instance_state
      assert exception.original[:capability_required] == "instance:read"
    end
  end

  # ---------------------------------------------------------------------------------
  # platform.log -- structured entry with correlation IDs (AC2), level mapping, never
  # raises, capability denial (AC4)
  # ---------------------------------------------------------------------------------

  describe "REQ-159: platform.log -- structured entry with correlation IDs" do
    setup do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["audit:log"]),
          execution_context(%{
            script_identity: "req159-script-abc",
            instance_id: "req159-instance-xyz",
            trace_id: "req159-trace-123"
          })
        )

      %{lua: lua}
    end

    test "emits an entry with all three correlation fields, asserted individually, plus the message text",
         %{lua: lua} do
      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            Lua.eval!(lua, "return platform.log('info', 'a message', nil)")
          end
        )

      assert log =~ "script_identity=req159-script-abc"
      assert log =~ "instance_id=req159-instance-xyz"
      assert log =~ "trace_id=req159-trace-123"
      assert log =~ "a message"
    end

    test "a table context argument is present on the emitted entry's metadata, not silently dropped",
         %{lua: lua} do
      # Elixir's default `Logger` text formatter only knows how to render
      # binary/integer/float/pid/atom/ref/port metadata values (confirmed directly
      # against `logger/formatter.ex:494-536`) -- a map value like `context` is silently
      # omitted from the *formatted text*, even though it IS present on the raw log
      # event's metadata. A raw `:logger` handler (below) asserts against that raw
      # metadata directly, rather than against the lossy formatted string.
      %{context: context} =
        capture_raw_log_meta(fn ->
          Lua.eval!(lua, "return platform.log('info', 'ctx message', {reason = 'test'})")
        end)

      # `Lua.decode!/2` decodes a table into a proplist (`[{key, value}]`), not a map --
      # see `Lua.decode_list!/2`'s own doctest (`deps/lua/lib/lua.ex:1057-1064`).
      assert context == [{"reason", "test"}]
    end
  end

  # Adds a temporary raw `:logger` handler for the duration of `fun`, returning the
  # metadata map of the first log event it observes. Used only where the default
  # `Logger` text formatter would lossily drop a non-scalar metadata value (see above) --
  # every other assertion in this file uses `ExUnit.CaptureLog` against the formatted
  # text, which is sufficient for every scalar (string) correlation field.
  defp capture_raw_log_meta(fun) do
    ref = make_ref()
    parent = self()
    handler_id = :"platform_test_raw_log_#{System.unique_integer([:positive])}"

    :logger.add_handler(handler_id, Letflow.Engine.Lua.PlatformTest.RawLogCapture, %{
      config: %{parent: parent, ref: ref}
    })

    try do
      fun.()
    after
      :logger.remove_handler(handler_id)
    end

    receive do
      {^ref, meta} -> meta
    after
      1_000 -> flunk("no log event captured by the raw :logger handler")
    end
  end

  defmodule RawLogCapture do
    @moduledoc false
    def log(%{meta: meta}, %{config: %{parent: parent, ref: ref}}) do
      send(parent, {ref, meta})
      :ok
    end
  end

  describe "REQ-159: platform.log -- level mapping and malformed input" do
    setup do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["audit:log"]),
          execution_context(%{script_identity: "s", instance_id: "i", trace_id: "t"})
        )

      %{lua: lua}
    end

    for {lua_level, elixir_level} <- [
          {"debug", "[debug]"},
          {"info", "[info]"},
          {"warn", "[warning]"},
          {"error", "[error]"}
        ] do
      test "'#{lua_level}' maps to Elixir Logger level #{elixir_level}", %{lua: lua} do
        log =
          ExUnit.CaptureLog.capture_log([level: :debug], fn ->
            Lua.eval!(lua, "return platform.log('#{unquote(lua_level)}', 'lvl-msg', nil)")
          end)

        assert log =~ unquote(elixir_level)
      end
    end

    test "an unrecognized level string produces an :info entry tagged with original_level", %{
      lua: lua
    } do
      log =
        ExUnit.CaptureLog.capture_log(
          [level: :debug, metadata: [:original_level]],
          fn ->
            Lua.eval!(lua, "return platform.log('bogus_level', 'weird', nil)")
          end
        )

      assert log =~ "[info]"
      assert log =~ "original_level=bogus_level"
    end

    test "never raises for malformed argument shapes", %{lua: lua} do
      ExUnit.CaptureLog.capture_log(fn ->
        assert {[], _lua} = Lua.eval!(lua, "return platform.log(42, nil)")
        assert {[], _lua} = Lua.eval!(lua, "return platform.log()")
      end)
    end
  end

  describe "REQ-159: platform.log -- capability denial (AC4)" do
    test "raises a capability denial for audit:log" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.log('info', 'x', nil)")
        end

      assert exception.original[:function] == :log
      assert exception.original[:capability_required] == "audit:log"
    end
  end

  # ---------------------------------------------------------------------------------
  # Matrix/stub-tag regression guards
  # ---------------------------------------------------------------------------------

  describe "REQ-159: matrix/stub-tag regression guards" do
    test "required capability strings for the 3 edited rows are unchanged" do
      matrix = Platform.capability_matrix()

      assert Enum.find(matrix, &(&1.name == :read_variable)).required == "variable:read"
      assert Enum.find(matrix, &(&1.name == :get_instance_state)).required == "instance:read"
      assert Enum.find(matrix, &(&1.name == :log)).required == "audit:log"
    end

    test "write_variable, call_service, emit_event still raise the not_yet_implemented stub error" do
      lua =
        Platform.install(
          Sandbox.new(),
          Capabilities.new(["variable:write", "service:call:x", "event:emit"]),
          execution_context()
        )

      for {call, function_name} <- [
            {"platform.write_variable('x', 'y')", :write_variable},
            {"platform.call_service('x')", :call_service},
            {"platform.emit_event('evt')", :emit_event}
          ] do
        exception =
          assert_raise Lua.RuntimeException, fn ->
            Lua.eval!(lua, "return #{call}")
          end

        assert exception.original[:function] == function_name
        assert exception.original[:stub] == true
      end
    end

    test "now and fail remain callable with an empty grant set, unaffected by execution_context" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(), execution_context())

      assert {[result], _lua} = Lua.eval!(lua, "return platform.now()")
      assert is_binary(result)

      exception =
        assert_raise Lua.RuntimeException, fn ->
          Lua.eval!(lua, "return platform.fail()")
        end

      assert exception.original[:reason] == :explicit_fail
    end
  end

  # ---------------------------------------------------------------------------------
  # install/1, install/2 backward compatibility
  # ---------------------------------------------------------------------------------

  describe "REQ-159: install/1, install/2 backward compatibility" do
    test "a granted call to read_variable through install/2 (empty context) returns nil, not a crash" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["variable:read"]))

      assert {[nil], _lua} = Lua.eval!(lua, "return platform.read_variable('x')")
    end

    test "a granted call to get_instance_state through install/2 (empty context) returns the structured no_execution_context error" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["instance:read"]))

      script = """
      local state, err = platform.get_instance_state('#{Ecto.UUID.generate()}')
      return state, err.reason
      """

      assert {[nil, "no_execution_context"], _lua} = Lua.eval!(lua, script)
    end

    test "a granted call to log through install/2 (empty context) still emits an entry with nil correlation fields" do
      lua = Platform.install(Sandbox.new(), Capabilities.new(["audit:log"]))

      log =
        ExUnit.CaptureLog.capture_log(
          [metadata: [:script_identity, :instance_id, :trace_id]],
          fn ->
            assert {[], _lua} = Lua.eval!(lua, "return platform.log('info', 'msg', nil)")
          end
        )

      assert log =~ "msg"
    end

    test "install/1 (production default) exposes all 8 names with an empty execution context, unaffected" do
      lua = Sandbox.new()

      assert {[nil], _lua} =
               Lua.eval!(
                 Platform.install(lua, Capabilities.new(["variable:read"])),
                 "return platform.read_variable('anything')"
               )
    end
  end

  # ---------------------------------------------------------------------------------
  # Structural guard: no Repo call in this diff uses a prefix derived from
  # script-supplied input (REQ-159 AC7) -- mirrors REQ-157's own single-Lua.set!
  # source-level guard.
  # ---------------------------------------------------------------------------------

  describe "REQ-159: structural guard -- Repo.get/3's prefix is always execution_context.prefix" do
    test "platform.ex's only Repo call site passes prefix: execution_context's own prefix, never a script-supplied value" do
      source = File.read!("lib/letflow/engine/lua/platform.ex")

      repo_call_occurrences =
        ~r/Repo\.get\(/
        |> Regex.scan(source)
        |> length()

      assert repo_call_occurrences == 1

      assert source =~ "Repo.get(InstanceProjection, instance_id, prefix: prefix)"

      # `prefix` at that call site is only ever bound from
      # `execution_context.prefix` (fetch_instance_state/3's own parameter, itself
      # only ever called with `execution_context.prefix`) -- never from the Lua
      # call's own argument list (`raw_id`/`instance_id`).
      assert source =~ "fetch_instance_state(instance_id, execution_context.prefix, lua)"
      refute source =~ "prefix: raw_id"
      refute source =~ "prefix: instance_id"
    end
  end
end
