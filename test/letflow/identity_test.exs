defmodule Letflow.IdentityTest do
  @moduledoc """
  Tests for `Letflow.Identity.provision_oidc_user/3`. See `test/specs/REQ-018.md` for
  the full test-case rationale, including which criteria are covered by inspection
  rather than a runtime assertion (AC4's moduledoc citation, and the
  `:external_identity_collision` defensive branch).

  Uses `Letflow.DataCase` (real Postgres, sandboxed connection, rolled back per test)
  per `docs/guides/test_developer_guide.md` DIRECTIVE T-1 — no mocked database anywhere
  in this file.

  The concurrent-race test (acceptance criterion 3) runs `async: true` deliberately:
  `Letflow.DataCase` only calls `Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})`
  when a test is NOT `async: true` (see `test/support/data_case.ex`) — shared mode would
  let the two spawned `Task`s reach the connection pool implicitly, which defeats the
  point of proving the race is handled through the sandbox's normal per-process
  ownership rules. Staying in the sandbox's default (manual, per-process) ownership and
  explicitly `Ecto.Adapters.SQL.Sandbox.allow/3`-ing each spawned `Task` onto the test
  process's own checked-out connection (per design doc §9's exact guidance) is what
  makes this a genuine two-connection race rather than an accidentally-serialized one.
  """

  use Letflow.DataCase, async: true

  alias Letflow.Identity
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig

  # Every test builds its own unique identity triple — no shared hardcoded
  # tenant_id/realm/external_id, per test_developer_guide.md's "no test pollution"
  # principle and this project's established Ecto.UUID.generate()-per-test convention.
  defp unique_realm(prefix \\ "realm") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp identity_context(overrides \\ %{}) do
    struct(
      %IdentityContext{
        external_user_id: Ecto.UUID.generate(),
        tenant_id: nil,
        realm: unique_realm(),
        roles: [],
        email: "someone@example.com",
        preferred_username: "someone-#{System.unique_integer([:positive])}",
        display_name: "Someone Example"
      },
      overrides
    )
  end

  defp jit_config(overrides \\ %{}) do
    struct(
      %JitProvisioningConfig{
        realm: "unused-by-provision_oidc_user",
        enabled: true,
        default_status: :active,
        default_roles: []
      },
      overrides
    )
  end

  describe "provision_oidc_user/3 — idempotency (acceptance criterion 1)" do
    test "calling provision_oidc_user/3 twice with the same identity returns the same user.id, created: true then false" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert id1 == id2
    end

    test "three consecutive calls all resolve to the same user.id" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert {:ok, %{user: %User{id: id3}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant_id, config)

      assert id1 == id2
      assert id2 == id3
    end

    test "different (tenant_id, realm, external_id) triples create distinct rows" do
      config = jit_config()

      ctx_a = identity_context()
      ctx_b = identity_context()

      assert {:ok, %{user: %User{id: id_a}, created: true}} =
               Identity.provision_oidc_user(ctx_a, Ecto.UUID.generate(), config)

      assert {:ok, %{user: %User{id: id_b}, created: true}} =
               Identity.provision_oidc_user(ctx_b, Ecto.UUID.generate(), config)

      assert id_a != id_b
    end
  end

  describe "provision_oidc_user/3 — fixed literals (acceptance criterion 2)" do
    test "the inserted row has the fixed OIDC-only password_hash and auth_source: :oidc" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()

      assert {:ok, %{user: %User{id: id}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      # Re-select from Postgres directly, rather than trusting the in-memory reply —
      # matches process_instance_test.exs's "every successful transition is persisted
      # to Postgres" persistence-test convention.
      persisted = Repo.get(User, id)

      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end

    test "password_hash and auth_source are not caller-overridable" do
      tenant_id = Ecto.UUID.generate()
      # IdentityContext has no password_hash/auth_source field at all, so this
      # exercises that the changeset always sets fixed values regardless of what's
      # in the context — there is no input surface here that COULD supply an
      # override, which is itself the property being pinned.
      ctx = identity_context(%{email: "override-attempt@example.com"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      persisted = Repo.get(User, id)
      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end
  end

  describe "provision_oidc_user/3 — concurrent-insert race (acceptance criterion 3)" do
    test "a genuine concurrent race between two tasks resolves to exactly one created row, both callers succeed" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config()

      parent = self()

      run_task = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        # Barrier: make both tasks announce readiness, then wait for the parent's
        # go-ahead, so both reach Identity.provision_oidc_user/3's own select-first
        # step at effectively the same time and genuinely race into the INSERT ...
        # ON CONFLICT path together, rather than being accidentally serialized by
        # Task.async/1's own scheduling.
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        after
          5000 -> flunk("barrier release never arrived")
        end

        Identity.provision_oidc_user(ctx, tenant_id, config)
      end

      task1 = Task.async(run_task)
      task2 = Task.async(run_task)

      # Wait for both tasks to reach the barrier before releasing either — this is
      # what forces both to attempt the insert at effectively the same time instead
      # of being serialized by whichever task's scheduler slice runs first.
      assert_receive {:ready, pid1}, 5000
      assert_receive {:ready, pid2}, 5000
      assert pid1 in [task1.pid, task2.pid]
      assert pid2 in [task1.pid, task2.pid]
      assert pid1 != pid2

      send(pid1, :go)
      send(pid2, :go)

      result1 = Task.await(task1, 5000)
      result2 = Task.await(task2, 5000)

      assert {:ok, %{user: %User{id: id1}, created: created1}} = result1
      assert {:ok, %{user: %User{id: id2}, created: created2}} = result2

      # Both tasks resolve to the same row.
      assert id1 == id2

      # Exactly one of the two calls actually performed the insert.
      assert [created1, created2] |> Enum.count(& &1) == 1

      # No unhandled exception escaped either task (Task.await/2 above would itself
      # have raised if either task's process crashed) — asserting this explicitly as
      # a documented expectation, not just relying on Task.await/2's own behavior.
      assert is_boolean(created1)
      assert is_boolean(created2)

      # Exactly one row exists in the database for this identity afterward.
      import Ecto.Query

      rows =
        User
        |> where(
          tenant_id: ^tenant_id,
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all()

      assert length(rows) == 1
    end
  end

  describe "provision_oidc_user/3 — jit_config.enabled == false (design-flagged, not a numbered AC)" do
    test "jit_config.enabled == false returns {:error, :jit_disabled} without writing to the database" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context()
      config = jit_config(%{enabled: false})

      assert {:error, :jit_disabled} = Identity.provision_oidc_user(ctx, tenant_id, config)

      import Ecto.Query

      rows =
        User
        |> where(
          tenant_id: ^tenant_id,
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all()

      assert rows == []
    end
  end

  describe "provision_oidc_user/3 — username cross-tenant collision (design §4.4/OQ-3, design-flagged)" do
    test "two different tenants with the same preferred_username: the second JIT provisioning call fails with a username uniqueness changeset error" do
      shared_username = "collide-#{System.unique_integer([:positive])}"
      config = jit_config()

      tenant_a = Ecto.UUID.generate()
      tenant_b = Ecto.UUID.generate()

      ctx_a = identity_context(%{preferred_username: shared_username})
      ctx_b = identity_context(%{preferred_username: shared_username})

      assert {:ok, %{user: %User{}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant_a, config)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.provision_oidc_user(ctx_b, tenant_b, config)

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "provision_oidc_user/3 — display_name fallback (design §4.3, design-flagged)" do
    test "display_name nil in the identity context falls back to preferred_username on the persisted row" do
      tenant_id = Ecto.UUID.generate()
      ctx = identity_context(%{display_name: nil, preferred_username: "fallback-username"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      persisted = Repo.get(User, id)
      assert persisted.display_name == "fallback-username"
    end

    test "display_name present in the identity context is stored verbatim" do
      tenant_id = Ecto.UUID.generate()

      ctx =
        identity_context(%{
          display_name: "Explicit Display Name",
          preferred_username: "some-other-username"
        })

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant_id, jit_config())

      persisted = Repo.get(User, id)
      assert persisted.display_name == "Explicit Display Name"
    end
  end

  # Minimal local helper mirroring Ecto's own test-helper convention (avoids pulling
  # in a full Phoenix-style ConnCase/errors_on just for this one assertion).
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
