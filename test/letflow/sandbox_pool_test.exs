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
  # enough. 400 attempts * 5ms = up to 2s, well past a single message-passing
  # round-trip (design doc INV-SP-DOWN-2's own stated bound).
  defp wait_until_schema_dropped(schema_name, attempts \\ 400)

  defp wait_until_schema_dropped(schema_name, 0) do
    flunk(
      "expected schema #{schema_name} to be dropped by SandboxPool's owner-crash " <>
        "reclaim, but it still exists in information_schema.schemata"
    )
  end

  defp wait_until_schema_dropped(schema_name, attempts) do
    if schema_exists?(schema_name) do
      Process.sleep(5)
      wait_until_schema_dropped(schema_name, attempts - 1)
    else
      :ok
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
            3_000 -> flunk("test process never signalled release for the waiter claim")
          end

          assert :ok = SandboxPool.release(waiter_claim.sandbox_id, pool)

          waiter_claim
        end)

      wait_until_waiter_queued(pool)

      assert :ok = SandboxPool.release(held_id, pool)
      refute schema_exists?(held_schema)

      assert_receive {:waiter_claimed,
                      %SandboxClaim{sandbox_id: waiter_id, schema_name: waiter_schema}},
                     3_000

      on_exit(fn -> drop_schema!(waiter_schema) end)

      assert waiter_id != held_id
      assert schema_exists?(waiter_schema)

      send(waiter.pid, :release_waiter_claim)

      assert %SandboxClaim{sandbox_id: ^waiter_id} = Task.await(waiter, 3_000)
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
                      2_000

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
end
