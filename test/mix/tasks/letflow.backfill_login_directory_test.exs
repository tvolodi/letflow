defmodule Mix.Tasks.Letflow.BackfillLoginDirectoryTest do
  @moduledoc """
  REQ-435 -- `mix letflow.backfill_login_directory`: per-tenant counts and
  tenant ids on stdout, `--dry-run` writes nothing, a second run reports zero
  inserted, and no email address or key appears in the task output or in the
  captured Logger output (INV-4). See `test/specs/REQ-435.md`.

  Known gap (recorded, not skipped silently): the task calls `System.halt(1)`
  when a tenant fails or the pepper is absent, which would terminate the test
  VM, so the non-zero-exit branch is covered at the `Backfill.run/1` level
  (`test/letflow/login_directory/backfill_test.exs`) and by source inspection
  below, not by running the task through a failing tenant.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Identity.User
  alias Letflow.LoginDirectory.Backfill
  alias Letflow.Test.LoginDirectoryFixture, as: Fx
  alias Mix.Tasks.Letflow.BackfillLoginDirectory, as: BackfillTask

  defp insert_user!(tenant, email) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "mt-#{System.unique_integer([:positive])}",
      display_name: "Task Person",
      email: email,
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  defp run_task(argv) do
    original = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    try do
      log = capture_log([level: :debug], fn -> BackfillTask.run(argv) end)
      {drain_shell([]), log}
    after
      Mix.shell(original)
    end
  end

  defp drain_shell(acc) do
    receive do
      {:mix_shell, level, [text]} -> drain_shell([{level, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  setup do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    a = Fx.tenant!()
    b = Fx.tenant!()
    insert_user!(a, "task-alice@example.test")
    insert_user!(a, "task-shared@example.test")
    insert_user!(b, "task-shared@example.test")

    # The task halts the VM when ANY registered tenant fails (including another
    # session's committed, broken tenant), so refuse to run it in that state.
    assert {:ok, %{failed: []}} = Backfill.run(dry_run: true),
           "a registered tenant in the shared test DB fails its backfill read; running the task would System.halt/1 the test VM"

    %{a: a, b: b}
  end

  test "--dry-run prints per-tenant counts and a dry-run summary, and inserts nothing", %{
    a: a,
    b: b
  } do
    {lines, _log} = run_task(["--dry-run"])
    infos = for {:info, text} <- lines, do: text

    assert Enum.any?(infos, &(&1 =~ "tenant #{a.tenant_id}: users_read=2 keys=2 inserted=0"))
    assert Enum.any?(infos, &(&1 =~ "tenant #{b.tenant_id}: users_read=1 keys=1 inserted=0"))
    assert Enum.any?(infos, &(&1 =~ "(dry run) complete:"))

    assert Fx.entries(a.tenant_id) == []
    assert Fx.entries(b.tenant_id) == []
  end

  test "a real run inserts, prints counts, and a second run reports inserted=0", %{a: a, b: b} do
    {lines, _log} = run_task([])
    infos = for {:info, text} <- lines, do: text

    assert Enum.any?(infos, &(&1 =~ "tenant #{a.tenant_id}: users_read=2 keys=2 inserted=2"))
    assert Enum.any?(infos, &(&1 =~ "tenant #{b.tenant_id}: users_read=1 keys=1 inserted=1"))
    assert Enum.any?(infos, &(&1 =~ "login directory backfill complete:"))
    refute Enum.any?(infos, &(&1 =~ "(dry run)"))
    assert [_, _] = Fx.entries(a.tenant_id)
    assert [_] = Fx.entries(b.tenant_id)

    {again, _log} = run_task([])
    infos2 = for {:info, text} <- again, do: text

    assert Enum.any?(infos2, &(&1 =~ "tenant #{a.tenant_id}: users_read=2 keys=2 inserted=0"))
    assert Enum.any?(infos2, &(&1 =~ "tenant #{b.tenant_id}: users_read=1 keys=1 inserted=0"))
    assert [_, _] = Fx.entries(a.tenant_id)
  end

  test "neither the task output nor the captured Logger output contains an email address or key",
       %{a: a} do
    key = Fx.key!("task-alice@example.test")

    {lines, log} = run_task([])
    output = Enum.map_join(lines, "\n", fn {_level, text} -> text end)

    for haystack <- [output, log] do
      refute haystack =~ "example.test"
      refute haystack =~ "task-alice"
      refute haystack =~ Base.encode16(key, case: :lower)
      refute haystack =~ Base.encode64(key)
    end

    refute log =~ "tenant_login_directory"
    assert [_, _] = Fx.entries(a.tenant_id)
  end

  test "an unknown flag is not fatal (strict parse; flag ignored)" do
    {lines, _log} = run_task(["--bogus"])
    assert Enum.any?(lines, fn {level, text} -> level == :info and text =~ "complete:" end)
  end

  test "source: non-zero exit on a failed tenant and on a missing pepper; no string-built SQL" do
    source = File.read!("lib/mix/tasks/letflow.backfill_login_directory.ex")

    assert source =~ "if failed != [], do: System.halt(1)"
    assert source =~ "LETFLOW_LOGIN_DIRECTORY_PEPPER is not configured"
    refute source =~ ~r/query!?\(/
    refute source =~ ~r/schema_name\s*<>|"[^"]*#\{[^}]*schema/i
  end
end
