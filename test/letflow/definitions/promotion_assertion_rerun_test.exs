defmodule Letflow.Definitions.PromotionAssertionRerunTest do
  @moduledoc """
  Tests for `Letflow.Definitions.apply_promotion_assertion_rerun/6` (REQ-040, PRM-06/07).
  See `test/specs/REQ-040.md` for the full test-case rationale and
  `lib/letflow/design/req040-promotion-assertion-rerun.md` for the gate-approved design
  this file exercises.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 -- no mocked database, and no mocked `Letflow.SandboxPool`, anywhere in
  this file. Where a test needs a real infrastructure failure (a release that fails, an
  exhausted claim quota, a disallowed fixture table), it drives the REAL `SandboxPool`/
  `FixtureLoader` into that failure rather than stubbing a canned error return.

  ## Fixture strategy -- mirrors `rollback_test.exs`'s and `sandbox_pool_test.exs`'s
  established patterns, not a new mechanism

  `apply_promotion_assertion_rerun/6` lives directly on `Letflow.Definitions` (design
  §1) and internally calls `Ecto.Migrator.run/4` (via `SandboxPool.claim/2`'s own
  provisioning sequence, REQ-039), so this file follows `rollback_test.exs`'s
  `provisioned_tenant/0` convention (switches `Letflow.Repo` to Sandbox `:auto` mode
  internally, real `CREATE SCHEMA` + `TenantProvisioning.replay_migrations/1`) combined
  with `sandbox_pool_test.exs`'s `start_pool!/1` convention (an isolated,
  `System.unique_integer/1`-suffixed `SandboxPool` instance per test, never the
  application singleton -- design doc req039 §4.7 INV-SP-7). `async: false` for the
  same reason both of those files are (switching `Letflow.Repo`'s sandbox mode mid-test
  cannot safely run concurrently with another `async: true` test file).

  ## Three claim-count / mid-flight-observation techniques used below

  `apply_promotion_assertion_rerun/6` runs synchronously start-to-finish and never
  returns control to the caller mid-call, so proving something about its INTERNAL
  behavior (not just its final return value) needs an injection point. This file uses
  three, all via the one genuinely test-controllable hook the function exposes,
  `opts[:assertion_evaluator]` (design §3: optional, defaults to a placeholder when
  omitted), plus the pool's own `:sys.get_state/1` (the same primitive
  `sandbox_pool_test.exs`'s own `wait_until_waiter_queued/2` already uses in this
  codebase):

  1. **Claim-count proof (AC1) -- pool-quota exhaustion, not tracing.** A dedicated pool
     started with `max_concurrent: 1`. After call 1 completes (claims, replays,
     releases -- pool back to 0/1 active), the test claims the pool's own single slot
     directly, fully exhausting it, THEN makes call 2. If the idempotent-hit path ever
     attempted a second `SandboxPool.claim/2`, that call would immediately fail
     `{:error, :sandbox_unavailable}` (deterministic with `max_wait_ms: 0`) and
     propagate as this function's own `{:error, _}` return -- so call 2 returning the
     cached `{:ok, result}` IS the claim-count proof.
  2. **Mid-replay sandbox inspection (AC2, and both teardown-failure tests) -- a custom
     `assertion_evaluator` reads the pool's live state via `:sys.get_state/1` to learn
     the currently-claimed `sandbox_id` (reliable: the evaluator runs only *after*
     `claim/2` has already returned `{:ok, claim}`, so that claim is in `active` and no
     DB work is in flight, and each test's dedicated pool is driven by a single
     synchronous caller that never produces a second concurrent claim -- so `active`
     holds exactly one entry. Since ISS-0224 the pool runs its DB work in a serialized
     worker rather than inside its own callbacks, which is why the reason is stated as
     "after the claim was granted" rather than the older "the whole call is
     synchronous": the call is still synchronous from the caller's side, but that is no
     longer what makes this read reliable), then either queries the sandbox schema's
     own real Postgres row set directly (AC2), or calls the REAL
     `SandboxPool.release/2` itself, once, from
     inside the evaluator -- genuinely triggering the exact `{:error, :not_found}`
     `finish_replay/8`'s own subsequent Step 5 release call then observes.
  3. **Real-exception injection (try/rescue span) -- a custom `assertion_evaluator`
     that raises.** Since the evaluator runs inside `run_replay_span/8`'s own `try`
     body, a `raise` from it is a genuine, unhandled exception at exactly the point
     design §2.3's `try/rescue` decision exists to catch.

  Every test provisions its own tenant (`provisioned_tenant/0`) and its own isolated
  `SandboxPool` (`start_pool!/1`) -- no shared or hard-coded identifiers, no test
  depends on another test's data or execution order, no wall-clock dependency anywhere
  (`rng_seed` is the fixed literal `fixed_rng_seed/0`, never derived from
  `System.os_time`; the "double-run non-determinism" tests construct their own
  deliberate non-determinism via a process-scoped call counter, not real randomness).

  `opts[:event_appender]` is supplied explicitly on every DB-touching call
  (`Keyword.fetch!/2`, no built-in default, design §3/§9) -- mirrors
  `rollback_test.exs`'s `recording_event_appender/1` (records what it was called with
  by sending a message to the test process) and `exploding_event_appender/0` (raises if
  invoked -- proves, not merely asserts, that a path never calls it).
  """

  use Letflow.DataCase, async: false

  alias Letflow.Definitions
  alias Letflow.Definitions.PromotionArtifact
  alias Letflow.Definitions.PromotionArtifact.Assertion
  alias Letflow.Definitions.PromotionAssertionRun
  alias Letflow.Definitions.PromotionDigest
  alias Letflow.Definitions.PromotionReviewStore
  alias Letflow.SandboxPool
  alias Letflow.SandboxPool.FixtureLoader.FixtureRow
  alias Letflow.SandboxPool.SandboxClaim

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- tenant + schema provisioning
  # ---------------------------------------------------------------------------------

  # Kept deliberately, even though `provisioned_tenant/0` below no longer calls it: the
  # `SandboxPool`-held schema at the "held sandbox" test's `on_exit` is NOT a
  # `TenantFixture` tenant and still needs its own drop (ISS-0109 design §5, §9 item 6).
  defp drop_schema!(schema_name) do
    Repo.query!(~s(DROP SCHEMA IF EXISTS "#{schema_name}" CASCADE))
  end

  # Adopts the shared `Letflow.TenantFixture` (ISS-0109 / GH#358) in place of this
  # file's own hand-rolled `insert_tenant!/0` + `provisioned_tenant/0` copies.
  # Behaviour-preserving by construction (design §7.7): the same tenant row is inserted,
  # the same sandbox `:auto` switch is made, the same schema is provisioned, the same
  # replay is run, and the same three teardown statements are issued in the same order
  # -- the fixture additionally asserts the resulting schema is COMPLETE (so a missing
  # `promotion_assertion_runs` is named here rather than surfacing 500 lines later as an
  # opaque 42P01) and emits one greppable `LETFLOW_TENANT_FIXTURE phase=teardown` line,
  # so a post-test drop can never again be mistaken for a mid-test one.
  defp provisioned_tenant do
    # Design §10.8.2.2: this file's own AC1 test drives a real second
    # `SandboxPool.claim/2` (line ~462) whose migrator work needs `Letflow.Repo` in
    # `:auto` mode -- a window `provisioned_tenant!/1` no longer opens ambiently since
    # §10.3.2 step 1. Safe here, and only here, because this module is `async: false`
    # (line 81): ExUnit never schedules it concurrently with an `async: true` file, so
    # this deliberate, un-restored mode call cannot reach an ISS-0480-style victim.
    Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)

    Letflow.TenantFixture.provisioned_tenant!(
      slug_prefix: "req040-assertion-rerun",
      display_name: "REQ-040 Assertion Rerun Test Tenant"
    )
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- isolated SandboxPool instance per test (req039 §4.7 INV-SP-7)
  # ---------------------------------------------------------------------------------

  defp start_pool!(opts) do
    name = :"req040_assertion_rerun_test_pool_#{System.unique_integer([:positive, :monotonic])}"
    {:ok, pid} = SandboxPool.start_link(Keyword.put_new(opts, :name, name))
    # ISS-0452: tolerate the process already being gone. It is linked to
    # the test process via start_link/1, and on_exit runs after that
    # process exits, so it may already be terminating -- check-then-act
    # races and exits :shutdown from the teardown.
    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  defp schema_exists?(schema_name) do
    %{rows: rows} =
      Repo.query!("SELECT 1 FROM information_schema.schemata WHERE schema_name = $1", [
        schema_name
      ])

    rows != []
  end

  defp schema_name_for_sandbox_id(sandbox_id) do
    "sandbox_" <> String.replace(sandbox_id, "-", "")
  end

  defp sandbox_process_definition_ids(schema_name) do
    %{rows: rows} =
      Repo.query!(~s(SELECT "id"::text FROM "#{schema_name}"."process_definitions" ORDER BY "id"))

    List.flatten(rows)
  end

  # Reads the sandbox_id of the ONE claim currently held by `pool` -- reliable because
  # this helper only ever runs inside an assertion_evaluator, which
  # apply_promotion_assertion_rerun/6 invokes AFTER SandboxPool.claim/2 has already
  # returned {:ok, claim}: that claim is therefore in `active`, no DB work is in flight,
  # and the single synchronous caller driving each test's dedicated max_concurrent: 1
  # pool never produces a second concurrent claim -- so `active` holds exactly one entry.
  #
  # (Before ISS-0224 this was justified with "the whole call is synchronous". The call
  # still IS synchronous from the caller's side; what changed is that the pool now runs
  # provisioning and dropping in a serialized worker Task instead of inside its own
  # callbacks, so "synchronous" is no longer the property this read rests on. The
  # partial map match below is also what keeps it working across that change: it ignores
  # the two new `db_queue` / `in_flight` siblings, and `active`'s key set and value shape
  # are unchanged.)
  #
  # Same :sys.get_state/1 primitive sandbox_pool_test.exs's own wait_until_waiter_queued/2
  # already uses in this codebase.
  defp active_sandbox_id!(pool) do
    %{active: active} = :sys.get_state(pool)

    case Map.keys(active) do
      [sandbox_id] ->
        sandbox_id

      other ->
        flunk("expected exactly one active sandbox claim in the pool, got: #{inspect(other)}")
    end
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- promotion_reviews (the FK target)
  # ---------------------------------------------------------------------------------

  defp unique_process_key(prefix \\ "req040-assertion-rerun-proc") do
    prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp sample_plan(tenant_id, process_key) do
    %{
      source_tenant_id: Ecto.UUID.generate(),
      target_tenant_id: tenant_id,
      process_key: process_key,
      source_definition_id: Ecto.UUID.generate(),
      target_definition_id: nil,
      base_version: nil,
      entries: [
        %{
          type: :graph_node,
          id: "n-#{System.unique_integer([:positive, :monotonic])}",
          change_kind: :added,
          before: nil,
          after: %{"id" => "n1", "node_type" => "START"}
        }
      ]
    }
  end

  defp digest_for(plan), do: PromotionDigest.compute_plan_digest(plan)

  # pending_review, via the real insert_review/2 (never a raw Repo.insert!).
  defp review_pending!(schema_name, tenant_id, process_key \\ nil) do
    process_key = process_key || unique_process_key()
    plan = sample_plan(tenant_id, process_key)
    digest = digest_for(plan)

    assert {:ok, review} =
             PromotionReviewStore.insert_review(
               %{plan: plan, digest: digest, requested_by: Ecto.UUID.generate()},
               prefix: schema_name
             )

    review
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- organic tenant-schema process_definitions row (AC2 only)
  # ---------------------------------------------------------------------------------

  defp valid_graph do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [%{"id" => "e1", "source" => "start", "target" => "end"}]
    }
  end

  defp create_organic_definition!(schema_name) do
    attrs = %{
      name: unique_process_key("req040-organic"),
      version: "1.0.0",
      graph: valid_graph(),
      created_by: Ecto.UUID.generate()
    }

    assert {:ok, definition} = Definitions.create(attrs, prefix: schema_name)
    definition
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- PromotionArtifact / assertions / fixture rows
  # ---------------------------------------------------------------------------------

  # A fixed literal (upper 32 bits = a fixed epoch-seconds value, lower 32 bits = a
  # fixed nonce) -- never System.os_time/1 or :rand -- so no test in this file depends
  # on wall-clock time or unseeded randomness (docs/guides/test_developer_guide.md §1).
  defp fixed_rng_seed, do: 1_700_000_000 * 4_294_967_296 + 424_242

  # `payload` doubles as the "result" text the default evaluator (and any custom
  # evaluator built on default_style_result/1 below) echoes back verbatim on a
  # non-empty payload -- which then flows into strip_non_deterministic_fields/2's own
  # `Jason.decode!/1` call (design §6.1 step f). A non-empty payload therefore MUST be
  # valid JSON text, never an arbitrary string -- this default and every non-empty
  # override in this file use a real encoded JSON object for that reason.
  defp assertion(overrides \\ %{}) do
    base = %{
      id: "req040-assertion-#{System.unique_integer([:positive, :monotonic])}",
      payload: Jason.encode!(%{"result" => "expected"})
    }

    attrs = Map.merge(base, overrides)
    %Assertion{id: attrs.id, payload: attrs.payload}
  end

  # All NOT NULL process_definitions columns with no DB-level default are supplied
  # explicitly -- jsonb_populate_record/2 fills any field missing from the JSON with
  # NULL, not the target table's column DEFAULT -- mirrors
  # fixture_loader_test.exs's valid_process_definition_json/1 exactly.
  defp valid_process_definition_fixture_row(overrides \\ %{}) do
    now =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:microsecond)
      |> NaiveDateTime.to_iso8601()

    row_json =
      %{
        "id" => Ecto.UUID.generate(),
        "tenant_id" => Ecto.UUID.generate(),
        "name" => "req040-fixture-#{System.unique_integer([:positive, :monotonic])}",
        "version" => "1.0.0",
        "status" => "draft",
        "graph" => %{"nodes" => [], "edges" => []},
        "created_by" => Ecto.UUID.generate(),
        "created_at" => now,
        "updated_at" => now
      }
      |> Map.merge(overrides)
      |> Jason.encode!()

    %FixtureRow{table_name: "process_definitions", row_json: row_json}
  end

  defp artifact(overrides \\ %{}) do
    base = %{
      id: "req040-artifact-#{System.unique_integer([:positive, :monotonic])}",
      assertions: [assertion()],
      fixtures: [valid_process_definition_fixture_row()],
      rng_seed: fixed_rng_seed(),
      non_deterministic_fields: [],
      candidate_definitions: []
    }

    attrs = Map.merge(base, overrides)

    %PromotionArtifact{
      id: attrs.id,
      assertions: attrs.assertions,
      fixtures: attrs.fixtures,
      rng_seed: attrs.rng_seed,
      non_deterministic_fields: attrs.non_deterministic_fields,
      candidate_definitions: attrs.candidate_definitions
    }
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- event_appender doubles (real function values, no mock lib)
  # ---------------------------------------------------------------------------------

  defp recording_event_appender(test_pid) do
    fn event_attrs, prefix ->
      send(test_pid, {:event_appended, event_attrs, prefix})
      {:ok, %{event_id: Ecto.UUID.generate()}}
    end
  end

  defp exploding_event_appender do
    fn _event_attrs, _prefix ->
      raise "event_appender must not be called on this path"
    end
  end

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers -- custom assertion_evaluator doubles (technique 2/3 above)
  # ---------------------------------------------------------------------------------

  # Default-placeholder-equivalent pass/fail rule (design §6.1 step h), reused by every
  # custom evaluator below that also needs a side effect but must otherwise behave
  # exactly like default_assertion_evaluator/2 for a fair replay outcome.
  defp default_style_result(%Assertion{payload: payload}) do
    if byte_size(payload) > 0, do: {:ok, payload}, else: {:ok, "{}"}
  end

  # On its FIRST invocation only, reads the sandbox_id currently claimed by `pool` and
  # calls the REAL SandboxPool.release/2 for it -- genuinely dropping the schema and
  # freeing the pool slot mid-replay, so finish_replay/8's own SUBSEQUENT Step 5
  # release call (finalize_and_write/10) gets a real {:error, :not_found}. No mocking
  # of SandboxPool anywhere -- this triggers SandboxPool's own actual "unknown
  # sandbox_id" branch (sandbox_pool.ex's handle_call({:release, ...})).
  defp evaluator_releasing_sandbox_once(pool) do
    fn assertion, _injection ->
      unless Process.get(:req040_already_released) do
        Process.put(:req040_already_released, true)
        sandbox_id = active_sandbox_id!(pool)
        SandboxPool.release(sandbox_id, pool)
      end

      default_style_result(assertion)
    end
  end

  # On its FIRST invocation only, snapshots the sandbox's own process_definitions row
  # set (a real Postgres query against the sandbox schema) and reports it back to the
  # test process -- while the sandbox still exists (before Step 5 drops it).
  defp evaluator_snapshotting_sandbox_rows(pool, test_pid) do
    fn assertion, _injection ->
      unless Process.get(:req040_already_snapshotted) do
        Process.put(:req040_already_snapshotted, true)
        sandbox_id = active_sandbox_id!(pool)
        schema_name = schema_name_for_sandbox_id(sandbox_id)
        send(test_pid, {:sandbox_snapshot, sandbox_process_definition_ids(schema_name)})
      end

      default_style_result(assertion)
    end
  end

  defp evaluator_raising do
    fn _assertion, _injection -> raise "simulated evaluator crash" end
  end

  # Deliberately non-deterministic ACROSS the two same-seed replay calls
  # replay_single_assertion/5 makes for a single assertion: its "metadata.nonce" field
  # increments on every call (a per-process counter, NOT derived from `injection`'s
  # frozen_clock_ms/rng_seed) -- models an evaluator reading some OTHER
  # non-deterministic source the frozen-seed reset cannot protect against. "stable" is
  # always the fixed string "fixed-value".
  defp evaluator_with_changing_nonce do
    fn _assertion, _injection ->
      count = Process.get(:req040_call_count, 0) + 1
      Process.put(:req040_call_count, count)
      {:ok, Jason.encode!(%{"metadata" => %{"nonce" => count}, "stable" => "fixed-value"})}
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1: "calling apply_promotion_assertion_rerun/6 twice with the same (review_id,
  # plan_digest) returns the cached outcome on the second call and claims no second
  # sandbox, verified by sandbox claim count"
  # ---------------------------------------------------------------------------------

  describe "AC1 -- idempotent replay, no second sandbox claim" do
    test "cached outcome on 2nd call; proven via exhausted pool quota" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      art = artifact()
      test_pid = self()

      pool = start_pool!(max_concurrent: 1)

      assert {:ok, result1} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(test_pid)
               )

      assert result1.idempotent_hit == false
      assert result1.status == :passed
      assert is_binary(result1.sandbox_id)
      assert result1.assertions_total == 1
      assert result1.assertions_passed == 1
      assert result1.assertions_failed == 0

      # A normal successful teardown never calls event_appender.
      refute_receive {:event_appended, _, _}, 50

      # Persistence check -- re-read from Postgres, not the in-memory reply.
      persisted =
        Repo.get!(PromotionAssertionRun, result1.run_id, prefix: schema_name)

      assert persisted.status == :passed
      assert persisted.sandbox_id == result1.sandbox_id

      # Fully exhaust the pool's own single slot -- any second real claim attempt from
      # here on must fail immediately.
      assert {:ok, %SandboxClaim{sandbox_id: held_id, schema_name: held_schema}} =
               SandboxPool.claim(0, pool)

      # A schema-drop fallback, not a SandboxPool.release/2 call -- ExUnit runs
      # on_exit/1 callbacks in registration order, so start_pool!/1's own
      # "GenServer.stop(pid)" on_exit (registered earlier, above) would already have
      # torn down the pool process by the time this one ran, making a release call
      # here fail with "no process". Mirrors sandbox_pool_test.exs's/
      # fixture_loader_test.exs's own established defensive-cleanup idiom.
      on_exit(fn -> drop_schema!(held_schema) end)

      assert {:ok, result2} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 # max_wait_ms: 0 -- a real second claim attempt against the now-fully
                 # exhausted pool would fail immediately and deterministically.
                 pool,
                 0,
                 prefix: schema_name,
                 # If the idempotent-hit path incorrectly called event_appender for
                 # any reason, this proves it via a crash rather than a missed
                 # assertion.
                 event_appender: exploding_event_appender()
               )

      assert result2.idempotent_hit == true
      assert result2.run_id == result1.run_id
      assert result2.sandbox_id == result1.sandbox_id
      assert result2.status == result1.status
      assert result2.assertions_total == result1.assertions_total
      assert result2.assertions_passed == result1.assertions_passed
      assert result2.assertions_failed == result1.assertions_failed
      assert result2.teardown_event_appended == true

      assert :ok = SandboxPool.release(held_id, pool)
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2: "a sandbox loaded via REQ-039 receives ONLY the artifact's fixtures[] rows,
  # demonstrated by confirming no pre-existing tenant data appears in the sandbox
  # schema"
  # ---------------------------------------------------------------------------------

  describe "AC2 -- sandbox receives only artifact fixtures" do
    test "organic tenant row absent; only the fixture row lands in the sandbox" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()

      # Organic tenant data, unrelated to this artifact -- created via the real
      # state-machine function, never a raw insert, and NEVER referenced by the
      # artifact below.
      organic = create_organic_definition!(schema_name)

      fixture_id = Ecto.UUID.generate()
      review = review_pending!(schema_name, tenant_id)

      art =
        artifact(%{
          fixtures: [valid_process_definition_fixture_row(%{"id" => fixture_id})]
        })

      test_pid = self()
      pool = start_pool!(max_concurrent: 2)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(test_pid),
                 assertion_evaluator: evaluator_snapshotting_sandbox_rows(pool, test_pid)
               )

      assert result.status == :passed

      assert_receive {:sandbox_snapshot, sandbox_ids}, 1_000

      # The core AC2 assertion: ONLY the artifact's own fixture row landed in the
      # sandbox -- the organic tenant-schema row's id is absent.
      assert sandbox_ids == [fixture_id]
      refute organic.id in sandbox_ids
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 (first half): "an assertion replay that fails records status = failed with a
  # non-empty failing_assertion_ids list"
  # ---------------------------------------------------------------------------------

  describe "AC3a -- failing replay records :failed" do
    test "empty payload replays consistently but counts as failed" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      failing = assertion(%{payload: ""})
      art = artifact(%{assertions: [failing]})
      pool = start_pool!(max_concurrent: 2)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(self())
               )

      assert result.status == :failed
      assert result.assertions_total == 1
      assert result.assertions_passed == 0
      assert result.assertions_failed == 1
      assert result.failing_assertion_ids == [failing.id]

      persisted = Repo.get!(PromotionAssertionRun, result.run_id, prefix: schema_name)
      assert persisted.status == :failed
      assert persisted.failing_assertion_ids == [failing.id]
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 (second half) + AC5: "a passing replay whose teardown itself fails records
  # status = teardown_failed with assertions_failed = 0" / "a simulated teardown
  # failure appends a PROMOTION_ASSERTION_TEARDOWN_FAILED event via REQ-025's append
  # and does not change a passing run's outcome from green to failed"
  # ---------------------------------------------------------------------------------

  describe "AC3b + AC5 -- teardown failure is a green gate" do
    test "real release failure -> :teardown_failed, assertions_failed 0, event appended once" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      passing = assertion(%{payload: Jason.encode!(%{"result" => "a-real-passing-result"})})
      art = artifact(%{assertions: [passing]})
      test_pid = self()
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(test_pid),
                 assertion_evaluator: evaluator_releasing_sandbox_once(pool)
               )

      assert result.status == :teardown_failed
      assert result.assertions_total == 1
      assert result.assertions_passed == 1
      # The real replay genuinely found zero failures -- INV-AR-6.
      assert result.assertions_failed == 0
      assert result.failing_assertion_ids == []
      assert is_binary(result.teardown_error)
      assert result.teardown_event_appended == true

      assert_receive {:event_appended, event_attrs, received_prefix}, 1_000
      assert received_prefix == schema_name
      assert event_attrs.event_type == "PROMOTION_ASSERTION_TEARDOWN_FAILED"
      assert event_attrs.run_id == result.run_id
      assert event_attrs.sandbox_id == result.sandbox_id
      assert event_attrs.tenant_id == tenant_id
      assert is_binary(event_attrs.error)

      # Exactly one event appended.
      refute_receive {:event_appended, _, _}, 50

      persisted = Repo.get!(PromotionAssertionRun, result.run_id, prefix: schema_name)
      assert persisted.status == :teardown_failed
      assert persisted.assertions_failed == 0
    end
  end

  # ---------------------------------------------------------------------------------
  # INV-AR-6 companion (not itself a named AC): a teardown failure never PROMOTES an
  # already-failed run into :teardown_failed -- only ever demotes a :passed one.
  # ---------------------------------------------------------------------------------

  describe "INV-AR-6 -- failed replay stays :failed after teardown failure" do
    test "release failure after a failing replay stays :failed, event still appended" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      failing = assertion(%{payload: ""})
      art = artifact(%{assertions: [failing]})
      test_pid = self()
      pool = start_pool!(max_concurrent: 1)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(test_pid),
                 assertion_evaluator: evaluator_releasing_sandbox_once(pool)
               )

      assert result.status == :failed
      assert result.assertions_failed == 1
      assert result.failing_assertion_ids == [failing.id]

      assert_receive {:event_appended, event_attrs, _prefix}, 1_000
      assert event_attrs.event_type == "PROMOTION_ASSERTION_TEARDOWN_FAILED"

      persisted = Repo.get!(PromotionAssertionRun, result.run_id, prefix: schema_name)
      assert persisted.status == :failed
    end
  end

  # ---------------------------------------------------------------------------------
  # Double-run self-consistency check (not an oracle comparison) -- extra coverage
  # this run's task briefing specifically flagged.
  # ---------------------------------------------------------------------------------

  describe "double-run self-consistency check" do
    test "changing nonce, undeclared -> failed with the assertion's id" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      flaky = assertion(%{payload: "non-empty-so-only-the-mismatch-path-can-fail-this"})
      art = artifact(%{assertions: [flaky], non_deterministic_fields: []})
      pool = start_pool!(max_concurrent: 2)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(self()),
                 assertion_evaluator: evaluator_with_changing_nonce()
               )

      assert result.status == :failed
      assert result.failing_assertion_ids == [flaky.id]
    end

    test "changing nonce, declared -> stripped and passes" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      flaky = assertion(%{payload: "non-empty-so-only-the-mismatch-path-can-fail-this"})
      art = artifact(%{assertions: [flaky], non_deterministic_fields: ["metadata.nonce"]})
      pool = start_pool!(max_concurrent: 2)

      assert {:ok, result} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: recording_event_appender(self()),
                 assertion_evaluator: evaluator_with_changing_nonce()
               )

      assert result.status == :passed
      assert result.failing_assertion_ids == []
    end
  end

  # ---------------------------------------------------------------------------------
  # fail_closed_counts/1: infrastructure failures never leave assertions_failed == 0
  # or a row stuck at :running -- extra coverage this run's task briefing flagged.
  # ---------------------------------------------------------------------------------

  describe "fail_closed_counts/1 on infrastructure failures" do
    test "exhausted pool -> :failed, assertions_failed 1, sandbox_id nil" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      only = assertion()
      art = artifact(%{assertions: [only]})
      pool = start_pool!(max_concurrent: 0)

      assert {:error, :sandbox_unavailable} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 0,
                 prefix: schema_name,
                 event_appender: exploding_event_appender()
               )

      persisted = Repo.get_by!(PromotionAssertionRun, [review_id: review.id], prefix: schema_name)
      assert persisted.status == :failed
      assert persisted.sandbox_id == nil
      assert persisted.assertions_total == 1
      assert persisted.assertions_failed == 1
      assert persisted.failing_assertion_ids == [only.id]
      assert persisted.completed_at != nil
    end

    test "exhausted pool + zero assertions -> sentinel id" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      art = artifact(%{assertions: []})
      pool = start_pool!(max_concurrent: 0)

      assert {:error, :sandbox_unavailable} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 0,
                 prefix: schema_name,
                 event_appender: exploding_event_appender()
               )

      persisted = Repo.get_by!(PromotionAssertionRun, [review_id: review.id], prefix: schema_name)
      assert persisted.status == :failed
      assert persisted.assertions_total == 0
      assert persisted.assertions_failed == 1
      assert persisted.failing_assertion_ids == ["__infrastructure_failure__"]
      assert persisted.completed_at != nil
    end

    test "disallowed fixture table -> :failed, sandbox released anyway" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)

      art =
        artifact(%{
          fixtures: [
            %FixtureRow{table_name: "not_on_the_allowlist", row_json: Jason.encode!(%{})}
          ]
        })

      pool = start_pool!(max_concurrent: 2)

      assert {:error, :fixture_load_failed} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: exploding_event_appender()
               )

      persisted = Repo.get_by!(PromotionAssertionRun, [review_id: review.id], prefix: schema_name)
      assert persisted.status == :failed
      assert persisted.assertions_failed >= 1
      assert persisted.completed_at != nil
      # The sandbox WAS claimed on this path (unlike the claim-failure tests above).
      assert is_binary(persisted.sandbox_id)

      # The claimed sandbox was still genuinely released despite the failure -- a
      # real Postgres query, not trusting the function's own return value.
      refute schema_exists?(schema_name_for_sandbox_id(persisted.sandbox_id))
    end
  end

  # ---------------------------------------------------------------------------------
  # try/rescue crash safety, proven not asserted -- extra coverage this run's task
  # briefing flagged.
  # ---------------------------------------------------------------------------------

  describe "try/rescue crash safety" do
    test "raising evaluator -> {:error, {:transaction_failed, _}}, fail-closed row" do
      %{tenant_id: tenant_id, schema_name: schema_name} = provisioned_tenant()
      review = review_pending!(schema_name, tenant_id)
      art = artifact()
      pool = start_pool!(max_concurrent: 2)

      assert {:error, {:transaction_failed, exception}} =
               Definitions.apply_promotion_assertion_rerun(
                 review.id,
                 review.plan_digest,
                 art,
                 pool,
                 2_000,
                 prefix: schema_name,
                 event_appender: exploding_event_appender(),
                 assertion_evaluator: evaluator_raising()
               )

      assert %RuntimeError{message: "simulated evaluator crash"} = exception

      persisted = Repo.get_by!(PromotionAssertionRun, [review_id: review.id], prefix: schema_name)
      assert persisted.status == :failed
      assert persisted.assertions_failed == 1
      assert persisted.teardown_error =~ "assertion rerun crashed: simulated evaluator crash"
      assert persisted.completed_at != nil
      # The sandbox WAS claimed before the exception fired.
      assert is_binary(persisted.sandbox_id)

      # The rescue clause's best-effort release genuinely worked -- a real Postgres
      # query, not merely a plausible-looking error tuple.
      refute schema_exists?(schema_name_for_sandbox_id(persisted.sandbox_id))
    end
  end

  # ---------------------------------------------------------------------------------
  # opts[:event_appender] has no built-in default -- mirrors rollback_test.exs's
  # identical check for its own no-default hooks (design §3/§9).
  # ---------------------------------------------------------------------------------

  describe "event_appender has no default" do
    test "omitting event_appender raises KeyError" do
      art = artifact()

      assert_raise KeyError, fn ->
        Definitions.apply_promotion_assertion_rerun(
          Ecto.UUID.generate(),
          "irrelevant-plan-digest",
          art,
          self(),
          0,
          prefix: "irrelevant-prefix"
        )
      end
    end
  end
end
