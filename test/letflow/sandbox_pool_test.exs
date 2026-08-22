defmodule Letflow.SandboxPoolTest do
  @moduledoc """
  Tests for `Letflow.SandboxPool` (REQ-039): `claim/1,2` and `release/1,2`. See
  `test/specs/REQ-039.md` for the full test-case rationale.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database anywhere in this file.

  ## Why this whole file runs under Sandbox `:auto` mode (not DataCase's normal
  ## rolled-back transaction)

  `SandboxPool.claim/1,2` calls `Ecto.Migrator.run/4` internally (to scaffold every
  `Letflow.TenantProvisioning.tenant_scoped_migrations/0` table into the freshly
  `CREATE SCHEMA`'d sandbox). `test/letflow/tenant_provisioning_test.exs` already hit
  and solved this exact problem for `replay_migrations/2` -- read that file's
  moduledoc and its `describe "replay_migrations/2 -- successful replay (acceptance
  criterion 3)"` block for the full empirical investigation (`Ecto.Migrator` genuinely
  needs a second, independent DB connection beyond whatever DataCase's sandboxed
  checkout hands this process, which raises `DBConnection.ConnectionError` /
  `:queue_timeout` under the default shared-connection sandbox mode). This file's
  `setup` block applies that same fix -- switch `Letflow.Repo` to Sandbox `:auto` mode
  -- for every test up front (not just a subset of describe blocks), because
  practically every test in this file calls `claim/1,2` at least once. As a
  consequence, **no test in this file is rolled back automatically**: every real
  Postgres schema this file creates is dropped explicitly, via `release/1,2` and/or a
  defensive `on_exit/1` `DROP SCHEMA IF EXISTS ... CASCADE` fallback right after each
  claim succeeds (belt-and-suspenders: the fallback is a no-op on the normal path,
  where `release/1,2` already dropped the schema).

  `async: false` for the whole module, for the identical reason
  `tenant_provisioning_test.exs` is `async: false` -- see that file's moduledoc for
  the full argument (traced directly from ExUnit's own `async_loop/4` source) that
  switching `Letflow.Repo`'s sandbox mode mid-test cannot corrupt any other
  concurrently running test file's connection, because ExUnit never runs an
  `async: false` module concurrently with anything else.

  ## Why this file starts its own uniquely-named `SandboxPool` instance per test,
  ## rather than using the application's singleton `Letflow.SandboxPool`

  Per the design doc (`lib/letflow/design/req039-sandbox-pool-fixture-loader.md` §4.2,
  §4.7 INV-SP-7), `start_link/1`'s `:name` option exists specifically so a test can
  start an independent pool with its own small `:max_concurrent`, deterministically
  exercising the quota-exhausted/blocking-wait behaviour (acceptance criterion 2)
  without contending for, or being polluted by, the application's own singleton pool
  (`config/test.exs` sets that singleton's quota to `max_concurrent_sandboxes: 1`
  specifically so *that* value stays cheap for whatever future test wants it, e.g. a
  REQ-040 test exercising the real end-to-end orchestration against the default pool --
  not so every SandboxPool test in this project has to share one global slot). See
  `start_pool!/1` below.
  """

  use Letflow.DataCase, async: false

  alias Letflow.SandboxPool
  alias Letflow.SandboxPool.SandboxClaim

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    :ok
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  # Covers only what happens *after* a pool call returns and before the waiting side
  # observes it: one BEAM message hop, the spawned process's own assert, and (for the
  # waiter rendezvous below) one schema_exists?/1 round trip. Real cost is
  # sub-millisecond to low-milliseconds; 1000ms is three orders of magnitude of slack.
  # It performs NO provisioning-cost work whatsoever -- that job belongs entirely to
  # SandboxPool.provision_timeout_ms/0. Kept as a separate, visibly small constant
  # rather than folded into the budget precisely so it can never quietly become a
  # second un-derived provisioning allowance (ISS-0220 design doc §8.1).
  @rendezvous_slack_ms 1_000

  # How long an observer in this file waits for something that is gated on a
  # SandboxPool.claim/2 (i.e. on a full cold-start provisioning). Derived from the
  # pool's own public call-timeout derivation rather than hand-picked, so these bounds
  # track a :provision_timeout_ms config override automatically and cannot drift away
  # from the budget the code under test actually uses (ISS-0220 design doc §8.1).
  #
  # This is the patience of the observer, not an assertion about the system under
  # test: nothing these bounds guard asserts anything different than it did before.
  defp claim_rendezvous_timeout(max_wait_ms) do
    SandboxPool.claim_call_timeout(max_wait_ms) + @rendezvous_slack_ms
  end

  # Same, for something gated on a SandboxPool.release/2 (or on the test process
  # getting as far as one).
  defp pool_op_rendezvous_timeout do
    SandboxPool.release_call_timeout() + @rendezvous_slack_ms
  end

  # Starts an isolated, uniquely-named SandboxPool instance so this test's quota
  # exercising never contends with another test in this file or with the
  # application's own singleton (design doc §4.7 INV-SP-7). Returns the pid --
  # SandboxPool.claim/2 and release/2 both accept a raw pid as `pool`.
  defp start_pool!(opts) do
    name = :"sandbox_pool_test_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SandboxPool.start_link(Keyword.put_new(opts, :name, name))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp schema_exists?(schema_name) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
        schema_name
      ])

    rows != []
  end

  defp table_exists_in_schema?(schema_name, table_name) do
    %{rows: [[exists?]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2)",
        [schema_name, table_name]
      )

    exists?
  end

  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Polls a pool's internal :waiting queue (via :sys.get_state/1, matching this
  # project's established bounded-polling idiom -- see
  # parallel_approval_test.exs's wait_for_new_pid/3) until a caller has genuinely
  # been queued as a waiter, rather than assuming a fixed sleep is long enough. This
  # removes the race between "Task.async's claim call has reached the pool's mailbox"
  # and "the test process calls release" -- see acceptance criterion 2's blocking-path
  # test below.
  defp wait_until_waiter_queued(pool, attempts \\ 200)

  defp wait_until_waiter_queued(_pool, 0) do
    flunk("expected a waiter to be queued in the pool's :waiting queue, but none appeared")
  end

  defp wait_until_waiter_queued(pool, attempts) do
    %{waiting: waiting} = :sys.get_state(pool)

    if :queue.len(waiting) > 0 do
      :ok
    else
      Process.sleep(5)
      wait_until_waiter_queued(pool, attempts - 1)
    end
  end

  # Same bounded-polling idiom as wait_until_waiter_queued/2 above, but for the
  # owner-crash-reclaim test below (ISS-0048): polls information_schema.schemata
  # directly until a killed owner's schema has actually been dropped by
  # SandboxPool's :DOWN handler, rather than assuming a fixed sleep is long
  # enough.
  #
  # Bounded by a monotonic-time deadline rather than by an attempt count (ISS-0220
  # design doc §8.2): an attempt count is an implicit time bound that silently changes
  # meaning if the 5ms poll interval ever changes. The default deadline is derived from
  # SandboxPool.release_call_timeout/0 -- the same single source of truth every other
  # bound in this file derives from -- rather than from a second, separately-derived
  # polling constant. The assertion is unchanged: on expiry this still flunks with the
  # same message, and a dropped schema still returns :ok.
  defp wait_until_schema_dropped(
         schema_name,
         timeout_ms \\ SandboxPool.release_call_timeout()
       ) do
    poll_until_schema_dropped(schema_name, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll_until_schema_dropped(schema_name, deadline_ms) do
    cond do
      not schema_exists?(schema_name) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk(
          "expected schema #{schema_name} to be dropped by SandboxPool's owner-crash " <>
            "reclaim, but it still exists in information_schema.schemata"
        )

      true ->
        Process.sleep(5)
        poll_until_schema_dropped(schema_name, deadline_ms)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 1: "claim/1 against an empty pool immediately succeeds and
  # returns a sandbox_id + schema_name for a real, freshly-created Postgres schema"
  # ---------------------------------------------------------------------------------

  describe "claim/1,2 -- empty pool (acceptance criterion 1)" do
    test "immediately succeeds and returns a sandbox_id + schema_name for a real, freshly-created Postgres schema" do
      pool = start_pool!(max_concurrent: 5)

      assert {:ok, %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(schema_name) end)

      assert is_binary(sandbox_id)
      assert {:ok, _} = Ecto.UUID.cast(sandbox_id)
      assert String.match?(schema_name, ~r/^sandbox_[0-9a-f]{32}$/)

      # The core AC1 assertion: query information_schema.schemata directly -- proves
      # a real Postgres schema exists, not just that the function returned a
      # well-shaped struct.
      assert schema_exists?(schema_name)

      # INV-SP-3 (design doc §4.7): already scaffolded with every
      # tenant_scoped_migrations/0 table, so fixture loading never needs to create
      # its own target tables.
      assert table_exists_in_schema?(schema_name, "process_definitions")
      assert table_exists_in_schema?(schema_name, "instance_definition_snapshots")

      assert :ok = SandboxPool.release(sandbox_id, pool)
    end

    test "two immediate claims against a pool with room for both produce two distinct schemas" do
      pool = start_pool!(max_concurrent: 5)

      assert {:ok, %SandboxClaim{sandbox_id: id1, schema_name: schema1}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(schema1) end)

      assert {:ok, %SandboxClaim{sandbox_id: id2, schema_name: schema2}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(schema2) end)

      assert id1 != id2
      assert schema1 != schema2
      assert schema_exists?(schema1)
      assert schema_exists?(schema2)

      assert :ok = SandboxPool.release(id1, pool)
      assert :ok = SandboxPool.release(id2, pool)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 2: "claim/1 when max_concurrent_sandboxes slots are all in
  # use blocks until either a slot frees or the wait window elapses, returning
  # SandboxUnavailable in the latter case" -- BOTH paths required, per this file's
  # dispatching task: the slot-frees-and-the-waiter-succeeds path, and the real
  # timeout-to-SandboxUnavailable path.
  #
  # Both tests use small, deliberate max_wait_ms windows (150ms-2s), never REQ-039's
  # real-world 60s default, per this file's task instruction to keep any unavoidable
  # real timeout small.
  # ---------------------------------------------------------------------------------

  describe "claim/1,2 -- quota exhausted, blocking path (acceptance criterion 2)" do
    test "a queued waiter is served once the held slot frees, before its wait window elapses" do
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, %SandboxClaim{sandbox_id: held_id, schema_name: held_schema}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(held_schema) end)

      # Long enough that the timeout path (tested separately below) cannot be what
      # produces a success here -- if this test passed only because the timer fired
      # after a slot had already, coincidentally, become free some other way, it
      # would be vacuous. The waiter genuinely blocks (:noreply internally) until
      # release/2 below frees the slot.
      #
      # The claim and its matching release must happen from the same process (see
      # SandboxPool's "Same-process claim/release contract" moduledoc section) --
      # a Task.async process that merely returns its claim and exits looks, to the
      # owner-monitor, identical to that process leaking/crashing, and the slot
      # would be reclaimed before the test process's own release/2 call ran. So the
      # spawned process itself claims, relays the claim back via a send/receive
      # rendezvous for the test process to assert on, waits for a "go ahead" signal,
      # and only then calls release/2 itself, before returning.
      test_pid = self()

      waiter =
        Task.async(fn ->
          assert {:ok, %SandboxClaim{} = waiter_claim} = SandboxPool.claim(2_000, pool)

          send(test_pid, {:waiter_claimed, waiter_claim})

          receive do
            :release_waiter_claim -> :ok
          after
            pool_op_rendezvous_timeout() ->
              flunk("test process never signalled release for the waiter claim")
          end

          assert :ok = SandboxPool.release(waiter_claim.sandbox_id, pool)

          waiter_claim
        end)

      wait_until_waiter_queued(pool)

      assert :ok = SandboxPool.release(held_id, pool)
      refute schema_exists?(held_schema)

      assert_receive {:waiter_claimed,
                      %SandboxClaim{sandbox_id: waiter_id, schema_name: waiter_schema}},
                     claim_rendezvous_timeout(2_000)

      on_exit(fn -> drop_schema!(waiter_schema) end)

      assert waiter_id != held_id
      assert schema_exists?(waiter_schema)

      send(waiter.pid, :release_waiter_claim)

      assert %SandboxClaim{sandbox_id: ^waiter_id} =
               Task.await(waiter, pool_op_rendezvous_timeout())
    end

    test "when no slot frees within the wait window, returns {:error, :sandbox_unavailable} and the held claim is untouched" do
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, %SandboxClaim{sandbox_id: held_id, schema_name: held_schema}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(held_schema) end)

      # Small deliberate wait window -- nothing ever releases the held slot, so this
      # call must genuinely wait out the timer and hit the timeout branch
      # (handle_info({:claim_timeout, ...}, ...)), not the release-driven hand-off.
      assert {:error, :sandbox_unavailable} = SandboxPool.claim(150, pool)

      # The timed-out waiter must not have disturbed the held claim's bookkeeping or
      # its physical schema.
      assert schema_exists?(held_schema)
      assert :ok = SandboxPool.release(held_id, pool)
      refute schema_exists?(held_schema)
    end

    test "max_wait_ms <= 0 against an exhausted pool rejects immediately without ever queueing" do
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, %SandboxClaim{sandbox_id: held_id, schema_name: held_schema}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(held_schema) end)

      assert {:error, :sandbox_unavailable} = SandboxPool.claim(0, pool)
      assert %{waiting: waiting} = :sys.get_state(pool)
      assert :queue.len(waiting) == 0

      assert :ok = SandboxPool.release(held_id, pool)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 3: "release/1 on a claimed sandbox drops its schema
  # (verified: the schema no longer appears in information_schema.schemata after
  # release) and frees its quota slot for a subsequent claim/1"
  # ---------------------------------------------------------------------------------

  describe "release/1,2 (acceptance criterion 3)" do
    test "drops the schema for real (confirmed via information_schema.schemata) and frees the quota slot for a subsequent claim/1" do
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, %SandboxClaim{sandbox_id: id1, schema_name: schema1}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(schema1) end)

      assert schema_exists?(schema1)

      # Sanity check the slot is genuinely fully consumed right now, so the later
      # "frees the slot" assertion isn't vacuous.
      assert {:error, :sandbox_unavailable} = SandboxPool.claim(0, pool)

      assert :ok = SandboxPool.release(id1, pool)

      # The core AC3 assertion: a real Postgres query, not the return value.
      refute schema_exists?(schema1)

      # The freed slot is immediately claimable again.
      assert {:ok, %SandboxClaim{sandbox_id: id2, schema_name: schema2}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(schema2) end)

      assert id2 != id1
      assert schema_exists?(schema2)
      assert :ok = SandboxPool.release(id2, pool)
    end

    test "an unknown sandbox_id returns {:error, :not_found} without touching any schema" do
      pool = start_pool!(max_concurrent: 1)

      assert {:error, :not_found} = SandboxPool.release(Ecto.UUID.generate(), pool)
    end
  end

  # ---------------------------------------------------------------------------------
  # ISS-0048 regression: owning process killed (not a raised exception) between
  # claim/2 and release/2 -- see
  # lib/letflow/design/iss-0048-sandbox-pool-owner-crash-reclaim.md and
  # test/specs/ISS-0048.md for the full rationale. `try/rescue` (the only safety
  # net that existed before this fix) never runs on an `exit` signal -- only a
  # process kill genuinely exercises the new owner-monitor path; a raised
  # exception would prove nothing new here.
  # ---------------------------------------------------------------------------------

  describe "owning process killed between claim/2 and release/2 (ISS-0048 regression)" do
    test "a killed owner's claim is reclaimed: schema dropped and quota slot freed for a subsequent claim/2" do
      pool = start_pool!(max_concurrent: 1)
      test_pid = self()

      # Claim from a separate, spawned process (not the test process) so that
      # process -- not the test itself -- can be killed out from under its own
      # claim. Plain spawn/1, not Task.async/1: Task's own normal-return exit is
      # already exercised by this file's "queued waiter" test above; this test
      # needs the process to still be alive, holding its claim, at the moment it
      # is killed, so it never calls release/2 at all.
      owner_pid =
        spawn(fn ->
          assert {:ok, %SandboxClaim{} = claim} = SandboxPool.claim(1_000, pool)
          send(test_pid, {:owner_claimed, claim})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:owner_claimed,
                      %SandboxClaim{sandbox_id: sandbox_id, schema_name: schema_name}},
                     claim_rendezvous_timeout(1_000)

      on_exit(fn -> drop_schema!(schema_name) end)

      # Sanity: the claim is real and the pool's quota is genuinely exhausted
      # before the kill, so the "slot freed" assertion below isn't vacuous.
      assert schema_exists?(schema_name)
      assert {:error, :sandbox_unavailable} = SandboxPool.claim(0, pool)

      # Kill the owner via an exit signal try/rescue structurally cannot catch --
      # NOT a raised exception (that path was already handled before this fix).
      owner_monitor_ref = Process.monitor(owner_pid)
      Process.exit(owner_pid, :kill)
      assert_receive {:DOWN, ^owner_monitor_ref, :process, ^owner_pid, :killed}, 2_000

      # Core regression assertion: the schema is dropped from real Postgres --
      # not merely that the function returned a particular value -- once
      # SandboxPool has processed its own :DOWN message for the dead owner.
      wait_until_schema_dropped(schema_name)
      refute schema_exists?(schema_name)

      # The freed quota slot is immediately claimable again -- proves the
      # `active` entry itself was removed, not just the physical schema.
      assert {:ok, %SandboxClaim{sandbox_id: id2, schema_name: schema2}} =
               SandboxPool.claim(1_000, pool)

      on_exit(fn -> drop_schema!(schema2) end)

      assert id2 != sandbox_id
      assert schema_exists?(schema2)
      assert :ok = SandboxPool.release(id2, pool)
    end
  end

  # ---------------------------------------------------------------------------------
  # Acceptance criterion 6: "the moduledoc names the process-per-instance-vs-row-
  # based-state open question explicitly and states it is left for CODE-DESIGNER" --
  # a documentation-content requirement, not application behaviour in the ExUnit
  # sense. Following test/specs/REQ-022.md's AC4 precedent (itself following
  # test/specs/REQ-020.md's AC5 precedent), this is verified by direct inspection,
  # recorded in test/specs/REQ-039.md, rather than a String.contains?(@moduledoc, ...)
  # runtime assertion that would prove nothing about whether the content is actually
  # true and would stay trivially "green" under a copy-pasted substring.
  # ---------------------------------------------------------------------------------

  # ---------------------------------------------------------------------------------
  # ISS-0224 regression: `provision_sandbox/0` must not run inside a pool callback
  # ---------------------------------------------------------------------------------
  #
  # Helpers below implement `lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md`
  # §10.2. They are used ONLY by the ISS-0224 describe block; the pre-existing cases in
  # this file deliberately keep querying directly from the test process (design §11
  # item 14 / §13 item 5 -- their connection marginality is a pre-existing finding, not
  # something this contract may quietly change by retrofitting).

  # The vacuity floor shared by RT-2(a) and RT-7(a), design §10.4. NOT a tolerance: it
  # is the value below which the defect cannot exist at all, so a green result would be
  # vacuous and the test must say so loudly instead. Derived from six independent
  # measurement windows whose lowest observed single provisioning is 411 ms
  # (ISSUE-FIXER, ~1500 samples); 200 ms sits 2.06x below that. ONE value serves both
  # premise guards, deliberately -- they guard the same quantity class (one provisioning
  # latency), so this contract introduces no second figure. Do not re-derive it here;
  # design §10.4 is where the derivation lives.
  @vacuity_floor_ms 200

  # Runs `fun` in a SHORT-LIVED process that then exits, so whatever DBConnection
  # checkout the query needs is handed straight back rather than retained for the rest
  # of the test. Design §10.2/§10.5: a verification query must never sit on a connection
  # while the pool's worker is provisioning, since one provisioning needs two of its own.
  defp query_without_holding(fun) when is_function(fun, 0) do
    test_pid = self()
    ref = make_ref()

    {pid, monitor_ref} = spawn_monitor(fn -> send(test_pid, {ref, fun.()}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        flunk("query_without_holding/1's helper process died: #{inspect(reason)}")
    after
      pool_op_rendezvous_timeout() ->
        Process.exit(pid, :kill)
        flunk("query_without_holding/1's helper process never answered")
    end
  end

  # Snapshot of every sandbox_% schema currently in information_schema.schemata. A set
  # difference before/after is the no-schema-leak proof in the cases where the leaked
  # name is one the test never gets told (a schema minted for a caller that died before
  # its claim was ever reported back).
  defp sandbox_schema_names do
    query_without_holding(fn ->
      %{rows: rows} =
        Repo.query!(
          "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'sandbox\\_%'"
        )

      MapSet.new(rows, fn [schema_name] -> schema_name end)
    end)
  end

  # Defensive teardown -- exactly the belt-and-suspenders role this file's existing
  # `on_exit(fn -> drop_schema!(schema) end)` calls play, but for cases whose leaked
  # schema names are not known up front. A no-op on every normal path, where the pool
  # has already dropped everything it created.
  defp drop_sandbox_schemas_created_since!(baseline) do
    for schema_name <- MapSet.difference(sandbox_schema_names(), baseline) do
      query_without_holding(fn ->
        Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
      end)
    end

    :ok
  end

  # Spawns a process that claims, reports {:claimed, label, result, elapsed_ms} back to
  # the test process, and then blocks until told to release -- honouring SandboxPool's
  # "Same-process claim/release contract": the SAME process that claimed is the one that
  # later calls release/2, so a claimer that is merely waiting never looks to the
  # owner-monitor like a process that leaked its claim.
  #
  # `elapsed_ms` is measured with System.monotonic_time/1 INSIDE the spawned process,
  # around the claim/2 call only, so it is that caller's own observed claim latency and
  # carries no rendezvous cost.
  defp spawn_claimer(pool, label, max_wait_ms) do
    test_pid = self()

    pid =
      spawn(fn ->
        started_at = System.monotonic_time(:millisecond)
        result = SandboxPool.claim(max_wait_ms, pool)
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        send(test_pid, {:claimed, label, result, elapsed_ms})
        claimer_loop(pool, label, test_pid, result)
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp claimer_loop(pool, label, test_pid, claim_result) do
    receive do
      :release ->
        outcome =
          case claim_result do
            {:ok, %SandboxClaim{sandbox_id: sandbox_id}} -> SandboxPool.release(sandbox_id, pool)
            _other -> {:error, :nothing_to_release}
          end

        send(test_pid, {:released, label, outcome})
        claimer_loop(pool, label, test_pid, :already_released)

      :stop ->
        :ok
    end
  end

  # Bounded polling of the pool's own state -- the same :sys.get_state/1 idiom and the
  # same 5ms interval wait_until_waiter_queued/2 and poll_until_schema_dropped/2 above
  # already use, but bounded by a monotonic deadline derived from
  # SandboxPool.release_call_timeout/0, the single source of truth every other bound in
  # this file derives from. No new constant (design §10.4).
  defp wait_until_pool_state(pool, description, predicate) do
    poll_pool_state(
      pool,
      description,
      predicate,
      System.monotonic_time(:millisecond) + SandboxPool.release_call_timeout()
    )
  end

  defp poll_pool_state(pool, description, predicate, deadline_ms) do
    state = :sys.get_state(pool)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("timed out waiting for pool state: #{description}\nlast state: #{inspect(state)}")

      true ->
        Process.sleep(5)
        poll_pool_state(pool, description, predicate, deadline_ms)
    end
  end

  defp waiter_count(%{waiting: waiting}), do: :queue.len(waiting)

  defp provision_in_flight?(%{in_flight: %{op: {:provision, _}}}), do: true
  defp provision_in_flight?(_state), do: false

  defp queued_provision_ops(%{db_queue: db_queue}) do
    Enum.filter(:queue.to_list(db_queue), &match?({:provision, _}, &1))
  end

  defp queued_provision_ops(_state), do: []

  # RT-8's counting surface: db_queue UNION the one in_flight op, not db_queue alone.
  # db_queue alone is correct but has a narrow window -- once the concurrent
  # provisioning completes, the pool pumps the retargeted DROP into `in_flight` and a
  # queued-only count reads zero. That would be a loud red rather than a silent green,
  # but the union discriminates identically (the case-5 fall-through this case exists to
  # catch still shows two ops) and is not subject to the window at all.
  defp drop_ops_for_sandbox(state, sandbox_id) do
    in_flight_ops =
      case state.in_flight do
        %{op: op} -> [op]
        nil -> []
      end

    Enum.filter(:queue.to_list(state.db_queue) ++ in_flight_ops, fn
      {:drop, %{sandbox_id: id}} -> id == sandbox_id
      _other -> false
    end)
  end

  defp pool_drained?(%{in_flight: nil, db_queue: db_queue}), do: :queue.is_empty(db_queue)
  defp pool_drained?(_state), do: false

  # ---------------------------------------------------------------------------------
  # ISS-0224 regression: provisioning ran synchronously inside the pool's own
  # callbacks, so for the whole duration of one provisioning the pool processed no
  # message at all -- including a parked waiter's own {:claim_timeout, _} timer.
  # `max_wait_ms`, documented as bounding queue parking only, therefore overshot by up
  # to one full provisioning. See
  # lib/letflow/design/iss0224-sandbox-pool-async-provisioning.md §10 (the contract
  # these eight cases implement) and test/specs/ISS-0224.md for the per-case rationale
  # and the pre-fix/post-fix evidence.
  #
  # RT-2(d) and RT-7(c) are the two fail-first cases; RT-1 is their control arm;
  # RT-3..RT-6 and RT-8 are the five mandatory death-path guards, each asserting BOTH
  # no slot leak and no schema leak, and that the pool itself survived.
  # ---------------------------------------------------------------------------------

  describe "provisioning does not block the pool's mailbox (ISS-0224 regression)" do
    test "RT-1 (control): a parked waiter times out on schedule when nothing is provisioning" do
      # Control arm, not a regression: this passes both pre-fix and post-fix. Its job is
      # to make RT-2's failure attributable to the blocking rather than to the timer --
      # if the {:claim_timeout, _} machinery were simply broken, this case would be red
      # too and RT-2 would prove nothing about mailbox starvation.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 1)

      o = spawn_claimer(pool, :o, 0)

      assert_receive {:claimed, :o, {:ok, %SandboxClaim{schema_name: o_schema}}, _t_o},
                     claim_rendezvous_timeout(0)

      # W1 first, confirmed parked, THEN W2 -- so W2 is genuinely behind W1 in the FIFO
      # queue, and so the window between W2 parking and the test observing it is one
      # poll interval rather than however long two spawns happen to take.
      w1 = spawn_claimer(pool, :w1, 60_000)
      wait_until_pool_state(pool, "W1 parked", &(waiter_count(&1) == 1))

      _w2 = spawn_claimer(pool, :w2, 50)
      wait_until_pool_state(pool, "W2 parked behind W1", &(waiter_count(&1) == 2))

      assert_receive {:claimed, :w2, w2_result, t_w2}, claim_rendezvous_timeout(50)
      assert w2_result == {:error, :sandbox_unavailable}
      assert t_w2 >= 50

      # W1 is never served: O holds the only slot and never releases it. Asserted from
      # the pool's own state rather than by waiting out a refute_receive window, so the
      # case costs nothing and introduces no bound.
      refute_received {:claimed, :w1, _, _}
      state = :sys.get_state(pool)
      assert waiter_count(state) == 1
      assert map_size(state.active) == 1

      Process.exit(w1, :kill)
      wait_until_pool_state(pool, "the killed W1 leaves `waiting`", &(waiter_count(&1) == 0))

      send(o, :release)
      assert_receive {:released, :o, :ok}, pool_op_rendezvous_timeout()

      final = sandbox_schema_names()
      refute MapSet.member?(final, o_schema)
      assert final == baseline
      assert Process.alive?(pool)
    end

    test "RT-2: a waiter's max_wait_ms is honoured while a DIFFERENT waiter is being provisioned" do
      # FAIL-FIRST #1. Identical to RT-1 except that O releases once both waiters are
      # parked, so W1 is promoted and provisioned while W2's 50ms timer runs. Pre-fix the
      # promotion and the provisioning both happen INSIDE the release callback, so W2's
      # timer message is not looked at until that callback returns -- measured pre-fix,
      # t_w2 == t_w1 to the millisecond in 20/20 runs.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 1)

      o = spawn_claimer(pool, :o, 0)
      assert_receive {:claimed, :o, {:ok, %SandboxClaim{}}, _t_o}, claim_rendezvous_timeout(0)

      w1 = spawn_claimer(pool, :w1, 60_000)
      wait_until_pool_state(pool, "W1 parked", &(waiter_count(&1) == 1))

      _w2 = spawn_claimer(pool, :w2, 50)
      wait_until_pool_state(pool, "W2 parked behind W1", &(waiter_count(&1) == 2))

      send(o, :release)
      assert_receive {:released, :o, :ok}, pool_op_rendezvous_timeout()

      assert_receive {:claimed, :w1, w1_result, t_w1}, claim_rendezvous_timeout(60_000)
      assert_receive {:claimed, :w2, w2_result, t_w2}, claim_rendezvous_timeout(50)

      # (a) PREMISE, checked first: a host that provisions in under the vacuity floor
      # cannot exhibit the defect at all, and a green (d) there would be vacuous.
      if t_w1 < @vacuity_floor_ms do
        flunk(
          "RT-2 premise (a) failed: W1's claim latency was #{t_w1} ms, below the " <>
            "#{@vacuity_floor_ms} ms vacuity floor. One provisioning has never been " <>
            "measured below 411 ms across the six windows in design §10.4, so this host " <>
            "is not exercising the scenario RT-2(d) is about and a pass would prove " <>
            "nothing. See design §10.4."
        )
      end

      # (b)
      assert {:ok, %SandboxClaim{}} = w1_result
      assert w2_result == {:error, :sandbox_unavailable}

      # (d) THE LOAD-BEARING FAIL-FIRST. A ratio of two quantities measured inside this
      # same test on this same host, so it needs no constant and no calibration. Pre-fix
      # it is false because W2's reply is gated on W1's provisioning rather than on W2's
      # own timer; post-fix the smaller side contains no DB work at all, and the measured
      # minimum ratio t_w1/t_w2 is 7.91 -- roughly 4x headroom over the 2x threshold.
      #
      # Round 0's ordering assertion ("the first completion message has label == :w2")
      # is NOT implemented and must not be re-added: it held 3/20, 5/20 and 0/20 across
      # three independent pre-fix windows, i.e. a biased coin flip, and would have
      # licensed a regression test that goes green against unfixed code (design §10.1
      # trap 2, and §10.3's struck row).
      assert 2 * t_w2 < t_w1,
             "RT-2(d) failed: t_w2 = #{t_w2} ms, t_w1 = #{t_w1} ms. W2 asked to wait " <>
               "50 ms and its reply was gated on W1's provisioning instead -- the pool's " <>
               "mailbox is blocked while a provisioning runs. See design §1.1, §10.3."

      send(w1, :release)
      assert_receive {:released, :w1, :ok}, pool_op_rendezvous_timeout()

      assert sandbox_schema_names() == baseline
      assert Process.alive?(pool)
    end

    test "RT-3 (death path a): a caller that dies while parked in `waiting` leaks no slot and no schema" do
      # Guard, not a regression -- it holds pre-fix via INV-SP-6, and its job is to keep
      # holding across the refactor that moved the owner monitor to reservation time.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 1)

      o = spawn_claimer(pool, :o, 0)

      assert_receive {:claimed, :o, {:ok, %SandboxClaim{schema_name: o_schema}}, _t_o},
                     claim_rendezvous_timeout(0)

      w = spawn_claimer(pool, :w, 60_000)
      wait_until_pool_state(pool, "W parked", &(waiter_count(&1) == 1))

      Process.exit(w, :kill)
      wait_until_pool_state(pool, "the dead waiter leaves `waiting`", &(waiter_count(&1) == 0))

      # NO SCHEMA LEAK: a parked waiter never had one provisioned for it, so the only
      # sandbox schema in existence is still O's.
      assert sandbox_schema_names() == MapSet.put(baseline, o_schema)

      send(o, :release)
      assert_receive {:released, :o, :ok}, pool_op_rendezvous_timeout()

      # NO SLOT LEAK.
      assert {:ok, %SandboxClaim{sandbox_id: id2}} = SandboxPool.claim(0, pool)
      assert :ok = SandboxPool.release(id2, pool)

      assert Process.alive?(pool)
      assert sandbox_schema_names() == baseline
    end

    test "RT-4 (death path b): a caller that dies DURING its provisioning leaks no slot and no schema" do
      # POST-FIX-ONLY TECHNIQUE, and labelled as such: it polls `in_flight`, which does
      # not exist pre-fix -- and pre-fix there is no such window to observe at all,
      # because the owner is not monitored until AFTER a successful provisioning. It
      # carries no fail-first weight and is not counted toward WF-03 Step 4's evidence.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 1)

      o = spawn_claimer(pool, :o, 1_000)

      state =
        wait_until_pool_state(pool, "O's provisioning is in flight", &provision_in_flight?/1)

      {:provision, %{schema_name: o_schema}} = state.in_flight.op

      Process.exit(o, :kill)

      # The pool does NOT kill the worker (Ecto.Migrator runs with timeout: :infinity, so
      # killing it mid-run abandons an open transaction and a half-migrated schema): it
      # lets the provisioning finish and then drops the schema it produced.
      drained =
        wait_until_pool_state(pool, "the pool drains after the owner's death", &pool_drained?/1)

      assert drained.in_flight == nil
      assert :queue.is_empty(drained.db_queue)

      # NO SCHEMA LEAK.
      final = sandbox_schema_names()
      refute MapSet.member?(final, o_schema)
      assert final == baseline

      # NO SLOT LEAK.
      assert {:ok, %SandboxClaim{sandbox_id: id2}} = SandboxPool.claim(0, pool)
      assert :ok = SandboxPool.release(id2, pool)

      assert Process.alive?(pool)
    end

    test "RT-5 (death path b'): a caller that dies while its reservation is still QUEUED frees its slot and provisions nothing" do
      # POST-FIX-ONLY. Exercises design §7 step 3 clause B case 4 -- a state that has no
      # pre-fix analogue, since pre-fix there is no db_queue and a claim is either
      # provisioned inline or parked. No fail-first weight.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 2)

      a = spawn_claimer(pool, :a, 0)
      wait_until_pool_state(pool, "A's provisioning is in flight", &provision_in_flight?/1)

      b = spawn_claimer(pool, :b, 0)

      state =
        wait_until_pool_state(pool, "B's provision op is queued behind A's", fn s ->
          length(queued_provision_ops(s)) == 1
        end)

      [{:provision, %{schema_name: b_schema}}] = queued_provision_ops(state)

      Process.exit(b, :kill)

      wait_until_pool_state(pool, "B's queued reservation is discarded", fn s ->
        queued_provision_ops(s) == []
      end)

      assert_receive {:claimed, :a, {:ok, %SandboxClaim{}}, _t_a}, claim_rendezvous_timeout(0)
      send(a, :release)
      assert_receive {:released, :a, :ok}, pool_op_rendezvous_timeout()

      wait_until_pool_state(pool, "the pool drains", &pool_drained?/1)

      # NO SCHEMA LEAK: B's identity was minted pool-side at reservation time, but no
      # schema was ever created for it, and none must appear afterwards either.
      final = sandbox_schema_names()
      refute MapSet.member?(final, b_schema)
      assert final == baseline

      # NO SLOT LEAK: both slots are back.
      assert {:ok, %SandboxClaim{sandbox_id: id1}} = SandboxPool.claim(0, pool)
      assert {:ok, %SandboxClaim{sandbox_id: id2}} = SandboxPool.claim(0, pool)
      assert :ok = SandboxPool.release(id1, pool)
      assert :ok = SandboxPool.release(id2, pool)

      assert Process.alive?(pool)
    end

    test "RT-6 (death path c): the provisioning worker Task crashing fails the claim without taking the pool, a slot or a schema with it" do
      # POST-FIX-ONLY. Exercises design §7 step 3 clause B case 1. Pre-fix there is no
      # worker to kill at all -- provisioning runs on the pool process itself, where an
      # equivalent kill would simply destroy the pool. No fail-first weight.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 1)

      _o = spawn_claimer(pool, :o, 1_000)

      state =
        wait_until_pool_state(pool, "O's provisioning is in flight", &provision_in_flight?/1)

      {:provision, %{schema_name: o_schema}} = state.in_flight.op
      task_pid = state.in_flight.task_pid

      # A genuine abnormal exit, not a stub return: this is the case Task.async/1 would
      # turn into a pool crash, and Task.Supervisor.async_nolink/3 exists to survive.
      Process.exit(task_pid, :kill)

      # The exact atom Letflow.Definitions matches on -- not a generic error.
      assert_receive {:claimed, :o, {:error, :provision_failed}, _t_o},
                     claim_rendezvous_timeout(1_000)

      drained =
        wait_until_pool_state(pool, "the pool drains after the worker crash", &pool_drained?/1)

      assert drained.in_flight == nil

      # NO SCHEMA LEAK -- possible only because the pool pre-minted the schema name, so
      # a worker that died without returning anything is still nameable.
      final = sandbox_schema_names()
      refute MapSet.member?(final, o_schema)
      assert final == baseline

      # THE POOL SURVIVES, and NO SLOT LEAK.
      assert Process.alive?(pool)
      assert {:ok, %SandboxClaim{sandbox_id: id2}} = SandboxPool.claim(0, pool)
      assert :ok = SandboxPool.release(id2, pool)
    end

    test "RT-7: a DB-free claim(0) is answered immediately while a provisioning is running" do
      # FAIL-FIRST #2, and independent of RT-2's mechanism: RT-2 observes a TIMER being
      # starved, this one observes a plain synchronous call being starved. The same atom
      # is returned in both arms, so the discriminator is purely latency.
      #
      # The ordering is DETERMINISTIC, not a race, and that is the whole reason this case
      # is shaped around a waiter promotion rather than a bare concurrent claim. In BOTH
      # arms `release/2`'s reply is issued from INSIDE a callback that then goes on to
      # promote the parked waiter: pre-fix `handle_call({:release, _})` replies and then
      # calls `service_next_waiter/1`, which provisions W synchronously in that same
      # callback; post-fix `complete_op/3` replies and the same callback then does only
      # bookkeeping. So a probe sent by this process the instant `release/2` returns is
      # guaranteed to land behind a pool that is still inside that callback, and what
      # differs between the arms is exactly how much longer that callback runs.
      #
      # The probe can also never race into a FREE slot: `active` still holds O's entry
      # when the probe is queued (post-fix it is retained until the DROP resolves), and by
      # the time the callback ends W has been promoted into the slot -- so between
      # callbacks `slots_in_use` is 1 continuously and the probe's answer is
      # {:error, :sandbox_unavailable} under every interleaving.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 1)

      # The TEST process owns this claim, so it is also the process that releases it --
      # the same-process contract. It acquires no DBConnection checkout of its own by
      # doing so: claim/2 and release/2 do their DB work in the pool, never in the caller.
      assert {:ok, %SandboxClaim{sandbox_id: o_id}} = SandboxPool.claim(1_000, pool)

      w = spawn_claimer(pool, :w, 60_000)
      wait_until_pool_state(pool, "W parked", &(waiter_count(&1) == 1))

      assert :ok = SandboxPool.release(o_id, pool)

      probe_started_at = System.monotonic_time(:millisecond)
      probe_result = SandboxPool.claim(0, pool)
      t_probe = System.monotonic_time(:millisecond) - probe_started_at

      assert_receive {:claimed, :w, w_result, t_b}, claim_rendezvous_timeout(60_000)

      # (a) PREMISE, checked first -- same shape, same threshold and same rationale as
      # RT-2(a), reusing the SAME vacuity floor rather than deriving a second one. Without
      # it the ratio in (c) goes green pre-fix on a host that provisions fast enough.
      if t_b < @vacuity_floor_ms do
        flunk(
          "RT-7 premise (a) failed: W's claim latency was #{t_b} ms, below the " <>
            "#{@vacuity_floor_ms} ms vacuity floor. See design §10.4 -- below this floor " <>
            "the defect cannot exist and (c) would pass vacuously."
        )
      end

      # (b)
      assert probe_result == {:error, :sandbox_unavailable}
      assert {:ok, %SandboxClaim{}} = w_result

      # (c) THE LOAD-BEARING FAIL-FIRST. Ratio of two quantities measured inside this same
      # test; no constant. Pre-fix the probe sits in the blocked mailbox for a full
      # provisioning (measured 369-1129 ms, against a t_b only ~60 ms larger); post-fix
      # the measured probe latency is 0 ms.
      assert 4 * t_probe < t_b,
             "RT-7(c) failed: t_probe = #{t_probe} ms against t_b = #{t_b} ms. A " <>
               "claim(0) against an exhausted pool touches no database at all, so its " <>
               "latency must not track a concurrent provisioning's -- the pool's mailbox " <>
               "is blocked while a provisioning runs. See design §1.1, §10.3."

      send(w, :release)
      assert_receive {:released, :w, :ok}, pool_op_rendezvous_timeout()

      assert sandbox_schema_names() == baseline
      assert Process.alive?(pool)
    end

    test "RT-8 (death path e): an owner that dies on top of its own release-DROP retargets that DROP instead of enqueuing a second one" do
      # POST-FIX-ONLY: pre-fix there is no db_queue and no deferred DROP at all, so the
      # scenario has no pre-fix analogue. No fail-first weight. Its job is to prove that
      # design §7 step 3 clause B CASE 4b is what runs -- not the case-5 reclaim
      # fall-through, which would delete the `active` entry AND enqueue a second drop for
      # the same schema.
      baseline = sandbox_schema_names()
      on_exit(fn -> drop_sandbox_schemas_created_since!(baseline) end)

      pool = start_pool!(max_concurrent: 2)

      o1 = spawn_claimer(pool, :o1, 0)

      assert_receive {:claimed, :o1, {:ok, %SandboxClaim{sandbox_id: o1_id}}, _t_o1},
                     claim_rendezvous_timeout(0)

      # A's provisioning owns the single worker for >= 411 ms, which is what makes the
      # window below wide and the state stable enough to read directly rather than race.
      a = spawn_claimer(pool, :a, 0)
      wait_until_pool_state(pool, "A's provisioning is in flight", &provision_in_flight?/1)

      # O1 calls release/2 ITSELF (same-process contract) and blocks in its own
      # GenServer.call; the DROP is scheduled behind A's provisioning.
      send(o1, :release)

      wait_until_pool_state(pool, "O1's release-DROP is scheduled", fn s ->
        drop_ops_for_sandbox(s, o1_id) != []
      end)

      Process.exit(o1, :kill)

      state =
        wait_until_pool_state(pool, "the pool has processed O1's :DOWN", fn s ->
          not Map.has_key?(s.active, o1_id)
        end)

      # NO DUPLICATE DROP -- the direct assertion against the case-5 fall-through, and a
      # deterministic read rather than a timing observation: A is still provisioning, so
      # the pool is quiescent. Counted over db_queue UNION in_flight.op.
      drops = drop_ops_for_sandbox(state, o1_id)

      assert length(drops) == 1,
             "expected exactly one scheduled DROP for O1's sandbox, got " <>
               "#{length(drops)}: #{inspect(drops)}. Two means the :DOWN fell through to " <>
               "the reclaim path and enqueued a second drop alongside the release-DROP " <>
               "that was already scheduled (design §7 step 3 case 4b, §11 item 17)."

      assert [{:drop, %{purpose: :release_orphaned, from: nil, owner_ref: nil}}] = drops

      # The slot was freed in the :DOWN callback itself (INV-SP-DOWN-2/3), not deferred
      # to the DROP's completion.
      refute Map.has_key?(state.active, o1_id)

      # No reply is sent to the dead release caller.
      refute_received {:released, :o1, _}

      assert_receive {:claimed, :a, {:ok, %SandboxClaim{}}, _t_a}, claim_rendezvous_timeout(0)
      send(a, :release)
      assert_receive {:released, :a, :ok}, pool_op_rendezvous_timeout()

      drained = wait_until_pool_state(pool, "the pool drains", &pool_drained?/1)
      assert drained.in_flight == nil
      assert :queue.is_empty(drained.db_queue)

      # NO SCHEMA LEAK: O1's schema was dropped exactly once, A's on release.
      assert sandbox_schema_names() == baseline

      # NO SLOT LEAK: both slots are back.
      assert {:ok, %SandboxClaim{sandbox_id: id1}} = SandboxPool.claim(0, pool)
      assert {:ok, %SandboxClaim{sandbox_id: id2}} = SandboxPool.claim(0, pool)
      assert :ok = SandboxPool.release(id1, pool)
      assert :ok = SandboxPool.release(id2, pool)

      # THE POOL IS ALIVE -- it never crashed replying to a dead caller.
      assert Process.alive?(pool)
    end
  end
end
