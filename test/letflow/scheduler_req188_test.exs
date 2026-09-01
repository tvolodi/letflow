defmodule Letflow.SchedulerReq188Test do
  @moduledoc """
  Tests for REQ-188 Part 1 -- `Letflow.Scheduler.maybe_rearm_timer/3` (SCH-07
  recurring timers) -- plus the moduledoc-deferral-statement and
  `transition.ex`-untouched-by-REQ-188's-own-commit-range structural checks
  (see the dated UPDATE comment on that describe block: this guard is pinned
  to REQ-188's own historical commit range, not a live check against the
  current branch). See `test/specs/REQ-188.md` for
  the full acceptance-criterion -> test-case map and, importantly, the
  "Fixture strategy -- the gateway/loop graph" section explaining why firing a
  recurring timer more than once through the REAL, unmocked engine requires
  the `graph_gateway_loop/1` fixture below (a bare `:TIMER` self-loop is
  rejected by `Letflow.Definitions.Graph`'s CHK-06 cycle check).

  REQ-188 Part 2 (the periodic retention runner, ACs 5-7) is covered in
  `test/letflow/scheduler/poller_test.exs` instead, alongside REQ-186's own
  `Letflow.Scheduler.Poller` coverage, since retention lives on that same
  process.

  Design authority: `lib/letflow/design/req188-recurring-timers-and-retention.md`.
  Implementation authority: `lib/letflow/scheduler.ex`/`lib/letflow/scheduler/timer.ex`,
  which already passed SECURITY-REVIEWER and REVIEWER
  (`handoffs/WF02-REQ188-20260829/step-02c-security-reviewer.json`,
  `step-02d-reviewer.json`).

  Uses `Letflow.DataCase` (real Postgres) per
  `docs/guides/test_developer_guide.md` DIRECTIVE T-1 -- no mocked database,
  no mocking library exists in this codebase (`mix.exs` has no `mox`/`meck`).

  `async: false` for the same reason every other tenant-fixture-using test
  file in this codebase sets it (real schema creation/teardown against one
  shared Postgres instance).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Definitions
  alias Letflow.Engine
  alias Letflow.Engine.TokenRecord
  alias Letflow.Scheduler
  alias Letflow.Scheduler.Timer
  alias Letflow.TenantFixture

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp provisioned_tenant(slug_prefix \\ "req188-scheduler") do
    TenantFixture.provisioned_tenant!(
      slug_prefix: slug_prefix,
      display_name: "REQ-188 Scheduler Test Tenant"
    )
  end

  defp unique_name(prefix),
    do: prefix <> "-" <> to_string(System.unique_integer([:positive, :monotonic]))

  # START -> gw (EXCLUSIVE_GATEWAY) -> loop (TIMER) -> gw, plus an always-false
  # conditioned edge gw -> end (CHK-02 needs an END node; CHK-04 needs it
  # reachable). See test/specs/REQ-188.md's "Fixture strategy" section for why
  # this shape (a cycle through a gateway), not a bare TIMER self-loop, is
  # required (CHK-06 rejects an unguarded cycle).
  #
  # This fixture DOES also trigger REQ-187's own separate TIMER->TIMER
  # auto-rearm mechanism once per gw -> loop loop-back hop (each hop's
  # previous_node_id, per tokens_needing_dispatch/3, is local to that hop --
  # "gw" then, not the chain's original "loop" -- so the node id genuinely
  # changes and prepare_timer_arms/4 fires again). Verified empirically: 4
  # repeat_expression-nil Timer rows after AC2's 3 firings (1 creation-time
  # arm + 3 per-firing arms), not 1. This is harmless here: those arms never
  # set repeat_expression (excluded by every row-counting filter in this
  # file), their fire_at is always a day out (never due in any poll these
  # tests run), and they cannot collide with maybe_rearm_timer/3's own
  # :scheduler_timer Multi step since advance_after_timer_fired/3 commits its
  # own nested Multi before maybe_rearm_timer/3 runs its separate insert.
  defp graph_gateway_loop(duration \\ "P1D") do
    %{
      "nodes" => [
        %{"id" => "start", "node_type" => "START"},
        %{"id" => "gw", "node_type" => "EXCLUSIVE_GATEWAY"},
        %{
          "id" => "loop",
          "node_type" => "TIMER",
          "attributes" => %{"duration_iso8601" => duration}
        },
        %{"id" => "end", "node_type" => "END"}
      ],
      "edges" => [
        %{"id" => "e1", "source" => "start", "target" => "gw"},
        %{"id" => "e2", "source" => "gw", "target" => "loop", "is_default" => true},
        %{"id" => "e3", "source" => "loop", "target" => "gw"},
        %{
          "id" => "e4",
          "source" => "gw",
          "target" => "end",
          "condition" => "variables.does_not_exist == 1"
        }
      ]
    }
  end

  defp active_definition!(schema_name) do
    assert {:ok, definition} =
             Definitions.create(
               %{
                 name: unique_name("req188-def"),
                 version: "1.0.0",
                 graph: graph_gateway_loop(),
                 created_by: Ecto.UUID.generate()
               },
               prefix: schema_name
             )

    assert {:ok, %{definition: activated}} =
             Definitions.activate(definition.id, prefix: schema_name)

    activated
  end

  # Starts a real instance whose one live token is parked at the "loop" TIMER
  # node (the graph's own initial hop-chain: start -> gw -> loop, arming one
  # harmless REQ-187-style duration-based timer at "loop" that's never due --
  # see the moduledoc/spec's fixture-strategy note).
  defp start_looping_instance!(schema_name) do
    definition = active_definition!(schema_name)

    assert {:ok, result} =
             Engine.create(
               %{
                 definition_id: definition.id,
                 initial_variables: %{},
                 actor_id: Ecto.UUID.generate(),
                 idempotency_key: unique_name("req188-start")
               },
               prefix: schema_name
             )

    result.instance_id
  end

  defp live_token_id!(schema_name, instance_id) do
    TokenRecord
    |> where([t], t.instance_id == ^instance_id and t.status == :active)
    |> select([t], t.id)
    |> Repo.one!(prefix: schema_name)
    |> to_string()
  end

  defp past_fire_at(seconds_ago \\ 60) do
    DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:microsecond)
  end

  defp arm_recurring_timer!(schema_name, instance_id, token_id, overrides) do
    attrs =
      Map.merge(
        %{
          instance_id: instance_id,
          token_id: token_id,
          timer_type: "deadline",
          node_id: "loop",
          fire_at: past_fire_at()
        },
        overrides
      )

    assert {:ok, timer} = Scheduler.create(Letflow.Repo, attrs, prefix: schema_name)
    timer
  end

  # Counts only THIS requirement's own recurring chain rows -- filters out the
  # graph's own harmless REQ-187 duration-based side-arm at "loop", which
  # never sets repeat_expression (verified directly against
  # resolve_timer_arm_attrs/4 in lib/letflow/engine.ex).
  defp recurring_timer_count(schema_name, instance_id) do
    Timer
    |> where([t], t.instance_id == ^instance_id and not is_nil(t.repeat_expression))
    |> Repo.aggregate(:count, prefix: schema_name)
  end

  defp recurring_timers_other_than(schema_name, instance_id, timer_id) do
    Timer
    |> where(
      [t],
      t.instance_id == ^instance_id and t.id != ^timer_id and not is_nil(t.repeat_expression)
    )
    |> Repo.all(prefix: schema_name)
  end

  # ---------------------------------------------------------------------------------
  # AC1a -- "R/PT1H" re-arm: exactly one new pending row, fire_at = fired
  # timer's own fire_at + 1 hour (nominal anchor, not the actual firing time)
  # ---------------------------------------------------------------------------------

  describe "AC1: a fired R/PT1H recurring timer re-arms exactly one new pending row, anchored to its own scheduled fire_at" do
    test "creates exactly one new pending timer with fire_at = fired timer's fire_at + 1 hour" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_looping_instance!(schema_name)
      token_id = live_token_id!(schema_name, instance_id)
      original_fire_at = past_fire_at(120)

      timer =
        arm_recurring_timer!(schema_name, instance_id, token_id, %{
          fire_at: original_fire_at,
          repeat_expression: "R/PT1H",
          repeat_interval_us: 3_600_000_000,
          repeat_total: nil,
          fired_count: 0
        })

      assert recurring_timer_count(schema_name, instance_id) == 1

      assert {:ok, :fired} = Scheduler.fire_timer(timer.id, schema_name)

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "fired"

      assert recurring_timer_count(schema_name, instance_id) == 2

      assert [new_timer] = recurring_timers_other_than(schema_name, instance_id, timer.id)
      assert new_timer.status == "pending"
      assert new_timer.fired_count == 1
      assert new_timer.node_id == "loop"
      assert new_timer.token_id == token_id

      assert DateTime.compare(
               new_timer.fire_at,
               DateTime.add(original_fire_at, 3600, :second)
             ) == :eq
    end
  end

  # ---------------------------------------------------------------------------------
  # AC1b -- INV-REARM-1: the re-arm insert runs in the SAME transaction as the
  # firing. Forcing that transaction to roll back must leave NEITHER the
  # status change NOR the new timer persisted.
  # ---------------------------------------------------------------------------------

  describe "AC1: re-arm runs in the SAME transaction as the firing (INV-REARM-1)" do
    test "forcing the firing transaction to roll back leaves neither the status change nor the new timer persisted" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_looping_instance!(schema_name)
      token_id = live_token_id!(schema_name, instance_id)

      timer =
        arm_recurring_timer!(schema_name, instance_id, token_id, %{
          fire_at: past_fire_at(120),
          repeat_expression: "R/PT1H",
          repeat_interval_us: 3_600_000_000,
          repeat_total: nil,
          fired_count: 0
        })

      assert recurring_timer_count(schema_name, instance_id) == 1

      # fire_timer/2 opens its own Repo.transaction/1 -- nested here inside an
      # outer one this test controls. Ecto/DBConnection nest this as a real
      # Postgres SAVEPOINT (the same mechanism scheduler.ex's own comment
      # documents for advance_after_timer_fired/3's nested persistence step),
      # so rolling back the OUTER transaction after fire_timer/2 itself
      # reports success must undo everything it did, if and only if the
      # re-arm insert genuinely ran inside that same nested scope.
      outer =
        Repo.transaction(fn ->
          inner_result = Scheduler.fire_timer(timer.id, schema_name)
          Repo.rollback({:forced_test_rollback, inner_result})
        end)

      assert {:error, {:forced_test_rollback, {:ok, :fired}}} = outer

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "pending"
      assert reloaded.fired_at == nil

      assert recurring_timer_count(schema_name, instance_id) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC2 -- "R3/PT1H" stops re-arming after the 3rd firing (INV-REARM-2)
  # ---------------------------------------------------------------------------------

  describe "AC2: an R3/PT1H timer stops re-arming after its third firing" do
    test "fired_count reaches 3; a fourth poll creates no new timer, asserted by counting timers rows" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_looping_instance!(schema_name)
      token_id = live_token_id!(schema_name, instance_id)

      # A tiny interval (1ms), not the literal PT1H, so all 3 cycles run
      # instantly with no wall-clock wait -- repeat_interval_us is
      # test-controlled independently of repeat_expression's descriptive
      # text (REQ-188 design doc OQ-1: the repeat grammar is never parsed).
      _timer =
        arm_recurring_timer!(schema_name, instance_id, token_id, %{
          fire_at: past_fire_at(5),
          repeat_expression: "R3/PT1H",
          repeat_interval_us: 1_000_000,
          repeat_total: 3,
          fired_count: 0
        })

      for _ <- 1..3, do: Scheduler.poll_and_fire(schema_name)

      assert recurring_timer_count(schema_name, instance_id) == 3

      fourth = Scheduler.poll_and_fire(schema_name)
      assert fourth.fired == 0

      assert recurring_timer_count(schema_name, instance_id) == 3

      all_recurring =
        Timer
        |> where([t], t.instance_id == ^instance_id and not is_nil(t.repeat_expression))
        |> Repo.all(prefix: schema_name)

      assert Enum.map(all_recurring, & &1.fired_count) |> Enum.sort() == [0, 1, 2]
      assert Enum.count(all_recurring, &(&1.status == "fired")) == 3
    end
  end

  # ---------------------------------------------------------------------------------
  # AC3 -- a cancelled instance's recurring timer does not re-arm (INV-REARM-3)
  # ---------------------------------------------------------------------------------

  describe "AC3: a recurring timer whose instance is cancelled does not re-arm" do
    test "the chain terminates -- a poll immediately after cancellation claims nothing" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_looping_instance!(schema_name)
      token_id = live_token_id!(schema_name, instance_id)

      timer =
        arm_recurring_timer!(schema_name, instance_id, token_id, %{
          fire_at: past_fire_at(60),
          repeat_expression: "R/PT1H",
          repeat_interval_us: 3_600_000_000,
          repeat_total: nil,
          fired_count: 0
        })

      assert {:ok, %{status: :cancelled}} =
               Engine.cancel_instance(
                 instance_id,
                 %{actor_id: Ecto.UUID.generate(), idempotency_key: unique_name("req188-cancel")},
                 prefix: schema_name
               )

      reloaded = Repo.get!(Timer, timer.id, prefix: schema_name)
      assert reloaded.status == "cancelled"

      result = Scheduler.poll_and_fire(schema_name)
      assert result.claimed == 0
      assert result.fired == 0

      assert recurring_timer_count(schema_name, instance_id) == 1
    end
  end

  # ---------------------------------------------------------------------------------
  # AC4 -- an interval shorter than the poll interval fires at most once per
  # poll cycle (INV-REARM-4, design doc §1.5)
  # ---------------------------------------------------------------------------------

  describe "AC4: an interval shorter than the poll interval fires at most once per poll cycle" do
    test "a single poll_and_fire call creates exactly one new pending row, never catching up multiple occurrences" do
      %{schema_name: schema_name} = provisioned_tenant()
      instance_id = start_looping_instance!(schema_name)
      token_id = live_token_id!(schema_name, instance_id)

      # Documented default, so this test's premise ("far shorter than the
      # poll interval") is verified against the real accessor, not assumed.
      assert Application.get_env(:letflow, :scheduler) == nil
      assert Scheduler.poll_interval_ms() == 5_000

      timer =
        arm_recurring_timer!(schema_name, instance_id, token_id, %{
          fire_at: past_fire_at(120),
          repeat_expression: "R/PT1H",
          # 1ms -- far shorter than the 5000ms documented poll_interval_ms/0
          # default just asserted above.
          repeat_interval_us: 1_000,
          repeat_total: nil,
          fired_count: 0
        })

      result = Scheduler.poll_and_fire(schema_name)
      assert result.claimed == 1
      assert result.fired == 1

      assert recurring_timer_count(schema_name, instance_id) == 2

      assert [new_timer] = recurring_timers_other_than(schema_name, instance_id, timer.id)
      assert new_timer.status == "pending"

      # Even though new_timer.fire_at is already <= now (the interval is
      # shorter than the time this poll cycle took to run), claim_due_timer_ids/2
      # already fixed its claimed-id list BEFORE this row existed -- it is
      # structurally impossible for THIS SAME poll_and_fire/1 call to have
      # claimed it too (design doc §1.5). result.claimed == 1 above is the
      # direct proof; this is the supporting evidence that it WOULD have
      # been eligible if the cycle re-queried.
      assert DateTime.compare(new_timer.fire_at, DateTime.utc_now()) != :gt
    end
  end

  # ---------------------------------------------------------------------------------
  # Moduledoc-mandated deferral statements (design doc §0 / handoff AC 8)
  # ---------------------------------------------------------------------------------

  describe "moduledoc names the REQ-188 deferral statements" do
    test "cites 0003 Decision C / ISS-0014 option (a)/(c) for partition_maintenance/partition_retention" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/scheduler.ex"))

      assert source =~ "partition_maintenance.zig"
      assert source =~ "partition_retention.zig"
      assert source =~ "0003"
      assert source =~ "ISS-0014"
      assert source =~ "option (a)"
    end

    test "cites CHK-12's missing escalation_timer_duration attribute for the SCH-04 deferral" do
      source = File.read!(Path.join(File.cwd!(), "lib/letflow/scheduler.ex"))

      assert source =~ "SCH-04"
      assert source =~ "escalation_timer_duration"
      assert source =~ "CHK-12"
    end
  end

  # ---------------------------------------------------------------------------------
  # transition.ex was untouched BY REQ-188 ITSELF (historical scope-creep guard,
  # pinned to REQ-188's own commit range -- see UPDATE below)
  # ---------------------------------------------------------------------------------

  describe "transition.ex is untouched by REQ-188" do
    # UPDATE (WF03-ISS0398-20260901, REVIEWER, 2026-09-01): this test originally
    # asserted `git diff --stat origin/main...HEAD -- lib/letflow/engine/transition.ex`
    # was empty -- i.e. "the currently checked-out branch's diff against main touches
    # zero lines in transition.ex," evaluated fresh on every future run. That phrasing
    # was correct as a one-time scope-creep check for REQ-188's OWN PR (REQ-188 is a
    # scheduler feature -- lib/letflow/scheduler.ex/timer.ex/poller.ex -- and had no
    # legitimate reason to touch the engine's transition module; see
    # test/specs/REQ-188.md's "transition.ex untouched" row), but it was never rescoped
    # to REQ-188's own commit range after REQ-188 merged (commit 77637268, PR #731,
    # 2026-08-30). Left as "against current main forever," it became permanently
    # unsatisfiable for any later, legitimate change to transition.ex -- which is
    # exactly what happened here: ISS-0398 (`lib/letflow/design/iss0398-walk-to-gateway-fix.md`)
    # needed to fix a genuine defect in `find_matching_join/2`/`walk_to_gateway/3`
    # (replaced with `collect_leaf_gateways/3`), went through three design-review
    # rounds (two BLOCKER reworks: an INV-8 exponential-blowup finding, then a
    # memo-key-soundness finding) plus a full SECURITY-REVIEWER pass
    # (`handoffs/WF03-ISS0398-20260901/step-03c-security-reviewer-recheck1.json`, PASS)
    # before reaching this gate -- this is legitimate engine work, not scope creep,
    # and the guard's original rationale (catch REQ-188 itself touching transition.ex)
    # was already fully and permanently discharged the moment REQ-188 merged.
    #
    # Fix: rescope the assertion to REQ-188's OWN historical commit range
    # (`746a3ac0` -- REQ-188's merge-base parent -- through `77637268` -- REQ-188's own
    # merge commit) instead of "base branch...HEAD". This is now a fixed, immutable
    # historical fact (re-derived directly, not guessed: `git diff --stat
    # 746a3ac0..77637268 -- lib/letflow/engine/transition.ex` returns empty) that can
    # never again break for unrelated future work, while still proving what it was
    # built to prove: REQ-188's own changes never touched transition.ex. If a future
    # test-suite change needs a live "did MY current branch touch a file it shouldn't"
    # check again, that belongs in a per-requirement/per-issue test (scoped to that
    # work's own commit range or an explicit allowlist), not as a standing assertion
    # against a shared file that gates all later work forever -- the next agent to hit
    # this pattern should re-derive a fresh commit-range pin the same way, not restore
    # the unscoped "against main" form.
    test "lib/letflow/engine/transition.ex had zero diff across REQ-188's own commit range (746a3ac0..77637268)" do
      req_188_base = "746a3ac0"
      req_188_merge = "77637268"

      for ref <- [req_188_base, req_188_merge] do
        assert match?(
                 {_, 0},
                 System.cmd("git", ["cat-file", "-e", ref], stderr_to_stdout: true)
               ),
               "REQ-188 commit range endpoint #{ref} is not resolvable in this repository " <>
                 "(shallow clone/unshallow-history checkout?) -- cannot verify this historical guard"
      end

      {output, 0} =
        System.cmd("git", [
          "diff",
          "--stat",
          "#{req_188_base}..#{req_188_merge}",
          "--",
          "lib/letflow/engine/transition.ex"
        ])

      assert output == "",
             "REQ-188's own commit range (746a3ac0..77637268) unexpectedly touches " <>
               "lib/letflow/engine/transition.ex:\n#{output}"
    end
  end
end
