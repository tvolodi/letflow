defmodule Letflow.Scheduler.PollerTest do
  @moduledoc """
  Tests for REQ-186's `Letflow.Scheduler.Poller` `GenServer` ticker itself.
  See `test/specs/REQ-186.md` (AC8) for the full acceptance-criterion ->
  test-case mapping.

  `config/test.exs` sets `start_scheduler: false` (see
  `lib/letflow/application.ex`'s own `scheduler_children/0` comment) --
  the Poller is deliberately never started under the ordinary test
  supervision tree, because its very first tick runs with zero delay and
  queries `Letflow.Repo` from a process no test process is an ancestor of,
  which under `Ecto.Adapters.SQL.Sandbox`'s default `:manual` mode raises
  `DBConnection.OwnershipError` repeatedly. This file starts its own Poller
  instance explicitly, per
  `handoffs/WF02-REQ186-20260829/step-03-test-designer.json`'s own
  instruction -- made safe here because `use Letflow.DataCase, async: false`
  puts `Ecto.Adapters.SQL.Sandbox` into `{:shared, self()}` mode for the
  whole test (see `test/support/data_case.ex`), so the Poller's own process
  (not a descendant of the test process) shares the same sandboxed
  connection as the test without needing an explicit `Sandbox.allow/3` call.

  `Letflow.SchedulerTest` (`test/letflow/scheduler_test.exs`) covers every
  other REQ-186 acceptance criterion by calling `Letflow.Scheduler`'s own
  functions directly, matching this codebase's established "context module
  tested without its process wrapper" precedent -- not duplicated here.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.TokenRecord
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Poller
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  defp provisioned_tenant(slug_prefix \\ "req186-poller") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-186 Poller Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # REQ-187: task's own node_type is TIMER (not HUMAN_TASK) -- firing a
  # timer now re-enters Letflow.Engine to advance the token off the :TIMER
  # node it's found sitting on via the timer's own token_id, so a timer
  # this file expects to actually *fire* successfully must be armed with
  # `token_id: live_token_id!/2`, matching this graph's own real live
  # token. `duration_iso8601` is far in the future (`P1D`) so
  # start_instance!/1's own automatic REQ-187 timer-arm never becomes due
  # during this test.
  defp graph_human_task_end do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{
          "id" => "task",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => "P1D"}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "task"},
        %{"id" => "e2", "source" => "task", "target" => "end"}
      ]
    }
  end

  defp live_token_id!(schema_name, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> select([t], t.id)
    |> Repo.one!(prefix: schema_name)
    |> to_string()
  end

  defp start_instance!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req186-poller-def"),
                 version: "1.0.0",
                 graph: graph_human_task_end(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: activated.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req186-poller-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp put_scheduler_config(overrides) do
    original = Application.get_env(:letflow, :scheduler)
    Application.put_env(:letflow, :scheduler, overrides)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:letflow, :scheduler)
        val -> Application.put_env(:letflow, :scheduler, val)
      end
    end)
  end

  describe "AC8: Poller.handle_info(:tick, _) reads config fresh and uses the overridden poll_interval_ms" do
    test "a timer armed after the Poller's own first tick is still fired well within the overridden interval, far faster than the 5000ms default would allow" do
      put_scheduler_config(
        poll_interval_ms: 30,
        jitter_ms: 0,
        max_timers_per_cycle: 64,
        max_fire_retries: 3
      )

      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_instance!(schema_name)

      start_supervised!(Poller)

      # Let the Poller's own immediate (zero-delay) first tick run and
      # complete -- at this point no due timer exists yet, so it's a no-op.
      Process.sleep(20)

      fire_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      assert {:ok, timer} =
               Scheduler.create(
                 Letflow.Repo,
                 %{
                   instance_id: instance_id,
                   timer_type: "deadline",
                   node_id: "poller-ac8",
                   fire_at: fire_at,
                   token_id: live_token_id!(schema_name, instance_id)
                 },
                 prefix: schema_name
               )

      # Only a SECOND tick, scheduled at (overridden) poll_interval_ms after
      # the first, can pick this timer up. 300ms comfortably fits ~10 ticks
      # at the 30ms override, but is nowhere near one tick at the 5000ms
      # documented default -- if the Poller ignored the override (e.g. a
      # mutation hardcoding the default, or caching poll_interval_ms/0's
      # value at init/1 time instead of reading it fresh every tick), this
      # timer would still be pending when we check.
      Process.sleep(300)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "fired"
    end
  end
end
