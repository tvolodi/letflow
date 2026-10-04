defmodule Letflow.LoginDirectoryTest do
  @moduledoc """
  REQ-435 -- the `Letflow.LoginDirectory` data layer: table placement, key form,
  the single-query lookup, cross-tenant isolation, FK cascade and the writers'
  own contracts. See `test/specs/REQ-435.md` for the criterion -> test mapping.

  `async: false`: tests swap the global `:login_directory_pepper` application
  env (restored in `on_exit/1`) and provision real tenant schemas.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Letflow.Identity.Tenant
  alias Letflow.Identity.TenantLoginDirectoryEntry
  alias Letflow.Identity.User
  alias Letflow.LoginDirectory
  alias Letflow.TenantProvisioning.Registration
  alias Letflow.Test.LoginDirectoryFixture, as: Fx

  defp with_pepper(value) do
    original = Application.fetch_env(:letflow, :login_directory_pepper)

    on_exit(fn ->
      case original do
        {:ok, v} -> Application.put_env(:letflow, :login_directory_pepper, v)
        :error -> Application.delete_env(:letflow, :login_directory_pepper)
      end
    end)

    case value do
      :unset -> Application.delete_env(:letflow, :login_directory_pepper)
      v -> Application.put_env(:letflow, :login_directory_pepper, v)
    end
  end

  defp in_tx(fun) do
    {:ok, result} = Repo.transaction(fn -> fun.() end)
    result
  end

  defp insert_user!(schema_name, email) do
    %User{}
    |> Ecto.Changeset.change(%{
      username: "u-#{System.unique_integer([:positive])}",
      display_name: "Some Person",
      email: email,
      password_hash: "__NO_PASSWORD_SET__",
      status: :active,
      auth_source: :internal
    })
    |> Repo.insert!(prefix: schema_name)
  end

  # Counts queries issued by the calling process via the Repo telemetry event.
  defp count_queries(fun) do
    ref = make_ref()
    me = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:letflow, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == me, do: send(me, {:query, ref})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(ref, n) do
    receive do
      {:query, ^ref} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  describe "AC1: table lives in the public schema only" do
    test "information_schema shows exactly one schema holding the table: public" do
      %{rows: rows} =
        Repo.query!(
          "SELECT table_schema FROM information_schema.tables WHERE table_name = 'tenant_login_directory'"
        )

      assert rows == [["public"]]
    end

    test "a freshly provisioned tenant schema does not contain the table" do
      %{schema_name: schema_name} = Fx.tenant!()

      %{rows: rows} =
        Repo.query!(
          "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = 'tenant_login_directory'",
          [schema_name]
        )

      assert rows == []
    end

    test "the table holds only (email_key, tenant_id, inserted_at): no credential, role, user or profile column" do
      %{rows: rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'tenant_login_directory'"
        )

      assert rows |> List.flatten() |> Enum.sort() == ["email_key", "inserted_at", "tenant_id"]
    end

    test "the Ecto schema exposes exactly the same fields (no password/role/user_id/external_id/display_name)" do
      assert Enum.sort(TenantLoginDirectoryEntry.__schema__(:fields)) ==
               [:email_key, :inserted_at, :tenant_id]
    end

    test "the DB rejects a key that is not 32 bytes (CHECK octet_length = 32)" do
      %{tenant_id: tenant_id} = Fx.tenant!()

      assert_raise Postgrex.Error, fn ->
        Repo.insert_all(TenantLoginDirectoryEntry, [
          %{
            email_key: :crypto.strong_rand_bytes(31),
            tenant_id: tenant_id,
            inserted_at: ~N[2026-01-01 00:00:00]
          }
        ])
      end
    end
  end

  describe "AC8: key form" do
    test "key is the 32-byte domain-separated HMAC-SHA256 of the normalised email (independent oracle)" do
      {:ok, pepper} = Application.fetch_env(:letflow, :login_directory_pepper)
      expected = :crypto.mac(:hmac, :sha256, pepper, "letflow:login-directory:v1:" <> "a@x.com")

      assert {:ok, key} = LoginDirectory.email_key("A@X.com ")
      assert byte_size(key) == 32
      assert key == expected
    end

    test "key is never the plaintext (or lowercased) email and does not contain it" do
      assert {:ok, key} = LoginDirectory.email_key("alice@example.test")
      refute key == "alice@example.test"
      refute String.contains?(key, "alice")
    end

    test "the stored directory row carries the key, never the plaintext" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      email = "stored-plain@example.test"

      assert {:ok, :inserted} = in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)

      assert [%{email_key: stored}] = Fx.entries(tenant_id)
      assert stored == Fx.key!(email)
      refute String.contains?(stored, "stored-plain")
    end

    test "a different pepper yields a different key" do
      {:ok, key_a} = LoginDirectory.email_key("alice@example.test")
      with_pepper(String.duplicate("b", 32))
      {:ok, key_b} = LoginDirectory.email_key("alice@example.test")

      assert key_a != key_b
    end

    test "normalisation equivalence: 'A@X.com ' and 'a@x.com' collide to one key" do
      assert LoginDirectory.email_key("A@X.com ") == LoginDirectory.email_key("a@x.com")

      assert LoginDirectory.email_key("  MiXeD@Example.TEST") ==
               LoginDirectory.email_key("mixed@example.test")

      refute LoginDirectory.email_key("a@x.com") == LoginDirectory.email_key("b@x.com")
    end

    test "invalid input is :invalid, not a key" do
      assert LoginDirectory.email_key("not-an-email") == :invalid
      assert LoginDirectory.email_key("") == :invalid
      assert LoginDirectory.email_key(nil) == :invalid
      assert LoginDirectory.email_key(123) == :invalid
      assert LoginDirectory.email_key("a@" <> String.duplicate("x", 260) <> ".com") == :invalid
    end

    test "an absent pepper is {:error, :pepper_unavailable}; a wrong-size pepper too" do
      with_pepper(:unset)
      assert LoginDirectory.email_key("a@x.com") == {:error, :pepper_unavailable}
      assert LoginDirectory.sentinel_key() == {:error, :pepper_unavailable}

      with_pepper("short")
      assert LoginDirectory.email_key("a@x.com") == {:error, :pepper_unavailable}
    end

    test "the sentinel key is a 32-byte key distinct from any real address's key" do
      sentinel = LoginDirectory.sentinel_key()
      assert byte_size(sentinel) == 32
      refute sentinel == Fx.key!("sentinel-no-at-sign@example.test")
    end
  end

  describe "AC6: lookup" do
    test "same email in tenants A and B yields two entries and lookup returns both in deterministic order" do
      a = Fx.tenant!(display_name: "Zzz Tenant")
      b = Fx.tenant!(display_name: "Aaa Tenant")
      email = Fx.unique_email("dual")

      in_tx(fn ->
        assert {:ok, :inserted} = LoginDirectory.upsert_entry(a.tenant_id, email)
        assert {:ok, :inserted} = LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      key = Fx.key!(email)

      assert Repo.aggregate(
               from(d in TenantLoginDirectoryEntry, where: d.email_key == ^key),
               :count
             ) ==
               2

      assert {:ok, result} = LoginDirectory.lookup_by_email(email)
      assert Enum.map(result, & &1.display_name) == ["Aaa Tenant", "Zzz Tenant"]
      assert LoginDirectory.lookup_by_email(email) == {:ok, result}
      assert LoginDirectory.lookup_by_email(" " <> String.upcase(email)) == {:ok, result}
    end

    test "equal display names are tie-broken by slug" do
      a = Fx.tenant!(display_name: "Same Name")
      b = Fx.tenant!(display_name: "Same Name")
      email = Fx.unique_email("tie")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      %{rows: rows} =
        Repo.query!(
          "SELECT slug FROM tenants WHERE id = ANY($1) ORDER BY display_name, slug",
          [[Ecto.UUID.dump!(a.tenant_id), Ecto.UUID.dump!(b.tenant_id)]]
        )

      assert {:ok, result} = LoginDirectory.lookup_by_email(email)
      assert Enum.map(result, & &1.slug) == List.flatten(rows)
    end

    test "returns only slug and display_name per row (closed projection)" do
      a = Fx.tenant!()
      email = Fx.unique_email("proj")
      in_tx(fn -> LoginDirectory.upsert_entry(a.tenant_id, email) end)

      assert {:ok, [row]} = LoginDirectory.lookup_by_email(email)
      assert Map.keys(row) |> Enum.sort() == [:display_name, :slug]
      refute is_struct(row)
    end

    test "excludes :inactive and :migrating tenants and tenants without a bound realm" do
      active = Fx.tenant!()
      inactive = Fx.tenant!()
      migrating = Fx.tenant!()
      unbound = Fx.tenant!(idp_realm_id: :none)
      empty_realm = Fx.tenant!()
      email = Fx.unique_email("excl")

      Fx.set_status!(inactive, :inactive)
      Fx.set_status!(migrating, :migrating)

      {1, _} =
        Repo.update_all(from(t in Tenant, where: t.id == ^empty_realm.tenant_id),
          set: [idp_realm_id: ""]
        )

      in_tx(fn ->
        for t <- [active, inactive, migrating, unbound, empty_realm] do
          assert {:ok, :inserted} = LoginDirectory.upsert_entry(t.tenant_id, email)
        end
      end)

      active_slug = Repo.get!(Tenant, active.tenant_id).slug
      assert {:ok, [%{slug: ^active_slug}]} = LoginDirectory.lookup_by_email(email)
    end

    test "the lookup is exactly ONE query, and telemetry still fires with log: false" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      email = Fx.unique_email("one")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      {result, count} = count_queries(fn -> LoginDirectory.lookup_by_email(email) end)

      assert {:ok, [_, _]} = result
      assert count == 1
    end

    test "invalid and unknown inputs return {:ok, []} (sentinel key, never matches)" do
      assert LoginDirectory.lookup_by_email("not-an-email") == {:ok, []}
      assert LoginDirectory.lookup_by_email(nil) == {:ok, []}
      assert LoginDirectory.lookup_by_email(Fx.unique_email("nobody")) == {:ok, []}
    end

    test "the sentinel is never written, so it matches no row even after a write attempt" do
      %{tenant_id: tenant_id} = Fx.tenant!()

      assert {:error, :invalid_email} =
               in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, "sentinel-no-at-sign") end)

      assert Fx.entries(tenant_id) == []
      assert LoginDirectory.lookup_by_key(LoginDirectory.sentinel_key()) == {:ok, []}
    end

    test "a missing pepper degrades to {:error, :lookup_failed}, never a raise" do
      with_pepper(:unset)
      assert LoginDirectory.lookup_by_email("a@x.com") == {:error, :lookup_failed}
      assert LoginDirectory.lookup_by_email("not-an-email") == {:error, :lookup_failed}
    end

    test "lookup_by_key/1 rejects a non-32-byte key without querying" do
      assert LoginDirectory.lookup_by_key("short") == {:error, :lookup_failed}
    end
  end

  describe "AC7: cross-tenant isolation" do
    test "an address that exists only in tenant A never returns anything tied to tenant B" do
      a = Fx.tenant!(display_name: "Tenant Alpha")
      b = Fx.tenant!(display_name: "Tenant Beta")
      only_a = Fx.unique_email("only-a")
      only_b = Fx.unique_email("only-b")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, only_a)
        LoginDirectory.upsert_entry(b.tenant_id, only_b)
      end)

      assert {:ok, [%{display_name: "Tenant Alpha"}]} = LoginDirectory.lookup_by_email(only_a)
      assert {:ok, [%{display_name: "Tenant Beta"}]} = LoginDirectory.lookup_by_email(only_b)

      # The directory holds only (key, tenant_id) pairs for each tenant.
      assert [%{email_key: ka, tenant_id: ta}] = Fx.entries(a.tenant_id)
      assert {ka, ta} == {Fx.key!(only_a), a.tenant_id}
      assert [%{tenant_id: tb}] = Fx.entries(b.tenant_id)
      assert tb == b.tenant_id
    end
  end

  describe "AC11: FK cascade" do
    test "deleting a tenant row cascades its directory entries" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      email = Fx.unique_email("cascade")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      Repo.delete_all(from(r in Registration, where: r.tenant_id == ^a.tenant_id))
      assert {1, _} = Repo.delete_all(from(t in Tenant, where: t.id == ^a.tenant_id))

      assert Fx.entries(a.tenant_id) == []
      assert [_] = Fx.entries(b.tenant_id)
    end
  end

  describe "writers" do
    test "upsert_entry/2 is idempotent: :inserted then :exists, one row" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      email = Fx.unique_email("idem")

      assert {:ok, :inserted} = in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)

      assert {:ok, :exists} =
               in_tx(fn ->
                 LoginDirectory.upsert_entry(tenant_id, " " <> String.upcase(email))
               end)

      assert [_] = Fx.entries(tenant_id)
    end

    test "writers refuse to run outside a transaction" do
      %{tenant_id: tenant_id, schema_name: schema_name} = Fx.tenant!()

      # The sandbox checkout wraps the test in a transaction; leave it by using a
      # pooled :auto connection for just these two calls.
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

      task =
        Task.async(fn ->
          {LoginDirectory.upsert_entry(tenant_id, "a@x.com"),
           LoginDirectory.remove_entry_if_unreferenced(tenant_id, "a@x.com", schema_name)}
        end)

      assert Task.await(task) == {{:error, :not_in_transaction}, {:error, :not_in_transaction}}
      assert Fx.entries(tenant_id) == []
    end

    test "upsert_entry/2 with a missing pepper returns :pepper_unavailable and writes nothing" do
      %{tenant_id: tenant_id} = Fx.tenant!()
      with_pepper(:unset)

      assert {:error, :pepper_unavailable} =
               in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, "a@x.com") end)

      assert Fx.entries(tenant_id) == []
    end

    test "upsert_entry/2 never leaks exception text: a bad tenant_id is the fixed :write_failed" do
      # FK violation (no such tenant) raises inside insert_all; reason must be fixed.
      assert {:error, :write_failed} =
               in_tx(fn ->
                 Repo.query!("SAVEPOINT s")
                 result = LoginDirectory.upsert_entry(Ecto.UUID.generate(), "a@x.com")
                 Repo.query!("ROLLBACK TO SAVEPOINT s")
                 result
               end)
    end

    test "remove_entry_if_unreferenced/3: :absent, :kept while another active user holds the email, then :removed" do
      %{tenant_id: tenant_id, schema_name: schema_name} = Fx.tenant!()
      email = Fx.unique_email("rm")

      assert {:ok, :absent} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      in_tx(fn -> LoginDirectory.upsert_entry(tenant_id, email) end)
      other = insert_user!(schema_name, String.upcase(email))

      assert {:ok, :kept} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      assert [_] = Fx.entries(tenant_id)

      Repo.update!(Ecto.Changeset.change(other, status: :inactive), prefix: schema_name)

      assert {:ok, :removed} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(tenant_id, email, schema_name)
               end)

      assert Fx.entries(tenant_id) == []
    end

    test "remove_entry_if_unreferenced/3 only deletes the entry of the named tenant" do
      a = Fx.tenant!()
      b = Fx.tenant!()
      email = Fx.unique_email("rm-scope")

      in_tx(fn ->
        LoginDirectory.upsert_entry(a.tenant_id, email)
        LoginDirectory.upsert_entry(b.tenant_id, email)
      end)

      assert {:ok, :removed} =
               in_tx(fn ->
                 LoginDirectory.remove_entry_if_unreferenced(a.tenant_id, email, a.schema_name)
               end)

      assert Fx.entries(a.tenant_id) == []
      assert [_] = Fx.entries(b.tenant_id)
    end
  end
end
