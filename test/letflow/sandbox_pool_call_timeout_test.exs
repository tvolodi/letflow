defmodule Letflow.SandboxPoolCallTimeoutTest do
  @moduledoc """
  ISS-0220 regression: `Letflow.SandboxPool`'s two call-timeout budgets.

  Full case rationale, pre-fix/post-fix expectations, and the fail-then-pass
  demonstration: `test/specs/ISS-0220.md`. The contract these four cases implement is
  specified in `lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md` §10.

  ## Why this file exists separately from `test/letflow/sandbox_pool_test.exs`

  Everything under test here is a **client-side** computation: the integer `claim/2`
  and `release/2` hand to `GenServer.call/3` as its timeout. Reaching it needs no pool,
  no schema and no database connection at all, so this file uses a plain
  `ExUnit.Case` rather than `Letflow.DataCase` -- deliberately, so the
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` switch that
  `sandbox_pool_test.exs`'s moduledoc spends 40 lines justifying is not dragged in
  where it is irrelevant (design §10.2). DIRECTIVE T-1 is not in tension with this: no
  database is mocked here, none is used.

  ## The "black hole" technique

  `claim/2`'s `pool` argument is a `GenServer.server()` -- any pid will do. A process
  that receives the `{:"$gen_call", ...}` message and never replies makes
  `GenServer.call/3` run to its **full** timeout deterministically, and
  `GenServer.call/3`'s timeout exit reason carries the exact integer the client
  computed: `{:timeout, {GenServer, :call, [server, request, timeout]}}`. Matching on
  that third element observes the derivation *where it is actually consumed*, rather
  than restating the constant back to itself (design §10.1).

  Consequences that matter, and are the reason this shape was chosen over suspending a
  real pool or racing a real provisioning against a tiny budget:

    * zero schemas are created, so nothing leaks (and nothing sweeps a stray
      `sandbox_%` schema if one did);
    * runtime is exactly the tiny configured budget, so a test *about* a timing defect
      is not itself timing-sensitive and cannot go flaky under the very host load
      ISS-0220 is about;
    * `catch_exit/1` keeps the exit inside the assertion, and no reply is ever sent, so
      no stale `{ref, reply}` message pollutes the test process's mailbox.

  `async: false`: RT-1..RT-3 mutate `Application.env` at runtime, which is unsafe under
  `async: true` in this repo.
  """

  use ExUnit.Case, async: false

  alias Letflow.SandboxPool

  # A deliberately distinctive, non-round override (design §10.3): a passing match on
  # 1_234 / 3_234 cannot be a coincidence of some other default lying around.
  @override_ms 1_234

  # A process that receives and never replies. Killed on exit so nothing is left
  # running past the test; it holds no resource other than its own pid.
  defp black_hole! do
    hole = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(hole, :kill) end)
    hole
  end

  describe "with :provision_timeout_ms overridden to #{@override_ms} ms" do
    setup do
      original = Application.get_env(:letflow, :sandbox_pool)

      Application.put_env(
        :letflow,
        :sandbox_pool,
        Keyword.put(original, :provision_timeout_ms, @override_ms)
      )

      on_exit(fn -> Application.put_env(:letflow, :sandbox_pool, original) end)

      :ok
    end

    # RT-1 -- drift guard on the two derivations, NOT the regression demonstration.
    #
    # Read on its own this test is the tautology design §10.1 warns about: it asserts
    # the derivation equals itself, and would pass against any value the implementation
    # happened to pick. It is meaningful ONLY in combination with RT-2/RT-3, which
    # observe these same two numbers behaviourally, inside a real GenServer.call/3's
    # timeout exit reason. Do not read it as the substance of this contract.
    test "RT-1: claim_call_timeout/1 is max_wait_ms + the budget; release_call_timeout/0 is the budget" do
      for max_wait_ms <- [0, 1, 1_000, 2_000, 60_000] do
        assert SandboxPool.claim_call_timeout(max_wait_ms) ==
                 max_wait_ms + SandboxPool.provision_timeout_ms()
      end

      assert SandboxPool.release_call_timeout() == SandboxPool.provision_timeout_ms()
    end

    # RT-2 -- one of the two cases carrying fail-first weight (design §10.3).
    #
    # The expected timeouts are written as LITERALS derived from the config value this
    # test itself sets, so the assertion depends on no function introduced by the fix.
    # That is what makes it runnable -- and behaviourally failing -- against pre-fix
    # code, where the same two calls compute 0 + 5_000 = 5_000 and 2_000 + 5_000 =
    # 7_000 from the old @call_timeout_buffer_ms and ignore the override entirely.
    #
    # The second assertion is what makes the pair discriminating: it pins that
    # max_wait_ms is ADDED TO the budget rather than replaced by it. A single
    # assertion at max_wait_ms = 0 could not tell those two derivations apart.
    test "RT-2: a config override reaches claim/2's real GenServer.call/3, added to max_wait_ms" do
      hole = black_hole!()

      assert {:timeout, {GenServer, :call, [^hole, {:claim, 0}, 1_234]}} =
               catch_exit(SandboxPool.claim(0, hole))

      assert {:timeout, {GenServer, :call, [^hole, {:claim, 2_000}, 3_234]}} =
               catch_exit(SandboxPool.claim(2_000, hole))
    end

    # RT-3 -- the second of the two cases carrying fail-first weight (design §10.3).
    #
    # Pins design §3.2, the mis-sizing nobody named: pre-fix, release/2 called
    # GenServer.call/2 with no timeout argument at all, i.e. GenServer's own implicit
    # 5_000 ms default, so this observes 5_000 against the expected 1_234. Without this
    # case nothing prevents release/2 silently reverting to that default -- which
    # matters because Letflow.Definitions.safe_release/2 contains release failures with
    # `rescue`, and `rescue` structurally cannot catch the `exit` a call timeout raises.
    test "RT-3: release/2 uses the budget, not GenServer.call/2's implicit 5_000 ms default" do
      hole = black_hole!()
      sandbox_id = "00000000-0000-4000-8000-000000000220"

      assert {:timeout, {GenServer, :call, [^hole, {:release, ^sandbox_id}, 1_234]}} =
               catch_exit(SandboxPool.release(sandbox_id, hole))
    end
  end

  describe "with no :provision_timeout_ms configured (the shipped state)" do
    # RT-4 -- drift guard on the shipped default, NOT the regression demonstration.
    #
    # The equality is an honest change-detector, justified only because this entire
    # issue IS a number silently left un-sized: changing it must force a re-read of
    # lib/letflow/design/iss0220-sandbox-pool-provision-timeout.md §4, where 44_000 is
    # derived from measurement.
    #
    # The two inequalities are drift guards too, not independent properties -- given
    # the equality above them they are strictly implied and can never fail on their
    # own. They earn their place purely as documentation of the two bounds §4 derives,
    # on the same screen as the number they bound, so that whoever edits the equality
    # is confronted with them rather than having to go find §4. Do not count them as
    # separate coverage.
    test "RT-4: the shipped default budget is in force" do
      # Precondition, so the assertions below cannot be quietly satisfied by a config
      # file that has started setting the key: §6 deliberately ships it unset
      # everywhere, which is what makes "the default is in force" a real observation.
      refute Keyword.has_key?(
               Application.get_env(:letflow, :sandbox_pool),
               :provision_timeout_ms
             )

      # See design §4.5 before changing this number.
      assert SandboxPool.provision_timeout_ms() == 44_000

      # ExUnit's per-test ceiling (design §4.4).
      assert SandboxPool.provision_timeout_ms() < 60_000

      # The highest observed legitimate provisioning, i.e. floor 1 (design §4.1/§4.4).
      assert SandboxPool.provision_timeout_ms() > 15_373
    end
  end
end
