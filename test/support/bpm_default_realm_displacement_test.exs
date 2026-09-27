defmodule Letflow.Support.BpmDefaultRealmDisplacementTest do
  @moduledoc """
  Regression test for ISS-0766 ("the migration-seeded 'bpm-default' tenant row is a
  singleton that, once lost -- e.g. an interrupted `mix test`/`scripts/test_parallel.sh`
  OS process killed between `displace!/0`'s `Repo.delete!` and its `on_exit`-deferred
  restoration -- is never re-seeded, permanently corrupting every later `mix test`
  invocation against that same long-lived database"). See `test/specs/ISS-0766.md` for
  the full acceptance-criteria breakdown.

  There is no dedicated test file for
  `test/support/bpm_default_realm_displacement.ex` itself anywhere in this suite prior
  to this file -- its behavior was previously only exercised indirectly via callers
  like `test/letflow/identity_test.exs`, all of which run under NORMAL (non-corrupted)
  conditions where the row is already present, so none of them would ever notice
  `ensure_seeded!/1` being silently removed or broken. This file directly simulates
  ISS-0766's precondition -- deletes the real "bpm-default" tenant row via raw SQL,
  bypassing `displace!/0`/`with_lock/1` entirely, exactly like ISSUE-FIXER's own manual
  reproduction (`docs/issues/ISS-0766.yaml`'s fix_direction) -- and proves the row is
  self-healed afterward, not merely that the call doesn't crash.

  `with_lock/1` is used as the primary, minimal, and fully synchronous way to exercise
  `ensure_seeded!/1`: it runs `ensure_seeded!/1` then the caller's `fun` on the SAME
  dedicated connection, all before returning, so this test can assert both the repaired
  row's content and its visibility to a caller's read within one call, with no
  `on_exit`-deferred timing to account for. `displace!/0` shares the exact same private
  `ensure_seeded!/1` call site (see that module's moduledoc), but its own self-heal
  effect is only externally observable once its `on_exit`-deferred restoration runs --
  i.e. after this test process itself has already exited -- which is not something a
  test body can synchronously observe without deadlocking on the very advisory lock
  `displace!/0` still holds until then. A lightweight functional smoke test for
  `displace!/0` is included below (it must not raise when the row is missing), but
  `with_lock/1`'s test above it is this file's authoritative, fully-synchronous proof.

  Real (non-sandboxed) Postgres access via `Ecto.Adapters.SQL.Sandbox` `:auto` mode --
  the module under test's own moduledoc explains why (the migration-seeded row is real,
  committed Postgres state, invisible to a normal sandboxed transaction).
  `async: false`, matching every other caller of `displace!/0`/`with_lock/1` in this
  codebase: this file deletes and restores the shared "bpm-default" binding directly,
  serialized against every other test via the module under test's own dedicated
  Postgres advisory lock.
  """

  use Letflow.DataCase, async: false

  import Ecto.Query

  alias Letflow.Identity.Tenant
  alias Letflow.Repo
  alias Letflow.Support.BpmDefaultRealmDisplacement

  # ---------------------------------------------------------------------------------
  # Fixtures / helpers
  # ---------------------------------------------------------------------------------

  defp bpm_default_row, do: Repo.get_by(Tenant, idp_realm_id: "bpm-default")

  # Deletes the "bpm-default" tenant row via raw SQL -- deliberately bypassing
  # displace!/0/with_lock/1 (and their advisory lock) entirely, exactly like ISS-0766's
  # own manual reproduction: simulates a database that is ALREADY corrupted (e.g. by a
  # prior interrupted process) before this test's own call to the module under test
  # even runs, rather than exercising the lock/mutual-exclusion machinery itself (that
  # is `test/letflow/plugs/auth_pipeline_test.exs` et al.'s concern, not this file's).
  defp delete_bpm_default_row! do
    Repo.delete_all(from(t in Tenant, where: t.idp_realm_id == "bpm-default"))
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    # Capture whatever tenant currently holds the binding (normally the
    # migration-seeded row) so it can be restored after this test, regardless of what
    # ensure_seeded!/1 leaves behind (its own re-insert uses a fresh random id/slug
    # combination each time -- ON CONFLICT (slug) DO NOTHING keys only on `slug`,
    # always "bpm-default", so at most one such row ever exists at a time).
    original = bpm_default_row()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      delete_bpm_default_row!()

      if original do
        %Tenant{}
        |> Tenant.create_changeset(
          %{
            slug: original.slug,
            display_name: original.display_name,
            idp_realm_id: original.idp_realm_id
          },
          :enabled
        )
        |> Repo.insert!()
      end

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------------
  # Criterion 1 -- with_lock/1 self-heals the missing "bpm-default" row via
  # ensure_seeded!/1 before running the caller's fun (ISS-0766 fix_direction item 1).
  # This is the exact shape identity_test.exs's insert_default_tenant!/0 (the original
  # caller ISS-0766 named as broken) depends on.
  # ---------------------------------------------------------------------------------

  describe "with_lock/1 self-heals via ensure_seeded!/1 (ISS-0766)" do
    test "re-seeds the bpm-default tenant row when it is missing, before running fun" do
      delete_bpm_default_row!()
      refute bpm_default_row()

      # Repo.get_by!/2 (the bang variant, matching identity_test.exs's own
      # insert_default_tenant!/0) raises Ecto.NoResultsError if the row is still
      # missing at this point -- this is the exact exception ISS-0766's process_note
      # quotes verbatim from real CI failures
      # ("test/support/bpm_default_realm_displacement.ex:118 via
      # insert_default_tenant!()"). A test that only asserted "no crash" without this
      # bang-read inside fun would not actually prove the row is usable by a real
      # caller, so this is deliberately the same access pattern, not a softer one.
      result =
        BpmDefaultRealmDisplacement.with_lock(fn ->
          Repo.get_by!(Tenant, idp_realm_id: "bpm-default")
        end)

      # Same shape the seed migration
      # (priv/repo/migrations/20260918173137_seed_default_tenant.exs) and
      # ensure_seeded!/1's own INSERT use -- proves a genuine repair, not just "some
      # row exists."
      assert %Tenant{
               slug: "bpm-default",
               display_name: "Default Tenant",
               idp_realm_id: "bpm-default",
               status: :active
             } = result

      # And durably committed -- readable independently of with_lock/1's own fun,
      # confirming this isn't an artifact only visible inside that one call.
      assert %Tenant{idp_realm_id: "bpm-default"} = bpm_default_row()
    end

    test "is a no-op repair when the row is already present" do
      # Deliberately does NOT assume the row is already ambiently present here --
      # ISS-0766 itself is precisely about a long-lived, reused test database
      # legitimately starting a run with this row already missing (a prior
      # interrupted process, or simply a different test earlier in this same
      # `mix test` invocation, having last touched it). This test's own criterion is
      # idempotency across two ensure_seeded!/1 calls, not "the row happened to
      # already be there" -- so it establishes the row itself first, via the same
      # self-healing path under test, before proving a second call doesn't disturb it.
      existing =
        BpmDefaultRealmDisplacement.with_lock(fn ->
          Repo.get_by!(Tenant, idp_realm_id: "bpm-default")
        end)

      result =
        BpmDefaultRealmDisplacement.with_lock(fn ->
          Repo.get_by!(Tenant, idp_realm_id: "bpm-default")
        end)

      # ON CONFLICT (slug) DO NOTHING must not disturb the pre-existing row's identity
      # (id) -- proves ensure_seeded!/1 is genuinely idempotent, not a
      # delete-and-reinsert that would spuriously succeed this criterion for the wrong
      # reason.
      assert result.id == existing.id
    end
  end

  # ---------------------------------------------------------------------------------
  # Criterion 2 -- displace!/0 shares the same ensure_seeded!/1 call site and must not
  # raise/crash when the row is missing (functional smoke test; see moduledoc above
  # for why full synchronous proof isn't practical for this entry point).
  # ---------------------------------------------------------------------------------

  describe "displace!/0 self-heals via ensure_seeded!/1 (ISS-0766)" do
    test "does not raise when the bpm-default row is missing" do
      delete_bpm_default_row!()
      refute bpm_default_row()

      assert :ok = BpmDefaultRealmDisplacement.displace!()
    end
  end
end
