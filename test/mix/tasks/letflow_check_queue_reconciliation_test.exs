defmodule Mix.Tasks.Letflow.CheckQueueReconciliationTest do
  @moduledoc """
  Covers ISS-0848 AC2: `reconcile/2` must flag (i) a status mismatch and
  (ii) a dangling `queue_ref`/`impl_order`, exercised against fixture data
  only -- never the live queue (that's AC3, run manually by ELIXIR-DEV, not
  from `mix test`).
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Letflow.CheckQueueReconciliation

  defp source(kind, id, yaml_status, queue_task_id) do
    %{kind: kind, id: id, yaml_status: yaml_status, queue_task_id: queue_task_id}
  end

  defp task(id, status), do: %{id: id, status: status, title: "t#{id}"}

  describe "reconcile/2 -- status_mismatch" do
    test "yaml done vs queue open is flagged (the exact ISS-0848 finding shape)" do
      sources = [source(:requirement, "REQ-999", "done", 999)]
      queue_tasks = [task(999, "open")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :status_mismatch, source: %{id: "REQ-999"}, queue_status: "open"}] =
               report.findings

      assert report.sources_checked == 1
      assert report.queue_tasks_seen == 1
    end

    test "ISS-0836/REQ-406/REQ-407 precedent: yaml done vs queue blocked is NOT a mismatch" do
      sources = [source(:requirement, "REQ-406", "done", 406)]
      queue_tasks = [task(406, "blocked")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert report.findings == []
    end

    test "yaml in_progress vs queue done is flagged" do
      sources = [source(:issue, "ISS-0848", "in_progress", 848)]
      queue_tasks = [task(848, "done")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :status_mismatch, reason: reason}] = report.findings
      assert reason =~ "in_progress"
      assert reason =~ "done"
    end

    test "issue instrumented vs queue done is flagged, not silently accepted" do
      sources = [source(:issue, "ISS-0700", "instrumented", 700)]
      queue_tasks = [task(700, "done")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :status_mismatch, source: %{id: "ISS-0700"}, queue_status: "done"}] =
               report.findings
    end

    test "issue no_defect vs queue done is flagged, not silently accepted" do
      sources = [source(:issue, "ISS-0701", "no_defect", 701)]
      queue_tasks = [task(701, "done")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :status_mismatch, source: %{id: "ISS-0701"}, queue_status: "done"}] =
               report.findings
    end
  end

  describe "reconcile/2 -- unrecognized_yaml_status" do
    test "an unrecognized yaml status on a requirement source is its own finding kind" do
      sources = [source(:requirement, "REQ-1", "unknown_status", 1)]
      queue_tasks = [task(1, "open")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :unrecognized_yaml_status, source: %{id: "REQ-1"}, reason: reason}] =
               report.findings

      assert reason =~ "unknown_status"
      refute Enum.any?(report.findings, &(&1.kind == :status_mismatch))
    end

    test "a legacy/undocumented issue yaml status is its own finding kind, not a status_mismatch" do
      sources = [source(:issue, "ISS-0123", "reopened", 123)]
      queue_tasks = [task(123, "done")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :unrecognized_yaml_status, source: %{id: "ISS-0123"}, reason: reason}] =
               report.findings

      assert reason =~ "reopened"
      refute Enum.any?(report.findings, &(&1.kind == :status_mismatch))
    end
  end

  describe "reconcile/2 -- dangling_queue_ref" do
    test "a queue_ref/impl_order pointing to a non-existent task is flagged" do
      sources = [source(:issue, "ISS-0001", "in_progress", 99_999)]
      queue_tasks = [task(1, "open")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :dangling_queue_ref, source: %{id: "ISS-0001", queue_task_id: 99_999}}] =
               report.findings
    end

    test "a requirement's impl_order pointing nowhere is flagged the same way as an issue's queue_ref" do
      sources = [source(:requirement, "REQ-500", "pending", 50_000)]
      queue_tasks = []

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :dangling_queue_ref, source: %{kind: :requirement, id: "REQ-500"}}] =
               report.findings
    end
  end

  describe "reconcile/2 -- clean set" do
    test "a fully compatible mix of requirements and issues produces zero findings" do
      sources = [
        source(:requirement, "REQ-1", "done", 1),
        source(:requirement, "REQ-2", "in_progress", 2),
        source(:requirement, "REQ-3", "pending", 3),
        source(:requirement, "REQ-4", "blocked", 4),
        source(:issue, "ISS-0001", "resolved", 5),
        source(:issue, "ISS-0002", "open", 6),
        source(:issue, "ISS-0003", "instrumented", 7),
        source(:issue, "ISS-0004", "no_defect", 8)
      ]

      queue_tasks = [
        task(1, "done"),
        task(2, "blocked"),
        task(3, "open"),
        task(4, "open"),
        task(5, "done"),
        task(6, "open"),
        task(7, "blocked"),
        task(8, "blocked")
      ]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert report.findings == []
      assert report.sources_checked == 8
      assert report.queue_tasks_seen == 8
    end
  end

  describe "status_compatible?/3 -- the requirement mapping table (§3.3, unchanged)" do
    test "done accepts done and blocked, rejects open" do
      assert CheckQueueReconciliation.status_compatible?(:requirement, "done", "done")
      assert CheckQueueReconciliation.status_compatible?(:requirement, "done", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:requirement, "done", "open")
    end

    test "in_progress accepts open and blocked, rejects done" do
      assert CheckQueueReconciliation.status_compatible?(:requirement, "in_progress", "open")
      assert CheckQueueReconciliation.status_compatible?(:requirement, "in_progress", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:requirement, "in_progress", "done")
    end

    test "pending accepts only open" do
      assert CheckQueueReconciliation.status_compatible?(:requirement, "pending", "open")
      refute CheckQueueReconciliation.status_compatible?(:requirement, "pending", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:requirement, "pending", "done")
    end

    test "blocked accepts blocked and open, rejects done" do
      assert CheckQueueReconciliation.status_compatible?(:requirement, "blocked", "blocked")
      assert CheckQueueReconciliation.status_compatible?(:requirement, "blocked", "open")
      refute CheckQueueReconciliation.status_compatible?(:requirement, "blocked", "done")
    end

    test "cancelled accepts anything" do
      assert CheckQueueReconciliation.status_compatible?(:requirement, "cancelled", "open")
      assert CheckQueueReconciliation.status_compatible?(:requirement, "cancelled", "blocked")
      assert CheckQueueReconciliation.status_compatible?(:requirement, "cancelled", "done")
    end

    test "an unrecognized yaml status is never compatible" do
      refute CheckQueueReconciliation.status_compatible?(:requirement, "weird", "open")
    end
  end

  describe "status_compatible?/3 -- the issue mapping table (§3.3b, AMENDMENT)" do
    test "open accepts only open (queue done under yaml open must NOT be compatible)" do
      assert CheckQueueReconciliation.status_compatible?(:issue, "open", "open")
      refute CheckQueueReconciliation.status_compatible?(:issue, "open", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:issue, "open", "done")
    end

    test "in_progress accepts open and blocked, rejects done" do
      assert CheckQueueReconciliation.status_compatible?(:issue, "in_progress", "open")
      assert CheckQueueReconciliation.status_compatible?(:issue, "in_progress", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:issue, "in_progress", "done")
    end

    test "resolved accepts done and blocked (ISS-0836-style precedent), rejects open" do
      assert CheckQueueReconciliation.status_compatible?(:issue, "resolved", "done")
      assert CheckQueueReconciliation.status_compatible?(:issue, "resolved", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:issue, "resolved", "open")
    end

    test "instrumented accepts only blocked -- NEVER done, per ISSUE_QUEUE.md's explicit rule" do
      assert CheckQueueReconciliation.status_compatible?(:issue, "instrumented", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:issue, "instrumented", "done")
      refute CheckQueueReconciliation.status_compatible?(:issue, "instrumented", "open")
    end

    test "no_defect accepts only blocked -- NEVER done, per ISSUE_QUEUE.md's explicit rule" do
      assert CheckQueueReconciliation.status_compatible?(:issue, "no_defect", "blocked")
      refute CheckQueueReconciliation.status_compatible?(:issue, "no_defect", "done")
      refute CheckQueueReconciliation.status_compatible?(:issue, "no_defect", "open")
    end

    test "the 8 undocumented legacy issue-status values are never compatible (unmapped by design)" do
      for legacy <- ~w(reopened fixed declined closed_not_applicable resolved_via_duplicate
                       resolved_not_applicable duplicate done) do
        refute CheckQueueReconciliation.status_compatible?(:issue, legacy, "open")
        refute CheckQueueReconciliation.status_compatible?(:issue, legacy, "blocked")
        refute CheckQueueReconciliation.status_compatible?(:issue, legacy, "done")
      end
    end

    test "requirement and issue tables are independent -- issue-side unmapped 'cancelled'" do
      # "cancelled" IS mapped for :requirement (accepts anything) but is NOT part
      # of the issue vocabulary (§3.3b) -- confirms the two tables are dispatched
      # separately, not merged/shared.
      assert CheckQueueReconciliation.status_compatible?(:requirement, "cancelled", "open")
      refute CheckQueueReconciliation.status_compatible?(:issue, "cancelled", "open")
    end
  end

  describe "parse_issue_file/1" do
    test "a well-formed queue_ref line parses to a source_ref" do
      content = """
      id: ISS-0100
      status: in_progress
      queue_ref: Q-42
      """

      assert %{kind: :issue, id: "ISS-0100", yaml_status: "in_progress", queue_task_id: 42} =
               CheckQueueReconciliation.parse_issue_file(content, "docs/issues/ISS-0100.yaml")
    end

    test "queue_ref: null is :unregistered, not a finding" do
      content = """
      id: ISS-0101
      status: resolved
      queue_ref: null   # filed directly, never queued
      """

      assert CheckQueueReconciliation.parse_issue_file(content, "docs/issues/ISS-0101.yaml") ==
               :unregistered
    end

    test "a missing id is an error" do
      content = """
      status: pending
      queue_ref: Q-1
      """

      assert {:error, reason} =
               CheckQueueReconciliation.parse_issue_file(content, "docs/issues/ISS-0102.yaml")

      assert reason =~ "id"
    end

    test "a missing status is an error" do
      content = """
      id: ISS-0103
      queue_ref: Q-1
      """

      assert {:error, reason} =
               CheckQueueReconciliation.parse_issue_file(content, "docs/issues/ISS-0103.yaml")

      assert reason =~ "status"
    end

    test "a malformed queue_ref is an error" do
      content = """
      id: ISS-0104
      status: pending
      queue_ref: 42
      """

      assert {:error, reason} =
               CheckQueueReconciliation.parse_issue_file(content, "docs/issues/ISS-0104.yaml")

      assert reason =~ "well-formed"
    end

    test "an indented queue_ref inside a description block is prose, not a field" do
      content = """
      id: ISS-0105
      status: resolved
      description: >
        This mirrors queue_ref: Q-999 from another issue, quoted for history.
      queue_ref: null   # never registered
      """

      assert CheckQueueReconciliation.parse_issue_file(content, "docs/issues/ISS-0105.yaml") ==
               :unregistered
    end
  end

  describe "resolve_queue_auth_token/0" do
    test "returns {:ok, token} when $QUEUE_AUTH_TOKEN is set in the shell env" do
      System.put_env("QUEUE_AUTH_TOKEN", "test-token-123")
      on_exit(fn -> System.delete_env("QUEUE_AUTH_TOKEN") end)

      assert CheckQueueReconciliation.resolve_queue_auth_token() == {:ok, "test-token-123"}
    end
  end
end
