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

    test "an unrecognized yaml status is always a mismatch, queue_status reported as n/a" do
      sources = [source(:requirement, "REQ-1", "unknown_status", 1)]
      queue_tasks = [task(1, "open")]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert [%{kind: :status_mismatch, queue_status: "n/a", reason: reason}] = report.findings
      assert reason =~ "unrecognized yaml status"
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
        source(:issue, "ISS-0001", "cancelled", 5)
      ]

      queue_tasks = [
        task(1, "done"),
        task(2, "blocked"),
        task(3, "open"),
        task(4, "open"),
        task(5, "done")
      ]

      report = CheckQueueReconciliation.reconcile(sources, queue_tasks)

      assert report.findings == []
      assert report.sources_checked == 5
      assert report.queue_tasks_seen == 5
    end
  end

  describe "status_compatible?/2 -- the mapping table" do
    test "done accepts done and blocked, rejects open" do
      assert CheckQueueReconciliation.status_compatible?("done", "done")
      assert CheckQueueReconciliation.status_compatible?("done", "blocked")
      refute CheckQueueReconciliation.status_compatible?("done", "open")
    end

    test "in_progress accepts open and blocked, rejects done" do
      assert CheckQueueReconciliation.status_compatible?("in_progress", "open")
      assert CheckQueueReconciliation.status_compatible?("in_progress", "blocked")
      refute CheckQueueReconciliation.status_compatible?("in_progress", "done")
    end

    test "pending accepts only open" do
      assert CheckQueueReconciliation.status_compatible?("pending", "open")
      refute CheckQueueReconciliation.status_compatible?("pending", "blocked")
      refute CheckQueueReconciliation.status_compatible?("pending", "done")
    end

    test "blocked accepts blocked and open, rejects done" do
      assert CheckQueueReconciliation.status_compatible?("blocked", "blocked")
      assert CheckQueueReconciliation.status_compatible?("blocked", "open")
      refute CheckQueueReconciliation.status_compatible?("blocked", "done")
    end

    test "cancelled accepts anything" do
      assert CheckQueueReconciliation.status_compatible?("cancelled", "open")
      assert CheckQueueReconciliation.status_compatible?("cancelled", "blocked")
      assert CheckQueueReconciliation.status_compatible?("cancelled", "done")
    end

    test "an unrecognized yaml status is never compatible" do
      refute CheckQueueReconciliation.status_compatible?("weird", "open")
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
