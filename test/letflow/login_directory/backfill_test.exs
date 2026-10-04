defmodule Letflow.LoginDirectory.BackfillTest do
  @moduledoc """
  REQ-435 -- `Letflow.LoginDirectory.Backfill` (design §4): idempotency across
  three tenants with overlapping emails, inactive users, a tenant registered
  `:inactive`, `dry_run`, per-tenant failure isolation and INV-4 (no email or
  key in the report or in captured Logger output). See `test/specs/REQ-435.md`.

  `Backfill.run/1` iterates EVERY registered tenant, including any other
  session's committed tenants in the shared test database, so every assertion
  here is scoped to this test's own tenant ids.
  """

  use Letflow.DataCase, async: false

  import ExUnit.CaptureLog

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.LoginDirectory.Backfill
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  @shared "shared-overlap@example.test"

  defp insert_user!(tenant, email, status) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "bf-#{System.unique_integer([:positive])}",
      display_name: "Backfill Person",
      email: email,
      password_hash: "__NO_PASSWORD_SET__",
      status: status,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: tenant.schema_name)
  end

  # Seeds users directly (the directory hooks are bypassed on purpose: this is
  # the pre-existing-users case). Call only after every tenant!/1 of the test.
  defp seed_users(%{a: a, b: b, c: c}) do
    Fx.set_status!(c, :inactive)

    insert_user!(a, @shared, :active)
    insert_user!(a, "a-only@example.test", :active)
    insert_user!(a, "A-Only@Example.test ", :active)
    insert_user!(a, "gone-inactive@example.test", :inactive)
    insert_user!(a, "not-an-email", :active)
    insert_user!(b, String.upcase(@shared), :active)
    insert_user!(b, "b-only@example.test", :active)
    insert_user!(c, @shared, :active)
    insert_user!(c, "c-only@example.test", :active)
    :ok
  end

  defp seeded_tenants do
    tenants = %{a: Fx.tenant!(), b: Fx.tenant!(), c: Fx.tenant!()}
    seed_users(tenants)
    tenants
  end

  defp report_for(report, tenant),
    do: Enum.find(report.tenants, &(&1.tenant_id == tenant.tenant_id))

  defp counts(report, tenant),
    do: Map.take(report_for(report, tenant), [:users_read, :keys, :inserted])

  defp snapshot(tenants) do
    tenants
    |> Enum.flat_map(&Fx.entries(&1.tenant_id))
    |> Enum.map(&{&1.email_key, &1.tenant_id})
    |> Enum.sort()
  end

  describe "idempotency" do
    test "second run inserts zero rows and leaves the row set identical; per-tenant counts are right" do
      %{a: a, b: b, c: c} = seeded_tenants()
      mine = [a, b, c]
      assert snapshot(mine) == []

      assert {:ok, first} = Backfill.run()

      # a: 4 active users read (the inactive one is not), 'not-an-email' skipped,
      # two case-variants of a-only collapse -> 2 distinct keys.
      assert counts(first, a) == %{users_read: 4, keys: 2, inserted: 2}
      assert counts(first, b) == %{users_read: 2, keys: 2, inserted: 2}
      assert counts(first, c) == %{users_read: 2, keys: 2, inserted: 2}

      after_first = snapshot(mine)
      assert length(after_first) == 6

      assert {:ok, second} = Backfill.run()
      for t <- mine, do: assert(report_for(second, t).inserted == 0)
      assert snapshot(mine) == after_first
    end

    test "inactive users and invalid addresses yield no row; case variants collapse to one" do
      %{a: a} = seeded_tenants()
      assert {:ok, _} = Backfill.run()

      keys = Enum.map(Fx.entries(a.tenant_id), & &1.email_key)

      assert Enum.sort(keys) == Enum.sort([Fx.key!(@shared), Fx.key!("a-only@example.test")])
      refute Fx.key!("gone-inactive@example.test") in keys
    end

    test "a tenant registered :inactive is still backfilled, but lookup excludes it" do
      %{a: a, b: b, c: c} = seeded_tenants()
      assert {:ok, _} = Backfill.run()

      assert [_, _] = Fx.entries(c.tenant_id)
      assert LoginDirectory.lookup_by_email("c-only@example.test") == {:ok, []}

      assert {:ok, found} = LoginDirectory.lookup_by_email(@shared)
      slug_of = fn t -> Repo.get!(Tenant, t.tenant_id).slug end

      assert found |> Enum.map(& &1.slug) |> Enum.sort() ==
               Enum.sort([slug_of.(a), slug_of.(b)])
    end

    test "reactivating the :inactive tenant makes its backfilled users discoverable" do
      %{c: c} = seeded_tenants()
      assert {:ok, _} = Backfill.run()
      assert LoginDirectory.lookup_by_email("c-only@example.test") == {:ok, []}

      Fx.set_status!(c, :active)
      assert {:ok, [%{}]} = LoginDirectory.lookup_by_email("c-only@example.test")
    end

    test "a pre-existing entry is not duplicated or errored (ON CONFLICT DO NOTHING)" do
      %{a: a} = seeded_tenants()

      {:ok, {:ok, :inserted}} =
        Repo.transaction(fn -> LoginDirectory.upsert_entry(a.tenant_id, @shared) end)

      assert {:ok, report} = Backfill.run()
      assert report_for(report, a).inserted == 1
      assert length(Fx.entries(a.tenant_id)) == 2
    end
  end

  describe "dry run" do
    test "inserts nothing, reports what a real run would attempt, and the real run then inserts" do
      %{a: a, b: b, c: c} = seeded_tenants()
      mine = [a, b, c]

      assert {:ok, %{dry_run: true} = dry} = Backfill.run(dry_run: true)
      assert snapshot(mine) == []

      for t <- mine do
        assert %{inserted: 0, keys: 2} = Map.take(report_for(dry, t), [:inserted, :keys])
      end

      assert {:ok, %{dry_run: false} = real} = Backfill.run()
      assert report_for(real, a).inserted == 2
      assert length(snapshot(mine)) == 6
    end
  end

  describe "failure isolation (INV-8)" do
    test "a tenant whose schema read raises is skipped and reported; the other tenants still complete" do
      tenants = %{a: Fx.tenant!(), b: Fx.tenant!(), c: Fx.tenant!()}
      broken = Fx.tenant!()
      seed_users(tenants)
      insert_user!(broken, "broken-tenant-user@example.test", :active)
      Repo.query!(~s(DROP TABLE "#{broken.schema_name}".users CASCADE))

      assert {:ok, report} = Backfill.run()

      assert [%{tenant_id: tid, reason: reason}] =
               Enum.filter(report.failed, &(&1.tenant_id == broken.tenant_id))

      assert tid == broken.tenant_id
      assert is_atom(reason)
      refute report_for(report, broken)

      for t <- Map.values(tenants), do: assert(report_for(report, t).inserted > 0)
      assert Fx.entries(broken.tenant_id) == []
      assert length(snapshot(Map.values(tenants))) == 6
    end

    test "the failure record carries a reason atom only (no exception text or email)" do
      broken = Fx.tenant!()
      insert_user!(broken, "leaky-address@example.test", :active)
      Repo.query!(~s(DROP TABLE "#{broken.schema_name}".users CASCADE))

      assert {:ok, report} = Backfill.run()
      [failure] = Enum.filter(report.failed, &(&1.tenant_id == broken.tenant_id))

      assert failure |> Map.keys() |> Enum.sort() == [:reason, :tenant_id]
      refute inspect(failure) =~ "leaky-address"
      refute inspect(failure) =~ "users"
    end
  end

  describe "pepper" do
    test "an unavailable pepper returns {:error, :pepper_unavailable} before touching any tenant" do
      %{a: a} = seeded_tenants()
      original = Application.fetch_env!(:letflow, :login_directory_pepper)
      on_exit(fn -> Application.put_env(:letflow, :login_directory_pepper, original) end)
      Application.delete_env(:letflow, :login_directory_pepper)

      assert Backfill.run() == {:error, :pepper_unavailable}
      assert Backfill.run(dry_run: true) == {:error, :pepper_unavailable}
      assert Fx.entries(a.tenant_id) == []
    end
  end

  describe "INV-4: no email or key in the report or in Logger output" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "a backfill run (dry and real) emits no address, key or directory query to the log, nor into the report" do
      %{a: a} = seeded_tenants()
      key = Fx.key!(@shared)

      {reports, log} =
        with_log([level: :debug], fn ->
          {:ok, dry} = Backfill.run(dry_run: true)
          {:ok, real} = Backfill.run()
          {dry, real}
        end)

      assert Fx.entries(a.tenant_id) != []

      refute log =~ "example.test"
      refute log =~ "tenant_login_directory"
      refute log =~ Base.encode16(key, case: :lower)
      refute log =~ Base.encode64(key)
      refute log =~ inspect(key, limit: :infinity)

      dumped = inspect(reports, limit: :infinity)
      refute dumped =~ "example.test"
      refute dumped =~ inspect(key, limit: :infinity)
    end
  end
end
