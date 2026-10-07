defmodule Letflow.EngineDistinctFromConcurrencyTest do
  @moduledoc """
  REQ-463 case A-8 -- two completions of parallel nodes P1 and P2 by the SAME user, submitted
  concurrently from two real database connections: exactly one commits and the other is
  refused, because the instance-projection row lock serialises the two transactions and the
  second one's check then sees the first one's committed completion (design req459 section 2.5).

  `Letflow.TenantFixture.provisioned_tenant!/1` sets the sandbox to `:auto`, so the two
  `Task.async/1` processes genuinely race on separate connections (no sandbox allowance
  needed, same idiom as `iss0397_join_counters_test.exs`). Run this file with its OWN
  `MIX_TEST_PARTITION` (it mutates shared state across connections), e.g. 15.

  Several rounds, each on a fresh instance of one definition, so a missing lock would have to
  win the race every time to go unnoticed. A control round with two DIFFERENT users shows the
  rule does not over-refuse under concurrency.

  See `test/specs/REQ-463.md`.
  """

  use Letflow.DataCase, async: false

  alias Letflow.Engine.Task, as: EngineTask
  alias Letflow.SodSupport, as: S

  import Ecto.Query

  @rounds 6

  defp setup_case! do
    ctx = S.new_case!(S.parallel_graph(), %{}, %{"seed" => 1})
    u = S.insert_user!(ctx.schema_name, "u")
    v = S.insert_user!(ctx.schema_name, "v")
    S.grant_role!(ctx.schema_name, "role-p", [u.id, v.id])
    Map.merge(ctx, %{u: u, v: v})
  end

  defp race(ctx, actor_one, actor_two) do
    task_one = S.pending_task!(ctx, "branch-one")
    task_two = S.pending_task!(ctx, "branch-two")

    first = Elixir.Task.async(fn -> S.complete(ctx, task_one, actor_one, %{}) end)
    second = Elixir.Task.async(fn -> S.complete(ctx, task_two, actor_two, %{}) end)
    Elixir.Task.await_many([first, second], 15_000)
  end

  defp completed_nodes(ctx) do
    EngineTask
    |> where([t], t.instance_id == ^ctx.instance_id and t.status == :completed)
    |> select([t], t.node_id)
    |> Repo.all(prefix: ctx.schema_name)
    |> Enum.sort()
  end

  test "A-8: the same user completing P1 and P2 concurrently -- exactly one commits, the other is refused" do
    ctx = setup_case!()

    for round <- 1..@rounds do
      inst = %{
        ctx
        | instance_id: S.start_instance!(ctx.schema_name, ctx.definition, %{"r" => round})
      }

      results = race(inst, ctx.u.id, ctx.u.id)

      accepted = Enum.filter(results, &match?({:ok, _}, &1))
      refused = Enum.filter(results, &(&1 == {:error, :separation_of_duties}))

      assert length(accepted) == 1,
             "round #{round}: expected exactly one commit, got #{inspect(results)}"

      assert length(refused) == 1,
             "round #{round}: expected exactly one refusal, got #{inspect(results)}"

      # exactly ONE of the two parallel tasks is COMPLETED; the refused one is still PENDING
      assert length(completed_nodes(inst)) == 1
      assert length(S.rows(inst).tasks |> Enum.filter(&(&1.status == :pending))) == 2
    end

    # one audit row per refused request, none for a commit
    assert length(S.refusal_rows(ctx.schema_name)) == @rounds
  end

  test "control: two DIFFERENT users completing P1 and P2 concurrently both commit" do
    ctx = setup_case!()

    for round <- 1..@rounds do
      inst = %{
        ctx
        | instance_id: S.start_instance!(ctx.schema_name, ctx.definition, %{"r" => round})
      }

      assert [{:ok, _}, {:ok, _}] = race(inst, ctx.u.id, ctx.v.id)
      assert completed_nodes(inst) == ["branch-one", "branch-two"]
    end

    assert S.refusal_rows(ctx.schema_name) == []
  end
end
