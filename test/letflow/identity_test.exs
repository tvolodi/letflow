defmodule Letflow.IdentityTest do
  @moduledoc """
  Tests for `Letflow.Identity.provision_oidc_user/4` (REQ-018, arity bumped to /4 by
  REQ-063 — see below) and `Letflow.Identity.resolve_tenant_by_realm/1`,
  `resolve_realm_by_tenant/1`, `verify_realm_ownership/2`, plus
  `Letflow.Identity.Tenant.create_changeset/3`/`update_changeset/2` (REQ-019). See
  `test/specs/REQ-018.md` and `test/specs/REQ-019.md` for the full test-case
  rationale, including which criteria are covered by inspection rather than a runtime
  assertion (REQ-018 AC4's moduledoc citation, and the `:external_identity_collision`
  defensive branch). See `test/specs/REQ-063.md` for why this file's fixtures changed.

  Uses `Letflow.DataCase` (real Postgres) per `docs/guides/test_developer_guide.md`
  DIRECTIVE T-1 — no mocked database anywhere in this file.

  ## REQ-063 fixture change (read before touching a `provision_oidc_user/4` test here)

  REQ-063 (`lib/letflow/design/req063-identity-tables-schema-per-tenant.md`) moved
  `users`/`groups`/`tenant_role` out of the `public` schema into each tenant's own
  provisioned Postgres schema, and `Identity.provision_oidc_user/3` became `/4` with a
  required `opts :: [prefix: String.t()]` fourth argument (design §5b). Every test that
  exercises `provision_oidc_user/4` now needs a **real, provisioned tenant schema**
  (`Letflow.TenantProvisioning.provision_tenant_schema/1` +
  `replay_migrations/2`) to pass as that `prefix:`, not a bare `Ecto.UUID.generate()`
  tenant_id with an implicit `public`-schema `users` table — that table no longer
  exists post-cutover (this branch already ran the drop migration; see
  `mix ecto.migrate` output referenced in `test/specs/REQ-063.md`).

  `Ecto.Migrator` (which `replay_migrations/2` calls) "cannot run dynamically during
  test under `Ecto.Adapters.SQL.Sandbox`, as the sandbox has to share a single
  connection across processes" (`deps/ecto_sql/lib/ecto/migrator.ex`'s own moduledoc,
  flagged for TEST-DESIGNER at `lib/letflow/design/req022-tenant-schema-provisioning.md`
  §6's testing-environment caveat). This file follows the same
  `Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)` + manual `on_exit/1` cleanup
  pattern `test/letflow/tenant_provisioning_test.exs` and `test/letflow/event_store_test.exs`
  already establish for exactly this reason — `provisioned_tenant!/0` below mirrors
  those files' `provisioned_tenant/1` helper. Every `describe` block in this file that
  provisions a tenant therefore runs under real (non-rolled-back) Postgres state,
  cleaned up explicitly in `on_exit/1`.

  **This file is now `async: false` for its entire module** (ExUnit's `async` setting
  is module-wide, not per-test) — unlike its pre-REQ-063 version, which had
  `provision_oidc_user/3` tests running `async: true` against `public`. Every
  `provision_oidc_user/4` test now needs `:auto` mode, which is only safe when no other
  `async: true` module's connection could be disturbed; `async: false` combined with
  ExUnit's documented full-drain-before-sync-modules scheduling (see
  `tenant_provisioning_test.exs`'s moduledoc for the source-level citation this file
  relies on rather than re-deriving) makes that safe. The REQ-019 `Tenant`-only tests
  (which never touch `users`/`groups`/`tenant_role` — `Tenant` stays in `public`
  permanently per Decision 0006 D3) do not themselves need `:auto` mode, but must share
  this module's `async: false` setting regardless since it is module-wide; they still
  run inside DataCase's normal rolled-back sandbox connection (no `:auto` switch of
  their own), so nothing about their isolation changes.

  The concurrent-race test (acceptance criterion 3) needs `provisioned_tenant!/0`'s
  migration replay first (which needs `:auto` mode, same as every other test in this
  file), but then switches BACK to `:manual` mode + a fresh checkout for the race
  itself — restoring the original `Sandbox.allow/3`-based two-process-same-connection
  mechanism design §9 specifies, once the schema/migration prerequisite is already real
  committed Postgres state that survives the mode switch. See that test's own inline
  comment for the full reasoning and why a genuine `:auto`-mode two-independent-
  connections race was tried first and rejected (it surfaces a real, separate,
  pre-existing gap in `Identity.insert_or_fetch/4`'s conflict handling — filed as
  ISS-0047, not silently fixed or masked here — rather than reproducing this specific
  acceptance criterion's intended proof).
  """

  use Letflow.DataCase, async: false

  import Ecto.Query, only: [where: 2, where: 3]

  alias Letflow.Identity
  alias Letflow.Identity.Tenant
  alias Letflow.Identity.User
  alias Letflow.Oidc.IdentityContext
  alias Letflow.Oidc.JitProvisioningConfig

  # Every test builds its own unique identity triple — no shared hardcoded
  # tenant_id/realm/external_id, per test_developer_guide.md's "no test pollution"
  # principle and this project's established Ecto.UUID.generate()-per-test convention.
  defp unique_realm(prefix \\ "realm") do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end

  # REQ-019 fixture helpers.

  defp unique_slug(prefix \\ "tenant") do
    Letflow.TenantSlugFixture.unique_slug(prefix)
  end

  defp insert_tenant!(attrs, oidc_mode \\ :enabled) do
    %Tenant{}
    |> Tenant.create_changeset(attrs, oidc_mode)
    |> Repo.insert!()
  end

  # The one fixture deliberately using the literal "bpm-default" reserved slug/realm —
  # per test/specs/REQ-019.md, "seeded" means TEST-DESIGNER-constructed, not a real
  # priv/repo/seeds.exs row. oidc_mode is irrelevant to the pinning rule itself (it's
  # unconditional), so :enabled is used here without loss of generality.
  defp insert_default_tenant! do
    insert_tenant!(%{
      slug: "bpm-default",
      display_name: "Default Tenant",
      idp_realm_id: "bpm-default"
    })
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

  # ---------------------------------------------------------------------------------
  # REQ-063 tenant-schema provisioning helper — adopts the shared `Letflow.TenantFixture`
  # (ISS-0109/GH#358, ISS-0115/GH#369) in place of this file's own hand-rolled
  # insert_tenant! + :auto-mode + on_exit/1 DROP SCHEMA copy. Behaviour-preserving by
  # construction (same Tenant.create_changeset/3 call, same provision_tenant_schema/1 +
  # replay_migrations/1 sequence, same :auto sandbox mode, same teardown), but adds a
  # completeness assertion post-replay and emits a greppable `LETFLOW_TENANT_FIXTURE`
  # marker automatically on teardown/capture failure. This module is the one ISS-0115
  # caught a single, unreproduced 42P01 undefined_table failure in
  # (identity_test.exs:205) — adopting the fixture here is that issue's own prescribed
  # step, so the *next* occurrence carries a full `capture_schema_state/1` report
  # instead of a bare Postgrex error. Still takes the same `oidc_mode` positional arg
  # every call site here already passes; still returns `%{tenant: ..., schema_name:
  # ...}` so no call site below needs to change.
  # ---------------------------------------------------------------------------------
  defp provisioned_tenant!(oidc_mode \\ :disabled) do
    %{tenant: tenant, schema_name: schema_name} =
      Letflow.TenantFixture.provisioned_tenant!(
        slug_prefix: "req063-identity",
        display_name: "REQ-063 Test Tenant",
        oidc_mode: oidc_mode
      )

    %{tenant: tenant, schema_name: schema_name}
  end

  describe "provision_oidc_user/4 — idempotency (acceptance criterion 1)" do
    test "calling provision_oidc_user/4 twice with the same identity returns the same user.id, created: true then false" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert id1 == id2
    end

    test "three consecutive calls all resolve to the same user.id" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      assert {:ok, %{user: %User{id: id1}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert {:ok, %{user: %User{id: id2}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert {:ok, %{user: %User{id: id3}, created: false}} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      assert id1 == id2
      assert id2 == id3
    end

    test "different (tenant_id, realm, external_id) triples in different tenant schemas create distinct rows" do
      %{tenant: tenant_a, schema_name: schema_a} = provisioned_tenant!()
      %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant!()
      config = jit_config()

      ctx_a = identity_context()
      ctx_b = identity_context()

      assert {:ok, %{user: %User{id: id_a}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant_a.id, config, prefix: schema_a)

      assert {:ok, %{user: %User{id: id_b}, created: true}} =
               Identity.provision_oidc_user(ctx_b, tenant_b.id, config, prefix: schema_b)

      assert id_a != id_b
    end
  end

  describe "provision_oidc_user/4 — fixed literals (acceptance criterion 2)" do
    test "the inserted row has the fixed OIDC-only password_hash and auth_source: :oidc" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()

      assert {:ok, %{user: %User{id: id}, created: true}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      # Re-select from Postgres directly, rather than trusting the in-memory reply —
      # matches process_instance_test.exs's "every successful transition is persisted
      # to Postgres" persistence-test convention. Must pass prefix: here too, per
      # REQ-063 — Repo.get/3 with no prefix would look in public, which no longer has
      # this row.
      persisted = Repo.get(User, id, prefix: schema_name)

      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end

    test "password_hash and auth_source are not caller-overridable" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      # IdentityContext has no password_hash/auth_source field at all, so this
      # exercises that the changeset always sets fixed values regardless of what's
      # in the context — there is no input surface here that COULD supply an
      # override, which is itself the property being pinned.
      ctx = identity_context(%{email: "override-attempt@example.com"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      persisted = Repo.get(User, id, prefix: schema_name)
      assert persisted.password_hash == "__OIDC_ONLY__"
      assert persisted.auth_source == :oidc
    end
  end

  describe "provision_oidc_user/4 — concurrent-insert race (acceptance criterion 3)" do
    test "a genuine concurrent race between two tasks resolves to exactly one created row, both callers succeed" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config()

      # REQ-063 update: provisioned_tenant!/0 above needed Sandbox :auto mode for its
      # migration replay (Ecto.Migrator's own documented single-shared-connection
      # incompatibility, see this file's moduledoc) -- but the ORIGINAL pre-REQ-063
      # version of this test relied specifically on :manual mode + Sandbox.allow/3,
      # which routes both spawned Tasks through the SAME underlying sandboxed
      # connection/transaction (nested savepoints), matching design §9's exact
      # guidance ("Ecto.Adapters.SQL.Sandbox `:manual` mode with `Sandbox.allow/3`").
      # Switching back to :manual mode and taking a fresh checkout here, AFTER the
      # schema/migration work above has already completed under :auto, restores that
      # exact intended mechanism for the race itself -- the tenant schema created
      # above survives the mode switch (it's real, committed Postgres state, not
      # sandboxed), so this checkout's rolled-back transaction only ever touches the
      # User row this test itself inserts.
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :manual)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Letflow.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, {:shared, self()})

      parent = self()

      run_task = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        # Barrier: make both tasks announce readiness, then wait for the parent's
        # go-ahead, so both reach Identity.provision_oidc_user/4's own select-first
        # step at effectively the same time and genuinely race into the INSERT ...
        # ON CONFLICT path together, rather than being accidentally serialized by
        # Task.async/1's own scheduling.
        send(parent, {:ready, self()})

        receive do
          :go -> :ok
        after
          5000 -> flunk("barrier release never arrived")
        end

        Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)
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
      rows =
        User
        |> where(
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all(prefix: schema_name)

      assert length(rows) == 1

      # Switch back to :auto mode BEFORE this test ends -- provisioned_tenant!/0's
      # on_exit/1 cleanup (DROP SCHEMA / DELETE FROM tenants) needs a real, checked-in
      # connection to run against; leaving this test's manual-mode checkout open past
      # the test body would orphan it once this test process exits, and on_exit/1's
      # own Repo calls would then fail trying to check out a connection whose owner
      # process is already gone (confirmed empirically while drafting this test).
      Ecto.Adapters.SQL.Sandbox.mode(Letflow.Repo, :auto)
    end
  end

  describe "provision_oidc_user/4 — ISS-0047 regression: username-index race resolves cleanly" do
    test "two genuinely independent connections racing an identical (realm, external_id, username) identity always resolve to {:ok, same id}, looped" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      config = jit_config()

      # :auto mode (already set by provisioned_tenant!/0 above) gives each spawned
      # Task its own genuinely independent, automatically-checked-out connection --
      # unlike the acceptance-criterion-3 race test above, which deliberately
      # switches to :manual mode + Sandbox.allow/3 so both Tasks share ONE
      # connection/transaction (see that test's own inline comment). A single
      # shared connection serializes the two INSERTs and never lets Postgres's
      # own conflict-check ordering across the two DIFFERENT unique indexes
      # (`(external_realm, external_id)` and `username`) vary -- which is exactly
      # the gap ISS-0047 depends on. Two real, independent connections are
      # required to exercise it at all -- see
      # lib/letflow/design/iss-0047-username-race-conflict-target.md §5.
      #
      # ISSUE-FIXER's own repro only reproduced the pre-fix bug 4/6 runs
      # (nondeterministic, depends on which unique index Postgres's constraint
      # checker happens to evaluate first for the losing insert) -- looping 10
      # independent race attempts, each with a fresh identity so no attempt's
      # result can be masked by a prior attempt's already-committed row, gives
      # strong confidence this is a reliable proof rather than a flaky one-shot.
      for attempt <- 1..10 do
        ctx = identity_context()
        parent = self()

        run_task = fn ->
          # Barrier: both tasks announce readiness, then wait for the parent's
          # go-ahead, so both reach provision_oidc_user/4's own select-first step
          # at effectively the same time and genuinely race into the INSERT
          # together, rather than being serialized by Task.async/1's own
          # scheduling. Same pattern as the acceptance-criterion-3 race test
          # above (lines 284-301), reused per design §5's guidance.
          send(parent, {:ready, attempt, self()})

          receive do
            :go -> :ok
          after
            5000 -> flunk("attempt #{attempt}: barrier release never arrived")
          end

          Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)
        end

        task1 = Task.async(run_task)
        task2 = Task.async(run_task)

        assert_receive {:ready, ^attempt, pid1}, 5000
        assert_receive {:ready, ^attempt, pid2}, 5000
        assert pid1 != pid2

        send(pid1, :go)
        send(pid2, :go)

        result1 = Task.await(task1, 5000)
        result2 = Task.await(task2, 5000)

        # The ISS-0047 bug surfaced as {:error, %Ecto.Changeset{}} for the losing
        # racer here (a username-uniqueness violation treated as permanent
        # instead of being recognized as this call's own race opponent) --
        # asserting {:ok, ...} for BOTH results is this regression test's core
        # proof.
        assert {:ok, %{user: %User{id: id1}, created: created1}} = result1
        assert {:ok, %{user: %User{id: id2}, created: created2}} = result2

        assert id1 == id2,
               "attempt #{attempt}: both racers must resolve to the same user id, got #{inspect(result1)} / #{inspect(result2)}"

        assert [created1, created2] |> Enum.count(& &1) == 1,
               "attempt #{attempt}: exactly one of the two calls should have inserted"

        rows =
          User
          |> where(external_realm: ^ctx.realm, external_id: ^ctx.external_user_id)
          |> Repo.all(prefix: schema_name)

        assert length(rows) == 1, "attempt #{attempt}: exactly one row should exist afterward"
      end
    end
  end

  describe "provision_oidc_user/4 — jit_config.enabled == false (design-flagged, not a numbered AC)" do
    test "jit_config.enabled == false returns {:error, :jit_disabled} without writing to the database" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context()
      config = jit_config(%{enabled: false})

      assert {:error, :jit_disabled} =
               Identity.provision_oidc_user(ctx, tenant.id, config, prefix: schema_name)

      rows =
        User
        |> where(
          external_realm: ^ctx.realm,
          external_id: ^ctx.external_user_id
        )
        |> Repo.all(prefix: schema_name)

      assert rows == []
    end
  end

  describe "provision_oidc_user/4 — username collision, same vs different tenant schemas (REQ-063)" do
    test "same username in the SAME tenant schema: second JIT provisioning call fails uniqueness" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      shared_username = "collide-#{System.unique_integer([:positive])}"
      config = jit_config()

      ctx_a = identity_context(%{preferred_username: shared_username})
      ctx_b = identity_context(%{preferred_username: shared_username})

      assert {:ok, %{user: %User{}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant.id, config, prefix: schema_name)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Identity.provision_oidc_user(ctx_b, tenant.id, config, prefix: schema_name)

      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "same username in TWO DIFFERENT tenant schemas both succeed (per-tenant-unique — Decision 0006 §3.1)" do
      %{tenant: tenant_a, schema_name: schema_a} = provisioned_tenant!()
      %{tenant: tenant_b, schema_name: schema_b} = provisioned_tenant!()
      shared_username = "collide-#{System.unique_integer([:positive])}"
      config = jit_config()

      ctx_a = identity_context(%{preferred_username: shared_username})
      ctx_b = identity_context(%{preferred_username: shared_username})

      assert {:ok, %{user: %User{id: id_a}, created: true}} =
               Identity.provision_oidc_user(ctx_a, tenant_a.id, config, prefix: schema_a)

      assert {:ok, %{user: %User{id: id_b}, created: true}} =
               Identity.provision_oidc_user(ctx_b, tenant_b.id, config, prefix: schema_b)

      assert id_a != id_b

      # Both rows genuinely persisted, one per tenant schema, same username value.
      assert %User{username: ^shared_username} = Repo.get(User, id_a, prefix: schema_a)
      assert %User{username: ^shared_username} = Repo.get(User, id_b, prefix: schema_b)
    end
  end

  describe "provision_oidc_user/4 — display_name fallback (design §4.3, design-flagged)" do
    test "display_name nil in the identity context falls back to preferred_username on the persisted row" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()
      ctx = identity_context(%{display_name: nil, preferred_username: "fallback-username"})

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      persisted = Repo.get(User, id, prefix: schema_name)
      assert persisted.display_name == "fallback-username"
    end

    test "display_name present in the identity context is stored verbatim" do
      %{tenant: tenant, schema_name: schema_name} = provisioned_tenant!()

      ctx =
        identity_context(%{
          display_name: "Explicit Display Name",
          preferred_username: "some-other-username"
        })

      assert {:ok, %{user: %User{id: id}}} =
               Identity.provision_oidc_user(ctx, tenant.id, jit_config(), prefix: schema_name)

      persisted = Repo.get(User, id, prefix: schema_name)
      assert persisted.display_name == "Explicit Display Name"
    end
  end

  describe "resolve_tenant_by_realm/1 and resolve_realm_by_tenant/1 (REQ-019 acceptance criterion 1)" do
    test "resolve_tenant_by_realm/1 resolves the seeded default tenant (bpm-default) by its idp_realm_id" do
      tenant = insert_default_tenant!()

      assert {:ok, %Tenant{id: id}} = Identity.resolve_tenant_by_realm("bpm-default")
      assert id == tenant.id
    end

    test "resolve_realm_by_tenant/1 resolves the seeded default tenant's (bpm-default) idp_realm_id by its tenant id" do
      tenant = insert_default_tenant!()

      assert {:ok, "bpm-default"} = Identity.resolve_realm_by_tenant(tenant.id)
    end

    test "resolve_tenant_by_realm/1 returns {:error, :not_found} for an unknown realm string" do
      assert {:error, :not_found} = Identity.resolve_tenant_by_realm(unique_realm("nonexistent"))
    end

    test "resolve_realm_by_tenant/1 returns {:error, :not_found} for an unknown tenant_id" do
      assert {:error, :not_found} = Identity.resolve_realm_by_tenant(Ecto.UUID.generate())
    end

    test "resolve_realm_by_tenant/1 returns {:ok, nil} for a tenant that exists but has no bound realm" do
      tenant =
        insert_tenant!(
          %{slug: unique_slug(), display_name: "No Realm Yet", idp_realm_id: nil},
          :disabled
        )

      assert {:ok, nil} = Identity.resolve_realm_by_tenant(tenant.id)
    end
  end

  describe "Tenant.create_changeset/3 — one-to-one collision rejection (REQ-019 acceptance criterion 2)" do
    test "creating a second tenant with an already-bound idp_realm_id is rejected, not silently overwritten" do
      shared_realm = unique_realm("collide")

      insert_tenant!(%{slug: unique_slug(), display_name: "Tenant A", idp_realm_id: shared_realm})

      result =
        %Tenant{}
        |> Tenant.create_changeset(
          %{slug: unique_slug(), display_name: "Tenant B", idp_realm_id: shared_realm},
          :enabled
        )
        |> Repo.insert()

      assert {:error, %Ecto.Changeset{} = changeset} = result
      assert %{idp_realm_id: ["has already been taken"]} = errors_on(changeset)

      rows = Tenant |> where(idp_realm_id: ^shared_realm) |> Repo.all()
      assert length(rows) == 1
    end

    test "two tenants with distinct idp_realm_id values both persist successfully" do
      tenant_a =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Tenant A",
          idp_realm_id: unique_realm()
        })

      tenant_b =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Tenant B",
          idp_realm_id: unique_realm()
        })

      assert tenant_a.id != tenant_b.id
      assert tenant_a.idp_realm_id != tenant_b.idp_realm_id
    end
  end

  describe "Tenant.update_changeset/2 — idp_realm_id immutability (REQ-019 acceptance criterion 3)" do
    test "update_changeset/2 does not cast idp_realm_id even when present in attrs" do
      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Original Name",
          idp_realm_id: unique_realm("original")
        })

      changeset =
        Tenant.update_changeset(tenant, %{
          idp_realm_id: "attempted-new-realm",
          display_name: "New Name"
        })

      assert Ecto.Changeset.get_change(changeset, :idp_realm_id) == nil
      assert Ecto.Changeset.get_change(changeset, :display_name) == "New Name"
      assert changeset.valid?
    end

    test "persisting update_changeset/2 with an attempted idp_realm_id change leaves the original idp_realm_id unchanged in the database" do
      original_realm = unique_realm("original")

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Original Name",
          idp_realm_id: original_realm
        })

      changeset =
        Tenant.update_changeset(tenant, %{
          idp_realm_id: "attempted-new-realm",
          display_name: "New Name"
        })

      assert {:ok, _updated} = Repo.update(changeset)

      persisted = Repo.get(Tenant, tenant.id)
      assert persisted.idp_realm_id == original_realm
      assert persisted.display_name == "New Name"
    end
  end

  describe "verify_realm_ownership/2 — realm-ownership guard, every branch (REQ-019 acceptance criterion 4)" do
    test "verify_realm_ownership/2 returns :ok when external_realm matches the tenant's bound idp_realm_id" do
      realm = unique_realm()

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Matching Tenant",
          idp_realm_id: realm
        })

      assert :ok = Identity.verify_realm_ownership(tenant.id, realm)
    end

    test "verify_realm_ownership/2 returns {:error, :realm_tenant_mismatch} when external_realm does not match the tenant's bound realm" do
      bound_realm = unique_realm("bound")
      other_realm = unique_realm("other")

      tenant =
        insert_tenant!(%{
          slug: unique_slug(),
          display_name: "Bound Tenant",
          idp_realm_id: bound_realm
        })

      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant.id, other_realm)
    end

    test "verify_realm_ownership/2 returns {:error, :not_found} for a tenant_id that matches no row" do
      assert {:error, :not_found} =
               Identity.verify_realm_ownership(Ecto.UUID.generate(), unique_realm())
    end

    test "verify_realm_ownership/2 returns {:error, :realm_tenant_mismatch}, not :ok and not a crash, for a tenant with no bound realm" do
      tenant =
        insert_tenant!(
          %{slug: unique_slug(), display_name: "No Realm Bound", idp_realm_id: nil},
          :disabled
        )

      assert {:error, :realm_tenant_mismatch} =
               Identity.verify_realm_ownership(tenant.id, unique_realm("some-external-realm"))
    end
  end

  describe "Tenant.create_changeset/3 — default-tenant pinning (design §3.2/§4)" do
    test "create_changeset/3 rejects slug bpm-default paired with a different idp_realm_id" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant", idp_realm_id: unique_realm()},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end

    test "create_changeset/3 accepts slug bpm-default paired with idp_realm_id bpm-default" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant", idp_realm_id: "bpm-default"},
          :enabled
        )

      assert changeset.valid?
    end

    test "create_changeset/3 rejects slug bpm-default with idp_realm_id omitted entirely" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: "bpm-default", display_name: "Default Tenant"},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "Tenant.create_changeset/3 — oidc_mode-conditional idp_realm_id requirement (design §3.2)" do
    test "create_changeset/3 requires idp_realm_id for a non-default tenant when oidc_mode is :enabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: unique_slug(), display_name: "Non-default Tenant"},
          :enabled
        )

      refute changeset.valid?
      assert %{idp_realm_id: [_ | _]} = errors_on(changeset)
    end

    test "create_changeset/3 allows a non-default tenant with no idp_realm_id when oidc_mode is :disabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{slug: unique_slug(), display_name: "Non-default Tenant"},
          :disabled
        )

      assert changeset.valid?
    end

    test "create_changeset/3 accepts a non-default tenant with idp_realm_id present when oidc_mode is :enabled" do
      changeset =
        Tenant.create_changeset(
          %Tenant{},
          %{
            slug: unique_slug(),
            display_name: "Non-default Tenant",
            idp_realm_id: unique_realm()
          },
          :enabled
        )

      assert changeset.valid?
    end
  end

  # ── REQ-124: Identity.safe_get_tenant_by_slug/2 exception-swallowing ──────
  #
  # Shared by the two unauthenticated tenant-config bootstrap routes
  # (Letflow.Routers.TenantConfig, Letflow.Routers.MobileTenantConfig) -- see
  # lib/letflow/identity.ex's own @doc for safe_get_tenant_by_slug/2. This
  # describe block is REQ-124's own contribution (its handoff's acceptance
  # criterion 5), independent of REQ-018/REQ-019 above.

  describe "safe_get_tenant_by_slug/2 — exception-swallowing (REQ-124 acceptance criterion 5)" do
    test "a genuine hit resolves exactly like get_tenant_by_slug/1" do
      tenant =
        insert_tenant!(
          %{
            slug: unique_slug("req124-safe-hit"),
            display_name: "REQ-124 Safe Hit",
            idp_realm_id: unique_realm("req124-safe-hit")
          },
          :disabled
        )

      assert {:ok, ^tenant} = Identity.safe_get_tenant_by_slug(tenant.slug, "req124-test")
      assert {:ok, ^tenant} = Identity.get_tenant_by_slug(tenant.slug)
    end

    test "a genuine miss returns {:error, :not_found}, same as get_tenant_by_slug/1" do
      missing_slug = unique_slug("req124-missing")

      assert {:error, :not_found} = Identity.safe_get_tenant_by_slug(missing_slug, "req124-test")
      assert {:error, :not_found} = Identity.get_tenant_by_slug(missing_slug)
    end

    test "a raise inside get_tenant_by_slug/1 is swallowed into {:error, :lookup_failed}, never propagates" do
      # Passing a non-binary `slug` makes Ecto's own query planner raise
      # Ecto.Query.CastError at query-execution time -- confirmed against this
      # project's vendored Ecto dependency (deps/ecto/lib/ecto/query/planner.ex,
      # `"value \`#{inspect(v)}\` cannot be dumped to type #{...}"` -> `raise
      # Ecto.Query.CastError`). This is a REAL exception raised from inside
      # get_tenant_by_slug/1's own Repo.get_by/2 call, not a simulated or
      # mocked one. If safe_get_tenant_by_slug/2's `rescue` clause were ever
      # removed, this test would fail with an unhandled Ecto.Query.CastError
      # instead of matching {:error, :lookup_failed} -- see the companion
      # "unwrapped" test below, which pins that this input genuinely raises
      # when NOT going through the wrapper.
      assert {:error, :lookup_failed} =
               Identity.safe_get_tenant_by_slug(12_345, "req124-raise-test")
    end

    test "get_tenant_by_slug/1 itself (unwrapped) DOES raise for the same bad input -- proves the rescue in safe_get_tenant_by_slug/2 is load-bearing, not a no-op" do
      assert_raise Ecto.Query.CastError, fn ->
        Identity.get_tenant_by_slug(12_345)
      end
    end

    test "the warning log names the context_label and the slug, and never the exception itself (INV-4)" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :lookup_failed} =
                   Identity.safe_get_tenant_by_slug(98_765, "req124-log-test")
        end)

      assert log =~ "req124-log-test"
      assert log =~ "98765"
      # INV-4: never logs the exception itself -- its message would mention
      # "QueryError" / "cannot be dumped" / the underlying query/connection
      # details, none of which this warning line may carry.
      refute log =~ "QueryError"
      refute log =~ "cannot be dumped"
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
