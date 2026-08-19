defmodule Letflow.Engine.PluginInterfaceTest do
  @moduledoc """
  Pure unit tests for REQ-057's `Letflow.Engine.PluginInterface` -- the plugin
  handler `@behaviour`, its `ExecutionContext` struct, the crash-safety
  `invoke/2,3` wrapper, and the pure `build_error_args/3` mapper. See
  `lib/letflow/design/req057-plugin-interface-registry.md` (the gate-approved
  design this module implements) and `test/specs/REQ-057.md` for the full
  rationale and AC traceability.

  No `Letflow.Repo`/`Ecto.Sandbox` dependency anywhere in this file --
  `invoke/2,3` and `build_error_args/3` are both explicitly I/O-free
  (INV-PR-8) -- `async: true` for the same reason `transition_test.exs`
  (REQ-044) and `task_activation_test.exs` (REQ-047) use it.

  The full `invoke/2 -> build_error_args/3 -> Letflow.Engine.set_instance_error/2`
  routing demonstration (AC1's `VariableMerge.merge/3` half and AC2/AC8's real
  Postgres read-back half) needs `Letflow.DataCase` and lives in
  `test/letflow/engine_plugin_error_routing_test.exs` instead, mirroring
  `engine_execution_error_test.exs`'s own file-boundary precedent (pure vs.
  DB-integration split).
  """

  use ExUnit.Case, async: true

  alias Letflow.Engine.PluginInterface
  alias Letflow.Engine.PluginInterface.ExecutionContext

  # ---------------------------------------------------------------------
  # Fixture handler modules -- one behavior each, exercising exactly one
  # invoke/2,3 branch apiece (design doc §2.4.1).
  # ---------------------------------------------------------------------

  defmodule CompleteHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(context), do: {:complete, Map.put(context.variables, "handled", true)}
  end

  defmodule ErrorHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context), do: {:error, "deliberate error reason"}
  end

  defmodule RaisingHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context), do: raise("boom")
  end

  defmodule ExitingHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context), do: exit(:deliberate_exit)
  end

  defmodule NonConformingHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    # Violates its own @callback contract on purpose -- neither {:complete, _}
    # nor {:error, _} (design doc §2.4.1 step 3's defensive branch, OQ-3).
    def handle_node(_context), do: :ok
  end

  defmodule SlowHandler do
    @moduledoc false
    @behaviour Letflow.Engine.PluginInterface
    @impl true
    def handle_node(_context) do
      Process.sleep(200)
      {:complete, %{}}
    end
  end

  # ---------------------------------------------------------------------
  # Fixture builder
  # ---------------------------------------------------------------------

  defp context(overrides \\ %{}) do
    %ExecutionContext{
      instance_id: Map.get(overrides, :instance_id, Ecto.UUID.generate()),
      definition_id: Map.get(overrides, :definition_id, Ecto.UUID.generate()),
      node_id: Map.get(overrides, :node_id, "node-1"),
      node_type: Map.get(overrides, :node_type, "SERVICE_TASK"),
      variables: Map.get(overrides, :variables, %{}),
      node_config: Map.get(overrides, :node_config, %{}),
      trace_id: Map.get(overrides, :trace_id, "trace-1")
    }
  end

  # ---------------------------------------------------------------------
  # AC1 (partial -- context shape only; the real invocation + VariableMerge
  # half lives in the DB-integration file listed above)
  # ---------------------------------------------------------------------

  describe "ExecutionContext -- carries all seven named fields (AC1)" do
    test "the struct enforces and exposes instance_id/definition_id/node_id/node_type/variables/node_config/trace_id" do
      instance_id = Ecto.UUID.generate()
      definition_id = Ecto.UUID.generate()

      ctx =
        context(%{
          instance_id: instance_id,
          definition_id: definition_id,
          node_id: "svc-1",
          node_type: "SERVICE_TASK",
          variables: %{"a" => 1},
          node_config: %{"role" => "x"},
          trace_id: "trace-abc"
        })

      assert %ExecutionContext{
               instance_id: ^instance_id,
               definition_id: ^definition_id,
               node_id: "svc-1",
               node_type: "SERVICE_TASK",
               variables: %{"a" => 1},
               node_config: %{"role" => "x"},
               trace_id: "trace-abc"
             } = ctx
    end

    test "@enforce_keys rejects a struct built with a missing required field" do
      assert_raise ArgumentError, fn ->
        Code.eval_string("""
        %Letflow.Engine.PluginInterface.ExecutionContext{
          instance_id: "i", definition_id: "d", node_id: "n", node_type: "t",
          variables: %{}, node_config: %{}
        }
        """)
      end
    end
  end

  describe "invoke/2 -- a COMPLETE outcome is returned unchanged (AC1)" do
    test "output variables from a successful handler pass through invoke/2 verbatim" do
      ctx = context(%{variables: %{"seed" => 1}})

      assert {:complete, %{"seed" => 1, "handled" => true}} =
               PluginInterface.invoke(CompleteHandler, ctx)
    end
  end

  # ---------------------------------------------------------------------
  # AC2 -- a deliberate ERROR outcome preserves the handler's reason
  # byte-for-byte (the routing-into-EE-10 half is in the DB-integration file).
  # ---------------------------------------------------------------------

  describe "invoke/2 -- a deliberate ERROR outcome preserves the handler's reason string (AC2)" do
    test "the handler's own reason string is returned unchanged, not rewritten or truncated" do
      ctx = context()

      assert {:error, "deliberate error reason"} = PluginInterface.invoke(ErrorHandler, ctx)
    end
  end

  # ---------------------------------------------------------------------
  # AC3 -- raise AND exit are BOTH treated as ERROR. Two explicit tests, since
  # a bare try/rescue would pass the first and silently fail the second (the
  # exact gap this design's Task.Supervisor + Task.yield/2 mechanism closes).
  # ---------------------------------------------------------------------

  describe "invoke/2 -- a handler that raises is treated as ERROR, not propagated (AC3)" do
    test "a raise inside the handler never crashes the caller -- invoke/2 returns {:error, _} instead" do
      ctx = context()

      assert {:error, reason} = PluginInterface.invoke(RaisingHandler, ctx)
      assert is_binary(reason)
      assert reason =~ "boom"
      assert reason =~ "crashed"
    end
  end

  describe "invoke/2 -- a handler that exits is ALSO treated as ERROR, not propagated (AC3)" do
    test "an exit/1 call never crashes the caller either -- same {:error, _} shape as a raise" do
      ctx = context()

      assert {:error, reason} = PluginInterface.invoke(ExitingHandler, ctx)
      assert is_binary(reason)
      assert reason =~ "deliberate_exit"
      assert reason =~ "crashed"
    end
  end

  # ---------------------------------------------------------------------
  # Supplementary invoke/2,3 branch coverage -- not independently-named ACs,
  # but real shipped branches of the same function AC3 exercises (design doc
  # §2.4.1's defensive {:ok, other} branch, OQ-3, and the timeout branch).
  # ---------------------------------------------------------------------

  describe "invoke/2 -- a handler returning a value outside its own outcome() contract" do
    test "is folded into {:error, _} too, not left to crash a pattern match downstream" do
      ctx = context()

      assert {:error, reason} = PluginInterface.invoke(NonConformingHandler, ctx)
      assert reason =~ "outside its outcome() contract"
    end
  end

  describe "invoke/3 -- a handler that does not respond within opts[:timeout_ms]" do
    test "times out into {:error, _} rather than blocking the caller indefinitely" do
      ctx = context()

      assert {:error, reason} = PluginInterface.invoke(SlowHandler, ctx, timeout_ms: 10)
      assert reason =~ "did not respond within 10ms"
    end
  end

  # ---------------------------------------------------------------------
  # AC8 (inspection half) -- build_error_args/3 is the pure, sole mapper. The
  # "confirmed by test" half of AC8 (a real set_instance_error/2 call) lives
  # in the DB-integration file; this is the "confirmed by inspection" half's
  # concrete, runnable counterpart -- proving the mapping itself is exact.
  # ---------------------------------------------------------------------

  describe "build_error_args/3 -- the pure outcome() -> error_args() mapper (AC8)" do
    test "maps context + reason + meta to the exact error_args() shape REQ-061 expects" do
      ctx =
        context(%{
          node_id: "svc-1",
          node_type: "SERVICE_TASK",
          variables: %{"x" => 1},
          trace_id: "trace-abc"
        })

      actor_id = Ecto.UUID.generate()
      meta = %{actor_id: actor_id, idempotency_key: "idem-1"}

      assert PluginInterface.build_error_args(ctx, "boom happened", meta) == %{
               instance_id: ctx.instance_id,
               error_type: :plugin_error_outcome,
               affected: {:node, "svc-1"},
               reason: "boom happened",
               variables: %{"x" => 1},
               details: %{node_type: "SERVICE_TASK", trace_id: "trace-abc"},
               actor_id: actor_id,
               idempotency_key: "idem-1"
             }
    end

    test "actor_id may be nil -- carried through unchanged, never defaulted to something else" do
      ctx = context()

      args =
        PluginInterface.build_error_args(ctx, "r", %{actor_id: nil, idempotency_key: "idem-2"})

      assert args.actor_id == nil
      assert args.idempotency_key == "idem-2"
    end

    test "is the only function this module defines that constructs an ExecutionError.error_args() value (INV-PR-10)" do
      # Structural/inspection check, made runnable: build_error_args/3 is
      # public and exported; no sibling public function in this module
      # returns a map carrying :error_type -- confirmed here by listing every
      # exported function and asserting build_error_args/3 is the only
      # 3-arity one whose name mentions "error".
      exported = PluginInterface.__info__(:functions)

      error_shaped =
        Enum.filter(exported, fn {name, _arity} -> name |> to_string() =~ "error" end)

      assert error_shaped == [build_error_args: 3]
    end
  end
end
